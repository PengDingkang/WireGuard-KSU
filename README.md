# WireGuard-KSU

在 Android 设备上使用内核级 WireGuard VPN，通过 KernelSU/APatch 内建 WebUI 管理。

## v1.2.0 升级注意：命令挂载默认关闭

**从没有保存过挂载选项的旧版升级后，命令挂载会默认关闭，并在重启后生效。**
届时终端中的 `wg`、`wgksu` 短命令可能不再可用；隧道、WebUI、开机自启和已有配置不受此项改变影响。

| 安装或升级前的状态 | 安装后的挂载设置 |
| --- | --- |
| 首次安装 | 关闭 |
| 旧版没有保存过挂载选项 | 关闭，即使旧版曾自动挂载命令 |
| 已保存过挂载选项 | 保留原来的开启或关闭选择 |

关闭挂载后，在 Root shell 中使用 `/data/adb/wireguard/wgksu` 和
`/data/adb/wireguard/wg` 的完整路径。自行编写的脚本也需要更新命令路径。
需要恢复短命令时，可在 WebUI 中开启 **Shell Command Mount**，然后重启设备；
KernelSU 下需要可用的挂载元模块。详见[可选的 Shell 命令挂载](#可选的-shell-命令挂载)。

## 特点

- **内核态 WireGuard**：利用 Linux 5.6+ 内核内置的 WireGuard 模块，性能最优、最省电
- **内核处理隧道流量**：无需用户态 VPN 转发守护进程；后台脚本定期维护 Endpoint 路由和 DNS
- **多接口支持**：可同时运行 wg0、wg1 等多个隧道
- **WebUI 管理**：在 KernelSU/APatch Manager 中直接管理
- **兼容三大框架**：Magisk、KernelSU、APatch

## 功能

- 命令行管理（start/stop/restart/status/enable/disable/genkey/mount）
- KernelSU/APatch WebUI 管理界面
  - 多接口标签切换，支持新建和删除接口
  - 新建接口时自动生成密钥对
  - 接口状态（IP、端口、公钥）
  - Peer 列表（endpoint、最后握手、收发流量、Allowed IPs）
  - 配置文件在线编辑，保存并重启
  - 密钥对生成工具
  - 开机自启动开关
  - 可选的 Shell 命令挂载开关（默认关闭）
  - 运行日志查看（正常启动、路由维护、警告及错误）
- 首次安装自动生成密钥对和配置模板
- 支持标准 wg-quick 配置格式中的常用字段
- 开机自动启动所有配置的接口
- KSU 模块列表显示运行状态和 IP
- Endpoint 自动钉扎到底层物理网络，避免外层 WireGuard UDP 流量被其他 VPN/TUN 路由接管
- 网络重建后自动修复 Endpoint 路由，改善 Wi-Fi/移动网络切换后的恢复速度
- 可选 Stay Awake 模式，在息屏时保持 WireGuard 可达（会增加耗电）

## 前提条件

内核需要支持 WireGuard（`CONFIG_WIREGUARD=y`）。安装时会自动检测。

大多数运行 KernelSU 的内核（Linux 5.6+）都已内置支持。

默认不需要安装 MMRS、meta-overlayfs 等元模块，WireGuard 和 WebUI 可以直接运行。
KernelSU 下只有需要将命令挂载到 `/system/bin` 时才需要提供挂载功能的元模块。

Endpoint 路由锁需要支持文件描述符模式的 `flock`。模块优先使用
Magisk/KernelSU/APatch 的 BusyBox applet，也会自动尝试系统提供的兼容实现；
如果两者都不可用，接口启动会明确失败，而不会在未钉扎 Endpoint 路由的情况下继续。

## 安装

1. 从 [Releases](../../releases) 下载 zip
2. 在 Magisk/KSU/APatch Manager 中刷入
3. 首次安装会自动生成密钥对和 `wg0.conf` 模板，安装日志中会显示公钥
4. 编辑 `/data/adb/wireguard/wg0.conf`，填入服务器信息（或在 WebUI 中编辑）
5. 重启设备，使安装或升级生效；已开启开机自启的接口会自动启动

也可以在 WebUI 中点击 "＋" 新建接口，会自动生成密钥对并进入编辑模式。

## 管理

以下命令在 Root shell 中执行（先运行 `su`）。完整路径在开启或关闭命令挂载时均可用：

```sh
/data/adb/wireguard/wgksu start              # 启动所有接口
/data/adb/wireguard/wgksu stop               # 停止所有接口
/data/adb/wireguard/wgksu restart            # 重启所有接口
/data/adb/wireguard/wgksu start wg0          # 启动指定接口
/data/adb/wireguard/wgksu stop wg0           # 停止指定接口
/data/adb/wireguard/wgksu status             # 查看所有接口状态
/data/adb/wireguard/wgksu enable             # 开启开机自启
/data/adb/wireguard/wgksu disable            # 关闭开机自启
/data/adb/wireguard/wgksu stay-awake enable wg0   # 让 wg0 运行时持有 wakelock 并启用 Wi-Fi hi-perf
/data/adb/wireguard/wgksu stay-awake disable wg0  # 关闭 wg0 的 Stay Awake
/data/adb/wireguard/wgksu genkey             # 生成新的密钥对
```

KernelSU/APatch 用户可在 Manager 中打开模块 WebUI 进行管理。

### 可选的 Shell 命令挂载

WebUI 的 **Shell Command Mount** 开关控制是否将 `wg` 和 `wgksu` 挂载到
`/system/bin`，方便在终端中直接输入命令。默认关闭；关闭后，隧道、WebUI、
开机自启、路由修复、DNS 重解析和 Stay Awake 仍然可用。

切换后需要重启设备才会改变挂载状态。该设置对整个模块生效，并会在升级时保留。
如果另外在 MMRS 中禁用了该模块的挂载，仍需要在那里允许挂载才能使用系统路径中的命令。

KernelSU 下只有检测到已启用、未标记移除且提供 `metamount.sh` 的元模块时才能开启挂载，
否则 WebUI 开关会禁用并说明原因，CLI 也会拒绝开启。Magisk/APatch 使用其内置挂载功能。
已有选择保存在 `/data/adb/wireguard/mount_enabled` 中（`1` 开启、`0` 关闭）。
`mount status` 显示的是保存的下次启动设置，不代表当前已完成挂载；`mount supported`
只表示检测到了挂载支持，也不代表该模块一定已被 MMRS 允许挂载。

关闭挂载后，终端中使用完整路径：

```sh
/data/adb/wireguard/wgksu start
/data/adb/wireguard/wg show
/data/adb/wireguard/wgksu mount disable  # 保存为不挂载，重启生效
/data/adb/wireguard/wgksu mount enable   # 保存为挂载，重启生效
/data/adb/wireguard/wgksu mount status   # 下次启动的设置：1 开启，0 关闭
/data/adb/wireguard/wgksu mount supported # 当前是否支持挂载：1 支持，0 不支持
```

模块内部始终调用 `/data/adb/wireguard/` 中的工具，不依赖系统命令路径。

### 日志

WebUI 的 **Runtime Log** 显示所有接口共享的运行日志，包含开机启动、路由维护、
警告和错误。`wg0 up` 表示接口已启动成功，不是错误；日志为空时显示 **No log entries**。
界面显示最近 50 行，清空操作会清除该文件中所有接口的运行日志。

为保留已有记录及兼容运行中的脚本，文件路径仍为 `/data/adb/wireguard/error.log`。
开机启动会将命令的标准输出和标准错误追加到这里；手动执行命令时，输出仍显示在调用
终端或 WebUI 中，只有命令显式记录的内容会写入运行日志。

DNS Endpoint 地址变化单独记录在 `/data/adb/wireguard/reresolve.log`，
在 **DNS Re-resolve → Re-resolve Log** 中查看；相关的路由维护和失败信息仍写入运行日志。

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

支持 `Address`、`DNS`、`MTU` 及 `wg setconf` 使用的常见 WireGuard 字段。
不执行 wg-quick 的 `PreUp`、`PostUp`、`PreDown`、`PostDown` 钩子，也不实现
`Table`、`SaveConfig` 选项；不要依赖这些选项完成额外的网络设置。

### Endpoint 路由钉扎

模块启动接口时会等待可用的物理网络和 DNS，然后为 Peer `Endpoint` 添加更具体的 host route，让 WireGuard 外层 UDP 流量走物理网络（优先 `wlan`，其次 `eth`，再其次移动网络），避免设备上同时存在其他 Android VPN/TUN 时把 WireGuard endpoint 套进另一个隧道。

如果网络在息屏、Wi-Fi 开关、移动网络切换等场景中被系统重建，模块会对运行中的接口定期检查当前 peer endpoint 的底层路由，并在路由丢失或指向错误设备时重新钉扎。该轻量检查默认约 30 秒一次，不做 DNS 查询。

对于域名 Endpoint，模块仍会通过 DNS re-resolve 循环处理域名解析结果变化。该循环默认间隔为 120 秒，可在 WebUI 的 DNS re-resolve 设置中调低；更短间隔会增加息屏唤醒和 DNS 查询频率。

### 息屏保持可达

内核态 WireGuard 没有 Android `VpnService` 前台服务。部分设备会在息屏后让 Wi-Fi/CPU 进入低功耗，导致外部无法主动连接隧道地址，即使 `PersistentKeepalive` 已配置也可能立即不可达。

需要息屏仍可从外部连入时，可为接口开启 Stay Awake：

```sh
/data/adb/wireguard/wgksu stay-awake enable wg0
```

开启后，如果对应接口正在运行会立即生效；如果接口尚未运行，则下次启动该接口时生效。模块会写入 `/sys/power/wake_lock` 并执行 `cmd wifi force-hi-perf-mode enabled`。停止接口或关闭 Stay Awake 后会释放 wakelock，并关闭模块启用过的 Wi-Fi hi-perf。

`cmd wifi force-hi-perf-mode` 需要 Android 10+。Android 9 上该命令可能不可用，此时会记录失败日志，但 wakelock 仍会尝试生效。

该模式会阻止设备正常深睡，明显增加耗电。建议只在开发、远程维护或固定供电设备上开启。

### 生成密钥对

在手机的 Root shell 中可直接运行：

```sh
/data/adb/wireguard/wgksu genkey
```

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
