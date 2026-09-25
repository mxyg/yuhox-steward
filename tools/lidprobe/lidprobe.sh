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

# 提权只问一次，而且问的那一下就把「开 → 到期 → 还原 → 合盖补睡」整条交给 root 子进程去做。
# 为什么不是一句 sudo 一句 osascript 拼起来：还原那一步若还要弹第二次窗，
# 而那时人已经合盖走开（或就是在远程会话里点的），弹窗没人点，
# disablesleep 就永远留在 1 —— 这个洞比"开不起来"严重得多，§2.2 守卫明令禁止它。
# 命令行里的 sudo 提示远程的人根本看不见，所以首选系统弹窗（= §4 里产品要用的那条路）。
if [ "$CONTROL" = 1 ]; then
  restore() { :; }
  echo "$(TS) 对照组：不改任何电源设置，只测判据本身。"
else
  CANCEL="$OUT/cancel"; rm -f "$CANCEL"
  # ROOT_END 只是兜底上限，正常收尾走两条快路：父进程写 CANCEL，或父进程没了（kill -9）。
  ROOT_END=$(( $(NOW) + MINUTES * 60 + 600 ))
  if sudo -n true 2>/dev/null; then
    echo "$(TS) 已有免密 sudo 票据，用它起 root 半边。"
    sudo bash "$HERE/lidroot.sh" "$ROOT_END" "$CANCEL" "$$" > "$OUT/root.log" 2>&1 &
  else
    echo "$(TS) 屏幕上会弹**一次**系统授权框 —— 这一次授权同时负责开和还原，中途不再问第二遍。"
    osascript -e "do shell script \"bash '$HERE/lidroot.sh' $ROOT_END '$CANCEL' '$$'\" with administrator privileges" \
      > "$OUT/root.log" 2>&1 &
  fi
  ROOTJOB=$!
  VAL() { pmset -g | awk '/SleepDisabled/{print $2; f=1} END{if(!f)print "missing"}'; }
  for _ in $(seq 1 90); do
    [ "$(VAL)" = "1" ] && break
    kill -0 "$ROOTJOB" 2>/dev/null || break
    sleep 1
  done
  if [ "$(VAL)" != "1" ]; then
    echo "$(TS) 没开起来（授权没给 / 被取消 / 超过 90 秒没人点窗）。本次不跑，机器状态未改动。"
    # 留个取消标记：万一人是在 90 秒之后才点的，root 半边一看到标记就还原并收工，
    # 不会把 SleepDisabled=1 一直攥到兜底到期。
    [ -f "$CANCEL" ] || touch "$CANCEL"
    wait "$ROOTJOB" 2>/dev/null; cat "$OUT/root.log" 2>/dev/null | sed 's/^/    /'
    exit 1
  fi
  echo "$(TS) 已开启，SleepDisabled=$(VAL)。"
  restore() {
    [ -f "$CANCEL" ] || touch "$CANCEL"
    wait "$ROOTJOB" 2>/dev/null
    echo "$(TS) root 半边已收工，当前 SleepDisabled=$(VAL)"
  }
  trap 'restore; exit 130' INT TERM
  trap restore EXIT
fi

BEFORE() { pmset -g log 2>/dev/null | grep -c "due to 'Clamshell Sleep'"; }
BEFORE_IDLE() { pmset -g log 2>/dev/null | grep -c "Entering Sleep state"; }

BASE_SLEEP=$(pmset -g | awk '/SleepDisabled/{print $2; found=1} END{if(!found)print "missing"}')
CLAM_BEFORE=$(BEFORE)
IDLE_BEFORE=$(BEFORE_IDLE)

{ echo "started$(TS)"; echo "base_SleepDisabled=$BASE_SLEEP"; echo "clamshell_events_before=$CLAM_BEFORE"; } > "$OUT/meta.txt"

# 心跳：每秒一条。睡过去就会断档，断档秒数即"睡了三分钟还是只打了个盹"。
# 三个采样循环都带硬到期：上一轮主进程卡在授权弹窗上、没走到收尾的 kill，
# 采样子进程就在后台空转了 8 分钟、多写了几十张全屏图。采样必须自己会停。
DEADLINE=$(( $(NOW) + MINUTES * 60 + 120 ))
( while [ "$(date +%s)" -lt "$DEADLINE" ]; do echo "$(date +%s.%N) $(NOW)"; sleep 1; done > "$OUT/heartbeat.tsv" ) &
HB=$!
# 抓屏循环：证明显示管线在盖子合上后还活着（§2.3 的口径，这里只记"成不成功 + 文件多大"）。
# 每张全屏 PNG ≈ 5MB，本机实测一轮就吃掉 268MB —— 所以只按大小记账，
# 图片每 6 次（≈30 秒）留一张够人工回看，其余抓完即删；循环按窗口时长封顶，不许无限跑。
FRAME_MAX=$(( (MINUTES * 60) / 5 + 12 ))
( n=0
  while [ $n -lt "$FRAME_MAX" ]; do
    n=$((n+1)); t=$(date +%s.%N); f="$OUT/frames/f$(printf %04d $n).png"
    if screencapture -x -t png "$OUT/frames/.cur.png" 2>"$OUT/frames/err.txt"; then
      s=$(stat -f%z "$OUT/frames/.cur.png" 2>/dev/null || echo 0)
      echo "$t ok $s"
      if [ $((n % 6)) -eq 1 ]; then mv "$OUT/frames/.cur.png" "$f"; else rm -f "$OUT/frames/.cur.png"; fi
    else
      echo "$t fail 0"
    fi >> "$OUT/frames.tsv"
    sleep 5
  done ) &
