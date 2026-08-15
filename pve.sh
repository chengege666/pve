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

# --- 3.5 PVE 概要信息增强 (温度/主频/硬盘/UPS 显示在 Web 页面) ---

# 配置文件路径
PVE_SUMMARY_CONF="/etc/pve-summary.conf"
PVE_SUMMARY_STATUS="/var/log/pve-summary-status.json"
PVE_SUMMARY_SCRIPT="/usr/local/bin/pve-summary-status.sh"
PVE_SUMMARY_CRON="/etc/cron.d/pve-summary-status"
PVEMANAGERLIB_JS="/usr/share/pve-manager/js/pvemanagerlib.js"

# 持久化保存用户选项 (追加到配置)
save_summary_opt() {
    local key="$1"
    local val="$2"
    [[ ! -f "$PVE_SUMMARY_CONF" ]] && mkdir -p "$(dirname "$PVE_SUMMARY_CONF")" 2>/dev/null
    # 如果 key 已存在则覆盖，否则追加
    if grep -q "^${key}=" "$PVE_SUMMARY_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$PVE_SUMMARY_CONF"
    else
        echo "${key}=${val}" >> "$PVE_SUMMARY_CONF"
    fi
}

# 读取选项
get_summary_opt() {
    local key="$1"
    grep -m1 "^${key}=" "$PVE_SUMMARY_CONF" 2>/dev/null | cut -d'=' -f2
}

# 预设方案
preset_summary_all() {
    # 高大全：全部 CPU + 风扇 + UPS + 硬盘 a/b/c + 居中
    for k in CPU_FREQ_REAL CPU_FREQ_RANGE CPU_THREAD_FREQ CPU_GOV CPU_POWER CPU_TEMP CPU_CORE_TEMP FAN_SPEED UPS_INFO DISK_BASIC DISK_POWERON DISK_IO; do
        save_summary_opt "$k" 1
    done
    save_summary_opt "LAYOUT" "center"
}
preset_summary_light() {
    # 精简：实时主频/工作模式/温度/硬盘基础 + 居中
    for k in CPU_FREQ_REAL CPU_GOV CPU_TEMP DISK_BASIC; do save_summary_opt "$k" 1; done
    for k in CPU_FREQ_RANGE CPU_THREAD_FREQ CPU_POWER CPU_CORE_TEMP FAN_SPEED UPS_INFO DISK_POWERON DISK_IO; do
        save_summary_opt "$k" 0
    done
    save_summary_opt "LAYOUT" "center"
}
preset_summary_minimal() {
    # 极简：实时主频/工作模式/温度
    for k in CPU_FREQ_REAL CPU_GOV CPU_TEMP; do save_summary_opt "$k" 1; done
    for k in CPU_FREQ_RANGE CPU_THREAD_FREQ CPU_POWER CPU_CORE_TEMP FAN_SPEED UPS_INFO DISK_BASIC DISK_POWERON DISK_IO; do
        save_summary_opt "$k" 0
    done
    save_summary_opt "LAYOUT" ""
}

# 写入后端采集脚本
write_status_script() {
    cat > "$PVE_SUMMARY_SCRIPT" <<'SCRIPT_EOF'
#!/bin/bash
# PVE 节点概要数据采集 (JSON 输出到 stdout 或 /var/log/pve-summary-status.json)
OUT="${1:-/var/log/pve-summary-status.json}"
TMP="$(mktemp)"

# 1) CPU 实时/最小/最大主频、线程主频、调速器
CPU_GOV=""
if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    CPU_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
fi
if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq ]]; then
    MIN_F=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq) / 1000 ))
fi
if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]]; then
    MAX_F=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) / 1000 ))
fi
# 实时主频 (每个线程)
THREAD_FREQS=""
idx=0
nproc_c=$(nproc 2>/dev/null || echo 0)
while [[ $idx -lt $nproc_c ]]; do
    f="/sys/devices/system/cpu/cpu${idx}/cpufreq/scaling_cur_freq"
    if [[ -r "$f" ]]; then
        v=$(( $(cat "$f") / 1000 ))
    else
        v=$(awk -v c="cpu MHz" -v i=$idx '/^cpu MHz/ {if (NR==i+1) {printf "%.0f", $4; exit}}' /proc/cpuinfo 2>/dev/null || echo 0)
    fi
    [[ -n "$THREAD_FREQS" ]] && THREAD_FREQS="${THREAD_FREQS},"
    THREAD_FREQS="${THREAD_FREQS}${v}"
    idx=$(( idx + 1 ))
done
# 当前平均实时主频
CUR_F=""
if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]]; then
    CUR_F=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 ))
else
    CUR_F=$(awk -v c="cpu MHz" '/^cpu MHz/ {s+=$4;n++} END {if (n>0) printf "%.0f", s/n; else print 0}' /proc/cpuinfo)
fi

# 2) CPU 功率 (尝试 rapl, 否则空)
CPU_POWER_W=""
RAPL_PATH=$(find /sys/class/powercap -name "energy_uj" -path "*package*" 2>/dev/null | head -1)
if [[ -n "$RAPL_PATH" && -r "$RAPL_PATH" ]]; then
    e1=$(cat "$RAPL_PATH")
    sleep 1
    e2=$(cat "$RAPL_PATH")
    dj=$(( (e2 - e1) / 1000 )) # mJ
    if [[ $dj -gt 0 ]]; then
        CPU_POWER_W="$(awk -v d=$dj 'BEGIN{printf "%.1f", d/1000}')"
    fi
fi

