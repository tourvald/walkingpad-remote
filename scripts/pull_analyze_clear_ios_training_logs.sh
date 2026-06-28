#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$script_dir/pull_ios_training_logs.sh" --clear-device-logs-after-pull "$@"
