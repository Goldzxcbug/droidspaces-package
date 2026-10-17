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

安装器成功完成后会将精确的 Release 版本记录到 `/var/lib/droidspaces-tui/components`。
卸载 Mesa、KWin、Mutter 或 Niri 补丁时会恢复发行版官方包，而不是直接删除系统图形栈；
Hangover Wine 和 Wine 字体则会移除各自的软件包或受管目录。

## 发布

在 GitHub Actions 中手动运行 `发布 Droidspaces TUI`。工作流会：

1. 对目录中的全部 shell 脚本执行 `bash -n`。
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
