#!/bin/bash
# <xbar.title>Moth</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>vinvomero</xbar.author>
# <xbar.desc>A little menu-bar moth, drawn to your Claude Code usage. Shows the real 5-hour and weekly limit percentages.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
#
# Moth for macOS — a SwiftBar / xbar plugin.
# The 5m in the filename = refresh every 5 minutes (safely above the endpoint's
# ~180s etiquette). Drop this file in your SwiftBar plugins folder, chmod +x it.
#
# Data source: the same undocumented api/oauth/usage endpoint the Windows widget
# uses, with the login token Claude Code already stores. See mac/README.md for the
# honest disclosure. Never runs its own login; never transmits the token anywhere
# except to Anthropic.

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
CLAUDE_CRED="$CRED" "$PY" <<'PYEOF'
import json, os, sys, time, urllib.request

AMBER, ORANGE, RED, MUTED, DIM = "#FFB65C", "#FF9D42", "#FF5C6E", "#8A7B5E", "#6E6552"

def line(text, **attrs):
    parts = [text]
    for k, v in attrs.items():
        parts.append(f"{k}={v}")
    print(" | ".join(parts) if attrs else text)

def bail(menubar, detail):
    line(menubar, color=MUTED)
    print("---")
    line("Moth - Claude usage", color=DIM)
    print("---")
    line(detail, color=RED)
    line("Refresh", refresh="true")
    sys.exit(0)

raw = os.environ.get("CLAUDE_CRED", "")
if not raw.strip():
    bail("Moth", "Not logged in to Claude Code — no credentials found.")

try:
    token = json.loads(raw).get("claudeAiOauth", {}).get("accessToken", "")
except Exception:
    token = ""
if not token:
    bail("Moth", "Logged in, but no access token yet. Open Claude Code, then refresh.")

try:
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            # REQUIRED — without this UA the endpoint hard rate-limits you.
            "User-Agent": "claude-code/2.1.224",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.load(r)
except Exception as e:
    code = getattr(e, "code", None)
    if code == 401:
        bail("Moth", "Token expired — reopen Claude Code to refresh it, then refresh.")
    bail("Moth", f"Couldn't reach the usage endpoint ({code or 'network error'}).")

def pct(bucket):
    u = data.get(bucket, {}).get("utilization")
    if u is None:
        return None
    u = float(u)
    return u * 100 if u <= 1.0 else u  # accept 0-1 or 0-100

def resets(bucket):
    v = data.get(bucket, {}).get("resets_at")
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
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m = s // 60
    if d: return f"resets in {d}d {h}h"
    if h: return f"resets in {h}h {m}m"
    return f"resets in {m}m"

def color_for(p):
    if p is None: return MUTED
    if p >= 90: return RED
    if p >= 70: return ORANGE
    return AMBER

p5, p7 = pct("five_hour"), pct("seven_day")
r5, r7 = resets("five_hour"), resets("seven_day")

# Menu-bar title: the actionable 5-hour number, colored by pressure.
if p5 is None:
    line("Moth", color=MUTED)
else:
    line(f"{round(p5)}%", color=color_for(p5))

print("---")
line("Moth - Claude usage", color=DIM)
print("---")
if p5 is not None:
    line(f"5-hour   {round(p5)}%", color=color_for(p5))
    if r5: line(remaining(r5), color=DIM, size="11")
if p7 is not None:
    line(f"Weekly   {round(p7)}%", color=color_for(p7))
    if r7: line(remaining(r7), color=DIM, size="11")

# Optional per-model weekly bucket, shown when present.
for key in ("seven_day_opus", "seven_day_sonnet", "seven_day_fable"):
    b = data.get(key)
    if b and b.get("utilization") is not None:
        pm = pct(key)
        label = key.replace("seven_day_", "").capitalize()
        line(f"{label} (weekly)   {round(pm)}%", color=color_for(pm))
        break

print("---")
line("Refresh", refresh="true")
PYEOF
