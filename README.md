# AgentBar

Claude Code와 Codex의 계정 usage/rate limit을 직접 조회해서 5시간/주간 사용량을 메뉴바에 표시하는 macOS 메뉴바 앱입니다.

## Run

```bash
swift build
./.build/debug/AgentBar
```

## What It Does

- Claude: macOS Keychain에 저장된 Claude OAuth 토큰으로 `https://api.anthropic.com/api/oauth/usage`를 직접 조회
- Codex: `codex app-server` JSON-RPC의 `account/rateLimits/read`를 직접 조회
- 메뉴바에 Claude/Codex 각각 별도 status item 표시
- 클릭 시 계정 전체 5시간/7일 퍼센트와 This Mac 기준 오늘/이번 달/최근 세션 상세 표시
- Settings에서 refresh interval 조절 가능

## Notes

- 상단 그래프와 퍼센트는 계정 전체 직접 조회값입니다.
- 아래 `This Mac` 토큰 요약과 최근 세션은 로컬 로그 기준 보조 정보입니다.
