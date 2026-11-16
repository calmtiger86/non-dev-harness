#!/usr/bin/env bash
# non-dev-harness: 비밀 파일 검사를 통과한 내용만 커밋한다 (/co, /hs가 함께 씀).
# 커밋할 트리를 먼저 고정하고, 그 트리만 담은 임시 인덱스를 같은 폴더의 check-staged.sh로 검사한 뒤,
# 통과하면 바로 그 트리로 커밋 객체를 만든다(git commit-tree). git commit을 쓰지 않으므로
# 훅이나 다른 프로세스가 검사 뒤에 내용을 바꿔 끼울 틈이 없다. 대신 git 훅(pre-commit 등)은 실행되지 않는다.
#
# 사용법: bash commit-checked.sh "<하네스 루트>" "<커밋 메시지>" [--allow "<경로>"]... [-- "<경로>"...]
#   경로가 없으면 지금 스테이징된 내용 전부를 커밋한다(/co).
#   -- 뒤에 경로를 주면 HEAD에 그 경로의 작업 파일 내용만 더해 커밋한다(/hs). 경로는 하네스 루트 기준이고
#     글자 그대로 읽는다(패턴 아님). 미리 스테이징된 다른 파일은 커밋에 들어가지 않고 스테이징에 남는다.
#   --allow는 check-staged.sh에 넘긴다(사용자가 비밀이 아니라고 한 파일 하나). 줄바꿈이 든 값은 받지 않는다.
#   그 밖의 옵션은 받지 않는다. 메시지에 "Claude-Session:"으로 시작하는 줄이 있으면 거부한다.
#   하네스 루트는 첫 줄이 "<!-- non-dev-harness:"인 CLAUDE.md가 있고, 현재 폴더를 품는 폴더여야 한다
#   (사전 승인된 이 스크립트로 다른 저장소에 커밋하지 못하게).
# 출력: check-staged.sh의 출력 뒤에 판정 줄.
#   [커밋] <짧은 해시> <제목>      커밋함(종료 코드 0)
#   [커밋 안 함] <이유>             커밋하지 않음
# 종료 코드: 0 커밋함, 2 사용법·메시지·루트 오류, 3 검사 실패(또는 커밋할 내용을 준비하지 못함),
#            4 걸린 파일 있음, 5 커밋 실패(커밋할 변경 없음, 작성자 정보 없음 등)

export LC_ALL=C
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

usage() {
  echo "사용법: bash commit-checked.sh \"<하네스 루트>\" \"<커밋 메시지>\" [--allow \"<경로>\"]... [-- \"<경로>\"...]" >&2
  exit 2
}
stop() {
  echo "[커밋 안 함] $2"
  exit "$1"
}

