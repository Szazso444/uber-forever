# In-game checklist

Boxes are ticked as the checks are run on Forever. Task 19 adds the group
checklist below the Task 18 section.

## Task 18: the windows and `/taxi sim` (alone, no group needed)

Status: **not run in game yet.** The windows and the sim are covered by the PC
tests (a strict fake of the frame API); every box below needs a real run.

Start with `/taxi sim`: the main window opens on the Travel tab and a "Sim
controls" window appears at the left. `/taxi sim off` (or the Stop sim button)
ends it. In the sim you are "You", a level 60 Hardcore hunter with 100g.
Dar Kbolt (a guildmate's warlock), Ann Other (a doubtful warlock), Mag Ic (a
mage), Cee One and Cee Two (clickers) and Stan Ger (a stranger) are simulated;
you answer for them in windows marked "(sim)". Answer a request within 30
seconds and take an invite within 60, or the sim traveler gives up, like a real
one.

### The board
- [ ] Travel > Summons: Dar Kbolt first and in green ("★ 4.7 · 6 summons"), then
      Ann Other ("★ 1.5 · 4 summons · New", "⚠ 1 reported death").
- [ ] Travel > Portals: Mag Ic, "Portals: Stormwind, Ironforge, Darnassus".
- [ ] Clicking: Dar Kbolt needs 1 clicker, Ann Other needs 2.

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
- [ ] Stars (Trust), Open trade with Dar Kbolt: "Put 1g in the trade" shows,
      "Rating sent." too; opening the trade again sends no second rating.
- [ ] Trade tip completes the trade; History shows "Summon from Dar Kbolt".
- [ ] Stay and click applies to his stand; Leave group leaves it.

### A portal ride
- [ ] Portals > Request > Darnassus: "Mag Ic (sim)" toast; Accept; Accept invite;
      Mage opens portal shows "Portal to Darnassus is up - click it!" with a
      sound; Step through portal opens the arrival window with no stars and no
      Stay and click.

### Clickers
- [ ] Clicker applies: "Dar Kbolt (sim) - Clicker offer" ("Cee Two asks for 40%",
      "You offered 25%"); Accept, Counter (box) and Decline work.
- [ ] After a tip, End shift: "Cee One (sim) - Shift ended", "Owed 25s ·
      Received 0c", one star suggested; Submit sends the rating.
- [ ] Applying yourself (Clicking tab) shows the offer in Dar Kbolt's window; the
      counter-offer comes back to You as a "Counter-offer" window.

### The rest
- [ ] Kill traveler: the red "Your Hardcore character has died." banner, every
      button off.
- [ ] Advance 60 s moves the sim clock; status lines render in the footer.
- [ ] `/taxi sim off` brings the real window back; nothing was sent to the real
      channel; the "New ratings are saved" reminder never showed in the sim.

### Only the game can tell
- [ ] The glyphs draw (not as boxes): ★ ⚠ → in the board and the guard panel,
      ✓ ✗ in the guard panel. If ✓ ✗ do not, change `W.CHECK` and `W.CROSS`
      (two lines in `UI/Widgets.lua`).
- [ ] The windows' X buttons work; the toast's X brings up the next request.
- [ ] `PlaySound(SOUNDKIT.READY_CHECK)` and `SOUNDKIT.RAID_WARNING` are heard.
- [ ] Esc closes the request dialog (it is in `UISpecialFrames`).
- [ ] Windows show and answer clicks during combat (try with a target dummy).

### Needs a real summon (Task 19, with a warlock)
- [ ] The guard panel sits to the right of Blizzard's own summon popup
      (`StaticPopup_FindVisible("CONFIRM_SUMMON")`); with no popup it sits at
      the top centre.
- [ ] Decline summon cancels the real popup (`C_SummonInfo.CancelSummon`).
