#!/usr/bin/env bash
# non-dev-harness /co 커밋 전 검사.
# 스테이징된 모든 파일(커밋에 들어갈 전부)을 비밀 파일 이름, 비밀 키 내용, 50MB 넘는 크기로 검사한다.
# 루트 인자는 git 명령을 실행할 폴더다. 루트 밖에서 미리 스테이징된 파일도 커밋에 들어가므로 함께 검사한다.
# 삭제되는 파일은 검사하지 않고, 내용은 새로 추가된 줄만 본다.
# 출력은 [이름] [내용] [크기] 머리말 아래에 걸린 파일 경로만 적는다. 비밀 값 자체는 출력하지 않는다.
# 사용법: bash check-staged.sh "<하네스 루트>"

ROOT="$1"
if [ -z "$ROOT" ] || ! cd "$ROOT" 2>/dev/null; then
  echo "사용법: bash check-staged.sh \"<하네스 루트>\"" >&2
  exit 2
fi

NAME_RE='(^|/)(\.env(\.[^/]*)?|[^/]*\.(pem|p12|pfx|keystore)|id_(rsa|ed25519|ecdsa)[^/]*|[^/]*credentials[^/]*\.json|client_secret[^/]*\.json|service-account[^/]*\.json|token\.json|secrets\.[^/]*)$'
LIMIT_BYTES=52428800

staged_names() {
  git -c core.quotePath=false diff --cached --name-only --diff-filter=d
}

echo "[이름]"
staged_names | grep -E "$NAME_RE" | grep -vE '(^|/)\.env\.example$'

echo "[내용]"
git -c core.quotePath=false diff --cached -U0 --diff-filter=d \
 | awk '/^\+\+\+ /{print "@@FILE@@ " substr($0,7); next} /^\+/{print substr($0,2)}' \
 | grep -E -e '^@@FILE@@ ' \
      -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
      -e '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}' \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'ghp_[A-Za-z0-9]{36}' \
      -e 'github_pat_[A-Za-z0-9_]{20,}' \
      -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
      -e 'AIza[0-9A-Za-z_-]{35}' \
 | awk '/^@@FILE@@ /{f=substr($0,10); next} {print f}' | sort -u

echo "[크기]"
staged_names | while IFS= read -r f; do
  s=$(git cat-file -s ":$f" 2>/dev/null) || continue
  [ "$s" -gt "$LIMIT_BYTES" ] && echo "$f"
done

exit 0
