import std/[json, sets, strutils, unicode, unittest]
import cogplomacy/llm

## The episode: phase sequencing, ownership, adjustments, scoring, the press
## caps, the two name spaces, and the replay round-trip.

proc fixtureConfig(years = 4, seed = 0, press = true): GameConfig =
  result = defaultGameConfig()
  result.years = years
  result.seed = seed
  result.press = press
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc stepPhase(sim: var Sim, kind = skExpander) =
  ## Answer every pending seat of the live phase from the baseline.
  let seats = sim.pendingSeats()
  for seat in seats:
    let decision = scriptedDecision(sim, seat, kind)
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

proc playOut(sim: var Sim, kind = skExpander) =
  var guard = 0
  while not sim.done and guard < 2000:
    inc guard
    if sim.pendingSeats().len == 0:
      raise newException(CogplomacyError, "no pending seats and not done")
    sim.stepPhase(kind)

proc dislodgementEpisode(): Sim =
  ## An episode with a forced dislodgement, so the retreat events exist:
  ## Austria takes Venice with a supported attack in Spring 1901 while Italy
  ## sits still. Every other seat plays the baseline.
  var sim = initSim(fixtureConfig(years = 1, press = false, seed = 3))
  sim.board.units.add(Unit(power: 0, kind: ukArmy,
    province: provinceByCode("TYR"), coast: ""))
  var guard = 0
  while not sim.done and guard < 200:
    inc guard
    let opening = sim.phase == pkOrders and sim.year == StartYear and
      sim.season == seSpring
    for seat in sim.pendingSeats():
      let power = sim.powerOf[seat]
      if opening and power == 0:
        sim.applyOrders(seat, @["F TRI - VEN", "A TYR S F TRI - VEN",
          "A VIE H", "A BUD H"], "", true)
      elif opening and power == 4:
        sim.applyOrders(seat, @["A VEN H", "A ROM H", "F NAP H"], "", true)
      else:
        let decision = scriptedDecision(sim, seat, skExpander)
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
  sim

proc ownerTable(sim: Sim): seq[int] =
  for slot in 0 ..< NumCentres:
    result.add(sim.board.owner[slot])

suite "setup":
  test "seat to power is a seeded permutation":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      var seen = initHashSet[int]()
      for seat in 0 ..< Seats:
        seen.incl(sim.powerOf[seat])
        check sim.seatOf[sim.powerOf[seat]] == seat
      check seen.len == Powers
    ## Different seeds really do move Italy around.
    var italies = initHashSet[int]()
    for seed in 0 ..< 20:
      italies.incl(initSim(fixtureConfig(seed = seed)).seatOf[4])
    check italies.len > 1

  test "exactly seven players are required":
    var config = fixtureConfig()
    config.players.setLen(6)
    expect CogplomacyError:
      discard initSim(config)

  test "the opening board is the 1901 position":
    let sim = initSim(fixtureConfig())
    check sim.board.units.len == 22
    var owned = 0
    for slot in 0 ..< NumCentres:
      if sim.board.owner[slot] >= 0:
        inc owned
    check owned == 22
    check sim.year == 1901
    check sim.season == seSpring
    check sim.phase == pkPress

  test "the same seed gives the same permutation, aliases and event log":
    var a = initSim(fixtureConfig(years = 2, seed = 11))
    var b = initSim(fixtureConfig(years = 2, seed = 11))
    check a.names == b.names
    check a.powerOf == b.powerOf
    a.playOut()
    b.playOut()
    check a.events.len == b.events.len
    for index in 0 ..< a.events.len:
      check $eventToJson(a.events[index]) == $eventToJson(b.events[index])

