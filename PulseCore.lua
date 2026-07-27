-- PulseCore for Vanilla / Turtle WoW 1.12
-- Native polling implementation. No modern API, secure hooks, or external libraries.

local DCP = CreateFrame("Frame", "PulseCoreFrame", UIParent)
local icon = DCP:CreateTexture(nil, "ARTWORK")
local text = DCP:CreateFontString(nil, "OVERLAY", "GameFontNormal")
local scanTip = CreateFrame("GameTooltip", "DCPScanTooltip", UIParent, "GameTooltipTemplate")

local actionState, inventoryState, bagState, buffState = {}, {}, {}, {}
local actionObserved, inventoryObserved, bagObserved = {}, {}, {}
local actionMeta, inventoryMeta, bagMeta, buffMeta = {}, {}, {}, {}
local pulses, filters, buffFilters, buffBlacklist, recentPulses = {}, {}, {}, {}, {}
local pulseHead, pulseTail = 1, 0
local scanGeneration = 0
local actionCandidates = {}
local actionCandidateCount = 0
local activeElapsed, discoveryElapsed, cleanupElapsed, animElapsed = 0, 0, 0, 0
local cooldownDataDirty = true
local suppressUntil = 0
local currentPulse = nil
local unlocked = false
local CreateMinimapButton
local ResetPulseVisual

local VERSION = "1.0.1 Performance Fix"
local TEST_ICON = "Interface\\Icons\\Spell_Nature_EarthBind"
local READY_SOUND = "Sound\\Interface\\iTellMessage.wav"

local defaults = {
    fadeInTime = 0.18,
    holdTime = 0.12,
    fadeOutTime = 0.55,
    pulseDuration = 0.85,
    maxAlpha = 0.95,
    animScale = 1.60,
    iconSize = 78,
    showSpellName = true,
    showSpells = true,
    showBagItems = true,
    showEquipment = true,
    playSound = false,
    animate = true,
    scanRate = 0.10, -- legacy setting; retained for old SavedVariables
    activeScanRate = 0.20,
    idleScanRate = 0.80,
    raidActiveScanRate = 0.30,
    raidIdleScanRate = 1.25,
    minCooldown = 1.6,
    x = 0,
    y = 0,
    minimapAngle = 220,
    minimapHidden = false,
    showBuffExpirations = false,
    ignoreHealingOverTime = true, -- legacy setting, migrated to ignoreTemporaryCombatBuffs
    ignoreTemporaryCombatBuffs = true,
    temporaryBuffMaxDuration = 30,
    enableBuffBlacklist = true,
    buffMinDuration = 2.0,
    autoLongBuffs = true,
    autoBuffMinRemaining = 120, -- 2 minutes: persistent buffs; short combat effects are filtered separately
}

local charDefaults = {
    ignoredSpells = "",
    invertIgnored = false,
    buffFilterList = "",
    buffBlacklist = "",
    invertBuffFilter = true, -- legacy field
}

local function CopyDefaults(source, target)
    if type(target) ~= "table" then target = {} end
    for k, v in pairs(source) do
        if target[k] == nil then target[k] = v end
    end
    return target
end

local function Trim(value)
    value = value or ""
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    return value
end

local function RefreshFilters()
    filters = {}
    local value = ""
    if DCP_SavedPerCharacter and DCP_SavedPerCharacter.ignoredSpells then
        value = DCP_SavedPerCharacter.ignoredSpells
    end
    for entry in string.gfind(value .. ",", "(.-),") do
        entry = string.lower(Trim(entry))
        if entry ~= "" then filters[entry] = true end
    end
end

local function IsAllowed(name)
    if not name or name == "" then
        return not (DCP_SavedPerCharacter and DCP_SavedPerCharacter.invertIgnored)
    end
    local listed = filters[string.lower(name)] and true or false
    if DCP_SavedPerCharacter and DCP_SavedPerCharacter.invertIgnored then
        return listed
    end
    return not listed
end

local function RefreshBuffFilters()
    buffFilters = {}
    buffBlacklist = {}
    local value = ""
    if DCP_SavedPerCharacter and DCP_SavedPerCharacter.buffFilterList then
        value = DCP_SavedPerCharacter.buffFilterList
    end
    for entry in string.gfind(value .. ",", "(.-),") do
        entry = string.lower(Trim(entry))
        if entry ~= "" then buffFilters[entry] = true end
    end

    value = ""
    if DCP_SavedPerCharacter and DCP_SavedPerCharacter.buffBlacklist then
        value = DCP_SavedPerCharacter.buffBlacklist
    end
    for entry in string.gfind(value .. ",", "(.-),") do
        entry = string.lower(Trim(entry))
        if entry ~= "" then buffBlacklist[entry] = true end
    end
end

-- Common healing-over-time effects and short combat procs. Names are matched
-- case-insensitively and include English/German Vanilla/Turtle names.
local temporaryCombatBuffNames = {
    ["renew"] = true,
    ["erneuerung"] = true,
    ["rejuvenation"] = true,
    ["verjüngung"] = true,
    ["regrowth"] = true,
    ["nachwachsen"] = true,
    ["lifebloom"] = true,
    ["blühendes leben"] = true,
    ["wild growth"] = true,
    ["wildwuchs"] = true,
    ["riptide"] = true,
    ["springflut"] = true,
    ["earthliving"] = true,
    ["lebensgeister"] = true,
    ["gift of the naaru"] = true,
    ["gabe der naaru"] = true,
    ["healing way"] = true,
    ["pfad der heilung"] = true,
    ["heathen's light"] = true,
    ["heathens light"] = true,
}

local function IsBuffAllowed(name, timeLeft)
    if not name or name == "" then return false end
    local key = string.lower(Trim(name))

    -- The optional blacklist always wins. Only explicitly listed buffs are hidden.
    if DCP_Saved and DCP_Saved.enableBuffBlacklist and buffBlacklist[key] then
        return false
    end

    -- The additional list is an allow-list for short or special buffs and may
    -- intentionally override the automatic short-combat-buff filter.
    if buffFilters[key] then return true end

    if DCP_Saved and DCP_Saved.ignoreTemporaryCombatBuffs then
        if temporaryCombatBuffNames[key] then return false end
        if (timeLeft or 0) < (DCP_Saved.temporaryBuffMaxDuration or 30) then return false end
    end

    if DCP_Saved and DCP_Saved.autoLongBuffs then
        return (timeLeft or 0) >= (DCP_Saved.autoBuffMinRemaining or 120)
    end
    return false
end


-- Safe metadata helpers for the Vanilla 1.12 API. These functions are kept in
-- one place so action, item and buff scans never depend on modern APIs.
local function SafeTooltipName(setter, a, b)
    if not scanTip or not setter then return nil end
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    local ok
    if b ~= nil then
        ok = pcall(setter, scanTip, a, b)
    else
        ok = pcall(setter, scanTip, a)
    end
    local name
    if ok then
        local line = getglobal("DCPScanTooltipTextLeft1")
        name = line and line:GetText()
    end
    scanTip:Hide()
    return name
