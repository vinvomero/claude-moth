#!/usr/bin/env python3
"""Capture the Mac plugin's Claude-only output as the golden the harness diffs against.

WHY THIS IS ITS OWN SCRIPT, AND WHY IT READS FROM GIT

The golden exists to prove one thing: adding the Codex section did not change a single
byte of what a Claude-only user sees. A golden generated from the refactored plugin
could never fail that test - it would just record whatever the new code happens to do.
So this reads the plugin from a git ref (default HEAD), not the working tree, and the
golden is committed BEFORE the plugin is edited.

The committed heredoc has no test seams - it reads the environment, opens urllib at
import time, and exits through bail() - so this patches the two things it touches
(urllib.request.build_opener and time.time) and catches SystemExit.

  python tools/capture-mac-golden.py                 # from HEAD, writes the golden
  python tools/capture-mac-golden.py --ref abc1234   # from any ref
  python tools/capture-mac-golden.py --print         # show it, write nothing
"""
import argparse
import io
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request

# Pinned clock. Every resets_at in the Claude fixture is BEFORE this, so remaining()
# returns "resetting..." and the golden never bakes in a local wall-clock time.
NOW = 1788460000.0

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tools" / "fixtures"
CLAUDE_FIXTURE = FIXTURES / "mac-claude-usage.json"
GOLDEN = FIXTURES / "mac-golden-codex-absent.txt"
PLUGIN = "mac/moth.5m.sh"


def extract_heredoc(text):
    """Return the python between the single <<'PYEOF' ... PYEOF pair."""
    start = text.index("<<'PYEOF'")
    body_start = text.index("\n", start) + 1
    end = text.index("\nPYEOF", body_start)
    return text[body_start:end + 1]


class _Reply:
    """Minimal stand-in for the urlopen context manager json.load() is handed."""

    def __init__(self, payload):
        self._buf = io.BytesIO(json.dumps(payload).encode("utf-8"))

    def read(self, *a):
        return self._buf.read(*a)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class _Opener:
    def __init__(self, payload):
        self._payload = payload

    def open(self, req, timeout=None):
        return _Reply(self._payload)


def run_plugin_python(source, payload, cred):
    """Exec the plugin's python with the network and the clock replaced; return stdout."""
    real_opener, real_time = urllib.request.build_opener, time.time
    real_stdout, real_cred = sys.stdout, os.environ.get("CLAUDE_CRED")
    out = io.StringIO()
    urllib.request.build_opener = lambda *a, **k: _Opener(payload)
    time.time = lambda: NOW
    os.environ["CLAUDE_CRED"] = cred
    sys.stdout = out
    try:
        # __name__ is deliberately not "__main__": the harness execs the same text and
        # a future `if __name__ == "__main__"` guard must not fire twice.
        exec(compile(source, PLUGIN, "exec"), {"__name__": "moth_mac_plugin"})
    except SystemExit:
        pass  # bail() is a normal exit path, not a failure
    finally:
        urllib.request.build_opener, time.time = real_opener, real_time
        sys.stdout = real_stdout
        if real_cred is None:
            os.environ.pop("CLAUDE_CRED", None)
        else:
            os.environ["CLAUDE_CRED"] = real_cred
    return out.getvalue()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default="HEAD", help="git ref to read the plugin from")
    ap.add_argument("--print", dest="show", action="store_true", help="print, do not write")
    args = ap.parse_args()

    shell = subprocess.run(
        ["git", "show", f"{args.ref}:{PLUGIN}"],
        cwd=str(ROOT), capture_output=True, check=True,
    ).stdout.decode("utf-8")
    payload = json.loads(CLAUDE_FIXTURE.read_text(encoding="utf-8"))
    cred = json.dumps({"claudeAiOauth": {"accessToken": "sk-ant-oat-FIXTURE"}})

    text = run_plugin_python(extract_heredoc(shell), payload, cred)
    if args.show:
        sys.stdout.write(text)
        return
    # newline="" so the golden keeps LF on Windows; the plugin's own output is LF.
    with open(GOLDEN, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    print(f"wrote {GOLDEN.relative_to(ROOT)} from {args.ref}:{PLUGIN} ({len(text)} chars)")


if __name__ == "__main__":
    main()
