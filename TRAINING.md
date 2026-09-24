# Cogplomacy post-training

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

From a Metta checkout with `metta-posttrain` installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/cogplomacy-data --output /tmp/cogplomacy-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 8192
```

The exporter retains the native order notation and prompts, including each
seat's private notes and received letters. `gunboat` has no press phases.
Numeric Metta RL and PufferLib training need a bounded action codec for this
game's orders, retreats, builds, and press.
