#!/usr/bin/env bash
set -uo pipefail

readonly TUI_VERSION="1.2"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
readonly HANGOVER_CACHE_DIR="/var/cache/hangover-wine"
readonly HANGOVER_MANIFEST_NAME="hangover-wine-manifest"
readonly INSTALLED_TUI_PATH="/usr/local/bin/droidspaces-tui"
readonly TUI_RELEASE_REPOSITORY="${DROIDSPACES_TUI_REPOSITORY:-Goldzxcbug/droidspaces-package}"
readonly TUI_RELEASE_TAG="Gold-bug-tui"
readonly TUI_BOOTSTRAP_NAME="install-tui.sh"
readonly TUI_GITHUB_API_URL="${DROIDSPACES_TUI_API_URL:-https://api.github.com}"
readonly TUI_GITHUB_DOWNLOAD_BASE="${DROIDSPACES_TUI_GITHUB_BASE:-https://github.com/$TUI_RELEASE_REPOSITORY/releases/download}"
readonly TUI_PROXY_DOWNLOAD_BASE="${DROIDSPACES_TUI_PROXY_BASE:-https://gh-proxy.com/https://github.com/$TUI_RELEASE_REPOSITORY/releases/download}"
readonly TUI_CNB_DOWNLOAD_BASE="${DROIDSPACES_TUI_CNB_BASE:-https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download}"

UI_LANG="en"
DOWNLOAD_SOURCE="auto"
SYSTEM_ID="unknown"
SYSTEM_VERSION=""
SYSTEM_LABEL="Unknown Linux"
ARCHITECTURE="unknown"
CACHE_ACTION=""
UPDATE_WORK_DIR=""
UPDATE_UPDATER_PATH=""

COLOR_RESET=""
COLOR_BOLD=""
COLOR_BLUE=""
COLOR_CYAN=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_DIM=""

detect_language() {
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    [[ "$locale_name" == zh* ]] && UI_LANG="zh"
    return 0
}

msg() {
    if [[ "$UI_LANG" == "zh" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

die() {
    printf 'droidspaces-tui: %s\n' "$(msg "$1" "$2")" >&2
    exit 1
}

usage() {
    cat <<EOF
$(msg '用法' 'Usage'): $0 [$(msg '选项' 'options')]

  --source auto|github|proxy|cnb
                       $(msg '设置初始下载源' 'Set the initial download source')
  --clean-cache manifest|all
                       $(msg '清理 Hangover 清单或全部下载缓存' 'Clean the Hangover manifest or all downloads')
  --no-color           $(msg '关闭彩色输出' 'Disable colored output')
  -h, --help           $(msg '显示此帮助' 'Show this help')
EOF
}

set_download_source_name() {
    case "${1,,}" in
        auto) DOWNLOAD_SOURCE="auto" ;;
        github|1) DOWNLOAD_SOURCE="1" ;;
        proxy|gh-proxy|2) DOWNLOAD_SOURCE="2" ;;
        cnb|3) DOWNLOAD_SOURCE="3" ;;
        *)
            die "不支持的下载源：$1" "Unsupported download source: $1"
            ;;
    esac
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --source)
                (($# >= 2)) || die "--source 缺少参数。" "--source requires a value."
                set_download_source_name "$2"
                shift 2
                ;;
            --source=*)
                set_download_source_name "${1#*=}"
                shift
                ;;
            --clean-cache)
                (($# >= 2)) || die "--clean-cache 缺少参数。" "--clean-cache requires a value."
                CACHE_ACTION="$2"
                shift 2
                ;;
            --clean-cache=*)
                CACHE_ACTION="${1#*=}"
                shift
                ;;
            --no-color)
                NO_COLOR=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "不支持的参数：$1" "Unsupported option: $1"
                ;;
        esac
    done
}

validate_cache_action() {
    case "$CACHE_ACTION" in
        ""|manifest|all) ;;
        *)
            die "不支持的缓存清理范围：$CACHE_ACTION" \
                "Unsupported cache-cleaning scope: $CACHE_ACTION"
            ;;
    esac
}

