# Droidspaces TUI 发布目录

此目录是 `Gold-bug-tui` 固定标签滚动 Release 的唯一发布源。

## 首次安装

从 GitHub 下载引导安装器：

```bash
curl -fLO https://github.com/Goldzxcbug/droidspaces-package/releases/download/Gold-bug-tui/install-tui.sh | sudo bash --source github
```

从 CNB 镜像下载：

```bash
curl -fLO https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download/Gold-bug-tui/install-tui.sh | sudo bash --source cnb
```

安装完成后可运行 `droidspaces-tui`、`dstui` 或 `ds-tui`。`install-tui.sh` 是旧
RootFS 使用的一次性引导器，不会安装到容器；TUI 更新时只会临时下载并执行它。

主菜单只显示组件状态：黄色“检测到更新”、绿色“当前已是最新版本”或红色“未安装”。
后台查询期间显示动态 Braille 符号，菜单输入不会等待网络；单项在 10 秒内未取得有效
版本时显示“超时”。选择组件进入二级菜单后才显示当前/上游版本，并提供“更新/安装”
和“卸载”。桌面更新项读取 `/etc/droidspaces-desktop.conf` 的 `DESKTOP` 字段：KDE/KDE
mobile 只显示 Anland KDE，GNOME 只显示 Anland GNOME；`none` 或未知桌面进入选择页，可
选择 Anland KWin 或 GNOME。旧 RootFS 缺少配置时按已安装组件兜底，无法判断时同样进入
选择页。成功安装 Anland KDE 或 GNOME 后，安装器只把 `DESKTOP=none` 原子更新为对应桌面，
不会修改显示后端或桌面环境变量；配置文件不存在时会创建桌面标记，已有明确桌面则保持
不变。版本检测在启动 TUI 时运行，进入菜单、返回或输入无效内容不会重新检测；安装或
卸载实际开始执行后，返回主菜单时会重新识别桌面并自动刷新一次。输入内容会显示并支持
退格，Loading 使用原地重绘以避免反复清屏闪烁。

安装器成功完成后会将精确的 Release 版本记录到 `/var/lib/droidspaces-tui/components`。
卸载 Mesa、KWin 或 Mutter 补丁时会恢复发行版官方包，而不是直接删除系统图形栈；
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
