#!/usr/bin/env python3
r"""
Halo Drop 하늘 뷰 타일 생성기 — pzmap2dzi 아이소 렌더 출력을 모드 타일로 자른다.

입력: pzmap2dzi 출력 폴더(base_map 렌더). 구조
    <dzi>/map_info.json            x0, y0, sqr(=128), w, h, skip
    <dzi>/layer0_files/<level>/<tx>_<ty>.jpg   지상층 (1024px 타일)
    <dzi>/layer<k>_files/<level>/<tx>_<ty>.webp  k층 (투명 배경)
  오버레이 모드 맵(오일리그)은 같은 구조의 별도 폴더. 자기 x0/y0 로 위치를 맞춰 합성한다.

출력: <mod>/42/media/textures/HaloDrop/L<px>/<c>_<r>.jpg  +  <mod>/42/media/lua/shared/HaloDropTiles.lua

투영 (pzmap2dzi html/pzmap/map.js cell2pixel 와 같음):
    px = x0 + (wx - wy) * sqr / 2,  py = y0 + (wx + wy) * sqr / 4    (base 해상도, sqr = 128)
  레벨 n (base 에서 n 번 반으로 줄인 것) 은 전부 2^-n 배.
  k층 타일은 뷰어가 1.5 * sqr * k 픽셀만큼 위로 올려 그린다(map.js yshift) -> 합성할 때 같은 오프셋을 쓴다.

사용 예 (PowerShell):
    python make_sky_tiles.py --dzi E:\pzmap\html\map_data\default --overlay E:\pzmap\html\map_data\OilRig ^
        --out "C:\Users\t3qquq\Zomboid\Workshop\(개인모드) HALO Drop\Contents\mods\HALO Drop\42\media" --px 4,2,1 --layers 0-4
  (pzmap2dzi 출력 폴더 이름은 conf.yaml 의 output_path 와 map 이름에 따라 다르다. map_info.json 이 있는 폴더를 준다)
"""
import argparse, json, math, os, re, sys
from PIL import Image

TILE = 1024
Image.MAX_IMAGE_PIXELS = None


def load_map(path):
    info = json.load(open(os.path.join(path, 'map_info.json'), encoding='utf-8'))
    levels = {}
    for name in os.listdir(path):
        m = re.match(r'layer(-?\d+)_files$', name)
        if not m:
            continue
        layer = int(m.group(1))
        lv = {}
        for lvname in os.listdir(os.path.join(path, name)):
            if lvname.isdigit():
                lv[int(lvname)] = os.path.join(path, name, lvname)
        levels[layer] = lv
    if 0 not in levels or not levels[0]:
        sys.exit('no layer0_files/<level> in ' + path)
    top = max(levels[0].keys())  # 가장 고운 레벨 번호 (skip 된 레벨은 폴더가 비어 있을 수 있음)
    return {'path': path, 'info': info, 'layers': levels, 'maxLevel': top}


