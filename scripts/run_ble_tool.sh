#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${BLE_VENV_DIR:-"$ROOT_DIR/.venv-ble"}"
PYTHON_BIN="$VENV_DIR/bin/python"

if [[ ! -x "$PYTHON_BIN" ]]; then
  cat >&2 <<EOF
BLE tool environment is not ready.
Run:
  ./scripts/setup_ble_env.sh
EOF
  exit 1
fi

cd "$ROOT_DIR"
exec "$PYTHON_BIN" "$ROOT_DIR/scan_ble.py" "$@"
