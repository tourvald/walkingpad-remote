"""Measure the selected zone and time marks in the retained native screenshots."""

import json
from pathlib import Path

from PIL import Image


def measure(path: Path, state: str) -> dict:
    image = Image.open(path).convert("RGB")
    assert image.size == (1170, 2532), "Expected the verified 390 x 844 @3x capture"
    zone_rows = [
        y for y in range(900, 1900)
        if sum(
            red > 230 and 170 < green < 235 and blue < 80
            for red, green, blue in (image.getpixel((x, y)) for x in range(530, 640))
        ) > 60
    ]
    x_range = range(605, 720) if state == "ready" else range(150, 350)
    time_rows = [
        y for y in range(1500, 1900)
        if sum(
            140 < red < 200 and 40 < green < 110 and blue < 30
            for red, green, blue in (image.getpixel((x, y)) for x in x_range)
        ) > 60
    ]
    return {
        "zoneBarTopPx": min(zone_rows),
        "zoneBarBottomPx": max(zone_rows),
        "zoneBarCenterPt": (min(zone_rows) + max(zone_rows)) / 6,
        "timeMarkCenterPt": (min(time_rows) + max(time_rows)) / 6,
    }


if __name__ == "__main__":
    native = Path(__file__).parent / "native"
    result = {state: measure(native / f"{state}-light.png", state) for state in ["ready", "active"]}
    result["deltaZonePt"] = result["active"]["zoneBarCenterPt"] - result["ready"]["zoneBarCenterPt"]
    result["deltaTimeMarkPt"] = result["active"]["timeMarkCenterPt"] - result["ready"]["timeMarkCenterPt"]
    assert abs(result["deltaZonePt"]) <= 1
    assert abs(result["deltaTimeMarkPt"]) <= 1
    print(json.dumps(result, indent=2))
