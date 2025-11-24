#!/bin/bash

# ============================================
# Guacamole Access Portal - 一鍵移除腳本
# ============================================

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}"
echo "============================================"
echo "  Guacamole Access Portal 移除腳本"
echo "============================================"
echo -e "${NC}"

INSTALL_DIR="/opt/guacamole-portal"

# 確認移除
echo -e "${YELLOW}警告：此操作將移除以下內容：${NC}"
echo "  - PM2 中的 guacamole-api 和 guacamole-frontend 服務"
echo "  - $INSTALL_DIR 目錄及所有資料"
echo "  - 所有申請記錄（資料庫）"
echo ""
read -p "確定要移除 Guacamole Access Portal？(y/n): " confirm

if [ "$confirm" != "y" ]; then
    echo "取消移除"
    exit 0
fi

echo ""

# 停止並刪除 PM2 服務
echo -e "${YELLOW}[1/4] 停止 PM2 服務...${NC}"
if command -v pm2 &> /dev/null; then
    pm2 stop guacamole-api 2>/dev/null || true
    pm2 stop guacamole-frontend 2>/dev/null || true
    pm2 delete guacamole-api 2>/dev/null || true
    pm2 delete guacamole-frontend 2>/dev/null || true
    pm2 save 2>/dev/null || true
    echo "PM2 服務已停止並刪除"
else
    echo "PM2 未安裝，跳過"
fi

# 刪除安裝目錄
echo -e "${YELLOW}[2/4] 刪除安裝目錄...${NC}"
if [ -d "$INSTALL_DIR" ]; then
    rm -rf $INSTALL_DIR
    echo "已刪除 $INSTALL_DIR"
else
    echo "目錄不存在，跳過"
fi

# 詢問是否移除 PM2
echo ""
echo -e "${YELLOW}[3/4] 是否移除 PM2？${NC}"
read -p "移除 PM2 程序管理器？(y/n): " remove_pm2

if [ "$remove_pm2" == "y" ]; then
    pm2 kill 2>/dev/null || true
    npm uninstall -g pm2 2>/dev/null || true
    rm -rf ~/.pm2 2>/dev/null || true
    echo "PM2 已移除"
else
    echo "保留 PM2"
fi

# 詢問是否移除 Node.js
echo ""
echo -e "${YELLOW}[4/4] 是否移除 Node.js？${NC}"
echo -e "${RED}注意：移除 Node.js 可能影響其他應用程式${NC}"
read -p "移除 Node.js？(y/n): " remove_node

if [ "$remove_node" == "y" ]; then
    apt-get remove -y nodejs npm 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    rm -rf /usr/local/lib/node_modules 2>/dev/null || true
    rm -rf ~/.npm 2>/dev/null || true
    echo "Node.js 已移除"
else
    echo "保留 Node.js"
fi

# 關閉防火牆 port（可選）
echo ""
read -p "是否關閉防火牆 port 3000 和 3001？(y/n): " close_ports

if [ "$close_ports" == "y" ]; then
    if command -v ufw &> /dev/null; then
        ufw delete allow 3000/tcp 2>/dev/null || true
        ufw delete allow 3001/tcp 2>/dev/null || true
        echo "防火牆 port 已關閉"
    else
        echo "ufw 未安裝，跳過"
    fi
else
    echo "保留防火牆設定"
fi

echo ""
echo -e "${GREEN}============================================"
echo "  移除完成！"
echo "============================================${NC}"
echo ""
echo "已移除："
echo "  ✓ PM2 服務 (guacamole-api, guacamole-frontend)"
echo "  ✓ 安裝目錄 ($INSTALL_DIR)"
if [ "$remove_pm2" == "y" ]; then
    echo "  ✓ PM2"
fi
if [ "$remove_node" == "y" ]; then
    echo "  ✓ Node.js"
fi
if [ "$close_ports" == "y" ]; then
    echo "  ✓ 防火牆 port (3000, 3001)"
fi
echo ""
