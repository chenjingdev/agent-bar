---
pact: 1
topic: Claude Code 계정 바꾸기
status: building
created: 2026-10-27
---
# Claude Code 계정 바꾸기
## 목적
`/login`의 브라우저 과정 없이, AgentBar에서 클릭 한 번으로 Claude Code의 로그인 계정을 바꾼다. 사용자 원문: "그냥 로그인만 편했으면 좋겠음. 내가 수동으로 클릭해도됨"
## 범위
- Claude Code의 기본 로그인 한 칸을 바꾼다. 기본 로그인은 폴더 변수(`CLAUDE_CONFIG_DIR`, `CLAUDE_SECURESTORAGE_CONFIG_DIR`) 없이 부른 Claude Code가 쓰는 로그인이다(Keychain "Claude Code-credentials"). 버튼은 AgentBar의 Claude 계정 창에 둔다. 집 Mac에서 만들고 확인한다. 회사 Mac은 설치한 뒤 사용자가 눌러 확인한다 [AI 가정].
## 하지 않는 것
- 세션마다 다른 계정, 자동 전환, 열린 세션 다시 시작. 사용량 로그인을 AgentBar 파일에 두는 지금 방식의 약관 검토는 따로 다룬다.
- 다음 판 후보: 직전 계정으로 되돌리기, 열린 세션 수 표시, 메뉴 막대에 계정 표시, 한도 90% 알림, Codex 계정 바꾸기
## 기능
- F1 Claude 계정 창 맨 위의 "Use in Claude Code" 버튼을 한 번 누르면 Claude Code가 그 계정으로 바뀐다. 지금 Claude Code가 쓰는 계정의 창에는 버튼 대신 "In Claude Code"가 보인다 [사용자]
  - 케이스: 그 계정의 빌려줄 로그인이 없거나 만료됨 → 이유를 보이고, 브라우저 로그인을 한 번 한 뒤 바뀐다(기다리는 동안 Cancel, 5분이 지나면 끝냄)
  - 케이스: 바꾸기 실패 → 계정 창에 이유를 한 줄로 보인다
- F2 한 번에 한 계정이다. 바꾸면 열린 세션까지 모든 Claude Code 세션이 새 계정을 쓴다 [사용자]
  - 케이스: 바꾼 뒤 → 결과 줄에 "Claude Code now uses …"와 "Open sessions switch within 30 s. Remote Control disconnects."를 보인다
- F3 다른 계정으로 바꾸면 그때까지 Claude Code에 있던 로그인을 AgentBar가 그 계정의 빌려줄 로그인으로 돌려받는다. 그래서 그 계정으로 돌아갈 때도 브라우저 로그인이 없다 [사용자: 범위 동의]
  - 케이스: AgentBar가 만들지 않은 로그인(처음 누를 때, 터미널 `/login` 뒤) → 그 계정이 AgentBar에 있으면 그대로 돌려받는다
  - 케이스: Claude Code에 있던 계정이 AgentBar에 없음 → 계정 창 안의 확인 줄(Cancel 포함)로 "이 로그인은 Claude Code에서 사라진다"고 먼저 묻는다
- F4 빌려줄 로그인은 사용량 로그인과 따로 계정마다 하나씩 둔다. 바꾸기에 문제가 생겨도 사용량 표시는 그대로다 — 로그인을 옮기면 토큰이 바뀌어서 한 로그인을 둘이 나눠 쓸 수 없다 [AI 가정]
<details><summary>그 밖의 기능 12개</summary>

