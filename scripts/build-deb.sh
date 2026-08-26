#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/lib.sh"

readonly TARGET="${TARGET:-ubuntu2604}"
readonly SOURCE_VERSION="257.13"
readonly DEBIAN_VERSION="257.13-1~deb13u1"
readonly PACKAGE_VERSION="${DEBIAN_VERSION}+droidspaces1"
readonly POOL_URL="https://deb.debian.org/debian/pool/main/s/systemd"
readonly DSC_SHA256="1b3405d671a82d1e20c9d99f52d4336aafe8543b28d04e91b7f1f586d3a667c7"
readonly ORIG_SHA256="1eb7d5f9ff8a426ff880a3cded9ce819613ba8003ac5ddde9eca162f14ddabe7"
readonly DEBIAN_TAR_SHA256="9c6e435d613b996efcdb3b7dd9a4cebaa745333a3f64dc722f3fad646f1fdc1a"

require_arm64
prepare_output "$TARGET"

log "installing Ubuntu build tooling"
apt-get update
apt-get install -y --no-install-recommends \
  build-essential ca-certificates curl devscripts dpkg-dev equivs patch xz-utils

work_dir="$(mktemp -d -t systemd257-deb.XXXXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
cd "$work_dir"

download() {
  local name="$1"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 30 \
    "$POOL_URL/$name" -o "$name"
}

log "downloading Debian systemd $DEBIAN_VERSION source package"
download "systemd_${DEBIAN_VERSION}.dsc"
download "systemd_${SOURCE_VERSION}.orig.tar.gz"
download "systemd_${DEBIAN_VERSION}.debian.tar.xz"

printf '%s  %s\n' "$DSC_SHA256" "systemd_${DEBIAN_VERSION}.dsc" | sha256sum -c -
printf '%s  %s\n' "$ORIG_SHA256" "systemd_${SOURCE_VERSION}.orig.tar.gz" | sha256sum -c -
printf '%s  %s\n' "$DEBIAN_TAR_SHA256" "systemd_${DEBIAN_VERSION}.debian.tar.xz" | sha256sum -c -

dpkg-source -x "systemd_${DEBIAN_VERSION}.dsc" source
cd source
patch --dry-run -p1 < "$PATCH_FILE"
patch -p1 < "$PATCH_FILE"

export DEBFULLNAME="Droidspaces Builder"
export DEBEMAIL="noreply@github.com"
export DEB_BUILD_OPTIONS="parallel=$(nproc) nocheck noautodbgsym"
dch --newversion "$PACKAGE_VERSION" --distribution unstable \
  "Rebuild the complete systemd 257 package family with Android old-kernel compatibility."

log "installing source package build dependencies"
mk-build-deps --install --remove \
  --tool='apt-get -y --no-install-recommends' debian/control

log "building the complete DEB package family"
dpkg-buildpackage -b -uc -us

find "$work_dir" -maxdepth 1 -type f -name '*.deb' ! -name '*-dbgsym_*' \
  -exec cp -a {} "$OUTPUT_DIR/" \;

package_count="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.deb' | wc -l)"
[ "$package_count" -ge 20 ] || die "expected at least 20 DEB packages, got $package_count"

log "installing the core DEB family for transaction and runtime validation"
install -m0755 /dev/stdin /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF

core_names=(
  libsystemd0 libsystemd-shared libudev1 libpam-systemd libnss-systemd
  systemd udev systemd-sysv systemd-timesyncd systemd-resolved
)
core_packages=()
for package_name in "${core_names[@]}"; do
  package_path="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name "${package_name}_*.deb" -print -quit)"
  [ -n "$package_path" ] || die "missing core DEB package: $package_name"
  core_packages+=("$package_path")
done
apt-get install -y --no-install-recommends --allow-downgrades "${core_packages[@]}"
apt-get check
verify_systemd_257 /usr/lib/systemd/systemd

for package_name in "${core_names[@]}"; do
  dpkg-query -W -f='${Package} ${Version} ${Status}\n' "$package_name"
done

write_manifest "$TARGET" "$SOURCE_VERSION" \
  "Debian ${DEBIAN_VERSION} source package rebuilt on Ubuntu 26.04" '*.deb'
log "DEB package family is ready in $OUTPUT_DIR"
