#!/usr/bin/env bash
# non-dev-harness /ci 상태 확인.
# git 상태와 .planning 위임 작업 상태를 머리말([git] [기록] [변경] [위임] [차단]) 아래에 한 번에 출력한다.
# 명령 하나가 실패해도 나머지는 계속 출력하고, 인자가 잘못된 경우 말고는 항상 종료 코드 0으로 끝난다.
# 사용법: bash status.sh "<루트>" [최근 기록 줄 수, 기본 3]

ROOT="$1"
LOG_LINES="${2:-3}"
case "$LOG_LINES" in
  ''|*[!0-9]*) LOG_LINES=3 ;;
esac
if [ -z "$ROOT" ] || ! cd "$ROOT" 2>/dev/null; then
  echo "사용법: bash status.sh \"<루트>\" [최근 기록 줄 수]" >&2
  exit 2
fi

echo "[git]"; git rev-parse --show-toplevel 2>&1
echo "[기록]"; git log --oneline -n "$LOG_LINES" 2>&1
echo "[변경]"; git status --short -uall -- . 2>/dev/null | wc -l | tr -d ' '
echo "[위임]"; head -n 5 .planning/STATE.md 2>/dev/null && find .planning/STATE.md -mmin +1440 2>/dev/null
echo "[차단]"; grep -E '^[-*] ' .planning/BLOCKERS.md 2>/dev/null | grep -vic '^[-*] \[x\]'
exit 0
