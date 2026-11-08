-- Tables over addon messages. The host owns seating and broadcasts the table state; every client
-- applies the server's /roll lines itself with the same rules, so a host cannot invent results.
--
-- Pure apart from hooks Core sets: ns.send(msg), ns.me(), ns.roll(lo, hi), ns.after(sec, fn).
-- ns.emit(what, ...) tells the UI what happened:
--   "enter" "leave" "closed" "state" "lobby" "event"(ev) "settled"(t, debts) "mismatch"(value)
--
-- Message: "1;<tableId>;<seq>;<EVT>;<payload>"
--   OPEN  host -> group   game;wager;start;maxSeats;chips;seated     (lobby listing)
--   S     host -> group   full table state (see encode)
--   CLOSE host -> group   table closed
--   SIT / LEAVE  player -> group, acted on by the host
--   WHO   anyone -> group, hosts answer with OPEN
local _, ns = ...
local T = { lobby = {} }
ns.Table = T
local VERSION = "1"

local function split(s, sep)
    local out = {}
    if s == nil or s == "" then return out end
    for p in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = p end
    return out
end
T.split = split

function T.pack(tid, seq, evt, payload)
    return VERSION .. ";" .. tid .. ";" .. seq .. ";" .. evt .. (payload and (";" .. payload) or "")
end

function T.unpack(msg)
    local v, tid, seq, evt, rest = msg:match("^(%d+);([^;]+);(%d+);(%u+);?(.*)$")
    if v ~= VERSION then return nil end
    return tid, tonumber(seq), evt, rest
end

local HISTORY_SENT = 8    -- with first-name seats a worst-case 6-seat state stays under 255 bytes (tested)

-- Seats travel as first names: six "First Lastname" seats would not fit in 255 bytes, and
-- Rolls.same() matches a first name against the full name on every roll line.
local function short(n) return n:match("^[^ %-]+") end

