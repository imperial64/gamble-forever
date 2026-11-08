-- Blackjack. Pure: no WoW API.
-- The host is the dealer (seat 1); seats 2-6 play. Cards come from a real six-deck shoe: the
-- dealer's addon rolls /roll 1-<cards left>, that card leaves the shoe, and the shoe carries
-- on between hands until a quarter is left, then it is replaced.
-- European rules (no hole card): the dealer takes one card, and the second only after the
-- players finish, so no hidden card is ever needed. Dealer stands on all 17s. Blackjack pays
-- 3:2. Double on any first two cards. Split once; split aces get one card each.
-- A dealer blackjack beats everything but a player blackjack, doubles and splits included.
local _, ns = ...
local C = ns.Cards
local BJ = { name = "Blackjack", minSeats = 2, maxSeats = 6, decks = 6, cut = 78 }
ns.Games.blackjack = BJ

function BJ.total(cards)
    local t, aces = 0, 0
    for _, c in ipairs(cards) do
        local v = C.value(c)
        if v == 14 then aces = aces + 1; t = t + 11 elseif v >= 10 then t = t + 10 else t = t + v end
    end
    while t > 21 and aces > 0 do t = t - 10; aces = aces - 1 end
    return t, aces > 0
end
local function points(c) local v = C.value(c); return v == 14 and 11 or math.min(v, 10) end
local function isBJ(hand) return #hand.cards == 2 and not hand.split and BJ.total(hand.cards) == 21 end
BJ.isBJ = isBJ

function BJ.setup(t, opts)
    t.shoe = C.newShoe(BJ.decks); t.draws = 0
    t.practice = opts and opts.practice or false
end

-- Seat 1 is the dealer. On a practice table the house deals for itself and the host plays too.
function BJ.first(t) return t.practice and 1 or 2 end

local function handOf(t, need)
    if need[1] == 0 then return t.dealer end
    return t.hands[need[1]] and t.hands[need[1]][need[2]]
end

local function results(t)
    local d = t.dealer.cards
    local dt = BJ.total(d)
    local dBJ = #d == 2 and dt == 21
    t.results, t.outcome = {}, {}
    for s = BJ.first(t), #t.seats do
        local net = 0
        t.outcome[s] = {}
        for h, hand in ipairs(t.hands[s] or {}) do
            local p = BJ.total(hand.cards)
            local stake = t.wager * hand.bet
            local r
            if hand.forfeit or p > 21 then r = -stake
            elseif isBJ(hand) and not dBJ then r = math.floor(t.wager * 1.5)
            elseif dBJ and not isBJ(hand) then r = -stake
            elseif dBJ and isBJ(hand) then r = 0
            elseif dt > 21 or p > dt then r = stake
            elseif p == dt then r = 0
            else r = -stake end
            t.outcome[s][h] = r
            net = net + r
        end
        t.results[s] = net
    end
end

local function finish(t)
    t.phase, t.need, t.turn = "done", nil, nil
    results(t)
end

