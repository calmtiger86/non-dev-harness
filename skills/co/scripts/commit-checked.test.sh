#!/usr/bin/env bash
# commit-checked.sh 회귀 시험. 임시 저장소에서 "검사를 통과한 스테이징만 커밋한다"를 확인한다.
# 사용법: bash skills/co/scripts/commit-checked.test.sh
# 비밀 미끼 문자열은 실행 중에 조립한다(키 모양 문자열이 든 파일 쓰기를 막는 도구가 있어서).
# 결과: 항목마다 "통과"/"실패"를 출력하고, 하나라도 실패하면 종료 코드 1.

export LC_ALL=C

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/commit-checked.sh"
WORK="$(mktemp -d)" || { echo "임시 폴더를 만들지 못했습니다" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "통과: $1"; }
ng() { FAIL=$((FAIL + 1)); echo "실패: $1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

new_repo() {
  R="$(mktemp -d "$WORK/repo.XXXX")/내 프로젝트"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.name test
  git -C "$R" config user.email test@example.invalid
  echo base > "$R/base.txt"
  git -C "$R" add -A
  git -C "$R" commit -q -m base
}
commits() { git -C "$R" rev-list --count HEAD; }
staged() { git -C "$R" diff --cached --name-only; }

SK="s""k-proj-$(printf 'Ab3%.0s' $(seq 1 10))"

# 1. 걸린 것이 없으면 스테이징한 그대로 커밋한다. 메시지는 준 그대로.
new_repo
echo hello > "$R/notes.md"
git -C "$R" add -A
OUT="$(bash "$SCRIPT" "$R" "co: 시험 커밋")"; RC=$?
check "1 통과하면 커밋(종료 코드 0)" '[ "$RC" -eq 0 ] && [ "$(commits)" -eq 2 ]'
check "1 마지막 줄이 [커밋]" 'printf "%s\n" "$OUT" | tail -n 1 | grep -q "^\[커밋\] "'
check "1 메시지 그대로" '[ "$(git -C "$R" log -1 --format=%B)" = "co: 시험 커밋" ]'

# 2. 검사 뒤 작업 파일을 바꿔도 커밋되는 것은 검사한 스테이징 내용이다.
new_repo
echo clean > "$R/memo.txt"
git -C "$R" add -A
printf 'k=%s\n' "$SK" > "$R/memo.txt"
bash "$SCRIPT" "$R" "co: 스테이징만" > /dev/null; RC=$?
check "2 작업 파일이 아니라 스테이징 내용을 커밋" '[ "$RC" -eq 0 ] && [ "$(git -C "$R" show HEAD:memo.txt)" = "clean" ]'

# 3. 걸린 파일이 있으면 커밋하지 않고 스테이징도 그대로 둔다(되돌리기는 스킬이 함).
new_repo
echo x > "$R/.env"
git -C "$R" add -A
OUT="$(bash "$SCRIPT" "$R" "co: 걸림")"; RC=$?
check "3 걸리면 종료 코드 4, 커밋 없음" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 1 ]'
check "3 걸린 경로가 출력에 보임" 'printf "%s\n" "$OUT" | grep -qxF ":(top).env"'
check "3 스테이징은 그대로" 'staged | grep -qxF ".env"'

# 4. --allow로 뺀 파일은 커밋된다.
bash "$SCRIPT" "$R" "co: 허용" --allow ".env" > /dev/null; RC=$?
check "4 --allow면 커밋" '[ "$RC" -eq 0 ] && [ "$(commits)" -eq 2 ]'

# 5. Claude-Session 줄이 든 메시지는 거부한다. Co-Authored-By 줄은 받아들인다.
new_repo
echo a > "$R/a.txt"
git -C "$R" add -A
MSG_BAD="$(printf 'co: 세션 줄\n\nClaude-Session: https://claude.ai/code/session_x')"
bash "$SCRIPT" "$R" "$MSG_BAD" > /dev/null 2>&1; RC=$?
check "5 Claude-Session 줄은 종료 코드 2, 커밋 없음" '[ "$RC" -eq 2 ] && [ "$(commits)" -eq 1 ]'
MSG_OK="$(printf 'co: 공동 작성\n\nCo-Authored-By: Claude <noreply@anthropic.com>')"
bash "$SCRIPT" "$R" "$MSG_OK" > /dev/null; RC=$?
check "5 Co-Authored-By 줄은 받아들임" '[ "$RC" -eq 0 ] && git -C "$R" log -1 --format=%B | grep -q "^Co-Authored-By:"'

