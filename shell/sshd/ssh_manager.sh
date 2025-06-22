#!/bin/bash

# ==============================================================================
# SSH 安全管理脚本 (适用于 Debian/Ubuntu) - V2 (使用 .d 目录)
#
# 策略:
# - 自定义配置写入 /etc/ssh/sshd_config.d/99-custom.conf
# - 为确保自定义配置生效，会自动注释掉 /etc/ssh/sshd_config 中的冲突项
# ==============================================================================

# --- 配置 ---
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
SSH_CONFIG_DIR="/etc/ssh/sshd_config.d"
CUSTOM_CONFIG_FILE="${SSH_CONFIG_DIR}/99-custom.conf"
AUTHORIZED_KEYS_FILE="/root/.ssh/authorized_keys"

# --- 颜色定义 ---
COLOR_BLUE='\033[1;34m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[1;31m'
COLOR_RESET='\033[0m'

# --- 标志位 ---
CONFIG_CHANGED=0

# --- 辅助函数 ---

# 检查是否以 root 用户运行
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${COLOR_RED}错误: 此脚本必须以 root 用户权限运行。${COLOR_RESET}"
        echo -e "请尝试使用 'sudo ./ssh_manager_v2.sh'"
        exit 1
    fi
}

# 按任意键继续
press_enter_to_continue() {
    echo ""
    read -p "按 [Enter] 键返回主菜单..."
}

# 备份文件
backup_file() {
    local file_to_backup="$1"
    if [ ! -f "${file_to_backup}.bak_$(date +%F)" ]; then
        cp "$file_to_backup" "${file_to_backup}.bak_$(date +%F)"
        echo -e "${COLOR_GREEN}文件已备份至 ${file_to_backup}.bak_$(date +%F)${COLOR_RESET}"
    fi
}

# 获取SSH的最终生效配置值
# 使用 sshd -T 是最准确的方法
get_ssh_config() {
    local key="$1"
    # sshd -T 输出的key是小写的
    sshd -T | grep -i "^${key,}" | awk '{print $2}'
}

# 设置SSH配置值 (新逻辑)
# $1: 配置项名称
# $2: 配置项的值
set_ssh_config() {
    local key="$1"
    local value="$2"
    local new_line="${key} ${value}"

    # 1. 确保 .d 目录和 Include 指令是激活的
    mkdir -p "$SSH_CONFIG_DIR"
    if ! grep -qE "^\s*Include ${SSH_CONFIG_DIR}/\*.conf" "$SSH_CONFIG_FILE"; then
        echo -e "${COLOR_YELLOW}在 ${SSH_CONFIG_FILE}末尾添加 Include 指令...${COLOR_RESET}"
        echo -e "\n# Include custom configurations\nInclude ${SSH_CONFIG_DIR}/*.conf" >> "$SSH_CONFIG_FILE"
        CONFIG_CHANGED=1
    fi
    
    # 2. 备份主配置文件（因为我们可能会修改它）
    backup_file "$SSH_CONFIG_FILE"
    
    # 3. 在主配置文件中注释掉冲突的设置
    # 使用 grep 查找有效行，再用 grep -v 排除注释行
    local active_setting
    active_setting=$(grep -E "^[[:space:]]*${key}\s+" "$SSH_CONFIG_FILE" | grep -vE "^[[:space:]]*#")

    if [ -n "$active_setting" ]; then
        echo -e "${COLOR_YELLOW}在 ${SSH_CONFIG_FILE} 中发现活动的 '${key}' 设置，正在注释...${COLOR_RESET}"
        echo "  -> 找到内容: $active_setting"
        
        # 使用更安全的 sed: /^\s*#/! 表示只在不以'#'开头的行上操作
        # 这样可以避免意外地重复注释
        sed -i.bak -E "/^\s*#/!s/^\s*(${key}\s+.*)/# \1 (由脚本自动注释)/" "$SSH_CONFIG_FILE"
        
        CONFIG_CHANGED=1
    fi

    # 4. 确保自定义配置文件存在
    touch "$CUSTOM_CONFIG_FILE"
    
    # 5. 在自定义文件中设置新值
    if grep -qE "^\s*#*\s*${key}\s+" "$CUSTOM_CONFIG_FILE"; then
        # 如果存在（无论是否注释），替换它
        sed -i "s/^\s*#*\s*${key}\s+.*/${new_line}/" "$CUSTOM_CONFIG_FILE"
    else
        # 如果不存在，追加
        echo "${new_line}" >> "$CUSTOM_CONFIG_FILE"
    fi
    echo -e "${COLOR_GREEN}配置已在 ${CUSTOM_CONFIG_FILE} 中更新: ${key} 设置为 ${value}${COLOR_RESET}"
    CONFIG_CHANGED=1
}


