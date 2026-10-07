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
    width    = 84,
    height   = 13,
    fontSize = 10,
    textAlign = "CENTER",   -- text position inside the bar: "LEFT", "CENTER", "RIGHT"
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

local MEDIA       = "Interface\\AddOns\\" .. addonName .. "\\media\\"
local BAR_TEXTURE = MEDIA .. "bar"
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

-- How the bar gets its color without ever touching a secret color value:
--
--   bar     StatusBar 0..100, value = threat, fixed "low" color
--   warnBar StatusBar warnAt-1..warnAt, value = threat, fixed "warning" color
--   highBar StatusBar 99..100,          value = threat, fixed "high" color
--
-- warnBar and highBar are anchored to the fill texture of `bar`, so they are
-- exactly as wide as the current threat. Because of their narrow value range
-- they are either completely empty (threat below the threshold) or completely
-- full (threat at/above it) and then paint over the fill below them.
-- Only StatusBar:SetValue() receives the (possibly secret) threat value, which
-- the client explicitly allows. No comparison, no color math, no grey fallback.

local function CreateZoneBar(w, level)
    local b = CreateFrame("StatusBar", nil, w)
    b:SetFrameLevel(w.bar:GetFrameLevel() + level)
    b:SetStatusBarTexture(BAR_TEXTURE)
    b:SetPoint("TOPLEFT", w.bar:GetStatusBarTexture(), "TOPLEFT")
    b:SetPoint("BOTTOMRIGHT", w.bar:GetStatusBarTexture(), "BOTTOMRIGHT")
    b:SetValue(0)
    return b
end

function ns.CreateWidget(parent)
    local w = CreateFrame("Frame", nil, parent)
    w:SetFrameStrata(parent:GetFrameStrata())
    w:SetFrameLevel(parent:GetFrameLevel() + 10)

    -- dark trough behind the fill (its corners are covered by the frame)
    w.bg = w:CreateTexture(nil, "BACKGROUND")
    w.bg:SetTexture(FLAT)
    w.bg:SetVertexColor(0.03, 0.03, 0.04, 0.85)

    w.bar = CreateFrame("StatusBar", nil, w)
    w.bar:SetStatusBarTexture(BAR_TEXTURE)
    w.bar:SetMinMaxValues(0, 100)
    w.bar:SetValue(0)

    w.warnBar = CreateZoneBar(w, 1)
    w.highBar = CreateZoneBar(w, 2)

    -- everything drawn above the fill: frame, threshold marker, text
    w.overlay = CreateFrame("Frame", nil, w)
    w.overlay:SetAllPoints()
    w.overlay:SetFrameLevel(w.bar:GetFrameLevel() + 5)

    -- marker at the warning threshold
    w.tick = w.overlay:CreateTexture(nil, "BACKGROUND")
    w.tick:SetTexture(FLAT)
    w.tick:SetVertexColor(0, 0, 0, 0.3)
    w.tick:SetWidth(1)

    -- rounded frame, 3-slice so the corners never stretch
    w.frameL = w.overlay:CreateTexture(nil, "BORDER")
    w.frameL:SetTexture(MEDIA .. "frame_left")
    w.frameR = w.overlay:CreateTexture(nil, "BORDER")
    w.frameR:SetTexture(MEDIA .. "frame_right")
    w.frameM = w.overlay:CreateTexture(nil, "BORDER")
    w.frameM:SetTexture(MEDIA .. "frame_mid")
    w.frameL:SetPoint("TOPLEFT")
    w.frameL:SetPoint("BOTTOMLEFT")
    w.frameR:SetPoint("TOPRIGHT")
    w.frameR:SetPoint("BOTTOMRIGHT")
    w.frameM:SetPoint("TOPLEFT", w.frameL, "TOPRIGHT")
    w.frameM:SetPoint("BOTTOMRIGHT", w.frameR, "BOTTOMLEFT")

    w.text = w.overlay:CreateFontString(nil, "OVERLAY")
    w.text:SetShadowColor(0, 0, 0, 1)

    ns.LayoutWidget(w)
    return w
end

local function ZoneColors()
    local db, c = ns.db or ns.defaults, ns.colors
    if db.mode == "dps" then
        return c.good, c.warn, c.bad   -- low, warning, high
    end
    return c.bad, c.warn, c.good
end

