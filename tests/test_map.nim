import std/[sets, unittest]
import cogplomacy/mapdata

## Map integrity. The board is a compiled-in transcription of the standard
## 1901 map; everything a rule depends on is pinned here.

suite "provinces":
  test "75 provinces, 56 land and 19 sea":
    check Provinces.len == 75
    var land = 0
    var coast = 0
    var sea = 0
    for province in Provinces:
      case province.kind
      of pkLand: inc land
      of pkCoast: inc coast
      of pkSea: inc sea
    check sea == 19
    check land + coast == 56
    check land == 14
    check coast == 42

  test "every province has a distinct three-letter code and a full name":
    var codes = initHashSet[string]()
    for province in Provinces:
      check province.code.len == 3
      check province.name.len > 3
      check province.code notin codes
      codes.incl(province.code)

suite "supply centres":
  test "exactly 34 supply centres":
    check SupplyCentres.len == 34
    check NumCentres == 34

  test "22 home centres map back to their power":
    var home = 0
    for power in 0 ..< NumPowers:
      for province in HomeCentres[power]:
        check Provinces[province].isCentre
        check Provinces[province].homePower == power
        inc home
    check home == 22
    check HomeCentres[0].len == 3    # Austria
    check HomeCentres[5].len == 4    # Russia

  test "the twelve neutrals are the documented ones":
    let neutrals = ["NWY", "SWE", "DEN", "HOL", "BEL", "SPA", "POR", "TUN",
      "SER", "RUM", "BUL", "GRE"]
    var found = 0
    for province in SupplyCentres:
      if Provinces[province].homePower < 0:
        inc found
        check Provinces[province].code in neutrals
    check found == 12

  test "the centre index round-trips":
    for slot, province in SupplyCentres:
      check CentreIndex[province] == slot
    var indexed = 0
    for province in 0 ..< NumProvinces:
      if CentreIndex[province] >= 0:
        inc indexed
    check indexed == 34

suite "adjacency":
  test "army adjacency is symmetric and never touches a sea":
    for a in 0 ..< NumProvinces:
      for b in ArmyAdj[a]:
        check a in ArmyAdj[b]
        check Provinces[b].kind != pkSea
        check Provinces[a].kind != pkSea
        check a != b

  test "fleet adjacency is symmetric and never touches an inland province":
    for a in 0 ..< NumFleetNodes:
      for b in FleetAdj[a]:
        check a in FleetAdj[b]
        check Provinces[FleetNodeProvince[b]].kind != pkLand
        check Provinces[FleetNodeProvince[a]].kind != pkLand
        check a != b

  test "every land province has at least one army neighbour":
    for index, province in Provinces:
      if province.kind != pkSea:
        check ArmyAdj[index].len > 0

  test "a few borders everyone knows":
    check provinceByCode("BUR") in ArmyAdj[provinceByCode("PAR")]
    check provinceByCode("MUN") in ArmyAdj[provinceByCode("BUR")]
    check provinceByCode("TUN") in ArmyAdj[provinceByCode("NAF")]
    check provinceByCode("SWE") in ArmyAdj[provinceByCode("DEN")]
    check provinceByCode("POR") in ArmyAdj[provinceByCode("SPA")]
    check provinceByCode("PAR") notin ArmyAdj[provinceByCode("MUN")]

suite "split coasts":
  test "exactly three provinces have named coasts":
    var split: seq[string]
    for province in Provinces:
      if province.coasts.len > 0:
        split.add(province.code)
    check split.len == 3
    check "SPA" in split
    check "STP" in split
    check "BUL" in split

  test "each split coast is a distinct fleet node of its province":
    check fleetNode(provinceByCode("SPA"), "NC") >= 0
    check fleetNode(provinceByCode("SPA"), "SC") >= 0
    check fleetNode(provinceByCode("SPA"), "") < 0
    check fleetNode(provinceByCode("STP"), "NC") >= 0
    check fleetNode(provinceByCode("STP"), "SC") >= 0
    check fleetNode(provinceByCode("BUL"), "EC") >= 0
    check fleetNode(provinceByCode("BUL"), "SC") >= 0
    check fleetNodesOf(provinceByCode("SPA")).len == 2
    check fleetNodesOf(provinceByCode("PAR")).len == 0

  test "a coast's fleet adjacency is a PROPER part of the province's":
    for code in ["SPA", "STP", "BUL"]:
      let province = provinceByCode(code)
      var whole = initHashSet[int]()
      for node in fleetNodesOf(province):
        for next in FleetAdj[node]:
          whole.incl(FleetNodeProvince[next])
      for node in fleetNodesOf(province):
        var part = initHashSet[int]()
        for next in FleetAdj[node]:
          part.incl(FleetNodeProvince[next])
        ## Each coast reaches some water, and strictly less of it than the
        ## province as a whole — a coast that reached all of it would make
        ## the split pointless, and that is what this pins.
        check part.len > 0
        check part < whole

  test "the coasts really are different water":
    ## St Petersburg's north coast reaches the Barents, its south coast the
    ## Gulf of Bothnia, and neither reaches the other's.
    let north = fleetNode(provinceByCode("STP"), "NC")
    let south = fleetNode(provinceByCode("STP"), "SC")
    check fleetNode(provinceByCode("BAR"), "") in FleetAdj[north]
    check fleetNode(provinceByCode("BOT"), "") in FleetAdj[south]
    check fleetNode(provinceByCode("BOT"), "") notin FleetAdj[north]
    check fleetNode(provinceByCode("BAR"), "") notin FleetAdj[south]

suite "starting position":
  test "22 units, legal for their provinces":
    check StartUnitSpec.len == 22
    var byPower: array[NumPowers, int]
    for spec in StartUnitSpec:
      let province = provinceByCode(spec[2])
      check province >= 0
      inc byPower[spec[0]]
      if spec[1] == "F":
        check fleetNode(province, spec[3]) >= 0
      else:
        check Provinces[province].kind != pkSea
    check byPower[5] == 4       # Russia opens with four
    for power in 0 ..< NumPowers:
      if power != 5:
        check byPower[power] == 3

  test "every unit starts on one of its own home centres":
    for spec in StartUnitSpec:
      let province = provinceByCode(spec[2])
      check Provinces[province].isCentre
      check Provinces[province].homePower == spec[0]

  test "Russia's fleet opens on a named coast":
    var found = false
    for spec in StartUnitSpec:
      if spec[2] == "STP":
        found = true
        check spec[1] == "F"
        check spec[3] == "SC"
    check found

suite "distances":
  test "bfsDistance reaches a supply centre from every land province":
    for index, province in Provinces:
      if province.kind == pkSea:
        continue
      let distances = bfsDistance(index, false)
      var best = high(int)
      for centre in SupplyCentres:
        if distances[centre] < best:
          best = distances[centre]
      check best < 1000

  test "bfsDistance on the fleet graph reaches a coastal centre":
    for node in 0 ..< NumFleetNodes:
      let distances = bfsDistance(node, true)
      var best = high(int)
      for centre in SupplyCentres:
        if fleetNodesOf(centre).len > 0 and distances[centre] < best:
          best = distances[centre]
      check best < 1000

  test "distance zero is the province itself":
    let paris = provinceByCode("PAR")
    check bfsDistance(paris, false)[paris] == 0

suite "power names":
  test "seven powers, named and adjectived":
    check PowerNames.len == 7
    check PowerAdjectives.len == 7
    check powerByName("france") == 2
    check powerByName("TURKEY") == 6
    check powerByName("PRUSSIA") == -1
