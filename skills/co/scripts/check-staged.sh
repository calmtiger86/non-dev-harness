#!/usr/bin/env bash
# non-dev-harness 커밋 전 검사 (/co, /hs가 함께 씀).
# 스테이징된 모든 파일(커밋에 들어갈 전부)을 비밀 파일 이름, 비밀 키 내용, 50MB 넘는 크기로 검사한다.
# 루트 인자는 git 명령을 실행할 폴더다. 루트 밖에서 미리 스테이징된 파일도 커밋에 들어가므로 함께 검사한다.
# 삭제되는 파일은 검사하지 않고, 내용은 새로 추가된 줄만 본다.
# 비밀 패턴에 걸린 토큰 자체에 YOUR, xxxx, XXXX, EXAMPLE, your_가 들어 있으면 자리표시자로 보고 뺀다.
# 같은 줄의 다른 곳에 있는 낱말은 빼는 근거가 되지 않는다.
# git이 바이너리로 보는 파일(UTF-16 텍스트, Office 문서 등)은 내용 검사를 하지 못한다.
#
# 출력: [이름] [내용] [크기] 머리말 아래에 걸린 파일을 ":(top)경로" 모양으로 적는다(git 명령에 그대로 쓸 수 있음).
#       비밀 값 자체는 출력하지 않는다. 모든 단계가 성공했을 때만 마지막 줄에 [끝]을 찍는다.
# 종료 코드: 0 검사 완료(걸린 파일이 있어도 0), 2 사용법 오류, 3 검사 실패([끝] 없음).
# 사용법: bash check-staged.sh "<하네스 루트>" [--allow "<경로>"]...
#         --allow로 준 경로(":(top)" 접두어는 있어도 없어도 됨)는 세 검사 모두에서 뺀다.

export LC_ALL=C

usage() {
  echo "사용법: bash check-staged.sh \"<하네스 루트>\" [--allow \"<경로>\"]..." >&2
  exit 2
}

fail() {
  echo "검사 실패: $1" >&2
  exit 3
}

ROOT="$1"
[ -n "$ROOT" ] || usage
shift
cd "$ROOT" 2>/dev/null || usage

TMP="$(mktemp -d 2>/dev/null)" || fail "임시 폴더를 만들지 못했습니다"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/allow" || fail "임시 파일을 만들지 못했습니다"

while [ $# -gt 0 ]; do
  case "$1" in
    --allow)
      [ $# -ge 2 ] || usage
      printf '%s\n' "${2#:(top)}" >> "$TMP/allow" || fail "임시 파일을 쓰지 못했습니다"
      shift 2
      ;;
    *) usage ;;
  esac
done

# 사용자 git 설정(색, 외부 diff 도구, 접두어 생략, 경로 따옴표)이 출력 모양을 바꾸지 못하게 고정한다.
G() {
  git -c core.quotePath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false "$@"
}

NAME_RE='(^|/)(\.env(\.[^/]*)?|\.envrc|\.npmrc|\.netrc|[^/]*\.(pem|p12|pfx|keystore|ppk)|id_(rsa|dsa|ed25519|ecdsa)[^/]*|[^/]*credentials[^/]*\.json|client_secret[^/]*\.json|[^/]*service-account[^/]*\.json|token\.json|secrets\.[^/]*)$'
LIMIT_BYTES=52428800

# 0이면 찾음, 1이면 못 찾음. 그 밖은 grep 자체의 실패다.
grep_ok() {
  [ "$1" -le 1 ]
}

G rev-parse --git-dir > /dev/null 2>&1 || fail "git 저장소가 아닙니다"

# 스테이징 목록: ":<옛 모드> <새 모드> <옛 id> <새 id> <상태><TAB><경로>"
G diff --cached --raw --no-abbrev --no-renames --diff-filter=d > "$TMP/raw" || fail "스테이징 목록을 읽지 못했습니다"
awk -F'\t' '{ print $2 }' "$TMP/raw" > "$TMP/names" || fail "스테이징 목록을 나누지 못했습니다"

# [이름]
grep -iE "$NAME_RE" "$TMP/names" > "$TMP/name1"; grep_ok $? || fail "이름 검사"
grep -viE '(^|/)\.env\.example$' "$TMP/name1" > "$TMP/name_hits"; grep_ok $? || fail "이름 검사"

