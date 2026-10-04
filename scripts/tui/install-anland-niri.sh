#!/usr/bin/env bash
set -euo pipefail

# Install the Anland Niri and patched Xwayland Arch ARM packages published by
# build-anland-packages.yml. Package ownership remains with pacman.
readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${ANLAND_NIRI_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}"
RELEASE_TAG="${ANLAND_NIRI_RELEASE_TAG:-}"
readonly ROLLING_RELEASE_TAG="anland-niri-packages"
readonly MANIFEST_NAME="anland-niri-manifest"
readonly CHECKSUMS_NAME="SHA256SUMS"
readonly MAX_MANIFEST_BYTES=$((1024 * 1024))
readonly MAX_CHECKSUMS_BYTES=$((1024 * 1024))
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((2 * 1024 * 1024 * 1024))
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly COMPONENT_STATE_DIR="${DROIDSPACES_COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}"
readonly PACMAN_CONF="${ANLAND_NIRI_PACMAN_CONF:-/etc/pacman.conf}"
readonly PACMAN_HOLD_BEGIN="# BEGIN anland-niri package holds"
readonly PACMAN_HOLD_END="# END anland-niri package holds"
readonly DESKTOP_CONFIG="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"

WORK_DIR=""
PREPARED_WORK_DIR="${ANLAND_NIRI_WORK_DIR:-}"
PREPARED_ARCHIVE_FILE="${ANLAND_NIRI_ARCHIVE_FILE:-}"
UI_LANG="en"
TARGET="Arch Linux ARM"
ARCHIVE_PREFIX="anland-niri-arch-"
ARCHIVE_SUFFIX="-aarch64.tar.gz"
ARCHIVE_NAME=""
ARCHIVE_FILE=""
PACKAGE_DIR=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
CHECKSUMS_FILE=""
EXPECTED_MANIFEST_SHA256=""
EXPECTED_ARCHIVE_SHA256=""
OFFICIAL_RELEASE_METADATA=""
PACKAGE_VERSION=""
ASSET_VERSION=""
UNINSTALL=false

detect_language() {
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    [[ "$locale_name" == zh* ]] && UI_LANG="zh"
}

msg() {
    if [[ "$UI_LANG" == zh ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

log() { printf '[anland-niri] %s\n' "$(msg "$1" "$2")"; }

die() {
    printf '[anland-niri] %s: %s\n' "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
}

record_component_version() {
    local version="$1" state_file="$COMPONENT_STATE_DIR/niri.version" temporary_file
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    mkdir -p -- "$COMPONENT_STATE_DIR" || {
        log "无法记录 Niri 版本。" "Could not record the Niri version."
        return 0
    }
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "无法记录 Niri 版本。" "Could not record the Niri version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" && chmod 0644 "$temporary_file" && \
        mv -f -- "$temporary_file" "$state_file"; then
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "无法记录 Niri 版本。" "Could not record the Niri version."
}

parse_arguments() {
    local argument
    for argument in "$@"; do
        case "$argument" in
            -1|--1) DOWNLOAD_SOURCE=1; SKIP_SOURCE_PROBE=true ;;
            -2|--2) DOWNLOAD_SOURCE=2; SKIP_SOURCE_PROBE=true ;;
            -3|--3) DOWNLOAD_SOURCE=3; SKIP_SOURCE_PROBE=true ;;
            --uninstall) UNINSTALL=true ;;
            -h|--help)
                cat <<EOF_HELP
用法: $0 [选项]

安装或卸载 Anland Niri 及其配套 Xwayland Arch ARM 软件包。

  -1, --1          使用 GitHub
  -2, --2          使用 gh-proxy.com
  -3, --3          使用 CNB
  --uninstall      卸载 Niri；有 Anland KDE 时保留其共用的 Xwayland
  -h, --help       显示帮助
EOF_HELP
                exit 0
                ;;
            *) die "不支持的参数：${argument}。可用参数为 -1/--1、-2/--2、-3/--3、--uninstall。" \
                "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, -3/--3, and --uninstall." ;;
        esac
    done
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi
}
trap cleanup EXIT

require_root() {
    (( EUID == 0 )) && return 0
    command -v sudo >/dev/null 2>&1 || die "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."
    local script_path="${BASH_SOURCE[0]}" status
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    if sudo env \
        "ANLAND_NIRI_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "ANLAND_NIRI_RELEASE_TAG=$RELEASE_TAG" \
        "ANLAND_NIRI_WORK_DIR=$WORK_DIR" \
        "ANLAND_NIRI_ARCHIVE_FILE=$ARCHIVE_FILE" \
        "DROIDSPACES_COMPONENT_STATE_DIR=$COMPONENT_STATE_DIR" \
        "DROIDSPACES_DESKTOP_CONFIG=$DESKTOP_CONFIG" \
        bash "$script_path" "$@"; then status=0; else status=$?; fi
    cleanup
    exit "$status"
}

CONFIGURED_DESKTOP="none"
CONFIGURED_DISPLAY_BACKEND=""

