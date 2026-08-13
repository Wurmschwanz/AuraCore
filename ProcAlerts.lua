-- AuraCore Proc Alerts for Vanilla / Turtle WoW 1.12
-- Lightweight, event-driven player proc overlay module.
-- ProcDoc visual definitions and exact artwork geometry ported for Turtle WoW.

AuraCoreProc = AuraCoreProc or {}
local PCProc = AuraCoreProc

local frame = CreateFrame("Frame", "AuraCoreProcFrame", UIParent)
frame:SetAllPoints(UIParent)
frame:SetFrameStrata("HIGH")
frame:EnableMouse(false)

local activeVisuals = {}
local visualPool = {}
-- Scratch list reused by the animation driver to avoid a new table every frame.
local releaseQueue = {}

local seenProcs = {}
local seenProcTiming = {}
local consumedProcs = {}
-- Prevent a proc overlay from being recreated for a stale final aura scan after
-- its visual expiry timer has already reached zero. The block is cleared as
-- soon as the aura truly disappears or a fresh duration is observed.
local expirySuppressed = {}
local slotByProc = {} -- compatibility name: maps proc keys to independent visual objects
local assignedProcs = {} -- scan-local ownership map; must always be a table
-- Shadow Trance can remain visible briefly after it has been consumed on some
-- Turtle WoW clients. Remember the aura duration at consumption time so a
-- later duration refresh is recognised as a genuinely new proc.
local shadowTranceTimeLeft = 0
local shadowTranceConsumedTimeLeft = 0
local shadowTranceConsumedAt = 0
local pendingShadowTranceCast = false
local pendingShadowTranceCastAt = 0
local testModeActive = false
local selectedTestDefinition = nil
local ShowTestAlerts -- forward declaration for Vanilla Lua lexical scope

local TEXTURE_PATH = "Interface\\AddOns\\AuraCore\\Textures\\"
local PROCDOC_TEXTURE_PATH = TEXTURE_PATH .. "ProcDoc\\"
-- Names are intentionally used instead of spell IDs because Turtle WoW procs
-- may use custom IDs. Tooltip names remain reliable across Vanilla clients.
local procDefinitions = AuraCoreProcDocData and AuraCoreProcDocData.buffs or {}

local function GetProcSettings()
    if AuraCore_GetProcSettings then return AuraCore_GetProcSettings() end
    return DCP_SavedPerCharacter or DCP_Saved
end

local function GetAlertSettingKey(definition)
    if not definition then return nil end
    return definition.id or definition.name or definition.spellName
end

local function GetProcOverride(definition)
    local key = GetAlertSettingKey(definition)
    local settings = GetProcSettings()
    if not key or not settings or not settings.procOverrides then return nil end
    return settings.procOverrides[key]
end

local function GetOverrideValue(definition, field, fallback)
    local override = GetProcOverride(definition)
    if override and override[field] ~= nil then return override[field] end
    return fallback
end

local function IsAlertEnabled(definition)
    local key = GetAlertSettingKey(definition)
    if not key then return true end
    local settings = GetProcSettings()
    if not settings or not settings.procAlertEnabled then return true end
    return settings.procAlertEnabled[key] ~= false
end

local actionProcDefinitions = AuraCoreProcDocData and AuraCoreProcDocData.actions or {}

local ACTION_PROC_DURATIONS = AuraCoreProcDocData and AuraCoreProcDocData.durations or {}

local actionSlotCache = {}
local actionCacheDirty = true
local actionActiveSince = {}
local actionWasUsable = {}
local inCombatFlag = false
local SetSeenTiming -- forward declaration for action proc scan

local function GetClassActionDefinitions()
    local _, class = UnitClass("player")
    return class and actionProcDefinitions[class]
end

local function RebuildActionSlotCache()
    for key in pairs(actionSlotCache) do actionSlotCache[key] = nil end
    local definitions = GetClassActionDefinitions()
    if not definitions or not GetActionTexture then actionCacheDirty = false; return end

    local slot
    for slot = 1, 120 do
        local actionTexture = GetActionTexture(slot)
        if actionTexture then
            local lowerTexture = string.lower(actionTexture)
            local _, definition
            for _, definition in ipairs(definitions) do
                if definition.actionTexture and lowerTexture == string.lower(definition.actionTexture) then
                    actionSlotCache[definition.id] = slot
                end
            end
        end
    end
    actionCacheDirty = false
end

