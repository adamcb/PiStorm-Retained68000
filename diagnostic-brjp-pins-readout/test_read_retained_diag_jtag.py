#!/usr/bin/env python3
"""Read-only JTAG sequence and decoder tests with a TAP/GPIO model."""
import contextlib
import io
import json
from pathlib import Path
import random
import unittest
from unittest import mock
import uuid

import read_retained_diag_jtag as diag
from retained_diag_decode import decode_record


def words_for(snapshot):
    first = 0xC000 | (snapshot & 0xFFF)
    return [first, first ^ 0xFFFF]


def image_words(record=None):
    words = [0xFFFF] * 512
    if record is not None:
        words[:2] = record
    for index, expected in diag.IMAGE_MARKERS.items():
        words[index] = expected
    return words


class FakeGPIO:
    """Models a single EPM240 TAP and only the whitelisted register actions."""
    def __init__(self, words=None, idcode=diag.EXPECTED_IDCODE, extra_device=None):
        self.words = list(words or [0xFFFF] * 512)
        self.output = 0
        self.functions = {pin: 0 for pin in diag.JTAG_PINS}
        self.state = "RESET"
        self.instruction = 0x006
        self.shift = 0
        self.shift_width = 1
        self.shifted = 0
        self.idcode = idcode
        self.extra_device = extra_device
        self.ufm_index = 0
        self.region = None
        self.instructions = []
        self.address_writes = []
        self.isc_enabled = False
        self.dr_widths = []
        self.read_count = 0
        self.fail_read_after = None

    def function(self, pin):
        return self.functions[pin]

    def close(self):
        pass

    def set_function(self, pin, function):
        if pin not in diag.JTAG_PINS:
            raise AssertionError("Touched a non-JTAG GPIO")
        if pin == diag.TDO and function != 0:
            raise AssertionError("Drove TDO")
        self.functions[pin] = function

    def set_bits(self, mask):
        if mask & ~diag.OUTPUT_MASK:
            raise AssertionError("Touched a non-JTAG output")
        old = self.output
        self.output |= mask
        if not old & (1 << diag.TCK) and self.output & (1 << diag.TCK):
            if any(self.functions[pin] != 1 for pin in diag.OUTPUT_PINS):
                raise AssertionError("Clocked without JTAG outputs")
            self.rising((self.output >> diag.TMS) & 1, (self.output >> diag.TDI) & 1)

    def clear_bits(self, mask):
        if mask & ~diag.OUTPUT_MASK:
            raise AssertionError("Touched a non-JTAG output")
        self.output &= ~mask

    def read_levels(self):
        self.read_count += 1
        if self.fail_read_after is not None and self.read_count >= self.fail_read_after:
            raise OSError("Injected GPIO read failure")
        return ((self.shift & 1) << diag.TDO) if self.state in ("SHIFT_IR", "SHIFT_DR") else 0

    def rising(self, tms, tdi):
        old = self.state
        if old == "CAPTURE_IR":
            self.shift, self.shift_width, self.shifted = 1, diag.IR_WIDTH, 0
        elif old == "CAPTURE_DR":
            self.shifted = 0
            if self.instruction == 0x006:
                self.shift_width = 32 if self.extra_device is None else 64
                self.shift = self.idcode | ((self.extra_device or 0) << 32)
            elif self.instruction == 0x005:
                self.shift_width, self.shift = 240, 0
            elif self.instruction == 0x203:
                self.shift_width, self.shift = 13, 0
            elif self.instruction == 0x205:
                if not self.isc_enabled or self.region != 1:
                    raise AssertionError("UFM read not enabled or wrong region")
                self.shift_width, self.shift = 16, self.words[self.ufm_index]
            else:
                raise AssertionError("Unsupported DR scan for instruction %03X" % self.instruction)
        elif old in ("SHIFT_IR", "SHIFT_DR"):
            self.shift = (self.shift >> 1) | (tdi << (self.shift_width - 1))
            self.shifted += 1
        elif old == "UPDATE_IR":
            if self.shift not in diag.ALLOWED_INSTRUCTIONS:
                raise AssertionError("Non-read-only IR instruction")
            self.instruction = self.shift
            self.instructions.append(self.instruction)
            if self.instruction == 0x2CC:
                self.isc_enabled = True
            elif self.instruction == 0x201:
                self.isc_enabled = False
        elif old == "UPDATE_DR":
            self.dr_widths.append((self.instruction, self.shifted))
            if self.instruction == 0x203:
                if self.shift != 1:
                    raise AssertionError("Address register selected a region other than UFM")
                self.region, self.ufm_index = self.shift, 0
                self.address_writes.append(self.shift)
            elif self.instruction == 0x205:
                self.ufm_index += 1
        self.state = diag.TAP[self.state][tms]
        if self.state == "RESET":
            self.instruction = 0x006


