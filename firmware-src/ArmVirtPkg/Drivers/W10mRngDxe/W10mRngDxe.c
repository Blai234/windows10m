/** @file
  A minimal EFI_RNG_PROTOCOL for running Windows 10 Mobile under QEMU.

  Windows 10 Mobile's mobilestartup.efi builds the device identifier from
  EFI_RNG_PROTOCOL and resets the machine if the protocol is absent. The
  Windows-on-ARM QEMU firmware does not otherwise provide one. This driver
  installs a protocol backed by an xorshift generator perturbed by the
  architectural performance counter. It is NOT cryptographically secure and
  is only meant to let the Windows boot path proceed under emulation.

  SPDX-License-Identifier: BSD-2-Clause-Patent
**/

#include <Uefi.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/TimerLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Protocol/Rng.h>

STATIC UINT64  mState = 0x9E3779B97F4A7C15ULL;

STATIC
UINT64
NextRandom (
  VOID
  )
{
  UINT64  x;

  mState ^= GetPerformanceCounter ();
  x = mState;
  if (x == 0) {
    x = 0x9E3779B97F4A7C15ULL;
  }
  x ^= x >> 12;
  x ^= x << 25;
  x ^= x >> 27;
  mState = x;
  return x * 0x2545F4914F6CDD1DULL;
}

/**
  Returns the list of supported RNG algorithms (just the "raw" algorithm).
**/
EFI_STATUS
EFIAPI
RngGetInfo (
  IN     EFI_RNG_PROTOCOL   *This,
  IN OUT UINTN              *RNGAlgorithmListSize,
  OUT    EFI_RNG_ALGORITHM  *RNGAlgorithmList
  )
{
  if ((This == NULL) || (RNGAlgorithmListSize == NULL)) {
    return EFI_INVALID_PARAMETER;
  }
  if (*RNGAlgorithmListSize < sizeof (EFI_RNG_ALGORITHM)) {
    *RNGAlgorithmListSize = sizeof (EFI_RNG_ALGORITHM);
    return EFI_BUFFER_TOO_SMALL;
  }
  if (RNGAlgorithmList == NULL) {
    return EFI_INVALID_PARAMETER;
  }
  *RNGAlgorithmListSize = sizeof (EFI_RNG_ALGORITHM);
  CopyGuid (&RNGAlgorithmList[0], &gEfiRngAlgorithmRaw);
  return EFI_SUCCESS;
}

/**
  Fills RNGValue with RNGValueLength pseudo-random bytes.
**/
EFI_STATUS
EFIAPI
RngGetRNG (
  IN  EFI_RNG_PROTOCOL   *This,
  IN  EFI_RNG_ALGORITHM  *RNGAlgorithm  OPTIONAL,
  IN  UINTN              RNGValueLength,
  OUT UINT8              *RNGValue
  )
{
  UINT64  r;
  UINTN   n;

  if ((This == NULL) || (RNGValueLength == 0) || (RNGValue == NULL)) {
    return EFI_INVALID_PARAMETER;
  }

  while (RNGValueLength > 0) {
    r = NextRandom ();
    n = (RNGValueLength < sizeof (r)) ? RNGValueLength : sizeof (r);
    CopyMem (RNGValue, &r, n);
    RNGValue        += n;
    RNGValueLength  -= n;
  }
  return EFI_SUCCESS;
}

STATIC EFI_RNG_PROTOCOL  mRng = {
  RngGetInfo,
  RngGetRNG
};

EFI_STATUS
EFIAPI
W10mRngEntry (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_HANDLE  Handle;
  EFI_TIME    Time;

  if (!EFI_ERROR (gRT->GetTime (&Time, NULL))) {
    mState ^= ((UINT64)Time.Nanosecond << 32) ^ ((UINT64)Time.Second << 20) ^
              ((UINT64)Time.Minute << 12) ^ ((UINT64)Time.Hour << 6) ^ Time.Day;
  }
  mState ^= GetPerformanceCounter ();

  Handle = NULL;
  return gBS->InstallMultipleProtocolInterfaces (
                &Handle,
                &gEfiRngProtocolGuid, &mRng,
                NULL
                );
}
