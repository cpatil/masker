#!/usr/bin/env python3
"""Local stdio bridge between Masker and Microsoft Presidio Analyzer."""

import json
import sys


def analyzer_engine():
    import tldextract
    from presidio_analyzer import AnalyzerEngine, RecognizerRegistry
    from presidio_analyzer.nlp_engine import NlpEngineProvider

    # The bundled public-suffix snapshot is sufficient for email recognition.
    # Disable tldextract's optional runtime list refresh so analysis stays offline.
    tldextract.extract = tldextract.TLDExtract(suffix_list_urls=())

    configuration = {
        "nlp_engine_name": "spacy",
        "models": [{"lang_code": "en", "model_name": "en_core_web_sm"}],
    }
    nlp_engine = NlpEngineProvider(nlp_configuration=configuration).create_engine()
    registry = RecognizerRegistry()
    registry.load_predefined_recognizers(
        languages=["en"], countries=["us"], nlp_engine=nlp_engine
    )
    return AnalyzerEngine(
        registry=registry,
        nlp_engine=nlp_engine,
        supported_languages=["en"],
    )


def non_overlapping(results):
    chosen = []
    for result in sorted(
        results,
        # Prefer the complete value when Presidio returns a high-confidence
        # substring inside a broader candidate, such as a date inside a phone.
        key=lambda item: (-(item.end - item.start), -item.score, item.start),
    ):
        if any(result.start < other.end and other.start < result.end for other in chosen):
            continue
        chosen.append(result)
    return sorted(chosen, key=lambda item: item.start)


def main():
    request = json.load(sys.stdin)
    language = request.get("language", "en")
    minimum_score = max(0.0, min(float(request.get("minimumScore", 0.2)), 1.0))
    analyzer = analyzer_engine()
    candidates = {}

    for segment in request.get("segments", []):
        text = segment.get("text", "")
        if not text.strip():
            continue
        results = analyzer.analyze(
            text=text,
            language=language,
            score_threshold=minimum_score,
        )
        for result in non_overlapping(results):
            value = text[result.start : result.end].strip()
            if len(value) < 2 or not any(character.isalnum() for character in value):
                continue
            key = value.casefold()
            existing = candidates.get(key)
            if existing is None:
                candidates[key] = {
                    "value": value,
                    "entityType": result.entity_type,
                    "score": result.score,
                    "occurrences": 1,
                }
            else:
                existing["occurrences"] += 1
                if result.score > existing["score"]:
                    existing["score"] = result.score
                    existing["entityType"] = result.entity_type

    values = sorted(
        candidates.values(),
        key=lambda item: (-item["score"], item["entityType"], item["value"].casefold()),
    )
    json.dump({"candidates": values}, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Do not echo document text or third-party exception details.
        sys.stderr.write("Presidio analysis failed.\n")
        raise SystemExit(1)
