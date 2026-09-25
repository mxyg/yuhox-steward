#!/bin/bash
# S1 §2.2 的阻塞项实测：disablesleep=1 到底挡不挡得住合盖触发的睡眠。
# 判据不靠人眼 —— 本机 pmset 日志里本来就有 'Clamshell Sleep' 这类事件，
# 所以"合盖期间有没有新增一条"就是结论本身。
# 用法：./lidprobe.sh [分钟数，默认 3] [--control]
#   不带 --control = 实验组（开 disablesleep，跑完无条件还原 0）
#   带   --control = 对照组（什么都不改，用来证明这套判据"睡得着的时候确实报得出来"）
# 中途退出/断网都会把 disablesleep 还原回 0。
# 结论不在这个脚本里算，交给同目录 analyze.sh —— 它只读盘，随时可重算。

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
VAL() { pmset -g | awk '/SleepDisabled/{print $2; f=1} END{if(!f)print "missing"}'; }

# 同一时间只许跑一轮。21:27 那轮的现象：取消标记在起跑后 13 秒被写过一次，root 半边当场把
# disablesleep 还原成 0，于是"开着能不能挡住"这一问整程没测到（却顺手证出了坑 #2，见 §7）。
# 当时猜"两轮同秒起跑共用一个标记"，22:09 当场抓到真凶：**是主进程被远程会话断开带走，
# trap 尽职地写了取消标记**（下面那段自脱终端就是冲它去的）。
# 但"文件名共享"这个洞本身是真的：两轮同秒起跑确实会共用取消标记，
# 一轮提前收工就把另一轮的 flag 一起还原了。所以两条都堵：加锁 + 标记按 pid 分开。
LOCK="$HERE/.run.lock"
lock_busy() {
  [ -f "$LOCK" ] || return 1
  local p; p=$(cat "$LOCK" 2>/dev/null || echo)
  # 不许把自己认成"另一轮"：后台那一半起跑时锁里躺的正是它自己的 pid（前台退出前先占上，
  # 免得连敲两次命令挤出两轮）。
  [ "$p" = "$$" ] && return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && ps -o command= -p "$p" 2>/dev/null | grep -q lidprobe
}

# 自己脱离终端再跑。上一轮（22:09）就是这一条救的命：人一合盖、远程会话一断，
# 挂在那个终端上的主进程被收掉，trap 当场把 disablesleep 还原成 0，
# 而盖子恰好在那一秒合上 —— 等于"没开保护"，然后被当成"功能不行"。
# 这个实验的全部前提就是"合盖之后没有任何人再点东西"，所以主进程不许吊在会话上。
if [ -z "${LIDPROBE_BG:-}" ]; then
  if lock_busy; then
    echo "$(TS) 已有一轮在跑（pid $(cat "$LOCK")），本次不启动 —— 两轮会互相踩取消标记。"
    exit 1
  fi
  ARGS="$MINUTES"
  [ "$CONTROL" = 1 ] && ARGS="$MINUTES --control"
  LIDPROBE_BG=1 LIDPROBE_OUT="$OUT" nohup bash "$HERE/lidprobe.sh" $ARGS </dev/null >"$OUT/progress.log" 2>&1 &
  # 锁先按子进程 pid 占上：前台这一下退出得太快，等子进程自己写会露出一瞬的空档，
  # 连敲两次命令就能起两轮 —— 那正是取消标记互相踩的成因。子进程起来会重写同一个值。
  echo $! > "$LOCK"
  echo "$(TS) 已后台起跑（pid $!）：终端关掉、远程掉线都不影响这一轮。"
  echo "     进度： tail -f '$OUT/progress.log'"
  echo "     报告： $OUT/报告.md（跑完自动生成，中途退出也有）"
  echo "     屏幕上会弹**一次**系统授权框，先点它再合盖。"
  exit 0
