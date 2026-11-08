-- Lobby window (browse, open a table, waiting room, rules) and the full-screen table view shown in
-- table mode, with a view for each game. All chrome is the addon's own art (media/ui).
local _, ns = ...
local UI = {}
ns.UI = UI

local MORPHEUS, FRIZ = "Fonts\\MORPHEUS.TTF", "Fonts\\FRIZQT__.TTF"
local GOLD, RED = { 1, .82, 0 }, { 1, .15, .08 }
local INK, INK_RED = { .2, .12, .04 }, { .38, .07, .02 }
local lobby, view, seats = nil, nil, {}
local W, L = {}, {}   -- table view and lobby widgets
local held = {}       -- seats whose win or loss is still being animated: no glow until the reveal

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

local TITLES = { deathroll = "DEATHROLL", highlow = "HIGH - LOW", coinflip = "COINFLIP", blackjack = "BLACKJACK", poker = "TEXAS HOLD'EM" }

local RULES = {
    deathroll = "Players take turns rolling. The first roll is 1 to the start number; every roll after that is 1 to the previous result.\n\nRoll a 1 and you are out. With more than two players the range starts over for the next player.\n\nThe last player standing wins the wager from everyone who went out. The host's addon rolls to decide who goes first.",
    highlow = "Everyone rolls 1 to the wager at the same time. The roll counts in copper (silver or gold on very big tables; the table says which).\n\nThe lowest roller pays the highest roller the difference.\n\nTies roll again among the tied players only; the original difference still counts. If everyone rolls the same, nobody pays.",
    coinflip = "Two seats: the first is heads, the second is tails.\n\nThe host's addon flips with /roll 1-2, so the game server decides.\n\nThe loser pays the wager.",
    blackjack = "The host deals. Up to five players each play their own hand against the dealer.\n\nGoal: finish closer to 21 than the dealer without going over. 2-10 count their number, J Q K count 10, an ace counts 11 or 1.\n\nBlackjack (an ace and a 10-value card as your first two) pays 3 to 2.\n\nHit: take a card.  Stand: keep your total.\nDouble: double your bet on your first two cards and take exactly one more card.\nSplit: two cards of the same value become two hands with a bet each. Split aces get one card each.\n\nThe dealer takes one card first and the rest after every player is done, drawing to 16 and standing on 17. Over 21 is a bust and loses. A dealer blackjack beats every hand except a player blackjack. Equal totals push.\n\nThe shoe is six real decks, 312 cards. Every card the dealer's roll draws leaves the shoe; a new shoe comes in when 78 cards are left.",
    poker = "Texas Hold'em, no limit. You get two private cards; five shared cards come face up in the middle: the flop (three), the turn (one) and the river (one). Your hand is the best five cards out of your two and the five shared ones.\n\nThe two players after the dealer button post the small and big blind. There is a betting round before the flop, after the flop, after the turn and after the river.\n\nOn your turn: Fold (give up the hand), Check (pass when there is nothing to call), Call (match the bet), Raise (bet more, at least the size of the last raise), or All in.\n\nEveryone starts each hand with 100 big blinds, and every hand settles on its own in the ledger. If everyone else folds you win without showing.\n\nFair deal: the host's addon shuffles from a secret seed and shows its fingerprint before the hand; the seed is revealed after the hand and every addon checks the deal. The host's addon does see the cards during a hand, and the revealed seed shows folded hands afterwards.",
}

local HAND_EXAMPLES = {
    { "Royal flush", "As Ks Qs Js 10s" }, { "Straight flush", "9h 8h 7h 6h 5h" }, { "Four of a kind", "Qc Qd Qh Qs 7d" },
    { "Full house", "Kh Kd Kc 4s 4h" }, { "Flush", "Ad Jd 8d 6d 2d" }, { "Straight", "10c 9d 8h 7s 6c" },
    { "Three of a kind", "7c 7d 7h Ks 2d" }, { "Two pair", "Jh Jc 5d 5s Ah" }, { "Pair", "9s 9d Ah Jc 4h" },
    { "High card", "Ac Qd 9h 6s 3c" },
}
local function cardFromText(s)
    local V = { A = 14, K = 13, Q = 12, J = 11 }
    local r, su = s:match("^(%w-)([hdcs])$")
    return ns.Cards.make(V[r] or tonumber(r), ({ h = 1, d = 2, c = 3, s = 4 })[su])
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

---------------------------------------------------------------- layout

-- seat positions per game (content coordinates, centre origin), seat scale, and where cards go
local function ring(angles, rx, ry)
    local out = {}
    for i, a in ipairs(angles) do out[i] = { rx * math.cos(math.rad(a)), ry * math.sin(math.rad(a)) - 10 } end
    return out
end
local LAYOUT = {
    deathroll = { seats = ring({ 180, 0, 146, 34, 214, 326 }, 560, 215), scale = 1 },   -- top seats clear the Settle Up card
    highlow = { seats = ring({ 180, 0, 148, 32, 212, 328, 118, 62 }, 560, 220), scale = .8 },
    coinflip = { seats = { { -480, -10 }, { 480, -10 } }, scale = 1 },
    -- slot 1 is the dealer. A practice table has no dealer seat (the house deals) and the host
    -- plays from the bottom centre. The bottom seat clears the status line (y -268) and the
    -- dealer seat clears the subtitle (y 285); turn text sits top left, opposite the shoe.
    blackjack = { scale = .65,
        seats = { { 0, 190 }, { -545, 40 }, { -380, -165 }, { 0, -180 }, { 380, -165 }, { 545, 40 } },
        cards = { { 0, 45 }, { -330, 40 }, { -230, -55 }, { 0, -55 }, { 230, -55 }, { 330, 40 } },
        practiceSlots = { 4, 2, 3, 5, 6 }, info = { -440, 200 } },
    poker = { scale = .72,
        seats = { { 0, -205 }, { -400, -170 }, { -555, 30 }, { 0, 220 }, { 555, 30 }, { 400, -170 } },
        cards = { { 0, -88 }, { -250, -72 }, { -360, 30 }, { 125, 205 }, { 360, 30 }, { 250, -72 } } },
}

---------------------------------------------------------------- cards and labels on the felt

local CARD_W, CARD_H = 56, 80
local cardTex, labels = {}, {}

local function cardFile(id)
    return ns.media .. "cards\\" .. (id and ns.Cards.file(id) or "card_back") .. ".png"
end

local function beginFelt()
    for _, tx in pairs(cardTex) do tx.used = false end
    for _, fs in pairs(labels) do fs.used = false end
end
local function endFelt()
    for _, tx in pairs(cardTex) do if not tx.used then tx:Hide() end end
    for _, fs in pairs(labels) do if not fs.used then fs:Hide() end end
end

