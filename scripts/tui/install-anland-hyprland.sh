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
# shellcheck source=lib/anland-compositor-common.sh
source "$ANLAND_LIB_DIR/anland-compositor-common.sh"

readonly COMPONENT_NAME="hyprland"
readonly COMPONENT_LABEL="Hyprland"
readonly COMPONENT_ENV_PREFIX="ANLAND_HYPRLAND"
readonly DEB_RECORD_PACKAGE="hyprland"
readonly RPM_RECORD_PACKAGE="hyprland-anland"
readonly ARCH_RECORD_PACKAGE="hyprland-anland"
readonly -a DEB_FALLBACK_PACKAGES=(hyprland libhyprutils12 libhyprlang2 libhyprgraphics4 libaquamarine14 xwayland)
readonly -a RPM_UNINSTALL_PACKAGES=(hyprland-anland xorg-x11-server-Xwayland)
readonly -a ARCH_PACKAGES=(hyprland-anland hyprpm-anland xorg-xwayland)
readonly -a REMOVE_PACKAGES=(hyprland-anland hyprpm-anland)
readonly -a RESTORE_PACKAGES=(hyprland libhyprutils12 libhyprlang2 libhyprgraphics4 libaquamarine14)
readonly -a AUXILIARY_PACKAGES=()
readonly DNF_EXCLUDED_PACKAGES="hyprland-anland*,hyprpm-anland*,xorg-x11-server-Xwayland*"
readonly -a DNF_STRIP_PACKAGES=('hyprland-anland' 'hyprland-anland*')
readonly -a DNF_XWAYLAND_STRIP_PACKAGES=('xorg-x11-server-Xwayland' 'xorg-x11-server-Xwayland*')
readonly DNF_LEGACY_PACKAGE="hyprland-anland"
# Keep the historical RPM filter and DNF sanitizer distinct from Arch holds.

readonly ANLAND_DISPLAY_NAME="Hyprland"
readonly ANLAND_STATE_NAME="hyprland"
readonly ANLAND_DESKTOP_NAME="hyprland"
readonly ANLAND_FORCE_WAYLAND=true
readonly ANLAND_DESKTOP_UPDATE_SELF=true
readonly ANLAND_ASSET_KIND=archive
readonly ANLAND_ASSET_FAMILY="anland-hyprland"
readonly ANLAND_ARCHIVE_VARIANT=""

readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
component_environment_value RELEASE_REPOSITORY component_repository
readonly RELEASE_REPOSITORY="${component_repository:-${ANLAND_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}}"
unset component_repository
component_environment_value RELEASE_TAG RELEASE_TAG
readonly ROLLING_RELEASE_TAG="anland-${COMPONENT_NAME}-packages"
readonly MANIFEST_NAME="anland-${COMPONENT_NAME}-manifest"
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((2 * 1024 * 1024 * 1024))
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly APT_HOLD_STATE="/var/lib/anland-${COMPONENT_NAME}/apt-holds"
readonly DNF_MANAGED_BEGIN="# BEGIN anland-${COMPONENT_NAME} package holds"
readonly DNF_MANAGED_END="# END anland-${COMPONENT_NAME} package holds"
readonly MESA_DNF_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly MESA_DNF_MANAGED_END="# END install-mesa package holds"
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly COMPONENT_STATE_DIR="${DROIDSPACES_COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}"
readonly DESKTOP_CONFIG="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"

WORK_DIR=""
component_environment_value WORK_DIR PREPARED_WORK_DIR
component_environment_value PACKAGE_DIR PREPARED_PACKAGE_DIR
component_environment_value ARCHIVE_NAME PREPARED_ARCHIVE_NAME
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

trap cleanup EXIT

# Native package transactions preserve profile-specific remove/restore policy.
install_deb_packages() {
    ds_operation_phase packages
    local -a files packages apt_options=()
    local file package apt_releases
    local backports_source=/etc/apt/sources.list.d/droidspaces-hyprland-backports.sources

    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 deb 包。" "No installable deb packages were found."

    if [[ "$ARCHIVE_TARGET" == debian13 ]]; then
        # The Debian 13 bundle is built against the backports runtime libraries.
        apt_releases="$(apt-get indextargets --no-release-info --format '$(RELEASE)' 'Identifier: Packages')"
        if ! grep -Fxq trixie-backports <<< "$apt_releases"; then
            ds_operation_backup "$backports_source"
            cat > "$backports_source" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        fi
        apt-get update
        apt_options+=(-t trixie-backports)
    fi

    log "正在安装 ${#files[@]} 个 deb 包并自动处理依赖..." \
        "Installing ${#files[@]} deb packages and resolving dependencies..."
    apt-get "${apt_options[@]}" install -y --reinstall --allow-downgrades --allow-change-held-packages "${files[@]}"

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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
