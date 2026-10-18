"""Local test for apply-config-toggles.py (content-based matching)."""
import os
import re
import subprocess
import sys
import tempfile

SCRIPT = r"D:\项目\ninfer-研究\llama-swap\docker\unified\apply-config-toggles.py"

CONFIG = """healthCheckTimeout: 300
logRequests: true

models:
  "llama":
    cmd: >
      llama-server
      --model /models/Qwen3-ASR-1.7B-Q8_0.gguf
      --port ${PORT}

  "tts":
    checkEndpoint: /health
    cmd: >
      audiocpp_server
      --task tts
      --port ${PORT}

  "sglang-agent":
    cmd: >
      /opt/sglang-venv/bin/python -m sglang.launch_server
      --model-path Qwen/Qwen3-7B-Instruct

  # arbitrary name, vllm venv path (like the live "Swift-Qwen3.8-27b" entry)
  "Swift-Qwen3.8-27b":
    cmd: >
      /opt/vllm-venv/bin/vllm serve /models/Swift-Qwen3.8-27b
      --port ${PORT}

  # arbitrary name, vllm serve via PATH only
  "path-vllm":
    cmd: vllm serve /models/foo

  # arbitrary name, strata via sh -c wrapper (like the live entry)
  "strata-flash-next":
    cmd: sh -c 'cd /opt/strata && exec .venv/bin/python serve/server.py --port ${PORT}'

  # arbitrary name, sd binary
  "my-sd":
    cmd: sd-server --model /models/sd

  # comment-trap: mentions /opt/vllm-venv in a COMMENT but runs llama-server
  "trap-entry":
    cmd: >
      llama-server
      # fallback would be /opt/vllm-venv/bin/vllm serve ...
      --model /models/x.gguf

groups:
  - name: all
    members:
      - llama
"""

# A commented entry's key line looks like: #   "name":  (script prefixes "# "
# to the 2-space-indented key line, and a key line has nothing after the colon)
COMMENTED_KEY_RE = re.compile(r'^#   "?([A-Za-z0-9_.\-]+)"?:\s*$')

CASES = [
    # (env overrides, expected-commented entry names)
    ({}, set()),
    ({"INCLUDE_LLAMA": "0"}, {"llama", "trap-entry"}),  # trap-entry RUNS llama-server
    ({"INCLUDE_AUDIOCPP": "0"}, {"tts"}),
    ({"INCLUDE_SGLANG": "0"}, {"sglang-agent"}),
    ({"INCLUDE_VLLM": "0"}, {"Swift-Qwen3.8-27b", "path-vllm"}),
    ({"INCLUDE_STRATA": "0"}, {"strata-flash-next"}),
    ({"INCLUDE_SD": "0"}, {"my-sd"}),
    ({"INCLUDE_SD": "1"}, set()),
    # everything off at once
    ({"INCLUDE_LLAMA": "0", "INCLUDE_AUDIOCPP": "0", "INCLUDE_SGLANG": "0",
      "INCLUDE_VLLM": "0", "INCLUDE_STRATA": "0", "INCLUDE_SD": "0"},
     {"llama", "tts", "sglang-agent", "Swift-Qwen3.8-27b", "path-vllm",
      "strata-flash-next", "my-sd", "trap-entry"}),
]

fails = 0
for env_extra, expected in CASES:
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8") as fh:
        fh.write(CONFIG)
        path = fh.name
    env = dict(os.environ)
    for k in ("INCLUDE_LLAMA", "INCLUDE_AUDIOCPP", "INCLUDE_SGLANG",
              "INCLUDE_VLLM", "INCLUDE_STRATA", "INCLUDE_SD"):
        env.pop(k, None)
    env.update(env_extra)
    r = subprocess.run([sys.executable, SCRIPT, path], capture_output=True, text=True, env=env)
    out = r.stdout.strip()
    with open(path, encoding="utf-8") as fh:
        result = fh.read()
    commented = set()
    for line in result.split("\n"):
        m = COMMENTED_KEY_RE.match(line)
        if m:
            commented.add(m.group(1))
    ok = commented == expected
    status = "PASS" if ok else "FAIL"
    if not ok:
        fails += 1
    print(f"[{status}] env={env_extra or 'all-on'}")
    if not ok:
        print(f"       commented={sorted(commented)}")
        print(f"       expected ={sorted(expected)}")
        print(f"       script said: {out}")
    os.unlink(path)

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURES")
sys.exit(1 if fails else 0)
