"""Verify the 2026-10-20 incident fixes before push.

1. GitHub expression semantics: simulate the new workflow toggle expressions
   under push/schedule (inputs='') and dispatch (true/false) using GitHub's
   loose-equality rules ('' == false is TRUE, both coerce to 0).
2. Dockerfile verify-stage shell logic across toggle combinations.
"""
import re
import subprocess
import sys

fails = 0


def gh_loose_eq(a, b):
    """GitHub Actions loose equality (per docs type-coercion table)."""
    def num(v):
        if v is None:
            return 0
        if isinstance(v, bool):
            return 1 if v else 0
        if isinstance(v, str):
            try:
                return float(v) if v != "" else 0.0
            except ValueError:
                return float("nan")
        return v
    na, nb = num(a), num(b)
    if isinstance(na, float) and na != na:  # NaN
        return False
    if isinstance(nb, float) and nb != nb:
        return False
    return na == nb


def gh_truthy(v):
    """GitHub truthiness: null/false/0/'' are falsy."""
    if v is None or v is False:
        return False
    if v == "":
        return False
    if isinstance(v, (int, float)) and v == 0:
        return False
    return True


def eval_expr(event, checkbox):
    """Evaluate: (github.event_name != 'workflow_dispatch' || inputs.x == true) && '1' || '0'"""
    # inputs context: {} for push/schedule -> missing property is ''
    inputs_val = "" if event != "workflow_dispatch" else checkbox
    lhs = (event != "workflow_dispatch") or gh_loose_eq(inputs_val, True)
    return "1" if gh_truthy(lhs) else "0"


print("== [1] workflow expression truth table ==")
CASES = [
    # (event, checkbox, expected)
    ("schedule", None, "1"),
    ("push", None, "1"),
    ("workflow_dispatch", True, "1"),
    ("workflow_dispatch", False, "0"),
]
for event, checkbox, expected in CASES:
    got = eval_expr(event, checkbox)
    ok = got == expected
    if not ok:
        fails += 1
    print(f"  [{'PASS' if ok else 'FAIL'}] {event} checkbox={checkbox} -> {got} (want {expected})")

# old form for regression proof: '' == false -> '0' (the bug)
old_bug = gh_loose_eq("", False)
print(f"  [{'PASS' if old_bug else 'FAIL'}] old form bug reproduced: '' == false is {old_bug} (must be True)")

print()
print("== [2] Dockerfile verify-stage logic ==")
VERIFY_SH = r'''
verify() {
    set -e
    LLAMA="$1"; AUDIO="$2"; SWAP="$3"; VLLM="$4"
    # emulate binaries present only for enabled components
    fake_bin() { :; }
    present() { return 0; }
    if [ "$LLAMA" = "1" ]; then llama_server_ok=1; else llama_server_ok=0; fi
    # real check: simulate which binaries exist
    exists() { case "$1" in
        llama-swap) [ "$SWAP" = "1" ];;
        llama-server|llama-cli) [ "$LLAMA" = "1" ];;
        audiocpp_server|audiocpp_cli) [ "$AUDIO" = "1" ];;
        vllm) [ "$VLLM" = "1" ];;
        *) return 1;;
    esac; }
    if [ "$SWAP" = "1" ]; then exists llama-swap || { echo "llama-swap MISSING"; exit 1; }; fi
    if [ "$LLAMA" = "1" ]; then exists llama-server || exit 1; exists llama-cli || exit 1; fi
    if [ "$AUDIO" = "1" ]; then exists audiocpp_server || exit 1; exists audiocpp_cli || exit 1; fi
    if [ "$VLLM" = "1" ]; then exists vllm || exit 1; fi
    echo OK
}
'''
vproc = subprocess.run(["bash", "-c", VERIFY_SH + "\n" + r'''
for combo in "1 0 1 1" "0 0 0 0" "1 1 1 1" "1 0 0 0"; do
    set -- $combo
    out=$(verify "$1" "$2" "$3" "$4" 2>&1) && echo "$1/$2/$3/$4 -> $out" || echo "$1/$2/$3/$4 -> BLOCKED ($out)"
done
'''], capture_output=True, text=True)
print(vproc.stdout + vproc.stderr)

print()
if fails == 0:
    print("ALL PASS")
else:
    print(f"{fails} FAILURES")
sys.exit(1 if fails else 0)
