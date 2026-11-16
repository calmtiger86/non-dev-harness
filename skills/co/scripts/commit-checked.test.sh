#!/usr/bin/env bash
# commit-checked.sh 회귀 시험. 임시 저장소에서 "검사를 통과한 내용만, 검사한 그대로 커밋한다"와
# 지금까지 재현된 우회 시도(옵션 끼우기, 패턴 경로, 지운 파일, assume-unchanged, 훅, CDPATH, 줄바꿈 예외,
# 다른 저장소)가 막히는지 확인한다.
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

MARK='<!-- non-dev-harness:v2 -->'
# 하네스 저장소(첫 커밋 있음)를 만든다. R은 저장소 루트.
new_repo() {
  R="$(mktemp -d "$WORK/repo.XXXX")/내 프로젝트"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.name test
  git -C "$R" config user.email test@example.invalid
  printf '%s\n# 시험\n' "$MARK" > "$R/CLAUDE.md"
  git -C "$R" add -A
  git -C "$R" commit -q -m base
}
# 루트 안에서 스크립트를 실행한다(사전 승인 실행과 같은 조건).
run() { (cd "$R" && bash "$SCRIPT" "$R" "$@"); }
commits() { git -C "$R" rev-list --count HEAD 2> /dev/null || echo 0; }
staged() { git -C "$R" diff --cached --name-only; }
files() { git -c core.quotePath=false -C "$R" show --name-only --format= HEAD | sort | tr '\n' ' '; }

SK="s""k-proj-$(printf 'Ab3%.0s' $(seq 1 10))"

# 1. 걸린 것이 없으면 스테이징한 그대로 커밋한다. 메시지는 준 그대로.
new_repo
echo hello > "$R/notes.md"
git -C "$R" add -A
OUT="$(run "co: 시험 커밋")"; RC=$?
check "1 통과하면 커밋(종료 코드 0)" '[ "$RC" -eq 0 ] && [ "$(commits)" -eq 2 ]'
check "1 마지막 줄이 [커밋]" 'printf "%s\n" "$OUT" | tail -n 1 | grep -q "^\[커밋\] "'
check "1 메시지 그대로" '[ "$(git -C "$R" log -1 --format=%B | sed "/^$/d")" = "co: 시험 커밋" ]'
check "1 커밋 뒤 스테이징 목록이 비어 있음" '[ -z "$(staged)" ]'

# 2. 검사 뒤 작업 파일을 바꿔도 커밋되는 것은 검사한 스테이징 내용이다.
new_repo
echo clean > "$R/memo.txt"
git -C "$R" add -A
printf 'k=%s\n' "$SK" > "$R/memo.txt"
run "co: 스테이징만" > /dev/null; RC=$?
check "2 작업 파일이 아니라 스테이징 내용을 커밋" '[ "$RC" -eq 0 ] && [ "$(git -C "$R" show HEAD:memo.txt)" = "clean" ]'

# 3. 걸린 파일이 있으면 커밋하지 않고 스테이징도 그대로 둔다(되돌리기는 스킬이 함).
new_repo
echo x > "$R/.env"
git -C "$R" add -A
OUT="$(run "co: 걸림")"; RC=$?
check "3 걸리면 종료 코드 4, 커밋 없음" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 1 ]'
check "3 걸린 경로가 출력에 보임" 'printf "%s\n" "$OUT" | grep -qxF ":(top).env"'
check "3 스테이징은 그대로" 'staged | grep -qxF ".env"'

# 4. 줄바꿈이 든 --allow 값은 받지 않는다. --allow로 뺀 파일은 커밋된다.
run "co: 허용" --allow "$(printf 'harmless\n.env')" > /dev/null 2>&1; RC=$?
check "4 줄바꿈이 든 --allow는 종료 코드 2" '[ "$RC" -eq 2 ] && [ "$(commits)" -eq 1 ]'
run "co: 허용" --allow ".env" > /dev/null; RC=$?
check "4 --allow면 커밋" '[ "$RC" -eq 0 ] && [ "$(commits)" -eq 2 ]'

# 5. Claude-Session 줄이 든 메시지는 거부한다. Co-Authored-By 줄은 받아들인다.
new_repo
echo a > "$R/a.txt"
git -C "$R" add -A
run "$(printf 'co: 세션 줄\n\nClaude-Session: https://claude.ai/code/session_x')" > /dev/null 2>&1; RC=$?
check "5 Claude-Session 줄은 종료 코드 2, 커밋 없음" '[ "$RC" -eq 2 ] && [ "$(commits)" -eq 1 ]'
run "$(printf 'co: 공동 작성\n\nCo-Authored-By: Claude <noreply@anthropic.com>')" > /dev/null; RC=$?
check "5 Co-Authored-By 줄은 받아들임" '[ "$RC" -eq 0 ] && git -C "$R" log -1 --format=%B | grep -q "^Co-Authored-By:"'

