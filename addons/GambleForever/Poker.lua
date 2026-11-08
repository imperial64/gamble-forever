-- Texas Hold'em, no limit. Pure: no WoW API.
-- Hole cards must stay hidden and every /roll is public, so cards cannot be rolled one by one
-- like Blackjack's. Instead the host's addon picks a secret seed and publishes its fingerprint,
-- then rolls /roll 1-SHUFFLE_ROLL; the deck is shuffled from the seed and that roll together, so
-- the host cannot choose the deck (the roll comes after the fingerprint) and nobody else can see
-- it (the seed is secret). Each player's two cards go in a private message, and the seed is
-- revealed when the hand ends. Every client then checks the fingerprint, the roll, the board and
-- the shown hands against the revealed deck.
-- The host's addon knows the hole cards during a hand, and the revealed seed also shows folded
-- hands afterwards; both are stated in the rules screen. With chat play on, the host whispers
-- chat players their cards in plain text, so the host deals and does not play (dealerOnly:
-- seat 1 is the dealer, seats 2+ play, like a real Blackjack table).
-- Everyone starts every hand with the same stack, 100 big blinds, and each hand settles on its
-- own into the ledger. With equal stacks every all-in is the same size, so there are no side pots.
local _, ns = ...
local C = ns.Cards
local PK = { name = "Texas Hold'em", minSeats = 2, maxSeats = 6, stackBB = 100, SHUFFLE_ROLL = 10000 }
ns.Games.poker = PK

function PK.setup(t, opts)
    t.bb = math.max(2, t.wager)
    t.sb = math.max(1, math.floor(t.bb / 2))
    t.cap = PK.stackBB * t.bb
    t.button = 0
    t.dealerOnly = opts and opts.dealerOnly or false
end

local function off(t) return t.dealerOnly and 1 or 0 end
function PK.first(t) return off(t) + 1 end
local function n(t) return #t.seats - off(t) end
local function nextSeat(t, s) return (s - off(t)) % n(t) + 1 + off(t) end
local function left(t, s) return t.cap - (t.total[s] or 0) end

local function post(t, s, amount)
    amount = math.min(amount, left(t, s))
    t.bet[s] = (t.bet[s] or 0) + amount
    t.total[s] = (t.total[s] or 0) + amount
    if left(t, s) <= 0 then t.allin[s] = true end
end

-- The deal is a pure function of the seed, the shuffle roll, the seats and the button, so anyone
-- can redo it once the seed is out. `skip` seats at the front (the dealer) get no cards.
function PK.deal(seed, roll, seats, button, skip)
    skip = skip or 0
    local deck = C.shuffle(seed .. ":" .. roll)
    local count = seats - skip
    local holes, i = {}, 1
    for _ = 1, 2 do
        local s = button
        for _ = 1, count do
            s = (s - skip) % count + 1 + skip
            holes[s] = holes[s] or {}
            table.insert(holes[s], deck[i])
            i = i + 1
        end
    end
    -- burn one, flop three, burn, turn, burn, river
    local board = { deck[i + 1], deck[i + 2], deck[i + 3], deck[i + 5], deck[i + 7] }
    return holes, board
end

local function needsAction(t, s)
    return t.inHand[s] and not t.allin[s] and (not t.acted[s] or (t.bet[s] or 0) < t.curBet)
end

local function firstActor(t, after)
    local s = after
    for _ = 1, n(t) do
        s = nextSeat(t, s)
        if t.inHand[s] and not t.allin[s] then return s end
    end
end

local BOARD_COUNT = { preflop = 0, flop = 3, turn = 4, river = 5 }
local STREETS = { "preflop", "flop", "turn", "river" }

