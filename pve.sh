#!/bin/bash
# ====================================================
# PVE 换源工具 (支持 PVE 9.0+ / Debian 12)
# 基于图片菜单实现，适用于 Proxmox VE 9.0 及以上
# ====================================================

set -e  # 遇到错误退出（可选，根据需求调整）

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 用户执行此脚本。${NC}"
    exit 1
fi

# 检测 PVE 版本
check_pve_version() {
    if ! command -v pveversion &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Proxmox VE 环境。${NC}"
        exit 1
    fi
    PVE_VERSION=$(pveversion | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' | cut -d'.' -f1)
    if [[ $PVE_VERSION -lt 9 ]]; then
        echo -e "${YELLOW}警告: 当前 PVE 版本可能低于 9.0，部分功能可能不兼容。${NC}"
    else
        echo -e "${GREEN}检测到 PVE $PVE_VERSION 版本，脚本兼容。${NC}"
    fi
}

# 检测网络连通性（简单 ping 百度）
check_network() {
    if ping -c 2 baidu.com &> /dev/null; then
        NET_STATUS="${GREEN}已连接互联网${NC}"
        return 0
    else
        NET_STATUS="${RED}未连接互联网${NC}"
        return 1
    fi
}

# 显示菜单
show_menu() {
    clear
    check_network
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${GREEN}           PVE 换源工具 (v1.0)${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e " 1) 一键设置 DNS、换源并更新系统"
    echo -e " 2) 更换 Proxmox VE 源"
    echo -e " 3) 更新软件包"
    echo -e " 4) 更新系统"
    echo -e " 5) 设置系统 DNS"
    echo -e " 6) 去除无效订阅源提示"
    echo -e " 7) 修改 PVE 概要信息"
    echo -e " 8) 应用 PVE 暗黑主题"
    echo -e " 9) 配置 PVE IOMMU 与核显直通、SR-IOV，群晖虚拟 USB 引导等"
    echo -e "10) 配置 CPU 电源管理 P-State 状态"
    echo -e "11) 配置 CPU 工作模式"
    echo -e "12) 通过 SLAAC 获取 IPv6"
    echo -e "13) 卸载内核 (Kernels) 及头文件 (Headers)"
    echo -e "14) 设置 PVE 启动内核"
    echo -e "15) 设置 NTP 自动校时服务器"
    echo -e "16) 移除 local-lvm 存储空间 (危险操作！)"
    echo -e "17) 禁止系统修改网卡名称，使用 eth0 ~ ethN 原名 (风险操作！)"
    echo -e "${BLUE}----------------------------------------------${NC}"
    echo -e "网络连通性: $NET_STATUS"
    echo -e "Ctrl+C: 退出"
    echo -e "${BLUE}==============================================${NC}"
    echo -n "请输入选项编号 [1-17]: "
}

# 选项1：一键设置 DNS、换源并更新系统
option1() {
    echo -e "${YELLOW}执行一键设置 DNS、换源并更新系统...${NC}"
    option5   # 设置 DNS
    option2   # 换源
    option4   # 更新系统
    echo -e "${GREEN}一键操作完成。${NC}"
}

# 选项2：更换 Proxmox VE 源（支持多镜像站选择，新增官方源）
option2() {
    echo -e "${YELLOW}选择要更换的源：${NC}"
    echo "1) 中科大 (USTC)"
    echo "2) 清华 (Tuna)"
    echo "3) 阿里云 (Aliyun)"
    echo "4) 自定义"
    echo "5) 官方源（恢复默认无订阅源）"
    read -p "请输入选项 [1-5]: " src_choice

    case $src_choice in
        1)
            DEB_MIRROR="https://mirrors.ustc.edu.cn/debian"
            PVE_MIRROR="https://mirrors.ustc.edu.cn/proxmox/debian"
            SEC_MIRROR="${DEB_MIRROR}-security"
            ;;
        2)
            DEB_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/debian"
            PVE_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian"
            SEC_MIRROR="${DEB_MIRROR}-security"
            ;;
        3)
            DEB_MIRROR="https://mirrors.aliyun.com/debian"
            PVE_MIRROR="https://mirrors.aliyun.com/proxmox/debian"
            SEC_MIRROR="${DEB_MIRROR}-security"
            ;;
        4)
            read -p "请输入 Debian 镜像地址 (例如 https://mirrors.xxx/debian): " DEB_MIRROR
            read -p "请输入 Proxmox 镜像地址 (例如 https://mirrors.xxx/proxmox/debian): " PVE_MIRROR
            SEC_MIRROR="${DEB_MIRROR}-security"
            ;;
        5)
            DEB_MIRROR="http://deb.debian.org/debian"
            PVE_MIRROR="http://download.proxmox.com/debian/pve"
            SEC_MIRROR="http://deb.debian.org/debian-security"
            ;;
        *)
            echo -e "${RED}无效选项，取消操作。${NC}"
            return
            ;;
    esac

    echo -e "${YELLOW}正在更换源...${NC}"
    # 备份原文件
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
    cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true

    # 写入新的 Debian 源
    cat > /etc/apt/sources.list <<EOF
