#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/lib.sh"

readonly TARGET="${TARGET:?TARGET is required}"
readonly FEDORA_VERSION="${FEDORA_VERSION:?FEDORA_VERSION is required}"
readonly SOURCE_VERSION="257.13"
readonly SOURCE_SHA512="f627e14e19b9ebc1686cad48d674fe7f69964b4d894e0253f9f47eeba3d6feabd1b19de54bdd8d4c2d21993865262830440a809f03d246ffa397320c94c7e46b"
readonly PACKAGING_COMMIT="680c614f89eaff7a5fe4754738dbddafeed852b6"

require_arm64
prepare_output "$TARGET"

log "installing Fedora $FEDORA_VERSION build tooling"
dnf install -y --setopt=install_weak_deps=False \
  ca-certificates curl dnf-plugins-core patch rpm-build rpmdevtools

packaging_dir="$(mktemp -d -t systemd257-rpm-sources.XXXXXXXX)"
work_dir="$(mktemp -d -t systemd257-rpmbuild.XXXXXXXX)"
test_root="$(mktemp -d -t systemd257-rpm-test.XXXXXXXX)"
trap 'rm -rf "$packaging_dir" "$work_dir" "$test_root"' EXIT
cp -a "$REPO_ROOT/vendor/fedora/." "$packaging_dir/"
cp -a "$PATCH_FILE" "$packaging_dir/0003-droidspaces-old-kernel-compat.patch"

log "installing Fedora source package build dependencies"
dnf builddep -y --setopt=install_weak_deps=False \
  --define "_sourcedir $packaging_dir" "$packaging_dir/systemd.spec"

log "downloading systemd $SOURCE_VERSION source"
curl -fL --retry 5 --retry-all-errors --connect-timeout 30 \
  "https://github.com/systemd/systemd/archive/v${SOURCE_VERSION}/systemd-${SOURCE_VERSION}.tar.gz" \
  -o "$packaging_dir/systemd-${SOURCE_VERSION}.tar.gz"
printf '%s  %s\n' "$SOURCE_SHA512" "$packaging_dir/systemd-${SOURCE_VERSION}.tar.gz" | sha512sum -c -

mkdir -p "$work_dir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
log "building the complete Fedora RPM package family"
rpmbuild -bb --nocheck \
  --define "_topdir $work_dir" \
  --define "_sourcedir $packaging_dir" \
  --define "release_override 0.droidspaces1" \
  --define "debug_package %{nil}" \
  "$packaging_dir/systemd.spec"

find "$work_dir/RPMS" -type f -name '*.rpm' -exec cp -a {} "$OUTPUT_DIR/" \;
package_count="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.rpm' | wc -l)"
[ "$package_count" -ge 15 ] || die "expected at least 15 RPM packages, got $package_count"

rpm_by_name() {
  local wanted="$1"
  local candidate
  while IFS= read -r -d '' candidate; do
    if [ "$(rpm -qp --qf '%{NAME}' "$candidate")" = "$wanted" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.rpm' -print0)
  return 1
}

core_names=(systemd systemd-libs systemd-shared systemd-pam systemd-udev systemd-networkd systemd-resolved)
core_packages=()
for package_name in "${core_names[@]}"; do
  package_path="$(rpm_by_name "$package_name" || true)"
  [ -n "$package_path" ] || die "missing core RPM package: $package_name"
  core_packages+=("$package_path")
done

log "installing the core RPM family into a clean Fedora $FEDORA_VERSION root"
dnf --installroot "$test_root" --releasever "$FEDORA_VERSION" install -y \
  --setopt=install_weak_deps=False --setopt=keepcache=False "${core_packages[@]}"
rpm --root "$test_root" -q "${core_names[@]}"
verify_systemd_257 "$test_root/usr/lib/systemd/systemd"

write_manifest "$TARGET" "$SOURCE_VERSION" \
  "Fedora dist-git $PACKAGING_COMMIT rebuilt on Fedora $FEDORA_VERSION" '*.rpm'
log "RPM package family is ready in $OUTPUT_DIR"
