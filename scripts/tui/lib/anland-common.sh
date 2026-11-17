#!/usr/bin/env bash
# shellcheck shell=bash

# BEGIN DROIDSPACES SHARED operations
# shellcheck shell=bash
# Shared installer transaction support, loaded by the Anland entry scripts.
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

detect_language() {
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    if [[ "$locale_name" == zh* ]]; then UI_LANG=zh; fi
}

msg() {
    if [[ "$UI_LANG" == zh ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

log() {
    printf '[anland-%s] %s\n' "$COMPONENT_NAME" "$(msg "$1" "$2")"
}

die() {
    printf '[anland-%s] %s: %s\n' "$COMPONENT_NAME" "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
}

record_component_version() {
    ds_operation_phase verify
    local version="$1" state_file="$COMPONENT_STATE_DIR/$ANLAND_STATE_NAME.version" temporary_file
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    if ! mkdir -p -- "$COMPONENT_STATE_DIR"; then
        log "无法记录已安装的 $ANLAND_DISPLAY_NAME 版本。" "Could not record the installed $ANLAND_DISPLAY_NAME version."
        return 0
    fi
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "无法记录已安装的 $ANLAND_DISPLAY_NAME 版本。" "Could not record the installed $ANLAND_DISPLAY_NAME version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" &&
        chmod 0644 "$temporary_file" && mv -f -- "$temporary_file" "$state_file"; then
        ds_operation_record_packages "$ANLAND_STATE_NAME" "$COMPONENT_STATE_DIR" || \
            printf 'Could not record native package identity; status will remain conservative.\n' >&2
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "无法记录已安装的 $ANLAND_DISPLAY_NAME 版本。" "Could not record the installed $ANLAND_DISPLAY_NAME version."
    return 0
}

update_desktop_config() {
    ds_operation_phase configuration
    local desktop="$ANLAND_DESKTOP_NAME" config_dir temporary_file line configured_desktop=''
    local desktop_lines=0
    config_dir="$(dirname -- "$DESKTOP_CONFIG")"
    if [[ ! -e "$DESKTOP_CONFIG" && ! -L "$DESKTOP_CONFIG" ]]; then
        if [[ ! -d "$config_dir" ]]; then
            install -d -m 0755 -- "$config_dir" || \
                die '无法创建桌面配置目录。' 'Could not create the desktop configuration directory.'
        fi
        temporary_file="$(mktemp "$config_dir/.droidspaces-desktop.conf.tmp.XXXXXXXX")" || \
            die '无法创建临时桌面配置。' 'Could not create a temporary desktop configuration.'
        if ! { printf 'DESKTOP=%s\n' "$desktop";
            if [[ "$ANLAND_FORCE_WAYLAND" == true ]]; then printf 'DISPLAY_BACKEND=anland-wayland\n'; fi;
        } > "$temporary_file" || ! chmod 0644 "$temporary_file" || ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
            rm -f -- "$temporary_file" || true
            die '无法创建桌面配置。' 'Could not create the desktop configuration.'
        fi
        log "已创建桌面配置：DESKTOP=${desktop}。" "Created the desktop configuration with DESKTOP=${desktop}."
        return
    fi
    if [[ ! -f "$DESKTOP_CONFIG" || -L "$DESKTOP_CONFIG" || ! -r "$DESKTOP_CONFIG" ]]; then
        die "桌面配置不是可安全修改的普通文件：${DESKTOP_CONFIG}。" \
            "The desktop configuration is not a safely writable regular file: ${DESKTOP_CONFIG}."
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in DESKTOP=*) configured_desktop="${line#DESKTOP=}"; ((desktop_lines += 1)) ;; esac
    done < "$DESKTOP_CONFIG"
    if ((desktop_lines != 1)) || [[ ! "$configured_desktop" =~ ^(none|[a-z][a-z0-9-]*)$ ]]; then
        die '桌面配置格式无效，未覆盖原文件。' 'The desktop configuration is invalid; the original file was not overwritten.'
    fi
    if [[ "$configured_desktop" != none ]] && \
        { [[ "$ANLAND_DESKTOP_UPDATE_SELF" != true ]] || [[ "$configured_desktop" != "$desktop" ]]; }; then
        log "保留现有桌面配置：DESKTOP=${configured_desktop}。" "Keeping the existing desktop configuration: DESKTOP=${configured_desktop}."
        return
    fi
    temporary_file="$(mktemp "$config_dir/.droidspaces-desktop.conf.tmp.XXXXXXXX")" || \
        die '无法创建临时桌面配置。' 'Could not create a temporary desktop configuration.'
    if ! awk -v desktop="$desktop" -v wayland="$ANLAND_FORCE_WAYLAND" '
        /^DESKTOP=/ { print "DESKTOP=" desktop; next }
        /^DISPLAY_BACKEND=/ && wayland == "true" { if (!backend++) print "DISPLAY_BACKEND=anland-wayland"; next }
        { print }
        END { if (wayland == "true" && !backend) print "DISPLAY_BACKEND=anland-wayland" }
    ' "$DESKTOP_CONFIG" > "$temporary_file" || ! chmod 0644 "$temporary_file" || \
        ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
        rm -f -- "$temporary_file" || true
        die '无法更新桌面配置。' 'Could not update the desktop configuration.'
    fi
    log "已将桌面配置更新为 DESKTOP=${desktop}。" "Updated the desktop configuration to DESKTOP=${desktop}."
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

check_architecture() {
    case "$(uname -m)" in
        aarch64|arm64) ;;
        *)
            die "预编译包仅支持 ARM64/aarch64，当前架构为 $(uname -m)。" \
                "The prebuilt packages support ARM64/aarch64 only; current architecture is $(uname -m)."
            ;;
    esac
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O "$destination" "$url"
    else
        die "未找到 curl 或 wget，无法下载安装包。" "Neither curl nor wget was found; packages cannot be downloaded."
    fi
}

download_stdout() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 60 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O - "$url"
    else
        die "未找到 curl 或 wget，无法读取 Release 信息。" "Neither curl nor wget was found; Release information cannot be read."
    fi
}

validate_release_tag() {
    case "$RELEASE_TAG" in
        "$ROLLING_RELEASE_TAG") ;;
        *)
            die "Release tag 只能是 ${ROLLING_RELEASE_TAG}。" \
                "The Release tag must be ${ROLLING_RELEASE_TAG}."
            ;;
    esac
}

resolve_release_tag() {
    validate_repository
    if [[ -z "$RELEASE_TAG" ]]; then
        RELEASE_TAG="$ROLLING_RELEASE_TAG"
    fi
    validate_release_tag
    log "使用固定滚动 Release: ${RELEASE_TAG}" "Using rolling Release: ${RELEASE_TAG}"
}

fetch_official_release_metadata() {
    local api_url

    api_url="${GITHUB_API_URL}/repos/${RELEASE_REPOSITORY}/releases/tags/${RELEASE_TAG}"
    if ! OFFICIAL_RELEASE_METADATA="$(download_stdout "$api_url")"; then
        log "无法获取 GitHub 官方 SHA-256 校验值，拒绝使用第三方镜像包。" \
            "Could not obtain GitHub's official SHA-256 digest; refusing the third-party mirror package."
        return 1
    fi
}

release_asset_sha256() {
    local requested_name="$1"
    local digest

    if ! digest="$(jq -er --arg name "$requested_name" --arg tag "$RELEASE_TAG" '
        if .tag_name != $tag then
            error("release tag mismatch")
        else
            [.assets[] | select(.name == $name) | .digest] |
            if length == 1 then .[0] else error("asset digest is not unique") end
        end
    ' <<< "$OFFICIAL_RELEASE_METADATA" 2>/dev/null)"; then
        return 1
    fi
    if [[ ! "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]]; then
        return 1
    fi

    printf '%s' "${BASH_REMATCH[1],,}"
}

resolve_official_manifest_sha256() {
    EXPECTED_MANIFEST_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "1" ]]; then
        return
    fi
    command -v jq >/dev/null 2>&1 || \
        die "选择第三方镜像需要 jq 来校验 GitHub Release。" \
            "Selecting a third-party mirror requires jq to verify the GitHub Release."
    command -v sha256sum >/dev/null 2>&1 || \
        die "选择第三方镜像需要 sha256sum 来校验下载文件。" \
            "Selecting a third-party mirror requires sha256sum to verify downloaded files."
    if ! fetch_official_release_metadata; then
        return 1
    fi
    if ! EXPECTED_MANIFEST_SHA256="$(release_asset_sha256 "$MANIFEST_NAME")"; then
        log "GitHub Release 未提供 ${MANIFEST_NAME} 的 SHA-256 校验值，拒绝使用第三方镜像包。" \
            "GitHub Release did not provide a SHA-256 digest for ${MANIFEST_NAME}; refusing the third-party mirror package."
        return 1
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
    case "$1" in
        1) printf 'GitHub' ;;
        2) printf 'gh-proxy.com' ;;
        3) printf 'CNB' ;;
        *) return 1 ;;
    esac
}

