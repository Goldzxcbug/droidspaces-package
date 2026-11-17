#!/usr/bin/env bash
# Package the TUI entry scripts and shared libraries as one verified release.
set -euo pipefail
export LC_ALL=C
unset TAR_OPTIONS GZIP

readonly RELEASE_TAG=Gold-bug-tui
readonly BUNDLE_NAME=Gold-bug-tui.tar.gz
readonly MANIFEST_NAME=Gold-bug-tui-manifest
readonly FILES_NAME=Gold-bug-tui-files
readonly SCRIPT_LIMIT=8388608
readonly BUNDLE_LIMIT=33554432
readonly EXPANDED_LIMIT=67108864
readonly MANIFEST_LIMIT=1048576
# Two directory members and the internal manifest complete the 128-member cap.
readonly PAYLOAD_LIMIT=125
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_DIR="$SCRIPT_DIR/tui"
OUTPUT=''
REVISION=''
WORK_DIR=''
ROLE=''
TARGET=''
MODE=''
declare -a ROOT_SCRIPTS=(
    droidspaces-tui.sh droidspaces-gpu.sh droidspaces-video.sh install-tui.sh
    install-mesa.sh install-hangover-wine.sh install-winefonts.sh
    install-anland-kde.sh install-anland-gnome.sh install-anland-next.sh
    install-anland-niri.sh install-anland-hyprland.sh install-anland-mango.sh
    install-anland-denial.sh
)
declare -a REQUIRED_LIBRARIES=(
    anland-common.sh anland-archive-common.sh anland-compositor-common.sh
)
declare -A REGISTERED_ROOTS=()

