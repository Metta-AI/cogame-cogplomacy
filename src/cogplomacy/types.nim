## Shared value types for Cogplomacy: the runtime config, the pieces on the
## board, orders and their results, press letters and pledges, and the flat
## event record the replay is made of.
##
## Forked from `cogame-bullwhip/src/bullwhip/types.nim`: same GameConfig
## shape and the same `update()` contract, with `years` in place of `weeks`
## and `press` in place of `talk`.

import std/[json, strutils], mapdata

export mapdata

type
  CogplomacyError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    years*: int           ## game-years played, starting at 1901
    press*: bool          ## a press phase before each movement phase
    episodeTimeoutSeconds*: int ## assumed platform kill time when env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  UnitKind* = enum
    ukArmy = "A"
    ukFleet = "F"

  Unit* = object
    power*: int
    kind*: UnitKind
    province*: int
    coast*: string     ## "" unless the fleet sits on a split coast

  OrderKind* = enum
    okHold = "hold"
    okMove = "move"
    okSupportHold = "supporthold"
    okSupportMove = "supportmove"
    okConvoy = "convoy"

  Order* = object
    power*: int
    unit*: Unit
    kind*: OrderKind
    target*: int          ## move destination province; -1 otherwise
    targetCoast*: string  ## named coast of the destination
    auxFrom*: int         ## supported/convoyed unit's province; -1 otherwise
    auxTo*: int           ## its destination; -1 otherwise
    auxCoast*: string     ## named coast of the supported destination
    auxKind*: UnitKind    ## kind of the supported/convoyed unit
    viaConvoy*: bool
    raw*: string          ## the string as submitted
    illegal*: bool
    why*: string          ## parse | nonadjacent | wrongunit | notthere |
                          ## noconvoy | ambiguouscoast

  Outcome* = enum
    orSuccess = "success"
    orBounce = "bounce"
    orVoid = "void"
    orNoConvoy = "noconvoy"
    orDislodged = "dislodged"
    orCut = "cut"
    orIllegal = "illegal"

  OrderResult* = object
    order*: Order
    outcome*: Outcome

  Dislodgement* = object
    unit*: Unit
    attackerFrom*: int   ## province the successful attack came out of

  Letter* = object
    fromPower*: int
    toPower*: int        ## -1 = ALL (a public broadcast)
    text*: string

  PledgeKind* = enum
    plPeace = "peace"
    plKeepOut = "keepout"
    plSupport = "support"

  Pledge* = object
    fromPower*: int
    toPower*: int        ## -1 = ALL
    kind*: PledgeKind
    province*: int       ## keepout only; -1 otherwise
    broken*: bool
    brokenBy*: string    ## the offending order, in canonical notation

  Season* = enum
    seSpring = "spring"
    seFall = "fall"
    seWinter = "winter"

  PhaseKind* = enum
    pkPress = "press"
    pkOrders = "orders"
    pkRetreats = "retreats"
    pkBuilds = "builds"
    pkDone = "done"

  EventKind* = enum
    evStart = "start"
    evPhase = "phase"
    evPress = "press"
    evOrders = "orders"
    evAdjudicate = "adjudicate"
    evRetreat = "retreat"
    evBuild = "build"
    evCentres = "centres"
    evEnd = "end"

  StabRecord* = object
    seat*: int
    power*: int
    pledgeTo*: int       ## -1 = ALL
    kind*: PledgeKind
    province*: int       ## the province the pledge named; -1 when none
    order*: string

  IllegalRecord* = object
    raw*: string
    why*: string

  AdjustAction* = object
    action*: string      ## "build" | "disband"
    unit*: Unit

  RetreatMove* = object
    unit*: Unit
    to*: int             ## -1 = disband
    coast*: string

  Board* = object
    ## The position: every unit on the map and who owns each supply centre.
    ## Split coasts share one province for occupancy and ownership.
    units*: seq[Unit]
    owner*: array[NumCentres, int]   ## centre slot -> power index, or -1

  GameEvent* = object
    kind*: EventKind
    year*: int
    season*: Season
    phaseKind*: PhaseKind
    seat*: int           ## -1 when the event is not a seat's
    power*: int          ## -1 when the event is not a power's
    scripted*: bool
    text*: string        ## press/orders: the seat's notes; end: the reason
    broadcast*: string
    letters*: seq[Letter]
    pledges*: seq[Pledge]
    orders*: seq[string]
    illegal*: seq[IllegalRecord]
    results*: seq[OrderResult]
    dislodged*: seq[Dislodgement]
    standoffs*: seq[int]
    stabs*: seq[StabRecord]
    moves*: seq[RetreatMove]
    adjustments*: seq[AdjustAction]
    waived*: int
    units*: seq[Unit]
    owners*: seq[int]    ## 34 entries, power index or -1
    counts*: seq[int]    ## 7 entries
    gained*: seq[int]
    lost*: seq[int]
    powers*: seq[int]    ## start: seat -> power index
    soloist*: int        ## end: the soloing power, or -1

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    years: 4,
    press: true,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 300,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 1200,
    llmTimeoutSeconds: 45
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(CogplomacyError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("years"):
    config.years = node["years"].getInt()
  if node.hasKey("press"):
    config.press = node["press"].getBool()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.years < 1:
    raise newException(CogplomacyError, "years must be at least 1")

# ---- Small helpers shared by every module -----------------------------------

proc unitNode*(unit: Unit): int =
  ## The fleet node a fleet stands on; -1 for an army.
  if unit.kind == ukFleet: fleetNode(unit.province, unit.coast) else: -1

proc sameUnit*(a, b: Unit): bool =
  a.power == b.power and a.kind == b.kind and a.province == b.province and
    a.coast == b.coast

proc unitLabel*(unit: Unit): string =
  ## "A PAR", "F STP/SC".
  result = $unit.kind & " " & provinceCode(unit.province)
  if unit.coast.len > 0:
    result.add("/" & unit.coast)

proc unitWords*(unit: Unit): string =
  ## "the army in Paris", spelled out for the feed.
  (if unit.kind == ukArmy: "army in " else: "fleet in ") &
    provinceName(unit.province)

proc unitAt*(board: Board, province: int): int =
  ## Index of the unit standing in a province, or -1. Occupancy is by
  ## province, never by coast.
  for index, unit in board.units:
    if unit.province == province:
      return index
  -1

proc ownerOf*(board: Board, province: int): int =
  ## Power owning the supply centre in a province; -1 for neutral or for a
  ## province that is not a centre.
  let slot = CentreIndex[province]
  if slot < 0: -1 else: board.owner[slot]

proc emptyBoard*(): Board =
  for slot in 0 ..< NumCentres:
    result.owner[slot] = -1

proc startBoard*(): Board =
  ## Spring 1901: the 22 opening units and the 22 home centres.
  result = emptyBoard()
  for spec in StartUnitSpec:
    result.units.add(Unit(
      power: spec[0],
      kind: (if spec[1] == "A": ukArmy else: ukFleet),
      province: provinceByCode(spec[2]),
      coast: spec[3]))
  for power in 0 ..< NumPowers:
    for province in HomeCentres[power]:
      result.owner[CentreIndex[province]] = power
