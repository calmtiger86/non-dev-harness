이 파일은 /hs에서 기록 파일을 템플릿으로 만들 때(새로 만들기, 그리고 다른 모드에서 빠진 파일을 만들 때) 읽습니다.

# 템플릿과 치환 규칙

## 템플릿 위치
- `${CLAUDE_SKILL_DIR}/templates/`에서 템플릿을 Read 도구로 읽어 `{{placeholder}}`를 치환합니다. 이 파일 안의 `${CLAUDE_SKILL_DIR}`는 치환되지 않으므로, SKILL.md 본문에 실제로 적힌 스킬 폴더 경로를 씁니다. 그 경로도 알 수 없으면 SKILL.md와 같은 폴더의 `templates/`를 찾습니다.
- `CLAUDE.md.template` → CLAUDE.md
- `JOURNAL.md.template` → JOURNAL.md
- `ERROR.md.template` → ERROR.md
- `ISSUE.md.template` → ISSUE.md
- `WIKI.md.template` → WIKI.md

## 치환 값 정리
사용자가 답한 값에만 적용하고, `{{CUSTOM_RULES}}`와 `{{DATE}}`처럼 정해진 값에는 적용하지 않습니다.
- 각 줄 맨 앞의 `#`과 그 뒤 공백만 지웁니다. 줄 중간의 `#`은 그대로 둡니다("C# 공부"는 바뀌지 않습니다).
- `<`로 시작해 `>`로 끝나는 태그를 지웁니다.
- 줄바꿈은 공백 하나로 바꿉니다.
- 200자를 넘으면 200자에서 자릅니다.

## 치환 변수
- `{{PROJECT_NAME}}` → 인터뷰 1번 답변 (업데이트·업그레이드는 CLAUDE.md 첫 `#` 제목)
- `{{PROJECT_DESCRIPTION}}` → 인터뷰 2번 답변 (1-2문장 설명)
- `{{PURPOSE}}` → 인터뷰 2번 답변에서 핵심 목적만 추출 (한 구절)
- `{{AUDIENCE}}` → 인터뷰 3번 답변
- `{{TECH_STACK}}` → 인터뷰 4번 답변 (없으면 "해당 없음")
- `{{LANGUAGE}}` → 인터뷰 5번 답변 (기본: 한국어)
- `{{CUSTOM_RULES}}` → `<!-- 프로젝트 진행하며 자동으로 채워집니다 -->`
- `{{DATE}}` → 오늘 날짜 (YYYY-MM-DD)

## 새 CLAUDE.md
- 현재 폴더에 `AGENTS.md`가 있으면 새 CLAUDE.md의 설명 줄 아래에 `@AGENTS.md` 한 줄을 넣습니다.
