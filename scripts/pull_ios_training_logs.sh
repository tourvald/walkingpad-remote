#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/pull_ios_training_logs.sh --device <device-id-or-name> [--bundle-id sw.WalkingPadRemote] [--out-dir /tmp/path] [--no-analyze] [--clear-device-logs-after-pull]

Read-only helper for pulling WalkingPadRemote raw TrainingLogs JSONL files from an iPhone app container.
By default it does not launch the app, connect to BLE, or send treadmill commands.
With --clear-device-logs-after-pull it launches the app once with a debug cleanup argument after a successful pull/analyze.
USAGE
}

device=""
bundle_id="sw.WalkingPadRemote"
out_dir=""
analyze=1
clear_device_logs_after_pull=0
analyzer_exit=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      device="${2:-}"
      shift 2
      ;;
    --bundle-id)
      bundle_id="${2:-}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:-}"
      shift 2
      ;;
    --no-analyze)
      analyze=0
      shift
      ;;
    --clear-device-logs-after-pull)
      clear_device_logs_after_pull=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$device" ]]; then
  echo "Missing required --device" >&2
  usage >&2
  exit 2
fi

if [[ -z "$out_dir" ]]; then
  out_dir="/tmp/walkingpad_ios_training_logs_$(date +%Y%m%d_%H%M%S)"
fi

mkdir -p "$out_dir"

xcrun devicectl device copy from \
  --device "$device" \
  --domain-type appDataContainer \
  --domain-identifier "$bundle_id" \
  --source 'Library/Application Support/TrainingLogs' \
  --destination "$out_dir" \
  --timeout 30

echo "pulled_dir=$out_dir"
jsonl_count="$(find "$out_dir" -type f -name '*.jsonl' | wc -l | tr -d ' ')"
echo "jsonl_count=$jsonl_count"

if [[ "$jsonl_count" = "0" ]]; then
  echo "No raw TrainingLogs JSONL files found."
  exit 0
fi

find "$out_dir" -type f -name '*.jsonl' -print | sort

if [[ "$analyze" = "1" ]]; then
  set +e
  python3 tools/analyze_training_log.py "$out_dir"
  analyzer_exit=$?
  set -e
  echo "analyzer_exit=$analyzer_exit"
fi

if [[ "$clear_device_logs_after_pull" = "1" ]]; then
  if [[ "$analyze" = "1" && "$analyzer_exit" != "0" ]]; then
    echo "device_log_cleanup=skipped_analyzer_failed"
    exit "$analyzer_exit"
  fi

  xcrun devicectl device process launch \
    --device "$device" \
    --terminate-existing \
    --timeout 30 \
    "$bundle_id" \
    --clear-training-logs-on-launch

  echo "device_log_cleanup=requested"
fi
