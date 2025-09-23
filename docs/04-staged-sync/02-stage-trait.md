# The Stage Trait: Interface Design for Modular Sync

## Overview

<mcreference link="https://github.com/paradigmxyz/reth/blob/main/docs/crates/stages.md" index="1">1</mcreference> The Stage trait is the fundamental interface that defines how individual stages operate within Reth's staged sync pipeline. Each stage implements this trait, providing function interfaces to get the stage ID, execute the stage, and unwind changes to the database if issues occur during stage execution.

## Stage Trait Definition

### Core Interface

```rust
// From stages/src/stage.rs
#[async_trait]
pub trait Stage<DB>: Send + Sync
where
    DB: Database,
{
    /// Returns the unique identifier for this stage
    fn id(&self) -> StageId;
    
    /// Execute the stage with the given input
    async fn execute(
        &mut self,
        provider: &DatabaseProviderRW<DB>,
        input: ExecInput,
    ) -> Result<ExecOutput, StageError>;
    
    /// Unwind the stage to the given block number
    async fn unwind(
        &mut self,
        provider: &DatabaseProviderRW<DB>,
        input: UnwindInput,
    ) -> Result<UnwindOutput, StageError>;
    
    /// Get the current checkpoint for this stage
    fn get_checkpoint(&self, provider: &DatabaseProviderRO<DB>) -> Result<StageCheckpoint, StageError> {
        provider.get_stage_checkpoint(self.id())
            .map_err(StageError::Database)
    }
    
    /// Update the checkpoint for this stage
    fn save_checkpoint(
        &self,
        provider: &DatabaseProviderRW<DB>,
        checkpoint: StageCheckpoint,
    ) -> Result<(), StageError> {
        provider.save_stage_checkpoint(self.id(), checkpoint)
            .map_err(StageError::Database)
    }
}
```
*Source: `stages/src/stage.rs`*

### Stage Identification

```rust
// Stage identifiers for tracking and metrics
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum StageId {
    Headers,
    Bodies,
    SenderRecovery,
    Execution,
    MerkleExecute,
    AccountHashing,
    StorageHashing,
    MerkleUnwind,
    TransactionLookup,
    IndexAccountHistory,
    IndexStorageHistory,
    Finish,
}

impl StageId {
    /// Returns a human-readable name for the stage
    pub fn name(&self) -> &'static str {
        match self {
            StageId::Headers => "Headers",
            StageId::Bodies => "Bodies", 
            StageId::SenderRecovery => "SenderRecovery",
            StageId::Execution => "Execution",
            StageId::MerkleExecute => "MerkleExecute",
            StageId::AccountHashing => "AccountHashing",
            StageId::StorageHashing => "StorageHashing",
            StageId::MerkleUnwind => "MerkleUnwind",
            StageId::TransactionLookup => "TransactionLookup",
            StageId::IndexAccountHistory => "IndexAccountHistory",
            StageId::IndexStorageHistory => "IndexStorageHistory",
            StageId::Finish => "Finish",
        }
    }
}
```
*Source: `stages/src/stage.rs`*

## Input and Output Types

### Execution Input

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExecInput {
    /// The target block number to sync to
    pub target: Option<BlockNumber>,
    /// The current checkpoint of the stage
    pub checkpoint: StageCheckpoint,
}

impl ExecInput {
    /// Returns the target block number, defaulting to the checkpoint if None
    pub fn target(&self) -> BlockNumber {
        self.target.unwrap_or(self.checkpoint.block_number)
    }
    
    /// Returns the next block number to process
    pub fn next_block(&self) -> BlockNumber {
        self.checkpoint.block_number + 1
    }
    
    /// Returns the range of blocks to process
    pub fn block_range(&self) -> RangeInclusive<BlockNumber> {
        self.next_block()..=self.target()
    }
}
```
*Source: `stages/src/stage.rs`*

### Execution Output

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExecOutput {
    /// The updated checkpoint after execution
    pub checkpoint: StageCheckpoint,
    /// Whether the stage has completed its work
    pub done: bool,
}

impl ExecOutput {
    /// Create output indicating the stage is complete
    pub fn done(checkpoint: StageCheckpoint) -> Self {
        Self {
            checkpoint,
            done: true,
        }
    }
    
    /// Create output indicating the stage needs more work
    pub fn progress(checkpoint: StageCheckpoint) -> Self {
        Self {
            checkpoint,
            done: false,
        }
    }
}
```
*Source: `stages/src/stage.rs`*

