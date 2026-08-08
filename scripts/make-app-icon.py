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

# 品牌深绿 —— 设计稿里主箭头的颜色，这里当底色用（前景改成白）。
BRAND_GREEN = (0.016, 0.278, 0.208)

# 设计稿里两组图形的语义：主（原深绿）压白，次（原浅灰）压半透明白。
# 直接给灰色会在绿底上发脏，用带透明度的白才是同一套明度关系。
PRIMARY = "#FFFFFF"
SECONDARY = "#FFFFFF"
SECONDARY_OPACITY = 0.65
PRIMARY_CLASSES = {"st0", "st2"}

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


def fill_only(svg_text: str) -> str:
    """把设计稿改写成「只填充、不描边」的等价图形。

    Illustrator 里箭头是描边对齐到外侧画粗的，而 SVG 只有居中描边这一种语义 ——
    导出后同色描边有一半落在图形内部，会把箭头两个倒钩之间的窄缝糊死，
    尖角处还会甩出一根 miter 毛刺。设计稿本身没问题，丢掉描边即还原本来的形状。
    """
    head = svg_text[: svg_text.index("<path")]
    body = "".join(f"<{tag} class=\"{cls}\"{attrs}/>" for tag, cls, attrs in parse_shapes(svg_text))
    return head + body + "</svg>"


def build_foreground(svg_text: str, bbox: tuple[float, float, float, float]) -> str:
    x, y, w, h = bbox
    scale = CONTENT_MAX / max(w, h)
    cx, cy = x + w / 2, y + h / 2
    tx = CANVAS / 2 - cx * scale
    ty = CANVAS / 2 - cy * scale

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" version="1.1" '
        f'viewBox="0 0 {CANVAS:.0f} {CANVAS:.0f}" width="{CANVAS:.0f}" height="{CANVAS:.0f}">',
        f'  <g transform="translate({tx:.2f} {ty:.2f}) scale({scale:.5f})">',
    ]
    for tag, cls, attrs in parse_shapes(svg_text):
        primary = cls in PRIMARY_CLASSES
        paint = f'fill="{PRIMARY if primary else SECONDARY}"'
        if not primary:
            paint += f' fill-opacity="{SECONDARY_OPACITY}"'
        lines.append(f"    <{tag} {paint}{attrs}/>")
    lines += ["  </g>", "</svg>", ""]
    return "\n".join(lines)


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

    # 包围盒要按去掉描边之后的真实图形来量，否则会白留一圈边距。
    flat = out / "fill-only.svg"
    flat.write_text(fill_only(svg_text))
    bbox = shape_bbox(flat, units)
    flat.unlink()
    (out / "Assets" / "PendingNet.svg").write_text(build_foreground(svg_text, bbox))

    r, g, b = BRAND_GREEN
    (out / "icon.json").write_text(
        json.dumps(
            {
                "fill": {"automatic-gradient": f"extended-srgb:{r:.3f},{g:.3f},{b:.3f},1.000"},
                "groups": [
                    {
                        "layers": [{"image-name": "PendingNet.svg", "name": "箭头"}],
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
