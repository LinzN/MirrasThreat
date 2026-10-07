-- Mirra's Threat
-- Shows the player's threat on enemy nameplates as a compact bar and/or percentage.
-- Written for WoW Forever (Interface 16001), where many unit API results can be
-- "secret values": they may be passed to widgets and string.format, but must never
-- be compared, used in arithmetic or tested for truthiness from addon code.

local addonName, ns = ...

ns.title = "Mirra's Threat"

ns.defaults = {
    mode     = "tank",    -- "tank" or "dps" (DPS / healer)
    style    = "bartext", -- "bartext", "bar" or "text"
    width    = 80,
    height   = 10,
    fontSize = 10,
    offsetY  = 0,
    warnAt   = 80,        -- threshold (in %) for the warning color
    hideZero = true,      -- hide the display while threat is 0 %
    hideSolo = false,     -- only show while in a party or raid
}

ns.colors = {
    good = { 0.30, 0.85, 0.40 },
    warn = { 1.00, 0.78, 0.18 },
    bad  = { 0.95, 0.26, 0.22 },
}

ns.lastError = nil

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local FLAT        = "Interface\\Buttons\\WHITE8X8"

---------------------------------------------------------------------------
-- Secret value helpers
---------------------------------------------------------------------------

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

-- Returns the value when it may be inspected, otherwise nil ("unknown").
local function Known(v)
    if IsSecret(v) then return nil end
    return v
end

local function NoteError(where, err)
    ns.lastError = where .. ": " .. tostring(err)
end

---------------------------------------------------------------------------
-- Colors
---------------------------------------------------------------------------

-- Plain (non-secret) values: simple thresholds.
function ns.GetColor(pct)
    local db, c = ns.db or ns.defaults, ns.colors
    local high, mid, low
    if db.mode == "dps" then
        high, mid, low = c.bad, c.warn, c.good
    else
        high, mid, low = c.good, c.warn, c.bad
    end
    if pct >= 100 then
        return high
    elseif pct >= db.warnAt then
        return mid
    end
    return low
end

-- Secret values: a step color curve evaluated by the client.
-- The alpha channel of the 0 % point is used to hide the display at zero threat.
local colorCurve

function ns.RebuildCurve()
    colorCurve = nil
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then return end

    local ok, err = pcall(function()
        local db, c = ns.db or ns.defaults, ns.colors
        local high, mid, low
        if db.mode == "dps" then
            high, mid, low = c.bad, c.warn, c.good
        else
            high, mid, low = c.good, c.warn, c.bad
        end

        local curve = C_CurveUtil.CreateColorCurve()
        if curve.SetType and Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step then
            curve:SetType(Enum.LuaCurveType.Step)
        end
        curve:AddPoint(0,           CreateColor(low[1],  low[2],  low[3],  db.hideZero and 0 or 1))
        curve:AddPoint(0.5,         CreateColor(low[1],  low[2],  low[3],  1))
        curve:AddPoint(db.warnAt,   CreateColor(mid[1],  mid[2],  mid[3],  1))
        curve:AddPoint(99.5,        CreateColor(high[1], high[2], high[3], 1))
        colorCurve = curve
    end)
    if not ok then NoteError("Color curve", err) end
end

---------------------------------------------------------------------------
-- Threat widget (used on nameplates and in the options preview)
---------------------------------------------------------------------------

