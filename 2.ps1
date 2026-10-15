
$ErrorActionPreference = "Stop"

$Root = "$env:ProgramData\USBGuard"
$Worker = "$Root\USBGuard-Monitor.ps1"
$Log = "$Root\USBGuard.log"
$MonitorTask = "USBGuard-Monitor"
$LockTask = "USBGuard-InteractiveLock"

# 要求当前 PowerShell 已经以管理员身份运行
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw "请以管理员身份打开 PowerShell 后再运行。"
}

$user = $identity.Name

New-Item -ItemType Directory -Path $Root -Force | Out-Null

# 限制监控脚本目录权限
& icacls.exe $Root /inheritance:r `
    /grant:r "*S-1-5-18:(OI)(CI)F" `
             "*S-1-5-32-544:(OI)(CI)F" | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "设置程序目录权限失败。"
}

# 创建监控脚本
$workerCode = @'
$ErrorActionPreference = "Continue"

$Root = "$env:ProgramData\USBGuard"
$Log = Join-Path $Root "USBGuard.log"
$LockTask = "\USBGuard-InteractiveLock"

function Write-Log([string]$Message) {
    try {
        Add-Content -LiteralPath $Log -Encoding UTF8 `
            -Value "$(Get-Date -Format o) $Message"

        if ((Get-Item $Log -ErrorAction SilentlyContinue).Length -gt 5MB) {
            Move-Item -LiteralPath $Log -Destination "$Log.old" -Force
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

Write-Log "USBGuard 监控启动，扫描间隔 500ms"

try {
    $previous = Get-UsbSnapshot
} catch {
    Write-Log "初始设备枚举失败：$($_.Exception.Message)"
    $previous = @()
}

while ($true) {
    Start-Sleep -Milliseconds 500

    try {
        $current = Get-UsbSnapshot

        $added = @($current | Where-Object { $_ -notin $previous })
        $removed = @($previous | Where-Object { $_ -notin $current })

        if ($added.Count -gt 0 -or $removed.Count -gt 0) {
            Write-Log "设备变化：新增 $($added.Count)，移除 $($removed.Count)"

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
        Write-Log "设备扫描失败：$($_.Exception.Message)"
        Start-Sleep -Seconds 2
    }
}
'@

Set-Content -LiteralPath $Worker -Value $workerCode -Encoding UTF8

# 创建交互式锁屏任务
$lockAction = New-ScheduledTaskAction `
    -Execute "$env:WINDIR\System32\rundll32.exe" `
    -Argument "user32.dll,LockWorkStation"

$lockTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user

$lockPrincipal = New-ScheduledTaskPrincipal `
    -UserId $user -LogonType Interactive -RunLevel Limited

$lockSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $LockTask `
    -Action $lockAction `
    -Trigger $lockTrigger `
    -Principal $lockPrincipal `
    -Settings $lockSettings `
    -Force | Out-Null

# 创建 SYSTEM 开机监控任务
$ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

$monitorAction = New-ScheduledTaskAction `
    -Execute $ps `
    -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Worker`""

$monitorTrigger = New-ScheduledTaskTrigger -AtStartup

$monitorPrincipal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

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
Write-Host "USBGuard 安装完成。" -ForegroundColor Green
Write-Host "运行账户：SYSTEM"
Write-Host "启动方式：开机自动启动"
Write-Host "扫描间隔：500 毫秒"
Write-Host "锁屏账户：$user"
Write-Host "日志位置：$Log"
Write-Host ""
Write-Host "验证命令："
Write-Host "Get-ScheduledTask -TaskName 'USBGuard-Monitor'"
Write-Host "Get-Content '$Log' -Tail 30"