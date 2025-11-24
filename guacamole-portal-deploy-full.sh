#!/bin/bash

# ============================================
# Guacamole Access Portal - 完整一鍵部署腳本
# 適用於 Ubuntu 18.04/20.04/22.04/24.04
# ============================================

set -e

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}"
echo "============================================"
echo "  Guacamole Access Portal 完整部署腳本"
echo "============================================"
echo -e "${NC}"

# 設定安裝目錄
INSTALL_DIR="/opt/guacamole-portal"
BACKEND_PORT=3001
FRONTEND_PORT=3000

# 取得伺服器 IP
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "${CYAN}偵測到伺服器 IP: ${SERVER_IP}${NC}"
echo ""

# ============================================
# 收集配置資訊
# ============================================
echo -e "${YELLOW}=== 系統配置 ===${NC}"
echo ""

# URL 配置
read -p "前端網址 (預設 http://$SERVER_IP:$FRONTEND_PORT): " BASE_URL
BASE_URL=${BASE_URL:-"http://$SERVER_IP:$FRONTEND_PORT"}

read -p "API 網址 (預設 http://$SERVER_IP:$BACKEND_PORT): " API_URL
API_URL=${API_URL:-"http://$SERVER_IP:$BACKEND_PORT"}

read -p "Guacamole 網址 (例如 http://$SERVER_IP:8080/guacamole): " GUACAMOLE_URL
if [ -z "$GUACAMOLE_URL" ]; then
    echo -e "${RED}錯誤: Guacamole 網址不能為空${NC}"
    exit 1
fi

# 從 GUACAMOLE_URL 解析主機和端口
GUACAMOLE_HOST=$(echo "$GUACAMOLE_URL" | sed -E 's|https?://([^:/]+).*|\1|')
GUACAMOLE_PORT=$(echo "$GUACAMOLE_URL" | sed -E 's|https?://[^:]+:([0-9]+).*|\1|')
if [ "$GUACAMOLE_PORT" = "$GUACAMOLE_URL" ]; then
    # 如果沒有端口，使用預設值
    if echo "$GUACAMOLE_URL" | grep -q "^https"; then
        GUACAMOLE_PORT=443
    else
        GUACAMOLE_PORT=80
    fi
fi

echo ""
echo -e "${YELLOW}=== SMTP 郵件配置 ===${NC}"
echo ""
echo "常用 SMTP 設定："
echo "  Gmail: smtp.gmail.com, Port 587"
echo "  Outlook: smtp-mail.outlook.com, Port 587"
echo ""
echo -e "${CYAN}注意：Gmail 需要使用「應用程式密碼」而非一般密碼${NC}"
echo ""

read -p "SMTP 主機 (預設 smtp.gmail.com): " SMTP_HOST
SMTP_HOST=${SMTP_HOST:-"smtp.gmail.com"}

read -p "SMTP 端口 (預設 587): " SMTP_PORT
SMTP_PORT=${SMTP_PORT:-587}

read -p "SMTP 帳號 (您的郵件地址): " SMTP_USER
if [ -z "$SMTP_USER" ]; then
    echo -e "${RED}錯誤: SMTP 帳號不能為空${NC}"
    exit 1
fi

read -sp "SMTP 密碼 (應用程式密碼，留空則不使用密碼): " SMTP_PASS
echo ""
# SMTP 密碼為可選，留空則使用匿名 SMTP

read -p "管理員郵件 (接收審核通知): " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-$SMTP_USER}

read -sp "管理員密碼 (用於登入管理頁面): " ADMIN_PASSWORD
echo ""
if [ -z "$ADMIN_PASSWORD" ]; then
    echo -e "${RED}錯誤: 管理員密碼不能為空${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}=== 配置確認 ===${NC}"
echo ""
echo "  前端網址: $BASE_URL"
echo "  API 網址: $API_URL"
echo "  Guacamole: $GUACAMOLE_URL"
echo "  SMTP 主機: $SMTP_HOST:$SMTP_PORT"
echo "  SMTP 帳號: $SMTP_USER"
echo "  管理員郵件: $ADMIN_EMAIL"
echo "  管理員密碼: ***（已設定）***"
echo ""
read -p "確認以上設定正確？(y/n): " confirm
if [ "$confirm" != "y" ]; then
    echo "取消部署"
    exit 1
fi

# ============================================
# 開始安裝
# ============================================
echo ""
echo -e "${YELLOW}[1/8] 安裝系統依賴...${NC}"

# 檢查並等待 dpkg 鎖定釋放
wait_for_dpkg_lock() {
    local max_wait=300  # 最多等待 5 分鐘
    local wait_time=0
    local check_interval=5
    
    while [ $wait_time -lt $max_wait ]; do
        if ! lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
           ! lsof /var/lib/dpkg/lock >/dev/null 2>&1 && \
           ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
           ! fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
            echo -e "${GREEN}dpkg 鎖定已釋放${NC}"
            return 0
        fi
        
        if [ $wait_time -eq 0 ]; then
            echo -e "${YELLOW}檢測到 dpkg 鎖定，等待自動更新完成...${NC}"
        fi
        
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
        
        # 每 30 秒顯示一次進度
        if [ $((wait_time % 30)) -eq 0 ]; then
            echo -e "${CYAN}已等待 ${wait_time} 秒...${NC}"
        fi
    done
    
    echo -e "${RED}錯誤：等待 dpkg 鎖定超時${NC}"
    echo -e "${YELLOW}請手動執行以下命令後再重試：${NC}"
    echo "  sudo systemctl stop unattended-upgrades"
    echo "  sudo killall unattended-upgr"
    return 1
}

# 等待 dpkg 鎖定釋放
if ! wait_for_dpkg_lock; then
    exit 1
fi

# 嘗試停止自動更新（如果正在運行）
if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    echo -e "${YELLOW}停止自動更新服務...${NC}"
    systemctl stop unattended-upgrades 2>/dev/null || true
fi

apt-get update
apt-get install -y curl wget gnupg2

# 安裝 Node.js 20.x LTS (長期支援版本，支援至 2026年4月)
if ! command -v node &> /dev/null; then
    echo -e "${YELLOW}安裝 Node.js 20.x LTS...${NC}"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi

# 更新 npm 到最新版本
echo -e "${YELLOW}更新 npm 到最新版本...${NC}"
npm install -g npm@latest

echo "Node.js 版本: $(node -v)"
echo "npm 版本: $(npm -v)"

# 安裝 PM2
echo -e "${YELLOW}[2/8] 安裝 PM2 程序管理器...${NC}"
npm install -g pm2

# 建立安裝目錄
echo -e "${YELLOW}[3/8] 建立專案目錄...${NC}"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# ============================================
# 建立後端
# ============================================
echo -e "${YELLOW}[4/8] 建立後端 API...${NC}"
echo -e "${CYAN}清除舊的資料庫檔案以確保結構同步...${NC}"
rm -f $INSTALL_DIR/backend/access_requests.db
mkdir -p backend

cat > backend/package.json << 'EOF'
{
  "name": "guacamole-access-portal-backend",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.7",
    "express": "^4.21.2",
    "http-proxy": "^1.18.1",
    "nodemailer": "^7.0.10",
    "sqlite3": "^5.1.7"
  }
}
EOF

cat > backend/server.js << 'SERVEREOF'
// 載入環境變數（從 .env 檔案或系統環境變數）
require('dotenv').config();

const express = require('express');
const cors = require('cors');
const nodemailer = require('nodemailer');
const crypto = require('crypto');
const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const httpProxy = require('http-proxy');
const url = require('url');

const app = express();
app.use(cors());
app.use(express.json());

// 從環境變數讀取配置
const GUACAMOLE_URL = process.env.GUACAMOLE_URL || 'http://localhost:8080/guacamole';
const GUACAMOLE_PROTOCOL = GUACAMOLE_URL.startsWith('https') ? 'https' : 'http';

const CONFIG = {
  ADMIN_EMAIL: process.env.ADMIN_EMAIL || 'admin@example.com',
  ADMIN_PASSWORD: process.env.ADMIN_PASSWORD || 'admin',
  SMTP_HOST: process.env.SMTP_HOST || 'smtp.gmail.com',
  SMTP_PORT: parseInt(process.env.SMTP_PORT) || 587,
  SMTP_USER: process.env.SMTP_USER || '',
  SMTP_PASS: process.env.SMTP_PASS || '',
  BASE_URL: process.env.BASE_URL || 'http://localhost:3000',
  API_URL: process.env.API_URL || 'http://localhost:3001',
  GUACAMOLE_URL: GUACAMOLE_URL,
  GUACAMOLE_PROTOCOL: GUACAMOLE_PROTOCOL,
  GUACAMOLE_HOST: process.env.GUACAMOLE_HOST || 'localhost',
  GUACAMOLE_PORT: parseInt(process.env.GUACAMOLE_PORT) || 8080,
  TOKEN_EXPIRY_HOURS: 24
};

console.log('========================================');
console.log('Guacamole Access Portal API 啟動');
console.log('========================================');
console.log('SMTP 配置:');
console.log('  Host:', CONFIG.SMTP_HOST);
console.log('  Port:', CONFIG.SMTP_PORT);
console.log('  User:', CONFIG.SMTP_USER);
console.log('  Auth:', CONFIG.SMTP_PASS && CONFIG.SMTP_PASS.trim() !== '' ? '已啟用' : '未啟用（匿名 SMTP）');
console.log('  Admin:', CONFIG.ADMIN_EMAIL);
console.log('URL 配置:');
console.log('  BASE_URL:', CONFIG.BASE_URL);
console.log('  API_URL:', CONFIG.API_URL);
console.log('  GUACAMOLE_URL:', CONFIG.GUACAMOLE_URL);
console.log('========================================');

