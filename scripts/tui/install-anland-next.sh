#!/usr/bin/env bash
set -euo pipefail

# Keep the entry path: BASH_SOURCE inside a shared function names its library.
ANLAND_INSTALLER_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
ANLAND_LIB_DIR="${ANLAND_INSTALLER_PATH%/*}/lib"
if [[ ! -f "$ANLAND_LIB_DIR/anland-common.sh" ]]; then
    ANLAND_LIB_DIR="${ANLAND_INSTALLER_PATH%/*}/../lib/droidspaces/tui"
    [[ -f "$ANLAND_LIB_DIR/anland-common.sh" ]] || ANLAND_LIB_DIR=/usr/local/lib/droidspaces/tui
fi
# shellcheck source=lib/anland-common.sh
source "$ANLAND_LIB_DIR/anland-common.sh"

# Install the Anland Next session package published by build-anland-packages.yml.
# The package itself remains owned by apt, dnf, or pacman; this script only
# selects, verifies, and installs the native package for the current system.
readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${ANLAND_NEXT_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}"
RELEASE_TAG="${ANLAND_NEXT_RELEASE_TAG:-}"
readonly ROLLING_RELEASE_TAG="anland-session-packages"
readonly MANIFEST_NAME="anland-session-manifest"
readonly CHECKSUMS_NAME="SHA256SUMS"
readonly MAX_MANIFEST_BYTES=$((1024 * 1024))
readonly MAX_CHECKSUMS_BYTES=$((1024 * 1024))
readonly MAX_PACKAGE_BYTES=$((128 * 1024 * 1024))
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly APT_HOLD_STATE="/var/lib/anland-next/apt-holds"
readonly DNF_MANAGED_BEGIN="# BEGIN anland-next package holds"
readonly DNF_MANAGED_END="# END anland-next package holds"
readonly MESA_DNF_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly MESA_DNF_MANAGED_END="# END install-mesa package holds"
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly COMPONENT_STATE_DIR="${DROIDSPACES_COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}"
readonly DESKTOP_CONFIG="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"
readonly COMPONENT_NAME="next"

WORK_DIR=""
PREPARED_WORK_DIR="${ANLAND_NEXT_WORK_DIR:-}"
PREPARED_PACKAGE_FILE="${ANLAND_NEXT_PACKAGE_FILE:-}"
UI_LANG="en"
TARGET=""
PACKAGE_TYPE=""
MANIFEST_TARGET=""
ASSET_PREFIX=""
ASSET_SUFFIX=""
PACKAGE_NAME=""
PACKAGE_FILE=""
PACKAGE_DIR=""
PACKAGE_VERSION=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
CHECKSUMS_FILE=""
EXPECTED_MANIFEST_SHA256=""
EXPECTED_PACKAGE_SHA256=""
OFFICIAL_RELEASE_METADATA=""
UNINSTALL=false

readonly ANLAND_DISPLAY_NAME="Next"
readonly ANLAND_STATE_NAME="anland-next"
readonly ANLAND_DESKTOP_NAME="anland-next"
readonly ANLAND_FORCE_WAYLAND=true
readonly ANLAND_DESKTOP_UPDATE_SELF=true
readonly ANLAND_ASSET_KIND=session
readonly ANLAND_ASSET_FAMILY="anland-session"
readonly ANLAND_ARCHIVE_VARIANT=""

readonly COMPONENT_LABEL="Next"
readonly DNF_LEGACY_LABEL="Next"
readonly DNF_ALLOW_PRESERVE_XWAYLAND=false
readonly DNF_LEGACY_PACKAGE="anland-session"
readonly DNF_EXCLUDED_PACKAGES="anland-session*"
readonly -a DNF_STRIP_PACKAGES=('anland-session' 'anland-session*')
readonly -a DNF_XWAYLAND_STRIP_PACKAGES=()

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
            -h|--help)
                cat <<EOF
用法: $0 [选项]

