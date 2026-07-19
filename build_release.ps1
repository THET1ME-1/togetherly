# Flutter release build — splits APK by ABI and renames to version
$pubspec = Get-Content pubspec.yaml | Where-Object { $_ -match '^version:' }
$version = ($pubspec -replace '^version:\s*', '').Trim()

Write-Host "Building version $version..." -ForegroundColor Cyan

flutter build apk --release --split-per-abi

$outDir  = "build\app\outputs\flutter-apk"
$destDir = "release"
New-Item -ItemType Directory -Force -Path $destDir | Out-Null

$map = @{
    "app-armeabi-v7a-release.apk" = "$version-v7a-release.apk"
    "app-arm64-v8a-release.apk"   = "$version-v8a-release.apk"
    "app-x86_64-release.apk"      = "$version-x86_64-release.apk"
}

foreach ($src in $map.Keys) {
    $srcPath = Join-Path $outDir $src
    if (Test-Path $srcPath) {
        $dst = Join-Path $destDir $map[$src]
        Copy-Item $srcPath $dst -Force
        Write-Host "  -> $($map[$src])" -ForegroundColor Green
    }
}

Write-Host "Done. Files in .\release\" -ForegroundColor Cyan
