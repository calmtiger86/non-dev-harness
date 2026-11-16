#!/usr/bin/env bash
# non-dev-harness 커밋 전 검사 (/co, /hs가 함께 씀).
# 스테이징된 모든 파일(커밋에 들어갈 전부)을 비밀 파일 이름, 비밀 키 내용, 50MB 넘는 크기로 검사한다.
# 루트 인자는 git 명령을 실행할 폴더다. 루트 밖에서 미리 스테이징된 파일도 커밋에 들어가므로 함께 검사한다.
# 삭제되는 파일은 검사하지 않고, 내용은 새로 추가된 줄만 본다.
# 비밀 패턴에 걸린 토큰 자체에 YOUR, xxxx, XXXX, EXAMPLE, your_가 들어 있으면 자리표시자로 보고 뺀다.
# 같은 줄의 다른 곳에 있는 낱말은 빼는 근거가 되지 않는다.
# git이 바이너리로 보는 파일(UTF-16 텍스트, Office 문서 등)은 내용 검사를 하지 못한다.
# 이름에 줄바꿈이 든 파일이 스테이징되어 있으면 경로를 줄 단위로 정확히 다룰 수 없으므로 검사 실패로 멈춘다.
#
# 출력: [이름] [내용] [크기] 머리말 아래에 걸린 파일을 ":(top)경로" 모양으로 적는다(git 명령에 그대로 쓸 수 있음).
#       비밀 값 자체는 출력하지 않는다. 모든 단계가 성공했을 때만 마지막 줄에 [끝]을 찍는다.
# 종료 코드: 0 검사 완료(걸린 파일이 있어도 0), 2 사용법 오류, 3 검사 실패([끝] 없음).
# 사용법: bash check-staged.sh "<하네스 루트>" [--allow "<경로>"]...
#         --allow로 준 경로(":(top)" 접두어는 있어도 없어도 됨)는 세 검사 모두에서 뺀다.

export LC_ALL=C
# 사용자 환경의 CDPATH나 git 위치 변수가 검사할 저장소를 바꾸지 못하게 한다.
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
# 대체 객체(git replace)가 검사할 내용을 다른 내용으로 보이게 하지 못하게 한다.
export GIT_NO_REPLACE_OBJECTS=1

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
cd -- "$ROOT" 2>/dev/null || usage

TMP="$(mktemp -d 2>/dev/null)" || fail "임시 폴더를 만들지 못했습니다"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/allow" || fail "임시 파일을 만들지 못했습니다"

while [ $# -gt 0 ]; do
  case "$1" in
    --allow)
      [ $# -ge 2 ] || usage
      # 예외는 파일 하나씩이다. 줄바꿈이 든 값은 여러 예외로 번지므로 받지 않는다.
      case "$2" in *"
"*) usage ;; esac
      printf '%s\n' "${2#:(top)}" >> "$TMP/allow" || fail "임시 파일을 쓰지 못했습니다"
      shift 2
      ;;
    *) usage ;;
  esac
done

# 사용자 git 설정(색, 외부 diff 도구, 접두어 생략·변경, 하위 폴더 기준 출력, 경로 따옴표)이 출력 모양을 바꾸지 못하게 고정한다.
G() {
  git -c core.quotePath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false \
    -c diff.relative=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/ "$@"
}

# git은 `"`, `\`, 제어 문자가 든 경로를 C 따옴표로 감싼다("we\"ird/.env"). 이를 풀어 실제 경로로 바꾼다.
# 줄바꿈은 줄 단위 처리와 맞지 않으므로 풀지 않고 nl 표시만 남긴다(목록 단계에서 검사 실패로 멈춤).
UNQUOTE='
function unq(s,    out, i, c, n, d) {
  if (s !~ /^".*"$/) return s
  s = substr(s, 2, length(s) - 2)
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c != "\\") { out = out c; continue }
    i++; c = substr(s, i, 1)
    if (c == "t") out = out "\t"
    else if (c == "n") { nl = 1; out = out "?" }
    else if (c == "r") out = out "\r"
    else if (c == "a") out = out "\007"
    else if (c == "b") out = out "\b"
    else if (c == "f") out = out "\f"
    else if (c == "v") out = out "\v"
    else if (c ~ /[0-7]/) {
      n = c + 0; d = 1
      while (d < 3 && substr(s, i + 1, 1) ~ /[0-7]/) { i++; n = n * 8 + substr(s, i, 1); d++ }
      out = out sprintf("%c", n)
    }
    else out = out c
  }
  return out
}'

