# ============================================================================
#  miniaudio_bridge Android arm64 build script (Windows / NDK / PowerShell)
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File build_android.ps1
#    powershell -ExecutionPolicy Bypass -File build_android.ps1 "C:\path\to\ndk"
#
#  Output:
#    ..\libs\android\miniaudio_bridge-debug.aar
#    ..\libs\android\miniaudio_bridge-release.aar
#    ..\libs\android\arm64\libminiaudio_bridge.so
# ============================================================================

param(
    [string]$NdkPath = ""
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

Write-Host "============================================================"
Write-Host " miniaudio_bridge Android arm64 Build (Windows / NDK)"
Write-Host "============================================================"

# ---- 1. Resolve NDK path ----
# Priority: argument > ANDROID_NDK_HOME > ANDROID_NDK_ROOT > auto-detect
if ([string]::IsNullOrEmpty($NdkPath)) {
    $NdkPath = $env:ANDROID_NDK_HOME
}
if ([string]::IsNullOrEmpty($NdkPath)) {
    $NdkPath = $env:ANDROID_NDK_ROOT
}

# Auto-detect: scan common Windows NDK install locations
if ([string]::IsNullOrEmpty($NdkPath)) {
    Write-Host "[INFO] NDK path not provided, auto-detecting..."

    $candidates = @()
    if (-not [string]::IsNullOrEmpty($env:LOCALAPPDATA)) {
        $candidates += Join-Path $env:LOCALAPPDATA "Android\Sdk\ndk"
    }
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) {
        $candidates += Join-Path $env:USERPROFILE "AppData\Local\Android\Sdk\ndk"
        $candidates += Join-Path $env:USERPROFILE "Android\Sdk\ndk-bundle"
    }
    if (-not [string]::IsNullOrEmpty($env:ANDROID_HOME)) {
        $candidates += Join-Path $env:ANDROID_HOME "ndk"
        $candidates += Join-Path $env:ANDROID_HOME "ndk-bundle"
    }
    if (-not [string]::IsNullOrEmpty($env:ANDROID_SDK_ROOT)) {
        $candidates += Join-Path $env:ANDROID_SDK_ROOT "ndk"
        $candidates += Join-Path $env:ANDROID_SDK_ROOT "ndk-bundle"
    }

    foreach ($base in $candidates) {
        if (Test-Path $base) {
            # If base itself has source.properties -> it's an NDK root (ndk-bundle layout)
            if (Test-Path (Join-Path $base "source.properties")) {
                $NdkPath = $base
                break
            }
            # Otherwise pick the highest-versioned subdirectory (side-by-side layout)
            $sub = Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending |
                   Select-Object -First 1
            if ($null -ne $sub -and (Test-Path (Join-Path $sub.FullName "source.properties"))) {
                $NdkPath = $sub.FullName
                break
            }
        }
    }
}

if ([string]::IsNullOrEmpty($NdkPath) -or -not (Test-Path $NdkPath)) {
    Write-Host ""
    Write-Host "[ERROR] Android NDK not found!"
    Write-Host ""
    Write-Host "Solutions:"
    Write-Host "  1. Install NDK via Android Studio: Settings -> Languages & Frameworks"
    Write-Host "     -> Android SDK -> SDK Tools -> NDK (Side by side)"
    Write-Host "  2. Or install via sdkmanager:"
    Write-Host "       sdkmanager `"ndk;26.1.10909125`""
    Write-Host "  3. Or set environment variable:"
    Write-Host "       set ANDROID_NDK_HOME=C:\path\to\ndk"
    Write-Host "  4. Or pass NDK path as argument:"
    Write-Host "       build_android.bat `"C:\path\to\ndk`""
    Write-Host ""
    Write-Host "Common NDK location:"
    Write-Host "  C:\Users\<user>\AppData\Local\Android\Sdk\ndk\<version>"
    exit 1
}

if (-not (Test-Path (Join-Path $NdkPath "source.properties"))) {
    Write-Host "[ERROR] Invalid NDK path (missing source.properties): $NdkPath"
    exit 1
}

Write-Host "[INFO] Using NDK: $NdkPath"

# ---- 2. Check miniaudio.h (git 子模块) ----
if (-not (Test-Path "miniaudio\miniaudio.h")) {
    Write-Host ""
    Write-Host "[ERROR] miniaudio\miniaudio.h not found!"
    Write-Host "The miniaudio submodule is missing. Run:"
    Write-Host "  git submodule update --init --recursive"
    exit 1
}
Write-Host "[INFO] miniaudio\miniaudio.h: OK"

# ---- 3. Locate NDK toolchain (Windows host: windows-x86_64) ----
$toolchain = Join-Path $NdkPath "toolchains\llvm\prebuilt\windows-x86_64"
if (-not (Test-Path $toolchain)) {
    $alt = Join-Path $NdkPath "toolchains\llvm\prebuilt\windows"
    if (Test-Path $alt) {
        $toolchain = $alt
    } else {
        Write-Host "[ERROR] NDK toolchain directory not found: $toolchain"
        Write-Host "Please verify NDK installation is complete."
        exit 1
    }
}