class JtagTests(unittest.TestCase):
    def make_tap(self, gpio=None):
        gpio = gpio or FakeGPIO()
        tap = diag.JtagTap(gpio, delay=lambda _: None)
        tap.initialize()
        return tap, gpio

    def test_single_device_idcode(self):
        tap, _ = self.make_tap()
        self.assertEqual(tap.verify_idcode()["idcode"], "0x020A10DD")

    def test_wrong_idcode_never_enables_isc(self):
        tap, gpio = self.make_tap(FakeGPIO(idcode=0x020A20DD))
        with self.assertRaisesRegex(diag.ReadoutError, "Expected one EPM240"):
            tap.verify_idcode()
        self.assertNotIn(0x2CC, gpio.instructions)

    def test_extra_chain_device_rejected(self):
        tap, gpio = self.make_tap(FakeGPIO(extra_device=0x12345679))
        with self.assertRaises(diag.ReadoutError):
            tap.verify_idcode()
        self.assertNotIn(0x2CC, gpio.instructions)

    def test_all_whitelisted_instructions_and_exact_dr_widths(self):
        rng = random.Random(0xD16A)
        words = [rng.randrange(65536) for _ in range(512)]
        tap, gpio = self.make_tap(FakeGPIO(words))
        tap.verify_idcode()
        tap.enable_read()
        first, second = [], []
        tap.read_ufm(first)
        tap.read_ufm(second)
        tap.disable_read()
        self.assertEqual(first, words)
        self.assertEqual(second, words)
        self.assertEqual(gpio.address_writes, [1, 1])
        self.assertFalse(gpio.isc_enabled)
        self.assertTrue(set(gpio.instructions) <= diag.ALLOWED_INSTRUCTIONS)
        self.assertEqual(gpio.instructions, [0x005, 0x3FF, 0x2CC, 0x203, 0x205, 0x203, 0x205, 0x201, 0x3FF])
        self.assertEqual(tap.dr_scan_counts, {"64": 1, "240": 1, "13": 2, "16": 1024})
        self.assertIn((0x006, 64), gpio.dr_widths)
        self.assertIn((0x005, 240), gpio.dr_widths)
        self.assertTrue(all(width == 16 for ir, width in gpio.dr_widths if ir == 0x205))
        self.assertTrue(all(width == 13 for ir, width in gpio.dr_widths if ir == 0x203))
        tap.cleanup_gpio()
        self.assertTrue(all(gpio.functions[pin] == 0 for pin in diag.JTAG_PINS))
        self.assertEqual(gpio.output & (1 << diag.TCK), 0)

    def test_program_and_erase_instructions_rejected_before_clocks(self):
        tap, gpio = self.make_tap()
        count = tap.clock_count
        for instruction in (0x2F2, 0x2F4, 0x000, 0x006, 0x204):
            with self.assertRaisesRegex(diag.ReadoutError, "whitelist"):
                tap.instruction(instruction)
        self.assertEqual(tap.clock_count, count)
        self.assertEqual(gpio.instructions, [])

    def test_no_arbitrary_dr_width_or_runtest(self):
        tap, _ = self.make_tap()
        for width in (0, 1, 32, 8192):
            with self.assertRaises(diag.ReadoutError):
                tap.data(width, 0)
        with self.assertRaises(diag.ReadoutError):
            tap.runtest(50003)

    def test_partial_read_preserved(self):
        tap, gpio = self.make_tap()
        tap.verify_idcode()
        tap.enable_read()
        words = []
        gpio.fail_read_after = gpio.read_count + 200
        with self.assertRaises(OSError):
            tap.read_ufm(words)
        self.assertGreater(len(words), 0)
        self.assertLess(len(words), 512)
        self.assertIsNotNone(tap.last_scan)
        gpio.fail_read_after = None
        tap.disable_read()
        tap.cleanup_gpio()
        self.assertFalse(gpio.isc_enabled)

    def test_tap_routes_do_not_enter_reset_between_reads(self):
        tap, gpio = self.make_tap()
        tap.verify_idcode()
        tap.enable_read()
        words = []
        tap.read_ufm(words)
        self.assertTrue(gpio.isc_enabled)
        self.assertEqual(gpio.instruction, 0x205)
        self.assertEqual(gpio.state, "IDLE")


