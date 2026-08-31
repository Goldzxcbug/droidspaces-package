#!/usr/bin/env bash
set -euo pipefail

readonly CNB_API_URL="${CNB_API_URL:-https://api.cnb.cool}"
readonly RELEASE_TAG="${1:?用法: publish-cnb-release.sh RELEASE_TAG}"
readonly GITHUB_RELEASE_REPOSITORY="${GITHUB_REPOSITORY:?缺少 GITHUB_REPOSITORY}"
readonly CNB_RELEASE_REPOSITORY="${CNB_REPO:?缺少 CNB_REPO}"

: "${CNB_TOKEN:?缺少 CNB_TOKEN}"
: "${GH_TOKEN:?缺少 GH_TOKEN}"

for command_name in curl gh jq stat; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "缺少命令：$command_name" >&2
        exit 1
    }
done

work_dir="$(mktemp -d)"
asset_dir="$work_dir/assets"
response_file="$work_dir/response.json"
payload_file="$work_dir/payload.json"
trap 'rm -rf -- "$work_dir"' EXIT
mkdir -p "$asset_dir"

api_repo="$CNB_API_URL/$CNB_RELEASE_REPOSITORY"
auth_header="Authorization: Bearer $CNB_TOKEN"
accept_header='Accept: application/vnd.cnb.api+json'
http_status=''

cnb_request() {
    local method="$1"
    local url="$2"
    local expected_statuses="$3"
    local body_file="${4:-}"
    local -a curl_arguments=(
        --silent
        --show-error
        --output "$response_file"
        --write-out '%{http_code}'
        --request "$method"
        --header "$auth_header"
        --header "$accept_header"
    )

    if [[ -n "$body_file" ]]; then
        curl_arguments+=(
            --header 'Content-Type: application/json'
            --data-binary "@$body_file"
        )
    fi

    if ! http_status="$(curl "${curl_arguments[@]}" "$url")"; then
        echo "CNB API 请求失败：$method $url" >&2
        exit 1
    fi
    case ",$expected_statuses," in
        *",$http_status,"*) ;;
        *)
            echo "CNB API 请求失败：$method $url（HTTP $http_status）" >&2
            jq . "$response_file" 2>/dev/null || sed -n '1,80p' "$response_file" >&2
            exit 1
            ;;
    esac
}

