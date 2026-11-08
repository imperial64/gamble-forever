-- Chat play: players without the addon sit and play by typing in party or raid chat, and the
-- host's addon narrates what they need to know. Rolls are never narrated; everyone sees them.
-- Only whole messages count: one command word, or "raise <amount>". Anything else is talk.
--
-- Pure apart from hooks Core sets: ns.say(text, key) and ns.sayTo(name, text).
local _, ns = ...
local C = ns.Cards
local Chat = {}
ns.Chat = Chat

local WORDS = { join = "join", sit = "join", leave = "leave", hit = "hit", stand = "stand", stay = "stand",
    double = "double", split = "split", fold = "fold", check = "check", call = "call", raise = "raise",
    bet = "raise", allin = "allin" }
local UNIT = { g = 10000, s = 100, c = 1 }

-- "500" is gold; "50s", "1g 50s" and "2550c" spell the coins out. Copper, or nil.
function Chat.amount(s)
    s = s:gsub("%s+", "")
    if s:match("^%d+$") then return tonumber(s) * 10000 end
    local total = 0
    local rest = s:gsub("(%d+)([gsc])", function(n, u) total = total + tonumber(n) * UNIT[u]; return "" end)
    if rest == "" and total > 0 then return total end
end

-- action, amount (copper) or nil
function Chat.parse(text)
    local s = text:lower():gsub("^%s+", ""):gsub("[%s!%.]+$", "")
    if s == "all in" or s == "all-in" then return "allin" end
    local w, rest = s:match("^(%a+)%s*(.-)$")
    local a = w and WORDS[w]
    if not a then return nil end
    if rest == "" then return a ~= "raise" and a or nil end
    if a == "raise" then
        local amt = Chat.amount((rest:gsub("^to%s+", "")))
        if amt then return a, amt end
    end
end

