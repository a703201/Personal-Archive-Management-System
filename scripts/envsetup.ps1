<#
.SYNOPSIS
    AMS 仓颉开发环境脚本（PowerShell 版）

.DESCRIPTION
    用法：. .\scripts\envsetup.ps1
    作用：
      1. 定位仓颉 SDK（默认 E:\Cangjie，可用 CANGJIE_HOME 覆盖）
      2. 设置 CANGJIE_STDX 指向 stdx 扩展标准库
      3. 把 stdx 动态库目录加入 PATH（运行时需要 DLL）

.NOTES
    实测依据（2026-10-24，本机 SDK 1.0.5）：
      - bin/ 只有 cjc.exe；cjpm/cjfmt/cjlint/cjcov 在 tools/bin/
      - SDK 标准库无 SM3/SM4 实现，国密能力来自 stdx
      - ⚠️ 本机 cjpm 崩溃（0xC0000374 堆损坏），与路径/版本/工程结构均无关；
        cjc / cjfmt / cjlint 正常。本机用 cjc 验证代码，cjpm 留给 CI。
#>

$ErrorActionPreference = 'Stop'

# ---- 路径配置 ----
if (-not $env:CANGJIE_HOME -or -not (Test-Path $env:CANGJIE_HOME)) {
    if (Test-Path 'E:\Cangjie') {
        $env:CANGJIE_HOME = 'E:\Cangjie'
    } elseif (Test-Path 'E:\Program Files (x86)\Cangjie') {
        $env:CANGJIE_HOME = 'E:\Program Files (x86)\Cangjie'
    } else {
        Write-Error "未找到仓颉 SDK。请设置 CANGJIE_HOME。"
    }
}

$CangjieStdxRoot = if ($env:CANGJIE_STDX_ROOT) { $env:CANGJIE_STDX_ROOT } else { 'E:\CangjieLibs' }
$CangjieTargetPlatform = 'windows_x86_64_cjnative'

# ---- 1. 加载 SDK 环境 ----
# envsetup.bat 用 set 设置环境变量，需在当前进程执行后导入
$envSetup = Join-Path $env:CANGJIE_HOME 'envsetup.bat'
if (Test-Path $envSetup) {
    foreach ($line in ((Get-Content $envSetup -Raw) -split "`r?`n")) {
        if ($line -match '^\s*set\s+"?([^="]+)=([^"]*)"?\s*$') {
            [Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2], 'Process')
        }
    }
} else {
    Write-Warning "未找到 $envSetup"
}

# ---- 2. 设置 CANGJIE_STDX ----
$stdxDir = Join-Path $CangjieStdxRoot $CangjieTargetPlatform
if (Test-Path $stdxDir) {
    $env:CANGJIE_STDX = $stdxDir
    $env:STDX_DYNAMIC_DIR = Join-Path $stdxDir 'dynamic\stdx'
    $env:STDX_STATIC_DIR  = Join-Path $stdxDir 'static\stdx'
    # 运行时需要能找到 libstdx.*.dll
    $env:PATH = "$($env:STDX_DYNAMIC_DIR);$env:PATH"
} else {
    Write-Warning "stdx 未找到：$stdxDir（请执行 scripts\install-stdx.ps1）"
}

# ---- 3. 验证 ----
Write-Host "[AMS] CANGJIE_HOME = $env:CANGJIE_HOME"
Write-Host "[AMS] CANGJIE_STDX = $env:CANGJIE_STDX"
foreach ($tool in @('cjc','cjfmt','cjlint')) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host "[AMS] $tool -> $($cmd.Source)" }
    else { Write-Warning "[AMS] $tool -> NOT FOUND" }
}
if (Get-Command cjpm -ErrorAction SilentlyContinue) {
    Write-Host "[AMS] cjpm  -> ⚠️ 本机已知崩溃，仅用于 CI/其他环境"
}