init_colors() {
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
        COLOR_RESET=$'\033[0m'
        COLOR_BOLD=$'\033[1m'
        COLOR_BLUE=$'\033[34m'
        COLOR_CYAN=$'\033[36m'
        COLOR_GREEN=$'\033[32m'
        COLOR_YELLOW=$'\033[33m'
        COLOR_RED=$'\033[31m'
        COLOR_DIM=$'\033[2m'
    fi
}

detect_system() {
    if [[ -r /etc/os-release ]]; then
        local ID="" VERSION_ID="" PRETTY_NAME=""
        # shellcheck disable=SC1091
        source /etc/os-release
        SYSTEM_ID="${ID,,}"
        SYSTEM_VERSION="$VERSION_ID"
        SYSTEM_LABEL="${PRETTY_NAME:-${ID:-Unknown Linux}${VERSION_ID:+ $VERSION_ID}}"
    fi
    ARCHITECTURE="$(uname -m 2>/dev/null || printf 'unknown')"
}

clear_screen() {
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
        printf '\033[2J\033[H'
    else
        printf '\n'
    fi
}

source_label() {
    case "$DOWNLOAD_SOURCE" in
        auto) msg "自动测速后选择" "Probe and choose" ;;
        1) printf 'GitHub' ;;
        2) printf 'gh-proxy.com' ;;
        3) printf 'CNB' ;;
    esac
}

hangover_cache_size() {
    local output

    if [[ ! -e "$HANGOVER_CACHE_DIR" && ! -L "$HANGOVER_CACHE_DIR" ]]; then
        printf '0 B'
    elif [[ -L "$HANGOVER_CACHE_DIR" || ! -d "$HANGOVER_CACHE_DIR" ]]; then
        msg "路径异常" "invalid path"
    elif output="$(du -sh -- "$HANGOVER_CACHE_DIR" 2>/dev/null)"; then
        printf '%s' "${output%%[[:space:]]*}"
    elif command -v sudo >/dev/null 2>&1 && \
        output="$(sudo -n du -sh -- "$HANGOVER_CACHE_DIR" 2>/dev/null)"; then
        printf '%s' "${output%%[[:space:]]*}"
    else
        msg "需要 root 权限" "root access required"
    fi
}

clean_cache_as_root() {
    local action="$1"

    if ((EUID != 0)); then
        command -v sudo >/dev/null 2>&1 || die \
            "清理缓存需要 root 权限，且系统未安装 sudo。" \
            "Cache cleaning requires root access, and sudo is unavailable."
        exec sudo --preserve-env=LANG,LC_ALL,LC_MESSAGES -- \
            "$SCRIPT_PATH" --no-color --clean-cache "$action"
    fi

    if [[ ! -e "$HANGOVER_CACHE_DIR" && ! -L "$HANGOVER_CACHE_DIR" ]]; then
        return
    fi
    [[ ! -L "$HANGOVER_CACHE_DIR" && -d "$HANGOVER_CACHE_DIR" ]] || die \
        "拒绝清理异常缓存路径：$HANGOVER_CACHE_DIR" \
        "Refusing to clean an invalid cache path: $HANGOVER_CACHE_DIR"

    case "$action" in
        manifest)
            if [[ -d "$HANGOVER_CACHE_DIR/$HANGOVER_MANIFEST_NAME" ]]; then
                die "缓存清单路径异常，拒绝删除。" \
                    "The cached manifest path is invalid; refusing to delete it."
            fi
            rm -f -- "$HANGOVER_CACHE_DIR/$HANGOVER_MANIFEST_NAME"
            ;;
        all)
            command -v find >/dev/null 2>&1 || die \
                "缺少命令：find。" "Required command is missing: find."
            find "$HANGOVER_CACHE_DIR" -mindepth 1 -delete
            ;;
    esac
}

draw_header() {
    printf '%b%s%b\n' "$COLOR_BLUE" "====================================================" "$COLOR_RESET"
    printf '  %b%s%b  %b%s%b\n' \
        "$COLOR_BOLD$COLOR_CYAN" "Droidspaces Toolkit" "$COLOR_RESET" \
        "$COLOR_DIM" "v$TUI_VERSION" "$COLOR_RESET"
    printf '%b%s%b\n' "$COLOR_BLUE" "----------------------------------------------------" "$COLOR_RESET"
    printf '  %s: %s (%s)\n' "$(msg '系统' 'System')" "$SYSTEM_LABEL" "$ARCHITECTURE"
    printf '  %s: %s\n' "$(msg '下载源' 'Source')" "$(source_label)"
    printf '%b%s%b\n' "$COLOR_BLUE" "====================================================" "$COLOR_RESET"
}

