## The movement-phase adjudicator.
##
## `adjudicate(board, orders)` is steps 2–8 of the resolution order in the
## design note: void unmatched supports and convoys, find convoy paths,
## resolve every move with Lucas B. Kruijswijk's *Math of Adjudication*
## recursion (unresolved / guessing / resolved marks with cycle detection),
## cut supports, record dislodgements and standoffs.
##
## Pure and total: no RNG, no IO, no exceptions on legal input. The orders
## handed in are already own-unit-filtered and legality-repaired by the sim,
## exactly one per unit on the board, so everything here is about strength.
##
## Cycles are broken by exactly two backup rules: **circular movement** (a
## closed ring of moves with no external interference all succeed) and the
## **Szykman rule** for convoy paradoxes (the paradoxical convoyed move
## fails and its army holds; the convoying fleet's dislodgement stands).

import std/[algorithm], mapdata, types, orders

export types

type
  Adjudication* = object
    results*: seq[OrderResult]
    dislodged*: seq[Dislodgement]
    standoffs*: seq[int]
    moved*: seq[MoveRecord]

  MoveRecord* = object
    unit*: Unit
    dest*: int
    coast*: string

  Mark = enum
    mkUnresolved, mkGuessing, mkResolved

  Resolver = object
    board: Board
    ords: seq[Order]        ## aligned one-to-one with board.units
    state: seq[Mark]
    value: seq[bool]
    depList: seq[int]
    szykman: seq[bool]      ## convoyed moves the backup rule disabled
    steps: int

const ResolveStepCap = 200_000
  ## Belt and braces: the recursion is bounded by the number of orders
  ## (<= 34) and the two backup rules always resolve at least one order, so
  ## this can only fire on a bug. It keeps a bug from hanging an episode.

proc resolve(r: var Resolver, index: int): bool
proc adjudicateMove(r: var Resolver, index: int): bool

# ---- Order predicates -------------------------------------------------------

proc isMove(r: Resolver, index: int): bool =
  r.ords[index].kind == okMove

proc isConvoyed(r: Resolver, index: int): bool =
  ## A move is convoyed when the army's destination is not adjacent by land,
  ## or when the order explicitly says VIA CONVOY (DATC 6.G).
  let order = r.ords[index]
  if order.kind != okMove or order.unit.kind != ukArmy:
    return false
  order.viaConvoy or order.target notin ArmyAdj[order.unit.province]

proc supportValid(r: Resolver, index: int): bool =
  ## Step 3: an unmatched support or convoy is void and its unit merely
  ## holds.
  let order = r.ords[index]
  case order.kind
  of okSupportHold:
    let seat = r.board.unitAt(order.auxFrom)
    seat >= 0 and r.ords[seat].kind != okMove
  of okSupportMove:
    let seat = r.board.unitAt(order.auxFrom)
    if seat < 0:
      return false
    let supported = r.ords[seat]
    if supported.kind != okMove or supported.target != order.auxTo:
      return false
    order.auxCoast.len == 0 or order.auxCoast == supported.targetCoast
  of okConvoy:
    let seat = r.board.unitAt(order.auxFrom)
    if seat < 0:
      return false
    let carried = r.ords[seat]
    carried.kind == okMove and carried.unit.kind == ukArmy and
      carried.target == order.auxTo
  else:
    false

proc headToHead(r: Resolver, index: int): int =
  ## The opposing move in a head-to-head battle, or -1. A convoyed move is
  ## never head-to-head: it arrives from the sea.
  result = -1
  let order = r.ords[index]
  if order.kind != okMove or r.isConvoyed(index):
    return
  let seat = r.board.unitAt(order.target)
  if seat < 0:
    return
  let other = r.ords[seat]
  if other.kind == okMove and other.target == order.unit.province and
      not r.isConvoyed(seat):
    return seat

# ---- Convoy paths -----------------------------------------------------------

proc convoyFleetDislodged(r: var Resolver, seat: int): bool =
  ## A convoying fleet never moves, so anything that successfully enters its
  ## province dislodges it and breaks the chain.
  let province = r.board.units[seat].province
  for index in 0 ..< r.ords.len:
    if r.ords[index].kind == okMove and r.ords[index].target == province:
      if r.resolve(index):
        return true
  false

