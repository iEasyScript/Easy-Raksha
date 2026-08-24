--- @module "Sonson's War's Retreat"
--- @version 2.0.0
------------------------------------------
-- # IMPORTS
------------------------------------------
local API = require("api")
local Player = require("raksha.core.player")
local Utils = require("raksha.core.helper")

------------------------------------------
-- # TYPE DEFINITIONS
------------------------------------------

--- @class WarsRetreatConfig
--- @field playerManager?       PlayerManager                   Player manager instance
--- @field rotationManager?     RotationManager                 Rotation manager instance
--- @field timer?               Timer                           Timer instance for task scheduling
--- @field bossData?            BossData                        Information about the targeted boss
--- @field userSettings?        UserSettings                    User configuration settings
--- @field prebuildSettings?    PrebuildSettings
--- @field onWarning?           fun(msg: string)                Callback fired for each validation warning
--- @field onWarningsClear?     fun()                            Callback fired before re-validating to clear stale warnings

--- @class UserSettings
--- @field taskOrder?           string[]                        Ordered list of task keys (e.g., {"BANK", "ALTAR", "CRYSTAL", ...})
--- @field bankPin?             integer                         Bank PIN for accessing the player's bank
--- @field preset?              PresetData                      Preset inventory and equipment data
--- @field surgeDiveChance?     number                          Chance (0-100) to use surge/bladed dive when navigating
--- @field bankIfInvFull?       boolean                         Whether to load last preset if inventory is full
--- @field summonConjures       boolean                         Whether to summon necromancy conjures
--- @field waitForFullHp?       boolean                         Whether to wait for full Hitpoints before continuing
--- @field useAdrenCrystal?     boolean                         Whether to use the adrenaline crystals to regain adrenaline
--- @field prebuildSettings?    PrebuildSettings                Settings for prebuilding
--- @field minimumValues?       MinimumValues                   The minimum values to check for in order to execute specific steps
--- @field advancedMovement     boolean                         Whether to use surge and/or dive while navigating around War's Retreat

--- @class MinimumValues
--- @field health?              integer                         The minimum health percent to have before continuing with the next steps
--- @field prayer?              integer                         The minimum prayer percent to have before continuing with the next steps
--- @field summoning?           integer                         The minimum summoning points percent to have before continuing wiht the next steps

--- @class PresetData
--- @field inventory?           table                           Items to equip from inventory
--- @field equipment?           table                           Equipment setup
--- @field spellbook?           string                          Active spellbook
--- @field aura?                string                          Active aura
--- @field buffs?               string                          Active buffs

--- @class BossData
--- @field name                 string                          Boss name
--- @field portalId             number                          Portal object ID for the boss
--- @field portalName           string                          Portal object name for the boss

--- @class PrebuildSettings
--- @field rotation             Step[]                          The prebuild rotaion to follow
--- @field useDummy             boolean                         Whether to use a dummy for prebuilding or not

--- @class WarsRetreat
--- @field playerManager?       PlayerManager                   Player manager instance
--- @field rotationManager?     RotationManager                 Rotation manager instance
--- @field timer?               Timer                           Timer instance
--- @field bossData?            BossData                        Data regarding the boss and boss portal IDs
--- @field preset?              PresetData                      Preset inventory and equipment data
--- @field userSettings?        UserSettings                    User configuration settings
--- @field constants            table<string, table>            Constant values used by the script
--- @field variables            table<string, any>              Variables that change during script execution
--- @field tasks                table[]                         List of scheduled tasks
--- @field lastAction           string                          Last taken action
--- @field warnings             string[]                        Accumulated preset validation warnings
--- @field onWarning?           fun(msg: string)                Optional per-warning callback
--- @field onWarningsClear?     fun()                            Optional callback to clear stale warnings
--- Core methods
--- @field init                 fun(self, config?):WarsRetreat  Creates a new instance of War's Retreat
--- @field atLocation           fun(self):boolean               Whether or not the player is at War's Retreat
--- @field loadLastPreset       fun(self):boolean               Load's the last preset loaded by the player
--- @field requirePresetLoad    fun(self, required?: boolean)   Makes the next bank visit load the preset regardless of the inventory
--- @field standAtBankChest     fun(self):boolean               Stands one tile in front of the Bank chest
--- @field prayAtAltarOfWar     fun(self):boolean               Prays at the Altar of War
--- @field channelAdrenaline    fun(self):boolean               Channels adrenaline at an Adrenaline crystal
--- @field goThroughBossPortal  fun(self):boolean               Goes through the boss poral
--- @field validatePreset       fun(self):boolean               Confirm the player has inventory and equipment loaded
--- @field getDebugInfo         fun(self):table                 Confirm the player has inventory and equipment loaded
--- @field reset                fun(self)                       Resets all War's Retreat related variables
--- Private methods
--- @field _initializeConfig    fun(self, config)               Initializes all config related data
--- @field _initializeData      fun(self)                       Initializes all War's Retreat related data
--- @field _initializeBossData  fun(self)                       Initializes all boss and boss portal related data
--- @field _createTimerTasks    fun(self)                       Creates and assigns tasks to the timer instance

------------------------------------------
-- # TASK METADATA & VALIDATION
------------------------------------------

--- Task metadata defining properties and display info
--- @class TaskMetadata
--- @field key string             Task key (e.g., "BANK", "ALTAR")
--- @field step string             Step name returned by _getCurrentStep()
--- @field conditionalLoad boolean Only loaded if user setting is enabled
--- @field loadSetting string|nil  Setting name that controls loading (e.g., "summonConjures")
--- @field displayName string      User-friendly name for GUI
--- @field dependencies string[]   Suggested task keys (for warnings, not enforcement)

local TASK_METADATA = {
    BANK = {
        key = "BANK",
        step = "LOAD PRESET",
        conditionalLoad = false,
        displayName = "Bank - Load Preset",
        dependencies = {}
    },
    ALTAR = {
        key = "ALTAR",
        step = "USE ALTAR",
        conditionalLoad = false,
        displayName = "Altar - Prayer Restore",
        dependencies = {}
    },
    CRYSTAL = {
        key = "CRYSTAL",
        step = "USE CRYSTAL",
        conditionalLoad = true,
        loadSetting = "useAdrenCrystal",
        displayName = "Adrenaline Crystal",
        dependencies = {}
    },
    CONJURES = {
        key = "CONJURES",
        step = "CONJURES", -- Special: handles REFRESH/EQUIP/SUMMON internally
        conditionalLoad = true,
        loadSetting = "summonConjures",
        displayName = "Pre-Summon Conjures",
        dependencies = {}
    },
    PREBUILD = {
        key = "PREBUILD",
        step = "PREBUILD",
        conditionalLoad = true,
        loadSetting = "prebuildSettings",
        displayName = "Prebuild Rotation",
        dependencies = {}
    },
    PORTAL = {
        key = "PORTAL",
        step = "USE PORTAL",
        conditionalLoad = false,
        displayName = "Enter Boss Portal",
        dependencies = {}
    }
}

