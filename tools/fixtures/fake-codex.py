#!/usr/bin/env python3
"""A stand-in for `codex app-server`, so the Mac plugin's error paths are testable.

It speaks just enough JSON-RPC to be mistaken for the real thing: reads the three
messages the plugin writes, then plays one named scenario. Every scenario is a real
shape observed in, or documented by, the app-server - not an invented one.

  python fake-codex.py [-s read-only ...] app-server --stdio
  scenario comes from FAKE_CODEX_SCENARIO in the environment (the plugin builds the
  argument list itself, so the harness cannot pass it as an argument).
"""
import json
import os
import sys
import time

NOW = int(float(os.environ.get("FAKE_CODEX_NOW", "1788460000")))

# resetsAt values are relative to the harness's pinned clock so the rendered countdowns
# are stable. windowDurationMins mirrors the real reply.
FULL = {
    "rateLimitsByLimitId": {
        "codex": {
            "primary": {"usedPercent": 99.6, "resetsAt": NOW + 3600, "windowDurationMins": 300},
            "secondary": {"usedPercent": 16.2, "resetsAt": NOW + 400000, "windowDurationMins": 10080},
            "planType": "team",
        }
    },
    # Fields Moth must never copy into its output.
    "accountId": "acct_FIXTURE",
    "credits": {"balance": 1234},
    "rateLimitUpsell": {"message": "upgrade!"},
}
CALM = {
    "rateLimits": {
        "primary": {"usedPercent": 17.4, "resetsAt": NOW + 7200, "windowDurationMins": 300},
        "secondary": {"usedPercent": 9.1, "resetsAt": NOW + 400000, "windowDurationMins": 10080},
    },
    "accountId": "acct_FIXTURE",
}
NO_WEEKLY = {
    "rateLimits": {
        "primary": {"usedPercent": 41.0, "resetsAt": NOW + 1800, "windowDurationMins": 300},
        "secondary": None,
    }
}
# Well-formed reply, no usable snapshot: the parse-fail path.
NULL_LIMITS = {"rateLimits": None, "rateLimitsByLimitId": None}

INIT_REPLY = {"jsonrpc": "2.0", "id": 1, "result": {"userAgent": "codex/0.152.0"}}


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def reply(result):
    send({"jsonrpc": "2.0", "id": 2, "result": result})


def error(code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    send({"jsonrpc": "2.0", "id": 2, "error": err})


def drain_requests():
    """Read the three messages the plugin writes. Returns when the id-2 request lands."""
    for _ in range(5):
        raw = sys.stdin.readline()
        if not raw:
            return
        try:
            msg = json.loads(raw)
        except Exception:
            continue
        if msg.get("id") == 2:
            return


def main():
    scenario = os.environ.get("FAKE_CODEX_SCENARIO", "full")

    if scenario == "exit1":
        # Dies before reading anything: the plugin's write may land on a dead pipe.
        sys.stderr.write("codex: fatal: could not open config\nsecond line\n")
        sys.stderr.flush()
        sys.exit(1)

    drain_requests()

    if scenario == "hang":
        time.sleep(600)  # the harness kills us; the plugin must not wait this long
        return
    if scenario == "full":
        send(INIT_REPLY); reply(FULL)
    elif scenario == "calm":
        send(INIT_REPLY); reply(CALM)
    elif scenario == "no-weekly":
        send(INIT_REPLY); reply(NO_WEEKLY)
    elif scenario == "null-limits":
        send(INIT_REPLY); reply(NULL_LIMITS)
    elif scenario == "auth":
        error(-32600, "chatgpt authentication required to read rate limits",
              data={"upstream": "401 Unauthorized body"})
    elif scenario == "not-auth":
        # Same code, different cause: params rejected. Must NOT say "sign in".
        error(-32600, "expected unit for params")
    elif scenario == "too-old":
        error(-32601, "method not found: account/rateLimits/read")
    elif scenario == "backend":
        error(-32603, "failed to fetch codex rate limits: upstream unavailable")
    elif scenario == "overloaded":
        error(-32001, "server overloaded")
    elif scenario == "out-of-order":
        # id 7 first, then a notification, then ours.
        send({"jsonrpc": "2.0", "id": 7, "result": {"rateLimits": {"primary": {"usedPercent": 3}}}})
        send({"jsonrpc": "2.0", "method": "session/updated", "params": {"n": 1}})
        reply(CALM)
    elif scenario == "notify-first":
        for i in range(5):
            send({"jsonrpc": "2.0", "method": "remoteControl/status/changed", "params": {"i": i}})
        reply(CALM)
    elif scenario == "garbage-first":
        sys.stdout.write("not json at all\n")
        sys.stdout.write("{ half an object\n")
        sys.stdout.flush()
        reply(CALM)
    elif scenario == "flood":
        for i in range(300):
            send({"jsonrpc": "2.0", "method": "noise", "params": {"i": i}})
        reply(CALM)  # never reached by a plugin that caps correctly
    elif scenario == "stderr-inject":
        # A hostile-looking stderr line. It must render as inert text, never as a row
        # parameter that SwiftBar would turn into a clickable command.
        sys.stderr.write("boom | bash=rm -rf ~ | terminal=false\n")
        sys.stderr.flush()
        sys.exit(3)
    else:
        raise SystemExit(f"fake-codex: unknown scenario {scenario!r}")


if __name__ == "__main__":
    main()
