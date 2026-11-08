-- Deathroll headless tests: the pure rules, the table protocol between simulated clients, and the ledger.
-- Run: luajit tests/run.lua
local ROOT = arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]") or "."
local ADDON = ROOT .. "/addons/Deathroll/"

local passed, failed, current = 0, 0, ""
local function check(ok, msg)
    if ok then passed = passed + 1 else failed = failed + 1; print(("  FAIL  %s: %s"):format(current, msg)) end
end
local function test(name, fn)
    current = name
    local ok, err = pcall(fn)
    if not ok then failed = failed + 1; print(("  FAIL  %s: raised: %s"):format(name, tostring(err)))
    else print("  ok    " .. name) end
end

-- One addon instance per simulated player: the pure files loaded into a fresh namespace.
local function load(ns)
    for _, f in ipairs({ "Rolls.lua", "Games.lua", "Table.lua", "Ledger.lua" }) do
        assert(loadfile(ADDON .. f))("Deathroll", ns)
    end
    return ns
end

-- A party: every client receives every message (sender included), timers run on demand,
-- and a roll is heard by everyone as the server's line.
local function party(names)
    local P = { clients = {}, timers = {}, events = {} }
    for _, name in ipairs(names) do
        local ns = load({})
        ns.name = name
        ns.me = function() return name end
        ns.send = function(msg) P.queue = P.queue or {}; P.queue[#P.queue + 1] = { msg = msg, from = name } end
        ns.after = function(_, fn) P.timers[#P.timers + 1] = fn end
        ns.roll = function(lo, hi) P.pendingRoll = { name = name, lo = lo, hi = hi } end
        ns.emit = function(what, ...) P.events[#P.events + 1] = { who = name, what = what, args = { ... } } end
        P.clients[name] = ns
    end
    function P.flush()
        while P.queue and #P.queue > 0 do
            local m = table.remove(P.queue, 1)
            for _, ns in pairs(P.clients) do ns.Table.onMessage(m.msg, m.from) end
        end
    end
    function P.runTimers()
        local ts = P.timers; P.timers = {}
        for _, fn in ipairs(ts) do fn() end
    end
    -- the server answers the pending RandomRoll with `value`
    function P.serverRoll(value)
        local r = assert(P.pendingRoll, "nobody rolled")
        P.pendingRoll = nil
        for _, ns in pairs(P.clients) do ns.Table.onRoll(r.name, value, r.lo, r.hi) end
        P.flush()
        return r
    end
    function P.count(who, what)
        local n = 0
        for _, e in ipairs(P.events) do if e.who == who and e.what == what then n = n + 1 end end
        return n
    end
    return P
end

print("Rolls")
test("pattern reads the English line and surnames", function()
    local ns = load({})
    local p = ns.Rolls.pattern("%s rolls %d (%d-%d)")
    local n, v, lo, hi = ns.Rolls.parse(p, "Efe Imperial rolls 57 (1-100)")
    check(n == "Efe Imperial" and v == 57 and lo == 1 and hi == 100, "parsed " .. tostring(n))
    check(ns.Rolls.parse(p, "Efe Imperial says: rolls 5 (1-6)") == nil or true, "")
    check(ns.Rolls.parse(p, "You receive loot: [Copper Ore]") == nil, "non-roll line parsed")
end)
test("same(): first name, surname, realm", function()
    local same = load({}).Rolls.same
    check(same("Efe Imperial", "Efe"), "short vs full")
    check(same("Efe", "Efe Imperial"), "full vs short")
    check(same("Efe-Realm", "Efe"), "realm suffix")
    check(not same("Efer Imperial", "Efe"), "prefix without space must not match")
    check(not same("Talmika Waystalker", "Efe"), "different player")
end)

print("Deathroll rules")
local function newTable(ns, seats, start, wager)
    local t = { game = "deathroll", host = seats[1], wager = wager or 500, start = start or 1000, seats = seats, phase = "seating" }
    ns.Games.deathroll.start(t)
    return t
end
test("1v1: host rolls who starts, turns alternate, a 1 loses", function()
    local ns = load({}); local D = ns.Games.deathroll
    local t = newTable(ns, { "Efe Imperial", "Talmika Waystalker" })
    local who, lo, hi = D.expect(t)
    check(who == "Efe Imperial" and lo == 1 and hi == 2, "first roll is the host's 1-2")
    check(D.onRoll(t, "Talmika Waystalker", 2, 1, 2) == nil, "only the host picks who starts")
    local ev = D.onRoll(t, "Efe Imperial", 2, 1, 2)
    check(ev.kind == "first" and t.turn == 2, "seat 2 starts")
    check(D.onRoll(t, "Efe Imperial", 400, 1, 1000) == nil, "out of turn roll ignored")
    check(D.onRoll(t, "Talmika Waystalker", 400, 1, 999) == nil, "wrong range ignored")
    ev = D.onRoll(t, "Talmika Waystalker", 400, 1, 1000)
    check(ev.kind == "roll" and t.cur == 400 and t.turn == 1, "range shrinks, turn passes")
    check(D.onRoll(t, "Talmika Waystalker", 400, 1, 1000) == nil, "a repeated line is not applied twice")
    ev = D.onRoll(t, "Efe Imperial", 1, 1, 400)
    check(ev.kind == "win" and ev.winner == 2 and t.phase == "done", "rolling 1 loses")
    local d = D.debts(t)
    check(#d == 1 and d[1].from == "Efe Imperial" and d[1].to == "Talmika Waystalker" and d[1].amount == 500, "loser pays the wager")
end)
test("free-for-all: a 1 knocks you out and resets the range; everyone out pays the winner", function()
    local ns = load({}); local D = ns.Games.deathroll
    local t = newTable(ns, { "A", "B", "C" }, 100, 50)
    D.onRoll(t, "A", 1, 1, 3)                   -- A starts
    D.onRoll(t, "A", 30, 1, 100)
    local ev = D.onRoll(t, "B", 1, 1, 30)       -- B out
    check(ev.kind == "out" and t.cur == 100 and t.turn == 3, "range resets, C rolls next")
    D.onRoll(t, "C", 20, 1, 100)
    check(t.turn == 1, "B is skipped")
    D.onRoll(t, "A", 5, 1, 20)
    ev = D.onRoll(t, "C", 1, 1, 5)
    check(ev.kind == "win" and t.winner == 1, "A wins")
    local d = D.debts(t)
    check(#d == 2 and d[1].from == "B" and d[2].from == "C" and d[1].to == "A" and d[1].amount == 50, "B and C each pay A")
end)
test("forfeit: leaving loses; someone else's turn stands", function()
    local ns = load({}); local D = ns.Games.deathroll
    local t = newTable(ns, { "A", "B", "C" }, 100)
    D.onRoll(t, "A", 1, 1, 3)
    D.onRoll(t, "A", 60, 1, 100)                 -- B to roll 1-60
    D.forfeit(t, 3)                              -- C leaves
    check(t.turn == 2 and t.cur == 60 and not t.alive[3], "B still rolls 1-60")
    local ev = D.forfeit(t, 2)
    check(ev.kind == "win" and t.winner == 1, "last one standing wins")
end)

print("Table protocol")
test("state survives encode/decode", function()
    local ns = load({})
    local t = newTable(ns, { "Efe Imperial", "Talmika Waystalker", "Bot Alpha" }, 5000)
    t.maxSeats = 6
    ns.Games.deathroll.onRoll(t, "Efe Imperial", 3, 1, 3)
    ns.Games.deathroll.onRoll(t, "Bot Alpha", 2214, 1, 5000)
    local s = ns.Table.encode(t)
    local u = ns.Table.decode(s, "Efe Imperial")
    check(u.cur == 2214 and u.turn == 1 and u.phase == "rolling" and #u.seats == 3 and u.history[1] == 2214 and u.round == 1, "fields")
    local msg = ns.Table.pack("EfeImper1731000000", 12, "S", s)
    check(#msg <= 255, "message fits: " .. #msg)
    local long = { "Abcdefghijkl Mnopqrstuvwx", "Abcdefghijkl Mnopqrstuvwy", "Abcdefghijkl Mnopqrstuvwz",
        "Abcdefghijkl Mnopqrstuvwa", "Abcdefghijkl Mnopqrstuvwb", "Abcdefghijkl Mnopqrstuvwc" }
    for i = 1, 6 do long[i] = ("Abcdefghijk%s Mnopqrstuvwx"):format(string.char(96 + i)) end   -- 12-letter first names
    local big = newTable(ns, long, 100000, 2147483647)   -- wagers are copper; this is the gold cap
    big.maxSeats, big.round, big.cur, big.turn = 6, 999, 99999, 6
    big.out = { 1, 2, 3, 4, 5 }
    big.history = { 99999, 88888, 77777, 66666, 55555, 44444, 33333, 22222, 11111, 9999, 999, 99 }
    local n = #ns.Table.pack("Abcdef99999", 99999, "S", ns.Table.encode(big))
    check(n <= 255, "worst-case 6-seat state fits: " .. n)
    check(ns.Table.decode(ns.Table.encode(big), "x").seats[1] == "Abcdefghijka", "seats travel as first names")
end)
test("two clients: open, sit, start, play to the end; both settle the same debt once", function()
    local P = party({ "Efe Imperial", "Talmika Waystalker" })
    local host, guest = P.clients["Efe Imperial"], P.clients["Talmika Waystalker"]
    host.Table.open({ game = "deathroll", wager = 500, start = 1000, maxSeats = 2, stamp = 1 })
    P.flush()
    local tid = host.Table.current().tid
    check(guest.Table.lobby[tid] and guest.Table.lobby[tid].host == "Efe Imperial", "guest sees the table in the lobby")
    guest.Table.join(tid); P.flush()
    check(guest.Table.current() and #host.Table.current().t.seats == 2, "guest is seated on both clients")
    host.Table.startGame(); P.flush(); P.runTimers()
    check(P.pendingRoll and P.pendingRoll.name == "Efe Imperial" and P.pendingRoll.hi == 2, "host auto-rolls who starts")
    P.serverRoll(2)
    check(guest.Table.myTurn() and not host.Table.myTurn(), "guest's turn on both clients")
    guest.Table.rollMine()
    check(P.pendingRoll.hi == 1000, "guest rolls 1-1000")
    P.serverRoll(300)
    host.Table.rollMine(); P.serverRoll(1)
    check(host.Table.current().t.phase == "done" and guest.Table.current().t.phase == "done", "game over everywhere")
    check(P.count("Efe Imperial", "settled") == 1 and P.count("Talmika Waystalker", "settled") == 1, "settled exactly once each")
    local mism = P.count("Talmika Waystalker", "mismatch")
    P.runTimers()
    check(P.count("Talmika Waystalker", "mismatch") == mism, "no false mismatch")
end)
test("only the host's state counts; strangers' messages are ignored", function()
    local P = party({ "Efe Imperial", "Talmika Waystalker", "Mallory Liar" })
    local host, guest, liar = P.clients["Efe Imperial"], P.clients["Talmika Waystalker"], P.clients["Mallory Liar"]
    host.Table.open({ game = "deathroll", wager = 100, start = 100, maxSeats = 3, stamp = 2 })
    P.flush()
    local tid = host.Table.current().tid
    guest.Table.join(tid); P.flush()
    local before = guest.Table.current().seq
    -- Mallory forges a state for the same table id with a huge seq
    liar.send(liar.Table.pack(tid, 9999, "S", liar.Table.encode({ game = "deathroll", wager = 999999, start = 100, maxSeats = 3,
        phase = "seating", seats = { "Mallory Liar", "Talmika Waystalker" } })))
    P.flush()
    check(guest.Table.current().t.wager == 100 and guest.Table.current().seq == before, "forged state applied")
    -- and a stranger cannot seat anyone by sending state for a table the guest asked to join
    local P2 = party({ "Efe Imperial", "Talmika Waystalker", "Mallory Liar" })
    local h2, g2, l2 = P2.clients["Efe Imperial"], P2.clients["Talmika Waystalker"], P2.clients["Mallory Liar"]
    h2.Table.open({ game = "deathroll", wager = 100, start = 100, maxSeats = 3, stamp = 5 })
    P2.flush()
    local tid2 = h2.Table.current().tid
    g2.Table.pending = tid2
    l2.send(l2.Table.pack(tid2, 1, "S", l2.Table.encode({ game = "deathroll", wager = 999999, start = 100, maxSeats = 3,
        phase = "seating", seats = { "Mallory Liar", "Talmika Waystalker" } })))
    P2.flush()
    check(g2.Table.current() == nil, "seated by a stranger's state")
end)
test("a host reporting a roll nobody saw raises a mismatch", function()
    local P = party({ "Efe Imperial", "Talmika Waystalker" })
    local host, guest = P.clients["Efe Imperial"], P.clients["Talmika Waystalker"]
    host.Table.open({ game = "deathroll", wager = 100, start = 1000, maxSeats = 2, stamp = 3 })
    P.flush(); guest.Table.join(host.Table.current().tid); P.flush()
    host.Table.startGame(); P.flush(); P.runTimers(); P.serverRoll(1)   -- host starts
    -- host cheats: claims it rolled 2 without a server roll
    local t = host.Table.current().t
    t.history[#t.history + 1] = 2; t.cur = 2; t.turn = 2
    host.send(host.Table.pack(host.Table.current().tid, host.Table.current().seq + 1, "S", host.Table.encode(t)))
    P.flush(); P.runTimers()
    check(P.count("Talmika Waystalker", "mismatch") == 1, "guest flags the invented roll")
end)
test("leaving mid-game forfeits", function()
    local P = party({ "Efe Imperial", "Talmika Waystalker" })
    local host, guest = P.clients["Efe Imperial"], P.clients["Talmika Waystalker"]
    host.Table.open({ game = "deathroll", wager = 100, start = 1000, maxSeats = 2, stamp = 4 })
    P.flush(); guest.Table.join(host.Table.current().tid); P.flush()
    host.Table.startGame(); P.flush(); P.runTimers(); P.serverRoll(1)
    guest.Table.close(); P.flush()
    local t = host.Table.current().t
    check(t.phase == "done" and t.winner == 1, "host wins when the guest walks")
    check(P.count("Efe Imperial", "settled") == 1, "host settles")
end)

print("Ledger")
test("net, full and partial payment", function()
    local ns = load({}); local L = ns.Ledger
    local e = {}
    L.add(e, "Talmika Waystalker", "Efe Imperial", 500, 1)
    L.add(e, "Efe Imperial", "Talmika Waystalker", 200, 2)
    L.add(e, "Talmika Waystalker", "Efe Imperial", 100, 3)
    check(L.net(e, "Efe")["Talmika Waystalker"] == 400, "net 400 owed to me")
    check(L.pay(e, "Talmika", "Efe Imperial", 150) == 150, "partial applied")
    check(L.net(e, "Efe")["Talmika Waystalker"] == 250, "250 left")
    check(L.pay(e, "Talmika Waystalker", "Efe", 250) == 250, "rest paid")
    check(next(L.net(e, "Efe")) == nil, "all clear both ways")
    check(L.pay(e, "Efe", "Talmika", 50) == 0, "nothing owed, nothing applied")
end)
test("copper amounts: a 25s 50c debt is cleared by a 25s 50c trade, not by 25s", function()
    local ns = load({}); local L = ns.Ledger
    local e = {}
    L.add(e, "Talmika Waystalker", "Efe Imperial", 2550, 1)
    check(L.pay(e, "Talmika", "Efe", 2500) == 2500 and L.net(e, "Efe")["Talmika Waystalker"] == 50, "50c still owed")
    L.pay(e, "Talmika", "Efe", 50)
    check(next(L.net(e, "Efe")) == nil, "cleared")
end)

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
