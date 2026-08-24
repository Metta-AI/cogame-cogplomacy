import std/[json, os, sets, strutils, unicode, unittest]
import cogplomacy/llm

## The viewer's contract with the sim: the keys the renderer reads, strict
## UTF-8 in the replay bytes, and the naming guard on the appended chrome
## block.

proc repoDir(): string =
  currentSourcePath().parentDir().parentDir()

proc fixtureConfig(years = 2, seed = 12): GameConfig =
  result = defaultGameConfig()
  result.years = years
  result.seed = seed
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "Policy " & $(index + 1)))
    result.tokens.add("token-" & $index)

proc pressFixture(sim: var Sim) =
  ## A press phase full of multi-byte text, so the UTF-8 assertions below
  ## have something to bite on.
  let seats = sim.pendingSeats()
  for index, seat in seats:
    let power = sim.powerOf[seat]
    sim.applyPress(seat,
      "Bourgogne n'est à personne — gardons-nous-en. 🕊️ " & "é".repeat(600),
      @[Letter(toPower: (power + 1) mod Powers,
        text: "Piémont est à vous si Trieste est à moi 🤝 " &
          "ß".repeat(600))],
      @[Pledge(toPower: (power + 1) mod Powers, kind: plPeace,
        province: -1),
        Pledge(toPower: -1, kind: plKeepOut,
          province: provinceByCode("BUR"))],
      "notes… " & "漢".repeat(600), false)
    discard index

proc playOut(sim: var Sim) =
  var guard = 0
  while not sim.done and guard < 2000:
    inc guard
    for seat in sim.pendingSeats():
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
      of pkDone: discard

suite "the frame the renderer draws":
  test "tableStateJson carries every key the renderer reads":
    var sim = initSim(fixtureConfig())
    sim.pressFixture()
    let frame = sim.tableStateJson()
    for key in ["seats", "seatOfPower", "units", "owners", "arrows", "stabs",
        "standoffs", "year", "season", "phase", "years", "yearsPlayed",
        "counts", "press", "gameDone", "reason", "soloist"]:
      check frame.hasKey(key)
    check frame["seats"].len == Seats
    for seat in frame["seats"]:
      for key in ["power", "name", "centres", "units", "score", "pending",
          "eliminated", "stabbedThisTurn", "broadcast", "lettersOut",
          "pledges", "notes"]:
        check seat.hasKey(key)
    check frame["owners"].len == NumCentres
    for owner in frame["owners"]:
      check owner.hasKey("centre")
      check owner.hasKey("power")
    for unit in frame["units"]:
      for key in ["power", "kind", "province", "coast", "dislodged"]:
        check unit.hasKey(key)

  test "arrows carry a kind, endpoints, a power and an outcome":
    var sim = initSim(fixtureConfig(years = 1))
    sim.playOut()
    var seen = 0
    for frame in replayMatch(sim.config, sim.events):
      for arrow in frame.tableStateJson()["arrows"]:
        inc seen
        for key in ["kind", "from", "to", "aux", "power", "outcome"]:
          check arrow.hasKey(key)
        check arrow["kind"].getStr() in ["move", "support", "convoy"]
        check arrow["outcome"].getStr() in ["success", "bounce", "void",
          "noconvoy", "cut", "illegal", "dislodged"]
    check seen > 0

  test "the frame renders words and numerals, never internal notation":
    var sim = initSim(fixtureConfig(years = 1))
    sim.playOut()
    let text = $sim.tableStateJson()
    check "okSupportMove" notin text
    check "pkOrders" notin text
    check "ukArmy" notin text

suite "replay bytes":
  test "the payload is strict UTF-8 and re-parses":
    var sim = initSim(fixtureConfig(years = 2))
    sim.pressFixture()
    sim.playOut()
    var events = newJArray()
    for event in sim.events:
      events.add(eventToJson(event))
    var names = newJArray()
    var powers = newJArray()
    for seat in 0 ..< Seats:
      names.add(%sim.names[seat])
      powers.add(%PowerNames[sim.powerOf[seat]])
    let payload = $ %*{
      "protocol": "cogplomacy.replay.v1",
      "names": names,
      "powers": powers,
      "config": {"years": sim.config.years, "seed": sim.config.seed,
        "press": sim.config.press, "sampled": true},
      "events": events,
      "results": sim.resultsJson()
    }
    check validateUtf8(payload) == -1
    let reparsed = parseJson(payload)
    check reparsed["events"].len == sim.events.len
    ## And the states the wasm module derives from those bytes are UTF-8 too.
    var replayed: seq[GameEvent]
    for node in reparsed["events"]:
      replayed.add(eventFromJson(node))
    var states = newJArray()
    for frame in replayMatch(sim.config, replayed):
      states.add(frame.tableStateJson())
    check validateUtf8($states) == -1
    check states.len == sim.events.len + 1

  test "the bytes are self-sufficient: both name spaces and the config":
    var sim = initSim(fixtureConfig(years = 1))
    sim.playOut()
    let results = sim.resultsJson()
    check results["names"][0].getStr() == "Policy 1"
    check results["powers"].len == Seats
    check sim.names[0] != "Policy 1"

