---
name: qwen3-tts-voice-clone
description: Qwen3-TTS によるローカル音声合成・音声クローン（ゼロショット）の実行手順。参照音声の前処理から生成、GPU世代ごとの設定、失敗時の切り分けまでを扱う。「この声で喋らせて」「音声をクローンして」「テキストを読み上げて」「TTSで音声を作って」「ナレーションを生成して」「サンプルボイスから音声合成」といった依頼のほか、wav ファイルと読み上げテキストを渡されて音声を作るよう頼まれた場合、生成音声の品質・速度・VRAM を改善したい場合にも必ず使うこと。「音声合成」「TTS」「voice clone」「読み上げ」「ナレーション」の語が出たら、Qwen3-TTS と明示されていなくても、まずこのスキルを参照する。
---

# Qwen3-TTS 音声クローン

このプロジェクトには構築済みの Qwen3-TTS 環境がある。**新しく環境を作らず、既存のものを使う。**

| | |
|---|---|
| 実行系 | `.venv/Scripts/python.exe`（uv 管理・Python 3.12） |
| モデル | `Qwen/Qwen3-TTS-12Hz-1.7B-Base`（初回のみ約4.2GB DL、以降キャッシュ） |
| 生成スクリプト | `scripts/voice_clone.py` |
| 前処理スクリプト | `scripts/prepare_reference.py` |
| 出力 | 24kHz / モノラル / PCM 16bit の wav |

技術的な背景（BF16の理由、12Hzトークナイザの仕組み、VRAM内訳など）は
[EXPLAINER.md](../../../EXPLAINER.md) にある。**設定の理由を問われたらそちらを読む。**

---

## 基本の流れ

音声クローンには「参照音声」と「その書き起こしテキスト」の**両方**が要る。
音だけでは声と発話内容を分離できないため、書き起こしは必須で、
かつ**音声の内容と正確に一致していること**が品質を左右する。

### 1. 参照音声を前処理する

モデルは 24kHz・モノラルを前提とする。まず実際の形式を確認する:

```bash
ffprobe -v error -show_entries format=duration -show_entries stream=sample_rate,channels -of default=noprint_wrappers=1 <参照音声>
```

変換:

```bash
.venv/Scripts/python.exe scripts/prepare_reference.py
```

別のファイルを使う、または長さを切る場合:

```bash
.venv/Scripts/python.exe scripts/prepare_reference.py --src path/to/audio.wav --dst reference/my_ref.wav --start 0 --duration 12
```

### 2. 生成する

```bash
.venv/Scripts/python.exe -u scripts/voice_clone.py --text "喋らせたい文章" --out output/result.wav
```

