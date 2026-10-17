# Uber Forever: Design Spec

- **Date:** 2026-10-17
- **Status:** Draft, awaiting review
- **Target:** World of Warcraft: Forever, client 1.60.1, Hardcore ruleset. The addon also runs on the other rulesets, which is useful for testing before Hardcore launches.

Sections marked **[Proposed]** were decided by Claude while writing this spec and have not been discussed yet. Everything else was agreed during brainstorming.

---

## 1. Purpose

A matchmaking board that connects players who **offer travel** (warlock summons, mage portals) with players who **want travel**, and makes the whole exchange easier for both sides. Payment is only tips or gold offers.

On Hardcore a summon can kill: a malicious warlock can summon someone into a deadly spot on purpose. So for summons, **safety is the top priority**. The addon verifies each summon with data from the player's own client, and it keeps a reputation system that is hard to manipulate.

## 2. Agreed decisions

| Topic | Decision |
|---|---|
| Matching model | **Taxi stands.** Providers post where they are and what they offer. Travelers choose from what's available. |
| Roles | **Summoner** (warlock), **Clicker** (helps complete Ritual of Summoning), **Mage** (portals, a separate pipeline). |
| Summon spell | Only **Ritual of Summoning**: the warlock plus 2 party members click the portal, and each summon costs a soul shard. Portal of Summoning is **not** in Forever. |
| Finding clickers | A **clicker marketplace** by default. A summoner can also add their **own crew** (friends, guild) as clickers. |
| Tips to clickers | **The summoner collects.** The traveler makes one trade, to the summoner. The share split is set on the stand, and the addon tracks what each clicker is owed. |
| Ratings | Every warlock has two background **scores** and two visible **ratings**, each 1–5 stars like Uber: **Trust rating** (safety, visible to travelers) and **Share rating** (payout fairness, visible to clickers). Mages are not rated. |
| Rating display | Driven by the star average plus a count: "★ 4.8 · 137 summons" or "★ 4.9 · 22 shifts". Guild members are highlighted and listed first. The background weighting will be tuned later. |
| Tip choice | Shown in the arrival window, together with the Trust rating: **50s / 1g / custom**. If the traveler attached an offer to the request, that amount is pre-selected. |
| Storage | **In-game only.** Each player stores data on their own disk (SavedVariables), and addons sync over in-game addon messages. No companion app, no web server. |
| Tamper resistance | Six rules, described in §8. Deaths within **2 minutes** of arriving count against the warlock. |

## 3. Platform facts (verified)

These were checked against Blizzard's generated API documentation for Forever (build 1.60.1.70450, `Gethe/wow-ui-source`, branch `forever`) and against community sources.

- **Addon API:** Forever uses the **modern (Midnight-era) addon API**, not the Classic one. Lua 5.1, the standard addon format.
- **Messaging:** `C_ChatInfo.SendAddonMessage` supports `PARTY`, `WHISPER`, `CHANNEL` and `GUILD`. Messages are limited to 255 bytes, prefixes to 16 characters. Sending is throttled: about 10 messages in a burst, refilling at 1 per second. Inside instances and encounters the API is in **chat messaging lockdown** (`C_ChatInfo.InChatMessagingLockdown()`), and sends fail with `AddOnMessageLockdown`.
- **Sender identity:** the `sender` field of `CHAT_MSG_ADDON` is filled in by the game server, so an addon cannot fake who sent a message.
- **Custom channel:** `JoinChannelByName` exists in Forever.
- **Invites:** `C_PartyInfo.InviteUnit(name)` is not protected. `UninviteUnit` is restricted. A party holds at most 5 players.
- **Summon:** the `CONFIRM_SUMMON` event fires when a summon is offered. `C_SummonInfo.GetSummonConfirmSummoner()` returns who is summoning, `GetSummonConfirmAreaName()` returns where you'll land, and `GetSummonConfirmTimeLeft()` and `CancelSummon()` are also available. Accepting must stay a manual click.
- **Positions:** `C_Map.GetBestMapForUnit`, `C_Map.GetPlayerMapPosition` and `UnitPosition` work for the player and party members. `C_Map.GetMapLevels(uiMapID)` returns a zone's level range.
- **Combat and death state:** `UnitAffectingCombat` and `UnitIsDeadOrGhost` work on party units, and the docs mark no secret returns for them. `HARDCORE_DEATHS(memberName)` is a death notice sent by the server, and `C_GameRules.IsHardcoreActive()` reports whether the Hardcore ruleset is active.
- **Trade:** `InitiateTrade(unit)` exists. `SetTradeMoney` and `AddTradeMoney` are **restricted**, so the addon may not be able to pre-fill gold. Trade events (`TRADE_SHOW`, `TRADE_MONEY_CHANGED`, `TRADE_ACCEPT_UPDATE`, `TRADE_CLOSED`) are available.
- **Time:** `GetServerTime()` is used for every timestamp.
- **Ritual of Summoning:** learned at level 20. Each summon needs the warlock plus 2 party members who right-click the portal, all out of combat, and costs 1 soul shard. Its tooltip is unchanged from Classic Era.
- **No internet access:** addons cannot make HTTP requests. All persistence is SavedVariables, which are written on logout or `/reload`.