parse_desktop_config() {
    local line desktop_lines=0 backend_lines=0
    CONFIGURED_DESKTOP="none"
    CONFIGURED_DISPLAY_BACKEND=""
    if [[ ! -e "$DESKTOP_CONFIG" && ! -L "$DESKTOP_CONFIG" ]]; then return 0; fi
    [[ -f "$DESKTOP_CONFIG" && ! -L "$DESKTOP_CONFIG" && -r "$DESKTOP_CONFIG" ]] || \
        die "桌面配置不是可安全读取的普通文件：${DESKTOP_CONFIG}。" \
            "The desktop configuration is not a safely readable regular file: ${DESKTOP_CONFIG}."
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            DESKTOP=*) CONFIGURED_DESKTOP="${line#DESKTOP=}"; ((desktop_lines += 1)) ;;
            DISPLAY_BACKEND=*) CONFIGURED_DISPLAY_BACKEND="${line#DISPLAY_BACKEND=}"; ((backend_lines += 1)) ;;
        esac
    done < "$DESKTOP_CONFIG"
    if ((desktop_lines != 1 || backend_lines > 1)) || \
        [[ ! "$CONFIGURED_DESKTOP" =~ ^(none|[a-z][a-z0-9-]*)$ ]] || \
        { ((backend_lines == 1)) && [[ ! "$CONFIGURED_DISPLAY_BACKEND" =~ ^[a-z][a-z0-9-]*$ ]]; }; then
        die "桌面配置格式无效，未覆盖原文件。" "The desktop configuration is invalid; the original file was not overwritten."
    fi
}

preflight_desktop_config() {
    parse_desktop_config
    if [[ "$CONFIGURED_DESKTOP" == niri && "$CONFIGURED_DISPLAY_BACKEND" == x11 ]]; then
        die "当前已选择 Niri，但 DISPLAY_BACKEND=x11；Niri 需要 Anland Wayland，请先修复桌面配置。" \
            "Niri is selected with DISPLAY_BACKEND=x11; Niri requires Anland Wayland. Fix the desktop configuration first."
    fi
}

update_desktop_config() {
    local config_dir temporary_file
    parse_desktop_config
    if [[ "$CONFIGURED_DESKTOP" != none ]]; then
        log "保留现有桌面配置：DESKTOP=${CONFIGURED_DESKTOP}，DISPLAY_BACKEND=${CONFIGURED_DISPLAY_BACKEND:-未设置}。" \
            "Keeping the existing desktop configuration: DESKTOP=${CONFIGURED_DESKTOP}, DISPLAY_BACKEND=${CONFIGURED_DISPLAY_BACKEND:-unset}."
        return 0
    fi
    config_dir="$(dirname -- "$DESKTOP_CONFIG")"
    install -d -m 0755 -- "$config_dir" || die "无法创建桌面配置目录。" "Could not create the desktop configuration directory."
    temporary_file="$(mktemp "$config_dir/.droidspaces-desktop.conf.tmp.XXXXXXXX")" || \
        die "无法创建临时桌面配置。" "Could not create a temporary desktop configuration."
    if [[ ! -e "$DESKTOP_CONFIG" && ! -L "$DESKTOP_CONFIG" ]]; then
        if ! printf 'DESKTOP=niri\nDISPLAY_BACKEND=anland-wayland\n' > "$temporary_file" || \
            ! chmod 0644 "$temporary_file" || ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
            rm -f -- "$temporary_file" || true
            die "无法创建桌面配置。" "Could not create the desktop configuration."
        fi
    else
        if ! awk '
            /^DESKTOP=/ { print "DESKTOP=niri"; next }
            /^DISPLAY_BACKEND=/ { print "DISPLAY_BACKEND=anland-wayland"; backend = 1; next }
            { print }
            END { if (!backend) print "DISPLAY_BACKEND=anland-wayland" }
        ' "$DESKTOP_CONFIG" > "$temporary_file" || \
            ! chmod --reference="$DESKTOP_CONFIG" "$temporary_file" || \
            ! chown --reference="$DESKTOP_CONFIG" "$temporary_file" || \
            ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
            rm -f -- "$temporary_file" || true
            die "无法更新桌面配置。" "Could not update the desktop configuration."
        fi
    fi
    log "已将桌面配置更新为 DESKTOP=niri、DISPLAY_BACKEND=anland-wayland。" \
        "Updated desktop configuration to DESKTOP=niri and DISPLAY_BACKEND=anland-wayland."
}

reset_niri_desktop_config() {
    local config_dir temporary_file
    parse_desktop_config
    [[ "$CONFIGURED_DESKTOP" == niri ]] || return 0
    config_dir="$(dirname -- "$DESKTOP_CONFIG")"
    temporary_file="$(mktemp "$config_dir/.droidspaces-desktop.conf.tmp.XXXXXXXX")" || \
        die "无法创建桌面配置临时文件。" "Could not create a temporary desktop configuration."
    if ! awk '
        /^DESKTOP=/ { print "DESKTOP=none"; next }
        /^DISPLAY_BACKEND=/ { print "DISPLAY_BACKEND=x11"; backend = 1; next }
        { print }
        END { if (!backend) print "DISPLAY_BACKEND=x11" }
    ' "$DESKTOP_CONFIG" > "$temporary_file" || \
        ! chmod --reference="$DESKTOP_CONFIG" "$temporary_file" || \
        ! chown --reference="$DESKTOP_CONFIG" "$temporary_file" || \
        ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
        rm -f -- "$temporary_file" || true
        die "无法将卸载后的桌面配置切回 DESKTOP=none。" \
            "Could not reset the desktop configuration to DESKTOP=none after uninstall."
    fi
    log "已将桌面配置切回 DESKTOP=none、DISPLAY_BACKEND=x11。" \
        "Reset desktop configuration to DESKTOP=none and DISPLAY_BACKEND=x11."
}

