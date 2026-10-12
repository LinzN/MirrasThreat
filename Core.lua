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
    theme    = "resource", -- bar design, see ns.themes
    width    = 84,
    height   = 13,
    fontSize = 10,
    textAlign = "CENTER",   -- text position inside the bar: "LEFT", "CENTER", "RIGHT"
    offsetY  = 0,
    warnAt   = 80,        -- threshold (in %) for the warning color
    hideZero = true,      -- hide the display while threat is 0 %
    hideSolo = true,      -- only show while in a party or raid
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

-- Bar designs. Every design uses the same zone-bar mechanics (see below);
-- only textures, frame and insets differ.
--   frame   3-slice frame textures (<frame>_left/_mid/_right), drawn above the fill
--   border  plain 1 px dark border instead of a frame
--   insetX/insetY  fill inset as a fraction of the bar height (frame designs)
--   segments       number of segments (dividers drawn above the fill)
--   bgShape        3-slice background shape instead of a plain rectangle
ns.themes = {
    { key = "resource", label = "Resource", bar = MEDIA .. "bar",  frame = "frame",
      insetX = 4 / 32, insetY = 4 / 32, bg = { 0.03, 0.03, 0.04, 0.85 } },
    { key = "capsule",  label = "Capsule",  bar = MEDIA .. "bar",  frame = "capsule", bgShape = "capsule_bg",
      insetX = 0.30,   insetY = 4 / 32, bg = { 0.03, 0.03, 0.04, 0.85 } },
    { key = "flat",     label = "Flat",     bar = MEDIA .. "flat", border = true,
      bg = { 0.06, 0.06, 0.07, 0.80 } },
    { key = "segments", label = "Segments", bar = MEDIA .. "flat", border = true, segments = 10,
      bg = { 0.06, 0.06, 0.07, 0.80 } },
    { key = "classic",  label = "Classic",  bar = "Interface\\TargetingFrame\\UI-StatusBar", frame = "classic",
      insetX = 4 / 32, insetY = 4 / 32, bg = { 0.02, 0.02, 0.02, 0.80 } },
}

function ns.GetTheme()
    local key = (ns.db or ns.defaults).theme
    for _, t in ipairs(ns.themes) do
        if t.key == key then return t end
    end
    return ns.themes[1]