deb ${DEB_MIRROR} bookworm main contrib non-free non-free-firmware
deb ${DEB_MIRROR} bookworm-updates main contrib non-free non-free-firmware
deb ${SEC_MIRROR} bookworm-security main contrib non-free non-free-firmware
EOF

    # 写入新的 Proxmox 源（无订阅版）
    cat > /etc/apt/sources.list.d/pve-enterprise.list <<EOF
deb ${PVE_MIRROR} bookworm pve-no-subscription
EOF

    apt update
    echo -e "${GREEN}源更换完成。${NC}"
}

# 选项3：更新软件包
option3() {
    echo -e "${YELLOW}正在更新软件包...${NC}"
    apt update
    apt upgrade -y
    echo -e "${GREEN}软件包更新完成。${NC}"
}

# 选项4：更新系统
option4() {
    echo -e "${YELLOW}正在更新系统...${NC}"
    apt update
    apt dist-upgrade -y
    echo -e "${GREEN}系统更新完成。${NC}"
}

# 选项5：设置系统 DNS
option5() {
    echo -e "${YELLOW}设置系统 DNS...${NC}"
    read -p "请输入首选 DNS 服务器 (例如 114.114.114.114): " dns1
    read -p "请输入备用 DNS 服务器 (例如 8.8.8.8): " dns2
    # 使用 systemd-resolved 或直接修改 resolv.conf
    if command -v resolvectl &> /dev/null; then
        resolvectl dns eth0 $dns1 $dns2
        echo -e "${GREEN}DNS 已通过 systemd-resolved 设置。${NC}"
    else
        cat > /etc/resolv.conf <<EOF
nameserver $dns1
nameserver $dns2
EOF
        echo -e "${GREEN}DNS 已写入 /etc/resolv.conf。${NC}"
    fi
}

# 选项6：去除无效订阅源提示
option6() {
    echo -e "${YELLOW}正在去除无效订阅源提示...${NC}"
    # 方法：修改 pve-manager 的 js 文件，将订阅检查返回真
    local js_file="/usr/share/pve-manager/js/pvemanagerlib.js"
    if [[ -f "$js_file" ]]; then
        cp "$js_file" "$js_file.bak.$(date +%Y%m%d%H%M%S)"
        sed -i "s/if (data.status === 'Active')/if (false)/g" "$js_file"
        # 或者替换检查函数，这里用简单的字符串替换
        systemctl restart pveproxy
        echo -e "${GREEN}订阅提示已去除，请刷新浏览器。${NC}"
    else
        echo -e "${RED}未找到 pvemanagerlib.js，操作失败。${NC}"
    fi
}

# 选项7：修改 PVE 概要信息（例如修改欢迎标题）
option7() {
    echo -e "${YELLOW}修改 PVE 概要信息...${NC}"
    read -p "请输入新的概要信息标题（例如 'My PVE Cluster'）: " new_title
    # 示例：修改 datacenter 显示的标题
    local dc_file="/usr/share/pve-manager/views/datacenter/DataCenterView.js"
    if [[ -f "$dc_file" ]]; then
        cp "$dc_file" "$dc_file.bak.$(date +%Y%m%d%H%M%S)"
        sed -i "s/title: gettext('Datacenter')/title: '${new_title}'/g" "$dc_file"
        systemctl restart pveproxy
        echo -e "${GREEN}概要信息已修改，请刷新浏览器。${NC}"
    else
        echo -e "${RED}未找到 DataCenterView.js，操作失败。${NC}"
    fi
}

