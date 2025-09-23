# BlockExecutor Bridge: Connecting Reth and REVM

## Overview

The BlockExecutor serves as the critical bridge between Reth's blockchain infrastructure and REVM's execution engine. This component orchestrates the execution of entire blocks, managing the complex process of transaction processing, state updates, and receipt generation while maintaining consistency with Ethereum's execution model.

## BlockExecutor Architecture

### Core Traits and Interfaces

```rust
// From reth-evm/src/execute.rs
pub trait BlockExecutor<DB> {
    type Error: From<ProviderError> + std::error::Error;
    type Receipt;
    type Output;

    fn execute_block(
        &mut self,
        block: &BlockWithSenders,
        total_difficulty: U256,
    ) -> Result<Self::Output, Self::Error>;

    fn execute_transactions(
        &mut self,
        block: &BlockWithSenders,
        total_difficulty: U256,
    ) -> Result<Vec<Self::Receipt>, Self::Error>;

    fn take_output_state(&mut self) -> BundleState;
}

pub trait BatchBlockExecutor<DB>: BlockExecutor<DB> {
    type BatchError: From<Self::Error>;

    fn execute_batch(
        &mut self,
        blocks: impl Iterator<Item = &BlockWithSenders>,
    ) -> Result<Vec<Self::Output>, Self::BatchError>;
}
```
*Source: `reth-evm/src/execute.rs`*

### Execution Output Types

```rust
// From reth-evm/src/execute.rs
#[derive(Debug, Clone)]
pub struct ExecutionOutput {
    pub receipts: Vec<Receipt>,
    pub gas_used: u64,
    pub state: BundleState,
    pub requests: Vec<Request>,
}

#[derive(Debug, Clone)]
pub struct BundleState {
    pub state: HashMap<Address, BundleAccount>,
    pub contracts: HashMap<B256, Bytecode>,
    pub reverts: HashMap<u64, HashMap<Address, RevertToSlot>>,
    pub state_size: usize,
}

#[derive(Debug, Clone)]
pub struct BundleAccount {
    pub info: Option<AccountInfo>,
    pub original_info: Option<AccountInfo>,
    pub storage: HashMap<U256, StorageSlot>,
    pub status: AccountStatus,
}
```
*Source: `reth-evm/src/execute.rs`*

## Reth's BlockExecutor Implementation

### EthBlockExecutor Structure

```rust
// From reth-ethereum-forks/src/executor.rs
pub struct EthBlockExecutor<EvmConfig, DB> {
    /// The EVM configuration.
    evm_config: EvmConfig,
    /// Current state for block execution.
    state: State<DB>,
    /// The consensus instance used for verification.
    consensus: Arc<dyn Consensus>,
    /// Requests collected during block execution.
    requests: Vec<Request>,
}

impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB>
where
    EvmConfig: ConfigureEvm,
    DB: Database<Error = ProviderError>,
{
    pub fn new(
        evm_config: EvmConfig,
        state: State<DB>,
        consensus: Arc<dyn Consensus>,
    ) -> Self {
        Self {
            evm_config,
            state,
            consensus,
            requests: Vec::new(),
        }
    }

    fn configure_evm_env(
        &self,
        header: &Header,
        total_difficulty: U256,
    ) -> EvmEnv {
        let mut env = EvmEnv::default();
        
        // Configure block environment
        env.block.number = U256::from(header.number);
        env.block.coinbase = header.beneficiary;
        env.block.timestamp = U256::from(header.timestamp);
        env.block.gas_limit = U256::from(header.gas_limit);
        env.block.basefee = U256::from(header.base_fee_per_gas.unwrap_or_default());
        env.block.difficulty = header.difficulty;
        env.block.prevrandao = header.mix_hash;
        
        // Configure chain-specific settings
        env.cfg.chain_id = self.evm_config.chain_id();
        env.cfg.spec_id = self.evm_config.spec_id_at_timestamp(header.timestamp);
        
        env
    }
}
```
*Source: `reth-ethereum-forks/src/executor.rs`*

### Block Execution Implementation