// 初始化 SQLite 資料庫
const db = new sqlite3.Database(path.join(__dirname, 'access_requests.db'));

db.serialize(() => {
  db.run(`
    CREATE TABLE IF NOT EXISTS access_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      request_id TEXT UNIQUE,
      name TEXT NOT NULL,
      email TEXT NOT NULL,
      department TEXT,
      reason TEXT NOT NULL,
      status TEXT DEFAULT 'pending',
      access_token TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      approved_at DATETIME,
      expires_at DATETIME,
      duration_hours INTEGER
    )
  `);
});

// 輔助函數：驗證 token 並返回申請紀錄
function getValidRequestByToken(db, token) {
  return new Promise((resolve, reject) => {
    db.get('SELECT * FROM access_requests WHERE access_token = ?', [token], (err, row) => {
      if (err) return reject(err);
      if (!row || row.status !== 'approved' || new Date(row.expires_at) < new Date()) {
        return resolve(null); // 無效、未批准或已過期
      }
      resolve(row); // 合法
    });
  });
}

// 設定郵件傳輸器
const smtpConfig = {
  host: CONFIG.SMTP_HOST,
  port: CONFIG.SMTP_PORT,
  secure: CONFIG.SMTP_PORT === 465,
  tls: {
    rejectUnauthorized: false
  }
};

// 只有在提供密碼時才設置認證
if (CONFIG.SMTP_PASS && CONFIG.SMTP_PASS.trim() !== '') {
  smtpConfig.auth = {
    user: CONFIG.SMTP_USER,
    pass: CONFIG.SMTP_PASS
  };
} else if (CONFIG.SMTP_USER && CONFIG.SMTP_USER.trim() !== '') {
  // 如果只有用戶名沒有密碼，也設置用戶名（某些 SMTP 伺服器需要）
  smtpConfig.auth = {
    user: CONFIG.SMTP_USER
  };
}

const transporter = nodemailer.createTransport(smtpConfig);

// 驗證 SMTP 連線
transporter.verify(function(error, success) {
  if (error) {
    console.error('SMTP 連線失敗:', error.message);
  } else {
    console.log('SMTP 連線成功，郵件服務準備就緒');
  }
});

function generateId() {
  return crypto.randomBytes(16).toString('hex');
}

// 根路徑 - API 狀態
app.get('/', (req, res) => {
  res.json({ 
    status: 'ok', 
    message: 'Guacamole Access Portal API is running',
    config: {
      BASE_URL: CONFIG.BASE_URL,
      API_URL: CONFIG.API_URL,
      GUACAMOLE_URL: CONFIG.GUACAMOLE_URL
    }
  });
});

