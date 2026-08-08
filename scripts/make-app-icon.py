#!/usr/bin/env python3
"""从 PendingNetIcon.svg 生成 app/SBTally/PendingNet.icon（Icon Composer 文档）。

macOS 26 起 app 图标是分层的 .icon：**圆角、玻璃高光、投影、深浅/单色变体全部由系统画**，
我们只负责两件事 —— 前景图形和底色。所以这里不再手工画白底圆角方块（那正是之前
「白底在浅色背景上看不出边界」的成因），只把设计稿的图形按苹果的图标网格摆好、
按底色重新上色，底色交给 icon.json 的 automatic-gradient。

actool 编译 .icon 时会顺带产出一份传统 .icns 兜底，所以 macOS 14/15 上一样有图标。

用法：python3 scripts/make-app-icon.py [--svg PendingNetIcon.svg]
"""

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# 浅色下的底：设计稿本来就是画在白底上的，这里给近白色（automatic-gradient
# 会自动派生出一点点纵深）。深色下的底由系统给，我们给不了也不该给。
LIGHT_GROUND = (0.98, 0.98, 0.975)

# 设计稿分两组：主（深绿箭头 + 深绿点）和次（浅灰箭头 + 浅灰点）。
# 浅色下直接用设计稿自己的颜色；深色下系统会铺一层深底，深绿就沉下去了，
# 所以给这两组各挂一个 dark 特化，把颜色换成白与浅灰。
PRIMARY_CLASSES = {"st0", "st2"}
DARK_PRIMARY = (1.0, 1.0, 1.0)
DARK_SECONDARY = (0.75, 0.80, 0.78)

CANVAS = 1024.0
# 图形在 1024 画布里的最大边长。系统还会再往内缩一点做圆角裁切，
# 660 是留足安全边距后仍然饱满的尺寸。
CONTENT_MAX = 660.0


def view_box(svg: str) -> float:
    m = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg)
    if not m or m.group(1) != m.group(2):
        sys.exit("只支持正方形 viewBox 的设计稿")
    return float(m.group(1))


def shape_bbox(svg_path: pathlib.Path, units: float, size: int = 2048) -> tuple[float, ...]:
    """用 rsvg 渲染一遍再 trim，把图形包围盒换算回 viewBox 的用户单位。"""
    png = svg_path.parent / (svg_path.stem + ".bbox.png")
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), str(svg_path), "-o", str(png)],
        check=True,
    )
    out = subprocess.run(
        ["magick", str(png), "-trim", "info:"], check=True, capture_output=True, text=True
    ).stdout
    png.unlink(missing_ok=True)
    # ... 1412x1141 2048x2048+366+407 ...
    m = re.search(r"\s(\d+)x(\d+)\s+\d+x\d+\+(\d+)\+(\d+)\s", out)
    if not m:
        sys.exit(f"读不出包围盒：{out}")
    w, h, x, y = (int(g) for g in m.groups())
    k = units / size
    return x * k, y * k, w * k, h * k


def parse_shapes(svg: str) -> list[tuple[str, str, str]]:
    """取出 (tag, class, 其余属性) 三元组，顺序即绘制顺序。"""
    shapes = re.findall(r"<(path|circle)\s+class=\"(st\d)\"([^>]*?)/>", svg)
    if not shapes:
        sys.exit("SVG 里没找到 class=\"stN\" 的图形 —— 导出格式变了？")
    return shapes


def stroke_widths(svg: str) -> dict[str, float]:
    """描边宽度是设计稿定的字重，必须保留 —— Illustrator 里写在 <style> 里，按 class 取。"""
    widths: dict[str, float] = {}
    for cls, body in re.findall(r"\.(st\d)\s*\{([^}]*)\}", svg):
        m = re.search(r"stroke-width:\s*([\d.]+)px", body)
        if m:
            widths[cls] = float(m.group(1))
    return widths


def shape_colors(svg: str) -> dict[str, str]:
    """设计稿自己的颜色，按 class 取（浅色模式下原样用）。"""
    colors: dict[str, str] = {}
    for classes, body in re.findall(r"((?:\.st\d,?\s*)+)\{([^}]*)\}", svg):
        m = re.search(r"fill:\s*(#[0-9a-fA-F]{3,6})", body)
        if not m:
            continue
        for cls in re.findall(r"st\d", classes):
            colors.setdefault(cls, m.group(1))
    return colors


