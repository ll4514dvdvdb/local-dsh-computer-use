# ------------------------------------------------------------- user takeover
#
# The missing half of "the caller can stop it": a *person* at the keyboard can stop it
# too. Every other stop in this worker is requested by the host (a marker file, a
# deadline); this one is requested by the human whose desktop is being driven. Without
# it the only way to take the machine back is to wait for the current call to finish —
# the exact complaint the "control budget" feature of Windows-MCP exists to answer.
#
# Why a low-level hook and not GetLastInputInfo: LASTINPUTINFO is a time stamp, not an
# author. It cannot tell an event this worker injected with SendInput from one a finger
# produced, so a poll-based probe would either never fire or fire on the worker's own
# clicks. WH_KEYBOARD_LL / WH_MOUSE_LL carry `LLKHF_INJECTED` / `LLMHF_INJECTED` on
# every injected event, which is the only reliable attribution the platform offers.
# So: a background hook thread keeps two counters —
#
#   lastPhysical  the tick of the last non-injected key press, mouse button or wheel;
#   movedUnits    the summed |dx|+|dy| of non-injected mouse movement.
#
# Movement alone is not a takeover: a hand resting on the mouse drifts a few hundred
# device units without meaning anything, so movement has to accumulate past
# $script:TakeoverMoveThreshold (1200 by default) before it counts. A press or a key
# is unambiguous and counts immediately.
#
# Attribution rule, stated once: an event with the injected bit is *ours* (SendInput is
# the only thing in this process that sends one) and is ignored. Everything else is a
# human. There is no third source.
$script:TakeoverEnabled = $true
if ("$($env:DSH_COMPUTER_USE_TAKEOVER)" -ne '') {
    $takeoverSwitch = "$($env:DSH_COMPUTER_USE_TAKEOVER)".Trim().ToLowerInvariant()
    if ($takeoverSwitch -in @('0', 'false', 'off', 'no', 'disabled')) { $script:TakeoverEnabled = $false }
}
$script:TakeoverMoveThreshold = [int64]1200
if ("$($env:DSH_COMPUTER_USE_TAKEOVER_MOVE)" -ne '') {
    try { $script:TakeoverMoveThreshold = [int64][int]$env:DSH_COMPUTER_USE_TAKEOVER_MOVE } catch { }
}
if ($script:TakeoverMoveThreshold -lt 1) { $script:TakeoverMoveThreshold = [int64]1 }
# How hard the takeover check pushes back:
#   off   -- never refuse; the hooks stay installed so `computer_control` can still report
#            what the user is doing (an explicit opt-out, for a scripted session where
#            nobody is at the keyboard).
#   input -- (default) refuse right before each piece of input is sent.
#   all   -- refuse during waits as well: a 30 s observation window ends the moment a
#            hand touches the keyboard instead of continuing to hold the desktop.
$script:TakeoverMode = 'input'
# The point this request started from. A takeover is "physical input newer than this",
# never "any input at all": the user typing a moment *before* the call began is not a
# reason to refuse it.
$script:TakeoverBaseLast = [int64]0
$script:TakeoverBaseMoved = [int64]0
$script:TakeoverBaseEvents = [int]0
$script:TakeoverError = ''
$script:TakeoverHookReady = $false

