--- @module "Sonson's Prayer Flicker"
--- @version 1.0.3

------------------------------------------
--# IMPORTS
------------------------------------------

local API             = require("api")
local Player          = require("raksha.core.player")
local Utils           = require("raksha.core.helper")


------------------------------------------
--# DEBUG LOGGING
------------------------------------------

--- Set true to get the flicker's step-by-step trace back.
---
--- It was ALWAYS ON. PrayerFlicker.new sets `self.DEBUG = false` and nothing
--- ever read it, while dozens of Utils:log(..., "debug") calls ran
--- unconditionally through the hottest path in a boss script — several per
--- threat, per pass, at 10-20 passes a game tick. Each one rebuilt a dispatch
--- table, formatted a string and pushed a line to the client log, and with
--- API.SetDrawLogs enabled the client then DREW every one of them.
---
--- Module scope rather than the instance, so the guard also covers the calls in
--- PrayerFlicker.new that run before `self` exists. Only "debug" level calls
--- were moved behind it: info, warn and error still report unconditionally,
--- because those are the lines that say something went wrong.
local DEBUG_LOGGING = false

--- Debug trace line, dropped unless DEBUG_LOGGING is on.
--- @param message string
local function dbg(message)
    if DEBUG_LOGGING then Utils:log(message, "debug") end
end

------------------------------------------
--# TYPE DEFINITIONS
------------------------------------------

--- @class Prayer
--- @field name             string              The name of the prayer (Used for activating ability)
--- @field id               integer             The ID of the buff

--- @class PrayerConfig
--- @field defaultPrayer?   Prayer              The default prayer to use when no threat is active
--- @field threats          Threat[]            A list of threats to monitor

--- @class Threat
--- @field name?            string              Used for debugging and metrics
--- @field type             ThreatType          The type of threat to check for
--- @field prayer           Prayer              The prayer to use against this threat
--- @field range?           integer             The radius within which the threat is checked (default: 60)
--- @field id?              integer|integer[]   The ID(s) to identify the threat (animation or projectile)
--- @field condition?       fun():boolean       A function evaluating the threat condition
--- @field bypassCondition? fun():boolean       A function that, if returns true, bypasses the threat check
--- @field npcId?           integer             The NPC ID associated with an animation threat
--- @field priority         integer             The priority of the threat (higher values denote higher urgency)
--- @field delay            integer             The delay (in ticks) before the threat becomes actionable
--- @field duration         integer             The duration (in ticks) for which the threat remains active

--- @alias ThreatType
--- | "Projectile"
--- | "Animation"
--- | "Conditional"

--- @class Action
--- @field threat           Threat              The threat which triggered this action
--- @field activationData   ActivationData      Data related to timing of the action

--- @class ActivationData
--- @field tickAdded        integer             The tick at which the action was added
--- @field tickActivated    integer             The tick at which the prayer was activated
--- @field tickExpired      integer             The tick when the action/threat expires

--- @class PrayerState
--- @field activePrayer     Prayer              The currently active prayer
--- @field lastPrayerTick   number              The tick at which the last prayer was activated
--- @field pendingActions   Action[]            A list of pending actions based on detected threats

--- @class PrayerFlicker
--- @field defaultPrayer    Prayer              The default prayer used when no threats are active
--- @field threats          Threat[]            A list of threats to monitor
--- @field pendingActions   Action[]            A list of actions queued based on threats
--- @field state            PrayerState         State data including active prayer and timing information
--- @field update           fun(self):boolean   Performs an update cycle and returns true if an action was triggered
--- @field deactivatePrayer fun(self):boolean   Deactivates the currently active prayer
--- @field tracking         fun(self):table     Returns a metrics table for debugging and monitoring

------------------------------------------
--# INITIALIZATION
------------------------------------------

local PrayerFlicker   = {}
PrayerFlicker.__index = PrayerFlicker

------------------------------------------
--# LIST OF OVERHEADS
------------------------------------------

