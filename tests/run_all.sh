#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TESTS=(
  "bash tests/test_fb_splash.sh"
  "bash tests/test_init_lifecycle.sh"
  "python3 tests/test_cache_proxy.py"
  "bash tests/test_net_fast.sh"
  "bash tests/test_checkpoint.sh"
  "bash tests/test_release_bundle.sh"
)

now_ms() {
  python3 -c 'import time; print(int(time.monotonic() * 1000))'
}

total_start="$(now_ms)"
passed=0

for cmd in "${TESTS[@]}"; do
  test_file="${cmd#* }"
  if [[ ! -f "$test_file" ]]; then
    echo "[SKIP] $test_file (not implemented yet)"
    continue
  fi
  t0="$(now_ms)"
  if $cmd; then
    t1="$(now_ms)"
    echo "[PASS] $test_file ($((t1 - t0)) ms)"
    passed=$((passed + 1))
  else
    t1="$(now_ms)"
    echo "[FAIL] $test_file ($((t1 - t0)) ms)"
    exit 1
  fi
done

total_end="$(now_ms)"
echo "All $passed test suite(s) passed in $((total_end - total_start)) ms."
