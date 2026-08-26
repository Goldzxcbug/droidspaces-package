#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PATCH_FILE="$REPO_ROOT/patches/0001-droidspaces-old-kernel-compat.patch"

log() {
  printf '[systemd257] %s\n' "$*"
}

die() {
  printf '[systemd257] error: %s\n' "$*" >&2
  exit 1
}

require_arm64() {
  case "$(uname -m)" in
    aarch64|arm64) ;;
    *) die "the package matrix must run natively on ARM64, got $(uname -m)" ;;
  esac
}

prepare_output() {
  local target="$1"
  OUTPUT_DIR="$REPO_ROOT/out/$target"
  export OUTPUT_DIR
  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"
}

verify_systemd_257() {
  local command_path="$1"
  local version_line

  version_line="$($command_path --version | sed -n '1p')"
  printf '%s\n' "$version_line"
  case "$version_line" in
    'systemd 257'*) ;;
    *) die "runtime version is not systemd 257: $version_line" ;;
  esac
}

write_manifest() {
  local target="$1"
  local source_version="$2"
  local packaging_source="$3"
  local pattern="$4"
  local architecture package_count package
  local -a packages=()

  architecture="$(uname -m)"
  while IFS= read -r -d '' package; do
    packages+=("$package")
  done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name "$pattern" -print0 | sort -z)
  package_count="${#packages[@]}"
  [ "$package_count" -gt 0 ] || die "no packages were produced for $target"

  {
    printf 'format=1\n'
    printf 'target=%s\n' "$target"
    printf 'architecture=%s\n' "$architecture"
    printf 'systemd_source_version=%s\n' "$source_version"
    printf 'packaging_source=%s\n' "$packaging_source"
    printf 'compat_patch=0001-droidspaces-old-kernel-compat.patch\n'
    printf 'package_count=%s\n' "$package_count"
    for package in "${packages[@]}"; do
      printf 'package=%s\n' "$(basename "$package")"
    done
  } > "$OUTPUT_DIR/manifest.env"

  (
    cd "$OUTPUT_DIR"
    sha256sum "${packages[@]##*/}" manifest.env > SHA256SUMS
  )
}
