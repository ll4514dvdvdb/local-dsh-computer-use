# DSH computer-use indicator: a click-through overlay that shows *that* the assistant is
# driving the desktop. Border glow while a request is in flight, a halo around the pointer
# it is about to move, and a ring wherever it clicks.
#
# It is a separate process on purpose. The worker comes and goes with the bridge, while this
# must be on screen exactly as long as the session is being driven; the parent pid is polled
# every other second and the process exits when the worker goes away, so a crashed worker
# cannot leave a glowing rectangle behind forever.
#
# Nothing here reads input. Input watching lives in the worker (02b-takeover); this process
# only draws, so it can never be a reason for a keyboard or mouse event to be dropped.
param(
    [Parameter(Mandatory = $true)][string]$StateFile,
    [int]$ParentPid = 0,
    [int]$Fps = 30,
    [string]$DumpPath = ''
)
$ErrorActionPreference = 'Stop'

# DPI awareness has to be claimed before any window exists, or the process stays virtualized:
# VirtualScreen would report 1440x810 while the layered surface is laid out in physical
# 2880x1620 pixels and the border ends up covering a quarter of the screen.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DshDpiConfig {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDPIAware();
}
"@
$dpiV2 = $false
$dpiErr = ''
try { $dpiV2 = [DshDpiConfig]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { $dpiErr = $_.Exception.Message }
if (-not $dpiV2) { try { $null = [DshDpiConfig]::SetProcessDPIAware() } catch { } }
try { Set-Content -Path "$StateFile.dpi" -Value "v2=$dpiV2 err=$dpiErr" -Encoding UTF8 } catch { }
$script:LogPath = "$StateFile.log"
function Note([string]$m) { try { Add-Content -Path $script:LogPath -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m) -Encoding UTF8 } catch { } }
Note ('start pid=' + $PID)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Note ('virtual=' + [System.Windows.Forms.SystemInformation]::VirtualScreen.Width + 'x' + [System.Windows.Forms.SystemInformation]::VirtualScreen.Height + ' dpi=' + ([DshDpiConfig]::SetProcessDpiAwarenessContext([IntPtr](-4))))

