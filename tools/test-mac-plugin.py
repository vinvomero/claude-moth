#!/usr/bin/env python3
"""Fixture harness for the macOS SwiftBar plugin - runnable on Windows.

The plugin is a bash wrapper around one python heredoc. This reads mac/moth.5m.sh as
bytes, checks the two things that make it a working macOS file at all (LF endings, the
bash shebang), pulls the python out of the heredoc, and execs it as a module. Then it
injects seams - the Claude fetch, the codex argv, the clock, `which` - and drives
main() in-process so every assertion is on real plugin code, not a copy of it.

`codex` itself is a fake (tools/fixtures/fake-codex.py) that plays a named scenario, so
the error paths are exercised for real: a hang really hangs, an exit really exits, and
the deadline really has to fire.

  python tools/test-mac-plugin.py            (python3 on macOS/Linux)
"""
import io
import json
import os
import pathlib
import subprocess
import sys
import time
import types

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "mac" / "moth.5m.sh"
FIXTURES = ROOT / "tools" / "fixtures"
FAKE = FIXTURES / "fake-codex.py"
GOLDEN = FIXTURES / "mac-golden-codex-absent.txt"
CLAUDE_FIXTURE = FIXTURES / "mac-claude-usage.json"
STRINGS = json.loads((FIXTURES / "codex-status-strings.json").read_text(encoding="utf-8"))

NOW = 1788460000.0
CRED = json.dumps({"claudeAiOauth": {"accessToken": "sk-ant-oat-FIXTURE"}})

passed = failed = 0


def check(name, got, expect):
    global passed, failed
    ok = got == expect
    if ok:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}\n          expected: {expect!r}\n          got:      {got!r}")