# 选项8：应用 PVE 暗黑主题
option8() {
    echo -e "${YELLOW}应用 PVE 暗黑主题...${NC}"
    # 使用官方 dark-theme 脚本（假设已安装 git）
    if ! command -v git &> /dev/null; then
        apt install -y git
    fi
    if [[ ! -d "/opt/pve-dark-theme" ]]; then
        git clone https://github.com/Weilbyte/PVEDiscordDark.git /opt/pve-dark-theme
    fi
    bash /opt/pve-dark-theme/install.sh
    echo -e "${GREEN}暗黑主题安装完成，请刷新浏览器。${NC}"
}

# 选项9：配置 IOMMU 与核显直通等（复杂选项，提供指导并执行基础步骤）
option9() {
    echo -e "${YELLOW}配置 IOMMU 与核显直通、SR-IOV 等...${NC}"
    echo "此选项将执行以下基础配置："
    echo "1. 启用 IOMMU (编辑 /etc/default/grub)"
    echo "2. 加载 VFIO 模块"
    echo "3. 配置内核参数"
    read -p "是否继续？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 备份 grub
        cp /etc/default/grub /etc/default/grub.bak.$(date +%Y%m%d%H%M%S)
        # 添加 intel_iommu=on 或 amd_iommu=on
        if grep -q "iommu=on" /etc/default/grub; then
            echo "IOMMU 已配置，跳过。"
        else
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&intel_iommu=on iommu=pt /' /etc/default/grub
            update-grub
        fi
        # 加载 vfio 模块
        echo "vfio" >> /etc/modules
        echo "vfio_iommu_type1" >> /etc/modules
        echo "vfio_pci" >> /etc/modules
        echo "vfio_virqfd" >> /etc/modules
        update-initramfs -u -k all
        echo -e "${GREEN}基础 IOMMU 配置完成，请重启生效。${NC}"
    else
        echo "已取消。"
    fi
}

# 选项10：配置 CPU 电源管理 P-State
option10() {
    echo -e "${YELLOW}配置 CPU 电源管理 P-State...${NC}"
    # 安装 cpupower 并设置 governor
    apt install -y linux-cpupower
    read -p "请输入 CPU 调频策略 (ondemand/performance/powersave/conservative/schedutil): " gov
    cpupower frequency-set -g $gov
    echo -e "${GREEN}P-State 已设置为 $gov。${NC}"
}

# 选项11：配置 CPU 工作模式（类似选项10，可独立）
option11() {
    echo -e "${YELLOW}配置 CPU 工作模式...${NC}"
    # 使用 cpupower 设置最小/最大频率等
    if ! command -v cpupower &> /dev/null; then
        apt install -y linux-cpupower
    fi
    read -p "请输入最小频率 (例如 800MHz): " min_freq
    read -p "请输入最大频率 (例如 3.2GHz): " max_freq
    cpupower frequency-set -u $max_freq -d $min_freq
    echo -e "${GREEN}CPU 频率范围已设置。${NC}"
}

# 选项12：通过 SLAAC 获取 IPv6
option12() {
    echo -e "${YELLOW}配置 SLAAC 获取 IPv6...${NC}"
    # 修改 /etc/network/interfaces，假设主接口为 vmbr0
    local iface="vmbr0"
    if grep -q "iface $iface inet6" /etc/network/interfaces; then
        echo "IPv6 已配置，请手动检查。"
    else
        cat >> /etc/network/interfaces <<EOF

iface $iface inet6 auto
    accept_ra 2
EOF
        systemctl restart networking
        echo -e "${GREEN}SLAAC 配置已添加。${NC}"
    fi
}

