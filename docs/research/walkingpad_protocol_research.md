# WalkingPad / KingSmith protocol research

Date: 2026-06-28
Branch context: `safety/units-gate-with-queryparams`
Scope: discovery only. No BLE writes, no unit switching, no firmware actions.

## 1. Executive summary

The public evidence supports two distinct KingSmith / WalkingPad control families:

1. Legacy WiLink / WalkingPad BLE protocol over service `0xFE00`, notify `0xFE01`,
   write `0xFE02`, with frames starting `F7` for writes and `F8` for responses.
2. Newer FTMS devices over service `0x1826`, plus KingSmith vendor channels
   such as ODM `d18d2c10-...` and Supplement `24e2521c-...`.

For the affected KS-F0 path in this app, the most relevant confirmed facts are:

- `queryParams` read packet is `F7 A6 00 00 00 00 00 A6 FD`.
- `queryParams.unit == 0` means metric controller preference.
- `queryParams.unit == 1` means imperial controller preference.
- Legacy set-unit is probably `F7 A6 08 00 00 00 <0|1> <crc> FD`, based on
  two independent reverse-engineered projects, but it is not safe to write from
  this app yet.
- Standard legacy stop is speed raw zero: `F7 A2 01 00 A3 FD`.
- Standby assist is mode standby: `F7 A2 02 02 A6 FD`.
- FTMS stop is standard Control Point `0x08 0x01`, but KingSmith FTMS devices
  may confirm through `0x2ADA` status events rather than Control Point
  indications.

Main conclusion: the current P0 safety approach is correct. Use
`queryParams.unit` for warning/gating. Do not auto-switch units. Do not
auto-convert HR-control commands on imperial. Do not unlock HR-control from
`confirmedImperial` until a separate product design covers command semantics,
UI, telemetry, and stop reliability.

## 2. Confirmed facts

### Legacy WiLink / FE00 protocol

- BLE service and characteristics:
  - service: `0000FE00-0000-1000-8000-00805F9B34FB`
  - notifications: `FE01`
  - writes: `FE02`
- Legacy control frame shape:
  - byte command: `F7 A2 <cmd> <value> <crc> FD`
  - preference/int command: `F7 A6 <key> <type> <u24-value> <crc> FD`
  - checksum: sum of bytes from index 1 through the byte before checksum,
    modulo 256.
- Mode values:
  - `0` = auto
  - `1` = manual
  - `2` = standby/sleep
- Common commands:
  - query status: `F7 A2 00 00 A2 FD`
  - set speed: `F7 A2 01 <rawTenths> <crc> FD`
  - stop by speed zero: `F7 A2 01 00 A3 FD`
  - set mode manual: `F7 A2 02 01 A5 FD`
  - set mode standby: `F7 A2 02 02 A6 FD`
  - start: `F7 A2 04 01 A7 FD`
  - query params: `F7 A6 00 00 00 00 00 A6 FD`
  - sync record / last status: `F7 A7 AA <n> <crc> FD`
- Current status response is `F8 A2 ... FD`.
- Params response is `F8 A6 ... FD`; field `m[13]` is unit preference.
- `unit=0` is metric and `unit=1` is imperial in ph4-walkingpad, QWalkingPad,
  and this app's parser/tests.

### Current app facts

- `BLETransportCodec.buildWalkingPadQueryParamsPacket()` builds
  `F7 A6 00 00 00 00 00 A6 FD`.
- `BLETransportCodec.parseWalkingPadParams(_:)` parses unit byte at index `13`
  and normalizes `0 -> metric`, `1 -> imperial`, other values to unknown.
- `BluetoothManager` auto-queries params after WalkingPad connect.
- `BluetoothManager` stop sequence for WalkingPad sends speed zero, then
  verifies, then can send standby and stop retries if the belt is still not
  confirmed stopped.
- Telemetry already treats imperial device-reported distance as raw/unknown,
  not factual meters.

### FTMS / newer KingSmith devices

- Newer KingSmith devices may use standard FTMS service `0x1826`.
- Standard FTMS command characteristics:
  - `0x2AD9` Fitness Machine Control Point
  - `0x2ACD` Treadmill Data
  - `0x2ADA` Fitness Machine Status
  - `0x2AD4` Supported Speed Range