download_source_probe_url() {
    local source="$1"

    case "$source" in
        1)
            printf '%s/%s/releases/download/%s/%s' \
                "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        2)
            printf '%s/%s/releases/download/%s/%s' \
                "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        3)
            printf '%s/%s/-/releases/download/%s/%s' \
                "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        *) return 1 ;;
    esac
}

probe_download_source() {
    local source="$1"
    local probe_url latency started finished probe_status=0
    local -a probe_command

    probe_url="$(download_source_probe_url "$source")" || return 1
    if command -v curl >/dev/null 2>&1; then
        if latency="$(curl -fsSL --connect-timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" \
            --max-time "$SOURCE_PROBE_TIMEOUT_SECONDS" --output /dev/null \
            --write-out '%{time_total}' "$probe_url" 2>/dev/null)"; then
            if awk -v seconds="$latency" -v limit="$SOURCE_PROBE_TIMEOUT_SECONDS" \
                'BEGIN { exit (seconds < limit ? 0 : 1) }'; then
                format_latency "$latency"
                return
            fi
            printf '%s' "$(msg '超时' 'timeout')"
            return
        else
            probe_status=$?
        fi
    elif command -v wget >/dev/null 2>&1; then
        command -v timeout >/dev/null 2>&1 || \
            die "wget 测试下载源需要 timeout 命令以限制为 ${SOURCE_PROBE_TIMEOUT_SECONDS} 秒。" \
                "Testing download sources with wget requires timeout to enforce the ${SOURCE_PROBE_TIMEOUT_SECONDS}-second limit."
        started="$(date +%s%3N 2>/dev/null || true)"
        probe_command=(wget -q --tries=1 --timeout="$SOURCE_PROBE_TIMEOUT_SECONDS" -O /dev/null "$probe_url")
        probe_command=(timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" "${probe_command[@]}")
        if "${probe_command[@]}"; then
            finished="$(date +%s%3N 2>/dev/null || true)"
            if [[ "$started" =~ ^[0-9]+$ && "$finished" =~ ^[0-9]+$ ]]; then
                if (( finished - started < SOURCE_PROBE_TIMEOUT_SECONDS * 1000 )); then
                    printf '%d ms' "$((finished - started))"
                else
                    printf '%s' "$(msg '超时' 'timeout')"
                fi
            else
                printf '%s' "$(msg '可用' 'available')"
            fi
            return
        else
            probe_status=$?
        fi
    else
        die "未找到 curl 或 wget，无法测试下载源。" "Neither curl nor wget was found; download sources cannot be tested."
    fi

    if (( probe_status == 28 || probe_status == 124 )); then
        printf '%s' "$(msg '超时' 'timeout')"
    else
        printf '%s' "$(msg '不可用' 'unavailable')"
    fi
}

select_download_source() {
    ds_operation_phase source
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
        if [[ "$source" == "3" ]]; then
            recommendation="$(msg '（推荐）' ' (recommended)')"
        fi
        printf '%s. %s%s %s: %s\n' "$source" "$(download_source_name "$source")" \
            "$recommendation" "$(msg '延迟' 'latency')" "$latency"
    done

    while :; do
        printf '%s' "$(msg '请输入下载源编号 [1-3]: ' 'Choose a download source [1-3]: ')"
        if ! IFS= read -r choice; then
            die "无法读取下载源选择。请使用 -1/--1、-2/--2 或 -3/--3 指定下载源。" \
                "Unable to read a download-source choice. Specify -1/--1, -2/--2, or -3/--3."
        fi
        case "$choice" in
            1|2|3)
                DOWNLOAD_SOURCE="$choice"
                return
                ;;
            *)
                log "请输入 1、2 或 3。" "Enter 1, 2, or 3."
                ;;
        esac
    done
}

