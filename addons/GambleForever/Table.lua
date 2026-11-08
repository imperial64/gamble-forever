-- Tables over addon messages. The host owns seating and broadcasts the table state; every client
-- applies the server's /roll lines itself with the same rules, so a host cannot invent results.
--
-- Pure apart from hooks Core sets: ns.send(msg), ns.whisper(name, msg), ns.me(), ns.roll(lo, hi),
-- ns.after(sec, fn), ns.seed(), ns.now() (seconds). ns.emit(what, ...) tells the UI what happened:
--   "enter" "leave" "closed" "state" "lobby" "event"(ev) "settled"(t, debts) "mismatch"(what)
--
-- Message: "2;<tableId>;<seq>;<EVT>;<payload>", at most 255 bytes
--   OPEN  host -> group    game;wager;maxSeats;chips;seated            (lobby listing)
--   R     host -> group    rosterVersion;part;parts;Full Name,...        (seats, in chunks)
--   S     host -> group    part;parts;state chunk                        (state, in chunks)
--   P     host -> one      private game data (poker hole cards), by whisper
--   CLOSE host -> group    table closed
--   SIT / LEAVE / ACT      player -> group, acted on by the host (ACT = action;amount)
--   READY                  player -> group, agrees to the next round (Coinflip rematch)
--   WHO   anyone -> group  hosts answer with OPEN
local _, ns = ...
local T = { lobby = {} }
ns.Table = T
local VERSION = "2"
local BATCH = .3
local CHUNK = 200
T.RULES_COOLDOWN = 60   -- seconds between "rules" answers in chat

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

