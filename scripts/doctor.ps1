<#
.SYNOPSIS
    venv の健全性を診断し、必要なら修復する。

.DESCRIPTION
    このプロジェクトの .venv は「薄い venv」で、インタプリタ本体は
    uv が管理する外部ディレクトリ (%APPDATA%\uv\python\...) にある。
    .venv\Scripts\python.exe は pyvenv.cfg の home を読んでそちらを起動するだけの
    ランチャーなので、外部のベース Python が一瞬でも参照できないと次のエラーで落ちる:

        No Python at '"C:\Users\...\uv\python\cpython-3.12.11-...\python.exe'

    CPython のランチャーは存在確認の失敗理由を区別せず、
    アクセスが一時的に弾かれただけでも「無い」と報告する。
    そのため、まず数回リトライして一過性かどうかを切り分ける。

    Python ではなく PowerShell で書いてあるのは、
    診断対象の Python が壊れている状況で使うため。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
    診断のみ。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1 -Repair
    ベース Python が失われていれば uv で入れ直す。
    .venv\Lib\site-packages はそのまま残るので、torch 等の再インストールは不要。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1 -MakeStandalone
    ベース Python をプロジェクト内 (python-base\) に複製し、
    %APPDATA%\uv への依存を断ち切る。約90MB増えるが、
    uv 側の更新・削除・クリーンアップの影響を受けなくなる。
