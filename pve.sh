#!/bin/bash

# ================================================
# PVE 一键优化脚本 v3.0 (全功能汉化终极版)
# 整合内容：备份回滚 + 调频 + Intel 特性 + 订阅去广告 + 监控工具
# ================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
BACKUP_DIR="/root/pve_backup_$(date +%Y%m%d_%H%M%S)"
ROLLBACK_FILE="$BACKUP_DIR/rollback.log"
CURRENT_PVE_VERSION=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K\d+\.\d+' || echo "未知")
DIALOG="none"

# 消息显示函数
show_msg() {
    local msg="$1"
    local type="$2"
    case $type in
        "info") echo -e "${BLUE}[信息]${NC} $msg" ;;
        "success") echo -e "${GREEN}[成功]${NC} $msg" ;;
        "warning") echo -e "${YELLOW}[警告]${NC} $msg" ;;
        "error") echo -e "${RED}[错误]${NC} $msg" ;;
    esac
}

# 环境与工具检查
check_env() {
    [[ $EUID -ne 0 ]] && { show_msg "必须以 root 运行" "error"; exit 1; }
    if command -v whiptail &> /dev/null; then DIALOG=whiptail; elif command -v dialog &> /dev/null; then DIALOG=dialog; else DIALOG="none"; fi
}

# 自动备份函数
backup_file() {
    local file="$1"
    local desc="$2"
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp "$file" "$BACKUP_DIR/$(basename "$file").$(date +%s).bak"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $desc: $file" >> "$ROLLBACK_FILE"
    fi
}

# 获取 CPU 详细信息
get_cpu_info() {
    CPU_VENDOR=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')
    CPU_CORES=$(nproc)
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        CPU_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    else
        CPU_GOVERNOR="不支持/未知"
    fi
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]]; then
        CURRENT_FREQ_MHZ=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 ))
    fi
}

# --- 1. CPU 优化子菜单功能 ---

# 1.1 配置调速器 (含补全的 userspace)
configure_cpu_governor() {
    get_cpu_info
    local available=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
    [[ -z "$available" ]] && { show_msg "当前 CPU 不支持调频" "warning"; return; }
    
    IFS=' ' read -ra gov_list <<< "$available"
    local menu_items=()
    for gov in "${gov_list[@]}"; do
        case $gov in
            "performance")  display="高性能 (始终最高频率)" ;;
            "powersave")    display="节能模式 (始终最低频率)" ;;
            "ondemand")     display="按需模式 (高负载升频，闲置降频)" ;;
            "schedutil")    display="调度优化 (现代内核推荐，响应快)" ;;
            "conservative") display="保守模式 (频率切换较平缓)" ;;
            "userspace")    display="用户空间 (由外部程序或用户手动控制)" ;;
            *)              display="$gov" ;;
        esac
        [[ "$gov" == "$CPU_GOVERNOR" ]] && display="$display [当前使用]"
        menu_items+=("$gov" "$display")
    done
    
    selected=$($DIALOG --title "选择 CPU 调速器" --menu "请选择工作模式：" 20 80 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)
    [[ -z "$selected" ]] && return

    # 持久化备份
    backup_file "/etc/default/cpufrequtils" "CPU 调速器配置"
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$selected" > "$cpu" 2>/dev/null; done
    echo -e "ENABLE=\"true\"\nGOVERNOR=\"$selected\"" > /etc/default/cpufrequtils
    show_msg "调速器已改为 $selected 并已持久化" "success"
}

# 1.2 手动设置频率范围 (找回功能)
configure_cpu_frequency() {
    local min_f_file="/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq"
    local max_f_file="/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
    [[ ! -f "$min_f_file" ]] && { show_msg "硬件不支持手动频率调整" "warning"; return; }
    
    local min_limit=$(( $(cat $min_f_file) / 1000 ))
    local max_limit=$(( $(cat $max_f_file) / 1000 ))

    new_min=$($DIALOG --title "设置最小频率" --inputbox "输入最小频率 (MHz)\n范围: $min_limit - $max_limit" 10 50 "$min_limit" 3>&1 1>&2 2>&3)
    [[ -z "$new_min" ]] && return
    new_max=$($DIALOG --title "设置最大频率" --inputbox "输入最大频率 (MHz)\n范围: $new_min - $max_limit" 10 50 "$max_limit" 3>&1 1>&2 2>&3)
    [[ -z "$new_max" ]] && return

    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do echo "$((new_min * 1000))" > "$cpu" 2>/dev/null; done
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo "$((new_max * 1000))" > "$cpu" 2>/dev/null; done
    show_msg "频率范围已应用: $new_min - $new_max MHz" "success"
}

