-- Who owes whom. Pure: entries are { from, to, amount, left, t }. Core keeps them in GambleForeverDB.
local _, ns = ...
local Ledger = {}
ns.Ledger = Ledger

function Ledger.add(entries, from, to, amount, when)
    if from == to or amount <= 0 then return end
    entries[#entries + 1] = { from = from, to = to, amount = amount, left = amount, t = when }
end

-- Turn each player's net result for a hand ({ name = +won / -lost }) into who pays whom:
-- the biggest loser pays the biggest winner first, so there are as few payments as possible.
function Ledger.settleNet(net)
    local winners, losers = {}, {}
    for name, v in pairs(net) do
        if v > 0 then winners[#winners + 1] = { name = name, v = v }
        elseif v < 0 then losers[#losers + 1] = { name = name, v = -v } end
    end
    local byV = function(a, b) if a.v ~= b.v then return a.v > b.v end return a.name < b.name end
    table.sort(winners, byV); table.sort(losers, byV)
    local debts, w = {}, 1
    for _, l in ipairs(losers) do
        while l.v > 0 and winners[w] do
            local p = math.min(l.v, winners[w].v)
            debts[#debts + 1] = { from = l.name, to = winners[w].name, amount = p }
            l.v, winners[w].v = l.v - p, winners[w].v - p
            if winners[w].v == 0 then w = w + 1 end
        end
    end
    return debts
end

-- Payments from many rounds netted per pair of players, biggest first: A owing B 300 and B
-- owing A 100 becomes one row, A pays B 200.
function Ledger.pairNet(debts)
    local bal, order = {}, {}
    for _, d in ipairs(debts) do
        local a, b, v = d.from, d.to, d.amount
        if a > b then a, b, v = b, a, -v end   -- v > 0: a pays b
        local k = a .. "\n" .. b
        if not bal[k] then bal[k] = { a = a, b = b, v = 0 }; order[#order + 1] = k end
        bal[k].v = bal[k].v + v
    end
    local out = {}
    for _, k in ipairs(order) do
        local e = bal[k]
        if e.v > 0 then out[#out + 1] = { from = e.a, to = e.b, amount = e.v }
        elseif e.v < 0 then out[#out + 1] = { from = e.b, to = e.a, amount = -e.v } end
    end
    table.sort(out, function(x, y) if x.amount ~= y.amount then return x.amount > y.amount end return x.from < y.from end)
    return out
end

-- Net per counterpart: positive means they owe me, negative means I owe them.
function Ledger.net(entries, me)
    local out = {}
    for _, e in ipairs(entries) do
        if e.left > 0 then
            if ns.Rolls.same(e.to, me) then out[e.from] = (out[e.from] or 0) + e.left
            elseif ns.Rolls.same(e.from, me) then out[e.to] = (out[e.to] or 0) - e.left end
        end
    end
    return out
end

-- Gold moved from `from` to `to`. Paying the net amount (or more) clears everything between
-- the two; less than that pays off the oldest debts in that direction first.
function Ledger.pay(entries, from, to, amount)
    local owed, back = 0, 0
    for _, e in ipairs(entries) do
        if e.left > 0 then
            if ns.Rolls.same(e.from, from) and ns.Rolls.same(e.to, to) then owed = owed + e.left
            elseif ns.Rolls.same(e.from, to) and ns.Rolls.same(e.to, from) then back = back + e.left end
        end
    end
    if owed - back <= 0 then return 0 end
    if amount >= owed - back then
        for _, e in ipairs(entries) do
            if (ns.Rolls.same(e.from, from) and ns.Rolls.same(e.to, to)) or (ns.Rolls.same(e.from, to) and ns.Rolls.same(e.to, from)) then
                e.left = 0
            end
        end
        return owed - back
    end
    local rest = amount
    for _, e in ipairs(entries) do
        if rest <= 0 then break end
        if e.left > 0 and ns.Rolls.same(e.from, from) and ns.Rolls.same(e.to, to) then
            local p = math.min(e.left, rest)
            e.left, rest = e.left - p, rest - p
        end
    end
    return amount - rest
end