安装或卸载 Anland Next session 原生软件包。

  -1, --1          使用 GitHub
  -2, --2          使用 gh-proxy.com
  -3, --3          使用 CNB
  --uninstall      卸载 anland-session，不删除发行版依赖
  -h, --help       显示帮助
EOF
                exit 0
                ;;
            *)
                die "不支持的参数：${argument}。可用参数为 -1/--1、-2/--2、-3/--3、--uninstall。" \
                    "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, -3/--3, and --uninstall."
                ;;
        esac
    done
}

trap cleanup EXIT

require_root() {
    if (( EUID == 0 )); then
        return
    fi

    command -v sudo >/dev/null 2>&1 || \
        die "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."
    local script_path="${BASH_SOURCE[0]}"
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    local status
    if sudo env \
        "ANLAND_NEXT_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "ANLAND_NEXT_RELEASE_TAG=$RELEASE_TAG" \
        "ANLAND_NEXT_WORK_DIR=$WORK_DIR" \
        "ANLAND_NEXT_PACKAGE_FILE=$PACKAGE_FILE" \
        "DROIDSPACES_COMPONENT_STATE_DIR=$COMPONENT_STATE_DIR" \
        "DROIDSPACES_DESKTOP_CONFIG=$DESKTOP_CONFIG" \
        bash "$script_path" "$@"; then
        status=0
    else
        status=$?
    fi
    cleanup
    exit "$status"
}

resolve_official_package_sha256() {
    EXPECTED_PACKAGE_SHA256=""
    [[ "$DOWNLOAD_SOURCE" == 1 ]] && return 0
    EXPECTED_PACKAGE_SHA256="$(release_asset_sha256 "$PACKAGE_NAME")" || {
        log "GitHub Release 未提供 ${PACKAGE_NAME} 的 SHA-256 校验值。" \
            "GitHub Release has no valid SHA-256 digest for ${PACKAGE_NAME}."
        return 1
    }
}

checksum_sha256_for_asset() {
    local checksums_file="$1" asset_name="$2"

    awk -v asset_name="$asset_name" '
        $1 ~ /^[0-9A-Fa-f]+$/ && length($1) == 64 && NF == 2 {
            name = $2
            sub(/^\*/, "", name)
            if (name == asset_name) {
                digest = tolower($1)
                count += 1
            }
        }
        END {
            if (count == 1) {
                print digest
            } else {
                exit 1
            }
        }
    ' "$checksums_file"
}

prepare_cnb_checksums() {
    local base_url="$1" checksum_size

    [[ "$DOWNLOAD_SOURCE" == 3 ]] || return 0
    CHECKSUMS_FILE="$WORK_DIR/$CHECKSUMS_NAME"
    download_file "$base_url/$CHECKSUMS_NAME" "$CHECKSUMS_FILE" || return 1
    checksum_size="$(stat -c '%s' "$CHECKSUMS_FILE")" || return 1
    [[ "$checksum_size" =~ ^[0-9]+$ && "$checksum_size" -gt 0 && \
       "$checksum_size" -le "$MAX_CHECKSUMS_BYTES" ]] || return 1
    EXPECTED_MANIFEST_SHA256="$(checksum_sha256_for_asset "$CHECKSUMS_FILE" "$MANIFEST_NAME")" || {
        log "CNB Release 的 ${CHECKSUMS_NAME} 缺少 ${MANIFEST_NAME} 的唯一 SHA-256 校验值。" \
            "The CNB Release ${CHECKSUMS_NAME} has no unique SHA-256 digest for ${MANIFEST_NAME}."
        return 1
    }
}

resolve_cnb_package_sha256() {
    [[ "$DOWNLOAD_SOURCE" == 3 ]] || return 0
    EXPECTED_PACKAGE_SHA256="$(checksum_sha256_for_asset "$CHECKSUMS_FILE" "$PACKAGE_NAME")" || {
        log "CNB Release 的 ${CHECKSUMS_NAME} 缺少 ${PACKAGE_NAME} 的唯一 SHA-256 校验值。" \
            "The CNB Release ${CHECKSUMS_NAME} has no unique SHA-256 digest for ${PACKAGE_NAME}."
        return 1
    }
}

