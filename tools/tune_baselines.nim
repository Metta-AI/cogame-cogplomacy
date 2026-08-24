## Grid harness for the expander baseline's numeric choices.
##
## The expander has exactly two numbers in it: the rank penalty a Spring move
## pays for vacating an owned home centre, and the rank at which a unit stops
## moving for itself and supports one of ours instead. The design note pins
## both — one rank, and rank (c) — and this harness is how that is checked
## rather than guessed. Each cell plays a mixed table (four expanders on the
## swept tuning against three hedgehogs) over a grid of seeds and reports the
## centres each side finished with, the illegal orders written (always none)
## and whether every episode reached `complete`.
##
##     nim r --path:src tools/tune_baselines.nim
##
## `tests/test_bot.nim` runs a reduced sweep through this same code, so the
## table lands in every CI log and the harness cannot rot.

import std/strutils
import cogplomacy/llm

type GridCell* = object
  tuning*: ExpanderTuning
  centres*: int      ## centres the four expander seats ended with
  hedgehog*: int     ## centres the three hedgehog seats ended with
  illegal*: int      ## illegal orders written by anybody
  complete*: bool    ## every episode of the cell ended `complete`

proc playTable(cell: var GridCell, seed, years: int) =
  var config = defaultGameConfig()
  config.years = years
  config.seed = seed
  config.press = false       ## the baselines are silent; skip the phase
  config.sampled = true
  for index in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "P" & $(index + 1)))
    config.tokens.add("token-" & $index)
  var kinds: seq[ScriptKind]
  for index in 0 ..< Seats:
    kinds.add(if index < 4: skExpander else: skHedgehog)
  var sim = initSim(config)
  var guard = 0
  while not sim.done and guard < 2000:
    inc guard
    for seat in sim.pendingSeats():
      let kind = kinds[seat]
      var decision = scriptedDecision(sim, seat, kind)
      if sim.phase == pkOrders and kind == skExpander:
        decision.orders = expanderOrders(sim, sim.powerOf[seat], cell.tuning)
      case sim.phase
      of pkPress:
        sim.applyPress(seat, decision.broadcast, decision.letters,
          decision.pledges, decision.notes, true)
      of pkOrders:
        sim.applyOrders(seat, decision.orders, decision.notes, true)
      of pkRetreats:
        sim.applyRetreats(seat, decision.retreats, decision.notes, true)
      of pkBuilds:
        sim.applyBuilds(seat, decision.adjustments, decision.notes, true)
      of pkDone:
        discard
  for event in sim.events:
    if event.kind == evOrders:
      cell.illegal += event.illegal.len
  for seat in 0 ..< Seats:
    if kinds[seat] == skExpander:
      cell.centres += sim.centres(seat)
    else:
      cell.hedgehog += sim.centres(seat)
  if not sim.done or sim.reason != "complete":
    cell.complete = false

proc sweep*(seeds: seq[int], years: int): seq[GridCell] =
  ## Every cell of the grid, in a fixed order.
  for penalty in 0 .. 2:
    for supportFrom in 1 .. 3:
      var cell = GridCell(complete: true, tuning: ExpanderTuning(
        springHomePenalty: penalty, supportFromRank: supportFrom))
      for seed in seeds:
        cell.playTable(seed, years)
      result.add(cell)

proc cellLine*(cell: GridCell): string =
  "expander grid: springHomePenalty=" & $cell.tuning.springHomePenalty &
    " supportFromRank=" & $cell.tuning.supportFromRank &
    "  expanders=" & align($cell.centres, 3) &
    "  hedgehogs=" & align($cell.hedgehog, 3) &
    "  illegal=" & $cell.illegal &
    "  complete=" & $cell.complete &
    (if cell.tuning == DefaultExpanderTuning: "   <- shipped" else: "")

when isMainModule:
  echo "four expanders vs three hedgehogs, seeds 1..8, four years"
  for cell in sweep(@[1, 2, 3, 4, 5, 6, 7, 8], 4):
    echo cellLine(cell)
