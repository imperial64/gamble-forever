-- UI smoke test: loads the whole addon (UI and Core included) against a stand-in client and
-- plays a practice game of every table through the real slash command, buttons and events.
-- It cannot tell you anything looks right; it catches nil calls and typos before the game does.
-- Run: luajit tests/ui_smoke.lua
local ROOT = arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]") or "."
local ADDON = ROOT .. "/addons/Deathroll/"
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
methods.Hide = function(s) s.shown = false end
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
local toc = io.open(ADDON .. "Deathroll.toc"):read("*a")
for file in toc:gmatch("\n([%w_]+%.lua)") do
    assert(loadfile(ADDON .. file))("Deathroll", ns)
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
    local view = _G.DeathrollTableView
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

fire("ADDON_LOADED", "Deathroll")
fire("PLAYER_LOGIN")
tick()
ns.UI.toggleLobby()

local passed, failed = 0, 0
local function play(cmd, decide)
    local ok, err = pcall(function()
        SlashCmdList.DEATHROLL(cmd)
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
        assert(c.t.phase == "done", "game did not finish, phase " .. tostring(c.t.phase))
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
print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
