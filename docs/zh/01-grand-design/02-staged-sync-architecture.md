# 阶段式同步 (Staged Sync) 核心架构思想

Reth 之所以能拥有高性能，其主要原因之一是采用了**阶段式同步 (Staged Sync)** 架构。这并非 Reth 首创的新概念，而是一种经过验证的设计模式，Reth 对其进行了高效的实现。

正如 `README.md` 文件所承认的，该架构由另一个高性能客户端首创：

> Erigon 开创了 Reth 正在使用的“阶段式同步”架构...
>
> *来源: `README.md`*

那么，阶段式同步究竟是什么？简单来说，它并非试图一次性完成所有工作，而是将同步区块链这一庞大任务分解为一系列更小的、顺序执行的、更易于管理的**阶段 (Stage)**。这类似于工厂里的流水线，每个工位都有一个单一且明确定义的工作。

## 核心构件: `Stage` 与 `Pipeline`

Reth 的整个阶段式同步框架构建于两个核心抽象之上：`Stage` trait 和 `Pipeline` 结构体。

### `Stage` Trait：一个独立的工作单元

一个 `Stage` 代表了同步过程中的一个离散步骤。Reth 中的每个阶段都必须实现 `Stage` trait。

该 trait 的定义揭示了其核心职责：

```rust
// 来源: crates/stages/api/src/stage.rs

/// A stage is a segmented part of the syncing process of the node.
///
/// Each stage takes care of a well-defined task, such as downloading headers or executing
/// transactions, and persist their results to a database.
///
/// Stages must have a unique [ID][StageId] and implement a way to "roll forwards"
/// ([`Stage::execute`]) and a way to "roll back" ([`Stage::unwind`]).
///
/// Stages are executed as part of a pipeline where they are executed serially.
///
/// Stages receive [`DBProvider`](reth_provider::DBProvider).
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

其中两个最重要的方法是：

- **`execute`**: 阶段在这里执行其主要任务。例如，下载区块头、执行交易或构建索引。它会一直运行，直到处理完某个目标高度之前的所有区块。
- **`unwind`**: 这是“撤销”函数。如果发生链重组 (reorg)，流水线会按相反的顺序在每个阶段上调用 `unwind`，以回滚所做的更改，使数据库在分叉前恢复到一致状态。

### `Pipeline`：总指挥

如果说 `Stage` 是流水线上的工人，那么 `Pipeline` 就是工厂的管理者或总指挥。它负责按正确的顺序管理和执行所有的阶段。

`Pipeline` 结构体的定义和文档凸显了它的职责：

```rust
// 来源: crates/stages/api/src/pipeline/mod.rs

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

`Pipeline` 的核心职责是：

- **顺序执行**: 它持有一个阶段列表，并按预定义顺序逐一运行它们。
- **进度管理**: 它跟踪同步进度，确保每个阶段在下一个阶段开始前都已完成其工作，达到目标区块高度。
- **事务与状态处理**: 它管理数据库事务，只有当一个阶段成功完成后，才会提交该阶段的工作。
- **回滚协调**: 它负责协调整个回滚过程，在必要时调用阶段的 `unwind` 方法。

## 流水线揭秘：默认阶段一览

那么，Reth 的“流水线”实际上是什么样的呢？`DefaultStages` 集合为我们清晰地展示了标准的同步流程。

*来源: `crates/stages/stages/src/sets.rs`*

以下是按执行顺序列出的关键阶段：

1.  **`HeaderStage` (区块头阶段)**: 下载区块头。这会快速构建起区块链的“骨架”。
2.  **`BodyStage` (区块体阶段)**: 下载对应的区块体（包含交易）。
3.  **`SenderRecoveryStage` (发送者恢复阶段)**: 一个至关重要的性能优化。它批量处理所有交易，从签名中恢复出发送者的地址。这是一个计算密集型任务，因此一次性完成会快得多。
4.  **`ExecutionStage` (执行阶段)**: 整个流程的核心。它执行已下载区块中的所有交易，更新世界状态，并生成交易收据。
5.  **哈希阶段 (`AccountHashingStage`, `StorageHashingStage`)**: 这些阶段负责为账户和存储生成默克尔树（Merkle Tries），这是计算区块最终状态根所必需的。
6.  **索引阶段 (`TransactionLookupStage`, `IndexAccountHistoryStage` 等)**: 状态执行完毕后，这些阶段会创建各种索引（例如，从交易哈希到其所在区块的映射）。这些索引对于通过 JSON-RPC API 进行快速查询至关重要。
7.  **`FinishStage` (完成阶段)**: 标志着一次完整流水线运行结束的最终阶段。

通过这种方式分解流程，Reth 可以最大化效率，提供清晰的进度，并优雅地处理中断或错误。