def level_tiles(dirpath):
    out = {}
    if not os.path.isdir(dirpath):
        return out
    for f in os.listdir(dirpath):
        m = re.match(r'(\d+)_(\d+)\.(jpg|jpeg|png|webp)$', f)
        if m:
            out[(int(m.group(1)), int(m.group(2)))] = os.path.join(dirpath, f)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dzi', required=True, help='pzmap2dzi base map output (map_info.json 폴더)')
    ap.add_argument('--overlay', action='append', default=[], help='mod map output folder (여러 번 가능)')
    ap.add_argument('--out', required=True, help='HALO Drop/42/media 폴더')
    ap.add_argument('--px', default='4,2,1', help='만들 레벨의 칸당 픽셀 (base 128 의 1/2^n 만 가능)')
    ap.add_argument('--layers', default='0-4', help='합성할 층 범위, 예 0-4')
    ap.add_argument('--quality', type=int, default=85)
    args = ap.parse_args()

    base = load_map(args.dzi)
    overlays = [load_map(p) for p in args.overlay]
    sqr = base['info']['sqr']
    bx0, by0 = base['info']['x0'], base['info']['y0']
    lmin, lmax = (int(v) for v in args.layers.split('-'))
    want = [float(v) for v in args.px.split(',')]

    # pzmap2dzi 의 레벨 번호: 0 = 1x1 px ... base = 128 px/칸. 레벨 폴더는 skip 된 것도 만들어지므로
    # 폴더 이름이 아니라 map_info 의 w(skip 적용 후 가장 고운 폭) 와 skip 으로 base 레벨 번호를 역산한다.
    def base_level_of(mp):
        skip = mp['info'].get('skip', 0)
        w = mp['info']['w'] * (2 ** skip)
        n = 1
        while w > 1:
            w = (w + 1) // 2
            n += 1
        return n - 1
    base_level = base_level_of(base)

    lua_levels = []
    for px in want:
        n = round(math.log2(sqr / px))
        if abs(sqr / (2 ** n) - px) > 1e-6:
            sys.exit('px %g is not sqr/2^n' % px)
        level = base_level - n
        scale = 1.0 / (2 ** n)
        yshift_per_layer = 1.5 * sqr * scale  # 뷰어 yshift 를 이 레벨 배율로
        outdir = os.path.join(args.out, 'textures', 'HaloDrop', 'L%g' % px)
        os.makedirs(outdir, exist_ok=True)

        # 합성 소스: (맵, 레이어) -> {(tx,ty): path}, 각 맵의 base 좌표계 오프셋 (base px)
        sources = []
        for mp in [base] + overlays:
            ox = (mp['info']['x0'] - bx0) * scale
            oy = (mp['info']['y0'] - by0) * scale
            mp_level = base_level_of(mp) - n
            for layer in range(lmin, lmax + 1):
                lv = mp['layers'].get(layer, {})
                tiles = level_tiles(lv.get(mp_level, '')) if mp_level in lv else {}
                if tiles:
                    sources.append({'map': mp, 'layer': layer, 'tiles': tiles, 'ox': ox, 'oy': oy,
                                    'dy': -yshift_per_layer * layer})
        if not sources:
            print('px %g: no source tiles at level %d' % (px, level))
            continue

        # 출력 타일 범위: 모든 소스 타일이 덮는 영역 (base 좌표계)
        minc, minr, maxc, maxr = 1e9, 1e9, -1e9, -1e9
        for s in sources:
            for (tx, ty) in s['tiles']:
                x0 = tx * TILE + s['ox']; y0 = ty * TILE + s['oy'] + s['dy']
                minc = min(minc, math.floor(x0 / TILE)); maxc = max(maxc, math.floor((x0 + TILE - 1) / TILE))
                minr = min(minr, math.floor(y0 / TILE)); maxr = max(maxr, math.floor((y0 + TILE - 1) / TILE))
        if minc < 0 or minr < 0:
            sys.exit('negative tile index (overlay left/above base): shift not supported yet')

        pieces = []
        cache = {}

        def get(path):
            im = cache.get(path)
            if im is None:
                im = Image.open(path).convert('RGBA')
                if len(cache) > 64:
                    cache.clear()
                cache[path] = im
            return im

        for r in range(int(minr), int(maxr) + 1):
            for c in range(int(minc), int(maxc) + 1):
                canvas = None
                for s in sources:  # 순서: base 0층, 1층 ..., 오버레이 0층 ...
                    for (tx, ty), path in s['tiles'].items():
                        x = tx * TILE + s['ox'] - c * TILE
                        y = ty * TILE + s['oy'] + s['dy'] - r * TILE
                        if x <= -TILE or y <= -TILE or x >= TILE or y >= TILE:
                            continue
                        if canvas is None:
                            canvas = Image.new('RGBA', (TILE, TILE), (0, 0, 0, 0))
                        im = get(path)
                        canvas.alpha_composite(im, (int(round(x)), int(round(y))))
                if canvas is None or canvas.getbbox() is None:
                    continue
                rgb = Image.new('RGB', (TILE, TILE), (84, 107, 48))
                rgb.paste(canvas, mask=canvas.split()[3])
                rgb.save(os.path.join(outdir, '%d_%d.jpg' % (c, r)), quality=args.quality, optimize=True)
                pieces.append((c, r))
        print('px %g (level %d): %d tiles -> %s' % (px, level, len(pieces), outdir))
        lua_levels.append({
            'id': 'L%g' % px, 'px': px,
            'ox': bx0 * scale, 'oy': by0 * scale,
            'path': 'media/textures/HaloDrop/L%g/' % px,
            'pieces': pieces,
        })

    # Lua 상수 파일
    lines = ['-- 자동 생성: tools/make_sky_tiles.py (pzmap2dzi 아이소 렌더). 손으로 고치지 말 것.',
             'require "HaloDropMap"', '', 'HaloDropMap.levels = {']
    for L in sorted(lua_levels, key=lambda l: l['px']):
        ps = ' '.join('["%d_%d"]=true,' % p for p in L['pieces'])
        lines.append('    { id = "%s", px = %g, ox = %.3f, oy = %.3f, path = "%s",' % (L['id'], L['px'], L['ox'], L['oy'], L['path']))
        lines.append('      pieces = { %s } },' % ps)
    lines.append('}')
    lines.append('')
    luapath = os.path.join(args.out, 'lua', 'shared', 'HaloDropTiles.lua')
    with open(luapath, 'w', encoding='utf-8', newline='\r\n') as f:
        f.write('\n'.join(lines))
    print('wrote', luapath)


if __name__ == '__main__':
    main()
