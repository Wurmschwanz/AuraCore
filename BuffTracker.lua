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
-- Reuse buff scan storage instead of allocating a result table and up to 32
-- entry tables on every tracker tick. This lowers garbage-collector churn in raids.
local scanFound = {}
local scanEntries = {}
local emptyFound = {}
local normalizedNameCache = {}
local elapsed = 0
local testMode = false
local testStarted = 0
local unlocked = false
local editor = nil
local editingIndex = nil
local positioned = false
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Custom clockwise growing shade for live buffs and test mode. It uses four
-- rectangular quadrants and is fully independent from Blizzard CooldownFrame.
local CUSTOM_SHADE_ALPHA = 0.78
local CUSTOM_SHADE_STRIPS = 12
local customShadeDriver = CreateFrame("Frame", "AuraCoreCustomBuffShadeDriver", UIParent)
local customShadeElapsed = 0

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
    value = value or ""
    local cached = normalizedNameCache[value]
    if cached then return cached end
    local normalized = string.lower(value)
    normalized = string.gsub(normalized, "^%s+", "")
    normalized = string.gsub(normalized, "%s+$", "")
    normalizedNameCache[value] = normalized
    return normalized
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

local function GetAuraRemaining(slot, buffIndex)
    -- Use the same Vanilla player-buff timer that drives the default buff bar.
    -- The optional SuperWoW GetPlayerAuraDuration API has different return
    -- layouts between builds; reading it here caused unrelated auras to inherit
    -- the same duration. GetPlayerBuffTimeLeft is authoritative for the visible
    -- player buff and also works for the timed trinket proc tested on this client.
    if GetPlayerBuffTimeLeft then
        return GetPlayerBuffTimeLeft(buffIndex) or 0
    end
    return 0
end
local function ScanPlayerBuffs()
    if AuraCoreAuraCache and AuraCoreAuraCache.Refresh then
        AuraCoreAuraCache.Refresh()
    end
    local key
    for key in pairs(scanFound) do scanFound[key] = nil end
    if not GetPlayerBuff then return scanFound end

    local slot
    for slot = 0, 31 do
        local buffIndex = GetPlayerBuff(slot, "HELPFUL")
        if buffIndex and buffIndex >= 0 then
            local texture = GetPlayerBuffTexture(buffIndex)
            local name = texture and GetBuffName(buffIndex)
            if name then
                local entry = scanEntries[slot]
                if not entry then
                    entry = {}
                    scanEntries[slot] = entry
                end
                entry.name = name
                entry.texture = texture
                entry.remaining = GetAuraRemaining(slot, buffIndex)
                entry.buffIndex = buffIndex
                entry.spellID = AuraCoreAuraCache and AuraCoreAuraCache.GetSpellIDBySlot and AuraCoreAuraCache.GetSpellIDBySlot(slot + 1) or nil
                entry.charges = AuraCoreAuraCache and AuraCoreAuraCache.GetChargesBySlot and AuraCoreAuraCache.GetChargesBySlot(slot + 1, name) or nil
                scanFound[Normalize(name)] = entry
            end
        end
    end
    return scanFound
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
    b.texture = b:CreateTexture(nil, "BACKGROUND")
    -- Keep the icon slightly inside the quickslot border. Using SetAllPoints made
    -- bright trinket/proc textures bleed over the border corners at some sizes.
    b.texture:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
    b.texture:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    b.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
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
    b.durationText = b:CreateFontString(nil, "OVERLAY")
    -- Use one explicit timer style for both test and live buffs. Some UI addons
    -- modify inherited font objects, which could otherwise make the live timer
    -- look slightly different from the test timer.
    local timerFont, timerSize, timerFlags = NumberFontNormal:GetFont()
    -- BuffTracker has its own timer font sizing. Keep it compact so stack
    -- numbers remain readable without changing AuraCore's other timers.
    b.timerFont = timerFont
    b.timerFlags = timerFlags or "OUTLINE"
    b.durationText:SetFont(timerFont, 12, b.timerFlags)
    b.durationText:ClearAllPoints()
    b.durationText:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.durationText:SetJustifyH("CENTER")
    b.durationText:SetJustifyV("MIDDLE")
    b.durationText:SetTextColor(1, 1, 1)
    b.durationText:SetShadowOffset(1, -1)
    b.durationText:SetShadowColor(0, 0, 0, 1)
    b.durationText:Hide()
    b.stackText = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.stackText:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 4)
    b.stackText:SetJustifyH("RIGHT")
    b.stackText:SetTextColor(1, 1, 1)
    b.stackText:Hide()
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
            if this.buffCharges then GameTooltip:AddLine("Charges: " .. tostring(this.buffCharges), 1, 1, 1) end
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

