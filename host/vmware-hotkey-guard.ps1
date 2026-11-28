<#
.SYNOPSIS
    Stops VMware Workstation's Ctrl+E (Power Off), Ctrl+R (Reset) and Ctrl+Z
    (Suspend) from hitting your VM by accident. Runs on the Windows host, in the tray.

.DESCRIPTION
    Those keys are Workstation menu shortcuts. They act on the VM whenever the VM does
    not have the keyboard: the pointer drifted onto the toolbar, the tabs or another
    screen, you came back with Alt+Tab, or you pressed Ctrl+Alt. Power Off is instant.

    While a VMware window is in front, this claims Ctrl+E, Ctrl+R and Ctrl+Z as Windows
    hotkeys. Windows looks at hotkeys only after VMware has taken the keys that go to
    the VM, so inside the VM they work as usual (end of line, history search, suspend a
    job). Only a key that would reach Workstation's menu is dropped, with a notice to
    click into the VM. Other programs see no difference.

    No admin rights, nothing installed, no setting changed. Exit it from its tray icon
    (the shield) and Workstation behaves as before. To power off on purpose, use the VM
    menu or the toolbar.

    Tip: Edit > Preferences > Input > "Grab keyboard and mouse input on key press" in
    Workstation makes the first key you press over the VM go to the VM.

.PARAMETER Install
    Also start it at every login: copies it to %LOCALAPPDATA%\kali-clean and adds a
    shortcut to your Startup folder.

.PARAMETER Uninstall
    Stop it and undo -Install.

.PARAMETER RestorePrompts
    Bring back Workstation's own "power off?" and "reset?" questions if they were
    switched off with "Do not show again". Close Workstation first; it edits
    %APPDATA%\VMware\preferences.ini and keeps a backup next to it.

.PARAMETER Quiet
    Drop the keys without showing a notice.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\vmware-hotkey-guard.ps1 -Install

.EXAMPLE
    iwr -UseBasicParsing https://raw.githubusercontent.com/flarycen/kali-clean/main/host/vmware-hotkey-guard.ps1 -OutFile $env:TEMP\vmware-hotkey-guard.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\vmware-hotkey-guard.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$RestorePrompts,
    [switch]$Quiet,
    [switch]$Run    # internal: the tray process itself
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This runs on the Windows host (where VMware Workstation runs), not inside Kali.'
}

$MutexName  = 'Local\kali-clean.vmware-hotkey-guard'
$StopName   = 'Local\kali-clean.vmware-hotkey-guard.stop'
$InstallDir = Join-Path $env:LOCALAPPDATA 'kali-clean'
$Installed  = Join-Path $InstallDir 'vmware-hotkey-guard.ps1'
$Shortcut   = Join-Path ([Environment]::GetFolderPath('Startup')) 'VMware hotkey guard.lnk'
$WinPS      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Self       = $PSCommandPath

