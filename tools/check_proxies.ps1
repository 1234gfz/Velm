# 检测游戏目录里常见的注入代理 DLL 是否冲突。
# 用法：powershell -ExecutionPolicy Bypass -File tools\check_proxies.ps1 -GameSteamDir "<游戏>\platform\steam"
param(
    [Parameter(Mandatory = $true)][string]$GameSteamDir
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $GameSteamDir)) { throw "目录不存在: $GameSteamDir" }

# 这些名字都是常见的“代理 DLL”注入点
$names = @('dwmapi.dll', 'version.dll', 'dxgi.dll', 'd3d12.dll', 'winmm.dll', 'dbghelp.dll', 'dinput8.dll')
$found = @()
foreach ($n in $names) {
    $p = Join-Path $GameSteamDir $n
    if (Test-Path $p) {
        $it = Get-Item $p
        $found += [pscustomobject]@{ Name = $n; SizeKB = [math]::Round($it.Length / 1KB, 1); Modified = $it.LastWriteTime }
    }
}

Write-Host "在 $GameSteamDir 找到的代理 DLL：" -ForegroundColor Cyan
if ($found.Count -eq 0) {
    Write-Host "  （无）—— 说明 UE4SS 等还没装，或装在了别的位置" -ForegroundColor Yellow
} else {
    $found | Format-Table -AutoSize
}

$hasUe4ss = $found.Name -contains 'dwmapi.dll'
if ($found.Count -gt 1) {
    Write-Host "⚠ 检测到 $($found.Count) 个代理 DLL。多数情况建议只保留一套：" -ForegroundColor Yellow
    Write-Host "   · 本模组必须有 dwmapi.dll（UE4SS）" -ForegroundColor Yellow
    Write-Host "   · 若同时有 dxgi.dll(ReShade) / version.dll(DLSS帧生成)，它们与 UE4SS 可能互相干扰，按需取舍" -ForegroundColor Yellow
} elseif ($hasUe4ss) {
    Write-Host "✅ 只有 UE4SS 的 dwmapi.dll，正常。" -ForegroundColor Green
}
