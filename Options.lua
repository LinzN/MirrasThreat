-- Mirra's Threat - settings panel (Options -> AddOns -> Mirra's Threat)

local addonName, ns = ...

local FLAT        = "Interface\\Buttons\\WHITE8X8"
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local GOLD        = { 1.00, 0.78, 0.18 }

local panel
local controls = {}
local refreshing = false

---------------------------------------------------------------------------
-- Small UI helpers
---------------------------------------------------------------------------

local function AddBorder(frame, r, g, b, a)
    local t = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    t:SetTexture(FLAT)
    t:SetVertexColor(r or 0, g or 0, b or 0, a or 1)
    t:SetAllPoints()
    return t
end

local function AddFill(frame, r, g, b, a)
    local t = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    t:SetTexture(FLAT)
    t:SetVertexColor(r, g, b, a)
    t:SetPoint("TOPLEFT", 1, -1)
    t:SetPoint("BOTTOMRIGHT", -1, 1)
    return t
end

local function Changed()
    if refreshing then return end
    ns.ApplySettings()
end

local function SectionHeader(parent, text, anchor, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fs:SetText(string.upper(text))
    fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y or -18)

    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture(FLAT)
    line:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.25)
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 8, 0)
    line:SetWidth(300 - fs:GetStringWidth() - 8)
    return fs
end