# 3) CPU 温度 / 核心温度 / 风扇 (lm-sensors)
CPU_TEMP=""
CORE_TEMPS=""
FANS=""
if command -v sensors &>/dev/null; then
    CPU_TEMP=$(sensors 2>/dev/null | awk -F'[:+°]' '/^Core 0|^Package id 0|^Tdie|^CPU Temperature|^temp1/ {v=$3; gsub(/ /,"",v); if (v!="") {printf "%.1f", v; exit}}')
    CORE_TEMPS=$(sensors 2>/dev/null | awk -F'[:+°]' '/^Core [0-9]/ {v=$3; gsub(/ /,"",v); if (v!="") {printf (NR>1?",":"") "%.1f", v}}')
    # 风扇: 多行转数组
    FANS=$(sensors 2>/dev/null | awk -F':' '/fan[0-9]/ {gsub(/ /,"",$2); sub(/ RPM.*/,"",$2); if ($2+0>0 || $2!="") {printf (a++?",":"") "%s=%s", $1, $2}}')
fi
# 兜底：hwmon 读取 cpu temp
if [[ -z "$CPU_TEMP" ]]; then
    for h in /sys/class/hwmon/hwmon*/temp1_input; do
        [[ -r "$h" ]] || continue
        v=$(cat "$h"); [[ $v -gt 0 ]] && { CPU_TEMP=$(awk -v v=$v 'BEGIN{printf "%.1f", v/1000}'); break; }
    done
fi

# 4) UPS (apcupsd)
UPS_JSON="null"
if command -v apcaccess &>/dev/null; then
    ups_raw=$(apcaccess 2>/dev/null)
    if [[ -n "$ups_raw" ]]; then
        STATUS=$(echo "$ups_raw" | awk -F':' '/^STATUS / {gsub(/^ +| +$/,"",$2); print $2}')
        BCHARGE=$(echo "$ups_raw" | awk -F':' '/^BCHARGE/ {gsub(/[^0-9.]/,"",$2); print $2}')
        TIMELEFT=$(echo "$ups_raw" | awk -F':' '/^TIMELEFT/ {gsub(/^ +| +$/,"",$2); gsub(/ Minutes.*/,"m",$2); print $2}')
        LOADPCT=$(echo "$ups_raw" | awk -F':' '/^LOADPCT/ {gsub(/[^0-9.]/,"",$2); print $2}')
        UPS_JSON=$(printf '{"status":"%s","battery":"%s%%","timeleft":"%s","load":"%s%%"}' \
            "$STATUS" "$BCHARGE" "$TIMELEFT" "$LOADPCT")
    fi
fi

# 5) 硬盘信息: 基础(a) / 通电(b) / IO(c)
DISK_JSON="{}"
# 候选磁盘: 非 loop, 非 dm (只取 /dev/sd* /dev/nvme* /dev/vd* /dev/hd*)
DISKS=$(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}' | grep -E '^/dev/(sd|nvme|vd|hd)' || true)
if [[ -n "$DISKS" ]]; then
    first=1
    DISK_JSON="["
    while read -r d; do
        [[ -z "$d" ]] && continue
        name=$(basename "$d")
        # 基础: 容量 温度 (NVME用nvme-cli, 其他用smartctl或hddtemp)
        SIZE=""
        TEMP=""
        HEALTH=""
        POWERON_HOURS=""
        POWERCYCLE=""
        IO_READ_MB=""
        IO_WRITE_MB=""
        IO_READ_IOPS=""
        IO_WRITE_IOPS=""
        # 容量
        if [[ -r /sys/block/${name}/size ]]; then
            sectors=$(cat /sys/block/${name}/size)
            SIZE=$(awk -v s=$sectors 'BEGIN{if (s>=1024*1024*2) printf "%.1fTB", s*512/1024/1024/1024/1024; else if (s>=2*1024*1024) printf "%.1fGB", s*512/1024/1024/1024; else printf "%.0fMB", s*512/1024/1024}')
        fi
        # 温度 / 健康 / 通电
        if command -v smartctl &>/dev/null; then
            sm=$(smartctl -A -H -d auto "$d" 2>/dev/null)
            # 温度 (不同 ID: 194/190/Celsius/Temperature)
            TEMP=$(echo "$sm" | awk -F'[:\\-]+' '/Temperature_Celsius|Temperature_Internal|Airflow_Temperature|^194 |^190 / {for(i=1;i<=NF;i++) if ($i~/[0-9]+/ && $i+0>0 && $i+0<120) {printf "%.0f", $i+0; exit}}')
            if [[ -z "$TEMP" && "$d" == /dev/nvme* ]]; then
                TEMP=$(smartctl -a "$d" 2>/dev/null | awk -F':' '/Temperature:/ {gsub(/[^0-9]/,"",$2); if ($2+0>0) {printf "%s", $2+0; exit}}')
            fi
            HEALTH=$(echo "$sm" | awk -F':' '/SMART overall-health|SMART Health Status/ {gsub(/^ +| +$/,"",$2); print $2; exit}')
            # 通电时长/次数
            POWERON_HOURS=$(echo "$sm" | awk '/Power_On_Hours|Power On Hours/ {for(i=1;i<=NF;i++) if ($i~/^[0-9]+$/) {print $i; exit}}')
            POWERCYCLE=$(echo "$sm" | awk '/Power_Cycle_Count|Power Cycle Count/ {for(i=1;i<=NF;i++) if ($i~/^[0-9]+$/) {print $i; exit}}')
        fi
        # hddtemp 兜底
        if [[ -z "$TEMP" ]] && command -v hddtemp &>/dev/null; then
            TEMP=$(hddtemp -n "$d" 2>/dev/null | tr -d '°C ')
            [[ "$TEMP" =~ ^[0-9]+$ ]] || TEMP=""
        fi
        # nvme-cli 兜底
        if [[ "$d" == /dev/nvme* ]]; then
            if command -v nvme &>/dev/null; then
                ns=$(nvme smart-log "$d" 2>/dev/null)
                [[ -z "$TEMP" ]] && TEMP=$(echo "$ns" | awk -F':' '/temperature/ {gsub(/[^0-9]/,"",$2); if ($2+0>0) {print $2+0; exit}}')
                [[ -z "$POWERON_HOURS" ]] && POWERON_HOURS=$(echo "$ns" | awk -F':' '/power_on_hours/ {gsub(/[^0-9]/,"",$2); if ($2+0>0) print $2+0; exit}')
                [[ -z "$POWERCYCLE" ]] && POWERCYCLE=$(echo "$ns" | awk -F':' '/power_cycles/ {gsub(/[^0-9]/,"",$2); if ($2+0>0) print $2+0; exit}')
                [[ -z "$HEALTH" ]] && HEALTH=$(echo "$ns" | awk -F':' '/^critical_warning/ {gsub(/^ +| +$/,"",$2); if ($2=="0x00000000" || $2=="0") print "OK"; else print "WARNING"}')
            fi
        fi
        # IO: 读取 /sys/block/<name>/stat 1秒差值
        if [[ -d "/sys/block/${name}" ]]; then
            s1=$(awk '{print $3" "$7}' /sys/block/${name}/stat 2>/dev/null)  # 读扇区, 写扇区
            r1=$(awk '{print $1" "$5}' /sys/block/${name}/stat 2>/dev/null)  # 读IO次数, 写IO次数
            sleep 1
            s2=$(awk '{print $3" "$7}' /sys/block/${name}/stat 2>/dev/null)
            r2=$(awk '{print $1" "$5}' /sys/block/${name}/stat 2>/dev/null)
            rs1=$(echo $s1 | awk '{print $1}'); ws1=$(echo $s1 | awk '{print $2}')
            rs2=$(echo $s2 | awk '{print $1}'); ws2=$(echo $s2 | awk '{print $2}')
            rio1=$(echo $r1 | awk '{print $1}'); wio1=$(echo $r1 | awk '{print $2}')
            rio2=$(echo $r2 | awk '{print $1}'); wio2=$(echo $r2 | awk '{print $2}')
            # 扇区 *512 字节 / 1024/1024 = MB
            IO_READ_MB=$(awk -v a=$rs1 -v b=$rs2 'BEGIN{d=b-a; if (d<0) d=0; printf "%.1f", d*512/1024/1024}')
            IO_WRITE_MB=$(awk -v a=$ws1 -v b=$ws2 'BEGIN{d=b-a; if (d<0) d=0; printf "%.1f", d*512/1024/1024}')
            IO_READ_IOPS=$(( rio2 - rio1 )); [[ $IO_READ_IOPS -lt 0 ]] && IO_READ_IOPS=0
            IO_WRITE_IOPS=$(( wio2 - wio1 )); [[ $IO_WRITE_IOPS -lt 0 ]] && IO_WRITE_IOPS=0
        fi
        # 组装条目
        [[ $first -eq 0 ]] && DISK_JSON="${DISK_JSON},"
        first=0
        DISK_JSON="${DISK_JSON}{\"name\":\"${name}\",\"size\":\"${SIZE}\",\"temp\":\"${TEMP}\",\"health\":\"${HEALTH}\",\"poweron_h\":\"${POWERON_HOURS}\",\"powercycle\":\"${POWERCYCLE}\",\"read_mbs\":\"${IO_READ_MB}\",\"write_mbs\":\"${IO_WRITE_MB}\",\"read_iops\":\"${IO_READ_IOPS}\",\"write_iops\":\"${IO_WRITE_IOPS}\"}"
    done <<< "$DISKS"
    DISK_JSON="${DISK_JSON}]"
