# Taxi: Design Spec

- **Name:** "Taxi" is a placeholder. Every name lives in `Core/Config.lua`: addon title, message prefix, channel name and slash command. The SavedVariables names (`TaxiDB`, `TaxiCharDB`) must be final before the first public release, because renaming them later loses everyone's stored ratings unless the data is migrated.
- **Date:** 2026-10-17 (revised the same day after review)
- **Status:** Approved 2026-10-17
- **Target:** World of Warcraft: Forever, client 1.60.1, Hardcore ruleset. The addon also runs on the other rulesets, which is useful for testing before Hardcore launches.

Sections marked **[Proposed]** were decided by Claude while writing this spec and have not been discussed yet. Everything else was agreed during brainstorming and review.

---

## 1. Purpose

A matchmaking board that connects players who **offer travel** (warlock summons, mage portals) with players who **want travel**, and makes the whole exchange easier for both sides. Payment is only tips or gold offers.

On Hardcore a summon can kill: a malicious warlock can summon someone into a deadly spot on purpose. So for summons, **safety is the top priority**. The addon verifies each summon with data from the player's own client, and it keeps a reputation system that is hard to manipulate.

## 2. Agreed decisions

| Topic | Decision |
|---|---|
| Matching model | **Taxi stands.** Providers post where they are and what they offer. Travelers choose from what's available. |
| Roles | **Summoner** (warlock), **Clicker** (helps complete Ritual of Summoning), **Mage** (portals, a separate pipeline). |
| Summon spell | Only **Ritual of Summoning**: the warlock plus 2 group members click the portal, and each summon costs a soul shard. Portal of Summoning is **not** in Forever. |
| Group size | A stand can be a **party or a raid**. The warlock sets how many traveler seats the stand has, and the addon converts the group to a raid when it needs more than 5 people. |
| Safety window | **None.** Travelers can leave the group as soon as they arrive. Safety relies on the Summon Guard and the ratings. |
| Finding clickers | A **clicker marketplace** by default. A summoner can also add their **own crew** (friends, guild) as clickers. |
| Tips to clickers | **The summoner collects.** The traveler makes one trade, to the summoner. The addon tracks what each clicker is owed. |
| Share split | The default is **50 / 25 / 25** (summoner / clicker / clicker). The split is **negotiated per clicker** when a summoner asks for clickers and when a clicker signs up. |
| Ratings | Every warlock has two background **scores** and two visible **ratings**, each 1–5 stars like Uber: **Trust rating** (safety, visible to travelers) and **Share rating** (payout fairness, visible to clickers). **Mages and clickers are not rated.** |
| Rating display | Driven by the star average plus a count: "★ 4.8 · 137 summons" or "★ 4.9 · 22 shifts". Guild members are highlighted and listed first. The background weighting will be tuned later. |
| Tip choice | Shown in the arrival window, together with the Trust rating: **50s / 1g / custom**. If the traveler attached an offer to the request, that amount is pre-selected. |
| Storage | **In-game only.** Each player stores data on their own disk (SavedVariables), and addons sync over in-game addon messages. No companion app, no web server. See §8.4 for persistence. |
| Tamper resistance | Six rules, described in §8. |
| Delivery | Everything is built **in one pass**, backed by unit tests and a simulation harness (§13). |

## 3. Platform facts (verified)

These were checked against Blizzard's generated API documentation for Forever (build 1.60.1.70450, `Gethe/wow-ui-source`, branch `forever`) and against community sources.

