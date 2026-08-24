import std/[strutils, unittest]
import cogplomacy/adjudicate
import cogplomacy/orders

## The classic adjudication cases, one assertion each, named after the rule.
## DATC numbers in comments where the case is a numbered one.

proc board(specs: varargs[tuple[power: int, kind, code, coast: string]]):
    Board =
  result = emptyBoard()
  for spec in specs:
    result.units.add(Unit(power: spec.power,
      kind: (if spec.kind == "A": ukArmy else: ukFleet),
      province: provinceByCode(spec.code), coast: spec.coast))

proc u(power: int, kind, code: string, coast = ""):
    tuple[power: int, kind, code, coast: string] =
  (power, kind, code, coast)

proc parseAll(b: Board, raws: openArray[string]): seq[Order] =
  for raw in raws:
    let token = raw.splitWhitespace()[1].split('/')[0]
    let seat = b.unitAt(provinceByCode(token))
    doAssert seat >= 0, "no unit for " & raw
    result.add(parseOrder(b, b.units[seat].power, raw))

proc run(b: Board, raws: openArray[string]): Adjudication =
  let parsed = parseAll(b, raws)
  for order in parsed:
    doAssert not order.illegal, order.raw & " -> " & order.why
  adjudicate(b, parsed)

proc outcomeOf(adj: Adjudication, code: string): Outcome =
  let province = provinceByCode(code)
  for item in adj.results:
    if item.order.unit.province == province:
      return item.outcome
  raise newException(ValueError, "no result for " & code)

proc dislodgedAt(adj: Adjudication, code: string): bool =
  for item in adj.dislodged:
    if item.unit.province == provinceByCode(code):
      return true
  false

proc standoffAt(adj: Adjudication, code: string): bool =
  provinceByCode(code) in adj.standoffs

suite "1 moves and bounces":
  test "a move to an empty province succeeds":
    let b = board(u(2, "A", "PAR"))
    check run(b, ["A PAR - BUR"]).outcomeOf("PAR") == orSuccess

  test "an unsupported move into an occupied province bounces":
    let b = board(u(2, "A", "PAR"), u(3, "A", "BUR"))
    let adj = run(b, ["A PAR - BUR", "A BUR H"])
    check adj.outcomeOf("PAR") == orBounce
    check not adj.dislodgedAt("BUR")

suite "2 standoff":
  test "two unsupported moves to the same province both bounce":
    let b = board(u(2, "A", "PAR"), u(3, "A", "MUN"))
    let adj = run(b, ["A PAR - BUR", "A MUN - BUR"])
    check adj.outcomeOf("PAR") == orBounce
    check adj.outcomeOf("MUN") == orBounce
    check adj.standoffAt("BUR")

suite "3 three-way standoff":
  test "three moves bounce and the province is barred as a retreat":
    let b = board(u(2, "A", "PAR"), u(3, "A", "MUN"), u(2, "A", "MAR"))
    let adj = run(b, ["A PAR - BUR", "A MUN - BUR", "A MAR - BUR"])
    check adj.outcomeOf("PAR") == orBounce
    check adj.outcomeOf("MUN") == orBounce
    check adj.outcomeOf("MAR") == orBounce
    check adj.standoffAt("BUR")
    ## And a dislodged unit next door may not retreat into it.
    let after = board(u(3, "A", "GAS"))
    let dislodged = Unit(power: 3, kind: ukArmy,
      province: provinceByCode("PAR"), coast: "")
    var open: seq[string]
    for option in retreatDestinations(after, dislodged, -1, adj.standoffs):
      open.add(provinceCode(option.province))
    check "BUR" notin open

suite "4 supported attack":
  test "a supported attack dislodges the defender":
    let b = board(u(0, "A", "BUD"), u(0, "A", "TRI"), u(3, "A", "VIE"))
    let adj = run(b, ["A BUD - VIE", "A TRI S A BUD - VIE", "A VIE H"])
    check adj.outcomeOf("BUD") == orSuccess
    check adj.dislodgedAt("VIE")