fi

# 输出 JSON
cat > "$TMP" <<EOF
{
  "cpu": {
    "gov": "${CPU_GOV}",
    "cur_mhz": "${CUR_F}",
    "min_mhz": "${MIN_F}",
    "max_mhz": "${MAX_F}",
    "thread_mhz": [${THREAD_FREQS}],
    "power_w": "${CPU_POWER_W}",
    "temp_c": "${CPU_TEMP}",
    "core_temp_c": [${CORE_TEMPS}]
  },
  "fans": "${FANS}",
  "ups": ${UPS_JSON},
  "disks": ${DISK_JSON}
}
EOF
mv "$TMP" "$OUT"
chmod 644 "$OUT" 2>/dev/null
SCRIPT_EOF
    chmod +x "$PVE_SUMMARY_SCRIPT"
}

# 安装 cron
install_summary_cron() {
    cat > "$PVE_SUMMARY_CRON" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root for i in 0 15 30 45; do sleep $i; /usr/local/bin/pve-summary-status.sh >/dev/null 2>&1; done
EOF
    chmod 644 "$PVE_SUMMARY_CRON"
    # 立即跑一次
    "$PVE_SUMMARY_SCRIPT" >/dev/null 2>&1 || true
}

# JS 注入块 (前置标记 + 清除历史注入)
JS_MARK_BEGIN="// ===== PVE-SUMMARY-ENHANCE-BEGIN ====="
JS_MARK_END="// ===== PVE-SUMMARY-ENHANCE-END ====="

# 清除旧注入
strip_old_inject() {
    local f="$1"
    if grep -q "$JS_MARK_BEGIN" "$f" 2>/dev/null; then
        # 用 awk 删除两标记之间 (含标记行)
        awk -v b="$JS_MARK_BEGIN" -v e="$JS_MARK_END" '
            $0 == b {skip=1; next}
            $0 == e {skip=0; next}
            !skip {print}
        ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    fi
}

