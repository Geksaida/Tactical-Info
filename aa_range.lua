function widget:GetInfo()
    return {
        name = "AARangePoC",
        desc = "AA range overlay plus response-time-aware tactical group evaluation.",
        author = "PoC",
        date = "2026-08-30",
        license = "GPLv2",
        layer = 0,
        enabled = true,
    }
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local FILL_ALPHA = 0.16
local SEGMENTS = 32
local ENEMY_COLOR = { 1.0, 0.55, 0.0 } -- orange
local ALLY_COLOR  = { 0.25, 0.65, 1.0 } -- blue

local ANTI_NUKE_LINE_COLOR = { 1.0, 1.0, 1.0 } -- white
local ANTI_NUKE_OUTLINE_WIDTH = 3.0
local ANTI_NUKE_HATCH_ALPHA = 0.2
local ANTI_NUKE_HATCH_WIDTH = 3
local ANTI_NUKE_HATCH_SPACING = 60
local ANTI_NUKE_HATCH_ORIGIN_X = 0
local ANTI_NUKE_HATCH_ORIGIN_Z = 0
local ANTI_NUKE_RANGE = 2000

local SHOW_ALLY_BY_DEFAULT = false
local COMBINE_BY_DEFAULT = false

-- Tactical group analysis. Power combines weapon DPS and durability, then is
-- adjusted by current health.
-- the response samples decide how much of that value can actually join a fight.
local SHOW_TACTICAL_BY_DEFAULT = false
local TACTICAL_UPDATE_INTERVAL = 1.0
local TACTICAL_MEMORY_TTL = 30
local TACTICAL_RESPONSE_TIME = 5.0
local TACTICAL_LINK_RESPONSE_TIME = 4.0
local TACTICAL_MIN_LINK = 320
local TACTICAL_MAX_LINK = 1400
local TACTICAL_GRID_SIZE = 512
local TACTICAL_EDGE_OFFSET = 80
local TACTICAL_DIRECTIONS = 8
local TACTICAL_MIN_GROUP_SIZE = 5
local TACTICAL_MIN_UNIT_METAL = 80
local TACTICAL_LATE_GAME_UNIT_METAL = 200
local TACTICAL_LATE_GAME_GROUP_UNITS = 4
local TACTICAL_LATE_GAME_GROUP_COUNT = 3
local TACTICAL_CENTER_MIN_REACH = 420
local TACTICAL_CENTER_MAX_REACH = 850
local TACTICAL_CENTER_SPLIT_ITERATIONS = 6
local TACTICAL_HULL_PADDING = 55
local TACTICAL_HULL_ROUNDING_POINTS = 8
local TACTICAL_ENEMY_HULL_ROUNDING_POINTS = 4
local TACTICAL_UNIT_SMOOTHING = 0.45
local TACTICAL_WEAK_HYSTERESIS = 1.12
local TACTICAL_HULL_LINE_WIDTH = 2.0
local TACTICAL_WEAK_LINE_WIDTH = 5.0
local TACTICAL_LABEL_FONT_SIZE = 13
local TACTICAL_LABEL_HEIGHT = 23
local TACTICAL_LABEL_GAP = 4
local TACTICAL_MAX_LABELS_NEAR = 24
local TACTICAL_MAX_LABELS_MID = 14
local TACTICAL_MAX_LABELS_FAR = 8
local TACTICAL_ALLY_COLOR = { 0.25, 0.85, 1.0 }
local TACTICAL_ENEMY_COLOR = { 1.0, 0.38, 0.15 }

local UPDATE_INTERVAL = 0.2 -- how often to rescan visible units (seconds, real time)
local MEMORY_TTL = 3000      -- seconds a circle survives without being re-sighted or LOS-checked
local DEAD_BLACKLIST_TTL = 30 -- seconds a destroyed unitID stays blocked from re-entry