$takeoverSource = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class DshTakeover
{
    const int WH_KEYBOARD_LL = 13;
    const int WH_MOUSE_LL = 14;
    const uint LLKHF_INJECTED = 0x10;
    const uint LLKHF_LOWER_IL_INJECTED = 0x02;
    const uint LLMHF_INJECTED = 0x01;
    const uint LLMHF_LOWER_IL_INJECTED = 0x02;
    const int WM_MOUSEMOVE = 0x0200;

    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MSLLHOOKSTRUCT
    {
        public int ptX;
        public int ptY;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    static extern IntPtr GetModuleHandle(string lpModuleName);

    static HookProc kbProc;
    static HookProc msProc;
    static IntPtr kbHook = IntPtr.Zero;
    static IntPtr msHook = IntPtr.Zero;
    // A monotonic millisecond clock, because Environment.TickCount64 is 4.5+ and Add-Type
    // compiles against the 4.0 reference assemblies. Stopwatch wraps the same QPC the
    // tick counter does and, unlike Environment.TickCount, never wraps through zero.
    static readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
    static long lastPhysical;
    static long movedUnits;
    // How many *physical* events were attributed to a human. The timestamp alone cannot
    // answer "did anything happen in these 80 ms" -- it answers "when was the last one" --
    // and a test that injects input needs the first question to tell a real key press
    // apart from its own SendInput.
    static int physicalEvents;
    static int lastPtX = int.MinValue;
    static int lastPtY = int.MinValue;
    static volatile bool started;
    static volatile string error = "";

    public static long MonotonicMs { get { return clock.ElapsedMilliseconds; } }
    public static long LastPhysicalMs { get { return Interlocked.Read(ref lastPhysical); } }
    public static long MovedUnits { get { return Interlocked.Read(ref movedUnits); } }
    public static int PhysicalEvents { get { return physicalEvents; } }
    public static bool Started { get { return started; } }
    public static string Error { get { return error; } }
    public static bool KeyboardHooked { get { return kbHook != IntPtr.Zero; } }
    public static bool MouseHooked { get { return msHook != IntPtr.Zero; } }

    static void NotePress()
    {
        Interlocked.Increment(ref physicalEvents);
        Interlocked.Exchange(ref lastPhysical, clock.ElapsedMilliseconds);
    }

    static void NoteMove(int x, int y)
    {
        if (lastPtX == int.MinValue)
        {
            // The first move after the hook was installed has no previous point: it is a
            // position to measure from, not a distance somebody travelled.
            lastPtX = x;
            lastPtY = y;
            return;
        }
        long dx = (long)x - (long)lastPtX;
        long dy = (long)y - (long)lastPtY;
        lastPtX = x;
        lastPtY = y;
        if (dx == 0 && dy == 0) return;
        Interlocked.Increment(ref physicalEvents);
        Interlocked.Add(ref movedUnits, (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy));
    }

    static IntPtr KbCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (nCode >= 0)
            {
                KBDLLHOOKSTRUCT d = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                if ((d.flags & (LLKHF_INJECTED | LLKHF_LOWER_IL_INJECTED)) == 0) NotePress();
            }
        }
        catch { }
        return CallNextHookEx(kbHook, nCode, wParam, lParam);
    }

    static IntPtr MsCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (nCode >= 0)
            {
                MSLLHOOKSTRUCT d = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                if ((d.flags & (LLMHF_INJECTED | LLMHF_LOWER_IL_INJECTED)) == 0)
                {
                    if (wParam.ToInt32() == WM_MOUSEMOVE) NoteMove(d.ptX, d.ptY);
                    else NotePress();
                }
            }
        }
        catch { }
        return CallNextHookEx(msHook, nCode, wParam, lParam);
    }

    static void Run()
    {
        try
        {
            kbProc = KbCallback;
            msProc = MsCallback;
            IntPtr module = GetModuleHandle(null);
            kbHook = SetWindowsHookEx(WH_KEYBOARD_LL, kbProc, module, 0);
            msHook = SetWindowsHookEx(WH_MOUSE_LL, msProc, module, 0);
            if (kbHook == IntPtr.Zero && msHook == IntPtr.Zero)
            {
                error = "SetWindowsHookEx failed for both hooks, LastError=" + Marshal.GetLastWin32Error().ToString();
                started = true;
                return;
            }
            started = true;
            MSG msg;
            while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
        }
        catch (Exception e)
        {
            error = e.GetType().Name + ": " + e.Message;
            started = true;
        }
    }

    /// Starts the hook thread and waits up to 3000 ms for it to report in, so a caller
    /// reads `Started` as a fact rather than as a hope.
    public static void Start()
    {
        Thread t = new Thread(Run);
        t.IsBackground = true;
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        for (int i = 0; i < 300 && !started; i++) Thread.Sleep(10);
    }
}
'@

function Start-TakeoverWatch {
    # Best effort by design: a machine where the hook cannot be installed (a locked-down
    # policy, a session without a desktop) loses the takeover stop, not the ability to
    # drive the desktop. The reason is kept and reported rather than swallowed.
    if (-not $script:TakeoverEnabled) { return }
    if ($script:TakeoverHookReady) { return }
    try {
        if ($null -eq ('DshTakeover' -as [type])) {
            Add-Type -TypeDefinition $takeoverSource -Language CSharp -ErrorAction Stop | Out-Null
        }
        [DshTakeover]::Start()
        if ([DshTakeover]::Started) {
            $script:TakeoverHookReady = $true
            if (-not [string]::IsNullOrEmpty([DshTakeover]::Error)) { $script:TakeoverError = [DshTakeover]::Error }
        } else {
            $script:TakeoverError = 'the hook thread did not report ready within 3000 ms'
        }
    } catch {
        $script:TakeoverError = "$($_.Exception.Message)"
    }
}

