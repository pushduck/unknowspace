#!/bin/bash

# =================================================================
# Fail2ban 智能管理脚本
# Author: Gemini
# Version: 2.3
#
# 更新日志 (v2.3):
# - 新增: 配置 Telegram Bot 通知功能 (菜单选项 8)。
#
# 更新日志 (v2.2):
# - 新增: 修改核心配置的功能 (bantime, findtime, maxretry)。
#
# 更新日志 (v2.1):
# - 新增: 自动检测并禁用系统日志压缩，防止Fail2ban因'message repeated'而漏掉日志。
#
# 功能:
# - 自动检测并适配包管理器 (apt, dnf, yum)
# - 智能检测防火墙后端 (nftables/iptables)，并自动配置
# - 当无防火墙时，交互式提示用户安装
# - 智能检测 SSHD 日志后端 (systemd/log file)
# - 提供安装、卸载、启停、查看日志和配置的菜单
# - 支持配置 Telegram Bot 发送封禁通知
# =================================================================

# --- 脚本配置 ---
# 使用颜色输出，增强可读性
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
NC='\e[0m' # No Color

# --- 全局变量 ---
PKG_MANAGER=""
FAIL2BAN_SERVICE="fail2ban"
JAIL_LOCAL_CONF="/etc/fail2ban/jail.local"
SSHD_JAIL_NAME="sshd"

# --- 内部函数 ---

# 检查是否以 root 权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ 错误：此脚本需要以 root 或 sudo 权限运行。${NC}"
        exit 1
    fi
}

# 检测包管理器
detect_pkg_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    else
        echo -e "${RED}❌ 错误：无法检测到支持的包管理器 (apt, dnf, yum)。${NC}"
        exit 1
    fi
}

# 检查 Fail2ban 是否已安装
is_installed() {
    command -v fail2ban-client &> /dev/null
}

# 检查并禁用系统日志压缩 (防止Fail2ban漏掉日志)
check_and_disable_log_compression() {
    echo -e "${BLUE}🔎 正在检查系统日志压缩设置...${NC}"
    local changes_made=false
    local restart_rsyslog=false
    local restart_journald=false

    # --- 检查并修复 rsyslog ---
    local rsyslog_conf="/etc/rsyslog.conf"
    if [ -f "$rsyslog_conf" ]; then
        # 检查是否明确开启了压缩
        if grep -q "^\s*\$RepeatedMsgReduction\s\+on" "$rsyslog_conf"; then
            echo -e "${YELLOW}⚠️  检测到 rsyslog 开启了日志压缩，正在禁用...${NC}"
            # 使用 sed 将 'on' 修改为 'off'，-i 表示直接修改文件
            sed -i 's/^\(\s*\$RepeatedMsgReduction\s\+\)on/\1off/' "$rsyslog_conf"
            changes_made=true
            restart_rsyslog=true
        fi
    fi

    # --- 检查并修复 systemd-journald ---
    local journald_conf="/etc/systemd/journald.conf"
    if [ -f "$journald_conf" ]; then
        # 如果速率限制没有被明确设置为0，则认为它是开启的（默认行为）
        if ! grep -q "^\s*RateLimitIntervalSec\s*=\s*0" "$journald_conf" || ! grep -q "^\s*RateLimitBurst\s*=\s*0" "$journald_conf"; then
            echo -e "${YELLOW}⚠️  检测到 systemd-journald 开启了速率限制，正在禁用...${NC}"
            # 使用 sed 修改或添加配置项
            # 如果行存在（无论是否注释），修改它
            if grep -q "RateLimitIntervalSec" "$journald_conf"; then
                sed -i -E 's/^\s*#?\s*RateLimitIntervalSec\s*=.*/RateLimitIntervalSec=0/' "$journald_conf"
            else
                # 如果不存在，追加到文件末尾
                echo "RateLimitIntervalSec=0" >> "$journald_conf"
            fi

            if grep -q "RateLimitBurst" "$journald_conf"; then
                sed -i -E 's/^\s*#?\s*RateLimitBurst\s*=.*/RateLimitBurst=0/' "$journald_conf"
            else
                echo "RateLimitBurst=0" >> "$journald_conf"
            fi

            changes_made=true
            restart_journald=true
        fi
    fi

    # --- 根据修改情况重启服务 ---
    if [ "$changes_made" = true ]; then
        echo -e "${BLUE}⚙️  正在应用日志配置变更...${NC}"
        if [ "$restart_journald" = true ]; then
            echo "正在重启 systemd-journald 服务..."
            systemctl restart systemd-journald
        fi
        if [ "$restart_rsyslog" = true ]; then
            echo "正在重启 rsyslog 服务..."
            systemctl restart rsyslog
        fi
        echo -e "${GREEN}✅ 日志压缩/速率限制已成功禁用。${NC}"
    else
        echo -e "${GREEN}✅ 日志压缩设置正常，无需修改。${NC}"
    fi
}


