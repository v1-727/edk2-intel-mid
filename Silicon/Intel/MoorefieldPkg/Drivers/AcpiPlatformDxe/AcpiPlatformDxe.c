/** @file
  Moorefield (Silvermont / Z3580) platform ACPI table set.

  Builds FACS, FADT, MADT and MCFG in memory and installs them with the
  board DSDT, giving a hardware-reduced namespace enough for Windows to bring up
  the four cores and the MMIO devices the DSDT describes. Windows starts the APs
  itself with INIT/SIPI from the MADT; no firmware MP wake-up is involved.

  FACS and DSDT are installed before FADT. AcpiTableDxe patches the FADT
  FIRMWARE_CTRL and DSDT pointers itself, so they are left zero here.

  SPDX-License-Identifier: BSD-2-Clause-Patent
 **/

#include <Uefi.h>
#include <IndustryStandard/Acpi.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/DxeServicesLib.h>
#include <Library/IoLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/PcdLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiDriverEntryPoint.h>
#include <IndustryStandard/MemoryMappedConfigurationSpaceAccessTable.h>
#include <Protocol/AcpiTable.h>

// No ACPI fixed hardware here, so the PM1xxx/PM2/PMTimer/GPE blocks stay zero and
  // the FADT advertises HARDWARE_REDUCED_ACPI. WBINVD is set, not cleared: the bit
  // means "WBINVD works", so the OS may use it to flush caches at ExitBootServices.
#define MF_FADT_FLAGS  (EFI_ACPI_6_5_WBINVD | EFI_ACPI_6_5_SLP_BUTTON | \
                        EFI_ACPI_6_5_HW_REDUCED_ACPI | \
                        EFI_ACPI_6_5_LOW_POWER_S0_IDLE_CAPABLE)

// GFX is a fixed-mode linear framebuffer from GOP, so there is no legacy VGA
  // framebuffer to keep the OS away from. The CMOS RTC at I/O 0x70 is real on
  // Anniedale, as on Tangier, so it is not declared absent.
// There are no PCIe links on the SoC (every function is on the root bus), so
  // the OS must not try to manage ASPM; U-Boot's Tangier FADT sets this too.
#define MF_FADT_BOOT_ARCH_FLAGS  (EFI_ACPI_6_5_VGA_NOT_PRESENT | \
                                  EFI_ACPI_6_5_PCIE_ASPM_CONTROLS)

// Tablet-class part: no S3/S4 and no legacy cooling or docking model.
#define MF_PREFERRED_PM_PROFILE  EFI_ACPI_6_5_PM_PROFILE_TABLET

// Single I/O APIC, so no second GSI range to offset into.
#define MF_IO_APIC_ID  0x00

#define MF_OEM_ID  { 'I', 'N', 'T', 'E', 'L', ' ' }
#define MF_OEM_TABLE_ID  SIGNATURE_32 ('M', 'O', 'O', 'R')

// Four cores in two modules. The SFI CPUS table lists APIC IDs 0, 2, 4, 6 - the
  // odd ones are absent SMT siblings - so the IDs are not consecutive.
#define MF_CPU_COUNT  4

/**
  MADT with all four cores online. Mirrors the ACPI 6.5 APIC table layout
  directly, so the whole table is a single object.
**/
typedef struct {
  EFI_ACPI_DESCRIPTION_HEADER                   Header;
  UINT32                                        LocalApicAddress;
  UINT32                                        Flags;
  EFI_ACPI_6_5_PROCESSOR_LOCAL_APIC_STRUCTURE   LocalApic[MF_CPU_COUNT];
  EFI_ACPI_6_5_IO_APIC_STRUCTURE                IoApic;
} MOOREFIELD_MADT;

/**
  ACPI "MCFG" table, one allocation. Lets Linux use the ECAM window that the
  PCI0 root bridge in Dsdt.asl reserves through its PDRC device.
**/
#pragma pack(1)
typedef struct {
  EFI_ACPI_DESCRIPTION_HEADER                                                    Header;
  UINT64                                                                         Reserved;
  EFI_ACPI_MEMORY_MAPPED_ENHANCED_CONFIGURATION_SPACE_BASE_ADDRESS_ALLOCATION_STRUCTURE  Segment;
} MOOREFIELD_MCFG;
#pragma pack()

