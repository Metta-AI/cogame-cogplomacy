## Pure game rules for Cogplomacy. No IO, no networking, no LLM — the game
## server, the tests and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded seat→power permutation and the
## cog aliases, the board, the press of the live phase, each power's orders,
## every power's private notes, and the append-only event log. The only draw
## from the seed is the permutation and the aliases, both fixed before
## Spring 1901 — there is no other randomness anywhere in the game.

import std/[algorithm, json, random, strutils, unicode],
  mapdata, types, orders, adjudicate

export mapdata, types, orders, adjudicate

const
  Seats* = 7
  Powers* = 7
  TotalCentres* = 34
  SoloCentres* = 18
  MinYears* = 1
  MaxYears* = 12
  StartYear* = 1901
  HistoryYears* = 2
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 60_000
  MaxBroadcastLen* = 400
  MaxLetterLen* = 400
  MaxLetters* = 6
  MaxPledges* = 4
  MaxNotesLen* = 800
  MaxOrderLen* = 32
  MaxOrdersPerReply* = 34
  MaxRetreatsPerReply* = 12
  MaxAdjustmentsPerReply* = 10
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  TurnRecord* = object
    year*: int
    season*: Season
    lines*: seq[string]   ## one readable line per order, with its result

  Sim* = object
    config*: GameConfig
    names*: seq[string]              ## anonymous cog aliases per seat
    powerOf*: array[Seats, int]      ## seat -> power index
    seatOf*: array[Powers, int]      ## power index -> seat
    board*: Board
    year*: int
    season*: Season
    phase*: PhaseKind
    pending*: seq[int]               ## seats the phase is still waiting on
    press*: seq[Letter]              ## this press phase's letters
    pressLast*: seq[Letter]
    pledges*: seq[Pledge]            ## this press phase's pledges
    pledgesLast*: seq[Pledge]
    broadcasts*: array[Powers, string]
    orders*: array[Powers, seq[Order]]
    lastAdjudication*: Adjudication
    dislodged*: seq[Dislodgement]
    standoffs*: seq[int]
    retreatChoices*: seq[RetreatMove]
    stabbed*: array[Powers, bool]
    history*: seq[TurnRecord]
    centresHistory*: seq[seq[int]]
    notes*: seq[string]
    eliminated*: array[Powers, bool]
    yearsPlayed*: int
    done*: bool
    reason*: string                  ## "solo" | "complete" | "deadline"
    soloist*: int                    ## power index, or -1
    events*: seq[GameEvent]

# ---- Text hygiene -----------------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. A byte
  ## slice through a multi-byte character would leave invalid UTF-8 in the
  ## replay and break its JSON.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc oneLine*(text: string): string =
  text.replace("\n", " ").replace("\r", " ")

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the year count into the episode's limits. Idempotent: a config
  ## that already carries the cap (a replay being re-read) is untouched.
  result = config
  if result.sampled:
    return
  result.years = max(min(config.years, MaxYears), MinYears)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.years * 7, 1))
  result.sampled = true

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, year: StartYear, season: seSpring, phaseKind: pkPress,
    seat: -1, power: -1, soloist: -1, waived: 0)

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

# ---- Queries ----------------------------------------------------------------

proc powerName*(sim: Sim, seat: int): string =
  PowerNames[sim.powerOf[seat]]

proc unitsOf*(sim: Sim, power: int): seq[Unit] =
  for unit in sim.board.units:
    if unit.power == power:
      result.add(unit)

proc centresOfPower*(sim: Sim, power: int): int =
  for slot in 0 ..< NumCentres:
    if sim.board.owner[slot] == power:
      inc result

proc centres*(sim: Sim, seat: int): int =
  sim.centresOfPower(sim.powerOf[seat])

proc unitCount*(sim: Sim, power: int): int =
  for unit in sim.board.units:
    if unit.power == power:
      inc result

proc score*(sim: Sim, seat: int): float =
  ## Solo: 1.0 for the soloist, 0.0 for everyone else. Otherwise the share
  ## of the 34 centres. The constant denominator is what makes a neutral
  ## worth the same to every power and kills the hand-the-win endgame.
  let power = sim.powerOf[seat]
  if sim.soloist >= 0:
    return if power == sim.soloist: 1.0 else: 0.0
  sim.centresOfPower(power).float / TotalCentres.float

proc pendingSeats*(sim: Sim): seq[int] =
  if sim.done:
    return
  sim.pending

proc livePowers(sim: Sim): seq[int] =
  for power in 0 ..< Powers:
    if not sim.eliminated[power]:
      result.add(power)

proc counts(sim: Sim): seq[int] =
  for power in 0 ..< Powers:
    result.add(sim.centresOfPower(power))

# ---- Phase machine ----------------------------------------------------------

proc phaseEvent(sim: var Sim) =
  var event = blankEvent(evPhase)
  event.year = sim.year
  event.season = sim.season
  event.phaseKind = sim.phase
  event.units = sim.board.units
  for slot in 0 ..< NumCentres:
    event.owners.add(sim.board.owner[slot])
  event.counts = sim.counts()
  sim.addEvent(event)

proc openPress(sim: var Sim) =
  sim.pressLast = sim.press
  sim.pledgesLast = sim.pledges
  sim.press = @[]
  sim.pledges = @[]
  for power in 0 ..< Powers:
    sim.broadcasts[power] = ""
    sim.stabbed[power] = false
  sim.phase = pkPress
  sim.pending = @[]
  for power in sim.livePowers():
    sim.pending.add(sim.seatOf[power])
  sim.pending.sort(system.cmp[int])
  sim.phaseEvent()

proc openOrders(sim: var Sim) =
  sim.phase = pkOrders
  for power in 0 ..< Powers:
    sim.orders[power] = @[]
    sim.stabbed[power] = false
  sim.pending = @[]
  for power in sim.livePowers():
    sim.pending.add(sim.seatOf[power])
  sim.pending.sort(system.cmp[int])
  sim.phaseEvent()

