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
local GUILib = require("raksha.core.gui_lib")

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

    -- Discord embeds on death and on a unique drop, same as Rasial.
    --
    -- The WEBHOOK URL is not a script setting: Discord:SendEmbedEx posts to the
    -- url in the client's own settings.json, so this only decides whether we
    -- send anything. With no url configured there, sending is simply a no-op.
    useDiscord = true,

    -- Party / duo. Modelled on kerapac/config.lua, which uses the same three
    -- settings: are we in a party at all, are we the one who owns the instance,
    -- and who is the owner if it isn't us.
    --
    -- inParty is what scales Raksha's phase thresholds — he has double the life
    -- points in duo and every transition doubles with them, so getting this
    -- wrong does not just misreport a number, it puts the whole phase machine
    -- on the wrong rotation. See Constants.setPartySize.
    inParty = false,
    isPartyLeader = false,
    partyLeader = "",

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
    poolKillThreshold = 6,
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

--- Raksha's own palette: violet and shadow, instead of the library's default
--- gold. The boss is the Shadow Colossus, so the accent, buttons and sliders all
--- shift to amethyst and the window sits a touch darker and cooler.
---
--- Only the keys we actually want to change are listed — GUILib._mergeThemes
--- fills the rest in from DEFAULT_THEME, so this stays a diff rather than a copy
--- that would silently drift when the library's defaults change.
local RAKSHA_THEME = {
    colors = {
        accent = {0.72, 0.51, 0.94, 1.0}, -- Amethyst
        header = {0.96, 0.94, 1.00, 1.0}, -- Faint violet-white
        label = {0.86, 0.84, 0.92, 1.0},
        hint = {0.50, 0.48, 0.58, 1.0},
        separator = {0.42, 0.32, 0.58, 0.55},

        windowBg = {0.07, 0.06, 0.10, 0.97}, -- Deep shadow
        frameBg = {0.14, 0.12, 0.19, 0.92},
        frameBgHover = {0.20, 0.17, 0.28, 1.0},
        frameBgActive = {0.26, 0.22, 0.36, 1.0},

        tab = {0.11, 0.09, 0.15, 1.0},
        tabHovered = {0.19, 0.15, 0.27, 1.0},
        tabActive = {0.07, 0.06, 0.10, 1.0},

        button = {0.55, 0.36, 0.82, 0.92},
        buttonHover = {0.66, 0.46, 0.93, 1.0},
        buttonActive = {0.45, 0.28, 0.70, 1.0},
        buttonText = {1.00, 0.98, 1.00, 1.0}, -- Light on violet, unlike gold

        sliderGrab = {0.72, 0.51, 0.94, 1.0},
        checkMark = {0.72, 0.51, 0.94, 1.0}
    }
}

local ui = GUILib.new(RAKSHA_THEME)

--------------------------------------------------------------------------------
-- DASHBOARD PALETTE
--------------------------------------------------------------------------------

-- Per-phase colours. Raksha darkens as the fight goes on, so the bar walks from
-- a pale violet toward deep shadow — the colour alone tells you the phase
-- without reading a number.
local PHASE_COLORS = {
    {0.62, 0.72, 0.98}, -- 1 — cold blue
    {0.72, 0.51, 0.94}, -- 2 — amethyst
    {0.85, 0.42, 0.85}, -- 3 — magenta
    {0.95, 0.30, 0.42} -- 4 — blood red
}

local PRAYER_COLOR = {0.45, 0.78, 0.98}
local ADRENALINE_COLOR = {0.98, 0.72, 0.28}
local DANGER_COLOR = {0.95, 0.30, 0.35}
local IDLE_COLOR = {0.45, 0.43, 0.52}
local SUCCESS_COLOR = {0.45, 0.85, 0.55} -- gp figures that are actually money
local RARE_COLOR = {1.00, 0.84, 0.35} -- gold, for anything off the unique table

--- Rounds to a whole number for %d formatting.
---
--- NOT cosmetic. Player:getAdrenaline() returns `state / 10`, so it is a FLOAT —
--- and string.format("%d", 87.4) throws "bad argument #2 to 'format' (number has
--- no integer representation)" in Lua 5.3+. That error fired mid-draw, so the
--- tab's endTab()/endTabBar() never ran and ImGui followed it with a cascade of
--- "Missing EndTabBar() / PopID() / PopStyleVar()" complaints. One unformatted
--- float took the whole window down.
--- @param n number|nil
--- @return number
local function whole(n) return math.floor(tonumber(n) or 0) end

