# WalkingPad / KingSmith setUnit and firmware deep research

Date: 2026-06-28
Scope: discovery only. No code changes, no BLE writes, no treadmill connection,
no `setUnit`, no firmware flashing, no service-menu writes.

Research channels used:

- Safari + Google search for `WalkingPad setUnit A6 key 8`.
- GitHub repository/API/raw source inspection.
- DuckDuckGo Lite searches for English, Chinese, Russian, German, Korean, and
  Japanese queries.
- Official KingSmith / WalkingPad / KS Fit pages.
- Existing local app code and the local `ph4-walkingpad` reference clone.

## 1. Executive summary

The exact legacy WiLink `setUnit` packet can be reconstructed with medium-high
confidence:

- metric: `F7 A6 08 00 00 00 00 AE FD`
- imperial: `F7 A6 08 00 00 00 01 AF FD`
- checksum rule: sum bytes from `A6` through the value bytes, modulo 256.

However, this is not enough evidence for a production feature. The packet is
likely a persistent controller preference, and rollback is probably the same
packet with value `0`, but public evidence does not prove model coverage,
display-only vs physical-command semantics, or safe recovery if the controller
enters a bad state.

Firmware / OTA evidence is also not actionable:

- Official KingSmith pages confirm firmware/security update policy for IoT
  devices and KS Fit.
- KS Fit reverse-engineering notes expose OTA-related services/classes, including
  Supplement service and `FTMSOta`.
- Public sources do not provide a complete safe firmware image format, update
  procedure, compatibility matrix, rollback, or brick recovery path.

Product conclusion:

- `setUnit`: do not implement as user-facing or automatic behavior. At most, a
  future dangerous debug-only gate could be designed after explicit owner
  approval and no-load recovery planning.
- Firmware/OTA: do not implement. Only read version/capabilities when exposed.
- HR-control on imperial remains blocked until a separate safety design proves
  command semantics and stop reliability.

## 2. Confirmed facts

### Legacy WiLink / FE00 facts

- Legacy WalkingPad control uses service `0xFE00`, notify `0xFE01`, write
  `0xFE02`.
- Byte command format:
  - `F7 A2 <command> <value> <checksum> FD`
- Preference/int command format:
  - `F7 A6 <key> <type> <u24-value> <checksum> FD`
- Checksum:
  - `checksum = sum(packet[1..<checksumIndex]) & 0xff`
- `queryParams` read packet:
  - `F7 A6 00 00 00 00 00 A6 FD`
- `queryParams` response:
  - prefix `F8 A6`
  - unit preference at byte index `13`
  - `0 = metric`, `1 = imperial`
- Standard legacy stop:
  - speed zero command `F7 A2 01 00 A3 FD`
- Standard legacy standby:
  - mode standby command `F7 A2 02 02 A6 FD`
- Standard legacy start:
  - `F7 A2 04 01 A7 FD`

### FTMS / newer KingSmith facts

- Newer KingSmith devices may use FTMS service `0x1826`.
- Standard FTMS basic commands:
  - `0x2AD9: 0x02 + uint16-le(speed * 100)` for target speed in km/h
  - `0x2AD9: 0x07` for start/resume
  - `0x2AD9: 0x08 0x01` for stop
  - `0x2AD9: 0x08 0x02` for pause
- KingSmith MC-21-class devices may need the ODM pre-amble characteristic
  `d18d2c10-c44c-11e8-a355-529269fb1459`.
- KS-HD-class devices may expose Supplement service `24e2521c-...`.
- OTA-related UUIDs reported by reverse-engineered notes:
  - `32e2314c-0000-0000-0000-00000000fdf1` OTA notify
  - `32e2314c-0000-0000-0000-00000000fdf2` OTA write
- Firmware/software version can be read safely on some FTMS devices via
  standard Device Information characteristics, especially `0x2A28` Software
  Revision String. `0x2A26` Firmware Revision String may also be present on
  devices exposing standard Device Information.

## 3. setUnit / metric-imperial findings

### Exact packet

Legacy preference write format from ph4-walkingpad and QWalkingPad:

```text
F7 A6 <key> <type> <value_2> <value_1> <value_0> <checksum> FD
```

For units:

- key: `0x08`
- type: `0x00`
- metric value: `0x000000`
- imperial value: `0x000001`

Computed packets:

```text
metric   = F7 A6 08 00 00 00 00 AE FD
imperial = F7 A6 08 00 00 00 01 AF FD
```

