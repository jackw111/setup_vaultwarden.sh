#!/bin/bash

# ==============================================================================
# Vaultwarden & Nginx 自动化部署脚本
#
# 功能:
# 1. 安装 Docker, Docker Compose, Nginx, Certbot
# 2. 获取用户域名和邮箱信息
# 3. 部署 Vaultwarden (使用 Docker Compose)
# 4. 自动配置 Nginx 反向代理
# 5. 自动申请 Let's Encrypt SSL 证书
#
# 使用方法:
# 1. wget https://path/to/this/script/setup_vaultwarden.sh
# 2. chmod +x setup_vaultwarden.sh
# 3. sudo ./setup_vaultwarden.sh
# ==============================================================================

# --- 配置颜色输出 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- 函数定义 ---

# 检查脚本是否以 root 权限运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用 sudo 运行此脚本。${NC}"
        exit 1
    fi
}

# 安装系统依赖
install_dependencies() {
    echo -e "${GREEN}>>> 1. 正在更新系统并安装依赖 (Docker, Docker Compose, Nginx, Certbot)...${NC}"
    apt-get update
    apt-get install -y docker.io docker-compose nginx python3-certbot-nginx curl
    
    # 启用并启动 Docker 和 Nginx
    systemctl enable --now docker
    systemctl enable --now nginx
    echo -e "${GREEN}>>> 依赖安装完成。${NC}"
}

# 获取用户输入
get_user_input() {
    echo -e "${GREEN}>>> 2. 请输入配置信息...${NC}"
    while [ -z "$DOMAIN_NAME" ]; do
        read -p "请输入你的域名 (例如: niube.laozi.com): " DOMAIN_NAME
    done

    while [ -z "$EMAIL" ]; do
        read -p "请输入你的邮箱 (用于 Let's Encrypt SSL 证书): " EMAIL
    done
}

# 设置并启动 Vaultwarden
setup_vaultwarden() {
    echo -e "${GREEN}>>> 3. 正在配置并启动 Vaultwarden 容器...${NC}"
    
    # 创建 Vaultwarden 工作目录
    mkdir -p /opt/vaultwarden
    cd /opt/vaultwarden

    # 生成一个安全的 ADMIN_TOKEN
    ADMIN_TOKEN=$(openssl rand -base64 48)

    # 创建 docker-compose.yml 文件
    cat <<EOF > docker-compose.yml
version: '3'

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: always
    environment:
      - WEBSOCKET_ENABLED=true
      - ADMIN_TOKEN=${ADMIN_TOKEN}
    volumes:
      - ./vw-data:/data
EOF

    # 创建 .env 文件保存敏感信息
    cat <<EOF > .env
# Vaultwarden 管理员后台访问令牌
# 访问 https://${DOMAIN_NAME}/admin 登录
ADMIN_TOKEN=${ADMIN_TOKEN}
EOF

    # 启动 Vaultwarden 容器
    docker-compose up -d

    # 确保 Vaultwarden 内部服务有时间启动
    echo -e "${YELLOW}等待 10 秒钟，以确保 Vaultwarden 服务完全启动...${NC}"
    sleep 10
    
    echo -e "${GREEN}>>> Vaultwarden 容器已成功启动。${NC}"
}

# 配置 Nginx 和 SSL
setup_nginx_ssl() {
    echo -e "${GREEN}>>> 4. 正在配置 Nginx 并申请 SSL 证书...${NC}"

    # 创建 Nginx 配置文件
    cat <<EOF > /etc/nginx/sites-available/vaultwarden.conf
server {
    listen 80;
    server_name ${DOMAIN_NAME};

    # 允许 Certbot 的 HTTP-01 质询
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    # 将所有其他 HTTP 请求重定向到 HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN_NAME};

    # SSL 配置将在 Certbot 成功后自动添加

    location / {
        proxy_pass http://127.0.0.1:8080; # Vaultwarden 默认在 Docker compose 网络中是 80 端口，这里假设我们映射了端口
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /notifications/hub {
        proxy_pass http://127.0.0.1:3012; # Vaultwarden 的 WebSocket 端口
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    # 替换 Vaultwarden 的默认 docker-compose 配置，使其端口暴露给主机
    sed -i '/restart: always/a \    ports:\n      - "127.0.0.1:8080:80"\n      - "127.0.0.1:3012:3012"' /opt/vaultwarden/docker-compose.yml
    
    cd /opt/vaultwarden && docker-compose up -d --force-recreate
    cd - > /dev/null

    # 启用 Nginx 站点
    ln -s /etc/nginx/sites-available/vaultwarden.conf /etc/nginx/sites-enabled/
    # 移除默认配置以避免冲突
    rm -f /etc/nginx/sites-enabled/default
    
    # 重载 Nginx 以使域名生效，为 Certbot 做准备
    nginx -t && systemctl reload nginx

    # 使用 Certbot 申请 SSL 证书
    echo -e "${YELLOW}正在为 ${DOMAIN_NAME} 申请 SSL 证书...${NC}"
    certbot --nginx -d ${DOMAIN_NAME} --agree-tos --email ${EMAIL} --redirect --non-interactive

    if [ $? -ne 0 ]; then
        echo -e "${RED}SSL 证书申请失败。请检查：${NC}"
        echo -e "${RED}1. 你的域名 (${DOMAIN_NAME}) 是否正确解析到了本服务器的 IP 地址。${NC}"
        echo -e "${RED}2. 服务器的 80 端口是否可以从公网访问。${NC}"
        exit 1
    fi

    # 再次重载 Nginx 以应用 SSL 配置
    systemctl reload nginx
    echo -e "${GREEN}>>> Nginx 和 SSL 配置完成。${NC}"
}

# 显示最终信息
show_final_info() {
    echo -e "===================================================================="
    echo -e "${GREEN}🎉 恭喜！Vaultwarden 部署完成！ 🎉${NC}"
    echo -e "===================================================================="
    echo -e "${YELLOW}你的 Vaultwarden 访问地址是:${NC} https://${DOMAIN_NAME}"
    echo ""
    echo -e "${YELLOW}你的管理员后台访问令牌 (Admin Token) 是:${NC}"
    echo -e "${GREEN}$(cat /opt/vaultwarden/.env | grep ADMIN_TOKEN | cut -d '=' -f2)${NC}"
    echo -e "请访问 https://${DOMAIN_NAME}/admin 并使用此令牌登录。"
    echo -e "这个令牌已保存在 /opt/vaultwarden/.env 文件中，请妥善保管。"
    echo ""
    echo -e "${RED}重要安全提示:${NC}"
    echo -e "1. 尽快登录你的 Vaultwarden 账户，并在【账户设置】中开启【双因素身份验证 (2FA)】。"
    echo -e "2. 定期备份 /opt/vaultwarden/vw-data 目录，这是你的所有密码数据！"
    echo -e "===================================================================="
}

# --- 主函数 ---
main() {
    check_root
    install_dependencies
    get_user_input
    setup_vaultwarden
    setup_nginx_ssl
    show_final_info
}

# --- 执行脚本 ---
main
