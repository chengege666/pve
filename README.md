
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



## 许可证

MIT License，详见 [LICENSE](LICENSE) 文件。