```rust
impl<EvmConfig, DB> BlockExecutor<DB> for EthBlockExecutor<EvmConfig, DB>
where
    EvmConfig: ConfigureEvm,
    DB: Database<Error = ProviderError>,
{
    type Error = BlockExecutionError;
    type Receipt = Receipt;
    type Output = ExecutionOutput;

    fn execute_block(
        &mut self,
        block: &BlockWithSenders,
        total_difficulty: U256,
    ) -> Result<Self::Output, Self::Error> {
        // Pre-execution validation
        self.validate_block_pre_execution(block)?;
        
        // Configure EVM environment
        let env = self.configure_evm_env(&block.header, total_difficulty);
        
        // Execute all transactions
        let receipts = self.execute_transactions(block, total_difficulty)?;
        
        // Calculate gas used
        let gas_used = receipts.last()
            .map(|receipt| receipt.cumulative_gas_used)
            .unwrap_or_default();
        
        // Validate gas usage
        if gas_used != block.header.gas_used {
            return Err(BlockExecutionError::BlockGasUsedMismatch {
                expected: block.header.gas_used,
                actual: gas_used,
            });
        }
        
        // Process system calls (withdrawals, etc.)
        self.process_system_calls(block)?;
        
        // Collect requests (EIP-7685)
        let requests = std::mem::take(&mut self.requests);
        
        // Get final state
        let state = self.take_output_state();
        
        Ok(ExecutionOutput {
            receipts,
            gas_used,
            state,
            requests,
        })
    }

    fn execute_transactions(
        &mut self,
        block: &BlockWithSenders,
        total_difficulty: U256,
    ) -> Result<Vec<Self::Receipt>, Self::Error> {
        let mut receipts = Vec::with_capacity(block.body.len());
        let mut cumulative_gas_used = 0u64;
        
        // Configure base EVM environment
        let mut env = self.configure_evm_env(&block.header, total_difficulty);
        
        for (transaction, sender) in block.transactions_with_sender() {
            // Configure transaction environment
            self.configure_tx_env(&mut env.tx, transaction, *sender)?;
            
            // Create EVM instance
            let mut evm = self.evm_config.evm_with_env(&mut self.state, env.clone());
            
            // Execute transaction
            let result = evm.transact()?;
            
            // Process execution result
            let gas_used = result.result.gas_used();
            cumulative_gas_used += gas_used;
            
            // Create receipt
            let receipt = self.create_receipt(
                transaction,
                &result,
                cumulative_gas_used,
                &result.state,
            )?;
            
            receipts.push(receipt);
            
            // Apply state changes
            self.state.commit(result.state);
            
            // Collect any requests from this transaction
            self.collect_requests_from_result(&result);
        }
        
        Ok(receipts)
    }

    fn take_output_state(&mut self) -> BundleState {
        self.state.take_bundle()
    }
}
```
*Source: `reth-ethereum-forks/src/executor.rs`*

## Transaction Environment Configuration

