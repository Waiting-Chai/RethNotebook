# RethNotebook Docker 部署指南

本项目提供了完整的 Docker 一键部署方案，让您可以快速部署 RethNotebook 文档站点。

## 🚀 快速开始

### 前置要求

- Docker (版本 20.10+)
- Docker Compose (版本 2.0+)
- 至少 2GB 可用内存
- 端口 40501 未被占用

### 一键部署

#### Linux/macOS

```bash
# 给脚本执行权限
chmod +x docker-deploy.sh

# 运行部署脚本
./docker-deploy.sh
```

#### Windows (PowerShell)

```powershell
# 以管理员身份运行 PowerShell
# 执行部署脚本
.\docker-deploy.ps1
```

### 手动部署

如果您更喜欢手动控制部署过程：

```bash
# 1. 构建镜像
docker-compose build

# 2. 启动服务
docker-compose up -d

# 3. 查看状态
docker-compose ps
```

## 📖 访问站点

部署成功后，您可以通过以下地址访问：

- **本地访问**: http://localhost:40501
- **局域网访问**: http://[您的IP]:40501

## 🛠️ 管理命令

### 查看日志

```bash
# 查看实时日志
docker-compose logs -f

# 查看特定服务日志
docker-compose logs reth-notebook
```

### 重启服务

```bash
# 重启服务
docker-compose restart

# 重新构建并重启
docker-compose up -d --build
```

### 停止服务

```bash
# 停止服务
docker-compose stop

# 停止并删除容器
docker-compose down

# 停止并删除容器、网络、卷
docker-compose down -v
```

### 更新部署

```bash
# 拉取最新代码
git pull

# 重新构建并部署
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

## 🔧 配置说明

### 端口配置

默认端口为 40501，如需修改请编辑 `docker-compose.yml`：

```yaml
ports:
  - "[新端口]:80"
```

### 环境变量

可在 `docker-compose.yml` 中添加环境变量：

```yaml
environment:
  - NODE_ENV=production
  - CUSTOM_VAR=value
```

### Nginx 配置

Nginx 配置文件位于 `nginx.conf`，包含以下优化：

- Gzip 压缩
- 静态资源缓存
- SPA 路由支持
- 安全头设置

## 📊 性能优化

### 资源限制

可在 `docker-compose.yml` 中设置资源限制：

```yaml
deploy:
  resources:
    limits:
      cpus: '1.0'
      memory: 512M
    reservations:
      cpus: '0.5'
      memory: 256M
```

### 缓存优化

- 静态资源缓存 1 年
- Gzip 压缩减少传输大小
- Docker 多阶段构建减少镜像大小

## 🐛 故障排除

### 常见问题

1. **端口被占用**
   ```bash
   # 检查端口占用
   netstat -tulpn | grep 40501
   # 或使用其他端口
   ```

2. **Docker 服务未启动**
   ```bash
   # Linux
   sudo systemctl start docker
   
   # Windows/macOS
   # 启动 Docker Desktop
   ```

3. **权限问题**
   ```bash
   # Linux 添加用户到 docker 组
   sudo usermod -aG docker $USER
   ```

4. **内存不足**
   ```bash
   # 清理未使用的镜像和容器
   docker system prune -a
   ```

### 查看详细日志

```bash
# 查看构建日志
docker-compose build --progress=plain

# 查看容器详细信息
docker inspect reth-notebook

# 进入容器调试
docker exec -it reth-notebook sh
```

## 🔒 安全建议

1. **生产环境部署**
   - 使用 HTTPS
   - 配置防火墙
   - 定期更新镜像

2. **网络安全**
   - 限制访问 IP
   - 使用反向代理
   - 启用访问日志

## 📝 文件结构

```
.
├── Dockerfile              # Docker 镜像构建文件
├── docker-compose.yml      # Docker Compose 配置
├── nginx.conf              # Nginx 配置文件
├── .dockerignore           # Docker 忽略文件
├── docker-deploy.sh        # Linux/macOS 部署脚本
├── docker-deploy.ps1       # Windows 部署脚本
└── DOCKER-README.md        # 本文档
```

## 🤝 支持

如果您在部署过程中遇到问题，请：

1. 检查本文档的故障排除部分
2. 查看项目 Issues
3. 提交新的 Issue 并附上详细日志

---

**祝您使用愉快！** 🎉