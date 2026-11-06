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
    hideSolo = true,      -- only show while in a party or raid
    tankInsecure   = true, -- tank: orange pulsing bar while aggro is insecure
    tankShowTarget = true, -- tank: show who the enemy is attacking after losing aggro
    attach         = true, -- glue the bar to the health bar, cast bar moves below it
    attachHeight   = 9,    -- bar height on a medium nameplate, scales with the nameplate size
    attachWidth    = 100,  -- % of the health bar width
    attachFontSize = 9,    -- text size on a medium nameplate, scales with the nameplate size
    attachSpacing  = 0,    -- extra space between health bar and threat bar (0 = they share one line)
}

-- Blizzard's modern nameplate look (Blizzard_NamePlates.xml / UpdateAnchors)
local PLATE_BAR_ATLAS      = "UI-HUD-CoolDownManager-Bar"
local PLATE_BG_ATLAS       = "UI-HUD-CoolDownManager-Bar-BG"
local PLATE_DESELECT_ATLAS = "ui-hud-nameplates-deselected-overlay"

ns.colors = {
    good = { 0.30, 0.85, 0.40 },
    warn = { 1.00, 0.78, 0.18 },
    bad  = { 0.95, 0.26, 0.22 },
    insecure = { 1.00, 0.50, 0.10 },
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

    -- dark trough behind the fill (its corners are covered by the frame);
    -- when attached, bg is the black edge and trough the dark inside
    w.bg = w:CreateTexture(nil, "BACKGROUND")
    w.bg:SetTexture(FLAT)
    w.bg:SetVertexColor(0.03, 0.03, 0.04, 0.85)
    w.trough = w:CreateTexture(nil, "BACKGROUND", nil, 1)
    w.trough:SetTexture(FLAT)
    w.trough:SetVertexColor(0.03, 0.03, 0.04, 0.9)

    -- Blizzard's nameplate bar background, drawn unchanged but clipped at
    -- the top: its top edge is cut off, so the health bar's bottom line is
    -- the only line between the two bars (stretching the art instead would
    -- shift the frame against the bar)
    w.bgClip = CreateFrame("Frame", nil, w)
    w.bgClip:SetFrameLevel(w:GetFrameLevel())
    w.bgClip:SetClipsChildren(true)
    -- the art lives on a child frame: child frames are always clipped
    w.bgArt = CreateFrame("Frame", nil, w.bgClip)
    w.bgArt:SetFrameLevel(w:GetFrameLevel())
    w.plateBg = w.bgArt:CreateTexture(nil, "BACKGROUND")
    w.plateBg:SetAllPoints()
    w.plateBg:SetAtlas(PLATE_BG_ATLAS)
    w.bgClip:Hide()

    w.bar = CreateFrame("StatusBar", nil, w)
    w.bar:SetFrameLevel(w:GetFrameLevel() + 1)
    w.bar:SetStatusBarTexture(BAR_TEXTURE)
    w.bar:SetMinMaxValues(0, 100)
    w.bar:SetValue(0)
    -- the warning marker follows the bar's real width (attached bars take
    -- the width of the nameplate)
    w.bar:SetScript("OnSizeChanged", function() ns.PlaceTick(w) end)

    w.warnBar = CreateZoneBar(w, 1)
    w.highBar = CreateZoneBar(w, 2)

    -- Tank aggro state, driven by the threat status (0-3) instead of the
    -- percentage. Same gate trick: full-width bars with a tiny value range.
    --   status 2 = you are tanking, but someone else already has more threat
    --   status 3 = you are tanking securely
    w.insecureBar = CreateFrame("StatusBar", nil, w)
    w.insecureBar:SetFrameLevel(w.bar:GetFrameLevel() + 3)
    w.insecureBar:SetAllPoints(w.bar)
    w.insecureBar:SetStatusBarTexture(BAR_TEXTURE)
    w.insecureBar:SetMinMaxValues(1, 2)
    w.insecureBar:SetValue(0)
    local pulse = w.insecureBar:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.35)
    fade:SetDuration(0.45)
    pulse:Play()
    w.insecurePulse = pulse

    w.secureBar = CreateFrame("StatusBar", nil, w)
    w.secureBar:SetFrameLevel(w.bar:GetFrameLevel() + 4)
    w.secureBar:SetAllPoints(w.bar)
    w.secureBar:SetStatusBarTexture(BAR_TEXTURE)
    w.secureBar:SetMinMaxValues(2, 3)
    w.secureBar:SetValue(0)

    -- everything drawn above the fill: frame, threshold marker, text
    w.overlay = CreateFrame("Frame", nil, w)
    w.overlay:SetAllPoints()
    w.overlay:SetFrameLevel(w.bar:GetFrameLevel() + 5)

    -- darkening when the enemy is not your target, like the health bar
    w.dim = w.overlay:CreateTexture(nil, "ARTWORK")
    w.dim:SetPoint("TOPLEFT", w.bar, "TOPLEFT", 0, 0)
    w.dim:SetPoint("BOTTOMRIGHT", w.bar, "BOTTOMRIGHT", 0, -1)
    w.dim:Hide()

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

    -- tank: name of the player the enemy is attacking (only after losing aggro)
    w.aggroText = w.overlay:CreateFontString(nil, "OVERLAY")
    w.aggroText:SetShadowColor(0, 0, 0, 1)
    w.aggroText:SetShadowOffset(1, -1)
    w.aggroText:SetPoint("TOP", w, "BOTTOM", 0, -2)

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