proc openRetreats(sim: var Sim) =
  sim.phase = pkRetreats
  sim.retreatChoices = @[]
  sim.pending = @[]
  for item in sim.dislodged:
    let seat = sim.seatOf[item.unit.power]
    if seat notin sim.pending:
      sim.pending.add(seat)
  sim.pending.sort(system.cmp[int])
  sim.phaseEvent()

proc buildDelta*(sim: Sim, power: int): int =
  sim.centresOfPower(power) - sim.unitCount(power)

proc openBuilds(sim: var Sim) =
  sim.season = seWinter
  sim.phase = pkBuilds
  sim.pending = @[]
  for power in sim.livePowers():
    if sim.buildDelta(power) != 0:
      sim.pending.add(sim.seatOf[power])
  sim.pending.sort(system.cmp[int])
  sim.phaseEvent()

proc settle(sim: var Sim, reason: string) =
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  sim.phase = pkDone
  sim.pending = @[]
  var event = blankEvent(evEnd)
  event.year = sim.year
  event.season = sim.season
  event.text = reason
  event.counts = sim.counts()
  event.soloist = sim.soloist
  sim.addEvent(event)

proc endEarly*(sim: var Sim) =
  ## Stop now, between phases. The hosted platform kills an episode that
  ## outlives its timeout and keeps NOTHING, so a short honest episode
  ## always beats a long one that never lands.
  sim.settle("deadline")

proc checkSolo(sim: var Sim): bool =
  var owners = 0
  var lastOwner = -1
  for power in 0 ..< Powers:
    let held = sim.centresOfPower(power)
    if held >= SoloCentres:
      sim.soloist = power
      sim.settle("solo")
      return true
    if held > 0:
      inc owners
      lastOwner = power
  if owners == 1:
    sim.soloist = lastOwner
    sim.settle("solo")
    return true
  false

proc updateEliminations(sim: var Sim) =
  for power in 0 ..< Powers:
    if not sim.eliminated[power] and sim.unitCount(power) == 0 and
        sim.centresOfPower(power) == 0:
      sim.eliminated[power] = true

proc startYear(sim: var Sim) =
  sim.season = seSpring
  if sim.config.press:
    sim.openPress()
  else:
    sim.openOrders()

proc endOfYear(sim: var Sim) =
  inc sim.yearsPlayed
  sim.centresHistory.add(sim.counts())
  sim.updateEliminations()
  if sim.checkSolo():
    return
  if sim.yearsPlayed >= sim.config.years:
    sim.settle("complete")
    return
  inc sim.year
  sim.startYear()

proc updateCentres(sim: var Sim) =
  ## Step 10, Fall only: whoever occupies a centre owns it.
  let before = sim.counts()
  for unit in sim.board.units:
    let slot = CentreIndex[unit.province]
    if slot >= 0:
      sim.board.owner[slot] = unit.power
  let after = sim.counts()
  var event = blankEvent(evCentres)
  event.year = sim.year
  event.season = seFall
  for slot in 0 ..< NumCentres:
    event.owners.add(sim.board.owner[slot])
  event.counts = after
  for power in 0 ..< Powers:
    event.gained.add(max(0, after[power] - before[power]))
    event.lost.add(max(0, before[power] - after[power]))
  sim.addEvent(event)

proc afterMovement(sim: var Sim) =
  if sim.season == seSpring:
    sim.season = seFall
    if sim.config.press:
      sim.openPress()
    else:
      sim.openOrders()
    return
  sim.updateCentres()
  if sim.checkSolo():
    return
  sim.updateEliminations()
  var anyAdjustment = false
  for power in sim.livePowers():
    if sim.buildDelta(power) != 0:
      anyAdjustment = true
  if anyAdjustment:
    sim.openBuilds()
  else:
    sim.endOfYear()

# ---- Setup ------------------------------------------------------------------

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(CogplomacyError,
      "cogplomacy needs exactly " & $Seats & " players")
  if config.years < MinYears:
    raise newException(CogplomacyError,
      "years must be at least " & $MinYears)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides: the seat→power permutation.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  var powers = @[0, 1, 2, 3, 4, 5, 6]
  rng.shuffle(powers)
  for seat in 0 ..< Seats:
    result.powerOf[seat] = powers[seat]
    result.seatOf[powers[seat]] = seat
  result.board = startBoard()
  result.notes = newSeq[string](Seats)
  result.year = StartYear
  result.season = seSpring
  result.soloist = -1
  var start = blankEvent(evStart)
  start.year = StartYear
  start.units = result.board.units
  for slot in 0 ..< NumCentres:
    start.owners.add(result.board.owner[slot])
  for seat in 0 ..< Seats:
    start.powers.add(result.powerOf[seat])
  start.counts = result.counts()
  result.addEvent(start)
  result.startYear()

# ---- Press ------------------------------------------------------------------

proc inboxOf*(sim: Sim, power: int, current: bool): seq[Letter] =
  ## Every letter this power may read: the public broadcasts plus the
  ## private letters addressed to it. A seat never learns that France wrote
  ## to Russia.
  let source = if current: sim.press else: sim.pressLast
  for letter in source:
    if letter.toPower < 0 or letter.toPower == power:
      result.add(letter)

proc pledgesFor*(sim: Sim, power: int, current: bool): seq[Pledge] =
  let source = if current: sim.pledges else: sim.pledgesLast
  for pledge in source:
    if pledge.toPower < 0 or pledge.toPower == power or
        pledge.fromPower == power:
      result.add(pledge)

proc resolvePress(sim: var Sim) =
  sim.openOrders()

