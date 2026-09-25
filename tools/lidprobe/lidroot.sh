#!/bin/bash
# lidprobe 的 root 半边：一次授权管完「开 → 盯到期 → 还原 → 合盖补睡」全程，
# 中途不再向人要第二次密码。
# 为什么必须有这一层：还原那一步如果还要弹一次授权框，而这时人已经合盖走开（甚至人是在
# 远程会话里点的），弹窗没人点 → disablesleep 永远留在 1，机器就成了"合盖不睡"的黑洞。
# 这正是 §2.2 守卫禁止的状态，所以开和还原必须在同一次提权里绑定完成。
#
# 用法（由 lidprobe.sh 通过 osascript 以 root 起）：
#   lidroot.sh <兜底到期epoch> <取消标记文件> <父进程pid>

set -u
END="${1:?用法: lidroot.sh <到期epoch> <取消标记文件> <父进程pid>}"
CANCEL="${2:?缺少取消标记文件路径}"
PARENT="${3:-}"
# 这一半是苹果 `do shell script ... with administrator privileges` 起的，
# 它给的环境 PATH 是 /bin:/sbin:/usr/bin:/usr/sbin 这一小圈，本机日常 PATH 里那串
# pyenv/homebrew shim 全都不在 —— 所以工具一律写绝对路径，别赌它找得到。
PMSET=/usr/bin/pmset; IOREG=/usr/sbin/ioreg; AWK=/usr/bin/awk; DATE=/bin/date
for _t in "$PMSET" "$IOREG" "$AWK" "$DATE"; do
  [ -x "$_t" ] || { echo "$(date '+%H:%M:%S') [root] 缺少 $_t，无法继续"; exit 2; }
done

LID() { "$IOREG" -r -k AppleClamshellState -d 1 2>/dev/null | "$AWK" -F'= ' '/AppleClamshellState/{gsub(/[ "]/,"",$2); print $2; exit}'; }
LOG() { echo "$("$DATE" '+%H:%M:%S') [root] $*"; }
VAL() { "$PMSET" -g | "$AWK" '/SleepDisabled/{print $2; f=1} END{if(!f)print "missing"}'; }

restore() {
  "$PMSET" -a disablesleep 0
  # 不能只信 pmset 的返回码：非 root 跑它会把 "'pmset' must be run as root..." 打到 stderr
  # 却照样退出 0（本机实测）。所以这里一律以"读回来的值"为准，读不到 0 就是没还原成功，说死它。
  case "$(VAL)" in
    0|missing) LOG "已还原 disablesleep=0" ;;
    *) LOG "!! 还原失败，当前仍是 $(VAL) —— 必须手工执行 sudo pmset -a disablesleep 0" ;;
  esac
}
trap 'restore; exit 0' TERM INT

"$PMSET" -a disablesleep 1
if [ "$(VAL)" != "1" ]; then LOG "开不了 disablesleep（当前 $(VAL)），退出"; exit 1; fi
LOG "disablesleep=1，到期 epoch=$END"

while [ "$("$DATE" +%s)" -lt "$END" ]; do
  if [ -f "$CANCEL" ]; then LOG "收到取消标记，提前收工"; restore; exit 0; fi
  # 父进程被 kill -9 时来不及写标记，所以直接盯它的死活 —— 宁可早还原，不留合盖不睡的黑洞。
  if [ -n "$PARENT" ] && ! kill -0 "$PARENT" 2>/dev/null; then
    LOG "父进程 $PARENT 已不在，立刻还原"; restore; exit 0
  fi
  # 盯的不是"到没到期"，而是"苹果有没有中途把它改回去"（电源/显示拓扑变化后有先例）。
  if [ "$(VAL)" != "1" ]; then
    LOG "SleepDisabled 被改回 $(VAL)，重设一次（这一条会计入被重置次数）"
    "$PMSET" -a disablesleep 1
  fi
  sleep 1
done

restore
# 还原之后盖子还合着 → 苹果不会补睡（XNU 只清标志不重算合盖事件），
# 机器会醒着待在包里直到没电。所以必须主动补一次，留 10 秒给人在现场开盖反悔。
if [ "$(LID)" = "Yes" ]; then
  LOG "退出时盖子仍合着，10 秒内开盖可取消补睡；否则执行 sleepnow"
  sleep 10
  [ "$(LID)" = "Yes" ] && { LOG "仍合盖，补一次 sleepnow"; "$PMSET" sleepnow; } || LOG "已开盖，不补睡"
fi
exit 0
