# Droidspaces 软件包构建

本仓库将 Anland 的发行版构建配方打包为可安装的 ARM64 软件包，并发布安装器、平台清单与国内镜像。

| 组件 | Ubuntu 26.04 | Debian 13 | Fedora 43/44 | Arch Linux ARM | 安装器 |
| --- | --- | --- | --- | --- | --- |
| KDE / KWin | ✓ | ✓ | ✓ | ✓ | `install-anland-kde.sh` |
| GNOME / Mutter | ✓ | ✓ | ✓ | ✓ | `install-anland-gnome.sh` |
| Niri | ✓ | ✓ | ✓ | ✓ | `install-anland-niri.sh` |
| Hyprland | ✓ | ✓ | ✓ | ✓ | `install-anland-hyprland.sh` |
| Mango | ✓ | ✓ | ✓ | ✓ | `install-anland-mango.sh` |
| Denial | ✓ | ✓ | ✓ | ✓ | `install-anland-denial.sh` |
| Anland Next session | ✓ | ✓ | ✓ | ✓ | `install-anland-next.sh` |

构建使用 `ubuntu-24.04-arm` 原生 ARM64 runner，在相应发行版容器中编译。桌面包包含配套 patched Xwayland；依赖由目标系统的 apt、dnf 或 pacman 管理。

## 运行构建

在 GitHub Actions 中选择：

- **构建 Anland 软件包**：在同一个工作流中分别开关 KDE、GNOME、Niri、Hyprland、Mango、Denial 和 Next session；每个组件都有独立的发行版目标。前六种组件共用源码仓库和 ref，Next session 的独立源码参数放在最后。
- **test**：手动运行主构建流程，默认使用个人 Anland 仓库，Next session 默认读取其 `main`。

主工作流每天北京时间 08:00 构建全部组件。每次先将 Anland ref 固定为一个提交，再启动独立的平台任务。`all` 中失败的平台沿用固定 Release 的旧包；指定单平台失败时不更新该 Release；没有新包时不会重新发布。

KDE、GNOME、Niri、Hyprland、Mango 和 Denial 共用 `anland_repo` 与 `anland_ref`，默认读取 `https://github.com/Goldzxcbug/anland.git` 的 `Gold` 分支。Next session 单独使用 `session_repo` 与 `session_ref`，主工作流默认读取 `https://github.com/SuperTurtleDev/anland.git` 的 `main` 分支。可以在手动运行时分别覆盖这两组源码参数；`test` 工作流也采用相同的分组方式。

**本地源码必须先进入远端提交。** `/home/gold/文档/仓库/anland` 中新增的 producer 配方、`producers/common/` 以及共享源码修改，只有提交并推送到所选 ref 后才会进入 Actions 构建。工作流会检查提交中的配方；本地存在文件不代表远端已经可用。

## 安装与发布

固定 Release 标签为 `anland-<组件>-packages`，Next session 使用 `anland-session-packages`。每个 Release 都带对应的自包含 `install-anland-*.sh`，下载后可直接运行；`-1`、`-2`、`-3` 分别选择 GitHub、代理和 CNB，`--uninstall` 用于卸载。安装器以 KDE 的下载、校验、提权和包管理流程为基准，保留各组件的软件包及会话差异。

桌面归档目录统一为 `anland-<组件>-packages/<小写平台>/`；`anland-<组件>-manifest` 将平台映射到资产。KDE/GNOME 使用清单中的 `<平台>_sha256`；Niri、Hyprland、Mango、Denial 还发布 `SHA256SUMS`。Next session 直接发布各发行版原生包与 `SHA256SUMS`。沿用的旧包保留自身构建信息。

安装器同时随 [Droidspaces TUI](scripts/tui/README.md) 发布。CNB 同步需要仓库 Secret `CNB_TOKEN` 和 Variable `CNB_REPO`，手动构建可关闭同步。