# 6. 정해진 인자 말고는 받지 않는다(검사하지 않은 내용을 커밋하는 git 옵션 차단).
new_repo
echo clean > "$R/ok.txt"
git -C "$R" add -- ok.txt
for bad in "--only" "--amend" "-a" "--no-verify" "--author=x <x@x.invalid>"; do
  run "co: 옵션" "$bad" > /dev/null 2>&1; RC=$?
  check "6 옵션 $bad 거부(종료 코드 2)" '[ "$RC" -eq 2 ]'
done
check "6 거부한 뒤 커밋 수 그대로" '[ "$(commits)" -eq 1 ]'

# 7. 경로를 주면 그 경로만 커밋한다. 미리 스테이징된 다른 파일(걸리는 것이어도)은 커밋에 들어가지 않고 남는다.
new_repo
echo "- 규칙" >> "$R/CLAUDE.md"
echo j > "$R/JOURNAL.md"
echo x > "$R/.env"
git -C "$R" add -A
run "hs: 하네스 세팅" -- "CLAUDE.md" "JOURNAL.md" > /dev/null; RC=$?
check "7 지정 경로만 커밋" '[ "$RC" -eq 0 ] && [ "$(files)" = "CLAUDE.md JOURNAL.md " ]'
check "7 밖의 파일은 스테이징에 남음" 'staged | grep -qxF ".env"'
check "7 커밋한 경로는 스테이징 목록에서 정리됨" '! staged | grep -qxF "JOURNAL.md"'

# 8. 지정 경로 안에서 걸리면 커밋하지 않는다.
new_repo
printf 'k=%s\n' "$SK" > "$R/WIKI.md"
git -C "$R" add -A
run "hs: 하네스 세팅" -- "WIKI.md" > /dev/null; RC=$?
check "8 지정 경로 안에서 걸리면 종료 코드 4" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 1 ]'

# 9. 경로 커밋은 작업 파일 내용을 담으므로 그 내용을 검사한다(스테이징한 뒤 작업 파일에 비밀을 넣어도 잡힘).
new_repo
echo clean > "$R/ISSUE.md"
git -C "$R" add -A
printf 'k=%s\n' "$SK" > "$R/ISSUE.md"
run "hs: 하네스 세팅" -- "ISSUE.md" > /dev/null; RC=$?
check "9 작업 파일의 비밀을 잡음(종료 코드 4)" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 1 ]'

# 10. 상위 저장소 안의 하네스 루트(하위 폴더)에서도 맞게 동작한다.
new_repo
mkdir -p "$R/하위"
printf '%s\n# 하위\n' "$MARK" > "$R/하위/CLAUDE.md"
printf 'k=%s\n' "$SK" > "$R/하위/WIKI.md"
git -C "$R" add -A
(cd "$R/하위" && bash "$SCRIPT" "$R/하위" "hs: 하네스 세팅" -- "WIKI.md") > /dev/null; RC=$?
check "10 하위 루트에서 지정 경로의 걸림을 잡음" '[ "$RC" -eq 4 ]'
(cd "$R/하위" && bash "$SCRIPT" "$R/하위" "hs: 하네스 세팅" -- "CLAUDE.md") > /dev/null; RC=$?
check "10 하위 루트에서 다른 경로는 커밋" '[ "$RC" -eq 0 ] && [ "$(files)" = "하위/CLAUDE.md " ]'

# 11. 우회 시도: 패턴처럼 보이는 경로는 글자 그대로 읽혀 다른 파일을 담지 못하고, 폴더 경로는 담은 전부를 검사한다.
new_repo
printf 'k=%s\n' "$SK" > "$R/secret.txt"
for p in "*" ":(glob)**" ":(top)secret.txt"; do
  run "hs: 패턴" -- "$p" > /dev/null 2>&1; RC=$?
  check "11 경로 $p 는 글자 그대로(커밋 없음)" '[ "$RC" -ne 0 ] && [ "$(commits)" -eq 1 ]'