# 6. 정해진 인자 말고는 받지 않는다(검사하지 않은 내용을 커밋하는 git 옵션 차단).
new_repo
printf 'k=%s\n' "$SK" > "$R/.env"
git -C "$R" add -- .env
git -C "$R" commit -q -m "추적 중인 .env"
echo clean > "$R/ok.txt"
git -C "$R" add -- ok.txt
printf 'k2=%s\n' "$SK" > "$R/.env"
for bad in "--only" "--amend" "-a" "--no-verify" "--author=x <x@x.invalid>"; do
  bash "$SCRIPT" "$R" "co: 옵션" "$bad" > /dev/null 2>&1; RC=$?
  check "6 옵션 $bad 거부(종료 코드 2)" '[ "$RC" -eq 2 ]'
done
check "6 거부한 뒤 커밋 수 그대로" '[ "$(commits)" -eq 2 ]'

# 7. 경로를 주면 그 경로만 커밋한다. 미리 스테이징된 다른 파일(걸리는 것이어도)은 커밋에 들어가지 않고 스테이징에 남는다.
new_repo
echo h > "$R/CLAUDE.md"
echo j > "$R/JOURNAL.md"
echo x > "$R/.env"
git -C "$R" add -A
OUT="$(bash "$SCRIPT" "$R" "hs: 하네스 세팅" -- "CLAUDE.md" "JOURNAL.md")"; RC=$?
check "7 지정 경로만 커밋" '[ "$RC" -eq 0 ] && [ "$(git -C "$R" show --name-only --format= HEAD | sort | tr "\n" " ")" = "CLAUDE.md JOURNAL.md " ]'
check "7 밖의 파일은 스테이징에 남음" 'staged | grep -qxF ".env"'
check "7 커밋한 경로는 스테이징 목록에서 정리됨" '! staged | grep -qxF "CLAUDE.md"'

# 8. 지정 경로 안에서 걸리면 커밋하지 않는다.
new_repo
printf 'k=%s\n' "$SK" > "$R/WIKI.md"
git -C "$R" add -A
bash "$SCRIPT" "$R" "hs: 하네스 세팅" -- "WIKI.md" > /dev/null; RC=$?
check "8 지정 경로 안에서 걸리면 종료 코드 4" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 1 ]'

# 9. 경로 커밋은 작업 파일 내용을 담으므로 그 내용을 검사한다(스테이징한 뒤 작업 파일에 비밀을 넣어도 잡힘).
new_repo
echo clean > "$R/ISSUE.md"
git -C "$R" add -A
printf 'k=%s\n' "$SK" > "$R/ISSUE.md"
bash "$SCRIPT" "$R" "hs: 하네스 세팅" -- "ISSUE.md" > /dev/null; RC=$?
check "9 작업 파일의 비밀을 잡음(종료 코드 4)" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 1 ]'

# 10. 상위 저장소 안의 하네스 루트(하위 폴더)에서도 맞게 동작한다.
new_repo
mkdir -p "$R/하위"
echo h > "$R/하위/CLAUDE.md"
printf 'k=%s\n' "$SK" > "$R/하위/WIKI.md"
git -C "$R" add -A
bash "$SCRIPT" "$R/하위" "hs: 하네스 세팅" -- "WIKI.md" > /dev/null; RC=$?
check "10 하위 루트에서 지정 경로의 걸림을 잡음" '[ "$RC" -eq 4 ]'
bash "$SCRIPT" "$R/하위" "hs: 하네스 세팅" -- "CLAUDE.md" > /dev/null; RC=$?
check "10 하위 루트에서 다른 경로는 커밋" '[ "$RC" -eq 0 ] && [ "$(git -c core.quotePath=false -C "$R" show --name-only --format= HEAD)" = "하위/CLAUDE.md" ]'

# 10b. 우회 시도: 패턴처럼 보이는 경로(*, :(glob))는 글자 그대로 읽혀 다른 파일을 담지 못한다.
new_repo
echo h > "$R/CLAUDE.md"
printf 'k=%s\n' "$SK" > "$R/secret.txt"
bash "$SCRIPT" "$R" "hs: 패턴" -- "*" > /dev/null 2>&1; RC=$?
check "10b 경로 * 는 글자 그대로(커밋 없음)" '[ "$RC" -ne 0 ] && [ "$(commits)" -eq 1 ]'
bash "$SCRIPT" "$R" "hs: 매직" -- ":(glob)**" > /dev/null 2>&1; RC=$?
check "10b 경로 :(glob)** 도 글자 그대로(커밋 없음)" '[ "$RC" -ne 0 ] && [ "$(commits)" -eq 1 ]'
bash "$SCRIPT" "$R" "hs: 폴더" -- "." > /dev/null 2>&1; RC=$?
check "10b 경로 . 은 폴더 전체를 담아 검사하므로 비밀을 잡음" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 1 ]'