local function EnsureGrowingShade(b)
    if b.growingShade then return end
    b.growingShade = {}
    local i
    -- Eight narrow strips per quarter create a much smoother clockwise wipe
    -- without relying on texture rotation, masks, or reverse cooldown support.
    for i = 1, CUSTOM_SHADE_STRIPS * 4 do
        local t = b:CreateTexture(nil, "ARTWORK")
        t:SetTexture(0, 0, 0)
        t:SetAlpha(CUSTOM_SHADE_ALPHA)
        t:Hide()
        b.growingShade[i] = t
    end
end

local function ResetGrowingShade(b)
    if not b or not b.growingShade then return end
    local i
    for i = 1, table.getn(b.growingShade) do
        local t = b.growingShade[i]
        t:ClearAllPoints()
        t:SetWidth(1)
        t:SetHeight(1)
        t:Hide()
        t.acPoint = nil
        t.acRelativePoint = nil
        t.acX = nil
        t.acY = nil
        t.acWidth = 1
        t.acHeight = 1
        t.acShown = nil
    end
    b.growingShadeEnabled = nil
end

local function SetShadeRect(texture, point, relativePoint, x, y, width, height)
    width = math.max(0.5, width)
    height = math.max(0.5, height)

    -- The swipe runs frequently. Re-anchor only when a strip changes quadrant;
    -- during normal animation usually only its width/height changes.
    if texture.acPoint ~= point or texture.acRelativePoint ~= relativePoint
       or texture.acX ~= x or texture.acY ~= y then
        texture:ClearAllPoints()
        texture:SetPoint(point, texture:GetParent(), relativePoint, x, y)
        texture.acPoint = point
        texture.acRelativePoint = relativePoint
        texture.acX = x
        texture.acY = y
    end
    if not texture.acWidth or math.abs(texture.acWidth - width) > 0.02 then
        texture:SetWidth(width)
        texture.acWidth = width
    end
    if not texture.acHeight or math.abs(texture.acHeight - height) > 0.02 then
        texture:SetHeight(height)
        texture.acHeight = height
    end
    if not texture.acShown then
        texture:Show()
        texture.acShown = true
    end
end

local function HideShade(texture)
    if texture and texture.acShown then
        texture:Hide()
        texture.acShown = nil
    end
end

local function Clamp01(value)
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