STATIC CONST EFI_ACPI_6_5_FIRMWARE_ACPI_CONTROL_STRUCTURE  mFacs = {
  .Signature = EFI_ACPI_6_5_FIRMWARE_ACPI_CONTROL_STRUCTURE_SIGNATURE,
  .Length    = sizeof (EFI_ACPI_6_5_FIRMWARE_ACPI_CONTROL_STRUCTURE),
  .Version   = EFI_ACPI_6_5_FIRMWARE_ACPI_CONTROL_STRUCTURE_VERSION
};

STATIC CONST EFI_ACPI_6_5_FIXED_ACPI_DESCRIPTION_TABLE  mFadt = {
  .Header = {
    .Signature       = EFI_ACPI_6_5_FIXED_ACPI_DESCRIPTION_TABLE_SIGNATURE,
    .Length          = sizeof (EFI_ACPI_6_5_FIXED_ACPI_DESCRIPTION_TABLE),
    .Revision        = EFI_ACPI_6_5_FIXED_ACPI_DESCRIPTION_TABLE_REVISION,
    .OemId           = MF_OEM_ID,
    .OemTableId      = MF_OEM_TABLE_ID,
    .OemRevision     = 0x00000001,
    .CreatorId       = SIGNATURE_32 ('I', 'N', 'T', 'L'),
    .CreatorRevision = 0x000C0000
  },
  .PreferredPmProfile = MF_PREFERRED_PM_PROFILE,
  .IaPcBootArch       = MF_FADT_BOOT_ARCH_FLAGS,
  .Flags             = MF_FADT_FLAGS,
  .MinorVersion      = 0x05  // ACPI 6.5
  //
  // FirmwareCtrl, Dsdt and every register block stay zero: AcpiTableDxe fills in
  // FirmwareCtrl/XFirmwareCtrl and Dsdt/XDsdt, and the OS ignores the blocks in
  // hardware-reduced mode.
};

#define MF_LOCAL_APIC(Uid, Id)  {                                          \
      .Type             = EFI_ACPI_6_5_PROCESSOR_LOCAL_APIC,               \
      .Length           = sizeof (EFI_ACPI_6_5_PROCESSOR_LOCAL_APIC_STRUCTURE), \
      .AcpiProcessorUid = (Uid),  /* Must match \_SB.CPUn._UID */          \
      .ApicId           = (Id),                                            \
      .Flags            = EFI_ACPI_6_5_LOCAL_APIC_ENABLED                  \
    }

STATIC CONST MOOREFIELD_MADT  mMadt = {
  .Header = {
    .Signature       = EFI_ACPI_6_5_MULTIPLE_APIC_DESCRIPTION_TABLE_SIGNATURE,
    .Length          = sizeof (MOOREFIELD_MADT),
    .Revision        = EFI_ACPI_6_5_MULTIPLE_APIC_DESCRIPTION_TABLE_REVISION,
    .OemId           = MF_OEM_ID,
    .OemTableId      = MF_OEM_TABLE_ID,
    .OemRevision     = 0x00000001,
    .CreatorId       = SIGNATURE_32 ('I', 'N', 'T', 'L'),
    .CreatorRevision = 0x000C0000
  },
  .LocalApicAddress = FixedPcdGet32 (PcdLocalApicBase),
  .LocalApic        = {
    MF_LOCAL_APIC (0, 0),
    MF_LOCAL_APIC (1, 2),
    MF_LOCAL_APIC (2, 4),
    MF_LOCAL_APIC (3, 6)
  },
  .IoApic = {
    .Type                      = EFI_ACPI_6_5_IO_APIC,
    .Length                    = sizeof (EFI_ACPI_6_5_IO_APIC_STRUCTURE),
    .IoApicId                  = MF_IO_APIC_ID,
    .IoApicAddress             = FixedPcdGet32 (PcdIoApicBase),
    .GlobalSystemInterruptBase = 0
  }
};

