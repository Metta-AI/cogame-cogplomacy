## Cogplomacy player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default Diplomacy strategy), then spectates until the final frame. All of
## the actual decision making happens inside the game server, which sends
## this seat's prompt to Claude once per phase, in one parallel batch with
## every other live seat.
##
## PLAYER_SCRIPTED=expander (or 1) registers the seat as the built-in greedy
## baseline instead; PLAYER_SCRIPTED=hedgehog as the wall. The server plays
## those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <cogplomacy-image> --name my-cogplomacy \
##     --run /bin/cogplomacy-player --secret-env PLAYER_PROMPT="<strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Grow steadily. Open with an alliance against the neighbour who threatens you
most, keep your promises while they are profitable, and take the supply
centres you can hold. Never leave a home centre uncovered in Fall.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "cogplomacy player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "cogplomacy player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read
  ## (only a timeout returns none), and mummy's send merely queues, so the
  ## game's quit(0) can outrun the flushed final frame. A dead socket is a
  ## normal end of episode, not a player failure: exit 0 either way.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "cogplomacy player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "cogplomacy player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"power"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "cogplomacy player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "cogplomacy player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "cogplomacy player: socket closed (", error.msg, "), exiting"
  try:
    socket.close()
  except CatchableError:
    discard
