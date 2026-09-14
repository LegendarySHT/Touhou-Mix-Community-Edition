@echo off
REM ============================================================================
REM  miniaudio_bridge 编译脚本 (Windows MSVC, x64)
REM
REM  使用前:
REM    1. 安装 Visual Studio Build Tools 或 Visual Studio (含 C++ 工具集)
REM    2. 确保 miniaudio 子模块已拉取:
REM       git submodule update --init --recursive
REM       (miniaudio.h 位于 miniaudio\miniaudio.h, 由 git 子模块提供, 勿手动下载覆盖)
REM    3. 在 "x64 Native Tools Command Prompt for VS" 中运行此脚本
REM
REM  产物: miniaudio_bridge.dll (放到 addons\miniaudio\libs\windows\)
REM ============================================================================

setlocal
cd /d "%~dp0"

if not exist miniaudio\miniaudio.h (
    echo [ERROR] miniaudio\miniaudio.h not found.
    echo The miniaudio submodule is missing. Run:
    echo   git submodule update --init --recursive
    exit /b 1
)

echo [1/3] Compiling miniaudio_bridge.c ...
cl /nologo /O2 /LD /EHsc /utf-8 ^
    /DMA_BRIDGE_EXPORTS ^
    /D_CRT_SECURE_NO_WARNINGS ^
    miniaudio_bridge.c ^
    /Fe:miniaudio_bridge.dll ^
    /link /DLL

if errorlevel 1 (
    echo [FAILED] Compilation failed.
    exit /b 1
)

echo [2/3] Cleaning up intermediate files ...
if exist miniaudio_bridge.obj del miniaudio_bridge.obj
if exist miniaudio_bridge.exp del miniaudio_bridge.exp
if exist miniaudio_bridge.lib del miniaudio_bridge.lib

echo [3/3] Copying to addons\miniaudio\libs\windows\ ...
if not exist "..\libs\windows" mkdir "..\libs\windows"
copy /Y miniaudio_bridge.dll "..\libs\windows\miniaudio_bridge.dll"

echo.
echo [SUCCESS] miniaudio_bridge.dll built and copied to:
echo   addons\miniaudio\libs\windows\miniaudio_bridge.dll
endlocal