# 1. 安装 Fail2ban
install_fail2ban() {
    if is_installed; then
        echo -e "${GREEN}✅ 信息：Fail2ban 已安装。${NC}"
        return
    fi

    echo -e "${BLUE}⚙️  正在安装 Fail2ban...${NC}"
    case "$PKG_MANAGER" in
        apt)
            apt-get update && apt-get install -y fail2ban whois python3-pyinotify python3-systemd curl
            ;;
        dnf|yum)
            # RHEL/CentOS 可能需要 epel-release
            if ! rpm -q epel-release &>/dev/null; then
                echo -e "${YELLOW}正在安装 EPEL release...${NC}"
                "$PKG_MANAGER" install -y epel-release
            fi
            "$PKG_MANAGER" install -y fail2ban curl
            ;;
    esac

    if ! is_installed; then
        echo -e "${RED}❌ 错误：Fail2ban 安装失败。${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ 安装成功！${NC}"

    # 核心步骤：创建配置并启动
    create_config
    start_service
}

# 2. 卸载 Fail2ban
uninstall_fail2ban() {
    if ! is_installed; then
        echo -e "${GREEN}✅ 信息：Fail2ban 未安装。${NC}"
        return
    fi

    stop_service
    echo -e "${BLUE}⚙️  正在卸载 Fail2ban...${NC}"
    case "$PKG_MANAGER" in
        apt)
            apt-get purge -y --auto-remove fail2ban
            ;;
        dnf|yum)
            "$PKG_MANAGER" remove -y fail2ban
            ;;
    esac

    # 清理配置文件
    if [ -d /etc/fail2ban ]; then
        read -p "❓ 是否删除所有配置文件 /etc/fail2ban? [y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            rm -rf /etc/fail2ban
            echo -e "${YELLOW}🔥 已删除配置文件。${NC}"
        fi
    fi

    echo -e "${GREEN}✅ 卸载完成。${NC}"
}

# 创建配置文件 (核心优化逻辑)
create_config() {
    echo -e "${BLUE}📝 正在分析系统环境并创建自定义配置文件...${NC}"
    local banaction=""

    # 步骤 1: 智能检测防火墙后端
    if command -v nft &> /dev/null; then
        echo -e "${GREEN}🔎 检测到 nftables，将使用它作为防火墙后端。${NC}"
        banaction="nftables-multiport"
    elif command -v iptables &> /dev/null; then
        echo -e "${GREEN}🔎 检测到 iptables，将使用它作为防火墙后端。${NC}"
        banaction="iptables-multiport"
    else
        # 步骤 2: 当没有防火墙时，与用户交互
        echo -e "${YELLOW}⚠️ 警告：未找到防火墙工具 (nftables 或 iptables)。${NC}"
        echo -e "${YELLOW}Fail2ban 需要其中之一才能封禁 IP 地址。${NC}"
        read -p "❓ 是否现在安装 nftables (推荐)? [Y/n]: " choice

        # 如果用户输入 'y', 'Y' 或直接回车
        if [[ -z "$choice" || "$choice" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}⚙️  正在安装 nftables...${NC}"
            case "$PKG_MANAGER" in
                apt) apt-get install -y nftables ;;
                dnf|yum) "$PKG_MANAGER" install -y nftables ;;
            esac

            if command -v nft &> /dev/null; then
                echo -e "${GREEN}✅ nftables 安装成功。${NC}"
                banaction="nftables-multiport"
            else
                echo -e "${RED}❌ 错误：nftables 安装失败。请手动安装后再试。${NC}"
                exit 1
            fi
        else
            echo -e "${RED}❌ 操作取消。请先手动安装 nftables 或 iptables。${NC}"
            exit 1
        fi
    fi

    # 步骤 3: 写入配置文件
    echo -e "${BLUE}📝 正在写入配置文件到 $JAIL_LOCAL_CONF...${NC}"
    cat > "$JAIL_LOCAL_CONF" << EOF
