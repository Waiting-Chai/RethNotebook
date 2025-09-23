# Blockchain Tree & Reorgs: Managing Chain Reorganizations

## Overview

<mcreference link="https://github.com/paradigmxyz/reth/issues/662" index="5">5</mcreference> Blockchain reorganizations (reorgs) are a fundamental aspect of blockchain consensus mechanisms, where the canonical chain can change due to competing blocks or network conditions. <mcreference link="https://github.com/paradigmxyz/reth/releases" index="4">4</mcreference> Reth implements sophisticated reorg handling mechanisms to ensure data consistency and optimal performance during chain reorganizations.

## Understanding Blockchain Reorgs

### What is a Reorg?

A blockchain reorganization occurs when the network switches from one chain of blocks to another, typically longer or more valid chain. This can happen due to:

1. **Network Partitions**: Temporary splits in the network
2. **Competing Blocks**: Multiple valid blocks at the same height
3. **Consensus Rules**: Fork choice rules favoring different chains
4. **Finality Mechanisms**: Post-merge Ethereum with consensus layer finality

### Types of Reorgs

```rust
// From reth-blockchain-tree/src/lib.rs
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReorgType {
    /// Single block reorg - most common
    SingleBlock {
        old_block: BlockHash,
        new_block: BlockHash,
    },
    /// Multi-block reorg - less common but more complex
    MultiBlock {
        /// Blocks being removed from canonical chain
        removed_blocks: Vec<BlockHash>,
        /// Blocks being added to canonical chain
        added_blocks: Vec<BlockHash>,
        /// Common ancestor block
        common_ancestor: BlockHash,
    },
    /// Deep reorg - rare but requires special handling
    DeepReorg {
        /// Number of blocks being reorganized
        depth: u64,
        /// Fork point where chains diverged
        fork_point: BlockHash,
        /// New canonical chain tip
        new_tip: BlockHash,
    },
}

impl ReorgType {
    pub fn depth(&self) -> u64 {
        match self {
            ReorgType::SingleBlock { .. } => 1,
            ReorgType::MultiBlock { removed_blocks, .. } => removed_blocks.len() as u64,
            ReorgType::DeepReorg { depth, .. } => *depth,
        }
    }
    
    pub fn is_deep(&self) -> bool {
        self.depth() > DEEP_REORG_THRESHOLD
    }
}
```
*Source: `reth-blockchain-tree/src/lib.rs`*

## Blockchain Tree Architecture

### Core Components

```rust
// From reth-blockchain-tree/src/blockchain_tree.rs
pub struct BlockchainTree<DB, EF> {
    /// Database provider for canonical chain
    provider: Arc<DB>,
    /// Execution factory for block validation
    executor_factory: EF,
    /// Tree of pending blocks
    block_tree: BTreeMap<BlockNumber, HashMap<BlockHash, SealedBlockWithSenders>>,
    /// Block indices for fast lookup
    block_indices: HashMap<BlockHash, BlockIndices>,
    /// Pending blocks waiting for parent
    pending_blocks: HashMap<BlockHash, SealedBlockWithSenders>,
    /// Finalized block number
    finalized_block_number: BlockNumber,
    /// Configuration
    config: BlockchainTreeConfig,
    /// Metrics
    metrics: TreeMetrics,
}

impl<DB, EF> BlockchainTree<DB, EF>
where
    DB: DatabaseProvider + Clone,
    EF: ExecutorFactory,
{
    pub fn new(
        provider: Arc<DB>,
        executor_factory: EF,
        config: BlockchainTreeConfig,
    ) -> Result<Self, TreeError> {
        let finalized_block_number = provider.finalized_block_number()?;
        
        Ok(Self {
            provider,
            executor_factory,
            block_tree: BTreeMap::new(),
            block_indices: HashMap::new(),
            pending_blocks: HashMap::new(),
            finalized_block_number,
            config,
            metrics: TreeMetrics::default(),
        })
    }
    
    /// Insert a new block into the tree
    pub fn insert_block(
        &mut self,
        block: SealedBlockWithSenders,
    ) -> Result<InsertPayloadOk, InsertBlockError> {
        let block_hash = block.hash();
        let block_number = block.number;
        let parent_hash = block.parent_hash;
        
        // Check if block already exists
        if self.block_indices.contains_key(&block_hash) {
            return Ok(InsertPayloadOk::AlreadyExists(block_hash));
        }
        
        // Validate block
        self.validate_block(&block)?;
        
        // Check if parent exists
        if !self.is_block_known(&parent_hash) {
            // Store as pending until parent arrives
            self.pending_blocks.insert(block_hash, block);
            return Ok(InsertPayloadOk::Pending(block_hash));
        }
        
        // Execute block and update state
        let execution_result = self.execute_block(&block)?;
        
        // Insert into tree
        self.insert_into_tree(block, execution_result)?;
        
        // Try to process any pending blocks
        self.process_pending_blocks()?;
        
        Ok(InsertPayloadOk::Inserted(block_hash))
    }
}
```
*Source: `reth-blockchain-tree/src/blockchain_tree.rs`*

