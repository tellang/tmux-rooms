[English](README.md) | 한국어

# Tmux Rooms

tmux 세션을 한눈에 보고 클릭 한 번으로 원하는 세션에 들어간다.

Tmux Rooms는 iTerm2 안에서 tmux를 쓰는 사람을 위한 macOS 메뉴바 앱이다.
같은 목록을 터미널에서 다루는 명령줄 도구 `tmr`도 함께 들어 있다.

## 만든 이유

iTerm2에서 tmux 세션을 여러 개 띄워 두고 일한다. tmux는 세션을 끝까지 살려 두는
데 능하다. 가끔은 지나칠 만큼. 일이 끝나도 세션은 남는다. 분리된 세션은 하나둘
쌓이고 런처가 붙인 `agent-20260901023710` 같은 이름으로는 안에 뭐가 있는지 알
수 없다. `tmux ls`, `attach -t`, `kill-session`으로 정리할 수는 있지만 명령을
기억해야 하고 세션마다 하나씩 처리해야 한다.

Tmux Rooms는 tmux 서버 전체를 방 목록으로 보여 준다. 방 하나가 tmux 세션
하나다. 방마다 안에서 무엇이 돌고 있는지, 클라이언트가 몇 개 붙어 있는지,
마지막으로 언제 썼는지가 보인다.

방에서 Claude Code, Codex, Antigravity가 돌고 있으면 그 에이전트가 붙인 세션
이름이 제목이 된다. `agent-20260901023710`이 "로그인 리다이렉트 수정"으로 보이는
식이다. tmux 이름은 한 줄 아래에 그대로 남는다.

목록에서 할 수 있는 일은 이렇다.

- 방 열기. 그 방을 보여 주는 iTerm2 창이 이미 있으면 그 창을 앞으로 가져온다.
  없으면 창을 하나 열고 다음에도 그 창을 다시 쓴다. Open을 두 번 눌러도
  클라이언트가 두 개로 늘지 않는다.
- 읽기 전용 미리보기. `READ ONLY`라고 표시된 iTerm2 탭 하나를 계속 다시 쓴다.
- 창 복제. 두 번째 인터랙티브 클라이언트가 정말 필요할 때 쓴다.
- 방 삭제. 고른 세션이 여전히 같은 세션인지 다시 확인한 뒤에 지운다.

Tmux Rooms는 tmux 세션을 스스로 만들지 않는다. 사용자가 고른 세션 말고는
건드리지도 않는다.

`tmr`을 쓰면 같은 목록을 어느 터미널에서나 볼 수 있다.

![tmr로 방 고르기](docs/images/tmr.gif)

## 요구 사항

- macOS 15 이상의 Apple Silicon Mac
- Homebrew로 설치한 tmux 3.6b 이상, 경로는 `/opt/homebrew/bin/tmux`
- 메뉴바 앱을 쓰려면 iTerm2. macOS가 물으면 Tmux Rooms의 iTerm2 제어를
  허용한다. iTerm2의 Settings > General > Magic > Enable Python API도 켠다.
  `tmr`은 터미널 종류를 가리지 않는다.
- 빌드하려면 Xcode 16 이상. XcodeGen 2.46은 `project.yml`을 고칠 때만 필요하다.

Tmux Rooms는 기본 tmux 서버, 즉 `$TMUX_TMPDIR` 또는 `/tmp` 아래의 `default`
소켓만 읽는다. `-L`이나 `-S`로 띄운 서버는 목록에 나오지 않는다.

## 설치

아직 미리 빌드한 바이너리는 없어서 소스에서 빌드한다.

```bash
git clone https://github.com/tellang/tmux-rooms.git
cd tmux-rooms
scripts/install-cli.sh               # ~/.local/bin에 tmr과 tmuxrooms 설치
scripts/install-local.sh --ad-hoc    # /Applications에 Tmux Rooms.app 설치
```

