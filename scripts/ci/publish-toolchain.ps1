<#
.SYNOPSIS
    AMS - Publish CI toolchain to GitHub Release (Windows native PowerShell)

.DESCRIPTION
    Package the Cangjie SDK and stdx, upload them to a toolchain Release,
    so GitHub-hosted runners can download them.

    Why a PowerShell version?
      Running `bash xxx.sh` from cmd usually resolves to the WSL bash
      (if WSL is installed), and WSL does NOT understand Windows drive
      paths like "E:/CangjieLibs" - it needs "/mnt/e/...".
      Measured result: "stdx directory not found".
      PowerShell is native Windows, so paths are unambiguous.

    The bash sibling (publish-toolchain.sh) handles this too via
    scripts/ci/pathutil.sh, but PowerShell is the recommended path for
    cmd users.

.EXAMPLE
    In cmd:
        set GITHUB_TOKEN=ghp_xxx
        powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ci\publish-toolchain.ps1

.PARAMETER Token
    GitHub token. Falls back to GITHUB_TOKEN / GH_TOKEN env vars.

.PARAMETER SdkPath
    Cangjie SDK dir. Defaults to <repo>\tools\cangjie, then E:\Cangjie.

.PARAMETER StdxPath
    stdx dynamic dir. Defaults to E:\CangjieLibs\windows_x86_64_cjnative\dynamic\stdx.

.PARAMETER Tag
    Toolchain Release tag. Defaults to toolchain-v<SDK version>.

.PARAMETER DryRun
    Package only, do not upload.
#>
[CmdletBinding()]
param(
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$TokenAlt = $env:GH_TOKEN,
    [string]$SdkPath = "",
    [string]$StdxPath = "",
    [string]$Tag = "",
    [string]$SdkVersion = "1.2.0",
    [string]$StdxVersion = "1.2.0.1",
    [switch]$DryRun,
    # Upload assets automatically. OFF by default: GitHub has a gateway
    # timeout on single asset uploads, so large files often fail with 504.
    # The script creates the Release and prints manual upload instructions.
    [switch]$Upload
)

$ErrorActionPreference = "Stop"

# Console encoding: cmd default code page is GBK(936) while this file is
# UTF-8, so Chinese output would be garbled. Switch the console to UTF-8.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    Write-Host "[hint] console encoding switch failed; output may be garbled" -ForegroundColor DarkYellow
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
Set-Location $RepoRoot

function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Info($msg) { Write-Host "  $msg" -ForegroundColor Gray }

# ---------------------------------------------------------------- defaults
if ([string]::IsNullOrEmpty($SdkPath)) {
    foreach ($cand in @("$RepoRoot\tools\cangjie", "E:\Cangjie")) {
        if (Test-Path (Join-Path $cand "bin\cjc.exe")) { $SdkPath = $cand; break }
    }
}
if ([string]::IsNullOrEmpty($StdxPath)) {
    $StdxPath = "E:\CangjieLibs\windows_x86_64_cjnative\dynamic\stdx"
}
if ([string]::IsNullOrEmpty($Tag)) { $Tag = "toolchain-v$SdkVersion" }
if ([string]::IsNullOrEmpty($Token)) { $Token = $TokenAlt }

Write-Host "=== AMS - Publish CI toolchain (PowerShell) ===" -ForegroundColor Green
Write-Info "SDK  : $SdkPath  ($SdkVersion)"
Write-Info "stdx : $StdxPath  ($StdxVersion)"
Write-Info "tag  : $Tag"
Write-Host ""

# ---------------------------------------------------------------- validate
if (-not (Test-Path (Join-Path $SdkPath "bin\cjc.exe"))) {
    Write-Err "Invalid SDK dir (missing bin\cjc.exe): $SdkPath"
    Write-Err "Use -SdkPath <dir> to specify it explicitly."
    exit 1
}
if (-not (Test-Path $StdxPath)) {
    Write-Err "stdx dir not found: $StdxPath"
    Write-Err "Use -StdxPath <dir> to specify it explicitly."
    exit 1
}

# ---------------------------------------------------------------- repo info
$remote = (git remote get-url origin 2>$null)
if (-not $remote) { Write-Err "git remote 'origin' not found"; exit 1 }
if ($remote -match '^git@[^:]+:(.+)/(.+)\.git$') {
    $ownerRepo = "$($Matches[1])/$($Matches[2])"
} elseif ($remote -match '^https?://[^/]+/(.+)/(.+)\.git$') {
    $ownerRepo = "$($Matches[1])/$($Matches[2])"
} else {
    Write-Err "Cannot parse owner/repo from: $remote"; exit 1
}
Write-Info "repo : $ownerRepo"
Write-Host ""

