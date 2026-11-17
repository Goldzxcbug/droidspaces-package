#!/usr/bin/env bash
# shellcheck shell=bash

component_environment_value() {
    local variable="${COMPONENT_ENV_PREFIX}_$1"
    # Assign directly: command substitution would strip trailing newlines from
    # untrusted environment values before the existing validators see them.
    printf -v "$2" '%s' "${!variable-}"
}

require_root() {
    if (( EUID == 0 )); then
        return
    fi

    command -v sudo >/dev/null 2>&1 || die "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."
    local script_path="$ANLAND_INSTALLER_PATH"
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    local status
    if sudo env \
        "${COMPONENT_ENV_PREFIX}_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "${COMPONENT_ENV_PREFIX}_RELEASE_TAG=$RELEASE_TAG" \
        "${COMPONENT_ENV_PREFIX}_WORK_DIR=$WORK_DIR" \
        "${COMPONENT_ENV_PREFIX}_PACKAGE_DIR=$PACKAGE_DIR" \
        "${COMPONENT_ENV_PREFIX}_ARCHIVE_NAME=$ARCHIVE_NAME" \
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
                die "CNB Release 的 ${MANIFEST_NAME} 缺少 ${ARCHIVE_NAME} 的唯一 SHA-256 校验值。" \
                    "The CNB Release ${MANIFEST_NAME} has no unique SHA-256 digest for ${ARCHIVE_NAME}."
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

validate_package_architecture() {
    local -a files=()
    local file package_arch

    case "$PACKAGE_TYPE" in
        deb)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
            for file in "${files[@]}"; do
                package_arch="$(dpkg-deb -f "$file" Architecture)"
                case "$package_arch" in arm64|all) ;; *) return 1 ;; esac
            done
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
            "anland-${COMPONENT_NAME}-packages/${ARCHIVE_TARGET}/"*) ;;
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

    PACKAGE_DIR="$WORK_DIR/anland-${COMPONENT_NAME}-packages/$ARCHIVE_TARGET"
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
    WORK_DIR="$(mktemp -d -t anland-${COMPONENT_NAME}.XXXXXXXX)"

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
    local prepared_work_dir prepared_package_dir prefix="/tmp/anland-${COMPONENT_NAME}."

    prepared_work_dir="$(realpath -e "$PREPARED_WORK_DIR")" || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    prepared_package_dir="$(realpath -e "$PREPARED_PACKAGE_DIR")" || \
        die "预下载包目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_work_dir" == "$prefix"* && "${prepared_work_dir#"$prefix"}" =~ ^[A-Za-z0-9]+$ ]] || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_package_dir" == "$prepared_work_dir/anland-${COMPONENT_NAME}-packages/$ARCHIVE_TARGET" ]] || \
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