function ns.CreateWidget(parent)
    local w = CreateFrame("Frame", nil, parent)
    w:SetFrameStrata(parent:GetFrameStrata())
    w:SetFrameLevel(parent:GetFrameLevel() + 10)

    -- 1 px dark border + inner background
    w.border = w:CreateTexture(nil, "BACKGROUND", nil, -2)
    w.border:SetTexture(FLAT)
    w.border:SetVertexColor(0, 0, 0, 0.9)
    w.border:SetAllPoints()

    w.bg = w:CreateTexture(nil, "BACKGROUND", nil, -1)
    w.bg:SetTexture(FLAT)
    w.bg:SetVertexColor(0.07, 0.07, 0.09, 0.85)
    w.bg:SetPoint("TOPLEFT", 1, -1)
    w.bg:SetPoint("BOTTOMRIGHT", -1, 1)

    w.bar = CreateFrame("StatusBar", nil, w)
    w.bar:SetPoint("TOPLEFT", 1, -1)
    w.bar:SetPoint("BOTTOMRIGHT", -1, 1)
    w.bar:SetStatusBarTexture(BAR_TEXTURE)
    w.bar:SetMinMaxValues(0, 100)
    w.bar:SetValue(0)

    -- subtle top highlight for a bit of depth
    w.shine = w.bar:CreateTexture(nil, "OVERLAY", nil, 1)
    w.shine:SetTexture(FLAT)
    w.shine:SetVertexColor(1, 1, 1, 0.10)
    w.shine:SetPoint("TOPLEFT")
    w.shine:SetPoint("TOPRIGHT")

    -- marker at the warning threshold
    w.tick = w.bar:CreateTexture(nil, "OVERLAY", nil, 2)
    w.tick:SetTexture(FLAT)
    w.tick:SetVertexColor(1, 1, 1, 0.35)
    w.tick:SetWidth(1)

    w.overlay = CreateFrame("Frame", nil, w)
    w.overlay:SetAllPoints()
    w.overlay:SetFrameLevel(w.bar:GetFrameLevel() + 2)

    w.text = w.overlay:CreateFontString(nil, "OVERLAY")
    w.text:SetShadowOffset(1, -1)
    w.text:SetShadowColor(0, 0, 0, 1)

    ns.LayoutWidget(w)
    return w
end

function ns.LayoutWidget(w)
    local db = ns.db or ns.defaults
    local showBar  = db.style ~= "text"
    local showText = db.style ~= "bar"

    w.text:SetFont(STANDARD_TEXT_FONT, db.fontSize, "OUTLINE")
    w.text:ClearAllPoints()

    if showBar then
        w:SetSize(db.width, db.height)
        w.border:Show()
        w.bg:Show()
        w.bar:Show()
        w.shine:SetHeight(math.max(1, math.floor(db.height / 3)))
        w.shine:Show()
        w.tick:ClearAllPoints()
        local inner = db.width - 2
        w.tick:SetPoint("TOPLEFT", w.bar, "TOPLEFT", math.floor(inner * db.warnAt / 100), 0)
        w.tick:SetPoint("BOTTOMLEFT", w.bar, "BOTTOMLEFT", math.floor(inner * db.warnAt / 100), 0)
        w.tick:Show()
        w.text:SetPoint("CENTER", w, "CENTER", 0, 0)
    else
        w:SetSize(db.width, db.fontSize + 4)
        w.border:Hide()
        w.bg:Hide()
        w.bar:Hide()
        w.text:SetPoint("CENTER", w, "CENTER", 0, 0)
    end

    if showText then w.text:Show() else w.text:Hide() end
    w.layoutStamp = ns.layoutStamp
end

-- Sets value and color. `pct` may be a plain number or a secret number.
function ns.RenderWidget(w, pct)
    if w.layoutStamp ~= ns.layoutStamp then
        ns.LayoutWidget(w)
    end

    if IsSecret(pct) then
        local ok, err = pcall(function()
            w.text:SetText(string.format("%.0f%%", pct))
            w.bar:SetValue(pct)
        end)
        if not ok then
            NoteError("Secret value", err)
            return false
        end

        w.text:SetTextColor(1, 1, 1, 1)
        w.bar:SetStatusBarColor(0.6, 0.6, 0.6, 1)
        if colorCurve then
            local okc, errc = pcall(function()
                local c = colorCurve:Evaluate(pct)
                w.text:SetTextColor(c:GetRGBA())
                w.bar:SetStatusBarColor(c:GetRGBA())
            end)
            if not okc then NoteError("Secret color", errc) end
        end
        return true
    end

    local display = math.floor(pct + 0.5)
    if display <= 0 and (ns.db or ns.defaults).hideZero then
        return false
    end

    local c = ns.GetColor(display)
    w.text:SetText(display .. "%")
    w.text:SetTextColor(c[1], c[2], c[3], 1)
    w.bar:SetValue(math.min(display, 100))
    w.bar:SetStatusBarColor(c[1], c[2], c[3], 1)
    return true
end

---------------------------------------------------------------------------
-- Nameplates
---------------------------------------------------------------------------

local widgets = {}   -- [plate] = widget
ns.layoutStamp = 1

local function GetPlateAnchor(plate)
    local uf = plate.UnitFrame
    if not uf then return plate end
    return uf.healthBar
        or uf.HealthBar
        or (uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar)
        or uf
end

local function HidePlate(plate)
    local w = plate and widgets[plate]
    if w then w:Hide() end
