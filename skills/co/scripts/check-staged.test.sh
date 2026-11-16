#!/usr/bin/env bash
# check-staged.sh 회귀 시험. 지금까지 재현한 우회·오탐 사례를 임시 저장소에서 다시 확인한다.
# 사용법: bash skills/co/scripts/check-staged.test.sh
#         CHECK_STAGED=<다른 스크립트 경로> 로 바꿔 끼워 시험할 수 있다(결함을 넣은 사본 확인용).
# 비밀 미끼 문자열은 실행 중에 조립한다(키 모양 문자열이 든 파일 쓰기를 막는 도구가 있어서).
# 결과: 항목마다 "통과"/"실패"를 출력하고, 하나라도 실패하면 종료 코드 1.

# 결과 비교는 바이트 단위로 한다(UTF-8 로케일의 macOS awk는 한글 머리말 비교가 어긋남). 스크립트 실행은 시험마다 로케일을 따로 정한다.
export LC_ALL=C

SCRIPT="${CHECK_STAGED:-$(cd "$(dirname "$0")" && pwd)/check-staged.sh}"
WORK="$(mktemp -d)" || { echo "임시 폴더를 만들지 못했습니다" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "통과: $1"; }
ng() { FAIL=$((FAIL + 1)); echo "실패: $1"; }

# 출력에서 [머리말] 아래 줄만 꺼낸다.
section() { printf '%s\n' "$1" | awk -v h="[$2]" '$0 == h { on = 1; next } /^\[/ { on = 0 } on'; }
has() { section "$1" "$2" | grep -Fxq -- "$3"; }
expect_has() { if has "$2" "$3" "$4"; then ok "$1"; else ng "$1 — [$3]에 '$4'가 없음"; fi; }
expect_lacks() { if has "$2" "$3" "$4"; then ng "$1 — [$3]에 '$4'가 있음"; else ok "$1"; fi; }
expect_done() {
  if [ "$3" -eq 0 ] && [ "$(printf '%s\n' "$2" | tail -n 1)" = "[끝]" ]; then ok "$1"; else ng "$1 — 종료 코드 $3, 마지막 줄 '$(printf '%s\n' "$2" | tail -n 1)'"; fi
}

new_repo() {
  R="$(mktemp -d "$WORK/repo.XXXX")"
  git -C "$R" init -q
  git -C "$R" config user.name test
  git -C "$R" config user.email test@example.invalid
}

# 미끼 조립
SK="s""k-proj-$(printf 'Ab3%.0s' $(seq 1 10))"          # sk-proj- + 영숫자 30자
AK="AK""IA"
AWS_KEY="${AK}ABCDEFGHIJKLMNOP"
AWS_DOC_EXAMPLE="${AK}IOSFODNN7EXAMPLE"                 # 공식 문서 예시 값(통과해야 함)
NPM_TOKEN="n""pm_$(printf 'Ab3%.0s' $(seq 1 12))"       # npm_ + 영숫자 36자

# 1. 출력 모양을 바꾸는 사용자 설정과 CP949 파일을 함께 걸어도 두 키 파일이 걸림
new_repo
printf '\270\305\303\342,1000\n' > "$R/aa-cp949.csv"       # CP949 "매출"
printf 'key=%s\n' "$SK" > "$R/메모 파일.txt"
printf 'id=%s\n' "$AWS_KEY" > "$R/notes.md"
git -C "$R" config color.ui always
git -C "$R" config diff.external true
git -C "$R" config diff.noprefix true
git -C "$R" config diff.mnemonicPrefix true
printf '*.md diff=hide\n' > "$R/.gitattributes"
git -C "$R" config diff.hide.textconv "sh -c 'echo HIDDEN'"
git -C "$R" add -A
OUT="$(cd "$R" && LANG=ko_KR.UTF-8 LC_ALL= bash "$SCRIPT" "$R")"; RC=$?
expect_has "1 사용자 설정·CP949: 공백 있는 한글 이름 파일의 키" "$OUT" 내용 ":(top)메모 파일.txt"
expect_has "1 사용자 설정·CP949: textconv가 걸린 파일의 키" "$OUT" 내용 ":(top)notes.md"
expect_done "1 사용자 설정·CP949: 검사 완료" "$OUT" "$RC"