# The tray process. C# 5 on purpose: Windows PowerShell 5.1 compiles it with the
# .NET Framework compiler.
$Source = @'
using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace KaliClean
{
    public sealed class VmwareHotkeyGuard : NativeWindow
    {
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        [DllImport("user32.dll")]
        static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);

        delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hwnd, int idObject,
                                   int idChild, uint eventThread, uint eventTime);

        [DllImport("user32.dll")]
        static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventProc proc,
                                             uint processId, uint threadId, uint flags);

        [DllImport("user32.dll")]
        static extern bool UnhookWinEvent(IntPtr hook);

        const int WM_HOTKEY = 0x0312;
        const uint MOD_CONTROL = 0x0002;
        const uint MOD_NOREPEAT = 0x4000;
        const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
        const uint WINEVENT_OUTOFCONTEXT = 0x0000;
        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        // Workstation's menu shortcuts that power off, reset or suspend the VM.
        static readonly char[] Letters = { 'E', 'R', 'Z' };
        static readonly string[] Actions = { "Power Off", "Reset", "Suspend" };
        static readonly string[] Programs = { "vmware.exe", "vmplayer.exe" };

        readonly bool quiet;
        readonly WaitHandle stop;
        readonly WinEventProc onForeground;  // kept in a field so the callback is never collected
        readonly IntPtr hook;
        readonly NotifyIcon tray;
        readonly ToolStripMenuItem counter;
        readonly System.Windows.Forms.Timer timer;
        IntPtr lastWindow;
        uint lastProcess;
        bool lastResult;
        bool armed;
        int blocked;
        DateTime lastNotice = DateTime.MinValue;

        VmwareHotkeyGuard(bool quiet, WaitHandle stop)
        {
            this.quiet = quiet;
            this.stop = stop;
            CreateHandle(new CreateParams());   // hidden; only receives WM_HOTKEY

            counter = new ToolStripMenuItem("Nothing blocked yet");
            counter.Enabled = false;
            var menu = new ContextMenuStrip();
            menu.Items.Add(counter);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Exit", null, delegate { Application.ExitThread(); }));

            tray = new NotifyIcon();
            tray.Icon = SystemIcons.Shield;
            tray.Text = "VMware hotkey guard (Ctrl+E/R/Z)";
            tray.ContextMenuStrip = menu;
            tray.Visible = true;

            onForeground = delegate
            {
                try { Sync(); }
                catch (Exception e) { Log(e.ToString()); }   // never let it escape into Windows
            };
            hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero,
                                   onForeground, 0, 0, WINEVENT_OUTOFCONTEXT);

            // Also re-check a few times a second (cheap), and watch for -Uninstall.
            timer = new System.Windows.Forms.Timer();
            timer.Interval = 250;
            timer.Tick += delegate
            {
                if (this.stop.WaitOne(0)) Application.ExitThread();
                else Sync();
            };
            timer.Start();
            Sync();
        }

        bool IsVmware(IntPtr window)
        {
            if (window == IntPtr.Zero) return false;
            uint pid;
            GetWindowThreadProcessId(window, out pid);
            if (pid == 0) return false;
            if (window == lastWindow && pid == lastProcess) return lastResult;

            bool result = false;
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (process != IntPtr.Zero)
            {
                try
                {
                    var path = new StringBuilder(1024);
                    uint size = (uint)path.Capacity;
                    if (QueryFullProcessImageName(process, 0, path, ref size))
                    {
                        string file = Path.GetFileName(path.ToString());
                        foreach (string program in Programs)
                            if (string.Equals(file, program, StringComparison.OrdinalIgnoreCase)) result = true;
                    }
                }
                finally
                {
                    CloseHandle(process);
                }
            }
            lastWindow = window;
            lastProcess = pid;
            lastResult = result;
            return result;
        }

        // Hold the keys only while a VMware window is in front.
        void Sync()
        {
            bool want = IsVmware(GetForegroundWindow());
            if (want == armed) return;
            armed = want;
            for (int i = 0; i < Letters.Length; i++)
            {
                if (want) RegisterHotKey(Handle, i + 1, MOD_CONTROL | MOD_NOREPEAT, Letters[i]);
                else UnregisterHotKey(Handle, i + 1);
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY)
            {
                int i = m.WParam.ToInt32() - 1;
                if (i >= 0 && i < Letters.Length) Dropped(i);
                return;
            }
            base.WndProc(ref m);
        }

        void Dropped(int i)
        {
            blocked++;
            counter.Text = string.Format("Blocked {0}x, last: Ctrl+{1} ({2}) at {3:HH:mm}",
                                         blocked, Letters[i], Actions[i], DateTime.Now);
            if (quiet) return;
            DateTime now = DateTime.UtcNow;
            if (now - lastNotice < TimeSpan.FromSeconds(15)) return;
            lastNotice = now;
            tray.ShowBalloonTip(5000, "Blocked Ctrl+" + Letters[i] + " (VMware " + Actions[i] + ")",
                "The VM did not have the keyboard, so the key went to Workstation's menu. " +
                "It was dropped. Click inside the VM and press it again.", ToolTipIcon.Warning);
        }

        void Shutdown()
        {
            timer.Stop();
            timer.Dispose();
            if (hook != IntPtr.Zero) UnhookWinEvent(hook);
            for (int i = 0; i < Letters.Length; i++) UnregisterHotKey(Handle, i + 1);
            tray.Visible = false;
            tray.Dispose();
            DestroyHandle();
        }

        static void Log(string text)
        {
            try
            {
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "kali-clean");
                Directory.CreateDirectory(dir);
                string file = Path.Combine(dir, "vmware-hotkey-guard.log");
                if (File.Exists(file) && new FileInfo(file).Length > 65536) File.Delete(file);
                File.AppendAllText(file, DateTime.Now.ToString("s") + " " + text + Environment.NewLine);
            }
            catch (Exception) { }
        }

        public static int Run(bool quiet)
        {
            bool first;
            using (var once = new Mutex(true, @"Local\kali-clean.vmware-hotkey-guard", out first))
            {
                if (!first) return 2;   // already running
                using (var stop = new EventWaitHandle(false, EventResetMode.AutoReset,
                                                      @"Local\kali-clean.vmware-hotkey-guard.stop"))
                {
                    Application.EnableVisualStyles();
                    try { Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException); }
                    catch (InvalidOperationException) { }
                    // Never put up an error dialog in the middle of an exam; log it instead.
                    Application.ThreadException += delegate(object sender, ThreadExceptionEventArgs e)
                    {
                        Log(e.Exception.ToString());
                    };
                    var guard = new VmwareHotkeyGuard(quiet, stop);
                    try { Application.Run(); }
                    finally { guard.Shutdown(); }
                }
                once.ReleaseMutex();
            }
            return 0;
        }
    }
}
'@

