
## 使用方法
### 短链接
```bash
bash <(curl -fsSL lj.1231818.xyz/pve)
```

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



## 断网自愈监控 (主菜单 11)

PVE 主机发生断网（网卡死锁、交换机/网关故障）时，自动触发自愈动作：整机重启或重启网络服务。

### 使用方法

1. 运行 `bash pve.sh`，主菜单选择 `11 断网自愈监控`
2. 选择 `2 开启/修改配置并启用检测`，按向导输入参数后自动写入 crontab
3. 选择 `1` 可查看监控状态并现场探测各目标网络通畅情况
4. 选择 `3` 可停止监控并卸载（配置与日志保留，重新开启不丢失参数）

### 配置参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| 目标 IP 1 | 自动探测网关 | 通常填网关地址 |
| 目标 IP 2 | 223.5.5.5 | 公网 DNS，建议与目标 1 走不同线路 |
| 检测周期 | 5 分钟 | crontab 执行间隔 |
| 开机保护期 | 600 秒 | 开机 uptime 小于该值时绝不触发，防止断网死循环 |
| 自愈动作 | 1-整机重启 | 1-整机重启 reboot / 2-重启网络服务 |

### 判定逻辑（防误判）

仅当两个目标 IP **同时** ping 不通（各 3 次、单次超时 2 秒）才判定为断网；任一目标通畅即放行。判定后先写告警日志并 `sync`，再执行自愈动作。

### 相关文件路径

- worker 程序：`/usr/local/bin/pve-netwatch`（crontab 调用 `pve-netwatch --cron` 静默运行）
- 配置文件：`/etc/pve_netwatch.conf`
- 日志文件：`/var/log/pve_netwatch.log`（自动裁剪，仅保留最近 500 行）

### 手动检查

```bash
crontab -l | grep PVE-NETWATCH      # 查看定时任务
cat /etc/pve_netwatch.conf          # 查看配置
tail -n 20 /var/log/pve_netwatch.log  # 查看告警日志
/usr/local/bin/pve-netwatch --cron  # 手动执行一次检测（慎用，可能触发自愈）
```

## 许可证

MIT License，详见 [LICENSE](LICENSE) 文件。
