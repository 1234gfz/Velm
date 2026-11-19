# 工程版 ↔ 游戏版 Lua 代码同步（整目录）。PowerShell 版，功能等价于 sync_lua.py。
#
# 本机没有可用的 Python，所以提供这份。用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_lua.ps1 push
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_lua.ps1 diff
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_lua.ps1 pull

param(
    [Parameter(Position = 0)]
    [ValidateSet('push', 'pull', 'diff')]
    [string]$Command = 'diff'
)

$ErrorActionPreference = 'Stop'

$Proj    = Split-Path -Parent $PSScriptRoot
$SrcRoot = Join-Path $Proj 'lua\PBZFog'
$DstRoot = 'E:\SteamLibrary\steamapps\common\PBZ\platform\steam\ue4ss\Mods\PBZFog'
$SrcJson = Join-Path $SrcRoot 'pbz_tweaker.json'
$DstJson = Join-Path $DstRoot 'pbz_tweaker.json'

$Node = 'C:\Program Files\nodejs\node.exe'
$Lint = Join-Path $PSScriptRoot 'lint_modules.js'

function Get-LuaFiles([string]$root) {
    if (-not (Test-Path $root)) { return @() }
    Get-ChildItem $root -Recurse -Filter *.lua |
        ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/' } |
        Sort-Object
}

