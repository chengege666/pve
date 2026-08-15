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

# 多选菜单关联数组
declare -A options
declare -A choices

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
        res=$($DIALOG --title "PVE 终极优化脚本 v3.0" --menu "PVE 版本: $CURRENT_PVE_VERSION" 24 70 12 \
            1 "CPU 性能、调频与虚拟机优化" \
            2 "去除网页‘无有效订阅’弹窗" \
            3 "安装全套监控工具 (温度/看板)" \
            4 "电源工作模式一键预设 (节能/性能)" \
            5 "查看当前系统运行状态" \
            6 "一键回滚脚本所做的修改" \
            7 "内存清理" \
            8 "磁盘清理" \
            9 "系统更新 (升级已安装软件包)" \
            10 "更换软件源 (国内镜像源)" \
            11 "概要信息增强 (CPU温度/频率/硬盘/UPS)" \
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
            9) system_update ;;
            10) change_apt_source ;;
            11) pveInfo_menu ;;
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

# --- 9. 系统更新功能 ---
system_update() {
    show_msg "正在更新软件包列表..." "info"
    if ! apt-get update; then
        show_msg "软件包列表更新失败，请检查网络或软件源配置" "error"
        return 1
    fi

    show_msg "开始升级已安装的软件包..." "info"
    if apt-get upgrade -y; then
        show_msg "系统软件包升级完成" "success"
    else
        show_msg "软件包升级过程中出现错误" "error"
        return 1
    fi

    # 询问是否清理无用依赖
    $DIALOG --title "清理依赖" --yesno "是否清理不再需要的依赖包？" 10 50
    if [[ $? -eq 0 ]]; then
        show_msg "正在清理无用依赖..." "info"
        apt-get autoremove -y
        show_msg "无用依赖清理完成" "success"
    fi

    show_msg "系统更新流程结束" "success"
}

# --- 10. 更换软件源功能 ---
change_apt_source() {
    # 检测 Debian 版本代号
    local codename=""
    [[ -f /etc/os-release ]] && codename=$(grep -E "^VERSION_CODENAME=" /etc/os-release | cut -d'=' -f2)
    if [[ -z "$codename" ]]; then
        $DIALOG --title "错误" --msgbox "无法识别 Debian 版本代号，操作取消" 10 50
        return 1
    fi

    local src_list="/etc/apt/sources.list"
    local ent_list="/etc/apt/sources.list.d/pve-enterprise.list"
    local nosub_list="/etc/apt/sources.list.d/pve-no-subscription.list"

    local sel=$($DIALOG --title "选择软件源 (当前 Debian: $codename)" --menu "请选择国内镜像源：" 18 60 5 \
        "1" "中科大 USTC (推荐)" \
        "2" "清华大学 TUNA" \
        "3" "阿里云 Aliyun" \
        "4" "华为云 Huaweicloud" \
        "5" "恢复官方默认源" 3>&1 1>&2 2>&3)
    [[ -z "$sel" ]] && return

    local base_url=""
    case $sel in
        "1") base_url="https://mirrors.ustc.edu.cn" ;;
        "2") base_url="https://mirrors.tuna.tsinghua.edu.cn" ;;
        "3") base_url="https://mirrors.aliyun.com" ;;
        "4") base_url="https://repo.huaweicloud.com" ;;
        "5") base_url="https://deb.debian.org" ;;
    esac

    # 备份原 sources.list
    backup_file "$src_list" "APT 软件源"
    [[ -f "$ent_list" ]] && backup_file "$ent_list" "PVE 企业源"
    [[ -f "$nosub_list" ]] && backup_file "$nosub_list" "PVE 无订阅源"

    # 禁用所有 DEB822 新格式源文件 (.sources)，避免与 sources.list 重复
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        backup_file "$f" "$(basename "$f" .sources) 新格式源"
        mv "$f" "${f}.disabled"
    done

    # 生成新的 sources.list
    cat > "$src_list" <<EOF
deb $base_url/debian $codename main contrib non-free non-free-firmware
deb $base_url/debian $codename-updates main contrib non-free non-free-firmware
deb $base_url/debian-security $codename-security main contrib non-free non-free-firmware
EOF
    [[ $? -ne 0 ]] && { show_msg "写入 sources.list 失败" "error"; return 1; }

    # 处理 PVE 企业源：注释掉企业源，启用无订阅源
    if [[ -f "$ent_list" ]]; then
        sed -i 's/^\(deb .*\)/# \1/' "$ent_list"
    fi

    # 写入或覆盖 PVE 无订阅源
    cat > "$nosub_list" <<EOF
deb [trusted=yes] http://download.proxmox.com/debian/pve $codename pve-no-subscription
EOF

    # 刷新软件包列表
    show_msg "软件源已更换，正在刷新软件包列表..." "info"
    if apt-get update; then
        show_msg "软件源更换并刷新成功" "success"
    else
        show_msg "软件源已更换，但刷新失败，请检查网络" "warning"
    fi
}

# ============ 以下移植自 pve-ui.sh 概要信息功能 ============

echoContent() {
    case $1 in
    "red")
        ${echoType} "\033[31m${printN}$2 \033[0m"
        ;;
    "skyBlue")
        ${echoType} "\033[1;36m${printN}$2 \033[0m"
        ;;
    "green")
        ${echoType} "\033[32m${printN}$2 \033[0m"
        ;;
    "white")
        ${echoType} "\033[37m${printN}$2 \033[0m"
        ;;
    "magenta")
        ${echoType} "\033[31m${printN}$2 \033[0m"
        ;;
    "yellow")
        ${echoType} "\033[33m${printN}$2 \033[0m"
        ;;
    esac
}

rmsg() { echo -e "\033[31m$*\033[0m"; }
gmsg() { echo -e "\033[32m$*\033[0m"; }
ymsg() { echo -e "\033[33m$*\033[0m"; }
bmsg() { echo -e "\033[34m$*\033[0m"; }
pmsg() { echo -e "\033[35m$*\033[0m"; }
bgmsg() { echo -e "\033[36m$*\033[0m"; }
bglsg() { echo -e "\033[1;36m$*\033[0m"; }
bgumsg() { echo -e "\033[4;36m$*\033[0m"; }
wmsg() { echo -e "\033[37m$*\033[0m"; }

network_connectivity() {
    curl test.ipw.cn > /dev/null 2>&1
    if [ $? = "0" ]; then
        echoContent green "网络连通性：已连接互联网"
    else
        echoContent red "网络连通性：未连接互联网。请注意网络配置及 DNS "
    fi
}

initVar() {
    installType='apt -y install'
    reinstallType='apt -y reinstall'
    removeType='apt -y remove'
    update="apt update"
    upgrade="apt upgrade -y"
    distupgrade="apt dist-upgrade -y"
    dpkgconfigure="dpkg --configure -a"

    updateReleaseInfoChange='apt-get --allow-releaseinfo-change update'
    autoremoveType='apt -y autoremove'
    echoType='echo -e'

    totalProgress=1

    Auto="No"
    pveauto="OFF"

    pveVersionJudge
}

