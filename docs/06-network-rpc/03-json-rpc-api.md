# JSON-RPC API: Ethereum Client Interface

## Overview

<mcreference link="https://github.com/paradigmxyz/reth" index="1">1</mcreference> Reth provides a comprehensive JSON-RPC API that enables applications to interact with the Ethereum blockchain. This API follows the Ethereum JSON-RPC specification and provides access to blockchain data, transaction submission, contract interaction, and various utility functions. <mcreference link="https://github.com/etclabscore/ethereum-json-rpc-specification" index="5">5</mcreference> The implementation ensures compatibility with existing Ethereum tooling while providing enhanced performance and reliability.

## RPC Server Architecture

### Core Components

```rust
// From reth-rpc/src/lib.rs
pub struct RpcServer {
    /// HTTP server configuration
    http_config: HttpConfig,
    /// WebSocket server configuration
    ws_config: Option<WsConfig>,
    /// IPC server configuration
    ipc_config: Option<IpcConfig>,
    /// RPC module registry
    modules: RpcModuleRegistry,
    /// Middleware stack
    middleware: MiddlewareStack,
    /// Authentication handler
    auth: Option<AuthHandler>,
}

impl RpcServer {
    pub fn new(config: RpcServerConfig) -> Self {
        Self {
            http_config: config.http,
            ws_config: config.ws,
            ipc_config: config.ipc,
            modules: RpcModuleRegistry::new(),
            middleware: MiddlewareStack::new(),
            auth: config.auth,
        }
    }
    
    pub async fn start(&mut self) -> Result<RpcServerHandle, RpcError> {
        // Start HTTP server
        let http_handle = if self.http_config.enabled {
            Some(self.start_http_server().await?)
        } else {
            None
        };
        
        // Start WebSocket server
        let ws_handle = if let Some(ws_config) = &self.ws_config {
            Some(self.start_ws_server(ws_config).await?)
        } else {
            None
        };
        
        // Start IPC server
        let ipc_handle = if let Some(ipc_config) = &self.ipc_config {
            Some(self.start_ipc_server(ipc_config).await?)
        } else {
            None
        };
        
        Ok(RpcServerHandle {
            http: http_handle,
            ws: ws_handle,
            ipc: ipc_handle,
        })
    }
}
```
*Source: `reth-rpc/src/lib.rs`*

### Module Registry

```rust
// From reth-rpc/src/registry.rs
pub struct RpcModuleRegistry {
    /// Registered RPC modules
    modules: HashMap<String, Box<dyn RpcModule>>,
    /// Module dependencies
    dependencies: HashMap<String, Vec<String>>,
}

impl RpcModuleRegistry {
    pub fn new() -> Self {
        Self {
            modules: HashMap::new(),
            dependencies: HashMap::new(),
        }
    }
    
    pub fn register_module<M: RpcModule + 'static>(
        &mut self,
        name: String,
        module: M,
        deps: Vec<String>,
    ) -> Result<(), RegistryError> {
        // Check dependencies
        for dep in &deps {
            if !self.modules.contains_key(dep) {
                return Err(RegistryError::MissingDependency(dep.clone()));
            }
        }
        
        // Register module
        self.modules.insert(name.clone(), Box::new(module));
        self.dependencies.insert(name, deps);
        
        Ok(())
    }
    
    pub fn build_server(&self) -> Result<jsonrpsee::RpcModule<()>, RegistryError> {
        let mut server = jsonrpsee::RpcModule::new(());
        
        // Add modules in dependency order
        let ordered_modules = self.resolve_dependencies()?;
        
        for module_name in ordered_modules {
            if let Some(module) = self.modules.get(&module_name) {
                module.register_methods(&mut server)?;
            }
        }
        
        Ok(server)
    }
}
```
*Source: `reth-rpc/src/registry.rs`*

## Ethereum RPC Methods

### Account and Balance Methods

```rust
// From reth-rpc/src/eth/mod.rs
pub struct EthApi<Provider, Pool, Network> {
    /// Blockchain data provider
    provider: Provider,
    /// Transaction pool
    pool: Pool,
    /// Network interface
    network: Network,
    /// Gas price oracle
    gas_oracle: GasPriceOracle,
    /// Fee history cache
    fee_history_cache: FeeHistoryCache,
}

impl<Provider, Pool, Network> EthApi<Provider, Pool, Network>
where
    Provider: BlockReader + StateProvider + EvmEnvProvider,
    Pool: TransactionPool,
    Network: NetworkInfo,
{
    /// Get account balance
    pub async fn get_balance(
        &self,
        address: Address,
        block_id: Option<BlockId>,
    ) -> Result<U256, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        
        // Get state at specified block
        let state = self.provider.state_by_block_id(block_id)?;
        
        // Query account balance
        let account = state.basic_account(address)?;
        let balance = account.map(|acc| acc.balance).unwrap_or_default();
        
        Ok(balance)
    }
    
    /// Get account transaction count (nonce)
    pub async fn get_transaction_count(
        &self,
        address: Address,
        block_id: Option<BlockId>,
    ) -> Result<U256, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        
        match block_id {
            BlockId::Number(BlockNumberOrTag::Pending) => {
                // For pending, check transaction pool
                let pool_nonce = self.pool.get_account_nonce(address);
                let state_nonce = self.get_state_nonce(address, BlockId::Number(BlockNumberOrTag::Latest))?;
                Ok(U256::from(std::cmp::max(pool_nonce, state_nonce)))
            }
            _ => {
                // For other blocks, query state directly
                self.get_state_nonce(address, block_id)
            }
        }
    }
    
    fn get_state_nonce(&self, address: Address, block_id: BlockId) -> Result<u64, EthApiError> {
        let state = self.provider.state_by_block_id(block_id)?;
        let account = state.basic_account(address)?;
        Ok(account.map(|acc| acc.nonce).unwrap_or_default())
    }
    
    /// Get account code
    pub async fn get_code(
        &self,
        address: Address,
        block_id: Option<BlockId>,
    ) -> Result<Bytes, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        let state = self.provider.state_by_block_id(block_id)?;
        
        let account = state.basic_account(address)?;
        if let Some(account) = account {
            if account.code_hash != KECCAK_EMPTY {
                let code = state.account_code(address)?;
                return Ok(code.unwrap_or_default().bytes());
            }
        }
        
        Ok(Bytes::default())
    }
    
    /// Get storage value at specific slot
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
*Source: `reth-rpc/src/eth/mod.rs`*

### Block and Transaction Methods

```rust
impl<Provider, Pool, Network> EthApi<Provider, Pool, Network> {
    /// Get block by hash
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
    