local function IsActionProcUsable(definition, slot)
    if not definition or not slot or not IsUsableAction then return false end
    local usable = IsUsableAction(slot)
    if not usable then return false end

    -- Turtle WoW's Kill Command can remain reported as usable while it is on
    -- cooldown. ProcDoc works around that server behaviour through the spellbook.
    if definition.checkSpellbookCooldown and GetSpellName and GetSpellCooldown then
        local spellIndex = 1
        while true do
            local spellName = GetSpellName(spellIndex, BOOKTYPE_SPELL or "spell")
            if not spellName then break end
            if string.lower(spellName) == string.lower(definition.spellName) then
                local _, duration = GetSpellCooldown(spellIndex, BOOKTYPE_SPELL or "spell")
                if duration and duration > 1.5 then return false end
                break
            end
            spellIndex = spellIndex + 1
        end
    end
    return true
end

local function FindSpellBookIndexByName(spellName)
    if not spellName or not GetNumSpellTabs then return nil end
    local tab
    for tab = 1, GetNumSpellTabs() do
        local _, _, offset, count = GetSpellTabInfo(tab)
        if offset and count then
            local i
            for i = offset + 1, offset + count do
                local name = GetSpellName(i, BOOKTYPE_SPELL or "spell")
                if name == spellName then return i end
            end
        end
    end
    return nil
end

local function IsSpellbookProcReady(definition)
    if not definition or not definition.useSpellbook then return false end
    local inCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) or inCombatFlag
    if not inCombat then return false end
    local index = FindSpellBookIndexByName(definition.spellName)
    if not index then return false end
    local _, duration = GetSpellCooldown(index, BOOKTYPE_SPELL or "spell")
    return duration == 0
end

local function AddActionProcsToSeen()
    local definitions = GetClassActionDefinitions()
    if not definitions then return end
    if actionCacheDirty then RebuildActionSlotCache() end

    local _, definition
    for _, definition in ipairs(definitions) do
        local usable = false
        if not IsAlertEnabled(definition) then
            actionWasUsable[definition.id] = nil
            actionActiveSince[definition.id] = nil
        else
        if definition.useSpellbook then
            usable = IsSpellbookProcReady(definition)
        else
            local slot = actionSlotCache[definition.id]
            usable = slot and IsActionProcUsable(definition, slot)
        end

        if usable then
            if not actionWasUsable[definition.id] then
                actionActiveSince[definition.id] = GetTime()
            end
            actionWasUsable[definition.id] = true

            local duration = ACTION_PROC_DURATIONS[definition.id]
            local expired = duration and actionActiveSince[definition.id]
                and (GetTime() - actionActiveSince[definition.id]) >= duration
            if not expired then
                local remaining = duration and actionActiveSince[definition.id]
                    and math.max(0, duration - (GetTime() - actionActiveSince[definition.id])) or nil
                if definition.dual then
                    local leftKey = definition._acLeftKey
                    local rightKey = definition._acRightKey
                    if not leftKey then
                        leftKey = definition.id .. "_left"
                        rightKey = definition.id .. "_right"
                        definition._acLeftKey = leftKey
                        definition._acRightKey = rightKey
                    end
                    seenProcs[leftKey] = definition
                    seenProcs[rightKey] = definition
                    if remaining then
                        SetSeenTiming(leftKey, remaining, duration, false)
                        SetSeenTiming(rightKey, remaining, duration, false)
                    end
                else
                    seenProcs[definition.id] = definition
                    if remaining then
                        SetSeenTiming(definition.id, remaining, duration, false)
                    end
                end
            end
        else
            actionWasUsable[definition.id] = nil
            actionActiveSince[definition.id] = nil
        end
        end
    end
end

local function AcquireVisual()
    local visual = table.remove(visualPool)
    if not visual then
        visual = { texture = frame:CreateTexture(nil, "OVERLAY") }
        visual.texture:SetBlendMode("BLEND")
    end
    return visual
end

SetSeenTiming = function(procKey, timeLeft, duration, isBuff)
    if not procKey or not timeLeft or timeLeft <= 0 then return end
    local timing = seenProcTiming[procKey]
    if not timing then
        timing = {}
        seenProcTiming[procKey] = timing
    end
    timing.timeLeft = timeLeft
    timing.isBuff = isBuff and true or false
    if duration and duration > 0 then
        timing.duration = duration
    elseif not timing.duration or timeLeft > timing.duration then
        timing.duration = timeLeft
    end
end

local function ApplyExpiryTransform(visual, definition, procKey, ratio)
    if not ratio or ratio >= 0.999 then return 1 end

    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end

    -- Keep the artwork completely unchanged and only fade its opacity.
    -- Smoothstep makes the fade subtle at first and stronger near expiry.
    return ratio * ratio * (3 - (2 * ratio))
end