- **Addon API:** Forever uses the **modern (Midnight-era) addon API**, not the Classic one. Lua 5.1, the standard addon format.
- **Messaging:** `C_ChatInfo.SendAddonMessage` supports `PARTY`, `RAID`, `WHISPER`, `CHANNEL` and `GUILD`. Messages are limited to 255 bytes, prefixes to 16 characters. Sending is throttled: about 10 messages in a burst, refilling at 1 per second. Inside instances and encounters the API is in **chat messaging lockdown** (`C_ChatInfo.InChatMessagingLockdown()`), and sends fail with `AddOnMessageLockdown`.
- **Sender identity:** the `sender` field of `CHAT_MSG_ADDON` is filled in by the game server, so an addon cannot fake who sent a message.
- **Custom channel:** `JoinChannelByName` exists in Forever.
- **Invites and groups:** `C_PartyInfo.InviteUnit(name)` is not protected. `C_PartyInfo.ConvertToRaid` and `UninviteUnit` are restricted, so they are triggered from the warlock's own button click. A party holds at most 5 players, a raid 40.
- **Summon:** the `CONFIRM_SUMMON` event fires when a summon is offered. `C_SummonInfo.GetSummonConfirmSummoner()` returns who is summoning, `GetSummonConfirmAreaName()` returns where you'll land, and `GetSummonConfirmTimeLeft()` and `CancelSummon()` are also available. Accepting must stay a manual click.
- **Positions:** `C_Map.GetBestMapForUnit`, `C_Map.GetPlayerMapPosition` and `UnitPosition` work for the player and group members. `C_Map.GetMapLevels(uiMapID)` returns a zone's level range.
- **Combat and death state:** `UnitAffectingCombat` and `UnitIsDeadOrGhost` work on group units, and the docs mark no secret returns for them. `HARDCORE_DEATHS(memberName)` is a death notice sent by the server, and `C_GameRules.IsHardcoreActive()` reports whether the Hardcore ruleset is active.
- **Trade:** `InitiateTrade(unit)` exists. `SetTradeMoney` and `AddTradeMoney` are **restricted**, so the addon may not be able to pre-fill gold. Trade events (`TRADE_SHOW`, `TRADE_MONEY_CHANGED`, `TRADE_ACCEPT_UPDATE`, `TRADE_CLOSED`) are available.
- **Time:** `GetServerTime()` is used for every timestamp.
- **Ritual of Summoning:** learned at level 20. Each summon needs the warlock plus 2 group members who right-click the portal, all out of combat, and costs 1 soul shard. It can target party or raid members. Its tooltip is unchanged from Classic Era.
- **No internet access:** addons cannot make HTTP requests. All persistence is SavedVariables, which the game writes on logout or `/reload`.

## 4. Roles

| Role | Who | Rated? | Sees |
|---|---|---|---|
| Traveler | Anyone | No | Trust rating of summoners |
| Summoner | Warlock, level 20+ | Trust rating (from travelers) and Share rating (from clickers) | Its own ratings |
| Clicker | Anyone at the stand | No | Share rating of summoners |
| Mage | Mage with portal spells | No | Nothing extra |

One player can switch roles. A traveler who has just arrived can become a clicker ("stay and click").

## 5. Architecture

### 5.1 Module layout [Proposed]

```
Taxi/
  Taxi.toc
  Core/      Init.lua, Config.lua (names and all tunable numbers), Events.lua, Log.lua
  Comms/     Protocol.lua (encode/decode, pure), Channel.lua (join/heartbeat), Transport.lua (AceComm + ChatThrottleLib, lockdown queue)
  Domain/    pure Lua, no WoW globals, unit tested
             Stand.lua       stand model, seats, clicker slots, expiry
             Ride.lua        ride state machine
             Negotiation.lua clicker share offers and counter-offers
             SummonGuard.lua summon verdict from a snapshot of game facts
             Ratings.lua     scores, weights, display values
             Ledger.lua      clicker shares, owed vs received
             Witness.lua     links deaths to rides
             Store.lua       SavedVariables schema, migration, pruning
  Game/      thin adapters over the WoW API: Party, Summon, Trade, Map, Spells, Unit
  UI/        MainWindow, StandList, RequestDialog, DriverToast, ClickerOffer, GuardPanel, ArrivalWindow, ShiftEndWindow, MinimapButton
  Sim/       in-game simulation mode (/taxi sim)
  Libs/      LibStub, CallbackHandler, ChatThrottleLib, AceComm-3.0, LibDataBroker, LibDBIcon
tests/       busted specs for Domain/ and Comms/Protocol.lua
tests/sim/   multi-client network simulation (§13.2)
```