function Test-Syntax([string]$root) {
    if (-not (Test-Path $Node)) {
        Write-Host '  跳过语法校验（找不到 node.exe）'
        return $true
    }
    $files = Get-LuaFiles $root
    $bad = @()
    foreach ($rel in $files) {
        $full = Join-Path $root ($rel -replace '/', '\')
        $r = & $Node (Join-Path $PSScriptRoot 'luacheck.js') $full 2>&1
        if (-not ($r -match '^OK')) { $bad += "$rel : $r" }
    }
    if ($bad.Count -gt 0) {
        Write-Host "  ✘ 语法错误 $($bad.Count) 个:"
        $bad | ForEach-Object { Write-Host "    $_" }
        return $false
    }
    Write-Host "  ✔ 语法全部通过（$($files.Count) 个文件）"
    return $true
}

function Push-Json {
    # 参数表是用户数据：以游戏版为基准，只追加工程版里新增的参数，
    # 绝不覆盖用户在面板里调好的 value / enabled。
    if (-not (Test-Path $DstJson)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $DstJson) | Out-Null
        Copy-Item $SrcJson $DstJson
        Write-Host '  ✔ 游戏版参数表不存在，首次推送完整参数表'
        return
    }

    try {
        $proj = Get-Content $SrcJson -Raw -Encoding utf8 | ConvertFrom-Json
        $game = Get-Content $DstJson -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        Write-Host "  ✘ 参数表 JSON 解析失败: $_"
        return
    }

    $gameKeys = @{}
    foreach ($g in $game.groups) {
        foreach ($x in $g.parameters) { if ($x.key) { $gameKeys[$x.key] = $true } }
    }

    $gameGroups = @{}
    foreach ($g in $game.groups) { $gameGroups[$g.name] = $g }

    $added = @()
    foreach ($pg in $proj.groups) {
        $gg = $gameGroups[$pg.name]
        if ($null -eq $gg) {
            $game.groups += $pg
            foreach ($x in $pg.parameters) { $added += $x.key }
            continue
        }
        foreach ($x in $pg.parameters) {
            if ($x.key -and -not $gameKeys.ContainsKey($x.key)) {
                $gg.parameters += $x
                $gameKeys[$x.key] = $true
                $added += $x.key
            }
        }
    }

    foreach ($meta in @('version', 'title', 'hotkey')) {
        if ($null -ne $proj.$meta) { $game.$meta = $proj.$meta }
    }

    if ($added.Count -eq 0) {
        Write-Host '  ✔ 参数表无需更新（游戏版已有全部参数，用户值全部保留）'
        return
    }

    # ConvertTo-Json 默认深度 2，参数表嵌套很深，必须给足。
    # 注意：绝不能直接 `| Set-Content $DstJson`——曾经因为管道输入异常把参数表写成 0 字节。
    # 先序列化成字符串，再用 File.WriteAllText 落盘（UTF8 无 BOM），并先写临时文件再替换。
    $jsonText = $game | ConvertTo-Json -Depth 20
    if ([string]::IsNullOrWhiteSpace($jsonText)) { throw '参数表序列化结果为空，已中止（不写盘）' }
    $tmp = "$DstJson.sync-tmp"
    [System.IO.File]::WriteAllText($tmp, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force $tmp $DstJson
    Write-Host "  ✔ 参数表增量更新：新增 $($added.Count) 项（$($added[0..([Math]::Min(5,$added.Count-1))] -join ', ')）"
    Write-Host '    用户已调的值和开关状态全部保留'
}

Write-Host "工程: $SrcRoot"
Write-Host "游戏: $DstRoot"
Write-Host ""

switch ($Command) {

    'diff' {
        $src = Get-LuaFiles $SrcRoot
        $dst = Get-LuaFiles $DstRoot
        $same = 0; $differ = @(); $onlyProj = @(); $onlyGame = @()

        foreach ($rel in $src) {
            $a = Join-Path $SrcRoot ($rel -replace '/', '\')
            $b = Join-Path $DstRoot ($rel -replace '/', '\')
            if (-not (Test-Path $b)) { $onlyProj += $rel }
            elseif ((Get-FileHash $a).Hash -eq (Get-FileHash $b).Hash) { $same++ }
            else { $differ += $rel }
        }
        foreach ($rel in $dst) { if ($src -notcontains $rel) { $onlyGame += $rel } }

        Write-Host "Lua 文件：一致 $same / 有差异 $($differ.Count) / 仅工程 $($onlyProj.Count) / 仅游戏 $($onlyGame.Count)"
        $differ    | ForEach-Object { Write-Host "  [差异] $_" }
        $onlyProj  | ForEach-Object { Write-Host "  [仅工程] $_" }
        $onlyGame  | ForEach-Object { Write-Host "  [仅游戏] $_" }

        $ja = (Get-Content $SrcJson -Raw)
        $jb = if (Test-Path $DstJson) { Get-Content $DstJson -Raw } else { '' }
        if ($ja -eq $jb) { Write-Host "参数表: 一致" }
        else { Write-Host "参数表: 不一致（工程 $($ja.Length) 字节 / 游戏 $($jb.Length) 字节）" }
    }

    'push' {
        Write-Host '校验工程版语法…'
        if (-not (Test-Syntax $SrcRoot)) { exit 1 }

        $src = Get-LuaFiles $SrcRoot
        $n = 0
        foreach ($rel in $src) {
            $s = Join-Path $SrcRoot ($rel -replace '/', '\')
            $d = Join-Path $DstRoot ($rel -replace '/', '\')
            $dir = Split-Path $d -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            if ((Test-Path $d) -and ((Get-FileHash $s).Hash -eq (Get-FileHash $d).Hash)) { continue }
            Copy-Item $s $d -Force
            $n++
        }
        Write-Host "  ✔ 已推送 $n 个 Lua 文件（共 $($src.Count) 个）"

        # 游戏侧有、工程侧没有的 .lua 是被删掉的旧模块，必须清掉，
        # 否则残留文件会被 require 到。
        $removed = @()
        foreach ($rel in (Get-LuaFiles $DstRoot)) {
            if ($src -notcontains $rel) {
                Remove-Item (Join-Path $DstRoot ($rel -replace '/', '\')) -Force
                $removed += $rel
            }
        }
        if ($removed.Count -gt 0) {
            Write-Host "  ✔ 已删除游戏侧多余文件 $($removed.Count) 个：$($removed -join ', ')"
        }

        Push-Json
    }

    'pull' {
        Write-Host '校验游戏版语法…'
        if (-not (Test-Syntax $DstRoot)) { exit 1 }

        $dst = Get-LuaFiles $DstRoot
        $n = 0
        foreach ($rel in $dst) {
            $s = Join-Path $DstRoot ($rel -replace '/', '\')
            $d = Join-Path $SrcRoot ($rel -replace '/', '\')
            $dir = Split-Path $d -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            if ((Test-Path $d) -and ((Get-FileHash $s).Hash -eq (Get-FileHash $d).Hash)) { continue }
            Copy-Item $s $d -Force
            $n++
        }
        Write-Host "  ✔ 已拉取 $n 个 Lua 文件"
        if (Test-Path $DstJson) { Copy-Item $DstJson $SrcJson -Force; Write-Host '  ✔ 已拉取 pbz_tweaker.json' }
    }
}
