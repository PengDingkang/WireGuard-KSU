# WireGuard-KSU

在 Android 设备上使用内核级 WireGuard VPN，通过 KernelSU/APatch 内建 WebUI 管理。

## 特点

- **内核态 WireGuard**：利用 Linux 5.6+ 内核内置的 WireGuard 模块，性能最优、最省电
- **无守护进程**：不需要后台常驻进程，只有一个 668KB 的 `wg` 配置工具
- **多接口支持**：可同时运行 wg0、wg1 等多个隧道
- **WebUI 管理**：在 KernelSU/APatch Manager 中直接管理
- **兼容三大框架**：Magisk、KernelSU、APatch

## 功能

- 命令行管理（start/stop/restart/status/enable/disable）
- KernelSU/APatch WebUI 管理界面
  - 多接口标签切换
  - 接口状态（IP、端口、公钥）
  - Peer 列表（endpoint、最后握手、收发流量、Allowed IPs）
  - 配置文件在线编辑，保存并重启
  - 开机自启动开关
  - 错误日志查看
- 开机自动启动所有配置的接口
- KSU 模块列表显示运行状态和 IP

## 前提条件

内核需要支持 WireGuard（`CONFIG_WIREGUARD=y`）。安装时会自动检测。

大多数运行 KernelSU 的内核（Linux 5.6+）都已内置支持。

## 安装

1. 从 [Releases](../../releases) 下载 zip
2. 在 Magisk/KSU/APatch Manager 中刷入
3. 编辑配置文件 `/data/adb/wireguard/wg0.conf`
4. 运行 `wgksu start` 或重启设备

## 管理

```bash
wgksu start              # 启动所有接口
wgksu stop               # 停止所有接口
wgksu restart             # 重启所有接口
wgksu start wg0           # 启动指定接口
wgksu stop wg0            # 停止指定接口
wgksu status              # 查看所有接口状态
wgksu enable              # 开启开机自启
wgksu disable             # 关闭开机自启
```

KernelSU/APatch 用户可在 Manager 中打开模块 WebUI 进行管理。

## 配置

配置文件位于 `/data/adb/wireguard/`，标准 WireGuard 配置格式：

```ini
[Interface]
PrivateKey = YOUR_PRIVATE_KEY
Address = 10.0.0.2/24
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = SERVER_PUBLIC_KEY
Endpoint = server.example.com:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

支持多个配置文件（`wg0.conf`、`wg1.conf` 等），每个文件对应一个接口。

### 生成密钥对

在任意有 `wg` 工具的设备上：

```bash
wg genkey | tee privatekey | wg pubkey > publickey
```

## 兼容性

- Magisk ≥ v20.4
- KernelSU ≥ 0.6.7
- APatch
- Android ≥ 9 (API 28)
- 内核需要 `CONFIG_WIREGUARD=y`（Linux 5.6+）
- arm64 设备

## License

本项目（模块脚本、WebUI）采用 [MIT License](LICENSE)。

`wg` 工具由 CI 从 [wireguard-tools](https://git.zx2c4.com/wireguard-tools) 编译，受 [GPL-2.0](https://git.zx2c4.com/wireguard-tools/about/) 约束。
