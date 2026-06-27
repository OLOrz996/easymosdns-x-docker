#!/usr/bin/env bash
set -euo pipefail

if ! pgrep -x mosdns >/dev/null 2>&1; then
  exit 1
fi

if ! dig @127.0.0.1 -p 53 localhost A +time=2 +tries=1 +short | grep -Eq '^127\.0\.0\.1$'; then
  exit 1
fi

exit 0
