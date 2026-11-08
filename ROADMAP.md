# Roadmap

Backlog from playtests. Highest priority first.

## Open

- **B4 Hole cards may never reach the friend (Hold'em).** Forever rejects an addon whisper to the first name ("No player named 'Efe'", seen in [playtest 1](feedback/2026-11-08-playtest-1.md)), and `whisperTarget` in `Core.lua` whispers exactly that. Needs an in-game test of which name form the server accepts; if none works, send hole cards over PARTY encrypted with a Diffie-Hellman key per player.
- **B5 Rename the addon.** At least six CurseForge addons are called DeathRoll-something, and DeathRoll Enhancer and Deathroll Companion also take `/dr` and `/deathroll`. Proposed: GambleForever (unused), with `/gf` and `/gamble`, which matches GearQuestForever, SkillUpForever and RoutePlannerForever. Touches the folder, toc, message prefix, SavedVariables (the old ledger stays behind), globals and slash commands. [playtest 1](feedback/2026-11-08-playtest-1.md)

## Done

- **B1 Chat spam "No player named 'Efe' is currently playing."** A solo table whispered every state update to the player's own first name. Solo messages now loop back locally; the UI smoke test fails if a solo table sends anything. [playtest 1](feedback/2026-11-08-playtest-1.md)
- **B2 Cards drawn as green rectangles.** Kenney's card PNGs are 2-bit palette images, which Forever does not draw. All media is now 8-bit RGBA (`scripts/fix-png.py`) and the install script refuses other PNG formats. [playtest 1](feedback/2026-11-08-playtest-1.md)
- **B3 Blackjack: the host was both dealer and player, and labels overlapped.** On a practice table the house now deals from an empty dealer spot and the host plays from the bottom centre (host plus up to 4 bots). Real tables keep the host as the dealer who banks and has no hand. New layout: seat scale .65, dealer seat below the subtitle, bottom seat above the status line, turn text top left opposite the shoe. [playtest 1](feedback/2026-11-08-playtest-1.md)

## Notes

- `SurnamePerCharacter` (in the AddOns folder) is the user's own addon. It only remembers the "show surname over head" setting per character and has nothing to do with Deathroll. The "First Last" names come from Forever itself.
