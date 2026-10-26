@echo off
setlocal
title MiniPC - Start local NPU worker
cd /d "%~dp0"

echo MiniPC NPU worker launcher
echo Target: MateBook Pro S [7QB0126509000160]
echo Connect the compute device to this computer with HDC available.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\vl-worker.ps1" -Device 7QB0126509000160 -Action Start
set "MINIPC_EXIT_CODE=%ERRORLEVEL%"
if not "%MINIPC_EXIT_CODE%"=="0" goto failed

echo.
echo Checking worker status...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\vl-worker.ps1" -Device 7QB0126509000160 -Action Status
set "MINIPC_EXIT_CODE=%ERRORLEVEL%"
if not "%MINIPC_EXIT_CODE%"=="0" goto failed

echo.
echo A READY line above confirms that the worker is available.
echo The compute HAP must include the updated worker bridge.
goto finished

:failed
echo.
echo Worker startup failed. See the error above.
echo Check the HDC connection and open the installed compute application first.

:finished
echo.
if not defined MINIPC_NO_PAUSE pause
exit /b %MINIPC_EXIT_CODE%