-- true when the player uses Blizzard's modern nameplate style
-- (classic style has its own fixed border art)
function ns.IsModernPlate()
    local o = NamePlateSetupOptions
    return not (o and o.useClassicHealthBar)
end

-- Fill textures: Blizzard's nameplate bar atlas or the Mirra's glossy bar.
local function SetBarTextures(w, plateLook)
    if w.plateLook == plateLook then return end
    w.plateLook = plateLook
    for _, b in ipairs({ w.bar, w.warnBar, w.highBar, w.insecureBar, w.secureBar }) do
        b:SetStatusBarTexture(BAR_TEXTURE)
        if plateLook then
            b:GetStatusBarTexture():SetAtlas(PLATE_BAR_ATLAS)
        end
    end
end

-- Attached scale: the settings are for a medium nameplate.
local function PlateScale()
    local scale = NamePlateSetupOptions and NamePlateSetupOptions.verticalScale
    if type(scale) ~= "number" or IsSecret(scale) or scale <= 0 then scale = 1 end
    return scale
end

function ns.AttachedFontSize()
    local db = ns.db or ns.defaults
    return math.max(6, math.floor(db.attachFontSize * PlateScale() + 0.5))
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
    w.aggroText:ClearAllPoints()
    w.aggroText:SetPoint("TOP", w, "BOTTOM", 0, -2)
    w.aggroText:SetJustifyH("CENTER")
    w.trough:Hide()

    w.dim:Hide()
    w.bgClip:Hide()
    w.attachedModern = false

    if showBar and w.attached then
        -- glued under the health bar; width comes from the anchors,
        -- height and text scale with the nameplate size
        local h = ns.AttachedHeight()
        local modern = ns.IsModernPlate()
        w.attachedModern = modern
        w:SetHeight(h)
        for _, t in ipairs({ w.frameL, w.frameM, w.frameR }) do t:Hide() end
        SetBarTextures(w, modern)

        w.bar:ClearAllPoints()
        w.bg:ClearAllPoints()
        w.bgClip:ClearAllPoints()
        w.bgArt:ClearAllPoints()
        if modern then
            -- exactly like Blizzard's health bar background (same offsets),
            -- only the part above the bar is clipped away: the health bar's
            -- bottom line is the threat bar's top line
            w.bar:SetAllPoints()
            w.bgArt:SetPoint("TOPLEFT", w.bar, "TOPLEFT", -2, 3)
            w.bgArt:SetPoint("BOTTOMRIGHT", w.bar, "BOTTOMRIGHT", 6, -6)
            w.bgClip:SetPoint("TOPLEFT", w.bar, "TOPLEFT", -2, 0)
            w.bgClip:SetPoint("BOTTOMRIGHT", w.bar, "BOTTOMRIGHT", 6, -6)
            w.bgClip:Show()
            w.bg:Hide()
            w.dim:SetAtlas(PLATE_DESELECT_ATLAS)
            w.tick:SetVertexColor(0, 0, 0, 0.35)
        else
            w.bgClip:Hide()
            w.bg:Show()
            -- classic style: flat black edge
            w.bg:SetAllPoints()
            w.bg:SetVertexColor(0, 0, 0, 1)
            w.trough:ClearAllPoints()
            -- no top edge: the line above belongs to the health bar
            w.trough:SetPoint("TOPLEFT", 1, 0)
            w.trough:SetPoint("BOTTOMRIGHT", -1, 1)
            w.trough:Show()
            w.bar:SetPoint("TOPLEFT", 1, 0)
            w.bar:SetPoint("BOTTOMRIGHT", -1, 1)
            w.tick:SetVertexColor(1, 0.85, 0.35, 0.9)
        end
        w.bar:Show()
        w.warnBar:Show()
        w.highBar:Show()
        w.tick:Show()

        -- same font as the nameplate's health text
        local font, _, flags = STANDARD_TEXT_FONT, nil, ""
        if SystemFont_NamePlate and SystemFont_NamePlate.GetFont then
            local f, _, fl = SystemFont_NamePlate:GetFont()
            if f then font, flags = f, fl or "" end
        end
        local size = ns.AttachedFontSize()
        w.text:SetFont(font, size, flags)
        w.text:SetShadowOffset(1, -1)
        w.text:SetTextColor(1, 1, 1, 1)
        local pad = 5
        local align = db.textAlign
        -- the "who has aggro" name sits inside the bar on the left
        if db.mode == "tank" and db.tankShowTarget then align = "RIGHT" end
        if align == "CENTER" then
            w.text:SetPoint("CENTER", w, "CENTER", 0, 0)
        elseif align == "RIGHT" then
            w.text:SetPoint("RIGHT", w, "RIGHT", -pad, 0)
        else
            w.text:SetPoint("LEFT", w, "LEFT", pad, 0)
        end
        w.aggroText:ClearAllPoints()
        w.aggroText:SetPoint("LEFT", w, "LEFT", pad, 0)
        w.aggroText:SetPoint("RIGHT", w.text, "LEFT", -4, 0)
        w.aggroText:SetJustifyH("LEFT")
        w.aggroText:SetWordWrap(false)
    elseif showBar then
        SetBarTextures(w, false)
        local h = db.height
        local inset = h * 4 / 32          -- matches the frame texture's border
        w:SetSize(db.width, h)

        w.frameL:SetWidth(h / 2)
        w.frameR:SetWidth(h / 2)
        for _, t in ipairs({ w.frameL, w.frameM, w.frameR }) do t:Show() end

        w.bg:ClearAllPoints()
        w.bg:SetPoint("TOPLEFT", inset, -inset)
        w.bg:SetPoint("BOTTOMRIGHT", -inset, inset)
        w.bg:SetVertexColor(0.03, 0.03, 0.04, 0.85)
        w.bg:Show()

        w.bar:ClearAllPoints()
        w.bar:SetPoint("TOPLEFT", inset, -inset)
        w.bar:SetPoint("BOTTOMRIGHT", -inset, inset)
        w.bar:Show()
        w.warnBar:Show()
        w.highBar:Show()

        w.tick:SetVertexColor(0, 0, 0, 0.3)
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

    -- tank extras
    local isTank = db.mode == "tank"
    local ins, good = ns.colors.insecure, ns.colors.good
    w.insecureBar:SetStatusBarColor(ins[1], ins[2], ins[3], 1)
    w.secureBar:SetStatusBarColor(good[1], good[2], good[3], 1)
    if isTank and db.tankInsecure and showBar then
        w.insecureBar:Show()
        w.secureBar:Show()
    else
        w.insecureBar:Hide()
        w.secureBar:Hide()
    end
    local aggroSize = math.max(7, db.fontSize - 1)
    if showBar and w.attached then
        aggroSize = ns.AttachedFontSize()
    end
    w.aggroText:SetFont(STANDARD_TEXT_FONT, aggroSize, "OUTLINE")
    if isTank and db.tankShowTarget then w.aggroText:Show() else w.aggroText:Hide() end

    ns.PlaceTick(w)
    w.layoutStamp = ns.layoutStamp
