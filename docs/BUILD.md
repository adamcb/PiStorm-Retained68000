# Build the source

The checked-in SVF is the exact known-working image. Building is optional;
flash that image when reproducing the reported hardware result.

## Toolchain

The recorded build used Quartus Prime Lite 24.1std.0 Build 1077 with MAX II
device support, targeting **EPM240T100I5**. Quartus and its vendor libraries
are separate prerequisites and are not distributed here.

From the repository root in PowerShell, substitute your actual Quartus path:

```powershell
.\firmware\project\build.ps1 -QuartusBin 'C:\altera_lite\24.1std\quartus\bin64'
```

The wrapper creates a fresh `firmware/builds/<snapshot>/` directory, copies
and hashes its inputs, compiles offline, verifies the target and 56 user pins,
checks BG71 is a physical Schmitt input and E53 remains an input, verifies
internal timing at both corners, and converts the POF to SVF. It never
discovers a cable or programs hardware. An error or critical warning blocks
export.

The public wrapper is portable across checkout locations; the lab wrapper's
fixed `C:\Dev\PiStorm-Retained68000` restriction was removed. It otherwise
retains the verification and snapshot behavior. The programming image was
not rebuilt as part of publishing this repository.

## Timing assumptions

- Pi interface clock: 200 MHz / 5 ns.
- Native-clock constraint: 139 ns.
- Native E launch is related to the falling native clock edge.
- Native E input budget: max 60 ns / min 0 ns, including 5 ns of assumed board
  allowance. That board allowance was not measured.
- Three UFM clocks are constrained separately; the expected total is five.

The recorded fit uses 238/240 logic elements and one UFM block. Its slow setup
margin is 0.069 ns; internal margins do not establish external GPIO/latch timing,
clock jitter, analog thresholds or compatibility with another board.

A rebuilt POF/SVF can differ because of tool versions, fit decisions and
programming-file metadata. Do not silently replace the checked-in working
image. Keep it as a recovery baseline and label a rebuilt image separately.

## Diagnostic reader checks

The reader uses only Python 3's standard library. Its host/fake-GPIO checks can
be run without hardware:

```sh
cd diagnostic-brjp-pins-readout
python3 -m unittest -v test_read_retained_diag_jtag
```

These validate reader logic and a simulated TAP. They do not qualify physical
JTAG signaling, flash retention or Amiga operation.
