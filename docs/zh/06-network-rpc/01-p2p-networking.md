# P2P 网络与节点发现

## 概述

Reth 的 P2P 网络层是其区块链基础设施的核心组件，负责节点发现、对等连接管理和协议通信。本章深入探讨 Reth 如何实现以太坊的 devp2p 协议栈，包括节点发现、RLPx 传输协议和以太坊线协议。

网络层的主要职责包括：
- **节点发现**：使用 Kademlia DHT 发现和维护对等节点
- **连接管理**：建立和维护与其他以太坊节点的安全连接
- **协议处理**：实现以太坊线协议进行区块和交易同步
- **会话管理**：管理对等会话的生命周期和状态

## DevP2P 协议栈

### 协议概述

DevP2P 是以太坊的网络协议栈，由三个主要层组成：

1. **发现层**：使用 UDP 进行节点发现
2. **RLPx 层**：提供加密和认证的传输
3. **应用层**：以太坊特定协议（ETH、SNAP 等）

```rust
// 来自 reth-network/src/lib.rs
pub struct NetworkStack {
    /// 节点发现服务
    discovery: Option<Discovery>,
    /// RLPx 连接管理器
    rlpx_manager: RlpxManager,
    /// 协议处理器
    protocols: HashMap<String, Box<dyn Protocol>>,
    /// 网络配置
    config: NetworkConfig,
}

impl NetworkStack {
    pub fn new(config: NetworkConfig) -> Self {
        let discovery = if config.discovery.enabled {
            Some(Discovery::new(config.local_enr().unwrap(), config.discovery.clone()))
        } else {
            None
        };
        
        let mut protocols = HashMap::new();
        
        // 注册以太坊协议
        protocols.insert(
            "eth".to_string(),
            Box::new(EthProtocol::new(config.chain.clone()))
        );
        
        // 注册快照协议
        protocols.insert(
            "snap".to_string(),
            Box::new(SnapProtocol::new())
        );
        
        Self {
            discovery,
            rlpx_manager: RlpxManager::new(config.clone()),
            protocols,
            config,
        }
    }
    
    pub async fn start(&mut self) -> Result<(), NetworkError> {
        // 启动节点发现
        if let Some(discovery) = &mut self.discovery {
            discovery.start().await?;
        }
        
        // 启动 RLPx 管理器
        self.rlpx_manager.start().await?;
        
        // 连接到引导节点
        for boot_node in &self.config.boot_nodes {
            if let Err(e) = self.connect_to_node(boot_node.clone()).await {
                warn!("连接引导节点失败: {}", e);
            }
        }
        
        Ok(())
    }
}
```
*来源：`reth-network/src/eth/messages.rs`*

## 会话管理

### SessionManager 结构

会话管理器负责维护与对等节点的活跃连接。

```rust
// 来自 reth-network/src/session.rs
pub struct SessionManager {
    /// 活跃会话
    sessions: HashMap<PeerId, Arc<PeerSession>>,
    /// 最大会话数
    max_sessions: usize,
    /// 会话配置
    config: SessionConfig,
    /// 事件发送器
    event_sender: mpsc::UnboundedSender<SessionEvent>,
}

impl SessionManager {
    pub fn new(
        max_sessions: usize,
        config: SessionConfig,
        event_sender: mpsc::UnboundedSender<SessionEvent>,
    ) -> Self {
        Self {
            sessions: HashMap::new(),
            max_sessions,
            config,
            event_sender,
        }
    }
    
    /// 添加新会话
    pub async fn add_session(
        &mut self,
        peer_id: PeerId,
        connection: RlpxConnection,
    ) -> Result<(), SessionError> {
        if self.sessions.len() >= self.max_sessions {
            return Err(SessionError::MaxSessionsReached);
        }
        
        if self.sessions.contains_key(&peer_id) {
            return Err(SessionError::SessionAlreadyExists(peer_id));
        }
        
        let session = Arc::new(PeerSession::new(
            peer_id,
            connection,
            self.config.clone(),
            self.event_sender.clone(),
        ));
        
        // 启动会话
        let session_clone = session.clone();
        tokio::spawn(async move {
            if let Err(e) = session_clone.start().await {
                error!("会话启动失败: {}", e);
            }
        });
        
        self.sessions.insert(peer_id, session);
        
        info!("添加新会话: {}", peer_id);
        Ok(())
    }
    
    /// 移除会话
    pub async fn remove_session(&mut self, peer_id: &PeerId) -> Result<(), SessionError> {
        if let Some(session) = self.sessions.remove(peer_id) {
            session.close().await;
            info!("移除会话: {}", peer_id);
            Ok(())
        } else {
            Err(SessionError::SessionNotFound(*peer_id))
        }
    }
    
    /// 广播消息到所有会话
    pub async fn broadcast_message(&self, message: EthMessage) -> Result<(), SessionError> {
        let futures: Vec<_> = self.sessions
            .values()
            .map(|session| session.send_message(message.clone()))
            .collect();
        
        // 等待所有发送完成
        let results = futures::future::join_all(futures).await;
        
        // 检查是否有失败的发送
        for result in results {
            if let Err(e) = result {
                warn!("广播消息失败: {}", e);
            }
        }
        
        Ok(())
    }
    
    /// 获取活跃会话数
    pub fn active_sessions(&self) -> usize {
        self.sessions.len()
    }
    
    /// 获取会话信息
    pub fn get_session_info(&self, peer_id: &PeerId) -> Option<SessionInfo> {
        self.sessions.get(peer_id).map(|session| session.info())
    }
}
```
*来源：`reth-network/src/session.rs`*

