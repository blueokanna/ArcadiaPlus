<#
.SYNOPSIS
Signs a HAP with the DevEco signing material and verifies the signature it just
wrote.

.DESCRIPTION
A device rejects an unsigned HAP with a parse error and nothing else to go on,
so the release artifacts and the CI uploads are named -unsigned / -signed.
This script turns an unsigned artifact into an installable one:

  1. locate hap-sign-tool.jar and java in the DevEco installation;
  2. take the signing material from build-profile.json5 when DevEco wrote it
     there (auto-sign), else from -Keystore/-Cert/-Profile/... parameters;
  3. sign with `sign-app -mode localSign`;
  4. run `verify-app` on the result and fail if it does not verify.

A debug Profile is a device whitelist: the signed HAP installs only on devices
registered to that profile. Auto-sign registers the connected device; more
devices are added in AGC's 设备管理 and the .p7b downloaded again.

.PARAMETER Hap
The unsigned HAP to sign (e.g. ArcadiaPlus-v1.0.5-ohos-arm64-unsigned.hap).

.PARAMETER OutFile
Where the signed HAP is written. Default: <Hap>-signed.hap next to the input.

.PARAMETER Keystore
The .p12 keystore. Defaults to the material in ohos/build-profile.json5.

.PARAMETER Cert
The .cer certificate. Same default as -Keystore.

.PARAMETER Profile
The .p7b provisioning profile. Same default as -Keystore.

.PARAMETER KeystorePassword
Keystore password. Defaults to the one build-profile.json5 holds.

.PARAMETER KeyAlias
Key alias. Defaults to the one build-profile.json5 holds.

.PARAMETER KeyPassword
Key password. Defaults to the one build-profile.json5 holds.

.PARAMETER SignAlg
SHA256withECDSA (default) or SHA256withRSA for manually created RSA keys.

.PARAMETER DevEcoHome
DevEco Studio installation root (holds sdk\ and jbr\). Probed when omitted.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File ohos/scripts/sign-hap.ps1 `
  -Hap ArcadiaPlus-v1.0.5-ohos-arm64-unsigned.hap
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Hap,
    [string]$OutFile,
    [string]$Keystore,
    [string]$Cert,
    [string]$Profile,
    [string]$KeystorePassword,
    [string]$KeyAlias,
    [string]$KeyPassword,
    [string]$SignAlg = 'SHA256withECDSA',
    [string]$DevEcoHome
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$message) {
    Write-Error $message -ErrorAction Continue
    exit 1
}

# ---- the HAP ----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Hap)) {
    Fail "HAP not found: $Hap"
}
$Hap = (Resolve-Path -LiteralPath $Hap).Path
if (-not $OutFile) {
    $OutFile = [IO.Path]::ChangeExtension($Hap, $null) + '-signed.hap'
}
if ([IO.Path]::GetFullPath($OutFile) -eq $Hap) {
    Fail '-OutFile must differ from -Hap; signing writes a new package.'
}

# ---- the tool and the runtime ----------------------------------------------

function Find-DevEcoRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
            $DevEcoHome,
            $env:DEVECO_SDK_HOME,
            'D:\DevEco Studio',
            "$env:ProgramFiles\Huawei\DevEco Studio",
            "${env:ProgramFiles(x86)}\Huawei\DevEco Studio",
            "$env:LOCALAPPDATA\Huawei\DevEco Studio")) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $full = (Resolve-Path -LiteralPath $candidate).Path
            # DEVECO_SDK_HOME points into the SDK; step out of the sdk folder
            # so the jbr sibling is found as well.
            if ($full -match '^(.*?)[\\/]sdk([\\/].*)?$') { $full = $Matches[1] }
            $roots.Add($full)
        }
    }
    return $roots
}

$signTool = $null
$java = $null
foreach ($root in Find-DevEcoRoots) {
    if (-not $signTool) {
        foreach ($rel in @(
                'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar',
                'sdk\default\hms\toolchains\lib\hap-sign-tool.jar')) {
            $candidate = Join-Path $root $rel
            if (Test-Path -LiteralPath $candidate) { $signTool = $candidate; break }
        }
    }
    if (-not $java) {
        $candidate = Join-Path $root 'jbr\bin\java.exe'
        if (Test-Path -LiteralPath $candidate) { $java = $candidate }
    }
}
if (-not $signTool) {
    Fail @'
hap-sign-tool.jar was not found under a DevEco installation. Pass
-DevEcoHome <DevEco root>, or set DEVECO_SDK_HOME to an SDK whose
sdk/default/openharmony/toolchains/lib holds the tool.
'@
}
if (-not $java) {
    $javaCommand = Get-Command 'java' -ErrorAction SilentlyContinue
    if (-not $javaCommand) {
        Fail 'No Java runtime found: neither a DevEco jbr nor java on PATH.'
    }
    $java = $javaCommand.Source
}
Write-Host "tool: $signTool"
Write-Host "java: $java"

# ---- the signing material ---------------------------------------------------

function Read-Json5String([string]$text, [string]$key) {
    $match = [regex]::Match($text, "`"$key`"\s*:\s*`"([^`"]*)`"")
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