`-u` を付ける理由は後述（[出力が途中で消える](#出力が途中で消えるログが尻切れになる)）。

主なオプション:

| オプション | 既定 | 用途 |
|---|---|---|
| `--text` | サンプル文 | 生成するテキスト |
| `--out` | `output/voice_clone.wav` | 出力先 |
| `--ref-audio` / `--ref-text` | `reference/` 配下 | 参照の差し替え |
| `--language` | `Japanese` | `Auto` や `English` 等も可 |
| `--seed` | なし（毎回変化） | 結果を再現したいとき |
| `--model` | 1.7B-Base | `--model Qwen/Qwen3-TTS-12Hz-0.6B-Base` で軽量化 |
| `--dtype` / `--attn` | 自動判定 | 通常触らない |

### 3. 結果を検証する

**生成音声は聴けない前提で、機械的に確認できることを必ず確認する:**

```bash
ffprobe -v error -show_entries format=duration -show_entries stream=sample_rate,channels -of default=noprint_wrappers=1 output/result.wav
ffmpeg -v info -i output/result.wav -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume"
```

見るべき点:

- **長さが妥当か** — テキストの文字数に対して極端に短い/長いのは生成の失敗を示す。日本語なら概ね 6〜8 文字/秒
- **無音でないか** — `mean_volume` が -60dB を下回るなら生成が壊れている
- **クリップしていないか** — `max_volume` が 0dB ちょうどなら歪んでいる可能性

そのうえで、**声の類似性は自分では判断できないので、ユーザーに聴いてもらう**。
生成できたことと似ていることを混同して報告しない。

---

## 参照音声の選び方

品質の大半はここで決まる。モデルの都合は次のとおり:

| 条件 | 理由 |
|---|---|
| 話者が1人だけ | 話者エンコーダは音声全体から1つのベクトルを作る。混ざると平均化され誰にも似ない |
| ノイズ・BGMが少ない | ノイズも「その話者の特徴」として取り込まれ、生成音声に乗る |
| 3〜15秒が公式推奨 | 短いと特徴を捉えられず、長いとプロンプトが伸びて遅くなる |
| 書き起こしが音声と一致 | ズレると声と内容の対応が壊れ、品質が落ちる |

### 推奨長より長い音声を渡されたとき

**書き起こしが全長に対応しているなら、切らずに全長を使う方がよい。**
中途半端に切ると音声とテキストがズレ、「推奨内に収まる」利点を上回る害になる。
33秒程度なら実測で問題なく動く。

どうしても切るなら、**書き起こしも対応する範囲に手で合わせること**。
文の切れ目は無音検出で探せる:

```bash
ffmpeg -v info -i <音声> -af silencedetect=noise=-40dB:d=0.12 -f null - 2>&1 | grep silence_
```

閾値は素材に応じて調整する。`-50dB / 0.3秒` で何も出なくても、
`-40dB / 0.12秒` に緩めると間が見つかることがある。**1回試して出ないだけで
「BGMが鳴っている」と結論しない。**

---

## 結果が安定しない・気に入らないとき

`generation_config.json` は `do_sample: true`, `temperature: 0.9` なので、
**同じ入力でも毎回結果が変わる**。これは自然な抑揚のために必要な性質で、異常ではない。

現実的な運用は「複数生成して選ぶ」:

```bash
for i in 1 2 3 4 5; do
  .venv/Scripts/python.exe -u scripts/voice_clone.py --seed $i --text "..." --out output/take_$i.wav
done
```

気に入ったテイクは `--seed` の値で再現できる。

品質が全体に悪い場合は、パラメータより先に**参照音声を疑う**。
別の箇所を切り出す、よりノイズの少ない素材に替える方が効果が大きい。

---

## トラブルシュート

### `OSError: ページング ファイルが小さすぎるため...` (os error 1455)

**まず `--dtype float16` を指定していないか確認する。** これが最頻の原因。

配布チェックポイントは BF16 で保存されている。fp16 を要求するとロード時に
CPU 側で 3.4GiB の変換コピーが発生し、mmap 分と合わせて約7GiB のコミットを要求して、
RAM やページファイルが小さい環境では落ちる。**BF16 のまま読めば変換コピーは起きない。**

`--dtype` を付けていないのに出る場合は、メモリを使っているアプリを閉じる。
それでも駄目ならユーザーに Windows のページングファイル拡張を案内する
（システムのプロパティ → 詳細設定 → パフォーマンス → 仮想メモリ）。
**これはシステム設定の変更なので、自分で実行せずユーザーに依頼すること。**

### `No Python at '"C:\Users\...\uv\python\...\python.exe'`

**最初に診断を走らせる。** 憶測で環境を作り直さないこと:

```bash
powershell -ExecutionPolicy Bypass -File scripts/doctor.ps1
```

`.venv\Scripts\python.exe` はインタプリタ本体ではなく、`pyvenv.cfg` の `home` に
書かれた外部の Python（`%APPDATA%\uv\python\...`）を起動するだけのランチャー。
その参照先が一瞬でも読めないとこのエラーになる。

**重要**: CPython のランチャーは存在確認の失敗理由を区別せず、
アクセスが一時的に弾かれただけでも「無い」と報告する。
つまり**ファイルが実在していてもこのエラーは出る**（ウイルス対策のスキャン中など）。
診断が [OK] を返すなら一過性なので、**そのまま再実行すればよい**。
エラー内の閉じていない `"` は CPython の書式の癖で、異常の証拠ではない。

診断で本当に見つからない場合の復旧:

```bash
powershell -ExecutionPolicy Bypass -File scripts/doctor.ps1 -Repair
```

`uv python install 3.12` でベース Python を入れ直すだけで、
**`.venv/Lib/site-packages` は無傷のまま使える。torch 等 5GB 超の再インストールは不要。**
「venv が壊れた」と判断して丸ごと作り直すのは、時間と帯域の大きな無駄になる。

頻発するなら `-MakeStandalone` でベース Python をプロジェクト内に複製し、
`%APPDATA%\uv` への依存を断てる（約90MB増、`uv pip` は引き続き使える）。

### CUDA out of memory

1.7B は実測で VRAM 5.16 GiB を使う。支配的なのは重みそのもの（約3.6GiB）なので、
**参照音声を短くしてもほとんど効かない。** 効く順に:

1. GPU を使っている他アプリ（ブラウザ、ゲーム）を閉じてもらう
2. `--model Qwen/Qwen3-TTS-12Hz-0.6B-Base` に落とす
3. 生成テキストを分割して複数回に分ける

現在の空き状況は `nvidia-smi` で確認できる。

### 出力が途中で消える・ログが尻切れになる

出力をパイプすると Python がブロックバッファリングになり、
プロセスが強制終了された際に**出力が丸ごと失われる**。
その結果「終了コード0なのに何も起きていない」ように見え、原因を見失う。

```bash
# 悪い例 — 落ちるとログが消え、$? はパイプ先のもの
.venv/Scripts/python.exe scripts/voice_clone.py | tail -40

# 良い例 — 非バッファ出力 + ファイルへリダイレクト、終了コードも正しく取れる
.venv/Scripts/python.exe -u scripts/voice_clone.py > run.log 2>&1
echo "EXIT=$?"
```

長時間かかる処理はバックグラウンド実行し、ログファイルを監視する。

### 実行中にセグメンテーション違反で落ちる

生成中に別プロセスが同じ環境やGPUに触れると落ちる。実際に再現した例:

- 生成中の `uv pip install` / `uninstall`（venv の書き換え）
- 生成中の `doctor.ps1` 実行（内部で torch と CUDA を初期化する）

VRAM が 5.16/6.0 GiB とほぼ満杯なため、別プロセスの CUDA 初期化が破綻しやすい。
**生成中はパッケージ操作も診断も走らせない。** 完了を待ってから行うこと。
コードの不具合と誤診して環境を作り直さないよう注意する。

### 無視してよい警告

これらが出ても生成は正常に完了する。**エラーとして報告しない。**

- `SoX could not be found!` — 外部バイナリを探す警告。今回の推論経路では使われない
- `Warning: flash-attn is not installed.` — 後述のとおり想定内。sdpa にフォールバックする
- `Xet Storage is enabled ... 'hf_xet' package is not installed` — DLが通常HTTPになるだけ

---

## GPU 世代による設定

`scripts/voice_clone.py` は compute capability を見て自動判定するので、
**通常は `--dtype` も `--attn` も指定しない。** 中身は次のとおり:

| 設定 | 判定 | 理由 |
|---|---|---|
| `attn_implementation` | **sm_80 以降 かつ flash-attn 導入済み**なら `flash_attention_2`、それ以外は `sdpa` | FlashAttention 2 は Ampere 以降が必須。さらに**GPUが対応していてもパッケージが無ければ transformers が ImportError を投げる**ので、両方を確認する必要がある |
| `dtype` | 常に `bfloat16` | チェックポイントと同じ dtype にして変換コピーを避ける |

flash-attn は本環境の必須依存ではない。未導入でも `sdpa` で正常に動くので、
「Ampere なのに sdpa が選ばれている」のは異常ではない。

**「Turing は bf16 非対応だから fp16 にする」は誤り。**
Turing に bf16 のテンソルコアが無いのは事実だが、PyTorch は内部で fp32 に変換して計算するので動作する。
速度の利点が無いだけで、メモリ面では BF16 のまま読む方が有利。
GPU世代から dtype を機械的に決めず、**チェックポイントの dtype に合わせる**のが原則。

チェックポイントの dtype は次で確認できる:

```bash
.venv/Scripts/python.exe -c "import sys,json,struct,collections; p=sys.argv[1]; f=open(p,'rb'); n=struct.unpack('<Q',f.read(8))[0]; h=json.loads(f.read(n)); print(collections.Counter(v['dtype'] for k,v in h.items() if k!='__metadata__'))" <model.safetensors のパス>
```

---

## 他のGPUで動かすとき

自動判定があるので**コードの書き換えは不要**。ただし次を確認する:

| GPU | 状態 |
|---|---|
| sm_75 (GTX 16/RTX 20系) | 実機検証済み |
| sm_86 (RTX 30系) / sm_89 (RTX 40系) | 動作する見込み。bf16 がネイティブで効き高速 |
| sm_120 (RTX 50系 / Blackwell) | **cu126 では動かない。** cu128 の PyTorch が必要 |

スクリプトは起動時に `torch.cuda.get_arch_list()` と実GPUの capability を突き合わせ、
非対応なら警告と対処コマンドを表示する。この警告が出たら PyTorch を入れ直す:

```bash
uv pip install --python .venv/Scripts/python.exe --reinstall torch torchaudio --index-url https://download.pytorch.org/whl/cu128
```

VRAM は 1.7B で実測 5.16 GiB。12GB 以上のGPUなら余裕がある。

## 性能の目安（GTX 1660 Ti / 6GiB 実測）

| 項目 | 値 |
|---|---|
| モデル読み込み | 初回 73.7秒（DL込み） / 2回目以降 16.6秒 |
| 生成速度 | RTF 約4（6秒の音声に25秒） |
| VRAM ピーク | 5.16 GiB |

**RTF 4 は「遅い」のではなくこのGPUでは妥当。** 自己回帰生成でフレームごとに
全重みを読み出すためメモリ帯域律速になる。時間がかかっても異常と判断しないこと。
新しめのGPU（Ampere以降）なら FlashAttention 2 と bf16 テンソルコアが効いて大幅に速くなる。

長文を生成する際は所要時間を見積もってユーザーに伝え、バックグラウンドで実行する。

---

## 環境が壊れているとき

**再構築の前に必ず診断を実行する。** ベース Python が失われているだけなら
`-Repair` で済み、5GB のパッケージ再ダウンロードを回避できる:

```bash
powershell -ExecutionPolicy Bypass -File scripts/doctor.ps1 -Repair
```

それでも駄目な場合（`.venv` 自体が無い、`import qwen_tts` が失敗する）の再構築:

```bash
uv venv --python 3.12 .venv
VIRTUAL_ENV=$PWD/.venv uv pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu126
VIRTUAL_ENV=$PWD/.venv uv pip install qwen-tts soundfile
```

**torch を先に CUDA 版で入れる順序が重要。** `qwen-tts` は `torchaudio` に依存するため、
先に入れておかないと PyPI の CPU 版が入り、GPU が使われなくなる。入れた後に必ず確認する:

```bash
.venv/Scripts/python.exe -c "import torch,torchaudio; print(torch.__version__, torchaudio.__version__, torch.cuda.is_available())"
```

`torch.cuda.is_available()` が `True` で、バージョンに `+cu126` が付いていること。
`+cpu` になっていたら CUDA 版を入れ直す。
