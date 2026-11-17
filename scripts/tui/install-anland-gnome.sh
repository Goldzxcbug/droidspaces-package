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
readonly RELEASE_REPOSITORY="${ANLAND_GNOME_RELEASE_REPOSITORY:-${ANLAND_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}}"
RELEASE_TAG="${ANLAND_GNOME_RELEASE_TAG:-}"
readonly ROLLING_RELEASE_TAG="anland-gnome-packages"
readonly MANIFEST_NAME="anland-gnome-manifest"
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((2 * 1024 * 1024 * 1024))
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly PACMAN_PACKAGE_STATE="/var/lib/anland-gnome/pacman-packages"
readonly APT_HOLD_STATE="/var/lib/anland-gnome/apt-holds"
readonly DNF_MANAGED_BEGIN="# BEGIN anland-gnome package holds"
readonly DNF_MANAGED_END="# END anland-gnome package holds"
readonly MESA_DNF_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly MESA_DNF_MANAGED_END="# END install-mesa package holds"
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly COMPONENT_NAME="gnome"
readonly COMPONENT_STATE_DIR="${DROIDSPACES_COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}"
readonly DESKTOP_CONFIG="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"

WORK_DIR=""
PREPARED_WORK_DIR="${ANLAND_GNOME_WORK_DIR:-}"
PREPARED_PACKAGE_DIR="${ANLAND_GNOME_PACKAGE_DIR:-}"
PREPARED_ARCHIVE_NAME="${ANLAND_GNOME_ARCHIVE_NAME:-}"
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

readonly ANLAND_DISPLAY_NAME="Mutter"
readonly ANLAND_STATE_NAME="gnome"
readonly ANLAND_DESKTOP_NAME="gnome"
readonly ANLAND_FORCE_WAYLAND=false
readonly ANLAND_DESKTOP_UPDATE_SELF=false
readonly ANLAND_ASSET_KIND=archive
readonly ANLAND_ASSET_FAMILY="anland-gnome"
readonly ANLAND_ARCHIVE_VARIANT="mutter"

readonly COMPONENT_LABEL="Mutter"
readonly DNF_LEGACY_LABEL="Mutter"
readonly DNF_ALLOW_PRESERVE_XWAYLAND=false
readonly DNF_LEGACY_PACKAGE="mutter"
readonly DNF_EXCLUDED_PACKAGES="mutter*,xorg-x11-server-Xwayland*"
readonly -a DNF_STRIP_PACKAGES=('mutter*')
readonly -a DNF_XWAYLAND_STRIP_PACKAGES=('xorg-x11-server-Xwayland*')