--- List of curses to choose from
PrayerFlicker.CURSES  = {
    SOUL_SPLIT         = { name = "Soul Split", id = 26033 },
    DEFLECT_MELEE      = { name = "Deflect Melee", id = 26040 },
    DEFLECT_MAGIC      = { name = "Deflect Magic", id = 26041 },
    DEFLECT_RANGED     = { name = "Deflect Ranged", id = 26044 },
    DEFLECT_NECROMANCY = { name = "Deflect Necromancy", id = 30745 },
}

--- List of prayers to choose from
--- Note: These are regular prayers (not curses). Use CURSES for Soul Split/Deflect variants.
PrayerFlicker.PRAYERS = {
    ECLIPSED_SOUL           = { name = "Eclipsed Soul", id = 34092 },             -- Necromancy prayer
    PROTECT_FROM_MELEE      = { name = "Protect from Melee", id = 25961 },
    PROTECT_FROM_MAGIC      = { name = "Protect from Magic", id = 25959 },
    PROTECT_FROM_RANGED     = { name = "Protect from Missiles", id = 25960 },     -- Correct name and ID
    PROTECT_FROM_SUMMONING  = { name = "Protect from Summoning", id = 25958 },    -- Correct ID
    PROTECT_FROM_NECROMANCY = { name = "Protect from Necromancy", id = 34093 },   -- Necromancy prayer
}

-- Singleton instance
local instance        = nil

--- Initiatlizes a new Prayer Flicker instance
--- @param config? PrayerConfig Configuration options
--- @return PrayerFlicker: Initialized PrayerFlicker instance
function PrayerFlicker.new(config)
    if instance then
        dbg("Returning existing PrayerFlicker instance") -- DEBUG
        return instance
    end

    -- Creates a new instance if none exists
    local self = setmetatable({}, PrayerFlicker)
    Utils:log("Initializing Prayer flicker instance", "info")
    -- Default debug values
    self.DEBUG = false

    -- TODO: Assert configurations
    dbg("Validating configuration...") -- DEBUG
    if config then
        dbg("Configuration provided")  -- DEBUG
    end

    self.flickInterval     = 1
    self.sameFlickInterval = 4
    self.defaultPrayer     = config and config.defaultPrayer or {}
    self.threats           = config and config.threats or {}
    self.prayers           = self:_getRequiredPrayers()
    self.pendingActions    = {}

    -- Check if the player has their required prayers on their bars
    self:_checkRequiredPrayers()

    self.state = {
        activePrayer = {},
        activationTick = 0,
    }

    instance = self
    Utils:log("PrayerFlicker initialized successfully", "info") -- DEBUG
    return instance
end