### Transaction Environment Setup

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn configure_tx_env(
        &self,
        tx_env: &mut TxEnv,
        transaction: &TransactionSigned,
        sender: Address,
    ) -> Result<(), BlockExecutionError> {
        // Basic transaction fields
        tx_env.caller = sender;
        tx_env.gas_limit = transaction.gas_limit();
        tx_env.gas_price = U256::from(transaction.gas_price());
        tx_env.value = transaction.value();
        tx_env.data = transaction.input().clone();
        tx_env.nonce = Some(transaction.nonce());
        tx_env.chain_id = transaction.chain_id();
        
        // Configure transaction type specific fields
        match transaction.transaction {
            Transaction::Legacy(_) => {
                // Legacy transaction - no additional configuration needed
            }
            Transaction::Eip2930(ref tx) => {
                tx_env.access_list = tx.access_list.clone();
            }
            Transaction::Eip1559(ref tx) => {
                tx_env.access_list = tx.access_list.clone();
                tx_env.gas_priority_fee = Some(U256::from(tx.max_priority_fee_per_gas));
                tx_env.gas_price = U256::from(tx.max_fee_per_gas);
            }
            Transaction::Eip4844(ref tx) => {
                tx_env.access_list = tx.access_list.clone();
                tx_env.gas_priority_fee = Some(U256::from(tx.max_priority_fee_per_gas));
                tx_env.gas_price = U256::from(tx.max_fee_per_gas);
                tx_env.blob_hashes = tx.blob_versioned_hashes.clone();
                tx_env.max_fee_per_blob_gas = Some(U256::from(tx.max_fee_per_blob_gas));
            }
        }
        
        // Set transaction destination
        tx_env.transact_to = match transaction.to() {
            Some(to) => TransactTo::Call(to),
            None => TransactTo::Create(CreateScheme::Create),
        };
        
        Ok(())
    }
}
```

### Receipt Generation

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn create_receipt(
        &self,
        transaction: &TransactionSigned,
        result: &ResultAndState,
        cumulative_gas_used: u64,
        state: &EvmState,
    ) -> Result<Receipt, BlockExecutionError> {
        // Determine transaction success
        let success = result.result.is_success();
        
        // Create logs from the execution result
        let logs = result.result.logs().iter().cloned().collect();
        
        // Calculate bloom filter
        let logs_bloom = logs_bloom(&logs);
        
        // Create base receipt
        let mut receipt = Receipt {
            tx_type: transaction.tx_type(),
            success,
            cumulative_gas_used,
            logs,
        };
        
        // Add transaction type specific fields
        match transaction.tx_type() {
            TxType::Legacy => {
                // Legacy receipts include state root (pre-Byzantium) or status (post-Byzantium)
                if self.is_byzantium_active() {
                    receipt.success = success;
                } else {
                    // Pre-Byzantium: include state root
                    receipt.state_root = Some(self.compute_state_root(state)?);
                }
            }
            TxType::Eip2930 | TxType::Eip1559 => {
                // EIP-2930 and EIP-1559 transactions always include status
                receipt.success = success;
            }
            TxType::Eip4844 => {
                // EIP-4844 transactions include status and blob gas used
                receipt.success = success;
                if let Some(blob_gas_used) = self.calculate_blob_gas_used(transaction) {
                    receipt.blob_gas_used = Some(blob_gas_used);
                }
            }
        }
        
        Ok(receipt)
    }
    
    fn calculate_blob_gas_used(&self, transaction: &TransactionSigned) -> Option<u64> {
        if let Transaction::Eip4844(ref tx) = transaction.transaction {
            Some(tx.blob_versioned_hashes.len() as u64 * DATA_GAS_PER_BLOB)
        } else {
            None
        }
    }
}
```

## State Management

### Bundle State Operations

```rust
// From reth-execution-types/src/bundle_state.rs
impl BundleState {
    pub fn new() -> Self {
        Self {
            state: HashMap::new(),
            contracts: HashMap::new(),
            reverts: HashMap::new(),
            state_size: 0,
        }
    }
    
    pub fn apply_revm_state(&mut self, revm_state: EvmState) {
        for (address, account) in revm_state {
            let bundle_account = self.state.entry(address).or_default();
            
            // Update account info
            if let Some(info) = account.info {
                bundle_account.info = Some(info);
            }
            
            // Update storage
            for (key, slot) in account.storage {
                if slot.is_changed() {
                    bundle_account.storage.insert(key, slot);
                }
            }
            
            // Update account status
            bundle_account.status = account.status;
        }
        
        // Update size tracking
        self.update_size();
    }
    
    pub fn revert_to(&mut self, revert_id: u64) -> Result<(), BundleStateError> {
        if let Some(reverts) = self.reverts.remove(&revert_id) {
            for (address, revert_info) in reverts {
                if let Some(account) = self.state.get_mut(&address) {
                    // Revert account changes
                    account.info = revert_info.account;
                    
                    // Revert storage changes
                    for (key, original_value) in revert_info.storage {
                        if let Some(original) = original_value {
                            account.storage.insert(key, StorageSlot {
                                previous_or_original_value: original,
                                present_value: original,
                            });
                        } else {
                            account.storage.remove(&key);
                        }
                    }
                    
                    // Update status
                    account.status = revert_info.previous_status;
                }
            }
        }
        
        Ok(())
    }
    
    fn update_size(&mut self) {
        self.state_size = self.state.len() + 
                         self.contracts.len() + 
                         self.reverts.values().map(|r| r.len()).sum::<usize>();
    }
}
```

