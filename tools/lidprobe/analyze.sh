#!/bin/bash
# 只读地把一轮 lidprobe 的原始采样算成结论，写 报告.md。随时可重跑，不改机器。
# 为什么单独成脚本：上一轮主脚本提前退出（取消标记被另一轮踩了），
# 而旧写法把"算结论"和"采集"绑在一起、只在窗口跑完才拼报告 ——
# 于是那一轮 292 个心跳、87 个合盖采样全在盘上，报告却一个字都没有。
# 分析必须能脱离采集独立发生，证据才不会因为一次早退而哑掉。
# 用法：analyze.sh <输出/时间戳 目录> [--control]

set -u
OUT="${1:?用法: analyze.sh <输出/时间戳 目录> [--control]}"
[ -d "$OUT" ] || { echo "目录没有这一轮: $OUT"; exit 1; }
META="$OUT/meta.txt"; HB="$OUT/heartbeat.tsv"; FL="$OUT/flag.tsv"; FR="$OUT/frames.tsv"
TS() { date '+%Y-%m-%d %H:%M:%S'; }
KEY() { awk -F= -v k="$1" '$1==k{print $2}' "$META" 2>/dev/null | tail -1; }
VAL() { pmset -g | awk '/SleepDisabled/{print $2; f=1} END{if(!f)print "missing"}'; }
DHS() { date -r "$1" '+%H:%M:%S' 2>/dev/null || echo "?"; }

MINUTES=$(KEY minutes); CONTROL=$(KEY control)
MINUTES_NOTE=""
[ "${2:-}" = "--control" ] && CONTROL=1
[ -z "$CONTROL" ] && CONTROL="?"   # 旧格式的 meta 没记这一项，报告里如实显示 ?
CLAM_BEFORE=$(KEY clamshell_events_before); IDLE_BEFORE=$(KEY idle_events_before)
BASE_SLEEP=$(KEY base_SleepDisabled)
T0=$(KEY window_start); T1=$(KEY window_end)
HB_FIRST=$(awk 'NR==1{print $2}' "$HB" 2>/dev/null)
HB_LAST=$(tail -1 "$HB" 2>/dev/null | awk '{print $2}')
[ -z "$T0" ] && T0="$HB_FIRST"
[ -z "$T1" ] && T1="$HB_LAST"
[ -z "$MINUTES" ] && { MINUTES=$(( ( (${T1:-0} - ${HB_FIRST:-0}) + 30 ) / 60 )); MINUTES_NOTE="（meta 没记分钟数，按采样跨度推算，仅供分档用）"; }
# 跑没跑完，不靠估时长（采样会一直跑到硬到期，看着很足）——主进程走完窗口才会写 window_end。
# 只有新格式的 meta 才有 started_epoch，老几轮压根没这两个键，不能反过来判它们"中途退了"。
if [ -n "$(KEY started_epoch)" ] && [ -z "$(KEY window_end)" ]; then
  EARLY="（**主进程没跑完就退了**：meta 里没有 window_end；下面这些数字仍按实际采样算）"
elif [ -z "$(KEY started_epoch)" ]; then
  EARLY="（这一轮跑在 window_end 这个字段加上之前，报告由事后重算生成）"
else
  EARLY=""
fi

# 睡眠事件按**日志时间戳落在窗口内**数，不用"事后总数 − 基线"：
# 隔几小时再重算一轮，增量口径会把窗口之外的其它睡眠一并算进来，那就不是这一轮的数了。
# `pmset -g log` 一次要 10 秒（本机实测），所以整轮只抓一次，后面全从这份快照里数。
PMSET_LOG=$(pmset -g log 2>/dev/null)
count_events() {
  local pat="$1" n=0 ts e lines
  lines=$(printf '%s\n' "$PMSET_LOG" | grep -F "$pat")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ts=$(echo "$line" | awk '{print $1" "$2" "$3}')
    e=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$ts" +%s 2>/dev/null) || continue
    [ -n "$T0" ] && [ -n "$T1" ] && [ "$e" -ge "$((T0 - 5))" ] && [ "$e" -le "$((T1 + 5))" ] && n=$((n+1))
  done <<< "$lines"
  echo "$n"
}
CLAM_NOW=$(printf '%s\n' "$PMSET_LOG" | grep -c "due to 'Clamshell Sleep'")
IDLE_NOW=$(printf '%s\n' "$PMSET_LOG" | grep -c "Entering Sleep state")
NEW_CLAM=$(count_events "due to 'Clamshell Sleep'")
NEW_IDLE=$(count_events "Entering Sleep state")