# This file is auto-generated by fail2ban_manager.sh
# Do not edit jail.conf, edit this file for your local overrides.

[DEFAULT]
# 使用检测到的最佳封禁动作
banaction = ${banaction}

# 封禁23小时
bantime = 23h
# 在10分钟内超过3次失败即封禁
findtime = 10m
maxretry = 3

# --- SSHD Protection ---
[sshd]
enabled = true
EOF

    # 步骤 4: 智能判断并配置 sshd 日志后端
    if [ -f /var/log/auth.log ] || [ -f /var/log/secure ]; then
        echo -e "${GREEN}🔎 检测到传统日志文件，为 [sshd] 使用 logpath。${NC}"

        # 调用日志压缩检查函数
        check_and_disable_log_compression

        echo "logpath = %(sshd_log)s" >> "$JAIL_LOCAL_CONF"
        echo "backend = auto" >> "$JAIL_LOCAL_CONF"
    else
        echo -e "${GREEN}🔎 未检测到 auth.log/secure，为 [sshd] 使用 systemd 后端。${NC}"

        # 检查 systemd 的 Python 模块依赖
        if ! python3 -c "import systemd.journal" &>/dev/null; then
            echo -e "${YELLOW}⚠️ Fail2ban 需要 'python3-systemd' 模块来读取 systemd 日志。${NC}"
            read -p "❓ 是否现在安装它? [Y/n]: " choice
            if [[ -z "$choice" || "$choice" =~ ^[Yy]$ ]]; then
                echo -e "${BLUE}⚙️  正在安装 python3-systemd...${NC}"
                case "$PKG_MANAGER" in
                    apt) apt-get install -y python3-systemd ;;
                    dnf|yum) "$PKG_MANAGER" install -y python3-systemd ;;
                esac
                if ! python3 -c "import systemd.journal" &>/dev/null; then
                    echo -e "${RED}❌ 错误：python3-systemd 安装失败。请手动解决。${NC}"
                    exit 1
                fi
            else
                echo -e "${RED}❌ 操作取消。无法在没有 python3-systemd 的情况下使用 systemd 后端。${NC}"
                exit 1
            fi
        fi

        echo "backend = systemd" >> "$JAIL_LOCAL_CONF"
    fi

    echo -e "${GREEN}✅ 配置文件创建成功！${NC}"
}

# 3. 启动服务
start_service() {
    if ! is_installed; then
        echo -e "${RED}❌ 错误：请先安装 Fail2ban。${NC}"
        return
    fi

    echo -e "${BLUE}🚀 正在启动并设置 Fail2ban 开机自启...${NC}"
    systemctl unmask "$FAIL2BAN_SERVICE" &> /dev/null
    systemctl enable "$FAIL2BAN_SERVICE"
    systemctl restart "$FAIL2BAN_SERVICE" # 使用 restart 确保配置重载

    sleep 1 # 等待服务启动
    if systemctl is-active --quiet "$FAIL2BAN_SERVICE"; then
        echo -e "${GREEN}✅ Fail2ban 已成功启动并运行。${NC}"
    else
        echo -e "${RED}❌ 错误：Fail2ban 启动失败。${NC}"
        echo -e "${YELLOW}请使用 'journalctl -xeu fail2ban' 或 'cat /var/log/fail2ban.log' 查看详细错误。${NC}"
    fi
}