function Test-Running {
    $mutex = $null
    try {
        if ([System.Threading.Mutex]::TryOpenExisting($MutexName, [ref]$mutex)) {
            $mutex.Dispose()
            return $true
        }
    } catch [System.UnauthorizedAccessException] {
        return $true    # running, started from an elevated prompt
    }
    return $false
}

function Stop-Guard {
    $signal = $null
    try {
        if (-not [System.Threading.EventWaitHandle]::TryOpenExisting($StopName, [ref]$signal)) { return $false }
    } catch [System.UnauthorizedAccessException] {
        throw 'It was started from an elevated prompt: exit it from its tray icon, or run this as administrator.'
    }
    [void]$signal.Set()
    $signal.Dispose()
    for ($i = 0; $i -lt 50 -and (Test-Running); $i++) { Start-Sleep -Milliseconds 100 }
    return $true
}

function Get-Arguments([string]$Path) {
    $line = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Run' -f $Path
    if ($Quiet) { $line += ' -Quiet' }
    return $line
}

function Start-Guard([string]$Path) {
    if (Test-Running) { return 'is already running' }
    Start-Process -FilePath $WinPS -ArgumentList (Get-Arguments $Path) -WindowStyle Hidden
    for ($i = 0; $i -lt 150; $i++) {    # the first start compiles the C# part (a few seconds)
        if (Test-Running) { return 'is running' }
        Start-Sleep -Milliseconds 100
    }
    throw ('It did not start. To see why, run it in the foreground: ' +
           'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Run' -f $Path)
}

function Install-Guard {
    [void](New-Item -ItemType Directory -Force -Path $InstallDir)
    if ([IO.Path]::GetFullPath($Self) -ne [IO.Path]::GetFullPath($Installed)) {
        Copy-Item -LiteralPath $Self -Destination $Installed -Force
    }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Shortcut)
    $link.TargetPath = $WinPS
    $link.Arguments = Get-Arguments $Installed
    $link.WorkingDirectory = $InstallDir
    $link.WindowStyle = 7    # minimized
    $link.Description = 'Keeps VMware Workstation Ctrl+E/R/Z from powering off, resetting or suspending a VM by accident'
    $link.Save()
    "Starts at every login: $Shortcut"
}