proc pathOk(r: var Resolver, index: int): bool =
  ## Step 4: a convoyed move needs a chain of sea spaces whose fleets issued
  ## the matching convoy order and survived the turn.
  if not r.isConvoyed(index):
    return true
  if r.szykman[index]:
    return false
  let order = r.ords[index]
  if not isCoastal(order.unit.province) or not isCoastal(order.target):
    return false
  var usable: seq[int]      ## seat indexes of live convoying fleets
  for seat in 0 ..< r.ords.len:
    let convoy = r.ords[seat]
    if convoy.kind != okConvoy:
      continue
    if convoy.auxFrom != order.unit.province or convoy.auxTo != order.target:
      continue
    if not r.supportValid(seat):
      continue
    if r.convoyFleetDislodged(seat):
      continue
    usable.add(seat)
  if usable.len == 0:
    return false
  ## Walk the sea graph over just those fleets.
  var frontier: seq[int]
  var seen: seq[int]
  for node in fleetNodesOf(order.unit.province):
    for next in FleetAdj[node]:
      let seat = r.board.unitAt(FleetNodeProvince[next])
      if seat >= 0 and seat in usable and seat notin frontier:
        frontier.add(seat)
  var head = 0
  while head < frontier.len:
    let seat = frontier[head]
    inc head
    seen.add(seat)
    let node = unitNode(r.board.units[seat])
    for next in FleetAdj[node]:
      let province = FleetNodeProvince[next]
      if province == order.target:
        return true
      let neighbour = r.board.unitAt(province)
      if neighbour >= 0 and neighbour in usable and neighbour notin frontier:
        frontier.add(neighbour)
  false

# ---- Support cutting --------------------------------------------------------

proc supportCut(r: var Resolver, index: int): bool =
  ## Step 6. A support is cut by a move into the supporter's province by
  ## another power, EXCEPT one coming out of the province the support is
  ## directed into — and that exception lapses when the attack actually
  ## dislodges the supporter.
  let support = r.ords[index]
  let province = support.unit.province
  let into =
    if support.kind == okSupportHold: support.auxFrom else: support.auxTo
  for other in 0 ..< r.ords.len:
    let attack = r.ords[other]
    if attack.kind != okMove or attack.target != province:
      continue
    if attack.power == support.power:
      continue
    if not r.pathOk(other):
      continue
    if attack.unit.province != into:
      return true
    if r.resolve(other):
      return true
  false

proc supportCounts(r: var Resolver, index: int): bool =
  r.supportValid(index) and not r.supportCut(index)

# ---- Strengths --------------------------------------------------------------

proc supportersOfMove(r: var Resolver, index: int,
    excludePower: int): int =
  ## Valid, uncut supports for move `index`, optionally dropping the ones
  ## given by the power whose unit is standing in the destination.
  let move = r.ords[index]
  for other in 0 ..< r.ords.len:
    let support = r.ords[other]
    if support.kind != okSupportMove:
      continue
    if support.auxFrom != move.unit.province or support.auxTo != move.target:
      continue
    if excludePower >= 0 and support.power == excludePower:
      continue
    if r.supportCounts(other):
      inc result

proc holdStrength(r: var Resolver, province: int): int =
  let seat = r.board.unitAt(province)
  if seat < 0:
    return 0
  if r.ords[seat].kind == okMove:
    return if r.resolve(seat): 0 else: 1
  result = 1
  for other in 0 ..< r.ords.len:
    let support = r.ords[other]
    if support.kind == okSupportHold and support.auxFrom == province and
        r.supportCounts(other):
      inc result

proc attackStrength(r: var Resolver, index: int): int =
  if not r.pathOk(index):
    return 0
  let move = r.ords[index]
  let seat = r.board.unitAt(move.target)
  if seat < 0:
    return 1 + r.supportersOfMove(index, -1)
  let occupant = r.ords[seat]
  let opposing = r.headToHead(index)
  if occupant.kind == okMove and opposing < 0 and r.resolve(seat):
    ## The occupier successfully moved away (and not into us).
    return 1 + r.supportersOfMove(index, -1)
  if r.board.units[seat].power == move.power:
    ## No power may dislodge its own unit.
    return 0
  1 + r.supportersOfMove(index, r.board.units[seat].power)

proc defendStrength(r: var Resolver, index: int): int =
  1 + r.supportersOfMove(index, -1)

proc preventStrength(r: var Resolver, index: int): int =
  if not r.pathOk(index):
    return 0
  let opposing = r.headToHead(index)
  if opposing >= 0 and r.resolve(opposing):
    return 0
  1 + r.supportersOfMove(index, -1)

# ---- The recursion ----------------------------------------------------------

proc adjudicateMove(r: var Resolver, index: int): bool =
  if not r.pathOk(index):
    return false
  let move = r.ords[index]
  let mine = r.attackStrength(index)
  let opposing = r.headToHead(index)
  if opposing >= 0:
    if mine <= r.defendStrength(opposing):
      return false
  else:
    if mine <= r.holdStrength(move.target):
      return false
  for other in 0 ..< r.ords.len:
    if other == index or r.ords[other].kind != okMove:
      continue
    if r.ords[other].target != move.target:
      continue
    if mine <= r.preventStrength(other):
      return false
  true

