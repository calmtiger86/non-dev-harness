#!/usr/bin/env bash
# non-dev-harness: 비밀 파일 검사를 통과했을 때만 커밋한다 (/co, /hs가 함께 씀).
# 같은 폴더의 check-staged.sh를 돌려 그 출력을 그대로 보여 주고, 결과를 스스로 판정한 뒤 커밋한다.
# 검사와 커밋을 한 실행으로 묶어, 검사를 건너뛰거나 검사하지 않은 내용을 커밋하는 길을 막는다.
#
# 사용법: bash commit-checked.sh "<하네스 루트>" "<커밋 메시지>" [--allow "<경로>"]... [-- "<경로>"...]
#   -- 뒤에 경로를 주면 그 경로만 커밋한다(/hs). 경로는 하네스 루트 기준이다. 없으면 스테이징된 전부를 커밋한다(/co).
#   --allow는 check-staged.sh에 그대로 넘긴다(사용자가 비밀이 아니라고 한 파일).
#   그 밖의 옵션은 받지 않는다. 메시지에 "Claude-Session:"으로 시작하는 줄이 있으면 거부한다.
# 출력: check-staged.sh의 출력 뒤에 판정 줄.
#   [커밋] <짧은 해시> <제목>                     커밋함(종료 코드 0)
#   [알림] 커밋하지 않는 경로에서 걸림: <경로>     -- 경로를 줬을 때, 커밋에 들어가지 않는 미리 스테이징된 파일
#   [커밋 안 함] <이유>                            커밋하지 않음
# 종료 코드: 0 커밋함, 2 사용법·메시지 오류, 3 검사 실패 또는 검사한 뒤 파일이 바뀜, 4 걸린 파일 있음, 5 git commit 실패

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

# 걸린 경로는 머리말([…])이 아닌 줄이고 모두 ":(top)"으로 시작한다.
FLAGGED="$(printf '%s\n' "$OUT" | grep -v '^\[' | sed 's/^:(top)//')"

if [ "$HAVE_PATHS" -eq 0 ]; then
  if [ -n "$FLAGGED" ]; then
    echo "[커밋 안 함] 걸린 파일이 있습니다"
    exit 4
  fi
  git -C "$ROOT" commit -q -m "$MSG" || { echo "[커밋 안 함] git commit이 실패했습니다"; exit 5; }
else
  PREFIX="$(git -C "$ROOT" rev-parse --show-prefix)" || { echo "[커밋 안 함] 저장소 위치를 읽지 못했습니다"; exit 3; }
  INSIDE=0
  if [ -n "$FLAGGED" ]; then
    while IFS= read -r f; do
      hit=0
      for p in "${PATHS[@]}"; do
        t="$PREFIX${p#./}"
        t="${t%/}"
        case "$f" in
          "$t" | "$t"/*) hit=1 ;;
        esac
      done
      if [ "$hit" -eq 1 ]; then
        INSIDE=1
      else
        echo "[알림] 커밋하지 않는 경로에서 걸림: $f"
      fi
    done <<EOF
$FLAGGED
EOF
  fi
  if [ "$INSIDE" -eq 1 ]; then
    echo "[커밋 안 함] 걸린 파일이 있습니다"
    exit 4
  fi
  # 경로를 지정한 커밋은 작업 파일의 내용을 담으므로, 검사한 스테이징 내용과 같을 때만 커밋한다.
  git -C "$ROOT" diff --quiet --no-ext-diff -- "${PATHS[@]}"
  case $? in
    0) ;;
    1) echo "[커밋 안 함] 검사한 뒤 바뀐 파일이 있습니다. 다시 스테이징한 뒤 실행하세요"; exit 3 ;;
    *) echo "[커밋 안 함] 바뀐 파일을 확인하지 못했습니다"; exit 3 ;;
  esac
  git -C "$ROOT" commit -q -m "$MSG" -- "${PATHS[@]}" || { echo "[커밋 안 함] git commit이 실패했습니다"; exit 5; }
fi

echo "[커밋] $(git -C "$ROOT" log -1 --format='%h %s')"
exit 0
