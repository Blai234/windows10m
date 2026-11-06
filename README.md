# Windows 10 Mobile on QEMU — Lumia 950 (RM-1104)

Firmware changes and tooling to boot a **Windows 10 Mobile** retail FFU
(Lumia 950, RM-1104) in QEMU on an emulated 32-bit ARM board.

Built on top of **[driver1998/edk2-winrt](https://github.com/driver1998/edk2-winrt)**
(branch `winrt`, commit `9ef33b4`, `ArmVirtPkg/ArmVirtQemuWinRt`) and
**[binarymaster/qemu](https://github.com/binarymaster/qemu)** `v6.2.0-winrt-v3`.

## Status

- ✅ **TianoCore reset loop fixed.** `mobilestartup.efi` no longer resets the
  machine a few seconds into every boot; the boot manager now runs through to
  the Windows loader stage.
- ⏳ **Windows loader (`winload.efi`) stage:** work in progress — the boot
  manager loads `winload` from MainOS and currently stops at the `:(` screen.
  `W10mTraceDxe` (below) exists to pin down where.

## What was wrong, and the fix

`mobilestartup.efi` reset the machine on every boot because the stock
Windows-on-ARM firmware lacked three things it needs (it resets when any is
missing):

1. **`EFI_RNG_PROTOCOL`** — used to build the device ID.
   → `ArmVirtPkg/Drivers/W10mRngDxe`: a small timer-seeded generator
   (non-cryptographic; enough for the boot path under emulation).
2. **Room for the ~15 KB Secure Boot `CurrentPolicy` variable** — the stock
   1 KB per-variable limit was far too small.
   → `PcdMaxVariableSize` / `PcdMaxAuthVariableSize` raised to `0x10000`,
   `PcdVariableStoreSize` to `0x40000` (fills the NV region; no FTW overlap).
3. **First-boot state the firmware can't keep** (its UEFI variables are
   RAM-only, so every boot looked like a fresh flash → it wiped all variables
   and rebooted).
   → `ArmVirtPkg/Library/PlatformIntelBdsLib/W10mPrepare.c`, called after
   `BdsLibConnectAll()`, creates
   `\Windows\System32\boot\FirstBootPostFlash.Done` on the EFIESP and seeds the
   `CurrentPolicy` variable from `\MMO\Security\SecureBootPolicy.p7b` (byte-for-
   byte identical to `mobilestartup`'s embedded RCDATA #1) **before** the boot
   manager runs, so `mobilestartup` finds both in place and continues.

Also included:

- **1440×2560 video** — `OvmfPkg/QemuVideoDxe` offers a single 1440×2560
  portrait GOP mode. (W10M otherwise falls back to a 480×800 resource set the
  image doesn't contain, and dwm/sihost crash on the missing resources.)
- **`ArmVirtPkg/Drivers/W10mTraceDxe`** — diagnostic-only: traces
  `LoadImage` / `StartImage` / `ExitBootServices` / `ResetSystem` to the PL011
  UART, and holds ~25 s before a reset so the screen can be read. Not in the
  default build (enable it together with removing the Shell to fit the FV).

## Contents

```
firmware/
  QEMU_EFI_W10M_1440x2560.fd        prebuilt production firmware (RNG + vars + W10mPrepare + 1440x2560)
  QEMU_EFI_W10M_1440x2560_DIAG.fd   diagnostic firmware (adds W10mTraceDxe, drops the Shell)
  edk2-winrt-1440x2560.patch        full diff vs driver1998/edk2-winrt@9ef33b4
firmware-src/                       the new/changed firmware sources, for browsing
qemu-runner/                        Windows scripts that build the disk from the FFU and launch QEMU
  Run-Lumia950.cmd                  double-click to build the image and boot
  Run-Diagnostic.cmd                boot the same image with the diagnostic firmware
  Lumia950-QEMU.ps1                 the actual worker (FFU -> raw disk, registry/EFIESP patches, launch)
  README.txt                        runner usage and what it does to the image
```

## Build the firmware

```sh
git clone -b winrt https://github.com/driver1998/edk2-winrt
cd edk2-winrt && git checkout 9ef33b4
git apply /path/to/firmware/edk2-winrt-1440x2560.patch
# EDK2 BaseTools + Python 2; ARM GCC cross toolchain:
export GCC49_ARM_PREFIX=arm-linux-gnueabihf-
source edksetup.sh BaseTools
build -a ARM -t GCC49 -b RELEASE -p ArmVirtPkg/ArmVirtQemuWinRt.dsc
# -> Build/ArmVirtQemuWinRt-ARM/RELEASE_GCC49/FV/QEMU_EFI.fd
```

## Run (Windows)

Put a Lumia 950 retail FFU next to `Run-Lumia950.cmd` (or pick it when asked)
and double-click it. The script downloads the patched QEMU (SHA-256 checked),
converts the FFU to a raw SD image, applies the registry/EFIESP fixes, and
launches QEMU with the firmware here. See `qemu-runner/README.txt`.

## Credits

- **driver1998** — [edk2-winrt](https://github.com/driver1998/edk2-winrt) and the
  Windows-on-ARM QEMU platform this builds on.
- **binarymaster** — the prebuilt Windows-on-ARM QEMU (`v6.2.0-winrt-v3`).

The firmware here is a derivative of EDK2 (BSD-2-Clause-Patent); the new drivers
carry that license.