installer_names() {
    case "$1" in
        mesa) printf '%s\n%s\n' "install-mesa.sh" "install-mesa" ;;
        hangover) printf '%s\n%s\n' "install-hangover-wine.sh" "install-hangover-wine" ;;
        fonts) printf '%s\n%s\n' "install-winefonts.sh" "install-winefonts" ;;
        kde) printf '%s\n%s\n' "install-anland-kde.sh" "install-anland-kde" ;;
        gnome) printf '%s\n%s\n' "install-anland-gnome.sh" "install-anland-gnome" ;;
        *) return 1 ;;
    esac
}

resolve_installer() {
    local names source_name installed_name candidate
    names="$(installer_names "$1")" || return 1
    source_name="${names%%$'\n'*}"
    installed_name="${names#*$'\n'}"

    if [[ -n "${DROIDSPACES_INSTALLER_DIR:-}" ]]; then
        candidate="${DROIDSPACES_INSTALLER_DIR%/}/$source_name"
        [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    fi

    candidate="$SCRIPT_DIR/$source_name"
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }

    candidate="/usr/local/sbin/$installed_name"
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }

    command -v "$installed_name" 2>/dev/null || return 1
}

is_arm64() {
    case "$ARCHITECTURE" in
        aarch64|arm64) return 0 ;;
        *) return 1 ;;
    esac
}

supports_common_packages() {
    case "$SYSTEM_ID:$SYSTEM_VERSION" in
        arch:*|archarm:*|archlinux:*|debian:13*|ubuntu:24.04*|ubuntu:25.10*|ubuntu:26.04*|fedora:43*|fedora:44*)
            return 0
            ;;
        *) return 1 ;;
    esac
}

component_supported() {
    local component="$1"
    [[ "$component" == "fonts" ]] && return 0
    is_arm64 || return 1

    case "$component" in
        mesa|hangover)
            if [[ "$component" == "mesa" ]]; then
                supports_common_packages
            else
                case "$SYSTEM_ID:$SYSTEM_VERSION" in
                    arch:*|archarm:*|debian:13*|ubuntu:24.04*|ubuntu:25.10*|ubuntu:26.04*|fedora:43*|fedora:44*) return 0 ;;
                    *) return 1 ;;
                esac
            fi
            ;;
        kde)
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                arch:*|archarm:*|debian:13*|ubuntu:26.04*|fedora:43*|fedora:44*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        gnome)
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                debian:13*|ubuntu:26.04*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

component_status() {
    local component="$1"
    if ! resolve_installer "$component" >/dev/null; then
        printf '%b%s%b' "$COLOR_RED" "$(msg '缺少脚本' 'missing')" "$COLOR_RESET"
    elif component_supported "$component"; then
        printf '%b%s%b' "$COLOR_GREEN" "$(msg '可用' 'ready')" "$COLOR_RESET"
    else
        printf '%b%s%b' "$COLOR_YELLOW" "$(msg '当前系统不支持' 'unsupported')" "$COLOR_RESET"
    fi
}

print_component() {
    printf '  %b[%s]%b %-32s %s\n' \
        "$COLOR_CYAN" "$1" "$COLOR_RESET" "$2" "$(component_status "$3")"
}

pause_menu() {
    local unused
    printf '\n%s' "$(msg '按 Enter 返回菜单...' 'Press Enter to return to the menu...')"
    IFS= read -r unused || true
}

confirm_run() {
    local answer
    printf '%s [y/N]: ' "$(msg "确认运行 $1？" "Run $1?")"
    IFS= read -r answer || return 1
    case "${answer,,}" in
        y|yes|1|是) return 0 ;;
        *) return 1 ;;
    esac
}