function T.encode(t)
    local alive, hist, seats = {}, {}, {}
    for i = 1, #t.seats do
        alive[i] = (t.alive and t.alive[i] == false) and "0" or "1"
        seats[i] = short(t.seats[i])
    end
    local h = t.history or {}
    for i = math.max(1, #h - HISTORY_SENT + 1), #h do hist[#hist + 1] = h[i] end
    return table.concat({ t.game, t.wager, t.start, t.maxSeats, t.chips and 1 or 0, t.phase,
        t.cur or 0, t.turn or 0, t.winner or 0, table.concat(seats, ","), table.concat(alive),
        table.concat(hist, ","), t.round or 0, table.concat(t.out or {}, ",") }, ";")
end

function T.decode(s, host)
    local f = split(s, ";")
    if #f < 14 then return nil end
    local t = { game = f[1], wager = tonumber(f[2]), start = tonumber(f[3]), maxSeats = tonumber(f[4]),
        chips = f[5] == "1", phase = f[6], cur = tonumber(f[7]), host = host, seats = split(f[10], ","),
        alive = {}, history = {}, out = {}, round = tonumber(f[13]) }
    local turn, winner = tonumber(f[8]), tonumber(f[9])
    t.turn = turn ~= 0 and turn or nil
    t.winner = winner ~= 0 and winner or nil
    for i = 1, #t.seats do t.alive[i] = f[11]:sub(i, i) ~= "0" end
    for _, v in ipairs(split(f[12], ",")) do t.history[#t.history + 1] = tonumber(v) end
    for _, v in ipairs(split(f[14], ",")) do t.out[#t.out + 1] = tonumber(v) end
    if not ns.Games[t.game] then return nil end
    return t
end

local function emit(...) if ns.emit then ns.emit(...) end end
local function game(t) return ns.Games[t.game] end
local function seatOf(t, name)
    for i, n in ipairs(t.seats) do if ns.Rolls.same(n, name) then return i end end
end
T.seatOf = seatOf

-- the table I host or sit at: { tid, host, seq, t, hosting, settled = round }
function T.current() return T.cur end

local function broadcast()
    local c = T.cur
    c.seq = c.seq + 1
    ns.send(T.pack(c.tid, c.seq, "S", T.encode(c.t)))
end

local function announce()
    local c, t = T.cur, T.cur.t
    ns.send(T.pack(c.tid, 0, "OPEN", table.concat({ t.game, t.wager, t.start, t.maxSeats, t.chips and 1 or 0, #t.seats }, ";")))
end

-- Settlement fires once per round, whether this client saw the deciding roll or got it from the host.
local function checkSettled(c)
    if c.t.phase == "done" and c.settled ~= c.t.round then
        c.settled = c.t.round
        emit("settled", c.t, game(c.t).debts(c.t))
    end
end

local function hostRollsFirst(c)
    ns.after(.8, function()
        if T.cur == c and c.t.phase == "first" then ns.roll(1, #c.t.seats) end
    end)
end

---------------------------------------------------------------- host actions

function T.open(opts)
    local me = ns.me()
    local g = ns.Games[opts.game]
    local t = { game = opts.game, host = me, wager = opts.wager,
        start = math.max(opts.start or opts.wager, g.minStart or 1),
        maxSeats = math.min(opts.maxSeats or g.maxSeats, g.maxSeats), chips = opts.chips and true or false,
        seats = { me }, phase = "seating", history = {}, out = {}, round = 0 }
    T.cur = { tid = short(me):sub(1, 6) .. ((opts.stamp or 0) % 100000), host = me, seq = 0, t = t, hosting = true }
    announce()
    broadcast()
    emit("enter")
    emit("state")
end

function T.addBot(name)   -- /dr test: seats whose rolls Core injects
    local c = T.cur
    if not (c and c.hosting and c.t.phase == "seating" and #c.t.seats < c.t.maxSeats) then return end
    c.t.seats[#c.t.seats + 1] = name
    broadcast(); emit("state")
end

function T.startGame()
    local c = T.cur
    if not (c and c.hosting) then return end
    local t = c.t
    if #t.seats < game(t).minSeats or (t.phase ~= "seating" and t.phase ~= "done") then return end
    game(t).start(t)
    T.seen = {}
    broadcast(); emit("state")
    hostRollsFirst(c)
end

function T.close()
    local c = T.cur
    if not c then return end
    if c.hosting then
        ns.send(T.pack(c.tid, c.seq + 1, "CLOSE"))
    else
        ns.send(T.pack(c.tid, 0, "LEAVE"))
    end
    T.cur = nil
    emit("leave")
end

---------------------------------------------------------------- player actions

function T.join(tid)
    T.pending = tid
    ns.send(T.pack(tid, 0, "SIT"))
end

function T.who() ns.send(T.pack("x", 0, "WHO")) end

function T.myTurn()
    local c = T.cur
    if not c or c.t.phase ~= "rolling" then return false end
    local who = game(c.t).expect(c.t)
    return who ~= nil and ns.Rolls.same(who, ns.me())
end

function T.rollMine()
    if not T.myTurn() then return end
    local _, lo, hi = game(T.cur.t).expect(T.cur.t)
    ns.roll(lo, hi)
end

---------------------------------------------------------------- rolls (everyone)

function T.onRoll(name, value, lo, hi)
    local c = T.cur
    if not c then return end
    local ev = game(c.t).onRoll(c.t, name, value, lo, hi)
    if not ev then return end
    T.seen = T.seen or {}
    T.seen[value] = true
    emit("event", ev)
    if c.hosting then broadcast() end
    emit("state")
    checkSettled(c)
end

---------------------------------------------------------------- messages

local function hostIntent(c, evt, sender)
    local t = c.t
    if evt == "SIT" then
        if t.phase == "seating" and #t.seats < t.maxSeats and not seatOf(t, sender) then
            t.seats[#t.seats + 1] = sender
            emit("state")
        end
        broadcast()   -- also tells a refused player where things stand
    elseif evt == "LEAVE" then
        local seat = seatOf(t, sender)
        if not seat or seat == 1 then return end
        if t.phase == "rolling" then
            local ev = game(t).forfeit(t, seat)
            if ev then emit("event", ev) end
        else
            table.remove(t.seats, seat)
            if t.phase == "first" then
                if #t.seats >= game(t).minSeats then game(t).start(t); hostRollsFirst(c) else t.phase = "seating" end
            end
        end
        broadcast(); emit("state")
        checkSettled(c)
    end
end

function T.onMessage(msg, sender)
    local tid, seq, evt, payload = T.unpack(msg)
    if not tid then return end
    local c = T.cur
    local mine = ns.Rolls.same(sender, ns.me())

    if evt == "WHO" then
        if c and c.hosting then announce() end
    elseif evt == "OPEN" then
        local f = split(payload, ";")
        T.lobby[tid] = { tid = tid, host = sender, game = f[1], wager = tonumber(f[2]), start = tonumber(f[3]),
            maxSeats = tonumber(f[4]), chips = f[5] == "1", seated = tonumber(f[6]) or 1, mine = mine }
        emit("lobby")
    elseif evt == "CLOSE" then
        T.lobby[tid] = nil
        emit("lobby")
        if c and c.tid == tid and not c.hosting then T.cur = nil; emit("closed") end
    elseif evt == "S" then
        if mine then return end   -- my own broadcast echoing back
        local t = T.decode(payload, sender)
        if not t then return end
        local entry = T.lobby[tid]
        if entry then entry.seated = #t.seats; emit("lobby") end
        if c and c.tid == tid then
            if seq <= c.seq or not ns.Rolls.same(sender, c.host) then return end
            c.seq, c.t = seq, t
            if not seatOf(t, ns.me()) then T.cur = nil; emit("leave"); return end
            if t.phase == "first" then T.seen = {} end
            -- The host may only report values the server rolled. A state can overtake the roll
            -- line by a moment, so check after a grace period.
            local last = t.history[#t.history]
            if last and not (T.seen and T.seen[last]) then
                ns.after(2, function()
                    if T.cur == c and not (T.seen and T.seen[last]) then emit("mismatch", last) end
                end)
            end
            emit("state")
            checkSettled(c)
        elseif T.pending == tid and seatOf(t, ns.me()) and T.lobby[tid] and ns.Rolls.same(sender, T.lobby[tid].host) then
            T.pending = nil
            T.cur = { tid = tid, host = sender, seq = seq, t = t, hosting = false, settled = t.round }
            T.seen = {}
            emit("enter"); emit("state")
        end
    elseif c and c.hosting and c.tid == tid and not mine then
        hostIntent(c, evt, sender)
    end
end
