# Syntax-checks the addon, runs the tests, and copies it into the WoW Forever AddOns folder.
#   .\scripts\install-addon.ps1 [-WowRoot "F:\World of Warcraft"]
param([string]$WowRoot = "F:\World of Warcraft")
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo "addons\Deathroll"

foreach ($f in Get-ChildItem $src -Filter *.lua) {
    luajit -bl $f.FullName | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Lua syntax error in $($f.Name) - not installing." }
}
Push-Location $repo
luajit tests/run.lua | Select-Object -Last 1
$rules = $LASTEXITCODE
luajit tests/ui_smoke.lua | Select-Object -Last 1
$smoke = $LASTEXITCODE
Pop-Location
if ($rules -ne 0 -or $smoke -ne 0) { Write-Error "Tests failed - not installing." }

$dest = Join-Path $WowRoot "_forever_\Interface\AddOns\Deathroll"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $src "*") $dest -Recurse -Force
Write-Host "Installed -> $dest" -ForegroundColor Green
Write-Host "New texture files need a full client restart; code changes only need /reload." -ForegroundColor Cyan