-- A card at x, y. A card that was not on the table before slides in from `origin`.
local function placeCard(key, id, x, y, origin, scale)
    local tx = cardTex[key]
    local fresh = not tx or not tx:IsShown()
    if not tx then
        tx = W.cards:CreateTexture(nil, "ARTWORK")
        tx:SetTexCoord(11 / 64, 53 / 64, 2 / 64, 62 / 64)   -- the card inside Kenney's 64x64 frame
        cardTex[key] = tx
    end
    tx.used = true
    local file = cardFile(id)
    if tx.file ~= file then tx:SetTexture(file, nil, nil, "NEAREST"); tx.file = file end
    tx:SetSize(CARD_W * (scale or 1), CARD_H * (scale or 1))
    tx:SetDrawLayer("ARTWORK", math.min(7, math.max(-8, math.floor(x / 40))))
    tx:Show()
    if fresh and origin then
        ns.sound(math.random() < .5 and "cardPlace1" or "cardPlace2")
        tween(.35, function(p)
            local e = 1 - (1 - p) ^ 2
            tx:SetPoint("CENTER", W.cards, "CENTER", origin[1] + (x - origin[1]) * e, origin[2] + (y - origin[2]) * e)
        end)
    else
        tx:SetPoint("CENTER", W.cards, "CENTER", x, y)
    end
end

local function label(key, text, x, y, size, color)
    local fs = labels[key]
    if not fs then
        fs = font(W.cards, FRIZ, size or 13, "OUTLINE")
        labels[key] = fs
    end
    fs.used = true
    fs:SetText(text)
    fs:SetTextColor(unpack(color or { 1, .95, .8 }))
    fs:SetPoint("CENTER", W.cards, "CENTER", x, y)
    fs:Show()
end

---------------------------------------------------------------- table view

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

-- where seat i sits on screen
local function slotOf(t, i)
    local m = t.practice and LAYOUT[t.game].practiceSlots
    if m then return m[i] end
    return i
end

local function layoutSeats(t)
    local gameId = t.game
    local key = gameId .. (t.practice and "p" or "")
    if W.layout == key then return end
    W.layout = key
    local lay = LAYOUT[gameId]
    local info = lay.info or { 0, 170 }
    W.cardInfo:SetPoint("CENTER", W.content, "CENTER", info[1], info[2])
    for i, s in ipairs(seats) do
        local p = lay.seats[slotOf(t, i) or 0]
        s:ClearAllPoints()
        s:SetScale(lay.scale)
        if p then
            s.ox, s.oy = p[1], p[2]
            s:SetPoint("CENTER", W.content, "CENTER", p[1] / lay.scale, p[2] / lay.scale)
        end
    end
end

local function sidePanel(title)
    local p = CreateFrame("Frame", nil, W.content)
    p:SetSize(340, 470)
    p:SetPoint("RIGHT", W.content, "RIGHT", -10, -10)
    p:SetFrameLevel(W.content:GetFrameLevel() + 30)
    p:EnableMouse(true)
    local bg = p:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(art("parch"))
    bg:SetAllPoints()
    p.title = font(p, MORPHEUS, 22, "", INK_RED)
    p.title:SetPoint("TOP", 0, -14)
    p.title:SetText(title)
    local x = skinButton(p, "X", 26, 24, "dark", function() p:Hide() end, 13)
    x:SetPoint("TOPRIGHT", -10, -10)
    p:Hide()
    return p
end

-- Settle Up card: shows at most SETTLE_ROWS payments (keeps it clear of the top-left seats;
-- deathroll seat 3 tops out at y 235); more scroll with the mouse wheel. Folds to its title bar.
local SETTLE_ROWS, ROW_H = 4, 18

local function settleRow(i)
    local p = W.settle
    local r = p.rows[i]
    if not r then
        local y = -(i - 1) * ROW_H
        r = { who = font(p.list, FRIZ, 11, "", INK), amt = font(p.list, FRIZ, 11, "", INK_RED) }
        r.who:SetPoint("TOPLEFT", 0, y)
        r.who:SetWidth(200); r.who:SetJustifyH("LEFT"); r.who:SetWordWrap(false)
        r.amt:SetPoint("TOPRIGHT", 0, y)
        r.amt:SetJustifyH("RIGHT")
        p.rows[i] = r
    end
    return r
end

local function layoutSettle()
    local p = W.settle
    local folded = GambleForeverDB.settings.settleFolded
    local vis = math.min(p.count or 0, SETTLE_ROWS)
    p.sf:SetShown(not folded); p.foot:SetShown(not folded)
    p.sf:SetHeight(math.max(1, vis * ROW_H))
    p.fold:SetLabel(folded and "+" or "-")
    p.title:SetText(folded and ("Settle Up  (%d)"):format(p.count or 0) or "Settle Up")
    p:SetHeight(folded and 38 or (34 + vis * ROW_H + 26))
end

local function buildPanels()
    W.rules = sidePanel("Rules")
    W.rulesText = font(W.rules, FRIZ, 11, "", INK)
    W.rulesText:SetPoint("TOPLEFT", 20, -48)
    W.rulesText:SetWidth(300)
    W.rulesText:SetJustifyH("LEFT")
    W.rulesText:SetSpacing(2)

    -- Settle Up card, top left: who pays whom once a round is over
    local p = CreateFrame("Frame", nil, W.content)
    p:SetSize(320, 130)
    p:SetPoint("TOPLEFT", 14, -14)
    p:SetFrameLevel(W.content:GetFrameLevel() + 20)
    p:EnableMouse(true)
    local bg = p:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(art("parch"))
    bg:SetAllPoints()
    p.title = font(p, MORPHEUS, 18, "", INK_RED)
    p.title:SetPoint("TOPLEFT", 16, -10)
    p.fold = skinButton(p, "-", 26, 22, "dark", function()
        GambleForeverDB.settings.settleFolded = not GambleForeverDB.settings.settleFolded
        layoutSettle()
    end, 14)
    p.fold:SetPoint("TOPRIGHT", -10, -8)
    local sf = CreateFrame("ScrollFrame", nil, p)
    sf:SetPoint("TOPLEFT", 16, -34)
    sf:SetSize(288, SETTLE_ROWS * ROW_H)
    local list = CreateFrame("Frame", nil, sf)
    list:SetSize(288, ROW_H)
    sf:SetScrollChild(list)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, list:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 2 * ROW_H)))
    end)
    p.sf, p.list, p.rows = sf, list, {}
    p.foot = font(p, FRIZ, 9, "", INK)
    p.foot:SetPoint("BOTTOM", 0, 10)
    p:Hide()
    W.settle = p

    W.hands = sidePanel("Winning Hands")
    local sub = font(W.hands, FRIZ, 9, "", INK)
    sub:SetPoint("TOP", 0, -38)
    sub:SetText("BEST AT THE TOP")
    for i, ex in ipairs(HAND_EXAMPLES) do
        local y = -56 - (i - 1) * 40
        local n = font(W.hands, MORPHEUS, 14, "", INK_RED)
        n:SetPoint("TOPLEFT", 18, y - 10)
        n:SetText(i .. ". " .. ex[1])
        local k = 0
        for card in ex[2]:gmatch("%S+") do
            local tx = W.hands:CreateTexture(nil, "ARTWORK")
            tx:SetTexture(cardFile(cardFromText(card)), nil, nil, "NEAREST")
            tx:SetTexCoord(11 / 64, 53 / 64, 2 / 64, 62 / 64)
            tx:SetSize(25, 36)
            tx:SetPoint("TOPLEFT", 172 + k * 28, y)
            k = k + 1
        end
    end
