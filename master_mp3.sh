#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${PHASELIMITER_BASE_DIR:-$SCRIPT_DIR}"

MP3_DIR="$BASE_DIR/mp3"
FLAC_DIR="$BASE_DIR/flac"
CACHE_DIR="${PHASELIMITER_CACHE:-$BASE_DIR/resource/sound_quality2_cache}"

if command -v phaselimiter >/dev/null 2>&1; then
    PHASE_LIMITER="$(command -v phaselimiter)"
elif [ -x /opt/homebrew/bin/phaselimiter ]; then
    PHASE_LIMITER="/opt/homebrew/bin/phaselimiter"
else
    echo "ERROR: phaselimiter not found. Install it systemwide (e.g. into /opt/homebrew/bin)." >&2
    exit 1
fi

command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: ffmpeg not found." >&2; exit 1; }

if [ ! -f "$CACHE_DIR" ]; then
    echo "ERROR: sound_quality2_cache not found at '$CACHE_DIR'." >&2
    echo "Copy it to '$BASE_DIR/resource/' or set PHASELIMITER_CACHE." >&2
    exit 1
fi

mkdir -p "$FLAC_DIR"

tmpdir=""
cleanup() {
    if [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ]; then
        rm -rf -- "$tmpdir"
    fi
}
trap cleanup EXIT INT TERM

for f in "$MP3_DIR"/*.mp3; do
    [ -e "$f" ] || continue

    filename="$(basename "$f" .mp3)"
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/phaselimiter-XXXXXX")"

    wav_in="$tmpdir/${filename}.wav"
    wav_out="$tmpdir/${filename}_out.wav"
    flac_out="$FLAC_DIR/${filename}.flac"

    echo "Processing: '$f' -> '$flac_out' (tmp: $tmpdir)"

    # Convert MP3 to WAV (32-bit float / 48 kHz)
    if ! ffmpeg -y -hide_banner -loglevel error -i "$f" -ar 48000 -ac 2 -c:a pcm_f32le "$wav_in"; then
        echo "ERROR: ffmpeg decode failed for '$f'. Skipping."
        rm -rf -- "$tmpdir"; tmpdir=""
        continue
    fi

    if ! "$PHASE_LIMITER" \
      --input="$wav_in" \
      --output="$wav_out" \
      --tmp="$tmpdir" \
      --mastering=true \
      --mastering_mode=mastering5 \
      --sound_quality2_cache="$CACHE_DIR" \
      --reference=-9 \
      --reference_mode=loudness \
      --ceiling=-0.5 \
      --ceiling_mode=true_peak \
      --lowpass_true_peak_cut_freq=15000 \
      --true_peak_oversample=1 \
      --limiter_internal_oversample=1 \
      --mastering5_mastering_level=0.5 \
      --output_format=wav \
      --bit_depth=32 \
      --sample_rate=48000 \
      --low_cut_freq=0 \
      --high_cut_freq=22000
    then
        echo "ERROR: phaselimiter failed for '$f'. Skipping."
        rm -rf -- "$tmpdir"; tmpdir=""
        continue
    fi

    if [ ! -s "$wav_out" ]; then
        echo "ERROR: phaselimiter produced no output for '$f'. Skipping."
        rm -rf -- "$tmpdir"; tmpdir=""
        continue
    fi

    # Convert WAV -> FLAC
    if ! ffmpeg -hide_banner -loglevel error -i "$wav_out" -c:a flac -compression_level 12 -map_metadata 0 "$flac_out"; then
        echo "ERROR: flac encode failed for '$wav_out'. MP3 will NOT be removed."
        rm -rf -- "$tmpdir"; tmpdir=""
        continue
    fi

    if [ -s "$flac_out" ]; then
        echo "SUCCESS: '$flac_out' created."
        echo "Deleting original MP3: '$f'"
        rm -f -- "$f"
    else
        echo "ERROR: FLAC file missing or empty. MP3 retained."
    fi

    rm -rf -- "$tmpdir"; tmpdir=""
done

echo "All done."
