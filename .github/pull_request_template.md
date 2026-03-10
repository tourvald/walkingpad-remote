## Summary

Describe the change in a few sentences.

## Why

Explain the user or engineering problem this PR solves.

## Testing

- [ ] `python3 -m compileall scan_ble.py run_live_stats.py run_menu.py run_workout.py tools/mcp_xcode_server.py`
- [ ] `cd ios/WalkingPadRemote/WalkingPadRemote && swift test`
- [ ] `xcodebuild -project ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote.xcodeproj -scheme WalkingPadRemote -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- [ ] Not applicable; explained below

## Hardware / environment

- Treadmill model:
- Protocol:
- iPhone / iOS:
- Apple Watch / watchOS:

## Screenshots or logs

Add screenshots for UI changes and logs for BLE or protocol changes when relevant.

## Notes for reviewers

- Risk areas:
- Follow-up work:
- Docs updated:
