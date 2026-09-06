function widget:GetInfo()
    return {
        name = "AARangePoC",
        desc = "Toggleable filled circles for true AA turrets/units. Remembers FoW positions. Ally ranges optional. Combine mode unions overlapping circles instead of stacking brightness.",
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

local SHOW_ALLY_BY_DEFAULT = false
local COMBINE_BY_DEFAULT = false

local UPDATE_INTERVAL = 0.2 -- how often to rescan visible units (seconds, real time)
local MEMORY_TTL = 3000      -- seconds a circle survives without being re-sighted or LOS-checked
local DEAD_BLACKLIST_TTL = 30 -- seconds a destroyed unitID stays blocked from re-entry

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local showAll = false                        -- master toggle (enemy circles)
local showAlly = SHOW_ALLY_BY_DEFAULT        -- additionally draw own/allied AA
local combineOverlap = COMBINE_BY_DEFAULT    -- union overlapping circles instead of stacking alpha

local aaRangeByDef = {}
local cacheBuilt = false

local dKey = nil

local trackedUnits = {}   -- uid -> { defID, x, y, z, lastSeen, isAlly }
local deadUnits = {}      -- uid -> gameTime of death (blocks the death-sequence re-add race)

local myAllyTeam = Spring.GetMyAllyTeamID()

local uiClock = 0         -- accumulated real time, used for toggle debounce
local lastToggleClock = -1
local lastAllyToggleClock = -1
local lastCombineToggleClock = -1
local sinceUpdate = 0

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

local function ClearMemory()
    local count = 0
    for _ in pairs(trackedUnits) do count = count + 1 end
    trackedUnits = {}
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

local function EnsureCache()
    if cacheBuilt then return end
    if not UnitDefs or not next(UnitDefs) then return end
    if not WeaponDefs or not next(WeaponDefs) then return end
    cacheBuilt = true
    local count = 0
    for defID, def in pairs(UnitDefs) do
        local range = GetAARange(def)
        aaRangeByDef[defID] = range
        if range then count = count + 1 end
    end
    Spring.Echo("[AARangePoC] Detected true AA unit defs: " .. count)
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
    if sinceUpdate < UPDATE_INTERVAL then return end
    sinceUpdate = 0

    local now = Spring.GetGameSeconds()
    local seen = {}

    local currentUnits = Spring.GetAllUnits()
    if currentUnits then
        for i = 1, #currentUnits do
            local uid = currentUnits[i]
            -- A unit stays in GetAllUnits() through its whole death sequence, and
            -- UnitDestroyed has already fired by then. Without these two guards the
            -- rescan re-adds the corpse and the circle becomes permanent.
            if not deadUnits[uid] and Spring.GetUnitIsDead(uid) ~= true then
                local defID = Spring.GetUnitDefID(uid) -- nil for radar-only blips
                if defID and aaRangeByDef[defID] then
                    local x, y, z = Spring.GetUnitPosition(uid)
                    if x then
                        seen[uid] = true
                        trackedUnits[uid] = {
                            defID = defID,
                            x = x,
                            y = Spring.GetGroundHeight(x, z) or y or 0,
                            z = z,
                            lastSeen = now,
                            isAlly = IsAllyUnit(uid),
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

    -- Expire the death blacklist so it doesn't grow all match and so recycled
    -- unitIDs aren't suppressed forever.
    for uid, t in pairs(deadUnits) do
        if now - t > DEAD_BLACKLIST_TTL then deadUnits[uid] = nil end
    end
end

function widget:UnitDestroyed(unitID)
    trackedUnits[unitID] = nil
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
    end
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------

function widget:Initialize()
    dKey = TryGetKeyCode({ "d", "D" })
    if not dKey and KEYSYMS then dKey = KEYSYMS.D or KEYSYMS.d end
    myAllyTeam = Spring.GetMyAllyTeamID()
    EnsureCache()

    widgetHandler:AddAction("aarange", Toggle, nil, "p")
    widgetHandler:AddAction("aaally", ToggleAlly, nil, "p")
    widgetHandler:AddAction("aacombine", ToggleCombine, nil, "p")
    widgetHandler:AddAction("aaclear", ClearMemory, nil, "p")

    Spring.Echo("[AARangePoC] loaded. Ctrl+D or /aarange toggles enemy AA. Ctrl+Shift+D or /aaally adds allied AA. Ctrl+Alt+D or /aacombine unions overlapping circles. /aaclear wipes remembered units.")
    if not hasStencilSupport then
        Spring.Echo("[AARangePoC] Note: this engine build has no stencil gl functions, so combine mode is unavailable.")
    end
end

function widget:Shutdown()
    widgetHandler:RemoveAction("aarange")
    widgetHandler:RemoveAction("aaally")
    widgetHandler:RemoveAction("aacombine")
    widgetHandler:RemoveAction("aaclear")
end

-- Fallback for builds where AddAction routing differs.
function widget:TextCommand(command)
    local cmd = lower(command)
    if cmd == "aarange" then Toggle() return true end
    if cmd == "aaally" then ToggleAlly() return true end
    if cmd == "aacombine" then ToggleCombine() return true end
    if cmd == "aaclear" then ClearMemory() return true end
    return false
end

function widget:KeyPress(key, mods, isRepeat)
    if isRepeat or not mods or not mods.ctrl then return false end
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
    if not showAll then return end

    gl.DepthTest(false)
    gl.Blending(true)

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

    local cx0, cy0, cx1, cy1 = GetCombineButtonRect()
    if x >= cx0 and x <= cx1 and y >= cy0 and y <= cy1 then
        ToggleCombine()
        return true
    end

    return false
end