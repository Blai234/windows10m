/** @file
  Diagnostic trace for the Windows 10 Mobile boot path under QEMU.

  Wraps gBS->LoadImage / gBS->StartImage / gBS->ExitBootServices and
  gRT->ResetSystem and logs each call (and its result) to the PL011 UART, so
  the serial log shows exactly how far the boot manager and winload.efi get and
  with what status. On a reset request it also holds the screen for a while so
  it can be photographed and the serial drained.

  This is a DIAGNOSTIC build only.

  SPDX-License-Identifier: BSD-2-Clause-Patent
**/

#include <Uefi.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/PrintLib.h>
#include <Library/SerialPortLib.h>
#include <Library/DevicePathLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>

STATIC EFI_IMAGE_LOAD          mLoadImage;
STATIC EFI_IMAGE_START         mStartImage;
STATIC EFI_EXIT_BOOT_SERVICES  mExitBootServices;
STATIC EFI_RESET_SYSTEM        mResetSystem;
STATIC UINTN                   mDepth;

STATIC
VOID
Emit (
  IN CONST CHAR8  *Str
  )
{
  SerialPortWrite ((UINT8 *)"TRACE: ", 7);
  SerialPortWrite ((UINT8 *)Str, AsciiStrLen (Str));
  SerialPortWrite ((UINT8 *)"\r\n", 2);
}

STATIC
VOID
EFIAPI
Trace (
  IN CONST CHAR8  *Format,
  ...
  )
{
  CHAR8    Buf[320];
  VA_LIST  Args;

  VA_START (Args, Format);
  AsciiVSPrint (Buf, sizeof (Buf), Format, Args);
  VA_END (Args);
  Emit (Buf);
}

STATIC
VOID
EmitUnicode (
  IN CONST CHAR8    *Tag,
  IN CONST CHAR16   *Str
  )
{
  CHAR8  *Ascii;
  UINTN  Len;

  if (Str == NULL) {
    return;
  }
  Len   = StrLen (Str);
  Ascii = AllocatePool (Len + 1);
  if (Ascii == NULL) {
    return;
  }
  UnicodeStrToAsciiStr (Str, Ascii);
  SerialPortWrite ((UINT8 *)"TRACE: ", 7);
  SerialPortWrite ((UINT8 *)Tag, AsciiStrLen (Tag));
  SerialPortWrite ((UINT8 *)Ascii, AsciiStrLen (Ascii));
  SerialPortWrite ((UINT8 *)"\r\n", 2);
  FreePool (Ascii);
}

STATIC
EFI_STATUS
EFIAPI
HookLoadImage (
  IN  BOOLEAN                   BootPolicy,
  IN  EFI_HANDLE                ParentImageHandle,
  IN  EFI_DEVICE_PATH_PROTOCOL  *DevicePath,
  IN  VOID                      *SourceBuffer OPTIONAL,
  IN  UINTN                     SourceSize,
  OUT EFI_HANDLE                *ImageHandle
  )
{
  EFI_STATUS  Status;
  CHAR16      *Text;

  Status = mLoadImage (BootPolicy, ParentImageHandle, DevicePath, SourceBuffer, SourceSize, ImageHandle);
  Text   = (DevicePath != NULL) ? ConvertDevicePathToText (DevicePath, FALSE, FALSE) : NULL;
  Trace ("LoadImage -> %r", Status);
  if (Text != NULL) {
    EmitUnicode ("  image: ", Text);
    FreePool (Text);
  }
  return Status;
}

STATIC
EFI_STATUS
EFIAPI
HookStartImage (
  IN  EFI_HANDLE  ImageHandle,
  OUT UINTN       *ExitDataSize,
  OUT CHAR16      **ExitData OPTIONAL
  )
{
  EFI_STATUS  Status;

  mDepth++;
  Trace ("StartImage[%d] enter", mDepth);
  Status = mStartImage (ImageHandle, ExitDataSize, ExitData);
  Trace ("StartImage[%d] -> %r", mDepth, Status);
  if ((ExitData != NULL) && (*ExitData != NULL)) {
    EmitUnicode ("  exitdata: ", *ExitData);
  }
  mDepth--;
  return Status;
}

STATIC
EFI_STATUS
EFIAPI
HookExitBootServices (
  IN EFI_HANDLE  ImageHandle,
  IN UINTN       MapKey
  )
{
  Trace ("ExitBootServices (OS is taking over)");
  return mExitBootServices (ImageHandle, MapKey);
}

STATIC
VOID
EFIAPI
HookResetSystem (
  IN EFI_RESET_TYPE  ResetType,
  IN EFI_STATUS      ResetStatus,
  IN UINTN           DataSize,
  IN VOID            *ResetData OPTIONAL
  )
{
  Trace ("ResetSystem type=%d status=%r dataSize=%d", ResetType, ResetStatus, DataSize);
  if ((ResetData != NULL) && (DataSize >= sizeof (CHAR16))) {
    EmitUnicode ("  resetdata: ", (CHAR16 *)ResetData);
  }
  Emit ("holding ~25s before the reset actually happens...");
  gBS->Stall (25 * 1000 * 1000);
  mResetSystem (ResetType, ResetStatus, DataSize, ResetData);
}

EFI_STATUS
EFIAPI
W10mTraceEntry (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  mLoadImage        = gBS->LoadImage;
  mStartImage       = gBS->StartImage;
  mExitBootServices = gBS->ExitBootServices;
  mResetSystem      = gRT->ResetSystem;

  gBS->LoadImage        = HookLoadImage;
  gBS->StartImage       = HookStartImage;
  gBS->ExitBootServices = HookExitBootServices;
  gRT->ResetSystem      = HookResetSystem;

  gBS->Hdr.CRC32 = 0;
  gBS->CalculateCrc32 (gBS, gBS->Hdr.HeaderSize, &gBS->Hdr.CRC32);
  gRT->Hdr.CRC32 = 0;
  gBS->CalculateCrc32 (gRT, gRT->Hdr.HeaderSize, &gRT->Hdr.CRC32);

  Emit ("W10mTraceDxe installed (LoadImage/StartImage/ExitBootServices/ResetSystem)");
  return EFI_SUCCESS;
}