validate_release_asset_checksum() {
    ds_operation_phase verify
    local asset_file="$1"
    local expected_checksum="$2"
    local asset_name="$3"
    local actual_checksum

    if ! actual_checksum="$(sha256sum "$asset_file" | awk '{print $1}')" || \
        ! [[ "$actual_checksum" =~ ^[0-9a-f]{64}$ ]] || \
        [[ "$actual_checksum" != "$expected_checksum" ]]; then
        log "下载的 ${asset_name} 未通过 SHA-256 校验。" \
            "Downloaded ${asset_name} failed SHA-256 verification."
        return 1
    fi
}

validate_repository() {
    if [[ ! "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        die "Release 仓库必须是 owner/repository 格式。" \
            "The Release repository must use the owner/repository format."
    fi
}

format_latency() {
    local seconds="$1"

    awk -v seconds="$seconds" 'BEGIN { printf "%d ms", (seconds * 1000) + 0.5 }'
}

validate_managed_dnf_block() {
    local dnf_conf="$1"

    awk -v begin="$DNF_MANAGED_BEGIN" -v end="$DNF_MANAGED_END" '
        $0 == begin {
            if (inside) {
                invalid = 1
            }
            begins++
            inside = 1
        }
        $0 == end {
            if (!inside) {
                invalid = 1
            }
            ends++
            inside = 0
        }
        END { exit (!invalid && !inside && begins == ends && begins <= 1) ? 0 : 1 }
    ' "$dnf_conf"
}

rewrite_dnf_config_without_mesa_block() {
    local dnf_conf="$1"
    local output_file="$2"

    awk -v begin="$MESA_DNF_MANAGED_BEGIN" -v end="$MESA_DNF_MANAGED_END" '
        $0 == begin {
            if (inside) {
                invalid = 1
            }
            begins++
            inside = 1
            next
        }
        $0 == end {
            if (!inside) {
                invalid = 1
            }
            ends++
            inside = 0
            next
        }
        !inside { print }
        END {
            if (invalid || inside || begins != ends || begins > 1) {
                exit 1
            }
        }
    ' "$dnf_conf" > "$output_file"
}

rewrite_dnf_config_without_managed_block() {
    local dnf_conf="$1"
    local output_file="$2"

    validate_managed_dnf_block "$dnf_conf" || return 1

    awk -v begin="$DNF_MANAGED_BEGIN" -v end="$DNF_MANAGED_END" \
        -v legacy_package="$DNF_LEGACY_PACKAGE" \
        -v legacy_begin="# anland-${COMPONENT_NAME}: hold patched ${DNF_LEGACY_LABEL:-$COMPONENT_LABEL}/Xwayland packages" '
        BEGIN {
            legacy_pattern = "^[[:space:]]*exclude[[:space:]]*=[[:space:]]*" legacy_package "\\*[[:space:]]+xorg-x11-server-Xwayland\\*[[:space:]]*$"
        }
        $0 == begin { managed = 1; next }
        $0 == end { managed = 0; next }
        managed { next }
        legacy_pending {
            if ($0 ~ legacy_pattern) {
                legacy_pending = 0
                next
            }
            print legacy_begin
            legacy_pending = 0
        }
        $0 == legacy_begin {
            legacy_pending = 1
            next
        }
        { print }
        END {
            if (legacy_pending) {
                print legacy_begin
            }
        }
    ' "$dnf_conf" > "$output_file"
}

rewrite_dnf_config_for_package_install() {
    local dnf_conf="$1"
    local output_file="$2"
    local preserve_xwayland="${3:-false}"
    # The older KDE/GNOME/session helpers did not accept this optional flag.
    [[ "${DNF_ALLOW_PRESERVE_XWAYLAND:-true}" == true ]] || preserve_xwayland=false

    awk -v preserve_xwayland="$preserve_xwayland" \
        -v remove_packages="$(printf '%s\n' "${DNF_STRIP_PACKAGES[@]}")" \
        -v shared_packages="$(printf '%s\n' "${DNF_XWAYLAND_STRIP_PACKAGES[@]}")" '
        BEGIN {
            count = split(remove_packages, packages, "\n")
            for (i = 1; i <= count; i++) stripped[packages[i]] = 1
            count = split(shared_packages, packages, "\n")
            for (i = 1; i <= count; i++) shared[packages[i]] = 1
        }
        function sanitize(line, equals, value, count, tokens, result, separator, i) {
            equals = index(line, "=")
            value = substr(line, equals + 1)
            gsub(/,/, " ", value)
            count = split(value, tokens, /[[:space:]]+/)
            result = ""
            separator = ""
            for (i = 1; i <= count; i++) {
                if (tokens[i] == "" || tokens[i] in stripped || \
                    (preserve_xwayland != "true" && tokens[i] in shared)) {
                    continue
                }
                result = result separator tokens[i]
                separator = ","
            }
            return result == "" ? "" : substr(line, 1, equals) result
        }
        /^\[main\][[:space:]]*$/ {
            in_main = 1
            print
            next
        }
        /^\[[^]]+\][[:space:]]*$/ {
            in_main = 0
            print
            next
        }
        {
            if (in_main && $0 ~ /^[[:space:]]*(exclude|excludepkgs)[[:space:]]*=/) {
                sanitized = sanitize($0)
                if (sanitized != "") {
                    print sanitized
                }
                next
            }
            print
        }
    ' "$dnf_conf" > "$output_file"
}

remove_managed_dnf_excludes() {
    local dnf_conf="$1"
    local temporary_conf mesa_stripped_conf transaction_conf

    # Local patched RPMs must bypass both hold blocks. The caller restores
    # the original configuration immediately after the DNF transaction.
    temporary_conf="$(mktemp -t anland-${COMPONENT_NAME}-dnf.XXXXXXXX)"
    mesa_stripped_conf="$(mktemp -t anland-${COMPONENT_NAME}-dnf.XXXXXXXX)"
    transaction_conf="$(mktemp -t anland-${COMPONENT_NAME}-dnf.XXXXXXXX)"
    if ! rewrite_dnf_config_without_managed_block "$dnf_conf" "$temporary_conf" || \
        ! rewrite_dnf_config_without_mesa_block "$temporary_conf" "$mesa_stripped_conf" || \
        ! rewrite_dnf_config_for_package_install "$mesa_stripped_conf" "$transaction_conf"; then
        rm -f -- "$temporary_conf" "$mesa_stripped_conf" "$transaction_conf"
        return 1
    fi
    if ! install -m 0644 "$transaction_conf" "$dnf_conf"; then
        rm -f -- "$temporary_conf" "$mesa_stripped_conf" "$transaction_conf"
        return 1
    fi
    rm -f -- "$temporary_conf" "$mesa_stripped_conf" "$transaction_conf"
}

write_dnf_config_with_managed_block() {
    local dnf_conf="$1"
    local output_file="$2"
    local stripped_conf
    local excluded_packages="$DNF_EXCLUDED_PACKAGES"

    if [[ -e "$SYSTEMD257_STATE" ]]; then
        excluded_packages+=",systemd*"
    fi

    stripped_conf="$(mktemp -t anland-${COMPONENT_NAME}-dnf.XXXXXXXX)"
    if ! rewrite_dnf_config_without_managed_block "$dnf_conf" "$stripped_conf"; then
        rm -f -- "$stripped_conf"
        return 1
    fi
    if ! awk -v begin="$DNF_MANAGED_BEGIN" -v end="$DNF_MANAGED_END" \
        -v excludes="$excluded_packages" '
        function contains(value, wanted, normalized, count, tokens, i) {
            normalized = value
            gsub(/,/, " ", normalized)
            count = split(normalized, tokens, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                if (tokens[i] == wanted) {
                    return 1
                }
            }
            return 0
        }
        function merge_excludes(line, equals, value, trimmed, separator, count, wanted, i) {
            equals = index(line, "=")
            value = substr(line, equals + 1)
            trimmed = value
            sub(/[[:space:]]+$/, "", trimmed)
            separator = (trimmed == "" || trimmed ~ /,$/) ? "" : ","
            count = split(excludes, wanted, ",")
            for (i = 1; i <= count; i++) {
                if (!contains(value, wanted[i])) {
                    value = value separator wanted[i]
                    separator = ","
                }
            }
            return substr(line, 1, equals) value
        }
        function write_block() {
            print begin
            print "excludepkgs=" excludes
            print end
        }
        /^\[main\][[:space:]]*$/ {
            in_main = 1
            saw_main = 1
            print
            next
        }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_main && !saw_exclude) {
                write_block()
            }
            in_main = 0
            print
            next
        }
        {
            if (in_main && $0 ~ /^[[:space:]]*excludepkgs[[:space:]]*=/) {
                print merge_excludes($0)
                saw_exclude = 1
                next
            }
            print
        }
        END {
            if (in_main && !saw_exclude) {
                write_block()
            }
            if (!saw_main) {
                print "[main]"
                write_block()
            }
        }
    ' "$stripped_conf" > "$output_file"; then
        rm -f -- "$stripped_conf"
        return 1
    fi
    rm -f -- "$stripped_conf"
}

