#!/bin/bash
# <xbar.title>Moth</xbar.title>
# <xbar.version>v1.1</xbar.version>
# <xbar.author>vinvomero</xbar.author>
# <xbar.desc>A little menu-bar moth, drawn to your Claude Code usage. Shows the real 5-hour and weekly limit percentages, and optionally Codex (ChatGPT) usage alongside them.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <xbar.var>boolean(MOTH_CODEX=false): Also show Codex (ChatGPT) usage. Needs the codex CLI installed; Moth runs `codex app-server` in the background to read it.</xbar.var>
# <xbar.var>string(CODEX_CLI_PATH=""): Full path to the codex binary, if it lives somewhere unusual.</xbar.var>
#
# Moth for macOS — a SwiftBar / xbar plugin.
# The 5m in the filename = refresh every 5 minutes (safely above the endpoint's
# ~180s etiquette). Drop this file in your SwiftBar plugins folder, chmod +x it.
#
# Data source: the same undocumented api/oauth/usage endpoint the Windows widget
# uses, with the login token Claude Code already stores. See mac/README.md for the
# honest disclosure. Never runs its own login; never transmits the token anywhere
# except to Anthropic.
#
# Codex is OPT-IN and OFF by default. With it off, this plugin does exactly what it
# always did and never looks for, or starts, anything.

# --- find python3 (does the JSON + date + rendering; stock macOS has no JSON tool) ---
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "Moth: needs python3"
  echo "---"
  echo "Install the Xcode Command Line Tools (xcode-select --install) or Homebrew python3, then refresh. | color=#FF5C6E"
  exit 0
fi

# --- read the credentials JSON: Keychain first, then the file fallback ---
CRED="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
if [ -z "$CRED" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
  CRED="$(cat "$HOME/.claude/.credentials.json")"
fi

# Hand everything to python3: extract token, call the endpoint, render SwiftBar lines.
# MOTH_CODEX and CODEX_CLI_PATH are already in the environment when SwiftBar sets them
# (2.1.0+ reads the <xbar.var> tags above); they are inherited, not re-read from a file.
CLAUDE_CRED="$CRED" "$PY" <<'PYEOF'
import json, os, subprocess, sys, threading, time, urllib.request

AMBER, ORANGE, RED, MUTED, DIM = "#FFB65C", "#FF9D42", "#FF5C6E", "#8A7B5E", "#6E6552"
ISSUES = "https://github.com/vinvomero/claude-moth/issues"

# Hard ceiling on the whole Codex exchange. The plugin refreshes every 5 minutes, so a
# wedged app-server costs one late menu, never a stuck menu bar.
CODEX_DEADLINE_S = 12.0
CODEX_MAX_LINES = 200
CODEX_MAX_BYTES = 1048576
CODEX_STDERR_KEEP = 2048

# Every row is BUILT, then printed once at the end. Nothing here calls print() or
# sys.exit() on its own: a Codex failure must not be able to truncate the Claude menu
# half-drawn, which is exactly what the old bail() did.


def clean(text):
    # SwiftBar reads everything after a "|" as row parameters, and every newline as a new
    # row. Some of the text below is not ours - a stderr line from codex, a path off the
    # user's disk - so an unescaped "|" could smuggle in `bash=...` and turn an error
    # message into a clickable command. Neutralise both here, once, for every row.
    return str(text).replace("|", "¦").replace("\r", " ").replace("\n", " ")


def line(text, **attrs):
    parts = [clean(text)]
    for k, v in attrs.items():
        parts.append(f"{k}={v}")
    return " | ".join(parts) if attrs else parts[0]


def color_for(p):
    if p is None: return MUTED
    if p >= 90: return RED
    if p >= 70: return ORANGE
    return AMBER


def pct_of(v):
    """A percentage clamped to 0-100, or None if it is not a real number."""
    if v is None:
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f or f in (float("inf"), float("-inf")):
        return None
    return max(0.0, min(100.0, f))


def parse_ts(v):
    if v is None:
        return None
    try:
        return float(v)  # epoch seconds
    except (TypeError, ValueError):
        pass
    try:  # ISO 8601, e.g. 2026-08-08T06:00:00.013303+00:00
        s = str(v).replace("Z", "+00:00")
        import datetime
        return datetime.datetime.fromisoformat(s).timestamp()
    except Exception:
        return None


def remaining(epoch):
    if epoch is None:
        return ""
    s = int(epoch - time.time())
    if s <= 0:
        return "resetting…"
    import datetime
    # local wall-clock; lstrip("0") drops the leading zero portably ("%-I" is glibc-only)
    clock = datetime.datetime.fromtimestamp(epoch).strftime("%I:%M %p").lstrip("0")
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m = s // 60
    if d: cd = f"in {d}d {h}h"
    elif h: cd = f"in {h}h {m}m"
    else: cd = f"in {m}m"
    return f"resets {clock} · {cd}"


# ======================= Claude =======================

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # Never follow a 3xx: a redirect would resend the Authorization: Bearer header to
    # whatever host the response points at. Returning None turns any redirect into an
    # HTTPError we handle below, so the token only ever goes to api.anthropic.com.
    def redirect_request(self, *args, **kwargs):
        return None


def fetch_claude(token):
    """Seam: the harness replaces this with a canned payload."""
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            # REQUIRED — without this UA the endpoint hard rate-limits you.
            "User-Agent": "claude-code/2.1.224",
        },
    )
    opener = urllib.request.build_opener(_NoRedirect)
    with opener.open(req, timeout=15) as r:
        return json.load(r)