end

local function GetActionMeta(slot)
    local texture = GetActionTexture(slot)
    if not texture then
        actionMeta[slot] = nil
        return nil, nil
    end
    local cached = actionMeta[slot]
    if not cached or cached.texture ~= texture then
        cached = {
            texture = texture,
            name = SafeTooltipName(function(tip, value) tip:SetAction(value) end, slot)
        }
        actionMeta[slot] = cached
    end
    return texture, cached.name
end

local function GetInventoryMeta(slot)
    local texture = GetInventoryItemTexture("player", slot)
    local link = GetInventoryItemLink("player", slot)
    if not texture or not link then
        inventoryMeta[slot] = nil
        return nil, nil
    end
    local cached = inventoryMeta[slot]
    if not cached or cached.link ~= link then
        local _, _, name = string.find(link, "%[(.-)%]")
        cached = { texture = texture, link = link, name = name }
        inventoryMeta[slot] = cached
    end
    return texture, cached.name
end

local function BagKey(bag, slot)
    return (bag * 100) + slot
end

local function UpdateObservedState(store, key, active, start, duration, texture, name)
    local state = store[key]
    if not state then
        state = {}
        store[key] = state
    end
    state.active = active
    state.start = start or 0
    state.duration = duration or 0
    state.texture = texture
    state.name = name
    return state
end

local function GetBagMeta(bag, slot)
    local texture = GetContainerItemInfo(bag, slot)
    local link = GetContainerItemLink(bag, slot)
    local key = BagKey(bag, slot)
    if not texture or not link then
        bagMeta[key] = nil
        return nil, nil, key
    end
    local cached = bagMeta[key]
    if not cached or cached.link ~= link then
        local _, _, name = string.find(link, "%[(.-)%]")
        cached = { texture = texture, link = link, name = name }
        bagMeta[key] = cached
    end
    return texture, cached.name, key
end

local function PulseKey(texture, name)
    return (name or "") .. "|" .. (texture or "")
end

local function QueuePulse(texture, name)
    if not texture or texture == "" or not IsAllowed(name) then return end
    local now = GetTime()
    local key = PulseKey(texture, name)
    if recentPulses[key] and now - recentPulses[key] < 0.75 then return end
    recentPulses[key] = now
    pulseTail = pulseTail + 1
    local index = pulseTail
    local pulse = pulses[index]
    if not pulse then pulse = {}; pulses[index] = pulse end
    pulse.texture = texture
    pulse.name = name
end

local function QueueBuffPulse(texture, name)
    -- Eligibility is decided when the buff is first tracked. Do not require the
    -- remaining-time threshold again when it actually expires.
    if not texture or texture == "" then return end
    local now = GetTime()
    local key = "BUFF|" .. PulseKey(texture, name)
    if recentPulses[key] and now - recentPulses[key] < 0.75 then return end
    recentPulses[key] = now
    pulseTail = pulseTail + 1
    local index = pulseTail
    local pulse = pulses[index]
    if not pulse then pulse = {}; pulses[index] = pulse end
    pulse.texture = texture
    pulse.name = name
end

local function CleanupRecent(now)
    for key, stamp in pairs(recentPulses) do
        if now - stamp > 3 then recentPulses[key] = nil end
    end
end

local function CooldownActive(start, duration, enable)
    start = start or 0
    duration = duration or 0
    if enable == 0 then return false end
    return start > 0 and duration > (DCP_Saved.minCooldown or 1.6)
end

-- Vanilla occasionally reports cooldown 0 for a single scan during lag,
-- action-page changes, zoning, or item movement. A pulse is only valid when
-- the originally calculated cooldown end has actually been reached.
local function NewCooldownState(start, duration, texture, name)
    return {
        active = true,
        start = start or 0,
        duration = duration or 0,
        endsAt = (start or 0) + (duration or 0),
        texture = texture,
        name = name,
        missingScans = 0,
    }
end

local function UpdateTrackedCooldown(old, start, duration, texture, name)
    local endsAt = (start or 0) + (duration or 0)
    old.active = true
    old.start = start or 0
    old.duration = duration or 0
    old.endsAt = endsAt
    old.texture = texture or old.texture
    old.name = name or old.name
    old.missingScans = 0
end

local function ShouldCompleteCooldown(old, texture, name)
    if not old then return false end

    -- The slot now contains something else: this was a bar/page/bag change,
    -- not a real cooldown completion.
    if texture and old.texture and texture ~= old.texture then return false end
    if name and old.name and name ~= old.name then return false end

    old.missingScans = (old.missingScans or 0) + 1
    if old.missingScans < 2 then return nil end

    local now = GetTime()
    local tolerance = math.max((DCP_Saved.activeScanRate or 0.20) * 3, 0.45)
    return old.endsAt and now >= (old.endsAt - tolerance)
end

local function PlayerUnavailable()
    return UnitIsDeadOrGhost("player") or not UnitExists("player")
end

local function ClearCooldownStates()
    actionState = {}
    inventoryState = {}
    bagState = {}
    buffState = {}
    actionObserved = {}
    inventoryObserved = {}
    bagObserved = {}
    pulses = {}
    pulseHead, pulseTail = 1, 0
    currentPulse = nil
    recentPulses = {}
    actionMeta, inventoryMeta, bagMeta, buffMeta = {}, {}, {}, {}
    ResetPulseVisual()
end

-- Track only cooldowns that actually begin while the addon is watching.
-- Existing cooldowns seen after login/reload are used as a baseline, not queued.
local function SameCooldown(a, start, duration, texture, name)
    if not a then return false end
    if texture and a.texture and texture ~= a.texture then return false end
    if name and a.name and name ~= a.name then return false end
    return math.abs((a.start or 0) - (start or 0)) < 0.08 and math.abs((a.duration or 0) - (duration or 0)) < 0.08
end

local function IsNewCooldown(previous, start, duration, texture, name)
    if not previous or not previous.active then return true end
    return not SameCooldown(previous, start, duration, texture, name)
end

local function ClearActionCandidates()
    actionCandidateCount = 0
end

local function AddActionCandidate(slot, start, duration, texture, name)
    actionCandidateCount = actionCandidateCount + 1
    local index = actionCandidateCount
    local c = actionCandidates[index]
    if not c then c = {}; actionCandidates[index] = c end
    c.slot, c.start, c.duration, c.texture, c.name = slot, start, duration, texture, name
    c.suppressed = false
end

local function SuppressMassLockouts(candidates)
    local count = actionCandidateCount
    local i, j
    for i = 1, count do
        local a = candidates[i]
        local matches = 1
        for j = 1, count do
            if i ~= j then
                local b = candidates[j]
                if math.abs((a.start or 0) - (b.start or 0)) < 0.05 and math.abs((a.duration or 0) - (b.duration or 0)) < 0.05 then
                    local sameIdentity = (a.name and b.name and a.name == b.name) or (not a.name and not b.name and a.texture == b.texture)
                    if not sameIdentity then matches = matches + 1 end
                end
            end
        end
        if matches >= 3 then a.suppressed = true end
    end