    /// Get block by number
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
    
    async fn build_rich_block(
        &self,
        block: Block,
        full_transactions: bool,
    ) -> Result<RichBlock, EthApiError> {
        let header = &block.header;
        let transactions = if full_transactions {
            // Include full transaction objects
            let mut rich_txs = Vec::new();
            for (index, tx) in block.body.iter().enumerate() {
                let rich_tx = self.build_rich_transaction(
                    tx.clone(),
                    Some(header.hash()),
                    Some(header.number),
                    Some(index as u64),
                ).await?;
                rich_txs.push(TransactionOrHash::Transaction(rich_tx));
            }
            rich_txs
        } else {
            // Include only transaction hashes
            block.body.iter()
                .map(|tx| TransactionOrHash::Hash(tx.hash()))
                .collect()
        };
        
        Ok(RichBlock {
            header: header.clone().into(),
            transactions,
            uncles: Vec::new(), // Reth doesn't support uncles (post-merge)
            size: Some(U256::from(block.encoded_length())),
        })
    }
    
    /// Get transaction by hash
    pub async fn get_transaction_by_hash(
        &self,
        hash: TxHash,
    ) -> Result<Option<Transaction>, EthApiError> {
        // First check if transaction is in a block
        if let Some(tx_info) = self.provider.transaction_by_hash(hash)? {
            let rich_tx = self.build_rich_transaction(
                tx_info.transaction,
                tx_info.block_hash,
                tx_info.block_number,
                tx_info.index,
            ).await?;
            return Ok(Some(rich_tx));
        }
        
        // Check transaction pool for pending transactions
        if let Some(pooled_tx) = self.pool.get_transaction(hash) {
            let rich_tx = self.build_rich_transaction(
                pooled_tx.transaction,
                None, // No block hash for pending
                None, // No block number for pending
                None, // No index for pending
            ).await?;
            return Ok(Some(rich_tx));
        }
        
        Ok(None)
    }
    
    async fn build_rich_transaction(
        &self,
        tx: TransactionSigned,
        block_hash: Option<B256>,
        block_number: Option<u64>,
        transaction_index: Option<u64>,
    ) -> Result<Transaction, EthApiError> {
        Ok(Transaction {
            hash: tx.hash(),
            nonce: U256::from(tx.nonce()),
            block_hash,
            block_number: block_number.map(U256::from),
            transaction_index: transaction_index.map(U256::from),
            from: tx.sender(),
            to: tx.to(),
            value: tx.value(),
            gas_price: Some(U256::from(tx.gas_price())),
            gas: U256::from(tx.gas_limit()),
            input: tx.input().clone(),
            // EIP-1559 fields
            max_fee_per_gas: tx.max_fee_per_gas().map(U256::from),
            max_priority_fee_per_gas: tx.max_priority_fee_per_gas().map(U256::from),
            // EIP-2930 fields
            access_list: tx.access_list().cloned(),
            // EIP-4844 fields
            max_fee_per_blob_gas: tx.max_fee_per_blob_gas().map(U256::from),
            blob_versioned_hashes: tx.blob_versioned_hashes().cloned().unwrap_or_default(),
            // Signature fields
            v: U256::from(tx.signature().v()),
            r: U256::from_be_bytes(tx.signature().r().to_bytes()),
            s: U256::from_be_bytes(tx.signature().s().to_bytes()),
        })
    }
}
```

### Transaction Receipt Methods

```rust
impl<Provider, Pool, Network> EthApi<Provider, Pool, Network> {
    /// Get transaction receipt
    pub async fn get_transaction_receipt(
        &self,
        hash: TxHash,
    ) -> Result<Option<TransactionReceipt>, EthApiError> {
        let receipt_info = self.provider.receipt_by_hash(hash)?;
        
        if let Some(receipt_info) = receipt_info {
            let rich_receipt = self.build_rich_receipt(
                receipt_info.receipt,
                receipt_info.transaction,
                receipt_info.block_hash,
                receipt_info.block_number,
                receipt_info.transaction_index,
            ).await?;
            Ok(Some(rich_receipt))
        } else {
            Ok(None)
        }
    }
    
    async fn build_rich_receipt(
        &self,
        receipt: Receipt,
        transaction: TransactionSigned,
        block_hash: B256,
        block_number: u64,
        transaction_index: u64,
    ) -> Result<TransactionReceipt, EthApiError> {
        // Calculate effective gas price
        let effective_gas_price = self.calculate_effective_gas_price(&transaction, block_number).await?;
        
        // Get block to calculate gas used by this transaction
        let block = self.provider.block_by_hash(block_hash)?
            .ok_or(EthApiError::BlockNotFound)?;
        
        let gas_used = if transaction_index == 0 {
            receipt.cumulative_gas_used
        } else {
            let prev_receipt = self.provider.receipt_by_hash(
                block.body[transaction_index as usize - 1].hash()
            )?.ok_or(EthApiError::ReceiptNotFound)?;
            receipt.cumulative_gas_used - prev_receipt.receipt.cumulative_gas_used
        };
        
        Ok(TransactionReceipt {
            transaction_hash: transaction.hash(),
            transaction_index: U256::from(transaction_index),
            block_hash: Some(block_hash),
            block_number: Some(U256::from(block_number)),
            from: transaction.sender(),
            to: transaction.to(),
            cumulative_gas_used: U256::from(receipt.cumulative_gas_used),
            gas_used: Some(U256::from(gas_used)),
            contract_address: self.calculate_contract_address(&transaction),
            logs: self.build_rich_logs(receipt.logs, block_hash, block_number, transaction_index),
            status: Some(U256::from(receipt.success as u8)),
            root: None, // Post-Byzantium doesn't include state root
            logs_bloom: receipt.logs_bloom,
            transaction_type: Some(U256::from(transaction.tx_type() as u8)),
            effective_gas_price: Some(effective_gas_price),
            // EIP-4844 fields
            blob_gas_used: receipt.blob_gas_used.map(U256::from),
            blob_gas_price: receipt.blob_gas_price,
        })
    }
    
