# Droidspaces TUI 发布目录

此目录是 `Gold-bug-tui` 固定标签滚动 Release 的唯一发布源。

## 首次安装

从 GitHub 下载引导安装器：

```bash
curl -fLO https://github.com/Goldzxcbug/droidspaces-package/releases/download/Gold-bug-tui/install-tui.sh
sudo bash install-tui.sh --source github
```

从 CNB 镜像下载：

```bash
curl -fLO https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download/Gold-bug-tui/install-tui.sh
sudo bash install-tui.sh --source cnb
```

安装完成后可运行 `droidspaces-tui`、`dstui` 或 `ds-tui`。`install-tui.sh` 是旧
RootFS 使用的一次性引导器，不会安装到容器；TUI 更新时只会临时下载并执行它。

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
