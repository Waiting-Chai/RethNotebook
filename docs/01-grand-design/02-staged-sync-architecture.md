# Staged Sync Core Architecture

One of the main reasons for Reth's high performance is its adoption of the **Staged Sync** architecture. This is not a new concept invented by Reth but a proven design pattern that Reth implements effectively.

As the `README.md` acknowledges, this architecture was pioneered by another high-performance client:

> Erigon pioneered the "Staged Sync" architecture that Reth is using...
>
> *Source: `README.md`*

So, what exactly is Staged Sync? In simple terms, instead of trying to do everything at once, it breaks down the massive task of synchronizing a blockchain into a series of smaller, sequential, and more manageable **stages**. This is analogous to an assembly line in a factory, where each station has a single, well-defined job.

## The Building Blocks: `Stage` and `Pipeline`

The entire Staged Sync framework in Reth is built upon two core abstractions: the `Stage` trait and the `Pipeline` struct.

### The `Stage` Trait: A Single Unit of Work

A `Stage` represents a single, discrete step in the synchronization process. Every stage in Reth must implement the `Stage` trait.

The definition of this trait reveals its core responsibilities:

```rust
// Source: crates/stages/api/src/stage.rs

/// A stage in the pipeline.
///
/// The `Stage` trait is the main interface for a stage.
pub trait Stage<Provider>: Send + Sync {
    /// Get the ID of the stage.
    ///
    /// Stage IDs must be unique.
    fn id(&self) -> StageId;

    /// Execute the stage.
    /// It is expected that the stage will write all necessary data to the database
    /// upon invoking this method.
    fn execute(&mut self, provider: &Provider, input: ExecInput) -> Result<ExecOutput, StageError>;

    /// Unwind the stage.
    fn unwind(
        &mut self,
        provider: &Provider,
        input: UnwindInput,
    ) -> Result<UnwindOutput, StageError>;
    // ...
}
```

The two most important methods are:

- **`execute`**: This is where the stage performs its main task. For example, downloading block headers, executing transactions, or building an index. It runs until it has processed all blocks up to a certain target.
- **`unwind`**: This is the "undo" function. If a chain reorganization (reorg) occurs, the pipeline calls `unwind` on each stage in reverse order to revert the changes made, bringing the database to a consistent state before the fork.

### The `Pipeline`: The Conductor

If stages are the workers on the assembly line, the `Pipeline` is the factory manager or conductor. It is responsible for managing and executing all the stages in the correct order.

The `Pipeline` struct's definition and documentation highlight its duties:

```rust
// Source: crates/stages/api/src/pipeline/mod.rs

pub struct Pipeline<N: ProviderNodeTypes> {
    /// Provider factory.
    provider_factory: ProviderFactory<N>,
    /// All configured stages in the order they will be executed.
    stages: Vec<BoxedStage<<ProviderFactory<N> as DatabaseProviderFactory>::ProviderRW>>,
    /// The maximum block number to sync to.
    max_block: Option<BlockNumber>,
    static_file_producer: StaticFileProducer<ProviderFactory<N>>,
    /// Sender for events the pipeline emits.
    event_sender: EventSender<PipelineEvent>,
    // ...
}
```

The core responsibilities of the `Pipeline` are:

- **Sequential Execution**: It holds a list of stages and runs them one by one, in a predefined order.
- **Progress Management**: It keeps track of the sync progress, ensuring that each stage completes its work up to the target block before the next stage begins.
- **Transaction and State Handling**: It manages database transactions, committing the work of a stage only after it successfully completes a run.
- **Unwinding Coordination**: It orchestrates the unwind process, calling the `unwind` method on stages when necessary.

## The Assembly Line: A Look at the Default Stages

So, what does Reth's "assembly line" actually look like? The `DefaultStages` set gives us a clear picture of the standard synchronization process.

*Source: `crates/stages/stages/src/sets.rs`*

Here are the key stages in their order of execution:

1. **`HeaderStage`**: Downloads block headers. This quickly builds the "skeleton" of the blockchain.
2. **`BodyStage`**: Downloads the corresponding block bodies (which contain transactions).
3. **`SenderRecoveryStage`**: A crucial performance optimization. It processes all transactions in a batch to recover the sender's address from the signature. This is computationally expensive, so doing it all at once is much faster.
4. **`ExecutionStage`**: The heart of the process. It executes all the transactions within the downloaded blocks, updates the world state, and generates transaction receipts.
5. **Hashing Stages (`AccountHashingStage`, `StorageHashingStage`)**: These stages are responsible for generating the Merkle Tries for accounts and storage, which are necessary to compute the final state root of a block.
6. **Indexing Stages (`TransactionLookupStage`, `IndexAccountHistoryStage`, etc.)**: After the state is executed, these stages create various indices (e.g., mapping a transaction hash to its block). These indices are vital for enabling fast lookups via the JSON-RPC API.
7. **`FinishStage`**: The final stage that marks the completion of a full pipeline run.

By breaking the process down this way, Reth can maximize efficiency, provide clear progress, and gracefully handle interruptions or errors.