end

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

    -- plain 1 px border (flat designs)
    w.border = w:CreateTexture(nil, "BACKGROUND", nil, -2)
    w.border:SetTexture(FLAT)
    w.border:SetVertexColor(0, 0, 0, 0.9)
    w.border:SetAllPoints()

    -- dark trough behind the fill (its corners are covered by the frame)
    w.bg = w:CreateTexture(nil, "BACKGROUND", nil, -1)
    w.bg:SetTexture(FLAT)
    w.bg:SetVertexColor(0.03, 0.03, 0.04, 0.85)

    -- shaped background (capsule), 3-slice like the frame
    w.bgL = w:CreateTexture(nil, "BACKGROUND", nil, -1)
    w.bgR = w:CreateTexture(nil, "BACKGROUND", nil, -1)
    w.bgM = w:CreateTexture(nil, "BACKGROUND", nil, -1)
    w.bgL:SetPoint("TOPLEFT")
    w.bgL:SetPoint("BOTTOMLEFT")
    w.bgR:SetPoint("TOPRIGHT")
    w.bgR:SetPoint("BOTTOMRIGHT")
    w.bgM:SetPoint("TOPLEFT", w.bgL, "TOPRIGHT")
    w.bgM:SetPoint("BOTTOMRIGHT", w.bgR, "BOTTOMLEFT")

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
    w.frameR = w.overlay:CreateTexture(nil, "BORDER")
    w.frameM = w.overlay:CreateTexture(nil, "BORDER")
    w.frameL:SetPoint("TOPLEFT")
    w.frameL:SetPoint("BOTTOMLEFT")
    w.frameR:SetPoint("TOPRIGHT")
    w.frameR:SetPoint("BOTTOMRIGHT")
    w.frameM:SetPoint("TOPLEFT", w.frameL, "TOPRIGHT")
    w.frameM:SetPoint("BOTTOMRIGHT", w.frameR, "BOTTOMLEFT")

    w.dividers = {}   -- segment dividers, created on demand

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

    local theme = ns.GetTheme()

    -- textures only change when the design changes
    if w.themeKey ~= theme.key then
        for _, b in ipairs({ w.bar, w.warnBar, w.highBar }) do
            b:SetStatusBarTexture(theme.bar)
        end
        -- the zone bars follow the main fill texture; re-anchor in case
        -- the client created a new texture object
        local fill = w.bar:GetStatusBarTexture()
        for _, b in ipairs({ w.warnBar, w.highBar }) do
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", fill, "TOPLEFT")
            b:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
        end
        if theme.frame then
            w.frameL:SetTexture(MEDIA .. theme.frame .. "_left")
            w.frameM:SetTexture(MEDIA .. theme.frame .. "_mid")
            w.frameR:SetTexture(MEDIA .. theme.frame .. "_right")
        end
        w.bg:SetVertexColor(theme.bg[1], theme.bg[2], theme.bg[3], theme.bg[4])
        if theme.bgShape then
            w.bgL:SetTexture(MEDIA .. theme.bgShape .. "_left")
            w.bgM:SetTexture(MEDIA .. theme.bgShape .. "_mid")
            w.bgR:SetTexture(MEDIA .. theme.bgShape .. "_right")
            for _, t in ipairs({ w.bgL, w.bgM, w.bgR }) do
                t:SetVertexColor(theme.bg[1], theme.bg[2], theme.bg[3], theme.bg[4])
            end
        end
        w.themeKey = theme.key
        -- zone colors were reset with the texture
        w.bar:SetStatusBarColor(low[1], low[2], low[3], 1)
        w.warnBar:SetStatusBarColor(mid[1], mid[2], mid[3], 1)
        w.highBar:SetStatusBarColor(high[1], high[2], high[3], 1)
    end

    for _, d in ipairs(w.dividers) do d:Hide() end

    if showBar then
        local h = db.height
        local insetX, insetY
        if theme.frame then
            insetX, insetY = h * theme.insetX, h * theme.insetY
        else
            insetX, insetY = 1, 1
        end
        w:SetSize(db.width, h)

        if theme.frame then
            w.frameL:SetWidth(h / 2)
            w.frameR:SetWidth(h / 2)
            for _, t in ipairs({ w.frameL, w.frameM, w.frameR }) do t:Show() end
        else
            for _, t in ipairs({ w.frameL, w.frameM, w.frameR }) do t:Hide() end
        end
        if theme.border then w.border:Show() else w.border:Hide() end

        if theme.bgShape then
            w.bg:Hide()
            w.bgL:SetWidth(h / 2)
            w.bgR:SetWidth(h / 2)
            for _, t in ipairs({ w.bgL, w.bgM, w.bgR }) do t:Show() end
        else
            for _, t in ipairs({ w.bgL, w.bgM, w.bgR }) do t:Hide() end
            w.bg:ClearAllPoints()
            w.bg:SetPoint("TOPLEFT", insetX, -insetY)
            w.bg:SetPoint("BOTTOMRIGHT", -insetX, insetY)
            w.bg:Show()
        end

        w.bar:ClearAllPoints()
        w.bar:SetPoint("TOPLEFT", insetX, -insetY)
        w.bar:SetPoint("BOTTOMRIGHT", -insetX, insetY)
        w.bar:Show()
        w.warnBar:Show()
        w.highBar:Show()

        local inner = db.width - 2 * insetX
        if theme.segments then
            -- dark gaps between the segments; the threshold marker is not needed
            local gap = inner >= 100 and 2 or 1
            for i = 1, theme.segments - 1 do
                local d = w.dividers[i]
                if not d then
                    d = w.overlay:CreateTexture(nil, "BACKGROUND")
                    d:SetTexture(FLAT)
                    d:SetVertexColor(0.04, 0.04, 0.05, 0.95)
                    w.dividers[i] = d
                end
                local x = inner * i / theme.segments - gap / 2
                d:SetWidth(gap)
                d:ClearAllPoints()
                d:SetPoint("TOPLEFT", w.bar, "TOPLEFT", x, 0)
                d:SetPoint("BOTTOMLEFT", w.bar, "BOTTOMLEFT", x, 0)
                d:Show()
            end
            w.tick:Hide()
        else
            local x = inner * db.warnAt / 100
            w.tick:ClearAllPoints()
            w.tick:SetPoint("TOPLEFT", w.bar, "TOPLEFT", x, 0)
            w.tick:SetPoint("BOTTOMLEFT", w.bar, "BOTTOMLEFT", x, 0)
            w.tick:Show()
        end

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
        for _, t in ipairs({ w.frameL, w.frameM, w.frameR, w.bg, w.tick, w.border, w.bgL, w.bgM, w.bgR }) do t:Hide() end
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

