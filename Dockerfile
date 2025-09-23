# 使用官方Node.js镜像作为基础镜像
FROM node:18-alpine AS builder

# 设置工作目录
WORKDIR /app

# 复制package.json和package-lock.json
COPY package*.json ./

# 安装依赖
RUN npm ci --only=production

# 复制源代码
COPY . .

# 构建项目
RUN npm run build

# 使用nginx作为生产环境服务器
FROM nginx:alpine

# 复制构建产物到nginx目录
COPY --from=builder /app/docs/.vitepress/dist /usr/share/nginx/html

# 复制nginx配置文件
COPY nginx.conf /etc/nginx/nginx.conf

# 暴露端口
EXPOSE 80

# 启动nginx
CMD ["nginx", "-g", "daemon off;"]