import std/[json, strutils, unicode, unittest]
import cogplomacy/llm

## The scripted baselines: bounded, always legal, and the load-bearing
## offline fallback. Reply parsing is exercised here too, because a reply
## that fails to parse is answered by these bots.

proc fixtureConfig(years = 4, seed = 0, press = true): GameConfig =
  result = defaultGameConfig()
  result.years = years
  result.seed = seed
  result.press = press
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc playEpisode(config: GameConfig, kinds: seq[ScriptKind]): Sim =
  result = initSim(config)
  let client = newLlmClient(config)
  let prompts = newSeq[string](Seats)
  var guard = 0
  while not result.done and guard < 2000:
    inc guard
    let seats = result.pendingSeats()
    doAssert seats.len > 0, "no pending seats and the episode is not over"
    let decisions = client.decideAll(result, seats, prompts, kinds)
    for index, seat in seats:
      let decision = decisions[index]
      case result.phase
      of pkPress:
        result.applyPress(seat, decision.broadcast, decision.letters,
          decision.pledges, decision.notes, true)
      of pkOrders:
        result.applyOrders(seat, decision.orders, decision.notes, true)
      of pkRetreats:
        result.applyRetreats(seat, decision.retreats, decision.notes, true)
      of pkBuilds:
        result.applyBuilds(seat, decision.adjustments, decision.notes, true)
      of pkDone:
        discard

proc allOf(kind: ScriptKind): seq[ScriptKind] =
  for index in 0 ..< Seats:
    result.add(kind)

proc auditLegality(sim: Sim) =
  ## Every submitted order parses and is legal, every unit is ordered
  ## exactly once, and no power ever stands itself off.
  var unitsAt: seq[int]
  for event in sim.events:
    case event.kind
    of evPhase:
      unitsAt = @[]
      for unit in event.units:
        unitsAt.add(unit.province)
    of evOrders:
      check event.illegal.len == 0
      var ordered: seq[string]
      var destinations: seq[string]
      for order in event.orders:
        let parts = strutils.splitWhitespace(order)
        check parts.len >= 2
        check parts[1] notin ordered
        ordered.add(parts[1])
        if parts.len >= 4 and parts[2] == "-":
          ## No power may stand itself off: one destination per power.
          check parts[3] notin destinations
          destinations.add(parts[3])
    of evRetreat:
      for move in event.moves:
        check move.to >= -1
    of evBuild:
      for action in event.adjustments:
        check action.action in ["build", "disband"]
        if action.action == "build":
          check Provinces[action.unit.province].isCentre
          check Provinces[action.unit.province].homePower == event.power
    else:
      discard

proc auditCaps(sim: Sim) =
  for event in sim.events:
    check event.letters.len <= MaxLetters
    check event.pledges.len <= MaxPledges
    check event.orders.len <= MaxOrdersPerReply
    check event.moves.len <= MaxRetreatsPerReply
    check event.adjustments.len <= MaxAdjustmentsPerReply

suite "expander":
  test "seven expanders play legal, complete episodes for seeds 1..8":
    for seed in 1 .. 8:
      let sim = playEpisode(fixtureConfig(years = 4, seed = seed),
        allOf(skExpander))
      check sim.done
      check sim.reason == "complete"
      auditLegality(sim)
      auditCaps(sim)

  test "every unit is ordered exactly once, every phase":
    let sim = playEpisode(fixtureConfig(years = 3, seed = 3),
      allOf(skExpander))
    var boardUnits: seq[Unit]
    for event in sim.events:
      if event.kind == evPhase and event.phaseKind == pkOrders:
        boardUnits = event.units
      if event.kind == evOrders:
        var mine = 0
        for unit in boardUnits:
          if unit.power == event.power:
            inc mine
        check event.orders.len == mine

  test "builds and disbands match the delta exactly":
    let sim = playEpisode(fixtureConfig(years = 5, seed = 2),
      allOf(skExpander))
    var counts: seq[int]
    var unitCounts: seq[int]
    for event in sim.events:
      if event.kind == evCentres:
        counts = event.counts
      if event.kind == evPhase and event.phaseKind == pkBuilds:
        unitCounts = newSeq[int](Powers)
        for unit in event.units:
          inc unitCounts[unit.power]
      if event.kind == evBuild and counts.len == Powers and
          unitCounts.len == Powers:
        let delta = counts[event.power] - unitCounts[event.power]
        var builds = 0
        var disbands = 0
        for action in event.adjustments:
          if action.action == "build": inc builds else: inc disbands
        if delta > 0:
          check builds + event.waived == delta
          check disbands == 0
        elif delta < 0:
          check disbands == -delta
          check builds == 0

