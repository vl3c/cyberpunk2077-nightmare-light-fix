# Builds NightmareLightFix.archive for game 2.5 from the nightmare files of Deceptious Bug Fixes 1.4.3.
# Read only for the game and the Deceptious archive; writes only into .\build next to this script.
#
# Usage (PowerShell; keep the quotes, an unquoted argument starting with # is a comment):
#   powershell -ExecutionPolicy Bypass -File build.ps1 -DbfArchive "<path>\#DeceptiousBugFixes.archive"
# Options:
#   -Game "<Cyberpunk 2077 folder>"  for the game's Oodle DLL (default: the Epic Games path; Steam/GOG users pass theirs)
#   -Python "<command>"              Python 3 to use (default: the py launcher if installed, else python)
#   -Force                           build even if the Deceptious files are not the tested 1.4.3 versions
param(
  [Parameter(Mandatory=$true)][string]$DbfArchive,
  [string]$Game = "C:\Program Files\Epic Games\Cyberpunk2077",
  [string]$Python = "",
  [switch]$Force
)
$ErrorActionPreference = "Stop"

function Resolve-Full([string]$p, [string]$what) {
  $p = $p.Trim().TrimEnd('"').TrimEnd('\')
  if (-not (Test-Path -LiteralPath $p)) { throw "$what not found: $p" }
  # .NET and Python don't understand ~, PowerShell drives or PowerShell's current folder
  return (Resolve-Path -LiteralPath $p).ProviderPath
}

$here = $PSScriptRoot
$tools = Join-Path $here "tools"
$work = Join-Path $here "build\work"
$out = Join-Path $here "build\NightmareLightFix"
$DbfArchive = Resolve-Full $DbfArchive "Deceptious archive"
$Game = Resolve-Full $Game "Game folder (set -Game)"
$oodle = Resolve-Full (Join-Path $Game "bin\x64\oo2ext_7_win64.dll") "Oodle DLL in the game folder (set -Game)"

# Python: an explicit -Python wins; otherwise prefer the py launcher (python can be the Microsoft Store stub)
if ($Python -ne "") { $pyCmd = @($Python) }
elseif (Get-Command py -ErrorAction SilentlyContinue) { $pyCmd = @("py", "-3") }
else { $pyCmd = @("python") }
$pyExe = $pyCmd[0]; $pyArgs = @($pyCmd | Select-Object -Skip 1)
$pyOk = $false
try { & $pyExe @pyArgs -c "import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)"; $pyOk = ($LASTEXITCODE -eq 0) } catch { $pyOk = $false }
if (-not $pyOk) { throw "Python 3 not found as '$($pyCmd -join ' ')'. Install Python 3 or pass -Python <command>." }

# Files taken from the Deceptious archive (by path hash):
#   4757bc419db4dc98 base\worlds\nightmare.streamingsector (red lights; tuned and converted below)
#   3df856f1a18034eb base\worlds\nightmare.streamingblock  (copied as is)
#   c85aed0fb1a98f32 q101_07c_johnny_triggers.scene         (copied as is)
#   1e259895a55c5560 q101 quest phase with the nightmare step (copied as is)
# The tuning rules were written for these exact 1.4.3 bytes, so other versions stop unless -Force is given.
$sectorPath = "base\worlds\nightmare.streamingsector"
$expected = [ordered]@{
  "base_worlds_nightmare.streamingsector" = "640de136986c8ca87385ada37d988b8f5b4da14c27fc28cf64838d85e19b8913";
  "base_worlds_nightmare.streamingsector.buffer1" = "0be9ec33d4c6660265626a1a3f7f212860c20862c82fe07bc4d58c6c857c7958"
}

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null
& (Join-Path $tools "extract-rdar.ps1") -Archive $DbfArchive -Out $work -Paths $sectorPath -Oodle $oodle
foreach ($k in $expected.Keys) {
  $f = Join-Path $work $k
  if (-not (Test-Path -LiteralPath $f)) { throw "extraction failed, missing $k (is this the Deceptious Bug Fixes archive?)" }
  $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
  if ($h -ne $expected[$k]) {
    $msg = "$k has sha256 $h, but this build was made for $($expected[$k]) (Deceptious Bug Fixes 1.4.3)"
    if ($Force) { Write-Warning "$msg; continuing because of -Force" } else { throw "$msg. Use -Force to try anyway." }
  }
}

$main = Join-Path $work "base_worlds_nightmare.streamingsector"
$tunedMain = Join-Path $work "tuned.main"
$tunedBuf = Join-Path $work "tuned.buffer1"
& $pyExe @pyArgs -I (Join-Path $tools "tune-nightmare.py") $main ($main + ".buffer1") $tunedMain $tunedBuf
if ($LASTEXITCODE -ne 0) { throw "tune-nightmare.py failed (exit code $LASTEXITCODE)" }

$archDir = Join-Path $out "archive\pc\mod"
$scriptDir = Join-Path $out "r6\scripts\NightmareLightFix"
New-Item -ItemType Directory -Force -Path $archDir, $scriptDir | Out-Null
$archive = Join-Path $archDir "NightmareLightFix.archive"
& $pyExe @pyArgs -I (Join-Path $tools "convert-sector-25.py") $DbfArchive $archive 4757bc419db4dc98 $tunedMain $tunedBuf 1e259895a55c5560 3df856f1a18034eb c85aed0fb1a98f32
if ($LASTEXITCODE -ne 0) { throw "convert-sector-25.py failed (exit code $LASTEXITCODE)" }
Copy-Item -LiteralPath (Join-Path $here "mod\archive\pc\mod\NightmareLightFix.archive.xl") -Destination $archDir
Copy-Item -LiteralPath (Join-Path $here "mod\r6\scripts\NightmareLightFix\NightmareLightFix.reds") -Destination $scriptDir
$sha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
Write-Host ""
Write-Host "Built $out"
Write-Host "NightmareLightFix.archive sha256 $sha"
Write-Host "Install: copy the archive and r6 folders from build\NightmareLightFix into the game folder."
Write-Host "Personal use only: the archive contains Deceptious's quest files, don't redistribute it without their permission."