## 4. Roles

| Role | Who | Rated? | Sees |
|---|---|---|---|
| Traveler | Anyone | No | Trust rating of summoners |
| Summoner | Warlock, level 20+ | Trust rating (from travelers) and Share rating (from clickers) | Its own ratings |
| Clicker | Anyone at the stand | No **[Proposed]**: a clicker can't change where a summon lands | Share rating of summoners |
| Mage | Mage with portal spells | No | Nothing extra |

One player can switch roles. A traveler who has just arrived can become a clicker ("stay and click").

## 5. Architecture

### 5.1 Module layout [Proposed]

```
UberForever/
  UberForever.toc
  Core/      Init.lua, Config.lua (all tunable numbers), Events.lua, Log.lua
  Comms/     Protocol.lua (encode/decode, pure), Channel.lua (join/heartbeat), Transport.lua (AceComm + ChatThrottleLib, lockdown queue)
  Domain/    pure Lua, no WoW globals, unit tested
             Stand.lua       stand model, expiry, seats, clicker slots
             Ride.lua        ride state machine
             SummonGuard.lua summon verdict from a snapshot of game facts
             Ratings.lua     scores, weights, display values
             Ledger.lua      clicker shares, owed vs received
             Witness.lua     links deaths to rides
  Game/      thin adapters over the WoW API: Party, Summon, Trade, Map, Spells, Unit
  UI/        MainWindow, StandList, RequestDialog, DriverToast, GuardPanel, ArrivalWindow, ShiftEndWindow, MinimapButton
  Libs/      LibStub, CallbackHandler, ChatThrottleLib, AceComm-3.0, LibDataBroker, LibDBIcon
tests/       busted specs for Domain/ and Comms/Protocol.lua, plus a fake game adapter
```

**Boundary rule:** `Domain/` never calls WoW functions. `Game/` gathers facts into plain tables, and `Domain/` makes the decisions. That keeps the safety-critical logic (SummonGuard, Ratings, Ledger, Witness) testable on a PC without the game.

**Libraries [Proposed]:** AceComm and ChatThrottleLib handle splitting long messages and throttling. Widely used addons with Forever builds, such as Questie, embed Ace3, which is good evidence it works, but it will be checked in-game in milestone 1. If it doesn't work, the fallback is a small hand-written transport.

### 5.2 Message flow

- **Public custom channel** `UberForever`, joined automatically: stand heartbeats, ride starts, ratings, ride logs, death reports, queries.
- **Whisper:** requests, accept/decline, clicker applications, query replies.
- **Party:** tip reports, ledger updates, "portal up" alerts.

## 6. Summon pipeline

### 6.1 Stand lifecycle

