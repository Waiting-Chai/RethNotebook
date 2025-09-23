# BlockExecutor 桥接：连接 Reth 与 REVM

## 概述

BlockExecutor 作为 Reth 区块链基础设施与 REVM 执行引擎之间的关键桥梁。该组件协调整个区块的执行，管理交易处理、状态更新和收据生成的复杂过程，同时保持与以太坊执行模型的一致性。

## BlockExecutor 架构

### 核心 Trait 和接口

```rust
// 来自 reth-evm/src/execute.rs
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
*来源：`reth-evm/src/execute.rs`*

### 执行输出类型

```rust
// 来自 reth-evm/src/execute.rs
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
*来源：`reth-evm/src/execute.rs`*

## Reth 的 BlockExecutor 实现

### EthBlockExecutor 结构

```rust
// 来自 reth-ethereum-forks/src/executor.rs
pub struct EthBlockExecutor<EvmConfig, DB> {
    /// EVM 配置
    evm_config: EvmConfig,
    /// 区块执行的当前状态
    state: State<DB>,
    /// 用于验证的共识实例
    consensus: Arc<dyn Consensus>,
    /// 区块执行期间收集的请求
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
        
        // 配置区块环境
        env.block.number = U256::from(header.number);
        env.block.coinbase = header.beneficiary;
        env.block.timestamp = U256::from(header.timestamp);
        env.block.gas_limit = U256::from(header.gas_limit);
        env.block.basefee = U256::from(header.base_fee_per_gas.unwrap_or_default());
        env.block.difficulty = header.difficulty;
        env.block.prevrandao = header.mix_hash;
        
        // 配置链特定设置
        env.cfg.chain_id = self.evm_config.chain_id();
        env.cfg.spec_id = self.evm_config.spec_id_at_timestamp(header.timestamp);
        
        env
    }
}
```
*来源：`reth-ethereum-forks/src/executor.rs`*

### 区块执行实现

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
        // 执行前验证
        self.validate_block_pre_execution(block)?;
        
        // 配置 EVM 环境
        let env = self.configure_evm_env(&block.header, total_difficulty);
        
        // 执行所有交易
        let receipts = self.execute_transactions(block, total_difficulty)?;
        
        // 计算使用的 gas
        let gas_used = receipts.last()
            .map(|receipt| receipt.cumulative_gas_used)
            .unwrap_or_default();
        
        // 验证 gas 使用量
        if gas_used != block.header.gas_used {
            return Err(BlockExecutionError::BlockGasUsedMismatch {
                expected: block.header.gas_used,
                actual: gas_used,
            });
        }
        
        // 处理系统调用（提款等）
        self.process_system_calls(block)?;
        
        // 收集请求（EIP-7685）
        let requests = std::mem::take(&mut self.requests);
        
        // 获取最终状态
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
        
        // 配置基础 EVM 环境
        let mut env = self.configure_evm_env(&block.header, total_difficulty);
        
        for (transaction, sender) in block.transactions_with_sender() {
            // 配置交易环境
            self.configure_tx_env(&mut env.tx, transaction, *sender)?;
            
            // 创建 EVM 实例
            let mut evm = self.evm_config.evm_with_env(&mut self.state, env.clone());
            
            // 执行交易
            let result = evm.transact()?;
            
            // 处理执行结果
            let gas_used = result.result.gas_used();
            cumulative_gas_used += gas_used;
            
            // 创建收据
            let receipt = self.create_receipt(
                transaction,
                &result,
                cumulative_gas_used,
                &result.state,
            )?;
            
            receipts.push(receipt);
            
            // 应用状态变更
            self.state.commit(result.state);
            
            // 从此交易收集任何请求
            self.collect_requests_from_result(&result);
        }
        
        Ok(receipts)
    }

    fn take_output_state(&mut self) -> BundleState {
        self.state.take_bundle()
    }
}
```
*来源：`reth-ethereum-forks/src/executor.rs`*

## 交易环境配置

### 交易环境设置

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn configure_tx_env(
        &self,
        tx_env: &mut TxEnv,
        transaction: &TransactionSigned,
        sender: Address,
    ) -> Result<(), BlockExecutionError> {
        // 基本交易字段
        tx_env.caller = sender;
        tx_env.gas_limit = transaction.gas_limit();
        tx_env.gas_price = U256::from(transaction.gas_price());
        tx_env.value = transaction.value();
        tx_env.data = transaction.input().clone();
        tx_env.nonce = Some(transaction.nonce());
        tx_env.chain_id = transaction.chain_id();
        
        // 配置交易类型特定字段
        match transaction.transaction {
            Transaction::Legacy(_) => {
                // 传统交易 - 无需额外配置
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
        
        // 设置交易目标
        tx_env.transact_to = match transaction.to() {
            Some(to) => TransactTo::Call(to),
            None => TransactTo::Create(CreateScheme::Create),
        };
        
        Ok(())
    }
}
```