**Boundary rule:** `Domain/` never calls WoW functions. `Game/` gathers facts into plain tables, and `Domain/` makes the decisions. That keeps the safety-critical logic (SummonGuard, Ratings, Ledger, Witness) testable on a PC without the game. It also means the same code can run inside the simulation harness.

**Libraries [Proposed]:** AceComm and ChatThrottleLib handle splitting long messages and throttling. Widely used addons with Forever builds, such as Questie, embed Ace3, which is good evidence it works, but it will be checked in-game first. If it doesn't work, the fallback is a small hand-written transport behind the same `Transport.lua` interface.

### 5.2 Message flow

- **Public custom channel** `TaxiForever`, joined automatically: stand heartbeats, ride starts, ratings, ride logs, death reports, queries.
- **Whisper:** requests, accept/decline, clicker applications and offers, query replies.
- **Party or raid:** tip reports, ledger updates, "portal up" alerts.

## 6. Summon pipeline

### 6.1 Stand lifecycle

1. **Create:** the warlock opens "My stand". The addon captures the zone, subzone, `uiMapID`, map coordinates and faction. The warlock sets:
   - the **traveler seats**, default 3 [Proposed], maximum 40 minus the crew;
   - the **clicker share offered**, default 25% each;
   - an optional note.
2. **Recruiting:** status is "Needs clickers 0/2". The stand appears in the clicker marketplace with the offered share. The warlock can also mark group members as their own crew, agreeing the split with each of them in the addon (§7.1).
3. **Live:** at 2/2 clickers, the stand appears on the traveler board. A heartbeat goes out every 60 s [Proposed]. Other addons drop a stand after 3 minutes without a heartbeat [Proposed].
4. **Paused:** if a clicker leaves (stand drops to 1/2), the crew is in combat, or the warlock is out of soul shards. The stand stays on the board, marked "Paused".
5. **Closed:** the warlock ends the stand, logs out, or moves more than 50 yards from the stand position [Proposed]. Moving ends the stand because the agreed destination is no longer true.

You can't post a stand inside an instance (messaging lockdown). Players can still use stands at dungeon entrances outside the instance.

### 6.2 Group size

- The crew (warlock and 2 clickers) plus the traveler seats decide the group size.
- When accepting the next traveler would need more than 5 people, the warlock's toast shows **"Convert to raid & invite"**. The conversion is the warlock's own click, because `ConvertToRaid` is restricted.
- Summons go one traveler at a time: each needs one soul shard and both clickers clicking the portal. The addon keeps a queue in the order requests were accepted.

### 6.3 Traveler flow

1. **Browse:** the Travel → Summons list shows each live stand: destination (zone, subzone), Trust rating ★ plus summon count, free seats, distance, and a guild highlight. It is sorted with guild members first, then by Trust score, then by summon count. Travelers can filter by zone.
2. **Request:** the traveler picks an optional offer (none / 50s / 1g / custom) and the request is whispered to the warlock.
3. **Accept:** the warlock gets a toast with sound showing the traveler's name, level, guild and offer, and clicks Accept or Decline. On Accept, the addon whispers back a `rideId` and calls `InviteUnit`.
4. **Join:** the traveler accepts the invite through Blizzard's normal dialog. The traveler's addon checks that the group contains the agreed warlock, then broadcasts `RIDE_START` on the channel (§8 rule 3).
5. **Ritual:** the warlock clicks "Summon next", a secure action button that targets the next traveler in the queue and casts Ritual of Summoning. The clickers get a "Portal up — click it!" alert with sound. Clicking the portal in the world is always done by hand.
6. **Summon Guard:** when `CONFIRM_SUMMON` fires, the guard panel attaches to Blizzard's summon popup (§6.4).
7. **Arrive:** the traveler accepts by hand. The addon confirms the traveler's own position is at the stand, records a **ride receipt**, and opens the arrival window (§10).
8. **Leave:** after rating and tipping, the arrival window offers "Leave group". The traveler can also leave at any time, which frees the seat.

