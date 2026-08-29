"""参照音声を Qwen3-TTS 向けに前処理する。

- ステレオ -> モノラル
- 任意のサンプリングレート -> 24kHz
- 任意で先頭からの秒数で切り出し（推奨 3〜15 秒）

使い方:
    python scripts/prepare_reference.py --duration 12
"""

import argparse
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--src", default=str(ROOT / "reference" / "reference_audio.wav"))
    p.add_argument("--dst", default=str(ROOT / "reference" / "reference_24k_mono.wav"))
    p.add_argument("--sr", type=int, default=24000)
    p.add_argument("--start", type=float, default=0.0, help="切り出し開始秒")
    p.add_argument("--duration", type=float, default=None, help="切り出し長さ秒（未指定なら全体）")
    args = p.parse_args()

    cmd = ["ffmpeg", "-y", "-v", "error", "-ss", str(args.start), "-i", args.src]
    if args.duration is not None:
        cmd += ["-t", str(args.duration)]
    cmd += ["-ac", "1", "-ar", str(args.sr), "-c:a", "pcm_s16le", args.dst]

    subprocess.run(cmd, check=True)
    print(f"wrote {args.dst}  (sr={args.sr}, mono, start={args.start}, dur={args.duration})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