1. **Create:** the warlock opens "My stand". The addon captures the zone, subzone, `uiMapID`, map coordinates and faction. The warlock sets the share split (default **50 / 25 / 25** [Proposed]) and an optional note.
2. **Recruiting:** status is "Needs clickers 0/2". The stand appears in the clicker marketplace. The warlock can also mark party members as their own crew.
3. **Live:** at 2/2 clickers, the stand appears on the traveler board. A heartbeat goes out every 60 s [Proposed]. Other addons drop a stand after 3 minutes without a heartbeat [Proposed].
4. **Paused:** if a clicker leaves (stand drops to 1/2), the crew is in combat, or the warlock is out of soul shards. The stand stays on the board, marked "Paused".
5. **Closed:** the warlock ends the stand, logs out, or moves more than 50 yards from the stand position [Proposed]. Moving ends the stand because the agreed destination is no longer true.

You can't post a stand inside an instance (messaging lockdown). Players can still use stands at dungeon entrances outside the instance.

### 6.2 Party capacity [Proposed]

A party of 5 is the warlock, 2 clickers and **2 traveler seats**. Travelers stay in the party during their 2-minute safety window (§8 rule 3) and then leave, which frees the seat. Converting to a raid for more seats is left for later.

### 6.3 Traveler flow

1. **Browse:** the Travel → Summons list shows each live stand: destination (zone, subzone), Trust rating ★ plus summon count, free seats, distance, and a guild highlight. It is sorted with guild members first, then by Trust score, then by summon count. Travelers can filter by zone.
2. **Request:** the traveler picks an optional offer (none / 50s / 1g / custom) and the request is whispered to the warlock.
3. **Accept:** the warlock gets a toast with sound showing the traveler's name, level, guild and offer, and clicks Accept or Decline. On Accept, the addon whispers back a `rideId` and calls `InviteUnit`.
4. **Join:** the traveler accepts the party invite through Blizzard's normal dialog. The traveler's addon checks that the party contains the agreed warlock, then broadcasts `RIDE_START` on the channel (§8 rule 3).
5. **Ritual:** the warlock clicks "Summon next", a secure action button that targets the traveler and casts Ritual of Summoning. The clickers get a "Portal up — click it!" alert with sound. Clicking the portal in the world is always done by hand.
6. **Summon Guard:** when `CONFIRM_SUMMON` fires, the guard panel attaches to Blizzard's summon popup (§6.4).
7. **Arrive:** the traveler accepts by hand. The addon confirms the traveler's own position is at the stand, records a **ride receipt**, and opens the arrival window (§10).
8. **Safety window:** for 2 minutes the traveler stays in the party, with a countdown in the arrival window. Then the addon suggests leaving the party.

### 6.4 Summon Guard checks

The guard takes a snapshot of facts from the traveler's own client and gives a verdict: **GREEN** (safe as agreed), **YELLOW** (be careful) or **RED** (doesn't match, decline).

| Check | Source | Fail level |
|---|---|---|
| Summoner is the agreed warlock | `GetSummonConfirmSummoner()` | RED |
| Landing area matches the stand's zone or subzone | `GetSummonConfirmAreaName()` vs stand | RED |
| Warlock is in the party, on the stand's map, within ~40 yards of the stand position | party map position / `UnitPosition` | RED |
| Warlock or clickers are in combat | `UnitAffectingCombat(partyN)` | RED |
| Zone level range is above the traveler's level | `C_Map.GetMapLevels` vs `UnitLevel("player")` | YELLOW |
| Stand moved or changed since the request was accepted | stand heartbeat history | YELLOW |
| Warlock's Trust rating is low or unknown | Ratings | YELLOW (information only) |

- The addon **never accepts on its own**. On RED, it shows a "Decline summon" button that calls `CancelSummon()`. Clicking it is still the traveler's choice.
- The panel lists each check in plain words, for example "✓ Summoner: Darkbolt", "✗ Destination: Searing Gorge (agreed: Ironforge)".
- **Not covered:** a mob wandering onto the spot after you accept. The 2-minute death rule (§8) handles the consequences.

### 6.5 Edge cases

| Situation | Behavior |
|---|---|
| Warlock goes offline or leaves mid-ride | Ride cancelled, no rating |
| Traveler declines the summon or it expires | Ride returns to "waiting for summon" once, then is cancelled |
| Traveler is in another group | The invite fails and the traveler is told to leave their group |
| Party full | Request queued, and the warlock sees the queue |
| Message lost or throttled | Retry with a timeout, then cancel cleanly |
| Different addon versions | Every message carries a protocol version. Unknown versions are ignored, and an "Update available" hint is shown. |