### State Commitment

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn commit_state_changes(&mut self, state: EvmState) -> Result<(), BlockExecutionError> {
        // Apply changes to the database state
        for (address, account) in state {
            match account.status {
                AccountStatus::Loaded | AccountStatus::Created => {
                    // Update or create account
                    if let Some(info) = account.info {
                        self.state.set_account(address, info);
                    }
                    
                    // Update storage
                    for (key, slot) in account.storage {
                        if slot.is_changed() {
                            self.state.set_storage(address, key, slot.present_value);
                        }
                    }
                }
                AccountStatus::SelfDestructed => {
                    // Remove account and all its storage
                    self.state.remove_account(address);
                }
                AccountStatus::Touched => {
                    // Account was touched but not modified significantly
                    // Update only if there are actual changes
                    if account.is_changed() {
                        if let Some(info) = account.info {
                            self.state.set_account(address, info);
                        }
                    }
                }
                _ => {
                    // No changes needed for other statuses
                }
            }
        }
        
        Ok(())
    }
}
```

## System Calls and Withdrawals

### Withdrawal Processing

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn process_system_calls(&mut self, block: &BlockWithSenders) -> Result<(), BlockExecutionError> {
        // Process withdrawals (EIP-4895)
        if let Some(withdrawals) = &block.withdrawals {
            self.process_withdrawals(withdrawals)?;
        }
        
        // Process other system calls as needed
        self.process_beacon_root_contract_call(block)?;
        
        Ok(())
    }
    
    fn process_withdrawals(&mut self, withdrawals: &[Withdrawal]) -> Result<(), BlockExecutionError> {
        for withdrawal in withdrawals {
            // Get current account balance
            let current_balance = self.state
                .basic_account(withdrawal.address)?
                .map(|acc| acc.balance)
                .unwrap_or_default();
            
            // Add withdrawal amount
            let new_balance = current_balance + withdrawal.amount_wei();
            
            // Update account balance
            let mut account_info = AccountInfo {
                balance: new_balance,
                nonce: 0, // Withdrawals don't affect nonce
                code_hash: KECCAK_EMPTY,
                code: None,
            };
            
            // If account exists, preserve existing nonce and code
            if let Some(existing) = self.state.basic_account(withdrawal.address)? {
                account_info.nonce = existing.nonce;
                account_info.code_hash = existing.code_hash;
            }
            
            self.state.set_account(withdrawal.address, account_info);
        }
        
        Ok(())
    }
    
    fn process_beacon_root_contract_call(&mut self, block: &BlockWithSenders) -> Result<(), BlockExecutionError> {
        // EIP-4788: Beacon block root in the EVM
        if let Some(parent_beacon_block_root) = block.header.parent_beacon_block_root {
            let beacon_roots_address = Address::from_slice(&[0x00; 20]); // Placeholder
            
            // Create system transaction to update beacon root
            let mut tx_env = TxEnv {
                caller: Address::ZERO,
                gas_limit: 30_000_000,
                gas_price: U256::ZERO,
                transact_to: TransactTo::Call(beacon_roots_address),
                value: U256::ZERO,
                data: parent_beacon_block_root.as_bytes().into(),
                nonce: None,
                chain_id: None,
                access_list: Vec::new(),
                gas_priority_fee: None,
                blob_hashes: Vec::new(),
                max_fee_per_blob_gas: None,
            };
            
            // Execute system call
            let mut env = self.configure_evm_env(&block.header, U256::ZERO);
            env.tx = tx_env;
            
            let mut evm = self.evm_config.evm_with_env(&mut self.state, env);
            let result = evm.transact()?;
            
            // Apply state changes from system call
            self.state.commit(result.state);
        }
        
        Ok(())
    }
}
```

## Error Handling and Recovery

### Comprehensive Error Types

