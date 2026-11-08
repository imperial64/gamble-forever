-- UI smoke test: loads the whole addon (UI and Core included) against a stand-in client and
-- plays a practice game of every table through the real slash command, buttons and events.
-- It cannot tell you anything looks right; it catches nil calls and typos before the game does.
-- Run: luajit tests/ui_smoke.lua
local ROOT = arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]") or "."
local ADDON = ROOT .. "/addons/GambleForever/"
local ME = "Efe Imperial"

---------------------------------------------------------------- stand-in client

local timers, frames, sent, rolls = {}, {}, {}, {}
local methods = {}
local function obj(kind)
    local o = { kind = kind, shown = true, scripts = {}, w = 100, h = 100 }
    -- WoW widget methods are Capitalized; the addon's own fields are lowercase and start out nil
    return setmetatable(o, { __index = function(_, k)
        if methods[k] then return methods[k] end
        if type(k) == "string" and k:match("^%u") then return function() end end
    end })
end
methods.SetScript = function(s, k, f) s.scripts[k] = f end
methods.GetScript = function(s, k) return s.scripts[k] end
methods.Show = function(s) s.shown = true; if s.scripts.OnShow then s.scripts.OnShow(s) end end
methods.Hide = function(s)
    local was = s.shown
    s.shown = false
    if was and s.scripts.OnHide then s.scripts.OnHide(s) end
end
methods.SetShown = function(s, v) if v then s:Show() else s:Hide() end end
methods.IsShown = function(s) return s.shown end
methods.IsVisible = methods.IsShown
methods.GetFrameLevel = function() return 1 end
methods.GetWidth = function(s) return s.w end
methods.GetHeight = function(s) return s.h end
methods.SetSize = function(s, w, h) s.w, s.h = w, h end
methods.SetWidth = function(s, w) s.w = w end
methods.SetHeight = function(s, h) s.h = h end
methods.GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end
methods.IsEnabled = function(s) return s.enabled ~= false end
methods.SetEnabled = function(s, v)
    s.enabled = v and true or false
    local f = s.scripts[v and "OnEnable" or "OnDisable"]
    if f then f(s) end
end
methods.CreateTexture = function() return obj("Texture") end
methods.CreateFontString = function() return obj("FontString") end
methods.CreateAnimationGroup = function() return obj("AnimationGroup") end
methods.CreateActor = function() return obj("Actor") end
methods.IsLoaded = function() return false end
methods.SetText = function(s, t)
    assert(t == nil or type(t) == "string" or type(t) == "number", "SetText with a " .. type(t))
    s.text = t
end
methods.GetText = function(s) return s.text end
methods.SetFont = function() return true end
methods.GetFontString = function(s) s.fs = s.fs or obj("FontString"); return s.fs end
methods.RegisterEvent = function(s, ev) local e = rawget(s, "events") or {}; e[ev] = true; rawset(s, "events", e) end
methods.SetTextColor = function(_, r, g, b) assert(type(r) == "number" and type(g) == "number" and type(b) == "number", "bad colour") end
methods.SetVertexColor = methods.SetTextColor
methods.SetColorTexture = function(_, r, g, b) assert(type(r) == "number" and type(g) == "number" and type(b) == "number", "bad colour") end