- FTMS set speed is `0x02 + uint16-le(speed * 100)` in km/h.
- FTMS start is `0x07`.
- FTMS stop/pause is `0x08 + 0x01/0x02`.
- KingSmith MC-21-class devices may need an ODM pre-amble
  `01 00 0D 00 06 0B 0F 0D` before FTMS commands.

## 3. Probable but unconfirmed facts

- Legacy `setUnit` is probably `A6 key 8`, value `0` metric or `1` imperial.
  This is supported by ph4-walkingpad and QWalkingPad.
- On some devices, `unit=1` may mean that the raw speed command is interpreted
  physically as mph. The owner's no-load observation supports that for the
  affected treadmill, but public sources do not prove it for every model.
- `queryParams.unit` is a reliable controller preference signal, but not a
  universal proof of physical command semantics.
- Device-reported legacy distance has often been interpreted as 10-meter units
  in metric mode, but this must not be treated as factual meters in imperial
  diagnostic mode without external evidence.
- The affected KS-F0 stop issue is probably not caused by the units safety
  implementation, because the same standard stop commands are used by other
  projects and by this app. However, the root cause remains unproven.

## 4. Dangerous / unknown areas

- `setUnit` / `A6 key 8` writes are dangerous until tested separately. They may
  alter controller settings, display units, app behavior, or physical command
  semantics.
- Firmware / OTA is out of scope. Public sources confirm OTA-related channels
  and app functionality, but not a complete safe update protocol.
- Service menu items `F1/F2/F3/F4/F5/G01` were not found in high-confidence
  public protocol sources. Treat them as unknown and unsafe.
- Vendor Supplement service `24e2521c-...` exposes actions such as device
  unlock, property list, system info, and OTA in KS Fit reverse-engineering
  notes. It should not be used without a dedicated design and safety review.
- KingSmith FTMS devices can have non-standard ACK behavior. Lack of a Control
  Point indication is not always failure, and status must be verified through
  telemetry.
- Multi-client behavior is risky: official apps and third-party controllers can
  compete for one BLE connection.

## 5. Protocol map

### Command map