end

-- Height of an attached bar: the setting is for a medium nameplate and
-- scales with the nameplate size the player picked (small ... huge).
function ns.AttachedHeight()
    local db = ns.db or ns.defaults
    return math.max(4, math.floor(db.attachHeight * PlateScale() + 0.5))
end

-- Distance from the health bar's fill to the threat bar's fill: the
-- health bar's bottom edge line (shared by both bars) plus extra spacing.
local SHARED_LINE_MODERN  = 2   -- bottom edge of Blizzard's bar background art
local SHARED_LINE_CLASSIC = 1
function ns.AttachedGap()
    local db = ns.db or ns.defaults
    local line = ns.IsModernPlate() and SHARED_LINE_MODERN or SHARED_LINE_CLASSIC
    return line + math.floor(db.attachSpacing * PlateScale() + 0.5)
end

-- Room the cast bar has to move down: gap + bar (+ shadow of the bar art).
function ns.AttachedRoom()
    -- the modern bar art has a soft shadow below the bar, keep it off the cast bar
    local shadow = ns.IsModernPlate() and 4 or 0
    return ns.AttachedGap() + ns.AttachedHeight() + shadow
end

-- Warning marker at warnAt % of the bar's actual width.
function ns.PlaceTick(w)
    local db = ns.db or ns.defaults
    local ok, width = pcall(w.bar.GetWidth, w.bar)
    if not ok or not width or IsSecret(width) or width <= 0 then return end
    local x = width * db.warnAt / 100
    w.tick:ClearAllPoints()
    w.tick:SetPoint("TOPLEFT", w.bar, "TOPLEFT", x, 0)
    w.tick:SetPoint("BOTTOMLEFT", w.bar, "BOTTOMLEFT", x, 0)
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

