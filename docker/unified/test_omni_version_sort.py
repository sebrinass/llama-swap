"""Standalone test of the vkey sort logic used by resolve_omni_version
(the exact same code block, fed a synthetic PyPI-shaped releases dict)."""
import re
import sys


def vkey(v):
    m = re.match(r"^(\d+(?:\.\d+)*)(.*)$", v)
    nums = tuple(int(p) for p in m.group(1).split("."))
    rest = m.group(2)
    if rest == "":
        return (nums, 1, "")
    return (nums, 0, rest)


def pick(releases, prefix):
    cands = []
    for ver, files in releases.items():
        if not files:
            continue
        vm = re.match(r"^(\d+\.\d+)\.", ver)
        if vm and vm.group(1) == prefix:
            cands.append(ver)
    if not cands:
        return None
    cands.sort(key=vkey)
    return cands[-1]


# Synthetic vllm-omni release table (PyPI shape: version -> file list)
RELEASES = {
    "0.28.0": [1], "0.28.0rc1": [1], "0.29.0rc1": [1],
    "0.30.0": [1], "0.30.0rc1": [1],
    "0.31.0rc1": [1],
    "0.26.0rc1": [1], "0.27.0rc1": [1],
    "1.0.0a1": [1],  # alpha of a future major - must NOT match 0.x prefixes
    "0.31.1rc2": [1], "0.31.1": [1],  # future: final must beat its own rc
}

CASES = [
    ("0.31", "0.31.1"),      # newest in line; final 0.31.1 beats 0.31.0rc1/0.31.1rc2
    ("0.30", "0.30.0"),      # final exists -> final wins over rc1
    ("0.29", "0.29.0rc1"),   # only rc
    ("0.28", "0.28.0"),      # final wins
    ("1.0", "1.0.0a1"),      # alpha of next major is still a match for 1.0
    ("0.99", None),          # no such line
]

fails = 0
for prefix, expected in CASES:
    got = pick(RELEASES, prefix)
    ok = got == expected
    if not ok:
        fails += 1
    print(f"[{'PASS' if ok else 'FAIL'}] line {prefix}.x -> {got} (expected {expected})")

# sort sanity: final > rc of same numbers, rc2 > rc1
assert vkey("0.31.0") > vkey("0.31.0rc1")
assert vkey("0.31.1rc2") > vkey("0.31.1rc1")
assert vkey("0.31.1") > vkey("0.31.1rc2")
assert vkey("0.32.0") > vkey("0.31.9")
print("vkey ordering assertions PASS")

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURES")
sys.exit(1 if fails else 0)
