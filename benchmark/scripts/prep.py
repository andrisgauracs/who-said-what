"""Sample clips from downloaded parquet shards -> 16 kHz mono WAV + manifest.tsv + refs.json."""
import json, os, random, subprocess, sys, tempfile
import pyarrow.parquet as pq

root = os.path.expanduser(sys.argv[1])
raw, clips = f"{root}/data/raw", f"{root}/data/clips"
os.makedirs(clips, exist_ok=True)
SHORT = ["ami", "earnings22", "gigaspeech", "librispeech_clean", "librispeech_other", "spgispeech", "voxpopuli"]
LONG = {"tedlium_long": ("text", None), "earnings21_long": ("transcription", 8)}
manifest, refs = [], {}

def emit(set_name, idx, audio_bytes, text):
    cid = f"{set_name}-{idx:04d}"
    wav = f"{clips}/{cid}.wav"
    if not os.path.exists(wav):
        with tempfile.NamedTemporaryFile(dir=clips, suffix=".bin", delete=False) as t:
            t.write(audio_bytes)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", t.name, "-ar", "16000", "-ac", "1",
                        "-c:a", "pcm_s16le", wav], check=True)
        os.unlink(t.name)
    manifest.append((cid, set_name, wav))
    refs[cid] = text

for s in SHORT:
    t = pq.read_table(f"{raw}/{s}.parquet", columns=["audio", "text"])
    n = t.num_rows
    for i in sorted(random.Random(0).sample(range(n), min(100, n))):
        emit(s, i, t["audio"][i]["bytes"].as_py(), t["text"][i].as_py())
    print(s, "done", file=sys.stderr)

for s, (col, k) in LONG.items():
    pf = pq.ParquetFile(f"{raw}/{s}.parquet")
    n = pf.metadata.num_rows
    pick = set(range(n)) if k is None else set(random.Random(0).sample(range(n), k))
    i = 0
    for batch in pf.iter_batches(batch_size=1, columns=["audio", col]):
        if i in pick:
            emit(s, i, batch["audio"][0]["bytes"].as_py(), batch[col][0].as_py())
        i += 1
    print(s, "done", file=sys.stderr)

with open(f"{root}/data/manifest_short.tsv", "w") as f:
    f.writelines(f"{a}\t{b}\t{c}\n" for a, b, c in manifest if not b.endswith("_long"))
with open(f"{root}/data/manifest_long.tsv", "w") as f:
    f.writelines(f"{a}\t{b}\t{c}\n" for a, b, c in manifest if b.endswith("_long"))
json.dump(refs, open(f"{root}/data/refs.json", "w"))