# 注入 JS 到 pvemanagerlib.js
inject_pvemanagerlib() {
    if [[ ! -f "$PVEMANAGERLIB_JS" ]]; then
        show_msg "未找到 $PVEMANAGERLIB_JS，跳过页面注入" "warning"
        return 1
    fi
    backup_file "$PVEMANAGERLIB_JS" "PVE 概要页面增强"

    # 1) 先清除旧注入
    strip_old_inject "$PVEMANAGERLIB_JS"

    # 2) 读取配置转为 JS 常量
    local LAYOUT="$(get_summary_opt LAYOUT)"
    [[ -z "$LAYOUT" ]] && LAYOUT="center"
    local -A OPTS=(
        [CPU_FREQ_REAL]="$(get_summary_opt CPU_FREQ_REAL)"
        [CPU_FREQ_RANGE]="$(get_summary_opt CPU_FREQ_RANGE)"
        [CPU_THREAD_FREQ]="$(get_summary_opt CPU_THREAD_FREQ)"
        [CPU_GOV]="$(get_summary_opt CPU_GOV)"
        [CPU_POWER]="$(get_summary_opt CPU_POWER)"
        [CPU_TEMP]="$(get_summary_opt CPU_TEMP)"
        [CPU_CORE_TEMP]="$(get_summary_opt CPU_CORE_TEMP)"
        [FAN_SPEED]="$(get_summary_opt FAN_SPEED)"
        [UPS_INFO]="$(get_summary_opt UPS_INFO)"
        [DISK_BASIC]="$(get_summary_opt DISK_BASIC)"
        [DISK_POWERON]="$(get_summary_opt DISK_POWERON)"
        [DISK_IO]="$(get_summary_opt DISK_IO)"
    )
    # 没任何选项就不注入内容
    local any=0
    for v in "${OPTS[@]}"; do [[ "$v" == "1" ]] && any=1; done
    if [[ $any -eq 0 ]]; then
        show_msg "未选择任何显示项，跳过 JS 注入" "info"
        return 0
    fi

    # 3) 把选项拼成 JS boolean 对象字符串
    local OPTS_JS="{"
    local first=1
    for k in "${!OPTS[@]}"; do
        v="${OPTS[$k]}"
        [[ $first -eq 0 ]] && OPTS_JS="${OPTS_JS},"
        if [[ "$v" == "1" ]]; then OPTS_JS="${OPTS_JS}${k}:true"; else OPTS_JS="${OPTS_JS}${k}:false"; fi
        first=0
    done
    OPTS_JS="${OPTS_JS}}"

    # 4) 生成注入 JS
    local INJECT_JS
    INJECT_JS=$(cat <<INJECT_EOF
$JS_MARK_BEGIN
(function(){
  var LAYOUT = "${LAYOUT}";
  var OPTS = ${OPTS_JS};
  var STATUS_URL = "/pve-summary-status.json";
  var REFRESH_MS = 10000;
  var PANEL_ID = "pve-summary-enhance-panel";
  // 避免重复注入
  if (window.__pve_summary_enhance_installed) return;
  window.__pve_summary_enhance_installed = true;

  // 取安全文本
  function esc(s){ if (s===null||s===undefined) return ""; return String(s).replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]});}
  function fmtNum(s,unit){ if (s===null||s===undefined||s==="") return "-"; return esc(s)+(unit?esc(unit):""); }
  function fanMap(s){ if (!s) return []; return s.split(",").map(function(p){var a=p.split("=");return {name:a[0],rpm:a[1]};}); }

  function render(data){
    if (!data) return "(加载中…)";
    var c = data.cpu || {};
    var disks = data.disks || [];
    var ups = data.ups;
    var fans = fanMap(data.fans);
    var html = [];
    html.push('<style>');
    html.push('#'+PANEL_ID+' .pse-row{display:table-row}');
    html.push('#'+PANEL_ID+' .pse-row>div{display:table-cell;padding:2px 12px 2px 0;vertical-align:middle;line-height:1.6}');
    html.push('#'+PANEL_ID+' .pse-k{color:#555;font-weight:normal;white-space:nowrap}');
    html.push('#'+PANEL_ID+' .pse-v{color:#000;font-weight:500}');
    html.push('#'+PANEL_ID+' .pse-block{margin:6px 0 2px 0;font-weight:600;border-bottom:1px solid #eee;padding-bottom:2px}');
    html.push('#'+PANEL_ID+' .pse-core{display:inline-block;margin:0 8px 2px 0;min-width:48px}');
    html.push('#'+PANEL_ID+' .pse-disk{border:1px solid #eee;border-radius:4px;padding:6px 8px;margin:4px 8px 4px 0;display:inline-block;min-width:240px;vertical-align:top}');
    html.push('</style>');

    // CPU 区
    var cpuAny = OPTS.CPU_FREQ_REAL||OPTS.CPU_FREQ_RANGE||OPTS.CPU_THREAD_FREQ||OPTS.CPU_GOV||OPTS.CPU_POWER||OPTS.CPU_TEMP||OPTS.CPU_CORE_TEMP;
    if (cpuAny){
      html.push('<div class="pse-block">CPU 信息</div>');
      html.push('<div style="display:table">');
      if (OPTS.CPU_GOV) html.push('<div class="pse-row"><div class="pse-k">工作模式</div><div class="pse-v">'+esc(c.gov||"-")+'</div></div>');
      if (OPTS.CPU_FREQ_REAL) html.push('<div class="pse-row"><div class="pse-k">实时主频</div><div class="pse-v">'+fmtNum(c.cur_mhz," MHz")+'</div></div>');
      if (OPTS.CPU_FREQ_RANGE) html.push('<div class="pse-row"><div class="pse-k">频率范围</div><div class="pse-v">'+fmtNum(c.min_mhz," MHz")+' ~ '+fmtNum(c.max_mhz," MHz")+'</div></div>');
      if (OPTS.CPU_THREAD_FREQ) {
        var t=(c.thread_mhz||[]).map(function(v,i){return '<span class="pse-core">T'+i+': '+fmtNum(v,"MHz")+'</span>'}).join("");
        html.push('<div class="pse-row"><div class="pse-k">线程主频</div><div class="pse-v">'+t+'</div></div>');
      }
      if (OPTS.CPU_POWER) html.push('<div class="pse-row"><div class="pse-k">CPU 功耗</div><div class="pse-v">'+fmtNum(c.power_w," W")+'</div></div>');
      if (OPTS.CPU_TEMP) html.push('<div class="pse-row"><div class="pse-k">CPU 温度</div><div class="pse-v">'+fmtNum(c.temp_c," °C")+'</div></div>');
      if (OPTS.CPU_CORE_TEMP) {
        var ct=(c.core_temp_c||[]).map(function(v,i){return '<span class="pse-core">C'+i+': '+fmtNum(v,"°C")+'</span>'}).join("");
        html.push('<div class="pse-row"><div class="pse-k">核心温度</div><div class="pse-v">'+(ct||"-")+'</div></div>');
      }
      html.push('</div>');
    }

    // 风扇区
    if (OPTS.FAN_SPEED) {
      html.push('<div class="pse-block">风扇</div><div style="display:table">');
      if (fans.length===0){ html.push('<div class="pse-row"><div class="pse-k">风扇</div><div class="pse-v">无数据</div></div>'); }
      else fans.forEach(function(f){html.push('<div class="pse-row"><div class="pse-k">'+esc(f.name)+'</div><div class="pse-v">'+fmtNum(f.rpm," RPM")+'</div></div>');});
      html.push('</div>');
    }

    // UPS 区
    if (OPTS.UPS_INFO) {
      html.push('<div class="pse-block">UPS</div><div style="display:table">');
      if (!ups){ html.push('<div class="pse-row"><div class="pse-k">状态</div><div class="pse-v">未检测到 apcupsd</div></div>'); }
      else {
        html.push('<div class="pse-row"><div class="pse-k">状态</div><div class="pse-v">'+esc(ups.status||"-")+'</div></div>');
        html.push('<div class="pse-row"><div class="pse-k">电量</div><div class="pse-v">'+esc(ups.battery||"-")+'</div></div>');
        html.push('<div class="pse-row"><div class="pse-k">负载</div><div class="pse-v">'+esc(ups.load||"-")+'</div></div>');
        html.push('<div class="pse-row"><div class="pse-k">剩余时间</div><div class="pse-v">'+esc(ups.timeleft||"-")+'</div></div>');
      }
      html.push('</div>');
    }

    // 硬盘区
    if (OPTS.DISK_BASIC||OPTS.DISK_POWERON||OPTS.DISK_IO) {
      html.push('<div class="pse-block">硬盘</div><div>');
      if (!disks||!disks.length){ html.push('<span>未检测到磁盘</span>'); }
      else disks.forEach(function(d){
        html.push('<div class="pse-disk">');
        html.push('<div style="font-weight:600">'+esc(d.name)+'</div>');
        if (OPTS.DISK_BASIC) {
          html.push('<div class="pse-k">容量: <span class="pse-v">'+esc(d.size||"-")+'</span></div>');
          if (d.temp!=="" && d.temp!==null && d.temp!==undefined) html.push('<div class="pse-k">温度: <span class="pse-v">'+esc(d.temp)+'°C</span></div>');
          if (d.health) html.push('<div class="pse-k">健康: <span class="pse-v">'+esc(d.health)+'</span></div>');
        }
        if (OPTS.DISK_POWERON) {
          html.push('<div class="pse-k">通电时长: <span class="pse-v">'+(d.poweron_h?esc(d.poweron_h)+" h":"-")+'</span></div>');
          html.push('<div class="pse-k">开关次数: <span class="pse-v">'+(d.powercycle?esc(d.powercycle):"-")+'</span></div>');
        }
        if (OPTS.DISK_IO) {
          html.push('<div class="pse-k">读取: <span class="pse-v">'+esc(d.read_mbs)+' MB/s ('+esc(d.read_iops)+' IOPS)</span></div>');
          html.push('<div class="pse-k">写入: <span class="pse-v">'+esc(d.write_mbs)+' MB/s ('+esc(d.write_iops)+' IOPS)</span></div>');
        }
        html.push('</div>');
      });
      html.push('</div>');
    }
    return html.join("");
  }

  function fetchThenRender(el){
    Ext.Ajax.request({
      url: STATUS_URL + "?_=" + Date.now(),
      disableCaching: false,
      success: function(r){
        try { var d = JSON.parse(r.responseText); el.update(render(d)); }
        catch(e){ el.update('<span style="color:#c00">数据格式错误: ' + esc(e.message||String(e)) + '</span>'); }
      },
      failure: function(){
        // 若首次请求失败，尝试加载静态文件可能还没生成
        el.update(render(null));
      }
    });
  }

  function insertAfter(container){
    if (!container) return;
    if (container.down && container.down("#"+PANEL_ID)) return;
    var alignCss = "";
    if (LAYOUT==="center") alignCss = "text-align:center";
    else if (LAYOUT==="left") alignCss = "text-align:left";
    else if (LAYOUT==="right") alignCss = "text-align:right";
    var panel;
    try {
      panel = container.add({
        xtype: "component",
        itemId: PANEL_ID,
        padding: 8,
        style: { background: "#fafafa", border: "1px dashed #ddd", borderRadius: "6px", marginTop: "8px", marginBottom: "8px" },
        html: '<div id="'+PANEL_ID+'" style="'+alignCss+'">加载中…</div>',
        listeners: {
          afterrender: function(cmp){
            var el = cmp.getEl().down("#"+PANEL_ID, true);
            if (!el) el = cmp.getEl();
            fetchThenRender(Ext.get(el));
            setInterval(function(){ fetchThenRender(Ext.get(el)); }, REFRESH_MS);
          }
        }
      });
    } catch(e){
      // fallback: 原始 DOM 注入
      var wrap = document.createElement("div");
      wrap.id = PANEL_ID;
      wrap.style.cssText = alignCss+";background:#fafafa;border:1px dashed #ddd;border-radius:6px;padding:8px;margin:8px 0;";
      wrap.textContent = "加载中…";
      if (container.getEl) container.getEl().appendChild(Ext.get(wrap));
      else if (container.appendChild) container.appendChild(wrap);
      var updater = function(){
        fetchThenRender(Ext.get(wrap));
      };
      updater();
      setInterval(updater, REFRESH_MS);
    }
  }

  function findSummaryContainer(){
    // 优先: Proxmox.node.StatusView (PVE 常用节点概要 View)
    try {
      var cls = Proxmox && Proxmox.node && Proxmox.node.StatusView;
      if (cls) {
        var orig = cls.prototype.initComponent || cls.prototype.constructor;
        var hook = function(){
          var me = this;
          if (orig && orig.apply) orig.apply(this, arguments);
          this.on("afterrender", function(){
            var body = me.items && me.items.getAt ? me.items.getAt(0) || me.items.items[0] : null;
            if (!body && me.down) body = me.down("panel") || me;
            insertAfter(body || me);
          });
        };
        if (cls.prototype.initComponent) cls.prototype.initComponent = hook;
        else cls.prototype.constructor = hook;
        return true;
      }
    } catch(e){}
    // 兜底: 轮询 DOM 找 pveManager 的节点概要块
    var timer = setInterval(function(){
      var candidates = document.querySelectorAll(".x-panel,.x-grid");
      for (var i=0;i<candidates.length;i++){
        var t = candidates[i].textContent || "";
        if ((/CPU.*(利用|使用|率)|内存.*使用|硬盘空间|KSM|IO.*延迟|SWAP/).test(t) && !document.getElementById(PANEL_ID)){
          var wrap = candidates[i];
          var holder = document.createElement("div");
          holder.innerHTML = '<div id="'+PANEL_ID+'" style="padding:8px;margin-top:6px;background:#fafafa;border:1px dashed #ddd;border-radius:6px;">加载中…</div>';
          var node = holder.firstChild;
          var alignCss = "";
          if (LAYOUT==="center") alignCss = "text-align:center";
          else if (LAYOUT==="left") alignCss = "text-align:left";
          else if (LAYOUT==="right") alignCss = "text-align:right";
          node.setAttribute("style", node.getAttribute("style")+";"+alignCss);
          if (wrap.parentNode) wrap.parentNode.insertBefore(node, wrap.nextSibling);
          else wrap.appendChild(node);
          var updater = function(){ fetchThenRender(Ext.get(node)); };
          updater();
          setInterval(updater, REFRESH_MS);
          clearInterval(timer);
          break;
        }
      }
    }, 1200);
    return true;
  }

  // 在 pvemanagerlib 加载完后，尝试挂载到 Proxmox.node.StatusView 或 DOM
  findSummaryContainer();
})();
$JS_MARK_END
INJECT_EOF
)

    # 5) 找到注入点: 在 pvemanagerlib.js 文件末尾之前添加 (在最后一行前)
    # 如果存在 Ext.define("Proxmox.node.StatusView" 附近，插在该 define 关闭的 } 之后最好，否则直接追加到文件尾
    local inject_line=0
    if grep -n 'Ext.define("Proxmox.node.StatusView"' "$PVEMANAGERLIB_JS" &>/dev/null; then
        # 找到该 define 结束的行 (估算: 取第一个 define 行号，然后找该块对应的 ); )
        local def_line
        def_line=$(grep -n 'Ext.define("Proxmox.node.StatusView"' "$PVEMANAGERLIB_JS" | head -1 | cut -d: -f1)
        # 从该行向下找结束的 '});'
        local end_line
        end_line=$(awk -v s="$def_line" 'NR>=s && /^}\);/ {print NR; exit}' "$PVEMANAGERLIB_JS")
        [[ -n "$end_line" && "$end_line" -gt 0 ]] && inject_line=$(( end_line + 1 ))
    fi

    if [[ $inject_line -gt 0 ]]; then
        # 在 inject_line 前插入
        awk -v n="$inject_line" -v inj="$INJECT_JS" '
            NR == n { print inj }
            { print }
        ' "$PVEMANAGERLIB_JS" > "${PVEMANAGERLIB_JS}.tmp" && mv "${PVEMANAGERLIB_JS}.tmp" "$PVEMANAGERLIB_JS"
    else
        # 追加
        echo "" >> "$PVEMANAGERLIB_JS"
        echo "$INJECT_JS" >> "$PVEMANAGERLIB_JS"
    fi

    # 6) 把 JSON 静态文件挂载到 pveproxy: 直接链接到 /usr/share/pve-manager/images/ (可直接访问)
    #    PVE 的 /images/ 目录能直接通过 /pve2/images/ 或 /images/ 访问，但更稳妥是放到 /usr/share/pve-manager
    local PVE_WEBROOT="/usr/share/pve-manager"
    if [[ -d "$PVE_WEBROOT" ]]; then
        ln -sf "$PVE_SUMMARY_STATUS" "$PVE_WEBROOT/pve-summary-status.json" 2>/dev/null || cp "$PVE_SUMMARY_STATUS" "$PVE_WEBROOT/pve-summary-status.json" 2>/dev/null || true
    fi

    # 重启
    systemctl restart pveproxy
    return 0
}

