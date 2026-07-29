--- @module 'raksha.gui'
--- @version 1.0.0
--- Raksha boss GUI — built on Sonson's GUI Library, modelled on rasial/gui.lua.
---
--- Two phases, same as Rasial:
---   * Before start: a settings window with tabs. main.lua blocks until Start.
---   * After start: a runtime window with live info, debug tabs and Pause/Stop.
---
--- Settings persist to raksha/config.json between sessions.
---@diagnostic disable: undefined-global

local API    = require("api")
local GUILib = require("core.gui_lib")

local RakshaGUI = {}

------------------------------------------
-- # STATE MANAGEMENT
------------------------------------------

RakshaGUI.open = true
RakshaGUI.started = false
RakshaGUI.paused = false
RakshaGUI.stopped = false
RakshaGUI.cancelled = false
RakshaGUI.warnings = {}
RakshaGUI.selectInfoTab = false
RakshaGUI.selectWarningsTab = false

------------------------------------------
-- # CONFIGURATION STATE
------------------------------------------

--- Flat config, mirrored to/from config.json. getConfig() reshapes this into the
--- nested structure main.lua and the core libraries expect.
RakshaGUI.config = {
    -- General
    bankPin = "",
    waitForFullHp = true,
    useRevolution = false,

    -- Health thresholds (percent). Set high for Raksha: anima clouds ramp to
    -- 2,000 a tick, pools are ~1,500 a tick and a countered shadow bomb still
    -- lands ~6,000, so eating at 45% left no room to react.
    healthSolid = 70,
    healthJellyfish = 70,
    healthPotion = 60,
    healthSpecial = 75,

    -- Prayer thresholds
    prayerNormal = 400,
    prayerCritical = 10,
    prayerSpecial = 601,

    -- War's Retreat
    summonConjures = false,
    usePrebuild = true,
    useAdrenCrystal = true,
    bankIfInvFull = false,
    -- Off by default, matching rasial/gui.lua. This is the Surge/Dive shortcut
    -- routing around War's Retreat (surge from the exit portal to the altar,
    -- surge+dive from the bank chest to the crystals, dive toward the next stop
    -- in the prebuild). It saves a couple of seconds per trip and is not needed
    -- for the loop to work — plain walking reaches every stop.
    advancedMovement = false,
    surgeDiveChance = 100,
    minPrayer = 100,
    minSummoning = 80,
    minHealth = 80,
    warsTaskOrder = nil, -- defaults in loadConfig
    warsTaskOrderSelectedIndex = 1,

    -- Raksha mechanics
    ignoreAnimaPools = false,
    poolKillThreshold = 10,
    poolDiveDistance = 8,
    -- Measured from the edge of the shadow's 4x4 box, not its centre, so these
    -- stay small — larger values make a big exclusion zone and we shuffle
    -- between tiles instead of attacking. Clamped at runtime.
    shadowTriggerRange = 1,
    shadowSafeRange = 2,
    instakillTriggerRange = 5,
    instakillSafeRange = 6,
    bombEscapeDistance = 5,

    -- Debug
    debugMain = true,
    debugTimer = false,
    debugRotation = false,
    debugPlayer = false,
    debugPrayer = false,
    debugWars = false,
    debugMechanics = true
}

-- PREBUILD sits after CRYSTAL and before PORTAL: fill adrenaline first, then
-- build souls/necrosis on the dummies, then enter.
local DEFAULT_TASK_ORDER = {"ALTAR", "BANK", "CRYSTAL", "PREBUILD", "PORTAL"}

--------------------------------------------------------------------------------
-- GUI LIBRARY INSTANCE
--------------------------------------------------------------------------------

local ui = GUILib.new()

------------------------------------------
-- # CONFIG FILE MANAGEMENT
------------------------------------------

local RAKSHA_DIR  = os.getenv("USERPROFILE") ..
                        "\\MemoryError\\Lua_Scripts\\raksha\\"