suite "phase sequencing":
  test "press then orders then retreats, twice, then builds":
    var sim = initSim(fixtureConfig(years = 1))
    var order: seq[string]
    var guard = 0
    while not sim.done and guard < 200:
      inc guard
      order.add($sim.season & "/" & $sim.phase)
      sim.stepPhase()
    ## Spring press, spring orders, (retreats), fall press, fall orders,
    ## (retreats), (winter builds) — optional phases only when they apply.
    check order[0] == "spring/press"
    check order[1] == "spring/orders"
    check "fall/press" in order
    check "fall/orders" in order
    for label in order:
      check label != "winter/press"
      check label != "spring/builds"

  test "no press phases at all when press is off":
    var sim = initSim(fixtureConfig(years = 1, press = false))
    check sim.phase == pkOrders
    var guard = 0
    while not sim.done and guard < 200:
      inc guard
      check sim.phase != pkPress
      sim.stepPhase()

  test "retreats and builds are skipped when nothing is owed":
    var sim = initSim(fixtureConfig(years = 1))
    sim.stepPhase()             # spring press
    sim.stepPhase()             # spring orders -> resolves
    ## The expander never dislodges anybody on the first turn.
    check sim.phase == pkPress
    check sim.season == seFall

suite "order submission":
  test "an illegal order holds its unit and a later order for it is dropped":
    var sim = initSim(fixtureConfig(years = 1, press = false))
    let power = 2                       # France: A PAR is on the board
    let seat = sim.seatOf[power]
    sim.applyOrders(seat, @["A PAR - ENG", "A PAR - BUR"], "", true)
    var ordersEvent: GameEvent
    for event in sim.events:
      if event.kind == evOrders and event.power == power:
        ordersEvent = event
    check ordersEvent.illegal.len == 1
    check ordersEvent.illegal[0].why == "wrongunit"
    ## Step 2 holds the unit, step 1 drops the second order for it.
    check "A PAR H" in ordersEvent.orders
    check "A PAR - BUR" notin ordersEvent.orders

suite "ownership":
  test "ownership changes only after Fall retreats":
    var sim = initSim(fixtureConfig(years = 1))
    let opening = sim.ownerTable()
    sim.stepPhase()             # spring press
    sim.stepPhase()             # spring orders
    check sim.ownerTable() == opening
    while not sim.done and sim.season != seWinter and
        not (sim.season == seFall and sim.phase == pkOrders):
      sim.stepPhase()
    check sim.ownerTable() == opening
    sim.stepPhase()             # fall orders -> ownership updates
    check sim.ownerTable() != opening

  test "a centres event is emitted once per year":
    var sim = initSim(fixtureConfig(years = 3))
    sim.playOut()
    var centres = 0
    for event in sim.events:
      if event.kind == evCentres:
        inc centres
        check event.owners.len == NumCentres
        check event.counts.len == Powers
    check centres == 3

suite "adjustments":
  test "build entitlement equals centres minus units":
    var sim = initSim(fixtureConfig(years = 1))
    sim.playOut()
    for event in sim.events:
      if event.kind != evBuild:
        continue
      var builds = 0
      for action in event.adjustments:
        if action.action == "build":
          inc builds
          ## Only in a vacant home centre the power still owns.
          check Provinces[action.unit.province].homePower == event.power
          check Provinces[action.unit.province].isCentre
      check builds + event.waived >= 0

  test "civil disorder disbands the unit furthest from home":
    var sim = initSim(fixtureConfig(years = 1, seed = 4))
    let power = 5                       # Russia
    let seat = sim.seatOf[power]
    sim.board.units = @[
      Unit(power: power, kind: ukArmy, province: provinceByCode("MOS")),
      Unit(power: power, kind: ukArmy, province: provinceByCode("POR"))
    ]
    for slot in 0 ..< NumCentres:
      sim.board.owner[slot] = -1
    sim.board.owner[CentreIndex[provinceByCode("MOS")]] = power
    sim.season = seWinter
    sim.phase = pkBuilds
    sim.pending = @[seat]
    check sim.buildDelta(power) == -1
    sim.applyBuilds(seat, @[], "", true)
    check sim.board.units.len == 1
    check sim.board.units[0].province == provinceByCode("MOS")

  test "an explicit disband is honoured and the count is exact":
    var sim = initSim(fixtureConfig(years = 1, seed = 4))
    let power = 5
    let seat = sim.seatOf[power]
    sim.board.units = @[
      Unit(power: power, kind: ukArmy, province: provinceByCode("MOS")),
      Unit(power: power, kind: ukArmy, province: provinceByCode("WAR")),
      Unit(power: power, kind: ukArmy, province: provinceByCode("UKR"))
    ]
    for slot in 0 ..< NumCentres:
      sim.board.owner[slot] = -1
    sim.board.owner[CentreIndex[provinceByCode("MOS")]] = power
    sim.season = seWinter
    sim.phase = pkBuilds
    sim.pending = @[seat]
    sim.applyBuilds(seat, @["DISBAND A MOS", "DISBAND A WAR"], "", true)
    check sim.board.units.len == 1
    check sim.board.units[0].province == provinceByCode("UKR")

