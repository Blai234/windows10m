Lumia 950 (RM-1104) Windows 10 Mobile in QEMU
===============================================

Run it
------
1. Extract this folder anywhere on an NTFS drive with ~5 GB free.
   (If Windows marks the files as downloaded: right-click the zip > Properties >
   Unblock before extracting.)
2. Double-click Run-Lumia950.cmd and pick
   RM1104_1078.0017.10586.13053.15482.02FAFD_retail_prod_signed.ffu when asked
   (or drop the .ffu next to the script; it is only ever read).
3. Later runs reuse the same disk image and FFU location. Options:
     Run-Lumia950.cmd -Rebuild      fresh image from the FFU (never-booted phone)
     Run-Lumia950.cmd -Snapshot     run without keeping any changes
     Run-Lumia950.cmd -NoLaunch     only download tools and build the image
     Run-Lumia950.cmd -Display sdl  SDL window instead of GTK

Everything the script creates goes into the "work" folder next to it. Delete that
folder to remove all of it. Nothing else on the PC is used or changed.

What it downloads (SHA-256 checked)
-----------------------------------
- QEMU 6.2.0 with driver1998's Windows-on-ARM patches, binarymaster build v3
  github.com/binarymaster/qemu/releases/tag/v6.2.0-winrt-v3
  qemu-6.2.0-winrt-emu-v3.7z  0AA650FC14935005EAA2836CE1F4EC879940B56B5B8D54E71E5EC78B0BA897F5
- 7zr.exe 25.01 from github.com/ip7z/7zip (to unpack the .7z)
  27CBE3D5804AD09E90BBCAA916DA0D5C3B0BE9462D0E0FB6CB54BE5ED9030875
- DiscUtils 0.16.13 (Streams, Core, Ntfs, Fat) from nuget.org, checked against
  the DiscUtils strong-name key (token 5fa5b410cc9c6289)

What it does to the image
-------------------------
- FFU -> 32 GiB sparse raw disk (QEMU's SD card needs a power-of-two size).
  Blocks land where a phone flasher would put them; the backup GPT is moved
  to the end of the bigger disk.
- EFIESP: copies the boot manager to EFI\BOOT\BOOTARM.EFI (if missing) so the
  firmware boots the SD card by itself instead of dropping to the UEFI shell.
- SYSTEM hive: adds the ROOT\BasicDisplay devnode desktop Windows has (the
  phone image only has a driver for the Lumia's own GPU), and removes
  StorageSvc from LaunchAppSvc's dependencies.
- SOFTWARE hive: HKLM\SOFTWARE\Microsoft\UIX ResolutionOverrideWidth/Height =
  1440/2560.
- No signed file is modified. Registry edits use a built-in hive editor that
  leaves security descriptors byte-for-byte untouched.
- The guest clock starts the day after the image's hives were last written.
- A report of what was found and changed is saved as work\image-build.txt.

Firmware
--------
firmware\QEMU_EFI_W10M_1440x2560.fd is driver1998/edk2-winrt (branch winrt,
commit 9ef33b4, ArmVirtQemuWinRt) rebuilt with the changes in
firmware\edk2-winrt-1440x2560.patch:

- Video: the driver offers one mode, 1440x2560 portrait, and starts in it. The
  stock firmware starts at 800x600; Windows 10 Mobile then picks its 480x800
  resource set, which this 1440x2560 image does not contain, and dwm/sihost
  crash on the missing resources.

- Boot-loop fix: Windows 10 Mobile's mobilestartup.efi reset the machine a few
  seconds into every boot (the "reboots at the TianoCore screen, again and
  again" symptom). It needs three things the stock Windows-on-ARM firmware does
  not provide, and resets when any is missing:
    * an EFI_RNG_PROTOCOL (used to build the device ID) -- added as a small
      timer-seeded generator (W10mRngDxe);
    * room for the ~15 KB Secure Boot "CurrentPolicy" variable -- the per-
      variable limit was raised from 1 KB to 64 KB and the store to 256 KB;
    * first-boot state that a real phone keeps but this firmware (whose UEFI
      variables do not survive a reset) cannot: before boot it now creates
      \Windows\System32\boot\FirstBootPostFlash.Done on the EFIESP and stores
      CurrentPolicy from \MMO\Security\SecureBootPolicy.p7b -- the same bytes
      mobilestartup would write before resetting to apply them.
  With these, mobilestartup runs through and hands off to the Windows loader
  instead of resetting. Verified in QEMU: the boot manager now reaches the
  Windows loader stage instead of looping.

What to expect
--------------
UEFI (tall black window) -> Windows logo -> long first boot. Under emulation
everything runs on one emulated core (the patched QEMU cannot start more), so
allow 10-30 minutes; first-boot provisioning may reboot the VM on its own.
Serial output (UEFI only, Windows does not log there) goes to work\serial-*.log.
A QMP socket listens on 127.0.0.1:49552 for debugging (-QmpPort 0 disables it).

Known limits
------------
- Input: the patched board only has an EHCI USB controller. The build report
  tells you whether this image contains usbehci.sys; if it doesn't, keyboard
  and mouse won't work inside Windows (they still work in UEFI).
- The firmware-level boot loop at mobilestartup.efi (reboots at the TianoCore
  screen) is fixed; see Firmware above. What you should now see is the UEFI
  screen, then the Windows logo, then the long first boot.
- Nobody has published this phone OS reaching its Start screen in QEMU. Earlier
  attempts got through the kernel to a running session with dwm and sihost and
  then stalled on missing 480x800 resources, a crashing StorageSvc and a
  first-boot account-provisioning service (AccountProvSvc) that can reboot the
  VM when it fails. This script addresses the mobilestartup loop, the 480x800
  resources and StorageSvc at the source; if a later provisioning reboot
  remains, that is the next thing to investigate.