// 測試郵件發送
app.get('/api/test-email/:email', async (req, res) => {
  const { email } = req.params;
  
  try {
    await transporter.sendMail({
      from: CONFIG.SMTP_USER,
      to: email,
      subject: '[Guacamole] 郵件測試',
      html: `
        <div style="font-family: Arial, sans-serif; padding: 20px;">
          <h2 style="color: #28a745;">✓ 郵件測試成功</h2>
          <p>如果您收到這封郵件，表示 SMTP 設定正確。</p>
          <p>發送時間: ${new Date().toLocaleString('zh-TW')}</p>
        </div>
      `
    });
    res.json({ success: true, message: `測試郵件已發送到 ${email}` });
  } catch (error) {
    console.error('郵件發送失敗:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// API: 提交存取申請
app.post('/api/request-access', async (req, res) => {
  const { name, email, department, reason } = req.body;
  
  if (!name || !email || !reason) {
    return res.status(400).json({ error: '請填寫所有必填欄位' });
  }

  const requestId = generateId();

  try {
    await new Promise((resolve, reject) => {
      db.run(
        `INSERT INTO access_requests (request_id, name, email, department, reason) 
         VALUES (?, ?, ?, ?, ?)`,
        [requestId, name, email, department, reason],
        (err) => err ? reject(err) : resolve()
      );
    });

    const approveUrl1h = `${CONFIG.API_URL}/api/approve/${requestId}?duration=1`;
    const approveUrl4h = `${CONFIG.API_URL}/api/approve/${requestId}?duration=4`;
    const approveUrl8h = `${CONFIG.API_URL}/api/approve/${requestId}?duration=8`;
    const approveUrl24h = `${CONFIG.API_URL}/api/approve/${requestId}?duration=24`;
    const rejectUrl = `${CONFIG.API_URL}/api/reject/${requestId}`;

    try {
      console.log('發送申請通知到:', CONFIG.ADMIN_EMAIL);
      
      await transporter.sendMail({
        from: CONFIG.SMTP_USER,
        to: CONFIG.ADMIN_EMAIL,
        subject: `[Guacamole 存取申請] ${name} 申請連線權限`,
        html: `
          <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
            <h2 style="color: #333;">Apache Guacamole 存取申請</h2>
            <div style="background: #f5f5f5; padding: 20px; border-radius: 8px;">
              <p><strong>申請人：</strong>${name}</p>
              <p><strong>電子郵件：</strong>${email}</p>
              <p><strong>部門：</strong>${department || '未提供'}</p>
              <p><strong>申請原因：</strong></p>
              <p style="background: #fff; padding: 10px; border-radius: 4px;">${reason}</p>
              <p><strong>申請時間：</strong>${new Date().toLocaleString('zh-TW')}</p>
            </div>
            <div style="margin-top: 20px;">
              <p><strong>請選擇核准的有效時間：</strong></p>
              <a href="${approveUrl1h}" style="display: inline-block; padding: 10px 18px; background: #28a745; color: white; text-decoration: none; border-radius: 4px; margin: 5px;">✓ 核准 1 小時</a>
              <a href="${approveUrl4h}" style="display: inline-block; padding: 10px 18px; background: #28a745; color: white; text-decoration: none; border-radius: 4px; margin: 5px;">✓ 核准 4 小時</a>
              <a href="${approveUrl8h}" style="display: inline-block; padding: 10px 18px; background: #28a745; color: white; text-decoration: none; border-radius: 4px; margin: 5px;">✓ 核准 8 小時</a>
              <a href="${approveUrl24h}" style="display: inline-block; padding: 10px 18px; background: #28a745; color: white; text-decoration: none; border-radius: 4px; margin: 5px;">✓ 核准 24 小時</a>
            </div>
            <div style="margin-top: 20px;">
              <a href="${rejectUrl}" style="display: inline-block; padding: 10px 18px; background: #dc3545; color: white; text-decoration: none; border-radius: 4px; margin: 5px;">✗ 拒絕申請</a>
            </div>
          </div>
        `
      });

      console.log('發送確認郵件到:', email);
      
      await transporter.sendMail({
        from: CONFIG.SMTP_USER,
        to: email,
        subject: '[Guacamole] 您的存取申請已收到',
        html: `
          <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
            <h2 style="color: #333;">存取申請已收到</h2>
            <p>親愛的 ${name}，</p>
            <p>您的 Apache Guacamole 存取申請已成功提交。</p>
            <p>申請編號：<strong>${requestId.substring(0, 8).toUpperCase()}</strong></p>
            <p>我們將盡快審核您的申請，審核結果將透過電子郵件通知您。</p>
          </div>
        `
      });
      
    } catch (mailError) {
      console.error('郵件發送失敗:', mailError.message);
    }

    res.json({ 
      success: true, 
      message: '申請已提交，請等待管理員審核',
      requestId: requestId.substring(0, 8).toUpperCase()
    });

  } catch (error) {
    console.error('Error:', error);
    res.status(500).json({ error: '提交申請時發生錯誤' });
  }
});

// API: 核准申請
app.get('/api/approve/:requestId', async (req, res) => {
  const { requestId } = req.params;
  const durationHours = parseInt(req.query.duration, 10) || 24;

  try {
    const request = await new Promise((resolve, reject) => {
      db.get('SELECT * FROM access_requests WHERE request_id = ?', [requestId],
        (err, row) => err ? reject(err) : resolve(row));
    });

    if (!request) {
      return res.status(404).send(generateResultPage('error', '找不到該申請'));
    }

    if (request.status !== 'pending') {
      return res.send(generateResultPage('info', '此申請已處理過'));
    }

    const accessToken = generateId();
    const expiresAt = new Date();
    expiresAt.setHours(expiresAt.getHours() + durationHours);

    await new Promise((resolve, reject) => {
      db.run(
        `UPDATE access_requests 
         SET status = 'approved', access_token = ?, approved_at = CURRENT_TIMESTAMP, expires_at = ?, duration_hours = ?
         WHERE request_id = ?`,
        [accessToken, expiresAt.toISOString(), durationHours, requestId],
        (err) => err ? reject(err) : resolve()
      );
    });

    const accessUrl = `${CONFIG.BASE_URL}/#access/${accessToken}`;
    
    console.log('核准申請:', request.name);
    console.log('存取連結:', accessUrl);
    
    try {
      console.log('發送核准通知到:', request.email);
      
      // 計算核准時間和到期時間
      const approvedAt = new Date();
      const expiresAtDate = new Date(expiresAt);
      const approvedAtFormatted = approvedAt.toLocaleString('zh-TW', { 
        timeZone: 'Asia/Taipei',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit'
      });
      const expiresAtFormatted = expiresAtDate.toLocaleString('zh-TW', { 
        timeZone: 'Asia/Taipei',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit'
      });

      await transporter.sendMail({
        from: CONFIG.SMTP_USER,
        to: request.email,
        subject: '[Guacamole] 您的存取申請已核准',
        html: `
          <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
            <h2 style="color: #28a745;">✓ 存取申請已核准</h2>
            <p>親愛的 ${request.name}，</p>
            <p>您的 Apache Guacamole 存取申請已獲得核准。管理者核准可連線時間：<strong>${durationHours} 小時</strong>（自 ${approvedAtFormatted} 起至 ${expiresAtFormatted} 止）。</p>
            <div style="background: #e7f3ff; border-left: 4px solid #007bff; padding: 15px; margin: 20px 0; border-radius: 4px;">
              <p style="margin: 0; color: #004085;"><strong>核准時間：</strong>${approvedAtFormatted}</p>
              <p style="margin: 5px 0 0 0; color: #004085;"><strong>到期時間：</strong>${expiresAtFormatted}</p>
              <p style="margin: 5px 0 0 0; color: #004085;"><strong>有效時長：</strong>${durationHours} 小時</p>
            </div>
            <p>請點擊下方按鈕進入系統：</p>
            <div style="text-align: center; margin: 20px 0;">
              <a href="${accessUrl}" 
                 style="display: inline-block; padding: 15px 30px; background: #007bff; color: white; text-decoration: none; border-radius: 4px; font-size: 16px;">
                進入 Guacamole
              </a>
            </div>
            <p style="color: #666; font-size: 14px;">或複製以下連結到瀏覽器：</p>
            <p style="background: #f5f5f5; padding: 10px; border-radius: 4px; word-break: break-all; font-size: 12px;">
              ${accessUrl}
            </p>
            <p style="color: #dc3545; margin-top: 20px;">
              <strong>注意：</strong>此連結將在 ${durationHours} 小時後失效（${expiresAtFormatted}）
            </p>
          </div>
        `
      });
      
      console.log('核准通知已發送');
      
    } catch (mailError) {
      console.error('核准郵件發送失敗:', mailError.message);
    }

    res.send(generateResultPage('success', `已核准 ${request.name} 的存取申請，通知郵件已發送到 ${request.email}`));

  } catch (error) {
    console.error('Error:', error);
    res.status(500).send(generateResultPage('error', '處理申請時發生錯誤'));
  }
});

// API: 拒絕申請
app.get('/api/reject/:requestId', async (req, res) => {
  const { requestId } = req.params;
  
  try {
    const request = await new Promise((resolve, reject) => {
      db.get('SELECT * FROM access_requests WHERE request_id = ?', [requestId],
        (err, row) => err ? reject(err) : resolve(row));
    });

    if (!request) {
      return res.status(404).send(generateResultPage('error', '找不到該申請'));
    }

    if (request.status !== 'pending') {
      return res.send(generateResultPage('info', '此申請已處理過'));
    }

    await new Promise((resolve, reject) => {
      db.run(`UPDATE access_requests SET status = 'rejected' WHERE request_id = ?`,
        [requestId], (err) => err ? reject(err) : resolve());
    });

    try {
      await transporter.sendMail({
        from: CONFIG.SMTP_USER,
        to: request.email,
        subject: '[Guacamole] 您的存取申請未獲核准',
        html: `
          <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
            <h2 style="color: #dc3545;">存取申請未獲核准</h2>
            <p>親愛的 ${request.name}，</p>
            <p>很抱歉，您的存取申請未獲核准。如有疑問，請聯繫管理員。</p>
          </div>
        `
      });
    } catch (mailError) {
      console.error('拒絕郵件發送失敗:', mailError.message);
    }

    res.send(generateResultPage('rejected', `已拒絕 ${request.name} 的存取申請`));

  } catch (error) {
    console.error('Error:', error);
    res.status(500).send(generateResultPage('error', '處理申請時發生錯誤'));
  }
});

// API: 驗證存取 token
app.get('/api/verify-access/:token', async (req, res) => {
  const { token } = req.params;
  
  console.log('驗證 token:', token);
  
  try {
    const request = await new Promise((resolve, reject) => {
      db.get('SELECT * FROM access_requests WHERE access_token = ?', [token],
        (err, row) => err ? reject(err) : resolve(row));
    });

    if (!request) {
      return res.json({ valid: false, error: '無效的存取連結' });
    }

    if (request.status !== 'approved') {
      return res.json({ valid: false, error: '此申請尚未核准' });
    }

    if (new Date(request.expires_at) < new Date()) {
      return res.json({ valid: false, error: '存取連結已過期，請重新申請' });
    }

    // 返回 /connect/{token} 路徑，通過代理訪問 Guacamole
    const connectUrl = `${CONFIG.BASE_URL}/connect/${token}`;
    console.log('驗證成功，用戶:', request.name, '-> 跳轉到:', connectUrl);
    
    res.json({ 
      valid: true, 
      guacamoleUrl: connectUrl,
      name: request.name,
      expiresAt: request.expires_at
    });

  } catch (error) {
    console.error('Error:', error);
    res.status(500).json({ valid: false, error: '驗證時發生錯誤' });
  }
});

// 管理員認證中間件
function requireAdminAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Basic ')) {
    res.setHeader('WWW-Authenticate', 'Basic realm="Admin Area"');
    return res.status(401).send('需要管理員認證');
  }

  const base64Credentials = authHeader.split(' ')[1];
  const credentials = Buffer.from(base64Credentials, 'base64').toString('ascii');
  const [username, password] = credentials.split(':');

  if (username === 'admin' && password === CONFIG.ADMIN_PASSWORD) {
    next();
  } else {
    res.setHeader('WWW-Authenticate', 'Basic realm="Admin Area"');
    res.status(401).send('管理員認證失敗');
  }
}

// API: 管理員登入驗證
app.post('/api/admin/login', async (req, res) => {
  const { password } = req.body;

  if (!password) {
    return res.status(400).json({ success: false, error: '請輸入密碼' });
  }

  if (password === CONFIG.ADMIN_PASSWORD) {
    // 產生一個簡單的 session token
    const token = crypto.randomBytes(32).toString('hex');
    // 在實際生產環境中，應該將 token 儲存在 Redis 或資料庫中
    // 這裡為了簡單起見，使用全域變數（注意：這在多進程環境中不會共享）
    global.adminTokens = global.adminTokens || new Set();
    global.adminTokens.add(token);

    res.json({
      success: true,
      message: '登入成功',
      token: token
    });
  } else {
    res.status(401).json({ success: false, error: '密碼錯誤' });
  }
});

// 管理員 Token 驗證中間件
function requireAdminToken(req, res, next) {
  const token = req.headers['x-admin-token'] || req.query.token;

  if (!token) {
    return res.status(401).json({ 
      success: false,
      error: '需要管理員認證',
      message: '請重新登入'
    });
  }

  global.adminTokens = global.adminTokens || new Set();
  if (global.adminTokens.has(token)) {
    next();
  } else {
    return res.status(401).json({ 
      success: false,
      error: '無效的管理員認證',
      message: 'Token已過期或無效，請重新登入'
    });
  }
}

// API: 查看所有申請（需要管理員認證）
app.get('/api/admin/requests', requireAdminToken, async (req, res) => {
  try {
    const { status, email, date_from, date_to } = req.query;

    let sql = 'SELECT * FROM access_requests WHERE 1=1';
    let params = [];

    if (status && status !== 'all') {
      sql += ' AND status = ?';
      params.push(status);
    }

    if (email) {
      sql += ' AND email LIKE ?';
      params.push(`%${email}%`);
    }

    if (date_from) {
      sql += ' AND created_at >= ?';
      params.push(date_from + ' 00:00:00');
    }

    if (date_to) {
      sql += ' AND created_at <= ?';
      params.push(date_to + ' 23:59:59');
    }

    sql += ' ORDER BY created_at DESC';

    const requests = await new Promise((resolve, reject) => {
      db.all(sql, params, (err, rows) => err ? reject(err) : resolve(rows));
    });

    // 統計資訊
    const stats = await new Promise((resolve, reject) => {
      db.get(`
        SELECT
          COUNT(CASE WHEN status = 'pending' THEN 1 END) as pending_count,
          COUNT(CASE WHEN status = 'approved' THEN 1 END) as approved_count,
          COUNT(CASE WHEN status = 'rejected' THEN 1 END) as rejected_count,
          COUNT(*) as total_count
        FROM access_requests
      `, [], (err, row) => err ? reject(err) : resolve(row));
    });

    res.json({
      requests,
      stats
    });
  } catch (error) {
    console.error('查詢申請記錄失敗:', error);
    res.status(500).json({ error: '查詢失敗' });
  }
});

// API: 匯出申請記錄為 CSV（需要管理員認證）
app.get('/api/admin/requests/export', requireAdminToken, async (req, res) => {
  try {
    const { status, email, date_from, date_to } = req.query;

    let sql = 'SELECT * FROM access_requests WHERE 1=1';
    let params = [];

    if (status && status !== 'all') {
      sql += ' AND status = ?';
      params.push(status);
    }

    if (email) {
      sql += ' AND email LIKE ?';
      params.push(`%${email}%`);
    }

    if (date_from) {
      sql += ' AND created_at >= ?';
      params.push(date_from + ' 00:00:00');
    }

    if (date_to) {
      sql += ' AND created_at <= ?';
      params.push(date_to + ' 23:59:59');
    }

    sql += ' ORDER BY created_at DESC';

    const requests = await new Promise((resolve, reject) => {
      db.all(sql, params, (err, rows) => err ? reject(err) : resolve(rows));
    });

    // 設定 CSV 標頭
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="guacamole-access-requests.csv"');

    // 添加 BOM 以支援中文
    res.write('\ufeff');

    // CSV 標題行
    res.write('申請編號,姓名,電子郵件,部門,申請原因,狀態,申請時間,核准時間,到期時間,有效時長\r\n');

    // 寫入資料
    requests.forEach(request => {
      const statusText = {
        'pending': '待審核',
        'approved': '已核准',
        'rejected': '已拒絕'
      }[request.status] || request.status;

      const row = [
        request.request_id ? `"${request.request_id}"` : '',
        `"${request.name || ''}"`,
        `"${request.email || ''}"`,
        `"${request.department || ''}"`,
        `"${(request.reason || '').replace(/"/g, '""')}"`,
        `"${statusText}"`,
        request.created_at ? `"${request.created_at}"` : '',
        request.approved_at ? `"${request.approved_at}"` : '',
        request.expires_at ? `"${request.expires_at}"` : '',
        request.duration_hours ? `${request.duration_hours}小時` : ''
      ];

      res.write(row.join(',') + '\r\n');
    });

    res.end();

  } catch (error) {
    console.error('匯出記錄失敗:', error);
    res.status(500).json({ error: '匯出失敗' });
  }
});

function generateResultPage(type, message) {
  const colors = { success: '#28a745', error: '#dc3545', info: '#17a2b8', rejected: '#dc3545' };
  const icons = { success: '✓', error: '✗', info: 'ℹ', rejected: '✗' };
  return `
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <title>處理結果</title>
      <style>
        body { font-family: Arial, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #f5f5f5; }
        .container { text-align: center; padding: 40px; background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); max-width: 500px; }
        .icon { font-size: 48px; color: ${colors[type]}; }
        .message { margin-top: 20px; font-size: 18px; color: #333; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="icon">${icons[type]}</div>
        <div class="message">${message}</div>
      </div>
    </body>
    </html>
  `;
}

function generateErrorPage(title, message) {
  return `
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <title>${title}</title>
      <style>
        body { font-family: Arial, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #f5f5f5; }
        .container { text-align: center; padding: 40px; background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); max-width: 500px; }
        .icon { font-size: 48px; color: #dc3545; }
        .title { margin-top: 20px; font-size: 24px; color: #333; }
        .message { margin-top: 10px; font-size: 16px; color: #666; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="icon">✗</div>
        <div class="title">${title}</div>
        <div class="message">${message}</div>
      </div>
    </body>
    </html>
  `;
}

function rewriteHtmlResponse(proxyRes, res, token, guacamoleBasePath, headers = null, statusCode = 200) {
  let body = '';
  proxyRes.on('data', (chunk) => {
    body += chunk.toString('utf8');
  });
  proxyRes.on('end', () => {
    try {
      const baseHref = guacamoleBasePath === '/'
        ? `/connect/${token}/`
        : `/connect/${token}${guacamoleBasePath.replace(/\/$/, '')}/`;

      if (!body.includes('<base ')) {
        body = body.replace(/<head([^>]*)>/i, `<head$1><base href="${baseHref}">`);
      }

      const escapedBase = guacamoleBasePath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      if (guacamoleBasePath === '/') {
        body = body.replace(/(<script[^>]+src=["'])\/([^"']+)(["'])/g, `$1/connect/${token}/$2$3`);
        body = body.replace(/(<link[^>]+href=["'])\/([^"']+)(["'])/g, `$1/connect/${token}/$2$3`);
        body = body.replace(/(<img[^>]+src=["'])\/([^"']+)(["'])/g, `$1/connect/${token}/$2$3`);
        body = body.replace(/(url\(["']?)\/([^"')]+)(["']?\))/g, `$1/connect/${token}/$2$3`);
        body = body.replace(/(["'])\/api\//g, `$1/connect/${token}/api/`);
      } else {
        body = body.replace(
          new RegExp(`(<script[^>]+src=["'])${escapedBase}([^"']+)(["'])`, 'g'),
          `$1/connect/${token}${guacamoleBasePath}$2$3`
        );
        body = body.replace(
          new RegExp(`(<link[^>]+href=["'])${escapedBase}([^"']+)(["'])`, 'g'),
          `$1/connect/${token}${guacamoleBasePath}$2$3`
        );
        body = body.replace(
          new RegExp(`(<img[^>]+src=["'])${escapedBase}([^"']+)(["'])`, 'g'),
          `$1/connect/${token}${guacamoleBasePath}$2$3`
        );
        body = body.replace(
          new RegExp(`(url\\(["']?)${escapedBase}([^"')]+)(["']?\\))`, 'g'),
          `$1/connect/${token}${guacamoleBasePath}$2$3`
        );
        body = body.replace(
          new RegExp(`(["'])${escapedBase}/api/`, 'g'),
          `$1/connect/${token}${guacamoleBasePath}/api/`
        );
      }
      body = body.replace(/(["'])\/guacamole\/api\//g, `$1/connect/${token}/guacamole/api/`);

      const buffer = Buffer.from(body, 'utf8');
      if (headers) {
        headers['content-length'] = buffer.length;
        res.writeHead(statusCode, headers);
      } else {
        res.setHeader('content-length', buffer.length);
      }
      res.end(buffer);
    } catch (error) {
      console.error('重寫 HTML 錯誤:', error);
      res.end(body);
    }
  });
}

// ============================================
// Token 驗證代理端點
// ============================================
const http = require('http');
const https = require('https');

// 統一處理所有 /connect/:token 的代理請求
app.all('/connect/:token*', async (req, res) => {
  const { token } = req.params;
  
  try {
    const request = await getValidRequestByToken(db, token);
    
    if (!request) {
      return res.status(403).send(generateErrorPage('無效的存取連結', '此連結無效或已失效。'));
    }

    // *** 關鍵修正 ***
    // 從原始 URL 中提取 token 後的所有路徑，包含查詢參數
    const prefix = `/connect/${token}`;
    let downstreamPath = req.originalUrl.substring(prefix.length);
    if (!downstreamPath.startsWith('/')) {
      downstreamPath = '/' + downstreamPath;
    }
    
    // 從 GUACAMOLE_URL 提取基礎路徑
    const guacamoleUrl = new URL(CONFIG.GUACAMOLE_URL);
    const guacamoleBasePath = guacamoleUrl.pathname.replace(/\/$/, '');
    const finalGuacamolePath = guacamoleBasePath + downstreamPath;
    
    const isRootRequest = downstreamPath === '/' || downstreamPath.startsWith('/?');
    if (isRootRequest) {
        console.log(`代理 HTTP 請求 (根): ${req.method} ${req.url} for ${request.name}`);
    }

    const options = {
      hostname: CONFIG.GUACAMOLE_HOST,
      port: CONFIG.GUACAMOLE_PORT,
      path: finalGuacamolePath,
      method: req.method,
      headers: {
        ...req.headers,
        host: `${CONFIG.GUACAMOLE_HOST}:${CONFIG.GUACAMOLE_PORT}`,
        'accept-encoding': 'identity' // 禁用壓縮以便修改 HTML
      },
      rejectUnauthorized: false
    };

    const httpModule = CONFIG.GUACAMOLE_PROTOCOL === 'https' ? https : http;
    const proxyReq = httpModule.request(options, (proxyRes) => {
      const responseHeaders = { ...proxyRes.headers };
      
      // 重寫 Location 頭
      if (responseHeaders.location) {
        try {
            const originalLocation = new URL(responseHeaders.location, CONFIG.GUACAMOLE_URL);
            const newPath = `/connect/${token}${originalLocation.pathname}${originalLocation.search}`;
            responseHeaders.location = new URL(newPath, CONFIG.BASE_URL).toString();
        } catch (e) {
            // 如果 location 是相對路徑
            responseHeaders.location = responseHeaders.location.replace(guacamoleBasePath, `/connect/${token}${guacamoleBasePath}`);
        }
      }
      
      // 如果是 HTML，則重寫內容
      const contentType = responseHeaders['content-type'] || '';
      if (contentType.includes('text/html')) {
        const bodyChunks = [];
        proxyRes.on('data', chunk => bodyChunks.push(chunk));
        proxyRes.on('end', () => {
          try {
            let html = Buffer.concat(bodyChunks).toString('utf8');
            
            // 插入 <base> 標籤
            const baseHref = `/connect/${token}${guacamoleBasePath}/`;
             if (html.includes('<head>')) {
                html = html.replace(/(<head[^>]*>)/, `$1<base href="${baseHref}">`);
            } else {
                html = `<html><head><base href="${baseHref}"></head>${html.replace('<html>','')}</html>`;
            }
            
            const modifiedBody = Buffer.from(html, 'utf8');

            delete responseHeaders['content-length'];
            delete responseHeaders['content-encoding'];
            delete responseHeaders['transfer-encoding'];
            
            if (!res.headersSent) {
                res.writeHead(proxyRes.statusCode, responseHeaders);
            }
            res.end(modifiedBody);

          } catch (err) {
            console.error('重寫 HTML 錯誤:', err);
            if (!res.headersSent) {
              res.writeHead(500);
              res.end('Proxy HTML rewrite error');
            }
          }
        });
      } else {
        // 非 HTML，直接 pipe
        if (!res.headersSent) {
          res.writeHead(proxyRes.statusCode, responseHeaders);
        }
        proxyRes.pipe(res);
      }
    });

    proxyReq.on('error', (err) => {
      console.error(`代理請求到 Guacamole 時發生錯誤: ${err.message}`);
      if (!res.headersSent) {
        res.status(502).send(generateErrorPage('連線錯誤', '無法連接到 Guacamole 伺服器。'));
      }
    });

    req.pipe(proxyReq);

  } catch (error) {
    console.error('代理處理錯誤:', error);
    if (!res.headersSent) {
      res.status(500).send(generateErrorPage('系統錯誤', '代理請求時發生內部錯誤。'));
    }
  }
});

const PORT = process.env.PORT || 3001;
const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`API Server running on http://0.0.0.0:${PORT}`);
});

// ============================================
// WebSocket 代理
// ============================================
const proxy = httpProxy.createProxyServer({
  changeOrigin: true,
  secure: false
});

proxy.on('error', (err, req, res) => {
    console.error('WebSocket 代理錯誤:', err.message);
    if (res.socket) {
        res.socket.destroy();
    }
});

server.on('upgrade', async function (req, socket, head) {
    try {
        const reqUrl = new url.URL(req.url, `http://${req.headers.host}`);
        const token = reqUrl.pathname.split('/')[2];

        if (!token) { throw new Error('請求缺少 token'); }
        
        const request = await getValidRequestByToken(db, token);

        if (!request) { throw new Error(`token 無效: ${token}`); }

        console.log(`代理 WebSocket for ${request.name}, url: ${req.url}`);

        const prefix = `/connect/${token}`;
        let downstreamPath = reqUrl.pathname.substring(prefix.length);
        if (!downstreamPath.startsWith('/')) {
            downstreamPath = '/' + downstreamPath;
        }
        
        const guacamoleUrl = new URL(CONFIG.GUACAMOLE_URL);
        const guacamoleBasePath = guacamoleUrl.pathname.replace(/\/$/, '');
        req.url = guacamoleBasePath + downstreamPath + reqUrl.search;
        
        proxy.ws(req, socket, head, { target: CONFIG.GUACAMOLE_URL });
    } catch (error) {
        console.error(`WebSocket 升級失敗: ${error.message}`);
        socket.destroy();
    }
});
SERVEREOF

# 安裝後端依賴
cd backend
echo -e "${CYAN}安裝後端依賴套件...${NC}"
echo -e "${YELLOW}注意: 如果看到 'deprecated' 警告，這些是 npm 內部依賴套件的警告，屬於正常現象，不影響功能運作${NC}"
npm install

# 自動修復安全漏洞（如果有）
echo -e "${YELLOW}檢查並修復安全漏洞...${NC}"
npm audit fix --force 2>/dev/null || true

# ============================================
# 建立前端
# ============================================
echo -e "${YELLOW}[5/8] 建立前端網頁...${NC}"
cd $INSTALL_DIR
mkdir -p frontend

cat > frontend/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-TW">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Guacamole 存取申請入口</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        .loading { animation: spin 1s linear infinite; }
        @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
    </style>
</head>
<body class="min-h-screen bg-gradient-to-br from-slate-900 to-slate-800">
    
    <!-- 首頁 -->
    <div id="home-page" class="min-h-screen flex items-center justify-center p-4">
        <div class="max-w-md w-full">
            <div class="text-center mb-8">
                <div class="inline-flex items-center justify-center w-20 h-20 bg-emerald-500 rounded-full mb-4">
                    <svg class="w-10 h-10 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"></path>
                    </svg>
                </div>
                <h1 class="text-3xl font-bold text-white mb-2">Guacamole 存取入口</h1>
                <p class="text-slate-400">Apache Guacamole 遠端連線申請系統</p>
            </div>
            
            <div class="bg-slate-800 rounded-xl p-6 shadow-xl">
                <p class="text-slate-300 mb-6 text-center">
                    如需使用遠端桌面連線服務，請提交存取申請。
                    管理員審核通過後，您將收到存取連結。
                </p>
                
                <button onclick="showRequestForm()" class="w-full bg-emerald-500 hover:bg-emerald-600 text-white font-semibold py-3 px-4 rounded-lg transition-colors flex items-center justify-center gap-2">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8"></path>
                    </svg>
                    申請存取權限
                </button>
            </div>
        </div>
    </div>

    <!-- 申請表單 -->
    <div id="request-page" class="min-h-screen flex items-center justify-center p-4" style="display: none;">
        <div class="max-w-md w-full">
            <button onclick="showHome()" class="text-slate-400 hover:text-white mb-4 flex items-center gap-1">
                ← 返回
            </button>
            
            <div class="bg-slate-800 rounded-xl p-6 shadow-xl">
                <h2 class="text-2xl font-bold text-white mb-6 text-center">申請存取權限</h2>
                
                <form id="request-form" onsubmit="submitRequest(event)" class="space-y-4">
                    <div>
                        <label class="block text-slate-300 text-sm mb-1">姓名 *</label>
                        <input type="text" id="name" required 
                            class="w-full bg-slate-700 border border-slate-600 rounded-lg px-4 py-2 text-white focus:outline-none focus:border-emerald-500"
                            placeholder="請輸入您的姓名">
                    </div>

                    <div>
                        <label class="block text-slate-300 text-sm mb-1">電子郵件 *</label>
                        <input type="email" id="email" required 
                            class="w-full bg-slate-700 border border-slate-600 rounded-lg px-4 py-2 text-white focus:outline-none focus:border-emerald-500"
                            placeholder="your@email.com">
                    </div>

                    <div>
                        <label class="block text-slate-300 text-sm mb-1">部門 or 公司</label>
                        <input type="text" id="department" 
                            class="w-full bg-slate-700 border border-slate-600 rounded-lg px-4 py-2 text-white focus:outline-none focus:border-emerald-500"
                            placeholder="您的部門 or 公司（選填）">
                    </div>

                    <div>
                        <label class="block text-slate-300 text-sm mb-1">申請原因 *</label>
                        <textarea id="reason" required 
                            class="w-full bg-slate-700 border border-slate-600 rounded-lg px-4 py-2 text-white focus:outline-none focus:border-emerald-500 h-24 resize-none"
                            placeholder="請說明您需要連線的原因..."></textarea>
                    </div>

                    <div id="error-message" class="bg-red-500/20 border border-red-500 rounded-lg p-3 text-red-400 text-sm" style="display: none;"></div>

                    <button type="submit" id="submit-btn" class="w-full bg-emerald-500 hover:bg-emerald-600 text-white font-semibold py-3 px-4 rounded-lg transition-colors flex items-center justify-center gap-2">
                        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8"></path>
                        </svg>
                        提交申請
                    </button>
                </form>
            </div>
        </div>
    </div>

    <!-- 成功頁面 -->
    <div id="success-page" class="min-h-screen flex items-center justify-center p-4" style="display: none;">
        <div class="max-w-md w-full bg-slate-800 rounded-xl p-8 text-center">
            <div class="inline-flex items-center justify-center w-16 h-16 bg-emerald-500 rounded-full mb-4">
                <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path>
                </svg>
            </div>
            <h2 class="text-2xl font-bold text-white mb-2">申請已提交</h2>
            <p class="text-slate-400 mb-4" id="success-message"></p>
            <div class="bg-slate-700 rounded-lg p-4 mb-6">
                <p class="text-slate-400 text-sm">申請編號</p>
                <p class="text-emerald-400 font-mono text-lg" id="request-id"></p>
            </div>
            <p class="text-slate-500 text-sm mb-6">
                請查收確認郵件，審核結果將透過電子郵件通知您
            </p>
            <button onclick="showHome()" class="text-emerald-400 hover:text-emerald-300">
                返回首頁
            </button>
        </div>
    </div>

    <!-- 存取頁面 -->
    <div id="access-page" class="min-h-screen flex items-center justify-center p-4" style="display: none;">
        <div id="access-content" class="max-w-md w-full bg-slate-800 rounded-xl p-8 text-center">
        </div>
    </div>


    <script>
        // API URL - 智能偵測
        const isStandardPort = window.location.port === '' || window.location.port === '80' || window.location.port === '443';
        const API_BASE = isStandardPort 
            ? window.location.origin
            : window.location.protocol + '//' + window.location.hostname + ':3001';
        const API_URL = API_BASE + '/api';

        function hideAllPages() {
            document.getElementById('home-page').style.display = 'none';
            document.getElementById('request-page').style.display = 'none';
            document.getElementById('success-page').style.display = 'none';
            document.getElementById('access-page').style.display = 'none';
        }

        function showHome() {
            hideAllPages();
            document.getElementById('home-page').style.display = 'flex';
            // 清除URL hash
            history.replaceState(null, null, window.location.pathname);
        }


        function showRequestForm() {
            hideAllPages();
            document.getElementById('request-page').style.display = 'flex';
            document.getElementById('error-message').style.display = 'none';
        }

        function showSuccess(message, requestId) {
            hideAllPages();
            document.getElementById('success-message').textContent = message;
            document.getElementById('request-id').textContent = requestId;
            document.getElementById('success-page').style.display = 'flex';
        }

        async function submitRequest(event) {
            event.preventDefault();
            
            const submitBtn = document.getElementById('submit-btn');
            const errorDiv = document.getElementById('error-message');
            
            submitBtn.disabled = true;
            submitBtn.innerHTML = '<svg class="w-5 h-5 loading" fill="none" stroke="currentColor" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" stroke-width="4" stroke-dasharray="30 60"></circle></svg> 提交中...';
            errorDiv.style.display = 'none';

            const formData = {
                name: document.getElementById('name').value,
                email: document.getElementById('email').value,
                department: document.getElementById('department').value,
                reason: document.getElementById('reason').value
            };

            try {
                const response = await fetch(API_URL + '/request-access', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(formData)
                });

                const data = await response.json();

                if (response.ok) {
                    showSuccess(data.message, data.requestId);
                    document.getElementById('request-form').reset();
                } else {
                    throw new Error(data.error || '提交失敗');
                }
            } catch (error) {
                let errorMsg = error.message;
                if (error.message === 'Failed to fetch') {
                    errorMsg = '無法連接到伺服器 (' + API_URL + ')。請確認後端 API 已啟動。';
                }
                errorDiv.textContent = errorMsg;
                errorDiv.style.display = 'block';
            } finally {
                submitBtn.disabled = false;
                submitBtn.innerHTML = '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8"></path></svg> 提交申請';
            }
        }


        async function verifyAccess(token) {
            hideAllPages();
            document.getElementById('access-page').style.display = 'flex';
            
            const contentDiv = document.getElementById('access-content');
            contentDiv.innerHTML = '<div class="text-center"><svg class="w-12 h-12 text-emerald-500 loading mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" stroke-width="4" stroke-dasharray="30 60"></circle></svg><p class="text-white">驗證存取權限中...</p></div>';

            try {
                const response = await fetch(API_URL + '/verify-access/' + token);
                const data = await response.json();

                if (data.valid) {
                    let countdown = 3;
                    contentDiv.innerHTML = `
                        <div class="inline-flex items-center justify-center w-16 h-16 bg-emerald-500 rounded-full mb-4">
                            <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path>
                            </svg>
                        </div>
                        <h2 class="text-2xl font-bold text-white mb-2">存取已授權</h2>
                        <p class="text-slate-400 mb-2">歡迎，${data.name}</p>
                        <p class="text-slate-500 text-sm mb-4">
                            有效期限：${new Date(data.expiresAt).toLocaleString('zh-TW')}
                        </p>
                        <p class="text-emerald-400 text-lg mb-4">
                            <span id="countdown">${countdown}</span> 秒後自動跳轉到 Guacamole...
                        </p>
                        <a href="${data.guacamoleUrl}" 
                           class="inline-flex items-center gap-2 bg-emerald-500 hover:bg-emerald-600 text-white font-semibold py-3 px-6 rounded-lg transition-colors">
                            立即進入
                        </a>
                    `;
                    
                    // 倒數計時並自動跳轉
                    const countdownInterval = setInterval(() => {
                        countdown--;
                        const countdownEl = document.getElementById('countdown');
                        if (countdownEl) {
                            countdownEl.textContent = countdown;
                        }
                        if (countdown <= 0) {
                            clearInterval(countdownInterval);
                            window.location.href = data.guacamoleUrl;
                        }
                    }, 1000);
                } else {
                    contentDiv.innerHTML = `
                        <div class="inline-flex items-center justify-center w-16 h-16 bg-red-500 rounded-full mb-4">
                            <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
                            </svg>
                        </div>
                        <h2 class="text-2xl font-bold text-white mb-2">無法存取</h2>
                        <p class="text-slate-400 mb-6">${data.error}</p>
                        <button onclick="showHome()" class="text-emerald-400 hover:text-emerald-300">
                            重新申請存取權限
                        </button>
                    `;
                }
            } catch (error) {
                contentDiv.innerHTML = `
                    <div class="inline-flex items-center justify-center w-16 h-16 bg-red-500 rounded-full mb-4">
                        <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
                        </svg>
                    </div>
                    <h2 class="text-2xl font-bold text-white mb-2">驗證失敗</h2>
                    <p class="text-slate-400 mb-6">無法連接到伺服器</p>
                    <button onclick="showHome()" class="text-emerald-400 hover:text-emerald-300">
                        返回首頁
                    </button>
                `;
            }
        }

        window.onload = function() {
            const hash = window.location.hash;
            if (hash && hash.includes('access/')) {
                const token = hash.split('access/')[1];
                verifyAccess(token);
            } else {
                showHome();
            }
        };

    </script>
</body>
</html>
EOF

# 建立管理員專用頁面
cat > frontend/admin.html << 'ADMINEOF'
<!DOCTYPE html>
<html lang="zh-TW">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>管理員面板 - Guacamole 存取管理系統</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        .loading { animation: spin 1s linear infinite; }
        @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
    </style>
</head>
<body class="bg-slate-900 min-h-screen">
    <!-- 登入頁面 -->
    <div id="login-page" class="min-h-screen flex items-center justify-center p-4" style="display: none;">
        <div class="max-w-md w-full">
            <div class="bg-slate-800 rounded-xl p-6 shadow-xl">
                <h2 class="text-2xl font-bold text-white mb-6 text-center">管理員登入</h2>

                <form id="admin-login-form" onsubmit="adminLogin(event)" class="space-y-4">
                    <div>
                        <label class="block text-slate-300 text-sm mb-1">管理員密碼</label>
                        <input type="password" id="admin-password" required
                            class="w-full bg-slate-700 border border-slate-600 rounded-lg px-4 py-2 text-white focus:outline-none focus:border-emerald-500"
                            placeholder="請輸入管理員密碼">
                    </div>

                    <div id="admin-login-error" class="bg-red-500/20 border border-red-500 rounded-lg p-3 text-red-400 text-sm" style="display: none;"></div>

                    <button type="submit" id="admin-login-btn" class="w-full bg-emerald-500 hover:bg-emerald-600 text-white font-semibold py-3 px-4 rounded-lg transition-colors flex items-center justify-center gap-2">
                        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"></path>
                        </svg>
                        登入
                    </button>
                </form>
            </div>
        </div>
    </div>

    <!-- 管理員面板 -->
    <div id="admin-panel" class="min-h-screen bg-slate-900 p-4" style="display: none;">
        <div class="max-w-7xl mx-auto">
            <!-- 頁首 -->
            <div class="bg-slate-800 rounded-xl p-6 mb-6">
                <div class="flex justify-between items-center">
                    <div>
                        <h1 class="text-2xl font-bold text-white mb-2">管理員面板</h1>
                        <p class="text-slate-400">Guacamole 存取申請管理系統</p>
                    </div>
                    <div class="flex gap-3">
                        <button onclick="refreshRequests()" class="bg-blue-500 hover:bg-blue-600 text-white px-4 py-2 rounded-lg flex items-center gap-2">
                            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path>
                            </svg>
                            重新整理
                        </button>
                        <button onclick="exportRequests()" class="bg-green-500 hover:bg-green-600 text-white px-4 py-2 rounded-lg flex items-center gap-2">
                            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 10v6m0 0l-3-3m3 3l3-3m2 8H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"></path>
                            </svg>
                            匯出 CSV
                        </button>
                        <button onclick="adminLogout()" class="bg-red-500 hover:bg-red-600 text-white px-4 py-2 rounded-lg">
                            登出
                        </button>
                    </div>
                </div>
            </div>

            <!-- 統計卡片 -->
            <div class="grid grid-cols-1 md:grid-cols-4 gap-6 mb-6">
                <div class="bg-slate-800 rounded-xl p-6">
                    <div class="flex items-center justify-between">
                        <div>
                            <p class="text-slate-400 text-sm">總申請數</p>
                            <p class="text-2xl font-bold text-white" id="total-count">0</p>
                        </div>
                        <div class="bg-blue-500 p-3 rounded-lg">
                            <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"></path>
                            </svg>
                        </div>
                    </div>
                </div>
                <div class="bg-slate-800 rounded-xl p-6">
                    <div class="flex items-center justify-between">
                        <div>
                            <p class="text-slate-400 text-sm">待審核</p>
                            <p class="text-2xl font-bold text-yellow-400" id="pending-count">0</p>
                        </div>
                        <div class="bg-yellow-500 p-3 rounded-lg">
                            <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                            </svg>
                        </div>
                    </div>
                </div>
                <div class="bg-slate-800 rounded-xl p-6">
                    <div class="flex items-center justify-between">
                        <div>
                            <p class="text-slate-400 text-sm">已核准</p>
                            <p class="text-2xl font-bold text-green-400" id="approved-count">0</p>
                        </div>
                        <div class="bg-green-500 p-3 rounded-lg">
                            <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path>
                            </svg>
                        </div>
                    </div>
                </div>
                <div class="bg-slate-800 rounded-xl p-6">
                    <div class="flex items-center justify-between">
                        <div>
                            <p class="text-slate-400 text-sm">已拒絕</p>
                            <p class="text-2xl font-bold text-red-400" id="rejected-count">0</p>
                        </div>
                        <div class="bg-red-500 p-3 rounded-lg">
                            <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
                            </svg>
                        </div>
                    </div>
                </div>
            </div>

            <!-- 篩選器 -->
            <div class="bg-slate-800 rounded-xl p-6 mb-6">
                <h3 class="text-lg font-semibold text-white mb-4">篩選條件</h3>
                <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
                    <div>
                        <label class="block text-slate-300 text-sm mb-2">狀態</label>
                        <select id="filter-status" onchange="applyFilters()" class="w-full bg-slate-700 border border-slate-600 rounded-lg px-3 py-2 text-white focus:outline-none focus:border-emerald-500">
                            <option value="all">全部</option>
                            <option value="pending">待審核</option>
                            <option value="approved">已核准</option>
                            <option value="rejected">已拒絕</option>
                        </select>
                    </div>
                    <div>
                        <label class="block text-slate-300 text-sm mb-2">電子郵件</label>
                        <input type="text" id="filter-email" oninput="applyFilters()" placeholder="搜尋電子郵件" class="w-full bg-slate-700 border border-slate-600 rounded-lg px-3 py-2 text-white focus:outline-none focus:border-emerald-500">
                    </div>
                    <div>
                        <label class="block text-slate-300 text-sm mb-2">開始日期</label>
                        <input type="date" id="filter-date-from" onchange="applyFilters()" class="w-full bg-slate-700 border border-slate-600 rounded-lg px-3 py-2 text-white focus:outline-none focus:border-emerald-500">
                    </div>
                    <div>
                        <label class="block text-slate-300 text-sm mb-2">結束日期</label>
                        <input type="date" id="filter-date-to" onchange="applyFilters()" class="w-full bg-slate-700 border border-slate-600 rounded-lg px-3 py-2 text-white focus:outline-none focus:border-emerald-500">
                    </div>
                </div>
            </div>

            <!-- 申請記錄列表 -->
            <div class="bg-slate-800 rounded-xl overflow-hidden">
                <div class="px-6 py-4 border-b border-slate-700">
                    <h3 class="text-lg font-semibold text-white">申請記錄</h3>
                </div>
                <div class="overflow-x-auto">
                    <table class="w-full">
                        <thead class="bg-slate-700">
                            <tr>
                                <th class="px-6 py-3 text-left text-xs font-medium text-slate-300 uppercase tracking-wider">申請資訊</th>
                                <th class="px-6 py-3 text-left text-xs font-medium text-slate-300 uppercase tracking-wider">狀態</th>
                                <th class="px-6 py-3 text-left text-xs font-medium text-slate-300 uppercase tracking-wider">時間</th>
                                <th class="px-6 py-3 text-left text-xs font-medium text-slate-300 uppercase tracking-wider">時長</th>
                            </tr>
                        </thead>
                        <tbody id="requests-table-body" class="bg-slate-800 divide-y divide-slate-700">
                            <!-- 記錄將動態插入這裡 -->
                        </tbody>
                    </table>
                </div>
                <div id="loading-indicator" class="px-6 py-4 text-center text-slate-400" style="display: none;">
                    載入中...
                </div>
                <div id="no-data-indicator" class="px-6 py-4 text-center text-slate-400" style="display: none;">
                    沒有符合條件的記錄
                </div>
            </div>
        </div>
    </div>

    <script>
        // API URL - 智能偵測
        const isStandardPort = window.location.port === '' || window.location.port === '80' || window.location.port === '443';
        const API_BASE = isStandardPort
            ? window.location.origin
            : window.location.protocol + '//' + window.location.hostname + ':3001';
        const API_URL = API_BASE + '/api';

        // 立即初始化頁面顯示狀態（在 DOM 載入前執行）
        (function() {
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', initPageState);
            } else {
                initPageState();
            }
        })();

        function initPageState() {
            const loginPage = document.getElementById('login-page');
            const adminPanel = document.getElementById('admin-panel');
            
            // 確保 DOM 元素已載入
            if (!loginPage || !adminPanel) {
                return;
            }
            
            const isLoggedIn = localStorage.getItem('admin_logged_in') === 'true';
            const token = localStorage.getItem('admin_token');
            
            if (isLoggedIn && token) {
                loginPage.style.display = 'none';
                adminPanel.style.display = 'block';
            } else {
                loginPage.style.display = 'flex';
                adminPanel.style.display = 'none';
                // 清除無效的登入狀態
                localStorage.removeItem('admin_logged_in');
                localStorage.removeItem('admin_token');
            }
        }

        function hideAllPages() {
            document.getElementById('login-page').style.display = 'none';
            document.getElementById('admin-panel').style.display = 'none';
        }

        function showLoginPage() {
            hideAllPages();
            document.getElementById('login-page').style.display = 'flex';
            document.getElementById('admin-login-error').style.display = 'none';
        }

        function showAdminPanel() {
            const token = localStorage.getItem('admin_token');
            if (!token) {
                adminLogout();
                return;
            }
            hideAllPages();
            document.getElementById('admin-panel').style.display = 'block';
            loadRequests();
        }

        // 管理員功能
        async function adminLogin(event) {
            event.preventDefault();

            const password = document.getElementById('admin-password').value;
            const loginBtn = document.getElementById('admin-login-btn');
            const errorDiv = document.getElementById('admin-login-error');

            loginBtn.disabled = true;
            loginBtn.innerHTML = '<svg class="w-5 h-5 loading" fill="none" stroke="currentColor" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" stroke-width="4" stroke-dasharray="30 60"></circle></svg> 驗證中...';
            errorDiv.style.display = 'none';

            try {
                const response = await fetch(API_URL + '/admin/login', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ password })
                });

                const data = await response.json();

                if (response.ok && data.success) {
                    localStorage.setItem('admin_token', data.token);
                    localStorage.setItem('admin_logged_in', 'true');
                    showAdminPanel();
                } else {
                    throw new Error(data.error || '登入失敗');
                }
            } catch (error) {
                let errorMsg = error.message;
                if (error.message === 'Failed to fetch') {
                    errorMsg = '無法連接到伺服器 (' + API_URL + '/admin/login)。請確認後端 API 已啟動。';
                }
                errorDiv.textContent = errorMsg;
                errorDiv.style.display = 'block';
            } finally {
                loginBtn.disabled = false;
                loginBtn.innerHTML = '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"></path></svg> 登入';
            }
        }

        function adminLogout() {
            localStorage.removeItem('admin_logged_in');
            localStorage.removeItem('admin_token');
            showLoginPage();
        }

        let currentFilters = {};

        async function loadRequests() {
            const tableBody = document.getElementById('requests-table-body');
            const loadingIndicator = document.getElementById('loading-indicator');
            const noDataIndicator = document.getElementById('no-data-indicator');

            loadingIndicator.style.display = 'block';
            noDataIndicator.style.display = 'none';
            tableBody.innerHTML = '';

            try {
                const params = new URLSearchParams(currentFilters);
                const token = localStorage.getItem('admin_token');

                if (!token) {
                    adminLogout();
                    return;
                }

                const response = await fetch(API_URL + '/admin/requests?' + params, {
                    headers: {
                        'X-Admin-Token': token
                    }
                });

                if (response.status === 401) {
                    localStorage.removeItem('admin_logged_in');
                    localStorage.removeItem('admin_token');
                    showLoginPage();
                    return;
                }

                if (!response.ok) {
                    throw new Error(`HTTP ${response.status}: ${response.statusText}`);
                }

                const data = await response.json();

                if (data && data.requests && data.stats) {
                    updateStats(data.stats);
                    renderRequests(data.requests);
                } else {
                    throw new Error('無效的響應格式');
                }
            } catch (error) {
                // 只在非認證錯誤時顯示錯誤訊息
                if (error.message && !error.message.includes('401')) {
                    tableBody.innerHTML = '<tr><td colspan="4" class="px-6 py-4 text-center text-red-400">載入失敗: ' + error.message + '</td></tr>';
                }
            } finally {
                loadingIndicator.style.display = 'none';
            }
        }

        function updateStats(stats) {
            if (!stats) {
                console.warn('統計數據為空');
                return;
            }

            const totalEl = document.getElementById('total-count');
            const pendingEl = document.getElementById('pending-count');
            const approvedEl = document.getElementById('approved-count');
            const rejectedEl = document.getElementById('rejected-count');

            if (totalEl) totalEl.textContent = stats.total_count || 0;
            if (pendingEl) pendingEl.textContent = stats.pending_count || 0;
            if (approvedEl) approvedEl.textContent = stats.approved_count || 0;
            if (rejectedEl) rejectedEl.textContent = stats.rejected_count || 0;
        }

        function renderRequests(requests) {
            const tableBody = document.getElementById('requests-table-body');
            const noDataIndicator = document.getElementById('no-data-indicator');

            if (!tableBody || !noDataIndicator) {
                console.error('無法找到表格元素');
                return;
            }

            if (!requests || !Array.isArray(requests) || requests.length === 0) {
                noDataIndicator.style.display = 'block';
                tableBody.innerHTML = '';
                return;
            }

            noDataIndicator.style.display = 'none';
            tableBody.innerHTML = '';

            requests.forEach(request => {
                if (!request) return;

                try {
                    const row = document.createElement('tr');
                    row.className = 'hover:bg-slate-700';

                    const statusColors = {
                        'pending': 'bg-yellow-500',
                        'approved': 'bg-green-500',
                        'rejected': 'bg-red-500'
                    };

                    const statusText = {
                        'pending': '待審核',
                        'approved': '已核准',
                        'rejected': '已拒絕'
                    };

                    const safeName = (request.name || '').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                    const safeEmail = (request.email || '').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                    const safeDepartment = (request.department || '未提供部門').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                    const safeReason = (request.reason || '').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
                    
                    let createdDate = '未知';
                    let approvedDate = '尚未處理';
                    let expiresDate = '無';

                    try {
                        if (request.created_at) {
                            createdDate = new Date(request.created_at).toLocaleString('zh-TW');
                        }
                    } catch (e) {
                        console.warn('無法解析申請時間:', request.created_at);
                    }

                    try {
                        if (request.approved_at) {
                            approvedDate = new Date(request.approved_at).toLocaleString('zh-TW');
                        }
                    } catch (e) {
                        console.warn('無法解析處理時間:', request.approved_at);
                    }

                    try {
                        if (request.expires_at) {
                            expiresDate = new Date(request.expires_at).toLocaleString('zh-TW');
                        }
                    } catch (e) {
                        console.warn('無法解析到期時間:', request.expires_at);
                    }

                    const status = request.status || 'pending';
                    const statusColor = statusColors[status] || 'bg-gray-500';
                    const statusLabel = statusText[status] || status;

                    row.innerHTML = `
                        <td class="px-6 py-4">
                            <div class="text-sm font-medium text-white">${safeName}</div>
                            <div class="text-sm text-slate-400">${safeEmail}</div>
                            <div class="text-sm text-slate-500 mt-1">${safeDepartment}</div>
                            <div class="text-sm text-slate-500 mt-1 max-w-xs truncate" title="${safeReason}">${safeReason}</div>
                        </td>
                        <td class="px-6 py-4">
                            <span class="inline-flex px-2 py-1 text-xs font-semibold rounded-full ${statusColor} text-white">
                                ${statusLabel}
                            </span>
                        </td>
                        <td class="px-6 py-4 text-sm text-slate-300">
                            <div>申請: ${createdDate}</div>
                            <div>處理: ${approvedDate}</div>
                        </td>
                        <td class="px-6 py-4 text-sm text-slate-300">
                            ${request.duration_hours ? request.duration_hours + ' 小時' : '未設定'}
                            <div class="text-xs text-slate-500">到期: ${expiresDate}</div>
                        </td>
                    `;

                    tableBody.appendChild(row);
                } catch (error) {
                    console.error('渲染申請記錄時發生錯誤:', error, request);
                }
            });
        }

        function applyFilters() {
            currentFilters = {
                status: document.getElementById('filter-status').value,
                email: document.getElementById('filter-email').value.trim(),
                date_from: document.getElementById('filter-date-from').value,
                date_to: document.getElementById('filter-date-to').value
            };

            // 移除空的篩選條件
            Object.keys(currentFilters).forEach(key => {
                if (!currentFilters[key]) {
                    delete currentFilters[key];
                }
            });

            loadRequests();
        }

        function refreshRequests() {
            loadRequests();
        }

        function exportRequests() {
            const params = new URLSearchParams(currentFilters);
            const token = localStorage.getItem('admin_token');

            if (!token) {
                alert('請重新登入');
                adminLogout();
                return;
            }

            params.append('token', token);
            const exportUrl = API_URL + '/admin/requests/export?' + params;

            // 建立一個臨時的 <a> 元素來觸發下載
            const link = document.createElement('a');
            link.href = exportUrl;
            link.setAttribute('download', 'guacamole-access-requests.csv');
            link.style.display = 'none';
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
        }

        // 頁面載入時檢查登入狀態（使用 DOMContentLoaded 以更快執行）
        document.addEventListener('DOMContentLoaded', function() {
            const isLoggedIn = localStorage.getItem('admin_logged_in') === 'true';
            const token = localStorage.getItem('admin_token');

            if (isLoggedIn && token) {
                showAdminPanel();
            } else {
                // 清除無效的登入狀態
                localStorage.removeItem('admin_logged_in');
                localStorage.removeItem('admin_token');
                showLoginPage();
            }
        });
    </script>
