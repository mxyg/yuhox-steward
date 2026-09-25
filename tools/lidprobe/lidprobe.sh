#!/bin/bash
# S1 §2.2 的阻塞项实测：disablesleep=1 到底挡不挡得住合盖触发的睡眠。
# 判据不靠人眼 —— 本机 pmset 日志里本来就有 'Clamshell Sleep' 这类事件，
# 所以"合盖期间有没有新增一条"就是结论本身。
# 用法：./lidprobe.sh [分钟数，默认 3] [--control]
#   不带 --control = 实验组（开 disablesleep，跑完无条件还原 0）
#   带   --control = 对照组（什么都不改，用来证明这套判据"睡得着的时候确实报得出来"）
# 中途退出/断网都会把 disablesleep 还原回 0。

set -u
MINUTES="${1:-3}"
CONTROL=0
[ "${2:-}" = "--control" ] && CONTROL=1
case "$MINUTES" in ''|*[!0-9]*) echo "分钟数得是整数（例：$0 3）"; exit 1 ;; esac
[ "$MINUTES" -lt 1 ] && { echo "至少 1 分钟，否则合盖动作来不及发生"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/输出/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/frames"

TS() { date '+%Y-%m-%d %H:%M:%S'; }
NOW() { date +%s; }

if [ "$CONTROL" = 1 ]; then
  restore() { :; }
  echo "$(TS) 对照组：不改任何电源设置，只测判据本身。"
else
  sudo -p "本脚本只需一次 sudo（改 pmset）: " true || { echo "拿不到 sudo，退出。机器状态未改动。"; exit 1; }
  RESTORED=0
  restore() {
    [ "$RESTORED" = 1 ] && return
    RESTORED=1
    sudo pmset -a disablesleep 0 && echo "$(TS) 已还原 disablesleep=0"
  }
  trap 'restore; exit 130' INT TERM
  trap restore EXIT
fi

BEFORE() { pmset -g log 2>/dev/null | grep -c "due to 'Clamshell Sleep'"; }
BEFORE_IDLE() { pmset -g log 2>/dev/null | grep -c "Entering Sleep state"; }

BASE_SLEEP=$(pmset -g | awk '/SleepDisabled/{print $2}')
CLAM_BEFORE=$(BEFORE)
IDLE_BEFORE=$(BEFORE_IDLE)

{ echo "started$(TS)"; echo "base_SleepDisabled=$BASE_SLEEP"; echo "clamshell_events_before=$CLAM_BEFORE"; } > "$OUT/meta.txt"

# 心跳：每秒一条。睡过去就会断档，断档秒数即"睡了三分钟还是只打了个盹"。
( while :; do echo "$(date +%s.%N) $(NOW)"; sleep 1; done > "$OUT/heartbeat.tsv" ) &
HB=$!
# 抓屏循环：证明显示管线在盖子合上后还活着（§2.3 的口径，这里只记"成不成功 + 文件多大"）。
( n=0; while [ $n -lt 9999 ]; do
    n=$((n+1)); t=$(date +%s.%N)
    if screencapture -x -t png "$OUT/frames/f$(printf %04d $n).png" 2>"$OUT/frames/err.txt"; then
      s=$(stat -f%z "$OUT/frames/f$(printf %04d $n).png" 2>/dev/null || echo 0)
      echo "$t ok $s"
    else
      echo "$t fail 0"
    fi >> "$OUT/frames.tsv"
    sleep 5
  done ) &
FR=$!

echo "$(TS) 基线：SleepDisabled=$BASE_SLEEP，历史 Clamshell Sleep 事件 $CLAM_BEFORE 条"
if [ "$CONTROL" = 1 ]; then
  echo "$(TS) 对照组：请在 15 秒内合上盖子，等满 ${MINUTES} 分钟再打开。"
else
  echo "$(TS) 现在开启 disablesleep。请在 15 秒内合上盖子，等满 ${MINUTES} 分钟再打开。"
  sudo pmset -a disablesleep 1 || { echo "开不了 disablesleep，测不下去。"; exit 1; }
  pmset -g | grep SleepDisabled
fi
T0=$(NOW)
sleep 15   # 留时间给你伸手合盖，避免和后面的计时混在一起
sleep $(( (MINUTES * 60) - 15 ))
T1=$(NOW)

kill $FR $HB 2>/dev/null; wait 2>/dev/null
restore

CLAM_AFTER=$(BEFORE); IDLE_AFTER=$(BEFORE_IDLE)
NEW_CLAM=$((CLAM_AFTER - CLAM_BEFORE))
NEW_IDLE=$((IDLE_AFTER - IDLE_BEFORE))
GAP=$(awk 'NR>1{d=$2-p; if(d>g)g=d} {p=$2} END{printf "%d", g+0}' "$OUT/heartbeat.tsv")
FRAMES_OK=$(awk '$2=="ok"' "$OUT/frames.tsv" 2>/dev/null | wc -l | tr -d ' ')
FRAMES_FAIL=$(awk '$2=="fail"' "$OUT/frames.tsv" 2>/dev/null | wc -l | tr -d ' ')

if [ "$CONTROL" = 1 ]; then
  # 对照组不评价 disablesleep，只评价"这套判据能不能看见一次真实的合盖睡眠"。
  if [ "$NEW_IDLE" -gt 0 ]; then
    VERDICT="对照组按预期睡过去了：窗口内新增 $NEW_IDLE 次睡眠事件（其中 Clamshell $NEW_CLAM），判据可用"
  else
    VERDICT="对照组窗口内一次睡眠都没有 —— 要么盖子没合上，要么判据看不见合盖睡眠。这两种情况下实验组的结果都不作数"
  fi
elif [ "$NEW_IDLE" -eq 0 ] && [ "$GAP" -le 5 ]; then
  VERDICT="挡住合盖了：窗口内零次进睡眠，心跳无断档"
elif [ "$NEW_CLAM" -gt 0 ]; then
  VERDICT="没挡住：窗口内新增 $NEW_CLAM 次 Clamshell Sleep"
else
  VERDICT="窗口内新增 $NEW_IDLE 次睡眠事件（Clamshell $NEW_CLAM），心跳最大断档 ${GAP}s"
fi

if [ "$CONTROL" = 1 ]; then CHANGED="对照组，全程未改动"; else CHANGED="实验期置 1、收尾还原 0"; fi
cat > "$OUT/报告.md" <<EOF
# 合盖实测报告 $(TS)　$([ "$CONTROL" = 1 ] && echo "对照组" || echo "实验组")

- 计时窗口：$(date -r "$T0" '+%H:%M:%S') → $(date -r "$T1" '+%H:%M:%S')（${MINUTES} 分钟）
- SleepDisabled：基线 $BASE_SLEEP，$CHANGED（当前 $(pmset -g | awk '/SleepDisabled/{print $2}')）
- Clamshell Sleep 事件：$CLAM_BEFORE → $CLAM_AFTER（新增 **$NEW_CLAM**）
- 进入睡眠事件（全部原因）：新增 **$NEW_IDLE**
- 心跳最大断档：**${GAP}s**
- 抓屏：成功 $FRAMES_OK 次 / 失败 $FRAMES_FAIL 次

## 结论
**$VERDICT**

## 判据说明
'Clamshell Sleep' 是这台机器自己日志里的原话（实测 09-21 开机以来已有 $CLAM_BEFORE 条），
不是我造的口径。所以本实验不需要人判断"好像没睡"，只看这条计数有没有在窗口内涨。

原始材料：heartbeat.tsv / frames.tsv / frames/ / meta.txt，都在本目录。
EOF
echo "$(TS) $VERDICT"
echo "$(TS) 报告：$OUT/报告.md"
