#!/bin/bash

# ==============================================================================
# Fail2ban 交互式管理脚本
#
# 功能:
#   - 提供菜单式交互界面
#   - 安装、卸载 Fail2ban
#   - 启动、停止、重启服务
#   - 查看日志、黑名单
#   - 手动封禁、解封 IP
#
# 最后更新: 2025-06-16
# ==============================================================================

# --- 脚本常量与颜色定义 ---
JAIL_LOCAL_PATH="/etc/fail2ban/jail.local"
LOG_PATH="/var/log/fail2ban.log"

# 颜色定义
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

# --- 辅助函数 ---

# 打印带颜色的信息
_log() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${C_RESET}"
}

# 暂停脚本，等待用户按键
_pause() {
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# 检查是否以 root 权限运行
_check_root() {
    if [ "$(id -u)" -ne "0" ]; then
        _log "$C_RED" "错误：此脚本必须以 root 权限运行。"
        exit 1
    fi
}

# 检查 Fail2ban 是否已安装
_check_installed() {
    if ! command -v fail2ban-client &> /dev/null; then
        _log "$C_YELLOW" "Fail2ban 尚未安装。"
        return 1
    else
        return 0
    fi
}

# 获取操作系统包管理器
_get_pkg_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt-get"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    else
        _log "$C_RED" "错误：未找到支持的包管理器 (apt-get, dnf, yum)。"
        exit 1
    fi
}

# --- 核心功能函数 ---