def build_layer(svg_text: str, bbox: tuple[float, ...], classes: set[str]) -> str:
    """把设计稿里指定的一组图形，按图标网格摆进 1024 画布，保留原色。"""
    x, y, w, h = bbox
    scale = CONTENT_MAX / max(w, h)
    cx, cy = x + w / 2, y + h / 2
    tx = CANVAS / 2 - cx * scale
    ty = CANVAS / 2 - cy * scale

    widths = stroke_widths(svg_text)
    colors = shape_colors(svg_text)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" version="1.1" '
        f'viewBox="0 0 {CANVAS:.0f} {CANVAS:.0f}" width="{CANVAS:.0f}" height="{CANVAS:.0f}">',
        f'  <g transform="translate({tx:.2f} {ty:.2f}) scale({scale:.5f})">',
    ]
    for tag, cls, attrs in parse_shapes(svg_text):
        if cls not in classes:
            continue
        color = colors.get(cls, "#000000")
        paint = f'fill="{color}"'
        if cls in widths:
            # 描边照搬设计稿的宽度，只把 miter 改成 round：设计稿用的是 miter-limit 10，
            # 箭头倒钩那个锐角超限后会甩出一根毛刺（Illustrator 画板上没有，
            # 三个 SVG 引擎都有）。圆角接头的结果与画板逐像素吻合。
            paint += (
                f' stroke="{color}" stroke-width="{widths[cls]}"'
                ' stroke-linejoin="round" stroke-linecap="round"'
            )
        lines.append(f"    <{tag} {paint}{attrs}/>")
    lines += ["  </g>", "</svg>", ""]
    return "\n".join(lines)


def srgb(rgb: tuple[float, float, float]) -> str:
    r, g, b = rgb
    return f"extended-srgb:{r:.3f},{g:.3f},{b:.3f},1.000"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--svg", default=str(ROOT / "PendingNetIcon.svg"))
    ap.add_argument("--out", default=str(ROOT / "app" / "SBTally" / "PendingNet.icon"))
    args = ap.parse_args()

    src = pathlib.Path(args.svg)
    svg_text = src.read_text()
    units = view_box(svg_text)

    out = pathlib.Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    (out / "Assets").mkdir(parents=True)

    # 包围盒按整张设计稿量，两层共用，才不会各自居中导致错位。
    bbox = shape_bbox(src, units)
    all_classes = {cls for _, cls, _ in parse_shapes(svg_text)}
    secondary_classes = all_classes - PRIMARY_CLASSES
    (out / "Assets" / "primary.svg").write_text(build_layer(svg_text, bbox, PRIMARY_CLASSES))
    (out / "Assets" / "secondary.svg").write_text(build_layer(svg_text, bbox, secondary_classes))

    # 分两层是为了让深色模式能把两组图形换成两种颜色（图层的 fill 特化是整层一个色）。
    # 注意：**不能**给图层写 base 的 fill —— 一旦写了，dark 特化就不再生效，
    # 浅色下也会丢掉设计稿自己的颜色。不写 fill = 浅色用 SVG 原色、深色走特化。
    def layer(name: str, asset: str, dark: tuple[float, float, float]) -> dict:
        return {
            "image-name": asset,
            "name": name,
            "fill-specializations": [{"appearance": "dark", "value": {"solid": srgb(dark)}}],
        }

    (out / "icon.json").write_text(
        json.dumps(
            {
                "fill": {"automatic-gradient": srgb(LIGHT_GROUND)},
                "groups": [
                    {
                        "layers": [
                            layer("次要箭头", "secondary.svg", DARK_SECONDARY),
                            layer("主箭头", "primary.svg", DARK_PRIMARY),
                        ],
                        "shadow": {"kind": "neutral", "opacity": 0.5},
                        "specular": True,
                        "translucency": {"enabled": False, "value": 0.5},
                    }
                ],
                "supported-platforms": {"circles": ["watchOS"], "squares": ["macOS"]},
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n"
    )
    print(f"生成 {out}")


if __name__ == "__main__":
    main()
