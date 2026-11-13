<#
================================================================
 AMS · 桌面启动器（Windows / PowerShell 5.1 + WinForms）
================================================================
 设计契约（见 docs/17-项目评估与创新点.md §3.2.3 方案 A）：

   启动器只是「看得见的外壳」，不是第二个权威。
   所有安全判定仍由 scripts/start.cmd 与 ams-server (SEC-001) 做出。

 红线（任何一条被破坏都视为实现错误）：
   R1 绝不生成/兜底密钥（生成按钮必须用户显式点击 + 显式落盘 + 备份提示）
   R2 预检只是提前告知，不替代 start.cmd / main.cj 的权威校验
   R3 不吞退出码、不自动重启、不静默降级
   R4 /api/health 只是 liveness，不等于「安全就绪」
   R5 密钥不进日志 / UI 明文常驻 / 崩溃报告
   R6 不改写启动参数、不自动换端口、不注入兜底环境变量
   R7 不创建管理员、不改 deployment.env、不碰 /setup

 运行前提：Windows 自带 PowerShell 5.1 + .NET Framework（不编译、不分发
 任何 C# / .NET / JVM 二进制）。入口为同目录 AMS-Launcher.cmd（-STA）。
 文件必须保存为 UTF-8 with BOM，否则 PS 5.1 按 ANSI 读取会导致中文乱码。
================================================================
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- 路径：$PSScriptRoot = <包根>/launcher ----
$Script:Root      = Split-Path -Parent $PSScriptRoot
$Script:ConfigPath = Join-Path $Script:Root 'config\application.env'
$Script:DeployEnv  = Join-Path $Script:Root 'config\deployment.env'
$Script:StartCmd   = Join-Path $Script:Root 'scripts\start.cmd'
$Script:ServerExe  = Join-Path $Script:Root 'bin\ams-server.exe'
$Script:WebIndex   = Join-Path $Script:Root 'web\index.html'
$Script:LogDir     = Join-Path $Script:Root 'logs'
# 服务日志由 cmd 重定向独占写入；启动器自身日志另写一份，避免两个进程抢同一文件句柄
$Script:LogFile    = Join-Path $Script:LogDir ("ams-server-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$Script:SelfLog    = Join-Path $Script:LogDir ("ams-launcher-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$Script:Proc       = $null
$Script:State      = 'Stopped'
$Script:LastExit   = $null
$Script:ForcedKill = $false
$Script:StartAt    = $null
$Script:LastLogLen = 0

# 脱敏：与 packages/ams-storage/src/deployment.cj 的 SECRET_KEYS 对齐
$Script:SecretPattern = '(?i)(TOKEN_SECRET|KEK|DB_PASSWORD|DB_APP_PASSWORD|MAIL_PASSWORD|S3_SECRET_KEY|S3_ACCESS_KEY|EXPORT_SIGN_KEY|PASSWORD|SECRET|ACCESS_KEY)\s*[:=]\s*([^\s,;"''}]+)'

function Protect-Secrets {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [System.Text.RegularExpressions.Regex]::Replace(
        $Text, $Script:SecretPattern, '$1=***')
}

function Read-Config {
    $map = @{}
    if (-not (Test-Path -LiteralPath $Script:ConfigPath)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($Script:ConfigPath, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') {
            $map[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $map
}

function Set-ConfigValue {
    param([string]$Key, [string]$Value)
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Script:ConfigPath) {
        foreach ($l in [System.IO.File]::ReadAllLines($Script:ConfigPath, [System.Text.Encoding]::UTF8)) {
            [void]$lines.Add($l)
        }
    }
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            $lines[$i] = ('{0}={1}' -f $Key, $Value)
            $found = $true
            break
        }
    }
    if (-not $found) { [void]$lines.Add(('{0}={1}' -f $Key, $Value)) }
    # 无 BOM UTF-8：start.cmd 的 for /f 才能正确解析键名
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Script:ConfigPath,
        ([string]::Join("`r`n", $lines) + "`r`n"), $enc)
}

function Get-Port {
    $cfg = Read-Config
    if ($cfg.ContainsKey('AMS_HTTP_PORT') -and $cfg['AMS_HTTP_PORT'] -match '^\d+$') {
        return [int]$cfg['AMS_HTTP_PORT']
    }
    return 8080
}

function Test-PortFree {
    param([int]$Port)
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch { return $false }
}