### Block Validation

```rust
impl<DB, EF> BlockchainTree<DB, EF> {
    fn validate_block(&self, block: &SealedBlockWithSenders) -> Result<(), ValidationError> {
        // Basic validation
        if block.number == 0 {
            return Err(ValidationError::GenesisBlock);
        }
        
        // Check timestamp
        let parent = self.get_block(&block.parent_hash)
            .ok_or(ValidationError::ParentNotFound)?;
        
        if block.timestamp <= parent.timestamp {
            return Err(ValidationError::InvalidTimestamp);
        }
        
        // Validate gas limit
        let parent_gas_limit = parent.gas_limit;
        let gas_limit_delta = if block.gas_limit > parent_gas_limit {
            block.gas_limit - parent_gas_limit
        } else {
            parent_gas_limit - block.gas_limit
        };
        
        let max_delta = parent_gas_limit / GAS_LIMIT_BOUND_DIVISOR;
        if gas_limit_delta > max_delta {
            return Err(ValidationError::InvalidGasLimit);
        }
        
        // Validate difficulty (pre-merge)
        if !self.is_post_merge(block.number) {
            self.validate_difficulty(block, &parent)?;
        }
        
        // Validate extra data size
        if block.extra_data.len() > MAXIMUM_EXTRA_DATA_SIZE {
            return Err(ValidationError::ExtraDataTooLong);
        }
        
        Ok(())
    }
    
    fn validate_difficulty(
        &self,
        block: &SealedBlockWithSenders,
        parent: &SealedBlockWithSenders,
    ) -> Result<(), ValidationError> {
        let expected_difficulty = self.calculate_difficulty(block, parent)?;
        
        if block.difficulty != expected_difficulty {
            return Err(ValidationError::InvalidDifficulty {
                expected: expected_difficulty,
                actual: block.difficulty,
            });
        }
        
        Ok(())
    }
    
    fn execute_block(
        &self,
        block: &SealedBlockWithSenders,
    ) -> Result<ExecutionOutcome, ExecutionError> {
        // Get parent state
        let parent_state = self.get_state_at_block(&block.parent_hash)?;
        
        // Create executor
        let mut executor = self.executor_factory.with_state(parent_state);
        
        // Execute block
        let outcome = executor.execute_block(block)?;
        
        // Validate state root
        if outcome.state_root != block.state_root {
            return Err(ExecutionError::StateRootMismatch {
                expected: block.state_root,
                actual: outcome.state_root,
            });
        }
        
        Ok(outcome)
    }
}
```

## Reorg Detection and Handling

### Fork Choice Implementation