local CAST_BAR_KEYS = { "castBar", "CastBar", "castbar", "CastingBar", "castingBar" }
local CAST_FALLBACK_OFFSET = 14   -- used when no cast bar frame can be found

local function GetCastBar(plate)
    local uf = plate.UnitFrame
    if not uf then return nil, nil end
    for _, key in ipairs(CAST_BAR_KEYS) do
        local cb = uf[key]
        if type(cb) == "table" and cb.GetObjectType then
            return cb, key
        end
    end
    return nil, nil
end
ns.GetCastBar = GetCastBar

-- Is the unit casting or channeling? Works with secret return values:
-- a secret value is never nil, so it counts as "casting".
local function IsCasting(unit)
    if not unit then return false end
    local ok, casting = pcall(function()
        local name = UnitCastingInfo and UnitCastingInfo(unit)
        if IsSecret(name) or name ~= nil then return true end
        local cname = UnitChannelInfo and UnitChannelInfo(unit)
        return IsSecret(cname) or cname ~= nil
    end)
    return ok and casting
end
ns.IsCasting = IsCasting

-- True when the cast bar sits below the health bar (so it would cover us).
local function CastBarIsBelow(castBar, healthAnchor)
    local ok, below = pcall(function()
        local cb, hb = castBar:GetBottom(), healthAnchor:GetBottom()
        return cb == nil or hb == nil or cb < hb
    end)
    return (not ok) or below
end

-- Places the widget under the health bar, or under the cast bar while
-- the enemy is casting. Casting is detected from the unit (events + API)
-- and from the cast bar frame itself, whichever reports it.
local function AnchorWidget(w, plate, castingOverride)
    local anchor = GetPlateAnchor(plate)
    local castBar = GetCastBar(plate)

    local casting = castingOverride
    if casting == nil then
        casting = IsCasting(w.unit)
    end
    if not casting and castBar and w.castBarShown then
        -- still fading out after the cast? (some clients only fade the alpha)
        local ok, visible = pcall(function()
            return castBar:IsShown() and (castBar:GetAlpha() or 1) > 0.05
        end)
        casting = ok and visible or false
    end

    local extra = 0
    if casting then
        if castBar and CastBarIsBelow(castBar, anchor) then
            anchor = castBar
        elseif not castBar then
            extra = CAST_FALLBACK_OFFSET
        end
    end

    local y = -2 + ns.db.offsetY - extra
    if w.anchor ~= anchor or w.anchorY ~= y then
        w:ClearAllPoints()
        w:SetPoint("TOP", anchor, "BOTTOM", 0, y)
        w.anchor, w.anchorY = anchor, y
    end
end

local hookedCastBars = {}