</body>
</html>
ADMINEOF

# 建立前端 package.json
cat > frontend/package.json << 'EOF'
{
  "name": "guacamole-portal-frontend",
  "version": "1.1.0",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "compression": "^1.7.4",
    "express": "^4.21.2",
    "http-proxy-middleware": "^3.0.3"
  }
}
EOF

cat > frontend/server.js << 'EOF'
const path = require('path');
const express = require('express');
const compression = require('compression');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();
const PORT = process.env.PORT || 3000;
const STATIC_DIR = process.env.STATIC_DIR || path.join(__dirname);
const API_PROXY_TARGET = process.env.API_PROXY_TARGET || 'http://localhost:3001';

console.log('============================================');
console.log('Guacamole Portal Frontend Server');
console.log('============================================');
console.log('Port:', PORT);
console.log('Static Dir:', STATIC_DIR);
console.log('API Proxy Target:', API_PROXY_TARGET);
console.log('============================================');

app.use(compression());

// Proxy API requests
app.use('/api', createProxyMiddleware({
  target: API_PROXY_TARGET,
  changeOrigin: true,
  logLevel: 'warn'
}));

// Proxy connect requests
app.use('/connect', createProxyMiddleware({
  target: API_PROXY_TARGET,
  changeOrigin: true,
  logLevel: 'warn'
}));