function Reset-TakeoverBaseline {
    # Called once per request, *before* the handler runs: what happened before the request
    # is context, what happens during it is a takeover.
    if (-not $script:TakeoverHookReady) { return }
    try {
        $script:TakeoverBaseLast = [int64][DshTakeover]::LastPhysicalMs
        $script:TakeoverBaseMoved = [int64][DshTakeover]::MovedUnits
        $script:TakeoverBaseEvents = [int][DshTakeover]::PhysicalEvents
    } catch { }
}

function Get-TakeoverStatus {
    $ready = $false
    $keyboard = $false
    $mouse = $false
    $lastAge = [int64]-1
    $movedSince = [int64]0
    $eventsSince = [int64]0
    try {
        $ready = [bool][DshTakeover]::Started
        $keyboard = [bool][DshTakeover]::KeyboardHooked
        $mouse = [bool][DshTakeover]::MouseHooked
        $lastPhysical = [int64][DshTakeover]::LastPhysicalMs
        if ($lastPhysical -gt 0) { $lastAge = [int64][DshTakeover]::MonotonicMs - $lastPhysical }
        $movedSince = [int64][DshTakeover]::MovedUnits - $script:TakeoverBaseMoved
        $eventsSince = [int64][DshTakeover]::PhysicalEvents - $script:TakeoverBaseEvents
    } catch { }
    return [ordered]@{
        mode = $script:TakeoverMode
        enabled = $script:TakeoverEnabled
        ready = $ready
        keyboard = $keyboard
        mouse = $mouse
        moveThreshold = $script:TakeoverMoveThreshold
        lastPhysicalAgeMs = [int64]$lastAge
        movedSinceBaseline = [int64]$movedSince
        physicalEvents = [int64]$eventsSince
        error = $script:TakeoverError
    }
}

function Set-TakeoverMode([string]$mode) {
    $switch = "$mode".Trim().ToLowerInvariant()
    if ($switch -in @('off', 'none', '0', 'false')) { $script:TakeoverMode = 'off' }
    elseif ($switch -in @('all', 'strict', 'wait')) { $script:TakeoverMode = 'all' }
    elseif ($switch -in @('input', 'default', 'normal', '1', 'true')) { $script:TakeoverMode = 'input' }
    else { throw "unknown takeover mode '$mode': expected 'off', 'input' or 'all'" }
    return $script:TakeoverMode
}

function Test-UserTakeover {
    if ($script:TakeoverMode -eq 'off') { return $false }
    if (-not $script:TakeoverEnabled) { return $false }
    if (-not $script:TakeoverHookReady) { return $false }
    try {
        if ([int64][DshTakeover]::LastPhysicalMs -gt $script:TakeoverBaseLast) { return $true }
        if (([int64][DshTakeover]::MovedUnits - $script:TakeoverBaseMoved) -ge $script:TakeoverMoveThreshold) { return $true }
    } catch {
        return $false
    }
    return $false
}

function Assert-NoUserTakeoverDuringWait([string]$where) {
    # Only the strict mode breaks a wait: under `input` a long observation is exactly the
    # moment the user is most likely to look at the screen without touching anything.
    if ($script:TakeoverMode -ne 'all') { return }
    if (-not (Test-UserTakeover)) { return }
    throw "[USER_TAKEOVER] the user touched the keyboard or mouse while this request was waiting ($where). The wait was cut short and nothing after it was sent to the desktop. Do not retry this call as it stands: ask the user whether to continue."
}

function Assert-NoUserTakeover([string]$where) {
    if (-not (Test-UserTakeover)) { return }
    # The same shape as [CANCELED] -- the caller is expected to stop, not to retry --
    # but a different code, because "the user took the mouse back" is not "you cancelled
    # it" and the message has to say which one happened.
    throw "[USER_TAKEOVER] the user touched the keyboard or mouse while this request was running ($where). The remaining steps were not sent to the desktop. Do not retry this call as it stands: ask the user whether to continue, and if they want the desktop back, leave it alone."
}

