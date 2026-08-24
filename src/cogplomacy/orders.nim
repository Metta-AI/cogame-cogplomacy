## Canonical order notation: one grammar for parsing and for printing.
##
##   A PAR H                 hold
##   A PAR - BUR             move
##   A PAR - BUR VIA CONVOY  move, convoy demanded
##   F BRE S A PAR           support a hold
##   F BRE S A PAR - PIC     support a move
##   F ENG C A LON - BRE     convoy
##   F STP/SC - BOT          a fleet on a named coast
##   A VIE - D               retreat: disband
##   BUILD F STP/SC          winter adjustment
##   DISBAND A MOS           winter adjustment
##
## Parsing is whitespace- and case-tolerant and accepts `-`, `–` and `->`
## for a move and `S`/`SUPPORT`, `C`/`CONVOY`, `H`/`HOLD`/`HOLDS`; nothing
## else. An order that cannot be parsed, or that names something the map
## forbids, comes back with `illegal = true` and a one-word `why`; the sim
## turns every such order into a hold and records it. An illegal order NEVER
## invalidates the rest of a reply.

import std/[algorithm, strutils], mapdata, types

export mapdata, types

const MaxLegalOrders* = 64

# ---- Printing ---------------------------------------------------------------

proc locLabel(province: int, coast: string): string =
  result = provinceCode(province)
  if coast.len > 0:
    result.add("/" & coast)

proc formatOrder*(order: Order): string =
  ## The canonical string for an order. `A PAR - BUR VIA CONVOY`.
  let head = unitLabel(order.unit)
  case order.kind
  of okHold:
    head & " H"
  of okMove:
    head & " - " & locLabel(order.target, order.targetCoast) &
      (if order.viaConvoy: " VIA CONVOY" else: "")
  of okSupportHold:
    head & " S " & $order.auxKind & " " & provinceCode(order.auxFrom)
  of okSupportMove:
    head & " S " & $order.auxKind & " " & provinceCode(order.auxFrom) &
      " - " & locLabel(order.auxTo, order.auxCoast)
  of okConvoy:
    head & " C " & $order.auxKind & " " & provinceCode(order.auxFrom) &
      " - " & provinceCode(order.auxTo)

proc orderWords*(order: Order): string =
  ## The same order in words, for the spectator feed.
  let who = unitWords(order.unit)
  case order.kind
  of okHold:
    "the " & who & " holds"
  of okMove:
    provinceName(order.unit.province) & " → " & provinceName(order.target)
  of okSupportHold:
    provinceName(order.unit.province) & " supports " &
      provinceName(order.auxFrom)
  of okSupportMove:
    provinceName(order.unit.province) & " supports " &
      provinceName(order.auxFrom) & " → " & provinceName(order.auxTo)
  of okConvoy:
    provinceName(order.unit.province) & " convoys " &
      provinceName(order.auxFrom) & " → " & provinceName(order.auxTo)

# ---- Map questions the grammar needs ----------------------------------------

proc isCoastal*(province: int): bool =
  province >= 0 and province < NumProvinces and
    Provinces[province].kind == pkCoast

proc isSea*(province: int): bool =
  province >= 0 and province < NumProvinces and
    Provinces[province].kind == pkSea

proc armyCanEnter*(province: int): bool =
  province >= 0 and province < NumProvinces and
    Provinces[province].kind != pkSea

proc fleetReach*(unit: Unit, province: int): seq[int] =
  ## Fleet nodes of `province` this fleet can move onto in one step.
  let from0 = unitNode(unit)
  if from0 < 0:
    return
  for node in fleetNodesOf(province):
    if node in FleetAdj[from0]:
      result.add(node)

proc canReach*(unit: Unit, province: int): bool =
  ## Could this unit move into that province at all, ignoring coasts?
  if unit.kind == ukArmy:
    armyCanEnter(province) and province in ArmyAdj[unit.province]
  else:
    fleetReach(unit, province).len > 0

proc convoyPossible*(fromProv, toProv: int): bool =
  ## Is there any chain of sea spaces at all between two coasts? This is a
  ## question about the MAP, not about the orders on it; whether fleets
  ## actually convoy is decided in adjudicate.nim.
  if fromProv == toProv:
    return false
  if not isCoastal(fromProv) or not isCoastal(toProv):
    return false
  var seen: seq[int]
  var queue: seq[int]
  for node in fleetNodesOf(fromProv):
    for next in FleetAdj[node]:
      if isSea(FleetNodeProvince[next]) and next notin queue:
        queue.add(next)
  var head = 0
  while head < queue.len:
    let node = queue[head]
    inc head
    seen.add(node)
    for next in FleetAdj[node]:
      let prov = FleetNodeProvince[next]
      if prov == toProv:
        return true
      if isSea(prov) and next notin queue:
        queue.add(next)
  false