app.use(express.static(STATIC_DIR));

// 管理員頁面路由
app.get('/admin', (req, res) => {
  res.sendFile(path.join(STATIC_DIR, 'admin.html'));
});

app.get('*', (req, res) => {
  res.sendFile(path.join(STATIC_DIR, 'index.html'));
});

app.listen(PORT, () => {
  console.log(`Frontend server running on http://0.0.0.0:${PORT}`);
});
EOF

cd frontend
echo -e "${CYAN}安裝前端依賴套件...${NC}"
echo -e "${YELLOW}注意: 如果看到 'deprecated' 警告，這些是 npm 內部依賴套件的警告，屬於正常現象，不影響功能運作${NC}"
npm install

# ============================================
# 建立 PM2 配置
# ============================================
echo -e "${YELLOW}[6/8] 配置 PM2 服務...${NC}"
cd $INSTALL_DIR

# 建立安全的環境變數檔案（僅 root 可讀）
cat > backend/.env << EOF
PORT=$BACKEND_PORT
NODE_ENV=production
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_USER=$SMTP_USER
SMTP_PASS=$SMTP_PASS
ADMIN_EMAIL=$ADMIN_EMAIL
ADMIN_PASSWORD=$ADMIN_PASSWORD
BASE_URL=$BASE_URL
API_URL=$API_URL
GUACAMOLE_URL=$GUACAMOLE_URL
GUACAMOLE_HOST=$GUACAMOLE_HOST
GUACAMOLE_PORT=$GUACAMOLE_PORT
EOF