local function UpdateGrowingShade(b, progress)
    if not b or not b.growingShadeEnabled then return end
    EnsureGrowingShade(b)
    progress = Clamp01(progress or 0)

    local usable = math.max(2, (b:GetWidth() or 40) - 4)
    local radius = usable / 2
    local strips = CUSTOM_SHADE_STRIPS
    local stripSize = radius / strips
    local phase = progress * 4
    local shades = b.growingShade
    local quarter, i, localProgress, angle, tangent, distance, threshold, amount

    for quarter = 1, 4 do
        localProgress = Clamp01(phase - (quarter - 1))
        angle = localProgress * (math.pi / 2)
        tangent = math.tan(angle)

        for i = 1, strips do
            local index = ((quarter - 1) * strips) + i
            local texture = shades[index]
            distance = (i - 0.5) * stripSize

            if localProgress <= 0 then
                HideShade(texture)
            elseif localProgress >= 0.9999 then
                if quarter == 1 then
                    -- top-right quarter
                    SetShadeRect(texture, "TOPLEFT", "CENTER", (i - 1) * stripSize, radius, stripSize + 0.4, radius)
                elseif quarter == 2 then
                    -- bottom-right quarter
                    SetShadeRect(texture, "TOPRIGHT", "CENTER", radius, -(i - 1) * stripSize, radius, stripSize + 0.4)
                elseif quarter == 3 then
                    -- bottom-left quarter
                    SetShadeRect(texture, "BOTTOMRIGHT", "CENTER", -(i - 1) * stripSize, -radius, stripSize + 0.4, radius)
                else
                    -- top-left quarter
                    SetShadeRect(texture, "BOTTOMLEFT", "CENTER", -radius, (i - 1) * stripSize, radius, stripSize + 0.4)
                end
            else
                -- Each quarter is approximated by narrow strips whose visible
                -- length follows the radial boundary. This begins exactly at
                -- 12 o'clock and proceeds clockwise.
                if tangent <= 0.0001 then
                    amount = 0
                else
                    threshold = distance / tangent
                    amount = radius - threshold
                    if amount < 0 then amount = 0 elseif amount > radius then amount = radius end
                end

                if amount <= 0 then
                    HideShade(texture)
                elseif quarter == 1 then
                    SetShadeRect(texture, "TOPLEFT", "CENTER", (i - 1) * stripSize, radius, stripSize + 0.4, amount)
                elseif quarter == 2 then
                    SetShadeRect(texture, "TOPRIGHT", "CENTER", radius, -(i - 1) * stripSize, amount, stripSize + 0.4)
                elseif quarter == 3 then
                    SetShadeRect(texture, "BOTTOMRIGHT", "CENTER", -(i - 1) * stripSize, -radius, stripSize + 0.4, amount)
                else
                    SetShadeRect(texture, "BOTTOMLEFT", "CENTER", -radius, (i - 1) * stripSize, amount, stripSize + 0.4)
                end
            end
        end
    end
end

local function FormatTrackerTime(seconds)
    if not seconds or seconds <= 0 then return "" end
    seconds = math.ceil(seconds)

    if seconds >= 3600 then
        return math.floor(seconds / 3600) .. "h"
    elseif seconds > 300 then
        -- Long buffs: compact minute display, e.g. 9m.
        return math.floor(seconds / 60) .. "m"
    elseif seconds >= 60 then
        -- Medium-length buffs keep useful precision without filling the icon,
        -- e.g. 2:48 instead of 2m.
        local minutes = math.floor(seconds / 60)
        local secs = math.mod(seconds, 60)
        if secs < 10 then
            return minutes .. ":0" .. secs
        end
        return minutes .. ":" .. secs
    end

    return tostring(seconds)
end

local function UpdateTrackerTimerFont(b, remaining)
    if not b or not b.durationText or not b.timerFont then return end
    local iconSize = b.acLayoutSize or 40
    local baseSize

    -- BuffTracker-only readability tiers:
    --   > 5m    : compact Xm
    --   1m-5m   : M:SS with a smaller font
    --   10-59s  : normal font
    --   0-9s    : larger for the important final seconds
    if remaining and remaining > 300 then
        baseSize = 10
    elseif remaining and remaining >= 60 then
        baseSize = 11
    elseif remaining and remaining > 0 and remaining < 10 then
        baseSize = 15
    else
        baseSize = 13
    end

    -- Keep the same proportions when users change the BuffTracker icon size.
    local fontSize = math.floor(baseSize * (iconSize / 40) + 0.5)
    if fontSize < 8 then fontSize = 8 end
    if fontSize > 22 then fontSize = 22 end

    if b.acTimerFontSize ~= fontSize then
        b.durationText:SetFont(b.timerFont, fontSize, b.timerFlags)
        b.acTimerFontSize = fontSize
    end
end

local customShadeDriverRunning = false

