#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TARGET="${TARGET:?TARGET is required}"
readonly ANLAND_SOURCE_DIR="${ANLAND_SOURCE_DIR:?ANLAND_SOURCE_DIR is required}"
# The patched bubblewrap and Xwayland sources, staged by
# stage-anland-session-vendor.sh (the same job, before this one runs).
readonly ANLAND_VENDOR_DIR="${ANLAND_VENDOR_DIR:?ANLAND_VENDOR_DIR is required}"
readonly PACKAGE_VERSION="${PACKAGE_VERSION:-0.1.0}"
readonly SOURCE_COMMIT="${SOURCE_COMMIT:-unknown}"
# Where the session resolves the private Xwayland and bwrap builds from; the
# session script prepends this to PATH, so the distribution binaries it falls
# back on are never replaced on disk.
readonly ANLAND_LIBEXEC_DIR=/usr/lib/anland

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

# For use inside functions whose stdout is captured by the caller.
warn() {
  printf '[anland-session] %s\n' "$*" >&2
}

comma_join() {
  local joined="" item
  for item in "$@"; do
    joined="${joined}${joined:+, }${item}"
  done
  printf '%s\n' "$joined"
}

[[ "$OUTPUT_DIR" == "$REPO_ROOT/out/"* ]] || \
  die "OUTPUT_DIR must be below $REPO_ROOT/out: $OUTPUT_DIR"
