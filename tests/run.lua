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

-- A party: every client receives every message (sender included) in order, timers run on
-- flush, and a roll is heard by everyone as the server's line.
local function party(names)
    local P = { clients = {}, timers = {}, events = {}, queue = {}, sent = {} }
    for _, name in ipairs(names) do
        local ns = load({})
        ns.me = function() return name end
        ns.send = function(msg)
            assert(#msg <= 255, "message over 255 bytes: " .. #msg)
            P.queue[#P.queue + 1] = { msg = msg, from = name }
            P.sent[#P.sent + 1] = msg
        end
        ns.after = function(_, fn) P.timers[#P.timers + 1] = fn end
        ns.roll = function(lo, hi) P.pendingRoll = { name = name, lo = lo, hi = hi } end
        ns.emit = function(what, ...) P.events[#P.events + 1] = { who = name, what = what, args = { ... } } end
        P.clients[name] = ns
    end
    function P.flush()
        for _ = 1, 100 do
            if #P.queue == 0 and #P.timers == 0 then return end
            local ts = P.timers; P.timers = {}
            for _, fn in ipairs(ts) do fn() end
            while #P.queue > 0 do
                local m = table.remove(P.queue, 1)
                for _, ns in pairs(P.clients) do ns.Table.onMessage(m.msg, m.from) end
            end
        end
        error("flush did not settle")
    end
    -- the server answers a RandomRoll; everyone in the group reads the line
    function P.roll(name, value, lo, hi)
        for _, ns in pairs(P.clients) do ns.Table.onRoll(name, value, lo, hi) end
    end
    function P.serverRoll(value)
        local r = assert(P.pendingRoll, "nobody rolled")
        P.pendingRoll = nil
        P.roll(r.name, value, r.lo, r.hi)
        P.flush()
        return r
    end
    function P.count(who, what)
        local n = 0
        for _, e in ipairs(P.events) do if e.who == who and e.what == what then n = n + 1 end end
        return n
    end
    function P.last(who, what)
        for i = #P.events, 1, -1 do local e = P.events[i]; if e.who == who and e.what == what then return e end end
    end
    return P
end

print("Rolls")
test("pattern reads the English line and surnames", function()
    local ns = load({})
    local p = ns.Rolls.pattern("%s rolls %d (%d-%d)")
    local n, v, lo, hi = ns.Rolls.parse(p, "Efe Imperial rolls 57 (1-100)")
    check(n == "Efe Imperial" and v == 57 and lo == 1 and hi == 100, "parsed " .. tostring(n))
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
local function newDeathroll(ns, seats, start, wager)
    local t = { game = "deathroll", host = seats[1], wager = wager or 500, seats = seats, phase = "seating" }
    ns.Games.deathroll.setup(t, { start = start or 1000 })
    ns.Games.deathroll.start(t)
    return t
end
test("1v1: host rolls who starts, turns alternate, a 1 loses", function()
    local ns = load({}); local D = ns.Games.deathroll
    local t = newDeathroll(ns, { "Efe Imperial", "Talmika Waystalker" })
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
    local t = newDeathroll(ns, { "A", "B", "C" }, 100, 50)
    D.onRoll(t, "A", 1, 1, 3)
    D.onRoll(t, "A", 30, 1, 100)
    local ev = D.onRoll(t, "B", 1, 1, 30)
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
    local t = newDeathroll(ns, { "A", "B", "C" }, 100)
    D.onRoll(t, "A", 1, 1, 3)
    D.onRoll(t, "A", 60, 1, 100)
    D.forfeit(t, 3)
    check(t.turn == 2 and t.cur == 60 and not t.alive[3], "B still rolls 1-60")
    local ev = D.forfeit(t, 2)
    check(ev.kind == "win" and t.winner == 1, "last one standing wins")
end)

print("High-Low rules")
local function newHighLow(ns, seats, wager)
    local t = { game = "highlow", host = seats[1], wager = wager, seats = seats, phase = "seating" }
    ns.Games.highlow.setup(t)
    ns.Games.highlow.start(t)
    return t
end
test("rolls in copper; the range is the wager; above the roll cap it switches to silver", function()
    local H = load({}).Games.highlow
    check(H.unitFor(15000) == 1, "1g 50s rolls in copper")
    check(H.unitFor(H.ROLL_MAX) == 1, "exactly at the cap stays copper")
    check(H.unitFor(5000000) == 100, "500g rolls in silver")
    check(H.unitFor(2147483647) == 10000, "the gold cap rolls in gold")
end)
test("lowest pays highest the difference in copper", function()
    local ns = load({}); local H = ns.Games.highlow
    local t = newHighLow(ns, { "A", "B", "C" }, 15000)
    check(t.range == 15000 and t.unit == 1, "range 1-15000")
    check(H.onRoll(t, "A", 14200, 1, 14999) == nil, "wrong range ignored")
    H.onRoll(t, "A", 14200, 1, 15000)
    check(H.onRoll(t, "A", 99, 1, 15000) == nil, "one roll each")
    H.onRoll(t, "B", 3100, 1, 15000)
    local ev = H.onRoll(t, "C", 8000, 1, 15000)
    check(ev.next and ev.next.kind == "result" and t.phase == "done", "resolved once everyone rolled")
    local d = H.debts(t)
    check(#d == 1 and d[1].from == "B" and d[1].to == "A" and d[1].amount == 11100, "B pays A 1g 11s")
end)
test("silver tables pay in silver", function()
    local ns = load({}); local H = ns.Games.highlow
    local t = newHighLow(ns, { "A", "B" }, 5000000)
    check(t.range == 50000 and t.unit == 100, "range 1-50000 silver")
    H.onRoll(t, "A", 40000, 1, 50000)
    H.onRoll(t, "B", 10000, 1, 50000)
    check(H.debts(t)[1].amount == 30000 * 100, "300g")
end)
test("ties roll off among the tied, keeping the original difference", function()
    local ns = load({}); local H = ns.Games.highlow
    local t = newHighLow(ns, { "A", "B", "C", "D" }, 1000)
    H.onRoll(t, "A", 900, 1, 1000); H.onRoll(t, "B", 900, 1, 1000)
    H.onRoll(t, "C", 100, 1, 1000)
    local ev = H.onRoll(t, "D", 100, 1, 1000)
    check(ev.next.kind == "tie" and ev.next.side == "hi" and t.phase == "tie", "high tie first")
    check(H.rangeFor(t, "C") == nil and H.rangeFor(t, "A") == 1, "only the tied roll")
    H.onRoll(t, "A", 50, 1, 1000)
    ev = H.onRoll(t, "B", 70, 1, 1000)
    check(ev.next.kind == "tie" and ev.next.side == "lo" and t.hiSeat == 2, "B wins high; now the low tie")
    H.onRoll(t, "C", 300, 1, 1000)
    ev = H.onRoll(t, "D", 200, 1, 1000)
    check(ev.next.kind == "result" and t.loSeat == 4, "D loses the low roll-off")
    local d = H.debts(t)
    check(d[1].from == "D" and d[1].to == "B" and d[1].amount == 800, "pays the original 900 - 100")
end)
test("everyone equal is a push; a no-show can be closed out", function()
    local ns = load({}); local H = ns.Games.highlow
    local t = newHighLow(ns, { "A", "B" }, 100)
    H.onRoll(t, "A", 50, 1, 100); H.onRoll(t, "B", 50, 1, 100)
    check(t.phase == "done" and #H.debts(t) == 0, "push")
    t = newHighLow(ns, { "A", "B", "C" }, 100)
    H.onRoll(t, "A", 80, 1, 100); H.onRoll(t, "B", 20, 1, 100)
    check(t.phase == "rolling", "waiting on C")
    H.closeRolls(t)
    check(t.phase == "done" and H.debts(t)[1].amount == 60, "C left out, B pays A 60")
end)

print("Table protocol")
test("full names travel in a chunked roster; 40 seats fit", function()
    local ns = load({})
    local seats = {}
    for i = 1, 40 do seats[i] = ("Abcdefghijk%s Mnopqrstuvw%s"):format(string.char(96 + i % 26), string.char(96 + i % 7)) end
    local chunks = ns.Table.rosterChunks(seats)
    local back = {}
    for _, ch in ipairs(chunks) do
        local msg = ns.Table.pack("Abcdef99999", 0, "R", table.concat({ 99, 1, #chunks, ch }, ";"))
        check(#msg <= 255, "roster chunk fits: " .. #msg)
        for n in ch:gmatch("[^,]+") do back[#back + 1] = n end
    end
    check(#back == 40 and back[40] == seats[40], "roster round-trips")
    local t = newHighLow(ns, seats, 2147483647)
    t.maxSeats, t.rosterVer = 40, 99
    for i = 1, 40 do t.rolls[i] = 999999 end
    local s = ns.Table.encode(t)
    check(#ns.Table.pack("Abcdef99999", 99999, "S", s) <= 255, "40-seat High-Low state fits: " .. #s)
    local d = newDeathroll(ns, { seats[1], seats[2], seats[3], seats[4], seats[5], seats[6] }, 100000, 2147483647)
    d.maxSeats, d.round, d.out = 6, 999, { 1, 2, 3, 4, 5 }
    d.history = { 99999, 88888, 77777, 66666, 55555, 44444, 33333, 22222, 11111 }
    check(#ns.Table.pack("Abcdef99999", 99999, "S", ns.Table.encode(d)) <= 255, "6-seat Deathroll state fits")
    local u = ns.Table.decode(ns.Table.encode(d), "x", d.seats)
    check(u.seats[2] == seats[2] and u.history[1] == 88888 and u.start == 100000, "decode keeps full names and fields")
end)

local function seated(names, opts)
    local P = party(names)
    local host = P.clients[names[1]]
    host.Table.open(opts)
    P.flush()
    local tid = host.Table.current().tid
    for i = 2, #names do P.clients[names[i]].Table.join(tid) end
    P.flush()
    return P, host, tid
end

test("two clients play Deathroll to the end; both settle once; full names everywhere", function()
    local P, host, tid = seated({ "Efe Imperial", "Talmika Waystalker" }, { game = "deathroll", wager = 500, start = 1000, maxSeats = 2, stamp = 1 })
    local guest = P.clients["Talmika Waystalker"]
    check(guest.Table.lobby[tid] and guest.Table.lobby[tid].host == "Efe Imperial", "guest saw the table in the lobby")
    check(guest.Table.current() and guest.Table.current().t.seats[1] == "Efe Imperial", "guest sees the host's full name")
    host.Table.startGame(); P.flush()
    check(P.pendingRoll and P.pendingRoll.name == "Efe Imperial" and P.pendingRoll.hi == 2, "host auto-rolls who starts")
    P.serverRoll(2)
    check(guest.Table.myTurn() and not host.Table.myTurn(), "guest's turn on both clients")
    guest.Table.rollMine(); P.serverRoll(300)
    host.Table.rollMine(); P.serverRoll(1)
    check(host.Table.current().t.phase == "done" and guest.Table.current().t.phase == "done", "game over everywhere")
    check(P.count("Efe Imperial", "settled") == 1 and P.count("Talmika Waystalker", "settled") == 1, "settled exactly once each")
    local d = P.last("Talmika Waystalker", "settled").args[2]
    check(d[1].from == "Efe Imperial" and d[1].to == "Talmika Waystalker", "debt uses full names")
    check(P.count("Talmika Waystalker", "mismatch") == 0, "no false mismatch")
end)
test("only the host's state counts; strangers cannot seat anyone", function()
    local P, host, tid = seated({ "Efe Imperial", "Talmika Waystalker", "Mallory Liar" }, { game = "deathroll", wager = 100, start = 100, maxSeats = 2, stamp = 2 })
    local guest, liar = P.clients["Talmika Waystalker"], P.clients["Mallory Liar"]
    check(liar.Table.current() == nil, "third player was not seated in a 2-seat table")
    local before = guest.Table.current().seq
    local fake = { game = "deathroll", wager = 999999, maxSeats = 2, phase = "seating", rosterVer = 1, seats = { "Mallory Liar", "Talmika Waystalker" } }
    liar.Games.deathroll.setup(fake, { start = 100 })
    liar.send(liar.Table.pack(tid, 9999, "S", liar.Table.encode(fake)))
    liar.send(liar.Table.pack(tid, 0, "R", "1;1;1;Mallory Liar,Talmika Waystalker"))
    P.flush()
    check(guest.Table.current().t.wager == 100 and guest.Table.current().seq == before, "forged state applied")
end)
test("a host reporting a roll nobody saw raises a mismatch", function()
    local P, host = seated({ "Efe Imperial", "Talmika Waystalker" }, { game = "deathroll", wager = 100, start = 1000, maxSeats = 2, stamp = 3 })
    host.Table.startGame(); P.flush(); P.serverRoll(1)
    local c = host.Table.current()
    c.t.history[#c.t.history + 1] = 2; c.t.cur = 2; c.t.turn = 2
    host.send(host.Table.pack(c.tid, c.seq + 1, "S", host.Table.encode(c.t)))
    P.flush()
    check(P.count("Talmika Waystalker", "mismatch") == 1, "guest flags the invented roll")
end)
test("leaving mid-game forfeits", function()
    local P, host = seated({ "Efe Imperial", "Talmika Waystalker" }, { game = "deathroll", wager = 100, start = 1000, maxSeats = 2, stamp = 4 })
    host.Table.startGame(); P.flush(); P.serverRoll(1)
    P.clients["Talmika Waystalker"].Table.close(); P.flush()
    local t = host.Table.current().t
    check(t.phase == "done" and t.winner == 1, "host wins when the guest walks")
end)
test("High-Low with three clients; a guest that gets the state before a roll line still fills it in", function()
    local P, host = seated({ "Efe Imperial", "Talmika Waystalker", "Nox Aeterna" }, { game = "highlow", wager = 15000, maxSeats = 10, stamp = 5 })
    local nox = P.clients["Nox Aeterna"]
    check(nox.Table.current() and #host.Table.current().t.seats == 3, "three seated")
    host.Table.startGame(); P.flush()
    check(nox.Table.myTurn() and host.Table.myTurn(), "everyone may roll at once")
    -- Efe's line reaches the host and Talmika, but Nox only hears about it from the host's state
    for _, n in ipairs({ "Efe Imperial", "Talmika Waystalker" }) do P.clients[n].Table.onRoll("Efe Imperial", 14200, 1, 15000) end
    P.flush()
    check(nox.Table.current().t.rolls[1] == true, "Nox knows Efe rolled, not the value")
    nox.Table.onRoll("Efe Imperial", 14200, 1, 15000)
    check(nox.Table.current().t.rolls[1] == 14200, "the late line fills the value")
    P.roll("Talmika Waystalker", 3100, 1, 15000)
    P.roll("Nox Aeterna", 8000, 1, 15000)
    P.flush()
    for name, ns in pairs(P.clients) do
        check(ns.Table.current().t.phase == "done", name .. " sees the result")
        local d = P.last(name, "settled").args[2]
        check(d[1].from == "Talmika Waystalker" and d[1].to == "Efe Imperial" and d[1].amount == 11100, name .. " settles 1g 11s")
    end
end)
test("40 players can sit at a High-Low table; every message fits", function()
    local names = { "Host Person" }
    for i = 2, 40 do names[i] = ("Player%02d Longsurname"):format(i) end
    local P, host = seated(names, { game = "highlow", wager = 1000000, maxSeats = 40, stamp = 6 })
    check(#host.Table.current().t.seats == 40, "40 seated")
    check(P.clients[names[40]].Table.current().t.seats[40] == names[40], "last player sees the full roster")
    host.Table.startGame(); P.flush()
    for i = 1, 40 do P.roll(names[i], i * 1000, 1, 1000000) end
    P.flush()
    local d = P.last(names[2], "settled").args[2]
    check(d[1].from == "Host Person" and d[1].to == names[40] and d[1].amount == 39000, "1 pays 40 the difference")
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