local function HasActiveCustomShade()
    if testMode then return true end
    local i
    for i = 1, table.getn(icons) do
        local b = icons[i]
        if b and b.growingShadeEnabled and b.acSwipeExpiresAt then return true end
    end
    return false
end

local function CustomShadeTick()
    customShadeElapsed = customShadeElapsed + (arg1 or 0)
    -- 30 updates per second are visually smooth for a 48-strip swipe and halve
    -- the geometry work compared with the previous ~60 Hz loop.
    if customShadeElapsed < 0.033 then return end
    customShadeElapsed = 0

    local now = GetTime()
    local elapsedTest = testMode and math.mod(now - testStarted, 8) or 0
    local testRemaining = testMode and (8 - elapsedTest) or 0
    local anyActive = false
    local i
    for i = 1, table.getn(icons) do
        local b = icons[i]
        if b and b.growingShadeEnabled then
            local remaining
            local progress

            if testMode and b.testEntry then
                anyActive = true
                remaining = testRemaining
                progress = elapsedTest / 8
            elseif b.acSwipeExpiresAt and b.acSwipeDuration and b.acSwipeDuration > 0 then
                remaining = b.acSwipeExpiresAt - now
                if remaining < 0 then remaining = 0 end
                if remaining > 0 then anyActive = true end
                if b.acSwipeStartedAt then
                    progress = (now - b.acSwipeStartedAt) / b.acSwipeDuration
                else
                    progress = 1 - (remaining / b.acSwipeDuration)
                end
            else
                remaining = 0
                progress = 1
            end

            UpdateGrowingShade(b, progress)
            UpdateTrackerTimerFont(b, remaining)

            local displayTime = FormatTrackerTime(remaining)
            if b.acDisplayedTime ~= displayTime then
                b.acDisplayedTime = displayTime
                if displayTime ~= "" then
                    b.durationText:SetText(displayTime)
                    b.durationText:Show()
                else
                    b.durationText:SetText("")
                    b.durationText:Hide()
                end
            end

            if testMode and b.testEntry then
                local entry = b.testEntry
                local charges
                if entry and entry.charges then
                    if remaining > 6 then charges = 3
                    elseif remaining > 4 then charges = 2
                    elseif remaining > 2 then charges = 1 end
                elseif entry and entry.stacks then
                    if remaining > 6 then charges = 5
                    elseif remaining > 4 then charges = 3
                    elseif remaining > 2 then charges = 1 end
                end

                if b.acDisplayedCharges ~= charges then
                    b.acDisplayedCharges = charges
                    if charges and charges > 0 then
                        b.stackText:SetText(tostring(charges))
                        b.stackText:Show()
                    else
                        b.stackText:SetText("")
                        b.stackText:Hide()
                    end
                end
            end
        end
    end

    -- No active aura and no test preview: remove the OnUpdate entirely. Aura
    -- scans wake it again when a tracked buff starts.
    if not anyActive and not testMode then
        customShadeDriverRunning = false
        customShadeDriver:SetScript("OnUpdate", nil)
    end
end

local function UpdateCustomShadeDriverState()
    local shouldRun = HasActiveCustomShade()
    if shouldRun and not customShadeDriverRunning then
        customShadeElapsed = 0
        customShadeDriverRunning = true
        customShadeDriver:SetScript("OnUpdate", CustomShadeTick)
    elseif not shouldRun and customShadeDriverRunning then
        customShadeElapsed = 0
        customShadeDriverRunning = false
        customShadeDriver:SetScript("OnUpdate", nil)
    end
end

customShadeDriver:Show()

local function StopCooldown(b)
    if not b then return end
    ResetGrowingShade(b)
    b.acSwipeDuration = nil
    b.acSwipeExpiresAt = nil
    b.acSwipeStartedAt = nil
    b.acSwipeKey = nil
    b.acLastSourceRemaining = nil
    b.acDisplayedTime = nil
    if b.durationText then
        b.durationText:SetText("")
        b.durationText:Hide()
    end
    UpdateCustomShadeDriverState()
