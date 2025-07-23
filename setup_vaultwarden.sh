#!/bin/bash

# ==============================================================================
# Vaultwarden & Nginx 自动化部署脚本 (优化版)
#
# 功能:
# 1. 安装 Docker, Docker Compose, Nginx, Certbot
# 2. 获取用户域名和邮箱信息
# 3. 部署 Vaultwarden (使用 Docker Compose)
# 4. 自动配置 Nginx 反向代理 (采用更稳健的 Webroot 模式)
# 5. 自动申请 Let's Encrypt SSL 证书
#
# 使用方法:
# bash <(curl -sSL https://raw.githubusercontent.com/username/repo/setup_vaultwarden.sh)
# 或
# wget ... && chmod +x ... && sudo ./...
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
        # 进行一些清理工作，以防万一
        systemctl start nginx &>/dev/null
        exit 1
    fi
}

# 安装系统依赖
install_dependencies() {
    echo -e "${GREEN}>>> 1. 正在更新系统并安装依赖 (Docker, Docker Compose, Nginx, Certbot)...${NC}"
    apt-get update
    check_success
    apt-get install -y docker.io docker-compose nginx python3-certbot-nginx curl openssl
    check_success
    
    # 启用并启动 Docker 和 Nginx
    systemctl enable --now docker
    check_success
    systemctl enable --now nginx
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

# 设置并启动 Vaultwarden
setup_vaultwarden() {
    echo -e "${GREEN}>>> 3. 正在配置并启动 Vaultwarden 容器...${NC}"
    
    # 创建 Vaultwarden 工作目录
    mkdir -p /opt/vaultwarden
    cd /opt/vaultwarden

    # 生成一个安全的 ADMIN_TOKEN
    ADMIN_TOKEN=$(openssl rand -base64 48)

    ## 优化 ##：一次性创建最终的 docker-compose.yml，直接暴露端口到本地回环地址
    # 这样更安全，因为服务只对本机Nginx可见，不对外网暴露
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
      - ADMIN_TOKEN=${ADMIN_TOKEN}
    volumes:
      - ./vw-data:/data
EOF
    check_success

    # 创建 .env 文件保存敏感信息
    cat <<EOF > .env
# Vaultwarden 管理员后台访问令牌
# 访问 https://${DOMAIN_NAME}/admin 登录
ADMIN_TOKEN=${ADMIN_TOKEN}
EOF
    check_success

    # 启动 Vaultwarden 容器 (使用--force-recreate确保配置更新)
    docker-compose up -d --force-recreate
    check_success

    # 确保 Vaultwarden 内部服务有时间启动
    echo -e "${YELLOW}等待 10 秒钟，以确保 Vaultwarden 服务完全启动...${NC}"
    sleep 10
    
    echo -e "${GREEN}>>> Vaultwarden 容器已成功启动。${NC}"
}

# 配置 Nginx 和 SSL
setup_nginx_ssl() {
    echo -e "${GREEN}>>> 4. 正在配置 Nginx 并申请 SSL 证书...${NC}"

    # 创建用于Let's Encrypt验证的目录
    mkdir -p /var/www/html
    chown www-data:www-data /var/www/html

    ## 优化 ##：第一阶段 - 只配置HTTP，用于Certbot验证
    echo -e "${YELLOW}--> 步骤 4.1: 配置临时 HTTP Nginx 站点...${NC}"
    cat <<EOF > /etc/nginx/sites-available/vaultwarden.conf
server {
    listen 80;
    server_name ${DOMAIN_NAME};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        # 临时返回一个信息，避免直接暴露服务
        return 404; 
    }
}
EOF
    check_success

    # 启用 Nginx 站点，并移除默认配置以避免冲突
    ln -sfn /etc/nginx/sites-available/vaultwarden.conf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    # 测试并重载Nginx配置
    nginx -t
    check_success
    systemctl reload nginx
    check_success

    ## 优化 ##：第二阶段 - 使用 webroot 模式申请证书
    echo -e "${YELLOW}--> 步骤 4.2: 使用 Certbot (webroot模式) 申请 SSL 证书...${NC}"
    certbot certonly --webroot -w /var/www/html -d ${DOMAIN_NAME} --agree-tos --email ${EMAIL} --non-interactive
    check_success

    # 检查证书是否真的申请成功
    if [ ! -f "/etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem" ]; then
        echo -e "${RED}SSL 证书文件未找到！申请过程可能出现问题。脚本终止。${NC}"
        exit 1
    fi
    echo -e "${GREEN}--> SSL 证书申请成功！${NC}"

    ## 优化 ##：第三阶段 - 配置最终的 HTTPS Nginx 站点
    echo -e "${YELLOW}--> 步骤 4.3: 配置最终的 HTTPS Nginx 站点...${NC}"
    # 生成推荐的SSL参数
    openssl dhparam -out /etc/nginx/dhparam.pem 2048 &>/dev/null & # 后台生成，不阻塞

    cat <<EOF > /etc/nginx/sites-available/vaultwarden.conf
server {
    listen 80;
    server_name ${DOMAIN_NAME};

    # 允许 Certbot 的 HTTP-01 质询并重定向其他所有流量
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN_NAME};

    # SSL 证书路径
    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;

    # 推荐的 SSL 安全设置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    # ssl_dhparam /etc/nginx/dhparam.pem; # 注释掉，如果生成时间太长可以先不用

    # 反向代理到 Vaultwarden
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # WebSocket 反向代理
    location /notifications/hub {
        proxy_pass http://127.0.0.1:3012;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    check_success

    # 等待dhparam生成（如果需要）
    wait
    # 如果dhparam生成完毕，取消注释
    if [ -f /etc/nginx/dhparam.pem ]; then
        sed -i 's/# ssl_dhparam/ssl_dhparam/' /etc/nginx/sites-available/vaultwarden.conf
    fi

    # 再次测试并重载 Nginx 以应用最终的SSL配置
    nginx -t
    check_success
    systemctl reload nginx
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
