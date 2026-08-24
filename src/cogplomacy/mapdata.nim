## The 1901 board, compiled in.
##
## A static transcription of Allan Calhamer's standard map: 75 provinces
## (56 land, of which 34 are supply centres, and 19 sea spaces), the two
## adjacency graphs an army and a fleet actually use, the three split-coast
## provinces, and the 22 units the seven great powers open with.
##
## Everything here is `const`: it is compiled into the game server, the
## tests and the wasm replay viewer alike, so all three agree on the board
## by construction. No procs beyond `provinceByCode`, `isAdjacent` and
## `bfsDistance`.

import std/[strutils]

const
  NumProvinces* = 75
  NumPowers* = 7
  NumCentres* = 34
  PowerNames* = [
    "AUSTRIA", "ENGLAND", "FRANCE", "GERMANY", "ITALY", "RUSSIA", "TURKEY"
  ]
  PowerAdjectives* = [
    "Austrian", "English", "French", "German", "Italian", "Russian", "Turkish"
  ]

type
  ProvinceKind* = enum
    pkLand = "land"     ## inland: armies only
    pkCoast = "coast"   ## armies and fleets
    pkSea = "sea"       ## fleets only

  Province* = object
    code*: string        ## three-letter code, e.g. "PAR"
    name*: string        ## display name, e.g. "Paris" — the viewer prints this
    kind*: ProvinceKind
    isCentre*: bool
    homePower*: int      ## -1 for neutrals and non-centres
    coasts*: seq[string] ## "NC"/"SC"/"EC" for the three split-coast provinces

# ---- Provinces --------------------------------------------------------------

const ProvinceSpec = [
  ("ADR", "Adriatic Sea", pkSea, false, -1, ""),
  ("AEG", "Aegean Sea", pkSea, false, -1, ""),
  ("ALB", "Albania", pkCoast, false, -1, ""),
  ("ANK", "Ankara", pkCoast, true, 6, ""),
  ("APU", "Apulia", pkCoast, false, -1, ""),
  ("ARM", "Armenia", pkCoast, false, -1, ""),
  ("BAL", "Baltic Sea", pkSea, false, -1, ""),
  ("BAR", "Barents Sea", pkSea, false, -1, ""),
  ("BEL", "Belgium", pkCoast, true, -1, ""),
  ("BER", "Berlin", pkCoast, true, 3, ""),
  ("BLA", "Black Sea", pkSea, false, -1, ""),
  ("BOH", "Bohemia", pkLand, false, -1, ""),
  ("BOT", "Gulf of Bothnia", pkSea, false, -1, ""),
  ("BRE", "Brest", pkCoast, true, 2, ""),
  ("BUD", "Budapest", pkLand, true, 0, ""),
  ("BUL", "Bulgaria", pkCoast, true, -1, "EC SC"),
  ("BUR", "Burgundy", pkLand, false, -1, ""),
  ("CLY", "Clyde", pkCoast, false, -1, ""),
  ("CON", "Constantinople", pkCoast, true, 6, ""),
  ("DEN", "Denmark", pkCoast, true, -1, ""),
  ("EAS", "Eastern Mediterranean", pkSea, false, -1, ""),
  ("EDI", "Edinburgh", pkCoast, true, 1, ""),
  ("ENG", "English Channel", pkSea, false, -1, ""),
  ("FIN", "Finland", pkCoast, false, -1, ""),
  ("GAL", "Galicia", pkLand, false, -1, ""),
  ("GAS", "Gascony", pkCoast, false, -1, ""),
  ("GOL", "Gulf of Lyon", pkSea, false, -1, ""),
  ("GRE", "Greece", pkCoast, true, -1, ""),
  ("HEL", "Helgoland Bight", pkSea, false, -1, ""),
  ("HOL", "Holland", pkCoast, true, -1, ""),
  ("ION", "Ionian Sea", pkSea, false, -1, ""),
  ("IRI", "Irish Sea", pkSea, false, -1, ""),
  ("KIE", "Kiel", pkCoast, true, 3, ""),
  ("LON", "London", pkCoast, true, 1, ""),
  ("LVN", "Livonia", pkCoast, false, -1, ""),
  ("LVP", "Liverpool", pkCoast, true, 1, ""),
  ("MAO", "Mid-Atlantic Ocean", pkSea, false, -1, ""),
  ("MAR", "Marseilles", pkCoast, true, 2, ""),
  ("MOS", "Moscow", pkLand, true, 5, ""),
  ("MUN", "Munich", pkLand, true, 3, ""),
  ("NAF", "North Africa", pkCoast, false, -1, ""),
  ("NAO", "North Atlantic Ocean", pkSea, false, -1, ""),
  ("NAP", "Naples", pkCoast, true, 4, ""),
  ("NTH", "North Sea", pkSea, false, -1, ""),
  ("NWG", "Norwegian Sea", pkSea, false, -1, ""),
  ("NWY", "Norway", pkCoast, true, -1, ""),
  ("PAR", "Paris", pkLand, true, 2, ""),
  ("PIC", "Picardy", pkCoast, false, -1, ""),
  ("PIE", "Piedmont", pkCoast, false, -1, ""),
  ("POR", "Portugal", pkCoast, true, -1, ""),
  ("PRU", "Prussia", pkCoast, false, -1, ""),
  ("ROM", "Rome", pkCoast, true, 4, ""),
  ("RUH", "Ruhr", pkLand, false, -1, ""),
  ("RUM", "Rumania", pkCoast, true, -1, ""),
  ("SER", "Serbia", pkLand, true, -1, ""),
  ("SEV", "Sevastopol", pkCoast, true, 5, ""),
  ("SIL", "Silesia", pkLand, false, -1, ""),
  ("SKA", "Skagerrak", pkSea, false, -1, ""),
  ("SMY", "Smyrna", pkCoast, true, 6, ""),
  ("SPA", "Spain", pkCoast, true, -1, "NC SC"),
  ("STP", "St Petersburg", pkCoast, true, 5, "NC SC"),
  ("SWE", "Sweden", pkCoast, true, -1, ""),
  ("SYR", "Syria", pkCoast, false, -1, ""),
  ("TRI", "Trieste", pkCoast, true, 0, ""),
  ("TUN", "Tunis", pkCoast, true, -1, ""),
  ("TUS", "Tuscany", pkCoast, false, -1, ""),
  ("TYR", "Tyrolia", pkLand, false, -1, ""),
  ("TYS", "Tyrrhenian Sea", pkSea, false, -1, ""),
  ("UKR", "Ukraine", pkLand, false, -1, ""),
  ("VEN", "Venice", pkCoast, true, 4, ""),
  ("VIE", "Vienna", pkLand, true, 0, ""),
  ("WAL", "Wales", pkCoast, false, -1, ""),
  ("WAR", "Warsaw", pkLand, true, 5, ""),
  ("WES", "Western Mediterranean", pkSea, false, -1, ""),
  ("YOR", "Yorkshire", pkCoast, false, -1, "")
]

