"""Exercise complete native server/player games and preserve all test artifacts."""

import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        user = body["messages"][0]["content"]
        slot = self.headers["X-Coworld-Player-Slot"]
        user = body["messages"][0]["content"]
        assert "PRIVATE_OPERATOR_" + slot in user
        assert all("PRIVATE_OPERATOR_" + str(i) not in user for i in range(7) if str(i) != slot)
        assert "SPECTATOR_POLICY_" not in user and "SPECTATOR_POLICY_" not in body["system"]
        text = self.server.fixture[(int(slot), body["system"], user)]
        response = json.dumps(
            {
                "model": body["model"],
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": text}],
                "usage": None if slot == "0" else {"input_tokens": 100, "output_tokens": 20},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid5(uuid.NAMESPACE_URL, raw.decode())))
        self.end_headers()
        self.wfile.write(response)


def run(game, player, fixture_generator, output, variant, capture, model_enabled=True):
    root = output / f"{variant['id']}-capture{capture}{'' if model_enabled else '-offline'}"
    root.mkdir(mode=0o700)
    config = dict(variant["game_config"])
    seats = 7
    config.update(
        seed=42,
        turnDelayMs=0,
        players=[{"name": f"SPECTATOR_POLICY_{i}"} for i in range(seats)],
        llmTimeoutSeconds=1,
        playerConnectTimeoutSeconds=5,
        episodeTimeoutSeconds=600,
        tokens=[f"fixture-{i}" for i in range(seats)],
    )
    (root / "config.json").write_text(json.dumps(config))
    subprocess.run(
        [str(fixture_generator), str(root / "config.json"), str(root / "fixture.json")],
        check=True,
        timeout=60,
        stdout=subprocess.DEVNULL,
    )
    fixture = json.loads((root / "fixture.json").read_text())
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    env = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "COWORLD_LLM_MODEL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "AWS_BEARER_TOKEN_BEDROCK",
    ):
        env.pop(key, None)
    episode = f"cogplomacy-native-capture-fixture-{variant['id']}"
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(root / "config.json").as_uri(),
        COGAME_RESULTS_URI=(root / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID=episode,
        COWORLD_GAME_VERSION="identity-fixture",
        COWORLD_SOURCE_REVISION="a" * 40,
    )
    if not capture:
        env.pop("COGAME_SAVE_TRAJECTORY_URI")
    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    provider.fixture = {(row["slot"], row["system"], row["user"]): row["response"] for row in fixture["requests"]}
    assert len(provider.fixture) == len(fixture["requests"])
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    if model_enabled:
        env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{provider.server_port}"
        env["COWORLD_LLM_MODEL"] = "native-capture-fixture"
    children = []
    streams = []
    try:
        log = (root / "game.log").open("wb")
        streams.append(log)
        server = subprocess.Popen([str(game)], env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append(server)
        for _ in range(100):
            assert server.poll() is None, "game exited before readiness; see retained game.log"
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
                    assert response.status == 200
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.05)
        else:
            raise TimeoutError("native game did not become ready")
        for seat in range(seats):
            log = (root / f"player-{seat}.log").open("wb")
            streams.append(log)
            player_env = dict(env, PLAYER_PROMPT=f"PRIVATE_OPERATOR_{seat}", COWORLD_TIMEOUT_SECONDS="600")
            player_env["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{port}/player?slot={seat}&token=fixture-{seat}"
            children.append(subprocess.Popen([str(player)], env=player_env, stdout=log, stderr=subprocess.STDOUT))
        assert server.wait(timeout=360) == 0
        for child in children[1:]:
            assert child.wait(timeout=5) == 0
        results = json.loads((root / "results.json").read_text())
        replay = json.loads((root / "replay.json").read_text())
        assert results["reason"] == "complete"
        assert results["years"] == config["years"]
        if capture:
            trace = root / "trajectory.jsonl"
            rows = [json.loads(line) for line in trace.read_text().splitlines()]
            assert trace.stat().st_mode & 0o077 == 0
            assert rows[-1]["status"] == "completed" and rows[-1]["outcome"] == results
            assert (
                rows[-1]["seed_family"] == f"cogplomacy-1901-years{config['years']}-press{str(config['press']).lower()}"
            )
            events = [event for event in replay["events"] if event["kind"] in ("press", "orders", "retreat", "build")]
            assert len(events) == len(rows) - 1 > 70
            if model_enabled:
                assert results == fixture["results"] and replay["events"] == fixture["events"]
                assert len(rows) - 1 == len(fixture["expected"])
            missing_usage = 0
            for position, (event, row) in enumerate(zip(events, rows[:-1], strict=True)):
                seat = event["seat"]
                assert seat == int(row["seat"])
                if not model_enabled:
                    assert row["action_status"] == "fallback" and row["selected_attempt_id"] is None
                    assert len(row["attempts"]) == 1 and row["attempts"][0]["origin"] == "unknown"
                    assert row["attempts"][0]["platform_call_id"] is None
                    continue
                expected = fixture["expected"][position]
                assert row["decision_id"] == f"event-{expected['event_index']}"
                view = dict(row["observation"])
                view.pop("prompt_attempts")
                assert view == expected["observation"]
                assert row["executed_action"] == expected["action"]
                assert event.get("scripted", False) == expected["scripted"]
                assert "notes" not in view
                attempts = row["attempts"]
                if expected["phase_index"] == 0:
                    assert row["action_status"] == "fallback" and event["scripted"]
                    assert len(attempts) == 2 and row["selected_attempt_id"] is None
                elif expected["phase_index"] == 1:
                    assert len(attempts) == 2 and not attempts[0]["accepted"]
                if row["action_status"] == "accepted":
                    assert row["selected_attempt_id"] == attempts[-1]["attempt_id"]
                    assert attempts[-1]["parsed_action"] == row["executed_action"]
                else:
                    assert row["action_status"] in ("fallback", "rejected") and row["selected_attempt_id"] is None
                for attempt in attempts:
                    assert attempt["platform_call_id"] is not None and attempt["behavior_logprobs"] is None
                    assert attempt["prompt"][0]["content"] == attempt["request"]["system"]
                    assert "SPECTATOR_POLICY_" not in json.dumps(attempt["prompt"])
                    user = attempt["request"]["messages"][0]["content"]
                    assert all(f"PRIVATE_CAPTURE_{i}" not in user for i in range(7) if i != seat)
                    key = (seat, attempt["request"]["system"], attempt["request"]["messages"][0]["content"])
                    original = provider.fixture[key]
                    response = json.loads(attempt["raw_response"])
                    assert response["content"][0]["text"] == original
                    if seat == 0:
                        assert attempt["input_tokens"] is None and attempt["output_tokens"] is None
                        missing_usage += 1
            if model_enabled:
                assert missing_usage > 0
        return results, replay
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=5)
        for child in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        for stream in streams:
            stream.close()


def main():
    game, player, fixture_generator, destination = map(lambda value: Path(value).resolve(), sys.argv[1:])
    destination.mkdir(mode=0o700, exist_ok=False)
    manifest = json.loads((Path(__file__).resolve().parents[1] / "coworld_manifest_template.json").read_text())
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [
            (
                pool.submit(run, game, player, fixture_generator, destination, variant, True),
                pool.submit(run, game, player, fixture_generator, destination, variant, False),
            )
            for variant in manifest["variants"]
        ]
        for captured, ordinary in futures:
            assert captured.result() == ordinary.result(), "capture changed the native outcome or replay"
    captured = run(game, player, fixture_generator, destination, manifest["variants"][0], True, model_enabled=False)
    ordinary = run(game, player, fixture_generator, destination, manifest["variants"][0], False, model_enabled=False)
    assert captured == ordinary, "capture changed the offline fallback game"
    print(
        "six complete native games: exact replay parity, simultaneous private views and all four phases, "
        "retries, true fallback flags, normalization, privacy, missing usage and offline fallback pass"
    )


if __name__ == "__main__":
    main()
