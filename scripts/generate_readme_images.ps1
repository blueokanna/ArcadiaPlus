[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $repoRoot
try {
    foreach ($language in @('en', 'zh')) {
        & flutter test --no-pub test/readme_showcase_test.dart `
            --dart-define=CAPTURE_UI=true "--dart-define=SHOWCASE_LOCALE=$language"
        if ($LASTEXITCODE -ne 0) {
            throw "README rendering failed for $language"
        }
    }
    & python scripts/update_readme_image_manifest.py
    if ($LASTEXITCODE -ne 0) {
        throw 'README image provenance validation failed'
    }
} finally {
    Pop-Location
}