run_component() {
    local component="$1"
    local label="$2"
    local installer status
    local -a source_argument=()

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$label" "$COLOR_RESET"

    if ! component_supported "$component"; then
        printf '%b%s%b\n' "$COLOR_YELLOW" \
            "$(msg '当前系统或架构不在该安装器的支持范围内。' \
                'The current system or architecture is not supported by this installer.')" \
            "$COLOR_RESET"
        pause_menu
        return
    fi

    if ! installer="$(resolve_installer "$component")"; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '找不到对应的安装脚本。' 'The installer script could not be found.')" \
            "$COLOR_RESET"
        pause_menu
        return
    fi

    printf '%s: %s\n' "$(msg '安装器' 'Installer')" "$installer"
    printf '%s: %s\n\n' "$(msg '下载源' 'Source')" "$(source_label)"
    confirm_run "$label" || return

    case "$DOWNLOAD_SOURCE" in
        1) source_argument=(--1) ;;
        2) source_argument=(--2) ;;
        3) source_argument=(--3) ;;
    esac

    printf '\n%b%s%b\n\n' "$COLOR_BLUE" \
        "$(msg '安装器开始运行。' 'Starting installer.')" "$COLOR_RESET"
    if "$installer" "${source_argument[@]}"; then
        status=0
    else
        status=$?
    fi

    printf '\n'
    if ((status == 0)); then
        printf '%b%s%b\n' "$COLOR_GREEN" \
            "$(msg "$label 已完成。" "$label completed.")" "$COLOR_RESET"
    else
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg "$label 失败，退出码：$status。" "$label failed with exit code $status.")" \
            "$COLOR_RESET"
    fi
    pause_menu
}

select_download_source() {
    local choice
    while :; do
        clear_screen
        draw_header
        printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '选择下载源' 'Select download source')" "$COLOR_RESET"
        printf '  %b[1]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '自动测速并由安装器提示选择' 'Probe sources and let the installer prompt')"
        printf '  %b[2]%b GitHub\n' "$COLOR_CYAN" "$COLOR_RESET"
        printf '  %b[3]%b gh-proxy.com\n' "$COLOR_CYAN" "$COLOR_RESET"
        printf '  %b[4]%b CNB\n' "$COLOR_CYAN" "$COLOR_RESET"
        printf '  %b[0]%b %s\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '返回' 'Back')"
        printf '%s: ' "$(msg '请选择' 'Select')"
        IFS= read -r choice || return
        case "$choice" in
            1) DOWNLOAD_SOURCE="auto"; return ;;
            2) DOWNLOAD_SOURCE="1"; return ;;
            3) DOWNLOAD_SOURCE="2"; return ;;
            4) DOWNLOAD_SOURCE="3"; return ;;
            0|q|Q) return ;;
        esac
    done
}

clean_cache_from_menu() {
    local action="$1"
    local label

    case "$action" in
        manifest)
            label="$(msg 'Hangover Release 清单缓存' 'Hangover Release manifest cache')"
            ;;
        all)
            label="$(msg 'Hangover 全部下载缓存' 'all Hangover download cache')"
            ;;
    esac

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$label" "$COLOR_RESET"
    if [[ "$action" == "all" ]]; then
        printf '%b%s%b\n\n' "$COLOR_YELLOW" \
            "$(msg '这会删除已下载的软件包，下次安装需要重新下载。' \
                'Downloaded package archives will be removed and must be downloaded again.')" \
            "$COLOR_RESET"
    fi
    confirm_run "$(msg "清理 $label" "clean $label")" || return

    printf '\n'
    if "$SCRIPT_PATH" --no-color --clean-cache "$action"; then
        printf '%b%s%b\n' "$COLOR_GREEN" \
            "$(msg "$label 已清理。" "$label cleaned.")" "$COLOR_RESET"
    else
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg "$label 清理失败。" "Failed to clean $label.")" "$COLOR_RESET"
    fi
    pause_menu
}

manage_cache() {
    local choice
    while :; do
        clear_screen
        draw_header
        printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '缓存管理' 'Cache management')" "$COLOR_RESET"
        printf '  %s: %s\n\n' "$(msg 'Hangover 缓存占用' 'Hangover cache usage')" \
            "$(hangover_cache_size)"
        printf '  %b[1]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '清理 Release 清单缓存（推荐）' 'Clean the Release manifest cache (recommended)')"
        printf '  %b[2]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '清空 Hangover 全部下载缓存' 'Clean all Hangover download cache')"
        printf '  %b[0]%b %s\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '返回' 'Back')"
        printf '%s: ' "$(msg '请选择' 'Select')"
        IFS= read -r choice || return
        case "$choice" in
            1) clean_cache_from_menu "manifest" ;;
            2) clean_cache_from_menu "all" ;;
            0|q|Q) return ;;
        esac
    done
}

