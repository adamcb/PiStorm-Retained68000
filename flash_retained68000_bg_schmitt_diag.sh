#!/bin/bash
# Experimental BG Schmitt diagnostic, Original-based retained-68000 image.
# Intended hardware: classic PiStorm, EPM240T100I5N, 74LVC16374, Pi3A+.
# JTAG ID checks EPM240 family; it cannot verify package or speed grade.
# Raspberry Pi OS: run as normal user, without sudo.
# Keep the complete LazarusStorm/PiStorm/Pi assembly disconnected from the
# Amiga while USB powered. The motherboard 68000 can remain in the Amiga.
# Native motherboard 68000 MUST be installed for running BG Schmitt diagnostic (native E/BG inputs).
set -euo pipefail
cd -- "$(dirname -- "$0")"

image='./rtl/EPM240_retained68000_bg_schmitt_diag.svf'
image_version='retained68000-bg-schmitt-diagnostic-20261030'
# Bound to selected BRJP-open correction snapshot 20261030T152114208Z-7b579606.
expected='2f6263c07f225ed51fbfee0439df37ef675dccd90f400936c8a8c4725709f1e0'

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    fail 'BG Schmitt diagnostic image hash has not been finalized; nothing was programmed.'
fi
if (( EUID == 0 )); then
    fail 'Run this script as the normal Pi user, without sudo.'
fi
for required in pgrep sha256sum awk; do
    command -v "$required" >/dev/null 2>&1 ||
        fail "Required command is missing: $required"
done
if pgrep -x emulator >/dev/null; then
    fail 'Stop the PiStorm emulator before flashing.'
else
    pgrep_status=$?
    if (( pgrep_status != 1 )); then
        fail 'Could not check emulator processes; nothing was programmed.'
    fi
fi
if [[ ! -x ./pistormflash ]]; then
    fail 'Missing executable ./pistormflash in this checkout.'
fi
if [[ ! -f "$image" ]]; then
    fail "Missing exact-case image: $image"
fi

if ! actual=$(sha256sum -- "$image" | awk '{print $1}'); then
    fail 'Could not hash the BG Schmitt diagnostic image; nothing was programmed.'
fi
if [[ "$actual" != "$expected" ]]; then
    fail 'BG Schmitt diagnostic image SHA256 mismatch; nothing was programmed.'
fi
if ! detection=$(./pistormflash -c 2>/dev/null); then
    fail 'CPLD detection failed; nothing was programmed.'
fi
id=$(printf '%s\n' "$detection" | awk -F, 'NR == 1 {print $1}')
if [[ "$id" != 'idcode=0x020a10dd' ]]; then
    fail "BG Schmitt diagnostic requires EPM240, ID0x020a10dd. Detected: $id"
fi

printf '%s\n' 'BG Schmitt diagnostic REQUIRES the motherboard 68000 installed when running on the Amiga.'
printf '%s\n' 'Save the existing diagnostic JSON BEFORE this full-device flash; the old UFM record will be cleared.'
printf '%s\n' 'Keep BRJP OPEN; do not bridge it. The original CPU must remain installed for the Amiga trial.'
printf 'Flashing experimental %s\nImage %s\nSHA256 %s\n' \
    "$image_version" "$image" "$actual"
if ./pistormflash -s "$image"; then
    printf '%s\n' \
        'CPLD flashed successfully!' \
        'MANDATORY: while still detached, perform a blank-record hardware preflight before reconnecting.' \
        'Use a fresh report filename. From this checkout run:' \
        'sudo python3 diagnostic-brjp-pins-readout/read_retained_diag_jtag.py --disconnected --preflight --output diagnostic-preflight-bg-schmitt-1.json' \
        'Require verified markers, blank record and exit status0. Keep the JSON.' \
        'After one trial, detach again and read with a fresh filename:' \
        'sudo python3 diagnostic-brjp-pins-readout/read_retained_diag_jtag.py --disconnected --output diagnostic-bg-schmitt-result-1.json' \
        'Shut down Linux and disconnect USB before reconnecting to the unpowered Amiga.'
else
    fail 'Flashing failed. Keep the assembly disconnected until recovery succeeds.'
fi
