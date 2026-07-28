-- AuraCore Buff Tracker for Vanilla / Turtle WoW 1.12
-- Clickable TellMeWhen-style buff slots, stored per character.

AuraCoreTracker = AuraCoreTracker or {}
local Tracker = AuraCoreTracker

local frame = CreateFrame("Frame", "AuraCoreBuffTracker", UIParent)
frame:SetFrameStrata("HIGH")
frame:SetFrameLevel(20)
frame:SetWidth(224)
frame:SetHeight(54)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
local scanTip = CreateFrame("GameTooltip", "AuraCoreTrackerTooltip", UIParent, "GameTooltipTemplate")
local icons = {}
local elapsed = 0
local testMode = false
local testStarted = 0
local unlocked = false
local editor = nil
local editingIndex = nil
local positioned = false
local TEST_ICON = "Interface\\Icons\\Spell_Nature_EarthBind"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function Settings()
    if not DCP_SavedPerCharacter then return nil end
    local s = DCP_SavedPerCharacter
    s.trackedBuffs = s.trackedBuffs or {}
    if s.trackerEnabled == nil then s.trackerEnabled = false end
    if s.trackerX == nil then s.trackerX = 0 end
    if s.trackerY == nil then s.trackerY = -150 end
    if s.trackerIconSize == nil then s.trackerIconSize = 40 end
    if s.trackerSpacing == nil then s.trackerSpacing = 6 end
    if s.trackerColumns == nil then s.trackerColumns = 6 end
    if s.trackerSlotCount == nil then s.trackerSlotCount = math.max(5, table.getn(s.trackedBuffs)) end
    if s.trackerShowTimer == nil then s.trackerShowTimer = true end
    if s.trackerRedExpiring == nil then s.trackerRedExpiring = true end
    return s
end

local function Normalize(value)
    value = string.lower(value or "")
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    return value
end

local function Trim(value)
    value = value or ""
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    return value
end

local function GetBuffName(buffIndex)
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetPlayerBuff(buffIndex)
    local line = getglobal("AuraCoreTrackerTooltipTextLeft1")
    local name = line and line:GetText() or nil
    scanTip:Hide()
    return name
end

local function ScanPlayerBuffs()
    local found = {}
    if not GetPlayerBuff then return found end
    local slot
    for slot = 0, 31 do
        local buffIndex = GetPlayerBuff(slot, "HELPFUL")
        if buffIndex and buffIndex >= 0 then
            local texture = GetPlayerBuffTexture(buffIndex)
            local name = texture and GetBuffName(buffIndex)
            if name then
                local remaining = GetPlayerBuffTimeLeft and (GetPlayerBuffTimeLeft(buffIndex) or 0) or 0
                found[Normalize(name)] = {name=name, texture=texture, remaining=remaining, buffIndex=buffIndex}
            end
        end
    end
    return found
end

local function FormatTime(seconds)
    if seconds >= 60 then return math.floor(seconds / 60 + 0.5) .. "m" end
    if seconds >= 10 then return tostring(math.floor(seconds + 0.5)) end
    return string.format("%.1f", math.max(0, seconds))
end

local function Position()
    local s = Settings(); if not s then return false end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", s.trackerX or 0, s.trackerY or -150)
    positioned = true
    return true
end

local function SetEditorStatus(entry, active)
    if not editor or not editor:IsShown() then return end
    if not entry or not entry.name or entry.name == "" then
        editor.status:SetText("Enter the exact buff name.")
        editor.status:SetTextColor(0.85, 0.85, 0.85)
    elseif active or entry.texture or entry.recognized then
        editor.status:SetText("Buff recognized")
        editor.status:SetTextColor(0.20, 1.00, 0.20)
    else
        editor.status:SetText("Waiting for detection")
        editor.status:SetTextColor(1.00, 0.82, 0.10)
    end
end