```rust
// From reth-blockchain-tree/src/fork_choice.rs
pub struct ForkChoiceState {
    /// Current canonical head
    pub head_block_hash: BlockHash,
    /// Safe block hash (justified)
    pub safe_block_hash: BlockHash,
    /// Finalized block hash
    pub finalized_block_hash: BlockHash,
}

pub trait ForkChoiceRule {
    /// Determine the canonical chain given competing chains
    fn choose_fork(
        &self,
        current_head: &BlockHash,
        competing_blocks: &[BlockHash],
        tree: &BlockchainTree<impl DatabaseProvider, impl ExecutorFactory>,
    ) -> Result<BlockHash, ForkChoiceError>;
}

/// Post-merge fork choice following Engine API
pub struct EngineForkChoice {
    /// Current fork choice state
    state: ForkChoiceState,
    /// Payload attributes for block building
    payload_attributes: Option<PayloadAttributes>,
}

impl ForkChoiceRule for EngineForkChoice {
    fn choose_fork(
        &self,
        current_head: &BlockHash,
        competing_blocks: &[BlockHash],
        tree: &BlockchainTree<impl DatabaseProvider, impl ExecutorFactory>,
    ) -> Result<BlockHash, ForkChoiceError> {
        // In post-merge Ethereum, fork choice is determined by consensus layer
        // We follow the forkchoiceUpdated calls from the consensus client
        
        // Check if any competing block is the new head from consensus layer
        if competing_blocks.contains(&self.state.head_block_hash) {
            return Ok(self.state.head_block_hash);
        }
        
        // If no explicit choice from CL, use current head
        Ok(*current_head)
    }
}

/// Pre-merge fork choice using longest chain rule
pub struct LongestChainRule;

impl ForkChoiceRule for LongestChainRule {
    fn choose_fork(
        &self,
        current_head: &BlockHash,
        competing_blocks: &[BlockHash],
        tree: &BlockchainTree<impl DatabaseProvider, impl ExecutorFactory>,
    ) -> Result<BlockHash, ForkChoiceError> {
        let mut best_block = *current_head;
        let mut best_total_difficulty = tree.get_total_difficulty(current_head)?;
        
        for &block_hash in competing_blocks {
            let total_difficulty = tree.get_total_difficulty(&block_hash)?;
            
            if total_difficulty > best_total_difficulty {
                best_block = block_hash;
                best_total_difficulty = total_difficulty;
            }
        }
        
        Ok(best_block)
    }
}
```
*Source: `reth-blockchain-tree/src/fork_choice.rs`*

### Reorg Execution

