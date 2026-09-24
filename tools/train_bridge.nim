## Persistent numeric decision bridge over the native Cogplomacy simulator.

import std/[json, os]
import cogplomacy/llm

const Variants = ["standard", "gunboat"]

var
  game: Sim
  seats: seq[int]
  cursor: int
  decisionId: int
  choices: array[Seats, int]
  variant: string

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc currentDecision(): JsonNode =
  let seat = seats[cursor]
  let system = systemPrompt(game, seat)
  let user = userPrompt(game, seat, "")
  %*{"kind": "decision", "game": "cogplomacy",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": (game.year - StartYear) * 8 + ord(game.season) * 4 + ord(game.phase),
    "semantic_view": {"system": system, "user": user},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 1}},
      "required": ["choice"]}, "typed_question": newJNull()}

proc encoding(): JsonNode =
  let power = game.powerOf[seats[cursor]]
  var values = newJArray()
  for name in Variants:
    values.add(%(if variant == name: 1 else: 0))
  for other in 0 ..< Powers:
    values.add(%(if other == power: 1 else: 0))
  for phase in [pkPress, pkOrders, pkRetreats, pkBuilds]:
    values.add(%(if game.phase == phase: 1 else: 0))
  for season in Season:
    values.add(%(if game.season == season: 1 else: 0))
  values.add(%(float(game.year - StartYear) / float(game.config.years)))
  for other in 0 ..< Powers:
    values.add(%(float(game.centresOfPower(other)) / float(TotalCentres)))
  for owner in game.board.owner:
    values.add(%(float(owner + 1) / float(Powers)))
  var occupied: array[NumProvinces, int]
  var kind: array[NumProvinces, int]
  for unit in game.board.units:
    occupied[unit.province] = unit.power + 1
    kind[unit.province] = ord(unit.kind) + 1
  for province in 0 ..< NumProvinces:
    values.add(%(float(occupied[province]) / float(Powers)))
    values.add(%(float(kind[province]) / 2.0))
  doAssert values.len == 208
  %*{"decision_id": decisionId, "values": values,
    "actions": [{"choice": 0}, {"choice": 1}]}

proc reset(request: JsonNode, manifestPath: string): JsonNode =
  doAssert request["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %seedOf(request["seed"].getStr())
  var config = defaultGameConfig()
  config.update($variantConfig)
  game = initSim(config.sampleEpisode())
  seats = game.pendingSeats()
  cursor = 0
  decisionId = 0
  choices = [0, 0, 0, 0, 0, 0, 0]
  currentDecision()

proc step(request: JsonNode): JsonNode =
  doAssert request["decision_id"].getInt() == decisionId
  let action = parseJson(request["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 .. 1
  choices[seats[cursor]] = choice
  inc cursor
  inc decisionId
  if cursor == seats.len:
    let phase = game.phase
    var decisions: seq[Decision]
    for seat in seats:
      let kind = if choices[seat] == 0: skExpander else: skHedgehog
      decisions.add(scriptedDecision(game, seat, kind))
    for index, seat in seats:
      let decision = decisions[index]
      case phase
      of pkPress:
        game.applyPress(seat, decision.broadcast, decision.letters,
          decision.pledges, decision.notes, true)
      of pkOrders:
        game.applyOrders(seat, decision.orders, decision.notes, true)
      of pkRetreats:
        game.applyRetreats(seat, decision.retreats, decision.notes, true)
      of pkBuilds:
        game.applyBuilds(seat, decision.adjustments, decision.notes, true)
      of pkDone:
        raise newException(ValueError, "completed phase has pending seats")
    seats = game.pendingSeats()
    cursor = 0
  let observation = if game.done:
    var scores = newJObject()
    var utilities = newJObject()
    for seat in 0 ..< Seats:
      let score = game.score(seat)
      scores[$seat] = %score
      utilities[$seat] = %score
    %*{"kind": "terminal", "scores": scores,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action,
    "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: cogplomacy-train-bridge MANIFEST VARIANT", 1)
  let manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in Variants
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request, manifestPath)
      of "encode": encoding()
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
