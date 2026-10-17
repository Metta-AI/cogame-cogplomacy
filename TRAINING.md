# Cogplomacy post-training

The exporter plays complete published games with seven powers. Standard has
four years with press; gunboat has six years without press. The shipped expander
and hedgehog teachers alternate by seat and seed. All decisions use one frozen
phase snapshot before the engine resolves orders, retreats, or Winter adjustments.

```sh
nim c -d:release --path:src -o:/tmp/cogplomacy-posttrain tools/export_posttrain.nim
/tmp/cogplomacy-posttrain /tmp/cogplomacy-data 10 standard plain 0
python3 tools/test_posttrain.py /tmp/cogplomacy-posttrain
```

The exporter requires clean committed source and a new output directory.
`trajectories.jsonl` holds private complete-episode events; `manifest.json`
records the source revision, wording, seeds, years, scores, and decision counts.
Episodes are written one at a time. Original proposals remain separate from
engine-normalized submissions. Dropped letters, repaired orders, automatic
disbands, and changed adjustments cannot silently become accepted teacher labels.

Convert events with `coworld.decision_trajectory.read_trajectory_jsonl` and
`export_complete_episodes`. Conversion does not authorize training. The importer
`metta_training.posttrain.hosted.export_hosted` requires external review bound to
the complete-episode SHA256 and source revision. Explicitly select the
`scripted-expander` and `scripted-hedgehog` teachers. The family `cogplomacy-SEED`
keeps both game variants and every wording in one data split.

## Rule wording

`promptVariant` selects `canonical`, `plain`, `numbered`, `questions`, or
`reordered`. `mixed` requires an explicit nonnegative `promptSeed` and selects
one training wording independently of game randomness. Selection stays fixed
for every power, phase, and retry. `heldout-briefing` and `heldout-reference` are
reserved for evaluation; training resets and candidate exports reject them.
Only the role, setting, and opponent introduction varies. Common rules, order
notation, scoring, private information, published horizons, pacing, and budgets
remain unchanged. Canonical text matches the original numeric bridge.

```sh
/tmp/cogplomacy-train-bridge coworld_manifest_template.json standard --language
python3 tools/test_prompt_variants.py /tmp/cogplomacy-train-bridge
```

The language bridge accepts production JSON replies for press, orders, retreats,
and builds. Acceptance means the parsed proposal was queued; all pending powers
submit before resolution. Use engine-resolved private episodes for authoritative
training targets. The private observation contains `prompt_template` metadata
with bank, wording, independent seed, and exact system/user hashes. These fields
stay out of model messages.

## Private native evidence

Set `COGAME_SAVE_TRAJECTORY_URI` to a private destination with
`COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`.
Capture preserves actual requests, messages, responses, retries, proposed replies,
and engine-accepted submissions. Authorization headers are excluded. Failed
requests retain rejection reasons and consumed fallbacks. Explicit scripted
policies are teachers. Replays now mark fallback decisions as scripted even when
the model client remains enabled. Deadline episodes are truncated; private events
are written before public results announce completion.

```sh
python3 tools/test_prompt_native_games.py GAME PLAYER OUTPUT SOURCE_REVISION
```

The native panel launches seven real players per game under ordinary budgets.
A closed local endpoint exercises actual failed requests and fallbacks; scripted
cases exercise accepted teacher submissions. Checks compare private observations,
request hashes, engine events, complete replays, and scores. The language panel
also exercises all four phases, private-note isolation, and duplicate-letter repair.
These checks do not establish model robustness or learning improvement. This
game-owned transport provides no authenticated serving receipts or token
probabilities for on-policy qualification.

Historical CPU pilots used the earlier row exporter. Validation loss changed
from 5.5937 to 5.5037 for standard and 5.5368 to 5.4659 for gunboat after one
optimizer step. Those results do not qualify the new candidate corpus or measure
paraphrase robustness. Historical largest examples required an 8,192-token context.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes 208 numeric values from the public board,
phase, and the acting seat's power. The action selects the shipped expander
or hedgehog strategy. All seven seats choose against the same pre-phase
state; the native simulator then resolves orders, retreats, or builds. The
text exporter above retains the full order and press vocabulary.

```sh
nim c -d:release --path:src -o:/tmp/cogplomacy-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/cogplomacy-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute bridge
and manifest paths to `recipes.external.coworld.train` for native PufferLib,
or `recipes.external.coworld_metta_rl.train` for Metta RL. Use `players=7`,
`max_decisions=300`, a timestep limit, and either variant ID. The bridge
also publishes the hosted prompts as `messages` and `semantic_view`.

## Local reinforcement learning proof

Metta RL completed 512 timesteps per variant through the numeric bridge.
Native PufferLib trained 4,096 CUDA timesteps per variant, then reloaded
each checkpoint on held-out seeds 101 and 102:

| Variant | Seed 101 score / performance / games | Seed 102 score / performance / games | Checkpoint SHA-256 |
| --- | --- | --- | --- |
| standard | 0.117647 / 0.558824 / 5 | 0.183824 / 0.591912 / 4 | `d018aa1924393757518be38199707fd75933037f2d946934faa84191af357392` |
| gunboat | 0.073529 / 0.536765 / 4 | 0.117647 / 0.558824 / 4 | `e9392b4828f3dd578f6baf833ebd642e4d79acbb51ebc62ba93c88ba51d6ca85` |

These short pilots verify training, checkpoint reload, and evaluation. They do
not establish competitive policies.