local function ApplyLayout(visual, definition, procKey, pulseScale)
    if not visual or not definition then return end
    local globalScale = (GetProcSettings() and GetProcSettings().procOverlayScale) or 1.0
    local procScale = GetOverrideValue(definition, "scale", 1.0)
    local scale = globalScale * procScale * (pulseScale or 1.0)
    local procYOffset = GetOverrideValue(definition, "yOffset", 0)
    local procXOffset = GetOverrideValue(definition, "xOffset", 0)
    local topOffset = 70 + ((GetProcSettings() and GetProcSettings().procOverlayYOffset) or 0) + procYOffset
    local sideOffset = 60 + ((GetProcSettings() and GetProcSettings().procOverlayXOffset) or 0) + procXOffset
    local style = definition.style or "SIDES"
    local texture = visual.texture
    local x, y = 0, topOffset
    local side = string.find(procKey or "", "_right", 1, true) and "right" or "left"

    texture:ClearAllPoints()
    texture:SetTexCoord(0, 1, 0, 1)
    if style == "TOP" or style == "TOP2" or style == "TOP_ROTATED" then
        texture:SetWidth(256 * scale); texture:SetHeight(128 * scale)
        y = topOffset + ((style == "TOP2") and 50 or 0)
        if style == "TOP_ROTATED" then texture:SetTexCoord(0, 1, 1, 1, 0, 0, 1, 0) end
    elseif style == "SIDES" or style == "SIDES2" then
        texture:SetWidth(128 * scale); texture:SetHeight(256 * scale)
        local sideX = sideOffset + ((style == "SIDES2") and 50 or 0)
        x = (side == "right") and sideX or -sideX
        y = topOffset - 150
        if side == "right" then texture:SetTexCoord(1, 0, 0, 1) end
    elseif style == "LEFT" then
        texture:SetWidth(128 * scale); texture:SetHeight(256 * scale)
        x = -(sideOffset + 50); y = topOffset - 150
    elseif style == "RIGHT" then
        texture:SetWidth(128 * scale); texture:SetHeight(256 * scale)
        x = sideOffset + 50; y = topOffset - 150
        texture:SetTexCoord(1, 0, 0, 1)
    end
    texture:SetPoint("CENTER", UIParent, "CENTER", x, y)
    visual.layoutWidth = texture:GetWidth()
    visual.layoutHeight = texture:GetHeight()
    visual.layoutX = x
    visual.layoutY = y
end

local function ReleaseVisual(procKey, immediate)
    local visual = activeVisuals[procKey]
    if not visual then return end
    if immediate then
        visual.texture:Hide()
        activeVisuals[procKey] = nil
        slotByProc[procKey] = nil
        visual.procKey = nil; visual.definition = nil; visual.timeLeft = nil; visual.duration = nil; visual.isBuff = nil; visual.testPreview = nil; visual.expiryElapsed = nil; visual.renderAlpha = nil; visual.fadeStartAlpha = nil
        table.insert(visualPool, visual)
    elseif visual.state ~= "out" then
        -- Continue the normal fade-out from the opacity that is currently on
        -- screen. Visual Expiry may already have reduced the overlay to almost
        -- zero; restarting the out animation at 80% caused the final flash.
        visual.fadeStartAlpha = visual.renderAlpha or 0.8
        visual.state = "out"; visual.elapsed = 0
    end
end

local function HasVisibleVisual()
    return next(activeVisuals) ~= nil
end

