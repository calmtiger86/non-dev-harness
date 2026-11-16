#!/usr/bin/env bash
# non-dev-harness: 비밀 파일 검사를 통과한 내용만 커밋한다 (/co, /hs가 함께 씀).
# 커밋할 트리를 먼저 고정하고, 그 트리만 담은 임시 인덱스를 같은 폴더의 check-staged.sh로 검사한 뒤,
# 통과하면 바로 그 트리로 커밋 객체를 만든다(git commit-tree). git commit을 쓰지 않으므로
# 훅이나 다른 프로세스가 검사 뒤에 내용을 바꿔 끼울 틈이 없다. 이 스크립트 안의 모든 git 호출에서 훅을 끄고
# (빈 hooksPath), 대체 객체(git replace)도 끈다. 병합·리베이스 등이 진행 중이면 커밋하지 않는다.
#
# 사용법: bash commit-checked.sh "<하네스 루트>" "<커밋 메시지>" [--allow "<경로>"]... [-- "<경로>"...]
#   경로가 없으면 지금 스테이징된 내용 전부를 커밋한다(/co).
#   -- 뒤에 경로를 주면 HEAD에 그 경로의 작업 파일 내용만 더해 커밋한다(/hs). 경로는 하네스 루트 기준이고
#     글자 그대로 읽는다(패턴 아님). 미리 스테이징된 다른 파일은 커밋에 들어가지 않고 스테이징에 남는다.
#   --allow는 check-staged.sh에 넘긴다(사용자가 비밀이 아니라고 한 파일 하나). 줄바꿈이 든 값은 받지 않는다.
#   그 밖의 옵션은 받지 않는다. 메시지에 "Claude-Session:"으로 시작하는 줄이 있으면 거부한다.
#   하네스 루트는 첫 줄이 "<!-- non-dev-harness:"인 CLAUDE.md가 있고, 현재 폴더를 품으며, 현재 폴더와 같은
#   git 저장소여야 한다(사전 승인된 이 스크립트로 다른 저장소에 커밋하지 못하게).
# 출력: check-staged.sh의 출력 뒤에 판정 줄.
#   [커밋] <짧은 해시> <제목>      커밋함(종료 코드 0)
#   [커밋 안 함] <이유>             커밋하지 않음
# 종료 코드: 0 커밋함, 2 사용법·메시지·루트 오류, 3 검사 실패(또는 커밋할 내용을 준비하지 못함),
#            4 걸린 파일 있음, 5 커밋 실패(커밋할 변경 없음, 작성자 정보 없음, 서명 실패, 진행 중인 병합, 분리된 HEAD 등)

export LC_ALL=C
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
# 대체 객체(git replace)가 검사할 내용을 다른 내용으로 보이게 하지 못하게 한다(check-staged.sh에도 이어짐).
export GIT_NO_REPLACE_OBJECTS=1

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

# 모든 git 호출(check-staged.sh 안의 것 포함)에서 훅을 끈다. 빈 폴더를 hooksPath로 준다.
# 사용자가 환경 변수로 준 git 설정(GIT_CONFIG_COUNT)은 지우지 않고, 그 뒤에 hooksPath 한 줄을 덧붙인다(뒤에 온 값이 이김).
NOHOOKS="$(mktemp -d "${TMPDIR:-/tmp}/ndh-nohooks.XXXXXX")" || stop 3 "임시 폴더를 만들지 못했습니다"
TMP_INDEX=""
trap 'rm -rf "$NOHOOKS"; [ -z "$TMP_INDEX" ] || rm -f "$TMP_INDEX"' EXIT
N="${GIT_CONFIG_COUNT:-0}"
case "$N" in '' | *[!0-9]*) N=0 ;; esac
export "GIT_CONFIG_KEY_$N=core.hooksPath" "GIT_CONFIG_VALUE_$N=$NOHOOKS"
export GIT_CONFIG_COUNT=$((N + 1))
G() { git -C "$ROOT" "$@"; }
# 다른 설정(예: GIT_CONFIG_PARAMETERS)이 hooksPath를 다시 덮으면 훅이 돌 수 있으므로, 실제로 적용됐는지 확인한다.
[ "$(G config core.hooksPath 2> /dev/null)" = "$NOHOOKS" ] || stop 3 "git 훅을 끄지 못했습니다(환경의 git 설정이 hooksPath를 덮음)"

