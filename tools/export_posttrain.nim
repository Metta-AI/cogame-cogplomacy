## Export complete games with the exact hosted prompt at each phase.

import std/[json, os, osproc, strutils]
import cogplomacy/llm

proc reply(phase: PhaseKind, decision: Decision): JsonNode =
  case phase
  of pkPress:
    %*{"broadcast": decision.broadcast, "letters": [], "pledges": [],
      "notes": decision.notes}
  of pkOrders:
    %*{"orders": decision.orders, "notes": decision.notes}
  of pkRetreats:
    %*{"retreats": decision.retreats, "notes": decision.notes}
  of pkBuilds:
    %*{"adjustments": decision.adjustments, "notes": decision.notes}
  of pkDone:
    raise newException(ValueError, "completed phase has no decision")

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: cogplomacy-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    var game = initSim(config.sampleEpisode())
    var rows: seq[string]
    var phases = 0
    while not game.done:
      inc phases
      doAssert phases <= 200
      let seats = game.pendingSeats()
      doAssert seats.len > 0
      let phase = game.phase
      var decisions: seq[Decision]
      for seat in seats:
        let baseline = if (seat + seed) mod 2 == 0:
          skExpander else: skHedgehog
        let teacher = scriptedDecision(game, seat, baseline)
        let completion = reply(phase, teacher)
        let accepted = parseDecision(game, seat, completion)
        doAssert accepted.orders == teacher.orders
        doAssert accepted.retreats == teacher.retreats
        doAssert accepted.adjustments == teacher.adjustments
        decisions.add(accepted)
        rows.add($(%*{
          "episode_id": "cogplomacy-" & variant & "-" & $seed,
          "seed": "cogplomacy-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(game, seat)},
            {"role": "user", "content": userPrompt(game, seat, "")}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "cogplomacy", "action_schema_revision": "cogplomacy-reply-v1"
        }))
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
    doAssert game.reason == "complete" or game.reason == "solo"
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    var scores = newJArray()
    for seat in 0 ..< Seats: scores.add(%game.score(seat))
    runs.add(%*{"seed": seed, "phases": phases, "decisions": rows.len,
      "scores": scores, "reason": game.reason})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "cogplomacy", "variant": variant,
    "source_revision": revision, "teacher": "expander-and-hedgehog",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
