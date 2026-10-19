# Windows 10：清除远程桌面连接历史及已保存凭据
# 仅清理当前 Windows 用户的记录

$ErrorActionPreference = "SilentlyContinue"

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "   Windows 远程桌面记录清理工具"
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# 1. 清除远程桌面连接历史记录
$rdpPath = "HKCU:\Software\Microsoft\Terminal Server Client"

# 删除已记录的远程服务器 IP 和主机名
$serversPath = Join-Path $rdpPath "Servers"
if (Test-Path $serversPath) {
    Remove-Item $serversPath -Recurse -Force
    Write-Host "[完成] 已清除远程服务器地址历史" -ForegroundColor Green
}

# 清除远程桌面最近连接列表（MRU）
$defaultPath = Join-Path $rdpPath "Default"
if (Test-Path $defaultPath) {
    $properties = Get-ItemProperty -Path $defaultPath
    $properties.PSObject.Properties |
        Where-Object { $_.Name -match '^MRU\d+$' } |
        ForEach-Object {
            Remove-ItemProperty -Path $defaultPath `
                -Name $_.Name -Force
        }
    Write-Host "[完成] 已清除最近连接列表" -ForegroundColor Green
}

# 2. 清除远程桌面默认用户名提示
if (Test-Path $rdpPath) {
    Remove-ItemProperty -Path $rdpPath `
        -Name "UsernameHint" -Force
}

# 3. 删除当前用户保存的远程桌面凭据
# 只处理目标名称中包含 TERMSRV/ 的凭据
$credentialOutput = & cmdkey.exe /list 2>&1
$targets = @()

foreach ($line in $credentialOutput) {
    if ($line -match '(?i)TERMSRV/([^\s]+)') {
        $target = "TERMSRV/" + $Matches[1].Trim()
        $targets += $target
    }
}

$targets = $targets | Sort-Object -Unique

foreach ($target in $targets) {
    & cmdkey.exe "/delete:$target" 2>&1 | Out-Null
    Write-Host "[处理] $target" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "清理操作已执行！" -ForegroundColor Green
Write-Host "建议重新打开远程桌面验证。" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "按回车键退出"