validate_package_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ && "$1" != *..* ]]
}

resolve_manifest_package() {
    local manifest_file="$1" format release_tag
    local -a selected_names=()

    format="$(awk -F= '$1 == "format" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    release_tag="$(awk -F= '$1 == "release_tag" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    [[ "$format" == 1 && "$release_tag" == "$RELEASE_TAG" ]] || return 1
    mapfile -t selected_names < <(
        awk -F= -v key="$MANIFEST_TARGET" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file"
    )
    [[ "${#selected_names[@]}" -eq 1 ]] || return 1
    PACKAGE_NAME="${selected_names[0]}"
    validate_package_name "$PACKAGE_NAME" || return 1
    case "$PACKAGE_NAME" in
        "${ASSET_PREFIX}"*"${ASSET_SUFFIX}") ;;
        *) return 1 ;;
    esac
}

validate_package_file() {
    local package package_arch package_version package_release package_info
    local package_name package_architecture
    [[ -f "$PACKAGE_FILE" && ! -L "$PACKAGE_FILE" ]] || return 1
    local package_size
    package_size="$(stat -c '%s' "$PACKAGE_FILE")"
    [[ "$package_size" =~ ^[0-9]+$ && "$package_size" -gt 0 && \
       "$package_size" -le "$MAX_PACKAGE_BYTES" ]] || return 1

    case "$PACKAGE_TYPE" in
        deb)
            package="$(dpkg-deb -f "$PACKAGE_FILE" Package)"
            package_arch="$(dpkg-deb -f "$PACKAGE_FILE" Architecture)"
            package_version="$(dpkg-deb -f "$PACKAGE_FILE" Version)"
            [[ "$package" == anland-session && "$package_arch" == arm64 ]] || return 1
            ;;
        rpm)
            IFS=$'\t' read -r package package_arch package_version package_release < <(
                rpm -qp --queryformat '%{NAME}\t%{ARCH}\t%{VERSION}\t%{RELEASE}\n' "$PACKAGE_FILE"
            )
            [[ "$package" == anland-session && "$package_arch" == aarch64 ]] || return 1
            package_version="${package_version}-${package_release}"
            ;;
        pkg.tar.*)
            package_info="$(LC_ALL=C pacman -Qip "$PACKAGE_FILE")"
            package_name="$(sed -n 's/^[[:space:]]*Name[[:space:]]*:[[:space:]]*//p' <<< "$package_info")"
            package_architecture="$(sed -n 's/^[[:space:]]*Architecture[[:space:]]*:[[:space:]]*//p' <<< "$package_info")"
            package_version="$(sed -n 's/^[[:space:]]*Version[[:space:]]*:[[:space:]]*//p' <<< "$package_info")"
            [[ "$package_name" == anland-session && "$package_architecture" == aarch64 ]] || return 1
            ;;
        *) return 1 ;;
    esac
    [[ "$package_version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 1
    PACKAGE_VERSION="$package_version"
}

require_runtime_dependencies() {
    local command_name
    for command_name in awk find grep mktemp realpath sed sort stat sha256sum; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "缺少运行安装器所需的命令：${command_name}。" \
                "The installer requires the missing command: ${command_name}."
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
        die "未找到 curl 或 wget。" "Neither curl nor wget was found."
    case "$PACKAGE_TYPE" in
        deb)
            command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found."
            ;;
        rpm)
            command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
            ;;
        pkg.tar.*)
            command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
            ;;
    esac
}

