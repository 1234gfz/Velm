# 组装可发布的 PBZFog 模组目录（含自包含面板）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\package_release.ps1
#   powershell ... -SkipPublish   # 跳过 dotnet publish，复用 panel\PBZTweaker\_build_out（需要目标机已装 .NET）
#
# 产物：<repo>\_release\PBZFog\{Scripts, PBZTweaker, pbz_tweaker.json, pbz_presets.json, VERSION}
param(
    [string]$Out = '',
    [switch]$SkipPublish,
    [string]$Runtime = 'win-x64'
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $repo '_release' }
$stage = Join-Path $Out 'PBZFog'
$scriptsSrc = Join-Path $repo 'lua\PBZFog\Scripts'
$jsonSrc    = Join-Path $repo 'lua\PBZFog\pbz_tweaker.json'
$presetSrc  = Join-Path $repo 'lua\PBZFog\pbz_presets.json'
$panelDir   = Join-Path $repo 'panel\PBZTweaker'

Write-Host "产物目录: $stage" -ForegroundColor Cyan
if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# 1) 面板
if ($SkipPublish) {
    $built = Join-Path $panelDir '_build_out'
    if (-not (Test-Path $built)) { throw "找不到 $built，请先 dotnet build 或去掉 -SkipPublish" }
    Write-Host "复制已有面板构建 (framework-dependent) ..." -ForegroundColor Yellow
    robocopy $built (Join-Path $stage 'PBZTweaker') /E /NFL /NDL /NJH /NJS /NP | Out-Null
} else {
    Write-Host "dotnet publish 自包含面板 ($Runtime) ..." -ForegroundColor Yellow
    dotnet publish $panelDir -c Release -r $Runtime --self-contained true `
        -p:PublishSingleFile=false -p:IncludeNativeLibrariesForSelfExtract=true `
        -o (Join-Path $stage 'PBZTweaker')
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish 失败 ($LASTEXITCODE)" }
}

# 2) Lua 脚本
Write-Host "复制 Lua 脚本 ..." -ForegroundColor Yellow
robocopy $scriptsSrc (Join-Path $stage 'Scripts') /E /NFL /NDL /NJH /NJS /NP | Out-Null

# 3) 参数表模板 + 预设
Copy-Item $jsonSrc (Join-Path $stage 'pbz_tweaker.json') -Force
if (Test-Path $presetSrc) { Copy-Item $presetSrc (Join-Path $stage 'pbz_presets.json') -Force }

# 4) 版本标记
$ver = (Get-Content (Join-Path $repo 'VERSION') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $ver) { $ver = '0.0.0' }
"PBZVisualTweaker $ver  $Runtime  self-contained=$(-not $SkipPublish)" | Set-Content (Join-Path $stage 'VERSION') -Encoding utf8

# 5) 报告
$files = Get-ChildItem $stage -Recurse -File
$mb = [math]::Round((($files | Measure-Object Length -Sum).Sum)/1MB, 1)
Write-Host "完成: $($files.Count) 个文件, 共 $mb MB" -ForegroundColor Green
Write-Host "把 `$stage` 里的 PBZFog 整个文件夹放到游戏的 ue4ss\Mods\ 下，并在 mods.txt 里加 PBZFog : 1" -ForegroundColor Green
