#!/usr/bin/env bash
# non-dev-harness: 비밀 파일 검사를 통과한 내용만 커밋한다 (/co, /hs가 함께 씀).
# 커밋할 트리를 먼저 고정하고, 그 트리만 담은 임시 인덱스를 같은 폴더의 check-staged.sh로 검사한 뒤,
# 통과하면 바로 그 트리로 커밋 객체를 만든다(git commit-tree). git commit을 쓰지 않으므로
# 훅이나 다른 프로세스가 검사 뒤에 내용을 바꿔 끼울 틈이 없다. 이 스크립트 안의 모든 git 호출에서 훅을 끄고
# (빈 hooksPath), 대체 객체(git replace)도 끈다. 병합·리베이스 등이 진행 중이면 커밋하지 않는다.
#
# 사용법: bash commit-checked.sh "<하네스 루트>" "<커밋 메시지>" [--trailer "<꼬리말>"]... [--allow "<경로>"]... [-- "<경로>"...]
#   경로가 없으면 지금 스테이징된 내용 전부를 커밋한다(/co).
#   -- 뒤에 경로를 주면 HEAD에 그 경로의 작업 파일 내용만 더해 커밋한다(/hs). 경로는 하네스 루트 기준이고
#     글자 그대로 읽는다(패턴 아님). 미리 스테이징된 다른 파일은 커밋에 들어가지 않고 스테이징에 남는다.
#   --trailer는 "이름: 값" 모양의 한 줄(예: Co-Authored-By)이고, 빈 줄 뒤에 준 순서대로 메시지 끝에 붙인다.
#     메시지 인자를 한 줄로 두면 명령 전체가 한 줄이 되어 사전 승인 규칙과 맞는다(줄바꿈이 든 인자는 확인 창이 뜸).
#   --allow는 check-staged.sh에 넘긴다(사용자가 비밀이 아니라고 한 파일 하나). 줄바꿈이 든 값은 받지 않는다.
#     이 파일을 직접 실행하면 --allow를 받지 않는다(사전 승인된 실행이 인자 하나로 검사를 끄지 못하게).
#     예외는 사전 승인하지 않은 commit-allowed.sh(이 파일을 불러 씀)로만 받으므로 그 실행에는 확인 창이 뜨고
#     창에 예외 경로가 그대로 보인다.
#   그 밖의 옵션은 받지 않는다. 메시지에 "Claude-Session:"으로 시작하는 줄이 있으면(대소문자 무시) 거부하고,
#   메시지와 꼬리말에 CR 문자가 있어도 거부한다.
#   하네스 루트는 첫 줄이 "<!-- non-dev-harness:"인 CLAUDE.md가 있고, 현재 폴더를 품으며, 현재 폴더와 같은
#   git 저장소여야 한다(사전 승인된 이 스크립트로 다른 저장소에 커밋하지 못하게).
# 출력: check-staged.sh의 출력 뒤에 판정 줄.
#   [커밋] <짧은 해시> <제목>      커밋함(종료 코드 0)
#   [커밋 안 함] <이유>             커밋하지 않음
# 종료 코드: 0 커밋함, 2 사용법·메시지·루트 오류, 3 검사 실패(또는 커밋할 내용을 준비하지 못함),
#            4 걸린 파일 있음, 5 커밋 실패(커밋할 변경 없음, 작성자 정보 없음, 서명 실패, 진행 중인 병합, 분리된 HEAD 등)
#
# 지키는 것(이 스크립트는 확인 창 없이 사전 승인되어 실행된다):
#   1. 검사한 트리만 커밋한다.  2. 시작할 때 고정한 저장소의 고정한 브랜치에만 커밋한다.
# 믿지 않는 것(막는 대상): 인자, 현재 폴더, 작업 폴더의 파일(.gitattributes 포함), 저장소의 정적 상태(.git 모양,
#   commondir, refs·objects 링크, 훅, 대체 객체, 진행 중인 병합), 환경 변수로 들어온 git 설정(GIT_CONFIG_PARAMETERS,
#   GIT_CONFIG_COUNT, GIT_TEST_FSMONITOR).
# 저장소 설정(.git/config)은 두 약속을 깨지 못하게만 한다(훅·fsmonitor 끔, 바이너리 취급 무시). 설정에 적힌 명령
#   (filter, gpg.program 등)의 실행은 막지 못한다. Claude Code가 세션을 시작할 때 돌리는 git status도 같은 명령을
#   실행하므로, 여기서 거부해도 노출은 줄지 않고 정상 저장소(로컬 LFS 등)만 쓸 수 없게 되기 때문이다.
# 믿는 것(막는 대상이 아님): PATH와 그 안의 git, 사용자 전역·시스템 git 설정(GIT_CONFIG_GLOBAL·GIT_CONFIG_SYSTEM로
#   바꾼 위치 포함), 실행 중에 저장소를 바꾸는 다른 프로세스. 마지막 것은 경쟁 조건을 줄이는 확인(옛 값 비교,
#   검사 뒤 트리 재확인)만 두고 완전히 막지는 않는다.