# 4. 停止服务
stop_service() {
    if ! is_installed; then
        echo -e "${GREEN}✅ 信息：Fail2ban 未安装。${NC}"
        return
    fi

    echo -e "${BLUE}🛑 正在停止并禁用 Fail2ban 开机自启...${NC}"
    systemctl stop "$FAIL2BAN_SERVICE"
    systemctl disable "$FAIL2BAN_SERVICE"
    echo -e "${GREEN}✅ Fail2ban 已停止。${NC}"
}

# 5. 查看日志 (友好)
view_log() {
    if ! is_installed || ! systemctl is-active --quiet "$FAIL2BAN_SERVICE"; then
        echo -e "${RED}❌ 错误：Fail2ban 未安装或未运行。${NC}"
        return
    fi

    echo -e "${BLUE}--- 🛡️  SSHD 防护状态 ---${NC}"
    fail2ban-client status "$SSHD_JAIL_NAME"
    echo -e "${BLUE}------------------------${NC}"

    read -p "❓ 是否查看实时原始日志 (tail -f /var/log/fail2ban.log)? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "按 CTRL+C 退出日志查看。"
        sleep 1
        tail -n 50 -f /var/log/fail2ban.log
    fi
}

# 6. 查看当前配置
view_config() {
    if [ -f "$JAIL_LOCAL_CONF" ]; then
        echo -e "${BLUE}--- 📜  当前配置文件 ($JAIL_LOCAL_CONF) ---${NC}"
        cat "$JAIL_LOCAL_CONF"
        echo -e "${BLUE}------------------------------------${NC}"
    else
        echo -e "${YELLOW}⚠️ 警告：未找到自定义配置文件 $JAIL_LOCAL_CONF。${NC}"
        if [ -f /etc/fail2ban/jail.conf ]; then
             echo "你可能正在使用默认配置 /etc/fail2ban/jail.conf，这不被推荐。"
        fi
    fi
}

# 修改配置的辅助函数
update_config_value() {
    local key="$1"
    local value="$2"
    local file="$3"
    # 如果键存在，则替换该行的值；如果不存在，则在[DEFAULT]后添加
    if grep -q "^\s*${key}\s*=" "${file}"; then
        # 使用 sed 替换已存在的行
        sed -i "s/^\s*${key}\s*=.*/${key} = ${value}/" "${file}"
    else
        # 如果键不存在，则在 [DEFAULT] 部分下添加它
        sed -i "/\[DEFAULT\]/a ${key} = ${value}" "${file}"
    fi
}

# 7. 修改核心配置
modify_config() {
    if [ ! -f "$JAIL_LOCAL_CONF" ]; then
        echo -e "${RED}❌ 错误：配置文件 $JAIL_LOCAL_CONF 不存在。${NC}"
        echo -e "${YELLOW}请先运行安装选项 (1) 来创建默认配置。${NC}"
        return
    fi

    echo -e "${BLUE}--- 🔧 修改 Fail2ban 配置 ---${NC}"
    echo "请输入新值，或直接按 Enter 保留当前值。"

    # 读取并显示当前值，使用 grep 和 cut 提高兼容性
    current_bantime=$(grep "^\s*bantime" "$JAIL_LOCAL_CONF" | cut -d '=' -f 2- | xargs)
    current_findtime=$(grep "^\s*findtime" "$JAIL_LOCAL_CONF" | cut -d '=' -f 2- | xargs)
    current_maxretry=$(grep "^\s*maxretry" "$JAIL_LOCAL_CONF" | cut -d '=' -f 2- | xargs)

    # 获取用户输入
    read -p "设置封禁时长 (bantime) [当前: ${current_bantime}]: " new_bantime
    read -p "设置检测时长 (findtime) [当前: ${current_findtime}]: " new_findtime
    read -p "设置最大重试次数 (maxretry) [当前: ${current_maxretry}]: " new_maxretry

    local changes_made=false

    # 更新值
    if [ -n "$new_bantime" ]; then
        update_config_value "bantime" "$new_bantime" "$JAIL_LOCAL_CONF"
        changes_made=true
    fi

    if [ -n "$new_findtime" ]; then
        update_config_value "findtime" "$new_findtime" "$JAIL_LOCAL_CONF"
        changes_made=true
    fi

    if [ -n "$new_maxretry" ]; then
        update_config_value "maxretry" "$new_maxretry" "$JAIL_LOCAL_CONF"
        changes_made=true
    fi

    if [ "$changes_made" = true ]; then
        echo -e "${GREEN}✅ 配置已更新！${NC}"
        view_config # 调用 view_config 函数显示新配置

        read -p "❓ 是否立即重启 Fail2ban 服务以应用新配置? [Y/n]: " choice
        if [[ -z "$choice" || "$choice" =~ ^[Yy]$ ]]; then
            start_service
        else
            echo -e "${YELLOW}提醒：配置已修改，但服务未重启，新配置将在下次重启后生效。${NC}"
        fi
    else
        echo -e "${GREEN}✅ 未做任何修改。${NC}"
    fi
}