# ---- Parsing ----------------------------------------------------------------

proc normalize(raw: string): seq[string] =
  var text = raw.strip().toUpperAscii()
  text = text.replace("\u2013", "-").replace("\u2014", "-")
  text = text.replace("->", "-").replace("=>", "-")
  text = text.replace(".", " ").replace(",", " ")
  text = text.replace("-", " - ")
  for token in text.splitWhitespace():
    if token.len > 0:
      result.add(token)

proc parseLoc(token: string): tuple[province: int, coast: string] =
  result = (-1, "")
  let slash = token.find('/')
  if slash < 0:
    result.province = provinceByCode(token)
  else:
    result.province = provinceByCode(token[0 ..< slash])
    result.coast = token[slash + 1 .. ^1]
    if result.coast notin ["NC", "SC", "EC", "WC"]:
      result.province = -1

proc badOrder(power: int, raw, why: string): Order =
  Order(power: power, kind: okHold, target: -1, auxFrom: -1, auxTo: -1,
    raw: raw, illegal: true, why: why)

proc isUnitToken(token: string): bool =
  token in ["A", "F", "ARMY", "FLEET"]

proc parseOrder*(board: Board, power: int, raw: string): Order =
  ## Parse and legality-check one movement-phase order for `power`.
  ## Everything the map forbids comes back illegal with a one-word reason.
  let tokens = normalize(raw)
  if tokens.len == 0:
    return badOrder(power, raw, "parse")
  var index = 0
  if isUnitToken(tokens[index]):
    inc index
  if index >= tokens.len:
    return badOrder(power, raw, "parse")
  let origin = parseLoc(tokens[index])
  inc index
  if origin.province < 0:
    return badOrder(power, raw, "parse")
  let seat = board.unitAt(origin.province)
  if seat < 0:
    return badOrder(power, raw, "notthere")
  let unit = board.units[seat]
  if unit.power != power:
    return badOrder(power, raw, "wrongunit")

  var order = Order(power: power, unit: unit, kind: okHold, target: -1,
    auxFrom: -1, auxTo: -1, raw: raw)

  if index >= tokens.len:
    return order
  let verb = tokens[index]
  inc index

  if verb in ["H", "HOLD", "HOLDS"]:
    return order

  if verb == "-":
    if index >= tokens.len:
      return badOrder(power, raw, "parse")
    let dest = parseLoc(tokens[index])
    inc index
    if dest.province < 0:
      return badOrder(power, raw, "parse")
    var via = false
    while index < tokens.len:
      if tokens[index] == "VIA":
        via = true
      elif tokens[index] != "CONVOY":
        return badOrder(power, raw, "parse")
      inc index
    if dest.province == unit.province:
      return badOrder(power, raw, "parse")
    order.kind = okMove
    order.target = dest.province
    order.viaConvoy = via
    if unit.kind == ukArmy:
      if not armyCanEnter(dest.province):
        return badOrder(power, raw, "wrongunit")
      order.targetCoast = ""
      if via and not convoyPossible(unit.province, dest.province):
        return badOrder(power, raw, "noconvoy")
      if dest.province notin ArmyAdj[unit.province]:
        if not convoyPossible(unit.province, dest.province):
          return badOrder(power, raw, "nonadjacent")
        order.viaConvoy = true
      return order
    ## Fleet.
    if via:
      return badOrder(power, raw, "wrongunit")
    if fleetNodesOf(dest.province).len == 0:
      return badOrder(power, raw, "wrongunit")
    if dest.coast.len > 0:
      let node = fleetNode(dest.province, dest.coast)
      if node < 0:
        return badOrder(power, raw, "wrongunit")
      if node notin FleetAdj[unitNode(unit)]:
        return badOrder(power, raw, "nonadjacent")
      order.targetCoast = dest.coast
      return order
    let reach = fleetReach(unit, dest.province)
    if reach.len == 0:
      return badOrder(power, raw, "nonadjacent")
    if reach.len > 1:
      return badOrder(power, raw, "ambiguouscoast")
    order.targetCoast = FleetNodeCoast[reach[0]]
    return order

  if verb in ["S", "SUPPORT", "SUPPORTS"]:
    if index < tokens.len and isUnitToken(tokens[index]):
      inc index
    if index >= tokens.len:
      return badOrder(power, raw, "parse")
    let aux = parseLoc(tokens[index])
    inc index
    if aux.province < 0:
      return badOrder(power, raw, "parse")
    if aux.province == unit.province:
      return badOrder(power, raw, "wrongunit")
    let auxSeat = board.unitAt(aux.province)
    if auxSeat < 0:
      return badOrder(power, raw, "notthere")
    order.auxFrom = aux.province
    order.auxKind = board.units[auxSeat].kind
    if index >= tokens.len:
      order.kind = okSupportHold
      if not canReach(unit, aux.province):
        return badOrder(power, raw, "nonadjacent")
      return order
    if tokens[index] != "-":
      return badOrder(power, raw, "parse")
    inc index
    if index >= tokens.len:
      return badOrder(power, raw, "parse")
    let dest = parseLoc(tokens[index])
    inc index
    if dest.province < 0:
      return badOrder(power, raw, "parse")
    if index < tokens.len:
      return badOrder(power, raw, "parse")
    order.kind = okSupportMove
    order.auxTo = dest.province
    order.auxCoast = dest.coast
    ## A support is aimed at a PROVINCE: which coast the mover names is
    ## the mover's business (DATC 6.B.4).
    if not canReach(unit, dest.province):
      return badOrder(power, raw, "nonadjacent")
    return order

  if verb in ["C", "CONVOY", "CONVOYS"]:
    if unit.kind != ukFleet:
      return badOrder(power, raw, "wrongunit")
    if not isSea(unit.province):
      return badOrder(power, raw, "wrongunit")
    if index < tokens.len and isUnitToken(tokens[index]):
      inc index
    if index >= tokens.len:
      return badOrder(power, raw, "parse")
    let aux = parseLoc(tokens[index])
    inc index
    if aux.province < 0:
      return badOrder(power, raw, "parse")
    let auxSeat = board.unitAt(aux.province)
    if auxSeat < 0:
      return badOrder(power, raw, "notthere")
    if board.units[auxSeat].kind != ukArmy:
      return badOrder(power, raw, "wrongunit")
    if index >= tokens.len or tokens[index] != "-":
      return badOrder(power, raw, "parse")
    inc index
    if index >= tokens.len:
      return badOrder(power, raw, "parse")
    let dest = parseLoc(tokens[index])
    inc index
    if dest.province < 0 or index < tokens.len:
      return badOrder(power, raw, "parse")
    if not isCoastal(aux.province) or not isCoastal(dest.province):
      return badOrder(power, raw, "wrongunit")
    order.kind = okConvoy
    order.auxFrom = aux.province
    order.auxTo = dest.province
    order.auxKind = ukArmy
    return order

  badOrder(power, raw, "parse")

