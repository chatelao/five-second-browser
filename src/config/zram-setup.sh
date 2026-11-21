#!/usr/bin/env bash
set -euo pipefail

MOCK_MODE="${MOCK_MODE:-0}"

if [[ "$MOCK_MODE" == "1" ]]; then
  echo "zram0: mock mode 512M lz4 max_comp_streams=4"
  exit 0
fi

modprobe zram 2>/dev/null || true

if [[ ! -d /sys/block/zram0 ]]; then
  echo "zram0 not available, skipping" >&2
  exit 0
fi

echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
echo 4 > /sys/block/zram0/max_comp_streams 2>/dev/null || true
echo 512M > /sys/block/zram0/disksize

mkswap /dev/zram0 >/dev/null
swapon -p 100 /dev/zram0

sysctl -w vm.swappiness=100 vm.page-cluster=0 >/dev/null 2>&1 || true
