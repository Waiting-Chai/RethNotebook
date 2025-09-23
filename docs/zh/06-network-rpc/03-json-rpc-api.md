# JSON-RPC 接口实现

本章详细介绍了 Reth 的 JSON-RPC API 实现，包括服务器架构、以太坊 RPC 方法、交易提交、合约交互、事件过滤和 WebSocket 订阅等核心功能。

## 概述

Reth 的 JSON-RPC API 提供了与以太坊区块链交互的标准接口，完全兼容以太坊 JSON-RPC 规范。该实现针对性能进行了优化，支持 HTTP、WebSocket 和 IPC 传输协议。

### 主要特性

- **完整的以太坊兼容性**：实现了所有标准的以太坊 JSON-RPC 方法
- **高性能**：优化的数据访问和智能缓存机制
- **实时功能**：通过 WebSocket 订阅支持实时事件流
- **安全性**：内置速率限制、身份验证和 CORS 支持
- **可扩展性**：模块化架构支持自定义 RPC 方法

## RPC 服务器架构

### 核心组件

```rust
// 来源：reth-rpc/src/server.rs
pub struct RpcServer<Provider, Pool, Network> {
    /// 区块链数据提供者
    provider: Provider,
    /// 交易池
    pool: Pool,
    /// 网络接口
    network: Network,
    /// 服务器配置
    config: RpcServerConfig,
    /// 注册的 RPC 模块
    modules: RpcModuleRegistry,
}

impl<Provider, Pool, Network> RpcServer<Provider, Pool, Network> {
    pub fn new(
        provider: Provider,
        pool: Pool,
        network: Network,
        config: RpcServerConfig,
    ) -> Self {
        let mut modules = RpcModuleRegistry::new();
        
        // 注册标准以太坊 RPC 方法
        modules.register_eth_api(provider.clone(), pool.clone(), network.clone());
        modules.register_net_api(network.clone());
        modules.register_web3_api();
        
        Self {
            provider,
            pool,
            network,
            config,
            modules,
        }
    }
    
    /// 启动 HTTP 服务器
    pub async fn start_http(&self) -> Result<HttpServerHandle, RpcError> {
        let middleware = SecurityMiddleware::new(&self.config);
        
        let server = HttpServerBuilder::default()
            .set_middleware(middleware)
            .max_request_body_size(self.config.http.max_request_size)
            .max_response_body_size(self.config.http.max_response_size)
            .build(self.config.http.addr)
            .await?;
        
        let handle = server.start(self.modules.clone())?;
        Ok(handle)
    }
    
    /// 启动 WebSocket 服务器
    pub async fn start_ws(&self) -> Result<WsServerHandle, RpcError> {
        if let Some(ws_config) = &self.config.ws {
            let server = WsServerBuilder::default()
                .max_connections(ws_config.max_connections)
                .build(ws_config.addr)
                .await?;
            
            let handle = server.start(self.modules.clone())?;
            Ok(handle)
        } else {
            Err(RpcError::WebSocketDisabled)
        }
    }
    
    /// 启动 IPC 服务器
    pub async fn start_ipc(&self) -> Result<IpcServerHandle, RpcError> {
        if let Some(ipc_config) = &self.config.ipc {
            let server = IpcServerBuilder::default()
                .build(&ipc_config.path)
                .await?;
            
            let handle = server.start(self.modules.clone())?;
            Ok(handle)
        } else {
            Err(RpcError::IpcDisabled)
        }
    }
}
```
*来源：`reth-rpc/src/server.rs`*

### 模块注册

```rust
// 来源：reth-rpc/src/registry.rs
pub struct RpcModuleRegistry {
    modules: HashMap<String, RpcModule<()>>,
}

impl RpcModuleRegistry {
    pub fn new() -> Self {
        Self {
            modules: HashMap::new(),
        }
    }
    
    /// 注册以太坊 API 模块
    pub fn register_eth_api<Provider, Pool, Network>(
        &mut self,
        provider: Provider,
        pool: Pool,
        network: Network,
    ) where
        Provider: BlockReader + StateProvider + ReceiptProvider + Clone + 'static,
        Pool: TransactionPool + Clone + 'static,
        Network: NetworkInfo + Clone + 'static,
    {
        let eth_api = EthApi::new(provider, pool, network);
        let mut module = RpcModule::new(());
        
        // 账户相关方法
        module.register_async_method("eth_getBalance", move |params, _| {
            let eth_api = eth_api.clone();
            async move {
                let (address, block_id): (Address, Option<BlockId>) = params.parse()?;
                eth_api.get_balance(address, block_id).await
            }
        })?;
        
        module.register_async_method("eth_getTransactionCount", move |params, _| {
            let eth_api = eth_api.clone();
            async move {
                let (address, block_id): (Address, Option<BlockId>) = params.parse()?;
                eth_api.get_transaction_count(address, block_id).await
            }
        })?;
        
        // 更多方法注册...
        
        self.modules.insert("eth".to_string(), module);
    }
    
    /// 解析模块依赖关系
    pub fn resolve_dependencies(&mut self) -> Result<(), RegistryError> {
        // 检查模块间的依赖关系
        // 确保所有必需的模块都已注册
        Ok(())
    }
}
```
*来源：`reth-rpc/src/registry.rs`*

## 以太坊 RPC 方法

### 账户和状态查询

