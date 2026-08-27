#!/usr/bin/env python3
"""生成 macOS 菜单栏图标资源 PendingNetMenuBarIcon。

复用 make-app-icon.py 产出的两层 Icon-Composer SVG（前景主箭头 + 次要箭头），
拼成一张图，按明暗两种外观各渲染一份 PNG。菜单栏资源固定为纯白色，
不再沿用 app 图标的绿/灰品牌色；两个外观槽保持相同，避免系统切换外观后
图标颜色发生变化。

菜单栏图标**不**画底色圆角方块：浅色菜单栏上白底看不出边界（见
make-app-icon.py 同类注释），系统又不会替菜单栏里的普通图片画 squircle /
投影，所以这里只给两层箭头本身，靠明暗变体保证两种菜单栏背景下都可见。

**尺寸必须在这里定死，不能指望 SwiftUI 侧收拾。** `MenuBarExtra` 的 label 只
取原样的 Text / Image，加在上面的 `.resizable()` `.frame()` 一律被丢掉 ——
0.3.29 就是这么修错过一次：Swift 那边加了 `.frame(width:22,height:18)`，装上
去菜单栏照样被占满。所以这里按点尺寸出 @1x/@2x/@3x 三份，图片的固有尺寸就是
最终显示尺寸。之前只出一张 756x630、连 scale 都没标，对 AppKit 来说就是一张
756 点宽的图，一个图标把整条菜单栏吃掉。

输出 app/SBTally/Assets.xcassets/PendingNetMenuBarIcon.imageset/。
依赖 app/PendingNet.icon/Assets/{primary,secondary}.svg（由 make-app-icon.py
生成），所以改了 PendingNetIcon.svg 后要按顺序重跑两个脚本。

用法：python3 scripts/make-menubar-icon.py
"""

import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "app" / "PendingNet.icon" / "Assets"
CATALOG = ROOT / "app" / "SBTally" / "Assets.xcassets"
OUT = CATALOG / "PendingNetMenuBarIcon.imageset"

# 菜单栏图标的点尺寸。菜单栏高 22-24 点，18 点高是系统一贯的图标尺寸；
# 宽度按两层箭头 trim 之后的比例（约 1.2:1）取整到 22，画面居中留白。
POINT_W = 22
POINT_H = 18
SCALES = (1, 2, 3)

SOURCE_PRIMARY = "#044735"
SOURCE_SECONDARY = "#b7b7b7"
MENUBAR_WHITE = "#ffffff"


def inner_g(svg_text: str) -> str:
    m = re.search(r"(<g\b.*?</g>)", svg_text, re.S)
    if not m:
        sys.exit("在 SVG 里找不到 <g> 图层 -- 上游格式变了？")
    return m.group(1)


def combined_svg(primary_g: str, secondary_g: str) -> str:
    # 先画次要箭头再画主箭头，叠放顺序与 icon.json 的图层顺序一致。
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" version="1.1" '
        'viewBox="0 0 1024 1024" width="1024" height="1024">\n'
        f"  {secondary_g}\n"
        f"  {primary_g}\n"
        "</svg>\n"
    )


def render_variants(svg_text: str, out_dir: pathlib.Path, stem: str) -> list[str]:
    """渲染 stem 的 @1x/@2x/@3x 三份，返回文件名（按 SCALES 顺序）。"""
    tmp_svg = out_dir / f"{stem}.svg"
    raw = out_dir / f"{stem}.raw.png"
    master = out_dir / f"{stem}.master.png"
    tmp_svg.write_text(svg_text)
    # 按 1024 渲染 -> trim 掉透明留白 -> 加一点透明边距，箭头不贴着图像边。
    subprocess.run(
        ["rsvg-convert", "-w", "1024", "-h", "1024", str(tmp_svg), "-o", str(raw)],
        check=True,
    )
    subprocess.run(
        ["magick", str(raw), "-trim", "+repage",
         "-bordercolor", "none", "-border", "48", str(master)],
        check=True,
    )

    names = []
    for scale in SCALES:
        w, h = POINT_W * scale, POINT_H * scale
        name = f"{stem}.png" if scale == 1 else f"{stem}@{scale}x.png"
        # -resize 是「装进这个框」（保比例），-extent 再补透明边到精确画布，
        # 这样三档的像素尺寸严格是 1:2:3，asset catalog 才认成同一张图。
        subprocess.run(
            ["magick", str(master),
             "-resize", f"{w}x{h}",
             "-background", "none", "-gravity", "center", "-extent", f"{w}x{h}",
             str(out_dir / name)],
            check=True,
        )
        names.append(name)

    for junk in (master, raw, tmp_svg):
        junk.unlink(missing_ok=True)
    return names


def main() -> None:
    for name in ("primary.svg", "secondary.svg"):
        if not (SRC / name).exists():
            sys.exit(f"缺少 {SRC / name} -- 先跑 scripts/make-app-icon.py")

    primary_g = inner_g((SRC / "primary.svg").read_text())
    secondary_g = inner_g((SRC / "secondary.svg").read_text())

    white = combined_svg(
        primary_g.replace(SOURCE_PRIMARY, MENUBAR_WHITE),
        secondary_g.replace(SOURCE_SECONDARY, MENUBAR_WHITE),
    )

    CATALOG.mkdir(parents=True, exist_ok=True)
    root_contents = CATALOG / "Contents.json"
    if not root_contents.exists():
        root_contents.write_text(
            json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
        )

    OUT.mkdir(parents=True, exist_ok=True)
    light_names = render_variants(white, OUT, "menubar-light")
    dark_names = render_variants(white, OUT, "menubar-dark")

    images = []
    for value, names in (("light", light_names), ("dark", dark_names)):
        for scale, name in zip(SCALES, names):
            images.append({
                "filename": name,
                "idiom": "universal",
                "scale": f"{scale}x",
                "appearances": [{"appearance": "luminosity", "value": value}],
            })
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (OUT / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"生成 {OUT}")


if __name__ == "__main__":
    main()