end

local function DiscoverActions()
    if not DCP_Saved.showSpells then actionState = {}; actionObserved = {}; return end
    ClearActionCandidates()
    local candidates = actionCandidates
    local slot
    for slot = 1, 120 do
        if HasAction(slot) then
            local texture, name = GetActionMeta(slot)
            local start, duration, enable = GetActionCooldown(slot)
            local active = CooldownActive(start, duration, enable)
            local previous = actionObserved[slot]
            if active and IsNewCooldown(previous, start, duration, texture, name) then
                AddActionCandidate(slot, start, duration, texture, name)
            end
            UpdateObservedState(actionObserved, slot, active, start, duration, texture, name)

            local old = actionState[slot]
            if active then
                if old and SameCooldown(old, start, duration, texture, name) then
                    UpdateTrackedCooldown(old, start, duration, texture, name)
                end
            elseif old and old.active then
                local complete = ShouldCompleteCooldown(old, texture, name)
                if complete == true then QueuePulse(old.texture, old.name) end
                if complete ~= nil then actionState[slot] = nil end
            end
        else
            actionState[slot] = nil
            actionObserved[slot] = nil
            actionMeta[slot] = nil
        end
    end

    SuppressMassLockouts(candidates)
    local i
    for i = 1, actionCandidateCount do
        local c = candidates[i]
        if not c.suppressed then
            actionState[c.slot] = NewCooldownState(c.start, c.duration, c.texture, c.name)
        end
    end
end

local function TrackActions()
    local slot, old
    for slot, old in pairs(actionState) do
        if HasAction(slot) then
            local texture, name = GetActionMeta(slot)
            local start, duration, enable = GetActionCooldown(slot)
            local active = CooldownActive(start, duration, enable)
            UpdateObservedState(actionObserved, slot, active, start, duration, texture, name)
            if active then
                UpdateTrackedCooldown(old, start, duration, texture, name)
            else
                local complete = ShouldCompleteCooldown(old, texture, name)
                if complete == true then QueuePulse(old.texture, old.name) end
                if complete ~= nil then actionState[slot] = nil end
            end
        else
            actionState[slot] = nil
            actionObserved[slot] = nil
        end
    end
end

local function DiscoverInventory()
    if not DCP_Saved.showEquipment then inventoryState = {}; inventoryObserved = {}; return end
    local slot
    for slot = 0, 19 do
        local texture, name = GetInventoryMeta(slot)
        if texture then
            local start, duration, enable = GetInventoryItemCooldown("player", slot)
            local active = CooldownActive(start, duration, enable)
            local previous = inventoryObserved[slot]
            local old = inventoryState[slot]
            if active then
                if old and SameCooldown(old, start, duration, texture, name) then
                    UpdateTrackedCooldown(old, start, duration, texture, name)
                elseif IsNewCooldown(previous, start, duration, texture, name) then
                    inventoryState[slot] = NewCooldownState(start, duration, texture, name)
                end
            elseif old and old.active then
                local complete = ShouldCompleteCooldown(old, texture, name)
                if complete == true then QueuePulse(old.texture, old.name) end
                if complete ~= nil then inventoryState[slot] = nil end
            end
            UpdateObservedState(inventoryObserved, slot, active, start, duration, texture, name)
        else
            inventoryState[slot] = nil
            inventoryObserved[slot] = nil
        end
    end
end

local function TrackInventory()
    local slot, old
    for slot, old in pairs(inventoryState) do
        local texture, name = GetInventoryMeta(slot)
        if texture then
            local start, duration, enable = GetInventoryItemCooldown("player", slot)
            local active = CooldownActive(start, duration, enable)
            UpdateObservedState(inventoryObserved, slot, active, start, duration, texture, name)
            if active then UpdateTrackedCooldown(old, start, duration, texture, name)
            else
                local complete = ShouldCompleteCooldown(old, texture, name)
                if complete == true then QueuePulse(old.texture, old.name) end
                if complete ~= nil then inventoryState[slot] = nil end
            end
        else inventoryState[slot] = nil end
    end
end

local function DiscoverBags()
    if not DCP_Saved.showBagItems then bagState = {}; bagObserved = {}; return end
    local bag, slot
    for bag = 0, 4 do
        local count = GetContainerNumSlots(bag) or 0
        for slot = 1, count do
            local texture, name, key = GetBagMeta(bag, slot)
            if texture then
                local start, duration, enable = GetContainerItemCooldown(bag, slot)
                local active = CooldownActive(start, duration, enable)
                local previous = bagObserved[key]
                local old = bagState[key]
                if active then
                    if old and SameCooldown(old, start, duration, texture, name) then
                        UpdateTrackedCooldown(old, start, duration, texture, name)
                    elseif IsNewCooldown(previous, start, duration, texture, name) then
                        bagState[key] = NewCooldownState(start, duration, texture, name)
                        bagState[key].bag = bag
                        bagState[key].slot = slot
                    end
                elseif old and old.active then
                    local complete = ShouldCompleteCooldown(old, texture, name)
                    if complete == true then QueuePulse(old.texture, old.name) end
                    if complete ~= nil then bagState[key] = nil end
                end
                UpdateObservedState(bagObserved, key, active, start, duration, texture, name)
            else
                bagState[key] = nil
                bagObserved[key] = nil
            end
        end
    end
end

local function TrackBags()
    local key, old
    for key, old in pairs(bagState) do
        local bag = old.bag or math.floor(key / 100)
        local slot = old.slot or math.mod(key, 100)
        if bag and slot and slot > 0 then
            local texture, name = GetBagMeta(bag, slot)
            if texture then
                local start, duration, enable = GetContainerItemCooldown(bag, slot)
                local active = CooldownActive(start, duration, enable)
                UpdateObservedState(bagObserved, key, active, start, duration, texture, name)
                if active then UpdateTrackedCooldown(old, start, duration, texture, name)
                else
                    local complete = ShouldCompleteCooldown(old, texture, name)
                    if complete == true then QueuePulse(old.texture, old.name) end
                    if complete ~= nil then bagState[key] = nil end
                end
            else bagState[key] = nil end
        else bagState[key] = nil end
    end
end

local function GetPlayerBuffMeta(buffIndex)
    if buffIndex == nil or buffIndex < 0 then return nil, nil end
    local texture = GetPlayerBuffTexture and GetPlayerBuffTexture(buffIndex)
    if not texture then return nil, nil end

    local cached = buffMeta[buffIndex]
    if not cached or cached.texture ~= texture then
        local name = SafeTooltipName(function(tip, value) tip:SetPlayerBuff(value) end, buffIndex)
        cached = { texture = texture, name = name }
        buffMeta[buffIndex] = cached
    end
    return texture, cached.name
end

