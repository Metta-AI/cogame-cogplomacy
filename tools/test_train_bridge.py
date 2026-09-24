"""Run complete Cogplomacy games through the numeric bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
for variant in ("standard", "gunboat"):
    for policy in ("teacher", "random"):
        with subprocess.Popen(
            [sys.argv[1], str(manifest), variant],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        ) as bridge:
            assert bridge.stdin is not None and bridge.stdout is not None

            def request(payload):
                bridge.stdin.write(json.dumps(payload) + "\n")
                bridge.stdin.flush()
                return json.loads(bridge.stdout.readline())

            observation = request({"kind": "reset", "seed": f"{variant}-{policy}", "players": 7})
            decisions = 0
            rng = random.Random(42)
            while observation["kind"] == "decision":
                assert observation["messages"][0]["content"].startswith("You are ")
                assert "THE BOARD:" in observation["messages"][1]["content"]
                encoded = request({"kind": "encode"})
                assert encoded["decision_id"] == observation["decision_id"]
                assert len(encoded["values"]) == 208
                assert encoded["actions"] == [{"choice": 0}, {"choice": 1}]
                action = (
                    json.loads(request({"kind": "teacher"})["response"])
                    if policy == "teacher"
                    else {"choice": rng.randrange(2)}
                )
                result = request(
                    {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
                )
                assert result["kind"] == "accepted" and result["action"] == action
                observation = result["observation"]
                decisions += 1
            assert 20 <= decisions <= 300
            assert set(observation["scores"]) == {str(seat) for seat in range(7)}
            assert all(0 <= score <= 1 for score in observation["scores"].values())
            assert observation["scores"] == observation["utilities"]
            bridge.stdin.close()
            assert bridge.wait() == 0
        print(f"{variant} {policy}: {decisions} decisions, 208 values")