    fn build_rich_logs(
        &self,
        logs: Vec<Log>,
        block_hash: B256,
        block_number: u64,
        transaction_index: u64,
    ) -> Vec<Log> {
        logs.into_iter()
            .enumerate()
            .map(|(log_index, mut log)| {
                log.block_hash = Some(block_hash);
                log.block_number = Some(U256::from(block_number));
                log.transaction_hash = Some(transaction.hash());
                log.transaction_index = Some(U256::from(transaction_index));
                log.log_index = Some(U256::from(log_index));
                log.removed = false;
                log
            })
            .collect()
    }
    
    async fn calculate_effective_gas_price(
        &self,
        transaction: &TransactionSigned,
        block_number: u64,
    ) -> Result<U256, EthApiError> {
        match &transaction.transaction {
            Transaction::Legacy(tx) => Ok(U256::from(tx.gas_price)),
            Transaction::Eip2930(tx) => Ok(U256::from(tx.gas_price)),
            Transaction::Eip1559(tx) | Transaction::Eip4844(tx) => {
                // Get base fee for the block
                let block = self.provider.block_by_number(block_number)?
                    .ok_or(EthApiError::BlockNotFound)?;
                
                let base_fee = block.header.base_fee_per_gas.unwrap_or_default();
                let priority_fee = tx.max_priority_fee_per_gas;
                let max_fee = tx.max_fee_per_gas;
                
                let effective_gas_price = std::cmp::min(max_fee, base_fee + priority_fee);
                Ok(U256::from(effective_gas_price))
            }
        }
    }
}
```

## Transaction Submission

### Send Transaction Methods

```rust
impl<Provider, Pool, Network> EthApi<Provider, Pool, Network> {
    /// Send raw transaction
    pub async fn send_raw_transaction(
        &self,
        bytes: Bytes,
    ) -> Result<TxHash, EthApiError> {
        // Decode transaction from raw bytes
        let transaction = TransactionSigned::decode(&mut bytes.as_ref())
            .map_err(|e| EthApiError::InvalidTransaction(e.to_string()))?;
        
        // Validate transaction
        self.validate_transaction(&transaction).await?;
        
        // Submit to transaction pool
        let hash = self.pool.add_transaction(transaction, false)
            .map_err(|e| EthApiError::PoolError(e))?;
        
        // Propagate to network
        self.network.propagate_transaction(hash).await?;
        
        Ok(hash)
    }
    
    /// Send transaction (requires unlocked account)
    pub async fn send_transaction(
        &self,
        request: TransactionRequest,
    ) -> Result<TxHash, EthApiError> {
        // Fill missing transaction fields
        let filled_request = self.fill_transaction_request(request).await?;
        
        // Sign transaction (this would require account management)
        let signed_transaction = self.sign_transaction(filled_request).await?;
        
        // Submit signed transaction
        self.send_raw_transaction(signed_transaction.encoded()).await
    }
    
    async fn fill_transaction_request(
        &self,
        mut request: TransactionRequest,
    ) -> Result<TransactionRequest, EthApiError> {
        // Fill gas price if not specified
        if request.gas_price.is_none() && request.max_fee_per_gas.is_none() {
            request.gas_price = Some(self.gas_oracle.suggest_gas_price().await?);
        }
        
        // Fill gas limit if not specified
        if request.gas.is_none() {
            request.gas = Some(self.estimate_gas(&request, None).await?);
        }
        
        // Fill nonce if not specified
        if request.nonce.is_none() {
            let from = request.from.ok_or(EthApiError::MissingFrom)?;
            request.nonce = Some(self.get_transaction_count(from, None).await?);
        }
        
        // Fill chain ID
        if request.chain_id.is_none() {
            request.chain_id = Some(U256::from(self.network.chain_id()));
        }
        
        Ok(request)
    }
    
    async fn validate_transaction(
        &self,
        transaction: &TransactionSigned,
    ) -> Result<(), EthApiError> {
        // Basic validation
        if transaction.gas_limit() == 0 {
            return Err(EthApiError::InvalidTransaction("Zero gas limit".to_string()));
        }
        
        // Check chain ID
        if let Some(chain_id) = transaction.chain_id() {
            if chain_id != self.network.chain_id() {
                return Err(EthApiError::InvalidChainId);
            }
        }
        
        // Verify signature
        let sender = transaction.recover_signer()
            .ok_or(EthApiError::InvalidSignature)?;
        
        // Check account balance and nonce
        let account = self.provider.basic_account(sender)?
            .unwrap_or_default();
        
        if transaction.nonce() < account.nonce {
            return Err(EthApiError::NonceTooLow);
        }
        
        let transaction_cost = transaction.value() + 
            U256::from(transaction.gas_limit()) * U256::from(transaction.gas_price());
        
        if account.balance < transaction_cost {
            return Err(EthApiError::InsufficientFunds);
        }
        
        Ok(())
    }
}
```

## Contract Interaction

### Call and Estimate Gas

```rust
impl<Provider, Pool, Network> EthApi<Provider, Pool, Network> {
    /// Execute a contract call without creating a transaction
    pub async fn call(
        &self,
        request: CallRequest,
        block_id: Option<BlockId>,
        state_overrides: Option<StateOverride>,
    ) -> Result<Bytes, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        
        // Get state at specified block
        let mut state = self.provider.state_by_block_id(block_id)?;
        
