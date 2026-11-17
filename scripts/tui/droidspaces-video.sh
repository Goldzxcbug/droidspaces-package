#!/usr/bin/env bash
# Read-only dmd-video-v1 telemetry. No daemon, Python or automatic privilege change.
set -uo pipefail
# Capture the language before selecting a stable locale for parsing.
VIDEO_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
# BEGIN DROIDSPACES SHARED ui
# shellcheck shell=bash
# Shared terminal cells and locale helpers, embedded into standalone releases.
DS_UI_LANGUAGE="${DS_UI_LANGUAGE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}}"
DS_UI_COLUMNS=80
DS_UI_ROWS=24

ds_ui_text() {
    if [[ "${DS_UI_LANGUAGE,,}" == zh* ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

ds_ui_size() {
    local rows="${LINES:-24}" columns="${COLUMNS:-80}"
    if [[ -t 1 ]] && command -v stty >/dev/null 2>&1; then
        read -r rows columns < <(stty size 2>/dev/null) || true
    fi
    [[ "$columns" =~ ^[0-9]+$ ]] && ((columns >= 12)) || columns=80
    [[ "$rows" =~ ^[0-9]+$ ]] && ((rows >= 9)) || rows=24
    DS_UI_COLUMNS="$columns"
    DS_UI_ROWS="$rows"
}

ds_ui_fit() {
    local LC_ALL=C.UTF-8 value="$1" width="$2" char code used=0 size i out=''
    for ((i=0; i<${#value}; i++)); do
        char="${value:i:1}"; printf -v code '%d' "'$char"; size=1
        if ((code < 32 || (code >= 127 && code < 160) || (code >= 0x200b && code <= 0x200f) ||
             (code >= 0x202a && code <= 0x202e) || (code >= 0x2060 && code <= 0x206f))); then continue; fi
        if (((code >= 0x300 && code <= 0x36f) || (code >= 0xfe00 && code <= 0xfe0f) || code == 0x200d)); then size=0
        elif (((code >= 0x1100 && code <= 0x115f) || (code >= 0x2e80 && code <= 0xa4cf) ||
              (code >= 0xac00 && code <= 0xd7a3) || (code >= 0xf900 && code <= 0xfaff) ||
              (code >= 0xfe10 && code <= 0xfe6f) || (code >= 0xff01 && code <= 0xff60) ||
              (code >= 0xffe0 && code <= 0xffe6) || (code >= 0x1f300 && code <= 0x1faff) ||
              (code >= 0x20000 && code <= 0x3ffff))); then size=2; fi
        ((used + size <= width)) || break
        out+="$char"; used=$((used + size))
    done
    printf '%s' "$out"
}
# END DROIDSPACES SHARED ui
export LC_ALL=C.UTF-8

INTERVAL=1
ONCE=false
JSON=false
INTERACTIVE=false
STOP=false
WORK=""
SAVED_TERMINAL=""
TTY_FD=0
COLOR=""
RESET=""
LINES_WRITTEN=0
WIDTH=119
HEIGHT=24
COLLECTOR_PID=""
RESIZED=false
COLLECTION_NOTE=""
SNAPSHOT_STALE=false
SCAN_BUDGET=3

video_msg() { ds_ui_text "$1" "$2"; }
fail() { printf '%s: %s\n' "$(video_msg '视频监控' 'Video monitor')" "$*" >&2; exit 2; }
stop_collector() {
    local attempt
    [[ -n "$COLLECTOR_PID" ]] || return 0
    # A separate collector session lets cancellation reach all descendants.
    # Tools can ignore TERM; never leave the input loop waiting on them.
    kill -TERM -- "-$COLLECTOR_PID" 2>/dev/null || true
    for ((attempt=0; attempt<10; attempt++)); do
        kill -0 -- "-$COLLECTOR_PID" 2>/dev/null || break
        sleep 0.02
    done
    kill -KILL -- "-$COLLECTOR_PID" 2>/dev/null || true
    wait "$COLLECTOR_PID" 2>/dev/null || true
    COLLECTOR_PID=''
}

cleanup() {
    stop_collector
    if [[ -n "$SAVED_TERMINAL" ]]; then
        stty "$SAVED_TERMINAL" <&"$TTY_FD" 2>/dev/null || true
        printf '\033[?25h\033[?1049l'
    fi
    [[ -z "$WORK" ]] || rm -rf -- "$WORK"
}

video_initialize() {

while (($#)); do
    case "$1" in
        --once) ONCE=true ;;
        --json) JSON=true; ONCE=true ;;
        --no-color) export NO_COLOR=1 ;;
        --interval)
            (($# >= 2)) || fail "$(video_msg '--interval 缺少秒数。' '--interval requires seconds.')"
            INTERVAL="$2"; shift
            [[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
                awk -v n="$INTERVAL" 'BEGIN { exit !(n >= 0.2 && n <= 60) }' ||
                fail "$(video_msg '刷新间隔应为 0.2 至 60 秒。' 'Interval must be between 0.2 and 60 seconds.')"
            ;;
        -h|--help)
            printf '%s\n' "$(video_msg '用法：droidspaces-video.sh [--once | --json] [--interval 秒数] [--no-color]' 'Usage: droidspaces-video.sh [--once | --json] [--interval seconds] [--no-color]')" \
                "$(video_msg '读取可访问进程的驱动遥测；q、Esc 或 Ctrl+C 返回。' 'Reads accessible driver telemetry; q, Esc or Ctrl+C returns.')" \
                "$(video_msg '需要 Bash、jq 和 GNU coreutils/findutils；无遥测时状态未知。' 'Requires Bash, jq and GNU coreutils/findutils; absent telemetry means unknown.')"
            exit 0 ;;
        *) fail "$(video_msg "未知参数：$1" "Unknown option: $1")" ;;
    esac
    shift
done
for tool in awk cat cp find getconf jq mktemp readlink rm stat timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "$(video_msg "缺少命令 $tool，请安装后重试。" "Missing command $tool; install it and retry.")"
done
CLOCK_TICKS="$(getconf CLK_TCK)"
[[ "$CLOCK_TICKS" =~ ^[0-9]+$ ]] && ((CLOCK_TICKS > 0 && CLOCK_TICKS <= 1000000)) || fail "$(video_msg '无法读取内核时钟频率。' 'Cannot read the kernel clock frequency.')"
WORK="$(mktemp -d -t droidspaces-video.XXXXXXXX)" || fail "$(video_msg '无法创建临时目录。' 'Cannot create a temporary directory.')"
trap cleanup EXIT
trap 'STOP=true' INT TERM HUP
trap 'RESIZED=true' WINCH
printf '{"sessions":[]}\n' > "$WORK/previous.json"

}

# status defines real/fs UID and explicitly maps nested PID namespaces. stat
# starttime prevents a reused PID from inheriting another process's counters.
process_identity() {
    local path="$1" pid="${1##*/}"
    awk -v pid="$pid" '
        FNR == NR {
            if ($1 == "Pid:") actual=$2
            if ($1 == "Uid:") { uid=$2; effective=$3; fsuid=$5 }
            if ($1 == "NSpid:") {
                mapped=$2
                for (i=3; i<=NF; i++) mapped=mapped "," $i
            }
            next
        }
        { sub(/^.*\) /, ""); start=$20 }
        END {
            if (mapped == "") mapped=pid
            split(mapped, ns, ",")
            if (actual != pid || ns[1] != pid || uid !~ /^[0-9]+$/ ||
                effective !~ /^[0-9]+$/ || fsuid !~ /^[0-9]+$/ || start !~ /^[0-9]+$/) exit 1
            print uid "|" effective "|" fsuid "|" start "|" mapped
        }
    ' "$path/status" "$path/stat" 2>/dev/null
}

prepare_validator() {
cat > "$WORK/validate.jq" <<'JQ'
if length != 1 then error("one record required") else .[0] end
| def uint: type == "number" and . >= 0 and . <= 18446744073709551615 and floor == .;
def codec_label: type == "string" and test("^[A-Za-z0-9_.:+-]{1,64}$");
if type != "object" or
   ([.pid,.context,.width,.height,.hw_completed,.output_frames,.errors,.updated_ns,.last_frame_ns] | all(uint) | not) or
   (.pid as $p | $ns | index($p)) == null or
   (has("uid") and .uid != $uid) or
   (.direction != "decode" and .direction != "encode") or
   (.codec | codec_label | not) or (has("target_fps") | not) or
   .width > 4294967295 or .height > 4294967295
then error("invalid telemetry") else . end
| if (.state != "created" and .state != "active" and .state != "error" and .state != "closed")
     or (.target_fps != null and (.target_fps | type != "number" or . < 0 or . > 1000000))
  then error("invalid state or target FPS") else . end
| {pid:$pid, reported_pid:.pid, uid:$uid, effective_uid:$effective,
   process_start_ticks:$start, memfd_inode:$inode, namespace_pids:$ns,
   context, direction, codec, width, height, hw_completed, output_frames, errors,
   updated_ns, last_frame_ns, target_fps, state,
   identity:([$pid,$start,$device,$inode,.context] | map(tostring) | join(":")),
   comm:($comm | gsub("[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u206f]"; " ")
       | if ascii_downcase == "vlc" then "VLC" elif (ascii_downcase == "obs" or ascii_downcase == "obs64") then "OBS" else . end)}
JQ
}

read_session() {
    local path="$1" process="/proc/$2" pid="$2" before="${3:-}" after uid effective fsuid start mapped
    local file_state="${4:-}" kind owner size device inode status
    [[ -n "$before" ]] || before="$(process_identity "$process")" || { raced=$((raced + 1)); return; }
    IFS='|' read -r uid effective fsuid start mapped <<< "$before"
    [[ -n "$file_state" ]] || file_state="$(LC_ALL=C stat -Lc '%F|%u|%s|%d|%i' -- "$path" 2>/dev/null)" || { raced=$((raced + 1)); return; }
    IFS='|' read -r kind owner size device inode <<< "$file_state"
    [[ "$kind" == 'regular file' && "$owner" == "$fsuid" && "$size" == 4096 ]] || { invalid=$((invalid + 1)); return; }
    # Keep both seqlock reads in one process: launching separate readers can
    # take longer than a frame on Android and reject every active session.
    LC_ALL=C timeout --foreground -k 0.1 0.4 awk -v path="$path" '
        function byte(s,n) { return ord[substr(s,n,1)] }
        function u32(s,n) { return byte(s,n)+256*byte(s,n+1)+65536*byte(s,n+2)+16777216*byte(s,n+3) }
        BEGIN {
            for (i=0; i<256; i++) ord[sprintf("%c",i)]=i
            RS="^$"
            for (attempt=0; attempt<4; attempt++) {
                if ((getline first < path) <= 0) exit 3
                close(path)
                if (length(first) != 4096 || substr(first,1,7) != "DMDVID1" || byte(first,8) != 0 ||
                    u32(first,9) != 1 || u32(first,13) != 4096) exit 2
                if (byte(first,17) % 2) continue
                length_json=u32(first,25)
                if (length_json < 1 || length_json > 4064) exit 2
                if ((getline second < path) <= 0) exit 3
                close(path)
                if (length(second) != 4096 || substr(first,17,8) != substr(second,17,8)) continue
                printf "%s",substr(first,33,length_json)
                exit 0
            }
            exit 4
        }
    ' > "$WORK/payload" 2>/dev/null
    status=$?
    case "$status" in 0) ;; 2) invalid=$((invalid + 1)); return ;; 4) busy=$((busy + 1)); return ;; *) raced=$((raced + 1)); return ;; esac
    after="$(LC_ALL=C stat -Lc '%F|%u|%s|%d|%i' -- "$path" 2>/dev/null)"
    [[ "$after" == "$file_state" && "$(readlink -- "$path" 2>/dev/null)" == '/memfd:dmd-video-v1 (deleted)' &&
       "$(process_identity "$process")" == "$before" ]] || { raced=$((raced + 1)); return; }
    local comm='?'
    IFS= read -r comm < "$process/comm" 2>/dev/null || true
    if ! jq -cse --argjson pid "$pid" --argjson uid "$uid" --argjson effective "$effective" \
        --argjson start "$start" --arg device "$device" --arg inode "$inode" --arg comm "$comm" \
        --argjson ns "[$mapped]" -f "$WORK/validate.jq" "$WORK/payload" >> "$WORK/records" 2>/dev/null; then
        invalid=$((invalid + 1))
    fi
}

collect() {
    local process pid path comm identity uid effective fsuid start mapped application now file_state kind owner size device inode key
    local scanned=0 denied=0 invalid=0 busy=0 raced=0 duplicates=0 budget_reached=false started=$SECONDS
    local -a directories=()
    local -A seen=() identities=()
    : > "$WORK/records"; : > "$WORK/apps"
    # One process enumeration supplies both FD directories and application rows.
    # Cached identity is only a pre-read hint; every record verifies it again.
    for process in /proc/[0-9]*; do
        [[ -d "$process" ]] || continue
        scanned=$((scanned + 1))
        directories+=("$process/fd")
        comm=''; IFS= read -r comm < "$process/comm" 2>/dev/null || continue
        case "${comm,,}" in mpv) application=mpv ;; vlc) application=VLC ;; obs|obs64) application=OBS ;; *) continue ;; esac
        identity="$(process_identity "$process")" || continue
        IFS='|' read -r uid effective fsuid start mapped <<< "$identity"
        pid="${process##*/}"; identities[$pid]="$identity"
        printf '{"pid":%s,"uid":%s,"process_start_ticks":%s,"comm":"%s","application":"%s"}\n' \
            "$pid" "$uid" "$start" "${comm,,}" "$application" >> "$WORK/apps"
    done
    : > "$WORK/candidates"; : > "$WORK/scan-errors"
    if ((${#directories[@]} > 0)); then
        LC_ALL=C timeout --foreground -k 0.1 "$SCAN_BUDGET" find "${directories[@]}" -mindepth 1 -maxdepth 1 \
            -lname '/memfd:dmd-video-v1 (deleted)' -print > "$WORK/candidates" 2> "$WORK/scan-errors"
        case "$?" in 124|137) budget_reached=true ;; esac
    fi
    denied="$(awk '/Permission denied|Operation not permitted/ {n++} END {print n+0}' "$WORK/scan-errors")"
    while IFS= read -r path; do
        if ((SECONDS - started >= SCAN_BUDGET)); then budget_reached=true; break; fi
        [[ "$path" =~ ^/proc/([0-9]+)/fd/[0-9]+$ ]] || continue
        pid="${BASH_REMATCH[1]}"
        identity="${identities[$pid]:-}"
        [[ -n "$identity" ]] || identity="$(process_identity "/proc/$pid")" || { raced=$((raced + 1)); continue; }
        identities[$pid]="$identity"
        IFS='|' read -r uid effective fsuid start mapped <<< "$identity"
        file_state="$(LC_ALL=C stat -Lc '%F|%u|%s|%d|%i' -- "$path" 2>/dev/null)" || { raced=$((raced + 1)); continue; }
        IFS='|' read -r kind owner size device inode <<< "$file_state"
        key="$pid:$start:$device:$inode"
        if [[ -v "seen[$key]" ]]; then duplicates=$((duplicates + 1)); continue; fi
        seen[$key]=1
        read_session "$path" "$pid" "$identity" "$file_state"
    done < "$WORK/candidates"
    # Android containers can virtualize /proc/uptime. A fresh sampler task
    # provides a stable kernel tick clock without Python or wall-clock jumps.
    now="$(awk -v hz="$CLOCK_TICKS" 'BEGIN {
        if ((getline s < "/proc/self/stat") <= 0) exit 1
        sub(/^.*\) /,"",s); split(s,fields," ")
        if (fields[20] !~ /^[0-9]+$/) exit 1
        printf "%.6f\n",fields[20]/hz
    }')" || return 1
    jq -n --argjson now "$now" --argjson uid "$EUID" --argjson scanned "$scanned" --argjson denied "$denied" \
        --argjson invalid "$invalid" --argjson busy "$busy" --argjson raced "$raced" \
        --argjson duplicates "$duplicates" --argjson budget "$budget_reached" \
        --slurpfile rows "$WORK/records" --slurpfile apps "$WORK/apps" --slurpfile previous "$WORK/previous.json" '
        ($previous[0].sessions | map({key:.identity,value:.}) | from_entries) as $old
        | ($rows | unique_by(.identity) | map(
            . as $row | $old[.identity] as $before
            | .sampled_seconds=$now
            | .counter_reset=($before != null and
                (.output_frames < $before.output_frames or .hw_completed < $before.hw_completed or .errors < $before.errors))
            | .observed_output_fps=(if $before == null or .counter_reset or $now <= $before.sampled_seconds then null
                else (.output_frames - $before.output_frames) / ($now - $before.sampled_seconds) end)
            | .hardware_status=(if .hw_completed > 0 then "confirmed" else "pending" end)
            | .activity=(if .state == "error" then "error" elif .state == "closed" then "closed"
                elif .output_frames == 0 then "waiting" elif .observed_output_fps == null then "sampling"
                elif .observed_output_fps == 0 then "idle" else "active" end))) as $sessions
        | {schema_version:1, sampled_seconds:$now, sample_clock:"kernel-start-ticks", collector_uid:$uid,
           software_visibility:"unknown", collection:{processes_scanned:$scanned,permission_denied:$denied,
               invalid_records:$invalid,busy_records:$busy,raced_records:$raced,duplicate_descriptors:$duplicates,scan_budget_reached:$budget}, sessions:$sessions,
           applications:($apps | map(. as $app | .driver_sessions=([$sessions[] |
               select(.pid == $app.pid and .process_start_ticks == $app.process_start_ticks)] | length)
               | .hardware_status=(if .driver_sessions > 0 then "see-driver-sessions" else "unknown" end)))}
    ' > "$WORK/snapshot.next" || return 1
    mv -f -- "$WORK/snapshot.next" "$WORK/snapshot.json"
}