check_target() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。" "Unable to read /etc/os-release."
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID,,}" in
        arch|archarm|archlinux) ;;
        *) die "Niri 预编译包目前仅支持 Arch Linux ARM。" "The Niri prebuilt package currently supports Arch Linux ARM only." ;;
    esac
    case "$(uname -m)" in
        aarch64|arm64) ;;
        *) die "预编译包仅支持 ARM64/aarch64。" "The prebuilt package supports ARM64/aarch64 only." ;;
    esac
    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
}

validate_repository() {
    [[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
        die "Release 仓库必须是 owner/repository 格式。" "The Release repository must use the owner/repository format."
}

resolve_release_tag() {
    validate_repository
    [[ -n "$RELEASE_TAG" ]] || RELEASE_TAG="$ROLLING_RELEASE_TAG"
    [[ "$RELEASE_TAG" == "$ROLLING_RELEASE_TAG" ]] || \
        die "Release tag 只能是 ${ROLLING_RELEASE_TAG}。" "The Release tag must be ${ROLLING_RELEASE_TAG}."
    log "使用固定滚动 Release：${RELEASE_TAG}" "Using rolling Release: ${RELEASE_TAG}"
}

download_file() {
    local url="$1" destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O "$destination" "$url"
    else
        die "未找到 curl 或 wget。" "Neither curl nor wget was found."
    fi
}

download_stdout() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 60 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O - "$url"
    else
        die "未找到 curl 或 wget。" "Neither curl nor wget was found."
    fi
}

release_download_base() {
    case "$DOWNLOAD_SOURCE" in
        1) printf '%s/%s/releases/download/%s' "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        2) printf '%s/%s/releases/download/%s' "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        3) printf '%s/%s/-/releases/download/%s' "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        *) die "下载源选择无效。" "The selected download source is invalid." ;;
    esac
}

download_source_name() {
    case "$1" in 1) printf GitHub ;; 2) printf gh-proxy.com ;; 3) printf CNB ;; *) return 1 ;; esac
}

download_source_probe_url() {
    case "$1" in
        1) printf '%s/%s/releases/download/%s/%s' "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME" ;;
        2) printf '%s/%s/releases/download/%s/%s' "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME" ;;
        3) printf '%s/%s/-/releases/download/%s/%s' "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME" ;;
        *) return 1 ;;
    esac
}

probe_download_source() {
    local source="$1" url latency status=0
    url="$(download_source_probe_url "$source")" || return 1
    if command -v curl >/dev/null 2>&1; then
        if latency="$(curl -fsSL --connect-timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" --max-time "$SOURCE_PROBE_TIMEOUT_SECONDS" \
            --output /dev/null --write-out '%{time_total}' "$url" 2>/dev/null)"; then
            awk -v seconds="$latency" 'BEGIN { printf "%.0f ms", seconds * 1000 }'; return
        else status=$?; fi
    elif command -v wget >/dev/null 2>&1; then
        if timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" wget -q --tries=1 --timeout="$SOURCE_PROBE_TIMEOUT_SECONDS" -O /dev/null "$url"; then
            printf '%s' "$(msg '可用' 'available')"; return
        else status=$?; fi
    else
        die "未找到 curl 或 wget。" "Neither curl nor wget was found."
    fi
    if ((status == 28 || status == 124)); then printf '%s' "$(msg '超时' 'timeout')"; else printf '%s' "$(msg '不可用' 'unavailable')"; fi
}

select_download_source() {
    local source latency choice recommendation
    if [[ "$SKIP_SOURCE_PROBE" == true ]]; then
        log "已按参数选择 $(download_source_name "$DOWNLOAD_SOURCE")，跳过延迟测试。" \
            "Selected $(download_source_name "$DOWNLOAD_SOURCE") from the command line; skipping latency checks."
        return
    fi
    log "正在测试下载源延迟（达到 ${SOURCE_PROBE_TIMEOUT_SECONDS} 秒视为超时）..." \
        "Testing download-source latency (timeouts at ${SOURCE_PROBE_TIMEOUT_SECONDS} seconds)..."
    for source in 1 2 3; do
        latency="$(probe_download_source "$source")"
        recommendation=""
        [[ "$source" == 3 ]] && recommendation="$(msg '（推荐）' ' (recommended)')"
        printf '%s. %s%s %s: %s\n' "$source" "$(download_source_name "$source")" "$recommendation" \
            "$(msg '延迟' 'latency')" "$latency"
    done
    while :; do
        printf '%s' "$(msg '请输入下载源编号 [1-3]: ' 'Choose a download source [1-3]: ')"
        IFS= read -r choice || die "无法读取下载源选择。" "Unable to read a download-source choice."
        case "$choice" in 1|2|3) DOWNLOAD_SOURCE="$choice"; return ;; *) log "请输入 1、2 或 3。" "Enter 1, 2, or 3." ;; esac
    done
}