prepare_cnb_uploads() {
    local index payload upload_url verify_url

    for index in "$@"; do
        payload="$work_dir/upload-request-$index.json"
        jq -n \
            --arg asset_name "${upload_asset_names[$index]}" \
            --argjson size "${upload_asset_sizes[$index]}" \
            '{asset_name:$asset_name,size:$size,overwrite:true,ttl:0}' \
            > "$payload"
        cnb_request POST \
            "$api_repo/-/releases/$release_id/asset-upload-url" \
            201 \
            "$payload"
        upload_url="$(jq -er '.upload_url' "$response_file")"
        verify_url="$(jq -er '.verify_url' "$response_file")"
        if [[ "$verify_url" != http://* && "$verify_url" != https://* ]]; then
            verify_url="$CNB_API_URL$verify_url"
        fi
        if [[ "$verify_url" == *\?* ]]; then
            verify_url="${verify_url}&ttl=0"
        else
            verify_url="${verify_url}?ttl=0"
        fi
        upload_urls[$index]="$upload_url"
        verify_urls[$index]="$verify_url"
    done
}

upload_cnb_asset() {
    local index="$1"
    local asset_name="${upload_asset_names[$index]}"
    local asset_path="${upload_asset_paths[$index]}"
    local asset_size="${upload_asset_sizes[$index]}"
    local upload_url="${upload_urls[$index]}"
    local verify_url="${verify_urls[$index]}"
    local started_at finished_at elapsed upload_metrics upload_status upload_speed verify_status

    started_at="$(date +%s)"
    echo "[$(date --iso-8601=seconds)] 开始上传 CNB 附件：$asset_name"
    if ! upload_metrics="$(curl --fail-with-body --silent --show-error \
        --retry 2 \
        --retry-all-errors \
        --connect-timeout 30 \
        --speed-limit 10240 \
        --speed-time 120 \
        --request PUT \
        --upload-file "$asset_path" \
        --output "$work_dir/upload-body-$index.txt" \
        --write-out '%{http_code}\t%{time_total}\t%{speed_upload}' \
        "$upload_url")"; then
        echo "上传 CNB 附件失败：$asset_name" >&2
        return 1
    fi
    IFS=$'\t' read -r upload_status _ upload_speed <<< "$upload_metrics"
    case "$upload_status" in
        200|201|204) ;;
        *)
            echo "上传 CNB 附件失败：$asset_name（HTTP $upload_status）" >&2
            return 1
            ;;
    esac

    if ! verify_status="$(curl --silent --show-error \
        --retry 2 \
        --retry-all-errors \
        --connect-timeout 30 \
        --request POST \
        --header "$auth_header" \
        --header "$accept_header" \
        --output "$work_dir/verify-response-$index.json" \
        --write-out '%{http_code}' \
        "$verify_url")"; then
        echo "校验 CNB 附件失败：$asset_name" >&2
        return 1
    fi
    if [[ "$verify_status" != 200 ]]; then
        echo "校验 CNB 附件失败：$asset_name（HTTP $verify_status）" >&2
        jq . "$work_dir/verify-response-$index.json" 2>/dev/null || \
            sed -n '1,80p' "$work_dir/verify-response-$index.json" >&2
        return 1
    fi

    finished_at="$(date +%s)"
    elapsed=$((finished_at - started_at))
    printf '%s\t%s\t%s\t%s\n' \
        "$asset_name" "$asset_size" "$elapsed" "$upload_speed" \
        > "$work_dir/upload-result-$index.tsv"
    awk \
        -v name="$asset_name" \
        -v elapsed="$elapsed" \
        -v speed="$upload_speed" \
        'BEGIN {
            printf "[%s] 上传完成：%d:%02d，%.3f MiB/s\n",
                name, int(elapsed / 60), elapsed % 60, speed / 1048576
        }'
}

upload_cnb_group() {
    local description="$1"
    shift
    local index pid failed=0
    local -a pids=()

    [[ "$#" -gt 0 ]] || return 0
    echo "正在全部并行上传 CNB ${description}（共 $# 个）..."
    for index in "$@"; do
        upload_cnb_asset "$index" &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=1
        fi
    done
    if [[ "$failed" -ne 0 ]]; then
        echo "至少一个 CNB ${description}上传失败。" >&2
        return 1
    fi
}

echo "正在读取 GitHub Release：$RELEASE_TAG"
github_release_json="$work_dir/github-release.json"
gh api \
    "repos/$GITHUB_RELEASE_REPOSITORY/releases/tags/$RELEASE_TAG" \
    > "$github_release_json"

release_name="$(jq -er '.name // .tag_name' "$github_release_json")"
release_body="$(jq -r '.body // ""' "$github_release_json")"
release_prerelease="$(jq -r '
    if (.prerelease | type) == "boolean" then .prerelease
    else error("prerelease is not a boolean")
    end
' "$github_release_json")"
mapfile -t expected_assets < <(jq -er '.assets[].name' "$github_release_json")
if [[ "${#expected_assets[@]}" -eq 0 ]]; then
    echo "GitHub Release $RELEASE_TAG 没有附件，拒绝创建空的 CNB 镜像。" >&2
    exit 1
fi

echo "正在下载 ${#expected_assets[@]} 个 GitHub Release 附件..."
gh release download "$RELEASE_TAG" \
    --repo "$GITHUB_RELEASE_REPOSITORY" \
    --dir "$asset_dir"
for asset_name in "${expected_assets[@]}"; do
    [[ -f "$asset_dir/$asset_name" ]] || {
        echo "缺少已声明的 GitHub Release 附件：$asset_name" >&2
        exit 1
    }
done

