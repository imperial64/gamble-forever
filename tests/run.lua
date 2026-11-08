-- Deathroll headless tests: the pure rules, the table protocol between simulated clients, and the ledger.
-- Run: luajit tests/run.lua
local ROOT = arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]") or "."
local ADDON = ROOT .. "/addons/GambleForever/"

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
    for _, f in ipairs({ "Rolls.lua", "Cards.lua", "Games.lua", "Blackjack.lua", "Poker.lua", "Chat.lua", "Table.lua", "Ledger.lua" }) do
        assert(loadfile(ADDON .. f))("GambleForever", ns)
    end
    return ns
end

-- A party: every client receives every message (sender included) in order, timers run on
-- flush, and a roll is heard by everyone as the server's line.
local function party(names)
    local P = { clients = {}, timers = {}, slow = {}, events = {}, queue = {}, sent = {} }
    for _, name in ipairs(names) do
        local ns = load({})
        ns.me = function() return name end
        ns.send = function(msg)
            assert(#msg <= 255, "message over 255 bytes: " .. #msg)
            P.queue[#P.queue + 1] = { msg = msg, from = name }
            P.sent[#P.sent + 1] = msg
        end
        ns.whisper = function(target, msg)
            assert(#msg <= 255, "whisper over 255 bytes: " .. #msg)
            P.queue[#P.queue + 1] = { msg = msg, from = name, to = target }
        end
        P.seedN = 0
        ns.seed = function() P.seedN = P.seedN + 1; return "seed" .. P.seedN end
        -- flush runs short timers at once; long ones (the host's 4 s roll retry) wait for runSlow
        ns.after = function(sec, fn)
            if sec >= 3 then P.slow[#P.slow + 1] = fn else P.timers[#P.timers + 1] = fn end
        end
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
                for name, ns in pairs(P.clients) do
                    if not m.to or name == m.to then ns.Table.onMessage(m.msg, m.from) end
                end
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
    liar.send(liar.Table.pack(tid, 9999, "S", "1;1;" .. liar.Table.encode(fake)))
    liar.send(liar.Table.pack(tid, 0, "R", "1;1;1;Mallory Liar,Talmika Waystalker"))
    P.flush()
    check(guest.Table.current().t.wager == 100 and guest.Table.current().seq == before, "forged state applied")
end)
test("a host reporting a roll nobody saw raises a mismatch", function()
    local P, host = seated({ "Efe Imperial", "Talmika Waystalker" }, { game = "deathroll", wager = 100, start = 1000, maxSeats = 2, stamp = 3 })
    host.Table.startGame(); P.flush(); P.serverRoll(1)
    local c = host.Table.current()
    c.t.history[#c.t.history + 1] = 2; c.t.cur = 2; c.t.turn = 2
    host.send(host.Table.pack(c.tid, c.seq + 1, "S", "1;1;" .. host.Table.encode(c.t)))
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

print("Cards")
test("a shoe hands out the n-th remaining card and never the same card twice", function()
    local C = load({}).Cards
    local shoe = C.newShoe(1)
    check(C.draw(shoe, 1) == 0 and shoe.left == 51, "first card of a fresh deck is 2 of hearts")
    check(C.draw(shoe, 1) == 1, "the next first card is the 3 of hearts")
    check(C.draw(shoe, 50) == 51 and shoe.left == 49, "the last card is the ace of spades")
    check(C.draw(shoe, 50) == nil, "beyond the cards left is refused")
    local seen = {}
    while shoe.left > 0 do
        local c = C.draw(shoe, math.floor(shoe.left / 2) + 1)
        check(not seen[c], "duplicate card " .. tostring(c))
        seen[c] = true
    end
    local six = C.newShoe(6)
    for _ = 1, 100 do C.draw(six, 7) end
    local back = C.unpackShoe(C.packShoe(six))
    check(back.left == 212 and C.packShoe(back) == C.packShoe(six), "six-deck shoe round-trips")
end)
test("seeded shuffle is a fixed permutation; the fingerprint changes with the seed", function()
    local C = load({}).Cards
    local a, b = C.shuffle("x1"), C.shuffle("x1")
    local seen, same = {}, true
    for i = 1, 52 do seen[a[i]] = true; if a[i] ~= b[i] then same = false end end
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    check(same and count == 52, "same seed, same deck, all 52 cards")
    check(C.commit("x1") ~= C.commit("x2") and #C.commit("x1") == 16, "fingerprints differ")
end)
test("hand ranking", function()
    local C = load({}).Cards
    local function h(spec)   -- "As Kd 10c ..."
        local out = {}
        local V = { A = 14, K = 13, Q = 12, J = 11 }
        local S = { h = 1, d = 2, c = 3, s = 4 }
        for r, s in spec:gmatch("(%w-)([hdcs])%f[%s%z]") do out[#out + 1] = C.make(V[r] or tonumber(r), S[s]) end
        return C.eval(out)
    end
    check(C.handName(h("As Ks Qs Js 10s 2d 3c")) == "Royal flush", "royal")
    check(h("Ah 2d 3c 4s 5h 9d Kc")[1] == 5 and h("Ah 2d 3c 4s 5h 9d Kc")[2] == 5, "wheel is a 5-high straight")
    check(C.cmp(h("Kh Kd Kc 2s 2h 9d 8c"), h("Ah Qh 9h 4h 2h Kd 3c")) == 1, "full house beats flush")
    check(C.cmp(h("Ah Ad Kc Ks 9d 3c 2h"), h("Ah Ad Kc Ks 8d 3c 2h")) == 1, "two pair, kicker decides")
    check(C.cmp(h("Ah Ad Kc Ks Qd Qc 2h"), h("Ah Ad Kc Ks Jd 3c 2h")) == 1, "three pairs: best two plus the third as kicker")
    check(h("7h 7d 7c 7s 2d 3c Kh")[3] == 13, "quads with king kicker")
    check(C.cmp(h("9h 8h 7h 6h 5h 2d 2c"), h("Ah Ad Ac As Kd 3c 2h")) == 1, "straight flush beats quads")
end)

print("Coinflip")
test("the host's addon flips; the loser pays the wager", function()
    local P, host = seated({ "Efe Imperial", "Talmika Waystalker" }, { game = "coinflip", wager = 1234, stamp = 7 })
    host.Table.startGame(); P.flush()
    check(P.pendingRoll and P.pendingRoll.name == "Efe Imperial" and P.pendingRoll.hi == 2, "host flips 1-2")
    P.serverRoll(2)
    local d = P.last("Talmika Waystalker", "settled").args[2]
    check(d[1].from == "Efe Imperial" and d[1].to == "Talmika Waystalker" and d[1].amount == 1234, "tails wins")
end)

print("Blackjack")
-- deal by naming the card each roll must produce; the test finds the roll value for it
local function rollFor(ns, card)
    local shoe = ns.Table.current().t.shoe
    local n = 0
    for i = 1, shoe.decks * 52 do
        if not shoe.removed[i] then
            n = n + 1
            if (i - 1) % 52 == card then return n end
        end
    end
end
local function dealCards(P, host, cards)
    local C = host.Cards
    for _, spec in ipairs(cards) do
        P.flush()
        assert(P.pendingRoll, "dealer did not roll for " .. spec)
        local v, s = spec:match("^(%w-)([hdcs])$")
        local V = { A = 14, K = 13, Q = 12, J = 11 }
        local card = C.make(V[v] or tonumber(v), ({ h = 1, d = 2, c = 3, s = 4 })[s])
        P.serverRoll(rollFor(host, card))
    end
    P.flush()
end
test("a full hand: deal, hit, stand, the dealer draws to 17; the shoe keeps count", function()
    local P, host = seated({ "Dealer Person", "Efe Imperial", "Talmika Waystalker" }, { game = "blackjack", wager = 1000, maxSeats = 6, stamp = 8 })
    local efe, tal = P.clients["Efe Imperial"], P.clients["Talmika Waystalker"]
    host.Table.startGame()
    -- order: Efe, Talmika, dealer upcard, Efe, Talmika (no hole card)
    dealCards(P, host, { "10h", "9c", "6d", "6s", "Kd" })
    local t = efe.Table.current().t
    check(t.phase == "playing" and t.turn[1] == 2, "Efe to act on 16")
    check(t.shoe.left == 312 - 5, "five cards out of the shoe on every client")
    check(efe.Table.myActions() and efe.Table.myActions().hit and not tal.Table.myActions(), "only Efe may act")
    efe.Table.act("hit"); dealCards(P, host, { "4c" })   -- 20, auto-stands? no: 20 waits
    check(efe.Table.current().t.turn[1] == 2, "Efe still to act on 20")
    efe.Table.act("stand"); P.flush()
    check(tal.Table.myActions() ~= nil, "Talmika's turn")
    tal.Table.act("stand"); P.flush()
    dealCards(P, host, { "5h", "Qs" })   -- dealer 6+5 = 11, +10 = 21
    local d = P.last("Efe Imperial", "settled").args[2]
    check(#d == 2 and d[1].from == "Efe Imperial" and d[1].to == "Dealer Person" and d[1].amount == 1000, "Efe's 20 loses to 21")
    check(d[2].from == "Talmika Waystalker" and d[2].amount == 1000, "Talmika's 19 loses")
    check(P.count("Talmika Waystalker", "mismatch") == 0, "honest dealer, no mismatch")
end)
test("blackjack pays 3:2, a split plays two hands, a double takes one card", function()
    local P, host = seated({ "Dealer Person", "Efe Imperial", "Talmika Waystalker" }, { game = "blackjack", wager = 1000, maxSeats = 6, stamp = 9 })
    local efe, tal = P.clients["Efe Imperial"], P.clients["Talmika Waystalker"]
    host.Table.startGame()
    dealCards(P, host, { "Ah", "8c", "9d", "Kh", "8d" })   -- Efe blackjack, Talmika 8 8, dealer 9
    check(tal.Table.myActions().split, "Talmika may split eights")
    tal.Table.act("split"); dealCards(P, host, { "2h", "3c" })   -- 8+2, 8+3
    tal.Table.act("double"); dealCards(P, host, { "Kc" })        -- 20, doubled
    check(tal.Table.current().t.turn[2] == 2, "second split hand")
    tal.Table.act("stand"); P.flush()
    dealCards(P, host, { "7h", "Ad" })                           -- dealer 9+7 = 16, +A = 17
    local t = host.Table.current().t
    check(t.results[2] == 1500, "blackjack pays 1.5x")
    check(t.results[3] == 2000 - 1000, "doubled 20 wins 2x, 11 loses 1x")
end)
test("a dealer that reports a card the roll did not draw is caught", function()
    local P, host = seated({ "Dealer Person", "Efe Imperial" }, { game = "blackjack", wager = 100, maxSeats = 6, stamp = 10 })
    host.Table.startGame()
    dealCards(P, host, { "10h", "6d", "6s" })
    local c = host.Table.current()
    -- the dealer swaps Efe's 6 for an ace without a roll, then sends that state
    local fake = c.t.hands[2][1].cards
    fake[2] = host.Cards.make(14, 1)
    c.t.shoe.removed[1] = true
    host.send(host.Table.pack(c.tid, c.seq + 1, "S", "1;1;" .. host.Table.encode(c.t)))
    P.flush()
    check(P.count("Efe Imperial", "mismatch") >= 1, "Efe's addon flags it")
end)

test("practice table: the house deals and the host plays a hand too", function()
    local P = party({ "Efe Imperial" })
    local host = P.clients["Efe Imperial"]
    host.Table.open({ game = "blackjack", wager = 100, maxSeats = 6, chips = true, practice = true, stamp = 15 })
    host.Table.addBot("Grizzlenut Sparkfuse")
    P.flush()
    host.Table.startGame()
    dealCards(P, host, { "10h", "9c", "6d", "7s", "8d" })   -- Efe 17, bot 17, dealer 6
    check(host.Table.myActions() ~= nil, "the host has a hand to play")
    host.Table.act("stand"); P.flush()
    host.Table.hostAct(2, "stand"); P.flush()
    dealCards(P, host, { "Kh" })   -- dealer 16, draws again
    dealCards(P, host, { "5c" })   -- 21
    local t = host.Table.current().t
    check(t.phase == "done" and t.results[1] == -100 and t.results[2] == -100, "both 17s lose to 21")
    check(#host.Games.blackjack.debts(t) == 1, "only the bot's hand makes a debt; the house never owes itself")
end)

print("Texas Hold'em")
test("hole cards stay private; a hand plays to showdown; everyone verifies the deal", function()
    local P, host = seated({ "Efe Imperial", "Talmika Waystalker", "Nox Aeterna" }, { game = "poker", wager = 100, maxSeats = 6, stamp = 11 })
    local tal, nox = P.clients["Talmika Waystalker"], P.clients["Nox Aeterna"]
    host.Table.startGame(); P.flush()
    local ht = host.Table.current().t
    local tt, nt = tal.Table.current().t, nox.Table.current().t
    check(tt.myHole and tt.myHole[1] == ht.holes[2][1] and tt.myHole[2] == ht.holes[2][2], "Talmika got her two cards")
    check(nt.myHole and nt.myHole[1] == ht.holes[3][1], "Nox got his")
    check(tt.holes == nil and not tostring(tt.myHole[1]):find(tostring(nt.myHole[1]) .. "x"), "guests do not hold the deck")
    check(ht.button == 1 and ht.sbSeat == 2 and ht.bbSeat == 3 and ht.toAct == 1, "button Efe, blinds Talmika and Nox, Efe first")
    local function act(name, a, amt) P.clients[name].Table.act(a, amt); P.flush() end
    act("Efe Imperial", "call")
    act("Talmika Waystalker", "call")
    act("Nox Aeterna", "check")
    check(#tal.Table.current().t.board == 3 and tal.Table.current().t.street == "flop", "flop dealt to everyone")
    for _, street in ipairs({ "flop", "turn", "river" }) do
        act("Talmika Waystalker", "check"); act("Nox Aeterna", "check"); act("Efe Imperial", "check")
    end
    local t = nox.Table.current().t
    check(t.phase == "done" and t.reveal and #t.board == 5, "showdown reached, seed revealed")
    check(P.count("Nox Aeterna", "mismatch") == 0 and P.count("Talmika Waystalker", "mismatch") == 0, "deal verified")
    local total = 0
    for _, d in ipairs(P.last("Nox Aeterna", "settled").args[2]) do total = total + d.amount end
    check(total > 0 and total <= 300, "the pot of 300 moves through the ledger")
end)
test("a fold ends the hand; raises reopen the action", function()
    local P, host = seated({ "Efe Imperial", "Talmika Waystalker" }, { game = "poker", wager = 100, maxSeats = 6, stamp = 12 })
    host.Table.startGame(); P.flush()
    local t = host.Table.current().t
    check(t.sbSeat == 1 and t.toAct == 1, "heads-up: the button posts the small blind and acts first")
    host.Table.act("raise", 400); P.flush()
    check(t.curBet == 400 and t.toAct == 2, "raise to 400")
    P.clients["Talmika Waystalker"].Table.act("raise", 1200); P.flush()
    check(t.curBet == 1200 and t.toAct == 1, "re-raise reopens Efe")
    host.Table.act("fold"); P.flush()
    local d = P.last("Talmika Waystalker", "settled").args[2]
    check(t.phase == "done" and d[1].from == "Efe Imperial" and d[1].amount == 400, "Efe loses the 400 he put in")
end)
test("all in for 100 big blinds runs the board out", function()
    local P, host = seated({ "Efe Imperial", "Talmika Waystalker" }, { game = "poker", wager = 100, maxSeats = 6, stamp = 13 })
    host.Table.startGame(); P.flush()
    host.Table.act("allin"); P.flush()
    P.clients["Talmika Waystalker"].Table.act("call"); P.flush()
    local t = P.clients["Talmika Waystalker"].Table.current().t
    check(t.phase == "done" and #t.board == 5 and t.total[1] == 10000 and t.total[2] == 10000, "both all in for 10000, board run out")
end)
test("a host that changes the board is caught when the seed is revealed", function()
    local P, host = seated({ "Efe Imperial", "Talmika Waystalker" }, { game = "poker", wager = 100, maxSeats = 6, stamp = 14 })
    host.Table.startGame(); P.flush()
    local t = host.Table.current().t
    t.fullBoard[1] = (t.fullBoard[1] + 1) % 52
    host.Table.act("call"); P.flush()
    P.clients["Talmika Waystalker"].Table.act("check"); P.flush()
    for _ = 1, 3 do P.clients["Talmika Waystalker"].Table.act("check"); P.flush(); host.Table.act("check"); P.flush() end
    check(P.count("Talmika Waystalker", "mismatch") >= 1, "Talmika's addon flags the board")
end)

print("Chat play")
test("chat commands: whole messages only, amounts in gold unless spelled out", function()
    local Chat = load({}).Chat
    local function p(s) local a, n = Chat.parse(s); return tostring(a) .. "/" .. tostring(n) end
    check(p("hit") == "hit/nil" and p("  Stand! ") == "stand/nil" and p("JOIN") == "join/nil", "single words")
    check(p("all in") == "allin/nil" and p("allin") == "allin/nil", "all in")
    check(p("raise 500") == "raise/5000000" and p("raise 50s") == "raise/5000" and p("raise to 1g 50s") == "raise/15000", "raise amounts")
    check(p("raise") == "nil/nil" and p("raise lots") == "nil/nil", "raise needs an amount")
    check(p("hit me baby") == "nil/nil" and p("call me later") == "nil/nil" and p("lol") == "nil/nil", "sentences are talk")
    check(Chat.money(15050) == "1g 50s 50c" and Chat.money(0) == "0c", "plain coins")
    local long = "[GF] " .. ("Somebody pays Someone 10g, "):rep(20)
    for _, l in ipairs(Chat.fit(long)) do check(#l <= 255, "line fits: " .. #l) end
end)

-- a party where Bob has no addon: his lines reach only the host's chatCommand
local function chatTable(names, opts)
    local P = party(names)
    local host = P.clients[names[1]]
    P.said = {}
    host.say = function(text) if text then assert(#text <= 255, "chat line over 255"); P.said[#P.said + 1] = text end end
    host.sayTo = function(name, text) P.said[#P.said + 1] = "(to " .. name .. ") " .. text end
    opts.chat = true
    host.Table.open(opts)
    P.flush()
    local tid = host.Table.current().tid
    for i = 2, #names do if names[i] ~= "Bob Noaddon" then P.clients[names[i]].Table.join(tid) end end
    P.flush()
    P.clients["Bob Noaddon"] = nil   -- Bob hears nothing; he only types
    function P.bob(text) host.Table.chatCommand("Bob Noaddon", text); P.flush() end
    function P.saidLike(pat) for _, l in ipairs(P.said) do if l:find(pat) then return l end end end
    return P, host
end

test("a chat player joins Deathroll by typing join and is told when to roll", function()
    local P, host = chatTable({ "Efe Imperial", "Bob Noaddon" }, { game = "deathroll", wager = 10000, start = 1000, maxSeats = 2, stamp = 21 })
    check(P.saidLike("^%[GF%] Deathroll table open, wager 1g%. Type join"), "the table is announced")
    P.bob("join")
    local t = host.Table.current().t
    check(#t.seats == 2 and t.seats[2] == "Bob Noaddon", "Bob is seated")
    check(P.saidLike("Seated %(2/2%): Efe, Bob"), "seating is narrated")
    host.Table.startGame(); P.flush(); P.serverRoll(2)   -- Bob goes first
    check(P.saidLike("^%[GF%] Bob, /roll 1%-1000$"), "Bob is prompted with his range")
    P.roll("Bob Noaddon", 1, 1, 1000); P.flush()
    check(P.saidLike("^%[GF%] Efe wins%. Bob pays Efe 1g%.$"), "the result is narrated")
    check(P.saidLike("Efe rolls for who goes first") and not P.saidLike("rolls %d"), "rolls are never narrated")
    P.bob("join")
    check(P.saidLike("Bob, the table is") == nil, "a seated player's join is ignored")
end)

test("Blackjack by chat: Bob sees the deal, hits, stands, and gets the result", function()
    local P, host = chatTable({ "Dealer Person", "Bob Noaddon" }, { game = "blackjack", wager = 10000, maxSeats = 6, stamp = 22 })
    P.bob("join")
    host.Table.startGame()
    dealCards(P, host, { "10h", "6d", "6s" })
    check(P.saidLike("^%[GF%] Dealer shows 6d%. Bob: 10h 6s %(16%)%.$"), "the deal is narrated")
    check(P.saidLike("^%[GF%] Bob: 10h 6s %(16%) vs 6d%. hit, stand, double%?$"), "Bob is prompted")
    P.bob("hit, please")   -- talk, not a command
    check(not host.Table.current().t.need, "a sentence does nothing")
    P.bob("hit"); dealCards(P, host, { "4c" })
    check(P.saidLike("Bob: 10h 6s 4c %(20%) vs 6d%. hit, stand%?"), "the new card shows in the next prompt")
    P.bob("stand"); P.flush()
    dealCards(P, host, { "Kh", "2c" })   -- dealer 6+10+2 = 18
    check(P.saidLike("^%[GF%] Dealer: 6d Kh 2c %(18%)%. Bob wins 1g%. Type join to play the next round%.$"), "the result is narrated, with an invitation")
end)

test("Hold'em by chat: hole cards by whisper, prompts with amounts, raise in gold", function()
    local P, host = chatTable({ "Efe Imperial", "Bob Noaddon" }, { game = "poker", wager = 10000, maxSeats = 6, stamp = 23 })
    P.bob("join")
    host.Table.startGame(); P.flush()
    local t = host.Table.current().t
    check(P.saidLike("^%(to Bob Noaddon%) %[GF%] Your cards for hand 1: %w+ %w+$"), "Bob's cards come by whisper")
    check(t.toAct == 1, "heads-up: Efe (button, small blind) acts first")
    host.Table.act("raise", 40000); P.flush()
    check(P.saidLike("^%[GF%] Efe raises to 4g%.$"), "Efe's raise is narrated")
    check(P.saidLike("^%[GF%] Bob, pot 5g: call 3g, raise 7g or more, allin, fold%?$"), "Bob is prompted")
    P.bob("raise 10")
    check(t.curBet == 100000 and t.toAct == 1, "Bob raised to 10g")
    host.Table.act("call"); P.flush()
    check(P.saidLike("^%[GF%] Flop: %w+ %w+ %w+%. Pot 20g%.$"), "the flop is narrated")
    P.bob("fold")
    check(t.phase == "done" and P.saidLike("^%[GF%] Efe wins 20g, everyone else folded%."), "the result is narrated")
end)

test("chat on with only addon players: the game is posted, nobody is prompted", function()
    local P, host = chatTable({ "Efe Imperial", "Talmika Waystalker", "Bob Noaddon" }, { game = "deathroll", wager = 10000, start = 1000, maxSeats = 3, stamp = 25 })
    local tal = P.clients["Talmika Waystalker"]
    host.Table.startGame(); P.flush(); P.serverRoll(2)   -- Talmika first
    check(P.saidLike("^%[GF%] Deathroll from 1000") and not P.saidLike("/roll 1%-"), "start posted, no prompt for an addon player")
    tal.Table.rollMine(); P.serverRoll(1)
    check(P.saidLike("^%[GF%] Efe wins%. Talmika pays Efe 1g%. Type join"), "result posted, with an invitation")
end)

test("between rounds an addon player and a chat player join; the next round deals them in", function()
    local P, host = chatTable({ "Efe Imperial", "Talmika Waystalker", "Nox Aeterna", "Bob Noaddon" }, { game = "poker", wager = 100, maxSeats = 6, stamp = 26 })
    local nox = P.clients["Nox Aeterna"]
    nox.Table.close(); P.flush()   -- Nox sits out the first hand
    local t = host.Table.current().t
    check(#t.seats == 2, "two seats for hand 1")
    host.Table.startGame(); P.flush()
    P.bob("join")
    check(P.saidLike("^%[GF%] Bob, a round is on"), "a join mid-hand is refused, with a reason")
    host.Table.act("fold"); P.flush()
    check(t.phase == "done", "hand 1 over")
    nox.Table.join(host.Table.current().tid); P.flush()
    P.bob("join")
    check(#t.seats == 4 and t.seats[3] == "Nox Aeterna" and t.seats[4] == "Bob Noaddon", "both seated between rounds")
    check(nox.Table.current() and nox.Table.current().t.phase == "done", "Nox is at the table, waiting")
    check(P.saidLike("Seated %(4/6%)"), "the new seats are posted")
    host.Table.startGame(); P.flush()
    local nt = nox.Table.current().t
    check(nt.round == 2 and nt.myHole and #nt.myHole == 2, "Nox gets hole cards in hand 2")
    check(P.saidLike("^%(to Bob Noaddon%) %[GF%] Your cards for hand 2"), "Bob gets his by whisper")
    check(P.count("Nox Aeterna", "settled") == 0, "Nox does not settle the hand he missed")
end)

test("without chat play, chat lines do nothing", function()
    local P, host = seated({ "Efe Imperial", "Talmika Waystalker" }, { game = "deathroll", wager = 100, start = 1000, maxSeats = 3, stamp = 24 })
    host.say = function() error("narrated without chat play") end
    host.Table.chatCommand("Bob Noaddon", "join"); P.flush()
    check(#host.Table.current().t.seats == 2, "nobody sat")
end)

print("Ledger")
test("settleNet: fewest payments from net results", function()
    local L = load({}).Ledger
    local d = L.settleNet({ A = 300, B = -200, C = -100, D = 0 })
    check(#d == 2 and d[1].from == "B" and d[1].to == "A" and d[1].amount == 200 and d[2].from == "C" and d[2].amount == 100, "two payments")
end)
test("pairNet: rounds at one table add up per pair, both directions netted", function()
    local L = load({}).Ledger
    local d = L.pairNet({
        { from = "B", to = "A", amount = 100 }, { from = "B", to = "A", amount = 100 }, { from = "B", to = "A", amount = 100 },
        { from = "A", to = "B", amount = 50 }, { from = "C", to = "A", amount = 40 }, { from = "A", to = "C", amount = 40 } })
    check(#d == 1 and d[1].from == "B" and d[1].to == "A" and d[1].amount == 250, "three wins minus one loss, C squared")
    d = L.pairNet({ { from = "A", to = "B", amount = 10 }, { from = "C", to = "B", amount = 30 } })
    check(#d == 2 and d[1].from == "C" and d[1].amount == 30 and d[2].from == "A", "biggest first")
end)
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
