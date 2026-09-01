#!/usr/bin/env bash
set -euo pipefail

readonly CASCADIA_TAG="v2407.24"
readonly SELAWIK_TAG="1.01"
readonly CARLITO_COMMIT="3a810cab78ebd6e2e4eed42af9e8453c4f9b850a"
readonly CALADEA_COMMIT="336a529cfad3d103d6527752686f8331d13e820a"
readonly LICENSE_PATH="licenses/OFL-1.1.txt"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
OUTPUT_DIR="$REPOSITORY_ROOT/winefonts"
WORK_DIR=""
STAGE_DIR=""
OUTPUT_BACKUP=""
OUTPUT_SUCCEEDED=false
INVENTORY=""
FONT_COUNT=0
FONT_BYTES=0

die() {
    printf '[winefonts-prepare] 错误: %s\n' "$1" >&2
    exit 1
}

log() {
    printf '[winefonts-prepare] %s\n' "$1"
}

cleanup() {
    if [[ -n "$OUTPUT_BACKUP" && -d "$OUTPUT_BACKUP" ]]; then
        if [[ "$OUTPUT_SUCCEEDED" == true ]]; then
            rm -rf -- "$OUTPUT_BACKUP"
        else
            if [[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" && \
                "$OUTPUT_DIR" == "$REPOSITORY_ROOT/winefonts" ]]; then
                rm -rf -- "$OUTPUT_DIR"
            fi
            if [[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]]; then
                mv -- "$OUTPUT_BACKUP" "$OUTPUT_DIR" || true
            fi
        fi
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

usage() {
    cat <<EOF
用法: $0

在本机组装仅含开源字体的目录：
  $OUTPUT_DIR

需要本机已安装 Arch 软件包：
  noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-liberation

还会从固定的官方 GitHub 标签/提交下载：
  Cascadia Code、Selawik、Carlito、Caladea

输出目录由 .gitignore 排除，不会把字体二进制加入 Git。
EOF
}

require_commands() {
    local command_name
    for command_name in awk cat chmod curl fc-scan find git grep install mkdir mktemp mv \
        pacman rm sha256sum sort stat unzip wc; do
        command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
    done
}

validate_arguments() {
    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
        '') ;;
        *)
            usage >&2
            die "此脚本不接受参数。"
            ;;
    esac
    (($# <= 1)) || die "此脚本不接受参数。"
}

require_local_packages() {
    local package
    for package in noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-liberation; do
        pacman -Q "$package" >/dev/null 2>&1 || die "本机缺少软件包：$package"
    done
    [[ -s /usr/share/licenses/noto-fonts-cjk/LICENSE ]] || \
        die "缺少 Noto CJK 的 OFL 许可证正文。"
    grep -q 'SIL OPEN FONT LICENSE Version 1.1' \
        /usr/share/licenses/noto-fonts-cjk/LICENSE || \
        die "Noto CJK 许可证正文不是预期的 OFL 1.1。"
}

download_verified() {
    local url="$1"
    local expected_sha256="$2"
    local destination="$3"
    local actual_sha256

    log "正在下载：${url##*/}"
    curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 \
        "$url" -o "$destination"
    actual_sha256="$(sha256sum "$destination" | awk '{print $1}')"
    [[ "$actual_sha256" == "$expected_sha256" ]] || \
        die "下载文件 SHA-256 不匹配：${url##*/}"
}

validate_font() {
    local font="$1"
    [[ -s "$font" && ! -L "$font" ]] || die "字体不存在或不是普通文件：$font"
    fc-scan "$font" >/dev/null 2>&1 || die "Fontconfig 无法识别字体：$font"
}

add_font() {
    local source_file="$1"
    local relative_path="$2"
    local upstream_url="$3"
    local destination="$STAGE_DIR/$relative_path"
    local size

    validate_font "$source_file"
    [[ ! -e "$destination" && ! -L "$destination" ]] || \
        die "字体目标重复：$relative_path"
    install -D -m 0644 "$source_file" "$destination"
    printf '%s\tOFL-1.1\t%s\t%s\n' \
        "$relative_path" "$LICENSE_PATH" "$upstream_url" >> "$INVENTORY"
    size="$(stat -c '%s' "$source_file")"
    FONT_COUNT=$((FONT_COUNT + 1))
    FONT_BYTES=$((FONT_BYTES + size))
}

add_local_font_sets() {
    local font basename
    local noto_url="https://github.com/notofonts"
    local noto_cjk_url="https://github.com/notofonts/noto-cjk"
    local emoji_url="https://github.com/googlefonts/noto-emoji"
    local liberation_url="https://github.com/liberationfonts/liberation-fonts"
    local -a noto_styles=(
        NotoSans-Bold.ttf
        NotoSans-Italic.ttf
        NotoSans-BoldItalic.ttf
        NotoSerif-Bold.ttf
        NotoSerif-Italic.ttf
        NotoSerif-BoldItalic.ttf
    )

    log "正在收集 Noto 常用字形与多语言常规字重..."
    while IFS= read -r -d '' font; do
        basename="${font##*/}"
        add_font "$font" "fonts/noto/$basename" "$noto_url"
    done < <(find /usr/share/fonts/noto -maxdepth 1 -type f \
        \( -name 'NotoSans*-Regular.ttf' -o -name 'NotoSerif*-Regular.ttf' \) \
        ! -name '*Test*' -print0 | sort -z)
    for basename in "${noto_styles[@]}"; do
        add_font "/usr/share/fonts/noto/$basename" "fonts/noto/$basename" "$noto_url"
    done

    log "正在收集 Noto CJK 全字重 TTC..."
    while IFS= read -r -d '' font; do
        basename="${font##*/}"
        add_font "$font" "fonts/noto-cjk/$basename" "$noto_cjk_url"
    done < <(find /usr/share/fonts/noto-cjk -maxdepth 1 -type f -name '*.ttc' -print0 | sort -z)

    add_font /usr/share/fonts/noto/NotoColorEmoji.ttf \
        fonts/noto-emoji/NotoColorEmoji.ttf "$emoji_url"

    log "正在收集 Liberation 公制兼容字体..."
    while IFS= read -r -d '' font; do
        basename="${font##*/}"
        add_font "$font" "fonts/liberation/$basename" "$liberation_url"
    done < <(find /usr/share/fonts/liberation -maxdepth 1 -type f -name '*.ttf' -print0 | sort -z)
}

add_downloaded_font() {
    local url="$1"
    local sha256="$2"
    local relative_path="$3"
    local upstream_url="$4"
    local download_path="$WORK_DIR/downloads/${relative_path##*/}"
    mkdir -p "${download_path%/*}"
    download_verified "$url" "$sha256" "$download_path"
    add_font "$download_path" "$relative_path" "$upstream_url"
}

add_cascadia() {
    local upstream="https://github.com/microsoft/cascadia-code/tree/$CASCADIA_TAG"
    local raw="https://raw.githubusercontent.com/microsoft/cascadia-code/$CASCADIA_TAG/sources/vtt_data"
    add_downloaded_font "$raw/CascadiaCode_VTT.ttf" \
        0973bb862a2ba9d31be669eb7adc3f4f4a79ad53f2678ef81527e335e1f53bc5 \
        fonts/cascadia/CascadiaCode.ttf "$upstream"
    add_downloaded_font "$raw/CascadiaCodeItalic_VTT.ttf" \
        8aa2c4ac45da592ce6b506645788dddaf1843947bbca3e51cb7e6ed60b31f5c0 \
        fonts/cascadia/CascadiaCodeItalic.ttf "$upstream"
}

add_selawik() {
    local zip_file="$WORK_DIR/downloads/Selawik_Release.zip"
    local extracted="$WORK_DIR/selawik"
    local upstream="https://github.com/microsoft/Selawik/releases/tag/$SELAWIK_TAG"
    local font

    mkdir -p "$extracted"
    download_verified \
        "https://github.com/microsoft/Selawik/releases/download/$SELAWIK_TAG/Selawik_Release.zip" \
        3f62c51e05e3b5a1e6241cf92a371f0be2ea1183aa87b30718bbd40832a8d423 \
        "$zip_file"
    unzip -q -j "$zip_file" '*.ttf' -d "$extracted"
    while IFS= read -r -d '' font; do
        add_font "$font" "fonts/selawik/${font##*/}" "$upstream"
    done < <(find "$extracted" -maxdepth 1 -type f -name '*.ttf' -print0 | sort -z)
    [[ "$(find "$extracted" -maxdepth 1 -type f -name '*.ttf' | wc -l)" == 5 ]] || \
        die "Selawik Release 的 TTF 数量不是预期的 5。"
}

add_carlito() {
    local upstream="https://github.com/googlefonts/carlito/tree/$CARLITO_COMMIT"
    local raw="https://raw.githubusercontent.com/googlefonts/carlito/$CARLITO_COMMIT/fonts/ttf"
    add_downloaded_font "$raw/Carlito-Regular.ttf" \
        f6418f708baede9789daef5d458c0f53d2a888af9820e8062934e504fedc6595 \
        fonts/carlito/Carlito-Regular.ttf "$upstream"
    add_downloaded_font "$raw/Carlito-Bold.ttf" \
        bb5d20f79b82599ec72983597437373a80f2d2085fa91fc144fd74e876a594db \
        fonts/carlito/Carlito-Bold.ttf "$upstream"
    add_downloaded_font "$raw/Carlito-Italic.ttf" \
        0b019225e58d702bfedcbd35c21696769f8ee115cb6343f84c2f240312450d1c \
        fonts/carlito/Carlito-Italic.ttf "$upstream"
    add_downloaded_font "$raw/Carlito-BoldItalic.ttf" \
        b32928186c119599e03ca6a1ffc680fdcb7fac95772f4b95d989cf6cd3861517 \
        fonts/carlito/Carlito-BoldItalic.ttf "$upstream"
}

add_caladea() {
    local upstream="https://github.com/googlefonts/caladea/tree/$CALADEA_COMMIT"
    local raw="https://raw.githubusercontent.com/googlefonts/caladea/$CALADEA_COMMIT/fonts/ttf"
    add_downloaded_font "$raw/Caladea-Regular.ttf" \
        f1e899278b7b4491aba5b6a8253c4b04c050cc59b21865be5c37559a775153cd \
        fonts/caladea/Caladea-Regular.ttf "$upstream"
    add_downloaded_font "$raw/Caladea-Bold.ttf" \
        ae3cb2dcbc925809dd29d2a44e9802211cab66be541bacbfc9c08c74b27c3742 \
        fonts/caladea/Caladea-Bold.ttf "$upstream"
    add_downloaded_font "$raw/Caladea-Italic.ttf" \
        4359a8e24f748b6447b1ff6d7a174febe70961d29f8bb8634b56dacd740a3deb \
        fonts/caladea/Caladea-Italic.ttf "$upstream"
    add_downloaded_font "$raw/Caladea-BoldItalic.ttf" \
        ccabaa7b7e2fdf253d2b1a5fa699dd8a3df8d835a9eb285ad82631a677eb76c0 \
        fonts/caladea/Caladea-BoldItalic.ttf "$upstream"
}

write_readme() {
    local noto_version cjk_version emoji_version liberation_version
    noto_version="$(pacman -Q noto-fonts | awk '{print $2}')"
    cjk_version="$(pacman -Q noto-fonts-cjk | awk '{print $2}')"
    emoji_version="$(pacman -Q noto-fonts-emoji | awk '{print $2}')"
    liberation_version="$(pacman -Q ttf-liberation | awk '{print $2}')"

    cat > "$STAGE_DIR/README.md" <<EOF
# Wine open-source replacement fonts

This directory contains only redistributable open-source fonts. It does not
contain Microsoft Windows/Office commercial fonts.

Estimated coverage for common Wine workloads:

- Daily UI, Chinese text, and office-document character coverage: 85%-90%
- Functional font-family substitution: 75%-85%
- Original Microsoft metrics, line breaks, and appearance: 60%-70%
- Exact icon, emoji, decorative-font, and legacy .fon compatibility is lower

Users who need original commercial fonts must copy them from a Windows/Office
computer for which they hold a valid license. Do not redistribute those files.

Local package inputs:

- noto-fonts $noto_version
- noto-fonts-cjk $cjk_version
- noto-fonts-emoji $emoji_version
- ttf-liberation $liberation_version

Pinned upstream inputs:

- Cascadia Code $CASCADIA_TAG
- Selawik $SELAWIK_TAG
- Carlito $CARLITO_COMMIT
- Caladea $CALADEA_COMMIT

See FONT-LICENSES.tsv for the license and source of every font file.
EOF
}

activate_output() {
    local answer
    if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
        [[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || \
            die "输出路径不是普通目录：$OUTPUT_DIR"
        [[ -t 0 ]] || die "非交互运行时拒绝替换已有 $OUTPUT_DIR。"
        printf '已存在 %s，是否替换？[y/N]: ' "$OUTPUT_DIR"
        IFS= read -r answer || answer=""
        case "${answer,,}" in
            y|yes|是) ;;
            *) die "用户取消；原目录未修改。" ;;
        esac
        OUTPUT_BACKUP="$WORK_DIR/previous-winefonts"
        mv -- "$OUTPUT_DIR" "$OUTPUT_BACKUP"
    fi

    mv -- "$STAGE_DIR" "$OUTPUT_DIR"
    STAGE_DIR=""
    OUTPUT_SUCCEEDED=true
    chmod -R a+rX,go-w "$OUTPUT_DIR"
}

main() {
    validate_arguments "$@"
    require_commands
    require_local_packages

    mkdir -p "$REPOSITORY_ROOT/out"
    WORK_DIR="$(mktemp -d "$REPOSITORY_ROOT/out/winefonts.prepare.XXXXXXXX")"
    STAGE_DIR="$WORK_DIR/winefonts"
    INVENTORY="$STAGE_DIR/FONT-LICENSES.tsv"
    mkdir -m 0700 -p "$STAGE_DIR/licenses" "$WORK_DIR/downloads"
    install -m 0644 /usr/share/licenses/noto-fonts-cjk/LICENSE \
        "$STAGE_DIR/$LICENSE_PATH"
    : > "$INVENTORY"

    add_local_font_sets
    add_cascadia
    add_selawik
    add_carlito
    add_caladea
    LC_ALL=C sort -o "$INVENTORY" "$INVENTORY"
    write_readme

    [[ "$FONT_COUNT" -ge 250 ]] || die "字体数量异常，仅收集到 $FONT_COUNT 个。"
    log "组装完成：$FONT_COUNT 个字体，$FONT_BYTES 字节。"
    activate_output
    log "本地发布目录已准备好：$OUTPUT_DIR"
    log "下一步：scripts/publish-winefonts.sh $OUTPUT_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