# 1. 安装与配置 Fail2ban
fn_install() {
    if _check_installed; then
        _log "$C_YELLOW" "Fail2ban 已安装。您想重新配置吗？[y/N]"
        read -r choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    
    _log "$C_CYAN" "--- 开始安装与配置 Fail2ban ---"

    # 获取用户配置
    read -p "请输入您的白名单 IP (多个用空格隔开, 强烈建议添加本机公网IP): " IGNORE_IP
    IGNORE_IP="127.0.0.1/8 ::1 ${IGNORE_IP}"
    
    read -p "请输入全局封禁时间 (例如 1d, 2h, 30m) [默认: 1d]: " BAN_TIME
    [ -z "$BAN_TIME" ] && BAN_TIME="1d"
    
    read -p "请输入全局最大重试次数 [默认: 5]: " MAX_RETRY
    [ -z "$MAX_RETRY" ] && MAX_RETRY="5"
    
    read -p "请输入 SSH 服务的端口号 [默认: 22]: " SSH_PORT
    [ -z "$SSH_PORT" ] && SSH_PORT="22"

    read -p "请输入 SSH 服务的最大重试次数 [默认: 3]: " SSH_MAX_RETRY
    [ -z "$SSH_MAX_RETRY" ] && SSH_MAX_RETRY="3"

    # 安装
    PKG_MANAGER=$(_get_pkg_manager)
    _log "$C_BLUE" "正在使用 $PKG_MANAGER 安装 Fail2ban..."
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        $PKG_MANAGER update > /dev/null
    fi
    if [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
        if ! rpm -q epel-release &> /dev/null; then
             $PKG_MANAGER install -y epel-release > /dev/null
        fi
    fi
    $PKG_MANAGER install -y fail2ban > /dev/null
    _log "$C_GREEN" "Fail2ban 安装成功。"

    # 配置
    _log "$C_BLUE" "正在创建配置文件: $JAIL_LOCAL_PATH"
    if [ -f "$JAIL_LOCAL_PATH" ]; then
        mv "$JAIL_LOCAL_PATH" "${JAIL_LOCAL_PATH}.bak_$(date +%F_%T)"
    fi

    cat << EOF > "$JAIL_LOCAL_PATH"
[DEFAULT]
ignoreip = ${IGNORE_IP}
bantime  = ${BAN_TIME}
findtime = 10m
maxretry = ${MAX_RETRY}
banaction = iptables-multiport

[sshd]
enabled = true
port    = ${SSH_PORT}
maxretry = ${SSH_MAX_RETRY}
EOF
    
    _log "$C_GREEN" "配置文件创建成功。"
    fn_start
}

# 2. 卸载 Fail2ban
fn_uninstall() {
    if ! _check_installed; then return; fi
    
    _log "$C_YELLOW" "警告：这将从系统中卸载 Fail2ban。确定要继续吗？[y/N]"
    read -r choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        _log "$C_GREEN" "操作已取消。"
        return
    fi

    fn_stop
    PKG_MANAGER=$(_get_pkg_manager)
    _log "$C_BLUE" "正在使用 $PKG_MANAGER 卸载 Fail2ban..."
    $PKG_MANAGER remove -y fail2ban > /dev/null
    
    _log "$C_YELLOW" "是否要删除所有配置文件 (/etc/fail2ban)？这是一个不可逆操作！[y/N]"
    read -r choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        rm -rf /etc/fail2ban
        _log "$C_RED" "配置文件已删除。"
    fi
    
    _log "$C_GREEN" "Fail2ban 卸载完成。"
}

# 3. 启动 Fail2ban
fn_start() {
    if ! _check_installed; then return; fi
    _log "$C_BLUE" "正在启动并设置 Fail2ban 开机自启..."
    systemctl enable fail2ban > /dev/null
    systemctl restart fail2ban
    sleep 1
    systemctl status fail2ban --no-pager -l
}

# 4. 停止 Fail2ban
fn_stop() {
    if ! _check_installed; then return; fi
    _log "$C_BLUE" "正在停止并禁用 Fail2ban 开机自启..."
    systemctl stop fail2ban
    systemctl disable fail2ban > /dev/null
    sleep 1
    systemctl status fail2ban --no-pager -l
}

# 5. 查看所有日志
fn_view_all_logs() {
    if ! _check_installed; then return; fi
    if [ -f "$LOG_PATH" ]; then
        less "$LOG_PATH"
    else
        _log "$C_YELLOW" "日志文件不存在: $LOG_PATH"
    fi
}

# 6. 查看失败日志 (Ban/Unban)
fn_view_failure_logs() {
    if ! _check_installed; then return; fi
    if [ -f "$LOG_PATH" ]; then
        _log "$C_CYAN" "--- 仅显示封禁/解封相关日志 ---"
        grep -E 'Ban|Unban' "$LOG_PATH" | less
    else
        _log "$C_YELLOW" "日志文件不存在: $LOG_PATH"
    fi
}

# 7. 增加禁止 IP
fn_ban_ip() {
    if ! _check_installed; then return; fi
    _log "$C_CYAN" "--- 手动封禁 IP ---"
    
    fail2ban-client status
    read -p "请输入要操作的 Jail 名称 (例如 sshd): " jail
    if [ -z "$jail" ]; then
        _log "$C_RED" "Jail 名称不能为空。"
        return
    fi

    read -p "请输入要封禁的 IP 地址: " ip
    if [ -z "$ip" ]; then
        _log "$C_RED" "IP 地址不能为空。"
        return
    fi

    fail2ban-client set "$jail" banip "$ip"
    _log "$C_GREEN" "IP $ip 已在 Jail [$jail] 中被封禁。"
}

# 8. 放行 IP
fn_unban_ip() {
    if ! _check_installed; then return; fi
    _log "$C_CYAN" "--- 手动解封 IP ---"
    
    fail2ban-client status
    read -p "请输入要操作的 Jail 名称 (例如 sshd): " jail
     if [ -z "$jail" ]; then
        _log "$C_RED" "Jail 名称不能为空。"
        return
    fi
    
    read -p "请输入要解封的 IP 地址: " ip
    if [ -z "$ip" ]; then
        _log "$C_RED" "IP 地址不能为空。"
        return
    fi

    fail2ban-client set "$jail" unbanip "$ip"
    _log "$C_GREEN" "IP $ip 已在 Jail [$jail] 中被解封。"
}

# 9. 查看当前黑名单
fn_view_banned_list() {
    if ! _check_installed; then return; fi
    _log "$C_CYAN" "--- 查看当前黑名单 ---"
    
    Jails=$(fail2ban-client status | grep "Jail list" | sed -E 's/.*Jail list:[ \t]+//' | sed 's/,//g')
    if [ -z "$Jails" ]; then
        _log "$C_YELLOW" "当前没有活动的 Jail。"
        return
    fi
    
    _log "$C_BLUE" "当前活动的 Jails: $Jails"
    for jail in $Jails; do
        _log "$C_CYAN" "--- Jail: $jail ---"
        fail2ban-client status "$jail"
        echo ""
    done
}


# --- 主菜单 ---
main_menu() {
    _check_root
    clear
    echo "================================================="
    _log "$C_CYAN" "          Fail2ban 交互式管理脚本"
    echo "================================================="
    _log "$C_GREEN" "  1. 安装并配置 Fail2ban"
    _log "$C_RED"   "  2. 卸载 Fail2ban"
    echo "-------------------------------------------------"
    _log "$C_GREEN" "  3. 启动并自启 Fail2ban"
    _log "$C_YELLOW" "  4. 停止并禁用 Fail2ban"
    echo "-------------------------------------------------"
    _log "$C_BLUE" "  5. 查看 Fail2ban 所有日志"
    _log "$C_BLUE" "  6. 查看封禁/解封日志"
    _log "$C_BLUE" "  7. 查看当前黑名单"
    echo "-------------------------------------------------"
    _log "$C_RED"   "  8. 手动封禁一个 IP"
    _log "$C_GREEN" "  9. 手动解封一个 IP"
    echo "-------------------------------------------------"
    _log "$C_YELLOW" "  q. 退出脚本"
    echo "================================================="
    read -p "请输入您的选项 [1-9, q]: " choice
    
    case $choice in
        1) fn_install; _pause ;;
        2) fn_uninstall; _pause ;;
        3) fn_start; _pause ;;
        4) fn_stop; _pause ;;
        5) fn_view_all_logs; _pause ;;
        6) fn_view_failure_logs; _pause ;;
        7) fn_view_banned_list; _pause ;;
        8) fn_ban_ip; _pause ;;
        9) fn_unban_ip; _pause ;;
        q|Q) exit 0 ;;
        *) _log "$C_RED" "无效选项，请输入 1-9 或 q。"; sleep 1 ;;
    esac
}

# --- 脚本入口 ---
while true; do
    main_menu
done
