@echo off
setlocal
cd /d "%~dp0"
set "FW=%~dp0firmware\QEMU_EFI_W10M_1440x2560_DIAG.fd"
set "IMG=%~dp0work\RM1104-sdcard.img"
set "SER=%~dp0work\diag-serial.log"
set "QEMU=%~dp0work\tools\qemu-6.2.0-winrt-v3\qemu-system-arm.exe"
if not exist "%QEMU%" ( echo Could not find QEMU at %QEMU% - run Run-Lumia950.cmd once first. ^& pause ^& exit /b 1 )
if not exist "%IMG%" ( echo Disk image not found: %IMG% - run Run-Lumia950.cmd once first. ^& pause ^& exit /b 1 )
if not exist "%FW%" ( echo Diagnostic firmware not found: %FW% ^& pause ^& exit /b 1 )
echo Diagnostic firmware run (traces the Windows loader to the serial log).
echo QEMU: %QEMU%
echo Serial log will be: %SER%
echo.
"%QEMU%" -name "Lumia 950 (RM-1104) - W10M DIAGNOSTIC" -M virt,highmem=off -cpu cortex-a15 -smp 1 -m 2048 -accel tcg,thread=multi -bios "%FW%" -device VGA -device usb-kbd,id=kbd -device usb-tablet,id=mice -nic none -drive "id=phone,if=sd,format=raw,cache=writeback,file=%IMG%" -rtc base=2015-11-05,clock=vm -serial "file:%SER%" -display gtk,zoom-to-fit=on
echo.
echo Diagnostic run finished. Serial log saved to %SER%
pause