export LC_ALL=C
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_TEST_FSMONITOR
# 이 파일을 직접 실행했는지(사전 승인된 실행), commit-allowed.sh가 불러 썼는지 구분한다.
SOURCED=0
[ "${BASH_SOURCE[0]}" = "$0" ] || SOURCED=1
# 대체 객체(git replace)가 검사할 내용을 다른 내용으로 보이게 하지 못하게 한다(check-staged.sh에도 이어짐).
export GIT_NO_REPLACE_OBJECTS=1

usage() {
  echo "사용법: bash commit-checked.sh \"<하네스 루트>\" \"<커밋 메시지>\" [--trailer \"<꼬리말>\"]... [--allow \"<경로>\"]... [-- \"<경로>\"...]" >&2
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

ALLOW=()
TRAILERS=()
PATHS=()
HAVE_PATHS=0
NL='
'
CR="$(printf '\r')"
while [ $# -gt 0 ]; do
  case "$1" in
    --trailer)
      [ $# -ge 2 ] || usage
      case "$2" in *"$NL"*) usage ;; [A-Za-z]*": "?*) ;; *) usage ;; esac
      TRAILERS+=("$2")
      shift 2
      ;;
    --allow)
      if [ "$SOURCED" -ne 1 ]; then
        echo "예외(--allow)는 이 스크립트로 받지 않습니다. 같은 폴더의 commit-allowed.sh로 실행하세요(확인 창이 뜹니다)" >&2
        exit 2
      fi
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
[ ${#TRAILERS[@]} -eq 0 ] || MSG="$MSG$NL$NL$(printf '%s\n' "${TRAILERS[@]}")"

# CR 문자(꼬리말에 든 것 포함)는 줄 시작 검사를 피하는 데 쓰일 수 있으므로 받지 않는다.
case "$MSG" in *"$CR"*) usage ;; esac
if printf '%s\n' "$MSG" | grep -qi '^claude-session:'; then
  echo "메시지 오류: Claude-Session 줄을 빼고 다시 실행하세요" >&2
  exit 2
fi

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

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || stop 3 "스크립트 폴더를 찾지 못했습니다"

# 환경 변수로 들어온 git 설정(GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT)은 명령을 실행하는 설정(core.fsmonitor 등)도
# 담을 수 있으므로 지운다. 작성자와 서명 설정만 골라 다시 넣는다.
KEEP_KEYS=()
KEEP_VALS=()
while IFS= read -r -d '' SCOPE && IFS= read -r -d '' KV; do
  [ "$SCOPE" = command ] || continue
  case "$KV" in *"$NL"*) KEEP_KEYS+=("${KV%%"$NL"*}"); KEEP_VALS+=("${KV#*"$NL"}") ;; *) KEEP_KEYS+=("$KV"); KEEP_VALS+=(true) ;; esac
done < <(git config --show-scope -z --get-regexp '^(user\.(name|email|signingkey)|commit\.gpgsign|gpg\.format)$' 2> /dev/null)
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
for V in $(compgen -e); do
  case "$V" in GIT_CONFIG_KEY_* | GIT_CONFIG_VALUE_*) unset "$V" ;; esac
