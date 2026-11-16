#!/usr/bin/env bash
# non-dev-harness /ci 상태 확인.
# git 상태와 .planning 위임 작업 상태를 머리말([git] [기록] [변경] [위임] [차단]) 아래에 한 번에 출력한다.
# 명령 하나가 실패해도 나머지는 계속 출력하고, 인자가 잘못된 경우 말고는 항상 종료 코드 0으로 끝난다.
# 사용법: bash status.sh "<루트>" [최근 기록 줄 수, 기본 3]

# git 안내 문장을 영어로 고정한다(SKILL.md가 영어 문장으로 상태를 판단함).
export LC_ALL=C

ROOT="$1"
LOG_LINES="${2:-3}"
case "$LOG_LINES" in
  ''|*[!0-9]*) LOG_LINES=3 ;;
esac
unset CDPATH
if [ -z "$ROOT" ] || ! cd -- "$ROOT" 2>/dev/null; then
  echo "사용법: bash status.sh \"<루트>\" [최근 기록 줄 수]" >&2
  exit 2
fi

echo "[git]"; git rev-parse --show-toplevel 2>&1
echo "[기록]"; git log --oneline -n "$LOG_LINES" 2>&1
echo "[변경]"
# 저장소가 아니면 0([git]의 오류로 판단). 저장소인데 git이 상태를 읽지 못하면(소유자 불일치 등) 숫자 대신 "확인 못 함".
if INSIDE_ERR="$(git rev-parse --is-inside-work-tree 2>&1 > /dev/null)"; then
  if CHANGES="$(git status --short -uall -- . 2>/dev/null)"; then
    if [ -z "$CHANGES" ]; then echo 0; else printf '%s\n' "$CHANGES" | wc -l | tr -d ' '; fi
  else
    echo "확인 못 함"
  fi
else
  case "$INSIDE_ERR" in
    *"not a git repository"*) echo 0 ;;
    *) echo "확인 못 함" ;;
  esac
fi
echo "[위임]"; head -n 5 .planning/STATE.md 2>/dev/null && find .planning/STATE.md -mmin +1440 2>/dev/null
echo "[차단]"; grep -E '^[-*] ' .planning/BLOCKERS.md 2>/dev/null | grep -vic '^[-*] \[x\]'
exit 0