# 一键清空 (还原 JS、删脚本、删 cron、删 JSON、删 conf)
clear_pve_summary() {
    $DIALOG --title "确认清空" --yesno "确定要清空 PVE 概要页面增强吗？\n(将还原 JS、删除采集脚本/cron/配置)" 12 55
    [[ $? -ne 0 ]] && return
    # 还原 JS
    local bak
    bak=$(ls -t "$BACKUP_DIR"/pvemanagerlib.js.*.bak 2>/dev/null | head -1)
    if [[ -z "$bak" && -f "$PVEMANAGERLIB_JS" ]]; then
        # 退而求其次：剥离旧注入
        strip_old_inject "$PVEMANAGERLIB_JS"
    elif [[ -f "$bak" ]]; then
        cp "$bak" "$PVEMANAGERLIB_JS"
    fi
    # 清理其他文件
    rm -f "$PVE_SUMMARY_SCRIPT" "$PVE_SUMMARY_STATUS" "$PVE_SUMMARY_CRON" "$PVE_SUMMARY_CONF"
    rm -f "/usr/share/pve-manager/pve-summary-status.json"
    systemctl restart pveproxy
    show_msg "PVE 概要页面增强已清空，请 Ctrl+F5 刷新浏览器" "success"
}

# 主向导
enhance_pve_summary() {
    # 初始化空配置
    if [[ ! -f "$PVE_SUMMARY_CONF" ]]; then
        : > "$PVE_SUMMARY_CONF"
    fi

    # ---------- 阶段 1: 先询问特殊动作 (清空 / 跳过) ----------
    local quick
    quick=$($DIALOG --title "进度 1/3 : PVE 概要信息定制向导" --menu "请选择操作:" 14 60 4 \
        "apply" "选择需要显示的信息 (下一步, 空格多选)" \
        "x" "一键清空 (还原默认)" \
        "s" "跳过本次修改 (返回主菜单)" 3>&1 1>&2 2>&3)
    case "$quick" in
        "x") clear_pve_summary; return ;;
        "s") return ;;
        "") return ;;
    esac

    while true; do
        # 读取当前选项 -> 转换成 checklist 的 ON/OFF
        o0=$(get_summary_opt CPU_FREQ_REAL);   [[ "$o0" == "1" ]] && s0="ON" || s0="OFF"
        o1=$(get_summary_opt CPU_FREQ_RANGE);  [[ "$o1" == "1" ]] && s1="ON" || s1="OFF"
        o2=$(get_summary_opt CPU_THREAD_FREQ); [[ "$o2" == "1" ]] && s2="ON" || s2="OFF"
        o3=$(get_summary_opt CPU_GOV);         [[ "$o3" == "1" ]] && s3="ON" || s3="OFF"
        o4=$(get_summary_opt CPU_POWER);       [[ "$o4" == "1" ]] && s4="ON" || s4="OFF"
        o5=$(get_summary_opt CPU_TEMP);        [[ "$o5" == "1" ]] && s5="ON" || s5="OFF"
        o6=$(get_summary_opt CPU_CORE_TEMP);   [[ "$o6" == "1" ]] && s6="ON" || s6="OFF"
        o7=$(get_summary_opt FAN_SPEED);       [[ "$o7" == "1" ]] && s7="ON" || s7="OFF"
        o8=$(get_summary_opt UPS_INFO);        [[ "$o8" == "1" ]] && s8="ON" || s8="OFF"
        oa=$(get_summary_opt DISK_BASIC);      [[ "$oa" == "1" ]] && sa="ON" || sa="OFF"
        ob=$(get_summary_opt DISK_POWERON);    [[ "$ob" == "1" ]] && sb="ON" || sb="OFF"
        oc=$(get_summary_opt DISK_IO);         [[ "$oc" == "1" ]] && sc="ON" || sc="OFF"
        lay=$(get_summary_opt LAYOUT)
        case "$lay" in
            left)   lr="[x] 居左 [ ] 居中 [ ] 居右" ;;
            center) lr="[ ] 居左 [x] 居中 [ ] 居右" ;;
            right)  lr="[ ] 居左 [ ] 居中 [x] 居右" ;;
            "")     lr="[ ] 居左 [ ] 居中 [ ] 居右 (默认居中)" ;;
            *)      lr="[ ] 居左 [ ] 居中 [ ] 居右" ;;
        esac

        # ---------- 阶段 2: checklist 空格多选 12 个显示项 ----------
        picks=$($DIALOG --title "进度 2/3 : PVE 概要信息定制向导" --checklist "空格键勾选/取消, 回车键确认\n\n当前布局: $lr\n\n提示: b/c 若勾选但未选 a, 将自动补上 a" 26 80 15 \
            "0" "CPU 实时主频"            "$s0" \
            "1" "CPU 最小及最大主频"      "$s1" \
            "2" "CPU 线程主频"            "$s2" \
            "3" "CPU 工作模式"            "$s3" \
            "4" "CPU 功率"                "$s4" \
            "5" "CPU 温度"                "$s5" \
            "6" "CPU 核心温度"            "$s6" \
            "7" "风扇转速"                "$s7" \
            "8" "UPS 信息 (需 apcupsd)"   "$s8" \
            "a" "硬盘基础信息 (容量/NVME温度/SMART)" "$sa" \
            "b" "硬盘通电信息 (需 a)"     "$sb" \
            "c" "硬盘 IO 信息 (需 a)"     "$sc" 3>&1 1>&2 2>&3)

        # 取消则直接退出到阶段 3
        # 如果用户点了取消(空), 不改变选择, 继续到布局阶段
        if [[ -n "$picks" ]]; then
            # 先全部置 0, 再对选中的置 1
            for k in CPU_FREQ_REAL CPU_FREQ_RANGE CPU_THREAD_FREQ CPU_GOV CPU_POWER CPU_TEMP CPU_CORE_TEMP FAN_SPEED UPS_INFO DISK_BASIC DISK_POWERON DISK_IO; do
                save_summary_opt "$k" 0
            done
            for item in $picks; do
                t=$(echo "$item" | tr -d '"')
                case "$t" in
                    0) save_summary_opt CPU_FREQ_REAL 1 ;;
                    1) save_summary_opt CPU_FREQ_RANGE 1 ;;
                    2) save_summary_opt CPU_THREAD_FREQ 1 ;;
                    3) save_summary_opt CPU_GOV 1 ;;
                    4) save_summary_opt CPU_POWER 1 ;;
                    5) save_summary_opt CPU_TEMP 1 ;;
                    6) save_summary_opt CPU_CORE_TEMP 1 ;;
                    7) save_summary_opt FAN_SPEED 1 ;;
                    8) save_summary_opt UPS_INFO 1 ;;
                    a) save_summary_opt DISK_BASIC 1 ;;
                    b) save_summary_opt DISK_POWERON 1 ;;
                    c) save_summary_opt DISK_IO 1 ;;
                esac
            done
            # 依赖修复: 若 b/c 选了但 a 没选 -> 自动勾 a
            ob2=$(get_summary_opt DISK_POWERON)
            oc2=$(get_summary_opt DISK_IO)
            oa2=$(get_summary_opt DISK_BASIC)
            if [[ "$oa2" != "1" ]] && { [[ "$ob2" == "1" ]] || [[ "$oc2" == "1" ]]; }; then
                save_summary_opt DISK_BASIC 1
            fi
        fi

        # ---------- 阶段 3: 布局 + 最终操作 ----------
        act=$($DIALOG --title "进度 3/3 : PVE 概要信息定制向导" --menu "当前布局: $lr\n\n请选择:" 16 65 7 \
            "apply" "应用以上选择 (确认执行)" \
            "again" "返回上一步重新勾选显示项" \
            "r" "布局: 居左显示" \
            "m" "布局: 居右显示" \
            "l" "布局: 居中显示" \
            "x" "一键清空 (还原默认)" \
            "s" "跳过本次修改 (返回主菜单)" 3>&1 1>&2 2>&3)
        [[ -z "$act" ]] && continue
        case "$act" in
            "apply") break ;;
            "again") continue ;;
            "r") save_summary_opt LAYOUT "left" ;;
            "m") save_summary_opt LAYOUT "right" ;;
            "l") save_summary_opt LAYOUT "center" ;;
            "x") clear_pve_summary; return ;;
            "s") return ;;
        esac
    done

    # 确认应用
    $DIALOG --title "确认应用" --yesno "开始应用选择的概要信息增强？\n将: 安装依赖 → 生成采集脚本 → 注入 JS → 重启 pveproxy\n提示: 完成后请 Ctrl+F5 强制刷新浏览器" 12 60
    [[ $? -ne 0 ]] && return

    # 1) 装依赖
    show_msg "安装依赖 (lm-sensors/smartmontools)..." "info"
    apt-get update -qq
    apt-get install -y lm-sensors smartmontools hddtemp nvme-cli sysstat apcupsd 2>&1 | tail -5
    sensors-detect --auto >/dev/null 2>&1 || true
    # apcupsd 默认不启用用户 socket，保持默认即可

    # 2) 写采集脚本 + cron
    show_msg "生成采集脚本 / cron..." "info"
    write_status_script
    install_summary_cron

    # 3) JS 注入
    show_msg "注入 PVE 页面 JS..." "info"
    inject_pvemanagerlib
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        $DIALOG --title "完成" --msgbox "PVE 概要信息增强已应用\n\n访问方式:\n  PVE → 数据中心 → 节点 → 概要 页面\n\n如未显示请 Ctrl+F5 强制刷新\n\n数据每 10s 刷新一次 (JSON 每 15s 生成)" 14 60
    else
        show_msg "注入过程中出现告警，详情见上面输出" "warning"
    fi
}