- F5 바꾸던 중 AgentBar가 꺼지면 다음 실행 때 마저 끝내거나 되돌린다 [사용자: 범위 동의]
- F6 Claude Code가 없으면 버튼을 숨긴다 [사용자: 범위 동의]
- F7 바꾸기마다 `~/.agentbar/multi-account-v1/logs/claude-code-switch.log`에 시각, 계정 이름, 단계, 결과를 남긴다. 형식은 `limit-resets.log`를 따른다(한 줄에 JSON 하나, 약 1MB에서 `.1`로 넘김, 토큰 같은 값은 가림). 결과 줄 옆에 "Open Log"를 둔다 [사용자: 범위 동의]
- F8 바꾸는 동안에는 모든 계정 창의 바꾸기 버튼과 관련된 두 계정의 Delete, Reconnect를 막고 진행 중임을 보인다 — 두 작업이 겹치면 로그인이 꼬인다 [AI 가정]
- F9 Claude Code가 2.1.309보다 옛 판이면 버튼을 막고 이유를 보인다. 위쪽 한도는 두지 않는다 — Claude Code는 며칠마다 자동으로 판이 오른다. 새 판에서 동작이 달라지면 R9 확인이 실패로 잡는다 [AI 가정]
- F10 사용량 로그인이 "Sign-in required"인 계정은 버튼을 막고 그 상태 줄을 이유로 보인다. 빌려줄 로그인만 없거나 만료된 계정은 F1 첫 케이스대로 한다 — 스케치 A의 셋째 창 [AI 가정]
- F11 앞 계정 로그인을 돌려받지 못할 때: 그 로그인이 이미 무효(400, 401, invalid_grant)면 바꾸기를 이어 가고 "그 계정은 다음에 브라우저 로그인이 필요하다"를 결과 줄에 더한다. 네트워크 오류, 시간 초과, 잠금 실패면 아무것도 바꾸지 않고 멈춘다 — 무효 로그인 때문에 영영 못 바꾸는 일을 막는다 [AI 가정]
- F12 처음 빌려줄 때 브라우저에서 다른 계정으로 로그인하면 그 로그인을 버리고 "Signed in as a different account"를 보인다 — 엉뚱한 계정을 빌려주지 않는다 [AI 가정]
- F13 AgentBar에서 계정을 지우면 그 계정의 빌려줄 로그인도 이 Mac에서 지운다. 삭제 확인 문구에 이것을 더한다. Claude Code가 지금 그 계정을 쓰면 Claude Code는 그대로 둔다 — 아무도 관리하지 않는 로그인을 남기지 않는다 [AI 가정]
- F14 "In Claude Code" 표시는 Claude Code의 실제 로그인을 따른다. AgentBar에 없는 계정이거나 로그아웃 상태면 어느 창에도 표시가 없다 — 터미널에서 바꾼 것도 맞게 보인다 [AI 가정]
- F15 사용자가 Claude Code에서 직접 `/login`이나 `/logout`을 하면 막지 않는다. 그때 Claude Code에 있던 계정은 다음에 브라우저 로그인을 한 번 한다 — Claude Code의 명령이 먼저다 [AI 가정]
- F16 결과 줄은 계정 창을 닫았다 열어도 보이고, 그 창을 한 번 더 닫으면 지운다 — 계정 창은 바깥을 누르면 닫힌다 [AI 가정]

</details>

## 공통 규칙
- R1 Claude Code에 로그인을 넣는 일은 Claude Code의 공식 명령(`claude auth login`에 refresh token을 넘기는 방식)으로만 한다. AgentBar는 Claude Code의 로그인 항목을 직접 쓰지 않는다 — 예전 세 번의 시도는 직접 쓰다가 낡은 사본과 Keychain 허용 창 때문에 실패했다 [AI 가정]
- R2 바꾸기 중에 Keychain 허용 창이 한 번도 뜨지 않는다. 사용자 원문: "키체인은 왜 계속 물어보는거야?" [사용자: 2026-09-20]
- R3 AI는 시험할 때 실제 Claude Code 로그인을 바꾸지 않는다. 따로 떼어 둔 폴더와 버릴 로그인으로 시험하고, 실제 바꾸기는 사용자가 직접 눌러 본다 — 실제 로그인을 바꾸면 지금 이 대화와 열린 세션의 계정도 바뀐다 [AI 가정]
<details><summary>그 밖의 AI 가정 11개</summary>

