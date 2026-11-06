@echo off
rem Starts Lumia950-QEMU.ps1 with Windows PowerShell, without changing the system
rem execution policy. Any arguments are passed on, e.g.  Run-Lumia950.cmd -Rebuild
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Lumia950-QEMU.ps1" %*
if errorlevel 1 (
  echo.
  echo The script stopped with an error - see the messages above.
  echo A full log is in the "work" folder next to this file.
  pause
)
endlocal