# ------------------------------------------------- MinGW runtime (required)
# The Cangjie SDK 1.2.0 Windows package does NOT ship the MinGW runtime
# (libgcc_s_seh-1.dll / libwinpthread-1.dll). cjc needs them to compile
# @Test programs - without them it fails with
# "could not find the create task method: RunCJTask".
#
# libssp-0.dll is OPTIONAL: measured on this machine it is absent and
# cjc still compiles and runs tests fine.
$mingwRequired = @("libgcc_s_seh-1.dll", "libwinpthread-1.dll")
$mingwOptional = @("libssp-0.dll")
$mingwFiles    = $mingwRequired + $mingwOptional
$mingwCandidates = @(
    (Join-Path $SdkPath "bin"),
    (Join-Path $RepoRoot "tools\cangjie\bin"),
    "C:\Program Files\Git\mingw64\bin",
    "C:\Program Files (x86)\Git\mingw64\bin"
)
$sdkBin = Join-Path $SdkPath "bin"
foreach ($f in $mingwFiles) {
    if (Test-Path (Join-Path $sdkBin $f)) { continue }
    foreach ($c in $mingwCandidates) {
        if ([string]::IsNullOrEmpty($c)) { continue }
        $src = Join-Path $c $f
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $sdkBin $f) -Force
            Write-Info "added MinGW runtime: $f (from $c)"
            break
        }
    }
}
$missing = @()
foreach ($f in $mingwRequired) {
    if (-not (Test-Path (Join-Path $sdkBin $f))) { $missing += $f }
}
if ($missing.Count -gt 0) {
    Write-Err "Missing required MinGW runtime: $($missing -join ' ')"
    Write-Err "CI would fail to compile @Test cases (RunCJTask not found)."
    exit 1
}