def claude_rows(env):
    """Return (p5, rows). p5 is None whenever there is no number to show."""
    raw = env.get("CLAUDE_CRED", "")
    if not raw.strip():
        return None, [line("Not logged in to Claude Code — no credentials found.", color=RED)]
    try:
        token = json.loads(raw).get("claudeAiOauth", {}).get("accessToken", "")
    except Exception:
        token = ""
    if not token:
        return None, [line("Logged in, but no access token yet. Open Claude Code, then refresh.", color=RED)]

    try:
        data = fetch_claude(token)
    except Exception as e:
        code = getattr(e, "code", None)
        if code == 401:
            return None, [line("Token expired — reopen Claude Code to refresh it, then refresh.", color=RED)]
        return None, [line(f"Couldn't reach the usage endpoint ({code or 'network error'}).", color=RED)]

    def pct(bucket):
        # `data.get(bucket, {})` does NOT protect against "five_hour": null (the default
        # applies only to a MISSING key, not a null value) - `or {}` covers both.
        return pct_of((data.get(bucket) or {}).get("utilization"))

    def resets(bucket):
        return parse_ts((data.get(bucket) or {}).get("resets_at"))

    p5, p7 = pct("five_hour"), pct("seven_day")
    r5, r7 = resets("five_hour"), resets("seven_day")

    rows = []
    if p5 is not None:
        rows.append(line(f"5-hour   {round(p5)}%", color=color_for(p5)))
        if r5: rows.append(line(remaining(r5), color=DIM, size="11"))
    if p7 is not None:
        rows.append(line(f"Weekly   {round(p7)}%", color=color_for(p7)))
        if r7: rows.append(line(remaining(r7), color=DIM, size="11"))

    # Per-model weekly bar: read the scoped-weekly limit from limits[] (the top-level
    # seven_day_<model> fields are null on Max plans). DETERMINISTIC tie-break (active,
    # then highest percent, then model name) matches the Windows widget so both platforms
    # pick the same model even if several are active.
    def _scored(lim):
        model = (lim.get("scope") or {}).get("model") or {}
        if lim.get("group") != "weekly" or not model.get("display_name"):
            return None
        try: pct_v = float(lim.get("percent") if lim.get("percent") is not None else lim.get("utilization"))
        except (TypeError, ValueError): pct_v = -1.0
        return (1 if lim.get("is_active") else 0, pct_v, model["display_name"])
    cands = []
    for lim in (data.get("limits") or []):
        try:
            s = _scored(lim)
            if s is not None: cands.append((s, lim))
        except AttributeError:
            continue
    if cands:
        # sort by (active, percent) desc, then name asc for a stable, cross-platform pick
        cands.sort(key=lambda t: (-t[0][0], -t[0][1], t[0][2]))
        scoped = cands[0][1]
        try:
            raw_pm = scoped.get("percent") if scoped.get("percent") is not None else scoped.get("utilization")
            pm = max(0.0, min(100.0, float(raw_pm)))
            label = scoped["scope"]["model"]["display_name"]
            rows.append(line(f"{label} (weekly)   {round(pm)}%", color=color_for(pm)))
            rm = parse_ts(scoped.get("resets_at"))
            if rm: rows.append(line(remaining(rm), color=DIM, size="11"))
        except (TypeError, ValueError):
            pass

    return p5, rows