proc buildProvinces(): seq[Province] =
  for spec in ProvinceSpec:
    var coasts: seq[string]
    if spec[5].len > 0:
      for part in spec[5].split(' '):
        coasts.add(part)
    result.add(Province(
      code: spec[0], name: spec[1], kind: spec[2],
      isCentre: spec[3], homePower: spec[4], coasts: coasts))

const Provinces* = buildProvinces()

proc provinceByCode*(code: string): int =
  ## Province id for a three-letter code, or -1. Case-insensitive.
  let want = code.strip().toUpperAscii()
  for index, province in Provinces:
    if province.code == want:
      return index
  -1

# ---- Army adjacency ---------------------------------------------------------
# Armies walk between land provinces (inland and coastal). Both directions of
# every border are written out: tests/test_map.nim asserts the symmetry rather
# than the builder repairing it.

const ArmyAdjRaw = [
  ("ALB", "GRE SER TRI"),
  ("ANK", "ARM CON SMY"),
  ("APU", "NAP ROM VEN"),
  ("ARM", "ANK SEV SMY SYR"),
  ("BEL", "BUR HOL PIC RUH"),
  ("BER", "KIE MUN PRU SIL"),
  ("BOH", "GAL MUN SIL TYR VIE"),
  ("BRE", "GAS PAR PIC"),
  ("BUD", "GAL RUM SER TRI VIE"),
  ("BUL", "CON GRE RUM SER"),
  ("BUR", "BEL GAS MAR MUN PAR PIC RUH"),
  ("CLY", "EDI LVP"),
  ("CON", "ANK BUL SMY"),
  ("DEN", "KIE SWE"),
  ("EDI", "CLY LVP YOR"),
  ("FIN", "NWY STP SWE"),
  ("GAL", "BOH BUD RUM SIL UKR VIE WAR"),
  ("GAS", "BRE BUR MAR PAR SPA"),
  ("GRE", "ALB BUL SER"),
  ("HOL", "BEL KIE RUH"),
  ("KIE", "BER DEN HOL MUN RUH"),
  ("LON", "WAL YOR"),
  ("LVN", "MOS PRU STP WAR"),
  ("LVP", "CLY EDI WAL YOR"),
  ("MAR", "BUR GAS PIE SPA"),
  ("MOS", "LVN SEV STP UKR WAR"),
  ("MUN", "BER BOH BUR KIE RUH SIL TYR"),
  ("NAF", "TUN"),
  ("NAP", "APU ROM"),
  ("NWY", "FIN STP SWE"),
  ("PAR", "BRE BUR GAS PIC"),
  ("PIC", "BEL BRE BUR PAR"),
  ("PIE", "MAR TUS TYR VEN"),
  ("POR", "SPA"),
  ("PRU", "BER LVN SIL WAR"),
  ("ROM", "APU NAP TUS VEN"),
  ("RUH", "BEL BUR HOL KIE MUN"),
  ("RUM", "BUD BUL GAL SER SEV UKR"),
  ("SER", "ALB BUD BUL GRE RUM TRI"),
  ("SEV", "ARM MOS RUM UKR"),
  ("SIL", "BER BOH GAL MUN PRU WAR"),
  ("SMY", "ANK ARM CON SYR"),
  ("SPA", "GAS MAR POR"),
  ("STP", "FIN LVN MOS NWY"),
  ("SWE", "DEN FIN NWY"),
  ("SYR", "ARM SMY"),
  ("TRI", "ALB BUD SER TYR VEN VIE"),
  ("TUN", "NAF"),
  ("TUS", "PIE ROM VEN"),
  ("TYR", "BOH MUN PIE TRI VEN VIE"),
  ("UKR", "GAL MOS RUM SEV WAR"),
  ("VEN", "APU PIE ROM TRI TUS TYR"),
  ("VIE", "BOH BUD GAL TRI TYR"),
  ("WAL", "LON LVP YOR"),
  ("WAR", "GAL LVN MOS PRU SIL UKR"),
  ("YOR", "EDI LON LVP WAL")
]