FR=$!
# 全程盯两件事，每 2 秒一行：`epoch 盖子状态 SleepDisabled取值`
#  ① 盖子状态：不采这一项，"没睡"有可能只是"盖子根本没合上"，实验白跑。
#     （本机实测 `ioreg -r -k AppleClamshellState` 免密可读，开盖为 No）
#  ② SleepDisabled 取值：二手证据里最要紧的风险是苹果会在电源/显示拓扑变化时
#     把它悄悄改回 0（有项目为此每 2 秒重设一次）。不盯这一项，
#     "还是睡过去了"就可能是被重置导致的，而不是 disablesleep 挡不住。
( while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    echo "$(NOW) $(ioreg -r -k AppleClamshellState -d 1 2>/dev/null | awk -F'= ' '/AppleClamshellState/{gsub(/[ "]/,"",$2); print $2; exit}') $(pmset -g | awk '/SleepDisabled/{print $2}')"
    sleep 2
  done > "$OUT/flag.tsv" ) &
FL=$!

echo "$(TS) 基线：SleepDisabled=$BASE_SLEEP，历史 Clamshell Sleep 事件 $CLAM_BEFORE 条"
if [ "$CONTROL" = 1 ]; then
  echo "$(TS) 对照组：请在 15 秒内合上盖子，**全程保持合上**满 ${MINUTES} 分钟再打开（中途开盖本次作废）。"
else
  echo "$(TS) 已经开着了。请在 15 秒内合上盖子，**全程保持合上**满 ${MINUTES} 分钟再打开（中途开盖本次作废）。"
fi
T0=$(NOW)
sleep 15   # 留时间给你伸手合盖，避免和后面的计时混在一起
sleep $(( (MINUTES * 60) - 15 ))
T1=$(NOW)

kill $FR $HB $FL 2>/dev/null; wait 2>/dev/null

# 先把盯梢结果算出来，再还原 —— 顺序反了会把"收尾那一下"当成系统自己改的。
# 只看**盖子合着那一段**的取值。全窗口统计会自己骗自己：
# 盯梢循环比 `disablesleep 1` 早起步几秒，那几秒天然是 0，
# 于是"被系统重置了 1 次"是假的 —— 第一次实验组就是这么被脏了一行的。
FLAG_SAMPLES=$(awk '$2=="Yes"' "$OUT/flag.tsv" 2>/dev/null | wc -l | tr -d ' ')
FLAG_MIN=$(awk '$2=="Yes"&&$3!=""{if(m==""||$3+0<m+0)m=$3} END{print (m==""?"none":m)}' "$OUT/flag.tsv" 2>/dev/null)
FLAG_FLIPS=$(awk '$2=="Yes"&&$3!=""{if(s!=""&&$3!=s)n++; s=$3} END{print n+0}' "$OUT/flag.tsv" 2>/dev/null)
LID_YES=$(awk '$2=="Yes"' "$OUT/flag.tsv" 2>/dev/null | wc -l | tr -d ' ')
LID_SECS=$((LID_YES * 2))
# 门槛按时长分档，不是一刀切作废：对照组实测"合盖→真睡着"的延迟只有 ≤4 秒，
# 所以合盖 30 秒以上仍零睡眠事件，已经是十几倍于延迟的正证据，只是窗口没跑满；
# 而只合一两秒（第二轮对照那样）确实什么都没测到。
REQUIRED=$(( (MINUTES * 60 - 15) * 80 / 100 ))
LID_ENOUGH=1; TIER="满格"
if [ "$LID_SECS" -lt "$REQUIRED" ]; then TIER="短时（未达满格 $REQUIRED 秒）"; fi
[ "$LID_SECS" -lt 30 ] && LID_ENOUGH=0
restore

CLAM_AFTER=$(BEFORE); IDLE_AFTER=$(BEFORE_IDLE)
NEW_CLAM=$((CLAM_AFTER - CLAM_BEFORE))
NEW_IDLE=$((IDLE_AFTER - IDLE_BEFORE))
GAP=$(awk 'NR>1{d=$2-p; if(d>g)g=d} {p=$2} END{printf "%d", g+0}' "$OUT/heartbeat.tsv")
FRAMES_OK=$(awk '$2=="ok"' "$OUT/frames.tsv" 2>/dev/null | wc -l | tr -d ' ')
FRAMES_FAIL=$(awk '$2=="fail"' "$OUT/frames.tsv" 2>/dev/null | wc -l | tr -d ' ')