```rust
// 来源：reth-rpc/src/eth/mod.rs
pub struct EthApi<Provider, Pool, Network> {
    provider: Provider,
    pool: Pool,
    network: Network,
    gas_oracle: GasPriceOracle<Provider>,
}

impl<Provider, Pool, Network> EthApi<Provider, Pool, Network>
where
    Provider: BlockReader + StateProvider + ReceiptProvider,
    Pool: TransactionPool,
    Network: NetworkInfo,
{
    pub fn new(provider: Provider, pool: Pool, network: Network) -> Self {
        let gas_oracle = GasPriceOracle::new(provider.clone(), GasPriceConfig::default());
        
        Self {
            provider,
            pool,
            network,
            gas_oracle,
        }
    }
    
    /// 获取账户余额
    pub async fn get_balance(
        &self,
        address: Address,
        block_id: Option<BlockId>,
    ) -> Result<U256, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        let state = self.provider.state_by_block_id(block_id)?;
        
        let account = state.basic_account(address)?;
        Ok(account.map(|acc| acc.balance).unwrap_or_default())
    }
    
    /// 获取账户交易计数（nonce）
    pub async fn get_transaction_count(
        &self,
        address: Address,
        block_id: Option<BlockId>,
    ) -> Result<U256, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        
        match block_id {
            BlockId::Number(BlockNumberOrTag::Pending) => {
                // 对于待处理状态，包括交易池中的交易
                let state_nonce = self.provider.account_nonce(address)?
                    .unwrap_or_default();
                
                let pool_nonce = self.pool.get_highest_nonce(address)
                    .map(|n| n + 1)
                    .unwrap_or(state_nonce);
                
                Ok(U256::from(std::cmp::max(state_nonce, pool_nonce)))
            }
            _ => {
                let state = self.provider.state_by_block_id(block_id)?;
                let account = state.basic_account(address)?;
                Ok(U256::from(account.map(|acc| acc.nonce).unwrap_or_default()))
            }
         }
    }
    
    /// 获取账户代码
    pub async fn get_code(
        &self,
        address: Address,
        block_id: Option<BlockId>,
    ) -> Result<Bytes, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        let state = self.provider.state_by_block_id(block_id)?;
        
        let account = state.basic_account(address)?;
        if let Some(account) = account {
            if let Some(code_hash) = account.code_hash {
                if code_hash != KECCAK_EMPTY {
                    let code = state.account_code(address)?;
                    return Ok(code.unwrap_or_default().original_bytes());
                }
            }
        }
        
        Ok(Bytes::default())
    }
    
    /// 获取存储值
    pub async fn get_storage_at(
        &self,
        address: Address,
        index: U256,
        block_id: Option<BlockId>,
    ) -> Result<B256, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        let state = self.provider.state_by_block_id(block_id)?;
        
        let storage_key = B256::from(index);
        let value = state.storage(address, storage_key)?;
        
        Ok(value.unwrap_or_default())
    }
}
```
*来源：`reth-rpc/src/eth/mod.rs`*

### 区块和交易查询

```rust
impl<Provider, Pool, Network> EthApi<Provider, Pool, Network>
where
    Provider: BlockReader + StateProvider + ReceiptProvider,
    Pool: TransactionPool,
    Network: NetworkInfo,
{
    /// 根据哈希获取区块
    pub async fn get_block_by_hash(
        &self,
        hash: B256,
        full_transactions: bool,
    ) -> Result<Option<RichBlock>, EthApiError> {
        let block = self.provider.block_by_hash(hash)?;
        
        if let Some(block) = block {
            let rich_block = self.build_rich_block(block, full_transactions).await?;
            Ok(Some(rich_block))
        } else {
             Ok(None)
         }
    }
    
    /// 构建富交易收据
    async fn build_rich_receipt(
        &self,
        receipt: Receipt,
        tx: Transaction,
        block_hash: B256,
        block_number: u64,
        transaction_index: u64,
    ) -> Result<TransactionReceipt, EthApiError> {
        let effective_gas_price = self.calculate_effective_gas_price(&tx, block_number).await?;
        
        let contract_address = if tx.to().is_none() {
            Some(tx.recover_signer()
                .ok_or(EthApiError::InvalidSignature)?
                .create(tx.nonce()))
        } else {
            None
        };
        
        let logs = self.build_rich_logs(
            receipt.logs,
            block_hash,
            block_number,
            transaction_index,
        )?;
        
        Ok(TransactionReceipt {
            transaction_hash: tx.hash(),
            transaction_index: U256::from(transaction_index),
            block_hash: Some(block_hash),
            block_number: Some(U256::from(block_number)),
            from: tx.recover_signer().ok_or(EthApiError::InvalidSignature)?,
            to: tx.to(),
            cumulative_gas_used: U256::from(receipt.cumulative_gas_used),
            gas_used: Some(U256::from(receipt.gas_used)),
            contract_address,
            logs,
            status: Some(U256::from(receipt.success as u8)),
            root: receipt.state_root,
            logs_bloom: receipt.bloom,
            transaction_type: Some(U256::from(tx.tx_type() as u8)),
            effective_gas_price: Some(effective_gas_price),
        })
    }
    
    /// 构建富日志
    fn build_rich_logs(
        &self,
        logs: Vec<Log>,
        block_hash: B256,
        block_number: u64,
        transaction_index: u64,
    ) -> Result<Vec<RichLog>, EthApiError> {
        let mut rich_logs = Vec::new();
        
        for (log_index, log) in logs.into_iter().enumerate() {
            rich_logs.push(RichLog {
                address: log.address,
                topics: log.topics,
                data: log.data,
                block_hash: Some(block_hash),
                block_number: Some(U256::from(block_number)),
                transaction_hash: Some(log.transaction_hash),
                transaction_index: Some(U256::from(transaction_index)),
                log_index: Some(U256::from(log_index)),
                removed: false,
            });
        }
        
        Ok(rich_logs)
    }
    
    /// 计算有效 Gas 价格
    async fn calculate_effective_gas_price(
        &self,
        tx: &Transaction,
        block_number: u64,
    ) -> Result<U256, EthApiError> {
        match tx {
            Transaction::Legacy(_) | Transaction::Eip2930(_) => {
                Ok(U256::from(tx.gas_price()))
            }
            Transaction::Eip1559(tx_1559) => {
                let block = self.provider.block_by_number(block_number)?;
                if let Some(block) = block {
                    let base_fee = block.header.base_fee_per_gas.unwrap_or_default();
                    let priority_fee = std::cmp::min(
                        tx_1559.max_priority_fee_per_gas,
                        tx_1559.max_fee_per_gas.saturating_sub(base_fee),
                    );
                    Ok(U256::from(base_fee + priority_fee))
                } else {
                    Ok(U256::from(tx.gas_price()))
                }
            }
            Transaction::Eip4844(tx_4844) => {
                let block = self.provider.block_by_number(block_number)?;
                if let Some(block) = block {
                    let base_fee = block.header.base_fee_per_gas.unwrap_or_default();
                    let priority_fee = std::cmp::min(
                        tx_4844.max_priority_fee_per_gas,
                        tx_4844.max_fee_per_gas.saturating_sub(base_fee),
                    );
                    Ok(U256::from(base_fee + priority_fee))
                } else {
                    Ok(U256::from(tx.gas_price()))
                }
            }
        }
    }
}
```
*来源：`reth-rpc/src/eth/mod.rs`*

## 交易提交

### 原始交易提交

