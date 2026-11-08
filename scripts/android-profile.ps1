param(
    [string]$Package = 'com.blueokanna.arcadiaplus',
    [ValidateRange(1, 60)][int]$Samples = 6,
    [ValidateRange(1, 60)][int]$IntervalSeconds = 10,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../build/android-profile')
)
$ErrorActionPreference = 'Stop'
if ($Package -notmatch '^[A-Za-z][A-Za-z0-9_.]+$') { throw 'Invalid package name' }
$devices = @(& adb devices | Select-String '\sdevice$')
if ($devices.Count -ne 1) { throw 'Connect exactly one authorized Android device first.' }
$deviceSerial = ($devices[0].Line -split '\s+')[0]
$appPids = (& adb -s $deviceSerial shell pidof $Package)
if ($LASTEXITCODE -ne 0 -or -not $appPids) { throw 'Launch the app before collecting measurements.' }
$targetDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
& adb -s $deviceSerial shell dumpsys gfxinfo $Package reset | Out-Null
for ($sample = 0; $sample -lt $Samples; $sample++) {
    & adb -s $deviceSerial shell dumpsys meminfo $Package |
        Set-Content -LiteralPath (Join-Path $targetDirectory "memory-$sample.txt") -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'Memory sampling failed' }
    if ($sample + 1 -lt $Samples) { Start-Sleep -Seconds $IntervalSeconds }
}
& adb -s $deviceSerial shell dumpsys gfxinfo $Package framestats |
    Set-Content -LiteralPath (Join-Path $targetDirectory 'frames.txt') -Encoding UTF8
if ($LASTEXITCODE -ne 0) { throw 'Frame sampling failed' }
Write-Output "Saved measurements to $targetDirectory"