### 6.4 Summon Guard checks

The guard takes a snapshot of facts from the traveler's own client and gives a verdict: **GREEN** (safe as agreed), **YELLOW** (be careful) or **RED** (doesn't match, decline).

| Check | Source | Fail level |
|---|---|---|
| Summoner is the agreed warlock | `GetSummonConfirmSummoner()` | RED |
| Landing area matches the stand's zone or subzone | `GetSummonConfirmAreaName()` vs stand | RED |
| Warlock is in the group, on the stand's map, within ~40 yards of the stand position | group map position / `UnitPosition` | RED |
| Warlock or clickers are in combat | `UnitAffectingCombat(unit)` | RED |
| Zone level range is above the traveler's level | `C_Map.GetMapLevels` vs `UnitLevel("player")` | YELLOW |
| Stand moved or changed since the request was accepted | stand heartbeat history | YELLOW |
| Warlock's Trust rating is low or unknown | Ratings | YELLOW (information only) |

- The addon **never accepts on its own**. On RED, it shows a "Decline summon" button that calls `CancelSummon()`. Clicking it is still the traveler's choice.
- The panel lists each check in plain words, for example "✓ Summoner: Darkbolt", "✗ Destination: Searing Gorge (agreed: Ironforge)".
- **Not covered:** a mob wandering onto the spot after you accept. Ratings and the death rule (§8 rule 3) handle the consequences.

### 6.5 Edge cases

| Situation | Behavior |
|---|---|
| Warlock goes offline or leaves mid-ride | Ride cancelled, no rating |
| Traveler declines the summon or it expires | Ride returns to "waiting for summon" once, then is cancelled |
| Traveler is in another group | The invite fails and the traveler is told to leave their group |
| No free seat | Request queued, and the warlock sees the queue |
| Message lost or throttled | Retry with a timeout, then cancel cleanly |
| Different addon versions | Every message carries a protocol version. Unknown versions are ignored, and an "Update available" hint is shown. |

## 7. Clicker pipeline

### 7.1 Finding clickers and negotiating the split

- **Marketplace:** the Clicking tab lists stands that need clickers. Each entry shows:
  - the warlock's **Share rating** plus shift count;
  - the **share offered**;
  - the location;
  - how many clickers are still needed.
- **Sign-up:** a clicker applies (`CLICK_APPLY`), either accepting the offered share or asking for a different one.
  - The warlock accepts, declines or makes a counter-offer (`CLICK_OFFER`).
  - The clicker accepts or declines the counter-offer.
  - An agreed deal (`CLICK_OK`) carries the final percentage, and the warlock's addon invites the clicker.
- **Rule:** the summoner keeps `100% − sum of the clicker shares`. The addon refuses a deal that would push that below 0%.
- **Own crew:** the warlock marks current group members as clickers and agrees a split with each of them through the same offer dialog. Crew members without the addon can still click the portal, but they get no share tracking and can't rate.
- **Getting there:** the clicker travels to the stand themselves, or the warlock summons them as a regular ride once 2 people are present.
- **Stay and click:** the arrival window offers "Stay and click for the next one". This starts the same sign-up, pre-filled with the stand's offered share.

### 7.2 Ledger and payouts

- After a traveler's trade with the warlock closes, the traveler's addon measures how much gold left its own bags and sends `TIP(rideId, amount)` to the group. The server stamps the sender.
- The warlock's addon measures the gold it actually received and sends its own `TIP_ACK(rideId, amount)`.
- Each clicker's addon computes its owed share on its own: the sum of the tips received while that clicker was on the stand, times **that clicker's agreed percentage**.
  - If the traveler's and the warlock's amounts **agree**, the tip counts.
  - If they **disagree**, the tip is shown as "disputed" with both amounts, and it is left out of the automatic pre-fill.
