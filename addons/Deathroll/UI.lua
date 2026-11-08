-- Lobby window (browse tables, open one, waiting room) and the full-screen table view shown in
-- table mode. All chrome is the addon's own art (media/ui, made by scripts/make-ui-art.py).
local _, ns = ...
local UI = {}
ns.UI = UI

local MORPHEUS, FRIZ = "Fonts\\MORPHEUS.TTF", "Fonts\\FRIZQT__.TTF"
local GOLD, RED = { 1, .82, 0 }, { 1, .15, .08 }
local INK, INK_RED = { .2, .12, .04 }, { .38, .07, .02 }
local lobby, view, seats = nil, nil, {}
local W, L = {}, {}   -- table view and lobby widgets

local function art(name) return ns.media .. "ui\\" .. name .. ".png" end
local function font(parent, path, size, flags, color)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(path, size, flags or "OUTLINE")
    if color then fs:SetTextColor(unpack(color)) end
    return fs
end
-- Forever names are "First Last" everywhere; drop only a realm suffix if one ever appears.
local function nm(name) return name and name:match("^[^%-]+") or "?" end
local function money(t, n) return t.chips and (ns.coins(n) .. " in chips") or ns.coins(n) end
local function unitNote(t)
    return t.unit == 1 and "1 = 1 copper" or t.unit == 100 and "1 = 1 silver" or "1 = 1 gold"
end

