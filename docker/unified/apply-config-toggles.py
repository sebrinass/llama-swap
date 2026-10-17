#!/usr/bin/env python3
"""Comment out llama-swap config entries whose component was left out of the
image build, so the baked-in config never references a missing binary.

Mapping (model entry name -> component toggle):
    "llama"        -> INCLUDE_LLAMA       (llama-server)
    "tts"          -> INCLUDE_AUDIOCPP    (audiocpp_server)
    "sglang-agent" -> INCLUDE_SGLANG      (/opt/sglang-venv)

Usage: apply-config-toggles.py <config.yaml>
The toggles are read from the environment (the Dockerfile exports them as ENV).
"""
import os
import re
import sys

KEY_RE = re.compile(r'^  "?([A-Za-z0-9_-]+)"?:')
TOGGLE = {
    "llama": os.environ.get("INCLUDE_LLAMA", "1"),
    "tts": os.environ.get("INCLUDE_AUDIOCPP", "1"),
    "sglang-agent": os.environ.get("INCLUDE_SGLANG", "1"),
}


def main() -> int:
    path = sys.argv[1]
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()

    out = []
    i = 0
    n = len(lines)

    # Pass through everything up to (and including) the top-level "models:" key
    while i < n and not lines[i].startswith("models:"):
        out.append(lines[i])
        i += 1
    if i >= n:
        print("apply-config-toggles: no models: section, nothing to do")
        return 0
    out.append(lines[i])
    i += 1

    commented = []
    while i < n:
        line = lines[i]
        m = KEY_RE.match(line)
        if not m:
            out.append(line)
            i += 1
            continue
        key = m.group(1)
        # Collect the whole block: until the next 2-space key or a dedent
        block = [line]
        i += 1
        while i < n:
            nxt = lines[i]
            if KEY_RE.match(nxt) or re.match(r"^\S", nxt):
                break
            block.append(nxt)
            i += 1
        if TOGGLE.get(key, "1") != "1":
            out.extend("# " + l if l.strip() else l for l in block)
            commented.append(key)
        else:
            out.extend(block)

    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(out)

    if commented:
        print("apply-config-toggles: commented out entries for disabled "
              "components: " + ", ".join(commented))
    else:
        print("apply-config-toggles: all model entries kept (components enabled)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
