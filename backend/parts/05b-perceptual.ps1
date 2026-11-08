# ---------------------------------------------------------------------------
# Perceptual change: turn "did the bytes change" into "does it look different".
#
# A byte comparison calls a blinking caret, a ticking clock, a progress bar and the
# taskbar clock "changed", so the model is told the screen moved every time it looks --
# when the question it is actually asking is "did the page change". Following dsh-see-now,
# the frame is shrunk to a 64x36 grid of average colours and the grids are compared cell
# by cell: that flattens single-pixel noise while keeping layout and dominant-colour
# changes.
#
# This is a hint, not a verdict: a low score only means "from these 64x36 cells the picture
# barely moved", and the model may still ask for the frame. So it touches no capture or
# injection path; it only adds a number to each capture receipt.
#
# NOTE: keep this file ASCII. parts/*.ps1 are concatenated into worker.ps1, which must be
# UTF-8 without BOM, and PowerShell 5.1's ParseFile decodes a BOM-less file as ANSI --
# dense non-ASCII comments come out as mangled bytes and break the parse.
# ---------------------------------------------------------------------------

$script:PerceptualCols = 64
$script:PerceptualRows = 36
$script:PerceptualThreshold = 8.0
# Average colour difference over 0..255. 8 is roughly "3% per cell": enough to swallow
# caret/stopwatch noise, not enough to miss a repainted list row.
if (-not [string]::IsNullOrWhiteSpace($env:DSH_COMPUTER_USE_CHANGE_THRESHOLD)) {
    $parsedThreshold = 0.0
    if ([double]::TryParse("$env:DSH_COMPUTER_USE_CHANGE_THRESHOLD", [ref]$parsedThreshold) -and $parsedThreshold -ge 0) {
        $script:PerceptualThreshold = $parsedThreshold
    }
}
# Cells whose average colour moved by at least this much count as "changed cells". A cell
# is one of 2304; 12 keeps a caret or a clock second out (1-2 cells) while letting a
# repainted row or a new line of text in (dozens of cells).
$script:PerceptualCellDelta = 12.0
if (-not [string]::IsNullOrWhiteSpace($env:DSH_COMPUTER_USE_CHANGE_CELL)) {
    $parsedCell = 0.0
    if ([double]::TryParse("$env:DSH_COMPUTER_USE_CHANGE_CELL", [ref]$parsedCell) -and $parsedCell -ge 0) {
        $script:PerceptualCellDelta = $parsedCell
    }
}
$script:PerceptualMinCells = 12
# One signature per capture target (screen / a window / a region), keyed by specKey. The
# cap is small on purpose: only a handful of keys ever appear, but an unbounded map would
# eat worker memory over a long session.
$script:PerceptualLast = @{}
$script:PerceptualMaxKeys = 8

function Get-BitmapSignature([System.Drawing.Bitmap]$bmp) {
    if ($null -eq $bmp) { return $null }
    $cols = $script:PerceptualCols
    $rows = $script:PerceptualRows
    $small = New-Object System.Drawing.Bitmap($cols, $rows, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bytes = $null
    $stride = 0
    try {
        $g = [System.Drawing.Graphics]::FromImage($small)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.DrawImage($bmp, 0, 0, $cols, $rows)
        } finally { $g.Dispose() }
        $rect = New-Object System.Drawing.Rectangle(0, 0, $cols, $rows)
        $data = $small.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $stride = [int]$data.Stride
            $bytes = New-Object byte[] ($stride * $rows)
            [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        } finally { $small.UnlockBits($data) }
    } finally { $small.Dispose() }
    if ($null -eq $bytes -or $stride -le 0) { return $null }
    # Memory is BGRA; the signature normalises to three RGB bytes per cell so it does not
    # depend on the source pixel format.
    $sig = New-Object byte[] ($cols * $rows * 3)
    for ($row = 0; $row -lt $rows; $row++) {
        $lineBase = $row * $stride
        for ($col = 0; $col -lt $cols; $col++) {
            $p = $lineBase + ($col * 4)
            $dst = (($row * $cols) + $col) * 3
            $sig[$dst] = $bytes[$p + 2]
            $sig[$dst + 1] = $bytes[$p + 1]
            $sig[$dst + 2] = $bytes[$p]
        }
    }
    return $sig
}

function Compare-Signature([byte[]]$current, [byte[]]$previous) {
    if ($null -eq $current -or $null -eq $previous) { return $null }
    if ($current.Length -ne $previous.Length) { return $null }
    $cells = $current.Length / 3
    if ($cells -le 0) { return $null }
    $sum = 0.0
    $changedCells = 0
    for ($i = 0; $i -lt $current.Length; $i += 3) {
        $dr = [Math]::Abs([int]$current[$i] - [int]$previous[$i])
        $dg = [Math]::Abs([int]$current[$i + 1] - [int]$previous[$i + 1])
        $db = [Math]::Abs([int]$current[$i + 2] - [int]$previous[$i + 2])
        $cell = ($dr + $dg + $db) / 3.0
        $sum += $cell
        if ($cell -ge $script:PerceptualCellDelta) { $changedCells++ }
    }
    return [ordered]@{ score = $sum / [double]$cells; cells = $changedCells; total = [int]$cells }
}

function Get-FrameChange([string]$key, [System.Drawing.Bitmap]$bmp) {
    # No pixels or no scale: report "unknown" instead of a score. A guessed number is worse
    # than an absent one, because it would be read as evidence.
    if ($null -eq $bmp) { return $null }
    $sig = $null
    try { $sig = Get-BitmapSignature $bmp } catch { return $null }
    if ($null -eq $sig) { return $null }
    $previous = $null
    if ($script:PerceptualLast.ContainsKey($key)) { $previous = $script:PerceptualLast[$key] }
    # Store the new one, treating insertion order as LRU: remove then add, so the oldest key
    # sits at the head of the key sequence.
    $script:PerceptualLast.Remove($key)
    $script:PerceptualLast[$key] = $sig
    while ($script:PerceptualLast.Count -gt $script:PerceptualMaxKeys) {
        $oldest = @($script:PerceptualLast.Keys)[0]
        $script:PerceptualLast.Remove($oldest)
    }
    if ($null -eq $previous) {
        return [ordered]@{ known = $false; cols = $script:PerceptualCols; rows = $script:PerceptualRows }
    }
    $cmp = Compare-Signature $sig $previous
    if ($null -eq $cmp) {
        return [ordered]@{ known = $false; cols = $script:PerceptualCols; rows = $script:PerceptualRows }
    }
    # `changed` is decided by how many cells moved, not by the average: a new line of text
    # moves dozens of cells but barely shifts the average over 2304 of them, while a caret
    # moves one cell and cannot reach the floor. The average is still reported, as context.
    return [ordered]@{
        known     = $true
        score     = [math]::Round([double]$cmp.score, 2)
        cells     = [int]$cmp.cells
        total     = [int]$cmp.total
        threshold = $script:PerceptualThreshold
        cellDelta = $script:PerceptualCellDelta
        minCells  = $script:PerceptualMinCells
        changed   = ([int]$cmp.cells -ge $script:PerceptualMinCells)
        cols      = $script:PerceptualCols
        rows      = $script:PerceptualRows
    }
}
