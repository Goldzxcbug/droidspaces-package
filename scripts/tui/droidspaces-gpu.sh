#!/usr/bin/env bash
set -uo pipefail

# BEGIN DROIDSPACES SHARED ui
# shellcheck shell=bash
# Shared terminal cells and locale helpers, embedded into standalone releases.
DS_UI_LANGUAGE="${DS_UI_LANGUAGE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}}"
DS_UI_COLUMNS=80
DS_UI_ROWS=24

ds_ui_text() {
    if [[ "${DS_UI_LANGUAGE,,}" == zh* ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

ds_ui_size() {
    local rows="${LINES:-24}" columns="${COLUMNS:-80}"
    if [[ -t 1 ]] && command -v stty >/dev/null 2>&1; then
        read -r rows columns < <(stty size 2>/dev/null) || true
    fi
    [[ "$columns" =~ ^[0-9]+$ ]] && ((columns >= 12)) || columns=80
    [[ "$rows" =~ ^[0-9]+$ ]] && ((rows >= 9)) || rows=24
    DS_UI_COLUMNS="$columns"
    DS_UI_ROWS="$rows"
}

ds_ui_fit() {
    local LC_ALL=C.UTF-8 value="$1" width="$2" char code used=0 size i out=''
    for ((i=0; i<${#value}; i++)); do
        char="${value:i:1}"; printf -v code '%d' "'$char"; size=1
        if ((code < 32 || (code >= 127 && code < 160) || (code >= 0x200b && code <= 0x200f) ||
             (code >= 0x202a && code <= 0x202e) || (code >= 0x2060 && code <= 0x206f))); then continue; fi
        if (((code >= 0x300 && code <= 0x36f) || (code >= 0xfe00 && code <= 0xfe0f) || code == 0x200d)); then size=0
        elif (((code >= 0x1100 && code <= 0x115f) || (code >= 0x2e80 && code <= 0xa4cf) ||
              (code >= 0xac00 && code <= 0xd7a3) || (code >= 0xf900 && code <= 0xfaff) ||
              (code >= 0xfe10 && code <= 0xfe6f) || (code >= 0xff01 && code <= 0xff60) ||
              (code >= 0xffe0 && code <= 0xffe6) || (code >= 0x1f300 && code <= 0x1faff) ||
              (code >= 0x20000 && code <= 0x3ffff))); then size=2; fi
        ((used + size <= width)) || break
        out+="$char"; used=$((used + size))
    done
    printf '%s' "$out"
}
# END DROIDSPACES SHARED ui

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

GPU_ENV_FILE="${DROIDSPACES_GPU_ENV_FILE:-/etc/environment}"
GPU_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
GPU_GREEN='' GPU_YELLOW='' GPU_RESET=''
if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    GPU_GREEN=$'\033[32m' GPU_YELLOW=$'\033[93m' GPU_RESET=$'\033[0m'
fi
gpu_msg() { ds_ui_text "$1" "$2"; }

gpu_gl_label() {
    case "$1" in
        kgsl) printf 'OpenGL → Freedreno KGSL → GPU' ;;
        zink) printf 'OpenGL → Zink → Vulkan' ;;
        llvmpipe|softpipe) printf 'OpenGL → %s → CPU' "$1" ;;
        '') gpu_msg '未指定' 'Not specified' ;;
        *) printf '%s' "$1" ;;
    esac
}
gpu_vk_label() {
    if [[ -f "$1" ]]; then
        if gpu_manifest_matches "$1" turnip; then printf 'Vulkan → Turnip → GPU'; return; fi
        if gpu_manifest_matches "$1" lavapipe; then printf 'Vulkan → Lavapipe → CPU'; return; fi
    fi
    case "$1" in
        *freedreno*) printf 'Vulkan → Turnip → GPU' ;;
        *lvp*) printf 'Vulkan → Lavapipe → CPU' ;;
        '') gpu_msg '未指定' 'Not specified' ;;
        *) printf '%s' "$1" ;;
    esac
}

gpu_read_saved() {
    local line key value
    GPU_LOADER='' GPU_GALLIUM='' GPU_SOFTWARE='' GPU_ICD='' GPU_OLD_ICD=''
    [[ ! -e "$GPU_ENV_FILE" || -r "$GPU_ENV_FILE" ]] || return 1
    [[ -r "$GPU_ENV_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[2]}" value="${BASH_REMATCH[3]}"
            value="${value%"${value##*[![:space:]]}"}"
            value="${value#\"}"; value="${value%\"}"
            value="${value#\'}"; value="${value%\'}"
            case "$key" in
                MESA_LOADER_DRIVER_OVERRIDE) GPU_LOADER="$value" ;;
                GALLIUM_DRIVER) GPU_GALLIUM="$value" ;;
                LIBGL_ALWAYS_SOFTWARE) GPU_SOFTWARE="$value" ;;
                VK_DRIVER_FILES) GPU_ICD="$value" ;;
                VK_ICD_FILENAMES) GPU_OLD_ICD="$value" ;;
            esac
        fi
    done < "$GPU_ENV_FILE"
}