# 选项13：卸载内核及头文件
option13() {
    echo -e "${YELLOW}卸载内核及头文件...${NC}"
    # 列出已安装内核
    dpkg -l | grep -E "linux-image-[0-9]" | grep -v "$(uname -r)" | awk '{print $2}' > /tmp/kernel_list
    if [[ ! -s /tmp/kernel_list ]]; then
        echo "没有可卸载的老内核。"
        return
    fi
    echo "可卸载的内核："
    cat /tmp/kernel_list
    read -p "请输入要卸载的内核版本（输入 all 卸载所有老内核）: " kernel_choice
    if [[ "$kernel_choice" == "all" ]]; then
        apt purge $(cat /tmp/kernel_list) -y
    else
        apt purge $kernel_choice -y
    fi
    apt autoremove -y
    echo -e "${GREEN}内核卸载完成。${NC}"
}

# 选项14：设置 PVE 启动内核
option14() {
    echo -e "${YELLOW}设置 PVE 启动内核...${NC}"
    # 列出所有内核菜单项
    awk -F\' '/menuentry / {print i++ " : " $2}' /boot/grub/grub.cfg
    read -p "请输入要设为默认的菜单项序号 (例如 0): " entry_num
    sed -i "s/GRUB_DEFAULT=.*/GRUB_DEFAULT=$entry_num/" /etc/default/grub
    update-grub
    echo -e "${GREEN}默认内核已设置为序号 $entry_num。${NC}"
}

# 选项15：设置 NTP 自动校时服务器
option15() {
    echo -e "${YELLOW}设置 NTP 自动校时服务器...${NC}"
    read -p "请输入 NTP 服务器地址 (例如 pool.ntp.org): " ntp_server
    if systemctl status systemd-timesyncd &>/dev/null; then
        sed -i "s/^#NTP=/NTP=$ntp_server/" /etc/systemd/timesyncd.conf
        systemctl restart systemd-timesyncd
        echo -e "${GREEN}NTP 已设置为 $ntp_server。${NC}"
    else
        apt install -y chrony
        sed -i "s/^pool /#pool /g" /etc/chrony/chrony.conf
        echo "pool $ntp_server iburst" >> /etc/chrony/chrony.conf
        systemctl restart chrony
        echo -e "${GREEN}NTP 已通过 chrony 设置为 $ntp_server。${NC}"
    fi
}

# 选项16：移除 local-lvm 存储空间（危险）
option16() {
    echo -e "${RED}警告：此操作将移除 local-lvm 存储空间，数据将丢失！${NC}"
    read -p "请再次确认是否继续？(输入 YES 确认): " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "已取消。"
        return
    fi
    # 卸载 lvm thin 并删除
    lvremove pve/data -y
    # 扩展 root 到剩余空间
    lvextend -l +100%FREE pve/root
    resize2fs /dev/mapper/pve-root
    # 从存储中移除 local-lvm
    pvesm remove local-lvm
    echo -e "${GREEN}local-lvm 已移除，空间已合并至 root。${NC}"
}

# 选项17：禁止系统修改网卡名称，使用 eth0 原名
option17() {
    echo -e "${YELLOW}配置使用 eth0 传统网卡命名...${NC}"
    # 添加内核参数 net.ifnames=0 biosdevname=0
    cp /etc/default/grub /etc/default/grub.bak.$(date +%Y%m%d%H%M%S)
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&net.ifnames=0 biosdevname=0 /' /etc/default/grub
    update-grub
    echo -e "${GREEN}配置已添加，重启后生效。${NC}"
}

# 主循环
main() {
    check_pve_version
    while true; do
        show_menu
        read choice
        case $choice in
            1) option1 ;;
            2) option2 ;;
            3) option3 ;;
            4) option4 ;;
            5) option5 ;;
            6) option6 ;;
            7) option7 ;;
            8) option8 ;;
            9) option9 ;;
            10) option10 ;;
            11) option11 ;;
            12) option12 ;;
            13) option13 ;;
            14) option14 ;;
            15) option15 ;;
            16) option16 ;;
            17) option17 ;;
            *) echo -e "${RED}无效选项，请重新输入。${NC}" ;;
        esac
        echo -e "\n按 Enter 键返回菜单..."
        read
    done
}

# 捕获 Ctrl+C
trap 'echo -e "\n${YELLOW}退出脚本。${NC}"; exit 0' INT

# 执行主函数
main