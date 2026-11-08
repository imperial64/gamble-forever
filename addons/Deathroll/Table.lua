-- Tables over addon messages. The host owns seating and broadcasts the table state; every client
-- applies the server's /roll lines itself with the same rules, so a host cannot invent results.
--
-- Pure apart from hooks Core sets: ns.send(msg), ns.me(), ns.roll(lo, hi), ns.after(sec, fn).
-- ns.emit(what, ...) tells the UI what happened:
--   "enter" "leave" "closed" "state" "lobby" "event"(ev) "settled"(t, debts) "mismatch"(value)
--
-- Message: "1;<tableId>;<seq>;<EVT>;<payload>"
--   OPEN  host -> group   game;wager;maxSeats;chips;seated           (lobby listing)
--   R     host -> group   rosterVersion;part;parts;Full Name,Full Name,...   (seats, in chunks)
--   S     host -> group   table state; names are not in it, only the roster version
--   CLOSE host -> group   table closed
--   SIT / LEAVE  player -> group, acted on by the host
--   WHO   anyone -> group, hosts answer with OPEN
-- Messages are capped at 255 bytes. Full "First Last" names for up to 40 seats travel in the
-- roster, sent only when seating changes; the state goes out at most every BATCH seconds.
local _, ns = ...
local T = { lobby = {} }
ns.Table = T
local VERSION = "2"
local BATCH = .3
local ROSTER_CHUNK = 200

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

local function game(t) return ns.Games[t.game] end

