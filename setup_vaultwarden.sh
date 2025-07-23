#!/bin/bash

# ==============================================================================
# Vaultwarden & Nginx 自动化部署脚本 (最终优化版)
#
# 结合了稳健的 Nginx/SSL 部署流程和安全的密钥管理实践
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
        echo -e "${RED}错误: 请使用 sudo 或以 root 用户身份运行此脚本。${NC}"
        exit 1
    fi
}

# 检查命令是否成功执行
check_success() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 上一步操作失败，脚本已终止。请检查输出信息。${NC}"
        exit 1
    fi
}

# 安装系统依赖
install_dependencies() {
    echo -e "${GREEN}>>> 1. 正在更新系统并安装依赖...${NC}"
    apt-get update
    check_success
    apt-get install -y docker.io docker-compose nginx python3-certbot-nginx curl openssl
    check_success
    systemctl enable --now docker && systemctl enable --now nginx
    check_success
    echo -e "${GREEN}>>> 依赖安装完成。${NC}"
}

# 获取用户输入
get_user_input() {
    echo -e "${GREEN}>>> 2. 请输入配置信息...${NC}"
    while [ -z "$DOMAIN_NAME" ]; do
        read -p "请输入你的域名 (确保已解析到本机IP): " DOMAIN_NAME
    done
    while [ -z "$EMAIL" ]; do
        read -p "请输入你的邮箱 (用于 Let's Encrypt SSL 证书): " EMAIL
    done
}

# 设置并启动 Vaultwarden (采用 .env 安全实践)
setup_vaultwarden() {
    echo -e "${GREEN}>>> 3. 正在配置并启动 Vaultwarden 容器...${NC}"
    
    mkdir -p /opt/vaultwarden
    cd /opt/vaultwarden

    # 生成一个安全的 ADMIN_TOKEN
    ADMIN_TOKEN=$(openssl rand -base64 48)

    # 创建 docker-compose.yml，注意它只引用变量
    cat <<EOF > docker-compose.yml
version: '3'

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: always
    ports:
      - "127.0.0.1:8080:80"
      - "127.0.0.1:3012:3012"
    environment:
      - WEBSOCKET_ENABLED=true
      # Docker Compose会自动从 .env 文件中读取这个变量的值
      - ADMIN_TOKEN=\${ADMIN_TOKEN}
    volumes:
      - ./vw-data:/data
EOF
    check_success

    # 创建 .env 文件来存储敏感的令牌
    echo -e "${YELLOW}--> 正在创建 .env 文件以安全地存储管理员令牌...${NC}"
    cat <<EOF > .env
# 此文件包含敏感信息，请勿提交到版本控制系统 (e.g., Git)
# Vaultwarden 管理员后台访问令牌
ADMIN_TOKEN=${ADMIN_TOKEN}
EOF
    check_success
    
    # 设置 .env 文件权限，使其更安全
    chmod 600 .env

    # 启动 Vaultwarden 容器
    docker-compose up -d --force-recreate
    check_success

    echo -e "${YELLOW}等待 10 秒钟，确保 Vaultwarden 服务完全启动...${NC}"
    sleep 10
    echo -e "${GREEN}>>> Vaultwarden 容器已成功启动。${NC}"
}

# 配置 Nginx 和 SSL (采用稳健的 Webroot 模式)
setup_nginx_ssl() {
    echo -e "${GREEN}>>> 4. 正在配置 Nginx 并申请 SSL 证书...${NC}"

    mkdir -p /var/www/html
    chown www-data:www-data /var/www/html

    echo -e "${YELLOW}--> 步骤 4.1: 配置临时 HTTP Nginx 站点...${NC}"
    cat <<EOF > /etc/nginx/sites-available/vaultwarden.conf
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 404; }
}
EOF
    check_success

    ln -sfn /etc/nginx/sites-available/vaultwarden.conf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx
    check_success

    echo -e "${YELLOW}--> 步骤 4.2: 使用 Certbot (webroot模式) 申请 SSL 证书...${NC}"
    certbot certonly --webroot -w /var/www/html -d ${DOMAIN_NAME} --agree-tos --email ${EMAIL} --non-interactive
    check_success

    echo -e "${YELLOW}--> 步骤 4.3: 配置最终的 HTTPS Nginx 站点...${NC}"
    cat <<EOF > /etc/nginx/sites-available/vaultwarden.conf
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN_NAME};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    
    # 加载推荐的SSL安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /notifications/hub {
        proxy_pass http://127.0.0.1:3012;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    check_success

    nginx -t && systemctl reload nginx
    check_success
    echo -e "${GREEN}>>> Nginx 和 SSL 配置完成。${NC}"
}

# 显示最终信息
show_final_info() {
    echo -e "===================================================================="
    echo -e "${GREEN}🎉 恭喜！Vaultwarden 部署完成！ 🎉${NC}"
    echo -e "===================================================================="
    echo -e "${YELLOW}你的 Vaultwarden 访问地址是:${NC} https://${DOMAIN_NAME}"
    echo ""
    echo -e "${YELLOW}你的管理员后台访问令牌 (Admin Token) 已保存在文件 /opt/vaultwarden/.env 中。${NC}"
    echo -e "请使用以下命令查看："
    echo -e "  ${GREEN}sudo cat /opt/vaultwarden/.env${NC}"
    echo ""
    echo -e "请访问 https://${DOMAIN_NAME}/admin 并使用此令牌登录。"
    echo -e "${RED}重要安全提示:${NC}"
    echo -e "1. 开启双因素认证 (2FA)。"
    echo -e "2. 定期备份 /opt/vaultwarden/vw-data 目录！"
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
