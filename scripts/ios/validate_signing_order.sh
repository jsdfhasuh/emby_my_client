#!/usr/bin/env bash
set -euo pipefail

ORDER_FILE="${1:?Usage: validate_signing_order.sh signing-order.txt}"
if [[ ! -f "$ORDER_FILE" ]]; then
  echo "Signing order file is missing: $ORDER_FILE" >&2
  exit 1
fi

awk -F '\t' '
  BEGIN { main_count = 0; line_count = 0; last = ""; failed = 0 }
  NF != 2 { failed = 1; next }
  {
    line_count += 1
    last = $1 "\t" $2
    if ($1 == "embedded") {
      if ($2 == "Runner" || $2 == "") failed = 1
    } else if ($1 == "main") {
      main_count += 1
      if ($2 != "Runner") failed = 1
    } else {
      failed = 1
    }
  }
  END {
    if (line_count == 0 || main_count != 1 || last != "main\tRunner") failed = 1
    exit failed
  }
' "$ORDER_FILE"

echo "signing_order_valid=$ORDER_FILE"