Checksum:

```text
metric:   A6 + 08 + 00 + 00 + 00 + 00 = AE
imperial: A6 + 08 + 00 + 00 + 00 + 01 = AF
```

### Evidence

- ph4-walkingpad defines `PREFS_UNITS = 8` and
  `set_pref_units_miles(enabled)` as an `A6` preference write.
- QWalkingPad defines:
  - `UNIT_METRIC = 0`
  - `UNIT_IMPERIAL = 1`
  - `setUnit(unit) { return messageInt(8, unit); }`
- Current app and QWalkingPad both parse `queryParams` unit from byte `13`.
- mcdax KS Fit reverse notes mention both Supplement `setUnit` and WiLink
  `setUnit`, but do not publish enough legacy packet bytes to be a third exact
  packet confirmation.

### Persistence

Likely persistent, but not proven enough for production:

- It is implemented as a controller preference (`A6` key) rather than a runtime
  `A2` command.
- `queryParams` returns the unit preference afterward.
- Public sources do not prove persistence across power-cycle for every model.

Conclusion: treat persistence as probable, not guaranteed.

### Rollback

Known probable rollback packet:

```text
F7 A6 08 00 00 00 00 AE FD
```

This is only a protocol-level rollback. It is not a proven safety/recovery
procedure. There is no public evidence of:

- service-menu rollback;
- app-level rollback guarantees;
- behavior after failed write;
- recovery if command semantics or controller state become inconsistent.

### Display-only vs command semantics

Inconclusive globally.

Evidence:

- Public reverse-engineered sources prove unit preference exists.
- They do not prove whether raw speed command `A2 01 rawTenths` is interpreted
  as km/h, mph, or display-only after unit preference changes on every model.
- Owner observation on the affected treadmill supports physical imperial command
  semantics for that specific device, but this is operator evidence, not a
  universal protocol guarantee.

Conclusion:

- For a specific device, operator-confirmed physical semantics may be stored as
  evidence.
- Do not generalize it to other treadmills.
- Do not enable HR-control on imperial from this evidence alone.

### Is there enough evidence to implement `setUnit`?

Answer: **not as production behavior**.

There is enough evidence to identify the dangerous packet, but not enough to
make it safe. A future implementation would have to be:

- hidden behind a dangerous debug gate;
- unavailable during HR-control or any loaded treadmill use;
- no-load only;
- explicit owner confirmation;
- with read-before/read-after params;
- with physical stop nearby;
- with rollback plan and telemetry;
- initially tested only on a sacrificial/affected unit.

Current recommendation: do not implement.

## 4. Firmware / OTA findings

### What exists

Official evidence:

- KingSmith has a Chinese security update page that explicitly mentions firmware
  upgrade policy (`固件升级政策`) and KS Fit App security updates.
- KingSmith support pages direct users to KS Fit through Google Play and App
  Store.

Reverse-engineered evidence:

- KS Fit decompile notes include:
  - `ftms_ota.dart`
  - `FTMSOta`
  - `enterOTAMode`
  - chunked firmware writes
  - CRC verify
  - reboot
- mcdax FTMS notes list OTA write/notify UUIDs:
  - `32e2314c-...fdf2` write
  - `32e2314c-...fdf1` notify
- Supplement service `24e2521c-...` is reported for KS-HD-class devices and
  includes wider vendor actions.

### What is not found

Not found in public sources:

- public official firmware files for treadmill controllers;
- complete firmware image format;
- complete OTA packet sequence;
- firmware compatibility matrix;
- bootloader protocol;
- recovery procedure after failed OTA;
- downgrade/rollback method;
- successful public flashing report for KingSmith / WalkingPad treadmill
  controller firmware;
- safe way to force OTA mode from a third-party app.

### Is there any safe firmware/OTA path?

Answer: **No**.

The OTA surface exists, but it is not an implementable safe path. The only safe
work for this app is read-only:

- read standard Device Information characteristics where exposed;
- record firmware/software revision;
- compare before/after behavior if the user suspects KS Fit or another app
  changed controller state.

### Can firmware/controller version be read safely?

Answer: **Yes, best-effort read-only**.

Safe read candidates:

- `0x2A28` Software Revision String;
- `0x2A26` Firmware Revision String;
- `0x2A24` Model Number String;
- `0x2A29` Manufacturer Name String.

mcdax `FTMSController` specifically reads `0x2A28` as a firmware version display
source. ph4's scanner also includes Device Information characteristic UUIDs in
its discovery set.

