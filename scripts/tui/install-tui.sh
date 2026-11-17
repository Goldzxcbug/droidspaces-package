#!/usr/bin/env bash
set -euo pipefail

# BEGIN DROIDSPACES SHARED operations
# shellcheck shell=bash
# Shared installer transaction support. Embedded into standalone release scripts.
# Keep this file independent of the installer's language and package manager.
DS_OP_ACTIVE=false
DS_OP_COMPONENT=''
DS_OP_PHASE=''
DS_OP_DIR=''
DS_OP_TRANSACTION=''
DS_OP_LOG=''
DS_OP_ID=''
DS_OP_PREVIOUS_EXIT=''
DS_OP_PREVIOUS_INT=''
DS_OP_PREVIOUS_TERM=''
DS_OP_PREVIOUS_HUP=''
DS_OP_CONFIG_RECOVERED=false
DS_PREFLIGHT_ACTIVE=false

ds_operation_preflight() {
    local component="$1" directory path
    if ((EUID == 0)); then ds_operation_begin "$component"; return; fi
    [[ "${DS_PREFLIGHT_ACTIVE:-false}" == false ]] || return 0
    [[ "$component" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    directory="${DROIDSPACES_USER_LOG_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/droidspaces-tui/logs}"
    ds_operation_safe_path "$directory" || return 1
    path="$directory"
    while [[ "$path" != / ]]; do
        [[ ! -L "$path" ]] || return 1
        path="${path%/*}"; [[ -n "$path" ]] || path=/
    done
    mkdir -p -m 0700 -- "$directory" || return 1
    [[ "$(stat -c %u "$directory")" == "$EUID" ]] || return 1
    chmod 0700 "$directory" || return 1
    DS_PREFLIGHT_LOG="$(mktemp "$directory/$component-preflight.XXXXXXXX.log")" || return 1
    DS_PREFLIGHT_PREVIOUS_EXIT="$(trap -p EXIT)"
    DS_PREFLIGHT_PREVIOUS_INT="$(trap -p INT)"
    DS_PREFLIGHT_PREVIOUS_TERM="$(trap -p TERM)"
    DS_PREFLIGHT_PREVIOUS_HUP="$(trap -p HUP)"
    exec {DS_PREFLIGHT_STDOUT}>&1 {DS_PREFLIGHT_STDERR}>&2
    exec > >(exec tee -a -- "$DS_PREFLIGHT_LOG") 2>&1
    DS_PREFLIGHT_LOG_PID=$!
    DS_PREFLIGHT_ACTIVE=true
    trap 'ds_operation_preflight_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    printf 'Droidspaces pre-download log / 预下载日志: %s\n' "$DS_PREFLIGHT_LOG"
}

ds_operation_preflight_finish() {
    local status="$1"
    [[ "${DS_PREFLIGHT_ACTIVE:-false}" == true ]] || return "$status"
    printf 'Pre-download/privilege handoff finished (exit=%s). Log: %s\n' "$status" "$DS_PREFLIGHT_LOG"
    DS_PREFLIGHT_ACTIVE=false
    exec 1>&"$DS_PREFLIGHT_STDOUT" 2>&"$DS_PREFLIGHT_STDERR"
    exec {DS_PREFLIGHT_STDOUT}>&- {DS_PREFLIGHT_STDERR}>&-
    ds_operation_drain_logger "$DS_PREFLIGHT_LOG_PID"
    trap - EXIT INT TERM HUP
    [[ -z "$DS_PREFLIGHT_PREVIOUS_EXIT" ]] || eval "$DS_PREFLIGHT_PREVIOUS_EXIT"
    [[ -z "$DS_PREFLIGHT_PREVIOUS_INT" ]] || eval "$DS_PREFLIGHT_PREVIOUS_INT"
    [[ -z "$DS_PREFLIGHT_PREVIOUS_TERM" ]] || eval "$DS_PREFLIGHT_PREVIOUS_TERM"
    [[ -z "$DS_PREFLIGHT_PREVIOUS_HUP" ]] || eval "$DS_PREFLIGHT_PREVIOUS_HUP"
    return "$status"
}

ds_operation_preflight_exit() {
    local status="$1"
    trap - EXIT INT TERM HUP
    if declare -F cleanup >/dev/null 2>&1; then cleanup || status=1; fi
    ds_operation_preflight_finish "$status" || status=$?
    trap - EXIT
    exit "$status"
}

ds_operation_safe_path() {
    [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *$'\t'* &&
       "$1" != */../* && "$1" != */.. && "$1" != */./* ]]
}

ds_operation_drain_logger() {
    local logger_pid="$1" attempt
    # A service started by a package hook can inherit the logging pipe. Do not
    # let that unrelated service hold up completion or keep the modification lock.
    for ((attempt=0; attempt<40; attempt++)); do
        if ! kill -0 "$logger_pid" 2>/dev/null; then
            wait "$logger_pid" 2>/dev/null || true
            return 0
        fi
        sleep 0.05
    done
    kill -TERM "$logger_pid" 2>/dev/null || true
    sleep 0.05
    kill -KILL "$logger_pid" 2>/dev/null || true
    # Only wait after confirming termination: even a logger blocked by a sick
    # filesystem must not turn installer cleanup into an unbounded wait.
    if ! kill -0 "$logger_pid" 2>/dev/null; then wait "$logger_pid" 2>/dev/null || true; fi
}

ds_operation_write_state() {
    local status="$1" code="${2:-0}" temporary
    temporary="$DS_OP_DIR/.active.$BASHPID"
    {
        printf 'format=1\noperation=%s\ncomponent=%s\nphase=%s\nstatus=%s\nexit_code=%s\n' \
            "$DS_OP_ID" "$DS_OP_COMPONENT" "$DS_OP_PHASE" "$status" "$code"
        printf 'pid=%s\nlog=%s\ntransaction=%s\nupdated_at=%s\n' \
            "$$" "$DS_OP_LOG" "$DS_OP_TRANSACTION" "$(date -u +%FT%TZ)"
        printf 'config_recovered=%s\n' "$DS_OP_CONFIG_RECOVERED"
    } > "$temporary" && chmod 0600 "$temporary" && mv -f -- "$temporary" "$DS_OP_DIR/active"
}

ds_operation_phase() {
    if [[ "${DS_OP_ACTIVE:-false}" != true ]]; then
        [[ "${DS_PREFLIGHT_ACTIVE:-false}" != true ]] || printf '[droidspaces preflight] phase=%s\n' "$1"
        return 0
    fi
    [[ "$1" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
    DS_OP_PHASE="$1"
    ds_operation_write_state running
    printf '[droidspaces operation] %s phase=%s\n' "$DS_OP_COMPONENT" "$DS_OP_PHASE"
}

ds_operation_backup() {
    local target="$1" number snapshot present
    [[ "${DS_OP_ACTIVE:-false}" == true ]] || return 0
    ds_operation_safe_path "$target" || return 1
    # Never dereference a user-supplied target when saving/restoring configuration.
    [[ ! -d "$target" || -L "$target" ]] || return 1
    if [[ -f "$DS_OP_TRANSACTION/configs" ]] &&
        awk -F '\t' -v target="$target" '$3 == target { found=1 } END { exit !found }' \
            "$DS_OP_TRANSACTION/configs"; then
        return 0
    fi
    number="$(wc -l < "$DS_OP_TRANSACTION/configs")"
    snapshot="$DS_OP_TRANSACTION/config.$number"
    present=missing
    if [[ -e "$target" || -L "$target" ]]; then
        cp -a -- "$target" "$snapshot" || return 1
        present=present
    fi
    printf '%s\t%s\t%s\n' "$present" "$snapshot" "$target" >> "$DS_OP_TRANSACTION/configs"
}

ds_operation_snapshot_installer_config() {
    local path
    for path in "${DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}" \
        /etc/dnf/dnf.conf /etc/pacman.conf /etc/apt/preferences.d/hold-anland-package \
        "${APT_HOLD_STATE:-}" "${PACMAN_PACKAGE_STATE:-}" \
        "${COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}/$DS_OP_COMPONENT.version" \
        "${COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}/$DS_OP_COMPONENT.packages.tsv" \
        "${COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}/$DS_OP_COMPONENT.files.sha256"; do
        [[ -n "$path" ]] || continue
        ds_operation_backup "$path"
    done
}

ds_operation_record_packages() {
    local component="$1" state_dir="$2" directory file package output version temporary digest unexpected
    local -a candidates=()
    local -A names=()
    ds_operation_safe_path "$state_dir" || return 1
    mkdir -p -- "$state_dir" || return 1
    if [[ "$component" == fonts ]]; then
        [[ -n "${FONT_TARGET:-}" && -d "$FONT_TARGET" && ! -L "$FONT_TARGET" ]] || return 1
        unexpected="$(find "$FONT_TARGET" -mindepth 1 ! -type f ! -type d -print -quit)" || return 1
        [[ -z "$unexpected" ]] || return 1
        digest="$(find "$FONT_TARGET" -type f -print0 | LC_ALL=C sort -z | \
            xargs -0 -r sha256sum -b -z | sha256sum)" || return 1
        digest="${digest%% *}"
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        temporary="$(mktemp "$state_dir/.fonts.files.XXXXXXXX")" || return 1
        printf '%s\n' "$digest" > "$temporary" && chmod 0644 "$temporary" && \
            mv -f -- "$temporary" "$state_dir/fonts.files.sha256"
        return
    fi
    temporary="$(mktemp "$state_dir/.$component.packages.XXXXXXXX")" || return 1
    directory="${PACKAGE_DIR:-${WORK_DIR:-}}"
    if [[ -n "$directory" && -d "$directory" ]]; then
        while IFS= read -r -d '' file; do
            package=''
            case "$file" in
                *.deb) package="$(dpkg-deb -f "$file" Package 2>/dev/null)" || true ;;
                *.rpm) package="$(rpm -qp --queryformat '%{NAME}' "$file" 2>/dev/null)" || true ;;
                *.pkg.tar.*)
                    output="$(pacman -Qp -- "$file" 2>/dev/null)" || true
                    package="${output%% *}"
                    ;;
            esac
            [[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9.+:_-]*$ ]] && names["$package"]=1
        done < <(find "$directory" -maxdepth 4 -type f \
            \( -name '*.deb' -o -name '*.rpm' -o -name '*.pkg.tar.*' \) -print0)
    fi
    # Also cover a single-package session and old archives with no unpacked metadata.
    case "$component" in
        mesa) candidates=(mesa mesa-vulkan-drivers libglx-mesa0 libegl-mesa0 mesa-dri-drivers) ;;
        kde) candidates=(kwin kwin-wayland kwin-x11 kwin-common xwayland xorg-x11-server-Xwayland) ;;
        gnome) candidates=(mutter mutter-common xwayland xorg-x11-server-Xwayland) ;;
        niri) candidates=(niri-anland xwayland-satellite xwayland xorg-x11-server-Xwayland) ;;
        hyprland) candidates=(hyprland-anland hyprland xwayland xorg-x11-server-Xwayland) ;;
        mango) candidates=(mango-anland xwayland xorg-x11-server-Xwayland) ;;
        denial) candidates=(denial xwayland xorg-x11-server-Xwayland) ;;
        anland-next) candidates=(anland-session) ;;
        hangover) candidates=(hangover-wine) ;;
    esac
    for package in "${candidates[@]}"; do names["$package"]=1; done
    for package in "${!names[@]}"; do
        version=''
        case "${PACKAGE_TYPE:-${PACKAGE_MANAGER:-${TARGET:-}}}" in
            deb|apt|debian*|ubuntu*)
                output="$(dpkg-query -W -f='${db:Status-Abbrev}\t${Version}\n' "$package" 2>/dev/null)" || continue
                [[ "$output" == ?i$' '*$'\t'* ]] || continue
                version="${output#*$'\t'}"
                ;;
            rpm|dnf|fedora*) version="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$package" 2>/dev/null)" || continue ;;
            pkg.tar.*|pacman|arch*)
                output="$(pacman -Q -- "$package" 2>/dev/null)" || continue
                version="${output#* }"
                ;;
        esac
        [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]*$ ]] || continue
        printf '%s\t%s\n' "$package" "$version" >> "$temporary"
    done
    if [[ -s "$temporary" ]]; then
        LC_ALL=C sort -o "$temporary" "$temporary" && chmod 0644 "$temporary" && \
            mv -f -- "$temporary" "$state_dir/$component.packages.tsv"
    else
        rm -f -- "$temporary" "$state_dir/$component.packages.tsv"
    fi
}

ds_operation_restore_configs() {
    local transaction="$1" present snapshot target temporary failed=0
    [[ -f "$transaction/configs" && ! -L "$transaction/configs" ]] || return 0
    while IFS=$'\t' read -r present snapshot target; do
        [[ -n "$target" ]] || continue
        if ! ds_operation_safe_path "$target" || [[ "$snapshot" != "$transaction"/config.* ]]; then
            failed=1; continue
        fi
        if [[ "$present" == present && ( -f "$snapshot" || -L "$snapshot" ) ]]; then
            temporary="${target}.droidspaces-restore-$BASHPID"
            if ! cp -a -- "$snapshot" "$temporary" || ! mv -Tf -- "$temporary" "$target"; then
                failed=1
            fi
        elif [[ "$present" == missing ]]; then
            rm -f -- "$target" || failed=1
        else
            failed=1
        fi
    done < "$transaction/configs"
    return "$failed"
}

ds_operation_recover_previous() {
    local previous_status previous_transaction previous_phase already_recovered
    [[ -f "$DS_OP_DIR/active" && ! -L "$DS_OP_DIR/active" ]] || return 0
    previous_status="$(awk -F= '$1=="status" {print $2}' "$DS_OP_DIR/active")"
    case "$previous_status" in running|incomplete|recovery_failed) ;; *) return 0 ;; esac
    previous_transaction="$(awk -F= '$1=="transaction" {sub(/^[^=]*=/, ""); print}' "$DS_OP_DIR/active")"
    previous_phase="$(awk -F= '$1=="phase" {print $2}' "$DS_OP_DIR/active")"
    already_recovered="$(awk -F= '$1=="config_recovered" {print $2}' "$DS_OP_DIR/active")"
    [[ "$previous_transaction" == "$DS_OP_DIR"/transactions/* && -d "$previous_transaction" &&
       ! -L "$previous_transaction" ]] || {
        printf 'Unfinished Droidspaces operation has an invalid recovery record: %s\n' "$DS_OP_DIR/active" >&2
        return 1
    }
    if [[ "$already_recovered" != true ]]; then
        printf 'Recovering configuration from unfinished operation (phase=%s): %s\n' \
            "$previous_phase" "$previous_transaction" >&2
        ds_operation_restore_configs "$previous_transaction" || return 1
    else
        printf 'Previous operation was interrupted at phase=%s; its configuration was already recovered.\n' "$previous_phase" >&2
    fi
    cp -a -- "$DS_OP_DIR/active" "$previous_transaction/interrupted-state" || return 1
    printf 'Configuration recovered. Package changes may already have completed; re-run the installer to verify/repair them.\n' >&2
}

ds_operation_begin() {
    local component="$1" path old_umask
    [[ "${DS_OP_ACTIVE:-false}" == false ]] || return 0
    [[ "$component" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    command -v flock >/dev/null 2>&1 || {
        printf 'Droidspaces: missing flock (install util-linux). / 缺少 flock，请安装 util-linux。\n' >&2
        return 1
    }
    DS_OP_DIR="${DROIDSPACES_OPERATION_DIR:-/var/lib/droidspaces-tui/operations}"
    ds_operation_safe_path "$DS_OP_DIR" || return 1
    # Reject symlink components before creating privileged persistent files.
    path="$DS_OP_DIR"
    while [[ "$path" != / ]]; do
        [[ ! -L "$path" ]] || { printf 'Unsafe operation directory: %s\n' "$path" >&2; return 1; }
        path="${path%/*}"; [[ -n "$path" ]] || path=/
    done
    old_umask="$(umask)"; umask 077
    mkdir -p -- "$DS_OP_DIR/transactions" || { umask "$old_umask"; return 1; }
    umask "$old_umask"
    [[ "$(stat -c %u "$DS_OP_DIR")" == "$EUID" && ! -L "$DS_OP_DIR/lock" &&
       ! -L "$DS_OP_DIR/transactions" && ! -L "$DS_OP_DIR/active" ]] || return 1
    chmod 0700 "$DS_OP_DIR" "$DS_OP_DIR/transactions" || return 1
    exec {DS_OP_LOCK_FD}>"$DS_OP_DIR/lock" || return 1
    if ! flock -n "$DS_OP_LOCK_FD"; then
        printf 'Another Droidspaces modification is running. / 另一个 Droidspaces 修改操作正在运行。\n' >&2
        exec {DS_OP_LOCK_FD}>&-
        return 75
    fi
    ds_operation_recover_previous || { exec {DS_OP_LOCK_FD}>&-; return 1; }
    DS_OP_COMPONENT="$component"
    DS_OP_CONFIG_RECOVERED=false
    DS_OP_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
    DS_OP_TRANSACTION="$DS_OP_DIR/transactions/$DS_OP_ID"
    mkdir -m 0700 -- "$DS_OP_TRANSACTION" || return 1
    : > "$DS_OP_TRANSACTION/configs"
    DS_OP_LOG="$DS_OP_TRANSACTION/operation.log"
    DS_OP_PREVIOUS_EXIT="$(trap -p EXIT)"
    DS_OP_PREVIOUS_INT="$(trap -p INT)"
    DS_OP_PREVIOUS_TERM="$(trap -p TERM)"
    DS_OP_PREVIOUS_HUP="$(trap -p HUP)"
    exec {DS_OP_STDOUT}>&1 {DS_OP_STDERR}>&2
    exec > >(exec {DS_OP_LOCK_FD}>&-; exec tee -a -- "$DS_OP_LOG") 2>&1
    DS_OP_LOG_PID=$!
    DS_OP_ACTIVE=true
    trap 'ds_operation_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    printf 'Droidspaces operation log / 操作日志: %s\n' "$DS_OP_LOG"
    ds_operation_phase prepare
}

ds_operation_finish() {
    local status="${1:-0}" result=complete
    [[ "${DS_OP_ACTIVE:-false}" == true ]] || return "$status"
    if ((status != 0)); then
        result=incomplete
        if ! ds_operation_restore_configs "$DS_OP_TRANSACTION"; then
            result=recovery_failed
        else
            DS_OP_CONFIG_RECOVERED=true
        fi
        printf 'Operation failed at phase=%s (exit=%s). Log: %s\n' "$DS_OP_PHASE" "$status" "$DS_OP_LOG" >&2
        printf 'Configuration backups: %s. Package changes may require re-running this installer.\n' "$DS_OP_TRANSACTION" >&2
    else
        DS_OP_PHASE=complete
        printf 'Operation completed. Log: %s\n' "$DS_OP_LOG"
    fi
    ds_operation_write_state "$result" "$status" || status=1
    DS_OP_ACTIVE=false
    exec 1>&"$DS_OP_STDOUT" 2>&"$DS_OP_STDERR"
    exec {DS_OP_STDOUT}>&- {DS_OP_STDERR}>&-
    flock -u "$DS_OP_LOCK_FD" || true
    exec {DS_OP_LOCK_FD}>&-
    ds_operation_drain_logger "$DS_OP_LOG_PID"
    trap - EXIT INT TERM HUP
    [[ -z "$DS_OP_PREVIOUS_EXIT" ]] || eval "$DS_OP_PREVIOUS_EXIT"
    [[ -z "$DS_OP_PREVIOUS_INT" ]] || eval "$DS_OP_PREVIOUS_INT"
    [[ -z "$DS_OP_PREVIOUS_TERM" ]] || eval "$DS_OP_PREVIOUS_TERM"
    [[ -z "$DS_OP_PREVIOUS_HUP" ]] || eval "$DS_OP_PREVIOUS_HUP"
    return "$status"
}

ds_operation_exit() {
    local status="$1"
    trap - EXIT INT TERM HUP
    if declare -F ds_installer_rollback >/dev/null 2>&1; then
        if ! ds_installer_rollback "$status"; then status=1; fi
    fi
    # Existing per-installer cleanup includes preserved media/fonts recovery.
    if declare -F cleanup >/dev/null 2>&1; then cleanup || status=1; fi
    ds_operation_finish "$status" || status=$?
    trap - EXIT
    exit "$status"
}
# END DROIDSPACES SHARED operations

readonly RELEASE_REPOSITORY="${DROIDSPACES_TUI_REPOSITORY:-Goldzxcbug/droidspaces-package}"
readonly RELEASE_TAG="Gold-bug-tui"
readonly MANIFEST_NAME="Gold-bug-tui-manifest"
readonly BUNDLE_NAME="Gold-bug-tui.tar.gz"
readonly FILES_NAME="Gold-bug-tui-files"
readonly MANIFEST_LIMIT=1048576
readonly SCRIPT_LIMIT=8388608
readonly BUNDLE_LIMIT=33554432
readonly EXPANDED_LIMIT=67108864
readonly MEMBER_LIMIT=128
BUNDLE_SHA=''
BUNDLE_SIZE=''
BOOTSTRAP_SHA=''
BOOTSTRAP_SIZE=''
PARSED_REVISION=''
declare -a MANIFEST_ROWS=()
readonly GITHUB_API_URL="${DROIDSPACES_TUI_API_URL:-https://api.github.com}"
readonly GITHUB_DOWNLOAD_BASE="${DROIDSPACES_TUI_GITHUB_BASE:-https://github.com/$RELEASE_REPOSITORY/releases/download}"
readonly GITHUB_PROXY_BASE="${DROIDSPACES_TUI_PROXY_BASE:-https://gh-proxy.com/https://github.com/$RELEASE_REPOSITORY/releases/download}"
readonly CNB_DOWNLOAD_BASE="${DROIDSPACES_TUI_CNB_BASE:-https://cnb.cool/$RELEASE_REPOSITORY/-/releases/download}"
readonly TUI_TARGET="/usr/local/bin/droidspaces-tui"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]:-}")"
DOWNLOAD_SOURCE="auto"
UPDATE_SCOPE="all"
CHECK_ONLY=false
ASSUME_YES=false
WORK_DIR=""
API_BEFORE=""
API_AFTER=""
MANIFEST_PATH=""
METADATA_SOURCE=""
MANIFEST_REVISION=""
CHANGED_COUNT=0

declare -a ORIGINAL_ARGUMENTS=("$@")
declare -a ASSET_NAMES=()
declare -a ASSET_SHA256=()
declare -a ASSET_SIZES=()
declare -a ASSET_ROLES=()
declare -a ASSET_TARGETS=()
declare -a SELECTED_INDEXES=()

die() {
    printf 'install-tui: %s\n' "$1" >&2
    exit 1
}

log() {
    printf '[droidspaces-tui] %s\n' "$1"
}

usage() {
    cat <<'EOF'
用法: install-tui.sh [选项]

安装或更新 Droidspaces TUI 及其管理的安装脚本。

  --source auto|github|proxy|cnb  选择附件下载源（默认：auto）
  --only tui|scripts|all         只更新 TUI、受管脚本或全部（默认：all）
  --check                        只检查，不写入系统
                                 退出码：0=已是最新，2=有更新，1=检查失败
  -y, --yes                      不询问，直接安装
  -h, --help                     显示帮助

固定 Release：
  https://github.com/Goldzxcbug/droidspaces-package/releases/tag/Gold-bug-tui
EOF
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --source)
                (($# >= 2)) || die '--source 缺少参数。'
                DOWNLOAD_SOURCE="${2,,}"
                shift 2
                ;;
            --source=*)
                DOWNLOAD_SOURCE="${1#*=}"
                DOWNLOAD_SOURCE="${DOWNLOAD_SOURCE,,}"
                shift
                ;;
            --only)
                (($# >= 2)) || die '--only 缺少参数。'
                UPDATE_SCOPE="${2,,}"
                shift 2
                ;;
            --only=*)
                UPDATE_SCOPE="${1#*=}"
                UPDATE_SCOPE="${UPDATE_SCOPE,,}"
                shift
                ;;
            --check)
                CHECK_ONLY=true
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *) die "不支持的参数：$1" ;;
        esac
    done

    case "$DOWNLOAD_SOURCE" in
        1) DOWNLOAD_SOURCE=github ;;
        2) DOWNLOAD_SOURCE=proxy ;;
        3) DOWNLOAD_SOURCE=cnb ;;
    esac
    case "$DOWNLOAD_SOURCE" in
        auto|github|proxy|cnb) ;;
        *) die "不支持的下载源：$DOWNLOAD_SOURCE" ;;
    esac
    case "$UPDATE_SCOPE" in
        tui|scripts|all) ;;
        *) die "不支持的更新范围：$UPDATE_SCOPE" ;;
    esac
}

require_commands() {
    local command_name
    for command_name in awk bash chmod cp curl date dirname find gzip head install ln mkdir mktemp mv readlink rm rmdir sha256sum stat tar tr wc; do
        command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
    done
}

json_parser_available() {
    command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1
}

ensure_root() {
    ((EUID == 0)) && return
    command -v sudo >/dev/null 2>&1 || die '安装需要 root 权限，且系统未安装 sudo。'
    exec sudo --preserve-env=LANG,LC_ALL,LC_MESSAGES -- bash "$SCRIPT_PATH" "${ORIGINAL_ARGUMENTS[@]}"
}

require_script_file() {
    if [[ -z "${BASH_SOURCE[0]:-}" || -d "$SCRIPT_PATH" ]]; then
        die "无法通过管道运行本脚本；请先下载脚本再运行，例如 curl -fsSLO $GITHUB_DOWNLOAD_BASE/$RELEASE_TAG/install-tui.sh && sudo bash install-tui.sh。Cannot run through a pipe; download the script first, e.g. curl -fsSLO $GITHUB_DOWNLOAD_BASE/$RELEASE_TAG/install-tui.sh && sudo bash install-tui.sh."
    fi
}

fetch_release_metadata() {
    local output="$1"
    local -a headers=(
        --header 'Accept: application/vnd.github+json'
        --header 'X-GitHub-Api-Version: 2022-11-28'
        --header 'User-Agent: droidspaces-tui-installer'
    )
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        headers+=(--header "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl --fail --silent --show-error --location \
        --retry 2 --retry-all-errors --connect-timeout 15 --max-time 60 \
        "${headers[@]}" \
        "$GITHUB_API_URL/repos/$RELEASE_REPOSITORY/releases/tags/$RELEASE_TAG" \
        --output "$output"
}

release_asset_row() {
    local metadata="$1" asset_name="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -er --arg tag "$RELEASE_TAG" --arg name "$asset_name" '
            if .tag_name != $tag then error("Release tag 不匹配")
            elif .draft != false then error("Release 仍是草稿")
            else . end
            | [.assets[] | select(.name == $name)]
            | if length != 1 then error("附件缺失或不唯一: " + $name)
              else .[0] end
            | if (.digest | type) != "string" or
                 (.digest | test("^sha256:[0-9A-Fa-f]{64}$") | not)
              then error("附件缺少有效的 SHA-256: " + $name)
              else [.id, (.digest | ascii_downcase | sub("^sha256:"; "")), .size, .updated_at] | @tsv
              end
        ' "$metadata"
    else
        python3 - "$metadata" "$RELEASE_TAG" "$asset_name" <<'PY'
import json
import re
import sys

path, expected_tag, expected_name = sys.argv[1:]
with open(path, "r", encoding="utf-8") as stream:
    release = json.load(stream)
if release.get("tag_name") != expected_tag or release.get("draft") is not False:
    raise SystemExit("Release tag 不匹配或仍是草稿")
assets = [item for item in release.get("assets", []) if item.get("name") == expected_name]
if len(assets) != 1:
    raise SystemExit("附件缺失或不唯一: " + expected_name)
asset = assets[0]
digest = asset.get("digest")
if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9A-Fa-f]{64}", digest):
    raise SystemExit("附件缺少有效的 SHA-256: " + expected_name)
print("\t".join((str(asset["id"]), digest[7:].lower(), str(asset["size"]), asset["updated_at"])))
PY
    fi
}

download_cnb_manifest_to() {
    local output="$1" manifest_size

    log "从 CNB 下载 $MANIFEST_NAME"
    download_from_url "$CNB_DOWNLOAD_BASE/$RELEASE_TAG/$MANIFEST_NAME" "$output" "$MANIFEST_LIMIT" || return 1
    manifest_size="$(stat -c '%s' "$output")" || return 1
    [[ "$manifest_size" =~ ^[0-9]+$ && "$manifest_size" -gt 0 && \
       "$manifest_size" -le $((1024 * 1024)) ]]
}

download_cnb_manifest() {
    download_cnb_manifest_to "$MANIFEST_PATH"
}

safe_target_path() {
    local target="$1" base
    case "${target%/*}" in
        /usr/local/bin|/usr/local/sbin|/usr/local/lib/droidspaces/tui) ;;
        *) return 1 ;;
    esac
    base="${target##*/}"
    [[ -n "$base" && "$base" != . && "$base" != .. && "$target" != *//* ]]
}

download_from_url() {
    local url="$1" output="$2" limit="${3:-$BUNDLE_LIMIT}"
    curl --fail --silent --show-error --location \
        --retry 2 --retry-all-errors --connect-timeout 15 --max-time 120 \
        --max-filesize "$limit" --proto '=http,https' --proto-redir '=http,https' \
        --output "$output" "$url"
}

download_asset() {
    ds_operation_phase download
    local asset_name="$1" expected_sha="$2" expected_size="$3" output="$4"
    local source_name base url actual_sha actual_size
    local -a sources=()

    case "$DOWNLOAD_SOURCE" in
        auto) sources=(github proxy cnb) ;;
        github|1) sources=(github) ;;
        proxy|2) sources=(proxy) ;;
        cnb|3) sources=(cnb) ;;
    esac

    for source_name in "${sources[@]}"; do
        case "$source_name" in
            github) base="$GITHUB_DOWNLOAD_BASE" ;;
            proxy) base="$GITHUB_PROXY_BASE" ;;
            cnb) base="$CNB_DOWNLOAD_BASE" ;;
        esac
        url="$base/$RELEASE_TAG/$asset_name"
        rm -f -- "$output"
        log "从 $source_name 下载 $asset_name"
        if ! download_from_url "$url" "$output" "$expected_size"; then
            continue
        fi
        actual_size="$(stat -c '%s' "$output")"
        actual_sha="$(sha256sum "$output" | awk '{print $1}')"
        if [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]]; then
            return 0
        fi
        printf '附件校验失败：%s（来源：%s）\n' "$asset_name" "$source_name" >&2
    done
    return 1
}

