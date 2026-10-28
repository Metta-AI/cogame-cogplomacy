# Cogplomacy post-training

## Authentic native model capture

Set `COGAME_SAVE_TRAJECTORY_URI` on the ordinary server to retain private native
requests, received responses, platform call IDs, applied actions and all retry,
fallback and normalization evidence. All seven private views are frozen before
any submission in each press/orders/retreats/builds phase. The native simultaneous
batches, parser, complete horizon and game rules stay unchanged. Failed model
decisions now stamp their actual scripted fallback provenance in the replay;
their actions and outcomes stay the same with capture enabled or disabled.

Only unchanged selected model replies can become targets. Optional omitted
JSON fields receive native empty defaults for equality checks only; parser or
engine repairs are excluded without rewriting the original response. Baselines
remain unknown-origin, never model teachers. Missing usage is unknown. Join
authenticated platform receipts before admitting any model label.

The seed changes power/alias assignment, not the 1901 world. Native trace families
therefore conservatively group all seed aliases by full year horizon and press
setting. Do not claim independent randomized boards or separate identical-role
self-play by requested seed. This coarse grouping can also keep distinct role
assignments together; audit finer groups before claiming wider generalization.

Compile the ordinary server/player and `tools/native_capture_fixture.nim`, then
run `python3 tools/test_native_capture.py GAME PLAYER FIXTURE NEW_EVIDENCE_DIR`.
The system workflow retains six complete server/player games, with capture on/off
replay/result parity, all four phase kinds, retries, true fallback flags,
normalization, private letters/notes, missing usage and credential-free fallback.
The provider is synthetic test evidence, not an authentic model demonstration.
Real model receipts, teacher quality, Qwen/SLIME preparation and learning require
separate measurements. The older scripted exports below remain mechanics checks.

`tools/export_posttrain.nim` plays ten complete native games for each
certified variant. At every phase it captures the system and user prompts
sent by the hosted game. The shipped expander and hedgehog policies supply
replies accepted by the production parser. All seven seats choose against
the same pre-phase state. Whole games stay in one data split.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/cogplomacy-posttrain tools/export_posttrain.nim
python3 tools/test_posttrain.py /tmp/cogplomacy-posttrain
/tmp/cogplomacy-posttrain /tmp/cogplomacy-data 10 standard
```

The other certified variant is `gunboat`. Ten games yielded 987 train and
249 validation decisions for `standard`, and 812 train and 215 validation
decisions for `gunboat`. The largest examples used 4,497 and 4,769 tokens
with a local Qwen2.5 tokenizer; set `--max-length 8192`. One CPU optimizer
step on a tiny local model reduced validation loss from 5.5937 to 5.5037
and 5.5368 to 5.4659. These short runs verify the training path, not policy
quality.

Use the [post-training research package](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining)
for current training and adapter-packaging workflows.


The exporter retains the native order notation and prompts, including each
seat's private notes and received letters. `gunboat` has no press phases.

## Prompt fuzzing

Use `promptVariant` to select canonical, plain, numbered, questions, or reordered
wording. Mixed selection requires a nonnegative `promptSeed`, independent of
game randomness. One selection stays fixed across every power and phase.
Heldout-briefing and heldout-reference are evaluation-only.

The bank varies movement, support, simultaneous orders, retreats, Winter
adjustments, scoring, and nonbinding diplomacy. Rule values and the JSON response
contract stay fixed. Canonical wording preserves the original prompt.

```sh
python3 tools/test_prompt_variants.py /tmp/cogplomacy-train-bridge
/tmp/cogplomacy-posttrain /tmp/cogplomacy-mixed 10 standard mixed 0
```

Mixed exports cycle through the five training wordings separately within each
split. This prevents every-fifth-seed validation from excluding a training wording. The manifest records each selection and normalized-proposal counts.
Only proposals matching the engine submission become training rows. Seed families
keep both game variants and all wordings in the same data split.
Existing complete-game checks cover phase transitions, private information,
prompt hashes, and equivalent scripted outcomes. They do not measure learned
robustness. Historical training scores above predate this filtering and wording bank.

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

Episode IDs include requested selection, resolved wording, and prompt seed, so
matched explicit and mixed collections remain distinct. Scenario families stay unchanged.