## 5. Stop behavior findings

### Legacy WiLink / FE00

Confirmed standard stop:

```text
F7 A2 01 00 A3 FD
```

Evidence:

- ph4-walkingpad `stop_belt()` calls `change_speed(0)`.
- tim-oster/walkingpad `StopBelt()` calls `ChangeSpeed(0.0)`.
- Current app uses the same speed-zero stop packet.

Standby:

```text
F7 A2 02 02 A6 FD
```

Evidence:

- ph4 mode constants: `standby = 2`.
- Current app uses standby as assist after stop, not as first stop command.

Recommended order:

1. stop through speed zero;
2. observe status/speed;
3. if still not confirmed stopped, send standby assist;
4. retry stop and verify with fresh telemetry.

Do not send standby as the only stop mechanism while moving without verification.

### FTMS / newer KingSmith

Standard FTMS stop:

```text
2AD9: 08 01
```

Pause:

```text
2AD9: 08 02
```

Command success can be verified through:

- `0x2ADA` Fitness Machine Status;
- `0x2ACD` Treadmill Data speed/state;
- not only through Control Point indication, because KingSmith firmware may omit
  indications for some accepted commands.

### Known issue: belt keeps moving after stop

No high-confidence public issue matching the affected treadmill's exact behavior
was found. There are generic Reddit/user reports about walking pads stopping
abruptly or device problems, but no protocol-level confirmed issue saying the
standard stop packet fails on KS-F0 because of a known firmware/state condition.

Conclusion:

- keep this in local stop-forensics scope;
- do not invent a new command;
- compare official app / remote / our app through logs and read-only capture
  where possible.

## 6. Service menu findings

Searches for service menu terms:

- `WalkingPad service menu F1 F2 F3 F4 F5`
- `金史密斯 工程模式 F1 F2 F3 F4 F5`
- `走步机 服务菜单`
- `WalkingPad F4 F5 mph`
- `KS-F0 F4 F5 WalkingPad`

Result:

- No high-confidence protocol source found.
- No reliable packet map for `F1/F2/F3/F4/F5/G01` found.
- Some search results lead to general manuals, product pages, or unrelated
  engineering-mode content.

Conclusion:

- service-menu writes must remain forbidden;
- do not use service-menu assumptions for units, stop, or firmware recovery.

## 7. Chinese-source findings

Useful Chinese-language sources:

- KingSmith security update page (`安全更新`) confirms firmware upgrade policy
  wording (`固件升级政策`) and KS Fit App security update context.
- KingSmith Chinese support page confirms KS Fit app distribution via Google
  Play / App Store.
- Tencent App Store page for KS Fit Chinese package confirms app presence and
  Bluetooth-related permissions.
- KingSmith C2 Chinese product page confirms app/Bluetooth connectivity as a
  product feature.

Chinese searches that did not produce high-confidence protocol data:

- `金史密斯 走步机 蓝牙 协议`
- `金史密斯 走步机 单位 切换`
- `WalkingPad 公里 英里 切换`
- `金史密斯 A6 协议`
- `金史密斯 工程模式 F1 F2 F3 F4 F5`
- `site:gitee.com 金史密斯 WalkingPad 蓝牙`
- `site:blog.csdn.net 金史密斯 走步机 蓝牙`

Conclusion:

- Chinese official/product sources are useful for app/firmware existence.
- They do not publish enough BLE protocol detail to justify writes.
- No Chinese public source found that independently confirms `A6 key=8`
  beyond the existing reverse-engineered projects.

## 8. Source inventory

