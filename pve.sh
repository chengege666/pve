#!/bin/bash

# ==============================================================================
# 脚本名称: Proxmox VE Ultimate Optimizer (支持 PVE 7.x / 8.x / 9.x)
# 功能描述: CPU/功耗优化、去除订阅、UI 硬件信息增强
# 更新说明: 正式适配 PVE 9.x 版本检测
# ==============================================================================

# --- 全局变量 ---
BACKUP_SUFFIX=".bak.pveopt"
# 获取主版本号 (例如 8.1.4 -> 8)
PVE_VERSION=$(pveversion | awk -F/ '{print $2}' | awk -F. '{print $1}')
LOG_FILE="/var/log/pve_optimizer.log"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 基础工具函数 ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用 root 权限运行。${NC}"
        exit 1
    fi
}

check_pve_version() {
    # 更新：加入 "9" 的支持
    if [[ "$PVE_VERSION" != "7" && "$PVE_VERSION" != "8" && "$PVE_VERSION" != "9" ]]; then
        echo -e "${RED}警告: 当前脚本适配 PVE 7/8/9，检测到版本: $PVE_VERSION${NC}"
        read -p "是否强制继续? (y/n): " choice
        if [[ "$choice" != "y" ]]; then exit 1; fi
    fi
}

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        if [ ! -f "${file}${BACKUP_SUFFIX}" ]; then
            cp "$file" "${file}${BACKUP_SUFFIX}"
            log "已备份: $file"
        fi
    fi
}

restore_file() {
    local file=$1
    if [ -f "${file}${BACKUP_SUFFIX}" ]; then
        cp "${file}${BACKUP_SUFFIX}" "$file"
        log "已恢复: $file"
        return 0
    fi
    return 1
}

confirm_box() {
    if whiptail --title "$1" --yesno "$2" 15 60; then return 0; else return 1; fi
}

msg_box() {
    whiptail --title "$1" --msgbox "$2" 10 60
}

# --- 模块一：CPU 优化 ---
module_cpu() {
    current_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    available_govs=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "N/A")
    
    cpu_choice=$(whiptail --title "CPU 模式选择" --menu \
        "当前: $current_gov\n可用: $available_govs" 15 70 5 \
        "performance" "高性能 (全速)" \
        "powersave" "省电 (降频)" \
        "ondemand" "按需 (平衡)" \
        "schedutil" "调度感应 (新内核推荐)" \
        "cancel" "返回" 3>&1 1>&2 2>&3)

    if [[ "$cpu_choice" != "cancel" && -n "$cpu_choice" ]]; then
        if confirm_box "确认修改" "设置模式为 $cpu_choice？"; then
            apt-get update -qq && apt-get install -y cpufrequtils >/dev/null
            backup_file "/etc/default/cpufrequtils"
            echo "GOVERNOR=\"$cpu_choice\"" > /etc/default/cpufrequtils
            systemctl restart cpufrequtils
            msg_box "成功" "已应用 CPU 策略。"
        fi
    fi

    # VM CPU 优化
    if confirm_box "VM CPU 类型优化" "推荐将 VM CPU 类型设为 'host' 以提升性能。\n是否扫描并修改？"; then
        vms=$(qm list | awk '$1 ~ /^[0-9]+$/ {print $1}')
        count=0
        for vmid in $vms; do
            ctype=$(qm config $vmid | grep "^cpu:" | awk '{print $2}')
            if [[ "$ctype" != "host" ]]; then
                qm set $vmid --cpu host >/dev/null
                ((count++))
            fi
        done
        msg_box "完成" "已优化 $count 台虚拟机。"
    fi
}

# --- 模块二：去除订阅 ---
module_subscription() {
    local target="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    if confirm_box "去除订阅弹窗" "修改 proxmoxlib.js 以移除 'No valid subscription' 弹窗。\n(适配 PVE 7/8/9)\n是否继续？"; then
        if [ ! -f "$target" ]; then
            msg_box "错误" "未找到文件: $target\nPVE 9 可能更改了文件路径。"
            return
        fi
        
        backup_file "$target"
        # 尝试通用的替换逻辑
        sed -i.bak "s/data.status !== 'Active'/false/g" "$target"
        
        if confirm_box "重启服务" "需重启 pveproxy 生效，是否立即重启？"; then
            systemctl restart pveproxy
            msg_box "完成" "服务已重启，请刷新浏览器 (Ctrl+F5)。"
        fi
    fi
}

# --- 模块三：基础监控工具 ---
module_tools() {
    choices=$(whiptail --title "安装基础工具" --checklist \
        "空格选择，回车确认:" 15 70 5 \
        "lm-sensors" "温度传感器驱动" ON \
        "smartmontools" "硬盘健康检测" ON \
        "nvme-cli" "NVMe 硬盘工具" ON \
        "ethtool" "网卡工具" OFF 3>&1 1>&2 2>&3)
    
    if [ -n "$choices" ]; then
        choices=$(echo "$choices" | tr -d '"')
        apt-get update -qq
        apt-get install -y $choices
        
        if [[ "$choices" == *"lm-sensors"* ]]; then
            if confirm_box "探测传感器" "是否运行 sensors-detect (自动模式)?"; then
                yes | sensors-detect >/dev/null
                service kmod start
            fi
        fi
        msg_box "完成" "工具安装完毕。"
    fi
}