suite "the appended chrome block":
  test "it defines no name the copied chrome already defines":
    let source = readFile(repoDir() / "client" / "renderer.js")
    let marker = "cogplomacy additions to the inherited cogame-bullwhip chrome"
    let split = source.find(marker)
    check split > 0
    let chrome = source[0 ..< split]
    let appended = source[split .. ^1]

    proc identifierAfter(line, keyword: string): string =
      ## The name declared by a top-level `  function foo(` / `  var foo =`
      ## line, or "" when the line declares nothing.
      if not line.startsWith("  " & keyword & " "):
        return ""
      var rest = line[2 + keyword.len + 1 .. ^1]
      for index, letter in rest:
        if letter in IdentChars:
          continue
        return rest[0 ..< index]
      rest

    proc topLevelNames(text: string): HashSet[string] =
      for line in text.splitLines():
        for keyword in ["function", "var"]:
          let name = identifierAfter(line, keyword)
          if name.len > 0:
            result.incl(name)

    let chromeNames = topLevelNames(chrome)
    let appendedNames = topLevelNames(appended)
    check appendedNames.len > 0
    check chromeNames.len > 0
    for name in appendedNames:
      check name notin chromeNames
    ## And the builders really are the renamed ones (cogame-tandem, 2026-08-23).
    check "markDiploBeat" in appendedNames
    check "buildCentreBar" in appendedNames
    check "markBeat" notin appendedNames
    check "buildScrub" notin appendedNames
    check "buildScrub" in chromeNames

  test "chrome.css is the starter's file plus exactly one appended block":
    let css = readFile(repoDir() / "client" / "chrome.css")
    check css.count("/* ---------- Cogplomacy ---------- */") == 1
    let head = css.find("/* ---------- Cogplomacy ---------- */")
    ## Nothing above the marker mentions this game.
    check "cogplomacy" notin css[0 ..< head].toLowerAscii()
    ## Every beat kind the scrubber emits has a rule.
    for kind in ["press", "orders", "adjudicate", "stab", "retreat", "build",
        "centres", "end"]:
      check (".beat-marker." & kind) in css
    check ".plate-name { flex: 1 1 auto; min-width: 3.2em; }" in css
    check "#loading { bottom: var(--band); }" in css
    check "--hudscale" in css

  test "the pages keep every starter element and add only #centrebar":
    for page in ["client/replay.html", "replay-viewer/index.html"]:
      let html = readFile(repoDir() / page)
      for id in ["layout", "stage", "topband", "wordmark", "clock",
          "topright", "statuschip", "feedtoggle", "scorebug", "board-wrap",
          "table", "lightpool", "grain", "endscreen", "transport", "scrub",
          "play", "pos", "feed", "loading"]:
        check ("id=\"" & id & "\"") in html
      check "COG<span>PLOMACY</span>" in html
      check "id=\"centrebar\"" in html
      check "id=\"viewpanel\"" notin html
      check "function relayout()" in html
      check "--band" in html

  test "the static shell talks to the module through the CP handshake":
    let shell = readFile(repoDir() / "replay-viewer" / "static_replay.js")
    for symbol in ["CogplomacyReplayModule()", "_cp_load_replay",
        "_cp_payload_ptr", "_cp_payload_len", "_cp_error_ptr",
        "_cp_error_len", "data-replay-error"]:
      check symbol in shell
    let config = readFile(repoDir() / "replay-viewer" / "config.nims")
    check "EXPORT_NAME=CogplomacyReplayModule" in config
    check "MODULARIZE=1" in config
    check "_cp_load_replay" in config
    let renderer = readFile(repoDir() / "client" / "renderer.js")
    check "data-replay-loaded" in renderer

suite "the board art":
  test "map1901.json is a complete vector map":
    let map = parseJson(readFile(repoDir() / "data" / "map1901.json"))
    check map["space"]["width"].getInt() == 1000
    check map["space"]["height"].getInt() == 800
    let provinces = map["provinces"]
    check provinces.len == NumProvinces
    var centres = 0
    for index in 0 ..< NumProvinces:
      let code = Provinces[index].code
      check provinces.hasKey(code)
      let entry = provinces[code]
      check entry["name"].getStr() == Provinces[index].name
      check entry["kind"].getStr() == $Provinces[index].kind
      check entry["centre"].getBool() == Provinces[index].isCentre
      if entry["centre"].getBool():
        inc centres
      check entry["poly"].len >= 8
      check entry["poly"].len <= 24
      check entry["label"].len == 2
      check entry["dot"].len == 2
      if Provinces[index].coasts.len > 0:
        for coast in Provinces[index].coasts:
          check entry["coasts"].hasKey(coast)
    check centres == 34