proc indexOfCode(code: string): int =
  for index, province in Provinces:
    if province.code == code:
      return index
  -1

proc buildArmyAdj(): seq[seq[int]] =
  result = newSeq[seq[int]](NumProvinces)
  for entry in ArmyAdjRaw:
    let from0 = indexOfCode(entry[0])
    doAssert from0 >= 0, "unknown province in ArmyAdjRaw: " & entry[0]
    for part in entry[1].split(' '):
      let to0 = indexOfCode(part)
      doAssert to0 >= 0, "unknown province in ArmyAdjRaw: " & part
      result[from0].add(to0)

const ArmyAdj* = buildArmyAdj()

# ---- Fleet adjacency --------------------------------------------------------
# A fleet lives on a NODE, not a province: sea spaces and coastal provinces,
# with the three split-coast provinces replaced by one node per coast. Node
# ids are indices into `FleetNodes`.

const FleetAdjRaw = [
  # Sea spaces.
  ("ADR", "ALB APU ION TRI VEN"),
  ("AEG", "BUL/SC CON EAS GRE ION SMY"),
  ("BAL", "BER BOT DEN KIE LVN PRU SWE"),
  ("BAR", "NWG NWY STP/NC"),
  ("BLA", "ANK ARM BUL/EC CON RUM SEV"),
  ("BOT", "BAL FIN LVN STP/SC SWE"),
  ("EAS", "AEG ION SMY SYR"),
  ("ENG", "BEL BRE IRI LON MAO NTH PIC WAL"),
  ("GOL", "MAR PIE SPA/SC TUS TYS WES"),
  ("HEL", "DEN HOL KIE NTH"),
  ("ION", "ADR AEG ALB APU EAS GRE NAP TUN TYS"),
  ("IRI", "ENG LVP MAO NAO WAL"),
  ("MAO", "BRE ENG GAS IRI NAF NAO POR SPA/NC SPA/SC WES"),
  ("NAO", "CLY IRI LVP MAO NWG"),
  ("NTH", "BEL DEN EDI ENG HEL HOL LON NWG NWY SKA YOR"),
  ("NWG", "BAR CLY EDI NAO NTH NWY"),
  ("SKA", "DEN NTH NWY SWE"),
  ("TYS", "GOL ION NAP ROM TUN TUS WES"),
  ("WES", "GOL MAO NAF SPA/SC TUN TYS"),
  # Coastal provinces.
  ("ALB", "ADR GRE ION TRI"),
  ("ANK", "ARM BLA CON"),
  ("APU", "ADR ION NAP VEN"),
  ("ARM", "ANK BLA SEV"),
  ("BEL", "ENG HOL NTH PIC"),
  ("BER", "BAL KIE PRU"),
  ("BRE", "ENG GAS MAO PIC"),
  ("BUL/EC", "BLA CON RUM"),
  ("BUL/SC", "AEG CON GRE"),
  ("CLY", "EDI LVP NAO NWG"),
  ("CON", "AEG ANK BLA BUL/EC BUL/SC SMY"),
  ("DEN", "BAL HEL KIE NTH SKA SWE"),
  ("EDI", "CLY NTH NWG YOR"),
  ("FIN", "BOT STP/SC SWE"),
  ("GAS", "BRE MAO SPA/NC"),
  ("GRE", "AEG ALB BUL/SC ION"),
  ("HOL", "BEL HEL KIE NTH"),
  ("KIE", "BAL BER DEN HEL HOL"),
  ("LON", "ENG NTH WAL YOR"),
  ("LVN", "BAL BOT PRU STP/SC"),
  ("LVP", "CLY IRI NAO WAL"),
  ("MAR", "GOL PIE SPA/SC"),
  ("NAF", "MAO TUN WES"),
  ("NAP", "APU ION ROM TYS"),
  ("NWY", "BAR NTH NWG SKA STP/NC SWE"),
  ("PIC", "BEL BRE ENG"),
  ("PIE", "GOL MAR TUS"),
  ("POR", "MAO SPA/NC SPA/SC"),
  ("PRU", "BAL BER LVN"),
  ("ROM", "NAP TUS TYS"),
  ("RUM", "BLA BUL/EC SEV"),
  ("SEV", "ARM BLA RUM"),
  ("SMY", "AEG CON EAS SYR"),
  ("SPA/NC", "GAS MAO POR"),
  ("SPA/SC", "GOL MAO MAR POR WES"),
  ("STP/NC", "BAR NWY"),
  ("STP/SC", "BOT FIN LVN"),
  ("SWE", "BAL BOT DEN FIN NWY SKA"),
  ("SYR", "EAS SMY"),
  ("TRI", "ADR ALB VEN"),
  ("TUN", "ION NAF TYS WES"),
  ("TUS", "GOL PIE ROM TYS"),
  ("VEN", "ADR APU TRI"),
  ("WAL", "ENG IRI LON LVP"),
  ("YOR", "EDI LON NTH")
]