-- Segmented control: a row of toggle buttons bound to one setting.
local function Segmented(parent, key, options, anchor, y)
    local group = { key = key, buttons = {} }
    local prev
    for i, opt in ipairs(options) do
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(opt.width or 96, 24)
        if prev then
            b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y or -8)
        end
        b.border = AddBorder(b, 0, 0, 0, 1)
        b.fill = AddFill(b, 0.12, 0.12, 0.14, 0.95)
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.label:SetPoint("CENTER")
        b.label:SetText(opt.text)
        b.value = opt.value

        b:SetScript("OnEnter", function(self)
            if ns.db[key] ~= self.value then self.fill:SetVertexColor(0.18, 0.18, 0.21, 0.95) end
        end)
        b:SetScript("OnLeave", function(self) group:Refresh() end)
        b:SetScript("OnClick", function(self)
            ns.db[key] = self.value
            group:Refresh()
            if group.onChange then group.onChange() end
            Changed()
        end)

        group.buttons[i] = b
        prev = b
    end

    function group:Refresh()
        for _, b in ipairs(self.buttons) do
            if ns.db[self.key] == b.value then
                b.border:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.9)
                b.fill:SetVertexColor(0.32, 0.24, 0.06, 0.95)
                b.label:SetTextColor(1, 0.92, 0.6)
            else
                b.border:SetVertexColor(0, 0, 0, 1)
                b.fill:SetVertexColor(0.12, 0.12, 0.14, 0.95)
                b.label:SetTextColor(0.8, 0.8, 0.8)
            end
        end
    end

    group.first = group.buttons[1]
    controls[#controls + 1] = group
    return group
end

local function Slider(parent, key, label, minV, maxV, step, fmt, anchor, y)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(300, 34)
    holder:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y or -10)

    local title = holder:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(label)

    local valueText = holder:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    valueText:SetPoint("TOPRIGHT", 0, 0)

    local s = CreateFrame("Slider", nil, holder)
    s:SetOrientation("HORIZONTAL")
    s:SetPoint("TOPLEFT", 0, -16)
    s:SetPoint("TOPRIGHT", 0, -16)
    s:SetHeight(14)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:EnableMouseWheel(true)

    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetTexture(FLAT)
    track:SetVertexColor(0, 0, 0, 0.9)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(6)

    local trackFill = s:CreateTexture(nil, "BORDER")
    trackFill:SetTexture(FLAT)
    trackFill:SetVertexColor(0.16, 0.16, 0.19, 1)
    trackFill:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -1)
    trackFill:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", -1, 1)

    local progress = s:CreateTexture(nil, "ARTWORK")
    progress:SetTexture(FLAT)
    progress:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.55)
    progress:SetPoint("TOPLEFT", trackFill, "TOPLEFT")
    progress:SetPoint("BOTTOMLEFT", trackFill, "BOTTOMLEFT")

    s:SetThumbTexture(FLAT)
    local thumb = s:GetThumbTexture()
    thumb:SetSize(8, 14)
    thumb:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)

    local function UpdateVisual(v)
        valueText:SetText(string.format(fmt, v))
        local width = trackFill:GetWidth()
        if width and width > 0 then
            progress:SetWidth(math.max(1, width * (v - minV) / (maxV - minV)))
        end
    end

    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        UpdateVisual(v)
        if refreshing or ns.db[key] == v then return end
        ns.db[key] = v
        Changed()
    end)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(math.max(minV, math.min(maxV, self:GetValue() + delta * step)))
    end)
    s:SetScript("OnSizeChanged", function(self) UpdateVisual(self:GetValue()) end)

    local ctl = { holder = holder }
    function ctl:Refresh()
        s:SetValue(ns.db[key])
        UpdateVisual(ns.db[key])
    end
    controls[#controls + 1] = ctl
    return holder
end

local function Checkbox(parent, key, label, tooltip, anchor, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -3, y or -6)

    local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    text:SetText(label)
    if cb.Text then cb.Text:SetText("") end
    if cb.text then cb.text:SetText("") end

    cb:SetScript("OnClick", function(self)
        ns.db[key] = self:GetChecked() and true or false
        Changed()
    end)
    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local ctl = {}
    function ctl:Refresh() cb:SetChecked(ns.db[key]) end
    controls[#controls + 1] = ctl

    -- return an anchor aligned with the section's left edge
    local a = CreateFrame("Frame", nil, parent)
    a:SetSize(1, 1)
    a:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 3, 2)
    return a
end

---------------------------------------------------------------------------
-- Preview: three mock enemy nameplates
---------------------------------------------------------------------------

local previews = {}

local function CreateMockPlate(parent, name, x, y)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(120, 50)
    p:SetPoint("TOP", parent, "TOP", x, y)

    p.name = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.name:SetPoint("TOP", 0, 0)
    p.name:SetText(name)

    local hp = CreateFrame("StatusBar", nil, p)
    hp:SetSize(120, 10)
    hp:SetPoint("TOP", p.name, "BOTTOM", 0, -3)
    hp:SetStatusBarTexture(BAR_TEXTURE)
    hp:SetStatusBarColor(0.80, 0.12, 0.10)
    hp:SetMinMaxValues(0, 1)
    hp:SetValue(0.85)
    local hpBorder = hp:CreateTexture(nil, "BACKGROUND")
    hpBorder:SetTexture(FLAT)
    hpBorder:SetVertexColor(0, 0, 0, 1)
    hpBorder:SetPoint("TOPLEFT", -1, 1)
    hpBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    p.hp = hp

    p.caption = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.threat = ns.CreateWidget(p)
    return p
end

function ns.RefreshPreview()
    if not panel or not panel:IsShown() or #previews == 0 then return end
    local db = ns.db
    local warnValue = math.min(99, db.warnAt + math.floor((100 - db.warnAt) / 2))
    local values = { 35, warnValue, 100 }
    for i, p in ipairs(previews) do
        local w = p.threat
        ns.LayoutWidget(w)
        w:ClearAllPoints()
        w:SetPoint("TOP", p.hp, "BOTTOM", 0, -2 + db.offsetY)
        ns.RenderWidget(w, values[i])
        w:Show()
        p.caption:ClearAllPoints()
        p.caption:SetPoint("TOP", w, "BOTTOM", 0, -5)
    end

    if db.mode == "dps" then
        previews[1].caption:SetText("Safe")
        previews[2].caption:SetText("Close to pulling")
        previews[3].caption:SetText("You pulled aggro")
    else
        previews[1].caption:SetText("Lost aggro")
        previews[2].caption:SetText("Losing aggro")
        previews[3].caption:SetText("Holding aggro")
    end
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function RefreshAll()
    refreshing = true
    for _, c in ipairs(controls) do c:Refresh() end
    refreshing = false
    if controls.roleHint then controls.roleHint() end
    ns.RefreshPreview()
end

local function BuildPanel()
    panel = CreateFrame("Frame", "MirraThreatOptionsPanel")
    panel.name = ns.title

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(ns.title)

    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    sub:SetText("Your threat on enemy nameplates, colored for your role.")
    sub:SetTextColor(0.75, 0.75, 0.75)

    -- Left column ---------------------------------------------------------
    local h = SectionHeader(panel, "Role", sub, -20)
    local role = Segmented(panel, "mode", {
        { text = "Tank",         value = "tank", width = 110 },
        { text = "DPS / Healer", value = "dps",  width = 110 },
    }, h, -8)

    local roleHint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    roleHint:SetPoint("TOPLEFT", role.first, "BOTTOMLEFT", 0, -6)
    roleHint:SetWidth(300)
    roleHint:SetJustifyH("LEFT")
    controls.roleHint = function()
        if ns.db.mode == "dps" then
            roleHint:SetText("Green while you are safe, red once you pull aggro.")
        else
            roleHint:SetText("Green while you hold aggro, red once you lose it.")
        end
    end
    role.onChange = controls.roleHint

    h = SectionHeader(panel, "Style", roleHint, -18)
    local style = Segmented(panel, "style", {
        { text = "Bar + Text", value = "bartext", width = 96 },
        { text = "Bar",        value = "bar",     width = 96 },
        { text = "Text",       value = "text",    width = 96 },
    }, h, -8)

    local align = Segmented(panel, "textAlign", {
        { text = "Text left",   value = "LEFT",   width = 96 },
        { text = "Text center", value = "CENTER", width = 96 },
        { text = "Text right",  value = "RIGHT",  width = 96 },
    }, style.first, -6)

    h = SectionHeader(panel, "Size & Position", align.first, -18)
    local a = Slider(panel, "width",    "Width",           40, 160, 2, "%d px", h, -10)
    a = Slider(panel, "height",   "Bar height",       6,  24, 1, "%d px", a, -8)
    a = Slider(panel, "fontSize", "Font size",        7,  20, 1, "%d",    a, -8)
    a = Slider(panel, "offsetY",  "Vertical offset", -30, 30, 1, "%d px", a, -8)

    h = SectionHeader(panel, "Behavior", a, -16)
    a = Slider(panel, "warnAt", "Warning color at", 50, 99, 1, "%d %%", h, -10)
    a = Checkbox(panel, "hideZero", "Hide at 0% threat",
        "Hides the display while you have no threat on that enemy.", a, -6)
    a = Checkbox(panel, "hideSolo", "Only show in a group",
        "Hides threat while you are playing solo.", a, -2)

    -- Right column: preview ---------------------------------------------
    local box = CreateFrame("Frame", nil, panel)
    box:SetPoint("TOPLEFT", panel, "TOPLEFT", 356, -62)
    box:SetSize(250, 330)
    AddBorder(box, 0, 0, 0, 1)
    AddFill(box, 0.05, 0.05, 0.07, 0.9)

    local boxTitle = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    boxTitle:SetPoint("TOPLEFT", 10, -10)
    boxTitle:SetText("PREVIEW")
    boxTitle:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    previews[1] = CreateMockPlate(box, "Kobold Tunneler", 0, -40)
    previews[2] = CreateMockPlate(box, "Defias Bandit",   0, -135)
    previews[3] = CreateMockPlate(box, "Hogger",          0, -230)

    -- Footer ------------------------------------------------------------
    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(140, 22)
    reset:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -10)
    reset:SetText("Reset to defaults")
    reset:SetScript("OnClick", function()
        for k, v in pairs(ns.defaults) do ns.db[k] = v end
        ns.ApplySettings()
        RefreshAll()
    end)

    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -14)
    hint:SetText("Commands: /mt tank, /mt dps, /mt debug")

    panel:SetScript("OnShow", RefreshAll)
end

function ns.BuildOptions()
    if panel then return end
    BuildPanel()

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, ns.title)
        Settings.RegisterAddOnCategory(category)
        ns.category = category
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

function ns.OpenOptions()
    if ns.category and Settings and Settings.OpenToCategory then
        local id = ns.category.GetID and ns.category:GetID() or ns.category.ID
        Settings.OpenToCategory(id)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end
