# In-game checklist

Everything the PC tests cannot prove: the real game API, the real client's
fonts and frames, and the real group flows. Run it on the Forever client.

Status: **only A1 is done** (you confirmed the TOC number on 2026-10-17). Every
other box is open on purpose: tick one only after you saw the expected result,
and write what you saw after an arrow on the same line (`→ pass`, `→ FAIL:
what happened`, plus any observed value: a name, an id, a position, a time).
That record is what the fixing step works from.

How the file is laid out:

- **Part 1** is the `/taxi sim` walkthrough: the windows against a made-up
  world, alone, no group needed.
- **Part 2** is the real client, grouped by area (A to O). Each item says what
  it **Needs**, what to **Do**, what to **Expect**, and (where a mismatch has an
  obvious place to fix it) **If wrong**. By design a mismatch with the game is
  fixed in the game adapter (`Taxi/Game/WoW.lua`, `Taxi/Core/Init.lua`), in the
  ids in `Taxi/Core/Config.lua` or in a timing constant named in Setup, not in
  the rules in `Domain/`.
- Characters needed over the whole list: two accounts for the 2-character
  items; a **warlock of level 20 or more** (W) with soul shards, **two clickers**
  (C1, C2: any class, any level) and **a traveler** (T) for the 4-character
  run; two more travelers for the 6-character raid run; a **mage** (M) with
  portal spells; a guildmate pair; and, once Hardcore launches, a throwaway
  Hardcore character. Everything except area L works on a normal ruleset, so do
  the rest before Hardcore launches. All characters of one run are the same
  faction.

## Setup (once)

- `/console scriptErrors 1` shows Lua errors as popups.
- Run `/taxi debug` after each area. Its last line must keep saying `0 errors
  logged; the last 0:`. Any other count lists the errors: copy them.
- Chat lines hold 255 characters, so the `/run` lines below are short on
  purpose. Paste them as written.
- A probe snippet that raises an error ("attempt to call a nil value") is a
  result, not a Taxi failure: it says that API does not exist in Forever. Write
  it next to the item.
- Constants a result may ask you to change (anything else is a code change):
  `JOIN_DELAY`, `JOIN_POLL`, `JOIN_TIMEOUT` in `Taxi/Core/Init.lua`;
  `LANDING_WINDOW`, `JUMP_YARDS`, `CREW_YARDS` in `Taxi/App/Traveler.lua`;
  `INVITE_TIMEOUT`, `RAID_TIMEOUT` in `Taxi/App/Driver.lua`; `PUMP_INTERVAL`
  in `Taxi/App/Engine.lua`; `POLL_SECONDS`, `MOVE_YARDS`,
  `TRADE_SETTLE_SECONDS` in `Taxi/Game/WoW.lua`; and in
  `Taxi/Core/Config.lua` `STAND_MOVE_YARDS`, `GUARD_YARDS`, `PORTALS`,
  `RITUAL_SPELL`, `SOUL_SHARD_ITEM`.
- Two helpers (paste once per character per session):
  - Addon messages: `/run TaxiW=CreateFrame("Frame");TaxiW:RegisterEvent("CHAT_MSG_ADDON");TaxiW:SetScript("OnEvent",function(_,_,p,m,d,s) if p=="TaxiFvr" then print(d,s,(m or ""):sub(1,30)) end end)`
    prints the distribution, the sender and the start of every Taxi message.
    Stop it with `/run TaxiW:UnregisterAllEvents()`.
  - Hardcore death notices: `/run TaxiD=CreateFrame("Frame");TaxiD:RegisterEvent("HARDCORE_DEATHS");TaxiD:SetScript("OnEvent",function(_,e,...) print(e,...) end)`
    Stop it with `/run TaxiD:UnregisterAllEvents()`.

## Part 1: the windows and `/taxi sim` (alone, no group needed)

Status: **not run in game yet.** The windows and the sim are covered by the PC
tests (a strict fake of the frame API); every box below needs a real run.