suite "end conditions":
  test "eighteen centres is a solo":
    var sim = initSim(fixtureConfig(years = 6, seed = 2))
    let power = 0
    let seat = sim.seatOf[power]
    for slot in 0 ..< NumCentres:
      sim.board.owner[slot] = if slot < 18: power else: -1
    sim.board.units = @[Unit(power: power, kind: ukArmy,
      province: provinceByCode("VIE"))]
    sim.season = seWinter
    sim.phase = pkBuilds
    sim.pending = @[seat]
    sim.applyBuilds(seat, @[], "", true)
    check sim.done
    check sim.reason == "solo"
    check sim.soloist == power
    check sim.score(seat) == 1.0
    for other in 0 ..< Seats:
      if other != seat:
        check sim.score(other) == 0.0

  test "the last power owning any centre solos":
    var sim = initSim(fixtureConfig(years = 6, seed = 2))
    let power = 3
    let seat = sim.seatOf[power]
    for slot in 0 ..< NumCentres:
      sim.board.owner[slot] = if slot < 3: power else: -1
    sim.board.units = @[Unit(power: power, kind: ukArmy,
      province: provinceByCode("BER"))]
    sim.season = seWinter
    sim.phase = pkBuilds
    sim.pending = @[seat]
    sim.applyBuilds(seat, @[], "", true)
    check sim.done
    check sim.reason == "solo"
    check sim.soloist == power

  test "playing the years out is complete":
    var sim = initSim(fixtureConfig(years = 2))
    sim.playOut()
    check sim.done
    check sim.reason == "complete"
    check sim.yearsPlayed == 2

  test "endEarly is a deadline scored on the standing ownership":
    var sim = initSim(fixtureConfig(years = 4))
    sim.stepPhase()
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    check sim.soloist < 0
    for seat in 0 ..< Seats:
      let expected = sim.centres(seat).float / TotalCentres.float
      check abs(sim.score(seat) - expected) < 1e-9

  test "only three reasons are ever written":
    for years in [1, 2]:
      var sim = initSim(fixtureConfig(years = years))
      sim.playOut()
      check sim.resultsJson()["reason"].getStr() in
        ["solo", "complete", "deadline"]
    var running = initSim(fixtureConfig(years = 2))
    check running.resultsJson()["reason"].getStr() == ""

suite "scoring":
  test "results carry the shape the schema declares":
    var sim = initSim(fixtureConfig(years = 2))
    sim.playOut()
    let results = sim.resultsJson()
    for key in ["names", "powers", "scores", "centres", "units"]:
      check results[key].len == Seats
    check results["years"].getInt() == 2
    check results["maxYears"].getInt() == 2
    check results["soloist"].getStr() == ""
    var total = 0.0
    for value in results["scores"]:
      check value.getFloat() >= 0.0
      check value.getFloat() <= 1.0
      total += value.getFloat()
    check total <= 1.0 + 1e-9

  test "results attribute by POLICY name, never by alias":
    var sim = initSim(fixtureConfig(years = 1))
    sim.playOut()
    let names = sim.resultsJson()["names"]
    for seat in 0 ..< Seats:
      check names[seat].getStr() == "P" & $(seat + 1)
      check names[seat].getStr() != sim.names[seat]