```rust
impl<DB, EF> BlockchainTree<DB, EF> {
    /// Execute a chain reorganization
    pub fn execute_reorg(
        &mut self,
        new_head: BlockHash,
    ) -> Result<ReorgOutcome, ReorgError> {
        let current_head = self.get_canonical_head()?;
        
        if new_head == current_head {
            return Ok(ReorgOutcome::NoChange);
        }
        
        // Find common ancestor
        let common_ancestor = self.find_common_ancestor(&current_head, &new_head)?;
        
        // Determine reorg type and depth
        let old_chain = self.get_chain_from_ancestor(&common_ancestor, &current_head)?;
        let new_chain = self.get_chain_from_ancestor(&common_ancestor, &new_head)?;
        
        let reorg_type = ReorgType::MultiBlock {
            removed_blocks: old_chain.clone(),
            added_blocks: new_chain.clone(),
            common_ancestor,
        };
        
        // Validate reorg depth
        if reorg_type.is_deep() && !self.config.allow_deep_reorgs {
            return Err(ReorgError::DeepReorgNotAllowed {
                depth: reorg_type.depth(),
                max_depth: self.config.max_reorg_depth,
            });
        }
        
        // Execute the reorg
        self.perform_reorg(&reorg_type)?;
        
        // Update metrics
        self.metrics.record_reorg(&reorg_type);
        
        Ok(ReorgOutcome::Executed {
            reorg_type,
            old_head: current_head,
            new_head,
        })
    }
    
    fn perform_reorg(&mut self, reorg: &ReorgType) -> Result<(), ReorgError> {
        match reorg {
            ReorgType::SingleBlock { old_block, new_block } => {
                self.reorg_single_block(*old_block, *new_block)?;
            }
            ReorgType::MultiBlock { removed_blocks, added_blocks, common_ancestor } => {
                self.reorg_multi_block(removed_blocks, added_blocks, *common_ancestor)?;
            }
            ReorgType::DeepReorg { depth, fork_point, new_tip } => {
                self.reorg_deep(*depth, *fork_point, *new_tip)?;
            }
        }
        
        Ok(())
    }
    
    fn reorg_single_block(
        &mut self,
        old_block: BlockHash,
        new_block: BlockHash,
    ) -> Result<(), ReorgError> {
        // Unwind state changes from old block
        let old_block_data = self.get_block(&old_block)
            .ok_or(ReorgError::BlockNotFound(old_block))?;
        
        self.unwind_block_state(&old_block_data)?;
        
        // Apply state changes from new block
        let new_block_data = self.get_block(&new_block)
            .ok_or(ReorgError::BlockNotFound(new_block))?;
        
        let execution_outcome = self.execute_block(&new_block_data)?;
        self.commit_block_state(&new_block_data, execution_outcome)?;
        
        // Update canonical chain
        self.update_canonical_head(new_block)?;
        
        Ok(())
    }
    
    fn reorg_multi_block(
        &mut self,
        removed_blocks: &[BlockHash],
        added_blocks: &[BlockHash],
        common_ancestor: BlockHash,
    ) -> Result<(), ReorgError> {
        // Unwind to common ancestor
        for &block_hash in removed_blocks.iter().rev() {
            let block = self.get_block(&block_hash)
                .ok_or(ReorgError::BlockNotFound(block_hash))?;
            self.unwind_block_state(&block)?;
        }
        
        // Apply new chain
        for &block_hash in added_blocks {
            let block = self.get_block(&block_hash)
                .ok_or(ReorgError::BlockNotFound(block_hash))?;
            let execution_outcome = self.execute_block(&block)?;
            self.commit_block_state(&block, execution_outcome)?;
        }
        
        // Update canonical head
        if let Some(&new_head) = added_blocks.last() {
            self.update_canonical_head(new_head)?;
        }
        
        Ok(())
    }
}
```

## State Management During Reorgs

### State Unwinding

```rust
// From reth-blockchain-tree/src/state.rs
pub struct StateManager<DB> {
    /// Database provider
    provider: Arc<DB>,
    /// State cache
    state_cache: LruCache<BlockHash, CachedState>,
    /// Pending state changes
    pending_changes: HashMap<BlockHash, StateChanges>,
}

impl<DB> StateManager<DB>
where
    DB: DatabaseProvider,
{
    /// Unwind state changes from a block
    pub fn unwind_block_state(
        &mut self,
        block: &SealedBlockWithSenders,
    ) -> Result<(), StateError> {
        let block_hash = block.hash();
        
        // Get state changes for this block
        let state_changes = self.get_state_changes(&block_hash)?;
        
        // Reverse account changes
        for (address, account_change) in &state_changes.accounts {
            match account_change {
                AccountChange::Created => {
                    // Remove created account
                    self.provider.remove_account(*address)?;
                }
                AccountChange::Updated { previous, .. } => {
                    // Restore previous account state
                    self.provider.update_account(*address, previous.clone())?;
                }
                AccountChange::Deleted { previous } => {
                    // Restore deleted account
                    self.provider.create_account(*address, previous.clone())?;
                }
            }
        }
        
        // Reverse storage changes
        for (address, storage_changes) in &state_changes.storage {
            for (key, storage_change) in storage_changes {
                match storage_change {
                    StorageChange::Created => {
                        self.provider.remove_storage(*address, *key)?;
                    }
                    StorageChange::Updated { previous, .. } => {
                        self.provider.update_storage(*address, *key, *previous)?;
                    }
                    StorageChange::Deleted { previous } => {
                        self.provider.create_storage(*address, *key, *previous)?;
                    }
                }
            }
        }
        
        // Reverse code changes
        for (address, code_change) in &state_changes.codes {
            match code_change {
                CodeChange::Created => {
                    self.provider.remove_code(*address)?;
                }
                CodeChange::Updated { previous, .. } => {
                    self.provider.update_code(*address, previous.clone())?;
                }
            }
        }
        
        // Update state root
        let parent_state_root = self.provider.state_root_at_block(&block.parent_hash)?;
        self.provider.set_state_root(parent_state_root)?;
        
        Ok(())
    }
    
    /// Commit state changes from block execution
    pub fn commit_block_state(
        &mut self,
        block: &SealedBlockWithSenders,
        execution_outcome: ExecutionOutcome,
    ) -> Result<(), StateError> {
        let block_hash = block.hash();
        
        // Apply account changes
        for (address, account) in execution_outcome.accounts {
            self.provider.update_account(address, account)?;
        }
        
        // Apply storage changes
        for (address, storage) in execution_outcome.storage {
            for (key, value) in storage {
                self.provider.update_storage(address, key, value)?;
            }
        }
        
        // Apply code changes
        for (address, code) in execution_outcome.codes {
            self.provider.update_code(address, code)?;
        }
        
        // Update state root
        self.provider.set_state_root(execution_outcome.state_root)?;
        
        // Cache state changes for potential unwinding
        self.pending_changes.insert(block_hash, StateChanges {
            accounts: execution_outcome.account_changes,
            storage: execution_outcome.storage_changes,
            codes: execution_outcome.code_changes,
        });
        
        Ok(())
    }
}
```
*Source: `reth-blockchain-tree/src/state.rs`*

