#!/usr/bin/env python3
"""Evaluate exactly 15 VoiceInk prompt variants with the real request envelope."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import statistics
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from difflib import SequenceMatcher
from pathlib import Path

RUN_DIR = Path(__file__).resolve().parent
ROOT = RUN_DIR.parents[2]
DATASET = RUN_DIR / "dataset.json"
RESULTS = RUN_DIR / "results.json"
CONTROL_PROMPT = ROOT / "docs/prompts/Denya-Hybrid-VoiceInk.txt"
MODEL = "gemini-3.5-flash-lite"
API_URL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
FROZEN_CONTROL_SHA256 = "748ce195e853fe9cd1201d1c7ef7762366945c9be3e23f1e2be98064a435dea5"

VARIANT_BLOCKS = [
    ("v00_control", "Current Denya hybrid prompt", ""),
    ("v01_numeric_direct", "Direct numeric rendering", """
Numeric rendering:
- Convert unambiguous spoken quantities to concise digits while preserving their exact value, sign, unit, and qualifier.
- Keep numeric-looking literary or ambiguous prose in words.
"""),
    ("v02_quantity_context", "Quantity-context threshold", """
Quantity notation:
- Use digits only when number words clearly express an amount, percentage, date, time, range, decimal, version, currency, measurement, or identifier.
- Preserve number words used as literary ordinals or ambiguous prose.
"""),
    ("v03_multilingual_numbers", "Multilingual numeric cues", """
Spoken numbers:
- In Russian, English, and Spanish, render clear percentages, money, dates, times, ranges, decimals, versions, and measurements in standard numeric notation.
- Never guess missing digits or normalize identifiers that are already written correctly.
"""),
    ("v04_value_ledger", "Value-preserving normalization", """
Numeric value ledger:
- Changing number words to digits is formatting, not permission to change the value. Preserve every sign, decimal, unit, currency, date component, version component, range endpoint, and qualifier such as "not more than".
- Leave phone, account, document, and case identifiers byte-for-byte when already supplied as digits.
"""),
    ("v05_percent_focus", "Percentage-focused rule", """
Percentages:
- Render an unambiguous quantitative phrase such as "сто процентов", "one hundred percent", or "cien por ciento" as 100%.
- Preserve negation, bounds, decimals, and surrounding claims exactly; do not convert figurative or unclear wording.
"""),
    ("v06_money_decimal", "Money and decimal rule", """
Amounts and decimals:
- Render clear spoken currencies and decimals compactly with digits, the original sign, and the stated currency or unit.
- Do not round, change decimal separators semantically, infer a currency, or merge an identifier into an amount.
"""),
    ("v07_dates_versions", "Dates, times, ranges, and versions", """
Structured numbers:
- Render clearly dictated dates, times, ranges, and software versions with digits and conventional separators.
- Preserve every supplied component; never invent a year, leading digit, endpoint, or version segment.
"""),
    ("v08_ordinal_lists", "Enumeration-only ordinal lists", """
Ordinal enumeration:
- When first/second/third, первый/второй/третий, or primero/segundo/tercero introduce sibling items, remove those spoken markers and use 1., 2., 3. lines.
- Do not list-format ordinals that modify nouns in narrative or literary prose.
"""),
    ("v09_format_intent", "Dictated formatting intent", """
Formatting intent:
- Treat explicit counts, ordinal item markers, percentage words, currency names, "point/comma", "minus", date parts, and version separators as formatting cues only when their role is unambiguous.
- Keep the closest spoken wording whenever two interpretations remain plausible.
"""),
    ("v10_numeric_then_audit", "Render then audit", """
Numeric pass:
1. Render every unambiguous quantitative expression in readable numeric notation.
2. Silently compare the result with the speech and undo any changed value, sign, decimal, unit, currency, date, version, identifier, qualifier, or negation.
3. Preserve ambiguous prose in words.
"""),
    ("v11_examples", "Cross-language examples", """
Numeric examples (format only; never copy their values):
- "сто процентов" -> "100%"; "минус три целых пять" -> "−3,5".
- "one hundred euros" -> "€100"; "version two point one" -> "version 2.1".
- "noventa y nueve coma cinco por ciento" -> "99,5%".
Apply only when the phrase is clearly quantitative.
"""),
    ("v12_conservative_notation", "Conservative notation boundary", """
