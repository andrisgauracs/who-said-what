#!/bin/zsh
# Benchmarks Voz against Apple's SpeechTranscriber. Needs ffmpeg and uv. Downloads ~2.6 GB of test data.
# Usage: benchmark/run.sh            results land in benchmark/results/
set -e
cd "$(dirname "$0")"
mkdir -p data/raw results
while read f u; do [[ -s data/raw/$f ]] || curl -sSL --retry 3 -o data/raw/$f "$u" & done < urls.txt
wait
uv run -q --no-project --with pyarrow python -I scripts/prep.py "$PWD"
(cd harness && swift build -c release)
# One engine at a time so they don't compete for the Neural Engine.
for s in short long; do
  for e in apple voz; do
    harness/.build/release/STTBench $e data/manifest_$s.tsv results/${e}_$s.jsonl
  done
done
uv run -q --no-project --with jiwer --with whisper-normalizer python -I scripts/score.py "$PWD" | tee results/summary.md
