/** @file
  Prepare a Windows 10 Mobile EFIESP so mobilestartup.efi does not reset the
  machine on every boot.

  Under this firmware the UEFI variables do not survive a reset (they are not
  backed by persistent flash). On a real phone the first boots after flashing
  leave two things behind that this firmware therefore cannot keep:

    - \Windows\System32\boot\FirstBootPostFlash.Done. Without it,
      mobilestartup.efi deletes every UEFI variable as a first-boot cleanup and
      resets.
    - The CurrentPolicy variable (Microsoft vendor GUID): the Secure Boot
      policy mobilestartup.efi carries. When it is missing or differs,
      mobilestartup writes it and resets to apply it; the reset loses the
      variable and the next boot hits the same path -> a reset loop.

  Before the boot manager launches the W10M boot manager, for the volume that
  holds mobilestartup.efi this creates the marker file (which persists on the
  SD card) and stores CurrentPolicy from \MMO\Security\SecureBootPolicy.p7b,
  whose bytes are identical to the policy mobilestartup.efi would write. The
  policy is re-stored on every boot, so mobilestartup always finds it in place
  and continues instead of resetting.

  SPDX-License-Identifier: BSD-2-Clause-Patent
**/

#include <Uefi.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Protocol/SimpleFileSystem.h>
#include <Guid/FileInfo.h>

#define MOBILESTARTUP_PATH  L"\\Windows\\System32\\boot\\mobilestartup.efi"
#define FIRSTBOOT_DONE_PATH L"\\Windows\\System32\\boot\\FirstBootPostFlash.Done"
#define POLICY_PATH         L"\\MMO\\Security\\SecureBootPolicy.p7b"
#define CURRENTPOLICY_NAME  L"CurrentPolicy"
#define MAX_POLICY_SIZE     (64u * 1024u)

STATIC EFI_GUID  mMicrosoftVendorGuid = {
  0x77fa9abd, 0x0359, 0x4d32, { 0xbd, 0x60, 0x28, 0xf4, 0xe7, 0x8f, 0x78, 0x4b }
};

STATIC
EFI_STATUS
ReadWholeFile (
  IN  EFI_FILE_PROTOCOL  *Root,
  IN  CHAR16             *Path,
  OUT UINT8              **Data,
  OUT UINTN              *Size
  )
{
  EFI_STATUS         Status;
  EFI_FILE_PROTOCOL  *File;
  EFI_FILE_INFO      *Info;
  UINTN              InfoSize;
  UINT8              *Buffer;
  UINTN              FileSize;

  Status = Root->Open (Root, &File, Path, EFI_FILE_MODE_READ, 0);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  InfoSize = 0;
  Status   = File->GetInfo (File, &gEfiFileInfoGuid, &InfoSize, NULL);
  if (Status != EFI_BUFFER_TOO_SMALL) {
    File->Close (File);
    return EFI_DEVICE_ERROR;
  }
  Info = AllocatePool (InfoSize);
  if (Info == NULL) {
    File->Close (File);
    return EFI_OUT_OF_RESOURCES;
  }
  Status = File->GetInfo (File, &gEfiFileInfoGuid, &InfoSize, Info);
  if (EFI_ERROR (Status)) {
    FreePool (Info);
    File->Close (File);
    return Status;
  }
  FileSize = (UINTN)Info->FileSize;
  FreePool (Info);
  if ((FileSize == 0) || (FileSize > MAX_POLICY_SIZE)) {
    File->Close (File);
    return EFI_UNSUPPORTED;
  }

  Buffer = AllocatePool (FileSize);
  if (Buffer == NULL) {
    File->Close (File);
    return EFI_OUT_OF_RESOURCES;
  }
  Status = File->Read (File, &FileSize, Buffer);
  File->Close (File);
  if (EFI_ERROR (Status)) {
    FreePool (Buffer);
    return Status;
  }
  *Data = Buffer;
  *Size = FileSize;
  return EFI_SUCCESS;
}

STATIC
VOID
PrepareVolume (
  IN EFI_FILE_PROTOCOL  *Root
  )
{
  EFI_STATUS         Status;
  EFI_FILE_PROTOCOL  *File;
  UINT8              *Policy;
  UINTN              PolicySize;

  //
  // Only the EFIESP volume carries mobilestartup.efi; ignore the rest.
  //
  Status = Root->Open (Root, &File, MOBILESTARTUP_PATH, EFI_FILE_MODE_READ, 0);
  if (EFI_ERROR (Status)) {
    return;
  }
  File->Close (File);

  //
  // 1. FirstBootPostFlash.Done -- create if absent (persists on the SD card).
  //
  Status = Root->Open (Root, &File, FIRSTBOOT_DONE_PATH, EFI_FILE_MODE_READ, 0);
  if (EFI_ERROR (Status)) {
    Status = Root->Open (
                     Root,
                     &File,
                     FIRSTBOOT_DONE_PATH,
                     EFI_FILE_MODE_CREATE | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_READ,
                     0
                     );
    if (!EFI_ERROR (Status)) {
      File->Close (File);
      DEBUG ((EFI_D_INFO, "W10mPrepare: created FirstBootPostFlash.Done\n"));
    } else {
      DEBUG ((EFI_D_WARN, "W10mPrepare: could not create marker: %r\n", Status));
    }
  } else {
    File->Close (File);
  }

  //
  // 2. CurrentPolicy -- store the Secure Boot policy mobilestartup expects.
  //
  Status = ReadWholeFile (Root, POLICY_PATH, &Policy, &PolicySize);
  if (!EFI_ERROR (Status)) {
    Status = gRT->SetVariable (
                    CURRENTPOLICY_NAME,
                    &mMicrosoftVendorGuid,
                    EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS |
                    EFI_VARIABLE_RUNTIME_ACCESS,
                    PolicySize,
                    Policy
                    );
    DEBUG ((EFI_D_INFO, "W10mPrepare: CurrentPolicy (%d bytes): %r\n", PolicySize, Status));
    FreePool (Policy);
  } else {
    DEBUG ((EFI_D_WARN, "W10mPrepare: no SecureBootPolicy.p7b: %r\n", Status));
  }
}

/**
  Scan every mounted filesystem and prepare the W10M EFIESP, if present.
**/
VOID
W10mPrepare (
  VOID
  )
{
  EFI_STATUS                       Status;
  EFI_HANDLE                       *Handles;
  UINTN                            Count;
  UINTN                            Index;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL  *Fs;
  EFI_FILE_PROTOCOL                *Root;

  Handles = NULL;
  Count   = 0;
  Status  = gBS->LocateHandleBuffer (
                   ByProtocol,
                   &gEfiSimpleFileSystemProtocolGuid,
                   NULL,
                   &Count,
                   &Handles
                   );
  if (EFI_ERROR (Status)) {
    return;
  }

  for (Index = 0; Index < Count; Index++) {
    Status = gBS->HandleProtocol (
                     Handles[Index],
                     &gEfiSimpleFileSystemProtocolGuid,
                     (VOID **)&Fs
                     );
    if (EFI_ERROR (Status)) {
      continue;
    }
    Status = Fs->OpenVolume (Fs, &Root);
    if (EFI_ERROR (Status)) {
      continue;
    }
    PrepareVolume (Root);
    Root->Close (Root);
  }

  if (Handles != NULL) {
    FreePool (Handles);
  }
}
