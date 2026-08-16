# PVE 一键优化脚本 v3.0

Proxmox VE (PVE) 一站式优化与维护工具。

## 功能特性

| # | 功能 |
|---|------|
| 1 | CPU 性能与调频优化（调速器/频率范围/Intel P-State/睿频/VM host 模式） |
| 2 | 去除网页"无有效订阅"弹窗（三层防护） |
| 3 | 电源工作模式一键预设（高性能/家用平衡/极致节能） |
| 4 | 查看当前系统运行状态 |
| 5 | 一键回滚脚本所做的修改（自动备份） |
| 6 | 内存清理 |
| 7 | 磁盘清理（APT 缓存/日志/临时文件） |
| 8 | 系统更新（upgrade，非 dist-upgrade） |
| 9 | 更换软件源（中科大/清华/阿里/华为/官方） |
| 10 | 概要信息增强（CPU 主频/温度/硬盘/UPS，支持多种预设方案与显示位置） |

## 使用方法

### 一键运行 (推荐)

```bash
curl -fsSL https://raw.githubusercontent.com/chengege666/pve/main/pve.sh | bash
```

或使用 wget:

```bash
wget -qO- https://raw.githubusercontent.com/chengege666/pve/main/pve.sh | bash
```

### 手动下载运行

1. 赋予执行权限：
```bash
chmod +x pve.sh
```

2. 修复换行符（防止 Windows CRLF 导致错误）：
```bash
sed -i 's/\r$//' pve.sh
```

3. 运行脚本：
```bash
./pve.sh
```

脚本采用交互式 TUI 菜单（whiptail/dialog），按提示操作即可。

## 注意事项

*   必须以 **root** 权限运行。
*   Web 相关功能修改后，浏览器按 **Ctrl+F5** 强制刷新清缓存。
*   修改前可选择自动备份至 `/root/pve_backup_<时间戳>/`。
*   建议脚本使用 **LF** (Unix) 换行符，避免 CRLF 导致错误。

## 许可证

MIT License，详见 [LICENSE](LICENSE) 文件。
