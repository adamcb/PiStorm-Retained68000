#!/usr/bin/env python3
"""Run the host-only JTAG reader tests and bind results to exact file hashes."""
import datetime
import hashlib
import io
import json
from pathlib import Path
import sys
import unittest


class RecordingResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.records = []

    def addSuccess(self, test):
        super().addSuccess(test)
        self.records.append({"test": test.id(), "status": "PASS"})

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.records.append({"test": test.id(), "status": "FAIL"})

    def addError(self, test, err):
        super().addError(test, err)
        self.records.append({"test": test.id(), "status": "ERROR"})


def main():
    folder = Path(__file__).resolve().parent
    reports = folder.parent / "reports"
    reports.mkdir(exist_ok=True)
    suite = unittest.defaultTestLoader.loadTestsFromName("test_read_retained_diag_jtag")
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2, resultclass=RecordingResult).run(suite)
    files = []
    for name in ("read_retained_diag_jtag.py", "retained_diag_decode.py", "test_read_retained_diag_jtag.py",
                 "word-mapping-evidence.json", "READOUT.md", "verify_readout.py"):
        data = (folder / name).read_bytes()
        files.append({"path": "readout/" + name, "sha256": hashlib.sha256(data).hexdigest(),
                      "bytes": len(data), "utf8NoBom": not data.startswith(b"\xef\xbb\xbf"),
                      "lfOnly": b"\r" not in data})
    report = {
        "status": "PASS_HOST_FAKE_GPIO_AND_DECODER_ONLY" if result.wasSuccessful() else "FAIL",
        "createdUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "physicalJtagQualified": False,
        "testsRun": result.testsRun,
        "testsPassed": len([record for record in result.records if record["status"] == "PASS"]),
        "failures": len(result.failures), "errors": len(result.errors),
        "files": files, "tests": result.records,
        "boundaries": [
            "Fake TAP/GPIO tests and compiler serialization fixture do not qualify physical JTAG waveforms or the user's board.",
            "The new UFM record is word0 Cxxx carrying pin-focused snapshot12, followed by its bitwise complement. Old D headers are rejected without interpreting their fields.",
            "Whitelisted read-only instructions and fixed UFM address selector are checked independently by the fake TAP.",
            "Both complete 512-word reads must match; raw words and partial read state are preserved on failure.",
            "Hardware decoding requires new logical UFM markers510=4D55 and511=C12C; oldD12C is rejected. Preflight additionally requires erased record words.",
            "No GPCLK setup, host status access, motherboard bus transfer, program or erase operation is exposed by the delivered reader.",
            "Mask4/2/1 means latchedBGhigh/BGACKlow/BERRlow; all8combinations are accepted, zero is unresolved and multiple flags have no recorded order. /VPA alone is sampled; AS/DTACK/E are absent.",
            "A single condition flag is not a proven physical root cause; first qualifying observation may precede the visible hang.",
        ],
    }
    (reports / "READOUT-VERIFIED.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
    (reports / "READOUT-tests.log").write_text(stream.getvalue(), encoding="utf-8", newline="\n")
    print(stream.getvalue())
    print(json.dumps({"status": report["status"], "testsRun": report["testsRun"], "testsPassed": report["testsPassed"]}))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