Notation boundary:
- Prefer digits for explicit calculations, claims, amounts, percentages, dates, times, ranges, decimals, versions, and measurements.
- Prefer words for stories, idioms, approximate rhetoric, and ordinals attached to narrative nouns.
- Existing digit strings and identifiers are immutable unless the speaker explicitly corrects them.
"""),
    ("v13_combined_compact", "Compact numeric and enumeration contract", """
Numbers and enumerations:
- Convert only clear quantitative speech to digits: preserve exact value, sign, decimal, unit, currency, bounds, date/time/version components, identifiers, and negation.
- Format explicit sibling ordinals as a numbered list; keep narrative ordinals as prose.
- Existing correct digits stay unchanged. Ambiguity means no conversion.
"""),
    ("v14_combined_explicit", "Explicit protected numeric contract", """
Numeric and enumeration contract:
- Render unambiguous spoken percentages, money, signed values, decimals, dates, times, ranges, versions, measurements, and explicit counts with digits and conventional notation.
- Preserve the exact numeric value, sign, decimal, currency/unit, qualifier, negation, date/version components, and event meaning. Never invent missing components.
- Preserve already-correct phone, account, document, case, invoice, and other identifiers exactly.
- Format explicit sibling ordinal markers as 1., 2., 3. lines, removing only the redundant markers. Keep literary, narrative, and ambiguous ordinals in prose.
- If numeric role or formatting intent is uncertain, keep the spoken words.
"""),
]


def digest(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def atomic_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def load_env() -> None:
    for path in (
        ROOT / ".env",
        Path.home() / "code/claude-playground/.env",
    ):
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip().removeprefix("export "), value.strip().strip("\"'"))


def prompts() -> list[dict[str, str]]:
    control = CONTROL_PROMPT.read_text(encoding="utf-8")
    marker = "Final silent check:"
    winner_block = next(block.strip() for variant_id, _, block in VARIANT_BLOCKS if variant_id == "v11_examples")
    control = control.replace(f"{winner_block}\n\n{marker}", marker)
    assert control.count(marker) == 1
    assert digest(control) == FROZEN_CONTROL_SHA256
    rows = []
    for variant_id, description, block in VARIANT_BLOCKS:
        prompt = control if not block else control.replace(marker, f"{block.strip()}\n\n{marker}")
        rows.append({"id": variant_id, "description": description, "prompt": prompt})
    assert len(rows) == 15
    assert len({digest(row["prompt"]) for row in rows}) == 15
    return rows


def filter_output(text: str, source: str) -> str:
    for pattern in (r"(?s)<thinking>(.*?)</thinking>", r"(?s)<think>(.*?)</think>", r"(?s)<reasoning>(.*?)</reasoning>"):
        text = re.sub(pattern, "", text)
    text = text.strip()
    match = re.fullmatch(r"(?is)<([A-Z][A-Z0-9_.:-]*)(?:\s[^>]*)?>\s*(.*?)\s*</\1\s*>", text)
    if match and re.search(rf"<{re.escape(match.group(1))}", source, re.IGNORECASE) is None:
        return match.group(2).strip()
    return text


def normalize(text: str) -> str:
    return " ".join(text.casefold().replace("ё", "е").split())


def gate(case: dict[str, object], output: str) -> dict[str, object]:
    failures: list[str] = []
    stripped = output.strip()
    if not stripped:
        failures.append("empty")
    if stripped.startswith(("{", "```", "<USER_MESSAGE", "<SYSTEM_INSTRUCTIONS")):
        failures.append("wrapper")
    for pattern in case.get("required", []):
        if re.search(str(pattern), stripped, re.IGNORECASE | re.MULTILINE) is None:
            failures.append(f"missing:{pattern}")
    for pattern in case.get("forbidden", []):
        if re.search(str(pattern), stripped, re.IGNORECASE | re.MULTILINE):
            failures.append(f"forbidden:{pattern}")
    for entity in case.get("entities", []):
        if str(entity) not in stripped:
            failures.append(f"entity:{entity}")
    for negation in case.get("negations", []):
        if re.search(rf"(?<!\w){re.escape(str(negation))}(?!\w)", stripped, re.IGNORECASE) is None:
            failures.append(f"negation:{negation}")
    if case.get("list_items"):
        found = re.findall(r"(?m)^\s*\d+[.)]\s+", stripped)
        if len(found) != int(case["list_items"]):
            failures.append(f"list_count:{len(found)}")
    if case.get("preserve_exact") and stripped != str(case["expected"]):
        failures.append("not_exact")
    similarity = 100 * SequenceMatcher(None, normalize(str(case["expected"])), normalize(stripped), autojunk=False).ratio()
    semantic_score = round(min(similarity, 49.0) if failures else similarity, 2)
    return {"passed": not failures, "failures": failures, "semantic_score": semantic_score}


def envelope(case: dict[str, object], prompt: str, model: str) -> dict[str, object]:
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": f"\n<USER_MESSAGE>\n{case['input']}\n</USER_MESSAGE>"},
        ],
        "temperature": 0.3,
        "max_tokens": 2048,
    }


def call(api_key: str, case: dict[str, object], variant: dict[str, str], model: str) -> dict[str, object]:
    payload = envelope(case, variant["prompt"], model)
    request = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    started = time.perf_counter()
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                body = json.load(response)
            raw = body["choices"][0]["message"]["content"]
            output = filter_output(raw, str(case["input"]))
            return {
                "output": output,
                "model_readback": body.get("model"),
                "latency_ms": round((time.perf_counter() - started) * 1000),
                "usage": body.get("usage", {}),
                "gate": gate(case, output),
            }
        except urllib.error.HTTPError as exc:
            if exc.code not in {429, 500, 502, 503, 504} or attempt == 4:
                raise RuntimeError(f"Gemini HTTP {exc.code}") from exc
            time.sleep(2**attempt)
        except urllib.error.URLError:
            if attempt == 4:
                raise
            time.sleep(2**attempt)
    raise AssertionError("unreachable")


def generation_key(stage: str, variant_id: str, case_id: str) -> str:
    return f"{stage}|{variant_id}|{case_id}"


def run_plan(
    plan: list[tuple[str, dict[str, str], dict[str, object]]],
    api_key: str,
    model: str,
    stored: dict[str, dict[str, object]],
) -> None:
    pending = [
        item for item in plan
        if generation_key(item[0], item[1]["id"], str(item[2]["id"])) not in stored
        or "error" in stored[generation_key(item[0], item[1]["id"], str(item[2]["id"]))]
    ]
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {pool.submit(call, api_key, case, variant, model): (stage, variant, case) for stage, variant, case in pending}
        for index, future in enumerate(as_completed(futures), 1):
            stage, variant, case = futures[future]
            key = generation_key(stage, variant["id"], str(case["id"]))
            try:
                row = future.result()
            except Exception as exc:
                row = {"error": f"{type(exc).__name__}: {exc}", "gate": {"passed": False, "failures": ["api_error"], "semantic_score": 0.0}}
            stored[key] = {"stage": stage, "variant_id": variant["id"], "case_id": case["id"], **row}
            atomic_json(RESULTS, {"state": "running", "model": model, "generations": list(stored.values())})
            print(f"{index}/{len(pending)} {key} {'PASS' if row['gate']['passed'] else 'FAIL'}")


def summary(rows: list[dict[str, object]], variants: list[dict[str, str]], stage: str) -> list[dict[str, object]]:
    result = []
    for variant in variants:
        selected = [row for row in rows if row["stage"] == stage and row["variant_id"] == variant["id"]]
        if not selected:
            continue
        latencies = [int(row["latency_ms"]) for row in selected if "latency_ms" in row]
        result.append({
            "variant_id": variant["id"],
            "passes": sum(bool(row["gate"]["passed"]) for row in selected),
            "total": len(selected),
            "mean_semantic_score": round(statistics.mean(float(row["gate"]["semantic_score"]) for row in selected), 2),
            "median_latency_ms": round(statistics.median(latencies)) if latencies else None,
            "failed_cases": [row["case_id"] for row in selected if not row["gate"]["passed"]],
        })
    return result


def regressions(rows: list[dict[str, object]], stage: str, candidate: str) -> dict[str, list[str]]:
    def failed(variant_id: str) -> set[str]:
        return {str(row["case_id"]) for row in rows if row["stage"] == stage and row["variant_id"] == variant_id and not row["gate"]["passed"]}
    control, challenger = failed("v00_control"), failed(candidate)
    return {"new": sorted(challenger - control), "resolved": sorted(control - challenger)}


def category_deltas(rows: list[dict[str, object]], cases: list[dict[str, object]], stage: str, candidate: str) -> dict[str, dict[str, int]]:
    case_map = {str(case["id"]): case for case in cases}
    values: dict[str, dict[str, int]] = {}
    for variant_id, label in (("v00_control", "control_passes"), (candidate, "candidate_passes")):
        for row in rows:
            if row["stage"] != stage or row["variant_id"] != variant_id:
                continue
            category = str(case_map[str(row["case_id"])]["category"])
            values.setdefault(category, {"control_passes": 0, "candidate_passes": 0, "total": 0})
            values[category][label] += int(bool(row["gate"]["passed"]))
            if label == "control_passes":
                values[category]["total"] += 1
    return dict(sorted(values.items()))


def check() -> None:
    cases = json.loads(DATASET.read_text(encoding="utf-8"))
    variants = prompts()
    assert len(cases) == 42
    assert {split: sum(case["split"] == split for case in cases) for split in ("train", "dev", "heldout")} == {"train": 12, "dev": 15, "heldout": 15}
    assert gate(next(case for case in cases if case["id"] == "dev_ru_percent_quantity"), "Мы выполнили 100% плана и не превысили бюджет.")["passed"]
    assert not gate(next(case for case in cases if case["id"] == "dev_ru_percent_quantity"), "Мы выполнили сто процентов плана.")["passed"]
    assert filter_output("<TRANSCRIPT>100%</TRANSCRIPT>", "сто процентов") == "100%"
    assert filter_output("<TRANSCRIPT>100%</TRANSCRIPT>", "<TRANSCRIPT>сто процентов</TRANSCRIPT>").startswith("<TRANSCRIPT>")
    assert len(variants) == 15
    assert digest(CONTROL_PROMPT.read_text(encoding="utf-8")) == digest(next(row["prompt"] for row in variants if row["id"] == "v11_examples"))
    print("check passed: 42 cases, 15 unique prompts, gates and source-aware envelope filter")


def execute(model: str) -> None:
    load_env()
    api_key = os.getenv("GEMINI_API_KEY") or os.getenv("GEMINI_KEY")
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY or GEMINI_KEY is required")
    cases: list[dict[str, object]] = json.loads(DATASET.read_text(encoding="utf-8"))
    variants = prompts()
    by_id = {variant["id"]: variant for variant in variants}
    stored: dict[str, dict[str, object]] = {}
    if RESULTS.exists():
        prior = json.loads(RESULTS.read_text(encoding="utf-8"))
        if prior.get("model") == model:
            stored = {generation_key(str(row["stage"]), str(row["variant_id"]), str(row["case_id"])): row for row in prior.get("generations", [])}
            case_map = {str(case["id"]): case for case in cases}
            for row in stored.values():
                if "output" in row:
                    row["gate"] = gate(case_map[str(row["case_id"])], str(row["output"]))

    dev = [case for case in cases if case["split"] == "dev"]
    run_plan([("dev", variant, case) for variant in variants for case in dev], api_key, model, stored)
    rows = list(stored.values())
    dev_summary = summary(rows, variants, "dev")
    control = next(row for row in dev_summary if row["variant_id"] == "v00_control")
    eligible = [
        row for row in dev_summary
        if row["variant_id"] != "v00_control"
        and not regressions(rows, "dev", str(row["variant_id"]))["new"]
        and int(row["passes"]) >= int(control["passes"])
    ]
    eligible.sort(key=lambda row: (-int(row["passes"]), -float(row["mean_semantic_score"]), len(by_id[str(row["variant_id"])]["prompt"])))
    shortlist = [str(row["variant_id"]) for row in eligible[:2]]
    if len(shortlist) < 2:
        fallback = [str(row["variant_id"]) for row in dev_summary if row["variant_id"] != "v00_control" and row["variant_id"] not in shortlist]
        fallback.sort(key=lambda variant_id: (-next(int(row["passes"]) for row in dev_summary if row["variant_id"] == variant_id), len(regressions(rows, "dev", variant_id)["new"])))
        shortlist.extend(fallback[: 2 - len(shortlist)])

    heldout = [case for case in cases if case["split"] == "heldout"]
    heldout_variants = [by_id["v00_control"], *(by_id[variant_id] for variant_id in shortlist)]
    run_plan([("heldout", variant, case) for variant in heldout_variants for case in heldout], api_key, model, stored)
    heldout_ids = {variant["id"] for variant in heldout_variants}
    rows = [row for row in stored.values() if row["stage"] == "dev" or row["variant_id"] in heldout_ids]
    heldout_summary = summary(rows, heldout_variants, "heldout")
    held_control = next(row for row in heldout_summary if row["variant_id"] == "v00_control")
    safe = []
    for candidate in shortlist:
        candidate_summary = next(row for row in heldout_summary if row["variant_id"] == candidate)
        swap = regressions(rows, "heldout", candidate)
        if not swap["new"] and swap["resolved"] and float(candidate_summary["mean_semantic_score"]) >= float(held_control["mean_semantic_score"]) - 1.0:
            safe.append(candidate_summary)
    safe.sort(key=lambda row: (-int(row["passes"]), -float(row["mean_semantic_score"])))
    winner = str(safe[0]["variant_id"]) if safe else "v00_control"
    decision = "winner" if safe else "no-go"

    # One separate read-back proves the selected prompt works through VoiceInk's exact system/user envelope.
    smoke_case = next(case for case in heldout if case["id"] == "held_ru_percent")
    smoke = call(api_key, smoke_case, by_id[winner], model)
    payload = {
        "state": "complete",
        "decision": decision,
        "winner": winner,
        "model": model,
        "model_readback": smoke.get("model_readback"),
        "temperature": 0.3,
        "variant_count": 15,
        "dataset_sha256": digest(DATASET.read_text(encoding="utf-8")),
        "control_prompt_sha256": digest(by_id["v00_control"]["prompt"]),
        "variants": [{"id": row["id"], "description": row["description"], "sha256": digest(row["prompt"]), "characters": len(row["prompt"])} for row in variants],
        "split_counts": {split: sum(case["split"] == split for case in cases) for split in ("train", "dev", "heldout")},
        "envelope": {"system": "candidate prompt", "user": "\\n<USER_MESSAGE>\\n{transcript}\\n</USER_MESSAGE>", "source_aware_filter": True},
        "dev": {"summary": dev_summary, "shortlist": shortlist, "regressions": {candidate: regressions(rows, "dev", candidate) for candidate in shortlist}},
        "heldout": {
            "summary": heldout_summary,
            "regressions": {candidate: regressions(rows, "heldout", candidate) for candidate in shortlist},
            "category_deltas": {candidate: category_deltas(rows, cases, "heldout", candidate) for candidate in shortlist},
            "overfitting": {
                candidate: {
                    "dev_pass_delta": next(int(row["passes"]) for row in dev_summary if row["variant_id"] == candidate) - int(control["passes"]),
                    "heldout_pass_delta": next(int(row["passes"]) for row in heldout_summary if row["variant_id"] == candidate) - int(held_control["passes"]),
                    "new_heldout_regressions": regressions(rows, "heldout", candidate)["new"],
                }
                for candidate in shortlist
            },
        },
        "smoke": {"case_id": smoke_case["id"], **smoke},
        "generations": sorted(rows, key=lambda row: (str(row["stage"]), str(row["variant_id"]), str(row["case_id"]))),
    }
    atomic_json(RESULTS, payload)
    print(f"{decision}: {winner}; results: {RESULTS}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--model", default=MODEL)
    args = parser.parse_args()
    if args.check:
        check()
    if args.execute:
        execute(args.model)
    if not args.check and not args.execute:
        parser.error("choose --check and/or --execute")