# [내용]: 파일 머리말은 "F경로", 추가된 줄은 " 내용"으로 바꿔 한 파일에 담는다.
# "+++ " 줄은 "diff --git" 바로 뒤 머리말 구간에서만 파일 이름으로 읽는다(추가된 줄이 "++ "로 시작해도 헷갈리지 않게).
G diff --cached -U0 --no-color --no-ext-diff --no-textconv --no-renames --diff-filter=d > "$TMP/diff" || fail "변경 내용을 읽지 못했습니다"
awk '
  /^diff --git / { hdr = 1; next }
  hdr && /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); sub(/\t$/, "", f); print "F" f; next }
  /^@@/ { hdr = 0; next }
  hdr { next }
  /^\+/ { print " " substr($0, 2) }
' "$TMP/diff" > "$TMP/added" || fail "변경 내용을 나누지 못했습니다"
# 걸린 토큰만 "줄 번호:토큰" 모양으로 꺼낸다(-n -o). 줄 번호로 어느 파일의 추가된 줄인지 찾는다.
# 머리말 줄("F경로")에서 걸린 것은 경로 글자일 뿐이므로 뺀다.
grep -a -n -o -E \
  -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
  -e '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}' \
  -e 'AKIA[0-9A-Z]{16}' \
  -e 'gh[oprsu]_[A-Za-z0-9]{36}' \
  -e 'github_pat_[A-Za-z0-9_]{20,}' \
  -e 'glpat-[A-Za-z0-9_-]{20,}' \
  -e '[sr]k_live_[A-Za-z0-9]{20,}' \
  -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
  -e 'AIza[0-9A-Za-z_-]{35}' \
  "$TMP/added" > "$TMP/hits"; grep_ok $? || fail "내용 검사"
awk -v A="$TMP/added" '
  BEGIN {
    n = 0
    while ((r = (getline l < A)) > 0) {
      n++
      if (substr(l, 1, 1) == "F") f = substr(l, 2)
      else file[n] = f
    }
    if (r < 0) exit 3
  }
  {
    i = index($0, ":")
    ln = substr($0, 1, i - 1) + 0
    tok = substr($0, i + 1)
    if (!(ln in file)) next
    if (index(tok, "YOUR") || index(tok, "xxxx") || index(tok, "XXXX") || index(tok, "EXAMPLE") || index(tok, "your_")) next
    print file[ln]
  }
' "$TMP/hits" > "$TMP/content1" || fail "내용 검사 결과 정리"
sort -u "$TMP/content1" > "$TMP/content_hits" || fail "내용 검사 결과 정리"

# [크기]: 하위 저장소(모드 160000)는 크기를 볼 수 없으므로 뺀다.
awk -F'\t' '{ split($1, m, " "); if (m[2] != "160000") print m[4] "\t" $2 }' "$TMP/raw" > "$TMP/blobs" || fail "크기 검사 준비"
cut -f1 "$TMP/blobs" > "$TMP/ids" || fail "크기 검사 준비"
git cat-file --batch-check='%(objectsize)' < "$TMP/ids" > "$TMP/sizes" || fail "파일 크기를 읽지 못했습니다"
paste "$TMP/sizes" "$TMP/blobs" > "$TMP/sized" || fail "크기 검사 준비"
awk -F'\t' -v lim="$LIMIT_BYTES" '
  $1 !~ /^[0-9]+$/ { bad = 1; next }
  $1 + 0 > lim { print $3 }
  END { exit bad }
' "$TMP/sized" > "$TMP/size_hits" || fail "파일 크기를 읽지 못했습니다"

# 예외 경로를 빼고 ":(top)" 접두어를 붙인다. 모두 계산한 뒤에 출력해, 중간에 실패하면 머리말이 하나도 나오지 않는다.
for part in name_hits content_hits size_hits; do
  awk -v A="$TMP/allow" '
    BEGIN { while ((getline l < A) > 0) skip[l] = 1 }
    !($0 in skip) { print ":(top)" $0 }
  ' "$TMP/$part" > "$TMP/$part.out" || fail "결과 정리"
done

echo "[이름]"; cat "$TMP/name_hits.out"
echo "[내용]"; cat "$TMP/content_hits.out"
echo "[크기]"; cat "$TMP/size_hits.out"
echo "[끝]"
exit 0