# --- 模块四：UI 界面增强 ---
module_ui_hack() {
    whiptail --title "UI 增强说明" --msgbox "实现“概要”页面显示详细温度、频率、硬盘寿命。\n本模块调用社区脚本 (pvetools)。\n\n注意：在 PVE 9 上该功能可能处于实验性阶段。" 12 70

    local choice=$(whiptail --title "选择增强方案" --menu "请选择:" 15 70 3 \
        "1" "安装 UI 监控补丁 (PVE 8/9 兼容模式)" \
        "2" "仅启用基础传感器 (lm-sensors) 不改 UI" \
        "3" "恢复原生 UI (回滚)" 3>&1 1>&2 2>&3)

    case $choice in
        1)
            if confirm_box "安装 UI 补丁" "即将下载并运行增强脚本。\n会自动修改 Nodes.pm 和 pvemanagerlib.js。\n\n是否继续？"; then
                apt-get install -y git lm-sensors smartmontools nvme-cli
                
                # 兼容性处理：PVE 9 通常兼容 PVE 8 的 Perl 结构
                # 如果是 PVE 9，我们尝试使用 PVE 8 的安装逻辑
                
                local install_cmd=""
                if [[ "$PVE_VERSION" == "8" || "$PVE_VERSION" == "9" ]]; then
                     # 使用 ivanhao 的 pvetools，这是目前维护较好的版本
                     install_cmd="bash <(curl -s https://raw.githubusercontent.com/ivanhao/pvetools/master/pvetools.sh) install_temp"
                else
                     # PVE 7
                     install_cmd="bash <(curl -s https://raw.githubusercontent.com/ivanhao/pvetools/master/pvetools.sh) install_temp"
                fi
                
                msg_box "执行中" "正在拉取脚本，请稍候...\n\n如果脚本提示版本不支持，请忽略或手动选择 PVE 8 选项。"
                eval "$install_cmd"
                
                msg_box "完成" "补丁脚本已执行。请强制刷新浏览器缓存 (Shift+F5)。\n如果界面白屏，请运行此脚本并选择 [3] 回滚。"
            fi
            ;;
        2)
            module_tools
            ;;
        3)
            if confirm_box "回滚" "尝试恢复 Nodes.pm 和 JS 文件？"; then
                restore_file "/usr/share/perl5/PVE/API2/Nodes.pm"
                restore_file "/usr/share/pve-manager/js/pvemanagerlib.js"
                systemctl restart pveproxy
                msg_box "回滚" "已尝试恢复文件。"
            fi
            ;;
    esac
}

# --- 模块五：功耗优化 ---
module_power() {
    preset=$(whiptail --title "功耗预设" --menu "选择方案:" 15 70 3 \
        "1" "家用 NAS 极致省电 (开启 ASPM)" \
        "2" "企业服务器 (高性能/默认)" 3>&1 1>&2 2>&3)

    case $preset in
        1)
            if confirm_box "省电模式" "将开启 PCIe ASPM 和 SATA Link Power。\n可能导致部分旧硬件不稳定，是否继续？"; then
                backup_file "/etc/default/grub"
                sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="pcie_aspm=force pcie_port_pm=force /' /etc/default/grub
                update-grub
                echo 'ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="auto"' > /etc/udev/rules.d/usb_power.rules
                udevadm control --reload
                msg_box "需重启" "已应用省电参数，请重启系统。"
            fi
            ;;
        2)
            if confirm_box "恢复默认" "将清除 ASPM 强制参数。"; then
                backup_file "/etc/default/grub"
                sed -i 's/pcie_aspm=force //g; s/pcie_port_pm=force //g' /etc/default/grub
                update-grub
                rm -f /etc/udev/rules.d/usb_power.rules
                msg_box "需重启" "已恢复默认设置。"
            fi
            ;;
    esac
}

# --- 主菜单 ---
show_menu() {
    whiptail --title "PVE 一键优化 (PVE $PVE_VERSION Detect)" \
        --menu "Select Action:" 20 70 10 \
        "1" "CPU 调度与虚拟化优化" \
        "2" "去除订阅提示 (Nag Remove)" \
        "3" "基础硬件监控工具安装" \
        "4" "UI 界面增强 (显示温度/频率)" \
        "5" "功耗优化方案" \
        "6" "退出" 3>&1 1>&2 2>&3
}

# --- 执行入口 ---
check_root
check_pve_version

while true; do
    choice=$(show_menu)
    if [ $? -ne 0 ]; then clear; exit 0; fi
    
    case $choice in
        1) module_cpu ;;
        2) module_subscription ;;
        3) module_tools ;;
        4) module_ui_hack ;;
        5) module_power ;;
        6) clear; exit 0 ;;
    esac
done