-- Clean buff scanner: one scan, one filter decision, one expiration path.
-- Buffs are only pulsed when they disappear at their expected natural end.
local function DiscoverBuffs()
    if not DCP_Saved.showBuffExpirations or not GetPlayerBuff or not GetPlayerBuffTimeLeft then
        buffState = {}
        return
    end

    local now = GetTime()
    scanGeneration = scanGeneration + 1
    local generation = scanGeneration
    local slot

    for slot = 0, 31 do
        local buffIndex = GetPlayerBuff(slot, "HELPFUL")
        if buffIndex and buffIndex >= 0 then
            local texture, name = GetPlayerBuffMeta(buffIndex)
            local timeLeft = GetPlayerBuffTimeLeft(buffIndex) or 0

            if texture and name and timeLeft > 0 then
                local key = tostring(buffIndex) .. "|" .. PulseKey(texture, name)
                local old = buffState[key]
                local endsAt = now + timeLeft

                if old then
                    -- Keep the newest expected end time after refresh/reapplication.
                    if endsAt > (old.endsAt or 0) + 0.75 then
                        old.endsAt = endsAt
                    end
                    old.texture = texture
                    old.name = name
                    old.lastSeen = now
                    old.lastTimeLeft = timeLeft
                    old.seenGeneration = generation
                elseif timeLeft >= (DCP_Saved.buffMinDuration or 2.0) and IsBuffAllowed(name, timeLeft) then
                    buffState[key] = {
                        texture = texture,
                        name = name,
                        endsAt = endsAt,
                        lastSeen = now,
                        lastTimeLeft = timeLeft,
                        seenGeneration = generation,
                    }
                end
            end
        end
    end

    local key, old
    for key, old in pairs(buffState) do
        if old.seenGeneration ~= generation then
            local tolerance = math.max((DCP_Saved.activeScanRate or 0.20) * 3, 0.65)
            -- Dispelled/cancelled buffs disappear too early and are discarded silently.
            if old.endsAt and now >= old.endsAt - tolerance then
                QueueBuffPulse(old.texture, old.name)
            end
            buffState[key] = nil
        end
    end
end

local function HasTrackedCooldowns()
    return next(actionState) or next(inventoryState) or next(bagState) or next(buffState)
end

local function GetPerformanceRates()
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        return DCP_Saved.raidActiveScanRate or 0.30, DCP_Saved.raidIdleScanRate or 1.25
    end
    return DCP_Saved.activeScanRate or 0.20, DCP_Saved.idleScanRate or 0.80
end

ResetPulseVisual = function()
    currentPulse = nil
    animElapsed = 0
    icon:SetTexture(nil)
    text:SetText("")
    DCP:SetAlpha(0)
    DCP:SetWidth(DCP_Saved.iconSize)
    DCP:SetHeight(DCP_Saved.iconSize)
end

local function StartNextPulse()
    if currentPulse or pulseHead > pulseTail then return end
    currentPulse = pulses[pulseHead]
    pulses[pulseHead] = nil
    pulseHead = pulseHead + 1
    if pulseHead > pulseTail then
        pulses = {}
        pulseHead, pulseTail = 1, 0
    end
    animElapsed = 0
    icon:SetTexture(currentPulse.texture)
    text:SetText(DCP_Saved.showSpellName and currentPulse.name or "")
    if DCP_Saved.playSound then PlaySoundFile(READY_SOUND) end
end

local function UpdatePulse(dt)
    if unlocked then return end
    StartNextPulse()
    if not currentPulse then return end

    animElapsed = animElapsed + dt
    local baseFadeIn = DCP_Saved.fadeInTime or 0.18
    local baseHold = DCP_Saved.holdTime or 0.12
    local baseFadeOut = DCP_Saved.fadeOutTime or 0.55
    local baseTotal = baseFadeIn + baseHold + baseFadeOut
    local total = DCP_Saved.pulseDuration or baseTotal
    local factor = baseTotal > 0 and (total / baseTotal) or 1
    local fadeIn = baseFadeIn * factor
    local hold = baseHold * factor
    local fadeOut = baseFadeOut * factor
    if animElapsed >= total then
        ResetPulseVisual()
        StartNextPulse()
        return
    end

    local alpha = DCP_Saved.maxAlpha
    if fadeIn > 0 and animElapsed < fadeIn then
        alpha = DCP_Saved.maxAlpha * animElapsed / fadeIn
    elseif fadeOut > 0 and animElapsed > fadeIn + hold then
        alpha = DCP_Saved.maxAlpha * (1 - ((animElapsed - fadeIn - hold) / fadeOut))
    end
    if alpha < 0 then alpha = 0 end
    DCP:SetAlpha(alpha)

    local size = DCP_Saved.iconSize
    if DCP_Saved.animate then
        local progress = total > 0 and animElapsed / total or 1
        size = size * (1 + ((DCP_Saved.animScale - 1) * progress))
    end
    DCP:SetWidth(size)
    DCP:SetHeight(size)
end

local function PositionFrame()
    DCP:ClearAllPoints()
    if not DCP_Saved.x or not DCP_Saved.y or (DCP_Saved.x == 0 and DCP_Saved.y == 0) then
        DCP:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    else
        DCP:SetPoint("CENTER", UIParent, "BOTTOMLEFT", DCP_Saved.x, DCP_Saved.y)
    end
end

DCP:SetWidth(78)
DCP:SetHeight(78)
DCP:SetFrameStrata("HIGH")
DCP:SetAlpha(0)
DCP:SetMovable(true)
DCP:RegisterForDrag("LeftButton")
DCP:EnableMouse(false)
icon:SetAllPoints(DCP)
text:SetPoint("TOP", DCP, "BOTTOM", 0, -5)
text:SetWidth(280)
text:SetJustifyH("CENTER")

DCP:SetScript("OnDragStart", function() if unlocked then DCP:StartMoving() end end)
DCP:SetScript("OnDragStop", function()
    if not unlocked then return end
    DCP:StopMovingOrSizing()
    local left, bottom = DCP:GetLeft(), DCP:GetBottom()
    if left and bottom then
        DCP_Saved.x = left + DCP:GetWidth() / 2
        DCP_Saved.y = bottom + DCP:GetHeight() / 2
    end
    PositionFrame()
end)

DCP:SetScript("OnUpdate", function()
    local dt = arg1 or 0
    if not DCP_Saved then return end

    if PlayerUnavailable() then
        if HasTrackedCooldowns() or currentPulse or pulseHead <= pulseTail then ClearCooldownStates() end
        return
    end

    local now = GetTime()
    if now < suppressUntil then
        UpdatePulse(dt)
        return
    end

    activeElapsed = activeElapsed + dt
    discoveryElapsed = discoveryElapsed + dt
    cleanupElapsed = cleanupElapsed + dt
    local activeRate, idleRate = GetPerformanceRates()

    -- Full discovery is event-driven and otherwise heavily throttled.
    if cooldownDataDirty or discoveryElapsed >= idleRate then
        cooldownDataDirty = false
        discoveryElapsed = 0
        DiscoverActions()
        DiscoverInventory()
        DiscoverBags()
        DiscoverBuffs()
    end

    -- Between discoveries, only slots with a known active cooldown are checked.
    if HasTrackedCooldowns() and activeElapsed >= activeRate then
        activeElapsed = 0
        TrackActions()
        TrackInventory()
        TrackBags()
        if next(buffState) then DiscoverBuffs() end
    elseif not HasTrackedCooldowns() then
        activeElapsed = 0
    end

    if cleanupElapsed >= 3 then
        cleanupElapsed = 0
        CleanupRecent(now)
    end

    UpdatePulse(dt)
end)

