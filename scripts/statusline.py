#!/usr/bin/env python3
"""Claude Code status line: model · context used · plan usage (5h / 7d) with time to reset."""
import json, sys, time

d = json.load(sys.stdin)
GREEN, YELLOW, RED, DIM, RESET = "\033[32m", "\033[33m", "\033[31m", "\033[2m", "\033[0m"

def color(pct):
    return GREEN if pct < 50 else YELLOW if pct < 80 else RED

def until(ts):
    s = max(0, int(ts - time.time()))
    d_, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    return f"{d_}d{h}h" if d_ else f"{h}h{m:02d}m" if h else f"{m}m"

parts = [d.get("model", {}).get("display_name", "Claude")]
ctx = d.get("context_window", {}).get("used_percentage")
if ctx is not None:
    parts.append(f"ctx {color(ctx)}{ctx}%{RESET}")
for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
    r = (d.get("rate_limits") or {}).get(key)
    if r and r.get("used_percentage") is not None:
        pct = r["used_percentage"]
        reset = f" {DIM}↻{until(r['resets_at'])}{RESET}" if r.get("resets_at") else ""
        parts.append(f"{label} {color(pct)}{pct}%{RESET}{reset}")
print(f" {DIM}·{RESET} ".join(parts))