cleanup_update_files() {
    if [[ -n "$UPDATE_WORK_DIR" && -d "$UPDATE_WORK_DIR" ]]; then
        rm -rf -- "$UPDATE_WORK_DIR"
    fi
    UPDATE_WORK_DIR=""
    UPDATE_UPDATER_PATH=""
}

fetch_tui_release_metadata() {
    local output="$1"
    local -a headers=(
        --header 'Accept: application/vnd.github+json'
        --header 'X-GitHub-Api-Version: 2022-11-28'
        --header 'User-Agent: droidspaces-tui'
    )
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        headers+=(--header "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl --fail --silent --show-error --location \
        --retry 2 --retry-all-errors --connect-timeout 15 --max-time 60 \
        "${headers[@]}" \
        "$TUI_GITHUB_API_URL/repos/$TUI_RELEASE_REPOSITORY/releases/tags/$TUI_RELEASE_TAG" \
        --output "$output"
}

tui_bootstrap_row() {
    local metadata="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -er --arg tag "$TUI_RELEASE_TAG" --arg name "$TUI_BOOTSTRAP_NAME" '
            if .tag_name != $tag then error("Release tag mismatch")
            elif .draft != false then error("Release is a draft")
            else . end
            | [.assets[] | select(.name == $name)]
            | if length != 1 then error("bootstrap asset is missing or duplicated")
              else .[0] end
            | if (.digest | type) != "string" or
                 (.digest | test("^sha256:[0-9A-Fa-f]{64}$") | not)
              then error("bootstrap asset has no valid SHA-256")
              else [.id, (.digest | ascii_downcase | sub("^sha256:"; "")), .size, .updated_at] | @tsv
              end
        ' "$metadata"
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$metadata" "$TUI_RELEASE_TAG" "$TUI_BOOTSTRAP_NAME" <<'PY'
import json
import re
import sys

path, expected_tag, expected_name = sys.argv[1:]
with open(path, "r", encoding="utf-8") as stream:
    release = json.load(stream)
if release.get("tag_name") != expected_tag or release.get("draft") is not False:
    raise SystemExit("Release tag mismatch or draft Release")
assets = [item for item in release.get("assets", []) if item.get("name") == expected_name]
if len(assets) != 1:
    raise SystemExit("bootstrap asset is missing or duplicated")
asset = assets[0]
digest = asset.get("digest")
if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9A-Fa-f]{64}", digest):
    raise SystemExit("bootstrap asset has no valid SHA-256")
print("\t".join((str(asset["id"]), digest[7:].lower(), str(asset["size"]), asset["updated_at"])))
PY
    else
        printf '%s\n' "$(msg '缺少 JSON 解析器：需要 jq 或 python3。' \
            'A JSON parser is required: install jq or python3.')" >&2
        return 1
    fi
}

download_tui_bootstrap() {
    local expected_sha="$1" expected_size="$2" output="$3"
    local source_name base actual_sha actual_size
    local -a sources=()

    case "$DOWNLOAD_SOURCE" in
        auto) sources=(github proxy cnb) ;;
        1) sources=(github) ;;
        2) sources=(proxy) ;;
        3) sources=(cnb) ;;
    esac
    for source_name in "${sources[@]}"; do
        case "$source_name" in
            github) base="$TUI_GITHUB_DOWNLOAD_BASE" ;;
            proxy) base="$TUI_PROXY_DOWNLOAD_BASE" ;;
            cnb) base="$TUI_CNB_DOWNLOAD_BASE" ;;
        esac
        rm -f -- "$output"
        printf '%s\n' "$(msg "正在从 $source_name 获取一次性安装脚本..." \
            "Downloading the one-time installer from $source_name...")"
        if ! curl --fail --silent --show-error --location \
            --retry 2 --retry-all-errors --connect-timeout 15 --max-time 120 \
            --output "$output" "$base/$TUI_RELEASE_TAG/$TUI_BOOTSTRAP_NAME"; then
            continue
        fi
        actual_size="$(stat -c '%s' "$output")"
        actual_sha="$(sha256sum "$output" | awk '{print $1}')"
        if [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]]; then
            chmod 0755 "$output"
            return 0
        fi
        printf '%s\n' "$(msg '一次性安装脚本校验失败。' \
            'The one-time installer failed verification.')" >&2
    done
    return 1
}