local function EnsureEditor()
    if editor then return editor end
    editor = CreateFrame("Frame", "AuraCoreTrackerSlotEditor", UIParent)
    editor:SetWidth(285); editor:SetHeight(145)
    editor:SetFrameStrata("DIALOG")
    editor:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32, edgeSize=32, insets={left=11,right=12,top=12,bottom=11}})
    editor:Hide()

    local title = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", editor, "TOP", 0, -16)
    title:SetText("Assign Buff Slot")

    local input = CreateFrame("EditBox", "AuraCoreTrackerSlotInput", editor, "InputBoxTemplate")
    input:SetWidth(230); input:SetHeight(24)
    input:SetPoint("TOP", editor, "TOP", 0, -43)
    input:SetAutoFocus(false); input:SetMaxLetters(80)
    editor.input = input

    local status = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOP", input, "BOTTOM", 0, -6)
    status:SetWidth(245); status:SetJustifyH("CENTER")
    editor.status = status

    local save = CreateFrame("Button", "AuraCoreTrackerEditorSave", editor, "UIPanelButtonTemplate")
    save:SetWidth(72); save:SetHeight(22)
    save:SetPoint("BOTTOMLEFT", editor, "BOTTOMLEFT", 20, 18)
    save:SetText("Save")

    local clear = CreateFrame("Button", "AuraCoreTrackerEditorClear", editor, "UIPanelButtonTemplate")
    clear:SetWidth(72); clear:SetHeight(22)
    clear:SetPoint("LEFT", save, "RIGHT", 8, 0)
    clear:SetText("Clear")

    local cancel = CreateFrame("Button", "AuraCoreTrackerEditorCancel", editor, "UIPanelButtonTemplate")
    cancel:SetWidth(72); cancel:SetHeight(22)
    cancel:SetPoint("LEFT", clear, "RIGHT", 8, 0)
    cancel:SetText("Cancel")

    local function SaveSlot()
        local s = Settings(); if not s or not editingIndex then return end
        local name = Trim(input:GetText())
        if name == "" then input:SetFocus(); return end
        local old = s.trackedBuffs[editingIndex]
        if not old or Normalize(old.name) ~= Normalize(name) then
            s.trackedBuffs[editingIndex] = {name=name}
        else
            old.name = name
        end
        editor:Hide(); editingIndex = nil
        Tracker.Refresh()
    end
    save:SetScript("OnClick", SaveSlot)
    input:SetScript("OnEnterPressed", SaveSlot)
    input:SetScript("OnEscapePressed", function() editor:Hide(); editingIndex = nil; this:ClearFocus() end)
    clear:SetScript("OnClick", function()
        local s = Settings()
        if s and editingIndex then s.trackedBuffs[editingIndex] = nil end
        editor:Hide(); editingIndex = nil
        Tracker.Refresh()
    end)
    cancel:SetScript("OnClick", function() editor:Hide(); editingIndex = nil end)
    return editor
end

local function OpenEditor(index, button)
    local s = Settings(); if not s then return end
    local e = EnsureEditor()
    editingIndex = index
    local entry = s.trackedBuffs[index]
    e.input:SetText(entry and entry.name or "")
    e:ClearAllPoints()
    e:SetPoint("TOP", button, "BOTTOM", 0, -8)
    if e:GetBottom() and e:GetBottom() < 10 then
        e:ClearAllPoints(); e:SetPoint("BOTTOM", button, "TOP", 0, 8)
    end
    e:Show()
    e.input:SetFocus(); e.input:HighlightText()
    SetEditorStatus(entry, false)
end

