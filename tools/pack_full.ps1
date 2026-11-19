# 组装“完整可分发包”：管理器 + 面板 + 模组 + 文档 (+ 可选 UE4SS) + 可选 zip。
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\pack_full.ps1                 # 框架依赖(离线可打)
#   ... -SelfContained -Zip                                                      # 自包含+打包(需联网还原运行时包)
#   ... -WithUE4SS -Zip                                                          # 带上 vendor\ue4ss 里下好的 UE4SS
param(
    [string]$Out = '',
    [switch]$SelfContained,
    [string]$Runtime = 'win-x64',
    [switch]$WithUE4SS,
    [switch]$Zip
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $repo '_release' }
$ver = (Get-Content (Join-Path $repo 'VERSION') -ErrorAction SilentlyContinue | Select-Object -First 1); if (-not $ver) { $ver = '0.0.0' }
Write-Host "版本 $ver -> $Out  (自包含=$([bool]$SelfContained))" -ForegroundColor Cyan
if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory -Path $Out -Force | Out-Null

function Publish-App($proj, $dst) {
    if ($SelfContained) {
        dotnet publish $proj -c Release -r $Runtime --self-contained true -p:PublishSingleFile=false -p:IncludeNativeLibrariesForSelfExtract=true -o $dst --nologo
    } else {
        dotnet publish $proj -c Release -o $dst --nologo
    }
    if ($LASTEXITCODE -ne 0) { throw "publish 失败: $proj ($LASTEXITCODE)" }
}

Write-Host "发布面板 -> PBZFog\PBZTweaker ..." -ForegroundColor Yellow
Publish-App (Join-Path $repo 'panel\PBZTweaker') (Join-Path $Out 'PBZFog\PBZTweaker')
Write-Host "发布管理器(窗口版) -> 根目录 ..." -ForegroundColor Yellow
Publish-App (Join-Path $repo 'manager\PBZModManagerGui') $Out
Get-ChildItem $Out -Recurse -Filter *.pdb -File -ErrorAction SilentlyContinue | Remove-Item -Force

Write-Host "复制模组脚本 + 参数表 ..." -ForegroundColor Yellow
robocopy (Join-Path $repo 'lua\PBZFog\Scripts') (Join-Path $Out 'PBZFog\Scripts') /E /NFL /NDL /NJH /NJS /NP | Out-Null
Copy-Item (Join-Path $repo 'lua\PBZFog\pbz_tweaker.json') (Join-Path $Out 'PBZFog\pbz_tweaker.json') -Force
$presetJson = Join-Path $repo 'lua\PBZFog\pbz_presets.json'
if (Test-Path $presetJson) { Copy-Item $presetJson (Join-Path $Out 'PBZFog\pbz_presets.json') -Force }
$langDir = Join-Path $repo 'lua\PBZFog\lang'
if (Test-Path $langDir) { robocopy $langDir (Join-Path $Out 'PBZFog\lang') /E /NFL /NDL /NJH /NJS /NP | Out-Null }

Write-Host "复制文档 ..." -ForegroundColor Yellow
foreach ($f in @('LICENSE', 'CHANGELOG.md', 'VERSION')) {
    if (Test-Path (Join-Path $repo $f)) { Copy-Item (Join-Path $repo $f) (Join-Path $Out $f) -Force }
}
$guide = Join-Path $repo 'packaging\安装说明.txt'
if (Test-Path $guide) { Copy-Item $guide (Join-Path $Out '安装说明.txt') -Force }

if ($WithUE4SS) {
    $v = Join-Path $repo 'vendor\ue4ss'
    if (Test-Path $v) {
        Write-Host "打包 UE4SS ..." -ForegroundColor Yellow
        $inner = Join-Path $v 'ue4ss'
        if (Test-Path $inner) { robocopy $inner (Join-Path $Out 'ue4ss') /E /NFL /NDL /NJH /NJS /NP | Out-Null }
        else { robocopy $v (Join-Path $Out 'ue4ss') /E /NFL /NDL /NJH /NJS /NP | Out-Null }
        $proxy = Join-Path $v 'dwmapi.dll'
        if (Test-Path $proxy) { Copy-Item $proxy (Join-Path $Out 'dwmapi.dll') -Force }
        $dstMods = Join-Path $Out 'ue4ss\Mods'
        New-Item -ItemType Directory -Path $dstMods -Force | Out-Null
        if (-not (Test-Path (Join-Path $dstMods 'PBZFog'))) {
            robocopy (Join-Path $Out 'PBZFog') (Join-Path $dstMods 'PBZFog') /E /NFL /NDL /NJH /NJS /NP | Out-Null
        }
    } else {
        Write-Host "警告: 没找到 vendor\ue4ss，跳过 UE4SS（先跑 tools\fetch_ue4ss.ps1）" -ForegroundColor Yellow
    }
}

$files = Get-ChildItem $Out -Recurse -File
$mb = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
Write-Host "完成: $($files.Count) 文件, $mb MB" -ForegroundColor Green

if ($Zip) {
    $zipPath = Join-Path (Split-Path $Out -Parent) ("PBZVisualTweaker_v" + $ver + ".zip")
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($Out, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    Write-Host "已打包: $zipPath" -ForegroundColor Green
}