fetch_official_release_metadata() {
    local api_url="${GITHUB_API_URL}/repos/${RELEASE_REPOSITORY}/releases/tags/${RELEASE_TAG}"
    OFFICIAL_RELEASE_METADATA="$(download_stdout "$api_url")" || {
        log "无法获取 GitHub 官方 SHA-256 校验值，拒绝使用第三方镜像包。" \
            "Could not obtain GitHub's official SHA-256 digest; refusing the third-party mirror package."
        return 1
    }
}

release_asset_sha256() {
    local name="$1" digest
    command -v jq >/dev/null 2>&1 || return 1
    digest="$(jq -er --arg name "$name" --arg tag "$RELEASE_TAG" '
        if .tag_name != $tag or .draft != false then error("release tag or status mismatch")
        else [.assets[] | select(.name == $name) | .digest]
             | if length == 1 then .[0] else error("asset digest is not unique") end end
    ' <<< "$OFFICIAL_RELEASE_METADATA" 2>/dev/null)" || return 1
    [[ "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1],,}"
}

resolve_official_digest() {
    local name="$1" result_name="$2"
    [[ "$DOWNLOAD_SOURCE" == 1 ]] && return 0
    command -v jq >/dev/null 2>&1 || die "第三方镜像校验需要 jq。" "jq is required to verify third-party mirrors."
    command -v sha256sum >/dev/null 2>&1 || die "第三方镜像校验需要 sha256sum。" "sha256sum is required to verify third-party mirrors."
    [[ -n "$OFFICIAL_RELEASE_METADATA" ]] || fetch_official_release_metadata || return 1
    local digest
    digest="$(release_asset_sha256 "$name")" || {
        log "GitHub Release 未提供 ${name} 的有效 SHA-256。" "GitHub Release has no valid SHA-256 for ${name}."
        return 1
    }
    if [[ "$result_name" == manifest ]]; then EXPECTED_MANIFEST_SHA256="$digest"; else EXPECTED_ARCHIVE_SHA256="$digest"; fi
}

checksum_sha256_for_asset() {
    local checksums_file="$1" asset_name="$2"
    awk -v asset_name="$asset_name" '
        $1 ~ /^[0-9A-Fa-f]+$/ && length($1) == 64 && NF == 2 {
            name = $2; sub(/^\*/, "", name)
            if (name == asset_name) { digest = tolower($1); count++ }
        }
        END { if (count == 1) print digest; else exit 1 }
    ' "$checksums_file"
}

prepare_cnb_checksums() {
    local base_url="$1" size
    CHECKSUMS_FILE="$WORK_DIR/$CHECKSUMS_NAME"
    download_file "$base_url/$CHECKSUMS_NAME" "$CHECKSUMS_FILE" || return 1
    size="$(stat -c '%s' "$CHECKSUMS_FILE")" || return 1
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le "$MAX_CHECKSUMS_BYTES" ]] || return 1
    EXPECTED_MANIFEST_SHA256="$(checksum_sha256_for_asset "$CHECKSUMS_FILE" "$MANIFEST_NAME")" || {
        log "CNB SHA256SUMS 缺少 manifest 的唯一校验值。" "CNB SHA256SUMS has no unique manifest digest."
        return 1
    }
}

resolve_cnb_archive_digest() {
    EXPECTED_ARCHIVE_SHA256="$(checksum_sha256_for_asset "$CHECKSUMS_FILE" "$ARCHIVE_NAME")" || {
        log "CNB SHA256SUMS 缺少 ${ARCHIVE_NAME} 的唯一校验值。" "CNB SHA256SUMS has no unique digest for ${ARCHIVE_NAME}."
        return 1
    }
}