# 현재 폴더와 루트가 같은 git 저장소인지 확인한다(중첩된 다른 저장소, .git 바꿔치기 방지).
GD_ROOT="$(G rev-parse --absolute-git-dir 2> /dev/null)" || stop 3 "git 저장소를 읽지 못했습니다"
GD_HERE="$(git -C "$HERE" rev-parse --absolute-git-dir 2> /dev/null)" || stop 2 "현재 폴더가 git 저장소 안이 아닙니다"
GD_ROOT="$(cd -- "$GD_ROOT" && pwd -P)" && GD_HERE="$(cd -- "$GD_HERE" && pwd -P)" || stop 3 "git 저장소를 읽지 못했습니다"
[ "$GD_ROOT" = "$GD_HERE" ] || stop 2 "현재 폴더의 저장소와 하네스 루트의 저장소가 다릅니다"
# 작업 폴더의 .git이 다른 저장소를 가리키도록 바꿔치기된 경우를 거부한다.
# 보통은 .git 폴더이고, git worktree·서브모듈이 쓰는 .git 파일은 .../worktrees/… 나 .../modules/… 를 가리킨다.
TOP="$(G rev-parse --show-toplevel 2> /dev/null)" && TOP="$(cd -- "$TOP" && pwd -P)" || stop 3 "저장소 최상위 폴더를 읽지 못했습니다"
case "$ROOT/" in "$TOP"/*) ;; *) stop 2 "하네스 루트가 저장소 밖에 있습니다" ;; esac
if [ -L "$TOP/.git" ]; then
  stop 2 "저장소의 .git이 다른 곳을 가리키는 링크입니다"
elif [ -d "$TOP/.git" ]; then
  [ "$(cd -- "$TOP/.git" && pwd -P)" = "$GD_ROOT" ] || stop 2 "저장소의 .git 위치가 맞지 않습니다"
elif [ -f "$TOP/.git" ]; then
  # 가리킨 저장소 쪽 기록도 이 폴더를 작업 폴더로 가리켜야 한다(worktree는 gitdir 파일, 서브모듈은 core.worktree).
  BACK=""
  case "$GD_ROOT" in
    */worktrees/*) IFS= read -r BACK < "$GD_ROOT/gitdir" 2> /dev/null && BACK="$(cd -- "$GD_ROOT" && cd -- "$(dirname -- "$BACK")" 2> /dev/null && pwd -P)" ;;
    */modules/*) BACK="$(git config --file "$GD_ROOT/config" core.worktree 2> /dev/null)" && BACK="$(cd -- "$GD_ROOT" && cd -- "$BACK" 2> /dev/null && pwd -P)" ;;
  esac
  [ -n "$BACK" ] && [ "$BACK" = "$TOP" ] || stop 2 "저장소의 .git 파일이 다른 저장소를 가리킵니다"
else
  stop 2 "저장소의 .git을 찾지 못했습니다"
fi

# 병합·리베이스·체리픽 등이 진행 중이면 커밋하지 않는다(부모가 하나인 커밋으로 잘못 기록되므로).
for ref in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  if G rev-parse -q --verify "$ref" > /dev/null; then stop 5 "진행 중인 git 작업($ref)이 있습니다. 먼저 마무리해 주세요"; fi
done
for d in rebase-merge rebase-apply; do
  [ ! -e "$(G rev-parse --git-path "$d")" ] || stop 5 "진행 중인 리베이스가 있습니다. 먼저 마무리해 주세요"
done

# 커밋을 올릴 브랜치를 먼저 고정하고, 부모는 그 브랜치에서 읽는다(실행 중에 HEAD가 바뀌어도 이 브랜치만 다룸).
BRANCH="$(G symbolic-ref -q HEAD)" || stop 5 "브랜치가 아닌 곳(분리된 HEAD)에서는 커밋하지 않습니다. 브랜치로 돌아간 뒤 다시 해 주세요"
case "$BRANCH" in refs/heads/*) ;; *) stop 5 "브랜치가 아닌 곳에서는 커밋하지 않습니다" ;; esac
PARENT="$(G rev-parse --verify -q "$BRANCH")"
EMPTY_TREE="$(G hash-object -t tree /dev/null)" || stop 3 "저장소를 읽지 못했습니다"

# 커밋할 트리를 고정한다.
TMP_INDEX="$(mktemp "${TMPDIR:-/tmp}/ndh-index.XXXXXX")" || stop 3 "임시 파일을 만들지 못했습니다"
rm -f "$TMP_INDEX"
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
# 비교 기준은 고정한 부모(첫 커밋이면 빈 트리)다. 검사 중에 HEAD가 바뀌어도 기준은 그대로다.
BASE_REV="${PARENT:-$EMPTY_TREE}"
if [ ${#ALLOW[@]} -gt 0 ]; then
  OUT="$(GIT_INDEX_FILE="$TMP_INDEX" bash "$DIR/check-staged.sh" "$ROOT" "${ALLOW[@]}" --base "$BASE_REV")"; RC=$?
else
  OUT="$(GIT_INDEX_FILE="$TMP_INDEX" bash "$DIR/check-staged.sh" "$ROOT" --base "$BASE_REV")"; RC=$?
fi
printf '%s\n' "$OUT"
if [ "$RC" -ne 0 ] || [ "$(printf '%s\n' "$OUT" | tail -n 1)" != "[끝]" ]; then
  stop 3 "비밀 파일 검사가 끝까지 돌지 않았습니다"
fi
# 걸린 경로는 머리말([…])이 아닌 줄이다.
if printf '%s\n' "$OUT" | grep -qv '^\['; then
  stop 4 "걸린 파일이 있습니다"
fi
# 검사한 임시 인덱스가 고정한 트리 그대로인지 다시 확인한다.
[ "$(GIT_INDEX_FILE="$TMP_INDEX" G write-tree)" = "$TREE" ] || stop 3 "검사하는 동안 커밋할 내용이 바뀌었습니다"

# 검사한 바로 그 트리로 커밋한다.
# 저장소가 서명을 요구하면(commit.gpgSign) 서명하고, 서명에 실패하면 커밋하지 않는다.
SIGN=""
[ "$(G config --bool commit.gpgSign 2> /dev/null)" != "true" ] || SIGN="-S"
SUBJECT="$(printf '%s\n' "$MSG" | head -n 1)"
if [ -n "$PARENT" ]; then
  [ "$TREE" != "$(G rev-parse "$PARENT^{tree}")" ] || stop 5 "커밋할 변경이 없습니다"
  NEW="$(G commit-tree $SIGN "$TREE" -p "$PARENT" -m "$MSG")" || stop 5 "커밋을 만들지 못했습니다(작성자 정보, 서명 등)"
else
  NEW="$(G commit-tree $SIGN "$TREE" -m "$MSG")" || stop 5 "커밋을 만들지 못했습니다(작성자 정보, 서명 등)"
fi
# 고정한 브랜치만, 그 브랜치가 아직 고정한 부모를 가리킬 때만 갱신한다(링크로 바뀐 브랜치는 따라가지 않음).
G update-ref --no-deref -m "commit (non-dev-harness): $SUBJECT" "$BRANCH" "$NEW" "$PARENT" || stop 5 "기록을 갱신하지 못했습니다(그 사이 브랜치가 바뀜)"

# 실제 스테이징 목록을 새 커밋에 맞춘다. 경로 커밋이면 그 경로만 맞추고 미리 스테이징된 다른 파일은 그대로 둔다.
if [ "$HAVE_PATHS" -eq 1 ]; then
  GIT_LITERAL_PATHSPECS=1 G reset -q -- "${PATHS[@]}" || echo "[알림] 커밋은 됐지만 스테이징 목록을 새 커밋에 맞추지 못했습니다"
fi

echo "[커밋] $(G log -1 --format='%h %s' "$NEW")"
exit 0