# 盖子与取值。只看**盖子合着那一段**：全窗口统计会自己骗自己 ——
# 盯梢比 disablesleep 早起步几秒，那几秒天然是 0，于是"被系统重置 1 次"是假的。
FLAG_SAMPLES=$(awk '$2=="Yes"' "$FL" 2>/dev/null | wc -l | tr -d ' ')
HAS_LID=1
[ -s "$FL" ] || HAS_LID=0   # 最早几轮没有 flag.tsv（那时还没这个传感器），不能当成"盖子没合上"
FLAG_MIN=$(awk '$2=="Yes"&&$3!=""{if(m==""||$3+0<m+0)m=$3} END{print (m==""?"none":m)}' "$FL" 2>/dev/null)
FLAG_FLIPS=$(awk '$2=="Yes"&&$3!=""{if(s!=""&&$3!=s)n++; s=$3} END{print n+0}' "$FL" 2>/dev/null)
CLOSE_VAL=$(awk '$2=="Yes"&&$3!=""{print $3; exit}' "$FL" 2>/dev/null)
ON_SECS=$(( $(awk '$2=="Yes"&&$3=="1"' "$FL" 2>/dev/null | wc -l | tr -d ' ') * 2 ))
OFF_SECS=$(( $(awk '$2=="Yes"&&$3=="0"' "$FL" 2>/dev/null | wc -l | tr -d ' ') * 2 ))
LID_YES=$FLAG_SAMPLES
LID_SECS=$((LID_YES * 2))
GAP=$(awk 'NR>1{d=$2-p; if(d>g)g=d} {p=$2} END{printf "%d", g+0}' "$HB" 2>/dev/null)
HB_N=$(wc -l < "$HB" 2>/dev/null | tr -d ' ')
FRAMES_OK=$(awk '$2=="ok"' "$FR" 2>/dev/null | wc -l | tr -d ' ')
FRAMES_FAIL=$(awk '$2=="fail"' "$FR" 2>/dev/null | wc -l | tr -d ' ')

REQUIRED=$(( (MINUTES * 60 - 15) * 80 / 100 ))
TIER="满格"; LID_ENOUGH=1
[ "$LID_SECS" -lt "$REQUIRED" ] && TIER="短时（未达满格 $REQUIRED 秒）"
[ "$LID_SECS" -lt 30 ] && LID_ENOUGH=0

if [ "$HAS_LID" = 0 ]; then
  if [ "$NEW_CLAM" -gt 0 ]; then
    VERDICT="这一轮没有盖子采样文件（早于 flag.tsv 传感器），但窗口内出现 $NEW_CLAM 条 Clamshell Sleep、心跳断档 ${GAP}s —— 这类事件只有真合上盖才记，所以「合过盖」由事件本身成立。判据在这一轮是：$([ "$CONTROL" = 1 ] && echo "对照组确实睡过去了，判据可用" || echo "实验组仍睡过去了，说明没挡住")"
  else
    VERDICT="这一轮**没有盖子采样文件**（早于 flag.tsv 传感器），所以「合没合上、合了多久」无法自证：窗口内 Clamshell 新增 ${NEW_CLAM}、进睡眠新增 ${NEW_IDLE}、心跳最大断档 ${GAP}s。这组数只能当「没检测到睡眠」用，不能当「挡住了睡眠」用"
  fi
elif [ "$LID_YES" -eq 0 ]; then
  VERDICT="本次不作数：盖子全程没合上过（合盖采样 0 次）。别用这个结果下任何结论"
elif [ "$LID_ENOUGH" = 0 ]; then
  VERDICT="本次不作数：合盖时长只有约 ${LID_SECS}s，低于 30 秒下限。对照实测合盖→睡着的延迟只有几秒，这么短根本什么都没测到"
elif [ "$CONTROL" = 1 ]; then
  if [ "$NEW_IDLE" -gt 0 ]; then
    VERDICT="对照组按预期睡过去了：窗口内新增 $NEW_IDLE 次睡眠事件（其中 Clamshell ${NEW_CLAM}），判据可用"
  else
    VERDICT="对照组窗口内一次睡眠都没有 —— 要么盖子没合上，要么判据看不见合盖睡眠。这两种情况下实验组的结果都不作数"
  fi
elif [ "$NEW_IDLE" -gt 0 ]; then
  VERDICT="睡了：窗口内新增 $NEW_IDLE 次进入睡眠（Clamshell ${NEW_CLAM}），心跳最大断档 ${GAP}s。合盖期间 flag=1 约 ${ON_SECS}s、=0 约 ${OFF_SECS}s —— 先分清是「挡不住」还是「被重置」"
elif [ "${GAP:-0}" -gt 5 ]; then
  VERDICT="没进睡眠但心跳断档 ${GAP}s —— 计时被冻过，去看 flag.tsv 与系统日志再定性"