# 1.3 Intel CPU 特性深调 (修复版)
configure_intel_features() {
    if [[ "$CPU_VENDOR" != "GenuineIntel" ]]; then
        $DIALOG --title "不支持" --msgbox "非 Intel CPU" 10 40; return
    fi
    local ps_status="/sys/devices/system/cpu/intel_pstate/status"
    local tb_file="/sys/devices/system/cpu/intel_pstate/no_turbo"
    [[ ! -f "$ps_status" ]] && { $DIALOG --title "错误" --msgbox "当前内核未开启 P-State" 10 40; return; }

    cur_tb="未知"; [[ -f "$tb_file" ]] && { [[ "$(cat $tb_file)" == "0" ]] && cur_tb="开启" || cur_tb="关闭"; }

    opt=$($DIALOG --title "Intel 深度设置" --menu "当前 P-State: $(cat $ps_status)\n当前睿频: $cur_tb" 15 60 5 \
        "active" "Active (由 P-State 驱动全面接管调频)" \
        "passive" "Passive (由通用驱动接管，更省电)" \
        "off" "Off (禁用 Intel 驱动模式)" \
        "turbo" "切换 睿频加速 (Turbo Boost) 开/关" 3>&1 1>&2 2>&3)

    case $opt in
        "active"|"passive"|"off") echo "$opt" > "$ps_status" && show_msg "P-State 已设为 $opt" "success" ;;
        "turbo")
            [[ "$(cat $tb_file)" == "0" ]] && echo "1" > "$tb_file" || echo "0" > "$tb_file"
            show_msg "睿频状态已切换" "success"
            ;;
    esac
}

# 1.4 虚拟机 host 优化
optimize_vm_cpu() {
    local vms=$(qm list 2>/dev/null | awk 'NR>1 {print $1}')
    [[ -z "$vms" ]] && { show_msg "没有正在运行的虚拟机" "info"; return; }
    for vm in $vms; do
        qm set "$vm" --cpu host && show_msg "虚拟机 $vm 已优化为 host 模式" "success"
    done
}

# CPU 优化子菜单界面
cpu_optimization_menu() {
    while true; do
        get_cpu_info
        sel=$($DIALOG --title "CPU 性能与调频优化" --menu "当前模式: $CPU_GOVERNOR | 频率: $CURRENT_FREQ_MHZ MHz" 18 65 6 \
            1 "配置 CPU 调速器 (Governor)" \
            2 "手动设置最小/最大频率" \
            3 "Intel CPU 深度控制 (P-State/睿频)" \
            4 "一键虚拟机 CPU 优化 (设置为 host)" \
            5 "返回主菜单" 3>&1 1>&2 2>&3)
        [[ -z "$sel" || "$sel" == "5" ]] && break
        case $sel in
            1) configure_cpu_governor ;;
            2) configure_cpu_frequency ;;
            3) configure_intel_features ;;
            4) optimize_vm_cpu ;;
        esac
    done
}

# --- 2. 网页弹窗去除 ---
remove_subscription_notice() {
    local js_file="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    [[ ! -f "$js_file" ]] && js_file="/usr/share/pve-manager/js/proxmoxlib.js"
    if [[ -f "$js_file" ]]; then
        backup_file "$js_file" "订阅广告修改"
        sed -i.bak "s/if (data.status !== 'Active') {/if (false) {/" "$js_file"
        systemctl restart pveproxy
        $DIALOG --title "操作成功" --msgbox "弹窗已去除，请 Ctrl+F5 刷新浏览器网页。" 10 50
    else
        show_msg "未找到对应 JS 文件" "error"
    fi
}

# --- 3. 找回全套监控工具安装 ---
install_monitoring_tools() {
    tools=$($DIALOG --title "安装监控工具" --checklist "空格键选择，回车键安装:" 20 65 8 \
        "lm-sensors" "CPU温度、风扇监控" ON \
        "smartmontools" "硬盘健康与寿命检测" ON \
        "powertop" "系统功耗详细分析" OFF \
        "nvme-cli" "NVMe SSD 专用管理工具" OFF \
        "hddtemp" "传统硬盘温度监控" OFF \
        "netdata" "酷炫的实时网页监控看板" OFF \
        "stress-ng" "压力测试工具" OFF 3>&1 1>&2 2>&3)
    
    [[ -z "$tools" ]] && return
    apt-get update
    for tool in $tools; do
        t=$(echo $tool | tr -d '"')
        if [[ "$t" == "netdata" ]]; then
            bash <(curl -Ss https://my-netdata.io/kickstart.sh) --non-interactive
        else
            apt-get install -y "$t"
        fi
        [[ "$t" == "lm-sensors" ]] && sensors-detect --auto
    done
    show_msg "所选工具安装完成" "success"
}

# --- 4. 找回详细电源模式选择 ---
power_optimization_menu() {
    mode=$($DIALOG --title "电源方案预设" --menu "请选择工作场景：" 15 60 4 \
        "server" "高性能模式 (性能优先，忽略功耗)" \
        "home" "家用平衡模式 (按需分配，静音平衡)" \
        "save" "极致节能模式 (限制低功耗，降低发热)" 3>&1 1>&2 2>&3)
    
    case $mode in
        "server")
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "performance" > "$cpu" 2>/dev/null; done
            show_msg "已应用高性能预设" "success"
            ;;
        "home")
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "schedutil" > "$cpu" 2>/dev/null || echo "ondemand" > "$cpu" 2>/dev/null; done
            show_msg "已应用家用平衡预设" "success"
            ;;
        "save")
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "powersave" > "$cpu" 2>/dev/null; done
            echo "powersupersave" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null
            show_msg "已应用极致节能预设" "success"
            ;;
    esac
}