# ---- Legal-order enumeration ------------------------------------------------

proc legalOrders*(board: Board, unit: Unit): seq[string] =
  ## Every order this unit may write this movement phase, in the exact
  ## notation a reply must use: hold, moves, support-holds, support-moves,
  ## convoys. Capped at `MaxLegalOrders` defensively.
  var holds: seq[string]
  var moves: seq[string]
  var supportHolds: seq[string]
  var supportMoves: seq[string]
  var convoys: seq[string]

  holds.add(formatOrder(Order(unit: unit, kind: okHold, target: -1,
    auxFrom: -1, auxTo: -1)))

  if unit.kind == ukArmy:
    var dests = ArmyAdj[unit.province]
    dests.sort(proc (a, b: int): int = cmp(provinceCode(a), provinceCode(b)))
    for dest in dests:
      moves.add(formatOrder(Order(unit: unit, kind: okMove, target: dest,
        auxFrom: -1, auxTo: -1)))
    if isCoastal(unit.province):
      ## One-sea convoys: the destinations a single friendly fleet could
      ## carry this army to. Longer chains are legal and parse, they are
      ## just not enumerated here.
      var reachable: seq[int]
      for node in fleetNodesOf(unit.province):
        for sea in FleetAdj[node]:
          if not isSea(FleetNodeProvince[sea]):
            continue
          for coastNode in FleetAdj[sea]:
            let prov = FleetNodeProvince[coastNode]
            if isCoastal(prov) and prov != unit.province and
                prov notin reachable and prov notin ArmyAdj[unit.province]:
              reachable.add(prov)
      reachable.sort(proc (a, b: int): int =
        cmp(provinceCode(a), provinceCode(b)))
      for dest in reachable:
        moves.add(formatOrder(Order(unit: unit, kind: okMove, target: dest,
          viaConvoy: true, auxFrom: -1, auxTo: -1)))
  else:
    var nodes = FleetAdj[unitNode(unit)]
    nodes.sort(proc (a, b: int): int =
      cmp(fleetNodeName(a), fleetNodeName(b)))
    for node in nodes:
      moves.add(formatOrder(Order(unit: unit, kind: okMove,
        target: FleetNodeProvince[node], targetCoast: FleetNodeCoast[node],
        auxFrom: -1, auxTo: -1)))

  ## Supports: every province this unit could enter is a province it can
  ## support into.
  var reach: seq[int]
  if unit.kind == ukArmy:
    reach = ArmyAdj[unit.province]
  else:
    for node in FleetAdj[unitNode(unit)]:
      let prov = FleetNodeProvince[node]
      if prov notin reach:
        reach.add(prov)
  reach.sort(proc (a, b: int): int = cmp(provinceCode(a), provinceCode(b)))

  for dest in reach:
    let seat = board.unitAt(dest)
    if seat >= 0 and not sameUnit(board.units[seat], unit):
      supportHolds.add(formatOrder(Order(unit: unit, kind: okSupportHold,
        target: -1, auxFrom: dest, auxTo: -1,
        auxKind: board.units[seat].kind)))
  for dest in reach:
    for other in board.units:
      if sameUnit(other, unit) or other.province == dest:
        continue
      if not canReach(other, dest):
        continue
      supportMoves.add(formatOrder(Order(unit: unit, kind: okSupportMove,
        target: -1, auxFrom: other.province, auxTo: dest,
        auxKind: other.kind)))

  if unit.kind == ukFleet and isSea(unit.province):
    let node = unitNode(unit)
    var armies: seq[Unit]
    for other in board.units:
      if other.kind != ukArmy or not isCoastal(other.province):
        continue
      var touches = false
      for coastNode in fleetNodesOf(other.province):
        if coastNode in FleetAdj[node]:
          touches = true
      if touches:
        armies.add(other)
    var coasts: seq[int]
    for coastNode in FleetAdj[node]:
      let prov = FleetNodeProvince[coastNode]
      if isCoastal(prov) and prov notin coasts:
        coasts.add(prov)
    coasts.sort(proc (a, b: int): int = cmp(provinceCode(a), provinceCode(b)))
    for army in armies:
      for dest in coasts:
        if dest == army.province:
          continue
        convoys.add(formatOrder(Order(unit: unit, kind: okConvoy, target: -1,
          auxFrom: army.province, auxTo: dest, auxKind: ukArmy)))

  result = holds & moves & supportHolds & supportMoves & convoys
  if result.len > MaxLegalOrders:
    result.setLen(MaxLegalOrders)