end

-- Coin seen from the front while it flips end over end: angle 0 shows heads, pi shows tails.
-- The face squashes with |cos|; the edge peeks out below it with |sin|, so it reads as a thick coin.
local COIN_SIZE, COIN_EDGE, COIN_REST = 140, 16, 30
local function drawCoin(angle, y, scale, spin)
    local cs, sn = math.cos(angle), math.abs(math.sin(angle))
    local size = COIN_SIZE * scale
    local h = math.max(1, size * math.abs(cs))
    local face = cs >= 0 and "heads" or "tails"
    if W.coinFace ~= face then
        W.coinFace = face
        W.coin:SetTexture(ns.media .. "coin_" .. face .. ".png")
    end
    local e = COIN_EDGE * scale * sn
    W.coin:SetSize(size, h)
    W.coin:SetPoint("CENTER", W.content, "CENTER", 0, y)
    W.coinEdge:SetSize(size, h + e)
    W.coinEdge:SetPoint("CENTER", W.content, "CENTER", 0, y - e / 2)
    W.coin:SetRotation(spin or 0); W.coinEdge:SetRotation(spin or 0)
    -- shadow on the felt: smaller and fainter the higher the coin is
    local lift = math.min(1, math.max(0, (y - COIN_REST) / 240))
    W.coinShadow:SetSize(size * (1.1 - .5 * lift), size * .35 * (1.1 - .5 * lift))
    W.coinShadow:SetAlpha(1 - .7 * lift)
end

