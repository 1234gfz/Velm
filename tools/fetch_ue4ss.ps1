# 下载并解压指定版本的 UE4SS 到 vendor\ue4ss\（供打包“自带 UE4SS”使用）。
# 二进制不进 git（.gitignore 已忽略 vendor/）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\fetch_ue4ss.ps1 `
#       -Url "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip" `
#       -Sha256 "<该 zip 的 sha256>" `
#       -Proxy "http://127.0.0.1:7897"
#
# 说明：本模组已实测的 UE4SS 为 `v3.0.1 Beta #0 / Git SHA #f885e8d2`。
#       维护者在“发布记录”里固定 URL 与 SHA256，避免上游悄悄改包。
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Sha256 = '',
    [string]$Proxy = '',
    [string]$Dest = '',
    [string]$LicenseUrl = ''
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
if ([string]::IsNullOrWhiteSpace($Dest)) { $Dest = Join-Path $repo 'vendor\ue4ss' }
$tmp = Join-Path $env:TEMP ("ue4ss_" + [guid]::NewGuid().ToString('N') + ".zip")

Write-Host "下载 UE4SS: $Url" -ForegroundColor Cyan
$args = @{ Uri = $Url; OutFile = $tmp; UseBasicParsing = $true }
if ($Proxy) { $args['Proxy'] = $Proxy }
Invoke-WebRequest @args

if ($Sha256) {
    $h = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $Sha256.ToLower()) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw "SHA256 不匹配：期望 $Sha256，实际 $h"
    }
    Write-Host "SHA256 校验通过" -ForegroundColor Green
} else {
    Write-Host "警告：未提供 -Sha256，跳过校验（不推荐用于正式发布）" -ForegroundColor Yellow
}

if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Expand-Archive -Path $tmp -DestinationPath $Dest -Force
# 提升 dwmapi.dll 到 vendor 根，供管理器 InstallBundledUe4ss 复制到游戏根目录
$proxySrc = Join-Path $Dest 'dwmapi.dll'
if (Test-Path $proxySrc) { Copy-Item $proxySrc (Join-Path (Split-Path $Dest -Parent) 'dwmapi.dll') -Force }
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

if ($LicenseUrl) {
    try {
        Invoke-WebRequest -Uri $LicenseUrl -OutFile (Join-Path $Dest 'LICENSE-UE4SS.txt') -UseBasicParsing
        Write-Host "已附带 UE4SS LICENSE" -ForegroundColor Green
    } catch { Write-Host "LICENSE 下载失败，请手动补一份 UE4SS 的 LICENSE" -ForegroundColor Yellow }
}

Write-Host "完成 -> $Dest" -ForegroundColor Green
Get-ChildItem $Dest | ForEach-Object { '  ' + $_.Name }