# Limit by terminal cells, including Chinese labels, before adding our own SGR.
fit() {
    ds_ui_fit "$1" "$WIDTH"
}

line() {
    local text="$1" tone="${2:-}" escape=''
    if [[ "$INTERACTIVE" == true ]]; then
        ((LINES_WRITTEN == 0)) || printf '\r\n'
        if [[ -n "$COLOR" ]]; then
            case "$tone" in title) escape=$'\033[36m' ;; muted) escape=$'\033[90m' ;;
                hardware) escape=$'\033[32m' ;; unknown) escape=$'\033[33m' ;; error) escape=$'\033[31m' ;; esac
        fi
        printf '%s%s%s\033[K' "$escape" "$(fit "$text")" "$RESET"
    else
        printf '%s\n' "$(fit "$text")"
    fi
    LINES_WRITTEN=$((LINES_WRITTEN + 1))
}

render() {
    local columns="${COLUMNS:-120}" rows=24 decoding encoding groups total uid denied invalid busy
    local name pid context direction codec width height fps hardware activity errors label size tone row last_group=''
    local shown=0 capacity needed group
    if [[ "$INTERACTIVE" == true ]]; then
        read -r rows columns < <(stty size <&"$TTY_FD") || true
    fi
    [[ "$columns" =~ ^[0-9]+$ ]] && ((columns >= 12)) || columns=80
    [[ "$rows" =~ ^[0-9]+$ ]] && ((rows >= 9)) || rows=24
    WIDTH=$((columns - 1)); HEIGHT="$rows"; LINES_WRITTEN=0
    read -r decoding encoding groups total uid denied invalid busy < <(jq -r '
        [([.sessions[] | select(.direction == "decode")] | length),
           ([.sessions[] | select(.direction == "encode")] | length),
           ([.sessions[] | [.comm,.uid]] + [.applications[] | select(.driver_sessions == 0) | [.application,.uid]] | unique | length),
           ((.sessions | length) + ([.applications[] | select(.driver_sessions == 0)] | length)),
           .collector_uid,.collection.permission_denied,.collection.invalid_records,.collection.busy_records] | @tsv
    ' "$WORK/snapshot.json")
    [[ "$INTERACTIVE" != true ]] || printf '\033[H'
    line "$(video_msg '视频编解码监控  DROIDSPACES' 'Video codec monitor  DROIDSPACES')" title
    if [[ -n "$COLLECTION_NOTE" ]]; then line "$COLLECTION_NOTE" unknown
    else line "$(video_msg "解码 $decoding   编码 $encoding   应用 $groups · UID $uid" "Decode $decoding   Encode $encoding   Apps $groups · UID $uid")"; fi
    printf -v row '%*s' "$WIDTH" ''; line "${row// /─}" muted
    jq -r --argjson stale "$SNAPSHOT_STALE" '
        ([.sessions[] | {name:.comm,uid,pid,context,direction,codec,width,height,
            fps:(if $stale or .observed_output_fps == null then "--" else ((.observed_output_fps * 10 | round) / 10 | tostring) end),
            hardware:.hardware_status,activity:(if $stale then "unknown" else .activity end),errors}] +
         [.applications[] | select(.driver_sessions == 0) | {name:.application,uid,pid,context:"--",direction:"unknown",
            codec:"--",width:0,height:0,fps:"--",hardware:"unknown",activity:"unknown",errors:0}])
        | group_by([.name,.uid]) | sort_by((if any(.[]; .activity == "error") then 0 else 1 end),.[0].name,.[0].uid)
        | .[] | sort_by((if .activity == "error" then 0 else 1 end),.pid,.context)[]
        | [.name,.uid,.pid,.context,.direction,.codec,.width,.height,.fps,.hardware,.activity,.errors] | @tsv
    ' "$WORK/snapshot.json" > "$WORK/view"
    capacity=$((HEIGHT - 7))
    [[ "$INTERACTIVE" == true ]] || capacity=1000000
    if ((columns >= 80 && total > 0 && capacity > 0)); then
        line "$(video_msg '  PID/ID      方向  格式      处理尺寸       输出FPS  硬件/状态' '  PID/ID      Path    Codec     Size            FPS    HW/Status')" muted
    fi
    while IFS=$'\t' read -r name uid pid context direction codec width height fps hardware activity errors; do
        needed=1; ((columns >= 80)) || needed=2
        group="$name/$uid"
        [[ "$group" == "$last_group" ]] || needed=$((needed + 1))
        ((LINES_WRITTEN + needed <= capacity + 3)) || continue
        if [[ "$group" != "$last_group" ]]; then line "$name  ·  UID $uid" title; last_group="$group"; fi
        case "$activity" in
            active) label="$(video_msg '活动' 'active')" ;; idle) label="$(video_msg '空闲' 'idle')" ;;
            waiting) label="$(video_msg '等待' 'waiting')" ;; sampling) label="$(video_msg '待采样' 'sampling')" ;;
            error) label="$(video_msg "错误 $errors" "error $errors")" ;; closed) label="$(video_msg '关闭' 'closed')" ;;
            *) label="$(video_msg '状态未知' 'unknown')" ;;
        esac
        tone=unknown
        [[ "$hardware" != confirmed ]] || tone=hardware
        if ((errors > 0)); then
            [[ "$activity" == error ]] || label+=" · $(video_msg "错误 $errors" "errors $errors")"
            tone=error
        fi
        size='--'; ((width == 0 || height == 0)) || size="${width}×${height}"
        if [[ "$direction" == unknown ]]; then
            line "  PID $pid  $(video_msg '未见驱动会话；状态未知' 'No driver session; unknown')" unknown
            ((columns >= 80)) || line "$(video_msg '  格式 --  处理尺寸 --  输出 -- fps' '  Codec --  Size --  Output -- fps')" muted
        else
            [[ "$direction" != decode ]] && direction="$(video_msg '编码' 'encode')" || direction="$(video_msg '解码' 'decode')"
            [[ "$hardware" == confirmed ]] && hardware="$(video_msg '硬件' 'HW')" || hardware="$(video_msg '待确认' 'pending')"
            if ((columns >= 80)); then
                printf -v row '  %-10s  %s  %-8s  %-13s  %6s  %s/%s' "$pid/$context" "$direction" "${codec^^}" "$size" "$fps" "$hardware" "$label"
                line "$row" "$tone"
            else
                line "  $direction ${codec^^}  ·  $(video_msg '尺寸' 'Size') $size"
                line "  $fps fps · $hardware/$label · PID $pid/$context" "$tone"
            fi
        fi
        shown=$((shown + 1))
    done < "$WORK/view"
    if ((total == 0)); then line "$(video_msg '暂无可读驱动会话；等待应用建立会话。' 'No readable driver sessions; waiting for applications.')" unknown; fi
    if [[ "$INTERACTIVE" == true ]]; then
        while ((LINES_WRITTEN < HEIGHT - 4)); do line ''; done
    fi
    line "$(video_msg "权限不足 $denied · 无效 $invalid · 更新中 $busy · 未显示 $((total - shown))" "Denied $denied · Invalid $invalid · Busy $busy · Hidden $((total - shown))")" muted
    line "$(video_msg '软件编解码：未知；未见遥测不能证明使用软件。' 'Software codecs: unknown; absent telemetry is inconclusive.')" unknown
    line "$(video_msg '处理尺寸以驱动为准；输出 FPS ≠ 播放 FPS。' 'Driver dimensions; output FPS is not playback FPS.')" muted
    line "$(video_msg 'q / Esc / Ctrl+C 返回  ·  自动刷新' 'q / Esc / Ctrl+C back  ·  Auto refresh')" title
    [[ "$INTERACTIVE" != true ]] || printf '\033[J'
}