validate_digest() {
    local path="$1" expected="$2" name="$3" actual
    actual="$(sha256sum "$path" | awk '{print $1}')"
    [[ "$actual" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] || {
        log "${name} 未通过 SHA-256 校验。" "${name} failed SHA-256 verification."
        return 1
    }
}

resolve_manifest_archive() {
    local manifest="$1" format release_tag
    local -a names=()
    format="$(awk -F= '$1 == "format" { print substr($0, index($0, "=") + 1) }' "$manifest")"
    release_tag="$(awk -F= '$1 == "release_tag" { print substr($0, index($0, "=") + 1) }' "$manifest")"
    [[ "$format" == 1 && "$release_tag" == "$RELEASE_TAG" ]] || return 1
    mapfile -t names < <(awk -F= '$1 == "arch" { print substr($0, index($0, "=") + 1) }' "$manifest")
    [[ "${#names[@]}" -eq 1 ]] || return 1
    ARCHIVE_NAME="${names[0]}"
    [[ "$ARCHIVE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ && "$ARCHIVE_NAME" != *..* ]] || return 1
    case "$ARCHIVE_NAME" in "${ARCHIVE_PREFIX}"*"${ARCHIVE_SUFFIX}") ;; *) return 1 ;; esac
    ASSET_VERSION="${ARCHIVE_NAME#"$ARCHIVE_PREFIX"}"
    ASSET_VERSION="${ASSET_VERSION%"$ARCHIVE_SUFFIX"}"
    [[ "$ASSET_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+~_-]{0,63}$ ]]
}

validate_archive_contents() {
    local archive="$1" size members entry verbose_size
    size="$(stat -c '%s' "$archive")" || return 1
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le "$MAX_ARCHIVE_BYTES" ]] || return 1
    members="$(tar -tzf "$archive")" || return 1
    [[ -n "$members" ]] || return 1
    local has_niri=false has_xwayland=false has_info=false
    while IFS= read -r entry; do
        case "$entry" in
            anland-niri-packages/arch/) ;;
            anland-niri-packages/arch/.anland-niri-build-info) has_info=true ;;
            anland-niri-packages/arch/*.pkg.tar.zst)
                local basename="${entry##*/}"
                [[ "$basename" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*\.pkg\.tar\.zst$ && "$basename" != *..* ]] || return 1
                [[ "$basename" == niri-anland-*.pkg.tar.zst ]] && has_niri=true
                [[ "$basename" == xorg-xwayland-*.pkg.tar.zst ]] && has_xwayland=true
                ;;
            /*|.|./*|..|../*|*/.|*/./*|*/..|*/../*) return 1 ;;
            *) return 1 ;;
        esac
    done <<< "$members"
    [[ "$has_niri" == true && "$has_xwayland" == true && "$has_info" == true ]] || return 1
    verbose_size="$(LC_ALL=C tar -tvzf "$archive" | awk -v maximum="$MAX_EXTRACTED_BYTES" '
        {
            kind = substr($1, 1, 1)
            if (kind !~ /^[-d]$/ || $3 !~ /^[0-9]+$/) exit 1
            total += $3; if (total > maximum) exit 1
        }
    ')" || return 1
}

validate_package_set() {
    local file info name arch version count_niri=0 count_xwayland=0
    local niri_version=""
    local -a files=()
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print | sort)
    ((${#files[@]} == 2)) || return 1
    for file in "${files[@]}"; do
        info="$(LC_ALL=C pacman -Qip "$file")" || return 1
        name="$(sed -n 's/^[[:space:]]*Name[[:space:]]*:[[:space:]]*//p' <<< "$info")"
        arch="$(sed -n 's/^[[:space:]]*Architecture[[:space:]]*:[[:space:]]*//p' <<< "$info")"
        version="$(sed -n 's/^[[:space:]]*Version[[:space:]]*:[[:space:]]*//p' <<< "$info")"
        [[ "$arch" == aarch64 && "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 1
        case "$name" in
            niri-anland)
                [[ "$file" == */niri-anland-*.pkg.tar.zst ]] || return 1
                count_niri=$((count_niri + 1)); niri_version="$version"
                ;;
            xorg-xwayland)
                [[ "$file" == */xorg-xwayland-*.pkg.tar.zst ]] || return 1
                count_xwayland=$((count_xwayland + 1))
                ;;
            *) return 1 ;;
        esac
    done
    [[ "$count_niri" -eq 1 && "$count_xwayland" -eq 1 ]] || return 1
    PACKAGE_VERSION="$niri_version"
}

validate_build_info() {
    local info="$PACKAGE_DIR/.anland-niri-build-info" target version
    [[ -f "$info" && ! -L "$info" ]] || return 1
    target="$(sed -n 's/^target=//p' "$info")"
    version="$(sed -n 's/^niri_version=//p' "$info")"
    [[ "$target" == arch && "$version" == "$ASSET_VERSION" && \
       "$version" == "${PACKAGE_VERSION%-*}" ]]
}

require_runtime_dependencies() {
    local command_name
    for command_name in awk find grep mktemp pacman realpath sed sort stat tar sha256sum; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "缺少运行安装器所需的命令：${command_name}。" "The installer requires the missing command: ${command_name}."
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
        die "未找到 curl 或 wget。" "Neither curl nor wget was found."
}

is_anland_kde_installed() {
    [[ -s "$COMPONENT_STATE_DIR/kde.version" ]] && return 0
    [[ -s /var/lib/anland-kde/pacman-packages ]] && return 0
    grep -Eq '^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])kwin([[:space:]]|$)' /etc/pacman.conf 2>/dev/null
}

refuse_kde_conflict() {
    is_anland_kde_installed && die \
        "检测到 Anland KDE。Niri 与 KDE 共用 patched xorg-xwayland；为避免覆盖或错误恢复，请先卸载 Anland KDE。" \
        "Anland KDE is installed. Niri and KDE share patched xorg-xwayland; uninstall Anland KDE first to avoid replacing or restoring the wrong package."
}