process_line() {
    i=0
    str='#'
    ch=('|' '\' '-' '/')
    index=0
    while [ $i -le 50 ]
    do
        printf "$1：[%-50s][%d%%][%c]\r" $str $(($i*2)) ${ch[$index]}
        str+='#'
        let i++
        let index=i%4
        sleep 0.05
    done
    printf "\n"
}

install_software() {
    local tool="$1"
    local soft="$2"
    if [ -z $(which ${tool}) ]; then
        ${updateReleaseInfoChange} > /dev/null 2>&1
        echoContent green " ---> 安装 ${soft}"
        process_line '进度'
        ${installType} ${soft} > /dev/null 2>&1
        if [ -z $(which ${tool}) ]; then
            echoContent red " ---> ${soft} 安装失败, 请检查 PVE 软件源及网络的连通性、DNS有效性后重试"
        else
            echoContent green " ---> ${soft} 安装完成"
        fi
    fi
}

remove_software() {
    local tool="$1"
    local soft="$2"
    if [ ! -z $(which ${tool}) ]; then
        echoContent green " ---> 卸载 ${soft}"
        process_line '进度'
        ${removeType} ${soft} > /dev/null 2>&1
        if [ -n $(which ${tool}) ]; then
            echoContent red " ---> ${soft} 卸载失败"
        else
            echoContent green " ---> ${soft} 卸载完成"
        fi
    fi
}

pveVersionJudge() {
    proxmox_ver="$(pveversion -v | grep pve-manager | awk '{print $2}')"
    proxmox_main_ver="${proxmox_ver%%-*}"

    function version_gt() { test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" != "$1"; }
    function version_le() { test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" == "$1"; }
    function version_lt() { test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" != "$1"; }
    function version_ge() { test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"; }
}

case_read() {
    read -r -p $'\x0a(按键 Ctrl + C 终止运行脚本, 键入任意值返回'$1') : ' choose
    case $choose in
        *)
            echoContent white ""
            if [ -f "$2" ]; then
                chmod +x "$2" && ./$2 $3
            fi
            ;;
    esac
}

ask_user() {
    Que="$1"
    cmd_0="$2"
    cme_1="$3"
    while true
        do
            read -r -p "$Que (Y/n) : " answer
            case $answer in [Yy]) eval $cmd_0 && break;;
                            [Nn]) eval $cmd_1 && break;;
                               *) echoContent red " ---> 选择错误";;
            esac
        done
}

choices_switch() {
	for i in $@; do
        if [[ "${choices[$i]}" == "*" ]]; then
            unset choices[$i]
        else
            choices[$i]="*"
        fi
	done
}

pve_Info_Menu() {
    keys=(0 1 2 3 4 5 6 7 8 9 a b c l r m j o p q x s)

    options[0]="CPU 实时主频"
    options[1]="CPU 最小及最大主频 # (必选 0 )"
    options[2]="CPU 线程主频"
    options[3]="CPU 工作模式       # (必选 0 )"
    options[4]="CPU 功率           # (必选 0 )"
    options[5]="CPU 温度"
    options[6]="CPU 核心温度       # 不支持 AMD (必选 5 )"
    options[7]="核显温度           # 仅支持 AMD (必选 5 )"
    options[8]="风扇转速           # 可能需要单独安装传感器驱动 (必选 5 )"
    options[9]="UPS 信息           # 仅支持 apcupsd - apcaccess 软件包"
    options[a]="硬盘基础信息       # 容量、寿命 (仅 NVME )、温度"
    options[b]="硬盘通电信息       # 通电统计 (必选 a )"
    options[c]="硬盘 IO 信息       # IO 负载 (必选 a )"
    options[l]="概要信息: 居左显示"
    options[r]="概要信息: 居右显示"
    options[m]="概要信息: 居中显示"
    options[j]="概要信息: 平铺显示"
    options[o]="推荐方案一：高大全 # 除 UPS 信息以外全全部居右显示"
    options[p]="推荐方案二：精简"
    options[q]="推荐方案三：极简"
    options[x]="一键清空           # 还原默认"
    options[s]="跳过本次修改"

    ERROR=" "

    clear

    function MENU {
        echoContent skyBlue "\n进度  2/${totalProgress} : PVE 概要信息定制向导"
        echoContent red "=============================================================="
        for NUM in ${keys[*]}; do
            ymsg "[""${choices[$NUM]:- }""]" $NUM") ${options[$NUM]}"
        done
        echoContent red "$ERROR"
        echoContent red "=============================================================="
    }

    while MENU && read -e -p "根据菜单选择需要部署/取消, 按Enter结束: " -n1 SELECTION && [[ -n "$SELECTION" ]]; do
        clear
        if [[ ${options[$SELECTION]} ]]; then
            case $SELECTION in
                l)
                    choices_switch $SELECTION
                    if [[ "${choices[$SELECTION]}" = "*" ]]; then
                        for i in r m j; do
                            choices[$i]="*"
                            choices_switch $i
                        done
                    fi
                    ;;
                r)
                    choices_switch $SELECTION
                    if [[ "${choices[$SELECTION]}" = "*" ]]; then
                        for i in l m j; do
                            choices[$i]="*"
                            choices_switch $i
                        done
                    fi
                    ;;
                m)
                    choices_switch $SELECTION
                    if [[ "${choices[$SELECTION]}" = "*" ]]; then
                        for i in l r j; do
                            choices[$i]="*"
                            choices_switch $i
                        done
                    fi
                    ;;
                j)
                    choices_switch $SELECTION
                    if [[ "${choices[$SELECTION]}" = "*" ]]; then
                        for i in l r m; do
                            choices[$i]="*"
                            choices_switch $i
                        done
                    fi
                    ;;
                o)
                    choices_switch $SELECTION
                    if [[ "${choices[$SELECTION]}" = "*" ]]; then
                        for i in 0 1 2 3 4 5 6 7 8 a b c r; do
                            choices[$i]=""
                            choices_switch $i
                        done
                        for i in 9 l m j p q x s; do
                            choices[$i]="*"
                            choices_switch $i
                        done
                    fi
                    ;;
                p)
                    choices_switch $SELECTION
                    if [[ "${choices[$SELECTION]}" = "*" ]]; then
                        for i in 0 2 3 4 5 6 7 8 a b r; do
                            choices[$i]=""
                            choices_switch $i
                        done
                        for i in 1 9 c l m j o q x s; do
                            choices[$i]="*"
                            choices_switch $i
                        done
                    fi
                    ;;
                q)
                    choices_switch $SELECTION
                    if [[ "${choices[$SELECTION]}" = "*" ]]; then
                        for i in 0 4 5 7 8 a r; do
                            choices[$i]=""
                            choices_switch $i
                        done
                        for i in 1 2 3 6 9 b c l m j o p x s; do
                            choices[$i]="*"
                            choices_switch $i
                        done
                    fi
                    ;;
                x)
                    for i in ${keys[*]}; do
                        choices[$i]="*"
                        choices_switch $i
                    done
                    ;;
                s)
                    choices[s]="*"
                    break
                    ;;
                *)
                    choices_switch $SELECTION
                    ;;
            esac

            if [[ "${choices[1]}" == "*" || "${choices[3]}" == "*" || "${choices[4]}" == "*" ]]; then
                choices[0]=""
                choices_switch 0
            fi
            if [[ "${choices[6]}" == "*" || "${choices[7]}" == "*" || "${choices[8]}" == "*" ]]; then
                choices[5]=""
                choices_switch 5
            fi
            if [[ "${choices[b]}" == "*" || "${choices[c]}" == "*" ]]; then
                choices[a]=""
                choices_switch a
            fi

        else
            ERROR=" ---> 非法参数: $SELECTION"
        fi
    done
}