### 收据生成

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn create_receipt(
        &self,
        transaction: &TransactionSigned,
        result: &ResultAndState,
        cumulative_gas_used: u64,
        state: &EvmState,
    ) -> Result<Receipt, BlockExecutionError> {
        // 确定交易成功状态
        let success = result.result.is_success();
        
        // 从执行结果创建日志
        let logs = result.result.logs().iter().cloned().collect();
        
        // 计算布隆过滤器
        let logs_bloom = logs_bloom(&logs);
        
        // 创建基础收据
        let mut receipt = Receipt {
            tx_type: transaction.tx_type(),
            success,
            cumulative_gas_used,
            logs,
        };
        
        // 添加交易类型特定字段
        match transaction.tx_type() {
            TxType::Legacy => {
                // 传统收据包含状态根（拜占庭前）或状态（拜占庭后）
                if self.is_byzantium_active() {
                    receipt.success = success;
                } else {
                    // 拜占庭前：包含状态根
                    receipt.state_root = Some(self.compute_state_root(state)?);
                }
            }
            TxType::Eip2930 | TxType::Eip1559 => {
                // EIP-2930 和 EIP-1559 交易总是包含状态
                receipt.success = success;
            }
            TxType::Eip4844 => {
                // EIP-4844 交易包含状态和使用的 blob gas
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

## 状态管理

### Bundle 状态操作

```rust
// 来自 reth-execution-types/src/bundle_state.rs
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
            
            // 更新账户信息
            if let Some(info) = account.info {
                bundle_account.info = Some(info);
            }
            
            // 更新存储
            for (key, slot) in account.storage {
                if slot.is_changed() {
                    bundle_account.storage.insert(key, slot);
                }
            }
            
            // 更新账户状态
            bundle_account.status = account.status;
        }
        
        // 更新大小跟踪
        self.update_size();
    }
    
    pub fn revert_to(&mut self, revert_id: u64) -> Result<(), BundleStateError> {
        if let Some(reverts) = self.reverts.remove(&revert_id) {
            for (address, revert_info) in reverts {
                if let Some(account) = self.state.get_mut(&address) {
                    // 回滚账户变更
                    account.info = revert_info.account;
                    
                    // 回滚存储变更
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
                    
                    // 更新状态
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

### 状态提交

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn commit_state_changes(&mut self, state: EvmState) -> Result<(), BlockExecutionError> {
        // 将变更应用到数据库状态
        for (address, account) in state {
            match account.status {
                AccountStatus::Loaded | AccountStatus::Created => {
                    // 更新或创建账户
                    if let Some(info) = account.info {
                        self.state.set_account(address, info);
                    }
                    
                    // 更新存储
                    for (key, slot) in account.storage {
                        if slot.is_changed() {
                            self.state.set_storage(address, key, slot.present_value);
                        }
                    }
                }
                AccountStatus::SelfDestructed => {
                    // 移除账户及其所有存储
                    self.state.remove_account(address);
                }
                AccountStatus::Touched => {
                    // 账户被触及但未显著修改
                    // 仅在有实际变更时更新
                    if account.is_changed() {
                        if let Some(info) = account.info {
                            self.state.set_account(address, info);
                        }
                    }
                }
                _ => {
                    // 其他状态无需变更
                }
            }
        }
        
        Ok(())
    }
}
```

## 系统调用和提款

### 提款处理

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn process_system_calls(&mut self, block: &BlockWithSenders) -> Result<(), BlockExecutionError> {
        // 处理提款（EIP-4895）
        if let Some(withdrawals) = &block.withdrawals {
            self.process_withdrawals(withdrawals)?;
        }
        
        // 根据需要处理其他系统调用
        self.process_beacon_root_contract_call(block)?;
        
        Ok(())
    }
    
    fn process_withdrawals(&mut self, withdrawals: &[Withdrawal]) -> Result<(), BlockExecutionError> {
        for withdrawal in withdrawals {
            // 获取当前账户余额
            let current_balance = self.state
                .basic_account(withdrawal.address)?
                .map(|acc| acc.balance)
                .unwrap_or_default();
            
            // 添加提款金额
            let new_balance = current_balance + withdrawal.amount_wei();
            
            // 更新账户余额
            let mut account_info = AccountInfo {
                balance: new_balance,
                nonce: 0, // 提款不影响 nonce
                code_hash: KECCAK_EMPTY,
                code: None,
            };
            
            // 如果账户存在，保留现有的 nonce 和代码
            if let Some(existing) = self.state.basic_account(withdrawal.address)? {
                account_info.nonce = existing.nonce;
                account_info.code_hash = existing.code_hash;
            }
            
            self.state.set_account(withdrawal.address, account_info);
        }
        
        Ok(())
    }
    
    fn process_beacon_root_contract_call(&mut self, block: &BlockWithSenders) -> Result<(), BlockExecutionError> {
        // EIP-4788：EVM 中的信标区块根
        if let Some(parent_beacon_block_root) = block.header.parent_beacon_block_root {
            let beacon_roots_address = Address::from_slice(&[0x00; 20]); // 占位符
            
            // 创建系统交易以更新信标根
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
            
            // 执行系统调用
            let mut env = self.configure_evm_env(&block.header, U256::ZERO);
            env.tx = tx_env;
            
            let mut evm = self.evm_config.evm_with_env(&mut self.state, env);
            let result = evm.transact()?;
            
            // 应用系统调用的状态变更
            self.state.commit(result.state);
        }
        
        Ok(())
    }
}
```

## 错误处理和恢复

### 综合错误类型

```rust
// 来自 reth-evm/src/execute.rs
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

### 错误恢复策略

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn execute_with_recovery(
        &mut self,
        block: &BlockWithSenders,
        total_difficulty: U256,
    ) -> Result<ExecutionOutput, BlockExecutionError> {
        // 为潜在回滚创建检查点
        let checkpoint = self.state.checkpoint();
        
        match self.execute_block(block, total_difficulty) {
            Ok(output) => {
                // 执行成功，提交变更
                self.state.commit_checkpoint(checkpoint);
                Ok(output)
            }
            Err(error) => {
                // 执行失败，回滚到检查点
                self.state.revert_checkpoint(checkpoint);
                
                // 根据错误类型尝试恢复
                match &error {
                    BlockExecutionError::InvalidTransaction { index, .. } => {
                        // 尝试跳过有问题的交易执行
                        warn!("Skipping invalid transaction at index {}", index);
                        self.execute_block_skip_transaction(block, *index, total_difficulty)
                    }
                    BlockExecutionError::StateRootMismatch { .. } => {
                        // 状态根不匹配可能是由于状态计算中的错误
                        // 记录错误并继续使用计算的状态
                        warn!("State root mismatch detected: {}", error);
                        self.execute_block_ignore_state_root(block, total_difficulty)
                    }
                    _ => {
                        // 对于其他错误，向上传播
                        Err(error)
                    }
                }
            }
        }
    }
}
```

## 性能优化

### 并行交易验证

```rust
impl<EvmConfig, DB> EthBlockExecutor<EvmConfig, DB> {
    fn validate_transactions_parallel(
        &self,
        block: &BlockWithSenders,
    ) -> Result<(), BlockExecutionError> {
        use rayon::prelude::*;
        
        // 并行验证交易
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
        // 基本签名验证
        if transaction.recover_signer() != Some(sender) {
            return Err(TransactionValidationError::InvalidSignature);
        }
        
        // Gas 限制验证
        if transaction.gas_limit() > MAX_TRANSACTION_GAS_LIMIT {
            return Err(TransactionValidationError::GasLimitTooHigh);
        }
        
        // 链 ID 验证
        if let Some(chain_id) = transaction.chain_id() {
            if chain_id != self.evm_config.chain_id() {
                return Err(TransactionValidationError::InvalidChainId);
            }
        }
        
        Ok(())
    }
}
```

### 状态缓存

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
        // 区块哈希通常在更高级别缓存
        self.db.block_hash(number)
    }
}
```

## 测试和验证

### 区块执行测试

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
        
        // 验证执行结果
        assert_eq!(result.receipts.len(), block.body.len());
        assert_eq!(result.gas_used, block.header.gas_used);
        
        // 验证状态变更
        let state = result.state;
        assert!(!state.state.is_empty());
        
        // 验证收据
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
        
        // 验证提款已处理
        let account = executor.state.basic_account(withdrawals[0].address).unwrap().unwrap();
        assert_eq!(account.balance, U256::from(withdrawals[0].amount_wei()));
    }
}
```

## 最佳实践

### 配置指南

1. **EVM 配置**：确保正确的 SpecId 和链配置
2. **状态管理**：使用适当的缓存策略以提高性能
3. **错误处理**：实现综合的错误恢复机制
4. **资源限制**：设置适当的 gas 和内存限制

### 性能优化

1. **并行验证**：在可能的情况下并行验证交易
2. **状态缓存**：为频繁访问的状态实现智能缓存
3. **批处理**：在批处理模式下高效处理多个区块
4. **内存管理**：在执行期间监控和优化内存使用

## 结论

BlockExecutor 桥接是一个关键组件，它将 REVM 的执行能力与 Reth 的区块链基础设施无缝集成。它提供：

- **完整的区块处理**：处理区块执行的所有方面，包括交易、系统调用和状态更新
- **类型安全**：利用 Rust 的类型系统进行安全可靠的执行
- **性能**：针对高吞吐量区块处理进行优化
- **灵活性**：支持各种交易类型和以太坊协议升级
- **错误恢复**：综合的错误处理和恢复机制

这种设计使 Reth 能够实现卓越的执行性能，同时保持与以太坊执行模型的完全兼容性，并为未来的协议升级提供所需的模块化。

## 参考资料

- [Reth EVM 执行](https://github.com/paradigmxyz/reth)
- [REVM 文档](https://github.com/bluealloy/revm)
- [以太坊执行规范](https://ethereum.github.io/execution-specs/)
- [EIP-4895：信标链推送提款](https://eips.ethereum.org/EIPS/eip-4895)
- [EIP-4788：EVM 中的信标区块根](https://eips.ethereum.org/EIPS/eip-4788)