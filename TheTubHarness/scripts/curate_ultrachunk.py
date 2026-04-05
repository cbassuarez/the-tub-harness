#!/usr/bin/env python3
import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

import aubio

KEEP_INDICES_PER_16 = [0, 3, 5, 7, 8, 11, 13, 15]
TARGET_LONG = 25
TARGET_SHORT = 633
LONG_THRESHOLD_SECONDS = 4.0
SAMPLE_RATE = 44100
CHANNELS = 2
CODEC = "pcm_s16le"


@dataclass(frozen=True)
class SampleInfo:
    path: Path
    number: int
    size_bytes: int
    duration_s: float
    cls: str  # "short" | "long"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Curate and re-encode ultrachunk samples.")
    p.add_argument("--input", required=True, help="Path to ultrachunk directory")
    p.add_argument("--report", required=True, help="Path to write JSON report")
    p.add_argument("--script-dest", help="Optional path to copy this script into repo")
    p.add_argument("--dry-run", action="store_true", help="Compute plan without mutating files")
    return p.parse_args()


def sample_number(path: Path) -> int:
    m = re.fullmatch(r"S(\d{4})\.wav", path.name)
    if not m:
        raise ValueError(f"Unexpected sample name format: {path.name}")
    return int(m.group(1))


def duration_seconds(path: Path) -> float:
    src = aubio.source(str(path), 0, 4096)
    total = 0
    while True:
        _, read = src()
        if read == 0:
            break
        total += read
    sr = float(src.samplerate)
    return (total / sr) if sr > 0 else 0.0


def collect_samples(root: Path) -> List[SampleInfo]:
    wavs = sorted(root.glob("S*.wav"), key=lambda p: sample_number(p))
    samples: List[SampleInfo] = []
    for p in wavs:
        num = sample_number(p)
        size = p.stat().st_size
        dur = duration_seconds(p)
        cls = "long" if dur > LONG_THRESHOLD_SECONDS else "short"
        samples.append(SampleInfo(path=p, number=num, size_bytes=size, duration_s=dur, cls=cls))
    return samples


def select_balanced_half(samples: List[SampleInfo]) -> Tuple[List[SampleInfo], Dict[str, object]]:
    chunks = [samples[i : i + 16] for i in range(0, len(samples), 16)]

    candidates: List[SampleInfo] = []
    for chunk in chunks:
        for idx in KEEP_INDICES_PER_16:
            if idx < len(chunk):
                candidates.append(chunk[idx])

    candidate_longs = [s for s in candidates if s.cls == "long"]
    candidate_shorts = [s for s in candidates if s.cls == "short"]

    if len(candidate_longs) < TARGET_LONG:
        raise RuntimeError(f"Not enough long candidates: need {TARGET_LONG}, got {len(candidate_longs)}")
    if len(candidate_shorts) < TARGET_SHORT:
        raise RuntimeError(f"Not enough short candidates: need {TARGET_SHORT}, got {len(candidate_shorts)}")

    # Deterministic selection in sequence order.
    keep_longs = candidate_longs[:TARGET_LONG]
    keep_shorts = candidate_shorts[:TARGET_SHORT]

    selected = keep_shorts + keep_longs
    selected = sorted(selected, key=lambda s: s.number)

    metadata = {
        "chunk_count": len(chunks),
        "chunk_rule_indices": KEEP_INDICES_PER_16,
        "candidate_count": len(candidates),
        "candidate_long_count": len(candidate_longs),
        "candidate_short_count": len(candidate_shorts),
        "selected_long_count": len(keep_longs),
        "selected_short_count": len(keep_shorts),
    }
    return selected, metadata


def ffprobe_audio(path: Path) -> Dict[str, str]:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "a:0",
        "-show_entries",
        "stream=codec_name,sample_rate,channels,bits_per_sample",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(path),
    ]
    out = subprocess.check_output(cmd, text=True).strip().splitlines()
    # Expected order: codec_name, sample_rate, channels, bits_per_sample
    if len(out) < 4:
        raise RuntimeError(f"ffprobe returned unexpected output for {path}: {out}")
    return {
        "codec_name": out[0].strip(),
        "sample_rate": out[1].strip(),
        "channels": out[2].strip(),
        "bits_per_sample": out[3].strip(),
    }


def reencode_pcm16_stereo(path: Path) -> None:
    tmp = path.with_suffix(".tmp.wav")
    if tmp.exists():
        tmp.unlink()
    cmd = [
        "ffmpeg",
        "-y",
        "-v",
        "error",
        "-i",
        str(path),
        "-ac",
        str(CHANNELS),
        "-ar",
        str(SAMPLE_RATE),
        "-c:a",
        CODEC,
        str(tmp),
    ]
    subprocess.check_call(cmd)
    os.replace(tmp, path)


def bytes_mb(n: int) -> float:
    return round(n / (1024 * 1024), 2)


