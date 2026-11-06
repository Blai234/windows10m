#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Protocol/GraphicsOutput.h>
#include <Protocol/LoadedImage.h>

EFI_STATUS EFIAPI UefiMain (IN EFI_HANDLE ImageHandle, IN EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_GRAPHICS_OUTPUT_PROTOCOL  *Gop = NULL;
  EFI_LOADED_IMAGE_PROTOCOL     *Li = NULL;
  EFI_GRAPHICS_OUTPUT_BLT_PIXEL  Px;
  UINT32                         Mode;
  UINTN                          Size;
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info;

  Print (L"\r\nW10M-QEMU-BOOTTEST: started from the SD card\r\n");
  if (!EFI_ERROR (gBS->HandleProtocol (ImageHandle, &gEfiLoadedImageProtocolGuid, (VOID **)&Li)) && Li->FilePath != NULL) {
    Print (L"W10M-QEMU-BOOTTEST: image loaded OK\r\n");
  }
  if (EFI_ERROR (gBS->LocateProtocol (&gEfiGraphicsOutputProtocolGuid, NULL, (VOID **)&Gop))) {
    Print (L"W10M-QEMU-BOOTTEST: no GOP\r\n");
  } else {
    Print (L"W10M-QEMU-BOOTTEST: GOP current mode %d of %d: %dx%d stride %d fb 0x%lx size 0x%lx\r\n",
           Gop->Mode->Mode, Gop->Mode->MaxMode, Gop->Mode->Info->HorizontalResolution,
           Gop->Mode->Info->VerticalResolution, Gop->Mode->Info->PixelsPerScanLine,
           Gop->Mode->FrameBufferBase, Gop->Mode->FrameBufferSize);
    for (Mode = 0; Mode < Gop->Mode->MaxMode; Mode++) {
      if (!EFI_ERROR (Gop->QueryMode (Gop, Mode, &Size, &Info))) {
        Print (L"W10M-QEMU-BOOTTEST: mode %d = %dx%d\r\n", Mode, Info->HorizontalResolution, Info->VerticalResolution);
      }
    }
    Px.Blue = 0xD7; Px.Green = 0x78; Px.Red = 0x00; Px.Reserved = 0;   /* Windows-phone blue */
    Gop->Blt (Gop, &Px, EfiBltVideoFill, 0, 0, 0, 0,
              Gop->Mode->Info->HorizontalResolution, Gop->Mode->Info->VerticalResolution / 2, 0);
  }
  Print (L"W10M-QEMU-BOOTTEST: done\r\n");
  for (;;) { gBS->Stall (1000000); }
  return EFI_SUCCESS;
}