suite "press":
  test "broadcast, letters and notes truncate on rune boundaries":
    var sim = initSim(fixtureConfig(years = 1))
    let seat = sim.pendingSeats()[0]
    let emoji = "🕊️".repeat(600)
    sim.applyPress(seat, emoji,
      @[Letter(toPower: (sim.powerOf[seat] + 1) mod Powers, text: emoji)],
      @[], emoji, true)
    var pressEvent: GameEvent
    for event in sim.events:
      if event.kind == evPress:
        pressEvent = event
    check pressEvent.broadcast.runeLen <= MaxBroadcastLen
    check validateUtf8(pressEvent.broadcast) == -1
    check pressEvent.broadcast.endsWith("…")
    check pressEvent.letters[^1].text.runeLen <= MaxLetterLen
    check validateUtf8(pressEvent.letters[^1].text) == -1
    check pressEvent.text.runeLen <= MaxNotesLen
    check validateUtf8(pressEvent.text) == -1
    check validateUtf8($sim.tableStateJson()) == -1

  test "a seventh letter and a fifth pledge are dropped":
    var sim = initSim(fixtureConfig(years = 1))
    let seat = sim.pendingSeats()[0]
    let power = sim.powerOf[seat]
    var letters: seq[Letter]
    var pledges: seq[Pledge]
    for other in 0 ..< Powers:
      if other != power:
        letters.add(Letter(toPower: other, text: "hello " & $other))
      pledges.add(Pledge(toPower: other, kind: plPeace, province: -1))
    ## Six other powers is already the cap; add a duplicate and a seventh.
    letters.add(Letter(toPower: (power + 1) mod Powers, text: "again"))
    sim.applyPress(seat, "", letters, pledges, "", true)
    var pressEvent: GameEvent
    for event in sim.events:
      if event.kind == evPress:
        pressEvent = event
    check pressEvent.letters.len == MaxLetters
    check pressEvent.pledges.len == MaxPledges

  test "a letter to an unknown power is dropped, one to ALL is published":
    var sim = initSim(fixtureConfig(years = 1))
    let seat = sim.pendingSeats()[0]
    sim.applyPress(seat, "", @[Letter(toPower: 99, text: "who?"),
      Letter(toPower: -1, text: "everybody hears this")], @[], "", true)
    var pressEvent: GameEvent
    for event in sim.events:
      if event.kind == evPress:
        pressEvent = event
    check pressEvent.letters.len == 1
    check pressEvent.letters[0].toPower < 0
    for power in 0 ..< Powers:
      var seen = false
      for letter in sim.inboxOf(power, true):
        if letter.text == "everybody hears this":
          seen = true
      check seen

  test "a seat reads only what is addressed to it":
    var sim = initSim(fixtureConfig(years = 1))
    let seats = sim.pendingSeats()
    let author = seats[0]
    let power = sim.powerOf[author]
    let target = (power + 1) mod Powers
    let other = (power + 2) mod Powers
    sim.applyPress(author, "everyone hears this",
      @[Letter(toPower: target, text: "only you hear this")], @[], "", true)
    var targetSees = false
    for letter in sim.inboxOf(target, true):
      if letter.text == "only you hear this":
        targetSees = true
    check targetSees
    for letter in sim.inboxOf(other, true):
      check letter.text != "only you hear this"
    ## Spectators see everything, immediately.
    check "only you hear this" in $sim.tableStateJson()