-- state without names
function T.encode(t)
    local f = { t.game, t.wager, t.maxSeats, t.chips and 1 or 0, t.phase, t.round or 0, t.rosterVer or 0 }
    for _, v in ipairs(game(t).encode(t)) do f[#f + 1] = v end
    return table.concat(f, ";")
end

-- seats come from the roster the client already holds; prev is the client's previous state
function T.decode(s, host, seats, prev)
    local f = split(s, ";")
    if #f < 7 or not ns.Games[f[1]] then return nil end
    local t = { game = f[1], wager = tonumber(f[2]), maxSeats = tonumber(f[3]), chips = f[4] == "1", phase = f[5],
        round = tonumber(f[6]), rosterVer = tonumber(f[7]), host = host, seats = {} }
    for i, n in ipairs(seats) do t.seats[i] = n end
    local rest = {}
    for i = 8, #f do rest[#rest + 1] = f[i] end
    game(t).decode(t, rest, prev)
    return t
end

function T.rosterChunks(seats)
    local chunks, cur = {}, {}
    local len = 0
    for _, n in ipairs(seats) do
        if len + #n + 1 > ROSTER_CHUNK and #cur > 0 then chunks[#chunks + 1] = table.concat(cur, ","); cur, len = {}, 0 end
        cur[#cur + 1] = n
        len = len + #n + 1
    end
    chunks[#chunks + 1] = table.concat(cur, ",")
    return chunks
end

local function emit(...) if ns.emit then ns.emit(...) end end
local function seatOf(t, name)
    for i, n in ipairs(t.seats) do if ns.Rolls.same(n, name) then return i end end
end
T.seatOf = seatOf

-- the table I host or sit at: { tid, host, seq, t, hosting, settled = round, roster = { ver, seats } }
function T.current() return T.cur end

---------------------------------------------------------------- host: batched sending

local function sendNow(c)
    local t = c.t
    if c.rosterDirty then
        c.rosterDirty = false
        local chunks = T.rosterChunks(t.seats)
        for i, ch in ipairs(chunks) do
            ns.send(T.pack(c.tid, 0, "R", table.concat({ t.rosterVer, i, #chunks, ch }, ";")))
        end
        ns.send(T.pack(c.tid, 0, "OPEN", table.concat({ t.game, t.wager, t.maxSeats, t.chips and 1 or 0, #t.seats }, ";")))
    end
    c.seq = c.seq + 1
    ns.send(T.pack(c.tid, c.seq, "S", T.encode(t)))
end

local function broadcast(rosterChanged)
    local c = T.cur
    if rosterChanged then
        c.t.rosterVer = (c.t.rosterVer or 0) + 1
        c.rosterDirty = true
    end
    if c.scheduled then return end
    c.scheduled = true
    ns.after(BATCH, function()
        c.scheduled = false
        if T.cur == c then sendNow(c) end
    end)
end

local function announce()
    local c, t = T.cur, T.cur.t
    ns.send(T.pack(c.tid, 0, "OPEN", table.concat({ t.game, t.wager, t.maxSeats, t.chips and 1 or 0, #t.seats }, ";")))
end

-- Settlement fires once per round, whether this client saw the deciding roll or got it from the host.
local function checkSettled(c)
    if c.t.phase == "done" and c.settled ~= c.t.round then
        c.settled = c.t.round
        emit("settled", c.t, game(c.t).debts(c.t))
    end
end

-- Deathroll: the host rolls who goes first
local function hostRolls(c)
    if c.t.game ~= "deathroll" then return end
    ns.after(.8, function()
        if T.cur == c and c.t.phase == "first" then ns.roll(1, #c.t.seats) end
    end)
end

---------------------------------------------------------------- host actions

function T.open(opts)
    local me = ns.me()
    local g = ns.Games[opts.game]
    local t = { game = opts.game, host = me, wager = opts.wager,
        maxSeats = math.max(g.minSeats, math.min(opts.maxSeats or g.maxSeats, g.maxSeats)),
        chips = opts.chips and true or false, seats = { me }, phase = "seating", round = 0, rosterVer = 0 }
    g.setup(t, opts)
    local short = me:match("^[^ %-]+")
    T.cur = { tid = short:sub(1, 6) .. ((opts.stamp or 0) % 100000), host = me, seq = 0, t = t, hosting = true }
    broadcast(true)
    emit("enter")
    emit("state")
end

function T.addBot(name)   -- /dr test: seats whose rolls Core injects
    local c = T.cur
    if not (c and c.hosting and c.t.phase == "seating" and #c.t.seats < c.t.maxSeats) then return end
    c.t.seats[#c.t.seats + 1] = name
    broadcast(true); emit("state")
end

function T.startGame()
    local c = T.cur
    if not (c and c.hosting) then return end
    local t = c.t
    if #t.seats < game(t).minSeats or (t.phase ~= "seating" and t.phase ~= "done") then return end
    game(t).start(t)
    T.seen = {}
    broadcast(); emit("state")
    hostRolls(c)
end

-- High-Low: stop waiting for players who have not rolled
function T.closeRolls()
    local c = T.cur
    if not (c and c.hosting and game(c.t).closeRolls) then return end
    local ev = game(c.t).closeRolls(c.t)
    if ev then emit("event", ev) end
    broadcast(); emit("state")
    checkSettled(c)
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
    T.pending = { tid = tid }
    ns.send(T.pack(tid, 0, "SIT"))
end

function T.who() ns.send(T.pack("x", 0, "WHO")) end

function T.myTurn()
    local c = T.cur
    return c ~= nil and game(c.t).rangeFor(c.t, ns.me()) ~= nil
end

function T.rollMine()
    local c = T.cur
    if not c then return end
    local lo, hi = game(c.t).rangeFor(c.t, ns.me())
    if lo then ns.roll(lo, hi) end
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
            broadcast(true); emit("state")
        else
            c.rosterDirty = true   -- resend the roster so the sender learns where things stand
            broadcast()
        end
    elseif evt == "LEAVE" then
        local seat = seatOf(t, sender)
        if not seat or seat == 1 then return end
        if t.phase == "seating" or t.phase == "done" then
            table.remove(t.seats, seat)
            broadcast(true)
        elseif t.phase == "first" then
            table.remove(t.seats, seat)
            if #t.seats >= game(t).minSeats then game(t).start(t); hostRolls(c) else t.phase = "seating" end
            broadcast(true)
        else
            local ev = game(t).forfeit(t, seat)
            if ev then emit("event", ev) end
            broadcast()
        end
        emit("state")
        checkSettled(c)
    end
end

-- Collect roster chunks; returns the full seat list once every part of a version is in.
local function takeRoster(box, payload)
    local f = split(payload, ";")
    local ver, part, parts = tonumber(f[1]), tonumber(f[2]), tonumber(f[3])
    if not (ver and part and parts) then return end
    if box.building ~= ver then box.building, box.parts = ver, {} end
    box.parts[part] = split(f[4] or "", ",")
    for i = 1, parts do if not box.parts[i] then return end end
    local seats = {}
    for i = 1, parts do for _, n in ipairs(box.parts[i]) do seats[#seats + 1] = n end end
    box.ver, box.seats = ver, seats
    return true
end

local function applyState(c, seq, payload, sender)
    local prev = c.t
    local t = T.decode(payload, sender, c.roster.seats, prev)
    if not t then return end
    c.seq, c.t = seq, t
    if not seatOf(t, ns.me()) then T.cur = nil; emit("leave"); return end
    if prev and prev.round ~= t.round then T.seen = {} end
    -- Deathroll: the host may only report values the server rolled. A state can overtake the
    -- roll line by a moment, so check after a grace period.
    if t.game == "deathroll" then
        local last = t.history[#t.history]
        if last and not (T.seen and T.seen[last]) then
            ns.after(2, function()
                if T.cur == c and not (T.seen and T.seen[last]) then emit("mismatch", last) end
            end)
        end
    end
    emit("state")
    checkSettled(c)
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
        if not ns.Games[f[1] or ""] then return end
        T.lobby[tid] = { tid = tid, host = sender, game = f[1], wager = tonumber(f[2]), maxSeats = tonumber(f[3]),
            chips = f[4] == "1", seated = tonumber(f[5]) or 1, mine = mine }
        emit("lobby")
    elseif evt == "CLOSE" then
        T.lobby[tid] = nil
        emit("lobby")
        if c and c.tid == tid and not c.hosting then T.cur = nil; emit("closed") end
    elseif evt == "R" then
        if mine then return end
        if c and c.tid == tid and ns.Rolls.same(sender, c.host) then
            c.roster = c.roster or {}
            if takeRoster(c.roster, payload) and c.pendingS then
                local p = c.pendingS
                c.pendingS = nil
                if p.ver == c.roster.ver then applyState(c, p.seq, p.payload, sender) end
            end
        elseif T.pending and T.pending.tid == tid and T.lobby[tid] and ns.Rolls.same(sender, T.lobby[tid].host) then
            takeRoster(T.pending, payload)
        end
    elseif evt == "S" then
        if mine then return end
        local ver = tonumber(split(payload, ";")[7])
        if c and c.tid == tid then
            if seq <= c.seq or not ns.Rolls.same(sender, c.host) then return end
            if not (c.roster and c.roster.ver == ver) then
                c.pendingS = { seq = seq, payload = payload, ver = ver }   -- wait for that roster
                return
            end
            applyState(c, seq, payload, sender)
        elseif T.pending and T.pending.tid == tid and T.lobby[tid] and ns.Rolls.same(sender, T.lobby[tid].host)
            and T.pending.ver == ver then
            local roster = { ver = T.pending.ver, seats = T.pending.seats }
            local t = T.decode(payload, sender, roster.seats)
            if t and seatOf(t, ns.me()) then
                T.pending = nil
                T.cur = { tid = tid, host = sender, seq = seq, t = t, hosting = false, settled = t.round, roster = roster }
                T.seen = {}
                emit("enter"); emit("state")
            end
        end
    elseif c and c.hosting and c.tid == tid and not mine then
        hostIntent(c, evt, sender)
    end
end