# 設置 .env 檔案權限（僅 root 可讀寫）
chmod 600 backend/.env
chown root:root backend/.env

# 建立 PM2 配置（不包含敏感資訊，SMTP_PASS 從 .env 檔案讀取）
cat > ecosystem.config.js << EOF
module.exports = {
  apps: [
    {
      name: 'guacamole-api',
      cwd: '$INSTALL_DIR/backend',
      script: 'server.js',
      env: {
        PORT: $BACKEND_PORT,
        NODE_ENV: 'production',
        SMTP_HOST: '$SMTP_HOST',
        SMTP_PORT: '$SMTP_PORT',
        SMTP_USER: '$SMTP_USER',
        SMTP_PASS: '$SMTP_PASS',
        ADMIN_EMAIL: '$ADMIN_EMAIL',
        ADMIN_PASSWORD: '$ADMIN_PASSWORD',
        BASE_URL: '$BASE_URL',
        API_URL: '$API_URL',
        GUACAMOLE_URL: '$GUACAMOLE_URL',
        GUACAMOLE_HOST: '$GUACAMOLE_HOST',
        GUACAMOLE_PORT: '$GUACAMOLE_PORT'
      }
    },
    {
      name: 'guacamole-frontend',
      cwd: '$INSTALL_DIR/frontend',
      script: 'server.js',
      env: {
        NODE_ENV: 'production',
        PORT: $FRONTEND_PORT,
        STATIC_DIR: '$INSTALL_DIR/frontend',
        API_PROXY_TARGET: 'http://localhost:$BACKEND_PORT'
      }
    }
  ]
};
EOF