# Inspect the uncompressed tar stream before extracting any member. GNU tar's
# escaped listing makes whitespace/control characters unambiguous; the allowed
# path grammar below excludes every escape and all links or special files.
validate_bundle_archive() {
    local archive="$1" listing="$2" mode owner size date time name extra relative
    local count=0 total=0 limit
    local -A seen=()
    limit=$((EXPANDED_LIMIT + MANIFEST_LIMIT))
    if ! (set -o pipefail; GZIP= gzip -cd -- "$archive" | head -c "$limit" | \
        LC_ALL=C TZ=UTC TAR_OPTIONS= tar --list --verbose --numeric-owner --full-time \
            --quoting-style=escape --absolute-names --file - | head -n "$((MEMBER_LIMIT + 1))") > "$listing"; then
        die 'invalid or oversized TUI archive'
    fi
    while read -r mode owner size date time name extra; do
        [[ -n "$mode" && -z "${extra:-}" && "$size" =~ ^[0-9]{1,10}$ ]] || die 'invalid TUI archive header'
        count=$((count + 1))
        ((count <= MEMBER_LIMIT)) || die 'TUI archive has too many members'
        [[ -z "${seen[$name]+present}" ]] || die "duplicate TUI archive member: $name"
        seen["$name"]=1
        case "$name" in
            tui/|tui/lib/)
                [[ "$mode" == d* && "$size" == 0 ]] || die "invalid TUI archive directory: $name"
                ;;
            tui/*)
                [[ "$mode" == -* ]] || die "TUI archive member is not a regular file: $name"
                relative="${name#tui/}"
                if [[ "$relative" != "$FILES_NAME" ]]; then
                    asset_metadata "$relative" >/dev/null || die "unexpected TUI archive member: $name"
                fi
                ((10#$size > 0 && 10#$size <= SCRIPT_LIMIT)) || die "invalid TUI archive member size: $name"
                if [[ "$relative" == "$FILES_NAME" ]]; then
                    ((10#$size <= MANIFEST_LIMIT)) || die 'TUI file manifest is too large'
                fi
                total=$((total + 10#$size))
                ((total <= EXPANDED_LIMIT)) || die 'TUI archive exceeds the expanded size limit'
                ;;
            *) die "unexpected TUI archive member: $name" ;;
        esac
    done < "$listing"
    [[ -n "${seen[tui/$FILES_NAME]+present}" ]] || die 'TUI archive has no file manifest'
}

extract_bundle_archive() {
    local archive="$1" destination="$2"
    mkdir -m 0700 -- "$destination"
    TAR_OPTIONS= GZIP= tar --extract --gzip --file "$archive" --directory "$destination" \
        --no-same-owner --no-same-permissions --delay-directory-restore || die 'unable to extract TUI archive'
    [[ -d "$destination/tui" && ! -L "$destination/tui" ]] || die 'TUI archive root is missing'
}

asset_metadata() {
    local name="$1" base
    case "$name" in
        droidspaces-tui.sh) printf 'tui\t/usr/local/bin/droidspaces-tui' ;;
        droidspaces-gpu.sh) printf 'tui\t/usr/local/bin/droidspaces-gpu' ;;
        droidspaces-video.sh) printf 'tui\t/usr/local/bin/droidspaces-video.sh' ;;
        install-tui.sh) printf 'bootstrap\t-' ;;
        install-anland-kde.sh|install-anland-gnome.sh|install-anland-next.sh|install-anland-niri.sh|install-anland-hyprland.sh|install-anland-mango.sh|install-anland-denial.sh|install-mesa.sh|install-hangover-wine.sh|install-winefonts.sh)
            printf 'installer\t/usr/local/sbin/%s' "${name%.sh}"
            ;;
        lib/*.sh)
            base="${name#lib/}"
            [[ "$base" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*\.sh$ ]] || return 1
            printf 'library\t/usr/local/lib/droidspaces/tui/%s' "$base"
            ;;
        *) return 1 ;;
    esac
}

read_manifest_records() {
    local path="$1" line key value bytes
    local header=false
    local -A fields=()
    MANIFEST_ROWS=()
    PARSED_REVISION=''
    [[ -f "$path" && ! -L "$path" ]] || die 'TUI 清单缺失或不是普通文件。'
    bytes="$(stat -c '%s' "$path")"
    ((bytes > 0 && bytes <= MANIFEST_LIMIT)) || die 'TUI 清单为空或超出大小限制。'
    [[ "$(LC_ALL=C tr -d '\11\12\40-\176' < "$path" | wc -c)" -eq 0 ]] || die 'TUI 清单包含无效字符。'
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$header" == false ]]; then
            if [[ "$line" == $'sha256\tsize\trole\ttarget\tasset' ]]; then
                header=true
                continue
            fi
            [[ "$line" == *=* ]] || die 'TUI 清单元数据无效。'
            key="${line%%=*}"; value="${line#*=}"
            case "$key" in format|release_tag|revision|generated_at) ;; *) die "未知的 TUI 清单元数据：$key" ;; esac
            [[ -z "${fields[$key]+present}" ]] || die "重复的 TUI 清单元数据：$key"
            fields["$key"]="$value"
        else
            MANIFEST_ROWS+=("$line")
        fi
    done < "$path"
    [[ "$header" == true && "${fields[format]-}" == 1 && "${fields[release_tag]-}" == "$RELEASE_TAG" &&
       "${fields[revision]-}" =~ ^[0-9a-f]{40}$ && -n "${fields[generated_at]-}" ]] || die 'TUI 清单格式、标签或源码 revision 无效。'
    PARSED_REVISION="${fields[revision]}"
}

read_manifest_row() {
    local line="$1"
    [[ "$line" =~ ^([^$'\t']+)$'\t'([^$'\t']+)$'\t'([^$'\t']+)$'\t'([^$'\t']+)$'\t'([^$'\t']+)$ ]] || die 'TUI 清单记录必须包含五个非空字段。'
    ROW_SHA="${BASH_REMATCH[1]}"; ROW_SIZE="${BASH_REMATCH[2]}"; ROW_ROLE="${BASH_REMATCH[3]}"
    ROW_TARGET="${BASH_REMATCH[4]}"; ROW_ASSET="${BASH_REMATCH[5]}"
    [[ "$ROW_SHA" =~ ^[0-9a-f]{64}$ && "$ROW_SIZE" =~ ^[1-9][0-9]{0,8}$ ]] || die 'TUI 清单摘要或大小无效。'
}

parse_manifest() {
    local line
    local -A seen=()
    read_manifest_records "$MANIFEST_PATH"
    MANIFEST_REVISION="$PARSED_REVISION"
    for line in "${MANIFEST_ROWS[@]}"; do
        read_manifest_row "$line"
        [[ -z "${seen[$ROW_ASSET]+present}" && "$ROW_TARGET" == - ]] || die 'TUI 发布清单包含重复或无效的附件。'
        seen["$ROW_ASSET"]=1
        case "$ROW_ASSET:$ROW_ROLE" in
            install-tui.sh:bootstrap)
                ((ROW_SIZE <= SCRIPT_LIMIT)) || die 'TUI 引导安装器超出大小限制。'
                BOOTSTRAP_SHA="$ROW_SHA"; BOOTSTRAP_SIZE="$ROW_SIZE"
                ;;
            "$BUNDLE_NAME:bundle")
                ((ROW_SIZE <= BUNDLE_LIMIT)) || die 'TUI 压缩包超出大小限制。'
                BUNDLE_SHA="$ROW_SHA"; BUNDLE_SIZE="$ROW_SIZE"
                ;;
            *) die "TUI 发布清单包含未知附件：$ROW_ASSET" ;;
        esac
    done
    [[ "${seen[install-tui.sh]-}" == 1 && "${seen[$BUNDLE_NAME]-}" == 1 && ${#seen[@]} == 2 ]] || die 'TUI 发布清单缺少引导器或压缩包。'
}

parse_files_manifest() {
    local directory="$1" line metadata role target asset file actual_sha required
    local -A seen_assets=() seen_targets=()
    read_manifest_records "$directory/$FILES_NAME"
    [[ "$PARSED_REVISION" == "$MANIFEST_REVISION" ]] || die '压缩包与发布清单的源码 revision 不一致。'
    ((${#MANIFEST_ROWS[@]} <= MEMBER_LIMIT)) || die 'TUI 压缩包包含过多文件。'
    for line in "${MANIFEST_ROWS[@]}"; do
        read_manifest_row "$line"
        asset="$ROW_ASSET"
        ((ROW_SIZE <= SCRIPT_LIMIT)) || die "TUI 文件超出大小限制：$asset"
        metadata="$(asset_metadata "$asset")" || die "TUI 压缩包包含未知文件：$asset"
        IFS=$'\t' read -r role target <<< "$metadata"
        [[ "$ROW_ROLE" == "$role" && "$ROW_TARGET" == "$target" ]] || die "TUI 文件安装映射无效：$asset"
        [[ -z "${seen_assets[$asset]+present}" && -z "${seen_targets[$target]+present}" ]] || die "TUI 文件或安装目标重复：$asset"
        seen_assets["$asset"]=1; seen_targets["$target"]=1
        file="$directory/$asset"
        [[ -f "$file" && ! -L "$file" && "$(stat -c '%s' "$file")" == "$ROW_SIZE" ]] || die "TUI 文件缺失或大小不符：$asset"
        actual_sha="$(sha256sum < "$file")"
        [[ "${actual_sha%% *}" == "$ROW_SHA" ]] || die "TUI 文件摘要不符：$asset"
        bash -n "$file" || die "TUI 文件语法检查失败：$asset"
        if [[ "$asset" == install-tui.sh ]]; then
            [[ "$ROW_SHA" == "$BOOTSTRAP_SHA" && "$ROW_SIZE" == "$BOOTSTRAP_SIZE" ]] || die '压缩包中的引导器与发布附件不一致。'
        else
            safe_target_path "$target" || die "TUI 文件安装路径无效：$asset"
        fi
        ASSET_NAMES+=("$asset"); ASSET_SHA256+=("$ROW_SHA"); ASSET_SIZES+=("$ROW_SIZE")
        ASSET_ROLES+=("$ROW_ROLE"); ASSET_TARGETS+=("$ROW_TARGET")
    done
    for required in droidspaces-tui.sh droidspaces-gpu.sh droidspaces-video.sh install-tui.sh \
        install-anland-{kde,gnome,next,niri,hyprland,mango,denial}.sh \
        install-{mesa,hangover-wine,winefonts}.sh lib/anland-{common,archive-common,compositor-common}.sh; do
        [[ "${seen_assets[$required]-}" == 1 ]] || die "TUI 压缩包缺少必要文件：$required"
    done
    while IFS= read -r -d '' file; do
        asset="${file#"$directory/"}"
        if [[ "$asset" == lib && -d "$file" && ! -L "$file" ]]; then continue; fi
        [[ -f "$file" && ! -L "$file" && ( "$asset" == "$FILES_NAME" || -n "${seen_assets[$asset]+present}" ) ]] || die "TUI 压缩包包含清单以外的文件：$asset"
    done < <(find "$directory" -mindepth 1 -print0)
}

load_bundle() {
    local extracted="$WORK_DIR/unpacked" archive="$WORK_DIR/$BUNDLE_NAME"
    download_asset "$BUNDLE_NAME" "$BUNDLE_SHA" "$BUNDLE_SIZE" "$archive" || die '无法下载并校验 TUI 压缩包。'
    validate_bundle_archive "$archive" "$WORK_DIR/archive-members"
    extract_bundle_archive "$archive" "$extracted"
    mv -- "$extracted/tui" "$WORK_DIR/assets"
    parse_files_manifest "$WORK_DIR/assets"
    select_updates
}

reset_manifest_state() {
    MANIFEST_REVISION=''
    BUNDLE_SHA=''; BUNDLE_SIZE=''
    BOOTSTRAP_SHA=''; BOOTSTRAP_SIZE=''
    ASSET_NAMES=(); ASSET_SHA256=(); ASSET_SIZES=(); ASSET_ROLES=(); ASSET_TARGETS=()
    SELECTED_INDEXES=(); CHANGED_COUNT=0
}

load_github_manifest() {
    local row asset_id asset_sha asset_size asset_updated name expected_sha expected_size
    reset_manifest_state
    json_parser_available || return 1
    log "读取 GitHub Release：$RELEASE_TAG"
    fetch_release_metadata "$API_BEFORE" || return 1
    row="$(release_asset_row "$API_BEFORE" "$MANIFEST_NAME")" || return 1
    IFS=$'\t' read -r asset_id asset_sha asset_size asset_updated <<< "$row"
    [[ "$asset_size" =~ ^[1-9][0-9]{0,8}$ ]] && ((asset_size <= MANIFEST_LIMIT)) || die 'TUI 发布清单超出大小限制。'
    download_asset "$MANIFEST_NAME" "$asset_sha" "$asset_size" "$MANIFEST_PATH" || return 1
    parse_manifest
    for name in install-tui.sh "$BUNDLE_NAME"; do
        if [[ "$name" == install-tui.sh ]]; then expected_sha="$BOOTSTRAP_SHA"; expected_size="$BOOTSTRAP_SIZE"
        else expected_sha="$BUNDLE_SHA"; expected_size="$BUNDLE_SIZE"; fi
        row="$(release_asset_row "$API_BEFORE" "$name")" || return 1
        IFS=$'\t' read -r asset_id asset_sha asset_size asset_updated <<< "$row"
        [[ "$asset_sha" == "$expected_sha" && "$asset_size" == "$expected_size" ]] || die "Release API 与发布清单不一致：$name"
    done
    METADATA_SOURCE=github
    load_bundle
}

load_cnb_manifest() {
    reset_manifest_state
    download_cnb_manifest || return 1
    parse_manifest
    METADATA_SOURCE=cnb
    load_bundle
}

verify_release_unchanged() {
    local name before after
    for name in "$MANIFEST_NAME" "$BUNDLE_NAME" install-tui.sh; do
        before="$(release_asset_row "$API_BEFORE" "$name")" || die '无法读取下载前的 Release 信息。'
        after="$(release_asset_row "$API_AFTER" "$name")" || die '无法读取下载后的 Release 信息。'
        [[ "$before" == "$after" ]] || die "下载期间 Release 附件发生变化：$name"
    done
}

asset_selected() {
    local role="$1"
    case "$UPDATE_SCOPE:$role" in
        all:tui|all:installer|all:library|tui:tui|scripts:installer|scripts:library) return 0 ;;
        *) return 1 ;;
    esac
}

aliases_need_update() {
    [[ "$UPDATE_SCOPE" != scripts ]] || return 1
    [[ -L /usr/local/bin/dstui && "$(readlink /usr/local/bin/dstui)" == droidspaces-tui && \
       -L /usr/local/bin/ds-tui && "$(readlink /usr/local/bin/ds-tui)" == droidspaces-tui ]] || return 0
    return 1
}

select_updates() {
    local index target actual_sha anland_changed=false
    local -A selected=()
    for index in "${!ASSET_NAMES[@]}"; do
        asset_selected "${ASSET_ROLES[$index]}" || continue
        target="${ASSET_TARGETS[$index]}"
        if [[ -f "$target" && ! -L "$target" ]]; then
            actual_sha="$(sha256sum "$target" | awk '{print $1}')"
            [[ "$actual_sha" == "${ASSET_SHA256[$index]}" ]] && continue
        fi
        SELECTED_INDEXES+=("$index")
        selected["$index"]=1
        case "${ASSET_NAMES[$index]}" in
            install-anland-*.sh|lib/*) anland_changed=true ;;
        esac
    done
    # Entry scripts and their sourced libraries form one update/rollback group.
    if [[ "$anland_changed" == true ]]; then
        for index in "${!ASSET_NAMES[@]}"; do
            case "${ASSET_NAMES[$index]}" in
                install-anland-*.sh|lib/*)
                    [[ -z "${selected[$index]+present}" ]] || continue
                    SELECTED_INDEXES+=("$index")
                    ;;
            esac
        done
    fi
    CHANGED_COUNT="${#SELECTED_INDEXES[@]}"
    if aliases_need_update; then
        CHANGED_COUNT=$((CHANGED_COUNT + 1))
    fi
}

confirm_install() {
    local answer
    [[ "$ASSUME_YES" == true ]] && return
    [[ -t 0 ]] || die '非交互环境请使用 --yes。'
    printf '将更新 %s 项，是否继续？ [y/N]: ' "$CHANGED_COUNT"
    IFS= read -r answer || exit 1
    case "${answer,,}" in y|yes|1|是) ;; *) exit 0 ;; esac
}

ds_tui_rollback_directory() {
    local directory="$1" present snapshot target staged extra temporary failed=0
    [[ -f "$directory/targets.tsv" && ! -L "$directory/targets.tsv" ]] || return 1
    while IFS=$'\t' read -r present snapshot target staged extra; do
        [[ -z "${extra:-}" ]] && ds_operation_safe_path "$target" &&
            [[ "$snapshot" == "$directory/files/${target#/}" &&
               "$staged" == "$target.droidspaces-new-"* &&
               "${staged#"$target.droidspaces-new-"}" =~ ^[0-9]+$ ]] || { failed=1; continue; }
        rm -f -- "$staged" || failed=1
        if [[ "$present" == present && ( -f "$snapshot" || -L "$snapshot" ) ]]; then
            temporary="$target.droidspaces-restore-$BASHPID"
            if ! cp -a -- "$snapshot" "$temporary" || ! mv -Tf -- "$temporary" "$target"; then
                failed=1
            fi
        elif [[ "$present" == missing ]]; then
            rm -f -- "$target" || failed=1
        else
            failed=1
        fi
    done < "$directory/targets.tsv"
    return "$failed"
}

ds_tui_recover_pending() {
    local directory root="${DROIDSPACES_TUI_BACKUP_DIR:-/var/backups/droidspaces-tui}"
    [[ -e "$DS_OP_DIR/tui-pending" || -L "$DS_OP_DIR/tui-pending" ]] || return 0
    [[ -f "$DS_OP_DIR/tui-pending" && ! -L "$DS_OP_DIR/tui-pending" ]] || return 1
    IFS= read -r directory < "$DS_OP_DIR/tui-pending" || return 1
    ds_operation_safe_path "$root" && [[ "$directory" == "$root"/* && -d "$directory" &&
        ! -L "$directory" && "$(stat -c %u "$directory")" == "$EUID" ]] || return 1
    log "恢复未完成的 TUI 更新：$directory"
    ds_tui_rollback_directory "$directory" || {
        log "自动恢复失败；请保留备份并检查：$directory"
        return 1
    }
    rm -f -- "$DS_OP_DIR/tui-pending"
    log '已恢复更新前的脚本、命令别名和来源记录。'
}

ds_installer_rollback() {
    (( ${1:-0} == 0 )) || ds_tui_recover_pending
}

install_updates() {
    local index asset target staged mode backup_dir transaction_id
    local present snapshot extra metadata_target metadata_staged aliases_changed=false
    local backup_root="${DROIDSPACES_TUI_BACKUP_DIR:-/var/backups/droidspaces-tui}" path
    ds_operation_phase stage
    ds_operation_safe_path "$backup_root" || die '备份目录必须是安全的绝对路径。'
    path="$backup_root"
    while [[ "$path" != / ]]; do
        [[ ! -L "$path" ]] || die "备份目录包含符号链接：$path"
        path="${path%/*}"; [[ -n "$path" ]] || path=/
    done
    mkdir -p -- "$backup_root"
    [[ "$(stat -c %u "$backup_root")" == "$EUID" ]] || die '备份目录所有者不正确。'
    chmod 0700 "$backup_root"
    transaction_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    backup_dir="$(mktemp -d "$backup_root/$transaction_id.XXXXXXXX")"
    : > "$backup_dir/targets.tsv"

    ds_tui_prepare_target() {
        local prepared_target="$1" old=missing old_path="$backup_dir/files/${1#/}"
        ds_operation_safe_path "$prepared_target" || return 1
        [[ ! -d "$prepared_target" || -L "$prepared_target" ]] || return 1
        mkdir -p -- "${prepared_target%/*}" "${old_path%/*}"
        if [[ -e "$prepared_target" || -L "$prepared_target" ]]; then
            cp -a -- "$prepared_target" "$old_path"
            old=present
        fi
        printf '%s\t%s\t%s\t%s\n' "$old" "$old_path" "$prepared_target" \
            "$prepared_target.droidspaces-new-$$" >> "$backup_dir/targets.tsv"
    }
    for index in "${SELECTED_INDEXES[@]}"; do
        ds_tui_prepare_target "${ASSET_TARGETS[$index]}"
    done
    if aliases_need_update; then
        aliases_changed=true
        ds_tui_prepare_target /usr/local/bin/dstui
        ds_tui_prepare_target /usr/local/bin/ds-tui
    fi
    metadata_target="$DS_OP_DIR/installed-tui.tsv"
    metadata_staged="$metadata_target.droidspaces-new-$$"
    ds_tui_prepare_target "$metadata_target"
    # A complete durable target list exists before any installed path changes.
    printf '%s\n' "$backup_dir" > "$DS_OP_DIR/.tui-pending.$BASHPID"
    mv -f -- "$DS_OP_DIR/.tui-pending.$BASHPID" "$DS_OP_DIR/tui-pending"
    for index in "${SELECTED_INDEXES[@]}"; do
        asset="${ASSET_NAMES[$index]}"
        target="${ASSET_TARGETS[$index]}"
        staged="$WORK_DIR/assets/$asset"
        mode=0755
        [[ "${ASSET_ROLES[$index]}" != library ]] || mode=0644
        install -o "$(id -u)" -g "$(id -g)" -m "$mode" -- "$staged" "$target.droidspaces-new-$$"
    done
    if [[ "$aliases_changed" == true ]]; then
        ln -s -- droidspaces-tui /usr/local/bin/dstui.droidspaces-new-$$
        ln -s -- droidspaces-tui /usr/local/bin/ds-tui.droidspaces-new-$$
    fi
    {
        printf 'format=1\nrelease_tag=%s\nrevision=%s\nsource=%s\nscope=%s\ninstalled_at=%s\n' \
            "$RELEASE_TAG" "${MANIFEST_REVISION:-unknown}" "$DOWNLOAD_SOURCE" "$UPDATE_SCOPE" "$(date -u +%FT%TZ)"
        printf 'sha256\tasset\ttarget\n'
        for index in "${SELECTED_INDEXES[@]}"; do
            printf '%s\t%s\t%s\n' "${ASSET_SHA256[$index]}" "${ASSET_NAMES[$index]}" "${ASSET_TARGETS[$index]}"
        done
    } > "$metadata_staged"
    chmod 0600 "$metadata_staged"
    ds_operation_phase commit
    while IFS=$'\t' read -r present snapshot target staged extra; do
        mv -Tf -- "$staged" "$target"
    done < "$backup_dir/targets.tsv"
    ds_operation_phase verify
    for index in "${SELECTED_INDEXES[@]}"; do
        [[ "$(sha256sum "${ASSET_TARGETS[$index]}" | awk '{print $1}')" == "${ASSET_SHA256[$index]}" ]] || \
            die "安装后的脚本摘要不符：${ASSET_NAMES[$index]}"
    done
    # Clearing this pointer is the transaction commit; backups remain available.
    rm -f -- "$DS_OP_DIR/tui-pending"
    log "旧文件已备份到 $backup_dir"
}

main() {
    local index manifest_after before_sha after_sha

    parse_arguments "$@"
    require_script_file
    require_commands
    if [[ "$CHECK_ONLY" == false ]]; then
        ensure_root
        ds_operation_begin tui
        ds_tui_recover_pending
    fi

    WORK_DIR="$(mktemp -d -t droidspaces-tui.XXXXXXXX)"
    API_BEFORE="$WORK_DIR/release-before.json"
    API_AFTER="$WORK_DIR/release-after.json"
    MANIFEST_PATH="$WORK_DIR/$MANIFEST_NAME"

    case "$DOWNLOAD_SOURCE" in
        cnb)
            load_cnb_manifest || die '无法从 CNB 下载并解析 TUI 清单。'
            ;;
        auto)
            if ! load_github_manifest; then
                log '警告：GitHub Release 元数据不可用，将改用 CNB 清单（不经 GitHub Release API 校验）。'
                log 'Warning: GitHub Release metadata is unavailable; falling back to the CNB manifest without GitHub Release API verification.'
                DOWNLOAD_SOURCE=cnb
                load_cnb_manifest || die '无法从 GitHub 或 CNB 取得 TUI 清单。'
            fi
            ;;
        github|proxy)
            load_github_manifest || die '无法取得经过 GitHub Release API 校验的 TUI 清单。'
            ;;
    esac

    if ((CHANGED_COUNT == 0)); then
        log "所选范围已经是 $RELEASE_TAG 的最新版本。"
        exit 0
    fi
    log "发现 $CHANGED_COUNT 项需要安装或更新。"
    if [[ "$CHECK_ONLY" == true ]]; then
        for index in "${SELECTED_INDEXES[@]}"; do
            printf '  %s -> %s\n' "${ASSET_NAMES[$index]}" "${ASSET_TARGETS[$index]}"
        done
        aliases_need_update && printf '  %s\n' '命令别名 dstui / ds-tui'
        # 2 表示“检查成功且存在可用更新”，供 TUI 区分已是最新与检查失败。
        exit 2
    fi
    confirm_install

    if [[ "$METADATA_SOURCE" == github ]]; then
        fetch_release_metadata "$API_AFTER"
        verify_release_unchanged
    else
        manifest_after="$WORK_DIR/${MANIFEST_NAME}.after"
        download_cnb_manifest_to "$manifest_after" || \
            die '无法重新读取 CNB TUI 清单。'
        before_sha="$(sha256sum "$MANIFEST_PATH" | awk '{print $1}')"
        after_sha="$(sha256sum "$manifest_after" | awk '{print $1}')"
        [[ "$before_sha" == "$after_sha" ]] || \
            die '下载期间 CNB TUI 清单发生变化，请重试。'
    fi
    install_updates
    log "安装完成。运行 dstui 或 ds-tui 即可打开工具箱。"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