        // Apply state overrides if provided
        if let Some(overrides) = state_overrides {
            self.apply_state_overrides(&mut state, overrides)?;
        }
        
        // Configure EVM environment
        let env = self.build_evm_env(&request, block_id).await?;
        
        // Execute call
        let mut evm = revm::EVM::with_env_and_db(env, state);
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
    
    /// Estimate gas required for a transaction
    pub async fn estimate_gas(
        &self,
        request: &CallRequest,
        block_id: Option<BlockId>,
    ) -> Result<U256, EthApiError> {
        let block_id = block_id.unwrap_or(BlockId::Number(BlockNumberOrTag::Latest));
        
        // Get state at specified block
        let state = self.provider.state_by_block_id(block_id)?;
        
        // Configure EVM environment with high gas limit for estimation
        let mut env = self.build_evm_env(request, block_id).await?;
        env.tx.gas_limit = u64::MAX;
        
        // Execute transaction
        let mut evm = revm::EVM::with_env_and_db(env, state);
        let result = evm.transact()?;
        
        match result.result {
            ExecutionResult::Success { gas_used, .. } => {
                // Add buffer to estimated gas (10%)
                let estimated_gas = gas_used + (gas_used / 10);
                Ok(U256::from(estimated_gas))
            }
            ExecutionResult::Revert { gas_used, output } => {
                // Transaction would revert, but we can still estimate gas
                Ok(U256::from(gas_used))
            }
            ExecutionResult::Halt { reason, gas_used } => {
                match reason {
                    HaltReason::OutOfGas(_) => {
                        // Need more gas, return a higher estimate
                        Ok(U256::from(gas_used * 2))
                    }
                    _ => Err(EthApiError::ExecutionHalted(reason)),
                }
            }
        }
    }
    
    async fn build_evm_env(
        &self,
        request: &CallRequest,
        block_id: BlockId,
    ) -> Result<Env, EthApiError> {
        let block = self.provider.block_by_id(block_id)?
            .ok_or(EthApiError::BlockNotFound)?;
        
        let mut env = Env::default();
        
        // Configure block environment
        env.block.number = U256::from(block.header.number);
        env.block.coinbase = block.header.beneficiary;
        env.block.timestamp = U256::from(block.header.timestamp);
        env.block.gas_limit = U256::from(block.header.gas_limit);
        env.block.basefee = U256::from(block.header.base_fee_per_gas.unwrap_or_default());
        env.block.difficulty = block.header.difficulty;
        env.block.prevrandao = Some(block.header.mix_hash);
        
        // Configure transaction environment
        env.tx.caller = request.from.unwrap_or_default();
        env.tx.gas_limit = request.gas.map(|g| g.to::<u64>()).unwrap_or(u64::MAX);
        env.tx.gas_price = U256::from(request.gas_price.unwrap_or_default());
        env.tx.transact_to = match request.to {
            Some(to) => TransactTo::Call(to),
            None => TransactTo::Create(CreateScheme::Create),
        };
        env.tx.value = request.value.unwrap_or_default();
        env.tx.data = request.data.clone().unwrap_or_default();
        env.tx.nonce = request.nonce.map(|n| n.to::<u64>());
        env.tx.chain_id = request.chain_id.map(|c| c.to::<u64>());
        env.tx.access_list = request.access_list.clone().unwrap_or_default();
        
        // Configure chain specification
        env.cfg.chain_id = self.network.chain_id();
        env.cfg.spec_id = self.provider.spec_id_at_block(block_id)?;
        
        Ok(env)
    }
    