end

local function UpdatePlate(plate, unit)
    if not plate then return end
    if plate.IsForbidden and plate:IsForbidden() then return end

    unit = unit or plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
    if not unit then
        HidePlate(plate)
        return
    end

    -- Results may be secret; only act on values we are allowed to read.
    if Known(UnitExists(unit)) == false
        or Known(UnitIsDead(unit)) == true
        or Known(UnitCanAttack("player", unit)) == false then
        HidePlate(plate)
        return
    end

    if ns.db.hideSolo and not IsInGroup() then
        HidePlate(plate)
        return
    end

    local _, _, percent = UnitDetailedThreatSituation("player", unit)

    -- nil = not on the threat list. issecretvalue(nil) is false, so this is safe.
    if not IsSecret(percent) and percent == nil then
        HidePlate(plate)
        return
    end

    local w = widgets[plate]
    if not w then
        w = ns.CreateWidget(plate)
        widgets[plate] = w
    end

    local anchor = GetPlateAnchor(plate)
    if w.anchor ~= anchor or w.anchorOffset ~= ns.db.offsetY then
        w:ClearAllPoints()
        w:SetPoint("TOP", anchor, "BOTTOM", 0, -2 + ns.db.offsetY)
        w.anchor, w.anchorOffset = anchor, ns.db.offsetY
    end

    if ns.RenderWidget(w, percent) then
        w:Show()
    else
        w:Hide()
    end
end

function ns.UpdateAll()
    if not ns.db then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        local ok, err = pcall(UpdatePlate, plate)
        if not ok then NoteError("Update", err) end
    end
end

-- Called by the options whenever a setting changes.
function ns.ApplySettings()
    ns.layoutStamp = ns.layoutStamp + 1
    ns.RebuildCurve()
    for plate, w in pairs(widgets) do
        w.anchor = nil
        ns.LayoutWidget(w)
    end
    ns.UpdateAll()
    if ns.RefreshPreview then ns.RefreshPreview() end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")

local function SafeUpdateUnit(unit)
    local plate = unit and C_NamePlate.GetNamePlateForUnit(unit)
    if plate then
        local ok, err = pcall(UpdatePlate, plate, unit)
        if not ok then NoteError("Update", err) end
    end
end

events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        MirraThreatDB = MirraThreatDB or {}
        for k, v in pairs(ns.defaults) do
            if MirraThreatDB[k] == nil then MirraThreatDB[k] = v end
        end
        ns.db = MirraThreatDB
        ns.RebuildCurve()
        if ns.BuildOptions then ns.BuildOptions() end
        self:UnregisterEvent("ADDON_LOADED")
        return
    end

    if not ns.db then return end

    if event == "NAME_PLATE_UNIT_ADDED" then
        SafeUpdateUnit(arg1)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        HidePlate(C_NamePlate.GetNamePlateForUnit(arg1))
    elseif event == "UNIT_THREAT_LIST_UPDATE" and arg1 and arg1 ~= "player" then
        SafeUpdateUnit(arg1)
    else
        ns.UpdateAll()
    end
end)

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
events:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function Print(msg)
    print("|cffe0a040Mirra's Threat|r: " .. msg)
end

SLASH_MIRRATHREAT1 = "/mthreat"
SLASH_MIRRATHREAT2 = "/mt"
SlashCmdList["MIRRATHREAT"] = function(msg)
    msg = strlower(strtrim(msg or ""))
    if not ns.db then return end

    if msg == "tank" then
        ns.db.mode = "tank"
        ns.ApplySettings()
        Print("role set to Tank.")
    elseif msg == "dps" or msg == "heal" or msg == "healer" then
        ns.db.mode = "dps"
        ns.ApplySettings()
        Print("role set to DPS / Healer.")
    elseif msg == "debug" then
        Print("debug")
        print("  Role: " .. tostring(ns.db.mode) .. ", style: " .. tostring(ns.db.style))
        print("  Interface: " .. tostring(select(4, GetBuildInfo())))
        print("  Secret values: " .. tostring(issecretvalue ~= nil))
        print("  Color curve: " .. tostring(colorCurve ~= nil))
        print("  Last error: " .. tostring(ns.lastError))
    elseif msg == "" or msg == "options" or msg == "config" then
        if ns.OpenOptions then ns.OpenOptions() end
    else
        Print("commands: /mt (options), /mt tank, /mt dps, /mt debug")
    end
end