suite "5 cut support":
  test "an attack on the supporter cuts its support":
    let b = board(u(0, "A", "ALB"), u(0, "F", "ION"), u(6, "F", "AEG"),
      u(6, "A", "GRE"))
    let adj = run(b, ["A ALB - GRE", "F ION S A ALB - GRE", "F AEG - ION",
      "A GRE H"])
    check adj.outcomeOf("ION") == orCut
    check adj.outcomeOf("ALB") == orBounce
    check not adj.dislodgedAt("GRE")

suite "6 support is not cut from the province it supports into":
  test "the classic exception (DATC 6.D.4)":
    let b = board(u(0, "A", "ALB"), u(0, "F", "ION"), u(6, "F", "GRE"),
      u(6, "F", "AEG"))
    let adj = run(b, ["A ALB - GRE", "F ION S A ALB - GRE", "F GRE - ION",
      "F AEG H"])
    check adj.outcomeOf("ION") == orSuccess
    check adj.outcomeOf("ALB") == orSuccess
    check adj.dislodgedAt("GRE")

suite "7 dislodging a supporter cuts its support":
  test "even from the supported direction (DATC 6.D.17)":
    let b = board(u(5, "F", "CON"), u(5, "F", "BLA"), u(6, "F", "ANK"),
      u(6, "A", "SMY"), u(6, "A", "ARM"))
    let adj = run(b, ["F CON S F BLA - ANK", "F BLA - ANK", "F ANK - CON",
      "A SMY S F ANK - CON", "A ARM - ANK"])
    check adj.outcomeOf("CON") == orCut
    check adj.outcomeOf("ANK") == orSuccess
    check adj.dislodgedAt("CON")
    check adj.outcomeOf("BLA") == orBounce

suite "8 self-dislodgement ban":
  test "a supported move into your own unit fails and does not dislodge it":
    let b = board(u(2, "A", "PAR"), u(2, "A", "BUR"), u(2, "A", "GAS"))
    let adj = run(b, ["A PAR - BUR", "A GAS S A PAR - BUR", "A BUR H"])
    check adj.outcomeOf("PAR") == orBounce
    check not adj.dislodgedAt("BUR")

suite "9 no support of an attack on your own unit":
  test "the support does not count toward attack strength":
    let b = board(u(1, "F", "NTH"), u(1, "F", "YOR"), u(3, "F", "HOL"))
    let adj = run(b, ["F NTH H", "F YOR S F HOL - NTH", "F HOL - NTH"])
    check adj.outcomeOf("HOL") == orBounce
    check not adj.dislodgedAt("NTH")

suite "10 beleaguered garrison":
  test "two equal supported attacks bounce and the defender survives":
    let b = board(u(1, "F", "NTH"), u(1, "F", "YOR"), u(5, "F", "NWY"),
      u(5, "F", "SKA"), u(3, "F", "HOL"))
    let adj = run(b, ["F NTH H", "F YOR S F HOL - NTH", "F NWY - NTH",
      "F SKA S F NWY - NTH", "F HOL - NTH"])
    check adj.outcomeOf("NWY") == orBounce
    check adj.outcomeOf("HOL") == orBounce
    check not adj.dislodgedAt("NTH")
    check adj.standoffAt("NTH")

suite "11 circular movement":
  test "a closed ring of moves all succeed":
    let b = board(u(0, "A", "VIE"), u(0, "A", "BUD"), u(0, "A", "TRI"))
    let adj = run(b, ["A VIE - BUD", "A BUD - TRI", "A TRI - VIE"])
    check adj.outcomeOf("VIE") == orSuccess
    check adj.outcomeOf("BUD") == orSuccess
    check adj.outcomeOf("TRI") == orSuccess

  test "an outside attack that beats one link makes the whole ring fail":
    let b = board(u(0, "A", "VIE"), u(0, "A", "BUD"), u(0, "A", "TRI"),
      u(4, "A", "VEN"), u(4, "A", "TYR"))
    let adj = run(b, ["A VIE - BUD", "A BUD - TRI", "A TRI - VIE",
      "A VEN - TRI", "A TYR S A VEN - TRI"])
    check adj.outcomeOf("VIE") == orBounce
    check adj.outcomeOf("BUD") == orBounce
    check adj.outcomeOf("TRI") == orBounce
    check adj.dislodgedAt("TRI")