# 2. 하위 폴더 루트 + diff.relative=true + 루트 밖에 미리 스테이징된 키 파일
new_repo
mkdir -p "$R/proj" "$R/other"
printf 'k=%s\n' "$SK" > "$R/other/leak.txt"
printf 'k=%s\n' "$SK" > "$R/proj/in-root.txt"
echo '{}' > "$R/proj/token.json"
git -C "$R" add other/leak.txt
git -C "$R" add -A -- "$R/proj"
git -C "$R" config diff.relative true
OUT="$(cd "$R/proj" && bash "$SCRIPT" "$R/proj")"; RC=$?
expect_has "2 diff.relative: 루트 밖 키 파일" "$OUT" 내용 ":(top)other/leak.txt"
expect_has "2 diff.relative: 루트 안 키 파일 경로가 최상위 기준" "$OUT" 내용 ":(top)proj/in-root.txt"
expect_has "2 diff.relative: 이름 검사 경로가 최상위 기준" "$OUT" 이름 ":(top)proj/token.json"
expect_done "2 diff.relative: 검사 완료" "$OUT" "$RC"

# 3. 자리표시자 판정은 걸린 토큰 단위
new_repo
printf 'OPENAI_API_KEY=s''k-proj-YOUR_API_KEY_HERE\n' > "$R/placeholder.txt"
printf 'YOUR key: %s\n' "$SK" > "$R/your-line.txt"
printf 'see EXAMPLE docs; real=%s\n' "$SK" > "$R/example-line.txt"
printf 'aws_access_key_id=%s\n' "$AWS_DOC_EXAMPLE" > "$R/aws-example.txt"
git -C "$R" add -A
OUT="$(bash "$SCRIPT" "$R")"; RC=$?
expect_lacks "3 자리표시자 토큰은 통과" "$OUT" 내용 ":(top)placeholder.txt"
expect_has "3 같은 줄에 YOUR가 있어도 진짜 키는 걸림" "$OUT" 내용 ":(top)your-line.txt"
expect_has "3 같은 줄에 EXAMPLE이 있어도 진짜 키는 걸림" "$OUT" 내용 ":(top)example-line.txt"
expect_lacks "3 공식 예시 AWS 키는 통과" "$OUT" 내용 ":(top)aws-example.txt"
expect_done "3 자리표시자: 검사 완료" "$OUT" "$RC"

# 4. git이 따옴표로 감싸는 경로(", \, 탭, 제어 문자)를 실제 경로로 출력하고, 그 경로로 git 명령이 맞음
new_repo
TABDIR="$(printf 'tab\there')"
CTL="$(printf 'ctl\001x.txt')"
mkdir -p "$R/we\"ird" "$R/back\\slash" "$R/$TABDIR"
echo x > "$R/we\"ird/.env"
printf 'k=%s\n' "$SK" > "$R/quo\"te.txt"
printf 'k=%s\n' "$SK" > "$R/back\\slash/b\\s.txt"
printf 'k=%s\n' "$SK" > "$R/$TABDIR/t.txt"
printf 'k=%s\n' "$SK" > "$R/$CTL"
git -C "$R" add -A
OUT="$(bash "$SCRIPT" "$R")"; RC=$?
expect_has "4 따옴표가 든 폴더의 .env" "$OUT" 이름 ":(top)we\"ird/.env"
expect_has "4 따옴표가 든 파일 이름" "$OUT" 내용 ":(top)quo\"te.txt"
expect_has "4 역슬래시가 든 경로" "$OUT" 내용 ":(top)back\\slash/b\\s.txt"
expect_has "4 탭이 든 경로" "$OUT" 내용 ":(top)$TABDIR/t.txt"
expect_has "4 제어 문자가 든 파일 이름" "$OUT" 내용 ":(top)$CTL"
MISS=0
while IFS= read -r p; do
  [ -n "$(git -C "$R" ls-files -- "$p")" ] || { MISS=1; echo "   ls-files로 찾지 못함: $p"; }
