# Export the HarmonyOS signing material in the exact form the
# ARCADIAPLUS_OHOS_* GitHub secrets expect.
#
# Flow: configure signing once in DevEco Studio (File -> Project Structure ->
# Signing Configs -> automatic signing). DevEco writes the material paths and
# the credentials into ohos/build-profile.json5 and drops the files under
# %USERPROFILE%\.ohos\config. Run this script *before* restoring that file:
#
#   powershell -ExecutionPolicy Bypass -File ohos\scripts\export-signing-secrets.ps1
#
# Output: %TEMP%\ohos-signing-secrets\<SECRET_NAME>.txt -- ASCII, no BOM, no
# trailing newline -- plus the plain-text credentials and the full GitHub
# checklist. The keystore is opened with DevEco's own keytool so a wrong store
# password or alias is caught here instead of in CI.
#
# Manually generated material (e.g. a release identity) can be exported by
# passing the files explicitly; add -StorePassword to keep the verification:
#
#   powershell ... -File export-signing-secrets.ps1 -P12 app.p12 -Cer app.cer -P7b app.p7b

param(
    [string]$P12 = '',
    [string]$Cer = '',
    [string]$P7b = '',
    [string]$OutDir = '',
    [string]$StorePassword = '',
    [switch]$SkipInspect
)

$ErrorActionPreference = 'Stop'

