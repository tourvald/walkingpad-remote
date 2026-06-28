#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${BLE_VENV_DIR:-"$ROOT_DIR/.venv-ble"}"

find_python() {
  if [[ -n "${BLE_PYTHON:-}" ]]; then
    printf '%s\n' "$BLE_PYTHON"
    return
  fi

  local candidates=(
    "/opt/homebrew/bin/python3.12"
    "/usr/local/bin/python3.12"
    "python3.12"
    "python3"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if ! command -v "$candidate" >/dev/null 2>&1; then
      continue
    fi
    if "$candidate" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
    then
      command -v "$candidate"
      return
    fi
  done

  return 1
}

PYTHON_BIN="$(find_python || true)"
if [[ -z "$PYTHON_BIN" ]]; then
  cat >&2 <<'EOF'
No suitable Python >= 3.10 was found.
Install Python 3.12, for example:
  brew install python@3.12
Or set BLE_PYTHON=/path/to/python3.12 and re-run this script.
EOF
  exit 1
fi

echo "Using Python: $PYTHON_BIN"
echo "Creating BLE venv: $VENV_DIR"
"$PYTHON_BIN" -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$ROOT_DIR/requirements-ble.txt"

echo "BLE tool environment ready."
"$VENV_DIR/bin/python" --version
"$VENV_DIR/bin/python" -m pip show bleak | awk '/^Version:/{print "bleak " $2}'