### PeerSession 结构

```rust
pub struct PeerSession {
    /// 对等节点 ID
    peer_id: PeerId,
    /// RLPx 连接
    connection: Arc<Mutex<RlpxConnection>>,
    /// 会话配置
    config: SessionConfig,
    /// 事件发送器
    event_sender: mpsc::UnboundedSender<SessionEvent>,
    /// 关闭信号
    shutdown: Arc<AtomicBool>,
    /// 统计信息
    stats: Arc<Mutex<SessionStats>>,
}

impl PeerSession {
    pub fn new(
        peer_id: PeerId,
        connection: RlpxConnection,
        config: SessionConfig,
        event_sender: mpsc::UnboundedSender<SessionEvent>,
    ) -> Self {
        Self {
            peer_id,
            connection: Arc::new(Mutex::new(connection)),
            config,
            event_sender,
            shutdown: Arc::new(AtomicBool::new(false)),
            stats: Arc::new(Mutex::new(SessionStats::new())),
        }
    }
    
    /// 启动会话
    pub async fn start(&self) -> Result<(), SessionError> {
        info!("启动对等节点会话: {}", self.peer_id);
        
        // 发送会话开始事件
        let _ = self.event_sender.send(SessionEvent::SessionStarted(self.peer_id));
        
        // 启动消息循环
        self.message_loop().await
    }
    
    /// 消息循环
    async fn message_loop(&self) -> Result<(), SessionError> {
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        
        loop {
            if self.shutdown.load(Ordering::Relaxed) {
                break;
            }
            
            tokio::select! {
                // 接收消息
                result = self.receive_message() => {
                    match result {
                        Ok(message) => {
                            self.handle_received_message(message).await?;
                        }
                        Err(e) => {
                            error!("接收消息失败: {}", e);
                            break;
                        }
                    }
                }
                
                // 定期心跳
                _ = interval.tick() => {
                    if let Err(e) = self.send_ping().await {
                        warn!("发送心跳失败: {}", e);
                    }
                }
            }
        }
        
        info!("会话消息循环结束: {}", self.peer_id);
        Ok(())
    }
    
    async fn receive_message(&self) -> Result<EthMessage, SessionError> {
        let mut connection = self.connection.lock().await;
        let data = connection.receive_message().await?;
        
        // 解码消息
        let message = EthMessage::decode(&data)?;
        
        // 更新统计信息
        {
            let mut stats = self.stats.lock().await;
            stats.messages_received += 1;
            stats.bytes_received += data.len() as u64;
        }
        
        Ok(message)
    }
    
    pub async fn send_message(&self, message: EthMessage) -> Result<(), SessionError> {
        let data = message.encode()?;
        
        {
            let mut connection = self.connection.lock().await;
            connection.send_message(&data).await?;
        }
        
        // 更新统计信息
        {
            let mut stats = self.stats.lock().await;
            stats.messages_sent += 1;
            stats.bytes_sent += data.len() as u64;
        }
        
        Ok(())
    }
    
    async fn send_ping(&self) -> Result<(), SessionError> {
        // 实现心跳逻辑
        // 这里可以发送 ping 消息或状态更新
        Ok(())
    }
    
    pub async fn close(&self) {
        self.shutdown.store(true, Ordering::Relaxed);
        let _ = self.event_sender.send(SessionEvent::SessionClosed(self.peer_id));
    }
    
    pub fn info(&self) -> SessionInfo {
        SessionInfo {
            peer_id: self.peer_id,
            connected_at: SystemTime::now(), // 实际应该存储连接时间
            stats: self.stats.clone(),
        }
    }
}
```
*来源：`reth-network/src/session.rs`*

## 网络配置

### NetworkConfig 结构

```rust
// 来自 reth-network/src/config.rs
#[derive(Debug, Clone)]
pub struct NetworkConfig {
    /// 本地节点的私钥
    pub secret_key: SecretKey,
    /// 监听地址
    pub listen_addr: SocketAddr,
    /// 引导节点
    pub boot_nodes: Vec<NodeRecord>,
    /// 最大对等节点数
    pub max_peers: usize,
    /// 发现配置
    pub discovery: DiscoveryConfig,
    /// 链配置
    pub chain: ChainConfig,
}

impl NetworkConfig {
    /// 创建主网配置
    pub fn mainnet() -> Self {
        Self {
            secret_key: SecretKey::random(),
            listen_addr: "0.0.0.0:30303".parse().unwrap(),
            boot_nodes: mainnet_boot_nodes(),
            max_peers: 50,
            discovery: DiscoveryConfig::default(),
            chain: ChainConfig::mainnet(),
        }
    }
    
    /// 获取对等节点 ID
    pub fn peer_id(&self) -> PeerId {
        PeerId::from_secret_key(&self.secret_key)
    }
    
    /// 创建本地 ENR
    pub fn local_enr(&self) -> Result<NodeRecord, EnrError> {
        let mut protocols = HashMap::new();
        protocols.insert("eth".to_string(), 68);
        
        NodeRecord::new(
            &self.secret_key,
            self.listen_addr,
            protocols,
            1, // 序列号
        )
    }
}

#[derive(Debug, Clone)]
pub struct DiscoveryConfig {
    /// 发现端口
    pub port: u16,
    /// 查询间隔
    pub query_interval: Duration,
    /// 最大发现的节点数
    pub max_discovered_nodes: usize,
    /// 引导查询超时
    pub bootstrap_timeout: Duration,
}

impl Default for DiscoveryConfig {
    fn default() -> Self {
        Self {
            port: 30303,
            query_interval: Duration::from_secs(60),
            max_discovered_nodes: 1000,
            bootstrap_timeout: Duration::from_secs(30),
        }
    }
}

fn mainnet_boot_nodes() -> Vec<NodeRecord> {
    // 返回以太坊主网的引导节点
    vec![
        // 这里会包含实际的引导节点 ENR
    ]
}
```
*来源：`reth-network/src/config.rs`*

