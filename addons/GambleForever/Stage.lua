-- Table mode: the world UI fades away, the camera moves over the shoulder, names vanish,
-- tavern music plays, and the table view fills the screen. Everything changed is backed up
-- in GambleForeverDB.stageBackup first, so a crash or logout mid-table is undone on next load.
local _, ns = ...
local Stage = {}
ns.Stage = Stage

local MUSIC = 53737   -- sound/music/zonemusic/tavernalliance/tavernalliance01.mp3 (02 is 53738)

local CVARS = { test_cameraOverShoulder = "1", cameraFov = "75", CameraKeepCharacterCentered = "0",
    CameraReduceUnexpectedMovement = "0" }
for _, cv in ipairs({ "UnitNameOwn", "UnitNameNonCombatCreatureName", "UnitNameFriendlyPlayerName",
    "UnitNameFriendlyPetName", "UnitNameFriendlyMinionName", "UnitNameFriendlyGuardianName",
    "UnitNameFriendlySpecialNPCName", "UnitNameEnemyPlayerName", "UnitNameEnemyPetName",
    "UnitNameEnemyGuardianName", "UnitNameNPC", "UnitNameInteractiveNPC", "UnitNameHostleNPC" }) do
    CVARS[cv] = "0"
end

local function zoomTo(target)
    local z = GetCameraZoom()
    if z > target then CameraZoomIn(z - target) else CameraZoomOut(target - z) end
end

function Stage.restoreCamera()
    local b = GambleForeverDB and GambleForeverDB.stageBackup
    if not b then return end
    for k, v in pairs(b.cvars) do C_CVar.SetCVar(k, v) end
    if b.zoom then zoomTo(b.zoom) end
    GambleForeverDB.stageBackup = nil
end

function Stage.restoreLeftovers()
    if GambleForeverDB.stageBackup then Stage.restoreCamera() end
end

local mode   -- nil while the table is not showing, else "immersive" or "window"
function Stage.isOn() return mode ~= nil end

function Stage.enter()
    if mode then return end
    local s = GambleForeverDB.settings
    if s.immersive and InCombatLockdown() then
        print("|cffffd100GambleForever|r the table opens once you are out of combat (/gf table).")
        return
    end
    mode = s.immersive and "immersive" or "window"
    if s.immersive then
        pcall(UIParent.UnregisterEvent, UIParent, "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED")
        if GameEvent and GameEvent.UnregisterInternalEvent then
            pcall(GameEvent.UnregisterInternalEvent, "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED")
        end
        if not GambleForeverDB.stageBackup then
            local b = { zoom = GetCameraZoom(), cvars = {} }
            for k in pairs(CVARS) do b.cvars[k] = C_CVar.GetCVar(k) end
            GambleForeverDB.stageBackup = b
        end
        for k, v in pairs(CVARS) do C_CVar.SetCVar(k, v) end
        zoomTo(4)
        UIParent:Hide()
    end
    if s.music and not s.mute then pcall(PlayMusic, MUSIC) end
    ns.UI.showTable(mode)
end

-- reason "interrupt" (combat, death, ready check) keeps your seat; /gf table brings the view back.
-- Only the immersive view closes for it: the window leaves the normal UI usable.
function Stage.leave(reason)
    if not mode or (reason == "interrupt" and mode == "window") then return end
    local was = mode
    mode = nil   -- first, so the view's OnHide calling back in is a no-op
    pcall(StopMusic)
    if was == "immersive" then
        -- PLAYER_REGEN_DISABLED fires just before combat lockdown; if showing is refused anyway,
        -- Core shows it on PLAYER_REGEN_ENABLED.
        if not UIParent:IsShown() then pcall(UIParent.Show, UIParent) end
        Stage.restoreCamera()
    end
    ns.UI.showTable(nil)
    if reason == "interrupt" and ns.Table.current() then
        print("|cffffd100GambleForever|r you are still seated. Type /gf table to return.")
    end
end

function Stage.toggleMusic()
    local s = GambleForeverDB.settings
    s.mute = not s.mute
    if s.mute then pcall(StopMusic) elseif s.music then pcall(PlayMusic, MUSIC) end
    return s.mute
end