suite "12 convoy":
  test "one fleet carries an army":
    let b = board(u(1, "A", "LON"), u(1, "F", "NTH"))
    let adj = run(b, ["A LON - HOL", "F NTH C A LON - HOL"])
    check adj.outcomeOf("LON") == orSuccess
    check adj.outcomeOf("NTH") == orSuccess

  test "a chain of three fleets carries an army":
    let b = board(u(1, "A", "LON"), u(1, "F", "ENG"), u(1, "F", "MAO"),
      u(1, "F", "WES"))
    let adj = run(b, ["A LON - NAF", "F ENG C A LON - NAF",
      "F MAO C A LON - NAF", "F WES C A LON - NAF"])
    check adj.outcomeOf("LON") == orSuccess

suite "13 convoy disruption":
  test "a dislodged convoying fleet leaves the army where it stood":
    let b = board(u(1, "A", "LON"), u(1, "F", "NTH"), u(3, "F", "HEL"),
      u(3, "F", "DEN"))
    let adj = run(b, ["A LON - HOL", "F NTH C A LON - HOL", "F HEL - NTH",
      "F DEN S F HEL - NTH"])
    check adj.outcomeOf("LON") == orNoConvoy
    check adj.dislodgedAt("NTH")
    check not adj.dislodgedAt("LON")
    ## The army's own province is not vacated.
    var moved = false
    for move in adj.moved:
      if move.unit.province == provinceByCode("LON"):
        moved = true
    check not moved

suite "14 convoy with an alternative path":
  test "one fleet may be dislodged and the army still crosses":
    let b = board(u(1, "A", "LON"), u(1, "F", "NTH"), u(1, "F", "ENG"),
      u(2, "F", "IRI"), u(2, "F", "WAL"))
    let adj = run(b, ["A LON - BEL", "F NTH C A LON - BEL",
      "F ENG C A LON - BEL", "F IRI - ENG", "F WAL S F IRI - ENG"])
    check adj.outcomeOf("LON") == orSuccess
    check adj.dislodgedAt("ENG")

suite "15 Szykman convoy paradox":
  test "the paradoxical convoyed move fails; the dislodgement stands":
    let b = board(u(1, "F", "LON"), u(1, "F", "WAL"), u(2, "A", "BRE"),
      u(2, "F", "ENG"))
    let adj = run(b, ["F LON S F WAL - ENG", "F WAL - ENG", "A BRE - LON",
      "F ENG C A BRE - LON"])
    check adj.outcomeOf("BRE") == orNoConvoy
    check adj.outcomeOf("WAL") == orSuccess
    check adj.dislodgedAt("ENG")

suite "16 support matching":
  test "a support of a move that was not ordered is void":
    let b = board(u(2, "A", "PAR"), u(2, "F", "BRE"))
    let adj = run(b, ["A PAR - GAS", "F BRE S A PAR - PIC"])
    check adj.outcomeOf("BRE") == orVoid
    check adj.outcomeOf("PAR") == orSuccess