local CLEAR = CreateColor(0, 0, 0, 0)
local AGGRO_NAME = CreateColor(1, 0.45, 0.35, 1)

-- Tank state: insecure/secure aggro bars and "who has aggro".
-- status, isTanking and aggroName may all be secret values.
local function UpdateTankExtras(w, isTanking, status, aggroName)
    local db = ns.db or ns.defaults
    if db.mode ~= "tank" then return end

    if db.tankInsecure then
        local value = 0
        if IsSecret(status) or status ~= nil then value = status end
        local ok, err = pcall(function()
            w.insecureBar:SetValue(value)
            w.secureBar:SetValue(value)
        end)
        if not ok then NoteError("Tank status", err) end
    end

    if db.tankShowTarget then
        local ok, err = pcall(function()
            w.aggroText:SetText(aggroName)
            -- visible only while someone else has aggro
            if IsSecret(isTanking) then
                if C_CurveUtil and C_CurveUtil.EvaluateColorFromBoolean then
                    local c = C_CurveUtil.EvaluateColorFromBoolean(isTanking, CLEAR, AGGRO_NAME)
                    w.aggroText:SetTextColor(c:GetRGBA())
                else
                    w.aggroText:SetTextColor(0, 0, 0, 0)
                end
            elseif isTanking then
                w.aggroText:SetTextColor(0, 0, 0, 0)
            else
                w.aggroText:SetTextColor(AGGRO_NAME:GetRGBA())
            end
        end)
        if not ok then
            NoteError("Aggro target", err)
            w.aggroText:SetTextColor(0, 0, 0, 0)
        end
    end
end

-- Sets value and color. `pct` may be a plain number or a secret number,
-- `isTanking` (optional) may be a plain or secret boolean.
function ns.RenderWidget(w, pct, isTanking, status, aggroName)
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
        UpdateTankExtras(w, isTanking, status, aggroName)
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
    UpdateTankExtras(w, isTanking, status, aggroName)
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

---------------------------------------------------------------------------
-- Attached mode: the bar is glued under the health bar and the cast bar
-- moves down to make room for it.
--
-- Blizzard's nameplate (Blizzard_NamePlateUnitFrame.lua, UpdateAnchors) is
-- built from the bottom: CastBarsContainer at the bottom of the plate, the
-- HealthBarsContainer anchored on top of it. To make room we move the cast
-- bar container down by the bar height and the health bar container up by
-- the same amount relative to it, so the health bar and the name stay
-- exactly where Blizzard put them, for every nameplate style and size.
---------------------------------------------------------------------------

