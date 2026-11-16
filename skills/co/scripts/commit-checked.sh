#!/usr/bin/env bash
# non-dev-harness: 비밀 파일 검사를 통과했을 때만 커밋한다 (/co, /hs가 함께 씀).
# 같은 폴더의 check-staged.sh를 돌려 그 출력을 그대로 보여 주고, 결과를 스스로 판정한 뒤 커밋한다.
# 검사와 커밋을 한 실행으로 묶어, 검사를 건너뛰거나 검사하지 않은 내용을 커밋하는 길을 막는다.
#
# 사용법: bash commit-checked.sh "<하네스 루트>" "<커밋 메시지>" [--allow "<경로>"]... [-- "<경로>"...]
#   -- 뒤에 경로를 주면 그 경로의 작업 파일 내용만 커밋한다(/hs). 경로는 하네스 루트 기준이고 글자 그대로 쓴다(패턴 아님).
#     이때는 HEAD에 그 경로만 담은 임시 인덱스를 만들어 그 인덱스를 검사하고, 검사한 그 인덱스로 커밋한다.
#     그래서 미리 스테이징된 다른 파일은 커밋에 들어가지 않고, 커밋되는 내용과 검사한 내용이 항상 같다.
#   경로가 없으면 스테이징된 전부를 검사하고 그 스테이징을 그대로 커밋한다(/co).
#   --allow는 check-staged.sh에 그대로 넘긴다(사용자가 비밀이 아니라고 한 파일).
#   그 밖의 옵션은 받지 않는다. 메시지에 "Claude-Session:"으로 시작하는 줄이 있으면 거부한다.
# 출력: check-staged.sh의 출력 뒤에 판정 줄.
#   [커밋] <짧은 해시> <제목>                     커밋함(종료 코드 0)
#   [커밋 안 함] <이유>                            커밋하지 않음
# 종료 코드: 0 커밋함, 2 사용법·메시지 오류, 3 검사 실패(또는 커밋할 파일을 준비하지 못함), 4 걸린 파일 있음, 5 git commit 실패

export LC_ALL=C

usage() {
  echo "사용법: bash commit-checked.sh \"<하네스 루트>\" \"<커밋 메시지>\" [--allow \"<경로>\"]... [-- \"<경로>\"...]" >&2
  exit 2
}

[ $# -ge 2 ] || usage
ROOT="$1"
MSG="$2"
shift 2
[ -n "$ROOT" ] && [ -n "$MSG" ] || usage

if printf '%s\n' "$MSG" | grep -q '^Claude-Session:'; then
  echo "메시지 오류: Claude-Session 줄을 빼고 다시 실행하세요" >&2
  exit 2
fi

ALLOW=()
PATHS=()
HAVE_PATHS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allow)
      [ $# -ge 2 ] || usage
      ALLOW+=(--allow "$2")
      shift 2
      ;;
    --)
      shift
      HAVE_PATHS=1
      PATHS=("$@")
      break
      ;;
    *) usage ;;
  esac
done
[ "$HAVE_PATHS" -eq 0 ] || [ ${#PATHS[@]} -gt 0 ] || usage

DIR="$(cd "$(dirname "$0")" && pwd)" || { echo "[커밋 안 함] 스크립트 폴더를 찾지 못했습니다"; exit 3; }

if [ "$HAVE_PATHS" -eq 1 ]; then
  # 경로 커밋: HEAD(없으면 빈 트리)에 지정 경로의 작업 파일만 더한 임시 인덱스를 만든다.
  # 경로는 글자 그대로 읽고(패턴·매직 없음), 검사와 커밋 모두 이 임시 인덱스로 한다.
  export GIT_LITERAL_PATHSPECS=1
  TMP_INDEX="$(mktemp "${TMPDIR:-/tmp}/ndh-index.XXXXXX")" || { echo "[커밋 안 함] 임시 파일을 만들지 못했습니다"; exit 3; }
  rm -f "$TMP_INDEX"
  trap 'rm -f "$TMP_INDEX"' EXIT
  export GIT_INDEX_FILE="$TMP_INDEX"
  if git -C "$ROOT" rev-parse --verify -q HEAD > /dev/null; then
    git -C "$ROOT" read-tree HEAD || { echo "[커밋 안 함] 커밋할 파일을 준비하지 못했습니다"; exit 3; }
  else
    git -C "$ROOT" read-tree --empty || { echo "[커밋 안 함] 커밋할 파일을 준비하지 못했습니다"; exit 3; }
  fi
  git -C "$ROOT" add -A -- "${PATHS[@]}" || { echo "[커밋 안 함] 지정한 경로를 담지 못했습니다"; exit 3; }
fi

if [ ${#ALLOW[@]} -gt 0 ]; then
  OUT="$(bash "$DIR/check-staged.sh" "$ROOT" "${ALLOW[@]}")"; RC=$?
else
  OUT="$(bash "$DIR/check-staged.sh" "$ROOT")"; RC=$?
fi
printf '%s\n' "$OUT"
if [ "$RC" -ne 0 ] || [ "$(printf '%s\n' "$OUT" | tail -n 1)" != "[끝]" ]; then
  echo "[커밋 안 함] 비밀 파일 검사가 끝까지 돌지 않았습니다"
  exit 3
fi

# 걸린 경로는 머리말([…])이 아닌 줄이다.
if printf '%s\n' "$OUT" | grep -qv '^\['; then
  echo "[커밋 안 함] 걸린 파일이 있습니다"
  exit 4
fi

git -C "$ROOT" commit -q -m "$MSG" || { echo "[커밋 안 함] git commit이 실패했습니다"; exit 5; }

if [ "$HAVE_PATHS" -eq 1 ]; then
  # 실제 인덱스에서 지정 경로를 새 HEAD에 맞춘다(미리 스테이징된 다른 파일은 그대로 둔다).
  unset GIT_INDEX_FILE
  git -C "$ROOT" reset -q -- "${PATHS[@]}" || echo "[알림] 커밋은 됐지만 스테이징 목록을 새 커밋에 맞추지 못했습니다"
fi

echo "[커밋] $(git -C "$ROOT" log -1 --format='%h %s')"
exit 0