`~/.local/bin`을 `PATH`에 넣어 둔다.

`--ad-hoc`은 인증서 없이 앱에 서명한다. 써 보기에는 충분하다. 다만 macOS는
iTerm2 제어 권한을 서명에 묶어 두기 때문에, 다시 빌드할 때마다 권한을 또 물을
수 있다. 권한을 유지하려면 키체인 접근에서 인증서를 만든다(인증서 지원 > 인증서
생성, 인증서 유형은 코드 서명). 그다음 `--identity "<인증서 이름>"`으로 설치한다.
신뢰 설정은 바꾸지 않아도 된다. 두 옵션을 모두 생략하면 스크립트는
`Tmux Rooms Local Development`라는 이름의 인증서를 찾는다.

그 밖의 옵션은 다음과 같다.

```bash
scripts/install-local.sh --dry-run --non-interactive   # 빌드와 검증만 하고 아무것도 바꾸지 않음
scripts/install-local.sh --login                       # 로그인할 때 앱 자동 실행
scripts/install-local.sh --no-login                    # 자동 실행 해제
scripts/install-local.sh --destination ~/Applications/"Tmux Rooms.app"
```

앱이 실행 중이면 설치 스크립트가 앱을 종료하고 새 빌드로 바꾼 뒤 다시 띄운다.
`--login`은 `~/Library/LaunchAgents/com.tellang.tmux-rooms.plist`에
LaunchAgent를 만든다.

## tmr 사용법

```bash
tmr                    # 모든 방 중에서 고르기
tmr --here             # 현재 디렉터리에 pane이 있는 방만
tmr billing            # 제목, tmux 이름, 에이전트, 경로에 billing이 들어간 방
tmr -r billing         # 읽기 전용으로 붙기
tmr ls                 # 붙지 않고 목록만 출력
tmr ls --here --json   # 스크립트용 JSON
tmr -help
```

목록에서 위아래 화살표(또는 `k`, `j`)로 강조 표시를 옮긴다. 끝에 닿으면 반대쪽으로
넘어간다. Home과 End는 처음과 끝으로 간다. Enter를 누르면 붙는다. 숫자를 누르면
그 방에 바로 붙는다. 방이 열 개 이상이면 숫자 두 개를 이어서 누르거나 숫자 하나를
누르고 Enter를 친다. `q`, Esc, Ctrl-C는 취소다. 처음에는 현재 디렉터리에 pane이 있는
첫 방이 강조된다. 목록은 stderr에 그리므로 stdout은 깨끗하게 남는다.

맞는 방이 하나뿐이면 `tmr`은 묻지 않고 바로 붙는다. 검색어는 방의 제목, tmux
이름, 에이전트, pane 경로와 대소문자 구분 없이 비교한다. tmux 이름이나 세션 ID가
검색어와 정확히 같으면 부분 일치보다 우선한다.

붙는 동작은 `tmux attach-session`과 같다. 클라이언트가 하나 더 생기므로, 다른
터미널에서 이미 열려 있던 방에는 화면 하나를 함께 쓰는 클라이언트가 두 개가 된다.
tmux 안에서 실행하면 현재 클라이언트를 그 방으로 전환한다. 이때 `-r`은 거부한다.
읽기 전용으로 보려면 tmux 안에 tmux를 또 띄워야 하기 때문이다.

`claude`, `codex`, `agy`가 도는 방은 AGENT 열에 에이전트 이름이 주황, 흰색,
파랑으로 표시된다. 색을 쓰려면 `COLORTERM=truecolor`나 `256color` 계열 `TERM`이
필요하다. `NO_COLOR`를 설정하면 색을 끈다.

`ls`는 `list`로, `attach`는 `a`로도 쓸 수 있다. 짧은 이름이 `tr`이 아니라
`tmr`인 것은 `tr`이 유닉스 기본 명령이기 때문이다.

