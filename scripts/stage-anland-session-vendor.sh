#!/usr/bin/env bash
#
# stage-anland-session-vendor.sh — stage the vendored sources that
# build-anland-session-package.sh compiles into the anland-session package.
#
# Anland keeps third_party/bubblewrap and third_party/xserver pristine and
# carries its delta in patches/<component>/; this applies those patches to a
# private copy, which is what the Anland Makefile does for its own source
# tarball (target "anlandx"). The packaging build stages it itself so it never
# depends on that target.
#
#   ANLAND_SOURCE_DIR=/path/to/anland ./stage-anland-session-vendor.sh <out>
#
# Produces under <out>:
#   bubblewrap/   bubblewrap v0.11.1 sources + patches/bubblewrap/ applied
#   xserver/      xwayland-24.1 tree + patches/xwayland/ applied, plus
#                 subprojects/xorgproto (the meson fallback for old xorgproto)
#   */ANLAND-SOURCE
#                 "<submodule commit>" + "<patch series md5>" — the exact build
#                 input, reported in the package manifest
set -euo pipefail

readonly ANLAND_SOURCE_DIR="${ANLAND_SOURCE_DIR:?ANLAND_SOURCE_DIR is required}"

OUT_DIR="${1:-${OUT_DIR:-}}"
[[ -n "$OUT_DIR" ]] || { printf 'usage: %s <output-dir>\n' "${0##*/}" >&2; exit 1; }
if [[ "$OUT_DIR" != /* ]]; then
  OUT_DIR="$PWD/${OUT_DIR#./}"
fi

readonly XORGPROTO_VERSION=2024.1
readonly XORGPROTO_SHA256=372225fd40815b8423547f5d890c5debc72e88b91088fbfb13158c20495ccb59
readonly XORGPROTO_URL="https://xorg.freedesktop.org/releases/individual/proto/xorgproto-${XORGPROTO_VERSION}.tar.xz"

log() {
  printf '[anland-vendor] %s\n' "$*"
}

die() {
  printf '[anland-vendor] error: %s\n' "$*" >&2
  exit 1
}

[[ "$ANLAND_SOURCE_DIR" == /* && -d "$ANLAND_SOURCE_DIR" ]] || \
  die "Anland source directory is missing: $ANLAND_SOURCE_DIR"
[[ -f "$ANLAND_SOURCE_DIR/.gitmodules" ]] || \
  die "not an Anland checkout (no .gitmodules): $ANLAND_SOURCE_DIR"

for tool in git patch tar curl sha256sum md5sum; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool is missing: $tool"
done

for required in \
  patches/bubblewrap/config.h \
  patches/bubblewrap/anland-mountinfo-index.patch \
  patches/xwayland/anland-kgsl-glamor.patch; do
  [[ -f "$ANLAND_SOURCE_DIR/$required" ]] || die "missing Anland file: $required"
done

# The build jobs check the Anland source out shallow and detached, which leaves
# the submodules empty; fetch just the two this package compiles.
for submodule in third_party/bubblewrap third_party/xserver; do
  if [[ -f "$ANLAND_SOURCE_DIR/$submodule/.git" || -d "$ANLAND_SOURCE_DIR/$submodule/.git" ]]; then
    continue
  fi
  log "fetching submodule $submodule"
  git -C "$ANLAND_SOURCE_DIR" submodule update --init --depth=1 "$submodule" || \
    die "could not fetch the $submodule submodule"
done

[[ -f "$ANLAND_SOURCE_DIR/third_party/bubblewrap/bubblewrap.c" ]] || \
  die 'third_party/bubblewrap is not checked out'
[[ -f "$ANLAND_SOURCE_DIR/third_party/xserver/hw/xwayland/meson.build" ]] || \
  die 'third_party/xserver is not checked out'

rm -rf -- "$OUT_DIR"
mkdir -p "$OUT_DIR/bubblewrap" "$OUT_DIR/xserver"

# ---- bubblewrap: pristine sources + the anland config.h, patch applied -----
# Only *.c/*.h/COPYING: the tree is compiled with a plain cc (no meson), and
# patches/bubblewrap/config.h stands in for the header meson would generate.
log 'staging bubblewrap'
cp "$ANLAND_SOURCE_DIR"/third_party/bubblewrap/*.c \
   "$ANLAND_SOURCE_DIR"/third_party/bubblewrap/*.h \
   "$ANLAND_SOURCE_DIR/third_party/bubblewrap/COPYING" \
   "$OUT_DIR/bubblewrap/"
cp "$ANLAND_SOURCE_DIR/patches/bubblewrap/config.h" "$OUT_DIR/bubblewrap/"
for patch_file in "$ANLAND_SOURCE_DIR"/patches/bubblewrap/*.patch; do
  patch -d "$OUT_DIR/bubblewrap" -p1 -s --no-backup-if-mismatch < "$patch_file" || \
    die "could not apply $(basename "$patch_file")"
done
grep -Fq 'lookup_mountinfo_line_by_id' "$OUT_DIR/bubblewrap/bind-mount.c" || \
  die 'the bubblewrap mountinfo patch did not apply'
grep -Fq 'anland: mountinfo index fix' "$OUT_DIR/bubblewrap/config.h" || \
  die 'the bubblewrap config.h does not identify the build as anland'

# ---- xserver: the pinned xwayland-24.1 tree, patch applied -----------------
log 'staging xserver'
git -C "$ANLAND_SOURCE_DIR/third_party/xserver" archive --format=tar HEAD | \
  tar -xf - -C "$OUT_DIR/xserver" || die 'could not export the xserver tree'
for patch_file in "$ANLAND_SOURCE_DIR"/patches/xwayland/*.patch; do
  patch -d "$OUT_DIR/xserver" -p1 -s --no-backup-if-mismatch < "$patch_file" || \
    die "could not apply $(basename "$patch_file")"
done

# ---- xorgproto: the meson subproject fallback ------------------------------
# Xwayland needs presentproto >= 1.4, which the distro xorgproto does not
# always provide; when it does, meson prefers the system one and this is
# simply unused.
log 'staging xorgproto'
download_dir="${XORGPROTO_DL_DIR:-$OUT_DIR/dl}"
mkdir -p "$download_dir"
xorgproto_tarball="$download_dir/xorgproto-${XORGPROTO_VERSION}.tar.xz"
if [[ ! -f "$xorgproto_tarball" ]]; then
  curl -fsSL --retry 3 -o "$xorgproto_tarball" "$XORGPROTO_URL" || \
    die "could not download $XORGPROTO_URL"
fi
printf '%s  %s\n' "$XORGPROTO_SHA256" "$xorgproto_tarball" | sha256sum -c --quiet || \
  die "checksum mismatch for xorgproto-${XORGPROTO_VERSION}.tar.xz"
rm -rf -- "$OUT_DIR/xserver/subprojects"
mkdir -p "$OUT_DIR/xserver/subprojects"
tar -C "$OUT_DIR/xserver/subprojects" -xJf "$xorgproto_tarball" || \
  die 'could not extract the xorgproto tarball'
mv "$OUT_DIR/xserver/subprojects/xorgproto-${XORGPROTO_VERSION}" \
   "$OUT_DIR/xserver/subprojects/xorgproto" || \
  die "the xorgproto tarball does not contain xorgproto-${XORGPROTO_VERSION}"
rm -rf -- "$download_dir"

# ---- build input identity --------------------------------------------------
# Same shape as the stamp setupanlandx.sh compares against its own build, so
# the manifest can record exactly which sources and patches went in.
for component in bubblewrap xserver; do
  case "$component" in
    bubblewrap) patch_dir=patches/bubblewrap ;;
    xserver)    patch_dir=patches/xwayland ;;
  esac
  {
    git -C "$ANLAND_SOURCE_DIR/third_party/$component" rev-parse HEAD
    cat "$ANLAND_SOURCE_DIR/$patch_dir"/*.patch | md5sum
  } > "$OUT_DIR/$component/ANLAND-SOURCE" || \
    die "could not record the build input for $component"
done

log "bubblewrap: $(head -1 "$OUT_DIR/bubblewrap/ANLAND-SOURCE")"
log "xserver:    $(head -1 "$OUT_DIR/xserver/ANLAND-SOURCE")"
log "staged in $OUT_DIR"
