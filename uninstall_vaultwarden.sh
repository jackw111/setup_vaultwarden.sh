#!/bin/bash

# ==============================================================================
# Vaultwarden & Nginx 完整卸载脚本
#
# 这个脚本将帮助你安全地移除 Vaultwarden 容器、Nginx 配置、
# 以及可选地删除数据卷和 SSL 证书。
# ==============================================================================

# --- 配置颜色输出 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- 检查脚本是否以 root 权限运行 ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 sudo 或以 root 用户身份运行此脚本。${NC}"
    exit 1
fi

# --- 主函数 ---
main() {
    echo -e "${YELLOW}====================================================${NC}"
    echo -e "${YELLOW}  Vaultwarden 卸载程序${NC}"
    echo -e "${YELLOW}====================================================${NC}"
    echo -e "此脚本将按步骤停止并移除 Vaultwarden 及其相关组件。"
    echo -e "${RED}请在继续前仔细阅读每个步骤的提示！${NC}\n"
    read -p "按 [Enter] 键开始..."

    # --- 1. 停止并移除 Docker 容器 ---
    echo -e "\n${GREEN}>>> 步骤 1: 停止并移除 Vaultwarden Docker 容器...${NC}"
    if [ -d "/opt/vaultwarden" ] && [ -f "/opt/vaultwarden/docker-compose.yml" ]; then
        cd /opt/vaultwarden
        if docker-compose ps | grep -q "vaultwarden"; then
            echo "检测到正在运行的 Vaultwarden 容器，正在停止..."
            docker-compose down
            echo "容器已停止并移除。"
        else
            echo "未检测到正在运行的 Vaultwarden 容器，跳过。"
        fi
    else
        echo "未找到 /opt/vaultwarden 目录或 docker-compose.yml 文件，可能已手动删除，跳过。"
    fi

    # --- 2. 移除 Docker 镜像 ---
    echo -e "\n${GREEN}>>> 步骤 2: 移除 Vaultwarden Docker 镜像...${NC}"
    if docker images | grep -q "vaultwarden/server"; then
        echo "正在移除 vaultwarden/server 镜像..."
        docker rmi vaultwarden/server:latest
    else
        echo "未找到 vaultwarden/server 镜像，跳过。"
    fi

    # --- 3. 移除 Nginx 配置 ---
    echo -e "\n${GREEN}>>> 步骤 3: 移除 Nginx 配置文件...${NC}"
    NGINX_CONF_FILE="/etc/nginx/sites-available/vaultwarden.conf"
    NGINX_LINK_FILE="/etc/nginx/sites-enabled/vaultwarden.conf"
    
    if [ -f "$NGINX_CONF_FILE" ]; then
        echo "正在移除 Nginx 配置文件: $NGINX_CONF_FILE"
        rm -f "$NGINX_CONF_FILE"
        rm -f "$NGINX_LINK_FILE"
        
        # 恢复默认的 Nginx 配置
        if [ ! -f "/etc/nginx/sites-enabled/default" ] && [ -f "/etc/nginx/sites-available/default" ]; then
            echo "正在恢复默认的 Nginx 欢迎页面..."
            ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
        fi

        echo "正在测试并重载 Nginx 配置..."
        nginx -t && systemctl reload nginx
        echo "Nginx 配置已移除。"
    else
        echo "未找到 Nginx 配置文件，跳过。"
    fi

    # --- 4. 删除数据 (危险操作，需用户确认) ---
    echo ""
    read -p "$(echo -e ${YELLOW}"[警告] 是否要删除 Vaultwarden 的所有数据 (密码库)？这个操作不可逆！(输入 'yes' 确认): "${NC})" CONFIRM_DELETE_DATA
    if [[ "$CONFIRM_DELETE_DATA" == "yes" ]]; then
        if [ -d "/opt/vaultwarden" ]; then
            echo -e "${RED}正在删除 /opt/vaultwarden 目录及其所有内容...${NC}"
            rm -rf /opt/vaultwarden
            echo "Vaultwarden 数据和配置文件已彻底删除。"
        else
            echo "未找到 /opt/vaultwarden 目录，跳过。"
        fi
    else
        echo -e "${GREEN}已选择保留 /opt/vaultwarden 数据目录。${NC}"
    fi

    # --- 5. 删除 SSL 证书 (危险操作，需用户确认) ---
    echo ""
    read -p "请输入之前为 Vaultwarden 配置的域名 (用于查找SSL证书): " DOMAIN_NAME
    if [ -n "$DOMAIN_NAME" ] && [ -d "/etc/letsencrypt/live/${DOMAIN_NAME}" ]; then
        read -p "$(echo -e ${YELLOW}"[警告] 是否要删除域名 ${DOMAIN_NAME} 的 SSL 证书？(输入 'yes' 确认): "${NC})" CONFIRM_DELETE_CERT
        if [[ "$CONFIRM_DELETE_CERT" == "yes" ]]; then
            echo -e "${RED}正在使用 certbot 删除 ${DOMAIN_NAME} 的证书...${NC}"
            certbot delete --cert-name "${DOMAIN_NAME}" --non-interactive
            echo "SSL 证书已删除。"
        else
            echo -e "${GREEN}已选择保留 SSL 证书。${NC}"
        fi
    else
        echo "未提供域名或未找到对应证书，跳过。"
    fi
    
    echo -e "\n${GREEN}====================================================${NC}"
    echo -e "${GREEN}  卸载完成！${NC}"
    echo -e "${GREEN}====================================================${NC}"
    echo "系统已清理完毕。你现在可以重新运行安装脚本进行全新安装了。"
}

# --- 执行脚本 ---
main
