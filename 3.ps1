
$ErrorActionPreference = "Stop"

$Root = "$env:ProgramData\USBGuard"
$MonitorTask = "USBGuard-Monitor"
$LockTask = "USBGuard-InteractiveLock"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw "请以管理员身份打开 PowerShell 后再运行。"
}

# 停止监控任务
Stop-ScheduledTask -TaskName $MonitorTask `
    -ErrorAction SilentlyContinue

# 删除计划任务
Unregister-ScheduledTask -TaskName $MonitorTask `
    -Confirm:$false -ErrorAction SilentlyContinue

Unregister-ScheduledTask -TaskName $LockTask `
    -Confirm:$false -ErrorAction SilentlyContinue

# 清理可能残留的监控 PowerShell 进程
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine.Contains("USBGuard-Monitor.ps1")
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force `
            -ErrorAction SilentlyContinue
    }

# 删除程序和日志目录
if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}

Write-Host "USBGuard 已卸载。" -ForegroundColor Green
