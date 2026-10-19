## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const PromptBankVersion* = "cogplomacy-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc introduction*(selection: PromptSelection, power, others: string): string =
  let introductions = [
    "You are " & power & ", one of seven great powers in a game " &
      "of Diplomacy on the 1901 map of\nEurope. The other powers are " &
      others & ", each\nplayed by a different cog. You never learn who " &
      "plays them.\n",
    "You play " & power & " among seven great powers in Diplomacy on the " &
      "1901 map of Europe. The other powers are " & others & ". " &
      "A different cog plays each opponent; their identities are never revealed to you.\n",
    "Your briefing:\n1. Your power is " & power & ".\n" &
      "2. Seven great powers play Diplomacy on the 1901 map of Europe.\n" &
      "3. The other powers are " & others & ".\n" &
      "4. Each has a different cog player whose identity you never learn.\n",
    "Who are you? " & power & ", one of seven great powers in Diplomacy.\n" &
      "Where? The 1901 map of Europe. Who are your opponents? " & others & ".\n" &
      "Who plays them? Different cogs, whose identities remain unknown to you.\n",
    "Diplomacy takes place on the 1901 map of Europe with seven great powers.\n" &
      "Your opponents are " & others & ", each played by a different cog " &
      "whose identity you never learn. Your power is " & power & ".\n",
    "Take the role of " & power & " in a seven-power game of Diplomacy on " &
      "the 1901 European map. You face " & others & ". A different cog " &
      "controls each opponent; you are never told who those players are.\n",
    "Role reference\nPower: " & power & ".\n" &
      "Game: Diplomacy, seven great powers, 1901 map of Europe.\n" &
      "Opposing powers: " & others & ".\n" &
      "Opposing players: different cogs; their identities are never disclosed to you.\n"
  ]
  introductions[ord(selection.selectedVariant)]

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

