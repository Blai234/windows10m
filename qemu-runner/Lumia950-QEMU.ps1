<#
.SYNOPSIS
    Boots a Lumia 950 (RM-1104) Windows 10 Mobile retail FFU in QEMU.

.DESCRIPTION
    Self-contained: everything it needs goes into its own "work" folder next to
    this script. Nothing else on the PC is read or changed, apart from the FFU
    you point it at (opened read-only).

      1. Downloads pinned, hash-checked tools from GitHub/NuGet:
           - QEMU 6.2 with driver1998's Windows-on-ARM patches (binarymaster build:
             platform SDHCI + EHCI on the "virt" board, no PCI in ACPI)
           - 7zr.exe (to unpack it), DiscUtils 0.16.13 (to edit FAT/NTFS offline)
      2. Converts the FFU into a 32 GiB sparse raw disk (QEMU's SD card model
         needs a power-of-two size), placing every block exactly where a phone
         flasher would, and moves the backup GPT to the new end of the disk.
      3. Applies offline fixes (registry and one boot-file copy; no signed
         binary is modified):
           - EFI\BOOT\BOOTARM.EFI on EFIESP so the firmware boots the SD card
           - ROOT\BasicDisplay devnode so Windows drives the QEMU framebuffer
           - UIX resolution pinned to 1440x2560, the only asset set in the image
           - LaunchAppSvc no longer depends on StorageSvc
      4. Starts QEMU with UEFI firmware rebuilt to start in a single 1440x2560
         portrait mode (QEMU_EFI_W10M_1440x2560.fd, shipped next to this script).
         The stock firmware starts at 800x600, which made Windows 10 Mobile look
         for 480x800 resources this image does not contain.

    The first boot is slow under TCG emulation (single core): allow 10-30 min,
    and expect the phone's first-boot provisioning to reboot it a few times.

.PARAMETER Ffu
    Path to RM1104_1078.0017.10586.13053.15482.02FAFD_retail_prod_signed.ffu.
    If omitted, the script looks next to itself, then asks with a file picker.

.PARAMETER Rebuild
    Recreate the disk image from the FFU (a fresh, never-booted phone).

.PARAMETER Snapshot
    Run with a throw-away overlay: nothing the guest writes is kept.

.PARAMETER NoLaunch
    Prepare tools and the disk image, then stop without starting QEMU.

.EXAMPLE
    .\Lumia950-QEMU.ps1 -Ffu "D:\firmware\RM1104_1078.0017.10586.13053.15482.02FAFD_retail_prod_signed.ffu"
