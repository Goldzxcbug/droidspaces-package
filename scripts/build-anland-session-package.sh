#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TARGET="${TARGET:?TARGET is required}"
readonly ANLAND_SOURCE_DIR="${ANLAND_SOURCE_DIR:?ANLAND_SOURCE_DIR is required}"
readonly PACKAGE_VERSION="${PACKAGE_VERSION:-0.1.0}"
readonly SOURCE_COMMIT="${SOURCE_COMMIT:-unknown}"

OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/out/$TARGET}"
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$REPO_ROOT/${OUTPUT_DIR#./}"
fi

log() {
  printf '[anland-session] %s\n' "$*"
}

die() {
  printf '[anland-session] error: %s\n' "$*" >&2
  exit 1
}

[[ "$OUTPUT_DIR" == "$REPO_ROOT/out/"* ]] || \
  die "OUTPUT_DIR must be below $REPO_ROOT/out: $OUTPUT_DIR"
[[ "$PACKAGE_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || \
  die "PACKAGE_VERSION must be numeric (for example 0.1.0)"
[[ "$ANLAND_SOURCE_DIR" == /* && -d "$ANLAND_SOURCE_DIR" ]] || \
  die "Anland source directory is missing: $ANLAND_SOURCE_DIR"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "this workflow must build natively on ARM64, got $(uname -m)" ;;
esac

case "$TARGET" in
  ubuntu2604)
    PACKAGE_FORMAT=deb
    PACKAGE_MANAGER=apt
    XWAYLAND_PACKAGE=xwayland
    ;;
  debian13)
    PACKAGE_FORMAT=deb
    PACKAGE_MANAGER=apt
    XWAYLAND_PACKAGE=xwayland
    ;;
  fedora43|fedora44)
    PACKAGE_FORMAT=rpm
    PACKAGE_MANAGER=dnf
    XWAYLAND_PACKAGE=xorg-x11-server-Xwayland
    ;;
  arch)
    PACKAGE_FORMAT=pkg.tar.zst
    PACKAGE_MANAGER=pacman
    XWAYLAND_PACKAGE=xorg-xwayland
    ;;
  *)
    die "unsupported target: $TARGET"
    ;;
esac

install_build_dependencies() {
  case "$TARGET" in
    ubuntu2604|debian13)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends \
        bash build-essential dpkg-dev \
        dbus-x11 xwayland libx11-6 libxcomposite1 \
        libx11-dev libxcomposite-dev
      ;;
    fedora43|fedora44)
      dnf install -y --setopt=install_weak_deps=False \
        bash gcc binutils rpm-build rpmdevtools \
        dbus-x11 xorg-x11-server-Xwayland libX11 libXcomposite \
        libX11-devel libXcomposite-devel
      ;;
    arch)
      pacman -Syu --noconfirm --needed \
        bash base-devel binutils dbus shadow util-linux \
        libx11 libxcomposite xorg-xwayland
      ;;
  esac
}

prepare_stage() {
  local stage="$1"
  local source_dir="$ANLAND_SOURCE_DIR/anland-session"

  for required in miniwm.c anland-session.sh anland-session.service; do
    [[ -f "$source_dir/$required" ]] || die "missing Anland file: $required"
  done
  [[ -f "$ANLAND_SOURCE_DIR/LICENSE" ]] || die "missing Anland LICENSE"

  mkdir -p "$stage/usr/bin" "$stage/usr/lib/systemd/user"
  mkdir -p "$stage/usr/share/doc/anland-session" \
           "$stage/usr/share/licenses/anland-session"

  cc -O2 -Wall -Wextra -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
    -o "$stage/usr/bin/anland-miniwm" \
    "$source_dir/miniwm.c" -lX11 -lXcomposite
  chmod 0755 "$stage/usr/bin/anland-miniwm"

  install -m 0755 "$source_dir/anland-session.sh" \
    "$stage/usr/bin/anland-session"

  # The source tarball's unit targets the per-user setup.sh layout. A system
  # package installs the executable in /usr/bin instead.
  sed 's|^ExecStart=%h/.local/bin/anland-session$|ExecStart=/usr/bin/anland-session|' \
    "$source_dir/anland-session.service" \
    > "$stage/usr/lib/systemd/user/anland-session.service"
  chmod 0644 "$stage/usr/lib/systemd/user/anland-session.service"
  grep -Fqx 'ExecStart=/usr/bin/anland-session' \
    "$stage/usr/lib/systemd/user/anland-session.service" || \
    die 'failed to adapt systemd user unit for /usr/bin installation'

  install -m 0644 "$ANLAND_SOURCE_DIR/LICENSE" \
    "$stage/usr/share/doc/anland-session/copyright"
  install -m 0644 "$ANLAND_SOURCE_DIR/LICENSE" \
    "$stage/usr/share/licenses/anland-session/LICENSE"
}

build_deb() {
  local stage="$1"
  local control="$stage/DEBIAN/control"
  local package_path="$OUTPUT_DIR/anland-session_${PACKAGE_VERSION}_arm64.deb"

  mkdir -p "$stage/DEBIAN"
  cat > "$control" <<EOF
Package: anland-session
Version: $PACKAGE_VERSION
Section: x11
Priority: optional
Architecture: arm64
Maintainer: Anland Next maintainers <noreply@anland.invalid>
Depends: bash, dbus-x11, xwayland, libx11-6, libxcomposite1
Description: Anland Next rootfs session and Xwayland mini window manager
 Provides the D-Bus/Wayland/Xwayland session launcher and the precompiled
 mini-wm used by Anland Next.
EOF
  chmod 0644 "$control"
  dpkg-deb --build --root-owner-group "$stage" "$package_path" >/dev/null
  printf '%s\n' "$package_path"
}

build_rpm() {
  local stage="$1"
  local rpm_top="$WORK_ROOT/rpmbuild"
  local spec="$rpm_top/SPECS/anland-session.spec"
  local package_path

  mkdir -p "$rpm_top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  tar -C "$stage" -czf "$rpm_top/SOURCES/anland-session.tar.gz" .
  cat > "$spec" <<EOF
%global debug_package %{nil}
Name:           anland-session
Version:        $PACKAGE_VERSION
Release:        1.droidspaces1%{?dist}
Summary:        Anland Next rootfs session and Xwayland mini window manager
License:        GPL-3.0-only
URL:            https://github.com/SuperTurtleDev/anland
Source0:        anland-session.tar.gz
BuildArch:      aarch64
Requires:       bash
Requires:       dbus-x11
Requires:       xorg-x11-server-Xwayland
Requires:       libX11
Requires:       libXcomposite

%description
Provides the D-Bus/Wayland/Xwayland session launcher and the precompiled
mini-wm used by Anland Next.

%prep
%setup -q -c

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a ./* %{buildroot}/

%files
%license /usr/share/licenses/anland-session/LICENSE
/usr/bin/anland-miniwm
/usr/bin/anland-session
/usr/lib/systemd/user/anland-session.service
/usr/share/doc/anland-session/copyright

%changelog
* Tue Sep 15 2026 Anland Next maintainers - $PACKAGE_VERSION-1.droidspaces1
- Initial ARM64 package.
EOF

  rpmbuild -bb --define "_topdir $rpm_top" "$spec" >/dev/null
  package_path="$(find "$rpm_top/RPMS" -type f -name 'anland-session-*.rpm' -print -quit)"
  [[ -n "$package_path" ]] || die 'rpmbuild produced no anland-session RPM'
  cp -a "$package_path" "$OUTPUT_DIR/"
  printf '%s\n' "$OUTPUT_DIR/${package_path##*/}"
}

build_arch() {
  local stage="$1"
  local arch_root="$WORK_ROOT/arch"
  local pkgbuild="$arch_root/PKGBUILD"
  local package_path builder_user builder_home

  mkdir -p "$arch_root"
  tar -C "$stage" -czf "$arch_root/anland-session-${PACKAGE_VERSION}.tar.gz" .
  cat > "$pkgbuild" <<EOF
pkgname=anland-session
pkgver=$PACKAGE_VERSION
pkgrel=1
pkgdesc='Anland Next rootfs session and Xwayland mini window manager'
arch=('aarch64')
license=('GPL-3.0-only')
depends=('bash' 'dbus' 'xorg-xwayland' 'libx11' 'libxcomposite')
source=("anland-session-\${pkgver}.tar.gz")
sha256sums=('SKIP')

package() {
  install -Dm755 "\$srcdir/usr/bin/anland-miniwm" \\
    "\$pkgdir/usr/bin/anland-miniwm"
  install -Dm755 "\$srcdir/usr/bin/anland-session" \\
    "\$pkgdir/usr/bin/anland-session"
  install -Dm644 "\$srcdir/usr/lib/systemd/user/anland-session.service" \\
    "\$pkgdir/usr/lib/systemd/user/anland-session.service"
  install -Dm644 "\$srcdir/usr/share/doc/anland-session/copyright" \\
    "\$pkgdir/usr/share/doc/anland-session/copyright"
  install -Dm644 "\$srcdir/usr/share/licenses/anland-session/LICENSE" \\
    "\$pkgdir/usr/share/licenses/anland-session/LICENSE"
}
EOF

  if (( EUID == 0 )); then
    command -v useradd >/dev/null 2>&1 || die 'useradd is required to run makepkg safely'
    command -v userdel >/dev/null 2>&1 || die 'userdel is required to clean up the Arch builder'
    command -v runuser >/dev/null 2>&1 || die 'runuser is required to run makepkg as a non-root user'
    builder_user="anland-builder-${BASHPID}"
    builder_home="$arch_root/home"
    useradd --system --create-home --user-group \
      --home-dir "$builder_home" --shell /usr/bin/nologin "$builder_user" || \
      die 'could not create the temporary Arch builder user'
    # WORK_ROOT is created mode 0700 for root. Grant only directory traversal
    # so the temporary builder can reach its owned Arch build directory.
    chmod o+x "$WORK_ROOT"
    chown -R "$builder_user:$builder_user" "$arch_root"
    if ! runuser -u "$builder_user" -- env HOME="$builder_home" \
        bash -c 'cd "$1" && exec makepkg --noconfirm --nocheck --skippgpcheck >/dev/null' \
        anland-makepkg "$arch_root"; then
      userdel --remove "$builder_user" >/dev/null 2>&1 || true
      die 'makepkg failed while building the Arch package'
    fi
    userdel --remove "$builder_user" >/dev/null 2>&1 || \
      die 'could not remove the temporary Arch builder user'
  else
    (cd "$arch_root" && makepkg --noconfirm --nocheck --skippgpcheck >/dev/null)
  fi
  package_path="$(find "$arch_root" -maxdepth 1 -type f -name 'anland-session-*.pkg.tar.*' -print -quit)"
  [[ -n "$package_path" ]] || die 'makepkg produced no anland-session package'
  cp -a "$package_path" "$OUTPUT_DIR/"
  printf '%s\n' "$OUTPUT_DIR/${package_path##*/}"
}

probe_installed_runtime() {
  local xwayland_bin xwayland_version

  [[ -x /usr/bin/anland-miniwm ]] || die 'installed miniwm is missing'
  [[ -x /usr/bin/anland-session ]] || die 'installed session launcher is missing'
  [[ -f /usr/lib/systemd/user/anland-session.service ]] || \
    die 'installed user service is missing'
  bash -n /usr/bin/anland-session

  if ldd /usr/bin/anland-miniwm | grep -Fq 'not found'; then
    die 'installed miniwm has unresolved shared libraries'
  fi

  xwayland_bin="$(command -v Xwayland || true)"
  [[ -n "$xwayland_bin" ]] || die 'package manager did not install Xwayland'
  # Anland Next's rootless X path needs the upstream xwayland-shell-v1
  # association protocol and its WL_SURFACE_SERIAL X-side message.
  grep -aFq 'xwayland_shell_v1' "$xwayland_bin" || \
    die "Xwayland lacks xwayland_shell_v1: $xwayland_bin"
  grep -aFq 'WL_SURFACE_SERIAL' "$xwayland_bin" || \
    die "Xwayland lacks WL_SURFACE_SERIAL: $xwayland_bin"
  xwayland_version="$(Xwayland -version 2>&1 || true)"
  log "Xwayland probe: $(printf '%s\n' "$xwayland_version" | sed -n '1p')"

  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify /usr/lib/systemd/user/anland-session.service >/dev/null
  fi
}

install_and_validate() {
  local package_path="$1"
  case "$TARGET" in
    ubuntu2604|debian13)
      (
        cd "$OUTPUT_DIR"
        apt-get install -y --no-install-recommends "./${package_path##*/}"
      )
      dpkg-query -W -f='${Status}\n' anland-session | \
        grep -Fqx 'install ok installed' || die 'dpkg did not install anland-session'
      dpkg-query -W -f='${Status}\n' "$XWAYLAND_PACKAGE" | \
        grep -Fqx 'install ok installed' || die 'apt did not install Xwayland'
      ;;
    fedora43|fedora44)
      dnf install -y --setopt=install_weak_deps=False "$package_path"
      rpm -q anland-session "$XWAYLAND_PACKAGE" >/dev/null
      ;;
    arch)
      pacman -U --noconfirm "$package_path" >/dev/null
      pacman -Q anland-session "$XWAYLAND_PACKAGE" >/dev/null
      ;;
  esac
  probe_installed_runtime
}