die() { printf 'package-tui: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Usage: package-tui.sh --output DIRECTORY --revision COMMIT [--source DIRECTORY]

Creates Gold-bug-tui.tar.gz, install-tui.sh, and Gold-bug-tui-manifest.
The archive contains tui/, shared lib/*.sh files, and Gold-bug-tui-files.
Requires Bash, GNU coreutils, GNU tar, gzip, and git (unless SOURCE_DATE_EPOCH
is set). SOURCE_DATE_EPOCH or the commit timestamp supplies generated_at;
non-repository fixtures without a commit timestamp use the Unix epoch.
HELP
}

cleanup() {
    [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
}

asset_metadata() {
    local name="$1" base
    if [[ "$name" == lib/* ]]; then
        base="${name#lib/}"
        [[ "$base" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*\.sh$ ]] || die "invalid library path: $name"
        ROLE=library; TARGET="/usr/local/lib/droidspaces/tui/$base"; MODE=0644
        return
    fi
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.sh$ && "$name" != *..* ]] || die "invalid script path: $name"
    [[ -n "${REGISTERED_ROOTS[$name]+present}" ]] || die "unregistered script: $name"
    MODE=0755
    case "$name" in
        install-tui.sh) ROLE=bootstrap; TARGET=- ;;
        droidspaces-tui.sh|droidspaces-gpu.sh) ROLE=tui; TARGET="/usr/local/bin/${name%.sh}" ;;
        droidspaces-video.sh) ROLE=tui; TARGET="/usr/local/bin/$name" ;;
        *) ROLE=installer; TARGET="/usr/local/sbin/${name%.sh}" ;;
    esac
}

write_header() {
    printf 'format=1\nrelease_tag=%s\nrevision=%s\ngenerated_at=%s\nsha256\tsize\trole\ttarget\tasset\n' \
        "$RELEASE_TAG" "$REVISION" "$GENERATED_AT"
}

main() {
    local command_name name source size staged digest total=0 epoch
    local files_manifest bundle bootstrap_size bootstrap_digest bundle_size bundle_digest
    local -a paths=()
    while (($#)); do
        case "$1" in
            --output|--revision|--source)
                (($# >= 2)) && [[ -n "$2" ]] || die "$1 requires a value"
                case "$1" in --output) OUTPUT="$2" ;; --revision) REVISION="$2" ;; --source) SOURCE_DIR="$2" ;; esac
                shift 2
                ;;
            -h|--help) usage; return ;;
            *) die "unsupported argument: $1" ;;
        esac
    done
    [[ -n "$OUTPUT" ]] || die '--output is required'
    [[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || die '--revision must be a lowercase 40-character commit hash'
    for command_name in bash chmod date dirname gzip install mkdir mktemp mv rm sha256sum stat tar; do
        command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
    done
    SOURCE_DIR="${SOURCE_DIR%/}"
    [[ -d "$SOURCE_DIR" && ! -L "$SOURCE_DIR" ]] || die '--source must be a regular directory'
    SOURCE_DIR="$(cd -- "$SOURCE_DIR" && pwd -P)"
    [[ -d "$SOURCE_DIR/lib" && ! -L "$SOURCE_DIR/lib" ]] || die 'source lib directory is missing or is a symlink'
    for name in "${ROOT_SCRIPTS[@]}"; do
        REGISTERED_ROOTS["$name"]=1
        [[ -f "$SOURCE_DIR/$name" && ! -L "$SOURCE_DIR/$name" ]] || die "required script is missing or not regular: $name"
    done
    for name in "${REQUIRED_LIBRARIES[@]}"; do
        [[ -f "$SOURCE_DIR/lib/$name" && ! -L "$SOURCE_DIR/lib/$name" ]] || die "required library is missing or not regular: $name"
    done
    shopt -s nullglob
    paths=("$SOURCE_DIR"/*.sh "$SOURCE_DIR"/lib/*.sh)
    shopt -u nullglob
    ((${#paths[@]} <= PAYLOAD_LIMIT)) || die "bundle exceeds $PAYLOAD_LIMIT payload files"
    if [[ -n "${SOURCE_DATE_EPOCH+x}" ]]; then
        epoch="$SOURCE_DATE_EPOCH"
    elif command -v git >/dev/null 2>&1; then
        epoch="$(git -C "$SOURCE_DIR" show -s --format=%ct --no-show-signature "$REVISION" 2>/dev/null)" || epoch=0
    else
        epoch=0
    fi
    [[ "$epoch" =~ ^[0-9]+$ ]] || die 'SOURCE_DATE_EPOCH must be a nonnegative integer'
    GENERATED_AT="$(date -u -d "@$epoch" +'%Y-%m-%dT%H:%M:%SZ')" || die 'source timestamp is outside the supported range'
    OUTPUT="${OUTPUT%/}"
    [[ -n "$OUTPUT" && ! -L "$OUTPUT" ]] || die '--output must be a regular directory'
    mkdir -p -- "$OUTPUT"
    OUTPUT="$(cd -- "$OUTPUT" && pwd -P)"
    for name in "$BUNDLE_NAME" install-tui.sh "$MANIFEST_NAME"; do
        [[ ! -d "$OUTPUT/$name" || -L "$OUTPUT/$name" ]] || die "output asset is a directory: $name"
    done
    WORK_DIR="$(mktemp -d "$OUTPUT/.package-tui.XXXXXXXX")"
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p -- "$WORK_DIR/stage/tui/lib" "$WORK_DIR/release"
    chmod 0755 -- "$WORK_DIR/stage/tui" "$WORK_DIR/stage/tui/lib"
    files_manifest="$WORK_DIR/stage/tui/$FILES_NAME"
    write_header > "$files_manifest"
    for source in "${paths[@]}"; do
        name="${source#"$SOURCE_DIR/"}"
        [[ -f "$source" && ! -L "$source" ]] || die "not a regular source file: $name"
        asset_metadata "$name"
        size="$(stat -c %s -- "$source")"
        ((size > 0 && size <= SCRIPT_LIMIT)) || die "source file is empty or exceeds $SCRIPT_LIMIT bytes: $name"
        staged="$WORK_DIR/stage/tui/$name"
        install -m "$MODE" -- "$source" "$staged"
        [[ "$(stat -c %s -- "$staged")" == "$size" ]] || die "source file changed while packaging: $name"
        bash -n "$staged" || die "shell syntax check failed: $name"
        total=$((total + size))
        ((total <= EXPANDED_LIMIT)) || die 'bundle exceeds the uncompressed size limit'
        digest="$(sha256sum < "$staged")"; digest="${digest%% *}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$digest" "$size" "$ROLE" "$TARGET" "$name" >> "$files_manifest"
    done
    size="$(stat -c %s -- "$files_manifest")"
    ((size <= MANIFEST_LIMIT && total + size <= EXPANDED_LIMIT)) || die 'bundle or internal manifest exceeds its size limit'
    chmod 0644 -- "$files_manifest"
    bundle="$WORK_DIR/release/$BUNDLE_NAME"
    tar -C "$WORK_DIR/stage" --sort=name --format=ustar --mtime=@0 \
        --owner=0 --group=0 --numeric-owner -cf - tui | gzip -n -9 > "$bundle"
    bundle_size="$(stat -c %s -- "$bundle")"
    ((bundle_size > 0 && bundle_size <= BUNDLE_LIMIT)) || die 'archive exceeds the compressed size limit'
    bundle_digest="$(sha256sum < "$bundle")"; bundle_digest="${bundle_digest%% *}"
    install -m 0755 -- "$WORK_DIR/stage/tui/install-tui.sh" "$WORK_DIR/release/install-tui.sh"
    bootstrap_size="$(stat -c %s -- "$WORK_DIR/release/install-tui.sh")"
    bootstrap_digest="$(sha256sum < "$WORK_DIR/release/install-tui.sh")"; bootstrap_digest="${bootstrap_digest%% *}"
    {
        write_header
        printf '%s\t%s\tbootstrap\t-\tinstall-tui.sh\n' "$bootstrap_digest" "$bootstrap_size"
        printf '%s\t%s\tbundle\t-\t%s\n' "$bundle_digest" "$bundle_size" "$BUNDLE_NAME"
    } > "$WORK_DIR/release/$MANIFEST_NAME"
    chmod 0644 -- "$bundle" "$WORK_DIR/release/$MANIFEST_NAME"
    # The staging directory is on the output filesystem; each replacement is an
    # atomic rename, and the external manifest becomes visible last.
    for name in "$BUNDLE_NAME" install-tui.sh "$MANIFEST_NAME"; do
        mv -Tf -- "$WORK_DIR/release/$name" "$OUTPUT/$name"
    done
    printf 'Packaged %s scripts/libraries (%s bytes) into %s/%s\n' "${#paths[@]}" "$total" "$OUTPUT" "$BUNDLE_NAME"
    printf 'Archive SHA-256: %s (%s bytes)\n' "$bundle_digest" "$bundle_size"
}

main "$@"