$profilePath = Join-Path $PSScriptRoot '..\build-profile.json5'
$wantMaterial = -not ($Keystore -and $Cert -and $Profile -and $KeystorePassword -and $KeyAlias -and $KeyPassword)
if ($wantMaterial) {
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Fail "ohos/build-profile.json5 not found next to $PSScriptRoot; cannot read signing material."
    }
    $text = Get-Content -LiteralPath $profilePath -Raw
    if ($text -match '"signingConfigs"\s*:\s*\[\s*\]') {
        Fail @'
ohos/build-profile.json5 holds no signing material, and no complete
-Keystore/-Cert/-Profile/-KeystorePassword/-KeyAlias/-KeyPassword set was
given. Create the material once in DevEco Studio (File -> Project Structure ->
Signing Configs -> automatically generate signature, logged into a real-name
Huawei developer account), which writes it into build-profile.json5; then run
this script again. See ohos/README.md, section "签名材料".
'@
    }
    $baseDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    if (-not $Keystore) {
        $rel = Read-Json5String $text 'storeFile'
        if ($rel) { $Keystore = Join-Path $baseDir $rel }
    }
    if (-not $Cert) {
        $rel = Read-Json5String $text 'certpath'
        if ($rel) { $Cert = Join-Path $baseDir $rel }
    }
    if (-not $Profile) {
        $rel = Read-Json5String $text 'profile'
        if ($rel) { $Profile = Join-Path $baseDir $rel }
    }
    if (-not $KeystorePassword) { $KeystorePassword = Read-Json5String $text 'storePassword' }
    if (-not $KeyAlias) { $KeyAlias = Read-Json5String $text 'keyAlias' }
    if (-not $KeyPassword) { $KeyPassword = Read-Json5String $text 'keyPassword' }
}

foreach ($pair in @(
        @{ name = 'Keystore'; value = $Keystore },
        @{ name = 'Cert'; value = $Cert },
        @{ name = 'Profile'; value = $Profile },
        @{ name = 'KeystorePassword'; value = $KeystorePassword },
        @{ name = 'KeyAlias'; value = $KeyAlias },
        @{ name = 'KeyPassword'; value = $KeyPassword })) {
    if (-not $pair.value) {
        Fail "-$($pair.name) is missing; pass it explicitly or configure DevEco auto-sign."
    }
}
foreach ($file in @($Keystore, $Cert, $Profile)) {
    if (-not (Test-Path -LiteralPath $file)) {
        Fail "signing material not found: $file"
    }
}

# ---- sign -------------------------------------------------------------------

Write-Host "signing $Hap -> $OutFile"
& $java -jar $signTool sign-app `
    -mode localSign `
    -signAlg $SignAlg `
    -keystoreFile $Keystore `
    -keystorePwd $KeystorePassword `
    -keyAlias $KeyAlias `
    -keyPwd $KeyPassword `
    -appCertFile $Cert `
    -profileFile $Profile `
    -inFile $Hap `
    -outFile $OutFile
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutFile)) {
    Fail "sign-app failed with exit code $LASTEXITCODE"
}

# ---- prove it ---------------------------------------------------------------

$certOut = Join-Path $env:TEMP 'hap-verify-certs.cer'
$profileOut = Join-Path $env:TEMP 'hap-verify-profile.p7b'
& $java -jar $signTool verify-app `
    -inFile $OutFile `
    -outCertChain $certOut `
    -outProfile $profileOut
if ($LASTEXITCODE -ne 0) {
    Fail "the signed HAP does not verify (exit code $LASTEXITCODE); not handing out $OutFile"
}

Write-Host ''
Write-Host "signed and verified: $OutFile"
Write-Host 'install with: hdc install "' -NoNewline
Write-Host $OutFile -NoNewline
Write-Host '"'
Write-Host 'a debug profile installs only on devices registered to it; add devices in AGC 设备管理 and update the .p7b to widen the list.'