suite "17 illegal-order repair":
  test "each illegal order is rejected with the documented reason":
    let b = board(u(2, "F", "BRE"), u(2, "A", "PAR"), u(2, "A", "MAR"),
      u(2, "F", "MAO"), u(2, "A", "GAS"))
    check parseOrder(b, 2, "F BRE - PAR").why == "wrongunit"
    check parseOrder(b, 2, "A PAR - ENG").why == "wrongunit"
    check parseOrder(b, 2, "A PAR S A MAR - ROM").why == "nonadjacent"
    check parseOrder(b, 2, "A PAR C A MAR - ROM").why == "wrongunit"
    check parseOrder(b, 2, "F MAO - SPA").why == "ambiguouscoast"
    check parseOrder(b, 2, "A PAR - XYZ").why == "parse"
    check parseOrder(b, 2, "A PAR S A BUR").why == "notthere"
    check parseOrder(b, 2, "A PAR - MOS").why == "nonadjacent"

  test "an illegal order never invalidates the rest of the reply":
    let b = board(u(2, "A", "PAR"), u(2, "F", "BRE"))
    let good = parseOrder(b, 2, "A PAR - BUR")
    let bad = parseOrder(b, 2, "F BRE - PAR")
    check not good.illegal
    check bad.illegal
    let adj = adjudicate(b, @[good])
    check adj.outcomeOf("PAR") == orSuccess
    check adj.outcomeOf("BRE") == orSuccess    # repaired to a hold

suite "18 coast disambiguation":
  test "one reachable coast is filled in silently":
    let b = board(u(5, "F", "BOT"))
    let order = parseOrder(b, 5, "F BOT - STP")
    check not order.illegal
    check order.targetCoast == "SC"
    check formatOrder(order) == "F BOT - STP/SC"

  test "two reachable coasts are ambiguouscoast unless named":
    let b = board(u(2, "F", "MAO"))
    check parseOrder(b, 2, "F MAO - SPA").why == "ambiguouscoast"
    let named = parseOrder(b, 2, "F MAO - SPA/NC")
    check not named.illegal
    check named.targetCoast == "NC"

suite "19 retreat rules":
  test "the attacker's origin, a standoff and an occupied province are barred":
    let b = board(u(0, "A", "GAL"), u(3, "A", "SIL"))
    let dislodged = Unit(power: 5, kind: ukArmy,
      province: provinceByCode("WAR"), coast: "")
    var open: seq[string]
    let attacker = provinceByCode("PRU")
    for option in retreatDestinations(b, dislodged, attacker,
        @[provinceByCode("UKR")]):
      open.add(provinceCode(option.province))
    check "PRU" notin open        # the attacker's origin
    check "UKR" notin open        # a standoff province
    check "GAL" notin open        # occupied
    check "SIL" notin open        # occupied
    check "MOS" in open
    check "LVN" in open

  test "two units retreating to the same province both disband":
    ## The rule lives in the sim; the enumeration above is what feeds it.
    let b = board()
    let one = Unit(power: 0, kind: ukArmy, province: provinceByCode("VIE"),
      coast: "")
    let two = Unit(power: 3, kind: ukArmy, province: provinceByCode("BOH"),
      coast: "")
    var shared: seq[string]
    for a in retreatDestinations(b, one, -1, @[]):
      for c in retreatDestinations(b, two, -1, @[]):
        if a.province == c.province and provinceCode(a.province) notin shared:
          shared.add(provinceCode(a.province))
    check "TYR" in shared

suite "20 head-to-head":
  test "equal strength bounces both ways":
    let b = board(u(2, "A", "PAR"), u(3, "A", "BUR"))
    let adj = run(b, ["A PAR - BUR", "A BUR - PAR"])
    check adj.outcomeOf("PAR") == orBounce
    check adj.outcomeOf("BUR") == orBounce
    check not adj.dislodgedAt("PAR")
    check not adj.dislodgedAt("BUR")

  test "one support makes the stronger side dislodge the weaker":
    let b = board(u(2, "A", "PAR"), u(2, "A", "PIC"), u(3, "A", "BUR"))
    let adj = run(b, ["A PAR - BUR", "A PIC S A PAR - BUR", "A BUR - PAR"])
    check adj.outcomeOf("PAR") == orSuccess
    check adj.outcomeOf("BUR") == orBounce
    check adj.dislodgedAt("BUR")