# rollback 辅助: 清除 pve-summary 相关 (供 6 一键回滚 调用)
rollback_pve_summary() {
    # 还原 JS
    local bak
    bak=$(ls -t "$BACKUP_DIR"/pvemanagerlib.js.*.bak 2>/dev/null | head -1)
    if [[ -f "$bak" && -f "$PVEMANAGERLIB_JS" ]]; then
        cp "$bak" "$PVEMANAGERLIB_JS"
    elif [[ -f "$PVEMANAGERLIB_JS" ]]; then
        strip_old_inject "$PVEMANAGERLIB_JS"
    fi
    rm -f "$PVE_SUMMARY_SCRIPT" "$PVE_SUMMARY_CRON" "$PVE_SUMMARY_STATUS" "$PVE_SUMMARY_CONF"
    rm -f "/usr/share/pve-manager/pve-summary-status.json"
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
    
    # 回滚 JS (proxmoxlib.js + pvemanagerlib.js)
    local js_bak=$(ls $BACKUP_DIR/proxmoxlib.js*.bak 2>/dev/null | tail -n 1)
    [[ -f "$js_bak" ]] && { cp "$js_bak" "/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js" 2>/dev/null || cp "$js_bak" "/usr/share/pve-manager/js/proxmoxlib.js" 2>/dev/null; }
    local pveml_bak=$(ls $BACKUP_DIR/pvemanagerlib.js*.bak 2>/dev/null | tail -n 1)
    if [[ -f "$pveml_bak" ]]; then
        cp "$pveml_bak" "$PVEMANAGERLIB_JS"
    else
        # 兜底剥离旧注入
        [[ -f "$PVEMANAGERLIB_JS" ]] && strip_old_inject "$PVEMANAGERLIB_JS"
    fi

    # 清理 PVE 概要增强相关文件/脚本/cron/配置
    rm -f "$PVE_SUMMARY_SCRIPT" "$PVE_SUMMARY_STATUS" "$PVE_SUMMARY_CRON" "$PVE_SUMMARY_CONF"
    rm -f "/usr/share/pve-manager/pve-summary-status.json"

    # 重启服务
    systemctl restart pveproxy
    show_msg "回滚完成，部分设置可能需要重启生效" "success"
}

