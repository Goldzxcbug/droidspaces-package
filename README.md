# systemd 257 package families

This repository builds package-manager-owned systemd 257 package families for
ARM64 Android container root filesystems. It is a test repository for Ubuntu
26.04, Fedora 43, Fedora 44, and Arch Linux ARM.

The build does not copy files directly over `/`. Each target reuses the native
distribution packaging definition and produces the complete binary package
family from one systemd source build:

| Target | systemd source | Native packaging source |
| --- | --- | --- |
| Ubuntu 26.04 | 257.13 | Debian `257.13-1~deb13u1` source package |
| Fedora 43 | 257.13 | Fedora dist-git commit `680c614f89eaff7a5fe4754738dbddafeed852b6` |
| Fedora 44 | 257.13 | Fedora dist-git commit `680c614f89eaff7a5fe4754738dbddafeed852b6` |
| Arch Linux ARM | 257.9 | Arch Linux ARM commit `3ad88a99717b40f1bf3a28eac9cae50fb9977efb` |

## Compatibility patch

All targets apply [`0001-droidspaces-old-kernel-compat.patch`](patches/0001-droidspaces-old-kernel-compat.patch):

- `systemd-networkd` treats `RTM_GETNEXTHOP` returning `EINVAL` like an
  unsupported old-kernel feature. Linux added nexthop netlink support in 5.3.
- systemd may use an existing cgroup v1 hierarchy when it is running inside a
  detected container, where changing the host kernel command line is impossible.

## CI verification

GitHub Actions builds natively on an ARM64 runner. Every matrix job:

1. builds the full native package family;
2. checks that all expected core split packages exist;
3. installs the core package family through apt, dnf/rpm, or pacman;
4. verifies the package transaction and `systemd 257` runtime version;
5. publishes a manifest and SHA-256 checksums.

Successful builds are available as workflow artifacts. Builds from `main` also
update the `systemd257-packages` rolling prerelease.

These are test packages. A successful package transaction proves package-family
consistency; it does not prove that every Ubuntu 26 or rolling Arch reverse
dependency supports systemd 257 behavior. RootFS boot and desktop integration
tests remain required before making the packages the default.
