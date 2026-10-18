# Taxi

A trust-based summon and portal board for **World of Warcraft: Forever**, built
for the Hardcore ruleset (it also runs on the other rulesets, which is handy
for testing). Players who offer travel post a "stand"; players who want travel
pick one, ask for a seat, and the addon checks the summon against the ride they
agreed to before they accept it.

> **Not tested in the real client yet.** The logic is covered by a PC test suite
> and by a simulation you can run in game (`/taxi sim`), and the TOC interface
> number (16001) is confirmed in game. Everything else still has to be checked
> on the Forever client: see [docs/testing/in-game-checklist.md](docs/testing/in-game-checklist.md).
>
> **"Taxi" is a placeholder name.** The original idea used "Uber", which is a
> trademark. See [The name](#the-name).

## What it does

- **Roles.** A **summoner** is a warlock of level 20 or more who uses Ritual of
  Summoning: the warlock and two **clickers** click the portal, and each summon
  costs a soul shard. A **mage** opens portals to the capitals. Anyone else is a
  traveler, and a traveler who has just arrived can stay and become a clicker.
- **Stands and the board.** A summoner or mage opens a stand (location, seats,
  the share offered to clickers). Travelers browse **Travel** (guildmates first,
  then by rating), send a request with an optional tip offer, and the driver
  accepts; the addon invites. When a group of more than five is needed, the
  warlock gets a one-click "Convert to raid & invite". Clickers find stands on
  the **Clicking** tab or are added from the summoner's own crew.
- **Summon Guard.** When a summon popup appears, a panel beside it compares it
  with your ride: the summoner, the landing area, whether the warlock is at the
  stand, whether anyone is in combat, the zone's level, whether the stand
  moved, and the warlock's rating. It shows GREEN, YELLOW or RED, and on RED
  offers "Decline summon". The addon never accepts a summon, trade, invite or
  portal for you.
- **Trust and Share ratings.** Each warlock has a **Trust** rating (from
  travelers, about safety) and a **Share** rating (from clickers, about fair
  payouts), 1 to 5 stars: "★ 4.8 · 137 summons". Fewer than five ratings shows
  "New". Mages and clickers are not rated.
- **Tips only.** There are no fixed prices. A traveler tips the summoner by
  trade (50s, 1g or a custom amount); the summoner splits it with the clickers
  (50/25/25 by default, negotiated per clicker) and Taxi keeps track of what each
  clicker is owed and has received.
- **In game only.** No companion app and no web service. Each player keeps their
  data in SavedVariables (`TaxiDB` account-wide, `TaxiCharDB` per character) and
  addons sync over addon messages in a public chat channel.

## Install

1. Copy the **`Taxi`** folder (the one that contains `Taxi.toc`) into the
   Forever client's `Interface\AddOns` folder, so that you end up with
   `...\Interface\AddOns\Taxi\Taxi.toc`. The client folder is likely
   `_forever_` (as Classic Era's is `_classic_era_`); the exact name has to be
   confirmed on your install.
2. Start the game and check that Taxi is in the AddOns list, then type `/taxi`.

New ratings are written to disk on `/reload` or logout (the window reminds you).

## Commands

| Command | What it does |
|---|---|
| `/taxi` | Opens or closes the window (tabs Travel, My stand, Clicking, History). The minimap button does the same. |
| `/taxi sim` | Starts a built-in simulation: made-up players and a made-up world, so you can try every window alone. Nothing reaches the real channel and nothing is saved. Don't play Hardcore content while it is on: real death reports are paused. |
| `/taxi sim off` | Ends the simulation and gives your real character back. |
| `/taxi debug` | Prints the version, the engine state, whether the Hardcore ruleset is active, the last status line and any errors Taxi logged. |

Anything else prints a one-line usage message.

## Safety model

Everything the Summon Guard says comes from your own client (the summoner and
the landing area in the summon popup, the positions and combat state of your
group), never from a chat message. Ratings rest on the sender field of addon
messages, which the server fills in, so a rating counts fully only when it comes
straight from the player who gave it; a Trust rating counts fully only when the
traveler's rating and the warlock's own ride log name the same ride. Second-hand copies
(relays) go one hop, weigh little, and are capped per relayer and in total; a
relayer caught contradicting the real rater gets strikes and is ignored after
three. A traveler who dies within two minutes of arriving counts as a heavy 1★
against the warlock, but only when the death is corroborated. Scores include a
prior, so one fresh 5★ cannot make a new warlock look perfect. **Known limits:**
there is no central server, so a ring of alts can still rate each other (such
ratings are strangers' with no shared history, and each fresh alt can file only
one light claim); relays can be invented, which is why their total weight is
capped; editing your own SavedVariables only fools yourself; two players may see
slightly different numbers until their addons sync; a crash before logout loses
that session's new ratings; and the guard cannot see a mob that wanders onto the
spot after you accept.

## Tests

The suite runs on Lua 5.1 with [busted](https://lunarmodules.github.io/busted/) and
[luacheck](https://github.com/lunarmodules/luacheck), in WSL. One-time setup
inside WSL (Debian or Ubuntu):

```sh
sudo apt install lua5.1 liblua5.1-0-dev luarocks build-essential
luarocks --lua-version=5.1 --local install busted
luarocks --lua-version=5.1 --local install luacheck
```

Then, from the repo root in Git Bash:

```sh
# the whole suite, then luacheck
MSYS_NO_PATHCONV=1 wsl.exe -e bash scripts/test.sh

# only some spec files (luacheck still runs afterwards)
MSYS_NO_PATHCONV=1 wsl.exe -e bash scripts/test.sh tests/domain/ratings_spec.lua
```

Inside WSL it is just `bash scripts/test.sh`. `luacheck` must report 0 warnings;
its rules in `.luacheckrc` also enforce the layering below.

## How the code is laid out

Files load in the order of `Taxi/Taxi.toc`.

- `Taxi/Core/`: `Config.lua` (every name and tunable number), `Locale.lua` (all
  player-facing strings), `Callbacks.lua`, and `Init.lua` (the bootstrap and the
  slash command).
- `Taxi/Domain/` and `Taxi/Comms/`: pure Lua with no WoW globals: stands, board,
  negotiation, ride state machine, Summon Guard, ratings, witness, ledger, store,
  and the wire protocol with its chunking, throttling and queue.
- `Taxi/App/`: the Engine and its services (Driver, Traveler, Clicker,
  Reputation), written against an abstract game adapter and clock.
- `Taxi/Game/WoW.lua` (with `Core/Init.lua`): the only code that reads the real
  game. `Taxi/Sim/`: a simulated world, message bus and fake game adapter that the
  tests and `/taxi sim` run the same Engine on.
- `Taxi/UI/`: the windows. They talk to the Engine only.

The design is in [docs/superpowers/specs/2026-10-17-uber-forever-design.md](docs/superpowers/specs/2026-10-17-uber-forever-design.md).

## The name

"Taxi" is a placeholder: "Uber" is a trademark. The addon title, message prefix,
chat channel and slash command are in `Taxi/Core/Config.lua`; the folder, the
`.toc` file and the SavedVariables names (`TaxiDB`, `TaxiCharDB`, declared in the
`.toc` and used in `Core/Init.lua`) follow it. Settle the final name, and the
SavedVariables names in particular, before the first public release: renaming
them later loses everyone's stored ratings unless the data is migrated.