proc applyPress*(sim: var Sim, seat: int, broadcast: string,
    letters: seq[Letter], pledges: seq[Pledge], notes: string,
    scripted: bool) =
  ## `seat` writes its press for this movement phase. Over-cap content is
  ## truncated or dropped, never rejected.
  if sim.done:
    raise newException(CogplomacyError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(CogplomacyError, "bad seat: " & $seat)
  if sim.phase != pkPress or seat notin sim.pending:
    raise newException(CogplomacyError,
      "seat " & $seat & " is not writing press now")
  let power = sim.powerOf[seat]
  let text = cleanText(oneLine(broadcast), MaxBroadcastLen)
  sim.broadcasts[power] = text
  var kept: seq[Letter]
  if text.len > 0:
    kept.add(Letter(fromPower: power, toPower: -1, text: text))
  var seenRecipients: seq[int]
  var privateCount = 0
  for letter in letters:
    if privateCount >= MaxLetters:
      break
    if letter.toPower >= Powers or letter.toPower == power:
      continue
    ## A letter addressed to ALL (`toPower < 0`) is published to everybody,
    ## like the broadcast; a second letter to the same power is dropped.
    let to = if letter.toPower < 0: -1 else: letter.toPower
    if to >= 0 and to in seenRecipients:
      continue
    let body = cleanText(oneLine(letter.text), MaxLetterLen)
    if body.len == 0:
      continue
    if to < 0 and body == text:
      continue     ## the broadcast is already published; never twice
    if to >= 0:
      seenRecipients.add(to)
    inc privateCount
    kept.add(Letter(fromPower: power, toPower: to, text: body))
  var keptPledges: seq[Pledge]
  for pledge in pledges:
    if keptPledges.len >= MaxPledges:
      break
    if pledge.toPower >= Powers:
      continue
    if pledge.kind == plKeepOut and
        (pledge.province < 0 or pledge.province >= NumProvinces):
      continue
    if pledge.kind != plKeepOut and pledge.toPower == power:
      continue
    keptPledges.add(Pledge(fromPower: power, toPower: pledge.toPower,
      kind: pledge.kind,
      province: (if pledge.kind == plKeepOut: pledge.province else: -1)))
  for letter in kept:
    sim.press.add(letter)
  for pledge in keptPledges:
    sim.pledges.add(pledge)
  if notes.len > 0:
    sim.notes[seat] = cleanText(notes, MaxNotesLen)

  var event = blankEvent(evPress)
  event.year = sim.year
  event.season = sim.season
  event.phaseKind = pkPress
  event.seat = seat
  event.power = power
  event.broadcast = text
  event.letters = kept
  event.pledges = keptPledges
  event.scripted = scripted
  event.text = sim.notes[seat]
  sim.addEvent(event)

  sim.pending.delete(sim.pending.find(seat))
  if sim.pending.len == 0:
    sim.resolvePress()

# ---- Orders -----------------------------------------------------------------

proc outcomeWord(outcome: Outcome): string =
  case outcome
  of orSuccess: "succeeds"
  of orBounce: "bounces"
  of orVoid: "is void"
  of orNoConvoy: "has no convoy"
  of orDislodged: "is dislodged"
  of orCut: "is cut"
  of orIllegal: "is illegal"

proc breaksPledge(sim: Sim, pledge: Pledge, order: Order): bool =
  ## Nothing is binding — a pledge exists only so the stab is machine
  ## detectable and therefore drawable.
  case pledge.kind
  of plPeace:
    var targets: seq[int]
    if pledge.toPower < 0:
      for power in 0 ..< Powers:
        if power != pledge.fromPower:
          targets.add(power)
    else:
      targets.add(pledge.toPower)
    var province = -1
    if order.kind == okMove:
      province = order.target
    elif order.kind == okSupportMove:
      province = order.auxTo
    if province < 0:
      return false
    for target in targets:
      let seat = sim.board.unitAt(province)
      if seat >= 0 and sim.board.units[seat].power == target:
        return true
      if sim.board.ownerOf(province) == target:
        return true
    false
  of plKeepOut:
    (order.kind == okMove and order.target == pledge.province) or
      (order.kind == okSupportMove and order.auxTo == pledge.province)
  of plSupport:
    false   ## handled as an absence, below

proc detectStabs(sim: Sim): seq[StabRecord] =
  for pledge in sim.pledges:
    let power = pledge.fromPower
    let seat = sim.seatOf[power]
    if pledge.kind == plSupport:
      var supported = false
      for order in sim.orders[power]:
        if order.kind notin {okSupportHold, okSupportMove}:
          continue
        let helped = sim.board.unitAt(order.auxFrom)
        if helped >= 0 and (pledge.toPower < 0 or
            sim.board.units[helped].power == pledge.toPower):
          supported = true
      if not supported:
        result.add(StabRecord(seat: seat, power: power,
          pledgeTo: pledge.toPower, kind: pledge.kind, province: -1,
          order: ""))
      continue
    for order in sim.orders[power]:
      if sim.breaksPledge(pledge, order):
        result.add(StabRecord(seat: seat, power: power,
          pledgeTo: pledge.toPower, kind: pledge.kind,
          province: pledge.province, order: formatOrder(order)))
        break

proc recordHistory(sim: var Sim, adj: Adjudication) =
  var record = TurnRecord(year: sim.year, season: sim.season)
  for item in adj.results:
    record.lines.add(PowerNames[item.order.power] & ": " &
      formatOrder(item.order) & " — " & outcomeWord(item.outcome))
  sim.history.add(record)
  ## Exactly the last two game-years: two movement phases a year.
  while sim.history.len > HistoryYears * 2:
    sim.history.delete(0)

proc resolveOrders(sim: var Sim) =
  var all: seq[Order]
  for power in 0 ..< Powers:
    for order in sim.orders[power]:
      all.add(order)
  let adj = adjudicate(sim.board, all)
  sim.lastAdjudication = adj
  let stabs = sim.detectStabs()
  for stab in stabs:
    sim.stabbed[stab.power] = true
  for index in 0 ..< sim.pledges.len:
    for stab in stabs:
      if sim.pledges[index].fromPower == stab.power and
          sim.pledges[index].kind == stab.kind and
          sim.pledges[index].toPower == stab.pledgeTo:
        sim.pledges[index].broken = true
        sim.pledges[index].brokenBy = stab.order

  var event = blankEvent(evAdjudicate)
  event.year = sim.year
  event.season = sim.season
  event.phaseKind = pkOrders
  event.results = adj.results
  event.dislodged = adj.dislodged
  event.standoffs = adj.standoffs
  event.stabs = stabs
  sim.addEvent(event)
  sim.recordHistory(adj)

  ## Apply the movement: successful moves land, dislodged units come off the
  ## board until the retreat phase.
  var next: seq[Unit]
  for unit in sim.board.units:
    var isDislodged = false
    for item in adj.dislodged:
      if sameUnit(item.unit, unit):
        isDislodged = true
    if isDislodged:
      continue
    var placed = unit
    for move in adj.moved:
      if sameUnit(move.unit, unit):
        placed.province = move.dest
        placed.coast = move.coast
    next.add(placed)
  sim.board.units = next
  sim.dislodged = adj.dislodged
  sim.standoffs = adj.standoffs

  if sim.dislodged.len > 0:
    sim.openRetreats()
  else:
    sim.afterMovement()

proc submitOrders(sim: Sim, power: int, raws: seq[string]):
    tuple[orders: seq[Order], illegal: seq[IllegalRecord]] =
  ## Steps 1 and 2: own-unit filter, first order per unit wins, illegal
  ## orders become holds and are recorded with a one-word reason.
  var claimed: seq[int]
  for raw in raws:
    if raw.runeLen > MaxOrderLen:
      result.illegal.add(IllegalRecord(
        raw: cleanText(oneLine(raw), MaxOrderLen), why: "parse"))
      continue
    let order = parseOrder(sim.board, power, raw)
    if order.illegal:
      result.illegal.add(IllegalRecord(raw: oneLine(raw.strip()),
        why: order.why))
      ## Step 2: an illegal order becomes `H` for its unit — and that
      ## consumes the unit's slot, so a later order for the same unit is
      ## dropped by step 1 rather than played.
      if order.unit.province >= 0 and order.unit.province notin claimed:
        claimed.add(order.unit.province)
        result.orders.add(Order(power: power, unit: order.unit, kind: okHold,
          target: -1, auxFrom: -1, auxTo: -1,
          raw: unitLabel(order.unit) & " H"))
      continue
    if order.unit.province in claimed:
      continue
    claimed.add(order.unit.province)
    result.orders.add(order)
  ## Every unit with no surviving order holds.
  for unit in sim.board.units:
    if unit.power != power or unit.province in claimed:
      continue
    result.orders.add(Order(power: power, unit: unit, kind: okHold,
      target: -1, auxFrom: -1, auxTo: -1, raw: unitLabel(unit) & " H"))

proc applyOrders*(sim: var Sim, seat: int, raws: seq[string], notes: string,
    scripted: bool) =
  ## `seat` submits its order set for the live movement phase. Illegal
  ## orders are repaired to holds; the reply is never rejected wholesale.
  if sim.done:
    raise newException(CogplomacyError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(CogplomacyError, "bad seat: " & $seat)
  if sim.phase != pkOrders or seat notin sim.pending:
    raise newException(CogplomacyError,
      "seat " & $seat & " is not ordering now")
  let power = sim.powerOf[seat]
  var trimmed: seq[string]
  for raw in raws:
    if trimmed.len >= MaxOrdersPerReply:
      break
    trimmed.add(raw)
  let submitted = sim.submitOrders(power, trimmed)
  sim.orders[power] = submitted.orders
  if notes.len > 0:
    sim.notes[seat] = cleanText(notes, MaxNotesLen)

  var event = blankEvent(evOrders)
  event.year = sim.year
  event.season = sim.season
  event.phaseKind = pkOrders
  event.seat = seat
  event.power = power
  for order in submitted.orders:
    event.orders.add(formatOrder(order))
  event.illegal = submitted.illegal
  event.scripted = scripted
  event.text = sim.notes[seat]
  sim.addEvent(event)

  sim.pending.delete(sim.pending.find(seat))
  if sim.pending.len == 0:
    sim.resolveOrders()

# ---- Retreats ---------------------------------------------------------------

proc resolveRetreats(sim: var Sim) =
  ## Two dislodged units retreating to the same province: both disband.
  var counted = newSeq[int](NumProvinces)
  for move in sim.retreatChoices:
    if move.to >= 0:
      inc counted[move.to]
  for move in sim.retreatChoices:
    if move.to >= 0 and counted[move.to] == 1:
      sim.board.units.add(Unit(power: move.unit.power, kind: move.unit.kind,
        province: move.to, coast: move.coast))
  sim.dislodged = @[]
  sim.retreatChoices = @[]
  sim.afterMovement()

proc applyRetreats*(sim: var Sim, seat: int, raws: seq[string], notes: string,
    scripted: bool) =
  if sim.done:
    raise newException(CogplomacyError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(CogplomacyError, "bad seat: " & $seat)
  if sim.phase != pkRetreats or seat notin sim.pending:
    raise newException(CogplomacyError,
      "seat " & $seat & " is not retreating now")
  let power = sim.powerOf[seat]
  var mine: seq[Dislodgement]
  for item in sim.dislodged:
    if item.unit.power == power:
      mine.add(item)
  var chosen: seq[RetreatMove]
  var handled: seq[int]
  var trimmed: seq[string]
  for raw in raws:
    if trimmed.len >= MaxRetreatsPerReply:
      break
    trimmed.add(raw)
  for raw in trimmed:
    if raw.runeLen > MaxOrderLen:
      continue
    ## The whole dislodged list, not just this power's: parseRetreat picks
    ## the power's own unit out of it, and every dislodged unit still
    ## occupies its province until the retreats resolve.
    let parsed = parseRetreat(sim.board, power, raw, sim.dislodged,
      sim.standoffs)
    if not parsed.ok:
      continue
    if parsed.unit.province in handled:
      continue
    handled.add(parsed.unit.province)
    chosen.add(RetreatMove(unit: parsed.unit, to: parsed.to,
      coast: parsed.coast))
  ## A missing, unparsable or illegal retreat is a disband.
  for item in mine:
    if item.unit.province notin handled:
      chosen.add(RetreatMove(unit: item.unit, to: -1, coast: ""))
  for move in chosen:
    sim.retreatChoices.add(move)
  if notes.len > 0:
    sim.notes[seat] = cleanText(notes, MaxNotesLen)

  var event = blankEvent(evRetreat)
  event.year = sim.year
  event.season = sim.season
  event.phaseKind = pkRetreats
  event.seat = seat
  event.power = power
  event.moves = chosen
  event.scripted = scripted
  event.text = sim.notes[seat]
  sim.addEvent(event)

  sim.pending.delete(sim.pending.find(seat))
  if sim.pending.len == 0:
    sim.resolveRetreats()

# ---- Winter adjustments -----------------------------------------------------

proc civilDisorderPick(sim: Sim, power: int, already: seq[int]): int =
  ## The unit furthest from the nearest home centre the power still owns, on
  ## its own movement graph; ties by province code.
  result = -1
  var worst = -1
  var worstCode = ""
  for index, unit in sim.board.units:
    if unit.power != power or unit.province in already:
      continue
    let distances =
      if unit.kind == ukArmy: bfsDistance(unit.province, false)
      else: bfsDistance(unitNode(unit), true)
    var best = high(int) div 4
    for home in HomeCentres[power]:
      if sim.board.ownerOf(home) == power and distances[home] < best:
        best = distances[home]
    let code = provinceCode(unit.province)
    if best > worst or (best == worst and (worstCode == "" or code < worstCode)):
      worst = best
      worstCode = code
      result = index

proc resolveBuilds(sim: var Sim) =
  sim.endOfYear()

proc applyBuilds*(sim: var Sim, seat: int, raws: seq[string], notes: string,
    scripted: bool) =
  if sim.done:
    raise newException(CogplomacyError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(CogplomacyError, "bad seat: " & $seat)
  if sim.phase != pkBuilds or seat notin sim.pending:
    raise newException(CogplomacyError,
      "seat " & $seat & " is not adjusting now")
  let power = sim.powerOf[seat]
  let delta = sim.buildDelta(power)
  var trimmed: seq[string]
  for raw in raws:
    if trimmed.len >= MaxAdjustmentsPerReply:
      break
    trimmed.add(raw)
  var actions: seq[AdjustAction]
  var waived = 0
  if delta > 0:
    var used: seq[int]
    for raw in trimmed:
      if actions.len >= delta:
        break
      if raw.runeLen > MaxOrderLen:
        continue
      let parsed = parseAdjustment(sim.board, power, raw)
      if not parsed.ok or not parsed.build:
        continue
      if parsed.unit.province in used:
        continue
      used.add(parsed.unit.province)
      sim.board.units.add(parsed.unit)
      actions.add(AdjustAction(action: "build", unit: parsed.unit))
    waived = delta - actions.len
  elif delta < 0:
    let owed = -delta
    var removed: seq[int]
    for raw in trimmed:
      if removed.len >= owed:
        break
      if raw.runeLen > MaxOrderLen:
        continue
      let parsed = parseAdjustment(sim.board, power, raw)
      if not parsed.ok or parsed.build:
        continue
      if parsed.unit.province in removed:
        continue
      removed.add(parsed.unit.province)
      actions.add(AdjustAction(action: "disband", unit: parsed.unit))
    while removed.len < owed:
      let index = sim.civilDisorderPick(power, removed)
      if index < 0:
        break
      removed.add(sim.board.units[index].province)
      actions.add(AdjustAction(action: "disband",
        unit: sim.board.units[index]))
    var kept: seq[Unit]
    for unit in sim.board.units:
      if unit.power == power and unit.province in removed:
        continue
      kept.add(unit)
    sim.board.units = kept
  if notes.len > 0:
    sim.notes[seat] = cleanText(notes, MaxNotesLen)

  var event = blankEvent(evBuild)
  event.year = sim.year
  event.season = seWinter
  event.phaseKind = pkBuilds
  event.seat = seat
  event.power = power
  event.adjustments = actions
  event.waived = waived
  event.scripted = scripted
  event.text = sim.notes[seat]
  sim.addEvent(event)

  sim.pending.delete(sim.pending.find(seat))
  if sim.pending.len == 0:
    sim.resolveBuilds()

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var powersNode = newJArray()
  var scores = newJArray()
  var centresNode = newJArray()
  var unitsNode = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, never by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    powersNode.add(%PowerNames[sim.powerOf[seat]])
    scores.add(%sim.score(seat))
    centresNode.add(%sim.centres(seat))
    unitsNode.add(%sim.unitCount(sim.powerOf[seat]))
  %*{
    "names": names,
    "powers": powersNode,
    "scores": scores,
    "centres": centresNode,
    "units": unitsNode,
    "years": sim.yearsPlayed,
    "maxYears": sim.config.years,
    "soloist": (if sim.soloist >= 0: PowerNames[sim.soloist] else: ""),
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc unitJson(unit: Unit, dislodged: bool): JsonNode =
  %*{
    "power": unit.power,
    "kind": $unit.kind,
    "province": provinceCode(unit.province),
    "coast": unit.coast,
    "dislodged": dislodged
  }

proc arrowsJson(sim: Sim): JsonNode =
  result = newJArray()
  for item in sim.lastAdjudication.results:
    let order = item.order
    case order.kind
    of okMove:
      result.add(%*{"kind": "move",
        "from": provinceCode(order.unit.province),
        "to": provinceCode(order.target), "aux": "",
        "power": order.power, "outcome": $item.outcome})
    of okSupportHold:
      result.add(%*{"kind": "support",
        "from": provinceCode(order.unit.province),
        "to": provinceCode(order.auxFrom), "aux": "",
        "power": order.power, "outcome": $item.outcome})
    of okSupportMove:
      result.add(%*{"kind": "support",
        "from": provinceCode(order.unit.province),
        "to": provinceCode(order.auxTo),
        "aux": provinceCode(order.auxFrom),
        "power": order.power, "outcome": $item.outcome})
    of okConvoy:
      result.add(%*{"kind": "convoy",
        "from": provinceCode(order.unit.province),
        "to": provinceCode(order.auxTo),
        "aux": provinceCode(order.auxFrom),
        "power": order.power, "outcome": $item.outcome})
    of okHold:
      discard

proc tableStateJson*(sim: Sim): JsonNode =
  ## The spectator frame. Every letter of the phase rides here, public and
  ## private — spectators read all the correspondence; the seats do not.
  var seats = newJArray()
  for seat in 0 ..< Seats:
    let power = sim.powerOf[seat]
    var lettersOut = newJArray()
    for letter in sim.press:
      if letter.fromPower == power and letter.toPower >= 0:
        lettersOut.add(%*{"to": PowerNames[letter.toPower],
          "text": letter.text})
    var pledges = newJArray()
    for pledge in sim.pledges:
      if pledge.fromPower == power:
        pledges.add(%*{
          "to": (if pledge.toPower < 0: "ALL"
                 else: PowerNames[pledge.toPower]),
          "kind": $pledge.kind,
          "province": (if pledge.province >= 0:
            provinceCode(pledge.province) else: ""),
          "broken": pledge.broken})
    seats.add(%*{
      "power": PowerNames[power],
      "name": sim.names[seat],
      "centres": sim.centresOfPower(power),
      "units": sim.unitCount(power),
      "score": sim.score(seat),
      "pending": seat in sim.pending,
      "eliminated": sim.eliminated[power],
      "stabbedThisTurn": sim.stabbed[power],
      "broadcast": sim.broadcasts[power],
      "lettersOut": lettersOut,
      "pledges": pledges,
      "notes": sim.notes[seat]
    })
  var seatOfPower = newJArray()
  for power in 0 ..< Powers:
    seatOfPower.add(%sim.seatOf[power])
  var units = newJArray()
  for unit in sim.board.units:
    units.add(unitJson(unit, false))
  for item in sim.dislodged:
    units.add(unitJson(item.unit, true))
  var owners = newJArray()
  for slot in 0 ..< NumCentres:
    owners.add(%*{"centre": provinceCode(SupplyCentres[slot]),
      "power": sim.board.owner[slot]})
  var stabList = newJArray()
  if sim.events.len > 0:
    for index in countdown(sim.events.high, 0):
      if sim.events[index].kind == evAdjudicate:
        for stab in sim.events[index].stabs:
          stabList.add(%*{"power": stab.power,
            "pledgeTo": (if stab.pledgeTo < 0: "ALL"
                         else: PowerNames[stab.pledgeTo]),
            "kind": $stab.kind, "order": stab.order})
        break
  var standoffs = newJArray()
  for province in sim.standoffs:
    standoffs.add(%provinceCode(province))
  var counts = newJArray()
  for record in sim.centresHistory:
    var row = newJArray()
    for value in record:
      row.add(%value)
    counts.add(row)
  var press = newJArray()
  for letter in sim.press:
    press.add(%*{"from": PowerNames[letter.fromPower],
      "to": (if letter.toPower < 0: "ALL" else: PowerNames[letter.toPower]),
      "text": letter.text, "public": letter.toPower < 0})
  %*{
    "seats": seats,
    "seatOfPower": seatOfPower,
    "units": units,
    "owners": owners,
    "arrows": sim.arrowsJson(),
    "stabs": stabList,
    "standoffs": standoffs,
    "year": sim.year,
    "season": $sim.season,
    "phase": $sim.phase,
    "years": sim.config.years,
    "yearsPlayed": sim.yearsPlayed,
    "counts": counts,
    "press": press,
    "gameDone": sim.done,
    "reason": sim.reason,
    "soloist": (if sim.soloist >= 0: PowerNames[sim.soloist] else: "")
  }
  
# ---- Event JSON -------------------------------------------------------------

proc unitToJson(unit: Unit): JsonNode =
  %*{"power": unit.power, "kind": $unit.kind, "province": unit.province,
    "coast": unit.coast}

proc unitFromJson(node: JsonNode): Unit =
  Unit(power: node{"power"}.getInt(-1),
    kind: parseEnum[UnitKind](node{"kind"}.getStr("A"), ukArmy),
    province: node{"province"}.getInt(-1),
    coast: node{"coast"}.getStr(""))

proc orderToJson(order: Order): JsonNode =
  %*{"power": order.power, "unit": unitToJson(order.unit),
    "kind": $order.kind, "target": order.target,
    "targetCoast": order.targetCoast, "auxFrom": order.auxFrom,
    "auxTo": order.auxTo, "auxCoast": order.auxCoast,
    "auxKind": $order.auxKind, "via": order.viaConvoy, "raw": order.raw,
    "illegal": order.illegal, "why": order.why}

proc orderFromJson(node: JsonNode): Order =
  Order(power: node{"power"}.getInt(-1), unit: unitFromJson(node{"unit"}),
    kind: parseEnum[OrderKind](node{"kind"}.getStr("hold"), okHold),
    target: node{"target"}.getInt(-1),
    targetCoast: node{"targetCoast"}.getStr(""),
    auxFrom: node{"auxFrom"}.getInt(-1), auxTo: node{"auxTo"}.getInt(-1),
    auxCoast: node{"auxCoast"}.getStr(""),
    auxKind: parseEnum[UnitKind](node{"auxKind"}.getStr("A"), ukArmy),
    viaConvoy: node{"via"}.getBool(false), raw: node{"raw"}.getStr(""),
    illegal: node{"illegal"}.getBool(false), why: node{"why"}.getStr(""))

proc letterToJson(letter: Letter): JsonNode =
  %*{"from": letter.fromPower, "to": letter.toPower, "text": letter.text}

proc letterFromJson(node: JsonNode): Letter =
  Letter(fromPower: node{"from"}.getInt(-1), toPower: node{"to"}.getInt(-1),
    text: node{"text"}.getStr(""))

proc pledgeToJson(pledge: Pledge): JsonNode =
  %*{"from": pledge.fromPower, "to": pledge.toPower, "kind": $pledge.kind,
    "province": pledge.province, "broken": pledge.broken,
    "brokenBy": pledge.brokenBy}

proc pledgeFromJson(node: JsonNode): Pledge =
  Pledge(fromPower: node{"from"}.getInt(-1), toPower: node{"to"}.getInt(-1),
    kind: parseEnum[PledgeKind](node{"kind"}.getStr("peace"), plPeace),
    province: node{"province"}.getInt(-1),
    broken: node{"broken"}.getBool(false),
    brokenBy: node{"brokenBy"}.getStr(""))

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind, "year": event.year,
    "season": $event.season, "phaseKind": $event.phaseKind}
  if event.seat >= 0:
    result["seat"] = %event.seat
  if event.power >= 0:
    result["power"] = %event.power
  if event.scripted:
    result["scripted"] = %true
  if event.text.len > 0:
    result["text"] = %event.text
  if event.broadcast.len > 0:
    result["broadcast"] = %event.broadcast
  if event.letters.len > 0:
    var letters = newJArray()
    for letter in event.letters:
      letters.add(letterToJson(letter))
    result["letters"] = letters
  if event.pledges.len > 0:
    var pledges = newJArray()
    for pledge in event.pledges:
      pledges.add(pledgeToJson(pledge))
    result["pledges"] = pledges
  if event.orders.len > 0:
    var list = newJArray()
    for order in event.orders:
      list.add(%order)
    result["orders"] = list
  if event.illegal.len > 0:
    var list = newJArray()
    for item in event.illegal:
      list.add(%*{"raw": item.raw, "why": item.why})
    result["illegal"] = list
  if event.results.len > 0:
    var list = newJArray()
    for item in event.results:
      list.add(%*{"order": orderToJson(item.order),
        "outcome": $item.outcome})
    result["results"] = list
  if event.dislodged.len > 0:
    var list = newJArray()
    for item in event.dislodged:
      list.add(%*{"unit": unitToJson(item.unit),
        "attackerFrom": item.attackerFrom})
    result["dislodged"] = list
  if event.standoffs.len > 0:
    var list = newJArray()
    for province in event.standoffs:
      list.add(%province)
    result["standoffs"] = list
  if event.stabs.len > 0:
    var list = newJArray()
    for stab in event.stabs:
      list.add(%*{"seat": stab.seat, "power": stab.power,
        "pledgeTo": stab.pledgeTo, "kind": $stab.kind,
        "province": stab.province, "order": stab.order})
    result["stabs"] = list
  if event.moves.len > 0:
    var list = newJArray()
    for move in event.moves:
      list.add(%*{"unit": unitToJson(move.unit), "to": move.to,
        "coast": move.coast})
    result["moves"] = list
  if event.adjustments.len > 0:
    var list = newJArray()
    for action in event.adjustments:
      list.add(%*{"action": action.action, "unit": unitToJson(action.unit)})
    result["adjustments"] = list
  if event.waived > 0:
    result["waived"] = %event.waived
  if event.units.len > 0:
    var list = newJArray()
    for unit in event.units:
      list.add(unitToJson(unit))
    result["units"] = list
  if event.owners.len > 0:
    var list = newJArray()
    for owner in event.owners:
      list.add(%owner)
    result["owners"] = list
  if event.counts.len > 0:
    var list = newJArray()
    for value in event.counts:
      list.add(%value)
    result["counts"] = list
  if event.gained.len > 0:
    var list = newJArray()
    for value in event.gained:
      list.add(%value)
    result["gained"] = list
  if event.lost.len > 0:
    var list = newJArray()
    for value in event.lost:
      list.add(%value)
    result["lost"] = list
  if event.powers.len > 0:
    var list = newJArray()
    for value in event.powers:
      list.add(%value)
    result["powers"] = list
  if event.soloist >= 0:
    result["soloist"] = %event.soloist

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    year: node{"year"}.getInt(StartYear),
    season: parseEnum[Season](node{"season"}.getStr("spring"), seSpring),
    phaseKind: parseEnum[PhaseKind](node{"phaseKind"}.getStr("press"),
      pkPress),
    seat: node{"seat"}.getInt(-1),
    power: node{"power"}.getInt(-1),
    scripted: node{"scripted"}.getBool(false),
    text: node{"text"}.getStr(""),
    broadcast: node{"broadcast"}.getStr(""),
    waived: node{"waived"}.getInt(0),
    soloist: node{"soloist"}.getInt(-1))
  if node.hasKey("letters"):
    for item in node["letters"]:
      result.letters.add(letterFromJson(item))
  if node.hasKey("pledges"):
    for item in node["pledges"]:
      result.pledges.add(pledgeFromJson(item))
  if node.hasKey("orders"):
    for item in node["orders"]:
      result.orders.add(item.getStr())
  if node.hasKey("illegal"):
    for item in node["illegal"]:
      result.illegal.add(IllegalRecord(raw: item{"raw"}.getStr(),
        why: item{"why"}.getStr()))
  if node.hasKey("results"):
    for item in node["results"]:
      result.results.add(OrderResult(order: orderFromJson(item{"order"}),
        outcome: parseEnum[Outcome](item{"outcome"}.getStr("success"),
          orSuccess)))
  if node.hasKey("dislodged"):
    for item in node["dislodged"]:
      result.dislodged.add(Dislodgement(unit: unitFromJson(item{"unit"}),
        attackerFrom: item{"attackerFrom"}.getInt(-1)))
  if node.hasKey("standoffs"):
    for item in node["standoffs"]:
      result.standoffs.add(item.getInt())
  if node.hasKey("stabs"):
    for item in node["stabs"]:
      result.stabs.add(StabRecord(seat: item{"seat"}.getInt(-1),
        power: item{"power"}.getInt(-1),
        pledgeTo: item{"pledgeTo"}.getInt(-1),
        kind: parseEnum[PledgeKind](item{"kind"}.getStr("peace"), plPeace),
        province: item{"province"}.getInt(-1),
        order: item{"order"}.getStr("")))
  if node.hasKey("moves"):
    for item in node["moves"]:
      result.moves.add(RetreatMove(unit: unitFromJson(item{"unit"}),
        to: item{"to"}.getInt(-1), coast: item{"coast"}.getStr("")))
  if node.hasKey("adjustments"):
    for item in node["adjustments"]:
      result.adjustments.add(AdjustAction(action: item{"action"}.getStr(),
        unit: unitFromJson(item{"unit"})))
  if node.hasKey("units"):
    for item in node["units"]:
      result.units.add(unitFromJson(item))
  if node.hasKey("owners"):
    for item in node["owners"]:
      result.owners.add(item.getInt())
  if node.hasKey("counts"):
    for item in node["counts"]:
      result.counts.add(item.getInt())
  if node.hasKey("gained"):
    for item in node["gained"]:
      result.gained.add(item.getInt())
  if node.hasKey("lost"):
    for item in node["lost"]:
      result.lost.add(item.getInt())
  if node.hasKey("powers"):
    for item in node["powers"]:
      result.powers.add(item.getInt())

# ---- Replay -----------------------------------------------------------------

proc sameUnits(recorded, derived: seq[Unit]): bool =
  if recorded.len != derived.len:
    return false
  for index in 0 ..< recorded.len:
    if not sameUnit(recorded[index], derived[index]):
      return false
  true

proc sameOwners(recorded: seq[int], board: Board): bool =
  if recorded.len != NumCentres:
    return false
  for slot in 0 ..< NumCentres:
    if recorded[slot] != board.owner[slot]:
      return false
  true

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the whole state timeline from a recorded event log by
  ## replaying the seats' decisions through the rules. The permutation and
  ## the aliases come from the seed; every derived event (`phase`,
  ## `adjudicate`, `centres`) is CHECKED against the re-derivation rather
  ## than trusted. frames[i] = state after events[0 ..< i].
  var sim = initSim(config)
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      if not sameUnits(event.units, sim.board.units) or
          not sameOwners(event.owners, sim.board):
        raise newException(CogplomacyError,
          "start event does not match the seeded board")
    of evPhase:
      if event.year != sim.year or event.season != sim.season or
          event.phaseKind != sim.phase:
        raise newException(CogplomacyError,
          "phase " & $event.year & " " & $event.season & " " &
          $event.phaseKind & " does not match the seeded re-derivation")
      ## The derived board the event carries, checked rather than trusted.
      if not sameUnits(event.units, sim.board.units) or
          not sameOwners(event.owners, sim.board) or
          event.counts != sim.counts():
        raise newException(CogplomacyError,
          "the board recorded at " & $event.year & " " & $event.season &
          " " & $event.phaseKind & " does not match the seeded re-derivation")
    of evPress:
      sim.applyPress(event.seat, event.broadcast, event.letters,
        event.pledges, event.text, event.scripted)
    of evOrders:
      sim.applyOrders(event.seat, event.orders, event.text, event.scripted)
    of evAdjudicate:
      let derived = sim.lastAdjudication
      if event.results.len != derived.results.len or
          event.dislodged.len != derived.dislodged.len or
          event.standoffs != derived.standoffs:
        raise newException(CogplomacyError,
          "adjudication does not match the seeded re-derivation")
      for index in 0 ..< event.results.len:
        if event.results[index].outcome != derived.results[index].outcome or
            formatOrder(event.results[index].order) !=
              formatOrder(derived.results[index].order):
          raise newException(CogplomacyError,
            "order result " & formatOrder(event.results[index].order) &
            " does not match the seeded re-derivation")
      for index in 0 ..< event.dislodged.len:
        if not sameUnit(event.dislodged[index].unit,
            derived.dislodged[index].unit):
          raise newException(CogplomacyError,
            "dislodgement does not match the seeded re-derivation")
    of evRetreat:
      var raws: seq[string]
      for move in event.moves:
        if move.to < 0:
          raws.add(unitLabel(move.unit) & " - D")
        else:
          raws.add(unitLabel(move.unit) & " - " & provinceCode(move.to) &
            (if move.coast.len > 0: "/" & move.coast else: ""))
      sim.applyRetreats(event.seat, raws, event.text, event.scripted)
    of evBuild:
      var raws: seq[string]
      for action in event.adjustments:
        raws.add(action.action.toUpperAscii() & " " & unitLabel(action.unit))
      sim.applyBuilds(event.seat, raws, event.text, event.scripted)
    of evCentres:
      for slot in 0 ..< min(event.owners.len, NumCentres):
        if event.owners[slot] != sim.board.owner[slot]:
          raise newException(CogplomacyError,
            "ownership table does not match the seeded re-derivation")
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the decisions alone.
        sim.settle(event.text)
    result.add(sim)