local function EnsureIcon(index)
    if icons[index] then return icons[index] end
    local b = CreateFrame("Button", "AuraCoreTrackerIcon" .. index, UIParent)
    -- Keep configuration slots above the movable tracker background.
    -- Parenting them directly to UIParent avoids the parent frame swallowing clicks
    -- on older Vanilla/Turtle clients. They still follow the tracker via anchors.
    b:SetFrameStrata("DIALOG")
    b:SetFrameLevel(80 + index)
    b:EnableMouse(true)
    if b.RegisterForClicks then
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end
    b.texture = b:CreateTexture(nil, "ARTWORK")
    -- Keep the icon slightly inside the quickslot border. Using SetAllPoints made
    -- bright trinket/proc textures bleed over the border corners at some sizes.
    b.texture:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
    b.texture:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    b.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.cooldown = CreateFrame("Model", "AuraCoreTrackerCooldown" .. index, b, "CooldownFrameTemplate")
    -- Match the cooldown sweep to the inset icon instead of the full button.
    b.cooldown:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
    b.cooldown:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    b.cooldown:Hide()
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    b.border:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.border:SetWidth(64); b.border:SetHeight(64)
    b.plus = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    b.plus:SetPoint("CENTER", b, "CENTER", 0, 1)
    b.plus:SetText("+")
    -- Buff names are intentionally not rendered on the live tracker.
    -- They remain available in the tooltip and slot editor.
    b.nameText = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.nameText:Hide()
    local function HandleSlotMouseUp()
        local mouseButton = arg1
        if mouseButton == "RightButton" then
            local s = Settings(); if s then s.trackedBuffs[this.index] = nil end
            Tracker.Refresh()
        elseif mouseButton == "LeftButton" or not mouseButton then
            OpenEditor(this.index, this)
        end
    end
    -- OnMouseUp is more reliable than OnClick on some 1.12 clients.
    b:SetScript("OnMouseUp", HandleSlotMouseUp)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        if this.buffName and this.buffName ~= "" then
            GameTooltip:SetText(this.buffName)
            if this.recognized then GameTooltip:AddLine("Recognized", 0.2, 1, 0.2)
            else GameTooltip:AddLine("Waiting for detection", 1, 0.82, 0.1) end
            GameTooltip:AddLine("Left-click to edit. Right-click to clear.", 0.75, 0.75, 0.75)
        else
            GameTooltip:SetText("Empty Buff Slot")
            GameTooltip:AddLine("Click to assign a buff.", 0.75, 0.75, 0.75)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.index = index
    icons[index] = b
    return b
end

local function StopCooldown(b)
    if not b or not b.cooldown then return end
    if CooldownFrame_SetTimer then CooldownFrame_SetTimer(b.cooldown, 0, 0, 0) end
    b.cooldown:Hide()
end

local function StartCooldown(b, entry, remaining, now)
    if not b or not b.cooldown or not remaining or remaining <= 0 then
        StopCooldown(b)
        return
    end

    -- Vanilla exposes the remaining buff time but not always the original duration.
    -- Learn the largest observed duration. A freshly gained proc therefore produces
    -- an exact Blizzard spiral, while an already-running proc is still represented.
    local learned = entry and entry.duration or 0
    if remaining > learned then
        learned = remaining
        if entry then entry.duration = learned end
    end
    if learned <= 0 then learned = remaining end

    local startTime = now - math.max(0, learned - remaining)
    if CooldownFrame_SetTimer then
        CooldownFrame_SetTimer(b.cooldown, startTime, learned, 1)
        b.cooldown:Show()
    else
        b.cooldown:Hide()
    end
end