proc buildFleetNodes(): seq[string] =
  for entry in FleetAdjRaw:
    result.add(entry[0])

const FleetNodes* = buildFleetNodes()
const NumFleetNodes* = FleetNodes.len

proc nodeIndexOf(node: string): int =
  for index, name in FleetNodes:
    if name == node:
      return index
  -1

proc buildFleetAdj(): seq[seq[int]] =
  result = newSeq[seq[int]](FleetNodes.len)
  for entry in FleetAdjRaw:
    let from0 = nodeIndexOf(entry[0])
    doAssert from0 >= 0, "unknown fleet node: " & entry[0]
    for part in entry[1].split(' '):
      let to0 = nodeIndexOf(part)
      doAssert to0 >= 0, "unknown fleet node: " & part
      result[from0].add(to0)

const FleetAdj* = buildFleetAdj()

proc buildNodeProvince(): seq[int] =
  for node in FleetNodes:
    let slash = node.find('/')
    let code = if slash < 0: node else: node[0 ..< slash]
    let id = indexOfCode(code)
    doAssert id >= 0, "fleet node names no province: " & node
    result.add(id)

proc buildNodeCoast(): seq[string] =
  for node in FleetNodes:
    let slash = node.find('/')
    result.add(if slash < 0: "" else: node[slash + 1 .. ^1])

const
  FleetNodeProvince* = buildNodeProvince()
  FleetNodeCoast* = buildNodeCoast()

proc fleetNode*(province: int, coast: string): int =
  ## Fleet node id for a province plus an optional coast, or -1 when the
  ## province holds no fleet node (an inland province, or a split-coast
  ## province named without its coast).
  if province < 0 or province >= NumProvinces:
    return -1
  let want = coast.strip().toUpperAscii()
  for index in 0 ..< FleetNodes.len:
    if FleetNodeProvince[index] == province and FleetNodeCoast[index] == want:
      return index
  -1

proc fleetNodesOf*(province: int): seq[int] =
  ## Every fleet node belonging to a province (two for a split coast).
  for index in 0 ..< FleetNodes.len:
    if FleetNodeProvince[index] == province:
      result.add(index)