local rooms  = setmetatable({}, { __mode = "k" })   -- [unitFrame] = room in px
local hooked = setmetatable({}, { __mode = "k" })   -- [unitFrame] = plate
local attachFailed = setmetatable({}, { __mode = "k" })

local function CanAttach(plate)
    local uf = plate.UnitFrame
    return uf ~= nil
        and not attachFailed[uf]
        and type(uf.HealthBarsContainer) == "table"
        and type(uf.CastBarsContainer) == "table"
        and type(uf.UpdateAnchors) == "function"
        and not (uf.IsForbidden and uf:IsForbidden())
        and uf:IsShown()          -- hidden: another nameplate addon draws the plate
end

-- Offsets the points of `frame` that are anchored to `relTo` by dy.
-- Everything is read and computed first, so a failure never leaves the
-- frame without anchors.
local function ShiftedPoints(frame, relTo, dy)
    local points = {}
    for i = 1, frame:GetNumPoints() do
        local p, rel, rp, x, y = frame:GetPoint(i)
        x, y = x or 0, y or 0
        if rel == relTo then y = y + dy end
        points[i] = { p, rel, rp, x, y }
    end
    return points
end

local function ApplyPoints(frame, points)
    frame:ClearAllPoints()
    for _, p in ipairs(points) do
        frame:SetPoint(p[1], p[2], p[3], p[4], p[5])
    end
end

-- Second way: rebuild the anchors the way Blizzard's UpdateAnchors does,
-- from NamePlateSetupOptions, with the room added. Used when the current
-- anchors can't be read.
local function ComputedPoints(uf, room)
    local o = NamePlateSetupOptions or {}
    local inset = tonumber(o.insetWidth) or 12
    local spacing = tonumber(o.castBarToHealthBarSpacing) or 2
    local cast = uf.CastBarsContainer
    local xOffset = 0
    local level = uf.PlayerLevelDiffFrame
    if level and level:IsShown() then
        local ok, _, _, relPoint, ox = pcall(level.GetPoint, level, 1)
        if ok and relPoint == "RIGHT" then
            xOffset = -(level:GetWidth() + math.abs(tonumber(ox) or 0))
        end
    end
    local castPoints = {
        { "BOTTOMLEFT", uf, "BOTTOMLEFT", inset, -room },
        { "BOTTOMRIGHT", uf, "BOTTOMRIGHT", -inset, -room },
    }
    local healthPoints = {
        { "BOTTOMLEFT", cast, "TOPLEFT", 0, spacing + room },
        { "BOTTOMRIGHT", cast, "TOPRIGHT", xOffset, spacing + room },
    }
    return castPoints, healthPoints
end

ns.attachStats = { ok = 0, computed = 0, failed = 0 }

local function SetRoom(uf, target)
    local current = rooms[uf] or 0
    if current == target then return true end
    local cast, health = uf.CastBarsContainer, uf.HealthBarsContainer

    -- 1) shift Blizzard's current anchors by the difference
    local delta = target - current
    local ok, err = pcall(function()
        local castPoints = ShiftedPoints(cast, uf, -delta)
        local healthPoints = ShiftedPoints(health, cast, delta)
        ApplyPoints(cast, castPoints)
        ApplyPoints(health, healthPoints)
    end)
    if ok then
        rooms[uf] = target
        ns.attachStats.ok = ns.attachStats.ok + 1
        return true
    end
    ns.attachError = "shift: " .. tostring(err)

    -- 2) rebuild the anchors from the nameplate options
    local ok2, err2 = pcall(function()
        local castPoints, healthPoints = ComputedPoints(uf, target)
        ApplyPoints(cast, castPoints)
        ApplyPoints(health, healthPoints)
    end)
    if ok2 then
        rooms[uf] = target
        ns.attachStats.computed = ns.attachStats.computed + 1
        return true
    end

    ns.attachError = ns.attachError .. " | rebuild: " .. tostring(err2)
    NoteError("Attach", ns.attachError)
    ns.attachStats.failed = ns.attachStats.failed + 1
    attachFailed[uf] = true      -- fall back to the floating bar
    return false
end