download_packages_once() {
    ds_operation_phase download
    local base_url manifest_file manifest_size
    base_url="$(release_download_base)"
    manifest_file="$WORK_DIR/$MANIFEST_NAME"
    OFFICIAL_RELEASE_METADATA=""
    if [[ "$DOWNLOAD_SOURCE" == 3 ]]; then
        prepare_cnb_checksums "$base_url" || return 1
    else
        resolve_official_manifest_sha256 || return 1
    fi

    log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载 ${TARGET} Anland Next 包..." \
        "Downloading the Anland Next package for ${TARGET} from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$base_url/$MANIFEST_NAME" "$manifest_file" || return 1
    manifest_size="$(stat -c '%s' "$manifest_file")"
    [[ "$manifest_size" =~ ^[0-9]+$ && "$manifest_size" -le "$MAX_MANIFEST_BYTES" ]] || return 1
    if [[ -n "$EXPECTED_MANIFEST_SHA256" ]]; then
        validate_release_asset_checksum "$manifest_file" "$EXPECTED_MANIFEST_SHA256" "$MANIFEST_NAME" || return 1
    fi
    resolve_manifest_package "$manifest_file" || {
        log "Release 清单中没有 ${TARGET} 的匹配原生包。" \
            "The Release manifest has no matching native package for ${TARGET}."
        return 1
    }
    if [[ "$DOWNLOAD_SOURCE" == 3 ]]; then
        resolve_cnb_package_sha256 || return 1
    else
        resolve_official_package_sha256 || return 1
    fi
    PACKAGE_FILE="$WORK_DIR/$PACKAGE_NAME"
    download_file "$base_url/$PACKAGE_NAME" "$PACKAGE_FILE" || return 1
    if [[ -n "$EXPECTED_PACKAGE_SHA256" ]]; then
        validate_release_asset_checksum "$PACKAGE_FILE" "$EXPECTED_PACKAGE_SHA256" "$PACKAGE_NAME" || return 1
    fi
    PACKAGE_DIR="${PACKAGE_FILE%/*}"
    validate_package_file || {
        log "下载的软件包不是当前系统的有效 ARM64 anland-session 包。" \
            "The downloaded package is not a valid ARM64 anland-session package for this system."
        return 1
    }
}

download_packages() {
    ds_operation_phase download
    local attempt
    WORK_DIR="$(mktemp -d -t anland-next.XXXXXXXX)"

    for ((attempt = 1; attempt <= 3; attempt++)); do
        if (( attempt > 1 )); then
            rm -rf -- "$WORK_DIR"
            mkdir -m 700 -- "$WORK_DIR"
        fi
        if download_packages_once; then
            return
        fi
        if (( attempt < 3 )); then
            log "Release 正在更新或网络暂时失败，准备重新获取（第 ${attempt} 次）。" \
                "The Release is being updated or the network failed; retrying after attempt ${attempt}."
            sleep "$attempt"
        fi
    done

    die "无法稳定获取 Release 包，请稍后重试。" \
        "Unable to consistently download the Release package; please retry later."
}

use_prepared_package() {
    local prepared_work_dir prepared_package_file
    prepared_work_dir="$(realpath -e "$PREPARED_WORK_DIR")" || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    prepared_package_file="$(realpath -e "$PREPARED_PACKAGE_FILE")" || \
        die "预下载软件包无效。" "The pre-downloaded package is invalid."
    [[ "$prepared_work_dir" =~ ^/tmp/anland-next\.[A-Za-z0-9]+$ ]] || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_package_file" == "$prepared_work_dir/"* ]] || \
        die "预下载软件包路径无效。" "The pre-downloaded package path is invalid."
    [[ -d "$prepared_work_dir" && -f "$prepared_package_file" ]] || \
        die "预下载软件包已不存在。" "The pre-downloaded package no longer exists."
    PACKAGE_NAME="${prepared_package_file##*/}"
    validate_package_name "$PACKAGE_NAME" || die "预下载包名无效。" "The pre-downloaded package name is invalid."
    case "$PACKAGE_NAME" in
        "${ASSET_PREFIX}"*"${ASSET_SUFFIX}") ;;
        *) die "预下载软件包与当前系统不匹配。" "The pre-downloaded package does not match this system." ;;
    esac
    WORK_DIR="$prepared_work_dir"
    PACKAGE_FILE="$prepared_package_file"
    PACKAGE_DIR="${PACKAGE_FILE%/*}"
    validate_package_file || die "预下载软件包校验失败。" "The pre-downloaded package failed validation."
}