# ======================= Codex =======================

def codex_enabled(env):
    # Environment only. There is no config file for this: SwiftBar 2.1.0+ writes the
    # <xbar.var> above into the environment, and on older builds you export it yourself.
    return str(env.get("MOTH_CODEX", "")).strip().lower() in ("1", "true", "yes", "on")


def find_codex(env, home, which):
    """Return (path, tried). Order mirrors the Windows helper: explicit override, then
    PATH, then the places the npm/bun/volta/nvm installers actually put it."""
    tried = []
    override = str(env.get("CODEX_CLI_PATH", "") or "").strip()
    if override:
        tried.append(override)
        if os.path.isfile(override):
            return override, tried
    hit = which("codex")
    tried.append("codex on PATH")
    if hit:
        return hit, tried
    cands = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        os.path.join(home, ".local", "bin", "codex"),
        os.path.join(home, ".bun", "bin", "codex"),
        os.path.join(home, ".volta", "bin", "codex"),
    ]
    # nvm keeps one bin dir per node version; newest-looking last so the sort picks it.
    nvm = os.path.join(home, ".nvm", "versions", "node")
    try:
        for ver in sorted(os.listdir(nvm), reverse=True):
            cands.append(os.path.join(nvm, ver, "bin", "codex"))
    except OSError:
        pass
    for c in cands:
        tried.append(c)
        if os.path.isfile(c):
            return c, tried
    return None, tried


def codex_command(path):
    """Seam: the harness swaps in a fake. Identical argument list to the Windows helper -
    -s read-only -a never says this process may not write or approve anything, and
    --stdio states the default transport rather than assuming it. All three verified
    accepted on codex-cli 0.152.0 (on Windows; the CLI is the same binary family)."""
    return [path, "-s", "read-only", "-a", "never", "app-server", "--stdio"]


def codex_env(path, env):
    child = dict(env)
    # The resolved directory leads, so a node shim finds its own siblings first; the two
    # Homebrew prefixes follow because a SwiftBar plugin inherits a login shell's PATH,
    # which frequently has neither.
    lead = os.path.dirname(os.path.abspath(path))
    child["PATH"] = os.pathsep.join([lead, "/opt/homebrew/bin", "/usr/local/bin"])
    child.pop("RUST_LOG", None)  # the app-server's tracing layer writes to stderr under it
    return child


def kill_codex(proc):
    if proc is None or proc.poll() is not None:
        return
    try:
        # start_new_session put the child in its own process group, so this reaches a
        # node shim's grandchildren too. Windows (the harness's home) has no killpg.
        os.killpg(proc.pid, 9)
    except (AttributeError, OSError, PermissionError):
        try:
            proc.kill()
        except OSError:
            pass
    try:
        proc.wait(timeout=2)
    except Exception:
        pass


def _epoch(v):
    """Epoch seconds. Anything past 1e11 is milliseconds - a future build changing units
    would otherwise render a countdown fifty thousand years out."""
    try:
        n = int(float(v))
    except (TypeError, ValueError):
        return None
    return n // 1000 if n > 100000000000 else n


def _bounded(epoch, now):
    """These stamps come from an undocumented API. Refuse ones that cannot be real
    rather than handing the countdown something absurd."""
    if epoch is None:
        return None
    if epoch < now - 86400 or epoch > now + 31536000:
        return None
    return epoch


