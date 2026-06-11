# Treadmill behaviour analyzer

Self-contained workspace for inspecting WalkingPad training-log exports — the
"fresh treadmill behaviour analyzer". One place for the analysis script, a tiny
synthetic fixture, and a local archive of real exports.

```
tools/treadmill_analyzer/
├── analyze_training_log.py     # runtime_gap / background-suspension analyzer
├── analyze_stop_sequences.py   # stop-sequence forensics (10-point Stop report)
├── README.md                   # this file
├── samples/
│   ├── sample_runtime_gap.csv     # fixture for the runtime_gap analyzer
│   └── sample_stop_sequence.csv   # fixture for the stop-sequence analyzer
└── logs/                       # local archive of real exports (gitignored)
    └── .gitkeep                # keeps the folder; real CSVs are NOT committed
```

## What it analyzes

The analyzer answers one question: **did backgrounding the app ever disturb the
belt?** It scans an export for `runtime_gap` events — written when the app's
1-second session loop was suspended (screen locked / user switched apps) and
resumed late — and for each gap checks that the commanded speed stayed
continuous and no stop/abort fired around it.

It reads the **`Training_History_*.csv`** export (per-event rows, ~1 Hz, with a
`raw_json` column). The **`Training_Session_Summary_*.csv`** export is a
different shape (one rolled-up row per session) and is archived for reference but
not parsed by this tool.

## Usage

```bash
# Analyze one export
python3 tools/treadmill_analyzer/analyze_training_log.py \
  tools/treadmill_analyzer/logs/Training_History_last3_20260610_222100.csv

# Machine-readable summary
python3 tools/treadmill_analyzer/analyze_training_log.py <export.csv> --json

# Widen the belt-impact window around each gap (default ±5s)
python3 tools/treadmill_analyzer/analyze_training_log.py <export.csv> --near-seconds 8

# Analyze the newest archived history export
python3 tools/treadmill_analyzer/analyze_training_log.py \
  "$(ls -t tools/treadmill_analyzer/logs/Training_History_*.csv | head -1)"

# Sweep the whole archive
for f in tools/treadmill_analyzer/logs/Training_History_*.csv; do
  echo "== $f =="
  python3 tools/treadmill_analyzer/analyze_training_log.py "$f" --json
done
```

## Verdicts & exit codes

| Verdict      | Meaning                                                              | Exit |
|--------------|---------------------------------------------------------------------|------|
| `PASS`       | `runtime_gap`(s) logged, belt/commanded speed unaffected            | 0    |
| `FAIL`       | a gap shows belt/control impact (speed dropped or a stop fired)     | 1    |
| `NO-STALL`   | app backgrounded but stayed alive — no gap (detector not exercised) | 0    |
| `NO-GAP`     | no gap and no backgrounding seen — re-run with an app switch        | 3    |
| (file error) | export not found                                                     | 2    |

A `runtime_gap` at time `T` lasting `G` seconds covers `[T-G, T]` with no rows
inside it. "Near" means the `--near-seconds` window just outside that interval,
used to compare the pre/post belt state and scan for stop signals.

## Stop-sequence forensics

`analyze_stop_sequences.py` produces the fixed 10-point Stop report (timeline;
all `command_write` ±60 s around Stop; any non-zero speed write after Stop;
`command_source` attribution; `controller_state` / `controller_manual_mode` /
`speed_reported_kmh` before→after; `stop_confirmed[_ever]`; race-condition
suspicion) and one explicit verdict per Stop:

| Verdict | Meaning | Exit |
|---|---|---|
| `SAFE_STOP_CONFIRMED` | no post-stop non-zero speed/start write; stop confirmed; controller not-moving & speed ≤ 0.3 km/h | 0 |
| `STOP_RACE_SUSPECTED` | a non-zero speed (or start/resume) write was sent AFTER Stop | 1 |
| `STOP_UNCONFIRMED` | no race, but the stop was never confirmed (controller kept moving) | 3 |
| `STOP_NOT_VERIFIED` | belt already at rest, no verification scheduled | 0 |

```bash
python3 tools/treadmill_analyzer/analyze_stop_sequences.py <export.csv> [--window 60] [--json]
```

A "Stop" = a `command_write` with `command_source == "stop"`; the `STOP retry` /
`MODE STANDBY` assist writes and the `stop_verification` rows that follow belong
to the same sequence.

## Adding new logs

Export a CSV from the app (Settings → Export Training CSV) and drop it into
`logs/`. Anything in `logs/` (except `.gitkeep`) is gitignored — these exports
carry personal biometric data (`installation_id`, profile, heart rate, full
history) and must never be committed.