cnb_request GET "$api_repo/-/releases/tags/$RELEASE_TAG" '200,404'
if [[ "$http_status" == 200 ]]; then
    release_id="$(jq -er '.id' "$response_file")"
    jq -n \
        --arg name "$release_name" \
        --arg body "$release_body" \
        --argjson prerelease "$release_prerelease" \
        '{name:$name,body:$body,draft:false,prerelease:$prerelease,make_latest:"false"}' \
        > "$payload_file"
    cnb_request PATCH "$api_repo/-/releases/$release_id" 200 "$payload_file"
    echo "正在更新 CNB Release：$RELEASE_TAG"
else
    jq -n \
        --arg tag "$RELEASE_TAG" \
        --arg name "$release_name" \
        --arg body "$release_body" \
        --argjson prerelease "$release_prerelease" \
        '{tag_name:$tag,target_commitish:"main",name:$name,body:$body,draft:false,prerelease:$prerelease,make_latest:"false"}' \
        > "$payload_file"
    cnb_request POST "$api_repo/-/releases" 201 "$payload_file"
    release_id="$(jq -er '.id' "$response_file")"
    echo "已创建 CNB Release：$RELEASE_TAG"
fi

declare -A expected_asset_names=()
declare -a upload_asset_names=()
declare -a upload_asset_paths=()
declare -a upload_asset_sizes=()
declare -a upload_urls=()
declare -a verify_urls=()
declare -a parallel_upload_indexes=()
declare -a manifest_upload_indexes=()
upload_index=0
for asset_name in "${expected_assets[@]}"; do
    expected_asset_names["$asset_name"]=1
    asset_path="$asset_dir/$asset_name"
    asset_size="$(stat --format='%s' "$asset_path")"
    upload_asset_names[$upload_index]="$asset_name"
    upload_asset_paths[$upload_index]="$asset_path"
    upload_asset_sizes[$upload_index]="$asset_size"
    case "$asset_name" in
        *-manifest|SHA256SUMS|SHA256SUMS.*)
            manifest_upload_indexes+=("$upload_index")
            ;;
        *)
            parallel_upload_indexes+=("$upload_index")
            ;;
    esac
    upload_index=$((upload_index + 1))
done

upload_started_at="$(date +%s)"
prepare_cnb_uploads "${parallel_upload_indexes[@]}"
upload_cnb_group "附件" "${parallel_upload_indexes[@]}"

# 清单最后发布，避免同步失败时引用尚未就绪的新软件包。
prepare_cnb_uploads "${manifest_upload_indexes[@]}"
upload_cnb_group "清单" "${manifest_upload_indexes[@]}"
upload_finished_at="$(date +%s)"
upload_elapsed=$((upload_finished_at - upload_started_at))
(( upload_elapsed > 0 )) || upload_elapsed=1

total_uploaded_bytes=0
for result_file in "$work_dir"/upload-result-*.tsv; do
    IFS=$'\t' read -r _ asset_size _ _ < "$result_file"
    total_uploaded_bytes=$((total_uploaded_bytes + asset_size))
done
awk \
    -v bytes="$total_uploaded_bytes" \
    -v elapsed="$upload_elapsed" \
    'BEGIN {
        printf "CNB 全部并行上传完成：%d:%02d，聚合速度 %.3f MiB/s（%.2f Mbit/s）\n",
            int(elapsed / 60), elapsed % 60,
            bytes / 1048576 / elapsed, bytes / 1048576 / elapsed * 8
    }'

# 上传完成后再删除旧附件，避免同步过程中破坏上一份完整镜像。
cnb_request GET "$api_repo/-/releases/$release_id" 200
mapfile -t cnb_asset_rows < <(jq -r '.assets[] | [.id, .name] | @tsv' "$response_file")
for asset_row in "${cnb_asset_rows[@]}"; do
    IFS=$'\t' read -r asset_id asset_name <<< "$asset_row"
    [[ -n "$asset_id" && -n "$asset_name" ]] || continue
    if [[ -z "${expected_asset_names[$asset_name]:-}" ]]; then
        echo "正在删除 CNB 旧附件：$asset_name"
        cnb_request DELETE \
            "$api_repo/-/releases/$release_id/assets/$asset_id" \
            '200,204'
    fi
done

echo "CNB Release 同步完成：https://cnb.cool/$CNB_RELEASE_REPOSITORY/-/releases"