uninstall_gnome_deb() {
    local package candidate owner
    local -a packages=() unhold_packages=() package_specs=()
    local preserve_xwayland=false
    [[ -s "$APT_HOLD_STATE" ]] || {
        rm -f -- "$COMPONENT_STATE_DIR/gnome.version" "$COMPONENT_STATE_DIR/gnome.packages.tsv"
        log "没有 Anland GNOME 安装记录。" "No Anland GNOME installation record was found."
        return 0
    }
    command -v apt-cache >/dev/null 2>&1 || die "未找到 apt-cache。" "apt-cache was not found."
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v apt-mark >/dev/null 2>&1 || die "未找到 apt-mark。" "apt-mark was not found."
    mapfile -t packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
    ((${#packages[@]} > 0)) || die "APT hold 清单为空。" "The APT hold list is empty."
    if owner="$(other_xwayland_owner)"; then
        preserve_xwayland=true
        log "检测到 Anland ${owner}，将保留共用的 patched xwayland。" \
            "Anland ${owner} is installed; preserving the shared patched xwayland."
    fi
    for package in "${packages[@]}"; do
        if [[ "$preserve_xwayland" == true && "$package" == xwayland ]]; then
            continue
        fi
        candidate="$(apt-cache madison "$package" | awk -F '|' 'NR == 1 {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }')"
        [[ -n "$candidate" ]] || \
            die "找不到 $package 的官方候选版本。" "No distribution candidate was found for $package."
        unhold_packages+=("$package")
        package_specs+=("$package=$candidate")
    done
    ((${#unhold_packages[@]} == 0)) || apt-mark unhold "${unhold_packages[@]}" >/dev/null
    ((${#package_specs[@]} == 0)) || \
        apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages \
            "${package_specs[@]}"
    rm -f -- "$APT_HOLD_STATE" "$COMPONENT_STATE_DIR/gnome.version"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
    log "Anland GNOME 已卸载，发行版 Mutter/Xwayland 已恢复。" \
        "Anland GNOME was uninstalled and distribution Mutter/Xwayland packages were restored."
}

uninstall_gnome_rpm() {
    local dnf_conf="/etc/dnf/dnf.conf" backup stripped transaction package owner
    local -a packages=() restore_packages=()
    local preserve_xwayland=false
    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    [[ -f "$dnf_conf" ]] || die "找不到 DNF 配置。" "The DNF configuration was not found."
    mapfile -t packages < <(rpm -qa --queryformat '%{NAME}\n' |
        awk '/^mutter([a-zA-Z0-9+._-]*)$/ || /^xorg-x11-server-Xwayland([a-zA-Z0-9+._-]*)$/' | sort -u)
    ((${#packages[@]})) || {
        rm -f -- "$COMPONENT_STATE_DIR/gnome.version" "$COMPONENT_STATE_DIR/gnome.packages.tsv"
        return 0
    }
    if owner="$(other_xwayland_owner)"; then
        preserve_xwayland=true
        log "检测到 Anland ${owner}，将保留共用的 patched xorg-x11-server-Xwayland。" \
            "Anland ${owner} is installed; preserving the shared patched xorg-x11-server-Xwayland."
    fi
    for package in "${packages[@]}"; do
        if [[ "$preserve_xwayland" == true && "$package" == xorg-x11-server-Xwayland* ]]; then
            continue
        fi
        restore_packages+=("$package")
    done
    backup="$(mktemp -t anland-gnome-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t anland-gnome-uninstall.XXXXXXXX)"
    transaction="$(mktemp -t anland-gnome-uninstall.XXXXXXXX)"
    cp -p -- "$dnf_conf" "$backup"
    if ! rewrite_dnf_config_without_managed_block "$dnf_conf" "$stripped" || \
        ! rewrite_dnf_config_for_package_install "$stripped" "$transaction" || \
        ! install -m 0644 "$transaction" "$dnf_conf" || \
        ! { ((${#restore_packages[@]} == 0)) || dnf distro-sync -y --exclude='mesa*' --exclude='systemd*' "${restore_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || dnf reinstall -y --exclude='mesa*' --exclude='systemd*' "${restore_packages[@]}"; }; then
        install -m 0644 "$backup" "$dnf_conf" || true
        rm -f -- "$backup" "$stripped" "$transaction"
        die "恢复发行版 Mutter/Xwayland 失败。" "Failed to restore distribution Mutter/Xwayland packages."
    fi
    rm -f -- "$backup" "$stripped" "$transaction" "$COMPONENT_STATE_DIR/gnome.version"
}

uninstall_gnome_arch() {
    local package backup owner
    local -a packages=() restore_packages=()
    local preserve_xwayland=false

    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    [[ -f /etc/pacman.conf ]] || die "找不到 pacman.conf。" "pacman.conf was not found."
    if [[ -s "$PACMAN_PACKAGE_STATE" ]]; then
        mapfile -t packages < <(sed -nE 's/^([A-Za-z0-9@.+_-]+)$/\1/p' "$PACMAN_PACKAGE_STATE" | sort -u)
    else
        local ignored_package
        for ignored_package in mutter xorg-xwayland; do
            if awk -v package="$ignored_package" '
                /^[[:space:]]*IgnorePkg[[:space:]]*=/ {
                    value = $0
                    sub(/^[^=]*=/, "", value)
                    count = split(value, entries, /[[:space:]]+/)
                    for (i = 1; i <= count; i++) if (entries[i] == package) found = 1
                }
                END { exit found ? 0 : 1 }
            ' /etc/pacman.conf; then
                packages+=("$ignored_package")
            fi
        done
        if ((${#packages[@]} == 0)); then
            rm -f -- "$COMPONENT_STATE_DIR/gnome.version" "$COMPONENT_STATE_DIR/gnome.packages.tsv"
            log "没有 Anland GNOME 安装记录。" "No Anland GNOME installation record was found."
            return 0
        fi
    fi
    ((${#packages[@]} > 0)) || die "Arch 软件包恢复清单为空。" "The Arch package restore list is empty."

    if owner="$(other_xwayland_owner)"; then
        preserve_xwayland=true
        log "检测到 Anland ${owner}，将保留共用的 patched xorg-xwayland。" \
            "Anland ${owner} is installed; preserving the shared patched xorg-xwayland."
    fi
    for package in "${packages[@]}"; do
        if [[ "$preserve_xwayland" == true && "$package" == xorg-xwayland ]]; then
            continue
        fi
        restore_packages+=("$package")
    done

    backup="$(mktemp -t anland-gnome-uninstall.XXXXXXXX)"
    cp -p -- /etc/pacman.conf "$backup"
    if ! remove_pacman_hold_entries "${restore_packages[@]}" || \
        ! { ((${#restore_packages[@]} == 0)) || pacman -S --noconfirm "${restore_packages[@]}"; }; then
        install -m 0644 -- "$backup" /etc/pacman.conf || true
        rm -f -- "$backup"
        die "恢复发行版 Mutter/Xwayland 失败。" "Failed to restore the distribution Mutter/Xwayland packages."
    fi

    rm -f -- "$backup" "$PACMAN_PACKAGE_STATE" \
        "$APT_HOLD_STATE" "$COMPONENT_STATE_DIR/gnome.version"
    rmdir -- "${PACMAN_PACKAGE_STATE%/*}" 2>/dev/null || true
    log "Anland GNOME 已卸载，发行版 Mutter/Xwayland 已恢复。" \
        "Anland GNOME was uninstalled and distribution Mutter/Xwayland packages were restored."
}

uninstall_gnome() {
    ds_operation_phase uninstall
    case "$PACKAGE_TYPE" in
        deb) uninstall_gnome_deb ;;
        rpm) uninstall_gnome_rpm ;;
        pkg.tar.*) uninstall_gnome_arch ;;
        *) die "无法确定 GNOME 软件包类型。" "Could not determine the GNOME package type." ;;
    esac
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
        "ANLAND_GNOME_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "ANLAND_GNOME_RELEASE_TAG=$RELEASE_TAG" \
        "ANLAND_GNOME_WORK_DIR=$WORK_DIR" \
        "ANLAND_GNOME_PACKAGE_DIR=$PACKAGE_DIR" \
        "ANLAND_GNOME_ARCHIVE_NAME=$ARCHIVE_NAME" \
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
                die "CNB 的旧 Release 清单缺少 ${ARCHIVE_NAME} 的 SHA-256 校验值，拒绝安装。" \
                    "The legacy CNB Release manifest has no SHA-256 digest for ${ARCHIVE_NAME}; refusing to install."
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
            "anland-gnome-packages/${ARCHIVE_TARGET}/"*) ;;
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

is_test_package() {
    case "$1" in
        mutter-tests|mutter-*-tests|mutter-test) return 0 ;;
        *) return 1 ;;
    esac
}

validate_package_architecture() {
    local -a files=()
    local file package_arch package_name package_info require_arch
    local mutter_count=0 xwayland_count=0

    case "$PACKAGE_TYPE" in
        deb)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
            for file in "${files[@]}"; do
                package_arch="$(dpkg-deb -f "$file" Architecture)" || {
                    log "无法读取 deb 架构：$(basename -- "$file")" \
                        "Could not read the deb architecture: $(basename -- "$file")"
                    return 1
                }
                package_name="$(dpkg-deb -f "$file" Package)" || {
                    log "无法读取 deb 包名：$(basename -- "$file")" \
                        "Could not read the deb package name: $(basename -- "$file")"
                    return 1
                }
                require_arch=""
                case "$package_name" in
                    mutter) ((mutter_count += 1)); require_arch=arm64 ;;
                    xwayland) ((xwayland_count += 1)); require_arch=arm64 ;;
                    libmutter-*|gir1.2-mutter-*|mutter-*-tests) require_arch=arm64 ;;
                    mutter-common|mutter-common-bin|mutter-dev-bin) ;;
                    *)
                        log "归档包含未预期的 deb 包：${package_name}（${package_arch}）" \
                            "Archive contains an unexpected deb package: ${package_name} (${package_arch})"
                        return 1
                        ;;
                esac
                if [[ -n "$require_arch" && "$package_arch" != "$require_arch" ]]; then
                    log "${package_name} 的架构应为 ${require_arch}，实际为 ${package_arch}。" \
                        "${package_name} should be ${require_arch} but is ${package_arch}."
                    return 1
                fi
                if [[ -z "$require_arch" && "$package_arch" != arm64 && "$package_arch" != all ]]; then
                    log "${package_name} 的架构应为 arm64 或 all，实际为 ${package_arch}。" \
                        "${package_name} should be arm64 or all but is ${package_arch}."
                    return 1
                fi
            done
            if ((mutter_count != 1 || xwayland_count != 1)); then
                log "deb 归档应恰好包含一个 mutter 和一个 xwayland，实际 mutter=${mutter_count} xwayland=${xwayland_count}。" \
                    "The deb archive should contain exactly one mutter and one xwayland, found mutter=${mutter_count} xwayland=${xwayland_count}."
                return 1
            fi
            ;;
        rpm)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.rpm' -print | sort)
            for file in "${files[@]}"; do
                package_arch="$(rpm -qp --queryformat '%{ARCH}' "$file")" || {
                    log "无法读取 rpm 架构：$(basename -- "$file")" \
                        "Could not read the rpm architecture: $(basename -- "$file")"
                    return 1
                }
                package_name="$(rpm -qp --queryformat '%{NAME}' "$file")" || {
                    log "无法读取 rpm 包名：$(basename -- "$file")" \
                        "Could not read the rpm package name: $(basename -- "$file")"
                    return 1
                }
                require_arch=""
                case "$package_name" in
                    mutter) ((mutter_count += 1)); require_arch=aarch64 ;;
                    xorg-x11-server-Xwayland) ((xwayland_count += 1)); require_arch=aarch64 ;;
                    mutter-common|mutter-common-x11) ;;
                    mutter-tests|mutter-*-tests) ;;
                    *)
                        log "归档包含未预期的 rpm 包：${package_name}（${package_arch}）" \
                            "Archive contains an unexpected rpm package: ${package_name} (${package_arch})"
                        return 1
                        ;;
                esac
                if [[ -n "$require_arch" && "$package_arch" != "$require_arch" ]]; then
                    log "${package_name} 的架构应为 ${require_arch}，实际为 ${package_arch}。" \
                        "${package_name} should be ${require_arch} but is ${package_arch}."
                    return 1
                fi
                if [[ -z "$require_arch" && "$package_arch" != aarch64 && "$package_arch" != noarch ]]; then
                    log "${package_name} 的架构应为 aarch64 或 noarch，实际为 ${package_arch}。" \
                        "${package_name} should be aarch64 or noarch but is ${package_arch}."
                    return 1
                fi
            done
            if ((mutter_count != 1 || xwayland_count != 1)); then
                log "rpm 归档应恰好包含一个 mutter 和一个 xorg-x11-server-Xwayland，实际 mutter=${mutter_count} xwayland=${xwayland_count}。" \
                    "The rpm archive should contain exactly one mutter and one xorg-x11-server-Xwayland, found mutter=${mutter_count} xwayland=${xwayland_count}."
                return 1
            fi
            ;;
        pkg.tar.*)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
            for file in "${files[@]}"; do
                package_info="$(LC_ALL=C pacman -Qip "$file")" || {
                    log "无法读取 Arch 包信息：$(basename -- "$file")" \
                        "Could not read the Arch package metadata: $(basename -- "$file")"
                    return 1
                }
                package_name="$(awk -F: '/^[[:space:]]*Name[[:space:]]*:/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }' <<< "$package_info")"
                package_arch="$(awk -F: '/^[[:space:]]*Architecture[[:space:]]*:/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }' <<< "$package_info")"
                if [[ ! "$package_name" =~ ^[A-Za-z0-9@.+_-]+$ ]]; then
                    log "Arch 包名无效：${package_name}" "Invalid Arch package name: ${package_name}"
                    return 1
                fi
                case "$package_arch" in
                    aarch64|any) ;;
                    *)
                        log "${package_name} 的架构应为 aarch64 或 any，实际为 ${package_arch}。" \
                            "${package_name} should be aarch64 or any but is ${package_arch}."
                        return 1
                        ;;
                esac
                case "$package_name" in
                    mutter) ((mutter_count += 1)) ;;
                    xorg-xwayland) ((xwayland_count += 1)) ;;
                    *)
                        log "归档包含未预期的 Arch 包：${package_name}" \
                            "Archive contains an unexpected Arch package: ${package_name}"
                        return 1
                        ;;
                esac
            done
            if (( ${#files[@]} != 2 || mutter_count != 1 || xwayland_count != 1 )); then
                log "Arch 归档应恰好包含一个 mutter 和一个 xorg-xwayland，实际总数=${#files[@]} mutter=${mutter_count} xwayland=${xwayland_count}。" \
                    "The Arch archive should contain exactly one mutter and one xorg-xwayland, found total=${#files[@]} mutter=${mutter_count} xwayland=${xwayland_count}."
                return 1
            fi
            ;;
        *)
            log "无法识别软件包类型：${PACKAGE_TYPE}" "Unknown package type: ${PACKAGE_TYPE}"
            return 1
            ;;
    esac
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

    PACKAGE_DIR="$WORK_DIR/anland-gnome-packages/$ARCHIVE_TARGET"
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
    WORK_DIR="$(mktemp -d -t anland-gnome.XXXXXXXX)"

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
    [[ "$prepared_work_dir" =~ ^/tmp/anland-gnome\.[A-Za-z0-9]+$ ]] || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_package_dir" == "$prepared_work_dir/anland-gnome-packages/$ARCHIVE_TARGET" ]] || \
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
    local -a selected=()
    for file in "${files[@]}"; do
        package="$(dpkg-deb -f "$file" Package 2>/dev/null || true)"
        if is_test_package "$package"; then
            log "跳过测试软件包：${package}" "Skipping test package: ${package}"
            continue
        fi
        selected+=("$file")
    done
    files=("${selected[@]}")
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
    local -a selected=()
    for file in "${files[@]}"; do
        package_name="$(rpm -qp --queryformat '%{NAME}' "$file" 2>/dev/null || true)"
        if is_test_package "$package_name"; then
            log "跳过测试软件包：${package_name}" "Skipping test package: ${package_name}"
            continue
        fi
        selected+=("$file")
    done
    files=("${selected[@]}")
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
    dnf_backup="$(mktemp -t anland-gnome-dnf-backup.XXXXXXXX)"
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

write_pacman_package_state() {
    local state_dir temporary_file
    state_dir="${PACMAN_PACKAGE_STATE%/*}"
    install -d -m 0755 "$state_dir"
    temporary_file="$(mktemp "$PACMAN_PACKAGE_STATE.tmp.XXXXXXXX")" || \
        die "无法记录 Arch Mutter/Xwayland 软件包。" "Could not record the Arch Mutter/Xwayland packages."
    if ! printf '%s\n' "$@" | sort -u > "$temporary_file" || \
        ! chmod 0644 "$temporary_file" || ! mv -f -- "$temporary_file" "$PACMAN_PACKAGE_STATE"; then
        rm -f -- "$temporary_file"
        die "无法记录 Arch Mutter/Xwayland 软件包。" "Could not record the Arch Mutter/Xwayland packages."
    fi
}

install_arch_packages() {
    ds_operation_phase packages
    local file package_name pacman_conf mutter_count=0 xwayland_count=0
    local -a archive_files=() files=() packages=()

    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    mapfile -t archive_files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
    for file in "${archive_files[@]}"; do
        package_name="$(LC_ALL=C pacman -Qp "$file" | awk 'NR == 1 { print $1 }')" || \
            die "无法读取 Arch 软件包名。" "Could not read an Arch package name."
        case "$package_name" in
            mutter)
                files+=("$file")
                packages+=(mutter)
                ((mutter_count += 1))
                ;;
            xorg-xwayland)
                files+=("$file")
                packages+=(xorg-xwayland)
                ((xwayland_count += 1))
                ;;
            *)
                die "Arch GNOME 归档包含不支持的软件包：$package_name。" "The Arch GNOME archive contains an unsupported package: $package_name."
                ;;
        esac
    done
    if ((${#files[@]} != 2 || mutter_count != 1 || xwayland_count != 1)); then
        die "归档必须包含一个 Mutter 和一个 patched Xwayland 包。" "The archive must contain one Mutter and one patched Xwayland package."
    fi

    pacman_conf="$(mktemp -t anland-gnome-pacman.XXXXXXXX)"
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
        die "Arch Mutter/Xwayland 软件包安装失败。" "Failed to install the Arch Mutter/Xwayland packages."
    fi
    rm -f -- "$pacman_conf"

    if ! pacman -Q "${packages[@]}" >/dev/null; then
        die "无法确认已安装 Arch Mutter/Xwayland 软件包。" "Could not verify that the Arch Mutter/Xwayland packages were installed."
    fi
    if ! write_pacman_hold_block "${packages[@]}"; then
        die "无法更新 pacman 锁定配置。" "Unable to update the pacman hold configuration."
    fi
    write_pacman_package_state "${packages[@]}"
    rm -f -- "$APT_HOLD_STATE"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
    printf '  IgnorePkg: %s\n' "${packages[@]}"
}

main() {
    local archive_version owner
    detect_language
    parse_arguments "$@"
    detect_target
    check_architecture
    ds_operation_preflight gnome
    if [[ "$UNINSTALL" == true ]]; then
        require_root "$@"
        ds_operation_begin gnome
        ds_operation_snapshot_installer_config
        uninstall_gnome
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
    ds_operation_begin gnome
    ds_operation_snapshot_installer_config
    if owner="$(other_xwayland_owner)"; then
        die "检测到 Anland ${owner}；GNOME 与它共用 patched Xwayland；请先卸载该组件以避免覆盖。" \
            "Anland ${owner} is installed; it shares the patched Xwayland with GNOME; uninstall it before installing GNOME to avoid overwriting it."
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
    log "安装完成，patched Mutter/Xwayland 已锁定。" \
        "Installation complete; patched Mutter/Xwayland packages are now locked."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
