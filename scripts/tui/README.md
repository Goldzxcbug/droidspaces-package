# Droidspaces TUI

此目录直接维护 Droidspaces TUI、七个 Anland 安装入口及其共享函数，整体打包为 `Gold-bug-tui.tar.gz`，发布到固定滚动 Release `Gold-bug-tui`。

## 安装与启动

从 GitHub 下载并运行引导安装器：

```bash
curl -fsSLO https://github.com/Goldzxcbug/droidspaces-package/releases/download/Gold-bug-tui/install-tui.sh
sudo bash install-tui.sh --source github
```

也可使用 CNB 镜像：

```bash
curl -fLO https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download/Gold-bug-tui/install-tui.sh
sudo bash install-tui.sh --source cnb
```

安装后运行 `droidspaces-tui`，别名为 `dstui`、`ds-tui`。`install-tui.sh` 保持独立可运行，下载并校验完整压缩包；TUI 更新时临时下载并执行该引导器。Anland 共享库安装在 `/usr/local/lib/droidspaces/tui/`。

```bash
droidspaces-tui
droidspaces-tui --source cnb
droidspaces-tui --status
droidspaces-tui --json
```

## 菜单与下载源

输入数字或字母后按 Enter 确认。界面支持中英文和 `--no-color`。

| 入口 | 操作 |
| --- | --- |
| `[1] Mesa + VA-API` | 安装、切换或卸载 Mesa，配置 OpenGL/Vulkan，管理视频驱动。 |
| `[2] Anland` | 安装、更新或卸载当前桌面的 Anland 组件。 |
| `[3] Hangover Wine` | 管理 Hangover Wine。 |
| `[4] Wine 字体` | 管理 Wine 字体包。 |
| `F` | 强制刷新组件状态。 |
| `C` | 清理 Hangover Release 清单或下载缓存。 |
| `U` | 检查更新，更新 TUI、受管安装脚本或全部。 |

首次运行时，中文环境默认使用 CNB，其他语言默认使用 GitHub。下载源可选自动测速、GitHub、`gh-proxy.com` 或 CNB，偏好保存在当前用户配置目录。GitHub/代理下载按 Release API 和发布清单校验附件；CNB 下载按同一 Release 的清单校验 SHA-256 和大小，Next session 使用 `SHA256SUMS`。缺少摘要的旧组件清单会给出提示，并继续检查归档结构和包元数据。

主菜单区分未安装、已是最新、可更新、本地较新、版本未知和安装记录漂移。安装状态以实际包数据库为准；单独残留的版本或锁定记录不表示已安装。后台版本查询上限为 10 秒，HTTP、网络、清单和缺少工具等错误分别显示。

查询缓存按来源和平台保存，过期后后台刷新；离线时显示历史结果及检查时间。安装器另行校验下载内容。启动、切换下载源、执行安装或卸载后会刷新状态；进入和返回菜单沿用当前结果。

## Anland 组件

桌面入口读取 `/etc/droidspaces-desktop.conf`：KDE/KDE Mobile 对应 Anland KDE，GNOME 对应 Anland GNOME，Niri、Hyprland、Mango、Denial 和 Anland Next 对应各自组件。`none` 或未知桌面进入组件选择页。旧 RootFS 缺少配置时按已安装组件识别。

七个 Anland 安装器支持 Debian 13、Ubuntu 26.04、Fedora 43/44 和 Arch Linux ARM。从组件 Release 或 TUI Release 下载 `Gold-bug-tui.tar.gz` 后运行：

```bash
tar -xzf Gold-bug-tui.tar.gz
sudo bash tui/install-anland-niri.sh --1
```

保留解压后的目录结构，安装器通过 `source` 加载相邻 `lib/` 中的共享函数。已经安装到系统的入口则加载 `/usr/local/lib/droidspaces/tui/`。在本仓库内也可直接运行 `sudo bash scripts/tui/install-anland-niri.sh --1`。

`--1`、`--2`、`--3` 分别选择 GitHub、代理、CNB；`-1`、`-2`、`-3` 是对应短参数。安装器先下载并校验，再通过 sudo 安装预下载包。APT 使用 hold，DNF 使用 exclude，Arch 使用 `IgnorePkg` 管理包锁。