-- plain coins for chat, which cannot show the coin icons: "1g 50s"
function Chat.money(copper)
    copper = math.floor(copper or 0)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local out = {}
    if g > 0 then out[#out + 1] = g .. "g" end
    if s > 0 then out[#out + 1] = s .. "s" end
    if c > 0 or #out == 0 then out[#out + 1] = c .. "c" end
    return table.concat(out, " ")
end

-- chat lines stop at 255 characters: break long ones after a comma
function Chat.fit(line)
    local out = {}
    while #line > 250 do
        local cut = line:sub(1, 250):match("^.*(), ") or 250
        out[#out + 1] = line:sub(1, cut - 1)
        line = "[GF] " .. line:sub(cut):gsub("^,? *", "")
    end
    out[#out + 1] = line
    return out
end

---------------------------------------------------------------- lines

local function nm(n) return (n or "?"):match("^[^ %-]+") end
local function hand(cards)
    local o = {}
    for i, c in ipairs(cards or {}) do o[i] = C.text(c) end
    return table.concat(o, " ")
end
local function list(names)
    if #names <= 1 then return names[1] or "" end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end
local function payments(debts)
    local o = {}
    for _, d in ipairs(debts) do o[#o + 1] = ("%s pays %s %s"):format(nm(d.from), nm(d.to), Chat.money(d.amount)) end
    return table.concat(o, ", ")
end

local STAKE = { deathroll = "wager", highlow = "wager", coinflip = "wager", blackjack = "bet", poker = "big blind" }

function Chat.openLine(t)
    return ("[GF] %s table open, %s %s. Type join to sit, leave to get up. Only the host's addon judges this table.")
        :format(ns.Games[t.game].name, STAKE[t.game], Chat.money(t.wager))
end

function Chat.seatsLine(t)
    local names, len = {}, 0
    for i, n in ipairs(t.seats) do
        if len > 180 then names[#names + 1] = ("+%d more"):format(#t.seats - i + 1); break end
        names[#names + 1] = nm(n)
        len = len + #names[#names] + 2
    end
    return ("[GF] Seated (%d/%d): %s."):format(#t.seats, t.maxSeats, table.concat(names, ", "))
end

local function startLine(t)
    local m = Chat.money(t.wager)
    if t.game == "deathroll" then
        return ("[GF] Deathroll from %d, wager %s. %s rolls for who goes first."):format(t.start, m, nm(t.host))
    elseif t.game == "highlow" then
        return ("[GF] High-Low, wager %s: everyone /roll 1-%d now. Lowest pays highest the difference%s.")
            :format(m, t.range, t.unit > 1 and (" (1 point = " .. Chat.money(t.unit) .. ")") or "")
    elseif t.game == "coinflip" then
        return ("[GF] Coinflip for %s: %s heads, %s tails."):format(m, nm(t.seats[1]), nm(t.seats[2]))
    elseif t.game == "poker" then
        return ("[GF] Hold'em hand %d, blinds %s/%s, %s on the button. Chat players get their cards by whisper.")
            :format(t.round, Chat.money(t.sb), Chat.money(t.bb), nm(t.seats[t.button]))
    end
end

local BJ = ns.Games.blackjack   -- Chat.lua loads after Blackjack.lua
local function bjHand(h)
    local tot = BJ.total(h.cards)
    local tag = BJ.isBJ(h) and "blackjack" or tot > 21 and (tot .. ", bust") or tostring(tot)
    return hand(h.cards) .. " (" .. tag .. ")"
end
local function bjName(t, s, h)
    return nm(t.seats[s]) .. (#t.hands[s] > 1 and (" hand " .. h) or "")
end

local function dealLine(t)
    local o = {}
    for s = BJ.first(t), #t.seats do
        for h, hd in ipairs(t.hands[s] or {}) do o[#o + 1] = bjName(t, s, h) .. ": " .. bjHand(hd) end
    end
    return ("[GF] Dealer shows %s. %s."):format(hand({ t.dealer.cards[1] }), table.concat(o, ", "))
end

local function pot(t)
    local p = 0
    for s = 1, #t.seats do p = p + (t.total[s] or 0) end
    return p
end

local POKER_ACT = { fold = "folds", check = "checks", call = "calls" }
local function eventLine(c, t, ev)
    if t.game == "highlow" then
        local e = ev.next or ev
        if e.kind == "tie" then
            local names = {}
            for _, s in ipairs(e.seats) do names[#names + 1] = nm(t.seats[s]) end
            return ("[GF] Tie for %s: %s. /roll 1-%d again."):format(e.side == "hi" and "high" or "low", list(names), t.range)
        end
    elseif t.game == "blackjack" then
        -- a hit that ends the hand; while the hand goes on, the prompt shows the new card
        local hd = ev.kind == "card" and ev.seat > 0 and c.saidDeal == t.round and t.hands[ev.seat][ev.hand]
        if hd and hd.done and c.chatters[t.seats[ev.seat]] then
            return "[GF] " .. bjName(t, ev.seat, ev.hand) .. ": " .. bjHand(hd) .. "."
        end
    elseif t.game == "poker" and ev.kind == "act" then
        local what = POKER_ACT[ev.action]
            or ev.action == "raise" and ("raises to " .. Chat.money(ev.amount))
            or ev.action == "allin" and ("goes all in, " .. Chat.money(ev.amount))
        if what then return ("[GF] %s %s."):format(nm(t.seats[ev.seat]), what) end
    end
end

local function resultLine(t)
    local g = ns.Games[t.game]
    if t.game == "deathroll" then
        return ("[GF] %s wins. %s."):format(nm(t.seats[t.winner]), payments(g.debts(t)))
    elseif t.game == "highlow" then
        if not (t.hiSeat and t.loSeat) or (t.diff or 0) <= 0 then return "[GF] Push, nobody pays." end
        return ("[GF] %s high, %s low: %s."):format(nm(t.seats[t.hiSeat]), nm(t.seats[t.loSeat]), payments(g.debts(t)))
    elseif t.game == "coinflip" then
        local side = t.result == 1 and "Heads" or t.result == 2 and "Tails" or "A player left"
        return ("[GF] %s. %s."):format(side, payments(g.debts(t)))
    elseif t.game == "blackjack" then
        local o = {}
        for s = BJ.first(t), #t.seats do
            local r = t.results[s] or 0
            o[#o + 1] = nm(t.seats[s]) .. (r > 0 and (" wins " .. Chat.money(r)) or r < 0 and (" loses " .. Chat.money(-r)) or " pushes")
        end
        return ("[GF] Dealer: %s. %s."):format(bjHand(t.dealer), table.concat(o, ", "))
    elseif t.game == "poker" then
        local names = {}
        for _, s in ipairs(t.winners) do names[#names + 1] = nm(t.seats[s]) end
        local won = ("%s %s %s"):format(list(names), #names > 1 and "split" or "wins", Chat.money(t.pot))
        if not t.shown then return ("[GF] %s, everyone else folded."):format(won) end
        local o = {}
        for s = 1, #t.seats do
            if t.shown[s] then o[#o + 1] = ("%s %s (%s)"):format(nm(t.seats[s]), hand(t.shown[s]), C.handName(t.scores[s])) end
        end
        return ("[GF] Showdown on %s: %s. %s."):format(hand(t.board), table.concat(o, ", "), won)
    end
end

-- what the chat player whose turn it is may do: text and a key that changes with the turn
local function prompt(c, t)
    local g = ns.Games[t.game]
    if t.game == "deathroll" then
        local name = t.phase == "rolling" and t.seats[t.turn]
        if name and c.chatters[name] then
            return ("[GF] %s, /roll 1-%d"):format(nm(name), t.cur), table.concat({ t.round, #t.history, t.turn }, ":")
        end
    elseif t.game == "blackjack" then
        local s = t.turn and t.turn[1]
        local can = s and c.chatters[t.seats[s]] and g.actions(t, s)
        if can then
            local opts = {}
            for _, a in ipairs({ "hit", "stand", "double", "split" }) do if can[a] then opts[#opts + 1] = a end end
            return ("[GF] %s: %s vs %s. %s?"):format(bjName(t, s, t.turn[2]), bjHand(t.hands[s][t.turn[2]]),
                hand({ t.dealer.cards[1] }), table.concat(opts, ", ")), table.concat({ t.round, t.draws, s, t.turn[2] }, ":")
        end
    elseif t.game == "poker" then
        local s = t.toAct
        local can = s and c.chatters[t.seats[s]] and g.actions(t, s)
        if can then
            local opts = { can.check and "check" or ("call " .. Chat.money(can.call)) }
            if can.raise then opts[#opts + 1] = "raise " .. Chat.money(can.minTo) .. " or more" end
            opts[#opts + 1] = "allin"
            opts[#opts + 1] = "fold"
            return ("[GF] %s, pot %s: %s?"):format(nm(t.seats[s]), Chat.money(pot(t)), table.concat(opts, ", ")),
                table.concat({ t.round, t.street, s, t.curBet, pot(t) }, ":")
        end
    end
end

function Chat.holeLine(t, seat)
    return ("[GF] Your cards for hand %d: %s"):format(t.round, hand(t.holes[seat]))
end

---------------------------------------------------------------- the host's narrator

local function say(text, key)
    local lines = Chat.fit(text)
    for _, l in ipairs(lines) do ns.say(l, #lines == 1 and key or nil) end
end

-- Called by the host after every change: the group can follow the table and join in. Prompts
-- and hole cards go only to chat players; addon players have the table view.
function Chat.hostChanged(c, ev)
    local t = c.t
    if not c.saidOpen then
        c.saidOpen, c.saidSeats = true, #t.seats
        say(Chat.openLine(t))
    end
    if (t.phase == "seating" or t.phase == "done") and c.saidSeats ~= #t.seats then
        c.saidSeats = #t.seats
        say(Chat.seatsLine(t), "seats")
    end
    if t.phase == "seating" then return end
    if c.saidStart ~= t.round then
        c.saidStart = t.round
        local l = startLine(t)
        if l then say(l) end
    end
    local l = ev and eventLine(c, t, ev)
    if l then say(l) end
    if t.game == "blackjack" and t.phase ~= "dealing" and c.saidDeal ~= t.round then
        c.saidDeal = t.round
        say(dealLine(t))
    end
    if t.game == "poker" and t.street and t.street ~= "preflop" and t.street ~= "showdown" then
        local key = t.round .. t.street
        if c.saidStreet ~= key then
            c.saidStreet = key
            say(("[GF] %s%s: %s. Pot %s."):format(t.street:sub(1, 1):upper(), t.street:sub(2), hand(t.board), Chat.money(pot(t))))
        end
    end
    if t.phase == "done" and c.saidDone ~= t.round then
        c.saidDone = t.round
        say(resultLine(t) .. (#t.seats < t.maxSeats and " Type join to play the next round." or ""))
    end
    local p, key = prompt(c, t)
    if p and key ~= c.saidPrompt then c.saidPrompt = key; say(p, "prompt")
    elseif not p then ns.say(nil, "prompt") end   -- the turn moved on: drop a prompt still queued
end
