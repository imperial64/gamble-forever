-- Wires the pure modules to the client: events, addon messages, rolls, ledger, slash command.
local ADDON, ns = ...
local PREFIX = "Deathroll"
local rollPattern = ns.Rolls.pattern(RANDOM_ROLL_RESULT)
local myFull           -- "Efe Imperial": learned from my own roll lines and addon echoes
ns.bots = {}           -- /dr test seats

local function isSecret(v) return issecretvalue ~= nil and issecretvalue(v) or false end
function ns.lockdown() return C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() or false end
function ns.me() return myFull or UnitName("player") end
function ns.after(sec, fn) C_Timer.After(sec, fn) end
function ns.roll(lo, hi) RandomRoll(lo, hi) end
-- poker deck seed: secret until the hand ends
function ns.seed()
    return ("%d-%d-%d"):format(math.random(1, 2 ^ 30), math.floor(GetTime() * 1000), math.random(1, 2 ^ 30))
end
ns.media = "Interface\\AddOns\\Deathroll\\media\\"

-- Amounts are copper everywhere (wagers, ledger, trades). Shown with the game's coin icons.
function ns.coins(copper)
    copper = math.floor(copper or 0)
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local out = {}
    if g > 0 then out[#out + 1] = g .. "g" end
    if s > 0 then out[#out + 1] = s .. "s" end
    if c > 0 or #out == 0 then out[#out + 1] = c .. "c" end
    return table.concat(out, " ")
end

function ns.sound(name)
    if DeathrollDB and DeathrollDB.settings.mute then return end
    PlaySoundFile(ns.media .. "sfx\\" .. name .. ".ogg", "SFX")
end

---------------------------------------------------------------- sending

-- Group channel. Solo (practice tables) a message is handed straight back to me: Forever answers
-- an addon whisper to my own name with "No player named 'Efe' is currently playing" for every send.
-- A send the client refuses (throttle, chat lockdown) is retried each second for a while.
local queue, ticking = {}, false
local function channel()
    if IsInRaid() then return "RAID" elseif IsInGroup() then return "PARTY" end
end
-- Whisper target for a seated player: the character name the client knows for their unit
-- (with a realm if one is attached), else the first word of the name shown on rolls.
local function whisperTarget(name)
    local u = ns.Scene.unitFor(name)
    if u then
        local n, realm = UnitName(u)
        if n then return realm and realm ~= "" and (n .. "-" .. realm) or n end
    end
    return name:match("^[^ ]+")
end

local function pump()
    ticking = false
    while #queue > 0 do
        local m = queue[1]
        local ch, target = channel(), nil
        if m.to then ch, target = "WHISPER", whisperTarget(m.to) end
        if not ch then
            local msg = m.msg
            C_Timer.After(0, function() ns.Table.onMessage(msg, ns.me()) end)
        else
            local res = C_ChatInfo.SendAddonMessage(PREFIX, m.msg, ch, target)
            if res ~= nil and res ~= 0 and res ~= true then
                m.tries = m.tries + 1
                if m.tries > 30 then table.remove(queue, 1) end
                ticking = true
                C_Timer.After(1, pump)
                return
            end
        end
        table.remove(queue, 1)
    end
end
function ns.send(msg)
    queue[#queue + 1] = { msg = msg, tries = 0 }
    if not ticking then pump() end
end
function ns.whisper(name, msg)
    queue[#queue + 1] = { msg = msg, tries = 0, to = name }
    if not ticking then pump() end
end

---------------------------------------------------------------- events from the pure modules

-- Practice bots: they roll whenever the rules let them, and play cards with simple habits.
local botStep = {}

local function bjChoice(t, seat, can)
    local hand = t.hands[seat][t.turn[2]]
    local total = ns.Games.blackjack.total(hand.cards)
    local uv = t.dealer.cards[1] and ns.Cards.value(t.dealer.cards[1]) or 10
    local up = uv == 14 and 11 or math.min(uv, 10)
    if can.split and ns.Cards.value(hand.cards[1]) == 14 then return "split" end
    if can.double and (total == 10 or total == 11) then return "double" end
    if total <= 11 or (total <= 16 and up >= 7) then return "hit" end
    return "stand"
end

local function pokerChoice(t, can)
    local r = math.random()
    if can.check then
        if r < .2 then return "raise", can.minTo end
        return "check"
    end
    if can.toCall <= 3 * t.bb then return r < .85 and "call" or "fold" end
    return r < .4 and "call" or "fold"
end

local function botTurn()
    local c = ns.Table.current()
    if not (c and c.hosting) then return end
    local g, t = ns.Games[c.t.game], c.t
    if g.actions then
        for seat, name in ipairs(t.seats) do
            local can = ns.bots[name] and g.actions(t, seat)
            local step = table.concat({ t.round or 0, t.phase, t.street or "", seat, t.draws or 0, t.curBet or 0,
                t.turn and t.turn[2] or 0, t.need and 1 or 0 }, ":")
            if can and botStep[name] ~= step then
                botStep[name] = step
                C_Timer.After(1 + math.random(), function()
                    if ns.Table.current() ~= c or not g.actions(t, seat) then return end
                    local now = g.actions(t, seat)
                    if t.game == "blackjack" then ns.Table.hostAct(seat, bjChoice(t, seat, now))
                    else ns.Table.hostAct(seat, pokerChoice(t, now)) end
                end)
            end
        end
        return
    end
    for name in pairs(ns.bots) do
        local lo, hi = g.rangeFor(t, name)
        local step = table.concat({ t.round or 0, t.phase, t.cur or 0, tostring(t.tieRolls) }, ":")
        if lo and botStep[name] ~= step then
            botStep[name] = step
            C_Timer.After(.8 + math.random() * 1.4, function()
                local lo2, hi2 = g.rangeFor(t, name)
                if ns.Table.current() == c and lo2 == lo and hi2 == hi then
                    ns.Table.onRoll(name, math.random(lo, hi), lo, hi)
                end
            end)
        end
    end
end

function ns.emit(what, ...)
    if what == "settled" then
        local t, debts = ...
        if not t.chips then
            for _, d in ipairs(debts) do
                if ns.Rolls.same(d.from, ns.me()) or ns.Rolls.same(d.to, ns.me()) then
                    ns.Ledger.add(DeathrollDB.ledger, d.from, d.to, d.amount, time())
                end
            end
        end
    elseif what == "state" then
        botTurn()
        -- the host's Start (or Rematch) pulls everyone seated into the table view, once per round
        local c = ns.Table.current()
        if c and c.t.phase ~= "seating" and c.entered ~= c.t.round then
            c.entered = c.t.round
            ns.UI.hideLobby()
            ns.Stage.enter()
        end
    elseif what == "enter" then
        ns.UI.showRoom()   -- opening or joining a table lands in the waiting room
    elseif what == "leave" or what == "closed" then
        wipe(ns.bots)
        ns.Stage.leave(what)
    end
    if ns.UI then ns.UI.handle(what, ...) end
end

---------------------------------------------------------------- trade: ledger reminder and payment

local trade = {}
local function tradePartner() return UnitName("NPC") end

local function onTrade(ev, ...)
    if ev == "TRADE_SHOW" then
        trade = { partner = tradePartner() }
        ns.UI.tradeReminder(trade.partner)
    elseif ev == "TRADE_ACCEPT_UPDATE" then
        trade.give = GetPlayerTradeMoney() or 0
        trade.get = GetTargetTradeMoney() or 0
    elseif ev == "UI_INFO_MESSAGE" then
        local kind = ...
        if kind == LE_GAME_ERR_TRADE_COMPLETE and trade.partner then
            local L = DeathrollDB.ledger
            local paid = 0
            if (trade.give or 0) > 0 then paid = paid + ns.Ledger.pay(L, ns.me(), trade.partner, trade.give) end
            if (trade.get or 0) > 0 then paid = paid + ns.Ledger.pay(L, trade.partner, ns.me(), trade.get) end
            if paid > 0 then print(("|cffffd100Deathroll|r ledger: %s with %s marked paid."):format(ns.coins(paid), trade.partner)) end
            trade = {}
            ns.UI.handle("ledger")
        end
    elseif ev == "TRADE_CLOSED" then
        ns.UI.tradeReminder(nil)
    end
end

---------------------------------------------------------------- client events

local f = CreateFrame("Frame")
for _, ev in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "CHAT_MSG_ADDON", "CHAT_MSG_SYSTEM",
    "ADDON_RESTRICTION_STATE_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_DEAD", "READY_CHECK", "GROUP_ROSTER_UPDATE",
    "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED", "UI_INFO_MESSAGE" }) do
    pcall(f.RegisterEvent, f, ev)   -- an event this client lacks raises; skip it
end

f:SetScript("OnEvent", function(_, ev, ...)
    if ev == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        DeathrollDB = DeathrollDB or {}
        local db = DeathrollDB
        db.ledger = db.ledger or {}
        if db.ledgerUnit ~= "copper" then   -- the first build kept whole gold
            for _, e in ipairs(db.ledger) do e.amount, e.left = e.amount * 10000, e.left * 10000 end
            db.ledgerUnit = "copper"
        end
        db.settings = db.settings or {}
        if db.settings.music == nil then db.settings.music = true end
        if db.settings.immersive == nil then db.settings.immersive = true end
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        ns.Stage.restoreLeftovers()
    elseif ev == "PLAYER_LOGIN" then
        ns.UI.init()
        ns.Table.who()   -- its echo tells us our full "First Last" name before any table opens
    elseif ev == "PLAYER_LOGOUT" then
        ns.Stage.restoreCamera()
    elseif ev == "CHAT_MSG_ADDON" then
        local prefix, msg, _, sender = ...
        if isSecret(prefix) or isSecret(msg) or isSecret(sender) or prefix ~= PREFIX then return end
        if not myFull and ns.Rolls.same(sender, UnitName("player")) then myFull = sender end
        ns.Table.onMessage(msg, sender)
    elseif ev == "CHAT_MSG_SYSTEM" then
        local text = ...
        if isSecret(text) then return end
        local name, v, lo, hi = ns.Rolls.parse(rollPattern, text)
        if not name then return end
        if not myFull and ns.Rolls.same(name, UnitName("player")) then myFull = name end
        ns.Table.onRoll(name, v, lo, hi)
    elseif ev == "ADDON_RESTRICTION_STATE_CHANGED" then
        ns.UI.handle("lockdown", ns.lockdown())
    elseif ev == "PLAYER_REGEN_DISABLED" or ev == "PLAYER_DEAD" or ev == "READY_CHECK" then
        ns.Stage.leave("interrupt")
    elseif ev == "PLAYER_REGEN_ENABLED" then
        if not UIParent:IsShown() and not ns.Stage.isOn() then UIParent:Show() end
    elseif ev == "GROUP_ROSTER_UPDATE" then
        ns.UI.handle("roster")
    else
        onTrade(ev, ...)
    end
end)

---------------------------------------------------------------- slash command

local BOT_NAMES = { "Grizzlenut Sparkfuse", "Thoradin Ironbrew", "Mirabelle Ashvale", "Kaelra Moonwhisper",
    "Fennick Brightwhisk", "Dorn Stonehelm", "Ysolde Fairwind", "Halvar Deepforge", "Sirelle Dawnmere",
    "Bramble Tinkerspan", "Ostrik Gravelmaw", "Velia Starfall" }

SLASH_DEATHROLL1 = "/dr"
SLASH_DEATHROLL2 = "/deathroll"
SlashCmdList.DEATHROLL = function(m)
    local cmd, a, b = strsplit(" ", (m or ""):lower())
    if cmd == "test" then   -- /dr test [bots] [deathroll|highlow|coinflip|blackjack|poker]
        if ns.Table.current() then ns.Table.close() end
        local gameId = ns.Games[b or ""] and b or "deathroll"
        local g = ns.Games[gameId]
        -- practice Blackjack: the house deals from the dealer spot, so one seat fewer
        local max = gameId == "blackjack" and g.maxSeats - 1 or g.maxSeats
        ns.Table.open({ game = gameId, wager = 2550, start = 1000, maxSeats = max, chips = true, practice = true, stamp = time() })   -- 25s 50c
        for i = 1, math.min(tonumber(a) or 1, max - 1, #BOT_NAMES) do
            ns.bots[BOT_NAMES[i]] = true
            ns.Table.addBot(BOT_NAMES[i])
        end
    elseif cmd == "leave" then
        ns.Table.close()
    elseif cmd == "table" then
        ns.Stage.enter()
    else
        ns.UI.toggleLobby()
    end
end

-- addon compartment (minimap drawer)
function Deathroll_OnAddonCompartmentClick() ns.UI.toggleLobby() end
