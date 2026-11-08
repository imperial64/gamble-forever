# GambleForever

A World of Warcraft: Forever addon for gambling with your friends: Deathroll, High-Low, Coinflip, Blackjack and Texas Hold'em, played at a table with seats, dice and cards.

The game server decides every result. Dice games use the normal /roll, Blackjack draws each card from a six-deck shoe with a /roll, and Hold'em shuffles from a secret seed mixed with a /roll and shows the seed after the hand. Every player's addon applies the same rules to the same roll lines, so the host cannot make up a result without everyone's addon noticing.

The addon does not move any gold. It keeps a ledger of who owes whom, and when you trade gold with someone on it, it marks the debt paid.

## Install

1. Download `GambleForever-<version>-forever.zip` from the latest [GitHub Release](https://github.com/imperial64/gamble-forever/releases/latest).
2. Extract it into the game's `Interface\AddOns` folder, so that you end up with `Interface\AddOns\GambleForever\GambleForever.toc`.
3. Start the game, or type `/reload` if it is already running.

## How to play

- `/gf` (or `/gamble`) opens the lobby. Pick a game, a wager and the number of seats, and open a table. Everyone in your party or raid with the addon sees it and can sit down.
- The host presses Start. Each game explains its rules on the table screen.
- `/gf test` opens a practice table with bots, for example `/gf test 3 blackjack`.

### Playing without the addon

With Chat play on (the default), the host posts the table to party or raid chat, and friends without the addon can play by typing whole-message commands there:

- `join`, `leave`
- `rules` (or `help`): the host posts the rules of the game, at most once a minute
- Blackjack: `hit`, `stand`, `double`, `split`
- Hold'em: `check`, `call`, `raise 5` (gold, or `raise 50s`), `allin`, `fold`. Hole cards come by whisper, so on a chat table the host deals and does not play.
- Coinflip: `ready` for another flip

Rolls are typed as usual, for example `/roll 1-1000` in Deathroll.

## Games

- **Deathroll:** take turns rolling 1 to the last roll. Roll a 1 and you are out.
- **High-Low:** everyone rolls at once; the lowest pays the highest the difference.
- **Coinflip:** two seats, heads and tails.
- **Blackjack:** the host deals; up to five players.
- **Texas Hold'em:** no limit, up to six players, everyone starts each hand with 100 big blinds.

## Credits

Cards, dice and sounds by [Kenney](https://kenney.nl) (CC0).

## Support

If you like it, you can buy me a coffee: https://buymeacoffee.com/imperial64