read_monitor_key() {
    local delay="$1" key=''
    IFS= read -rsn1 -t "$delay" key <&"$TTY_FD" || true
    case "$key" in q|Q|$'\033') STOP=true ;; esac
}

collect_interactive() {
    local status started=$SECONDS
    SNAPSHOT_STALE=true
    # Source definitions only. A completed sample replaces the previous snapshot
    # atomically, so resizing can safely render during an in-progress scan.
    setsid "$BASH" -c 'source "$1"; WORK="$2"; CLOCK_TICKS="$3"; SCAN_BUDGET="$4"; collect' \
        -- "$VIDEO_SCRIPT" "$WORK" "$CLOCK_TICKS" "$SCAN_BUDGET" \
        > "$WORK/collector-output" 2> "$WORK/collector-errors" &
    COLLECTOR_PID=$!
    while kill -0 "$COLLECTOR_PID" 2>/dev/null; do
        read_monitor_key 0.05
        if [[ "$STOP" == true ]]; then stop_collector; return 130; fi
        if [[ "$RESIZED" == true ]]; then RESIZED=false; render; fi
        if ((SECONDS - started > SCAN_BUDGET + 2)); then
            stop_collector
            COLLECTION_NOTE="$(video_msg '采集超时；保留上一快照' 'Scan timed out; showing previous snapshot')"
            return 0
        fi
    done
    wait "$COLLECTOR_PID"; status=$?
    # A timed-out helper may have exited before its own children. Reap the
    # entire isolated group even when the collector itself returned normally.
    kill -KILL -- "-$COLLECTOR_PID" 2>/dev/null || true
    COLLECTOR_PID=''
    ((status == 0)) || return "$status"
    cp -- "$WORK/snapshot.json" "$WORK/previous.next" && \
        mv -f -- "$WORK/previous.next" "$WORK/previous.json" || return 1
    SNAPSHOT_STALE=false
    COLLECTION_NOTE=''
    if jq -e '.collection.scan_budget_reached == true' "$WORK/snapshot.json" >/dev/null 2>&1; then
        COLLECTION_NOTE="$(video_msg '达到扫描预算；当前结果不完整' 'Scan budget reached; current results are incomplete')"
    fi
}

