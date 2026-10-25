# Voz vs SpeechTranscriber

We compared the two transcribers this app can use: Desert Ant's **Voz** (v0.4.0, `desert-ant-core` 4.1.0) and Apple's **`SpeechTranscriber`** (macOS 26, en-US, configured exactly as `Pipeline.transcribeWithApple`). Voz was more accurate on all nine test sets and faster on all of them.

Measured on a MacBook Pro M5 Max (macOS 26.6.2), 2026-10-25.

## Results

Word error rate (WER, lower is better) and speed in multiples of realtime (higher is better).

| Set | Clips | Audio | Apple WER | Voz WER | Apple speed | Voz speed |
|---|---:|---:|---:|---:|---:|---:|
| AMI (meetings) | 100 | 6 min | 12.32% | **8.81%** | 44x | 91x |
| Earnings-22 | 100 | 10 min | 11.03% | **9.11%** | 53x | 121x |
| GigaSpeech | 100 | 7 min | 12.14% | **11.00%** | 45x | 97x |
| LibriSpeech test-clean | 100 | 12 min | 1.75% | **1.59%** | 49x | 129x |
| LibriSpeech test-other | 100 | 10 min | 5.03% | **4.18%** | 46x | 117x |
| SPGISpeech | 100 | 11 min | 4.29% | **3.83%** | 55x | 128x |
| VoxPopuli | 100 | 11 min | 8.57% | **5.68%** | 54x | 130x |
| **Short clips, average** | 700 | 68 min | 7.87% | **6.31%** | 50x | 117x |
| TED-LIUM, whole talks | 11 | 148 min | 3.68% | **2.71%** | 88x | 530x |
| Earnings-21, whole calls | 8 | 433 min | 9.38% | **7.33%** | 76x | 556x |
| **Long recordings, average** | 19 | 581 min | 6.53% | **5.02%** | 78x | **549x** |

Averages are the mean of the per-set WERs; speed is total audio over total time. The breakdown into substitutions, deletions and insertions, plus the median time per clip, is in [`benchmark/results/summary.md`](../benchmark/results/summary.md).

What this means for the app:

- **Voz makes about 20-25% fewer errors.** The biggest gaps are on meetings (AMI) and accented speech (VoxPopuli). On whole recordings, the closest thing here to a podcast, Voz is ahead as well.
- **Voz is about 7x faster on long recordings.** On the earnings calls, which average 54 minutes, the median call took Voz 5.4 seconds and Apple 40. The app runs transcription and diarization side by side, so the slower of the two sets the total time.
- **Our Voz number matches Desert Ant's.** 6.31% on the short sets is close to the 6.43% they publish across six Open ASR leaderboard sets, which suggests the setup and the scoring are sound.

## Method

- **Data.** Short clips: 100 clips drawn at random (seed 0) from one mid-sized shard of each set in [`hf-audio/open-asr-leaderboard`](https://huggingface.co/datasets/hf-audio/open-asr-leaderboard). The shards are sorted by length, so a middle shard gives typical clip lengths. Long recordings: all 11 talks in [`distil-whisper/tedlium-long-form`](https://huggingface.co/datasets/distil-whisper/tedlium-long-form) (test) and 8 calls drawn at random (seed 0) from [`distil-whisper/earnings21`](https://huggingface.co/datasets/distil-whisper/earnings21), about 9.7 hours together. Every file is converted to 16 kHz mono WAV with ffmpeg first.
- **Running.** A small Swift harness (`benchmark/harness`) runs one engine over a list of files. Both engines read the same WAV from disk: Voz through `voz.transcribe(path:)`, Apple through `SpeechAnalyzer.analyzeSequence(from:)`. The first file is a warm-up and isn't scored. Model loading isn't timed. The engines run one after the other, never together, so they don't compete for the Neural Engine.
- **Scoring.** References and transcripts both go through Whisper's English text normalizer, the one the Open ASR leaderboard uses. WER is corpus-level per set, computed with `jiwer`.

## Caveats

- **One machine.** Speed figures are for an M5 Max. Expect lower numbers on smaller chips, though the gap between the two engines should stay similar.
- **Number formatting.** Voz spells numbers out ("seven hundred million dollars"). The normalizer standardizes numbers in references and transcripts before comparing, so WER doesn't penalize either engine's style, but the exports will look different.
- **Samples, not full test sets.** Each short set is 100 clips, not the full test set, so per-set numbers will differ somewhat from full-set results. The direction held on every set.
- **English only.** Voz covers 25 languages. This compares English, the only language the app's Apple setup uses.

## Re-running it

Needs ffmpeg, [uv](https://docs.astral.sh/uv/) and about 4 GB of disk. It downloads about 2.6 GB of test data from Hugging Face and takes about 15 minutes on an M5 Max: roughly 10 minutes of transcription (most of it Apple's long-form pass) plus downloading and preparing the data.

```sh
benchmark/run.sh        # writes benchmark/results/summary.md
```

The datasets carry their own licenses (TED-LIUM is CC BY-NC-ND), so the downloaded audio and the raw transcripts stay out of the repository; only the summary table is committed.