#>
[CmdletBinding()]
param(
    [string]$Ffu,
    [string]$WorkDir,
    [switch]$Rebuild,
    [switch]$Snapshot,
    [switch]$NoLaunch,
    [ValidateRange(512, 3072)][int]$MemoryMB = 2048,
    [ValidateSet('gtk', 'sdl')][string]$Display = 'gtk',
    [int]$QmpPort = 49552,
    [switch]$StockFirmware,
    [switch]$SkipFixes,
    [string]$DiscUtilsDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ScriptVersion = '1.0'

# ---------------------------------------------------------------- pinned inputs
$Pinned = @{
    QemuUrl        = 'https://github.com/binarymaster/qemu/releases/download/v6.2.0-winrt-v3/qemu-6.2.0-winrt-emu-v3.7z'
    QemuSha256     = '0AA650FC14935005EAA2836CE1F4EC879940B56B5B8D54E71E5EC78B0BA897F5'
    SevenZipUrl    = 'https://github.com/ip7z/7zip/releases/download/25.01/7zr.exe'
    SevenZipSha256 = '27CBE3D5804AD09E90BBCAA916DA0D5C3B0BE9462D0E0FB6CB54BE5ED9030875'
    StockFwUrl     = 'https://github.com/binarymaster/qemu/releases/download/v6.2.0-winrt-v3/QEMU_EFI_1512_driver1998.fd'
    StockFwSha256  = '99FE27785B9BC7ADC48B60DEED42BD3C7B8003DBF11F28F409CF4AB44E9AFCB4'
    FirmwareName   = 'QEMU_EFI_W10M_1440x2560.fd'
    FirmwareSha256 = '648E308ACA65BDBB8DC84970B17E9DF42EFBF1AA763E51E668E4A89EDB112640'
    DiscUtilsVer   = '0.16.13'
    DiscUtilsPkgs  = @('DiscUtils.Streams', 'DiscUtils.Core', 'DiscUtils.Ntfs', 'DiscUtils.Fat')
    DiscUtilsToken = '5fa5b410cc9c6289'
}

function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note([string]$Text) { Write-Host "    $Text" }
function Write-Warn([string]$Text) { Write-Host "    WARNING: $Text" -ForegroundColor Yellow }

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-PinnedFile([string]$Url, [string]$Dest, [string]$Sha256) {
    if ((Test-Path -LiteralPath $Dest) -and (Get-Sha256 $Dest) -eq $Sha256) { return }
    $tmp = "$Dest.part"
    Write-Note "downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
    $got = Get-Sha256 $tmp
    if ($got -ne $Sha256) {
        Remove-Item -LiteralPath $tmp -Force
        throw "Hash mismatch for $Url`n  expected $Sha256`n  got      $got"
    }
    Move-Item -LiteralPath $tmp -Destination $Dest -Force
}

function ConvertTo-QemuValue([string]$Text) { return $Text.Replace(',', ',,') }

function Invoke-Main {
    # ------------------------------------------------------------------- setup ---
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This script runs on Windows (it drives the Windows build of QEMU).' }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows is required (the patched QEMU is an x64 build).' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $Here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    if (-not $WorkDir) { $WorkDir = Join-Path $Here 'work' }
    $Tools = Join-Path $WorkDir 'tools'
    $null = New-Item -ItemType Directory -Force -Path $WorkDir, $Tools
    $LogFile = Join-Path $WorkDir ('session-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    try { Start-Transcript -LiteralPath $LogFile -Force | Out-Null } catch { }

    try {
        Write-Host "Lumia 950 (RM-1104) Windows 10 Mobile in QEMU - script v$ScriptVersion"
        Write-Note "work folder: $WorkDir"

        # ---- the FFU (read-only input) ------------------------------------------
        $StateFile = Join-Path $WorkDir 'RM1104-sdcard.json'
        if (-not $Ffu -and (Test-Path -LiteralPath $StateFile)) {
            try {
                $prev = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
                if ($prev.FfuPath -and (Test-Path -LiteralPath $prev.FfuPath -PathType Leaf)) { $Ffu = $prev.FfuPath }
            } catch { }
        }
        if (-not $Ffu) {
            $candidates = @(Get-ChildItem -LiteralPath $Here -Filter '*.ffu' -File -ErrorAction SilentlyContinue)
            if ($candidates.Count -eq 1) { $Ffu = $candidates[0].FullName }
        }
        if (-not $Ffu) {
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $dlg = New-Object System.Windows.Forms.OpenFileDialog
                $dlg.Title = 'Select the Lumia 950 (RM-1104) FFU'
                $dlg.Filter = 'Full Flash Update (*.ffu)|*.ffu|All files (*.*)|*.*'
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $Ffu = $dlg.FileName }
            } catch { }
        }
        if (-not $Ffu) { $Ffu = Read-Host 'Full path of the RM1104 .ffu file' }
        $Ffu = $Ffu.Trim('"', ' ')
        if (-not (Test-Path -LiteralPath $Ffu -PathType Leaf)) { throw "FFU not found: $Ffu" }
        $FfuItem = Get-Item -LiteralPath $Ffu
        Write-Note ("FFU: {0} ({1:N2} GB)" -f $FfuItem.FullName, ($FfuItem.Length / 1GB))
        if ($FfuItem.Name -notmatch 'RM-?1104') { Write-Warn 'This does not look like an RM-1104 (Lumia 950) FFU. The firmware and fixes assume a 1440x2560 Lumia 950 image.' }

        $drive = $null
        try { $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $WorkDir).Path)) } catch { }
        if ($drive) {
            if ($drive.DriveFormat -ne 'NTFS') { Write-Warn "The work folder is on $($drive.DriveFormat), not NTFS: the 32 GiB image cannot be sparse there." }
            $needBytes = [long]($FfuItem.Length * 1.2) + 1GB
            if ($drive.AvailableFreeSpace -lt $needBytes) {
                throw ("Not enough free space on {0}: need about {1:N1} GB, have {2:N1} GB." -f $drive.Name, ($needBytes / 1GB), ($drive.AvailableFreeSpace / 1GB))
            }
        }

        # ---- tools ---------------------------------------------------------------
        Write-Step 'Tools'
        $SevenZip = Join-Path $Tools '7zr.exe'
        Get-PinnedFile $Pinned.SevenZipUrl $SevenZip $Pinned.SevenZipSha256

        $QemuDir = Join-Path $Tools 'qemu-6.2.0-winrt-v3'
        $QemuExe = Join-Path $QemuDir 'qemu-system-arm.exe'
        if (-not (Test-Path -LiteralPath $QemuExe)) {
            $archive = Join-Path $Tools 'qemu-6.2.0-winrt-emu-v3.7z'
            Get-PinnedFile $Pinned.QemuUrl $archive $Pinned.QemuSha256
            Write-Note 'unpacking QEMU'
            $null = New-Item -ItemType Directory -Force -Path $QemuDir
            $ErrorActionPreference = 'Continue'
            & $SevenZip x -y "-o$QemuDir" $archive | Out-Null
            $ErrorActionPreference = 'Stop'
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $QemuExe)) { throw "7zr failed to unpack $archive (exit $LASTEXITCODE)" }
            Remove-Item -LiteralPath $archive -Force
        }
        Write-Note "QEMU: $QemuExe"

        if ($StockFirmware) {
            $Firmware = Join-Path $Tools 'QEMU_EFI_1512_driver1998.fd'
            Get-PinnedFile $Pinned.StockFwUrl $Firmware $Pinned.StockFwSha256
            Write-Warn 'Stock firmware starts at 800x600: Windows 10 Mobile will look for 480x800 assets.'
        } else {
            $Firmware = Join-Path $Here $Pinned.FirmwareName
            if (-not (Test-Path -LiteralPath $Firmware)) { $Firmware = Join-Path (Join-Path $Here 'firmware') $Pinned.FirmwareName }
            if (-not (Test-Path -LiteralPath $Firmware)) { throw "$($Pinned.FirmwareName) must sit next to this script (or in a 'firmware' folder beside it)." }
            if ((Get-Sha256 $Firmware) -ne $Pinned.FirmwareSha256) { throw "$Firmware does not match the expected SHA-256 ($($Pinned.FirmwareSha256))." }
        }
        Write-Note "firmware: $Firmware"

        # ---- disk image ----------------------------------------------------------
        $Image = Join-Path $WorkDir 'RM1104-sdcard.img'
        $fingerprint = '{0}|{1}|{2}|{3}' -f $FfuItem.Name, $FfuItem.Length, $FfuItem.LastWriteTimeUtc.Ticks, $ScriptVersion
        $state = $null
        if ((Test-Path -LiteralPath $StateFile) -and (Test-Path -LiteralPath $Image)) {
            try { $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { $state = $null }
        }
        if ($state -and $state.Fingerprint -ne $fingerprint) { Write-Note 'the FFU or script changed since the image was built; rebuilding'; $state = $null }
        if ($Rebuild) { $state = $null }

        if (-not $state) {
            Write-Step 'Loading the converter'
            if (-not ('LumiaQemu.FfuConverter' -as [type])) {
                $refs = @()
                if (-not $SkipFixes) {
                    $tfm = if ($PSVersionTable.PSEdition -eq 'Core') { 'netstandard2.0' } else { 'net45' }
                    if (-not $DiscUtilsDir) { $DiscUtilsDir = Join-Path $Tools "discutils-$($Pinned.DiscUtilsVer)-$tfm" }
                    $null = New-Item -ItemType Directory -Force -Path $DiscUtilsDir
                    foreach ($pkg in $Pinned.DiscUtilsPkgs) {
                        $dll = Join-Path $DiscUtilsDir "$pkg.dll"
                        if (-not (Test-Path -LiteralPath $dll)) {
                            $nupkg = Join-Path $Tools "$pkg.$($Pinned.DiscUtilsVer).nupkg"
                            Write-Note "downloading $pkg $($Pinned.DiscUtilsVer) from nuget.org"
                            Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/$pkg/$($Pinned.DiscUtilsVer)" -OutFile $nupkg -UseBasicParsing
                            Add-Type -AssemblyName System.IO.Compression.FileSystem
                            $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
                            try {
                                $entry = $zip.Entries | Where-Object { $_.FullName -eq "lib/$tfm/$pkg.dll" } | Select-Object -First 1
                                if (-not $entry) { throw "lib/$tfm/$pkg.dll not found in $nupkg" }
                                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dll, $true)
                            } finally { $zip.Dispose() }
                            Remove-Item -LiteralPath $nupkg -Force
                        }
                        $refs += $dll
                    }
                    foreach ($dll in $refs) {
                        $an = [Reflection.AssemblyName]::GetAssemblyName($dll)
                        $token = -join ($an.GetPublicKeyToken() | ForEach-Object { $_.ToString('x2') })
                        if ($token -ne $Pinned.DiscUtilsToken) { throw "$dll is not signed with the DiscUtils key (token $token, expected $($Pinned.DiscUtilsToken))." }
                        $null = [Reflection.Assembly]::LoadFrom($dll)
                    }
                }
                $source = $CSharpSource
                if ($SkipFixes) {
                    # Drop the DiscUtils-based fixer so the converter compiles on its own.
                    $source = $source.Substring(0, $source.IndexOf('    // -------------------------------------------------------------- patcher --')) + "}`n"
                }
                if ($refs.Count -gt 0) {
                    $compileRefs = @($refs)
                    if ($PSVersionTable.PSEdition -eq 'Core') {
                        # PowerShell 7 drops its default reference set once any reference is given.
                        $compileRefs += @('netstandard', 'System.Runtime', 'System.Collections', 'System.Console',
                                          'System.Runtime.InteropServices', 'System.Text.Encoding.Extensions')
                    }
                    Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies $compileRefs
                } else {
                    Add-Type -TypeDefinition $source -Language CSharp
                }
            }

            Write-Step 'Converting the FFU (read-only) into a sparse 32 GiB SD card image'
            $conv = [LumiaQemu.FfuConverter]::Convert($FfuItem.FullName, $Image, 32GB)
            foreach ($p in $conv.Partitions) {
                if ($p.Name -in @('EFIESP', 'MainOS', 'Data', 'UEFI', 'PLAT')) {
                    Write-Note ("{0,-8} {1,8:N0} MiB at LBA {2}" -f $p.Name, ($p.SizeBytes / 1MB), $p.FirstLba)
                }
            }

            $rtc = '2016-11-01'
            if (-not $SkipFixes) {
                Write-Step 'Applying offline fixes'
                $opt = New-Object LumiaQemu.PatchOptions
                $res = [LumiaQemu.ImagePatcher]::Patch($Image, $opt)
                $rtc = $res.RtcBase
            }
            $buildLog = Join-Path $WorkDir 'image-build.txt'
            [LumiaQemu.Log]::Text.ToString() | Set-Content -LiteralPath $buildLog -Encoding UTF8
            Write-Note "build report: $buildLog"
            $state = [pscustomobject]@{ Fingerprint = $fingerprint; FfuPath = $FfuItem.FullName; Rtc = $rtc; Built = (Get-Date).ToString('s') }
            $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
            Write-Note "image ready: $Image"
        } else {
            Write-Step 'Reusing the existing disk image (use -Rebuild for a fresh first boot)'
            Write-Note $Image
        }

        if ($NoLaunch) { Write-Note 'NoLaunch given: not starting QEMU.'; return }

        # ---- QEMU ----------------------------------------------------------------
        Write-Step 'Starting QEMU'
        $serial = Join-Path $WorkDir ('serial-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
        $driveArg = "id=phone,if=sd,format=raw,cache=writeback,file=$(ConvertTo-QemuValue $Image)"
        if ($Snapshot) { $driveArg += ',snapshot=on' }
        $displayArg = if ($Display -eq 'gtk') { 'gtk,zoom-to-fit=on' } else { 'sdl' }
        $qargs = @(
            '-name', 'Lumia 950 (RM-1104) - Windows 10 Mobile',
            '-M', 'virt,highmem=off',
            '-cpu', 'cortex-a15', '-smp', '1', '-m', "$MemoryMB",
            '-accel', 'tcg,thread=multi',
            '-bios', $Firmware,
            '-device', 'VGA',
            '-device', 'usb-kbd,id=kbd', '-device', 'usb-tablet,id=mice',
            '-nic', 'none',
            '-drive', $driveArg,
            '-rtc', "base=$($state.Rtc),clock=vm",
            '-serial', "file:$(ConvertTo-QemuValue $serial)",
            '-display', $displayArg
        )
        if ($QmpPort -gt 0) {
            # QEMU refuses to start if the port is taken (e.g. by an older QEMU still running).
            $free = $true
            try { $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $QmpPort); $probe.Start(); $probe.Stop() } catch { $free = $false }
            if ($free) { $qargs += @('-qmp', "tcp:127.0.0.1:$QmpPort,server=on,wait=off") }
            else { Write-Warn "port $QmpPort is in use, starting without the QMP socket (is another QEMU still running?)" }
        }
        Write-Note ('"{0}" {1}' -f $QemuExe, (($qargs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '))
        Write-Note 'Expect the UEFI screen, then the Windows logo. The first boot takes a long time and may reboot itself.'
        Write-Note 'If input stops responding: View > compatmonitor0, then  device_del kbd / device_add usb-kbd,id=kbd'
        $ErrorActionPreference = 'Continue'
        & $QemuExe @qargs
        $code = $LASTEXITCODE
        Write-Note "QEMU exited with code $code. UEFI serial output: $serial"
        if ($code -ne 0) { exit $code }
    }
    catch {
        Write-Host ''
        Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
        Write-Host "Log: $LogFile"
        exit 1
    }
    finally {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

# --------------------------------------------------------------- C# source --
$CSharpSource = @'
// LumiaQemu.cs -- FFU -> raw disk converter and offline image fixer for running a
// Lumia 950 (RM-1104) Windows 10 Mobile FFU in the Windows-RT-patched QEMU.
//
// Written for C# 5 so Windows PowerShell 5.1 can compile it with Add-Type.
// The converter and the registry editor have no dependencies; the fixer uses
// DiscUtils 0.16.13 only to read and write files inside the FAT/NTFS partitions.

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace LumiaQemu
{
    public static class Log
    {
        public static readonly StringBuilder Text = new StringBuilder();

        public static void Line(string format, params object[] args)
        {
            string s = (args == null || args.Length == 0) ? format : String.Format(format, args);
            Console.WriteLine(s);
            Text.AppendLine(s);
        }
    }

    // ------------------------------------------------------------------ GPT --

    public class GptPartition
    {
        public int Index;
        public string Name;
        public Guid TypeGuid;
        public Guid UniqueGuid;
        public long FirstLba;
        public long LastLba;
        public long SizeBytes { get { return (LastLba - FirstLba + 1) * 512L; } }
    }

    public class GptHeader
    {
        public long MyLba;
        public long AlternateLba;
        public long FirstUsableLba;
        public long LastUsableLba;
        public Guid DiskGuid;
        public long EntriesLba;
        public uint EntryCount;
        public uint EntrySize;
        public uint HeaderSize;
        public uint EntriesCrc;

        public long EntriesSectors { get { return (EntryCount * (long)EntrySize + 511) / 512; } }

        public static GptHeader Parse(byte[] sector, int offset)
        {
            if (Encoding.ASCII.GetString(sector, offset, 8) != "EFI PART") return null;
            GptHeader h = new GptHeader();
            h.HeaderSize = BitConverter.ToUInt32(sector, offset + 12);
            h.MyLba = BitConverter.ToInt64(sector, offset + 24);
            h.AlternateLba = BitConverter.ToInt64(sector, offset + 32);
            h.FirstUsableLba = BitConverter.ToInt64(sector, offset + 40);
            h.LastUsableLba = BitConverter.ToInt64(sector, offset + 48);
            byte[] g = new byte[16];
            Array.Copy(sector, offset + 56, g, 0, 16);
            h.DiskGuid = new Guid(g);
            h.EntriesLba = BitConverter.ToInt64(sector, offset + 72);
            h.EntryCount = BitConverter.ToUInt32(sector, offset + 80);
            h.EntrySize = BitConverter.ToUInt32(sector, offset + 84);
            h.EntriesCrc = BitConverter.ToUInt32(sector, offset + 88);
            if (h.HeaderSize < 92 || h.HeaderSize > 512 || h.EntrySize < 128 || h.EntryCount == 0 || h.EntryCount > 4096) return null;
            return h;
        }

        public static List<GptPartition> ParseEntries(byte[] entries, uint count, uint size)
        {
            List<GptPartition> list = new List<GptPartition>();
            for (int i = 0; i < count; i++)
            {
                int o = (int)(i * size);
                if (o + 128 > entries.Length) break;
                byte[] t = new byte[16];
                Array.Copy(entries, o, t, 0, 16);
                Guid type = new Guid(t);
                if (type == Guid.Empty) continue;
                byte[] u = new byte[16];
                Array.Copy(entries, o + 16, u, 0, 16);
                GptPartition p = new GptPartition();
                p.Index = i + 1;
                p.TypeGuid = type;
                p.UniqueGuid = new Guid(u);
                p.FirstLba = BitConverter.ToInt64(entries, o + 32);
                p.LastLba = BitConverter.ToInt64(entries, o + 40);
                p.Name = Encoding.Unicode.GetString(entries, o + 56, 72).TrimEnd('\0');
                list.Add(p);
            }
            return list;
        }
    }

    public static class Crc32
    {
        private static uint[] _table;

        public static uint Compute(byte[] data, int offset, int count)
        {
            if (_table == null)
            {
                uint[] t = new uint[256];
                for (uint i = 0; i < 256; i++)
                {
                    uint c = i;
                    for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
                    t[i] = c;
                }
                _table = t;
            }
            uint crc = 0xFFFFFFFFu;
            for (int i = offset; i < offset + count; i++) crc = _table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
            return crc ^ 0xFFFFFFFFu;
        }
    }

    // ------------------------------------------------------------------ FFU --

    public class FfuWrite
    {
        public uint BlockCount;
        public uint[] Methods;   // 0 = from disk start, 2 = from disk end
        public uint[] Indexes;
        public long FirstPayloadBlock;
    }

    public class FfuFile
    {
        public string Path;
        public uint ChunkSize;
        public uint BlockSize;
        public ushort StoreMajor;
        public ushort StoreMinor;
        public ushort FullFlashMajor;
        public ushort FullFlashMinor;
        public string PlatformId;
        public string Manifest;
        public long PayloadStart;
        public long PayloadBlocks;
        public List<FfuWrite> Writes = new List<FfuWrite>();

        private static long Align(long value, long unit)
        {
            long r = value % unit;
            return r == 0 ? value : value + (unit - r);
        }

        private static byte[] ReadAt(FileStream fs, long offset, int count)
        {
            byte[] b = new byte[count];
            fs.Position = offset;
            int got = 0;
            while (got < count)
            {
                int n = fs.Read(b, got, count - got);
                if (n <= 0) throw new EndOfStreamException("Unexpected end of FFU at offset " + (offset + got));
                got += n;
            }
            return b;
        }

        public static FfuFile Open(string path)
        {
            FfuFile f = new FfuFile();
            f.Path = path;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                long length = fs.Length;

                // SECURITY_HEADER
                byte[] sh = ReadAt(fs, 0, 32);
                if (Encoding.ASCII.GetString(sh, 4, 12) != "SignedImage ")
                    throw new InvalidDataException("Not an FFU: missing 'SignedImage ' signature.");
                uint secSize = BitConverter.ToUInt32(sh, 0);
                uint chunkKb = BitConverter.ToUInt32(sh, 16);
                uint catalogSize = BitConverter.ToUInt32(sh, 24);
                uint hashTableSize = BitConverter.ToUInt32(sh, 28);
                if (chunkKb == 0 || chunkKb > 65536) throw new InvalidDataException("Bad FFU chunk size.");
                f.ChunkSize = chunkKb * 1024;

                // IMAGE_HEADER (after the catalog and hash table, chunk aligned)
                long pos = Align(secSize + (long)catalogSize + hashTableSize, f.ChunkSize);
                byte[] ih = ReadAt(fs, pos, 24);
                if (Encoding.ASCII.GetString(ih, 4, 12) != "ImageFlash  ")
                    throw new InvalidDataException("FFU image header not found at 0x" + pos.ToString("X"));
                uint imgHdrSize = BitConverter.ToUInt32(ih, 0);
                uint manifestLen = BitConverter.ToUInt32(ih, 16);
                f.Manifest = Encoding.ASCII.GetString(ReadAt(fs, pos + imgHdrSize, (int)Math.Min(manifestLen, 1 << 20)));

                // STORE_HEADER
                pos = Align(pos + imgHdrSize + manifestLen, f.ChunkSize);
                byte[] st = ReadAt(fs, pos, 248);
                f.StoreMajor = BitConverter.ToUInt16(st, 4);
                f.StoreMinor = BitConverter.ToUInt16(st, 6);
                f.FullFlashMajor = BitConverter.ToUInt16(st, 8);
                f.FullFlashMinor = BitConverter.ToUInt16(st, 10);
                f.PlatformId = Encoding.ASCII.GetString(st, 12, 192).TrimEnd('\0');
                f.BlockSize = BitConverter.ToUInt32(st, 204);
                uint writeCount = BitConverter.ToUInt32(st, 208);
                uint writeLen = BitConverter.ToUInt32(st, 212);
                uint validateLen = BitConverter.ToUInt32(st, 220);
                long storeHeaderSize = 248;
                if (f.StoreMajor >= 2)
                {
                    byte[] ext = ReadAt(fs, pos + 248, 14);
                    ushort numStores = BitConverter.ToUInt16(ext, 0);
                    ushort devPathLen = BitConverter.ToUInt16(ext, 12);
                    if (numStores > 1)
                        throw new NotSupportedException("Multi-store FFU (v2, " + numStores + " stores) is not supported; this script expects a phone FFU.");
                    storeHeaderSize = 248 + 14 + devPathLen * 2L;
                }
                if (f.BlockSize == 0 || f.BlockSize % 512 != 0 || f.BlockSize > (64 << 20))
                    throw new InvalidDataException("Bad FFU block size " + f.BlockSize);
                if (writeLen > (256 << 20) || validateLen > (256 << 20))
                    throw new InvalidDataException("FFU descriptor tables are implausibly large.");

                // The descriptor tables follow the store header directly. Some tools align
                // them to 16 bytes, so try that too and keep whichever parses cleanly and
                // accounts for the whole file.
                long[] starts = { pos + storeHeaderSize, Align(pos + storeHeaderSize, 16) };
                List<FfuWrite> best = null;
                long bestPayload = 0, bestStart = 0;
                foreach (long start in starts)
                {
                    long writePos = start + validateLen;
                    List<FfuWrite> list;
                    long blocks;
                    if (!TryParseWrites(fs, writePos, writeCount, writeLen, out list, out blocks)) continue;
                    long payloadStart = Align(writePos + writeLen, f.ChunkSize);
                    long end = payloadStart + blocks * (long)f.BlockSize;
                    if (end > length) continue;
                    if (best == null || end == length)
                    {
                        best = list; bestPayload = blocks; bestStart = payloadStart;
                        if (end == length) break;
                    }
                }
                if (best == null) throw new InvalidDataException("Could not parse the FFU write descriptors (unknown layout or truncated file).");
                f.Writes = best;
                long payloadBlock = bestPayload;
                f.PayloadStart = bestStart;
                f.PayloadBlocks = payloadBlock;
            }
            return f;
        }

        private static bool TryParseWrites(FileStream fs, long writePos, uint writeCount, uint writeLen, out List<FfuWrite> list, out long blocks)
        {
            list = new List<FfuWrite>();
            blocks = 0;
            if (writePos + writeLen > fs.Length) return false;
            byte[] wd = ReadAt(fs, writePos, (int)writeLen);
            int o = 0;
            for (uint i = 0; i < writeCount; i++)
            {
                if (o + 8 > wd.Length) return false;
                uint locCount = BitConverter.ToUInt32(wd, o);
                uint blockCount = BitConverter.ToUInt32(wd, o + 4);
                o += 8;
                if (locCount == 0 || locCount > 1024 || blockCount == 0 || o + locCount * 8 > wd.Length) return false;
                FfuWrite w = new FfuWrite();
                w.BlockCount = blockCount;
                w.Methods = new uint[locCount];
                w.Indexes = new uint[locCount];
                for (int j = 0; j < locCount; j++)
                {
                    w.Methods[j] = BitConverter.ToUInt32(wd, o);
                    w.Indexes[j] = BitConverter.ToUInt32(wd, o + 4);
                    if (w.Methods[j] != 0 && w.Methods[j] != 2) return false;
                    o += 8;
                }
                w.FirstPayloadBlock = blocks;
                blocks += blockCount;
                list.Add(w);
            }
            return o <= wd.Length;
        }

        public long PayloadOffset(long payloadBlock)
        {
            return PayloadStart + payloadBlock * (long)BlockSize;
        }

        // Returns the payload block that ends up at disk block 0 (the final GPT).
        public long FinalGptPayloadBlock()
        {
            long found = -1;
            foreach (FfuWrite w in Writes)
            {
                for (int j = 0; j < w.Methods.Length; j++)
                {
                    if (w.Methods[j] == 0 && w.Indexes[j] == 0) found = w.FirstPayloadBlock;
                }
            }
            return found;
        }
    }

    public class ConvertResult
    {
        public long DiskBytes;
        public long PayloadBytes;
        public long BytesWritten;
        public List<GptPartition> Partitions = new List<GptPartition>();
        public bool BackupGptRebuilt;
    }

    public static class FfuConverter
    {
        private const uint FSCTL_SET_SPARSE = 0x000900C4;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle hDevice, uint dwIoControlCode, IntPtr lpInBuffer, uint nInBufferSize,
            IntPtr lpOutBuffer, uint nOutBufferSize, out uint lpBytesReturned, IntPtr lpOverlapped);

        private static bool IsWindows
        {
            get { return Environment.OSVersion.Platform == PlatformID.Win32NT; }
        }

        private static bool AllZero(byte[] b, int count)
        {
            int i = 0;
            for (; i + 8 <= count; i += 8) if (BitConverter.ToInt64(b, i) != 0) return false;
            for (; i < count; i++) if (b[i] != 0) return false;
            return true;
        }

        private static long NextPow2(long v)
        {
            long p = 1;
            while (p < v) p <<= 1;
            return p;
        }

        // Converts the FFU into a sparse raw disk image whose size is a power of two
        // (QEMU's SD card model requires that) and at least minDiskBytes.
        public static ConvertResult Convert(string ffuPath, string imagePath, long minDiskBytes)
        {
            ConvertResult result = new ConvertResult();
            FfuFile ffu = FfuFile.Open(ffuPath);
            Log.Line("FFU: store v{0}.{1}, full-flash v{2}.{3}, platform '{4}', block {5} KiB, {6} write descriptors, {7} payload blocks",
                ffu.StoreMajor, ffu.StoreMinor, ffu.FullFlashMajor, ffu.FullFlashMinor, ffu.PlatformId, ffu.BlockSize / 1024, ffu.Writes.Count, ffu.PayloadBlocks);

            using (FileStream src = new FileStream(ffuPath, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, FileOptions.SequentialScan))
            {
                // 1. Look at the final GPT to size the virtual disk.
                long gptBlock = ffu.FinalGptPayloadBlock();
                if (gptBlock < 0) throw new InvalidDataException("The FFU never writes disk block 0, so it has no GPT.");
                byte[] gptBuf = new byte[ffu.BlockSize];
                src.Position = ffu.PayloadOffset(gptBlock);
                ReadFull(src, gptBuf, (int)ffu.BlockSize);
                GptHeader hdr = GptHeader.Parse(gptBuf, 512);
                if (hdr == null) throw new InvalidDataException("The FFU's first disk block does not contain a GPT header.");
                long entriesBytes = hdr.EntryCount * (long)hdr.EntrySize;
                byte[] entries = new byte[entriesBytes];
                if (hdr.EntriesLba * 512 + entriesBytes <= ffu.BlockSize)
                    Array.Copy(gptBuf, hdr.EntriesLba * 512, entries, 0, entriesBytes);
                else
                    throw new InvalidDataException("GPT entries do not fit in the first FFU block.");
                List<GptPartition> parts = GptHeader.ParseEntries(entries, hdr.EntryCount, hdr.EntrySize);
                long neededLbas = hdr.LastUsableLba + 1 + hdr.EntriesSectors + 1;
                foreach (GptPartition p in parts) neededLbas = Math.Max(neededLbas, p.LastLba + 1 + hdr.EntriesSectors + 1);
                long maxBegin = 0;
                foreach (FfuWrite w in ffu.Writes)
                    for (int j = 0; j < w.Methods.Length; j++)
                        if (w.Methods[j] == 0) maxBegin = Math.Max(maxBegin, ((long)w.Indexes[j] + w.BlockCount) * ffu.BlockSize);
                long needed = Math.Max(neededLbas * 512, maxBegin);
                long diskBytes = NextPow2(Math.Max(needed, minDiskBytes));
                result.DiskBytes = diskBytes;
                Log.Line("GPT: {0} partitions, image needs {1:F2} GiB -> virtual SD card {2} GiB", parts.Count, needed / 1073741824.0, diskBytes >> 30);

                // 2. Create the sparse image.
                if (File.Exists(imagePath)) File.Delete(imagePath);
                using (FileStream dst = new FileStream(imagePath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 1 << 16))
                {
                    if (IsWindows)
                    {
                        uint ret;
                        if (!DeviceIoControl(dst.SafeFileHandle, FSCTL_SET_SPARSE, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero))
                            Log.Line("warning: could not mark the image sparse (error {0}); it will use the full {1} GiB on disk.", Marshal.GetLastWin32Error(), diskBytes >> 30);
                    }
                    dst.SetLength(diskBytes);

                    long totalBlocks = diskBytes / ffu.BlockSize;
                    bool[] written = new bool[totalBlocks];
                    byte[] buf = new byte[ffu.BlockSize];
                    src.Position = ffu.PayloadStart;
                    long done = 0;
                    int lastPct = -1;
                    foreach (FfuWrite w in ffu.Writes)
                    {
                        for (uint b = 0; b < w.BlockCount; b++)
                        {
                            ReadFull(src, buf, (int)ffu.BlockSize);
                            bool zero = AllZero(buf, (int)ffu.BlockSize);
                            for (int j = 0; j < w.Methods.Length; j++)
                            {
                                long diskBlock;
                                if (w.Methods[j] == 0) diskBlock = (long)w.Indexes[j] + b;
                                else if (w.Methods[j] == 2) diskBlock = totalBlocks - 1 - ((long)w.Indexes[j] + b);
                                else throw new InvalidDataException("Unsupported FFU disk access method " + w.Methods[j]);
                                if (diskBlock < 0 || diskBlock >= totalBlocks) throw new InvalidDataException("FFU block outside the disk: " + diskBlock);
                                if (zero && !written[diskBlock]) continue;   // sparse regions already read as zero
                                dst.Position = diskBlock * ffu.BlockSize;
                                dst.Write(buf, 0, (int)ffu.BlockSize);
                                written[diskBlock] = true;
                                result.BytesWritten += ffu.BlockSize;
                            }
                            done++;
                            int pct = (int)(done * 100 / Math.Max(1, ffu.PayloadBlocks));
                            if (pct != lastPct && pct % 5 == 0) { Console.WriteLine("  converting FFU... {0,3}%", pct); lastPct = pct; }
                        }
                    }
                    result.PayloadBytes = done * ffu.BlockSize;
                    dst.Flush();

                    // 3. Make the GPT describe this disk exactly like a flashed phone would.
                    result.BackupGptRebuilt = FixGpt(dst, diskBytes);
                    result.Partitions = ReadPartitions(dst);
                }
            }
            Log.Line("Image written: {0:F2} GiB of data in a {1} GiB sparse file{2}", result.BytesWritten / 1073741824.0, result.DiskBytes >> 30,
                result.BackupGptRebuilt ? " (backup GPT relocated to the end of the disk)" : "");
            return result;
        }

        private static void ReadFull(Stream s, byte[] buf, int count)
        {
            int got = 0;
            while (got < count)
            {
                int n = s.Read(buf, got, count - got);
                if (n <= 0) throw new EndOfStreamException("Unexpected end of FFU payload.");
                got += n;
            }
        }

        private static byte[] ReadAt(Stream s, long offset, int count)
        {
            byte[] b = new byte[count];
            s.Position = offset;
            ReadFull(s, b, count);
            return b;
        }

        public static List<GptPartition> ReadPartitions(Stream disk)
        {
            byte[] lba1 = ReadAt(disk, 512, 512);
            GptHeader h = GptHeader.Parse(lba1, 0);
            if (h == null) throw new InvalidDataException("No GPT in the converted image.");
            byte[] entries = ReadAt(disk, h.EntriesLba * 512, (int)(h.EntryCount * h.EntrySize));
            return GptHeader.ParseEntries(entries, h.EntryCount, h.EntrySize);
        }

        // Points the primary GPT's backup copy at the real last LBA and writes a valid
        // backup there. Returns true if anything had to change.
        public static bool FixGpt(Stream disk, long diskBytes)
        {
            long lastLba = diskBytes / 512 - 1;
            byte[] primary = ReadAt(disk, 512, 512);
            GptHeader h = GptHeader.Parse(primary, 0);
            if (h == null) throw new InvalidDataException("No primary GPT header at LBA 1.");
            byte[] check = (byte[])primary.Clone();
            uint storedCrc = BitConverter.ToUInt32(check, 16);
            Array.Clear(check, 16, 4);
            if (Crc32.Compute(check, 0, (int)h.HeaderSize) != storedCrc)
                throw new InvalidDataException("Primary GPT header CRC mismatch: the FFU conversion produced a corrupt table.");
            int entriesBytes = (int)(h.EntryCount * h.EntrySize);
            byte[] entries = ReadAt(disk, h.EntriesLba * 512, entriesBytes);
            if (Crc32.Compute(entries, 0, entriesBytes) != h.EntriesCrc)
                throw new InvalidDataException("GPT partition array CRC mismatch: the FFU conversion produced a corrupt table.");

            long backupEntriesLba = lastLba - h.EntriesSectors;
            bool changed = false;
            if (h.AlternateLba != lastLba || h.LastUsableLba > backupEntriesLba - 1)
            {
                Log.Line("GPT: backup header moved from LBA {0} to {1} (disk is {2} sectors)", h.AlternateLba, lastLba, lastLba + 1);
                WriteInt64(primary, 32, lastLba);
                // Like flashing onto a bigger eMMC: the usable area now reaches the new end.
                WriteInt64(primary, 48, backupEntriesLba - 1);
                SetHeaderCrc(primary, (int)h.HeaderSize);
                disk.Position = 512;
                disk.Write(primary, 0, 512);
                changed = true;
            }

            // Backup = same entries + header with swapped LBAs.
            byte[] backup = (byte[])primary.Clone();
            WriteInt64(backup, 24, lastLba);
            WriteInt64(backup, 32, 1);
            WriteInt64(backup, 72, backupEntriesLba);
            SetHeaderCrc(backup, (int)h.HeaderSize);
            byte[] existing = ReadAt(disk, lastLba * 512, 512);
            byte[] existingEntries = ReadAt(disk, backupEntriesLba * 512, entriesBytes);
            if (!BytesEqual(existing, backup) || !BytesEqual(existingEntries, entries))
            {
                disk.Position = backupEntriesLba * 512;
                disk.Write(entries, 0, entriesBytes);
                disk.Position = lastLba * 512;
                disk.Write(backup, 0, 512);
                changed = true;
            }

            // Protective MBR size field.
            byte[] mbr = ReadAt(disk, 0, 512);
            if (mbr[510] == 0x55 && mbr[511] == 0xAA && mbr[446 + 4] == 0xEE)
            {
                uint want = (uint)Math.Min(lastLba, 0xFFFFFFFFL);
                if (BitConverter.ToUInt32(mbr, 446 + 12) != want)
                {
                    Array.Copy(BitConverter.GetBytes(want), 0, mbr, 446 + 12, 4);
                    disk.Position = 0;
                    disk.Write(mbr, 0, 512);
                }
            }
            disk.Flush();
            return changed;
        }

        private static void WriteInt64(byte[] b, int offset, long v)
        {
            Array.Copy(BitConverter.GetBytes(v), 0, b, offset, 8);
        }

        private static void SetHeaderCrc(byte[] header, int size)
        {
            Array.Clear(header, 16, 4);
            uint crc = Crc32.Compute(header, 0, size);
            Array.Copy(BitConverter.GetBytes(crc), 0, header, 16, 4);
        }

        private static bool BytesEqual(byte[] a, byte[] b)
        {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
        }
    }

    // ----------------------------------------------------------------- regf --
    // A small offline registry hive editor. It only does what the fixes need
    // (open keys, create keys, read and set small values) and never re-encodes
    // security descriptors: new keys share their parent's "sk" cell and only its
    // reference count changes, exactly as Windows does for inherited security.

    public sealed class RegHive
    {
        public const int BinStart = 0x1000;
        private byte[] _d;
        private int _length;          // size of all hbins
        private readonly int _root;
        private readonly long _stamp; // FILETIME used for keys we touch
        private readonly int _minor;
        private readonly int _fileLength;

        public RegHive(byte[] file, DateTime stampUtc)
        {
            _fileLength = file.Length;
            if (file.Length < BinStart + 0x1000 || Encoding.ASCII.GetString(file, 0, 4) != "regf")
                throw new InvalidDataException("Not a registry hive (no 'regf' signature).");
            _d = file;
            int seq1 = I32(4), seq2 = I32(8);
            if (seq1 != seq2) throw new InvalidDataException("Hive is dirty (sequence numbers differ); refusing to edit it offline.");
            _minor = I32(24);
            _root = I32(36);
            _length = I32(40);
            if (_length <= 0 || BinStart + (long)_length > file.Length) throw new InvalidDataException("Hive length field is out of range.");
            if (Encoding.ASCII.GetString(_d, BinStart, 4) != "hbin") throw new InvalidDataException("First hive bin is missing.");
            _stamp = stampUtc.ToFileTimeUtc();
        }

        public RegKey Root { get { return new RegKey(this, _root); } }

        public byte[] ToArray()
        {
            int seq = I32(4) + 1;
            W32(4, seq);
            W32(8, seq);
            Array.Copy(BitConverter.GetBytes(_stamp), 0, _d, 12, 8);
            W32(40, _length);
            uint sum = 0;
            for (int i = 0; i < 508; i += 4) sum ^= BitConverter.ToUInt32(_d, i);
            if (sum == 0) sum = 1;
            if (sum == 0xFFFFFFFF) sum = 0xFFFFFFFE;
            Array.Copy(BitConverter.GetBytes(sum), 0, _d, 508, 4);
            // Keep any preallocated slack the original file had after its bins.
            byte[] r = new byte[Math.Max(_fileLength, BinStart + _length)];
            Array.Copy(_d, r, Math.Min(_d.Length, r.Length));
            return r;
        }

        // --- raw access (cell offsets are relative to the first hbin) ---------
        internal int I32(int pos) { return BitConverter.ToInt32(_d, pos); }
        internal int U16(int pos) { return BitConverter.ToUInt16(_d, pos); }
        internal void W32(int pos, int v) { Array.Copy(BitConverter.GetBytes(v), 0, _d, pos, 4); }
        internal void W16(int pos, int v) { _d[pos] = (byte)v; _d[pos + 1] = (byte)(v >> 8); }
        internal int Data(int cell) { return BinStart + cell + 4; }       // file position of a cell's payload
        internal string Sig(int cell) { return Encoding.ASCII.GetString(_d, Data(cell), 2); }
        internal byte[] Bytes { get { return _d; } }
        internal long Stamp { get { return _stamp; } }
        internal int Minor { get { return _minor; } }

        internal void CheckCell(int cell)
        {
            if (cell < 0 || cell + 8 > _length) throw new InvalidDataException("Hive cell offset 0x" + cell.ToString("X") + " is out of range.");
            if (I32(BinStart + cell) >= 0) throw new InvalidDataException("Hive cell 0x" + cell.ToString("X") + " is not allocated.");
        }

        internal int CellSize(int cell) { return -I32(BinStart + cell); }

        internal int Alloc(int payload)
        {
            int need = (payload + 4 + 7) & ~7;
            int pos = BinStart;
            int end = BinStart + _length;
            while (pos < end)
            {
                if (Encoding.ASCII.GetString(_d, pos, 4) != "hbin") throw new InvalidDataException("Corrupt hive bin at 0x" + pos.ToString("X"));
                int binSize = I32(pos + 8);
                int c = pos + 32;
                int binEnd = pos + binSize;
                while (c < binEnd)
                {
                    int size = I32(c);
                    if (size == 0) break;
                    int abs = Math.Abs(size);
                    if (size > 0 && size >= need)
                    {
                        if (size - need >= 16)
                        {
                            W32(c, -need);
                            W32(c + need, size - need);
                        }
                        else
                        {
                            W32(c, -size);
                        }
                        Array.Clear(_d, c + 4, need - 4);
                        return c - BinStart;
                    }
                    c += abs;
                }
                pos = binEnd;
            }
            // No room: append a bin.
            int newBin = (need + 32 + 0xFFF) & ~0xFFF;
            int binPos = BinStart + _length;
            if (_d.Length < binPos + newBin)
            {
                byte[] grown = new byte[Math.Max(binPos + newBin, _d.Length + (_d.Length >> 3))];
                Array.Copy(_d, grown, _d.Length);
                _d = grown;
            }
            Array.Clear(_d, binPos, newBin);
            Encoding.ASCII.GetBytes("hbin").CopyTo(_d, binPos);
            W32(binPos + 4, _length);
            W32(binPos + 8, newBin);
            Array.Copy(BitConverter.GetBytes(_stamp), 0, _d, binPos + 20, 8);
            W32(binPos + 32, -need);
            if (newBin - 32 - need > 0) W32(binPos + 32 + need, newBin - 32 - need);
            _length += newBin;
            return binPos + 32 - BinStart;
        }

        internal void Free(int cell)
        {
            if (cell < 0 || cell >= _length) return;
            int size = I32(BinStart + cell);
            if (size < 0) W32(BinStart + cell, -size);
        }

        internal static bool IsAscii(string s)
        {
            foreach (char ch in s) if (ch < 0x20 || ch > 0x7E) return false;
            return true;
        }

        internal static int CompareNames(string a, string b)
        {
            return String.CompareOrdinal(a.ToUpperInvariant(), b.ToUpperInvariant());
        }

        internal static uint LhHash(string name)
        {
            uint h = 0;
            foreach (char ch in name.ToUpperInvariant()) h = unchecked(h * 37 + ch);
            return h;
        }
    }

    public sealed class RegKey
    {
        private readonly RegHive _h;
        private readonly int _cell;

        internal RegKey(RegHive hive, int cell)
        {
            hive.CheckCell(cell);
            if (hive.Sig(cell) != "nk") throw new InvalidDataException("Hive cell 0x" + cell.ToString("X") + " is not a key node.");
            _h = hive;
            _cell = cell;
        }

        private int P { get { return _h.Data(_cell); } }   // payload position
        private int Flags { get { return _h.U16(P + 2); } }
        private int NumSubKeys { get { return _h.I32(P + 0x14); } }
        private int SubKeyList { get { return _h.I32(P + 0x1C); } }
        private int NumValues { get { return _h.I32(P + 0x24); } }
        private int ValueList { get { return _h.I32(P + 0x28); } }
        private int Security { get { return _h.I32(P + 0x2C); } }

        public string Name
        {
            get
            {
                int len = _h.U16(P + 0x48);
                return (Flags & 0x20) != 0 ? Encoding.GetEncoding(28591).GetString(_h.Bytes, P + 0x4C, len)
                                           : Encoding.Unicode.GetString(_h.Bytes, P + 0x4C, len);
            }
        }

        private void Touch()
        {
            Array.Copy(BitConverter.GetBytes(_h.Stamp), 0, _h.Bytes, P + 4, 8);
        }

        // ---- subkeys ---------------------------------------------------------
        private void CollectSubKeys(int list, List<int> into)
        {
            if (list == -1) return;
            _h.CheckCell(list);
            string sig = _h.Sig(list);
            int p = _h.Data(list);
            int count = _h.U16(p + 2);
            if (sig == "lf" || sig == "lh")
                for (int i = 0; i < count; i++) into.Add(_h.I32(p + 4 + i * 8));
            else if (sig == "li")
                for (int i = 0; i < count; i++) into.Add(_h.I32(p + 4 + i * 4));
            else if (sig == "ri")
                for (int i = 0; i < count; i++) CollectSubKeys(_h.I32(p + 4 + i * 4), into);
            else
                throw new InvalidDataException("Unknown subkey list type '" + sig + "'");
        }

        public string[] GetSubKeyNames()
        {
            List<int> cells = new List<int>();
            if (NumSubKeys > 0) CollectSubKeys(SubKeyList, cells);
            List<string> names = new List<string>();
            foreach (int c in cells) names.Add(new RegKey(_h, c).Name);
            return names.ToArray();
        }

        private RegKey Child(string name)
        {
            if (NumSubKeys == 0) return null;
            List<int> cells = new List<int>();
            CollectSubKeys(SubKeyList, cells);
            foreach (int c in cells)
            {
                RegKey k = new RegKey(_h, c);
                if (RegHive.CompareNames(k.Name, name) == 0) return k;
            }
            return null;
        }

        public RegKey OpenSubKey(string path)
        {
            RegKey k = this;
            foreach (string part in path.Split(new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
            {
                k = k.Child(part);
                if (k == null) return null;
            }
            return k;
        }

        public RegKey CreateSubKey(string path)
        {
            RegKey k = this;
            foreach (string part in path.Split(new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
            {
                RegKey c = k.Child(part);
                k = c ?? k.AddChild(part);
            }
            return k;
        }

        private RegKey AddChild(string name)
        {
            if (name.Length == 0 || name.Length > 255) throw new ArgumentException("Bad key name '" + name + "'");
            bool ascii = RegHive.IsAscii(name);
            byte[] nameBytes = ascii ? Encoding.ASCII.GetBytes(name) : Encoding.Unicode.GetBytes(name);

            int cell = _h.Alloc(0x4C + nameBytes.Length);
            int p = _h.Data(cell);
            byte[] d = _h.Bytes;
            d[p] = (byte)'n'; d[p + 1] = (byte)'k';
            _h.W16(p + 2, ascii ? 0x20 : 0);
            Array.Copy(BitConverter.GetBytes(_h.Stamp), 0, d, p + 4, 8);
            _h.W32(p + 0x10, _cell);
            _h.W32(p + 0x1C, -1);
            _h.W32(p + 0x20, -1);
            _h.W32(p + 0x28, -1);
            _h.W32(p + 0x30, -1);
            _h.W16(p + 0x48, nameBytes.Length);
            Array.Copy(nameBytes, 0, d, p + 0x4C, nameBytes.Length);

            // Inherit the parent's security cell (bump its reference count only).
            int sk = Security;
            _h.W32(p + 0x2C, sk);
            if (sk != -1)
            {
                _h.CheckCell(sk);
                if (_h.Sig(sk) != "sk") throw new InvalidDataException("Parent security cell is not an 'sk' cell.");
                int sp = _h.Data(sk);
                _h.W32(sp + 0x0C, _h.I32(sp + 0x0C) + 1);
            }

            InsertIntoList(cell, name);
            // Re-read P: the hive buffer may have been reallocated by Alloc.
            int pp = P;
            _h.W32(pp + 0x14, NumSubKeys + 1);
            int maxName = _h.I32(pp + 0x34);
            int nameLen16 = name.Length * 2;
            if ((maxName & 0xFFFF) < nameLen16) _h.W32(pp + 0x34, (int)((maxName & 0xFFFF0000) | (uint)nameLen16));
            Touch();
            return new RegKey(_h, cell);
        }

        private int BuildLeaf(string sig, List<int> cells)
        {
            int entry = sig == "li" ? 4 : 8;
            int leaf = _h.Alloc(4 + cells.Count * entry);
            int p = _h.Data(leaf);
            byte[] d = _h.Bytes;
            d[p] = (byte)sig[0]; d[p + 1] = (byte)sig[1];
            _h.W16(p + 2, cells.Count);
            for (int i = 0; i < cells.Count; i++)
            {
                _h.W32(p + 4 + i * entry, cells[i]);
                if (entry == 8)
                {
                    string n = new RegKey(_h, cells[i]).Name;
                    if (sig == "lh")
                    {
                        _h.W32(p + 8 + i * 8, unchecked((int)RegHive.LhHash(n)));
                    }
                    else
                    {
                        byte[] hint = new byte[4];
                        for (int k = 0; k < 4 && k < n.Length; k++) hint[k] = (byte)(n[k] < 0x80 ? n[k] : 0);
                        Array.Copy(hint, 0, d, p + 8 + i * 8, 4);
                    }
                }
            }
            return leaf;
        }

        private List<int> LeafCells(int leaf)
        {
            List<int> cells = new List<int>();
            CollectSubKeys(leaf, cells);
            return cells;
        }

        private int InsertSorted(List<int> cells, int newCell, string name)
        {
            int at = cells.Count;
            for (int i = 0; i < cells.Count; i++)
            {
                if (RegHive.CompareNames(name, new RegKey(_h, cells[i]).Name) < 0) { at = i; break; }
            }
            cells.Insert(at, newCell);
            return at;
        }

        private void InsertIntoList(int newCell, string name)
        {
            int list = NumSubKeys > 0 ? SubKeyList : -1;
            if (list == -1)
            {
                List<int> one = new List<int>();
                one.Add(newCell);
                int leaf = BuildLeaf("lh", one);
                _h.W32(P + 0x1C, leaf);
                return;
            }
            string sig = _h.Sig(list);
            if (sig == "lf" || sig == "lh" || sig == "li")
            {
                List<int> cells = LeafCells(list);
                InsertSorted(cells, newCell, name);
                int leaf = BuildLeaf(sig, cells);
                _h.Free(list);
                _h.W32(P + 0x1C, leaf);
                return;
            }
            if (sig != "ri") throw new InvalidDataException("Unknown subkey list type '" + sig + "'");

            // Index root: insert into the leaf whose range covers the name.
            int rp = _h.Data(list);
            int leaves = _h.U16(rp + 2);
            int target = leaves - 1;
            for (int i = 0; i < leaves; i++)
            {
                List<int> lc = LeafCells(_h.I32(rp + 4 + i * 4));
                if (lc.Count > 0 && RegHive.CompareNames(name, new RegKey(_h, lc[lc.Count - 1]).Name) <= 0) { target = i; break; }
            }
            int oldLeaf = _h.I32(rp + 4 + target * 4);
            string leafSig = _h.Sig(oldLeaf);
            List<int> tc = LeafCells(oldLeaf);
            InsertSorted(tc, newCell, name);
            int newLeaf = BuildLeaf(leafSig, tc);
            _h.Free(oldLeaf);
            _h.W32(_h.Data(list) + 4 + target * 4, newLeaf);
        }

        // ---- values ----------------------------------------------------------
        private int FindValue(string name, out int index)
        {
            index = -1;
            if (NumValues == 0 || ValueList == -1) return -1;
            int lp = _h.Data(ValueList);
            for (int i = 0; i < NumValues; i++)
            {
                int vk = _h.I32(lp + i * 4);
                _h.CheckCell(vk);
                int vp = _h.Data(vk);
                if (_h.Sig(vk) != "vk") continue;
                int nlen = _h.U16(vp + 2);
                int flags = _h.U16(vp + 0x10);
                string vname = (flags & 1) != 0 ? Encoding.GetEncoding(28591).GetString(_h.Bytes, vp + 0x14, nlen)
                                                : Encoding.Unicode.GetString(_h.Bytes, vp + 0x14, nlen);
                if (RegHive.CompareNames(vname, name) == 0) { index = i; return vk; }
            }
            return -1;
        }

        public int GetValueType(string name)
        {
            int idx;
            int vk = FindValue(name, out idx);
            return vk == -1 ? -1 : _h.I32(_h.Data(vk) + 0x0C);
        }

        public byte[] GetValueBytes(string name)
        {
            int idx;
            int vk = FindValue(name, out idx);
            if (vk == -1) return null;
            int vp = _h.Data(vk);
            uint len = (uint)_h.I32(vp + 4);
            if ((len & 0x80000000u) != 0)
            {
                int n = (int)(len & 0x7FFFFFFF);
                byte[] inl = new byte[Math.Min(n, 4)];
                Array.Copy(_h.Bytes, vp + 8, inl, 0, inl.Length);
                return inl;
            }
            int dataCell = _h.I32(vp + 8);
            _h.CheckCell(dataCell);
            if (len > 16344 && _h.Minor >= 4 && _h.Sig(dataCell) == "db")
            {
                int dp = _h.Data(dataCell);
                int segs = _h.U16(dp + 2);
                int segList = _h.Data(_h.I32(dp + 4));
                byte[] big = new byte[len];
                int got = 0;
                for (int i = 0; i < segs && got < len; i++)
                {
                    int seg = _h.I32(segList + i * 4);
                    int take = (int)Math.Min(16344, len - got);
                    Array.Copy(_h.Bytes, _h.Data(seg), big, got, take);
                    got += take;
                }
                return big;
            }
            byte[] r = new byte[len];
            Array.Copy(_h.Bytes, _h.Data(dataCell), r, 0, (int)len);
            return r;
        }

        // DWORD -> int, SZ/EXPAND_SZ -> string, MULTI_SZ -> string[], else byte[].
        public object GetValue(string name)
        {
            byte[] b = GetValueBytes(name);
            if (b == null) return null;
            int type = GetValueType(name);
            if (type == 4 && b.Length >= 4) return BitConverter.ToInt32(b, 0);
            if (type == 1 || type == 2) return Encoding.Unicode.GetString(b).TrimEnd('\0');
            if (type == 7)
            {
                string all = Encoding.Unicode.GetString(b);
                List<string> parts = new List<string>();
                foreach (string s in all.Split('\0')) if (s.Length > 0) parts.Add(s);
                return parts.ToArray();
            }
            return b;
        }

        public void SetDword(string name, int value) { SetValue(name, 4, BitConverter.GetBytes(value)); }

        public void SetString(string name, string value) { SetValue(name, 1, Encoding.Unicode.GetBytes(value + "\0")); }

        public void SetMultiString(string name, string[] values)
        {
            StringBuilder sb = new StringBuilder();
            foreach (string v in values) { sb.Append(v); sb.Append('\0'); }
            sb.Append('\0');
            SetValue(name, 7, Encoding.Unicode.GetBytes(sb.ToString()));
        }

        public void SetValue(string name, int type, byte[] data)
        {
            if (data.Length > 16344) throw new NotSupportedException("Values larger than 16 KiB are not supported.");
            int idx;
            int vk = FindValue(name, out idx);
            if (vk == -1)
            {
                bool ascii = RegHive.IsAscii(name);
                byte[] nb = ascii ? Encoding.ASCII.GetBytes(name) : Encoding.Unicode.GetBytes(name);
                vk = _h.Alloc(0x14 + nb.Length);
                int vp0 = _h.Data(vk);
                _h.Bytes[vp0] = (byte)'v'; _h.Bytes[vp0 + 1] = (byte)'k';
                _h.W16(vp0 + 2, nb.Length);
                _h.W32(vp0 + 4, unchecked((int)0x80000000));
                _h.W16(vp0 + 0x10, ascii ? 1 : 0);
                Array.Copy(nb, 0, _h.Bytes, vp0 + 0x14, nb.Length);

                int count = NumValues;
                int newList = _h.Alloc((count + 1) * 4);
                if (count > 0 && ValueList != -1)
                {
                    Array.Copy(_h.Bytes, _h.Data(ValueList), _h.Bytes, _h.Data(newList), count * 4);
                    _h.Free(ValueList);
                }
                _h.W32(_h.Data(newList) + count * 4, vk);
                _h.W32(P + 0x28, newList);
                _h.W32(P + 0x24, count + 1);
                int nl = name.Length * 2;
                if (_h.I32(P + 0x3C) < nl) _h.W32(P + 0x3C, nl);
            }
            else
            {
                int vp1 = _h.Data(vk);
                uint oldLen = (uint)_h.I32(vp1 + 4);
                if ((oldLen & 0x80000000u) == 0 && oldLen > 0)
                {
                    int oldData = _h.I32(vp1 + 8);
                    if (oldLen > 16344 && _h.Minor >= 4 && _h.Sig(oldData) == "db") { /* leave big-data segments alone */ }
                    _h.Free(oldData);
                }
            }

            int dataCell = -1;
            if (data.Length > 4) dataCell = _h.Alloc(data.Length);
            int vp = _h.Data(vk);
            _h.W32(vp + 0x0C, type);
            if (data.Length <= 4)
            {
                _h.W32(vp + 4, unchecked((int)(0x80000000u | (uint)data.Length)));
                byte[] inl = new byte[4];
                Array.Copy(data, inl, data.Length);
                Array.Copy(inl, 0, _h.Bytes, vp + 8, 4);
            }
            else
            {
                Array.Copy(data, 0, _h.Bytes, _h.Data(dataCell), data.Length);
                _h.W32(vp + 4, data.Length);
                _h.W32(vp + 8, dataCell);
            }
            if (_h.I32(P + 0x40) < data.Length) _h.W32(P + 0x40, data.Length);
            Touch();
        }
    }

    // -------------------------------------------------------------- patcher --
    // Offline fixes applied to the converted image. Nothing here edits a signed
    // binary: only registry values and one copy of the boot manager change.

    public class PatchOptions
    {
        public bool AddBootArmEfi = true;
        public bool BasicDisplayDevnode = true;
        public bool UixResolutionOverride = true;
        public int ScreenWidth = 1440;
        public int ScreenHeight = 2560;
        public bool DropStorageSvcDependency = true;
    }

    public class PatchResult
    {
        public List<string> Changes = new List<string>();
        public List<string> Warnings = new List<string>();
        public List<string> Facts = new List<string>();
        public DateTime ImageTimeUtc = DateTime.MinValue;

        public string RtcBase
        {
            get
            {
                DateTime t = ImageTimeUtc;
                if (t.Year < 2015 || t.Year > 2019) t = new DateTime(2016, 11, 1);
                return t.AddDays(1).ToString("yyyy-MM-dd");
            }
        }
    }

    public static class ImagePatcher
    {
        private const string SystemClassGuid = "{4d36e97d-e325-11ce-bfc1-08002be10318}";
        private const string SystemHive = @"Windows\System32\config\SYSTEM";
        private const string SoftwareHive = @"Windows\System32\config\SOFTWARE";

        public static PatchResult Patch(string imagePath, PatchOptions opt)
        {
            PatchResult r = new PatchResult();
            using (DiscUtils.Raw.Disk disk = new DiscUtils.Raw.Disk(imagePath, FileAccess.ReadWrite))
            {
                DiscUtils.Partitions.GuidPartitionTable gpt = new DiscUtils.Partitions.GuidPartitionTable(disk);
                DiscUtils.Partitions.GuidPartitionInfo esp = Find(gpt, "EFIESP");
                DiscUtils.Partitions.GuidPartitionInfo mainOs = Find(gpt, "MainOS");
                DiscUtils.Partitions.GuidPartitionInfo data = Find(gpt, "Data");
                if (esp == null) throw new InvalidDataException("No EFIESP partition in the image. Is this a Windows 10 Mobile FFU?");
                if (mainOs == null) throw new InvalidDataException("No MainOS partition in the image. Is this a Windows 10 Mobile FFU?");
                if (data == null) r.Warnings.Add("No 'Data' partition found; user data and apps live there on a real phone.");

                PatchEsp(esp, opt, r);
                PatchMainOs(mainOs, opt, r);
            }
            foreach (string c in r.Changes) Log.Line("  changed: {0}", c);
            foreach (string f in r.Facts) Log.Line("  found:   {0}", f);
            foreach (string w in r.Warnings) Log.Line("  WARNING: {0}", w);
            return r;
        }

        private static DiscUtils.Partitions.GuidPartitionInfo Find(DiscUtils.Partitions.GuidPartitionTable gpt, string name)
        {
            foreach (DiscUtils.Partitions.PartitionInfo p in gpt.Partitions)
            {
                DiscUtils.Partitions.GuidPartitionInfo g = p as DiscUtils.Partitions.GuidPartitionInfo;
                if (g != null && String.Equals((g.Name ?? "").Trim('\0', ' '), name, StringComparison.OrdinalIgnoreCase)) return g;
            }
            return null;
        }

        private static void CopyStream(Stream src, Stream dst)
        {
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = src.Read(buf, 0, buf.Length)) > 0) dst.Write(buf, 0, n);
        }

        // ---- EFIESP (FAT) ----------------------------------------------------
        private static void PatchEsp(DiscUtils.Partitions.GuidPartitionInfo esp, PatchOptions opt, PatchResult r)
        {
            using (Stream s = esp.Open())
            using (DiscUtils.Fat.FatFileSystem fat = new DiscUtils.Fat.FatFileSystem(s))
            {
                // DiscUtils' FAT code only sees 8.3 names (EFI\MICROS~1\...), so find the
                // Windows boot manager by walking EFI\* instead of using the long path.
                string bootmgr = null;
                string bcd = null;
                if (fat.DirectoryExists("EFI"))
                {
                    foreach (string d in fat.GetDirectories("EFI"))
                    {
                        string dir = d.TrimStart('\\');
                        if (fat.FileExists(dir + @"\BOOT\BOOTMGFW.EFI"))
                        {
                            bootmgr = dir + @"\BOOT\BOOTMGFW.EFI";
                            if (fat.FileExists(dir + @"\BOOT\BCD")) bcd = dir + @"\BOOT\BCD";
                            break;
                        }
                    }
                }
                if (bootmgr == null)
                {
                    // The Windows boot manager binary may sit under a long-named
                    // path DiscUtils' FAT view doesn't match (Windows\Boot\EFI\
                    // bootmgfw.efi). What the firmware actually boots is
                    // EFI\BOOT\BOOTARM.EFI; if that is present, all is well.
                    if (fat.FileExists(@"EFI\BOOT\BOOTARM.EFI"))
                        r.Facts.Add(@"EFIESP: EFI\BOOT\BOOTARM.EFI present (the firmware boots this directly)");
                    else
                        r.Warnings.Add(@"EFIESP has no EFI\BOOT\BOOTARM.EFI and no bootmgfw.efi to copy; the firmware may not find Windows.");
                    return;
                }
                r.Facts.Add("EFIESP: Windows Boot Manager at " + bootmgr + (bcd != null ? ", BCD present" : ", BCD MISSING"));

                const string fallback = @"EFI\BOOT\BOOTARM.EFI";
                if (fat.FileExists(fallback))
                {
                    r.Facts.Add(@"EFIESP: EFI\BOOT\BOOTARM.EFI already present");
                    return;
                }
                if (!opt.AddBootArmEfi) return;
                if (!fat.DirectoryExists(@"EFI\BOOT")) fat.CreateDirectory(@"EFI\BOOT");
                using (Stream src = fat.OpenFile(bootmgr, FileMode.Open, FileAccess.Read))
                using (Stream dst = fat.OpenFile(fallback, FileMode.Create, FileAccess.ReadWrite))
                {
                    CopyStream(src, dst);
                }
                r.Changes.Add(@"EFIESP: copied the boot manager to EFI\BOOT\BOOTARM.EFI so the firmware boots the SD card on its own");
            }
        }

        // ---- MainOS (NTFS + registry) ----------------------------------------
        private static void PatchMainOs(DiscUtils.Partitions.GuidPartitionInfo mainOs, PatchOptions opt, PatchResult r)
        {
            using (Stream s = mainOs.Open())
            using (DiscUtils.Ntfs.NtfsFileSystem ntfs = new DiscUtils.Ntfs.NtfsFileSystem(s))
            {
                if (!ntfs.FileExists(SystemHive) || !ntfs.FileExists(SoftwareHive))
                    throw new InvalidDataException("MainOS has no SYSTEM/SOFTWARE hives; the image is not a Windows 10 Mobile MainOS.");

                DateTime sysTime = ntfs.GetLastWriteTimeUtc(SystemHive);
                DateTime swTime = ntfs.GetLastWriteTimeUtc(SoftwareHive);
                r.ImageTimeUtc = sysTime > swTime ? sysTime : swTime;
                r.Facts.Add("MainOS: hives last written " + r.ImageTimeUtc.ToString("yyyy-MM-dd") + "; the guest clock will start at " + r.RtcBase);

                string[] drivers = { "BasicDisplay.sys", "BasicRender.sys", "sdbus.sys", "sdstor.sys", "usbehci.sys", "usbport.sys", "usbxhci.sys", "usbhub.sys", "usbhub3.sys", "hidusb.sys", "kbdhid.sys", "mouhid.sys" };
                List<string> present = new List<string>();
                List<string> missing = new List<string>();
                foreach (string d in drivers)
                {
                    if (ntfs.FileExists(@"Windows\System32\drivers\" + d)) present.Add(d); else missing.Add(d);
                }
                r.Facts.Add("drivers present: " + String.Join(", ", present.ToArray()));
                if (missing.Count > 0) r.Facts.Add("drivers absent:  " + String.Join(", ", missing.ToArray()));
                if (!present.Contains("sdbus.sys") || !present.Contains("sdstor.sys"))
                    r.Warnings.Add("sdbus.sys/sdstor.sys missing: Windows will not find its boot disk on the emulated SD controller.");
                if (!present.Contains("usbehci.sys"))
                    r.Warnings.Add("usbehci.sys is not in this image and the emulated board's only USB controller is EHCI: expect no keyboard or mouse inside Windows.");

                DateTime stamp = r.ImageTimeUtc.Year >= 2015 ? r.ImageTimeUtc : new DateTime(2016, 11, 1);
                EditHive(ntfs, SystemHive, stamp, r.Warnings, delegate (RegHive hive) { PatchSystem(hive, opt, r, present.Contains("BasicDisplay.sys")); });
                if (opt.UixResolutionOverride)
                    EditHive(ntfs, SoftwareHive, stamp, r.Warnings, delegate (RegHive hive) { PatchSoftware(hive, opt, r); });
            }
        }

        private delegate void HiveAction(RegHive hive);

        private static void EditHive(DiscUtils.Ntfs.NtfsFileSystem ntfs, string path, DateTime stamp, List<string> warnings, HiveAction action)
        {
            DateTime written = ntfs.GetLastWriteTimeUtc(path);
            byte[] original;
            using (Stream hs = ntfs.OpenFile(path, FileMode.Open, FileAccess.Read))
            {
                original = new byte[hs.Length];
                int got = 0;
                while (got < original.Length)
                {
                    int n = hs.Read(original, got, original.Length - got);
                    if (n <= 0) throw new EndOfStreamException("Short read of " + path);
                    got += n;
                }
            }
            RegHive hive;
            try
            {
                hive = new RegHive((byte[])original.Clone(), stamp);
            }
            catch (InvalidDataException e)
            {
                warnings.Add(path + " was left unchanged: " + e.Message);
                return;
            }
            action(hive);
            byte[] updated = hive.ToArray();
            // Only write if something changed (ToArray always bumps the sequence numbers).
            RegHive check = new RegHive((byte[])updated.Clone(), stamp);
            if (check.Root == null) throw new InvalidDataException("Edited hive does not reopen.");
            using (Stream hs = ntfs.OpenFile(path, FileMode.Open, FileAccess.ReadWrite))
            {
                hs.SetLength(updated.Length);
                hs.Position = 0;
                hs.Write(updated, 0, updated.Length);
                hs.Flush();
            }
            ntfs.SetLastWriteTimeUtc(path, written);
        }

        private static string ControlSet(RegKey root)
        {
            int current = 1;
            RegKey select = root.OpenSubKey("Select");
            if (select != null)
            {
                object v = select.GetValue("Current");
                if (v is int && (int)v > 0) current = (int)v;
            }
            return String.Format("ControlSet{0:000}", current);
        }

        private static void PatchSystem(RegHive hive, PatchOptions opt, PatchResult r, bool haveBasicDisplaySys)
        {
            RegKey root = hive.Root;
            string csName = ControlSet(root);
            RegKey cs = root.OpenSubKey(csName);
            if (cs == null) throw new InvalidDataException("SYSTEM hive has no " + csName);

            if (opt.BasicDisplayDevnode) EnableBasicDisplay(cs, csName, r, haveBasicDisplaySys);
            if (opt.DropStorageSvcDependency) DropDependency(cs, "LaunchAppSvc", "StorageSvc", r);
        }

        // Windows 10 Mobile only ships a driver for the Lumia's own GPU. The QEMU
        // framebuffer needs "Microsoft Basic Display Driver" on a root-enumerated
        // devnode, which desktop Windows Setup creates and the phone image lacks.
        private static void EnableBasicDisplay(RegKey cs, string csName, PatchResult r, bool haveSys)
        {
            RegKey svc = cs.OpenSubKey(@"Services\BasicDisplay");
            if (svc == null || !haveSys)
            {
                r.Warnings.Add("BasicDisplay driver/service is not in this image: Windows will have no display driver for the QEMU framebuffer.");
                return;
            }
            object start = svc.GetValue("Start");
            if (start is int && (int)start == 4)
            {
                svc.SetDword("Start", 1);
                r.Changes.Add(csName + @"\Services\BasicDisplay: Start 4 (disabled) -> 1 (system), as on desktop Windows");
            }

            if (cs.OpenSubKey(@"Enum\Root\BasicDisplay\0000") != null)
            {
                r.Facts.Add(@"Enum\Root\BasicDisplay\0000 already exists");
                return;
            }

            RegKey classKey = cs.CreateSubKey(@"Control\Class\" + SystemClassGuid);
            int next = 0;
            foreach (string name in classKey.GetSubKeyNames())
            {
                int n;
                if (name.Length == 4 && Int32.TryParse(name, out n) && n >= next) next = n + 1;
            }
            string drvIndex = next.ToString("D4");

            // Match the image's own root devnode for BasicRender where it has one.
            RegKey render = cs.OpenSubKey(@"Enum\Root\BasicRender\0000");
            object caps = render != null ? render.GetValue("Capabilities") : null;
            object container = render != null ? render.GetValue("ContainerID") : null;

            // Same values desktop Windows 10 setup writes for ROOT\BASICDISPLAY\0000.
            RegKey drv = classKey.CreateSubKey(drvIndex);
            drv.SetString("DriverDesc", "Microsoft Basic Display Driver");
            drv.SetString("ProviderName", "Microsoft");
            drv.SetValue("DriverDateData", 3, new byte[] { 0x00, 0x80, 0x8c, 0xa3, 0xc5, 0x94, 0xc6, 0x01 });
            drv.SetString("DriverDate", "6-21-2006");
            drv.SetString("DriverVersion", "10.0.10586.0");
            drv.SetString("InfPath", "basicdisplay.inf");
            drv.SetString("InfSection", "MSBDD_Fallback");
            drv.SetString("MatchingDeviceId", "ROOT\\BasicDisplay");

            RegKey dev = cs.CreateSubKey(@"Enum\Root\BasicDisplay\0000");
            dev.SetMultiString("HardwareID", new string[] { "ROOT\\BasicDisplay" });
            dev.SetDword("ConfigFlags", 0);
            dev.SetDword("DeviceReported", 1);
            dev.SetString("Service", "BasicDisplay");
            dev.SetDword("Capabilities", caps is int ? (int)caps : 0);
            dev.SetString("ClassGUID", SystemClassGuid);
            dev.SetString("DeviceDesc", "@basicdisplay.inf,%msbddfallbackname%;Microsoft Basic Display Driver");
            dev.SetString("Driver", SystemClassGuid + "\\" + drvIndex);
            dev.SetString("Mfg", "@basicdisplay.inf,%std%;(Standard display types)");
            dev.SetString("ContainerID", container is string ? (string)container : "{00000000-0000-0000-FFFF-FFFFFFFFFFFF}");
            dev.CreateSubKey("Device Parameters");

            RegKey video = svc.CreateSubKey("Video");
            if (!(video.GetValue("Service") is string)) video.SetString("Service", "BasicDisplay");
            r.Changes.Add(csName + @"\Enum\Root\BasicDisplay\0000 created (driver key " + SystemClassGuid + "\\" + drvIndex + ") so Windows drives the QEMU framebuffer");
        }

        private static void DropDependency(RegKey cs, string service, string dependency, PatchResult r)
        {
            RegKey k = cs.OpenSubKey(@"Services\" + service);
            if (k == null) return;
            string[] deps = k.GetValue("DependOnService") as string[];
            if (deps == null) return;
            List<string> keep = new List<string>();
            bool found = false;
            foreach (string d in deps)
            {
                if (String.Equals(d, dependency, StringComparison.OrdinalIgnoreCase)) found = true;
                else if (d.Length > 0) keep.Add(d);
            }
            if (!found) return;
            k.SetMultiString("DependOnService", keep.ToArray());
            r.Changes.Add(service + " no longer waits for " + dependency + " (StorageSvc crashed on the emulated storage in earlier runs and blocked app launches)");
        }

        // uixmobile.dll picks the asset set (480x800 ... 1440x2560) from the measured
        // screen size. This image only ships the 1440x2560 set, so pin it as well.
        private static void PatchSoftware(RegHive hive, PatchOptions opt, PatchResult r)
        {
            RegKey uix = hive.Root.CreateSubKey(@"Microsoft\UIX");
            object w = uix.GetValue("ResolutionOverrideWidth");
            object h = uix.GetValue("ResolutionOverrideHeight");
            if (w is int && h is int && (int)w == opt.ScreenWidth && (int)h == opt.ScreenHeight)
            {
                r.Facts.Add(@"SOFTWARE\Microsoft\UIX resolution override already " + opt.ScreenWidth + "x" + opt.ScreenHeight);
                return;
            }
            uix.SetDword("ResolutionOverrideWidth", opt.ScreenWidth);
            uix.SetDword("ResolutionOverrideHeight", opt.ScreenHeight);
            r.Changes.Add(@"SOFTWARE\Microsoft\UIX ResolutionOverrideWidth/Height = " + opt.ScreenWidth + "x" + opt.ScreenHeight);
        }
    }
}
'@

Invoke-Main