end

-- One timing path for every tracked player aura, including trinket procs.
-- The number is always based on the current GetPlayerBuffTimeLeft sample.
-- Duration is runtime-only and relearned whenever remaining time jumps upward,
-- which marks a new proc/refresh. Nothing is stored in SavedVariables.
local function StartCooldown(b, entry, remaining, now)
    if not b or not remaining or remaining <= 0 then
        StopCooldown(b)
        return
    end

    EnsureGrowingShade(b)

    if testMode and b.testEntry then
        b.growingShadeEnabled = true
        b.acSwipeDuration = 8
        b.acSwipeExpiresAt = now + remaining
        b.acSwipeStartedAt = now - (8 - remaining)
        b.acLastSourceRemaining = remaining
        UpdateGrowingShade(b, math.mod(now - testStarted, 8) / 8)
        UpdateCustomShadeDriverState()
        return
    end

    b.growingShadeEnabled = true

    local swipeKey = (entry and entry.name or "") .. "|" .. (entry and entry.texture or "")
    local previousRemaining = b.acLastSourceRemaining
    local newActivation = b.acSwipeKey ~= swipeKey
        or not b.acSwipeDuration
        or not previousRemaining
        or remaining > previousRemaining + 0.75

    if newActivation then
        -- Buff APIs are sampled a fraction after application. Round a fresh
        -- sample to the nearest whole second so a 24s/6s aura starts at its
        -- real full duration while the live remaining value stays untouched.
        local learnedDuration = math.floor(remaining + 0.5)
        if learnedDuration < remaining then learnedDuration = remaining end
        if learnedDuration <= 0 then learnedDuration = remaining end
        b.acSwipeKey = swipeKey
        b.acSwipeDuration = learnedDuration
        -- Keep the visual swipe on its own clock. Short trinket procs can report
        -- their remaining time in coarse steps; deriving every frame from that
        -- sample can leave the custom shade apparently stationary or absent.
        b.acSwipeStartedAt = now - math.max(0, learnedDuration - remaining)
    elseif remaining > (b.acSwipeDuration or 0) then
        b.acSwipeDuration = remaining
    end

    -- Re-anchor every scan to the actual aura value. The fast visual driver
    -- interpolates only between scans, preventing a permanent one-second drift.
    b.acSwipeExpiresAt = now + remaining
    b.acLastSourceRemaining = remaining

    local progress
    if b.acSwipeStartedAt and b.acSwipeDuration and b.acSwipeDuration > 0 then
        progress = (now - b.acSwipeStartedAt) / b.acSwipeDuration
    else
        progress = 1 - (remaining / math.max(0.001, b.acSwipeDuration or remaining))
    end
    UpdateGrowingShade(b, progress)

    UpdateTrackerTimerFont(b, remaining)
    local displayTime = FormatTrackerTime(remaining)
    if b.acDisplayedTime ~= displayTime then
        b.acDisplayedTime = displayTime
        if displayTime ~= "" then
            b.durationText:SetText(displayTime)
            b.durationText:Show()
        else
            b.durationText:SetText("")
            b.durationText:Hide()
        end
    end
    UpdateCustomShadeDriverState()
end