# ---- 4. Android API level (default 24 = Android 7.0+) ----
if ([string]::IsNullOrEmpty($env:ANDROID_API)) {
    $api = "24"
} else {
    $api = $env:ANDROID_API
}
Write-Host "[INFO] Android API: $api (arm64-v8a)"

# ---- 5. Target compiler ----
# Newer NDK: aarch64-linux-android<API>-clang.cmd ; older: .sh / no extension
$cc = Join-Path $toolchain "bin\aarch64-linux-android$api-clang.cmd"
if (-not (Test-Path $cc)) {
    $cc = Join-Path $toolchain "bin\aarch64-linux-android$api-clang"
}
if (-not (Test-Path $cc)) {
    Write-Host "[ERROR] Compiler not found: $cc"
    Write-Host "Check NDK version and API level. Set ANDROID_API env var to adjust, e.g.:"
    Write-Host "  set ANDROID_API=21"
    exit 1
}
Write-Host "[INFO] Compiler: $cc"

# ---- 6. Compile ----
Write-Host ""
Write-Host "[1/3] Compiling libminiaudio_bridge.so (arm64-v8a, API $api)..."

$ccArgs = @("-O2", "-fPIC", "-DNDEBUG", "-DMA_BRIDGE_EXPORTS", "-shared",
            "miniaudio_bridge.c",
            "-o", "libminiaudio_bridge.so",
            "-lOpenSLES")

& $cc @ccArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAILED] Compilation failed."
    exit 1
}
Write-Host "[SUCCESS] libminiaudio_bridge.so compiled."

# ---- 7. Package AAR ----
Write-Host ""
Write-Host "[2/3] Packaging AAR..."

if (Test-Path "_aar_tmp") {
    Remove-Item -Recurse -Force "_aar_tmp"
}
New-Item -ItemType Directory -Path "_aar_tmp\jni\arm64-v8a" -Force | Out-Null
Copy-Item -Force "libminiaudio_bridge.so" "_aar_tmp\jni\arm64-v8a\"

$manifest = @'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.godot.miniaudio">
</manifest>
'@
$manifest | Set-Content -Path "_aar_tmp\AndroidManifest.xml" -Encoding UTF8

if (-not (Test-Path "..\libs\android")) {
    New-Item -ItemType Directory -Path "..\libs\android" -Force | Out-Null
}

# Remove existing AAR files first
$aarDebug = "..\libs\android\miniaudio_bridge-debug.aar"
$aarRelease = "..\libs\android\miniaudio_bridge-release.aar"
if (Test-Path $aarDebug) { Remove-Item -Force $aarDebug }
if (Test-Path $aarRelease) { Remove-Item -Force $aarRelease }

# IMPORTANT: Manually create the ZIP with forward-slash entry names.
# Both PowerShell Compress-Archive and .NET Framework ZipFile.CreateFromDirectory
# on Windows emit entries with backslashes (e.g. "jni\arm64-v8a\libfoo.so"),
# which violates the ZIP spec. Android's gradle/AGP requires forward slashes
# ("jni/arm64-v8a/libfoo.so") and silently ignores backslash entries, causing
# "library not found" at dlopen time.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$absAarDir = (Resolve-Path "_aar_tmp").Path
$absAarDebug = (Resolve-Path -Path ".").Path + "\..\libs\android\miniaudio_bridge-debug.aar"

$fs = [System.IO.File]::Open($absAarDebug, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $files = Get-ChildItem -Path $absAarDir -Recurse -File
    foreach ($f in $files) {
        # Compute relative path and force forward slashes (ZIP spec)
        $rel = $f.FullName.Substring($absAarDir.Length + 1).Replace('\', '/')
        $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        try {
            $fileBytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $entryStream.Write($fileBytes, 0, $fileBytes.Length)
        } finally {
            $entryStream.Close()
        }
    }
} finally {
    $zip.Dispose()
    $fs.Close()
}
Copy-Item -Force $aarDebug $aarRelease

Remove-Item -Recurse -Force "_aar_tmp"

Write-Host "[SUCCESS] AAR packaged:"
Write-Host "  $aarDebug"
Write-Host "  $aarRelease"

# ---- 8. Copy .so to arm64/ (backup) ----
Write-Host ""
Write-Host "[3/3] Copying .so to ..\libs\android\arm64\ (backup)..."
if (-not (Test-Path "..\libs\android\arm64")) {
    New-Item -ItemType Directory -Path "..\libs\android\arm64" -Force | Out-Null
}
Copy-Item -Force "libminiaudio_bridge.so" "..\libs\android\arm64\"
Write-Host "[SUCCESS] ..\libs\android\arm64\libminiaudio_bridge.so"

# ---- 9. Done ----
Write-Host ""
Write-Host "============================================================"
Write-Host " Build succeeded!"
Write-Host "============================================================"
Write-Host " Output:"
Write-Host "   $aarDebug"
Write-Host "   $aarRelease"
Write-Host "   ..\libs\android\arm64\libminiaudio_bridge.so"
Write-Host ""
Write-Host " Next steps:"
Write-Host "   1. Enable miniaudio plugin in Godot (Project -> Project Settings -> Plugins)"
Write-Host "   2. Re-deploy/export Android APK"
Write-Host "============================================================"
exit 0