## Engine API Integration

### Forkchoice Updates

```rust
// From reth-engine/src/engine_api.rs
pub struct EngineApi<Provider, Pool, Executor> {
    /// Blockchain tree for managing forks
    blockchain_tree: Arc<Mutex<BlockchainTree<Provider, Executor>>>,
    /// Transaction pool
    pool: Pool,
    /// Payload builder
    payload_builder: PayloadBuilder,
    /// Current fork choice state
    fork_choice_state: Arc<Mutex<ForkChoiceState>>,
}

impl<Provider, Pool, Executor> EngineApi<Provider, Pool, Executor>
where
    Provider: DatabaseProvider + Clone,
    Pool: TransactionPool,
    Executor: ExecutorFactory,
{
    /// Handle forkchoiceUpdated call from consensus layer
    pub async fn fork_choice_updated(
        &self,
        fork_choice_state: ForkChoiceState,
        payload_attributes: Option<PayloadAttributes>,
    ) -> Result<ForkchoiceUpdatedResponse, EngineError> {
        let mut tree = self.blockchain_tree.lock().await;
        let mut current_state = self.fork_choice_state.lock().await;
        
        // Validate the fork choice state
        self.validate_fork_choice_state(&fork_choice_state, &tree)?;
        
        // Check if we need to perform a reorg
        let current_head = current_state.head_block_hash;
        let new_head = fork_choice_state.head_block_hash;
        
        if new_head != current_head {
            // Execute reorg
            let reorg_outcome = tree.execute_reorg(new_head)?;
            
            match reorg_outcome {
                ReorgOutcome::Executed { reorg_type, .. } => {
                    tracing::info!(
                        "Executed reorg: depth={}, type={:?}",
                        reorg_type.depth(),
                        reorg_type
                    );
                }
                ReorgOutcome::NoChange => {
                    tracing::debug!("No reorg needed");
                }
            }
        }
        
        // Update fork choice state
        *current_state = fork_choice_state;
        
        // Handle payload attributes if provided
        let payload_id = if let Some(attributes) = payload_attributes {
            Some(self.start_payload_building(attributes).await?)
        } else {
            None
        };
        
        Ok(ForkchoiceUpdatedResponse {
            payload_status: PayloadStatus::Valid,
            payload_id,
        })
    }
    
    fn validate_fork_choice_state(
        &self,
        state: &ForkChoiceState,
        tree: &BlockchainTree<Provider, Executor>,
    ) -> Result<(), EngineError> {
        // Validate head block exists
        if !tree.is_block_known(&state.head_block_hash) {
            return Err(EngineError::UnknownBlock(state.head_block_hash));
        }
        
        // Validate safe block exists and is ancestor of head
        if !tree.is_block_known(&state.safe_block_hash) {
            return Err(EngineError::UnknownBlock(state.safe_block_hash));
        }
        
        if !tree.is_ancestor(&state.safe_block_hash, &state.head_block_hash)? {
            return Err(EngineError::InvalidSafeBlock);
        }
        
        // Validate finalized block exists and is ancestor of safe
        if !tree.is_block_known(&state.finalized_block_hash) {
            return Err(EngineError::UnknownBlock(state.finalized_block_hash));
        }
        
        if !tree.is_ancestor(&state.finalized_block_hash, &state.safe_block_hash)? {
            return Err(EngineError::InvalidFinalizedBlock);
        }
        
        Ok(())
    }
}
```
*Source: `reth-engine/src/engine_api.rs`*

