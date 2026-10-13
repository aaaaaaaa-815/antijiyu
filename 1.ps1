# LockHotkeys.ps1
# Ctrl+Shift+C  -> 锁屏 (独占，吞掉按键)
# Scroll Lock   -> 锁屏 (非独占，继续传递)
# 低级键盘钩子，高进程优先级

Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class MultiLockHotkey
{
    private const int WH_KEYBOARD_LL   = 13;
    private const int WM_KEYDOWN       = 0x0100;
    private const int WM_SYSKEYDOWN    = 0x0104;
    private const int VK_CONTROL       = 0x11;
    private const int VK_SHIFT         = 0x10;
    private const int VK_C             = 0x43;
    private const int VK_SCROLL        = 0x91;

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    private static extern bool LockWorkStation();

    [DllImport("kernel32.dll")]
    private static extern bool SetPriorityClass(IntPtr hProcess, uint dwPriorityClass);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    private const uint HIGH_PRIORITY_CLASS = 0x00000080;

    private static IntPtr _hookID = IntPtr.Zero;
    private static LowLevelKeyboardProc _proc = HookCallback;
    private static DateTime _lastFireCtrlC = DateTime.MinValue;
    private static DateTime _lastFireScroll = DateTime.MinValue;
    private static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(800);

    public static void Start()
    {
        // 提升进程优先级，保证钩子回调及时响应
        SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);

        _hookID = SetHook(_proc);
        Application.Run(); // 消息循环，保持钩子有效
        UnhookWindowsHookEx(_hookID);
    }

    private static IntPtr SetHook(LowLevelKeyboardProc proc)
    {
        using (Process curProcess = Process.GetCurrentProcess())
        using (ProcessModule curModule = curProcess.MainModule)
        {
            return SetWindowsHookEx(WH_KEYBOARD_LL, proc,
                GetModuleHandle(curModule.ModuleName), 0);
        }
    }

    // 异步锁屏，避免钩子回调超时（300ms 预算）
    private static void FireLock()
    {
        System.Threading.ThreadPool.QueueUserWorkItem(_ =>
        {
            try { LockWorkStation(); } catch { }
        });
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN))
        {
            int vkCode = Marshal.ReadInt32(lParam);

            // ---- 1) Ctrl + Shift + C -> 锁屏，独占 ----
            if (vkCode == VK_C)
            {
                bool ctrl  = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
                bool shift = (GetAsyncKeyState(VK_SHIFT)   & 0x8000) != 0;
                if (ctrl && shift)
                {
                    if (DateTime.Now - _lastFireCtrlC > Debounce)
                    {
                        _lastFireCtrlC = DateTime.Now;
                        FireLock();
                    }
                    // 独占：吞掉 C 键，不再向下传递
                    return (IntPtr)1;
                }
            }

            // ---- 2) Scroll Lock -> 锁屏，非独占 ----
            if (vkCode == VK_SCROLL)
            {
                if (DateTime.Now - _lastFireScroll > Debounce)
                {
                    _lastFireScroll = DateTime.Now;
                    FireLock();
                }
                // 不吞键：继续向下传递
            }
        }

        return CallNextHookEx(_hookID, nCode, wParam, lParam);
    }
}
"@ -ReferencedAssemblies System.Windows.Forms

Write-Host "[*] 已启动全局热键监听："
Write-Host "    Ctrl+Shift+C  -> 锁屏 (独占)"
Write-Host "    Scroll Lock   -> 锁屏 (非独占)"
Write-Host "    按 Ctrl+C 退出"
[MultiLockHotkey]::Start()