def parse_rate_limits(result, now):
    """Map an app-server result to (p5, r5, p7, r7), or None if it carries no primary.
    Prefer rateLimitsByLimitId.codex; fall back to the legacy single-bucket rateLimits.
    primary is required; secondary is optional (some plans report no weekly window)."""
    if not isinstance(result, dict):
        return None
    snap = None
    by_id = result.get("rateLimitsByLimitId")
    if isinstance(by_id, dict) and isinstance(by_id.get("codex"), dict):
        snap = by_id["codex"]
    elif isinstance(result.get("rateLimits"), dict):
        snap = result["rateLimits"]
    if snap is None:
        return None
    primary = snap.get("primary") or {}
    p5 = pct_of(primary.get("usedPercent"))
    if p5 is None:
        return None
    secondary = snap.get("secondary") or {}
    p7 = pct_of(secondary.get("usedPercent"))
    return {
        "p5": p5,
        "r5": _bounded(_epoch(primary.get("resetsAt")), now),
        "p7": p7,
        "r7": _bounded(_epoch(secondary.get("resetsAt")), now) if p7 is not None else None,
    }


def read_codex(path, home, env):
    """Speak JSON-RPC to a local `codex app-server` and return (snapshot, failure).
    Exactly one of the two is None. Moth never reads Codex credentials - the app-server
    owns its own login and makes the backend call itself."""
    try:
        proc = subprocess.Popen(
            codex_command(path),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=home, env=codex_env(path, env),
            # Its own process group, so a kill reaches a shim's children and a Ctrl-C in
            # whatever launched SwiftBar never reaches the app-server.
            start_new_session=True,
            text=True, encoding="utf-8", errors="replace",
        )
    except PermissionError:
        return None, {"kind": "quarantine"}
    except FileNotFoundError:
        # The path exists (find_codex checked) but exec failed to find something: an npm
        # shim whose `node` is gone. Saying "not found" about a file the user can see
        # sends them looking in the wrong place.
        if os.path.isfile(path):
            return None, {"kind": "interpreter-missing"}
        return None, {"kind": "binary-missing"}
    except OSError as e:
        return None, {"kind": "spawn-failed", "detail": str(e)}

    lines_q = []
    lines_lock = threading.Condition()
    stderr_buf = []

    def pump_stdout():
        # readline, not `for raw in proc.stdout`: iteration over a pipe can sit on a
        # read-ahead buffer, which on a chatty server delays the reply we are waiting for.
        try:
            for raw in iter(proc.stdout.readline, ""):
                with lines_lock:
                    lines_q.append(raw)
                    lines_lock.notify()
        except Exception:
            pass
        finally:
            with lines_lock:
                lines_q.append(None)  # EOF sentinel
                lines_lock.notify()

    def pump_stderr():
        # Kept, not discarded: the Mac plugin has no log file, so the first couple of KB
        # of stderr is the only evidence a user can show us. A full stderr pipe would
        # also stall the child forever, which looks exactly like a hang.
        kept = 0
        try:
            for raw in iter(proc.stderr.readline, ""):
                if kept >= CODEX_STDERR_KEEP:
                    continue  # keep draining the pipe, just stop remembering
                chunk = raw[: CODEX_STDERR_KEEP - kept]
                stderr_buf.append(chunk)
                kept += len(chunk)
        except Exception:
            pass

    # Daemon threads: a read blocked on a pipe that never closes would otherwise outlive
    # every deadline and keep the whole plugin alive.
    threads = []
    for fn in (pump_stdout, pump_stderr):
        t = threading.Thread(target=fn, daemon=True)
        t.start()
        threads.append(t)

    def stderr_first_line():
        # Give the stderr pump a moment to finish: a child that dies fast can close both
        # pipes before that thread has copied anything, and an empty error row is the one
        # that makes a bug report useless.
        threads[1].join(timeout=1)
        text = "".join(stderr_buf).strip()
        return text.splitlines()[0] if text else ""

    try:
        req_id = 2
        init = ('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":'
                '{"name":"moth","version":"0.1"},"capabilities":{"optOutNotificationMethods":'
                '["remoteControl/status/changed"]}}}')
        try:
            # No params on account/rateLimits/read: this app-server version types them as
            # unit and rejects an object with -32600 "expected unit".
            proc.stdin.write(init + "\n")
            proc.stdin.write('{"jsonrpc":"2.0","method":"initialized"}\n')
            proc.stdin.write('{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}\n')
            proc.stdin.flush()
        except OSError as e:
            # A child that already died raises BrokenPipeError here on macOS and EINVAL
            # on Windows; both are OSError, neither is a hang.
            rc = proc.poll()
            return None, {"kind": "exited", "status": rc, "detail": stderr_first_line() or str(e)}

        # ONE absolute deadline for the whole exchange, on the monotonic clock so a system
        # clock change mid-read cannot extend or collapse it.
        deadline = time.monotonic() + CODEX_DEADLINE_S
        seen_lines = seen_bytes = 0
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None, {"kind": "timeout"}
            with lines_lock:
                while not lines_q:
                    if not lines_lock.wait(timeout=max(0.01, deadline - time.monotonic())):
                        break
                if not lines_q:
                    return None, {"kind": "timeout"}
                raw = lines_q.pop(0)
            if raw is None:
                # stdout closing does NOT mean the child has been reaped yet, so poll()
                # here races and usually returns None - which would report a codex that
                # died with a config error as "replied with no usable limits" and send
                # the user looking at their plan instead of their install. Wait for the
                # real status; only a child that is somehow still alive falls through.
                try:
                    rc = proc.wait(timeout=2)
                except Exception:
                    rc = proc.poll()
                if rc not in (None, 0):
                    return None, {"kind": "exited", "status": rc, "detail": stderr_first_line()}
                return None, {"kind": "parse-fail", "detail": "closed stdout before answering"}

            seen_lines += 1
            seen_bytes += len(raw)
            if seen_lines > CODEX_MAX_LINES or seen_bytes > CODEX_MAX_BYTES:
                return None, {"kind": "parse-fail", "detail": "too much output before answering"}

            try:
                msg = json.loads(raw)
            except Exception:
                continue  # notifications, log noise, a half-line - not a failure
            if not isinstance(msg, dict):
                continue
            # Replies can arrive out of order and notifications carry no id at all, so
            # match the id we asked for rather than trusting position.
            if _epoch(msg.get("id")) != req_id:
                continue
            err = msg.get("error")
            if isinstance(err, dict):
                # error.data may echo upstream response text - the message only.
                return None, {"kind": "rpc", "code": err.get("code"),
                              "detail": str(err.get("message") or "")}
            snap = parse_rate_limits(msg.get("result"), int(time.time()))
            if snap is None:
                return None, {"kind": "parse-fail", "detail": "no usable primary window"}
            return snap, None
    finally:
        # Close stdin first (the app-server exits on stdio close), then give it a moment,
        # then kill the group.
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.wait(timeout=2)
        except Exception:
            kill_codex(proc)


