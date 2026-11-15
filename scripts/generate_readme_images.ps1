[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $repoRoot
try {
    & dart format --output=none --set-exit-if-changed lib test
    if ($LASTEXITCODE -ne 0) {
        throw 'Dart formatting differs from CI requirements; format the reported files before rendering'
    }
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