-- Blizzard re-anchors the whole nameplate (size/style change, new unit):
-- it starts from scratch, so our room is gone and is added again.
-- Unit frames are pooled and move between nameplates, so the plate is
-- looked up when the hook fires.
local function HookAnchors(uf, plate)
    local first = hooked[uf] == nil
    hooked[uf] = plate
    if not first then return end
    hooksecurefunc(uf, "UpdateAnchors", function(self)
        rooms[self] = 0
        local p = self:GetParent() or hooked[self]
        local w = widgets[p]
        if w and w.attached and w:IsShown() and ns.db then
            ns.LayoutWidget(w)
            SetRoom(self, ns.AttachedRoom())
            ns.LinkPlate(self, w)
        end
    end)
end

---------------------------------------------------------------------------
-- Making the bar part of the nameplate: the yellow target border is
-- stretched around both bars, and the "not your target" darkening of the
-- health bar is mirrored on the threat bar.
---------------------------------------------------------------------------

local overlayOwner = setmetatable({}, { __mode = "k" })  -- [deselectedOverlay] = unitFrame
local linkedBorder = setmetatable({}, { __mode = "k" })  -- [unitFrame] = true

local function MirrorDim(uf)
    local hb = uf and uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar
    local w = uf and widgets[uf:GetParent()]
    if not (hb and w) then return end
    local ok, shown = pcall(function() return hb.deselectedOverlay:IsShown() end)
    w.dim:SetShown(ok and w.attachedModern and w.attached and shown == true or false)
end

local function RestoreBorder(uf)
    if not linkedBorder[uf] then return end
    linkedBorder[uf] = nil
    pcall(function()
        local hb = uf.HealthBarsContainer.healthBar
        local o = NamePlateConstants and NamePlateConstants.SELECTED_BORDER_OFFSETS
        hb.selectedBorder:SetPoint("BOTTOMRIGHT", hb.bgTexture, "BOTTOMRIGHT",
            o and o.bottomRightX or 0, o and o.bottomRightY or 0)
    end)
end

function ns.LinkPlate(uf, w)
    local hb = uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar
    if not hb then return end

    if w.attachedModern then
        -- one yellow frame around health bar and threat bar
        local ok = pcall(function()
            local o = NamePlateConstants and NamePlateConstants.SELECTED_BORDER_OFFSETS
            hb.selectedBorder:SetPoint("BOTTOMRIGHT", w.plateBg, "BOTTOMRIGHT",
                o and o.bottomRightX or 0, o and o.bottomRightY or 0)
        end)
        if ok then linkedBorder[uf] = true end
    else
        RestoreBorder(uf)
    end

    local overlay = hb.deselectedOverlay
    if overlay and not overlayOwner[overlay] then
        overlayOwner[overlay] = uf
        local function sync(self) MirrorDim(overlayOwner[self]) end
        hooksecurefunc(overlay, "SetShown", sync)
        hooksecurefunc(overlay, "Show", sync)
        hooksecurefunc(overlay, "Hide", sync)
    elseif overlay then
        overlayOwner[overlay] = uf
    end
    MirrorDim(uf)
end

local function RemoveRoom(plate)
    local uf = plate and plate.UnitFrame
    if not uf then return end
    RestoreBorder(uf)
    if rooms[uf] and rooms[uf] ~= 0 then SetRoom(uf, 0) end
end

local function AttachWidget(w, plate)
    local db = ns.db
    local uf = plate.UnitFrame
    local healthBar = GetPlateAnchor(plate)
    HookAnchors(uf, plate)
    if not w.attached then
        w.attached = true
        ns.LayoutWidget(w)
    end

    -- width: a share of the health bar, centered under it
    local inset = 0
    if db.attachWidth < 100 then
        local ok, width = pcall(healthBar.GetWidth, healthBar)
        if ok and type(width) == "number" and not IsSecret(width) then
            inset = width * (100 - db.attachWidth) / 200
        end
    end
    local gap = ns.AttachedGap()
    if w.anchor ~= healthBar or w.anchorMode ~= "attached" or w.anchorY ~= gap or w.anchorX ~= inset then
        w:ClearAllPoints()
        -- same width as the health bar, also for the classic style where the
        -- health bar is inset inside its container
        w:SetPoint("TOPLEFT", healthBar, "BOTTOMLEFT", inset, -gap)
        w:SetPoint("TOPRIGHT", healthBar, "BOTTOMRIGHT", -inset, -gap)
        w.anchor, w.anchorY, w.anchorX, w.anchorMode = healthBar, gap, inset, "attached"
    end
    if not SetRoom(uf, ns.AttachedRoom()) then return false end
    ns.LinkPlate(uf, w)
    return true