function Read-Json5String {
    param([string]$Text, [string]$Name)
    $match = [regex]::Match($Text, '"' + [regex]::Escape($Name) + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($match.Success) { return $match.Groups[1].Value.Replace('\\', '\') }
    return ''
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$profilePath = Join-Path $root 'ohos\build-profile.json5'

$storePassword = $StorePassword
$keyAlias = ''
$keyPassword = ''
$signAlg = ''

if (Test-Path -LiteralPath $profilePath) {
    $text = Get-Content -LiteralPath $profilePath -Raw
    if (-not $P12) { $P12 = Read-Json5String $text 'storeFile' }
    if (-not $Cer) { $Cer = Read-Json5String $text 'certpath' }
    if (-not $P7b) { $P7b = Read-Json5String $text 'profile' }
    if (-not $storePassword) { $storePassword = Read-Json5String $text 'storePassword' }
    $keyAlias = Read-Json5String $text 'keyAlias'
    $keyPassword = Read-Json5String $text 'keyPassword'
    $signAlg = Read-Json5String $text 'signAlg'
}

if (-not $P12 -or -not $Cer -or -not $P7b) {
    $configDir = Join-Path $env:USERPROFILE '.ohos\config'
    Write-Host "ohos/build-profile.json5 carries no signing material; falling back to $configDir" -ForegroundColor Yellow
    Write-Host 'If build-profile.json5 was already restored, pass the three files explicitly with -P12/-Cer/-P7b.' -ForegroundColor Yellow
    if (-not (Test-Path -LiteralPath $configDir)) {
        throw 'no signing material found - configure signing in DevEco Studio (File -> Project Structure -> Signing Configs) or pass -P12/-Cer/-P7b'
    }

    if (-not $P12) {
        $candidates = @(Get-ChildItem -LiteralPath $configDir -File -Filter '*.p12' | Sort-Object LastWriteTime -Descending)
        if ($candidates.Count -eq 0) { throw "no .p12 keystore in $configDir; pass -P12 explicitly" }
        if ($candidates.Count -gt 1) {
            Write-Host 'several .p12 files exist; using the newest - verify it is the one DevEco configured:' -ForegroundColor Yellow
            $candidates | Select-Object -First 5 | ForEach-Object { Write-Host "  $($_.FullName)  ($($_.LastWriteTime))" }
        }
        $P12 = $candidates[0].FullName
    }
    if (-not $Cer) {
        $candidates = @(Get-ChildItem -LiteralPath $configDir -File -Filter '*.cer' | Sort-Object LastWriteTime -Descending)
        if ($candidates.Count -eq 0) { throw "no .cer certificate in $configDir; pass -Cer explicitly" }
        if ($candidates.Count -gt 1) {
            Write-Host 'several .cer files exist; using the newest - verify it is the one DevEco configured:' -ForegroundColor Yellow
            $candidates | Select-Object -First 5 | ForEach-Object { Write-Host "  $($_.FullName)  ($($_.LastWriteTime))" }
        }
        $Cer = $candidates[0].FullName
    }
    if (-not $P7b) {
        $candidates = @(Get-ChildItem -LiteralPath $configDir -File -Filter '*.p7b' | Sort-Object LastWriteTime -Descending)
        if ($candidates.Count -eq 0) { throw "no .p7b profile in $configDir; pass -P7b explicitly" }
        if ($candidates.Count -gt 1) {
            Write-Host 'several .p7b files exist; using the newest - verify it is the one DevEco configured:' -ForegroundColor Yellow
            $candidates | Select-Object -First 5 | ForEach-Object { Write-Host "  $($_.FullName)  ($($_.LastWriteTime))" }
        }
        $P7b = $candidates[0].FullName
    }
}

foreach ($file in @($P12, $Cer, $P7b)) {
    if (-not (Test-Path -LiteralPath $file)) { throw "not found: $file" }
}

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'ohos-signing-secrets' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host ''
Write-Host 'Base64 transcripts (paste each file into the secret of the same name):'
$map = [ordered]@{
    'ARCADIAPLUS_OHOS_KEYSTORE_BASE64' = $P12
    'ARCADIAPLUS_OHOS_CERT_BASE64'     = $Cer
    'ARCADIAPLUS_OHOS_PROFILE_BASE64'  = $P7b
}
foreach ($secret in $map.Keys) {
    $bytes = [IO.File]::ReadAllBytes($map[$secret])
    $b64 = [Convert]::ToBase64String($bytes)
    $outFile = Join-Path $OutDir "$secret.txt"
    [IO.File]::WriteAllText($outFile, $b64, [Text.Encoding]::ASCII)
    Write-Host ('  {0,-34} {1,8} bytes -> {2}' -f $secret, $bytes.Length, $outFile)
}

if (-not $SkipInspect -and $storePassword) {
    $keytool = @()
    if ($env:ProgramFiles) { $keytool += (Join-Path $env:ProgramFiles 'Huawei\DevEco Studio\jbr\bin\keytool.exe') }
    $keytool += 'D:\DevEco Studio\jbr\bin\keytool.exe'
    if ($env:JAVA_HOME) { $keytool += (Join-Path $env:JAVA_HOME 'bin\keytool.exe') }
    $keytool = @($keytool | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $keytool) {
        $cmd = Get-Command keytool -ErrorAction SilentlyContinue
        if ($cmd) { $keytool = @($cmd.Source) }
    }
    if ($keytool) {
        $kt = $keytool[0]
        Write-Host ''
        Write-Host "Verifying the keystore with $kt ..."
        $result = & $kt -J-Duser.language=en -list -v -storetype PKCS12 -keystore $P12 -storepass $storePassword 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'keytool could not open the keystore with the store password from build-profile.json5:' -ForegroundColor Red
            $result | ForEach-Object { Write-Host "  $_" }
        } else {
            $result | Select-String -Pattern '^Alias name:|^Signature algorithm name:|^Valid from:' | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
            $names = @($result | Select-String -Pattern '^Alias name: (.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
            if ($keyAlias) {
                if ($names -contains $keyAlias) {
                    Write-Host "configured keyAlias '$keyAlias' exists in the keystore" -ForegroundColor Green
                } else {
                    Write-Host "configured keyAlias '$keyAlias' was NOT found (aliases present: $($names -join ', '))" -ForegroundColor Red
                }
            }
        }
    } else {
        Write-Host 'keytool not found; skipping the keystore verification' -ForegroundColor Yellow
    }
} elseif (-not $SkipInspect) {
    Write-Host ''
    Write-Host 'keystore verification skipped: no store password available (pass -StorePassword to verify).' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'GitHub: repository -> Settings -> Secrets and variables -> Actions -> New repository secret'
Write-Host 'Fill all seven (the three transcript files map 1:1, drop the .txt suffix):'
Write-Host '  ARCADIAPLUS_OHOS_KEYSTORE_BASE64    <- ARCADIAPLUS_OHOS_KEYSTORE_BASE64.txt'
Write-Host '  ARCADIAPLUS_OHOS_CERT_BASE64        <- ARCADIAPLUS_OHOS_CERT_BASE64.txt'
Write-Host '  ARCADIAPLUS_OHOS_PROFILE_BASE64     <- ARCADIAPLUS_OHOS_PROFILE_BASE64.txt'
Write-Host '  ARCADIAPLUS_OHOS_KEYSTORE_PASSWORD  <- plain text'
Write-Host '  ARCADIAPLUS_OHOS_KEY_ALIAS          <- plain text'
Write-Host '  ARCADIAPLUS_OHOS_KEY_PASSWORD       <- plain text'
Write-Host '  ARCADIAPLUS_OHOS_SIGN_ALG           <- optional; SHA256withECDSA by default, RSA keys need SHA256withRSA'

if ($storePassword -or $keyAlias -or $keyPassword) {
    Write-Host ''
    Write-Host 'Plain-text values read from ohos/build-profile.json5 (already stored on this machine; never commit them):'
    if ($storePassword) { Write-Host "  ARCADIAPLUS_OHOS_KEYSTORE_PASSWORD = $storePassword" }
    if ($keyAlias) { Write-Host "  ARCADIAPLUS_OHOS_KEY_ALIAS         = $keyAlias" }
    if ($keyPassword) { Write-Host "  ARCADIAPLUS_OHOS_KEY_PASSWORD      = $keyPassword" }
    if ($signAlg) { Write-Host "  (DevEco wrote signAlg = $signAlg)" }
}

Write-Host ''
Write-Host 'Afterwards run:  git restore ohos/build-profile.json5'
Write-Host 'That file now holds plain-text passwords and machine-specific absolute paths; the release'
Write-Host 'workflow expects an empty "signingConfigs": [] to inject the secrets into.'
Write-Host 'The Android keystore secrets (ARCADIAPLUS_KEYSTORE_* / ARCADIAPLUS_KEY_*) are a separate set.'
