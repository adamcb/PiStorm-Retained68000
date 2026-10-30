# Pin-focused C12 diagnostic readout

Use these **new reader files only with the pin-focused C12 diagnostic image**. Keep them in the new `diagnostic-brjp-pins-readout` folder; leave the earlier `diagnostic-readout` folder and its D-format results untouched. The old D704/28FB record cannot be reinterpreted as pin flags. This reader rejects the old D12C identity marker and refuses to decode old D headers.

After flashing the exact new SVF, while the entire LazarusStorm/PiStorm/Pi assembly remains physically detached from the unpowered Amiga and powered only by Pi USB, enter the new reader folder and run:

```sh
sudo python3 read_retained_diag_jtag.py --disconnected --preflight --output diagnostic-preflight-bg-schmitt-1.json
```

Require `Diagnostic image markers: verified`, `Record: blank` and exit status 0 before reconnecting for a trial. This checks logical word510=4D55, word511=C12C and erased record words0/1. Use a new JSON filename every time. The markers identify the C12 format, not the complete CPLD configuration; associate the result with the exact image/hash, blank preflight and trial history.

When the stop appears, leave Amiga power on for at least one second so a pending record can finish. Turn the Amiga off, disconnect its power, physically unplug the complete assembly, and boot Raspberry Pi OS with the detached assembly USB-powered as for flashing. Stop any emulator, OpenOCD, PiStorm flasher and other GPIO/JTAG reader. From this new folder run:

```sh
sudo python3 read_retained_diag_jtag.py --disconnected --output diagnostic-bg-schmitt-result-1.json
```

Keep the JSON even if readout fails or the record is partial/unrecognized. The tool preserves two full512-word reads, converted words, markers, raw record and JTAG trace; it decodes only after both reads agree and new markers match. Existing result files are never overwritten. Readout can be repeated without clearing the record. Save the result before reflashing, because flashing can erase it. Shut down Linux and remove USB before reconnecting the assembly to the unpowered Amiga.

Python3's standard library is sufficient. This hardware path remains restricted to the Pi3A+ and uses the existing flasher's GPIO numbers: TCK26, TMS24, TDI27, TDO25 (GPIO numbers, not header-pin numbers). It does not access `/dev/mem`, configure a clock, use GPIO BUSY, issue motherboard bus cycles, or expose program/erase instructions. Instruction whitelist, device/chain checks, JTAG routing and GPIO implementation are unchanged from the earlier read-only tool.

| Record | Interpretation |
|---|---|
| `committed` | Word0 high nibble C and word1 its exact16-bit complement. Decode the low12 bits. |
| `blank` | Both record words FFFF with the new hardware markers verified; no record was found. |
| `partial` | C-format first word with absent/mismatched complement; preserve without interpreting fields. |
| `unrecognized` | Old D header or another unsupported header; return a readout error and preserve the raw words without pin interpretation. |

Payload bits11:10 retain the observation reason; bit9 ownership, bits8:7 main state and bits6:4 peripheral state are unchanged. **Bits3:1 are now sticky per-input condition flags, not the old AS/DTACK/E levels.** Bit0 is the sampled /VPA level.

| Event mask | Qualified condition latched |
|---|---|
| 4 | /BG high |
| 2 | /BGACK low |
| 1 | /BERR low |
| 0 | No per-input flag present; a reported raw event remains unresolved. |
| Multiple bits | More than one condition was latched; order and initiating cause are not recorded. |

The labels refer to **CPLD logical inputs**, rather than independent measurements of native CPU voltage. The published PCB/fabrication files agree with BG71/BGACK70, and the tested board's BG71 copper was checked. The schematic PDF differs, and BGACK was not separately measured on the actual board. This reader does not remap pins. A /BERR-low flag can be an ordinary bus-error cycle termination, and is not itself proof of arbitration loss or CPU contention.

Each per-input flag observes the same owned-and-not-native-reset qualification as the functional raw-loss detector. The flags are additional observations only. A short pulse can end before readout. Zero or multiple flags are valid possibilities; a single flag does not prove its physical cause, which condition came first, or that it caused the visible hang. The first qualifying record can precede that hang and remains retained. There are **no AS, DTACK or E samples** in C12, and no timestamp, waveform, interrupt history, address or transfer data.

A long BUSY trigger is about1.14ms at7.16MHz. A BUSY-low software stop or native clock loss before capture can leave no record. A blank record is not a health certificate, and the red power LED alone does not identify a cause. UFM completion uses an independent oscillator after capture. No on-device readback verification occurs; the reader's complement check detects single-bit changes but cannot detect every paired/multibit corruption.

The read-only whitelist is SAMPLE/PRELOAD005, BYPASS3FF, ISC_ENABLE2CC, address203, read205 and ISC_DISABLE201. Erase2F2/program2F4 are rejected. A64-bit ID scan must show the single expected EPM240020A10DD before ISC. The UFM selector remains fixed to1. Cleanup disables ISC, selects BYPASS and floats the four JTAG pads. Numeric scan values are bit-reversed into logical16-bit UFM words; the unchanged official Quartus serialization fixture proves that offline mapping, not physical waveforms or this record format. No fixture programming image is included.

Offline decoding requires no GPIO. It cannot verify full-memory identity markers:

```sh
python3 read_retained_diag_jtag.py --decode C708 38F7 --json
```

This synthetic example carries one /BG-high latch. Host/fake-GPIO checks are reproducible with:

```sh
python3 -m unittest -v test_read_retained_diag_jtag
```

These checks do not qualify physical JTAG waveforms, real asynchronous pulse acceptance, flash retention or operation of the user's new image.