-- Default task order (matches user's requested default)
local DEFAULT_TASK_ORDER = {
    "BANK", "ALTAR", "CRYSTAL", "CONJURES", "PREBUILD", "PORTAL"
}

------------------------------------------
-- # TASK ORDER VALIDATION
------------------------------------------

--- Validates a task order and produces warnings (does NOT auto-correct).
--- Filters out conditional tasks whose settings are disabled, deduplicates,
--- and warns about common ordering mistakes.
--- @param taskOrder string[] User-provided task order
--- @param userSettings UserSettings User settings for conditional loading
--- @return string[] filteredOrder Tasks that should be loaded based on settings
--- @return string[] warnings List of validation warnings
local function validateTaskOrder(taskOrder, userSettings)
    local warnings = {}
    local filteredOrder = {}
    local seen = {}

    -- Filter tasks based on settings (conditionalLoad check)
    for _, taskKey in ipairs(taskOrder) do
        local metadata = TASK_METADATA[taskKey]

        if not metadata then
            warnings[#warnings + 1] = string.format(
                                          "Unknown task '%s' - skipped", taskKey)
            goto continue
        end

        -- Skip duplicates
        if seen[taskKey] then
            warnings[#warnings + 1] = string.format(
                                          "Duplicate task '%s' - skipped",
                                          taskKey)
            goto continue
        end

        -- Check if task should be loaded based on settings
        local shouldLoad = true
        if metadata.conditionalLoad then
            local setting = userSettings[metadata.loadSetting]
            shouldLoad = setting ~= nil and setting ~= false
        end

        if shouldLoad then
            filteredOrder[#filteredOrder + 1] = taskKey
            seen[taskKey] = true
        end

        ::continue::
    end

    -- Warn about common mistakes (but don't prevent them)
    if #filteredOrder > 0 and filteredOrder[1] ~= "BANK" then
        warnings[#warnings + 1] =
            "Warning: BANK is not first - may cause issues if inventory doesn't match preset"
    end

    if #filteredOrder > 0 and filteredOrder[#filteredOrder] ~= "PORTAL" then
        warnings[#warnings + 1] =
            "Warning: PORTAL is not last - script may complete prep but not enter boss instance"
    end

    -- Check dependency order (warn only)
    for i, taskKey in ipairs(filteredOrder) do
        local metadata = TASK_METADATA[taskKey]
        for _, depKey in ipairs(metadata.dependencies) do
            local depIndex = nil
            for j = 1, i do
                if filteredOrder[j] == depKey then
                    depIndex = j
                    break
                end
            end
            if not depIndex then
                warnings[#warnings + 1] = string.format(
                                              "Warning: %s typically requires %s to run first",
                                              metadata.displayName,
                                              TASK_METADATA[depKey].displayName)
            end
        end
    end

    return filteredOrder, warnings
end

------------------------------------------
-- # INITIALIZATION
------------------------------------------

local WarsRetreat = {}
WarsRetreat.__index = WarsRetreat

-- Expose metadata for GUI (make module-level for gui.lua to access)
WarsRetreat.TASK_METADATA = TASK_METADATA
WarsRetreat.DEFAULT_TASK_ORDER = DEFAULT_TASK_ORDER

-- Singleton instance
local instance = nil

--- Initializes a new War's Retreat instance
--- @param config? WarsRetreatConfig Configuration options
--- @return WarsRetreat: Initialized WarsRetreat instance
function WarsRetreat:init(config)
    if instance then return instance end

    -- Create new instance if none exists
    --- @type WarsRetreat
    self = setmetatable({}, WarsRetreat)
    Utils:log("Initializing War's Retreat instance", "info")

    -- Set core components from config
    config = config or {}
    self.playerManager = config.playerManager
    self.rotationManager = config.rotationManager
    self.timer = config.timer
    self.bossData = config.bossData
    self.onWarning = config.onWarning
    self.onWarningsClear = config.onWarningsClear
    self.warnings = {}

    -- Setup user settings if provided
    if config.userSettings then self:_initializeConfig(config) end

    -- Initialize constant data and variables
    self:_initializeData()

    -- Setup boss portal data if boss provided
    if self.bossData then self:_initializeBossData() end

    -- Create and register tasks if required components exist
    if self.playerManager and self.timer then self:_createTimerTasks() end

    self.lastAction = ""

    instance = self
    return instance
end

--- Configures user settings
--- @param config WarsRetreatConfig Configuration with user settings
--- @private
function WarsRetreat:_initializeConfig(config)
    local userSettings = config.userSettings or {}
    local preset = userSettings.preset or {}
    local mins = userSettings.minimumValues or {}

    self.userSettings = {
        bankPin = userSettings.bankPin or 1234,
        prebuildSettings = config.prebuildSettings,
        bankIfInvFull = userSettings.bankIfInvFull or false,
        preset = {
            inventory = preset.inventory or {},
            equipment = preset.equipment or {},
            buffs = preset.buffs or {},
            aura = preset.aura or {},
            spellbook = preset.spellbook or {}
        },
        advancedMovement = userSettings.advancedMovement or false,
        surgeDiveChance = userSettings.surgeDiveChance or 0,
        useAdrenCrystal = userSettings.useAdrenCrystal,
        summonConjures = userSettings.summonConjures or false,
        waitForFullHp = userSettings.waitForFullHp or false,
        minimumValues = {
            prayer = mins.prayer or 80,
            summoning = mins.summoning or 80,
            health = mins.health or 80
        },
        -- Task order (validate and filter based on settings)
        taskOrder = userSettings.taskOrder or DEFAULT_TASK_ORDER
    }

    -- Validate task order
    local filtered, warnings = validateTaskOrder(self.userSettings.taskOrder,
                                                 self.userSettings)
    self.userSettings.taskOrder = filtered

    -- Pre-compute priority map: first task = highest priority
    local priorities = {}
    for i, key in ipairs(filtered) do
        priorities[key] = (#filtered - i + 1) * 10
    end
    self.taskPriorities = priorities

    -- Store warnings for GUI display
    self.taskOrderWarnings = warnings

    -- Log warnings
    if #warnings > 0 then
        Utils:log("Task order validation warnings:", "warn")
        for _, warning in ipairs(warnings) do
            Utils:log("  - " .. warning, "warn")
        end
    end
end

--- Initializes constant values and variables
--- @private
function WarsRetreat:_initializeData()
    Utils:log("Starting data initialization", "info")
    ---@diagnostic disable: undefined-global
    -- Constants
    self.constants = {
        -- Location data
        LOCATION = {
            name = "War's Retreat",
            coords = WPOINT.new(3295, 10137, 0),
            range = 30
        },
        -- Object data
        OBJECTS = {
            BANK_CHEST = {name = "Bank chest", id = 114750, type = 0},
            ALTAR_OF_WAR = {name = "Altar of War", id = 114748, type = 0},
            BOSS_PORTAL = {
                name = self.bossData and self.bossData.portalName or "NONE",
                id = self.bossData and self.bossData.portalId or nil,
                type = 0
            },
            ADRENALINE_CRYSTAL = {
                name = "Adrenaline crystal",
                id = 114749,
                type = 12
            },
            CAMPFIRE = {
                name = "Campfire",
                id = {
                    114756, 114758, 114755, 114752, 114754, 114757, 114753,
                    131888
                },
                type = 0
            },
            TRAINING_DUMMY = {name = "Training Dummy", id = 16027, type = 1}
        },
        -- Key tiles for navigation
        TILES = {
            POSITIONING = WPOINT.new(3299, 10131, 0),
            ALTAR = WPOINT.new(3304, 10129, 0),
            STAIRS = WPOINT.new(3294, 10136, 0),
            EXIT_PORTAL = WPOINT.new(3294, 10127, 9),
            CRYSTAL_WEST = WPOINT.new(3290, 10148, 0),
            CRYSTAL_EAST = WPOINT.new(3298, 10148, 0),
            PORTAL_WEST = WPOINT.new(3290, 10153, 0),
            PORTAL_EAST = WPOINT.new(3298, 10153, 0)
        },
        -- Relevant IDs
        IDS = {
            ADRENALINE_PREVENTION = 26094,
            CONJURE_SUMMONING_ANIMATION = 35502,
            PRAY_AT_ALTAR_ANIMATION = 22755,
            CRYSTAL_CHANNEL_ANIMS = {27668, 27669}
        },
        -- Conjure buff IDs
        CONJURE_IDS = {
            ZOMBIE = 34177,
            GHOST = 34178,
            SKELETON = 34179
        }
    }
    ---@diagnostic enable: undefined-global

    -- Variables
    self.variables = {
        bankAttempts = 0,
        conjureAttempts = 0,
        portalSide = nil,
        ---@diagnostic disable-next-line: undefined-global
        crystalDiveCoords = WPOINT.new(0, 0, 0),
        ---@diagnostic disable-next-line: undefined-global
        portalDiveCoords = WPOINT.new(0, 0, 0),
        -- Cached advanced movement decision for this reset cycle
        useAdvMovement = false,
        -- True when player is walking to positioning tile for surge/dive combo
        positioning = false,
        -- True once preset items have been validated after banking
        _presetValidated = false,
        -- Altar visits made during THIS stay at War's Retreat. Cleared on
        -- leaving — see _syncTripState.
        altarVisits = 0,
        -- Tick the pray interaction went out, while a visit is in flight. Non
        -- nil means "still waiting on the altar" — see _checkAltarCondition.
        altarPrayTick = nil,
        -- Consecutive interactions that never went out, and which object they
        -- were against — see _recoverFailedInteract.
        interactFails = {what = nil, count = 0},
        -- Mandatory preset load pending — see requirePresetLoad. Deliberately
        -- survives reset(); cleared only once the load is confirmed.
        presetLoadRequired = false,
        presetLoadSentTick = nil,
        -- Per-tick _getCurrentStep() memo — see _getCurrentStep.
        _stepCache = nil,
        _stepCacheTick = -1
    }
    self:_rollAdvancedMovement()
    Utils:log("Data initialization completed", "info")
end

--- Rolls the advanced movement decision for this cycle.
--- @private
function WarsRetreat:_rollAdvancedMovement()
    if not self.userSettings or not self.userSettings.advancedMovement then
        self.variables.useAdvMovement = false
        return
    end
    local roll = math.random(1, 100)
    local chance = self.userSettings.surgeDiveChance or 0
    self.variables.useAdvMovement = roll <= chance
    Utils:log(string.format("Advanced movement: roll %d/%d -> %s", roll, chance,
                            self.variables.useAdvMovement and "enabled" or "disabled"))
end

--- Initialize boss and portal data
--- @private
function WarsRetreat:_initializeBossData()
    if not self.constants.OBJECTS.BOSS_PORTAL.id then return end
    if not self:atLocation() then return end

    local portalObj = self.constants.OBJECTS.BOSS_PORTAL
    local portal = Utils:find(portalObj.id, portalObj.type, 60)

    if not portal then
        Utils:terminate(portalObj.name .. " not found.")
        return
    end

    -- Determine portal side and set dive coordinates
    self.variables.portalSide = math.floor(portal.Tile_XYZ.x) == 3298 and
                                    "East" or "West"

    local tiles = self.constants.TILES
    local isWest = self.variables.portalSide == "West"
    self.variables.crystalDiveCoords = isWest and tiles.CRYSTAL_WEST or tiles.CRYSTAL_EAST
    self.variables.portalDiveCoords = isWest and tiles.PORTAL_WEST or tiles.PORTAL_EAST

    Utils:log(string.format("Portal side initialized: %s",
                            self.variables.portalSide))
end

------------------------------------------
-- # CORE FUNCTIONALITY
------------------------------------------

--- Clears the per-stay counters once we've left War's Retreat.
---
--- This is the trip boundary, and it lives here rather than in reset() because
--- reset() is not called on a normal trip by every caller — raksha/main.lua only
--- calls it during death recovery. Anything latched against reset() would
--- therefore stick for the rest of the session, which is precisely how
--- bankAttempts came to terminate the script on the third bank.
--- @param here boolean Whether we are currently at War's Retreat
--- @private
function WarsRetreat:_syncTripState(here)
    if here or not self.variables then return end
    self.variables.altarVisits = 0
    self.variables.bankAttempts = 0
    -- Any altar visit still in flight died with the trip.
    self.variables.altarPrayTick = nil
    self:_clearInteractFails()
    self.variables._stepCache = nil
    self.variables._stepCacheTick = -1
end

--- Checks if player is at War's Retreat
--- @return boolean: True if player is at War's Retreat
function WarsRetreat:atLocation()
    if not self.constants then return false end

    local here = Player:isAtCoordWithRadius(self.constants.LOCATION.coords,
                                            self.constants.LOCATION.range)
    self:_syncTripState(here)
    return here
end

--- Attempts to load last preset from bank
--- @return boolean: True if preset loading was attempted
function WarsRetreat:loadLastPreset()
    if self.variables.bankAttempts >= 3 then
        Utils:terminate("Failed to load preset after 3 attempts")
        return false
    end

    -- Handle bank pin if the interface is open
    API.DoBankPin(self.userSettings.bankPin)

    ---@diagnostic disable: missing-parameter
    if Interact:Object(self.constants.OBJECTS.BANK_CHEST.name,
    "Load Last Preset from") then
        self.variables.bankAttempts = self.variables.bankAttempts + 1
        return true
    end
    return false
end

--- Makes the next visit to the bank chest load the preset, whatever the
--- inventory currently looks like.
---
--- For the cases where the inventory is not evidence of anything. The one that
--- drives it is a BROKEN READ: the client sometimes hands back an inventory
--- array that is null or has something other than 28 slots, and from then on
--- every inventory check in the script is answering from garbage. Reloading the
--- preset rebuilds the container, which is what actually clears it.
---
--- Idempotent. Re-asserting a requirement that is already outstanding does
--- nothing, because the caller is a watchdog on a timer and would otherwise keep
--- restarting the confirmation clock below and stop it ever completing.
---
--- Deliberately survives reset(): the requirement outlives whatever went wrong,
--- and reset() is precisely the call a recovery path makes on its way back.
--- @param required? boolean Defaults to true; pass false to cancel a pending requirement
function WarsRetreat:requirePresetLoad(required)
    if required == nil then required = true end
    if required and self.variables.presetLoadRequired then return end

    self.variables.presetLoadRequired = required
    self.variables.presetLoadSentTick = nil

    if required then
        Utils:log("Preset load required at the next bank visit", "info")
    end
end

--- Moves player to bank chest position
--- @return boolean: True if movement was initiated
function WarsRetreat:standAtBankChest()
    return API.DoAction_WalkerW(self.constants.TILES.POSITIONING)
end

--- Performs prayer action at altar
--- @return boolean: True if prayer interaction was successful
function WarsRetreat:prayAtAltarOfWar()
    ---@diagnostic disable-next-line: missing-parameter
    return Interact:Object(self.constants.OBJECTS.ALTAR_OF_WAR.name, "Pray") or false
end

--- Interacts with the adrenaline crystal closest to boss portal
--- @return boolean: True if crystal interaction was successful
function WarsRetreat:channelAdrenaline()
    return Interact:Object(self.constants.OBJECTS.ADRENALINE_CRYSTAL.name,
                           "Channel", self.variables.crystalDiveCoords) or false
end

--- Goes through the boss portal
--- @return boolean: True if portal interaction was successful
function WarsRetreat:goThroughBossPortal()
    assert(self.constants.OBJECTS.BOSS_PORTAL.id, "No boss portal specified")

    return Interact:Object(self.constants.OBJECTS.BOSS_PORTAL.name, "Enter") or false
end
---@diagnostic enable

--- Handles an interaction that never actually went out.
---
--- Interact:Object returns false when the client's object scan cannot find the
--- object near us — "DoAction_Object_r:nothing at tile" in the log. Two things
--- then have to happen or the script simply stops dead:
---
---   * We have to MOVE. The scan failing means we are not close enough, and
---     retrying from the same tile fails identically forever. Nothing else
---     moves us either: _navigateToBank and _navigateForAltar both check a 30
---     tile range, which covers the whole of War's Retreat, so they consider us
---     "in range" from the moment we arrive and never walk us anywhere.
---
---   * The task has to report SUCCESS. Timer:_execute only starts a task's
---     cooldown when the action returns true, so returning false re-fires the
---     task on every single loop iteration. Each of those iterations re-runs
---     _getCurrentStep() and with it a full inventory comparison, which is
---     where the wall of "Unexpected inventory size" came from — and because no
---     click ever reached the game, the account idled out while the script
---     looked busy.
---
--- Returning true here is therefore the fix, not a lie: walking IS the action.
--- @param tile WPOINT Tile to walk to
--- @param what string Name of the object, for the log
--- @return boolean Always true, so the caller's cooldown engages
--- @private
function WarsRetreat:_recoverFailedInteract(tile, what)
    local fails = self.variables.interactFails

    -- The streak is per object. Switching targets ends the previous streak, and
    -- carrying it over would spend one step's patience on another's behalf.
    if fails.what ~= what then
        fails.what = what
        fails.count = 0
    end
    fails.count = fails.count + 1

    self.lastAction = "Walking to " .. what
    Utils:log(string.format(
                  "%s interaction did not go out (%d in a row) — walking to it and retrying",
                  what, fails.count), "warn")

    if not Player:isMoving() then API.DoAction_WalkerW(tile) end
    return true
end

--- Ends the current failed-interaction streak.
--- @private
function WarsRetreat:_clearInteractFails()
    self.variables.interactFails.what = nil
    self.variables.interactFails.count = 0
end

--- Resets all War's Retreat variables
function WarsRetreat:reset()
    local variables = self.variables
    variables.bankAttempts = 0
    variables.conjureAttempts = 0
    self.lastAction = ""
    variables.positioning = false
    variables._presetValidated = false
    variables.altarVisits = 0
    variables.altarPrayTick = nil
    self:_clearInteractFails()
    variables._stepCache = nil
    variables._stepCacheTick = -1
    self.warnings = {}

    -- presetLoadRequired and presetLoadSentTick are deliberately NOT cleared.
    -- A pending mandatory bank has to outlive the reset a recovery path performs
    -- on its way back here — clearing it would cancel the requirement at exactly
    -- the moment it is needed. See requirePresetLoad.

    self:_rollAdvancedMovement()
end

--- Returns debug information for GUI display
--- @return table Debug data
function WarsRetreat:getDebugInfo()
    local currentStep = self:_getCurrentStep()
    local taskOrder = self.userSettings.taskOrder or DEFAULT_TASK_ORDER
    local priorities = self.taskPriorities or {}

    -- Build task order display with status and priority
    local taskOrderDisplay = {}
    for i, taskKey in ipairs(taskOrder) do
        local metadata = TASK_METADATA[taskKey]
        if metadata then
            taskOrderDisplay[i] = {
                index = i,
                key = taskKey,
                name = metadata.displayName,
                step = metadata.step,
                priority = priorities[taskKey] or 0,
                active = (metadata.step == currentStep) or
                    (taskKey == "CONJURES" and
                        (currentStep == "REFRESH CONJURES" or currentStep ==
                            "EQUIP LANTERN" or currentStep == "SUMMON CONJURES"))
            }
        end
    end

    return {
        currentStep = currentStep,
        lastAction = self.lastAction or "None",
        atLocation = self:atLocation(),
        taskOrder = taskOrderDisplay,
        variables = {
            bankAttempts = self.variables.bankAttempts,
            conjureAttempts = self.variables.conjureAttempts,
            portalSide = self.variables.portalSide or "Unknown",
            useAdvMovement = self.variables.useAdvMovement,
            positioning = self.variables.positioning,
            presetValidated = self.variables._presetValidated
        },
        settings = {
            summonConjures = self.userSettings.summonConjures,
            useAdrenCrystal = self.userSettings.useAdrenCrystal,
            waitForFullHp = self.userSettings.waitForFullHp,
            bankIfInvFull = self.userSettings.bankIfInvFull,
            advancedMovement = self.userSettings.advancedMovement,
            surgeDiveChance = self.userSettings.surgeDiveChance
        },
        checks = {
            inventoryMatches = self:_inventoryMatchCheck(),
            prayerPercent = Player:getPrayerPercent(),
            summoningPercent = Player:getSummoningPointsPercent(),
            healthPercent = Player:getHpPercent(),
            adrenaline = Player:getAdrenaline(),
            maxAdrenaline = Player:getMaxAdrenaline(),
            hasActiveSummons = self:_hasActiveSummons(),
            shouldRefreshConjures = self.userSettings.summonConjures and
                self:_shouldRefreshConjures() or false
        }
    }
end

------------------------------------------
-- # TASK MANAGEMENT
------------------------------------------

--- Creates and registers timer tasks
--- @private
function WarsRetreat:_createTimerTasks()
    -- Helper: get priority for a task key, with optional sub-offset for multi-step tasks
    local priorities = self.taskPriorities or {}
    local function pri(key, subOffset)
        return (priorities[key] or 0) - (subOffset or 0)
    end

    self.tasks = {
        -- Navigate around War's Retreat depending on the player's needs and instance settings
        {
            name = "Navigate",
            cooldown = 0,
            parallel = true,
            condition = function() return self:atLocation() end,
            action = function()
                local step = self:_getCurrentStep()
                return self:_handleNavigation(step)
            end,
            load = true
        }, -- Task: Load last preset
        {
            name = "Load last preset",
            priority = pri("BANK"),
            cooldown = 10,
            useTicks = true,
            condition = function()
                return self:atLocation() and
                           (self:_getCurrentStep() == "LOAD PRESET")
            end,
            action = function()
                self.lastAction = "Loading last preset"

                if not self:loadLastPreset() then
                    return self:_recoverFailedInteract(
                               self.constants.TILES.POSITIONING,
                               self.constants.OBJECTS.BANK_CHEST.name)
                end

                self:_clearInteractFails()
                -- Starts the confirmation clock for a forced load, on the first
                -- attempt only — re-stamping on every retry would let it extend
                -- its own window instead of bounding it.
                if self.variables.presetLoadRequired and
                    not self.variables.presetLoadSentTick then
                    self.variables.presetLoadSentTick = API.Get_tick()
                end
                return true
            end,
            load = true
        }, -- Task: Pray at Altar of War
        {
            name = "Pray at Altar of War",
            priority = pri("ALTAR"),
            cooldown = 10,
            useTicks = true,
            condition = function()
                return self:atLocation() and
                           (self:_getCurrentStep() == "USE ALTAR")
            end,
            action = function()
                -- Never re-issue over our own prayer animation — that is the
                -- restore happening, and clicking through it starts the
                -- interaction again from scratch.
                if Player:getAnimation() ==
                    self.constants.IDS.PRAY_AT_ALTAR_ANIMATION then
                    return false
                end

                self.lastAction = "Using Altar of War"

                if not self:prayAtAltarOfWar() then
                    return self:_recoverFailedInteract(
                               self.constants.TILES.ALTAR,
                               self.constants.OBJECTS.ALTAR_OF_WAR.name)
                end

                self:_clearInteractFails()
                -- Counts the visit only when the interaction actually went out,
                -- so a failed click doesn't spend our one trip to the altar.
                self.variables.altarVisits = self.variables.altarVisits + 1
                -- Opens the wait window. _checkAltarCondition holds the step
                -- here until the prayer lands or the wait times out.
                self.variables.altarPrayTick = self.variables.altarPrayTick or
                                                   API.Get_tick()
                return true
            end,
            delay = 300,
            delayTicks = false,
            load = true
        }, -- Task: Interact with adrenaline crystal
        {
            name = "Interacting with adrenaline crystal",
            priority = pri("CRYSTAL"),
            cooldown = 10,
            useTicks = true,
            condition = function()
                return self:atLocation() and
                           (self:_getCurrentStep() == "USE CRYSTAL")
            end,
            action = function()
                if self.variables.positioning then return false end
                local anims = self.constants.IDS.CRYSTAL_CHANNEL_ANIMS
                if self:_isPlayerByCrystals(30) and
                    not (Player:getAnimation() == anims[1] or Player:getAnimation() ==
                        anims[2]) then
                    self.lastAction = "Interacting with Adrenaline crystal"
                    return self:channelAdrenaline()
                end
            end,
            load = self.bossData ~= nil
        }, -- Task: Dismiss conjures when needed
        {
            name = "Dismissing conjures",
            priority = pri("CONJURES", 0),
            cooldown = 3,
            useTicks = true,
            condition = function()
                return self:atLocation() and
                           (self:_getCurrentStep() == "REFRESH CONJURES")
            end,
            action = function()
                if self.variables.positioning then return false end
                self.lastAction = "Unequipping lantern"
                return self:_unequipLantern()
            end,
            load = self.userSettings.summonConjures
        }, -- Task: Equip lantern for conjures
        {
            name = "Equipping lantern",
            priority = pri("CONJURES", 1),
            cooldown = 3,
            useTicks = true,
            condition = function()
                return self:atLocation() and
                           (self:_getCurrentStep() == "EQUIP LANTERN")
            end,
            action = function()
                if self.variables.positioning then return false end
                self.lastAction = "Equipping lantern"
                return self:_equipLantern()
            end,
            delay = 1,
            delayTicks = true,
            load = self.userSettings.summonConjures
        }, -- Task: Summon conjures
        {
            name = "Summoning conjures",
            priority = pri("CONJURES", 2),
            cooldown = 3,
            useTicks = true,
            condition = function()
                return self:atLocation() and
                           (self:_getCurrentStep() == "SUMMON CONJURES")
            end,
            action = function()
                if self.variables.positioning then return false end
                if self:_isPlayerByCrystals(10) then
                    self.lastAction = "Conjuring Undead Army"
                    return Utils:useAbility("Conjure Undead Army")
                end
            end,
            disabledWhenOnCooldown = true,
            load = self.userSettings.summonConjures
        }, {
            name = "Prebuild",
            priority = pri("PREBUILD"),
            cooldown = 0,
            parallel = true,
            condition = function()
                return self:atLocation() and
                           (self:_getCurrentStep() == "PREBUILD")
            end,
            action = function()
                if self.variables.positioning then return false end
                self.lastAction = "Prebuilding"
                self.rotationManager:load(
                    self.userSettings.prebuildSettings.rotation)
                self.rotationManager:execute()
                return true
            end,
            load = self.userSettings.prebuildSettings
        }, -- Task: Go through boss portal
        {
            name = "Go through boss portal",
            priority = pri("PORTAL"),
            cooldown = 1,
            useTicks = true,
            condition = function()
                return self:atLocation() and
                           (self:_getCurrentStep() == "USE PORTAL")
            end,
            action = function()
                if self.variables.positioning then return false end
                if self:_isPlayerByBossPortal(30) and not Player:isMoving() then
                    self.lastAction = "Going through boss portal"
                    return self:goThroughBossPortal()
                end
                return false
            end,
            load = self.bossData ~= nil
        }
    }

    -- Assign tasks to the timer
    if self.timer then
        for _, task in pairs(self.tasks) do
            if task.load then self.timer:addTask(task) end
        end
    end
end

------------------------------------------
-- # BUFF CACHE
------------------------------------------

--- Refreshes the per-tick buff/debuff cache to avoid redundant API calls.
--- Must be called once at the start of each tick before any buff checks.
--- @private
function WarsRetreat:_updateBuffCache()
    local ids = self.constants.CONJURE_IDS
    local cache = {}
    cache[ids.ZOMBIE] = Player:getBuff(ids.ZOMBIE)
    cache[ids.GHOST] = Player:getBuff(ids.GHOST)
    cache[ids.SKELETON] = Player:getBuff(ids.SKELETON)
    cache[self.constants.IDS.ADRENALINE_PREVENTION] =
        Player:getDebuff(self.constants.IDS.ADRENALINE_PREVENTION)
    self.variables._buffCache = cache
end

--- Returns cached buff result for a given ID (falls back to live lookup)
--- @param id number Buff/debuff ID
--- @return table Buff result with .found and .remaining fields
--- @private
function WarsRetreat:_getCachedBuff(id)
    local cache = self.variables._buffCache
    if cache and cache[id] then return cache[id] end
    return Player:getBuff(id)
end

--- Returns cached debuff result for a given ID (falls back to live lookup)
--- @param id number Debuff ID
--- @return table Debuff result with .found field
--- @private
function WarsRetreat:_getCachedDebuff(id)
    local cache = self.variables._buffCache
    if cache and cache[id] then return cache[id] end
    return Player:getDebuff(id)
end

------------------------------------------
-- # STEP CONDITION CHECKS
------------------------------------------

--- Ticks a forced preset load is given to land before the inventory is believed.
---
--- The click only starts a walk to the chest. Reading the inventory straight
--- after it reads the state we already had, and if that happened to satisfy the
--- match check we would clear the requirement and walk away mid-interaction.
local FORCED_LOAD_SETTLE_TICKS = 10

--- Checks if preset needs loading. Returns step string or nil.
--- @return string|nil
--- @private
function WarsRetreat:_checkLoadPresetCondition()
    -- An outstanding forced load outranks the inventory check outright — that is
    -- the whole point of it, since the inventory is what we have decided not to
    -- trust. It clears only once we have actually banked AND the inventory reads
    -- back clean, so a broken read can never satisfy it.
    if self.variables.presetLoadRequired then
        local sentAt = self.variables.presetLoadSentTick
        local settled = sentAt and
                            (API.Get_tick() - sentAt) >= FORCED_LOAD_SETTLE_TICKS

        if settled and self:_inventoryMatchCheck() then
            self.variables.presetLoadRequired = false
            self.variables.presetLoadSentTick = nil
            -- Those attempts counted against the three-strike guard in
            -- loadLastPreset(). The load is done, so they must not carry into
            -- the next trip and terminate the script there.
            self.variables.bankAttempts = 0
            Utils:log("Forced preset load complete", "info")
        else
            return "LOAD PRESET"
        end
    end

    -- Inventory:IsFull(), not API.InvFull_(): the latter was removed from
    -- api.lua as of 1.077 and would resolve to nil here. Short-circuiting on
    -- bankIfInvFull has been hiding it — the call only happens when that setting
    -- is on, so scripts running with it off never hit the error.
    if not self:_inventoryMatchCheck() or
        (self.userSettings.bankIfInvFull and Inventory:IsFull()) then
        -- Validate preset items once after successful load
        if not self.variables._presetValidated and
            self.variables.bankAttempts > 0 then
            self:_validatePresetItems()
            self.variables._presetValidated = true
        end
        return "LOAD PRESET"
    end

    -- Inventory matches the preset, so banking is DONE and the attempt counter
    -- has to go back to zero.
    --
    -- Without this, bankAttempts only ever counted upwards: it is incremented on
    -- every "Load Last Preset from" interaction and reset nowhere except init()
    -- and reset() — and raksha/main.lua only calls reset() during death
    -- recovery. So it survived across trips, and on the THIRD bank of a session
    -- loadLastPreset() hit its `>= 3` guard and called
    -- Utils:terminate("Failed to load preset after 3 attempts"), which is the
    -- "Script executed successfully" exit. The preset was loading fine every
    -- time; the counter was simply never cleared.
    --
    -- Zeroing it here gives it the meaning its own error message claims —
    -- CONSECUTIVE failed attempts — instead of a lifetime total.
    --
    -- _afterAdvancedMove() already did exactly this, which is why the bug is
    -- Raksha-shaped: its config runs with AdvancedMovement off, so that reset
    -- never fired and nothing else cleared the counter.
    self.variables.bankAttempts = 0

    -- Wait for full HP immediately after banking if enabled
    if self.userSettings.waitForFullHp and Player:getHpPercent() <
        self.userSettings.minimumValues.health then
        return "HEALING"
    end

    return nil
end

--- Most trips to the altar we will make in one visit to War's Retreat.
---
--- One, because that is what a human does and what the altar is worth. If the
--- points still read below the minimum afterwards we carry on to the bank and
--- the portal anyway — starting a kill a few percent short is trivial next to
--- the alternative, which was an altar <-> bank shuffle that burned the bank
--- attempt counter and terminated the script.
local ALTAR_MAX_VISITS = 1

--- Prayer reading that counts as a finished restore. The altar tops prayer up in
--- full, so anything short of this means the prayer has not landed yet.
local ALTAR_PRAYER_FULL = 100

--- Ticks a visit is given before its result is believed at all.
---
--- prayAtAltarOfWar() only SENDS the interaction — the walk across War's Retreat
--- and the prayer animation both still have to happen. Reading prayer straight
--- after the click reads the value we already had.
local ALTAR_MIN_TICKS = 5

--- Ticks after which we stop waiting on the altar and carry on regardless.
---
--- The visit can legitimately never complete: the click can be eaten, the walk
--- can be interrupted, and prayer can sit a point below full. Starting a kill
--- slightly short is trivial next to standing at the altar for the rest of the
--- session, so the wait is bounded.
local ALTAR_TIMEOUT_TICKS = 30

--- Failed pray interactions before the altar is written off for this trip.
---
--- ALTAR_TIMEOUT_TICKS only bounds a visit that STARTED — it keys off
--- altarPrayTick, which is never stamped when the click doesn't go out at all.
--- An altar the object scan can't find would otherwise loop here forever, and
--- the altar is the one step we can do without: the points check carries us on
--- to the bank and the portal regardless.
local ALTAR_MAX_INTERACT_FAILS = 3

--- Whether the altar visit currently in flight has finished.
---
--- PRAYER, and only prayer, is the completion signal. It is what the altar is
--- for and it is restored in full, so it reads unambiguously. Summoning is
--- deliberately not part of this: getSummoningPointsPercent() FLOORS, so the
--- default minimum of 100 sits at 99 on a single point of drift — as a trigger
--- that costs one wasted altar trip, but as a completion gate it would pin us
--- here until the timeout on every single kill.
--- @return boolean
--- @private
function WarsRetreat:_altarVisitDone()
    local elapsed = API.Get_tick() - self.variables.altarPrayTick

    if elapsed < ALTAR_MIN_TICKS then return false end

    if Player:getPrayerPercent() >= ALTAR_PRAYER_FULL then return true end

    if elapsed >= ALTAR_TIMEOUT_TICKS then
        Utils:log(string.format(
                      "Altar did not restore prayer within %d ticks (at %d%%) — moving on",
                      ALTAR_TIMEOUT_TICKS, Player:getPrayerPercent()), "warn")
        return true
    end

    return false
end

--- Checks if altar is needed. Returns step string or nil.
---
--- Points are the ONLY reason to go. If prayer and summoning are both topped up,
--- the altar has nothing left to give us and we skip it.
---
--- This used to also OR in `_whitelistCooldownCheck()` — true whenever Death
--- Skulls, Living Death, Split Soul, Berserk or Overpower was on cooldown, on
--- the basis that the altar resets those too. That is what produced the
--- altar -> bank -> altar shuffle on full prayer: the ultimate was still on
--- cooldown after the first visit, so the condition stayed true and sent us
--- back to an altar that had nothing to offer. The check is gone, along with the
--- WHITELIST it read, because nothing else used either.
---
--- Losing it costs nothing in practice: a kill leaves prayer well below the
--- threshold, so the points check sends us to the altar anyway and the cooldown
--- reset comes along for free.
---
--- Capped at ALTAR_MAX_VISITS per trip on top of that. Points alone were still
--- enough to bounce us back: `minSummoning` defaults to 100, i.e. EXACTLY full,
--- and getSummoningPointsPercent() floors — so a single point of drift reads as
--- 99 and sends us straight back to the altar after banking. Whether the altar
--- can even restore that is beside the point; a second visit that changes
--- nothing is a loop, and this loop was fatal (see the bankAttempts note in
--- _checkLoadPresetCondition).
--- @return string|nil
--- @private
function WarsRetreat:_checkAltarCondition()
    local minimums = self.userSettings.minimumValues

    -- A visit already under way OWNS the step until the prayer actually lands.
    --
    -- This is the whole reason the altar used to do nothing. altarVisits was
    -- incremented the moment the click went OUT, which immediately took this
    -- check to its cap and handed the step on — so navigation walked us off to
    -- the bank while we were still on our way to the altar, and we reached the
    -- portal on whatever prayer the last kill left us.
    if self.variables.altarPrayTick then
        if not self:_altarVisitDone() then return "USE ALTAR" end
        self.variables.altarPrayTick = nil
        return nil
    end

    if self.variables.altarVisits >= ALTAR_MAX_VISITS then return nil end

    -- An altar we cannot get a click into is written off rather than retried
    -- forever. See ALTAR_MAX_INTERACT_FAILS.
    local fails = self.variables.interactFails
    if fails.what == self.constants.OBJECTS.ALTAR_OF_WAR.name and fails.count >=
        ALTAR_MAX_INTERACT_FAILS then
        return nil
    end

    if (Player:getPrayerPercent() < minimums.prayer) or
        (Player:getSummoningPointsPercent() < minimums.summoning) then
        return "USE ALTAR"
    end

    return nil
end

--- Checks if crystal is needed. Returns step string, "SKIP" to continue iteration, or nil.
--- @return string|nil
--- @private
function WarsRetreat:_checkCrystalCondition()
    if ((Player:getAdrenaline() < Player:getMaxAdrenaline()) or
        self:_getCachedDebuff(self.constants.IDS.ADRENALINE_PREVENTION).found) and
        (self.bossData ~= nil) then
        -- Skip crystal if prebuild is active and not complete
        local prebuild = self.userSettings.prebuildSettings ~= nil
        if prebuild and (self.rotationManager.index ~= 1) and
            (self.rotationManager.index <=
                #self.userSettings.prebuildSettings.rotation) then
            return "SKIP"
        end
        return "USE CRYSTAL"
    end
    return nil
end

--- Checks conjure state. Returns the appropriate sub-step or nil.
--- @return string|nil
--- @private
function WarsRetreat:_checkConjuresCondition()
    if self:_hasActiveSummons() and self:_shouldRefreshConjures() then
        return "REFRESH CONJURES"
    elseif self:_checkForItem("lantern") and not self:_hasActiveSummons() then
        return "EQUIP LANTERN"
    elseif not self:_hasActiveSummons() and
        not (Player:getAnimation() ==
            self.constants.IDS.CONJURE_SUMMONING_ANIMATION) then
        return "SUMMON CONJURES"
    end
    return nil
end

--- Checks if prebuild is needed. Returns step string or nil.
--- @return string|nil
--- @private
function WarsRetreat:_checkPrebuildCondition()
    local prebuildSettings = self.userSettings.prebuildSettings
    if prebuildSettings and self.rotationManager.index <=
        #prebuildSettings.rotation then
        return "PREBUILD"
    end
    return nil
end

--- Checks if portal entry is ready. Returns step string or nil.
--- @return string|nil
--- @private
function WarsRetreat:_checkPortalCondition()
    if self.bossData and self.bossData.portalId then
        return "USE PORTAL"
    end
    return nil
end

------------------------------------------
-- # STEP RESOLUTION
------------------------------------------

--- Returns the appropriate step based on user-defined task order
---
--- Memoised per game tick. Every War's Retreat task calls this from its
--- CONDITION, and Timer:run() evaluates every condition at the top of each
--- cycle, so one pass used to resolve the step five or six times over — and
--- _checkLoadPresetCondition walks the whole preset with two container reads per
--- item id every time it is asked. That is the actual source of the "Unexpected
--- inventory size" wall in the log: not one broken read, but the same handful of
--- reads repeated at loop speed. Answering once per tick collapses it without
--- changing a single decision, since nothing the checks read moves faster than
--- the game clock anyway.
--- @return string Step name indicating the current action to be taken
function WarsRetreat:_getCurrentStep()
    if not self:atLocation() then return "UNKNOWN" end

    local tick = API.Get_tick()
    if self.variables._stepCacheTick == tick and self.variables._stepCache then
        return self.variables._stepCache
    end

    local step = self:_resolveCurrentStep()
    self.variables._stepCache = step
    self.variables._stepCacheTick = tick
    return step
end

--- Works out the current step from scratch. Call _getCurrentStep, not this.
--- @return string
--- @private
function WarsRetreat:_resolveCurrentStep()
    -- Refresh buff cache for this tick
    self:_updateBuffCache()

    -- Step condition dispatch table
    local stepChecks = {
        ["LOAD PRESET"] = self._checkLoadPresetCondition,
        ["USE ALTAR"] = self._checkAltarCondition,
        ["USE CRYSTAL"] = self._checkCrystalCondition,
        ["CONJURES"] = self._checkConjuresCondition,
        ["PREBUILD"] = self._checkPrebuildCondition,
        ["USE PORTAL"] = self._checkPortalCondition
    }

    -- Iterate through user-defined order and return first step whose condition is met
    local taskOrder = self.userSettings.taskOrder or DEFAULT_TASK_ORDER
    for _, taskKey in ipairs(taskOrder) do
        local metadata = TASK_METADATA[taskKey]
        if not metadata then goto continue end

        local checker = stepChecks[metadata.step]
        if checker then
            local result = checker(self)
            if result == "SKIP" then
                goto continue
            elseif result then
                return result
            end
        end

        ::continue::
    end

    -- Fallback: HEALING if waitForFullHp is enabled and HP below threshold
    if self.userSettings.waitForFullHp and Player:getHpPercent() <
        self.userSettings.minimumValues.health then return "HEALING" end

    return "UNKNOWN"
end

------------------------------------------
-- # LOCATION CHECKS
------------------------------------------

--- Generic proximity check against a tile
--- @param tile WPOINT Target tile to check distance against
--- @param range number Maximum distance from tile
--- @return boolean: True if player is within range of tile
--- @private
function WarsRetreat:_isPlayerNear(tile, range)
    return Player:isAtCoordWithRadius(tile, range)
end

--- @private
function WarsRetreat:_isPlayerByBankChest(range)
    return self:_isPlayerNear(self.constants.TILES.POSITIONING, range or 1)
end

--- @private
function WarsRetreat:_isPlayerByAltar(range)
    return self:_isPlayerNear(self.constants.TILES.ALTAR, range or 3)
end

--- @private
function WarsRetreat:_isPlayerByStairs(range)
    return self:_isPlayerNear(self.constants.TILES.STAIRS, range or 2)
end

--- @private
function WarsRetreat:_isPlayerByCrystals(range)
    return self:_isPlayerNear(self.variables.crystalDiveCoords, range or 6)
end

--- Checks if the player is facing toward the adrenaline crystals.
--- @return boolean: True if facing toward the crystals
--- @private
function WarsRetreat:_isFacingCrystals()
    return Player:getFacingDirection() == "Northwest"
end

--- @private
function WarsRetreat:_isPlayerByBossPortal(range)
    return self:_isPlayerNear(self.variables.portalDiveCoords, range or 6)
end

--- @private
function WarsRetreat:_isPlayerByExitPortal(range)
    return self:_isPlayerNear(self.constants.TILES.EXIT_PORTAL, range or 3)
end

------------------------------------------
-- # INVENTORY AND EQUIPMENT UTILITIES
------------------------------------------

--- Checks player inventory against preset loadout
--- @return boolean: True if inventory matches preset
--- @private
function WarsRetreat:_inventoryMatchCheck()
    assert(self.userSettings, "User settings not initialized")
    assert(self.userSettings.preset, "Preset not initialized")
    assert(self.userSettings.preset.inventory,
           "Preset inventory not initialized")
    return Utils:inventoryMatchCheck(self.userSettings.preset.inventory)
end

--- Validates preset items against current inventory/equipment, storing and reporting warnings.
--- @private
function WarsRetreat:_validatePresetItems()
    if self.onWarningsClear then self.onWarningsClear() end
    self.warnings = {}
    local preset = self.userSettings.preset

    -- Check inventory items
    if preset.inventory then
        local invItems = API.ReadInvArrays33()
        for _, item in ipairs(preset.inventory) do
            local found = false
            local itemIds = item.ids or (item.id and {item.id} or {})

            for _, invItem in ipairs(invItems) do
                for _, id in ipairs(itemIds) do
                    if invItem.itemid1 == id then
                        found = true
                        break
                    end
                end
                if found then break end
            end

            if not found then
                local itemName = item.name or
                                     (item.id and ("Item ID: " .. item.id) or
                                         ("Item IDs: " ..
                                             table.concat(item.ids or {}, ", ")))
                local msg = "Missing inventory item: " .. itemName
                self.warnings[#self.warnings + 1] = msg
                if self.onWarning then self.onWarning(msg) end
            end
        end
    end

    -- Check equipment items
    if preset.equipment then
        for _, item in ipairs(preset.equipment) do
            if not Equipment:Contains(item.id) then
                local itemName = item.name or ("Item ID: " .. item.id)
                local slotName = item.slot or "unknown"
                local msg = "Missing equipment: " .. itemName .. " (slot " ..
                                slotName .. ")"
                self.warnings[#self.warnings + 1] = msg
                if self.onWarning then self.onWarning(msg) end
            end
        end
    end

    -- Each warning by NAME, not just a count. A missing preset item is the one
    -- thing that pins the step machine on LOAD PRESET indefinitely — the
    -- inventory can never match, so we bank, re-check, bank again — and "1
    -- warning(s)" tells you that happened without telling you what to fix. The
    -- names are already built above; printing them costs nothing and turns a
    -- dead end into a one-line diagnosis.
    for _, msg in ipairs(self.warnings) do Utils:log(msg, "warn") end

    if #self.warnings > 0 then
        Utils:log("Preset validation: " .. #self.warnings ..
                      " warning(s) — the inventory cannot match the preset " ..
                      "until these are in it", "warn")
    end
end

--- Public interface for preset validation. Returns the warnings list.
--- @return string[]
function WarsRetreat:validatePreset()
    self:_validatePresetItems()
    return self.warnings
end

--- Checks if an item exists in your inventory
--- @param name string Item name to search for
--- @return boolean: True if item is found in inventory
--- @private
function WarsRetreat:_checkForItem(name)
    for _, item in pairs(Inventory:GetItems()) do
        if string.find(item.name, name) then return true end
    end
    return false
end

--- Equips a lantern from inventory
--- @return boolean: True if lantern was equipped
--- @private
function WarsRetreat:_equipLantern()
    return Inventory:Equip("lantern")
end

--- Unequips your off-hand (lantern)
--- @return boolean: True if lantern was unequipped
--- @private
function WarsRetreat:_unequipLantern()
    local offhand = Equipment:GetOffhand()
    return offhand and Equipment:Unequip(offhand.id)
end

------------------------------------------
-- # ABILITY UTILITIES
------------------------------------------

-- _whitelistCooldownCheck() lived here. It reported whether any of Death Skulls
-- / Living Death / Split Soul / Berserk / Overpower was on cooldown, and its
-- only caller was _checkAltarCondition — where it caused the altar -> bank ->
-- altar shuffle on full prayer. Removed with the WHITELIST it read; see
-- _checkAltarCondition for why the altar is now decided on points alone.

--- Checks if conjures need to be refreshed
--- @return boolean: True if conjures need refreshing
--- @private
function WarsRetreat:_shouldRefreshConjures()
    local ids = self.constants.CONJURE_IDS
    for _, id in ipairs({ids.ZOMBIE, ids.GHOST, ids.SKELETON}) do
        local r = self:_getCachedBuff(id).remaining
        if r > 0 and r < 59 then return true end
    end
    return false
end

--- Checks if the player has active summons (Ghost, Skeleton)
--- @return boolean: True if player has active summons
--- @private
function WarsRetreat:_hasActiveSummons()
    local ids = self.constants.CONJURE_IDS
    return self:_getCachedBuff(ids.GHOST).found or self:_getCachedBuff(ids.SKELETON).found
end

------------------------------------------
-- # ADVANCED MOVEMENT HELPERS
------------------------------------------

--- Surge + Dive combo to a specific location
--- @param tile? WPOINT Target coordinates for dive
--- @return boolean: True if abilities were used
--- @private
function WarsRetreat:_doDiveAndSurge(tile)
    if Utils:useAbility("Surge") then
        if Utils:canUseAbility("Dive") and tile then
            return API.DoAction_Dive_Tile(tile)
        end
        if Utils:canUseAbility("Bladed Dive") and tile then
            return API.DoAction_BDive_Tile(tile)
        end
        return true
    end
    return false
end

--- Checks if Dive or Bladed Dive ability is available
--- @return boolean: True if either dive ability can be used
--- @private
function WarsRetreat:_canDive()
    return Utils:canUseAbility("Dive") or Utils:canUseAbility("Bladed Dive")
end

--- Executes Dive or Bladed Dive to a target tile
--- @param tile WPOINT Target tile to dive to
--- @return boolean: True if dive was initiated
--- @private
function WarsRetreat:_diveToTile(tile)
    if Utils:canUseAbility("Dive") then return API.DoAction_Dive_Tile(tile) end
    if Utils:canUseAbility("Bladed Dive") then
        return API.DoAction_BDive_Tile(tile)
    end
    return false
end

--- Resets interaction task cooldowns after surge/dive to force re-interaction.
--- Called after any advanced movement ability so the next interaction fires immediately.
--- @private
function WarsRetreat:_afterAdvancedMove()
    self.variables.positioning = false
    if not self.timer then return end
    self.variables.bankAttempts = 0
    local interactionTasks = {
        "Load last preset", "Pray at Altar of War",
        "Interacting with adrenaline crystal", "Dismissing conjures",
        "Equipping lantern", "Summoning conjures", "Go through boss portal"
    }
    for _, name in ipairs(interactionTasks) do self.timer:resetTask(name) end
end

--- Ensures the player is within interaction range of a target tile.
--- If farther than the specified range, initiates walking navigation.
--- @param targetTile WPOINT The tile to check distance against
--- @param range? number Maximum interaction range (default 30)
--- @return boolean: True if navigation was started (not yet in range), false if already in range
--- @private
function WarsRetreat:_ensureInRange(targetTile, range)
    if self:_isPlayerNear(targetTile, range or 30) then return false end
    if not Player:isMoving() and not Player:isAnimating() then
        API.DoAction_WalkerW(targetTile)
    end
    return true
end

--- Attempts advanced movement patterns 3.A and 3.B toward the crystals/portal area.
--- 3.A: From altar area, position at positioning tile then surge+dive combo.
--- 3.B: From stairs area facing North, surge toward target.
--- @param targetCoords WPOINT The dive target (crystal or portal coords)
--- @param step string The current navigation step
--- @return boolean|nil: True if movement/positioning is active, nil if no pattern matched (fall through to standard nav)
--- @private
function WarsRetreat:_tryAdvancedMoveNorth(targetCoords, step)
    if not self.variables.useAdvMovement then
        self.variables.positioning = false
        return nil
    end

    -- Special case: conjure summons just needs proximity to crystals/portal
    if step == "SUMMON CONJURES" and
        (self:_isPlayerByCrystals(10) or self:_isPlayerByBossPortal(10)) then
        self.variables.positioning = false
        return nil
    end

    -- 3.A: Near altar → walk to positioning tile to set up surge+dive combo
    if self:_isPlayerByAltar(6) and not self:_isPlayerByBankChest(2) then
        self.variables.positioning = true
        if not Player:isMoving() then
            self.lastAction = "Positioning for surge/dive combo"
            return API.DoAction_WalkerW(self.constants.TILES.POSITIONING)
        end
        return true
    end

    -- 3.A: In transit to positioning tile (between altar and bank chest)
    if self.variables.positioning and not self:_isPlayerByBankChest(2) then
        if Player:isMoving() then return true end
        self.lastAction = "Re-positioning for surge/dive combo"
        return API.DoAction_WalkerW(self.constants.TILES.POSITIONING)
    end

    -- 3.A: At positioning tile → execute surge+dive combo if facing correctly
    if self:_isPlayerByBankChest(2) then
        self.variables.positioning = false
        if self:_isFacingCrystals() then
            if not Player:isAnimating() then
                self.lastAction = "Surge/dive combo"
                local result = self:_doDiveAndSurge(targetCoords)
                if result then self:_afterAdvancedMove() end
                return result
            end
            return true -- Wait for animation to finish
        else
            -- Wrong facing direction: disable advanced movement for this cycle and use standard nav
            self.variables.useAdvMovement = false
            Utils:log(
                "At bank chest but facing wrong direction - using standard navigation",
                "debug")
            return nil
        end
    end

    -- 3.B: Near stairs facing North → surge toward crystals/portal
    if self:_isPlayerByStairs(3) and Player:getFacingDirection() == "North" then
        self.lastAction = "Surging from stairs"
        local result = Utils:useAbility("Surge")
        if result then self:_afterAdvancedMove() end
        return result
    end

    self.variables.positioning = false
    return nil
end

------------------------------------------
-- # NAVIGATION HELPERS
------------------------------------------

--- Main navigation handler that routes to step-specific navigation logic
--- @param step string The current step from _getCurrentStep()
--- @return boolean: True if navigation action was taken
--- @private
function WarsRetreat:_handleNavigation(step)
    if step == "LOAD PRESET" or step == "HEALING" then
        return self:_navigateToBank(step)
    elseif step == "USE ALTAR" then
        return self:_navigateForAltar()
    elseif step == "USE PORTAL" then
        return self:_navigateNorthward(self.variables.portalDiveCoords, step, 30, "Walking to portal")
    elseif step == "USE CRYSTAL" or step == "SUMMON CONJURES" or step == "PREBUILD"
        or step == "EQUIP LANTERN" or step == "REFRESH CONJURES" then
        local range = (step == "SUMMON CONJURES") and 10 or 30
        return self:_navigateNorthward(self.variables.crystalDiveCoords, step, range, "Walking to crystals")
    end
    return false
end

--- Navigates northward to a target tile using advanced movement or standard walking.
--- Shared logic for crystal and portal navigation (patterns 3.A and 3.B).
--- @param targetCoords WPOINT Destination tile
--- @param step string Current navigation step
--- @param fallbackRange number Standard navigation range
--- @param fallbackMsg string lastAction message for standard walking
--- @return boolean: True if navigation action was taken
--- @private
function WarsRetreat:_navigateNorthward(targetCoords, step, fallbackRange, fallbackMsg)
    local advResult = self:_tryAdvancedMoveNorth(targetCoords, step)
    if advResult ~= nil then return advResult end

    if self:_ensureInRange(targetCoords, fallbackRange) then
        self.lastAction = fallbackMsg
        return true
    end
    return false
end

--- Handles navigation to the bank chest.
--- Includes 3.D pattern: dive to positioning tile when approaching for preset load.
--- @param step string The current step
--- @return boolean: True if navigation action was taken
--- @private
function WarsRetreat:_navigateToBank(step)
    local bankTile = self.constants.TILES.POSITIONING

    -- 3.D: Dive to positioning tile when approaching bank for preset load
    if self.variables.useAdvMovement and step == "LOAD PRESET" and
        self:_isPlayerByBankChest(11) and not self:_isPlayerByBankChest(3) and
        self:_canDive() and self:_isPlayerByExitPortal(2) then
        self.lastAction = "Diving to bank area"
        local result = self:_diveToTile(bankTile)
        if result then self:_afterAdvancedMove() end
        return result or false
    end

    -- Standard navigation: ensure within interaction range
    local range = step == "HEALING" and 1 or 30
    if self:_ensureInRange(bankTile, range) then
        self.lastAction = "Moving to bank"
        return true
    end
    return false
end

--- Handles navigation for the altar step.
--- Includes 3.C pattern: surge from exit portal when facing East.
--- @return boolean: True if navigation action was taken
--- @private
function WarsRetreat:_navigateForAltar()
    -- 3.C: Exit Portal → Altar (Surge when facing East near exit portal)
    if self.variables.useAdvMovement and self:_isPlayerByExitPortal(4) and
        Player:getFacingDirection() == "East" then
        self.lastAction = "Surging from exit portal to altar"
        local result = Utils:useAbility("Surge")
        if result then self:_afterAdvancedMove() end
        return result or false
    end

    if self:_ensureInRange(self.constants.TILES.ALTAR, 30) then
        self.lastAction = "Moving to altar"
        return true
    end
    return false
end

return WarsRetreat