DCP:RegisterEvent("ADDON_LOADED")
DCP:RegisterEvent("PLAYER_DEAD")
DCP:RegisterEvent("PLAYER_ALIVE")
DCP:RegisterEvent("PLAYER_UNGHOST")
DCP:RegisterEvent("PLAYER_ENTERING_WORLD")
DCP:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
DCP:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
DCP:RegisterEvent("BAG_UPDATE")
DCP:RegisterEvent("BAG_UPDATE_COOLDOWN")
DCP:RegisterEvent("UNIT_INVENTORY_CHANGED")
DCP:RegisterEvent("PLAYER_AURAS_CHANGED")
DCP:SetScript("OnEvent", function()
    if event == "PLAYER_DEAD" then
        ClearCooldownStates()
        return
    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        ClearCooldownStates()
        activeElapsed, discoveryElapsed = 0, 0
        suppressUntil = GetTime() + 0.75
        cooldownDataDirty = true
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        ClearCooldownStates()
        activeElapsed, discoveryElapsed = 0, 0
        suppressUntil = GetTime() + 1.5
        cooldownDataDirty = true
        return
    elseif event == "ACTIONBAR_UPDATE_COOLDOWN" or event == "ACTIONBAR_SLOT_CHANGED" or event == "BAG_UPDATE" or event == "BAG_UPDATE_COOLDOWN" or event == "PLAYER_AURAS_CHANGED" or (event == "UNIT_INVENTORY_CHANGED" and arg1 == "player") then
        cooldownDataDirty = true
        return
    elseif event == "ADDON_LOADED" and arg1 == "PulseCore" then
        local hadTemporarySetting = DCP_Saved and DCP_Saved.ignoreTemporaryCombatBuffs ~= nil
        DCP_Saved = CopyDefaults(defaults, DCP_Saved)
        DCP_SavedPerCharacter = CopyDefaults(charDefaults, DCP_SavedPerCharacter)
        if not hadTemporarySetting then
            DCP_Saved.ignoreTemporaryCombatBuffs = DCP_Saved.ignoreHealingOverTime ~= false
        end
        -- Migrate the former fixed 10-minute threshold. Persistent Turtle buffs
        -- such as Felstone can now be tracked from two minutes upward, while
        -- short combat procs remain excluded by the separate temporary filter.
        if not DCP_Saved.autoBuffMinRemaining or DCP_Saved.autoBuffMinRemaining >= 600 then
            DCP_Saved.autoBuffMinRemaining = 120
        end
        DCP_SavedPerCharacter.invertBuffFilter = true
        DCP_SavedPerCharacter.buffBlacklist = DCP_SavedPerCharacter.buffBlacklist or ""
        DCP_Saved.enableBuffBlacklist = true
        RefreshFilters()
        RefreshBuffFilters()
        PositionFrame()
        ResetPulseVisual()
        CreateMinimapButton()
        DCP:UnregisterEvent("ADDON_LOADED")
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99PulseCore|r |cffffffff" .. VERSION .. " loaded|r — raid performance mode active — /pc")
    end
end)

local function MakeSlider(parent, name, title, y, minimum, maximum, step, key)
    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetPoint("TOP", parent, "TOP", 0, y)
    slider:SetMinMaxValues(minimum, maximum)
    slider:SetValueStep(step)
    slider:SetValue(DCP_Saved[key])
    getglobal(name .. "Text"):SetText(title .. ": " .. math.floor(DCP_Saved[key] + 0.5))
    getglobal(name .. "Low"):SetText(minimum)
    getglobal(name .. "High"):SetText(maximum)
    slider:SetScript("OnValueChanged", function()
        local value = this:GetValue()
        DCP_Saved[key] = value
        getglobal(name .. "Text"):SetText(title .. ": " .. math.floor(value + 0.5))
        if unlocked then
            DCP:SetWidth(value)
            DCP:SetHeight(value)
        end
    end)
    return slider
end

local function MakeDurationSlider(parent, y)
    local name = "DCPDurationSlider"
    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetPoint("TOP", parent, "TOP", 0, y)
    slider:SetMinMaxValues(0.3, 3.0)
    slider:SetValueStep(0.1)
    slider:SetValue(DCP_Saved.pulseDuration or 0.85)
    getglobal(name .. "Text"):SetText(string.format("Pulse Duration: %.1f seconds", DCP_Saved.pulseDuration or 0.85))
    getglobal(name .. "Low"):SetText("0.3")
    getglobal(name .. "High"):SetText("3.0")
    slider:SetScript("OnValueChanged", function()
        local value = math.floor((this:GetValue() * 10) + 0.5) / 10
        DCP_Saved.pulseDuration = value
        getglobal(name .. "Text"):SetText(string.format("Pulse Duration: %.1f seconds", value))
    end)
    return slider
end

local function SetUnlocked(state)
    unlocked = state and true or false
    if unlocked then
        currentPulse = nil
        pulses = {}
        pulseHead, pulseTail = 1, 0
        DCP:EnableMouse(true)
        DCP:SetAlpha(1)
        DCP:SetWidth(DCP_Saved.iconSize)
        DCP:SetHeight(DCP_Saved.iconSize)
        icon:SetTexture(TEST_ICON)
        text:SetText(DCP_Saved.showSpellName and "Drag to reposition" or "")
        if DCPUnlockButton then DCPUnlockButton:SetText("Lock Position") end
    else
        DCP:EnableMouse(false)
        if DCPUnlockButton then DCPUnlockButton:SetText("Unlock Position") end
        ResetPulseVisual()
    end
end

local function ParseNameList(value)
    local result = {}
    local seen = {}
    value = value or ""
    for entry in string.gfind(value .. ",", "(.-),") do
        entry = Trim(entry)
        local key = string.lower(entry)
        if entry ~= "" and not seen[key] then
            table.insert(result, entry)
            seen[key] = true
        end
    end
    table.sort(result, function(a, b) return string.lower(a) < string.lower(b) end)
    return result
end

local function SerializeNameList(entries)
    return table.concat(entries, ", ")
end

