# Generate Android launcher icons from the project logo.
#
# Run from anywhere:
#
#     powershell -File .project/tool/generate_launcher_icons.ps1
#
# Why a script rather than a build plugin: flutter_launcher_icons would add a
# dev dependency and a pub step to every fresh checkout, and this is a handful of
# resizes. The logo does not change between releases.
#
# The logo is a navy square with the mark floating in the middle, padding on all
# four sides. Scaling that whole square into an icon makes the mark tiny, so the
# mark is trimmed out of its padding first and only then scaled. The padding
# colour becomes the background layer.
#
# Two sets are written, and both are needed:
#
#   * The per-density ic_launcher.png bitmaps for pre-Android-8, where the whole
#     bitmap is the icon.
#   * An adaptive icon, mipmap-anydpi-v26/ic_launcher.xml, for Android 8 and up.
#     Those mask the icon to a shape the launcher picks, so the bitmap is split
#     into a background layer and a foreground layer, and the mark is scaled into
#     the middle 72dp of a 108dp canvas -- the region Android guarantees survives
#     every mask. Without this, Android 8+ shows a small icon inside a white
#     rounded square.

param(
    [string]$Logo,
    [string]$ResDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Resolved here rather than as param defaults, because a default cannot call
# Join-Path against $PSScriptRoot.
if (-not $Logo) {
    # .project/tool -> workspace root
    $Logo = Join-Path (Split-Path -Parent $PSScriptRoot) '..\logo.png'
}
if (-not $ResDir) {
    $ResDir = Join-Path $PSScriptRoot '..\android\app\src\main\res'
}

if (-not (Test-Path -LiteralPath $Logo)) {
    throw "Logo not found: $Logo"
}

$source = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Logo))
Write-Host "source: $($source.Width)x$($source.Height) from $Logo"

# The logo has no alpha channel (24bpp RGB), so its corners are the padding
# colour and can be sampled rather than guessed.
$padding = [System.Drawing.Color]::FromArgb(255, 0, 0, 0)
$probe = New-Object System.Drawing.Bitmap($source)
$padding = $probe.GetPixel(0, 0)
$probe.Dispose()
Write-Host ("padding colour: #{0:X2}{1:X2}{2:X2}" -f $padding.R, $padding.G, $padding.B)

# Per-channel difference at which a pixel counts as "not padding". Small, because
# the logo has anti-aliased edges, but not so small that JPEG-ish noise counts.
$Tolerance = 24

function Test-IsPadding {
    param([System.Drawing.Color]$Colour)
    return (
        [Math]::Abs($Colour.R - $padding.R) -le $Tolerance -and
        [Math]::Abs($Colour.G - $padding.G) -le $Tolerance -and
        [Math]::Abs($Colour.B - $padding.B) -le $Tolerance
    )
}

# Scans inward from each edge rather than over every pixel: the padding is most
# of the image, so this finds the first mark pixel quickly instead of reading
# 1.5 million of them.
function Get-MarkBounds {
    param([System.Drawing.Bitmap]$Bitmap)

    $minX = -1; $minY = -1; $maxX = -1; $maxY = -1

    for ($y = 0; $y -lt $Bitmap.Height -and $minY -lt 0; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            if (-not (Test-IsPadding $Bitmap.GetPixel($x, $y))) {
                $minY = $y; break
            }
        }
    }
    for ($y = $Bitmap.Height - 1; $y -ge 0 -and $maxY -lt 0; $y--) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            if (-not (Test-IsPadding $Bitmap.GetPixel($x, $y))) {
                $maxY = $y; break
            }
        }
    }
    for ($x = 0; $x -lt $Bitmap.Width -and $minX -lt 0; $x++) {
        for ($y = 0; $y -lt $Bitmap.Height; $y++) {
            if (-not (Test-IsPadding $Bitmap.GetPixel($x, $y))) {
                $minX = $x; break
            }
        }
    }
    for ($x = $Bitmap.Width - 1; $x -ge 0 -and $maxX -lt 0; $x--) {
        for ($y = 0; $y -lt $Bitmap.Height; $y++) {
            if (-not (Test-IsPadding $Bitmap.GetPixel($x, $y))) {
                $maxX = $x; break
            }
        }
    }

    if ($minX -lt 0 -or $minY -lt 0 -or $maxX -lt 0 -or $maxY -lt 0) {
        throw 'The logo appears to be a single flat colour; nothing to trim.'
    }
    return [System.Drawing.Rectangle]::new(
        $minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1)
    )
}

$bitmapSource = New-Object System.Drawing.Bitmap($source)
$bounds = Get-MarkBounds $bitmapSource
Write-Host ("mark: {0}x{1} at {2},{3} ({4:P0} of the canvas)" -f `
    $bounds.Width, $bounds.Height, $bounds.X, $bounds.Y, `
    (($bounds.Width * $bounds.Height) / ($source.Width * $source.Height)))