done
for p in "." "././secret.txt" "sub/../secret.txt"; do
  run "hs: 폴더" -- "$p" > /dev/null 2>&1; RC=$?
  check "11 경로 $p 는 담은 내용을 검사해 비밀을 잡음" '[ "$RC" -ne 0 ] && [ "$(commits)" -eq 1 ]'
done

# 12. 우회 시도: 스테이징에서 지운 추적 파일, assume-unchanged 표시를 단 파일도 작업 파일 내용을 검사한다.
new_repo
echo safe > "$R/note1.txt"
echo safe > "$R/note2.txt"
git -C "$R" add -A
git -C "$R" commit -q -m "추적 파일"
git -C "$R" rm -q --cached -- "note1.txt"
printf 'k=%s\n' "$SK" > "$R/note1.txt"
run "hs: 지운 파일" -- "note1.txt" > /dev/null; RC=$?
check "12 스테이징에서 지운 파일의 작업 내용을 검사(종료 코드 4)" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 2 ]'
git -C "$R" update-index --assume-unchanged -- "note2.txt"
printf 'k=%s\n' "$SK" > "$R/note2.txt"
run "hs: 표시" -- "note2.txt" > /dev/null; RC=$?
check "12 assume-unchanged 파일의 작업 내용을 검사(종료 코드 4)" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 2 ]'

# 13. 우회 시도: pre-commit 훅이 검사 뒤에 파일을 끼워 넣어도 커밋에 들어가지 않는다(훅은 실행하지 않음).
new_repo
printf 'k=%s\n' "$SK" > "$R/.env"
mkdir -p "$R/.git/hooks"
printf '#!/bin/sh\ngit add -f .env\n' > "$R/.git/hooks/pre-commit"
chmod +x "$R/.git/hooks/pre-commit"
echo ok > "$R/ok.txt"
git -C "$R" add -- ok.txt
run "co: 훅" > /dev/null; RC=$?
check "13 훅이 끼운 파일은 커밋에 없음" '[ "$RC" -eq 0 ] && [ "$(files)" = "ok.txt " ]'

# 14. 우회 시도: CDPATH가 검사할 저장소를 바꾸지 못한다.
new_repo
PARENT_DIR="$(dirname "$R")"
B="$(mktemp -d "$WORK/cdpath.XXXX")"
mkdir -p "$B/내 프로젝트"
git -C "$B/내 프로젝트" init -q
printf 'k=%s\n' "$SK" > "$R/leak.txt"
git -C "$R" add -A
OUT="$(cd "$PARENT_DIR" && CDPATH="$B" bash "$DIR/check-staged.sh" "내 프로젝트" 2> /dev/null)"
check "14 check-staged.sh는 CDPATH를 무시하고 현재 폴더 기준 루트를 검사" 'printf "%s\n" "$OUT" | grep -qxF ":(top)leak.txt"'
(cd "$R" && CDPATH="$B" bash "$SCRIPT" "." "co: cdpath") > /dev/null; RC=$?
check "14 commit-checked.sh도 같은 저장소를 검사해 걸림(종료 코드 4)" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 1 ]'

# 15. 사전 승인된 실행으로 다른 저장소에 커밋하지 못한다.
new_repo
echo x > "$R/a.txt"
git -C "$R" add -A
OTHER="$R"
new_repo
(cd "$R" && bash "$SCRIPT" "$OTHER" "co: 다른 저장소") > /dev/null; RC=$?
check "15 현재 폴더 밖의 루트는 종료 코드 2" '[ "$RC" -eq 2 ] && [ "$(git -C "$OTHER" rev-list --count HEAD)" -eq 1 ]'
NOMARK="$(mktemp -d "$WORK/nomark.XXXX")"
git -C "$NOMARK" init -q
echo x > "$NOMARK/a.txt"
git -C "$NOMARK" add -A
(cd "$NOMARK" && bash "$SCRIPT" "$NOMARK" "co: 표식 없음") > /dev/null; RC=$?
check "15 하네스 표식이 없는 루트는 종료 코드 2" '[ "$RC" -eq 2 ] && ! git -C "$NOMARK" rev-parse --verify -q HEAD > /dev/null'

# 15b. CLAUDE.md 앞에 BOM 글자가 있어도 표식을 알아본다(Windows 메모장).
new_repo
printf '\357\273\277%s\n# 시험\n' "$MARK" > "$R/CLAUDE.md"
git -C "$R" add -A
run "co: BOM" > /dev/null; RC=$?
check "15b BOM이 붙은 표식도 하네스 루트로 인정" '[ "$RC" -eq 0 ] && [ "$(commits)" -eq 2 ]'