def codex_failure_rows(failure, path, tried, strings=None):
    """One human sentence, then a dim row that says exactly where we looked, then the
    issues link. The dim row is what makes a bug report actionable."""
    kind = failure.get("kind")
    code = failure.get("code")
    detail = str(failure.get("detail") or "")

    if kind == "rpc":
        # -32600 is JSON-RPC's generic "invalid request" - the server returns it for
        # rejected params too, so only the message makes it a sign-in problem. Telling a
        # -32603 (backend) or -32601 (outdated binary) user to sign in sends them nowhere.
        if code == -32600 and "auth" in detail.lower():
            msg = "Sign in to Codex to sync."
        elif code == -32601:
            msg = "This Codex build is too old to report rate limits."
        elif code == -32603:
            msg = "Codex sync failed."
        elif code == -32001:
            msg = "Codex is overloaded - try again shortly."
        elif code is not None:
            msg = f"Codex error {code}."
        else:
            msg = "Codex sync failed."
    elif kind == "binary-missing":
        msg = "Codex CLI not found."
    elif kind == "interpreter-missing":
        msg = "Found the Codex CLI, but not the interpreter it needs (install Node, or use the app's own build)."
    elif kind == "quarantine":
        msg = "macOS blocked it. Run it once from a terminal, or clear quarantine: xattr -d com.apple.quarantine " + (path or "<path>")
    elif kind == "timeout":
        msg = "Codex didn't answer in time."
    elif kind == "exited":
        status = failure.get("status")
        msg = f"The Codex CLI exited before answering (status {status})."
        # A negative status is a signal on POSIX - most often the kernel refusing to run
        # a quarantined binary, which no amount of retrying fixes.
        if isinstance(status, int) and status < 0:
            msg += " macOS may have blocked it: xattr -d com.apple.quarantine " + (path or "<path>")
    elif kind == "spawn-failed":
        msg = "Couldn't start the Codex CLI."
    else:
        msg = "Codex replied, but with no usable limits."

    rows = [line(msg, color=RED)]
    if detail and kind in ("exited", "spawn-failed", "rpc", "parse-fail"):
        rows.append(line(detail, color=DIM, size="11"))
    if path:
        rows.append(line(f"Using: {path}", color=DIM, size="11"))
    else:
        rows.append(line("Looked in: " + ", ".join(tried), color=DIM, size="11"))
    rows.append(line("Report a Codex problem", href=ISSUES, color=DIM, size="11"))
    return rows


