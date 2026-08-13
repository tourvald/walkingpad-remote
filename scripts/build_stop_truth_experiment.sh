#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --expected-sha <40-char-git-sha> [--derived-data <path>]" >&2
}

expected_sha=""
derived_data="/tmp/walkingpad-stop-truth-derived-data"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-sha)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      expected_sha="$2"
      shift 2
      ;;
    --derived-data)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      derived_data="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
actual_sha="$(git -C "$repo_root" rev-parse HEAD)"

if [[ ! "$expected_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Expected SHA must be an exact lowercase 40-character git SHA." >&2
  exit 3
fi
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "Build identity mismatch: expected=$expected_sha actual=$actual_sha" >&2
  exit 4
fi
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]]; then
  echo "Refusing experiment-capable build from a dirty worktree." >&2
  exit 5
fi

project_dir="$repo_root/ios/WalkingPadRemote/WalkingPadRemote"
project="$project_dir/WalkingPadRemote.xcodeproj"

xcodebuild \
  -project "$project" \
  -scheme WalkingPadRemote \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) STOP_TRUTH_EXPERIMENT_CAPABILITY" \
  "EXECUTABLE_SUFFIX=-issue14-stop-truth-v1-e${expected_sha}-a${actual_sha}" \
  build

products="$derived_data/Build/Products"
ios_app="$products/Debug-iphoneos/WalkingPadRemote.app"
watch_app="$ios_app/Watch/WalkingPadRemoteWatch Watch App.app"
binding="-issue14-stop-truth-v1-e${expected_sha}-a${actual_sha}"
ios_executable="WalkingPadRemote${binding}"
watch_executable="WalkingPadRemoteWatch Watch App${binding}"

if [[ ! -x "$ios_app/$ios_executable" ]]; then
  echo "Missing exact-bound unsigned iOS executable: $ios_app/$ios_executable" >&2
  exit 6
fi
if [[ ! -x "$watch_app/$watch_executable" ]]; then
  echo "Missing embedded exact-bound unsigned watchOS executable: $watch_app/$watch_executable" >&2
  exit 7
fi

echo "Verified unsigned iOS app: $ios_app"
echo "Verified embedded unsigned watchOS app: $watch_app"
echo "Verified exact build binding: expected=$expected_sha actual=$actual_sha"