local function UpdateVisual()
    local dt = arg1 or 0
    local settings = GetProcSettings()
    local globalOpacity = (settings and settings.procOverlayOpacity) or 0.85
    local key, visual
    local releaseCount = 0
    for key, visual in pairs(activeVisuals) do
        visual.elapsed = visual.elapsed + dt
        if visual.timeLeft and visual.state == "active" and not testModeActive then
            local previousTimeLeft = visual.timeLeft
            visual.timeLeft = math.max(0, visual.timeLeft - dt)
            if previousTimeLeft > 0 and visual.timeLeft <= 0 then
                -- Some 1.12 clients report an expiring aura for one more scan.
                -- Without this guard the pooled visual can be recreated for a
                -- single frame after the fade has completed.
                expirySuppressed[key] = true
            end
        end
        if testModeActive and visual.testPreview and settings and settings.procOverlayExpiry then
            -- Persistent test alerts use a repeating preview cycle: three
            -- seconds fully visible, followed by the same five-second alpha fade
            -- used by live procs. They never disappear permanently.
            visual.expiryElapsed = (visual.expiryElapsed or 0) + dt
            if visual.expiryElapsed >= 8.0 then
                visual.expiryElapsed = visual.expiryElapsed - 8.0
            end
        end
        local alpha, pulseScale
        if visual.state == "in" then
            local p = visual.elapsed / 0.18
            if p >= 1 then p = 1; visual.state = "active"; visual.elapsed = 0 end
            alpha = p * 0.8
            pulseScale = 0.9 + (0.1 * p)
        elseif visual.state == "active" then
            if settings and settings.procOverlayPulse then
                -- Optional original ProcDoc breathing animation.
                local wave = (math.sin(visual.elapsed * 4.0) + 1) * 0.5
                alpha = 0.8 + (0.2 * wave)
                pulseScale = 0.9 + (0.1 * wave)
            else
                alpha = 1.0
                pulseScale = 1.0
            end
        else
            local p = 1 - (visual.elapsed / 0.25)
            if p <= 0 then
                releaseCount = releaseCount + 1
                releaseQueue[releaseCount] = key
            else
                alpha = p * (visual.fadeStartAlpha or 0.8)
                pulseScale = 0.9
            end
        end
        if alpha then
            local procOpacity = GetOverrideValue(visual.definition, "opacity", 1.0)
            ApplyLayout(visual, visual.definition, key, pulseScale)
            local expiryAlpha = 1
            if visual.state == "active" and settings and settings.procOverlayExpiry then
                local ratio = 1
                if testModeActive and visual.testPreview then
                    local previewLeft = 8.0 - (visual.expiryElapsed or 0)
                    ratio = previewLeft >= 5.0 and 1 or (previewLeft / 5.0)
                elseif visual.timeLeft ~= nil then
                    local expiryWindow = 5.0
                    if visual.timeLeft <= 0 then
                        -- Do not let the expiry fade jump back to full opacity at
                        -- zero. The aura scan may remove the visual a fraction of
                        -- a second later; keeping ratio at 0 prevents a final flash.
                        ratio = 0
                    else
                        ratio = visual.timeLeft >= expiryWindow and 1 or (visual.timeLeft / expiryWindow)
                    end
                end
                expiryAlpha = ApplyExpiryTransform(visual, visual.definition, key, ratio)
            end
            -- Remember the normalized opacity actually rendered this frame.
            -- If the aura disappears during Visual Expiry, ReleaseVisual uses
            -- this value as the start of the out animation instead of jumping
            -- back to a fixed opacity.
            visual.renderAlpha = alpha * expiryAlpha
            visual.texture:SetVertexColor(visual.definition.r or 1, visual.definition.g or 1, visual.definition.b or 1)
            visual.texture:SetAlpha(visual.renderAlpha * globalOpacity * procOpacity)
            visual.texture:Show()
        end
    end
    local i
    for i = 1, releaseCount do
        key = releaseQueue[i]
        releaseQueue[i] = nil
        ReleaseVisual(key, true)
    end
    if not HasVisibleVisual() then frame:SetScript("OnUpdate", nil) end
end

local function HideAll(immediate)
    local count = 0
    local key
    for key in pairs(activeVisuals) do
        count = count + 1
        releaseQueue[count] = key
    end
    local i
    for i = 1, count do
        key = releaseQueue[i]
        releaseQueue[i] = nil
        ReleaseVisual(key, immediate)
    end
    if immediate then frame:SetScript("OnUpdate", nil) else frame:SetScript("OnUpdate", UpdateVisual) end
end

local function ShowVisual(definition, procKey, isTestPreview, isBuff)
    if not definition or not procKey then return end
    local visual = activeVisuals[procKey]

    -- Live proc visuals are single-instance. If the same proc is already
    -- entering, active, or fading out, do not restart its intro animation.
    -- A fresh proc can only create a new visual after the previous object has
    -- been fully released from activeVisuals. Test previews remain refreshable.
    if visual and not isTestPreview then
        return visual
    end

    if not visual then
        visual = AcquireVisual()
        activeVisuals[procKey] = visual
        slotByProc[procKey] = visual
    end
    visual.procKey = procKey
    visual.definition = definition
    visual.state = "in"
    visual.elapsed = 0
    visual.testPreview = isTestPreview and true or false
    visual.isBuff = isBuff and true or false
    visual.expiryElapsed = 0
    visual.renderAlpha = 0
    visual.fadeStartAlpha = nil
    -- Clear the previous pooled texture first. Vanilla can otherwise keep the
    -- former artwork visible for one frame when a different file is assigned.
    visual.texture:SetTexture(nil)
    visual.texture:SetTexture(PROCDOC_TEXTURE_PATH .. definition.texture)
    visual.texture:SetBlendMode("BLEND")
    visual.texture:SetVertexColor(definition.r or 1, definition.g or 1, definition.b or 1)
    ApplyLayout(visual, definition, procKey, 0.9)
    visual.texture:SetAlpha(0)
    visual.texture:Show()
    frame:SetScript("OnUpdate", UpdateVisual)
    return visual