download_packages_once() {
    local base_url manifest_file manifest_size cnb_manifest_sha256="" cnb_archive_sha256=""
    base_url="$(release_download_base)"
    manifest_file="$WORK_DIR/$MANIFEST_NAME"
    OFFICIAL_RELEASE_METADATA=""
    if [[ "$DOWNLOAD_SOURCE" == 3 ]]; then
        CHECKSUMS_FILE="$WORK_DIR/$CHECKSUMS_NAME"
        download_file "$base_url/$CHECKSUMS_NAME" "$CHECKSUMS_FILE" || return 1
        local checksums_size
        checksums_size="$(stat -c '%s' "$CHECKSUMS_FILE")" || return 1
        [[ "$checksums_size" =~ ^[0-9]+$ && "$checksums_size" -gt 0 && "$checksums_size" -le "$MAX_CHECKSUMS_BYTES" ]] || return 1
        cnb_manifest_sha256="$(checksum_sha256_for_asset "$CHECKSUMS_FILE" "$MANIFEST_NAME")" || return 1
        resolve_official_digest "$MANIFEST_NAME" manifest || return 1
        [[ "$EXPECTED_MANIFEST_SHA256" == "$cnb_manifest_sha256" ]] || {
            log "CNB manifest 校验值与 GitHub 官方摘要不一致。" "The CNB manifest digest does not match GitHub's official digest."
            return 1
        }
    else
        resolve_official_digest "$MANIFEST_NAME" manifest || return 1
    fi
    log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载 ${TARGET} Anland Niri 包..." \
        "Downloading the ${TARGET} Anland Niri packages from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$base_url/$MANIFEST_NAME" "$manifest_file" || return 1
    manifest_size="$(stat -c '%s' "$manifest_file")" || return 1
    [[ "$manifest_size" =~ ^[0-9]+$ && "$manifest_size" -gt 0 && "$manifest_size" -le "$MAX_MANIFEST_BYTES" ]] || return 1
    [[ -z "$EXPECTED_MANIFEST_SHA256" ]] || validate_digest "$manifest_file" "$EXPECTED_MANIFEST_SHA256" "$MANIFEST_NAME" || return 1
    resolve_manifest_archive "$manifest_file" || {
        log "Release 清单中没有有效的 Arch ARM 归档。" "The Release manifest has no valid Arch ARM archive."
        return 1
    }
    if [[ "$DOWNLOAD_SOURCE" == 3 ]]; then
        cnb_archive_sha256="$(checksum_sha256_for_asset "$CHECKSUMS_FILE" "$ARCHIVE_NAME")" || return 1
        resolve_official_digest "$ARCHIVE_NAME" archive || return 1
        [[ "$EXPECTED_ARCHIVE_SHA256" == "$cnb_archive_sha256" ]] || {
            log "CNB 归档校验值与 GitHub 官方摘要不一致。" "The CNB archive digest does not match GitHub's official digest."
            return 1
        }
    else
        resolve_official_digest "$ARCHIVE_NAME" archive || return 1
    fi
    ARCHIVE_FILE="$WORK_DIR/$ARCHIVE_NAME"
    download_file "$base_url/$ARCHIVE_NAME" "$ARCHIVE_FILE" || return 1
    [[ -z "$EXPECTED_ARCHIVE_SHA256" ]] || validate_digest "$ARCHIVE_FILE" "$EXPECTED_ARCHIVE_SHA256" "$ARCHIVE_NAME" || return 1
    validate_archive_contents "$ARCHIVE_FILE" || {
        log "下载归档的结构无效或不安全。" "The downloaded archive is malformed or unsafe."
        return 1
    }
    tar --no-same-owner --no-same-permissions -xzf "$ARCHIVE_FILE" -C "$WORK_DIR" || return 1
    PACKAGE_DIR="$WORK_DIR/anland-niri-packages/arch"
    validate_package_set && validate_build_info || {
        log "归档中的 Niri/Xwayland 软件包或构建信息校验失败。" \
            "Niri/Xwayland packages or build information in the archive failed validation."
        return 1
    }
}

download_packages() {
    local attempt
    WORK_DIR="$(mktemp -d -t anland-niri.XXXXXXXX)"
    chmod 0700 "$WORK_DIR"
    for ((attempt = 1; attempt <= 3; attempt++)); do
        if ((attempt > 1)); then
            rm -rf -- "$WORK_DIR"
            mkdir -m 0700 -- "$WORK_DIR"
        fi
        if download_packages_once; then return 0; fi
        if ((attempt < 3)); then
            log "Release 正在更新或网络暂时失败，准备重试（第 ${attempt} 次）。" \
                "The Release is updating or the network failed; retrying after attempt ${attempt}."
            sleep "$attempt"
        fi
    done
    die "无法稳定获取 Anland Niri 软件包，请稍后重试。" "Unable to consistently download the Anland Niri packages; please retry later."
}