prepare_updater() {
    local candidate metadata_before metadata_after row_before row_after
    local asset_id expected_sha expected_size updated_at command_name

    cleanup_update_files
    candidate="$SCRIPT_DIR/install-tui.sh"
    if [[ -x "$candidate" ]]; then
        UPDATE_UPDATER_PATH="$candidate"
        return 0
    fi
    for command_name in awk bash chmod curl mktemp rm sha256sum stat; do
        command -v "$command_name" >/dev/null 2>&1 || {
            printf '%s\n' "$(msg "缺少命令：$command_name" "Required command is missing: $command_name")" >&2
            return 1
        }
    done

    UPDATE_WORK_DIR="$(mktemp -d -t droidspaces-tui-update.XXXXXXXX)" || return 1
    metadata_before="$UPDATE_WORK_DIR/release-before.json"
    metadata_after="$UPDATE_WORK_DIR/release-after.json"
    UPDATE_UPDATER_PATH="$UPDATE_WORK_DIR/$TUI_BOOTSTRAP_NAME"
    fetch_tui_release_metadata "$metadata_before" || { cleanup_update_files; return 1; }
    row_before="$(tui_bootstrap_row "$metadata_before")" || { cleanup_update_files; return 1; }
    IFS=$'\t' read -r asset_id expected_sha expected_size updated_at <<< "$row_before"
    download_tui_bootstrap "$expected_sha" "$expected_size" "$UPDATE_UPDATER_PATH" || {
        cleanup_update_files
        return 1
    }
    bash -n "$UPDATE_UPDATER_PATH" || { cleanup_update_files; return 1; }
    fetch_tui_release_metadata "$metadata_after" || { cleanup_update_files; return 1; }
    row_after="$(tui_bootstrap_row "$metadata_after")" || { cleanup_update_files; return 1; }
    if [[ "$row_before" != "$row_after" ]]; then
        printf '%s\n' "$(msg '下载期间 Release 已变化，请重试。' \
            'The Release changed during download; try again.')" >&2
        cleanup_update_files
        return 1
    fi
    return 0
}

run_update_check() {
    local updater
    local -a source_argument=(--source "$DOWNLOAD_SOURCE")

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '检查更新' 'Check for updates')" "$COLOR_RESET"
    if ! prepare_updater; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '无法取得经过校验的一次性安装脚本。' \
                'Could not obtain a verified one-time installer.')" "$COLOR_RESET"
        pause_menu
        return
    fi
    updater="$UPDATE_UPDATER_PATH"
    if ! "$updater" "${source_argument[@]}" --check --only all; then
        printf '\n%b%s%b\n' "$COLOR_RED" \
            "$(msg '检查更新失败。' 'The update check failed.')" "$COLOR_RESET"
    fi
    cleanup_update_files
    pause_menu
}

run_update() {
    local scope="$1" label="$2" updater status
    local -a source_argument=(--source "$DOWNLOAD_SOURCE")

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$label" "$COLOR_RESET"
    confirm_run "$label" || return
    if ! prepare_updater; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '无法取得经过校验的一次性安装脚本。' \
                'Could not obtain a verified one-time installer.')" "$COLOR_RESET"
        pause_menu
        return
    fi
    updater="$UPDATE_UPDATER_PATH"
    printf '\n'
    if "$updater" "${source_argument[@]}" --only "$scope" --yes; then
        status=0
    else
        status=$?
    fi
    if ((status != 0)); then
        cleanup_update_files
        printf '\n%b%s%b\n' "$COLOR_RED" \
            "$(msg "更新失败，退出码：$status。" "Update failed with exit code $status.")" "$COLOR_RESET"
        pause_menu
        return
    fi

    if [[ "$scope" == tui || "$scope" == all ]]; then
        if [[ -x "$INSTALLED_TUI_PATH" ]]; then
            printf '\n%s\n' "$(msg 'TUI 已更新，正在重新启动。' 'The TUI was updated and will now restart.')"
            cleanup_update_files
            exec "$INSTALLED_TUI_PATH" --source "$DOWNLOAD_SOURCE"
        fi
    fi
    cleanup_update_files
    printf '\n%b%s%b\n' "$COLOR_GREEN" "$(msg '更新完成。' 'Update completed.')" "$COLOR_RESET"
    pause_menu
}