$source = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class DshIndicator : Form
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx; public int cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    const int WS_EX_LAYERED = 0x00080000;
    const int WS_EX_TRANSPARENT = 0x00000020;
    const int WS_EX_TOPMOST = 0x00000008;
    const int WS_EX_NOACTIVATE = 0x08000000;
    const int WS_EX_TOOLWINDOW = 0x00000080;
    const byte AC_SRC_OVER = 0x00;
    const byte AC_SRC_ALPHA = 0x01;
    const int ULW_ALPHA = 0x02;
    const uint SWP_NOACTIVATE = 0x0010;
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    // Colours: the ring/edge is the accent blue used by the tool text, kept in one place so
    // the border, halo and rings cannot drift apart.
    static readonly Color Accent = Color.FromArgb(56, 148, 255);


    // Debug-only: when set, every tenth rendered frame is written here, so the overlay can be
    // inspected without relying on a screen grab of a layered window.
    public static string DumpPath;

    readonly string stateFile;
    // Set from the worker through a "label=" line; empty falls back to the built-in text so
    // this script stays ASCII-only (PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI).
    volatile string badgeText = "";
    readonly Timer timer;
    Bitmap bitmap;
    Graphics graphics;
    IntPtr screenDc;
    IntPtr memoryDc;
    Rectangle bounds;
    int frame;
    bool active;
    long activeUntil;
    List<long> ringAt = new List<long>();
    List<Point> ringPt = new List<Point>();

    readonly int fps;
    public DshIndicator(string stateFile, int fps)
    {
        this.stateFile = stateFile;
        this.fps = fps;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        // Without None, WinForms rescales the form to the design-time font metrics and a
        // 2880x1620 bounds ends up as a 1440x810 window on a 200% display.
        AutoScaleMode = AutoScaleMode.None;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.Opaque, true);
        bounds = SystemInformation.VirtualScreen;
        Bounds = bounds;
        screenDc = GetDC(IntPtr.Zero);
        memoryDc = CreateCompatibleDC(screenDc);
        bitmap = new Bitmap(bounds.Width, bounds.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        graphics = Graphics.FromImage(bitmap);
        timer = new Timer();
        timer.Interval = Math.Max(16, 1000 / Math.Max(1, fps));
        timer.Tick += delegate { Tick(); };
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
            return cp;
        }
    }

    public void Begin()
    {
        Show();
        // WinForms keeps rescaling the form to its design font metrics even with
        // AutoScaleMode.None, so the size is decided once, in device pixels, after the
        // handle exists. HWND_TOPMOST keeps it above the taskbar as well.
        SetWindowPos(Handle, new IntPtr(-1), bounds.X, bounds.Y, bounds.Width, bounds.Height, SWP_NOACTIVATE);
        timer.Start();
    }

    void Tick()
    {
        frame++;
        // Reading the state file at 30 Hz would be pointless IO; ten times a second is more
        // than enough for a hint that a human is looking at.
        if (frame % 3 == 0) ReadState();
        Point cursor = Pointer();
        Render(cursor);
    }

    void ReadState()
    {
        long now = Now();
        active = activeUntil > now;
        string text;
        try
        {
            using (var fs = new System.IO.FileStream(stateFile, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite))
            using (var sr = new System.IO.StreamReader(fs, Encoding.UTF8))
                text = sr.ReadToEnd();
        }
        catch (Exception ex)
        {
            try { System.IO.File.AppendAllText(stateFile + ".err", ex.GetType().Name + ": " + ex.Message + "\n"); } catch { }
            return;
        }
        foreach (string raw in text.Split('\n'))
        {
            string line = raw.Trim();
            if (line.Length == 0) continue;
            int comma = line.IndexOf(',');
            if (line.StartsWith("label="))
            {
                badgeText = line.Substring(6).Trim();
            }
            else if (line.StartsWith("active="))
            {
                long value;
                if (long.TryParse(line.Substring(7).Trim(), out value)) activeUntil = value;
            }
            else if (line.StartsWith("click=") && comma > 6)
            {
                string[] parts = line.Substring(6).Split(',');
                if (parts.Length < 3) continue;
                long at; int x; int y;
                if (!long.TryParse(parts[0].Trim(), out at)) continue;
                if (!int.TryParse(parts[1].Trim(), out x)) continue;
                if (!int.TryParse(parts[2].Trim(), out y)) continue;
                // The worker rewrites the whole file, so the same click shows up on every
                // read; only the ones never seen before should ring.
                bool seen = false;
                for (int i = 0; i < ringAt.Count; i++) { if (ringAt[i] == at && ringPt[i].X == x && ringPt[i].Y == y) { seen = true; break; } }
                if (!seen) { ringAt.Add(at); ringPt.Add(new Point(x, y)); }
            }
        }
        while (ringAt.Count > 8) { ringAt.RemoveAt(0); ringPt.RemoveAt(0); }
        active = activeUntil > now;
    }

    static long Now() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }

    static Point Pointer()
    {
        POINT p;
        if (GetCursorPos(out p)) return new Point(p.X, p.Y);
        return Point.Empty;
    }

    GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        GraphicsPath path = new GraphicsPath();
        float d = radius * 2f;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    // A badge at the top of the screen: what is happening, and how to stop it. The text
    // comes from the worker through a "label=" line so the product name lives in one place;
    // the fallback here is ASCII because this script must stay readable by Windows
    // PowerShell 5.1 without an encoding gamble.
    void DrawBadge()
    {
        if (!active) return;
        string text = badgeText;
        if (string.IsNullOrEmpty(text)) text = "DeepSeek Harness 正在操控电脑 · 动鼠标或按任意键停止";
        float scale = UiScale();
        // 22 at a 1080-tall screen: sized to read from across a desk, the way the
        // assistant overlays people are used to look. Every length below multiplies by
        // scale, so the pill keeps the same apparent size on 1366x768 and 3840x2160.
        float pixel = 22f * scale;
        using (Font font = new Font("Microsoft YaHei UI", pixel, FontStyle.Regular, GraphicsUnit.Pixel))
        {
            SizeF measured = graphics.MeasureString(text, font);
            float padX = 26f * scale;
            float padY = 13f * scale;
            float w = measured.Width + padX * 2f;
            float h = measured.Height + padY * 2f;
            float x = (bounds.Width - w) / 2f;
            float y = 24f * scale;
            RectangleF rect = new RectangleF(x, y, w, h);
            using (GraphicsPath path = RoundedRect(rect, h / 2f))
            using (SolidBrush bg = new SolidBrush(Color.FromArgb(232, Accent)))
            using (Pen border = new Pen(Color.FromArgb(120, 255, 255, 255), Math.Max(1.2f, 1.6f * scale)))
            using (SolidBrush fg = new SolidBrush(Color.FromArgb(255, 255, 255, 255)))
            {
                graphics.FillPath(bg, path);
                graphics.DrawPath(border, path);
                graphics.DrawString(text, font, fg, x + padX, y + padY);
            }
        }
    }

    void Render(Point cursor)
    {
        graphics.Clear(Color.Transparent);

        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        if (active) DrawEdge();
        DrawRings();
        DrawHalo(cursor);
        DrawBadge();
        Present();
        if (DumpPath != null && frame % 3 == 0)
        {
            try
            {
                string dir = System.IO.Path.GetDirectoryName(DumpPath);
                if (!System.IO.Directory.Exists(dir)) System.IO.Directory.CreateDirectory(dir);
                bitmap.Save(System.IO.Path.Combine(dir, "frame_" + (frame % 600).ToString("000") + ".png"), System.Drawing.Imaging.ImageFormat.Png);
            }
            catch { }
        }
    }

    // A glow hugging the virtual-desktop edge: solid at the very edge, fading inward over
    // 36 px. Four linear gradients rather than a path brush, because a path brush on a
    // 5000-px rectangle is slow enough to show.
    // Everything is sized from the shorter side of the virtual desktop, so the same design
    // reads the same on a 1366x768 laptop and a 3840x2160 monitor: 36 px of glow at 1080
    // tall means ~3.3% of the short side, not a magic pixel count that vanishes on 4K.
    float UiScale()
    {
        float s = Math.Min(bounds.Width, bounds.Height) / 1080f;
        if (s < 0.6f) s = 0.6f;
        if (s > 2.6f) s = 2.6f;
        return s;
    }

    void DrawEdge()
    {
        float scale = UiScale();
        int depth = (int)Math.Round(36f * scale);
        if (depth < 8) depth = 8;
        int glow = 150;
        Rectangle r = new Rectangle(0, 0, bounds.Width, bounds.Height);
        using (LinearGradientBrush top = new LinearGradientBrush(new Rectangle(r.X, 0, r.Width, depth), Color.FromArgb(glow, Accent), Color.FromArgb(0, Accent), LinearGradientMode.Vertical))
            graphics.FillRectangle(top, r.X, 0, r.Width, depth);
        using (LinearGradientBrush bottom = new LinearGradientBrush(new Rectangle(r.X, r.Height - depth, r.Width, depth), Color.FromArgb(0, Accent), Color.FromArgb(glow, Accent), LinearGradientMode.Vertical))
            graphics.FillRectangle(bottom, r.X, r.Height - depth, r.Width, depth);
        using (LinearGradientBrush left = new LinearGradientBrush(new Rectangle(0, r.Y, depth, r.Height), Color.FromArgb(glow, Accent), Color.FromArgb(0, Accent), LinearGradientMode.Horizontal))
            graphics.FillRectangle(left, 0, r.Y, depth, r.Height);
        using (LinearGradientBrush right = new LinearGradientBrush(new Rectangle(r.Width - depth, r.Y, depth, r.Height), Color.FromArgb(0, Accent), Color.FromArgb(glow, Accent), LinearGradientMode.Horizontal))
            graphics.FillRectangle(right, r.Width - depth, r.Y, depth, r.Height);
    }

    // Rings expand from 8 to 46 px over 600 ms and fade as they grow, so two quick clicks
    // read as two clicks instead of one thick ring.
    void DrawRings()
    {
        if (ringAt.Count == 0 || !active) return;
        long now = Now();
        for (int i = 0; i < ringAt.Count; i++)
        {
            long age = now - ringAt[i];
            if (age < 0 || age > 900) continue;
            float t = age / 900f;
            float scale = UiScale();
            float radius = (8f + 38f * t) * scale;
            int alpha = (int)(190 * (1f - t));
            if (alpha <= 0) continue;
            Point p = ringPt[i];
            float width = Math.Max(2f, 3f * scale);
            using (Pen pen = new Pen(Color.FromArgb(alpha, Accent), width))
                graphics.DrawEllipse(pen, p.X - bounds.X - radius, p.Y - bounds.Y - radius, radius * 2f, radius * 2f);
        }
    }

    // Three concentric discs instead of a blur: cheap, and the exact pixel under the pointer
    // stays readable because the innermost disc is a thin outline, not a fill.
    void DrawHalo(Point cursor)
    {
        if (!active) return;
        float cx = cursor.X - bounds.X;
        float cy = cursor.Y - bounds.Y;
        float scale = UiScale();
        float margin = 64f * scale;
        if (cx < -margin || cy < -margin || cx > bounds.Width + margin || cy > bounds.Height + margin) return;
        float outerR = 22f * scale;
        float innerR = 9f * scale;
        float stroke = Math.Max(1.5f, 2f * scale);
        using (SolidBrush glow = new SolidBrush(Color.FromArgb(46, Accent)))
            graphics.FillEllipse(glow, cx - outerR, cy - outerR, outerR * 2f, outerR * 2f);
        using (Pen outer = new Pen(Color.FromArgb(120, Accent), stroke))
            graphics.DrawEllipse(outer, cx - outerR, cy - outerR, outerR * 2f, outerR * 2f);
        using (Pen inner = new Pen(Color.FromArgb(230, Accent), stroke))
            graphics.DrawEllipse(inner, cx - innerR, cy - innerR, innerR * 2f, innerR * 2f);
    }

    void Present()
    {
        IntPtr mem = CreateCompatibleDC(screenDc);
        IntPtr target = bitmap.GetHbitmap(Color.FromArgb(0));
        IntPtr previous = SelectObject(mem, target);
        try
        {
            POINT dst = new POINT();
            dst.X = bounds.X;
            dst.Y = bounds.Y;
            SIZE size = new SIZE();
            size.cx = bounds.Width;
            size.cy = bounds.Height;
            POINT src = new POINT();
            BLENDFUNCTION blend = new BLENDFUNCTION();
            blend.BlendOp = AC_SRC_OVER;
            blend.BlendFlags = 0;
            blend.SourceConstantAlpha = 255;
            blend.AlphaFormat = AC_SRC_ALPHA;
            UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, mem, ref src, 0, ref blend, ULW_ALPHA);
        }
        finally
        {
            SelectObject(mem, previous);
            DeleteObject(target);
            DeleteDC(mem);
        }
    }

    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
}
'@

Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms, System.Drawing
Note 'compiled'

if ($DumpPath -ne '') { [DshIndicator]::DumpPath = $DumpPath }
$form = New-Object DshIndicator($StateFile, $Fps)
Note ('form null=' + ($null -eq $form))
$form.Begin()
Note 'begin done'

if ($ParentPid -gt 0) {
    $watch = New-Object System.Windows.Forms.Timer
    $watch.Interval = 2000
    $watch.Add_Tick({
        try { $null = [System.Diagnostics.Process]::GetProcessById($ParentPid) }
        catch { $watch.Stop(); [System.Windows.Forms.Application]::Exit() }
    })
    $watch.Start()
}

Note 'entering run'
[System.Windows.Forms.Application]::Run($form)
Note 'run returned'












