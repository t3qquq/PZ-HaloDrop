# Halo Drop — 좀보이드 B42 공수강하 모드

**모드 ID**: `t3HaloDrop` ·
**표시명**: `[Puppet] Halo Drop - 공수강하` ·
**폴더**: `[Puppet] Halo Drop` ·
**대상**: Build 42 (`versionMin=42.0`), 멀티플레이 우선

배틀그라운드식 공수강하(HALO: High Altitude Low Opening) 모드.
라운드가 시작되면 수송기가 맵 위의 두 점 A → B 를 일직선으로 횡단한다.
탑승한 플레이어는 비행 중 **상호작용 키**(기본 `E`)를 눌러 뛰어내리고,
자유낙하 중 **한 번 더 누르면 낙하산**이 펴져 그때부터 천천히 내려온다.

> 개발 초기 단계 (0.1.0). 핵심 루프(라운드 → 탑승 → 뛰어내리기 → 자유낙하 → 낙하산 → 착지)를
> 구현했고 인게임 검증 전이다. 라운드는 어드민이 월드 우클릭 메뉴로 시작하며,
> 출발점 A 는 시작한 사람 위치, 방향은 무작위다.

---

## 🔁 흐름

| 단위 | 상태 전이 | 누가 진행하나 |
| --- | --- | --- |
| 라운드 | `IDLE → BOARDING → FLYING → ENDED` | 서버 |
| 플레이어 | `ABOARD → FREEFALL → CANOPY → LANDED` | 각 클라가 자기 캐릭터만 |

- 수송기의 "진짜 위치"는 차량이 아니라 **시간으로 정의된 경로**(A, B, 속도, 시작 시각)다.
  모든 클라가 같은 경로식으로 현재 위치를 계산하고, 차량 모델은 그 위치를 보여주는 연출일 뿐이다.
- 고도는 **가상 고도(m)** 로 관리한다. 실제 z 는 상한(`CarryZ`)에 묶어 두고,
  가상 고도가 그 아래로 내려온 뒤에만 실제 z 가 따라 내려간다 (설계 근거는 아래 "제약").
- 경로 끝(B)에 도달할 때까지 안 뛰어내린 플레이어는 강제로 투하한다.

## 🧭 권위 분리

| 일 | 위치 | 이유 |
| --- | --- | --- |
| 라운드 상태·A/B 선정·탑승자 목록 | 서버 | 단일 진실 |
| 수송기 차량 스폰·제거·권한 이전 | 서버 | `addVehicleDebug` / `permanentlyRemove` |
| 수송기 차량 이동 | 파일럿 클라 1명 | 서버 `setWorldTransform` 은 Bullet 이동을 안 한다 |
| 자기 캐릭터 위치·고도·낙하 속도 | 각 클라 | 플레이어 이동·낙하는 소유 클라가 계산 |
| 낙하산 아이템 착용·해제 | 서버 | B42 아이템은 서버 권위 (`sendAddItemToContainer`, `setWornItem`) |
| HUD (고도계·키 안내·지도 경로선) | 각 클라 | 표시 전용 |

## 🗂 디렉터리 구조

```
Contents/mods/[Puppet] Halo Drop/
├── common/                         mod.info, icon.png, poster.png
└── 42/media/
    ├── lua/shared/
    │   ├── HaloDropConfig.lua      상수, 로그 헬퍼, 커맨드 모듈명
    │   ├── HaloDropFlight.lua      경로 계산 (위치·방향·진행률 ← 시각)
    │   └── Translate/{KO,EN}/      IG_UI / Sandbox / ItemName / ContextMenu .json
    ├── lua/server/
    │   └── HaloDropServer.lua      라운드 상태기계, 커맨드 처리, 수송기 스폰·제거·파일럿 교체, 낙하산 지급·회수
    ├── lua/client/
    │   ├── HaloDropClient.lua      서버 커맨드 수신, 비행 정보 캐시, 탑승자 숨기기
    │   ├── HaloDropPilot.lua       파일럿 클라: 매 틱 수송기 setWorldTransform
    │   ├── HaloDropJumper.lua      자기 캐릭터 상태기계, 키 입력, 위치·낙하 속도 제어
    │   ├── HaloDropHUD.lua         고도계, 키 안내, 지도 경로선
    │   └── HaloDropAdminMenu.lua   어드민 라운드 시작·중지 메뉴
    ├── sandbox-options.txt
    ├── scripts/                    수송기 차량, 낙하산 의류 아이템, 사운드
    ├── clothing/                   낙하산 clothingItems + fileGuidTable.xml
    ├── models_X/  textures/  sound/
```

## 📡 커맨드 (모듈명 `HaloDrop` 하나로 통일)