# ---- Retreats ---------------------------------------------------------------

type
  RetreatOrder* = object
    unit*: Unit
    to*: int        ## -1 = disband
    coast*: string
    ok*: bool
    why*: string

proc retreatDestinations*(board: Board, unit: Unit, attackerFrom: int,
    standoffs: seq[int]): seq[tuple[province: int, coast: string]] =
  ## Legal retreat squares: adjacent and legal for the unit, empty after the
  ## movement phase, not the attacker's origin, not a standoff province.
  if unit.kind == ukArmy:
    var dests = ArmyAdj[unit.province]
    dests.sort(proc (a, b: int): int = cmp(provinceCode(a), provinceCode(b)))
    for dest in dests:
      if dest == attackerFrom or dest in standoffs:
        continue
      if board.unitAt(dest) >= 0:
        continue
      result.add((dest, ""))
  else:
    var nodes = FleetAdj[unitNode(unit)]
    nodes.sort(proc (a, b: int): int =
      cmp(fleetNodeName(a), fleetNodeName(b)))
    for node in nodes:
      let dest = FleetNodeProvince[node]
      if dest == attackerFrom or dest in standoffs:
        continue
      if board.unitAt(dest) >= 0:
        continue
      result.add((dest, FleetNodeCoast[node]))

proc legalRetreats*(board: Board, unit: Unit, attackerFrom: int,
    standoffs: seq[int]): seq[string] =
  for dest in retreatDestinations(board, unit, attackerFrom, standoffs):
    result.add(unitLabel(unit) & " - " & locLabel(dest.province, dest.coast))
  result.add(unitLabel(unit) & " - D")

