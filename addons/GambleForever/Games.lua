-- Game rules. Pure: no WoW API. Every client runs the same rules on the same server rolls,
-- so they all reach the same result without trusting the host for outcomes.
--
-- Common table fields: game, host, wager (copper), maxSeats, chips, seats = { full names },
-- phase ("seating" -> game phases -> "done"), round. Each game adds its own fields and says how
-- they travel in a state message (encode returns a list of strings, decode reads them back).
local _, ns = ...
local Games = {}
ns.Games = Games

local function bits(list, n, test)
    local s = {}
    for i = 1, n do s[i] = test(list, i) and "1" or "0" end
    return table.concat(s)
end
local function unbits(s, n)
    local out = {}
    for i = 1, n do out[i] = s:sub(i, i) == "1" end
    return out
end
local function csv(list) return table.concat(list or {}, ",") end
local function uncsv(s)
    local out = {}
    for v in (s or ""):gmatch("[^,]+") do out[#out + 1] = tonumber(v) end
    return out
end
local function seatOf(t, name)
    for i, n in ipairs(t.seats) do if ns.Rolls.same(n, name) then return i end end
end

---------------------------------------------------------------- Deathroll

local Deathroll = { name = "Deathroll", minSeats = 2, maxSeats = 6, minStart = 100 }
Games.deathroll = Deathroll

function Deathroll.setup(t, opts)
    t.start = math.max(opts.start or 1000, Deathroll.minStart)
end

function Deathroll.start(t)
    t.alive, t.out, t.history = {}, {}, {}
    for i = 1, #t.seats do t.alive[i] = true end
    t.phase, t.cur, t.turn, t.winner = "first", t.start, nil, nil
    t.round = (t.round or 0) + 1
end

-- Who must roll next and the exact range, or nil when the table waits for nobody.
function Deathroll.expect(t)
    if t.phase == "first" then return t.host, 1, #t.seats end
    if t.phase == "rolling" then return t.seats[t.turn], 1, t.cur end
end

-- Rolls the host's addon makes on its own: who goes first.
function Deathroll.hostRoll(t)
    if t.phase == "first" then return 1, #t.seats end
end

-- The range `name` may roll right now, or nil.
function Deathroll.rangeFor(t, name)
    local who, lo, hi = Deathroll.expect(t)
    if who and ns.Rolls.same(who, name) and t.phase == "rolling" then return lo, hi end
end

local function nextAlive(t, from)
    local n = #t.seats
    for k = 1, n do
        local j = (from + k - 1) % n + 1
        if t.alive[j] then return j end
    end
end

local function eliminate(t, seat)
    t.alive[seat] = false
    t.out[#t.out + 1] = seat
    local left
    for i = 1, #t.seats do
        if t.alive[i] then
            if left then left = false; break end
            left = i
        end
    end
    if left then
        t.phase, t.winner, t.turn = "done", left, nil
        return { kind = "win", seat = seat, winner = left }
    end
    t.cur = t.start            -- free-for-all: the range resets for the next player
    t.turn = nextAlive(t, seat)
    return { kind = "out", seat = seat }
end

function Deathroll.onRoll(t, name, value, lo, hi)
    local who, elo, ehi = Deathroll.expect(t)
    if not who or not ns.Rolls.same(name, who) or lo ~= elo or hi ~= ehi then return nil end
    if t.phase == "first" then
        t.phase, t.turn = "rolling", value
        return { kind = "first", seat = value }
    end
    local seat = t.turn
    t.history[#t.history + 1] = value
    if value > 1 then
        t.cur, t.turn = value, nextAlive(t, seat)
        return { kind = "roll", seat = seat, value = value }
    end
    return eliminate(t, seat)
end

-- Leaving mid-game counts as rolling a 1.
function Deathroll.forfeit(t, seat)
    if t.phase ~= "rolling" or not t.alive[seat] then return nil end
    local turn, cur = t.turn, t.cur
    local ev = eliminate(t, seat)
    if t.phase == "rolling" and turn and turn ~= seat then t.turn, t.cur = turn, cur end
    return ev
end

-- Everyone knocked out pays the last player standing the wager.
function Deathroll.debts(t)
    local d = {}
    if t.phase ~= "done" or not t.winner then return d end
    for _, s in ipairs(t.out) do
        d[#d + 1] = { from = t.seats[s], to = t.seats[t.winner], amount = t.wager }
    end
    return d
end

local HISTORY_SENT = 8
function Deathroll.encode(t)
    local h, hist = t.history or {}, {}
    for i = math.max(1, #h - HISTORY_SENT + 1), #h do hist[#hist + 1] = h[i] end
    return { t.start, t.cur or 0, t.turn or 0, t.winner or 0,
        bits(t.alive or {}, #t.seats, function(a, i) return a[i] ~= false end), csv(hist), csv(t.out) }
end
function Deathroll.decode(t, f)
    t.start, t.cur = tonumber(f[1]), tonumber(f[2])
    local turn, winner = tonumber(f[3]), tonumber(f[4])
    t.turn, t.winner = turn ~= 0 and turn or nil, winner ~= 0 and winner or nil
    t.alive = unbits(f[5] or "", #t.seats)
    t.history, t.out = uncsv(f[6]), uncsv(f[7])
end

---------------------------------------------------------------- High-Low

-- Everyone rolls 1 to the wager at once; the lowest roller pays the highest the difference.
-- The range is the wager in copper. /roll tops out at ROLL_MAX, so bigger wagers roll in
-- silver (or gold) instead: `unit` is the copper value of one point on the die.
local HighLow = { name = "High-Low", minSeats = 2, maxSeats = 40 }
Games.highlow = HighLow
HighLow.ROLL_MAX = 1000000   -- ponytail: believed /roll cap; measure in game and adjust

function HighLow.unitFor(wager)
    local unit = 1
    while math.ceil(wager / unit) > HighLow.ROLL_MAX do unit = unit * 100 end
    return unit
end

function HighLow.setup(t)
    t.unit = HighLow.unitFor(t.wager)
    t.range = math.max(2, math.ceil(t.wager / t.unit))
end

function HighLow.start(t)
    t.phase, t.rolls, t.round = "rolling", {}, (t.round or 0) + 1
    t.hiCands, t.loCands, t.hiSeat, t.loSeat, t.diff = nil, nil, nil, nil, nil
    t.tieSide, t.tieSeats, t.tieRolls, t.left = nil, nil, nil, nil
end

-- Seats still to roll in the current step (everyone, or the tied players).
local function waitingOn(t)
    local out = {}
    if t.phase == "rolling" then
        for i = 1, #t.seats do if not t.rolls[i] and not (t.left and t.left[i]) then out[#out + 1] = i end end
    elseif t.phase == "tie" then
        for _, s in ipairs(t.tieSeats) do if not t.tieRolls[s] then out[#out + 1] = s end end
    end
    return out
end
HighLow.waitingOn = waitingOn

function HighLow.rangeFor(t, name)
    local seat = seatOf(t, name)
    if not seat then return nil end
    for _, s in ipairs(waitingOn(t)) do if s == seat then return 1, t.range end end
end

local function extremes(seats, values, wantHigh)
    local best, list
    for _, s in ipairs(seats) do
        local v = values[s]
        if v then
            if not best or (wantHigh and v > best) or (not wantHigh and v < best) then best, list = v, { s }
            elseif v == best then list[#list + 1] = s end
        end
    end
    return best, list or {}
end

-- Resolve whatever can be resolved: the high side first, then the low side, rolling off ties.
local function settleNext(t)
    for _, side in ipairs({ "hi", "lo" }) do
        if not t[side .. "Seat"] then
            local cands = t[side .. "Cands"]
            if #cands == 1 then
                t[side .. "Seat"] = cands[1]
            else
                t.phase, t.tieSide, t.tieSeats, t.tieRolls = "tie", side, cands, {}
                return { kind = "tie", side = side, seats = cands }
            end
        end
    end
    t.phase, t.tieSide, t.tieSeats, t.tieRolls = "done", nil, nil, nil
    return { kind = "result", hi = t.hiSeat, lo = t.loSeat, diff = t.diff }
end

local function resolveMain(t)
    local seats = {}
    for i = 1, #t.seats do if t.rolls[i] then seats[#seats + 1] = i end end
    local hiV, hiC = extremes(seats, t.rolls, true)
    local loV, loC = extremes(seats, t.rolls, false)
    if #seats < 2 or hiV == loV then
        t.phase, t.diff = "done", 0
        return { kind = "push" }
    end
    t.diff, t.hiCands, t.loCands = hiV - loV, hiC, loC
    return settleNext(t)
end

local function resolveTie(t)
    local side = t.tieSide
    local _, cands = extremes(t.tieSeats, t.tieRolls, side == "hi")
    t[side .. "Cands"] = cands
    return settleNext(t)
end

-- A client that got the host's state before a roll line knows only that the seat rolled
-- (value `true`). The line then fills the value in without resolving anything twice.
local function allKnown(values)
    for _, v in pairs(values) do if v == true then return false end end
    return true
end

function HighLow.onRoll(t, name, value, lo, hi)
    local seat = seatOf(t, name)
    if not seat or lo ~= 1 or hi ~= t.range then return nil end
    local book = t.phase == "tie" and t.tieRolls or t.phase == "rolling" and t.rolls or nil
    if book and book[seat] == true then
        book[seat] = value
        return { kind = "roll", seat = seat, value = value, late = true }
    end
    if not HighLow.rangeFor(t, name) then return nil end
    book[seat] = value
    local ev = { kind = "roll", seat = seat, value = value, tie = t.phase == "tie" }
    -- resolve only when every value is known here; otherwise the host's state brings the result
    if #waitingOn(t) == 0 and allKnown(book) then
        ev.next = t.phase == "rolling" and resolveMain(t) or resolveTie(t)
    end
    return ev
end

-- Host closes the step: players who did not roll are left out of the main roll, and in a
-- roll-off they lose it (dropped from a high tie, made the loser of a low tie).
function HighLow.closeRolls(t)
    if t.phase == "rolling" then return resolveMain(t) end
    if t.phase == "tie" then
        if t.tieSide == "lo" then
            for _, s in ipairs(t.tieSeats) do if not t.tieRolls[s] then t.tieRolls[s] = 0 end end
        end
        return resolveTie(t)
    end
end

-- Leaving mid-round: you are out of the main roll; in a roll-off you lose it.
function HighLow.forfeit(t, seat)
    if t.phase == "rolling" then
        t.rolls[seat] = nil
        t.left = t.left or {}
        t.left[seat] = true
        if #waitingOn(t) == 0 then return resolveMain(t) end
    elseif t.phase == "tie" then
        if t.tieSide == "lo" then t.tieRolls[seat] = 0 else t.tieRolls[seat] = -1 end
        if #waitingOn(t) == 0 then return resolveTie(t) end
    end
end

function HighLow.debts(t)
    if t.phase ~= "done" or not t.hiSeat or not t.loSeat or (t.diff or 0) <= 0 then return {} end
    return { { from = t.seats[t.loSeat], to = t.seats[t.hiSeat], amount = t.diff * t.unit } }
end

-- Roll values do not travel (40 of them would not fit); each client reads them from the roll
-- lines. The state carries who has rolled and the host's result.
function HighLow.encode(t)
    local n = #t.seats
    return { t.range, t.unit, t.hiSeat or 0, t.loSeat or 0, t.diff or 0, t.tieSide or "",
        bits(t.rolls or {}, n, function(r, i) return r[i] ~= nil end),
        bits(t.tieSeats or {}, n, function(ts, i) for _, s in ipairs(ts) do if s == i then return true end end end),
        bits(t.tieRolls or {}, n, function(r, i) return r[i] ~= nil end),
        bits(t.left or {}, n, function(l, i) return l[i] end) }
end
function HighLow.decode(t, f, prev)
    local n = #t.seats
    t.range, t.unit = tonumber(f[1]), tonumber(f[2])
    local hi, lo, diff = tonumber(f[3]), tonumber(f[4]), tonumber(f[5])
    t.hiSeat, t.loSeat = hi ~= 0 and hi or nil, lo ~= 0 and lo or nil
    t.diff = (t.phase == "done" or t.phase == "tie" or diff ~= 0) and diff or nil
    t.tieSide = f[6] ~= "" and f[6] or nil
    -- keep the values this client read itself; take "has rolled" from the host
    local same = prev and prev.round == t.round
    local rolled, tied, tieRolled = unbits(f[7] or "", n), unbits(f[8] or "", n), unbits(f[9] or "", n)
    t.rolls, t.tieRolls, t.tieSeats, t.left = {}, {}, nil, nil
    local left = unbits(f[10] or "", n)
    for i = 1, n do
        if left[i] then t.left = t.left or {}; t.left[i] = true end
        if rolled[i] then t.rolls[i] = same and prev.rolls and prev.rolls[i] or true end
        if tieRolled[i] then t.tieRolls[i] = same and prev.tieRolls and prev.tieRolls[i] or true end
        if tied[i] then t.tieSeats = t.tieSeats or {}; t.tieSeats[#t.tieSeats + 1] = i end
    end
end

---------------------------------------------------------------- Coinflip

-- Two seats: seat 1 is heads (1), seat 2 is tails (2). The host's addon flips with /roll 1-2;
-- the server decides, so the host flipping cannot favour anyone.
local Coinflip = { name = "Coinflip", minSeats = 2, maxSeats = 2 }
Games.coinflip = Coinflip

function Coinflip.setup() end
function Coinflip.start(t)
    t.phase, t.result, t.winner, t.round = "flip", nil, nil, (t.round or 0) + 1
end
function Coinflip.hostRoll(t)
    if t.phase == "flip" then return 1, 2 end
end
function Coinflip.rangeFor() return nil end
function Coinflip.onRoll(t, name, value, lo, hi)
    if t.phase ~= "flip" or not ns.Rolls.same(name, t.host) or lo ~= 1 or hi ~= 2 then return nil end
    t.result, t.winner, t.phase = value, value, "done"
    return { kind = "flip", value = value, winner = value }
end
function Coinflip.forfeit(t, seat)
    if t.phase ~= "flip" then return nil end
    t.winner, t.phase = 3 - seat, "done"
    return { kind = "flip", winner = t.winner }
end
function Coinflip.debts(t)
    if t.phase ~= "done" or not t.winner then return {} end
    return { { from = t.seats[3 - t.winner], to = t.seats[t.winner], amount = t.wager } }
end
function Coinflip.encode(t) return { t.result or 0, t.winner or 0 } end
function Coinflip.decode(t, f)
    local r, w = tonumber(f[1]), tonumber(f[2])
    t.result, t.winner = r ~= 0 and r or nil, w ~= 0 and w or nil
end