fi
# 这一半已经是 nohup 起来的子进程：锁的值由前台按本进程 pid 提前占好，不会再被抢，
# 所以这里不重查，直接落自己的 pid 继续跑。
[ -n "${LIDPROBE_OUT:-}" ] && OUT="$LIDPROBE_OUT"
mkdir -p "$OUT/frames"
echo $$ > "$LOCK"

BEFORE_ALL() { pmset -g log 2>/dev/null; }

# 基线必须在提权**之前**落盘。上一轮的 meta 写着 base_SleepDisabled=1，
# 那是我们自己刚设上去的值，不是基线 —— 顺序反了就等于自己给自己造基线。
# `pmset -g log` 一次就要 10 秒（本机实测），所以只抓一次、两个计数都从这一份里数。
BASE_SLEEP=$(VAL)
PMSET_LOG=$(BEFORE_ALL)
CLAM_BEFORE=$(printf '%s\n' "$PMSET_LOG" | grep -c "due to 'Clamshell Sleep'")
IDLE_BEFORE=$(printf '%s\n' "$PMSET_LOG" | grep -c "Entering Sleep state")
{ echo "started_ts=$(TS)"
  echo "started_epoch=$(NOW)"
  echo "minutes=$MINUTES"
  echo "control=$CONTROL"
  echo "base_SleepDisabled=$BASE_SLEEP"
  echo "clamshell_events_before=$CLAM_BEFORE"
  echo "idle_events_before=$IDLE_BEFORE"
  echo "pid=$$"; } > "$OUT/meta.txt"

# 提权只问一次，而且问的那一下就把「开 → 到期 → 还原 → 合盖补睡」整条交给 root 子进程去做。
# 为什么不是一句 sudo 一句 osascript 拼起来：还原那一步若还要弹第二次窗，
# 而那时人已经合盖走开（或就是在远程会话里点的），弹窗没人点，
# disablesleep 就永远留在 1 —— 这个洞比"开不起来"严重得多，§2.2 守卫明令禁止它。
# 命令行里的 sudo 提示远程的人根本看不见，所以首选系统弹窗（= §4 里产品要用的那条路）。
ROOTJOB=""
RESTORED=0
FINALIZED=0
restore() {
  [ "$RESTORED" = 1 ] && return
  RESTORED=1
  [ -n "$ROOTJOB" ] || return
  [ -f "$CANCEL" ] || touch "$CANCEL"
  wait "$ROOTJOB" 2>/dev/null
  echo "$(TS) root 半边已收工，当前 SleepDisabled=$(VAL)"
}
# 收尾只做一次：还原 → 放锁 → 交给 analyze.sh 算结论。
# 放在 finalize 里而不是一行行摊在末尾，是因为上一轮主进程提前退出时，
# 采样数据全在盘上却一个字报告都没有 —— 早退也必须留痕。
finalize() {
  [ "$FINALIZED" = 1 ] && return
  FINALIZED=1
  restore
  rm -f "$LOCK"
  bash "$HERE/analyze.sh" "$OUT" $([ "$CONTROL" = 1 ] && echo --control)
}
trap 'finalize; exit 130' INT TERM
# HUP 也要接住：终端一关、远程会话一断，默认动作是直接收掉进程，
# 那样 disablesleep 就被攥在 1 里没人还原 —— 这条和"弹窗没人点"是同一类洞。
trap 'finalize; exit 129' HUP
trap 'finalize' EXIT
if [ "$CONTROL" = 1 ]; then
  echo "$(TS) 对照组：不改任何电源设置，只测判据本身。"