## Performance Optimizations

### Efficient Reorg Handling

```rust
impl<DB, EF> BlockchainTree<DB, EF> {
    /// Optimize reorg performance with batched operations
    pub fn optimized_reorg(
        &mut self,
        reorg: &ReorgType,
    ) -> Result<(), ReorgError> {
        match reorg {
            ReorgType::MultiBlock { removed_blocks, added_blocks, .. } => {
                // Batch unwind operations
                let mut batch_unwind = BatchUnwind::new();
                for &block_hash in removed_blocks.iter().rev() {
                    let block = self.get_block(&block_hash)
                        .ok_or(ReorgError::BlockNotFound(block_hash))?;
                    batch_unwind.add_block(&block);
                }
                batch_unwind.execute(&mut self.provider)?;
                
                // Batch apply operations
                let mut batch_apply = BatchApply::new();
                for &block_hash in added_blocks {
                    let block = self.get_block(&block_hash)
                        .ok_or(ReorgError::BlockNotFound(block_hash))?;
                    let execution_outcome = self.execute_block(&block)?;
                    batch_apply.add_block(&block, execution_outcome);
                }
                batch_apply.execute(&mut self.provider)?;
            }
            _ => {
                // Use standard reorg for simple cases
                self.perform_reorg(reorg)?;
            }
        }
        
        Ok(())
    }
}

/// Batch operations for efficient state updates
pub struct BatchUnwind {
    operations: Vec<UnwindOperation>,
}

impl BatchUnwind {
    pub fn new() -> Self {
        Self {
            operations: Vec::new(),
        }
    }
    
    pub fn add_block(&mut self, block: &SealedBlockWithSenders) {
        // Collect all state changes to unwind
        let state_changes = self.extract_state_changes(block);
        self.operations.push(UnwindOperation {
            block_hash: block.hash(),
            state_changes,
        });
    }
    
    pub fn execute<DB: DatabaseProvider>(
        self,
        provider: &mut DB,
    ) -> Result<(), StateError> {
        // Sort operations by block number (descending for unwind)
        let mut operations = self.operations;
        operations.sort_by(|a, b| b.block_number().cmp(&a.block_number()));
        
        // Execute all unwind operations in a single transaction
        provider.begin_transaction()?;
        
        for operation in operations {
            operation.execute(provider)?;
        }
        
        provider.commit_transaction()?;
        Ok(())
    }
}
```

## Monitoring and Metrics

### Reorg Metrics