local function LayoutAndUpdate()
    local s = Settings(); if not s then return end
    if not positioned then Position() end

    local enabled = s.trackerEnabled
    local count = math.max(1, math.min(10, s.trackerSlotCount or 5))
    local found = testMode and {} or ScanPlayerBuffs()
    local size = s.trackerIconSize or 40
    local spacing = s.trackerSpacing or 6
    local columns = math.max(1, math.min(count, s.trackerColumns or count))
    local now = GetTime()
    local testRemaining = 8 - math.mod(now - testStarted, 8)
    local visible = 0
    local i

    for i = 1, count do
        local b = EnsureIcon(i)
        local entry = s.trackedBuffs[i]
        local active = entry and found[Normalize(entry.name)] or nil

        if active and active.texture then
            entry.texture = active.texture
            entry.recognized = true
            if active.remaining and active.remaining > (entry.duration or 0) then
                entry.duration = active.remaining
            end
        end

        local recognized = entry and (entry.recognized or entry.texture or active) and true or false
        local isActive = (testMode and entry) or active
        local showConfigSlot = unlocked and true or false
        local shouldShow = false

        -- Live mode is deliberately compact: empty and inactive slots never render.
        -- Unlock mode is the only configuration state that exposes all clickable slots.
        if showConfigSlot then
            shouldShow = true
        elseif testMode then
            shouldShow = entry and true or false
        elseif enabled and active then
            shouldShow = true
        end

        b.index = i
        b.buffName = entry and entry.name or nil
        b.recognized = recognized
        b.plus:SetText((showConfigSlot and not entry) and "+" or "")
        b.nameText:Hide()

        if shouldShow then
            local layoutIndex
            if showConfigSlot then layoutIndex = i - 1 else layoutIndex = visible end
            local col = math.mod(layoutIndex, columns)
            local row = math.floor(layoutIndex / columns)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", frame, "TOPLEFT", col * (size + spacing), -row * (size + spacing))
            b:SetWidth(size); b:SetHeight(size)
            -- UI-Quickslot2 is a 64px border intended for a 40px icon. Scale it
            -- with the configured tracker size so the frame always encloses the icon.
            b.border:SetWidth(size * 1.6)
            b.border:SetHeight(size * 1.6)

            if not entry then
                b.texture:SetTexture(UNKNOWN_ICON)
                b.texture:SetVertexColor(0.25, 0.25, 0.25)
                b:SetAlpha(0.65)
                StopCooldown(b)
            elseif isActive then
                local texture = (active and active.texture) or entry.texture or TEST_ICON
                local remaining = testMode and testRemaining or (active and active.remaining or 0)
                b.texture:SetTexture(texture)
                if s.trackerRedExpiring and remaining > 0 and remaining <= 5 then
                    b.texture:SetVertexColor(1, 0.20, 0.20)
                else
                    b.texture:SetVertexColor(1, 1, 1)
                end
                b:SetAlpha(1)
                if testMode then
                    entry.duration = 8
                end
                StartCooldown(b, entry, remaining, now)
            else
                -- Assigned but currently inactive; shown only while unlocked.
                b.texture:SetTexture(entry.texture or UNKNOWN_ICON)
                b.texture:SetVertexColor(recognized and 0.45 or 0.35, recognized and 0.45 or 0.35, recognized and 0.45 or 0.35)
                b:SetAlpha(0.55)
                StopCooldown(b)
            end

            b:EnableMouse(showConfigSlot and true or false)
            b:Show()
            if not showConfigSlot then visible = visible + 1 end
        else
            StopCooldown(b)
            b:EnableMouse(false)
            b:Hide()
        end
    end

    for i = count + 1, table.getn(icons) do
        StopCooldown(icons[i])
        icons[i]:Hide()
    end

    local renderedCount = unlocked and count or visible
    if renderedCount < 1 then renderedCount = 1 end
    local usedColumns = math.min(columns, renderedCount)
    local rows = math.ceil(renderedCount / columns)
    frame:SetWidth(usedColumns * size + math.max(0, usedColumns - 1) * spacing)
    frame:SetHeight(rows * size + math.max(0, rows - 1) * spacing)

    if unlocked or testMode or (enabled and visible > 0) then frame:Show() else frame:Hide() end
end

frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function() if unlocked then this:StartMoving() end end)
frame:SetScript("OnDragStop", function()
    if not unlocked then return end
    this:StopMovingOrSizing()
    local x, y = this:GetCenter(); local ux, uy = UIParent:GetCenter(); local s = Settings()
    if x and y and ux and uy then s.trackerX = x - ux; s.trackerY = y - uy end
    Position()
end)