local function LayoutAndUpdate()
    local s = Settings(); if not s then return end
    if not positioned then Position() end

    local enabled = s.trackerEnabled
    local count = math.max(1, math.min(10, s.trackerSlotCount or 5))
    local found = testMode and emptyFound or ScanPlayerBuffs()
    local size = s.trackerIconSize or 40
    local spacing = s.trackerSpacing or 6
    local columns = math.max(1, math.min(count, s.trackerColumns or count))
    local now = GetTime()
    local testRemaining = 8 - math.mod(now - testStarted, 8)
    local visible = 0
    local i

    for i = 1, count do
        local b = EnsureIcon(i)
        -- Test exactly the player-configured tracker slots. Never inject
        -- class-foreign example buffs into the visual test.
        local entry = s.trackedBuffs[i]
        local active = (not testMode and entry) and found[Normalize(entry.name)] or nil

        if active and active.texture then
            entry.texture = active.texture
            entry.recognized = true
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
        b.buffCharges = active and active.charges or nil
        b.testEntry = testMode and entry or nil
        b.plus:SetText((showConfigSlot and not entry) and "+" or "")
        b.nameText:Hide()
        if not testMode then
            b.acDisplayedCharges = nil
            b.stackText:Hide()
        end

        if shouldShow then
            local layoutIndex
            if showConfigSlot then layoutIndex = i - 1 else layoutIndex = visible end
            local col = math.mod(layoutIndex, columns)
            local row = math.floor(layoutIndex / columns)
            -- Layout cache: positioning and sizing only need to be applied when the
            -- rendered slot, icon size, or spacing actually changes. In live combat
            -- this avoids repeating the same anchor/size work five times per second.
            local x = col * (size + spacing)
            local y = -row * (size + spacing)
            if b.acLayoutX ~= x or b.acLayoutY ~= y or b.acLayoutSize ~= size then
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
                b:SetWidth(size); b:SetHeight(size)
                -- UI-Quickslot2 is a 64px border intended for a 40px icon. Scale it
                -- with the configured tracker size so the frame always encloses the icon.
                b.border:SetWidth(size * 1.6)
                b.border:SetHeight(size * 1.6)
                -- Timer size is selected dynamically from the remaining time.
                -- This affects only BuffTracker; other AuraCore timers are untouched.
                b.acTimerFontSize = nil
                -- Stack count stays separate in the bottom-right corner.
                b.stackText:ClearAllPoints()
                b.stackText:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 4)
                b.acLayoutX = x
                b.acLayoutY = y
                b.acLayoutSize = size
            end

            if not entry then
                b.texture:SetTexture(UNKNOWN_ICON)
                b.texture:SetVertexColor(0.25, 0.25, 0.25)
                b:SetAlpha(0.65)
                StopCooldown(b)
            elseif isActive then
                local texture = (active and active.texture) or entry.texture or UNKNOWN_ICON
                local remaining = testMode and testRemaining or (active and active.remaining or 0)
                local charges = active and active.charges or nil
                b.texture:SetTexture(texture)
                if s.trackerRedExpiring and remaining > 0 and remaining <= 5 then
                    b.texture:SetVertexColor(1, 0.20, 0.20)
                else
                    b.texture:SetVertexColor(1, 1, 1)
                end
                b:SetAlpha(1)
                if not testMode then
                    if charges and charges > 0 then
                        if b.acDisplayedCharges ~= charges then
                            b.acDisplayedCharges = charges
                            b.stackText:SetText(tostring(charges))
                        end
                        b.stackText:Show()
                    else
                        b.acDisplayedCharges = nil
                        b.stackText:Hide()
                    end
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
    local frameWidth = usedColumns * size + math.max(0, usedColumns - 1) * spacing
    local frameHeight = rows * size + math.max(0, rows - 1) * spacing
    if frame.acLayoutWidth ~= frameWidth then
        frame:SetWidth(frameWidth)
        frame.acLayoutWidth = frameWidth
    end
    if frame.acLayoutHeight ~= frameHeight then
        frame:SetHeight(frameHeight)
        frame.acLayoutHeight = frameHeight
    end

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
-- not receive OnUpdate in Vanilla, so the driver remains separate from the
-- visual tracker. Test10 lets this driver sleep entirely when there is nothing
-- useful to track and uses a slower interval outside combat.
local updateDriver = CreateFrame("Frame", "AuraCoreBuffTrackerUpdateDriver", UIParent)
local driverRunning = false

local function HasAssignedSlots(s)
    if not s or not s.trackedBuffs then return false end
    local count = s.trackerSlotCount or table.getn(s.trackedBuffs)
    local i
    for i = 1, count do
        local entry = s.trackedBuffs[i]
        if entry and entry.name and Trim(entry.name) ~= "" then return true end
    end
    return false
