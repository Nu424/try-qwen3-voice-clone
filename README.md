# Qwen3-TTS 音声クローン検証

[Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) の `Qwen3-TTS-12Hz-1.7B-Base` を使い、
数十秒の参照音声だけでその声を再現する**ゼロショット音声クローン**をローカルGPUで動かす検証環境。
話者ごとの追加学習は不要。

セットアップ手順は [note記事](https://note.com/npaka/n/nda90baec71aa) を出発点に、
実環境で動くよう修正したもの（[変更点](#記事のサンプルコードからの変更点)）。

---

## セットアップ

### 必要なもの

| | 要件 |
|---|---|
| OS | Windows 10 / 11（スクリプトは PowerShell とWindowsパス前提） |
| GPU | NVIDIA製、**VRAM 6GB以上**。対応範囲は [GPUの対応状況](#gpuの対応状況) を参照 |
| RAM | 16GB以上を推奨。少ないと[ロード時に落ちる](#oserror-ページング-ファイルが小さすぎるため-os-error-1455)ことがある |
| ディスク | 約10GB（仮想環境 約5GB + モデル 約4.2GB） |
| [uv](https://docs.astral.sh/uv/) | Python環境の構築に使用 |
| ffmpeg | 参照音声の変換と出力の確認に使用。`PATH` に通っていること |

uv と ffmpeg が入っているかの確認:

```bash
uv --version
ffmpeg -version
```

uv が無ければ [公式手順](https://docs.astral.sh/uv/getting-started/installation/) で導入する。
Python 自体は uv が自動で用意するので、事前インストールは不要。

### 1. 取得

```bash
git clone <このリポジトリのURL>
cd try-qwen3-voice-clone
```

### 2. 仮想環境を作る

```bash
uv venv --python 3.12 .venv
```

### 3. PyTorch（CUDA版）を入れる

**必ずこれを先に、専用インデックスから入れること。** 順序を逆にすると、
次の手順で PyPI の CPU版 torch が入ってしまい GPU が使われなくなる。

```bash
uv pip install --python .venv/Scripts/python.exe torch torchaudio --index-url https://download.pytorch.org/whl/cu126
```

> RTX 50 系（Blackwell）を使う場合は `cu126` を `cu128` に読み替える。
> 詳細は [GPUの対応状況](#gpuの対応状況)。

### 4. qwen-tts を入れる

```bash
uv pip install --python .venv/Scripts/python.exe qwen-tts soundfile
```

### 5. 参照音声を置く

`reference/` に次の2つを置く。詳しい条件は [reference/README.md](reference/README.md) を参照。

| ファイル | 内容 |
|---|---|
| `reference_audio.wav` | クローンしたい声の音声。**話者1人・ノイズ少なめ・3〜15秒**が目安 |
| `reference_text.txt` | その音声の書き起こし（UTF-8）。**音声と正確に一致していること** |

書き起こしのズレが品質に最も響くので、ここは丁寧に。

### 6. 参照音声を前処理する

モノラル・24kHz に変換する（モデルがこの形式を前提とするため）。

```bash
.venv/Scripts/python.exe scripts/prepare_reference.py
```

### 7. 生成する

```bash
.venv/Scripts/python.exe -u scripts/voice_clone.py --text "こんにちは。音声クローンのテストです。" --out output/test.wav
```

**初回はモデルのダウンロード（約4.2GB）が走る**ため数分かかる。2回目以降はキャッシュされる。

`-u`（非バッファ出力）を付けているのは、途中で落ちた際にログが失われないようにするため。
詳細は[トラブルシュート](#出力が途中で消えるログが尻切れになる)。

### 8. うまくいかないときは

```bash
powershell -ExecutionPolicy Bypass -File scripts/doctor.ps1
```

仮想環境・ベースPython・CUDA・qwen-tts をまとめて診断する。`-Repair` で自動修復。

---

## 使い方

```bash
.venv/Scripts/python.exe -u scripts/voice_clone.py --text "喋らせたい文章" --out output/result.wav
```

| オプション | 既定 | 用途 |
|---|---|---|
| `--text` | サンプル文 | 生成するテキスト |
| `--out` | `output/voice_clone.wav` | 出力先 |
| `--ref-audio` / `--ref-text` | `reference/` 配下 | 参照の差し替え |
| `--language` | `Japanese` | `Auto` や `English` なども可（対応10言語） |
| `--seed` | なし | 結果を再現したいときに指定 |
| `--model` | `Qwen/Qwen3-TTS-12Hz-1.7B-Base` | `...-0.6B-Base` で軽量化 |
| `--dtype` / `--attn` | 自動判定 | 通常は指定不要 |

### 結果が毎回変わるのは正常

モデルの `generation_config.json` は `do_sample: true`, `temperature: 0.9` なので、
同じ入力でも出力が変わる。自然な抑揚のために必要な性質。

実用上は複数生成して選ぶのが早い:

```bash
for i in 1 2 3 4 5; do
  .venv/Scripts/python.exe -u scripts/voice_clone.py --seed $i --text "..." --out output/take_$i.wav
done
```

気に入ったテイクは `--seed` の値で再現できる。

---

## GPUの対応状況

`scripts/voice_clone.py` は GPU の compute capability と、
flash-attn パッケージの有無を見て設定を自動で切り替える。
そのため**下表のGPUでは、コードを書き換えずにそのまま動く**。

| GPU 例 | compute capability | 状態 | 備考 |
|---|---|---|---|
| GTX 1660 Ti / RTX 20系 | sm_75 (Turing) | **実機検証済み** | bf16 のテンソルコアが無く演算は fp32 に落ちる。RTF 約4 |
| RTX 3060 / 30系 | sm_86 (Ampere) | 動作する見込み | bf16 がネイティブに効くのでこの環境より高速なはず |
| RTX 40系 | sm_89 (Ada) | 動作する見込み | sm_86 のバイナリが上位互換で動作する |
| RTX 50系 | sm_120 (Blackwell) | **cu128 が必要** | cu126 ビルドに sm_120 のコードが無い。下記参照 |

> **検証範囲について**: 実機で確認できたのは GTX 1660 Ti のみ。
> 他は PyTorch が同梱するアーキテクチャ一覧（`torch.cuda.get_arch_list()`）と
> コードの分岐を追って判断したもので、実機テストはしていない。

### VRAM

1.7B モデルの実測ピークは **5.16 GiB**。支配的なのは重みそのもの（約3.6GiB）なので、
参照音声を短くしてもほとんど減らない。6GB のGPUでは他のGPU使用アプリを閉じておくこと。
12GB 以上あれば余裕がある。

足りない場合は `--model Qwen/Qwen3-TTS-12Hz-0.6B-Base` に落とす。

### RTX 50系（Blackwell）を使う場合

PyTorch の cu126 ビルドには sm_120 向けのコードが含まれておらず、
PTX による将来アーキ向けのフォールバックも同梱されていない。cu128 を使う:

```bash
uv pip install --python .venv/Scripts/python.exe --reinstall torch torchaudio --index-url https://download.pytorch.org/whl/cu128
```

スクリプトは起動時にこの不一致を検知して警告を出す。

### FlashAttention 2 について（任意）

Ampere (sm_80) 以降なら FlashAttention 2 で高速化できるが、**本手順では導入していない**。
未導入の場合はスクリプトが自動的に `sdpa`（PyTorch標準の実装）を選ぶので、そのまま動く。

導入したい場合:

```bash
uv pip install --python .venv/Scripts/python.exe flash-attn --no-build-isolation
```

Windows ではビルドに CUDA Toolkit と MSVC が必要で時間もかかる。
失敗しても `sdpa` で動くので、無理に入れなくてよい。

---

## 記事のサンプルコードからの変更点

元記事のコードは、この環境ではそのまま動かなかった。

| 記事 | このリポジトリ | 理由 |
|---|---|---|
| `attn_implementation="flash_attention_2"` | 自動判定（既定 `sdpa`） | FlashAttention 2 は Ampere 以降かつ flash-attn 導入済みでないと使えない。**GPUが対応していてもパッケージが無ければ ImportError で落ちる** |
| `dtype=torch.bfloat16` | `torch.bfloat16`（据え置き） | 記事のままが正しい。**float16 に変えてはいけない**（下記） |

### float16 にしてはいけない

配布チェックポイントは **BF16 で保存**されている（`model.safetensors` 3.59 GiB / 全480テンソルが BF16）。
`float16` を指定すると**ロード時に CPU 側で 3.4 GiB の変換コピー**が発生し、
mmap 分と合わせて約 7 GiB のメモリ確保を要求する。RAM の少ない環境ではここで落ちる。

「Turing は bf16 非対応だから float16 にすべき」は誤り。Turing に bf16 のテンソルコアが
無いのは事実だが、PyTorch は内部で fp32 に変換して計算するので動作する。
速度の利点が無いだけで、メモリ面では BF16 のまま読む方が有利。

**GPU世代から dtype を機械的に決めず、チェックポイントの dtype に合わせるのが原則。**

---

## 実測結果

`Qwen3-TTS-12Hz-1.7B-Base` / bfloat16 / sdpa / 参照音声33.7秒 / GTX 1660 Ti:

| 項目 | 値 |
|---|---|
| モデル読み込み | 初回 73.7秒（ダウンロード込み） / 2回目以降 11〜18秒 |
| 生成 | RTF 4.0〜5.1（6秒の音声に25秒程度） |
| VRAM ピーク | 5.16 GiB / 6.0 GiB |
| 出力 | 24kHz / モノラル / PCM 16bit |

RTF 4 はこのGPUでは妥当な値。自己回帰生成でフレームごとに全重みを読み出すため
メモリ帯域が律速になる。

---

## リポジトリ構成

```
scripts/
  voice_clone.py        生成本体
  prepare_reference.py  参照音声をモノラル24kHzに変換
  doctor.ps1            環境の診断・修復（PowerShell）
reference/              参照音声の置き場所（中身は非公開）
output/                 生成音声の出力先（非公開）
README.md               このファイル
EXPLAINER.md            技術解説
.claude/skills/         Claude Code 用スキル
```

`reference/` と `output/` は `.gitignore` で除外している。
個人の声や生成物が意図せず公開されないようにするため。

---

## ドキュメント

- **[EXPLAINER.md](EXPLAINER.md)** — 技術解説。音声クローンの仕組み、モデルの実構造、
  BF16/FP16 とメモリの関係、FlashAttention と GPU 世代、VRAM の内訳、速度の理由
- **[reference/README.md](reference/README.md)** — 参照音声の条件と置き方
- **[.claude/skills/qwen3-tts-voice-clone/SKILL.md](.claude/skills/qwen3-tts-voice-clone/SKILL.md)**
  — Claude Code 用スキル。音声合成を依頼すると自動で参照される

---

## トラブルシュート

### `OSError: ページング ファイルが小さすぎるため...` (os error 1455)

**まず `--dtype float16` を指定していないか確認する。** これが最頻の原因
（理由は[上記](#float16-にしてはいけない)）。

指定していないのに出る場合は、メモリを使っているアプリを閉じる。
それでも解消しなければ Windows のページングファイルを拡張する
（システムのプロパティ → 詳細設定 → パフォーマンス → 仮想メモリ）。

### `No Python at '"C:\Users\...\uv\python\...\python.exe'`

まず診断する:

```bash
powershell -ExecutionPolicy Bypass -File scripts/doctor.ps1
```

`.venv\Scripts\python.exe` はインタプリタ本体ではなく、`pyvenv.cfg` の `home` に
書かれた外部の Python を起動するだけのランチャー。その参照先が一瞬でも読めないと
このエラーになる。CPython のランチャーは失敗理由を区別しないため、
**ファイルが実在していてもアクセスが一時的に弾かれれば「無い」と報告する**
（ウイルス対策のスキャン中など）。診断が通るなら一過性なので、そのまま再実行してよい。
エラー内の閉じていない `"` は CPython の書式の癖で、異常の証拠ではない。

本当に失われている場合の復旧:

```bash
powershell -ExecutionPolicy Bypass -File scripts/doctor.ps1 -Repair
```

`uv python install 3.12` を実行するだけで、**`.venv/Lib/site-packages` は無傷**。
torch など5GB超の再インストールは不要。

再発を防ぎたい場合は、ベースPythonをプロジェクト内に複製して依存を断てる（約90MB増）:

```bash
powershell -ExecutionPolicy Bypass -File scripts/doctor.ps1 -MakeStandalone
```

### CUDA out of memory

1. GPUを使っている他アプリ（ブラウザ、ゲーム）を閉じる
2. `--model Qwen/Qwen3-TTS-12Hz-0.6B-Base` に落とす
3. 生成テキストを分割する

現在の使用状況は `nvidia-smi` で確認できる。

### torch が CPU 版になっている

`torch.cuda.is_available()` が `False`、またはバージョンに `+cpu` が付いている場合、
セットアップの手順3と4を逆にした可能性が高い。CUDA版を入れ直す:

```bash
uv pip install --python .venv/Scripts/python.exe --reinstall torch torchaudio --index-url https://download.pytorch.org/whl/cu126
```

### 出力が途中で消える・ログが尻切れになる

出力をパイプすると Python がブロックバッファリングになり、
強制終了された際に出力が丸ごと失われる。「終了コード0なのに何も起きていない」
ように見えて原因を見失う。

```bash
# 悪い例 — 落ちるとログが消え、$? もパイプ先のものになる
.venv/Scripts/python.exe scripts/voice_clone.py | tail -40

# 良い例 — 非バッファ出力 + ファイルへリダイレクト
.venv/Scripts/python.exe -u scripts/voice_clone.py > run.log 2>&1
echo "EXIT=$?"
```

### 実行中にセグメンテーション違反で落ちる

生成中に**別のプロセスが同じ環境やGPUに触れる**と落ちることがある。
このリポジトリでの再現例:

- 生成中に `uv pip install` / `uninstall` で venv を書き換えた
- 生成中に `doctor.ps1` を実行した（内部で torch と CUDA を初期化するため）

VRAM 実測 5.16 / 6.0 GiB とほぼ満杯なので、別プロセスが CUDA コンテキストを
作ろうとすると破綻しやすい。**生成中はパッケージ操作も診断も走らせないこと。**
VRAM に余裕のあるGPU（12GB以上）ではあまり起きないと考えられる。

### 無視してよい警告

これらが出ても生成は正常に完了する。

- `SoX could not be found!` — `sox` パッケージが外部バイナリを探す警告。この推論経路では使われない
- `Warning: flash-attn is not installed.` — 想定どおり。`sdpa` にフォールバックする
- `Xet Storage is enabled ... 'hf_xet' package is not installed` — ダウンロードが通常HTTPになるだけ

---

## ライセンス

このリポジトリのコードとドキュメントは **MIT License**（[LICENSE](LICENSE)）。
Copyright (c) 2026 jidouka-kenkyukai

ただし**モデルの重みはこのライセンスの対象外**。
`Qwen/Qwen3-TTS-12Hz-1.7B-Base` の利用条件は
[配布元](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base)の規約に従うこと。

## 利用上の注意

**他人の声をクローンする場合は、必ず本人の同意を得ること。**
音声クローンはなりすましや詐欺に悪用されうる技術であり、
無断での利用は法的・倫理的な問題になりうる。