## 错误处理和弹性

### 网络错误类型

```rust
// 来自 reth-network/src/error.rs
#[derive(Debug, thiserror::Error)]
pub enum NetworkError {
    #[error("连接失败: {0}")]
    ConnectionFailed(#[from] std::io::Error),
    
    #[error("握手失败: {0}")]
    HandshakeFailed(String),
    
    #[error("协议错误: {0}")]
    ProtocolError(String),
    
    #[error("对等节点断开连接: {peer_id}")]
    PeerDisconnected { peer_id: PeerId },
    
    #[error("达到最大对等节点数")]
    MaxPeersReached,
    
    #[error("发现错误: {0}")]
    Discovery(#[from] DiscoveryError),
}

#[derive(Debug, thiserror::Error)]
pub enum DiscoveryError {
    #[error("UDP 绑定失败: {0}")]
    UdpBindFailed(#[from] std::io::Error),
    
    #[error("查询超时")]
    QueryTimeout,
    
    #[error("无效的 ENR: {0}")]
    InvalidEnr(String),
    
    #[error("节点不可达: {node_id}")]
    NodeUnreachable { node_id: NodeId },
}
```
*来源：`reth-network/src/error.rs`*

### 错误恢复机制

```rust
impl NetworkManager {
    /// 处理对等节点断开连接
    async fn handle_peer_disconnection(&mut self, peer_id: PeerId) -> Result<(), NetworkError> {
        warn!("对等节点断开连接: {}", peer_id);
        
        // 从会话管理器中移除
        if let Err(e) = self.session_manager.remove_session(&peer_id).await {
            error!("移除会话失败: {}", e);
        }
        
        // 更新对等节点状态
        self.peer_manager.mark_peer_disconnected(peer_id);
        
        // 尝试发现更多对等节点
        if self.session_manager.active_sessions() < self.config.max_peers / 2 {
            self.discover_more_peers().await?;
        }
        
        Ok(())
    }
    
    /// 发现更多对等节点
    async fn discover_more_peers(&mut self) -> Result<(), NetworkError> {
        info!("开始发现更多对等节点");
        
        // 启动发现查询
        let discovered_nodes = self.discovery.find_nodes(10).await?;
        
        // 尝试连接到发现的节点
        for node in discovered_nodes {
            if self.session_manager.active_sessions() >= self.config.max_peers {
                break;
            }
            
            match self.connect_to_peer(node).await {
                Ok(_) => {
                    info!("成功连接到新对等节点: {}", node.node_id());
                }
                Err(e) => {
                    debug!("连接到对等节点失败: {}", e);
                }
            }
        }
        
        Ok(())
    }
}
```
*来源：`reth-network/src/manager.rs`*

## 性能优化

### 连接池

```rust
// 来自 reth-network/src/pool.rs
pub struct ConnectionPool {
    /// 空闲连接
    idle_connections: VecDeque<RlpxConnection>,
    /// 活跃连接
    active_connections: HashMap<PeerId, RlpxConnection>,
    /// 最大连接数
    max_connections: usize,
}

impl ConnectionPool {
    pub fn new(max_connections: usize) -> Self {
        Self {
            idle_connections: VecDeque::new(),
            active_connections: HashMap::new(),
            max_connections,
        }
    }
    
    /// 获取连接
    pub async fn get_connection(&mut self, peer_id: PeerId) -> Option<RlpxConnection> {
        // 首先检查是否有现有连接
        if let Some(connection) = self.active_connections.remove(&peer_id) {
            return Some(connection);
        }
        
        // 尝试重用空闲连接
        if let Some(connection) = self.idle_connections.pop_front() {
            self.active_connections.insert(peer_id, connection.clone());
            return Some(connection);
        }
        
        None
    }
    
    /// 归还连接
    pub fn return_connection(&mut self, peer_id: PeerId, connection: RlpxConnection) {
        self.active_connections.remove(&peer_id);
        
        if self.idle_connections.len() < self.max_connections / 2 {
            self.idle_connections.push_back(connection);
        }
        // 否则丢弃连接
    }
}
```
*来源：`reth-network/src/pool.rs`*

### 消息批处理

