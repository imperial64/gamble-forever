# Roadmap

Backlog from playtests. Highest priority first.

## Open

- **B4 Hole cards may never reach the friend (Hold'em).** Forever rejects an addon whisper to the first name ("No player named 'Efe'", seen in [playtest 1](feedback/2026-11-08-playtest-1.md)), and `whisperTarget` in `Core.lua` whispers exactly that. [Playtest 2](feedback/2026-11-08-playtest-2.md) says "everything else works", which may mean the friend saw their cards (a whisper to yourself may be the only failing case). Confirm the friend saw only their own two cards; if not, send hole cards over PARTY encrypted with a Diffie-Hellman key per player.
- **B11 High-Low roll cap.** `/roll 1000001` prints nothing, so the server refuses it ([playtest 2](feedback/2026-11-08-playtest-2.md)). `HighLow.ROLL_MAX` assumes 1,000,000 works; still to check that `/roll 1000000` prints a roll. If it does not, the cap is lower and High-Low's unit switch must move.

## Done

- **B12 Hold'em street text sat on the top seat's nameplate.** "SHOWDOWN" (and PRE-FLOP, FLOP...) was at y 170, on the top seat's plate. It now sits between the pot and the top seat. [playtest 2](feedback/2026-11-08-playtest-2.md)

- **B10 Seat glow gave the result away.** The winner's gold glow (and the loser's red) lit up the moment the state arrived, before the coin landed or the deathroll dice settled. Those seats now wait for the reveal, and so does the "X WINS" line. Reported in chat 2026-11-08.
- **B9 Settle Up showed only the last round.** It now keeps a running total for the table, netted per pair (win three coinflips, lose one: one row for two wins' worth), with the round count in the footer. It stays up between rounds and updates after each reveal. Reported in chat 2026-11-08.

- **B8 Coinflip looked flat.** It was an item icon squashed sideways. Now a drawn two-sided coin (crown heads, skull tails, reeded edge from `scripts/make-coin-art.py`) tossed in an arc, flipping end over end and slowing, with a shadow on the felt, one bounce and a gold flash on landing. Requested in chat 2026-11-08.
- **B7 Settle Up card folds and scrolls.** Fold button in its header (remembered in `settings.settleFolded`; folded shows the payment count); more than 4 payments scroll with the mouse wheel. Requested in chat 2026-11-08.

- **B6 Payouts hidden behind the bottom seat's nameplate.** "X pays Y" ran along the status line under the bottom seat. It is now a parchment "Settle Up" card in the empty top-left corner (up to 4 rows, then "and N more"), shown after the round's stinger and hidden when the next round starts. Deathroll's corner seats moved slightly lower to clear it. Reported in chat 2026-11-08 with a Hold'em screenshot.

- **B5 Renamed the addon to GambleForever.** At least six CurseForge addons are called DeathRoll-something, and DeathRoll Enhancer and Deathroll Companion also take `/dr` and `/deathroll`. Now `/gf` and `/gamble`, folder and prefix `GambleForever`, saved data `GambleForeverDB` (the old `DeathrollDB` ledger is not carried over). The Deathroll game keeps its name. The repo folder is still `deathroll`. [playtest 1](feedback/2026-11-08-playtest-1.md)
- **B1 Chat spam "No player named 'Efe' is currently playing."** A solo table whispered every state update to the player's own first name. Solo messages now loop back locally; the UI smoke test fails if a solo table sends anything. [playtest 1](feedback/2026-11-08-playtest-1.md)
- **B2 Cards drawn as green rectangles.** Kenney's card PNGs are 2-bit palette images, which Forever does not draw. All media is now 8-bit RGBA (`scripts/fix-png.py`) and the install script refuses other PNG formats. [playtest 1](feedback/2026-11-08-playtest-1.md)
- **B3 Blackjack: the host was both dealer and player, and labels overlapped.** On a practice table the house now deals from an empty dealer spot and the host plays from the bottom centre (host plus up to 4 bots). Real tables keep the host as the dealer who banks and has no hand. New layout: seat scale .65, dealer seat below the subtitle, bottom seat above the status line, turn text top left opposite the shoe. [playtest 1](feedback/2026-11-08-playtest-1.md)

## Notes

- Hold'em stacks are 100 big blinds, and the big blind is the table's wager. A practice table (`/gf test`) uses a 25s 50c wager, so stacks start at 25g 50s; 24g 73s 50c is that minus what went into the pot ([playtest 2](feedback/2026-11-08-playtest-2.md)).

- `SurnamePerCharacter` (in the AddOns folder) is the user's own addon. It only remembers the "show surname over head" setting per character and has nothing to do with Deathroll. The "First Last" names come from Forever itself.