    fn apply_state_overrides(
        &self,
        state: &mut dyn StateProvider,
        overrides: StateOverride,
    ) -> Result<(), EthApiError> {
        for (address, account_override) in overrides {
            // Override balance
            if let Some(balance) = account_override.balance {
                state.set_account_balance(address, balance)?;
            }
            
            // Override nonce
            if let Some(nonce) = account_override.nonce {
                state.set_account_nonce(address, nonce.to::<u64>())?;
            }
            
            // Override code
            if let Some(code) = account_override.code {
                state.set_account_code(address, code)?;
            }
            
            // Override storage
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

## Gas Price and Fee History

### Gas Price Oracle

```rust
// From reth-rpc/src/eth/gas_oracle.rs
pub struct GasPriceOracle<Provider> {
    provider: Provider,
    config: GasPriceConfig,
    cache: LruCache<u64, GasPriceInfo>,
}

impl<Provider> GasPriceOracle<Provider>
where
    Provider: BlockReader + HeaderProvider,
{
    pub fn new(provider: Provider, config: GasPriceConfig) -> Self {
        Self {
            provider,
            config,
            cache: LruCache::new(config.cache_size),
        }
    }
    
    /// Suggest gas price based on recent blocks
    pub async fn suggest_gas_price(&mut self) -> Result<U256, GasOracleError> {
        let latest_block = self.provider.latest_header()?
            .ok_or(GasOracleError::NoBlocks)?;
        
        // Check cache first
        if let Some(cached) = self.cache.get(&latest_block.number) {
            if cached.timestamp + self.config.cache_ttl > current_timestamp() {
                return Ok(cached.gas_price);
            }
        }
        
        // Calculate gas price from recent blocks
        let gas_price = self.calculate_gas_price(latest_block.number).await?;
        
        // Cache result
        self.cache.put(latest_block.number, GasPriceInfo {
            gas_price,
            timestamp: current_timestamp(),
        });
        
        Ok(gas_price)
    }
    
    async fn calculate_gas_price(&self, latest_block: u64) -> Result<U256, GasOracleError> {
        let start_block = latest_block.saturating_sub(self.config.sample_size);
        let mut gas_prices = Vec::new();
        
        // Collect gas prices from recent blocks
        for block_num in start_block..=latest_block {
            if let Some(block) = self.provider.block_by_number(block_num)? {
                // Use base fee if available (EIP-1559)
                if let Some(base_fee) = block.header.base_fee_per_gas {
                    gas_prices.push(base_fee);
                } else {
                    // Fallback to transaction gas prices
                    for tx in &block.body {
                        gas_prices.push(tx.gas_price());
                    }
                }
            }
        }
        
        if gas_prices.is_empty() {
            return Ok(U256::from(self.config.default_gas_price));
        }
        
        // Calculate percentile-based gas price
        gas_prices.sort_unstable();
        let index = (gas_prices.len() * self.config.percentile / 100).min(gas_prices.len() - 1);
        let suggested_price = gas_prices[index];
        
        // Apply bounds
        let min_price = U256::from(self.config.min_gas_price);
        let max_price = U256::from(self.config.max_gas_price);
        
        Ok(suggested_price.clamp(min_price, max_price))
    }
    
    /// Get fee history for EIP-1559
    pub async fn fee_history(
        &mut self,
        block_count: u64,
        newest_block: BlockNumberOrTag,
        reward_percentiles: Option<Vec<f64>>,
    ) -> Result<FeeHistory, GasOracleError> {
        let latest_block = match newest_block {
            BlockNumberOrTag::Latest => {
                self.provider.latest_header()?.map(|h| h.number).unwrap_or_default()
            }
            BlockNumberOrTag::Number(n) => n,
            _ => return Err(GasOracleError::InvalidBlock),
        };
        
        let start_block = latest_block.saturating_sub(block_count - 1);
        let mut base_fees = Vec::new();
        let mut gas_used_ratios = Vec::new();
        let mut rewards = Vec::new();
        
        for block_num in start_block..=latest_block {
            if let Some(block) = self.provider.block_by_number(block_num)? {
                // Base fee per gas
                base_fees.push(U256::from(block.header.base_fee_per_gas.unwrap_or_default()));
                
                // Gas used ratio
                let gas_used_ratio = block.header.gas_used as f64 / block.header.gas_limit as f64;
                gas_used_ratios.push(gas_used_ratio);
                
                // Priority fee rewards
                if let Some(percentiles) = &reward_percentiles {
                    let block_rewards = self.calculate_reward_percentiles(&block, percentiles)?;
                    rewards.push(block_rewards);
                }
            }
        }
        
        // Add next block's base fee
        if let Some(last_block) = self.provider.block_by_number(latest_block)? {
            let next_base_fee = calculate_next_base_fee(
                last_block.header.base_fee_per_gas.unwrap_or_default(),
                last_block.header.gas_used,
                last_block.header.gas_limit,
            );
            base_fees.push(U256::from(next_base_fee));
        }
        
        Ok(FeeHistory {
            oldest_block: U256::from(start_block),
            base_fee_per_gas: base_fees,
            gas_used_ratio: gas_used_ratios,
            reward: if rewards.is_empty() { None } else { Some(rewards) },
        })
    }
    
    fn calculate_reward_percentiles(
        &self,
        block: &Block,
        percentiles: &[f64],
    ) -> Result<Vec<U256>, GasOracleError> {
        let mut priority_fees = Vec::new();
        
        // Extract priority fees from EIP-1559 transactions
        let base_fee = block.header.base_fee_per_gas.unwrap_or_default();
        
        for tx in &block.body {
            match &tx.transaction {
                Transaction::Eip1559(tx) => {
                    let effective_priority_fee = std::cmp::min(
                        tx.max_priority_fee_per_gas,
                        tx.max_fee_per_gas.saturating_sub(base_fee),
                    );
                    priority_fees.push(effective_priority_fee);
                }
                Transaction::Eip4844(tx) => {
                    let effective_priority_fee = std::cmp::min(
                        tx.max_priority_fee_per_gas,
                        tx.max_fee_per_gas.saturating_sub(base_fee),
                    );
                    priority_fees.push(effective_priority_fee);
                }
                _ => {
                    // Legacy transactions: priority fee is gas_price - base_fee
                    let priority_fee = tx.gas_price().saturating_sub(base_fee);
                    priority_fees.push(priority_fee);
                }
            }
        }
        
        if priority_fees.is_empty() {
            return Ok(vec![U256::ZERO; percentiles.len()]);
        }
        
        priority_fees.sort_unstable();
        
        let mut rewards = Vec::new();
        for &percentile in percentiles {
            let index = ((priority_fees.len() - 1) as f64 * percentile / 100.0) as usize;
            rewards.push(U256::from(priority_fees[index]));
        }
        
        Ok(rewards)
    }
}
```

## Filtering and Logs

### Event Filtering

```rust
// From reth-rpc/src/eth/filter.rs
pub struct FilterManager<Provider> {
    provider: Provider,
    active_filters: HashMap<U256, Filter>,
    next_filter_id: U256,
    max_filters: usize,
}

impl<Provider> FilterManager<Provider>
where
    Provider: BlockReader + StateProvider + ReceiptProvider,
{
    pub fn new(provider: Provider, max_filters: usize) -> Self {
        Self {
            provider,
            active_filters: HashMap::new(),
            next_filter_id: U256::from(1),
            max_filters,
        }
    }
    
    /// Create a new block filter
    pub fn new_block_filter(&mut self) -> Result<U256, FilterError> {
        if self.active_filters.len() >= self.max_filters {
            return Err(FilterError::TooManyFilters);
        }
        
        let filter_id = self.next_filter_id;
        self.next_filter_id += U256::from(1);
        
        let filter = Filter::Block(BlockFilter {
            last_block: self.provider.best_block_number()?,
        });
        
        self.active_filters.insert(filter_id, filter);
        Ok(filter_id)
    }
    
    /// Create a new pending transaction filter
    pub fn new_pending_transaction_filter(&mut self) -> Result<U256, FilterError> {
        if self.active_filters.len() >= self.max_filters {
            return Err(FilterError::TooManyFilters);
        }
        
        let filter_id = self.next_filter_id;
        self.next_filter_id += U256::from(1);
        
        let filter = Filter::PendingTransaction(PendingTransactionFilter {
            seen_hashes: HashSet::new(),
        });
        
        self.active_filters.insert(filter_id, filter);
        Ok(filter_id)
    }
    
    /// Create a new log filter
    pub fn new_filter(&mut self, filter_params: FilterParams) -> Result<U256, FilterError> {
        if self.active_filters.len() >= self.max_filters {
            return Err(FilterError::TooManyFilters);
        }
        
        let filter_id = self.next_filter_id;
        self.next_filter_id += U256::from(1);
        
        let filter = Filter::Log(LogFilter {
            params: filter_params,
            last_block: self.provider.best_block_number()?,
        });
        
        self.active_filters.insert(filter_id, filter);
        Ok(filter_id)
    }
    
    /// Get filter changes
    pub fn get_filter_changes(&mut self, filter_id: U256) -> Result<FilterChanges, FilterError> {
        let filter = self.active_filters.get_mut(&filter_id)
            .ok_or(FilterError::FilterNotFound)?;
        
        match filter {
            Filter::Block(block_filter) => {
                let current_block = self.provider.best_block_number()?;
                let mut block_hashes = Vec::new();
                
                for block_num in (block_filter.last_block + 1)..=current_block {
                    if let Some(header) = self.provider.header_by_number(block_num)? {
                        block_hashes.push(header.hash());
                    }
                }
                
                block_filter.last_block = current_block;
                Ok(FilterChanges::Hashes(block_hashes))
            }
            Filter::PendingTransaction(tx_filter) => {
                // This would require integration with transaction pool
                // to get pending transaction hashes
                Ok(FilterChanges::Hashes(Vec::new()))
            }
            Filter::Log(log_filter) => {
                let current_block = self.provider.best_block_number()?;
                let logs = self.get_logs_in_range(
                    log_filter.last_block + 1,
                    current_block,
                    &log_filter.params,
                )?;
                
                log_filter.last_block = current_block;
                Ok(FilterChanges::Logs(logs))
            }
        }
    }
    
    /// Get logs matching filter criteria
    pub fn get_logs(&self, filter_params: FilterParams) -> Result<Vec<Log>, FilterError> {
        let (from_block, to_block) = self.resolve_block_range(&filter_params)?;
        self.get_logs_in_range(from_block, to_block, &filter_params)
    }
    
    fn get_logs_in_range(
        &self,
        from_block: u64,
        to_block: u64,
        filter_params: &FilterParams,
    ) -> Result<Vec<Log>, FilterError> {
        let mut matching_logs = Vec::new();
        
        for block_num in from_block..=to_block {
            if let Some(block) = self.provider.block_by_number(block_num)? {
                for (tx_index, tx) in block.body.iter().enumerate() {
                    if let Some(receipt) = self.provider.receipt_by_hash(tx.hash())? {
                        for (log_index, log) in receipt.logs.iter().enumerate() {
                            if self.log_matches_filter(log, filter_params) {
                                let mut rich_log = log.clone();
                                rich_log.block_hash = Some(block.header.hash());
                                rich_log.block_number = Some(U256::from(block_num));
                                rich_log.transaction_hash = Some(tx.hash());
                                rich_log.transaction_index = Some(U256::from(tx_index));
                                rich_log.log_index = Some(U256::from(log_index));
                                rich_log.removed = false;
                                
                                matching_logs.push(rich_log);
                            }
                        }
                    }
                }
            }
        }
        
        Ok(matching_logs)
    }
    
    fn log_matches_filter(&self, log: &Log, filter_params: &FilterParams) -> bool {
        // Check address filter
        if let Some(addresses) = &filter_params.address {
            if !addresses.contains(&log.address) {
                return false;
            }
        }
        
        // Check topics filter
        if let Some(topics) = &filter_params.topics {
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
}
```

## WebSocket Subscriptions

### Real-time Event Streaming

```rust
// From reth-rpc/src/eth/pubsub.rs
pub struct EthSubscriptionManager<Provider, Pool> {
    provider: Provider,
    pool: Pool,
    subscriptions: HashMap<SubscriptionId, Subscription>,
    next_subscription_id: u64,
}

impl<Provider, Pool> EthSubscriptionManager<Provider, Pool>
where
    Provider: BlockReader + StateProvider + ReceiptProvider,
    Pool: TransactionPool,
{
    pub fn new(provider: Provider, pool: Pool) -> Self {
        Self {
            provider,
            pool,
            subscriptions: HashMap::new(),
            next_subscription_id: 1,
        }
    }
    
    /// Subscribe to new block headers
    pub async fn subscribe_new_heads(
        &mut self,
        sink: SubscriptionSink,
    ) -> Result<SubscriptionId, SubscriptionError> {
        let subscription_id = SubscriptionId::from(self.next_subscription_id);
        self.next_subscription_id += 1;
        
        let subscription = Subscription::NewHeads(NewHeadsSubscription {
            sink,
            last_block: self.provider.best_block_number()?,
        });
        
        self.subscriptions.insert(subscription_id.clone(), subscription);
        Ok(subscription_id)
    }
    
    /// Subscribe to pending transactions
    pub async fn subscribe_new_pending_transactions(
        &mut self,
        sink: SubscriptionSink,
        full_transactions: bool,
    ) -> Result<SubscriptionId, SubscriptionError> {
        let subscription_id = SubscriptionId::from(self.next_subscription_id);
        self.next_subscription_id += 1;
        
        let subscription = Subscription::PendingTransactions(PendingTransactionsSubscription {
            sink,
            full_transactions,
            seen_hashes: HashSet::new(),
        });
        
        self.subscriptions.insert(subscription_id.clone(), subscription);
        Ok(subscription_id)
    }
    
    /// Subscribe to logs
    pub async fn subscribe_logs(
        &mut self,
        sink: SubscriptionSink,
        filter_params: FilterParams,
    ) -> Result<SubscriptionId, SubscriptionError> {
        let subscription_id = SubscriptionId::from(self.next_subscription_id);
        self.next_subscription_id += 1;
        
        let subscription = Subscription::Logs(LogsSubscription {
            sink,
            filter_params,
            last_block: self.provider.best_block_number()?,
        });
        
        self.subscriptions.insert(subscription_id.clone(), subscription);
        Ok(subscription_id)
    }
    
    /// Handle new block notification
    pub async fn on_new_block(&mut self, block: &Block) -> Result<(), SubscriptionError> {
        let mut to_remove = Vec::new();
        
        for (subscription_id, subscription) in &mut self.subscriptions {
            match subscription {
                Subscription::NewHeads(sub) => {
                    let header = RichHeader::from(&block.header);
                    if sub.sink.send(&header).await.is_err() {
                        to_remove.push(subscription_id.clone());
                    }
                }
                Subscription::Logs(sub) => {
                    // Check for matching logs in the new block
                    let matching_logs = self.get_matching_logs_in_block(block, &sub.filter_params)?;
                    
                    for log in matching_logs {
                        if sub.sink.send(&log).await.is_err() {
                            to_remove.push(subscription_id.clone());
                            break;
                        }
                    }
                }
                _ => {}
            }
        }
        
        // Remove closed subscriptions
        for subscription_id in to_remove {
            self.subscriptions.remove(&subscription_id);
        }
        
        Ok(())
    }
    
    /// Handle new pending transaction notification
    pub async fn on_new_pending_transaction(
        &mut self,
        transaction: &TransactionSigned,
    ) -> Result<(), SubscriptionError> {
        let mut to_remove = Vec::new();
        
        for (subscription_id, subscription) in &mut self.subscriptions {
            if let Subscription::PendingTransactions(sub) = subscription {
                let tx_hash = transaction.hash();
                
                if !sub.seen_hashes.contains(&tx_hash) {
                    sub.seen_hashes.insert(tx_hash);
                    
                    let notification = if sub.full_transactions {
                        // Send full transaction object
                        let rich_tx = self.build_rich_transaction(transaction.clone(), None, None, None).await?;
                        serde_json::to_value(rich_tx)?
                    } else {
                        // Send only transaction hash
                        serde_json::to_value(tx_hash)?
                    };
                    
                    if sub.sink.send(&notification).await.is_err() {
                        to_remove.push(subscription_id.clone());
                    }
                }
            }
        }
        
        // Remove closed subscriptions
        for subscription_id in to_remove {
            self.subscriptions.remove(&subscription_id);
        }
        
        Ok(())
    }
    
    fn get_matching_logs_in_block(
        &self,
        block: &Block,
        filter_params: &FilterParams,
    ) -> Result<Vec<Log>, SubscriptionError> {
        let mut matching_logs = Vec::new();
        
        for (tx_index, tx) in block.body.iter().enumerate() {
            if let Some(receipt) = self.provider.receipt_by_hash(tx.hash())? {
                for (log_index, log) in receipt.logs.iter().enumerate() {
                    if self.log_matches_filter(log, filter_params) {
                        let mut rich_log = log.clone();
                        rich_log.block_hash = Some(block.header.hash());
                        rich_log.block_number = Some(U256::from(block.header.number));
                        rich_log.transaction_hash = Some(tx.hash());
                        rich_log.transaction_index = Some(U256::from(tx_index));
                        rich_log.log_index = Some(U256::from(log_index));
                        rich_log.removed = false;
                        
                        matching_logs.push(rich_log);
                    }
                }
            }
        }
        
        Ok(matching_logs)
    }
}
```

## Configuration and Security

### RPC Configuration

```rust
// From reth-rpc/src/config.rs
#[derive(Debug, Clone)]
pub struct RpcServerConfig {
    /// HTTP server configuration
    pub http: HttpConfig,
    /// WebSocket server configuration
    pub ws: Option<WsConfig>,
    /// IPC server configuration
    pub ipc: Option<IpcConfig>,
    /// Authentication configuration
    pub auth: Option<AuthConfig>,
    /// Rate limiting configuration
    pub rate_limit: RateLimitConfig,
    /// CORS configuration
    pub cors: CorsConfig,
}

#[derive(Debug, Clone)]
pub struct HttpConfig {
    /// Enable HTTP server
    pub enabled: bool,
    /// HTTP server address
    pub addr: SocketAddr,
    /// Maximum request size
    pub max_request_size: u32,
    /// Maximum response size
    pub max_response_size: u32,
    /// Request timeout
    pub timeout: Duration,
    /// Maximum concurrent connections
    pub max_connections: u32,
}

#[derive(Debug, Clone)]
pub struct RateLimitConfig {
    /// Enable rate limiting
    pub enabled: bool,
    /// Requests per second per IP
    pub requests_per_second: u32,
    /// Burst size
    pub burst_size: u32,
    /// Whitelist of IP addresses
    pub whitelist: Vec<IpAddr>,
}

impl Default for RpcServerConfig {
    fn default() -> Self {
        Self {
            http: HttpConfig {
                enabled: true,
                addr: "127.0.0.1:8545".parse().unwrap(),
                max_request_size: 15 * 1024 * 1024, // 15 MB
                max_response_size: 15 * 1024 * 1024, // 15 MB
                timeout: Duration::from_secs(30),
                max_connections: 100,
            },
            ws: Some(WsConfig {
                enabled: true,
                addr: "127.0.0.1:8546".parse().unwrap(),
                max_connections: 100,
                max_subscriptions_per_connection: 1024,
            }),
            ipc: None, // Disabled by default
            auth: None, // No authentication by default
            rate_limit: RateLimitConfig {
                enabled: true,
                requests_per_second: 100,
                burst_size: 200,
                whitelist: vec!["127.0.0.1".parse().unwrap()],
            },
            cors: CorsConfig::default(),
        }
    }
}
```

### Security Middleware

```rust
// From reth-rpc/src/middleware.rs
pub struct SecurityMiddleware {
    rate_limiter: RateLimiter,
    auth_handler: Option<AuthHandler>,
    cors_handler: CorsHandler,
}

impl SecurityMiddleware {
    pub fn new(config: &RpcServerConfig) -> Self {
        Self {
            rate_limiter: RateLimiter::new(&config.rate_limit),
            auth_handler: config.auth.as_ref().map(AuthHandler::new),
            cors_handler: CorsHandler::new(&config.cors),
        }
    }
    
    pub async fn process_request(
        &self,
        request: &HttpRequest,
    ) -> Result<(), MiddlewareError> {
        // Rate limiting
        if !self.rate_limiter.check_rate_limit(request.remote_addr())? {
            return Err(MiddlewareError::RateLimitExceeded);
        }
        
        // Authentication
        if let Some(auth_handler) = &self.auth_handler {
            auth_handler.authenticate(request)?;
        }
        
        // CORS validation
        self.cors_handler.validate_origin(request)?;
        
        Ok(())
    }
}

pub struct RateLimiter {
    config: RateLimitConfig,
    buckets: HashMap<IpAddr, TokenBucket>,
}

impl RateLimiter {
    pub fn new(config: &RateLimitConfig) -> Self {
        Self {
            config: config.clone(),
            buckets: HashMap::new(),
        }
    }
    
    pub fn check_rate_limit(&mut self, addr: IpAddr) -> Result<bool, RateLimitError> {
        if !self.config.enabled {
            return Ok(true);
        }
        
        // Check whitelist
        if self.config.whitelist.contains(&addr) {
            return Ok(true);
        }
        
        // Get or create token bucket for this IP
        let bucket = self.buckets.entry(addr).or_insert_with(|| {
            TokenBucket::new(
                self.config.requests_per_second,
                self.config.burst_size,
            )
        });
        
        Ok(bucket.try_consume(1))
    }
}
```

## Testing and Validation

### RPC Testing Framework

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[tokio::test]
    async fn test_get_balance() {
        let provider = create_test_provider();
        let pool = create_test_pool();
        let network = create_test_network();
        
        let eth_api = EthApi::new(provider, pool, network);
        
        let address = Address::random();
        let balance = eth_api.get_balance(address, None).await.unwrap();
        
        assert_eq!(balance, U256::ZERO); // New account should have zero balance
    }
    
    #[tokio::test]
    async fn test_send_raw_transaction() {
        let provider = create_test_provider();
        let pool = create_test_pool();
        let network = create_test_network();
        
        let eth_api = EthApi::new(provider, pool, network);
        
        let tx = create_test_transaction();
        let tx_bytes = tx.encoded();
        
        let hash = eth_api.send_raw_transaction(tx_bytes).await.unwrap();
        assert_eq!(hash, tx.hash());
    }
    
    #[tokio::test]
    async fn test_estimate_gas() {
        let provider = create_test_provider();
        let pool = create_test_pool();
        let network = create_test_network();
        
        let eth_api = EthApi::new(provider, pool, network);
        
        let call_request = CallRequest {
            from: Some(Address::random()),
            to: Some(Address::random()),
            value: Some(U256::from(1000)),
            data: None,
            gas: None,
            gas_price: None,
            max_fee_per_gas: None,
            max_priority_fee_per_gas: None,
            access_list: None,
            chain_id: None,
            nonce: None,
        };
        
        let estimated_gas = eth_api.estimate_gas(&call_request, None).await.unwrap();
        assert!(estimated_gas > U256::from(21000)); // Should be more than basic transfer
    }
    
    #[tokio::test]
    async fn test_get_logs() {
        let provider = create_test_provider();
        let pool = create_test_pool();
        let network = create_test_network();
        
        let filter_manager = FilterManager::new(provider, 1000);
        
        let filter_params = FilterParams {
            from_block: Some(BlockNumberOrTag::Number(0)),
            to_block: Some(BlockNumberOrTag::Latest),
            address: None,
            topics: None,
        };
        
        let logs = filter_manager.get_logs(filter_params).unwrap();
        assert!(logs.is_empty()); // No logs in test environment
    }
}
```

## Best Practices

### Performance Optimization

1. **Caching**: Implement intelligent caching for frequently accessed data
2. **Connection Pooling**: Reuse database connections efficiently
3. **Batch Processing**: Process multiple requests together when possible
4. **Async Processing**: Use asynchronous processing for all I/O operations

### Security Considerations

1. **Rate Limiting**: Implement proper rate limiting to prevent abuse
2. **Authentication**: Use authentication for sensitive operations
3. **Input Validation**: Thoroughly validate all RPC parameters
4. **CORS Configuration**: Configure CORS properly for web applications

### Monitoring and Metrics

1. **Request Metrics**: Track request counts, response times, and error rates
2. **Resource Usage**: Monitor CPU, memory, and network usage
3. **Error Tracking**: Log and analyze RPC errors
4. **Performance Monitoring**: Track slow queries and optimize accordingly

## Conclusion

Reth's JSON-RPC API provides a comprehensive and high-performance interface for interacting with the Ethereum blockchain. Key features include:

- **Complete Ethereum Compatibility**: Full implementation of the Ethereum JSON-RPC specification
- **High Performance**: Optimized for speed and efficiency with intelligent caching
- **Security**: Comprehensive security features including rate limiting and authentication
- **Real-time Features**: WebSocket subscriptions for real-time event streaming
- **Extensibility**: Modular architecture supporting custom RPC methods
- **Reliability**: Robust error handling and recovery mechanisms

This architecture enables Reth to serve as a reliable and efficient Ethereum RPC endpoint for applications ranging from simple wallet interactions to complex DeFi protocols and blockchain analytics platforms.

## References

- [Ethereum JSON-RPC Specification](https://github.com/etclabscore/ethereum-json-rpc-specification)
- [Ethereum JSON-RPC API Documentation](https://ethereum.org/en/developers/docs/apis/json-rpc/)
- [EIP-1559: Fee Market](https://eips.ethereum.org/EIPS/eip-1559)
- [EIP-2930: Access Lists](https://eips.ethereum.org/EIPS/eip-2930)
- [EIP-4844: Blob Transactions](https://eips.ethereum.org/EIPS/eip-4844)
- [Reth RPC Implementation](https://github.com/paradigmxyz/reth)