# ★★★ 新增：8. 配置 Telegram 通知 ★★★
configure_telegram() {
    # 检查 curl 是否安装
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}❌ 错误：'curl' 命令未找到，这是发送 Telegram 通知所必需的。${NC}"
        read -p "❓ 是否现在尝试安装 curl? [Y/n]: " choice
        if [[ -z "$choice" || "$choice" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}⚙️  正在安装 curl...${NC}"
            case "$PKG_MANAGER" in
                apt) apt-get install -y curl ;;
                dnf|yum) "$PKG_MANAGER" install -y curl ;;
            esac
            if ! command -v curl &> /dev/null; then
                echo -e "${RED}❌ curl 安装失败。请手动安装后再试。${NC}"
                return 1
            fi
        else
            echo -e "${RED}❌ 操作取消。${NC}"
            return 1
        fi
    fi

    echo -e "${BLUE}--- 🔧 配置 Telegram Bot 通知 ---${NC}"
    read -p "请输入你的 Bot Token: " bot_token
    read -p "请输入你的 Chat ID: " chat_id

    if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
        echo -e "${RED}❌ 错误：Bot Token 和 Chat ID 不能为空。${NC}"
        return 1
    fi

    local TELEGRAM_ACTION_CONF="/etc/fail2ban/action.d/telegram.conf"
    local TELEGRAM_NOTIFY_SCRIPT="/etc/fail2ban/action.d/telegram-notify.sh"

    echo -e "${BLUE}📝 正在创建 Telegram action 配置文件...${NC}"
    # 创建 Fail2ban 的 action 文件
    cat > "$TELEGRAM_ACTION_CONF" << EOF
# Fail2ban action configuration for Telegram
# Auto-generated by fail2ban_manager.sh
[Definition]
actionban = ${TELEGRAM_NOTIFY_SCRIPT} "<ip>" "<name>" "<protocol>" "<port>"
[Init]
EOF

    echo -e "${BLUE}📝 正在创建 Telegram 通知脚本...${NC}"
    # 创建通知脚本
    # 注意：这里的 EOF 需要用引号括起来，防止脚本内的变量被当前shell解析
    cat > "$TELEGRAM_NOTIFY_SCRIPT" << 'EOF'
#!/bin/bash
# Fail2Ban Telegram notify script (auto-generated by fail2ban_manager.sh)
# Arguments: <IP> <JAIL> <PROTOCOL> <PORT>

# --- Configuration (will be replaced by main script) ---
BOT_TOKEN="!!BOT_TOKEN!!"
CHAT_ID="!!CHAT_ID!!"
# --- End Configuration ---

# --- Script Logic ---
IP="$1"
JAIL="$2"
PROTOCOL="$3"
PORT="$4"
HOSTNAME=$(hostname -f)
LOG_DATE=$(date)

# Message formatting for Markdown
MESSAGE="🛡️ *Fail2Ban Alert on ${HOSTNAME}* 🛡️

A host has just been banned by Fail2Ban.