pve_Info_mod() {
	pve_Info_Menu
    cpu_freqs_api=''
    thread_freqs_api=''
    cpu_modes_api=''
    cpu_powers_api=''
    cpu_info_api=''

    cpu_info_cpufreqs=''
    cpu_info_threadfreqs=''
    cpu_info_cpumodes=''
    cpu_info_cpupowers=''

    row_height="17"

    cpu_freqs_degree=''
    thread_freqs_degree=''
    cpu_info_height='0'

    cpu_info_data_modes=''
    cpu_info_data_powers=''
    cpu_info_data_freqs=''
    cpu_info_data_scalings=''
    cpu_info_data_minfreqs=''
    cpu_info_data_maxfreqs=''
    cpu_info_data_threadfreqs=''
    cpu_info_data=''

    cpu_info_let_modes=''
    cpu_info_let_powers=''
    cpu_info_let_freqs=''
    cpu_info_let_scalings=''
    cpu_info_let_minfreqs=''
    cpu_info_let_maxfreqs=''
    cpu_info_let_threadfreqs=''
    cpu_info_let=''

    cpu_info_output_modes=''
    cpu_info_output_powers=''
    cpu_info_output_freqs=''
    cpu_info_output_scalings=''
    cpu_info_output_minfreqs=''
    cpu_info_output_maxfreqs=''
    cpu_info_output_threadfreqs=''
    cpu_info_output=''

    cpu_info_display=''

    sensors_info_api=''

    sensors_degree=''
    cores_degree=''
    sensors_height='0'

    core_num=''

    sensors_data_packages=''
    sensors_data_cores=''

    sensors_let_packages=''
    sensors_let_cores=''

    sensors_output_packages=''
    sensors_output_cores_1=''
    sensors_output_cores_2=''

    sensors_display=''
	sensors_gpus_display=''
	sensors_FunStates_display=''

    ups_info_api=''

    ups_degree=''
    ups_height='0'

    ups_info_display=''

    nvme_info_api=''
    nvme_degree=''
    nvme_height='0'
    nvme_info_display=''

    storage_info_api=''
    storage_degree=''
    storage_height='0'
    storage_info_display=''

    nand_info_api=''
    nand_degree=''
    nand_height='0'
    nand_info_display=''

    if [[ "${choices[0]}" == "*" || "${choices[1]}" == "*" || "${choices[2]}" == "*" || "${choices[3]}" == "*" || "${choices[4]}" == "*" ]]; then
        if [[ "${choices[0]}" == "*" || "${choices[1]}" == "*" ]]; then
            cpu_freqs_api='
	my $cpufreqs = `lscpu | grep MHz`;'
            cpu_info_cpufreqs='$cpufreqs . '

            cpu_freqs_degree="$(lscpu | grep 'Model name' | wc -l)"

            cpu_info_data_freqs=',
	                    freqs: [],
	                    scalings: [],
	                    minfreqs: [],
	                    maxfreqs: []'

            cpu_info_let_freqs='
	            let freqs = cpuinfo[1].matchAll(/^CPU *MHz[^\d]+(.*)$/gm);
	            for (const freq of freqs) {
	                data[cpuNumber]['"'"'freqs'"'"'].push(freq[1]);
	            }

	            let scalings = cpuinfo[1].matchAll(/^CPU\(s\) *scaling *MHz[^\d]+(\d+).*$/gm);
	            for (const scaling of scalings) {
	                data[cpuNumber]['"'"'scalings'"'"'].push(scaling[1]);
	            }

	            let minfreqs = cpuinfo[1].matchAll(/^CPU *min *MHz[^\d]+(\d+).*$/gm);
	            for (const minfreq of minfreqs) {
	                data[cpuNumber]['"'"'minfreqs'"'"'].push(minfreq[1]);
	            }

	            let maxfreqs = cpuinfo[1].matchAll(/^CPU *max *MHz[^\d]+(\d+).*$/gm);
	            for (const maxfreq of maxfreqs) {
	                data[cpuNumber]['"'"'maxfreqs'"'"'].push(maxfreq[1]);
	            }'

            if [[ "${choices[1]}" == "*" ]]; then
                cpu_info_output_freqs='
	            if (cpuinfo.freqs.length > 0) {
	                output += `主频: `;
	                for (const cpuinfofreq of cpuinfo.freqs) {
	                    output += `实时 ${cpuinfofreq} Mhz, `;
	                }
	            } else if (cpuinfo.scalings.length > 0 && cpuinfo.maxfreqs.length > 0) {
	                output += `主频: `;
	                for (const cpuinfoscaling of cpuinfo.scalings) {
	                    var cpuscaling = `${cpuinfoscaling}`;
	                }
	                for (const cpuinfomaxfreq of cpuinfo.maxfreqs) {
	                    var cpumaxfreq = `${cpuinfomaxfreq}`;
	                }
	                var cpuinfofreq = `${cpumaxfreq}` * `${cpuscaling}` / 100;
	                output += `实时 ${cpuinfofreq} Mhz, `;
	            }

	            if (cpuinfo.minfreqs.length > 0) {
	                for (const cpuinfominfreq of cpuinfo.minfreqs) {
	                    output += `最小 ${cpuinfominfreq} Mhz, `;
	                }
	            }

	            if (cpuinfo.maxfreqs.length > 0) {
	                for (const cpuinfomaxfreq of cpuinfo.maxfreqs) {
	                    output += `最大 ${cpuinfomaxfreq} Mhz | `;
	                }
	            }'
            elif [[ "${choices[1]}" == "" ]]; then
                cpu_info_output_freqs='
	            if (cpuinfo.freqs.length > 0) {
	                for (const cpuinfofreq of cpuinfo.freqs) {
	                    output += `主频: ${cpuinfofreq} Mhz | `;
	                }
	            } else if (cpuinfo.scalings.length > 0 && cpuinfo.maxfreqs.length > 0) {
	                for (const cpuinfoscaling of cpuinfo.scalings) {
	                    var cpuscaling = `${cpuinfoscaling}`;
	                }
	                for (const cpuinfomaxfreq of cpuinfo.maxfreqs) {
	                    var cpumaxfreq = `${cpuinfomaxfreq}`;
	                }
	                var cpuinfofreq = `${cpumaxfreq}` * `${cpuscaling}` / 100;
	                output += `主频: ${cpuinfofreq} Mhz | `;
	            }'
            fi
        fi

        if [[ "${choices[2]}" == "*" ]]; then
            thread_freqs_api='
	my $threadfreqs = `cat /proc/cpuinfo | grep -i  "cpu MHz"`;'
            cpu_info_threadfreqs='$threadfreqs . '

            thread_freqs_degree="$(cat /proc/cpuinfo | grep -i "cpu MHz" | wc -l)"

            cpu_info_data_threadfreqs=',
	                    threadfreqs: []'

            cpu_info_let_threadfreqs='
	            let threadfreqs = cpuinfo[1].matchAll(/^cpu *MHz[^\d]+(.*)$/gm);
	            for (const threadfreq of threadfreqs) {
	                data[cpuNumber]['"'"'threadfreqs'"'"'].push(threadfreq[1]);
	            }'

            cpu_info_output_threadfreqs='
	            if (cpuinfo.threadfreqs.length > 0) {
	                if (output) {
	                    output += '"'"'\\n'"'"';
	                }
	                for (j = 1; j <= cpuinfo.threadfreqs.length; j++) {
	                    for (const cpuinfothreadfreq of cpuinfo.threadfreqs) {
	                        output += `线程 ${j++}: ${cpuinfothreadfreq} Mhz`;
	                        output += '"'"' | '"'"';
	                        if ((j-1) % 4 == 0){
	                            output = output.slice(0, -2);
	                            output += '"'"'\\n'"'"';
	                        }
	                    }
	                }
	            output = output.slice(0, -2);
	            }'
        fi

        if [[ "${choices[3]}" == "*" ]]; then
            cpu_modes_api='
	my $cpumodes = `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`;'
            cpu_info_cpumodes='$cpumodes . '

            cpu_info_data_modes=',
	                    modes: []'

            cpu_info_let_modes='
	            let modes = cpuinfo[1].matchAll(/^([a-z]+)$/gm);
	            for (const mode of modes) {
	                data[cpuNumber]['"'"'modes'"'"'].push(mode[1]);
	            }'
            cpu_info_output_modes='
	            if (cpuinfo.modes.length > 0) {
	                for (const cpuinfomode of cpuinfo.modes) {
	                    output += `模式: ${cpuinfomode} | `;
	                }
	            }'
        fi

        if [[ "${choices[4]}" == "*" ]]; then
            install_software 'turbostat' 'linux-cpupower'

            if [ -n $(which turbostat) ]; then
                chmod +s /usr/sbin/turbostat
            fi

            if [ -n "$(lsmod | grep -E '^msr')" ]; then
                modprobe -r msr > /dev/null 2>&1
                modprobe msr > /dev/null 2>&1
            else
                modprobe msr > /dev/null 2>&1
            fi

            if [[ ! -f "/etc/modules-load.d/turbostat-msr.conf" || `grep -c 'msr' "/etc/modules-load.d/turbostat-msr.conf"` -eq '0' ]]; then
                echo msr > /etc/modules-load.d/turbostat-msr.conf
                update-initramfs -u -k all > /dev/null 2>&1
            fi

            cpu_powers_api='
	my $cpupowers = `turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package | grep -v PkgWatt`;'
            cpu_info_cpupowers='$cpupowers . '

            cpu_info_data_powers=',
	                    powers: []'

            cpu_info_let_powers='
	            let powers = cpuinfo[1].matchAll(/^(\d(?:\d|\.)*)$/gm);
	            for (const power of powers) {
	                data[cpuNumber]['"'"'powers'"'"'].push(power[1]);
	            }'
            cpu_info_output_powers='
	            if (cpuinfo.powers.length > 0) {
	                for (const cpuinfopower of cpuinfo.powers) {
	                    output += `功率: ${cpuinfopower} W | `;
	                }
	            }'
        fi

        cpu_info_api=''${cpu_modes_api}''${cpu_powers_api}''${cpu_freqs_api}''${thread_freqs_api}'
	$res->{cpu_info} = '$(echo "${cpu_info_cpumodes}${cpu_info_cpupowers}${cpu_info_cpufreqs}${cpu_info_threadfreqs}" | sed '$s/...$//')';
'

        cpu_info_data="$(echo "${cpu_info_data_modes}${cpu_info_data_freqs}${cpu_info_data_powers}${cpu_info_data_threadfreqs}" | sed '1d')"

        cpu_info_let="$(echo "${cpu_info_let_modes}${cpu_info_let_freqs}${cpu_info_let_powers}${cpu_info_let_threadfreqs}")"

        cpu_info_output=''$(echo "${cpu_info_output_modes}${cpu_info_output_freqs}${cpu_info_output_powers}")'
	            if (output) {
	                output = output.slice(0, -2);
	            }'

        cpu_info_degree="$[cpu_freqs_degree + (thread_freqs_degree+4-1)/4]"

        cpu_info_height="$[cpu_info_degree*row_height+7]"

        cpu_info_display=',
	{
	    itemId: '"'"'cpu-info'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"'CPU'"'"'),
	    textField: '"'"'cpu_info'"'"',
	    renderer:function(value){
	        value = value.replace(/Â/g, '"'"''"'"');
	        let data = [];
	        let cpuinfos = value.matchAll(/^((?:[a-z]|(?:\d|\.)|CPU|cpu)[\s\S]*)+/gm);
	        for (const cpuinfo of cpuinfos) {
	            let cpuNumber = 0;
	            data[cpuNumber] = {
'${cpu_info_data}'
	            };
	            '${cpu_info_let}'
	        }

	        let output = '"'"''"'"';
	        for (const [i, cpuinfo] of data.entries()) {
	            '${cpu_info_output}'
	            '${cpu_info_output_threadfreqs}'
	        }
	        return output.replace(/\\n/g, '"'"'<br>'"'"');
	    }
	}'
    fi

    if [[ "${choices[5]}" == "*" || "${choices[6]}" == "*" || "${choices[7]}" == "*" || "${choices[8]}" == "*" ]]; then
        if [[ "${choices[5]}" == "*" ]]; then
            install_software 'sensors' 'lm-sensors'

            sensors-detect --auto > /tmp/tmp_sensors
            chips=`sed -n '/Chip drivers/,/\#----cut/p' /tmp/tmp_sensors|sed '/Chip /d'|sed '/cut/d'`
            if [[ `echo $chips|wc -w` -gt '0' ]]; then
                for i in $chips; do
                    modprobe $i
                    if [ `grep -c $i /etc/modules` = '0' ];then
                        echo $i >> /etc/modules
                    fi
                done
            fi
            rm -rf /tmp/tmp_sensors

            sensors_info_api='
	$res->{sensors_info} = `sensors`;
'

            sensors_degree="$(sensors | grep -E 'coretemp-isa|k10temp-pci' | wc -l)"

            sensors_data_packages=',
	                    packages: []'

            sensors_let_packages='
	            let packages = cpu[2].matchAll(/^(?:Package id \d+|Tctl):\s*\+([^°C ]+).*$/gm);
	            for (const package of packages) {
	                data[cpuNumber]['"'"'packages'"'"'].push(package[1]);
	            }'

            sensors_output_packages='
	            if (cpu.packages.length > 0) {
	                for (const packageTemp of cpu.packages) {
	                    output += `CPU ${i}: ${packageTemp}°C | `;
	                }
	            }'
        fi

        if [[ "${choices[6]}" == "*" ]]; then
            cores_degree="$(sensors | grep Core | wc -l)"

            sensors_data_cores=',
	                    cores: []'

            sensors_let_cores='
	            let cores = cpu[2].matchAll(/^Core (\d+):\s*\+([^°C ]+).*$/gm);
	            for (const core of cores) {
					var corecombi = `核心 ${core[1]}: ${core[2]}°C`
	                data[cpuNumber]['"'"'cores'"'"'].push(corecombi);
	            }'

            if [[ "$cores_degree" -gt '0' ]] && [[ "$cores_degree" -le '4' ]]; then
                sensors_output_cores_1='
	            if (cpu.cores.length > 0 && cpu.cores.length <= 4) {
	                if (cpu.packages.length > 0) {
	                    output = output.slice(0, -2);
	                    output += '"'"'('"'"';
	                }
	                for (j = 1;j < cpu.cores.length;) {
	                    for (const coreTemp of cpu.cores) {
	                        output += `${coreTemp}, `;
	                        j++;
	                    }
	                }
	                output = output.slice(0, -2);
	                if (cpu.packages.length > 0) {
	                    output += '"'"') | '"'"';
	                }
                } else {
	                output = output.slice(0, -2);
	            }'
            elif [[ "$cores_degree" -gt '4' ]]; then
                sensors_output_cores_2='
	            if (cpu.cores.length > 4) {
	                output += '"'"'\\n'"'"';
	                for (j = 1;j < cpu.cores.length;) {
	                    for (const coreTemp of cpu.cores) {
	                        output += `${coreTemp} | `;
	                        j++;
	                        if ((j-1) % 4 == 0){
	                            output = output.slice(0, -2);
	                            output += '"'"'\\n'"'"';
	                        }
	                    }
	                }
	                output = output.slice(0, -2);
	            }'
            fi
        fi

        if [[ "${choices[7]}" == "*" ]]; then
            sensors_gpus_display='
	            let gpus = value.matchAll(/^amdgpu-pci-(\w*)$\\n((?!edge:)[ \S]*?\\n)*((?:edge)[\s\S]*?^\\n)+/gm);
	            for (const gpu of gpus) {
	                let gpuNumber = 0;
	                data[gpuNumber] = {
	                    edges: []
	                };

	                let edges = gpu[3].matchAll(/^edge:\s*\+([^°C ]+).*$/gm);
	                for (const edge of edges) {
	                    data[gpuNumber]['"'"'edges'"'"'].push(edge[1]);
	                }

	                for (const [k, gpu] of data.entries()) {
	                    if (gpu.edges.length > 0) {
	                        output += '"'"'核显: '"'"';
	                        for (const edgeTemp of gpu.edges) {
	                            output += `${edgeTemp}°C, `;
	                        }
	                        output = output.slice(0, -2);
	                        output += '"'"' | '"'"';
	                    } else {
	                        output = output.slice(0, -2);
	                    }
	                }
	            }
'
        fi

        if [[ "${choices[8]}" == "*" ]]; then
            sensors_FunStates_display='
	            let FunStates = value.matchAll(/^(?:[a-zA-z]{2,3}\d{4}|dell_smm)-isa-(\w{4})$\\n((?![ \S]+: *\d+ +RPM)[ \S]*?\\n)*((?:[ \S]+: *\d+ RPM)[\s\S]*?^\\n)+/gm);
	            for (const FunState of FunStates) {
	                let FanNumber = 0;
	                data[FanNumber] = {
	                    rotationals: [],
	                    cpufans: [],
	                    motherboardfans: [],
	                    pumpfans: [],
	                    systemfans: []
	                };

	                let rotationals = FunState[3].match(/^([ \S]+: *[0-9]\d* +RPM)[ \S]*?$/gm);
	                for (const rotational of rotationals) {
	                    if (rotational.toLowerCase().indexOf("pump") !== -1 || rotational.toLowerCase().indexOf("opt") !== -1){
	                        let pumpfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
	                        for (const pumpfan of pumpfans) {
	                            data[FanNumber]['"'"'pumpfans'"'"'].push(pumpfan[1]);
	                        }
	                    } else if (rotational.toLowerCase().indexOf("cpu") !== -1 || rotational.toLowerCase().indexOf("processor") !== -1){
	                        let cpufans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
	                        for (const cpufan of cpufans) {
	                            data[FanNumber]['"'"'cpufans'"'"'].push(cpufan[1]);
	                        }
	                    } else if (rotational.toLowerCase().indexOf("motherboard") !== -1){
	                        let motherboardfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
	                        for (const motherboardfan of motherboardfans) {
	                            data[FanNumber]['"'"'motherboardfans'"'"'].push(motherboardfan[1]);
	                        }
	                    }  else {
	                        let systemfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
	                        for (const systemfan of systemfans) {
	                            data[FanNumber]['"'"'systemfans'"'"'].push(systemfan[1]);
	                        }
	                    }
	                }

	                for (const [j, FunState] of data.entries()) {
	                    if (FunState.cpufans.length > 0 || FunState.motherboardfans.length > 0 || FunState.pumpfans.length > 0 || FunState.systemfans.length > 0) {
	                        output += '"'"'风扇: '"'"';
	                        if (FunState.cpufans.length > 0) {
	                            output += '"'"'CPU-'"'"';
	                            for (const cpufan_value of FunState.cpufans) {
	                                output += `${cpufan_value}转/分钟, `;
	                            }
	                        }
	
	                        if (FunState.motherboardfans.length > 0) {
	                            output += '"'"'主板-'"'"';
	                            for (const motherboardfan_value of FunState.motherboardfans) {
	                                output += `${motherboardfan_value}转/分钟, `;
	                            }
	                        }

	                        if (FunState.pumpfans.length > 0) {
	                            output += '"'"'水冷-'"'"';
	                            for (const pumpfan_value of FunState.pumpfans) {
	                                output += `${pumpfan_value}转/分钟, `;
	                            }
	                        }

	                        if (FunState.systemfans.length > 0) {
	                            if (FunState.cpufans.length > 0 || FunState.pumpfans.length > 0) {
	                                output += '"'"'系统-'"'"';
	                            }
	                            for (const systemfan_value of FunState.systemfans) {
	                                output += `${systemfan_value}转/分钟, `;
	                            }
	                        }
	                        output = output.slice(0, -2);
	                        output += '"'"' | '"'"';
	                    } else if (FunState.cpufans.length == 0 && FunState.pumpfans.length == 0 && FunState.systemfans.length == 0) {
	                        output += '"'"' 风扇: 停转'"'"';
	                        output += '"'"' | '"'"';
                        } else {
	                        output = output.slice(0, -2);
	                    }
	                }
	            }'
        fi

        sensors_data="$(echo "${sensors_data_packages}${sensors_data_cores}" | sed '1d')"

        sensors_let="$(echo "${sensors_let_packages}${sensors_let_cores}")"

        if [[ "$cores_degree" -gt '4' ]]; then
            sensors_degree="$[sensors_degree + (cores_degree+4-1)/4]"
        fi

        sensors_height="$[sensors_degree*row_height+7]"

        sensors_display=',
	{
	    itemId: '"'"'sensors-info'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"'传感器'"'"'),
	    textField: '"'"'sensors_info'"'"',
	    renderer: function(value) {
	        value = value.replace(/Â/g, '"'"''"'"');
	        let data = [];
	        let cpus = value.matchAll(/^(?:coretemp-isa|k10temp-pci)-(\w{4})$\\n.*?\\n((?:Package|Core|Tctl)[\s\S]*?^\\n)+/gm);
	        for (const cpu of cpus) {
	            let cpuNumber = parseInt(cpu[1], 10);
	            data[cpuNumber] = {
'${sensors_data}'
	            };
	            '${sensors_let}'
	        }

	        let output = '"'"''"'"';
	        for (const [i, cpu] of data.entries()) {
'${sensors_output_packages}'
'${sensors_output_cores_1}'
'${sensors_gpus_display}'
	            let acpitzs = value.matchAll(/^acpitz-acpi-(\d*)$\\n.*?\\n((?:temp)[\s\S]*?^\\n)+/gm);
	            for (const acpitz of acpitzs) {
	                let acpitzNumber = parseInt(acpitz[1], 10);
	                data[acpitzNumber] = {
	                    acpisensors: []
	                };

	                let acpisensors = acpitz[2].matchAll(/^temp\d+:\s*\+([^°C ]+).*$/gm);
	                for (const acpisensor of acpisensors) {
	                    data[acpitzNumber]['"'"'acpisensors'"'"'].push(acpisensor[1]);
	                }

	                for (const [k, acpitz] of data.entries()) {
	                    if (acpitz.acpisensors.length > 0) {
	                        output += '"'"'主板: '"'"';
	                        for (const acpiTemp of acpitz.acpisensors) {
	                            output += `${acpiTemp}°C, `;
	                        }
	                        output = output.slice(0, -2);
	                        output += '"'"' | '"'"';
	                    } else {
	                        output = output.slice(0, -2);
	                    }
	                }
	            }
'${sensors_FunStates_display}'
	            output = output.slice(0, -2);
'${sensors_output_cores_2}'
	            output += '"'"'\\n'"'"';
	        }

	        output = output.slice(0, -2);
	        return output.replace(/\\n/g, '"'"'<br>'"'"');
	    }
	}'
    fi

    if [[ "${choices[9]}" ]]; then
        install_software 'apcaccess' 'apcupsd'

        if [ -n $(which apcaccess) ]; then
            chmod +s /usr/sbin/apcaccess
        fi

        ups_info_api='
	$res->{ups_apcaccess} = `apcaccess|grep -E "STARTTIME|MODEL|STATUS|LINEV|BATTDATE|BCHARGE|LOADPCT|TIMELEFT|NUMXFERS|MBATTCHG|SENSE|BATTV|NOMPOWER"`;
'

        if [ ! $(apcaccess|grep -E "NOMPOWER" | awk '{print $3}') ]; then
            while :
            do
                read -r -p "请输入 UPS 的额定功率 (输入正整数, 单位: W; 输入 skip 跳过): " selectUPSNorPower
                case ${selectUPSNorPower} in
                    skip)
                        UPSNorPower=""
                        echoContent green " ---> 跳过"
                        ups_LoadPower_info_display=''
                        break
                        ;;
                    *)
                        if [[ "${selectUPSNorPower}" -gt '0' ]]; then
                            UPSNorPower="${selectUPSNorPower}"
                            echoContent green " ---> UPS 的额定功率：${UPSNorPower}W"
                            break
                        else
                            echoContent red " ---> UPS 的额定功率输入错误, 请重新输入"
                        fi
                        ;;
                esac
            done
        else
            UPSNorPower="$(apcaccess|grep -E "NOMPOWER" | awk '{print $3}')"
        fi

        ups_degree="2"

        ups_height="$[ups_degree*row_height+7]"

        ups_info_display=',
	{
	    itemId: '"'"'ups-apcaccess'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"'UPS 信息'"'"'),
	    textField: '"'"'ups_apcaccess'"'"',
	    renderer: function(value) {
	        if (value.length > 0) {
	            value = value.replace(/Â/g, '"'"''"'"');
	            let data = [];
	            let upses = value.matchAll(/(^(?:STARTTIME|MODEL|STATUS|LINEV|BATTDATE|BCHARGE|LOADPCT|TIMELEFT|NUMXFERS|MBATTCHG|SENSE|BATTV|NOMPOWER)[\s\S]*)+/gm);
	            for (const ups of upses) {
	                let upsNumber = 0;
	                data[upsNumber] = {
	                    Starttimes: [],
	                    Models: [],
	                    Statuses: [],
	                    Nompowers: [],
	                    Linevs: [],
	                    Loadpctes: [],
	                    Senses: [],
	                    Bcharges: [],
	                    Mbattchges: [],
	                    Timeleftes: [],
	                    Numxferses: [],
	                    Battvs: [],
	                    Battdates: []
	                };

	                let Models = ups[1].matchAll(/^MODEL *: *(.*)$/gm);
	                for (const Model of Models) {
	                    data[upsNumber]['"'"'Models'"'"'].push(Model[1]);
	                }

	                let Statuses = ups[1].matchAll(/^STATUS(?: |:)+(.*)$/gm);
	                for (const Status of Statuses) {
	                    data[upsNumber]['"'"'Statuses'"'"'].push(Status[1]);
	                }

	                let Nompowers = ups[1].matchAll(/^NOMPOWER *: *( \d+(?:\.\d*)?).*$/gm);
	                for (const Nompower of Nompowers) {
	                    data[upsNumber]['"'"'Nompowers'"'"'].push(Nompower[1]);
	                }

	                let Loadpctes = ups[1].matchAll(/^LOADPCT *: *( \d+(?:\.\d*)?).*$/gm);
	                for (const Loadpct of Loadpctes) {
	                    data[upsNumber]['"'"'Loadpctes'"'"'].push(Loadpct[1]);
	                }

	                let Linevs = ups[1].matchAll(/^LINEV *: *( \d+(?:\.\d*)?).*$/gm);
	                for (const Linev of Linevs) {
	                    data[upsNumber]['"'"'Linevs'"'"'].push(Linev[1]);
	                }

	                let Senses = ups[1].matchAll(/^SENSE(?: |:)+(.*)$/gm);
	                for (const Sense of Senses) {
	                    data[upsNumber]['"'"'Senses'"'"'].push(Sense[1]);
	                }

	                let Starttimes = ups[1].matchAll(/^STARTTIME *: *(.*) \+.*$/gm);
	                for (const Starttime of Starttimes) {
	                    data[upsNumber]['"'"'Starttimes'"'"'].push(Starttime[1]);
	                }
	
	                let Bcharges = ups[1].matchAll(/^BCHARGE *: *( \d+(?:\.\d*)?).*$/gm);
	                for (const Bcharge of Bcharges) {
	                    data[upsNumber]['"'"'Bcharges'"'"'].push(Bcharge[1]);
	                }
	
	                let Mbattchges = ups[1].matchAll(/^MBATTCHG *: *( \d+(?:\.\d*)?).*$/gm);
	                for (const Mbattchg of Mbattchges) {
	                    data[upsNumber]['"'"'Mbattchges'"'"'].push(Mbattchg[1]);
	                }
	
	                let Timeleftes = ups[1].matchAll(/^TIMELEFT *: *( \d+(?:\.\d*)?).*$/gm);
	                for (const Timeleft of Timeleftes) {
	                    data[upsNumber]['"'"'Timeleftes'"'"'].push(Timeleft[1]);
	                }
	
	                let Numxferses = ups[1].matchAll(/^NUMXFERS *: *( \d+(?:\.\d*)?).*$/gm);
	                for (const Numxfers of Numxferses) {
	                    data[upsNumber]['"'"'Numxferses'"'"'].push(Numxfers[1]);
	                }

	                let Battvs = ups[1].matchAll(/^BATTV *: *( \d+(?:\.\d*)?).*$/gm);
	                for (const Battv of Battvs) {
	                    data[upsNumber]['"'"'Battvs'"'"'].push(Battv[1]);
	                }
	
	                let Battdates = ups[1].matchAll(/^BATTDATE *: *(\d{4}-\d{2}-\d{2})$/gm);
	                for (const Battdate of Battdates) {
	                    data[upsNumber]['"'"'Battdates'"'"'].push(Battdate[1]);
	                }
	
	                let output = '"'"''"'"';
	                for (const [i, ups] of data.entries()) {
	                    if (ups.Models.length > 0) {
	                        for (const upsModel of ups.Models) {
	                            output += `${upsModel}`;
	                        }
	
	                        if (ups.Statuses.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const upsStatus of ups.Statuses) {
	                                if (upsStatus.indexOf("ONLINE") !== -1){
	                                    output += `状态: ${upsStatus.replace(/ONLINE/gm, '"'"'在线'"'"')}`;
	                                } else if (upsStatus.indexOf("COMMLOST") !== -1){
	                                    output += `状态: ${upsStatus.replace(/COMMLOST/gm, '"'"'离线'"'"')}`;
	                                }
	                            }
	                        }
	
	                        if (ups.Senses.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const upsSense of ups.Senses) {
	                                output += '"'"'灵敏度: '"'"';
	                                if (upsSense.indexOf("Low") !== -1){
	                                    output += `${upsSense.replace(/Low/gm, '"'"'低'"'"')}`;
	                                } else if (upsSense.indexOf("Medium") !== -1){
	                                    output += `${upsSense.replace(/Medium/gm, '"'"'中'"'"')}`;
	                                } else if (upsSense.indexOf("High") !== -1){
	                                    output += `${upsSense.replace(/High/gm, '"'"'高'"'"')}`;
	                                }
	                            }
	                        }
	
	                        if (ups.Loadpctes.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const upsLoadpct of ups.Loadpctes) {
	                                output += `负载: ${upsLoadpct}%`;
	                                if (ups.Nompowers.length > 0) {
	                                    if (ups.Nompowers.length > 0) {
	                                        for (const upsNompower of ups.Nompowers) {
	                                            var NormPower = `${upsNompower}`;
	                                            var upsLoadPower = `${NormPower}` * `${upsLoadpct}` / 100;
	                                            output += `, ${upsLoadPower}W`;
	                                        }
	                                    }
	                                } else {
	                                    var NormPower = '"'"''${UPSNorPower}''"'"';
	                                    if (NormPower.length > 0) {
	                                        var upsLoadPower = `${NormPower}` * `${upsLoadpct}` / 100;
	                                        output += `, ${upsLoadPower}W`;
	                                    }
	                                }
	                            }
	                        }
	
	                        if (ups.Linevs.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const upsLinev of ups.Linevs) {
	                                output += `市电电压: ${upsLinev}V`;
	                            }
	                        }
	
	                        if (ups.Starttimes.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const upsStarttime of ups.Starttimes) {
	                                output += `启动时间: ${upsStarttime}`;
	                            }
	                        }
	
	                        if (ups.Bcharges.length > 0) {
	                            output += '"'"'\\n电池: '"'"';
	                            for (const upsBcharge of ups.Bcharges) {
	                                output += `当前电量: ${upsBcharge}%`;
	                            }
	                        }
	
	                        if (ups.Mbattchges.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const upsMbattchg of ups.Mbattchges) {
	                                output += `关机电量: ${upsMbattchg}%`;
	                            }
	                        }
	
	                        if (ups.Timeleftes.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const upsTimeleft of ups.Timeleftes) {
	                                output += `剩余时间: ${upsTimeleft}分钟`;
	                            }
	                        }
	
	                        if (ups.Numxferses.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const upsNumxfers of ups.Numxferses) {
	                                output += `停电次数: ${upsNumxfers}次`;
	                            }
	                        }
	
	                        if (ups.Battvs.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const upsBattv of ups.Battvs) {
	                                output += `电池电压: ${upsBattv}V`;
	                            }
	                        }
	
	                        if (ups.Battdates.length > 0) {
	                            output += '"'"' | '"'"';
	                            for (const upsBattdate of ups.Battdates) {
	                                output += `换电日期: ${upsBattdate}`;
	                            }
	                        }
	                    } else {
	                        output += `提示: 未连接 UPS ！`;
	                    }
	                }
	                return output.replace(/\\n/g, '"'"'<br>'"'"');
	            }
	        } else {
	            return `提示: 未连接 UPS ！`;
	        }
	    }
	}'
	else
        remove_software 'apcaccess' 'apcupsd'
    fi

    if [[ "${choices[a]}" == "*" || "${choices[b]}" == "*" || "${choices[c]}" == "*" ]]; then
        if [[ "${choices[a]}" == "*" || "${choices[b]}" == "*" ]]; then
            if [ -n $(which smartctl) ]; then
                chmod +s /usr/sbin/smartctl
            fi
        fi

        if [[ "${choices[c]}" == "*" ]]; then
            install_software 'iostat' 'sysstat'
        fi

        if [ $(ls /dev/nvme? 2> /dev/null | wc -l) -gt '0' ]; then
            i="1"
            for nvme_device in $(ls -1 /dev/nvme?); do
                nvme_code=${nvme_device##*/}

                nvme_info_api_code='
	my '$(eval echo "\\$'$nvme_code'_info")' = `smartctl -a '$nvme_device' | grep -E "Model Number|(?=Total|Namespace)[^:]+Capacity|Temperature:|Available Spare:|Percentage|Data Unit|Power Cycles|Power On Hours|Unsafe Shutdowns|Integrity Errors"`;'
                eval ${nvme_code}_info_api='$nvme_info_api_code'

                eval ${nvme_code}_info='"\$'$nvme_code'_info"'

                if [[ "${choices[b]}" == "*" || "${choices[c]}" == "*" ]]; then
                    if [[ "${choices[b]}" == "*" ]]; then
                        nvme_power_data=',
	                    Cycles: [],
	                    Hours: [],
	                    Shutdowns: []'
                        nvme_power_let='
	                let Cycles = nvme[1].matchAll(/^Power Cycles: *([ \S]*)$/gm);
	                for (const Cycle of Cycles) {
	                    data[nvmeNumber]['"'"'Cycles'"'"'].push(Cycle[1]);
	                }

	                let Hours = nvme[1].matchAll(/^Power On Hours: *([ \S]*)$/gm);
	                for (const Hour of Hours) {
	                    data[nvmeNumber]['"'"'Hours'"'"'].push(Hour[1]);
	                }

	                let Shutdowns = nvme[1].matchAll(/^Unsafe Shutdowns: *([ \S]*)$/gm);
	                for (const Shutdown of Shutdowns) {
	                    data[nvmeNumber]['"'"'Shutdowns'"'"'].push(Shutdown[1]);
	                }'

                        nvme_power_output='
                        if (nvme.Cycles.length > 0) {
                            output += '"'"'\\n'"'"';
                            for (const nvmeCycle of nvme.Cycles) {
                                output += `通电: ${nvmeCycle.replace(/ |,/gm, '"'"''"'"')}次`;
                            }

                            if (nvme.Shutdowns.length > 0) {
                                output += '"'"', '"'"';
                                for (const nvmeShutdown of nvme.Shutdowns) {
                                    output += `不安全断电${nvmeShutdown.replace(/ |,/gm, '"'"''"'"')}次`;
                                    break
                                }
                            }

                            if (nvme.Hours.length > 0) {
                                output += '"'"', '"'"';
                                for (const nvmeHour of nvme.Hours) {
                                    output += `累计${nvmeHour.replace(/ |,/gm, '"'"''"'"')}小时`;
                                }
                            }
                        }'
                    else
                        nvme_power_data=''
                        nvme_power_let=''
                        nvme_power_output=''
                    fi

                    if [[ "${choices[c]}" == "*" ]]; then
                        nvme_io_api_code='
	my $'$nvme_code'_io = `iostat -d -x -k 1 1 | grep -E "^'$(eval echo '$nvme_code')'"`;'
                        eval ${nvme_code}_io_api='$nvme_io_api_code'

                        eval ${nvme_code}_io='" . \$'$nvme_code'_io"'

                        nvme_io_data=',
	                    States: [],
	                    r_kBs: [],
	                    r_awaits: [],
	                    w_kBs: [],
	                    w_awaits: [],
	                    utils: []'

                        nvme_io_let='
	                let States = nvme[1].matchAll(/^nvme\S+(( *\d+\.\d{2}){22})/gm);
	                for (const State of States) {
	                    data[nvmeNumber]['"'"'States'"'"'].push(State[1]);
	                    const IO_array = [...State[1].matchAll(/\d+\.\d{2}/g)];
	                    if (IO_array.length > 0) {
	                        data[nvmeNumber]['"'"'r_kBs'"'"'].push(IO_array[1]);
	                        data[nvmeNumber]['"'"'r_awaits'"'"'].push(IO_array[4]);
	                        data[nvmeNumber]['"'"'w_kBs'"'"'].push(IO_array[7]);
	                        data[nvmeNumber]['"'"'w_awaits'"'"'].push(IO_array[10]);
	                        data[nvmeNumber]['"'"'utils'"'"'].push(IO_array[21]);
	                    }
	                }'

                        nvme_io_output='
	                    if (nvme.States.length > 0) {
	                        if (nvme.Models.length > 0) {
	                            output += '"'"'\\n'"'"';
	                        }

	                        output += '"'"'I/O: '"'"';
	                        if (nvme.r_kBs.length > 0 || nvme.r_awaits.length > 0) {
	                            output += '"'"'读-'"'"';
	                            if (nvme.r_kBs.length > 0) {
	                                for (const nvme_r_kB of nvme.r_kBs) {
	                                    var nvme_r_mB = `${nvme_r_kB}` / 1024;
	                                    nvme_r_mB = nvme_r_mB.toFixed(2);
	                                    output += `速度${nvme_r_mB}MB/s`;
	                                }
	                            }
	                            if (nvme.r_awaits.length > 0) {
	                                for (const nvme_r_await of nvme.r_awaits) {
	                                    output += `, 延迟${nvme_r_await}ms / `;
	                                }
	                            }
	                        }

	                        if (nvme.w_kBs.length > 0 || nvme.w_awaits.length > 0) {
	                            output += '"'"'写-'"'"';
	                            if (nvme.w_kBs.length > 0) {
	                                for (const nvme_w_kB of nvme.w_kBs) {
	                                    var nvme_w_mB = `${nvme_w_kB}` / 1024;
	                                    nvme_w_mB = nvme_w_mB.toFixed(2);
	                                    output += `速度${nvme_w_mB}MB/s`;
	                                }
	                            }
	                            if (nvme.w_awaits.length > 0) {
	                                for (const nvme_w_await of nvme.w_awaits) {
	                                    output += `, 延迟${nvme_w_await}ms | `;
	                                }
	                            }
	                        }

	                        if (nvme.utils.length > 0) {
	                            for (const nvme_util of nvme.utils) {
	                                output += `负载${nvme_util}%`;
	                            }
	                        }
	                    }'
                    else
				        nvme_io_api_code=''
                        eval ${nvme_code}_io_api=''
                        eval ${nvme_code}_io=''
                        nvme_io_data=''
                        nvme_io_let=''
                        nvme_io_output=''
                    fi
                fi

                nvme_info_api_tmp=''$(eval echo \"\$${nvme_code}_info_api\")''$(eval echo \"\$${nvme_code}_io_api\")'
	$res->{'$nvme_code'_status} = '$(eval echo \"\$${nvme_code}_info\")''$(eval echo \"\$${nvme_code}_io\")';
'
                nvme_info_api="$nvme_info_api$nvme_info_api_tmp"

                if [[ "${choices[b]}" == "*" && "${choices[c]}" == "*" ]]; then
                    nvme_degree="3"
                elif [[ "${choices[b]}" == "*" || "${choices[c]}" == "*" ]]; then
                    nvme_degree="2"
                else
                    nvme_degree="1"
                fi
                nvme_tmp_height="$[nvme_degree*row_height+7]"
                nvme_height="$[nvme_height + nvme_tmp_height]"

                nvme_info_display_tmp=',
	{
	    itemId: '"'"''$nvme_code'-status'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"'NVME '$i''"'"'),
	    textField: '"'"''$nvme_code'_status'"'"',
	    renderer:function(value){
	        if (value.length > 0) {
	            value = value.replace(/Â/g, '"'"''"'"');
	            let data = [];
	            let nvmes = value.matchAll(/(^(?:Model|Total|Temperature:|Available Spare:|Percentage|Data|Power|Unsafe|Integrity Errors|nvme)[\s\S]*)+/gm);
	            for (const nvme of nvmes) {
	                let nvmeNumber = 0;
	                data[nvmeNumber] = {
	                    Models: [],
	                    Integrity_Errors: [],
	                    Capacitys: [],
	                    Temperatures: [],
	                    Available_Spares: [],
	                    Useds: [],
	                    Reads: [],
	                    Writtens: []'$nvme_power_data''$nvme_io_data'
	                };

	                let Models = nvme[1].matchAll(/^Model Number: *([ \S]*)$/gm);
	                for (const Model of Models) {
	                    data[nvmeNumber]['"'"'Models'"'"'].push(Model[1]);
	                }

	                let Integrity_Errors = nvme[1].matchAll(/^Media and Data Integrity Errors: *([ \S]*)$/gm);
	                for (const Integrity_Error of Integrity_Errors) {
	                    data[nvmeNumber]['"'"'Integrity_Errors'"'"'].push(Integrity_Error[1]);
	                }

	                let Capacitys = nvme[1].matchAll(/^(?=Total|Namespace)[^:]+Capacity:[^\[]*\[([ \S]*)\]$/gm);
	                for (const Capacity of Capacitys) {
	                    data[nvmeNumber]['"'"'Capacitys'"'"'].push(Capacity[1]);
	                }

	                let Temperatures = nvme[1].matchAll(/^Temperature: *([\d]*)[ \S]*$/gm);
	                for (const Temperature of Temperatures) {
	                    data[nvmeNumber]['"'"'Temperatures'"'"'].push(Temperature[1]);
	                }

	                let Available_Spares = nvme[1].matchAll(/^Available Spare: *([\d]*%)[ \S]*$/gm);
	                for (const Available_Spare of Available_Spares) {
	                    data[nvmeNumber]['"'"'Available_Spares'"'"'].push(Available_Spare[1]);
	                }

	                let Useds = nvme[1].matchAll(/^Percentage Used: *([ \S]*)%$/gm);
	                for (const Used of Useds) {
	                    data[nvmeNumber]['"'"'Useds'"'"'].push(Used[1]);
	                }

	                let Reads = nvme[1].matchAll(/^Data Units Read:[^\[]*\[([ \S]*)\]$/gm);
	                for (const Read of Reads) {
	                    data[nvmeNumber]['"'"'Reads'"'"'].push(Read[1]);
	                }

	                let Writtens = nvme[1].matchAll(/^Data Units Written:[^\[]*\[([ \S]*)\]$/gm);
	                for (const Written of Writtens) {
	                    data[nvmeNumber]['"'"'Writtens'"'"'].push(Written[1]);
	                }
'$nvme_power_let'
'$nvme_io_let'

	                let output = '"'"''"'"';
	                for (const [i, nvme] of data.entries()) {
	                    if (nvme.Models.length > 0) {
	                        for (const nvmeModel of nvme.Models) {
	                            output += `${nvmeModel}`;
	                        }
	                    }

	                    if (nvme.Integrity_Errors.length > 0) {
	                        for (const nvmeIntegrity_Error of nvme.Integrity_Errors) {
	                            if (nvmeIntegrity_Error != 0) {
	                                output += ` (`;
	                                output += `0E: ${nvmeIntegrity_Error}-故障！`;
	                                if (nvme.Available_Spares.length > 0) {
	                                    output += '"'"', '"'"';
	                                    for (const Available_Spare of nvme.Available_Spares) {
	                                        output += `备用空间: ${Available_Spare}`;
	                                    }
	                                }
	                                output += `)`;
	                            }
	                        }
	                    }

	                    if (nvme.Capacitys.length > 0) {
	                        output += '"'"' | '"'"';
	                        for (const nvmeCapacity of nvme.Capacitys) {
	                            output += `容量: ${nvmeCapacity.replace(/ |,/gm, '"'"''"'"')}`;
	                        }
	                    }

	                    if (nvme.Useds.length > 0) {
	                        output += '"'"' | '"'"';
	                        for (const nvmeUsed of nvme.Useds) {
	                            output += `寿命: ${100-Number(nvmeUsed)}% `;
	                            if (nvme.Reads.length > 0) {
	                                output += '"'"'('"'"';
	                                for (const nvmeRead of nvme.Reads) {
	                                    output += `已读${nvmeRead.replace(/ |,/gm, '"'"''"'"')}`;
	                                    output += '"'"')'"'"';
	                                }
	                            }

	                            if (nvme.Writtens.length > 0) {
	                                output = output.slice(0, -1);
	                                output += '"'"', '"'"';
	                                for (const nvmeWritten of nvme.Writtens) {
	                                    output += `已写${nvmeWritten.replace(/ |,/gm, '"'"''"'"')}`;
	                                }
	                                output += '"'"')'"'"';
	                            }
	                        }
	                    }

	                    if (nvme.Temperatures.length > 0) {
	                        output += '"'"' | '"'"';
	                        for (const nvmeTemperature of nvme.Temperatures) {
	                            output += `温度: ${nvmeTemperature}°C`;
	                        }
	                    }
'$nvme_io_output'
'$nvme_power_output'
	                    //output = output.slice(0, -3);
	                }
	                return output.replace(/\\n/g, '"'"'<br>'"'"');
	            }
	        } else {
	            return `提示: 未安装 NVME 或已直通 NVME 控制器！`;
	        }
	    }
	}'
                nvme_info_display="$nvme_info_display$nvme_info_display_tmp"

                i=$((i + 1))
            done
        fi

        if [ $(ls /dev/sd? 2> /dev/null | wc -l) -gt '0' ]; then
            i="1"
            j="1"
            for storage_device in $(ls -1 /dev/sd?); do
                storage_code=${storage_device##*/}
                nand_code=${storage_device##*/}

                nand_io_api_code=''
                eval ${nand_code}_io_api=''
                eval ${nand_code}_io=''

                storage_io_api_code=''
                eval ${storage_code}_io_api=''
                eval ${storage_code}_io=''
                storage_io_data=''
                storage_io_let=''
                storage_io_output=''

                if [[ "${choices[c]}" == "*" && -z "$(smartctl -a "$storage_device" | grep -E "Model|^Vendor|^Product")" && -n "$(iostat -d -x -k 1 1 | grep -E "^$nand_code")" ]]; then
                    nand_io_api_code='
	my $'$nand_code'_io = `iostat -d -x -k 1 1 | grep -E "^'$(eval echo '$nand_code')'"`;'
                    eval ${nand_code}_io_api='$nand_io_api_code'

                    eval ${nand_code}_io='"\$'$nand_code'_io"'

                    nand_info_api_tmp=''$(eval echo \"\$${nand_code}_io_api\")'
	$res->{'$nand_code'_status} = '$(eval echo \"\$${nand_code}_io\")';
'
                        nand_info_api="$nand_info_api$nand_info_api_tmp"

                    nand_degree="1"
                    nand_tmp_height="$[nand_degree*row_height+7]"
                    nand_height="$[nand_height + nand_tmp_height]"

                    nand_info_display_tmp=',
	{
	    itemId: '"'"''$nand_code'-status'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"'闪存 '$j''"'"'),
	    textField: '"'"''$nand_code'_status'"'"',
	    renderer:function(value){
	        if (value.length > 0) {
	            value = value.replace(/Â/g, '"'"''"'"');
	            let data = [];
	            let nands = value.matchAll(/^((?:Device|Model|User|[ ]{0,2}\d|sd)[\s\S]*)+/gm);
	            for (const nand of nands) {
	                let nandNumber = 0;
	                data[nandNumber] = {
	                    States: [],
	                    r_kBs: [],
	                    r_awaits: [],
	                    w_kBs: [],
	                    w_awaits: [],
	                    utils: []
	                };

	                let States = nand[1].matchAll(/^sd\S+(( *\d+\.\d{2}){22})/gm);
	                for (const State of States) {
	                    data[nandNumber]['"'"'States'"'"'].push(State[1]);
	                    const IO_array = [...State[1].matchAll(/\d+\.\d{2}/g)];
	                    if (IO_array.length > 0) {
	                        data[nandNumber]['"'"'r_kBs'"'"'].push(IO_array[1]);
	                        data[nandNumber]['"'"'r_awaits'"'"'].push(IO_array[4]);
	                        data[nandNumber]['"'"'w_kBs'"'"'].push(IO_array[7]);
	                        data[nandNumber]['"'"'w_awaits'"'"'].push(IO_array[10]);
	                        data[nandNumber]['"'"'utils'"'"'].push(IO_array[21]);
	                    }
	                }

	                let output = '"'"''"'"';
					for (const [i, nand] of data.entries()) {
	                    if (nand.States.length > 0) {
	                        output += '"'"'I/O: '"'"';
	                        if (nand.r_kBs.length > 0 || nand.r_awaits.length > 0) {
	                            output += '"'"'读-'"'"';
	                            if (nand.r_kBs.length > 0) {
	                                for (const nand_r_kB of nand.r_kBs) {
	                                    var nand_r_mB = `${nand_r_kB}` / 1024;
	                                    nand_r_mB = nand_r_mB.toFixed(2);
	                                    output += `速度${nand_r_mB}MB/s`;
	                                }
	                            }
	                            if (nand.r_awaits.length > 0) {
	                                for (const nand_r_await of nand.r_awaits) {
	                                    output += `, 延迟${nand_r_await}ms / `;
	                                }
	                            }
	                        }

	                        if (nand.w_kBs.length > 0 || nand.w_awaits.length > 0) {
	                            output += '"'"'写-'"'"';
	                            if (nand.w_awaits.length > 0) {
	                                for (const nand_w_kB of nand.w_kBs) {
	                                    var nand_w_mB = `${nand_w_kB}` / 1024;
	                                    nand_w_mB = nand_w_mB.toFixed(2);
	                                    output += `速度${nand_w_mB}MB/s`;
	                                }
	                                for (const nand_w_await of nand.w_awaits) {
	                                    output += `, 延迟${nand_w_await}ms | `;
	                                }
	                            }
	                        }

	                        if (nand.utils.length > 0) {
	                            for (const nand_util of nand.utils) {
	                                output += `负载${nand_util}%`;
	                            }
	                        }
	                    }
	                    //output = output.slice(0, -3);
	                }
	                return output.replace(/\\n/g, '"'"'<br>'"'"');
	            }
	        } else {
	            return `提示: 未安装闪存或已直通闪存控制器！`;
	        }
	    }
	}'

                    nand_info_display="$nand_info_display$nand_info_display_tmp"

                    j=$((j + 1))
                else
                    storage_info_api_code='
	my '$(eval echo "\\$'$storage_code'_info")' = `smartctl -a '$storage_device' | grep -E "Model|Vendor|Product|Capacity|Power_On_Hours|Power_Cycle_Count|Power-Off_Retract_Count|Unexpected_Power_Loss|Unexpect_Power_Loss_Ct|POR_Recovery|Temperature|Accumulated"`;'
                    eval ${storage_code}_info_api='$storage_info_api_code'

                    eval ${storage_code}_info='"\$'$storage_code'_info"'

                    if [[ "${choices[b]}" == "*" || "${choices[c]}" == "*" ]]; then
                        if [[ "${choices[b]}" == "*" ]]; then
                            storage_power_data=',
	                    Cycles: [],
	                    Hours: [],
	                    Shutdowns: []'

                            storage_power_let='
	                let Cycles = device[1].matchAll(/(?:Cycle|load-unload cycles)[ \S]*(?:\-|In_the_past|:) *?(\d+)[ \S]*$/gm);
	                for (const Cycle of Cycles) {
	                    data[deviceNumber]['"'"'Cycles'"'"'].push(Cycle[1]);
	                }

	                let Hours = device[1].matchAll(/(?:Hours|hours)[ \S]*(?:\-|In_the_past|:[^\d]+) *?(\d+)[ \S]*$/gm);
	                for (const Hour of Hours) {
	                    data[deviceNumber]['"'"'Hours'"'"'].push(Hour[1]);
	                }

	                let Shutdowns = device[1].matchAll(/(?:Retract|Loss|POR_Recovery|start-stop cycles)[ \S]*(?:\-|In_the_past|:) *?(\d+)[ \S]*$/gm);
	                for (const Shutdown of Shutdowns) {
	                    data[deviceNumber]['"'"'Shutdowns'"'"'].push(Shutdown[1]);
	                }'

                            storage_power_output='
	                    if (device.Cycles.length > 0) {
	                        output += '"'"'\\n'"'"';
	                        for (const deviceCycle of device.Cycles) {
	                            output += `通电: ${deviceCycle.replace(/ |,/gm, '"'"''"'"')}次`;
	                        }

	                        if (device.Shutdowns.length > 0) {
	                            output += '"'"', '"'"';
	                            for (const deviceShutdown of device.Shutdowns) {
	                                output += `不安全断电${deviceShutdown.replace(/ |,/gm, '"'"''"'"')}次`;
	                                break
	                            }
	                        }

	                        if (device.Hours.length > 0) {
	                            output += '"'"', '"'"';
	                            for (const deviceHour of device.Hours) {
	                                output += `累计${deviceHour.replace(/ |,/gm, '"'"''"'"')}小时`;
	                            }
	                        }
	                    }'
                        else
                            storage_power_data=''
                            storage_power_let=''
                            storage_power_output=''
                        fi

                        if [[ "${choices[c]}" == "*" ]]; then
                            storage_io_api_code='
	my $'$storage_code'_io = `iostat -d -x -k 1 1 | grep -E "^'$(eval echo '$storage_code')'"`;'
                            eval ${storage_code}_io_api='$storage_io_api_code'

                            eval ${storage_code}_io='" . \$'$storage_code'_io"'

                            storage_io_data=',
	                    States: [],
	                    r_kBs: [],
	                    r_awaits: [],
	                    w_kBs: [],
	                    w_awaits: [],
	                    utils: []'

                            storage_io_let='
	                let States = device[1].matchAll(/^sd\S+(( *\d+\.\d{2}){22})/gm);
	                for (const State of States) {
	                    data[deviceNumber]['"'"'States'"'"'].push(State[1]);
	                    const IO_array = [...State[1].matchAll(/\d+\.\d{2}/g)];
	                    if (IO_array.length > 0) {
	                        data[deviceNumber]['"'"'r_kBs'"'"'].push(IO_array[1]);
	                        data[deviceNumber]['"'"'r_awaits'"'"'].push(IO_array[4]);
	                        data[deviceNumber]['"'"'w_kBs'"'"'].push(IO_array[7]);
	                        data[deviceNumber]['"'"'w_awaits'"'"'].push(IO_array[10]);
	                        data[deviceNumber]['"'"'utils'"'"'].push(IO_array[21]);
	                    }
	                }'

                            storage_io_output='
	                    if (device.States.length > 0) {
	                        if (device.Models.length > 0) {
	                            output += '"'"'\\n'"'"';
	                        }

	                        output += '"'"'I/O: '"'"';
	                        if (device.r_kBs.length > 0 || device.r_awaits.length > 0) {
	                            output += '"'"'读-'"'"';
	                            if (device.r_kBs.length > 0) {
	                                for (const device_r_kB of device.r_kBs) {
	                                    var device_r_mB = `${device_r_kB}` / 1024;
	                                    device_r_mB = device_r_mB.toFixed(2);
	                                    output += `速度${device_r_mB}MB/s`;
	                                }
	                            }
	                            if (device.r_awaits.length > 0) {
	                                for (const device_r_await of device.r_awaits) {
	                                    output += `, 延迟${device_r_await}ms / `;
	                                }
	                            }
	                        }

	                        if (device.w_kBs.length > 0 || device.w_awaits.length > 0) {
	                            output += '"'"'写-'"'"';
	                            if (device.w_awaits.length > 0) {
	                                for (const device_w_kB of device.w_kBs) {
	                                    var device_w_mB = `${device_w_kB}` / 1024;
	                                    device_w_mB = device_w_mB.toFixed(2);
	                                    output += `速度${device_w_mB}MB/s`;
	                                }
	                                for (const device_w_await of device.w_awaits) {
	                                    output += `, 延迟${device_w_await}ms | `;
	                                }
	                            }
	                        }

	                        if (device.utils.length > 0) {
	                            for (const device_util of device.utils) {
	                                output += `负载${device_util}%`;
	                            }
	                        }
	                    }'
                        fi
                    fi

                    storage_info_api_tmp=''$(eval echo \"\$${storage_code}_info_api\")''$(eval echo \"\$${storage_code}_io_api\")'
	$res->{'$storage_code'_status} = '$(eval echo \"\$${storage_code}_info\")''$(eval echo \"\$${storage_code}_io\")';
'
                    storage_info_api="$storage_info_api$storage_info_api_tmp"

                    storage_name="其他存储"

                    if [[ ! -z $(smartctl -a "$storage_device" | grep -E "Model|^Vendor|^Product") ]]; then
                        storage_name="硬盘"
                        if [[ "${choices[b]}" == "*" && "${choices[c]}" == "*" ]]; then
                            storage_degree="3"
                        elif [[ "${choices[b]}" == "*" || "${choices[c]}" == "*" ]]; then
                            storage_degree="2"
                        else
                            storage_degree="1"
                        fi
                    fi

                    storage_tmp_height="$[storage_degree*row_height+7]"
                    storage_height="$[storage_height + storage_tmp_height]"

                    storage_info_display_tmp=',
	{
	    itemId: '"'"''$storage_code'-status'"'"',
	    colspan: 2,
	    printBar: false,
	    title: gettext('"'"''$storage_name' '$i''"'"'),
	    textField: '"'"''$storage_code'_status'"'"',
	    renderer:function(value){
	        if (value.length > 0) {
	            value = value.replace(/Â/g, '"'"''"'"');
	            let data = [];
	            let devices = value.matchAll(/^((?:Device|Model|Vendor|Product|User|[ ]{0,2}\d|sd)[\s\S]*)+/gm);
	            for (const device of devices) {
	                let deviceNumber = 0;
	                data[deviceNumber] = {
	                    Models: [],
	                    Capacitys: [],
	                    Temperatures: []'$storage_power_data''$storage_io_data'
	                };

	                if(device[1].indexOf("Family") !== -1 || device[1].indexOf("Vendor:") !== -1){
	                    let Models = device[1].matchAll(/^(?:Model Family|Vendor): *([ \S]*?)\\n^(?:Device Model|Product): *([ \S]*?)$/gm);
	                    for (const Model of Models) {
	                        data[deviceNumber]['"'"'Models'"'"'].push(`${Model[1]} - ${Model[2]}`);
	                    }
	                } else {
	                    let Models = device[1].matchAll(/(?:Model|Product): *([ \S]*?)$/gm);
	                    for (const Model of Models) {
	                        data[deviceNumber]['"'"'Models'"'"'].push(Model[1]);
	                    }
	                }

	                let Capacitys = device[1].matchAll(/^User Capacity:[^\[]*\[([ \S]*)\]$/gm);
	                for (const Capacity of Capacitys) {
	                    data[deviceNumber]['"'"'Capacitys'"'"'].push(Capacity[1]);
	                }

	                let Temperatures = device[1].matchAll(/Temperature[ \S]*(?:\-|In_the_past|:) *?(\d+)[ \S]*$/gm);
	                for (const Temperature of Temperatures) {
	                    data[deviceNumber]['"'"'Temperatures'"'"'].push(Temperature[1]);
	                }
'$storage_power_let'
'$storage_io_let'

	                let output = '"'"''"'"';
	                for (const [i, device] of data.entries()) {
	                    if (device.Models.length > 0) {
	                        for (const deviceModel of device.Models) {
	                            output += `${deviceModel}`;
	                        }
	                    }

	                    if (device.Capacitys.length > 0) {
	                        if (device.Models.length > 0) {
	                            output += '"'"' | '"'"';
	                      }
	                        for (const deviceCapacity of device.Capacitys) {
	                            output += `容量: ${deviceCapacity.replace(/ |,/gm, '"'"''"'"')}`;
	                        }
	                    }

	                    if (device.Temperatures.length > 0) {
	                        output += '"'"' | '"'"';
	                        for (const deviceTemperature of device.Temperatures) {
	                            output += `温度: ${deviceTemperature}°C`;
	                            break
	                        }
	                    }
'$storage_io_output'
'$storage_power_output'
	                    //output = output.slice(0, -3);
	                }
	                return output.replace(/\\n/g, '"'"'<br>'"'"');
	            }
	        } else {
	            return `提示: 未安装'$storage_name'或已直通'$storage_name'控制器！`;
	        }
	    }
	}'
                    storage_info_display="$storage_info_display$storage_info_display_tmp"

                    i=$((i + 1))
                fi
            done
        fi
    fi

    if [[ "${choices[s]}" == "*" ]]; then
        echoContent green " ---> 跳过本次修改 ......"
    else
        INFO_API="$cpu_info_api$sensors_info_api$ups_info_api$nvme_info_api$storage_info_api$nand_info_api"
        INFO_DISPLAY="$cpu_info_display$sensors_display$ups_info_display$nvme_info_display$storage_info_display$nand_info_display"
    
        echo -e "$INFO_API" > /tmp/2.txt
        echo -e "	    value: '',\n	}$INFO_DISPLAY" > /tmp/3.txt
    
        height2="$[300 + cpu_info_height + sensors_height + ups_height + nvme_height + storage_height + nand_height + 25]"
        if [ $height2 -le 325 ]; then
            height2="300"
        fi
        sed -i '/PVE::pvecfg::version_text();/,/my $dinfo = df/!b;//!d;/my $dinfo = df/e cat /tmp/2.txt' /usr/share/perl5/PVE/API2/Nodes.pm
        sed -i '/pveversion/,/^\s\+],/!b;//!d;/^\s\+],/e cat /tmp/3.txt' /usr/share/pve-manager/js/pvemanagerlib.js
    
        if [[ "${choices[r]}" = "*" ]]; then
            textAlign='right'
        elif [[ "${choices[m]}" = "*" ]]; then
            textAlign='center'
        elif [[ "${choices[j]}" = "*" ]]; then
            textAlign='justify-all'
        else
            textAlign=''
        fi

        if [[ -n "${textAlign}" ]]; then
            sed -Ei '/widget.pveNodeStatus/,/	    },/ s/height: [0-9]+/height: '$height2'/; /width: '"'"'100%'"'"',/{n;s/^	    },/\t\ttextAlign: '"'"''${textAlign}''"'"',\n&/}' /usr/share/pve-manager/js/pvemanagerlib.js
        else
            sed -Ei '/widget.pveNodeStatus/,/	    },/ s/height: [0-9]+/height: '$height2'/; /textAlign/d' /usr/share/pve-manager/js/pvemanagerlib.js
        fi
    
        sed -Ei '/'"'"'netin'"'"', '"'"'netout'"'"'/{n;s/^([	| ]+)store: rrdstore/\1fieldTitles: [gettext('"'"'下行'"'"'), gettext('"'"'上行'"'"')],\n&/g}' /usr/share/pve-manager/js/pvemanagerlib.js
        sed -Ei '/'"'"'diskread'"'"', '"'"'diskwrite'"'"'/{n;s/^([	| ]+)store: rrdstore/\1fieldTitles: [gettext('"'"'读'"'"'), gettext('"'"'写'"'"')],\n&/g}' /usr/share/pve-manager/js/pvemanagerlib.js
    
        echoContent skyBlue "\n进度  2/${totalProgress} : 重启 pveproxy 服务"
        echoContent green " ---> 添加 PVE 硬件概要信息完成, 正在重启 pveproxy 服务 ......"
        systemctl restart pveproxy
    
        echoContent red "\n进度  3/${totalProgress} : 需要手动刷新 PVE Web 页面！！！"
        echoContent green " ---> pveproxy 服务重启完成, 请使用 Shift + F5 手动刷新 PVE Web 页面"
    fi
}

recovery_info_offline() {
    echoContent skyBlue "\n进度 1/${totalProgress} : 恢复原版 PVE 概要信息(离线模式测试版)"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项\n"
    echoContent yellow "1、在线模式会将暗黑主题恢复为官方主题, 离线模式不会影响暗黑主题\n"
    echoContent yellow "2、如恢复出现异常, 请使用恢复原版 PVE 概要信息(在线模式)\n"

    echoContent red "=============================================================="
    while :
    do
        read -r -p '是否恢复原版 PVE 概要信息 (Y/n)？ : ' choose
        case $choose in
            [Yy])
                sed -i '/PVE::pvecfg::version_text();/,/my $dinfo = df/!b;//!d;s/my $dinfo = df/\n\t&/' /usr/share/perl5/PVE/API2/Nodes.pm
                sed -i '/pveversion/,/^\s\+],/!b;//!d;s/^\s\+],/\t    value: '"'"''"'"',\n\t},\n&/' /usr/share/pve-manager/js/pvemanagerlib.js
                sed -i '/widget.pveNodeStatus/,/},/ { s/height: [0-9]\+/height: 300/; /textAlign/d}' /usr/share/pve-manager/js/pvemanagerlib.js
                systemctl restart pveproxy

                echoContent green " ---> 恢复原版 PVE 概要信息完成, 请使用 Shift + F5 手动刷新 PVE Web 页面"
                break
                ;;
            [Nn])
                break
                ;;
            *)
                echoContent red " ---> 选择错误"
                ;;
        esac
    done
}

recovery_info_online() {
    echoContent skyBlue "\n进度 1/${totalProgress} : 恢复原版 PVE 概要信息(在线模式)"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项\n"
    echoContent yellow "1、在线模式会将暗黑主题恢复为官方主题, 离线模式不会影响暗黑主题\n"
    echoContent yellow "2、需确保 PVE 软件源连通性正常, 否则会恢复失败\n"

    echoContent red "=============================================================="
    while :
    do
        read -r -p '是否恢复原版 PVE 概要信息 (Y/n)？ : ' choose
        case $choose in
            [Yy])
                ${reinstallType} pve-manager
                echoContent green " ---> 恢复原版 PVE 概要信息完成, 请使用 Shift + F5 手动刷新 PVE Web 页面"
                break
                ;;
            [Nn])
                break
                ;;
            *)
                echoContent red " ---> 选择错误"
                ;;
        esac
    done
}

pveInfo_menu() {
    initVar
    while true; do
        res=$($DIALOG --title "PVE 概要信息增强" --menu "请选择操作" 16 65 4 \
            1 "添加 CPU 主频/温度/硬盘/UPS 等概要信息" \
            2 "恢复原版概要信息 (离线模式)" \
            3 "恢复原版概要信息 (在线模式)" \
            0 "返回主菜单" 3>&1 1>&2 2>&3)

        [[ -z "$res" || "$res" == "0" ]] && break
        case $res in
            1)
                totalProgress=3
                pve_Info_mod
                read -n 1 -s -r -p $'\n按任意键返回子菜单...'
                echo
                ;;
            2)
                totalProgress=1
                recovery_info_offline
                read -n 1 -s -r -p $'\n按任意键返回子菜单...'
                echo
                ;;
            3)
                totalProgress=1
                recovery_info_online
                read -n 1 -s -r -p $'\n按任意键返回子菜单...'
                echo
                ;;
        esac
    done
}

main() {
    clear
    check_env
    $DIALOG --title "欢迎使用" --yesno "脚本将对 PVE 进行深度优化。\n修改前会自动备份至 $BACKUP_DIR\n\n是否开始？" 12 60
    [[ $? -eq 0 ]] && main_menu
}

main "$@"