proc parseRetreat*(board: Board, power: int, raw: string,
    dislodged: seq[Dislodgement], standoffs: seq[int]): RetreatOrder =
  ## A missing, unparsable or illegal retreat is a disband — never an error.
  result = RetreatOrder(to: -1, ok: false, why: "parse")
  let tokens = normalize(raw)
  if tokens.len == 0:
    return
  var index = 0
  if isUnitToken(tokens[index]):
    inc index
  if index >= tokens.len:
    return
  let origin = parseLoc(tokens[index])
  inc index
  if origin.province < 0:
    return
  var unit: Unit
  var found = false
  for item in dislodged:
    if item.unit.province == origin.province and item.unit.power == power:
      unit = item.unit
      found = true
  if not found:
    result.why = "notthere"
    return
  result.unit = unit
  if index >= tokens.len:
    result.ok = true
    result.why = ""
    return
  if tokens[index] != "-":
    return
  inc index
  if index >= tokens.len:
    return
  if tokens[index] in ["D", "DISBAND"]:
    result.ok = true
    result.why = ""
    return
  let dest = parseLoc(tokens[index])
  if dest.province < 0:
    return
  var attackerFrom = -1
  for item in dislodged:
    if sameUnit(item.unit, unit):
      attackerFrom = item.attackerFrom
  for option in retreatDestinations(board, unit, attackerFrom, standoffs):
    if option.province == dest.province and
        (dest.coast.len == 0 or dest.coast == option.coast):
      result.to = option.province
      result.coast = option.coast
      result.ok = true
      result.why = ""
      return
  result.why = "nonadjacent"

# ---- Winter adjustments -----------------------------------------------------

type
  AdjustOrder* = object
    build*: bool
    unit*: Unit
    ok*: bool
    why*: string

proc buildSites*(board: Board, power: int): seq[tuple[province: int,
    coast: string, kind: UnitKind]] =
  ## Vacant home supply centres the power still owns, with the unit kinds
  ## each can take. `STP` builds a fleet only on a named coast.
  var homes = HomeCentres[power]
  homes.sort(proc (a, b: int): int = cmp(provinceCode(a), provinceCode(b)))
  for province in homes:
    if board.ownerOf(province) != power:
      continue
    if board.unitAt(province) >= 0:
      continue
    result.add((province, "", ukArmy))
    for node in fleetNodesOf(province):
      result.add((province, FleetNodeCoast[node], ukFleet))

proc legalBuilds*(board: Board, power: int): seq[string] =
  for site in buildSites(board, power):
    result.add("BUILD " & $site.kind & " " &
      locLabel(site.province, site.coast))

proc legalDisbands*(board: Board, power: int): seq[string] =
  for unit in board.units:
    if unit.power == power:
      result.add("DISBAND " & unitLabel(unit))

proc parseAdjustment*(board: Board, power: int, raw: string): AdjustOrder =
  ## `BUILD A PAR` / `DISBAND F BRE`. Illegal adjustments are waived (builds)
  ## or replaced by civil disorder (disbands) upstream.
  result = AdjustOrder(ok: false, why: "parse")
  let tokens = normalize(raw)
  if tokens.len < 2:
    return
  var index = 0
  var isBuild = true
  if tokens[0] in ["BUILD", "B"]:
    isBuild = true
    index = 1
  elif tokens[0] in ["DISBAND", "REMOVE", "D"]:
    isBuild = false
    index = 1
  else:
    return
  if index >= tokens.len:
    return
  var kind = ukArmy
  if isUnitToken(tokens[index]):
    kind = if tokens[index] in ["F", "FLEET"]: ukFleet else: ukArmy
    inc index
  if index >= tokens.len:
    return
  let loc = parseLoc(tokens[index])
  if loc.province < 0:
    return
  result.build = isBuild
  if isBuild:
    for site in buildSites(board, power):
      if site.province == loc.province and site.kind == kind and
          (loc.coast.len == 0 or loc.coast == site.coast) and
          (kind == ukArmy or site.coast.len > 0 or
            fleetNodesOf(loc.province).len == 1):
        result.unit = Unit(power: power, kind: kind, province: loc.province,
          coast: site.coast)
        result.ok = true
        result.why = ""
        return
    result.why = "notthere"
    return
  let seat = board.unitAt(loc.province)
  if seat < 0 or board.units[seat].power != power:
    result.why = "notthere"
    return
  result.unit = board.units[seat]
  result.ok = true
  result.why = ""