| Command | Packet / UUID | Meaning | Read/Write | Persistent? | Known models | Source |
|---|---|---|---|---|---|---|
| Query status | `F7 A2 00 00 A2 FD` | request current legacy status | write request, notify response | no | A1/C1/R1-class legacy WiLink | ph4, QWalkingPad |
| Current status | `F8 A2 ... FD` | status frame with state/speed/time/distance/steps | notify | no | A1/C1/R1-class legacy WiLink | ph4, QWalkingPad, current app |
| Set speed | `F7 A2 01 <rawTenths> <crc> FD` | set target speed raw tenths | write | no | A1/C1/R1-class legacy WiLink, KS-F0 in current app | ph4, QWalkingPad, current app |
| Stop | `F7 A2 01 00 A3 FD` | stop by target speed zero | write | no | A1/C1/R1-class legacy WiLink, KS-F0 in current app | ph4, current app |
| Set mode | `F7 A2 02 <mode> <crc> FD` | auto/manual/standby | write | partly stateful, persistence unproven | A1/C1/R1-class legacy WiLink, KS-F0 in current app | ph4, QWalkingPad |
| Standby | `F7 A2 02 02 A6 FD` | put controller into standby/sleep | write | partly stateful, persistence unproven | A1/C1/R1-class legacy WiLink, KS-F0 in current app | ph4, current app |
| Start | `F7 A2 04 01 A7 FD` | start/resume belt | write | no | A1/C1/R1-class legacy WiLink, KS-F0 in current app | ph4, QWalkingPad, current app |
| Query params | `F7 A6 00 00 00 00 00 A6 FD` | read controller params/preferences | write request, notify response | no write-side persistence | A1/C1/R1-class legacy WiLink, KS-F0 in current app | QWalkingPad, current app |
| Params response | `F8 A6 ... FD` | goal/max/start/unit/controller prefs | notify | reports persistent prefs | A1/C1/R1-class legacy WiLink, KS-F0 in current app | QWalkingPad, current app |
| Set max speed | `F7 A6 03 00 <u24> <crc> FD` | max speed preference | write | probably yes | A1/C1/R1-class legacy WiLink | ph4, QWalkingPad |
| Set start speed | `F7 A6 04 00 <u24> <crc> FD` | start speed preference | write | probably yes | A1/C1/R1-class legacy WiLink | ph4, QWalkingPad |
| Set auto-start | `F7 A6 05 00 <u24> <crc> FD` | automatic start preference | write | probably yes | A1/C1/R1-class legacy WiLink | ph4, QWalkingPad |
| Set sensitivity | `F7 A6 06 00 <u24> <crc> FD` | auto-mode sensitivity | write | probably yes | A1/C1/R1-class legacy WiLink | ph4, QWalkingPad |
| Set display mask | `F7 A6 07 00 <u24> <crc> FD` | display fields | write | probably yes | A1/C1/R1-class legacy WiLink | ph4, QWalkingPad |
| Set unit | `F7 A6 08 00 00 00 <0|1> <crc> FD` | metric/imperial preference | write | probably yes, not safely proven per model | A1/C1/R1-class legacy WiLink; KS-F0 unknown/unsafe | ph4, QWalkingPad |
| Set child lock | `F7 A6 09 00 <u24> <crc> FD` | child lock preference | write | probably yes | A1/C1/R1-class legacy WiLink | ph4, QWalkingPad |
| Sync record | `F7 A7 AA <n> <crc> FD` | read/clear last record variants | write request, notify response | can clear stored record | A1/C1/R1-class legacy WiLink | ph4, QWalkingPad |
| FTMS request control | `2AD9: 00` | request FTMS control | write | no | KS-HD, KS-MC21, KS-SMC21C, ZP-ZEALR1-class | mcdax |
| FTMS set speed | `2AD9: 02 <uint16 speed*100>` | set target speed in km/h | write | no | KS-HD, KS-MC21, KS-SMC21C, ZP-ZEALR1-class | mcdax, FTMS |
| FTMS start | `2AD9: 07` | start/resume | write | no | KS-HD, KS-MC21, KS-SMC21C, ZP-ZEALR1-class | mcdax, FTMS |
| FTMS stop | `2AD9: 08 01` | stop | write | no | KS-HD, KS-MC21, KS-SMC21C, ZP-ZEALR1-class | mcdax, FTMS |
| FTMS pause | `2AD9: 08 02` | pause | write | no | KS-HD, KS-MC21, KS-SMC21C, ZP-ZEALR1-class | mcdax, FTMS |
| FTMS speed range | `2AD4` | min/max/increment | read | no | FTMS-capable KingSmith models | mcdax, FTMS |
| FTMS treadmill data | `2ACD` | live speed/distance/time | notify | no | FTMS-capable KingSmith models | mcdax, FTMS |
| FTMS status | `2ADA` | started/stopped/target changed events | notify | no | FTMS-capable KingSmith models | mcdax, FTMS |
| ODM pre-amble | `d18d2c10...: 01 00 0D 00 06 0B 0F 0D` | KingSmith MC-21 unlock/property pre-amble | write | no known persistence | KS-MC21 / KS-SMC21C / ZP-ZEALR1 | mcdax |
| Supplement property/OTA | `24e2521c...`, `32e2314c...` | vendor properties, OTA path | read/write/notify | potentially persistent and dangerous | KS-HD and related supplement models | mcdax KS Fit notes |

### Legacy WiLink / FE00

| Area | Packet / field | Meaning | Confidence |
|---|---:|---|---|
| Service | `FE00` | WalkingPad service | high |
| Notify char | `FE01` | status/params notifications | high |
| Write char | `FE02` | command writes | high |
| Checksum | `sum(bytes[1..before_crc]) & 0xff` | command checksum | high |
| Query status | `F7 A2 00 00 A2 FD` | request current status | high |
| Set speed | `F7 A2 01 <rawTenths> <crc> FD` | set target speed raw tenths | high |
| Stop | `F7 A2 01 00 A3 FD` | stop through speed zero | high |
| Mode | `F7 A2 02 <mode> <crc> FD` | auto/manual/standby | high |
| Start | `F7 A2 04 01 A7 FD` | start/resume belt | high |
| Query params | `F7 A6 00 00 00 00 00 A6 FD` | read controller params | high |
| Set max speed | `A6 key=3` | preference write | medium |
| Set start speed | `A6 key=4` | preference write | medium |
| Set auto-start | `A6 key=5` | preference write | medium |
| Set sensitivity | `A6 key=6` | preference write | medium |
| Set display mask | `A6 key=7` | preference write | medium |
| Set units | `A6 key=8` | metric/imperial preference | medium-high, not safe |
| Child lock | `A6 key=9` | preference write | medium |

### Legacy status map