proc backupRule(r: var Resolver, oldDep: int) =
  ## Exactly two rules. A ring of plain moves all succeed; a ring holding a
  ## convoyed move is a convoy paradox, and the Szykman rule fails that move.
  var cycle: seq[int]
  while r.depList.len > oldDep:
    cycle.add(r.depList.pop())
  var paradox = false
  for index in cycle:
    if r.isMove(index) and r.isConvoyed(index):
      paradox = true
  for index in cycle:
    if paradox:
      if r.isMove(index) and r.isConvoyed(index):
        r.szykman[index] = true
        r.state[index] = mkResolved
        r.value[index] = false
      else:
        r.state[index] = mkUnresolved
    else:
      r.state[index] = mkResolved
      r.value[index] = true

proc resolve(r: var Resolver, index: int): bool =
  inc r.steps
  if r.steps > ResolveStepCap:
    return false
  if r.state[index] == mkResolved:
    return r.value[index]
  if r.state[index] == mkGuessing:
    if index notin r.depList:
      r.depList.add(index)
    return r.value[index]
  if r.ords[index].kind != okMove:
    r.state[index] = mkResolved
    r.value[index] = false
    return false
  let oldDep = r.depList.len
  r.value[index] = false
  r.state[index] = mkGuessing
  let first = r.adjudicateMove(index)
  if r.depList.len == oldDep:
    r.state[index] = mkResolved
    r.value[index] = first
    return first
  if r.depList[oldDep] != index:
    ## We depend on a cycle we are not the head of; let the head sort it out.
    r.depList.add(index)
    r.value[index] = first
    return first
  while r.depList.len > oldDep:
    r.state[r.depList.pop()] = mkUnresolved
  r.value[index] = true
  r.state[index] = mkGuessing
  let second = r.adjudicateMove(index)
  if first == second:
    while r.depList.len > oldDep:
      r.state[r.depList.pop()] = mkUnresolved
    r.state[index] = mkResolved
    r.value[index] = first
    return first
  r.backupRule(oldDep)
  r.resolve(index)

# ---- Entry point ------------------------------------------------------------

proc alignOrders(board: Board, submitted: seq[Order]): seq[Order] =
  ## One order per unit, in unit order. A unit with no order holds.
  result = newSeq[Order](board.units.len)
  for index, unit in board.units:
    var found = false
    for order in submitted:
      if not found and sameUnit(order.unit, unit) and not order.illegal:
        result[index] = order
        found = true
    if not found:
      result[index] = Order(power: unit.power, unit: unit, kind: okHold,
        target: -1, auxFrom: -1, auxTo: -1, raw: unitLabel(unit) & " H")

proc adjudicate*(board: Board, submitted: seq[Order]): Adjudication =
  ## Steps 2–8. Every unit on the board gets exactly one result.
  var r = Resolver(board: board, ords: alignOrders(board, submitted))
  r.state = newSeq[Mark](r.ords.len)
  r.value = newSeq[bool](r.ords.len)
  r.szykman = newSeq[bool](r.ords.len)

  var succeeds = newSeq[bool](r.ords.len)
  for index in 0 ..< r.ords.len:
    if r.ords[index].kind == okMove:
      succeeds[index] = r.resolve(index)

  ## Dislodgements: a unit that did not move away and had a successful move
  ## enter its province.
  var dislodgedFlags = newSeq[bool](r.ords.len)
  for index in 0 ..< r.ords.len:
    if succeeds[index]:
      continue
    let province = board.units[index].province
    for other in 0 ..< r.ords.len:
      if succeeds[other] and r.ords[other].target == province:
        dislodgedFlags[index] = true
        result.dislodged.add(Dislodgement(unit: board.units[index],
          attackerFrom: r.ords[other].unit.province))

  ## Standoffs: two or more moves bounced into the same province.
  var bounced = newSeq[int](NumProvinces)
  for index in 0 ..< r.ords.len:
    if r.ords[index].kind == okMove and not succeeds[index] and
        r.pathOk(index):
      inc bounced[r.ords[index].target]
  for province in 0 ..< NumProvinces:
    if bounced[province] >= 2:
      result.standoffs.add(province)

  for index in 0 ..< r.ords.len:
    let order = r.ords[index]
    var outcome: Outcome
    case order.kind
    of okMove:
      if succeeds[index]:
        outcome = orSuccess
        result.moved.add(MoveRecord(unit: order.unit, dest: order.target,
          coast: order.targetCoast))
      elif not r.pathOk(index):
        outcome = orNoConvoy
      else:
        outcome = orBounce
    of okSupportHold, okSupportMove:
      if not r.supportValid(index):
        outcome = orVoid
      elif r.supportCut(index):
        outcome = orCut
      else:
        outcome = orSuccess
    of okConvoy:
      outcome = if r.supportValid(index): orSuccess else: orVoid
    of okHold:
      outcome = if dislodgedFlags[index]: orDislodged else: orSuccess
    if order.kind != okMove and order.kind != okHold and
        dislodgedFlags[index] and outcome == orSuccess:
      outcome = orDislodged
    result.results.add(OrderResult(order: order, outcome: outcome))

  result.standoffs.sort(proc (a, b: int): int =
    cmp(provinceCode(a), provinceCode(b)))
