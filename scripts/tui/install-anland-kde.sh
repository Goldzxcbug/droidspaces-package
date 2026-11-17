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
# shellcheck source=lib/anland-archive-common.sh
source "$ANLAND_LIB_DIR/anland-archive-common.sh"

# The package archives are deliberately kept out of Git. Override the
# repository when installing packages published by a fork.
readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${ANLAND_KDE_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}"
RELEASE_TAG="${ANLAND_KDE_RELEASE_TAG:-}"
readonly ROLLING_RELEASE_TAG="anland-kde-packages"
readonly MANIFEST_NAME="anland-kde-manifest"
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((2 * 1024 * 1024 * 1024))
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly APT_HOLD_STATE="/var/lib/anland-kde/apt-holds"
readonly DNF_MANAGED_BEGIN="# BEGIN anland-kde package holds"
readonly DNF_MANAGED_END="# END anland-kde package holds"
readonly MESA_DNF_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly MESA_DNF_MANAGED_END="# END install-mesa package holds"
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly COMPONENT_NAME="kde"
readonly COMPONENT_STATE_DIR="${DROIDSPACES_COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}"
readonly DESKTOP_CONFIG="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"

WORK_DIR=""
PREPARED_WORK_DIR="${ANLAND_KDE_WORK_DIR:-}"
PREPARED_PACKAGE_DIR="${ANLAND_KDE_PACKAGE_DIR:-}"
PREPARED_ARCHIVE_NAME="${ANLAND_KDE_ARCHIVE_NAME:-}"
UI_LANG="en"
TARGET=""
PACKAGE_TYPE=""
ARCHIVE_PREFIX=""
ARCHIVE_SUFFIX=""
ARCHIVE_NAME=""
ARCHIVE_TARGET=""
PACKAGE_DIR=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
EXPECTED_MANIFEST_SHA256=""
EXPECTED_ARCHIVE_SHA256=""
OFFICIAL_RELEASE_METADATA=""
UNINSTALL=false
KDE_XWAYLAND_PRESERVED=false
KDE_XWAYLAND_OWNER=""

readonly ANLAND_DISPLAY_NAME="KWin"
readonly ANLAND_STATE_NAME="kde"
readonly ANLAND_DESKTOP_NAME="kde"
readonly ANLAND_FORCE_WAYLAND=false
readonly ANLAND_DESKTOP_UPDATE_SELF=false
readonly ANLAND_ASSET_KIND=archive
readonly ANLAND_ASSET_FAMILY="anland-kde"
readonly ANLAND_ARCHIVE_VARIANT="kwin"

readonly COMPONENT_LABEL="KWin"
readonly DNF_LEGACY_LABEL="KWin"
readonly DNF_ALLOW_PRESERVE_XWAYLAND=false
readonly DNF_LEGACY_PACKAGE="kwin"
readonly DNF_EXCLUDED_PACKAGES="kwin*,xorg-x11-server-Xwayland*"
readonly -a DNF_STRIP_PACKAGES=('kwin*')
readonly -a DNF_XWAYLAND_STRIP_PACKAGES=('xorg-x11-server-Xwayland*')