video_main() {
    local status
    video_initialize "$@"
    prepare_validator
    if [[ "$ONCE" == false && -t 0 && -t 1 && "${TERM:-dumb}" != dumb ]]; then
        command -v setsid >/dev/null 2>&1 || fail "$(video_msg '缺少 setsid。' 'Missing setsid.')"
        command -v stty >/dev/null 2>&1 || fail "$(video_msg '缺少 stty。' 'Missing stty.')"
        INTERACTIVE=true
        exec {TTY_FD}</dev/tty || fail "$(video_msg '无法打开控制终端。' 'Cannot open the controlling terminal.')"
        SAVED_TERMINAL="$(stty -g <&"$TTY_FD")" || fail "$(video_msg '无法读取终端设置。' 'Cannot read terminal settings.')"
        stty -echo -icanon min 1 time 0 <&"$TTY_FD" || fail "$(video_msg '无法设置终端输入。' 'Cannot configure terminal input.')"
        printf '\033[?1049h\033[?25l'
        if [[ ! -v NO_COLOR ]]; then COLOR=1; RESET=$'\033[0m'; fi
        printf '%s\r\n%s' "$(video_msg '正在采集视频遥测…' 'Collecting video telemetry…')" "$(video_msg 'q / Esc / Ctrl+C 返回' 'q / Esc / Ctrl+C to return')"
        printf '{"sessions":[],"applications":[],"collector_uid":%s,"collection":{"permission_denied":0,"invalid_records":0,"busy_records":0}}\n' "$EUID" > "$WORK/snapshot.json"
    fi
    while :; do
        if [[ "$INTERACTIVE" == true ]]; then
            collect_interactive || { [[ "$STOP" != true ]] || break; fail "$(video_msg '读取驱动统计失败。' 'Cannot read driver statistics.')"; }
        else
            # One-shot exports have no input loop; timeout bounds the complete
            # scan and JSON construction, including tools that ignore TERM.
            timeout -k 0.2 5 "$BASH" -c 'source "$1"; WORK="$2"; CLOCK_TICKS="$3"; SCAN_BUDGET="$4"; collect' \
                -- "$VIDEO_SCRIPT" "$WORK" "$CLOCK_TICKS" "$SCAN_BUDGET" &
            COLLECTOR_PID=$!
            wait "$COLLECTOR_PID"; status=$?
            kill -KILL -- "-$COLLECTOR_PID" 2>/dev/null || true
            COLLECTOR_PID=''
            if ((status == 124 || status == 137)); then
                fail "$(video_msg '采集超过总时间预算。' 'Collection exceeded the total time budget.')"
            elif ((status != 0)); then
                fail "$(video_msg '读取驱动统计失败。' 'Cannot read driver statistics.')"
            fi
        fi
        [[ "$STOP" != true ]] || break
        if [[ "$JSON" == true ]]; then cat "$WORK/snapshot.json"; break; fi
        render
        [[ "$INTERACTIVE" == true ]] || break
        read_monitor_key "$INTERVAL"
        [[ "$STOP" != true ]] || break
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then video_main "$@"; fi
