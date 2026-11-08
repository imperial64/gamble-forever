-- Game rules. Pure: no WoW API. Every client runs the same rules on the same server rolls,
-- so they all reach the same result without trusting the host for outcomes.
--
-- A table `t` is plain data:
--   game, host, wager, start, maxSeats, chips, seats = { names }, phase, alive = { bool },
--   cur, turn (seat index), history = { values }, out = { seat order of elimination },
--   winner (seat index), debts = { { from, to, amount } }
-- phase: "seating" -> "first" (host rolls who starts) -> "rolling" -> "done"
local _, ns = ...
local Games = {}
ns.Games = Games

local Deathroll = { name = "Deathroll", minSeats = 2, maxSeats = 6, minStart = 100 }
Games.deathroll = Deathroll

function Deathroll.start(t)
    t.alive, t.out, t.history = {}, {}, {}
    for i = 1, #t.seats do t.alive[i] = true end
    t.phase, t.cur, t.turn, t.winner = "first", t.start, nil, nil
    t.round = (t.round or 0) + 1
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

-- Who must roll next and the exact range, or nil when the table waits for nobody.
function Deathroll.expect(t)
    if t.phase == "first" then return t.host, 1, #t.seats end
    if t.phase == "rolling" then return t.seats[t.turn], 1, t.cur end
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

-- Apply one parsed roll. Returns what happened, or nil when this is not the roll the table is
-- waiting for (wrong player, wrong range, or a line already applied).
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
    -- someone else was mid-turn: their turn and range stand
    if t.phase == "rolling" and turn and turn ~= seat then t.turn, t.cur = turn, cur end
    return ev
end
