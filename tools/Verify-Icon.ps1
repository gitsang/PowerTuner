# ============================================================
#  Verify-Icon.ps1 —— 解码 app.ico 并输出 PNG 预览，用于肉眼确认
#  同时校验 ICO 结构（头、目录项、位图头）是否合法
# ============================================================
$ErrorActionPreference = 'Stop'
$icoPath = Join-Path $PSScriptRoot 'app.ico'
$bytes = [IO.File]::ReadAllBytes($icoPath)

function Get-U16 { param($b, $o) return [int]$b[$o] -bor ([int]$b[$o + 1] -shl 8) }
function Get-U32 { param($b, $o) return [long]$b[$o] -bor ([long]$b[$o + 1] -shl 8) -bor ([long]$b[$o + 2] -shl 16) -bor ([long]$b[$o + 3] -shl 24) }

# ---- 校验 ICO 头 ----
$reserved = Get-U16 $bytes 0
$type = Get-U16 $bytes 2
$count = Get-U16 $bytes 4
"ICO 头: reserved=$reserved type=$type count=$count"
if ($reserved -ne 0 -or $type -ne 1) { throw "不是合法 ICO 文件" }

$entries = @()
for ($i = 0; $i -lt $count; $i++) {
    $e = 6 + $i * 16
    $w = [int]$bytes[$e]
    if ($w -eq 0) { $w = 256 }
    $h = [int]$bytes[$e + 1]
    if ($h -eq 0) { $h = 256 }
    $bits = Get-U16 $bytes ($e + 6)
    $len = Get-U32 $bytes ($e + 8)
    $off = Get-U32 $bytes ($e + 12)
    $entries += [pscustomobject]@{ W = $w; H = $h; Bits = $bits; Len = $len; Off = $off }
    "  项 {0}: {1}x{2} {3}bpp  len={4} off={5}" -f $i, $w, $h, $bits, $len, $off
}
"目录总长: $(6 + 16 * $count)，文件长: $($bytes.Length)"

# ---- PNG 编码器 ----
$crcTable = New-Object 'uint32[]' 256
for ($n = 0; $n -lt 256; $n++) {
    $c = [uint32]$n
    for ($k = 0; $k -lt 8; $k++) {
        if ($c -band 1) { $c = [uint32](0xEDB88320 -bxor ($c -shr 1)) } else { $c = [uint32]($c -shr 1) }
    }
    $crcTable[$n] = $c
}
function Get-Crc32 { param([byte[]]$data, [int]$off, [int]$len) 
    $c = [uint32]::MaxValue
    for ($i = $off; $i -lt ($off + $len); $i++) {
        $c = [uint32]($crcTable[[int](($c -bxor $data[$i]) -band 0xFF)] -bxor ($c -shr 8))
    }
    return [uint32]($c -bxor [uint32]::MaxValue)
}
function Get-Adler32 { param([byte[]]$data)
    $a = [uint32]1; $b = [uint32]0
    foreach ($d in $data) { $a = [uint32](($a + $d) % 65521); $b = [uint32](($b + $a) % 65521) }
    return [uint32](($b -shl 16) -bor $a)
}