end

local function GetClassDefinitions()
    local _, class = UnitClass("player")
    return class and procDefinitions[class]
end

-- Reuse the fixed Hot Streak visual definitions instead of allocating new
-- tables every time the player's buffs are scanned.
local HOT_STREAK_LEFT = { name = "Hot Streak", texture = "WarriorRevenge.tga", style = "LEFT" }
local HOT_STREAK_RIGHT = { name = "Hot Streak", texture = "WarriorRevenge.tga", style = "RIGHT" }
local HOT_STREAK_TOP = { name = "Hot Streak", texture = "MageHotStreak.tga", style = "TOP2" }

local function AuraCoreOriginalProcScan()
    if testModeActive then return end
    local settings = GetProcSettings()
    local cache = AuraCoreAuraCache
    if not settings or not settings.procAlertsEnabled or not cache or not cache.GetAuraBySlot then
        for key in pairs(seenProcs) do seenProcs[key] = nil end
        for key in pairs(assignedProcs) do assignedProcs[key] = nil end
        HideAll(true)
        return
    end

    -- AuraCache is refreshed by PLAYER_AURAS_CHANGED before this module's queued
    -- scan runs. Refresh only as an initialization fallback, never rescan buffs
    -- independently from ProcAlerts.
    if cache.GetLastRefresh and cache.GetLastRefresh() == 0 and cache.Refresh then
        cache.Refresh()
    end

    local definitions = GetClassDefinitions()
    if not definitions then HideAll(true); return end

    for key in pairs(seenProcs) do seenProcs[key] = nil end
    for key in pairs(seenProcTiming) do seenProcTiming[key] = nil end
    for key in pairs(assignedProcs) do assignedProcs[key] = nil end

    shadowTranceTimeLeft = 0
    local shadowTranceSeen = false
    local hotStreakStacks = 0

    local maxSlots = cache.GetMaxSlots and cache.GetMaxSlots() or 32
    local slotIndex
    for slotIndex = 1, maxSlots do
        local aura = cache.GetAuraBySlot(slotIndex)
        local name = aura and aura.name
        if name then
            local stacks = aura.stacks or 0
            local key = string.lower(name)
            local definition = definitions[key]
            if definition and IsAlertEnabled(definition) then
                if definition.special == "HOT_STREAK" then
                    if stacks and stacks > hotStreakStacks then hotStreakStacks = stacks end
                else
                local usable = true
                local timeLeft = aura.remaining
                if definition.id == "shadow_trance" then
                    shadowTranceSeen = true
                    if timeLeft then
                        if timeLeft > shadowTranceTimeLeft then shadowTranceTimeLeft = timeLeft end
                        usable = timeLeft > 0.1
                    end
                end
                if usable then
                    -- Several clients expose the same proc under multiple aura
                    -- names (for example "Nightfall" and "Shadow Trance").
                    -- Store aliases under one canonical ID so one proc can
                    -- never occupy both overlay slots.
                    local procKey = definition.id or key
                    if definition.dual then
                        -- Cache mirrored keys on the static definition so the
                        -- proc scan does not concatenate new strings every tick.
                        local leftKey = definition._acLeftKey
                        local rightKey = definition._acRightKey
                        if not leftKey then
                            leftKey = procKey .. "_left"
                            rightKey = procKey .. "_right"
                            definition._acLeftKey = leftKey
                            definition._acRightKey = rightKey
                        end
                        seenProcs[leftKey] = definition
                        seenProcs[rightKey] = definition
                        SetSeenTiming(leftKey, timeLeft, nil, true)
                        SetSeenTiming(rightKey, timeLeft, nil, true)
                    else
                        seenProcs[procKey] = definition
                        SetSeenTiming(procKey, timeLeft, nil, true)
                    end
                end
                end
            end
        end
    end

    -- ProcDoc's Turtle WoW Hot Streak display is stack-tiered:
    -- 3 stacks = left, 4 = left + right, 5 = left + right + top.
    if hotStreakStacks >= 3 then
        seenProcs["hot_streak_left"] = HOT_STREAK_LEFT
    end
    if hotStreakStacks >= 4 then
        seenProcs["hot_streak_right"] = HOT_STREAK_RIGHT
    end
    if hotStreakStacks >= 5 then
        seenProcs["hot_streak_top"] = HOT_STREAK_TOP
    end

    AddActionProcsToSeen()

    -- Clear expiry suppression only when the aura is genuinely gone or a new
    -- full-duration proc has appeared. Tiny final values are treated as stale
    -- client data and remain suppressed.
    local suppressedKey
    for suppressedKey in pairs(expirySuppressed) do
        local timing = seenProcTiming[suppressedKey]
        if not seenProcs[suppressedKey] then
            expirySuppressed[suppressedKey] = nil
        elseif timing and timing.timeLeft and timing.timeLeft > 0.50 then
            expirySuppressed[suppressedKey] = nil
        end
    end

    -- Release the consumption block when the aura disappears or when its
    -- remaining duration jumps up again. The latter means Nightfall procced a
    -- second time before the stale client-side aura had fully vanished.
    if consumedProcs["shadow_trance_left"] or consumedProcs["shadow_trance_right"] then
        local freshProc = false
        if not shadowTranceSeen then
            freshProc = true
        elseif shadowTranceTimeLeft > 0 then
            freshProc = shadowTranceTimeLeft > (shadowTranceConsumedTimeLeft + 0.20)
        else
            freshProc = (GetTime() - shadowTranceConsumedAt) > 0.75
        end

        if freshProc then
            consumedProcs["shadow_trance_left"] = nil
            consumedProcs["shadow_trance_right"] = nil
        end
    end

    local consumedKey
    for consumedKey in pairs(consumedProcs) do
        if consumedKey ~= "shadow_trance_left" and consumedKey ~= "shadow_trance_right" and not seenProcs[consumedKey] then
            consumedProcs[consumedKey] = nil
        end
    end

    -- Every proc now owns an independent visual object. Simultaneous alerts
    -- can no longer replace each other merely because they share a side/style.
    local key, visual
    for key, visual in pairs(activeVisuals) do
        if expirySuppressed[key] then
            -- Visual Expiry has already faded this overlay to alpha 0. Starting
            -- the normal fade-out here would raise alpha back to ~0.8 for one
            -- frame and cause the visible end-of-timer flash. Remove it without
            -- another fade instead.
            ReleaseVisual(key, true)
        elseif consumedProcs[key] or not seenProcs[key] then
            ReleaseVisual(key, false)
        else
            local timing = seenProcTiming[key]
            if timing then
                visual.timeLeft = timing.timeLeft
                visual.duration = timing.duration
                visual.isBuff = timing.isBuff and true or false
            end
            assignedProcs[key] = true
        end
    end

    local definition
    for key, definition in pairs(seenProcs) do
        if not consumedProcs[key] and not expirySuppressed[key] and not assignedProcs[key] then
            local timing = seenProcTiming[key]
            ShowVisual(definition, key, false, timing and timing.isBuff)
            local visual = activeVisuals[key]
            if timing and visual then
                visual.timeLeft = timing.timeLeft
                visual.duration = timing.duration
                visual.isBuff = timing.isBuff and true or false
            end
            assignedProcs[key] = true
        end
    end
