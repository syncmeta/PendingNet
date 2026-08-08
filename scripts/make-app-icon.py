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


def stroke_widths(svg: str) -> dict[str, float]:
    """Illustrator 把描边宽度写在 <style> 里，按 class 取出来。"""
    widths: dict[str, float] = {}
    for cls, body in re.findall(r"\.(st\d)\s*\{([^}]*)\}", svg):
        m = re.search(r"stroke-width:\s*([\d.]+)px", body)
        if m:
            widths[cls] = float(m.group(1))
    return widths


def shape_bboxes(svg_text: str, units: float, work: pathlib.Path) -> dict[str, tuple[float, ...]]:
    """逐个图形单独渲染取包围盒 —— 修主箭头时要按次箭头的尺寸/位置对齐。"""
    head = svg_text[: svg_text.index("<path")]
    out: dict[str, tuple[float, ...]] = {}
    for tag, cls, attrs in parse_shapes(svg_text):
        one = work / f"{cls}.svg"
        one.write_text(f"{head}<{tag} class=\"{cls}\"{attrs}/></svg>")
        out[cls] = shape_bbox(one, units)
        one.unlink(missing_ok=True)
    return out


def repair_primary_arrow(svg_text: str, units: float, work: pathlib.Path) -> str:
    """把主箭头换成次箭头旋转 180° 的副本。

    设计稿导出的主箭头路径自交（渲出来是带缺口的墨块，苹果和 rsvg 的渲染结果一致）。
    两个箭头本就是同一个字形的正反两版，所以拿干净的那个转过来复用，形状最忠于原设计。
    """
    shapes = {cls: (tag, attrs) for tag, cls, attrs in parse_shapes(svg_text)}
    bb = shape_bboxes(svg_text, units, work)
    x0, y0, w0, h0 = bb["st0"]
    x1, y1, w1, h1 = bb["st1"]
    scale = ((w0 / w1) + (h0 / h1)) / 2
    cx0, cy0 = x0 + w0 / 2, y0 + h0 / 2
    cx1, cy1 = x1 + w1 / 2, y1 + h1 / 2
    tag, attrs = shapes["st1"]
    # 变换写成图形自己的 transform 属性（而不是包一层 <g>），
    # 后面按 class 逐个改色的正则才照样认得出它。
    rebuilt = (
        f'<{tag} class="st0" transform="translate({cx0:.2f} {cy0:.2f}) scale({scale:.4f}) '
        f'rotate(180) translate({-cx1:.2f} {-cy1:.2f})"{attrs}/>'
    )
    head = svg_text[: svg_text.index("<path")]
    rest = [rebuilt] + [
        f'<{shapes[c][0]} class="{c}"{shapes[c][1]}/>' for c in ("st1", "st2", "st3") if c in shapes
    ]
    return head + "\n".join(rest) + "\n</svg>\n"


def build_foreground(svg_text: str, bbox: tuple[float, float, float, float]) -> str:
    x, y, w, h = bbox
    scale = CONTENT_MAX / max(w, h)
    cx, cy = x + w / 2, y + h / 2
    tx = CANVAS / 2 - cx * scale
    ty = CANVAS / 2 - cy * scale

    widths = stroke_widths(svg_text)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" version="1.1" '
        f'viewBox="0 0 {CANVAS:.0f} {CANVAS:.0f}" width="{CANVAS:.0f}" height="{CANVAS:.0f}">',
        f'  <g transform="translate({tx:.2f} {ty:.2f}) scale({scale:.5f})">',
    ]
    for tag, cls, attrs in parse_shapes(svg_text):
        primary = cls in PRIMARY_CLASSES
        color = PRIMARY if primary else SECONDARY
        paint = f'fill="{color}"'
        if not primary:
            paint += f' fill-opacity="{SECONDARY_OPACITY}"'
        if cls in widths:
            paint += f' stroke="{color}" stroke-width="{widths[cls]}" stroke-miterlimit="10"'
            if not primary:
                paint += f' stroke-opacity="{SECONDARY_OPACITY}"'
        lines.append(f"    <{tag} {paint}{attrs}/>")
    lines += ["  </g>", "</svg>", ""]
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--svg", default=str(ROOT / "PendingNetIcon.svg"))
    ap.add_argument("--out", default=str(ROOT / "app" / "SBTally" / "PendingNet.icon"))
    ap.add_argument(
        "--repair-primary-arrow",
        action="store_true",
        help="设计稿里主箭头路径自交时，用次箭头旋转 180° 顶上",
    )
    args = ap.parse_args()

    src = pathlib.Path(args.svg)
    svg_text = src.read_text()
    units = view_box(svg_text)

    out = pathlib.Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    (out / "Assets").mkdir(parents=True)

    if args.repair_primary_arrow:
        svg_text = repair_primary_arrow(svg_text, units, out)
        src = out / "repaired.svg"
        src.write_text(svg_text)
    bbox = shape_bbox(src, units)
    (out / "Assets" / "PendingNet.svg").write_text(build_foreground(svg_text, bbox))
    if args.repair_primary_arrow:
        src.unlink()

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