```rust
// 来自 reth-network/src/batch.rs
pub struct MessageBatcher {
    /// 待发送消息
    pending_messages: Vec<(PeerId, EthMessage)>,
    /// 批处理大小
    batch_size: usize,
    /// 批处理间隔
    batch_interval: Duration,
    /// 最后批处理时间
    last_batch_time: Instant,
}

impl MessageBatcher {
    pub fn new(batch_size: usize, batch_interval: Duration) -> Self {
        Self {
            pending_messages: Vec::new(),
            batch_size,
            batch_interval,
            last_batch_time: Instant::now(),
        }
    }
    
    /// 添加消息到批处理队列
    pub fn add_message(&mut self, peer_id: PeerId, message: EthMessage) -> bool {
        self.pending_messages.push((peer_id, message));
        
        // 检查是否应该发送批处理
        self.should_send_batch()
    }
    
    fn should_send_batch(&self) -> bool {
        self.pending_messages.len() >= self.batch_size ||
        self.last_batch_time.elapsed() >= self.batch_interval
    }
    
    /// 获取并清空待发送消息
    pub fn take_messages(&mut self) -> Vec<(PeerId, EthMessage)> {
        self.last_batch_time = Instant::now();
        std::mem::take(&mut self.pending_messages)
    }
}
```
*来源：`reth-network/src/batch.rs`*

## 测试和验证

### 单元测试

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tokio_test;
    
    #[tokio::test]
    async fn test_peer_discovery() {
        let config = DiscoveryConfig::default();
        let mut discovery = Discovery::new(config).await.unwrap();
        
        // 启动发现服务
        discovery.start().await.unwrap();
        
        // 查找节点
        let nodes = discovery.find_nodes(5).await.unwrap();
        
        assert!(!nodes.is_empty());
        assert!(nodes.len() <= 5);
    }
    
    #[tokio::test]
    async fn test_rlpx_handshake() {
        let server_secret = SecretKey::random();
        let client_secret = SecretKey::random();
        
        // 创建服务器监听器
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server_addr = listener.local_addr().unwrap();
        
        // 启动服务器
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let _connection = RlpxConnection::accept(stream, server_secret).await.unwrap();
        });
        
        // 客户端连接
        let server_public = server_secret.public_key();
        let connection = RlpxConnection::connect(
            server_addr,
            client_secret,
            server_public,
        ).await.unwrap();
        
        assert!(matches!(connection.state, ConnectionState::Established));
    }
    
    #[tokio::test]
    async fn test_eth_protocol() {
        let chain_info = ChainInfo::mainnet();
        let fork_id = ForkId::mainnet();
        let mut protocol = EthProtocol::new(chain_info, fork_id);
        
        let peer_id = PeerId::random();
        let status = StatusMessage {
            protocol_version: 68,
            network_id: 1,
            total_difficulty: U256::from(1000),
            best_hash: B256::random(),
            genesis_hash: B256::random(),
            fork_id: ForkId::mainnet(),
        };
        
        let response = protocol
            .handle_message(peer_id, EthMessage::Status(status))
            .await
            .unwrap();
        
        assert!(response.is_some());
        assert!(matches!(response.unwrap(), EthMessage::Status(_)));
    }
}
```
*来源：`reth-network/src/lib.rs`*

## 最佳实践

### 网络安全

1. **连接验证**：始终验证传入连接的身份
2. **速率限制**：实施消息速率限制以防止垃圾邮件
3. **黑名单管理**：维护恶意对等节点的黑名单
4. **加密通信**：确保所有网络通信都经过加密

### 性能优化

1. **连接复用**：重用现有连接以减少握手开销
2. **消息批处理**：批量发送消息以提高效率
3. **异步处理**：使用异步 I/O 处理网络操作
4. **缓存策略**：缓存频繁访问的对等节点信息

### 错误处理

1. **优雅降级**：在网络问题时优雅地降级功能
2. **重试机制**：实施指数退避重试策略
3. **监控和日志**：全面记录网络事件和错误
4. **健康检查**：定期检查网络连接的健康状态

## 结论

Reth 的 P2P 网络层提供了一个强大而灵活的框架，用于构建去中心化的以太坊网络。通过 DevP2P 协议栈、节点发现机制、RLPx 传输协议和以太坊线协议的组合，Reth 能够与以太坊网络中的其他节点进行可靠的通信。

关键特性包括：
- 自动节点发现和连接管理
- 加密和认证的通信
- 高效的消息路由和处理
- 强大的错误处理和恢复机制
- 可扩展的协议架构

## 参考文献

1. [DevP2P 规范](https://github.com/ethereum/devp2p)
2. [RLPx 传输协议](https://github.com/ethereum/devp2p/blob/master/rlpx.md)
3. [以太坊线协议](https://github.com/ethereum/devp2p/blob/master/caps/eth.md)
4. [节点发现协议](https://github.com/ethereum/devp2p/blob/master/discv4.md)
5. [Reth 网络文档](https://github.com/paradigmxyz/reth/tree/main/crates/net)
*来源：`reth-network/src/lib.rs`*

### 核心组件

#### NetworkManager 结构

```rust
// 来自 reth-network/src/manager.rs
pub struct NetworkManager<C> {
    /// 本地节点信息
    local_node: NodeRecord,
    /// 活跃的对等连接
    peers: HashMap<PeerId, PeerConnection>,
    /// 节点发现服务
    discovery: Option<Discovery>,
    /// 会话管理器
    sessions: SessionManager,
    /// 网络配置
    config: NetworkConfig,
    /// 链规范
    chain: C,
    /// 事件发送器
    event_sender: mpsc::UnboundedSender<NetworkEvent>,
}

