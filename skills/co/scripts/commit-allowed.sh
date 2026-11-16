#!/usr/bin/env bash
# non-dev-harness: 사용자가 "비밀이 아니다"라고 한 파일(--allow)을 빼고 검사한 뒤 커밋한다.
# 사용법과 동작은 같은 폴더의 commit-checked.sh와 같고, --allow를 받는다는 점만 다르다.
# 이 파일은 스킬의 사전 승인 목록에 넣지 않는다. 그래서 실행할 때마다 확인 창이 뜨고, 창에 예외 경로가 그대로 보인다.
# commit-checked.sh를 직접 실행하면 --allow를 거부하므로, 예외는 사용자가 확인 창에서 허락할 때만 들어간다.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/commit-checked.sh"