local function dealerNeed(t)
    local live, anyBJ = false, false
    for s = BJ.first(t), #t.seats do
        for _, hand in ipairs(t.hands[s] or {}) do
            if isBJ(hand) then anyBJ = true
            elseif not hand.forfeit and BJ.total(hand.cards) <= 21 then live = true end
        end
    end
    local dt = BJ.total(t.dealer.cards)
    if (live and dt < 17) or (not live and anyBJ and #t.dealer.cards < 2) then
        t.need = { 0 }
    else
        finish(t)
    end
end

local function nextTurn(t)
    for s = BJ.first(t), #t.seats do
        for h, hand in ipairs(t.hands[s] or {}) do
            if not hand.done then t.turn = { s, h }; return end
        end
    end
    t.turn, t.phase = nil, "dealer"
    dealerNeed(t)
end

function BJ.start(t)
    if not t.shoe or t.shoe.left < BJ.cut then t.shoe = C.newShoe(BJ.decks); t.reshuffled = true else t.reshuffled = false end
    t.round = (t.round or 0) + 1
    t.phase, t.turn, t.results, t.outcome = "dealing", nil, nil, nil
    t.dealer = { cards = {} }
    t.hands, t.queue = {}, {}
    for s = BJ.first(t), #t.seats do t.hands[s] = { { cards = {}, bet = 1 } } end
    for r = 1, 2 do
        for s = BJ.first(t), #t.seats do t.queue[#t.queue + 1] = { s, 1 } end
        if r == 1 then t.queue[#t.queue + 1] = { 0 } end
    end
    t.need = table.remove(t.queue, 1)
end

function BJ.hostRoll(t)
    if t.need then return 1, t.shoe.left end
end
function BJ.rangeFor() return nil end

local function afterCard(t, need)
    local hand = handOf(t, need)
    local tot = BJ.total(hand.cards)
    if tot > 21 or tot == 21 or (hand.doubled and #hand.cards >= 3) or (hand.aceSplit and #hand.cards >= 2) then hand.done = true end
    if #t.queue > 0 then t.need = table.remove(t.queue, 1); return end
    local cur = t.turn and handOf(t, t.turn)
    if not cur or cur.done then nextTurn(t) end
end

function BJ.onRoll(t, name, value, lo, hi)
    if not t.need or not ns.Rolls.same(name, t.host) or lo ~= 1 or hi ~= t.shoe.left then return nil end
    local card = C.draw(t.shoe, value)
    if not card then return nil end
    t.draws = (t.draws or 0) + 1
    local need = t.need
    t.need = nil
    table.insert(handOf(t, need).cards, card)
    local ev = { kind = "card", seat = need[1], hand = need[2], card = card }
    if t.phase == "dealing" then
        if #t.queue > 0 then
            t.need = table.remove(t.queue, 1)
        else
            for s = BJ.first(t), #t.seats do
                for _, hand in ipairs(t.hands[s]) do if isBJ(hand) then hand.done = true end end
            end
            t.phase = "playing"
            nextTurn(t)
        end
    elseif t.phase == "playing" then
        afterCard(t, need)
    elseif t.phase == "dealer" then
        dealerNeed(t)
    end
    if t.phase == "done" then ev.done = true end
    return ev
end

-- What the seat may do right now: { hit, stand, double, split } or nil.
function BJ.actions(t, seat)
    if t.phase ~= "playing" or t.need or not t.turn or t.turn[1] ~= seat then return nil end
    local hand = handOf(t, t.turn)
    local two = #hand.cards == 2
    return { hit = true, stand = true, double = two and not hand.doubled,
        split = two and #t.hands[seat] == 1 and points(hand.cards[1]) == points(hand.cards[2]) }
end

function BJ.act(t, seat, action)
    local can = BJ.actions(t, seat)
    if not can or not can[action] then return nil end
    local hand = handOf(t, t.turn)
    if action == "hit" then
        t.need = { seat, t.turn[2] }
    elseif action == "stand" then
        hand.done = true
        nextTurn(t)
    elseif action == "double" then
        hand.bet, hand.doubled = 2, true
        t.need = { seat, t.turn[2] }
    elseif action == "split" then
        local a, b = hand.cards[1], hand.cards[2]
        local aces = C.value(a) == 14
        t.hands[seat] = { { cards = { a }, bet = 1, split = true, aceSplit = aces },
            { cards = { b }, bet = 1, split = true, aceSplit = aces } }
        t.queue = { { seat, 1 }, { seat, 2 } }
        t.turn = { seat, 1 }
        t.need = table.remove(t.queue, 1)
    end
    return { kind = "act", seat = seat, action = action }
end

-- Leaving mid-hand loses that seat's hands.
function BJ.forfeit(t, seat)
    if t.phase == "seating" or t.phase == "done" or not t.hands[seat] then return nil end
    for _, hand in ipairs(t.hands[seat]) do hand.forfeit, hand.done = true, true end
    if t.need and t.need[1] == seat then t.need = nil; t.queue = {} end
    if t.phase == "playing" and t.turn and t.turn[1] == seat then nextTurn(t) end
    if t.phase == "dealing" then
        local q = {}
        for _, n in ipairs(t.queue) do if n[1] ~= seat then q[#q + 1] = n end end
        t.queue = q
        if not t.need then t.need = table.remove(t.queue, 1) end
    end
    return { kind = "act", seat = seat, action = "leave" }
end

function BJ.debts(t)
    local d = {}
    if t.phase ~= "done" or not t.results then return d end
    for s = 2, #t.seats do   -- the house never owes itself (practice seat 1)
        local net = t.results[s] or 0
        if net > 0 then d[#d + 1] = { from = t.seats[1], to = t.seats[s], amount = net }
        elseif net < 0 then d[#d + 1] = { from = t.seats[s], to = t.seats[1], amount = -net } end
    end
    return d
end

-- A guest compares the shoe it built from the dealer's roll lines with the dealer's state: the
-- same number of draws must have taken out exactly the same cards.
function BJ.check(mine, host)
    if mine and mine.shoe and host.shoe and mine.round == host.round and mine.draws == host.draws
        and C.packShoe(mine.shoe) ~= C.packShoe(host.shoe) then
        return "a card that the dealer's roll did not draw"
    end
end

local function packNeed(n) return n and (n[1] .. "." .. (n[2] or 0)) or "" end
local function unpackNeed(s)
    local a, b = (s or ""):match("^(%d+)%.(%d+)$")
    if not a then return nil end
    a, b = tonumber(a), tonumber(b)
    return a == 0 and { 0 } or { a, b }
end

function BJ.encode(t)
    local seats = {}
    for s = BJ.first(t), #t.seats do
        local hs = {}
        for _, h in ipairs((t.hands or {})[s] or {}) do
            local flags = (h.done and "d" or "") .. (h.doubled and "x" or "") .. (h.split and "s" or "")
                .. (h.aceSplit and "a" or "") .. (h.forfeit and "f" or "")
            hs[#hs + 1] = h.bet .. flags .. ":" .. C.pack(h.cards)
        end
        seats[#seats + 1] = table.concat(hs, "/")
    end
    local q = {}
    for _, n in ipairs(t.queue or {}) do q[#q + 1] = packNeed(n) end
    return { C.packShoe(t.shoe), t.draws or 0, packNeed(t.need), packNeed(t.turn), table.concat(q, "+"),
        C.pack(t.dealer and t.dealer.cards), table.concat(seats, ","), t.reshuffled and 1 or 0, t.practice and 1 or 0 }
end

function BJ.decode(t, f)
    t.shoe = C.unpackShoe(f[1]) or C.newShoe(BJ.decks)
    t.draws = tonumber(f[2]) or 0
    t.need, t.turn = unpackNeed(f[3]), unpackNeed(f[4])
    t.queue = {}
    for p in (f[5] or ""):gmatch("[^+]+") do t.queue[#t.queue + 1] = unpackNeed(p) end
    t.dealer = { cards = C.unpack(f[6]) }
    t.practice = f[9] == "1"
    t.hands = {}
    local i = BJ.first(t)
    for seatStr in ((f[7] or "") .. ","):gmatch("(.-),") do
        t.hands[i] = {}
        for hs in seatStr:gmatch("[^/]+") do
            local bet, flags, cards = hs:match("^(%d)(%a*):(%x*)$")
            if bet then
                t.hands[i][#t.hands[i] + 1] = { bet = tonumber(bet), cards = C.unpack(cards), done = flags:find("d") ~= nil,
                    doubled = flags:find("x") ~= nil, split = flags:find("s") ~= nil, aceSplit = flags:find("a") ~= nil,
                    forfeit = flags:find("f") ~= nil }
            end
        end
        i = i + 1
    end
    t.reshuffled = f[8] == "1"
    if t.phase == "done" then results(t) end
end
