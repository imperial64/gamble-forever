# Syntax-checks the addon, runs the tests, and copies it into the WoW Forever AddOns folder.
#   .\scripts\install-addon.ps1 [-WowRoot "F:\World of Warcraft"]
param([string]$WowRoot = "F:\World of Warcraft")
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo "addons\GambleForever"

foreach ($f in Get-ChildItem $src -Filter *.lua) {
    luajit -bl $f.FullName | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Lua syntax error in $($f.Name) - not installing." }
}
# Forever draws palette PNGs below 8 bits as solid green: only 8-bit RGB (2) or RGBA (6) ship.
foreach ($p in Get-ChildItem $src -Recurse -Filter *.png) {
    $b = [IO.File]::ReadAllBytes($p.FullName)
    if ($b[24] -ne 8 -or ($b[25] -ne 2 -and $b[25] -ne 6)) {
        Write-Error "$($p.Name) is not 8-bit RGB/RGBA - run python scripts/fix-png.py. Not installing."
    }
}
Push-Location $repo
luajit tests/run.lua | Select-Object -Last 1
$rules = $LASTEXITCODE
luajit tests/ui_smoke.lua | Select-Object -Last 1
$smoke = $LASTEXITCODE
Pop-Location
if ($rules -ne 0 -or $smoke -ne 0) { Write-Error "Tests failed - not installing." }

$dest = Join-Path $WowRoot "_forever_\Interface\AddOns\GambleForever"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $src "*") $dest -Recurse -Force
Write-Host "Installed -> $dest" -ForegroundColor Green
Write-Host "New texture files need a full client restart; code changes only need /reload." -ForegroundColor Cyan