suite "hedgehog":
  test "seven hedgehogs play legal, complete episodes":
    for seed in [1, 5, 9]:
      let sim = playEpisode(fixtureConfig(years = 4, seed = seed),
        allOf(skHedgehog))
      check sim.done
      check sim.reason == "complete"
      auditLegality(sim)

  test "the wall never grows past its start":
    let sim = playEpisode(fixtureConfig(years = 4, seed = 5),
      allOf(skHedgehog))
    for seat in 0 ..< Seats:
      check sim.centres(seat) <= 4

suite "a mixed table":
  test "four expanders and three hedgehogs still complete":
    var kinds: seq[ScriptKind]
    for index in 0 ..< Seats:
      kinds.add(if index < 4: skExpander else: skHedgehog)
    let sim = playEpisode(fixtureConfig(years = 4, seed = 7), kinds)
    check sim.done
    check sim.reason == "complete"
    auditLegality(sim)
    ## The greedy bot beats the wall.
    var expanderTotal = 0
    var hedgehogTotal = 0
    for seat in 0 ..< Seats:
      if kinds[seat] == skExpander:
        expanderTotal += sim.centres(seat)
      else:
        hedgehogTotal += sim.centres(seat)
    check expanderTotal > hedgehogTotal

suite "offline fallback":
  test "decideAll with no credentials answers every seat without a network":
    let config = fixtureConfig(years = 2)
    var sim = initSim(config)
    let client = newLlmClient(config)
    check client.disabled          # CI has no credentials
    var prompts = newSeq[string](Seats)
    var kinds = newSeq[ScriptKind](Seats)
    let seats = sim.pendingSeats()
    let decisions = client.decideAll(sim, seats, prompts, kinds)
    check decisions.len == Seats
    ## Every one of them is a legal, applyable decision.
    for index, seat in seats:
      sim.applyPress(seat, decisions[index].broadcast,
        decisions[index].letters, decisions[index].pledges,
        decisions[index].notes, true)
    check sim.phase == pkOrders

suite "reply parsing":
  test "PLAYER_SCRIPTED values map to the two baselines":
    check parseScriptKind("expander") == skExpander
    check parseScriptKind("1") == skExpander
    check parseScriptKind(" TRUE ") == skExpander
    check parseScriptKind("hedgehog") == skHedgehog
    check parseScriptKind("turtle") == skHedgehog
    check parseScriptKind("") == skNone
    check parseScriptKind("nonsense") == skNone

  test "fenced and prose-wrapped JSON is extracted":
    let fenced = "```json\n{\"orders\":[\"A PAR - BUR\"]}\n```"
    check extractJsonObject(fenced){"orders"}.len == 1
    let prose = "Here is my move.\n{\"orders\": [\"A PAR - BUR\"]}\nGood luck!"
    check extractJsonObject(prose){"orders"}.len == 1
    expect CogplomacyError:
      discard extractJsonObject("no json at all here")

  test "a missing required key is invalid; bad contents are repaired":
    var sim = initSim(fixtureConfig(years = 1, press = false))
    let seat = sim.pendingSeats()[0]
    expect CogplomacyError:
      discard sim.parseDecision(seat, parseJson("""{"notes":"hi"}"""))
    expect CogplomacyError:
      discard sim.parseDecision(seat, parseJson("""{"orders":"A PAR - BUR"}"""))
    ## An oversize order string survives parsing and becomes a hold later.
    let long = "A PAR - " & "X".repeat(80)
    let decision = sim.parseDecision(seat,
      %*{"orders": [long, "A PAR - BUR"]})
    check decision.orders.len == 2
    check decision.orders[0].runeLen <= MaxOrderLen

  test "an unknown pledge kind or recipient is dropped, not rejected":
    var sim = initSim(fixtureConfig(years = 1))
    let seat = sim.pendingSeats()[0]
    let decision = sim.parseDecision(seat, %*{
      "broadcast": "hello",
      "letters": [{"to": "ATLANTIS", "text": "hi"},
                  {"to": "ITALY", "text": "real"}],
      "pledges": [{"to": "ITALY", "kind": "invade"},
                  {"to": "ITALY", "kind": "peace"},
                  {"to": "ALL", "kind": "keepout", "province": "ZZZ"},
                  {"to": "ALL", "kind": "keepout", "province": "BUR"}]
    })
    check decision.broadcast == "hello"
    check decision.letters.len <= 1
    check decision.pledges.len == 2
    check decision.pledges[0].kind == plPeace
    check decision.pledges[1].kind == plKeepOut

  test "an over-long array is truncated from the end":
    var sim = initSim(fixtureConfig(years = 1, press = false))
    let seat = sim.pendingSeats()[0]
    var many = newJArray()
    for index in 0 ..< 80:
      many.add(%"A PAR - BUR")
    let decision = sim.parseDecision(seat, %*{"orders": many})
    check decision.orders.len == MaxOrdersPerReply