# 16. 첫 커밋(HEAD 없음)도 경로 커밋으로 된다(/hs 새 프로젝트).
R="$(mktemp -d "$WORK/first.XXXX")/새 프로젝트"
mkdir -p "$R"
git -C "$R" init -q
git -C "$R" config user.name test
git -C "$R" config user.email test@example.invalid
printf '%s\n# 새\n' "$MARK" > "$R/CLAUDE.md"
echo j > "$R/JOURNAL.md"
echo other > "$R/other.txt"
git -C "$R" add -- CLAUDE.md JOURNAL.md
run "hs: 하네스 세팅" -- "CLAUDE.md" "JOURNAL.md" > /dev/null; RC=$?
check "16 첫 커밋이 지정 경로만으로 만들어짐" '[ "$RC" -eq 0 ] && [ "$(commits)" -eq 1 ] && [ "$(files)" = "CLAUDE.md JOURNAL.md " ]'

# 17. 바뀐 것이 없으면 종료 코드 5. 저장소가 아니면 3. 인자 부족은 2.
new_repo
run "co: 빈 커밋" > /dev/null; RC=$?
check "17 바뀐 것이 없으면 종료 코드 5" '[ "$RC" -eq 5 ] && [ "$(commits)" -eq 1 ]'
NOREPO="$(mktemp -d "$WORK/norepo.XXXX")"
printf '%s\n' "$MARK" > "$NOREPO/CLAUDE.md"
(cd "$NOREPO" && bash "$SCRIPT" "$NOREPO" "co: x") > /dev/null 2>&1; RC=$?
check "17 저장소가 아니면 종료 코드 3" '[ "$RC" -eq 3 ]'
bash "$SCRIPT" "$NOREPO" > /dev/null 2>&1; RC=$?
check "17 인자 부족은 종료 코드 2" '[ "$RC" -eq 2 ]'

# 20. 우회 시도: 인덱스가 바뀔 때 도는 훅(post-index-change)이 검사할 임시 인덱스를 바꾸지 못한다(훅을 끔).
new_repo
printf 'k=%s\n' "$SK" > "$R/leak.txt"
git -C "$R" add -A
mkdir -p "$R/.git/hooks"
printf '#!/bin/sh\n[ -n "$GIT_INDEX_FILE" ] && git read-tree HEAD\nexit 0\n' > "$R/.git/hooks/post-index-change"
chmod +x "$R/.git/hooks/post-index-change"
run "co: 인덱스 훅" > /dev/null; RC=$?
check "20 인덱스 훅이 있어도 비밀을 잡음(종료 코드 4)" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 1 ]'

# 21. 우회 시도: git replace로 비밀 내용을 안전한 내용처럼 보이게 해도 실제 내용을 검사한다.
new_repo
printf 'k=%s\n' "$SK" > "$R/notes.txt"
git -C "$R" add -A
B_ID="$(git -C "$R" rev-parse :notes.txt)"
S_ID="$(printf 'safe\n' | git -C "$R" hash-object -w --stdin)"
git -C "$R" replace "$B_ID" "$S_ID"
run "co: 대체 객체" > /dev/null; RC=$?
check "21 대체 객체가 있어도 실제 비밀을 잡음(종료 코드 4)" '[ "$RC" -eq 4 ] && [ "$(commits)" -eq 1 ]'

# 22. 우회 시도: 하네스 루트 안에 있는 다른 저장소(중첩)에서 바깥 저장소로 커밋하지 못한다.
new_repo
OUTER="$R"
echo x > "$OUTER/a.txt"
git -C "$OUTER" add -A
mkdir -p "$OUTER/inner"
git -C "$OUTER/inner" init -q
printf '%s\n' "$MARK" > "$OUTER/inner/CLAUDE.md"
(cd "$OUTER/inner" && bash "$SCRIPT" "$OUTER" "co: 중첩") > /dev/null; RC=$?
check "22 다른 저장소의 폴더에서 실행하면 종료 코드 2" '[ "$RC" -eq 2 ] && [ "$(git -C "$OUTER" rev-list --count HEAD)" -eq 1 ]'