impl<C: ChainSpec> NetworkManager<C> {
    pub fn new(
        config: NetworkConfig,
        chain: C,
        event_sender: mpsc::UnboundedSender<NetworkEvent>,
    ) -> Result<Self, NetworkError> {
        let local_node = NodeRecord::from_secret_key(
            &config.secret_key,
            config.listen_addr,
        )?;
        
        let discovery = if config.discovery.enabled {
            Some(Discovery::new(
                config.local_enr()?,
                config.discovery.clone(),
            ))
        } else {
            None
        };
        
        Ok(Self {
            local_node,
            peers: HashMap::new(),
            discovery,
            sessions: SessionManager::new(config.session_config()),
            config,
            chain,
            event_sender,
        })
    }
    
    /// 启动网络管理器
    pub async fn start(&mut self) -> Result<(), NetworkError> {
        info!("启动网络管理器，节点 ID: {}", self.local_node.node_id());
        
        // 启动发现服务
        if let Some(discovery) = &mut self.discovery {
            discovery.start().await?;
            
            // 添加引导节点
            for boot_node in &self.config.boot_nodes {
                discovery.add_node(boot_node.clone())?;
            }
        }
        
        // 启动监听器
        self.start_listener().await?;
        
        // 启动对等发现循环
        self.start_peer_discovery_loop().await;
        
        Ok(())
    }
    
    async fn start_listener(&mut self) -> Result<(), NetworkError> {
        let listener = TcpListener::bind(self.config.listen_addr).await?;
        let local_secret = self.config.secret_key.clone();
        let event_sender = self.event_sender.clone();
        
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((stream, addr)) => {
                        info!("接受来自 {} 的连接", addr);
                        
                        let secret = local_secret.clone();
                        let sender = event_sender.clone();
                        
                        tokio::spawn(async move {
                            if let Err(e) = Self::handle_incoming_connection(
                                stream, secret, sender
                            ).await {
                                error!("处理传入连接失败: {}", e);
                            }
                        });
                    }
                    Err(e) => {
                        error!("接受连接失败: {}", e);
                    }
                }
            }
        });
        
        Ok(())
    }
}
```
*来源：`reth-network/src/manager.rs`*

## 节点发现

### Discovery 结构

节点发现使用基于 Kademlia 的分布式哈希表 (DHT) 来查找和维护网络中的对等节点。

```rust
// 来自 reth-network/src/discovery.rs
pub struct Discovery {
    /// 本地节点的 ENR
    local_enr: Enr,
    /// Kademlia 路由表
    kbuckets: KBucketsTable<NodeId, NodeRecord>,
    /// 活跃的查询
    active_queries: HashMap<QueryId, Query>,
    /// UDP 套接字
    socket: UdpSocket,
    /// 配置
    config: DiscoveryConfig,
    /// 待处理的请求
    pending_requests: HashMap<RequestId, PendingRequest>,
}

impl Discovery {
    pub fn new(local_enr: Enr, config: DiscoveryConfig) -> Self {
        let local_node_id = local_enr.node_id();
        let kbuckets = KBucketsTable::new(local_node_id, Duration::from_secs(60));
        
        Self {
            local_enr,
            kbuckets,
            active_queries: HashMap::new(),
            socket: UdpSocket::bind(("0.0.0.0", config.port)).unwrap(),
            config,
            pending_requests: HashMap::new(),
        }
    }
    
    /// 启动发现服务
    pub async fn start(&mut self) -> Result<(), DiscoveryError> {
        info!("启动节点发现，端口: {}", self.config.port);
        
        // 启动消息处理循环
        let socket = self.socket.clone();
        let local_enr = self.local_enr.clone();
        
        tokio::spawn(async move {
            Self::message_loop(socket, local_enr).await;
        });
        
        // 启动定期桶刷新
        self.start_bucket_refresh().await;
        
        Ok(())
    }
    
    /// 查找接近目标 ID 的节点
    pub async fn find_node(&mut self, target: NodeId) -> Result<Vec<NodeRecord>, DiscoveryError> {
        let query_id = QueryId::random();
        let closest_nodes = self.kbuckets.closest_nodes(&target, 16);
        
        if closest_nodes.is_empty() {
            return Err(DiscoveryError::NoKnownNodes);
        }
        
        let query = Query::new(target, closest_nodes);
        self.active_queries.insert(query_id, query);
        
        // 发送初始 FIND_NODE 请求
        for node in &closest_nodes {
            self.send_find_node(node.socket_addr(), target).await?;
        }
        
        // 等待查询完成
        self.wait_for_query_completion(query_id).await
    }
    
    async fn send_find_node(
        &mut self,
        addr: SocketAddr,
        target: NodeId,
    ) -> Result<(), DiscoveryError> {
        let request_id = RequestId::random();
        let message = DiscoveryMessage::FindNode {
            request_id,
            target,
        };
        
        let encoded = message.encode(&self.local_enr.secret_key())?;
        self.socket.send_to(&encoded, addr).await?;
        
        // 跟踪待处理的请求
        let pending = PendingRequest {
            addr,
            message_type: MessageType::FindNode,
            timestamp: Instant::now(),
        };
        
        self.pending_requests.insert(request_id, pending);
        
        Ok(())
    }
}
```
*来源：`reth-network/src/discovery.rs`*

## 以太坊节点记录 (ENR)

### NodeRecord 结构

以太坊节点记录 (ENR) 是一种标准化格式，用于存储和传输节点信息。

```rust
// 来自 reth-network/src/enr.rs
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeRecord {
    /// 节点的公钥
    public_key: PublicKey,
    /// 网络地址
    socket_addr: SocketAddr,
    /// 节点 ID（公钥的哈希）
    node_id: NodeId,
    /// 支持的协议
    protocols: HashMap<String, u32>,
    /// ENR 序列号
    seq: u64,
    /// 数字签名
    signature: Signature,
}

