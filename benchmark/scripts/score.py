"""Score results/*.jsonl against data/refs.json -> results/summary.json + markdown table on stdout."""
import json, os, statistics, sys
from collections import defaultdict
import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

root = os.path.expanduser(sys.argv[1])
norm = EnglishTextNormalizer()
refs = json.load(open(f"{root}/data/refs.json"))
rows = defaultdict(list)
for name in sorted(os.listdir(f"{root}/results")):
    if name.endswith(".jsonl"):
        for line in open(f"{root}/results/{name}"):
            r = json.loads(line)
            rows[(r["set"], r["engine"])].append(r)

summary = []
def score(group, rs):
    pairs = [(norm(refs[r["id"]]), norm(r["hyp"])) for r in rs]
    pairs = [(a, b) for a, b in pairs if a.strip()]
    m = jiwer.process_words([a for a, _ in pairs], [b if b.strip() else "<empty>" for _, b in pairs])
    n = m.hits + m.substitutions + m.deletions
    audio, secs = sum(r["duration"] for r in rs), sum(r["seconds"] for r in rs)
    return dict(set=group, engine=rs[0]["engine"], items=len(rs), audio_min=audio / 60,
                errors=sum(1 for r in rs if "error" in r), empty=sum(1 for r in rs if not r["hyp"].strip()),
                wer=100 * m.wer, sub=100 * m.substitutions / n, dele=100 * m.deletions / n, ins=100 * m.insertions / n,
                rtf=audio / secs, median_ms=1000 * statistics.median(r["seconds"] for r in rs), ref_words=n)

for (s, e), rs in sorted(rows.items()):
    summary.append(score(s, rs))
for scope, pred in [("ALL short (macro avg)", lambda s: not s.endswith("_long")), ("ALL long (macro avg)", lambda s: s.endswith("_long"))]:
    for e in ("apple", "voz"):
        part = [x for x in summary if x["engine"] == e and pred(x["set"])]
        if part:
            summary.append(dict(set=scope, engine=e, items=sum(x["items"] for x in part),
                                audio_min=sum(x["audio_min"] for x in part),
                                errors=sum(x["errors"] for x in part), empty=sum(x["empty"] for x in part),
                                wer=statistics.mean(x["wer"] for x in part), sub=statistics.mean(x["sub"] for x in part),
                                dele=statistics.mean(x["dele"] for x in part), ins=statistics.mean(x["ins"] for x in part),
                                rtf=sum(x["audio_min"] for x in part) / sum(x["audio_min"] / x["rtf"] for x in part),
                                median_ms=float("nan"), ref_words=sum(x["ref_words"] for x in part)))
json.dump(summary, open(f"{root}/results/summary.json", "w"), indent=1)
print("| set | engine | items | audio min | WER % | sub | del | ins | ×realtime | median ms | empty/err |")
print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for x in summary:
    print(f"| {x['set']} | {x['engine']} | {x['items']} | {x['audio_min']:.1f} | **{x['wer']:.2f}** | {x['sub']:.2f} | {x['dele']:.2f} | {x['ins']:.2f} | {x['rtf']:.0f} | {x['median_ms']:.0f} | {x['empty']}/{x['errors']} |")