--- Retrieves all required prayers from list of threats
function PrayerFlicker:_getRequiredPrayers()
    dbg("Retrieving required prayers from threats") -- DEBUG
    local requiredPrayers = {}

    if self.defaultPrayer then
        table.insert(requiredPrayers, self.defaultPrayer)
    end

    for _, threat in ipairs(self.threats) do
        local prayer = threat.prayer
        -- Check if prayer already exists
        if #requiredPrayers > 0 then
            for _, requiredPrayer in ipairs(requiredPrayers) do
                if requiredPrayer.name == prayer.name then
                    dbg("Prayer already registered: " .. prayer.name) -- DEBUG
                    goto continue
                end
            end
        end
        Utils:log("Required prayer registered: " .. prayer.name, "info")
        table.insert(requiredPrayers, prayer)
        ::continue::
    end
    dbg("Total required prayers: " .. #requiredPrayers) -- DEBUG
    return requiredPrayers
end

--- Checks to see if the listed prayers exist on available ability bars
--- @private
function PrayerFlicker:_checkRequiredPrayers()
    dbg("Checking for required prayers on ability bars") -- DEBUG
    local missingPrayers = {}

    for _, prayer in pairs(self.prayers) do
        dbg("Checking ability bar for prayer: " .. prayer.name) -- DEBUG
        if #API.GetABs_names({ prayer.name }) < 1 then
            dbg("Prayer missing: " .. prayer.name)              -- DEBUG
            table.insert(missingPrayers, prayer.name)
        end
    end

    if #missingPrayers >= 1 then
        API.SetDrawLogs(true)
        Utils:log("[PRAYER FLICKER]: Missing prayers!", "warn")
        Utils:log("[PRAYER FLICKER]: Please make sure to add the following prayers to your ability bars.", "warn")
        Utils:log("[PRAYER FLICKER]: " .. table.concat(missingPrayers, ", "), "warn")
        Utils:log("[PRAYER FLICKER]: Terminating your session.", "error")
        -- Terminate session
        API.Write_LoopyLoop(false)
    else
        Utils:log("All required prayers found on ability bars", "info") -- DEBUG
    end
end

------------------------------------------
--# CORE FUNCTIONALITY
------------------------------------------

--- Updates the Prayer Flicker instance
--- @return boolean: Whether an action was triggered this loop
function PrayerFlicker:update()
    dbg("Updating PrayerFlicker...") -- DEBUG
    self:_updateActions()
    return self:_switchPrayer(self:_determinePrayer())
end

--- Disables active prayer
--- @return boolean
function PrayerFlicker:deactivatePrayer()
    dbg("Attempting to deactivate prayer") -- DEBUG
    local currentTick = API.Get_tick()
    local prayer = self:_getActivePrayer()
    if not prayer.name or ((currentTick - self.state.activationTick < 1) and not self.state.activePrayer.name) then
        dbg("Deactivation skipped: No active prayer or cooldown") -- DEBUG
        return false
    end

    Utils:log("Deactivating prayer: " .. prayer.name, "info") -- DEBUG
    local success = API.DoAction_Ability(
        prayer.name,
        1,
        API.OFF_ACT_GeneralInterface_route,
        true
    )

    if success then
        self.state.activationTick = API.Get_tick()
        ---@diagnostic disable-next-line
        self.state.activePrayer = {}
        Utils:log("Prayer deactivated: " .. prayer.name, "info")          -- DEBUG
    else
        Utils:log("Failed to deactivate prayer: " .. prayer.name, "warn") -- DEBUG
    end

    return success
end

------------------------------------------
--# THREAT MANAGEMENT CORE FUNCTIONS
------------------------------------------

--- Checks to see if threats exists and adds them to self.pendingActions if they do
function PrayerFlicker:_getExistingThreats()
    dbg("Scanning for existing threats...") -- DEBUG
    local foundThreats = {}
    -- Iterate over list of threats
    for _, threat in ipairs(self.threats) do
        dbg("Checking threat: " .. (threat.name or "Unnamed")) -- DEBUG
        if self:_doesThreatExist(threat) then
            if not self:_isThreatInTable(foundThreats, threat) then
                Utils:log("+ Threat detected: " .. (threat.name or "Unnamed threat"), "warn")
                table.insert(foundThreats, threat)
            end
        else
            dbg("- Threat not active: " .. (threat.name or "Unnamed")) -- DEBUG
        end
    end
    dbg("Total threats found: " .. #foundThreats) -- DEBUG
    return foundThreats
end

function PrayerFlicker:_updateActions()
    dbg("Updating pending actions...") -- DEBUG
    local currentTick = API.Get_tick()
    local threats     = self:_getExistingThreats()
    local actions     = self.pendingActions
    local toAdd       = {}
    local toRemove    = {}

    dbg("Current pending actions: " .. #actions) -- DEBUG

    if #threats > 0 then
        dbg("Processing " .. #threats .. " active threats") -- DEBUG
        -- Check if threats exist, add to threats.pendingActions
        for _, threat in ipairs(threats) do
            if not self:_isThreatInTable(self.pendingActions, threat) then
                dbg("+ Adding threat: " .. (threat.name or "Unnamed threat")) -- DEBUG
                table.insert(toAdd, threat)
            end
        end

        -- Add threats that don't exist in self.pendingActions
        for _, threat in ipairs(toAdd) do
            table.insert(self.pendingActions, {
                threat = threat,
                activationData = {
                    tickExpired = -1,
                    tickAdded = currentTick
                }
            })
            dbg("Added threat to pending actions: " .. (threat.name or "Unnamed")) -- DEBUG
        end
    end

    if #actions > 0 then
        dbg("Processing " .. #actions .. " pending actions") -- DEBUG
        for i, action in ipairs(actions) do
            local threatExists = self:_doesThreatExist(action.threat)
            -- If the threat no longer exists
            if not threatExists then
                local tickExpired = action.activationData.tickExpired
                -- If no expiration tick set
                if tickExpired == -1 then
                    action.activationData.tickExpired = currentTick + action.threat.duration
                    dbg("Set expiration tick for threat: " .. (action.threat.name or "Unnamed")) -- DEBUG
                    goto continue
                end
                -- If expiration tick passed
                if currentTick > tickExpired then
                    dbg("Threat expired: " .. (action.threat.name or "Unnamed threat")) -- DEBUG
                    table.insert(toRemove, { index = i, action = action })
                    goto continue
                end
            else
                -- Threat still exists, make sure no expiration date
                action.activationData.tickExpired = -1
                dbg("Threat still active: " .. (action.threat.name or "Unnamed")) -- DEBUG
            end
            ::continue::
        end
    end

    -- Remove expired actions
    table.sort(toRemove, function(a, b)
        return a.index < b.index
    end)
    for _, record in ipairs(toRemove) do
        dbg("Removing expired action: " .. (record.action.threat.name or "Unnamed")) -- DEBUG
        table.remove(self.pendingActions, record.index)
    end

    dbg("Pending actions after update: " .. #self.pendingActions) -- DEBUG
end

------------------------------------------
--# THREAT MANAGEMENT HELPER FUNCTIONS
------------------------------------------

--- Checks if the threat exists
--- @param threat Threat: The threat in question
--- @return boolean: Whether the threat exists
function PrayerFlicker:_doesThreatExist(threat)
    --- @type ThreatType
    local threatType = threat.type
    local threatExists = false
    dbg(string.format("Checking for threat [%s]: %s", threat.type, threat.name or "Unnamed threat"))

    -- Projectile threat checks
    if threatType == "Projectile" then
        dbg(string.format("Checking projectile ID %d (range %d)", threat.id, threat.range or 60)) -- DEBUG
        threatExists = self:_projectileExists(threat.id, threat.range)
        goto continue
    end

    -- Animation threat checks
    if threatType == "Animation" then
        --Utils:log(string.format("Checking NPC %d animation %d (range %d)", threat.npcId, threat.id, threat.range or 60), "debug") -- DEBUG
        threatExists = self:_animationExists(threat.npcId, threat.id, threat.range)
        goto continue
    end

    -- Conditional threat checks
    if threatType == "Conditional" then
        dbg("Checking conditional threat") -- DEBUG
        threatExists = self:_conditionalThreatExists(threat.condition)
        goto continue
    end
    ::continue::
    if threat.bypassCondition and threat.bypassCondition() then
        dbg("Threat bypassed by condition") -- DEBUG
        return false
    end
    dbg("Threat exists: " .. tostring(threatExists)) -- DEBUG
    return threatExists
end

--- Checks if the specified projectile threat(s) exist
--- @param id integer | integer[]
--- @param range? integer
--- @return boolean
--- @private
function PrayerFlicker:_projectileExists(id, range)
    dbg(string.format("Scanning for projectiles (ID: %s, range: %d)", tostring(id), range or 60)) -- DEBUG
    local found = #Utils:findAll(id, 5, range or 60) > 0
    dbg(string.format("Projectiles found: %s", tostring(found)))                                  -- DEBUG
    return found
end

--- Checks if the specified animation threat(s) exist
--- @param npcId integer
--- @param animId integer | integer[]
--- @param range? integer
--- @return boolean
--- @private
function PrayerFlicker:_animationExists(npcId, animId, range)
    animId = (type(animId) == "table") and animId or { animId }
    --Utils:log(string.format("Scanning NPC %d for animation %d (range %d)", npcId, animId, range or 60), "debug") -- DEBUG
    local npcs = Utils:findAll(npcId, 1, range or 60)
    if #npcs > 0 then
        for _, npc in ipairs(npcs) do
            if npc.Id then
                for _, anim in ipairs(animId) do
                    if npc.Anim == anim then
                        dbg("Animation found on NPC") -- DEBUG
                        return true
                    end
                end
            end
        end
    end
    dbg("Animation not found") -- DEBUG
    return false
end

--- Checks if the conditional threat exists
--- @param condition fun(): boolean
--- @return boolean
--- @private
function PrayerFlicker:_conditionalThreatExists(condition)
    dbg("Evaluating conditional threat")          -- DEBUG
    local result = condition and condition()
    dbg("Condition result: " .. tostring(result)) -- DEBUG
    return result
end

--- Checks if a threat with the same properties exists in the specified table
--- @param tableToCheck table The table to check (either pendingActions or another table)
--- @param threat Threat The threat to look for
--- @return boolean: True if threat already exists, false otherwise
--- @private
function PrayerFlicker:_isThreatInTable(tableToCheck, threat)
    dbg(string.format("Checking if threat exists in table: %s", threat.name or "Unnamed")) -- DEBUG
    -- Handle pendingActions special case
    local items = tableToCheck
    if tableToCheck == self.pendingActions then
        -- Process pendingActions differently since threats are nested in action.threat
        for _, action in ipairs(tableToCheck) do
            if self:_threatsMatch(action.threat, threat) then
                dbg("Threat already in pending actions") -- DEBUG
                return true
            end
        end
    else
        -- Standard table processing
        for _, existingThreat in ipairs(tableToCheck) do
            if self:_threatsMatch(existingThreat, threat) then
                dbg("Threat already exists in table") -- DEBUG
                return true
            end
        end
    end
    dbg("Threat not found in table") -- DEBUG
    return false
end

--- Helper function to compare two threats
--- @param threatA Threat First threat to compare
--- @param threatB Threat Second threat to compare
--- @return boolean: True if threats match
--- @private
function PrayerFlicker:_threatsMatch(threatA, threatB)
    dbg(string.format("Comparing threats: %s vs %s", threatA.name or "A", threatB.name or "B")) -- DEBUG
    -- Simple check if names exist and match
    if threatA.name and threatB.name then
        if threatA.name == threatB.name then
            dbg("Threat names match") -- DEBUG
            return true
        end
    end

    -- More detailed comparison based on type
    if threatA.type == threatB.type then
        if threatA.type == "Projectile" then
            local match = threatA.id == threatB.id
            dbg(string.format("Projectile ID match: %s", tostring(match))) -- DEBUG
            return match
        elseif threatA.type == "Animation" then
            local match = (threatA.npcId == threatB.npcId) and (threatA.id == threatB.id)
            dbg(string.format("Animation NPC/ID match: %s", tostring(match))) -- DEBUG
            return match
        elseif threatA.type == "Conditional" then
            local match = tostring(threatA.condition) == tostring(threatB.condition)
            dbg(string.format("Conditional function match: %s", tostring(match))) -- DEBUG
            return match
        end
    end

    dbg("Threats do not match") -- DEBUG
    return false
end

------------------------------------------
--# OVERHEAD MANAGEMENT CORE FUNCTIONS
------------------------------------------

--- Determines the prayer to use based on threat priorities
--- @return Prayer: The prayer with the highest threat priority
--- @private
function PrayerFlicker:_determinePrayer()
    dbg("Determining prayer based on threats...") -- DEBUG
    local currentTick = API.Get_tick()
    local actions     = self.pendingActions

    -- Sort threats by priority (highest first)
    table.sort(actions, function(a, b)
        return (a.threat.priority or 0) > (b.threat.priority or 0)
    end)

    if #actions > 0 then
        dbg("Evaluating " .. #actions .. " actions") -- DEBUG
        for _, action in ipairs(actions) do
            if currentTick - action.activationData.tickAdded >= action.threat.delay then
                dbg("Selected prayer: " .. action.threat.prayer.name) -- DEBUG
                return action.threat.prayer
            end
        end
    end

    dbg("No active threats, using default prayer") -- DEBUG
    return self.defaultPrayer
end

--- Switches your prayers depending on highest threat and last triggered
--- @param prayer Prayer
--- @return boolean
--- @private
function PrayerFlicker:_switchPrayer(prayer)
    dbg("Attempting to switch prayer...") -- DEBUG
    if not prayer then
        dbg("No prayer provided")         -- DEBUG
        return false
    end
    if not self:_shouldToggle(prayer) then
        dbg("Prayer toggle not required") -- DEBUG
        return false
    end

    Utils:log("Flicking to prayer: " .. prayer.name, "info") -- DEBUG
    local success = Utils:useAbility(prayer.name)

    if success then
        self.state.activePrayer = prayer
        self.state.activationTick = API.Get_tick()
        Utils:log("Prayer switched successfully to " .. prayer.name, "info") -- DEBUG
    else
        Utils:log("Failed to switch to prayer: " .. prayer.name, "warn")     -- DEBUG
    end

    return success
end

------------------------------------------
--# OVERHEAD MANAGEMENT HELPER FUNCTIONS
------------------------------------------

--- Returns the active overhead used by the player
--- @return Prayer
function PrayerFlicker:_getActivePrayer()
    dbg("Checking active prayer...") -- DEBUG
    -- Loops through required prayers
    for _, prayer in ipairs(self.prayers) do
        if Player:getBuff(prayer.id).found then
            dbg("Active prayer found: " .. prayer.name) -- DEBUG
            return prayer
        end
    end
    dbg("No active prayer detected") -- DEBUG
    return {}
end

--- Checks if prayer can be toggled (to avoid misfires)
--- @param prayer Prayer: The prayer to activate
--- @return boolean: Whether the prayer should be toggled
function PrayerFlicker:_shouldToggle(prayer)
    local currentTick = API.Get_tick()
    -- SAME prayer re-flick waits sameFlickInterval; a DIFFERENT prayer waits the
    -- short flickInterval.
    --
    -- Both arms of this used to read self.sameFlickInterval, which made the
    -- ternary decide nothing and left self.flickInterval assigned at construction
    -- and never read anywhere in the file. The effect was that swapping to a
    -- different deflect — the entire point of flicking — was gated behind the
    -- 4 tick same-prayer cooldown instead of 1, so a new incoming style could not
    -- be answered for ~3 seconds after the previous activation. That is the
    -- "prayer flicking is really behind" symptom, and no amount of loop speed
    -- could fix it: the guard below rejects the switch regardless of how often
    -- we ask.
    local flickInterval = (prayer.name == self.state.activePrayer.name) and
                              self.sameFlickInterval or self.flickInterval

    dbg(string.format("Checking toggle conditions: CurrentTick=%d, LastActivation=%d, Interval=%d",
                      currentTick, self.state.activationTick, flickInterval))

    if currentTick - self.state.activationTick > flickInterval then
        local activePrayer = self:_getActivePrayer()
        local shouldToggle = prayer.name ~= (activePrayer and activePrayer.name or "")
        dbg("Should toggle: " .. tostring(shouldToggle)) -- DEBUG
        return shouldToggle
    end

    dbg("Toggle blocked by cooldown") -- DEBUG
    return false
end

------------------------------------------
--# METRICS
------------------------------------------

--- Can be used with API.DrawTable(PrayerFlicker:tracking()) to check metrics
--- @return table
function PrayerFlicker:tracking()
    local actions = self.pendingActions
    local metrics = {
        { "Prayer Flicker:", "" },
        { "- Active",        self:_getActivePrayer() and self:_getActivePrayer().name or "None" },
        { "- Last Used",     self.state.activePrayer and self.state.activePrayer.name or "None" },
        { "- Required",      self:_determinePrayer().name },
    }

    if #actions > 0 then
        local formattedPendingActions = {}
        for i, action in ipairs(actions) do
            table.insert(formattedPendingActions, {
                string.format("-- [%d] %s", i, action.threat.prayer.name),
                string.format("[%d] Type: %s", action.activationData.tickActivated or -1, action.threat.type or "UNKNOWN")
            })
        end

        Utils:multiTableConcat(
            metrics,
            { { "- Pending Actions:", #actions .. " actions pending" } },
            formattedPendingActions
        )
    end
    return metrics
end

return PrayerFlicker

------------------------------------------
--# FIN
------------------------------------------