-- Dedicated drag handle. The slot buttons cover the whole tracker, so relying on
-- the parent background for dragging makes the bar effectively immovable.
local dragHandle = CreateFrame("Button", "AuraCoreBuffTrackerDragHandle", frame)
dragHandle:SetHeight(16)
dragHandle:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
dragHandle:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 2)
dragHandle:SetFrameStrata("DIALOG")
dragHandle:SetFrameLevel(200)
dragHandle:EnableMouse(true)
dragHandle:RegisterForDrag("LeftButton")
dragHandle:SetBackdrop({bgFile="Interface\\Tooltips\\UI-Tooltip-Background", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=8, insets={left=2,right=2,top=2,bottom=2}})
dragHandle:SetBackdropColor(0, 0.7, 0.2, 0.55)
dragHandle.text = dragHandle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
dragHandle.text:SetPoint("CENTER", dragHandle, "CENTER", 0, 0)
dragHandle.text:SetText("Drag Tracker")
dragHandle:SetScript("OnDragStart", function()
    if unlocked then frame:StartMoving() end
end)
dragHandle:SetScript("OnDragStop", function()
    if not unlocked then return end
    frame:StopMovingOrSizing()
    local x, y = frame:GetCenter(); local ux, uy = UIParent:GetCenter(); local s = Settings()
    if x and y and ux and uy and s then s.trackerX = x - ux; s.trackerY = y - uy end
    Position()
end)
dragHandle:Hide()
-- Keep scanning independently from the visible tracker frame. Hidden frames do
-- not receive OnUpdate in Vanilla, which previously meant the tracker could not
-- discover a newly activated buff until the options window made it visible.
local updateDriver = CreateFrame("Frame", "AuraCoreBuffTrackerUpdateDriver", UIParent)
updateDriver:Show()
updateDriver:SetScript("OnUpdate", function()
    elapsed = elapsed + (arg1 or 0)
    if elapsed >= 0.20 then
        elapsed = 0
        LayoutAndUpdate()
    end
end)

-- Aura events provide an immediate refresh; the lightweight driver remains as a
-- fallback for clients/procs that do not reliably emit every aura event.
updateDriver:RegisterEvent("PLAYER_AURAS_CHANGED")
updateDriver:RegisterEvent("PLAYER_ENTERING_WORLD")
updateDriver:SetScript("OnEvent", function()
    positioned = false
    Position()
    LayoutAndUpdate()
end)

function Tracker.Refresh() LayoutAndUpdate() end
function Tracker.ToggleTest()
    testMode = not testMode; testStarted = GetTime(); LayoutAndUpdate(); return testMode
end
function Tracker.IsTesting() return testMode end
function Tracker.SetUnlocked(value)
    unlocked = value and true or false
    -- Keep the parent mouse-enabled so its child slot buttons remain clickable.
    -- Dragging is still restricted to unlock mode by OnDragStart.
    frame:EnableMouse(true)
    if unlocked then
        frame:SetBackdrop({bgFile="Interface\\Tooltips\\UI-Tooltip-Background", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=12, insets={left=3,right=3,top=3,bottom=3}})
        frame:SetBackdropColor(0, 0.7, 0.2, 0.28)
        dragHandle:Show()
    else
        frame:SetBackdrop(nil)
        dragHandle:Hide()
    end
    LayoutAndUpdate()
end
function Tracker.IsUnlocked() return unlocked end

local function MakeSlider(page, name, label, x, y, width, minVal, maxVal, step, getValue, setValue)
    local slider = CreateFrame("Slider", name, page, "OptionsSliderTemplate")
    slider:SetWidth(width); slider:SetHeight(16)
    slider:SetPoint("TOPLEFT", page, "TOPLEFT", x, y)
    slider:SetMinMaxValues(minVal, maxVal); slider:SetValueStep(step); slider:SetValue(getValue())
    getglobal(name .. "Low"):SetText(tostring(minVal)); getglobal(name .. "High"):SetText(tostring(maxVal))
    getglobal(name .. "Text"):SetText(label .. ": " .. getValue())
    slider:SetScript("OnValueChanged", function()
        local value = math.floor(this:GetValue() + 0.5)
        setValue(value); getglobal(this:GetName() .. "Text"):SetText(label .. ": " .. value); LayoutAndUpdate()
    end)
    return slider
end