[[ "$PACKAGE_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || \
  die "PACKAGE_VERSION must be numeric (for example 0.1.0)"
[[ "$ANLAND_SOURCE_DIR" == /* && -d "$ANLAND_SOURCE_DIR" ]] || \
  die "Anland source directory is missing: $ANLAND_SOURCE_DIR"
[[ "$ANLAND_VENDOR_DIR" == /* && -d "$ANLAND_VENDOR_DIR" ]] || \
  die "Anland vendor directory is missing: $ANLAND_VENDOR_DIR"
[[ -f "$ANLAND_VENDOR_DIR/bubblewrap/bubblewrap.c" ]] || \
  die "the staged bubblewrap tree is missing: $ANLAND_VENDOR_DIR/bubblewrap"
[[ -f "$ANLAND_VENDOR_DIR/xserver/hw/xwayland/meson.build" ]] || \
  die "the staged xserver tree is missing: $ANLAND_VENDOR_DIR/xserver"
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

# Xwayland's build dependencies come from the distribution's own list (the
# vendored tree is xserver's xwayland-24.1, so the -dev versions match the
# libraries that end up linked). That needs the source index, which is off by
# default; the deb-src/dnf-source entries are index metadata only — no
# distribution source code is fetched and no system package is replaced.
enable_apt_source_packages() {
  if grep -rqsE '^Types:.*deb-src|^[[:space:]]*deb-src ' \
      /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    return 0
  fi
  local suite_file
  for suite_file in /etc/apt/sources.list.d/ubuntu.sources \
                    /etc/apt/sources.list.d/debian.sources; do
    [ -f "$suite_file" ] || continue
    log "enabling deb-src entries in $suite_file"
    sed -i 's/^Types: deb$/Types: deb deb-src/' "$suite_file"
  done
  if [ -f /etc/apt/sources.list ] && \
      ! grep -qE '^[[:space:]]*deb-src ' /etc/apt/sources.list; then
    sed -i 's|^deb \(.*\)$|deb \1\ndeb-src \1|' /etc/apt/sources.list
  fi
  apt-get update
}

enable_dnf_source_packages() {
  if dnf repolist --enabled 2>/dev/null | grep -q -- '-source'; then
    return 0
  fi
  # Fedora splits its source repos (fedora-source, updates-source, …) and the
  # Xwayland BuildRequires can live in any of them, so enable every one the
  # image knows about rather than guessing a name.
  local repo
  local -a repos=()
  mapfile -t repos < <(grep -rhoE '^\[[^]]*-source\]' /etc/yum.repos.d 2>/dev/null | \
    tr -d '[]' | sort -u)
  [ "${#repos[@]}" -gt 0 ] || die 'no *-source repositories are configured'
  for repo in "${repos[@]}"; do
    log "enabling $repo"
    dnf config-manager --set-enabled "$repo" >/dev/null 2>&1 || \
      dnf config-manager setopt "$repo.enabled=1" >/dev/null 2>&1 || \
      die "could not enable $repo"
  done
  dnf repolist --enabled | grep -q -- '-source' || \
    die 'no *-source repository ended up enabled'
}

install_build_dependencies() {
  case "$TARGET" in
    ubuntu2604|debian13)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends \
        bash build-essential dpkg-dev \
        dbus-x11 xwayland libx11-6 libxcomposite1 \
        libx11-dev libxcomposite-dev \
        meson ninja-build pkg-config patch ca-certificates \
        libcap-dev
      enable_apt_source_packages
      log 'installing the Xwayland build dependencies'
      apt-get build-dep -y xwayland || die 'apt-get build-dep xwayland failed'
      ;;
    fedora43|fedora44)
      dnf install -y --setopt=install_weak_deps=False \
        bash gcc binutils rpm-build rpmdevtools \
        dbus-x11 xorg-x11-server-Xwayland libX11 libXcomposite \
        libX11-devel libXcomposite-devel \
        meson ninja-build pkgconf-pkg-config patch ca-certificates \
        libcap-devel dnf-plugins-core
      enable_dnf_source_packages
      log 'installing the Xwayland build dependencies'
      dnf builddep -y --setopt=install_weak_deps=False \
        xorg-x11-server-Xwayland || \
        die 'dnf builddep xorg-x11-server-Xwayland failed'
      ;;
    arch)
      # Arch has no builddep equivalent, so the Xwayland list is spelled out:
      # everything hw/xwayland needs that has no meson fallback (xtrans,
      # libxcvt, libxkbfile, libxfont2, wayland-protocols).
      pacman -Syu --noconfirm --needed \
        bash base-devel binutils dbus shadow util-linux \
        libx11 libxcomposite xorg-xwayland \
        meson ninja pkgconf patch ca-certificates libcap \
        xorgproto xtrans pixman libxkbfile libxfont2 libxcvt \
        wayland wayland-protocols libxshmfence libdrm libepoxy mesa libgcrypt
      ;;
  esac
}

# ---- vendored components ---------------------------------------------------
# bubblewrap and Xwayland are built from the tree staged by
# stage-anland-session-vendor.sh, which has the Anland patches applied.

bwrap_sandbox_selfcheck() {
  local bwrap="$1" output
  # The distribution bubblewrap sizes its mountinfo index as
  # xcalloc(max_id + 1). KernelSU+SuSFS counts every mount a KernelSU-domain
  # process creates from 2e9, i.e. 16 GB, which is what makes glycin's
  # sandboxed loaders die under the RLIMIT_AS they set before exec'ing bwrap
  # (patches/bubblewrap/README.anland.md). Starting a sandbox under a 2 GB cap
  # is the on-device regression test — the patched lookup is proportional to
  # the mount count instead. Both lib/ and lib64/ get a symlink so the dynamic
  # loader is reachable whichever layout the distribution uses.
  #
  # A CI job container runs as root without CAP_SYS_ADMIN and without
  # unprivileged user namespaces, so this cannot pass there; it reports why
  # instead of failing, and the patch itself is asserted on the staged source.
  if output="$( ( ulimit -v 2000000 && \
        "$bwrap" --unshare-all --ro-bind /usr /usr \
          --symlink usr/lib /lib --symlink usr/lib64 /lib64 --dev /dev \
          /usr/bin/true ) 2>&1 )"; then
    return 0
  fi
  printf '%s\n' "$output" >&2
  return 1
}

build_bwrap() {
  local output="$1"
  local src="$ANLAND_VENDOR_DIR/bubblewrap"

  log 'building the patched bubblewrap'
  cc -O2 -Wall -D_GNU_SOURCE -I "$src" -o "$output" "$src"/*.c -lcap
  chmod 0755 "$output"

  if ! bwrap_sandbox_selfcheck "$output"; then
    log 'note: the sandbox self-check could not run here (see the output above) — the build container grants neither CAP_SYS_ADMIN nor unprivileged user namespaces'
  fi
  "$output" --version | grep -Fq 'anland' || \
    die 'the built bubblewrap is not identified as the anland build'
  log "bwrap: $("$output" --version)"
}

build_xwayland() {
  local output="$1"
  local src="$ANLAND_VENDOR_DIR/xserver"
  local build_src="$WORK_ROOT/xserver"
  local version

  log 'building the patched Xwayland (this takes a few minutes)'
  rm -rf -- "$build_src"
  cp -a "$src" "$build_src"
  (
    cd "$build_src"
    # The package is installed below /usr even though its private Xwayland
    # binary lives in /usr/lib/anland.  Keep Xwayland's compiled-in helper and
    # data paths aligned with the distribution: xkbcomp is /usr/bin/xkbcomp
    # and xkeyboard-config lives below /usr/share/X11/xkb.  Meson's default
    # /usr/local prefix makes the server look for both under /usr/local and
    # prevents it from starting on Fedora (and other normal RootFS layouts).
    meson setup build --prefix=/usr -Dxvfb=false
    meson compile -C build
  ) || die 'the Xwayland build failed'
  [ -x "$build_src/build/hw/xwayland/Xwayland" ] || \
    die 'the Xwayland build produced no binary'
  install -m 0755 "$build_src/build/hw/xwayland/Xwayland" "$output"

  # Guard the two paths that caused the Fedora 44 regression.  The server
  # invokes xkbcomp through its compiled-in prefix and loads xkeyboard-config
  # from the same prefix, so a /usr/local build cannot run in our RootFSes.
  grep -aFq '/usr/share/X11/xkb' "$output" || \
    die 'the built Xwayland has no /usr/share XKB data path'
  if grep -aFq '/usr/local/share/X11/xkb' "$output" || \
     grep -aFq '/usr/local/bin' "$output"; then
    die 'the built Xwayland still embeds /usr/local runtime paths'
  fi

  version="$("$output" -version 2>&1 || true)"
  printf '%s\n' "$version" | grep -Fq 'Xwayland' || \
    die 'the built Xwayland does not run'
  log "Xwayland: $(printf '%s\n' "$version" | sed -n '1p')"
}

# The meson-built Xwayland links whatever libraries this distribution provided,
# which is not something to hard-code: resolve the shared libraries of the
# packaged binaries back to the packages that own them and declare those.
# (rpmbuild derives the same Requires from the ELF headers on Fedora, so this
# only feeds the deb and pacman metadata.)
runtime_dependency_packages() {
  local stage="$1"
  local file package

  {
    ldd "$stage/usr/bin/anland-miniwm" 2>/dev/null
    ldd "$stage/usr/lib/anland/Xwayland" 2>/dev/null
    ldd "$stage/usr/lib/anland/bwrap" 2>/dev/null
  } | awk '/=> \//{ print $3 }' | sort -u | while IFS= read -r file; do
    [ -n "$file" ] || continue
    # ldd reports the path the loader opened; on Debian/Ubuntu that is the /lib
    # alias while the package database records the merged-usr path.
    file="$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")"
    [ -n "$file" ] || continue
    # Every branch stays non-fatal: an unresolved file is skipped, not fatal,
    # and a failing lookup must not take the loop down with it.
    case "$PACKAGE_MANAGER" in
      # dpkg -S prints "<package>[:<arch>]: <path>" (several names on
      # diversions), so take the first name before the colon.
      apt)    package="$(dpkg -S "$file" 2>/dev/null | head -n1 | cut -d: -f1 | cut -d, -f1)" || true ;;
      dnf)    package="$(rpm -qf --qf '%{NAME}' "$file" 2>/dev/null)" || true ;;
      pacman) package="$(pacman -Qoq "$file" 2>/dev/null)" || true ;;
    esac
    if [ -z "$package" ]; then
      # e.g. a file installed by the Mesa for Android archive, which no
      # distribution package owns
      warn "skipping $file — no distribution package owns it"
      continue
    fi
    printf '%s\n' "$package" | tr ' ' '\n'
  done | sort -u
}

# The session resolves both Xwayland and bwrap through PATH: it exports
# APP_PATH into its own environment and into the systemd user manager, which is
# also what glycin's `bwrap` lookup sees. Upstream prepends ~/.local/bin there
# for the on-device build; a system package points at its private directory
# instead, leaving the distribution binaries in place as the fallback.
adapt_session_path() {
  local session_script="$1"
  local anchor="printf 'PATH=%s\\n' \"\$APP_PATH\" >> \"\$ENVF\""
  local temporary="$session_script.new"
  local mode

  grep -Fqx "$anchor" "$session_script" || \
    die 'the Anland session script has no PATH publication line to adapt'
  # awk writes through a shell redirect, so the replacement would come out mode
  # 0644 and the launcher has to stay executable.
  mode="$(stat -c '%a' "$session_script")" || \
    die "cannot read the mode of $session_script"
  # The anchor goes through the environment: awk -v would expand its \n escape.
  if ! ANLAND_SESSION_ANCHOR="$anchor" \
      awk -v prefix="$ANLAND_LIBEXEC_DIR" '
        $0 == ENVIRON["ANLAND_SESSION_ANCHOR"] && !inserted {
          print "APP_PATH=\"" prefix ":$APP_PATH\""
          inserted = 1
        }
        { print }
        END { exit inserted ? 0 : 1 }
      ' "$session_script" > "$temporary"; then
    rm -f -- "$temporary"
    die 'failed to adapt the session PATH for the packaged binaries'
  fi
  mv -f -- "$temporary" "$session_script"
  chmod "$mode" "$session_script"

  grep -Fq "APP_PATH=\"$ANLAND_LIBEXEC_DIR:\$APP_PATH\"" "$session_script" || \
    die 'the session PATH adaptation did not take'
  bash -n "$session_script" || die 'the adapted session script is not valid bash'
  [[ -x "$session_script" ]] || \
    die 'the adapted session script lost its executable bit'
}

prepare_stage() {
  local stage="$1"
  local source_dir="$ANLAND_SOURCE_DIR/anland-session"

  for required in miniwm.c anland-session.sh anland-session.service; do
    [[ -f "$source_dir/$required" ]] || die "missing Anland file: $required"
  done
  [[ -f "$ANLAND_SOURCE_DIR/LICENSE" ]] || die "missing Anland LICENSE"

  mkdir -p "$stage/usr/bin" "$stage/usr/lib/systemd/user"
  mkdir -p "$stage$ANLAND_LIBEXEC_DIR"
  mkdir -p "$stage/usr/share/doc/anland-session" \
           "$stage/usr/share/licenses/anland-session"

  cc -O2 -Wall -Wextra -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
    -o "$stage/usr/bin/anland-miniwm" \
    "$source_dir/miniwm.c" -lX11 -lXcomposite
  chmod 0755 "$stage/usr/bin/anland-miniwm"

  build_bwrap "$stage$ANLAND_LIBEXEC_DIR/bwrap"
  build_xwayland "$stage$ANLAND_LIBEXEC_DIR/Xwayland"

  # Xwayland is built 'debugoptimized' (-O2 -g), so it carries its debug
  # information. rpmbuild and makepkg strip their payloads, dpkg-deb does not,
  # which left the .deb three times the size of the other two; strip here so
  # all three formats ship the same binaries.
  local binary
  for binary in "$stage/usr/bin/anland-miniwm" \
                "$stage$ANLAND_LIBEXEC_DIR/Xwayland" \
                "$stage$ANLAND_LIBEXEC_DIR/bwrap"; do
    strip "$binary" || die "could not strip $(basename "$binary")"
  done

  install -m 0755 "$source_dir/anland-session.sh" \
    "$stage/usr/bin/anland-session"
  adapt_session_path "$stage/usr/bin/anland-session"

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
Depends: bash, dbus-x11, x11-xkb-utils, xwayland, libpam-systemd, $(comma_join "${RUNTIME_PACKAGES[@]}")
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
Requires:       xkbcomp
Requires:       libX11
Requires:       libXcomposite
# pam_systemd.so: without it the systemd user manager exits with
# "XDG_RUNTIME_DIR is not set" and the session service never starts.
Requires:       systemd-pam

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
/usr/lib/anland/Xwayland
/usr/lib/anland/bwrap
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
  # Arch Linux ARM ships makepkg.conf with PKGEXT='.pkg.tar.xz' while x86_64
  # Arch uses '.pkg.tar.zst'. The release assets and the Anland Next installer
  # both expect the zstd name, so pin the extension. makepkg preserves PKGEXT
  # from the environment and re-applies it after sourcing makepkg.conf.
  local arch_pkgext=".$PACKAGE_FORMAT"

  mkdir -p "$arch_root"
  tar -C "$stage" -czf "$arch_root/anland-session-${PACKAGE_VERSION}.tar.gz" .
  cat > "$pkgbuild" <<EOF
pkgname=anland-session
pkgver=$PACKAGE_VERSION
pkgrel=1
pkgdesc='Anland Next rootfs session and Xwayland mini window manager'
arch=('aarch64')
license=('GPL-3.0-only')
depends=('bash' 'dbus' 'xorg-xwayland' 'xorg-xkbcomp' 'systemd' $RUNTIME_DEPENDS_ARCH)
source=("anland-session-\${pkgver}.tar.gz")
sha256sums=('SKIP')

package() {
  install -Dm755 "\$srcdir/usr/bin/anland-miniwm" \\
    "\$pkgdir/usr/bin/anland-miniwm"
  install -Dm755 "\$srcdir/usr/bin/anland-session" \\
    "\$pkgdir/usr/bin/anland-session"
  install -Dm755 "\$srcdir/usr/lib/anland/Xwayland" \\
    "\$pkgdir/usr/lib/anland/Xwayland"
  install -Dm755 "\$srcdir/usr/lib/anland/bwrap" \\
    "\$pkgdir/usr/lib/anland/bwrap"
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
    if ! runuser -u "$builder_user" -- \
        env HOME="$builder_home" PKGEXT="$arch_pkgext" \
        bash -c 'cd "$1" && exec makepkg --noconfirm --nocheck --skippgpcheck >/dev/null' \
        anland-makepkg "$arch_root"; then
      userdel --remove "$builder_user" >/dev/null 2>&1 || true
      die 'makepkg failed while building the Arch package'
    fi
    userdel --remove "$builder_user" >/dev/null 2>&1 || \
      die 'could not remove the temporary Arch builder user'
  else
    (cd "$arch_root" && PKGEXT="$arch_pkgext" \
      makepkg --noconfirm --nocheck --skippgpcheck >/dev/null)
  fi
  package_path="$(find "$arch_root" -maxdepth 1 -type f -name 'anland-session-*.pkg.tar.*' -print -quit)"
  [[ -n "$package_path" ]] || die 'makepkg produced no anland-session package'
  [[ "$package_path" == *"$arch_pkgext" ]] || \
    die "makepkg produced ${package_path##*/} instead of a ${arch_pkgext#.} package"
  cp -a "$package_path" "$OUTPUT_DIR/"
  printf '%s\n' "$OUTPUT_DIR/${package_path##*/}"
}

probe_installed_runtime() {
  local xwayland_bin xwayland_version binary session_path

  [[ -x /usr/bin/anland-miniwm ]] || die 'installed miniwm is missing'
  [[ -x /usr/bin/anland-session ]] || die 'installed session launcher is missing'
  [[ -f /usr/lib/systemd/user/anland-session.service ]] || \
    die 'installed user service is missing'
  [[ -x "$ANLAND_LIBEXEC_DIR/Xwayland" ]] || die 'installed Xwayland is missing'
  [[ -x "$ANLAND_LIBEXEC_DIR/bwrap" ]] || die 'installed bwrap is missing'
  command -v xkbcomp >/dev/null 2>&1 || \
    die 'installed runtime has no xkbcomp for Xwayland keyboard setup'
  bash -n /usr/bin/anland-session

  for binary in /usr/bin/anland-miniwm "$ANLAND_LIBEXEC_DIR/Xwayland" \
                "$ANLAND_LIBEXEC_DIR/bwrap"; do
    if ldd "$binary" | grep -Fq 'not found'; then
      die "$(basename "$binary") has unresolved shared libraries"
    fi
  done

  # The session exports a PATH that starts with the package-private directory,
  # so that is what both its own Xwayland launch and glycin's `bwrap` lookup
  # must resolve to — never the distribution builds.
  session_path="$ANLAND_LIBEXEC_DIR:$PATH"
  xwayland_bin="$(PATH="$session_path" command -v Xwayland || true)"
  [[ "$xwayland_bin" == "$ANLAND_LIBEXEC_DIR/Xwayland" ]] || \
    die "the session PATH does not resolve Xwayland to the packaged build: ${xwayland_bin:-none}"
  [[ "$(PATH="$session_path" command -v bwrap || true)" == "$ANLAND_LIBEXEC_DIR/bwrap" ]] || \
    die 'the session PATH does not resolve bwrap to the packaged build'

  # Anland Next's rootless X path needs the upstream xwayland-shell-v1
  # association protocol and its WL_SURFACE_SERIAL X-side message; the patched
  # build must keep both.
  grep -aFq 'xwayland_shell_v1' "$xwayland_bin" || \
    die "Xwayland lacks xwayland_shell_v1: $xwayland_bin"
  grep -aFq 'WL_SURFACE_SERIAL' "$xwayland_bin" || \
    die "Xwayland lacks WL_SURFACE_SERIAL: $xwayland_bin"
  xwayland_version="$("$xwayland_bin" -version 2>&1 || true)"
  log "Xwayland probe: $(printf '%s\n' "$xwayland_version" | sed -n '1p')"

  if ! bwrap_sandbox_selfcheck "$ANLAND_LIBEXEC_DIR/bwrap"; then
    log 'note: the installed bwrap could not start a sandbox here (see the output above) — same container restriction as at build time'
  fi
  "$ANLAND_LIBEXEC_DIR/bwrap" --version | grep -Fq 'anland' || \
    die 'installed bwrap is not the anland build'
  log "bwrap probe: $("$ANLAND_LIBEXEC_DIR/bwrap" --version)"

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
      # The package is built locally and is intentionally not signed. Keep
      # the system pacman configuration unchanged and allow this one local
      # installation to proceed with a temporary configuration instead.
      local pacman_conf="$WORK_ROOT/pacman.conf"
      [[ -r /etc/pacman.conf ]] || die 'cannot read /etc/pacman.conf'
      cp /etc/pacman.conf "$pacman_conf"
      if grep -Eq '^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=' \
        "$pacman_conf"; then
        sed -i -E \
          's/^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=.*/LocalFileSigLevel = Optional/' \
          "$pacman_conf"
      elif grep -qE '^\[options\][[:space:]]*$' "$pacman_conf"; then
        sed -i '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' \
          "$pacman_conf"
      else
        die 'pacman.conf has no [options] section'
      fi
      pacman --config "$pacman_conf" -U --noconfirm "$package_path" >/dev/null
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

log 'resolving the runtime dependencies of the packaged binaries'
mapfile -t RUNTIME_PACKAGES < <(runtime_dependency_packages "$STAGE")
[[ "${#RUNTIME_PACKAGES[@]}" -gt 0 ]] || \
  die 'could not resolve the runtime dependencies of the packaged binaries'
RUNTIME_DEPENDS_ARCH="$(printf "'%s' " "${RUNTIME_PACKAGES[@]}")"
log "runtime packages: ${RUNTIME_PACKAGES[*]}"

case "$PACKAGE_FORMAT" in
  deb) PACKAGE_PATH="$(build_deb "$STAGE")" ;;
  rpm) PACKAGE_PATH="$(build_rpm "$STAGE")" ;;
  pkg.tar.zst) PACKAGE_PATH="$(build_arch "$STAGE")" ;;
esac

install_and_validate "$PACKAGE_PATH"

PACKAGE_NAME="${PACKAGE_PATH##*/}"
BUILD_TIME="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
# "<vendor commit>/<patch series md5>" — the exact input each vendored
# component was built from (same identity the Anland setup script stamps).
vendor_source_identity() {
  awk 'NR == 1 { commit = $1 } NR == 2 { print commit "/" $1 }' "$1"
}
{
  printf 'format=1\n'
  printf 'target=%s\n' "$TARGET"
  printf 'architecture=%s\n' "$(uname -m)"
  printf 'anland_source_commit=%s\n' "$SOURCE_COMMIT"
  printf 'anland_package_version=%s\n' "$PACKAGE_VERSION"
  printf 'package_manager=%s\n' "$PACKAGE_MANAGER"
  printf 'package=%s\n' "$PACKAGE_NAME"
  printf 'xwayland_package=%s\n' "$XWAYLAND_PACKAGE"
  printf 'xwayland_provided_by_distribution=false\n'
  printf 'xwayland_source=%s\n' \
    "$(vendor_source_identity "$ANLAND_VENDOR_DIR/xserver/ANLAND-SOURCE")"
  printf 'bwrap_source=%s\n' \
    "$(vendor_source_identity "$ANLAND_VENDOR_DIR/bubblewrap/ANLAND-SOURCE")"
  printf 'xwayland_probe=xwayland_shell_v1,WL_SURFACE_SERIAL\n'
  printf 'build_time=%s\n' "$BUILD_TIME"
} > "$OUTPUT_DIR/manifest.env"

(
  cd "$OUTPUT_DIR"
  sha256sum "$PACKAGE_NAME" manifest.env > SHA256SUMS
)
log "validated $TARGET package: $PACKAGE_NAME"
