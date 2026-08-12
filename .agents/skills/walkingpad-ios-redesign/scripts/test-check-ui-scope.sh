#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
checker="${script_dir}/check-ui-scope.sh"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/walkingpad-ui-scope.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT

new_fixture() {
  local name=$1
  local repo="${fixture_root}/${name}"
  mkdir -p "${repo}/ios/App" "${repo}/docs/design"
  git -C "$repo" init -q
  git -C "$repo" config user.email "scope-test@example.invalid"
  git -C "$repo" config user.name "Scope Test"
  printf 'final class BluetoothManager {}\n' >"${repo}/ios/App/BluetoothManager.swift"
  printf 'baseline\n' >"${repo}/docs/design/brief.md"
  git -C "$repo" add .
  git -C "$repo" commit -qm baseline
  printf '%s\n' "$repo"
}

expect_forbidden() {
  local repo=$1
  local label=$2
  local output
  local status

  set +e
  output=$(cd "$repo" && "$checker" "$(git rev-parse HEAD)" docs/design/brief.md 2>&1)
  status=$?
  set -e

  if [[ $status -eq 0 || "$output" != *"FORBIDDEN: ios/App/BluetoothManager.swift"* ]]; then
    printf 'FAIL: %s\n%s\n' "$label" "$output" >&2
    return 1
  fi
  printf 'PASS: %s\n' "$label"
}

repo=$(new_fixture unstaged-modification)
printf '// unstaged\n' >>"${repo}/ios/App/BluetoothManager.swift"
expect_forbidden "$repo" "unstaged forbidden modification"

repo=$(new_fixture staged-modification)
printf '// staged\n' >>"${repo}/ios/App/BluetoothManager.swift"
git -C "$repo" add ios/App/BluetoothManager.swift
expect_forbidden "$repo" "staged forbidden modification"

repo=$(new_fixture delete-only)
rm "${repo}/ios/App/BluetoothManager.swift"
expect_forbidden "$repo" "delete-only forbidden path"

repo=$(new_fixture forbidden-rename)
git -C "$repo" mv ios/App/BluetoothManager.swift docs/design/PresentationOwner.swift
expect_forbidden "$repo" "forbidden rename to allowed-looking path"
