"""Exercise the TUI with isolated state, package queries, installers, and downloads."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


TUI = Path(__file__).resolve().parents[1] / "scripts/tui/droidspaces-tui.sh"
COMPONENTS = ("kde", "gnome", "niri", "hyprland", "mango", "denial", "anland-next")
TARGETS = (
    ("debian", "13", "debian13"),
    ("ubuntu", "26.04", "ubuntu2604"),
    ("fedora", "43", "fedora43"),
    ("fedora", "44", "fedora44"),
    ("arch", "", "arch"),
)

PACKAGE_QUERIES = r'''
declare -A FIXTURE_PACKAGES=()
dpkg-query() {
    local package="${!#}"
    [[ -n "${FIXTURE_PACKAGES[$package]:-}" ]] || return 1
    printf 'ii \t%s\n' "${FIXTURE_PACKAGES[$package]}"
}
rpm() {
    local package="${!#}"
    [[ -n "${FIXTURE_PACKAGES[$package]:-}" ]] || return 1
    printf '%s\n' "${FIXTURE_PACKAGES[$package]}"
}
pacman() {
    local package="${!#}"
    [[ -n "${FIXTURE_PACKAGES[$package]:-}" ]] || return 1
    printf '%s %s\n' "$package" "${FIXTURE_PACKAGES[$package]}"
}
'''


class AnlandTuiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="anland-tui-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Redirect only the sourced test copy's system paths. No host state is touched.
        script = TUI.read_text()
        for prefix in ("/var/lib/anland-", "/etc/dnf/", "/etc/pacman.conf",
                       "/etc/apt/", "/usr/local/share/fonts/winefonts"):
            script = script.replace(prefix, str(self.root) + prefix)
        self.script = self.root / "tui.sh"
        self.script.write_text(script)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        curl = self.bin / "curl"
        curl.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith('https://'))
with open(os.environ['CURL_REQUESTS'], 'a') as stream:
    stream.write(url + '\\n')
fixtures = json.loads(Path(os.environ['HTTP_FIXTURES']).read_text())
if url not in fixtures:
    raise SystemExit(22)
Path(args[args.index('--output') + 1]).write_text(fixtures[url])
""")
        curl.chmod(0o755)
        self.fixtures = self.root / "http.json"
        self.fixtures.write_text("{}")
        self.requests = self.root / "requests"
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FIXTURE_ROOT": str(self.root),
            "HTTP_FIXTURES": str(self.fixtures),
            "CURL_REQUESTS": str(self.requests),
            "DROIDSPACES_COMPONENT_STATE_DIR": str(self.root / "components"),
            "DROIDSPACES_DESKTOP_CONFIG": str(self.root / "desktop.conf"),
            **{f"DROIDSPACES_COMPONENT_{source}_BASE":
               f"https://fixtures.invalid/{source.lower()}"
               for source in ("GITHUB", "PROXY", "CNB")},
        }

    def bash(self, commands, *args, input=None):
        result = subprocess.run(
            ["bash", "-euc", 'source "$1"; shift\n' + PACKAGE_QUERIES + commands,
             "tui-test", str(self.script), *args],
            env=self.env, input=input, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def write(self, relative_path, text):
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def holds(self, component, system):
        if system in ("debian", "ubuntu"):
            self.write(f"var/lib/anland-{component}/apt-holds", "fixture-package\n")
        elif system == "fedora":
            with self.write_if_missing("etc/dnf/dnf.conf").open("a") as stream:
                stream.write(f"# BEGIN anland-{component} package holds\n")
        else:
            package = {"kde": "kwin", "gnome": "mutter"}.get(component, component)
            with self.write_if_missing("etc/pacman.conf").open("a") as stream:
                stream.write(f"IgnorePkg = {package}\n")

    def write_if_missing(self, relative_path):
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(exist_ok=True)
        return path

    def package(self, component, system):
        return {
            "kde": "kwin-wayland" if system in ("debian", "ubuntu") else "kwin",
            "gnome": "mutter-common" if system in ("debian", "ubuntu") else "mutter",
            "hyprland": "hyprland" if system in ("debian", "ubuntu") else "hyprland-anland",
            "niri": "niri-anland", "mango": "mango-anland",
            "denial": "denial", "anland-next": "anland-session",
        }[component]

    def test_installed_packages_with_new_holds_without_version_marker(self):
        for component in COMPONENTS:
            for system, version, _ in TARGETS:
                with self.subTest(component=component, system=system, version=version):
                    self.holds(component, system)
                    self.bash('''
SYSTEM_ID="$1"; SYSTEM_VERSION="$2"; ARCHITECTURE=aarch64
FIXTURE_PACKAGES[$4]=25.11-1
managed_component_installed "$3"
[[ "$(detect_current_component_version "$3")" == 25.11-1 ]]
''', system, version, component, self.package(component, system))

    def test_version_and_hold_records_do_not_replace_missing_packages(self):
        for component in COMPONENTS:
            self.write(f"components/{component}.version", "25.11\n")
            for system, _, _ in TARGETS:
                with self.subTest(component=component, system=system):
                    self.holds(component, system)
                    self.bash('''
SYSTEM_ID="$1"
! managed_component_installed "$2"
''', system, component)

    def test_dedicated_packages_need_no_state_files(self):
        for component in ("niri", "mango", "denial", "anland-next"):
            for system, _, _ in TARGETS:
                with self.subTest(component=component, system=system):
                    self.bash('''
SYSTEM_ID="$1"; FIXTURE_PACKAGES[$3]=25.11-1
managed_component_installed "$2"
''', system, component, self.package(component, system))

    def test_distribution_graphics_packages_are_not_automatically_anland(self):
        for component in ("kde", "gnome", "hyprland"):
            for system, _, _ in TARGETS:
                with self.subTest(component=component, system=system):
                    package = "hyprland" if component == "hyprland" else self.package(component, system)
                    self.bash('''
SYSTEM_ID="$1"; FIXTURE_PACKAGES[$3]=25.11-1
! managed_component_installed "$2"
''', system, component, package)

    def test_installed_component_keeps_exact_recorded_release_version(self):
        self.write("components/hyprland.version", "0.54.1\n")
        self.bash('''
SYSTEM_ID=debian; FIXTURE_PACKAGES[hyprland]=0.54.1-1
managed_component_installed hyprland
[[ "$(detect_current_component_version hyprland)" == 0.54.1 ]]
''')

    def test_hyprland_deb_can_be_uninstalled_without_version_marker(self):
        self.holds("hyprland", "debian")
        installer = self.write("installer", '#!/bin/bash\nprintf "%s\\n" "$@" > "$FIXTURE_ROOT/uninstall-args"\n')
        installer.chmod(0o755)
        self.bash('''
SYSTEM_ID=debian; FIXTURE_PACKAGES[hyprland]=0.54.1-1
if managed_component_installed hyprland; then COMPONENT_INSTALLED[hyprland]=true; fi
resolve_installer() { printf '%s/installer' "$FIXTURE_ROOT"; }
confirm_run() { return 0; }; pause_menu() { :; }
run_component_uninstall hyprland 'Anland Hyprland'
[[ "$COMPONENT_REFRESH_REQUIRED" == true ]]
''')
        self.assertEqual((self.root / "uninstall-args").read_text(), "--uninstall\n")

    def fetch(self, source, system, version, component):
        return self.bash('''
DOWNLOAD_SOURCE="$1"; SYSTEM_ID="$2"; SYSTEM_VERSION="$3"; ARCHITECTURE=aarch64
COMPONENT_VERSION_WORK_DIR="$FIXTURE_ROOT/work"; mkdir -p "$COMPONENT_VERSION_WORK_DIR"
fetch_component_release_version "$4" "$FIXTURE_ROOT/result"
cat "$FIXTURE_ROOT/result"
''', source, system, version, component).strip()

    def test_all_sources_follow_manifest_instead_of_leftover_archives(self):
        # The rolling Release can contain both archives; its manifest selects one.
        tag = "anland-niri-packages"
        assets = [f"anland-niri-debian13-{v}-arm64.tar.gz" for v in ("25.08", "25.09")]
        fixtures = {f"https://api.github.com/repos/Goldzxcbug/droidspaces-package/releases/tags/{tag}":
                    json.dumps({"tag_name": tag, "draft": False,
                                "assets": [{"name": name} for name in assets]})}
        for source in ("github", "proxy", "cnb"):
            fixtures[f"https://fixtures.invalid/{source}/{tag}/anland-niri-manifest"] = (
                f"format=1\nrelease_tag={tag}\ndebian13={assets[0]}\n")
        self.fixtures.write_text(json.dumps(fixtures))
        for selection, source in (("1", "github"), ("2", "proxy"), ("3", "cnb"), ("auto", "github")):
            with self.subTest(source=source, selection=selection):
                self.assertEqual(self.fetch(selection, "debian", "13", "niri"), "25.08")
                self.assertEqual(self.requests.read_text().splitlines()[-1],
                                 f"https://fixtures.invalid/{source}/{tag}/anland-niri-manifest")

    def test_all_anland_distribution_manifest_formats(self):
        for component in COMPONENTS:
            for system, version, target in TARGETS:
                with self.subTest(component=component, target=target):
                    name = "session" if component == "anland-next" else component
                    if component == "anland-next":
                        if system in ("debian", "ubuntu"):
                            archive = f"anland-session-{target}-anland-session_25.11_arm64.deb"
                        elif system == "fedora":
                            archive = f"anland-session-{target}-anland-session-25.11.aarch64.rpm"
                        else:
                            archive = "anland-session-arch-anland-session-25.11-aarch64.pkg.tar.zst"
                    else:
                        vprefix = {"kde": "kwin-", "gnome": "mutter-"}.get(component, "")
                        arch = "arm64" if system in ("debian", "ubuntu") else "aarch64"
                        archive = f"anland-{name}-{target}-{vprefix}25.11-{arch}.tar.gz"
                    tag = f"anland-{name}-packages"
                    body = f"format=1\nrelease_tag={tag}\n{target}={archive}\n"
                    url = f"https://fixtures.invalid/github/{tag}/anland-{name}-manifest"
                    self.fixtures.write_text(json.dumps({url: body}))
                    self.assertEqual(self.fetch("1", system, version, component), "25.11")

    def test_other_component_manifest_formats(self):
        cases = (
            ("mesa", "mesa-for-android-container", "mesa-distribution-manifest",
             "sha256\tsize\tasset\n" + "a" * 64 + "\t123\tmesa-for-android-container_25.11_debian_trixie_arm64.tar.gz\n"),
            ("hangover", "hangover-wine-packages", "hangover-wine-manifest",
             "debian13=hangover-wine-debian13-25.11-arm64.tar.gz\n"),
            ("fonts", "winefonts", "winefonts-manifest", "archive=winefonts-25.11.tar.xz\n"),
        )
        for component, tag, manifest_name, entries in cases:
            with self.subTest(component=component):
                url = f"https://fixtures.invalid/github/{tag}/{manifest_name}"
                self.fixtures.write_text(json.dumps({url: f"format=1\nrelease_tag={tag}\n{entries}"}))
                self.assertEqual(self.fetch("1", "debian", "13", component), "25.11")

    def test_invalid_or_ambiguous_manifests_do_not_publish_a_version(self):
        header = "format=1\nrelease_tag=anland-niri-packages\n"
        entry = "debian13=anland-niri-debian13-25.11-arm64.tar.gz\n"
        for body in ("", header.replace("format=1", "format=2") + entry,
                     header.replace("niri", "mango") + entry, header + entry + entry,
                     header + "arch=anland-niri-arch-25.11-aarch64.tar.gz\n",
                     header + entry + "#" * (1024 * 1024)):
            with self.subTest(size=len(body)):
                url = "https://fixtures.invalid/github/anland-niri-packages/anland-niri-manifest"
                self.fixtures.write_text(json.dumps({url: body}))
                self.bash('''
DOWNLOAD_SOURCE=1; SYSTEM_ID=debian; SYSTEM_VERSION=13; ARCHITECTURE=aarch64
COMPONENT_VERSION_WORK_DIR="$FIXTURE_ROOT/work"; mkdir -p "$COMPONENT_VERSION_WORK_DIR"
! fetch_component_release_version niri "$FIXTURE_ROOT/result"
[[ ! -e "$FIXTURE_ROOT/result" ]]
''')

    def test_source_selection_requests_refresh_only_when_changed(self):
        for choice, source, refresh in (("1", "auto", "true"), ("2", "1", "false"),
                                        ("3", "2", "true"), ("4", "3", "true"),
                                        ("0", "1", "false")):
            with self.subTest(choice=choice):
                self.bash('''
DOWNLOAD_SOURCE=1; COMPONENT_REFRESH_REQUIRED=false
select_download_source >/dev/null
[[ "$DOWNLOAD_SOURCE" == "$1" && "$COMPONENT_REFRESH_REQUIRED" == "$2" ]]
''', source, refresh, input=choice + "\n")

    def test_main_menu_refreshes_after_switching_from_failed_github_to_cnb(self):
        url = "https://fixtures.invalid/cnb/anland-niri-packages/anland-niri-manifest"
        self.fixtures.write_text(json.dumps({url: "format=1\nrelease_tag=anland-niri-packages\n"
                                             "debian13=anland-niri-debian13-25.11-arm64.tar.gz\n"}))
        self.bash('''
DOWNLOAD_SOURCE=1; SYSTEM_ID=debian; SYSTEM_VERSION=13; ARCHITECTURE=aarch64
set_desktop_component niri
component_visible() { [[ "$1" == niri ]]; }
read_dynamic_menu_choice() { IFS= read -r MENU_CHOICE; }
draw_dynamic_menu_prompt() { :; }
main_menu >/dev/null
for pid in "${COMPONENT_VERSION_PIDS[@]}"; do wait "$pid" || true; done
poll_component_version_checks
[[ "${COMPONENT_UPSTREAM_VERSIONS[niri]}" == 25.11 ]]
[[ "$COMPONENT_REFRESH_REQUIRED" == false ]]
[[ -z "$COMPONENT_VERSION_WORK_DIR" ]]
''', input="s\n4\nq\n")

    def test_next_accepts_archlinux_alias_and_rejects_other_architectures(self):
        self.bash('''
SYSTEM_ID=archlinux; ARCHITECTURE=aarch64
component_supported anland-next
ARCHITECTURE=x86_64
for component in kde gnome niri hyprland mango denial anland-next; do
    ! component_supported "$component"
done
''')


if __name__ == "__main__":
    unittest.main()
