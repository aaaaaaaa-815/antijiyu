
param(
    [ValidateSet("Install", "Uninstall", "Status")]
    [string]$Mode = "Install"
)

$ErrorActionPreference = "Stop"

$Root = Join-Path $env:ProgramData "USBGuard"
$Worker = Join-Path $Root "USBGuard-Monitor.ps1"
$Log = Join-Path $Root "USBGuard.log"
$MonitorTask = "USBGuard-Monitor"
$LockTask = "USBGuard-InteractiveLock"

# 必须由当前管理员 PowerShell 运行，不额外弹出 UAC
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw "请先以管理员身份打开 PowerShell，再执行安装命令。"
}

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

if ($Mode -eq "Status") {
    Get-ScheduledTask -TaskName $MonitorTask -ErrorAction SilentlyContinue |
        Select-Object TaskName, State

    Get-ScheduledTask -TaskName $LockTask -ErrorAction SilentlyContinue |
        Select-Object TaskName, State

    if (Test-Path $Log) {
        Get-Content -LiteralPath $Log -Tail 50
    }
    return
}

if ($Mode -eq "Uninstall") {
    Stop-ScheduledTask -TaskName $MonitorTask `
        -ErrorAction SilentlyContinue

    Unregister-ScheduledTask -TaskName $MonitorTask `
        -Confirm:$false -ErrorAction SilentlyContinue

    Unregister-ScheduledTask -TaskName $LockTask `
        -Confirm:$false -ErrorAction SilentlyContinue

    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine.Contains("USBGuard-Monitor.ps1")
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force `
                -ErrorAction SilentlyContinue
        }

    Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "USBGuard 已卸载。" -ForegroundColor Green
    return
}

# 创建程序目录
New-Item -ItemType Directory -Path $Root -Force | Out-Null

# SYSTEM 和本机管理员可以修改；普通用户不可写
& icacls.exe $Root /inheritance:r `
    /grant:r "*S-1-5-18:(OI)(CI)F" `
             "*S-1-5-32-544:(OI)(CI)F" | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "无法设置程序目录权限。"
}

# 后台监控程序
$workerCode = @'
$ErrorActionPreference = "Continue"

$Root = "$env:ProgramData\USBGuard"
$Log = Join-Path $Root "USBGuard.log"
$LockTask = "\USBGuard-InteractiveLock"

function Write-Log([string]$Message) {
    try {
        Add-Content -LiteralPath $Log -Encoding UTF8 `
            -Value "$(Get-Date -Format o) $Message"

        # 防止日志无限增长
        if ((Get-Item $Log -ErrorAction SilentlyContinue).Length -gt 5MB) {
            Move-Item $Log "$Log.old" -Force
        }
    } catch {}
}

function Get-UsbSnapshot {
    $ids = Get-CimInstance -ClassName Win32_PnPEntity `
        -ErrorAction Stop |
        Where-Object {
            $_.PNPDeviceID -and (
                $_.PNPDeviceID.StartsWith(
                    "USB\", [StringComparison]::OrdinalIgnoreCase
                ) -or
                $_.PNPDeviceID.StartsWith(
                    "USBSTOR\", [StringComparison]::OrdinalIgnoreCase
                )
            )
        } |
        ForEach-Object { $_.PNPDeviceID } |
        Sort-Object -Unique

    return ,@($ids)
}

Write-Log "监控启动，扫描间隔 500 毫秒"

# 首次读取只建立基线，不因已有设备而锁屏
try {
    $previous = Get-UsbSnapshot
} catch {
    Write-Log "首次枚举失败：$($_.Exception.Message)"
    $previous = @()
}

while ($true) {
    Start-Sleep -Milliseconds 500

    try {
        $current = Get-UsbSnapshot

        $added = @(
            $current | Where-Object { $_ -notin $previous }
        )
        $removed = @(
            $previous | Where-Object { $_ -notin $current }
        )

        if ($added.Count -gt 0 -or $removed.Count -gt 0) {
            Write-Log (
                "设备变化：新增 {0}，移除 {1}" -f
                $added.Count, $removed.Count
            )

            try {
                $output = & "$env:WINDIR\System32\schtasks.exe" `
                    /Run /TN $LockTask 2>&1

                Write-Log "锁屏任务请求：$output"
            } catch {
                Write-Log "锁屏任务调用失败：$($_.Exception.Message)"
            }

            $previous = $current
        }
    } catch {
        # 枚举失败时不覆盖原有基线，避免临时故障造成误判
        Write-Log "USB 枚举失败：$($_.Exception.Message)"
        Start-Sleep -Seconds 2
    }
}
'@

Set-Content -LiteralPath $Worker -Value $workerCode -Encoding UTF8

# 锁屏任务：在当前管理员的交互式登录会话中执行
$lockAction = New-ScheduledTaskAction `
    -Execute "$env:WINDIR\System32\rundll32.exe" `
    -Argument "user32.dll,LockWorkStation"

$lockTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user

$lockPrincipal = New-ScheduledTaskPrincipal `
    -UserId $user `
    -LogonType Interactive `
    -RunLevel Limited

$lockSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $LockTask `
    -Action $lockAction `
    -Trigger $lockTrigger `
    -Principal $lockPrincipal `
    -Settings $lockSettings `
    -Force | Out-Null

# 监控任务：SYSTEM 身份，开机启动，不限制运行时间
$ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

$monitorAction = New-ScheduledTaskAction `
    -Execute $ps `
    -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Worker`""

$monitorTrigger = New-ScheduledTaskTrigger -AtStartup

$monitorPrincipal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

$monitorSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $MonitorTask `
    -Action $monitorAction `
    -Trigger $monitorTrigger `
    -Principal $monitorPrincipal `
    -Settings $monitorSettings `
    -Force | Out-Null

Start-ScheduledTask -TaskName $MonitorTask

Write-Host ""
Write-Host "USBGuard 安装完成" -ForegroundColor Green
Write-Host "监控身份：SYSTEM"
Write-Host "启动方式：开机自动启动"
Write-Host "扫描间隔：500 毫秒"
Write-Host "锁屏账户：$user"
Write-Host "日志文件：$Log"
Write-Host ""
Write-Host "检查状态：再次执行安装脚本，Mode 改为 Status"
Write-Host "卸载方式：再次执行安装脚本，Mode 改为 Uninstall"