local function buildTable()
    view = CreateFrame("Frame", "GambleForeverTableView", nil)   -- no parent: stays visible while UIParent is hidden
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

    -- Coinflip centre
    W.cf = CreateFrame("Frame", nil, c)
    W.cf:SetAllPoints()
    -- the coin: a face (heads or tails) over its edge, a shadow on the felt and a landing flash
    W.coinShadow = W.cf:CreateTexture(nil, "BORDER")
    W.coinShadow:SetTexture(ns.media .. "glow.png")
    W.coinShadow:SetVertexColor(0, 0, 0, .55)
    W.coinShadow:SetPoint("CENTER", c, "CENTER", 0, COIN_REST - COIN_SIZE / 2 + 4)
    W.coinFlash = W.cf:CreateTexture(nil, "BACKGROUND")
    W.coinFlash:SetTexture(ns.media .. "glow.png")
    W.coinFlash:SetBlendMode("ADD")
    W.coinFlash:SetVertexColor(1, .8, .3, 0)
    W.coinFlash:SetSize(360, 360)
    W.coinFlash:SetPoint("CENTER", c, "CENTER", 0, COIN_REST)
    W.coinEdge = W.cf:CreateTexture(nil, "ARTWORK", nil, 1)
    W.coinEdge:SetTexture(ns.media .. "coin_edge.png")
    W.coin = W.cf:CreateTexture(nil, "ARTWORK", nil, 2)
    drawCoin(0, COIN_REST, 1)
    W.cfInfo = font(W.cf, MORPHEUS, 30, "OUTLINE", GOLD)
    W.cfInfo:SetPoint("CENTER", c, "CENTER", 0, -80)
    W.heads = font(W.cf, MORPHEUS, 26, "OUTLINE", GOLD)
    W.heads:SetPoint("CENTER", c, "CENTER", -480, 150)
    W.heads:SetText("HEADS")
    W.tails = font(W.cf, MORPHEUS, 26, "OUTLINE", GOLD)
    W.tails:SetPoint("CENTER", c, "CENTER", 480, 150)
    W.tails:SetText("TAILS")

    -- card games: cards and labels on the felt, plus the shoe / pot / board text
    W.cards = CreateFrame("Frame", nil, c)
    W.cards:SetAllPoints()
    W.cards:SetFrameLevel(c:GetFrameLevel() + 5)
    W.cardInfo = font(W.cards, MORPHEUS, 20, "OUTLINE", GOLD)
    W.cardInfo:SetPoint("CENTER", c, "CENTER", 0, 170)
    W.shoe = W.cards:CreateTexture(nil, "ARTWORK")
    W.shoe:SetTexture(cardFile(nil), nil, nil, "NEAREST")
    W.shoe:SetTexCoord(11 / 64, 53 / 64, 2 / 64, 62 / 64)
    W.shoe:SetSize(42, 60)
    W.shoe:SetPoint("CENTER", c, "CENTER", 440, 210)
    W.shoe:SetRotation(-.25)
    W.shoeText = font(W.cards, FRIZ, 12, "OUTLINE", { .95, .9, .75 })
    W.shoeText:SetPoint("TOP", W.shoe, "BOTTOM", 0, -6)
    W.button = W.cards:CreateTexture(nil, "OVERLAY")
    W.button:SetTexture(ns.media .. "button.png", nil, nil, "NEAREST")
    W.button:SetSize(30, 30)
    W.buttonD = font(W.cards, FRIZ, 12, "OUTLINE", { .1, .1, .1 })
    W.buttonD:SetText("D")
    W.buttonD:SetShadowOffset(0, 0)
    W.buttonD:SetPoint("CENTER", W.button, "CENTER", 0, 1)

    for i = 1, 8 do
        local s = ns.Scene.seat(c)
        s:Hide()
        seats[i] = s
    end

    -- bottom bar: Leave and Start on the left, the game's own controls in the middle
    local bar = CreateFrame("Frame", nil, c)
    bar:SetSize(900, 70)
    bar:SetPoint("BOTTOM", 0, 20)
    bar:SetFrameLevel(c:GetFrameLevel() + 10)
    local bt = bar:CreateTexture(nil, "BACKGROUND")
    bt:SetTexture(art("bar"))
    bt:SetAllPoints()
    W.leave = skinButton(bar, "Leave table", 112, 32, "dark", function() ns.Table.close() end)
    W.leave:SetPoint("LEFT", 16, 0)
    W.start = skinButton(bar, "Start", 104, 32, "gold", function() ns.Table.startGame() end)
    W.start:SetPoint("LEFT", W.leave, "RIGHT", 8, 0)
    W.closeRolls = skinButton(bar, "Close rolls", 104, 32, "dark", function() ns.Table.closeRolls() end)
    W.closeRolls:SetPoint("LEFT", W.leave, "RIGHT", 8, 0)

    W.roll = skinButton(bar, "ROLL", 200, 50, "red", function() ns.Table.rollMine() end, 28)
    W.roll:SetPoint("CENTER", 60, 0)

    W.bjBar = CreateFrame("Frame", nil, bar)
    W.bjBar:SetSize(440, 50)
    W.bjBar:SetPoint("CENTER", 110, 0)
    W.bjButtons = {}
    for i, a in ipairs({ { "hit", "HIT", "red" }, { "stand", "STAND", "red" }, { "double", "DOUBLE", "gold" }, { "split", "SPLIT", "gold" } }) do
        local b = skinButton(W.bjBar, a[2], 100, 40, a[3], function() ns.Table.act(a[1]) end, 18)
        b:SetPoint("LEFT", (i - 1) * 108, 0)
        W.bjButtons[a[1]] = b
    end

    W.pkBar = CreateFrame("Frame", nil, bar)
    W.pkBar:SetSize(640, 50)
    W.pkBar:SetPoint("CENTER", 120, 0)
    W.pkFold = skinButton(W.pkBar, "FOLD", 78, 38, "dark", function() ns.Table.act("fold") end, 16)
    W.pkFold:SetPoint("LEFT", 0, 0)
    W.pkCall = skinButton(W.pkBar, "CHECK", 150, 38, "red", function()
        local can = ns.Table.myActions()
        if can then ns.Table.act(can.check and "check" or "call") end
    end, 15)
    W.pkCall:SetPoint("LEFT", W.pkFold, "RIGHT", 6, 0)
    W.pkMinus = skinButton(W.pkBar, "-", 26, 26, "dark", function() UI.stepRaise(-1) end, 16)
    W.pkMinus:SetPoint("LEFT", W.pkCall, "RIGHT", 10, 0)
    W.pkAmount = font(W.pkBar, FRIZ, 12, "OUTLINE", { 1, .95, .8 })
    W.pkAmount:SetPoint("LEFT", W.pkMinus, "RIGHT", 4, 0)
    W.pkAmount:SetWidth(108)
    W.pkPlus = skinButton(W.pkBar, "+", 26, 26, "dark", function() UI.stepRaise(1) end, 16)
    W.pkPlus:SetPoint("LEFT", W.pkMinus, "RIGHT", 116, 0)
    W.pkPot = skinButton(W.pkBar, "POT", 50, 26, "dark", function() UI.potRaise() end, 12)
    W.pkPot:SetPoint("LEFT", W.pkPlus, "RIGHT", 4, 0)
    W.pkRaise = skinButton(W.pkBar, "RAISE", 82, 38, "gold", function() ns.Table.act("raise", W.raiseTo) end, 16)
    W.pkRaise:SetPoint("LEFT", W.pkPot, "RIGHT", 8, 0)
    W.pkAllin = skinButton(W.pkBar, "ALL IN", 76, 38, "red", function() ns.Table.act("allin") end, 14)
    W.pkAllin:SetPoint("LEFT", W.pkRaise, "RIGHT", 6, 0)

    -- top-right corner: hide, music, rules, hand rankings
    local corner = CreateFrame("Frame", nil, c)
    corner:SetSize(420, 26)
    corner:SetPoint("TOPRIGHT", c, "TOPRIGHT", -16, -16)
    corner:SetFrameLevel(c:GetFrameLevel() + 10)
    W.hide = skinButton(corner, "Hide (Esc)", 96, 24, "dark", function() ns.Stage.leave("hide") end, 12)
    W.hide:SetPoint("RIGHT")
    W.music = skinButton(corner, "Music: on", 96, 24, "dark", function()
        W.music:SetLabel(ns.Stage.toggleMusic() and "Music: off" or "Music: on")
    end, 12)
    W.music:SetPoint("RIGHT", W.hide, "LEFT", -6, 0)
    W.rulesBtn = skinButton(corner, "Rules", 80, 24, "dark", function()
        W.hands:Hide(); W.rules:SetShown(not W.rules:IsShown())
    end, 12)
    W.rulesBtn:SetPoint("RIGHT", W.music, "LEFT", -6, 0)
    W.handsBtn = skinButton(corner, "Hands", 80, 24, "gold", function()
        W.rules:Hide(); W.hands:SetShown(not W.hands:IsShown())
    end, 12)
    W.handsBtn:SetPoint("RIGHT", W.rulesBtn, "LEFT", -6, 0)

    W.status = font(c, FRIZ, 15, "OUTLINE", { .95, .9, .75 })
    W.status:SetPoint("BOTTOM", bar, "TOP", 0, 10)
    W.banner = font(c, FRIZ, 16, "OUTLINE", { 1, .35, .25 })
    W.banner:SetPoint("TOP", W.sub, "BOTTOM", 0, -10)

    buildPanels()

    -- dice, stinger and coins sit above everything
    W.fx = CreateFrame("Frame", nil, c)
    W.fx:SetAllPoints()
    W.fx:SetFrameLevel(c:GetFrameLevel() + 25)
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

---------------------------------------------------------------- per-game refresh