# 重启SSH服务
restart_ssh_service() {
    echo -e "${COLOR_YELLOW}正在测试 SSH 配置...${COLOR_RESET}"
    sshd -t
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}SSH 配置测试失败！请检查 ${CUSTOM_CONFIG_FILE} 和 ${SSH_CONFIG_FILE}${COLOR_RESET}"
        echo -e "${COLOR_RED}重启已中止，以防 SSH 服务无法启动。${COLOR_RESET}"
        return
    fi
    
    echo -e "${COLOR_YELLOW}配置测试通过。正在重启 SSH 服务...${COLOR_RESET}"
    systemctl restart sshd
    if systemctl is-active --quiet sshd; then
        echo -e "${COLOR_GREEN}SSH 服务重启成功！${COLOR_RESET}"
        new_port=$(get_ssh_config "port")
        echo -e "${COLOR_YELLOW}请注意：如果修改了端口，请使用新端口 ${new_port} 连接。${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}SSH 服务重启失败！请检查日志: sudo journalctl -u sshd${COLOR_RESET}"
        echo -e "${COLOR_RED}旧的配置文件已备份，您可以从备份恢复。${COLOR_RESET}"
    fi
}

# --- 菜单功能 (与V1基本相同，但调用的是新版函数) ---

# 1. 预览当前SSH配置
preview_config() {
    clear
    echo -e "${COLOR_BLUE}--- 当前 SSH 生效配置预览 (通过 'sshd -T' 获取) ---${COLOR_RESET}"
    echo "--------------------------------------------------"
    echo -e "SSH 端口 (Port):               $(get_ssh_config port)"
    echo -e "密钥登录 (PubkeyAuthentication): $(get_ssh_config pubkeyauthentication)"
    echo -e "密码登录 (PasswordAuthentication): $(get_ssh_config passwordauthentication)"
    echo -e "Root 登录 (PermitRootLogin):   $(get_ssh_config permitrootlogin)"
    echo "--------------------------------------------------"
    echo -e "公钥信息 ($AUTHORIZED_KEYS_FILE):"
    cat "$AUTHORIZED_KEYS_FILE" 
    echo "--------------------------------------------------"
    echo "说明:"
    echo " - PermitRootLogin 'prohibit-password' 表示禁止root使用密码登录，但允许密钥登录。"
    echo " - 这是当前服务正在使用的最终生效值。"
    echo -e "\n您的自定义配置文件位于: ${COLOR_GREEN}${CUSTOM_CONFIG_FILE}${COLOR_RESET}"
}

# 2. 开启 SSHKey 登录和新增公钥
setup_ssh_key() {
    clear
    echo -e "${COLOR_YELLOW}--- 开启 SSHKey 登录 和 新增公钥 ---${COLOR_RESET}"
    
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    touch "$AUTHORIZED_KEYS_FILE" && chmod 600 "$AUTHORIZED_KEYS_FILE"

    echo "请输入您要添加的 SSH 公钥 (例如: ssh-rsa AAAA... user@host):"
    read -p "> " pub_key

    if [[ -z "$pub_key" || ! "$pub_key" =~ ^ssh- ]]; then
        echo -e "${COLOR_RED}输入无效。公钥内容不能为空，且通常以 'ssh-' 开头。${COLOR_RESET}"
        return
    fi
    
    # 防止重复添加
    if grep -qF "$pub_key" "$AUTHORIZED_KEYS_FILE"; then
         echo -e "${COLOR_YELLOW}此公钥已存在于 ${AUTHORIZED_KEYS_FILE} 中，无需重复添加。${COLOR_RESET}"
    else
        echo "$pub_key" >> "$AUTHORIZED_KEYS_FILE"
        echo -e "${COLOR_GREEN}公钥已成功添加到 ${AUTHORIZED_KEYS_FILE}${COLOR_RESET}"
    fi

    if [[ "$(get_ssh_config pubkeyauthentication)" != "yes" ]]; then
        echo "检测到 PubkeyAuthentication 未开启，现在为您设置为 'yes'..."
        set_ssh_config "PubkeyAuthentication" "yes"
    fi
}

# 3. 修改 SSH 端口
change_ssh_port() {
    clear
    echo -e "${COLOR_RED}--- (高危) 修改 SSH 端口 ---${COLOR_RESET}"
    local current_port=$(get_ssh_config port)
    echo "当前 SSH 端口是: $current_port"
    echo -e "${COLOR_YELLOW}警告: 修改端口后，您需要使用新的端口号连接 SSH。${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}请确保新的端口没有被防火墙拦截 (如 ufw, iptables)！${COLOR_RESET}"
    read -p "请输入新的 SSH 端口号 (1024-65535, 留空取消): " new_port

    if [ -z "$new_port" ]; then
        echo "操作已取消。"
        return
    fi

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${COLOR_RED}错误: 端口号必须是 1024 到 65535 之间的数字。${COLOR_RESET}"
        return
    fi
    
    read -p "您确定要将 SSH 端口修改为 ${new_port} 吗? [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        set_ssh_config "Port" "$new_port"
    else
        echo "操作已取消。"
    fi
}