end

-- Attached mode when possible, otherwise the floating bar below.
local AnchorFloating
local function AnchorWidget(w, plate, castingOverride)
    local db = ns.db
    if db.attach and db.style ~= "text" and CanAttach(plate) then
        if AttachWidget(w, plate) then return end
    end
    if w.attached then
        w.attached = false
        w.anchor, w.anchorMode = nil, nil
        ns.LayoutWidget(w)
    end
    RemoveRoom(plate)
    AnchorFloating(w, plate, castingOverride)
end

-- Floating bar: under the health bar, or under the cast bar while the
-- enemy is casting. Casting is detected from the unit (events + API)
-- and from the cast bar frame itself, whichever reports it.
AnchorFloating = function(w, plate, castingOverride)
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
        if w and ns.db and w:IsShown() then
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
    RemoveRoom(plate)
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

    local isTanking, status, percent = UnitDetailedThreatSituation("player", unit)

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

    local aggroName
    if ns.db.mode == "tank" and ns.db.tankShowTarget then
        local ok, name = pcall(UnitName, unit .. "target")
        if ok then aggroName = name end
    end

    if ns.RenderWidget(w, percent, isTanking, status, aggroName) then
        -- anchored only while shown, so hidden bars never reserve room
        AnchorWidget(w, plate)
        w:Show()
    else
        HidePlate(plate)
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
        w.anchor, w.anchorY, w.anchorMode = nil, nil, nil
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
        if w and w:IsShown() then
            w.unit = arg1
            local override = CAST_EVENTS[event] or nil   -- true on start, API check otherwise
            local ok, err = pcall(AnchorWidget, w, plate, override)
            if not ok then NoteError("Cast event", err) end
        end
    elseif event == "UNIT_TARGET" then
        -- an enemy switched targets: refresh "who has aggro"
        if IsNameplateToken(arg1) then SafeUpdateUnit(arg1) end
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
events:RegisterEvent("UNIT_TARGET")
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
        print("  Attach to nameplate: " .. tostring(ns.db.attach) .. ", bar height: " .. tostring(ns.AttachedHeight()))
        local okp, tplate = pcall(C_NamePlate.GetNamePlateForUnit, "target")
        if okp and tplate then
            local cb, key = GetCastBar(tplate)
            print("  Target cast bar: " .. tostring(key or "not found")
                .. (cb and (", shown: " .. tostring(cb:IsShown())) or ""))
            print("  Target casting: " .. tostring(IsCasting("target")))
        else
            print("  Target cast bar: no target nameplate")
        end
        local st = ns.attachStats
        print(string.format("  Attach: shifted %d, rebuilt %d, failed %d", st.ok, st.computed, st.failed))
        if okp and tplate then
            local uf = tplate.UnitFrame
            local w = widgets[tplate]
            print("  Target plate: UnitFrame " .. tostring(uf ~= nil)
                .. ", health container " .. tostring(uf and uf.HealthBarsContainer ~= nil)
                .. ", cast container " .. tostring(uf and uf.CastBarsContainer ~= nil)
                .. ", can attach " .. tostring(CanAttach(tplate)))
            print("  Target bar: shown " .. tostring(w and w:IsShown())
                .. ", attached " .. tostring(w and w.attached)
                .. ", room " .. tostring(uf and rooms[uf])
                .. ", failed " .. tostring(uf and attachFailed[uf] or false))
            print("  Other nameplate addon: " .. tostring(uf and uf.IsVisible and not uf:IsVisible()))
        end
        print("  Attach error: " .. tostring(ns.attachError))
        print("  Last error: " .. tostring(ns.lastError))
    elseif msg == "" or msg == "options" or msg == "config" then
        if ns.OpenOptions then ns.OpenOptions() end
    else
        Print("commands: /mthreat (options), /mthreat tank, /mthreat dps, /mthreat debug")
    end
end
