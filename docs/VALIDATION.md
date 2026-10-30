# Validation and hardware result

## User-reported physical result, 2026-10-30

On the setup listed in the main README, the user identified the supplied BG
Schmitt diagnostic image and confirmed:

- Workbench running with the original motherboard 68000 installed.
- A floppy loaded while keyboard typing continued.
- Several successful restarts and varied normal use afterward.

The first report included a Workbench/editor photograph. Photos and raw
conversation material are not included in this repository. The number/type
of restarts, exact elapsed duration and a complete BUPTest result for that
particular successful run were not separately specified. Earlier diagnostic
trials had different explicit preflight/reset histories; those confirmations
are not imported into this run.

This is a useful functional result on one assembly, not long-term or broad
hardware qualification. Keep the supplied image unchanged if it works on
your machine. Additional hardware combinations need their own trial.

## Offline build evidence

| Check | Recorded result |
|---|---|
| Tool/target | Quartus Prime Lite 24.1std.0 Build 1077, EPM240T100I5 |
| Fit | 238/240 logic elements, 56 user pins, 1 UFM block |
| BG71 | Physical input, 3.3V Schmitt Trigger Input, weak pull-up retained |
| E53 | Physical input, 3.3-V LVTTL |
| Other 55 user pins | 3.3-V LVTTL, established pin map |
| Internal timing | Slow/fast checks pass with five expected clocks |
| Slow setup/hold margin | 0.069 ns / 1.376 ns |
| Fast setup/hold margin | 3.457 ns / 0.301 ns |
| Fitted guard/observer connectivity | 14 endpoint checks across two corners |
| Independent build/source/pin review | 142/142 checks |
| Export-mode guard fixtures | 9 cases, including expected rejection cases |

The existing 455 digital cases were reused by exact top/logger/MIF source
identity. They were not 455 new simulations of Schmitt behavior: the analog
hysteresis is not modeled by those HDL tests. The current fit and physical
trial are separate evidence.

The image keeps the existing raw grant/error withdrawal and fault handling.
The fitted review checked those paths remained connected and the isolated
PiStorm BR input was absent from them. No automatic retry or false completion
was introduced.

## Exact working artifact

```text
SVF SHA256 2f6263c07f225ed51fbfee0439df37ef675dccd90f400936c8a8c4725709f1e0
POF SHA256 449d6a01fdc8be823a00b1c84d47435b33b8ee250266d4e66d95011985f8368c
```

The repository carries the original SVF without modification. The flash
helper binds that exact hash and checks EPM240 ID020a10dd. The ID check cannot
establish package/speed grade or that the whole adapter matches the tested
hardware. See `KNOWN-WORKING.json` and `SHA256SUMS` for local integrity checks.
