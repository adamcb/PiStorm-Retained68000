#!/usr/bin/env python3
"""Read-only MAX II UFM diagnostic reader for PiStorm / Raspberry Pi 3A+.

Use only with the Amiga OFF and the LazarusStorm assembly physically detached,
with the Pi powered from USB. No clock, status-register or bus access is used.
"""
import argparse
import ctypes
import datetime
import json
import mmap
import os
from pathlib import Path
import sys
import time

from retained_diag_decode import decode_record, format_record

VERSION = "retained-diag-jtag-reader-4-pins-C12"
TCK, TMS, TDI, TDO = 26, 24, 27, 25
OUTPUT_PINS = (TCK, TMS, TDI)
JTAG_PINS = OUTPUT_PINS + (TDO,)
OUTPUT_MASK = sum(1 << p for p in OUTPUT_PINS)
EXPECTED_IDCODE = 0x020A10DD
IR_WIDTH = 10
ALLOWED_INSTRUCTIONS = {0x005, 0x3FF, 0x2CC, 0x203, 0x205, 0x201}
UFM_WORDS = 512
IMAGE_MARKERS = {510: 0x4D55, 511: 0xC12C}
# Physical mapping is verified against a separate Quartus MIF/SVF fixture.
WORD_MAPPING = "reverse_16_bits"

TAP = {
    "RESET": ("IDLE", "RESET"), "IDLE": ("IDLE", "SELECT_DR"),
    "SELECT_DR": ("CAPTURE_DR", "SELECT_IR"), "CAPTURE_DR": ("SHIFT_DR", "EXIT1_DR"),
    "SHIFT_DR": ("SHIFT_DR", "EXIT1_DR"), "EXIT1_DR": ("PAUSE_DR", "UPDATE_DR"),
    "PAUSE_DR": ("PAUSE_DR", "EXIT2_DR"), "EXIT2_DR": ("SHIFT_DR", "UPDATE_DR"),
    "UPDATE_DR": ("IDLE", "SELECT_DR"), "SELECT_IR": ("CAPTURE_IR", "RESET"),
    "CAPTURE_IR": ("SHIFT_IR", "EXIT1_IR"), "SHIFT_IR": ("SHIFT_IR", "EXIT1_IR"),
    "EXIT1_IR": ("PAUSE_IR", "UPDATE_IR"), "PAUSE_IR": ("PAUSE_IR", "EXIT2_IR"),
    "EXIT2_IR": ("SHIFT_IR", "UPDATE_IR"), "UPDATE_IR": ("IDLE", "SELECT_DR"),
}


class ReadoutError(RuntimeError):
    pass


def utc_timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def normalise_ufm_word(value):
    if not 0 <= value <= 0xFFFF:
        raise ValueError("UFM word must be unsigned 16-bit")
    if WORD_MAPPING == "lsb_first_value_is_logical_word":
        return value
    if WORD_MAPPING == "reverse_16_bits":
        result = 0
        for bit in range(16):
            result |= ((value >> bit) & 1) << (15 - bit)
        return result
    raise ReadoutError("JTAG/UFM word mapping has not been verified; hardware decode is disabled")


def mmio_read32(mapping, offset):
    return ctypes.c_uint32.from_buffer(mapping, offset).value


def mmio_write32(mapping, offset, value):
    ctypes.c_uint32.from_buffer(mapping, offset).value = value & 0xFFFFFFFF