end

local function ShouldDriverRun()
    local s = Settings()
    if not s then return false end
    -- Configuration and test mode need live updates even when the normal tracker
    -- is disabled. In normal play, an enabled tracker without assigned slots has
    -- no work to perform and can sleep completely.
    if unlocked or testMode then return true end
    return s.trackerEnabled and HasAssignedSlots(s)
end

local function DriverTick()
    elapsed = elapsed + (arg1 or 0)
    local interval = 0.50
    if UnitAffectingCombat and UnitAffectingCombat("player") then interval = 0.20 end
    if elapsed < interval then return end
    elapsed = 0

    if not ShouldDriverRun() then
        driverRunning = false
        updateDriver:SetScript("OnUpdate", nil)
        if AuraCoreProfilerRecord then AuraCoreProfilerRecord("TrackerDriver.Sleep", 0) end
        return
    end

    if AuraCoreProfilerRecord then
        local tickStarted = GetTime()
        local layoutStarted = GetTime()
        LayoutAndUpdate()
        AuraCoreProfilerRecord("Tracker.LayoutAndUpdate", GetTime() - layoutStarted)
        AuraCoreProfilerRecord("TrackerDriver.Tick", GetTime() - tickStarted)
    else
        LayoutAndUpdate()
    end
end

local function UpdateDriverState()
    local shouldRun = ShouldDriverRun()
    if shouldRun and not driverRunning then
        elapsed = 0
        driverRunning = true
        updateDriver:SetScript("OnUpdate", DriverTick)
        if AuraCoreProfilerRecord then AuraCoreProfilerRecord("TrackerDriver.Wake", 0) end
    elseif not shouldRun and driverRunning then
        elapsed = 0
        driverRunning = false
        updateDriver:SetScript("OnUpdate", nil)
        if AuraCoreProfilerRecord then AuraCoreProfilerRecord("TrackerDriver.Sleep", 0) end
    end
end

updateDriver:Show()
updateDriver:RegisterEvent("PLAYER_AURAS_CHANGED")
updateDriver:RegisterEvent("PLAYER_ENTERING_WORLD")
updateDriver:RegisterEvent("PLAYER_REGEN_DISABLED")
updateDriver:RegisterEvent("PLAYER_REGEN_ENABLED")
updateDriver:SetScript("OnEvent", function()
    positioned = false
    Position()
    UpdateDriverState()
    if ShouldDriverRun() then
        if AuraCoreProfilerRecord then
            local started = GetTime()
            LayoutAndUpdate()
            AuraCoreProfilerRecord("Tracker.EventRefresh", GetTime() - started)
        else
            LayoutAndUpdate()
        end
    end
end)

function Tracker.Refresh() LayoutAndUpdate(); UpdateDriverState(); UpdateCustomShadeDriverState() end
function Tracker.ToggleTest()
    testMode = not testMode
    testStarted = GetTime()
    LayoutAndUpdate()
    UpdateDriverState()
    UpdateCustomShadeDriverState()
    return testMode
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
    UpdateDriverState()
    UpdateCustomShadeDriverState()
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
    lock:SetScript("OnClick", function()
        local current = Settings()
        if current and not current.trackerEnabled then
            -- Unlock/Lock is a positioning control, not a visibility toggle.
            -- If the user interacts with it, keep the tracker enabled so locking
            -- cannot make active tracked buffs disappear merely because the
            -- enable checkbox was previously off.
            current.trackerEnabled = true
            local enableCheck = getglobal("DCPTrackerEnableCheck")
            if enableCheck then enableCheck:SetChecked(1) end
        end
        Tracker.SetUnlocked(not Tracker.IsUnlocked())
        this:SetText(Tracker.IsUnlocked() and "Lock Tracker" or "Unlock Tracker")
    end)

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
    UpdateDriverState()
end)

Position()
UpdateDriverState()
