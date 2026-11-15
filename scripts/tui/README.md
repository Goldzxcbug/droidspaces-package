# Droidspaces TUI 发布目录

此目录是 `Gold-bug-tui` 固定标签滚动 Release 的唯一发布源。

## 首次安装

从 GitHub 下载引导安装器：

```bash
curl -fsSLO https://github.com/Goldzxcbug/droidspaces-package/releases/download/Gold-bug-tui/install-tui.sh
sudo bash install-tui.sh --source github
```

从 CNB 镜像下载：

```bash
curl -fLO https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download/Gold-bug-tui/install-tui.sh
sudo bash install-tui.sh --source cnb
```

安装完成后可运行 `droidspaces-tui`、`dstui` 或 `ds-tui`。`install-tui.sh` 是旧
RootFS 使用的一次性引导器，不会安装到容器；TUI 更新时只会临时下载并执行它。

主菜单只显示组件状态：黄色“检测到更新”、绿色“当前已是最新版本”或红色“未安装”。
后台查询期间显示动态 Braille 符号，菜单输入不会等待网络；单项在 10 秒内未取得有效
版本时显示“超时”。选择组件进入二级菜单后才显示当前/上游版本，并提供“更新/安装”
和“卸载”。Anland Next session 与 KDE、GNOME 一样由桌面/会话组件入口统一管理。桌面更新项读取
`/etc/droidspaces-desktop.conf` 的 `DESKTOP` 字段：KDE/KDE
mobile 只显示 Anland KDE，GNOME 只显示 Anland GNOME，Anland Next 只显示其 session；`none`
或未知桌面进入选择页，可选择 Anland KDE、GNOME、Niri、Hyprland、Mango、Denial 或 Next session。`DESKTOP=niri` 时只显示 Anland Niri。旧 RootFS 缺少配置时按已
安装组件兜底，无法判断时同样进入选择页。成功安装 Anland KDE、GNOME、Niri、Hyprland、Mango 或 Denial 后，安装器只把
`DESKTOP=none` 原子更新为对应桌面；Niri 同时将 `DISPLAY_BACKEND` 设为 `anland-wayland`，因为 Niri 不支持 X11 后端。配置文件不存在时会创建桌面标记，已有明确桌面则保持
不变。Niri、Hyprland、Mango 和 Denial 需要 `DISPLAY_BACKEND=anland-wayland`，选定这些桌面时会写入该后端。它们与其他 Anland 图形组件共用 patched Xwayland；为避免相互覆盖，检测到其他组件时会拒绝安装，卸载时会保留其他组件使用的 Xwayland。版本检测在启动 TUI 时运行，进入菜单、返回或输入无效内容不会重新检测；安装或
卸载实际开始执行后，返回主菜单时会重新识别桌面并自动刷新一次；切换下载源后也会重新检测版本。
版本查询统一读取所选下载源的 Release 清单，避免新旧附件并存时误判超时。
安装状态会核实实际软件包，单独残留的版本记录或锁定记录不会被视为已安装。输入内容会显示并支持
退格，Loading 使用原地重绘以避免反复清屏闪烁。

Anland Niri、Hyprland、Mango 和 Denial 的独立安装器支持 Ubuntu 26.04、Debian 13、Fedora
43/44 与 Arch Linux ARM。安装器采用 KDE 的独立脚本流程：先下载并校验，再通过 sudo
安装预下载包；APT 使用 `/var/lib/anland-<组件>/apt-holds`，DNF 使用 exclude，Arch 使用
`IgnorePkg` 锁定软件包。安装、卸载不再读取或生成 `packages.tsv`；升级或卸载成功后会清理旧文件。
卸载时移除 Anland 专用包并恢复发行版图形包，保留已有桌面配置。Next session 也采用 KDE 的下载、
包安装和锁定流程，保留单包发布格式、私有 Xwayland 检查及用户服务启停。