```rust
// From reth-evm/src/execute.rs
#[derive(Debug, thiserror::Error)]
pub enum BlockExecutionError {
    #[error("Provider error: {0}")]
    Provider(#[from] ProviderError),
    
    #[error("EVM error: {0}")]
    Evm(#[from] EVMError<ProviderError>),
    
    #[error("Block gas used mismatch: expected {expected}, actual {actual}")]
    BlockGasUsedMismatch { expected: u64, actual: u64 },
    
    #[error("Invalid transaction at index {index}: {reason}")]
    InvalidTransaction { index: usize, reason: String },
    
    #[error("State root mismatch: expected {expected}, computed {computed}")]
    StateRootMismatch { expected: B256, computed: B256 },
    
    #[error("Receipt root mismatch: expected {expected}, computed {computed}")]
    ReceiptRootMismatch { expected: B256, computed: B256 },
    
    #[error("Consensus validation failed: {0}")]
    ConsensusValidation(String),
    
    #[error("System call failed: {0}")]
    SystemCall(String),
}
```

### Error Recovery Strategies

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn execute_with_recovery(
        &mut self,
        block: &BlockWithSenders,
        total_difficulty: U256,
    ) -> Result<ExecutionOutput, BlockExecutionError> {
        // Create checkpoint for potential rollback
        let checkpoint = self.state.checkpoint();
        
        match self.execute_block(block, total_difficulty) {
            Ok(output) => {
                // Execution successful, commit changes
                self.state.commit_checkpoint(checkpoint);
                Ok(output)
            }
            Err(error) => {
                // Execution failed, rollback to checkpoint
                self.state.revert_checkpoint(checkpoint);
                
                // Attempt recovery based on error type
                match &error {
                    BlockExecutionError::InvalidTransaction { index, .. } => {
                        // Try executing without the problematic transaction
                        warn!("Skipping invalid transaction at index {}", index);
                        self.execute_block_skip_transaction(block, *index, total_difficulty)
                    }
                    BlockExecutionError::StateRootMismatch { .. } => {
                        // State root mismatch might be due to a bug in state calculation
                        // Log the error and continue with computed state
                        warn!("State root mismatch detected: {}", error);
                        self.execute_block_ignore_state_root(block, total_difficulty)
                    }
                    _ => {
                        // For other errors, propagate up
                        Err(error)
                    }
                }
            }
        }
    }
}
```

## Performance Optimizations

### Parallel Transaction Validation

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn validate_transactions_parallel(
        &self,
        block: &BlockWithSenders,
    ) -> Result<(), BlockExecutionError> {
        use rayon::prelude::*;
        
        // Validate transactions in parallel
        let validation_results: Result<Vec<_>, _> = block
            .transactions_with_sender()
            .par_iter()
            .enumerate()
            .map(|(index, (tx, sender))| {
                self.validate_transaction(tx, *sender)
                    .map_err(|e| BlockExecutionError::InvalidTransaction {
                        index,
                        reason: e.to_string(),
                    })
            })
            .collect();
        
        validation_results?;
        Ok(())
    }
    
    fn validate_transaction(
        &self,
        transaction: &TransactionSigned,
        sender: Address,
    ) -> Result<(), TransactionValidationError> {
        // Basic signature validation
        if transaction.recover_signer() != Some(sender) {
            return Err(TransactionValidationError::InvalidSignature);
        }
        
        // Gas limit validation
        if transaction.gas_limit() > MAX_TRANSACTION_GAS_LIMIT {
            return Err(TransactionValidationError::GasLimitTooHigh);
        }
        
        // Chain ID validation
        if let Some(chain_id) = transaction.chain_id() {
            if chain_id != self.evm_config.chain_id() {
                return Err(TransactionValidationError::InvalidChainId);
            }
        }
        
        Ok(())
    }
}
```

### State Caching

```rust
pub struct CachedState<DB> {
    db: DB,
    account_cache: LruCache<Address, Option<AccountInfo>>,
    storage_cache: LruCache<(Address, U256), U256>,
    code_cache: LruCache<B256, Bytecode>,
}

impl<DB: Database> Database for CachedState<DB> {
    type Error = DB::Error;
    
    fn basic(&mut self, address: Address) -> Result<Option<AccountInfo>, Self::Error> {
        if let Some(cached) = self.account_cache.get(&address) {
            return Ok(cached.clone());
        }
        
        let account = self.db.basic(address)?;
        self.account_cache.put(address, account.clone());
        Ok(account)
    }
    
    fn storage(&mut self, address: Address, index: U256) -> Result<U256, Self::Error> {
        let key = (address, index);
        if let Some(&cached) = self.storage_cache.get(&key) {
            return Ok(cached);
        }
        
        let value = self.db.storage(address, index)?;
        self.storage_cache.put(key, value);
        Ok(value)
    }
    
    fn code_by_hash(&mut self, code_hash: B256) -> Result<Bytecode, Self::Error> {
        if let Some(cached) = self.code_cache.get(&code_hash) {
            return Ok(cached.clone());
        }
        
        let code = self.db.code_by_hash(code_hash)?;
        self.code_cache.put(code_hash, code.clone());
        Ok(code)
    }
    
    fn block_hash(&mut self, number: U256) -> Result<B256, Self::Error> {
        // Block hashes are typically cached at a higher level
        self.db.block_hash(number)
    }
}
```