## 7. Clicker pipeline

### 7.1 Finding clickers

- **Marketplace:** the Clicking tab lists stands that need clickers. Each entry shows the warlock's **Share rating** plus shift count, the split, the location and how many clickers are still needed. A clicker applies (whisper), and the warlock accepts and invites. The clicker travels to the stand themselves, or the warlock summons them as a regular ride once 2 people are present.
- **Own crew:** the warlock marks current party members as clickers. Those clickers don't need the addon for the ritual, but without it they can't track their share or rate.
- **Stay and click:** the arrival window offers "Stay and click for the next one". The traveler then becomes a clicker on that stand.

### 7.2 Ledger and payouts

- After a traveler's trade with the warlock closes, the traveler's addon measures how much gold left its own bag and sends `TIP(rideId, amount)` to the party. The server stamps the sender.
- The warlock's addon measures the gold it actually received and sends its own `TIP_ACK(rideId, amount)`.
- Each clicker's addon computes its owed share on its own: the sum of the tips received while that clicker was on the stand, times the clicker's split.
  - If the traveler's and the warlock's amounts **agree**, the tip counts.
  - If they **disagree**, the tip is shown as "disputed" with both amounts, and it is left out of the automatic pre-fill.
- The warlock's "My stand" view shows each clicker's owed amount, with a "Pay" button that opens a trade.
- The clicker's addon records the gold actually received in trades with that warlock during or right after the shift.

### 7.3 Shift end

A shift ends when the clicker leaves the stand or the stand closes. The clicker then gets the shift-end window:

- "Owed 25s · Received 25s ✓", with the **Share rating** stars pre-filled: received ≥ owed → 5★, nothing received → 1★, in between → proportional [Proposed]. If nothing was owed (no tips during the shift), the stars aren't pre-filled and rating is optional. The clicker can change the stars.
- The rating is sent with the shift's ledger summary as proof (§8).

## 8. Ratings and tamper resistance

### 8.1 Facts no addon can fake

- The **sender** of every addon message, filled in by the server.
- The **summoner** and **landing area** in the summon dialog.
- **Party members'** position, combat state and dead/ghost state as seen by your own client.
- **Hardcore death notices** (`HARDCORE_DEATHS`).
- **Gold** that actually entered or left your own bags.

### 8.2 Rules

1. **Speak for yourself only.** A rating is accepted only straight from the player who gave it (sender = rater). Ratings passed along by someone else are ignored. Nobody can change or invent another player's rating.
2. **Rides need two-sided proof.** A Trust rating counts fully only if both parties logged the ride with the same `rideId`: the traveler's `RATING` and the warlock's `RIDE_LOG`. If only the traveler logged it, the rating counts at reduced weight. This also covers a modified warlock addon that skips logging bad rides.
3. **Deaths within 2 minutes count automatically.**
   - When a traveler joins the warlock's party, their addon broadcasts `RIDE_START(rideId, warlock)`, which ties the traveler to that warlock publicly.
   - If the traveler dies within **2 minutes** of arriving, a `DEATH(rideId)` report goes out. It can come from the traveler's own addon, from party members' addons (who see `UnitIsDeadOrGhost` change), or from any addon that receives `HARDCORE_DEATHS` for that name.
   - The death is recorded as a **1★ Trust rating with heavy weight** [Proposed: weight 5]. It counts even if the warlock never logged the ride.
   - Dying costs a Hardcore character, so nobody fakes a death cheaply. A player who reported their own death but keeps broadcasting as alive on Hardcore afterwards has all of their reports discarded.