- The warlock's "My stand" view shows each clicker's owed amount, with a "Pay" button that opens a trade.
- The clicker's addon records the gold actually received in trades with that warlock during or right after the shift.

### 7.3 Shift end

A shift ends when the clicker leaves the stand or the stand closes. The clicker then gets the shift-end window:

- "Owed 25s · Received 25s ✓", with the **Share rating** stars pre-filled: received ≥ owed → 5★, nothing received → 1★, in between → proportional [Proposed].
- If nothing was owed (no tips during the shift), the stars aren't pre-filled and rating is optional.
- The clicker can change the stars.
- The rating is sent with the shift's ledger summary as proof (§8).

## 8. Ratings and tamper resistance

### 8.1 Facts no addon can fake

- The **sender** of every addon message, filled in by the server.
- The **summoner** and **landing area** in the summon dialog.
- **Group members'** position, combat state and dead/ghost state as seen by your own client.
- **Hardcore death notices** (`HARDCORE_DEATHS`).
- **Gold** that actually entered or left your own bags.

### 8.2 Rules

1. **Direct beats relayed.** A rating counts fully only when it comes straight from the player who gave it (sender = rater). So nobody can change another player's rating and pass it off as theirs.
   - Addons also **relay** ratings they heard directly, so history survives when raters quit. Relays go **one hop only**: a relayed rating is never relayed again. Each relayed rating carries the original rater and the relayer's name, which the server stamps.
   - Relayed ratings count at **reduced weight** (§8.2 rule 5).
   - When the original rater later sends the same rating directly, it is upgraded to direct.
   - If the rater's own message contradicts a relay (different stars for the same `rideId`, or "I never rated that"), the relay is dropped and the relayer gets a **strike**. After 3 strikes [Proposed], all of that relayer's relays are ignored.
2. **Rides need two-sided proof.** A Trust rating counts fully only if both parties logged the ride with the same `rideId`: the traveler's `RATING` and the warlock's `RIDE_LOG`. If only the traveler logged it, the rating counts at reduced weight. This also covers a modified warlock addon that skips logging bad rides.
3. **A death right after arrival becomes an automatic 1★.** A traveler who dies can't fill in the arrival window, so the addon records the rating for them.
   - When a traveler joins the warlock's group, their addon broadcasts `RIDE_START(rideId, warlock)`, which ties the traveler to that warlock publicly.
   - If the traveler dies within **2 minutes** of arriving, their own addon sends `DEATH(rideId)`. It does this whether or not they are still in the group.
   - Any addon that heard the `RIDE_START` and receives `HARDCORE_DEATHS` for that traveler in the same window records the death too. So do group members' addons, if the traveler is still in the group and they see `UnitIsDeadOrGhost` change.
   - The death is recorded as a **1★ Trust rating with heavy weight** [Proposed: weight 5]. It counts even if the warlock never logged the ride.
   - A **relayed** death report doesn't get the heavy weight, because a relayer could invent it. It counts as an ordinary relayed 1★ and is also shown on the stand as a warning: "⚠ 1 reported death (relayed)".
   - Dying costs a Hardcore character, so nobody fakes a death cheaply. A player who reported their own death but keeps broadcasting as alive on Hardcore afterwards has all of their reports discarded.
4. **The Share rating checks itself.** The owed share comes from the travelers' own `TIP` reports, each clicker's agreed percentage and the gold received in the clicker's own bags (§7.2), not from the warlock's word.
5. **Weighting and display:**
   - Visible: average stars to one decimal, plus a count of verified summons or shifts. Fewer than 5 ratings shows "New".
   - Background score [Proposed]: a weighted average with a prior, so one alt's 5★ can't make a new warlock 5.0: `score = (C·m + Σ wᵢ·starsᵢ) / (C + Σ wᵢ)` with `m = 3.5` and `C = 5`. Weights: two-sided 1.0, one-sided 0.3, death 5.0, relayed 0.2. A relayed rating reported by 3 or more different relayers counts 0.5. All numbers live in `Core/Config.lua` and can be tuned later.
   - Each rater has one rating per warlock per day, and only the latest 500 ratings per warlock are kept (like Uber).
   - Guild members are highlighted and listed first.
