#!/usr/bin/env bash
set -euo pipefail

if ! dig @127.0.0.1 -p 53 localhost A +time=2 +tries=1 +short | grep -q .; then
  exit 1
fi

exit 0
