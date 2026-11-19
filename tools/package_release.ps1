# 组装可发布的 PBZFog 模组目录。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\package_release.ps1                  # 框架依赖(默认，仅需目标机装 .NET 9 桌面运行时)
#   powershell -ExecutionPolicy Bypass -File tools\package_release.ps1 -SelfContained    # 自包含(需联网还原 win-x64 运行时包，首次较慢)
#
# 产物：<repo>\_release\PBZFog\{Scripts, PBZTweaker, pbz_tweaker.json, pbz_presets.json, VERSION}
param(
    [string]$Out = '',
    [switch]$SelfContained,
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
$panelOut   = Join-Path $stage 'PBZTweaker'

Write-Host "产物目录: $stage" -ForegroundColor Cyan
if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# 1) 面板
if ($SelfContained) {
    Write-Host "dotnet publish 自包含面板 ($Runtime) —— 首次需联网还原运行时包 ..." -ForegroundColor Yellow
    dotnet publish $panelDir -c Release -r $Runtime --self-contained true `
        -p:PublishSingleFile=false -p:IncludeNativeLibrariesForSelfExtract=true `
        -o $panelOut --nologo
} else {
    Write-Host "dotnet publish 面板 (框架依赖，需目标机 .NET 9 桌面运行时) ..." -ForegroundColor Yellow
    dotnet publish $panelDir -c Release -o $panelOut --nologo
}
if ($LASTEXITCODE -ne 0) { throw "dotnet publish 失败 ($LASTEXITCODE)" }

# 2) Lua 脚本
Write-Host "复制 Lua 脚本 ..." -ForegroundColor Yellow
robocopy $scriptsSrc (Join-Path $stage 'Scripts') /E /NFL /NDL /NJH /NJS /NP | Out-Null

# 3) 参数表模板 + 预设
Copy-Item $jsonSrc (Join-Path $stage 'pbz_tweaker.json') -Force
if (Test-Path $presetSrc) { Copy-Item $presetSrc (Join-Path $stage 'pbz_presets.json') -Force }

# 4) 版本标记
$ver = (Get-Content (Join-Path $repo 'VERSION') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $ver) { $ver = '0.0.0' }
"PBZVisualTweaker $ver  自包含=$([bool]$SelfContained)  $Runtime" | Set-Content (Join-Path $stage 'VERSION') -Encoding utf8

# 5) 报告
$files = Get-ChildItem $stage -Recurse -File
$mb = [math]::Round((($files | Measure-Object Length -Sum).Sum)/1MB, 1)
Write-Host "完成: $($files.Count) 个文件, 共 $mb MB" -ForegroundColor Green
Write-Host "把 _release\PBZFog 整个放到游戏的 <PBZ>\platform\steam\ue4ss\Mods\ 下，并在 mods.txt 加 PBZFog : 1" -ForegroundColor Green
