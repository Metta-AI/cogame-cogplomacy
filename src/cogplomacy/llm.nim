## Claude-backed decision making for Cogplomacy. Each seat's policy is just
## a prompt: the game server composes the seat's view (the whole board, the
## ownership table, two years of history, the press it received, its notes)
## plus that seat's prompt and asks Claude what it writes and what it
## orders.
##
## All seven powers decide SIMULTANEOUSLY by rule, so every phase fires its
## requests as ONE parallel batch (`curly.makeRequests`) — never seat by
## seat. An invalid reply joins one retry batch carrying a hint; anything
## still failing is answered by the `expander` baseline.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing.

import
  std/[algorithm, json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

export sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  Far = high(int) div 4

type
  ScriptKind* = enum
    skNone = "none"
    skExpander = "expander"
    skHedgehog = "hedgehog"

  Decision* = object
    broadcast*: string
    letters*: seq[Letter]
    pledges*: seq[Pledge]
    orders*: seq[string]
    retreats*: seq[string]
    adjustments*: seq[string]
    notes*: string

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "expander"/"1"/"true"/"yes" play the greedy
  ## expander, "hedgehog"/"turtle" the wall, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "expander", "greedy": skExpander
  of "hedgehog", "turtle", "wall": skHedgehog
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "cogplomacy llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another. Haiku leads: hosted Bedrock capacity is shared
  ## account-wide and the sonnet profiles run out of daily tokens first.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "cogplomacy llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "cogplomacy llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel],
      ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "cogplomacy llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "cogplomacy llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

proc targetCentres(sim: Sim, power: int): seq[int] =
  for province in SupplyCentres:
    if sim.board.ownerOf(province) != power:
      result.add(province)

proc armyGoalDistance(sim: Sim, power: int): seq[int] =
  ## Multi-source BFS on the army graph: hops from every province to the
  ## nearest supply centre this power does NOT own.
  result = newSeq[int](NumProvinces)
  for index in 0 ..< NumProvinces:
    result[index] = Far
  var queue: seq[int]
  for province in sim.targetCentres(power):
    if Provinces[province].kind != pkSea:
      result[province] = 0
      queue.add(province)
  var head = 0
  while head < queue.len:
    let node = queue[head]
    inc head
    for next in ArmyAdj[node]:
      if result[next] == Far:
        result[next] = result[node] + 1
        queue.add(next)

proc fleetGoalDistance(sim: Sim, power: int): seq[int] =
  ## The same on the fleet-node graph, indexed by fleet node.
  result = newSeq[int](NumFleetNodes)
  for index in 0 ..< NumFleetNodes:
    result[index] = Far
  var queue: seq[int]
  for province in sim.targetCentres(power):
    for node in fleetNodesOf(province):
      if result[node] == Far:
        result[node] = 0
        queue.add(node)
  var head = 0
  while head < queue.len:
    let node = queue[head]
    inc head
    for next in FleetAdj[node]:
      if result[next] == Far:
        result[next] = result[node] + 1
        queue.add(next)

type MoveOption = object
  dest: int
  coast: string
  rank: int    ## with the Spring home-centre penalty, for ordering
  base: int    ## the note's (a)/(b)/(c)/(d) before that penalty

proc rankMove(sim: Sim, power: int, unit: Unit, dest: int,
    originDist, destDist: int): int =
  ## (a) unowned neutral centre, (b) a rival's unoccupied centre,
  ## (c) closes the distance, (d) anything else.
  let owner = sim.board.ownerOf(dest)
  let occupied = sim.board.unitAt(dest) >= 0
  if Provinces[dest].isCentre and owner < 0:
    return 0
  if Provinces[dest].isCentre and owner >= 0 and owner != power and
      not occupied:
    return 1
  if destDist < originDist:
    return 2
  3

proc expanderOrders(sim: Sim, power: int): seq[string] =
  let armyDist = sim.armyGoalDistance(power)
  let fleetDist = sim.fleetGoalDistance(power)
  var mine = sim.unitsOf(power)
  mine.sort(proc (a, b: Unit): int =
    cmp(provinceCode(a.province), provinceCode(b.province)))
  var claimed: seq[int]
  var chosen: seq[tuple[unit: Unit, dest: int, coast: string, rank: int]]
  for unit in mine:
    let originDist =
      if unit.kind == ukArmy: armyDist[unit.province]
      else: fleetDist[unitNode(unit)]
    var options: seq[MoveOption]
    if unit.kind == ukArmy:
      for dest in ArmyAdj[unit.province]:
        let base = sim.rankMove(power, unit, dest, originDist, armyDist[dest])
        var rank = base
        ## In Spring, a move that vacates an owned, unoccupied home centre
        ## drops one rank; in Fall the centres are taken regardless.
        if sim.season == seSpring and Provinces[unit.province].isCentre and
            Provinces[unit.province].homePower == power and
            sim.board.ownerOf(unit.province) == power:
          rank += 1
        options.add(MoveOption(dest: dest, coast: "", rank: rank, base: base))
    else:
      for node in FleetAdj[unitNode(unit)]:
        let dest = FleetNodeProvince[node]
        let base = sim.rankMove(power, unit, dest, originDist, fleetDist[node])
        var rank = base
        if sim.season == seSpring and Provinces[unit.province].isCentre and
            Provinces[unit.province].homePower == power and
            sim.board.ownerOf(unit.province) == power:
          rank += 1
        options.add(MoveOption(dest: dest, coast: FleetNodeCoast[node],
          rank: rank, base: base))
    options.sort(proc (a, b: MoveOption): int =
      if a.rank != b.rank: cmp(a.rank, b.rank)
      elif a.dest != b.dest: cmp(provinceCode(a.dest), provinceCode(b.dest))
      else: cmp(a.coast, b.coast))
    var picked = MoveOption(dest: -1, coast: "", rank: 3, base: 3)
    for option in options:
      if option.rank > 2:
        break
      if option.dest in claimed:
        continue
      ## Never walk into one of our own units that is staying put.
      let sitting = sim.board.unitAt(option.dest)
      if sitting >= 0 and sim.board.units[sitting].power == power:
        continue
      picked = option
      break
    if picked.dest >= 0:
      claimed.add(picked.dest)
    chosen.add((unit, picked.dest, picked.coast, picked.base))

  ## A unit whose own best option is only rank (c) — a move that merely
  ## closes the distance — or (d) supports one of ours that is moving
  ## instead, whenever it can reach that destination. Only units that are
  ## really moving are supported, so the baseline never writes a void
  ## support.
  var moving: seq[bool]
  for entry in chosen:
    moving.add(entry.dest >= 0 and entry.rank <= 1)
  for index, entry in chosen:
    if not moving[index]:
      var helped = false
      for other in 0 ..< chosen.len:
        if other == index or not moving[other]:
          continue
        if not canReach(entry.unit, chosen[other].dest):
          continue
        result.add(unitLabel(entry.unit) & " S " &
          $chosen[other].unit.kind & " " &
          provinceCode(chosen[other].unit.province) & " - " &
          provinceCode(chosen[other].dest))
        helped = true
        break
      if helped:
        continue
      if entry.dest >= 0:
        moving[index] = true
    if moving[index]:
      result.add(unitLabel(entry.unit) & " - " & provinceCode(entry.dest) &
        (if entry.coast.len > 0: "/" & entry.coast else: ""))
    else:
      result.add(unitLabel(entry.unit) & " H")

proc hedgehogOrders(sim: Sim, power: int): seq[string] =
  ## The wall: everything holds, and a unit next to one of our own units
  ## sitting on a centre we own props it up instead.
  var mine = sim.unitsOf(power)
  mine.sort(proc (a, b: Unit): int =
    cmp(provinceCode(a.province), provinceCode(b.province)))
  for unit in mine:
    var neighbours: seq[Unit]
    for other in mine:
      if sameUnit(other, unit):
        continue
      if not Provinces[other.province].isCentre:
        continue
      if sim.board.ownerOf(other.province) != power:
        continue
      if canReach(unit, other.province):
        neighbours.add(other)
    neighbours.sort(proc (a, b: Unit): int =
      cmp(provinceCode(a.province), provinceCode(b.province)))
    if neighbours.len > 0:
      result.add(unitLabel(unit) & " S " & $neighbours[0].kind & " " &
        provinceCode(neighbours[0].province))
    else:
      result.add(unitLabel(unit) & " H")

proc scriptedRetreats(sim: Sim, power: int, kind: ScriptKind): seq[string] =
  let armyDist = sim.armyGoalDistance(power)
  let fleetDist = sim.fleetGoalDistance(power)
  for item in sim.dislodged:
    if item.unit.power != power:
      continue
    let options = retreatDestinations(sim.board, item.unit,
      item.attackerFrom, sim.standoffs, sim.dislodged)
    var best = -1
    var bestCoast = ""
    var bestScore = Far
    for option in options:
      var score = Far
      if kind == skHedgehog:
        for home in HomeCentres[power]:
          if sim.board.ownerOf(home) != power:
            continue
          let distances =
            if item.unit.kind == ukArmy: bfsDistance(option.province, false)
            else: bfsDistance(fleetNode(option.province, option.coast), true)
          if distances[home] < score:
            score = distances[home]
      else:
        score =
          if item.unit.kind == ukArmy: armyDist[option.province]
          else: fleetDist[fleetNode(option.province, option.coast)]
      if score < bestScore or (score == bestScore and best >= 0 and
          provinceCode(option.province) < provinceCode(best)):
        bestScore = score
        best = option.province
        bestCoast = option.coast
    if best < 0:
      result.add(unitLabel(item.unit) & " - D")
    else:
      result.add(unitLabel(item.unit) & " - " & provinceCode(best) &
        (if bestCoast.len > 0: "/" & bestCoast else: ""))

proc scriptedBuilds(sim: Sim, power: int, kind: ScriptKind): seq[string] =
  let delta = sim.centresOfPower(power) - sim.unitCount(power)
  if delta <= 0:
    ## Disbands are left to the civil-disorder rule.
    return
  var fleets = 0
  var armies = 0
  for unit in sim.board.units:
    if unit.power != power:
      continue
    if unit.kind == ukFleet: inc fleets else: inc armies
  let sites = buildSites(sim.board, power)
  var provinces: seq[int]
  for site in sites:
    if site.province notin provinces:
      provinces.add(site.province)
  var built = 0
  for province in provinces:
    if built >= delta:
      break
    ## One build per centre, and the kind is decided once for the centre: a
    ## fleet when it is coastal and the power holds fewer fleets than armies,
    ## otherwise an army. Of a split coast's sites take the one with the most
    ## water to move on, which is what makes `STP` build `F STP/SC`.
    var chosen = -1
    if kind != skHedgehog and fleets < armies:
      for index, site in sites:
        if site.province != province or site.kind != ukFleet:
          continue
        if chosen < 0 or FleetAdj[fleetNode(province, site.coast)].len >
            FleetAdj[fleetNode(province, sites[chosen].coast)].len:
          chosen = index
    if chosen < 0:
      for index, site in sites:
        if site.province == province and site.kind == ukArmy and chosen < 0:
          chosen = index
    if chosen < 0:
      continue
    let site = sites[chosen]
    result.add("BUILD " & $site.kind & " " & provinceCode(site.province) &
      (if site.coast.len > 0: "/" & site.coast else: ""))
    if site.kind == ukFleet: inc fleets else: inc armies
    inc built

proc scriptedDecision*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Rule-based baseline for `seat`. Always legal; never talks or notes.
  let power = sim.powerOf[seat]
  case sim.phase
  of pkPress:
    discard
  of pkOrders:
    result.orders =
      if kind == skHedgehog: sim.hedgehogOrders(power)
      else: sim.expanderOrders(power)
  of pkRetreats:
    result.retreats = sim.scriptedRetreats(power, kind)
  of pkBuilds:
    result.adjustments = sim.scriptedBuilds(power, kind)
  of pkDone:
    discard

# ---- Prompt building --------------------------------------------------------

proc seasonWord(season: Season): string =
  case season
  of seSpring: "SPRING"
  of seFall: "FALL"
  of seWinter: "WINTER"

proc systemPrompt*(sim: Sim, seat: int): string =
  ## The in-game name space is anonymous: a seat is only ever a POWER. No
  ## policy name, player name or slot number is ever interpolated here.
  let power = sim.powerOf[seat]
  var others: seq[string]
  for other in 0 ..< Powers:
    if other != power:
      others.add(PowerNames[other])
  let othersText = others[0 ..< others.high].join(", ") & " and " & others[^1]
  "You are " & PowerNames[power] & ", one of seven great powers in a game " &
    "of Diplomacy on the 1901 map of\nEurope. The other powers are " &
    othersText & ", each\nplayed by a different cog. You never learn who " &
    "plays them.\n" & """
Rules:
- Armies move on land, fleets on coasts and seas. Every unit has equal
  strength; a unit moves into a province only if it out-supports whatever
  opposes it, and equal strength means a STANDOFF and nobody moves.
- Orders: HOLD, MOVE, SUPPORT (a hold or a move) and CONVOY (a fleet at sea
  carrying an army between coasts). All seven powers order at the same time
  and see nothing of each other's orders until they resolve.
- A supported attack that beats the defence DISLODGES the defender, which
  must retreat or disband. You may never dislodge your own unit or help
  anyone dislodge it.
- After every Fall, whoever occupies a supply centre owns it. Owning more
  centres than units lets you build at home in Winter; owning fewer forces
  you to disband.
- Hold 18 of the 34 supply centres and you win outright. Otherwise you are
  scored on your share of the 34 centres when the game stops. Nothing else
  scores.
- PRESS IS NOT BINDING. You may promise anything to anyone and then order
  the opposite. So may they. Alliances are the only way to grow and betrayal
  is the only way to win.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else — no
analysis, no explanation, no markdown fences, no text before or after the
object. Your reply must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc boardBlock(sim: Sim): string =
  var lines: seq[string]
  for power in 0 ..< Powers:
    var pieces: seq[string]
    for unit in sim.board.units:
      if unit.power == power:
        pieces.add($unit.kind & " " & provinceName(unit.province) &
          (if unit.coast.len > 0: " (" & unit.coast & ")" else: ""))
    pieces.sort(system.cmp[string])
    lines.add(PowerNames[power] & " — " & $sim.centresOfPower(power) &
      " centres, " & $sim.unitCount(power) & " units: " &
      (if pieces.len > 0: pieces.join("; ") else: "(no units)"))
  "THE BOARD:\n" & lines.join("\n") & "\n\n"

proc ownershipBlock(sim: Sim): string =
  var lines: seq[string]
  for slot in 0 ..< NumCentres:
    let province = SupplyCentres[slot]
    let owner = sim.board.owner[slot]
    lines.add(provinceName(province) & " (" & provinceCode(province) & "): " &
      (if owner < 0: "neutral" else: PowerNames[owner]))
  "SUPPLY CENTRES (34):\n" & lines.join("; ") & "\n\n"

proc historyBlock(sim: Sim): string =
  if sim.history.len == 0:
    return "RECENT ORDERS: (none yet)\n\n"
  var blocks: seq[string]
  for record in sim.history:
    blocks.add(seasonWord(record.season) & " " & $record.year & "\n" &
      record.lines.join("\n"))
  "RECENT ORDERS AND RESULTS:\n" & blocks.join("\n\n") & "\n\n"

proc pressBlock(sim: Sim, power: int): string =
  var lines: seq[string]
  for letter in sim.pressLast:
    if letter.toPower < 0:
      lines.add("[last phase] " & PowerNames[letter.fromPower] &
        " broadcast: \"" & letter.text & "\"")
    elif letter.toPower == power:
      lines.add("[last phase] " & PowerNames[letter.fromPower] &
        " wrote to you: \"" & letter.text & "\"")
  for letter in sim.press:
    if letter.toPower < 0:
      lines.add(PowerNames[letter.fromPower] & " broadcast: \"" &
        letter.text & "\"")
    elif letter.toPower == power:
      lines.add(PowerNames[letter.fromPower] & " wrote to you: \"" &
        letter.text & "\"")
  for pledge in sim.pledges:
    if pledge.fromPower == power:
      continue
    if pledge.toPower < 0 or pledge.toPower == power:
      lines.add(PowerNames[pledge.fromPower] & " pledged " & $pledge.kind &
        (if pledge.province >= 0: " (" & provinceName(pledge.province) & ")"
         else: "") &
        (if pledge.toPower < 0: " to everyone" else: " to you"))
  "PRESS YOU HAVE RECEIVED:\n" &
    (if lines.len > 0: lines.join("\n") else: "(none)") & "\n\n"

proc legalOrdersBlock(sim: Sim, power: int): string =
  var blocks: seq[string]
  var mine = sim.unitsOf(power)
  mine.sort(proc (a, b: Unit): int =
    cmp(provinceCode(a.province), provinceCode(b.province)))
  for unit in mine:
    blocks.add(unitLabel(unit) & " in " & provinceName(unit.province) & ":\n  " &
      legalOrders(sim.board, unit).join("\n  "))
  "YOUR UNITS AND EVERY LEGAL ORDER:\n" & blocks.join("\n") & "\n\n"

proc retreatBlock(sim: Sim, power: int): string =
  var lines: seq[string]
  for item in sim.dislodged:
    if item.unit.power != power:
      continue
    lines.add(unitLabel(item.unit) & " was dislodged from " &
      provinceName(item.unit.province) & " by an attack out of " &
      provinceName(item.attackerFrom) & ". Legal: " &
      legalRetreats(sim.board, item.unit, item.attackerFrom,
        sim.standoffs, sim.dislodged).join(", ") & " (disband).")
  lines.join("\n") & "\n\n"

proc buildBlock(sim: Sim, power: int): string =
  let delta = sim.centresOfPower(power) - sim.unitCount(power)
  if delta > 0:
    var sites: seq[string]
    for option in legalBuilds(sim.board, power):
      sites.add(option)
    return "You own " & $sim.centresOfPower(power) & " centres and have " &
      $sim.unitCount(power) & " units: build " & $delta & ". Legal builds: " &
      (if sites.len > 0: sites.join(", ") else: "(none — the entitlement is waived)") &
      "\n\n"
  "You own " & $sim.centresOfPower(power) & " centres and have " &
    $sim.unitCount(power) & " units: disband " & $(-delta) &
    ". Legal disbands: " & legalDisbands(sim.board, power).join(", ") & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let power = sim.powerOf[seat]
  let head = seasonWord(sim.season) & " " & $sim.year
  result.add(head & " — " & ($sim.phase).toUpperAscii() & ". Year " &
    $(sim.yearsPlayed + 1) & " of " & $sim.config.years & ".\n\n")
  result.add(sim.boardBlock())
  result.add(sim.ownershipBlock())
  result.add(sim.historyBlock())
  if sim.config.press:
    result.add(sim.pressBlock(power))
  result.add("YOUR NOTES:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  case sim.phase
  of pkPress:
    result.add("Reply with ONLY {\"broadcast\":\"…\"," &
      "\"letters\":[{\"to\":\"ITALY\",\"text\":\"…\"}]," &
      "\"pledges\":[{\"to\":\"ITALY\",\"kind\":\"peace\"}],\"notes\":\"…\"}" &
      " — broadcast at most " & $MaxBroadcastLen & " characters, at most " &
      $MaxLetters & " letters of at most " & $MaxLetterLen &
      " characters each (one per power), at most " & $MaxPledges &
      " pledges, notes at most " & $MaxNotesLen & " characters. A pledge " &
      "kind is peace, keepout (with a \"province\" code) or support. A " &
      "pledge is the only promise spectators can see you break; free text " &
      "is never checked.")
  of pkOrders:
    result.add(sim.legalOrdersBlock(power))
    result.add("Reply with ONLY {\"orders\":[\"A PAR - BUR\"," &
      "\"F BRE S A PAR - BUR\"],\"notes\":\"…\"} — exactly one order per " &
      "unit, copied character for character from the list above. An order " &
      "that is not on the list becomes a hold.")
  of pkRetreats:
    result.add(sim.retreatBlock(power))
    result.add("Reply with ONLY {\"retreats\":[\"A VIE - TYR\"]," &
      "\"notes\":\"…\"} — one entry per dislodged unit; " &
      "\"A VIE - D\" disbands it.")
  of pkBuilds:
    result.add(sim.buildBlock(power))
    result.add("Reply with ONLY {\"adjustments\":[\"BUILD A PAR\"]," &
      "\"notes\":\"…\"} (or \"DISBAND F BRE\" when you must remove units).")
  of pkDone:
    discard

# ---- Reply parsing ----------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(CogplomacyError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc stringList(node: JsonNode, limit: int): seq[string] =
  if node.isNil or node.kind != JArray:
    return
  for item in node:
    if result.len >= limit:
      break
    if item.kind == JString:
      result.add(cleanText(oneLine(item.getStr()), MaxOrderLen))

proc parsePress(sim: Sim, power: int, payload: JsonNode): Decision =
  let broadcast = payload{"broadcast"}
  let letters = payload{"letters"}
  if (broadcast.isNil or broadcast.kind != JString) and
      (letters.isNil or letters.kind != JArray):
    raise newException(CogplomacyError, "no broadcast or letters in reply")
  if not broadcast.isNil and broadcast.kind == JString:
    result.broadcast = cleanText(oneLine(broadcast.getStr()),
      MaxBroadcastLen)
  if not letters.isNil and letters.kind == JArray:
    for item in letters:
      if result.letters.len >= MaxLetters:
        break
      if item.kind != JObject:
        continue
      ## `to` is a power name or ALL (case-insensitive); an ALL letter is
      ## published to everybody. Only an unknown recipient is dropped.
      let toText = item{"to"}.getStr().strip().toUpperAscii()
      var to = -1
      if toText != "ALL":
        to = powerByName(toText)
        if to < 0 or to == power:
          continue
      result.letters.add(Letter(fromPower: power, toPower: to,
        text: cleanText(oneLine(item{"text"}.getStr()), MaxLetterLen)))
  let pledges = payload{"pledges"}
  if not pledges.isNil and pledges.kind == JArray:
    for item in pledges:
      if result.pledges.len >= MaxPledges:
        break
      if item.kind != JObject:
        continue
      var kind: PledgeKind
      case item{"kind"}.getStr().strip().toLowerAscii()
      of "peace": kind = plPeace
      of "keepout", "keep out", "keep-out": kind = plKeepOut
      of "support": kind = plSupport
      else: continue
      let toText = item{"to"}.getStr().strip().toUpperAscii()
      var to = -1
      if toText != "ALL" and toText.len > 0:
        to = powerByName(toText)
        if to < 0:
          continue
      var province = -1
      if kind == plKeepOut:
        province = provinceByCode(item{"province"}.getStr())
        if province < 0:
          continue
      result.pledges.add(Pledge(fromPower: power, toPower: to, kind: kind,
        province: province))
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)

proc parseOrdersReply(payload: JsonNode): Decision =
  let node = payload{"orders"}
  if node.isNil or node.kind != JArray:
    raise newException(CogplomacyError, "no orders array in reply")
  result.orders = stringList(node, MaxOrdersPerReply)
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)

proc parseRetreatsReply(payload: JsonNode): Decision =
  let node = payload{"retreats"}
  if node.isNil or node.kind != JArray:
    raise newException(CogplomacyError, "no retreats array in reply")
  result.retreats = stringList(node, MaxRetreatsPerReply)
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)

proc parseBuildsReply(payload: JsonNode): Decision =
  let node = payload{"adjustments"}
  if node.isNil or node.kind != JArray:
    raise newException(CogplomacyError, "no adjustments array in reply")
  result.adjustments = stringList(node, MaxAdjustmentsPerReply)
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)

proc parseDecision*(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## A reply is invalid only when it is not a JSON object or the phase's
  ## required key is missing or of the wrong kind. Illegal CONTENTS — a bad
  ## order, an unknown recipient — are repaired, never rejected.
  if payload.isNil or payload.kind != JObject:
    raise newException(CogplomacyError, "reply is not a JSON object")
  case sim.phase
  of pkPress: parsePress(sim, sim.powerOf[seat], payload)
  of pkOrders: parseOrdersReply(payload)
  of pkRetreats: parseRetreatsReply(payload)
  of pkBuilds: parseBuildsReply(payload)
  of pkDone: Decision()

# ---- Anthropic / Bedrock transport ------------------------------------------

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a CogplomacyError describing why
  ## there is none. Auth failures disable the client; model-access and
  ## throttle failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(CogplomacyError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(CogplomacyError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(CogplomacyError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(CogplomacyError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(CogplomacyError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(CogplomacyError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(CogplomacyError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order, for the CURRENT phase.
  ## Every live seat's request goes out in ONE parallel batch — this is a
  ## simultaneous-decision game and a serial loop would blow the play
  ## budget. Never raises: any failure falls back to the scripted baseline
  ## so the episode always advances.
  result = newSeq[Decision](seats.len)
  var open: seq[int]
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedDecision(sim, seat,
        (if kind == skNone: skExpander else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\n\nYour previous reply was invalid. Respond with ONLY " &
          "the requested JSON object.")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        result[index] = sim.parseDecision(seat, extractJsonObject(text))
      except CatchableError as error:
        echo "cogplomacy llm: seat ", seat, " attempt ", attempt,
          " failed: ", error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "cogplomacy: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedDecision(sim, seat, skExpander)
