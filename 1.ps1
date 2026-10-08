# FullUnlock.ps1 - 极域键盘锁双层解锁（内核驱动清理 + 用户态循环挂钩）
# 以管理员身份运行
# 保存为 UTF-8 with BOM 编码

# ================= 权限检查 =================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] 请以管理员身份运行此脚本！" -ForegroundColor Red
    Read-Host "按 Enter 退出"
    exit 1
}

$ErrorActionPreference = "SilentlyContinue"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  极域键盘锁双层解锁工具" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ================= 第一部分：内核驱动清理 =================
Write-Host "【第一部分】清除 TDKeybd.sys 内核驱动" -ForegroundColor Yellow
Write-Host ""

# 1. 获取键盘类驱动注册表项所有权
$regKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E96B-E325-11CE-BFC1-08002BE10318}"
$regPath = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\{4D36E96B-E325-11CE-BFC1-08002BE10318}"

Write-Host "[*] 获取注册表项所有权..." -ForegroundColor Gray
takeown /f $regPath /r 2>&1 | Out-Null
icacls $regPath /grant administrators:F 2>&1 | Out-Null

# 2. 从 UpperFilters 中移除 TDKeybd
$filters = (Get-ItemProperty -Path $regKey -Name "UpperFilters" -ErrorAction SilentlyContinue).UpperFilters
if ($filters -match "TDkeybd") {
    $newFilters = $filters | Where-Object { $_ -notmatch "TDkeybd" }
    Set-ItemProperty -Path $regKey -Name "UpperFilters" -Value $newFilters -Type MultiString
    Write-Host "[+] 已从 UpperFilters 移除 TDkeybd" -ForegroundColor Green
} else {
    Write-Host "[!] UpperFilters 中未找到 TDkeybd" -ForegroundColor Gray
}

# 3. 删除服务注册表项
Write-Host "[*] 删除服务注册表项..." -ForegroundColor Gray
$svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\TDKeybd"
if (Test-Path $svcKey) {
    takeown /f "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\TDKeybd" /r 2>&1 | Out-Null
    icacls "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\TDKeybd" /grant administrators:F 2>&1 | Out-Null
    Remove-Item -Path $svcKey -Recurse -Force
    Write-Host "[+] 服务注册表项已删除" -ForegroundColor Green
} else {
    Write-Host "[!] 服务注册表项不存在" -ForegroundColor Gray
}

# 4. 删除驱动文件
Write-Host "[*] 删除驱动文件..." -ForegroundColor Gray
$driverPaths = @(
    "C:\Windows\System32\drivers\TDKeybd.sys",
    "C:\Windows\SysWOW64\drivers\TDKeybd.sys"
)
foreach ($path in $driverPaths) {
    if (Test-Path $path) {
        takeown /f $path 2>&1 | Out-Null
        icacls $path /grant administrators:F 2>&1 | Out-Null
        if (Remove-Item -Path $path -Force -ErrorAction SilentlyContinue) {
            Write-Host "[+] 已删除: $path" -ForegroundColor Green
        } else {
            Write-Host "[!] 文件被占用，未能删除（内存中驱动仍在运行）: $path" -ForegroundColor DarkYellow
        }
    }
}
Write-Host "[*] 内核驱动清理阶段完成。若驱动已加载，需重启才能彻底生效。" -ForegroundColor Yellow
Write-Host ""

# ================= 第二部分：用户态循环挂钩 =================
Write-Host "【第二部分】启动用户态循环挂钩" -ForegroundColor Yellow
Write-Host ""

$code = @"
using System;
using System.Runtime.InteropServices;
using System.Threading;

public class HookLooper
{
    private const int WH_KEYBOARD_LL = 13;
    private const int PM_REMOVE = 0x0001;

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int pt_x;
        public int pt_y;
    }

    public static volatile int HookCount = 0;
    public static volatile bool Running = true;

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        // 返回 0：消息不再传递给后续钩子（包括极域的钩子），按键恢复正常
        return IntPtr.Zero;
    }

    public static void Start()
    {
        Thread thread = new Thread(() =>
        {
            LowLevelKeyboardProc proc = HookCallback;
            while (Running)
            {
                IntPtr hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, IntPtr.Zero, 0);
                if (hook != IntPtr.Zero)
                {
                    HookCount++;
                    uint startTime = (uint)Environment.TickCount;
                    MSG msg;
                    while ((uint)Environment.TickCount - startTime < 50 && Running)
                    {
                        while (PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_REMOVE))
                        {
                            TranslateMessage(ref msg);
                            DispatchMessage(ref msg);
                        }
                        Thread.Sleep(1);
                    }
                    UnhookWindowsHookEx(hook);
                }
                Thread.Sleep(10);
            }
        });
        thread.IsBackground = true;
        thread.Start();
    }

    public static void Stop()
    {
        Running = false;
    }
}
"@

Add-Type -TypeDefinition $code -Language CSharp
[HookLooper]::Start()

Write-Host "[+] 循环挂钩已启动。" -ForegroundColor Green
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  解锁已激活" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "[*] 保持此窗口运行，按键将不再被极域拦截。" -ForegroundColor White
Write-Host "[*] 按 Ctrl+C 停止解锁。" -ForegroundColor White
Write-Host ""

# 定时打印挂钩状态
$counter = 0
while ($true) {
    Start-Sleep -Seconds 10
    $counter++
    $hookCount = [HookLooper]::HookCount
    Write-Host "[状态] 已运行 $($counter * 10) 秒，累计安装钩子 $hookCount 次。" -ForegroundColor DarkGray
}