local function CreateNameListEditor(parent, globalName, titleText, hintText, x, y, width, height, getValue, setValue, onChanged)
    local editor = CreateFrame("Frame", globalName, parent)
    editor:SetWidth(width)
    editor:SetHeight(height)
    editor:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local title = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, 0)
    title:SetText(titleText)

    local hint = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    hint:SetWidth(width)
    hint:SetJustifyH("LEFT")
    hint:SetText(hintText or "")

    local listBox = CreateFrame("Frame", nil, editor)
    listBox:SetWidth(width)
    listBox:SetHeight(height - 63)
    listBox:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, -34)
    listBox:SetBackdrop({bgFile="Interface\\ChatFrame\\ChatFrameBackground", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=12, insets={left=3,right=3,top=3,bottom=3}})
    listBox:SetBackdropColor(0, 0, 0, 0.75)

    editor.entries = {}
    editor.selected = nil
    editor.offset = 0
    editor.rows = {}
    editor.visibleRows = math.max(2, math.floor((height - 69) / 18))

    local rowWidth = width - 30
    local i
    for i = 1, editor.visibleRows do
        local row = CreateFrame("Button", nil, listBox)
        row:SetWidth(rowWidth)
        row:SetHeight(18)
        row:SetPoint("TOPLEFT", listBox, "TOPLEFT", 7, -5 - ((i - 1) * 18))
        row:SetID(i)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row, "LEFT", 3, 0)
        row.text:SetWidth(rowWidth - 6)
        row.text:SetJustifyH("LEFT")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row:SetScript("OnClick", function()
            local index = editor.offset + this:GetID()
            if editor.entries[index] then
                editor.selected = index
                editor:RefreshRows()
            end
        end)
        editor.rows[i] = row
    end

    local up = CreateFrame("Button", nil, listBox, "UIPanelScrollUpButtonTemplate")
    up:SetPoint("TOPRIGHT", listBox, "TOPRIGHT", -4, -5)
    up:SetScript("OnClick", function()
        if editor.offset > 0 then
            editor.offset = editor.offset - 1
            editor:RefreshRows()
        end
    end)

    local down = CreateFrame("Button", nil, listBox, "UIPanelScrollDownButtonTemplate")
    down:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -4, 5)
    down:SetScript("OnClick", function()
        local maximum = math.max(0, table.getn(editor.entries) - editor.visibleRows)
        if editor.offset < maximum then
            editor.offset = editor.offset + 1
            editor:RefreshRows()
        end
    end)

    local input = CreateFrame("EditBox", nil, editor)
    input:SetWidth(width - 158)
    input:SetHeight(22)
    input:SetPoint("BOTTOMLEFT", editor, "BOTTOMLEFT", 4, 0)
    input:SetAutoFocus(false)
    input:SetFontObject(GameFontHighlightSmall)
    input:SetBackdrop({bgFile="Interface\\ChatFrame\\ChatFrameBackground", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=10, insets={left=3,right=3,top=3,bottom=3}})
    input:SetBackdropColor(0, 0, 0, 0.8)
    input:SetTextInsets(5, 5, 0, 0)
    input:SetScript("OnEscapePressed", function() this:ClearFocus() end)

    local add = CreateFrame("Button", nil, editor, "UIPanelButtonTemplate")
    add:SetWidth(68)
    add:SetHeight(22)
    add:SetPoint("LEFT", input, "RIGHT", 5, 0)
    add:SetText("Add")

    local remove = CreateFrame("Button", nil, editor, "UIPanelButtonTemplate")
    remove:SetWidth(70)
    remove:SetHeight(22)
    remove:SetPoint("LEFT", add, "RIGHT", 5, 0)
    remove:SetText("Remove")

    function editor:Save()
        setValue(SerializeNameList(self.entries))
        if onChanged then onChanged() end
    end

    function editor:RefreshRows()
        local count = table.getn(self.entries)
        local maximum = math.max(0, count - self.visibleRows)
        if self.offset > maximum then self.offset = maximum end
        local r
        for r = 1, self.visibleRows do
            local index = self.offset + r
            local row = self.rows[r]
            if self.entries[index] then
                row.text:SetText(self.entries[index])
                row:Show()
                if self.selected == index then
                    row:LockHighlight()
                else
                    row:UnlockHighlight()
                end
            else
                row.text:SetText("")
                row:UnlockHighlight()
                row:Hide()
            end
        end
        if self.offset > 0 then up:Enable() else up:Disable() end
        if self.offset < maximum then down:Enable() else down:Disable() end
        if self.selected and self.entries[self.selected] then remove:Enable() else remove:Disable() end
    end

    function editor:Reload()
        self.entries = ParseNameList(getValue())
        self.selected = nil
        self.offset = 0
        input:SetText("")
        self:RefreshRows()
    end

    local function AddEntry()
        local value = Trim(input:GetText())
        if value == "" then return end
        local key = string.lower(value)
        local found = false
        local n
        for n = 1, table.getn(editor.entries) do
            if string.lower(editor.entries[n]) == key then found = true break end
        end
        if not found then
            table.insert(editor.entries, value)
            table.sort(editor.entries, function(a, b) return string.lower(a) < string.lower(b) end)
            editor:Save()
        end
        input:SetText("")
        input:ClearFocus()
        editor:RefreshRows()
    end

    add:SetScript("OnClick", AddEntry)
    input:SetScript("OnEnterPressed", AddEntry)
    remove:SetScript("OnClick", function()
        if editor.selected and editor.entries[editor.selected] then
            table.remove(editor.entries, editor.selected)
            editor.selected = nil
            editor:Save()
            editor:RefreshRows()
        end
    end)

    editor:Reload()
    return editor
end