impl NodeRecord {
    pub fn new(
        secret_key: &SecretKey,
        socket_addr: SocketAddr,
        protocols: HashMap<String, u32>,
        seq: u64,
    ) -> Result<Self, EnrError> {
        let public_key = secret_key.public_key();
        let node_id = NodeId::from_public_key(&public_key);
        
        // 创建要签名的数据
        let mut data = Vec::new();
        data.extend_from_slice(&seq.to_be_bytes());
        data.extend_from_slice(&socket_addr.ip().octets());
        data.extend_from_slice(&socket_addr.port().to_be_bytes());
        
        // 添加协议信息
        for (name, version) in &protocols {
            data.extend_from_slice(name.as_bytes());
            data.extend_from_slice(&version.to_be_bytes());
        }
        
        // 签名数据
        let signature = secret_key.sign(&data)?;
        
        Ok(Self {
            public_key,
            socket_addr,
            node_id,
            protocols,
            seq,
            signature,
        })
    }
    
    pub fn node_id(&self) -> NodeId {
        self.node_id
    }
    
    pub fn socket_addr(&self) -> SocketAddr {
        self.socket_addr
    }
    
    /// 提取支持的协议
    pub fn extract_protocols(&self) -> Vec<ProtocolInfo> {
        self.protocols
            .iter()
            .map(|(name, version)| ProtocolInfo {
                name: name.clone(),
                version: *version,
            })
            .collect()
    }
    
    /// 验证 ENR 签名
    pub fn verify_signature(&self) -> Result<bool, EnrError> {
        let mut data = Vec::new();
        data.extend_from_slice(&self.seq.to_be_bytes());
        data.extend_from_slice(&self.socket_addr.ip().octets());
        data.extend_from_slice(&self.socket_addr.port().to_be_bytes());
        
        for (name, version) in &self.protocols {
            data.extend_from_slice(name.as_bytes());
            data.extend_from_slice(&version.to_be_bytes());
        }
        
        self.public_key.verify(&data, &self.signature)
    }
}
```
*来源：`reth-network/src/enr.rs`*

## RLPx 传输协议

### 连接建立

RLPx 提供加密和认证的传输层，使用椭圆曲线集成加密方案 (ECIES) 进行握手。

```rust
// 来自 reth-network/src/rlpx.rs
pub struct RlpxConnection {
    /// 底层 TCP 流
    stream: TcpStream,
    /// 加密状态
    encryption: EncryptionState,
    /// 远程节点 ID
    remote_id: NodeId,
    /// 连接状态
    state: ConnectionState,
}

#[derive(Debug)]
enum ConnectionState {
    /// 等待握手
    Handshaking,
    /// 已建立连接
    Established,
    /// 连接已关闭
    Closed,
}

impl RlpxConnection {
    /// 作为客户端连接到远程节点
    pub async fn connect(
        addr: SocketAddr,
        local_secret: SecretKey,
        remote_public: PublicKey,
    ) -> Result<Self, RlpxError> {
        let stream = TcpStream::connect(addr).await?;
        let remote_id = NodeId::from_public_key(&remote_public);
        
        let mut connection = Self {
            stream,
            encryption: EncryptionState::new(),
            remote_id,
            state: ConnectionState::Handshaking,
        };
        
        // 执行客户端握手
        connection.perform_client_handshake(local_secret, remote_public).await?;
        
        Ok(connection)
    }
    
    /// 作为服务器接受连接
    pub async fn accept(
        stream: TcpStream,
        local_secret: SecretKey,
    ) -> Result<Self, RlpxError> {
        let mut connection = Self {
            stream,
            encryption: EncryptionState::new(),
            remote_id: NodeId::default(), // 将在握手期间设置
            state: ConnectionState::Handshaking,
        };
        
        // 执行服务器握手
        connection.perform_server_handshake(local_secret).await?;
        
        Ok(connection)
    }
    