done <<EOF2
$(printf '%s\n' "$OUT" | grep '^:(top)')
EOF2
if [ "$MISS" -eq 0 ]; then ok "4 출력 경로를 git ls-files에 그대로 쓸 수 있음"; else ng "4 출력 경로를 git ls-files에 그대로 쓸 수 있음"; fi
expect_done "4 인용 경로: 검사 완료" "$OUT" "$RC"

# 5. 이름 검사(.npmrc, 대소문자), npm 토큰, --allow 예외(따옴표가 든 경로 포함)
new_repo
echo 'registry=https://registry.example.invalid/' > "$R/.npmrc"
echo x > "$R/KEY.PEM"
printf 'k=%s\n' "$SK" > "$R/a.txt"
printf 'k=%s\n' "$SK" > "$R/b.txt"
printf 'k=%s\n' "$SK" > "$R/quo\"te.txt"
printf '//registry.npmjs.org/:_authToken=%s\n' "$NPM_TOKEN" > "$R/npm-token.txt"
echo x > "$R/.env"
git -C "$R" add -A
OUT="$(bash "$SCRIPT" "$R")"; RC=$?
expect_has "5 .npmrc 이름" "$OUT" 이름 ":(top).npmrc"
expect_has "5 대문자 KEY.PEM 이름" "$OUT" 이름 ":(top)KEY.PEM"
expect_has "5 npm 토큰 내용" "$OUT" 내용 ":(top)npm-token.txt"
expect_has "5 --allow 전에는 따옴표 든 파일이 걸림" "$OUT" 내용 ":(top)quo\"te.txt"
OUT="$(bash "$SCRIPT" "$R" --allow ':(top)a.txt' --allow .env --allow ':(top)quo"te.txt')"; RC=$?
expect_lacks "5 --allow로 뺀 파일(:(top) 붙임)" "$OUT" 내용 ":(top)a.txt"
expect_lacks "5 --allow로 뺀 파일(:(top) 없음)" "$OUT" 이름 ":(top).env"
expect_lacks "5 --allow로 뺀 따옴표 든 파일" "$OUT" 내용 ":(top)quo\"te.txt"
expect_has "5 --allow로 빼지 않은 파일은 그대로 걸림" "$OUT" 내용 ":(top)b.txt"
expect_done "5 --allow: 검사 완료" "$OUT" "$RC"

# 6. 50MB 넘는 파일
new_repo
dd if=/dev/zero of="$R/big.bin" bs=1048576 count=51 2> /dev/null
echo small > "$R/small.txt"
git -C "$R" add -A
OUT="$(bash "$SCRIPT" "$R")"; RC=$?
expect_has "6 51MB 파일" "$OUT" 크기 ":(top)big.bin"
expect_lacks "6 작은 파일은 크기 검사 통과" "$OUT" 크기 ":(top)small.txt"
expect_done "6 크기: 검사 완료" "$OUT" "$RC"

# 7. 실패 처리
NOREPO="$(mktemp -d "$WORK/norepo.XXXX")"
OUT="$(bash "$SCRIPT" "$NOREPO" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && ! printf '%s\n' "$OUT" | grep -Fxq '[끝]'; then ok "7 저장소가 아니면 [끝] 없이 0이 아닌 종료 코드"; else ng "7 저장소가 아니면 [끝] 없이 0이 아닌 종료 코드 — 종료 코드 $RC"; fi
bash "$SCRIPT" > /dev/null 2>&1; RC=$?
if [ "$RC" -eq 2 ]; then ok "7 인자 없음은 종료 코드 2"; else ng "7 인자 없음은 종료 코드 2 — $RC"; fi