### Unwind Input and Output

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UnwindInput {
    /// The block number to unwind to
    pub unwind_to: BlockNumber,
    /// The current checkpoint of the stage
    pub checkpoint: StageCheckpoint,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UnwindOutput {
    /// The updated checkpoint after unwinding
    pub checkpoint: StageCheckpoint,
}
```
*Source: `stages/src/stage.rs`*

## Stage Implementation Examples

### Header Stage Implementation

```rust
// From stages/src/stages/headers.rs
pub struct HeaderStage<D> {
    downloader: D,
    consensus: Arc<dyn Consensus>,
    commit_threshold: u64,
}

#[async_trait]
impl<DB, D> Stage<DB> for HeaderStage<D>
where
    DB: Database,
    D: HeaderDownloader + Send + Sync,
{
    fn id(&self) -> StageId {
        StageId::Headers
    }
    
    async fn execute(
        &mut self,
        provider: &DatabaseProviderRW<DB>,
        input: ExecInput,
    ) -> Result<ExecOutput, StageError> {
        let target = input.target();
        let mut current_block = input.next_block();
        
        // Get the current tip from consensus layer
        let tip = self.consensus.get_canonical_head()?;
        let sync_target = target.min(tip.number);
        
        if current_block > sync_target {
            return Ok(ExecOutput::done(StageCheckpoint::new(sync_target)));
        }
        
        // Download headers in reverse order (from tip to current)
        let mut headers_stream = self.downloader
            .download_headers(sync_target, current_block)
            .await?;
        
        let mut headers_cursor = provider.tx_ref().cursor_write::<tables::Headers>()?;
        let mut canonical_cursor = provider.tx_ref().cursor_write::<tables::CanonicalHeaders>()?;
        
        let mut processed = 0u64;
        
        while let Some(header) = headers_stream.next().await {
            let header = header?;
            
            // Validate header according to consensus rules
            self.consensus.validate_header(&header)?;
            
            // Store header in database
            headers_cursor.append(header.number, header.clone())?;
            canonical_cursor.append(header.number, header.hash())?;
            
            current_block = header.number;
            processed += 1;
            
            // Commit periodically to avoid large transactions
            if processed >= self.commit_threshold {
                let checkpoint = StageCheckpoint::new(current_block);
                self.save_checkpoint(provider, checkpoint)?;
                
                return Ok(ExecOutput::progress(checkpoint));
            }
        }
        
        let final_checkpoint = StageCheckpoint::new(sync_target);
        self.save_checkpoint(provider, final_checkpoint)?;
        
        Ok(ExecOutput::done(final_checkpoint))
    }
    
    async fn unwind(
        &mut self,
        provider: &DatabaseProviderRW<DB>,
        input: UnwindInput,
    ) -> Result<UnwindOutput, StageError> {
        let target = input.unwind_to;
        let current = input.checkpoint.block_number;
        
        if target >= current {
            return Ok(UnwindOutput {
                checkpoint: input.checkpoint,
            });
        }
        
        // Remove headers from target+1 to current
        let mut headers_cursor = provider.tx_ref().cursor_write::<tables::Headers>()?;
        let mut canonical_cursor = provider.tx_ref().cursor_write::<tables::CanonicalHeaders>()?;
        
        // Seek to the first block to remove
        if let Some((block_num, _)) = headers_cursor.seek(target + 1)? {
            // Remove all headers from this point forward
            while block_num <= current {
                headers_cursor.delete_current()?;
                canonical_cursor.seek_exact(block_num)?;
                canonical_cursor.delete_current()?;
                
                if let Some((next_block, _)) = headers_cursor.next()? {
                    block_num = next_block;
                } else {
                    break;
                }
            }
        }
        
        let checkpoint = StageCheckpoint::new(target);
        self.save_checkpoint(provider, checkpoint)?;
        
        Ok(UnwindOutput { checkpoint })
    }
}
```
*Source: `stages/src/stages/headers.rs`*

### Body Stage Implementation

```rust
// From stages/src/stages/bodies.rs
pub struct BodyStage<D> {
    downloader: D,
    commit_threshold: u64,
}

#[async_trait]
impl<DB, D> Stage<DB> for BodyStage<D>
where
    DB: Database,
    D: BodyDownloader + Send + Sync,
{
    fn id(&self) -> StageId {
        StageId::Bodies
    }
    
    async fn execute(
        &mut self,
        provider: &DatabaseProviderRW<DB>,
        input: ExecInput,
    ) -> Result<ExecOutput, StageError> {
        let range = input.block_range();
        
        if range.is_empty() {
            return Ok(ExecOutput::done(input.checkpoint));
        }
        
        // Find blocks that need bodies downloaded
        let blocks_to_download = self.find_blocks_needing_bodies(provider, range)?;
        
        if blocks_to_download.is_empty() {
            return Ok(ExecOutput::done(StageCheckpoint::new(*range.end())));
        }
        
        // Download bodies
        let mut bodies_stream = self.downloader
            .download_bodies(blocks_to_download)
            .await?;
        
        let mut tx_cursor = provider.tx_ref().cursor_write::<tables::Transactions>()?;
        let mut body_indices_cursor = provider.tx_ref().cursor_write::<tables::BlockBodyIndices>()?;
        let mut ommers_cursor = provider.tx_ref().cursor_write::<tables::BlockOmmers>()?;
        
        let mut current_tx_num = self.get_next_tx_number(provider)?;
        let mut processed_blocks = 0u64;
        
        while let Some((block_num, body)) = bodies_stream.next().await {
            let (block_num, body) = (block_num?, body?);
            
            // Validate body against header
            let header = provider.header(block_num)?
                .ok_or(StageError::MissingHeader(block_num))?;
            
            self.validate_body(&header, &body)?;
            
            // Store transactions
            let first_tx_num = current_tx_num;
            for tx in body.transactions {
                tx_cursor.append(current_tx_num, tx)?;
                current_tx_num += 1;
            }
            
            // Store body indices
            let indices = StoredBlockBodyIndices {
                first_tx_num,
                tx_count: body.transactions.len() as u64,
            };
            body_indices_cursor.append(block_num, indices)?;
            
            // Store ommers if any
            if !body.ommers.is_empty() {
                ommers_cursor.append(block_num, body.ommers)?;
            }
            
            processed_blocks += 1;
            
            // Commit periodically
            if processed_blocks >= self.commit_threshold {
                let checkpoint = StageCheckpoint::new(block_num);
                self.save_checkpoint(provider, checkpoint)?;
                
                return Ok(ExecOutput::progress(checkpoint));
            }
        }
        
        let final_checkpoint = StageCheckpoint::new(*range.end());
        self.save_checkpoint(provider, final_checkpoint)?;
        
        Ok(ExecOutput::done(final_checkpoint))
    }
    
    async fn unwind(
        &mut self,
        provider: &DatabaseProviderRW<DB>,
        input: UnwindInput,
    ) -> Result<UnwindOutput, StageError> {
        // Implementation for unwinding body data
        // Remove transactions, body indices, and ommers for blocks > target
        
        let target = input.unwind_to;
        let current = input.checkpoint.block_number;
        
        // Find transaction range to remove
        let tx_range = self.get_tx_range_for_blocks(provider, target + 1..=current)?;
        
        if let Some((start_tx, end_tx)) = tx_range {
            // Remove transactions
            let mut tx_cursor = provider.tx_ref().cursor_write::<tables::Transactions>()?;
            for tx_num in start_tx..=end_tx {
                if tx_cursor.seek_exact(tx_num)?.is_some() {
                    tx_cursor.delete_current()?;
                }
            }
            
            // Remove body indices and ommers
            let mut body_indices_cursor = provider.tx_ref().cursor_write::<tables::BlockBodyIndices>()?;
            let mut ommers_cursor = provider.tx_ref().cursor_write::<tables::BlockOmmers>()?;
            
            for block_num in (target + 1)..=current {
                if body_indices_cursor.seek_exact(block_num)?.is_some() {
                    body_indices_cursor.delete_current()?;
                }
                
                if ommers_cursor.seek_exact(block_num)?.is_some() {
                    ommers_cursor.delete_current()?;
                }
            }
        }
        
        let checkpoint = StageCheckpoint::new(target);
        self.save_checkpoint(provider, checkpoint)?;
        
        Ok(UnwindOutput { checkpoint })
    }
}
```
*Source: `stages/src/stages/bodies.rs`*

## Error Handling

### Stage Error Types

```rust
#[derive(Debug, thiserror::Error)]
pub enum StageError {
    #[error("Database error: {0}")]
    Database(#[from] DatabaseError),
    
    #[error("Provider error: {0}")]
    Provider(#[from] ProviderError),
    
    #[error("Consensus error: {0}")]
    Consensus(#[from] ConsensusError),
    
    #[error("Download error: {0}")]
    Download(#[from] DownloadError),
    
    #[error("Missing header for block {0}")]
    MissingHeader(BlockNumber),
    
    #[error("Invalid block body for block {0}")]
    InvalidBody(BlockNumber),
    
    #[error("Stage was cancelled")]
    Cancelled,
    
    #[error("Internal error: {0}")]
    Internal(String),
}
```
*Source: `stages/src/stage.rs`*

### Error Recovery Patterns

```rust
impl<DB: Database> Stage<DB> for MyStage {
    async fn execute(
        &mut self,
        provider: &DatabaseProviderRW<DB>,
        input: ExecInput,
    ) -> Result<ExecOutput, StageError> {
        // Save checkpoint before starting work
        let initial_checkpoint = input.checkpoint;
        
        match self.do_work(provider, input).await {
            Ok(output) => {
                // Work completed successfully
                self.save_checkpoint(provider, output.checkpoint)?;
                Ok(output)
            }
            Err(e) => {
                // Error occurred, restore checkpoint
                self.save_checkpoint(provider, initial_checkpoint)?;
                Err(e)
            }
        }
    }
}
```

## Stage Composition and Dependencies

### Stage Dependencies

```rust
// Stages have implicit dependencies based on their order
pub fn default_stage_order() -> Vec<StageId> {
    vec![
        StageId::Headers,           // Must be first - provides block structure
        StageId::Bodies,            // Depends on headers
        StageId::SenderRecovery,    // Depends on transactions from bodies
        StageId::Execution,         // Depends on senders and transactions
        StageId::AccountHashing,    // Depends on execution results
        StageId::StorageHashing,    // Depends on execution results
        StageId::MerkleExecute,     // Depends on hashed state
        StageId::TransactionLookup, // Can run after bodies
        StageId::IndexAccountHistory,  // Depends on execution
        StageId::IndexStorageHistory,  // Depends on execution
        StageId::Finish,            // Always last
    ]
}
```

### Conditional Stage Execution

```rust
pub trait ConditionalStage<DB>: Stage<DB> {
    /// Check if this stage should be executed
    fn should_execute(&self, provider: &DatabaseProviderRO<DB>) -> Result<bool, StageError>;
}

// Example: Skip execution stage for header-only sync
impl<DB: Database> ConditionalStage<DB> for ExecutionStage {
    fn should_execute(&self, provider: &DatabaseProviderRO<DB>) -> Result<bool, StageError> {
        // Check if we're in header-only mode
        let config = provider.get_sync_config()?;
        Ok(!config.headers_only)
    }
}
```

## Testing Framework

### Stage Testing Utilities

```rust
#[cfg(test)]
pub mod test_utils {
    use super::*;
    
    /// Create a mock stage for testing
    pub struct MockStage {
        id: StageId,
        execute_fn: Box<dyn Fn(ExecInput) -> Result<ExecOutput, StageError> + Send + Sync>,
        unwind_fn: Box<dyn Fn(UnwindInput) -> Result<UnwindOutput, StageError> + Send + Sync>,
    }
    
    impl MockStage {
        pub fn new(id: StageId) -> Self {
            Self {
                id,
                execute_fn: Box::new(|input| {
                    Ok(ExecOutput::done(StageCheckpoint::new(input.target())))
                }),
                unwind_fn: Box::new(|input| {
                    Ok(UnwindOutput {
                        checkpoint: StageCheckpoint::new(input.unwind_to),
                    })
                }),
            }
        }
        
        pub fn with_execute<F>(mut self, f: F) -> Self
        where
            F: Fn(ExecInput) -> Result<ExecOutput, StageError> + Send + Sync + 'static,
        {
            self.execute_fn = Box::new(f);
            self
        }
    }
    
    #[async_trait]
    impl<DB: Database> Stage<DB> for MockStage {
        fn id(&self) -> StageId {
            self.id
        }
        
        async fn execute(
            &mut self,
            _provider: &DatabaseProviderRW<DB>,
            input: ExecInput,
        ) -> Result<ExecOutput, StageError> {
            (self.execute_fn)(input)
        }
        
        async fn unwind(
            &mut self,
            _provider: &DatabaseProviderRW<DB>,
            input: UnwindInput,
        ) -> Result<UnwindOutput, StageError> {
            (self.unwind_fn)(input)
        }
    }
}
```
*Source: `stages/src/test_utils.rs`*

### Stage Integration Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use reth_db::test_utils::create_test_rw_db;
    
    #[tokio::test]
    async fn test_header_stage_execution() {
        let db = create_test_rw_db();
        let provider = db.provider_rw().unwrap();
        
        let mut stage = HeaderStage::new(
            MockHeaderDownloader::new(),
            Arc::new(MockConsensus::new()),
        );
        
        let input = ExecInput {
            target: Some(1000),
            checkpoint: StageCheckpoint::new(0),
        };
        
        let output = stage.execute(&provider, input).await.unwrap();
        
        assert_eq!(output.checkpoint.block_number, 1000);
        assert!(output.done);
        
        // Verify headers were stored
        let header = provider.header(500).unwrap();
        assert!(header.is_some());
    }
    
    #[tokio::test]
    async fn test_stage_unwind() {
        let db = create_test_rw_db();
        let provider = db.provider_rw().unwrap();
        
        // Setup stage with some progress
        let mut stage = setup_stage_with_progress(&provider, 1000).await;
        
        let input = UnwindInput {
            unwind_to: 500,
            checkpoint: StageCheckpoint::new(1000),
        };
        
        let output = stage.unwind(&provider, input).await.unwrap();
        
        assert_eq!(output.checkpoint.block_number, 500);
        
        // Verify data was unwound
        let header = provider.header(600).unwrap();
        assert!(header.is_none());
    }
}
```
*Source: `stages/src/stages/headers/tests.rs`*

## Best Practices

### Stage Implementation Guidelines

1. **Idempotency**: Stages should be idempotent - running the same stage multiple times should produce the same result
2. **Checkpoint Granularity**: Choose appropriate checkpoint frequency to balance recovery time and performance
3. **Resource Management**: Monitor memory usage and implement appropriate limits
4. **Error Handling**: Provide detailed error information for debugging and recovery

### Performance Optimization

1. **Batch Processing**: Process multiple items in batches to reduce database overhead
2. **Streaming**: Use streaming APIs for large datasets to avoid memory issues
3. **Parallel Processing**: Where possible, parallelize work within stages
4. **Caching**: Cache frequently accessed data to reduce database queries

### Testing Strategy

1. **Unit Tests**: Test individual stage logic in isolation
2. **Integration Tests**: Test stages with real database interactions
3. **Error Scenarios**: Test error handling and recovery mechanisms
4. **Performance Tests**: Benchmark stage performance under various conditions

## Conclusion

The Stage trait provides a clean, modular interface for implementing blockchain synchronization logic in Reth. Key benefits include:

- **Modularity**: Each stage can be developed and tested independently
- **Composability**: Stages can be combined in different configurations
- **Reliability**: Built-in checkpoint and unwind mechanisms ensure data consistency
- **Observability**: Standardized interface enables consistent monitoring and metrics

This design enables Reth to achieve high performance while maintaining code clarity and reliability, making it easy to add new stages or modify existing ones as the Ethereum protocol evolves.

## References

- [Reth Stages Documentation](https://github.com/paradigmxyz/reth/blob/main/docs/crates/stages.md)
- [Reth Repository Layout](https://github.com/paradigmxyz/reth/blob/main/docs/repo/layout.md)
- [Async Trait Documentation](https://docs.rs/async-trait/)
- [Ethereum Sync Strategies](https://ethereum.org/en/developers/docs/nodes-and-clients/)