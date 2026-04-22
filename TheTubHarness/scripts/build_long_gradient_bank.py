#!/usr/bin/env python3
"""Build a dedicated long-sample bank for the Play gradient strip.

This renders 20 curated long clips (4 per source track) from a source folder,
applying light mastering and a few derivative textures so bank sweeps feel more
varied while remaining level-matched.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List


SAMPLE_RATE = 44_100
CHANNELS = 2
SAMPLE_FMT = "s16"
MIN_LONG_SECONDS = 4.0


@dataclass(frozen=True)
class ClipSpec:
    name: str
    source: str
    start_s: float
    duration_s: float
    style: str
    profile: str


# Ordered to map cleanly into the 8 long banks (16 L/R + 4 center slots).
CLIPS: List[ClipSpec] = [
    ClipSpec("00_xither_forge", "Xither.mp3", 28.0, 11.8, "base", "xither"),
    ClipSpec("01_wetair_veil", "wet air pad.mp3", 124.0, 11.4, "haze", "wetair"),
    ClipSpec("02_trillion_hull", "trillion.mp3", 20.0, 11.9, "base", "trillion"),
    ClipSpec("03_acharia_arc", "acharia.mp3", 14.0, 10.8, "base", "acharia"),
    ClipSpec("04_xemf_mass", "xemf.mp3", 18.0, 12.8, "base", "xemf"),
    ClipSpec("05_xither_glass", "Xither.mp3", 91.0, 12.4, "air", "xither"),
    ClipSpec("06_wetair_core", "wet air pad.mp3", 6.0, 12.5, "base", "wetair"),
    ClipSpec("07_trillion_air", "trillion.mp3", 74.0, 10.6, "air", "trillion"),
    ClipSpec("08_acharia_depth", "acharia.mp3", 118.0, 10.7, "down", "acharia"),
    ClipSpec("09_xemf_sheen", "xemf.mp3", 136.0, 11.1, "air", "xemf"),
    ClipSpec("10_xither_floor", "Xither.mp3", 158.0, 10.9, "down", "xither"),
    ClipSpec("11_wetair_shine", "wet air pad.mp3", 36.0, 11.2, "air", "wetair"),
    ClipSpec("12_trillion_low", "trillion.mp3", 133.0, 11.4, "down", "trillion"),
    ClipSpec("13_acharia_spark", "acharia.mp3", 162.0, 11.3, "up", "acharia"),
    ClipSpec("14_xemf_grain", "xemf.mp3", 252.0, 10.9, "down", "xemf"),
    ClipSpec("15_xither_lift", "Xither.mp3", 272.0, 11.5, "up", "xither"),
    ClipSpec("16_wetair_drift", "wet air pad.mp3", 82.0, 10.8, "down", "wetair"),
    ClipSpec("17_trillion_fog", "trillion.mp3", 189.0, 10.9, "haze", "trillion"),
    ClipSpec("18_acharia_haze", "acharia.mp3", 63.0, 11.6, "haze", "acharia"),
    ClipSpec("19_xemf_bloom", "xemf.mp3", 398.0, 12.2, "up", "xemf"),
]


STYLE_FILTERS: Dict[str, str] = {
    "base": (
        "highpass=f=28,lowpass=f=17000,"
        "acompressor=threshold=-14dB:ratio=2:attack=15:release=180:makeup=2,"
        "loudnorm=I=-20:TP=-1.5:LRA=11"
    ),
    "air": (
        "highpass=f=90,lowpass=f=16000,"
        "equalizer=f=4800:t=q:w=1.3:g=2.0,"
        "aecho=0.7:0.35:42:0.16,"
        "loudnorm=I=-20:TP=-1.5:LRA=10"
    ),
    "down": (
        "highpass=f=30,"
        "asetrate=42831,aresample=44100,atempo=1.029302,"
        "lowpass=f=14000,"
        "loudnorm=I=-20:TP=-1.5:LRA=11"
    ),
    "up": (
        "highpass=f=30,"
        "asetrate=45388,aresample=44100,atempo=0.971532,"
        "lowpass=f=17000,"
        "loudnorm=I=-20:TP=-1.5:LRA=11"
    ),
    "haze": (
        "highpass=f=140,lowpass=f=9000,"
        "aecho=0.75:0.35:65:0.22,"
        "acompressor=threshold=-18dB:ratio=2.5:attack=10:release=220:makeup=3,"
        "loudnorm=I=-20:TP=-1.5:LRA=9"
    ),
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Render long gradient bank clips")
    p.add_argument("--source-dir", required=True, help="Directory containing source MP3 tracks")
    p.add_argument("--output-dir", required=True, help="Directory where WAV clips are written")
    p.add_argument("--report", help="Optional JSON report output path")
    return p.parse_args()


def run(cmd: List[str]) -> None:
    subprocess.run(cmd, check=True)


def probe_duration(path: Path) -> float:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(path),
    ]
    out = subprocess.check_output(cmd, text=True).strip()
    return float(out)


def render_clip(source_path: Path, output_path: Path, start_s: float, duration_s: float, style: str) -> None:
    if style not in STYLE_FILTERS:
        raise ValueError(f"Unknown style: {style}")

    fade = max(0.14, min(0.24, duration_s * 0.02))
    fade_out_start = max(0.0, duration_s - fade)
    afilter = (
        f"{STYLE_FILTERS[style]},"
        f"afade=t=in:curve=hsin:st=0:d={fade:.3f},"
        f"afade=t=out:curve=hsin:st={fade_out_start:.3f}:d={fade:.3f}"
    )

    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        f"{start_s:.3f}",
        "-t",
        f"{duration_s:.3f}",
        "-i",
        str(source_path),
        "-vn",
        "-ac",
        str(CHANNELS),
        "-ar",
        str(SAMPLE_RATE),
        "-sample_fmt",
        SAMPLE_FMT,
        "-af",
        afilter,
        str(output_path),
    ]
    run(cmd)


def ensure_sources_exist(source_dir: Path) -> None:
    required = sorted({c.source for c in CLIPS})
    missing = [name for name in required if not (source_dir / name).is_file()]
    if missing:
        raise FileNotFoundError(f"Missing source files: {missing}")


def validate_layout() -> None:
    if len(CLIPS) != 20:
        raise RuntimeError(f"Expected 20 clip specs, got {len(CLIPS)}")

    for bank_index in range(8):
        left = CLIPS[bank_index * 2]
        right = CLIPS[(bank_index * 2) + 1]
        if left.profile == right.profile:
            raise RuntimeError(
                f"Bank {bank_index + 1} is not heterogeneous: {left.name} and {right.name} are both '{left.profile}'"
            )


def main() -> int:
    args = parse_args()
    source_dir = Path(args.source_dir).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()

    if not source_dir.is_dir():
        raise NotADirectoryError(f"Source directory not found: {source_dir}")

    ensure_sources_exist(source_dir)
    validate_layout()
    output_dir.mkdir(parents=True, exist_ok=True)

    # Clear only prior bank files generated by this script naming convention.
    for old in output_dir.glob("[0-1][0-9]_*.wav"):
        old.unlink()

    report = {
        "source_dir": str(source_dir),
        "output_dir": str(output_dir),
        "sample_rate": SAMPLE_RATE,
        "channels": CHANNELS,
        "clips": [],
    }

    for spec in CLIPS:
        src = source_dir / spec.source
        out = output_dir / f"{spec.name}.wav"
        render_clip(src, out, spec.start_s, spec.duration_s, spec.style)
        rendered_duration = probe_duration(out)
        if rendered_duration < MIN_LONG_SECONDS:
            raise RuntimeError(
                f"Rendered clip too short for long bank: {out.name} ({rendered_duration:.3f}s)"
            )
        report["clips"].append(
            {
                "file": out.name,
                "source": spec.source,
                "start_s": spec.start_s,
                "duration_s": round(rendered_duration, 4),
                "style": spec.style,
                "profile": spec.profile,
            }
        )
        print(f"rendered {out.name} ({rendered_duration:.2f}s)")

    if len(report["clips"]) != 20:
        raise RuntimeError(f"Expected 20 clips, rendered {len(report['clips'])}")

    print(f"\nRendered {len(report['clips'])} clips in {output_dir}")

    bank_pairs = []
    for bank_index in range(8):
        left = CLIPS[bank_index * 2]
        right = CLIPS[(bank_index * 2) + 1]
        bank_pairs.append(
            {
                "bank": bank_index + 1,
                "left": left.name,
                "left_profile": left.profile,
                "right": right.name,
                "right_profile": right.profile,
            }
        )
    report["bank_pairs"] = bank_pairs

    if args.report:
        report_path = Path(args.report).expanduser().resolve()
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"Report written to {report_path}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
