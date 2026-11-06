# 하늘 뷰 타일 만들기 (pzmap2dzi 아이소 렌더)

1. `git clone https://github.com/blind-coder/pzmap2dzi` (B42 지원 포크). `install_requirements.bat` 실행 (Python 3.8+, Pillow 등)
2. 이 폴더의 `conf.yaml` → pzmap2dzi `conf/conf.yaml`, `vanilla_b42.txt` → `conf/vanilla.txt`, `mod/halodrop.txt` → `conf/mod/halodrop.txt` 로 복사(덮어쓰기)
3. pzmap2dzi 폴더에서 `python main.py copy` → `python main.py unpack` → `python main.py render base`
   - 풀해상도 렌더를 메모리에서 하고 고운 5레벨은 안 쓴다. 6코어 기준 수 시간. 중간에 끊으면 다시 실행 시 이어서 한다
   - 출력: `E:/pzmap/html/base/`(바닐라), `E:/pzmap/html/mod_maps/OilRig/base/`(리그). 각 폴더에 `map_info.json`
4. 타일 자르기:
   `python "...\HALO Drop\tools\make_sky_tiles.py" --dzi E:\pzmap\html\base --overlay E:\pzmap\html\mod_maps\OilRig\base --out "C:\Users\t3qquq\Zomboid\Workshop\(개인모드) HALO Drop\Contents\mods\HALO Drop\42\media" --px 4,2,1 --layers 0-5`
   - 결과: `42/media/textures/HaloDrop/L4|L2|L1/<c>_<r>.jpg` + `42/media/lua/shared/HaloDropTiles.lua`
   - 게임을 켜면 클라 로그 `sky tiles: L1(px=1 pieces=N) L2(...) L4(...)`. 없으면 `sky tiles: HaloDropTiles.lua not present -> vector map fallback`
5. 샌드박스 `SkyScale`(칸당 화면 px, 기본 1.5) 로 높이감 조절. 타일이 없는 레벨은 가장 가까운 레벨을 확대/축소해 쓴다