function DCP:CreateOptions()
    if DCPOptions then
        DCPSizeSlider:SetValue(DCP_Saved.iconSize)
        DCPDurationSlider:SetValue(DCP_Saved.pulseDuration or 0.85)
        DCPNameCheckButton:SetChecked(DCP_Saved.showSpellName and 1 or nil)
        DCPBuffCheckButton:SetChecked(DCP_Saved.showBuffExpirations and 1 or nil)
        DCPAutoLongBuffCheckButton:SetChecked(DCP_Saved.autoLongBuffs and 1 or nil)
        DCPIgnoreHoTCheckButton:SetChecked(DCP_Saved.ignoreTemporaryCombatBuffs and 1 or nil)
        if DCPCooldownListEditor then DCPCooldownListEditor:Reload() end
        if DCPAdditionalBuffListEditor then DCPAdditionalBuffListEditor:Reload() end
        if DCPBuffBlacklistListEditor then DCPBuffBlacklistListEditor:Reload() end
        DCPOptions:Show()
        return
    end

    local frame = CreateFrame("Frame", "DCPOptions", UIParent)
    frame:SetWidth(430)
    frame:SetHeight(575)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() this:StartMoving() end)
    frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    frame:SetScript("OnHide", function() if unlocked then SetUnlocked(false) end end)
    frame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32, edgeSize=32, insets={left=11,right=12,top=12,bottom=11}})
    table.insert(UISpecialFrames, "DCPOptions")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -17)
    title:SetText("PulseCore")

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOP", frame, "TOP", 0, -41)
    subtitle:SetText("Lightweight cooldown and buff expiration alerts")

    local pages, tabs = {}, {}
    local function SelectTab(index)
        local n
        for n = 1, 3 do
            if n == index then pages[n]:Show(); tabs[n]:Disable() else pages[n]:Hide(); tabs[n]:Enable() end
        end
    end

    local tabNames = {"Display", "Cooldowns", "Buffs"}
    local i
    for i = 1, 3 do
        local tab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        tab:SetWidth(112); tab:SetHeight(24)
        tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 39 + ((i - 1) * 117), -66)
        tab:SetText(tabNames[i]); tab.pageIndex = i
        tab:SetScript("OnClick", function() SelectTab(this.pageIndex) end)
        tabs[i] = tab
        local page = CreateFrame("Frame", nil, frame)
        page:SetWidth(380); page:SetHeight(405)
        page:SetPoint("TOPLEFT", frame, "TOPLEFT", 25, -98)
        pages[i] = page
    end

    local displayPage = pages[1]
    local displayTitle = displayPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    displayTitle:SetPoint("TOPLEFT", displayPage, "TOPLEFT", 10, -8)
    displayTitle:SetText("Display")
    MakeSlider(displayPage, "DCPSizeSlider", "Icon Size", -55, 30, 160, 5, "iconSize")
    MakeDurationSlider(displayPage, -118)

    local nameCheck = CreateFrame("CheckButton", "DCPNameCheckButton", displayPage, "UICheckButtonTemplate")
    nameCheck:SetWidth(24); nameCheck:SetHeight(24)
    nameCheck:SetPoint("TOPLEFT", displayPage, "TOPLEFT", 21, -160)
    nameCheck:SetChecked(DCP_Saved.showSpellName and 1 or nil)
    nameCheck:SetScript("OnClick", function()
        DCP_Saved.showSpellName = this:GetChecked() and true or false
        if unlocked then text:SetText(DCP_Saved.showSpellName and "Drag to reposition" or "") end
    end)
    local nameText = displayPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameText:SetPoint("LEFT", nameCheck, "RIGHT", 3, 0)
    nameText:SetText("Show name below the icon")

    local displayHint = displayPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    displayHint:SetPoint("TOPLEFT", nameCheck, "BOTTOMLEFT", 2, -7)
    displayHint:SetText("Test and position controls are always available below.")

    local cooldownPage = pages[2]
    local cooldownTitle = cooldownPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cooldownTitle:SetPoint("TOPLEFT", cooldownPage, "TOPLEFT", 10, -8)
    cooldownTitle:SetText("Cooldown Filter")

    local modeText = cooldownPage:CreateFontString("DCPFilterModeText", "OVERLAY", "GameFontHighlight")
    modeText:SetPoint("TOPLEFT", cooldownPage, "TOPLEFT", 18, -42)
    local modeButton = CreateFrame("Button", "DCPFilterModeButton", cooldownPage, "UIPanelButtonTemplate")
    modeButton:SetWidth(145); modeButton:SetHeight(23)
    modeButton:SetPoint("TOPRIGHT", cooldownPage, "TOPRIGHT", -18, -35)
    local function UpdateFilterModeText()
        if DCP_SavedPerCharacter.invertIgnored then
            modeText:SetText("Only show listed cooldowns")
            modeButton:SetText("Only Show Listed")
        else
            modeText:SetText("Ignore listed cooldowns")
            modeButton:SetText("Ignore Listed")
        end
    end
    modeButton:SetScript("OnClick", function()
        DCP_SavedPerCharacter.invertIgnored = not DCP_SavedPerCharacter.invertIgnored
        UpdateFilterModeText()
    end)
    UpdateFilterModeText()

    CreateNameListEditor(cooldownPage, "DCPCooldownListEditor", "Cooldown List", "Entries are shown or ignored depending on the selected filter mode.", 18, -78, 344, 225,
        function() return DCP_SavedPerCharacter.ignoredSpells or "" end,
        function(value) DCP_SavedPerCharacter.ignoredSpells = value end,
        function() RefreshFilters() end)

    local cdHint = cooldownPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cdHint:SetPoint("TOPLEFT", cooldownPage, "TOPLEFT", 18, -322)
    cdHint:SetWidth(344); cdHint:SetJustifyH("LEFT")
    cdHint:SetText("Only genuine cooldowns triggered by you are tracked. Knockbacks and temporary global lockouts are ignored.")

    local buffPage = pages[3]
    local buffTitle = buffPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    buffTitle:SetPoint("TOPLEFT", buffPage, "TOPLEFT", 10, -8)
    buffTitle:SetText("Buff Expiration")

    local buffCheck = CreateFrame("CheckButton", "DCPBuffCheckButton", buffPage, "UICheckButtonTemplate")
    buffCheck:SetWidth(24); buffCheck:SetHeight(24)
    buffCheck:SetPoint("TOPLEFT", buffPage, "TOPLEFT", 16, -30)
    buffCheck:SetChecked(DCP_Saved.showBuffExpirations and 1 or nil)
    buffCheck:SetScript("OnClick", function()
        DCP_Saved.showBuffExpirations = this:GetChecked() and true or false
        buffState = {}; buffMeta = {}; cooldownDataDirty = true
    end)
    local buffText = buffPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    buffText:SetPoint("LEFT", buffCheck, "RIGHT", 3, 0)
    buffText:SetText("Enable Buff Pulse")

    local autoCheck = CreateFrame("CheckButton", "DCPAutoLongBuffCheckButton", buffPage, "UICheckButtonTemplate")
    autoCheck:SetWidth(24); autoCheck:SetHeight(24)
    autoCheck:SetPoint("TOPLEFT", buffPage, "TOPLEFT", 16, -58)
    autoCheck:SetChecked(DCP_Saved.autoLongBuffs and 1 or nil)
    autoCheck:SetScript("OnClick", function()
        DCP_Saved.autoLongBuffs = this:GetChecked() and true or false
        buffState = {}; buffMeta = {}; cooldownDataDirty = true
    end)
    local autoText = buffPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    autoText:SetPoint("LEFT", autoCheck, "RIGHT", 3, 0)
    autoText:SetText("Track Long-Duration Buffs Automatically")

    local hotCheck = CreateFrame("CheckButton", "DCPIgnoreHoTCheckButton", buffPage, "UICheckButtonTemplate")
    hotCheck:SetWidth(24); hotCheck:SetHeight(24)
    hotCheck:SetPoint("TOPLEFT", buffPage, "TOPLEFT", 16, -86)
    hotCheck:SetChecked(DCP_Saved.ignoreTemporaryCombatBuffs and 1 or nil)
    hotCheck:SetScript("OnClick", function()
        DCP_Saved.ignoreTemporaryCombatBuffs = this:GetChecked() and true or false
        DCP_Saved.ignoreHealingOverTime = DCP_Saved.ignoreTemporaryCombatBuffs
        buffState = {}; buffMeta = {}; cooldownDataDirty = true
    end)
    local hotText = buffPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hotText:SetPoint("LEFT", hotCheck, "RIGHT", 3, 0)
    hotText:SetText("Ignore Temporary Combat Buffs")

    CreateNameListEditor(buffPage, "DCPAdditionalBuffListEditor", "Additional Buffs", "Track these in addition to automatically detected long-duration buffs.", 18, -126, 344, 128,
        function() return DCP_SavedPerCharacter.buffFilterList or "" end,
        function(value) DCP_SavedPerCharacter.buffFilterList = value end,
        function() RefreshBuffFilters(); buffState = {}; buffMeta = {}; cooldownDataDirty = true end)

    CreateNameListEditor(buffPage, "DCPBuffBlacklistListEditor", "Buff Blacklist", "These buffs never trigger a pulse.", 18, -270, 344, 128,
        function() return DCP_SavedPerCharacter.buffBlacklist or "" end,
        function(value) DCP_SavedPerCharacter.buffBlacklist = value end,
        function() DCP_Saved.enableBuffBlacklist = true; RefreshBuffFilters(); buffState = {}; buffMeta = {}; cooldownDataDirty = true end)

    local test = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    test:SetWidth(75); test:SetHeight(24)
    test:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 25, 24)
    test:SetText("Test Pulse")
    test:SetScript("OnClick", function()
        if unlocked then SetUnlocked(false) end
        QueuePulse(TEST_ICON, "Cooldown Ready")
    end)

    local unlock = CreateFrame("Button", "DCPUnlockButton", frame, "UIPanelButtonTemplate")
    unlock:SetWidth(130); unlock:SetHeight(24)
    unlock:SetPoint("LEFT", test, "RIGHT", 10, 0)
    unlock:SetText("Unlock Position")
    unlock:SetScript("OnClick", function() SetUnlocked(not unlocked) end)

    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetWidth(75); close:SetHeight(24)
    close:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -25, 24)
    close:SetText("Close")
    close:SetScript("OnClick", function() frame:Hide() end)

    SelectTab(1)
    frame:Show()