function T.chunks(s, size)
    local out = {}
    for i = 1, math.max(1, #s), size do out[#out + 1] = s:sub(i, i + size - 1) end
    return out
end

function T.rosterChunks(seats)
    local chunks, cur = {}, {}
    local len = 0
    for _, n in ipairs(seats) do
        if len + #n + 1 > CHUNK and #cur > 0 then chunks[#chunks + 1] = table.concat(cur, ","); cur, len = {}, 0 end
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
    local parts = T.chunks(T.encode(t), CHUNK)
    for i, p in ipairs(parts) do ns.send(T.pack(c.tid, c.seq, "S", i .. ";" .. #parts .. ";" .. p)) end
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
        if game(c.t).verify then
            c.t.mySeat = seatOf(c.t, ns.me())
            local ok, what = game(c.t).verify(c.t)
            if not ok then emit("mismatch", what) end
        end
        emit("settled", c.t, game(c.t).debts(c.t))
    end
end

-- Rolls the host's addon makes on its own (who goes first, coin flips, dealing cards). A roll the
-- server never answers is retried.
local function hostAuto(c)
    local g = game(c.t)
    if not g.hostRoll then return end
    local lo, hi = g.hostRoll(c.t)
    if not lo then return end
    local key = table.concat({ c.t.round or 0, c.t.phase, c.t.draws or 0, hi }, ":")
    if c.autoKey == key then return end
    c.autoKey = key
    ns.after(.6, function()
        if T.cur ~= c then return end
        local lo2, hi2 = g.hostRoll(c.t)
        if lo2 == lo and hi2 == hi and c.autoKey == key then
            ns.roll(lo, hi)
            ns.after(4, function()
                if T.cur == c and c.autoKey == key then c.autoKey = nil; hostAuto(c) end
            end)
        end
    end)
end

-- Private game data (poker hole cards), once per round as soon as the game has it: by addon
-- whisper to addon players, in plain words to chat players.
local function sendPrivate(c)
    local t = c.t
    local list = game(t).privateFor and c.privRound ~= t.round and game(t).privateFor(t)
    if not list then return end
    c.privRound = t.round
    for _, p in ipairs(list) do
        local name = t.seats[p.seat]
        if ns.Rolls.same(name, ns.me()) then game(t).onPrivate(t, p.payload)
        else
            if not (ns.bots and ns.bots[name]) then ns.whisper(name, T.pack(c.tid, 0, "P", p.payload)) end
            if c.chatters[name] then ns.sayTo(name, ns.Chat.holeLine(t, p.seat)) end
        end
    end
end

local function hostChanged(c, ev, rosterChanged)
    sendPrivate(c)
    if ev then emit("event", ev) end
    broadcast(rosterChanged)
    emit("state")
    checkSettled(c)
    hostAuto(c)
    if c.chat then ns.Chat.hostChanged(c, ev) end
end

---------------------------------------------------------------- host actions

function T.open(opts)
    local me = ns.me()
    local g = ns.Games[opts.game]
    -- chat players get their poker cards as whispers the host can read: the host only deals
    if opts.chat and opts.game == "poker" then opts.dealerOnly = true end
    local t = { game = opts.game, host = me, wager = opts.wager,
        maxSeats = math.max(g.minSeats, math.min(opts.maxSeats or g.maxSeats, g.maxSeats)),
        chips = opts.chips and true or false, seats = { me }, phase = "seating", round = 0, rosterVer = 0 }
    g.setup(t, opts)
    local short = me:match("^[^ %-]+")
    -- chatters: seats taken by typing "join" in party/raid chat (Chat.lua narrates for them)
    -- ready: players who agreed to the next round (games with needsReady)
    T.cur = { tid = short:sub(1, 6) .. ((opts.stamp or 0) % 100000), host = me, seq = 0, t = t, hosting = true,
        chat = opts.chat and true or false, chatters = {}, ready = {} }
    broadcast(true)
    emit("enter")
    emit("state")
    if T.cur.chat then ns.Chat.hostChanged(T.cur) end
end

-- /gf test: seats Core plays for; asChatter makes the narrator treat the bot as a chat player
function T.addBot(name, asChatter)
    local c = T.cur
    if not (c and c.hosting and c.t.phase == "seating" and #c.t.seats < c.t.maxSeats) then return end
    c.t.seats[#c.t.seats + 1] = name
    if asChatter then c.chatters[name] = true end
    broadcast(true); emit("state")
end

-- Host: may the next round start? false and the names still to say ready (needsReady games).
function T.canStart()
    local c = T.cur
    if not (c and c.hosting) then return false, {} end
    local t = c.t
    if t.phase ~= "seating" and t.phase ~= "done" then return false, {} end
    if #t.seats < game(t).minSeats + (t.dealerOnly and 1 or 0) then return false, {} end
    local waiting = {}
    if game(t).needsReady then
        for i = 2, #t.seats do
            local name = t.seats[i]
            if not (c.ready[name] or (ns.bots and ns.bots[name])) then waiting[#waiting + 1] = name end
        end
    end
    return #waiting == 0, waiting
end

function T.startGame()
    local c = T.cur
    if not T.canStart() then return end
    local t = c.t
    game(t).start(t, ns.seed and ns.seed() or tostring(t.round))
    c.ready = {}
    T.seen = {}
    hostChanged(c)
end

-- A player agrees to the next round (Coinflip rematch). Sitting down counts for the first.
local function markReady(c, name)
    local t = c.t
    if c.ready[name] or t.phase ~= "done" or not seatOf(t, name) then return end
    c.ready[name] = true
    if c.chat then ns.say(("[GF] %s is ready."):format(name:match("^[^ %-]+"))) end
    emit("state")
end

function T.ready()
    local c = T.cur
    if not c or c.hosting or c.readyRound == c.t.round then return end
    c.readyRound = c.t.round
    ns.send(T.pack(c.tid, 0, "READY"))
    emit("state")
end

-- A guest: have I said ready for the round that just ended?
function T.amReady()
    local c = T.cur
    return c ~= nil and c.readyRound == c.t.round
end

-- High-Low: stop waiting for players who have not rolled
function T.closeRolls()
    local c = T.cur
    if not (c and c.hosting and game(c.t).closeRolls) then return end
    hostChanged(c, game(c.t).closeRolls(c.t))
end

-- the host applies a player's action (or its own, or a bot's)
function T.hostAct(seat, action, amount)
    local c = T.cur
    if not (c and c.hosting and game(c.t).act) then return end
    local ev = game(c.t).act(c.t, seat, action, amount)
    if ev then hostChanged(c, ev) end
end

function T.close()
    local c = T.cur
    if not c then return end
    if c.hosting then
        ns.send(T.pack(c.tid, c.seq + 1, "CLOSE"))
        if c.chat then ns.say(nil, "prompt"); ns.say("[GF] Table closed. Thanks for playing.") end
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

function T.mySeat()
    local c = T.cur
    return c and seatOf(c.t, ns.me())
end

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

-- what I may do right now (card games), or nil
function T.myActions()
    local c = T.cur
    if not c or not game(c.t).actions then return nil end
    return game(c.t).actions(c.t, T.mySeat())
end

function T.act(action, amount)
    local c = T.cur
    if not c then return end
    if c.hosting then T.hostAct(T.mySeat(), action, amount)
    else ns.send(T.pack(c.tid, 0, "ACT", action .. ";" .. (amount or 0))) end
end

---------------------------------------------------------------- rolls (everyone)

function T.onRoll(name, value, lo, hi)
    local c = T.cur
    if not c then return end
    local ev = game(c.t).onRoll(c.t, name, value, lo, hi)
    if not ev then return end
    T.seen = T.seen or {}
    T.seen[value] = true
    if c.hosting then hostChanged(c, ev) else emit("event", ev); emit("state"); checkSettled(c) end
end

---------------------------------------------------------------- messages

local function hostIntent(c, evt, sender, payload)
    local t = c.t
    if evt == "SIT" then
        -- before the first start, or between rounds (the next Start or Rematch deals them in)
        if (t.phase == "seating" or t.phase == "done") and #t.seats < t.maxSeats and not seatOf(t, sender) then
            t.seats[#t.seats + 1] = sender
            c.ready[sender] = true
            hostChanged(c, nil, true)
        else
            c.rosterDirty = true   -- resend the roster so the sender learns where things stand
            broadcast()
        end
    elseif evt == "LEAVE" then
        local seat = seatOf(t, sender)
        if not seat or seat == 1 then return end
        if t.phase == "seating" or t.phase == "done" then
            table.remove(t.seats, seat)
            hostChanged(c, nil, true)
        elseif t.game == "deathroll" and t.phase == "first" then
            table.remove(t.seats, seat)
            if #t.seats >= game(t).minSeats then game(t).start(t) else t.phase = "seating" end
            hostChanged(c, nil, true)
        else
            hostChanged(c, game(t).forfeit(t, seat))
        end
    elseif evt == "ACT" then
        local seat = seatOf(t, sender)
        local f = split(payload, ";")
        if seat then T.hostAct(seat, f[1], tonumber(f[2])) end
    elseif evt == "READY" then
        markReady(c, sender)
    end
end

-- Collect roster chunks; true once every part of a version is in.
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

-- Collect state chunks of one seq; returns the whole state once complete.
local function takeState(box, seq, payload)
    local part, parts, data = payload:match("^(%d+);(%d+);(.*)$")
    part, parts = tonumber(part), tonumber(parts)
    if not part then return end
    if box.stateSeq ~= seq then box.stateSeq, box.stateParts = seq, {} end
    box.stateParts[part] = data
    for i = 1, parts do if not box.stateParts[i] then return end end
    return table.concat(box.stateParts)
end

local function applyState(c, seq, state, sender)
    local prev = c.t
    local t = T.decode(state, sender, c.roster.seats, prev)
    if not t then return end
    local problem = game(t).check and game(t).check(prev, t)
    c.seq, c.t = seq, t
    if c.private and game(t).onPrivate then game(t).onPrivate(t, c.private) end
    if problem then emit("mismatch", problem) end
    if not seatOf(t, ns.me()) then T.cur = nil; emit("leave"); return end
    if prev and prev.round ~= t.round then T.seen = {} end
    -- Deathroll: the host may only report values the server rolled. A state can overtake the
    -- roll line by a moment, so check after a grace period.
    if t.game == "deathroll" then
        local last = t.history[#t.history]
        if last and not (T.seen and T.seen[last]) then
            ns.after(2, function()
                if T.cur == c and not (T.seen and T.seen[last]) then emit("mismatch", "a roll of " .. last .. " that nobody saw") end
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
                if p.ver == c.roster.ver then applyState(c, p.seq, p.state, sender) end
            end
        elseif T.pending and T.pending.tid == tid and T.lobby[tid] and ns.Rolls.same(sender, T.lobby[tid].host) then
            takeRoster(T.pending, payload)
        end
    elseif evt == "S" then
        if mine then return end
        if c and c.tid == tid then
            if seq <= c.seq or not ns.Rolls.same(sender, c.host) then return end
            local state = takeState(c, seq, payload)
            if not state then return end
            local ver = tonumber(split(state, ";")[7])
            if not (c.roster and c.roster.ver == ver) then
                c.pendingS = { seq = seq, state = state, ver = ver }   -- wait for that roster
                return
            end
            applyState(c, seq, state, sender)
        elseif T.pending and T.pending.tid == tid and T.lobby[tid] and ns.Rolls.same(sender, T.lobby[tid].host) then
            local state = takeState(T.pending, seq, payload)
            if not state or T.pending.ver ~= tonumber(split(state, ";")[7]) then return end
            local roster = { ver = T.pending.ver, seats = T.pending.seats }
            local t = T.decode(state, sender, roster.seats)
            if t and seatOf(t, ns.me()) then
                T.pending = nil
                T.cur = { tid = tid, host = sender, seq = seq, t = t, hosting = false, settled = t.round, roster = roster }
                T.seen = {}
                emit("enter"); emit("state")
            end
        end
    elseif evt == "P" then
        if c and c.tid == tid and ns.Rolls.same(sender, c.host) and game(c.t).onPrivate then
            c.private = payload   -- may arrive before the new hand's state; re-applied with each state
            game(c.t).onPrivate(c.t, payload)
            emit("state")
        end
    elseif c and c.hosting and c.tid == tid and not mine then
        hostIntent(c, evt, sender, payload)
    end
end

-- A party or raid line from someone, maybe without the addon. Only the host acts on it, and
-- only on a whole-message command (Chat.parse).
function T.chatCommand(sender, text)
    local c = T.cur
    if not (c and c.hosting and c.chat) or ns.Rolls.same(sender, ns.me()) then return end
    local action, amount = ns.Chat.parse(text)
    if not action then return end
    local t = c.t
    if action == "join" then
        if seatOf(t, sender) then return end
        local between = t.phase == "seating" or t.phase == "done"
        if not between or #t.seats >= t.maxSeats then
            ns.say(("[GF] %s, %s."):format(sender:match("^[^ %-]+"),
                between and "the table is full" or "a round is on; type join again when it ends"))
            return
        end
        c.chatters[sender] = true
        hostIntent(c, "SIT", sender)
    elseif action == "leave" then
        hostIntent(c, "LEAVE", sender)
    elseif action == "ready" then
        markReady(c, sender)
    elseif action == "rules" then
        -- anyone may ask, once a minute per table, so it cannot flood the channel
        local now = ns.now()
        if c.rulesAt and now - c.rulesAt < T.RULES_COOLDOWN then return end
        c.rulesAt = now
        for _, l in ipairs(ns.Chat.fit(ns.Chat.rulesLine(t))) do ns.say(l) end
    else
        local seat = seatOf(t, sender)
        if seat then T.hostAct(seat, action, amount) end
    end
end