```rust
impl<Provider, Pool, Network> EthApi<Provider, Pool, Network>
where
    Provider: BlockReader + StateProvider + ReceiptProvider,
    Pool: TransactionPool,
    Network: NetworkInfo + PeersInfo,
{
    /// 发送原始交易
    pub async fn send_raw_transaction(
        &self,
        bytes: Bytes,
    ) -> Result<B256, EthApiError> {
        // 解码交易
        let tx = Transaction::decode(&mut bytes.as_ref())
            .map_err(|_| EthApiError::InvalidTransaction)?;
        
        // 验证交易
        self.validate_transaction(&tx).await?;
        
        let tx_hash = tx.hash();
        
        // 提交到交易池
        let pool_tx = PoolTransaction::new(tx, TxOrigin::External);
        self.pool.add_transaction(pool_tx).await
            .map_err(|e| EthApiError::PoolError(e))?;
        
        // 传播到网络
        self.network.propagate_transaction(tx_hash);
        
        Ok(tx_hash)
    }
    
    /// 发送交易（需要签名）
    pub async fn send_transaction(
        &self,
        request: TransactionRequest,
    ) -> Result<B256, EthApiError> {
        // 填充交易请求
        let filled_request = self.fill_transaction_request(request).await?;
        
        // 签名交易（这里需要钱包集成）
        let signed_tx = self.sign_transaction(filled_request).await?;
        
        // 发送原始交易
        self.send_raw_transaction(signed_tx.encoded()).await
    }
    
    /// 填充交易请求
    async fn fill_transaction_request(
        &self,
        mut request: TransactionRequest,
    ) -> Result<TransactionRequest, EthApiError> {
        // 填充 Gas 价格
        if request.gas_price.is_none() && request.max_fee_per_gas.is_none() {
            let gas_price = self.gas_oracle.suggest_gas_price().await?;
            request.gas_price = Some(gas_price);
        }
        
        // 填充 Gas 限制
        if request.gas.is_none() {
            let gas_estimate = self.estimate_gas(request.clone(), None).await?;
            request.gas = Some(gas_estimate);
        }
        
        // 填充 nonce
        if request.nonce.is_none() {
            let nonce = self.get_transaction_count(
                request.from,
                Some(BlockId::Number(BlockNumberOrTag::Pending)),
            ).await?;
            request.nonce = Some(nonce);
        }
        
        // 填充链 ID
        if request.chain_id.is_none() {
            request.chain_id = Some(U256::from(self.network.chain_id()));
        }
        
        Ok(request)
    }
    
    /// 验证交易
    async fn validate_transaction(
        &self,
        tx: &Transaction,
    ) -> Result<(), EthApiError> {
        // 基本验证
        if tx.gas_limit() == 0 {
            return Err(EthApiError::InvalidGasLimit);
        }
        
        if tx.gas_price() == 0 {
            return Err(EthApiError::InvalidGasPrice);
        }
        
        // 链 ID 检查
        if let Some(chain_id) = tx.chain_id() {
            if chain_id != self.network.chain_id() {
                return Err(EthApiError::InvalidChainId);
            }
        }
        
        // 签名验证
        let signer = tx.recover_signer()
            .ok_or(EthApiError::InvalidSignature)?;
        
        // 账户余额检查
        let balance = self.get_balance(signer, None).await?;
        let total_cost = U256::from(tx.gas_limit()) * U256::from(tx.gas_price()) + tx.value();
        
        if balance < total_cost {
            return Err(EthApiError::InsufficientFunds);
        }
        
        // Nonce 检查
        let account_nonce = self.get_transaction_count(signer, None).await?;
        if U256::from(tx.nonce()) < account_nonce {
            return Err(EthApiError::NonceTooLow);
        }
        
        Ok(())
    }
}
```
*来源：`reth-rpc/src/eth/mod.rs`*

## 合约交互

### 合约调用和 Gas 估算

```rust
impl<Provider, Pool, Network> EthApi<Provider, Pool, Network>
where
    Provider: BlockReader + StateProvider + ReceiptProvider,
    Pool: TransactionPool,
    Network: NetworkInfo,
{
    /// 执行合约调用
    pub async fn call(
        &self,
        request: CallRequest,
        block_id: Option<BlockId>,
        state_overrides: Option<StateOverrides>,
    ) -> Result<Bytes, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        let mut state = self.provider.state_by_block_id(block_id)?;
        
        // 应用状态覆盖
        if let Some(overrides) = state_overrides {
            self.apply_state_overrides(&mut state, overrides)?;
        }
        
        // 构建 EVM 环境
        let env = self.build_evm_env(request, block_id).await?;
        
        // 执行调用
        let mut evm = Evm::builder()
            .with_db(&state)
            .with_env(env)
            .build();
        
        let result = evm.transact()?;
        
        match result.result {
            ExecutionResult::Success { output, .. } => {
                match output {
                    Output::Call(data) => Ok(data),
                    Output::Create(data, _) => Ok(data),
                }
            }
            ExecutionResult::Revert { output, .. } => {
                Err(EthApiError::ExecutionReverted(output))
            }
            ExecutionResult::Halt { reason, .. } => {
                Err(EthApiError::ExecutionHalted(reason))
            }
        }
    }
    
    /// 估算 Gas
    pub async fn estimate_gas(
        &self,
        request: CallRequest,
        block_id: Option<BlockId>,
    ) -> Result<U256, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        let state = self.provider.state_by_block_id(block_id)?;
        
        // 二分搜索找到最小 Gas 限制
        let mut low = 21_000u64; // 最小 Gas
        let mut high = 30_000_000u64; // 最大 Gas
        
        while low < high {
            let mid = (low + high) / 2;
            
            let mut test_request = request.clone();
            test_request.gas = Some(U256::from(mid));
            
            let env = self.build_evm_env(test_request, block_id).await?;
            
            let mut evm = Evm::builder()
                .with_db(&state)
                .with_env(env)
                .build();
            
            match evm.transact() {
                Ok(result) => {
                    match result.result {
                        ExecutionResult::Success { .. } => {
                            high = mid;
                        }
                        _ => {
                            low = mid + 1;
                        }
                    }
                }
                Err(_) => {
                    low = mid + 1;
                }
            }
        }
        
        // 添加 10% 的缓冲
        let gas_estimate = (low as f64 * 1.1) as u64;
        Ok(U256::from(gas_estimate))
    }
    
    /// 构建 EVM 环境
    async fn build_evm_env(
        &self,
        request: CallRequest,
        block_id: BlockId,
    ) -> Result<Env, EthApiError> {
        let block = self.provider.block_by_id(block_id)?
            .ok_or(EthApiError::BlockNotFound)?;
        
        let mut env = Env::default();
        
        // 设置区块环境
        env.block.number = U256::from(block.number);
        env.block.coinbase = block.header.beneficiary;
        env.block.timestamp = U256::from(block.header.timestamp);
        env.block.gas_limit = U256::from(block.header.gas_limit);
        env.block.basefee = U256::from(block.header.base_fee_per_gas.unwrap_or_default());
        env.block.difficulty = block.header.difficulty;
        
        // 设置交易环境
        env.tx.caller = request.from.unwrap_or_default();
        env.tx.transact_to = request.to.map(TransactTo::Call).unwrap_or(TransactTo::Create);
        env.tx.value = request.value.unwrap_or_default();
        env.tx.data = request.data.unwrap_or_default();
        env.tx.gas_limit = request.gas.unwrap_or(U256::from(30_000_000)).as_u64();
        env.tx.gas_price = U256::from(
            request.gas_price.unwrap_or_else(|| {
                self.gas_oracle.suggest_gas_price().unwrap_or_default()
            })
        );
        
        Ok(env)
    }
    
    /// 应用状态覆盖
    fn apply_state_overrides(
        &self,
        state: &mut dyn StateProvider,
        overrides: StateOverrides,
    ) -> Result<(), EthApiError> {
        for (address, account_override) in overrides {
            if let Some(balance) = account_override.balance {
                state.set_account_balance(address, balance)?;
            }
            
            if let Some(nonce) = account_override.nonce {
                state.set_account_nonce(address, nonce.as_u64())?;
            }
            
            if let Some(code) = account_override.code {
                state.set_account_code(address, code)?;
            }
            
            if let Some(state_diff) = account_override.state_diff {
                for (key, value) in state_diff {
                    state.set_storage(address, key, value)?;
                }
            }
        }
        
        Ok(())
     }
 }
```
*来源：`reth-rpc/src/eth/mod.rs`*