function Tracker.BuildOptions(page)
    if not page or page.trackerBuilt then return end
    local s = Settings(); if not s then return end
    page.trackerBuilt = true

    local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", page, "TOPLEFT", 10, -8); title:SetText("Buff Tracker")
    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", page, "TOPLEFT", 10, -28); hint:SetWidth(355); hint:SetJustifyH("LEFT")
    hint:SetText("Enable the tracker to show its slots, then left-click a slot to assign any player buff, talent proc, or trinket proc by its exact aura name.")

    local enable = CreateFrame("CheckButton", "DCPTrackerEnableCheck", page, "UICheckButtonTemplate")
    enable:SetWidth(24); enable:SetHeight(24); enable:SetPoint("TOPLEFT", page, "TOPLEFT", 16, -66)
    enable:SetChecked(s.trackerEnabled and 1 or nil)
    enable:SetScript("OnClick", function()
        local current = Settings(); if not current then return end
        current.trackerEnabled = this:GetChecked() and true or false
        if current.trackerEnabled then
            Position()
            -- Enabling the tracker immediately exposes its assignable slots.
            Tracker.SetUnlocked(true)
            local lockButton = getglobal("DCPTrackerLockButton")
            if lockButton then lockButton:SetText("Lock Tracker") end
        else
            Tracker.SetUnlocked(false)
            local lockButton = getglobal("DCPTrackerLockButton")
            if lockButton then lockButton:SetText("Unlock Tracker") end
        end
        LayoutAndUpdate()
    end)
    local enableText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    enableText:SetPoint("LEFT", enable, "RIGHT", 3, 0); enableText:SetText("Enable Buff Tracker")

    MakeSlider(page, "DCPTrackerSlotsSlider", "Slots", 28, -118, 145, 1, 10, 1,
        function() return s.trackerSlotCount end,
        function(v) s.trackerSlotCount = v; if s.trackerColumns > v then s.trackerColumns = v end end)
    MakeSlider(page, "DCPTrackerSizeSlider", "Icon Size", 215, -118, 145, 24, 72, 1,
        function() return s.trackerIconSize end, function(v) s.trackerIconSize = v end)
    MakeSlider(page, "DCPTrackerSpacingSlider", "Spacing", 28, -184, 145, 0, 20, 1,
        function() return s.trackerSpacing end, function(v) s.trackerSpacing = v end)
    MakeSlider(page, "DCPTrackerColumnsSlider", "Columns", 215, -184, 145, 1, 10, 1,
        function() return s.trackerColumns end, function(v) s.trackerColumns = v end)

    local red = CreateFrame("CheckButton", "DCPTrackerRedCheck", page, "UICheckButtonTemplate")
    red:SetWidth(24); red:SetHeight(24); red:SetPoint("TOPLEFT", page, "TOPLEFT", 16, -238)
    red:SetChecked(s.trackerRedExpiring and 1 or nil)
    red:SetScript("OnClick", function() Settings().trackerRedExpiring = this:GetChecked() and true or false; LayoutAndUpdate() end)
    local redText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    redText:SetPoint("LEFT", red, "RIGHT", 3, 0); redText:SetText("Red during the final 5 seconds")

    local test = CreateFrame("Button", "DCPTrackerTestButton", page, "UIPanelButtonTemplate")
    test:SetWidth(160); test:SetHeight(24); test:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -322)
    test:SetText("Test Buff Tracker")
    test:SetScript("OnClick", function() local active=Tracker.ToggleTest(); this:SetText(active and "Stop Test" or "Test Buff Tracker") end)

    local lock = CreateFrame("Button", "DCPTrackerLockButton", page, "UIPanelButtonTemplate")
    lock:SetWidth(160); lock:SetHeight(24); lock:SetPoint("LEFT", test, "RIGHT", 12, 0)
    lock:SetText("Unlock Tracker")
    lock:SetScript("OnClick", function() Tracker.SetUnlocked(not Tracker.IsUnlocked()); this:SetText(Tracker.IsUnlocked() and "Lock Tracker" or "Unlock Tracker") end)

    local note = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -364); note:SetWidth(350); note:SetJustifyH("LEFT")
    note:SetText("Unlock the tracker to configure its slots. In live mode, only active buffs, talent procs, and trinket proc buffs are shown; inactive and empty slots are always hidden.")
end

local bootstrap = CreateFrame("Frame")
bootstrap:RegisterEvent("PLAYER_ENTERING_WORLD")
bootstrap:RegisterEvent("VARIABLES_LOADED")
bootstrap:SetScript("OnEvent", function()
    positioned = false
    Position()
    LayoutAndUpdate()
end)

Position()