    async fn perform_client_handshake(
        &mut self,
        local_secret: SecretKey,
        remote_public: PublicKey,
    ) -> Result<(), RlpxError> {
        // 1. 生成临时密钥对
        let ephemeral_secret = SecretKey::random();
        let ephemeral_public = ephemeral_secret.public_key();
        
        // 2. 创建认证消息
        let nonce = generate_nonce();
        let auth_message = AuthMessage {
            signature: self.create_auth_signature(&local_secret, &nonce)?,
            initiator_public: local_secret.public_key(),
            initiator_nonce: nonce,
            version: 4,
        };
        
        // 3. 加密并发送认证消息
        let encrypted_auth = ecies_encrypt(&remote_public, &auth_message.encode())?;
        self.stream.write_all(&encrypted_auth).await?;
        
        // 4. 接收并解密认证确认
        let encrypted_ack = self.read_message().await?;
        let ack_data = ecies_decrypt(&local_secret, &encrypted_ack)?;
        let ack_message = AuthAckMessage::decode(&ack_data)?;
        
        // 5. 派生会话密钥
        self.derive_session_keys(
            &local_secret,
            &ephemeral_secret,
            &ack_message.responder_public,
            &nonce,
            &ack_message.responder_nonce,
        )?;
        
        self.state = ConnectionState::Established;
        Ok(())
    }
}
```
*来源：`reth-network/src/rlpx.rs`*

### 消息帧和加密

```rust
impl RlpxConnection {
    /// 发送加密消息
    pub async fn send_message(&mut self, data: &[u8]) -> Result<(), RlpxError> {
        if !matches!(self.state, ConnectionState::Established) {
            return Err(RlpxError::NotEstablished);
        }
        
        // 创建消息帧
        let frame = MessageFrame {
            size: data.len() as u32,
            header_data: vec![0; 16], // 填充
            payload: data.to_vec(),
        };
        
        // 加密帧
        let encrypted_frame = self.encryption.encrypt_frame(&frame)?;
        
        // 发送加密帧
        self.stream.write_all(&encrypted_frame).await?;
        
        Ok(())
    }
    
    /// 接收并解密消息
    pub async fn receive_message(&mut self) -> Result<Vec<u8>, RlpxError> {
        if !matches!(self.state, ConnectionState::Established) {
            return Err(RlpxError::NotEstablished);
        }
        
        // 读取帧头
        let mut header_buf = [0u8; 32];
        self.stream.read_exact(&mut header_buf).await?;
        
        // 解密帧头
        let header = self.encryption.decrypt_header(&header_buf)?;
        let payload_size = header.payload_size();
        
        // 读取有效载荷
        let mut payload_buf = vec![0u8; payload_size];
        self.stream.read_exact(&mut payload_buf).await?;
        
        // 解密有效载荷
        let payload = self.encryption.decrypt_payload(&payload_buf)?;
        
        Ok(payload)
    }
}

#[derive(Debug)]
struct MessageFrame {
    size: u32,
    header_data: Vec<u8>,
    payload: Vec<u8>,
}

struct EncryptionState {
    /// AES 加密器（出站）
    egress_aes: Aes256Ctr,
    /// AES 解密器（入站）
    ingress_aes: Aes256Ctr,
    /// MAC 密钥
    mac_key: [u8; 32],
    /// 出站 MAC
    egress_mac: Keccak256,
    /// 入站 MAC
    ingress_mac: Keccak256,
}
```
*来源：`reth-network/src/rlpx.rs`*

## 以太坊线协议

### EthProtocol 结构

以太坊线协议处理区块链特定的消息，如状态同步、区块传播和交易中继。

```rust
// 来自 reth-network/src/eth/protocol.rs
pub struct EthProtocol {
    /// 链信息
    chain_info: ChainInfo,
    /// 分叉 ID
    fork_id: ForkId,
    /// 协议版本
    version: u32,
    /// 消息处理器
    handlers: HashMap<u8, Box<dyn MessageHandler>>,
}

impl EthProtocol {
    pub fn new(chain_info: ChainInfo, fork_id: ForkId) -> Self {
        let mut handlers = HashMap::new();
        
        // 注册消息处理器
        handlers.insert(0x00, Box::new(StatusHandler::new()));
        handlers.insert(0x01, Box::new(NewBlockHashesHandler::new()));
        handlers.insert(0x02, Box::new(TransactionsHandler::new()));
        handlers.insert(0x03, Box::new(GetBlockHeadersHandler::new()));
        handlers.insert(0x04, Box::new(BlockHeadersHandler::new()));
        
        Self {
            chain_info,
            fork_id,
            version: 68, // ETH/68
            handlers,
        }
    }
    
    /// 处理传入消息
    pub async fn handle_message(
        &mut self,
        peer_id: PeerId,
        message: EthMessage,
    ) -> Result<Option<EthMessage>, EthError> {
        match message {
            EthMessage::Status(status) => {
                self.handle_status(peer_id, status).await
            }
            EthMessage::NewBlockHashes(hashes) => {
                self.handle_new_block_hashes(peer_id, hashes).await
            }
            EthMessage::Transactions(txs) => {
                self.handle_transactions(peer_id, txs).await
            }
            EthMessage::GetBlockHeaders(request) => {
                self.handle_get_block_headers(peer_id, request).await
            }
            EthMessage::BlockHeaders(headers) => {
                self.handle_block_headers(peer_id, headers).await
            }
            _ => {
                warn!("未处理的消息类型: {:?}", message);
                Ok(None)
            }
        }
    }
    
    /// 处理状态消息
    async fn handle_status(
        &mut self,
        peer_id: PeerId,
        status: StatusMessage,
    ) -> Result<Option<EthMessage>, EthError> {
        info!("从对等节点 {} 收到状态: {:?}", peer_id, status);
        
        // 验证网络 ID
        if status.network_id != self.chain_info.network_id {
            return Err(EthError::NetworkIdMismatch {
                expected: self.chain_info.network_id,
                received: status.network_id,
            });
        }
        
        // 验证创世区块哈希
        if status.genesis_hash != self.chain_info.genesis_hash {
            return Err(EthError::GenesisHashMismatch {
                expected: self.chain_info.genesis_hash,
                received: status.genesis_hash,
            });
        }
        
        // 检查分叉兼容性
        if !self.fork_id.is_compatible(&status.fork_id) {
            return Err(EthError::ForkIdMismatch {
                local: self.fork_id,
                remote: status.fork_id,
            });
        }
        
        // 发送我们的状态作为响应
        let our_status = StatusMessage {
            protocol_version: self.version,
            network_id: self.chain_info.network_id,
            total_difficulty: self.chain_info.total_difficulty,
            best_hash: self.chain_info.best_hash,
            genesis_hash: self.chain_info.genesis_hash,
            fork_id: self.fork_id,
        };
        
        Ok(Some(EthMessage::Status(our_status)))
    }
    