class DecoderTests(unittest.TestCase):
    def test_official_quartus_word_mapping_sentinels(self):
        fixture = json.loads((Path(__file__).parent / "word-mapping-evidence.json").read_text())
        self.assertEqual(fixture["wordsVerified"], 512)
        for sentinel in fixture["sentinels"]:
            self.assertEqual(diag.normalise_ufm_word(int(sentinel["jtag"], 16)), int(sentinel["logical"], 16))

    def test_bit_reverse_is_not_applied_to_idcode(self):
        self.assertNotEqual(diag.normalise_ufm_word(0x10DD), 0x10DD)
        tap, _ = JtagTests().make_tap()
        self.assertEqual(tap.verify_idcode()["idcode"], "0x020A10DD")

    def test_blank_partial_unrecognized_committed(self):
        for words, expected in (([0xFFFF] * 2, "blank"), ([0xC123, 0xFFFF], "partial"),
                                ([0, 0], "unrecognized"), ([0xC123, 0x3EDC], "committed")):
            self.assertEqual(decode_record(words)["classification"], expected)

    def test_zero_event_mask_unresolved(self):
        record = decode_record(words_for(1 << 10))
        self.assertTrue(record["raw_event_latches_present"])
        self.assertEqual(record["event_pin_mask"], 0)
        self.assertEqual(record["latched_condition_names"], [])
        self.assertIn("unresolved", record["pin_mask_interpretation"])
        self.assertEqual(set(record["sampled_input_levels"]), {"/VPA"})
        self.assertEqual(record["event_order"], "not_recorded")

    def test_payload_bit_round_trip_100(self):
        rng = random.Random(0xD16A)
        for _ in range(100):
            value = rng.randrange(1 << 12)
            self.assertEqual(decode_record(words_for(value))["snapshot_hex"], "0x%03X" % value)

    def test_every_flag_and_level(self):
        record = decode_record(words_for(1 << 9))
        self.assertTrue(record["flags"]["owned"])
        for bit, name in {3: "/BG high", 2: "/BGACK low", 1: "/BERR low"}.items():
            record = decode_record(words_for(1 << bit))
            self.assertTrue(record["latched_raw_conditions"][name])
            self.assertEqual(sum(record["latched_raw_conditions"].values()), 1)
        self.assertEqual(decode_record(words_for(1))["sampled_input_levels"], {"/VPA": 1})

    def test_all_eight_event_mask_combinations(self):
        for mask in range(8):
            with self.subTest(mask=mask):
                record = decode_record(words_for((1 << 10) | (mask << 1)))
                self.assertEqual(record["event_pin_mask"], mask)
                self.assertEqual(record["latched_raw_conditions"], {
                    "/BG high": bool(mask & 4), "/BGACK low": bool(mask & 2), "/BERR low": bool(mask & 1)})
                self.assertEqual(len(record["latched_condition_names"]), mask.bit_count())
                self.assertEqual(record["event_order"], "not_recorded")
                self.assertFalse(record["single_pin_cause_proven"])

    def test_multiple_flags_do_not_identify_first(self):
        record = decode_record(words_for((1 << 10) | (7 << 1)))
        self.assertIn("Multiple", record["pin_mask_interpretation"])
        self.assertIn("order", record["pin_mask_interpretation"])
        self.assertEqual(record["event_order"], "not_recorded")
        self.assertNotIn("first_pin", record)

    def test_single_flag_is_not_physical_root_cause_proof(self):
        record = decode_record(words_for((1 << 10) | (4 << 1)))
        self.assertEqual(record["latched_condition_names"], ["/BG high"])
        self.assertFalse(record["single_pin_cause_proven"])
        self.assertIn("physical cause", record["pin_mask_interpretation"])
        berr = decode_record(words_for((1 << 10) | (1 << 1)))
        self.assertEqual(berr["latched_condition_names"], ["/BERR low"])
        self.assertFalse(berr["berr_flag_proves_arbitration_loss"])
        self.assertIn("CPLD logical", berr["pin_identity_scope"])
        self.assertIn("ordinary bus cycle", berr["meaning"])
        self.assertIn("not proof", berr["meaning"])

    def test_old_AS_DTACK_E_levels_are_not_exposed(self):
        record = decode_record(words_for(0xFFF))
        self.assertEqual(set(record["sampled_input_levels"]), {"/VPA"})
        self.assertNotIn("/AS", record["sampled_input_levels"])
        self.assertNotIn("/DTACK", record["sampled_input_levels"])
        self.assertNotIn("E", record["sampled_input_levels"])

    def test_causes_and_state_ranges(self):
        for cause in range(4):
            self.assertEqual(decode_record(words_for(cause << 10))["cause"]["code"], cause)
        for state in range(4):
            self.assertEqual(decode_record(words_for(state << 7))["main_state"]["code"], state)
        for state in range(8):
            self.assertEqual(decode_record(words_for(state << 4))["peripheral_state"]["code"], state)

    def test_uncommitted_payload_not_interpreted(self):
        for words in ([0xC123, 0xFFFF], [0xC123, 0x3EDD], [0xD123, 0x2EDC]):
            self.assertNotIn("flags", decode_record(words))

    def test_any_single_bit_change_rejected(self):
        words = words_for(0x623)
        for index in range(2):
            for bit in range(16):
                changed = list(words)
                changed[index] ^= 1 << bit
                record = decode_record(changed)
                self.assertNotEqual(record["classification"], "committed")
                self.assertNotIn("flags", record)

    def test_paired_corruption_limitation_is_explicit(self):
        words = words_for(0x623)
        words[0] ^= 1
        words[1] ^= 1
        record = decode_record(words)
        self.assertEqual(record["classification"], "committed")
        self.assertTrue(any("paired" in text for text in record["limitations"]))

    def test_invalid_inputs(self):
        for words in ([], [0], [0, 0, 0], [-1, 0], [65536, 0]):
            with self.assertRaises(ValueError):
                decode_record(words)