const RuleBriefings = [
  "Rules:\n- Armies move on land, fleets on coasts and seas. Every unit has equal\n  strength; a unit moves into a province only if it out-supports whatever\n  opposes it, and equal strength means a STANDOFF and nobody moves.\n- Orders: HOLD, MOVE, SUPPORT (a hold or a move) and CONVOY (a fleet at sea\n  carrying an army between coasts). All seven powers order at the same time\n  and see nothing of each other's orders until they resolve.\n- A supported attack that beats the defence DISLODGES the defender, which\n  must retreat or disband. You may never dislodge your own unit or help\n  anyone dislodge it.\n- After every Fall, whoever occupies a supply centre owns it. Owning more\n  centres than units lets you build at home in Winter; owning fewer forces\n  you to disband.\n- Hold 18 of the 34 supply centres and you win outright. Otherwise you are\n  scored on your share of the 34 centres when the game stops. Nothing else\n  scores.\n- PRESS IS NOT BINDING. You may promise anything to anyone and then order\n  the opposite. So may they. Alliances are the only way to grow and betrayal\n  is the only way to win.\n\n",
  "Armies travel on land and fleets along coasts or at sea. Units have equal strength: entering a province requires out-supporting its opposition; equal strength means a standoff and no movement. Use HOLD, MOVE, SUPPORT a hold or move, or CONVOY an army between coasts with a fleet at sea. Seven powers choose simultaneously, keeping orders hidden until resolution. An attack beating the defence dislodges the defender, which must retreat or disband. You cannot dislodge your own unit or help another power do so.\n\nAfter each Fall, the occupier owns the supply centre. More centres than units permit home builds in Winter; fewer require disbands. Hold 18 of 34 centres to win outright; otherwise score only your share of the 34 centres at the end.\n\nPress binds nobody. You may promise anything and order the opposite, and so may your rivals. Alliances are the only way to grow and betrayal is the only way to win.\n\n",
  "Rules:\n1. Armies move on land; fleets use coasts and seas. All units have equal strength. A province can be entered only with superior support; ties produce a standoff and no movement.\n2. Orders are HOLD, MOVE, SUPPORT (hold or move) and CONVOY (an army between coasts via a fleet at sea). All seven powers submit simultaneously and reveal orders only at resolution.\n3. An attack beating defence dislodges the defender, which must retreat or disband. Never dislodge your own unit or assist that outcome.\n4. A supply centre belongs to its occupier after Fall. In Winter, more centres than units allow builds at home; fewer force disbands.\n5. Owning 18 of 34 centres wins outright. Otherwise score your share of the 34 centres when play stops; nothing else scores.\n6. Press is nonbinding: any power may act against its promises. Alliances are the only way to grow and betrayal is the only way to win.\n\n",
  "Where can units move? Armies on land, fleets on coasts and seas. What wins a province? All units are equally strong, so superior support is required; a tie is a standoff and nobody moves. Which orders exist? HOLD, MOVE, SUPPORT a hold or move, and CONVOY an army between coasts using a fleet at sea. When are orders seen? All seven powers choose at once and see other orders only when resolved. What if an attack beats defence? Dislodge the defender, which must retreat or disband; you may never dislodge your own unit or help do so.\n\nWho owns a supply centre? Its occupier after Fall. What happens in Winter? More centres than units let you build at home; fewer make you disband. How do you score? Hold 18 of 34 centres for an outright win; otherwise only your share of the 34 centres at the stop counts.\n\nAre promises binding? No: you and your rivals can promise anything and order the opposite. Alliances are the only way to grow and betrayal is the only way to win.\n\n",
  "Hold 18 of the 34 supply centres to win outright. If play stops first, your only score is your share of the 34 centres. Ownership goes to the occupier after each Fall. In Winter, a surplus of centres over units permits builds at home; a deficit forces disbands.\n\nAll seven powers order simultaneously, with orders hidden until resolution. HOLD, MOVE, SUPPORT a hold or move, and CONVOY are available; a convoy uses a fleet at sea to carry an army between coasts. Armies move over land, fleets over coasts and seas. Unit strength is equal: only superior support enters a province, and equal strength causes a standoff with nobody moving. An attack overcoming defence dislodges the defender, which must retreat or disband. Dislodging your own unit or helping someone do it is forbidden.\n\nPress is nonbinding. Every power, including you, may promise anything and order its opposite. Alliances are the only way to grow and betrayal is the only way to win.\n\n",
  "Military briefing: armies use land, fleets use coasts and seas. Units have equal strength. To enter a province, out-support the opposition; a tie leaves a standoff and nobody moves. Submit HOLD, MOVE, SUPPORT (hold or move), or CONVOY (a fleet at sea carries an army between coasts). All seven powers submit together, with orders hidden until resolution. A supported attack that beats defence dislodges the defender to retreat or disband. You may not dislodge your own unit or aid another power in doing so.\n\nSupply briefing: after Fall, occupation determines centre ownership. More centres than units let you build at home in Winter; fewer require disbands. Owning 18 of 34 wins outright; otherwise only your share of those 34 centres at the end scores.\n\nDiplomatic briefing: press imposes no obligation. Both you and your opponents may promise anything and order the opposite. Alliances are the only way to grow and betrayal is the only way to win.\n\n",
  "Movement reference: armies on land; fleets on coasts and seas. Strength reference: equal per unit; superior support required to enter a province; equal strength means a standoff with no movement.\nOrders: HOLD, MOVE, SUPPORT (hold or move), CONVOY (army between coasts using a fleet at sea). Timing: seven simultaneous submissions; opposing orders hidden until resolution.\nDislodgement: attack beats defence; defender must retreat or disband. Restriction: never dislodge your own unit or assist it.\nSupply: after Fall, the occupier owns the centre. Winter: more centres than units allow home builds; fewer force disbands.\nVictory: 18 of 34 centres. Otherwise: only centre share out of 34 when play stops scores.\nPress: nonbinding for every power; promises may be contradicted by orders. Alliances are the only way to grow and betrayal is the only way to win.\n\n"
]

proc rulesBriefing*(selection: PromptSelection): string =
  RuleBriefings[ord(selection.selectedVariant)]