function Write-Png {
    param([string]$Path, [int]$W, [int]$H, [byte[]]$Rgba)

    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $bw.Write([byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))

    $ihdr = New-Object 'byte[]' 13
    $wB = [BitConverter]::GetBytes([int]$W); [Array]::Reverse($wB)
    [Array]::Copy($wB, 0, $ihdr, 0, 4)
    $hB = [BitConverter]::GetBytes([int]$H); [Array]::Reverse($hB)
    [Array]::Copy($hB, 0, $ihdr, 4, 4)
    $ihdr[8] = 8; $ihdr[9] = 6; $ihdr[10] = 0; $ihdr[11] = 0; $ihdr[12] = 0

    # IHDR 块
    $lenB = [BitConverter]::GetBytes([int]13); [Array]::Reverse($lenB)
    $bw.Write($lenB)
    $typeB = [byte[]](0x49, 0x48, 0x44, 0x52)
    $bw.Write($typeB)
    $bw.Write($ihdr)
    $crcInput = New-Object 'byte[]' (4 + 13)
    [Array]::Copy($typeB, 0, $crcInput, 0, 4)
    [Array]::Copy($ihdr, 0, $crcInput, 4, 13)
    $c = [BitConverter]::GetBytes([uint32](Get-Crc32 $crcInput 0 17)); [Array]::Reverse($c)
    $bw.Write($c)

    # 原始扫描线（每行前面加 filter=0）
    $raw = New-Object 'byte[]' ($H * (1 + $W * 4))
    for ($y = 0; $y -lt $H; $y++) {
        $raw[$y * (1 + $W * 4)] = 0
        [Array]::Copy($Rgba, $y * $W * 4, $raw, $y * (1 + $W * 4) + 1, $W * 4)
    }

    # zlib 压缩
    $comp = New-Object IO.MemoryStream
    $ds = New-Object IO.Compression.DeflateStream($comp, [IO.Compression.CompressionMode]::Compress)
    $ds.Write($raw, 0, $raw.Length)
    $ds.Close()
    $deflated = $comp.ToArray()

    $z = New-Object 'byte[]' (2 + $deflated.Length + 4)
    $z[0] = 0x78; $z[1] = 0x9C
    [Array]::Copy($deflated, 0, $z, 2, $deflated.Length)
    $ad = [BitConverter]::GetBytes([uint32](Get-Adler32 $raw)); [Array]::Reverse($ad)
    [Array]::Copy($ad, 0, $z, 2 + $deflated.Length, 4)

    $lenB = [BitConverter]::GetBytes([int]$z.Length); [Array]::Reverse($lenB)
    $bw.Write($lenB)
    $typeB = [byte[]](0x49, 0x44, 0x41, 0x54)
    $bw.Write($typeB); $bw.Write($z)
    $crcInput = New-Object 'byte[]' (4 + $z.Length)
    [Array]::Copy($typeB, 0, $crcInput, 0, 4)
    [Array]::Copy($z, 0, $crcInput, 4, $z.Length)
    $c = [BitConverter]::GetBytes([uint32](Get-Crc32 $crcInput 0 (4 + $z.Length))); [Array]::Reverse($c)
    $bw.Write($c)

    # IEND
    $bw.Write([byte[]](0, 0, 0, 0))
    $bw.Write([byte[]](0x49, 0x45, 0x4E, 0x44))
    $bw.Write([byte[]](0xAE, 0x42, 0x60, 0x82))
    $bw.Flush()
    [IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Close()
}

# ---- 解码指定尺寸并导出 PNG ----
function Export-Preview {
    param([int]$Index, [string]$OutFile, [int]$Scale = 1)

    $en = $entries[$Index]
    $w = $en.W; $h = $en.H
    $base = [int]$en.Off

    $biSize = Get-U32 $bytes $base
    $biW = Get-U32 $bytes ($base + 4)
    $biH = Get-U32 $bytes ($base + 8)
    "  位图头: biSize=$biSize biW=$biW biH=$biH (应为 $w / $($h*2))"

    $pixBase = $base + 40
    $rgba = New-Object 'byte[]' ($w * $h * 4)
    for ($y = 0; $y -lt $h; $y++) {
        $srcRow = $pixBase + ($h - 1 - $y) * $w * 4
        for ($x = 0; $x -lt $w; $x++) {
            $s = $srcRow + $x * 4
            $d = ($y * $w + $x) * 4
            $rgba[$d + 0] = $bytes[$s + 2]
            $rgba[$d + 1] = $bytes[$s + 1]
            $rgba[$d + 2] = $bytes[$s + 0]
            $rgba[$d + 3] = $bytes[$s + 3]
        }
    }

    if ($Scale -gt 1) {
        $sw = $w * $Scale; $sh = $h * $Scale
        $big = New-Object 'byte[]' ($sw * $sh * 4)
        for ($y = 0; $y -lt $sh; $y++) {
            for ($x = 0; $x -lt $sw; $x++) {
                $s = ([int][Math]::Floor($y / $Scale) * $w + [int][Math]::Floor($x / $Scale)) * 4
                $d = ($y * $sw + $x) * 4
                $big[$d] = $rgba[$s]; $big[$d + 1] = $rgba[$s + 1]; $big[$d + 2] = $rgba[$s + 2]; $big[$d + 3] = $rgba[$s + 3]
            }
        }
        Write-Png -Path $OutFile -W $sw -H $sh -Rgba $big
    }
    else {
        Write-Png -Path $OutFile -W $w -H $h -Rgba $rgba
    }
    "  -> $OutFile"
}

""
"---- 导出预览 ----"
Export-Preview -Index 5 -OutFile (Join-Path $PSScriptRoot 'preview-256.png')
Export-Preview -Index 1 -OutFile (Join-Path $PSScriptRoot 'preview-32x8.png') -Scale 8
"完成"