# --- 5. 系统状态显示 ---
show_system_status() {
    get_cpu_info
    status="[ PVE版本 ]  $CURRENT_PVE_VERSION\n"
    status+="[ CPU型号 ]  $CPU_MODEL\n"
    status+="[ 当前频率 ]  $CURRENT_FREQ_MHZ MHz\n"
    status+="[ 调速模式 ]  $CPU_GOVERNOR\n\n"
    status+="[ 内存使用 ]\n$(free -h | awk 'NR<=2')\n\n"
    status+="[ 磁盘空间 ]\n$(df -h | grep -E '^/dev/|pve-')"
    $DIALOG --title "实时状态" --msgbox "$status" 20 70
}

# --- 6. 找回一键回滚功能 ---
rollback_all() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        $DIALOG --title "错误" --msgbox "未找到本次执行的备份目录。" 10 40; return
    fi
    $DIALOG --title "确认回滚" --yesno "确定要撤销脚本对文件的所有修改吗？" 10 50
    [[ $? -ne 0 ]] && return
    
    # 回滚 JS
    local js_bak=$(ls $BACKUP_DIR/proxmoxlib.js*.bak 2>/dev/null | tail -n 1)
    [[ -f "$js_bak" ]] && { cp "$js_bak" "/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js" 2>/dev/null || cp "$js_bak" "/usr/share/pve-manager/js/proxmoxlib.js"; }
    
    # 重启服务
    systemctl restart pveproxy
    show_msg "回滚完成，部分设置可能需要重启生效" "success"
}

# --- 主入口逻辑 ---

main_menu() {
    while true; do
        res=$($DIALOG --title "PVE 终极优化脚本 v3.0" --menu "PVE 版本: $CURRENT_PVE_VERSION" 20 65 9 \
            1 "CPU 性能、调频与虚拟机优化" \
            2 "去除网页‘无有效订阅’弹窗" \
            3 "安装全套监控工具 (温度/看板)" \
            4 "电源工作模式一键预设 (节能/性能)" \
            5 "查看当前系统运行状态" \
            6 "一键回滚脚本所做的修改" \
            7 "内存清理" \
            8 "磁盘清理" \
            0 "退出脚本" 3>&1 1>&2 2>&3)
        
        [[ -z "$res" || "$res" == "0" ]] && break
        case $res in
            1) cpu_optimization_menu ;;
            2) remove_subscription_notice ;;
            3) install_monitoring_tools ;;
            4) power_optimization_menu ;;
            5) show_system_status ;;
            6) rollback_all ;;
            7) clear_memory ;;
            8) clear_disk ;;
        esac
    done
}

# --- 7. 内存清理功能 ---
clear_memory() {
    show_msg "开始清理内存缓存..." "info"
    sync
    echo 3 > /proc/sys/vm/drop_caches
    show_msg "内存缓存清理完成。" "success"
}

# --- 8. 磁盘清理功能 ---
clear_disk() {
    show_msg "开始清理磁盘空间..." "info"

    # 清理 apt 缓存
    apt clean
    show_msg "APT 缓存清理完成。" "success"

    # 清理旧日志文件
    find /var/log -type f -name "*.log" -delete
    find /var/log -type f -name "*.gz" -delete
    show_msg "旧日志文件清理完成。" "success"

    # 清理临时文件
    rm -rf /tmp/*
    show_msg "临时文件清理完成。" "success"

    show_msg "磁盘清理完成。" "success"
}

main() {
    clear
    check_env
    $DIALOG --title "欢迎使用" --yesno "脚本将对 PVE 进行深度优化。\n修改前会自动备份至 $BACKUP_DIR\n\n是否开始？" 12 60
    [[ $? -eq 0 ]] && main_menu
}

main "$@"