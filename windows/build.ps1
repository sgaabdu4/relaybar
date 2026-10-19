param([switch]$Install)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$out = Join-Path $root 'build\windows'
New-Item -ItemType Directory -Force $out | Out-Null
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'

Add-Type -AssemblyName System.Drawing
$ico = Join-Path $out 'Relaybar.ico'
$png = [Drawing.Image]::FromFile((Join-Path $root 'Resources\AppIcon.png'))
$sizes = 16, 20, 24, 32, 48, 256
$frames = foreach ($size in $sizes) {
  $bitmap = New-Object Drawing.Bitmap $size, $size
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  $graphics.InterpolationMode = 'HighQualityBicubic'
  $graphics.DrawImage($png, 0, 0, $size, $size)
  $graphics.Dispose()
  $stream = New-Object IO.MemoryStream
  $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
  , $stream.ToArray()
}
$png.Dispose()
$writer = New-Object IO.BinaryWriter ([IO.File]::Create($ico))
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($n = 0; $n -lt $sizes.Count; $n++) {
  $writer.Write([byte]($sizes[$n] % 256)); $writer.Write([byte]($sizes[$n] % 256))
  $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
  $writer.Write([uint32]$frames[$n].Length); $writer.Write([uint32]$offset)
  $offset += $frames[$n].Length
}
foreach ($frame in $frames) { $writer.Write($frame) }
$writer.Close()

$exe = Join-Path $out 'Relaybar.exe'
$sources = (Get-ChildItem (Join-Path $PSScriptRoot 'Relaybar\*.cs')).FullName
& $csc /nologo /codepage:65001 /target:winexe /optimize+ /warnaserror+ "/out:$exe" "/win32icon:$ico" `
  /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:Microsoft.VisualBasic.dll `
  "/resource:$root\Resources\claude.svg,claude.svg" "/resource:$root\Resources\codex.svg,codex.svg" $sources
if ($LASTEXITCODE) { throw 'The build failed.' }
Copy-Item $exe (Join-Path $out 'RelaybarSetup.exe') -Force
Write-Output "Built $exe and RelaybarSetup.exe"

if ($Install) {
  $target = Join-Path $env:LOCALAPPDATA 'Programs\Relaybar'
  New-Item -ItemType Directory -Force $target | Out-Null
  Get-Process Relaybar -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $target 'Relaybar.exe') } | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  Copy-Item $exe $target -Force
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Relaybar.lnk'))
  $link.TargetPath = Join-Path $target 'Relaybar.exe'
  $link.WorkingDirectory = $target
  $link.Save()
  Start-Process (Join-Path $target 'Relaybar.exe')
  Write-Output "Installed to $target and started Relaybar"
}