install_build_dependencies
rm -rf -- "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
WORK_ROOT="$(mktemp -d -t anland-session-package.XXXXXXXX)"
trap 'rm -rf -- "$WORK_ROOT"' EXIT

STAGE="$WORK_ROOT/stage"
prepare_stage "$STAGE"

case "$PACKAGE_FORMAT" in
  deb) PACKAGE_PATH="$(build_deb "$STAGE")" ;;
  rpm) PACKAGE_PATH="$(build_rpm "$STAGE")" ;;
  pkg.tar.zst) PACKAGE_PATH="$(build_arch "$STAGE")" ;;
esac

install_and_validate "$PACKAGE_PATH"

PACKAGE_NAME="${PACKAGE_PATH##*/}"
BUILD_TIME="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
{
  printf 'format=1\n'
  printf 'target=%s\n' "$TARGET"
  printf 'architecture=%s\n' "$(uname -m)"
  printf 'anland_source_commit=%s\n' "$SOURCE_COMMIT"
  printf 'anland_package_version=%s\n' "$PACKAGE_VERSION"
  printf 'package_manager=%s\n' "$PACKAGE_MANAGER"
  printf 'package=%s\n' "$PACKAGE_NAME"
  printf 'xwayland_package=%s\n' "$XWAYLAND_PACKAGE"
  printf 'xwayland_provided_by_distribution=true\n'
  printf 'xwayland_probe=xwayland_shell_v1,WL_SURFACE_SERIAL\n'
  printf 'build_time=%s\n' "$BUILD_TIME"
} > "$OUTPUT_DIR/manifest.env"

(
  cd "$OUTPUT_DIR"
  sha256sum "$PACKAGE_NAME" manifest.env > SHA256SUMS
)
log "validated $TARGET package: $PACKAGE_NAME"
