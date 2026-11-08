-- Table mode: the world UI fades away, the camera moves over the shoulder, names vanish,
-- tavern music plays, and the table view fills the screen. Everything changed is backed up
-- in DeathrollDB.stageBackup first, so a crash or logout mid-table is undone on next load.
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
    local b = DeathrollDB and DeathrollDB.stageBackup
    if not b then return end
    for k, v in pairs(b.cvars) do C_CVar.SetCVar(k, v) end
    if b.zoom then zoomTo(b.zoom) end
    DeathrollDB.stageBackup = nil
end

function Stage.restoreLeftovers()
    if DeathrollDB.stageBackup then Stage.restoreCamera() end
end

function Stage.isOn() return ns.UI.tableShown() end

function Stage.enter()
    if InCombatLockdown() then
        print("|cffffd100Deathroll|r the table opens once you are out of combat (/dr table).")
        return
    end
    if Stage.isOn() then return end
    local s = DeathrollDB.settings
    if s.immersive then
        pcall(UIParent.UnregisterEvent, UIParent, "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED")
        if GameEvent and GameEvent.UnregisterInternalEvent then
            pcall(GameEvent.UnregisterInternalEvent, "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED")
        end
        if not DeathrollDB.stageBackup then
            local b = { zoom = GetCameraZoom(), cvars = {} }
            for k in pairs(CVARS) do b.cvars[k] = C_CVar.GetCVar(k) end
            DeathrollDB.stageBackup = b
        end
        for k, v in pairs(CVARS) do C_CVar.SetCVar(k, v) end
        zoomTo(4)
        UIParent:Hide()
    end
    if s.music and not s.mute then pcall(PlayMusic, MUSIC) end
    ns.UI.showTable(true)
end

-- reason "interrupt" (combat, death, ready check) keeps your seat; /dr table brings the view back.
function Stage.leave(reason)
    if not Stage.isOn() then return end
    pcall(StopMusic)
    -- PLAYER_REGEN_DISABLED fires just before combat lockdown; if showing is refused anyway,
    -- Core shows it on PLAYER_REGEN_ENABLED.
    if not UIParent:IsShown() then pcall(UIParent.Show, UIParent) end
    Stage.restoreCamera()
    ns.UI.showTable(false)
    if reason == "interrupt" and ns.Table.current() then
        print("|cffffd100Deathroll|r you are still seated. Type /dr table to return.")
    end
end

function Stage.toggleMusic()
    local s = DeathrollDB.settings
    s.mute = not s.mute
    if s.mute then pcall(StopMusic) elseif s.music then pcall(PlayMusic, MUSIC) end
    return s.mute
end