主菜单 `[1] Mesa + VA-API` 的二级菜单提供统一的 OpenGL 和 Vulkan 路径切换界面。
OpenGL 可选 Freedreno KGSL、Zink、LLVMpipe 和 Softpipe；Vulkan 可选 Turnip 和 Lavapipe。
Vulkan 还可清除 `/etc/environment` 中的 `VK_DRIVER_FILES` 和 `VK_ICD_FILENAMES`，
由 Vulkan Loader 按默认规则发现驱动；其他位置的环境变量和过滤设置仍可能影响结果。
Zink 使用单独选择的 Vulkan 驱动；每个选项只修改对应的配置，原生 Vulkan 程序也会使用所选 Vulkan 驱动。
绿色显示当前 TUI 进程环境中指定的路径，浅黄色显示其他选项；环境变量未指定时并不代表没有驱动。
脚本保存配置到 `/etc/environment`，并备份到 `/etc/environment.droidspaces-gpu.bak`；
重启容器后生效。路径由独立脚本 `droidspaces-gpu.sh` 管理，也可运行
`droidspaces-gpu` 单独打开菜单。驱动文件存在不保证硬件支持。
Vulkan 清单会从常见系统和 XDG 目录查找；有多个候选时可选择，也可输入任意位置的 JSON 绝对路径。
脚本通过 Python 3 或 jq 检查清单中的驱动库名称和 64 位架构，并将所选清单写入 `VK_DRIVER_FILES`。
自定义清单和它引用的驱动库还需能被运行图形程序的用户读取和加载。

图形组件选择 CNB 时采用 KDE 的校验方式，从同一 CNB Release 清单读取附件名称和 SHA-256，
兼容缺少摘要的旧清单；Next session 使用同一 CNB Release 的 `SHA256SUMS`。
GitHub 直连使用官方附件，代理模式通过 GitHub Release API 交叉核验附件摘要。

“回收存储空间（稀疏镜像）”用于在正常启动的 `rootfs.img` 容器内回收已经删除文件所占的
宿主物理空间。TUI 会先确认根文件系统是可写的 Ext4 loop 镜像，经用户确认后以 root 身份
执行 `fstrim -v /`。该操作只修剪根文件系统，不会处理容器内的其他挂载；`fstrim` 报告的
是提交给设备的 discard 范围，实际回收结果应在 Android 宿主端查看 `rootfs.img` 的已分配
空间。稀疏文件的逻辑大小通常不会改变。