end

function PCProc.Scan()
    if AuraCoreProfilerRecord then
        local started = GetTime()
        AuraCoreOriginalProcScan()
        AuraCoreProfilerRecord("Proc.Scan", GetTime() - started)
    else
        AuraCoreOriginalProcScan()
    end
end

function PCProc.GetAlertKey(definition)
    return GetAlertSettingKey(definition)
end

function PCProc.GetProcOverride(definition)
    local override = GetProcOverride(definition)
    if not override then return nil end
    return override
end

function PCProc.SetProcOverride(definition, field, value)
    local settings = GetProcSettings()
    if not definition or not field or not settings then return end
    local key = GetAlertSettingKey(definition)
    if not key then return end
    settings.procOverrides = settings.procOverrides or {}
    local override = settings.procOverrides[key]
    if not override then
        override = {}
        settings.procOverrides[key] = override
    end
    override[field] = value
    PCProc.Refresh()
end

function PCProc.ResetProcOverride(definition)
    local settings = GetProcSettings()
    if not definition or not settings or not settings.procOverrides then return end
    local key = GetAlertSettingKey(definition)
    if key then settings.procOverrides[key] = nil end
    PCProc.Refresh()
end

function PCProc.GetClassAlerts()
    local alerts = {}
    local used = {}
    local definitions = GetClassDefinitions()
    local _, definition
    if definitions then
        for _, definition in pairs(definitions) do
            local key = GetAlertSettingKey(definition)
            if key and not used[key] then
                used[key] = true
                table.insert(alerts, definition)
            end
        end
    end
    local actions = GetClassActionDefinitions()
    if actions then
        for _, definition in ipairs(actions) do
            local key = GetAlertSettingKey(definition)
            if key and not used[key] then
                used[key] = true
                table.insert(alerts, definition)
            end
        end
    end
    table.sort(alerts, function(a, b) return (a.name or a.spellName or "") < (b.name or b.spellName or "") end)
    return alerts
end

function PCProc.SelectTestAlert(definition)
    -- Selection is retained for future per-proc editing, but changing a row
    -- while test mode is active is handled once by SetAlertEnabled below.
    selectedTestDefinition = definition