6. **Local edits only fool yourself.** Editing your own SavedVariables changes only your own view.

### 8.3 Sync [Proposed]

- New ratings are broadcast live on the channel. Every addon that hears one directly from the rater stores it.
- When you open a stand or a marketplace entry, your addon sends `QUERY(warlock)` at most once per 10 minutes per warlock. The warlock's addon replies with its ride and shift logs. Other addons reply by whisper, after a random 0–5 s delay, with at most 20 replies:
  - each sends **its own** ratings of that warlock (received as direct);
  - and the ratings it **heard directly** from others (received as relayed, one hop).
- Each reply carries at most the 50 most recent records [Proposed], so a well-known warlock's full history fills in over several queries.

### 8.4 Persistence

Scores stay with the addon through three layers:

1. **Your own disk.** Everything your addon has heard, direct and relayed, is stored in `TaxiDB` (account-wide SavedVariables) at `WTF\Account\<account>\SavedVariables\Taxi.lua`.
   - The game loads it at login and writes it on logout and `/reload`. It survives restarts, patches and addon updates.
   - Ratings don't expire. Only the 500-per-warlock cap applies.
2. **Ratings you gave are kept permanently** in a separate `given` list, outside that cap, so your addon can always re-answer queries with them (§8.3).
3. **Other players.** Every addon holds copies of what it has heard and relays them (§8.3), so a lost local file refills over time through queries. Ratings from players who have quit keep circulating as relayed copies.

**What can still lose data:**
- A game crash before logout or `/reload` loses that session's new entries. After a session with new ratings, the addon shows a reminder to `/reload` when out of combat [Proposed].
- Deleting the WTF folder or moving to a new PC empties the local copy. It refills from other players: direct ratings from raters still playing, relayed copies for everyone else.
- `Store.lua` carries a schema `version`, and data is migrated, never wiped, when the format changes.

**Score consistency:** each addon calculates scores from the ratings it holds, so two players can see slightly different numbers. Their numbers converge as their addons sync.

### 8.5 What it can't fully stop

- **Alts rating themselves.** Someone levelling many alts to rate themselves. Those ratings carry stranger weight with no shared history, and players' own or friends' experience outweighs them.
- **Invented relays.** A relayer can invent ratings from players who don't exist or never rated. Relays count at 0.2, a relayed death gets no heavy weight, and any contradiction from the real rater costs the relayer a strike. A group of alts relaying the same invented rating can reach the 0.5 weight for 3+ relayers, but never the weight of a direct rating.
- Detecting alt rings properly would need a central server, which is out of scope.

## 9. Mage pipeline

1. **Portal stand:** the mage posts their location and destinations. Destinations come from the mage's **known portal spells** (spell IDs kept in a data table), so the list stays correct if Forever changes the portals. The stand also shows the free seats; the group converts to a raid if needed, the same as in §6.2.
2. **Request:** the traveler picks a destination and an optional offer.
3. **Accept:** the mage accepts and the addon invites the traveler. The traveler sees the mage's location on the map and walks there. Portals have to be clicked near the mage.
4. **Portal:** the mage presses "Open portal to X", a secure button. The travelers click the portal by hand.
5. **Arrival:** a tip window with 50s / 1g / custom and Open trade. **No rating** and no Summon Guard, because portals only go to fixed capital cities.

## 10. UI [Proposed]

