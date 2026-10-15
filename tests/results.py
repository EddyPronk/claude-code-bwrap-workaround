#!/usr/bin/python3
"""results.py < STREAM — the Bash calls and their exact results from `claude -p --output-format
stream-json --verbose` (Claude Code's record of the tool output, not the model's retelling of it).
Prints each call with any flags (dangerouslyDisableSandbox would show), then its result."""
import json
import sys

calls = {}
for line in sys.stdin:
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    if entry.get("type") not in ("assistant", "user"):
        continue
    content = (entry.get("message") or {}).get("content")
    if not isinstance(content, list):
        continue
    for c in content:
        if c.get("type") == "tool_use" and c.get("name") == "Bash":
            calls[c["id"]] = c["input"]
        elif c.get("type") == "tool_result" and c.get("tool_use_id") in calls:
            inp = calls[c["tool_use_id"]]
            text = c.get("content")
            if isinstance(text, list):
                text = "\n".join(p.get("text", "") for p in text if isinstance(p, dict))
            flags = ", ".join(f"{k}={v}" for k, v in inp.items() if k not in ("command", "description"))
            print(f"$ {inp.get('command')}" + (f"   [{flags}]" if flags else ""))
            print(text or "")