| Response | Field | Meaning | Confidence |
|---|---:|---|---|
| `F8 A2` | `[2]` | belt state | high |
| `F8 A2` | `[3]` | current speed raw tenths | high |
| `F8 A2` | `[4]` | manual/auto mode flag | high |
| `F8 A2` | `[5...7]` | elapsed time seconds | high |
| `F8 A2` | `[8...10]` | distance raw | high |
| `F8 A2` | `[11...13]` | steps | high |
| `F8 A2` | `[14]` | app/target speed raw | high |
| `F8 A2` | `[16]` | controller button | medium-high |
| `F8 A6` | `[7]` | max speed raw tenths | high |
| `F8 A6` | `[8]` | start speed raw tenths | high |
| `F8 A6` | `[13]` | unit preference | high |

### FTMS / newer devices

| Area | UUID / opcode | Meaning | Confidence |
|---|---:|---|---|
| Service | `0x1826` | FTMS | high |
| Treadmill data | `0x2ACD` | speed/distance/time data | high |
| Supported speed range | `0x2AD4` | min/max/increment | high |
| Control point | `0x2AD9` | FTMS commands | high |
| Fitness Machine Status | `0x2ADA` | command/status events | high |
| Request control | `0x00` | FTMS request control | high |
| Set target speed | `0x02` + `uint16 speed*100` | speed in km/h | high |
| Start/resume | `0x07` | start | high |
| Stop/pause | `0x08 0x01/0x02` | stop or pause | high |
| ODM pre-amble | `d18d2c10...` write `01 00 0D 00 06 0B 0F 0D` | unlock/property pre-amble | medium-high for MC-21 |
| Supplement service | `24e2521c...` | KingSmith vendor extensions | medium |
| OTA write/notify | `32e2314c...fdf2/fdf1` | OTA channel | medium, unsafe |

## 6. Units switching findings

The strongest legacy units evidence is:

- ph4-walkingpad defines `PREFS_UNITS = 8` and
  `set_pref_units_miles(enabled)` as an `A6` preference write.
- QWalkingPad defines `UNIT_METRIC = 0`, `UNIT_IMPERIAL = 1`, and
  `setUnit(unit)` as `messageInt(8, unit)`.
- This app's query parser reads params byte `[13]` and maps `0/1` to
  metric/imperial.

Concrete conclusion:

- Read-only detection through `queryParams.unit` is appropriate for warning and
  safety gating.
- Writing `setUnit` is not MVP-safe. It is known enough to be dangerous, but not
  validated enough for this app to expose.
- Public sources do not prove whether all models interpret raw speed commands in
  metric or native units after unit preference changes.
- Operator confirmation can record physical evidence for one specific treadmill
  fingerprint, but it should not globally change behavior for other devices.

## 7. Stop behavior findings

Legacy stop:

- ph4-walkingpad implements stop as `change_speed(0)`.
- QWalkingPad exposes `setSpeed(0)` via the same `A2 cmd=1` frame shape.
- The CLI wrapper in ph4 can optionally switch to standby after stop.
- This app's current stop hardening is consistent with that: speed zero,
  standby assist, retries, and telemetry-based verification.

FTMS stop:

- Standard FTMS stop is `STOP_OR_PAUSE` opcode `0x08` with parameter `0x01`.
- KingSmith FTMS devices may confirm through `0x2ADA` Fitness Machine Status or
  the next `0x2ACD` Treadmill Data notification, not always through Control
  Point indications.

Concrete conclusion:

- The standard stop behavior is known enough to keep the current command
  sequence.
- Stop success must be judged by observed status/speed, not by write success.
- A high-confidence public known issue matching "belt keeps moving after stop"
  was not found. The user's affected treadmill remains a local stop-forensics
  case, not a solved protocol fact.
- If `stop_confirmed_ever=false`, keep that in stop-forensics. Do not solve it
  by guessing new preference/service-menu/OTA commands.

## 8. Firmware / controller findings

Firmware and controller evidence splits into three confidence levels:

1. Official product evidence: KingSmith has security update / firmware upgrade
   policy pages and KS Fit app support. This confirms that firmware/app update
   surfaces exist.
2. Reverse-engineered KS Fit evidence: `FTMSOta`, `enterOTAMode`, Supplement
   service, and OTA write/notify UUIDs are present in decompiled KS Fit notes.
3. Missing evidence: no complete, safe, public firmware package format,
   flashing protocol, rollback story, compatibility matrix, or brick-recovery
   procedure was found.