| Window | Contents |
|---|---|
| Main window (`/taxi`, minimap button) | Tabs: **Travel** (Summons / Portals), **My stand** (warlock or mage), **Clicking** (marketplace and current shift), **History** |
| Request dialog | Destination, offer (none / 50s / 1g / custom), Send |
| Driver toast | Traveler name, level, guild, offer, Accept / Decline, "Convert to raid & invite" when needed, sound |
| Clicker offer dialog | Offered share, the clicker's ask, Accept / Counter / Decline |
| Guard panel | Next to Blizzard's summon popup: verdict color, check list, "Decline summon" on RED |
| Arrival window | **Trust rating** stars, **tip 50s / 1g / custom** (pre-selected offer), **Open trade with <warlock>**, "Stay and click", "Leave group" |
| Shift-end window | Owed vs received, **Share rating** stars (pre-filled), Submit |
| Mage arrival window | Tip 50s / 1g / custom, Open trade, Leave group |

The UI follows Blizzard's frame style, uses English text, and keeps strings in one table so they can be localized later.

If `SetTradeMoney` can't be called from the addon, "Open trade" opens the trade window and the arrival window shows "Put 1g in the trade" for the traveler to type.

## 11. Data (SavedVariables) [Proposed]

```lua
TaxiDB = {                   -- account-wide
  version = 1,
  ratings = {                -- keyed by warlock "Name"
    ["Darkbolt"] = {
      trust = { {rater, stars, rideId, ts, twoSided, kind, via}, ... },  -- kind: "rating" | "death"
      share = { {rater, stars, shiftId, ts, owed, received, pct, via}, ... },
    },                       -- via: nil if heard directly, else { relayerName, ... }
  },
  given   = { ... },         -- ratings this account gave, kept permanently
  rides   = { ... },         -- my own rides as traveler, summoner, clicker or mage
  liars   = { ["Name"] = ts },      -- raters whose reports were discarded
  strikes = { ["Name"] = count },   -- relayers caught contradicting a direct rating
  settings = { ... },
}
TaxiCharDB = { stand = { seats = 3, clickerPct = 25, note = "" } }  -- per character
```

Ratings don't expire. The cap is 500 per warlock per kind; the oldest are dropped first.

## 12. Messages [Proposed]

Prefix `TaxiFvr`. The format is `v1|TYPE|field|field…`, compact and split into chunks by AceComm when needed. Every message has a `msgId`, and receivers dedupe by (sender, msgId).

| Type | Channel | Fields |
|---|---|---|
| `STAND` | channel | standId, kind (lock/mage), faction, mapID, x, y, zone, subzone, seatsFree, clickers n/2, clickerPct offered, portals (mage) |
| `STAND_END` | channel | standId |
| `REQUEST` | whisper | standId, offer (copper), level, destination (mage) |
| `ACCEPT` / `DECLINE` | whisper | rideId / reason |
| `CLICK_APPLY` | whisper | standId, askedPct |
| `CLICK_OFFER` | whisper | standId, offeredPct |
| `CLICK_OK` / `CLICK_NO` | whisper | standId, agreedPct |
| `RIDE_START` | channel | rideId, warlock |
| `RIDE_LOG` | channel | rideId, traveler, ts |
| `RATING` | channel | kind (trust/share), target, stars, rideId or shiftId, ts, owed/received/pct (share) |
| `DEATH` | channel | rideId, victim, secondsAfterArrival, source (self/group/server) |
| `TIP` / `TIP_ACK` | party/raid | rideId, amount |
| `PORTAL_UP` | party/raid | — |
| `QUERY` / `QUERY_R` | channel / whisper | target / own ratings and relayed records (original rater, stars, id, ts, kind) |

Throttle budget: heartbeats every 60 s with random jitter, everything else is event-driven. Under lockdown, outgoing messages are queued and the UI shows "Paused (instance)".

## 13. Testing and simulation

### 13.1 Unit tests (PC)