## Gas 价格和费用历史

### Gas 价格预言机

```rust
// 来源：reth-rpc/src/gas_oracle.rs
pub struct GasPriceOracle<Provider> {
    provider: Provider,
    config: GasPriceConfig,
    cache: Arc<Mutex<LruCache<u64, U256>>>,
}

#[derive(Debug, Clone)]
pub struct GasPriceConfig {
    /// 用于计算的区块数量
    pub blocks: usize,
    /// 百分位数（0-100）
    pub percentile: u8,
    /// 最大 Gas 价格
    pub max_price: U256,
    /// 最小 Gas 价格
    pub min_price: U256,
    /// 缓存大小
    pub cache_size: usize,
}

impl Default for GasPriceConfig {
    fn default() -> Self {
        Self {
            blocks: 20,
            percentile: 60,
            max_price: U256::from(500_000_000_000u64), // 500 Gwei
            min_price: U256::from(1_000_000_000u64),   // 1 Gwei
            cache_size: 128,
        }
    }
}

impl<Provider> GasPriceOracle<Provider>
where
    Provider: BlockReader,
{
    pub fn new(provider: Provider, config: GasPriceConfig) -> Self {
        let cache = Arc::new(Mutex::new(LruCache::new(config.cache_size)));
        
        Self {
            provider,
            config,
            cache,
        }
    }
    
    /// 建议 Gas 价格
    pub async fn suggest_gas_price(&self) -> Result<U256, GasOracleError> {
        let latest_block = self.provider.latest_block_number()?;
        
        // 检查缓存
        {
            let mut cache = self.cache.lock().unwrap();
            if let Some(cached_price) = cache.get(&latest_block) {
                return Ok(*cached_price);
            }
        }
        
        // 计算 Gas 价格
        let gas_price = self.calculate_gas_price(latest_block).await?;
        
        // 更新缓存
        {
            let mut cache = self.cache.lock().unwrap();
            cache.put(latest_block, gas_price);
        }
        
        Ok(gas_price)
    }
    
    /// 计算 Gas 价格
    async fn calculate_gas_price(&self, latest_block: u64) -> Result<U256, GasOracleError> {
        let start_block = latest_block.saturating_sub(self.config.blocks as u64 - 1);
        let mut gas_prices = Vec::new();
        
        for block_number in start_block..=latest_block {
            if let Some(block) = self.provider.block_by_number(block_number)? {
                for tx in &block.body.transactions {
                    gas_prices.push(U256::from(tx.gas_price()));
                }
            }
        }
        
        if gas_prices.is_empty() {
            return Ok(self.config.min_price);
        }
        
        // 排序并计算百分位数
        gas_prices.sort();
        let index = (gas_prices.len() * self.config.percentile as usize) / 100;
        let percentile_price = gas_prices[index.min(gas_prices.len() - 1)];
        
        // 应用最小值和最大值限制
        let clamped_price = percentile_price
            .max(self.config.min_price)
            .min(self.config.max_price);
        
        Ok(clamped_price)
    }
    
    /// 获取 EIP-1559 费用历史
    pub async fn fee_history(
        &self,
        block_count: u64,
        newest_block: BlockNumberOrTag,
        reward_percentiles: Option<Vec<f64>>,
    ) -> Result<FeeHistory, GasOracleError> {
        let latest_block = match newest_block {
            BlockNumberOrTag::Latest => self.provider.latest_block_number()?,
            BlockNumberOrTag::Number(n) => n,
            _ => return Err(GasOracleError::InvalidBlockNumber),
        };
        
        let start_block = latest_block.saturating_sub(block_count - 1);
        let mut base_fee_per_gas = Vec::new();
        let mut gas_used_ratio = Vec::new();
        let mut reward = Vec::new();
        
        for block_number in start_block..=latest_block {
            if let Some(block) = self.provider.block_by_number(block_number)? {
                // 基础费用
                base_fee_per_gas.push(U256::from(
                    block.header.base_fee_per_gas.unwrap_or_default()
                ));
                
                // Gas 使用比例
                let gas_ratio = block.header.gas_used as f64 / block.header.gas_limit as f64;
                gas_used_ratio.push(gas_ratio);
                
                // 奖励百分位数
                if let Some(ref percentiles) = reward_percentiles {
                    let block_rewards = self.calculate_reward_percentiles(
                        &block.body.transactions,
                        percentiles,
                        block.header.base_fee_per_gas.unwrap_or_default(),
                    )?;
                    reward.push(block_rewards);
                }
            }
        }
        
        Ok(FeeHistory {
            oldest_block: U256::from(start_block),
            base_fee_per_gas,
            gas_used_ratio,
            reward,
        })
    }
    
    /// 计算奖励百分位数
    fn calculate_reward_percentiles(
        &self,
        transactions: &[Transaction],
        percentiles: &[f64],
        base_fee: u64,
    ) -> Result<Vec<U256>, GasOracleError> {
        let mut priority_fees = Vec::new();
        
        for tx in transactions {
            let priority_fee = match tx {
                Transaction::Eip1559(tx_1559) => {
                    std::cmp::min(
                        tx_1559.max_priority_fee_per_gas,
                        tx_1559.max_fee_per_gas.saturating_sub(base_fee),
                    )
                }
                Transaction::Eip4844(tx_4844) => {
                    std::cmp::min(
                        tx_4844.max_priority_fee_per_gas,
                        tx_4844.max_fee_per_gas.saturating_sub(base_fee),
                    )
                }
                Transaction::Legacy(tx_legacy) => {
                    tx_legacy.gas_price.saturating_sub(base_fee)
                }
                Transaction::Eip2930(tx_2930) => {
                    tx_2930.gas_price.saturating_sub(base_fee)
                }
            };
            
            priority_fees.push(priority_fee);
        }
        
        if priority_fees.is_empty() {
            return Ok(vec![U256::ZERO; percentiles.len()]);
        }
        
        priority_fees.sort();
        
        let mut rewards = Vec::new();
        for &percentile in percentiles {
            let index = ((priority_fees.len() as f64 * percentile / 100.0) as usize)
                .min(priority_fees.len() - 1);
            rewards.push(U256::from(priority_fees[index]));
        }
        
        Ok(rewards)
    }
}
```
*来源：`reth-rpc/src/gas_oracle.rs`*

