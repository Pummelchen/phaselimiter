#!/usr/bin/env bash
# Interleaved A/B benchmark of compiler optimization variants.
#   DUR=20 ROUNDS=6 perf/bench_flags.sh
# Records wall and CPU time; CPU time is the robust metric when the machine is busy.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
OUT=perf/results/flags
mkdir -p "$OUT"
ROUNDS="${ROUNDS:-3}"
DUR="${DUR:-60}"

declare -A BINS=(
  [O3]=build/static/bin/phase_limiter
  [O2]=build/flags-o2/bin/phase_limiter
  [O3M3]=build/flags-o3m3/bin/phase_limiter
  [O3NATIVE]=build/flags-o3native/bin/phase_limiter
  [O3FAST]=build/flags-o3fast/bin/phase_limiter
  [O3LTO]=build/flags-o3lto/bin/phase_limiter
  [O3NOERRNO]=build/flags-o3noerrno/bin/phase_limiter
)
ORDER=(O3 O2 O3M3 O3NATIVE O3FAST O3LTO O3NOERRNO)
echo "round,variant,wall_s,user_s,sys_s,limit_lap_s" > "$OUT/raw.csv"

for r in $(seq 1 "$ROUNDS"); do
  for name in "${ORDER[@]}"; do
    bin="${BINS[$name]}"
    if [[ ! -x "$bin" ]]; then echo "skip $name (missing)"; continue; fi
    wav="$OUT/$name-$r.wav"
    tfile="$OUT/$name-$r.time"
    rm -f "$wav" "$tfile"
    /usr/bin/time -p -o "$tfile" \
      "$bin" --input=D07B53F5.wav --output="$wav" \
      --start_at=0 --end_at="$DUR" --worker_count=8 > "$OUT/$name-$r.log" 2>&1 || true
    wall=$(awk '/^real/{print $2}' "$tfile")
    user=$(awk '/^user/{print $2}' "$tfile")
    sys=$(awk '/^sys/{print $2}' "$tfile")
    lap=$(grep "phase limiting lap" "$OUT/$name-$r.log" | tail -1 | awk '{print $4}')
    echo "$r,$name,${wall:-0},${user:-0},${sys:-0},${lap:-0}" >> "$OUT/raw.csv"
    printf 'round %s %-10s wall=%s user=%s lap=%s\n' "$r" "$name" "${wall:-?}" "${user:-?}" "${lap:-?}"
    sleep 2
  done
  ORDER=("${ORDER[@]:1}" "${ORDER[0]}")
done

"$REPO_ROOT/build/conda-env/bin/python" - "$OUT" <<'PY'
import csv, os, statistics, sys, wave
import numpy as np
out = sys.argv[1]
rows = list(csv.DictReader(open(os.path.join(out, "raw.csv"))))
variants = []
for r in rows:
    if r["variant"] not in variants: variants.append(r["variant"])

def read(p):
    w = wave.open(p); d = w.readframes(w.getnframes()); w.close()
    return np.frombuffer(d, dtype="<i2")

refs = sorted(f for f in os.listdir(out) if f.startswith("O3-") and f.endswith(".wav"))
ref = read(os.path.join(out, refs[0])) if refs else None
print("variant,median_wall_s,median_user_s,min_user_s,median_lap_s,vs_O3_user,audio_max_lsb")
base = None
summary = []
for v in variants:
    vs = [r for r in rows if r["variant"] == v and float(r["user_s"]) > 0]
    if not vs: continue
    walls = [float(r["wall_s"]) for r in vs]
    users = [float(r["user_s"]) for r in vs]
    laps = [float(r["limit_lap_s"]) for r in vs]
    med_user = statistics.median(users)
    if v == "O3": base = med_user
    maxdiff = ""
    wavs = sorted(f for f in os.listdir(out) if f.startswith(v + "-") and f.endswith(".wav"))
    if ref is not None and wavs:
        a = read(os.path.join(out, wavs[0]))
        if len(a) == len(ref):
            d = a.astype(np.int32) - ref.astype(np.int32)
            maxdiff = int(np.abs(d).max())
    summary.append([v, f"{statistics.median(walls):.3f}", f"{med_user:.3f}",
                    f"{min(users):.3f}", f"{statistics.median(laps):.3f}", "", maxdiff])
for row in summary:
    if base and row[0] != "O3":
        row[5] = f"{base / float(row[2]):.3f}x"
    elif row[0] == "O3":
        row[5] = "1.000x"
    print(",".join(str(x) for x in row))
with open(os.path.join(out, "summary.csv"), "w") as f:
    f.write("variant,median_wall_s,median_user_s,min_user_s,median_lap_s,vs_O3_user,audio_max_lsb\n")
    for row in summary:
        f.write(",".join(str(x) for x in row) + "\n")
PY
