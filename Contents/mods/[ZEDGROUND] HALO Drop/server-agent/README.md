# HaloDropAgent (dedicated server java agent)

Halo Drop 서버 셀 미리 올리기용 자바 에이전트. 전용 서버에만 필요하고 클라에는 필요 없다.
없어도 모드는 정상 동작한다(강하 중 앞쪽 지형 로딩이 늦어 수평 이동이 잠깐 멈출 수 있음).

## 설치 (Windows 전용 서버)
1. 모드 폴더(`...\mods\HALO Drop\`, 이 폴더의 한 단계 위)의 `HaloDrop-ServerSetup.bat` 을 더블클릭한다.
2. `1` (Install / update) 을 입력하고 Enter.
3. 파일 선택 창에서 **서버를 띄울 때 쓰는 .bat 파일**을 고른다.
   기본은 SteamCMD 설치본의 `StartServer64.bat`. 복사해서 이름을 바꾼 파일(예 `API-Test.bat`)도 된다.
4. 이후 그 .bat 으로 평소처럼 서버를 띄운다.

설치가 하는 일: `HaloDropAgent.jar` 를 고른 .bat 과 같은 폴더에 복사하고, 그 .bat 의 java 줄에
`-javaagent:"<그 폴더>\HaloDropAgent.jar"`(전체 경로)를 넣는다. 처음 한 번 `<이름>.bat.halodrop-backup` 백업을 만든다.
전체 경로라서 .bat 이 `cd /d` 로 다른 폴더로 옮겨 가도 된다. 서버를 여러 .bat 으로 띄우면 각각 한 번씩 설치한다.

다시 실행해야 할 때:
- SteamCMD 로 서버를 업데이트한 뒤 (`StartServer64.bat` 이 원본으로 돌아갈 수 있다. 직접 만든 .bat 은 그대로다)
- Halo Drop 모드가 업데이트된 뒤 (복사된 jar 가 옛 버전일 수 있다. 서버 로그에 `agent version ... expects ...` 경고가 뜬다)

제거: 같은 파일에서 `2` (Remove) 후 같은 .bat 을 고른다.

## 확인
`server-console.txt` 에서
- `[HaloDropAgent] premain, java ...` : 에이전트가 떴다
- `[HaloDropAgent] registered HaloDropNative.state/preload` : Lua 에 함수가 들어갔다
- 강하 중 `[HaloDrop] preload: active` / `preload: want=... loaded=...` / 착지 후 `preload: idle`

## 리눅스 서버 / 수동 설치
`HaloDropAgent.jar` 를 서버 폴더에 두고, 서버를 띄우는 java 명령에 `-javaagent:HaloDropAgent.jar` 를
`-cp` 앞에 넣는다(리눅스 `start-server.sh` 는 `ProjectZomboid64.json` 의 `vmArgs` 에 추가).

## 동작
- 게임 클래스를 고치지 않는다. Lua 전역 `HaloDropNative` 표(서버 `HaloDropPreload.lua` 가 만든다)의
  `state` / `preload` / `version` 값(false)을 자바 함수로 바꿔 넣을 뿐이다.
- `HaloDropNative.state(x, y)`   : -2 오류, -1 맵 밖, 0 미요청, 1 로드됨, 2 로드 중
- `HaloDropNative.preload(x, y)` : 타일 (x, y) 가 든 서버 셀(64x64)을 `ServerMap.loadOrKeepRelevent` 로 올리거나 유지
- 쓰는 엔진 멤버(리플렉션): `zombie.Lua.LuaManager.env`, `zombie.network.ServerMap.instance / getMinX / getMinY /
  isInvalidCell / loadOrKeepRelevent / getCell`, `ServerMap$ServerCell.isLoaded`. 이름이 바뀌면 -2 를 돌려주고 로그를 남긴다.

## 빌드 (게임 jar 없이)
Kahlua 인터페이스 3개(`JavaFunction`, `LuaCallFrame`, `KahluaTable`)를 컴파일 전용 스텁으로 만들고
`javac --release 17 -cp <스텁> Agent.java`, 매니페스트 `Premain-Class: halodrop.Agent` 로 jar 를 만든다.
스텁 클래스는 jar 에 넣지 않는다. `Agent.VERSION` 을 바꾸면 `HaloDropConfig.lua` 의 `PRELOAD.AGENT_VERSION` 도 같이 바꾼다.
확인한 빌드: 서버 42.22.2, JRE Zulu 25.0.5.