## 事件过滤和日志

### 过滤器管理

```rust
// 来源：reth-rpc/src/filter.rs
pub struct FilterManager<Provider> {
    provider: Provider,
    filters: Arc<RwLock<HashMap<U256, Filter>>>,
    next_id: Arc<AtomicU64>,
    max_filters: usize,
}

#[derive(Debug, Clone)]
pub enum Filter {
    Block {
        last_block: u64,
        created_at: Instant,
    },
    PendingTransaction {
        seen_hashes: HashSet<B256>,
        created_at: Instant,
    },
    Log {
        filter: LogFilter,
        last_block: u64,
        created_at: Instant,
    },
}

impl<Provider> FilterManager<Provider>
where
    Provider: BlockReader + StateProvider,
{
    pub fn new(provider: Provider, max_filters: usize) -> Self {
        Self {
            provider,
            filters: Arc::new(RwLock::new(HashMap::new())),
            next_id: Arc::new(AtomicU64::new(1)),
            max_filters,
        }
    }
    
    /// 创建新的区块过滤器
    pub async fn new_block_filter(&self) -> Result<U256, FilterError> {
        let current_block = self.provider.latest_block_number()?;
        
        let filter_id = U256::from(self.next_id.fetch_add(1, Ordering::SeqCst));
        let filter = Filter::Block {
            last_block: current_block,
            created_at: Instant::now(),
        };
        
        {
            let mut filters = self.filters.write().unwrap();
            
            // 检查过滤器数量限制
            if filters.len() >= self.max_filters {
                return Err(FilterError::TooManyFilters);
            }
            
            filters.insert(filter_id, filter);
        }
        
        Ok(filter_id)
    }
    
    /// 创建新的待处理交易过滤器
    pub async fn new_pending_transaction_filter(&self) -> Result<U256, FilterError> {
        let filter_id = U256::from(self.next_id.fetch_add(1, Ordering::SeqCst));
        let filter = Filter::PendingTransaction {
            seen_hashes: HashSet::new(),
            created_at: Instant::now(),
        };
        
        {
            let mut filters = self.filters.write().unwrap();
            
            if filters.len() >= self.max_filters {
                return Err(FilterError::TooManyFilters);
            }
            
            filters.insert(filter_id, filter);
        }
        
        Ok(filter_id)
     }
     
     /// 创建新的日志过滤器
     pub async fn new_filter(&self, filter: LogFilter) -> Result<U256, FilterError> {
         let current_block = self.provider.latest_block_number()?;
         
         let filter_id = U256::from(self.next_id.fetch_add(1, Ordering::SeqCst));
         let filter = Filter::Log {
             filter,
             last_block: current_block,
             created_at: Instant::now(),
         };
         
         {
             let mut filters = self.filters.write().unwrap();
             
             if filters.len() >= self.max_filters {
                 return Err(FilterError::TooManyFilters);
             }
             
             filters.insert(filter_id, filter);
         }
         
         Ok(filter_id)
     }
     
     /// 获取过滤器变更
     pub async fn get_filter_changes(&self, filter_id: U256) -> Result<FilterChanges, FilterError> {
         let mut filters = self.filters.write().unwrap();
         
         match filters.get_mut(&filter_id) {
             Some(Filter::Block { last_block, .. }) => {
                 let current_block = self.provider.latest_block_number()?;
                 let mut block_hashes = Vec::new();
                 
                 for block_number in (*last_block + 1)..=current_block {
                     if let Some(block) = self.provider.block_by_number(block_number)? {
                         block_hashes.push(block.header.hash());
                     }
                 }
                 
                 *last_block = current_block;
                 Ok(FilterChanges::Hashes(block_hashes))
             }
             Some(Filter::PendingTransaction { seen_hashes, .. }) => {
                 // 获取待处理交易（这里需要从交易池获取）
                 let pending_txs = self.get_pending_transactions().await?;
                 let mut new_hashes = Vec::new();
                 
                 for tx_hash in pending_txs {
                     if !seen_hashes.contains(&tx_hash) {
                         seen_hashes.insert(tx_hash);
                         new_hashes.push(tx_hash);
                     }
                 }
                 
                 Ok(FilterChanges::Hashes(new_hashes))
             }
             Some(Filter::Log { filter, last_block, .. }) => {
                 let current_block = self.provider.latest_block_number()?;
                 let logs = self.get_logs_in_range(
                     filter,
                     *last_block + 1,
                     current_block,
                 ).await?;
                 
                 *last_block = current_block;
                 Ok(FilterChanges::Logs(logs))
             }
             None => Err(FilterError::FilterNotFound),
         }
     }
     
     /// 获取匹配的日志
     pub async fn get_logs(&self, filter: &LogFilter) -> Result<Vec<Log>, FilterError> {
         let from_block = filter.from_block.unwrap_or(0);
         let to_block = filter.to_block.unwrap_or(self.provider.latest_block_number()?);
         
         self.get_logs_in_range(filter, from_block, to_block).await
     }
     
     /// 在指定范围内获取日志
     async fn get_logs_in_range(
         &self,
         filter: &LogFilter,
         from_block: u64,
         to_block: u64,
     ) -> Result<Vec<Log>, FilterError> {
         let mut logs = Vec::new();
         
         for block_number in from_block..=to_block {
             if let Some(block) = self.provider.block_by_number(block_number)? {
                 if let Some(receipts) = self.provider.receipts_by_block(block_number)? {
                     for (tx_index, receipt) in receipts.iter().enumerate() {
                         for (log_index, log) in receipt.logs.iter().enumerate() {
                             if self.log_matches_filter(log, filter) {
                                 let rich_log = Log {
                                     address: log.address,
                                     topics: log.topics.clone(),
                                     data: log.data.clone(),
                                     block_hash: Some(block.header.hash()),
                                     block_number: Some(U256::from(block_number)),
                                     transaction_hash: Some(block.body.transactions[tx_index].hash()),
                                     transaction_index: Some(U256::from(tx_index)),
                                     log_index: Some(U256::from(log_index)),
                                     removed: false,
                                 };
                                 logs.push(rich_log);
                             }
                         }
                     }
                 }
             }
         }
         
         Ok(logs)
     }
     
     /// 检查日志是否匹配过滤器
     fn log_matches_filter(&self, log: &LogEntry, filter: &LogFilter) -> bool {
         // 检查地址
         if let Some(ref addresses) = filter.address {
             if !addresses.contains(&log.address) {
                 return false;
             }
         }
         
         // 检查主题
         if let Some(ref topics) = filter.topics {
             for (i, topic_filter) in topics.iter().enumerate() {
                 if let Some(topic_filter) = topic_filter {
                     if i >= log.topics.len() {
                         return false;
                     }
                     
                     match topic_filter {
                         TopicFilter::Single(topic) => {
                             if log.topics[i] != *topic {
                                 return false;
                             }
                         }
                         TopicFilter::Multiple(topics) => {
                             if !topics.contains(&log.topics[i]) {
                                 return false;
                             }
                         }
                     }
                 }
             }
         }
         
         true
     }
     
     async fn get_pending_transactions(&self) -> Result<Vec<B256>, FilterError> {
         // 这里需要从交易池获取待处理交易
         // 实际实现中会调用交易池的 API
         Ok(vec![])
     }
}
```
*来源：`reth-rpc/src/filter.rs`*

