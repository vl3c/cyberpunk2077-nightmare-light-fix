# Builds NightmareLightFix.archive for game 2.5 from the nightmare files of Deceptious Bug Fixes 1.2.4.
# Read only for the game and the Deceptious archive; writes only into .\build next to this script.
#
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File build.ps1 -DbfArchive "<path>\#DeceptiousBugFixes.archive"
# Optional: -Game "<Cyberpunk 2077 folder>" (for the game's Oodle DLL), -Python "py"
param(
  [Parameter(Mandatory=$true)][string]$DbfArchive,
  [string]$Game = "C:\Program Files\Epic Games\Cyberpunk2077",
  [string]$Python = "python"
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tools = Join-Path $here "tools"
$work = Join-Path $here "build\work"
$out = Join-Path $here "build\NightmareLightFix"
$oodle = Join-Path $Game "bin\x64\oo2ext_7_win64.dll"
if (-not (Test-Path $DbfArchive)) { throw "Deceptious archive not found: $DbfArchive" }
if (-not (Test-Path $oodle)) { throw "Oodle DLL not found (set -Game): $oodle" }

# Files taken from the Deceptious archive (by path hash):
#   4757bc419db4dc98 base\worlds\nightmare.streamingsector (red lights; converted and tuned below)
#   3df856f1a18034eb base\worlds\nightmare.streamingblock  (copied as is)
#   c85aed0fb1a98f32 q101_07c_johnny_triggers.scene         (copied as is)
#   1e259895a55c5560 q101 quest phase with the nightmare step (copied as is)
$sectorPath = "base\worlds\nightmare.streamingsector"
$expected = @{
  "base_worlds_nightmare.streamingsector" = "640de136986c8ca87385ada37d988b8f5b4da14c27fc28cf64838d85e19b8913";
  "base_worlds_nightmare.streamingsector.buffer1" = "0be9ec33d4c6660265626a1a3f7f212860c20862c82fe07bc4d58c6c857c7958"
}

if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force -Path $work | Out-Null
& (Join-Path $tools "extract-rdar.ps1") -Archive $DbfArchive -Out $work -Paths $sectorPath -Oodle $oodle
foreach ($k in $expected.Keys) {
  $f = Join-Path $work $k
  if (-not (Test-Path $f)) { throw "extraction failed, missing $k" }
  $h = (Get-FileHash -Algorithm SHA256 $f).Hash.ToLower()
  if ($h -ne $expected[$k]) { Write-Warning "$k has sha256 $h, built for $($expected[$k]) (Deceptious Bug Fixes 1.2.4); continuing" }
}

$main = Join-Path $work "base_worlds_nightmare.streamingsector"
$tunedMain = Join-Path $work "tuned.main"
$tunedBuf = Join-Path $work "tuned.buffer1"
& $Python -I (Join-Path $tools "tune-nightmare.py") $main ($main + ".buffer1") $tunedMain $tunedBuf
if ($LASTEXITCODE -ne 0) { throw "tune-nightmare.py failed" }

$archDir = Join-Path $out "archive\pc\mod"
$scriptDir = Join-Path $out "r6\scripts\NightmareLightFix"
New-Item -ItemType Directory -Force -Path $archDir, $scriptDir | Out-Null
& $Python -I (Join-Path $tools "convert-sector-25.py") $DbfArchive (Join-Path $archDir "NightmareLightFix.archive") 4757bc419db4dc98 $tunedMain $tunedBuf 1e259895a55c5560 3df856f1a18034eb c85aed0fb1a98f32
if ($LASTEXITCODE -ne 0) { throw "convert-sector-25.py failed" }
Copy-Item (Join-Path $here "mod\archive\pc\mod\NightmareLightFix.archive.xl") $archDir
Copy-Item (Join-Path $here "mod\r6\scripts\NightmareLightFix\NightmareLightFix.reds") $scriptDir
$sha = (Get-FileHash -Algorithm SHA256 (Join-Path $archDir "NightmareLightFix.archive")).Hash.ToLower()
Write-Host ""
Write-Host "Built $out"
Write-Host "NightmareLightFix.archive sha256 $sha"
Write-Host "Install: copy the archive and r6 folders from build\NightmareLightFix into the game folder."
