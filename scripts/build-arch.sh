#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/lib.sh"

readonly TARGET="${TARGET:-arch}"
readonly SOURCE_VERSION="257.9"
readonly PACKAGING_COMMIT="3ad88a99717b40f1bf3a28eac9cae50fb9977efb"

require_arm64
prepare_output "$TARGET"

log "updating Arch Linux ARM and installing build tooling"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm base-devel git sudo

work_dir="$(mktemp -d -t systemd257-arch.XXXXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
cp -a "$REPO_ROOT/vendor/arch/." "$work_dir/"
cp -a "$PATCH_FILE" "$work_dir/0002-droidspaces-old-kernel-compat.patch"
cp -a "$REPO_ROOT/patches/0002-systemd-257.9-linux-7.0-errno-aliases.patch" \
  "$work_dir/0003-systemd-257.9-linux-7.0-errno-aliases.patch"

if ! id build >/dev/null 2>&1; then
  useradd -m build
fi
printf 'build ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/systemd257-build
chmod 0440 /etc/sudoers.d/systemd257-build
chown -R build:build "$work_dir" "$OUTPUT_DIR"

log "building the complete Arch Linux ARM package family"
runuser -u build -- env MAKEFLAGS="-j$(nproc)" \
  bash -c "cd '$work_dir' && makepkg --syncdeps --noconfirm --nocheck --skippgpcheck"

find "$work_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' \
  -exec cp -a {} "$OUTPUT_DIR/" \;
package_count="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' | wc -l)"
[ "$package_count" -ge 5 ] || die "expected at least 5 pacman packages, got $package_count"

package_by_name() {
  local wanted="$1"
  local candidate
  while IFS= read -r -d '' candidate; do
    if [ "$(LC_ALL=C pacman -Qp "$candidate" | awk '{ print $1 }')" = "$wanted" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print0)
  return 1
}

core_names=(systemd-libs systemd systemd-sysvcompat)
core_packages=()
for package_name in "${core_names[@]}"; do
  package_path="$(package_by_name "$package_name" || true)"
  [ -n "$package_path" ] || die "missing core pacman package: $package_name"
  core_packages+=("$package_path")
done

log "installing the core pacman package family for transaction and runtime validation"
pacman -U --noconfirm "${core_packages[@]}"
pacman -Q "${core_names[@]}"
verify_systemd_257 /usr/lib/systemd/systemd

write_manifest "$TARGET" "$SOURCE_VERSION" \
  "Arch Linux ARM PKGBUILDs $PACKAGING_COMMIT" '*.pkg.tar.*'
log "pacman package family is ready in $OUTPUT_DIR"