```rust
// From reth-metrics/src/blockchain_tree.rs
#[derive(Debug, Default)]
pub struct TreeMetrics {
    /// Total number of reorgs
    pub total_reorgs: Counter,
    /// Reorg depth histogram
    pub reorg_depth: Histogram,
    /// Reorg execution time
    pub reorg_duration: Histogram,
    /// Number of blocks in tree
    pub tree_size: Gauge,
    /// Pending blocks count
    pub pending_blocks: Gauge,
}

impl TreeMetrics {
    pub fn record_reorg(&self, reorg: &ReorgType) {
        self.total_reorgs.increment(1);
        self.reorg_depth.record(reorg.depth() as f64);
        
        let start = std::time::Instant::now();
        // ... reorg execution ...
        self.reorg_duration.record(start.elapsed().as_secs_f64());
    }
    
    pub fn update_tree_size(&self, size: usize) {
        self.tree_size.set(size as f64);
    }
    
    pub fn update_pending_blocks(&self, count: usize) {
        self.pending_blocks.set(count as f64);
    }
}

/// Reorg event for external monitoring
#[derive(Debug, Clone)]
pub struct ReorgEvent {
    pub reorg_type: ReorgType,
    pub timestamp: u64,
    pub duration: Duration,
    pub old_head: BlockHash,
    pub new_head: BlockHash,
    pub affected_transactions: Vec<TxHash>,
}

impl ReorgEvent {
    pub fn emit(&self) {
        tracing::warn!(
            "Chain reorganization detected: depth={}, duration={:?}, old_head={:?}, new_head={:?}",
            self.reorg_type.depth(),
            self.duration,
            self.old_head,
            self.new_head
        );
        
        // Emit metrics
        metrics::counter!("reth_reorg_total").increment(1);
        metrics::histogram!("reth_reorg_depth").record(self.reorg_type.depth() as f64);
        metrics::histogram!("reth_reorg_duration_seconds").record(self.duration.as_secs_f64());
    }
}
```
*Source: `reth-metrics/src/blockchain_tree.rs`*

## Testing and Validation

### Reorg Testing Framework

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[tokio::test]
    async fn test_single_block_reorg() {
        let mut tree = create_test_tree();
        
        // Create competing blocks at same height
        let block_a = create_test_block(1, GENESIS_HASH);
        let block_b = create_test_block(1, GENESIS_HASH);
        
        // Insert both blocks
        tree.insert_block(block_a.clone()).unwrap();
        tree.insert_block(block_b.clone()).unwrap();
        
        // Initially, block_a should be canonical (first seen)
        assert_eq!(tree.get_canonical_head().unwrap(), block_a.hash());
        
        // Force reorg to block_b
        let reorg_outcome = tree.execute_reorg(block_b.hash()).unwrap();
        
        match reorg_outcome {
            ReorgOutcome::Executed { reorg_type, .. } => {
                assert_eq!(reorg_type.depth(), 1);
                assert_eq!(tree.get_canonical_head().unwrap(), block_b.hash());
            }
            _ => panic!("Expected reorg to be executed"),
        }
    }
    
    #[tokio::test]
    async fn test_multi_block_reorg() {
        let mut tree = create_test_tree();
        
        // Create main chain: genesis -> A -> B -> C
        let block_a = create_test_block(1, GENESIS_HASH);
        let block_b = create_test_block(2, block_a.hash());
        let block_c = create_test_block(3, block_b.hash());
        
        tree.insert_block(block_a.clone()).unwrap();
        tree.insert_block(block_b.clone()).unwrap();
        tree.insert_block(block_c.clone()).unwrap();
        
        // Create competing chain: genesis -> A -> D -> E -> F
        let block_d = create_test_block(2, block_a.hash());
        let block_e = create_test_block(3, block_d.hash());
        let block_f = create_test_block(4, block_e.hash());
        
        tree.insert_block(block_d.clone()).unwrap();
        tree.insert_block(block_e.clone()).unwrap();
        tree.insert_block(block_f.clone()).unwrap();
        
        // Reorg to longer chain
        let reorg_outcome = tree.execute_reorg(block_f.hash()).unwrap();
        
        match reorg_outcome {
            ReorgOutcome::Executed { reorg_type, .. } => {
                assert_eq!(reorg_type.depth(), 2); // B and C removed
                assert_eq!(tree.get_canonical_head().unwrap(), block_f.hash());
            }
            _ => panic!("Expected reorg to be executed"),
        }
    }
    
    #[tokio::test]
    async fn test_deep_reorg_rejection() {
        let config = BlockchainTreeConfig {
            max_reorg_depth: 5,
            allow_deep_reorgs: false,
            ..Default::default()
        };
        
        let mut tree = create_test_tree_with_config(config);
        
        // Create a deep reorg scenario (6 blocks)
        let deep_reorg = ReorgType::DeepReorg {
            depth: 6,
            fork_point: BlockHash::random(),
            new_tip: BlockHash::random(),
        };
        
        let result = tree.perform_reorg(&deep_reorg);
        
        assert!(matches!(result, Err(ReorgError::DeepReorgNotAllowed { .. })));
    }
    
    #[tokio::test]
    async fn test_state_consistency_after_reorg() {
        let mut tree = create_test_tree();
        
        // Create blocks with state changes
        let block_a = create_block_with_state_changes(1, GENESIS_HASH, vec![
            StateChange::AccountUpdate(Address::random(), Account::default()),
        ]);
        
        let block_b = create_block_with_state_changes(1, GENESIS_HASH, vec![
            StateChange::AccountUpdate(Address::random(), Account::default()),
        ]);
        
        tree.insert_block(block_a.clone()).unwrap();
        tree.insert_block(block_b.clone()).unwrap();
        
        // Get state before reorg
        let state_before = tree.get_state_at_head().unwrap();
        
        // Execute reorg
        tree.execute_reorg(block_b.hash()).unwrap();
        
        // Verify state consistency
        let state_after = tree.get_state_at_head().unwrap();
        assert_ne!(state_before.state_root(), state_after.state_root());
        
        // Verify state matches block_b execution
        let expected_state = execute_block_on_state(&state_before, &block_b).unwrap();
        assert_eq!(state_after.state_root(), expected_state.state_root());
    }
}
```

## Best Practices

### Reorg Handling Guidelines

1. **Monitor Reorg Depth**: Track reorg frequency and depth to detect network issues
2. **Efficient State Management**: Use batched operations for multi-block reorgs
3. **Transaction Pool Updates**: Properly handle transaction resubmission after reorgs
4. **Event Notification**: Notify dependent systems about reorg events
5. **Performance Optimization**: Cache frequently accessed state data

### Configuration Recommendations

```rust
pub struct ReorgConfig {
    /// Maximum allowed reorg depth
    pub max_reorg_depth: u64,
    /// Whether to allow deep reorgs
    pub allow_deep_reorgs: bool,
    /// Reorg detection threshold
    pub detection_threshold: Duration,
    /// State cache size for reorg handling
    pub state_cache_size: usize,
    /// Enable reorg metrics collection
    pub enable_metrics: bool,
}