// One segment, bus 0 only, matching the SFI MCFG table on the device. Bus 0 is
  // 1 MB of ECAM space, which is what PDRC in Dsdt.asl reserves.
STATIC CONST MOOREFIELD_MCFG  mMcfg = {
  .Header = {
    .Signature       = EFI_ACPI_6_5_PCI_EXPRESS_MEMORY_MAPPED_CONFIGURATION_SPACE_BASE_ADDRESS_DESCRIPTION_TABLE_SIGNATURE,
    .Length          = sizeof (MOOREFIELD_MCFG),
    .Revision        = EFI_ACPI_MEMORY_MAPPED_CONFIGURATION_SPACE_ACCESS_TABLE_REVISION,
    .OemId           = MF_OEM_ID,
    .OemTableId      = MF_OEM_TABLE_ID,
    .OemRevision     = 0x00000001,
    .CreatorId       = SIGNATURE_32 ('I', 'N', 'T', 'L'),
    .CreatorRevision = 0x000C0000
  },
  .Segment = {
    .BaseAddress                = FixedPcdGet32 (PcdPciMmcfgBase),
    .PciSegmentGroupNumber      = 0,
    .StartBusNumber             = 0,
    .EndBusNumber               = 0
  }
}; 

/**
  Fill in the 8-bit checksum of a writable ACPI table. AcpiTableDxe recomputes this
  on install, so doing it here is only to keep each table well formed on the way
  out, and to make an accidental length change show up as a bad checksum.

  @param[in, out]  Table  Table to checksum, in writable memory.
**/
STATIC
VOID
MfChecksumTable (
  IN OUT EFI_ACPI_DESCRIPTION_HEADER  *Table
  )
{
  UINT8  *Bytes;
  UINT8   Sum;
  UINTN   Index;

  Table->Checksum = 0;

  Sum   = 0;
  Bytes = (UINT8 *)Table;
  for (Index = 0; Index < Table->Length; Index++) {
    Sum = (UINT8)(Sum + Bytes[Index]);
  }

  Table->Checksum = (UINT8)(0x100U - Sum);
}

/**
  Install one statically built table, filling in its checksum first.

  @param[in]  AcpiTable  ACPI table protocol instance.
  @param[in]  Template   Read-only template to copy and install.

  @retval EFI_SUCCESS  The table was installed.
  @return               Errors from the memory allocator or the protocol.
**/
STATIC
EFI_STATUS
MfInstallTemplate (
  IN EFI_ACPI_TABLE_PROTOCOL         *AcpiTable,
  IN CONST EFI_ACPI_DESCRIPTION_HEADER  *Template
  )
{
  EFI_STATUS                   Status;
  EFI_ACPI_DESCRIPTION_HEADER  *Table;
  UINTN                        TableKey;

  Table = AllocateCopyPool (Template->Length, Template);
  if (Table == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }

  // The FACS has no checksum byte: it is a bare signature/length pair, not a
  // common-header table, so MfChecksumTable() would write at offset 9, inside
  // HardwareSignature. AcpiTableDxe does not checksum it either.
  if (Template->Signature != EFI_ACPI_6_5_FIRMWARE_ACPI_CONTROL_STRUCTURE_SIGNATURE) {
    MfChecksumTable (Table);
  }

  TableKey = 0;
  Status   = AcpiTable->InstallAcpiTable (AcpiTable, Table, Table->Length, &TableKey);
  FreePool (Table);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  DEBUG ((
    DEBUG_INFO,
    "AcpiPlatform: installed %c%c%c%c revision %u, %u bytes\n",
    Template->Signature & 0xFF,
    (Template->Signature >> 8) & 0xFF,
    (Template->Signature >> 16) & 0xFF,
    (Template->Signature >> 24) & 0xFF,
    Template->Revision,
    Template->Length
    ));

  return EFI_SUCCESS;
}