4. **The Share rating checks itself.** The owed share comes from the travelers' own `TIP` reports and the gold received from the clicker's own bags (§7.2), not from the warlock's word.
5. **Weighting and display:**
   - Visible: average stars to one decimal, plus a count of verified summons or shifts. Fewer than 5 ratings shows "New".
   - Background score [Proposed]: a weighted average with a prior, so one alt's 5★ can't make a new warlock 5.0: `score = (C·m + Σ wᵢ·starsᵢ) / (C + Σ wᵢ)` with `m = 3.5` and `C = 5`. Weights: two-sided 1.0, one-sided 0.3, death 5.0. All numbers live in `Core/Config.lua` and can be tuned later.
   - Each rater has one rating per warlock per day, and only the latest 500 ratings per warlock are kept (like Uber).
   - Guild members are highlighted and listed first.
6. **Local edits only fool yourself.** Editing your own SavedVariables changes only your own view.

### 8.3 Sync [Proposed]

- New ratings are broadcast live on the channel. Every addon that hears one directly from the rater stores it.
- When you open a stand or a marketplace entry, your addon sends `QUERY(warlock)` at most once per 10 minutes per warlock. Online raters reply with **their own** ratings of that warlock by whisper, after a random 0–5 s delay, with at most 20 replies. The warlock's addon replies with its ride and shift logs.
- **Limit:** ratings from raters who are offline and whom you've never heard from are not available to you. Coverage grows as people play. This is the cost of rule 1, which is what prevents relayed fakes.

### 8.4 What it can't fully stop

Someone levelling many alts to rate themselves. Those ratings carry stranger weight with no shared history, and anyone's own or friends' experience outweighs them. Detecting alt rings properly would need a central server, which is out of scope.

## 9. Mage pipeline

1. **Portal stand:** the mage posts their location and destinations. Destinations come from the mage's **known portal spells** (spell IDs kept in a data table), so the list stays correct if Forever changes the portals. The stand also shows the number of free seats (up to 4 travelers).
2. **Request:** the traveler picks a destination and an optional offer.
3. **Accept:** the mage accepts and the addon invites the traveler. The traveler sees the mage's location on the map and walks there. Portals have to be clicked near the mage.
4. **Portal:** the mage presses "Open portal to X", a secure button. The travelers click the portal by hand.
5. **Arrival:** a tip window with 50s / 1g / custom and Open trade. **No rating** and no Summon Guard, because portals only go to fixed capital cities.

## 10. UI [Proposed]

| Window | Contents |
|---|---|
| Main window (`/uf`, minimap button) | Tabs: **Travel** (Summons / Portals), **My stand** (warlock or mage), **Clicking** (marketplace and current shift), **History** |
| Request dialog | Destination, offer (none / 50s / 1g / custom), Send |
| Driver toast | Traveler name, level, guild, offer, Accept / Decline, sound |
| Guard panel | Next to Blizzard's summon popup: verdict color, check list, "Decline summon" on RED |
| Arrival window | **Trust rating** stars, **tip 50s / 1g / custom** (pre-selected offer), **Open trade with <warlock>**, "Stay and click", 2-minute safety countdown |
| Shift-end window | Owed vs received, **Share rating** stars (pre-filled), Submit |
| Mage arrival window | Tip 50s / 1g / custom, Open trade |

The UI follows Blizzard's frame style, uses English text, and keeps strings in one table so they can be localized later.

If `SetTradeMoney` can't be called from the addon, "Open trade" opens the trade window and the arrival window shows "Put 1g in the trade" for the traveler to type.

## 11. Data (SavedVariables) [Proposed]

```lua
UberForeverDB = {            -- account-wide
  version = 1,
  ratings = {                -- keyed by warlock "Name"
    ["Darkbolt"] = {
      trust = { {rater, stars, rideId, ts, twoSided, kind}, ... },  -- kind: "rating" | "death"
      share = { {rater, stars, shiftId, ts, owed, received}, ... },
    },
  },
  rides  = { ... },          -- my own rides as traveler, summoner, clicker or mage
  liars  = { ["Name"] = ts },-- raters whose reports were discarded
  settings = { ... },
}
UberForeverCharDB = { stand = { split = {50,25,25}, note = "" } }    -- per character
```

Pruning: ratings older than 180 days are dropped, with at most 500 per warlock per kind.

## 12. Messages [Proposed]

Prefix `UberFvr`. The format is `v1|TYPE|field|field…`, compact and split into chunks by AceComm when needed. Every message has a `msgId`, and receivers dedupe by (sender, msgId).

