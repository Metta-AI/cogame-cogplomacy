# cogame-cogplomacy

**Diplomacy, 1901, seven cogs, no dice.**

Allan Calhamer's game on the standard map of Europe: seven great powers, armies and fleets, and
the classic simultaneous-orders adjudication — supports, convoys, standoffs, cut supports,
dislodgements, retreats and Winter builds. The only mechanic that matters is the **press phase**
before each turn: public broadcasts and private letters in free text, none of it binding.
Hold 18 of the 34 supply centres and you win outright; otherwise the episode is scored at the
turn cap by supply-centre share.

There is no randomness anywhere. The only draw from the seed is which seat plays which power and
what each seat's cog alias is, both fixed before Spring 1901. Everything that happens after that
is a function of what seven agents promised each other and what they actually ordered.

**A policy is just a prompt.** Every phase, the game server sends each seat's prompt plus the
whole board, the ownership table, two years of history, the press that seat received and its
private notes to Claude — as **one parallel batch for all seven seats**, because this is a
simultaneous-decision game. Field your own policy by reusing the published player image with a
different `PLAYER_PROMPT`:

```bash
coworld upload-policy coworld-cogplomacy:latest \
  --name my-cogplomacy \
  --run /bin/cogplomacy-player \
  --secret-env PLAYER_PROMPT="<your strategy, in words>"
```

Two scripted baselines ship in the same image and are selected with `PLAYER_SCRIPTED`:
`expander` (the greedy bot: take an unowned neutral centre, else an undefended rival centre, else
close the distance; never stand yourself off) and `hedgehog` (the wall: everything holds and props
up its neighbours). They are also the fallback for any decision that fails, and every seat plays
one when there are no LLM credentials — which is what lets certification complete offline.

---

## The game in one screen

| | |
|---|---|
| Seats | **7** — Austria, England, France, Germany, Italy, Russia, Turkey, dealt from the seed |
| A year | spring press → spring orders → spring retreats? → fall press → fall orders → fall retreats? → winter builds? |
| Press | one broadcast (400 chars) + up to 6 private letters (400 chars each) + up to 4 pledges, all written simultaneously, none of it binding |
| Pledges | `peace` with X · `keepout` of a province · `support` of X — the only promises a spectator can watch you break |
| Scoring | `centres / 34`, or **1.0** for a soloist on 18 and 0.0 for everyone else |
| Ends | `solo` · `complete` · `deadline` |

The full rules, the twelve-step resolution order and the order notation are in
[`docs/plans/2026-08-24-cogplomacy-design.md`](docs/plans/2026-08-24-cogplomacy-design.md) and in
the manifest's `rules.md` / `map.md` pages.

## Layout

```
src/cogplomacy/mapdata.nim     the 1901 board, compiled in: 75 provinces, both
                               adjacency graphs, the three split coasts, 22 units
src/cogplomacy/types.nim       config, units, orders, letters, pledges, events
src/cogplomacy/orders.nim      the notation: parse, print, enumerate legal orders
src/cogplomacy/adjudicate.nim  the resolver (Kruijswijk's Math of Adjudication,
                               circular-movement and Szykman backup rules)
src/cogplomacy/sim.nim         the episode: phases, press, ownership, scoring,
                               the event log and the replay re-derivation
src/cogplomacy/llm.nim         prompts, ONE parallel batch per phase, the two
                               scripted baselines
src/cogplomacy/server.nim      mummy server, the Coworld game contract
src/cogplomacy_player.nim      the player: deliver a prompt, then spectate
client/                        the broadcast chrome (bullwhip's, plus one block)
replay-viewer/                 the static wasm bundle: the same sim in the browser
data/map1901.json              the vector map the viewer draws
scripts/art/                   how the map and the power portraits were made
tests/                         map, adjudicator, sim, bots, scoring, viewer
```

## Building and running

The image carries both entrypoints:

```bash
docker build --platform=linux/amd64 -t coworld-cogplomacy:latest .
```

- `/bin/cogplomacy` — the game server (default `CMD`)
- `/bin/cogplomacy-player` — the prompt-delivery player

One end-to-end episode in raw docker, seven player containers, the certification fixture's seat
mix:

```bash
./tools/ci/docker_smoke.sh coworld-cogplomacy:latest
```

The static replay viewer bundle (falls back to the pinned `emscripten/emsdk` container when there
is no local `emcc`):

```bash
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --timeout 90
```

## Tests

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
# regenerate nim.cfg from the synced package tree (the committed one is gitignored)
for t in tests/*.nim; do nim r --hints:off --path:src "$t"; done
```

`tests/test_map.nim` pins the board; `tests/test_adjudicate.nim` is twenty named adjudication
cases (standoffs, cut support, the beleaguered garrison, circular movement, convoy disruption,
the Szykman paradox, head-to-heads); `tests/test_sim.nim` is the episode; `tests/test_bot.nim`
asserts the baselines only ever emit legal orders; `tests/test_score.nim` pins the share formula
and its sign; `tests/test_viewer.nim` pins the frame the renderer reads, the strict-UTF-8 replay
bytes and the naming guard on the appended chrome block. CI runs every file twice, debug and
`-d:release`.

## Watchability

The map is the stage. Provinces are drawn from `data/map1901.json` and tinted toward the owning
power's seat colour; supply centres are amber stars, filled when owned and hollow when neutral.
During press, letters fly between capitals and spectators read **all** the private
correspondence — the pleasure of watching Diplomacy is seeing the stab coming. At adjudication
every order draws at once: moves as arrows, supports as glowing braces, convoys as dashed sea
paths; bounces flash and tag the province `STANDOFF`, dislodged units shudder and go grey, and a
unit that moved against a pledge made that turn gets a red **STAB** stamp. A supply-centre bar
race runs along the top with a line at the 18-centre solo threshold, and the endcard replays the
alliance graph year by year.

Replays are a **static file plus a browser wasm viewer**, never a pod: the bundle runs the same
Nim adjudicator the server ran and re-derives every frame from the recorded events, so the viewer
contacts nothing but S3 for the `.replay` file.

## Art

`data/map1901.json` is a committed vector map of 1901 Europe — 75 province polygons, label
anchors, supply-centre dots and coast anchors in a 1000×800 space — built from a hand-placed
anchor per province by `scripts/art/build_map1901.py`. The seven power portraits
(`data/cog_*.png`) are nano-banana renders of the Softmax cog: `scripts/art/gen_power_cogs.py`
generates the two source sheets under `scripts/art/source/` and
`scripts/art/split_cog_sheet.py` keys, splits and pads them. Both scripts are deterministic
given their inputs; CI does not regenerate art, so the outputs are committed.

## License

MIT. See `LICENSE`.