*Timestamp:* \`${LOG_DATE}\`
*Banned IP:* \`${IP}\`
*Jail Name:* \`${JAIL}\`
*Protocol:* \`${PROTOCOL}\`
*Port:* \`${PORT}\`"

# API URL
URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

# Send the message using curl, with Markdown parsing
curl -s --max-time 15 -X POST "${URL}" \
    -d "chat_id=${CHAT_ID}" \
    -d "text=${MESSAGE}" \
    -d "parse_mode=Markdown" > /dev/null
EOF

    # 替换 Token 和 Chat ID
    sed -i "s/!!BOT_TOKEN!!/${bot_token}/" "$TELEGRAM_NOTIFY_SCRIPT"
    sed -i "s/!!CHAT_ID!!/${chat_id}/" "$TELEGRAM_NOTIFY_SCRIPT"

    # 使脚本可执行
    chmod +x "$TELEGRAM_NOTIFY_SCRIPT"
    echo -e "${GREEN}✅ 通知脚本创建成功并已设为可执行。${NC}"

    # 修改 jail.local 以使用新的 action
    if [ ! -f "$JAIL_LOCAL_CONF" ]; then
        echo -e "${RED}❌ 错误：配置文件 $JAIL_LOCAL_CONF 不存在。${NC}"
        echo -e "${YELLOW}请先运行安装选项 (1) 来创建默认配置。${NC}"
        return 1
    fi

    echo -e "${BLUE}🔧 正在更新 $JAIL_LOCAL_CONF 以启用通知...${NC}"
    # 检查 [sshd] 监牢中是否已配置 telegram action
    if sed -n '/^\[sshd\]/,/^\[/p' "$JAIL_LOCAL_CONF" | grep -q "^\s*action\s*.*telegram"; then
        echo -e "${YELLOW}⚠️ Telegram 通知似乎已在 [sshd] 部分配置。跳过修改。${NC}"
    else
        # 为防止冲突，先删除 [sshd] 中可能存在的旧 action 行
        sed -i '/^\[sshd\]/,/^\[/ { /^\s*action\s*=/d; }' "$JAIL_LOCAL_CONF"

        # 在 [sshd] 标题后添加新的组合 action
        # 这将同时执行默认的封禁动作 (%(action_)) 和 telegram 通知
        # 使用 printf 和 sed 来处理换行符，以获得更好的可移植性
        local new_action
        new_action=$(printf "action = %%(action_)s\n         telegram")
        sed -i "/^\[sshd\]/a ${new_action}" "$JAIL_LOCAL_CONF"
        echo -e "${GREEN}✅ 已为 [sshd] 监牢启用 Telegram 通知。${NC}"
    fi

    echo -e "${GREEN}🎉 Telegram 通知配置完成！${NC}"
    read -p "❓ 是否立即重启 Fail2ban 服务以应用新配置? [Y/n]: " choice
    if [[ -z "$choice" || "$choice" =~ ^[Yy]$ ]]; then
        start_service
    else
        echo -e "${YELLOW}提醒：配置已修改，但服务未重启，新配置将在下次重启后生效。${NC}"
    fi
}


# --- 主菜单 ---
main_menu() {
    clear
    while true; do
        echo ""
        echo -e "${BLUE}--- Fail2ban 智能管理脚本 (v2.3) ---${NC}"
        echo " 1. 安装 Fail2ban (自动配置并启动)"
        echo " 2. 卸载 Fail2ban"
        echo " ---------------------------------------"
        echo " 3. 启动 / 重启 Fail2ban 服务"
        echo " 4. 停止 Fail2ban 服务"
        echo " 5. 查看 SSHD 防护状态和日志"
        echo " 6. 查看当前本地配置文件"
        echo " 7. 修改 Fail2ban 核心配置"
        echo -e "${GREEN} 8. 配置 Telegram 通知${NC}"
        echo " 0. 退出脚本"
        echo -e "${BLUE}---------------------------------------${NC}"
        read -p "请输入选项 [0-8]: " option

        # 清屏以便显示操作结果
        clear

        case $option in
            1) install_fail2ban ;;
            2) uninstall_fail2ban ;;
            3) start_service ;;
            4) stop_service ;;
            5) view_log ;;
            6) view_config ;;
            7) modify_config ;;
            8) configure_telegram ;;
            0) echo -e "${GREEN}👋 再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}❌ 无效选项，请重试。${NC}" ;;
        esac

        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        clear
    done
}

# --- 脚本入口 ---
check_root
detect_pkg_manager
main_menu