configure_dnf_excludes() {
    ds_operation_phase holds
    local dnf_conf="/etc/dnf/dnf.conf"
    local temporary_conf

    touch "$dnf_conf"
    temporary_conf="$(mktemp -t anland-${COMPONENT_NAME}-dnf.XXXXXXXX)"
    if ! write_dnf_config_with_managed_block "$dnf_conf" "$temporary_conf"; then
        rm -f -- "$temporary_conf"
        return 1
    fi
    if ! install -m 0644 "$temporary_conf" "$dnf_conf"; then
        rm -f -- "$temporary_conf"
        return 1
    fi
    rm -f -- "$temporary_conf"
}

write_pacman_hold_block() {
    ds_operation_phase holds
    local -a packages=("$@")
    local temporary
    ((${#packages[@]} > 0)) || return 0
    command -v pacman >/dev/null 2>&1 || return 0
    [[ -f /etc/pacman.conf ]] || return 0
    temporary="$(mktemp -t "anland-$COMPONENT_NAME-pacman.XXXXXXXX")" || return 1
    if ! awk -v begin="# BEGIN anland-$COMPONENT_NAME package holds" \
        -v end="# END anland-$COMPONENT_NAME package holds" \
        -v packages="${packages[*]}" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        skip { next }
        /^\[options\][[:space:]]*$/ && !wrote {
            print
            print begin
            print "IgnorePkg = " packages
            print end
            wrote = 1
            next
        }
        { print }
        END { if (skip) exit 1; if (!wrote) exit 1 }
    ' /etc/pacman.conf > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! install -m 0644 -- "$temporary" /etc/pacman.conf; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
}

remove_pacman_hold_entries() {
    local -a packages=("$@")
    local temporary
    command -v pacman >/dev/null 2>&1 || return 0
    [[ -f /etc/pacman.conf ]] || return 0
    temporary="$(mktemp -t "anland-$COMPONENT_NAME-pacman.XXXXXXXX")" || return 1
    if ! awk -v begin="# BEGIN anland-$COMPONENT_NAME package holds" \
        -v end="# END anland-$COMPONENT_NAME package holds" \
        -v remove_list="${packages[*]}" '
        BEGIN { remove_count = split(remove_list, remove_names, /[[:space:]]+/) }
        $0 == begin { inside = 1; next }
        $0 == end { inside = 0; next }
        inside { next }
        /^# BEGIN .* package holds$/ { foreign = 1; print; next }
        /^# END .* package holds$/ { foreign = 0; print; next }
        foreign { print; next }
        /^[[:space:]]*IgnorePkg[[:space:]]*=/ {
            equals = index($0, "=")
            count = split(substr($0, equals + 1), items, /[[:space:]]+/)
            output = ""
            for (i = 1; i <= count; i++) {
                remove = 0
                for (j = 1; j <= remove_count; j++) {
                    if (items[i] == remove_names[j]) remove = 1
                }
                if (items[i] != "" && !remove) output = output (output == "" ? "" : " ") items[i]
            }
            if (output != "") print substr($0, 1, equals) " " output
            next
        }
        { print }
    ' /etc/pacman.conf > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! install -m 0644 -- "$temporary" /etc/pacman.conf; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
}

clear_stale_apt_holds() {
    local -a current_packages=("$@") previous_packages=()
    local previous current keep

    [[ -r "$APT_HOLD_STATE" ]] || return 0
    mapfile -t previous_packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
    for previous in "${previous_packages[@]}"; do
        keep=false
        for current in "${current_packages[@]}"; do
            if [[ "$previous" == "$current" ]]; then
                keep=true
                break
            fi
        done
        if [[ "$keep" == false ]]; then
            apt-mark unhold "$previous" >/dev/null 2>&1 || true
        fi
    done
}

write_apt_hold_state() {
    ds_operation_phase holds
    install -d -m 0755 "$(dirname "$APT_HOLD_STATE")"
    printf '%s\n' "$@" | sort -u > "$APT_HOLD_STATE"
}

detect_target() {
    [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。' 'Unable to read /etc/os-release.'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || die '/etc/os-release 缺少 ID。' '/etc/os-release does not contain ID.'
    local distro_id="${ID,,}" version_id="${VERSION_ID:-}" platform archive_suffix
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"
    case "$distro_id" in
        arch|archarm|archlinux)
            TARGET='Arch Linux'; PACKAGE_TYPE='pkg.tar.*'; platform=arch; archive_suffix='-aarch64.tar.gz'
            ;;
        *)
            [[ -n "$version_id" ]] || die '/etc/os-release 缺少 VERSION_ID。' '/etc/os-release does not contain VERSION_ID.'
            case "$distro_id:$version_id" in
                debian:13*) TARGET='Debian 13'; PACKAGE_TYPE=deb; platform=debian13; archive_suffix='-arm64.tar.gz' ;;
                ubuntu:26.04*) TARGET='Ubuntu 26.04'; PACKAGE_TYPE=deb; platform=ubuntu2604; archive_suffix='-arm64.tar.gz' ;;
                fedora:43*) TARGET='Fedora 43'; PACKAGE_TYPE=rpm; platform=fedora43; archive_suffix='-aarch64.tar.gz' ;;
                fedora:44*) TARGET='Fedora 44'; PACKAGE_TYPE=rpm; platform=fedora44; archive_suffix='-aarch64.tar.gz' ;;
                *) die "不支持当前系统 ${system_name}。仅支持 Debian 13、Ubuntu 26.04、Fedora 43/44、Arch Linux。" \
                    "Unsupported system: ${system_name}. Supported systems are Debian 13, Ubuntu 26.04, Fedora 43/44, and Arch Linux." ;;
            esac
            ;;
    esac
    if [[ "$ANLAND_ASSET_KIND" == session ]]; then
        MANIFEST_TARGET="$platform"
        case "$PACKAGE_TYPE" in
            deb) ASSET_PREFIX="$ANLAND_ASSET_FAMILY-$platform-anland-session_"; ASSET_SUFFIX='_arm64.deb' ;;
            rpm) ASSET_PREFIX="$ANLAND_ASSET_FAMILY-$platform-anland-session-"; ASSET_SUFFIX='.aarch64.rpm' ;;
            pkg.tar.*) ASSET_PREFIX="$ANLAND_ASSET_FAMILY-$platform-anland-session-"; ASSET_SUFFIX='-aarch64.pkg.tar.zst' ;;
        esac
    else
        ARCHIVE_TARGET="$platform"
        ARCHIVE_PREFIX="$ANLAND_ASSET_FAMILY-$platform${ANLAND_ARCHIVE_VARIANT:+-$ANLAND_ARCHIVE_VARIANT}-"
        ARCHIVE_SUFFIX="$archive_suffix"
    fi
    if [[ "$ANLAND_ASSET_KIND" == session ]]; then
        log "已识别系统：${system_name} -> ${TARGET}" "Detected system: ${system_name} -> ${TARGET}"
    else
        log "已识别系统: ${system_name} -> ${TARGET}" "Detected system: ${system_name} -> ${TARGET}"
    fi
}
