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
        source = output / "trajectories.jsonl"
        assert source.stat().st_mode & 0o777 == 0o600
        assert not (output / "train.jsonl").exists()
        assert not (output / "validation.jsonl").exists()
        episodes, decisions = [], 0
        with source.open() as stream:
            for line in stream:
                row = json.loads(line)
                assert row["game"] == "cogplomacy"
                assert row["source_revision"] == manifest["source_revision"]
                if row["event_type"] == "episode":
                    episodes.append(row)
                    continue
                decisions += 1
                (attempt,) = row["attempts"]
                assert attempt["origin"] == "teacher"
                assert attempt["policy"] in ("scripted-expander", "scripted-hedgehog")
                assert [part["role"] for part in attempt["prompt"]] == [
                    "system",
                    "user",
                ]
                assert "THE BOARD:" in attempt["prompt"][1]["content"]
                reply = json.loads(attempt["response"])
                assert reply == attempt["parsed_action"]
                assert set(reply) in (
                    {"broadcast", "letters", "pledges", "notes"},
                    {"orders", "notes"},
                    {"retreats", "notes"},
                    {"adjustments", "notes"},
                )
                if variant == "gunboat":
                    assert "broadcast" not in reply
                if row["action_status"] == "accepted":
                    assert attempt["accepted"] and row["executed_action"] == reply
                else:
                    assert (
                        not attempt["accepted"] and row["selected_attempt_id"] is None
                    )
                    assert row["fallback_origin"] == "engine-normalized-submission"
        assert len(episodes) == len(manifest["runs"]) == 10
        assert decisions == sum(run["decisions"] for run in manifest["runs"])
        assert {row["seed_family"] for row in episodes} == {
            f"cogplomacy-{seed}" for seed in range(1, 11)
        }
        assert all(row["status"] == "completed" for row in episodes)
        assert all(run["reason"] in ("complete", "solo") for run in manifest["runs"])
        assert all(
            len(run["scores"]) == 7 and all(0 <= score <= 1 for score in run["scores"])
            for run in manifest["runs"]
        )
        print(
            f"{variant}: {len(episodes)} private complete episodes, {decisions} resolved decisions"
        )