# ============================================
# 啟動服務
# ============================================
echo -e "${YELLOW}[7/8] 啟動服務...${NC}"
pm2 delete all 2>/dev/null || true
pm2 start ecosystem.config.js
pm2 save
pm2 startup systemd -u root --hp /root 2>/dev/null || true

# ============================================
# 開放防火牆
# ============================================
echo -e "${YELLOW}[8/8] 設定防火牆...${NC}"
if command -v ufw &> /dev/null; then
    ufw allow $FRONTEND_PORT/tcp 2>/dev/null || true
    ufw allow $BACKEND_PORT/tcp 2>/dev/null || true
fi

# ============================================
# 完成
# ============================================
echo ""
echo -e "${GREEN}============================================"
echo "  部署完成！"
echo "============================================${NC}"
echo ""
echo -e "前端網頁: ${CYAN}$BASE_URL${NC}"
echo -e "後端 API: ${CYAN}$API_URL${NC}"
echo -e "Guacamole: ${CYAN}$GUACAMOLE_URL${NC}"
echo ""
echo "管理指令："
echo "  pm2 list          - 查看服務狀態"
echo "  pm2 logs          - 查看日誌"
echo "  pm2 restart all   - 重啟所有服務"
echo "  pm2 stop all      - 停止所有服務"
echo ""
echo "測試郵件："
echo "  curl $API_URL/api/test-email/your@email.com"
echo ""
echo -e "${YELLOW}管理員功能：${NC}"
echo "  管理員登入網址: $BASE_URL/admin"
echo "  管理員可查看所有申請記錄、篩選查詢、匯出 CSV 報告"
echo ""
echo -e "${YELLOW}安全性提示：${NC}"
if [ -n "$SMTP_PASS" ]; then
    echo "  SMTP 密碼已安全存儲在: $INSTALL_DIR/backend/.env"
else
    echo "  SMTP 使用匿名連線（未設置密碼）"
fi
echo "  管理員密碼已安全存儲在: $INSTALL_DIR/backend/.env"
echo "  這些檔案權限已設置為僅 root 可讀寫（600）"
echo "  請勿將這些檔案分享或提交到版本控制系統"
echo ""
echo -e "${GREEN}部署成功！請開啟 $BASE_URL 測試${NC}"
echo ""