function Test-Health {
    $port = Get-Port
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/api/health")
        $req.Timeout = 1500
        $req.ReadWriteTimeout = 1500
        $req.Method = 'GET'
        $resp = $req.GetResponse()
        try { return ([int]$resp.StatusCode -eq 200) } finally { $resp.Dispose() }
    } catch { return $false }
}

function Test-RootHtml {
    $port = Get-Port
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/")
        $req.Timeout = 1500
        $req.Method = 'GET'
        $resp = $req.GetResponse()
        try {
            $sr = [System.IO.StreamReader]::new($resp.GetResponseStream())
            $body = $sr.ReadToEnd()
            return ($body -match '<html|<div\s+id="app"')
        } finally { $resp.Dispose() }
    } catch { return $false }
}

function Get-LogTail {
    param([int]$Lines = 60)
    $merged = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($Script:SelfLog, $Script:LogFile)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            foreach ($l in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
                [void]$merged.Add($l)
            }
        } catch { }
    }
    if ($merged.Count -eq 0) { return '' }
    $start = [Math]::Max(0, $merged.Count - $Lines)
    return (Protect-Secrets ([string]::Join("`r`n", $merged.GetRange($start, $merged.Count - $start))))
}

function Test-StartupFailureInLog {
    $tail = Get-LogTail 200
    if ([string]::IsNullOrEmpty($tail)) { return $false }
    return ($tail -match '(?i)(生产模式拒绝启动|至少需要 32 字节|拒绝以默认密钥启动|db\.unavailable|StorageFailure|缺少 config\\application\.env)')
}

# ---- 预检：只读检查，绝不修改任何配置、绝不补默认值 ----
function Invoke-Preflight {
    $issues = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $Script:ConfigPath)) {
        [void]$issues.Add("缺少 config\application.env（请从模板复制并填写）")
    }
    if (-not (Test-Path -LiteralPath $Script:StartCmd)) {
        [void]$issues.Add("缺少 scripts\start.cmd（发布包不完整）")
    }
    if (-not (Test-Path -LiteralPath $Script:ServerExe)) {
        [void]$issues.Add("缺少 bin\ams-server.exe（发布包不完整）")
    }
    if (-not (Test-Path -LiteralPath $Script:WebIndex)) {
        [void]$issues.Add("缺少 web\index.html：前端页面将不可用")
    }

    $cfg = Read-Config
    # 与 main.cj:120-139 SEC-001 完全对齐的三项凭据
    foreach ($key in @('AMS_TOKEN_SECRET', 'AMS_KEK', 'AMS_DB_PASSWORD')) {
        if (-not $cfg.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($cfg[$key])) {
            [void]$issues.Add("$key 未显式配置（启动器不会为你生成或兜底）")
        }
    }
    if ($cfg.ContainsKey('AMS_TOKEN_SECRET') -and -not [string]::IsNullOrEmpty($cfg['AMS_TOKEN_SECRET'])) {
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($cfg['AMS_TOKEN_SECRET'])
        if ($bytes -lt 32) { [void]$issues.Add("AMS_TOKEN_SECRET 只有 $bytes 字节，服务端要求 >= 32 字节") }
    }

    $port = Get-Port
    if (-not (Test-PortFree $port)) {
        [void]$issues.Add("端口 $port 已被占用（启动器不会自动改用其它端口）")
    }

    if (Test-Path -LiteralPath $Script:DeployEnv) {
        # 只做提示，不读取、不覆盖
        [void]$issues.Add("注意：config\deployment.env 已存在，其优先级高于 application.env")
    }
    # 直接返回数组（不要用 ,$array 包裹，否则 @() 会把它当成单元素）
    return $issues.ToArray()
}

function Write-Log {
    param([string]$Message)
    if (-not (Test-Path -LiteralPath $Script:LogDir)) {
        [void][System.IO.Directory]::CreateDirectory($Script:LogDir)
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] [launcher] $(Protect-Secrets $Message)"
    [System.IO.File]::AppendAllText($Script:SelfLog, $line + "`r`n",
        (New-Object System.Text.UTF8Encoding($false)))
}

