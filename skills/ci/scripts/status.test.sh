#!/usr/bin/env bash
# status.sh 회귀 시험. git 없음, 정상, git status 실패, rev-parse 실패, 커밋 없는 저장소를 임시 폴더에서 확인한다.
# 사용법: bash skills/ci/scripts/status.test.sh
#         STATUS_SH=<다른 스크립트 경로> 로 바꿔 끼워 시험할 수 있다(결함을 넣은 사본 확인용).
# 결과: 항목마다 "통과"/"실패"를 출력하고, 하나라도 실패하면 종료 코드 1.

# 결과 비교는 바이트 단위로 한다(UTF-8 로케일의 macOS awk는 한글 머리말 비교가 어긋남). 스크립트 실행은 시험마다 로케일을 따로 정한다.
export LC_ALL=C

SCRIPT="${STATUS_SH:-$(cd "$(dirname "$0")" && pwd)/status.sh}"
WORK="$(mktemp -d)" || { echo "임시 폴더를 만들지 못했습니다" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "통과: $1"; }
ng() { FAIL=$((FAIL + 1)); echo "실패: $1"; }

section() { printf '%s\n' "$1" | awk -v h="[$2]" '$0 == h { on = 1; next } /^\[/ { on = 0 } on'; }
expect_eq() { local got; got="$(section "$2" "$3")"; if [ "$got" = "$4" ]; then ok "$1"; else ng "$1 — [$3] 아래가 '$got'"; fi; }
expect_contains() { if section "$2" "$3" | grep -Fq -- "$4"; then ok "$1"; else ng "$1 — [$3]에 '$4'가 없음"; fi; }
run() { (cd "$1" && LANG=ko_KR.UTF-8 LC_ALL= bash "$SCRIPT" "$1"); }   # 한국어 환경에서도 git 안내가 영어로 나와야 함

# git 없는 폴더
D="$(mktemp -d "$WORK/nogit.XXXX")"
OUT="$(run "$D")"; RC=$?
expect_contains "git 없음: [git]에 영어 오류" "$OUT" git "not a git repository"
expect_eq "git 없음: [변경]은 0" "$OUT" 변경 "0"
[ "$RC" -eq 0 ] && ok "git 없음: 종료 코드 0" || ng "git 없음: 종료 코드 0 — $RC"

# 커밋 없는 저장소
D="$(mktemp -d "$WORK/unborn.XXXX")"
git -C "$D" init -q
echo x > "$D/f.txt"
OUT="$(run "$D")"; RC=$?
expect_contains "커밋 없음: [기록]에 영어 안내" "$OUT" 기록 "does not have any commits yet"
expect_eq "커밋 없음: [변경]은 1" "$OUT" 변경 "1"

# 정상 저장소(커밋 1개, 커밋 안 된 파일 2개)
D="$(mktemp -d "$WORK/normal.XXXX")"
git -C "$D" init -q
git -C "$D" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m "첫 커밋"
echo a > "$D/a.txt"
echo b > "$D/b.txt"
OUT="$(run "$D")"; RC=$?
expect_contains "정상: [기록]에 커밋" "$OUT" 기록 "첫 커밋"
expect_eq "정상: [변경]은 2" "$OUT" 변경 "2"
[ "$RC" -eq 0 ] && ok "정상: 종료 코드 0" || ng "정상: 종료 코드 0 — $RC"

# 저장소인데 git status가 실패(index를 깨뜨림)
D="$(mktemp -d "$WORK/broken.XXXX")"
git -C "$D" init -q
git -C "$D" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init
echo a > "$D/a.txt"
echo garbage > "$D/.git/index"
OUT="$(run "$D")"; RC=$?
expect_eq "status 실패: [변경]은 확인 못 함" "$OUT" 변경 "확인 못 함"
[ "$RC" -eq 0 ] && ok "status 실패: 종료 코드 0" || ng "status 실패: 종료 코드 0 — $RC"

# 저장소인데 rev-parse부터 실패(소유자 불일치, Cowork의 마운트 폴더에서 생길 수 있음)
D="$(mktemp -d "$WORK/owner.XXXX")"
git -C "$D" init -q
OUT="$(cd "$D" && GIT_TEST_ASSUME_DIFFERENT_OWNER=1 LANG=ko_KR.UTF-8 LC_ALL= bash "$SCRIPT" "$D")"; RC=$?
expect_contains "소유자 불일치: [git]에 영어 오류" "$OUT" git "dubious ownership"
expect_eq "소유자 불일치: [변경]은 확인 못 함" "$OUT" 변경 "확인 못 함"
[ "$RC" -eq 0 ] && ok "소유자 불일치: 종료 코드 0" || ng "소유자 불일치: 종료 코드 0 — $RC"

# 인자 오류
bash "$SCRIPT" "$WORK/없는폴더" > /dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "없는 폴더는 종료 코드 2" || ng "없는 폴더는 종료 코드 2 — $RC"

# 해시. 해시 목록(SHA256SUMS)이 스크립트와 맞고, Cowork처럼 스크립트를 다른 셸로 옮기는 경로(gzip+base64, 따옴표 친 heredoc)를 거쳐도 바이트가 그대로인지 확인한다.
#    스크립트를 고치면 SHA256SUMS도 함께 갱신해야 이 시험이 통과한다(`shasum -a 256 status.sh > SHA256SUMS`).
DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
NAME="$(basename "$SCRIPT")"
EXPECT="$(awk -v n="$NAME" '$2 == n { print $1 }' "$DIR/SHA256SUMS" 2> /dev/null)"
ACTUAL="$(shasum -a 256 "$SCRIPT" | awk '{ print $1 }')"
if [ -n "$EXPECT" ] && [ "$EXPECT" = "$ACTUAL" ]; then ok "해시 SHA256SUMS가 스크립트와 맞음"; else ng "해시 SHA256SUMS가 스크립트와 맞음 — 기대 '$EXPECT', 실제 '$ACTUAL'"; fi
gzip -c "$SCRIPT" | base64 > "$WORK/enc.txt"
base64 -d < "$WORK/enc.txt" 2> /dev/null | gunzip > "$WORK/b64.sh" 2> /dev/null || base64 -D < "$WORK/enc.txt" | gunzip > "$WORK/b64.sh"
if [ "$(shasum -a 256 "$WORK/b64.sh" | awk '{ print $1 }')" = "$ACTUAL" ]; then ok "해시 gzip+base64로 옮겨도 같은 해시"; else ng "해시 gzip+base64로 옮겨도 같은 해시"; fi
{ printf "cat > '%s' <<'NDH_SCRIPT_EOF'\n" "$WORK/heredoc.sh"; cat "$SCRIPT"; printf 'NDH_SCRIPT_EOF\n'; } > "$WORK/write.sh"
bash "$WORK/write.sh"
if [ "$(shasum -a 256 "$WORK/heredoc.sh" | awk '{ print $1 }')" = "$ACTUAL" ]; then ok "해시 따옴표 친 heredoc으로 옮겨도 같은 해시"; else ng "해시 따옴표 친 heredoc으로 옮겨도 같은 해시"; fi

echo "결과: 통과 $PASS, 실패 $FAIL"
[ "$FAIL" -eq 0 ]
