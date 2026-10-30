# SPDX-License-Identifier: MIT
"""Decode the C12 pin-focused two-word retained-68000 UFM record."""


def decode_record(words):
    if len(words) != 2 or any(not isinstance(x, int) or not 0 <= x <= 0xFFFF for x in words):
        raise ValueError("Exactly two unsigned 16-bit words are required")
    result = {
        "raw_words": ["0x%04X" % word for word in words],
        "format": "retained68000-complement-pins12-v2",
        "classification": None,
        "limitations": [
            "C12 format markers and a C header identify this record format, not a complete CPLD configuration hash.",
            "This is the first eligible observation and may precede the visible hang; it does not prove the hang's cause.",
            "Per-input flags latch qualified conditions. They are not waveforms, simultaneous level samples, or proof of temporal order.",
            "Zero or multiple pin flags are possible. A zero mask leaves a raw event unresolved; multiple flags do not identify which condition came first.",
            "A single latched condition does not establish its physical cause or prove it initiated the visible hang.",
            "No /AS, /DTACK or E samples, addresses, transfer data, timestamps or E-edge history are stored in this format.",
            "Pin labels refer to CPLD logical inputs under the selected historical QSF; this record does not establish their mapping to native CPU physical pins.",
            "A /BERR-low observation can be a bus-error termination of an ordinary cycle; it is not by itself proof of arbitration loss or CPU contention.",
            "The isolated PiStorm-side /BR is ignored by this controller and is not represented by these flags.",
            "The complement check detects a single changed bit but cannot detect every paired or multi-bit corruption.",
            "Readout follows shutdown/disconnection; no live Amiga bus transaction is attempted.",
        ],
    }
    header_ok = (words[0] >> 12) == 0xC
    complement_ok = words[1] == (words[0] ^ 0xFFFF)
    result["header_valid"] = header_ok
    result["complement_valid"] = complement_ok
    if words == [0xFFFF, 0xFFFF]:
        result["classification"] = "blank"
        result["meaning"] = "No diagnostic record is present in these two erased words."
        return result
    if not header_ok:
        result["classification"] = "unrecognized"
        result["meaning"] = "The first word is not a C12 pin-focused record. Old D-format records must use their original reader; these bit fields are not interpreted."
        return result
    if not complement_ok:
        result["classification"] = "partial"
        result["meaning"] = "A C-format first word is present, but its final complement is missing or mismatched; the payload is preserved without interpretation."
        return result
    snapshot = words[0] & 0xFFF
    cause = (snapshot >> 10) & 3
    cause_names = ("long_busy_observation", "raw_guard_observation", "native_fault", "pi_interruption")
    meanings = (
        "BUSY remained high for approximately 1.14 ms at a 7.16 MHz native clock. The timeout only recorded evidence; it did not retry or complete the transfer.",
        "The firmware combined raw protective guard was observed (/BG high, /BGACK low or /BERR low as CPLD logical inputs). /BERR can terminate an ordinary bus cycle; this is not proof of arbitration loss or CPU contention. Zero/multiple masks and uncertain event order remain possible.",
        "The native controller's sticky fault was observed. This records a stop rather than a complete history of its beginning.",
        "The synchronized Pi interruption flag was observed. This is an interruption observation, not a failing address or proven physical cause.",
    )
    main = (snapshot >> 7) & 3
    peripheral = (snapshot >> 4) & 7
    main_names = ("idle_or_S7_or_hold_tail", "address_S1_S2", "access_or_wait_S3_S4", "ordinary_finish_S5_S6")
    peripheral_names = {0: "idle", 1: "wait_E_fall", 2: "wait_E_rise", 3: "wait_E_end_fall", 4: "done"}
    mask = (snapshot >> 1) & 7
    conditions = {"/BG high": bool(mask & 4), "/BGACK low": bool(mask & 2), "/BERR low": bool(mask & 1)}
    names = [name for name, present in conditions.items() if present]
    if not names:
        interpretation = "No per-input flag is set in this snapshot; a reported raw event remains unresolved."
    elif len(names) == 1:
        interpretation = "One qualified condition was latched: %s. Its physical cause and when it occurred are not established." % names[0]
    else:
        interpretation = "Multiple qualified conditions were latched: %s. Their order and initiating cause are not recorded." % ", ".join(names)
    result.update({
        "classification": "committed", "meaning": meanings[cause],
        "snapshot_hex": "0x%03X" % snapshot,
        "cause": {"code": cause, "name": cause_names[cause]},
        "main_state": {"code": main, "name": main_names[main]},
        "peripheral_state": {"code": peripheral, "name": peripheral_names.get(peripheral, "invalid_or_unknown")},
        "flags": {"owned": bool(snapshot & (1 << 9))},
        "event_pin_mask": mask,
        "latched_raw_conditions": conditions,
        "latched_condition_names": names,
        "raw_event_latches_present": True,
        "event_order": "not_recorded",
        "single_pin_cause_proven": False,
        "pin_identity_scope": "CPLD logical inputs under selected historical QSF; native CPU physical-pin mapping is not established by this record",
        "berr_flag_proves_arbitration_loss": False,
        "pin_mask_interpretation": interpretation,
        "sampled_input_levels": {"/VPA": snapshot & 1},
    })
    return result


def format_record(record):
    lines = ["Logical UFM words: " + " ".join(record["raw_words"]),
             "Record: " + record["classification"], record["meaning"]]
    if record["classification"] == "committed":
        lines.append("Controller: %s; peripheral: %s" % (record["main_state"]["name"], record["peripheral_state"]["name"]))
        lines.append("Owned at capture: " + ("yes" if record["flags"]["owned"] else "no"))
        lines.append("Latched pin-condition mask: 0x%X" % record["event_pin_mask"])
        lines.append(record["pin_mask_interpretation"])
        lines.append("Sampled /VPA=%d; /AS, /DTACK and E are not stored." % record["sampled_input_levels"]["/VPA"])
    lines.append("First observation may precede the visible hang. Pin-condition flags do not establish event order or physical root cause.")
    return "\n".join(lines)