def main() -> int:
    args = parse_args()
    input_dir = Path(args.input).resolve()
    report_path = Path(args.report).resolve()

    if not input_dir.is_dir():
        raise RuntimeError(f"Input directory does not exist: {input_dir}")

    if args.script_dest:
        script_dest = Path(args.script_dest).resolve()
        script_dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(Path(__file__), script_dest)

    before = collect_samples(input_dir)
    if not before:
        raise RuntimeError(f"No S####.wav files found in {input_dir}")

    total_before_bytes = sum(s.size_bytes for s in before)
    selected, selection_meta = select_balanced_half(before)
    keep_set = {s.path.name for s in selected}

    dropped = [s for s in before if s.path.name not in keep_set]

    if len([s for s in selected if s.cls == "short"]) != TARGET_SHORT:
        raise RuntimeError("Selected short count mismatch")
    if len([s for s in selected if s.cls == "long"]) != TARGET_LONG:
        raise RuntimeError("Selected long count mismatch")

    mutation_summary = {
        "reencoded_count": len(selected),
        "dropped_count": len(dropped),
    }

    if not args.dry_run:
        for idx, s in enumerate(selected, 1):
            reencode_pcm16_stereo(s.path)
            if idx % 100 == 0 or idx == len(selected):
                print(f"re-encoded {idx}/{len(selected)}")

        for idx, s in enumerate(dropped, 1):
            s.path.unlink(missing_ok=False)
            if idx % 200 == 0 or idx == len(dropped):
                print(f"dropped {idx}/{len(dropped)}")

        after = collect_samples(input_dir)
        total_after_bytes = sum(s.size_bytes for s in after)

        after_names = {s.path.name for s in after}
        expected_names = {s.path.name for s in selected}
        missing_after = sorted(expected_names - after_names)
        unexpected_after = sorted(after_names - expected_names)
        if missing_after:
            raise RuntimeError(f"Missing expected files after mutation: {missing_after[:20]}")
        if unexpected_after:
            raise RuntimeError(f"Unexpected files remain after mutation: {unexpected_after[:20]}")

        # Codec verification for all kept files.
        format_violations = []
        for s in after:
            info = ffprobe_audio(s.path)
            if not (
                info["codec_name"] == CODEC
                and info["sample_rate"] == str(SAMPLE_RATE)
                and info["channels"] == str(CHANNELS)
                and info["bits_per_sample"] == "16"
            ):
                format_violations.append({"file": s.path.name, **info})
    else:
        after = list(selected)
        total_after_bytes = sum(s.size_bytes for s in selected)
        missing_after = []
        unexpected_after = []
        format_violations = []

    after_short = [s for s in after if s.cls == "short"]
    after_long = [s for s in after if s.cls == "long"]

    report = {
        "input_dir": str(input_dir),
        "selection_policy": {
            "group_size": 16,
            "rule_indices": KEEP_INDICES_PER_16,
            "target_short": TARGET_SHORT,
            "target_long": TARGET_LONG,
            "long_threshold_seconds": LONG_THRESHOLD_SECONDS,
        },
        "selection_metadata": selection_meta,
        "dry_run": args.dry_run,
        "before": {
            "count": len(before),
            "short_count": len([s for s in before if s.cls == "short"]),
            "long_count": len([s for s in before if s.cls == "long"]),
            "bytes": total_before_bytes,
            "mb": bytes_mb(total_before_bytes),
        },
        "after": {
            "count": len(after),
            "short_count": len(after_short),
            "long_count": len(after_long),
            "bytes": total_after_bytes,
            "mb": bytes_mb(total_after_bytes),
        },
        "delta": {
            "bytes_removed": total_before_bytes - total_after_bytes,
            "mb_removed": bytes_mb(total_before_bytes - total_after_bytes),
            "percent_removed": round((1 - (total_after_bytes / total_before_bytes)) * 100, 2),
        },
        "mutations": mutation_summary,
        "kept_files": [s.path.name for s in selected],
        "dropped_files": [s.path.name for s in dropped],
        "validation": {
            "missing_after": missing_after,
            "unexpected_after": unexpected_after,
            "format_violations": format_violations,
        },
    }

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(json.dumps({
        "before_mb": report["before"]["mb"],
        "after_mb": report["after"]["mb"],
        "removed_mb": report["delta"]["mb_removed"],
        "removed_percent": report["delta"]["percent_removed"],
        "kept_count": report["after"]["count"],
        "kept_short": report["after"]["short_count"],
        "kept_long": report["after"]["long_count"],
        "report": str(report_path),
    }, indent=2))

    if report["after"]["short_count"] != TARGET_SHORT or report["after"]["long_count"] != TARGET_LONG:
        raise RuntimeError("Final count check failed")
    if not args.dry_run and format_violations:
        raise RuntimeError(f"Audio format validation failed for {len(format_violations)} files")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