| Type | Channel | Fields |
|---|---|---|
| `STAND` | channel | standId, kind (lock/mage), faction, mapID, x, y, zone, subzone, seatsFree, clickers n/2, split, portals (mage) |
| `STAND_END` | channel | standId |
| `REQUEST` | whisper | standId, offer (copper), level, destination (mage) |
| `ACCEPT` / `DECLINE` | whisper | rideId / reason |
| `CLICK_APPLY` / `CLICK_OK` | whisper | standId |
| `RIDE_START` | channel | rideId, warlock |
| `RIDE_LOG` | channel | rideId, traveler, ts |
| `RATING` | channel | kind (trust/share), target, stars, rideId or shiftId, ts, owed/received (share) |
| `DEATH` | channel | rideId, victim, secondsAfterArrival, source (self/party/server) |
| `TIP` / `TIP_ACK` | party | rideId, amount |
| `PORTAL_UP` | party | — |
| `QUERY` / `QUERY_R` | channel / whisper | target / ratings |

Throttle budget: heartbeats every 60 s with random jitter, everything else is event-driven. Under lockdown, outgoing messages are queued and the UI shows "Paused (instance)".

## 13. Testing

- **Unit tests (PC):** `busted` on Lua 5.1 for `Domain/*` and `Comms/Protocol.lua`, using a fake game adapter. The required cases:
  - SummonGuard verdicts for every check;
  - ride state machine transitions;
  - rating math, weights and the prior;
  - two-sided vs one-sided ratings;
  - death within and outside the 2-minute window;
  - liar detection;
  - ledger agree and dispute cases;
  - message round-trip encoding.
- **Lint:** `luacheck` with the WoW globals declared.
- **In-game, solo:** `/uf debug` injects fake stands, requests and summon facts, so the UI can be tested alone.
- **In-game, group:** a manual checklist on Forever, on a normal ruleset until Hardcore launches.
  - A full summon test needs **4 characters**: a warlock of level 20+, 2 clickers and a traveler.
  - The mage test needs a mage who knows portal spells.

## 14. Milestones [Proposed]

1. **Core:** TOC, comms over the channel (verify AceComm on Forever), stand board, invite, debug injection. This proves messaging works on a mega-realm.
2. **Mage pipeline:** the simplest end-to-end loop. Request, invite, portal, tip window.
3. **Summon pipeline:** stands, clickers (marketplace and own crew), Summon Guard, arrival window with Trust rating and tip.
4. **Ratings and sync:** rules 1–6, query sync, death witnessing, Share rating with ledger.
5. **Hardcore hardening:** run on the Hardcore ruleset once it launches. Verify the `HARDCORE_DEATHS` scope and the trade rules, and tune the weights.

## 15. Out of scope for v1

- Companion app or web backend.
- **Discord:** automatic display would need a companion app plus a Discord bot. A no-app option for later is a "Copy for Discord" button that copies a text summary to paste. Pasted text can't be verified, but it's fine for showing off.
- Raid conversion for more than 2 traveler seats.
- Stands inside instances.
- Localization beyond English.
- Clicker ratings.

## 16. Open questions to verify in game

1. The TOC `## Interface:` number (reported as 16001) and whether Forever needs a TOC filename suffix. Check with `/dump (select(4, GetBuildInfo()))`.
2. Where the summoned player lands: at the warlock's position when accepting, or at the portal. This affects guard check 3.
3. What `GetSummonConfirmAreaName()` returns: the zone or the subzone.
4. Whether `SetTradeMoney` works from a button click (it's restricted).
5. Who receives `HARDCORE_DEATHS` in Forever: guild, party, or everyone. This can only be checked once Hardcore launches.
6. Forever Hardcore trade rules, which aren't published yet. If Hardcore disables trading, the tip flow has to change.
7. Custom channel limits on a region-wide mega-realm: member caps and channel throttling.
8. **Public name.** "Uber" is a trademark of Uber Technologies, so a published addon with that name could be taken down on CurseForge or Wago. Pick a public name before release; the repo name can stay.
