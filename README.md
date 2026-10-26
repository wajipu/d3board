# D3Board

局域网 Android 设备管理器（macOS 原生 app）。列表里能看到网内所有开了 adb 的机器，
点一下就在这台 Mac 上镜像，并且**把设备的物理屏关掉**——屏幕上看起来像没人动过。

主要解决两件事：

1. **IP 变了不用管。** 设备按序列号（`ro.serialno`）记住，不用管地址。板子换了 DHCP 租约后，
   扫描时按序列号认出来，自动更新记录、自动重连，并在列表里标出"IP 曾 x.x.x.x"。
2. **黑屏镜像。** 一个按钮起 scrcpy 并关掉物理面板（`--turn-screen-off`），退出时自动恢复。

## 用法

打开 `D3Board.app`，列表里是所有设备：

| 列 | 说明 |
|---|---|
| 设备 | 自己起的名字 / 型号 |
| 型号 | `ro.product.model` |
| 地址 | 当前 `ip:5555`，灰色表示离线 |
| 状态 | 在线 / 离线 / IP 变更提示 |
| 镜像 | 是否正在镜像 |

- **双击一行** 或选中后点 **镜像（黑屏）**：开窗口，物理屏熄灭。
- **停止镜像**：关窗口并把面板恢复（scrcpy 收到 SIGINT 后自己恢复）。
- **亮屏**：发 `KEYCODE_WAKEUP`，用于屏幕被别的原因关掉时。
- **全部镜像**：把所有在线设备一次性开窗。
- **adb 终端**：为选中设备打开 Terminal，直接进 `adb shell`。
- **重命名**：起个"客厅板子"这样的名字，只影响显示。
- **原生分辨率**：勾上后镜像用设备原始分辨率（更清晰、更吃带宽；默认限到 1024 宽）。

快捷键：`⌘R` 扫描，`⌘⇧R` 深度扫描，`⌘M` 镜像，`⌘.` 停止。

## 更新

app 自己会检查 GitHub 上新版本，不用手动下载：

- 启动 3 秒后查一次 `releases/latest`，之后每 4 小时查一次（这个间隔只是避免反复联网，
  手动 `⌘U` 或菜单 **D3Board → 检查更新…** 随时随地查）。
- 有新版本弹窗写清版本号和更新说明，三个选择：**下载并安装** / **稍后** / **跳过此版本**。
  默认按钮是**稍后**（回车不会开始安装）——更新会重启 app、打断板子上的操作，不该被误点触发。
  跳过会记住，之后不再为那个版本打扰你。
- 下载的是 release 里的 zip。装之前会核对：解出来的 bundle 的
  `CFBundleShortVersionString` 必须和 release tag 一致，不一致就中止，不会拿错包覆盖自己。
- 替换由一段分离的 shell 脚本完成：它按 **pid** 等当前进程真正退出，再把
  `D3Board.app` 挪到 `.old`、拷入新包、重启，成功后才删 `.old`。拷贝失败会把 `.old` 挪回来。
  进程 60 秒还没退就放弃替换——宁可不更新，也不在运行中的进程底下换文件。
- 更新没有签名校验（release 是 ad-hoc 签名，也没做公证），第一次从浏览器下载的包仍然需要
  右键 → 打开。走 app 内更新的话由脚本去掉 quarantine 属性，不会二次拦。
- 每一步都写 `~/Library/Logs/D3Board-update.log`：查到了哪个版本、弹窗返回了什么、
  校验结果、替换目标。升级重启之后，这是唯一能复盘的地方。

天花板：只有已经装了带 updater 的版本（1.2.0 起）才能自更新。更早的 1.0/1.1 只能手动装一次。

更新链路可以单独跑（会真的下载当前 release 并替换一个临时副本，不碰 `/Applications`）：

```
mkdir -p /tmp/d3ut && cp tools/test_update.swift /tmp/d3ut/main.swift
swiftc -O -swift-version 5 Sources/Engine.swift Sources/Updater.swift /tmp/d3ut/main.swift -o /tmp/d3ut/test
ARCHS=arm64 VERSION=0.9.0 ./build.sh && /tmp/d3ut/test
```

## 它怎么找设备

扫描分两步，目标是"快"和"IP 变了也能找到"：

1. **快扫**（约 0.1–0.3s）：用记住的地址 + `adb mdns services` + `adb devices` 逐个确认身份。
2. **深度扫描**（约 1–6s，只在需要时）：
   - 读 `arp -an` 取出网内真实存在的主机，用原生 socket 探测 5555 端口（不是 fork `nc`，快很多）；
   - 都没有就退回扫整个 /24；
   - 对每个候选跑 `adb connect` + `getprop`，用 `ro.serialno` 认设备。

几个必要的过滤，都是踩过的坑：

- 光看"5555 开着"不行：网内有 Linux 机器也开 adbd，`getprop` 直接报 `command not found`。
  现在要求 `getprop` 里有合法的 `ro.serialno`，否则拉黑 5 分钟并 `adb disconnect`。
- 不能只靠 mDNS：D3-503 这块板子根本不广播 mDNS。
- 不能靠型号 `rk356*` 认板子：网内还有一台 `rk3566_r`，不是同一台。

后台每 30 秒体检一次；发现记录里的设备掉线，会自动做一次全网段查找（限频 60 秒）。