package_installed_version() {
    case "$PACKAGE_TYPE" in
        deb) dpkg-query -W -f='${Version}' anland-session 2>/dev/null ;;
        rpm) rpm -q --queryformat '%{VERSION}-%{RELEASE}' anland-session 2>/dev/null ;;
        pkg.tar.*) pacman -Q anland-session 2>/dev/null | awk '{print $2}' ;;
    esac
}

verify_installed_package_version() {
    local installed_version

    installed_version="$(package_installed_version || true)"
    [[ "$installed_version" == "$PACKAGE_VERSION" ]] || \
        die "安装后的 anland-session 版本与下载包不一致（期望 ${PACKAGE_VERSION:-unknown}，实际 ${installed_version:-unknown}）。" \
            "The installed anland-session version does not match the downloaded package (expected ${PACKAGE_VERSION:-unknown}, got ${installed_version:-unknown})."
}

verify_installed_xwayland_paths() {
    local xwayland_binary=/usr/lib/anland/Xwayland

    [[ -x "$xwayland_binary" ]] || \
        die "已安装的 anland-session 缺少 Xwayland：$xwayland_binary。" \
            "The installed anland-session package is missing Xwayland: $xwayland_binary."
    grep -aFq '/usr/share/X11/xkb' "$xwayland_binary" || \
        die "已安装的 Xwayland 没有正确的 /usr XKB 数据路径。请更新 Anland Next 软件包。" \
            "The installed Xwayland has no correct /usr XKB data path. Update the Anland Next package."
    if grep -aFq '/usr/local/share/X11/xkb' "$xwayland_binary" || \
       grep -aFq '/usr/local/bin' "$xwayland_binary"; then
        die "已安装的 Xwayland 仍含错误的 /usr/local 运行时路径。请更新 Anland Next 软件包。" \
            "The installed Xwayland still embeds incorrect /usr/local runtime paths. Update the Anland Next package."
    fi
}

install_deb_packages() {
    ds_operation_phase packages
    local -a files packages
    local file package

    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 deb 包。" "No installable deb packages were found."

    log "正在安装 ${#files[@]} 个 deb 包并自动处理依赖..." \
        "Installing ${#files[@]} deb packages and resolving dependencies..."
    apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages "${files[@]}"

    for file in "${files[@]}"; do
        package="$(dpkg-deb -f "$file" Package)"
        [[ -n "$package" ]] && packages+=("$package")
    done
    mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 deb 包名。" "Could not determine the deb package names."

    clear_stale_apt_holds "${packages[@]}"
    log "正在设置 APT hold..." "Applying APT holds..."
    apt-mark hold "${packages[@]}"
    write_apt_hold_state "${packages[@]}"
    printf '  hold: %s\n' "${packages[@]}"
}