suite "stabs":
  test "a stab is stamped for its turn and comes down at the next press":
    var sim = initSim(fixtureConfig(years = 1, seed = 3))
    let france = sim.seatOf[2]
    for seat in sim.pendingSeats():
      if seat == france:
        sim.applyPress(seat, "", @[],
          @[Pledge(toPower: -1, kind: plKeepOut,
            province: provinceByCode("BUR"))], "", true)
      else:
        sim.applyPress(seat, "", @[], @[], "", true)
    check sim.phase == pkOrders
    for seat in sim.pendingSeats():
      if seat == france:
        sim.applyOrders(seat, @["A PAR - BUR", "A MAR H", "F BRE H"], "",
          true)
      else:
        let decision = scriptedDecision(sim, seat, skExpander)
        sim.applyOrders(seat, decision.orders, decision.notes, true)
    check sim.tableStateJson()["stabs"].len == 1
    ## The next press phase is a new turn: the stamp comes down.
    check sim.phase == pkPress
    sim.applyPress(sim.pendingSeats()[0], "", @[], @[], "", true)
    check sim.tableStateJson()["stabs"].len == 0

suite "the two name spaces":
  test "policy names never appear in any prompt":
    var config = fixtureConfig(years = 2)
    for index in 0 ..< Seats:
      config.players[index].name = "ZZPOLICY" & $index & "ZZ"
    var sim = initSim(config)
    var guard = 0
    while not sim.done and guard < 60:
      inc guard
      for seat in sim.pendingSeats():
        let system = systemPrompt(sim, seat)
        let user = sim.userPrompt(seat, "an operator prompt")
        for index in 0 ..< Seats:
          check config.players[index].name notin system
          check config.players[index].name notin user
          check sim.names[index] notin system
          check sim.names[index] notin user
      sim.stepPhase()

  test "the replay carries both name spaces":
    var sim = initSim(fixtureConfig(years = 1))
    sim.playOut()
    let frame = sim.tableStateJson()
    for seat in 0 ..< Seats:
      check frame["seats"][seat]["name"].getStr() == sim.names[seat]
      check frame["seats"][seat]["power"].getStr() ==
        PowerNames[sim.powerOf[seat]]

suite "events and replay":
  test "every event kind round-trips through JSON":
    var plain = initSim(fixtureConfig(years = 3, seed = 5))
    plain.playOut()
    var kinds = initHashSet[EventKind]()
    for sim in [plain, dislodgementEpisode()]:
      for event in sim.events:
        kinds.incl(event.kind)
        let round = eventFromJson(eventToJson(event))
        check $eventToJson(round) == $eventToJson(event)
    ## All nine kinds, retreats and builds included.
    for kind in EventKind:
      check kind in kinds

  test "replayMatch re-derives the whole timeline":
    var sim = initSim(fixtureConfig(years = 2, seed = 6))
    sim.playOut()
    let frames = replayMatch(sim.config, sim.events)
    check frames.len == sim.events.len + 1
    check $frames[^1].tableStateJson() == $sim.tableStateJson()
    check frames[^1].reason == sim.reason

  test "replayMatch rejects a recorded board the rules do not re-derive":
    var sim = initSim(fixtureConfig(years = 1, seed = 6))
    sim.playOut()
    ## A phase event whose recorded board has lost a unit.
    var tampered = sim.events
    for index in 0 ..< tampered.len:
      if tampered[index].kind == evPhase and tampered[index].units.len > 0:
        tampered[index].units.delete(0)
        break
    expect CogplomacyError:
      discard replayMatch(sim.config, tampered)
    ## An adjudication whose recorded outcome was edited.
    var flipped = sim.events
    for index in 0 ..< flipped.len:
      if flipped[index].kind == evAdjudicate and
          flipped[index].results.len > 0:
        flipped[index].results[0].outcome =
          if flipped[index].results[0].outcome == orSuccess: orBounce
          else: orSuccess
        break
    expect CogplomacyError:
      discard replayMatch(sim.config, flipped)

  test "a deadline stop replays as a deadline":
    var sim = initSim(fixtureConfig(years = 4, seed = 8))
    sim.stepPhase()
    sim.stepPhase()
    sim.endEarly()
    let frames = replayMatch(sim.config, sim.events)
    check frames[^1].reason == "deadline"
    check frames.len == sim.events.len + 1