- R4 계정이 같은지는 계정 UUID와 조직 UUID 쌍으로 판단한다. 등록된 계정의 계정 UUID는 그 계정 로그인 폴더의 `.claude.json`(`oauthAccount`)에서 한 번 채우고, 조직 UUID가 등록된 값과 같을 때만 채운다. 빌려줄 로그인과 기본 로그인도 각자의 `.claude.json`에서 같은 쌍을 읽는다 — 지금 등록된 Claude 계정에는 계정 UUID가 없고, `claude auth status --json`도 내지 않는다 [AI 가정]
- R5 로그인을 넣고 빼는 일은 Claude Code의 공식 명령에 맡겨 그 명령이 자기 잠금을 잡게 한다. AgentBar는 자기 바꾸기 작업을 한 번에 하나만 한다. 앞 계정 토큰은 기본 칸이 새 계정으로 바뀐 뒤에 빼내 다시 빌려준다. 그 사이 열린 세션이 앞 토큰을 이미 돌렸으면 빼내기는 실패로 끝나고 F11이 받는다 — 한 토큰을 둘이 쓰면 로그인이 통째로 폐기될 수 있고(clauth #52), CLI의 사적 잠금 형식을 흉내 내면 판이 바뀔 때 깨진다 [AI 가정]
- R6 옮긴 뒤 남은 낡은 사본은 이 Mac에서만 지운다. 로그아웃은 쓰지 않는다. 지우기와 지운 뒤 확인은 계정 삭제 코드(`AccountFiles`)와 같은 방식으로 한다 — 서버 폐기가 옮겨 간 새 로그인까지 끊을 수 있다 [AI 가정]
- R7 빌려줄 로그인은 `~/.agentbar/multi-account-v1/lend/` 아래 계정 UUID 폴더(0700)에 Claude Code가 저장한다. 두 폴더 변수를 이 폴더로 준다. 사용량 로그인 폴더와 같이 쓰지 않고, 이 폴더에는 `.credentials.json`을 만들지 않는다 — AgentBar가 토큰을 따로 보관하지 않는다. 폴더가 같으면 Keychain 이름도 겹친다 [AI 가정]
- R8 Claude Code는 AgentBar의 최소 환경(`ProviderCLI.processEnvironment()`)으로 부르고, 필요한 변수만 더한다. 기본 로그인에 쓸 때는 폴더 변수를 주지 않는다 — 물려받은 변수가 엉뚱한 폴더나 계정에 쓰지 않게 한다 [AI 가정]
- R9 바꾼 뒤 Claude Code 로그인을 다시 읽어 계정이 맞는지 확인한다. 다르면 실패로 알린다 — 확인 없이 성공이라고 하지 않는다 [AI 가정]
- R10 Claude Code의 Keychain 항목은 `/usr/bin/security`로만 읽는다. AgentBar가 Security API로 직접 읽지 않는다 — Claude Code가 만든 항목은 이 프로그램을 믿는다 [AI 가정]
- R11 시험 코드는 대상 칸을 바깥에서 받는다. 시험할 때는 두 폴더 변수를 늘 시험 폴더로 준다 — 변수 없이 부르면 실제 기본 로그인에 쓴다 [AI 가정]
- R12 기존 규칙 "AgentBar never imports or follows the login used by Claude"(README 20, 41, 45, 73줄)는 사용량 읽기에 그대로 둔다. "Use in Claude Code"만 예외로 README에 적는다. 기본 로그인을 건드리지 않는지 보는 기존 시험도 그대로 둔다 [AI 가정]
- R13 토큰 값은 화면, 로그, 오류 메시지 어디에도 남기지 않는다 — 시크릿이다 [AI 가정]
- R14 새 문구는 앱처럼 영어로 쓴다(예: "Use in Claude Code", "In Claude Code") — 앱의 다른 문구가 모두 영어다 [AI 가정]

</details>

## 구조 판정
- A안: 각 Claude 계정 창 맨 위에 "Use in Claude Code" 버튼을 두고, 결과는 그 아래 한 줄로 보인다. 사용자가 추천안 A에 "ㄱㄱ"로 답했다. 스케치: `.pact/claude-code-계정-바꾸기/sketches/A.html`
## 확인 필요
- 확인함(10-28): 같은 계정에 로그인을 하나 더 두어도 사용량 로그인은 끊기지 않는다. Claude(회사) 사용량 로그인이 10-27 00:10 뒤로 다시 로그인하지 않고 00:12 무렵을 지나 16:18까지 갱신됐다. F4는 그대로다.
- 확인함(10-28): 따로 떼어 둔 폴더에서 chenjingdev와 회사 계정으로 한 실험이 9개 확인을 모두 넘었다. 허용 창 없음, 열린 세션 401 없음, 열린 세션이 옛 계정 정보를 되쓰지 않음, 돌려받은 로그인 생존, AgentBar가 만들지 않은 로그인 돌려받기를 확인했다. 실제 기본 로그인의 Keychain 항목은 `/usr/bin/security`를 믿고 파티션이 `apple-tool:`이다. refresh token으로 넣은 로그인도 브라우저 로그인처럼 8시간 토큰을 받는다.
## 결정 기록
- Ruling: 앞 계정 토큰 빼내기를 CLI 내부 잠금(`.oauth_refresh.lock`) 재구현에서 공식 명령에 맡기는 방식으로 바꿨다(R5, F11) — CLI의 사적 잠금 형식은 Claude Code 판이 바뀌면 깨지고, 공식 명령이 이미 자기 잠금을 잡는다 — 틀리면 바꾸는 중 열린 세션의 토큰 갱신과 겹쳐 앞 계정 로그인이 폐기될 수 있다
- Ruling: F11의 "아무것도 바꾸지 않고 멈춘다"는 새 계정을 기본 칸에 넣는 단계의 실패에만 쓴다. 앞 계정 돌려받기가 네트워크 오류나 시간 초과로 실패하면 메모리의 토큰으로 두 번 더 해 보고, 그래도 안 되면 바꾸기는 그대로 두고 결과 줄에 그 계정은 다음에 브라우저 로그인이 필요하다고 더한다 — R5대로 기본 칸을 먼저 바꾸므로 돌려받을 때는 이미 바뀐 뒤다 — 틀리면 네트워크가 불안정할 때 앞 계정 로그인을 브라우저로 한 번 더 받아야 한다
- Ruling: 빌려줄 로그인 폴더 이름은 AgentBar 계정 id로 한다(R7의 "계정 UUID") — 같은 Claude 계정이 두 조직에 있으면 Claude 계정 UUID만으로는 폴더가 겹친다 — 틀리면 AgentBar에서 계정을 지우고 다시 만들 때 빌려줄 로그인을 다시 받아야 한다
- Ruling: 바꾸던 중 AgentBar가 꺼질 때(F5)를 위한 기록에는 토큰 없이 대상, 앞 계정, 단계만 남긴다. 기본 칸을 바꾼 뒤 꺼졌으면 다음 실행 때 남은 정리를 끝내고, 메모리에만 있던 앞 계정 토큰은 잃으므로 그 계정은 다음에 브라우저 로그인이 필요하다고 알린다 — R7에 따라 AgentBar는 토큰을 파일에 두지 않는다 — 틀리면 그 드문 경우 앞 계정 로그인을 브라우저로 한 번 더 받아야 한다
