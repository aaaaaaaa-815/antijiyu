
@'
$ErrorActionPreference = "SilentlyContinue"

Write-Host "Cleaning Remote Desktop history..."

$rdpPath = "HKCU:\Software\Microsoft\Terminal Server Client"

# Remove saved server addresses
$serversPath = Join-Path $rdpPath "Servers"
if (Test-Path $serversPath) {
    Remove-Item $serversPath -Recurse -Force
}

# Remove recent connection entries
$defaultPath = Join-Path $rdpPath "Default"
if (Test-Path $defaultPath) {
    $item = Get-ItemProperty -Path $defaultPath
    $item.PSObject.Properties |
        Where-Object { $_.Name -match '^MRU\d+$' } |
        ForEach-Object {
            Remove-ItemProperty -Path $defaultPath -Name $_.Name -Force
        }
}

# Remove default username hint
Remove-ItemProperty -Path $rdpPath -Name "UsernameHint" -Force

# Remove saved RDP credentials
$output = & cmdkey.exe /list 2>&1
$targets = @()

foreach ($line in $output) {
    if ($line -match '(?i)TERMSRV/([^\s]+)') {
        $targets += "TERMSRV/$($Matches[1])"
    }
}

$targets | Sort-Object -Unique | ForEach-Object {
    & cmdkey.exe "/delete:$_" 2>&1 | Out-Null
}

Write-Host "Remote Desktop history cleanup completed."
Read-Host "Press Enter to exit"
'@ | Set-Content -LiteralPath "$env:USERPROFILE\Desktop\4.ps1" -Encoding UTF8