[ $# -ge 2 ] || usage
ROOT_ARG="$1"
MSG="$2"
shift 2
[ -n "$ROOT_ARG" ] && [ -n "$MSG" ] || usage

if printf '%s\n' "$MSG" | grep -q '^Claude-Session:'; then
  echo "메시지 오류: Claude-Session 줄을 빼고 다시 실행하세요" >&2
  exit 2
fi

ALLOW=()
PATHS=()
HAVE_PATHS=0
NL='
'
while [ $# -gt 0 ]; do
  case "$1" in
    --allow)
      [ $# -ge 2 ] || usage
      case "$2" in *"$NL"*) usage ;; esac
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

# 루트를 절대경로 하나로 확정한다. 검사와 커밋이 같은 저장소를 보게 한다.
ROOT="$(cd -- "$ROOT_ARG" 2> /dev/null && pwd -P)" || stop 2 "하네스 루트를 찾지 못했습니다: $ROOT_ARG"
HERE="$(pwd -P)"
case "$HERE/" in
  "$ROOT"/*) ;;
  *) stop 2 "현재 폴더가 하네스 루트 안이 아닙니다(현재 폴더: $HERE)" ;;
esac
FIRST=""
[ -f "$ROOT/CLAUDE.md" ] && IFS= read -r FIRST < "$ROOT/CLAUDE.md"
BOM="$(printf '\357\273\277')"
FIRST="${FIRST#"$BOM"}"
case "$FIRST" in
  "<!-- non-dev-harness:"*) ;;
  *) stop 2 "하네스 루트가 아닙니다(CLAUDE.md 첫 줄의 non-dev-harness 표식이 없음)" ;;
esac

DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)" || stop 3 "스크립트 폴더를 찾지 못했습니다"
G() { git -C "$ROOT" "$@"; }

PARENT="$(G rev-parse --verify -q HEAD)"

# 커밋할 트리를 고정한다.
TMP_INDEX="$(mktemp "${TMPDIR:-/tmp}/ndh-index.XXXXXX")" || stop 3 "임시 파일을 만들지 못했습니다"
rm -f "$TMP_INDEX"
trap 'rm -f "$TMP_INDEX"' EXIT
if [ "$HAVE_PATHS" -eq 1 ]; then
  if [ -n "$PARENT" ]; then
    GIT_INDEX_FILE="$TMP_INDEX" G read-tree "$PARENT" || stop 3 "커밋할 내용을 준비하지 못했습니다"
  else
    GIT_INDEX_FILE="$TMP_INDEX" G read-tree --empty || stop 3 "커밋할 내용을 준비하지 못했습니다"
  fi
  GIT_LITERAL_PATHSPECS=1 GIT_INDEX_FILE="$TMP_INDEX" G add -A -- "${PATHS[@]}" || stop 3 "지정한 경로를 담지 못했습니다"
  TREE="$(GIT_INDEX_FILE="$TMP_INDEX" G write-tree)" || stop 3 "커밋할 내용을 준비하지 못했습니다"
else
  TREE="$(G write-tree)" || stop 3 "스테이징된 내용을 읽지 못했습니다"
  GIT_INDEX_FILE="$TMP_INDEX" G read-tree "$TREE" || stop 3 "커밋할 내용을 준비하지 못했습니다"
fi

# 고정한 트리(임시 인덱스)를 검사한다.
if [ ${#ALLOW[@]} -gt 0 ]; then
  OUT="$(GIT_INDEX_FILE="$TMP_INDEX" bash "$DIR/check-staged.sh" "$ROOT" "${ALLOW[@]}")"; RC=$?
else
  OUT="$(GIT_INDEX_FILE="$TMP_INDEX" bash "$DIR/check-staged.sh" "$ROOT")"; RC=$?
fi
printf '%s\n' "$OUT"
if [ "$RC" -ne 0 ] || [ "$(printf '%s\n' "$OUT" | tail -n 1)" != "[끝]" ]; then
  stop 3 "비밀 파일 검사가 끝까지 돌지 않았습니다"
fi
# 걸린 경로는 머리말([…])이 아닌 줄이다.
if printf '%s\n' "$OUT" | grep -qv '^\['; then
  stop 4 "걸린 파일이 있습니다"
fi

# 검사한 바로 그 트리로 커밋한다.
if [ -n "$PARENT" ]; then
  [ "$TREE" != "$(G rev-parse "$PARENT^{tree}")" ] || stop 5 "커밋할 변경이 없습니다"
  NEW="$(G commit-tree "$TREE" -p "$PARENT" -m "$MSG")" || stop 5 "커밋을 만들지 못했습니다(작성자 정보 등)"
  G update-ref -m "commit (non-dev-harness): $(printf '%s\n' "$MSG" | head -n 1)" HEAD "$NEW" "$PARENT" || stop 5 "기록을 갱신하지 못했습니다"
else
  NEW="$(G commit-tree "$TREE" -m "$MSG")" || stop 5 "커밋을 만들지 못했습니다(작성자 정보 등)"
  G update-ref -m "commit (initial, non-dev-harness): $(printf '%s\n' "$MSG" | head -n 1)" HEAD "$NEW" "" || stop 5 "기록을 갱신하지 못했습니다"
fi

# 실제 스테이징 목록을 새 커밋에 맞춘다. 경로 커밋이면 그 경로만 맞추고 미리 스테이징된 다른 파일은 그대로 둔다.
if [ "$HAVE_PATHS" -eq 1 ]; then
  GIT_LITERAL_PATHSPECS=1 G reset -q -- "${PATHS[@]}" || echo "[알림] 커밋은 됐지만 스테이징 목록을 새 커밋에 맞추지 못했습니다"
fi

echo "[커밋] $(G log -1 --format='%h %s' "$NEW")"
exit 0
