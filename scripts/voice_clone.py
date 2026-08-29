"""Qwen3-TTS-12Hz-1.7B-Base による音声クローン検証スクリプト。

GTX 1660 Ti (Turing / sm_75) 向けの既定値:
  - dtype = bfloat16  … チェックポイントと同じ dtype。変換コピーを避けてRAMを節約
  - attn  = sdpa      … FlashAttention 2 は Ampere (sm_80) 以降が必須

使い方:
    python scripts/voice_clone.py
    python scripts/voice_clone.py --text "喋らせたい文章" --out output/foo.wav
"""

import argparse
import importlib.util
import pathlib
import time

import soundfile as sf
import torch
from qwen_tts import Qwen3TTSModel

ROOT = pathlib.Path(__file__).resolve().parent.parent

DEFAULT_TEXT = (
    "こんにちは。これは音声クローンのテストです。"
    "参照した声とどれくらい似ているか、確かめてみましょう。"
)

DTYPES = {"float16": torch.float16, "bfloat16": torch.bfloat16, "float32": torch.float32}


def has_flash_attn() -> bool:
    return importlib.util.find_spec("flash_attn") is not None


def pick_attn(requested: str) -> str:
    """FlashAttention 2 は「GPUが対応」かつ「パッケージが入っている」時だけ選ぶ。

    compute capability だけで判断すると、Ampere 以降のGPUなのに
    flash-attn 未導入の環境で transformers が ImportError を投げて起動できない。
    flash-attn は本セットアップの必須依存ではないので、必ず両方を確認する。
    """
    if requested != "auto":
        return requested
    if not torch.cuda.is_available():
        return "sdpa"
    major, _ = torch.cuda.get_device_capability(0)
    if major < 8:
        return "sdpa"          # FlashAttention 2 は Ampere (sm_80) 以降が必須
    if not has_flash_attn():
        return "sdpa"          # GPUは対応しているがパッケージが無い
    return "flash_attention_2"


def check_arch_supported() -> None:
    """このtorchビルドが当該GPUの命令セットを含むか確認し、含まなければ警告する。

    同じメジャー世代内では上位互換（sm_86 のコードは sm_89 で動く）なので、
    メジャーが一致し minor が同じか小さいアーキがあれば動作する。
    RTX 50 系 (Blackwell / sm_120) など新しすぎるGPUはここで弾かれる。
    """
    if not torch.cuda.is_available():
        return
    major, minor = torch.cuda.get_device_capability(0)
    archs = []
    for a in torch.cuda.get_arch_list():
        if a.startswith("sm_"):
            n = a[3:]
            archs.append((int(n[:-1]), int(n[-1])))
    if any(am == major and an <= minor for am, an in archs):
        return
    print()
    print(f"[警告] この PyTorch ビルドは sm_{major}{minor} 用のコードを含みません。")
    print(f"       含まれるのは: {', '.join(torch.cuda.get_arch_list())}")
    print( "       より新しい CUDA 版 PyTorch が必要です。例 (RTX 50 系など):")
    print( "         uv pip install --python .venv/Scripts/python.exe --reinstall \\")
    print( "             torch torchaudio --index-url https://download.pytorch.org/whl/cu128")
    print()


def pick_dtype(requested: str) -> torch.dtype:
    """既定は bfloat16。

    公開チェックポイントは BF16 で保存されている。float16 を要求すると
    ロード時に CPU 側で 3.4GiB の変換コピーが発生し、mmap 分と合わせて
    約 7GiB のコミットを要求する。搭載RAM/ページファイルによっては
    ここで OSError 1455 (ページングファイルが小さすぎる) で落ちる。
    BF16 のまま読めば変換コピーが発生しない。

    Turing (sm_75) には bf16 のテンソルコアが無く演算は fp32 に落ちるが、
    実測で問題なく動作する。
    """
    if requested != "auto":
        return DTYPES[requested]
    if not torch.cuda.is_available():
        return torch.float32
    return torch.bfloat16


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-1.7B-Base")
    p.add_argument("--ref-audio", default=str(ROOT / "reference" / "reference_24k_mono.wav"))
    p.add_argument("--ref-text", default=str(ROOT / "reference" / "reference_text.txt"))
    p.add_argument("--text", default=DEFAULT_TEXT)
    p.add_argument("--language", default="Japanese")
    p.add_argument("--out", default=str(ROOT / "output" / "voice_clone.wav"))
    p.add_argument("--device", default="cuda:0")
    p.add_argument("--dtype", default="auto", choices=["auto", *DTYPES])
    p.add_argument("--attn", default="auto",
                   choices=["auto", "sdpa", "eager", "flash_attention_2"])
    p.add_argument("--seed", type=int, default=None)
    args = p.parse_args()

    if args.seed is not None:
        torch.manual_seed(args.seed)

    if torch.cuda.is_available():
        name = torch.cuda.get_device_name(0)
        cap = torch.cuda.get_device_capability(0)
        vram = torch.cuda.get_device_properties(0).total_memory / 1024**3
        print(f"GPU: {name}  sm_{cap[0]}{cap[1]}  VRAM {vram:.1f} GiB")
    else:
        print("GPU: 利用不可 — CPU で実行します（非常に遅くなります）")
        args.device = "cpu"

    check_arch_supported()

    dtype = pick_dtype(args.dtype)
    attn = pick_attn(args.attn)
    print(f"dtype={dtype}  attn_implementation={attn}  device={args.device}")
    if attn == "sdpa" and torch.cuda.is_available() and args.attn == "auto":
        major, _ = torch.cuda.get_device_capability(0)
        if major >= 8 and not has_flash_attn():
            print(
                "  ヒント: このGPUは FlashAttention 2 に対応していますが、"
                "flash-attn が未導入のため sdpa を使います。"
            )
            print(
                "          高速化したい場合 (任意): uv pip install --python "
                ".venv/Scripts/python.exe flash-attn --no-build-isolation"
            )

    ref_text_path = pathlib.Path(args.ref_text)
    ref_text = ref_text_path.read_text(encoding="utf-8").strip()

    ref_audio = pathlib.Path(args.ref_audio)
    if not ref_audio.exists():
        raise SystemExit(
            f"参照音声が見つかりません: {ref_audio}\n"
            "先に `python scripts/prepare_reference.py` を実行してください。"
        )

    print(f"\nモデル読み込み中: {args.model}")
    t0 = time.time()
    model = Qwen3TTSModel.from_pretrained(
        args.model,
        device_map=args.device,
        dtype=dtype,
        attn_implementation=attn,
    )
    print(f"読み込み完了 ({time.time() - t0:.1f}s)")

    print(f"\n参照音声 : {ref_audio}")
    print(f"参照テキスト: {ref_text[:60]}...")
    print(f"生成テキスト: {args.text}")

    t0 = time.time()
    wavs, sr = model.generate_voice_clone(
        text=args.text,
        language=args.language,
        ref_audio=str(ref_audio),
        ref_text=ref_text,
    )
    gen_s = time.time() - t0

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    sf.write(out, wavs[0], sr)

    dur = len(wavs[0]) / sr
    print(f"\n出力: {out}")
    print(f"長さ {dur:.2f}s / 生成 {gen_s:.1f}s (RTF {gen_s / dur:.2f}) / sr={sr}")
    if torch.cuda.is_available():
        print(f"VRAM ピーク: {torch.cuda.max_memory_allocated() / 1024**3:.2f} GiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
