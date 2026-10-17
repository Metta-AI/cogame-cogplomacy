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

const PromptBankVersion* = "cogplomacy-rules-v1"

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
