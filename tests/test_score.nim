import std/[json, unittest]
import cogplomacy/sim

## Scoring: plain supply-centre share out of a constant 34, with a
## discontinuous 1.0 for a solo. Higher is better; scores sum to at most 1.

proc fixtureConfig(years = 4, seed = 0): GameConfig =
  result = defaultGameConfig()
  result.years = years
  result.seed = seed
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc withOwners(sim: var Sim, counts: array[Powers, int]) =
  ## Hand out the first `counts[power]` free centres to each power.
  for slot in 0 ..< NumCentres:
    sim.board.owner[slot] = -1
  var slot = 0
  for power in 0 ..< Powers:
    for _ in 0 ..< counts[power]:
      sim.board.owner[slot] = power
      inc slot

suite "the share formula":
  test "a seat scores its centres over the constant 34":
    var sim = initSim(fixtureConfig())
    sim.withOwners([6, 5, 5, 5, 4, 4, 4])
    for seat in 0 ..< Seats:
      let held = sim.centres(seat)
      check abs(sim.score(seat) - held.float / 34.0) < 1e-9

  test "unclaimed neutrals dilute everybody: the shares sum to owned/34":
    var sim = initSim(fixtureConfig())
    sim.withOwners([3, 3, 3, 3, 3, 4, 3])   # 22 owned, 12 neutral
    var total = 0.0
    for seat in 0 ..< Seats:
      total += sim.score(seat)
    check abs(total - 22.0 / 34.0) < 1e-9
    check total < 1.0

  test "a neutral is worth the same to every power":
    var sim = initSim(fixtureConfig())
    sim.withOwners([3, 3, 3, 3, 3, 4, 3])
    let before = sim.score(0)
    ## Give seat 0's power one more centre.
    for slot in 0 ..< NumCentres:
      if sim.board.owner[slot] < 0:
        sim.board.owner[slot] = sim.powerOf[0]
        break
    check abs((sim.score(0) - before) - 1.0 / 34.0) < 1e-9

  test "an eliminated power scores zero":
    var sim = initSim(fixtureConfig())
    sim.withOwners([10, 8, 8, 8, 0, 0, 0])
    for seat in 0 ..< Seats:
      if sim.centres(seat) == 0:
        check sim.score(seat) == 0.0

suite "the solo":
  test "exactly eighteen centres is 1.0 and 0.0s":
    var sim = initSim(fixtureConfig(seed = 3))
    var counts: array[Powers, int]
    counts[0] = 18
    counts[1] = 16
    sim.withOwners(counts)
    ## The solo flag is what makes the score discontinuous.
    sim.soloist = 0
    for seat in 0 ..< Seats:
      if sim.powerOf[seat] == 0:
        check sim.score(seat) == 1.0
      else:
        check sim.score(seat) == 0.0
    var total = 0.0
    for seat in 0 ..< Seats:
      total += sim.score(seat)
    check total == 1.0

  test "seventeen centres is not a solo":
    var sim = initSim(fixtureConfig(seed = 3))
    var counts: array[Powers, int]
    counts[0] = 17
    counts[1] = 17
    sim.withOwners(counts)
    for seat in 0 ..< Seats:
      check sim.score(seat) < 1.0
      check abs(sim.score(seat) - sim.centres(seat).float / 34.0) < 1e-9

suite "a deadline before the first Fall":
  test "scores are the 1901 home centres":
    var sim = initSim(fixtureConfig(years = 4, seed = 1))
    sim.endEarly()
    check sim.reason == "deadline"
    let results = sim.resultsJson()
    for seat in 0 ..< Seats:
      let power = sim.powerOf[seat]
      let expected = if power == 5: 4.0 / 34.0 else: 3.0 / 34.0
      check abs(results["scores"][seat].getFloat() - expected) < 1e-9
      check results["centres"][seat].getInt() == (if power == 5: 4 else: 3)
    check results["soloist"].getStr() == ""
    check results["years"].getInt() == 0

suite "bounds":
  test "every score is in [0, 1] and the total never exceeds 1":
    for seed in 0 .. 5:
      var sim = initSim(fixtureConfig(seed = seed))
      sim.withOwners([9, 7, 5, 4, 4, 3, 2])
      var total = 0.0
      for seat in 0 ..< Seats:
        check sim.score(seat) >= 0.0
        check sim.score(seat) <= 1.0
        total += sim.score(seat)
      check total <= 1.0 + 1e-9