“切换系统软件源”使用 [LinuxMirrors](https://github.com/SuperManito/LinuxMirrors) 的
`https://linuxmirrors.cn/main.sh`。TUI 会先下载并执行 `bash -n` 语法检查，确认后以 root
身份运行脚本；该脚本会交互式选择并修改当前容器的系统软件源配置。

“检查与安装更新”会显示当前 TUI 版本和下载源。`检查更新` 使用一次性引导器的 `--check`
模式：退出码 `0` 表示已是最新，`2` 表示有可用更新，`1` 表示检查失败。发现更新后可直接
确认安装全部更新，并复用刚校验过的引导器，避免重复下载。也可以只更新 TUI，或只更新受管
安装脚本。旧版引导器发现更新时仍返回 `0`，TUI 会根据其“发现 N 项需要安装或更新”的输出
兼容识别。

安装器成功完成后会将精确的 Release 版本记录到 `/var/lib/droidspaces-tui/components`。
Mesa 的 `[1] 更新/安装 Mesa（包含视频驱动）` 安装最新 Mesa 和最新视频编解码驱动；`[4] 选择 Mesa 版本`
只切换 Mesa，列出分发 Release 提供的最新及之前最多三个上游正式 Release。上游正式 Release
可能带有 `devel` 标签，界面会原样显示，不将其称为 Mesa 稳定版。历史版本若没有当前发行版的软件包，
不会出现在该发行版的列表中。`[5] 视频编解码` 子菜单提供独立的更新/安装、卸载和实时监控。
前两项都限定为 `--media-only`，只替换或移除视频驱动，不更换 Mesa 软件包；单独切换 Mesa
时也保留已有视频驱动。Mesa 整体卸载仍恢复发行版 Mesa 并移除视频驱动。
视频版本独立记录在 `/var/lib/droidspaces-tui/components/video.version`，并保存已安装文件的
SHA-256，避免外部替换驱动后仍显示旧版本。手工安装或缺少有效记录时显示版本未知和文件短摘要；
旧分发清单没有媒体版本时使用 `sha256-` 短摘要标识，不把滚动 Mesa 标签当作视频版本。
更新或卸载后需要重新启动相关应用。

监控脚本使用 Bash、jq 和 GNU coreutils/findutils，本地源码目录优先，安装后位于
`/usr/local/bin/droidspaces-video.sh`，不依赖 Python。菜单继承当前用户身份运行监控，不提升权限；
非交互调用传入 `--once`，缺少 jq 等工具时给出提示。独立运行支持 `--json` 和 `--interval 秒数`。
监控内按 `q`、`Esc` 或 `Ctrl+C` 返回视频子菜单，返回后恢复 TUI 原有的 `Ctrl+C` 退出行为。
视频子菜单通过磁盘驱动中的 `DMD_VIDEO_STATS_PROTOCOL=1` 标记区分未安装、支持监控及旧版不支持。
磁盘状态不能证明已运行应用加载了该版本；需重启相关应用并以监控读到的会话数据为准。
驱动会话统计仅报告当前用户有权读取且由支持协议的驱动发布的数据，无法据此判断所有应用的软硬件路径。
可读的 mpv、VLC、OBS 进程没有驱动会话时仍出现在应用概览，明确显示状态未知，格式、尺寸和 FPS 为 `--`；
进程存在或没有 memfd 都不能证明软件解码。概览不读取媒体路径或应用完整启动参数，不增加 IPC／常驻服务。
监控只读扫描 `/proc` 中的 `dmd-video-v1` memfd，核对进程身份、文件所有者及稳定序号，
重复描述符只计一个会话。输出 FPS 根据相邻采集的输出帧增量和内核采样时钟计算，
避免容器虚拟 uptime 影响；首次采集显示 `--`，暂停后显示 0，不代表屏幕播放帧率。处理尺寸可能包含硬件对齐，
例如 1920×1088，不强行改报源画面的 1920×1080。权限限制、旧驱动或其他接口都可能使会话不可见。
分发工作流同时保留旧版最新清单和独立的多版本清单，先校验清单和软件包，再执行安装。
卸载 Mesa、KWin、Mutter 或 Niri 补丁时会恢复发行版官方包，而不是直接删除系统图形栈；
Hangover Wine 和 Wine 字体则会移除各自的软件包或受管目录。

## 终端布局

TUI 1.7 使用三行紧凑页头和轻分隔线；主菜单按图形与桌面、Windows 应用、工具分组。
组件状态与名称按终端显示宽度对齐，中文不会按字节数补空格。Mesa 页分开显示版本、当前
渲染路径、下次启动配置和管理操作；视频页按驱动状态、维护、运行状态排列，版本单独显示。
60×24、80×24 和 120×30 终端均保留返回和输入区。主菜单依次为 `[1] Mesa + VA-API`、
`[2] Anland`、`[3] Hangover Wine` 和 `[4] Wine 字体`，使用数字/字母快捷键并按 Enter 确认。
`--no-color` 同时传给监控子进程，终端背景和用户主题不被改写。

实时监控先显示解码、编码和应用数量，再按应用及 UID 分组；80 列起使用紧凑表，较窄终端
改为两行详情。绿色表示已确认硬件工作，黄色表示待确认或状态未知，红色表示驱动错误。
底部保留退出键、速率口径和无法显示的条目数量；逐行清理旧内容，防止刷新残留。
`--once` 保持纯文本，`--json` 输出当前会话快照。

## 发布

在 GitHub Actions 中手动运行 `发布 Droidspaces TUI`。工作流会：

1. 对目录中的全部 Shell 脚本执行 ShellCheck 错误级检查和 `bash -n`。
2. 生成包含安装目标、大小和 SHA-256 的 `Gold-bug-tui-manifest`。
3. 更新固定标签 `Gold-bug-tui` 的 GitHub Release。
4. 在公开 Release 前核验 GitHub 生成的附件摘要。
5. 默认将相同附件和 Release 说明同步到 CNB。

CNB 同步需要仓库配置 `CNB_TOKEN` Secret 和 `CNB_REPO` Variable。也可以手动运行
`同步 GitHub Release 到 CNB`，其默认标签已经设为 `Gold-bug-tui`。

## 添加受管脚本

新脚本使用 `install-*.sh` 文件名并放入此目录。发布工作流会自动将它登记到清单，安装目标为
`/usr/local/sbin/<去掉 .sh 的文件名>`，“受管安装脚本”更新选项也会自动包含它。

如需从 TUI 主菜单直接启动新脚本，还需在 `droidspaces-tui.sh` 中增加菜单项和支持范围。