use_prepared_packages() {
    local prepared_work_dir prepared_archive_file
    prepared_work_dir="$(realpath -e "$PREPARED_WORK_DIR")" || die "预下载目录无效。" "The pre-downloaded directory is invalid."
    prepared_archive_file="$(realpath -e "$PREPARED_ARCHIVE_FILE")" || die "预下载归档无效。" "The pre-downloaded archive is invalid."
    [[ "$prepared_work_dir" =~ ^/tmp/anland-niri\.[A-Za-z0-9]+$ && "$prepared_archive_file" == "$prepared_work_dir/"* ]] || \
        die "预下载归档路径无效。" "The pre-downloaded archive path is invalid."
    [[ -d "$prepared_work_dir" && -f "$prepared_archive_file" ]] || die "预下载归档不存在。" "The pre-downloaded archive does not exist."
    WORK_DIR="$prepared_work_dir"
    ARCHIVE_FILE="$prepared_archive_file"
    ARCHIVE_NAME="${ARCHIVE_FILE##*/}"
    case "$ARCHIVE_NAME" in "${ARCHIVE_PREFIX}"*"${ARCHIVE_SUFFIX}") ;; *) die "归档与当前系统不匹配。" "The archive does not match this system." ;; esac
    ASSET_VERSION="${ARCHIVE_NAME#"$ARCHIVE_PREFIX"}"
    ASSET_VERSION="${ASSET_VERSION%"$ARCHIVE_SUFFIX"}"
    [[ "$ASSET_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+~_-]{0,63}$ ]] || die "归档版本无效。" "The archive version is invalid."
    validate_archive_contents "$ARCHIVE_FILE" || die "预下载归档结构不安全。" "The pre-downloaded archive is unsafe."
    tar --no-same-owner --no-same-permissions -xzf "$ARCHIVE_FILE" -C "$WORK_DIR" || die "无法解压预下载归档。" "Could not extract the pre-downloaded archive."
    PACKAGE_DIR="$WORK_DIR/anland-niri-packages/arch"
    validate_package_set && validate_build_info || die "预下载软件包校验失败。" "The pre-downloaded packages failed validation."
}

installed_package_version() {
    pacman -Q niri-anland 2>/dev/null | awk '{print $2}'
}

add_package_holds() {
    local mode="${1:-all}" temporary_file hold_line
    [[ "$mode" == xwayland-only ]] && hold_line="IgnorePkg = xorg-xwayland" || hold_line="IgnorePkg = niri-anland xorg-xwayland"
    [[ -f "$PACMAN_CONF" && ! -L "$PACMAN_CONF" ]] || die "找不到安全的 pacman.conf。" "A safe pacman.conf was not found."
    grep -qE '^\[options\][[:space:]]*$' "$PACMAN_CONF" || die "pacman.conf 缺少 [options] 段。" "pacman.conf has no [options] section."
    temporary_file="$(mktemp "${PACMAN_CONF}.tmp.XXXXXXXX")" || die "无法创建 pacman.conf 临时文件。" "Could not create a temporary pacman.conf."
    if ! awk -v begin="$PACMAN_HOLD_BEGIN" -v end="$PACMAN_HOLD_END" -v line="$hold_line" '
        function block() { print begin; print line; print end }
        $0 == begin { inside = 1; found = 1; next }
        $0 == end { inside = 0; next }
        inside { next }
        /^\[/ {
            if (in_options && found && !inserted) { block(); inserted = 1 }
            if (in_options && !found && !inserted) { block(); inserted = 1 }
            in_options = ($0 ~ /^\[options\][[:space:]]*$/)
        }
        { print }
        END {
            if (inside) exit 1
            if (in_options && !inserted) { block(); inserted = 1 }
            if (!inserted) exit 1
        }
    ' "$PACMAN_CONF" > "$temporary_file"; then
        rm -f -- "$temporary_file"
        die "无法在 pacman.conf 的 [options] 中加入 hold。" "Could not add the package hold in pacman.conf [options]."
    fi
    if ! chmod --reference="$PACMAN_CONF" "$temporary_file" || ! chown --reference="$PACMAN_CONF" "$temporary_file" || \
        ! mv -f -- "$temporary_file" "$PACMAN_CONF"; then
        rm -f -- "$temporary_file"
        die "无法锁定 Niri 与 patched Xwayland 软件包。" "Could not hold Niri and patched Xwayland packages."
    fi
}

remove_package_holds() {
    local temporary_file
    [[ -f "$PACMAN_CONF" && ! -L "$PACMAN_CONF" ]] || return 0
    grep -Fqx "$PACMAN_HOLD_BEGIN" "$PACMAN_CONF" || return 0
    grep -Fqx "$PACMAN_HOLD_END" "$PACMAN_CONF" || die "Anland Niri 的 pacman hold 标记不完整。" "The Anland Niri pacman hold markers are incomplete."
    temporary_file="$(mktemp "${PACMAN_CONF}.tmp.XXXXXXXX")" || die "无法创建 pacman.conf 临时文件。" "Could not create a temporary pacman.conf."
    if ! awk -v begin="$PACMAN_HOLD_BEGIN" -v end="$PACMAN_HOLD_END" '
        $0 == begin { inside = 1; next }
        $0 == end { inside = 0; next }
        inside { next }
        { print }
        END { if (inside) exit 1 }
    ' "$PACMAN_CONF" > "$temporary_file"; then
        rm -f -- "$temporary_file"
        die "无法安全移除 Niri pacman hold。" "Could not safely remove the Niri pacman hold."
    fi
    if ! chmod --reference="$PACMAN_CONF" "$temporary_file" || ! chown --reference="$PACMAN_CONF" "$temporary_file" || \
        ! mv -f -- "$temporary_file" "$PACMAN_CONF"; then
        rm -f -- "$temporary_file"
        die "无法更新 pacman.conf。" "Could not update pacman.conf."
    fi
}

install_packages() {
    local pacman_conf installed_version
    local -a files=()
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print | sort)
    ((${#files[@]} == 2)) || die "安装包集合不完整。" "The package set is incomplete."
    pacman_conf="$(mktemp -t anland-niri-pacman.XXXXXXXX)"
    cp -p -- "$PACMAN_CONF" "$pacman_conf"
    if grep -Eq '^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=' "$pacman_conf"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=.*/LocalFileSigLevel = Optional/' "$pacman_conf"
    elif grep -qE '^\[options\][[:space:]]*$' "$pacman_conf"; then
        sed -i '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' "$pacman_conf"
    else
        rm -f -- "$pacman_conf"
        die "pacman.conf 缺少 [options] 段。" "pacman.conf has no [options] section."
    fi
    # Hold before replacing either shared package. If package installation or
    # later verification fails, the patched Xwayland stays protected.
    add_package_holds all
    if ! pacman --config "$pacman_conf" -U --noconfirm "${files[@]}"; then
        rm -f -- "$pacman_conf"
        die "Arch 软件包安装失败；patched Xwayland 仍保持锁定。" "Arch package installation failed; patched Xwayland remains held."
    fi
    rm -f -- "$pacman_conf"
    pacman -Q niri-anland >/dev/null || die "pacman 未安装 niri-anland。" "pacman did not install niri-anland."
    pacman -Q xorg-xwayland >/dev/null || die "pacman 未安装 patched xorg-xwayland。" "pacman did not install patched xorg-xwayland."
    installed_version="$(installed_package_version || true)"
    [[ "$installed_version" == "$PACKAGE_VERSION" ]] || die \
        "安装后的 Niri 版本与下载包不一致（期望 ${PACKAGE_VERSION}，实际 ${installed_version:-unknown}）。" \
        "The installed Niri version does not match the downloaded package (expected ${PACKAGE_VERSION}, got ${installed_version:-unknown})."
}

uninstall_packages() {
    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    local kde_present=false
    is_anland_kde_installed && kde_present=true
    if pacman -Q niri-anland >/dev/null 2>&1; then
        pacman -R --noconfirm niri-anland || die "卸载 niri-anland 失败。" "Failed to uninstall niri-anland."
    else
        log "没有已安装的 niri-anland 包。" "No installed niri-anland package was found."
    fi
    remove_package_holds
    if [[ "$kde_present" == true ]]; then
        log "保留 Anland KDE 共用的 patched xorg-xwayland。" \
            "Keeping patched xorg-xwayland because Anland KDE also uses it."
    elif pacman -Q xorg-xwayland >/dev/null 2>&1; then
        log "正在恢复发行版 Xwayland..." "Restoring distribution Xwayland..."
        if ! pacman -S --noconfirm xorg-xwayland; then
            add_package_holds xwayland-only
            rm -f -- "$COMPONENT_STATE_DIR/niri.version"
            die "恢复发行版 xorg-xwayland 失败；已重新锁定当前 Xwayland 以避免破坏图形会话。" \
                "Failed to restore distribution xorg-xwayland; the current Xwayland was re-held to avoid breaking graphical sessions."
        fi
    fi
    reset_niri_desktop_config
    rm -f -- "$COMPONENT_STATE_DIR/niri.version"
    rmdir --ignore-fail-on-non-empty "$COMPONENT_STATE_DIR" 2>/dev/null || true
    log "Anland Niri 已卸载；其他依赖未删除。" "Anland Niri was uninstalled; other dependencies were kept."
}

main() {
    detect_language
    parse_arguments "$@"
    check_target
    if [[ "$UNINSTALL" == true ]]; then
        require_root "$@"
        uninstall_packages
        return
    fi
    require_runtime_dependencies
    resolve_release_tag
    if [[ -n "$PREPARED_WORK_DIR" || -n "$PREPARED_ARCHIVE_FILE" ]]; then
        [[ -n "$PREPARED_WORK_DIR" && -n "$PREPARED_ARCHIVE_FILE" ]] || \
            die "预下载环境变量不完整。" "The pre-downloaded archive environment is incomplete."
        use_prepared_packages
    else
        select_download_source
        download_packages
    fi
    require_root "$@"
    preflight_desktop_config
    refuse_kde_conflict
    install_packages
    record_component_version "$PACKAGE_VERSION"
    update_desktop_config
    log "Anland Niri 安装完成（${PACKAGE_VERSION}）。" "Anland Niri installation completed (${PACKAGE_VERSION})."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