function ns.LayoutWidget(w)
    local db = ns.db or ns.defaults
    local showBar  = db.style ~= "text"
    local showText = db.style ~= "bar"

    -- fixed colors per zone, only change when the settings change
    local low, mid, high = ZoneColors()
    w.bar:SetStatusBarColor(low[1], low[2], low[3], 1)
    w.warnBar:SetStatusBarColor(mid[1], mid[2], mid[3], 1)
    w.highBar:SetStatusBarColor(high[1], high[2], high[3], 1)
    w.warnBar:SetMinMaxValues(db.warnAt - 1, db.warnAt)
    w.highBar:SetMinMaxValues(99, 100)

    w.text:ClearAllPoints()

    if showBar then
        local h = db.height
        local inset = h * 4 / 32          -- matches the frame texture's border
        w:SetSize(db.width, h)

        w.frameL:SetWidth(h / 2)
        w.frameR:SetWidth(h / 2)
        for _, t in ipairs({ w.frameL, w.frameM, w.frameR }) do t:Show() end

        w.bg:ClearAllPoints()
        w.bg:SetPoint("TOPLEFT", inset, -inset)
        w.bg:SetPoint("BOTTOMRIGHT", -inset, inset)
        w.bg:Show()

        w.bar:ClearAllPoints()
        w.bar:SetPoint("TOPLEFT", inset, -inset)
        w.bar:SetPoint("BOTTOMRIGHT", -inset, inset)
        w.bar:Show()
        w.warnBar:Show()
        w.highBar:Show()

        local x = (db.width - 2 * inset) * db.warnAt / 100
        w.tick:ClearAllPoints()
        w.tick:SetPoint("TOPLEFT", w.bar, "TOPLEFT", x, 0)
        w.tick:SetPoint("BOTTOMLEFT", w.bar, "BOTTOMLEFT", x, 0)
        w.tick:Show()

        -- resource bar look: light text with a soft shadow, inside the bar
        w.text:SetFont(STANDARD_TEXT_FONT, db.fontSize, "")
        w.text:SetShadowOffset(1, -1)
        w.text:SetTextColor(0.96, 0.96, 0.96, 1)
        local pad = math.max(3, h * 0.3)
        if db.textAlign == "CENTER" then
            w.text:SetPoint("CENTER", w, "CENTER", 0, 0)
        elseif db.textAlign == "RIGHT" then
            w.text:SetPoint("RIGHT", w, "RIGHT", -pad, 0)
        else
            w.text:SetPoint("LEFT", w, "LEFT", pad, 0)
        end
    else
        w:SetSize(db.width, db.fontSize + 4)
        for _, t in ipairs({ w.frameL, w.frameM, w.frameR, w.bg, w.tick }) do t:Hide() end
        w.bar:Hide()
        w.warnBar:Hide()
        w.highBar:Hide()

        -- text only: colored by threat, outlined for readability
        w.text:SetFont(STANDARD_TEXT_FONT, db.fontSize, "OUTLINE")
        w.text:SetShadowOffset(1, -1)
        w.text:SetPoint("CENTER", w, "CENTER", 0, 0)
    end

    if showText then w.text:Show() else w.text:Hide() end
    w.layoutStamp = ns.layoutStamp
end

local function SetBarValues(w, pct)
    w.bar:SetValue(pct)
    w.warnBar:SetValue(pct)
    w.highBar:SetValue(pct)
end

-- Text color for secret values: color curve first, then the tanking flag.
local function ColorSecretText(w, pct, isTanking)
    if colorCurve then
        local ok, err = pcall(function()
            local c = colorCurve:Evaluate(pct)
            w.text:SetTextColor(c:GetRGBA())
        end)
        if ok then return "curve" end
        NoteError("Text color (curve)", err)
    end

    if (IsSecret(isTanking) or isTanking ~= nil) and C_CurveUtil and C_CurveUtil.EvaluateColorFromBoolean then
        local ok, err = pcall(function()
            local _, _, high = ZoneColors()
            local low = (ns.db.mode == "dps") and ns.colors.good or ns.colors.bad
            local c = C_CurveUtil.EvaluateColorFromBoolean(isTanking,
                CreateColor(high[1], high[2], high[3], 1),
                CreateColor(low[1], low[2], low[3], 1))
            w.text:SetTextColor(c:GetRGBA())
        end)
        if ok then return "boolean" end
        NoteError("Text color (boolean)", err)
    end

    w.text:SetTextColor(1, 1, 1, 1)
    return "none"
end

-- Sets value and color. `pct` may be a plain number or a secret number,
-- `isTanking` (optional) may be a plain or secret boolean.
function ns.RenderWidget(w, pct, isTanking)
    if w.layoutStamp ~= ns.layoutStamp then
        ns.LayoutWidget(w)
    end

    if IsSecret(pct) then
        local ok, err = pcall(function()
            w.text:SetText(string.format("%.0f%%", pct))
            SetBarValues(w, pct)
        end)
        if not ok then
            NoteError("Secret value", err)
            return false
        end
        if (ns.db or ns.defaults).style == "text" then
            ns.textColorMethod = ColorSecretText(w, pct, isTanking)
        end
        return true
    end

    local display = math.floor(pct + 0.5)
    if display <= 0 and (ns.db or ns.defaults).hideZero then
        return false
    end

    local c = ns.GetColor(display)
    w.text:SetText(display .. "%")
    if (ns.db or ns.defaults).style == "text" then
        w.text:SetTextColor(c[1], c[2], c[3], 1)
    end
    SetBarValues(w, math.min(display, 100))
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

    local isTanking, _, percent = UnitDetailedThreatSituation("player", unit)

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

    if ns.RenderWidget(w, percent, isTanking) then
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
        print("  Text color method: " .. tostring(ns.textColorMethod or "-"))
        print("  Last error: " .. tostring(ns.lastError))
    elseif msg == "" or msg == "options" or msg == "config" then
        if ns.OpenOptions then ns.OpenOptions() end
    else
        Print("commands: /mt (options), /mt tank, /mt dps, /mt debug")
    end
end