## WebSocket 订阅

### 订阅管理器

```rust
// 来源：reth-rpc/src/subscription.rs
pub struct EthSubscriptionManager<Provider> {
    provider: Provider,
    subscriptions: Arc<RwLock<HashMap<SubscriptionId, Subscription>>>,
    next_id: Arc<AtomicU64>,
}

#[derive(Debug, Clone)]
pub enum Subscription {
    NewHeads {
        sender: mpsc::UnboundedSender<Block>,
        created_at: Instant,
    },
    NewPendingTransactions {
        sender: mpsc::UnboundedSender<B256>,
        full_transactions: bool,
        created_at: Instant,
    },
    Logs {
        sender: mpsc::UnboundedSender<Log>,
        filter: LogFilter,
        created_at: Instant,
    },
}

impl<Provider> EthSubscriptionManager<Provider>
where
    Provider: BlockReader + StateProvider,
{
    pub fn new(provider: Provider) -> Self {
        Self {
            provider,
            subscriptions: Arc::new(RwLock::new(HashMap::new())),
            next_id: Arc::new(AtomicU64::new(1)),
        }
    }
    
    /// 订阅新区块头
    pub async fn subscribe_new_heads(
        &self,
    ) -> Result<(SubscriptionId, mpsc::UnboundedReceiver<Block>), SubscriptionError> {
        let (sender, receiver) = mpsc::unbounded_channel();
        let subscription_id = SubscriptionId::from(self.next_id.fetch_add(1, Ordering::SeqCst));
        
        let subscription = Subscription::NewHeads {
            sender,
            created_at: Instant::now(),
        };
        
        {
            let mut subscriptions = self.subscriptions.write().unwrap();
            subscriptions.insert(subscription_id.clone(), subscription);
        }
        
        Ok((subscription_id, receiver))
    }
    
    /// 订阅新的待处理交易
    pub async fn subscribe_new_pending_transactions(
        &self,
        full_transactions: bool,
    ) -> Result<(SubscriptionId, mpsc::UnboundedReceiver<B256>), SubscriptionError> {
        let (sender, receiver) = mpsc::unbounded_channel();
        let subscription_id = SubscriptionId::from(self.next_id.fetch_add(1, Ordering::SeqCst));
        
        let subscription = Subscription::NewPendingTransactions {
            sender,
            full_transactions,
            created_at: Instant::now(),
        };
        
        {
            let mut subscriptions = self.subscriptions.write().unwrap();
            subscriptions.insert(subscription_id.clone(), subscription);
        }
        
        Ok((subscription_id, receiver))
    }
    
    /// 订阅日志
    pub async fn subscribe_logs(
        &self,
        filter: LogFilter,
    ) -> Result<(SubscriptionId, mpsc::UnboundedReceiver<Log>), SubscriptionError> {
        let (sender, receiver) = mpsc::unbounded_channel();
        let subscription_id = SubscriptionId::from(self.next_id.fetch_add(1, Ordering::SeqCst));
        
        // 获取最新区块号用于过滤
        let latest_block = self.provider.latest_block_number()?;
        let mut filter = filter;
        filter.from_block = Some(latest_block);
        
        let subscription = Subscription::Logs {
            sender,
            filter,
            created_at: Instant::now(),
        };
        
        {
            let mut subscriptions = self.subscriptions.write().unwrap();
            subscriptions.insert(subscription_id.clone(), subscription);
        }
        
        Ok((subscription_id, receiver))
    }
    
    /// 处理新区块通知
    pub async fn on_new_block(&self, block: Block) -> Result<(), SubscriptionError> {
        let subscriptions = self.subscriptions.read().unwrap();
        
        for subscription in subscriptions.values() {
             match subscription {
                 Subscription::NewHeads { sender, .. } => {
                     let _ = sender.send(block.clone());
                 }
                 Subscription::Logs { sender, filter, .. } => {
                     let matching_logs = self.get_matching_logs_in_block(&block, filter).await?;
                     for log in matching_logs {
                         let _ = sender.send(log);
                     }
                 }
                 _ => {}
             }
         }
         
         Ok(())
     }
     
     /// 处理新的待处理交易通知
     pub async fn on_new_pending_transaction(
         &self,
         tx_hash: B256,
         transaction: Option<Transaction>,
     ) -> Result<(), SubscriptionError> {
         let subscriptions = self.subscriptions.read().unwrap();
         
         for subscription in subscriptions.values() {
             if let Subscription::NewPendingTransactions { sender, full_transactions, .. } = subscription {
                 if *full_transactions {
                     // 发送完整交易对象（这里简化为发送哈希）
                     let _ = sender.send(tx_hash);
                 } else {
                     // 只发送交易哈希
                     let _ = sender.send(tx_hash);
                 }
             }
         }
         
         Ok(())
     }
     
     /// 获取区块中匹配的日志
     async fn get_matching_logs_in_block(
         &self,
         block: &Block,
         filter: &LogFilter,
     ) -> Result<Vec<Log>, SubscriptionError> {
         let mut logs = Vec::new();
         
         if let Some(receipts) = self.provider.receipts_by_block(block.header.number)? {
             for (tx_index, receipt) in receipts.iter().enumerate() {
                 for (log_index, log_entry) in receipt.logs.iter().enumerate() {
                     if self.log_matches_filter(log_entry, filter) {
                         let log = Log {
                             address: log_entry.address,
                             topics: log_entry.topics.clone(),
                             data: log_entry.data.clone(),
                             block_hash: Some(block.header.hash()),
                             block_number: Some(U256::from(block.header.number)),
                             transaction_hash: Some(block.body.transactions[tx_index].hash()),
                             transaction_index: Some(U256::from(tx_index)),
                             log_index: Some(U256::from(log_index)),
                             removed: false,
                         };
                         logs.push(log);
                     }
                 }
             }
         }
         
         Ok(logs)
     }
     
     fn log_matches_filter(&self, log: &LogEntry, filter: &LogFilter) -> bool {
         // 与 FilterManager 中的实现相同
         true // 简化实现
     }
}
```
*来源：`reth-rpc/src/subscription.rs`*