# ---- 启动：调用 start.cmd（唯一权威入口），仅追加输出重定向 ----
function Start-AmsService {
    $issues = @(Invoke-Preflight)
    $blocking = @($issues | Where-Object { $_ -notlike '注意：*' -and $_ -notlike '缺少 web*' })
    if ($blocking.Count -gt 0) {
        $msg = "预检未通过，未拉起任何进程：`r`n`r`n - " + ($blocking -join "`r`n - ")
        [System.Windows.Forms.MessageBox]::Show($msg, 'AMS · 无法启动',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        Write-Log "预检失败，拒绝启动：$($blocking -join '; ')"
        $Script:State = 'PreflightFailed'
        return $false
    }
    if ($issues.Count -gt 0) {
        $warn = "以下为非阻断提示：`r`n`r`n - " + ($issues -join "`r`n - ")
        [System.Windows.Forms.MessageBox]::Show($warn, 'AMS · 启动提示',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Script:LogDir)) {
        [void][System.IO.Directory]::CreateDirectory($Script:LogDir)
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $env:ComSpec
    # /s + 外层成对引号：cmd.exe 处理含空格路径的标准写法
    $psi.Arguments = '/d /s /c ""{0}" > "{1}" 2>&1"' -f $Script:StartCmd, $Script:LogFile
    $psi.WorkingDirectory = $Script:Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    try {
        $Script:Proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("启动 start.cmd 失败：$($_.Exception.Message)",
            'AMS · 启动失败', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Write-Log "Process.Start 失败：$($_.Exception.Message)"
        $Script:State = 'StartFailed'
        return $false
    }

    $Script:StartAt   = Get-Date
    $Script:LastExit  = $null
    $Script:ForcedKill = $false
    $Script:State     = 'Starting'
    Write-Log "已调用 scripts\start.cmd（PID=$($Script:Proc.Id)），等待就绪"
    return $true
}

function Stop-AmsService {
    if ($null -eq $Script:Proc) { return }
    if ($Script:Proc.HasExited) { return }

    $pidValue = $Script:Proc.Id
    # 优雅：先请求进程树终止（不带 /F）
    try {
        $k = [System.Diagnostics.ProcessStartInfo]::new()
        $k.FileName = 'taskkill.exe'
        $k.Arguments = "/PID $pidValue /T"
        $k.UseShellExecute = $false
        $k.CreateNoWindow = $true
        $kp = [System.Diagnostics.Process]::Start($k)
        $kp.WaitForExit(3000) | Out-Null
    } catch { }

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
        if ($Script:Proc.HasExited) { break }
    }

    if (-not $Script:Proc.HasExited) {
        # 显式标记为「强制终止」，绝不伪装成正常停止
        try {
            $f = [System.Diagnostics.ProcessStartInfo]::new()
            $f.FileName = 'taskkill.exe'
            $f.Arguments = "/PID $pidValue /T /F"
            $f.UseShellExecute = $false
            $f.CreateNoWindow = $true
            $fp = [System.Diagnostics.Process]::Start($f)
            $fp.WaitForExit(3000) | Out-Null
        } catch { }
        $Script:ForcedKill = $true
        Write-Log "优雅停止超时，已强制终止进程树 PID=$pidValue（强制终止，非正常停止）"
    } else {
        Write-Log "服务已优雅停止 PID=$pidValue"
    }
    $Script:State = 'Stopped'
}

# ---- 状态机（唯一判定逻辑；health 只作 liveness）----
function Update-State {
    $stateText = ''
    if ($null -ne $Script:Proc -and $Script:Proc.HasExited) {
        if ($null -eq $Script:LastExit) {
            $Script:LastExit = $Script:Proc.ExitCode
            if ($Script:LastExit -eq 0 -and -not $Script:ForcedKill) {
                $Script:State = 'Stopped'
            } else {
                $Script:State = 'Failed'
            }
            Write-Log "服务进程退出，退出码=$Script:LastExit，强制终止=$Script:ForcedKill（不会自动重启）"
        }
        $stateText = "已停止 / 退出码 $Script:LastExit" + $(if ($Script:ForcedKill) { '（强制终止）' } else { '' })
    } elseif ($Script:State -eq 'PreflightFailed') {
        $stateText = '预检失败（未拉起进程）'
    } elseif ($Script:State -eq 'StartFailed') {
        $stateText = '启动失败（详见日志）'
    } elseif ($null -eq $Script:Proc) {
        $stateText = '未启动'
    } else {
        $health = Test-Health
        $root   = if ($health) { Test-RootHtml } else { $false }
        $badLog = Test-StartupFailureInLog
        if ($badLog) {
            $Script:State = 'Failed'
            $stateText = '启动失败（日志含拒绝启动/凭据错误）'
        } elseif ($health -and $root) {
            $Script:State = 'Running'
            $stateText = '运行中（接口存活 + 前端可达）'
        } elseif ($health) {
            $Script:State = 'Starting'
            $stateText = '进程存活，但前端页面不可达'
        } else {
            $elapsed = ((Get-Date) - $Script:StartAt).TotalSeconds
            if ($elapsed -gt 30) {
                $Script:State = 'Failed'
                $stateText = '启动超时（30 秒内 /api/health 未响应）'
            } else {
                $stateText = '启动中…（等待 /api/health）'
            }
        }
    }

    $Script:StateLabel.Text = "状态：$stateText"
    $trayText = "AMS · $stateText"
    if ($trayText.Length -gt 60) { $trayText = $trayText.Substring(0, 60) }
    $Script:Tray.Text = $trayText
    $Script:LogBox.Text = Get-LogTail 60
    $Script:LogBox.SelectionStart = $Script:LogBox.Text.Length
    $Script:LogBox.ScrollToCaret()

    $running = ($null -ne $Script:Proc -and -not $Script:Proc.HasExited)
    $Script:BtnStart.Enabled  = -not $running
    $Script:BtnStop.Enabled   = $running
    $Script:BtnRestart.Enabled = $running
}

# ---- 配置向导：显式输入 / 显式生成 / 显式保存 ----
function New-RandomSecret {
    $bytes = New-Object byte[] 48
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Show-ConfigWizard {
    $cfg = Read-Config
    $w = [System.Windows.Forms.Form]::new()
    $w.Text = 'AMS · 首次配置向导'
    $w.Size = [System.Drawing.Size]::new(560, 470)
    $w.StartPosition = 'CenterParent'
    $w.FormBorderStyle = 'FixedDialog'
    $w.MaximizeBox = $false
    $w.MinimizeBox = $false

    $y = 16
    $boxes = @{}
    $fields = @(
        @{ Key='AMS_DB_HOST';       Label='数据库地址';        Secret=$false },
        @{ Key='AMS_DB_PORT';       Label='数据库端口';        Secret=$false },
        @{ Key='AMS_DB_NAME';       Label='数据库名';          Secret=$false },
        @{ Key='AMS_DB_USER';       Label='数据库用户';        Secret=$false },
        @{ Key='AMS_DB_PASSWORD';   Label='数据库口令';        Secret=$true  },
        @{ Key='AMS_TOKEN_SECRET';  Label='令牌密钥 (>=32B)';  Secret=$true  },
        @{ Key='AMS_KEK';           Label='字段加密密钥 KEK';  Secret=$true  },
        @{ Key='AMS_HTTP_HOST';     Label='监听地址';          Secret=$false },
        @{ Key='AMS_HTTP_PORT';     Label='监听端口';          Secret=$false }
    )

    foreach ($f in $fields) {
        $lbl = [System.Windows.Forms.Label]::new()
        $lbl.Text = $f.Label
        $lbl.Location = [System.Drawing.Point]::new(18, $y + 3)
        $lbl.Size = [System.Drawing.Size]::new(140, 20)
        [void]$w.Controls.Add($lbl)

        $tb = [System.Windows.Forms.TextBox]::new()
        $tb.Location = [System.Drawing.Point]::new(164, $y)
        $tb.Size = [System.Drawing.Size]::new(250, 22)
        if ($cfg.ContainsKey($f.Key)) { $tb.Text = $cfg[$f.Key] }
        if ($f.Secret) { $tb.UseSystemPasswordChar = $true }
        [void]$w.Controls.Add($tb)
        $boxes[$f.Key] = $tb

        if ($f.Key -eq 'AMS_TOKEN_SECRET' -or $f.Key -eq 'AMS_KEK') {
            $gen = [System.Windows.Forms.Button]::new()
            $gen.Text = '生成'
            $gen.Location = [System.Drawing.Point]::new(422, $y - 1)
            $gen.Size = [System.Drawing.Size]::new(60, 24)
            $target = $tb
            $gen.Add_Click({
                $ok = [System.Windows.Forms.MessageBox]::Show(
                    "将为本字段生成一个 48 字节随机密钥。`r`n`r`n" +
                    "· 仅在你显式点击后生成`r`n" +
                    "· 生成后只显示一次，请立即复制到密码管理器备份`r`n" +
                    "· 必须再点「保存」才会写入 config\application.env`r`n`r`n" +
                    "继续生成？", 'AMS · 生成密钥',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($ok -eq [System.Windows.Forms.DialogResult]::Yes) {
                    $target.UseSystemPasswordChar = $false
                    $target.Text = New-RandomSecret
                    [System.Windows.Forms.MessageBox]::Show(
                        "密钥已生成并临时显示，请立即复制备份。`r`n" +
                        "点击「保存」后才会落盘；本工具不会再次明文显示，也不会写入日志。",
                        'AMS · 请备份密钥',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                }
            }.GetNewClosure())
            [void]$w.Controls.Add($gen)
        }
        $y += 32
    }

    $note = [System.Windows.Forms.Label]::new()
    $note.Text = "说明：仅写 config\application.env；不写 deployment.env、不创建管理员。`r`n" +
                 "数据库 / SMTP / 管理员请在启动后由浏览器中的 /setup 向导完成。`r`n" +
                 "启动器绝不为你生成或兜底任何密钥。"
    $note.Location = [System.Drawing.Point]::new(18, $y + 6)
    $note.Size = [System.Drawing.Size]::new(510, 48)
    $note.ForeColor = [System.Drawing.Color]::DimGray
    [void]$w.Controls.Add($note)

    $save = [System.Windows.Forms.Button]::new()
    $save.Text = '保存'
    $save.Location = [System.Drawing.Point]::new(300, 400)
    $save.Size = [System.Drawing.Size]::new(100, 28)
    $save.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "确认把以上值写入 config\application.env？`r`n`r`n" +
            "该文件含明文密钥，请妥善设置文件权限并自行备份原文件。`r`n" +
            "保存后仍需通过预检，服务端 SEC-001 才是最终判定者。",
            'AMS · 确认落盘',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            foreach ($k in $boxes.Keys) { Set-ConfigValue -Key $k -Value $boxes[$k].Text }
            Write-Log '配置向导已显式写盘 config\application.env（键值不记录）'
            [System.Windows.Forms.MessageBox]::Show('已保存。请返回主窗口点击「启动」。',
                'AMS', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            $w.Close()
        }
    })
    [void]$w.Controls.Add($save)

    $cancel = [System.Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.Location = [System.Drawing.Point]::new(410, 400)
    $cancel.Size = [System.Drawing.Size]::new(100, 28)
    $cancel.Add_Click({ $w.Close() })
    [void]$w.Controls.Add($cancel)

    [void]$w.ShowDialog()
}

# ---- 单实例保护 ----
$mutexName = 'Local\AMS-Launcher-' + [Math]::Abs($Script:Root.ToLowerInvariant().GetHashCode())
$createdNew = $false
$Script:InstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show('AMS 启动器已在运行（单实例保护）。', 'AMS',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit 0
}

# ---- 主窗口 ----
$form = [System.Windows.Forms.Form]::new()
$form.Text = 'AMS · 个人档案管理系统  启动器'
$form.Size = [System.Drawing.Size]::new(680, 460)
$form.StartPosition = 'CenterScreen'
$form.Icon = [System.Drawing.SystemIcons]::Application

$Script:StateLabel = [System.Windows.Forms.Label]::new()
$Script:StateLabel.Text = '状态：未启动'
$Script:StateLabel.Location = [System.Drawing.Point]::new(16, 14)
$Script:StateLabel.Size = [System.Drawing.Size]::new(620, 24)
$Script:StateLabel.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 11)
[void]$form.Controls.Add($Script:StateLabel)

$btnDefs = @(
    @{ Name='BtnStart';   Text='启动';     X=16  },
    @{ Name='BtnStop';    Text='停止';     X=116 },
    @{ Name='BtnRestart'; Text='重启';     X=216 },
    @{ Name='BtnOpen';    Text='打开浏览器'; X=316 },
    @{ Name='BtnWizard';  Text='配置向导'; X=436 },
    @{ Name='BtnLogFile'; Text='日志文件'; X=536 }
)
foreach ($d in $btnDefs) {
    $b = [System.Windows.Forms.Button]::new()
    $b.Text = $d.Text
    $b.Location = [System.Drawing.Point]::new($d.X, 48)
    $b.Size = [System.Drawing.Size]::new(92, 28)
    [void]$form.Controls.Add($b)
    Set-Variable -Name $d.Name -Value $b -Scope Script
}
$Script:BtnStart.Enabled = $true
$Script:BtnStop.Enabled = $false
$Script:BtnRestart.Enabled = $false

$Script:LogBox = [System.Windows.Forms.TextBox]::new()
$Script:LogBox.Multiline = $true
$Script:LogBox.ReadOnly = $true
$Script:LogBox.ScrollBars = 'Vertical'
# 必须自动换行：WordWrap=false 时 ScrollToCaret() 会把视图水平滚到长行末尾，
# 导致时间戳与中文前缀被裁掉（真实 GUI 实测发现）。
$Script:LogBox.WordWrap = $true
$Script:LogBox.Font = [System.Drawing.Font]::new('Consolas', 9)
$Script:LogBox.Location = [System.Drawing.Point]::new(16, 88)
$Script:LogBox.Size = [System.Drawing.Size]::new(632, 300)
$Script:LogBox.BackColor = [System.Drawing.Color]::White
[void]$form.Controls.Add($Script:LogBox)

$hint = [System.Windows.Forms.Label]::new()
$hint.Text = '日志已按密钥键名脱敏。启动器不会自动重启服务；服务退出后请查看日志并手动处理。'
$hint.Location = [System.Drawing.Point]::new(16, 396)
$hint.Size = [System.Drawing.Size]::new(632, 20)
$hint.ForeColor = [System.Drawing.Color]::DimGray
[void]$form.Controls.Add($hint)

# ---- 托盘 ----
$Script:Tray = [System.Windows.Forms.NotifyIcon]::new()
$Script:Tray.Icon = [System.Drawing.SystemIcons]::Application
$Script:Tray.Text = 'AMS · 未启动'
$Script:Tray.Visible = $true
$trayMenu = [System.Windows.Forms.ContextMenuStrip]::new()
$miShow = [System.Windows.Forms.ToolStripMenuItem]::new('显示主窗口')
$miShow.Add_Click({ $form.Show(); $form.WindowState = 'Normal' })
$miStart = [System.Windows.Forms.ToolStripMenuItem]::new('启动服务')
$miStart.Add_Click({ [void](Start-AmsService) })
$miStop = [System.Windows.Forms.ToolStripMenuItem]::new('停止服务')
$miStop.Add_Click({ Stop-AmsService })
$miExit = [System.Windows.Forms.ToolStripMenuItem]::new('退出启动器')
$miExit.Add_Click({ $form.Close() })
[void]$trayMenu.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@($miShow, $miStart, $miStop, $miExit))
$Script:Tray.ContextMenuStrip = $trayMenu
$Script:Tray.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal' })

# ---- 事件 ----
$Script:BtnStart.Add_Click({ [void](Start-AmsService) })
$Script:BtnStop.Add_Click({ Stop-AmsService })
$Script:BtnRestart.Add_Click({ Stop-AmsService; Start-Sleep -Milliseconds 500; [void](Start-AmsService) })
$Script:BtnWizard.Add_Click({ Show-ConfigWizard })
$Script:BtnLogFile.Add_Click({
    if (Test-Path -LiteralPath $Script:LogFile) {
        [void][System.Diagnostics.Process]::Start('notepad.exe', $Script:LogFile)
    } else {
        [System.Windows.Forms.MessageBox]::Show('尚无日志文件。', 'AMS') | Out-Null
    }
})
$Script:BtnOpen.Add_Click({
    $port = Get-Port
    [void][System.Diagnostics.Process]::Start("http://127.0.0.1:$port/")
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($null -ne $Script:Proc -and -not $Script:Proc.HasExited) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            '服务仍在运行。退出启动器不会自动停止服务。`r`n`r`n是否一并停止服务？',
            'AMS · 退出', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { $e.Cancel = $true; return }
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { Stop-AmsService }
    }
    $Script:Tray.Visible = $false
    $Script:Tray.Dispose()
})

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 2000
$timer.Add_Tick({ Update-State })
$timer.Start()

Write-Log '启动器已就绪；未自动启动服务（请显式点击「启动」）'
[void][System.Windows.Forms.Application]::Run($form)
$timer.Stop()
$Script:InstanceMutex.ReleaseMutex()
