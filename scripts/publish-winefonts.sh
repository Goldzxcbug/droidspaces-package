#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${WINEFONTS_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}"
readonly RELEASE_TAG="${WINEFONTS_RELEASE_TAG:-winefonts}"
readonly RELEASE_TARGET="main"
readonly MANIFEST_NAME="winefonts-manifest"
readonly INSTALLER_NAME="install-winefonts.sh"
readonly LICENSE_INVENTORY="FONT-LICENSES.tsv"
readonly RELEASE_TITLE="Wine 开源替代字体包"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SOURCE_DIR=""
WORK_DIR=""
ASSET_DIR=""
ARCHIVE_NAME=""
PUBLISH_CNB=false
FONT_FILE_COUNT=0
FONT_FILE_BYTES=0

die() {
    printf '[winefonts-publish] 错误: %s\n' "$1" >&2
    exit 1
}

log() {
    printf '[winefonts-publish] %s\n' "$1"
}

usage() {
    cat <<EOF
用法: $0 [--publish-cnb] FONT_DIRECTORY

从仓库外的字体目录创建最高压缩率 tar.xz，并更新固定的 GitHub Release：
  $RELEASE_TAG

FONT_DIRECTORY 必须包含：
  $LICENSE_INVENTORY
  licenses/ 下的许可证正文
  清单逐个列出的开源字体文件

$LICENSE_INVENTORY 每行使用四个 Tab 分隔字段：
  字体相对路径<Tab>SPDX 标识<Tab>许可证相对路径<Tab>HTTPS 上游地址

可接受的许可证：OFL-1.1、Apache-2.0、Ubuntu Font License、
GPL + Font Exception、CC-BY-4.0。常见 Windows/Office 商业字体会被硬拒绝。

选项：
  --publish-cnb  GitHub 发布成功后调用 publish-cnb-release.sh 同步到 CNB
  -h, --help     显示帮助
EOF
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

parse_arguments() {
    local argument
    local -a positional=()

    for argument in "$@"; do
        case "$argument" in
            --publish-cnb) PUBLISH_CNB=true ;;
            -h|--help)
                usage
                exit 0
                ;;
            --*) die "不支持的参数：$argument" ;;
            *) positional+=("$argument") ;;
        esac
    done

    ((${#positional[@]} == 1)) || {
        usage >&2
        die "必须且只能指定一个字体目录。"
    }
    SOURCE_DIR="$(realpath -e -- "${positional[0]}")"
}

require_commands() {
    local command_name
    for command_name in awk cat chmod cp date find gh git jq mkdir mktemp realpath rm \
        sha256sum sleep sort stat tar xz; do
        command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
    done
}

validate_release_settings() {
    [[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
        die "Release 仓库必须使用 owner/repository 格式。"
    [[ "$RELEASE_TAG" == winefonts ]] || die "Release tag 只能是 winefonts。"
    [[ -d "$SOURCE_DIR" ]] || die "字体来源不是目录：$SOURCE_DIR"
    [[ "$SOURCE_DIR" != / ]] || die "拒绝使用根目录作为字体来源。"
}

validate_git_state() {
    [[ -x "$REPOSITORY_ROOT/scripts/tui/install-winefonts.sh" ]] || \
        die "缺少可执行安装器：scripts/tui/install-winefonts.sh"
    [[ -z "$(git -C "$REPOSITORY_ROOT" status --porcelain --untracked-files=normal)" ]] || \
        die "Git 工作区不是干净状态；请先提交脚本变更再发布。"
    git -C "$REPOSITORY_ROOT" rev-parse --verify HEAD >/dev/null
}

safe_relative_path() {
    local path="$1"
    [[ -n "$path" && "$path" != /* && "$path" != *\\* && "$path" != *$'\n'* && \
        "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
    case "/$path/" in
        */./*|*/../*|*//* ) return 1 ;;
    esac
    [[ "$path" != . && "$path" != .. ]]
}

is_font_file() {
    local lower="${1,,}"
    case "$lower" in
        *.ttf|*.ttc|*.otf|*.otc|*.woff|*.woff2|*.fon) return 0 ;;
        *) return 1 ;;
    esac
}

is_allowed_license() {
    case "$1" in
        OFL-1.1|Apache-2.0|Ubuntu-Font-1.0|CC-BY-4.0|\
        'GPL-2.0-or-later WITH Font-exception-2.0') return 0 ;;
        *) return 1 ;;
    esac
}

is_known_commercial_font_name() {
    local name="${1##*/}"
    name="${name,,}"
    case "$name" in
        arial.ttf|arialbd.ttf|arialbi.ttf|ariali.ttf|ariblk.ttf|\
        bahnschrift.ttf|calibri.ttf|calibrib.ttf|calibrii.ttf|calibril.ttf|calibrili.ttf|calibriz.ttf|\
        cambria.ttc|cambriab.ttf|cambriai.ttf|cambriaz.ttf|\
        candara.ttf|candarab.ttf|candarai.ttf|candaral.ttf|candarali.ttf|candaraz.ttf|\
        comic.ttf|comicbd.ttf|comici.ttf|comicz.ttf|\
        consola.ttf|consolab.ttf|consolai.ttf|consolaz.ttf|\
        constan.ttf|constanb.ttf|constani.ttf|constanz.ttf|\
        corbel.ttf|corbelb.ttf|corbeli.ttf|corbell.ttf|corbelli.ttf|corbelz.ttf|\
        cour.ttf|courbd.ttf|courbi.ttf|couri.ttf|deng.ttf|dengb.ttf|dengl.ttf|\
        ebrima.ttf|ebrimabd.ttf|framd.ttf|framdit.ttf|gabriola.ttf|gadugi.ttf|gadugib.ttf|\
        georgia.ttf|georgiab.ttf|georgiai.ttf|georgiaz.ttf|himalaya.ttf|impact.ttf|inkfree.ttf|\
        kaiu.ttf|leelauib.ttf|leelawui.ttf|leeluisl.ttf|lucon.ttf|\
        malgun.ttf|malgunbd.ttf|malgunsl.ttf|marlett.ttf|micross.ttf|mingliu.ttc|mingliub.ttc|\
        mmrtext.ttf|mmrtextb.ttf|monbaiti.ttf|msgothic.ttc|\
        msjh.ttc|msjhbd.ttc|msjhl.ttc|msyh.ttc|msyhbd.ttc|msyhl.ttc|msyi.ttf|mvboli.ttf|\
        nirmala.ttc|ntailu.ttf|ntailub.ttf|pala.ttf|palab.ttf|palabi.ttf|palai.ttf|\
        phagspa.ttf|phagspab.ttf|segmdl2.ttf|segoeicons.ttf|segoepr.ttf|segoeprb.ttf|\
        segoesc.ttf|segoescb.ttf|segoeui.ttf|segoeuib.ttf|segoeuii.ttf|segoeuil.ttf|\
        segoeuisl.ttf|segoeuiz.ttf|seguibl.ttf|seguibli.ttf|seguiemj.ttf|seguihis.ttf|\
        seguili.ttf|seguisb.ttf|seguisbi.ttf|seguisli.ttf|seguisym.ttf|seguivar.ttf|\
        simfang.ttf|simhei.ttf|simkai.ttf|simsun.ttc|simsunb.ttf|simsunextg.ttf|\
        sitkavf.ttf|sitkavf-italic.ttf|sylfaen.ttf|symbol.ttf|tahoma.ttf|tahomabd.ttf|\
        taile.ttf|taileb.ttf|times.ttf|timesbd.ttf|timesbi.ttf|timesi.ttf|\
        trebuc.ttf|trebucbd.ttf|trebucbi.ttf|trebucit.ttf|\
        verdana.ttf|verdanab.ttf|verdanai.ttf|verdanaz.ttf|webdings.ttf|wingding.ttf|\
        yugothb.ttc|yugothl.ttc|yugothm.ttc|yugothr.ttc) return 0 ;;
        *) return 1 ;;
    esac
}

validate_source_tree() {
    local inventory="$SOURCE_DIR/$LICENSE_INVENTORY"
    local font_path spdx_id license_path source_url extra path relative
    local -A declared_fonts=()
    local -A referenced_licenses=()

    [[ -f "$inventory" && ! -L "$inventory" ]] || \
        die "来源目录缺少普通文件 $LICENSE_INVENTORY。"
    if [[ -n "$(find "$SOURCE_DIR" -mindepth 1 ! -type d ! -type f -print -quit)" ]]; then
        die "来源目录包含符号链接或特殊文件。"
    fi

    while IFS=$'\t' read -r font_path spdx_id license_path source_url extra || [[ -n "$font_path$spdx_id$license_path$source_url$extra" ]]; do
        source_url="${source_url%$'\r'}"
        [[ -z "$font_path" || "$font_path" == \#* ]] && continue
        [[ -n "$spdx_id" && -n "$license_path" && -n "$source_url" && -z "$extra" ]] || \
            die "$LICENSE_INVENTORY 存在字段数量错误。"
        safe_relative_path "$font_path" || die "清单包含不安全字体路径：$font_path"
        safe_relative_path "$license_path" || die "清单包含不安全许可证路径：$license_path"
        is_font_file "$font_path" || die "清单列出的文件不是受支持字体：$font_path"
        is_allowed_license "$spdx_id" || die "不接受字体 $font_path 的许可证：$spdx_id"
        [[ "$license_path" == licenses/* ]] || die "许可证必须位于 licenses/：$license_path"
        [[ "$source_url" == https://* ]] || die "上游地址必须使用 HTTPS：$font_path"
        [[ -f "$SOURCE_DIR/$font_path" && ! -L "$SOURCE_DIR/$font_path" ]] || \
            die "清单字体不存在或不是普通文件：$font_path"
        [[ -f "$SOURCE_DIR/$license_path" && ! -L "$SOURCE_DIR/$license_path" ]] || \
            die "许可证正文不存在或不是普通文件：$license_path"
        [[ -z "${declared_fonts[$font_path]:-}" ]] || die "清单重复列出字体：$font_path"
        is_known_commercial_font_name "$font_path" && \
            die "检测到常见 Windows/Office 商业字体，拒绝发布：$font_path"
        declared_fonts["$font_path"]=1
        referenced_licenses["$license_path"]=1
    done < "$inventory"

    ((${#declared_fonts[@]} > 0)) || die "许可证清单没有列出任何字体。"

    while IFS= read -r -d '' path; do
        relative="${path#"$SOURCE_DIR/"}"
        safe_relative_path "$relative" || die "来源目录包含不安全文件名。"
        if is_font_file "$relative"; then
            [[ -n "${declared_fonts[$relative]:-}" ]] || die "字体未列入许可证清单：$relative"
        else
            case "$relative" in
                "$LICENSE_INVENTORY"|README.md|licenses/*.txt|licenses/*.md) ;;
                *) die "来源目录包含不允许的非字体文件：$relative" ;;
            esac
        fi
    done < <(find "$SOURCE_DIR" -type f -print0)

    for license_path in "${!referenced_licenses[@]}"; do
        [[ -s "$SOURCE_DIR/$license_path" ]] || die "许可证正文为空：$license_path"
    done

    FONT_FILE_COUNT=${#declared_fonts[@]}
    FONT_FILE_BYTES=0
    for font_path in "${!declared_fonts[@]}"; do
        FONT_FILE_BYTES=$((FONT_FILE_BYTES + $(stat -c '%s' "$SOURCE_DIR/$font_path")))
    done
    log "许可证清单验证完成：$FONT_FILE_COUNT 个字体，$FONT_FILE_BYTES 字节。"
}

confirm_redistribution_rights() {
    local answer
    [[ -t 0 ]] || die "发布确认必须在交互终端中完成。"
    cat <<'EOF'

许可证确认：
  * 非商用、个人项目或开源仓库不会自动获得微软商业字体的再分发权。
  * 本次目录中的每个字体都必须由其许可证明确允许公开再分发。
  * 发布包必须保留对应的版权声明和许可证正文。

请输入以下完整文本继续：I HAVE REDISTRIBUTION RIGHTS
EOF
    IFS= read -r answer
    [[ "$answer" == 'I HAVE REDISTRIBUTION RIGHTS' ]] || die "许可证确认不匹配，已取消发布。"
}

prepare_assets() {
    local timestamp revision source_date_epoch archive_path installer_path manifest_path checksums_path
    local stage_dir release_notes

    timestamp="$(date -u +%Y%m%d-%H%M%S)"
    revision="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"
    source_date_epoch="$(git -C "$REPOSITORY_ROOT" show -s --format=%ct HEAD)"
    ARCHIVE_NAME="winefonts-$timestamp.tar.xz"
    WORK_DIR="$(mktemp -d -t winefonts-publish.XXXXXXXX)"
    ASSET_DIR="$WORK_DIR/assets"
    stage_dir="$WORK_DIR/stage"
    mkdir -m 0700 -p "$ASSET_DIR" "$stage_dir/winefonts"
    cp -a -- "$SOURCE_DIR/." "$stage_dir/winefonts/"

    archive_path="$ASSET_DIR/$ARCHIVE_NAME"
    log "正在使用单线程 LZMA2（512 MiB 字典）创建最大压缩率归档..."
    LC_ALL=C tar \
        --sort=name \
        --format=posix \
        --pax-option=delete=atime,delete=ctime \
        --owner=0 --group=0 --numeric-owner \
        --mode='u+rwX,go+rX,go-w' \
        --mtime="@$source_date_epoch" \
        -cf - -C "$stage_dir" winefonts | \
        xz --threads=1 --check=crc64 -9e \
            --lzma2=dict=512MiB,nice=273,mf=bt4 \
            > "$archive_path"
    xz --test "$archive_path"

    installer_path="$ASSET_DIR/$INSTALLER_NAME"
    cp -- "$REPOSITORY_ROOT/scripts/tui/install-winefonts.sh" "$installer_path"
    chmod 0755 "$installer_path"

    manifest_path="$ASSET_DIR/$MANIFEST_NAME"
    {
        printf 'format=1\n'
        printf 'release_tag=%s\n' "$RELEASE_TAG"
        printf 'revision=%s\n' "$revision"
        printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'archive=%s\n' "$ARCHIVE_NAME"
        printf 'archive_sha256=%s\n' "$(sha256sum "$archive_path" | awk '{print $1}')"
        printf 'archive_size=%s\n' "$(stat -c '%s' "$archive_path")"
        printf 'font_file_count=%s\n' "$FONT_FILE_COUNT"
        printf 'font_file_bytes=%s\n' "$FONT_FILE_BYTES"
    } > "$manifest_path"

    checksums_path="$ASSET_DIR/SHA256SUMS"
    (
        cd "$ASSET_DIR"
        sha256sum "$ARCHIVE_NAME" "$INSTALLER_NAME" "$MANIFEST_NAME" > "$checksums_path"
    )

    release_notes="$WORK_DIR/release-notes.md"
    cat > "$release_notes" <<'EOF'
这是面向 Wine/Droidspaces 的开源替代字体包，不包含 Arial、Calibri、Cambria、Segoe UI、微软雅黑等 Windows/Office 商业字体。

覆盖率说明（按常见 Wine 使用场景估算，并非逐字形保证）：

- 日常 Wine 界面、中文和办公软件字符覆盖：约 85%–90%
- 字体家族的功能性替代：约 75%–85%
- 与微软原字体保持相同字宽、换行和视觉效果：约 60%–70%
- 图标字体、Emoji、装饰字体以及旧式 `.fon` 的精确兼容率明显更低

开源替代字体不能保证与原商业字体完全相同。需要原版排版、特殊图标或应用明确指定商业字体时，请用户从自己拥有有效许可证的 Windows/Office 电脑中自行补全；请勿把这些商业字体重新上传或公开分发。

归档内的 `FONT-LICENSES.tsv` 逐个记录字体、SPDX 许可证、许可证正文和上游来源。安装器只管理 `/usr/local/share/fonts/winefonts`，不会删除或修改 `/usr/share/fonts`。
EOF
}

release_exists() {
    gh release view "$RELEASE_TAG" --repo "$RELEASE_REPOSITORY" >/dev/null 2>&1
}

upload_assets() {
    local revision release_notes release_id
    revision="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"
    release_notes="$WORK_DIR/release-notes.md"

    if release_exists; then
        log "正在更新固定 Release：$RELEASE_TAG"
    else
        log "正在创建草稿 Release：$RELEASE_TAG"
        gh release create "$RELEASE_TAG" \
            --repo "$RELEASE_REPOSITORY" \
            --target "$RELEASE_TARGET" \
            --title "$RELEASE_TITLE" \
            --notes-file "$release_notes" \
            --draft \
            --latest=false
    fi

    release_id="$(gh release view "$RELEASE_TAG" \
        --repo "$RELEASE_REPOSITORY" \
        --json databaseId \
        --jq '.databaseId')"
    [[ "$release_id" =~ ^[0-9]+$ ]] || die "无法取得 GitHub Release ID：$RELEASE_TAG"

    # 新归档先上传；清单最后替换，旧清单在此之前仍指向旧归档。
    gh release upload "$RELEASE_TAG" "$ASSET_DIR/$ARCHIVE_NAME" \
        --repo "$RELEASE_REPOSITORY"
    gh release upload "$RELEASE_TAG" \
        "$ASSET_DIR/$INSTALLER_NAME" "$ASSET_DIR/SHA256SUMS" \
        --repo "$RELEASE_REPOSITORY" --clobber
    gh release upload "$RELEASE_TAG" "$ASSET_DIR/$MANIFEST_NAME" \
        --repo "$RELEASE_REPOSITORY" --clobber

    verify_uploaded_asset "$release_id" "$ASSET_DIR/$ARCHIVE_NAME"
    verify_uploaded_asset "$release_id" "$ASSET_DIR/$INSTALLER_NAME"
    verify_uploaded_asset "$release_id" "$ASSET_DIR/SHA256SUMS"
    verify_uploaded_asset "$release_id" "$ASSET_DIR/$MANIFEST_NAME"

    if gh api "repos/$RELEASE_REPOSITORY/git/ref/tags/$RELEASE_TAG" >/dev/null 2>&1; then
        gh api --method PATCH \
            "repos/$RELEASE_REPOSITORY/git/refs/tags/$RELEASE_TAG" \
            -f sha="$revision" -F force=true >/dev/null
    fi
    gh release edit "$RELEASE_TAG" \
        --repo "$RELEASE_REPOSITORY" \
        --target "$RELEASE_TARGET" \
        --title "$RELEASE_TITLE" \
        --notes-file "$release_notes" \
        --draft=false --prerelease=false --latest=false

    delete_stale_assets "$release_id"
    log "GitHub Release 发布完成：https://github.com/$RELEASE_REPOSITORY/releases/tag/$RELEASE_TAG"
}

verify_uploaded_asset() {
    local release_id="$1"
    local file="$2"
    local name expected_size expected_digest release_json actual_size actual_digest attempt
    name="${file##*/}"
    expected_size="$(stat -c '%s' "$file")"
    expected_digest="sha256:$(sha256sum "$file" | awk '{print $1}')"

    for attempt in {1..15}; do
        release_json="$(gh api "repos/$RELEASE_REPOSITORY/releases/$release_id")"
        actual_size="$(jq -er --arg name "$name" '
            [.assets[] | select(.name == $name)] |
            if length == 1 then .[0].size else error("asset is not unique") end
        ' <<< "$release_json" 2>/dev/null || true)"
        actual_digest="$(jq -er --arg name "$name" '
            [.assets[] | select(.name == $name)] |
            if length == 1 and .[0].digest != null then .[0].digest
            else error("digest is unavailable") end
        ' <<< "$release_json" 2>/dev/null || true)"
        if [[ "$actual_size" == "$expected_size" && "$actual_digest" == "$expected_digest" ]]; then
            return
        fi
        (( attempt < 15 )) && sleep 2
    done
    die "GitHub 未返回 $name 的正确大小和 SHA-256 摘要。"
}

delete_stale_assets() {
    local release_id="$1"
    local release_json row asset_id asset_name
    local -A keep=(
        ["$ARCHIVE_NAME"]=1
        ["$INSTALLER_NAME"]=1
        ["SHA256SUMS"]=1
        ["$MANIFEST_NAME"]=1
    )

    release_json="$(gh api "repos/$RELEASE_REPOSITORY/releases/$release_id")"
    while IFS=$'\t' read -r asset_id asset_name; do
        [[ -n "$asset_id" && -n "$asset_name" ]] || continue
        if [[ -z "${keep[$asset_name]:-}" ]]; then
            log "正在删除旧 Release 资产：$asset_name"
            gh api --method DELETE \
                "repos/$RELEASE_REPOSITORY/releases/assets/$asset_id" >/dev/null
        fi
    done < <(jq -r '.assets[] | [.id, .name] | @tsv' <<< "$release_json")
}

publish_cnb() {
    [[ "$PUBLISH_CNB" == true ]] || return
    [[ -n "${GH_TOKEN:-}" ]] || die "同步 CNB 需要 GH_TOKEN。"
    [[ -n "${CNB_TOKEN:-}" ]] || die "同步 CNB 需要 CNB_TOKEN。"
    [[ -n "${CNB_REPO:-}" ]] || die "同步 CNB 需要 CNB_REPO。"
    log "正在同步固定 Release 到 CNB..."
    GH_TOKEN="$GH_TOKEN" \
    CNB_TOKEN="$CNB_TOKEN" \
    CNB_REPO="$CNB_REPO" \
    GITHUB_REPOSITORY="$RELEASE_REPOSITORY" \
        "$REPOSITORY_ROOT/scripts/publish-cnb-release.sh" "$RELEASE_TAG"
}

main() {
    require_commands
    parse_arguments "$@"
    validate_release_settings
    validate_git_state
    validate_source_tree
    confirm_redistribution_rights
    prepare_assets
    upload_assets
    publish_cnb
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