end


CreateMinimapButton = function()
    if minimapButton then return end
    minimapButton = CreateFrame("Button", "DCPMinimapButton", Minimap)
    minimapButton:SetWidth(31)
    minimapButton:SetHeight(31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(54)
    border:SetHeight(54)
    border:SetPoint("TOPLEFT", minimapButton, "TOPLEFT", 0, 0)

    local background = minimapButton:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetWidth(20)
    background:SetHeight(20)
    background:SetPoint("CENTER", minimapButton, "CENTER", 0, 1)

    local buttonIcon = minimapButton:CreateTexture(nil, "ARTWORK")
    buttonIcon:SetTexture(TEST_ICON)
    buttonIcon:SetWidth(20)
    buttonIcon:SetHeight(20)
    buttonIcon:SetPoint("CENTER", minimapButton, "CENTER", 0, 1)
    buttonIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    minimapButton:SetScript("OnClick", function()
        DCP:CreateOptions()
    end)
    minimapButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("PulseCore")
        GameTooltip:AddLine("Left-click: Open Settings", 1, 1, 1)
        GameTooltip:AddLine("Drag: Move Minimap Icon", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    minimapButton:SetScript("OnDragStart", function()
        this:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            DCP_Saved.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            UpdateMinimapButtonPosition()
        end)
    end)
    minimapButton:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
    end)

    UpdateMinimapButtonPosition()
    if DCP_Saved.minimapHidden then minimapButton:Hide() end
end

local function PrintHelp()
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99PulseCore commands:|r")
    DEFAULT_CHAT_FRAME:AddMessage("/pc - Settings, /pc test, /pc reset")
    DEFAULT_CHAT_FRAME:AddMessage("/pc ignore NAME - Add a name to the cooldown filter")
    DEFAULT_CHAT_FRAME:AddMessage("/pc clear - Clear cooldown filter, /pc invert - Toggle filter mode")
    DEFAULT_CHAT_FRAME:AddMessage("/pc list - Show the current cooldown filter")
end

SLASH_PULSECORE1 = "/pc"
SLASH_PULSECORE2 = "/pulsecore"
SLASH_PULSECORE3 = "/dcp"
SlashCmdList["PULSECORE"] = function(message)
    local original = Trim(message or "")
    local lower = string.lower(original)
    if lower == "test" then
        QueuePulse(TEST_ICON, "Cooldown ready")
    elseif lower == "reset" then
        DCP_Saved = CopyDefaults(defaults, {})
        DCP_SavedPerCharacter = CopyDefaults(charDefaults, {})
        -- Migrate the former fixed 10-minute threshold. Persistent Turtle buffs
        -- such as Felstone can now be tracked from two minutes upward, while
        -- short combat procs remain excluded by the separate temporary filter.
        if not DCP_Saved.autoBuffMinRemaining or DCP_Saved.autoBuffMinRemaining >= 600 then
            DCP_Saved.autoBuffMinRemaining = 120
        end
        DCP_SavedPerCharacter.invertBuffFilter = true
        DCP_SavedPerCharacter.buffBlacklist = DCP_SavedPerCharacter.buffBlacklist or ""
        RefreshFilters(); RefreshBuffFilters(); PositionFrame(); ResetPulseVisual()
        DEFAULT_CHAT_FRAME:AddMessage("PulseCore settings reset.")
    elseif lower == "clear" then
        DCP_SavedPerCharacter.ignoredSpells = ""; RefreshFilters()
        DEFAULT_CHAT_FRAME:AddMessage("PulseCore cooldown filter cleared.")
    elseif lower == "invert" then
        DCP_SavedPerCharacter.invertIgnored = not DCP_SavedPerCharacter.invertIgnored
        DEFAULT_CHAT_FRAME:AddMessage("PulseCore only-show-listed mode: " .. (DCP_SavedPerCharacter.invertIgnored and "ON" or "OFF"))
    elseif lower == "list" then
        DEFAULT_CHAT_FRAME:AddMessage("PulseCore cooldown filter: " .. (DCP_SavedPerCharacter.ignoredSpells ~= "" and DCP_SavedPerCharacter.ignoredSpells or "empty"))
    elseif lower == "help" then
        PrintHelp()
    elseif string.sub(lower, 1, 7) == "ignore " then
        local spell = Trim(string.sub(original, 8))
        if spell ~= "" then
            if DCP_SavedPerCharacter.ignoredSpells ~= "" then
                DCP_SavedPerCharacter.ignoredSpells = DCP_SavedPerCharacter.ignoredSpells .. ", " .. spell
            else
                DCP_SavedPerCharacter.ignoredSpells = spell
            end
            RefreshFilters()
            DEFAULT_CHAT_FRAME:AddMessage("PulseCore added: " .. spell)
        end
    elseif lower == "" then
        DCP:CreateOptions()
    else
        PrintHelp()
    end
end