if [ "$LID_YES" -eq 0 ]; then
  VERDICT="本次不作数：盖子全程没合上过（合盖采样 0 次）。别用这个结果下任何结论"
elif [ "$LID_ENOUGH" = 0 ]; then
  VERDICT="本次不作数：合盖时长只有约 ${LID_SECS}s，低于 30 秒下限。对照实测合盖→睡着的延迟只有几秒，这么短根本什么都没测到"
elif [ "$CONTROL" = 1 ]; then
  # 对照组不评价 disablesleep，只评价"这套判据能不能看见一次真实的合盖睡眠"。
  if [ "$NEW_IDLE" -gt 0 ]; then
    VERDICT="对照组按预期睡过去了：窗口内新增 $NEW_IDLE 次睡眠事件（其中 Clamshell $NEW_CLAM），判据可用"
  else
    VERDICT="对照组窗口内一次睡眠都没有 —— 要么盖子没合上，要么判据看不见合盖睡眠。这两种情况下实验组的结果都不作数"
  fi
elif [ "$NEW_IDLE" -eq 0 ] && [ "$GAP" -le 5 ]; then
  VERDICT="挡住合盖了：合盖 ${LID_SECS}s 内零次进睡眠、心跳无断档、SleepDisabled 未回落（时长档位：$TIER）"
elif [ "$NEW_IDLE" -eq 0 ]; then
  VERDICT="没进睡眠但心跳断档 ${GAP}s —— 计时被冻过，去看 flag.tsv 与系统日志再定性"
elif [ "$NEW_CLAM" -gt 0 ] && [ "$FLAG_MIN" = "0" ]; then
  VERDICT="不能判定「挡不住」：窗口内 SleepDisabled 自己掉回 0（最小值 $FLAG_MIN、变化 $FLAG_FLIPS 次）之后才睡的。这测的是「会不会被系统重置」，不是「disablesleep 挡不挡得住」，得先加重设循环再测"
elif [ "$NEW_CLAM" -gt 0 ]; then
  VERDICT="没挡住：窗口内新增 $NEW_CLAM 次 Clamshell Sleep，且全程 SleepDisabled 未回落（最小值 $FLAG_MIN）"
else
  VERDICT="窗口内新增 $NEW_IDLE 次睡眠事件（Clamshell $NEW_CLAM），心跳最大断档 ${GAP}s"
fi

if [ "$CONTROL" = 1 ]; then CHANGED="对照组，全程未改动"; else CHANGED="实验期置 1、收尾还原 0"; fi
cat > "$OUT/报告.md" <<EOF
# 合盖实测报告 $(TS)　$([ "$CONTROL" = 1 ] && echo "对照组" || echo "实验组")

- 计时窗口：$(date -r "$T0" '+%H:%M:%S') → $(date -r "$T1" '+%H:%M:%S')（${MINUTES} 分钟）
- SleepDisabled：基线 $BASE_SLEEP，$CHANGED（当前 $(pmset -g | awk '/SleepDisabled/{print $2}')）
- 盖子状态：合上采样 $FLAG_SAMPLES 次 ≈ $LID_SECS 秒（满格需 ≥ ${REQUIRED}s，本次档位：$TIER；$([ "$LID_ENOUGH" = 1 ] && echo "达标，可用" || echo "低于 30 秒下限，本次不作数")）
- 合盖期间 SleepDisabled 取值：最小 **$FLAG_MIN**，取值变化 **$FLAG_FLIPS** 次（掉回 0 = 被系统重置，不等于挡不住）
- Clamshell Sleep 事件：$CLAM_BEFORE → $CLAM_AFTER（新增 **$NEW_CLAM**）
- 进入睡眠事件（全部原因）：新增 **$NEW_IDLE**
- 心跳最大断档：**${GAP}s**
- 抓屏：成功 $FRAMES_OK 次 / 失败 $FRAMES_FAIL 次

## 结论
**$VERDICT**

## 需要人工补一行
- 远程会话（控境/屏幕共享/SSH）这段时间断过没有：______
  这条是产品口径，不是机制口径 —— 日志能证明"内核有没有睡"，但客户只关心"我远程还连不连得上"。
  两者可能不一致：合盖后掉线也可能是显示/网卡被关而机器并没睡，那种情况下 disablesleep 修不好它。

## 判据说明
'Clamshell Sleep' 是这台机器自己日志里的原话（实测 09-21 开机以来已有 $CLAM_BEFORE 条），
不是我造的口径。所以本实验不需要人判断"好像没睡"，只看这条计数有没有在窗口内涨。

原始材料：heartbeat.tsv / frames.tsv / frames/ / meta.txt，都在本目录。
EOF
echo "$(TS) $VERDICT"
echo "$(TS) 报告：$OUT/报告.md"

# "还原时盖子还合着 → 苹果不补睡 → 机器醒着待在包里"这条坑由 lidroot.sh 那半边负责：
# 它在同一次授权里检测退出时的盖子状态，仍合着就补一次 sleepnow（留 10 秒开盖反悔）。
# 放在 root 半边是因为这里要真执行 sleepnow —— 父进程自己再提一次权，就等于又弹一次没人点的窗。