# 8. 이름에 줄바꿈이 든 파일은 검사 실패로 멈춘다(글자 그대로의 역슬래시+n 이름과 겹치지 않게).
#    역슬래시+n 이름은 평소대로 검사하고, 탭이 든 큰 파일은 크기 검사에서 경로가 잘리지 않는다.
NL="$(printf '\nx')"; NL="${NL%x}"
new_repo
echo x > "$R/new${NL}line.txt"
git -C "$R" add -A
OUT="$(bash "$SCRIPT" "$R" 2>&1)"; RC=$?
if [ "$RC" -eq 3 ] && ! printf '%s\n' "$OUT" | grep -Fxq '[끝]'; then ok "8 줄바꿈 이름은 검사 실패(종료 코드 3)"; else ng "8 줄바꿈 이름은 검사 실패 — 종료 코드 $RC"; fi
new_repo
printf 'k=%s\n' "$SK" > "$R/back\\nslash.txt"
mkdir "$R/tab	here"
dd if=/dev/zero of="$R/tab	here/big.bin" bs=1048576 count=51 2> /dev/null
git -C "$R" add -A
OUT="$(bash "$SCRIPT" "$R")"; RC=$?
expect_has "8 역슬래시+n 이름은 평소대로 검사" "$OUT" 내용 ':(top)back\nslash.txt'
expect_has "8 탭이 든 큰 파일의 경로가 잘리지 않음" "$OUT" 크기 ":(top)tab	here/big.bin"
expect_done "8 역슬래시+n·탭 이름: 검사 완료" "$OUT" "$RC"

# 9. 해시 목록(SHA256SUMS)이 스크립트와 맞고, Cowork처럼 스크립트를 다른 셸로 옮기는 경로(gzip+base64, 따옴표 친 heredoc)를 거쳐도 바이트가 그대로인지 확인한다.
#    스크립트를 고치면 SHA256SUMS도 함께 갱신해야 이 시험이 통과한다(`shasum -a 256 check-staged.sh commit-checked.sh > SHA256SUMS`).
DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
NAME="$(basename "$SCRIPT")"
EXPECT="$(awk -v n="$NAME" '$2 == n { print $1 }' "$DIR/SHA256SUMS" 2> /dev/null)"
ACTUAL="$(shasum -a 256 "$SCRIPT" | awk '{ print $1 }')"
if [ -n "$EXPECT" ] && [ "$EXPECT" = "$ACTUAL" ]; then ok "9 SHA256SUMS가 스크립트와 맞음"; else ng "9 SHA256SUMS가 스크립트와 맞음 — 기대 '$EXPECT', 실제 '$ACTUAL'"; fi
gzip -c "$SCRIPT" | base64 > "$WORK/enc.txt"
base64 -d < "$WORK/enc.txt" 2> /dev/null | gunzip > "$WORK/b64.sh" 2> /dev/null || base64 -D < "$WORK/enc.txt" | gunzip > "$WORK/b64.sh"
if [ "$(shasum -a 256 "$WORK/b64.sh" | awk '{ print $1 }')" = "$ACTUAL" ]; then ok "9 gzip+base64로 옮겨도 같은 해시"; else ng "9 gzip+base64로 옮겨도 같은 해시"; fi
{ printf "cat > '%s' <<'NDH_SCRIPT_EOF'\n" "$WORK/heredoc.sh"; cat "$SCRIPT"; printf 'NDH_SCRIPT_EOF\n'; } > "$WORK/write.sh"
bash "$WORK/write.sh"
if [ "$(shasum -a 256 "$WORK/heredoc.sh" | awk '{ print $1 }')" = "$ACTUAL" ]; then ok "9 따옴표 친 heredoc으로 옮겨도 같은 해시"; else ng "9 따옴표 친 heredoc으로 옮겨도 같은 해시"; fi

echo "결과: 통과 $PASS, 실패 $FAIL"
[ "$FAIL" -eq 0 ]