local function waitingNote(c, t)
    return c.hosting and (#t.seats >= ns.Games[t.game].minSeats and "Press Start when everyone is seated." or "")
        or "Waiting for the host to start."
end

local function seatState(t, i)
    if t.game == "deathroll" then
        if t.phase == "done" and t.winner == i then return "win" end
        if t.alive and t.alive[i] == false then return "out" end
        if t.phase == "rolling" and t.turn == i then return "turn" end
    elseif t.game == "highlow" then
        if t.phase == "done" and t.hiSeat == i and (t.diff or 0) > 0 then return "win" end
        if t.phase == "done" and t.loSeat == i and (t.diff or 0) > 0 then return "out" end
        for _, s in ipairs(ns.Games.highlow.waitingOn(t)) do if s == i then return "turn" end end
    elseif t.game == "coinflip" then
        if t.phase == "done" then return t.winner == i and "win" or "out" end
    elseif t.game == "blackjack" then
        if t.phase == "done" and i >= ns.Games.blackjack.first(t) and t.results then
            return (t.results[i] or 0) > 0 and "win" or (t.results[i] or 0) < 0 and "out" or nil
        end
        if t.turn and t.turn[1] == i then return "turn" end
    elseif t.game == "poker" then
        if t.phase == "done" and t.won and (t.won[i] or 0) > 0 then return "win" end
        if t.inHand and t.phase ~= "seating" and not t.inHand[i] then return "out" end
        if t.toAct == i then return "turn" end
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
        W.status:SetText(waitingNote(c, t))
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
        W.turn:SetText(next(held) and "" or (nm(t.seats[t.winner]):upper() .. " WINS"))
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
        W.status:SetText(waitingNote(c, t))
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

local function refreshCoinflip(c, t)
    W.sub:SetText(("Wager %s  -  %s is heads, %s is tails"):format(money(t, t.wager), nm(t.seats[1]), nm(t.seats[2] or "?")))
    if t.phase == "seating" then
        W.cfInfo:SetText(("Waiting for players  %d / 2"):format(#t.seats))
        W.status:SetText(waitingNote(c, t))
    elseif t.phase == "flip" then
        if not W.flipping then W.cfInfo:SetText("Flipping...") end
        W.status:SetText("")
    elseif t.phase == "done" and not W.flipping then
        W.cfInfo:SetText(((t.winner == 1) and "HEADS" or "TAILS") .. "  -  " .. nm(t.seats[t.winner]) .. " wins")
    end
end

local function handLabel(hand, outcome, t)
    local total = ns.Games.blackjack.total(hand.cards)
    local text = ns.Games.blackjack.isBJ(hand) and "Blackjack" or total > 21 and "Bust" or tostring(total)
    if hand.doubled then text = text .. "  x2" end
    if outcome then
        text = text .. (outcome > 0 and ("  |cff40ff40+" .. ns.coins(outcome) .. "|r") or outcome < 0 and ("  |cffff6050-" .. ns.coins(-outcome) .. "|r") or "  push")
    end
    return text
end

local function refreshBlackjack(c, t)
    local lay = LAYOUT.blackjack
    W.sub:SetText(("Bet %s per hand  -  blackjack pays 3 to 2  -  dealer stands on 17"):format(money(t, t.wager)))
    local shoe = t.shoe
    W.shoeText:SetText(shoe and ("Shoe  %d / %d"):format(shoe.left, shoe.decks * 52) or "")
    local origin = { 440, 210 }
    beginFelt()
    if t.phase ~= "seating" and t.dealer then
        local d = t.dealer.cards
        local dx, dy = lay.cards[1][1], lay.cards[1][2]
        for i, card in ipairs(d) do placeCard("d" .. i, card, dx + (i - 1) * 30 - 15, dy, origin) end
        if #d == 1 and (t.phase == "dealing" or t.phase == "playing") then placeCard("d2", nil, dx + 15, dy) end
        if #d > 0 then label("dt", "Dealer  " .. handLabel(t.dealer), dx, dy + 56, 14) end
        for s = ns.Games.blackjack.first(t), #t.seats do
            local hands = t.hands and t.hands[s] or {}
            local spot = lay.cards[slotOf(t, s)]
            local ax, ay = spot[1], spot[2]
            for h, hand in ipairs(hands) do
                local hx = ax + (h - (#hands + 1) / 2) * 92
                for i, card in ipairs(hand.cards) do
                    placeCard(("p%d.%d.%d"):format(s, h, i), card, hx + (i - 1) * 16 - 8, ay - (i - 1) * 6, origin, .85)
                end
                if #hand.cards > 0 then
                    local active = t.turn and t.turn[1] == s and t.turn[2] == h
                    label(("pt%d.%d"):format(s, h), handLabel(hand, t.outcome and t.outcome[s] and t.outcome[s][h], t),
                        hx, ay + 52, 12, active and GOLD or nil)
                end
            end
        end
    end
    endFelt()
    if t.phase == "seating" then
        local house = t.practice and 0 or 1   -- a real table's seat 1 deals and does not play
        W.cardInfo:SetText(("Waiting for players  %d / %d"):format(#t.seats - house, t.maxSeats - house))
        W.status:SetText(waitingNote(c, t))
    elseif t.phase == "dealing" then
        W.cardInfo:SetText(t.reshuffled and "New shoe. Dealing..." or "Dealing...")
        W.status:SetText("")
    elseif t.phase == "playing" then
        local who = t.turn and t.seats[t.turn[1]]
        W.cardInfo:SetText(who and (ns.Rolls.same(who, ns.me()) and "YOUR HAND" or (nm(who):upper() .. "'S HAND")) or "")
        W.status:SetText(ns.Table.myActions() and "Hit, stand, double or split." or "")
    elseif t.phase == "dealer" then
        W.cardInfo:SetText("Dealer draws")
        W.status:SetText("")
    elseif t.phase == "done" then
        W.cardInfo:SetText("Hand over")
    end
end

local function refreshPoker(c, t)
    local lay = LAYOUT.poker
    W.sub:SetText(("Blinds %s / %s  -  everyone starts each hand with %s"):format(ns.coins(t.sb), ns.coins(t.bb), ns.coins(t.cap)))
    local mySeat = ns.Table.mySeat()
    local origin = { 0, 150 }
    beginFelt()
    if t.phase ~= "seating" and t.inHand then
        for i = 1, 5 do
            if t.board and t.board[i] then placeCard("b" .. i, t.board[i], (i - 3) * 64, 15, origin) end
        end
        local pot = 0
        for s = 1, #t.seats do pot = pot + (t.total and t.total[s] or 0) end
        label("pot", "Pot  " .. ns.coins(pot), 0, 82, 15, GOLD)
        for s = 1, #t.seats do
            local ax, ay = lay.cards[s][1], lay.cards[s][2]
            local hole
            if s == mySeat then hole = t.myHole or (t.inHand[s] and { false, false })
            elseif t.shown and t.shown[s] then hole = t.shown[s]
            elseif t.inHand[s] and t.phase ~= "done" then hole = { false, false } end
            if hole then
                for k = 1, 2 do placeCard(("h%d.%d"):format(s, k), hole[k] or nil, ax + (k - 1.5) * 34, ay, origin, .8) end
            end
            local left = t.cap - (t.total[s] or 0)
            local note = t.inHand[s] and (t.allin[s] and "ALL IN" or ("stack " .. ns.coins(left))) or "folded"
            local bet = (t.bet[s] or 0) > 0 and ("bet " .. ns.coins(t.bet[s])) or ""
            label(("n%d"):format(s), note, ax, ay - 46, 11)
            if bet ~= "" then label(("bt%d"):format(s), bet, ax, ay + 44, 12, GOLD) end
            if t.phase == "done" and t.won and (t.won[s] or 0) > 0 then
                local hn = t.scores and t.scores[s] and ns.Cards.handName(t.scores[s]) or ""
                label(("w%d"):format(s), ("wins %s  %s"):format(ns.coins(t.won[s]), hn), ax, ay + 44, 13, GOLD)
            elseif t.phase == "done" and t.scores and t.scores[s] then
                label(("w%d"):format(s), ns.Cards.handName(t.scores[s]), ax, ay + 44, 12)
            end
        end
        -- dealer button next to the button seat's cards
        local b = lay.cards[t.button] or lay.cards[1]
        W.button:SetPoint("CENTER", W.cards, "CENTER", b[1] + 62, b[2] + 10)
        W.button:Show(); W.buttonD:Show()
    else
        W.button:Hide(); W.buttonD:Hide()
    end
    endFelt()
    local streetName = { preflop = "PRE-FLOP", flop = "FLOP", turn = "TURN", river = "RIVER", showdown = "SHOWDOWN" }
    if t.phase == "seating" then
        W.cardInfo:SetText(("Waiting for players  %d / %d"):format(#t.seats, t.maxSeats))
        W.status:SetText(waitingNote(c, t))
    elseif t.phase == "betting" then
        W.cardInfo:SetText(streetName[t.street] or "")
        local who = t.toAct and t.seats[t.toAct]
        W.status:SetText(who and (ns.Rolls.same(who, ns.me()) and "Your turn." or (nm(who) .. " to act.")) or "")
    elseif t.phase == "done" then
        W.cardInfo:SetText(t.street == "showdown" and "SHOWDOWN" or "HAND OVER")
    end
end

-- poker raise amount controls
function UI.stepRaise(dir)
    local c = ns.Table.current()
    local can = ns.Table.myActions()
    if not (c and can and can.raise) then return end
    W.raiseTo = math.max(can.minTo, math.min(can.maxTo, (W.raiseTo or can.minTo) + dir * c.t.bb))
    W.pkAmount:SetText("to " .. ns.coins(W.raiseTo))
end
function UI.potRaise()
    local c = ns.Table.current()
    local can = ns.Table.myActions()
    if not (c and can and can.raise) then return end
    local pot = 0
    for s = 1, #c.t.seats do pot = pot + (c.t.total[s] or 0) end
    W.raiseTo = math.max(can.minTo, math.min(can.maxTo, c.t.curBet + pot + can.toCall))
    W.pkAmount:SetText("to " .. ns.coins(W.raiseTo))
end

local function refreshControls(c, t, mine)
    local g = t.game
    local between = t.phase == "seating" or t.phase == "done"
    local cards = g == "blackjack" or g == "poker"
    W.start:SetShown(c.hosting and between)
    W.start:SetLabel(cards and (t.phase == "done" and "Next hand" or "Deal") or (t.phase == "done" and "Rematch" or "Start"))
    W.start:SetEnabled(#t.seats >= ns.Games[g].minSeats)
    W.closeRolls:SetShown(c.hosting and g == "highlow" and (t.phase == "rolling" or t.phase == "tie"))
    W.roll:SetShown(g == "deathroll" or g == "highlow")
    W.roll:SetEnabled(mine and not ns.lockdown())
    W.bjBar:SetShown(g == "blackjack")
    W.pkBar:SetShown(g == "poker")
    W.handsBtn:SetShown(g == "poker")
    if not W.hands:IsShown() or g ~= "poker" then W.hands:SetShown(W.hands:IsShown() and g == "poker") end
    local can = cards and ns.Table.myActions()
    if g == "blackjack" then
        for a, b in pairs(W.bjButtons) do b:SetEnabled(can and can[a] and not ns.lockdown() or false) end
    elseif g == "poker" then
        local on = can and not ns.lockdown()
        W.pkFold:SetEnabled(on or false)
        W.pkCall:SetEnabled(on or false)
        W.pkCall:SetLabel(can and (can.check and "CHECK" or ("CALL " .. ns.coins(can.call or 0))) or "CHECK")
        for _, b in ipairs({ W.pkMinus, W.pkPlus, W.pkPot, W.pkRaise, W.pkAllin }) do b:SetEnabled(on and can.raise or false) end
        local key = can and table.concat({ t.round, t.street, t.curBet, t.toAct }, ":")
        if key ~= W.raiseKey then
            W.raiseKey = key
            W.raiseTo = can and can.minTo or nil
        end
        W.pkAmount:SetText(W.raiseTo and ("to " .. ns.coins(W.raiseTo)) or "")
    end
    W.music:SetLabel(GambleForeverDB.settings.mute and "Music: off" or "Music: on")
end

local function refresh()
    local c = ns.Table.current()
    if not view or not c then return end
    local t = c.t
    local g = t.game
    local mine = ns.Table.myTurn()
    W.settle:SetShown(W.tally and W.tally.tid == c.tid and W.tally.shown or false)
    layoutSeats(t)
    W.title:SetText(TITLES[g])
    W.dr:SetShown(g == "deathroll")
    W.hl:SetShown(g == "highlow")
    W.cf:SetShown(g == "coinflip")
    W.cards:SetShown(g == "blackjack" or g == "poker")
    W.shoe:SetShown(g == "blackjack"); W.shoeText:SetShown(g == "blackjack")
    if g ~= "deathroll" then W.danger = false; W.glow:Hide() end
    W.rulesText:SetText(RULES[g])

    for i, s in ipairs(seats) do
        local name = t.seats[i]
        if name and LAYOUT[g].seats[slotOf(t, i) or 0] then
            s:Show()
            s:SetPlayer(name)
            local state = seatState(t, i)
            if held[i] and (state == "win" or state == "out") then state = nil end
            if s.state ~= state then s:SetState(state) end
            s:SetNote(i == 1 and (g == "blackjack" and not t.practice and "dealer" or "host") or "")
        else
            s:Hide()
        end
    end

    if g == "deathroll" then refreshDeathroll(c, t, mine)
    elseif g == "highlow" then refreshHighLow(c, t, mine)
    elseif g == "coinflip" then refreshCoinflip(c, t)
    elseif g == "blackjack" then refreshBlackjack(c, t)
    elseif g == "poker" then refreshPoker(c, t) end
    refreshControls(c, t, mine)
end

---------------------------------------------------------------- per-game moments

local function hold(...) for _, s in ipairs({ ... }) do held[s] = true end end
local function release() wipe(held); refresh() end

local function flipCoin(ev, t)
    hold(1, 2)
    W.flipping = true
    ns.sound("chipLay1")
    W.cfInfo:SetText("")
    -- toss: a parabola up and down while it turns over 7 times and slows, ending on the winning face
    local turns = 2 * math.pi * 7 + (ev.winner == 1 and 0 or math.pi)
    local wobble = (math.random() - .5) * .5
    tween(1.9, function(p)
        local arc = 4 * p * (1 - p)
        local spin = 1 - (1 - p) ^ 2
        drawCoin(turns * spin, COIN_REST + 250 * arc, 1 + .3 * arc, wobble * arc)
    end, function()
        ns.sound("chipLay1")
        -- one small bounce, rocking on the edge, then it settles
        tween(.35, function(q)
            local hop = math.sin(q * math.pi)
            drawCoin(turns + .5 * hop * (1 - q), COIN_REST + 16 * hop, 1)
        end, function()
            drawCoin(turns, COIN_REST, 1)
            tween(.7, function(q) W.coinFlash:SetVertexColor(1, .8, .3, .9 * (1 - q)) end)
            ns.sound("chipsStack2")
            W.flipping = false
            release()
            local side = ev.winner == 1 and "HEADS" or "TAILS"
            W.cfInfo:SetText(side .. "  -  " .. nm(t.seats[ev.winner]) .. " wins")
            stinger(side, nm(t.seats[ev.winner]) .. " wins " .. money(t, t.wager), 1.6, GOLD)
            local w, l = seats[ev.winner], seats[3 - ev.winner]
            if w then w:Anim("cheer", 4); C_Timer.After(1, function() coinShower(w.ox, w.oy + 60, 50) end) end
            if l then l:Anim("cry", 4) end
        end)
    end)
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
    elseif t.game == "coinflip" then
        if ev.kind == "flip" then flipCoin(ev, t) end
        return
    elseif t.game == "blackjack" then
        if ev.kind == "act" and seats[ev.seat] then seats[ev.seat]:Anim("talk", 1.2) end
        if ev.done and t.results then
            local best, worst = 0, 0
            for s = ns.Games.blackjack.first(t), #t.seats do
                local r = t.results[s] or 0
                if seats[s] then seats[s]:Anim(r > 0 and "cheer" or r < 0 and "cry" or "idle", 3) end
                best, worst = math.max(best, r), math.min(worst, r)
            end
            local dt = ns.Games.blackjack.total(t.dealer.cards)
            stinger(dt > 21 and "DEALER BUSTS" or ("DEALER " .. dt), nil, 1.2, GOLD)
        end
        return
    elseif t.game == "poker" then
        if ev.kind == "act" then
            if seats[ev.seat] then seats[ev.seat]:Anim(ev.action == "fold" and "cry" or "talk", 1.2) end
            ns.sound(ev.action == "fold" and "cardSlide2" or "chipLay1")
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
        hold(ev.seat, ev.winner)
        throwDice(ev.seat, 1, prev, function()
            ns.sound("dieThrow1")
            release()
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
    if t.game == "poker" and t.phase == "done" and t.winners and #t.winners > 0 then
        local names = {}
        for _, s in ipairs(t.winners) do names[#names + 1] = nm(t.seats[s]) end
        local s1 = t.winners[1]
        local hn = t.scores and t.scores[s1] and ns.Cards.handName(t.scores[s1]) or "everyone else folded"
        stinger(#names > 1 and "SPLIT POT" or (names[1]:upper() .. " WINS"), hn, 1.6, GOLD)
        local w = seats[s1]
        if w then w:Anim("cheer", 4); coinShower(w.ox, w.oy + 60, 40) end
        ns.sound("chipsStack1")
    end
    -- running total for this table: every round's payments, netted per pair
    local c = ns.Table.current()
    if not c then return end
    if not (W.tally and W.tally.tid == c.tid) then W.tally = { tid = c.tid, debts = {}, rounds = 0 } end
    local tally = W.tally
    tally.rounds = tally.rounds + 1
    for _, d in ipairs(debts) do tally.debts[#tally.debts + 1] = d end
    if #tally.debts == 0 then return end
    C_Timer.After(2.6, function()   -- after the stinger, so it never gives the result away
        if W.tally ~= tally then return end
        tally.shown = true
        local p = W.settle
        local rows = ns.Ledger.pairNet(tally.debts)
        p.count = #rows
        for i, d in ipairs(rows) do
            local r = settleRow(i)
            r.who:SetText(nm(d.from) .. "  >  " .. nm(d.to)); r.amt:SetText(ns.coins(d.amount))
            r.who:Show(); r.amt:Show()
        end
        for i = #rows + 1, #p.rows do p.rows[i].who:Hide(); p.rows[i].amt:Hide() end
        p.list:SetHeight(math.max(1, #rows) * ROW_H)
        p.sf:SetVerticalScroll(0)
        p.foot:SetText(("%d %s  -  %s%s"):format(tally.rounds, tally.rounds == 1 and "round" or "rounds",
            t.chips and "chips only, no gold" or "trade it, the ledger marks it paid",
            #rows > SETTLE_ROWS and "  -  scroll" or ""))
        layoutSettle()
        p:Show()
    end)
end

---------------------------------------------------------------- lobby

local function ledgerText()
    local net = ns.Ledger.net(GambleForeverDB.ledger, ns.me())
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

local function tableLine(t)
    if t.game == "deathroll" then return ("Start number  %d"):format(t.start) end
    if t.game == "highlow" then return ("Rolls 1 - %d  (%s)"):format(t.range, unitNote(t)) end
    if t.game == "coinflip" then return "Seat 1 heads, seat 2 tails" end
    if t.game == "blackjack" then return "Six-deck shoe, dealer is seat 1" end
    if t.game == "poker" then return ("Blinds %s / %s"):format(ns.coins(t.sb), ns.coins(t.bb)) end
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
                row.tag:SetText(i == 1 and (t.game == "blackjack" and not t.practice and "dealer" or "host") or (ns.bots[name] and "practice bot")
                    or (ns.Rolls.same(name, ns.me()) and "you") or "")
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
    local wagerName = t.game == "poker" and "Big blind" or t.game == "blackjack" and "Bet per hand" or "Wager"
    L.roomInfo:SetText(("%s  %s%s\n%s\nSeats  %d / %d"):format(wagerName, ns.coins(t.wager), t.chips and "  (chips)" or "",
        tableLine(t), n, t.maxSeats))
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
    L.rulesBox:SetShown(L.rulesBox.on and not cur)
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
    L.immersive:SetOn(GambleForeverDB.settings.immersive)
end

local function field(parent, label, value, x, y, w)
    local fs = font(parent, FRIZ, 10, "", INK_RED)
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(label)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(w, 26)
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
    local b = skinButton(parent, label, w, 26, "dark", nil, 12)
    function b:SetOn(on)
        self.on = on and true or false
        self:SetStyle(self.on and "gold" or "dark")
        self:SetLabel(label .. (self.on and ": on" or ": off"))
    end
    b:SetScript("OnClick", function(self) self:SetOn(not self.on); if onChange then onChange(self.on) end end)
    b:SetOn(false)
    return b
end

local GAME_FIELDS = {
    deathroll = { wager = "WAGER", seats = "SEATS (2-6)", seatsDefault = "2", start = true },
    highlow = { wager = "WAGER = HIGHEST ROLL", seats = "SEATS (2-40)", seatsDefault = "10" },
    coinflip = { wager = "WAGER", seats = nil },
    blackjack = { wager = "BET PER HAND", seats = "SEATS (DEALER + 1-5)", seatsDefault = "6" },
    poker = { wager = "BIG BLIND", seats = "SEATS (2-6)", seatsDefault = "6" },
}
local PRACTICE = { deathroll = "test 1 deathroll", highlow = "test 9 highlow", coinflip = "test 1 coinflip",
    blackjack = "test 3 blackjack", poker = "test 3 poker" }

local function selectGame(id)
    L.game = id
    for gid, b in pairs(L.gameButtons) do b:SetStyle(gid == id and "gold" or "dark") end
    local f = GAME_FIELDS[id]
    L.gold.label:SetText(f.wager)
    L.start:SetShown(f.start or false); L.start.label:SetShown(f.start or false)
    L.seats:SetShown(f.seats ~= nil); L.seats.label:SetShown(f.seats ~= nil)
    if f.seats then L.seats.label:SetText(f.seats); L.seats:SetText(f.seatsDefault) end
    L.rulesTitle:SetText(ns.Games[id].name)
    L.rulesText:SetText(RULES[id])
end

local function buildLobby()
    lobby = CreateFrame("Frame", "GambleForeverLobby", UIParent)
    lobby:SetSize(768, 480)
    lobby:SetPoint("CENTER")
    lobby:SetFrameStrata("HIGH")
    lobby:SetMovable(true); lobby:EnableMouse(true)
    lobby:RegisterForDrag("LeftButton")
    lobby:SetScript("OnDragStart", lobby.StartMoving)
    lobby:SetScript("OnDragStop", lobby.StopMovingOrSizing)
    lobby:SetClampedToScreen(true)
    lobby:Hide()
    tinsert(UISpecialFrames, "GambleForeverLobby")
    local bg = lobby:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(art("frame"))
    bg:SetAllPoints()

    local title = font(lobby, MORPHEUS, 26, "OUTLINE", GOLD)
    title:SetPoint("TOP", 0, -14)
    title:SetText("GambleForever")
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
        SlashCmdList.GAMBLEFOREVER(PRACTICE[L.game])
    end, 13)
    practice:SetPoint("BOTTOMLEFT", 16, 14)
    local refreshBtn = skinButton(left, "Refresh", 100, 28, "dark", function() ns.Table.who(); refreshLobby() end, 13)
    refreshBtn:SetPoint("BOTTOMRIGHT", -16, 14)

    -- rules for the selected game, over the open-tables panel
    L.rulesBox = panel(30, -52, 417, 350)
    L.rulesBox:SetFrameLevel(left:GetFrameLevel() + 5)
    L.rulesTitle = font(L.rulesBox, MORPHEUS, 22, "", INK_RED)
    L.rulesTitle:SetPoint("TOP", 0, -12)
    L.rulesText = font(L.rulesBox, FRIZ, 11, "", INK)
    L.rulesText:SetPoint("TOPLEFT", 22, -44)
    L.rulesText:SetWidth(375)
    L.rulesText:SetJustifyH("LEFT")
    local rclose = skinButton(L.rulesBox, "Close", 80, 24, "dark", function() L.rulesBox.on = false; refreshLobby() end, 12)
    rclose:SetPoint("BOTTOMRIGHT", -14, 12)

    -- browse, right: open a table
    local right = panel(474, -52, 264, 350)
    local h2 = font(right, MORPHEUS, 22, "", INK_RED)
    h2:SetPoint("TOP", 0, -10)
    h2:SetText("Open a Table")
    L.gameButtons = {}
    local games = { { "deathroll", "Deathroll" }, { "highlow", "High-Low" }, { "coinflip", "Coinflip" },
        { "blackjack", "Blackjack" }, { "poker", "Hold'em" } }
    for i, g in ipairs(games) do
        local b = skinButton(right, g[2], 112, 26, "dark", function() selectGame(g[1]) end, 13)
        b:SetPoint("TOPLEFT", 16 + ((i - 1) % 2) * 120, -40 - math.floor((i - 1) / 2) * 29)
        L.gameButtons[g[1]] = b
    end
    local rulesBtn = skinButton(right, "Rules", 112, 26, "dark", function()
        L.rulesBox.on = not L.rulesBox.on; refreshLobby()
    end, 13)
    rulesBtn:SetPoint("TOPLEFT", 136, -98)
    -- wager in gold, silver and copper, each box marked with the game's coin icon
    L.gold = field(right, "WAGER", "0", 16, -132, 72)
    L.silver = field(right, " ", "50", 96, -132, 72)
    L.copper = field(right, " ", "0", 176, -132, 72)
    for _, p in ipairs({ { L.gold, "Gold" }, { L.silver, "Silver" }, { L.copper, "Copper" } }) do
        local icon = p[1]:CreateTexture(nil, "OVERLAY")
        icon:SetTexture("Interface\\MoneyFrame\\UI-" .. p[2] .. "Icon")
        icon:SetSize(13, 13)
        icon:SetPoint("RIGHT", -8, 0)
        p[1]:SetTextInsets(10, 24, 0, 0)
    end
    L.silver:SetMaxLetters(2)
    L.copper:SetMaxLetters(2)
    L.seats = field(right, "SEATS", "2", 16, -178, 112)
    L.start = field(right, "START NUMBER", "1000", 136, -178, 112)
    L.chips = toggle(right, "Chips", 112)
    L.chips:SetPoint("TOPLEFT", 16, -232)
    L.immersive = toggle(right, "Immersive", 112, function(on) GambleForeverDB.settings.immersive = on end)
    L.immersive:SetPoint("TOPLEFT", 136, -232)
    local open = skinButton(right, "Open Table", 232, 36, "gold", function()
        if ns.Table.current() then print("|cffffd100GambleForever|r leave your current table first."); return end
        local g = ns.Games[L.game]
        local seatsN = L.seats:IsShown() and math.max(2, math.min(g.maxSeats, tonumber(L.seats:GetText()) or 2)) or g.maxSeats
        local wager = (tonumber(L.gold:GetText()) or 0) * 10000 + math.min(99, tonumber(L.silver:GetText()) or 0) * 100
            + math.min(99, tonumber(L.copper:GetText()) or 0)
        if wager < 2 then print("|cffffd100GambleForever|r set a wager of at least 2 copper."); return end
        ns.Table.open({ game = L.game, wager = wager, start = tonumber(L.start:GetText()) or 1000,
            maxSeats = seatsN, chips = L.chips.on, stamp = time() })
    end, 18)
    open:SetPoint("BOTTOM", 0, 14)
    L.browse = { left, right }

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

    selectGame("deathroll")
    lobby:SetScript("OnShow", function() ns.Table.who(); refreshLobby() end)
end

---------------------------------------------------------------- trade reminder

local reminder
function UI.tradeReminder(partner)
    if not partner then if reminder then reminder:Hide() end; return end
    local amt
    for who, a in pairs(ns.Ledger.net(GambleForeverDB.ledger, ns.me())) do
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
    reminder.text:SetText(amt > 0 and ("GambleForever: %s owes you %s"):format(nm(partner), ns.coins(amt))
        or ("GambleForever: |cffff7050you owe|r %s %s"):format(nm(partner), ns.coins(-amt)))
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
        if W.banner then W.banner:SetText(("Warning: the host's table shows %s."):format(tostring(v))) end
    elseif what == "lobby" or what == "ledger" then
        refreshLobby()
    elseif what == "closed" then
        print("|cffffd100GambleForever|r the host closed the table.")
        refreshLobby()
    elseif what == "leave" then
        wipe(held)
        refreshLobby()
    end
end
