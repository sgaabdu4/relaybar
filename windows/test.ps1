$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$out = Join-Path $root 'build\windows'
New-Item -ItemType Directory -Force $out | Out-Null
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$exe = Join-Path $out 'RelaybarTests.exe'
& $csc /nologo /codepage:65001 /target:exe /warnaserror+ "/out:$exe" (Join-Path $PSScriptRoot 'Relaybar\Core.cs') (Join-Path $PSScriptRoot 'Tests\Tests.cs')
if ($LASTEXITCODE) { throw 'The tests did not build.' }
& $exe
if ($LASTEXITCODE) { throw 'Some tests failed.' }