| 방향 | 커맨드 | 내용 |
| --- | --- | --- |
| C → S | `Start` / `Stop` | 어드민 라운드 시작·종료 (종료된 라운드에 한 번 더 `Stop` 이면 즉시 정리) |
| C → S | `Jumped` / `ChuteOpen` / `Landed` | 자기 캐릭터 상태 보고 (로그·낙하산 착용 트리거) |
| C → S | `Cleanup` | 접속 시 남아 있던 낙하산 회수 요청 |
| S → C | `Flight` | 경로 `ax, ay, bx, by, speed`, 서버 기준 경과 ms, 라운드 번호 |
| S → C | `Pilot` | 수송기 vid, 파일럿 onlineID |
| S → C | `Member` | 탑승자 하차 (숨김 해제) |
| S → C | `PlaneGone` | 수송기 차량 제거 |
| S → C | `End` | 경로 끝·어드민 종료 (남은 탑승자 강제 투하) |
| S → C | `Closed` | 라운드 정리 (전원 착지 또는 종료 후 120초) |

## ⚙️ 샌드박스 옵션 (페이지 `HaloDrop`)

| 옵션 | 기본 | 설명 |
| --- | --- | --- |
| `PlaneSpeed` | 16 타일/초 | 수송기 속도. 탑승 중 캐릭터도 이 속도로 움직인다 |
| `PathLength` | 1500 타일 | A–B 거리 |
| `PlaneZ` | 15 층 | 수송기 차량이 나는 실제 층 (퐁듀 수송기와 같음) |
| `CarryZ` | 10 층 | 탑승·자유낙하 중 캐릭터가 머무는 실제 층 상한 |
| `JumpAltitude` | 600 m | 가상 고도 (수송기 고도) |
| `FreefallSpeed` | 40 m/s | 자유낙하 하강 속도 |
| `CanopySpeed` | 6 m/s | 낙하산 하강 속도 (≈ 2.45 층/초) |
| `FreefallSteer` / `CanopySteer` | 12 / 8 타일/초 | 공중 수평 이동 속도 |
| `AutoOpenAltitude` | 100 m | 이 고도에서 낙하산 자동 개방. 0 이면 끔 (안 펴면 추락) |
| `HideCarried` | 켬 | 탑승 중인 다른 플레이어를 각 클라 화면에서 숨긴다 |

## ⚠️ 엔진 제약 (설계에 반영한 것)

- **카메라는 캐릭터 z 를 따라간다** — `PlayerCamera` 가 `calculateCameraZ`(차량 탑승 중이면 차량 높이)로
  화면 중심을 잡는다. 1층 올라갈 때마다 화면 중심의 지면이 x, y 각각 3칸씩 북서로 밀린다.
- **청크는 z 와 무관하게 캐릭터 x, y 중심으로만 로드된다** (`IsoChunkMap.ProcessChunkPos`, 기본 ±52칸).
  → 실제 z 를 높이 올리면 화면에 보이는 지면이 로드 범위를 벗어난다. 그래서 가상 고도를 쓴다.
- **안티치트 속도 검사** — 차량 밖 캐릭터는 1초 평균 20 타일/초 초과 시 위반, 4회 누적 킥
  (`AntiCheatSpeed`, 기본 Kick). 차량 탑승자는 서버 옵션 `SpeedLimit`(기본 70) 기준.
  → 탑승·공중 이동 속도는 20 타일/초 아래로 둔다.
- **낙하 처리** — `IsoGameCharacter.updateFalling` 은 매 틱 `lastFallSpeed` 에 중력(5 층/s²)을 더하는
  순수 등가속도이고, 착지 피해는 충돌 순간 속도로만 정한다 (2.24 층/초 미만 무피해).
  → 하강 속도는 매 틱 `setLastFallSpeed` 로 직접 정한다 (퐁듀 좀비 공습과 같은 방식).

## 🎨 에셋 출처

- **C-17 수송기 모델**: "c17 Globemaster with animation" by pilotcandle5470
  (https://sketchfab.com/runzew68), CC BY 4.0. 퐁듀에서 경량화한 버전을 가져온다.
  상세 출처·변경 내역은 `models_X/vehicles/` 의 LICENSE 파일에 함께 둔다.
- **낙하산 모델**: Parachuting Start 모드(Panopticon, Glytch3r, Sapph, Dante271)의 OpenParachute 메시·텍스처.
  퐁듀 좀비 낙하산과 같은 파일이다. 워크샵 공개 전 원작자 허락 여부 확인 필요.
- **엔진음·낙하산 펼침음**: 퐁듀 수송기 투하 음원 그대로.

## 🔧 개발 참조

| 이름 | URL | 용도 |
| --- | --- | --- |
| PZ 바닐라 소스 | [t3qquq/PZ-Library](https://github.com/t3qquq/PZ-Library) | B42 Lua·Java·스크립트 |
| 퐁듀 모드 | [Project-PongDu/Mod](https://github.com/Project-PongDu/Mod) | 수송기 비행·낙하산 투하 구현 원본 |