-- Anti-nuke (ABM / missile-defense) unit def names — enemy only
local ANTI_NUKE_NAMES = {
    armamd  = true,
    armscab = true,
    corfmd  = true,
    cormabm = true,
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local showAll = false                        -- master toggle (enemy circles)
local showAlly = SHOW_ALLY_BY_DEFAULT        -- additionally draw own/allied AA
local combineOverlap = COMBINE_BY_DEFAULT    -- union overlapping circles instead of stacking alpha
local showTactical = SHOW_TACTICAL_BY_DEFAULT

local aaRangeByDef = {}
local combatInfoByDef = {}
local cacheBuilt = false

local dKey = nil
local gKey = nil

local trackedUnits = {}   -- uid -> { defID, x, y, z, lastSeen, isAlly }
local antiNukeUnits = {}  -- uid -> { defID, x, y, z, lastSeen }  (enemy only)
local tacticalUnits = {}  -- uid -> combat unit snapshot (visible/last known)
local tacticalGroups = {} -- response-time-aware connected components
local deadUnits = {}      -- uid -> gameTime of death (blocks the death-sequence re-add race)

local myAllyTeam = Spring.GetMyAllyTeamID()

local uiClock = 0         -- accumulated real time, used for toggle debounce
local lastToggleClock = -1
local lastAllyToggleClock = -1
local lastCombineToggleClock = -1
local lastTacticalToggleClock = -1
local sinceUpdate = 0
local sinceTacticalUpdate = 0

local hasPosInLos = type(Spring.IsPosInLos) == "function"

-- Stencil-based union drawing needs these three entry points. Some very old
-- engine builds may not expose them; detect once and fall back gracefully
-- instead of silently drawing nothing.
local hasStencilSupport = type(gl.StencilTest) == "function"
    and type(gl.StencilFunc) == "function"
    and type(gl.StencilOp) == "function"
    and type(gl.StencilMask) == "function"

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function Toggle()
    if uiClock - lastToggleClock < 0.25 then return end
    lastToggleClock = uiClock
    showAll = not showAll
    Spring.Echo("[AARangePoC] AA ranges: " .. (showAll and "ON" or "OFF"))
end

local function ToggleAlly()
    if uiClock - lastAllyToggleClock < 0.25 then return end
    lastAllyToggleClock = uiClock
    showAlly = not showAlly
    Spring.Echo("[AARangePoC] Ally AA ranges: " .. (showAlly and "ON" or "OFF"))
end

local function ToggleCombine()
    if uiClock - lastCombineToggleClock < 0.25 then return end
    lastCombineToggleClock = uiClock
    if not hasStencilSupport then
        Spring.Echo("[AARangePoC] Combine mode needs stencil buffer support, which this engine build doesn't expose. Staying in overlap mode.")
        return
    end
    combineOverlap = not combineOverlap
    Spring.Echo("[AARangePoC] Combine overlapping circles: " .. (combineOverlap and "ON" or "OFF"))
end

local function ToggleTactical()
    if uiClock - lastTacticalToggleClock < 0.25 then return end
    lastTacticalToggleClock = uiClock
    showTactical = not showTactical
    if showTactical then
        sinceTacticalUpdate = TACTICAL_UPDATE_INTERVAL
    else
        tacticalUnits = {}
        tacticalGroups = {}
    end
    Spring.Echo("[AARangePoC] Tactical group evaluation: " .. (showTactical and "ON" or "OFF"))
end

local function ClearMemory()
    local count = 0
    for _ in pairs(trackedUnits) do count = count + 1 end
    for _ in pairs(antiNukeUnits) do count = count + 1 end
    for _ in pairs(tacticalUnits) do count = count + 1 end
    trackedUnits = {}
    antiNukeUnits = {}
    tacticalUnits = {}
    tacticalGroups = {}
    Spring.Echo("[AARangePoC] Cleared " .. count .. " remembered unit(s).")
end

--------------------------------------------------------------------------------
-- AA detection (heuristics over UnitDefs / WeaponDefs)
--------------------------------------------------------------------------------

local function lower(s)
    return s and tostring(s):lower() or ""
end

local function StringContainsAny(s, patterns)
    if type(s) ~= "string" then return false end
    local t = lower(s)
    for _, p in ipairs(patterns) do
        if t:find(p, 1, true) then return true end
    end
    return false
end

local function StringHasTrueAA(s)
    if type(s) ~= "string" then return false end
    local t = lower(s)
    if t:find("anti air") or t:find("anti%-air") or t:find("antiair") or t:find("anti_air")
        or t:find("air defense") or t:find("airdefense") or t:find("air%-defense") or t:find("flak") then
        return true
    end
    if t == "aa" then return true end
    if t:find("^aa") or t:find("aa$") or t:find(" aa") or t:find("aa ")
        or t:find("_aa") or t:find("aa_") or t:find("%-aa") or t:find("aa%-") then
        return true
    end
    return false
end

local function CategoryHasTrueAA(v, depth)
    depth = depth or 0
    if depth > 3 then return false end
    if type(v) == "string" then
        return StringHasTrueAA(v)
    elseif type(v) == "table" then
        for k, val in pairs(v) do
            if CategoryHasTrueAA(k, depth + 1) or CategoryHasTrueAA(val, depth + 1) then return true end
        end
    end
    return false
end

local function CategoryContainsAny(v, patterns, depth)
    depth = depth or 0
    if depth > 3 then return false end
    if type(v) == "string" then
        return StringContainsAny(v, patterns)
    elseif type(v) == "table" then
        for k, val in pairs(v) do
            if CategoryContainsAny(k, patterns, depth + 1) or CategoryContainsAny(val, patterns, depth + 1) then return true end
        end
    end
    return false
end

local excludeCategoryPatterns = { "commander", "construction", "builder", "factory", "nanotower", "resurrector" }

local function UnitIsExcluded(def)
    if not def then return true end
    if def.canAttack == false then return true end
    if def.isAirUnit or def.canFly then return true end
    if def.isCommander then return true end
    if def.isBuilder or def.builder then return true end
    if def.isFactory or def.isBuildingFactory then return true end
    if CategoryContainsAny(def.category, excludeCategoryPatterns) then return true end
    local cp = def.customParams
    if cp then
        if CategoryContainsAny(cp.category, excludeCategoryPatterns)
            or CategoryContainsAny(cp.role, excludeCategoryPatterns)
            or CategoryContainsAny(cp.unitclass, excludeCategoryPatterns) then return true end
        if cp.iscommander == "1" or cp.is_commander == "1" then return true end
        if cp.isbuilder == "1" or cp.is_builder == "1" or cp.isconstruction == "1" then return true end
    end
    return false
end

local function UnitHasAACategory(def)
    if CategoryHasTrueAA(def.category) then return true end
    local cp = def.customParams
    if cp then
        if CategoryHasTrueAA(cp.category) or CategoryHasTrueAA(cp.role)
            or CategoryHasTrueAA(cp.unitclass) or CategoryHasTrueAA(cp.weaponclass) then return true end
        if cp.isairdefense == "1" or cp.is_air_defense == "1" or cp.airdefense == "1" or cp.aa == "1" then return true end
    end
    return false
end

local function UnitTextLooksLikeTrueAA(def)
    if StringHasTrueAA(def.name) or StringHasTrueAA(def.humanName) or StringHasTrueAA(def.tooltip) then return true end
    local cp = def.customParams
    if cp then
        if StringHasTrueAA(cp.description) or StringHasTrueAA(cp.role)
            or StringHasTrueAA(cp.unitclass) or StringHasTrueAA(cp.weaponclass) then return true end
    end
    return false
end

local function TargetStringHasAir(s)
    if type(s) ~= "string" then return false end
    local t = lower(s)
    return t:find("air") ~= nil or t:find("vtol") ~= nil or t:find("fly") ~= nil or t:find("aircraft") ~= nil
end

local function TargetSpecHasAir(t)
    if type(t) == "string" then
        return TargetStringHasAir(t)
    elseif type(t) == "table" then
        if t.air or t.Air or t.AIR or t.vtol or t.VTOL then return true end
        for k, v in pairs(t) do
            if type(k) == "string" and TargetStringHasAir(k) then return true end
            if type(v) == "string" and TargetStringHasAir(v) then return true end
            if type(v) == "table" and (v.air or v.Air or v.AIR or v.vtol or v.VTOL) then return true end
        end
    end
    return false
end

local function WeaponAirTargetInfo(wd, uw)
    local canAir, onlyAir = false, false
    if uw then
        if TargetSpecHasAir(uw.onlyTargets) then canAir, onlyAir = true, true end
        if TargetSpecHasAir(uw.targets) then canAir = true end
    end
    if wd then
        if TargetSpecHasAir(wd.onlyTargets) then canAir, onlyAir = true, true end
        if TargetSpecHasAir(wd.targets) then canAir = true end
        if wd.canTargetAir == true or wd.canTargetAir == 1 then canAir = true end
        local cp = wd.customParams
        if cp then
            if TargetSpecHasAir(cp.onlyTargets) then canAir, onlyAir = true, true end
            if TargetSpecHasAir(cp.targets) then canAir = true end
            if cp.canTargetAir == "1" or cp.canTargetAir == "true" then canAir = true end
            if cp.isairdefense == "1" or cp.is_air_defense == "1" then canAir = true end
        end
    end
    return canAir, onlyAir
end

local function GetAARange(def)
    if not def then return false end
    if UnitIsExcluded(def) then return false end
    local anyWeaponRange = def.maxWeaponRange or 0
    local hasWeapon = anyWeaponRange > 0
    local canAirRange, onlyAirRange = 0, 0
    if def.weapons then
        for _, uw in pairs(def.weapons) do
            local wdID = uw.weaponDef or uw.id
            local wd = wdID and WeaponDefs[wdID] or nil
            local range = uw.range or (wd and wd.range) or 0
            if range > 0 then hasWeapon = true end
            if range > anyWeaponRange then anyWeaponRange = range end
            local canAir, onlyAir = WeaponAirTargetInfo(wd, uw)
            if canAir and range > canAirRange then canAirRange = range end
            if onlyAir and range > onlyAirRange then onlyAirRange = range end
        end
    end
    if not hasWeapon then return false end
    if onlyAirRange > 0 then return onlyAirRange end
    if UnitHasAACategory(def) or UnitTextLooksLikeTrueAA(def) then
        if canAirRange > 0 then return canAirRange end
        return anyWeaponRange
    end
    return false
end

local function GetWeaponDamage(wd)
    if not wd then return 0 end
    local damages = wd.damages or wd.damage
    if type(damages) == "number" then return damages end
    if type(damages) ~= "table" then return 0 end

    -- The engine commonly exposes the default armor damage at index 0. Fall
    -- back to the largest numeric entry for builds/mods using named keys.
    local defaultDamage = damages[0] or damages.default or damages.Default
    if type(defaultDamage) == "number" then return defaultDamage end
    local best = 0
    for _, damage in pairs(damages) do
        if type(damage) == "number" and damage > best then best = damage end
    end
    return best
end

local function GetCombatInfo(def)
    if not def or UnitIsExcluded(def) then return false end

    local metalCost = def.metalCost or def.buildCostMetal or 0

    local range, dps = 0, 0
    if def.weapons then
        for _, uw in pairs(def.weapons) do
            local wdID = uw.weaponDef or uw.id
            local wd = wdID and WeaponDefs[wdID] or nil
            local _, onlyAir = WeaponAirTargetInfo(wd, uw)
            if wd and not onlyAir then
                local weaponRange = uw.range or wd.range or 0
                local reload = wd.reload or wd.reloadTime or 1
                local salvo = wd.salvoSize or wd.projectiles or 1
                if weaponRange > range then range = weaponRange end
                if reload > 0 then
                    dps = dps + (GetWeaponDamage(wd) * math.max(1, salvo)) / reload
                end
            end
        end
    end
    if range <= 0 or dps <= 0 then return false end

    local maxHealth = def.health or def.maxDamage or 1
    -- This is deliberately a combat score rather than raw cost: damage output
    -- is tempered by durability. Matchup-specific scoring can later replace
    -- this scalar without changing the grouping/response model.
    local power = math.max(1, dps * math.sqrt(maxHealth / 1000))
    return {
        range = range,
        speed = math.max(0, def.speed or def.maxVelocity or 0),
        maxHealth = math.max(1, maxHealth),
        power = power,
        metalCost = metalCost,
    }
end

local function EnsureCache()
    if cacheBuilt then return end
    if not UnitDefs or not next(UnitDefs) then return end
    if not WeaponDefs or not next(WeaponDefs) then return end
    cacheBuilt = true
    local count = 0
    for defID, def in pairs(UnitDefs) do
        local range = GetAARange(def)
        aaRangeByDef[defID] = range
        combatInfoByDef[defID] = GetCombatInfo(def)
        if range then count = count + 1 end
    end
    Spring.Echo("[AARangePoC] Detected true AA unit defs: " .. count)
end

--------------------------------------------------------------------------------
-- Tactical group analysis
--------------------------------------------------------------------------------

local function TacticalLinkDistance(a, b)
    local support = math.max(a.range, b.range)
        + TACTICAL_LINK_RESPONSE_TIME * math.max(a.speed, b.speed)
    return math.max(TACTICAL_MIN_LINK, math.min(TACTICAL_MAX_LINK, support))
end

local function Cross(o, a, b)
    return (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
end

local function ConvexHull(points)
    if #points <= 1 then return points end
    table.sort(points, function(a, b)
        return a.x < b.x or (a.x == b.x and a.z < b.z)
    end)

    local unique = {}
    for i = 1, #points do
        local point = points[i]
        local previous = unique[#unique]
        if not previous or point.x ~= previous.x or point.z ~= previous.z then
            unique[#unique + 1] = point
        end
    end
    if #unique <= 1 then return unique end

    local lowerHull = {}
    for i = 1, #unique do
        while #lowerHull >= 2
            and Cross(lowerHull[#lowerHull - 1], lowerHull[#lowerHull], unique[i]) <= 0 do
            lowerHull[#lowerHull] = nil
        end
        lowerHull[#lowerHull + 1] = unique[i]
    end

    local upperHull = {}
    for i = #unique, 1, -1 do
        while #upperHull >= 2
            and Cross(upperHull[#upperHull - 1], upperHull[#upperHull], unique[i]) <= 0 do
            upperHull[#upperHull] = nil
        end
        upperHull[#upperHull + 1] = unique[i]
    end

    lowerHull[#lowerHull] = nil
    upperHull[#upperHull] = nil
    for i = 1, #upperHull do lowerHull[#lowerHull + 1] = upperHull[i] end
    return lowerHull
end

local function BuildPaddedHull(members, isAlly)
    local memberPoints = {}
    for i = 1, #members do
        memberPoints[#memberPoints + 1] = { x = members[i].x, z = members[i].z }
    end
    local baseHull = ConvexHull(memberPoints)
    local expandedPoints = {}
    local roundingPoints = isAlly
        and TACTICAL_HULL_ROUNDING_POINTS
        or TACTICAL_ENEMY_HULL_ROUNDING_POINTS
    for i = 1, #baseHull do
        for step = 1, roundingPoints do
            local angle = (step - 1) * 2 * math.pi / roundingPoints
            expandedPoints[#expandedPoints + 1] = {
                x = baseHull[i].x + TACTICAL_HULL_PADDING * math.cos(angle),
                z = baseHull[i].z + TACTICAL_HULL_PADDING * math.sin(angle),
            }
        end
    end
    return ConvexHull(expandedPoints)
end

local function FindWeakHullIndex(hull, cx, cz, weakDirection)
    local weakHullIndex, bestProjection = 1, -math.huge
    for i = 1, #hull do
        local projection = (hull[i].x - cx) * weakDirection.dirX
            + (hull[i].z - cz) * weakDirection.dirZ
        if projection > bestProjection then
            weakHullIndex, bestProjection = i, projection
        end
    end
    return weakHullIndex
end

local function ResponsePowerAt(members, x, z)
    local immediate, response = 0, 0
    for i = 1, #members do
        local unit = members[i]
        local dx, dz = unit.x - x, unit.z - z
        local distance = math.sqrt(dx * dx + dz * dz)
        local travelDistance = math.max(0, distance - unit.range)
        if travelDistance <= 0 then
            immediate = immediate + unit.power
            response = response + unit.power
        elseif unit.speed > 0 then
            local travelTime = travelDistance / unit.speed
            response = response + unit.power * math.exp(-travelTime / TACTICAL_RESPONSE_TIME)
        end
    end
    return immediate, response
end

local function EvaluateTacticalGroup(members, isAlly)
    local nominal, cx, cz = 0, 0, 0
    local memberIDs = {}
    for i = 1, #members do
        local unit = members[i]
        memberIDs[unit.unitID] = true
        nominal = nominal + unit.power
        cx = cx + unit.x * unit.power
        cz = cz + unit.z * unit.power
    end
    if nominal <= 0 then return nil end
    cx, cz = cx / nominal, cz / nominal

    local radius = 0
    for i = 1, #members do
        local dx, dz = members[i].x - cx, members[i].z - cz
        radius = math.max(radius, math.sqrt(dx * dx + dz * dz))
    end

    local samples = {}
    local weakestIndex, weakestResponse = 1, math.huge
    local weakestImmediate = 0
    for direction = 1, TACTICAL_DIRECTIONS do
        local angle = (direction - 1) * 2 * math.pi / TACTICAL_DIRECTIONS
        local dirX, dirZ = math.cos(angle), math.sin(angle)
        local edgeProjection = -math.huge
        for i = 1, #members do
            local projection = (members[i].x - cx) * dirX + (members[i].z - cz) * dirZ
            if projection > edgeProjection then edgeProjection = projection end
        end
        local x = cx + (edgeProjection + TACTICAL_EDGE_OFFSET) * dirX
        local z = cz + (edgeProjection + TACTICAL_EDGE_OFFSET) * dirZ
        local immediate, response = ResponsePowerAt(members, x, z)
        samples[direction] = {
            x = x, z = z, dirX = dirX, dirZ = dirZ,
            immediate = immediate, response = response,
        }
        if response < weakestResponse then
            weakestIndex, weakestResponse, weakestImmediate = direction, response, immediate
        end
    end

    local hull = BuildPaddedHull(members, isAlly)
    local weakDirection = samples[weakestIndex]
    local weakHullIndex = FindWeakHullIndex(hull, cx, cz, weakDirection)

    return {
        members = members,
        memberIDs = memberIDs,
        isAlly = isAlly,
        x = cx,
        z = cz,
        y = Spring.GetGroundHeight(cx, cz) or 0,
        radius = radius,
        nominal = nominal,
        immediate = weakestImmediate,
        response = weakestResponse,
        cohesion = math.max(0, math.min(1, weakestResponse / nominal)),
        samples = samples,
        weakestIndex = weakestIndex,
        hull = hull,
        weakHullIndex = weakHullIndex,
    }
end

local function GeometricCenter(members)
    local x, z = 0, 0
    for i = 1, #members do
        x = x + members[i].x
        z = z + members[i].z
    end
    return x / #members, z / #members
end

local function UnitCenterReach(unit)
    local reach = unit.range + TACTICAL_RESPONSE_TIME * unit.speed
    return math.max(TACTICAL_CENTER_MIN_REACH, math.min(TACTICAL_CENTER_MAX_REACH, reach))
end

local function GroupFitsCenterReach(members)
    local cx, cz = GeometricCenter(members)
    local farthest, farthestRatio = nil, 0
    for i = 1, #members do
        local unit = members[i]
        local dx, dz = unit.x - cx, unit.z - cz
        local reach = UnitCenterReach(unit)
        local ratio = (dx * dx + dz * dz) / (reach * reach)
        if ratio > farthestRatio then
            farthest, farthestRatio = unit, ratio
        end
    end
    return farthestRatio <= 1, farthest
end

local function SplitByCenterReach(members, output, minimumSize)
    minimumSize = minimumSize or TACTICAL_MIN_GROUP_SIZE
    if #members < minimumSize then return end

    local fits, seedA = GroupFitsCenterReach(members)
    if fits then
        output[#output + 1] = members
        return
    end

    -- Split around the violating outlier and the member farthest from it.
    -- Repeating this recursively prevents pairwise-link chains from producing
    -- a group whose ends cannot realistically support the same center fight.
    local seedB, farthestDistance = nil, -1
    for i = 1, #members do
        local unit = members[i]
        local dx, dz = unit.x - seedA.x, unit.z - seedA.z
        local distance = dx * dx + dz * dz
        if distance > farthestDistance then
            seedB, farthestDistance = unit, distance
        end
    end
    if not seedB or seedA == seedB then return end

    local centerAX, centerAZ = seedA.x, seedA.z
    local centerBX, centerBZ = seedB.x, seedB.z
    local clusterA, clusterB
    for _ = 1, TACTICAL_CENTER_SPLIT_ITERATIONS do
        clusterA, clusterB = {}, {}
        for i = 1, #members do
            local unit = members[i]
            if unit == seedA then
                clusterA[#clusterA + 1] = unit
            elseif unit == seedB then
                clusterB[#clusterB + 1] = unit
            else
                local dax, daz = unit.x - centerAX, unit.z - centerAZ
                local dbx, dbz = unit.x - centerBX, unit.z - centerBZ
                if dax * dax + daz * daz <= dbx * dbx + dbz * dbz then
                    clusterA[#clusterA + 1] = unit
                else
                    clusterB[#clusterB + 1] = unit
                end
            end
        end
        centerAX, centerAZ = GeometricCenter(clusterA)
        centerBX, centerBZ = GeometricCenter(clusterB)
    end

    SplitByCenterReach(clusterA, output, minimumSize)
    SplitByCenterReach(clusterB, output, minimumSize)
end

local function BuildTacticalGroups()
    local units = {}
    for _, unit in pairs(tacticalUnits) do units[#units + 1] = unit end
    local count = #units
    if count == 0 then
        tacticalGroups = {}
        return
    end

    local parent, size, grid = {}, {}, {}
    for i = 1, count do parent[i], size[i] = i, 1 end
    local function Find(i)
        while parent[i] ~= i do
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    local function Union(a, b)
        local ra, rb = Find(a), Find(b)
        if ra == rb then return end
        if size[ra] < size[rb] then ra, rb = rb, ra end
        parent[rb] = ra
        size[ra] = size[ra] + size[rb]
    end

    local cellReach = math.ceil(TACTICAL_MAX_LINK / TACTICAL_GRID_SIZE)
    for i = 1, count do
        local unit = units[i]
        local gx, gz = math.floor(unit.x / TACTICAL_GRID_SIZE), math.floor(unit.z / TACTICAL_GRID_SIZE)
        local side = unit.isAlly and "a:" or "e:"
        for ox = -cellReach, cellReach do
            for oz = -cellReach, cellReach do
                local candidates = grid[side .. (gx + ox) .. ":" .. (gz + oz)]
                if candidates then
                    for c = 1, #candidates do
                        local j = candidates[c]
                        local other = units[j]
                        local dx, dz = unit.x - other.x, unit.z - other.z
                        local link = TacticalLinkDistance(unit, other)
                        if dx * dx + dz * dz <= link * link then Union(i, j) end
                    end
                end
            end
        end
        local key = side .. gx .. ":" .. gz
        grid[key] = grid[key] or {}
        grid[key][#grid[key] + 1] = i
    end

    local components = {}
    for i = 1, count do
        local root = Find(i)
        components[root] = components[root] or {}
        components[root][#components[root] + 1] = units[i]
    end

    -- Preserve four-unit compact components long enough to evaluate the
    -- late-game trigger, even though only five-plus-unit groups are drawn.
    local candidateComponents = {}
    for _, members in pairs(components) do
        SplitByCenterReach(members, candidateComponents, TACTICAL_LATE_GAME_GROUP_UNITS)
    end

    -- Keep cheap units useful in the opening, when they are the main combat
    -- problem. Three separate compact formations, each with four 200+ metal
    -- units, establish that higher-value armies now dominate the tactical view.
    local lateGameGroupCount = 0
    for _, members in ipairs(candidateComponents) do
        local highValueCount = 0
        for i = 1, #members do
            if members[i].metalCost >= TACTICAL_LATE_GAME_UNIT_METAL then
                highValueCount = highValueCount + 1
            end
        end
        if highValueCount >= TACTICAL_LATE_GAME_GROUP_UNITS then
            lateGameGroupCount = lateGameGroupCount + 1
            if lateGameGroupCount >= TACTICAL_LATE_GAME_GROUP_COUNT then break end
        end
    end

    local compactComponents = {}
    if lateGameGroupCount >= TACTICAL_LATE_GAME_GROUP_COUNT then
        for _, members in ipairs(candidateComponents) do
            local retained = {}
            for i = 1, #members do
                local unit = members[i]
                if unit.metalCost <= 0 or unit.metalCost >= TACTICAL_MIN_UNIT_METAL then
                    retained[#retained + 1] = unit
                end
            end
            SplitByCenterReach(retained, compactComponents)
        end
    else
        for _, members in ipairs(candidateComponents) do
            if #members >= TACTICAL_MIN_GROUP_SIZE then
                compactComponents[#compactComponents + 1] = members
            end
        end
    end

    local previousGroups = tacticalGroups
    local claimedPrevious = {}
    local groups = {}
    for _, members in ipairs(compactComponents) do
        local group = EvaluateTacticalGroup(members, members[1].isAlly)
        if group then
            local bestPreviousIndex, bestOverlap = nil, 0
            for previousIndex = 1, #previousGroups do
                local previous = previousGroups[previousIndex]
                if not claimedPrevious[previousIndex] and previous.isAlly == group.isAlly
                    and previous.memberIDs then
                    local overlap = 0
                    for unitID in pairs(group.memberIDs) do
                        if previous.memberIDs[unitID] then overlap = overlap + 1 end
                    end
                    if overlap > bestOverlap then
                        bestPreviousIndex, bestOverlap = previousIndex, overlap
                    end
                end
            end

            if bestPreviousIndex and bestOverlap >= math.max(1, math.ceil(#members * 0.4)) then
                claimedPrevious[bestPreviousIndex] = true
                local previous = previousGroups[bestPreviousIndex]
                local retainedSample = group.samples[previous.weakestIndex]
                -- Do not let nearly tied sample directions flip the weak
                -- edge every analysis tick. A new direction must be
                -- meaningfully weaker before it replaces the old one.
                if retainedSample
                    and retainedSample.response <= group.response * TACTICAL_WEAK_HYSTERESIS then
                    group.weakestIndex = previous.weakestIndex
                    group.immediate = retainedSample.immediate
                    group.response = retainedSample.response
                    group.cohesion = math.max(0, math.min(1, group.response / group.nominal))
                    group.weakHullIndex = FindWeakHullIndex(
                        group.hull, group.x, group.z, retainedSample)
                end
            end
            groups[#groups + 1] = group
        end
    end
    table.sort(groups, function(a, b) return a.nominal > b.nominal end)
    tacticalGroups = groups
end

--------------------------------------------------------------------------------
-- Drawing helpers
--------------------------------------------------------------------------------

local function DrawFilledGroundCircle(x, y, z, radius, segments)
    if not (GL and GL.TRIANGLE_FAN and gl.BeginEnd and gl.Vertex) then return end
    gl.BeginEnd(GL.TRIANGLE_FAN, function()
        gl.Vertex(x, y, z)
        for i = 0, segments do
            local a = (2 * math.pi * i) / segments
            gl.Vertex(x + radius * math.cos(a), y, z + radius * math.sin(a))
        end
    end)
end

-- Draw a circle outline (bold ring) on the ground
local function DrawGroundCircleOutline(x, y, z, radius, segments)
    if not (GL and GL.LINE_LOOP and gl.BeginEnd and gl.Vertex) then return end
    gl.BeginEnd(GL.LINE_LOOP, function()
        for i = 0, segments do
            local a = (2 * math.pi * i) / segments
            gl.Vertex(x + radius * math.cos(a), y, z + radius * math.sin(a))
        end
    end)
end

-- Build diagonal hatch lines clipped inside a ground circle.
-- Returns a flat table { x1, y, z1, x2, y, z2, ... } suitable for GL.LINES.
--
-- IMPORTANT:
-- The hatch pattern is defined in WORLD coordinates, not relative to
-- the circle center. Therefore overlapping anti-nuke circles use exactly
-- the same hatch lines and overlay perfectly.
--
-- Hatch direction:  (1,  1)
-- Hatch normal:     (1, -1)
local function BuildHatchLines(x, y, z, radius)
    local vertices = {}
    local spacing = ANTI_NUKE_HATCH_SPACING

    if radius <= 0 or spacing <= 0 then
        return vertices
    end

    local hatchY = y + 1

    local invSqrt2 = 1 / math.sqrt(2)

    -- Unit vectors:
    -- d = direction along each hatch line
    -- n = direction separating adjacent hatch lines
    local dx = invSqrt2
    local dz = invSqrt2

    local nx = invSqrt2
    local nz = -invSqrt2

    local radiusSq = radius * radius

    -- Project the fixed world-space hatch origin onto the hatch normal.
    -- Every circle therefore uses the exact same sequence of hatch lines.
    local originNormal =
        ANTI_NUKE_HATCH_ORIGIN_X * nx +
        ANTI_NUKE_HATCH_ORIGIN_Z * nz

    -- Projection of this circle center onto the same normal.
    local centerNormal =
        x * nx +
        z * nz

    -- Find the hatch-line indices whose normal coordinates intersect
    -- this circle.
    local minIndex = math.ceil((centerNormal - radius - originNormal) / spacing)
    local maxIndex = math.floor((centerNormal + radius - originNormal) / spacing)

    for i = minIndex, maxIndex do
        -- World-space normal coordinate of this hatch line.
        local lineNormal = originNormal + i * spacing

        -- Offset from the circle center along the hatch normal.
        local offset = lineNormal - centerNormal

        if math.abs(offset) < radius then
            local halfChord = math.sqrt(
                math.max(0, radiusSq - offset * offset)
            )

            -- Center of the chord where the infinite world-space hatch
            -- line intersects this circle.
            local cx = x + offset * nx
            local cz = z + offset * nz

            -- Extend halfChord in the hatch direction.
            local halfDX = halfChord * dx
            local halfDZ = halfChord * dz

            vertices[#vertices + 1] = cx - halfDX
            vertices[#vertices + 1] = hatchY
            vertices[#vertices + 1] = cz - halfDZ

            vertices[#vertices + 1] = cx + halfDX
            vertices[#vertices + 1] = hatchY
            vertices[#vertices + 1] = cz + halfDZ
        end
    end

    return vertices
end

-- Draws every circle in dataList (already filtered to one ally/enemy group) in
-- a single flat color+alpha, regardless of how many of them overlap a given
-- pixel. Uses the stencil buffer as a per-pixel "already painted" mark: the
-- first circle to cover a pixel stamps stencilRef there and paints it; every
-- later circle in the same group is stencil-rejected on that pixel, so it
-- never blends a second time. That makes a lone circle and an N-circle
-- pileup produce the exact same color/opacity - a real boolean union rather
-- than an approximation.
local function DrawCircleGroupCombined(dataList, color, stencilRef)
    gl.StencilFunc(GL.NOTEQUAL, stencilRef, 0xFF)
    gl.StencilOp(GL.KEEP, GL.KEEP, GL.REPLACE)
    gl.Color(color[1], color[2], color[3], FILL_ALPHA)
    for _, data in pairs(dataList) do
        local range = aaRangeByDef[data.defID]
        if range and range > 0 then
            DrawFilledGroundCircle(data.x, data.y, data.z, range, SEGMENTS)
        end
    end
end

-- Original behavior: additive blending, so overlaps visibly brighten.
local function DrawCircleGroupAdditive(dataList, color)
    gl.Color(color[1], color[2], color[3], FILL_ALPHA)
    for _, data in pairs(dataList) do
        local range = aaRangeByDef[data.defID]
        if range and range > 0 then
            DrawFilledGroundCircle(data.x, data.y, data.z, range, SEGMENTS)
        end
    end
end

local function CohesionColor(cohesion)
    if cohesion < 0.4 then
        local t = cohesion / 0.4
        return 1.0, 0.2 + 0.55 * t, 0.1
    elseif cohesion < 0.7 then
        local t = (cohesion - 0.4) / 0.3
        return 1.0 - 0.75 * t, 0.75 + 0.25 * t, 0.1 + 0.25 * t
    end
    return 0.25, 1.0, 0.35
end

local function HullVertex(point, heightOffset)
    gl.Vertex(point.x, (Spring.GetGroundHeight(point.x, point.z) or 0) + heightOffset, point.z)
end

local function DrawTacticalGroupsWorld()
    if not (GL and GL.LINES and GL.LINE_LOOP and GL.TRIANGLE_FAN and gl.BeginEnd and gl.Vertex) then return end
    gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

    for i = 1, #tacticalGroups do
        local group = tacticalGroups[i]
        local hull = group.hull
        if hull and #hull >= 3 then
            local color = group.isAlly and TACTICAL_ALLY_COLOR or TACTICAL_ENEMY_COLOR

            -- A quiet relationship-colored footprint follows the units instead
            -- of implying a circular weapon/influence range.
            gl.Color(color[1], color[2], color[3], 0.055)
            gl.BeginEnd(GL.TRIANGLE_FAN, function()
                gl.Vertex(group.x, group.y + 3, group.z)
                for vertexIndex = 1, #hull do HullVertex(hull[vertexIndex], 3) end
                HullVertex(hull[1], 3)
            end)

            gl.LineWidth(TACTICAL_HULL_LINE_WIDTH)
            gl.Color(color[1], color[2], color[3], 0.68)
            gl.BeginEnd(GL.LINE_LOOP, function()
                for vertexIndex = 1, #hull do HullVertex(hull[vertexIndex], 5) end
            end)

            -- The tactical conclusion is encoded directly on the exposed edge.
            local weakIndex = group.weakHullIndex
            local previousIndex = ((weakIndex - 2) % #hull) + 1
            local nextIndex = (weakIndex % #hull) + 1
            local r, g, b = CohesionColor(group.cohesion)
            gl.LineWidth(TACTICAL_WEAK_LINE_WIDTH)
            gl.Color(r, g, b, 0.98)
            gl.BeginEnd(GL.LINES, function()
                HullVertex(hull[previousIndex], 8)
                HullVertex(hull[weakIndex], 8)
                HullVertex(hull[weakIndex], 8)
                HullVertex(hull[nextIndex], 8)
            end)
        end
    end
    gl.LineWidth(1.0)
end

local function FormatPower(value)
    if value >= 10000 then return string.format("%.0fk", value / 1000) end
    if value >= 1000 then return string.format("%.1fk", value / 1000) end
    return string.format("%.0f", value)
end

local function TryGetKeyCode(names)
    if not Spring.GetKeyCode then return nil end
    for _, name in ipairs(names) do
        local ok, code = pcall(Spring.GetKeyCode, name)
        if ok and code and code ~= 0 then return code end
    end
    return nil
end

local function KeyIsD(key)
    if dKey and key == dKey then return true end
    if Spring.GetKeySymbol then
        local sym = Spring.GetKeySymbol(key)
        if sym and lower(sym) == "d" then return true end
    end
    return false
end

local function KeyIsG(key)
    if gKey and key == gKey then return true end
    if Spring.GetKeySymbol then
        local sym = Spring.GetKeySymbol(key)
        if sym and lower(sym) == "g" then return true end
    end
    return false
end

local function GetViewSizes()
    if gl.GetViewSizes then return gl.GetViewSizes() end
    if Spring.GetViewSizes then return Spring.GetViewSizes() end
    return 0, 0
end

local BTN_W, BTN_H, BTN_GAP = 260, 40, 6

local function GetButtonRect()
    local _, vsy = GetViewSizes()
    local x0 = 12
    local y0 = math.max(12 + BTN_H + BTN_GAP, (vsy * 0.5) - (BTN_H * 0.5))
    return x0, y0, x0 + BTN_W, y0 + BTN_H
end

local function GetAllyButtonRect()
    local x0, y0, x1, _ = GetButtonRect()
    local ay1 = y0 - BTN_GAP
    return x0, ay1 - BTN_H, x1, ay1
end

local function GetCombineButtonRect()
    local x0, ay0, x1, _ = GetAllyButtonRect()
    local cy1 = ay0 - BTN_GAP
    return x0, cy1 - BTN_H, x1, cy1
end

local function GetTacticalButtonRect()
    return GetCombineButtonRect()
end

local function DrawButton(x0, y0, x1, y1, on, label, enabled)
    gl.Color(0.0, 0.0, 0.0, enabled and 0.65 or 0.4)
    gl.Rect(x0, y0, x1, y1)
    if on then gl.Color(0.2, 0.9, 0.2, 0.9) else gl.Color(0.9, 0.2, 0.2, 0.9) end
    gl.Rect(x0, y0, x0 + 6, y1)
    if enabled then
        gl.Color(1.0, 1.0, 1.0, 1.0)
    else
        gl.Color(0.6, 0.6, 0.6, 0.8)
    end
    gl.Text(label, x0 + 14, y0 + 12, 15, "o")
end

local function TextPixelWidth(value, fontSize)
    if gl.GetTextWidth then return gl.GetTextWidth(value) * fontSize end
    return #value * fontSize * 0.58
end

local function RectanglesOverlap(a, b)
    return a.x0 < b.x1 and a.x1 > b.x0 and a.y0 < b.y1 and a.y1 > b.y0
end

local function TacticalLabelLimit()
    local camera = Spring.GetCameraState and Spring.GetCameraState()
    local height = camera and (camera.height or camera.py) or 0
    if height > 6500 then return TACTICAL_MAX_LABELS_FAR end
    if height > 3500 then return TACTICAL_MAX_LABELS_MID end
    return TACTICAL_MAX_LABELS_NEAR
end

local function BuildTacticalLabelLayout()
    local vsx, vsy = GetViewSizes()
    local candidates = {}
    for i = 1, #tacticalGroups do
        local group = tacticalGroups[i]
        candidates[#candidates + 1] = {
            group = group,
            priority = group.nominal,
        }
    end
    table.sort(candidates, function(a, b) return a.priority > b.priority end)

    local occupied = {}
    local bx0, by0, bx1, by1 = GetButtonRect()
    local _, tay0, _, _ = GetTacticalButtonRect()
    occupied[1] = { x0 = bx0, y0 = tay0, x1 = bx1, y1 = by1 }

    local labels = {}
    local maximum = math.min(#candidates, TacticalLabelLimit())
    for i = 1, maximum do
        local group = candidates[i].group
        local sx, sy, sz = Spring.WorldToScreenCoords(group.x, group.y + 70, group.z)
        if sx and sy and sx >= 0 and sx <= vsx and sy >= 0 and sy <= vsy
            and (not sz or sz > 0) then
            local prefix = #group.members .. "u  "
            local status = FormatPower(group.nominal)
            local width = TextPixelWidth(prefix .. status, TACTICAL_LABEL_FONT_SIZE) + 18
            local desiredX = sx - width * 0.5
            local desiredY = sy - TACTICAL_LABEL_HEIGHT * 0.5

            local chosen = nil
            if desiredX >= 5 and desiredX + width <= vsx - 5 then
                for attempt = 0, 10 do
                    local step = math.ceil(attempt / 2)
                    local direction = attempt % 2 == 1 and 1 or -1
                    local y = desiredY + direction * step * (TACTICAL_LABEL_HEIGHT + TACTICAL_LABEL_GAP)
                    if y >= 5 and y + TACTICAL_LABEL_HEIGHT <= vsy - 5 then
                        local rect = {
                            x0 = desiredX, y0 = y,
                            x1 = desiredX + width, y1 = y + TACTICAL_LABEL_HEIGHT,
                        }
                        local blocked = false
                        for occupiedIndex = 1, #occupied do
                            if RectanglesOverlap(rect, occupied[occupiedIndex]) then
                                blocked = true
                                break
                            end
                        end
                        if not blocked then
                            chosen = rect
                            break
                        end
                    end
                end
            end

            if chosen then
                chosen.group = group
                chosen.anchorX = sx
                chosen.anchorY = sy
                chosen.prefix = prefix
                chosen.status = status
                occupied[#occupied + 1] = chosen
                labels[#labels + 1] = chosen
            end
        end
    end
    return labels
end

local function DrawTacticalDetail(label, vsx, vsy)
    local group = label.group
    local width, height = 170, 75
    local x0 = label.x1 + 7
    if x0 + width > vsx - 5 then x0 = label.x0 - width - 7 end
    local y0 = label.y0 - height - 5
    if y0 < 5 then y0 = label.y1 + 5 end
    y0 = math.max(5, math.min(vsy - height - 5, y0))
    local x1, y1 = x0 + width, y0 + height
    local relationship = group.isAlly and TACTICAL_ALLY_COLOR or TACTICAL_ENEMY_COLOR

    gl.Color(0.02, 0.025, 0.03, 0.92)
    gl.Rect(x0, y0, x1, y1)
    gl.Color(relationship[1], relationship[2], relationship[3], 0.95)
    gl.Rect(x0, y1 - 4, x1, y1)

    local textX, textY = x0 + 9, y1 - 20
    gl.Color(1, 1, 1, 1)
    gl.Text(#group.members .. " units", textX, textY, 13, "o")
    gl.Text("Nominal   " .. FormatPower(group.nominal), textX, textY - 17, 12, "o")
    gl.Text("Immediate " .. FormatPower(group.immediate), textX, textY - 33, 12, "o")
    gl.Text("In 5 sec  " .. FormatPower(group.response), textX, textY - 49, 12, "o")
end

--------------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------------

local function IsAllyUnit(uid)
    local at = Spring.GetUnitAllyTeam(uid)
    if at == nil then return false end
    return at == myAllyTeam
end

function widget:Update(dt)
    EnsureCache()

    uiClock = uiClock + dt
    sinceUpdate = sinceUpdate + dt
    sinceTacticalUpdate = sinceTacticalUpdate + dt
    if sinceUpdate < UPDATE_INTERVAL then return end
    sinceUpdate = 0

    local now = Spring.GetGameSeconds()
    local seen = {}
    local tacticalSeen = {}

    local currentUnits = Spring.GetAllUnits()
    if currentUnits then
        for i = 1, #currentUnits do
            local uid = currentUnits[i]
            -- A unit stays in GetAllUnits() through its whole death sequence, and
            -- UnitDestroyed has already fired by then. Without these two guards the
            -- rescan re-adds the corpse and the circle becomes permanent.
            if not deadUnits[uid] and Spring.GetUnitIsDead(uid) ~= true then
                local defID = Spring.GetUnitDefID(uid) -- nil for radar-only blips
                local x, y, z = Spring.GetUnitPosition(uid)

                if x then
                    local isAlly = IsAllyUnit(uid)

                    local combatInfo = defID and combatInfoByDef[defID]
                    if showTactical and combatInfo then
                        local health = Spring.GetUnitHealth(uid)
                        local healthFraction = health and math.max(0, math.min(1, health / combatInfo.maxHealth)) or 1
                        local currentPower = combatInfo.power * healthFraction
                        local previous = tacticalUnits[uid]
                        local displayX, displayZ, displayPower = x, z, currentPower
                        if previous and previous.defID == defID then
                            local smoothing = TACTICAL_UNIT_SMOOTHING
                            displayX = previous.x + (x - previous.x) * smoothing
                            displayZ = previous.z + (z - previous.z) * smoothing
                            displayPower = previous.power + (currentPower - previous.power) * smoothing
                        end
                        tacticalSeen[uid] = true
                        tacticalUnits[uid] = {
                            unitID = uid,
                            defID = defID,
                            x = displayX,
                            y = Spring.GetGroundHeight(displayX, displayZ) or y or 0,
                            z = displayZ,
                            lastSeen = now,
                            isAlly = isAlly,
                            range = combatInfo.range,
                            speed = combatInfo.speed,
                            power = displayPower,
                            metalCost = combatInfo.metalCost,
                        }
                    end

                    -- Check for anti-nuke units (enemy only)
                    local defName = UnitDefs[defID] and UnitDefs[defID].name
                    if defName and ANTI_NUKE_NAMES[defName] and not isAlly then
                        seen[uid] = true
                        antiNukeUnits[uid] = {
                            defID = defID,
                            x = x,
                            y = Spring.GetGroundHeight(x, z) or y or 0,
                            z = z,
                            lastSeen = now,
                        }
                    elseif defID and aaRangeByDef[defID] then
                        seen[uid] = true
                        trackedUnits[uid] = {
                            defID = defID,
                            x = x,
                            y = Spring.GetGroundHeight(x, z) or y or 0,
                            z = z,
                            lastSeen = now,
                            isAlly = isAlly,
                        }
                    end
                end
            end
        end
    end

    -- Prune remembered units we did not see this tick.
    for uid, data in pairs(trackedUnits) do
        if not seen[uid] then
            if hasPosInLos and Spring.IsPosInLos(data.x, data.y, data.z) then
                -- We can see that spot and nothing is standing there: it died or moved.
                trackedUnits[uid] = nil
            elseif now - (data.lastSeen or now) > MEMORY_TTL then
                -- Backstop for positions we never revisit.
                trackedUnits[uid] = nil
            end
        end
    end

    -- Prune remembered anti-nuke units we did not see this tick.
    for uid, data in pairs(antiNukeUnits) do
        if not seen[uid] then
            if hasPosInLos and Spring.IsPosInLos(data.x, data.y, data.z) then
                antiNukeUnits[uid] = nil
            elseif now - (data.lastSeen or now) > MEMORY_TTL then
                antiNukeUnits[uid] = nil
            end
        end
    end

    if showTactical then
        for uid, data in pairs(tacticalUnits) do
            if not tacticalSeen[uid] then
                if hasPosInLos and Spring.IsPosInLos(data.x, data.y, data.z) then
                    tacticalUnits[uid] = nil
                elseif now - (data.lastSeen or now) > TACTICAL_MEMORY_TTL then
                    tacticalUnits[uid] = nil
                end
            end
        end
        if sinceTacticalUpdate >= TACTICAL_UPDATE_INTERVAL then
            sinceTacticalUpdate = 0
            BuildTacticalGroups()
        end
    end

    -- Expire the death blacklist so it doesn't grow all match and so recycled
    -- unitIDs aren't suppressed forever.
    for uid, t in pairs(deadUnits) do
        if now - t > DEAD_BLACKLIST_TTL then deadUnits[uid] = nil end
    end
end

function widget:UnitDestroyed(unitID)
    trackedUnits[unitID] = nil
    antiNukeUnits[unitID] = nil
    tacticalUnits[unitID] = nil
    deadUnits[unitID] = Spring.GetGameSeconds()
end

-- Keep the ally test correct when spectating and switching viewed team.
function widget:PlayerChanged()
    local newAllyTeam = Spring.GetMyAllyTeamID()
    if newAllyTeam ~= myAllyTeam then
        myAllyTeam = newAllyTeam
        for uid, data in pairs(trackedUnits) do
            data.isAlly = IsAllyUnit(uid)
        end
        for uid, data in pairs(tacticalUnits) do
            data.isAlly = IsAllyUnit(uid)
        end
        if showTactical then BuildTacticalGroups() end
    end
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------

function widget:Initialize()
    dKey = TryGetKeyCode({ "d", "D" })
    if not dKey and KEYSYMS then dKey = KEYSYMS.D or KEYSYMS.d end
    gKey = TryGetKeyCode({ "g", "G" })
    if not gKey and KEYSYMS then gKey = KEYSYMS.G or KEYSYMS.g end
    myAllyTeam = Spring.GetMyAllyTeamID()
    EnsureCache()

    widgetHandler:AddAction("aarange", Toggle, nil, "p")
    widgetHandler:AddAction("aaally", ToggleAlly, nil, "p")
    widgetHandler:AddAction("aacombine", ToggleCombine, nil, "p")
    widgetHandler:AddAction("aatactical", ToggleTactical, nil, "p")
    widgetHandler:AddAction("aaclear", ClearMemory, nil, "p")

    Spring.Echo("[AARangePoC] loaded. Ctrl+D toggles enemy AA; Ctrl+G toggles tactical group evaluation. Use /aaclear to wipe remembered units.")
    if not hasStencilSupport then
        Spring.Echo("[AARangePoC] Note: this engine build has no stencil gl functions, so combine mode is unavailable.")
    end
end

function widget:Shutdown()
    widgetHandler:RemoveAction("aarange")
    widgetHandler:RemoveAction("aaally")
    widgetHandler:RemoveAction("aacombine")
    widgetHandler:RemoveAction("aatactical")
    widgetHandler:RemoveAction("aaclear")
end

-- Fallback for builds where AddAction routing differs.
function widget:TextCommand(command)
    local cmd = lower(command)
    if cmd == "aarange" then Toggle() return true end
    if cmd == "aaally" then ToggleAlly() return true end
    if cmd == "aacombine" then ToggleCombine() return true end
    if cmd == "aatactical" then ToggleTactical() return true end
    if cmd == "aaclear" then ClearMemory() return true end
    return false
end

function widget:KeyPress(key, mods, isRepeat)
    if isRepeat or not mods or not mods.ctrl then return false end
    if KeyIsG(key) then
        ToggleTactical()
        return true
    end
    if not KeyIsD(key) then return false end
    if mods.alt then
        ToggleCombine()
    elseif mods.shift then
        ToggleAlly()
    else
        Toggle()
    end
    return true
end

function widget:DrawWorld()
    if not showAll and not showTactical then return end

    gl.DepthTest(false)
    gl.Blending(true)

    if showAll then

    local useCombine = combineOverlap and hasStencilSupport

    -- Split the tracked units into per-group lists once; both draw paths need this.
    local enemyList, allyList = {}, {}
    for uid, data in pairs(trackedUnits) do
        if data.isAlly then
            if showAlly then allyList[uid] = data end
        else
            enemyList[uid] = data
        end
    end

    if useCombine then
        -- One clear per frame; enemy and ally each get their own stencil
        -- reference value so a group unions with itself while still being
        -- able to layer on top of the other group's already-painted pixels.
        gl.StencilMask(0xFF)
        gl.Clear(GL.STENCIL_BUFFER_BIT, 0)
        gl.StencilTest(true)
        -- Additive, same as overlap mode - the stencil (not the blend func)
        -- is what removes double-painting, so using the same equation here
        -- makes a lone circle and a unioned overlap come out identically
        -- bright instead of the union looking dimmer.
        gl.BlendFunc(GL.SRC_ALPHA, GL.ONE)

        DrawCircleGroupCombined(enemyList, ENEMY_COLOR, 1)
        if showAlly then
            DrawCircleGroupCombined(allyList, ALLY_COLOR, 2)
        end

        gl.StencilTest(false)
    else
        gl.BlendFunc(GL.SRC_ALPHA, GL.ONE) -- additive: overlapping circles brighten, showing density

        DrawCircleGroupAdditive(enemyList, ENEMY_COLOR)
        if showAlly then
            DrawCircleGroupAdditive(allyList, ALLY_COLOR)
        end
    end

    -- Anti-nuke circles: bold white outline + hatched interior (enemy only)
    if next(antiNukeUnits) then
        gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
        gl.DepthTest(false)

        -- Collect all hatch vertices into a single array
        local allHatchVerts = {}
        for _, data in pairs(antiNukeUnits) do
            local verts = BuildHatchLines(data.x, data.y, data.z, ANTI_NUKE_RANGE)
            for i = 1, #verts do
                allHatchVerts[#allHatchVerts + 1] = verts[i]
            end
        end

        -- Draw hatch lines.
        -- Use immediate mode to avoid depending on gl.Lines() vertex-table format.
        if #allHatchVerts > 0 and GL and GL.LINES and gl.BeginEnd and gl.Vertex then
            gl.LineWidth(ANTI_NUKE_HATCH_WIDTH)
            gl.Color(
                ANTI_NUKE_LINE_COLOR[1],
                ANTI_NUKE_LINE_COLOR[2],
                ANTI_NUKE_LINE_COLOR[3],
                ANTI_NUKE_HATCH_ALPHA
            )

            gl.BeginEnd(GL.LINES, function()
                for i = 1, #allHatchVerts, 3 do
                    gl.Vertex(allHatchVerts[i], allHatchVerts[i + 1], allHatchVerts[i + 2])
                end
            end)
        end

        -- Bold white outlines (more segments for a smooth-looking ring)
        gl.LineWidth(ANTI_NUKE_OUTLINE_WIDTH)
        gl.Color(ANTI_NUKE_LINE_COLOR[1], ANTI_NUKE_LINE_COLOR[2], ANTI_NUKE_LINE_COLOR[3], 1.0)
        local antiNukeOutlineSegments = math.max(96, math.ceil(2 * math.pi * ANTI_NUKE_RANGE / 20))
        for _, data in pairs(antiNukeUnits) do
            DrawGroundCircleOutline(data.x, data.y, data.z, ANTI_NUKE_RANGE, antiNukeOutlineSegments)
        end
        gl.LineWidth(1.0)
    end

    end

    if showTactical then DrawTacticalGroupsWorld() end

    gl.Color(1.0, 1.0, 1.0, 1.0)
    gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
    gl.DepthTest(true)
end

function widget:DrawScreen()
    local x0, y0, x1, y1 = GetButtonRect()
    DrawButton(x0, y0, x1, y1, showAll,
        "AA Ranges: " .. (showAll and "ON" or "OFF") .. " [Ctrl+D]", true)

    local ax0, ay0, ax1, ay1 = GetAllyButtonRect()
    DrawButton(ax0, ay0, ax1, ay1, showAlly,
        "Ally AA: " .. (showAlly and "ON" or "OFF") .. " [Ctrl+Shift+D]", showAll)
    --[[
    local cx0, cy0, cx1, cy1 = GetCombineButtonRect()
    local combineLabel = "Combine: " .. (combineOverlap and "ON" or "OFF") .. " [Ctrl+Alt+D]"
    if not hasStencilSupport then
        combineLabel = "Combine: N/A (no stencil)"
    end
    DrawButton(cx0, cy0, cx1, cy1, combineOverlap, combineLabel, showAll and hasStencilSupport)
    --]]

    local tx0, ty0, tx1, ty1 = GetTacticalButtonRect()
    DrawButton(tx0, ty0, tx1, ty1, showTactical,
        "Tactical Groups: " .. (showTactical and "ON" or "OFF") .. " [Ctrl+G]", true)

    if showTactical and Spring.WorldToScreenCoords then
        local vsx, vsy = GetViewSizes()
        local mouseX, mouseY = -1, -1
        if Spring.GetMouseState then mouseX, mouseY = Spring.GetMouseState() end
        local labels = BuildTacticalLabelLayout()
        local hovered = nil

        for i = 1, #labels do
            local label = labels[i]
            local group = label.group
            local centerX = (label.x0 + label.x1) * 0.5
            local centerY = (label.y0 + label.y1) * 0.5
            local dx, dy = centerX - label.anchorX, centerY - label.anchorY
            if dx * dx + dy * dy > 196 and GL and GL.LINES and gl.BeginEnd and gl.Vertex then
                gl.LineWidth(1)
                gl.Color(0.85, 0.85, 0.85, 0.45)
                gl.BeginEnd(GL.LINES, function()
                    gl.Vertex(label.anchorX, label.anchorY)
                    gl.Vertex(centerX, centerY)
                end)
            end

            gl.Color(0.015, 0.02, 0.025, 0.84)
            gl.Rect(label.x0, label.y0, label.x1, label.y1)
            local relationship = group.isAlly and TACTICAL_ALLY_COLOR or TACTICAL_ENEMY_COLOR
            gl.Color(relationship[1], relationship[2], relationship[3], 0.95)
            gl.Rect(label.x0, label.y0, label.x0 + 4, label.y1)

            local textX = label.x0 + 9
            local textY = label.y0 + 6
            gl.Color(0.95, 0.95, 0.95, 1)
            gl.Text(label.prefix, textX, textY, TACTICAL_LABEL_FONT_SIZE, "o")
            gl.Color(1.0, 0.92, 0.62, 1)
            gl.Text(label.status, textX + TextPixelWidth(label.prefix, TACTICAL_LABEL_FONT_SIZE),
                textY, TACTICAL_LABEL_FONT_SIZE, "o")

            if mouseX >= label.x0 and mouseX <= label.x1
                and mouseY >= label.y0 and mouseY <= label.y1 then
                hovered = label
            end
        end

        if hovered then DrawTacticalDetail(hovered, vsx, vsy) end
        gl.Color(1, 1, 1, 1)
    end
end

function widget:MousePress(x, y, button)
    if button ~= 1 then return false end

    local x0, y0, x1, y1 = GetButtonRect()
    if x >= x0 and x <= x1 and y >= y0 and y <= y1 then
        Toggle()
        return true
    end

    local ax0, ay0, ax1, ay1 = GetAllyButtonRect()
    if x >= ax0 and x <= ax1 and y >= ay0 and y <= ay1 then
        ToggleAlly()
        return true
    end

    local tx0, ty0, tx1, ty1 = GetTacticalButtonRect()
    if x >= tx0 and x <= tx1 and y >= ty0 and y <= ty1 then
        ToggleTactical()
        return true
    end

    return false
end
