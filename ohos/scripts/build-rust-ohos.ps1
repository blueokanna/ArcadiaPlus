# Build the ArcadiaPlus Rust engine for HarmonyOS (arm64) on Windows and stage
# the artifacts the HAP build consumes — the PowerShell counterpart of
# build-rust-ohos.sh, with the same output contract:
#
#   * ohos/entry/src/main/cpp/thirdparty/arm64-v8a/librust_lib_arcadiaplus.a
#     statically linked into libarcadia_core.so by the entry module's CMake
#   * ohos/entry/libs/arm64-v8a/librust_lib_arcadiaplus.so
#     the cdylib hvigor packs into the HAP next to libapp.so
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File ohos/scripts/build-rust-ohos.ps1
#   powershell ... -File ... -Ndk "D:\DevEco Studio\sdk\default\openharmony\native"

param(
    [string]$Ndk = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$target = 'aarch64-unknown-linux-ohos'
$abi = 'arm64-v8a'

function Find-Ndk {
    if ($Ndk) { return $Ndk }
    if ($env:OHOS_NDK) { return $env:OHOS_NDK }
    $candidates = @()
    if ($env:DEVECO_SDK_HOME) {
        $candidates += Join-Path $env:DEVECO_SDK_HOME 'default/openharmony/native'
    }
    $candidates += @(
        'D:\DevEco Studio\sdk\default\openharmony\native',
        'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native'
    )
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Huawei\Sdk\openharmony\native'
    }
    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate 'llvm/bin/clang.exe')) { return $candidate }
    }
    throw 'the HarmonyOS NDK was not found; pass -Ndk <.../openharmony/native> or set OHOS_NDK'
}

$ndk = (Resolve-Path -LiteralPath (Find-Ndk)).Path

$mapped = $null
if ($ndk -match ' ') {
    # cc-rs and rustc split unquoted flag strings on whitespace, so a space in
    # the NDK path (D:\DevEco Studio\...) breaks --sysroot. A directory
    # junction under %LOCALAPPDATA% gives every tool a space-free path without
    # needing elevation or a free drive letter.
    $link = Join-Path $env:LOCALAPPDATA 'ohos-ndk-native'
    if (Test-Path $link) { cmd /c rmdir "$link" | Out-Null }
    New-Item -ItemType Junction -Path $link -Target $ndk | Out-Null
    if (-not (Test-Path (Join-Path $link 'llvm\bin\clang.exe'))) {
        throw "could not create a space-free junction for the HarmonyOS NDK at $link"
    }
    $mapped = $link
    $ndk = $link
}

try {
    $clang = Join-Path $ndk 'llvm\bin\clang.exe'
    $llvmAr = Join-Path $ndk 'llvm\bin\llvm-ar.exe'
    $sysroot = Join-Path $ndk 'sysroot'
    foreach ($required in @($clang, $llvmAr, $sysroot)) {
        if (-not (Test-Path $required)) { throw "not found: $required" }
    }

    $installed = & rustup target list --installed
    if ($installed -notcontains $target) {
        Write-Host "Installing missing Rust target $target"
        & rustup target add $target
        if ($LASTEXITCODE -ne 0) { throw "rustup target add $target failed" }
    }

    Write-Host "Engine target : $target"
    Write-Host "HarmonyOS NDK : $ndk"
    Write-Host "Rust toolchain: $(& rustc --version)"

    # Target-scoped variables only: a global RUSTFLAGS would leak into every
    # other target this machine builds (Android, desktop).
    $env:CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER = $clang
    $env:CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS = "-Clink-arg=--target=aarch64-linux-ohos -Clink-arg=--sysroot=$sysroot"
    $env:CC_aarch64_unknown_linux_ohos = $clang
    $env:AR_aarch64_unknown_linux_ohos = $llvmAr
    $env:CFLAGS_aarch64_unknown_linux_ohos = "--target=aarch64-linux-ohos --sysroot=$sysroot"
    $env:CARGO_TERM_COLOR = 'never'

    # File-existence alone must never be read as "the build succeeded": stale
    # artifacts are removed first, cargo's exit code decides, and the checks
    # below re-assert before anything is staged.
    $release = Join-Path $root "rust\target\$target\release"
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $release 'librust_lib_arcadiaplus.a')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $release 'librust_lib_arcadiaplus.so')

    & cargo build --manifest-path (Join-Path $root 'rust\Cargo.toml') --target $target --release --locked
    if ($LASTEXITCODE -ne 0) { throw 'cargo build failed' }

    $static = Join-Path $release 'librust_lib_arcadiaplus.a'
    $shared = Join-Path $release 'librust_lib_arcadiaplus.so'
    if (-not (Test-Path $static)) { throw "$static was not produced" }
    if (-not (Test-Path $shared)) { throw "$shared was not produced" }

    $staticDest = Join-Path $root "ohos\entry\src\main\cpp\thirdparty\$abi"
    $sharedDest = Join-Path $root "ohos\entry\libs\$abi"
    New-Item -ItemType Directory -Force $staticDest, $sharedDest | Out-Null
    Copy-Item -Force $static $staticDest
    Copy-Item -Force $shared $sharedDest

    Write-Host 'Engine staged:'
    Write-Host "  ohos/entry/src/main/cpp/thirdparty/$abi/librust_lib_arcadiaplus.a"
    Write-Host "  ohos/entry/libs/$abi/librust_lib_arcadiaplus.so"
}
finally {
    if ($mapped) { cmd /c rmdir "$mapped" | Out-Null }
}