gpu_status() {
    local scope="$1" api="$2" loader gallium software icd
    if [[ "$scope" == saved ]]; then
        gpu_read_saved || { gpu_msg '无法读取配置' 'Configuration unreadable'; return 1; }
        loader="$GPU_LOADER" gallium="$GPU_GALLIUM" software="$GPU_SOFTWARE" icd="${GPU_ICD:-$GPU_OLD_ICD}"
    else
        loader="${MESA_LOADER_DRIVER_OVERRIDE:-}" gallium="${GALLIUM_DRIVER:-}" software="${LIBGL_ALWAYS_SOFTWARE:-}" icd="${VK_DRIVER_FILES:-${VK_ICD_FILENAMES:-}}"
    fi
    if [[ "$api" == opengl ]]; then
        if [[ "$software" == true || "$software" == 1 ]]; then
            gpu_gl_label "${gallium:-llvmpipe}"
        else
            gpu_gl_label "${gallium:-$loader}"
        fi
    else
        gpu_vk_label "$icd"
    fi
}

gpu_driver_file() {
    local name="$1" file
    for file in /usr/lib/aarch64-linux-gnu/dri/$name /usr/lib64/dri/$name /usr/lib/dri/$name; do
        [[ -f "$file" ]] && return 0
    done
    return 1
}
gpu_manifest_matches() {
    local path="$1" mode="$2" driver
    case "$mode" in turnip) driver=freedreno ;; lavapipe) driver=lvp ;; *) return 1 ;; esac
    [[ "$path" == /* && -f "$path" && -r "$path" ]] || return 1
    # Colon separates paths in Vulkan and the remaining characters cannot be
    # represented safely in /etc/environment without shell-like expansion.
    [[ "$path" != *:* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *'"'* && "$path" != *'\'* && "$path" != *'$'* && "$path" != *'`'* ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$path" "$driver" <<'PY'
import json, os, sys
try:
    with open(sys.argv[1], encoding='utf-8') as source:
        icd = json.load(source)['ICD']
    library = os.path.basename(icd['library_path'])
    arch = str(icd.get('library_arch', '64'))
    prefix = 'libvulkan_' + sys.argv[2] + '.so'
    ok = (library == prefix or library.startswith(prefix + '.')) and arch == '64'
except (OSError, ValueError, TypeError, KeyError, AttributeError):
    ok = False
sys.exit(0 if ok else 1)
PY
    elif command -v jq >/dev/null 2>&1; then
        jq -e --arg driver "$driver" '
            .ICD as $i | ($i.library_path | type == "string") and
            (($i.library_path | split("/") | last) | startswith("libvulkan_" + $driver + ".so")) and
            (($i.library_arch // "64" | tostring) == "64")
        ' "$path" >/dev/null 2>&1
    else
        printf '%s\n' "$(gpu_msg '需要 python3 或 jq 来检查 Vulkan 清单。' 'python3 or jq is required to validate Vulkan manifests.')" >&2
        return 1
    fi
}

gpu_find_manifests() {
    local mode="$1" directory file base group
    local -a directories=() bases=()
    local -A seen=()
    GPU_MANIFESTS=()
    # Follow the loader's XDG order, plus common build/install prefixes.
    bases+=("${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}")
    IFS=: read -r -a group <<< "${XDG_CONFIG_DIRS:-/etc/xdg}"
    bases+=("${group[@]}" /etc /usr/local/etc "${XDG_DATA_HOME:-${HOME:-/nonexistent}/.local/share}")
    IFS=: read -r -a group <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    bases+=("${group[@]}" /usr/local/share /usr/share)
    for base in "${bases[@]}"; do
        [[ "$base" == /* ]] || continue
        directory="${base%/}/vulkan/icd.d"
        [[ -d "$directory" ]] || continue
        for file in "$directory"/*.json; do
            [[ -f "$file" ]] || continue
            file="$(readlink -f -- "$file")" || continue
            [[ -z "${seen[$file]:-}" ]] || continue
            seen["$file"]=1
            gpu_manifest_matches "$file" "$mode" && GPU_MANIFESTS+=("$file")
        done
    done
    return 0
}

gpu_draw_begin() {
    ds_ui_size
    if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then printf '\033[2J\033[H'; fi
}

gpu_line() {
    printf '  %s\n' "$(ds_ui_fit "$1" "$((DS_UI_COLUMNS - 3))")"
}

# read remains line-oriented for adb and software keyboards. A resize redraws
# the same page; the terminal's canonical input buffer is left intact.
gpu_read_choice() {
    local columns="$DS_UI_COLUMNS" rows="$DS_UI_ROWS" status
    printf '  %s: ' "$(gpu_msg '请选择' 'Select')"
    while :; do
        IFS= read -r -t 0.2 GPU_CHOICE; status=$?
        ((status != 0)) || return 0
        ((status > 128)) || return 1
        ds_ui_size
        if [[ "$columns:$rows" != "$DS_UI_COLUMNS:$DS_UI_ROWS" || "${GPU_RESIZED:-false}" == true ]]; then
            GPU_RESIZED=false
            return 2
        fi
    done
}

gpu_choose_manifest() {
    local mode="$1" choice path index page=0 capacity first last read_status
    GPU_SELECTED_ICD=''
    gpu_find_manifests "$mode"
    if ((${#GPU_MANIFESTS[@]} == 1)); then
        GPU_SELECTED_ICD="${GPU_MANIFESTS[0]}"
        return 0
    fi
    while :; do
        gpu_draw_begin
        gpu_line "$(gpu_msg '选择 Vulkan 清单' 'Select Vulkan manifest')"
        capacity=$((DS_UI_ROWS - 7)); ((capacity >= 1)) || capacity=1
        first=$((page * capacity)); last=$((first + capacity))
        for ((index=first; index<last && index<${#GPU_MANIFESTS[@]}; index++)); do
            gpu_line "[$((index + 1))] ${GPU_MANIFESTS[$index]}"
        done
        if ((${#GPU_MANIFESTS[@]} == 0)); then
            gpu_line "$(gpu_msg '标准目录中没有匹配清单。' 'No matching manifest in standard directories.')"
        fi
        gpu_line "$(gpu_msg '输入编号或 JSON 绝对路径。' 'Enter a number or an absolute JSON path.')"
        gpu_line "$(gpu_msg '[N/P] 翻页  [0] 返回' '[N/P] Page  [0] Back')"
        gpu_read_choice; read_status=$?
        ((read_status != 2)) || continue
        ((read_status == 0)) || return 1
        choice="$GPU_CHOICE"
        case "$choice" in
            0|q|Q|'') return 1 ;;
            n|N) ((last >= ${#GPU_MANIFESTS[@]})) || page=$((page + 1)); continue ;;
            p|P) ((page <= 0)) || page=$((page - 1)); continue ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ && ${#choice} -le 6 ]] && ((10#$choice > 0 && 10#$choice <= ${#GPU_MANIFESTS[@]})); then
            path="${GPU_MANIFESTS[$((10#$choice - 1))]}"
        else
            path="$choice"
        fi
        if ! gpu_manifest_matches "$path" "$mode"; then
            printf '%s\n' "$(gpu_msg '清单无效或驱动类型不匹配。' 'Invalid manifest or incorrect driver type.')" >&2
            return 1
        fi
        GPU_SELECTED_ICD="$(readlink -f -- "$path")" || return 1
        return 0
    done
}

gpu_save() (
    local api="$1" mode="$2" icd="${3:-}" temporary pattern
    case "$api:$mode" in
        opengl:kgsl) gpu_driver_file kgsl_dri.so || return 1 ;;
        opengl:zink) gpu_driver_file zink_dri.so || return 1 ;;
        opengl:llvmpipe|opengl:softpipe) gpu_driver_file swrast_dri.so || return 1 ;;
        vulkan:turnip|vulkan:lavapipe) gpu_manifest_matches "$icd" "$mode" || return 1 ;;
        vulkan:auto) : ;;
        *) return 1 ;;
    esac
    [[ ! -L "$GPU_ENV_FILE" && ( ! -e "$GPU_ENV_FILE" || -f "$GPU_ENV_FILE" ) ]] || return 1
    ds_operation_begin gpu || return "$?"
    ds_operation_backup "$GPU_ENV_FILE" || return 1
    ds_operation_phase configuration || return 1
    cleanup() { [[ -z "${temporary:-}" ]] || rm -f -- "$temporary"; }
    temporary="$(mktemp "${GPU_ENV_FILE}.tmp.XXXXXXXX")" || return 1
    if [[ -f "$GPU_ENV_FILE" ]]; then
        if ! cp -p -- "$GPU_ENV_FILE" "$temporary" || ! cp -p -- "$GPU_ENV_FILE" "${GPU_ENV_FILE}.droidspaces-gpu.bak"; then
            rm -f -- "$temporary"; return 1
        fi
    else
        chmod 0644 "$temporary" || { rm -f -- "$temporary"; return 1; }
    fi
    if [[ "$api" == opengl ]]; then
        pattern='MESA_LOADER_DRIVER_OVERRIDE|GALLIUM_DRIVER|LIBGL_ALWAYS_SOFTWARE'
    else
        pattern='VK_DRIVER_FILES|VK_ICD_FILENAMES'
    fi
    if [[ -f "$GPU_ENV_FILE" ]] && ! awk -v keys="$pattern" '
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?(" keys ")[[:space:]]*=" { next }
        { print }
    ' "$GPU_ENV_FILE" > "$temporary"; then
        rm -f -- "$temporary"; return 1
    fi
    if ! {
        case "$api:$mode" in
            opengl:kgsl|opengl:zink) printf 'MESA_LOADER_DRIVER_OVERRIDE=%s\nGALLIUM_DRIVER=%s\n' "$mode" "$mode" ;;
            opengl:llvmpipe|opengl:softpipe) printf 'LIBGL_ALWAYS_SOFTWARE=true\nGALLIUM_DRIVER=%s\n' "$mode" ;;
            vulkan:auto) : ;;
            vulkan:*) printf 'VK_DRIVER_FILES="%s"\n' "$icd" ;;
        esac
    } >> "$temporary"; then
        rm -f -- "$temporary"; return 1
    fi
    mv -f -- "$temporary" "$GPU_ENV_FILE" || { rm -f -- "$temporary"; return 1; }
    ds_operation_phase verify || return 1
    gpu_read_saved || return 1
    case "$api:$mode" in
        opengl:kgsl|opengl:zink) [[ "$GPU_LOADER" == "$mode" && "$GPU_GALLIUM" == "$mode" && -z "$GPU_SOFTWARE" ]] ;;
        opengl:llvmpipe|opengl:softpipe) [[ "$GPU_SOFTWARE" == true && "$GPU_GALLIUM" == "$mode" && -z "$GPU_LOADER" ]] ;;
        vulkan:auto) [[ -z "$GPU_ICD" && -z "$GPU_OLD_ICD" ]] ;;
        vulkan:*) [[ "$GPU_ICD" == "$icd" && -z "$GPU_OLD_ICD" ]] ;;
    esac
)

gpu_option() {
    local number="$1" label="$2" description="$3" color="$GPU_YELLOW"
    [[ "$label" != "$GPU_CURRENT" ]] || color="$GPU_GREEN"
    printf '  %b%s%b\n' "$color" "$(ds_ui_fit "[$number] $label" "$((DS_UI_COLUMNS - 3))")" "$GPU_RESET"
    # Short screens keep actions and the prompt visible. Details remain on the
    # normal 24-row layout, with every line clipped by terminal cell width.
    if ((DS_UI_ROWS >= 20)); then gpu_line "  $description"; fi
}

gpu_draw_menu() {
    local page="$1" GPU_CURRENT
    gpu_draw_begin
    gpu_line "DROIDSPACES / $(gpu_msg '渲染路径' 'Rendering paths')${page:+ / $page}"
    if [[ -z "$page" ]]; then
        gpu_line "OpenGL $(gpu_msg '当前' 'now'): $(gpu_status current opengl)"
        gpu_line "OpenGL $(gpu_msg '下次启动' 'next'): $(gpu_status saved opengl)"
        gpu_line "Vulkan $(gpu_msg '当前' 'now'): $(gpu_status current vulkan)"
        gpu_line "Vulkan $(gpu_msg '下次启动' 'next'): $(gpu_status saved vulkan)"
        gpu_line '[1] OpenGL'
        gpu_line '[2] Vulkan'
    elif [[ "$page" == opengl ]]; then
        gpu_line "$(gpu_msg '当前' 'Now'): $(gpu_status current opengl)"
        gpu_line "$(gpu_msg '下次启动' 'Next'): $(gpu_status saved opengl)"
        GPU_CURRENT="$(gpu_status current opengl)"
        gpu_option 1 "$(gpu_gl_label kgsl)" "$(gpu_msg 'Freedreno 通过 KGSL 访问 GPU。' 'Freedreno accesses the GPU through KGSL.')"
        gpu_option 2 "$(gpu_gl_label zink)" "$(gpu_msg '使用已选择的 Vulkan 驱动。' 'Uses the selected Vulkan driver.')"
        gpu_option 3 "$(gpu_gl_label llvmpipe)" "$(gpu_msg 'CPU 软件渲染，用于排查问题。' 'CPU software rendering for troubleshooting.')"
        gpu_option 4 "$(gpu_gl_label softpipe)" "$(gpu_msg 'CPU 参考渲染，用于调试。' 'CPU reference renderer for debugging.')"
    else
        gpu_line "$(gpu_msg '当前' 'Now'): $(gpu_status current vulkan)"
        gpu_line "$(gpu_msg '下次启动' 'Next'): $(gpu_status saved vulkan)"
        GPU_CURRENT="$(gpu_status current vulkan)"
        gpu_option 5 "$(gpu_vk_label freedreno)" "$(gpu_msg 'Turnip：通过 Vulkan 访问 Adreno GPU。' 'Turnip accesses Adreno GPUs through Vulkan.')"
        gpu_option 6 "$(gpu_vk_label lvp)" "$(gpu_msg 'Lavapipe：CPU 软件渲染。' 'Lavapipe renders Vulkan on the CPU.')"
        gpu_option 7 "$(gpu_msg '自动发现驱动' 'Automatic driver discovery')" "$(gpu_msg '清除本配置中的 Vulkan 驱动指定。' 'Clears Vulkan overrides in this configuration.')"
    fi
    gpu_line "$(gpu_msg '[0] 返回  ·  保存后需重启容器' '[0] Back  ·  Restart container after saving')"
}

gpu_menu() {
    local api choice mode status icd read_status page="${1:-}"
    GPU_RESIZED=false
    trap 'GPU_RESIZED=true' WINCH
    while :; do
        gpu_draw_menu "$page"
        gpu_read_choice; read_status=$?
        ((read_status != 2)) || continue
        ((read_status == 0)) || break
        choice="$GPU_CHOICE"
        if [[ "$choice" == 0 || "${choice,,}" == q ]]; then
            [[ -n "$page" ]] || break
            page=''; continue
        fi
        if [[ -z "$page" ]]; then
            case "$choice" in 1) page=opengl ;; 2) page=vulkan ;; esac
            continue
        fi
        case "$page:$choice" in
            opengl:1) api=opengl; mode=kgsl ;; opengl:2) api=opengl; mode=zink ;;
            opengl:3) api=opengl; mode=llvmpipe ;; opengl:4) api=opengl; mode=softpipe ;;
            vulkan:5) api=vulkan; mode=turnip ;; vulkan:6) api=vulkan; mode=lavapipe ;; vulkan:7) api=vulkan; mode=auto ;;
            *) continue ;;
        esac
        icd=''
        if [[ "$api" == vulkan && "$mode" != auto ]]; then
            gpu_choose_manifest "$mode" || continue
            icd="$GPU_SELECTED_ICD"
        fi
        if ((EUID == 0)); then
            gpu_save "$api" "$mode" "$icd"; status=$?
        elif command -v sudo >/dev/null 2>&1; then
            sudo -- env "DROIDSPACES_GPU_ENV_FILE=$GPU_ENV_FILE" bash "$GPU_SCRIPT" --set "$api" "$mode" "$icd"; status=$?
        else
            status=1
        fi
        if ((status == 0)); then
            gpu_line "$(gpu_msg '配置已保存，请重启容器。' 'Saved. Restart the container to apply.')"
        else
            gpu_line "$(gpu_msg '保存失败：请检查权限、驱动和配置。' 'Save failed: check access, driver and configuration.')"
        fi
        printf '  %s' "$(gpu_msg '按 Enter 继续...' 'Press Enter to continue...')"
        IFS= read -r choice || break
    done
    trap - WINCH
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --status)
            [[ $# == 3 && ( "$2" == current || "$2" == saved ) && ( "$3" == opengl || "$3" == vulkan ) ]] || exit 2
            gpu_status "$2" "$3" ;;
        --set)
            [[ ( $# == 3 || $# == 4 ) && $EUID == 0 ]] || exit 2
            gpu_save "$2" "$3" "${4:-}" ;;
        ""|opengl|vulkan) [[ $# -le 1 ]] || exit 2; gpu_menu "${1:-}" ;;
        *) printf '%s\n' 'Usage: droidspaces-gpu | --status current|saved opengl|vulkan | --set opengl|vulkan MODE [ICD_JSON]' >&2; exit 2 ;;
    esac
fi