# 4. 禁用密码登录
disable_password_login() {
    clear
    echo -e "${COLOR_RED}--- (高危) 禁用密码登录 ---${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}警告: 此操作将禁止通过密码登录服务器！${COLOR_RESET}"
    
    if [ ! -s "$AUTHORIZED_KEYS_FILE" ]; then
        echo -e "${COLOR_RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!! 安全中止 !!!!!!!!!!!!!!!!!!!!!!!!!!!!${COLOR_RESET}"
        echo -e "${COLOR_RED}错误: 检测到 ${AUTHORIZED_KEYS_FILE} 文件不存在或为空。${COLOR_RESET}"
        echo -e "${COLOR_RED}在此情况下禁用密码登录，您将无法通过 SSH 登录 root 账户！${COLOR_RESET}"
        echo -e "请先通过菜单 [2] 添加您的公钥，然后再执行此操作。"
        return
    fi
    
    echo "安全检查通过，检测到已设置公钥。"
    read -p "您确定要禁用密码登录 (PasswordAuthentication no) 吗? [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        set_ssh_config "PasswordAuthentication" "no"
    else
        echo "操作已取消。"
    fi
}

# 5. 禁用 root 用户直接登录
disable_root_login() {
    clear
    echo -e "${COLOR_RED}--- (高危) 禁用 Root 用户直接登录 ---${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}警告: 此操作将禁止 root 用户直接通过 SSH 密码登录。${COLOR_RESET}"
    echo "推荐设置为 'prohibit-password'，这允许 root 使用密钥登录，但禁止使用密码。"

    if [ ! -s "$AUTHORIZED_KEYS_FILE" ]; then
        echo -e "${COLOR_RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!! 安全中止 !!!!!!!!!!!!!!!!!!!!!!!!!!!!${COLOR_RESET}"
        echo -e "${COLOR_RED}错误: 检测到 ${AUTHORIZED_KEYS_FILE} 文件不存在或为空。${COLOR_RESET}"
        echo -e "${COLOR_RED}若在没有其他可sudo用户的情况下完全禁用root登录，您可能失去服务器权限！${COLOR_RESET}"
        echo -e "请先通过菜单 [2] 为 root 添加公钥，以确保可以通过密钥登录。"
        return
    fi
    
    echo "安全检查通过，检测到 root 已设置公钥。"
    read -p "您确定要将 PermitRootLogin 设置为 'prohibit-password' 吗? [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        set_ssh_config "PermitRootLogin" "prohibit-password"
    else
        echo "操作已取消。"
    fi
}

# --- 主菜单 ---
main_menu() {
    while true; do
        clear
        echo "====================================================="
        echo "      SSH 安全管理脚本 V2 (使用分离式配置)     "
        echo "====================================================="
        echo -e "自定义配置将被写入: ${COLOR_GREEN}${CUSTOM_CONFIG_FILE}${COLOR_RESET}"
        echo "-----------------------------------------------------"
        echo -e "${COLOR_BLUE} 1. 预览当前 SSH 生效配置${COLOR_RESET}"
        echo -e "${COLOR_YELLOW} 2. 开启 SSHKey 登录 和 新增公钥${COLOR_RESET}"
        echo -e "${COLOR_RED} 3. (高危) 修改 SSH 端口${COLOR_RESET}"
        echo -e "${COLOR_RED} 4. (高危) 禁用密码登录${COLOR_RESET}"
        echo -e "${COLOR_RED} 5. (高危) 禁用 Root 密码登录${COLOR_RESET}"
        echo "-----------------------------------------------------"
        echo " 0. 退出脚本"
        echo "====================================================="
        
        if [ "$CONFIG_CHANGED" -eq 1 ]; then
            echo -e "${COLOR_YELLOW}检测到配置已更改。输入 'r' 可测试并重启 SSH 服务使其生效。${COLOR_RESET}"
        fi

        read -p "请输入您的选择 [0-5, r]: " choice

        case "$choice" in
            1) preview_config; press_enter_to_continue ;;
            2) setup_ssh_key; press_enter_to_continue ;;
            3) change_ssh_port; press_enter_to_continue ;;
            4) disable_password_login; press_enter_to_continue ;;
            5) disable_root_login; press_enter_to_continue ;;
            r|R)
                if [ "$CONFIG_CHANGED" -eq 1 ]; then
                    restart_ssh_service
                    CONFIG_CHANGED=0
                else
                    echo "配置未发生变化，无需重启。"
                fi
                press_enter_to_continue
                ;;
            0)
                if [ "$CONFIG_CHANGED" -eq 1 ]; then
                   echo -e "${COLOR_YELLOW}警告: 您有未应用的配置更改。确定要退出吗？${COLOR_RESET}"
                   read -p "退出将丢失更改，除非您手动重启SSH。确定退出? [y/N]: " exit_confirm
                   if [[ "${exit_confirm,,}" == "y" ]]; then break; fi
                else
                    break
                fi
                ;;
            *)
                echo -e "${COLOR_RED}无效的输入，请输入 0-5 或 r。${COLOR_RESET}"
                press_enter_to_continue
                ;;
        esac
    done
    echo "脚本已退出。"
}

# --- 脚本入口 ---
check_root
main_menu