KDE、GNOME、Niri、Hyprland、Mango、Denial 安装成功后，会将 `DESKTOP=none` 更新为对应桌面；配置缺失时创建标记，已有其他桌面时保留配置。Niri、Hyprland、Mango 和 Denial 使用 `anland-wayland` 后端。这些图形组件共用 patched Xwayland，安装器会拒绝有冲突的组件；卸载时保留其他组件仍使用的 Xwayland。

卸载 Mesa、KWin、Mutter 或 compositor 补丁会恢复发行版图形包；Hangover Wine 和 Wine 字体会移除各自的软件包或受管目录。Next session 单独管理 `anland-session` 包和用户服务。

## OpenGL 与 Vulkan

Mesa 页可配置 OpenGL 的 Freedreno KGSL、Zink、LLVMpipe、Softpipe，以及 Vulkan 的 Turnip、Lavapipe。Zink 使用选定的 Vulkan 驱动；原生 Vulkan 程序也使用该驱动。Vulkan 默认选项清除 `/etc/environment` 中的 `VK_DRIVER_FILES` 和 `VK_ICD_FILENAMES`，由 Loader 自动发现；其他位置的变量仍可能影响结果。

也可运行 `droidspaces-gpu` 单独打开菜单。配置写入 `/etc/environment`，备份为 `/etc/environment.droidspaces-gpu.bak`，重启容器后生效。绿色表示当前 TUI 进程环境指定的路径；未指定环境变量时仍可能由系统自动加载驱动。

Vulkan 清单从系统和 XDG 目录查找，也可输入 JSON 绝对路径。检查清单需要 Python 3 或 jq。清单和引用的 64 位驱动库必须能被应用用户读取和加载；文件存在不保证设备支持。

## Mesa 与视频驱动

Mesa 页的更新项安装最新 Mesa 和视频驱动。`[4] 选择 Mesa 版本` 列出当前发行版可用的最新及此前最多三个上游正式 Release，只切换 Mesa；上游含 `devel` 的标签按原文显示。`[5] 视频编解码` 提供视频驱动安装、卸载和监控。

视频独立安装、卸载使用 `--media-only`；Mesa 单独切换使用 `--mesa-only`。Mesa 整体卸载恢复发行版 Mesa 并移除视频驱动。视频版本及文件 SHA-256 记录在 `/var/lib/droidspaces-tui/components/video.version`；手工安装、文件被替换或记录缺失时显示版本未知及文件短摘要。旧清单缺少媒体版本时使用 `sha256-` 短摘要标识。更新或卸载后重启相关应用。

### 实时监控

监控依赖 Bash、awk、jq 和 GNU coreutils/findutils，以当前用户身份读取可访问的驱动会话。安装路径为 `/usr/local/bin/droidspaces-video.sh`。

```bash
droidspaces-video.sh --once
droidspaces-video.sh --json
droidspaces-video.sh --interval 2 --no-color
```

按 `q`、`Esc` 或 `Ctrl+C` 返回视频菜单。`--once` 输出一次文本快照，`--json` 输出一次 JSON 快照。

界面按应用及 UID 显示方向、视频格式、处理尺寸、输出 FPS 和硬件状态。绿色表示已确认硬件工作，黄色表示待确认或未知，红色表示驱动错误。可读的 mpv、VLC、OBS 进程没有驱动会话时也会列出，格式、尺寸和 FPS 显示 `--`；进程存在不能证明软件编解码。

输出 FPS 取自相邻采集的输出帧增量和内核采样时钟，首次采集为 `--`，暂停后为 0，含义与屏幕播放帧率不同。处理尺寸可能含硬件对齐，如 1920×1088。权限、旧驱动或其他接口会影响会话可见性；监控仅能判断支持协议且可读取的会话。驱动更新后，已运行应用需重启才会加载新版本。

## 其他工具