Concrete conclusion:

- OTA/firmware must not be implemented in this app.
- Firmware findings are useful only for understanding that official apps may
  have changed controller behavior, not for taking action.
- If the affected treadmill changed behavior after another app connected, the
  safe next step is read-only evidence collection: params, firmware/software
  revision when exposed, app version, and BLE status logs.

## 9. Source inventory

| Source | URL | Type | Models | What it proves | Confidence |
|---|---|---|---|---|---|
| Current app `BLETransportCodec.swift` | local repo | local code | KS-F0 / legacy WalkingPad path in this app | query params packet, unit parser, speed packet | High |
| Current app `BluetoothManager.swift` | local repo | local code | KS-F0 / WalkingPad / FTMS / FitShow as implemented | stop sequence, auto-query, telemetry behavior | High |
| ph4-walkingpad | https://github.com/ph4r05/ph4-walkingpad | reverse-engineered project | WalkingPad A1; issue reports R1 Pro similarity | legacy FE00 protocol, checksum, commands | High |
| ph4 `pad.py` | https://github.com/ph4r05/ph4-walkingpad/blob/master/ph4_walkingpad/pad.py | source code | legacy WiLink / FE00 | exact commands, prefs, `PREFS_UNITS=8`, stop as speed zero | High |
| ph4 protocol basics | https://github.com/ph4r05/ph4-walkingpad#protocol-basics | documentation | legacy WiLink / FE00 | status fields, checksum, reversing method | High |
| QWalkingPad | https://github.com/DorianRudolph/QWalkingPad | reverse-engineered project | KingSmith WalkingPad legacy BLE | independent Qt implementation | High |
| QWalkingPad `Protocol.cpp` | https://github.com/DorianRudolph/QWalkingPad/blob/master/Protocol.cpp | source code | legacy WiLink / FE00 | `messageInt`, `queryParams`, `setUnit(8)`, parsers | High |
| QWalkingPad `Protocol.h` | https://github.com/DorianRudolph/QWalkingPad/blob/master/Protocol.h | source code | legacy WiLink / FE00 | metric/imperial/mode constants | High |
| mcdax/walkingpad-controller | https://github.com/mcdax/walkingpad-controller | reverse-engineered project | KS-HD, KS-MC21, KS-SMC21C, ZP-ZEALR1, legacy WiLink | FTMS + WiLink split, protocol auto-detection | High |
| mcdax KS Fit reverse notes | https://github.com/mcdax/walkingpad-controller/blob/main/docs/ks-fit-reverse-engineering.md | decompile notes | KS Fit v5.9.10/v6.0.7; MC-21/HD families | KS Fit routing, Supplement, OTA, setUnit mention | Medium-High |
| mcdax FTMS protocol reference | https://github.com/mcdax/walkingpad-controller/blob/main/docs/ftms-protocol-reference.md | snoop/decompile notes | KS-MC21, KS-HD class | FTMS opcodes, ODM pre-amble, OTA UUIDs | Medium-High |
| mcdax issue #1 | https://github.com/mcdax/walkingpad-controller/issues/1 | field report / issue | Kingsmith MC-21 | FTMS control requires KS Fit-like authorization/pre-amble | Medium |
| madmatah/hass-walkingpad | https://github.com/madmatah/hass-walkingpad | downstream integration | WalkingPad A1 Pro / legacy ph4-backed devices | remote control safety defaults, ph4 dependency | Medium |
| mcdax/hass-walkingpad | https://github.com/mcdax/hass-walkingpad | downstream integration | FTMS + WiLink KingSmith devices | Home Assistant wrapper for new protocol split | Medium |
| darnfish/walkingpad | https://github.com/darnfish/walkingpad | downstream library | legacy WalkingPad | BLE wrapper and ph4 attribution | Low-Medium |
| CodeJawn/walkingpad | https://github.com/CodeJawn/walkingpad | downstream app | legacy ph4-backed devices | mph UI over km/h internal command model | Low-Medium |
| KingSmith security updates zh | http://www.kingsmithfitness.com/securityupdates?lang=zh-cn | official Chinese source | KingSmith IoT devices / KS Fit | firmware/app security update surface exists | Medium |
| KingSmith support zh | https://www.kingsmithfitness.com/support?lang=zh-cn | official Chinese source | KingSmith products / KS Fit | official KS Fit support channel | Medium |
| KS Fit Google Play | https://play.google.com/store/apps/details?id=com.kingsmith.xiaojin | official app listing | KS Fit app | official package identity for app research | Medium |
| WalkingPad support | https://www.walkingpad.com/pages/support | official support | WalkingPad products | product/manual support surface, no protocol proof | Low-Medium |