function Uninstall-Guard {
    if (Stop-Guard) { 'Stopped.' } else { 'It was not running.' }
    if (Test-Path -LiteralPath $Shortcut) { Remove-Item -LiteralPath $Shortcut -Force; "Removed $Shortcut" }
    if (Test-Path -LiteralPath $Installed) { Remove-Item -LiteralPath $Installed -Force; "Removed $Installed" }
    $log = Join-Path $InstallDir 'vmware-hotkey-guard.log'
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    if ((Test-Path -LiteralPath $InstallDir) -and -not (Get-ChildItem -LiteralPath $InstallDir -Force)) {
        Remove-Item -LiteralPath $InstallDir -Force
    }
}

function Restore-Prompts {
    $prefs = Join-Path $env:APPDATA 'VMware\preferences.ini'
    if (-not (Test-Path -LiteralPath $prefs)) {
        'No preferences.ini yet, so Workstation still asks before Power Off and Reset.'
        return
    }
    if (@(Get-Process -Name vmware, vmplayer -ErrorAction SilentlyContinue).Count) {
        Write-Warning ('Prompts not restored: close VMware Workstation first (File > Exit; a running ' +
                       'VM can stay running in the background), then run -RestorePrompts again. ' +
                       'Workstation rewrites preferences.ini when it exits.')
        return
    }
    # "Do not show again" on those questions stores these; Help > Hints > Show Enabled Hints
    # off stores hints.hideAll. Latin-1 keeps every other byte of the file exactly as it was.
    $pattern = '(?im)^[ \t]*(?:hint\.vmui\.(?:poweroff|reset)[ \t]*=[ \t]*"false"|hints\.hideAll[ \t]*=[ \t]*"true")[ \t]*(?:\r?\n|$)'
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $text = [IO.File]::ReadAllText($prefs, $latin1)
    $found = [regex]::Matches($text, $pattern)
    if ($found.Count -eq 0) {
        'Nothing to restore: Workstation''s Power Off and Reset questions are not switched off.'
        return
    }
    $backup = '{0}.{1:yyyyMMdd-HHmmss}.bak' -f $prefs, (Get-Date)
    Copy-Item -LiteralPath $prefs -Destination $backup
    [IO.File]::WriteAllText($prefs, [regex]::Replace($text, $pattern, ''), $latin1)
    foreach ($match in $found) { 'Removed ' + $match.Value.Trim() }
    "Workstation asks again before Power Off and Reset. Backup: $backup"
}

if (-not $Self) {
    throw 'Save it as a .ps1 file and run: powershell -NoProfile -ExecutionPolicy Bypass -File .\vmware-hotkey-guard.ps1'
}

if ($Run) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # The tray process needs Windows PowerShell 5.1 (it compiles against the .NET Framework).
        $rest = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Self, '-Run')
        if ($Quiet) { $rest += '-Quiet' }
        & $WinPS @rest
        exit $LASTEXITCODE
    }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -TypeDefinition $Source -ReferencedAssemblies System.Windows.Forms, System.Drawing -IgnoreWarnings
    exit ([KaliClean.VmwareHotkeyGuard]::Run([bool]$Quiet))
}

if ($Uninstall) {
    Uninstall-Guard
    return
}
if ($RestorePrompts) {
    Restore-Prompts
    if (-not $Install) { return }
}
$target = $Self
if ($Install) {
    Install-Guard
    $target = $Installed
}
'VMware hotkey guard {0} (shield icon in the tray). Inside the VM, Ctrl+E/R/Z work as usual.' -f (Start-Guard $target)