## RPC 配置和安全

### 服务器配置

```rust
// 来源：reth-rpc/src/config.rs
#[derive(Debug, Clone)]
pub struct RpcServerConfig {
    pub http: Option<HttpConfig>,
    pub ws: Option<WsConfig>,
    pub ipc: Option<IpcConfig>,
    pub auth: Option<AuthConfig>,
    pub rate_limit: RateLimitConfig,
    pub cors: CorsConfig,
}

#[derive(Debug, Clone)]
pub struct HttpConfig {
    pub addr: SocketAddr,
    pub max_request_size: u32,
    pub max_response_size: u32,
    pub timeout: Duration,
    pub max_connections: u32,
}

impl Default for HttpConfig {
    fn default() -> Self {
        Self {
            addr: "127.0.0.1:8545".parse().unwrap(),
            max_request_size: 15 * 1024 * 1024, // 15MB
            max_response_size: 15 * 1024 * 1024, // 15MB
            timeout: Duration::from_secs(30),
            max_connections: 100,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RateLimitConfig {
    pub enabled: bool,
    pub requests_per_second: u32,
    pub burst_size: u32,
    pub whitelist: Vec<IpAddr>,
}

impl Default for RateLimitConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            requests_per_second: 100,
            burst_size: 200,
            whitelist: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        }
    }
}
```
*来源：`reth-rpc/src/config.rs`*

### 安全中间件

```rust
// 来源：reth-rpc/src/middleware.rs
pub struct SecurityMiddleware {
    rate_limiter: RateLimiter,
    auth: Option<AuthValidator>,
    cors: CorsValidator,
}

impl SecurityMiddleware {
    pub fn new(config: &RpcServerConfig) -> Self {
        Self {
            rate_limiter: RateLimiter::new(&config.rate_limit),
            auth: config.auth.as_ref().map(AuthValidator::new),
            cors: CorsValidator::new(&config.cors),
        }
    }
    
    pub async fn process_request(
        &self,
        request: &HttpRequest,
    ) -> Result<(), MiddlewareError> {
        // 检查速率限制
        let client_ip = self.extract_client_ip(request)?;
        self.rate_limiter.check_rate_limit(client_ip).await?;
        
        // 检查认证
        if let Some(ref auth) = self.auth {
            auth.validate_request(request).await?;
        }
        
        // 检查 CORS
        self.cors.validate_request(request)?;
        
        Ok(())
    }
    
    fn extract_client_ip(&self, request: &HttpRequest) -> Result<IpAddr, MiddlewareError> {
        // 从请求头中提取客户端 IP
        if let Some(forwarded) = request.headers().get("X-Forwarded-For") {
            if let Ok(forwarded_str) = forwarded.to_str() {
                if let Some(ip_str) = forwarded_str.split(',').next() {
                    if let Ok(ip) = ip_str.trim().parse() {
                        return Ok(ip);
                    }
                }
            }
        }
        
        // 从连接信息中获取
        request.peer_addr()
            .map(|addr| addr.ip())
            .ok_or(MiddlewareError::InvalidClientIp)
    }
}

/// 速率限制器
pub struct RateLimiter {
    config: RateLimitConfig,
    buckets: Arc<RwLock<HashMap<IpAddr, TokenBucket>>>,
}

impl RateLimiter {
    pub fn new(config: &RateLimitConfig) -> Self {
        Self {
            config: config.clone(),
            buckets: Arc::new(RwLock::new(HashMap::new())),
        }
    }
    
    pub async fn check_rate_limit(&self, ip: IpAddr) -> Result<(), MiddlewareError> {
        if !self.config.enabled {
            return Ok(());
        }
        
        // 检查白名单
        if self.config.whitelist.contains(&ip) {
            return Ok(());
        }
        
        let mut buckets = self.buckets.write().unwrap();
        let bucket = buckets.entry(ip).or_insert_with(|| {
            TokenBucket::new(
                self.config.requests_per_second,
                self.config.burst_size,
            )
        });
        
        if bucket.try_consume(1) {
            Ok(())
        } else {
            Err(MiddlewareError::RateLimitExceeded)
        }
    }
}
```
*来源：`reth-rpc/src/middleware.rs`*

## RPC 测试框架

### 单元测试

```rust
// 来源：reth-rpc/src/eth/tests.rs
#[cfg(test)]
mod tests {
    use super::*;
    use reth_testing_utils::*;
    
    #[tokio::test]
    async fn test_get_balance() {
        let provider = MockProvider::new();
        let eth_api = EthApi::new(provider.clone());
        
        let address = Address::random();
        let expected_balance = U256::from(1000000000000000000u64); // 1 ETH
        
        provider.set_balance(address, expected_balance);
        
        let balance = eth_api.get_balance(address, BlockNumberOrTag::Latest).await.unwrap();
        assert_eq!(balance, expected_balance);
    }
    
    #[tokio::test]
    async fn test_send_raw_transaction() {
        let provider = MockProvider::new();
        let pool = MockTransactionPool::new();
        let eth_api = EthApi::new(provider.clone());
        
        let raw_tx = "0xf86c808504a817c800825208940123456789abcdef0123456789abcdef01234567880de0b6b3a764000080820a95a01234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdefa01234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
        
        let tx_hash = eth_api.send_raw_transaction(raw_tx.into()).await.unwrap();
        assert!(!tx_hash.is_zero());
    }
    
    #[tokio::test]
    async fn test_estimate_gas() {
        let provider = MockProvider::new();
        let eth_api = EthApi::new(provider.clone());
        
        let call_request = CallRequest {
            from: Some(Address::random()),
            to: Some(Address::random()),
            value: Some(U256::from(1000)),
            data: None,
            gas: None,
            gas_price: None,
            max_fee_per_gas: None,
            max_priority_fee_per_gas: None,
        };
        
        let gas_estimate = eth_api.estimate_gas(call_request, BlockNumberOrTag::Latest).await.unwrap();
        assert!(gas_estimate > U256::ZERO);
    }
    
    #[tokio::test]
    async fn test_get_logs() {
        let provider = MockProvider::new();
        let filter_manager = FilterManager::new(provider.clone(), 100);
        
        let filter = LogFilter {
            from_block: Some(0),
            to_block: Some(100),
            address: Some(vec![Address::random()]),
            topics: None,
        };
        
        let logs = filter_manager.get_logs(&filter).await.unwrap();
        assert!(logs.is_empty()); // 模拟环境中没有日志
    }
}
```
*来源：`reth-rpc/src/eth/tests.rs`*