install_rpm_packages() {
    ds_operation_phase packages
    local -a files packages dnf_install_options=() install_files=() reinstall_files=()
    local file package_name package_version installed_version
    local dnf_conf="/etc/dnf/dnf.conf"
    local dnf_backup

    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.rpm' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 rpm 包。" "No installable rpm packages were found."

    for file in "${files[@]}"; do
        package_name="$(rpm -qp --queryformat '%{NAME}' "$file")"
        package_version="$(rpm -qp --queryformat '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' "$file")"
        installed_version="$(rpm -q --queryformat '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' "$package_name" 2>/dev/null || true)"
        if [[ "$installed_version" == "$package_version" ]]; then
            reinstall_files+=("$file")
        else
            install_files+=("$file")
        fi
    done

    log "正在安装 ${#files[@]} 个 rpm 包并自动处理依赖..." \
        "Installing ${#files[@]} rpm packages and resolving dependencies..."
    touch "$dnf_conf"
    dnf_backup="$(mktemp -t anland-next-dnf-backup.XXXXXXXX)"
    cp -p "$dnf_conf" "$dnf_backup"
    if grep -Fqx "$MESA_DNF_MANAGED_BEGIN" "$dnf_conf"; then
        dnf_install_options+=('--exclude=mesa*')
    fi
    if [[ -e "$SYSTEMD257_STATE" ]]; then
        dnf_install_options+=('--exclude=systemd*')
    fi
    if ! remove_managed_dnf_excludes "$dnf_conf" || \
        ! { ((${#install_files[@]} == 0)) || dnf --nogpgcheck install -y "${dnf_install_options[@]}" "${install_files[@]}"; } || \
        ! { ((${#reinstall_files[@]} == 0)) || dnf --nogpgcheck reinstall -y "${dnf_install_options[@]}" "${reinstall_files[@]}"; }; then
        install -m 0644 "$dnf_backup" "$dnf_conf" || true
        rm -f -- "$dnf_backup"
        die "rpm 软件包安装失败。" "RPM package installation failed."
    fi
    if ! install -m 0644 "$dnf_backup" "$dnf_conf"; then
        rm -f -- "$dnf_backup"
        die "无法恢复 DNF 锁定配置。" "Unable to restore the DNF hold configuration."
    fi

    mapfile -t packages < <(rpm -qp --queryformat '%{NAME}\n' "${files[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 rpm 包名。" "Could not determine the rpm package names."
    log "正在设置 DNF exclude（等效于 hold）..." "Applying DNF excludes (equivalent to hold)..."
    if ! configure_dnf_excludes; then
        install -m 0644 "$dnf_backup" "$dnf_conf" || true
        rm -f -- "$dnf_backup"
        die "无法更新 DNF 锁定配置。" "Unable to update the DNF hold configuration."
    fi
    rm -f -- "$dnf_backup"
    printf '  hold: %s\n' "${packages[@]}"
}

install_arch_packages() {
    ds_operation_phase packages
    local -a files packages
    local pacman_conf

    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 Arch 包。" "No installable Arch packages were found."

    log "正在安装 ${#files[@]} 个 Arch 包..." "Installing ${#files[@]} Arch packages..."
    pacman_conf="$(mktemp -t anland-next-pacman.XXXXXXXX)"
    cp /etc/pacman.conf "$pacman_conf"
    if grep -Eq '^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=' "$pacman_conf"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=.*/LocalFileSigLevel = Optional/' "$pacman_conf"
    elif grep -qE '^\[options\][[:space:]]*$' "$pacman_conf"; then
        sed -i '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' "$pacman_conf"
    else
        rm -f -- "$pacman_conf"
        die "pacman.conf 缺少 [options] 段。" "pacman.conf has no [options] section."
    fi
    if ! pacman --config "$pacman_conf" -U --noconfirm "${files[@]}"; then
        rm -f -- "$pacman_conf"
        die "Arch 软件包安装失败。" "Arch package installation failed."
    fi
    rm -f -- "$pacman_conf"

    write_pacman_hold_block anland-session || \
        die "无法更新 pacman 锁定配置。" "Unable to update the pacman hold configuration."
    mapfile -t packages < <(pacman -Qq -p "${files[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 Arch 包名。" "Could not determine the Arch package names."
    printf '  hold: %s\n' "${packages[@]}"
}

refresh_user_service() {
    ds_operation_phase service
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl --user daemon-reload >/dev/null 2>&1; then
        if systemctl --user enable --now anland-session.service >/dev/null 2>&1; then
            log "已刷新、启用并启动 anland-session 用户服务。" \
                "Refreshed, enabled, and started the anland-session user service."
        else
            systemctl --user enable anland-session.service >/dev/null 2>&1 || true
            log "已启用 anland-session 用户服务，但当前未能启动；可稍后运行 systemctl --user restart anland-session.service。" \
                "The anland-session user service was enabled but could not start; run systemctl --user restart anland-session.service later."
        fi
    else
        log "当前没有可用的 systemd 用户总线；软件包已安装，可稍后运行 systemctl --user daemon-reload。" \
            "No systemd user bus is available; the package is installed, and systemctl --user daemon-reload can be run later."
    fi
}

stop_user_service() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl --user disable --now anland-session.service >/dev/null 2>&1 || true
}

uninstall_next_deb() {
    local package candidate action
    local -a packages=() package_specs=() remove_packages=()
    command -v apt-cache >/dev/null 2>&1 || die "未找到 apt-cache。" "apt-cache was not found."
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v apt-mark >/dev/null 2>&1 || die "未找到 apt-mark。" "apt-mark was not found."
    if [[ -s "$APT_HOLD_STATE" ]]; then
        mapfile -t packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
        ((${#packages[@]} > 0)) || die "APT hold 清单为空。" "The APT hold list is empty."
    elif dpkg-query -W -f='${db:Status-Status}' anland-session 2>/dev/null | grep -Fqx installed; then
        # Older installers did not write KDE-style APT hold lists.
        for package in anland-session; do
            if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -Fqx installed; then
                packages+=("$package")
            fi
        done
    else
        rm -f -- "$COMPONENT_STATE_DIR/anland-next.version" "$COMPONENT_STATE_DIR/anland-next.packages.tsv"
        log "没有 Anland Next 安装记录。" "No Anland Next installation record was found."
        return 0
    fi
    local -a unhold_packages=()
    for package in "${packages[@]}"; do
        action="$(uninstall_package_action "$package")" || die "安装记录含未知软件包。" "The installation record contains an unknown package."
        [[ "$action" != keep ]] || continue
        unhold_packages+=("$package")
        if [[ "$action" == remove ]]; then
            remove_packages+=("$package")
            continue
        fi
        candidate="$(apt-cache madison "$package" | awk -F '|' 'NR == 1 {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }')"
        if [[ -z "$candidate" && "$action" == auxiliary ]]; then
            remove_packages+=("$package")
            continue
        fi
        [[ -n "$candidate" ]] || die "找不到 $package 的官方候选版本。" "No distribution candidate was found for $package."
        package_specs+=("$package=$candidate")
    done
    ((${#unhold_packages[@]} == 0)) || apt-mark unhold "${unhold_packages[@]}" >/dev/null
    ((${#package_specs[@]} == 0)) || apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages "${package_specs[@]}"
    ((${#remove_packages[@]} == 0)) || apt-get remove -y --allow-change-held-packages "${remove_packages[@]}"
    rm -f -- "$APT_HOLD_STATE" "$COMPONENT_STATE_DIR/anland-next.version"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_next_rpm() {
    local dnf_conf="/etc/dnf/dnf.conf" backup stripped transaction package action
    local -a packages=() restore_packages=() remove_packages=()
    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    [[ -f "$dnf_conf" ]] || die "找不到 DNF 配置。" "The DNF configuration was not found."
    if ! rpm -q anland-session >/dev/null 2>&1 && [[ ! -s "$COMPONENT_STATE_DIR/anland-next.version" ]] &&
        ! grep -Fqx "$DNF_MANAGED_BEGIN" "$dnf_conf"; then
        log "没有 Anland Next 安装记录。" "No Anland Next installation record was found."
        return 0
    fi
    mapfile -t packages < <(rpm -qa --queryformat '%{NAME}\n' | awk '/^anland-session$/' | sort -u)
    for package in "${packages[@]}"; do
        action="$(uninstall_package_action "$package")" || die "检测到未知软件包。" "An unknown package was detected."
        case "$action" in
            keep) ;;
            remove) remove_packages+=("$package") ;;
            *) restore_packages+=("$package") ;;
        esac
    done
    backup="$(mktemp -t anland-next-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t anland-next-uninstall.XXXXXXXX)"
    transaction="$(mktemp -t anland-next-uninstall.XXXXXXXX)"
    cp -p -- "$dnf_conf" "$backup"
    if ! rewrite_dnf_config_without_managed_block "$dnf_conf" "$stripped" || \
        ! rewrite_dnf_config_for_package_install "$stripped" "$transaction" || \
        ! install -m 0644 "$transaction" "$dnf_conf" || \
        ! { ((${#remove_packages[@]} == 0)) || dnf remove -y --no-autoremove "${remove_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || dnf distro-sync -y --exclude='mesa*' --exclude='systemd*' "${restore_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || dnf reinstall -y --exclude='mesa*' --exclude='systemd*' "${restore_packages[@]}"; }; then
        install -m 0644 "$backup" "$dnf_conf" || true
        rm -f -- "$backup" "$stripped" "$transaction"
        die "卸载 Anland Next 或恢复发行版图形包失败。" "Failed to uninstall Anland Next or restore distribution graphics packages."
    fi
    rm -f -- "$backup" "$stripped" "$transaction" "$COMPONENT_STATE_DIR/anland-next.version"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_next_arch() {
    local package action backup
    local -a packages=() restore_packages=() remove_packages=()
    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    [[ -f /etc/pacman.conf ]] || die "找不到 pacman.conf。" "pacman.conf was not found."
    if ! pacman -Q anland-session >/dev/null 2>&1 && [[ ! -s "$COMPONENT_STATE_DIR/anland-next.version" ]]; then
        log "没有 Anland Next 安装记录。" "No Anland Next installation record was found."
        return 0
    fi
    for package in anland-session; do
        pacman -Q "$package" >/dev/null 2>&1 || continue
        action="$(uninstall_package_action "$package")" || die "检测到未知软件包。" "An unknown package was detected."
        [[ "$action" != keep ]] || continue
        packages+=("$package")
        if [[ "$action" == remove ]]; then
            remove_packages+=("$package")
        else
            restore_packages+=("$package")
        fi
    done
    backup="$(mktemp -t anland-next-uninstall.XXXXXXXX)"
    cp -p -- /etc/pacman.conf "$backup"
    if ! remove_pacman_hold_entries "${packages[@]}" || \
        ! { ((${#remove_packages[@]} == 0)) || pacman -R --noconfirm "${remove_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || pacman -S --noconfirm "${restore_packages[@]}"; }; then
        install -m 0644 "$backup" /etc/pacman.conf || true
        rm -f -- "$backup"
        die "卸载 Anland Next 或恢复发行版图形包失败。" "Failed to uninstall Anland Next or restore distribution graphics packages."
    fi
    rm -f -- "$backup" "$COMPONENT_STATE_DIR/anland-next.version"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_package_action() {
    [[ "$1" == anland-session ]] || return 1
    printf remove
}

uninstall_package() {
    ds_operation_phase uninstall
    stop_user_service
    case "$PACKAGE_TYPE" in
        deb) uninstall_next_deb ;;
        rpm) uninstall_next_rpm ;;
        pkg.tar.*) uninstall_next_arch ;;
    esac
    log "Anland Next session 已卸载；发行版 Xwayland 和其他依赖未删除。" \
        "Anland Next session was uninstalled; distribution Xwayland and other dependencies were kept."
}

main() {
    detect_language
    parse_arguments "$@"
    detect_target
    check_architecture
    ds_operation_preflight anland-next
    if [[ "$UNINSTALL" == true ]]; then
        require_root "$@"
        ds_operation_begin anland-next
        ds_operation_snapshot_installer_config
        uninstall_package
        return
    fi

    require_runtime_dependencies
    resolve_release_tag

    if [[ -n "$PREPARED_WORK_DIR" || -n "$PREPARED_PACKAGE_FILE" ]]; then
        [[ -n "$PREPARED_WORK_DIR" && -n "$PREPARED_PACKAGE_FILE" ]] || \
            die "预下载环境变量不完整。" "The pre-downloaded package environment is incomplete."
        use_prepared_package
    else
        select_download_source
        download_packages
    fi
    require_root "$@"
    ds_operation_begin anland-next
    ds_operation_snapshot_installer_config

    case "$PACKAGE_TYPE" in
        deb) install_deb_packages ;;
        rpm) install_rpm_packages ;;
        pkg.tar.*) install_arch_packages ;;
    esac
    verify_installed_package_version
    verify_installed_xwayland_paths
    refresh_user_service
    record_component_version "$PACKAGE_VERSION"
    update_desktop_config
    log "Anland Next session 安装完成（${PACKAGE_VERSION:-unknown}）。" \
        "Anland Next session installation completed (${PACKAGE_VERSION:-unknown})."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
