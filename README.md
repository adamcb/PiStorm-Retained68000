# PiStorm Retained 68000

CPLD firmware for a **classic PiStorm connected through LazarusStorm to an
Amiga 500 Rev 5, with the original motherboard 68000 left installed**.

The working build is **BG Schmitt diagnostic, 2026-10-30**. It uses the original
CPU's E clock and bus-grant signal, and enables the MAX II Schmitt input on
`/BG`. On the tested assembly it reached Workbench, allowed floppy loading
while typing, and continued working through several restarts and normal use.

This is a working result on one reported setup, not a compatibility claim for
every Amiga, PiStorm revision or expansion. The original CPU remains installed
and held off the bus. This firmware does not implement a stock-CPU/PiStorm
selection switch or hot switching.

## Tested setup

| Part | Setup |
|---|---|
| Amiga | A500 Rev 5 with original 68000 installed |
| Adapter | LazarusStorm, BRJP **open**, native `/BR` held low through its fitted R1 |
| Rev 5 clock connection | Existing wire from native CPU pin 15 to side-expansion contact 7 |
| PiStorm | Classic MAX II EPM240, T100 package, speed grade 5; project target EPM240T100I5 |
| Registers / bus switches | Four 74LVC16374 and two SN74CBTD3384, marked CC384 |
| Raspberry Pi | Pi 3A+ |
| Software | Emu68 1.0.x; Raspberry Pi OS for flashing and diagnostic retrieval |
| Pi interface clock | 200 MHz, as required by the supplied constraints |

Keep the setup's existing working VPAJP arrangement. Pin numbers on the native
68000, PiStorm connector and Amiga expansion connector are different numbering
systems; the clock connection above is explicitly CPU15 to expansion7.

## What the firmware changes

- E and `/BG` are **inputs**. PiStorm does not drive competing E or BG outputs
  against the retained motherboard CPU.
- Peripheral cycles use the native CPU's E clock.
- Acquisition accounts for LazarusStorm's open BRJP: native CPU `/BR` is held
  low, while PiStorm's separate connector `/BR` is pulled high. That isolated
  input is not used as the native CPU's bus request.
- `/BG` at CPLD pin 71 uses **3.3V Schmitt Trigger Input** mode. Hysteresis can
  improve tolerance of noisy transitions while the existing grant-loss
  protection remains active.
- Bus completion, reset and error protection remain in place. No automatic
  transaction retry is added.
- A one-shot diagnostic logger remains available in the MAX II user flash.
  It observes the controller and does not provide an AmigaOS background task.

The new Schmitt build retains the same controller RTL and Hold A timing as the
preceding corrected diagnostic. It is not a source rebuild of the historical
2021 `long_hold.svf` image. See [design and provenance](docs/DESIGN.md).

## Flash the known-working image

Use **`flash_retained68000_bg_schmitt_diag.sh`**. There is one supplied
programming image:

```text
rtl/EPM240_retained68000_bg_schmitt_diag.svf
SHA256 2f6263c07f225ed51fbfee0439df37ef675dccd90f400936c8a8c4725709f1e0
```

The image and helper can be copied into an existing `PiStorm-Firmware`
directory containing a working `pistormflash` executable. Copy the complete
`diagnostic-brjp-pins-readout/` directory too. The flasher executable is a
separate prerequisite; obtain it from the
[upstream firmware bundle](https://github.com/LemaruX/PiStorm-Firmware).

With the Amiga off, **physically detach the complete adapter/PiStorm/Pi
assembly from the Amiga**. USB-power the detached Pi and boot Raspberry Pi OS.
The original 68000 can stay in the disconnected Amiga.

From the directory containing the helper and `pistormflash`, as the normal Pi
user:

```sh
chmod +x flash_retained68000_bg_schmitt_diag.sh
./flash_retained68000_bg_schmitt_diag.sh
```

The helper checks the exact image hash and EPM240 ID before flashing. Require
`CPLD flashed successfully!`. Do not run the flash helper with sudo.

While the assembly is still detached and USB-powered, check the blank logger:

```sh
sudo python3 diagnostic-brjp-pins-readout/read_retained_diag_jtag.py --disconnected --preflight --output diagnostic-preflight-bg-schmitt-1.json
```

Require verified image-format markers, a blank record and exit status zero.
Use a new output filename if one already exists.

Shut down Linux, wait for shutdown, remove USB power and restore the Emu68
card. Reconnect to the unpowered Amiga, keeping **the 68000 installed and
BRJP open**, then power the Amiga normally. USB power is used only while the
assembly is detached.

Keep startup BUPTest enabled for the first trial. Record its result, whether
Workbench starts, and keyboard/floppy operation separately. A RAM-test pass
alone does not demonstrate peripheral stability.

## Diagnostic dump

Save a diagnostic dump **before reflashing**, because a full-device flash can
erase the previous record. After a failure, leave Amiga power on for at least
one second, then power off and return the physically detached assembly to
USB-powered Raspberry Pi OS.

```sh
sudo python3 diagnostic-brjp-pins-readout/read_retained_diag_jtag.py --disconnected --output diagnostic-bg-schmitt-result-1.json
```

The reader uses Python 3's standard library. It preserves two complete reads
and never overwrites an existing output file. See
[diagnostic details](diagnostic-brjp-pins-readout/READOUT.md).

The logger stores the first qualifying event; that record survives keyboard
resets and power cycles. Reading does not clear it. C12 format markers identify
the record format, not the complete firmware image or a physical waveform.

## Source and validation

- [Quartus build instructions](docs/BUILD.md)
- [Hardware result and verification limits](docs/VALIDATION.md)
- [Design, pin mapping and provenance](docs/DESIGN.md)
- [Exact release identity](KNOWN-WORKING.json)

The supplied SVF is the unchanged image used for the successful user-reported
trial. Building the source produces a new candidate that needs its own checks
and hardware trial. Keep this exact image as the recovery baseline.

## Credits

Based on [PiStorm](https://github.com/captain-amygdala/pistorm), with
[LazarusStorm](https://github.com/arananet/LAZARUSTORM) and the
[PiStorm firmware bundle](https://github.com/LemaruX/PiStorm-Firmware) used as
hardware, source and flashing references. Original source copyright and
license headers are retained. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
