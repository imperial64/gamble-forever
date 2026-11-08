-- Deathroll Spike: throwaway checks that the Deathroll design relies on, on WoW Forever.
-- Every result is printed and also kept in DeathrollSpikeDB (written on /reload or logout).
--   a  roll text in CHAT_MSG_SYSTEM is readable (not a secret value)
--   b  RandomRoll works from a click, a typed command, a timer, and an addon-message handler
--   c  addon messages and rolls reach other party members
--   d  ModelScene shows party members, and which animation IDs look right
--   e  table mode: hide the UI, move the camera, then restore everything
--   f  the chat lockdown is detected
--   g  the Alliance tavern music plays by file ID
--   h  the game's own fonts load by path

local PREFIX = "DRSpike"
local DB
local R = { rolls = 0, secret = 0, expect = {}, pongs = {}, remote = {}, blocked = {}, lockEvents = 0, actorsLoaded = 0, music = "not tried", fonts = {} }

local function lockdown()
    return C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() or false
end
local function isSecret(v) return issecretvalue ~= nil and issecretvalue(v) or false end

local screenLog, screenLines = nil, {}   -- on-stage copy of the log, since chat is hidden in table mode

local function log(fmt, ...)
    local msg = fmt:format(...)
    print("|cffffd100DRS|r " .. msg)
    if DB then
        DB.log[#DB.log + 1] = date("%H:%M:%S") .. " " .. msg
        if #DB.log > 400 then table.remove(DB.log, 1) end
    end
    screenLines[#screenLines + 1] = msg
    if #screenLines > 9 then table.remove(screenLines, 1) end
    if screenLog then screenLog:SetText(table.concat(screenLines, "\n")) end
end

-- a: roll parser built from the client's own format string, so locale wording does not matter.
local rollPattern
do
    local s = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
    s = s:gsub("([%(%)%.%-%+%[%]%^%$%?%*])", "%%%1")
    s = s:gsub("%%s", "(.+)")
    s = s:gsub("%%d", "(%%d+)")
    rollPattern = "^" .. s .. "$"
end

local function shortName(n) return (n:match("^[^%-]+")) end

local function onSystem(text)
    if isSecret(text) then
        R.secret = R.secret + 1
        log("CHECK a: a system message arrived as a SECRET value (lockdown=%s)", tostring(lockdown()))
        return
    end
    local name, roll, lo, hi = text:match(rollPattern)
    if not name then return end
    roll, lo, hi = tonumber(roll), tonumber(lo), tonumber(hi)
    R.rolls = R.rolls + 1
    log("CHECK a: roll read: %s rolled %d (%d-%d)", name, roll, lo, hi)
    -- Forever characters have a surname, so the roll line may say "Efe Imperial" while UnitName says "Efe".
    local me = UnitName("player")
    if shortName(name) == me or name:find(me, 1, true) == 1 then
        local e = R.expect[hi]
        if e and not e.ok then
            e.ok = true
            log("CHECK b: RandomRoll from [%s] WORKS, server result after %.2fs", e.src, GetTime() - e.t)
        end
    else
        R.remote[name] = (R.remote[name] or 0) + 1
        log("CHECK c: saw a roll from another player: %s", name)
    end
end

-- b: each source uses its own range, so the result line tells us which call produced it.
local RANGE = { typed = 776, button = 775, timer = 777, addonmsg = 778 }
local function tryRoll(src)
    local max = RANGE[src]
    R.expect[max] = { src = src, t = GetTime() }
    local ok, err = pcall(RandomRoll, 1, max)
    log("CHECK b: RandomRoll(1,%d) from [%s]: call %s %s", max, src, ok and "ran" or "ERRORED", err and tostring(err) or "")
    C_Timer.After(4, function()
        local e = R.expect[max]
        if e and not e.ok then log("CHECK b: no roll result 4s after [%s]: probably BLOCKED", src) end
    end)
end

-- c: addon messages
local function groupChannel()
    if IsInRaid() then return "RAID" elseif IsInGroup() then return "PARTY" end
end
local function send(msg, channel, target)
    if not channel then
        channel = groupChannel()
        if not channel then channel, target = "WHISPER", UnitName("player") end
    end
    local res = C_ChatInfo.SendAddonMessage(PREFIX, msg, channel, target)
    log("sent %s on %s: result %s, lockdown=%s", msg, channel, tostring(res), tostring(lockdown()))
end

local function onAddon(prefix, msg, channel, sender)
    if isSecret(prefix) or isSecret(msg) or isSecret(sender) then
        log("CHECK f: an addon message arrived with SECRET fields")
        return
    end
    if prefix ~= PREFIX then return end
    local cmd, arg = strsplit(":", msg)
    if cmd == "PING" then
        if channel == "WHISPER" then send("PONG:" .. arg, "WHISPER", sender) else send("PONG:" .. arg) end
    elseif cmd == "PONG" then
        local rtt = GetTime() - (tonumber(arg) or GetTime())
        R.pongs[sender] = rtt
        log("CHECK c: PONG from %s via %s, round trip %.2fs", sender, channel, rtt)
    elseif cmd == "DEAL" then
        log("DEAL request from %s", sender)
        tryRoll("addonmsg")
    end
end

-- d: ModelScene seats
local ANIMS = {
    { 0, "Stand" }, { 60, "Talk" }, { 68, "Cheer?" }, { 70, "Laugh?" }, { 77, "Cry?" }, { 80, "Applaud?" },
    { 69, "Dance?" }, { 66, "Bow?" }, { 67, "Wave?" }, { 1, "Death" }, { 97, "SitGround?" },
    { 100, "SitChairLow?" }, { 101, "SitChairMed?" }, { 102, "SitChairHigh?" }, { 75, "Kneel?" },
}
R.anim, R.camDist, R.camZ = 1, 7, 1

local stage, scene, animLabel
local fitCamera

local function setAnim(id, label)
    if not scene then return end
    for _, a in ipairs(scene.actors) do a:SetAnimation(id, 0, 1) end
    if animLabel then animLabel:SetText(("Animation %d  %s"):format(id, label or "")) end
    log("CHECK d: animation %d %s on all seats. Note which ID looks like what.", id, label or "")
end

local function placeCamera()
    if scene then scene:SetCameraPosition(R.camDist, 0, R.camZ) end
end

R.spacing, R.fov = 1.5, 30   -- spacing is in normalized units: the tallest model is 2 tall
local function bounds(a)
    if not a.GetActiveBoundingBox then return end
    local x, y, z, xx, yy, zz = a:GetActiveBoundingBox()
    if type(x) == "table" and type(y) == "table" then
        local lo, hi = x, y
        x, y, z = lo:GetXYZ(); xx, yy, zz = hi:GetXYZ()
    end
    if type(z) == "number" and type(zz) == "number" and zz > z then return z, zz end
end

-- Frame every seat the way ForeverProfessions does: scale all models by one factor so the
-- tallest is 2 units (races keep their relative size), centre them on z=0, then fit the camera.
-- The FOV axis is undocumented, so assume a diagonal FOV, which is the most conservative.
function fitCamera()
    if not scene then return end
    local shown, raw = {}, {}
    for _, a in ipairs(scene.actors) do
        if a:IsShown() then
            shown[#shown + 1] = a
            if a:IsLoaded() then
                a:SetRequestedScale(1); a:SetScale(1)
                local z, zz = bounds(a)
                if z then raw[a] = { z, zz } end
            end
        end
    end
    local tallest = 0
    for _, b in pairs(raw) do tallest = math.max(tallest, b[2] - b[1]) end
    if tallest <= 0 then log("CHECK d: no model bounds yet, camera not fitted"); return end
    local s = 2 / tallest
    for i, a in ipairs(shown) do
        local b = raw[a]
        a:SetRequestedScale(s); a:SetScale(s)
        a:SetPosition(0, (i - (#shown + 1) / 2) * R.spacing, b and -(b[1] + b[2]) / 2 * s or -1)
    end
    if R.manualCam then placeCamera(); return end
    local aspect = math.max(1, scene:GetWidth()) / math.max(1, scene:GetHeight())
    local vt = math.tan(math.rad(R.fov) / 2) / math.sqrt(1 + aspect * aspect)
    local ht = vt * aspect
    R.camDist = math.max(1 / (vt * .85), (#shown * R.spacing / 2) / (ht * .9))
    R.camZ = 0
    placeCamera()
    log("CHECK d: fitted %d seat(s): raw height %.2f, scale %.2f, camera %.1f (mouse wheel zooms, shift+wheel moves up/down)", #shown, tallest, s, R.camDist)
end

local function buildSeats()
    if scene then
        for _, a in ipairs(scene.actors) do a:ClearModel() end
    else
        scene = CreateFrame("ModelScene", nil, stage)
        scene:SetPoint("BOTTOMLEFT", stage, "BOTTOMLEFT", 0, 90)
        scene:SetPoint("TOPRIGHT", stage, "TOPRIGHT", 0, -170)
        scene:SetCameraFieldOfView(math.rad(R.fov))
        scene:SetCameraOrientationByYawPitchRoll(math.pi, 0, 0)
        scene:SetCameraNearClip(.01); scene:SetCameraFarClip(1000)
        scene:SetLightAmbientColor(.8, .8, .8); scene:SetLightDiffuseColor(.8, .75, .6)
        scene:SetLightDirection(-1, -1, -1); scene:SetLightVisible(true)
        scene.actors = {}
        scene:EnableMouseWheel(true)
        scene:SetScript("OnMouseWheel", function(_, delta)
            R.manualCam = true
            if IsShiftKeyDown() then R.camZ = R.camZ + delta * .1 else R.camDist = R.camDist * (delta > 0 and .9 or 1.1) end
            placeCamera()
            if animLabel then animLabel:SetText(("camera %.1f / %.2f"):format(R.camDist, R.camZ)) end
        end)
    end
    placeCamera()
    local units = { "player" }
    for i = 1, 4 do if UnitExists("party" .. i) then units[#units + 1] = "party" .. i end end
    for i, u in ipairs(units) do
        local a = scene.actors[i] or scene:CreateActor(nil, "ModelSceneActorTemplate")
        scene.actors[i] = a
        a:SetOnModelLoadedCallback(function()
            R.actorsLoaded = R.actorsLoaded + 1
            log("CHECK d: 3D model loaded for %s", u)
            C_Timer.After(0, fitCamera)   -- bounds settle a frame after loading
        end)
        -- unit, sheatheWeapons, autoDress, hideWeapons, usePlayerNativeForm
        a:SetModelByUnit(u, false, true, false, true)
        a:SetPosition(0, (i - (#units + 1) / 2) * R.spacing, 0)
        a:SetYaw(0)
        a:SetAnimation(0, 0, 1)
        a:Show()
    end
    for i = #units + 1, #scene.actors do scene.actors[i]:Hide() end
    log("CHECK d: %d seat(s) created (you + party). Camera %.1f / %.1f", #units, R.camDist, R.camZ)
end

-- g: Alliance tavern music (sound/music/zonemusic/tavernalliance/tavernalliance01/02.mp3)
local MUSIC = { 53737, 53738 }
local soundHandle
local function playMusic(id)
    id = id or MUSIC[1]
    local ok, a, b = pcall(PlayMusic, id)
    R.music = ("PlayMusic(%d): %s, returned %s %s; music enabled=%s volume=%s"):format(id, ok and "ran" or "ERRORED", tostring(a), tostring(b),
        tostring(C_CVar.GetCVar("Sound_EnableMusic")), tostring(C_CVar.GetCVar("Sound_MusicVolume")))
    log("CHECK g: %s. Do you hear tavern music?", R.music)
end
local function playMusicAsSound(id)
    id = id or MUSIC[1]
    local willPlay, handle = PlaySoundFile(id, "Music")
    soundHandle = handle
    log("CHECK g: PlaySoundFile(%d, Music): willPlay=%s", id, tostring(willPlay))
end
local function stopMusic()
    pcall(StopMusic)
    if soundHandle then StopSound(soundHandle, 500); soundHandle = nil end
end

-- e: table mode
local CVARS = { test_cameraOverShoulder = "1", cameraFov = "75", CameraKeepCharacterCentered = "0", CameraReduceUnexpectedMovement = "0" }
-- Floating names in the world (DialogueUI hides the same set). Restored on leave.
for _, cv in ipairs({ "UnitNameOwn", "UnitNameNonCombatCreatureName", "UnitNameFriendlyPlayerName", "UnitNameFriendlyPetName",
    "UnitNameFriendlyMinionName", "UnitNameFriendlyGuardianName", "UnitNameFriendlySpecialNPCName", "UnitNameEnemyPlayerName",
    "UnitNameEnemyPetName", "UnitNameEnemyGuardianName", "UnitNameNPC", "UnitNameInteractiveNPC", "UnitNameHostleNPC" }) do
    CVARS[cv] = "0"
end

local function zoomTo(target)
    local z = GetCameraZoom()
    if z > target then CameraZoomIn(z - target) else CameraZoomOut(target - z) end
end

local function restoreCamera()
    local b = DB and DB.backup
    if not b then return end
    for k, v in pairs(b.cvars) do C_CVar.SetCVar(k, v) end
    if b.zoom then zoomTo(b.zoom) end
    DB.backup = nil
end

local function exitStage(reason)
    if not stage or not stage:IsShown() then return end
    stopMusic()
    UIParent:Show()
    restoreCamera()
    stage:Hide()
    log("CHECK e: left table mode (%s). UI shown=%s, in combat lockdown=%s", reason, tostring(UIParent:IsShown()), tostring(InCombatLockdown()))
end

local function makeButton(text, x, onClick)
    local b = CreateFrame("Button", nil, stage, "UIPanelButtonTemplate")
    b:SetSize(140, 30)
    b:SetPoint("BOTTOM", stage, "BOTTOM", x, 18)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function edge(side, orientation, from, to, size)
    local t = stage:CreateTexture(nil, "BACKGROUND")
    t:SetColorTexture(1, 1, 1, 1)
    if side == "LEFT" or side == "RIGHT" then
        t:SetPoint("TOP" .. side); t:SetPoint("BOTTOM" .. side); t:SetWidth(size)
    else
        t:SetPoint(side .. "LEFT"); t:SetPoint(side .. "RIGHT"); t:SetHeight(size)
    end
    t:SetGradient(orientation, CreateColor(0, 0, 0, from), CreateColor(0, 0, 0, to))
end

local function buildStage()
    stage = CreateFrame("Frame", "DeathrollSpikeStage", nil)
    stage:SetAllPoints(WorldFrame)
    stage:SetFrameStrata("DIALOG")
    stage:Hide()

    -- vignette from plain gradients, no texture files
    edge("LEFT", "HORIZONTAL", .9, 0, 420)
    edge("RIGHT", "HORIZONTAL", 0, .9, 420)
    edge("TOP", "VERTICAL", 0, .85, 260)
    edge("BOTTOM", "VERTICAL", .95, 0, 300)

    -- h: the game's own fonts by path
    local title = stage:CreateFontString(nil, "OVERLAY")
    local fontOK = title:SetFont("Fonts\\MORPHEUS.TTF", 46, "OUTLINE")
    R.fonts.morpheus = tostring(fontOK)
    if not fontOK then title:SetFontObject(GameFontNormalHuge) end
    title:SetPoint("TOP", 0, -60)
    title:SetText("DEATHROLL")
    title:SetTextColor(1, .82, 0)

    local sub = stage:CreateFontString(nil, "OVERLAY")
    local friz = sub:SetFont("Fonts\\FRIZQT__.TTF", 18, "OUTLINE")
    R.fonts.friz = tostring(friz)
    if not friz then sub:SetFontObject(GameFontHighlight) end
    sub:SetPoint("TOP", title, "BOTTOM", 0, -6)
    sub:SetText("Table mode spike. Esc or Leave to exit.")
    log("CHECK h: Morpheus font loaded=%s, Friz font loaded=%s", R.fonts.morpheus, R.fonts.friz)

    animLabel = stage:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    animLabel:SetPoint("BOTTOM", 0, 60)

    screenLog = stage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    screenLog:SetPoint("TOPLEFT", 24, -24)
    screenLog:SetWidth(620)
    screenLog:SetJustifyH("LEFT")
    screenLog:SetText(table.concat(screenLines, "\n"))

    makeButton("Leave table", -450, function() exitStage("button") end)
    makeButton("Roll (click)", -300, function() tryRoll("button") end)
    makeButton("Ping party", -150, function() send("PING:" .. GetTime()) end)
    makeButton("Deal (party rolls)", 0, function() send("DEAL:1") end)
    makeButton("Prev animation", 150, function() R.anim = (R.anim - 2) % #ANIMS + 1; setAnim(ANIMS[R.anim][1], ANIMS[R.anim][2]) end)
    makeButton("Next animation", 300, function() R.anim = R.anim % #ANIMS + 1; setAnim(ANIMS[R.anim][1], ANIMS[R.anim][2]) end)
    makeButton("Rebuild seats", 450, function() buildSeats() end)

    stage:EnableKeyboard(true)
    stage:SetPropagateKeyboardInput(true)
    stage:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            exitStage("escape")
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
end

local function enterStage()
    if InCombatLockdown() then log("CHECK e: refused, you are in combat"); return end
    if not stage then buildStage() end
    if stage:IsShown() then return end
    pcall(UIParent.UnregisterEvent, UIParent, "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED")
    if GameEvent and GameEvent.UnregisterInternalEvent then pcall(GameEvent.UnregisterInternalEvent, "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED") end
    if not DB.backup then
        DB.backup = { zoom = GetCameraZoom(), cvars = {} }
        for k in pairs(CVARS) do DB.backup.cvars[k] = C_CVar.GetCVar(k) end
    end
    for k, v in pairs(CVARS) do C_CVar.SetCVar(k, v) end
    zoomTo(4)
    UIParent:Hide()
    stage:Show()
    buildSeats()
    playMusic()
    log("CHECK e: entered table mode. UI hidden=%s. Did the camera move over your shoulder and zoom in?", tostring(not UIParent:IsShown()))
end

-- events
local f = CreateFrame("Frame")
local function reg(ev)
    local ok = pcall(f.RegisterEvent, f, ev)
    if not ok then print("|cffffd100DRS|r event not available on this client: " .. ev) end
end
for _, ev in ipairs({ "ADDON_LOADED", "CHAT_MSG_SYSTEM", "CHAT_MSG_ADDON", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
    "ADDON_RESTRICTION_STATE_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_LOGOUT", "GROUP_ROSTER_UPDATE" }) do reg(ev) end

f:SetScript("OnEvent", function(_, ev, ...)
    if ev == "ADDON_LOADED" then
        if ... ~= "DeathrollSpike" then return end
        DeathrollSpikeDB = DeathrollSpikeDB or {}
        DB = DeathrollSpikeDB
        DB.log = DB.log or {}
        local res = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        if DB.backup then restoreCamera(); log("restored camera settings left over from the last session") end
        log("loaded. Prefix registered: %s. Roll pattern: %s. UnitName=%s. Type /drs for the steps.", tostring(res), rollPattern, tostring(UnitName("player")))
    elseif ev == "CHAT_MSG_SYSTEM" then
        onSystem((...))
    elseif ev == "CHAT_MSG_ADDON" then
        onAddon(...)
    elseif ev == "ADDON_ACTION_BLOCKED" or ev == "ADDON_ACTION_FORBIDDEN" then
        local addon, func = ...
        if addon == "DeathrollSpike" then
            R.blocked[#R.blocked + 1] = ev .. " " .. tostring(func)
            log("CHECK b/e: %s: %s", ev, tostring(func))
        end
    elseif ev == "ADDON_RESTRICTION_STATE_CHANGED" then
        R.lockEvents = R.lockEvents + 1
        local parts = {}
        for i = 1, select("#", ...) do local v = select(i, ...); parts[i] = isSecret(v) and "<secret>" or tostring(v) end
        log("CHECK f: ADDON_RESTRICTION_STATE_CHANGED %s, lockdown now=%s", table.concat(parts, " "), tostring(lockdown()))
    elseif ev == "PLAYER_REGEN_DISABLED" then
        if stage and stage:IsShown() then exitStage("combat started") end
    elseif ev == "PLAYER_LOGOUT" then
        restoreCamera()
    elseif ev == "GROUP_ROSTER_UPDATE" then
        if stage and stage:IsShown() then buildSeats() end
    end
end)

local function report()
    local lines = {}
    local function add(fmt, ...) lines[#lines + 1] = fmt:format(...) end
    add("a  rolls read=%d, secret system messages=%d", R.rolls, R.secret)
    for src, max in pairs(RANGE) do
        local e = R.expect[max]
        add("b  %-8s %s", src, not e and "not tried" or e.ok and "WORKS" or "no result (blocked?)")
    end
    local p = {}
    for n, rtt in pairs(R.pongs) do p[#p + 1] = ("%s %.2fs"):format(n, rtt) end
    add("c  pongs: %s", #p > 0 and table.concat(p, ", ") or "none")
    local rr = {}
    for n, c in pairs(R.remote) do rr[#rr + 1] = n .. " x" .. c end
    add("c  rolls seen from others: %s", #rr > 0 and table.concat(rr, ", ") or "none")
    add("d  3D models loaded=%d", R.actorsLoaded)
    add("e  blocked actions: %s", #R.blocked > 0 and table.concat(R.blocked, "; ") or "none")
    add("f  lockdown now=%s, restriction events=%d", tostring(lockdown()), R.lockEvents)
    add("g  %s", R.music)
    add("h  Morpheus=%s Friz=%s", tostring(R.fonts.morpheus), tostring(R.fonts.friz))
    DB.report = lines
    for _, l in ipairs(lines) do print("|cffffd100DRS|r " .. l) end
    print("|cffffd100DRS|r Saved. Type /reload so the results are written to disk.")
end

SLASH_DEATHROLLSPIKE1 = "/drs"
SlashCmdList.DEATHROLLSPIKE = function(m)
    local cmd, a, b = strsplit(" ", (m or ""):lower())
    if cmd == "stage" then if stage and stage:IsShown() then exitStage("command") else enterStage() end
    elseif cmd == "roll" then tryRoll("typed")
    elseif cmd == "timerroll" then log("rolling from a timer in 1s..."); C_Timer.After(1, function() tryRoll("timer") end)
    elseif cmd == "ping" then send("PING:" .. GetTime())
    elseif cmd == "deal" then send("DEAL:1")
    elseif cmd == "anim" then local id = tonumber(a); if id then setAnim(id, "") end
    elseif cmd == "cam" then
        if a == "auto" then R.manualCam = false; fitCamera()
        else R.manualCam = true; R.camDist, R.camZ = tonumber(a) or R.camDist, tonumber(b) or R.camZ; placeCamera(); log("camera %.1f / %.1f (manual; /drs cam auto to refit)", R.camDist, R.camZ) end
    elseif cmd == "music" then if a == "off" then stopMusic() elseif a == "sound" then playMusicAsSound(tonumber(b)) else playMusic(tonumber(a)) end
    elseif cmd == "report" then report()
    else
        print("|cffffd100Deathroll spike|r steps:")
        print("  1. /drs roll, then /drs timerroll   (can the addon roll for you?)")
        print("  2. /drs stage   (table mode: UI hides, camera moves, tavern music, 3D seats; Esc to leave)")
        print("     in table mode try Roll (click), Next animation; /drs cam 7 1 to move the camera")
        print("  3. with a friend in party: Ping party and Deal (both need the addon), stand far apart")
        print("  4. /console addonChatRestrictionsForced 1, then /drs ping, then set it back to 0")
        print("  5. /drs music sound   (fallback music path),  /drs music off")
        print("  6. /drs report, then /reload")
    end
end