    /// 处理获取区块头请求
    async fn handle_get_block_headers(
        &mut self,
        peer_id: PeerId,
        request: GetBlockHeadersMessage,
    ) -> Result<Option<EthMessage>, EthError> {
        info!("从对等节点 {} 收到获取区块头请求: {:?}", peer_id, request);
        
        // 获取请求的区块头
        let headers = self.fetch_headers(
            request.start_block,
            request.max_headers,
            request.skip,
            request.reverse,
        ).await?;
        
        let response = BlockHeadersMessage {
            request_id: request.request_id,
            headers,
        };
        
        Ok(Some(EthMessage::BlockHeaders(response)))
    }
    
    async fn fetch_headers(
        &self,
        start: BlockHashOrNumber,
        max_headers: u64,
        skip: u64,
        reverse: bool,
    ) -> Result<Vec<Header>, EthError> {
        // 这里会与区块链数据库交互获取区块头
        // 实际实现会更复杂，包括缓存和优化
        
        let mut headers = Vec::new();
        let mut current_block = match start {
            BlockHashOrNumber::Hash(hash) => {
                self.chain_info.get_block_number_by_hash(hash)?
            }
            BlockHashOrNumber::Number(number) => number,
        };
        
        for _ in 0..max_headers {
            if let Some(header) = self.chain_info.get_header_by_number(current_block)? {
                headers.push(header);
                
                if reverse {
                    if current_block == 0 {
                        break;
                    }
                    current_block = current_block.saturating_sub(skip + 1);
                } else {
                    current_block += skip + 1;
                }
            } else {
                break;
            }
        }
        
        Ok(headers)
    }
}
```
*来源：`reth-network/src/eth/protocol.rs`*

### 消息类型

```rust
// 来自 reth-network/src/eth/messages.rs
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EthMessage {
    /// 状态消息 (0x00)
    Status(StatusMessage),
    /// 新区块哈希 (0x01)
    NewBlockHashes(NewBlockHashesMessage),
    /// 交易 (0x02)
    Transactions(TransactionsMessage),
    /// 获取区块头 (0x03)
    GetBlockHeaders(GetBlockHeadersMessage),
    /// 区块头 (0x04)
    BlockHeaders(BlockHeadersMessage),
    /// 获取区块体 (0x05)
    GetBlockBodies(GetBlockBodiesMessage),
    /// 区块体 (0x06)
    BlockBodies(BlockBodiesMessage),
    /// 新区块 (0x07)
    NewBlock(NewBlockMessage),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusMessage {
    pub protocol_version: u32,
    pub network_id: u64,
    pub total_difficulty: U256,
    pub best_hash: B256,
    pub genesis_hash: B256,
    pub fork_id: ForkId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GetBlockHeadersMessage {
    pub request_id: u64,
    pub start_block: BlockHashOrNumber,
    pub max_headers: u64,
    pub skip: u64,
    pub reverse: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockHeadersMessage {
    pub request_id: u64,
    pub headers: Vec<Header>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewBlockHashesMessage {
    pub hashes: Vec<(B256, u64)>, // (哈希, 区块号)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransactionsMessage {
    pub transactions: Vec<Transaction>,
}

impl EthMessage {
    /// 获取消息 ID
    pub fn message_id(&self) -> u8 {
        match self {
            EthMessage::Status(_) => 0x00,
            EthMessage::NewBlockHashes(_) => 0x01,
            EthMessage::Transactions(_) => 0x02,
            EthMessage::GetBlockHeaders(_) => 0x03,
            EthMessage::BlockHeaders(_) => 0x04,
            EthMessage::GetBlockBodies(_) => 0x05,
            EthMessage::BlockBodies(_) => 0x06,
            EthMessage::NewBlock(_) => 0x07,
        }
    }
    
    /// 编码消息为 RLP
    pub fn encode(&self) -> Result<Vec<u8>, EthError> {
        let mut stream = RlpStream::new();
        
        match self {
            EthMessage::Status(status) => {
                stream.begin_list(6);
                stream.append(&status.protocol_version);
                stream.append(&status.network_id);
                stream.append(&status.total_difficulty);
                stream.append(&status.best_hash);
                stream.append(&status.genesis_hash);
                stream.append(&status.fork_id);
            }
            EthMessage::GetBlockHeaders(request) => {
                stream.begin_list(5);
                stream.append(&request.request_id);
                match request.start_block {
                    BlockHashOrNumber::Hash(hash) => stream.append(&hash),
                    BlockHashOrNumber::Number(number) => stream.append(&number),
                };
                stream.append(&request.max_headers);
                stream.append(&request.skip);
                stream.append(&request.reverse);
            }
            // ... 其他消息类型的编码
            _ => return Err(EthError::UnsupportedMessage),
        }
        
        Ok(stream.out().to_vec())
    }
}
```