# 10c. 우회 시도: 스테이징에서 지운(git rm --cached) 추적 파일을 경로로 지정해도 작업 파일 내용을 검사한다.
new_repo
echo safe > "$R/.env.local.txt"
git -C "$R" add -A
git -C "$R" commit -q -m "추적 파일"
git -C "$R" rm -q --cached -- ".env.local.txt"
printf 'k=%s\n' "$SK" > "$R/.env.local.txt"
bash "$SCRIPT" "$R" "hs: 지운 파일" -- ".env.local.txt" > /dev/null; RC=$?
check "10c 스테이징에서 지운 파일의 작업 내용도 검사(종료 코드 4)" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 2 ]'

# 11. 검사가 실패하면(저장소가 아님) 종료 코드 3. 인자 부족은 2.
NOREPO="$(mktemp -d "$WORK/norepo.XXXX")"
bash "$SCRIPT" "$NOREPO" "co: x" > /dev/null 2>&1; RC=$?
check "11 저장소가 아니면 종료 코드 3" '[ "$RC" -eq 3 ]'
bash "$SCRIPT" "$NOREPO" > /dev/null 2>&1; RC=$?
check "11 인자 부족은 종료 코드 2" '[ "$RC" -eq 2 ]'

# 12. 해시 목록이 두 스크립트와 맞는다(Cowork에서 옮겨 실행할 때 이 목록으로 확인).
for n in commit-checked.sh check-staged.sh; do
  E="$(awk -v n="$n" '$2 == n { print $1 }' "$DIR/SHA256SUMS")"
  A="$(shasum -a 256 "$DIR/$n" | awk '{ print $1 }')"
  check "12 SHA256SUMS: $n" '[ -n "$E" ] && [ "$E" = "$A" ]'
done

# 13. Cowork에서 옮겨 실행하는 절차(run-script-elsewhere.md)의 "확인하고 바로 실행" 한 줄: 해시가 다르면 실행되지 않는다.
new_repo
echo hi > "$R/n.txt"
git -C "$R" add -A
T="$(mktemp -d "$WORK/ndh-script.XXXXXX")"
for n in commit-checked.sh check-staged.sh; do
  E="$(gzip -c "$DIR/$n" | base64)"
  printf '%s\n' "$E" | { base64 -d 2> /dev/null || base64 -D; } | gunzip > "$T/$n"
done
H1="$(awk '$2 == "commit-checked.sh" { print $1 }' "$DIR/SHA256SUMS")"
H2="$(awk '$2 == "check-staged.sh" { print $1 }' "$DIR/SHA256SUMS")"
echo '# 바뀐 줄' >> "$T/commit-checked.sh"
printf '%s  %s\n' "$H1" "$T/commit-checked.sh" "$H2" "$T/check-staged.sh" | shasum -a 256 -c - > /dev/null 2>&1 && bash "$T/commit-checked.sh" "$R" "co: 바뀐 사본" > /dev/null 2>&1
check "13 해시가 다르면 실행되지 않음(커밋 없음)" '[ "$(commits)" -eq 1 ]'
T2="$(mktemp -d "$WORK/ndh-script.XXXXXX")"
for n in commit-checked.sh check-staged.sh; do gzip -c "$DIR/$n" | base64 | { base64 -d 2> /dev/null || base64 -D; } | gunzip > "$T2/$n"; done
printf '%s  %s\n' "$H1" "$T2/commit-checked.sh" "$H2" "$T2/check-staged.sh" | shasum -a 256 -c - > /dev/null 2>&1 && bash "$T2/commit-checked.sh" "$R" "co: 옮긴 사본" > /dev/null 2>&1
check "13 해시가 맞으면 옮긴 사본으로 검사와 커밋" '[ "$(commits)" -eq 2 ] && [ "$(git -C "$R" log -1 --format=%s)" = "co: 옮긴 사본" ]'

echo "결과: 통과 $PASS, 실패 $FAIL"
[ "$FAIL" -eq 0 ]
