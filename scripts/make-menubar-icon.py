#!/usr/bin/env python3
"""生成 macOS 菜单栏图标资源 PendingNetMenuBarIcon。

复用 make-app-icon.py 产出的两层 Icon-Composer SVG（前景主箭头 + 次要箭头），
拼成一张图，按明暗两种外观各渲染一份 PNG，非 template（保留品牌色）。

两套颜色与 app 图标保持一致：
  - light：主箭头 #044735 / 次箭头 #b7b7b7（设计稿原色，浅色下用）
  - dark ：主箭头 #ffffff  / 次箭头 #bfccc4（icon.json 的 dark 特化）

菜单栏图标**不**画底色圆角方块：浅色菜单栏上白底看不出边界（见
make-app-icon.py 同类注释），系统又不会替菜单栏里的普通图片画 squircle /
投影，所以这里只给两层箭头本身，靠明暗变体保证两种菜单栏背景下都可见。

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

LIGHT_PRIMARY = "#044735"
LIGHT_SECONDARY = "#b7b7b7"
DARK_PRIMARY = "#ffffff"
DARK_SECONDARY = "#bfccc4"  # icon.json: extended-srgb:0.750,0.800,0.780


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


def render_png(svg_text: str, out_png: pathlib.Path) -> None:
    tmp_svg = out_png.with_suffix(".svg")
    raw = out_png.with_name(out_png.stem + ".raw.png")
    tmp_svg.write_text(svg_text)
    # 按 1024 渲染 -> trim 掉透明留白 -> 加一点透明边距，箭头不贴着图像边。
    subprocess.run(
        ["rsvg-convert", "-w", "1024", "-h", "1024", str(tmp_svg), "-o", str(raw)],
        check=True,
    )
    subprocess.run(
        ["magick", str(raw), "-trim", "+repage",
         "-bordercolor", "none", "-border", "48", str(out_png)],
        check=True,
    )
    raw.unlink(missing_ok=True)
    tmp_svg.unlink(missing_ok=True)


def main() -> None:
    for name in ("primary.svg", "secondary.svg"):
        if not (SRC / name).exists():
            sys.exit(f"缺少 {SRC / name} -- 先跑 scripts/make-app-icon.py")

    primary_g = inner_g((SRC / "primary.svg").read_text())
    secondary_g = inner_g((SRC / "secondary.svg").read_text())

    light = combined_svg(primary_g, secondary_g)
    dark = combined_svg(
        primary_g.replace(LIGHT_PRIMARY, DARK_PRIMARY),
        secondary_g.replace(LIGHT_SECONDARY, DARK_SECONDARY),
    )

    CATALOG.mkdir(parents=True, exist_ok=True)
    root_contents = CATALOG / "Contents.json"
    if not root_contents.exists():
        root_contents.write_text(
            json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
        )

    OUT.mkdir(parents=True, exist_ok=True)
    render_png(light, OUT / "menubar-light.png")
    render_png(dark, OUT / "menubar-dark.png")

    contents = {
        "images": [
            {
                "filename": "menubar-light.png",
                "idiom": "universal",
                "appearances": [{"appearance": "luminosity", "value": "light"}],
            },
            {
                "filename": "menubar-dark.png",
                "idiom": "universal",
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
            },
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (OUT / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"生成 {OUT}")


if __name__ == "__main__":
    main()