uninstall_kde_deb() {
    local package candidate owner
    local preserve_xwayland=false
    local -a packages=() package_specs=() unhold_packages=()
    [[ -s "$APT_HOLD_STATE" ]] || {
        rm -f -- "$COMPONENT_STATE_DIR/kde.version" "$COMPONENT_STATE_DIR/kde.packages.tsv"
        log "没有 Anland KDE 安装记录。" "No Anland KDE installation record was found."
        return 0
    }
    command -v apt-cache >/dev/null 2>&1 || die "未找到 apt-cache。" "apt-cache was not found."
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v apt-mark >/dev/null 2>&1 || die "未找到 apt-mark。" "apt-mark was not found."
    if owner="$(other_xwayland_owner)"; then
        preserve_xwayland=true
        KDE_XWAYLAND_PRESERVED=true
        KDE_XWAYLAND_OWNER="$owner"
        log "检测到 Anland $owner，将保留共用的 patched Xwayland。" \
            "Anland $owner is installed; preserving the shared patched Xwayland."
    fi
    mapfile -t packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
    ((${#packages[@]} > 0)) || die "APT hold 清单为空。" "The APT hold list is empty."
    for package in "${packages[@]}"; do
        if [[ "$preserve_xwayland" == true && "$package" == xwayland ]]; then
            continue
        fi
        unhold_packages+=("$package")
        candidate="$(apt-cache madison "$package" | awk -F '|' 'NR == 1 {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }')"
        [[ -n "$candidate" ]] || \
            die "找不到 $package 的官方候选版本。" "No distribution candidate was found for $package."
        package_specs+=("$package=$candidate")
    done
    ((${#unhold_packages[@]} == 0)) || apt-mark unhold "${unhold_packages[@]}" >/dev/null
    ((${#package_specs[@]} == 0)) || apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages \
        "${package_specs[@]}"
    rm -f -- "$APT_HOLD_STATE" "$COMPONENT_STATE_DIR/kde.version"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_kde_rpm() {
    local dnf_conf="/etc/dnf/dnf.conf" backup stripped transaction package owner
    local -a packages=() retained_packages=()
    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    [[ -f "$dnf_conf" ]] || die "找不到 DNF 配置。" "The DNF configuration was not found."
    mapfile -t packages < <(rpm -qa --queryformat '%{NAME}\n' |
        awk '/^kwin([a-zA-Z0-9+._-]*)$/ || /^xorg-x11-server-Xwayland([a-zA-Z0-9+._-]*)$/' | sort -u)
    if owner="$(other_xwayland_owner)"; then
        KDE_XWAYLAND_PRESERVED=true
        KDE_XWAYLAND_OWNER="$owner"
        log "检测到 Anland $owner，将保留共用的 patched Xwayland。" \
            "Anland $owner is installed; preserving the shared patched Xwayland."
        for package in "${packages[@]}"; do
            [[ "$package" != xorg-x11-server-Xwayland* ]] || continue
            retained_packages+=("$package")
        done
        packages=("${retained_packages[@]}")
    fi
    ((${#packages[@]})) || {
        rm -f -- "$COMPONENT_STATE_DIR/kde.version" "$COMPONENT_STATE_DIR/kde.packages.tsv"
        return 0
    }
    backup="$(mktemp -t anland-kde-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t anland-kde-uninstall.XXXXXXXX)"
    transaction="$(mktemp -t anland-kde-uninstall.XXXXXXXX)"
    cp -p -- "$dnf_conf" "$backup"
    if ! rewrite_dnf_config_without_managed_block "$dnf_conf" "$stripped" || \
        ! rewrite_dnf_config_for_package_install "$stripped" "$transaction" || \
        ! install -m 0644 "$transaction" "$dnf_conf" || \
        ! dnf distro-sync -y --exclude='mesa*' --exclude='systemd*' "${packages[@]}" || \
        ! dnf reinstall -y --exclude='mesa*' --exclude='systemd*' "${packages[@]}"; then
        install -m 0644 "$backup" "$dnf_conf" || true
        rm -f -- "$backup" "$stripped" "$transaction"
        die "恢复发行版 KWin/Xwayland 失败。" "Failed to restore distribution KWin/Xwayland packages."
    fi
    rm -f -- "$backup" "$stripped" "$transaction" "$COMPONENT_STATE_DIR/kde.version"
}

uninstall_kde_arch() {
    local backup owner
    local -a restore_packages=(kwin) hold_removals=(kwin)
    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    [[ -f /etc/pacman.conf ]] || die "找不到 pacman.conf。" "pacman.conf was not found."
    if [[ ! -s "$COMPONENT_STATE_DIR/kde.version" ]] && \
        [[ ! -s "$APT_HOLD_STATE" ]] && \
        ! grep -Fqx "# BEGIN anland-kde package holds" /etc/pacman.conf 2>/dev/null && \
        ! grep -Eq "^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])kwin([[:space:]]|$)" /etc/pacman.conf 2>/dev/null; then
        log "没有 Anland KDE 安装记录。" "No Anland KDE installation record was found."
        return 0
    fi
    if owner="$(other_xwayland_owner)"; then
        KDE_XWAYLAND_PRESERVED=true
        KDE_XWAYLAND_OWNER="$owner"
        log "检测到 Anland $owner，将保留共用的 patched Xwayland。" \
            "Anland $owner is installed; preserving the shared patched Xwayland."
    else
        restore_packages+=(xorg-xwayland)
        hold_removals+=(xorg-xwayland)
    fi
    backup="$(mktemp -t anland-kde-uninstall.XXXXXXXX)"
    cp -p -- /etc/pacman.conf "$backup"
    if ! remove_pacman_hold_entries "${hold_removals[@]}" || \
        ! pacman -S --noconfirm "${restore_packages[@]}"; then
        install -m 0644 "$backup" /etc/pacman.conf || true
        rm -f -- "$backup"
        die "恢复发行版 KWin/Xwayland 失败。" "Failed to restore distribution KWin/Xwayland packages."
    fi
    rm -f -- "$backup" "$COMPONENT_STATE_DIR/kde.version"
}

uninstall_kde() {
    ds_operation_phase uninstall
    case "$PACKAGE_TYPE" in
        deb) uninstall_kde_deb ;;
        rpm) uninstall_kde_rpm ;;
        pkg.tar.*) uninstall_kde_arch ;;
    esac
    if [[ "$KDE_XWAYLAND_PRESERVED" == true ]]; then
        log "Anland KDE 已卸载，发行版 KWin 已恢复，共用的 patched Xwayland 仍由 Anland ${KDE_XWAYLAND_OWNER} 管理。" \
            "Anland KDE was uninstalled and distribution KWin was restored; the shared patched Xwayland remains managed by Anland ${KDE_XWAYLAND_OWNER}."
    else
        log "Anland KDE 已卸载，发行版 KWin/Xwayland 已恢复。" \
            "Anland KDE was uninstalled and distribution KWin/Xwayland packages were restored."
    fi
}

trap cleanup EXIT

require_root() {
    if (( EUID == 0 )); then
        return
    fi

    command -v sudo >/dev/null 2>&1 || die "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."
    local script_path="${BASH_SOURCE[0]}"
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    local status
    if sudo env \
        "ANLAND_KDE_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "ANLAND_KDE_RELEASE_TAG=$RELEASE_TAG" \
        "ANLAND_KDE_WORK_DIR=$WORK_DIR" \
        "ANLAND_KDE_PACKAGE_DIR=$PACKAGE_DIR" \
        "ANLAND_KDE_ARCHIVE_NAME=$ARCHIVE_NAME" \
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

resolve_archive_name() {
    local manifest_file="$1"
    local manifest_format manifest_release_tag selected_name checksum_key checksum_count checksum

    manifest_format="$(awk -F= '$1 == "format" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    manifest_release_tag="$(awk -F= '$1 == "release_tag" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    [[ "$manifest_format" == "1" && "$manifest_release_tag" == "$RELEASE_TAG" ]] || {
        log "Release 清单格式无效。" "The Release manifest format is invalid."
        return 1
    }

    selected_name="$(awk -F= -v key="$ARCHIVE_TARGET" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    case "$selected_name" in
        "${ARCHIVE_PREFIX}"*"${ARCHIVE_SUFFIX}") ;;
        *)
            log "Release 清单没有 ${TARGET} 的匹配 ARM64 包。" \
                "The Release manifest has no matching ARM64 archive for ${TARGET}."
            return 1
            ;;
    esac
    if [[ ! "$selected_name" =~ ^[A-Za-z0-9._+~_-]+$ || "$selected_name" == *..* ]]; then
        log "Release 清单中的包名无效。" "The archive name in the Release manifest is invalid."
        return 1
    fi

    ARCHIVE_NAME="$selected_name"
    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "3" ]]; then
        checksum_key="${ARCHIVE_TARGET}_sha256"
        checksum_count="$(awk -F= -v key="$checksum_key" '$1 == key { count += 1 } END { print count + 0 }' "$manifest_file")" || return 1
        case "$checksum_count" in
            0)
                die "CNB Release 的 ${MANIFEST_NAME} 缺少 ${ARCHIVE_NAME} 的唯一 SHA-256 校验值，拒绝安装。" \
                    "The CNB Release ${MANIFEST_NAME} has no unique SHA-256 digest for ${ARCHIVE_NAME}; refusing to install."
                ;;
            1)
                checksum="$(awk -F= -v key="$checksum_key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file")" || return 1
                [[ "$checksum" =~ ^[0-9A-Fa-f]{64}$ ]] || {
                    log "CNB Release 清单中的 ${ARCHIVE_NAME} SHA-256 无效。" \
                        "The CNB Release manifest has an invalid SHA-256 for ${ARCHIVE_NAME}."
                    return 1
                }
                EXPECTED_ARCHIVE_SHA256="${checksum,,}"
                ;;
            *)
                log "CNB Release 清单中的 ${ARCHIVE_NAME} SHA-256 不唯一。" \
                    "The CNB Release manifest has multiple SHA-256 entries for ${ARCHIVE_NAME}."
                return 1
                ;;
        esac
    fi
    log "已选择 ${ARCHIVE_NAME}" "Selected ${ARCHIVE_NAME}"
}

validate_archive_contents() {
    local archive_file="$1"
    local archive_size members entry

    if ! archive_size="$(stat -c '%s' "$archive_file")" || ! [[ "$archive_size" =~ ^[0-9]+$ ]]; then
        log "无法读取下载包的大小。" "Unable to read the downloaded archive size."
        return 1
    fi
    if (( archive_size > MAX_ARCHIVE_BYTES )); then
        log "下载包超过允许的大小。" "The downloaded archive exceeds the allowed size."
        return 1
    fi
    if ! members="$(tar -tzf "$archive_file")" || [[ -z "$members" ]]; then
        log "下载包不是有效的非空 tar.gz 文件。" "The downloaded archive is not a valid non-empty tar.gz file."
        return 1
    fi
    while IFS= read -r entry; do
        case "$entry" in
            /*|.|./*|..|../*|*/.|*/./*|*/..|*/../*)
                log "下载包包含不安全路径。" "The downloaded archive contains an unsafe path."
                return 1
                ;;
            "anland-kde-packages/${ARCHIVE_TARGET}/"*) ;;
            *)
                log "下载包包含目标系统目录以外的文件。" \
                    "The downloaded archive contains files outside the target system directory."
                return 1
                ;;
        esac
    done <<< "$members"

    if ! LC_ALL=C tar -tvzf "$archive_file" | awk -v maximum="$MAX_EXTRACTED_BYTES" '
        {
            entry_type = substr($1, 1, 1)
            if (entry_type !~ /^[-d]$/ || $3 !~ /^[0-9]+$/) {
                exit 1
            }
            total += $3
            if (total > maximum) {
                exit 1
            }
        }
    '; then
        log "下载包包含不允许的条目，或解压后会超过大小限制。" \
            "The downloaded archive has a disallowed entry or exceeds the extraction size limit."
        return 1
    fi
}

validate_package_architecture() {
    local -a files=()
    local file package_arch package_name xwayland_count=0

    case "$PACKAGE_TYPE" in
        deb)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
            for file in "${files[@]}"; do
                package_arch="$(dpkg-deb -f "$file" Architecture)" || return 1
                package_name="$(dpkg-deb -f "$file" Package)" || return 1
                case "$package_arch" in arm64|all) ;; *) return 1 ;; esac
                case "$package_name" in
                    kwin-data) ;;
                    kwin|kwin-*|libkwin*) [[ "$package_arch" == arm64 ]] || return 1 ;;
                    xwayland) [[ "$package_arch" == arm64 ]] || return 1; ((xwayland_count += 1)) ;;
                    *) return 1 ;;
                esac
            done
            ((xwayland_count == 1))
            ;;
        rpm)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.rpm' -print | sort)
            for file in "${files[@]}"; do
                package_arch="$(rpm -qp --queryformat '%{ARCH}' "$file")"
                case "$package_arch" in aarch64|noarch) ;; *) return 1 ;; esac
            done
            ;;
        pkg.tar.*)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
            for file in "${files[@]}"; do
                package_arch="$(LC_ALL=C pacman -Qip "$file" | sed -n 's/^[[:space:]]*Architecture[[:space:]]*:[[:space:]]*//p')"
                case "$package_arch" in aarch64|any) ;; *) return 1 ;; esac
            done
            ;;
    esac

    ((${#files[@]} > 0))
}

download_packages_once() {
    ds_operation_phase download
    local base_url manifest_file archive_file extracted_size

    base_url="$(release_download_base)"
    manifest_file="$WORK_DIR/$MANIFEST_NAME"
    OFFICIAL_RELEASE_METADATA=""
    if [[ "$DOWNLOAD_SOURCE" != "3" ]]; then
        resolve_official_manifest_sha256 || return 1
    fi

    log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载 ${TARGET} 预编译包..." \
        "Downloading ${TARGET} prebuilt packages from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$base_url/$MANIFEST_NAME" "$manifest_file" || return 1
    if [[ -n "$EXPECTED_MANIFEST_SHA256" ]]; then
        validate_release_asset_checksum "$manifest_file" "$EXPECTED_MANIFEST_SHA256" "$MANIFEST_NAME" || return 1
    fi
    resolve_archive_name "$manifest_file" || return 1
    if [[ "$DOWNLOAD_SOURCE" != "3" ]]; then
        resolve_official_archive_sha256 || return 1
    fi

    archive_file="$WORK_DIR/$ARCHIVE_NAME"
    download_file "$base_url/$ARCHIVE_NAME" "$archive_file" || return 1
    if [[ -n "$EXPECTED_ARCHIVE_SHA256" ]]; then
        validate_release_asset_checksum "$archive_file" "$EXPECTED_ARCHIVE_SHA256" "$ARCHIVE_NAME" || return 1
    fi
    validate_archive_contents "$archive_file" || return 1
    if ! tar --no-same-owner --no-same-permissions -xzf "$archive_file" -C "$WORK_DIR"; then
        log "无法安全解压下载包。" "Unable to safely extract the downloaded archive."
        return 1
    fi

    PACKAGE_DIR="$WORK_DIR/anland-kde-packages/$ARCHIVE_TARGET"
    has_packages "$PACKAGE_DIR" || {
        log "未能获取 ${TARGET} 的安装包。" "Could not obtain packages for ${TARGET}."
        return 1
    }
    if ! extracted_size="$(du -sb "$PACKAGE_DIR" | awk '{print $1}')" || ! [[ "$extracted_size" =~ ^[0-9]+$ ]] || (( extracted_size > MAX_EXTRACTED_BYTES )); then
        log "解压后的软件包大小无效或超过限制。" \
            "The extracted package size is invalid or exceeds the limit."
        return 1
    fi
    if ! validate_package_architecture; then
        log "下载包中的软件包架构与当前系统不匹配。" \
            "The package architecture in the archive does not match this system."
        return 1
    fi
}

download_packages() {
    ds_operation_phase download
    local attempt
    WORK_DIR="$(mktemp -d -t anland-kde.XXXXXXXX)"

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

use_prepared_packages() {
    local prepared_work_dir prepared_package_dir

    prepared_work_dir="$(realpath -e "$PREPARED_WORK_DIR")" || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    prepared_package_dir="$(realpath -e "$PREPARED_PACKAGE_DIR")" || \
        die "预下载包目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_work_dir" =~ ^/tmp/anland-kde\.[A-Za-z0-9]+$ ]] || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_package_dir" == "$prepared_work_dir/anland-kde-packages/$ARCHIVE_TARGET" ]] || \
        die "预下载包的目标系统不匹配。" "The pre-downloaded package target does not match this system."
    [[ -d "$prepared_work_dir" && -d "$prepared_package_dir" ]] || \
        die "预下载包已不存在。" "The pre-downloaded package directory no longer exists."

    WORK_DIR="$prepared_work_dir"
    PACKAGE_DIR="$prepared_package_dir"
    ARCHIVE_NAME="$PREPARED_ARCHIVE_NAME"
    case "$ARCHIVE_NAME" in "${ARCHIVE_PREFIX}"*"${ARCHIVE_SUFFIX}") ;; *)
        die "预下载包名与系统不匹配。" "The pre-downloaded archive name does not match this system." ;;
    esac
    has_packages "$PACKAGE_DIR" || die "预下载目录中没有可安装的软件包。" "The pre-downloaded directory has no installable packages."
    validate_package_architecture || \
        die "预下载包中的软件包架构与当前系统不匹配。" "The pre-downloaded package architecture does not match this system."
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
    dnf_backup="$(mktemp -t anland-kde-dnf-backup.XXXXXXXX)"
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
    pacman_conf="$(mktemp -t anland-kde-pacman.XXXXXXXX)"
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

    if ! write_pacman_hold_block kwin xorg-xwayland; then
        die "无法更新 pacman 锁定配置。" "Unable to update the pacman hold configuration."
    fi
    mapfile -t packages < <(pacman -Qq -p "${files[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 Arch 包名。" "Could not determine the Arch package names."
    printf '  hold: %s\n' "${packages[@]}"
}

main() {
    local archive_version owner
    detect_language
    parse_arguments "$@"
    detect_target
    check_architecture
    ds_operation_preflight kde
    if [[ "$UNINSTALL" == true ]]; then
        require_root "$@"
        ds_operation_begin kde
        ds_operation_snapshot_installer_config
        uninstall_kde
        return
    fi
    require_runtime_dependencies

    resolve_release_tag
    if [[ -n "$PREPARED_WORK_DIR" || -n "$PREPARED_PACKAGE_DIR" ]]; then
        use_prepared_packages
    else
        select_download_source
        download_packages
    fi
    require_root "$@"
    ds_operation_begin kde
    ds_operation_snapshot_installer_config
    if owner="$(other_xwayland_owner)"; then
        die "检测到 Anland $owner；KDE 与它共用 patched Xwayland；请先卸载该组件以避免覆盖。" \
            "Anland $owner is installed; KDE shares patched Xwayland with it; uninstall that component first to avoid replacing it."
    fi

    case "$PACKAGE_TYPE" in
        deb) install_deb_packages ;;
        rpm) install_rpm_packages ;;
        pkg.tar.*) install_arch_packages ;;
    esac

    archive_version="${ARCHIVE_NAME#"$ARCHIVE_PREFIX"}"
    archive_version="${archive_version%"$ARCHIVE_SUFFIX"}"
    record_component_version "$archive_version"
    update_desktop_config
    log "安装完成，patched KWin/Xwayland 已锁定。" \
        "Installation complete; patched KWin/Xwayland packages are now locked."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