# --- 主入口逻辑 ---

main_menu() {
    while true; do
        res=$($DIALOG --title "PVE 终极优化脚本 v3.0" --menu "PVE 版本: $CURRENT_PVE_VERSION" 23 68 12 \
            1 "CPU 性能、调频与虚拟机优化" \
            2 "去除网页‘无有效订阅’弹窗" \
            3 "安装全套监控工具 (温度/看板)" \
            11 "PVE 页面信息增强 (温度/主频/硬盘/UPS)" \
            4 "电源工作模式一键预设 (节能/性能)" \
            5 "查看当前系统运行状态" \
            6 "一键回滚脚本所做的修改" \
            7 "内存清理" \
            8 "磁盘清理" \
            9 "系统更新 (升级已安装软件包)" \
            10 "更换软件源 (国内镜像源)" \
            0 "退出脚本" 3>&1 1>&2 2>&3)

        [[ -z "$res" || "$res" == "0" ]] && break
        case $res in
            1) cpu_optimization_menu ;;
            2) remove_subscription_notice ;;
            3) install_monitoring_tools ;;
            11) enhance_pve_summary ;;
            4) power_optimization_menu ;;
            5) show_system_status ;;
            6) rollback_all ;;
            7) clear_memory ;;
            8) clear_disk ;;
            9) system_update ;;
            10) change_apt_source ;;
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

main() {
    clear
    check_env
    $DIALOG --title "欢迎使用" --yesno "脚本将对 PVE 进行深度优化。\n修改前会自动备份至 $BACKUP_DIR\n\n是否开始？" 12 60
    [[ $? -eq 0 ]] && main_menu
}

main "$@"