NAME_RE='(^|/)(\.env(\.[^/]*)?|\.envrc|\.npmrc|\.netrc|[^/]*\.(pem|p12|pfx|keystore|ppk)|id_(rsa|dsa|ed25519|ecdsa)[^/]*|[^/]*credentials[^/]*\.json|client_secret[^/]*\.json|[^/]*service-account[^/]*\.json|token\.json|secrets\.[^/]*)$'
LIMIT_BYTES=52428800

# 0이면 찾음, 1이면 못 찾음. 그 밖은 grep 자체의 실패다.
grep_ok() {
  [ "$1" -le 1 ]
}

G rev-parse --git-dir > /dev/null 2>&1 || fail "git 저장소가 아닙니다"

# 스테이징 목록: ":<옛 모드> <새 모드> <옛 id> <새 id> <상태><TAB><경로>"
G diff --cached --raw --no-abbrev --no-renames --diff-filter=d > "$TMP/raw" || fail "스테이징 목록을 읽지 못했습니다"
awk -F'\t' "$UNQUOTE"' { print unq($2) } END { if (nl) exit 4 }' "$TMP/raw" > "$TMP/names"; rc=$?
[ "$rc" -ne 4 ] || fail "이름에 줄바꿈이 든 파일이 스테이징되어 있어 검사할 수 없습니다. 그 파일 이름을 바꾼 뒤 다시 시도하세요"
[ "$rc" -eq 0 ] || fail "스테이징 목록을 나누지 못했습니다"

# [이름]
grep -iE "$NAME_RE" "$TMP/names" > "$TMP/name1"; grep_ok $? || fail "이름 검사"
grep -viE '(^|/)\.env\.example$' "$TMP/name1" > "$TMP/name_hits"; grep_ok $? || fail "이름 검사"

# [내용]: 파일 머리말은 "F경로", 추가된 줄은 " 내용"으로 바꿔 한 파일에 담는다.
# "+++ " 줄은 "diff --git" 바로 뒤 머리말 구간에서만 파일 이름으로 읽는다(추가된 줄이 "++ "로 시작해도 헷갈리지 않게).
G diff --cached -U0 --no-color --no-ext-diff --no-textconv --no-renames --diff-filter=d > "$TMP/diff" || fail "변경 내용을 읽지 못했습니다"
awk "$UNQUOTE"'
  /^diff --git / { hdr = 1; next }
  hdr && /^\+\+\+ / { f = substr($0, 5); sub(/\t$/, "", f); f = unq(f); sub(/^b\//, "", f); print "F" f; next }
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
  -e 'npm_[A-Za-z0-9]{36}' \
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

# [크기]: 하위 저장소(모드 160000)는 크기를 볼 수 없으므로 뺀다. 경로에 탭이 있을 수 있으므로 앞 두 칸을 떼고 나머지 전체를 경로로 쓴다.
awk -F'\t' "$UNQUOTE"' { split($1, m, " "); if (m[2] != "160000") print m[4] "\t" unq($2) }' "$TMP/raw" > "$TMP/blobs" || fail "크기 검사 준비"
cut -f1 "$TMP/blobs" > "$TMP/ids" || fail "크기 검사 준비"
git cat-file --batch-check='%(objectsize)' < "$TMP/ids" > "$TMP/sizes" || fail "파일 크기를 읽지 못했습니다"
paste "$TMP/sizes" "$TMP/blobs" > "$TMP/sized" || fail "크기 검사 준비"
awk -F'\t' -v lim="$LIMIT_BYTES" '
  $1 !~ /^[0-9]+$/ { bad = 1; next }
  $1 + 0 > lim { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); print p }
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