done
# 모든 git 호출(check-staged.sh 안의 것 포함)에서 훅을 끈다. 빈 폴더를 hooksPath로 준다.
NOHOOKS="$(mktemp -d "${TMPDIR:-/tmp}/ndh-nohooks.XXXXXX")" || stop 3 "임시 폴더를 만들지 못했습니다"
TMP_INDEX=""
trap 'rm -rf "$NOHOOKS"; [ -z "$TMP_INDEX" ] || rm -f "$TMP_INDEX"' EXIT
N=0
while [ "$N" -lt ${#KEEP_KEYS[@]} ]; do
  export "GIT_CONFIG_KEY_$N=${KEEP_KEYS[$N]}" "GIT_CONFIG_VALUE_$N=${KEEP_VALS[$N]}"
  N=$((N + 1))
done
export "GIT_CONFIG_KEY_$N=core.hooksPath" "GIT_CONFIG_VALUE_$N=$NOHOOKS"
N=$((N + 1))
# 저장소 설정의 fsmonitor 명령도 이 스크립트(와 check-staged.sh)의 git 호출에서는 돌지 않게 한다.
export "GIT_CONFIG_KEY_$N=core.fsmonitor" "GIT_CONFIG_VALUE_$N=false"
export GIT_CONFIG_COUNT=$((N + 1))
G() { git --no-pager -C "$ROOT" "$@"; }
# GIT_CONFIG_COUNT를 모르는 오래된 git(2.31 미만)에서는 위 설정이 무시되어 훅이 돌 수 있으므로, 실제로 적용됐는지 확인한다.
[ "$(G config core.hooksPath 2> /dev/null)" = "$NOHOOKS" ] || stop 3 "git 훅을 끄지 못했습니다(git이 오래되었을 수 있습니다)"

# 현재 폴더와 루트가 같은 git 저장소인지 확인한다(중첩된 다른 저장소, .git 바꿔치기 방지).
GD_ROOT="$(G rev-parse --absolute-git-dir 2> /dev/null)" || stop 3 "git 저장소를 읽지 못했습니다"
GD_HERE="$(git -C "$HERE" rev-parse --absolute-git-dir 2> /dev/null)" || stop 2 "현재 폴더가 git 저장소 안이 아닙니다"
GD_ROOT="$(cd -- "$GD_ROOT" && pwd -P)" && GD_HERE="$(cd -- "$GD_HERE" && pwd -P)" || stop 3 "git 저장소를 읽지 못했습니다"
[ "$GD_ROOT" = "$GD_HERE" ] || stop 2 "현재 폴더의 저장소와 하네스 루트의 저장소가 다릅니다"
# 작업 폴더의 .git이 다른 저장소를 가리키도록 바꿔치기된 경우를 거부한다. 기준은 git이 실제로 쓰는 공용 폴더(COMMON)다.
# 보통은 .git 폴더이고 COMMON도 그 폴더다. git worktree와 서브모듈은 .git 파일을 쓰는데, 이때 가리킨 곳과 COMMON은
# 작업 폴더 밖에 있어야 하고(작업 폴더 안의 파일로 commondir를 꾸미지 못하게), 그쪽 기록도 이 폴더를 가리켜야 한다.
TOP="$(G rev-parse --show-toplevel 2> /dev/null)" && TOP="$(cd -- "$TOP" && pwd -P)" || stop 3 "저장소 최상위 폴더를 읽지 못했습니다"
COMMON="$(G rev-parse --git-common-dir 2> /dev/null)" && COMMON="$(cd -- "$ROOT" && cd -- "$COMMON" && pwd -P)" || stop 3 "저장소를 읽지 못했습니다"
case "$ROOT/" in "$TOP"/*) ;; *) stop 2 "하네스 루트가 저장소 밖에 있습니다" ;; esac
if [ -L "$TOP/.git" ]; then
  stop 2 "저장소의 .git이 다른 곳을 가리키는 링크입니다"
elif [ -d "$TOP/.git" ]; then
  [ "$(cd -- "$TOP/.git" && pwd -P)" = "$GD_ROOT" ] && [ "$COMMON" = "$GD_ROOT" ] || stop 2 "저장소의 .git 위치가 맞지 않습니다"
elif [ -f "$TOP/.git" ]; then
  case "$GD_ROOT/" in "$TOP"/*) stop 2 "저장소의 .git 파일이 작업 폴더 안을 가리킵니다" ;; esac
  case "$COMMON/" in "$TOP"/*) stop 2 "저장소의 .git 파일이 작업 폴더 안을 가리킵니다" ;; esac
  BACK=""
  if [ "$(dirname -- "$GD_ROOT")" = "$COMMON/worktrees" ]; then
    # git worktree: 공용 폴더의 worktrees/<이름>이고, 그 안의 gitdir 파일이 이 폴더의 .git을 가리킨다.
    IFS= read -r BACK < "$GD_ROOT/gitdir" 2> /dev/null && BACK="$(cd -- "$GD_ROOT" && cd -- "$(dirname -- "$BACK")" 2> /dev/null && pwd -P)"
  elif [ "$COMMON" = "$GD_ROOT" ]; then
    # 서브모듈: 자기 저장소 폴더의 core.worktree가 이 폴더를 가리킨다.
    BACK="$(git config --file "$GD_ROOT/config" core.worktree 2> /dev/null)" && BACK="$(cd -- "$GD_ROOT" && cd -- "$BACK" 2> /dev/null && pwd -P)"
  fi
  [ -n "$BACK" ] && [ "$BACK" = "$TOP" ] || stop 2 "저장소의 .git 파일이 다른 저장소를 가리킵니다"
else
  stop 2 "저장소의 .git을 찾지 못했습니다"
fi
# 진짜 .git 폴더 안의 기록 폴더(refs, objects 등)가 다른 저장소로 가는 링크여도 커밋이 그쪽에 써지므로 거부한다.
for P in "$COMMON/refs" "$COMMON/objects" "$COMMON/packed-refs" "$GD_ROOT/HEAD"; do
  [ ! -L "$P" ] || stop 2 "저장소 안의 기록 폴더가 다른 곳을 가리키는 링크입니다"
done
[ -z "$(find "$COMMON/refs" -type l -print 2> /dev/null | head -n 1)" ] || stop 2 "저장소 안의 기록 폴더에 링크가 있습니다"

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
