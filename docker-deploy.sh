#!/bin/bash

# RethNotebook Docker 一键部署脚本
# 作者: AI Assistant
# 用途: 快速部署VitePress文档站点

set -e

echo "🚀 开始部署 RethNotebook..."

# 检查Docker是否安装
if ! command -v docker &> /dev/null; then
    echo "❌ Docker 未安装，请先安装 Docker"
    exit 1
fi

# 检查docker-compose是否安装
if ! command -v docker-compose &> /dev/null; then
    echo "❌ docker-compose 未安装，请先安装 docker-compose"
    exit 1
fi

echo "✅ Docker 环境检查通过"

# 停止并删除现有容器
echo "🛑 停止现有容器..."
docker-compose down --remove-orphans 2>/dev/null || true

# 清理旧镜像（可选）
read -p "是否清理旧的Docker镜像？(y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🧹 清理旧镜像..."
    docker system prune -f
    docker image prune -f
fi

# 构建并启动容器
echo "🔨 构建Docker镜像..."
docker-compose build --no-cache

echo "🚀 启动容器..."
docker-compose up -d

# 等待服务启动
echo "⏳ 等待服务启动..."
sleep 10

# 检查容器状态
if docker-compose ps | grep -q "Up"; then
    echo "✅ 部署成功！"
    echo "📖 访问地址: http://localhost:40501"
    echo "🔍 查看日志: docker-compose logs -f"
    echo "🛑 停止服务: docker-compose down"
else
    echo "❌ 部署失败，请检查日志:"
    docker-compose logs
    exit 1
fi

echo "🎉 RethNotebook 部署完成！"