## 给 agent 用（MCP + skill）

`mcp/d3board.py` 是一个零依赖的 MCP server（Python 3.9+ 标准库，stdio），
和 GUI 共用同一份设备记录，所以 agent 看到的地址和 app 里一致；不需要 app 开着。

同一个文件也是命令行工具：

```sh
python3 mcp/d3board.py list --deep
python3 mcp/d3board.py info D3-503
python3 mcp/d3board.py shell D3-503 'dumpsys power | head -5'
python3 mcp/d3board.py screenshot D3-503 -o /tmp/board.png
python3 mcp/d3board.py mirror D3-503      # 物理屏熄灭
python3 mcp/d3board.py stop D3-503        # 恢复
```

设备参数可以是昵称、型号、序列号或 `ip:5555`——**不建议写死 IP**，
`list --deep` 会在地址变了之后自己找回来。

MCP 工具：

| 工具 | 用途 |
|---|---|
| `list_devices` | 列设备（`deep=true` 全网段重扫） |
| `device_status` | 版本、唤醒状态、电量、面板是否已断电、正在镜像的 pid |
| `adb_shell` | 跑任意 adb shell 命令 |
| `screenshot` | 设备截图，以 PNG image content 返回 |
| `mirror` / `stop_mirror` | 开/关 scrcpy（默认关物理屏） |
| `wake_screen` | 亮屏 |
| `install_apk` / `transfer_file` | 安装 APK、push/pull 文件 |

接入 opencode（`~/.config/opencode/opencode.json`）：

```json
{
  "mcp": {
    "d3board": {
      "command": ["python3", "/path/to/d3board/mcp/d3board.py", "mcp"],
      "enabled": true,
      "type": "local"
    }
  }
}
```

Claude Code / Codex 同理，命令行是 `python3 /path/to/mcp/d3board.py mcp`。

skill 在 `skills/d3board/SKILL.md`，agent 会据此知道"先 list、别写死 IP、
别 `pkill scrcpy`"这些规矩。装到 opencode：

```sh
ln -s "$PWD/skills/d3board" ~/.skillshub/d3board
ln -s ~/.skillshub/d3board ~/.config/opencode/skills/d3board
```

自测（会真的连板子跑一遍握手、截图、shell）：

```sh
python3 tools/test_mcp.py
```

## 数据

- 设备记录：`~/Library/Application Support/D3Board/devices.json`
  （序列号、型号、上次地址、曾用地址、昵称；删掉就重新认一遍）
- 已知的非安卓主机缓存只在内存里，重启 app 后重新判断一次。

想让后台守护一直生效，把它加进登录项（`D3Board.app` 已装在 `/Applications`）：

```sh
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/D3Board.app", hidden:false}'
```

不需要时用 `delete login item "D3Board"` 删掉。

## 构建

需要 Xcode 命令行工具和 `scrcpy`：

```sh
brew install scrcpy
./build.sh                                    # 只编当前架构（快）
ARCHS="arm64 x86_64" ./build.sh               # universal
VERSION=1.2.0 BUILD_NUMBER=9 ./build.sh       # 打上版本号
./tools/makeicon.sh                           # 重新生成图标（可选）
```

## 自动打包

`.github/workflows/build.yml`：每次 push 都出 universal（arm64 + x86_64）产物，
打 `v*` tag 时附到 GitHub Release。产物两个格式：

- `D3Board-<version>-macos-universal.zip`
- `D3Board-<version>-macos-universal.dmg`（拖进 Applications 即可）
- `SHA256SUMS.txt`

发版：

```sh
git tag v1.0.0 && git push origin v1.0.0
```

CI 里会校验两个 slice 都在、版本号确实写进了 Info.plist，然后跑
`hdiutil verify`。

自测（无 GUI，直接跑 Engine：发现 → 记录 → 镜像 → 校验物理屏状态 → 停止）：

```sh
mkdir -p /tmp/d3st && cp Sources/Engine.swift /tmp/d3st/Engine.swift
cp tools/selftest.swift /tmp/d3st/main.swift
swiftc -O -swift-version 5 /tmp/d3st/Engine.swift /tmp/d3st/main.swift -o /tmp/d3st/selftest
/tmp/d3st/selftest
```

期望输出 `SELFTEST PASS`，期间 `panel during 4`（面板断电）、`panel after 0`（恢复）。

## 和 `~/.local/bin/d3` 的关系

`d3` 是同一件事的命令行版本（单块板子、带 rk356x 硬编码器）。两者互不影响：

- 只想命令行快速镜像 D3：`d3`
- 想看网内都有哪些设备、管理 IP、同时开多个：用这个 app

## 已知边界

- 没有 root（板子上没有 `su`），所以"黑屏"只能靠 scrcpy 的 `--turn-screen-off`，
  不能直接写 `/sys/class/backlight/backlight/bl_power`。app 关闭时 scrcpy 退出，
  面板自动恢复；如果异常残留，`pkill -INT scrcpy` 即可（SIGTERM 会被 scrcpy 忽略）。
- 设备镜像中途换 IP 时，镜像窗口会断开，app 会记一条日志提示重连。
- 非苹果签名（ad-hoc），首次打开如被 Gatekeeper 拦住：右键 → 打开。