-- style: "red" (main action), "gold" (confirm / selected), "dark" (secondary)
local function skinButton(parent, text, w, h, style, onClick, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture(art("btn_gold"))
    hl:SetAllPoints()
    hl:SetBlendMode("ADD")
    hl:SetAlpha(.18)
    b.text = font(b, MORPHEUS, size or 15, "")
    b.text:SetPoint("CENTER", 0, 1)
    function b:SetStyle(s)
        self.style = s
        self.bg:SetTexture(art("btn_" .. s))
        if s == "gold" then self.text:SetTextColor(.2, .1, .02); self.text:SetShadowColor(1, .9, .5, .5)
        else self.text:SetTextColor(1, .9, .62); self.text:SetShadowColor(0, 0, 0, 1) end
        self.text:SetShadowOffset(1, -1)
    end
    function b:SetLabel(s) self.text:SetText(s) end
    b:SetStyle(style)
    b:SetLabel(text)
    b:SetScript("OnMouseDown", function(self) if self:IsEnabled() then self.text:SetPoint("CENTER", 1, 0) end end)
    b:SetScript("OnMouseUp", function(self) self.text:SetPoint("CENTER", 0, 1) end)
    b:SetScript("OnDisable", function(self) self.bg:SetDesaturated(true); self:SetAlpha(.5) end)
    b:SetScript("OnEnable", function(self) self.bg:SetDesaturated(false); self:SetAlpha(1) end)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

---------------------------------------------------------------- tweens, coins, jolts (one OnUpdate)

local tweens, coins = {}, {}
local function tween(dur, fn, done) tweens[#tweens + 1] = { t = 0, dur = dur, fn = fn, done = done } end
local jolt, pulse = 0, 0   -- jolt: short shake of the deathroll number only; pulse drives the danger glow

local function coinShower(x, y, n)
    for _ = 1, n do
        local c
        for _, k in ipairs(coins) do if not k.live then c = k; break end end
        if not c then
            c = { tex = W.fx:CreateTexture(nil, "OVERLAY") }
            c.tex:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
            c.tex:SetSize(18, 18)
            coins[#coins + 1] = c
        end
        local a, sp = math.random() * math.pi * 2, 150 + math.random() * 350
        c.x, c.y, c.vx, c.vy, c.life, c.live = x, y, math.cos(a) * sp, math.abs(math.sin(a)) * sp + 200, 2 + math.random(), true
        c.tex:Show()
    end
end

local function onUpdate(_, el)
    for i = #tweens, 1, -1 do
        local tw = tweens[i]
        tw.t = tw.t + el
        local p = math.min(1, tw.t / tw.dur)
        tw.fn(p)
        if p >= 1 then table.remove(tweens, i); if tw.done then tw.done() end end
    end
    for _, c in ipairs(coins) do
        if c.live then
            c.vy = c.vy - 900 * el
            c.x, c.y, c.life = c.x + c.vx * el, c.y + c.vy * el, c.life - el
            c.tex:SetPoint("CENTER", W.fx, "CENTER", c.x, c.y)
            c.tex:SetAlpha(math.min(1, c.life))
            if c.life <= 0 then c.live = false; c.tex:Hide() end
        end
    end
    if jolt > .3 then
        W.num:SetPoint("CENTER", W.content, "CENTER", (math.random() - .5) * jolt, 30 + (math.random() - .5) * jolt)
        jolt = jolt * math.max(0, 1 - el * 9)
    elseif jolt > 0 then
        jolt = 0
        W.num:SetPoint("CENTER", W.content, "CENTER", 0, 30)
    end
    if W.danger then
        pulse = pulse + el * 4
        W.glow:SetAlpha(.35 + .25 * math.sin(pulse))
    end
end

---------------------------------------------------------------- table view

-- seat slots per game: angle around the table, ellipse radii, seat scale
local LAYOUT = {
    deathroll = { slots = { 180, 0, 140, 40, 220, 320 }, rx = 560, ry = 215, scale = 1 },
    highlow = { slots = { 180, 0, 148, 32, 212, 328, 118, 62 }, rx = 560, ry = 220, scale = .8 },
}

local function edge(parent, side, orientation, from, to, size)
    local t = parent:CreateTexture(nil, "BACKGROUND")
    t:SetColorTexture(1, 1, 1, 1)
    if side == "LEFT" or side == "RIGHT" then
        t:SetPoint("TOP" .. side); t:SetPoint("BOTTOM" .. side); t:SetWidth(size)
    else
        t:SetPoint(side .. "LEFT"); t:SetPoint(side .. "RIGHT"); t:SetHeight(size)
    end
    t:SetGradient(orientation, CreateColor(0, 0, 0, from), CreateColor(0, 0, 0, to))
end

local function layoutSeats(gameId)
    if W.layout == gameId then return end
    W.layout = gameId
    local lay = LAYOUT[gameId]
    for i, s in ipairs(seats) do
        local a = lay.slots[i] and math.rad(lay.slots[i])
        s:ClearAllPoints()
        s:SetScale(lay.scale)
        if a then
            s.ox, s.oy = lay.rx * math.cos(a), lay.ry * math.sin(a) - 10
            s:SetPoint("CENTER", W.content, "CENTER", s.ox / lay.scale, s.oy / lay.scale)
        end
    end
end

local function buildTable()
    view = CreateFrame("Frame", "DeathrollTableView", nil)   -- no parent: stays visible while UIParent is hidden
    view:SetAllPoints(WorldFrame)
    view:SetFrameStrata("DIALOG")
    view:Hide()
    edge(view, "LEFT", "HORIZONTAL", .9, 0, 380)
    edge(view, "RIGHT", "HORIZONTAL", 0, .9, 380)
    edge(view, "TOP", "VERTICAL", 0, .8, 230)
    edge(view, "BOTTOM", "VERTICAL", .95, 0, 260)

    local c = CreateFrame("Frame", nil, view)
    c:SetSize(1365, 768)
    c:SetPoint("CENTER")
    W.content = c

    local felt = c:CreateTexture(nil, "BORDER")
    felt:SetTexture(ns.media .. "table.png")
    felt:SetSize(980, 490)
    felt:SetPoint("CENTER", 0, -10)

    W.title = font(c, MORPHEUS, 46, "OUTLINE", GOLD)
    W.title:SetPoint("TOP", 0, -26)
    W.sub = font(c, FRIZ, 15, "OUTLINE", { .9, .85, .7 })
    W.sub:SetPoint("TOP", W.title, "BOTTOM", 0, -2)

    -- Deathroll centre
    W.dr = CreateFrame("Frame", nil, c)
    W.dr:SetAllPoints()
    W.turn = font(W.dr, FRIZ, 18, "OUTLINE", GOLD)
    W.turn:SetPoint("CENTER", c, "CENTER", 0, 120)
    W.glow = W.dr:CreateTexture(nil, "ARTWORK")
    W.glow:SetTexture(ns.media .. "glow.png")
    W.glow:SetBlendMode("ADD")
    W.glow:SetVertexColor(1, .1, .05)
    W.glow:SetSize(420, 300)
    W.glow:SetPoint("CENTER", c, "CENTER", 0, 30)
    W.glow:Hide()
    W.num = font(W.dr, MORPHEUS, 112, "THICKOUTLINE")
    W.num:SetPoint("CENTER", c, "CENTER", 0, 30)
    W.range = font(W.dr, FRIZ, 20)
    W.range:SetPoint("CENTER", c, "CENTER", 0, -50)
    W.trail = font(W.dr, FRIZ, 14, "", { .85, .8, .6 })
    W.trail:SetPoint("CENTER", c, "CENTER", 0, -82)

    -- High-Low centre: everyone's roll on a board
    W.hl = CreateFrame("Frame", nil, c)
    W.hl:SetAllPoints()
    W.hlInfo = font(W.hl, FRIZ, 18, "OUTLINE", GOLD)
    W.hlInfo:SetPoint("CENTER", c, "CENTER", 0, 58)
    W.cells = {}
    for i = 1, 40 do
        local cell = CreateFrame("Frame", nil, W.hl)
        cell:SetSize(136, 16)
        cell:SetPoint("TOPLEFT", c, "CENTER", -280 + math.floor((i - 1) / 10) * 142, 38 - ((i - 1) % 10) * 17)
        cell.bg = cell:CreateTexture(nil, "BACKGROUND")
        cell.bg:SetAllPoints()
        cell.name = font(cell, FRIZ, 10, "")
        cell.name:SetPoint("LEFT", 4, 0)
        cell.name:SetWidth(88)
        cell.name:SetJustifyH("LEFT")
        cell.name:SetWordWrap(false)
        cell.val = font(cell, FRIZ, 11, "OUTLINE")
        cell.val:SetPoint("RIGHT", -4, 0)
        W.cells[i] = cell
    end
    W.hlResult = font(W.hl, MORPHEUS, 22, "OUTLINE", GOLD)
    W.hlResult:SetPoint("CENTER", c, "CENTER", 0, -150)

    for i = 1, 8 do
        local s = ns.Scene.seat(c)
        s:Hide()
        seats[i] = s
    end

    -- bottom bar
    local bar = CreateFrame("Frame", nil, c)
    bar:SetSize(860, 70)
    bar:SetPoint("BOTTOM", 0, 20)
    local bt = bar:CreateTexture(nil, "BACKGROUND")
    bt:SetTexture(art("bar"))
    bt:SetAllPoints()
    W.leave = skinButton(bar, "Leave table", 118, 32, "dark", function() ns.Table.close() end)
    W.leave:SetPoint("LEFT", 18, 0)
    W.start = skinButton(bar, "Start", 110, 32, "gold", function() ns.Table.startGame() end)
    W.start:SetPoint("LEFT", W.leave, "RIGHT", 8, 0)
    W.closeRolls = skinButton(bar, "Close rolls", 110, 32, "dark", function() ns.Table.closeRolls() end)
    W.closeRolls:SetPoint("LEFT", W.leave, "RIGHT", 8, 0)
    W.roll = skinButton(bar, "ROLL", 200, 50, "red", function() ns.Table.rollMine() end, 28)
    W.roll:SetPoint("CENTER")
    W.music = skinButton(bar, "Music: on", 110, 32, "dark", function()
        W.music:SetLabel(ns.Stage.toggleMusic() and "Music: off" or "Music: on")
    end)
    W.music:SetPoint("RIGHT", -18, 0)
    W.hide = skinButton(bar, "Hide (Esc)", 110, 32, "dark", function() ns.Stage.leave("hide") end)
    W.hide:SetPoint("RIGHT", W.music, "LEFT", -8, 0)

    W.status = font(c, FRIZ, 15, "OUTLINE", { .95, .9, .75 })
    W.status:SetPoint("BOTTOM", bar, "TOP", 0, 10)
    W.banner = font(c, FRIZ, 16, "OUTLINE", { 1, .35, .25 })
    W.banner:SetPoint("TOP", W.sub, "BOTTOM", 0, -10)

    -- dice, stinger and coins sit above everything
    W.fx = CreateFrame("Frame", nil, c)
    W.fx:SetAllPoints()
    W.fx:SetFrameLevel(c:GetFrameLevel() + 20)
    W.dice = W.fx:CreateTexture(nil, "OVERLAY")
    W.dice:SetSize(56, 56)
    W.dice:Hide()
    W.sting = CreateFrame("Frame", nil, W.fx)
    W.sting:SetSize(1000, 200)
    W.sting:SetPoint("CENTER", 0, 30)
    W.sting:Hide()
    W.stingText = font(W.sting, MORPHEUS, 88, "THICKOUTLINE", RED)
    W.stingText:SetPoint("CENTER")
    W.stingSub = font(W.sting, FRIZ, 22, "OUTLINE", GOLD)
    W.stingSub:SetPoint("TOP", W.stingText, "BOTTOM", 0, -6)

    view:SetScript("OnUpdate", onUpdate)
    view:EnableKeyboard(true)
    view:SetPropagateKeyboardInput(true)
    view:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            ns.Stage.leave("hide")
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
end

local function stinger(text, sub, hold, color)
    W.stingText:SetText(text)
    W.stingText:SetTextColor(unpack(color or RED))
    W.stingSub:SetText(sub or "")
    W.sting:Show()
    tween(.9, function(p)
        local e = 1 - (1 - p) ^ 3
        W.sting:SetScale(2.6 - 1.6 * e)
        W.sting:SetAlpha(math.min(1, p * 3))
    end, function()
        C_Timer.After(hold or 1.6, function()
            tween(.4, function(p) W.sting:SetAlpha(1 - p) end, function() W.sting:Hide() end)
        end)
    end)
end

-- The die flies from the rolling player's seat (or the bottom edge for seats without a 3D
-- character) to `tx, ty` while the deathroll number spins; `onLand` runs after it lands.
local function throwDice(seatIndex, final, max, onLand, tx, ty)
    local s = seatIndex and seatIndex <= #seats and seats[seatIndex]:IsShown() and seats[seatIndex]
    local x0, y0 = s and s.ox or 0, s and (s.oy + 40) or -250
    tx, ty = tx or 0, ty or 30
    W.spinning = final ~= nil
    W.dice:Show()
    tween(.55, function(p)
        local e = 1 - (1 - p) ^ 2
        if final then W.num:SetText(math.random(1, math.max(1, max))) end
        W.dice:SetTexture(ns.media .. "dice\\dieWhite_border" .. math.random(1, 6) .. ".png")
        W.dice:SetPoint("CENTER", W.fx, "CENTER", x0 + (tx - x0) * e, y0 + (ty - y0) * e + math.sin(p * math.pi) * 90)
        W.dice:SetRotation(p * 14)
    end, function()
        W.dice:Hide()
        W.spinning = false
        if final then
            W.num:SetText(final)
            jolt = final == 1 and 16 or final < 10 and 7 or 0
            tween(.2, function(p) W.num:SetScale(1 + .14 * math.sin(p * math.pi)) end)
        end
        if onLand then onLand() end
    end)
end

local function seatState(t, i)
    if t.game == "deathroll" then
        if t.phase == "done" and t.winner == i then return "win" end
        if t.alive and t.alive[i] == false then return "out" end
        if t.phase == "rolling" and t.turn == i then return "turn" end
    else
        if t.phase == "done" and t.hiSeat == i and (t.diff or 0) > 0 then return "win" end
        if t.phase == "done" and t.loSeat == i and (t.diff or 0) > 0 then return "out" end
        local waiting = ns.Games.highlow.waitingOn(t)
        for _, s in ipairs(waiting) do if s == i then return "turn" end end
    end
end

local function refreshDeathroll(c, t, mine)
    local n = #t.seats
    W.sub:SetText(("%s  -  wager %s  -  start %d"):format(n == 2 and "1v1" or "Free-for-all", money(t, t.wager), t.start))
    W.danger = t.phase == "rolling" and t.cur < 10
    W.glow:SetShown(W.danger)
    if W.danger then W.num:SetTextColor(1, .25, .12) else W.num:SetTextColor(1, .82, 0) end
    W.trail:SetText(table.concat(t.history or {}, "   >   "))
    if t.phase == "seating" then
        W.num:SetText(t.start)
        W.turn:SetText("")
        W.range:SetText(("Waiting for players  %d / %d"):format(n, t.maxSeats))
        W.status:SetText(c.hosting and (n >= 2 and "Press Start when everyone is seated." or "") or "Waiting for the host to start.")
    elseif t.phase == "first" then
        if not W.spinning then W.num:SetText(t.start) end
        W.turn:SetText("WHO GOES FIRST?")
        W.range:SetText(("%s rolls 1 - %d"):format(nm(t.host), n))
        W.status:SetText("")
    elseif t.phase == "rolling" then
        if not W.spinning then W.num:SetText(t.cur) end
        W.turn:SetText(mine and "YOUR ROLL" or (nm(t.seats[t.turn]):upper() .. "'S ROLL"))
        W.range:SetText("/roll 1 - " .. t.cur)
        W.status:SetText(mine and "Click ROLL. Roll a 1 and you are out." or "")
    elseif t.phase == "done" then
        W.turn:SetText(nm(t.seats[t.winner]):upper() .. " WINS")
        W.range:SetText("")
    end
end

local CELL = { hi = { .9, .7, .1, .55 }, lo = { .8, .12, .06, .6 }, tie = { .95, .5, .1, .45 }, wait = { 0, 0, 0, .25 }, done = { 0, 0, 0, .45 } }

local function refreshHighLow(c, t, mine)
    W.sub:SetText(("Wager %s  -  everyone rolls 1 - %d  (%s)"):format(money(t, t.wager), t.range, unitNote(t)))
    local tied = {}
    for _, s in ipairs(t.tieSeats or {}) do tied[s] = true end
    for i, cell in ipairs(W.cells) do
        local name = t.seats[i]
        if name then
            cell:Show()
            cell.name:SetText(nm(name))
            local v = t.rolls and t.rolls[i]
            local text = v == true and "?" or v or (t.left and t.left[i] and "left") or (t.phase == "rolling" and "..." or "")
            local tv = t.tieRolls and t.tieRolls[i]
            if tv then text = text .. " > " .. (tv == true and "?" or (tv <= 0 and "-" or tv)) end
            cell.val:SetText(text)
            local color = (t.phase == "done" and t.hiSeat == i and (t.diff or 0) > 0 and CELL.hi)
                or (t.phase == "done" and t.loSeat == i and (t.diff or 0) > 0 and CELL.lo)
                or (tied[i] and CELL.tie) or (v and CELL.done) or CELL.wait
            cell.bg:SetColorTexture(unpack(color))
            local me = ns.Rolls.same(name, ns.me())
            cell.name:SetTextColor(me and 1 or .9, me and .82 or .85, me and 0 or .7)
        else
            cell:Hide()
        end
    end
    W.hlResult:SetText("")
    if t.phase == "seating" then
        W.hlInfo:SetText(("Waiting for players  %d / %d"):format(#t.seats, t.maxSeats))
        W.status:SetText(c.hosting and (#t.seats >= 2 and "Press Start when everyone is seated." or "") or "Waiting for the host to start.")
    elseif t.phase == "rolling" then
        W.hlInfo:SetText(("Everyone rolls 1 - %d"):format(t.range))
        W.status:SetText(mine and "Click ROLL." or "Waiting for everyone to roll.")
    elseif t.phase == "tie" then
        local names = {}
        for _, s in ipairs(t.tieSeats or {}) do names[#names + 1] = nm(t.seats[s]) end
        W.hlInfo:SetText(("Roll-off for the %s roll: %s"):format(t.tieSide == "hi" and "high" or "low", table.concat(names, ", ")))
        W.status:SetText(mine and "You are in the roll-off. Click ROLL." or "")
    elseif t.phase == "done" then
        W.hlInfo:SetText("")
        if t.hiSeat and t.loSeat and (t.diff or 0) > 0 then
            W.hlResult:SetText(("%s pays %s %s"):format(nm(t.seats[t.loSeat]), nm(t.seats[t.hiSeat]), money(t, t.diff * t.unit)))
        else
            W.hlResult:SetText("Push: nobody pays")
        end
    end

    -- result and roll-off moments, whether this client resolved them or the host's state did
    local key = table.concat({ t.round or 0, t.phase, t.tieSide or "", tostring(t.tieSeats and #t.tieSeats) }, ":")
    if W.hlKey ~= key then
        local fresh = W.hlKey ~= nil
        W.hlKey = key
        if fresh and t.phase == "tie" then
            ns.sound("chipLay1")
            stinger("ROLL-OFF", "for the " .. (t.tieSide == "hi" and "high" or "low") .. " roll", 1.2, GOLD)
        elseif fresh and t.phase == "done" then
            if t.hiSeat and t.loSeat and (t.diff or 0) > 0 then
                stinger(nm(t.seats[t.loSeat]):upper() .. " PAYS", nm(t.seats[t.hiSeat]) .. "  " .. money(t, t.diff * t.unit), 2)
                local w = seats[t.hiSeat]
                C_Timer.After(1.2, function()
                    coinShower(w and w:IsShown() and w.ox or 0, (w and w:IsShown() and w.oy or -40) + 60, 60)
                    ns.sound("chipsStack1")
                end)
                if seats[t.hiSeat] then seats[t.hiSeat]:Anim("cheer", 4) end
                if seats[t.loSeat] then seats[t.loSeat]:Anim("cry", 4) end
            else
                stinger("PUSH", "nobody pays", 1.4, GOLD)
            end
        end
    end
end

local function refresh()
    local c = ns.Table.current()
    if not view or not c then return end
    local t = c.t
    local mine = ns.Table.myTurn()
    local hl = t.game == "highlow"
    layoutSeats(t.game)
    W.title:SetText(hl and "HIGH - LOW" or "DEATHROLL")
    W.dr:SetShown(not hl)
    W.hl:SetShown(hl)
    if hl then W.danger = false; W.glow:Hide() end

    for i, s in ipairs(seats) do
        local name = t.seats[i]
        if name and LAYOUT[t.game].slots[i] then
            s:Show()
            s:SetPlayer(name)
            local state = seatState(t, i)
            if s.state ~= state then s:SetState(state) end
            s:SetNote(i == 1 and "host" or "")
        else
            s:Hide()
        end
    end

    if hl then refreshHighLow(c, t, mine) else refreshDeathroll(c, t, mine) end

    W.roll:SetEnabled(mine and not ns.lockdown())
    local between = t.phase == "seating" or t.phase == "done"
    W.start:SetShown(c.hosting and between)
    W.start:SetLabel(t.phase == "done" and "Rematch" or "Start")
    W.start:SetEnabled(#t.seats >= ns.Games[t.game].minSeats)
    W.closeRolls:SetShown(c.hosting and hl and (t.phase == "rolling" or t.phase == "tie"))
    W.music:SetLabel(DeathrollDB.settings.mute and "Music: off" or "Music: on")
end

local function onEvent(ev)
    local c = ns.Table.current()
    if not c or not view then return end
    local t = c.t
    if t.game == "highlow" then
        if ev.kind == "roll" and not ev.late then
            ns.sound("diceThrow1")
            if seats[ev.seat] and seats[ev.seat]:IsShown() then seats[ev.seat]:Anim("talk", 1.2) end
            throwDice(ev.seat, nil, nil, nil, 0, -40)
        end
        return
    end
    local prev = t.history[#t.history - 1] or t.start
    if ev.kind == "first" then
        ns.sound("chipLay1")
        throwDice(1, nil, nil, function() stinger(nm(t.seats[ev.seat]):upper(), "rolls first", .8, GOLD) end)
    elseif ev.kind == "roll" then
        ns.sound(ev.value < 10 and "diceThrow2" or "diceThrow1")
        seats[ev.seat]:Anim("talk", 1.6)
        throwDice(ev.seat, ev.value, prev)
    elseif ev.kind == "out" or ev.kind == "win" then
        ns.sound("diceThrow2")
        throwDice(ev.seat, 1, prev, function()
            ns.sound("dieThrow1")
            seats[ev.seat]:Anim("death")
            if ev.kind == "out" then
                stinger("OUT", nm(t.seats[ev.seat]) .. " rolled a 1", 1.2)
                for i, s in ipairs(seats) do if i ~= ev.seat and t.alive[i] then s:Anim("laugh", 2) end end
                C_Timer.After(1.8, refresh)
            else
                stinger("DEATHROLL", nm(t.seats[ev.seat]) .. " rolled a 1", 1.8)
                C_Timer.After(1.4, function()
                    local w = seats[ev.winner]
                    coinShower(w.ox, w.oy + 60, 60)
                    ns.sound("chipsStack1")
                    w:Anim("cheer", 4)
                end)
            end
        end)
    end
end

local function showSettled(t, debts)
    if #debts == 0 then return end
    local parts = {}
    for _, d in ipairs(debts) do parts[#parts + 1] = ("%s pays %s %s"):format(nm(d.from), nm(d.to), money(t, d.amount)) end
    local text = table.concat(parts, "   ")
    if not t.chips then text = text .. "   (trade it; the ledger marks it paid)" end
    C_Timer.After(2.6, function() if W.status then W.status:SetText(text) end end)
end

---------------------------------------------------------------- lobby

local function ledgerText()
    local net = ns.Ledger.net(DeathrollDB.ledger, ns.me())
    local parts = {}
    for who, amt in pairs(net) do
        if amt > 0 then parts[#parts + 1] = ("%s owes you %s"):format(nm(who), ns.coins(amt))
        elseif amt < 0 then parts[#parts + 1] = ("|cffff7050you owe|r %s %s"):format(nm(who), ns.coins(-amt)) end
    end
    return #parts > 0 and table.concat(parts, "      ") or "|cff9a8a66Nothing owed. Trades with players on the ledger are marked paid automatically.|r"
end

local function classColor(name)
    local u = ns.Scene.unitFor(name)
    local class = u and select(2, UnitClass(u))
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and c.r or INK[1], c and c.g or INK[2], c and c.b or INK[3]
end

-- Waiting room: the seats of the table I host or sit at, shown in the lobby window while the
-- normal UI and chat stay up. The host's Start pulls everyone into the table view.
local function refreshRoom(cur)
    local t = cur.t
    local g = ns.Games[t.game]
    L.roomTitle:SetText(("%s's %s"):format(nm(t.host), g.name))
    local big = t.maxSeats <= 6
    for i, row in ipairs(L.seatRows) do
        local name = t.seats[i]
        row:SetShown(big and i <= t.maxSeats)
        if big and i <= t.maxSeats then
            row.num:SetText(i)
            if name then
                row.name:SetText(nm(name)); row.name:SetTextColor(classColor(name))
                row.tag:SetText(i == 1 and "host" or (ns.bots[name] and "practice bot") or (ns.Rolls.same(name, ns.me()) and "you") or "")
            else
                row.name:SetText("open seat"); row.name:SetTextColor(.5, .42, .3)
                row.tag:SetText("")
            end
        end
    end
    for i, fs in ipairs(L.seatGrid) do
        local name = t.seats[i]
        fs:SetShown(not big and i <= t.maxSeats)
        if name then
            fs:SetText(("%d. %s%s"):format(i, nm(name), i == 1 and "  (host)" or ""))
            fs:SetTextColor(classColor(name))
        else
            fs:SetText(("%d. open seat"):format(i)); fs:SetTextColor(.5, .42, .3)
        end
    end
    local n = #t.seats
    local line2 = t.game == "deathroll" and ("Start number  %d"):format(t.start)
        or ("Rolls 1 - %d  (%s)"):format(t.range, unitNote(t))
    L.roomInfo:SetText(("Wager  %s%s\n%s\nSeats  %d / %d"):format(ns.coins(t.wager), t.chips and "  (chips)" or "", line2, n, t.maxSeats))
    if t.phase == "seating" then
        if cur.hosting then
            L.roomStatus:SetText(n >= g.minSeats and "Everyone in? Start the game." or "Waiting for players to take a seat.")
            L.roomMain:SetLabel("Start game"); L.roomMain:SetEnabled(n >= g.minSeats)
            L.roomMain:SetScript("OnClick", function() ns.Table.startGame() end)
        else
            L.roomStatus:SetText(("Waiting for %s to start."):format(nm(t.host)))
            L.roomMain:SetLabel("Waiting..."); L.roomMain:SetEnabled(false)
        end
    else
        L.roomStatus:SetText("The game is under way.")
        L.roomMain:SetLabel("Return to table"); L.roomMain:SetEnabled(true)
        L.roomMain:SetScript("OnClick", function() ns.Stage.enter(); lobby:Hide() end)
    end
    L.roomLeave:SetLabel(cur.hosting and "Close table" or "Leave table")
end

local function refreshLobby()
    if not lobby then return end
    local cur = ns.Table.current()
    for _, p in ipairs(L.browse) do p:SetShown(not cur) end
    for _, p in ipairs(L.room) do p:SetShown(cur ~= nil) end
    L.ledger:SetText(ledgerText())
    if cur then refreshRoom(cur); return end
    local list = {}
    for _, e in pairs(ns.Table.lobby) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.tid < b.tid end)
    for i, row in ipairs(L.rows) do
        local e = list[i]
        if e then
            local g = ns.Games[e.game]
            row.host:SetText(nm(e.host))
            row.info:SetText(("%s  -  %s%s  -  %d / %d seats"):format(g and g.name or e.game,
                ns.coins(e.wager), e.chips and " chips" or "", e.seated, e.maxSeats))
            row.btn:SetScript("OnClick", function() ns.Table.join(e.tid) end)
            row.btn:SetEnabled(e.seated < e.maxSeats)
            row:Show()
        else
            row:Hide()
        end
    end
    L.empty:SetShown(#list == 0)
    L.chips:SetOn(L.chips.on)
    L.immersive:SetOn(DeathrollDB.settings.immersive)
end

local function field(parent, label, value, x, y, w)
    local fs = font(parent, FRIZ, 10, "", INK_RED)
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(label)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(w, 28)
    e:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3)
    local bg = e:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(art("inset"))
    bg:SetAllPoints()
    e:SetFont(FRIZ, 14, "")
    e:SetTextColor(1, .9, .6)
    e:SetTextInsets(10, 10, 0, 0)
    e:SetAutoFocus(false)
    e:SetNumeric(true)
    e:SetText(value)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed", e.ClearFocus)
    e.label = fs
    return e
end

-- a pill that flips between dark (off) and gold (on)
local function toggle(parent, label, w, onChange)
    local b = skinButton(parent, label, w, 26, "dark", nil, 13)
    function b:SetOn(on)
        self.on = on and true or false
        self:SetStyle(self.on and "gold" or "dark")
        self:SetLabel(label .. (self.on and ": on" or ": off"))
    end
    b:SetScript("OnClick", function(self) self:SetOn(not self.on); if onChange then onChange(self.on) end end)
    b:SetOn(false)
    return b
end

local function selectGame(id)
    L.game = id
    for gid, b in pairs(L.gameButtons) do b:SetStyle(gid == id and "gold" or "dark") end
    local dr = id == "deathroll"
    L.start:SetShown(dr); L.start.label:SetShown(dr)
    L.seats.label:SetText(dr and "SEATS (2-6)" or "SEATS (2-40)")
    L.seats:SetText(dr and "2" or "10")
end

local function buildLobby()
    lobby = CreateFrame("Frame", "DeathrollLobby", UIParent)
    lobby:SetSize(768, 480)
    lobby:SetPoint("CENTER")
    lobby:SetFrameStrata("HIGH")
    lobby:SetMovable(true); lobby:EnableMouse(true)
    lobby:RegisterForDrag("LeftButton")
    lobby:SetScript("OnDragStart", lobby.StartMoving)
    lobby:SetScript("OnDragStop", lobby.StopMovingOrSizing)
    lobby:SetClampedToScreen(true)
    lobby:Hide()
    tinsert(UISpecialFrames, "DeathrollLobby")
    local bg = lobby:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(art("frame"))
    bg:SetAllPoints()

    local title = font(lobby, MORPHEUS, 26, "OUTLINE", GOLD)
    title:SetPoint("TOP", 0, -14)
    title:SetText("The Deathroll Tavern")
    local close = skinButton(lobby, "X", 28, 26, "dark", function() lobby:Hide() end, 14)
    close:SetPoint("TOPRIGHT", -16, -12)

    local function panel(x, y, w, h)
        local p = CreateFrame("Frame", nil, lobby)
        p:SetPoint("TOPLEFT", x, y)
        p:SetSize(w, h)
        local t = p:CreateTexture(nil, "BACKGROUND")
        t:SetTexture(art("parch"))
        t:SetAllPoints()
        return p
    end

    -- browse, left: open tables
    local left = panel(30, -52, 417, 350)
    local h = font(left, MORPHEUS, 22, "", INK_RED)
    h:SetPoint("TOP", 0, -12)
    h:SetText("Open Tables")
    local hs = font(left, FRIZ, 10, "", INK)
    hs:SetPoint("TOP", h, "BOTTOM", 0, -2)
    hs:SetText("IN YOUR GROUP AND GUILD")
    L.rows = {}
    for i = 1, 6 do
        local row = CreateFrame("Frame", nil, left)
        row:SetSize(385, 40)
        row:SetPoint("TOP", 0, -58 - (i - 1) * 42)
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetTexture(ns.media .. "dice\\dieRed_border" .. (i % 6 + 1) .. ".png")
        icon:SetSize(26, 26)
        icon:SetPoint("LEFT", 2, 0)
        row.host = font(row, MORPHEUS, 16, "", INK_RED)
        row.host:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 2)
        row.info = font(row, FRIZ, 11, "", INK)
        row.info:SetPoint("TOPLEFT", row.host, "BOTTOMLEFT", 0, -2)
        row.btn = skinButton(row, "Take seat", 104, 30, "red")
        row.btn:SetPoint("RIGHT")
        local line = row:CreateTexture(nil, "BACKGROUND")
        line:SetColorTexture(.45, .3, .12, .35)
        line:SetHeight(1)
        line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT")
        L.rows[i] = row
    end
    L.empty = font(left, FRIZ, 12, "", INK)
    L.empty:SetPoint("TOP", 0, -110)
    L.empty:SetWidth(330)
    L.empty:SetText("No open tables yet.\n\nOpen one on the right, or ask the host to invite you to their group.")
    local practice = skinButton(left, "Practice vs bots", 150, 28, "dark", function()
        SlashCmdList.DEATHROLL(L.game == "highlow" and "test 9 highlow" or "test 1 deathroll")
    end, 13)
    practice:SetPoint("BOTTOMLEFT", 16, 14)
    local refreshBtn = skinButton(left, "Refresh", 100, 28, "dark", function() ns.Table.who(); refreshLobby() end, 13)
    refreshBtn:SetPoint("BOTTOMRIGHT", -16, 14)

    -- browse, right: open a table
    local right = panel(474, -52, 264, 350)
    local h2 = font(right, MORPHEUS, 22, "", INK_RED)
    h2:SetPoint("TOP", 0, -12)
    h2:SetText("Open a Table")
    L.gameButtons = {}
    local games = { { "deathroll", "Deathroll" }, { "highlow", "High-Low" }, { nil, "Coinflip" }, { nil, "Blackjack" } }
    for i, g in ipairs(games) do
        local b = skinButton(right, g[2], 112, 28, "dark", nil, 13)
        b:SetPoint("TOPLEFT", 16 + ((i - 1) % 2) * 120, -48 - math.floor((i - 1) / 2) * 32)
        if g[1] then
            L.gameButtons[g[1]] = b
            b:SetScript("OnClick", function() selectGame(g[1]) end)
        else
            b:SetEnabled(false)
            local soon = font(b, FRIZ, 8, "OUTLINE", { 1, .9, .6 })
            soon:SetPoint("BOTTOMRIGHT", -6, 3)
            soon:SetText("SOON")
        end
    end
    -- wager in gold, silver and copper, each box marked with the game's coin icon
    L.gold = field(right, "WAGER", "0", 16, -122, 72)
    L.silver = field(right, " ", "50", 96, -122, 72)
    L.copper = field(right, " ", "0", 176, -122, 72)
    for _, p in ipairs({ { L.gold, "Gold" }, { L.silver, "Silver" }, { L.copper, "Copper" } }) do
        local icon = p[1]:CreateTexture(nil, "OVERLAY")
        icon:SetTexture("Interface\\MoneyFrame\\UI-" .. p[2] .. "Icon")
        icon:SetSize(13, 13)
        icon:SetPoint("RIGHT", -8, 0)
        p[1]:SetTextInsets(10, 24, 0, 0)
    end
    L.silver:SetMaxLetters(2)
    L.copper:SetMaxLetters(2)
    L.start = field(right, "START NUMBER", "1000", 16, -172, 112)
    L.seats = field(right, "SEATS (2-6)", "2", 136, -172, 112)
    L.chips = toggle(right, "Chips only", 232)
    L.chips:SetPoint("TOPLEFT", 16, -228)
    L.immersive = toggle(right, "Immersive view", 232, function(on) DeathrollDB.settings.immersive = on end)
    L.immersive:SetPoint("TOPLEFT", 16, -258)
    local open = skinButton(right, "Open Table", 232, 36, "gold", function()
        if ns.Table.current() then print("|cffffd100Deathroll|r leave your current table first."); return end
        local g = ns.Games[L.game]
        local seatsN = math.max(2, math.min(g.maxSeats, tonumber(L.seats:GetText()) or 2))
        local wager = (tonumber(L.gold:GetText()) or 0) * 10000 + math.min(99, tonumber(L.silver:GetText()) or 0) * 100
            + math.min(99, tonumber(L.copper:GetText()) or 0)
        if wager < 2 then print("|cffffd100Deathroll|r set a wager of at least 2 copper."); return end
        ns.Table.open({ game = L.game, wager = wager, start = tonumber(L.start:GetText()) or 1000,
            maxSeats = seatsN, chips = L.chips.on, stamp = time() })
    end, 18)
    open:SetPoint("BOTTOM", 0, 14)
    L.browse = { left, right }
    selectGame("deathroll")

    -- waiting room (replaces the two browse panels while I host or sit at a table)
    local seatsPanel = panel(30, -52, 417, 350)
    L.roomTitle = font(seatsPanel, MORPHEUS, 22, "", INK_RED)
    L.roomTitle:SetPoint("TOP", 0, -12)
    local rs = font(seatsPanel, FRIZ, 10, "", INK)
    rs:SetPoint("TOP", L.roomTitle, "BOTTOM", 0, -2)
    rs:SetText("SEATS")
    L.seatRows = {}
    for i = 1, 6 do
        local row = CreateFrame("Frame", nil, seatsPanel)
        row:SetSize(360, 40)
        row:SetPoint("TOP", 0, -58 - (i - 1) * 44)
        local disc = row:CreateTexture(nil, "ARTWORK")
        disc:SetTexture(art("btn_dark"))
        disc:SetSize(34, 34)
        disc:SetPoint("LEFT")
        row.num = font(row, MORPHEUS, 16, "", { 1, .9, .62 })
        row.num:SetPoint("CENTER", disc, "CENTER", 0, 1)
        row.name = font(row, MORPHEUS, 18, "")
        row.name:SetPoint("LEFT", disc, "RIGHT", 12, 0)
        row.tag = font(row, FRIZ, 11, "", INK_RED)
        row.tag:SetPoint("RIGHT", -6, 0)
        local line = row:CreateTexture(nil, "BACKGROUND")
        line:SetColorTexture(.45, .3, .12, .35)
        line:SetHeight(1)
        line:SetPoint("BOTTOMLEFT", 0, -2); line:SetPoint("BOTTOMRIGHT", 0, -2)
        L.seatRows[i] = row
    end
    -- compact grid for big tables (High-Low up to 40)
    L.seatGrid = {}
    for i = 1, 40 do
        local fs = font(seatsPanel, FRIZ, 10, "")
        fs:SetPoint("TOPLEFT", 22 + math.floor((i - 1) / 20) * 190, -52 - ((i - 1) % 20) * 14)
        fs:SetWidth(185)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        L.seatGrid[i] = fs
    end

    local infoPanel = panel(474, -52, 264, 350)
    local ih = font(infoPanel, MORPHEUS, 22, "", INK_RED)
    ih:SetPoint("TOP", 0, -12)
    ih:SetText("Table")
    L.roomInfo = font(infoPanel, FRIZ, 13, "", INK)
    L.roomInfo:SetPoint("TOP", 0, -52)
    L.roomInfo:SetSpacing(8)
    L.roomStatus = font(infoPanel, FRIZ, 12, "", INK_RED)
    L.roomStatus:SetPoint("TOP", 0, -150)
    L.roomStatus:SetWidth(230)
    local chatHint = font(infoPanel, FRIZ, 10, "", INK)
    chatHint:SetPoint("TOP", L.roomStatus, "BOTTOM", 0, -10)
    chatHint:SetWidth(230)
    chatHint:SetText("Chat stays open until the host starts.\nEveryone seated moves to the table together.")
    L.roomMain = skinButton(infoPanel, "Start game", 232, 36, "gold", nil, 18)
    L.roomMain:SetPoint("BOTTOM", 0, 52)
    L.roomLeave = skinButton(infoPanel, "Leave table", 232, 28, "dark", function() ns.Table.close() end, 14)
    L.roomLeave:SetPoint("BOTTOM", 0, 16)
    L.room = { seatsPanel, infoPanel }

    -- bottom: ledger
    local lh = font(lobby, MORPHEUS, 15, "OUTLINE", GOLD)
    lh:SetPoint("BOTTOMLEFT", 46, 28)
    lh:SetText("LEDGER")
    L.ledger = font(lobby, FRIZ, 13, "OUTLINE", { .95, .9, .75 })
    L.ledger:SetPoint("LEFT", lh, "RIGHT", 16, 0)
    L.ledger:SetPoint("RIGHT", lobby, "RIGHT", -46, 0)
    L.ledger:SetJustifyH("LEFT")

    lobby:SetScript("OnShow", function() ns.Table.who(); refreshLobby() end)
end

---------------------------------------------------------------- trade reminder

local reminder
function UI.tradeReminder(partner)
    if not partner then if reminder then reminder:Hide() end; return end
    local amt
    for who, a in pairs(ns.Ledger.net(DeathrollDB.ledger, ns.me())) do
        if ns.Rolls.same(who, partner) and a ~= 0 then amt = a end
    end
    if not amt or not TradeFrame then return end
    if not reminder then
        reminder = CreateFrame("Frame", nil, TradeFrame)
        reminder:SetSize(360, 40)
        reminder:SetPoint("BOTTOM", TradeFrame, "TOP", 0, 4)
        local t = reminder:CreateTexture(nil, "BACKGROUND")
        t:SetTexture(art("bar"))
        t:SetAllPoints()
        reminder.text = font(reminder, FRIZ, 13, "OUTLINE", { .95, .9, .75 })
        reminder.text:SetPoint("CENTER")
    end
    reminder.text:SetText(amt > 0 and ("Deathroll: %s owes you %s"):format(nm(partner), ns.coins(amt))
        or ("Deathroll: |cffff7050you owe|r %s %s"):format(nm(partner), ns.coins(-amt)))
    reminder:Show()
end

---------------------------------------------------------------- entry points

function UI.init()
    buildTable()
    buildLobby()
end

function UI.toggleLobby()
    if lobby:IsShown() then lobby:Hide() else lobby:Show() end
end

function UI.showRoom()
    if not lobby:IsShown() then lobby:Show() end
    refreshLobby()
end

function UI.hideLobby() lobby:Hide() end

function UI.tableShown() return view and view:IsShown() end

function UI.showTable(on)
    if on then
        view:Show()
        view:SetAlpha(0)
        tween(.6, function(p) view:SetAlpha(p) end)
        refresh()
    else
        view:Hide()
        jolt = 0
    end
end

function UI.handle(what, ...)
    if what == "state" or what == "roster" then
        refresh()
        refreshLobby()
    elseif what == "event" then
        onEvent(...)
    elseif what == "settled" then
        showSettled(...)
        refreshLobby()
    elseif what == "lockdown" then
        local on = ...
        if W.banner then W.banner:SetText(on and "Paused: the game blocks addon chat during encounters." or "") end
        refresh()
    elseif what == "mismatch" then
        local v = ...
        if W.banner then W.banner:SetText(("Warning: the host reported a roll of %s that nobody saw."):format(tostring(v))) end
    elseif what == "lobby" or what == "ledger" then
        refreshLobby()
    elseif what == "closed" then
        print("|cffffd100Deathroll|r the host closed the table.")
        refreshLobby()
    elseif what == "leave" then
        refreshLobby()
    end
end