-- Also follow the cast bar frame directly (covers its fade-out). Nameplates
-- and their cast bars are recycled by the client, so hook each one once.
local function HookCastBar(plate)
    local castBar = GetCastBar(plate)
    if not castBar or hookedCastBars[castBar] then return end
    hookedCastBars[castBar] = true
    local function OnVisibility(shown)
        local w = widgets[plate]
        if w and ns.db then
            w.castBarShown = shown
            local ok, err = pcall(AnchorWidget, w, plate)
            if not ok then NoteError("Cast bar", err) end
        end
    end
    local ok, err = pcall(function()
        castBar:HookScript("OnShow", function() OnVisibility(true) end)
        castBar:HookScript("OnHide", function() OnVisibility(false) end)
    end)
    if not ok then NoteError("Cast bar hook", err) end
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

    if w.unit ~= unit then
        w.unit = unit
        w.castBarShown = nil
    end
    HookCastBar(plate)
    AnchorWidget(w, plate)

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
        w.anchor, w.anchorY = nil, nil
        ns.LayoutWidget(w)
    end
    ns.UpdateAll()
    if ns.RefreshPreview then ns.RefreshPreview() end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
local CAST_EVENTS

-- Only real nameplate tokens ("nameplate1" ...) may be passed to
-- C_NamePlate.GetNamePlateForUnit. Threat events also fire for tokens like
-- "target", "targettarget" or "party1target", which the client rejects.
local function IsNameplateToken(unit)
    return type(unit) == "string"
        and not IsSecret(unit)
        and unit:match("^nameplate%d+$") ~= nil
end

local function GetPlate(unit)
    if not IsNameplateToken(unit) then return nil end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if ok then return plate end
    return nil
end

local function SafeUpdateUnit(unit)
    local plate = GetPlate(unit)
    if plate then
        local ok, err = pcall(UpdatePlate, plate, unit)
        if not ok then NoteError("Update", err) end
    end
end

-- Many events can arrive in the same frame (especially in groups);
-- refresh all nameplates at most once per frame.
local updateQueued = false
local function QueueUpdateAll()
    if updateQueued then return end
    if not (C_Timer and C_Timer.After) then
        ns.UpdateAll()
        return
    end
    updateQueued = true
    C_Timer.After(0, function()
        updateQueued = false
        ns.UpdateAll()
    end)
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
        HidePlate(GetPlate(arg1))
    elseif CAST_EVENTS[event] ~= nil then
        -- enemy started/stopped casting: move the display below/back up
        local plate = GetPlate(arg1)
        local w = plate and widgets[plate]
        if w then
            w.unit = arg1
            local override = CAST_EVENTS[event] or nil   -- true on start, API check otherwise
            local ok, err = pcall(AnchorWidget, w, plate, override)
            if not ok then NoteError("Cast event", err) end
        end
    elseif event == "UNIT_THREAT_LIST_UPDATE" then
        if IsNameplateToken(arg1) then
            SafeUpdateUnit(arg1)
        else
            -- "target", "targettarget", "party1target" ...: refresh all plates instead
            QueueUpdateAll()
        end
    else
        QueueUpdateAll()
    end
end)

-- true = cast started, false = cast ended (state is then re-read from the API)
CAST_EVENTS = {
    UNIT_SPELLCAST_START          = true,
    UNIT_SPELLCAST_CHANNEL_START  = true,
    UNIT_SPELLCAST_EMPOWER_START  = true,
    UNIT_SPELLCAST_STOP           = false,
    UNIT_SPELLCAST_CHANNEL_STOP   = false,
    UNIT_SPELLCAST_EMPOWER_STOP   = false,
    UNIT_SPELLCAST_INTERRUPTED    = false,
    UNIT_SPELLCAST_FAILED         = false,
}
for event in pairs(CAST_EVENTS) do
    pcall(events.RegisterEvent, events, event)   -- not every client knows every event
end

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
        local okp, tplate = pcall(C_NamePlate.GetNamePlateForUnit, "target")
        if okp and tplate then
            local cb, key = GetCastBar(tplate)
            print("  Target cast bar: " .. tostring(key or "not found")
                .. (cb and (", shown: " .. tostring(cb:IsShown())) or ""))
            print("  Target casting: " .. tostring(IsCasting("target")))
        else
            print("  Target cast bar: no target nameplate")
        end
        print("  Last error: " .. tostring(ns.lastError))
    elseif msg == "" or msg == "options" or msg == "config" then
        if ns.OpenOptions then ns.OpenOptions() end
    else
        Print("commands: /mthreat (options), /mthreat tank, /mthreat dps, /mthreat debug")
    end
end