end

function PCProc.SetAlertEnabled(definition, enabled)
    local settings = GetProcSettings()
    if not settings then return end
    settings.procAlertEnabled = settings.procAlertEnabled or {}
    local key = GetAlertSettingKey(definition)
    if key then settings.procAlertEnabled[key] = enabled and true or false end
    selectedTestDefinition = definition

    if testModeActive then
        ShowTestAlerts()
    else
        PCProc.Scan()
    end
end

function PCProc.IsAlertEnabled(definition)
    return IsAlertEnabled(definition)
end

function PCProc.HideTests()
    testModeActive = false
    HideAll(true)
end

local function IsBuffDefinition(definition)
    local definitions = GetClassDefinitions()
    if not definitions or not definition then return false end
    local _, candidate
    for _, candidate in pairs(definitions) do
        if candidate == definition then return true end
    end
    return false
end

local function ShowDefinitionForTest(definition, baseKey)
    if not definition or not baseKey then return end
    local isBuff = IsBuffDefinition(definition)

    -- ProcDoc's live Hot Streak visual is tiered. Preview the complete five-
    -- stack state: LEFT + RIGHT + TOP2.
    if definition.special == "HOT_STREAK" then
        ShowVisual(HOT_STREAK_LEFT, baseKey .. "_left", true, isBuff)
        ShowVisual(HOT_STREAK_RIGHT, baseKey .. "_right", true, isBuff)
        ShowVisual(HOT_STREAK_TOP, baseKey .. "_top", true, isBuff)
    elseif definition.dual then
        ShowVisual(definition, baseKey .. "_left", true, isBuff)
        ShowVisual(definition, baseKey .. "_right", true, isBuff)
    else
        ShowVisual(definition, baseKey, true, isBuff)
    end
end

ShowTestAlerts = function()
    HideAll(true)

    -- Test every enabled alert simultaneously. This mirrors the checkbox
    -- state directly, avoids stale single-selection previews, and allows
    -- users to compare multiple ProcDoc overlays without leaving test mode.
    local alerts = PCProc.GetClassAlerts()
    local index, definition
    for index, definition in ipairs(alerts) do
        if IsAlertEnabled(definition) then
            local settingKey = GetAlertSettingKey(definition) or (definition.name or definition.spellName or tostring(index))
            local testKey = "test_" .. string.gsub(string.lower(settingKey), "[^%w]+", "_")
            ShowDefinitionForTest(definition, testKey)
        end
    end
end

function PCProc.ToggleTest()
    if testModeActive then
        PCProc.HideTests()
        PCProc.Scan()
        return false
    end
    testModeActive = true
    ShowTestAlerts()
    return true
end

function PCProc.Test()
    return PCProc.ToggleTest()
end

function PCProc.Refresh()
    local key, visual
    for key, visual in pairs(activeVisuals) do
        ApplyLayout(visual, visual.definition, key, 1.0)
    end
    PCProc.Scan()
end

-- Nightfall / Shadow Trance consumption handling. Turtle WoW may keep a
-- same-named temporary aura visible after the instant Shadow Bolt is consumed.
local actionTip = CreateFrame("GameTooltip", "AuraCoreProcActionTooltip", UIParent, "GameTooltipTemplate")

local function IsShadowBolt(spellName)
    if not spellName then return false end
    local lowerName = string.lower(spellName)
    return string.find(lowerName, "shadow bolt", 1, true)
        or string.find(lowerName, "shadowblitz", 1, true)
end

-- Casting functions only report an attempt. The proc must not disappear when
-- the cast fails because of insufficient mana, range, silence, etc.
local function QueueShadowTranceConsumption(spellName)
    if not (slotByProc["shadow_trance_left"] or slotByProc["shadow_trance_right"]) then
        pendingShadowTranceCast = false
        pendingShadowTranceCastAt = 0
        return
    end

    -- Every known spell attempt replaces the previous pending state. This is
    -- important because Vanilla's SPELLCAST_STOP event does not include the
    -- spell name: a later Life Tap could otherwise confirm an older Shadow
    -- Bolt attempt and hide Shadow Trance incorrectly.
    if spellName then
        pendingShadowTranceCast = IsShadowBolt(spellName) and true or false
        pendingShadowTranceCastAt = pendingShadowTranceCast and GetTime() or 0
    end
end