| 종료 코드 | 의미 |
|---|---|
| 0 | 성공. `tmr ls --json`은 맞는 방이 없으면 `[]`를 출력하고 0으로 끝난다. |
| 1 | 맞는 방이 없거나, 취소했거나, 여러 방이 맞는데 고를 터미널이 없음 |
| 2 | 사용법 오류 |
| 3 | tmux를 읽지 못함. 예를 들어 버전이 3.6b보다 낮은 경우 |
| 126 | tmux를 실행하지 못함 |

## JSON 출력

`tmr ls --json`은 방의 배열을 출력한다.

| 방 필드 | 내용 |
|---|---|
| `id` | tmux 세션 ID. 예: `$3` |
| `name` | tmux 세션 이름 |
| `title` | 목록에 보이는 제목 |
| `agent` | `claude`, `codex`, `agy`, `null` 중 하나 |
| `paths` | pane들의 작업 디렉터리 |
| `interactiveClients`, `readOnlyClients` | 붙어 있는 클라이언트 수 |
| `lastActivity` | 마지막 활동 시각. 초 단위 Unix 시간 |
| `panes` | 살아 있는 pane마다 하나씩 |

| pane 필드 | 내용 |
|---|---|
| `paneId` | tmux pane ID. 예: `%12`. pane이 살아 있는 동안 바뀌지 않으므로 pane을 가리킬 때는 이 값을 쓴다. |
| `target` | `session:window.pane` 형식. 예: `work:0.1`. `tmux -t`에 넣기 편하지만, 창 번호가 다시 매겨지거나 pane이 옮겨지면 다른 곳을 가리킨다. |
| `active` | 활성 pane인지 여부 |
| `path` | 작업 디렉터리 |
| `agent` | `claude`, `codex`, `agy`, `null` 중 하나 |
| `pid` | 에이전트의 pid. 에이전트가 없으면 pane의 pid |
| `sessionId`, `name` | 에이전트의 세션 ID와 이름. 없으면 `null` |
| `state` | `busy`, `idle`, `unknown` 중 하나 |

Claude의 상태는 Claude의 세션 레지스트리에서 읽는다. Codex는 pane 화면 아래쪽을
읽는다. `esc to interrupt`가 보이면 busy, 아무것도 돌지 않고 입력 프롬프트가
보이면 idle이다. `agy`는 busy 아니면 unknown이다. 확인된 idle 표시가 없어서다.
그 밖에는 모두 `unknown`이다. 화면은 `ls --json`일 때만 읽는다. 프로세스 이름만
보고 상태를 짐작하지는 않는다.

## 에이전트 이름을 가져오는 곳

Tmux Rooms는 아래 파일을 읽기만 한다. 어디에도 이름이 없으면 방은 `Claude`,
`Codex`, `Antigravity`로 표시된다. 에이전트가 없는 방은 tmux 이름을 그대로 쓴다.

- Claude Code는 `~/.claude/sessions/<pid>.json`을 남긴다(`CLAUDE_CONFIG_DIR`가
  설정돼 있으면 그 아래). `/rename`으로 정한 이름과 세션이 도는 pane이 여기
  기록된다. 이름을 바꾼 적이 없는 세션은 대화 기록의 제목을 쓴다.
- Codex 스레드 이름은 `$CODEX_HOME/session_index.jsonl`에서 가져온다(기본값
  `~/.codex`). 이름을 여러 번 바꿨으면 마지막 이름을 쓴다. 어떤 pane이 어떤
  스레드를 돌리는지는 다음 순서로 찾는다.
  1. triflux 런처가 쓰는 레지스트리
     `$XDG_STATE_HOME/triflux/codex-sessions/<pid>.json`(기본값 `~/.local/state`)
  2. `tmr`에서만, codex 프로세스가 열어 둔 rollout 파일. `lsof`로 찾는다.
  3. oh-my-codex가 pane 디렉터리나 그 상위 디렉터리(홈 디렉터리까지)에 쓰는
     `.omx/state/session.json`