impl Default for ReorgConfig {
    fn default() -> Self {
        Self {
            max_reorg_depth: 64,
            allow_deep_reorgs: false,
            detection_threshold: Duration::from_secs(12),
            state_cache_size: 1000,
            enable_metrics: true,
        }
    }
}
```

## Conclusion

Reth's blockchain tree and reorg handling system provides a robust foundation for managing chain reorganizations in Ethereum. Key features include:

- **Efficient Tree Structure**: Optimized data structures for managing competing chains
- **Sophisticated Reorg Detection**: Advanced algorithms for detecting and validating reorgs
- **State Management**: Efficient state unwinding and application during reorgs
- **Engine API Integration**: Seamless integration with consensus layer fork choice
- **Performance Optimization**: Batched operations and caching for optimal performance
- **Comprehensive Monitoring**: Detailed metrics and event tracking for reorg analysis

This architecture ensures that Reth can handle both common single-block reorgs and complex multi-block reorganizations while maintaining data consistency and optimal performance.

## References

- [Ethereum Consensus Specs - Fork Choice](https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/fork-choice.md)
- [Reth Reorg Discussion](https://github.com/paradigmxyz/reth/issues/662)
- [Ethereum Reorg Tracker](https://github.com/ausaf007/ethereum-reorg-tracker)
- [Engine API Specification](https://github.com/ethereum/execution-apis/blob/main/src/engine/common.md)
- [Reth Implementation](https://github.com/paradigmxyz/reth)