class MappedGPIO:
    def __init__(self):
        self.mapping = None
        fd = os.open("/dev/gpiomem", os.O_RDWR | os.O_SYNC)
        try:
            self.mapping = mmap.mmap(fd, 4096, flags=mmap.MAP_SHARED,
                                     prot=mmap.PROT_READ | mmap.PROT_WRITE, offset=0)
        finally:
            os.close(fd)

    def read_register(self, index):
        return mmio_read32(self.mapping, index * 4)

    def write_register(self, index, value):
        mmio_write32(self.mapping, index * 4, value)

    def function(self, pin):
        return (self.read_register(pin // 10) >> ((pin % 10) * 3)) & 7

    def set_function(self, pin, function):
        if pin not in JTAG_PINS or not 0 <= function <= 7:
            raise ReadoutError("Refusing unexpected GPIO function change")
        index, shift = pin // 10, (pin % 10) * 3
        current = self.read_register(index)
        self.write_register(index, (current & ~(7 << shift)) | (function << shift))

    def set_bits(self, mask):
        if mask & ~OUTPUT_MASK:
            raise ReadoutError("Refusing unrelated GPIO output change")
        self.write_register(7, mask)

    def clear_bits(self, mask):
        if mask & ~OUTPUT_MASK:
            raise ReadoutError("Refusing unrelated GPIO output change")
        self.write_register(10, mask)

    def read_levels(self):
        return self.read_register(13)

    def close(self):
        if self.mapping is not None:
            self.mapping.close()
            self.mapping = None


class JtagTap:
    def __init__(self, gpio, delay=time.sleep):
        self.gpio, self.delay = gpio, delay
        self.state = "RESET"
        self.instructions = []
        self.dr_scan_counts = {}
        self.clock_count = 0
        self.last_scan = None
        self.initialized = False

    def initialize(self):
        # Set output latches before enabling outputs. TDO is always an input.
        self.gpio.clear_bits(1 << TCK)
        self.gpio.set_bits((1 << TMS) | (1 << TDI))
        self.gpio.set_function(TDO, 0)
        for pin in OUTPUT_PINS:
            self.gpio.set_function(pin, 1)
        self.initialized = True
        self.reset()

    def tick(self, tms, tdi=1):
        self.gpio.clear_bits(1 << TCK)
        self.gpio.set_bits(((1 << TMS) if tms else 0) | ((1 << TDI) if tdi else 0))
        self.gpio.clear_bits(((1 << TMS) if not tms else 0) | ((1 << TDI) if not tdi else 0))
        self.delay(0.000005)
        # JTAG TDO is stable before the rising clock edge; shift occurs on it.
        result = (self.gpio.read_levels() >> TDO) & 1
        self.gpio.set_bits(1 << TCK)
        self.delay(0.000005)
        self.gpio.clear_bits(1 << TCK)
        self.state = TAP[self.state][1 if tms else 0]
        self.clock_count += 1
        return result

    def reset(self):
        for _ in range(6):
            self.tick(1)
        self.state = "RESET"
        self.tick(0)

    def move(self, target):
        queue = [(self.state, [])]
        visited = set()
        while queue:
            state, path = queue.pop(0)
            if state == target:
                for tms in path:
                    self.tick(tms)
                return
            if state in visited:
                continue
            visited.add(state)
            for tms in (0, 1):
                queue.append((TAP[state][tms], path + [tms]))
        raise ReadoutError("No TAP path to " + target)

    def runtest(self, clocks):
        if not 0 <= clocks <= 103:
            raise ReadoutError("Refusing unexpected RUNTEST duration")
        self.move("IDLE")
        for _ in range(clocks):
            self.tick(0)

    def _scan(self, kind, width, value, end_state):
        if width < 1 or not 0 <= value < (1 << width):
            raise ReadoutError("Invalid scan")
        self.move("SHIFT_" + kind)
        result = 0
        self.last_scan = {"kind": kind, "width": width, "received_bits": 0, "tdo": "0x0"}
        for bit in range(width):
            result |= self.tick(bit == width - 1, (value >> bit) & 1) << bit
            self.last_scan.update(received_bits=bit + 1, tdo="0x%X" % result)
        self.move(end_state)
        return result

    def instruction(self, value):
        if value not in ALLOWED_INSTRUCTIONS:
            raise ReadoutError("Instruction is outside the read-only whitelist")
        self.instructions.append("0x%03X" % value)
        # Match the Quartus SVF's ENDIR IRPAUSE. RUNTEST enters IDLE and
        # therefore performs UPDATE_IR before its counted idle clocks.
        return self._scan("IR", IR_WIDTH, value, "PAUSE_IR")

    def data(self, width, value):
        if width not in (13, 16, 64, 240):
            raise ReadoutError("Unexpected DR width")
        self.dr_scan_counts[str(width)] = self.dr_scan_counts.get(str(width), 0) + 1
        return self._scan("DR", width, value, "IDLE")

    def verify_idcode(self):
        self.reset()
        value = self.data(64, (1 << 64) - 1)
        device, padding = value & 0xFFFFFFFF, value >> 32
        if device != EXPECTED_IDCODE or padding != 0xFFFFFFFF:
            raise ReadoutError("Expected one EPM240 IDCODE 0x020A10DD; observed 64-bit chain scan 0x%016X" % value)
        return {"idcode": "0x%08X" % device, "chain_scan_64": "0x%016X" % value,
                "single_device_padding": "0x%08X" % padding}

    def enable_read(self):
        self.instruction(0x005)
        self.runtest(4)
        self.data(240, (1 << 240) - 1)
        self.instruction(0x3FF)
        self.runtest(103)
        self.instruction(0x2CC)
        self.runtest(103)

    def read_ufm(self, destination):
        self.instruction(0x203)
        self.runtest(4)
        self.data(13, 1)  # UFM region, exactly as in the Quartus SVF.
        self.instruction(0x205)
        self.runtest(4)
        for _ in range(UFM_WORDS):
            destination.append(self.data(16, 0xFFFF))

    def disable_read(self):
        self.instruction(0x201)
        self.runtest(103)
        self.instruction(0x3FF)
        self.runtest(100)

    def cleanup_gpio(self):
        if self.initialized:
            self.gpio.clear_bits(1 << TCK)
            self.gpio.set_bits((1 << TMS) | (1 << TDI))
            # Leave all four JTAG pads floating after the TAP is disabled.
            for pin in JTAG_PINS:
                self.gpio.set_function(pin, 0)


def check_platform_and_processes():
    if not sys.platform.startswith("linux"):
        raise ReadoutError("Hardware readout requires Raspberry Pi OS on the Pi 3A+")
    model = Path("/proc/device-tree/model").read_text(errors="replace").rstrip("\x00\n")
    if "Raspberry Pi 3 Model A Plus" not in model:
        raise ReadoutError("This GPIO configuration is restricted to Raspberry Pi 3 Model A Plus; found: " + model)
    conflicts = []
    for item in Path("/proc").iterdir():
        if not item.name.isdigit() or int(item.name) == os.getpid():
            continue
        try:
            argv = (item / "cmdline").read_bytes().split(b"\0")
            names = [os.path.basename(a.decode(errors="replace")) for a in argv[:2] if a]
            if any(name in ("emulator", "pistormflash", "openocd", "pigpiod", "read_retained_diag_jtag.py") for name in names):
                conflicts.append({"pid": int(item.name), "names": names})
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    if conflicts:
        raise ReadoutError("Stop emulator/JTAG/GPIO-control processes before readout: " + json.dumps(conflicts))
    return model


def save_report(path, report):
    with Path(path).open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(report, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--disconnected", action="store_true", help="Confirm Amiga OFF, assembly physically detached, Pi USB-powered only")
    parser.add_argument("--decode", metavar="HEX_WORD", nargs=2, help="Decode two logical hexadecimal words without GPIO")
    parser.add_argument("--output", help="New JSON report path; defaults to a timestamped file for hardware readout")
    parser.add_argument("--json", action="store_true", help="Print complete JSON rather than the text interpretation")
    parser.add_argument("--preflight", action="store_true", help="After flashing, require the correct image markers and a blank record before the Amiga trial")
    args = parser.parse_args(argv)
    if args.decode and args.preflight:
        parser.error("--preflight requires a full hardware UFM read, not --decode")
    report = {"tool_version": VERSION, "created_utc": utc_timestamp(), "mode": "decode" if args.decode else "hardware_jtag",
              "readout_success": False, "word_mapping": WORD_MAPPING, "image_identity_verified": False}
    output_path = args.output
    if args.decode:
        try:
            report["record"] = decode_record([int(word, 16) for word in args.decode])
            report["image_identity_verified"] = False
            report["offline_decode_limitation"] = "Two supplied words cannot verify the image markers; offline classification is not an image/readout qualification"
            report["readout_success"] = report["record"]["classification"] != "unrecognized"
            if not report["readout_success"]:
                report["readout_error"] = "Record header is not the pin-focused C12 format; old D-format records are not interpreted"
        except ValueError as error:
            parser.error(str(error))
    else:
        if not args.disconnected:
            parser.error("Hardware readout requires --disconnected: Amiga OFF, assembly physically detached, Pi USB-powered only")
        if output_path is None:
            output_path = "retained-diag-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".json"
        gpio = tap = None
        isc_entered = False
        raw_reads = []
        report["safety_confirmation"] = "User supplied --disconnected: Amiga off, assembly detached, Pi USB-powered only"
        try:
            normalise_ufm_word(0)  # Mapping must be established before touching GPIO.
            report["device_model"] = check_platform_and_processes()
            gpio = MappedGPIO()
            tap = JtagTap(gpio)
            tap.initialize()
            report["jtag_device"] = tap.verify_idcode()
            # Mark entry before the sequence so cleanup also covers an error
            # immediately after ISC_ENABLE was shifted.
            isc_entered = True
            tap.enable_read()
            for _ in range(2):
                words = []
                raw_reads.append(words)
                tap.read_ufm(words)
            if raw_reads[0] != raw_reads[1]:
                raise ReadoutError("Two full UFM reads disagreed; raw reads have been preserved")
            logical = [normalise_ufm_word(word) for word in raw_reads[0]]
            report["logical_ufm_words"] = ["0x%04X" % word for word in logical]
            report["nonblank_word_offsets_after_record"] = [index for index, word in enumerate(logical) if index >= 2 and word != 0xFFFF]
            report["reads_identical"] = True
            markers_valid = all(logical[index] == expected for index, expected in IMAGE_MARKERS.items())
            report["image_identity_verified"] = markers_valid
            report["image_identity_scope"] = "Known diagnostic-format UFM markers only; not a full configuration-flash hash verification"
            report["image_markers"] = [{"word_offset": index, "expected": "0x%04X" % expected,
                                        "observed": "0x%04X" % logical[index], "match": logical[index] == expected}
                                       for index, expected in IMAGE_MARKERS.items()]
            if not markers_valid:
                raise ReadoutError("Diagnostic image markers do not match; image, UFM access or serialization mapping is unrecognized. Do not interpret this as a blank record")
            report["record"] = decode_record(logical[:2])
            if report["record"]["classification"] == "unrecognized":
                raise ReadoutError("Record header is not the pin-focused C12 format; old D-format records are not interpreted")
            report["preflight_requested"] = args.preflight
            if args.preflight:
                report["preflight_passed"] = report["record"]["classification"] == "blank"
                if not report["preflight_passed"]:
                    raise ReadoutError("Preflight expected a blank record immediately after flashing; the two record words are already nonblank")
            report["readout_success"] = True
        except (OSError, ReadoutError, KeyboardInterrupt) as error:
            report["readout_error"] = str(error) or "Interrupted"
        finally:
            report["raw_jtag_reads"] = [["0x%04X" % word for word in words] for words in raw_reads]
            cleanup_errors = []
            if tap is not None:
                report["scan_at_end_of_readout"] = dict(tap.last_scan) if tap.last_scan else None
                if isc_entered:
                    try:
                        tap.disable_read()
                    except (OSError, ReadoutError) as error:
                        cleanup_errors.append("ISC_DISABLE/BYPASS: " + str(error))
                try:
                    tap.cleanup_gpio()
                except (OSError, ReadoutError) as error:
                    cleanup_errors.append("GPIO cleanup: " + str(error))
                report["jtag_trace"] = {"instructions": tap.instructions, "dr_scan_counts": tap.dr_scan_counts,
                                        "clock_count": tap.clock_count, "last_scan": tap.last_scan}
            if gpio is not None:
                gpio.close()
            if cleanup_errors:
                report["cleanup_errors"] = cleanup_errors
                report["readout_success"] = False
    if output_path:
        try:
            save_report(output_path, report)
        except OSError as error:
            report["report_save_error"] = str(error)
            print(json.dumps(report, indent=2))
            print("Could not create report file; JSON evidence is printed above: " + str(error), file=sys.stderr)
            return 1
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("Retained-68000 read-only JTAG/UFM diagnostic readout")
        if "image_identity_verified" in report:
            print("Diagnostic image markers: " + ("verified" if report["image_identity_verified"] else "not verified"))
        if report.get("record"):
            print(format_record(report["record"]))
        if report.get("readout_error"):
            print("Readout failed: " + report.get("readout_error", "unknown error"))
        if output_path:
            print("JSON report: " + str(output_path))
        if report.get("cleanup_errors"):
            print("Cleanup issue: " + "; ".join(report["cleanup_errors"]))
    return 0 if report["readout_success"] else 1


if __name__ == "__main__":
    sys.exit(main())