## Testing and Validation

### Block Execution Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_block_execution() {
        let db = create_test_db();
        let consensus = Arc::new(TestConsensus::new());
        let evm_config = TestEvmConfig::new();
        
        let mut executor = EthBlockExecutor::new(
            evm_config,
            State::new(db),
            consensus,
        );
        
        let block = create_test_block_with_transactions();
        let total_difficulty = U256::from(1000);
        
        let result = executor.execute_block(&block, total_difficulty).unwrap();
        
        // Verify execution results
        assert_eq!(result.receipts.len(), block.body.len());
        assert_eq!(result.gas_used, block.header.gas_used);
        
        // Verify state changes
        let state = result.state;
        assert!(!state.state.is_empty());
        
        // Verify receipts
        for (i, receipt) in result.receipts.iter().enumerate() {
            assert!(receipt.cumulative_gas_used > 0);
            if i > 0 {
                assert!(receipt.cumulative_gas_used >= result.receipts[i-1].cumulative_gas_used);
            }
        }
    }
    
    #[test]
    fn test_withdrawal_processing() {
        let db = create_test_db();
        let consensus = Arc::new(TestConsensus::new());
        let evm_config = TestEvmConfig::new();
        
        let mut executor = EthBlockExecutor::new(
            evm_config,
            State::new(db),
            consensus,
        );
        
        let withdrawals = vec![
            Withdrawal {
                index: 0,
                validator_index: 1,
                address: Address::random(),
                amount: 1000,
            }
        ];
        
        executor.process_withdrawals(&withdrawals).unwrap();
        
        // Verify withdrawal was processed
        let account = executor.state.basic_account(withdrawals[0].address).unwrap().unwrap();
        assert_eq!(account.balance, U256::from(withdrawals[0].amount_wei()));
    }
}
```

## Best Practices

### Configuration Guidelines

1. **EVM Configuration**: Ensure proper SpecId and chain configuration
2. **State Management**: Use appropriate caching strategies for performance
3. **Error Handling**: Implement comprehensive error recovery mechanisms
4. **Resource Limits**: Set appropriate gas and memory limits

### Performance Optimization

1. **Parallel Validation**: Validate transactions in parallel when possible
2. **State Caching**: Implement intelligent caching for frequently accessed state
3. **Batch Processing**: Process multiple blocks efficiently in batch mode
4. **Memory Management**: Monitor and optimize memory usage during execution

## Conclusion

The BlockExecutor bridge is a critical component that seamlessly integrates REVM's execution capabilities with Reth's blockchain infrastructure. It provides:

- **Complete Block Processing**: Handles all aspects of block execution including transactions, system calls, and state updates
- **Type Safety**: Leverages Rust's type system for safe and reliable execution
- **Performance**: Optimized for high-throughput block processing
- **Flexibility**: Supports various transaction types and Ethereum protocol upgrades
- **Error Recovery**: Comprehensive error handling and recovery mechanisms

This design enables Reth to achieve exceptional execution performance while maintaining full compatibility with Ethereum's execution model and providing the modularity needed for future protocol upgrades.

## References

- [Reth EVM Execution](https://github.com/paradigmxyz/reth)
- [REVM Documentation](https://github.com/bluealloy/revm)
- [Ethereum Execution Specification](https://ethereum.github.io/execution-specs/)
- [EIP-4895: Beacon Chain Push Withdrawals](https://eips.ethereum.org/EIPS/eip-4895)
- [EIP-4788: Beacon Block Root in the EVM](https://eips.ethereum.org/EIPS/eip-4788)