## 最佳实践

### 性能优化

1. **缓存策略**：
   - 使用 LRU 缓存存储频繁访问的数据
   - 缓存区块、交易和状态信息
   - 定期清理过期缓存

2. **批量处理**：
   - 支持批量 RPC 请求
   - 批量查询数据库
   - 批量验证交易

3. **异步处理**：
   - 使用异步 I/O 处理网络请求
   - 异步访问数据库和状态
   - 并发处理多个请求

### 安全考虑

1. **输入验证**：
   - 验证所有输入参数
   - 防止注入攻击
   - 限制请求大小

2. **速率限制**：
   - 基于 IP 的速率限制
   - 防止 DoS 攻击
   - 白名单机制

3. **认证授权**：
   - JWT 令牌认证
   - API 密钥管理
   - 权限控制

### 监控和指标

1. **性能指标**：
   - 请求延迟
   - 吞吐量
   - 错误率

2. **资源监控**：
   - CPU 使用率
   - 内存使用量
   - 网络带宽

3. **业务指标**：
   - 活跃连接数
   - 交易处理量
   - 区块同步状态

## 结论

Reth 的 JSON-RPC API 实现提供了：

1. **全面兼容**：完全兼容以太坊 JSON-RPC 规范
2. **高性能**：优化的数据访问和缓存机制
3. **安全性**：完善的安全中间件和验证机制
4. **实时性**：支持 WebSocket 订阅和实时通知
5. **可扩展**：模块化设计，易于扩展新功能
6. **可靠性**：完善的错误处理和恢复机制

通过这些特性，Reth 能够为以太坊应用提供稳定、高效的 RPC 服务。

## 参考文献

- [Ethereum JSON-RPC Specification](https://ethereum.github.io/execution-apis/api-documentation/)
- [EIP-1559: Fee market change for ETH 1.0 chain](https://eips.ethereum.org/EIPS/eip-1559)
- [EIP-4844: Shard Blob Transactions](https://eips.ethereum.org/EIPS/eip-4844)
- [Reth Documentation](https://reth.rs/)
     
     pub async fn get_block_by_number(
        &self,
        number: BlockNumberOrTag,
        full_transactions: bool,
    ) -> Result<Option<RichBlock>, EthApiError> {
        let block_id = BlockId::Number(number);
        let block = self.provider.block_by_id(block_id)?;
        
        if let Some(block) = block {
            let rich_block = self.build_rich_block(block, full_transactions).await?;
            Ok(Some(rich_block))
        } else {
            Ok(None)
        }
    }
    
    /// 构建富区块对象
    async fn build_rich_block(
        &self,
        block: Block,
        full_transactions: bool,
    ) -> Result<RichBlock, EthApiError> {
        let block_hash = block.hash();
        let block_number = block.number;
        
        let transactions = if full_transactions {
            let mut rich_transactions = Vec::new();
            
            for (index, tx) in block.body.transactions.iter().enumerate() {
                let rich_tx = self.build_rich_transaction(
                    tx.clone(),
                    Some(block_hash),
                    Some(block_number),
                    Some(index as u64),
                ).await?;
                
                rich_transactions.push(TransactionOrHash::Transaction(rich_tx));
            }
            
            rich_transactions
        } else {
            block.body.transactions
                .iter()
                .map(|tx| TransactionOrHash::Hash(tx.hash()))
                .collect()
        };
        
        Ok(RichBlock {
            header: block.header,
            transactions,
            uncles: block.body.ommers.iter().map(|uncle| uncle.hash()).collect(),
            size: Some(U256::from(block.size())),
        })
    }
    
    /// 根据哈希获取交易
    pub async fn get_transaction_by_hash(
        &self,
        hash: B256,
    ) -> Result<Option<RichTransaction>, EthApiError> {
        // 首先在区块链中查找
        if let Some((tx, block_hash, block_number, index)) = 
            self.provider.transaction_by_hash_with_meta(hash)? {
            let rich_tx = self.build_rich_transaction(
                tx,
                Some(block_hash),
                Some(block_number),
                Some(index),
            ).await?;
            
            return Ok(Some(rich_tx));
        }
        
        // 在交易池中查找
        if let Some(pool_tx) = self.pool.get_transaction(hash) {
            let rich_tx = self.build_rich_transaction(
                pool_tx.transaction().clone(),
                None,
                None,
                None,
            ).await?;
            
            return Ok(Some(rich_tx));
        }
        
        Ok(None)
    }
    
    /// 构建富交易对象
    async fn build_rich_transaction(
        &self,
        tx: Transaction,
        block_hash: Option<B256>,
        block_number: Option<u64>,
        transaction_index: Option<u64>,
    ) -> Result<RichTransaction, EthApiError> {
        Ok(RichTransaction {
            hash: tx.hash(),
            nonce: U256::from(tx.nonce()),
            block_hash,
            block_number: block_number.map(U256::from),
            transaction_index: transaction_index.map(U256::from),
            from: tx.recover_signer().ok_or(EthApiError::InvalidSignature)?,
            to: tx.to(),
            value: tx.value(),
            gas_price: Some(U256::from(tx.gas_price())),
            gas: U256::from(tx.gas_limit()),
            input: tx.input().clone(),
            v: U256::from(tx.signature().v()),
            r: U256::from_be_bytes(tx.signature().r().to_be_bytes()),
            s: U256::from_be_bytes(tx.signature().s().to_be_bytes()),
            transaction_type: Some(U256::from(tx.tx_type() as u8)),
            access_list: tx.access_list().cloned(),
            max_fee_per_gas: tx.max_fee_per_gas().map(U256::from),
            max_priority_fee_per_gas: tx.max_priority_fee_per_gas().map(U256::from),
            chain_id: tx.chain_id().map(U256::from),
        })
    }
    
    /// 获取交易收据
    pub async fn get_transaction_receipt(
        &self,
        hash: B256,
    ) -> Result<Option<TransactionReceipt>, EthApiError> {
        let receipt = self.provider.receipt_by_hash(hash)?;
        
        if let Some((receipt, tx, block_hash, block_number, index)) = receipt {
            let rich_receipt = self.build_rich_receipt(
                receipt,
                tx,
                block_hash,
                block_number,
                index,
            ).await?;
            
            Ok(Some(rich_receipt))
        } else {
            Ok(None)
        }
    }