local function ConfirmShadowTranceConsumption()
    if not pendingShadowTranceCast then return end
    -- Ignore stale cast attempts. A genuine Shadow Bolt stop follows its cast
    -- request immediately, while unrelated later spells must not consume the proc.
    if pendingShadowTranceCastAt == 0 or (GetTime() - pendingShadowTranceCastAt) > 2.0 then
        pendingShadowTranceCast = false
        pendingShadowTranceCastAt = 0
        return
    end
    pendingShadowTranceCast = false
    pendingShadowTranceCastAt = 0
    if not slotByProc["shadow_trance_left"] and not slotByProc["shadow_trance_right"] then return end
    consumedProcs["shadow_trance_left"] = true
    consumedProcs["shadow_trance_right"] = true
    shadowTranceConsumedTimeLeft = shadowTranceTimeLeft or 0
    shadowTranceConsumedAt = GetTime()
    ReleaseVisual("shadow_trance_left", true)
    ReleaseVisual("shadow_trance_right", true)
end

local function GetActionName(slot)
    if not slot then return nil end
    actionTip:SetOwner(UIParent, "ANCHOR_NONE")
    actionTip:ClearLines()
    actionTip:SetAction(slot)
    local line = getglobal("AuraCoreProcActionTooltipTextLeft1")
    local name = line and line:GetText()
    actionTip:Hide()
    return name
end

if not PCProc.consumptionHooksInstalled then
    PCProc.consumptionHooksInstalled = true

    local originalUseAction = UseAction
    if originalUseAction then
        UseAction = function(slot, checkCursor, onSelf)
            local spellName
            if slotByProc["shadow_trance_left"] or slotByProc["shadow_trance_right"] then spellName = GetActionName(slot) end
            local result = originalUseAction(slot, checkCursor, onSelf)
            QueueShadowTranceConsumption(spellName)
            return result
        end
    end

    local originalCastSpellByName = CastSpellByName
    if originalCastSpellByName then
        CastSpellByName = function(spellName, onSelf)
            local result = originalCastSpellByName(spellName, onSelf)
            QueueShadowTranceConsumption(spellName)
            return result
        end
    end

    local originalCastSpell = CastSpell
    if originalCastSpell then
        CastSpell = function(spellId, bookType)
            local spellName = GetSpellName and GetSpellName(spellId, bookType)
            local result = originalCastSpell(spellId, bookType)
            QueueShadowTranceConsumption(spellName)
            return result
        end
    end
end

-- A fresh Nightfall can proc immediately after the previous one was consumed.
-- On some Turtle WoW clients the old aura never visibly drops first, so aura
-- duration comparisons alone cannot reliably distinguish the new proc. The
-- self-buff combat message is emitted for every fresh proc and therefore
-- releases the consumption lock immediately.
local function IsShadowTranceGainMessage(message)
    if not message then return false end
    local text = string.lower(message)
    return string.find(text, "shadow trance", 1, true)
        or string.find(text, "shadowtrance", 1, true)
        or string.find(text, "nightfall", 1, true)
        or string.find(text, "schattentrance", 1, true)
end

local function ReleaseShadowTranceLock()
    consumedProcs["shadow_trance_left"] = nil
    consumedProcs["shadow_trance_right"] = nil
    shadowTranceConsumedTimeLeft = 0
    shadowTranceConsumedAt = 0
end

-- Many combat events can fire in the same frame. Queue one proc scan for the
-- next frame so bursts are collapsed without changing which events request a
-- refresh. A separate driver is used because the visual frame owns its own
-- OnUpdate animation handler.
local scanDriver = CreateFrame("Frame")
local scanPending = false

local function QueueProcScan()
    if scanPending then return end
    scanPending = true
    scanDriver:SetScript("OnUpdate", function()
        scanDriver:SetScript("OnUpdate", nil)
        scanPending = false
        PCProc.Scan()
    end)
end

frame:RegisterEvent("PLAYER_AURAS_CHANGED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")
frame:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")
frame:RegisterEvent("SPELLCAST_STOP")
frame:RegisterEvent("SPELLCAST_FAILED")
frame:RegisterEvent("SPELLCAST_INTERRUPTED")
frame:RegisterEvent("ACTIONBAR_UPDATE_USABLE")
frame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
frame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
frame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function()
    if event == "SPELLCAST_STOP" then
        ConfirmShadowTranceConsumption()
    elseif event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
        pendingShadowTranceCast = false
        pendingShadowTranceCastAt = 0
    elseif (event == "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS" or event == "CHAT_MSG_SPELL_SELF_BUFF")
        and IsShadowTranceGainMessage(arg1) then
        ReleaseShadowTranceLock()
    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombatFlag = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombatFlag = false
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "ACTIONBAR_PAGE_CHANGED"
        or event == "UPDATE_BONUS_ACTIONBAR" or event == "UPDATE_SHAPESHIFT_FORM" then
        actionCacheDirty = true
    end
    QueueProcScan()
end)