install_arch_dependencies() {
    local file dependency name missing internal=' ' metadata
    local -a dependency_files=() dependency_names=()
    mapfile -t dependency_files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
    mapfile -t dependency_names < <(pacman -Qq -p "${dependency_files[@]}")
    local -a dependencies=() missing_names=()
    for file in "${dependency_files[@]}"; do
        metadata="$(bsdtar -xOf "$file" .PKGINFO)" || return 1
        while IFS= read -r dependency; do
            [[ -z "$dependency" ]] || dependencies+=("$dependency")
        done < <(sed -n 's/^depend = //p' <<< "$metadata")
        while IFS= read -r dependency; do internal+="${dependency%%[<>=]*} "; done < <(sed -n 's/^provides = //p' <<< "$metadata")
    done
    for name in "${dependency_names[@]}"; do internal+="$name "; done
    local -a external=()
    for dependency in "${dependencies[@]}"; do
        [[ "$internal" == *" ${dependency%%[<>=]*} "* ]] || external+=("$dependency")
    done
    ((${#external[@]})) || return 0
    missing="$(pacman -T "${external[@]}" || [[ "$?" == 127 ]])" || return 1
    [[ -n "$missing" ]] || return 0
    while IFS= read -r dependency; do missing_names+=("${dependency%%[<>=]*}"); done <<< "$missing"
    pacman -S --needed --noconfirm "${missing_names[@]}"
}

uninstall_package_action() {
    local package
    case "$1" in
        xwayland|xorg-x11-server-Xwayland|xorg-xwayland)
            if other_xwayland_owner >/dev/null; then printf keep; else printf restore; fi
            return 0
            ;;
    esac
    for package in "${REMOVE_PACKAGES[@]}"; do
        if [[ "$1" == "$package" ]]; then printf remove; return 0; fi
    done
    for package in "${RESTORE_PACKAGES[@]}"; do
        if [[ "$1" == "$package" ]]; then printf restore; return 0; fi
    done
    for package in "${AUXILIARY_PACKAGES[@]}"; do
        if [[ "$1" == "$package" ]]; then printf auxiliary; return 0; fi
    done
    return 1
}

uninstall_compositor_deb() {
    local package candidate action
    local -a packages=() package_specs=() remove_packages=()
    command -v apt-cache >/dev/null 2>&1 || die "未找到 apt-cache。" "apt-cache was not found."
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v apt-mark >/dev/null 2>&1 || die "未找到 apt-mark。" "apt-mark was not found."
    if [[ -s "$APT_HOLD_STATE" ]]; then
        mapfile -t packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
        ((${#packages[@]} > 0)) || die "APT hold 清单为空。" "The APT hold list is empty."
    elif dpkg-query -W -f='${db:Status-Status}' "$DEB_RECORD_PACKAGE" 2>/dev/null | grep -Fqx installed; then
        # Older installers did not write KDE-style APT hold lists.
        for package in "${DEB_FALLBACK_PACKAGES[@]}"; do
            if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -Fqx installed; then
                packages+=("$package")
            fi
        done
    else
        rm -f -- "$COMPONENT_STATE_DIR/$COMPONENT_NAME.version" "$COMPONENT_STATE_DIR/$COMPONENT_NAME.packages.tsv"
        log "没有 Anland ${COMPONENT_LABEL} 安装记录。" "No Anland ${COMPONENT_LABEL} installation record was found."
        return 0
    fi
    local -a unhold_packages=()
    local handled=0
    for package in "${packages[@]}"; do
        if ! action="$(uninstall_package_action "$package")"; then
            log "跳过未知软件包：${package}（可能来自更新版本的安装记录）。" \
                "Skipping unknown package: ${package} (it may come from a newer installation record)."
            continue
        fi
        handled=$((handled + 1))
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
    if ((handled == 0 && ${#packages[@]} > 0)); then
        die "安装记录含未知软件包。" "The installation record contains an unknown package."
    fi
    ((${#unhold_packages[@]} == 0)) || apt-mark unhold "${unhold_packages[@]}" >/dev/null
    ((${#package_specs[@]} == 0)) || apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages "${package_specs[@]}"
    ((${#remove_packages[@]} == 0)) || apt-get remove -y --allow-change-held-packages "${remove_packages[@]}"
    rm -f -- "$APT_HOLD_STATE" "$COMPONENT_STATE_DIR/$COMPONENT_NAME.version" \
        "${APT_HOLD_STATE%/*}/packages.tsv"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_compositor_rpm() {
    local dnf_conf="/etc/dnf/dnf.conf" backup stripped transaction package action
    local preserve_xwayland=false
    local -a packages=() restore_packages=() remove_packages=()
    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    [[ -f "$dnf_conf" ]] || die "找不到 DNF 配置。" "The DNF configuration was not found."
    if ! rpm -q "$RPM_RECORD_PACKAGE" >/dev/null 2>&1 && [[ ! -s "$COMPONENT_STATE_DIR/$COMPONENT_NAME.version" ]] &&
        ! grep -Fqx "$DNF_MANAGED_BEGIN" "$dnf_conf"; then
        log "没有 Anland ${COMPONENT_LABEL} 安装记录。" "No Anland ${COMPONENT_LABEL} installation record was found."
        return 0
    fi
    mapfile -t packages < <(rpm -qa --queryformat '%{NAME}\n' | awk -v selected="$(printf '%s\n' "${RPM_UNINSTALL_PACKAGES[@]}")" '
        BEGIN { count = split(selected, names, "\n"); for (i = 1; i <= count; i++) wanted[names[i]] = 1 }
        $0 in wanted
    ' | sort -u)
    local handled=0
    for package in "${packages[@]}"; do
        if ! action="$(uninstall_package_action "$package")"; then
            log "跳过未知软件包：${package}（可能来自更新版本的安装记录）。" \
                "Skipping unknown package: ${package} (it may come from a newer installation record)."
            continue
        fi
        handled=$((handled + 1))
        case "$action" in
            keep) ;;
            remove) remove_packages+=("$package") ;;
            *) restore_packages+=("$package") ;;
        esac
    done
    if ((handled == 0 && ${#packages[@]} > 0)); then
        die "检测到未知软件包。" "An unknown package was detected."
    fi
    if other_xwayland_owner >/dev/null; then preserve_xwayland=true; fi
    backup="$(mktemp -t anland-${COMPONENT_NAME}-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t anland-${COMPONENT_NAME}-uninstall.XXXXXXXX)"
    transaction="$(mktemp -t anland-${COMPONENT_NAME}-uninstall.XXXXXXXX)"
    cp -p -- "$dnf_conf" "$backup"
    if ! rewrite_dnf_config_without_managed_block "$dnf_conf" "$stripped" || \
        ! rewrite_dnf_config_for_package_install "$stripped" "$transaction" "$preserve_xwayland" || \
        ! install -m 0644 "$transaction" "$dnf_conf" || \
        ! { ((${#remove_packages[@]} == 0)) || dnf remove -y --no-autoremove "${remove_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || dnf distro-sync -y --exclude='mesa*' --exclude='systemd*' "${restore_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || dnf reinstall -y --exclude='mesa*' --exclude='systemd*' "${restore_packages[@]}"; }; then
        install -m 0644 "$backup" "$dnf_conf" || true
        rm -f -- "$backup" "$stripped" "$transaction"
        die "卸载 Anland ${COMPONENT_LABEL} 或恢复发行版图形包失败。" "Failed to uninstall Anland ${COMPONENT_LABEL} or restore distribution graphics packages."
    fi
    rm -f -- "$backup" "$stripped" "$transaction" "$COMPONENT_STATE_DIR/$COMPONENT_NAME.version" \
        "${APT_HOLD_STATE%/*}/packages.tsv"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_compositor_arch() {
    local package action backup
    local -a packages=() restore_packages=() remove_packages=()
    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    [[ -f /etc/pacman.conf ]] || die "找不到 pacman.conf。" "pacman.conf was not found."
    if ! pacman -Q "$ARCH_RECORD_PACKAGE" >/dev/null 2>&1 && [[ ! -s "$COMPONENT_STATE_DIR/$COMPONENT_NAME.version" ]]; then
        log "没有 Anland ${COMPONENT_LABEL} 安装记录。" "No Anland ${COMPONENT_LABEL} installation record was found."
        return 0
    fi
    local handled=0 found=0
    for package in "${ARCH_PACKAGES[@]}"; do
        pacman -Q "$package" >/dev/null 2>&1 || continue
        found=$((found + 1))
        if ! action="$(uninstall_package_action "$package")"; then
            log "跳过未知软件包：${package}（可能来自更新版本的安装记录）。" \
                "Skipping unknown package: ${package} (it may come from a newer installation record)."
            continue
        fi
        handled=$((handled + 1))
        [[ "$action" != keep ]] || continue
        packages+=("$package")
        if [[ "$action" == remove ]]; then
            remove_packages+=("$package")
        else
            restore_packages+=("$package")
        fi
    done
    if ((handled == 0 && found > 0)); then
        die "检测到未知软件包。" "An unknown package was detected."
    fi
    backup="$(mktemp -t anland-${COMPONENT_NAME}-uninstall.XXXXXXXX)"
    cp -p -- /etc/pacman.conf "$backup"
    if ! remove_pacman_hold_entries "${packages[@]}" || \
        ! { ((${#remove_packages[@]} == 0)) || pacman -R --noconfirm "${remove_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || pacman -S --noconfirm "${restore_packages[@]}"; }; then
        install -m 0644 "$backup" /etc/pacman.conf || true
        rm -f -- "$backup"
        die "卸载 Anland ${COMPONENT_LABEL} 或恢复发行版图形包失败。" "Failed to uninstall Anland ${COMPONENT_LABEL} or restore distribution graphics packages."
    fi
    rm -f -- "$backup" "$COMPONENT_STATE_DIR/$COMPONENT_NAME.version" \
        "${APT_HOLD_STATE%/*}/packages.tsv"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_compositor() {
    ds_operation_phase uninstall
    case "$PACKAGE_TYPE" in
        deb) uninstall_compositor_deb ;;
        rpm) uninstall_compositor_rpm ;;
        pkg.tar.*) uninstall_compositor_arch ;;
    esac
    log "Anland ${COMPONENT_LABEL} 已卸载，发行版图形包已恢复。" \
        "Anland ${COMPONENT_LABEL} was uninstalled; distribution graphics packages were restored."
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
    dnf_backup="$(mktemp -t anland-${COMPONENT_NAME}-dnf-backup.XXXXXXXX)"
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

    install_arch_dependencies || die "无法安装 Arch 运行时依赖。" "Could not install Arch runtime dependencies."
    log "正在安装 ${#files[@]} 个 Arch 包..." "Installing ${#files[@]} Arch packages..."
    pacman_conf="$(mktemp -t anland-${COMPONENT_NAME}-pacman.XXXXXXXX)"
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

    if ! write_pacman_hold_block "${ARCH_PACKAGES[@]}"; then
        die "无法更新 pacman 锁定配置。" "Unable to update the pacman hold configuration."
    fi
    mapfile -t packages < <(pacman -Qq -p "${files[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 Arch 包名。" "Could not determine the Arch package names."
    printf '  hold: %s\n' "${packages[@]}"
}

main() {
    local archive_version
    detect_language
    parse_arguments "$@"
    detect_target
    check_architecture
    ds_operation_preflight "$COMPONENT_NAME"
    if [[ "$UNINSTALL" == true ]]; then
        require_root "$@"
        ds_operation_begin "$COMPONENT_NAME"
        ds_operation_snapshot_installer_config
        uninstall_compositor
        return
    fi
    require_runtime_dependencies
    if [[ "$PACKAGE_TYPE" == "pkg.tar.*" ]]; then
        command -v bsdtar >/dev/null 2>&1 || die "未找到 bsdtar。" "bsdtar was not found."
    fi
    resolve_release_tag
    if [[ -n "$PREPARED_WORK_DIR" || -n "$PREPARED_PACKAGE_DIR" ]]; then
        use_prepared_packages
    else
        select_download_source
        download_packages
    fi
    require_root "$@"
    ds_operation_begin "$COMPONENT_NAME"
    ds_operation_snapshot_installer_config
    local owner
    if owner="$(other_xwayland_owner)"; then
        die "检测到 Anland $owner；请先卸载该组件以避免覆盖其 patched Xwayland。" \
            "Anland $owner is installed; uninstall it before replacing its patched Xwayland."
    fi

    case "$PACKAGE_TYPE" in
        deb) install_deb_packages ;;
        rpm) install_rpm_packages ;;
        pkg.tar.*) install_arch_packages ;;
    esac

    archive_version="${ARCHIVE_NAME#"$ARCHIVE_PREFIX"}"
    archive_version="${archive_version%"$ARCHIVE_SUFFIX"}"
    rm -f -- "${APT_HOLD_STATE%/*}/packages.tsv"
    record_component_version "$archive_version"
    update_desktop_config
    log "安装完成，patched ${COMPONENT_LABEL}/Xwayland 已锁定。" \
        "Installation complete; patched ${COMPONENT_LABEL}/Xwayland packages are now locked."
}