# 23. 병합이 진행 중이면 커밋하지 않는다(부모 하나짜리 커밋으로 잘못 기록되지 않게).
new_repo
git -C "$R" checkout -q -b feature
echo f > "$R/f.txt"
git -C "$R" add -A
git -C "$R" commit -q -m feature
git -C "$R" checkout -q -
echo m > "$R/m.txt"
git -C "$R" add -A
git -C "$R" commit -q -m main2
git -C "$R" merge -q --no-ff --no-commit feature > /dev/null 2>&1
run "co: 병합 중" > /dev/null; RC=$?
check "23 병합 중이면 종료 코드 5, 커밋 없음" '[ "$RC" -eq 5 ] && [ "$(commits)" -eq 2 ]'

# 24. 저장소가 서명을 요구하면(commit.gpgSign) 서명하고, 서명에 실패하면 커밋하지 않는다.
new_repo
git -C "$R" config commit.gpgSign true
git -C "$R" config gpg.program false
echo s > "$R/s.txt"
git -C "$R" add -A
run "co: 서명" > /dev/null 2>&1; RC=$?
check "24 서명 실패면 종료 코드 5, 커밋 없음" '[ "$RC" -eq 5 ] && [ "$(commits)" -eq 1 ]'

# 25. 분리 HEAD에서도 그 HEAD 위에 커밋한다(브랜치는 건드리지 않음).
new_repo
git -C "$R" checkout -q --detach
BR_BEFORE="$(git -C "$R" rev-parse refs/heads/master 2> /dev/null || git -C "$R" rev-parse refs/heads/main)"
echo d > "$R/d.txt"
git -C "$R" add -A
run "co: 분리" > /dev/null; RC=$?
check "25 분리 HEAD에서 커밋하고 브랜치는 그대로" '[ "$RC" -eq 0 ] && [ "$(commits)" -eq 2 ] && ! git -C "$R" symbolic-ref -q HEAD > /dev/null && { [ "$(git -C "$R" rev-parse refs/heads/master 2> /dev/null || git -C "$R" rev-parse refs/heads/main)" = "$BR_BEFORE" ]; }'

# 18. 해시 목록이 두 스크립트와 맞는다(Cowork에서 옮겨 실행할 때 이 목록으로 확인).
for n in commit-checked.sh check-staged.sh; do
  E="$(awk -v n="$n" '$2 == n { print $1 }' "$DIR/SHA256SUMS")"
  A="$(shasum -a 256 "$DIR/$n" | awk '{ print $1 }')"
  check "18 SHA256SUMS: $n" '[ -n "$E" ] && [ "$E" = "$A" ]'
done

# 19. 옮겨 실행하는 절차(run-script-elsewhere.md)의 "확인하고 바로 실행" 한 줄: 해시가 다르면 실행되지 않는다.
new_repo
echo hi > "$R/n.txt"
git -C "$R" add -A
H1="$(awk '$2 == "commit-checked.sh" { print $1 }' "$DIR/SHA256SUMS")"
H2="$(awk '$2 == "check-staged.sh" { print $1 }' "$DIR/SHA256SUMS")"
T="$(mktemp -d "$WORK/ndh-script.XXXXXX")"
for n in commit-checked.sh check-staged.sh; do gzip -c "$DIR/$n" | base64 | { base64 -d 2> /dev/null || base64 -D; } | gunzip > "$T/$n"; done
echo '# 바뀐 줄' >> "$T/commit-checked.sh"
(cd "$R" && printf '%s  %s\n' "$H1" "$T/commit-checked.sh" "$H2" "$T/check-staged.sh" | shasum -a 256 -c - > /dev/null 2>&1 && bash "$T/commit-checked.sh" "$R" "co: 바뀐 사본" > /dev/null 2>&1)
check "19 해시가 다르면 실행되지 않음(커밋 없음)" '[ "$(commits)" -eq 1 ]'
T2="$(mktemp -d "$WORK/ndh-script.XXXXXX")"
for n in commit-checked.sh check-staged.sh; do gzip -c "$DIR/$n" | base64 | { base64 -d 2> /dev/null || base64 -D; } | gunzip > "$T2/$n"; done
(cd "$R" && printf '%s  %s\n' "$H1" "$T2/commit-checked.sh" "$H2" "$T2/check-staged.sh" | shasum -a 256 -c - > /dev/null 2>&1 && bash "$T2/commit-checked.sh" "$R" "co: 옮긴 사본" > /dev/null 2>&1)
check "19 해시가 맞으면 옮긴 사본으로 검사와 커밋" '[ "$(commits)" -eq 2 ] && [ "$(git -C "$R" log -1 --format=%s)" = "co: 옮긴 사본" ]'

echo "결과: 통과 $PASS, 실패 $FAIL"
[ "$FAIL" -eq 0 ]
