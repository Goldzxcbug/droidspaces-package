# Droidspaces 软件包构建

本仓库为 Anland 构建 ARM64 发行版软件包，发布包含安装器及共享函数的压缩包、平台清单和 CNB 镜像。

| 组件 | Ubuntu 26.04 | Debian 13 | Fedora 43/44/45 | Arch Linux ARM | 安装器 |
| --- | --- | --- | --- | --- | --- |
| KDE / KWin | ✓ | ✓ | ✓ | ✓ | `install-anland-kde.sh` |
| GNOME / Mutter | ✓ | ✓ | ✓ | ✓ | `install-anland-gnome.sh` |
| Niri | ✓ | ✓ | ✓ | ✓ | `install-anland-niri.sh` |
| Hyprland | ✓ | ✓ | ✓ | ✓ | `install-anland-hyprland.sh` |
| Mango | ✓ | ✓ | ✓ | ✓ | `install-anland-mango.sh` |
| Denial | ✓ | ✓ | ✓ | ✓ | `install-anland-denial.sh` |
| Anland Next session | ✓ | ✓ | 43/44 | ✓ | `install-anland-next.sh` |

构建使用 `ubuntu-24.04-arm` 原生 ARM64 runner，在目标发行版容器中编译。桌面包包含配套 patched Xwayland；依赖由目标系统的 apt、dnf 或 pacman 管理。

## 运行构建

在 GitHub Actions 中选择：

- **构建 Anland 软件包**：分别选择 KDE、GNOME、Niri、Hyprland、Mango、Denial 和 Next session 及其发行版目标。

主工作流每天北京时间 08:00 构建全部组件。每次先将 Anland ref 固定为提交，再启动平台任务。`all` 中失败的平台沿用固定 Release 的旧包；指定单平台失败时不更新该 Release；没有新包时跳过发布。

| 组件 | 源码参数 | 默认来源 |
| --- | --- | --- |
| KDE、GNOME、Niri、Hyprland、Mango、Denial | `anland_repo`、`anland_ref` | `https://github.com/Goldzxcbug/anland.git` 的 `Gold` 分支。 |
| Next session | `session_repo`、`session_ref` | `https://github.com/SuperTurtleDev/anland.git` 的 `main` 分支。 |

手动运行时可覆盖源码参数。新增 producer 配方、`producers/common/` 和共享源码修改应先提交并推送到所选 ref；Actions 从该远端提交读取源码和检查配方。

## 安装与发布

固定 Release 标签为 `anland-<组件>-packages`，Next session 使用 `anland-session-packages`。从对应 Release 下载 `Gold-bug-tui.tar.gz`，解压后运行需要的安装器：

```bash
tar -xzf Gold-bug-tui.tar.gz
sudo bash tui/install-anland-niri.sh --1
```

保持 `tui/` 和其中的 `lib/` 目录完整。七个安装器分别保留自己的入口，重复函数由 `lib/*.sh` 提供。`-1`、`-2`、`-3` 分别选择 GitHub、代理和 CNB，`--uninstall` 用于卸载。

桌面归档目录为 `anland-<组件>-packages/<小写平台>/`，`anland-<组件>-manifest` 将平台映射到附件。KDE/GNOME 使用清单中的 `<平台>_sha256`；Niri、Hyprland、Mango、Denial 还发布 `SHA256SUMS`。Next session 直接发布原生包与 `SHA256SUMS`。沿用的旧包保留自身构建信息。

同一压缩包同时随 [Droidspaces TUI](scripts/tui/README.md) 发布。TUI 发布还保留独立的 `install-tui.sh` 引导器，用于下载、校验和安装完整压缩包；更新时安装器与共享库一起处理。RootFS 构建下载并解压压缩包，将共享库安装到 `/usr/local/lib/droidspaces/tui/`。

CNB 同步需要仓库 Secret `CNB_TOKEN` 和 Variable `CNB_REPO`，手动构建可关闭同步。