### Chinese-language source notes

- High-confidence Chinese public protocol write-ups were not found in the
  searched Gitee/CSDN/Zhihu-style queries.
- Official Chinese KingSmith pages confirm product support, KS Fit, and
  firmware/security update policy, but do not publish BLE command details.
- Searches for `F1/F2/F3/F4/F5/G01` with WalkingPad/KingSmith terms did not
  produce high-confidence service-menu protocol documentation.
- Result: Chinese sources are useful for product/firmware existence, not for
  safe BLE implementation.

### Model matrix

| Model | Protocol | Units support | Stop behavior | Firmware info | Notes |
|---|---|---|---|---|---|
| KS-F0 | Legacy WalkingPad / FE00 in this app | `queryParams.unit` confirmed in app; affected unit reported as imperial | speed zero + standby/retries in app; user's affected unit has unconfirmed stop issue | not found in public sources | Treat as primary safety target; no HR-control on imperial |
| R1 / R1 Pro | Legacy WiLink likely for older models; newer variants may differ | ph4 issue reports similarity; `setUnit` not model-validated | ph4/QWalkingPad standard stop likely applies on legacy variants | not found | Needs per-device params/status capture |
| K12 | unknown / not confirmed | not found | not found | not found | Do not infer from A1/R1 without BLE service evidence |
| A1 / A1 Pro | Legacy WiLink / FE00 | ph4/QWalkingPad units constants and prefs likely apply | speed zero, optional standby | not found | Best-supported legacy model in public projects |
| C1 / C2 | likely legacy WiLink for some variants, but public proof weak | not found per model | likely legacy if FE00, otherwise unknown | official product/support only | Need service scan before implementation claims |
| KS-MC21 / KS-SMC21C | FTMS `0x1826` + ODM pre-amble | FTMS speed is km/h per spec; unit switching unknown in app scope | FTMS `0x08 0x01`; status via `2ADA`/`2ACD` | software revision via `0x2A28`; OTA UUIDs in reverse notes | Control may fail without ODM pre-amble |
| KS-HD family | FTMS + Supplement service | FTMS speed is km/h; Supplement may expose `setUnit` but unsafe | FTMS standard plus vendor extensions | Supplement OTA path found in KS Fit notes | Do not use Supplement without separate design |
| Xiaomi / KingSmith variants | mixed legacy WiLink / FTMS / cloud variants | model-dependent | model-dependent | model-dependent | Must identify protocol from advertised services and params |

## 10. Recommended next experiments

Safe, read-only or low-risk experiments:

1. Read-only connect on affected KS-F0:
   - record BLE name, peripheral ID, advertised services, `queryParams.rawHex`,
     checksum, unit, max speed, start speed, firmware/software revision if any.
2. No-load imperial diagnostic:
   - explicit owner confirmation
   - raw command `30`
   - duration 60 seconds
   - no person on belt
   - hand near power/safety stop
   - export raw CSV and record operator observation.
3. Stop verification only:
   - after any diagnostic, log all `F8 A2` status changes for at least 30
     seconds after stop.
   - classify by observed state, raw speed, app speed, and freshness.
4. Official app comparison, read-only:
   - use Bluetooth snoop / PacketLogger while KS Fit or the other App Store app
     starts/stops the treadmill.
   - compare only captured packets; do not replay unknown writes yet.
5. Metric reference treadmill comparison:
   - same diagnostic on known metric unit to compare params/status/stop without
     changing units.

## 11. What NOT to implement yet

- Do not implement `setUnit` / `A6 key 8` writes.
- Do not implement auto-switching metric/imperial units.
- Do not implement HR-control on imperial, even with operator confirmation.
- Do not implement automatic mph/kmh command conversion for HR-control.
- Do not implement service-menu commands or any `F1/F2/F3/F4/F5/G01` behavior.
- Do not implement OTA, firmware flashing, `enterOTAMode`, or Supplement
  service actions.
- Do not change stop behavior based on undocumented commands.
- Do not treat device-reported distance as factual meters in imperial
  diagnostics without external measurement.
- Do not generalize one treadmill's operator confirmation to other peripherals
  or changed controller params.
