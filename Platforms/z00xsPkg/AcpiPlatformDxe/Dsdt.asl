DefinitionBlock ("Dsdt.aml", "DSDT", 0x02, "INTEL ", "MOOREFLD", 0x00000001)
{
    // System power states
    //Name (_S0, Package () { 0x00 })
    //Name (_S5, Package () { 0x00 })

    /*
    * The _PTS method (Prepare To Sleep) is called before the OS is
    * entering a sleep state. The sleep state number is passed in Arg0.
    */
    Method(_PTS, 1)
    {
    }

    /* The _WAK method is called on system wakeup */
    Method(_WAK, 1)
    {
        Return (Package() { Zero, Zero })
    }

    Scope (\_SB)
    {
       Processor (CPU0, 0x00, 0, 0) { Name (_UID,0)  Name (_STA,0x0F) }
       Processor (CPU1, 0x02, 0, 0) { Name (_UID,1)  Name (_STA,0x0F) }
       Processor (CPU2, 0x04, 0, 0) { Name (_UID,2)  Name (_STA,0x0F) }
       Processor (CPU3, 0x06, 0, 0) { Name (_UID,3)  Name (_STA,0x0F) }

        //
        // Motherboard resources: the framebuffer and graphics stolen memory at
        // the top of low RAM (ZX551ML/iomem.txt), so the OS keeps its hands off
        // it. The I/O APIC and the Local APIC are claimed by the MADT, the
        // SDHCI block is the BAR of PCI0.SDHB and the MMCONFIG window is
        // reserved by PCI0.PDRC, so none of them are repeated here.
        //
        // There is no HPET: the SoC has none (the SFI tables and the stock
        // kernel's iomem show no timer block at 0xFED00000, and U-Boot's
        // Tangier ACPI has none either). Linux on Intel MID runs from the
        // Local APIC timer and the MSR-calibrated TSC.
        //
        Device (SYSR)
        {
            Name (_HID, EisaId ("PNP0C02"))
            Name (_UID, 0x01)
            Name (_STA, 0x0F)
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x7F700000, 0x00900000)  // 0x7F700000-0x7FFFFFFF framebuffer, stolen memory
            })
        }

        /* Real Time Clock, present on TNG/ANN */
        Device (RTC0)
        {
            Name (_HID, EisaId ("PNP0B00"))
            Name (_CRS, ResourceTemplate()
            {
                IO(Decode16, 0x70, 0x70, 0x01, 0x08)
            })
        }

        //
        // PCI host bridge, modelled on the Tangier (Merrifield/Moorefield) ACPI
        // in U-Boot (arch/x86/include/asm/arch-tangier/acpi/southcluster.asl).
        // The SoC has a single root bus with every function on bus 0 and no PCIe
        // links; config space is reached through the MMCONFIG window that the
        // MCFG table in AcpiPlatformDxe.c publishes (PcdPciMmcfgBase, bus 0 only).
        //
        // Windows needs this device to load pci.sys at all: without a PNP0A08
        // node it never enumerates the SoC's PCI functions. The I/O and memory
        // ranges are the whole decode space of the root bridge; the memory
        // windows below 0x80000000 are the BARs that sit in low memory on this
        // part (ZX551ML/iomem.txt), not general-purpose space.
        //
        Device (PCI0)
        {
            Name (_HID, EisaId ("PNP0A08"))  // PCI Express root bridge
            Name (_CID, EisaId ("PNP0A03"))  // PCI root bridge
            Name (_UID, 0x00)
            Name (_BBN, 0x00)

            Name (MCRS, ResourceTemplate ()
            {
                // Bus numbers
                WordBusNumber (ResourceProducer, MinFixed, MaxFixed, PosDecode,
                    0x0000, 0x0000, 0x00FF, 0x0000, 0x0100, , , PB00)

                // I/O below the config mechanism #1 ports
                WordIO (ResourceProducer, MinFixed, MaxFixed, PosDecode, EntireRange,
                    0x0000, 0x0000, 0x0CF7, 0x0000, 0x0CF8, , , PI00)

                // PCI config mechanism #1 address/data ports
                IO (Decode16, 0x0CF8, 0x0CF8, 0x01, 0x08)

                // I/O above them
                WordIO (ResourceProducer, MinFixed, MaxFixed, PosDecode, EntireRange,
                    0x0000, 0x0D00, 0xFFFF, 0x0000, 0xF300, , , PI01)

                // GPIO (langwell_gpio, 00:0c.0) low BAR
                DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed,
                    Cacheable, ReadWrite,
                    0x00000000, 0x000CDB20, 0x000CDB27, 0x00000000,
                    0x00000008, , , GP00)

                // PSH (00:16.1) BAR 0
                DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed,
                    Cacheable, ReadWrite,
                    0x00000000, 0x04900000, 0x0497FFFF, 0x00000000,
                    0x00080000, , , PSH0)

                // PSH (00:16.1) BAR 1
                DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed,
                    Cacheable, ReadWrite,
                    0x00000000, 0x04B19000, 0x04B20FFF, 0x00000000,
                    0x00008000, , , PSH1)

                // SST audio (00:0d.0) shared SRAM
                DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed,
                    Cacheable, ReadWrite,
                    0x00000000, 0x05E00000, 0x05FFFFFF, 0x00000000,
                    0x00200000, , , SST0)

                // Everything the SoC maps for its PCI functions: GFX at
                // 0x80000000, the 0xF9/0xFA peripherals and the 0xFF0xxxxx
                // fabric BARs.
                DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed,
                    Cacheable, ReadWrite,
                    0x00000000, 0x80000000, 0xFFFFFFFF, 0x00000000,
                    0x80000000, , , PMEM)
            })

            Method (_CRS, 0, Serialized)
            {
                Return (MCRS)
            }

            //
            // Device Resource Consumption: the MMCONFIG window. Must match
            // PcdPciMmcfgBase and the single bus-0 segment in the MCFG table,
            // which is 1 MB of ECAM space (32 devices x 8 functions x 4 KB).
            //
            Device (PDRC)
            {
                Name (_HID, EisaId ("PNP0C02"))
                Name (_UID, 0x01)

                Name (PDRS, ResourceTemplate ()
                {
                    Memory32Fixed (ReadWrite, 0x7F600000, 0x00100000)
                })

                Method (_CRS, 0, Serialized)
                {
                    Return (PDRS)
                }
            }

            //
            // PCI Express _OSC: the SoC has no firmware-managed PCI features,
            // so let the OS control everything it asks for.
            //
            Method (_OSC, 4, NotSerialized)
            {
                If (LEqual (Arg0, ToUUID ("33DB4D5B-1FF7-401C-9657-7441C03DD766")))
                {
                    Return (Arg3)
                }
                Else
                {
                    // Unrecognized UUID: set the "unrecognized UUID" error bit
                    CreateDWordField (Arg3, 0x00, CDW1)
                    Or (CDW1, 0x04, CDW1)
                    Return (Arg3)
                }
            }

            //
            // GPIO controller (langwell_gpio, 00:0c.0), modelled on the Tangier
            // (Merrifield/Moorefield) ACPI in U-Boot. The _REG method lets the
            // OS take ownership of the GPIO region, and the WFD3 field is the
            // WiFi device power switch shared with PCI0.SDHC.
            //
            Device (GPIO)
            {
                Name (_ADR, 0x000c0000)
                Name (_STA, 0x0F)

                Name (AVBL, Zero)
                Method (_REG, 2, NotSerialized)
                {
                    If (Arg0 == 0x08)
                    {
                        AVBL = Arg1
                    }
                }

                OperationRegion (GPOP, GeneralPurposeIo, 0, 1)
                //
                // WLAN-EN. PullDown, not U-Boot's PullDefault: Linux takes the
                // direction of an output-only GpioIo from its pull setting and
                // leaves a PullDefault pin as it found it. U-Boot on Edison
                // leaves this pad an output; this firmware does not, so with
                // PullDefault every write to WFD3 went to an input pin. With
                // PullDown it becomes an output, initially low (off), like the
                // stock kernel's WLAN-EN regulator.
                //
                Field (GPOP, ByteAcc, NoLock, Preserve)
                {
                    Connection (
                        GpioIo (Exclusive, PullDown, 0, 0, IoRestrictionOutputOnly,
                            "\\_SB.PCI0.GPIO", 0, ResourceConsumer, , ) { 96 }
                    ),
                    WFD3, 1,
                }
            }

            //
            // SDIO/SD host controller (00:01.2). The card-detect GPIO is on
            // pin 77 of the GPIO controller (sd_cd_pin in the SFI GPIO table),
            // wired as an edge-triggered, active-both, shared-and-wake
            // interrupt. The _DSD "cd-gpios" property is what the Linux MMC
            // driver consumes to find the card-detect line.
            //
            Device (SDHB)
            {
                Name (_ADR, 0x00010002)
                Name (_DEP, Package () { GPIO })

                Name (RBUF, ResourceTemplate ()
                {
                    GpioInt (Edge, ActiveBoth, SharedAndWake, PullNone, 10000,
                        "\\_SB.PCI0.GPIO", 0, ResourceConsumer, , ) { 77 }
                })

                Method (_CRS, 0, Serialized)
                {
                    Return (RBUF)
                }

                Name (_DSD, Package () {
                    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301"),
                    Package () {
                        Package () { "cd-gpios", Package () { ^SDHB, 0, 0, 0 } },
                    }
                })

                Name (_STA, 0x0F)
            }

            //
            // SDIO host controller (00:01.3) with the Broadcom BCM4339 WiFi
            // chip (CONFIG_BCM4339 in the ZX551ML kernel config). The chip is
            // powered by WLAN-EN, GPIO 96 in the SFI GPIO table, which the
            // stock kernel drives as the slot's 1.8 V vmmc regulator; here it
            // is the GPIO.WFD3 field, as in U-Boot's Tangier ACPI. Linux runs
            // _PS0 of this device and its children when the slot is probed
            // and whenever the PCI function is powered up, so WiFi gets power
            // once the GPIO operation region is available (GPIO.AVBL).
            //
            // Like the stock regulator (registered with the pin low, then
            // enabled with a 250 ms startup delay), WLON gives the chip a
            // clean power-on reset even if WLAN-EN was left high, e.g. across
            // a warm reboot, and holds off the first SDIO command until the
            // chip is ready to answer it.
            //
            Device (SDHC)
            {
                Name (_ADR, 0x00010003)
                Name (_DEP, Package () { GPIO })
                Name (PSTS, Zero)

                Name (_STA, 0x0F)

                Method (_PS3, 0, NotSerialized)
                {
                }

                Method (WLON, 0, Serialized)
                {
                    If (PSTS == Zero)
                    {
                        If (^^GPIO.AVBL == One)
                        {
                            ^^GPIO.WFD3 = Zero
                            Sleep (20)
                            ^^GPIO.WFD3 = One
                            Sleep (250)
                            PSTS = One
                        }
                    }
                }

                Method (_PS0, 0, NotSerialized)
                {
                    WLON ()
                }

                // SDIO function 1: BCM4339 WLAN
                Device (WLAN)
                {
                    Name (_ADR, 0x01)
                    Name (_DEP, Package () { GPIO })

                    Name (_STA, 0x0F)

                    Method (_RMV, 0, NotSerialized)
                    {
                        Return (Zero)
                    }

                    Method (_PS3, 0, NotSerialized)
                    {
                        If (^^^GPIO.AVBL == One)
                        {
                            ^^^GPIO.WFD3 = Zero
                            PSTS = Zero
                        }
                    }

                    Method (_PS0, 0, NotSerialized)
                    {
                        ^^WLON ()
                    }
                }

                // SDIO function 2: BCM4339 WLAN data
                Device (WLN2)
                {
                    Name (_ADR, 0x02)

                    Name (_STA, 0x0F)

                    Method (_RMV, 0, NotSerialized)
                    {
                        Return (Zero)
                    }
                }
            }

            //
            // I2C bus 2 (00:08.1): MAX17058 fuel gauge at 0x36 (max17058_batt
            // in the SFI DEVS table). Linux binds max17040_battery to it via
            // the compatible below; the stock kernel runs this bus at
            // standard mode and polls the gauge, so there is no interrupt.
            // maxim,rcomp is the stock driver's INI_RCOMP (165). Its 18-bit
            // model reports SOC in 1/256 %, mainline's default scaling.
            //
            Device (I2C2)
            {
                Name (_ADR, 0x00080001)
                Name (_STA, 0x0F)

                Device (BATT)
                {
                    Name (_HID, "PRP0001")
                    Name (_DDN, "MAX17058 fuel gauge")
                    Name (_STA, 0x0F)

                    Name (RBUF, ResourceTemplate ()
                    {
                        I2cSerialBusV2 (0x36, ControllerInitiated, 100000,
                            AddressingMode7Bit, "\\_SB.PCI0.I2C2",
                            0x00, ResourceConsumer, , Exclusive, )
                    })

                    Method (_CRS, 0, Serialized)
                    {
                        Return (RBUF)
                    }

                    Name (_DSD, Package () {
                        ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301"),
                        Package () {
                            Package () { "compatible", "maxim,max17058" },
                            Package () { "maxim,rcomp", Package () { 0xA5 } },
                        }
                    })
                }
            }

            //
            // I2C bus 7 (00:09.2): FocalTech touch controller at 0x38
            // (ftxxxx_ts in the SFI DEVS table), run at fast mode as in the
            // stock kernel. The stock driver speaks the generic FocalTech
            // protocol (10 points, 6-byte records from register 0), which is
            // what Linux edt-ft5x06 uses for "focaltech,ft5426". Interrupt is
            // TOUCH_INT_N (GPIO 120, falling edge), reset is TOUCH_RST_N
            // (GPIO 191, active low); the panel is 1080x1920.
            //
            Device (I2C7)
            {
                Name (_ADR, 0x00090002)
                Name (_STA, 0x0F)

                Device (TCH0)
                {
                    Name (_HID, "PRP0001")
                    Name (_DDN, "FocalTech touchscreen")
                    Name (_DEP, Package () { ^^GPIO })
                    Name (_STA, 0x0F)

                    Name (RBUF, ResourceTemplate ()
                    {
                        I2cSerialBusV2 (0x38, ControllerInitiated, 400000,
                            AddressingMode7Bit, "\\_SB.PCI0.I2C7",
                            0x00, ResourceConsumer, , Exclusive, )
                        GpioInt (Edge, ActiveLow, Exclusive, PullDefault, 0,
                            "\\_SB.PCI0.GPIO", 0, ResourceConsumer, , ) { 120 }
                        GpioIo (Exclusive, PullDefault, 0, 0, IoRestrictionOutputOnly,
                            "\\_SB.PCI0.GPIO", 0, ResourceConsumer, , ) { 191 }
                    })

                    Method (_CRS, 0, Serialized)
                    {
                        Return (RBUF)
                    }

                    // GPIO indices count GpioInt and GpioIo together: 0 is
                    // the interrupt, 1 the reset line.
                    Name (_DSD, Package () {
                        ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301"),
                        Package () {
                            Package () { "compatible", "focaltech,ft5426" },
                            Package () { "touchscreen-size-x", 1080 },
                            Package () { "touchscreen-size-y", 1920 },
                            Package () { "reset-gpios", Package () { ^TCH0, 1, 0, 1 } },
                        }
                    })
                }
            }

            //
            // Graphics (00:02.0, 8086:1480): the display controller and its
            // MIPI DSI panel, a Novatek NT35596 on the ZX550ML. The Linux
            // mrfld driver takes the panel's GPIOs from here: reset is
            // DISP_RST_N (GPIO 190, active low), backlight enable is
            // PANEL_BKLTEN (GPIO 188), both from the SFI GPIO table.
            // asus,lcd-id is the LCD ID the Asus firmware reports in SFI
            // OEM1 and picks the panel's glass: 3 is TM, as on this phone
            // (OEM1 lcd_id 0x03), 0 would be AUO.
            //
            Device (GFX0)
            {
                Name (_ADR, 0x00020000)
                Name (_DEP, Package () { GPIO })

                Name (RBUF, ResourceTemplate ()
                {
                    GpioIo (Exclusive, PullDefault, 0, 0, IoRestrictionOutputOnly,
                        "\\_SB.PCI0.GPIO", 0, ResourceConsumer, , ) { 190 }
                    GpioIo (Exclusive, PullDefault, 0, 0, IoRestrictionOutputOnly,
                        "\\_SB.PCI0.GPIO", 0, ResourceConsumer, , ) { 188 }
                })

                Method (_CRS, 0, Serialized)
                {
                    Return (RBUF)
                }

                Name (_DSD, Package () {
                    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301"),
                    Package () {
                        Package () { "reset-gpios", Package () { ^GFX0, 0, 0, 1 } },
                        Package () { "backlight-gpios", Package () { ^GFX0, 1, 0, 0 } },
                        Package () { "asus,lcd-id", 3 },
                    }
                })

                Name (_STA, 0x0F)
            }

            //
            // USB OTG controller (00:11.0): the Synopsys DWC3 core. Moorefield
            // uses the same PCI ID 8086:119E as Merrifield, at the same _ADR.
            // The Shady Cove PMIC provides power and clock, so the DWC3
            // depends on it.
            //
            Device (DWC3)
            {
                Name (_ADR, 0x00110000)
                Name (_DEP, Package ()
                {
                    ^IPC1.PMIC
                })

                Name (_STA, 0x0F)

                Device (RHUB)
                {
                    Name (_ADR, Zero)

                    Name (PCKG, Package () {
                        Buffer (0x14) {}
                    })

                    /* GPLD: Generate Port Location Data (PLD) */
                    Method (GPLD, 1, Serialized) {
                        /* REV: Revision 0x02 for ACPI 5.0 */
                        CreateField (DerefOf (Index (PCKG, Zero)), Zero, 0x07, REV)
                        Store (0x0002, REV)

                        /* VISI: Port visibility to user per port */
                        CreateField (DerefOf (Index (PCKG, Zero)), 0x40, One, VISI)
                        Store (Arg0, VISI)

                        /* VOFF: Vertical offset is not supplied */
                        CreateField (DerefOf (Index (PCKG, Zero)), 0x80, 0x10, VOFF)
                        Store (0xFFFF, VOFF)

                        /* HOFF: Horizontal offset is not supplied */
                        CreateField (DerefOf (Index (PCKG, Zero)), 0x90, 0x10, HOFF)
                        Store (0xFFFF, HOFF)

                        Return (PCKG)
                    }

                    Device (HS01) { Name (_ADR, 1) }
                    Device (SS01) { Name (_ADR, 2) }
                }
            }

            //
            // Intel SCU IPC (00:13.0) with the Shady Cove PMIC behind it.
            // Like Merrifield's Basin Cove (INTC100E), the PMIC is reached
            // through SCU IPC and the SCU services its Level 1 interrupts,
            // so each one has its own I/O APIC line. The Linux
            // intel_soc_pmic_mrfld driver binds to INTC100F and takes the
            // interrupts by index, in the same order as for Basin Cove.
            //
            Device (IPC1)
            {
                Name (_ADR, 0x00130000)

                Name (_STA, 0x0F)

                Device (PMIC)
                {
                    Name (_HID, "INTC100F")
                    Name (_CID, "INTC100F")
                    Name (_DDN, "Shady Cove PMIC")
                    Name (_DEP, Package ()
                    {
                        IPC1
                    })

                    Name (_STA, 0x0F)

                    //
                    // The interrupt lines are the ones the SFI DEVS table
                    // gives the PMIC functions (ZX551ML/tables/DEVS), and
                    // match the Basin Cove ones in U-Boot's Tangier ACPI.
                    // The SRAM window is where the SCU shadows the PMIC
                    // interrupt status; the stock kernel reads the thermal
                    // status at offset 0x03 and PBSTATUS at offset 0x0a.
                    //
                    Name (RBUF, ResourceTemplate ()
                    {
                        Memory32Fixed (ReadWrite, 0xFFFFF610, 0x00000010)
                        Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) { 30 }  // power button
                        Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) { 23 }  // TMU
                        Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) { 52 }  // thermal
                        Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) { 51 }  // BCU
                        Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) { 50 }  // ADC
                        Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) { 27 }  // charger
                        Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) { 49 }  // GPIO
                    })

                    Method (_CRS, 0, Serialized)
                    {
                        Return (RBUF)
                    }
                }
            }
        }

        //
        // Family-Level Interface Shim (FLIS), the pin controller. The Linux
        // pinctrl-moorefield driver binds to INTC1003 and maps the pin
        // configuration registers from the first memory resource; the
        // GPIO driver looks the device up by this ID to register its pin
        // ranges. Without it the SD card-detect GPIO never comes up. The
        // base is the same as on Merrifield (INTC1002) and as the stock
        // kernel's flis_base.
        //
        Device (FLIS)
        {
            Name (_HID, "INTC1003")
            Name (_DDN, "Intel Moorefield Family-Level Interface Shim")
            Name (_STA, 0x0F)

            Name (RBUF, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0xFF0C0000, 0x00008000)
                // Pin numbers are pinctrl-moorefield pins, mirroring the
                // PinGroups in U-Boot's Tangier southcluster.asl (which
                // describes Merrifield/INTC1002 with its own numbering).
                PinGroup ("spi5", ResourceProducer, ) { 78, 79, 80, 81, 82, 83, 84 }
                PinGroup ("uart0", ResourceProducer, ) { 109, 110, 111, 112 }
                PinGroup ("uart1", ResourceProducer, ) { 113, 114, 115, 116 }
                PinGroup ("uart2", ResourceProducer, ) { 117, 118, 119, 120 }
                PinGroup ("pwm0", ResourceProducer, ) { 130 }
                PinGroup ("pwm1", ResourceProducer, ) { 131 }
                PinGroup ("pwm2", ResourceProducer, ) { 138 }
                PinGroup ("pwm3", ResourceProducer, ) { 139 }
            })

            Method (_CRS, 0, NotSerialized)
            {
                Return (RBUF)
            }
        }
    }
}
