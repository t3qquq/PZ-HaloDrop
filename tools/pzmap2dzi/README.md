# 하늘 뷰 타일 만들기 (pzmap2dzi 아이소 렌더)

파서 확인(11-08): cff29546/pzmap2dzi 1.1.17 의 lotpack v1(B42, 256칸 셀) 파서로 B42.21 WorldEd 가 만든
`HALO OilRig/.../OilRig/75_1` 을 읽어 봄 — 정상. 바닐라 42.21 도 같은 포맷.

## 0. 사양
- 디스크: `omit_levels: 5` 라 고운 레벨은 안 남긴다. 최종 수백 MB. 임시로 텍스처 언팩 ~수 GB (E:/pzmap/texture)
- 메모리: 워커 5 × ~0.5GB + 공유 4GB + 캐시 3GB ≈ 10GB. 16GB 머신에선 게임·브라우저 끄고 돌릴 것
- 시간: 기준 머신(8코어 16스레드)에서 B42.6 바닐라 3.6시간 → 6코어는 8~10시간 추정. 끊으면(Ctrl+C) 다시 실행 시 이어서 한다
- Python 3.11 이상 (공유 메모리 캐시). `python --version` 으로 확인

## 1. 설치
```
git clone https://github.com/cff29546/pzmap2dzi E:\pzmap2dzi
cd E:\pzmap2dzi
install_requirements.bat
```

## 2. 설정 복사 (이 폴더 → pzmap2dzi)
```
copy "...\HALO Drop\tools\pzmap2dzi\conf.yaml"        E:\pzmap2dzi\conf\conf.yaml
copy "...\HALO Drop\tools\pzmap2dzi\mod\halodrop.txt" E:\pzmap2dzi\conf\mod\halodrop.txt
copy "...\HALO Drop\tools\pzmap2dzi\run_halodrop.bat" E:\pzmap2dzi\run_halodrop.bat
```
conf.yaml 의 `pz_root`(게임 폴더)·`output_root`(E:/pzmap)·`mod_root` 경로가 네 PC 와 맞는지 확인.

## 3. 렌더
`E:\pzmap2dzi\run_halodrop.bat` (= `python main.py deploy` → `unpack` → `render base`)
- `unpack` 은 텍스처팩을 E:/pzmap/texture 에 푼다 (한 번만)
- `render base` 가 바닐라 + OilRig 를 아이소로 그린다. 출력:
  - `E:/pzmap/html/map_data/base/` (바닐라) — `map_info.json`, `layer0_files/<level>/<tx>_<ty>.jpg`, `layer1~4_files/.../*.webp`
  - `E:/pzmap/html/map_data/mod_maps/OilRig/base/` (리그)
- 중간 확인: `E:\pzmap\html\index.html` 을 브라우저로 열면 뷰어 (고운 레벨은 비어 있으니 멀리서만 보임)
- 렌더가 죽으면 conf.yaml 의 `enable_cache: false` 로 바꿔 재실행 (느려지고 SSD 쓰기 많아짐)

## 4. 타일 자르기
```
python "...\HALO Drop\tools\make_sky_tiles.py" --dzi E:\pzmap\html\map_data\base --overlay E:\pzmap\html\map_data\mod_maps\OilRig\base --out "C:\Users\t3qquq\Zomboid\Workshop\(개인모드) HALO Drop\Contents\mods\HALO Drop\42\media" --px 4,2,1 --layers 0-4
```
- 결과: `42/media/textures/HaloDrop/L4|L2|L1/<c>_<r>.jpg` + `42/media/lua/shared/HaloDropTiles.lua`
- 게임을 켜면 클라 로그 `sky tiles: L1(px=1 pieces=N) L2(...) L4(...)`. 없으면 `sky tiles: HaloDropTiles.lua not present -> vector map fallback`

## 5. 조정
샌드박스 `SkyScale`(칸당 화면 px, 기본 1.5) 로 높이감 조절. 타일이 없는 레벨은 가장 가까운 레벨을 확대/축소해 쓴다.