- **回收存储空间（稀疏镜像）**：确认根文件系统为可写 Ext4 loop 镜像后，经确认以 root 执行 `fstrim -v /`。只处理根文件系统。实际回收量在 Android 宿主端查看 `rootfs.img` 的已分配空间；逻辑大小通常不变。
- **切换系统软件源**：下载 [LinuxMirrors](https://github.com/SuperManito/LinuxMirrors) 的 `https://linuxmirrors.cn/main.sh`，通过 `bash -n` 检查并经确认后以 root 运行，交互修改容器的软件源。
- **检查与安装更新**：支持更新全部、仅 TUI 或仅受管脚本。引导器 `--check` 的退出码为 `0` 已是最新、`2` 有更新、`1` 检查失败。

## 日志与恢复

安装器与 GPU 配置写入共用 `/var/lib/droidspaces-tui/operations` 下的修改锁。事务日志、阶段状态和配置备份位于 `operations/transactions`；非 root 预下载日志位于 `~/.local/state/droidspaces-tui/logs`。

失败或中断后恢复已备份的配置，软件包事务可能已经部分完成。根据日志重新运行安装器核验或修复。TUI 更新将安装入口与共享库纳入同一批备份、更新和恢复，保存多文件恢复记录；下次运行引导器可恢复未完成的更新。`installed-tui.tsv` 记录 revision、来源、更新范围和文件摘要。组件版本记录位于 `/var/lib/droidspaces-tui/components`。

## 维护与检查

直接修改本目录中的脚本：

| 文件 | 维护内容 |
| --- | --- |
| `droidspaces-tui.sh` | 主菜单、组件状态、版本查询和更新入口。 |
| `droidspaces-gpu.sh`、`droidspaces-video.sh` | GPU 配置与视频会话监控。 |
| `install-tui.sh` | TUI 安装、更新、校验和失败恢复。 |
| `install-anland-*.sh` | 各 Anland 组件的配置和专用安装、卸载步骤。 |
| `lib/anland-common.sh` | 七个 Anland 安装器共用的事务、下载、校验、平台和包锁函数。 |
| `lib/anland-archive-common.sh` | 六个归档安装器共用的函数。 |
| `lib/anland-compositor-common.sh` | Niri、Hyprland、Mango、Denial 共用的函数。 |
| `install-mesa.sh`、`install-hangover-wine.sh`、`install-winefonts.sh` | Mesa、Wine 和字体维护。 |

在仓库根目录运行：

```bash
while IFS= read -r -d '' script; do
    bash -n "$script"
    shellcheck -S error "$script"
done < <(find scripts/tui -type f -name '*.sh' -print0)
```

提交前运行上述检查；发布工作流会再次执行语法和 ShellCheck 静态检查。

RootFS 构建从 `Gold-bug-tui` 滚动 Release 获取当前发布。在 RootFS 仓库根目录可手动下载并校验：

```bash
bash scripts/sync-tui.sh --output .build/tui
bash scripts/sync-tui.sh --output .build/tui --check
```

下载源可通过 `--source github|cnb` 选择。RootFS 下载器校验压缩包摘要后检查并解压目录，再验证每个脚本和共享库。下载目录不提交到仓库；镜像保存 `Gold-bug-tui-manifest` 和 `Gold-bug-tui-files`，记录本次发布来源、压缩包及文件摘要。修改后的 TUI 需发布后才会进入后续 RootFS 构建。

## 发布与新增脚本

在 GitHub Actions 手动运行 `发布 Droidspaces TUI`。工作流检查根目录脚本和 `lib/*.sh`，再调用 `scripts/package-tui.sh` 生成：

- `Gold-bug-tui.tar.gz`：`tui/` 目录中的脚本、共享库和内部清单 `Gold-bug-tui-files`。
- `install-tui.sh`：独立引导安装器。
- `Gold-bug-tui-manifest`：引导器和压缩包的 SHA-256、大小及来源 revision。

内部清单登记每个文件的安装目标、大小和 SHA-256。发布流程核验 GitHub 附件摘要后公开固定标签 Release。七个 Anland 组件的打包工作流也使用同一个打包工具，随软件包附上完整的 `Gold-bug-tui.tar.gz`。

本地打包示例：

```bash
bash scripts/package-tui.sh --output /tmp/droidspaces-tui-release --revision "$(git rev-parse HEAD)"
```

默认同步相同附件和 Release 说明到 CNB，需配置 `CNB_TOKEN` Secret 和 `CNB_REPO` Variable。也可手动运行 `同步 GitHub Release 到 CNB`，标签使用 `Gold-bug-tui`。

添加受管安装器时：

1. 在本目录增加可执行的 `install-*.sh`，共享函数放入 `lib/*.sh`；同时在 `scripts/package-tui.sh`、`install-tui.sh` 和 RootFS 的 `sync-tui.sh` 中登记新入口。
2. 对入口和共享库运行语法和静态检查；内部清单中的安装器目标为 `/usr/local/sbin/<去掉 .sh 的文件名>`，共享库目标为 `/usr/local/lib/droidspaces/tui/<文件名>`。
3. 如需菜单入口，在 `droidspaces-tui.sh` 中增加菜单项和支持范围。