manage_updates() {
    local choice
    while :; do
        clear_screen
        draw_header
        printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '更新管理' 'Update management')" "$COLOR_RESET"
        printf '  %b[1]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '检查更新' 'Check for updates')"
        printf '  %b[2]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '更新 TUI' 'Update the TUI')"
        printf '  %b[3]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '更新受管安装脚本' 'Update managed installer scripts')"
        printf '  %b[4]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '更新全部' 'Update everything')"
        printf '  %b[0]%b %s\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '返回' 'Back')"
        printf '%s: ' "$(msg '请选择' 'Select')"
        IFS= read -r choice || return
        case "$choice" in
            1) run_update_check ;;
            2) run_update tui "$(msg '更新 TUI' 'Update the TUI')" ;;
            3) run_update scripts "$(msg '更新受管安装脚本' 'Update managed installer scripts')" ;;
            4) run_update all "$(msg '更新全部' 'Update everything')" ;;
            0|q|Q) return ;;
        esac
    done
}

show_about() {
    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '关于' 'About')" "$COLOR_RESET"
    printf '%s\n' "$(msg \
        '此工具统一调用仓库内的五个独立安装器；下载、校验、安装和软件包锁定仍由各安装器负责。' \
        'This tool dispatches the five standalone installers. Each installer still owns download, verification, installation, and package locking.')"
    printf '\n%s\n' "$(msg \
        'GNOME Anland 仅支持 Debian 13 和 Ubuntu 26.04；KDE Anland 还支持 Fedora 43/44 与 Arch Linux。' \
        'GNOME Anland supports Debian 13 and Ubuntu 26.04. KDE Anland also supports Fedora 43/44 and Arch Linux.')"
    pause_menu
}

main_menu() {
    local choice
    while :; do
        clear_screen
        draw_header
        printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '组件安装' 'Component installers')" "$COLOR_RESET"
        print_component "1" "Mesa + MediaCodec VA-API" "mesa"
        print_component "2" "Hangover Wine" "hangover"
        print_component "3" "$(msg 'Wine 字体' 'Wine fonts')" "fonts"
        print_component "4" "Anland KDE (KWin/Xwayland)" "kde"
        print_component "5" "Anland GNOME (Mutter/Xwayland)" "gnome"
        printf '\n'
        printf '  %b[S]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '切换下载源' 'Change download source')"
        printf '  %b[C]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '清理下载缓存' 'Clean download cache')"
        printf '  %b[U]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '检查与安装更新' 'Check for and install updates')"
        printf '  %b[A]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '关于与支持范围' 'About and support')"
        printf '  %b[Q]%b %s\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '退出' 'Quit')"
        printf '%s: ' "$(msg '请选择' 'Select')"
        IFS= read -r choice || return
        case "${choice,,}" in
            1) run_component "mesa" "Mesa + MediaCodec VA-API" ;;
            2) run_component "hangover" "Hangover Wine" ;;
            3) run_component "fonts" "$(msg 'Wine 字体' 'Wine fonts')" ;;
            4) run_component "kde" "Anland KDE" ;;
            5) run_component "gnome" "Anland GNOME" ;;
            s) select_download_source ;;
            c) manage_cache ;;
            u) manage_updates ;;
            a) show_about ;;
            q|0) return ;;
        esac
    done
}

handle_signal() {
    cleanup_update_files
    printf '\n'
    exit 130
}

main() {
    detect_language
    parse_arguments "$@"
    validate_cache_action
    init_colors
    detect_system
    if [[ -n "$CACHE_ACTION" ]]; then
        clean_cache_as_root "$CACHE_ACTION"
        exit 0
    fi
    [[ -t 0 && -t 1 ]] || die \
        "需要交互式终端，请通过 adb shell -t 或普通终端运行。" \
        "An interactive terminal is required; use adb shell -t or a regular terminal."
    trap handle_signal HUP INT TERM
    trap cleanup_update_files EXIT
    main_menu
    clear_screen
    printf '%s\n' "$(msg '已退出 Droidspaces 工具箱。' 'Exited Droidspaces Toolkit.')"
}

main "$@"
