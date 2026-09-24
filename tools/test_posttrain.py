"""Check complete, seed-separated Cogplomacy post-training episodes."""

import json
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


for variant in ("standard", "gunboat"):
    with TemporaryDirectory() as temporary:
        output = Path(temporary) / variant
        subprocess.run([sys.argv[1], str(output), "10", variant], check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        assert len(manifest["runs"]) == 10
        assert manifest["train_examples"] == len(train) > 0
        assert manifest["validation_examples"] == len(validation) > 0
        assert {row["seed"] for row in train}.isdisjoint({row["seed"] for row in validation})
        assert all(run["reason"] in ("complete", "solo") for run in manifest["runs"])
        assert all(len(run["scores"]) == 7 and all(0 <= score <= 1 for score in run["scores"]) for run in manifest["runs"])
        for row in train + validation:
            assert row["game"] == "cogplomacy"
            assert [part["role"] for part in row["prompt"]] == ["system", "user"]
            assert "THE BOARD:" in row["prompt"][1]["content"]
            reply = json.loads(row["completion"][0]["content"])
            assert set(reply) in (
                {"broadcast", "letters", "pledges", "notes"},
                {"orders", "notes"},
                {"retreats", "notes"},
                {"adjustments", "notes"},
            )
            if variant == "gunboat":
                assert "broadcast" not in reply
        print(f"{variant}: {len(train)} train, {len(validation)} validation decisions")