| Source | URL | Language | Type | Model | What it proves | Confidence |
|---|---|---|---|---|---|---|
| Current app `BLETransportCodec.swift` | local repo | English | local code | KS-F0/current WalkingPad path | query params, unit parser, speed packet | High |
| Current app `BluetoothManager.swift` | local repo | English | local code | KS-F0/current WalkingPad path | stop sequence, standby assist, telemetry gates | High |
| ph4-walkingpad | https://github.com/ph4r05/ph4-walkingpad | English | reverse-engineered project | A1, R1 Pro reported similar | legacy FE00 protocol | High |
| ph4 `pad.py` | https://github.com/ph4r05/ph4-walkingpad/blob/master/ph4_walkingpad/pad.py | English | source code | legacy WiLink | `PREFS_UNITS=8`, stop speed zero, checksum | High |
| ph4 protocol basics | https://github.com/ph4r05/ph4-walkingpad#protocol-basics | English | documentation | legacy WiLink | status fields, checksum, reverse method | High |
| QWalkingPad | https://github.com/DorianRudolph/QWalkingPad | English | reverse-engineered project | KingSmith WalkingPad legacy BLE | independent Qt controller | High |
| QWalkingPad `Protocol.cpp` | https://github.com/DorianRudolph/QWalkingPad/blob/master/Protocol.cpp | English | source code | legacy WiLink | `setUnit(8)`, `queryParams`, parser | High |
| QWalkingPad `Protocol.h` | https://github.com/DorianRudolph/QWalkingPad/blob/master/Protocol.h | English | source code | legacy WiLink | metric/imperial constants | High |
| mcdax/walkingpad-controller | https://github.com/mcdax/walkingpad-controller | English | reverse-engineered project | KS-HD, KS-MC21, KS-SMC21C, ZP-ZEALR1, legacy WiLink | FTMS/WiLink split | High |
| mcdax KS Fit notes | https://github.com/mcdax/walkingpad-controller/blob/main/docs/ks-fit-reverse-engineering.md | English | decompile notes | KS Fit v5.9.10/v6.0.7 | Supplement, OTA, setUnit inventory | Medium-High |
| mcdax FTMS reference | https://github.com/mcdax/walkingpad-controller/blob/main/docs/ftms-protocol-reference.md | English | snoop/decompile notes | MC-21, KS-HD | FTMS opcodes, ODM, OTA UUIDs, unit property | Medium-High |
| mcdax `ftms.py` | https://github.com/mcdax/walkingpad-controller/blob/main/src/walkingpad_controller/ftms.py | English | source code | FTMS KingSmith | read `0x2A28`, stop/pause behavior | High |
| mcdax issue #1 | https://github.com/mcdax/walkingpad-controller/issues/1 | English | issue/field report | MC-21 | FTMS commands need KS Fit-like authorization/pre-amble | Medium |
| tim-oster/walkingpad | https://github.com/tim-oster/walkingpad | English | independent source project | legacy WiLink | FE00/FE01/FE02, stop speed zero, checksum | Medium-High |
| madmatah/hass-walkingpad | https://github.com/madmatah/hass-walkingpad | English | downstream integration | A1 Pro / ph4-backed | safety default and ph4 dependency | Medium |
| mcdax/hass-walkingpad | https://github.com/mcdax/hass-walkingpad | English | downstream integration | FTMS + WiLink | Home Assistant protocol split | Medium |
| darnfish/walkingpad | https://github.com/darnfish/walkingpad | English | downstream library | legacy WalkingPad | BLE wrapper, ph4 attribution | Low-Medium |
| CodeJawn/walkingpad | https://github.com/CodeJawn/walkingpad | English | downstream app | ph4-backed legacy | mph UI over km/h internal commands | Low-Medium |
| WalkingStar App Store | https://apps.apple.com/us/app/walkingstar/id6770512201 | English | third-party app listing | R/P/C-series with Bluetooth | third-party app claims mph/kmh toggle | Low |
| Treadmill Pro App Store | https://apps.apple.com/ng/app/treadmill-pro/id6759807162 | English/Russian/etc. | third-party app listing | FTMS, WalkingPad, Gymax | public app claims WalkingPad protocol support | Low |
| KS Fit Google Play | https://play.google.com/store/apps/details?id=com.kingsmith.xiaojin | English | official app listing | KingSmith fitness devices | official app identity and capabilities | Medium |
| KS Fit App Store | https://apps.apple.com/us/app/ks-fit-easy-workout/id6769698398 | English/Chinese/etc. | official app listing | KingSmith ecosystem | official app identity / Health sync | Medium |
| KingSmith security updates zh | http://www.kingsmithfitness.com/securityupdates?lang=zh-cn | Chinese | official page | KingSmith IoT devices / KS Fit | firmware upgrade policy exists | Medium |
| KingSmith support zh | https://www.kingsmithfitness.com/support?lang=zh-cn | Chinese | official page | KingSmith products | KS Fit distribution/support | Medium |
| Tencent KS Fit China appstore | https://sj.qq.com/appdetail/com.kingsmith.china | Chinese | app store page | KS Fit China package | app presence and Bluetooth permissions | Medium |
| KingSmith C2 zh | https://www.kingsmithfitness.com/walkingpad-c2-walking-treadmill?lang=zh-cn | Chinese | product page | C2 | app/Bluetooth connectivity, no protocol details | Low-Medium |
| WalkingPad UK KS Fit guide | https://uk.walkingpad.com/pages/ks-fit-app | English | support guide | WalkingPad products | app connection steps | Low-Medium |
| Safari / Google search | https://www.google.com/search?q=WalkingPad+setUnit+A6+key+8 | English | search attempt | n/a | no new useful public setUnit source; some results removed/irrelevant | Low |
| DuckDuckGo Chinese searches | n/a | Chinese | search attempt | n/a | CSDN/Gitee/Zhihu-style searches did not reveal protocol proof | Low |

