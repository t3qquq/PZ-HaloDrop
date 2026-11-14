# HaloDropAgent (dedicated server java agent)

Halo Drop 서버 셀 미리 올리기용 자바 에이전트. 클라에는 필요 없다.

## 설치
1. `HaloDropAgent.jar` 를 전용 서버 폴더(`StartServer64.bat` 가 있는 곳)에 둔다.
2. `StartServer64.bat` 의 java 실행 줄에서 `java.exe"` 바로 뒤에 `-javaagent:HaloDropAgent.jar` 를 넣는다.
3. 서버를 띄우고 `server-console.txt` 에서 확인한다.
   - `[HaloDropAgent] premain, java ...` : 에이전트가 떴다
   - `[HaloDropAgent] registered HaloDropNative.state/preload` : Lua 에 함수가 들어갔다
   - 라운드 중 `[HaloDrop] preload: native agent version 1 active` / `preload: want=... loaded=...`

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
스텁 클래스는 jar 에 넣지 않는다. 확인한 빌드: 서버 42.22.2, JRE Zulu 25.0.5.