else
  CANCEL="$OUT/cancel.$$"; rm -f "$CANCEL"
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
  for _ in $(seq 1 90); do
    [ "$(VAL)" = "1" ] && break
    kill -0 "$ROOTJOB" 2>/dev/null || break
    sleep 1
  done
  if [ "$(VAL)" != "1" ]; then
    echo "$(TS) 没开起来（授权没给 / 被取消 / 超过 90 秒没人点窗）。本次不跑，机器状态未改动。"
    # 留个取消标记：万一人是在 90 秒之后才点的，root 半边一看到标记就还原并收工，
    # 不会把 SleepDisabled=1 一直攥到兜底到期。
    restore
    cat "$OUT/root.log" 2>/dev/null | sed 's/^/    /'
    # 这一轮没有采样数据可算（整轮没起跑），所以手写一份"为什么没跑"的报告，
    # 不叫 analyze.sh 去对空目录编结论。
    FINALIZED=1
    { echo "# 本轮未起跑 $(TS)"
      echo
      echo "原因：授权没给 / 被取消 / 90 秒内没人点窗。采样循环还没起，所以目录里没有 heartbeat/flag/frames。"
      echo "机器状态：SleepDisabled=$(VAL)（未改动，或已按取消标记还原）。"
      echo "root 半边输出："; sed 's/^/    /' "$OUT/root.log" 2>/dev/null; } > "$OUT/报告.md"
    echo "$(TS) 报告：$OUT/报告.md"
    rm -f "$LOCK"
    exit 1
  fi
  echo "$(TS) 已开启，SleepDisabled=$(VAL)。"
fi

# 心跳：每秒一条。睡过去就会断档，断档秒数即"睡了三分钟还是只打了个盹"。
# 三个采样循环都带硬到期：上一轮主进程卡在授权弹窗上、没走到收尾的 kill，
# 采样子进程就在后台空转了 8 分钟、多写了几十张全屏图。采样必须自己会停。
DEADLINE=$(( $(NOW) + MINUTES * 60 + 120 ))
( while [ "$(date +%s)" -lt "$DEADLINE" ]; do echo "$(date +%s.%N) $(NOW)"; sleep 1; done > "$OUT/heartbeat.tsv" ) &
HB=$!
# 抓屏循环：证明显示管线在盖子合上后还活着（§2.3 的口径，这里只记"成不成功 + 文件多大"）。
# 每张全屏 PNG ≈ 2–5MB，上一轮吃掉 268MB —— 所以只按大小记账，每 6 张留一张够人工回看。
# 临时文件名**不能以点开头**：`screencapture` 拒写点文件却照样退出 0（本机实测），
# 所以下面除了看返回码，还必须看文件真在不在。
FRAME_MAX=$(( (MINUTES * 60) / 5 + 12 ))
( n=0
  while [ $n -lt "$FRAME_MAX" ]; do
    n=$((n+1)); t=$(date +%s.%N); tmp="$OUT/frames/cur.png"
    screencapture -x -t png "$tmp" 2>"$OUT/frames/err.txt"
    if [ -s "$tmp" ]; then
      echo "$t ok $(stat -f%z "$tmp")"
      if [ $((n % 6)) -eq 1 ]; then mv "$tmp" "$OUT/frames/f$(printf %04d $n).png"; else rm -f "$tmp"; fi
    else
      echo "$t fail 0"
    fi >> "$OUT/frames.tsv"
    sleep 5
  done ) &
FR=$!
# 全程盯两件事，每 2 秒一行：`epoch 盖子状态 SleepDisabled取值`
#  ① 盖子状态：不采这一项，"没睡"有可能只是"盖子根本没合上"，实验白跑。
#     （本机实测 `ioreg -r -k AppleClamshellState` 免密可读，开盖为 No）
#  ② SleepDisabled 取值：苹果会在电源/显示拓扑变化时把它悄悄改回 0（二手证据里最要紧的坑）。
#     不盯这一项，"还是睡过去了"就可能是被重置导致的，而不是 disablesleep 挡不住。
#     上一轮还多证出一条：**合盖那一刻的取值才是关键**，所以这一列一行都不能少。
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
echo "window_start=$T0" >> "$OUT/meta.txt"
echo "window_end=$T1" >> "$OUT/meta.txt"
finalize
