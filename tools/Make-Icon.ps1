# ============================================================
#  Make-Icon.ps1 —— 生成 app.ico（纯字节运算，无需编译或第三方库）
#  设计：蓝色圆角方块 + 白色闪电。多尺寸 32bpp BMP 型 ICO。
#  说明：像素热循环全部内联，避免 PowerShell 函数调用开销
# ============================================================

$ErrorActionPreference = 'Stop'
$outPath = Join-Path $PSScriptRoot 'app.ico'

# 闪电多边形（归一化坐标，6 个顶点）
$PX = @(0.560, 0.290, 0.470, 0.400, 0.715, 0.530)
$PY = @(0.085, 0.545, 0.545, 0.915, 0.445, 0.445)
$RADIUS = 0.20

$sizes = @(16, 32, 48, 64, 128, 256)
$images = @()

foreach ($size in $sizes) {

    if ($size -le 32) { $S = 3 }
    elseif ($size -le 64) { $S = 2 }
    else { $S = 1 }

    $xor = New-Object 'byte[]' ($size * $size * 4)
    $inv = 1.0 / $size
    $step = 1.0 / $S
    $half = $step / 2.0

    for ($y = 0; $y -lt $size; $y++) {
        $rowTarget = ($size - 1 - $y) * $size * 4

        for ($x = 0; $x -lt $size; $x++) {
            $accA = 0.0; $accW = 0.0; $accR = 0.0; $accG = 0.0; $accB = 0.0

            for ($sy = 0; $sy -lt $S; $sy++) {
                $uy = ($y + $sy * $step + $half) * $inv

                for ($sx = 0; $sx -lt $S; $sx++) {
                    $ux = ($x + $sx * $step + $half) * $inv

                    # 圆角矩形覆盖率
                    $dx = $ux
                    $t1 = 1.0 - $ux
                    if ($t1 -lt $dx) { $dx = $t1 }
                    $dy = $uy
                    $t2 = 1.0 - $uy
                    if ($t2 -lt $dy) { $dy = $t2 }

                    $bg = 1.0
                    if ($dx -lt $RADIUS -and $dy -lt $RADIUS) {
                        $ex = $RADIUS - $dx
                        $ey = $RADIUS - $dy
                        if (($ex * $ex + $ey * $ey) -gt ($RADIUS * $RADIUS)) { $bg = 0.0 }
                    }
                    if ($bg -le 0.0) { continue }

                    # 竖向渐变 #1B7ED8 -> #0A5AA0
                    $br = 0x1B + (0x0A - 0x1B) * $uy
                    $bgc = 0x7E + (0x5A - 0x7E) * $uy
                    $bb = 0xD8 + (0xA0 - 0xD8) * $uy

                    # 点在闪电内？射线法
                    $inside = $false
                    $j = 5
                    for ($k = 0; $k -lt 6; $k++) {
                        $yi = $PY[$k]; $yj = $PY[$j]
                        if ((($yi -gt $uy) -ne ($yj -gt $uy))) {
                            $xi = $PX[$k]; $xj = $PX[$j]
                            if ($ux -lt (($xj - $xi) * ($uy - $yi) / ($yj - $yi) + $xi)) {
                                $inside = -not $inside
                            }
                        }
                        $j = $k
                    }
                    if ($inside) { $br = 255.0; $bgc = 255.0; $bb = 255.0 }

                    $accA += $bg
                    $accR += $br * $bg
                    $accG += $bgc * $bg
                    $accB += $bb * $bg
                    $accW += $bg
                }
            }

            $o = $rowTarget + $x * 4
            if ($accW -le 0.0) {
                $xor[$o] = 0; $xor[$o + 1] = 0; $xor[$o + 2] = 0; $xor[$o + 3] = 0
            }
            else {
                $total = $S * $S
                $xor[$o + 0] = [byte][Math]::Round($accB / $accW)
                $xor[$o + 1] = [byte][Math]::Round($accG / $accW)
                $xor[$o + 2] = [byte][Math]::Round($accR / $accW)
                $xor[$o + 3] = [byte][Math]::Min(255, [Math]::Round(255.0 * $accA / $total))
            }
        }
    }

    # AND 掩码（每行 4 字节对齐，透明处置 1）
    $maskStride = [int]([Math]::Floor(($size + 31) / 32) * 4)
    $mask = New-Object 'byte[]' ($maskStride * $size)
    for ($y = 0; $y -lt $size; $y++) {
        $srcRow = ($size - 1 - $y) * $size * 4
        $dstRow = $y * $maskStride
        for ($x = 0; $x -lt $size; $x++) {
            if ($xor[$srcRow + $x * 4 + 3] -lt 128) {
                $bi = $dstRow + [int][Math]::Floor($x / 8)
                $mask[$bi] = [byte]($mask[$bi] -bor (0x80 -shr ($x % 8)))
            }
        }
    }

    # BITMAPINFOHEADER
    $header = New-Object 'byte[]' 40
    $header[0] = 40
    [Array]::Copy([BitConverter]::GetBytes([int]$size), 0, $header, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes([int]($size * 2)), 0, $header, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes([int16]1), 0, $header, 12, 2)
    [Array]::Copy([BitConverter]::GetBytes([int16]32), 0, $header, 14, 2)
    [Array]::Copy([BitConverter]::GetBytes([int]($xor.Length + $mask.Length)), 0, $header, 20, 4)

    $data = New-Object 'byte[]' (40 + $xor.Length + $mask.Length)
    [Array]::Copy($header, 0, $data, 0, 40)
    [Array]::Copy($xor, 0, $data, 40, $xor.Length)
    [Array]::Copy($mask, 0, $data, 40 + $xor.Length, $mask.Length)

    $images += , $data
    Write-Host ("  {0}x{0} 渲染完成" -f $size)
}

# ---- 组装 ICO ----
$count = $images.Count
$total = 6 + 16 * $count
foreach ($img in $images) { $total += $img.Length }

$ico = New-Object 'byte[]' $total
$ico[2] = 1
$ico[4] = [byte]($count % 256)
$ico[5] = [byte][Math]::Floor($count / 256)

$offset = 6 + 16 * $count
for ($i = 0; $i -lt $count; $i++) {
    $size = $sizes[$i]
    $img = $images[$i]
    $e = 6 + $i * 16

    $dim = $size
    if ($size -ge 256) { $dim = 0 }
    $ico[$e + 0] = [byte]$dim
    $ico[$e + 1] = [byte]$dim
    [Array]::Copy([BitConverter]::GetBytes([int16]1), 0, $ico, $e + 4, 2)
    [Array]::Copy([BitConverter]::GetBytes([int16]32), 0, $ico, $e + 6, 2)
    [Array]::Copy([BitConverter]::GetBytes([int]$img.Length), 0, $ico, $e + 8, 4)
    [Array]::Copy([BitConverter]::GetBytes([int]$offset), 0, $ico, $e + 12, 4)

    [Array]::Copy($img, 0, $ico, $offset, $img.Length)
    $offset += $img.Length
}

[IO.File]::WriteAllBytes($outPath, $ico)
Write-Host ("已生成 " + $outPath + "  (" + [Math]::Round($ico.Length / 1KB) + " KB)")