--- Colour for a phase number, clamped so an unexpected value can't index nil.
--- @param phase number|nil
--- @return number[]
local function phaseColor(phase)
    local index = math.max(1, math.min(4, math.floor(phase or 1)))
    return PHASE_COLORS[index]
end

--- Draws the four phase pips as a single row. The reached ones take their phase
--- colour, the rest stay muted — a glanceable "how far in are we".
--- @param phase number
local function drawPhasePips(phase)
    phase = math.max(1, math.min(4, math.floor(phase or 1)))
    for i = 1, 4 do
        local label = (i <= phase) and "  ●  " or "  ○  "
        ui:textColored(label, i <= phase and phaseColor(i) or IDLE_COLOR)
        if i < 4 then ui:sameLine() end
    end
end

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
        UseDiscord = cfg.useDiscord,
        InParty = cfg.inParty,
        IsPartyLeader = cfg.isPartyLeader,
        PartyLeader = cfg.partyLeader,
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
    bool("UseDiscord", "useDiscord")

    bool("InParty", "inParty")
    bool("IsPartyLeader", "isPartyLeader")
    str("PartyLeader", "partyLeader")

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
        useDiscord = c.useDiscord,

        party = {
            inParty = c.inParty,
            -- Only meaningful inside a party. Resolved here rather than at every
            -- call site so nothing downstream has to remember the combination.
            isLeader = c.inParty and c.isPartyLeader or false,
            leaderName = c.partyLeader or "",
            -- Two in a duo, one otherwise. This is the number the phase
            -- thresholds scale on.
            size = c.inParty and 2 or 1
        },

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

    ui:separator()
    ui:sectionHeader("Party", "Solo or duo, and who owns the instance.")

    cfg.inParty = ui:checkbox("Duo (in a party)##inparty", cfg.inParty)

    if not cfg.inParty then
        ui:text("Solo. Raksha has 800,000 life points and phases at 600k, " ..
                    "400k and 200k.", "hint")
        return
    end

    ui:text("Duo. Raksha has 1,600,000 life points and phases at 1.2M, 800k " ..
                "and 400k — every threshold doubles, so this must match the " ..
                "instance you are actually in or the phase rotations load at " ..
                "the wrong time.", "hint")

    ui:spacing(1)
    cfg.isPartyLeader = ui:checkbox("I own the instance##ispartyleader",
                                    cfg.isPartyLeader)

    if cfg.isPartyLeader then
        ui:text("You create the instance and set it to 2 players. Your partner " ..
                    "joins you by name.", "hint")
        return
    end

    cfg.partyLeader = ui:labeledInput("Owner's name", "##partyleader",
                                      cfg.partyLeader)
    if cfg.partyLeader == nil or cfg.partyLeader == "" then
        ui:statusText("Owner's name required to join their instance", "warning",
                      true)
    else
        ui:text("You join this player's instance rather than creating one.",
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
    local WarsRetreat = require("raksha.core.wars_retreat")

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

    ui:separator()
    ui:sectionHeader("Notifications", "Configure alerts and notifications.")

    cfg.useDiscord = ui:checkbox("Discord Notifications##discord",
                                 cfg.useDiscord)
    ui:text("Embeds on death and on a unique drop. The webhook URL comes " ..
                "from the client's settings.json, not from here.", "hint")
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
        cfg.poolKillThreshold = ui:labeledSliderInt("Tolerate up to (pools)",
                                                    "##poolThreshold",
                                                    cfg.poolKillThreshold, 1, 20,
                                                    "%d")
        ui:text("Phase 3 only. This many standing is fine and we stay on " ..
                    "Raksha; above it we clear back down to this number and " ..
                    "return to him. An announced siphon still clears them all.",
                "hint")

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

--- The live dashboard: everything you'd want at a glance while it runs.
---
--- Built around bars rather than numbers on purpose. A row of text tells you the
--- boss is on 143,204 HP; a violet bar three-quarters drained tells you the same
--- thing without reading, and the colour tells you the phase at the same time.
--- The numbers are still there, just as the label on the bar.
local function drawInfoTab(data)
    local player = data.player or {}
    local review = data.review or {}

    ----------------------------------------------------------------
    -- Status banner
    ----------------------------------------------------------------
    -- A full-width bar used purely as a coloured plate for the status text.
    -- Red while dodging lethal ground, phase-coloured in the fight, muted
    -- otherwise — so the banner itself signals danger before you read it.
    local bannerColor = IDLE_COLOR
    local bannerText = data.status or "Idle"

    if data.dodging then
        bannerColor = DANGER_COLOR
        bannerText = "DODGING LETHAL GROUND"
    elseif data.activeMechanic then
        bannerColor = phaseColor(data.phase)
        bannerText = data.activeMechanic
    elseif data.inFight then
        bannerColor = phaseColor(data.phase)
    end

    ui:progressBar(1.0, 26, bannerText, bannerColor)
    ui:spacing(1)

    if ui:beginInfoTable("##rakshainfo", 0.45) then
        ui:tableRow("Location", data.location or "Unknown")
        ui:tableRow("Runtime", API.ScriptRuntimeString())

        -- Loop health. "Are we keeping up with the game?" as a number.
        --
        -- Passes/tick should sit in the low teens. `skipped` counts game ticks
        -- the main loop never got a pass in at all — on those the boss could
        -- start AND finish an animation without us ever reading it, which is
        -- exactly how mechanics and rotation steps end up late. Anything other
        -- than 0 here is the thing to chase; a rising number means the loop is
        -- being starved, not that a handler is mistuned.
        local health = data.loopHealth
        if health then
            local skipped = whole(health.skippedTicks)
            ui:tableRow("Loop passes / tick", tostring(whole(health.itersLastTick)),
                        skipped > 0 and DANGER_COLOR or nil)
            ui:tableRow("Ticks skipped", string.format("%d (worst jump %d)",
                                                       skipped,
                                                       whole(health.worstJump)),
                        skipped > 0 and DANGER_COLOR or nil)
        end
        ui:endColumns()
    end

    ----------------------------------------------------------------
    -- Pass profile
    ----------------------------------------------------------------
    -- Only shown while the loop is actually behind. When passes/tick is healthy
    -- this is noise, and the dashboard is already dense.
    --
    -- Sorted worst-first by main.lua. "worst" is the column to read: the bug we
    -- are chasing is a section that is normally instant and occasionally blocks
    -- for most of a game tick, which an average would hide completely.
    local prof = data.profile
    if prof and #prof > 0 and data.loopHealth and
        whole(data.loopHealth.skippedTicks) > 0 then
        ui:separator()
        ui:sectionHeader("Pass profile (ms)", "Worst offender first.")

        if ui:beginInfoTable("##rakshaprof", 0.45) then
            -- Ten rows now, not six: Mechanics:update is broken into its own
            -- sections (mech:*), so the table is longer and the interesting
            -- entry is no longer guaranteed to be in the top few.
            for index, row in ipairs(prof) do
                if index > 10 then break end
                ui:tableRow(tostring(row.name),
                            string.format("%.1f last / %.1f worst",
                                          tonumber(row.last) or 0,
                                          tonumber(row.worst) or 0),
                            (tonumber(row.worst) or 0) >= 100 and DANGER_COLOR or
                                nil)
            end
            ui:endColumns()
        end
    end

    ----------------------------------------------------------------
    -- Raksha
    ----------------------------------------------------------------
    -- Headings pass "" rather than nil deliberately. sectionHeader treats any
    -- non-nil second argument as a hint line, so "" adds a blank line plus
    -- spacing(3) beneath the title. Dropping it tightened things up on paper but
    -- looked worse in the client — the headings ended up crowding the content
    -- under them — so the breathing room stays.
    ui:separator()
    ui:sectionHeader("Raksha", "")

    local boss = data.boss or {}
    local phase = data.phase or 1

    ui:textColored("Phase " .. tostring(phase), phaseColor(phase))
    ui:sameLine()
    drawPhasePips(phase)

    -- Denominator is the highest HP actually observed this fight, not a
    -- hardcoded max — see Mechanics review.bossMaxSeen for why.
    local maxHp = math.max(review.bossMaxSeen or 0, boss.health or 0, 1)
    local hp = math.max(0, boss.health or 0)

    if boss.found then
        ui:progressBar(math.min(1, hp / maxHp), 22,
                       string.format("%s / %s", GUILib.formatNumber(whole(hp)),
                                     GUILib.formatNumber(whole(maxHp))),
                       phaseColor(phase))
    else
        ui:progressBar(0, 22, "not in the arena", IDLE_COLOR)
    end

    if ui:beginInfoTable("##rakshaboss", 0.45) then
        ui:tableRow("Animation", tostring(boss.animation or "-"))
        ui:tableRow("Mechanic", boss.mechanic or "-")
        ui:endColumns()
    end

    ----------------------------------------------------------------
    -- Player vitals
    ----------------------------------------------------------------
    ui:separator()
    ui:sectionHeader("Vitals", "")

    -- progressBar, not labeledProgressBar: the label goes INSIDE the bar so each
    -- vital is one compact row. labeledProgressBar puts the label above and
    -- leaves the bar to draw ImGui's own "82%" inside it, which meant two lines
    -- per vital saying much the same thing twice.
    local maxPlayerHp = math.max(whole(player.maxHp), 1)
    local playerHp = whole(player.hp)
    local hpPercent = (playerHp / maxPlayerHp) * 100

    ui:progressBar(math.min(1, playerHp / maxPlayerHp), 20,
                   string.format("Health      %d / %d", playerHp, maxPlayerHp),
                   GUILib.getHealthColor(hpPercent))

    local prayer = whole(player.prayer)
    ui:progressBar(math.min(1, prayer / 100), 20,
                   string.format("Prayer      %d%%", prayer), PRAYER_COLOR)

    -- whole() matters most here: getAdrenaline returns state/10, so this is the
    -- float that was crashing the draw.
    local maxAdren = math.max(whole(player.maxAdrenaline), 1)
    local adren = whole(player.adrenaline)
    ui:progressBar(math.min(1, adren / maxAdren), 20,
                   string.format("Adrenaline  %d / %d", adren, maxAdren),
                   ADRENALINE_COLOR)

    ----------------------------------------------------------------
    -- This fight
    ----------------------------------------------------------------
    ui:separator()
    ui:sectionHeader("This Fight", "")

    if ui:beginInfoTable("##rakshareview", 0.45) then
        ui:tableRow("Damage taken",
                    GUILib.formatNumber(whole(review.damageTaken)))
        ui:tableRow("Biggest hit",
                    string.format("%s  (%s)",
                                  GUILib.formatNumber(whole(review.biggestHit)),
                                  review.biggestHitAnim or "none"))
        ui:tableRow("Lowest HP", tostring(whole(review.lowestHp)))

        -- Mechanics answered vs seen. Coloured because a miss is the one number
        -- here that means something is wrong rather than merely interesting.
        local missed = whole(review.missed)
        ui:tableRow("Mechanics",
                    string.format("%d / %d answered", whole(review.answered),
                                  whole(review.seen)),
                    missed > 0 and DANGER_COLOR or nil)
        if missed > 0 then
            ui:tableRow("Missed", tostring(missed), DANGER_COLOR)
        end
        ui:endColumns()
    end

    ----------------------------------------------------------------
    -- Session
    ----------------------------------------------------------------
    ui:separator()
    ui:sectionHeader("Session", "")

    if ui:beginInfoTable("##rakshakills", 0.45) then
        ui:tableRow("Total Kills", tostring(whole(data.killCount)))
        ui:tableRow("Kills / hr", tostring(data.killsPerHour or "0"))
        ui:tableRow("Deaths", tostring(whole(data.deathCount)),
                    whole(data.deathCount) > 0 and DANGER_COLOR or nil)
        ui:tableRow("Fastest", data.fastestKill or "N/A")
        ui:tableRow("Slowest", data.slowestKill or "N/A")
        ui:tableRow("Average", data.averageKill or "N/A")
        ui:endColumns()
    end
end

--------------------------------------------------------------------------------
-- RUNTIME TAB: LOOT
--------------------------------------------------------------------------------

--- Whole gp with thousands separators.
---
--- Not GUILib.formatNumber, which rounds to "1.2M". That reads well for a health
--- bar and badly for money — the whole point of a gp column is being able to see
--- the difference between two drops that both abbreviate to the same thing.
--- @param n number|nil
--- @return string
local function gp(n)
    n = math.floor(tonumber(n) or 0)
    local formatted = tostring(n)
    -- Insert separators right to left until no more fit.
    while true do
        local replaced
        formatted, replaced = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if replaced == 0 then break end
    end
    return formatted
end

local function drawLootTab(data)
    local loot = data.loot or {}
    local rares = loot.rares or {}
    local history = loot.history or {}

    ----------------------------------------------------------------
    -- Totals
    ----------------------------------------------------------------
    ui:sectionHeader("Session Value", "")

    if ui:beginInfoTable("##rakshalootvalue", 0.45) then
        ui:tableRow("Total looted", gp(loot.totalValue) .. " gp")
        ui:tableRow("GP / hr", gp(loot.gpPerHour), SUCCESS_COLOR)
        ui:tableRow("GP / kill", gp(loot.gpPerKill))
        ui:tableRow("Best kill", gp(loot.bestKill))
        ui:tableRow("Kills", tostring(whole(data.killCount)))
        ui:endColumns()
    end

    ----------------------------------------------------------------
    -- Rares
    ----------------------------------------------------------------
    ui:separator()
    ui:sectionHeader("Rare Drops", "")

    if #rares == 0 then
        ui:text("None yet.", "hint")
    elseif ui:beginColumns("##rakshararetable", {0.44, 0.14, 0.22, 0.20}) then
        ui:tableRow({"Item", "Kill", "Value", "Time"})
        for _, r in ipairs(rares) do
            ui:tableRow({r.name, "#" .. tostring(r.kill), gp(r.value), r.time},
                        {RARE_COLOR, nil, SUCCESS_COLOR, nil})
        end
        ui:endColumns()
    end

    ----------------------------------------------------------------
    -- Per kill
    ----------------------------------------------------------------
    ui:separator()
    ui:sectionHeader("Loot Per Kill", "")

    if #history == 0 then
        ui:text("Nothing looted yet.", "hint")
        return
    end

    if ui:beginColumns("##rakshaloothistory", {0.30, 0.42, 0.28}) then
        ui:tableRow({"Kill", "Value", "Time"})
        for _, k in ipairs(history) do
            ui:tableRow({"#" .. tostring(k.kill), gp(k.gp), k.time},
                        {nil, k.gp > 0 and SUCCESS_COLOR or nil, nil})
        end
        ui:endColumns()
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

--- Runs a tab's body so that an error inside it cannot escape the tab.
---
--- ImGui's begin/end calls have to balance. When the dashboard threw a
--- string.format error mid-draw, endTab() and endTabBar() were skipped and ImGui
--- reported a cascade of "Missing EndTabBar() / PopID() / PopStyleVar()" on top
--- of the real error — which buried the actual cause and left the window broken
--- until restart. Catching here means a bad value shows up as one readable line
--- in its own tab and everything else keeps rendering.
--- @param fn function
--- @param ... any
local function safeDraw(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        ui:statusText("Draw error: " .. tostring(err), "error", true)
    end
end

local function drawRuntimeContent(data, gui)
    if ui:beginTabBar("##runtimetabs") then
        local infoFlags = gui.selectInfoTab and ImGuiTabItemFlags.SetSelected or
                              0
        gui.selectInfoTab = false
        -- The ###info id is kept so selectInfoTab still targets this tab; only
        -- the visible label changed.
        if ui:beginTab("Dashboard###info", infoFlags) then
            ui:spacing(1)
            safeDraw(drawInfoTab, data)
            ui:endTab()
        end

        if ui:beginTab("Loot###loot") then
            ui:spacing(1)
            safeDraw(drawLootTab, data)
            ui:endTab()
        end

        if gui.config.debugMechanics and
            ui:beginTab("Mechanics###mechdebug") then
            ui:spacing(1)
            safeDraw(drawMechanicsDebugTab, data)
            ui:endTab()
        end

        if #gui.warnings > 0 then
            local label = "Warnings (" .. #gui.warnings .. ")###warnings"
            local flags = gui.selectWarningsTab and
                              ImGuiTabItemFlags.SetSelected or 0
            if ui:beginTab(label, flags) then
                gui.selectWarningsTab = false
                ui:spacing(1)
                safeDraw(drawWarningsTab, gui)
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
