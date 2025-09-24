# 多阶段构建：第一阶段 - 构建VitePress项目
FROM node:20-alpine AS builder

# 设置工作目录
WORKDIR /app

# 复制package文件
COPY package*.json ./

# 安装所有依赖（包括开发依赖）
RUN npm ci

# 复制源代码
COPY . .

# 构建VitePress项目
RUN npm run build

# 第二阶段 - 生产环境nginx服务器
FROM nginx:alpine

# 安装必要的工具
RUN apk add --no-cache curl

# 创建nginx用户和目录
RUN addgroup -g 101 -S nginx || true
RUN adduser -S -D -H -u 101 -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx || true

# 复制构建产物到nginx目录
COPY --from=builder /app/docs/.vitepress/dist /usr/share/nginx/html

# 复制nginx配置文件
COPY nginx.conf /etc/nginx/nginx.conf

# 设置正确的权限
RUN chown -R nginx:nginx /usr/share/nginx/html
RUN chmod -R 755 /usr/share/nginx/html

# 创建日志目录
RUN mkdir -p /var/log/nginx && chown -R nginx:nginx /var/log/nginx

# 暴露端口
EXPOSE 80

# 健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

# 启动nginx
CMD ["nginx", "-g", "daemon off;"]