def codex_rows(env, home, which):
    """Return (p5, rows). rows is empty ONLY when Codex is switched off."""
    if not codex_enabled(env):
        return None, []
    path, tried = find_codex(env, home, which)
    if not path:
        return None, codex_failure_rows({"kind": "binary-missing"}, None, tried)
    snap, failure = read_codex(path, home, env)
    if failure is not None:
        return None, codex_failure_rows(failure, path, tried)

    rows = [line(f"5-hour   {round(snap['p5'])}%", color=color_for(snap["p5"]))]
    if snap["r5"]: rows.append(line(remaining(snap["r5"]), color=DIM, size="11"))
    if snap["p7"] is None:
        # Not every plan reports a weekly window. "--%" says "no reading"; a 0% bar would
        # say "you have used none of it", which is a different and untrue claim.
        rows.append(line("Weekly   --%", color=MUTED))
    else:
        rows.append(line(f"Weekly   {round(snap['p7'])}%", color=color_for(snap["p7"])))
        if snap["r7"]: rows.append(line(remaining(snap["r7"]), color=DIM, size="11"))
    return snap["p5"], rows


# ======================= compose =======================

def title(p_claude, p_codex, two_part):
    if not two_part:
        if p_claude is None:
            return line("Moth", color=MUTED)
        return line(f"{round(p_claude)}%", color=color_for(p_claude))
    # Fixed order, Claude first, so the menu bar never reshuffles under you.
    c = f"{round(p_claude)}%" if p_claude is not None else "--%"
    x = f"{round(p_codex)}%" if p_codex is not None else "--%"
    hottest = max([p for p in (p_claude, p_codex) if p is not None], default=None)
    return line(f"Cl {c} · Co {x}", color=color_for(hottest))


def main(env, home, which=None):
    if which is None:
        import shutil
        which = shutil.which

    # Per-section guards: an unexpected shape on one provider degrades that provider's
    # rows and leaves the other's alone. A single try around both would let a Codex
    # surprise blank the Claude numbers the user actually came for.
    try:
        p_claude, rows_claude = claude_rows(env)
    except Exception as e:
        p_claude, rows_claude = None, [line(f"Couldn't render usage ({type(e).__name__}).", color=RED)]
    try:
        p_codex, rows_codex = codex_rows(env, home, which)
    except Exception as e:
        p_codex, rows_codex = None, [line(f"Couldn't read Codex ({type(e).__name__}).", color=RED)]

    out = [title(p_claude, p_codex, bool(rows_codex))]
    out.append("---")
    out.append(line("Moth - Claude usage", color=DIM))
    out.append("---")
    out.extend(rows_claude)
    if rows_codex:
        out.append("---")
        out.append(line("Codex usage", color=DIM))
        out.append("---")
        out.extend(rows_codex)
    out.append("---")
    out.append(line("Refresh", refresh="true"))
    print("\n".join(out))


# Guarded so the fixture harness can exec this same text as a module and drive main()
# itself with injected seams. Run normally (python reading this heredoc), __name__ IS
# "__main__" and the menu prints exactly as before.
if __name__ == "__main__":
    main(os.environ, os.path.expanduser("~"))
PYEOF
