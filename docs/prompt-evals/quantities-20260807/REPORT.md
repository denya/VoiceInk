# VoiceInk quantity and enumeration prompt evaluation

## Decision

`v11_examples` is the prompt-only winner. It adds six lines of cross-language numeric examples to the existing Denya hybrid prompt.

- Dev: 15/15 hard-gate passes, mean conservative semantic score 97.51 (control: 7/15).
- Held-out: 13/15 passes, mean score 92.14 (control: 9/15, 79.60).
- Held-out swap: four failures resolved, zero new regressions.
- Overfitting check: +8 passes on dev and +4 on held-out. The other finalist added a Russian date regression and was rejected.
- Model: `gemini-3.5-flash-lite`, temperature 0.3, exact model read-back verified.

The two remaining held-out failures are unchanged categories, not regressions: an English spoken range stayed in words, and a Spanish ordinal enumeration did not meet the required numbered-list form.

## Per-category held-out result

| Category | Control | Winner | Regression |
|---|---:|---:|---|
| Percentage | 1/3 | 3/3 | none |
| Money | 0/1 | 1/1 | none |
| Ordinal list | 0/2 | 1/2 | none |
| Date | 1/1 | 1/1 | none |
| Version | 1/1 | 1/1 | none |
| Identifier | 2/2 | 2/2 | none |
| Phone | 1/1 | 1/1 | none |
| Literal prose | 2/2 | 2/2 | none |
| Already-correct/no-op | 1/1 | 1/1 | none |
| Range | 0/1 | 0/1 | unchanged failure |

## Real VoiceInk envelope traced

`TranscriptionPipeline` passes raw text to `AIEnhancementService.enhance`. The selected `CustomPrompt.finalPromptText` becomes the system message; custom vocabulary and selected/clipboard/window context are appended when present. The raw transcript is sent separately as:

```text
<USER_MESSAGE>
{raw transcript}
</USER_MESSAGE>
```

The response is trimmed and passed through `AIEnhancementOutputFilter.filter(_:preservingMarkupFrom:)`, which removes reasoning blocks and unwraps one model-added outer XML envelope only when that markup was not dictated. History persists the raw text, enhanced text, prompt name, provider/model, duration, and exact system/user request messages in `Transcription`.

The evaluated hybrid artifact is a complete system prompt, so VoiceInk's **Use System Template** toggle must be off for this prompt. The installed app was inspected but not changed: it currently selects `Denya 14feb2026` with Anthropic `claude-sonnet-4-5`, not the repo hybrid artifact.

## Reproducibility

- Dataset: `dataset.json` — 42 synthetic cases (12 train, 15 dev, 15 held-out), primarily Russian plus English and Spanish.
- Runner: `evaluate.py` — exactly 15 unique prompt variants; train informs variants, dev selects two challengers, held-out is opened only for control plus those challengers.
- Results: `results.json` — 270 scheduled generations, zero API errors, outputs, gates, latency, usage, category deltas, and overfitting deltas.
- Frozen control SHA-256: `748ce195e853fe9cd1201d1c7ef7762366945c9be3e23f1e2be98064a435dea5`.
- Winner/artifact SHA-256: `5ea669e2bd16549245bc19958a3d710f842e3788fcddad7f6f7eefb0c40e23a4`.

Run the local regression check with:

```sh
python3 docs/prompt-evals/quantities-20260807/evaluate.py --check
```

Re-run paid evaluation calls only when intentionally refreshing the evidence:

```sh
python3 docs/prompt-evals/quantities-20260807/evaluate.py --execute
```

## Safe installation and restart verification

Do not overwrite the currently selected prompt. After integrating this commit:

1. In VoiceInk, edit the intended Mode and open **AI Enhancement → Prompt → Add prompt**.
2. Name it `Denya Hybrid Quantities 07aug2026`, paste the entire `docs/prompts/Denya-Hybrid-VoiceInk.txt`, turn **Use System Template** off, then choose **Create & Select** and save the Mode.
3. Quit VoiceInk so preferences are flushed. From `/Users/denya/code/external/VoiceInk`, verify exact read-back:

```sh
python3 - <<'PY'
import hashlib, json, plistlib
from pathlib import Path

artifact = Path("docs/prompts/Denya-Hybrid-VoiceInk.txt").read_text()
prefs = plistlib.loads((Path.home() / "Library/Preferences/com.prakashjoshipax.voiceink.plist").read_bytes())
rows = json.loads(prefs["customPrompts"])
row = next(row for row in rows if row["title"] == "Denya Hybrid Quantities 07aug2026")
assert row["promptText"] == artifact
assert row["useSystemInstructions"] is False
print(row["title"], hashlib.sha256(artifact.encode()).hexdigest())
PY
```

4. Reopen VoiceInk, confirm the Mode still selects `Denya Hybrid Quantities 07aug2026`, dictate `Готовность сто процентов, отклонение ноль процентов`, and verify History shows `Готовность 100%, отклонение 0%.` with the expected prompt/model request details.
5. Quit and run the read-back command once more; only then treat restart persistence as verified.