$legacy = [ordered]@{
    'mipmap-mdpi'    = 48
    'mipmap-hdpi'    = 72
    'mipmap-xhdpi'   = 96
    'mipmap-xxhdpi'  = 144
    'mipmap-xxxhdpi' = 192
}

# Adaptive layers are 108dp at every density; the mark goes in the middle 72dp.
$adaptive = [ordered]@{
    'mipmap-mdpi'    = 108
    'mipmap-hdpi'    = 162
    'mipmap-xhdpi'   = 216
    'mipmap-xxhdpi'  = 324
    'mipmap-xxxhdpi' = 432
}

function New-Canvas {
    param(
        [int]$Side,
        [System.Drawing.Color]$Background
    )
    $canvas = New-Object System.Drawing.Bitmap(
        $Side, $Side, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.Clear($Background)
    return @($canvas, $g)
}

function Draw-Mark {
    param(
        [System.Drawing.Bitmap]$Canvas,
        [System.Drawing.Graphics]$Graphics,
        # Fraction of the canvas the mark may fill.
        [double]$Fill
    )
    $side = [double]$Canvas.Width * $Fill
    $scale = [Math]::Min(
        $side / $bounds.Width,
        $side / $bounds.Height
    )
    $width = [double]$bounds.Width * $scale
    $height = [double]$bounds.Height * $scale
    $x = ([double]$Canvas.Width - $width) / 2
    $y = ([double]$Canvas.Height - $height) / 2
    $Graphics.DrawImage(
        $bitmapSource,
        [System.Drawing.RectangleF]::new($x, $y, $width, $height),
        [System.Drawing.RectangleF]::new(
            [float]$bounds.X, [float]$bounds.Y, [float]$bounds.Width, [float]$bounds.Height
        ),
        [System.Drawing.GraphicsUnit]::Pixel
    )
}

function Write-Png {
    param([System.Drawing.Bitmap]$Bitmap, [string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host ("  {0}  {1}x{2}" -f `
        [System.IO.Path]::GetFileName($Path), $Bitmap.Width, $Bitmap.Height)
}

# Legacy: the mark on the logo's own padding colour, with a little breathing room
# because a launcher on these versions may still round the corners.
Write-Host 'legacy icons'
foreach ($density in $legacy.Keys) {
    $side = $legacy[$density]
    $pair = New-Canvas -Side $side -Background $padding
    Draw-Mark -Canvas $pair[0] -Graphics $pair[1] -Fill 0.84
    $pair[1].Dispose()
    Write-Png $pair[0] (Join-Path $ResDir "$density\ic_launcher.png")
    $pair[0].Dispose()
}

# Adaptive foreground: transparent outside the mark, so the launcher can shape it.
#
# 0.60 of a 108dp canvas, which puts the mark inside the 66dp circle Android
# guarantees is always visible. The documented safe square is 72dp, but a square
# mark at 72dp loses its corners to a circular mask, and this one is a square
# green block. The navy it sits on is the same navy as the background layer, so
# anything clipped is invisible anyway.
Write-Host 'adaptive foreground'
foreach ($density in $adaptive.Keys) {
    $pair = New-Canvas -Side $adaptive[$density] `
        -Background ([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
    Draw-Mark -Canvas $pair[0] -Graphics $pair[1] -Fill 0.60
    $pair[1].Dispose()
    Write-Png $pair[0] (Join-Path $ResDir "$density\ic_launcher_foreground.png")
    $pair[0].Dispose()
}

# Adaptive background: flat padding colour.
Write-Host 'adaptive background'
foreach ($density in $adaptive.Keys) {
    $pair = New-Canvas -Side $adaptive[$density] -Background $padding
    $pair[1].Dispose()
    Write-Png $pair[0] (Join-Path $ResDir "$density\ic_launcher_background.png")
    $pair[0].Dispose()
}

$bitmapSource.Dispose()
$source.Dispose()

# anydpi-v26 keeps the adaptive icon out of the way of the legacy bitmaps, which
# is how the two coexist on one manifest entry.
$anydpi = Join-Path $ResDir 'mipmap-anydpi-v26'
if (-not (Test-Path -LiteralPath $anydpi)) {
    New-Item -ItemType Directory -Path $anydpi -Force | Out-Null
}
$xml = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by tool/generate_launcher_icons.ps1. Do not edit by hand. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
'@
$encoding = New-Object System.Text.UTF8Encoding($false)
# Written to both names: some launchers ask for the round variant explicitly, and
# a missing one falls back to a default icon rather than this one.
[System.IO.File]::WriteAllText((Join-Path $anydpi 'ic_launcher.xml'), $xml, $encoding)
[System.IO.File]::WriteAllText((Join-Path $anydpi 'ic_launcher_round.xml'), $xml, $encoding)
Write-Host '  mipmap-anydpi-v26\ic_launcher.xml'
Write-Host '  mipmap-anydpi-v26\ic_launcher_round.xml'

Write-Host 'done'