# The environment is read last, through the same setter `computer_control` uses, so the
# accepted spellings cannot drift between "startup" and "runtime".
if ("$($env:DSH_COMPUTER_USE_TAKEOVER_MODE)" -ne '') {
    try { Set-TakeoverMode "$($env:DSH_COMPUTER_USE_TAKEOVER_MODE)" | Out-Null } catch { }
}

# ---- visual indicator -------------------------------------------------------------------
# A click-through overlay process that says "the assistant is driving" while it runs: a glow
# along the desktop edge, a halo around the pointer, a ring wherever it clicks. It is started
# lazily with the input watch and lives only as long as this worker (it polls -ParentPid).
# The worker's only jobs are: refresh the active-until stamp before it touches the desktop,
# and append click coordinates so the overlay can animate them.
$script:IndicatorProcess = $null
$script:IndicatorFile = $null
$script:IndicatorClicks = New-Object System.Collections.ArrayList
$script:IndicatorActiveUntil = 0

function Test-IndicatorWanted() {
    if (-not $script:TakeoverEnabled) { return $false }
    return -not ("$env:DSH_COMPUTER_USE_INDICATOR" -match '^(0|false|off|no|disabled)$')
}

function Get-IndicatorStatePath() {
    if ($null -eq $script:IndicatorFile) {
        $dir = $null
        if (-not [string]::IsNullOrWhiteSpace($env:DSH_COMPUTER_USE_TMP)) { $dir = $env:DSH_COMPUTER_USE_TMP }
        if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'dsh-computer-use' }
        try { if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch { }
        $script:IndicatorFile = Join-Path $dir ("indicator-{0}.txt" -f $PID)
    }
    return $script:IndicatorFile
}

function Write-IndicatorFile([string]$text) {
    try {
        $path = Get-IndicatorStatePath
        [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        try { [System.IO.File]::AppendAllText((Join-Path ([System.IO.Path]::GetTempPath()) 'dsh-indicator-wfail.log'), "$(Get-IndicatorStatePath) :: $($_.Exception.GetType().Name) :: $($_.Exception.Message)`r`n") } catch { }
    }
}

function Update-IndicatorState([int]$holdMs = 1500) {
    if ($null -eq $script:IndicatorProcess) { return }
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $script:IndicatorActiveUntil = $now + $holdMs
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("active=$($script:IndicatorActiveUntil)")
        foreach ($c in $script:IndicatorClicks) { [void]$sb.AppendLine("click=$($c.at),$($c.x),$($c.y)") }
        Write-IndicatorFile $sb.ToString()
    } catch { }
}

function Note-IndicatorClick([int]$x, [int]$y) {
    if ($null -eq $script:IndicatorProcess) { return }
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        [void]$script:IndicatorClicks.Add([pscustomobject]@{ at = $now; x = $x; y = $y })
        while ($script:IndicatorClicks.Count -gt 6) { $script:IndicatorClicks.RemoveAt(0) }
        Update-IndicatorState 2200
    } catch { }
}

function Start-Indicator {
    if (-not (Test-IndicatorWanted)) { return }
    if ($null -ne $script:IndicatorProcess) { return }
    try {
        $scriptPath = Join-Path $PSScriptRoot 'indicator.ps1'
        if (-not (Test-Path $scriptPath)) { return }
        $file = Get-IndicatorStatePath
        Write-IndicatorFile "active=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 1500)`n"
        $exe = $null
        try { $exe = (Get-Process -Id $PID).Path } catch { $exe = $null }
        if ([string]::IsNullOrWhiteSpace($exe)) { $exe = 'powershell.exe' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Sta -File `"$scriptPath`" -StateFile `"$file`" -ParentPid $PID"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $script:IndicatorProcess = [System.Diagnostics.Process]::Start($psi)
    } catch { $script:TakeoverError = "indicator: $($_.Exception.Message)" }
}

function Stop-Indicator {
    if ($null -eq $script:IndicatorProcess) { return }
    try { if (-not $script:IndicatorProcess.HasExited) { $script:IndicatorProcess.Kill() } } catch { }
    try { $script:IndicatorProcess.Dispose() } catch { }
    $script:IndicatorProcess = $null
    try { Remove-Item -LiteralPath (Get-IndicatorStatePath) -Force -ErrorAction SilentlyContinue } catch { }
}