#>
[CmdletBinding()]
param(
    [switch]$Repair,
    [switch]$MakeStandalone
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $root '.venv'
$cfg = Join-Path $venv 'pyvenv.cfg'
$venvPy = Join-Path $venv 'Scripts\python.exe'

$problems = @()

function Say($msg)  { Write-Host $msg }
function Ok($msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Bad($msg)  { Write-Host "  [NG]   $msg" -ForegroundColor Red }
function Warn($msg) { Write-Host "  [注意] $msg" -ForegroundColor Yellow }

Say ""
Say "=== Qwen3-TTS 環境診断 ==="
Say "プロジェクト: $root"
Say ""

# --- 1. venv 本体 ---------------------------------------------------------
Say "[1] venv の存在"
if (-not (Test-Path $cfg)) {
    Bad "pyvenv.cfg がありません: $cfg"
    Say ""
    Say "venv 自体が失われています。README の「環境が壊れているとき」に従って再構築してください。"
    exit 1
}
if (-not (Test-Path $venvPy)) {
    Bad "python.exe がありません: $venvPy"
    exit 1
}
Ok "$venv"

# --- 2. pyvenv.cfg の home ------------------------------------------------
Say ""
Say "[2] ベース Python の参照先 (pyvenv.cfg の home)"
$home_ = $null
foreach ($line in Get-Content $cfg) {
    if ($line -match '^\s*home\s*=\s*(.+?)\s*$') { $home_ = $Matches[1] }
}
if (-not $home_) {
    Bad "pyvenv.cfg に home がありません"
    exit 1
}
Say "  home = $home_"
$basePy = Join-Path $home_ 'python.exe'

# --- 3. ベース Python の到達性（リトライ付き） ----------------------------
Say ""
Say "[3] ベース Python の到達性"
$found = $false
for ($i = 1; $i -le 5; $i++) {
    if (Test-Path $basePy) { $found = $true; break }
    Warn "見つかりません (試行 $i/5) — 一時的なアクセス失敗の可能性。1秒待って再試行します"
    Start-Sleep -Seconds 1
}

if ($found) {
    Ok "$basePy"
    if ($i -gt 1) {
        Warn "初回は見えませんでした。ウイルス対策のスキャン等による一過性の事象と思われます"
        Warn "頻発するなら -MakeStandalone で %APPDATA% への依存を切ることを検討してください"
    }
} else {
    Bad "$basePy が見つかりません"
    $problems += 'base-missing'
    if ($Repair) {
        Say ""
        Say "  → uv でベース Python を入れ直します (パッケージは再インストール不要)"
        uv python install 3.12
        if (Test-Path $basePy) {
            Ok "復旧しました"
            $problems = $problems | Where-Object { $_ -ne 'base-missing' }
        } else {
            Bad "復旧できませんでした"
            $installed = (uv python list --only-installed) -join "`n"
            Say ""
            Say "  uv が認識している Python:"
            Say "  $installed"
            Say ""
            Say "  バージョンが変わっている場合は pyvenv.cfg の home を実際のパスに書き換えてください。"
            exit 1
        }
    } else {
        Say ""
        Say "  → 修復するには: powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1 -Repair"
        exit 1
    }
}

# --- 4. venv の python が起動するか ---------------------------------------
Say ""
Say "[4] venv の Python 起動確認"
$out = & $venvPy -c "import sys; print(sys.version.split()[0])"
if ($LASTEXITCODE -eq 0) {
    Ok "Python $out"
} else {
    Bad "起動に失敗しました (終了コード $LASTEXITCODE)"
    exit 1
}

# --- 5. torch と CUDA ------------------------------------------------------
Say ""
Say "[5] PyTorch と CUDA"
# 複数行のコードは -c で渡さず一時ファイルにする。
# PowerShell はネイティブコマンドへの改行入り引数をうまく渡せないため。
$probe = @'
import torch, torchaudio
print("torch=" + torch.__version__ + " torchaudio=" + torchaudio.__version__ + " cuda=" + str(torch.cuda.is_available()))
if torch.cuda.is_available():
    cap = torch.cuda.get_device_capability(0)
    print("gpu=" + torch.cuda.get_device_name(0) + " sm_" + str(cap[0]) + str(cap[1]))
'@
$tmp = Join-Path $env:TEMP "qwen3tts_probe_$PID.py"
Set-Content -Path $tmp -Value $probe -Encoding utf8
$t = & $venvPy $tmp
$rc = $LASTEXITCODE
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
if ($rc -ne 0) {
    Bad "torch を import できません"
    Say ""
    Say "  → README の「環境が壊れているとき」に従って入れ直してください"
    exit 1
}
foreach ($line in $t) { Say "  $line" }
# $t は配列。配列に対する -match は「一致した要素」を返すため、
# 単一文字列に連結してから判定しないと誤検知する。
$tj = ($t -join "`n")
if ($tj -match 'cuda=True') {
    Ok "CUDA 有効"
} else {
    Bad "CUDA が無効です"
    Warn "torch が CPU 版に置き換わっている可能性があります (バージョンに +cu126 が付いているか確認)"
    $problems += 'no-cuda'
}
if ($tj -notmatch '\+cu') {
    Warn "torch が CPU ビルドです。CUDA 版を入れ直してください:"
    Say '    $env:VIRTUAL_ENV="$PWD\.venv"; uv pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu126'
}

# --- 6. qwen_tts -----------------------------------------------------------
Say ""
Say "[6] qwen-tts"
$null = & $venvPy -c "import qwen_tts"
if ($LASTEXITCODE -eq 0) {
    Ok "import 成功"
} else {
    Bad "import できません (終了コード $LASTEXITCODE)"
    Say "  詳細: .venv\Scripts\python.exe -c \"import qwen_tts\" を直接実行して確認してください"
    $problems += 'no-qwen-tts'
}

# --- 7. スタンドアロン化 ---------------------------------------------------
if ($MakeStandalone) {
    Say ""
    Say "[7] スタンドアロン化"
    $dest = Join-Path $root 'python-base'
    if (Test-Path $dest) {
        Warn "$dest は既に存在します。スキップします"
    } else {
        Say "  $home_"
        Say "    → $dest へ複製中..."
        Copy-Item -Path $home_ -Destination $dest -Recurse -Force
        Copy-Item -Path $cfg -Destination "$cfg.bak" -Force
        $new = Get-Content $cfg | ForEach-Object {
            if ($_ -match '^\s*home\s*=') { "home = $dest" } else { $_ }
        }
        Set-Content -Path $cfg -Value $new -Encoding utf8
        $v = & $venvPy -c "import sys; print(sys.base_prefix)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Ok "完了。base_prefix = $v"
            Say "  (元の pyvenv.cfg は $cfg.bak に退避してあります)"
        } else {
            Bad "起動できなくなったため元に戻します"
            Copy-Item -Path "$cfg.bak" -Destination $cfg -Force
            Remove-Item -Recurse -Force $dest
        }
    }
}

# --- まとめ ----------------------------------------------------------------
Say ""
if ($problems.Count -eq 0) {
    Say "=== 問題なし。音声生成を実行できます ==="
    Say ""
    Say '  .venv\Scripts\python.exe -u scripts\voice_clone.py --text "テキスト" --out output\test.wav'
} else {
    Say "=== 未解決の問題: $($problems -join ', ') ==="
}
Say ""