# ---------------------------------------------------------------- packaging
# 两个程序集都要加载：
#   System.IO.Compression           → ZipArchiveMode（枚举）
#   System.IO.Compression.FileSystem → ZipFile / ZipFileExtensions（静态方法）
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-ZipFromDir([string]$srcDir, [string]$zipPath, [string]$arcRoot) {
    # Write the zip directly, NO temp directory:
    #   1) avoids one extra 820 MB copy (much faster)
    #   2) avoids recursive delete (blocked by safe-delete on this machine)
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }

    $zip = [System.IO.Compression.ZipFile]::Open(
        $zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $rootFull = (Resolve-Path $srcDir).Path.TrimEnd('\')
        $all = Get-ChildItem -Path $rootFull -Recurse -File -Force
        # 排除对「编译 + 运行测试」无用的部分（省掉 ~600 MB）
        #   tools/            406M —— clang-format / lldb / cjlint / IDE 插件，CI 用不到
        #   third_party/llvm  198M —— LLVM（cjc 是自研编译器，不用 LLVM）
        # 注意：必需的动态库（libboundscheck / libcangjie-runtime / libsecurec /
        #       libpcre2-8）**都在 runtime/lib/** 下，runtime 目录已完整保留。
        # 已实测：裁剪后仍能编译并运行 @Test 用例。
        $excludeExact = @(
            "third_party/llvm/bin/libclang-cpp.dll",
            "third_party/llvm/bin/libclang.dll",
            "third_party/llvm/bin/liblldb.dll",
            "third_party/llvm/bin/libunwind.dll",
            "third_party/llvm/bin/libLTO.dll",
            "third_party/llvm/bin/libcangjie-lsp.dll"
        )
        $excludePrefix = @("tools/")
        $files = @()
        foreach ($f in $all) {
            if ($f.Extension -in @(".log", ".tmp")) { continue }
            $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\').Replace('\', '/')
            $skip = $false
            if ($excludeExact -contains $rel) { $skip = $true }
            else {
                foreach ($pre in $excludePrefix) {
                    if ($rel.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
                }
            }
            # lldb* 只被调试器使用
            if (-not $skip -and $rel.StartsWith("third_party/llvm/")) {
                $bn = Split-Path -Leaf $rel
                if ($bn.StartsWith("lldb")) { $skip = $true }
            }
            if (-not $skip) { $files += $f }
        }
        $n = 0
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\').Replace('\', '/')
            $arc = "$arcRoot/$rel"
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $f.FullName, $arc,
                [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
            $n++
            if ($n % 2000 -eq 0) { Write-Info "  packed $n files..." }
        }
        Write-Info "  total $n files"
    }
    finally {
        $zip.Dispose()
    }
}

$outDir = Join-Path $RepoRoot "dist\toolchain"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$sdkZip  = Join-Path $outDir "cangjie-sdk-windows-x64-$SdkVersion.zip"
$stdxZip = Join-Path $outDir "cangjie-stdx-windows-x64-$StdxVersion.zip"

if (Test-Path $sdkZip) {
    Write-Step "SDK zip exists, reusing"
} else {
    Write-Step "Packing SDK (820 MB -> ~250 MB, takes a few minutes)..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    New-ZipFromDir $SdkPath $sdkZip "cangjie"
    $sw.Stop()
    Write-Ok ("done: {0:N0} MB in {1:N0}s" -f ((Get-Item $sdkZip).Length / 1MB), $sw.Elapsed.TotalSeconds)
}

if (Test-Path $stdxZip) {
    Write-Step "stdx zip exists, reusing"
} else {
    Write-Step "Packing stdx..."
    New-ZipFromDir $StdxPath $stdxZip "stdx"
    Write-Ok ("done: {0:N1} MB" -f ((Get-Item $stdxZip).Length / 1MB))
}

if ($DryRun) {
    Write-Host ""
    Write-Host "=== dry-run, nothing uploaded ===" -ForegroundColor Yellow
    Get-ChildItem $outDir | Format-Table Name, @{n='Size(MB)';e={"{0:N1}" -f ($_.Length/1MB)}}
    exit 0
}

if ([string]::IsNullOrEmpty($Token)) {
    Write-Err "No token. Pass -Token or set GITHUB_TOKEN."
    exit 1
}

# ---------------------------------------------------------------- release
$headers = @{
    "Authorization" = "Bearer $Token"
    "Accept"        = "application/vnd.github+json"
    "User-Agent"    = "ams-publish-toolchain"
}
$api = "https://api.github.com/repos/$ownerRepo"

Write-Step "Looking up Release $Tag ..."
$relId = $null
try {
    $r = Invoke-RestMethod -Uri "$api/releases/tags/$Tag" -Headers $headers -Method Get
    $relId = $r.id
    Write-Info "exists (id=$relId)"
} catch {
    Write-Step "Creating Release ..."
    $body = @{
        tag_name   = $Tag
        name       = "CI toolchain $Tag"
        body       = "Cangjie SDK + stdx for CI runners.`n`nGenerated by scripts/ci/publish-toolchain.ps1."
        draft      = $false
        prerelease = $false
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$api/releases" -Headers $headers -Method Post `
         -ContentType "application/json" -Body ([Text.Encoding]::UTF8.GetBytes($body))
    $relId = $r.id
    Write-Ok "created (id=$relId)"
}

# ---------------------------------------------------------------- upload
function Upload-Asset([string]$filePath, [string]$releaseId) {
    $name = Split-Path -Leaf $filePath
    # drop an asset with the same name first (otherwise 422)
    try {
        $assets = Invoke-RestMethod -Uri "$api/releases/$releaseId/assets" -Headers $headers -Method Get
        foreach ($a in $assets) {
            if ($a.name -eq $name) {
                Invoke-RestMethod -Uri "$api/releases/assets/$($a.id)" -Headers $headers -Method Delete
                Write-Info "removed old asset $name"
            }
        }
    } catch { }

    Write-Step ("uploading {0} ({1:N1} MB)..." -f $name, ((Get-Item $filePath).Length / 1MB))
    $uploadUrl = "$api/releases/$releaseId/assets?name=$([uri]::EscapeDataString($name))"

    # 用 curl.exe 流式上传（Windows 10+ 自带）：
    #   ① Invoke-RestMethod -Form 在 PS 5.1 里不存在，手拼 multipart 又要把
    #      整个文件读进内存（251 MB 曾经就是这么 504 的）；
    #   ② curl -F 直接流式发送，内存占用恒定，且能设长超时。
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        Write-Err "curl.exe not found (needed for large asset upload)."
        Write-Err "Alternative: install GitHub CLI and run: gh release upload $Tag $filePath"
        exit 1
    }

    # ⚠️ 两个必须注意的点（都是实测踩出来的）：
    #
    # ① `--ssl-no-revoke`
    #    Windows 自带的 curl 用 **schannel**（非 OpenSSL），默认会检查服务器
    #    证书的吊销状态（CRL/OCSP）。若网络环境（企业代理 / 防火墙）阻断了
    #    吊销检查端点，curl 会直接失败：
    #        curl: (35) schannel: next InitializeSecurityContext failed:
    #        CRYPT_E_NO_REVOCATION_CHECK (0x80092012)
    #    证书本身的有效性校验不受影响，故关掉吊销检查即可。
    #
    # ② 重试必须能真正跑起来
    #    脚本顶部是 `$ErrorActionPreference = "Stop"`，而 **native command
    #    写 stderr 会触发 NativeCommandError**，在 Stop 下是 terminating error
    #    → 脚本在第 1 次尝试后就直接退出，**重试逻辑根本没执行**。
    #    故调用 curl 时临时把 ErrorActionPreference 降为 Continue。
    $ok = $false
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Write-Info "  attempt $attempt/3 ..."
            $curlOut = & curl.exe -sS --fail-with-body `
                --ssl-no-revoke `
                --max-time 1800 `
                -X POST `
                -H "Authorization: Bearer $Token" `
                -H "Accept: application/vnd.github+json" `
                -H "User-Agent: ams-publish-toolchain" `
                -F "file=@$filePath" `
                "$uploadUrl" 2>&1
            $curlCode = $LASTEXITCODE
            $curlText = ($curlOut | Out-String)
            if ($curlCode -eq 0) { $ok = $true; break }
            if ($curlText -match "504|Gateway Timeout") {
                Write-Info "  gateway timeout (504) - asset too large for one request"
            } elseif ($curlText -match "NO_REVOCATION_CHECK") {
                Write-Info "  TLS revocation check failed"
            } elseif ($curlText.Trim()) {
                Write-Info ("  " + $curlText.Trim().Substring(0, [Math]::Min(200, $curlText.Trim().Length)))
            }
            Write-Info "  failed (curl exit $curlCode), retrying in 10s ..."
            Start-Sleep -Seconds 10
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }

    if (-not $ok) {
        Write-Err "Upload failed for $name"
        Write-Err ""
        Write-Err "If the error was '504 Gateway Timeout', the asset is too large for"
        Write-Err "a single GitHub API request. Options:"
        Write-Err "  A) Install GitHub CLI, then:  gh release upload $Tag `"$filePath`" --clobber"
        Write-Err "  B) Upload the file manually at:"
        Write-Err "     https://github.com/$ownerRepo/releases/tag/$Tag"
        exit 1
    }
    Write-Ok $name
}

if (-not $Upload) {
    Write-Host ""
    Write-Host "[3/3] skipping auto-upload (use -Upload to enable)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "=== Release created; please upload the assets manually ===" -ForegroundColor Green
    Write-Host "  Release: https://github.com/$ownerRepo/releases/tag/$Tag" -ForegroundColor Cyan
    Write-Host "  Files to upload:" -ForegroundColor Cyan
    Write-Host "    $sdkZip"
    Write-Host "    $stdxZip"
    Write-Host ""
    Write-Host "Option A: browser (simplest)" -ForegroundColor Cyan
    Write-Host "  open the Release page -> Assets -> drag the files in"
    Write-Host ""
    Write-Host "Option B: GitHub CLI (recommended; bypasses the API gateway limit)" -ForegroundColor Cyan
    Write-Host "  winget install GitHub.cli"
    Write-Host "  gh release upload $Tag `"$sdkZip`" `"$stdxZip`" --repo $ownerRepo --clobber"
    Write-Host ""
    Write-Host "Next step:" -ForegroundColor Cyan
    Write-Host "  Repo Settings -> Secrets and variables -> Actions -> Variables"
    Write-Host "  add variable CANGJIE_TOOLCHAIN_TAG = $Tag"
    exit 0
}

Upload-Asset $sdkZip $relId
Upload-Asset $stdxZip $relId

Write-Host ""
Write-Host "=== toolchain published ===" -ForegroundColor Green
Write-Host "  Release: https://github.com/$ownerRepo/releases/tag/$Tag" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1) Repo Settings -> Secrets and variables -> Actions -> Variables"
Write-Host "     add variable CANGJIE_TOOLCHAIN_TAG = $Tag"
Write-Host "  2) Commit and push the workflow changes; CI will fetch the toolchain."