local function finish(t, winners)
    local pot = 0
    for s = PK.first(t), #t.seats do pot = pot + (t.total[s] or 0) end
    t.won, t.net = {}, {}
    local share = math.floor(pot / #winners)
    local extra = pot - share * #winners
    -- odd copper goes to the first winners after the button
    table.sort(winners, function(a, b) return (a - t.button - 1) % n(t) < (b - t.button - 1) % n(t) end)
    for i, s in ipairs(winners) do t.won[s] = share + (i <= extra and 1 or 0) end
    for s = PK.first(t), #t.seats do t.net[s] = (t.won[s] or 0) - (t.total[s] or 0) end
    t.winners, t.phase, t.toAct, t.pot = winners, "done", nil, pot
    if t.seed then t.reveal = t.seed end
end

local function showdown(t)
    t.street = "showdown"
    t.shown, t.scores = {}, {}
    local best, winners
    for s = PK.first(t), #t.seats do
        if t.inHand[s] then
            local cards = { t.holes[s][1], t.holes[s][2] }
            for _, c in ipairs(t.board) do cards[#cards + 1] = c end
            local score = C.eval(cards)
            t.shown[s], t.scores[s] = t.holes[s], score
            local cmp = best and C.cmp(score, best) or 1
            if cmp > 0 then best, winners = score, { s } elseif cmp == 0 then winners[#winners + 1] = s end
        end
    end
    finish(t, winners)
end

local function nextStreet(t)
    for s = PK.first(t), #t.seats do t.bet[s] = 0 end
    t.acted, t.curBet, t.minRaise = {}, 0, t.bb
    local idx
    for i, st in ipairs(STREETS) do if st == t.street then idx = i end end
    if idx == #STREETS then return showdown(t) end
    t.street = STREETS[idx + 1]
    t.board = {}
    for i = 1, BOARD_COUNT[t.street] do t.board[i] = t.fullBoard[i] end
    local canAct = 0
    for s = PK.first(t), #t.seats do if t.inHand[s] and not t.allin[s] then canAct = canAct + 1 end end
    if canAct <= 1 then return nextStreet(t) end   -- everyone else is all in: run the board out
    t.toAct = firstActor(t, t.button)
end

local function advance(t)
    local live = {}
    for s = PK.first(t), #t.seats do if t.inHand[s] then live[#live + 1] = s end end
    if #live == 1 then return finish(t, live) end
    local s = t.toAct
    for _ = 1, n(t) do
        s = nextSeat(t, s)
        if needsAction(t, s) then t.toAct = s; return end
    end
    nextStreet(t)
end

-- Host only: `seed` is secret until the hand ends. Clients get the public part via the state.
-- The blinds go in now; the cards wait for the shuffle roll.
function PK.start(t, seed)
    t.round = (t.round or 0) + 1
    t.button = (t.button or 0) == 0 and PK.first(t) or nextSeat(t, t.button)
    t.seed, t.reveal, t.commit, t.roll, t.rollSeen = seed, nil, C.commit(seed), nil, nil
    t.holes, t.fullBoard, t.myHole = nil, nil, nil
    t.board, t.shown, t.scores, t.won, t.net, t.winners = {}, nil, nil, nil, nil, nil
    t.inHand, t.allin, t.bet, t.total, t.acted = {}, {}, {}, {}, {}
    for s = PK.first(t), #t.seats do t.inHand[s], t.bet[s], t.total[s] = true, 0, 0 end
    local sbSeat = n(t) == 2 and t.button or nextSeat(t, t.button)
    local bbSeat = nextSeat(t, sbSeat)
    post(t, sbSeat, t.sb)
    post(t, bbSeat, t.bb)
    t.sbSeat, t.bbSeat = sbSeat, bbSeat
    t.curBet, t.minRaise = t.bb, t.bb
    t.street, t.phase, t.toAct = "preflop", "shuffle", nil
end

function PK.hostRoll(t)
    if t.phase == "shuffle" then return 1, PK.SHUFFLE_ROLL end
end
function PK.rangeFor() return nil end

-- The host's shuffle roll. The host deals from it; every other client notes the value it saw,
-- to check against the roll the host reports.
function PK.onRoll(t, name, value, lo, hi)
    if not ns.Rolls.same(name, t.host) or lo ~= 1 or hi ~= PK.SHUFFLE_ROLL then return nil end
    if not t.seed then t.rollSeen = value; return nil end
    if t.phase ~= "shuffle" then return nil end
    t.roll = value
    t.holes, t.fullBoard = PK.deal(t.seed, value, #t.seats, t.button, off(t))
    t.phase = "betting"
    local s = t.bbSeat
    for _ = 1, n(t) do s = nextSeat(t, s); if needsAction(t, s) then t.toAct = s; break end end
    return { kind = "shuffled", value = value }
end

-- What the seat may do right now, or nil. Amounts are copper; raise amounts are "raise to".
function PK.actions(t, seat)
    if t.phase ~= "betting" or not seat or t.toAct ~= seat then return nil end
    local toCall = t.curBet - (t.bet[seat] or 0)
    local maxTo = (t.bet[seat] or 0) + left(t, seat)
    local minTo = math.min(t.curBet + t.minRaise, maxTo)
    return { fold = true, check = toCall == 0, call = toCall > 0 and math.min(toCall, left(t, seat)) or nil,
        raise = maxTo > t.curBet, minTo = minTo, maxTo = maxTo, toCall = toCall }
end

function PK.act(t, seat, action, amount)
    local can = PK.actions(t, seat)
    if not can then return nil end
    if action == "fold" then
        t.inHand[seat] = false
    elseif action == "check" then
        if not can.check then return nil end
    elseif action == "call" then
        if not can.call then return nil end
        post(t, seat, can.call)
    elseif action == "raise" or action == "allin" then
        if not can.raise then return nil end
        local to = action == "allin" and can.maxTo or math.max(can.minTo, math.min(tonumber(amount) or 0, can.maxTo))
        local size = to - t.curBet
        if size >= t.minRaise then
            t.minRaise = size
            t.acted = {}   -- a full raise reopens the betting
        end
        t.curBet = math.max(t.curBet, to)
        post(t, seat, to - (t.bet[seat] or 0))
        amount = to
    else
        return nil
    end
    t.acted[seat] = true
    local ev = { kind = "act", seat = seat, action = action, amount = amount, street = t.street }
    advance(t)
    return ev
end

function PK.forfeit(t, seat)
    if (t.phase ~= "betting" and t.phase ~= "shuffle") or not t.inHand[seat] then return nil end
    t.inHand[seat] = false
    if t.phase == "shuffle" then
        local live = {}
        for s = PK.first(t), #t.seats do if t.inHand[s] then live[#live + 1] = s end end
        if #live == 1 then finish(t, live) end
    elseif t.toAct == seat then advance(t) else
        local live = 0
        for s = PK.first(t), #t.seats do if t.inHand[s] then live = live + 1 end end
        if live == 1 then advance(t) end
    end
    return { kind = "act", seat = seat, action = "fold" }
end

function PK.debts(t)
    if t.phase ~= "done" or not t.net then return {} end
    local net = {}
    for s = PK.first(t), #t.seats do net[t.seats[s]] = t.net[s] end
    return ns.Ledger.settleNet(net)
end

-- private hole cards for each player (host side), once the shuffle roll has dealt them
function PK.privateFor(t)
    if not t.holes then return nil end
    local out = {}
    for s = PK.first(t), #t.seats do out[#out + 1] = { seat = s, payload = t.round .. ";" .. C.pack(t.holes[s]) } end
    return out
end
function PK.onPrivate(t, payload)
    local round, hex = payload:match("^(%d+);(%x+)$")
    if tonumber(round) == t.round then t.myHole = C.unpack(hex) end
end

-- After the seed is revealed: does it match the fingerprint, the roll everyone saw, the board
-- and the shown hands?
function PK.verify(t)
    if t.phase ~= "done" or not t.reveal or not t.roll then return true end
    if C.commit(t.reveal) ~= t.commit then return false, "a deck seed that does not match its fingerprint" end
    if t.rollSeen and t.rollSeen ~= t.roll then return false, "a shuffle roll the server did not give" end
    local holes, board = PK.deal(t.reveal, t.roll, #t.seats, t.button, off(t))
    for i, c in ipairs(t.board or {}) do if board[i] ~= c then return false, "a board card the deck did not deal" end end
    for s, h in pairs(t.shown or {}) do
        if holes[s][1] ~= h[1] or holes[s][2] ~= h[2] then return false, "a shown hand the deck did not deal" end
    end
    if t.myHole and t.mySeat and holes[t.mySeat] and (holes[t.mySeat][1] ~= t.myHole[1] or holes[t.mySeat][2] ~= t.myHole[2]) then
        return false, "hole cards for you the deck did not deal"
    end
    return true
end

function PK.encode(t)
    local seats = {}
    for s = PK.first(t), #t.seats do
        local flags = (t.inHand and t.inHand[s] and "i" or "") .. (t.allin and t.allin[s] and "a" or "") .. (t.acted and t.acted[s] and "c" or "")
        local shown = t.shown and t.shown[s] and C.pack(t.shown[s]) or ""
        seats[#seats + 1] = table.concat({ flags, (t.bet and t.bet[s]) or 0, (t.total and t.total[s]) or 0, shown, t.won and t.won[s] or 0 }, ".")
    end
    return { t.bb, t.sb, t.cap, t.button or 0, t.street or "", t.toAct or 0, t.curBet or 0, t.minRaise or 0,
        t.commit or "", t.reveal or "", C.pack(t.board), table.concat(seats, ","), t.dealerOnly and 1 or 0, t.roll or 0 }
end

function PK.decode(t, f, prev)
    t.bb, t.sb, t.cap, t.button = tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
    t.street = f[5] ~= "" and f[5] or nil
    local ta = tonumber(f[6]); t.toAct = ta ~= 0 and ta or nil
    t.curBet, t.minRaise = tonumber(f[7]), tonumber(f[8])
    t.commit = f[9] ~= "" and f[9] or nil
    t.reveal = f[10] ~= "" and f[10] or nil
    t.board = C.unpack(f[11])
    t.dealerOnly = f[13] == "1"
    local roll = tonumber(f[14]) or 0
    t.roll = roll ~= 0 and roll or nil
    t.inHand, t.allin, t.acted, t.bet, t.total, t.shown, t.won = {}, {}, {}, {}, {}, nil, nil
    local s = PK.first(t)
    for seatStr in ((f[12] or "") .. ","):gmatch("(.-),") do
        local flags, bet, total, shown, won = seatStr:match("^(%a*)%.(%d+)%.(%d+)%.(%x*)%.(%d+)$")
        if flags then
            t.inHand[s], t.allin[s], t.acted[s] = flags:find("i") ~= nil, flags:find("a") ~= nil, flags:find("c") ~= nil
            t.bet[s], t.total[s] = tonumber(bet), tonumber(total)
            if shown ~= "" then t.shown = t.shown or {}; t.shown[s] = C.unpack(shown) end
            if tonumber(won) > 0 or t.phase == "done" then t.won = t.won or {}; t.won[s] = tonumber(won) end
        end
        s = s + 1
    end
    if t.phase == "done" and t.won then
        t.net = {}
        for i = PK.first(t), #t.seats do t.net[i] = (t.won[i] or 0) - (t.total[i] or 0) end
        t.winners = {}
        for i = PK.first(t), #t.seats do if (t.won[i] or 0) > 0 then t.winners[#t.winners + 1] = i end end
        if t.shown then
            t.scores = {}
            for i, h in pairs(t.shown) do
                local cards = { h[1], h[2] }
                for _, c in ipairs(t.board) do cards[#cards + 1] = c end
                t.scores[i] = C.eval(cards)
            end
        end
    end
    -- kept for the hand: my own hole cards (they arrive privately) and the shuffle roll I saw
    if prev and prev.round == t.round then t.myHole, t.rollSeen = prev.myHole, prev.rollSeen end
end