Start with `/taxi sim`: the main window opens on the Travel tab and a "Sim
controls" window appears at the left. `/taxi sim off` (or the Stop sim button)
ends it. In the sim you are "You", a level 60 Hardcore hunter with 100g.
Dar Kbolt (a guildmate's warlock, live with Cee One and Cee Two on his crew),
Ann Other (a doubtful warlock whose crew left her, so her stand is paused), Mag
Ic (a mage), Cee One and Cee Two (clickers) and Stan Ger (a stranger) are simulated;
you answer for them in windows marked "(sim)". Answer a request within 30
seconds and take an invite within 60, or the sim traveler gives up, like a real
one.

**While /taxi sim is on, real death reports still go out; everything else from
the real addon is paused until `/taxi sim off`.** (The real Engine is muted for
the whole sim: it sends nothing, except your own character's DEATH report,
which is never held back. A real summon still gets its real Summon Guard panel
next to the real popup; the sim's panels say "(sim)".)

### The board
- [ ] Travel > Summons: Dar Kbolt first and in green ("★ 4.7 · 6 summons"), then
      Ann Other ("★ 1.5 · 4 summons · New", "⚠ 1 reported death"), marked
      "Paused" with her Request button off.
- [ ] Travel > Portals: Mag Ic, "Portals: Stormwind, Ironforge, Darnassus".
- [ ] Clicking: only Ann Other, "Needs 2 clickers" (Dar Kbolt's stand is live).

### A ride
- [ ] Request (Dar Kbolt) opens the request dialog; 50s, 1g and Custom (gold and
      silver boxes) change the picked (greyed) button; Esc closes it; Send says
      "Requested a seat from Dar Kbolt." in the footer.
- [ ] "Dar Kbolt (sim) - Ride request" appears with a sound: You (level 60),
      Guildmate, Wants a summon, Offers 1g. Accept invites You; Decline does not.
- [ ] Accept invite (Sim controls) puts You in his group.
- [ ] Offer summon (green): GREEN border, seven ticked lines, no button.
- [ ] Offer summon (wrong place): RED border, crossed Destination and position
      lines, Decline summon (and no accept button); Decline summon closes it.
- [ ] Offer stranger summon: YELLOW "Not a Taxi ride" with no ride; RED
      "Summoner: Stan Ger (agreed: Dar Kbolt)" during one.
- [ ] Accept summon: the panel goes, the arrival window opens with 1g picked.
- [ ] Stars (Trust), Open trade with Dar Kbolt: "Put 1g in the trade" shows
      (as a hint and as a Put button, enabled while the simulated trade is
      open; clicking it keeps the hint), "Rating sent." too; opening the trade
      again sends no second rating. Picking No tip clears the hint.
- [ ] Put 1g in the trade (the button: Open trade itself never sets the
      money), then Trade tip completes the trade; History shows "Summon from
      Dar Kbolt".
- [ ] Stay and click applies to his stand (his crew is full, so he turns it
      down: "Dar Kbolt turned your application down."); Leave group leaves it.

### A portal ride
- [ ] Portals > Request > Darnassus: "Mag Ic (sim)" toast; Accept; Accept invite;
      Mage opens portal shows "Portal to Darnassus is up - click it!" with a
      sound; Step through portal opens the arrival window with no stars and no
      Stay and click.

### Clickers
- [ ] Clicker applies: "Ann Other (sim) - Clicker offer" ("Stan Ger asks for 40%",
      "You offered 30%"); Accept, Counter (box) and Decline work.
- [ ] After a tip, End shift: "Cee One (sim) - Shift ended", "Owed 25s ·
      Received 0c", one star suggested; Submit sends the rating.
- [ ] Applying yourself (Clicking tab, Ann Other's row) shows the offer in Ann
      Other's window; the counter-offer comes back to You as a "Counter-offer"
      window.

### The rest
- [ ] Kill traveler: the red "Your Hardcore character has died." banner, every
      button off.
- [ ] Advance 60 s moves the sim clock; status lines render in the footer.
- [ ] `/taxi sim off` brings the real window back; nothing was sent to the real
      channel; the "New ratings are saved" reminder never showed in the sim.
      Do: the real character has a stand open (E1) and a second account runs
      the addon-messages helper (Setup); start `/taxi sim`, play two minutes,
      `/taxi sim off`. Expect: the second account's helper prints no line from
      the real character while the sim runs (a real death report is the one
      exception, L6) and prints heartbeats again within a minute after
      `/taxi sim off`; the reminder never showed during the sim.
- [ ] A real ride or summon while the sim is on (a normal ruleset only). Do: in
      a real ride (G4) type `/taxi sim`, let the real warlock cast the summon
      (G5), accept it (G6), then `/taxi sim off`. Expect: the real guard panel
      shows beside the real popup (G7). The real arrival (rating and tip)
      window and the real shift-end window do **not** show during the sim,
      because they are tied to the real character being the active one; by the
      code they are not replayed after `/taxi sim off` either, so that ride's
      rating prompt is lost. The ride-request toast and clicker offers (views
      over Engine state) should come back at once after `/taxi sim off`; that
      is read from the code, not seen, so verify it. Record what you see, and
      that `/taxi debug` stays at 0 errors.

### Only the game can tell
- [ ] The glyphs draw (not as boxes). Do: look at each place: the board and
      the arrival window in the sim, a guard panel, the shift-end window and
      `/taxi debug`. Where each one appears: ★ in the trust and share lines
      ("★ 4.7 · 6 summons") on the Travel and Clicking rows and on the clickable
      stars of the arrival and shift-end windows; ⚠ in "⚠ 1 reported death" on a
      stand row and in the arrival window's "⚠ You landed away from the agreed
      spot."; → in the yellow guard line "Not a Taxi ride: X → area"; · in the
      trust line, the stand header, the Clicking rows and the first two
      `/taxi debug` lines; ✓ ✗ at the start of each Summon Guard line (and ✓ after "Received"
      in the shift-end window); … in "… more checks failed" (only with more
      than nine checks, so rarely). The swap points: ★ ✓ ✗ are `W.STAR`,
      `W.CHECK` and `W.CROSS` (one line each, `Taxi/UI/Widgets.lua`); the rest
      sit inside strings in `Taxi/Core/Locale.lua` (★ `TRUST_LINE`,
      `SHARE_LINE`; ⚠ `DEATHS_ONE`, `DEATHS_MANY`, `ARRIVE_WRONG`; → `GUARD_NO_RIDE`;
      · in many strings; … `GUARD_MORE_FAILED`). The guard panel's title still
      says GREEN, YELLOW or RED and its lines are colour-coded, so a missing
      glyph there is cosmetic.
- [ ] The windows' X buttons work; the toast's X brings up the next request.
- [ ] `PlaySound(SOUNDKIT.READY_CHECK)` and `SOUNDKIT.RAID_WARNING` are heard.
- [ ] Esc closes the request dialog (it is in `UISpecialFrames`).
- [ ] Windows show and answer clicks during combat (try with a target dummy).

### Needs a real summon
Moved to area G, where a real warlock is at hand: the panel beside Blizzard's
popup and the real panel during `/taxi sim` are G7; Decline summon cancelling
the real popup is G10.

## Part 2: the real client

### A. Install and load (alone)

- [x] **A1. TOC `## Interface:` value.** DONE 2026-10-17: you confirmed `16001`
      in game (`/dump (select(4, GetBuildInfo()))`); it matches `Taxi/Taxi.toc`.
- [ ] **A2. The addon loads and is not "out of date".** Do: copy the `Taxi`
      folder into the client's `Interface\AddOns` (see the README for the
      folder), log in with "Load out of date AddOns" **unticked**. Expect: Taxi
      is in the AddOns list, enabled, no out-of-date mark. If wrong:
      `## Interface:` in `Taxi/Taxi.toc`.
- [ ] **A3. No TOC filename suffix needed (spec §16.1).** Do: after A2, open
      the AddOns list (character select screen). Expect: "Taxi" is listed with
      the note "Trust-based summon and portal board for WoW Forever" while the
      file is the plain `Taxi.toc`. If Taxi is missing, Forever wants a
      suffixed TOC name.
- [ ] **A4. A quiet, healthy start.** Do: `/reload`, wait 10 seconds,
      `/taxi debug`. Expect: no Lua error popup, no "action blocked" popup, and
      three lines: `Taxi 0.1.0 · protocol 1 · data 1`, `Engine running ·
      Hardcore <true or false> · last status: none`, `0 errors logged; the last
      0:`. This also proves several assumptions at once: `ADDON_LOADED` names the
      addon `Taxi`; `PLAYER_LOGIN` and `PLAYER_ENTERING_WORLD` fire again after
      `/reload`; `RegisterAddonMessagePrefix("TaxiFvr")` returned 0 (any other
      result shows as an error line); `C_AddOns.GetAddOnMetadata("Taxi",
      "Version")` works (a `?` instead of `0.1.0` means it does not); and the
      `·` glyph renders.
- [ ] **A5. The legacy globals exist** (they are not in Forever's generated API
      docs, so the PC cannot know). Do, one line at a time:
      `/run for _,n in ipairs({"CreateFrame","IsInRaid","GetNumGroupMembers","GetNumSubgroupMembers","GetNumGuildMembers","GetGuildRosterInfo"}) do if not _G[n] then print("MISSING",n) end end print("checked")`
      `/run for _,n in ipairs({"JoinChannelByName","GetChannelName","InitiateTrade","UNKNOWNOBJECT","ERR_TRADE_COMPLETE","date"}) do if not _G[n] then print("MISSING",n) end end print("checked")`
      Expect: only `checked` each time. A `MISSING` line names an API the
      adapter calls that Forever lacks.
- [ ] **A6. SavedVariables are written.** Do: play a minute, `/reload` (or log
      out). Expect: `Taxi.lua` exists under `WTF\Account\<account>\SavedVariables\`
      (it holds `TaxiDB`, with `["version"] = 1`) and under
      `WTF\Account\<account>\<Realm>\<Character>\SavedVariables\` (it holds
      `TaxiCharDB`, with `stand = {seats = 3, clickerPct = 25, note = ""}`).

### B. Chat channel and addon messages

- [ ] **B1. The channel is joined and General and Trade keep /1 and /2.**
      Needs: alone. Do: log in, wait about 10 seconds, then run
      `/run print(GetChannelName("TaxiForever"))` and
      `/run print(GetChannelList())`.
      Expect: the first prints a number above 0 and `TaxiForever`; the second
      still lists General as 1 and Trade as 2 (Taxi joins 5 seconds after
      entering the world so the numbers do not shift). If wrong: `JOIN_DELAY` in
      `Taxi/Core/Init.lua`.
- [ ] **B2. How long the join takes** (is the channel id there at once, or
      later?). Do: `/run local t=GetTime();JoinChannelByName("TaxiTest");C_Timer.NewTicker(.1,function(k)if GetChannelName("TaxiTest")>0 then print("id after",GetTime()-t);k:Cancel()end end,100)`
      then `/leave TaxiTest`. Expect: `id after <seconds>`. Record the number.
      Taxi waits up to 10 seconds. If it prints more than 10 or nothing while
      free slots exist, raise `JOIN_TIMEOUT` in `Taxi/Core/Init.lua`.
- [ ] **B3. `/reload` while in the channel does not break it, and Taxi does not
      join twice.** Do: `/reload`, wait 10 seconds, then run
      `/run print(GetChannelList())` and `/taxi debug`. Expect: TaxiForever is
      listed once with the same number as before, no new "Joined Channel" line
      for it appears in chat after the reload (the channel was still joined,
      so Taxi does not join again), `/taxi debug` says `Engine running`, 0
      errors.
- [ ] **B4. All 10 channel slots taken.** Do: `/join` test channels until
      `/run print(GetChannelList())` shows 10, leave Taxi's out of them (`/leave
      TaxiForever`) and `/reload`. Expect: the join leaves the id at 0; about 15
      seconds after entering the world chat says `Taxi: Taxi needs a free chat
      channel. Leave one (e.g. /leave 5) and /reload.` (chat only while the
      Taxi window is closed; with it open the line is in the footer);
      `/taxi debug` says `Engine disabled (no channel)`; a Request says "Taxi
      has no chat channel, so nothing can be sent."; after leaving one test
      channel and `/reload`, Taxi runs. Clean up the test channels.
- [ ] **B5. Send results are the enum numbers (0, 3, 8, 11).** Do:
      `/run print(C_ChatInfo.SendAddonMessage("TaxiFvr","x","CHANNEL",tostring(GetChannelName("TaxiForever"))))`
      and then, to hit the throttle,
      `/run for i=1,15 do print(C_ChatInfo.SendAddonMessage("TaxiFvr","x","CHANNEL",tostring(GetChannelName("TaxiForever")))) end`
      Expect: the first prints `0` (a number, not `true`); the burst prints 0s
      and, once the game's throttle bites, 3 (addon-message throttle) or 8
      (channel throttle). Inside an instance the same call gives 11 (M1). Other
      Taxi clients ignore the `x`. If wrong: the result mapping in
      `backend.send` (in `Backend.new`, `Taxi/Game/WoW.lua`) and the codes
      `Taxi/Comms/Transport.lua` reads.
- [ ] **B6. Channel messages reach other players.** Needs: 2 accounts in the
      channel. Do: A pastes the addon-messages helper; B opens a stand (My stand
      tab, Open stand). Expect: A's chat prints lines starting with `CHANNEL`
      and B's name; A's Travel tab lists B's stand within seconds. If the
      lines never come, the send target for `CHANNEL` in `backend.send` (the
      channel's id as a string) is wrong.
- [ ] **B7. Channel limits with many users (spec §16.8).** Needs: a busy place
      and a few players with Taxi. Do: leave Taxi running a while where many
      players have it; try `/chatlist TaxiForever` (if Forever has the
      command) to count members. Expect and record: how many members the
      channel holds; whether a join ever fails because the channel is full
      (Taxi would then show the "needs a free chat channel" line, which would
      be the wrong advice); whether every open stand shows on a second client
      within about a minute; whether `/taxi debug` shows send or throttle
      errors. If the channel does not scale, the channel name needs sharding:
      report it, it is a design change.
- [ ] **B8. The newer-version notice.** Needs: 2 accounts. Do: on one, change
      `PROTOCOL = 1` to `2` in `Taxi/Core/Config.lua`, `/reload`, and open a
      stand; leave the other on 1. Expect: the other client says "A newer Taxi
      version is in use. Please update." once (in chat while its window is
      closed, in the footer while it is open) and does not list the stand.
      Change `PROTOCOL` back afterwards.

### C. Names (the most important area)

A player is their full two-part name, compared exactly. These must come out
identical after Taxi tidies them: `UnitName("party1")`, the summoner in the
summon popup, the `CHAT_MSG_ADDON` sender, the guild roster and
`HARDCORE_DEATHS`. The tidying is `canonical()` in `Taxi/Game/WoW.lua`: it drops
your own realm's `-Realm` suffix (another realm's is kept) and runs
`Names.normalize`, which only collapses ASCII whitespace, so a special surname
separator survives.

- [ ] **C1. The form of a name.** Needs: 2 chars in a party. Do:
      `/run print(UnitName("party1"))`, `/dump {(UnitName("party1")):byte(1,-1)}`
      and `/run print(GetNormalizedRealmName())`.
      Expect: a two-part name (first name and surname). Record the separator
      byte (32 is an ordinary space; anything else is a special separator,
      which Taxi keeps as it is) and whether `UnitName` returns a realm as its
      second value (nothing is normal on your own realm).
- [ ] **C2. `UnitName` shows the surname.** Do: `/run print(C_PlayerInfo.ShouldDisplaySurname(),UnitName("player"),UnitNameUnmodified("player"))`
      Expect: the two names are the same full two-part name. If `UnitName`
      returns only a first name while surnames are hidden, switch `fullName` in
      `Taxi/Game/WoW.lua` to `UnitNameUnmodified`.
- [ ] **C3. The summoner's name in the summon popup.** Needs: a summon popup
      showing (it stays about two minutes). Do: `/run print(C_SummonInfo.GetSummonConfirmSummoner())`
      Expect: exactly the string of C1 for that warlock (same separator).
- [ ] **C4. The `CHAT_MSG_ADDON` sender.** Do: the addon-messages helper while
      the other player's Taxi talks (a stand heartbeat). Expect: the same name
      as C1; a `-Realm` suffix equal to `GetNormalizedRealmName()` is fine (Taxi
      drops your own realm's suffix). A player from another realm may come as
      `Name-OtherRealm`; record how it looks next to `UnitName` for the same
      player.
- [ ] **C5. The guild roster name.** Needs: a guild. Do: `/run print(GetNumGuildMembers(),GetGuildRosterInfo(1))`
      Expect: a number above 0 and a name in the same form as C1 (possibly with
      `-Realm`).
- [ ] **C6. The `HARDCORE_DEATHS` name.** Needs: Hardcore live and two
      characters with the death-notices helper (Setup). Do: as in L2; compare
      the name the helper prints with C1's. Expect: the same form as `UnitName`
      (Taxi matches deaths to rides by that name). If it differs, fix
      `canonical()` or the `HARDCORE_DEATHS` handler in `Taxi/Game/WoW.lua`.
- [ ] **C7. The names agree end to end.** Needs: the 4-character run. Do: G1
      to G7 and read the first line of T's Summon Guard panel. Expect: "✓
      Summoner: W". If it says "✗ Summoner: X (agreed: Y)" while X and Y look
      the same, the forms differ: compare the bytes from C1, C3 and C4 and fix
      `canonical()` or `fullName()` in `Taxi/Game/WoW.lua`.
- [ ] **C8. The invite and the whisper accept that form.** Needs: the
      4-character run. Do: G2 to G4 (T presses Send, W presses Accept in the
      toast). Expect: W's toast appears (the whispered REQUEST arrived), T gets
      the party invite (`C_PartyInfo.InviteUnit`) and T's row says "Accepted -
      join group" (the whispered ACCEPT arrived). If a name with a surname
      separator is refused, look at `Game.invite` and `backend.send` in
      `Taxi/Game/WoW.lua`.
- [ ] **C9. Names are never "secret" in the open world, and the not-yet-loaded
      placeholder.** Do: during G4 run `/run print(UnitName("party1"))` the
      moment T joins (a few times), run `/run print(UNKNOWNOBJECT)`, and after
      a group session `/taxi debug`. Expect: `UnitName` gives a real name (or
      the text `UNKNOWNOBJECT` holds, which the adapter treats, like
      `Unknown`, as no name); `/taxi debug` shows no secret-value error; the
      group lists show real names. Record what `UnitName("party1")` returned
      for a member who had only just joined.

### D. Position, map, levels and group counts

- [ ] **D1. `UnitPosition` for group members.** Needs: 2 chars in a party, in the
      open world. Do: `/run print(UnitPosition("party1"))` with the other player
      in sight and again far away. Expect: numbers both times; inside an
      instance, nothing. (The guard's "Warlock is at the stand" check needs it;
      when the position is unknown the check fails and the panel is RED.)
- [ ] **D2. Raid members have a map and a position.** Needs: a raid. Do:
      `/run print(C_Map.GetBestMapForUnit("raid2"))` and
      `/run print(UnitPosition("raid2"))`. Expect: a map id and position
      numbers. Forever's docs promise `GetBestMapForUnit` only for the player
      and party members, so raid support is an assumption (Task 16 report, item
      12). If either is nil in a raid, the position check cannot be answered for
      raid rides and the guard goes RED there.
- [ ] **D3. Map levels.** Do: stand in a capital, then in a zone, and run
      `/run print(C_Map.GetMapLevels(C_Map.GetBestMapForUnit("player")))`.
      Expect: zeros (or nothing) in a city, the zone's level range in a zone.
      Taxi treats 0 as unknown. The guard shows YELLOW "Zone is level 40+, you
      are 20" when a low-level traveler is summoned somewhere higher (G9).
- [ ] **D4. Your own place.** Do: `/run local m=C_Map.GetBestMapForUnit("player");local p=C_Map.GetPlayerMapPosition(m,"player");print(m,C_Map.GetMapInfo(m).name,p:GetXY())`
      and `/run print(GetZoneText(),"|",GetSubZoneText())` Expect: a map id, its
      name and x, y between 0 and 1; the zone and subzone texts. A stand opened
      here shows "Zone - Subzone" on another client (E1): the zone is that
      client's own name for this map id (the map name printed above, in its
      language), never this zone text; the subzone is this client's text. In a
      capital the subzone may be empty.
- [ ] **D5. Group counts.** Do: `/run print(IsInRaid(),GetNumGroupMembers(),GetNumSubgroupMembers())`
      alone, in a party of 3, and in a raid of 6. Expect: `false 0 0`, `false 3 2`
      (the member count includes you, the subgroup count does not), then `true 6`
      and the size of your subgroup. Taxi's group size and "needs a raid"
      decisions rest on these.

### E. The board and stands (2 characters: W the warlock, T the traveler)

- [ ] **E1. A stand shows up on another client.** Do: W opens `/taxi`, My stand,
      "Warlock summons", Seats 3, Clicker share 25, a note, Open stand. Expect:
      W sees "Your stand is open." and the header "Recruiting clickers" with
      "Seats 3 (3 free) · Clickers 0/2 · 25% of the tips each"; another
      character sees W's row on the Clicking tab within a heartbeat (60 seconds
      at most), but T's Travel > Summons does not list it: a stand still
      recruiting clickers is not offered to travelers. Once two clickers are on
      (F2) or two crew members were added (F4), T sees W's row on Travel >
      Summons within a heartbeat, in the right zone group (T's own client's
      name for W's map, D4), with its free seats; selecting the row shows the
      note, the clickers and the trust line, and sends one query.
- [ ] **E2. Guildmates are green and first.** Needs: a guildmate with Taxi.
      Do: the guildmate opens a stand (E1) while another stand is open too;
      look at Travel > Summons. Expect: the guildmate's row is green and above
      the non-guild rows (the roster names match, C5).
- [ ] **E3. A stand that goes quiet leaves the board.** Do: end W's game without
      a clean close (kill the process). Expect: T's row is gone within about 3
      minutes and 5 seconds.
- [ ] **E4. The stand closes when its owner walks away.** Do: W walks more than 50
      yards from where the stand was opened. Expect: within a few seconds W's My
      stand tab goes back to the form, W's footer (or chat, with the window
      closed) says "Your stand closed because you moved away from it.", and T's
      row goes. ("Your stand is closed." is the answer to pressing Close stand.)
- [ ] **E5. The Travel tab controls.** Do: open the zone dropdown, pick a zone,
      pick "All zones", click elsewhere while it is open, toggle Portals and
      Summons. Expect: the list opens under its button, filters, resets, closes
      on an outside click; Portals shows mage stands.
- [ ] **E6. The request round trip.** Do: T presses Request on W's row (a dialog
      opens), picks a tip, Send. Expect: T's button shows "Waiting for an
      answer"; W's toast appears (G3). When W presses Decline: T's footer says
      "W declined your request." and the Request button comes back.
- [ ] **E7. The stand header follows reality.** Needs: W with two clickers
      (F2). Do: W opens the stand; then (a) W or a clicker enters combat and
      leaves it; (b) W puts the soul shards in the bank, and takes them back.
      Expect: the header reads Recruiting clickers before the clickers join,
      Live once both have; Paused with "(in combat)" while W or a clicker is in
      combat; Paused with "(no soul shards)" while W has none, each within a
      moment. T's row on Travel > Summons says "Paused", with its Request
      button off, from W's next heartbeat on (60 seconds at most).
- [ ] **E8. The form refuses wrong input in plain words.** Do and expect: seats 0
      says "Seats must be a whole number from 1 to 37."; "Warlock summons" on a
      non-warlock says "Only a warlock can open a summon stand."; "Mage portals"
      on a character with no portal spell says "You don't know any portal spell
      yet."; a warlock below level 20 says "Ritual of Summoning needs level
      20."; inside an instance, "You can't open a stand inside an instance.";
      opening a second stand says "Your stand is already open."
- [ ] **E9. Message limits.** Do: type the longest note the box allows and open
      the stand. Expect: it either arrives whole on T's detail line or the form
      says "That note is too long to send."; never a Lua error. (Messages are at
      most 255 bytes; Taxi chunks longer ones.)
- [ ] **E10. Faction filter.** Needs: one character of each faction. Do: the
      other faction's character opens a stand (E1); look at Travel > Summons
      on the first faction's client. Expect: the stand is not on the board. If
      Forever does allow cross-faction groups, drop the `faction = ...` filter
      in `Taxi/UI/StandList.lua` and `Taxi/UI/Clicking.lua`.

### F. Clickers and crew (3 characters: W, C1, C2)

- [ ] **F1. Applying and the offer.** Do: C1 opens the Clicking tab. Expect: W's
      stand is listed with "Share ★ ... · n shifts" (or "Share: no ratings
      yet"), "Offers 25%" and "Needs 2 clickers". C1 presses Apply. Expect: C1
      sees "You asked W for 25% and are waiting for an answer."; W gets a
      "Clicker offer" window ("C1 asks for 25%", "You offered 25%") with Accept,
      Counter and Decline, and the same application is listed under Clicker
      applications on My stand.
- [ ] **F2. Accept brings the clicker in.** Do: W presses Accept (in the offer
      window or on My stand). Expect: C1 is
      invited, joins the group, and appears in W's Crew section with "25% of the
      tips" and a Dismiss button; C1's Clicking tab shows "On shift for W at
      25% of the tips".
- [ ] **F3. Counter-offers.** Do: C2 asks for another percentage (type it in the
      asked-% box, Apply); W types a different number in the offer window and
      presses Counter. Expect: C2 gets a "Counter-offer" window (and a line on
      the Clicking tab) saying "W offers N% instead (you asked M%)." with Take
      it and Decline; Take it brings C2 in at N%; the asked-% box keeps what you
      typed through the 5-second repaint.
- [ ] **F4. Crew by hand.** Do: W types a group member's name in the "Crew
      member" field and a percentage in the "%" box, then presses Add. Expect:
      the member is listed in the "Crew" section; a name outside the group says
      "They are not in your group."; adding the same member twice says "They
      are already in your crew."
- [ ] **F5. Dismiss and leave.** Do: W dismisses a clicker; another clicker
      presses Leave. Expect: the crew count drops, the stand header says
      Paused (it was live; it says Recruiting clickers only for a stand that
      never had both), the stand is on the Clicking tab again ("Needs 1
      clicker"), and the clicker's Clicking tab says "You are not on a shift."
      (or shows the last shift).
- [ ] **F6. Shift end and payout.** Needs: a tipped ride (I4). Do: C1 presses
      Leave on the Clicking tab. Expect: C1 gets "Shift ended" with "Owed ... ·
      Received ...", stars suggested from what was paid (or optional when
      nothing was owed); W's Payouts show "Owed ... · paid ..." with a Pay
      button (I6).

### G. Summons: the full run (4 characters: W, C1, C2, T)

Start W and T far apart: in another zone, or at least 100 yards away on the same
map. (Taxi recognises an arrival only when the summon moves T to another map or
more than 100 yards; a summon that moves T less is not seen as an arrival.) W
should stand in a zone with a known level range. This run also settles spec §16
questions 2 and 3 (steps G6 and G8). Do it on a normal ruleset first.

- [ ] **G1. W opens the stand and the clickers join.** Do: E1 for W, then F1
      and F2 for C1 and for C2. Expect: header "Live", "Clickers 2/2".
- [ ] **G2. T requests with a tip.** Do: T: Travel > Summons > W > Request >
      1g > Send. Expect: footer "Requested a seat from W."; T's Request button
      on W's row turns into "Waiting for an answer".
- [ ] **G3. W's toast.** Do: W watches the screen after G2. Expect: a window
      "Ride request" with a sound, naming T, T's level, "Wants a summon",
      "Offers 1g" (and "Guildmate" if applicable). Accept invites T.
- [ ] **G4. T joins.** Do: T accepts the party invite by hand; W and T watch
      their tabs. Expect: W's My stand first says "Invited - waiting for them
      to join", then "In your group"; T's row says "In group - awaiting
      summon". Also, once: T declines the first invite; W's row still says
      "Invited - waiting for them to join" and has a Re-invite button, which
      sends a new invite and says "Invited T again." in W's footer.
- [ ] **G5. The secure Summon button** (W). Do: W looks at the button before T
      has joined (G4) and after, then clicks it once. Expect: the button reads
      "Summon T" and is enabled once T has joined; before that it is greyed and
      "Nobody in your group is waiting" shows. The click: Ritual of Summoning (spell 698)
      starts on T, whoever W has targeted. This must work with "Cast action
      keybinds on key down" both on and off (Options > Controls). C1 and C2 get
      the banner "Portal is up - click it!" with a sound, exactly once per
      click; W's row for T says "Being summoned" (only a ride W summoned this
      way is logged when T arrives, R52). If the cast fails or hits the wrong
      target, look at the secure button in `Taxi/UI/MyStand.lua`.
- [ ] **G6. Where T lands (spec §16.2).** Do: C1 and C2 click the portal; T
      accepts by hand. Test twice: (a) W stays put; (b) W walks about 45 yards
      from the portal first (the stand stays open below 50 yards, and the guard
      should go RED because W is beyond 40; T accepts anyway, which is only
      acceptable on a normal ruleset). Expect and record, for each: T lands at
      W's position at the time of accepting, or at the portal; the distance
      between T and the stand afterwards. The guard's check 3 judges the
      warlock against the stand, and Taxi calls T arrived wherever T lands
      (the arrival window shows "⚠ You landed away from the agreed spot." when
      it is not at the stand). If the landing can differ from the stand, note
      it in the report.
- [ ] **G7. The Summon Guard panel with a real popup.** Do: watch T when the
      summon popup appears. Expect: the panel sits to the right of Blizzard's
      popup (it anchors to `StaticPopup_FindVisible("CONFIRM_SUMMON")`; with no
      popup it would sit at the top centre) and shows the checks: "✓ Summoner:
      W", "✓ Destination: ...", "✓ Warlock is at the stand", "✓ Nobody in
      combat", "✓ Zone level is fine", "✓ Stand hasn't moved", and a last line
      for the Trust rating. A brand-new warlock is "New", and the guard warns
      about that: expect "✗ Low or new Trust rating" and a YELLOW panel ("Summon
      Guard: YELLOW - be careful") with no button until W has at least 5
      direct ratings and a good score; then it reads "✓ Trust rating OK" and a GREEN
      panel ("Summon Guard: GREEN - matches your ride"). Note which you got.
      The panel appearing at all is the proof that `CONFIRM_SUMMON` fires for a
      warlock's Ritual of Summoning in Forever. With `/taxi sim` running at the
      same time, the real panel must still show (title without "(sim)") beside
      the real popup, and the sim's panel stays at the top centre. While the
      popup is up the panel keeps checking: when a clicker starts a fight
      (attack a target dummy) it turns RED at once ("✗ In combat: C1"), and
      back when the fight ends.
- [ ] **G8. What `GetSummonConfirmAreaName()` returns (spec §16.3).** Do: with
      the popup up, `/run print(C_SummonInfo.GetSummonConfirmAreaName(),"|",GetZoneText(),"|",GetSubZoneText())`
      (run it for the destination: ask W to read their zone and subzone aloud
      too). Expect and record: the popup's area is the zone or the subzone of
      W's position, and T's `/run print(C_Map.GetMapInfo(<W's map id>).name)`
      (the map id from D4 on W) gives the same zone name. The guard compares the
      area with T's own name for the stand's map (the stand's zone text from
      W's addon only when T's client has no name for that map) or the
      subzone, so "Destination: ..." must show a tick; a ✗ on an honest ride
      means the text is something else (a continent, a sub-map's name), and
      `Game.summonFacts` or the map lookup needs adjusting.
- [ ] **G9. A real YELLOW and RED.** Needs: a second warlock (the clicker can be
      one). Do: (a) with T in no ride, the other warlock summons T: YELLOW
      "Not a Taxi ride: X → area". (b) While T is in W's ride (G4), the other
      warlock summons T: RED, "✗ Summoner: X (agreed: W)", and only a Decline
      summon button, no accept button. (c) A low-level T summoned into a higher
      zone: YELLOW "Zone is level N+, you are M".
- [ ] **G10. Decline summon cancels the real popup.** Do: on a RED panel, press
      Decline summon. Expect: Blizzard's popup closes
      (`C_SummonInfo.CancelSummon`; the game's `CANCEL_SUMMON` is what clears
      the panel), the panel goes, no Lua error. The panel never accepts
      anything itself.
- [ ] **G11. The popup going away is noticed.** Do: T accepts a summon. Expect:
      within about a second the guard panel goes away and the arrival window
      opens (summon gone is read by polling `GetSummonConfirmSummoner` and
      `GetSummonConfirmTimeLeft`). If the panel stays until the popup would have
      expired, neither call clears after an accept.
- [ ] **G12. Arrival.** Do: T accepts the summon (G6) and looks at the window
      that opens. Expect: the arrival window "You arrived" with the rating
      stars ("Rate W (Trust):"), the tip picker with 1g already picked, Open
      trade with W, Stay and click, Leave group. History shows "Summon from W"
      with "Arrived" on T and "Summon for T" on W.
- [ ] **G13. A summon that is declined or runs out.** Do: W casts again and T
      lets the popup expire (or declines it on Blizzard's popup). Expect: after
      the popup goes (up to about 30 seconds, the time Taxi waits for a landing)
      T's row goes back to "In group - awaiting summon" once; a second failed
      summon ends the ride ("Your request to W ended without a ride."). No
      rating window either time. Also: with the popup up, T uses the
      hearthstone (or takes a flight path); no arrival window opens, then or
      when the popup goes.
- [ ] **G14. Portal-up alerts travel as group addon messages.** Do: C1 pastes
      the addon-messages helper (Setup) before G5, then W clicks Summon; repeat
      in the raid of H3. Expect: C1's helper prints a line with `PARTY` (and
      `RAID` in a raid) and W's name, and the banner "Portal is up - click it!"
      shows once per click. If it says `PARTY` in a raid, clickers in other
      subgroups miss the banner (`Engine:groupDist`, `Taxi/App/Engine.lua`).

### H. Raid conversion (6 characters: W, C1, C2, T1, T2, T3)

- [ ] **H1. The button changes.** Do: get W, C1, C2, T1, T2 into the group (5),
      then T3 requests. Expect: on W's toast and in My stand, the Accept button
      for T3 reads "Convert to raid & invite" and nothing was converted yet.
- [ ] **H2. `ConvertToRaid` works from the click (spec §16.5).** Do: W presses it.
      Expect: "Converting the group to a raid..." shows; within 5 seconds
      `/run print(IsInRaid())` says `true` for everyone; then T3 is invited
      and accepts; no "action blocked" popup. Record whether the game asks for a
      confirmation. If `ConvertToRaid` is blocked from the click, the flow
      ends with "Couldn't convert the group to a raid. Convert it from the
      group menu, then press Accept again." after 5 seconds and the request
      stays pending: convert by hand, then Accept should work.
- [ ] **H3. Rides work in a raid.** Do: with 6 in the raid run G5 to G12 for T1.
      Expect: the Summon button targets the right traveler among raid units;
      the portal-up banner reaches C1 and C2; the guard panel reads GREEN;
      `C_Map.GetBestMapForUnit` for raid units works (D2).
- [ ] **H4. A group leader who is not W.** Do: make a clicker the leader and press
      Convert as W. Expect: "Couldn't convert the group to a raid. Convert it
      from the group menu, then press Accept again." after 5 seconds, and the
      request is back as pending.

### I. Trade, tips and payouts (needs a completed ride; Forever's Hardcore trade rules are in I8)

- [ ] **I1. Open trade, and the Put button (R64).** Needs: T still in W's
      group and within trade range. Do: T presses Open trade with W in the
      arrival window (1g picked); W accepts the trade request; T watches the
      window as the trade window opens. Expect: T's arrival window shows the
      hint "Put 1g in the trade" and, under it, a button "Put 1g in the trade"
      that is greyed out until the trade window with W is open and enabled
      once it is (it may take up to half a second to switch). No "action
      blocked" popup. Open trade only opens the trade and never touches the
      gold field (the trade window that opens may be another player's): only
      the Put button's click (I2) sets the money. T must not press Leave group first: Taxi only opens a
      trade with a group member (otherwise "The game would not open a
      trade.").
- [ ] **I2. `SetTradeMoney` from the Put button click (spec §16.4).** Needs:
      the trade window open (I1). Do: T clicks the Put button, then looks at
      the gold field in the trade window; then T picks another tip amount (the
      button and the hint change to it), empties the gold field and clicks the
      button again. Expect and record: whether the click puts the gold in the
      trade window, and whether an "action blocked" popup appears. The hint
      "Put 1g in the trade" stays either way (Taxi cannot read the amount
      back), so check the gold yourself before accepting the trade. Closing the
      trade window greys the button out again. Also run
      `/run print(GetPlayerTradeMoney)`: a `function` means the old getter
      exists in Forever and Taxi could read the amount back (that needs a
      decision, it is not in the API docs); `nil` means it does not.
- [ ] **I3. The trade partner is "NPC".** Do: with the trade window open,
      `/run print(UnitName("NPC"))` Expect: the partner's name in the form of C1.
- [ ] **I4. A completed trade is a recorded tip.** Needs: a ride that ended
      in the arrival window (G12), T still in W's group, C1 and C2 on the crew
      at 25%. Do: T puts 1g in the trade, both accept. Expect: chat says "Trade
      complete." (`/dump ERR_TRADE_COMPLETE` shows the same text, which Taxi
      matches in the `UI_INFO_MESSAGE` event); within about 3 seconds the tip is
      recorded: W's My stand Payouts show "Owed 25s · paid 0c" for each
      clicker, and each clicker's Clicking tab shows "Owed 25s · received 0c".
      A cancelled trade and an items-only trade record nothing.
- [ ] **I5. `InitiateTrade(unit)`.** Do: `/run InitiateTrade("party1")` within
      trade range. Expect: the other player gets a trade request.
- [ ] **I6. Paying a clicker.** Do: W presses Pay on a Payouts row. Expect: a
      trade request to that clicker (a clicker outside the group says "The game
      would not open a trade."); after W puts the gold in and the trade
      completes, the row shows the amount as paid and the clicker's shift-end
      window shows what was received.
- [ ] **I7. Money arrives in time.** Do: complete three 1g trades (I4, I6) and
      each time note how long after the trade window closes the Payouts line
      (W) or the "Owed ... · received ..." line (clicker) updates. Expect:
      within about 3 seconds each time (the game's `PLAYER_MONEY` must show by
      then, or the trade is not recorded). If tips are missed, raise
      `TRADE_SETTLE_SECONDS` in `Taxi/Game/WoW.lua`.
- [ ] **I8. Forever Hardcore trade rules (spec §16.7).** Not published at the
      time of writing. Do: on a Hardcore character, trade gold with a group
      member. Expect and record: allowed or blocked, with the game's message.
      If Hardcore blocks trading, the tip flow (arrival window and Payouts)
      has to change; report it.

### J. Mage portals (M the mage, T the traveler)

- [ ] **J1. Spell ids and names.** Do: `/run for _,i in ipairs({698,10059,11416,11419,11417,11418,11420}) do print(i,C_Spell.GetSpellName(i),C_SpellBook.IsSpellKnown(i)) end`
      on the mage, and on the warlock for 698. Expect: 698 is Ritual of
      Summoning (true for a warlock who learned it); 10059 Portal: Stormwind,
      11416 Portal: Ironforge, 11419 Portal: Darnassus, 11417 Portal:
      Orgrimmar, 11418 Portal: Undercity, 11420 Portal: Thunder Bluff; `true`
      exactly for the portals the mage has learned. A wrong name or a `false`
      for a portal the mage has means that id in `Taxi/Core/Config.lua`
      (`PORTALS`, `RITUAL_SPELL`) is wrong. Also record any portal Forever has
      that is not in the table.
- [ ] **J2. Destination map ids.** Do: stand in each capital and run
      `/run print(C_Map.GetBestMapForUnit("player"))`
      Expect: Stormwind 1453,
      Ironforge 1455, Darnassus 1457, Orgrimmar 1454, Undercity 1458, Thunder
      Bluff 1456 (the `mapID` of each `PORTALS` entry in `Taxi/Core/Config.lua`;
      a portal rider counts as arrived when their map is that id).
- [ ] **J3. Soul shard id.** Do: with shards in your bags, run
      `/run print(C_Item.GetItemCount(6265))` and
      `/run print(C_Item.GetItemInfo(6265))` (twice if the first prints
      nothing). Expect: the count matches the shards
      in your bags (it changes when you move one to the bank); the item is
      "Soul Shard".
- [ ] **J4. The mage's stand.** Do: M opens `/taxi` > My stand > "Mage portals".
      Expect: the form lists the portals M knows; the stand header shows "Seats
      N (n free) · <portal names>"; T's Travel > Portals shows "Portals: ...".
- [ ] **J5. Asking for a portal.** Do: T presses Request on M's row. Expect: a
      menu asks which portal (a stand with several), then the dialog "Portal to
      Darnassus from M"; M's toast says "Wants a portal to Darnassus"; Accept
      invites T.
- [ ] **J6. The portal button.** Do: M clicks the button. Expect: it reads
      "Open portal to <city>" and casts the right portal spell with no target
      needed; T gets the banner "Portal to <city> is up - click it!" with a
      sound.
- [ ] **J7. Arrival by portal.** Do: T walks to M and steps through. Expect: the
      arrival window opens when T's map is the destination city (J2), with a
      tip picker and Open trade but no stars and no Stay and click; no Summon
      Guard panel was involved.

### K. Ratings, sync and saving (3 or more accounts)

- [ ] **K1. A rating spreads.** Needs: a finished ride (G12) and a third
      account X online. Do: T rates W 5 stars in the arrival window (Send rating
      or Open trade). Expect: T's window says "Rating sent."; within a minute X's
      Travel row for W shows the new count (for W's first ride, "★ 5.0 · 1
      summon · New").
- [ ] **K2. The save reminder.** Do: after K1 on T's client, out of combat, open
      `/taxi`. Expect: the footer's second line says "New ratings are saved on
      /reload or logout."; it disappears in combat; after `/reload` the rating is
      still there and the line is gone.
- [ ] **K3. A newly installed client catches up.** Do: log in a character on an
      account with no Taxi data (a fresh account, or delete `Taxi.lua` from
      `SavedVariables` with the game closed), open Travel and select W's row.
      Expect: within about 10 seconds the count and stars fill in from other
      players' replies (ratings arrive after a 0 to 5 second jitter, one query
      per warlock every 10 minutes).
- [ ] **K4. History.** Do: after a ride as traveler, a declined request, a ride
      given and a clicker shift, open the History tab. Expect: all four, newest
      first, with the right titles; `/reload` keeps them.
- [ ] **K5. Guild highlight comes from the real roster.** Needs: a guild and a
      guildmate with a stand open. Do: log in, wait about 10 seconds, open
      Travel, then run `/run print(GetNumGuildMembers(),GetGuildRosterInfo(1))`.
      Expect: the guildmate's row is green and first without any extra step
      (Taxi requests the roster with `C_GuildInfo.GuildRoster()` when it
      starts), and the roster call prints a number above 0 and a name (C5). If
      the row turns green only after you open the Guild window, the roster is
      not requested early enough.

### L. Hardcore (only once Hardcore launches, on throwaway characters)

- [ ] **L1. The rules flag.** Do: `/run print(C_GameRules.IsHardcoreActive())`
      Expect: `true` on Forever Hardcore, `false` on the other rulesets, and
      `/taxi debug` says the same (`Hardcore true`). Taxi records deaths only
      when it is true.
- [ ] **L2. `HARDCORE_DEATHS` scope (spec §16.6).** Do: every tester pastes the
      death-notices helper; one character dies. Expect and record: who sees
      the notice (everyone on the server, the guild, the group, or only players
      nearby) and the form of the name it carries (same as C1?). If it is
      narrow, observed deaths stay rare and heavy deaths rely on the warlock's
      ride log and the victim's own report; that is by design, but note it.
- [ ] **L3. A death after a ride.** Do: T (a throwaway Hardcore character) is
      summoned by W and dies within 2 minutes of arriving. Expect: T's client
      reports it; on a third client W's row shows "⚠ 1 reported death" and a
      lower stars value; T's own window shows the red banner "Your Hardcore
      character has died." with every action button off.
- [ ] **L4. A dead character logging in.** Do: log in a dead Hardcore character.
      Expect: `/run print(UnitIsDeadOrGhost("player"))` says `true`; chat says
      "Taxi: Your Hardcore character has died."; the window shows the banner and
      every action button is greyed; `/taxi debug` shows no errors.
- [ ] **L5. `CONFIRM_SUMMON` on Hardcore.** Needs: Hardcore live and the
      4-character run. Do: W casts Ritual of Summoning on T (G5) and T watches
      the screen. Expect: the same popup and guard panel as on a normal
      ruleset (G7).
- [ ] **L6. A real death during `/taxi sim` is still reported (R62).** Needs:
      Hardcore live, a throwaway T that has just arrived on W's ride (G12), and
      a third client running the addon-messages helper. Do: T types `/taxi
      sim`, then dies within 2 minutes of arriving (with the sim running).
      Expect: the third client's helper prints a `CHANNEL` line from T just
      after the death (the DEATH report), and W's row there shows "⚠ 1
      reported death"; nothing else from T's real addon goes out while the sim
      runs.

### M. Instances and lockdown

- [ ] **M1. The lockdown flag and result code 11.** Do:
      `/run print(C_ChatInfo.InChatMessagingLockdown())` outside, then inside a
      dungeon (and in an encounter); inside, also run the first line of B5.
      Expect and record: when the flag turns `true` (in the instance, or only
      in encounters), and that the send returns 11 (AddOnMessageLockdown) while
      it is.
- [ ] **M2. Entering an instance.** Needs: W with an open stand. Do: walk into a
      dungeon. Expect: chat says "Taxi: Paused (instance)" (or the footer, if
      the window is open) once, W's stand is closed, no Lua error.
- [ ] **M3. No stand inside.** Do: try Open stand inside the dungeon. Expect:
      "You can't open a stand inside an instance."
- [ ] **M4. Sending is held back, not lost or crashing.** Do: inside the
      dungeon press a Request. Expect: no Lua error; the message goes out after
      leaving (or the request ends with "Your request to ... ended without a
      ride."). Record which.
- [ ] **M5. Back outside.** Do: leave the dungeon, then open a stand and
      request a ride (E1, E6). Expect: the "Paused (instance)" line is gone and
      messages flow again (B6).

### N. Windows, art and combat (alone unless noted)

- [ ] **N1. The window and the minimap button.** Do: `/taxi`. Expect: a 600x514
      window with the tabs Travel, My stand, Clicking, History; the minimap
      button on the rim (icon and border look right), left click toggles the
      window, dragging moves it around the rim and the place survives
      `/reload`; Esc closes the window. The tooltip says "Taxi", "Click to open
      Taxi. Drag to move this button." and the status line.
- [ ] **N2. Rows and text fit.** Do: look at the Travel and Clicking lists with
      several stands. Expect: three text lines fit inside each 48-pixel row
      without touching the next row; long names and zones end in "..." instead of
      running into the buttons; the arrows at the right scroll the list and so
      does the wheel; the detail lines under the Travel list are not cut off
      at the bottom; the footer is readable.
- [ ] **N3. The secure button's text fits.** Do: W looks at the button in
      G5 (a warlock) and M in J6 (a mage, "Open portal to Thunder Bluff" being
      the longest). Expect: "Summon <Name>" and "Open portal to <city>" fit the
      button without being cut off. The glyph checks are in Part 1.
- [ ] **N4. Combat and the main window** (the window holds the secure button, so
      Taxi assumes the game protects it and what it hangs from). Do and expect:
      (a) with the window open, enter combat: no "action blocked" popup, texts
      keep updating, a tab button says "Tabs can't be switched during combat.";
      (b) with the window closed, `/taxi` in combat says it opens after combat,
      and it opens by itself when combat ends; (c) with the window open in
      combat, `/taxi` says "Taxi's window can't be closed during combat; press
      Esc." and Esc closes it; (d) the secure Summon button keeps working in
      combat, and after combat it re-aims at the current next traveler; (e)
      **the title-bar X and Esc in combat:** with the window open, click the X
      in combat, then (reopened out of combat) press Esc in combat: both should
      close it with no blocked-action message; if either fails, say so; (f) if
      the window **can** be opened, closed and switched in combat with no
      blocked message, say so, and the guards come out (`Taxi/UI/MainWindow.lua`
      `Show/Hide/Toggle/ShowTab/OnDragStart/OnDragStop` and the swap in
      `Taxi/UI/MyStand.lua`).
- [ ] **N5. The footer.** Do, with `/taxi` open: (a) walk into a dungeon
      (M2); (b) after K1, out of combat, read the lower line; (c) enter combat
      and read it again; (d) press Open stand with seats 0 (E8). Expect: two
      lines. Above: Taxi's status ("Paused (instance)" in (a), the channel
      problem, the newer-version line, or an action's answer for 10 seconds as
      in (d)). Below: "New ratings are saved on /reload or logout." whenever
      there are unsaved ratings and you are out of combat ((b)), gone in (c),
      whatever the line above says.
- [ ] **N6. Statuses go to chat only while the window is closed.** Do: walk
      into a dungeon (M2) and out again, once with the window closed and once
      with it open. Expect: closed, a "Taxi: Paused (instance)" line in chat;
      open, the line is only in the footer.
- [ ] **N7. Sounds.** Do: with game sound on, W gets a ride request (G3) and
      then clicks Summon (G5), and C1 watches. Expect: a ready-check sound with
      the toast (`SOUNDKIT.READY_CHECK`) and a raid-warning sound with the
      clickers' banner (`SOUNDKIT.RAID_WARNING`). If silent, the name is missing
      from `SOUNDKIT` in Forever (`sound()` in `Taxi/UI/Dialogs.lua`).
- [ ] **N8. `/taxi` itself.** Do: type `/taxi`, then `/taxi foo`. Expect:
      `/taxi` toggles the window; `/taxi foo` prints "/taxi opens the window;
      /taxi debug shows version, status and errors; /taxi sim plays a made-up
      world."

### O. The end of a session

- [ ] **O1. Still clean.** Do: after a long group session, `/taxi debug`. Expect:
      `0 errors logged`; in particular no lines from "window refresh", "UI
      start" or "window build".
- [ ] **O2. The final public name (spec §16.9).** Not a game check (Do:
      nothing in game): before any public release, replace the placeholder
      "Taxi" (see the README, "The name") and settle the SavedVariables names,
      because renaming them later loses everyone's stored ratings.
