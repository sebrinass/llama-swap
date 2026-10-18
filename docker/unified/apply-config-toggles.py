#!/usr/bin/env python3
"""Comment out llama-swap config entries whose component was left out of the
image build, so the baked-in config never references a missing binary.

Matching is CONTENT-based (what the entry's cmd actually invokes), not
name-based: the entry key can be anything ("Swift-Qwen3.8-27b", ...), but the
cmd line always references the engine's install path / binary:

    llama-server / audiocpp_server|audiocpp_cli / /opt/sglang-venv /
    /opt/vllm-venv (or `vllm serve`) / /opt/strata / sd-server|sd-cli

Entry-name fallbacks (legacy config.example.yaml keys) are kept so older
configs behave identically:

    "llama" -> INCLUDE_LLAMA, "tts" -> INCLUDE_AUDIOCPP,
    "sglang-agent" -> INCLUDE_SGLANG

Usage: apply-config-toggles.py <config.yaml>
The toggles are read from the environment (the Dockerfile exports them as ENV).
"""
import os
import re
import sys

# Entry keys may contain dots (e.g. "Swift-Qwen3.8-27b" in the live config) -
# without '.' in the class a dotted key fails to match and the entry swallows
# the following one.
KEY_RE = re.compile(r'^  "?([A-Za-z0-9_.\-]+)"?:')

# Content patterns (checked against the entry's NON-COMMENT lines) -> toggle.
# Order matters only for reporting; every pattern that matches contributes.
CONTENT_RULES = [
    ("llama-server", "INCLUDE_LLAMA"),
    ("audiocpp", "INCLUDE_AUDIOCPP"),
    ("/opt/sglang-venv", "INCLUDE_SGLANG"),
    ("/opt/vllm-venv", "INCLUDE_VLLM"),
    ("vllm serve", "INCLUDE_VLLM"),
    ("/opt/strata", "INCLUDE_STRATA"),
    ("sd-server", "INCLUDE_SD"),
    ("sd-cli", "INCLUDE_SD"),
]

# Legacy name-based fallbacks (config.example.yaml entry keys).
NAME_TOGGLE = {
    "llama": "INCLUDE_LLAMA",
    "tts": "INCLUDE_AUDIOCPP",
    "sglang-agent": "INCLUDE_SGLANG",
}


def toggles() -> dict:
    names = {rule[1] for rule in CONTENT_RULES} | set(NAME_TOGGLE.values())
    return {name: os.environ.get(name, "1") for name in names}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: apply-config-toggles.py <config.yaml>", file=sys.stderr)
        return 2

    tg = toggles()
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

        # Which components does this entry depend on?
        deps = set()
        if key in NAME_TOGGLE:
            deps.add(NAME_TOGGLE[key])
        for bl in block:
            if bl.lstrip().startswith("#"):
                continue  # comments never count as a dependency
            for pattern, toggle in CONTENT_RULES:
                if pattern in bl:
                    deps.add(toggle)

        missing = sorted(d for d in deps if tg.get(d, "1") != "1")
        if missing:
            out.extend("# " + l if l.strip() else l for l in block)
            commented.append("%s (needs %s)" % (key, ", ".join(missing)))
        else:
            out.extend(block)

    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(out)

    if commented:
        print("apply-config-toggles: commented out entries for disabled "
              "components: " + "; ".join(commented))
    else:
        print("apply-config-toggles: all model entries kept (components enabled)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