def check_that(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")


# --------------------------------------------------------------------------------
# Load the plugin
# --------------------------------------------------------------------------------

def load_plugin_source():
    data = PLUGIN.read_bytes()
    # A CRLF here is not cosmetic: macOS would try to exec "/bin/bash\r".
    check_that("plugin has no CR bytes", b"\r" not in data,
               f"({data.count(chr(13).encode())} found)")
    check_that("plugin starts with the bash shebang",
               data.split(b"\n", 1)[0] == b"#!/bin/bash")
    text = data.decode("utf-8")
    check_that("exactly one PYEOF heredoc", text.count("<<'PYEOF'") == 1)
    start = text.index("<<'PYEOF'")
    body = text[text.index("\n", start) + 1:]
    return body[: body.index("\nPYEOF") + 1]


SOURCE = load_plugin_source()


class Recorder:
    """Wraps subprocess.Popen so the spawn's shape is assertable."""

    def __init__(self):
        self.calls = []
        self._real = subprocess.Popen

    def __call__(self, args, **kw):
        self.calls.append({"args": list(args), **kw})
        return self._real(args, **kw)


def run_plugin(env=None, home=None, which=None, scenario=None, claude=None,
               codex_argv=None):
    """Exec the plugin fresh, inject the seams, drive main(), return (out, err, rec)."""
    mod = {"__name__": "moth_mac_plugin"}
    exec(compile(SOURCE, str(PLUGIN), "exec"), mod)

    payload = claude if claude is not None else json.loads(
        CLAUDE_FIXTURE.read_text(encoding="utf-8"))
    mod["fetch_claude"] = lambda token: payload
    if codex_argv is not None:
        mod["codex_command"] = codex_argv
    else:
        mod["codex_command"] = lambda path: [sys.executable, str(FAKE), "app-server"]

    full_env = {"CLAUDE_CRED": CRED}
    if scenario:
        full_env["FAKE_CODEX_SCENARIO"] = scenario
        full_env["FAKE_CODEX_NOW"] = str(int(NOW))
    full_env.update(env or {})

    rec = Recorder()
    real_popen, real_time = subprocess.Popen, time.time
    out, err = io.StringIO(), io.StringIO()
    real_out, real_err = sys.stdout, sys.stderr
    subprocess.Popen = rec
    time.time = lambda: NOW
    sys.stdout, sys.stderr = out, err
    try:
        mod["main"](full_env, home or str(ROOT), which or (lambda n: None))
    finally:
        subprocess.Popen = real_popen
        time.time = real_time
        sys.stdout, sys.stderr = real_out, real_err
    rendered = out.getvalue()
    # Checked on EVERY run, not in one place: a regression that put the Claude token into
    # an error row would otherwise pass the whole suite.
    if "sk-ant-oat-FIXTURE" in rendered:
        raise AssertionError("the Claude token reached rendered output:\n" + rendered)
    return rendered, err.getvalue(), rec


def stub(tmp, *parts):
    """Create an empty file standing in for a codex binary; return its path."""
    p = pathlib.Path(tmp, *parts)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("#!/bin/sh\n", encoding="utf-8")
    return str(p)


def title_of(out):
    return out.split("\n", 1)[0]


def rows(out):
    return out.split("\n")


# --------------------------------------------------------------------------------
print("mac plugin: Claude-only output is untouched")
# --------------------------------------------------------------------------------
golden = GOLDEN.read_text(encoding="utf-8").replace("\r\n", "\n")

out, err, rec = run_plugin()
check("codex absent, opt-in unset -> golden", out, golden)
check_that("no process spawned", rec.calls == [], f"({len(rec.calls)} spawns)")
check("no stderr", err, "")

import tempfile
with tempfile.TemporaryDirectory() as tmp:
    working = stub(tmp, "bin", "codex")
    for label, envv in (("unset", {}), ("false", {"MOTH_CODEX": "false"}),
                        ("0", {"MOTH_CODEX": "0"}), ("empty", {"MOTH_CODEX": ""})):
        out, err, rec = run_plugin(env=envv, which=lambda n: working, scenario="full")
        check(f"codex present, MOTH_CODEX {label} -> golden", out, golden)
        check_that(f"MOTH_CODEX {label} spawns nothing", rec.calls == [])

# --------------------------------------------------------------------------------
print("\nmac plugin: discovery")
# --------------------------------------------------------------------------------
mod = {"__name__": "moth_mac_plugin"}
exec(compile(SOURCE, str(PLUGIN), "exec"), mod)
find_codex = mod["find_codex"]

with tempfile.TemporaryDirectory() as tmp:
    override = stub(tmp, "custom", "codex")
    on_path = stub(tmp, "pathdir", "codex")
    got, tried = find_codex({"CODEX_CLI_PATH": override}, tmp, lambda n: on_path)
    check("CODEX_CLI_PATH wins over PATH", got, override)
    got, tried = find_codex({}, tmp, lambda n: on_path)
    check("PATH is used when no override", got, on_path)
    got, tried = find_codex({"CODEX_CLI_PATH": os.path.join(tmp, "nope")}, tmp,
                            lambda n: on_path)
    check("a bad override falls through to PATH", got, on_path)

with tempfile.TemporaryDirectory() as tmp:
    nvm = stub(tmp, ".nvm", "versions", "node", "v20.11.0", "bin", "codex")
    got, tried = find_codex({}, tmp, lambda n: None)
    check("nvm install is found with nothing on PATH", got, nvm)
    got, tried = find_codex({}, tmp, lambda n: None)
    check_that("paths tried are reported", len(tried) >= 3 and "codex on PATH" in tried)

with tempfile.TemporaryDirectory() as tmp:
    got, tried = find_codex({}, tmp, lambda n: None)
    check("nothing anywhere -> None", got, None)

# --------------------------------------------------------------------------------
print("\nmac plugin: the child process")
# --------------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    nvm = stub(tmp, ".nvm", "versions", "node", "v20.11.0", "bin", "codex")
    out, err, rec = run_plugin(env={"MOTH_CODEX": "1"}, home=tmp,
                               which=lambda n: None, scenario="calm")
    check_that("one spawn", len(rec.calls) == 1, f"({len(rec.calls)})")
    call = rec.calls[0]
    check("start_new_session is set", call.get("start_new_session"), True)
    check("cwd is the injected home", call.get("cwd"), tmp)
    check_that("all three streams piped",
               call.get("stdin") == subprocess.PIPE and call.get("stdout") == subprocess.PIPE
               and call.get("stderr") == subprocess.PIPE)
    check("decoding is utf-8 with replacement", (call.get("encoding"), call.get("errors")),
          ("utf-8", "replace"))
    lead = call["env"]["PATH"].split(os.pathsep)[0]
    check("resolved dir leads the child PATH", lead, os.path.dirname(nvm))
    check_that("homebrew prefixes follow",
               "/opt/homebrew/bin" in call["env"]["PATH"] and "/usr/local/bin" in call["env"]["PATH"])
    check_that("the inherited PATH is kept, not replaced",
               call["env"]["PATH"].split(os.pathsep)[-1] not in
               ("", os.path.dirname(nvm), "/opt/homebrew/bin", "/usr/local/bin"),
               call["env"]["PATH"])
    check_that("RUST_LOG is stripped", "RUST_LOG" not in call["env"])

    # The credential must not reach a different vendor's binary - or anything it forks.
    # Asserting only what IS in the child env is how this was missed the first time.
    check_that("CLAUDE_CRED is stripped from the child env",
               "CLAUDE_CRED" not in call["env"], sorted(call["env"]))
    leaked = [k for k, v in call["env"].items() if isinstance(v, str) and "sk-ant-oat-FIXTURE" in v]
    check_that("no child env var carries the token by value", not leaked, str(leaked))
    # Same guarantee, renamed variable: the by-value sweep has to catch it.
    _, _, rec2 = run_plugin(env={"MOTH_CODEX": "1", "SOMETHING_ELSE": CRED}, home=tmp,
                            which=lambda n: None, scenario="calm")
    leaked2 = [k for k, v in rec2.calls[0]["env"].items()
               if isinstance(v, str) and "sk-ant-oat-FIXTURE" in v]
    check_that("a renamed credential var is stripped by value", not leaked2, str(leaked2))

# the real argument list (not the harness's fake) is asserted by reading codex_command
check("codex_command mirrors the Windows helper", mod["codex_command"]("/x/codex"),
      ["/x/codex", "-s", "read-only", "-a", "never", "app-server", "--stdio"])

# --------------------------------------------------------------------------------
print("\nmac plugin: Codex rows")
# --------------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    working = stub(tmp, "bin", "codex")
    W = lambda n: working
    ON = {"MOTH_CODEX": "1"}

    out, err, rec = run_plugin(env=ON, which=W, scenario="full")
    check("full reply -> two-part title", title_of(out), "Cl 42% · Co 100% | color=#FF5C6E")
    check_that("Codex group header present", "Codex usage | color=#6E6552" in out)
    check_that("Codex 5-hour row", "5-hour   100% | color=#FF5C6E" in out)
    check_that("Codex weekly row", "Weekly   16% | color=#FFB65C" in out)
    check_that("account id never leaves the reply", "acct_FIXTURE" not in out, out)
    check_that("credits never leave the reply", "1234" not in out)
    check_that("Claude rows still present", "Fable (weekly)   55% | color=#FFB65C" in out)
    check("no stderr", err, "")

    out, err, rec = run_plugin(env=ON, which=W, scenario="calm")
    check("calm reply -> amber two-part title", title_of(out), "Cl 42% · Co 17% | color=#FFB65C")

    out, err, rec = run_plugin(env=ON, which=W, scenario="no-weekly")
    check_that("missing weekly renders --%, muted", "Weekly   --% | color=#8A7B5E" in out, out)
    check_that("missing weekly is never 0%", "Weekly   0%" not in out)

    out, err, rec = run_plugin(env=ON, which=W, scenario="null-limits")
    check_that("rateLimits:null -> parse-fail row", STRINGS["parse-fail"]["mac"] in out, out)
    check_that("Claude rows survive a Codex parse failure",
               "5-hour   42% | color=#FFB65C" in out)

    # --- error codes ---
    out, _, _ = run_plugin(env=ON, which=W, scenario="auth")
    check_that("-32600 with auth -> sign-in row", STRINGS["rpc-auth"]["mac"] in out, out)
    check_that("error.data never reaches the menu", "401 Unauthorized" not in out)

    out, _, _ = run_plugin(env=ON, which=W, scenario="not-auth")
    check_that("-32600 without auth is NOT sign-in", STRINGS["rpc-auth"]["mac"] not in out, out)
    check_that("-32600 without auth -> the code, verbatim",
               STRINGS["rpc-other"]["mac"].format(-32600) in out, out)

    out, _, _ = run_plugin(env=ON, which=W, scenario="too-old")
    check_that("-32601 -> too-old row", STRINGS["rpc-too-old"]["mac"] in out, out)

    out, _, _ = run_plugin(env=ON, which=W, scenario="backend")
    check_that("-32603 -> sync-failed row", STRINGS["rpc-backend"]["mac"] in out, out)

    out, _, _ = run_plugin(env=ON, which=W, scenario="overloaded")
    check_that("-32001 -> overloaded row", STRINGS["rpc-overloaded"]["mac"] in out, out)

    # --- stream discipline ---
    for scen in ("out-of-order", "notify-first", "garbage-first"):
        out, err, _ = run_plugin(env=ON, which=W, scenario=scen)
        check_that(f"{scen}: the id-2 reply is the one used",
                   "5-hour   17% | color=#FFB65C" in out, out)
        check(f"{scen}: no stderr", err, "")

    # 300 notifications then the real reply: the reply must still land. Counting startup
    # chatter against the cap would permanently fail anyone whose codex build starts their
    # MCP servers, with no setting they could change.
    out, err, _ = run_plugin(env=ON, which=W, scenario="flood")
    check_that("notification burst does not consume the line cap",
               "5-hour   17% | color=#FFB65C" in out, out)
    check("no stderr after a notification burst", err, "")

    # ...but 300 non-notification lines are what the cap is for.
    out, err, _ = run_plugin(env=ON, which=W, scenario="flood-replies")
    check_that("over-cap -> capped, not hung", STRINGS["no-reply"]["mac"] in out, out)
    check_that("over-cap says what happened", "sent too much before answering" in out)
    check_that("over-cap does not blame the reply", STRINGS["parse-fail"]["mac"] not in out)

    # --- injection ---
    out, err, _ = run_plugin(env=ON, which=W, scenario="stderr-inject")
    # The text is still shown - hiding it would hide the evidence - but every "|" in it
    # is neutralised, so SwiftBar reads it as one row's text and not as row parameters.
    check_that("hostile stderr is still shown, escaped", "boom ¦ bash" in out, out)
    danger = [r for r in rows(out)
              if any(p.split("=", 1)[0] in ("bash", "shell", "terminal", "param1")
                     for p in r.split(" | ")[1:])]
    check_that("hostile stderr never becomes a row parameter", not danger, str(danger))
    check_that("hostile stderr forged no extra row",
               len([r for r in rows(out) if r.startswith("boom")]) == 1)
    check("no stderr", err, "")

    # --- absent, but asked for ---
    out, err, rec = run_plugin(env=ON, which=lambda n: None, home=tempfile.gettempdir(),
                               scenario="full")
    check_that("codex absent + opt-in -> not-found row", STRINGS["binary-missing"]["mac"] in out, out)
    check_that("not-found row lists where we looked", "Looked in: " in out, out)
    check_that("Claude rows unchanged when Codex is missing",
               "5-hour   42% | color=#FFB65C" in out)
    check_that("nothing was spawned", rec.calls == [])

    # --- Claude down, Codex fine ---
    out, err, _ = run_plugin(env={**ON, "CLAUDE_CRED": ""}, which=W, scenario="calm")
    check("claude creds absent -> --% for Claude only", title_of(out),
          "Cl --% · Co 17% | color=#FFB65C")
    check_that("claude not-logged-in row present", "Not logged in to Claude Code" in out, out)
    check_that("codex rows still rendered", "5-hour   17%" in out)

    # --- exit and hang ---
    out, err, _ = run_plugin(env=ON, which=W, scenario="exit1")
    check_that("immediate exit -> exited row", STRINGS["exited"]["mac"].rstrip(".") in out, out)
    check_that("exit row carries the status", "status 1" in out, out)
    check_that("exit row carries the first stderr line", "could not open config" in out, out)
    check_that("only the FIRST stderr line", "second line" not in out)
    check("no stderr", err, "")

    # --- spawn failures: the branches no scenario could reach, because every scenario
    # --- used the default codex_command that always spawns successfully.
    missing = os.path.join(tmp, "no-such-interpreter", "python")
    out, err, _ = run_plugin(env=ON, which=W, codex_argv=lambda p: [missing, "app-server"])
    check_that("exec failure on a path that exists -> interpreter row",
               STRINGS["interpreter-missing"]["mac"] in out, out)
    check_that("interpreter row does not say 'not found'",
               STRINGS["binary-missing"]["mac"] not in out)
    check("no stderr on an exec failure", err, "")

    # A directory raises PermissionError on Windows, which is the same exception macOS
    # raises for a Gatekeeper kill - so it drives the real branch.
    out, err, _ = run_plugin(env=ON, which=W, codex_argv=lambda p: [tmp, "app-server"])
    check_that("permission failure on an executable file -> quarantine row",
               "com.apple.quarantine" in out, out)

    # ...and the same exception when the file is NOT executable must say chmod instead.
    real_access = os.access
    os.access = lambda p, m: False if m == os.X_OK else real_access(p, m)
    try:
        out, err, _ = run_plugin(env=ON, which=W, codex_argv=lambda p: [tmp, "app-server"])
    finally:
        os.access = real_access
    check_that("permission failure on a non-executable file -> chmod row",
               "chmod +x" in out, out)
    check_that("chmod row does not blame Gatekeeper", "com.apple.quarantine" not in out)

    # line() must clean parameter VALUES too, not just row text.
    check_that("row parameter values are sanitized",
               "|" not in mod["line"]("t", href="http://x|bash=rm -rf ~").split(" | ", 1)[1],
               mod["line"]("t", href="http://x|bash=rm -rf ~"))

    started = time.monotonic()
    out, err, _ = run_plugin(env=ON, which=W, scenario="hang")
    elapsed = time.monotonic() - started
    check_that("hang -> timed-out row", STRINGS["timeout"]["mac"] in out, out)
    check_that("hang row names the resolved path", f"Using: {working}" in out, out)
    check_that("hang returns within the deadline + 5s", elapsed < mod["CODEX_DEADLINE_S"] + 5,
               f"({elapsed:.1f}s)")
    check("no stderr after a hang", err, "")
    check_that("Claude rows survive a hang", "5-hour   42% | color=#FFB65C" in out)

# --------------------------------------------------------------------------------
print("\nmac plugin: shared strings and structure")
# --------------------------------------------------------------------------------
src_text = PLUGIN.read_text(encoding="utf-8")
check_that("bail() is gone", "def bail(" not in src_text)
check_that("the opt-in is declared for SwiftBar", "<xbar.var>boolean(MOTH_CODEX=false)" in src_text)
check_that("main is guarded so the harness can drive it",
           'if __name__ == "__main__":' in src_text)
check_that("killpg is the POSIX branch", "os.killpg(" in src_text)
check_that("quarantine hint names the xattr command",
           "xattr -d com.apple.quarantine" in src_text)
check_that("python3 fallback message is unchanged",
           "Moth: needs python3" in src_text)
check_that("dead `strings` parameter is gone", "strings=None" not in src_text)
check_that("the process group is swept unconditionally", "sweep_group(proc)" in src_text)
check_that("the credential is stripped by name", 'child.pop("CLAUDE_CRED", None)' in src_text)

# Every non-null 'mac' string in the shared table must appear in the plugin, and the table
# must not silently gain a class the plugin cannot produce. A null is a deliberate claim
# that the platform has no such failure, so it is skipped rather than treated as a pass.
for key, pair in STRINGS.items():
    if key.startswith("_") or pair.get("mac") is None:
        continue
    # A {0} entry is a format template; only its literal prefix can appear in the source.
    needle = pair["mac"].split("{0}")[0].rstrip(". ")
    check_that(f"string table matches the plugin: {key}", needle in src_text, pair["mac"])

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
