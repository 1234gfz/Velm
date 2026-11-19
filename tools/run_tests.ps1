# 一键跑全部离线测试：Lua 语法 / 模块依赖 / 模拟 UE 环境的行为断言。
# 需要本机有 Lua 5.4 解释器；可用 $env:LUA_EXE 指定路径。
# 用法：powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
Push-Location $here
try {
    if (-not (Test-Path (Join-Path $here 'node_modules'))) {
        Write-Host "首次运行，安装依赖 (npm install)..." -ForegroundColor Yellow
        npm install --no-audit --no-fund --loglevel=error
    }

    Write-Host "=== 1/3 语法检查 ===" -ForegroundColor Cyan
    node syntaxtest.js
    if ($LASTEXITCODE -ne 0) { throw "语法检查失败" }

    Write-Host "=== 2/3 模块依赖检查 ===" -ForegroundColor Cyan
    node lint_modules.js
    if ($LASTEXITCODE -ne 0) { throw "模块依赖检查失败" }

    Write-Host "=== 3/3 行为测试 ===" -ForegroundColor Cyan
    node run_sim.js
    if ($LASTEXITCODE -ne 0) { throw "行为测试失败" }

    Write-Host "全部通过 ✅" -ForegroundColor Green
}
finally {
    Pop-Location
}