class CliTests(unittest.TestCase):
    def run_fake_hardware(self, logical, preflight=False):
        raw = [diag.normalise_ufm_word(word) for word in logical]
        gpio = FakeGPIO(raw)
        target = Path(__file__).resolve().parent / ("test-result-" + uuid.uuid4().hex + ".json")
        tap_class = diag.JtagTap
        try:
            arguments = ["--disconnected", "--output", str(target)] + (["--preflight"] if preflight else [])
            with mock.patch.object(diag, "MappedGPIO", return_value=gpio), \
                 mock.patch.object(diag, "check_platform_and_processes", return_value="Raspberry Pi 3 Model A Plus Rev 1.0"), \
                 mock.patch.object(diag, "JtagTap", side_effect=lambda g: tap_class(g, delay=lambda _: None)), \
                 contextlib.redirect_stdout(io.StringIO()):
                result = diag.main(arguments)
            return result, json.loads(target.read_text()), gpio
        finally:
            target.unlink(missing_ok=True)

    def test_valid_markers_and_blank_preflight(self):
        result, report, _ = self.run_fake_hardware(image_words(), preflight=True)
        self.assertEqual(result, 0)
        self.assertTrue(report["image_identity_verified"])
        self.assertTrue(report["preflight_passed"])
        self.assertEqual(report["record"]["classification"], "blank")

    def test_all_erased_memory_is_not_reported_as_blank_image(self):
        result, report, _ = self.run_fake_hardware([0xFFFF] * 512)
        self.assertEqual(result, 1)
        self.assertFalse(report["image_identity_verified"])
        self.assertNotIn("record", report)
        self.assertIn("markers", report["readout_error"])
        self.assertEqual(len(report["raw_jtag_reads"][0]), 512)

    def test_wrong_marker_preserves_raw_without_decoding(self):
        words = image_words(words_for(0x623))
        words[511] ^= 1
        result, report, _ = self.run_fake_hardware(words)
        self.assertEqual(result, 1)
        self.assertFalse(report["image_identity_verified"])
        self.assertNotIn("record", report)
        self.assertFalse(report["image_markers"][1]["match"])

    def test_old_D12C_marker_rejected_before_record_decode(self):
        words = image_words(words_for(0x704))
        words[511] = 0xD12C
        result, report, _ = self.run_fake_hardware(words)
        self.assertEqual(result, 1)
        self.assertFalse(report["image_identity_verified"])
        self.assertNotIn("record", report)
        self.assertEqual(report["image_markers"][1]["expected"], "0xC12C")
        self.assertEqual(report["image_markers"][1]["observed"], "0xD12C")

    def test_old_D_header_rejected_with_valid_new_markers(self):
        result, report, _ = self.run_fake_hardware(image_words([0xD704, 0x28FB]))
        self.assertEqual(result, 1)
        self.assertTrue(report["image_identity_verified"])
        self.assertEqual(report["record"]["classification"], "unrecognized")
        self.assertNotIn("flags", report["record"])
        self.assertIn("C12", report["readout_error"])

    def test_offline_old_D_header_is_not_interpreted(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = diag.main(["--decode", "D704", "28FB", "--json"])
        report = json.loads(output.getvalue())
        self.assertEqual(result, 1)
        self.assertEqual(report["record"]["classification"], "unrecognized")
        self.assertNotIn("event_pin_mask", report["record"])

    def test_preflight_nonblank_record_fails_but_preserves_decode(self):
        result, report, _ = self.run_fake_hardware(image_words(words_for(0x623)), preflight=True)
        self.assertEqual(result, 1)
        self.assertTrue(report["image_identity_verified"])
        self.assertFalse(report["preflight_passed"])
        self.assertEqual(report["record"]["classification"], "committed")

    def test_complete_hardware_flow_fake_gpio(self):
        logical = image_words(words_for(0x623))
        raw = [diag.normalise_ufm_word(word) for word in logical]
        gpio = FakeGPIO(raw)
        target = Path(__file__).resolve().parent / ("test-result-" + uuid.uuid4().hex + ".json")
        tap_class = diag.JtagTap
        try:
            with mock.patch.object(diag, "MappedGPIO", return_value=gpio), \
                 mock.patch.object(diag, "check_platform_and_processes", return_value="Raspberry Pi 3 Model A Plus Rev 1.0"), \
                 mock.patch.object(diag, "JtagTap", side_effect=lambda g: tap_class(g, delay=lambda _: None)), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(diag.main(["--disconnected", "--output", str(target)]), 0)
            report = json.loads(target.read_text())
            self.assertTrue(report["reads_identical"])
            self.assertEqual(report["record"]["snapshot_hex"], "0x623")
            self.assertEqual(len(report["raw_jtag_reads"]), 2)
            self.assertEqual(len(report["raw_jtag_reads"][0]), 512)
            self.assertEqual(report["nonblank_word_offsets_after_record"], [510, 511])
            self.assertTrue(report["image_identity_verified"])
            self.assertFalse(gpio.isc_enabled)
            self.assertTrue(all(gpio.functions[pin] == 0 for pin in diag.JTAG_PINS))
        finally:
            target.unlink(missing_ok=True)

    def test_wrong_id_hardware_flow_preserves_error_and_never_isc(self):
        gpio = FakeGPIO(idcode=0xFFFFFFFF)
        target = Path(__file__).resolve().parent / ("test-result-" + uuid.uuid4().hex + ".json")
        tap_class = diag.JtagTap
        try:
            with mock.patch.object(diag, "MappedGPIO", return_value=gpio), \
                 mock.patch.object(diag, "check_platform_and_processes", return_value="Raspberry Pi 3 Model A Plus Rev 1.0"), \
                 mock.patch.object(diag, "JtagTap", side_effect=lambda g: tap_class(g, delay=lambda _: None)), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(diag.main(["--disconnected", "--output", str(target)]), 1)
            report = json.loads(target.read_text())
            self.assertFalse(report["readout_success"])
            self.assertIn("IDCODE", report["readout_error"])
            self.assertEqual(gpio.instructions, [])
            self.assertEqual(report["raw_jtag_reads"], [])
            self.assertTrue(all(gpio.functions[pin] == 0 for pin in diag.JTAG_PINS))
        finally:
            target.unlink(missing_ok=True)

    def test_hardware_confirmation_required_before_gpio(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            diag.main([])
        self.assertEqual(raised.exception.code, 2)

    def test_decode_does_not_require_gpio(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(diag.main(["--decode", "C123", "3EDC", "--json"]), 0)
        self.assertEqual(json.loads(output.getvalue())["record"]["classification"], "committed")
        self.assertFalse(json.loads(output.getvalue())["image_identity_verified"])

    def test_report_not_overwritten(self):
        target = Path(__file__).resolve().parent / ("test-result-" + uuid.uuid4().hex + ".json")
        try:
            target.write_text("previous evidence", encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(diag.main(["--decode", "FFFF", "FFFF", "--output", str(target)]), 1)
            self.assertEqual(target.read_text(), "previous evidence")
            self.assertEqual(json.loads(output.getvalue())["record"]["classification"], "blank")
        finally:
            target.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