## 9. Confidence matrix

| Question | Answer | Confidence | Reason |
|---|---|---:|---|
| Exact legacy `setUnit` packet? | `F7 A6 08 00 00 00 00 AE FD` / `...01 AF FD` | Medium-High | ph4 + QWalkingPad exact source agreement |
| Is `setUnit` persistent? | Probably yes | Medium | preference command + queryParams, but no model-wide power-cycle proof |
| Is rollback known? | Protocol-level rollback probably value `0` | Medium | packet known, recovery semantics not proven |
| Display-only or physical semantics? | Inconclusive globally | Low-Medium | public sources do not prove it; owner evidence only per-device |
| Enough to implement production setUnit? | No | High | safety/recovery/model coverage gaps remain |
| Debug-only setUnit conceivable later? | Only with explicit dangerous gate | Medium | packet is known but unsafe |
| Safe firmware/OTA path? | No | High | OTA surface found, full safe protocol/recovery not found |
| Can firmware/software version be read? | Yes, best-effort | Medium-High | standard Device Info, mcdax reads `0x2A28` |
| Standard legacy stop command? | speed zero `F7 A2 01 00 A3 FD` | High | ph4 + tim-oster + current app |
| Standard FTMS stop command? | `0x2AD9: 08 01` | High | FTMS/mcdax |
| Known public "belt keeps moving" issue? | Not found | Medium | searches found generic issues, not protocol-confirmed cause |
| Service menu F1/F2/F3/F4/F5/G01? | Not found / unsafe | Medium | broad searches no reliable packet map |

## 10. Safe next experiments

Safest immediate experiment:

1. Read-only BLE scan / connect.
2. Capture:
   - peripheral name;
   - advertised services;
   - `queryParams.rawHex`;
   - unit byte;
   - checksum status;
   - Device Information characteristics if exposed:
     - `0x2A24` model;
     - `0x2A26` firmware revision;
     - `0x2A28` software revision;
     - `0x2A29` manufacturer.
3. Do not send writes except existing app's normal read-only query if already
   part of the safety branch.

Next safe physical diagnostic:

1. no-load only;
2. explicit owner confirmation;
3. raw command `30`;
4. 60 seconds;
5. external/operator observation recorded;
6. stop verification for 30 seconds afterward;
7. export raw telemetry.

Only after those:

- compare official KS Fit / WalkingPad app behavior through passive Bluetooth
  capture if possible;
- do not replay unknown writes.

## 11. Forbidden actions

Keep forbidden:

- user-facing `setUnit`;
- automatic metric/imperial switching;
- HR-control on imperial;
- automatic mph/kmh conversion for HR-control;
- `setUnit` without a separate dangerous-debug design;
- service-menu writes;
- `F1/F2/F3/F4/F5/G01` experiments;
- OTA / firmware flashing;
- `enterOTAMode`;
- Supplement service actions;
- downloading/running suspicious APKs or binaries;
- bypassing login/paywall/protection;
- sending BLE writes to a live loaded treadmill;
- treating one device's operator confirmation as global truth.

## 12. Open questions

- Does `A6 key=8` persist across power cycles on KS-F0 specifically?
- Does `A6 key=8` alter only display units or the physical speed command
  semantics on KS-F0?
- Does KS Fit expose a user-facing unit switch for KS-F0, and what packet does
  it send on that exact model?
- Can KS-F0 expose `0x2A26` or `0x2A28`, or only FE00/FE01/FE02?
- Did the third-party App Store app change only unit preference, or another
  controller parameter?
- Why does the affected treadmill fail stop confirmation even when controlled
  by remote?
- Does official KS Fit send a different stop sequence on the affected unit?
- Are service-menu labels like `F1/F2/F3/F4/F5/G01` real on this controller, and
  if yes, are they display-only diagnostic modes or writable controller states?
- Is there any official controller reset that restores units and stop behavior
  without firmware/OTA?