elif [ "$ON_SECS" -ge "$REQUIRED" ]; then
  VERDICT="挡住合盖了：合盖 ${LID_SECS}s 里 flag=1 覆盖 ${ON_SECS}s（≥ 满格线 $REQUIRED 秒），零次进睡眠、心跳无断档（时长档位：${TIER}）"
elif [ "$CLOSE_VAL" = "1" ] && [ "$OFF_SECS" -ge 30 ]; then
  VERDICT="这一轮没测「开着挡不挡得住」，但把坑 #2 从二手升级成本机实测：合盖那一刻 flag=1，随后 flag 被还原成 0，盖子继续合着 ${OFF_SECS}s，仍**零睡眠事件、心跳零断档**。也就是苹果只在合盖那一下判一次，还原不会补睡 —— §2.2 的守卫还原时必须自己补一次 sleepnow"
elif [ "$FLAG_MIN" = "0" ]; then
  VERDICT="不能判定「挡不住」：窗口内 SleepDisabled 掉回过 0（最小值 ${FLAG_MIN}、变化 $FLAG_FLIPS 次）。这测的是「会不会被重置」，得排除重置这一层再重测"
else
  VERDICT="合盖 ${LID_SECS}s 零睡眠事件，但 flag=1 只覆盖 ${ON_SECS}s（满格要 ≥$REQUIRED 秒），档位：$TIER —— 是正证据，只是窗口没跑满"
fi

if [ "$CONTROL" = 1 ]; then CHANGED="对照组，全程未改动"; else CHANGED="实验期置 1、收尾还原 0"; fi
if [ "$HAS_LID" = 0 ]; then
  LID_LINES="- 盖子状态：这一轮**没有 flag.tsv**（跑在该传感器加上之前），合盖时长与合盖期间的取值都无法自证 —— 下面只按事件与心跳判。"
else
  LID_LINES="- 盖子状态：合上采样 $FLAG_SAMPLES 次 ≈ $LID_SECS 秒（满格需 ≥ ${REQUIRED}s，本次档位：${TIER}；$([ "$LID_ENOUGH" = 1 ] && echo "达标，可用" || echo "低于 30 秒下限，本次不作数")）
- **合盖那一刻的取值：${CLOSE_VAL:-?}** —— 这条决定这一轮到底在回答哪个问题
- 合盖期间取值：flag=1 约 ${ON_SECS}s / flag=0 约 ${OFF_SECS}s；最小 **$FLAG_MIN**，取值变化 **$FLAG_FLIPS** 次"
fi
{ cat <<EOF
# 合盖实测报告 $(TS)　$([ "$CONTROL" = 1 ] && echo "对照组" || echo "实验组 $([ "$CONTROL" = "?" ] && echo "（meta 未记，按实验组算）")")

- 采样：$HB_N 个心跳，$(DHS "${HB_FIRST:-0}") → $(DHS "${HB_LAST:-0}")（$MINUTES 分钟档）$MINUTES_NOTE$EARLY
- SleepDisabled：基线 ${BASE_SLEEP:-?}，${CHANGED}（分析时 $(VAL)）
$LID_LINES
- Clamshell Sleep 事件：基线 ${CLAM_BEFORE:-?} → 现存 ${CLAM_NOW}；**窗口内新增 $NEW_CLAM**（按日志时间戳数进窗口的）
- 进入睡眠事件（全部原因）：基线 ${IDLE_BEFORE:-未记} → 现存 ${IDLE_NOW}；**窗口内新增 $NEW_IDLE**
- 心跳最大断档：**${GAP:-?}s**
- 抓屏：成功 $FRAMES_OK 次 / 失败 $FRAMES_FAIL 次（每张只记大小，每 6 张留一张）

## 结论
**$VERDICT**

## 需要人工补一行
- 远程会话（控境/屏幕共享/SSH）这段时间断过没有：______
  这条是产品口径，不是机制口径 —— 日志能证明"内核有没有睡"，但客户只关心"我远程还连不连得上"。
  两者可能不一致：合盖后掉线也可能是显示/网卡被关而机器并没睡，那种情况下 disablesleep 修不好它。

## 判据说明
'Clamshell Sleep' 是这台机器自己日志里的原话，不是我造的口径。所以本实验不需要人判断"好像没睡"，
只看窗口时间戳里有没有这种条目。窗口内计数用的是日志自带时间戳，所以事后多久重算都是同一个数 ——
上一轮就是这样补出来的。

原始材料：heartbeat.tsv / frames.tsv / frames/ / meta.txt / root.log，都在本目录。
EOF
} > "$OUT/报告.md"
echo "$(TS) $VERDICT"
echo "$(TS) 报告：$OUT/报告.md"
