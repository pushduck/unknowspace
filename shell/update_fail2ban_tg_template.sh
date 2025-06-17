#!/bin/bash

# 定义目标文件路径
TARGET_FILE="/etc/fail2ban/action.d/telegram-notify.sh"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ 错误：此脚本需要以 root 或 sudo 权限运行。${NC}"
        exit 1
    fi
}

check_root

# 检查是否传入了两个必需的参数
if [ "$#" -ne 2 ]; then
    echo "❌ 错误: 参数不足。"
    echo "用法: sudo $0 <你的BOT_TOKEN> <你的CHAT_ID>"
    echo "示例: sudo $0 \"12345:ABC-DEF\" \"-100123456789\""
    exit 1
fi

# 从命令行参数获取 BOT_TOKEN 和 CHAT_ID
BOT_TOKEN="$1"
CHAT_ID="$2"

echo "准备更新 Fail2Ban 的 Telegram 通知脚本..."

# 使用 cat 和 here document (heredoc) 将新脚本内容写入目标文件
# 使用 'EOF' 可以防止本地shell变量扩展，确保文件内容原样写入
# 使用 sudo tee 命令可以正确处理需要root权限的文件写入操作
tee "$TARGET_FILE" > /dev/null << 'EOF'
#!/bin/bash

# --- Script Logic ---
IP="$1"
JAIL="$2"
PROTOCOL="$3"
PORT="$4"
HOSTNAME=$(hostname -f)
LOG_DATE=$(date)

# 查询 whois 信息
WHOIS_INFO=$(whois $IP | grep -E "Country|OrgName|City|StateProv" | tr '\n' '; ')
# 查询 GeoIP 信息
GEOIP_INFO=$(geoiplookup $IP | grep "GeoIP City" | awk -F": " '{print $2}')

# Message formatting for Markdown
MESSAGE="🤖主机名: \`${HOSTNAME}\`
-------------------------------
*🚫禁止IP:* ${IP}
*服务名称:* ${JAIL}
-------------------------------
*Whois:* ${WHOIS_INFO}
*GeoIP:* ${GEOIP_INFO}
-------------------------------
${LOG_DATE}
_本消息由 Fail2Ban 自动发送_"

# API URL
URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

# Send the message using curl, with Markdown parsing
curl -s --max-time 15 -X POST "${URL}" \
    -d "chat_id=${CHAT_ID}" \
    -d "text=${MESSAGE}" \
    -d "parse_mode=Markdown" > /dev/null
EOF

# 检查文件是否成功写入
if [ $? -eq 0 ]; then
    echo "✅ 文件 ${TARGET_FILE} 已成功更新。"
else
    echo "❌ 错误：文件写入失败！"
    exit 1
fi

echo "设置文件为可执行权限..."
chmod +x "$TARGET_FILE"

echo "正在重启 fail2ban 服务..."
systemctl restart fail2ban

# 等待几秒钟，让服务有时间重启
echo "等待 3 秒钟以确保服务稳定..."
sleep 3

echo "--------------------------------------------------"
echo "检查 fail2ban 服务状态："
# 执行 status 命令，--no-pager 会直接输出所有状态信息，而不是在 less 中打开
systemctl status fail2ban --no-pager
echo "--------------------------------------------------"

echo "✅ 操作完成。"
