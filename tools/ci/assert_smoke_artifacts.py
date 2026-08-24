#!/usr/bin/env python3
"""Assert what the docker smoke produced, against the manifest's own schema.

tools/ci/docker_smoke.sh is the coworld-builder template, copied verbatim, and
it checks only the invariants every game shares (no player failure, a
non-empty results.json, seat-count agreement, a replay that parses). The
design note's CI-jobs section asks for more of THIS game: results.json
validating against `game.results_schema`, `reason == "complete"`, seven
scores, and a replay carrying `events`, `results`, `names`, `policyNames`,
`powers` and `config`. That is what this script adds, from ci.yml, leaving
the shared template untouched.

    python3 tools/ci/assert_smoke_artifacts.py \
        --manifest coworld_manifest_template.json \
        --results dist/smoke/results.json \
        --replay dist/smoke/replay.json \
        --seats 7
"""
import argparse
import json
import sys

REPLAY_KEYS = ("events", "results", "names", "policyNames", "powers",
               "config")

failures = []


def fail(message):
    failures.append(message)


def check_type(value, expected, where):
    kinds = {
        "object": dict,
        "array": list,
        "string": str,
        "number": (int, float),
        "integer": int,
        "boolean": bool,
    }
    if expected not in kinds:
        return True
    if expected in ("number", "integer") and isinstance(value, bool):
        fail(f"{where}: expected {expected}, got a boolean")
        return False
    if not isinstance(value, kinds[expected]):
        fail(f"{where}: expected {expected}, got {type(value).__name__}")
        return False
    return True


def validate(value, schema, where="results"):
    """The slice of JSON Schema the manifest actually uses."""
    if "type" in schema and not check_type(value, schema["type"], where):
        return
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                fail(f"{where}: missing required key {key!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in properties:
                    fail(f"{where}: unexpected key {key!r}")
        for key, sub in properties.items():
            if key in value:
                validate(value[key], sub, f"{where}.{key}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            fail(f"{where}: {len(value)} items, minimum {schema['minItems']}")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            fail(f"{where}: {len(value)} items, maximum {schema['maxItems']}")
        for index, item in enumerate(value):
            if "items" in schema:
                validate(item, schema["items"], f"{where}[{index}]")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            fail(f"{where}: {value} below minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            fail(f"{where}: {value} above maximum {schema['maximum']}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--results", required=True)
    parser.add_argument("--replay", required=True)
    parser.add_argument("--seats", type=int, required=True)
    args = parser.parse_args()

    manifest = json.loads(open(args.manifest, "rb").read().decode("utf-8"))
    schema = manifest["game"]["results_schema"]
    results = json.loads(open(args.results, "rb").read().decode("utf-8"))
    validate(results, schema)

    if results.get("reason") != "complete":
        fail(f"results.reason is {results.get('reason')!r}, expected "
             "'complete' (an offline smoke plays every year out)")
    for key in ("names", "powers", "scores", "centres", "units"):
        if len(results.get(key, [])) != args.seats:
            fail(f"results.{key} has {len(results.get(key, []))} entries, "
                 f"expected {args.seats}")

    replay = json.loads(open(args.replay, "rb").read().decode("utf-8"))
    for key in REPLAY_KEYS:
        if key not in replay:
            fail(f"replay is missing {key!r}")
    if not replay.get("events"):
        fail("replay carries no events")

    if failures:
        for message in failures:
            print(f"::error::SMOKE ARTIFACT FAIL: {message}")
        return 1
    print(f"smoke artifacts OK: reason={results['reason']} "
          f"scores={len(results['scores'])} events={len(replay['events'])} "
          f"replay keys={sorted(replay)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