- Antigravity는 `agy` 명령으로 알아보며, 이름을 가져올 곳은 없다.

기록은 두 조건을 모두 만족할 때만 인정한다. 기록의 pane이 살아 있는 pane과 같아야
한다. pid는 그 pane의 프로세스이거나 같은 에이전트를 돌리는 하위 프로세스여야 한다. 끝난 세션이 남긴 파일로는 방
이름이 붙지 않는다.

이 파일들은 다른 도구의 것이고 형식이 안정적이라고 문서화돼 있지 않다. 그 도구가
형식을 바꾸면 Tmux Rooms가 따라 고칠 때까지 그쪽 이름은 표시되지 않는다.

## 파일과 권한

앱은 macOS에 iTerm2 제어 권한을 요청한다. 디스크에는 두 가지를 쓴다.

- `~/Library/Application Support/Tmux Rooms/ManagedClients/`: 앱이 연 iTerm2
  클라이언트 기록. 앱이 비정상 종료돼도 다시 찾을 수 있게 남긴다.
- `~/Library/Application Support/iTerm2/Scripts/com.tellang.tmuxrooms-title.py`:
  `READ ONLY` 탭 제목을 붙이는 iTerm2 스크립트

iTerm2 Python API를 켜면 이 Mac의 다른 프로그램도 iTerm2를 조작할 수 있다. 여러
사람이 쓰는 Mac이라면 이 점을 염두에 둔다.

## 문제 해결

앱 로그는 이렇게 본다.

```bash
log show --last 30m --predicate 'subsystem == "com.tellang.tmuxrooms"' --style compact
```

- 미리보기 탭에 `READ ONLY` 제목이 없다: iTerm2 Python API가 꺼져 있다. 켜고
  다시 Preview를 누른다.
- `tmr`이 3으로 끝난다: tmux가 3.6b보다 낮거나 `/opt/homebrew/bin/tmux`에 없다.
- 목록에 없는 서버가 있다: `-L`이나 `-S`로 띄운 서버다.
- 다시 빌드할 때마다 iTerm2 권한을 묻는다: 설치 절에 적은 대로 인증서로 설치한다.

## 제거

```bash
scripts/uninstall.sh --dry-run   # 지울 대상만 출력
scripts/uninstall.sh             # 확인을 받고 지움. --yes를 주면 묻지 않음
```

스크립트는 앱을 종료한 뒤 앱, `tmuxrooms`, `tmr` 링크, 로그인 LaunchAgent, 앱의
상태 폴더, iTerm2 스크립트를 지운다. tmux 세션은 건드리지 않는다.

## 빌드와 테스트

```bash
xcodegen generate   # project.yml을 고친 뒤에만
xcodebuild -project TmuxRooms.xcodeproj -scheme TmuxRoomsUnitTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

UI 테스트와 통합 테스트는 [docs/testing.md](docs/testing.md)에 정리했다. UI
테스트는 실제 화면을 조작한다. 앱이 자기가 연 iTerm2 클라이언트를 어떻게
관리하는지는 [docs/design/managed-clients.md](docs/design/managed-clients.md)에 있다.

## 현재 상태

0.x 버전이다. 한 사람이 Mac 한 대에서 쓰는 용도로 만들었다. 지원하는 터미널은
iTerm2뿐이다. 앞으로 할 일은 [TODOS.md](TODOS.md)에 있다.

## 기여, 보안, 라이선스

[CONTRIBUTING.md](CONTRIBUTING.md)와 [SECURITY.md](SECURITY.md)를 본다. Tmux
Rooms는 [MIT 라이선스](LICENSE)로 배포한다.

Tmux Rooms는 Anthropic, OpenAI, Google, tmux 프로젝트, iTerm2 프로젝트와 관계가
없다.
