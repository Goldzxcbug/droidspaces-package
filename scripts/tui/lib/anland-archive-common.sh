#!/usr/bin/env bash
# shellcheck shell=bash

parse_arguments() {
    local argument

    for argument in "$@"; do
        case "$argument" in
            -1|--1)
                DOWNLOAD_SOURCE="1"
                SKIP_SOURCE_PROBE=true
                ;;
            -2|--2)
                DOWNLOAD_SOURCE="2"
                SKIP_SOURCE_PROBE=true
                ;;
            -3|--3)
                DOWNLOAD_SOURCE="3"
                SKIP_SOURCE_PROBE=true
                ;;
            --uninstall)
                UNINSTALL=true
                ;;
            *)
                die "不支持的参数：${argument}。可用参数为 -1/--1、-2/--2、-3/--3、--uninstall。" \
                    "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, -3/--3, and --uninstall."
                ;;
        esac
    done
}

resolve_official_archive_sha256() {
    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "1" ]]; then
        return
    fi
    if EXPECTED_ARCHIVE_SHA256="$(release_asset_sha256 "$ARCHIVE_NAME")"; then
        return
    fi
    log "GitHub Release 未提供 ${ARCHIVE_NAME} 的 SHA-256 校验值，拒绝使用第三方镜像包。" \
        "GitHub Release did not provide a SHA-256 digest for ${ARCHIVE_NAME}; refusing the third-party mirror package."
    return 1
}

require_runtime_dependencies() {
    local command_name
    for command_name in awk du find mktemp realpath sha256sum sort stat tar; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "缺少运行安装器所需的命令：${command_name}。" \
                "The installer requires the missing command: ${command_name}."
    done

    case "$PACKAGE_TYPE" in
        deb) command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found." ;;
        rpm) command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found." ;;
        pkg.tar.*) command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found." ;;
    esac
}

has_packages() {
    local directory="$1"
    compgen -G "$directory/*.${PACKAGE_TYPE}" >/dev/null
}

other_xwayland_owner() {
    local component state_file
    for component in kde gnome niri hyprland mango denial next; do
        [[ "$component" != "$COMPONENT_NAME" ]] || continue
        state_file="$COMPONENT_STATE_DIR/$component.version"
        [[ "$component" == next ]] && state_file="$COMPONENT_STATE_DIR/anland-next.version"
        if [[ -s "$state_file" ||
              -s "/var/lib/anland-$component/apt-holds" ||
              -s "/var/lib/anland-$component/pacman-packages" ]] ||
            grep -Fqx "# BEGIN anland-$component package holds" /etc/pacman.conf /etc/dnf/dnf.conf 2>/dev/null; then
            printf '%s' "$component"
            return 0
        fi
    done
    local legacy
    for legacy in kwin mutter; do
        [[ "$legacy" == kwin && "$COMPONENT_NAME" == kde ]] && continue
        [[ "$legacy" == mutter && "$COMPONENT_NAME" == gnome ]] && continue
        if grep -Eq "^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])${legacy}([[:space:]]|$)" /etc/pacman.conf 2>/dev/null; then
            printf '%s' "$legacy"
            return 0
        fi
    done
    return 1
}
