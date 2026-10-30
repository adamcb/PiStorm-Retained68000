# Design and provenance

## Intended use

This is a fixed-owner retained-CPU firmware for a classic PiStorm on
LazarusStorm. The motherboard 68000 remains powered and supplies E and BG,
while LazarusStorm holds its native bus request low. CPU selection would
require separately engineered hardware and isolation; this image does not
control the native R1 pull-down or provide live switching.

The retained-CPU controller derives from the identified historical PiStorm
Original source at commit `75bbc70be87a8f63f02ce6a57f23f5fb1d9c5787`.
Its native-clock bus engine was adapted for input-only E/BG, native-E
peripheral sequencing, fixed-owner qualification, delayed completion and the
LazarusStorm open-BRJP topology. A one-shot pin diagnostic was then added.

The published 2021 Long Hold programming image helped identify a useful
hardware comparison, but its exact matching editable source was not recovered.
This project is therefore not described as "Long Hold plus a patch".

## BRJP and ownership

With BRJP open, LazarusStorm has two separate BR nets:

| Net | Connection |
|---|---|
| Native CPU BR | Amiga expansion60, through R1 to ground |
| PiStorm connector BR | External 64-pin connector13, through R2 to +5V |

The tested adapter's R1 was reported as a zero-ohm part. The published BOM's
different R1 value must not be substituted as a measurement of that board.
Requiring the isolated PiStorm-side BR input low prevented earlier candidates
from acquiring the bus. The supplied firmware removes that wrong prerequisite
and keeps the input unused. BRJP stays open.

The firmware qualifies grant and bus-idle conditions before enabling its bus
drivers. E and BG are never push-pull outputs. Reset, grant/error withdrawal
and latched-fault handling remain active. An uncertain transaction is not
reported complete or automatically replayed.

## BG receiver

The successful image differs from the preceding pin diagnostic by one
electrical assignment:

```tcl
set_instance_assignment -name IO_STANDARD "3.3V SCHMITT TRIGGER INPUT" -to M68K_BG_n
```

This selects a MAX II input buffer with hysteresis. It is not a timed digital
debounce, a guaranteed rejection of every narrow pulse, or removal of the
grant guard. It cannot repair an open connection or an actual loss of grant.
The [MAX II handbook](https://docs.altera.com/api/khub/documents/EVNBSY8oxDghXeEwnyVZvQ/content)
documents Schmitt inputs in the architecture section and hysteresis/input-delay
characteristics in the electrical section.

Success with this image supports BG input conditioning as an effective
change on the tested assembly. It does not isolate the precise electrical
source of the earlier indication; the fitted image also changed.

## Checked BG path

The supplied QSF uses BG71 and BGACK70. Published ASCII PCB and fabrication
copper agree with those assignments. A published schematic PDF instead has
a one-pin offset in this group, so it must not be used to silently remap the
image.

| Published PCB segment | Role |
|---|---|
| PiStorm connector11 to U7.11 | BG socket side |
| U7 channel11/10 | Powered SN74CBTD3384 switch channel |
| U7.10 to CPLD U4.71 | BG receiver side |
| Connector12 to U7.8; U7.9 to U4.70 | Published BGACK path |

On the user's board, connector11 to U7.11 and U7.10 to actual CPLD71 both
measured near zero. Native CPU11 through the assembled adapter to U7.11 was
reported as 0.6 ohm. These check copper and contacts; they do not measure the
powered switch's analog behavior. Unpowered continuity through U7 itself is
not expected. BGACK's actual-board path was not separately measured.

## Diagnostics

The C12 logger records a reason, owned flag, controller states, sticky
BG-high/BGACK-low/BERR-low observations and a VPA sample. It does not store
address/data, AS/DTACK/E history, timestamps or waveforms. A logical BG-high
observation is not proof of a particular physical CPU transition or of which
electrical effect caused it. BERR can also be a bus-error cycle termination.

The logger watches the controller without feeding the functional bus, reset
or completion equations. It programs at most one two-word committed record
until the user flash is erased by a later flash. No erase or retry operation
is implemented by the runtime logger. Its dedicated oscillator remains
enabled. The source uses 238/240 logic elements, including diagnostics.

## Source identity

The original diagnostic top remains byte-identical in this working image:

```text
pistorm.v         11505ca4d1e04e2cd23f665cf465347056e425423f53d8022585c0b0d1c96b4d
diagnostic_ufm.v  d872cbd488da372cd3ef24be11cc1ee082d46cacf0bffaf57b88e704a9c9ccb8
diagnostic.mif    b138e20696719c9ac2d9f41c5df8e09a0d59083574e69545818514e5904b53f9
```

The source is supplied under `firmware/`. The public build wrapper removes
the original workstation-only path restriction; RTL, constraints and fitted
pin assignments remain unchanged. No new FPGA image was built for publishing.