local CONFIG_PATH = RAKSHA_DIR .. "config.json"

local function loadConfigFromFile()
    local file = io.open(CONFIG_PATH, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then return nil end
    local ok, data = pcall(API.JsonDecode, content)
    if not ok or not data then return nil end
    return data
end

local function saveConfigToFile(cfg)
    local data = {
        BankPin = cfg.bankPin,
        WaitForFullHp = cfg.waitForFullHp,
        UseRevolution = cfg.useRevolution,
        HealthSolid = cfg.healthSolid,
        HealthJellyfish = cfg.healthJellyfish,
        HealthPotion = cfg.healthPotion,
        HealthSpecial = cfg.healthSpecial,
        PrayerNormal = cfg.prayerNormal,
        PrayerCritical = cfg.prayerCritical,
        PrayerSpecial = cfg.prayerSpecial,
        SummonConjures = cfg.summonConjures,
        UsePrebuild = cfg.usePrebuild,
        UseAdrenCrystal = cfg.useAdrenCrystal,
        BankIfInvFull = cfg.bankIfInvFull,
        AdvancedMovement = cfg.advancedMovement,
        SurgeDiveChance = cfg.surgeDiveChance,
        MinPrayer = cfg.minPrayer,
        MinSummoning = cfg.minSummoning,
        MinHealth = cfg.minHealth,
        WarsTaskOrder = cfg.warsTaskOrder,
        IgnoreAnimaPools = cfg.ignoreAnimaPools,
        PoolKillThreshold = cfg.poolKillThreshold,
        PoolDiveDistance = cfg.poolDiveDistance,
        ShadowTriggerRange = cfg.shadowTriggerRange,
        ShadowSafeRange = cfg.shadowSafeRange,
        InstakillTriggerRange = cfg.instakillTriggerRange,
        InstakillSafeRange = cfg.instakillSafeRange,
        BombEscapeDistance = cfg.bombEscapeDistance,
        DebugMain = cfg.debugMain,
        DebugTimer = cfg.debugTimer,
        DebugRotation = cfg.debugRotation,
        DebugPlayer = cfg.debugPlayer,
        DebugPrayer = cfg.debugPrayer,
        DebugWars = cfg.debugWars,
        DebugMechanics = cfg.debugMechanics
    }

    local ok, json = pcall(API.JsonEncode, data)
    if not ok or not json then
        API.printlua("Failed to encode config JSON", 4, false)
        return
    end

    os.execute('mkdir "' .. RAKSHA_DIR:gsub("/", "\\") .. '" 2>nul')
    local file = io.open(CONFIG_PATH, "w")
    if not file then
        API.printlua("Failed to open config file for writing", 4, false)
        return
    end
    file:write(json)
    file:close()
    API.printlua("Config saved", 0, false)
end

--- Folds newly-added tasks into a task order saved by an older version.
---
--- Without this, a config.json written before PREBUILD existed keeps overriding
--- DEFAULT_TASK_ORDER on load — the step is never reached and the dummies are
--- silently skipped forever, even with the toggle switched on.
--- @param order string[]
--- @return string[]
local function migrateTaskOrder(order)
    local seen = {}
    for _, key in ipairs(order) do seen[key] = true end

    for _, key in ipairs(DEFAULT_TASK_ORDER) do
        if not seen[key] then
            -- Slot it in ahead of PORTAL so entering the instance stays last.
            local inserted = false
            for i, existing in ipairs(order) do
                if existing == "PORTAL" then
                    table.insert(order, i, key)
                    inserted = true
                    break
                end
            end
            if not inserted then order[#order + 1] = key end
            seen[key] = true
            API.printlua("Task order migrated: added " .. key, 0, false)
        end
    end

    return order
end

------------------------------------------
-- # PUBLIC STATE API
------------------------------------------

function RakshaGUI.reset()
    RakshaGUI.open = true
    RakshaGUI.started = false
    RakshaGUI.paused = false
    RakshaGUI.stopped = false
    RakshaGUI.cancelled = false
    RakshaGUI.warnings = {}
end

function RakshaGUI.isPaused() return RakshaGUI.paused end
function RakshaGUI.isStopped() return RakshaGUI.stopped end
function RakshaGUI.isCancelled() return RakshaGUI.cancelled end

function RakshaGUI.addWarning(msg)
    table.insert(RakshaGUI.warnings, msg)
end

function RakshaGUI.clearWarnings() RakshaGUI.warnings = {} end

--- Loads saved settings over the defaults. Missing/!type-matching keys are left
--- at their default, so a partial or older config file still loads cleanly.
function RakshaGUI.loadConfig()
    local c = RakshaGUI.config
    c.warsTaskOrder = c.warsTaskOrder or DEFAULT_TASK_ORDER

    local saved = loadConfigFromFile()
    if not saved then return end

    local function str(key, field)
        if type(saved[key]) == "string" then c[field] = saved[key] end
    end
    local function num(key, field)
        if type(saved[key]) == "number" then c[field] = saved[key] end
    end
    local function bool(key, field)
        if type(saved[key]) == "boolean" then c[field] = saved[key] end
    end

    str("BankPin", "bankPin")
    bool("WaitForFullHp", "waitForFullHp")
    bool("UseRevolution", "useRevolution")

    num("HealthSolid", "healthSolid")
    num("HealthJellyfish", "healthJellyfish")
    num("HealthPotion", "healthPotion")
    num("HealthSpecial", "healthSpecial")
    num("PrayerNormal", "prayerNormal")
    num("PrayerCritical", "prayerCritical")
    num("PrayerSpecial", "prayerSpecial")

    bool("SummonConjures", "summonConjures")
    bool("UsePrebuild", "usePrebuild")
    bool("UseAdrenCrystal", "useAdrenCrystal")
    bool("BankIfInvFull", "bankIfInvFull")
    bool("AdvancedMovement", "advancedMovement")
    num("SurgeDiveChance", "surgeDiveChance")
    num("MinPrayer", "minPrayer")
    num("MinSummoning", "minSummoning")
    num("MinHealth", "minHealth")
    if type(saved.WarsTaskOrder) == "table" and #saved.WarsTaskOrder > 0 then
        c.warsTaskOrder = migrateTaskOrder(saved.WarsTaskOrder)
    end

    bool("IgnoreAnimaPools", "ignoreAnimaPools")
    num("PoolKillThreshold", "poolKillThreshold")
    num("PoolDiveDistance", "poolDiveDistance")
    num("ShadowTriggerRange", "shadowTriggerRange")
    num("ShadowSafeRange", "shadowSafeRange")
    num("InstakillTriggerRange", "instakillTriggerRange")
    num("InstakillSafeRange", "instakillSafeRange")
    num("BombEscapeDistance", "bombEscapeDistance")

    bool("DebugMain", "debugMain")
    bool("DebugTimer", "debugTimer")
    bool("DebugRotation", "debugRotation")
    bool("DebugPlayer", "debugPlayer")
    bool("DebugPrayer", "debugPrayer")
    bool("DebugWars", "debugWars")
    bool("DebugMechanics", "debugMechanics")
end

--- Resolved configuration in the shape main.lua and the core libraries want.
--- @return table
function RakshaGUI.getConfig()
    local c = RakshaGUI.config

    return {
        bankPin = tonumber(c.bankPin) or c.bankPin,
        waitForFullHp = c.waitForFullHp,
        useRevolution = c.useRevolution,
        usePrebuild = c.usePrebuild,

        playerManager = {
            health = {
                solid = {type = "percent", value = c.healthSolid},
                jellyfish = {type = "percent", value = c.healthJellyfish},
                healingPotion = {type = "percent", value = c.healthPotion},
                special = {type = "percent", value = c.healthSpecial}
            },
            prayer = {
                normal = {type = "current", value = c.prayerNormal},
                critical = {type = "percent", value = c.prayerCritical},
                special = {type = "current", value = c.prayerSpecial}
            }
        },

        warsRetreat = {
            summonConjures = c.summonConjures,
            useAdrenCrystal = c.useAdrenCrystal,
            bankIfInvFull = c.bankIfInvFull,
            advancedMovement = c.advancedMovement,
            surgeDiveChance = c.advancedMovement and c.surgeDiveChance or 0,
            taskOrder = c.warsTaskOrder or DEFAULT_TASK_ORDER,
            minimumValues = {
                prayer = c.minPrayer,
                summoning = c.minSummoning,
                health = c.minHealth
            }
        },

        -- Applied onto raksha.constants at startup by main.lua
        mechanics = {
            ignoreAnimaPools = c.ignoreAnimaPools,
            poolKillThreshold = c.poolKillThreshold,
            poolDiveDistance = c.poolDiveDistance,
            shadowTriggerRange = c.shadowTriggerRange,
            shadowSafeRange = c.shadowSafeRange,
            instakillTriggerRange = c.instakillTriggerRange,
            instakillSafeRange = c.instakillSafeRange,
            bombEscapeDistance = c.bombEscapeDistance
        },

        debug = {
            main = c.debugMain,
            timer = c.debugTimer,
            rotation = c.debugRotation,
            player = c.debugPlayer,
            prayer = c.debugPrayer,
            wars = c.debugWars,
            mechanics = c.debugMechanics
        }
    }
end

--------------------------------------------------------------------------------
-- TAB CONTENT: GENERAL
--------------------------------------------------------------------------------

local function drawGeneralTab(cfg)
    ui:spacing(1)
    ui:sectionHeader("General Settings", "Banking and startup behaviour.")

    cfg.bankPin = ui:labeledInput("Bank PIN", "##bankpin", cfg.bankPin)
    if cfg.bankPin == "" or cfg.bankPin == nil then
        ui:statusText("Bank PIN required for preset loading", "warning", true)
    end

    cfg.waitForFullHp = ui:checkbox("Wait for Full HP##waitfullhp",
                                    cfg.waitForFullHp)
    ui:text("Hold at War's Retreat until health is topped up.", "hint")

    ui:separator()
    ui:sectionHeader("Combat Style", "Who casts the damage abilities.")

    cfg.useRevolution = ui:checkbox("Use Revolution bar##userevo",
                                    cfg.useRevolution)
    if cfg.useRevolution then
        ui:text("Your Revolution bar does the damage. The script still handles " ..
                    "pre-fight buffs, conjures, positioning, every mechanic " ..
                    "(Freedom / Escape / Anticipation / dodges), prayers, food " ..
                    "and defensives — it just won't cast damage abilities.",
                "hint")
    else
        ui:text("The script casts the full scripted rotation itself. Turn this " ..
                    "on to hand damage over to a full Revolution bar instead.",
                "hint")
    end
end

--------------------------------------------------------------------------------
-- TAB CONTENT: WAR'S RETREAT
--------------------------------------------------------------------------------

local function drawWarsRetreatTab(cfg)
    ui:spacing(1)
    ui:sectionHeader("War's Retreat", "Pre-fight preparation between kills.")

    cfg.summonConjures = ui:checkbox("Summon Conjures##summonconjures",
                                     cfg.summonConjures)
    ui:text("Off by default — conjures are summoned in the Raksha lobby instead.",
            "hint")
    cfg.useAdrenCrystal = ui:checkbox("Use Adrenaline Crystal##useadren",
                                      cfg.useAdrenCrystal)
    cfg.bankIfInvFull = ui:checkbox("Bank if Inventory Full##bankinvfull",
                                    cfg.bankIfInvFull)

    ui:spacing(1)
    cfg.usePrebuild = ui:checkbox("Pre-build on Dummies##useprebuild",
                                  cfg.usePrebuild)
    ui:text("Builds 5 Residual Souls and 4 Necrosis on the training dummies " ..
                "before entering, so the opener can Volley and Finger " ..
                "immediately (PVME).", "hint")

    ui:separator()
    ui:sectionHeader("Minimum Thresholds",
                     "Minimum values before continuing to the next step.")

    cfg.minPrayer = ui:labeledSliderInt("Prayer (%)", "##minPrayer",
                                        cfg.minPrayer, 0, 100, "%d%%")
    cfg.minSummoning = ui:labeledSliderInt("Summoning (%)", "##minSummoning",
                                           cfg.minSummoning, 0, 100, "%d%%")
    cfg.minHealth = ui:labeledSliderInt("Health (%)", "##minHealth",
                                        cfg.minHealth, 0, 100, "%d%%")
    ui:text("Prayer at 100% means always top up at the Altar of War.", "hint")

    ui:separator()
    ui:sectionHeader("Movement", "Surge and dive behaviour.")

    cfg.advancedMovement = ui:checkbox("Advanced Movement##advancedmovement",
                                       cfg.advancedMovement)
    ui:text("Surges to the adrenaline crystal and the portal.", "hint")

    if cfg.advancedMovement then
        ui:spacing(1)
        cfg.surgeDiveChance = ui:labeledSliderInt("Surge/Dive Chance",
                                                  "##surgeDiveChance",
                                                  cfg.surgeDiveChance, 0, 100,
                                                  "%d%%")
    end
end

--------------------------------------------------------------------------------
-- TAB CONTENT: TASK ORDER
--------------------------------------------------------------------------------

local function drawWarsTaskOrderTab(cfg)
    local WarsRetreat = require("core.wars_retreat")

    ui:spacing(1)
    ui:sectionHeader("Task Execution Order",
                     "Order of the War's Retreat preparation steps.")
    ui:text("Select a task, then use the buttons to move it.", "hint")
    ui:spacing(2)

    -- reorderableList wants {key, label, disabled} entries and renders its own
    -- up/down buttons, returning the action to apply.
    -- TASK_METADATA names the setting as the library sees it; map those onto our
    -- GUI fields so the greyed-out state is accurate.
    local SETTING_FIELD = {
        prebuildSettings = "usePrebuild",
        summonConjures = "summonConjures",
        useAdrenCrystal = "useAdrenCrystal"
    }

    local displayItems = {}
    for _, taskKey in ipairs(cfg.warsTaskOrder) do
        local metadata = WarsRetreat.TASK_METADATA[taskKey]
        if metadata then
            local disabled = false
            if metadata.conditionalLoad then
                local field = SETTING_FIELD[metadata.loadSetting] or
                                  metadata.loadSetting
                disabled = not cfg[field]
            end
            displayItems[#displayItems + 1] = {
                key = taskKey,
                label = metadata.displayName,
                disabled = disabled
            }
        end
    end

    local newIndex, action = ui:reorderableList("##warsTaskOrder", displayItems,
                                                cfg.warsTaskOrderSelectedIndex)
    cfg.warsTaskOrderSelectedIndex = newIndex

    if action then
        local i = action.index
        if action.type == "move_up" and i > 1 then
            cfg.warsTaskOrder[i], cfg.warsTaskOrder[i - 1] =
                cfg.warsTaskOrder[i - 1], cfg.warsTaskOrder[i]
            cfg.warsTaskOrderSelectedIndex = i - 1
        elseif action.type == "move_down" and i < #cfg.warsTaskOrder then
            cfg.warsTaskOrder[i], cfg.warsTaskOrder[i + 1] =
                cfg.warsTaskOrder[i + 1], cfg.warsTaskOrder[i]
            cfg.warsTaskOrderSelectedIndex = i + 1
        end
    end

    ui:spacing(2)
    ui:separator()
    ui:spacing(1)

    if ui:buttonWarning("Reset to Default Order##resetOrder", 26) then
        cfg.warsTaskOrder = {}
        for i, key in ipairs(DEFAULT_TASK_ORDER) do
            cfg.warsTaskOrder[i] = key
        end
        cfg.warsTaskOrderSelectedIndex = 1
    end

    ui:spacing(1)
    ui:text("Default: Altar → Bank → Crystal → Portal. BANK should come before " ..
                "PORTAL or preparation may be skipped.", "hint")
end

--------------------------------------------------------------------------------
-- TAB CONTENT: PLAYER MANAGER
--------------------------------------------------------------------------------

local function drawPlayerManagerTab(cfg)
    ui:spacing(1)
    ui:sectionHeader("Health Thresholds", "When to eat, drink and heal.")

    cfg.healthSolid = ui:labeledSliderInt("Solid Food (%)", "##healthSolid",
                                          cfg.healthSolid, 0, 100, "%d%%")
    cfg.healthJellyfish = ui:labeledSliderInt("Jellyfish (%)",
                                              "##healthJellyfish",
                                              cfg.healthJellyfish, 0, 100,
                                              "%d%%")
    cfg.healthPotion = ui:labeledSliderInt("Healing Potion (%)",
                                           "##healthPotion", cfg.healthPotion,
                                           0, 100, "%d%%")
    cfg.healthSpecial = ui:labeledSliderInt("Excalibur (%)", "##healthSpecial",
                                            cfg.healthSpecial, 0, 100, "%d%%")
    ui:text("Set to 0 to disable a given heal.", "hint")

    ui:separator()
    ui:sectionHeader("Prayer Thresholds", "When to restore prayer points.")

    cfg.prayerNormal = ui:labeledInputInt("Restore below (points)",
                                          "##prayerNormal", cfg.prayerNormal, 10)
    cfg.prayerCritical = ui:labeledSliderInt("Critical (%)", "##prayerCritical",
                                             cfg.prayerCritical, 0, 100, "%d%%")
    cfg.prayerSpecial = ui:labeledInputInt("Elven shard below (points)",
                                           "##prayerSpecial", cfg.prayerSpecial,
                                           10)
end

--------------------------------------------------------------------------------
-- TAB CONTENT: MECHANICS (Raksha-specific)
--------------------------------------------------------------------------------

local function drawMechanicsTab(cfg)
    ui:spacing(1)
    ui:sectionHeader("Shadow Anima Pools",
                     "Pools heal Raksha. Clearing starts at the threshold and " ..
                         "always runs down to zero.")

    cfg.ignoreAnimaPools = ui:checkbox("Ignore Anima Pools##ignorepools",
                                       cfg.ignoreAnimaPools)
    ui:text("Never break off to clear pools — just keep DPSing Raksha. Note " ..
                "that uncleared pools heal the boss.", "hint")

    if not cfg.ignoreAnimaPools then
        ui:spacing(1)
        cfg.poolKillThreshold = ui:labeledSliderInt("Start clearing at (pools)",
                                                    "##poolThreshold",
                                                    cfg.poolKillThreshold, 1, 20,
                                                    "%d")
        ui:text("Fewer than this are ignored so we keep DPSing the boss.", "hint")

        cfg.poolDiveDistance = ui:labeledSliderInt(
                                   "Dive when further than (tiles)", "##poolDive",
                                   cfg.poolDiveDistance, 2, 20, "%d")
        ui:text("Dive is only used when off cooldown, and never into a hazard.",
                "hint")
    end

    ui:separator()
    ui:sectionHeader("Lethal Ground", "Instant-death hazards. Higher is safer.")

    cfg.shadowTriggerRange = ui:labeledSliderInt("Shadow: dodge within (tiles)",
                                                 "##shadowTrigger",
                                                 cfg.shadowTriggerRange, 1, 4,
                                                 "%d")
    cfg.shadowSafeRange = ui:labeledSliderInt("Shadow: clear by (tiles)",
                                              "##shadowSafe",
                                              cfg.shadowSafeRange, 1, 4, "%d")
    ui:text("Measured from the shadow's edge. Keep these low — high values " ..
                "make us reposition constantly instead of attacking.", "hint")
    ui:spacing(1)
    cfg.instakillTriggerRange = ui:labeledSliderInt(
                                    "Highlight: dodge within (tiles)",
                                    "##ikTrigger", cfg.instakillTriggerRange, 1,
                                    12, "%d")
    cfg.instakillSafeRange = ui:labeledSliderInt("Highlight: clear by (tiles)",
                                                 "##ikSafe",
                                                 cfg.instakillSafeRange, 1, 15,
                                                 "%d")

    ui:separator()
    ui:sectionHeader("Bombs", "Ground bombs during the bomb phase.")

    cfg.bombEscapeDistance = ui:labeledSliderInt("Clear bombs by (tiles)",
                                                 "##bombEscape",
                                                 cfg.bombEscapeDistance, 1, 12,
                                                 "%d")
end

--------------------------------------------------------------------------------
-- TAB CONTENT: DEBUG
--------------------------------------------------------------------------------

local function drawDebugTab(cfg)
    ui:spacing(1)
    ui:sectionHeader("Debug Output", "Enable extra logging and runtime tabs.")

    cfg.debugMain = ui:checkbox("Main##debugmain", cfg.debugMain)
    cfg.debugMechanics = ui:checkbox("Mechanics##debugmech", cfg.debugMechanics)
    cfg.debugTimer = ui:checkbox("Timer##debugtimer", cfg.debugTimer)
    cfg.debugRotation = ui:checkbox("Rotation##debugrot", cfg.debugRotation)
    cfg.debugPlayer = ui:checkbox("Player Manager##debugplayer", cfg.debugPlayer)
    cfg.debugPrayer = ui:checkbox("Prayer Flicker##debugprayer", cfg.debugPrayer)
    cfg.debugWars = ui:checkbox("War's Retreat##debugwars", cfg.debugWars)
end

--------------------------------------------------------------------------------
-- RUNTIME TAB: INFO
--------------------------------------------------------------------------------

local function drawInfoTab(data)
    if ui:beginInfoTable("##rakshainfo", 0.45) then
        ui:tableRow("Status", data.status or "Unknown")
        ui:tableRow("Location", data.location or "Unknown")
        ui:tableRow("Runtime", API.ScriptRuntimeString())
        ui:endColumns()
    end

    ui:separator()
    ui:sectionHeader("Kills", "")

    if ui:beginInfoTable("##rakshakills", 0.45) then
        ui:tableRow("Total Kills", tostring(data.killCount or 0))
        ui:tableRow("Kills / hr", tostring(data.killsPerHour or "0"))
        ui:tableRow("Deaths", tostring(data.deathCount or 0))
        ui:tableRow("Fastest", data.fastestKill or "N/A")
        ui:tableRow("Slowest", data.slowestKill or "N/A")
        ui:tableRow("Average", data.averageKill or "N/A")
        ui:endColumns()
    end

    if data.boss then
        ui:separator()
        ui:sectionHeader("Raksha", "")
        if ui:beginInfoTable("##rakshaboss", 0.45) then
            ui:tableRow("Found", tostring(data.boss.found))
            ui:tableRow("Health", tostring(data.boss.health))
            ui:tableRow("Animation", tostring(data.boss.animation))
            ui:tableRow("Mechanic", data.boss.mechanic or "-")
            ui:endColumns()
        end
    end
end

--------------------------------------------------------------------------------
-- RUNTIME TAB: MECHANICS DEBUG
--------------------------------------------------------------------------------

local function drawMechanicsDebugTab(data)
    if not data.mechanics then
        ui:text("No mechanics data.", "hint")
        return
    end

    if ui:beginInfoTable("##mechdebug", 0.55) then
        for _, row in ipairs(data.mechanics) do
            ui:tableRow(tostring(row[1]), tostring(row[2]))
        end
        ui:endColumns()
    end
end

--------------------------------------------------------------------------------
-- RUNTIME TAB: WARNINGS
--------------------------------------------------------------------------------

local function drawWarningsTab(gui)
    for _, msg in ipairs(gui.warnings) do
        ui:statusText(msg, "warning", true)
    end
    ui:spacing(2)
    if ui:buttonSecondary("Clear Warnings##clearwarn") then
        RakshaGUI.clearWarnings()
    end
end

--------------------------------------------------------------------------------
-- WINDOW CONTENT
--------------------------------------------------------------------------------

local function drawConfigContent(gui)
    if ui:beginTabBar("##configtabs") then
        if ui:beginTab("General###general") then
            drawGeneralTab(gui.config)
            ui:endTab()
        end
        if ui:beginTab("War's Retreat###warsretreat") then
            drawWarsRetreatTab(gui.config)
            ui:endTab()
        end
        if ui:beginTab("Task Order###taskorder") then
            drawWarsTaskOrderTab(gui.config)
            ui:endTab()
        end
        if ui:beginTab("Player###playermanager") then
            drawPlayerManagerTab(gui.config)
            ui:endTab()
        end
        if ui:beginTab("Mechanics###mechanics") then
            drawMechanicsTab(gui.config)
            ui:endTab()
        end
        if ui:beginTab("Debug###debug") then
            drawDebugTab(gui.config)
            ui:endTab()
        end
        ui:endTabBar()
    end

    ui:separator(3, 3)

    if ui:button("Start Raksha##start", 32) then
        saveConfigToFile(gui.config)
        gui.started = true
    end
    ui:spacing(1)
    if ui:buttonSecondary("Cancel##cancel") then gui.cancelled = true end
end

local function drawRuntimeContent(data, gui)
    if ui:beginTabBar("##runtimetabs") then
        local infoFlags = gui.selectInfoTab and ImGuiTabItemFlags.SetSelected or
                              0
        gui.selectInfoTab = false
        if ui:beginTab("Info###info", infoFlags) then
            ui:spacing(1)
            drawInfoTab(data)
            ui:endTab()
        end

        if gui.config.debugMechanics and
            ui:beginTab("Mechanics###mechdebug") then
            ui:spacing(1)
            drawMechanicsDebugTab(data)
            ui:endTab()
        end

        if #gui.warnings > 0 then
            local label = "Warnings (" .. #gui.warnings .. ")###warnings"
            local flags = gui.selectWarningsTab and
                              ImGuiTabItemFlags.SetSelected or 0
            if ui:beginTab(label, flags) then
                gui.selectWarningsTab = false
                ui:spacing(1)
                drawWarningsTab(gui)
                ui:endTab()
            end
        end

        ui:endTabBar()
    end

    ui:separator(3, 3)

    if gui.paused then
        if ui:buttonSuccess("Resume Script##resume") then gui.paused = false end
    else
        if ui:buttonSecondary("Pause Script##pause") then gui.paused = true end
    end
    ui:spacing(1)
    if ui:buttonDanger("Stop Script##stop") then gui.stopped = true end
end

------------------------------------------
-- # MAIN DRAW FUNCTION
------------------------------------------

function RakshaGUI.draw(data)
    data = data or {}

    ImGui.SetNextWindowPos(100, 100, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSize(540, 0, ImGuiCond.Always)
    local colorCount, styleCount = ui:pushTheme()

    local title = "Raksha - " .. API.ScriptRuntimeString() .. " - K: " ..
                      tostring(data.killCount or 0) .. "###Raksha"
    local visible = ui:beginWindow(title, 64) -- AlwaysAutoResize

    if visible then
        local ok, err
        if not RakshaGUI.started then
            ok, err = pcall(drawConfigContent, RakshaGUI)
        else
            ok, err = pcall(drawRuntimeContent, data, RakshaGUI)
        end
        if not ok then ui:text("Error: " .. tostring(err), "error") end
    end

    ui:endWindow()
    ui:popTheme(colorCount, styleCount)

    return RakshaGUI.open
end

return RakshaGUI