proc fleetNodeName*(node: int): string =
  if node < 0 or node >= FleetNodes.len: "" else: FleetNodes[node]

# ---- Supply centres and home centres ----------------------------------------

proc buildSupplyCentres(): seq[int] =
  for index, province in Provinces:
    if province.isCentre:
      result.add(index)

const SupplyCentres* = buildSupplyCentres()

proc buildCentreIndex(): seq[int] =
  result = newSeq[int](NumProvinces)
  for index in 0 ..< NumProvinces:
    result[index] = -1
  for slot, province in SupplyCentres:
    result[province] = slot

const CentreIndex* = buildCentreIndex()
  ## province id -> 0..33 slot in the ownership table, or -1

proc buildHomeCentres(): seq[seq[int]] =
  result = newSeq[seq[int]](NumPowers)
  for index, province in Provinces:
    if province.isCentre and province.homePower >= 0:
      result[province.homePower].add(index)

const HomeCentres* = buildHomeCentres()

# ---- Starting units ---------------------------------------------------------

const StartUnitSpec* = [
  (0, "A", "VIE", ""), (0, "A", "BUD", ""), (0, "F", "TRI", ""),
  (1, "F", "LON", ""), (1, "F", "EDI", ""), (1, "A", "LVP", ""),
  (2, "A", "PAR", ""), (2, "A", "MAR", ""), (2, "F", "BRE", ""),
  (3, "A", "BER", ""), (3, "A", "MUN", ""), (3, "F", "KIE", ""),
  (4, "A", "ROM", ""), (4, "A", "VEN", ""), (4, "F", "NAP", ""),
  (5, "A", "MOS", ""), (5, "A", "WAR", ""), (5, "F", "SEV", ""),
  (5, "F", "STP", "SC"),
  (6, "A", "CON", ""), (6, "A", "SMY", ""), (6, "F", "ANK", "")
]

# ---- Queries ----------------------------------------------------------------

proc isAdjacent*(a, b: int, fleet: bool): bool =
  ## Adjacency in the graph the given unit kind walks. For fleets `a` and `b`
  ## are FLEET NODE ids; for armies they are province ids.
  if fleet:
    if a < 0 or a >= FleetAdj.len or b < 0:
      return false
    return b in FleetAdj[a]
  if a < 0 or a >= ArmyAdj.len or b < 0:
    return false
  b in ArmyAdj[a]

proc bfsDistance*(start: int, fleet: bool): seq[int] =
  ## Hop distance from `start` to every province, walking the graph the given
  ## unit kind uses. For fleets `start` is a fleet node id and the distances
  ## are still projected onto PROVINCES (the smallest distance over the
  ## province's nodes). Unreachable provinces get `high(int) div 4`.
  const Far = high(int) div 4
  result = newSeq[int](NumProvinces)
  for index in 0 ..< NumProvinces:
    result[index] = Far
  if fleet:
    if start < 0 or start >= FleetAdj.len:
      return
    var dist = newSeq[int](FleetAdj.len)
    for index in 0 ..< dist.len:
      dist[index] = Far
    dist[start] = 0
    var queue = @[start]
    var head = 0
    while head < queue.len:
      let node = queue[head]
      inc head
      for next in FleetAdj[node]:
        if dist[next] == Far:
          dist[next] = dist[node] + 1
          queue.add(next)
    for node in 0 ..< dist.len:
      if dist[node] < result[FleetNodeProvince[node]]:
        result[FleetNodeProvince[node]] = dist[node]
  else:
    if start < 0 or start >= ArmyAdj.len:
      return
    result[start] = 0
    var queue = @[start]
    var head = 0
    while head < queue.len:
      let node = queue[head]
      inc head
      for next in ArmyAdj[node]:
        if result[next] == Far:
          result[next] = result[node] + 1
          queue.add(next)

proc provinceName*(province: int): string =
  if province < 0 or province >= NumProvinces: "?" else: Provinces[province].name

proc provinceCode*(province: int): string =
  if province < 0 or province >= NumProvinces: "???" else: Provinces[province].code

proc powerName*(power: int): string =
  if power < 0 or power >= NumPowers: "" else: PowerNames[power]

proc powerAdjective*(power: int): string =
  if power < 0 or power >= NumPowers: "" else: PowerAdjectives[power]

proc powerByName*(name: string): int =
  let want = name.strip().toUpperAscii()
  for index, power in PowerNames:
    if power == want:
      return index
  -1