function CreateFrame(kind, name)
    local o = obj(kind)
    frames[#frames + 1] = o
    if name then _G[name] = o end
    return o
end
UIParent, WorldFrame, TradeFrame = obj("Frame"), obj("Frame"), obj("Frame")
UISpecialFrames, SlashCmdList = {}, {}
local chatLines = {}
DEFAULT_CHAT_FRAME = obj("Frame")
DEFAULT_CHAT_FRAME.AddMessage = function(_, m) chatLines[#chatLines + 1] = m end
function SendChatMessage() error("solo table sent a chat line") end
RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)"
LE_GAME_ERR_TRADE_COMPLETE = 999
RAID_CLASS_COLORS = { PALADIN = { r = .96, g = .55, b = .73 } }
CLASS_ICON_TCOORDS = { PALADIN = { 0, .25, .5, .75 } }
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
C_CVar = { GetCVar = function() return "0" end, SetCVar = function() end }
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return 0 end,
    InChatMessagingLockdown = function() return false end,
    -- solo, nothing may go out: Forever answers each self-whisper with a "No player named" error
    SendAddonMessage = function(prefix, msg, ch, target) error("solo table sent over " .. tostring(ch)) end,
}
function UnitName(u) if u == "player" then return "Efe" end end
function UnitExists(u) return u == "player" end
function UnitIsVisible(u) return u == "player" end
function UnitClass() return "Paladin", "PALADIN" end
function IsInRaid() return false end
function IsInGroup() return false end
function InCombatLockdown() return false end
function GetCameraZoom() return 10 end
function CameraZoomIn() end
function CameraZoomOut() end
function PlayMusic() end
function StopMusic() end
function PlaySoundFile() return true end
function GetTime() return os.clock() end
function time() return os.time() end
function RandomRoll(lo, hi) rolls[#rolls + 1] = { lo, hi } end
function CreateColor(r, g, b, a) return { r, g, b, a } end
function GetCoinTextureString(c) return tostring(c) .. "c" end
function strsplit(sep, s) local out = {}; for p in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = p end; return unpack(out) end
function tinsert(t, v) table.insert(t, v) end
function wipe(t) for k in pairs(t) do t[k] = nil end; return t end
function issecretvalue() return false end
function GetPlayerTradeMoney() return 0 end
function GetTargetTradeMoney() return 0 end
function date() return "00:00:00" end
print_ = print

---------------------------------------------------------------- load the addon

local ns = {}
local toc = io.open(ADDON .. "GambleForever.toc"):read("*a")
for file in toc:gmatch("\n([%w_]+%.lua)") do
    assert(loadfile(ADDON .. file))("GambleForever", ns)
end
local function fire(ev, ...)
    for _, f in ipairs(frames) do
        local evs = rawget(f, "events")
        if evs and evs[ev] and f.scripts.OnEvent then f.scripts.OnEvent(f, ev, ...) end
    end
end
-- whispers to myself come back as my own addon messages (that is how a solo table talks)
local function deliver()
    while #sent > 0 do
        local m = table.remove(sent, 1)
        fire("CHAT_MSG_ADDON", m.prefix, m.msg, m.ch, ME)
    end
end
local function tick(n)
    local view = _G.GambleForeverTableView
    for _ = 1, n or 3 do
        deliver()
        local ts = timers; timers = {}
        for _, fn in ipairs(ts) do fn() end
        if view and view.scripts.OnUpdate then for _ = 1, 4 do view.scripts.OnUpdate(view, .2) end end
        deliver()
    end
end
local function serverRolls()
    while #rolls > 0 do
        local r = table.remove(rolls, 1)
        fire("CHAT_MSG_SYSTEM", RANDOM_ROLL_RESULT:format(ME, math.random(r[1], r[2]), r[1], r[2]))
    end
end

fire("ADDON_LOADED", "GambleForever")
fire("PLAYER_LOGIN")
tick()
ns.UI.toggleLobby()

local passed, failed = 0, 0
local function play(cmd, decide)
    local ok, err = pcall(function()
        SlashCmdList.GAMBLEFOREVER(cmd)
        tick()
        ns.Table.startGame()
        for _ = 1, 400 do
            tick(1)
            serverRolls()
            decide()
            local c = ns.Table.current()
            if c and c.t.phase == "done" and #timers == 0 and #rolls == 0 then break end
        end
        local c = assert(ns.Table.current(), "no table")
        assert(c.t.phase == "done", "game did not finish, phase " .. tostring(c.t.phase) .. " turn " .. tostring(c.t.turn) .. " cur " .. tostring(c.t.cur) .. " hist " .. #(c.t.history or {}) .. " timers " .. #timers)
        -- chat tables: someone joins between rounds, and the open table view takes the new seat
        local n = #c.t.seats
        ns.bots["Ostrik Gravelmaw"] = true
        ns.Table.chatCommand("Ostrik Gravelmaw", "join")
        tick()
        assert(not c.chat or n == c.t.maxSeats or #c.t.seats == n + 1, "the late join was not seated")
        ns.Table.startGame()   -- rematch / next hand
        for _ = 1, 30 do tick(1); serverRolls(); decide() end
        ns.Table.close()
        tick()
    end)
    if ok then passed = passed + 1; print("  ok    " .. cmd)
    else failed = failed + 1; print("  FAIL  " .. cmd .. ": " .. tostring(err)) end
end

math.randomseed(7)
print("UI smoke")
play("test 1 deathroll", function() if ns.Table.myTurn() then ns.Table.rollMine() end end)
play("test 5 deathroll", function() if ns.Table.myTurn() then ns.Table.rollMine() end end)   -- 5 payments: Settle Up scrolls
play("test 9 highlow", function() if ns.Table.myTurn() then ns.Table.rollMine() end end)
play("test 1 coinflip", function() end)
play("test 3 blackjack", function()
    local can = ns.Table.myActions()
    if can then ns.Table.act(math.random() < .5 and "hit" or "stand") end
end)
play("test 3 poker", function()
    local can = ns.Table.myActions()
    if can then
        if can.check then ns.Table.act("check") else ns.Table.act("call") end
        ns.UI.stepRaise(1); ns.UI.potRaise()
    end
end)
-- "chat": the bots count as chat players, so every game is narrated (into my own chat frame)
for _, g in ipairs({ "deathroll", "highlow", "coinflip", "blackjack", "poker" }) do
    local before = #chatLines
    play("test 3 " .. g .. " chat", function()
        local can = ns.Table.myActions()
        if ns.Table.myTurn() then ns.Table.rollMine() end
        if can then ns.Table.act(can.check and "check" or can.call and "call" or "stand") end
    end)
    for _ = 1, 200 do tick(1) end   -- let the one-line-a-second queue drain
    local n = 0
    for i = before + 1, #chatLines do
        local l = chatLines[i]
        n = n + 1
        if #l > 300 or l:find("nil") then failed = failed + 1; print("  FAIL  bad chat line: " .. l) end
    end
    if n < 2 then failed = failed + 1; print("  FAIL  " .. g .. " chat narrated " .. n .. " lines") end
end

-- Immersive off: the table is a window that survives combat and closes on Esc (UISpecialFrames hides it)
local ok, err = pcall(function()
    GambleForeverDB.settings.immersive = false
    SlashCmdList.GAMBLEFOREVER("test 1 deathroll")
    tick()
    ns.Table.startGame()
    tick()
    local view = _G.GambleForeverTableView
    assert(ns.Stage.isOn() and view:IsShown(), "window did not open")
    fire("PLAYER_REGEN_DISABLED")
    assert(ns.Stage.isOn() and view:IsShown(), "window closed in combat")
    view:Hide()   -- what CloseSpecialWindows does on Esc
    assert(not ns.Stage.isOn(), "hiding the window did not leave the table view")
    SlashCmdList.GAMBLEFOREVER("table")
    assert(ns.Stage.isOn() and view:IsShown(), "/gf table did not reopen the window")
    ns.Table.close()
    tick()
    assert(not view:IsShown(), "closing the table left the window up")
    GambleForeverDB.settings.immersive = true
end)
if ok then passed = passed + 1; print("  ok    window mode")
else failed = failed + 1; print("  FAIL  window mode: " .. tostring(err)) end
if os.getenv("SHOW_CHAT") then for _, l in ipairs(chatLines) do print(l) end end   -- read the narration
print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