/**
  Install the board DSDT from the platform ACPI storage file.

  @param[in]  AcpiTable  ACPI table protocol instance.

  @retval EFI_SUCCESS           The DSDT was installed.
  @retval EFI_NOT_FOUND         No DSDT section in the storage file.
  @return                       Errors from the FFS reader or the protocol.
**/
STATIC
EFI_STATUS
MfInstallDsdt (
  IN EFI_ACPI_TABLE_PROTOCOL  *AcpiTable
  )
{
  EFI_STATUS                   Status;
  UINTN                        Instance;
  UINTN                        SectionSize;
  VOID                         *Section;
  EFI_ACPI_DESCRIPTION_HEADER  *Header;
  UINTN                        TableKey;

  Instance = 0;
  while (TRUE) {
    Status = GetSectionFromAnyFv (
               &gMoorefieldAcpiTableStorageGuid,
               EFI_SECTION_RAW,
               Instance,
               &Section,
               &SectionSize
               );
    if (Status == EFI_NOT_FOUND) {
      DEBUG ((DEBUG_ERROR, "AcpiPlatform: no DSDT in the platform ACPI storage file\n"));
      return Status;
    }

    if (EFI_ERROR (Status) || (Section == NULL)) {
      DEBUG ((DEBUG_ERROR, "AcpiPlatform: ACPI section %u unreadable: %r\n", Instance, Status));
      return EFI_PROTOCOL_ERROR;
    }

    if (SectionSize >= sizeof (EFI_ACPI_DESCRIPTION_HEADER)) {
      Header = (EFI_ACPI_DESCRIPTION_HEADER *)Section;
      if (Header->Signature == EFI_ACPI_6_5_DIFFERENTIATED_SYSTEM_DESCRIPTION_TABLE_SIGNATURE) {
        TableKey = 0;
        Status   = AcpiTable->InstallAcpiTable (AcpiTable, Section, Header->Length, &TableKey);
        FreePool (Section);
        if (EFI_ERROR (Status)) {
          return Status;
        }

        DEBUG ((
          DEBUG_INFO,
          "AcpiPlatform: installed DSDT revision %u, %u bytes\n",
          Header->Revision,
          Header->Length
          ));
        return EFI_SUCCESS;
      }
    }

    FreePool (Section);
    Instance++;
  }
}

/**
  Publish the Moorefield ACPI table set.

  @param[in]  ImageHandle  Image handle of this driver.
  @param[in]  SystemTable  UEFI system table.

  @retval EFI_SUCCESS  The table set was installed.
  @return              Errors from the ACPI table protocol.
**/
EFI_STATUS
EFIAPI
AcpiPlatformEntryPoint (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS              Status;
  EFI_ACPI_TABLE_PROTOCOL *AcpiTable;

  Status = gBS->LocateProtocol (
                  &gEfiAcpiTableProtocolGuid,
                  NULL,
                  (VOID **)&AcpiTable
                  );
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "AcpiPlatform: no ACPI table protocol: %r\n", Status));
    return Status;
  }

  // FACS and DSDT must be in place before the FADT that points at them.
  Status = MfInstallTemplate (AcpiTable, (CONST EFI_ACPI_DESCRIPTION_HEADER *)&mFacs);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  Status = MfInstallDsdt (AcpiTable);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  Status = MfInstallTemplate (AcpiTable, (CONST EFI_ACPI_DESCRIPTION_HEADER *)&mFadt);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  Status = MfInstallTemplate (AcpiTable, (CONST EFI_ACPI_DESCRIPTION_HEADER *)&mMadt);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  Status = MfInstallTemplate (AcpiTable, (CONST EFI_ACPI_DESCRIPTION_HEADER *)&mMcfg);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  DEBUG ((DEBUG_INFO, "AcpiPlatform: Moorefield ACPI table set installed\n"));
  return EFI_SUCCESS;
}

// MCFG: 36-byte header, 8 reserved bytes, one 16-byte segment entry. This is the
// same 0x3C-byte table the SFI MCFG on the device and U-Boot's Tangier
// acpi_fill_mcfg() produce.
STATIC_ASSERT (
  sizeof (MOOREFIELD_MCFG) == 0x3C,
  "MCFG table must be 0x3C bytes"
  );
