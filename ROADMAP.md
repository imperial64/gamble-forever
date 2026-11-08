# Roadmap

Backlog from playtests. Highest priority first.

## Open

- **B4 Hole cards may never reach the friend (Hold'em).** Forever rejects an addon whisper to the first name ("No player named 'Efe'", seen in [playtest 1](feedback/2026-11-08-playtest-1.md)), and `whisperTarget` in `Core.lua` whispers exactly that. Needs an in-game test of which name form the server accepts; if none works, send hole cards over PARTY encrypted with a Diffie-Hellman key per player.

## Done

- **B6 Payouts hidden behind the bottom seat's nameplate.** "X pays Y" ran along the status line under the bottom seat. It is now a parchment "Settle Up" card in the empty top-left corner (up to 4 rows, then "and N more"), shown after the round's stinger and hidden when the next round starts. Deathroll's corner seats moved slightly lower to clear it. Reported in chat 2026-11-08 with a Hold'em screenshot.

- **B5 Renamed the addon to GambleForever.** At least six CurseForge addons are called DeathRoll-something, and DeathRoll Enhancer and Deathroll Companion also take `/dr` and `/deathroll`. Now `/gf` and `/gamble`, folder and prefix `GambleForever`, saved data `GambleForeverDB` (the old `DeathrollDB` ledger is not carried over). The Deathroll game keeps its name. The repo folder is still `deathroll`. [playtest 1](feedback/2026-11-08-playtest-1.md)
- **B1 Chat spam "No player named 'Efe' is currently playing."** A solo table whispered every state update to the player's own first name. Solo messages now loop back locally; the UI smoke test fails if a solo table sends anything. [playtest 1](feedback/2026-11-08-playtest-1.md)
- **B2 Cards drawn as green rectangles.** Kenney's card PNGs are 2-bit palette images, which Forever does not draw. All media is now 8-bit RGBA (`scripts/fix-png.py`) and the install script refuses other PNG formats. [playtest 1](feedback/2026-11-08-playtest-1.md)
- **B3 Blackjack: the host was both dealer and player, and labels overlapped.** On a practice table the house now deals from an empty dealer spot and the host plays from the bottom centre (host plus up to 4 bots). Real tables keep the host as the dealer who banks and has no hand. New layout: seat scale .65, dealer seat below the subtitle, bottom seat above the status line, turn text top left opposite the shoe. [playtest 1](feedback/2026-11-08-playtest-1.md)

## Notes

- `SurnamePerCharacter` (in the AddOns folder) is the user's own addon. It only remembers the "show surname over head" setting per character and has nothing to do with Deathroll. The "First Last" names come from Forever itself.