`busted` on Lua 5.1 for every `Domain/` module and for `Comms/Protocol.lua`. The required cases:
- SummonGuard verdicts for every check;
- ride state machine transitions;
- negotiation: accept, counter-offer, and refusing a deal that pushes the summoner below 0%;
- rating math, weights and the prior;
- two-sided vs one-sided ratings;
- a death within and outside the 2-minute window;
- liar detection;
- relays: low weight, the 3-relayer bonus, upgrade to direct, a contradiction giving a strike, 3 strikes ignored, a relay of a relay rejected, a relayed death getting no heavy weight;
- ledger agree and dispute cases with different clicker percentages;
- store migration and pruning;
- message round-trip encoding.

`luacheck` runs with the WoW globals declared.

### 13.2 Network simulation (PC)

A harness in `tests/sim/` runs **many simulated clients** of the real `Domain/` and `Comms/` code on a fake message bus. A scripted game world provides positions, summons, trades and deaths, and each client gets its own fake `Game/` adapter. The bus copies the server's behavior: it stamps the sender, throttles, can drop messages, and applies lockdown inside instances.

Each scenario checks what every client ends up believing:
- **Normal loop:** stand → clickers negotiate → travelers request → raid conversion → summons → tips → ratings → query sync for a newly installed client.
- **Wrong-destination summon:** the guard returns RED.
- **Ratings attacks:** a relayer inventing ratings only reaches relayed weight and gets strikes when contradicted; an alt ring self-boosting barely moves the score; a warlock skipping `RIDE_LOG` still gets a reduced-weight rating.
- **History survival:** raters who quit, followed by a fresh install that recovers their ratings as relayed copies.
- **Deaths:** a death within 2 minutes of arrival gives the warlock 1★; a fake death claim by a player who is still alive gets the liar discarded.
- **Payouts:** a stingy warlock gets a low Share rating; a disputed tip is shown as disputed.
- **Network trouble:** message loss and throttling, an addon version mismatch, a crash before save, and a wiped WTF folder refilling over time.

### 13.3 In-game

- **Solo:** `/taxi sim` runs simulated peers against the real UI. It shows fake stands, requests, clicker offers, a summon popup with each guard verdict, and the arrival and shift-end windows.
- **Group:** a manual checklist on Forever, on a normal ruleset until Hardcore launches.
  - A full summon test needs **4 characters**: a warlock of level 20+, 2 clickers and a traveler. Raid conversion needs at least 6.
  - The mage test needs a mage who knows portal spells.

## 14. Build approach

Everything in this spec is built **in one pass**. Internally the work goes in dependency order: core and comms, then the domain modules with their tests, then the simulation harness, then the game adapters, then the UI and `/taxi sim`. It is delivered together.

The in-game checks in §16 are done after the build. Any API that turns out to behave differently is isolated behind its `Game/` adapter, so fixing it doesn't touch the domain logic.

## 15. Out of scope for v1

- Companion app or web backend.
- **Discord:** automatic display would need a companion app plus a Discord bot. A no-app option for later is a "Copy for Discord" button that copies a text summary to paste. Pasted text can't be verified, but it's fine for showing off.
- Stands inside instances.
- Localization beyond English.

## 16. Open questions to verify in game

1. The TOC `## Interface:` number (reported as 16001) and whether Forever needs a TOC filename suffix. Check with `/dump (select(4, GetBuildInfo()))`.
2. Where the summoned player lands: at the warlock's position when accepting, or at the portal. This affects guard check 3.
3. What `GetSummonConfirmAreaName()` returns: the zone or the subzone.
4. Whether `SetTradeMoney` works from a button click (it's restricted).
5. Whether `ConvertToRaid` works from an addon button click (it's restricted). If not, the toast asks the warlock to convert through Blizzard's own menu.
6. Who receives `HARDCORE_DEATHS` in Forever: guild, group, or everyone. This can only be checked once Hardcore launches.
7. Forever Hardcore trade rules, which aren't published yet. If Hardcore disables trading, the tip flow has to change.
8. Custom channel limits on a region-wide mega-realm: member caps and channel throttling.
9. **Final public name** to replace the placeholder "Taxi" before release (see the note at the top).
