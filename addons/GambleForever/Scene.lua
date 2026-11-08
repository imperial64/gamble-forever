-- Seats: a ModelScene per seat showing the real player in 3D. A player the client cannot
-- render (out of range, e.g. another continent) or a test bot gets a class crest instead.
local _, ns = ...
local Scene = {}
ns.Scene = Scene

-- animation IDs measured on Forever 2026-11-08 (100 is sleep and 101 is waking, not chair sits)
local ANIM = { idle = 0, death = 1, talk = 60, bow = 66, wave = 67, cheer = 68, dance = 69, laugh = 70,
    kneel = 75, cry = 77, applaud = 80, sit = 97 }
Scene.ANIM = ANIM

local function isSecret(v) return issecretvalue ~= nil and issecretvalue(v) or false end

function Scene.unitFor(name)
    if not name or ns.bots[name] then return nil end
    if ns.Rolls.same(UnitName("player"), name) then return "player" end
    local raid = IsInRaid()
    for i = 1, raid and 40 or 4 do
        local u = (raid and "raid" or "party") .. i
        local n = UnitExists(u) and UnitName(u)
        if n and not isSecret(n) and ns.Rolls.same(n, name) then return u end
    end
end

local FOV = math.rad(30)

-- Same framing that worked in the spike: normalize the model to 2 units tall, centre it,
-- and place the camera for a diagonal FOV (the axis is undocumented; diagonal is safest).
local function fit(seat)
    local a, sc = seat.actor, seat.scene
    if not a:IsLoaded() or not a.GetActiveBoundingBox then return end
    local x, y, z, xx, yy, zz = a:GetActiveBoundingBox()
    if type(x) == "table" and type(y) == "table" then
        local lo, hi = x, y
        x, y, z = lo:GetXYZ(); xx, yy, zz = hi:GetXYZ()
    end
    if type(z) ~= "number" or type(zz) ~= "number" or zz <= z then return end
    local s = 2 / (zz - z)
    a:SetRequestedScale(s); a:SetScale(s)
    a:SetPosition(0, 0, -(z + zz) / 2 * s)
    local aspect = math.max(1, sc:GetWidth()) / math.max(1, sc:GetHeight())
    local vt = math.tan(FOV / 2) / math.sqrt(1 + aspect * aspect)
    sc:SetCameraPosition(1 / (vt * .92), 0, 0)
end

function Scene.seat(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(170, 250)

    s.glow = s:CreateTexture(nil, "BACKGROUND")
    s.glow:SetTexture(ns.media .. "glow.png")
    s.glow:SetPoint("CENTER", 0, 10)
    s.glow:SetSize(300, 300)
    s.glow:SetBlendMode("ADD")
    s.glow:SetVertexColor(1, .75, .3, .25)

    local sc = CreateFrame("ModelScene", nil, s)
    sc:SetPoint("TOPLEFT"); sc:SetPoint("BOTTOMRIGHT", 0, 46)
    sc:SetCameraFieldOfView(FOV)
    sc:SetCameraOrientationByYawPitchRoll(math.pi, 0, 0)
    sc:SetCameraNearClip(.01); sc:SetCameraFarClip(1000)
    sc:SetLightAmbientColor(.75, .7, .65); sc:SetLightDiffuseColor(1, .85, .6)
    sc:SetLightDirection(-1, -.6, -1); sc:SetLightVisible(true)
    s.scene = sc
    s.actor = sc:CreateActor(nil, "ModelSceneActorTemplate")
    s.actor:SetOnModelLoadedCallback(function() C_Timer.After(0, function() fit(s) end) end)

    -- crest for players the client cannot render
    s.crest = s:CreateTexture(nil, "ARTWORK")
    s.crest:SetSize(96, 96)
    s.crest:SetPoint("CENTER", sc, "CENTER", 0, 0)
    s.far = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    s.far:SetPoint("TOP", s.crest, "BOTTOM", 0, -4)

    s.plate = CreateFrame("Frame", nil, s)
    s.plate:SetPoint("BOTTOMLEFT"); s.plate:SetPoint("BOTTOMRIGHT")
    s.plate:SetHeight(44)
    local pt = s.plate:CreateTexture(nil, "BACKGROUND")
    pt:SetTexture(ns.media .. "ui\\btn_dark.png")
    pt:SetAllPoints()
    s.name = s.plate:CreateFontString(nil, "OVERLAY")
    s.name:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    s.name:SetPoint("TOP", 0, -8)
    s.name:SetWidth(160)
    s.name:SetWordWrap(false)
    s.note = s.plate:CreateFontString(nil, "OVERLAY")
    s.note:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    s.note:SetPoint("TOP", s.name, "BOTTOM", 0, -2)
    s.note:SetTextColor(1, .82, 0)

    function s:SetPlayer(name)
        if self.player == name and self.shownModel == (self.unit and UnitIsVisible(self.unit)) then return end
        self.player = name
        self.unit = Scene.unitFor(name)
        local visible = self.unit and UnitIsVisible(self.unit)
        self.shownModel = visible
        local class = self.unit and select(2, UnitClass(self.unit))
        local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        self.name:SetText(name and name:match("^[^%-]+") or "")   -- "First Last", like everywhere on Forever
        if color then self.name:SetTextColor(color.r, color.g, color.b) else self.name:SetTextColor(1, 1, 1) end
        if visible then
            self.crest:Hide(); self.far:Hide(); sc:Show()
            self.actor:SetModelByUnit(self.unit, false, true, false, true)   -- 3rd arg dresses them
            self.actor:SetAnimation(ANIM.idle, 0, 1)
        else
            sc:Hide(); self.crest:Show(); self.far:Show()
            local coords = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
            if coords then
                self.crest:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
                self.crest:SetTexCoord(unpack(coords))
            else
                self.crest:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                self.crest:SetTexCoord(.08, .92, .08, .92)
            end
            self.far:SetText(ns.bots[name or ""] and "test seat" or "too far away to see")
        end
    end

    function s:SetNote(text) self.note:SetText(text or "") end

    -- state: nil, "turn", "out", "win"
    function s:SetState(state)
        local prev = self.state
        self.state = state
        -- a new round: the last loser gets up from the death pose, the last winner stops cheering
        if (prev == "out" or prev == "win") and state ~= prev and self.shownModel then
            self.animToken = (self.animToken or 0) + 1
            self.actor:SetAnimation(ANIM.idle, 0, 1)
        end
        local r, g, b, al = 1, .75, .3, .25
        if state == "turn" then r, g, b, al = 1, .82, 0, .7
        elseif state == "win" then r, g, b, al = 1, .9, .3, 1
        elseif state == "out" then r, g, b, al = .6, 0, 0, .35 end
        self.glow:SetVertexColor(r, g, b, al)
        self:SetAlpha(state == "out" and .55 or 1)
        pcall(self.actor.SetDesaturation, self.actor, state == "out" and 1 or 0)
    end

    -- play an animation; anything but death drops back to idle after `hold` seconds
    function s:Anim(key, hold)
        if not self.shownModel then return end
        self.actor:SetAnimation(ANIM[key] or 0, 0, 1)
        self.animToken = (self.animToken or 0) + 1
        local token = self.animToken
        if key ~= "death" and hold then
            C_Timer.After(hold, function()
                if self.animToken == token and self.state ~= "out" then self.actor:SetAnimation(ANIM.idle, 0, 1) end
            end)
        end
    end

    return s
end
