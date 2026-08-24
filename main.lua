--- @module 'raksha.main'
--- @version 0.1.0
--- Raksha — fight loop.
---@diagnostic disable: undefined-global

local API             = require("api")

local RotationManager = require("raksha.core.rotation_manager")
local PlayerManager   = require("raksha.core.player_manager")
local PrayerFlicker   = require("raksha.core.prayer_flicker")
local WarsRetreat     = require("raksha.core.wars_retreat")
local Player          = require("raksha.core.player")
local Utils           = require("raksha.core.helper")
local Timer           = require("raksha.core.timer")
local Profiler        = require("raksha.core.profiler")

local Constants       = require("raksha.constants")
local Mechanics       = require("raksha.mechanics")
local GUI             = require("raksha.gui")

------------------------------------------
-- # SETTINGS
------------------------------------------

--- Every dose of every potion the rotation will accept for its adrenaline beat.
---
--- Both potions are carried in one list rather than picked between, because the
--- places that care — the bank check in LOADOUT and adrenalinePotion()'s "have
--- we got one" guard — can each take the whole list and ask "any of these".
--- Nothing has to know WHICH one you brought.
---
--- ORDER IS PREFERENCE, and it still drives the drink. API.GetAB_ids matches the
--- action bar against these ids in the order given, so a bag holding both drinks
--- the renewal and keeps the replenishment. Swap the two blocks to reverse that.
---
--- Note the two are not equivalent, only interchangeable: they restore different
--- amounts of adrenaline, and PHASE2_ROTATION's beat after the drink is written
--- around the renewal's refund. See adrenalinePotion().
local ADRENALINE_POTION_IDS = {
    -- Adrenaline renewal potion, doses 1-4
    49079, 49081, 49083, 49085,
    -- Enhanced replenishment potion, doses 1-6
    39220, 39222, 39224, 39226, 39228, 39230
}

--- LOADOUT is a CHECKLIST, not the thing that fills your bag.
---
--- Worth being explicit, because it is easy to read the other way round:
--- core/wars_retreat loads supplies with Interact:Object(bank, "Load Last Preset
--- from"), i.e. your IN-GAME preset. This table only drives two things —
--- Utils:inventoryMatchCheck, which decides whether we need to re-bank, and the
--- startup warnings about missing items.
---
--- Which makes a WRONG id here actively dangerous rather than merely useless:
--- inventoryMatchCheck fails if any single entry is unsatisfied, that keeps
--- sending us back to the bank, and loadLastPreset terminates the script on the
--- third failed attempt. Only put ids in here that you have actually confirmed.
---
--- TODO: Super restore FLASKS. They belong in this list so that running out
--- triggers a re-bank, but the flask ids are not in this codebase anywhere and
--- are NOT the same as the plain potion's {3024, 3026, 3028, 3030}. Add them as
--- an `ids` entry once confirmed. Nothing else needs changing for them to be
--- drunk: core/player_manager's "prayer" category matches on the name pattern
--- "Super restore", which "Super restore flask (6)" satisfies already.
local LOADOUT = {
    {id = 48951, amount = 502, name = "Vulnerability bomb"},
    {id = 42267, amount = 10, name = "Blue blubber jellyfish"}, {
        --ids = {49042, 49044, 49046, 49048, 49050, 49052},
        ids = {49039, 49037, 49035, 49033, 49031, 49029},
        amount = 1,
        name = "Elder overload potion"
    }, -- Accepts any dose (1-6)
    --{id = 47713, amount = 11, name = "Lantadyme incense sticks"},
    --{id = 49405, amount = 1, name = "Binding contract (blood reaver)"},
    {
        ids = ADRENALINE_POTION_IDS,
        amount = 1,
        -- Only ever a log/warning string. The bank check matches on ids, and
        -- either potion satisfies it.
        name = "Adrenaline renewal or Enhanced replenishment"
    }
}

--- Ripper Demon, kept out for the whole trip and specced whenever it can pay.
---
--- Set `enabled = false` to run without a familiar. Every task gates on it and
--- the three items drop back out of LOADOUT with it, so nothing else needs
--- touching — which matters, because leaving a pouch in LOADOUT that you do not
--- actually own would fail the bank check forever and eventually terminate the
--- script on the three-attempt guard.
---
--- Ids are off each item's own wiki page rather than copied from another script.
local FAMILIAR = {
    enabled = true,

    -- Ripper demon pouch. 96 Summoning, 64 minute duration.
    --
    -- Both the id and the name, because the two are used for different things:
    -- the id gates the bag checks and the LOADOUT entry, the name presses the
    -- action bar (see useBarItem). Keep them describing the same pouch.
    pouch = 49417,
    pouchName = "Ripper demon pouch",

    -- Ripper Demon scroll (Death From Above). Its wiki page puts the special at
    -- 20 special move points, or 16 with a spirit cape — the pool is 60, so a
    -- full bar is three casts.
    scroll = 49419,
    scrollAmount = 20,

    -- Special move points needed before we bother trying. Deliberately the
    -- FULL 20 rather than the spirit cape's 16: overshooting wastes a potion
    -- dose, undershooting wastes the cast.
    specialCost = 20,

    -- OPTIONAL: Spiritual prayer potions, for topping the special move pool back
    -- up mid-trip. OFF by default — the familiar works perfectly well without
    -- them, you just get fewer Death From Above casts once the starting 60
    -- points are spent.
    --
    -- Off matters more than it looks, because of what LOADOUT is: a checklist
    -- fed to Utils:inventoryMatchCheck, which fails if ANY entry is unsatisfied.
    -- An entry for a potion you don't carry means the inventory never matches,
    -- we bank on a loop, and loadLastPreset terminates the script on its third
    -- attempt. So the potion only joins the checklist when you have opted in.
    --
    -- Set true if you do carry them; nothing else needs changing.
    usePotion = false,

    -- Spiritual prayer potion, any dose. 15 special move points a dose, on top
    -- of the prayer and summoning points it also restores.
    --
    -- Id list for the bag check and for the action bar press (GetAB_ids matches
    -- by icon id, which covers every dose); the name is only a label.
    potionIds = {49017, 49019, 49021, 49023, 49025, 49027},
    potionName = "Spiritual prayer potion",

    -- Drink when the pool can no longer pay for a cast. Ignored when usePotion
    -- is false.
    drinkBelowPoints = 20,

    -- Renew when the familiar has less than this long left. Familiars:
    -- GetTimeRemaining reports seconds, so this is five minutes — comfortably
    -- more than a kill, so it renews at War's Retreat rather than expiring
    -- mid-fight.
    renewBelowSeconds = 300
}

if FAMILIAR.enabled then
    LOADOUT[#LOADOUT + 1] = {
        id = FAMILIAR.pouch,
        amount = 1,
        name = FAMILIAR.pouchName
    }
    LOADOUT[#LOADOUT + 1] = {
        id = FAMILIAR.scroll,
        amount = FAMILIAR.scrollAmount,
        name = "Ripper Demon scroll (Death From Above)"
    }

    -- Only when opted in — see FAMILIAR.usePotion for why an unwanted entry here
    -- is worse than merely redundant.
    if FAMILIAR.usePotion then
        LOADOUT[#LOADOUT + 1] = {
            ids = FAMILIAR.potionIds,
            amount = 1,
            name = FAMILIAR.potionName
        }
    end
end

local SCRIPT_VERSION = "0.2.0"

------------------------------------------
-- # LOOT
------------------------------------------

--- Raksha's drop table, from the wiki. IDs were read off each item's own wiki
--- page rather than copied across from another script, except where an id is
--- shared with rasial/main.lua and matched on re-check.
---
--- These lists only decide whether we bother OPENING the loot window: once it's
--- open, pickUpLoot presses Loot All, which takes everything in the pile. So a
--- drop missing from here is still collected as long as one listed item landed
--- alongside it — which the main table guarantees. That's why Raksha's head
--- isn't here: the wiki has no id for it (see Constants.PENDING), and it can't
--- be the only thing in a pile.
---
--- Items the wiki marks "(noted)" drop as bank notes. The wiki doesn't document
--- note ids, but a note always sits at base + 1, so both are listed — an id that
--- never appears on the ground costs nothing to scan for.
local LOOT = {
    COMMONS = {
        -- Seeds
        48201, -- Arbuck seed
        48769, -- Ciku seed

        -- Stone spirits
        44815, -- Dark animica stone spirit
        44814, -- Light animica stone spirit
        57174, -- Primal stone spirit

        -- Salvage (noted)
        47298, 47299, -- Small blunt rune salvage
        51103, 51104, -- Medium spiky orikalkum salvage
        51105, 51106, -- Huge plated orikalkum salvage

        -- Other main drops
        1747, 1748, -- Black dragonhide (noted)
        42954, -- Onyx dust
        48075, 48076, -- Dinosaur bones (noted)
        989, 990, -- Crystal key (noted)
        54019, -- Catalytic anima stone
        566, -- Soul rune
    },

    -- The 1/50 unique table.
    UNIQUES = {
        51102, -- Broken shackle (pet)

        51082, -- Fleeting boots
        51086, -- Shadow spike
        51094, -- Greater Ricochet ability codex
        51096, -- Greater Chain ability codex
        51098 -- Divert ability codex
    },

    -- Names for the uniques, keyed by id, mirroring rasial's UNIQUES_DATA.
    --
    -- Needed because rares are spotted by scanning the FLOOR rather than by
    -- reading the loot window, and a ground object's own name field is not
    -- something to rely on — see recordUniqueDrops.
    -- `prefix` is the article the Discord embed puts before the name, defaulting
    -- to "a " when absent — so plurals set it to "" rather than announcing "a
    -- Fleeting boots". `thumbnail` is optional: supply a real runescape.wiki
    -- image URL and the embed shows it, omit it and the embed renders without
    -- one. See DISCORD_ICON for why none are pre-filled.
    UNIQUES_DATA = {
        -- The pet. Was missing from this table entirely, so the rare log and the
        -- Discord embed would both have called the best drop in the game
        -- "Unique 51102".
        [51102] = {name = "Broken shackle"},

        [51082] = {name = "Fleeting boots", prefix = ""},
        [51086] = {name = "Shadow spike"},
        [51094] = {name = "Greater Ricochet ability codex"},
        [51096] = {name = "Greater Chain ability codex"},
        [51098] = {name = "Divert ability codex"}
    }
}

--- @return boolean
local function lootConfigured()
    return (#LOOT.COMMONS + #LOOT.UNIQUES) > 0
end

------------------------------------------
-- # ITEM ACTIVATION (ACTION BAR)
------------------------------------------

-- EVERY item this script activates goes through one of the two functions below —
-- useBarItem for fixed-name items (the Vulnerability bomb, the familiar pouch,
-- the gear switches) and useBarPotion for anything with doses (the overload, the
-- adrenaline potions, the spiritual prayer potion). The split is not cosmetic:
-- see useBarPotion for why a name lookup silently fails on a potion.
--
-- The inventory calls they replaced (Inventory:DoAction, DoAction_Inventory1/2/3,
-- Inventory:Equip, and the rotation manager's `type = "Inventory"`) are all gone
-- from this file.
--
-- THE PREREQUISITE, because there is no way for the script to fix it: the item
-- has to be ON the action bar. API.DoAction_Ability resolves by name against the
-- bar, so an item that is in the bag but not barred simply cannot be used this
-- way. That is why a miss is logged loudly — an unbarred item otherwise fails in
-- complete silence, and a script that quietly stops overloading looks like a
-- dozen other problems before it looks like this one.
--
-- Inventory READS are untouched: Inventory:Contains / GetItem still gate every
-- caller. Those answer "do we have one", which the bar cannot tell us and which
-- is worth knowing separately from "can we press it".

--- Names we've already warned about, so a missing bar entry logs once rather
--- than on every attempt. Keyed by item name.
local barItemWarned = {}

--- True when `name` occupies an action bar slot we can actually press.
--- @param name string Item name, exactly as it appears on the action bar
--- @return boolean onBar
local function barItemReady(name)
    local ok, ability = pcall(API.GetABs_name, name, true)
    return (ok and ability and (ability.slot or 0) > 0) and true or false
end

--- Logs a missing bar entry once per key, then never again.
--- @param key string
--- @param message string
local function warnBarItemOnce(key, message)
    if barItemWarned[key] then return end
    barItemWarned[key] = true
    Utils:log(message, "warn")
end

--- Uses an item from the ACTION BAR instead of clicking it in the inventory.
--- See the section note above for the prerequisite this carries.
---
--- NAMED items only — things whose bar label never changes, like the bomb, the
--- pouch and the gear switches. Potions must NOT come through here; see
--- useBarPotion below for why.
--- @param name string Item name, exactly as it appears on the action bar
--- @param optional? boolean Suppress the warning — for callers trying several
---        candidate names, which must not complain about the ones you didn't bar
--- @return boolean used
local function useBarItem(name, optional)
    if not barItemReady(name) then
        if not optional then
            warnBarItemOnce(name, string.format(
                                "'%s' is not on the action bar — this script activates items from the bar, so it will never be used until you put it there",
                                name))
        end
        return false
    end
    return Utils:useAbility(name) and true or false
end

--- Uses a multi-dose POTION from the action bar, matched by ICON ID.
---
--- Potions cannot go through useBarItem, and assuming they could is what stopped
--- the adrenaline drink working. The bar labels a potion WITH ITS DOSE —
--- "Adrenaline renewal potion (4)" — while Utils:useAbility resolves through
--- API.DoAction_Ability with exact_match set to true. A base name therefore
--- never matches a barred potion, the press silently does nothing, and the only
--- symptom is a potion that is never drunk.
---
--- API.GetAB_ids exists for exactly this case: api.lua documents it as matching
--- bar slots by icon id "in order of input, for potions ... full dose to
--- smaller". It hands back the slot, which DoAction_Ability_Direct presses.
---
--- Taking the whole id array also restores what the old inventory call did — ONE
--- call covering both adrenaline potions and every dose of each, in preference
--- order — so there is no longer a list of names to keep in sync.
--- @param ids number[] Item ids, fullest/preferred dose first
--- @param label string Human name, for the warning when none of them are barred
--- @return boolean used
local function useBarPotion(ids, label)
    local ok, ab = pcall(API.GetAB_ids, ids)
    if not ok or not ab or (ab.slot or 0) <= 0 then
        warnBarItemOnce(label, string.format(
                            "No '%s' on the action bar — this script activates items from the bar, so bar one or it will never be drunk",
                            label))
        return false
    end
    return API.DoAction_Ability_Direct(ab, 1,
                                       API.OFF_ACT_GeneralInterface_route) and
               true or false
end

------------------------------------------
-- # BUFFS
------------------------------------------

--- Buffs kept up for the duration of the fight, in the format core/player_manager
--- expects. Ported from rasial/presets.lua:Presets.Buffs.
---
--- The contract is worth understanding, because it's what makes "on for the
--- fight, off after the kill" work without any explicit teardown:
---   * requestBuffs(BUFFS) is called every loop iteration WHILE Raksha is alive.
---   * Each frame the manager re-applies anything that has expired or been
---     stripped — which is what re-drinks the overload when the buff runs out.
---   * Entries marked `toggle` are tracked, and any toggle buff NOT requested on
---     a frame is toggled back off. So we simply stop requesting once he's dead
---     and Ruination and the pocket item switch themselves off. It retries until
---     it succeeds, unlike a one-shot teardown call.
---
--- Ruination is deliberately NOT in FIGHT_ROTATION as well. Casting it from both
--- places races the activation delay: the rotation turns it on, the manager sees
--- it as still-off a tick later, casts again, and toggles it straight back off.
--- Rasial has it buff-managed only, for the same reason.

-- Equipment container, and the pocket slot's index within it.
local EQUIPMENT_CONTAINER = 94
local POCKET_SLOT = 18

--- Item id currently in the pocket slot, or -1 if empty/unreadable.
--- @return number
local function pocketItemId()
    local ok, container = pcall(API.Container_Get_all, EQUIPMENT_CONTAINER)
    if not ok or not container then return -1 end
    local slot = container[POCKET_SLOT]
    return (slot and slot.item_id) or -1
end

--- Buff entry for a pocket-slot activatable — the scriptures and the grimoire.
---
--- All three share one id between the item and the buff it grants, and all three
--- burn charges while active, so all three are toggles that must go off after the
--- kill. Only one can be in the pocket slot at a time, so every entry is gated on
--- finding its own item there: we can request all three unconditionally and
--- whichever is actually equipped is the only one that does anything. That's why
--- there's no setting for which one you're using.
--- @param name string Ability name, which is also the item name
--- @param id number Shared item/buff id
--- @return table
local function pocketBuff(name, id)
    return {
        buffName = name,
        buffId = id,
        canApply = function() return pocketItemId() == id end,
        execute = function()
            if pocketItemId() ~= id then return false end
            return Utils:useAbility(name)
        end,
        toggle = true
    }
end

-- Doses 1-6 of the Elder overload potion, matching the ids in LOADOUT above. The
-- buff id is the 6-dose id for all of them. Swap to the salve ids
-- {49042, 49044, 49046, 49048, 49050, 49052} (and the "Elder overload salve"
-- name) if you change LOADOUT over.
local ELDER_OVERLOAD_IDS = {49039, 49037, 49035, 49033, 49031, 49029}

local BUFFS = {
    {
        buffName = "Ruination",
        buffId = 30769,
        canApply = function() return true end,
        execute = function() return Utils:useAbility("Ruination") end,
        toggle = true
    },

    pocketBuff("Scripture of Jas", 51814),
    pocketBuff("Scripture of Ful", 52494),
    pocketBuff("Erethdor's grimoire", 42787),

    {
        -- Re-drunk automatically whenever the buff drops: _processBuff applies
        -- any requested buff whose remaining time is at or below refreshAt, and
        -- an absent buff counts as expired.
        buffName = "Elder overload",
        buffId = 49039,
        -- ContainsAny, NOT Contains. Contains with a table asks whether the bag
        -- holds ALL of them — every dose from 1 to 6 at once — which is never
        -- true, so this gate was refusing the overload outright. ContainsAny is
        -- the "have we got any dose" question actually meant here, and is what
        -- rasial/presets.lua uses for the same kind of list.
        canApply = function()
            return Inventory:ContainsAny(ELDER_OVERLOAD_IDS)
        end,
        -- By id, not name: the bar labels a potion with its dose, so a name
        -- lookup never matches one. See useBarPotion.
        execute = function()
            return useBarPotion(ELDER_OVERLOAD_IDS, "Elder overload potion")
        end,
        refreshAt = math.random(10, 20)
    }
}

------------------------------------------
-- # SCRIPT INITIALIZATION
------------------------------------------

Interact:SetSleep(0, 0, 0)
API.ClearLog()

------------------------------------------
-- # GUI PRE-START CONFIGURATION
------------------------------------------

GUI.reset()
GUI.loadConfig()
ClearRender()

-- Settings window; blocks here until Start or Cancel.
DrawImGui(function() if GUI.open then GUI.draw({}) end end)

API.printlua("Waiting for configuration...", 0, false)

while API.Read_LoopyLoop() and not GUI.started do
    if not GUI.open then
        API.printlua("GUI closed before start", 0, false)
        ClearRender()
        return
    end
    if GUI.isCancelled() then
        API.printlua("Script cancelled by user", 0, false)
        ClearRender()
        return
    end
    API.RandomSleep2(100, 50, 0)
end

local CONFIG = GUI.getConfig()
CONFIG.scriptVersion = SCRIPT_VERSION
-- Preset drives War's Retreat banking: the bank step only triggers when the
-- inventory no longer matches this list, so an EMPTY LOADOUT means no banking.
CONFIG.preset = {inventory = LOADOUT, equipment = {}}

------------------------------------------
-- # DISCORD NOTIFICATIONS
------------------------------------------

-- Placed HERE, below CONFIG, and not up with the other constants — these close
-- over CONFIG, and CONFIG is a local. Defined any earlier, the name would not
-- resolve to it: Lua would compile the reference as a GLOBAL lookup, which is
-- nil, and the first notification would error instead of sending.

--- Icon used for the embed author and footer.
---
--- EMPTY BY DEFAULT, deliberately. Rasial hardcodes runescape.wiki thumbnail
--- URLs, and those carry a content hash — an invented one 404s and the embed
--- renders with a broken image rather than no image. Paste a real URL here
--- (right-click the picture on the wiki, copy image address) and every embed
--- picks it up; leave it empty and they render cleanly without an icon.
local DISCORD_ICON = ""

--- Embed colours, matching Rasial's.
local DISCORD_COLOR = {
    drop = 10181046, -- purple, for a unique
    death = 15158332 -- red
}

--- True when embeds are switched on in the GUI.
---
--- Note this is the ONLY thing the setting controls. The webhook URL itself
--- lives in the client's settings.json, which Discord:SendEmbedEx reads; with no
--- URL configured there, sending is a harmless no-op.
--- @return boolean
local function discordEnabled() return CONFIG.useDiscord == true end

--- Author block shared by every embed, so the script name and version are
--- reported identically wherever the embed came from.
--- @return table
local function discordAuthor()
    ---@diagnostic disable-next-line: undefined-global
    return EmbedAuthor.new(string.format("[%s] Raksha", SCRIPT_VERSION), "",
                           DISCORD_ICON, "")
end

--- @param text string
--- @return table
local function discordFooter(text)
    ---@diagnostic disable-next-line: undefined-global
    return EmbedFooter.new(text, DISCORD_ICON, "")
end

--- Sends an embed, swallowing anything that goes wrong.
---
--- Wrapped in pcall on purpose: a notification is the least important thing this
--- script does, and it reaches out to the network. A webhook that is
--- misconfigured, rate limited or simply down must never take the fight down
--- with it — least of all the DEATH embed, which fires in the middle of the
--- recovery flow.
--- @param embed table
--- @param what string For the log line if it fails
local function sendDiscord(embed, what)
    local ok, err = pcall(function()
        ---@diagnostic disable-next-line: undefined-global
        return Discord:SendEmbedEx(embed, true)
    end)
    if not ok then
        Utils:log(string.format("Discord %s notification failed: %s", what,
                                tostring(err)), "warn")
    end
end

-- Scale the phase thresholds for the party we are actually in, BEFORE anything
-- reads them. Raksha has double the life points in a duo and every transition
-- doubles with them, so this decides which rotation loads when — see
-- Constants.setPartySize.
Constants.setPartySize(CONFIG.party.size)
Utils:log(string.format(
              "%s: Raksha phases at %d / %d / %d",
              CONFIG.party.inParty and "DUO" or "Solo", Constants.PHASE_HP.P2,
              Constants.PHASE_HP.P3, Constants.PHASE_HP.P4), "info")

-- Push the tunable mechanic values from the GUI onto the constants the
-- mechanics module reads.
do
    local m = CONFIG.mechanics
    Constants.ADDS.ANIMA_POOL.ignore = m.ignoreAnimaPools
    Constants.ADDS.ANIMA_POOL.killThreshold = m.poolKillThreshold
    -- Phase 3 too, and this is the one that matters: handleAnimaPools prefers
    -- killThresholdByPhase over killThreshold, and phase 3 is the only phase with
    -- a finite entry. Setting only killThreshold above left the slider with
    -- nothing to affect.
    Constants.ADDS.ANIMA_POOL.killThresholdByPhase[3] = m.poolKillThreshold
    Constants.ADDS.ANIMA_POOL.diveDistance = m.poolDiveDistance
    Constants.SHADOW_FLOOR.triggerRange = m.shadowTriggerRange
    Constants.SHADOW_FLOOR.safeRange = m.shadowSafeRange
    Constants.INSTAKILL.triggerRange = m.instakillTriggerRange
    Constants.INSTAKILL.safeRange = m.instakillSafeRange
    local bombs = Constants.MECHANICS[Constants.ANIM.BOMBS]
    if bombs then bombs.escapeDistance = m.bombEscapeDistance end
end

ClearRender()

------------------------------------------
-- # PASS PROFILER
------------------------------------------

--- Section timings for one main-loop pass. Lives in core/profiler.lua so
--- mechanics.lua can time its own internals against the same table — the
--- previous version was a local here, which meant the single most expensive
--- call in the pass (Mechanics:update) could only ever be measured as one
--- opaque number.
local profMark = Profiler.mark
local profileSnapshot = Profiler.snapshot

local Common = {
    scriptStartTime = os.time(),
    killCount = 0,
    -- Kill record staged by logKill, committed by confirmKill once a loot pile
    -- proves the kill was real.
    pendingKill = nil,
    deathCount = 0,
    killData = {},
    fightStartTick = nil,

    -- Death recovery (ported from rasial/main.lua)
    isDead = false, -- Latched while the recovery flow is running
    deathTime = nil, -- os.time() of the death, for logging
    deathReclaimStep = nil, -- Death's Office reclaim state-machine step
    deathReclaimStepTick = nil, -- Tick the current reclaim step started
    reachedDeathOffice = false, -- True once we've actually arrived at Death
    deathReclaimed = false, -- True once items are back, so we stop and leave

    -- Loot ledger. See the LOOT TRACKING section.
    lootValue = 0, -- Total gp of every pile looted this session
    lootPerKill = {}, -- Newest-first {kill, gp, time}, one per looted pile
    rareLog = {} -- Newest-first list of unique drops, with the kill they fell on
}

------------------------------------------
-- # LOOT TRACKING
------------------------------------------

--- Live Grand Exchange prices, resolved once per item id per session.
---
--- Cached deliberately, and not for tidiness. API.GetExchangePrice is a lookup
--- out of the client, the GUI redraws every frame, and this codebase has already
--- been bitten once by a per-frame native call — see the "Unexpected inventory
--- size" wall that a repeated inventory comparison produced. Prices do not move
--- enough during a session to be worth paying that twice.
local priceCache = {}

--- @param id number Item id
--- @return number gp Unit price, 0 when the exchange has no answer
local function itemPrice(id)
    local cached = priceCache[id]
    if cached ~= nil then return cached end

    -- pcall because an untradeable or unrecognised id is a perfectly ordinary
    -- thing to find in a drop, and it must not take the fight loop down.
    local ok, price = pcall(API.GetExchangePrice, id)
    if not ok or type(price) ~= "number" or price < 0 then price = 0 end

    priceCache[id] = price
    return price
end

--- Most rare drops we keep in the log before dropping the oldest.
local RARE_LOG_LIMIT = 50

--- Most per-kill loot rows we keep. Enough to see a trend, not enough to grow
--- without bound over an overnight session.
local LOOT_HISTORY_LIMIT = 50

--- Adds the open loot window's own valuation of the pile to the running total.
---
--- Utils:getLootWindowAmount scrapes the "Value: N" line off interface 1622,
--- which is the game's own GE-based figure for everything in the window. This is
--- the mechanism rasial/main.lua has been using all along, and it replaced a
--- per-item pricing pass of mine that recorded nothing at all — the loot tab
--- stayed empty because that pass depended on LootWindow_GetData returning a
--- shape it evidently does not, and the pcall around it failed silently.
---
--- Using the window's own total also removes the need to price commons by hand:
--- the number already reflects live prices, stack sizes and every item in the
--- pile, including anything missing from the LOOT table.
--- Confirms a kill against the pile it dropped, and commits its timing record.
---
--- THE COUNTER LIVES HERE, not in logKill, because the kill DETECTOR is
--- inferential: a run of ticks where Raksha reads as unfound is accepted as a
--- kill. That is the right call for deciding to teleport out — being stranded in
--- a finished instance is worse than leaving early — but it is the wrong basis
--- for a count, because a bad scan mid-fight registers a kill that never
--- happened. A loot pile is physical evidence. No boss, no pile.
---
--- The timing record moves with it, so fastest/slowest/average describe exactly
--- the same set of kills the counter does rather than a slightly larger one.
---
--- Must run BEFORE the pile and any rare are recorded: both stamp themselves
--- with Common.killCount, and they should carry the number of the kill they
--- actually came from.
local function confirmKill()
    Common.killCount = Common.killCount + 1

    if Common.pendingKill then
        table.insert(Common.killData, Common.pendingKill)
        Common.pendingKill = nil
    end

    Utils:log(string.format("----- KILL %d (confirmed by loot) -----",
                            Common.killCount))
end

--- @param gained number Value read from the window BEFORE Loot All was pressed
--- @return number gp Added this call
local function recordLootValue(gained)
    gained = gained or 0
    if gained <= 0 then
        Utils:log("Loot window reported no value — nothing added to the ledger",
                  "debug")
        return 0
    end

    Common.lootValue = Common.lootValue + gained

    table.insert(Common.lootPerKill, 1, {
        kill = Common.killCount,
        gp = gained,
        time = os.date("%H:%M:%S")
    })
    while #Common.lootPerKill > LOOT_HISTORY_LIMIT do
        table.remove(Common.lootPerKill)
    end

    Utils:log(string.format("Looted %d gp on kill #%d (session %d gp)", gained,
                            Common.killCount, Common.lootValue))
    return gained
end

--- Logs any unique sitting on the floor, stamped with the kill it fell on.
---
--- Scans the GROUND (object type 3) rather than reading the loot window, which
--- is how rasial:logUniqueDrop does it and the reason that one works. The pile
--- is still on the floor at this point — pickUpLoot only reaches here with
--- getGroundLoot() non-empty — so the uniques are there to be found.
---
--- Names come from LOOT.UNIQUES_DATA rather than the object, because a ground
--- object's name field is not dependable across item types and the ids are a
--- fixed, known list anyway.
--- @param drops table[]|nil Ground scan taken BEFORE Loot All was pressed
local function recordUniqueDrops(drops)
    if not drops or #drops == 0 then return end

    for _, drop in ipairs(drops) do
        local id = drop.Id
        local data = LOOT.UNIQUES_DATA[id]
        local name = (data and data.name) or ("Unique " .. tostring(id))
        local value = itemPrice(id)

        table.insert(Common.rareLog, 1, {
            name = name,
            id = id,
            value = value,
            kill = Common.killCount,
            time = os.date("%H:%M:%S")
        })
        while #Common.rareLog > RARE_LOG_LIMIT do
            table.remove(Common.rareLog)
        end

        Utils:log(string.format("RARE DROP: %s on kill #%d (%d gp)", name,
                                Common.killCount, value), "warn")

        if discordEnabled() then
            ---@diagnostic disable-next-line: undefined-global
            local embed = DiscordEmbed.new()
                              :SetTitle(string.format(
                                            "Congratulations! You found %s%s",
                                            (data and data.prefix) or "a ", name))
                              :SetDescription(string.format(
                                                  "Raksha coughed up a **%s**!",
                                                  name))
                              :SetColor(DISCORD_COLOR.drop)
                              :SetTimestamp(tostring(os.time()))
                              :SetAuthor(discordAuthor())

            -- Thumbnail only when we actually have a URL for that item, so an
            -- entry without one renders plainly instead of showing a broken
            -- image. See DISCORD_ICON for why none are filled in by default.
            if data and data.thumbnail and data.thumbnail ~= "" then
                ---@diagnostic disable-next-line: undefined-global
                embed:SetThumbnail(EmbedImage.new(data.thumbnail,
                                                  data.thumbnail, 50, 50))
            end

            ---@diagnostic disable-next-line: undefined-global
            embed:AddField(EmbedField.new("Kill Count",
                                          tostring(Common.killCount), true))
            ---@diagnostic disable-next-line: undefined-global
            embed:AddField(EmbedField.new("Value",
                                          string.format("%d gp", value), true))
            ---@diagnostic disable-next-line: undefined-global
            embed:AddField(EmbedField.new("Runtime", API.ScriptRuntimeString(),
                                          true))
            embed:SetFooter(discordFooter(
                                "Thank you for using Sonson's Scripts"))

            sendDiscord(embed, "rare drop")
        end
    end
end

------------------------------------------
-- # PREBUILD (War's Retreat dummies)
------------------------------------------

-- PVME opens Raksha holding 5 Residual Souls and 4 Necrosis stacks, built on the
-- War's Retreat training dummies before entering. Without them the phase 1
-- opener can't fire Volley of Souls or Finger of Death and falls back to
-- builders, which is a big chunk of lost opening damage.
--
-- Training dummy: NPC 16027, "Attack", around (3315, 10147). Targeted by id via
-- DoAction_NPC, so the exact name/plane doesn't matter.
local TRAINING_DUMMY_ID = 16027

-- Forward-declared so the prebuild steps below can reset the rotation and read
-- War's Retreat's resolved tiles. Both are assigned in the INSTANCES section.
local rotationManager
local warsRetreat

--- @return number Current Residual Souls (buff 30123)
local function soulStacks()
    local buff = Player:getBuff(30123)
    return (buff and buff.found and buff.remaining) or 0
end

--- @return number Current Necrosis stacks (buff 30101)
local function necrosisStacks()
    local buff = Player:getBuff(30101)
    return (buff and buff.found and buff.remaining) or 0
end

local PREBUILD_TARGET_SOULS = 5
local PREBUILD_TARGET_NECROSIS = 12

-- Don't start casting until we're actually near the dummy — abilities thrown
-- while still walking in are simply wasted.
local PREBUILD_ENGAGE_RANGE = 10

--- @return boolean True when a training dummy is within engage range
local function inDummyRange()
    local dummies = Utils:findAll(TRAINING_DUMMY_ID, 1, 60)
    if #dummies == 0 then return false end
    return (dummies[1].Distance or 999) <= PREBUILD_ENGAGE_RANGE
end

local PREBUILD_ROTATION = {
    {
        label = "Attack Training dummy",
        type = "Custom",
        action = function()
            return API.DoAction_NPC(0x2a, API.OFF_ACT_AttackNPC_route,
                                    {TRAINING_DUMMY_ID}, 80)
        end,
        wait = 2,
        useTicks = true
    }
}

-- Soul Sap builds souls, Touch of Death builds necrosis. Each step is
-- conditional, so once a resource is capped its steps skip straight through.
-- Each builder also requires being in range: out of range the step is skipped
-- rather than cast into thin air, and the loop guard below keeps us walking in.
for _ = 1, 5 do
    PREBUILD_ROTATION[#PREBUILD_ROTATION + 1] = {
        label = "Soul Sap",
        condition = function()
            return inDummyRange() and soulStacks() < PREBUILD_TARGET_SOULS
        end,
        wait = 6,
        useTicks = true
    }
    PREBUILD_ROTATION[#PREBUILD_ROTATION + 1] = {
        label = "Touch of Death",
        condition = function()
            return inDummyRange() and
                       necrosisStacks() < PREBUILD_TARGET_NECROSIS
        end,
        wait = 16,
        useTicks = true
    }
end

-- Loop guard. War's Retreat only keeps the PREBUILD step alive while the
-- rotation index is inside the rotation, and a builder step that fails on
-- cooldown still advances — so a single pass runs out long before the stacks are
-- full, which is why it was leaving early. This final step loops back to the
-- builders until both targets are met (capped, so a missing dummy or ability
-- can't strand us at War's Retreat forever).
local PREBUILD_MAX_PASSES = 10
local PREBUILD_APPROACH_TIMEOUT = 100 -- ticks (~60s) to reach the dummy
local prebuildPasses = 0
local prebuildApproachStart = nil

PREBUILD_ROTATION[#PREBUILD_ROTATION + 1] = {
    label = "Prebuild loop until stacked",
    type = "Custom",
    action = function()
        -- Still walking in: keep the attack-click alive and loop, but DON'T
        -- spend a build pass — we haven't started building yet, and counting
        -- these would make us give up before ever reaching the dummy.
        if not inDummyRange() then
            prebuildApproachStart = prebuildApproachStart or API.Get_tick()
            if (API.Get_tick() - prebuildApproachStart) >
                PREBUILD_APPROACH_TIMEOUT then
                Utils:log("Could not reach the training dummy — skipping " ..
                              "prebuild", "warn")
                prebuildApproachStart = nil
                prebuildPasses = 0
                return true
            end

            API.DoAction_NPC(0x2a, API.OFF_ACT_AttackNPC_route,
                             {TRAINING_DUMMY_ID}, 80)
            rotationManager:reset()
            return true
        end

        prebuildApproachStart = nil -- arrived
        local souls, necrosis = soulStacks(), necrosisStacks()

        if souls >= PREBUILD_TARGET_SOULS and
            necrosis >= PREBUILD_TARGET_NECROSIS then
            prebuildPasses = 0
            Utils:log(string.format(
                          "Prebuild complete: %d souls, %d necrosis — entering",
                          souls, necrosis))
            return true -- fall off the end; PREBUILD finishes, PORTAL is next
        end

        prebuildPasses = prebuildPasses + 1
        if prebuildPasses >= PREBUILD_MAX_PASSES then
            Utils:log(string.format(
                          "Prebuild gave up after %d passes (%d souls, %d necrosis)",
                          prebuildPasses, souls, necrosis), "warn")
            prebuildPasses = 0
            return true
        end

        -- Make sure we're still hitting the dummy, then loop the builders.
        -- reset() sets index = 1 and the step timer then increments it, so we
        -- resume on the first Soul Sap rather than re-clicking the dummy step.
        API.DoAction_NPC(0x2a, API.OFF_ACT_AttackNPC_route, {TRAINING_DUMMY_ID},
                         80)
        rotationManager:reset()
        return true
    end,
    wait = 2,
    useTicks = true
}

--- Staging tile we head for once the stacks are up, on the way to the portal.
---
--- Fixed x/y: War's Retreat is a static area, so these don't shift the way the
--- instanced Raksha arena does. Only the plane varies, so z is taken from the
--- player at the time rather than hardcoded. This replaced resolving the
--- portal/crystal tiles out of the library, which could come back nil entirely
--- when the script hadn't started at War's Retreat.
local PREBUILD_DIVE_TILE = {x = 3296, y = 10143}

--- Targeted movement toward a tile. Dive/Bladed Dive both take a destination, so
--- unlike Surge they always travel the right way.
--- @param tile WPOINT
--- @return boolean
local function diveToward(tile)
    if Utils:canUseAbility("Dive") then
        return API.DoAction_Dive_Tile(tile) and true or false
    end
    if Utils:canUseAbility("Bladed Dive") then
        return API.DoAction_BDive_Tile(tile) and true or false
    end
    return false
end

-- Dive out of the dummy area the moment the stacks are up. This only runs after
-- the loop step falls through (i.e. we're actually stacked), and it shortens the
-- ~18 tile walk to the portal so we spend as little time as possible carrying
-- the stacks. Respects the Advanced Movement setting.
--
-- Retried a few times rather than fired once: Dive can be a tick from ready, or
-- we can still be animating the last builder cast, and a single attempt threw
-- the whole thing away. Each attempt logs its outcome so a persistent failure is
-- diagnosable instead of silent.
local PREBUILD_DIVE_ATTEMPTS = 1

for _ = 1, PREBUILD_DIVE_ATTEMPTS do
    PREBUILD_ROTATION[#PREBUILD_ROTATION + 1] = {
        label = "Dive toward next stop",
        type = "Custom",
        action = function()
            if not CONFIG.warsRetreat.advancedMovement then return true end

            local player = Player:getCoords()
            if not player then return true end

            local dest = PREBUILD_DIVE_TILE
            local dx, dy = dest.x - player.x, dest.y - player.y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance < 6 then return true end -- close enough already

            if not (Utils:canUseAbility("Dive") or
                Utils:canUseAbility("Bladed Dive")) then
                return true -- on cooldown / not on the bar; walking is fine
            end

            -- Plane comes from the player: the staging tile's x/y are fixed but
            -- which plane War's Retreat reports can differ.
            local z = math.floor(player.z or 0)

            -- Dive reaches ~10 tiles: aim straight at the tile when it's in
            -- range, otherwise at a point along the way and let the walk finish.
            local tx, ty
            if distance <= 9 then
                tx, ty = dest.x, dest.y
            else
                local scale = 9 / distance
                tx = math.floor(player.x + dx * scale)
                ty = math.floor(player.y + dy * scale)
            end

            ---@diagnostic disable-next-line: undefined-global
            local landed = diveToward(WPOINT.new(tx, ty, z))
            Utils:log(string.format(
                          "Prebuild dive -> (%d, %d, %d), %.0f tiles out: %s", tx,
                          ty, z, distance, landed and "sent" or "failed"))
            return true
        end,
        wait = 2,
        useTicks = true
    }
end

------------------------------------------
-- # INSTANCES
------------------------------------------

local prayerFlicker = PrayerFlicker.new(Constants.PRAYER_FLICKER)

local playerManager = PlayerManager.new({
    health = CONFIG.playerManager.health,
    prayer = CONFIG.playerManager.prayer,
    comboBrewWithJellyfish = true,
    brewSipsPerRestore = 3
})

local timer = Timer.new()
timer.debug = CONFIG.debug.timer

-- Assigns the forward-declared local from the PREBUILD section above.
rotationManager = RotationManager.new(Constants.BOSS.id,
                                      {debug = CONFIG.debug.rotation})

local mechanics = Mechanics.new({
    debug = CONFIG.debug.mechanics,
    revolution = CONFIG.useRevolution
})

-- Assigns the forward-declared local from the PREBUILD section above.
warsRetreat = WarsRetreat:init({
    playerManager = playerManager,
    -- The prebuild task drives the rotation manager, so it must be passed in.
    rotationManager = rotationManager,
    timer = timer,
    -- Enables the PREBUILD task; nil disables it and the task never loads.
    prebuildSettings = CONFIG.usePrebuild and
        {rotation = PREBUILD_ROTATION, useDummy = true} or nil,
    bossData = {
        name = Constants.BOSS.name,
        portalId = Constants.OBJECTS.PORTAL.id,
        portalName = Constants.OBJECTS.PORTAL.name
    },
    userSettings = {
        bankPin = CONFIG.bankPin,
        waitForFullHp = CONFIG.waitForFullHp,
        summonConjures = CONFIG.warsRetreat.summonConjures,
        useAdrenCrystal = CONFIG.warsRetreat.useAdrenCrystal,
        bankIfInvFull = CONFIG.warsRetreat.bankIfInvFull,
        advancedMovement = CONFIG.warsRetreat.advancedMovement,
        surgeDiveChance = CONFIG.warsRetreat.surgeDiveChance,
        minimumValues = CONFIG.warsRetreat.minimumValues,
        taskOrder = CONFIG.warsRetreat.taskOrder,
        preset = CONFIG.preset
    }
})

------------------------------------------
-- # SURVIVAL
------------------------------------------

-- The fight had NO reactive defensives at all, which is a large part of why we
-- die before phase 4. Raksha's damage is brutal and much of it is typeless, so
-- prayer alone doesn't cover it: anima clouds ramp to 2,000 a tick, standing in
-- a pool is ~1,500 a tick, Mind Flay is ~600 a tick while immobilised, and a
-- countered shadow bomb still lands ~6,000.
--
-- Fired highest-value first when health drops below the threshold. Each is
-- cheap, off the damage rotation, and none of them break a mechanic response
-- (those run earlier and take the tick).
local SURVIVAL_ABILITIES = {
    "Devotion", -- negates the next hits outright
    "Debilitate", -- big incoming-damage reduction
    "Resonance", -- turns a big hit into a heal
    "Reflect"
}

-- Percent health at which we start spending defensives.
local SURVIVAL_HP_PERCENT = 55

--- Fires the best available defensive when we're getting low.
--- @return boolean used True if an ability was cast (the tick is consumed)
local function spendSurvivalAbilities()
    if Player:getHpPercent() > SURVIVAL_HP_PERCENT then return false end

    for _, ability in ipairs(SURVIVAL_ABILITIES) do
        if Utils:canUseAbility(ability) and Utils:useAbility(ability) then
            Utils:log("Low HP — " .. ability, "warn")
            return true
        end
    end
    return false
end

------------------------------------------
-- # CONJURES
------------------------------------------

-- Buff ids and the summoning animation, same values core/wars_retreat.lua uses.
local CONJURE_BUFFS = {ZOMBIE = 34177, GHOST = 34178, SKELETON = 34179}
local CONJURE_ANIMATION = 35502

-- How long to wait in the lobby for a summon to actually land before entering
-- without it (e.g. the ability is on cooldown from a previous life).
local CONJURE_WAIT_TICKS = 12

--- True when conjures are actually OUT — not merely requested. Clicking the
--- ability set a flag instantly, and entering the instance on that flag cut the
--- summon animation short, which is why conjures stopped appearing.
--- @return boolean
local function hasActiveConjures()
    return Player:getBuff(CONJURE_BUFFS.GHOST).found or
               Player:getBuff(CONJURE_BUFFS.SKELETON).found
end

--- True while the summon animation is playing, so we neither re-cast over it nor
--- walk away mid-cast.
--- @return boolean
local function conjuring()
    return Player:getAnimation() == CONJURE_ANIMATION
end

-- Post-cast lockout. There's a gap between clicking the ability and the game
-- registering it: the buffs aren't up yet, the animation hasn't started, and the
-- cooldown may not have applied — so every guard still reads "no conjures" and
-- we fire again, cancelling our own summon. This is the only check that holds
-- during that window.
local CONJURE_RECAST_TICKS = 10
local lastConjureTick = -99

--- @return boolean True when it's actually safe to attempt a summon
local function canSummonConjures()
    if hasActiveConjures() or conjuring() then return false end
    if (API.Get_tick() - lastConjureTick) < CONJURE_RECAST_TICKS then
        return false
    end
    return Utils:canUseAbility("Conjure Undead Army")
end

--- Casts the summon and opens the lockout window. Stamped before the cast so a
--- failed attempt can't spin either.
--- @return boolean cast
local function summonConjures()
    lastConjureTick = API.Get_tick()
    return Utils:useAbility("Conjure Undead Army")
end

------------------------------------------
-- # LOBBY PRE-FIGHT SEQUENCE
------------------------------------------

-- Conjure Undead Army -> Life Transfer -> one food -> enter the instance.
--
-- Life Transfer heals the conjures at the cost of OUR health, which is the whole
-- reason the food follows it rather than precedes it: eating first just tops up
-- health we are about to spend. Doing both in the lobby means we walk through
-- the gate with the conjures already healthy and our own health back up, instead
-- of paying for it on Raksha's clock.
local LIFE_TRANSFER_ABILITY = "Life Transfer"

-- Ticks allowed for the whole lobby sequence before we go in without it.
--
-- On top of CONJURE_WAIT_TICKS rather than replacing it: that constant covers
-- the summon landing, and these two steps come after it. Life Transfer can be on
-- cooldown from the previous kill and the food can simply be absent, so neither
-- step is allowed to hold the trip up indefinitely — the existing "go anyway"
-- escape in the Handle instance condition still owns that decision, this just
-- widens its window to fit the extra steps.
local LOBBY_PREP_WAIT_TICKS = CONJURE_WAIT_TICKS + 10

--- The first food in the bag, or nil when there is none.
---
--- Reads the player manager's own categorised inventory rather than scanning
--- again: _processInventory already classifies every health item and refreshes
--- every 5 ticks from the main loop, so the list is current in the lobby.
--- @return table|nil
local function lobbyFoodItem()
    local food = playerManager.inventory and playerManager.inventory.food
    if not food or #food == 0 then return nil end
    return food[1]
end

--- Eats one food from the ACTION BAR.
---
--- useBarItem, not Inventory:DoAction — see the note above useBarItem: every
--- item this script activates goes through the bar, and the inventory calls are
--- deliberately gone from this file. The food therefore has to be barred; if it
--- is not, useBarItem says so once and loudly rather than failing silently.
--- @return boolean ate
local function eatOneFood()
    local item = lobbyFoodItem()
    if not item or not item.name then return false end
    return useBarItem(item.name)
end

------------------------------------------
-- # SPECIAL ATTACK GATING
------------------------------------------

-- Special attack cooldowns show on the DEBUFF bar, not the ability bar, so
-- Utils:canUseAbility happily reports the spec as ready and we click straight
-- into a cooldown over and over. Gate on the debuff instead.
--
-- Add any further spec-cooldown debuff ids here as they're identified.
local SPEC_COOLDOWN_DEBUFFS = {
    55524, -- Death Grasp (Essence of Finality)
    55480 -- Omni Guard special attack
}

-- Backstop for a cooldown whose debuff id we don't know yet: after a spec is
-- fired, don't try again for this many ticks regardless of what the bars say.
-- Generous on purpose — a missed spec costs far less than spamming one.
local SPEC_RETRY_TICKS = 50
local lastSpecTick = -999

--- True while any known spec cooldown debuff is up, or while our own post-cast
--- window is still running.
--- @return boolean
local function specOnCooldown()
    for _, id in ipairs(SPEC_COOLDOWN_DEBUFFS) do
        if Player:getDebuff(id).found then return true end
    end
    return (API.Get_tick() - lastSpecTick) < SPEC_RETRY_TICKS
end

--- Marks a spec as just fired, opening the retry window.
local function markSpecUsed() lastSpecTick = API.Get_tick() end

--- @return boolean True when a special attack is worth attempting
local function canSpec()
    return API.GetAdrenalineFromInterface() > 23 and not specOnCooldown()
end

------------------------------------------
-- # ROTATION
------------------------------------------
local SWITCHES = {
    excalibur = "Enhanced Excalibur",
    lantern = "Soulbound lantern",
    deathguard = "Deathguard",
    genesisMain = "Roar of Awakening",
    genesisOff = "Ode to Deceit",
    omniGuard = "Omni guard",
    eof = "Essence of Finality"
}

--- The tail every phase rotation ends on. PVME: "improvise basics if not
--- phased" / "improvise if not dead", so `spend = false` — Improvise stays on
--- basics and conjure commands instead of dumping souls, adrenaline and specs
--- outside the burst windows the guide scripts them into.
--- @return table
local function improviseTail()
    return {
        label = "Improvise",
        type = "Improvise",
        style = "Necromancy",
        spend = false,
        wait = 3,
        useTicks = true
    }
end

--- The guide's "tc" / "target Raksha". Clicking him by id rather than pressing
--- the target-cycle key is unambiguous when pools and adds are on the floor.
--- @param wait? number
--- @return table
local function targetRaksha(wait)
    return {
        label = "Target Raksha",
        type = "Custom",
        action = function()
            -- Four args is how every DoAction_NPC call in this codebase is
            -- written; the arity warning is spurious.
            ---@diagnostic disable-next-line: missing-parameter
            return API.DoAction_NPC(0x2a, API.OFF_ACT_AttackNPC_route,
                                    {Constants.BOSS.id}, 60)
        end,
        wait = wait or 1,
        useTicks = true
    }
end

--- Equips an item only when it is actually carried. An account without the
--- switch skips the step entirely instead of stalling on a failed equip.
---
--- Equipped FROM THE ACTION BAR: a worn item sitting on the bar equips when
--- activated, so the switch is one bar press rather than an inventory click. The
--- carried check stays on the inventory, since that is the question it answers.
---
--- Returns true either way, exactly as the Inventory:Equip version did — the
--- result was never checked there either, and a switch that reports failure here
--- would stall the 0-tick spec sequences this feeds.
--- @param name string
--- @param wait? number
--- @return table
local function equipIfCarried(name, wait)
    return {
        label = "Equip " .. name,
        type = "Custom",
        condition = function() return #Inventory:GetItem(name) > 0 end,
        action = function()
            useBarItem(name)
            return true
        end,
        wait = wait or 1,
        useTicks = true,
        replacementAction = function() return true end
    }
end

--- Switches back to the Necromancy weapons after a 0-tick spec switch.
---
--- Not in the guide's text, but implied by it: a 0-tick switch is switch-in,
--- spec, switch-out, and without the switch-out we'd finish the phase wielding
--- Omni Guard. The weapon we swapped off lands in the inventory, so equipping
--- the first name we can actually find covers both the T100 shard-of-genesis
--- pair and the plain deathguard/lantern.
--- @param wait? number
--- @return table
local function restoreNecroWeapons(wait)
    return {
        label = "Re-equip Necromancy weapons",
        type = "Custom",
        action = function()
            -- Bar activation for the equip, inventory read to pick WHICH name —
            -- the weapon we swapped off is the one now sitting in the bag, and
            -- that is the one to put back on.
            for _, name in ipairs({SWITCHES.genesisMain, SWITCHES.deathguard}) do
                if #Inventory:GetItem(name) > 0 then
                    useBarItem(name)
                    break
                end
            end
            for _, name in ipairs({SWITCHES.genesisOff, SWITCHES.lantern}) do
                if #Inventory:GetItem(name) > 0 then
                    useBarItem(name)
                    break
                end
            end
            return true
        end,
        wait = wait or 0,
        useTicks = true
    }
end

--- Weapon special attack. canSpec() gates on the debuff bar, since the ability
--- bar does not reflect a special attack's cooldown.
--- @param wait? number
--- @return table
local function weaponSpec(wait)
    return {
        label = "Weapon Special Attack",
        type = "Custom",
        condition = canSpec,
        action = function()
            local used = Utils:useAbility("Weapon Special Attack")
            if used then markSpecUsed() end
            return used
        end,
        wait = wait or 3,
        useTicks = true,
        replacementAction = function() return true end
    }
end

--- Finger of Death costs 6 Necrosis. Without them the guide's line would cast
--- nothing at all, so we fall back to the builder it would have used anyway.
--- @param wait? number
--- @return table
local function fingerOfDeath(wait)
    return {
        label = "Finger of Death",
        condition = function() return Player:getBuff(30101).remaining >= 6 end,
        replacementLabel = "Touch of Death",
        wait = wait or 3,
        useTicks = true
    }
end

--- Residual Souls we insist on before spending them on a Volley.
---
--- NOT a requirement of the ability — Volley of Souls activates on TWO stacks
--- and consumes whatever it finds, for 135-165% each. This is a policy, and the
--- distinction matters because the number used to be 5 and read as though the
--- ability demanded it.
---
--- 5 was the soul CAP (three by default, five while a soulbound lantern is
--- equipped), and gating on the cap looks free — damage per soul is flat, so
--- batching costs nothing and each Volley lands for more. What it actually cost
--- was the casts themselves. Soul Sap is the only generator in these rotations
--- at one soul apiece, so from an empty bar phase 1 reaches two souls at its
--- first Volley and three at its second: BOTH failed the gate and fell through
--- to Soul Sap, every kill, and `replacementLabel` meant that never showed up as
--- anything going wrong. The gate wasn't wrong in principle, it was simply set
--- above what the rotation delivers.
---
--- 3 is the default cap and the figure the sibling Arch-Glacor rotations in this
--- repo already use. It clears every Volley site here except the immediate
--- second of a back-to-back pair, which nothing can save: the first Volley
--- empties the bar and one Soul Sap cannot refill it. Those keep falling through
--- to Soul Sap, which is what the PVME line asks for at that position anyway.
local VOLLEY_MIN_SOULS = 3

--- Volley of Souls, with Soul Sap as the builder to fall back on when we're
--- short — which also tops the stack up for the next attempt.
--- @param wait? number
--- @return table
local function volleyOfSouls(wait)
    return {
        label = "Volley of Souls",
        condition = function() return soulStacks() >= VOLLEY_MIN_SOULS end,
        replacementLabel = "Soul Sap",
        wait = wait or 3,
        useTicks = true
    }
end

--- Ticks to stop the player manager drinking for around the adrenaline potion.
--- Two inventory clicks in the same tick means one of them is thrown away, and
--- the one we lose is whichever went second.
local ADREN_POTION_DONT_DRINK = 4

--- The rotation's adrenaline drink, following Rasial's pattern
--- (rasial/presets.lua).
---
--- Takes whichever of the two potions in ADRENALINE_POTION_IDS you actually
--- brought — an Adrenaline renewal or an Enhanced replenishment. The step does
--- not branch on which: it hands the whole id list to the client and the first
--- one present is clicked. Bring either, bring both, bring any dose.
---
--- What you bring is NOT neutral, though. This step exists to fund the beat
--- below it in PHASE2_ROTATION, and that beat is written around the renewal's
--- refund. A replenishment restoring less adrenaline still drinks correctly and
--- still leaves the fight in a sane state — Death Skulls simply waits for the
--- bar rather than firing off the refund — but the phase runs a little slower
--- for it. Worth knowing before blaming the rotation.
---
--- Two things matter here and both were wrong before:
---
--- ORDER. Rasial drinks it immediately AFTER Living Death, not before, and
--- that's the whole point of the guide writing them as one beat ("Living death +
--- Adrenaline renewal"): Living Death spends the full 100, the renewal refunds
--- the bar, and the Death Skulls and double Finger of Death that follow are paid
--- for out of the refund. Drinking first meant that on entering the phase near
--- capped the `< 100` guard skipped the potion, Living Death then emptied the
--- bar, and nothing ever refilled it — so the potion went undrunk for the whole
--- kill and the Fingers fell through to their Touch of Death replacement.
---
--- DON'T-DRINK. The player manager drinks prayer potions on its own schedule
--- out of manageHealth/managePrayer, which runs in the same tick as the
--- rotation. Rasial pauses it around the renewal; we do the same, but against
--- the manager we're actually running — Rasial calls
--- `PlayerManager.new():dontDrink(4)`, which builds a throwaway instance and so
--- pauses nothing.
--- @param wait? number
--- @return table
local function adrenalinePotion(wait)
    return {
        label = "Adrenaline potion",
        type = "Custom",
        -- Still guarded, so we never burn the potion on a full bar — but by this
        -- point Living Death has just emptied it, so it passes.
        --
        -- Also guarded on actually HAVING one. Without this the step reports
        -- failure every attempt on a bag that ran out, which reads in the log
        -- exactly like a click that keeps missing.
        condition = function()
            -- ContainsAny, NOT Contains. This is why the potion was never drunk
            -- even back when the drink was an inventory click: Contains with a
            -- table asks whether the bag holds ALL ten ids — both potions, every
            -- dose of each, simultaneously — which cannot happen, so the
            -- condition was false on every attempt and the step fell straight
            -- through to its replacementAction. rasial/presets.lua has always
            -- used ContainsAny here; this copy did not.
            if not Inventory:ContainsAny(ADRENALINE_POTION_IDS) then
                return false
            end
            return API.GetAdrenalineFromInterface() < 100
        end,
        action = function()
            playerManager:dontDrink(ADREN_POTION_DONT_DRINK)

            -- One call, the whole id array, preference order preserved — the
            -- same contract the old DoAction_Inventory2 had, because GetAB_ids
            -- matches the bar by icon id rather than by name. Nothing here has
            -- to know which potion you brought or what dose is left.
            return useBarPotion(ADRENALINE_POTION_IDS, "adrenaline potion")
        end,
        wait = wait or 3,
        useTicks = true,
        replacementAction = function() return true end
    }
end

--- Conjure Undead Army, guarded so we never cast over a summon that's already
--- landed or still animating. Routed through summonConjures() rather than an
--- Ability step so the recast lockout is stamped and the mid-fight re-summon in
--- handleFight can't fire on top of it.
--- @param wait? number
--- @return table
local function conjureArmy(wait)
    return {
        label = "Conjure Undead Army",
        type = "Custom",
        condition = canSummonConjures,
        action = function() return summonConjures() end,
        wait = 4,
        useTicks = true,
        replacementAction = function() return true end
    }
end

local FIGHT_ROTATION = {
    -- --- Pre-fight: script infrastructure, not part of the PVME line --------
    -- The guide assumes a human has already put these up; nothing in it is
    -- displaced by them, and they all run before Raksha is engaged so they cost
    -- no DPS.
    --
    -- Waits follow Rasial's tuning rather than a blanket GCD: buffs and conjure
    -- commands are effectively off-GCD (0-1), inventory items and equipment
    -- switches are 1, movement is 2-3, and only real damage abilities pay the
    -- full 3. Death Skulls (4) needs longer than the GCD.
    {label = "Vengeance", wait = 1, useTicks = true},
    {label = "Darkness", wait = 2, useTicks = true},
    {label = "Vengeance", wait = 1, useTicks = true},
    {label = "Invoke Lord of Bones", wait = 2, useTicks = true},
    {label = "Surge", wait = 3, useTicks = true},
    {label = "Surge", wait = 2, useTicks = true},

    {label = "Command Vengeful Ghost", wait = 2, useTicks = true},
    {
        label = "Walk to safespot",
        type = "Custom",
        action = function()
            local dormant = Utils:findAll(Constants.DORMANT_BOSS.id,
                                          Constants.DORMANT_BOSS.type, 60)
            if #dormant == 0 then return false end
            local tile = dormant[1].Tile_XYZ

            local hx = math.floor(tile.x) - 9
            local hy = math.floor(tile.y)
            local hz = math.floor(tile.z)

            mechanics:setHome(hx, hy, hz)

            ---@diagnostic disable-next-line: undefined-global
            --return API.DoAction_WalkerW(WPOINT.new(hx, hy, hz))
        end,
        wait = 0,
        useTicks = true
    },

    -- --- PVME PHASE 1 -------------------------------------------------------
    -- Surge + Invoke death -> Command skeleton -> Split soul + Vuln bomb under
    -- Raksha -> tc + Bloat -> Death skulls -> Volley of souls -> Soul sap ->
    -- Divert -> Touch of death -> Soul sap -> Command skeleton
    --
    -- Ruination is NOT cast anywhere in here: it's in BUFFS, so the player
    -- manager turns it on and, crucially, back off after the kill. Casting it
    -- from both places races the activation delay and toggles it off again.
    {label = "Invoke Death", wait = 3, useTicks = true},
    {label = "Command Skeleton Warrior", wait = 2, useTicks = true},

    -- "Split soul + Vuln bomb under Raksha" — the bomb is thrown at whatever
    -- we're targeting, so acquiring him first is what puts it under him.
    targetRaksha(1),
    {label = "Split Soul", wait = 2, useTicks = true},
    {
        label = "Vulnerability bomb",
        -- Custom rather than `type = "Inventory"`: that step type resolves
        -- through the rotation manager's DoAction_Inventory3, which clicks the
        -- bag. Thrown from the action bar instead, like every other item here.
        type = "Custom",
        action = function() return useBarItem("Vulnerability bomb") end,
        wait = 0,
        useTicks = true,
        setupBoundary = true
    },

    -- "tc + Bloat": re-acquire Raksha, then open the damage.
    targetRaksha(1),
    {label = "Death Skulls", wait = 4, useTicks = true},
    {label = "Bloat", wait = 3, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Divert", wait = 4, useTicks = true},
    {label = "Touch of Death", wait = 4, useTicks = true},
    {label = "Soul Sap", wait = 5, useTicks = true},
    {label = "Command Skeleton Warrior", wait = 2, useTicks = true},

    -- Phase 1 runs out into this only if he survives the scripted opener; the
    -- phase 2 rotation replaces the whole thing on transition.
    improviseTail()
}

------------------------------------------
-- # PHASE 2 ROTATION
------------------------------------------

--- PVME phase 2, in full:
---   Living death + Adrenaline renewal -> Touch of death -> Death skulls ->
---   Soul sap -> Finger of death -> Finger of death -> Soul sap -> Basic ->
---   Basic -> Death skulls -> Basic -> Touch of death -> Basic ->
---   improvise basics if not phased
local PHASE2_ROTATION = {
    -- "Living death + Adrenaline renewal", in Rasial's order: the ultimate
    -- first, the drink straight after it.
    --
    -- Living Death costs the whole bar and the renewal hands it straight back,
    -- which is what pays for the Death Skulls and the Finger pair below — that
    -- refund IS why the guide writes the two as a single beat. Drinking first
    -- meant arriving near-capped, failing the "don't waste it" guard, skipping
    -- the potion, and then having Living Death empty the bar with nothing left
    -- to refill it.
    --
    -- Living Death takes 5 ticks to land before the next ABILITY, but a potion
    -- is an inventory action and off the global cooldown, so it slots into that
    -- window rather than extending it: 1 + 4 keeps Touch of Death where it was.
    {label = "Living Death", wait = 3, useTicks = true},
    adrenalinePotion(4),
    {label = "Touch of Death", wait = 3, useTicks = true},
    -- Death Skulls runs long; Rasial gives it 4 inside the Living Death window.
    {label = "Death Skulls", wait = 4, useTicks = true},
    volleyOfSouls(4),
    fingerOfDeath(4),
    fingerOfDeath(3),
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Death Skulls", wait = 4, useTicks = true},
    {label = "Soul Sap", wait = 2, useTicks = true}, -- weaves off Death Skulls
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Touch of Death", wait = 3, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    volleyOfSouls(3),
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},

    -- "improvise basics if not phased"
    improviseTail()
}

------------------------------------------
-- # PHASE 3 ROTATION
------------------------------------------
local PHASE3_ROTATION = {
    fingerOfDeath(3),
    fingerOfDeath(3),
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Death Skulls", wait = 4, useTicks = true},
    {label = "Bloat", wait = 3, useTicks = true},
    volleyOfSouls(4),
    {
        label = "Threads of Fate + target pools",
        type = "Custom",
        action = function()
            mechanics:requestPoolClear()
            return Utils:useAbility("Threads of Fate")
        end,
        wait = 3,
        useTicks = true
    },
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},

    -- "target Raksha + Volley of souls" — the pool clear leaves us on the
    -- cluster, and the Volley that follows has to land on the boss.
    targetRaksha(1),
    {
        label = "Vulnerability bomb",
        -- Custom rather than `type = "Inventory"`: that step type resolves
        -- through the rotation manager's DoAction_Inventory3, which clicks the
        -- bag. Thrown from the action bar instead, like every other item here.
        type = "Custom",
        action = function() return useBarItem("Vulnerability bomb") end,
        wait = 0,
        useTicks = true,
        setupBoundary = true
    },
    volleyOfSouls(3),
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Bloat", wait = 3, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Bloat", wait = 3, useTicks = true},
    {label = "Touch of Death", wait = 3, useTicks = true},
    {label = "Improvise", type = "Improvise", style = "Necromancy", spend = false, wait = 3, useTicks = true}
}

------------------------------------------
-- # PHASE 4 ROTATION
------------------------------------------
--- PVME phase 4, in full:
---   Anti -> Soul sap -> Touch of death -> Basic -> equip Excalibur -> equip
---   Soulbound lantern + Conjure army -> Soul sap -> Command skeleton ->
---   Command ghost -> Death skulls -> Ingenuity + Roar of awakening / Ode to
---   deceit spec (0 tick) -> Divert -> Soul sap -> Split soul -> Bloat ->
---   Omniguard spec -> Basic -> Soul sap -> Command skeleton -> Volley of
---   souls -> Touch of death -> Finger of death -> Deathguard90 EOF spec ->
---   improvise if not dead
---
--- Note what is NOT here: Living Death and the Adrenaline renewal. The guide
--- spends both in phase 2 and funds phase 4 from the adrenaline carried in plus
--- the specs, so neither appears in this line.
---
--- Every equip is conditional on carrying the item (see SWITCHES), so an
--- account without a switch flows straight past it rather than stalling.
local PHASE4_ROTATION = {
    -- "Anti" — Anticipation, off the global cooldown, up before the phase's
    -- first tail sweep.
    {label = "Anticipation", wait = 1, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Touch of Death", wait = 3, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},

    -- "equip Excalibur -> equip Soulbound lantern + Conjure army"
    equipIfCarried(SWITCHES.excalibur, 1),
    equipIfCarried(SWITCHES.lantern, 1),
    conjureArmy(3),

    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Command Skeleton Warrior", wait = 1, useTicks = true},
    {label = "Command Vengeful Ghost", wait = 1, useTicks = true},
    adrenalinePotion(4),
    {label = "Death Skulls", wait = 4, useTicks = true},
    
    -- "Ingenuity + Roar of awakening / Ode to deceit spec (0 tick)": Ingenuity
    -- makes the spec free, both T100 shard-of-genesis weapons go on inside the
    -- same tick (wait = 0), the spec fires, and we switch back off them.
    {
        label = "Ingenuity of the Humans",
        condition = canSpec,
        wait = 1,
        useTicks = true,
        replacementAction = function() return true end
    },
    equipIfCarried(SWITCHES.genesisMain, 0),
    equipIfCarried(SWITCHES.genesisOff, 0),
    weaponSpec(2),
    restoreNecroWeapons(1),

    {label = "Divert", wait = 3, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Split Soul", wait = 3, useTicks = true},
    {label = "Bloat", wait = 3, useTicks = true},

    -- "Omniguard spec", the same 0-tick shape: switch on, spec, switch back.
    equipIfCarried(SWITCHES.omniGuard, 0),
    weaponSpec(2),
    restoreNecroWeapons(1),

    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Command Skeleton Warrior", wait = 1, useTicks = true},
    volleyOfSouls(3),
    {label = "Touch of Death", wait = 3, useTicks = true},
    fingerOfDeath(3),

    -- "Deathguard90 EOF spec": the Essence of Finality amulet firing the stored
    -- deathguard special.
    equipIfCarried(SWITCHES.eof, 1),
    {
        label = "Essence of Finality",
        type = "Custom",
        condition = canSpec,
        action = function()
            local used = Utils:useAbility("Essence of Finality")
            if used then markSpecUsed() end
            return used
        end,
        wait = 3,
        useTicks = true,
        replacementAction = function() return true end
    },

    -- "improvise if not dead"
    {label = "Improvise", type = "Improvise", style = "Necromancy", spend = true, wait = 3, useTicks = true}
}

------------------------------------------
-- # PHASE 4 ROTATION
------------------------------------------
--- PVME phase 4, in full:
---   Anti -> Soul sap -> Touch of death -> Basic -> equip Excalibur -> equip
---   Soulbound lantern + Conjure army -> Soul sap -> Command skeleton ->
---   Command ghost -> Death skulls -> Ingenuity + Roar of awakening / Ode to
---   deceit spec (0 tick) -> Divert -> Soul sap -> Split soul -> Bloat ->
---   Omniguard spec -> Basic -> Soul sap -> Command skeleton -> Volley of
---   souls -> Touch of death -> Finger of death -> Deathguard90 EOF spec ->
---   improvise if not dead
---
--- Note what is NOT here: Living Death and the Adrenaline renewal. The guide
--- spends both in phase 2 and funds phase 4 from the adrenaline carried in plus
--- the specs, so neither appears in this line.
---
--- Every equip is conditional on carrying the item (see SWITCHES), so an
--- account without a switch flows straight past it rather than stalling.
local PHASE4_ROTATION = {
    -- "Anti" — Anticipation, off the global cooldown, up before the phase's
    -- first tail sweep.
    {label = "Anticipation", wait = 1, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Touch of Death", wait = 3, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},

    -- "equip Excalibur -> equip Soulbound lantern + Conjure army"
    equipIfCarried(SWITCHES.excalibur, 1),
    equipIfCarried(SWITCHES.lantern, 1),
    conjureArmy(3),

    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Command Skeleton Warrior", wait = 1, useTicks = true},
    {label = "Command Vengeful Ghost", wait = 1, useTicks = true},
    adrenalinePotion(4),
    {
        label = "Vulnerability bomb",
        -- Custom rather than `type = "Inventory"`: that step type resolves
        -- through the rotation manager's DoAction_Inventory3, which clicks the
        -- bag. Thrown from the action bar instead, like every other item here.
        type = "Custom",
        action = function() return useBarItem("Vulnerability bomb") end,
        wait = 0,
        useTicks = true,
        setupBoundary = true
    },
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Death Skulls", wait = 4, useTicks = true},
    
    -- "Ingenuity + Roar of awakening / Ode to deceit spec (0 tick)": Ingenuity
    -- makes the spec free, both T100 shard-of-genesis weapons go on inside the
    -- same tick (wait = 0), the spec fires, and we switch back off them.
    {
        label = "Ingenuity of the Humans",
        condition = canSpec,
        wait = 1,
        useTicks = true,
        replacementAction = function() return true end
    },
    equipIfCarried(SWITCHES.genesisMain, 0),
    equipIfCarried(SWITCHES.genesisOff, 0),
    weaponSpec(2),
    restoreNecroWeapons(1),

    {label = "Divert", wait = 3, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Split Soul", wait = 3, useTicks = true},
    {label = "Bloat", wait = 3, useTicks = true},

    -- "Omniguard spec", the same 0-tick shape: switch on, spec, switch back.
    equipIfCarried(SWITCHES.omniGuard, 0),
    weaponSpec(2),
    restoreNecroWeapons(1),

    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Command Skeleton Warrior", wait = 1, useTicks = true},
    volleyOfSouls(3),
    {label = "Touch of Death", wait = 3, useTicks = true},
    fingerOfDeath(3),

    -- "Deathguard90 EOF spec": the Essence of Finality amulet firing the stored
    -- deathguard special.
    equipIfCarried(SWITCHES.eof, 1),
    {
        label = "Essence of Finality",
        type = "Custom",
        condition = canSpec,
        action = function()
            local used = Utils:useAbility("Essence of Finality")
            if used then markSpecUsed() end
            return used
        end,
        wait = 3,
        useTicks = true,
        replacementAction = function() return true end
    },

    -- "improvise if not dead"
    {label = "Improvise", type = "Improvise", style = "Necromancy", spend = true, wait = 3, useTicks = true}
}

------------------------------------------
-- # PHASE ROTATION TABLE
------------------------------------------

--- Rotation to run in each phase, replacing the previous one on transition.
---
--- Phase 1 is absent on purpose: FIGHT_ROTATION already IS setup + phase 1, and
--- it's loaded on instance entry so the pre-fight steps run first. The loader in
--- handleFight starts from the phase we entered on, so nothing reloads at 1.
local PHASE_ROTATIONS = {
    [2] = PHASE2_ROTATION,
    [3] = PHASE3_ROTATION,
    [4] = PHASE4_ROTATION
}

------------------------------------------
-- # REVOLUTION MODE
------------------------------------------

-- With Revolution enabled the game's action bar handles the damage rotation, so
-- the script stops casting damage abilities and only does the things Revolution
-- cannot: pre-fight buffs, conjures, positioning, engaging, every mechanic
-- response (Freedom / Escape / Anticipation / dodges), prayers, food and
-- defensives.
--
-- The setup rotation is the prefix of FIGHT_ROTATION up to the END OF SETUP
-- marker: buffs, conjures, the walk to the safespot, Surge/Invoke Death, Split
-- Soul, the Vulnerability bomb and the target cycle onto Raksha. Revolution
-- won't do any of that, so it still runs. There's deliberately no Improvise tail
-- — once setup is done the rotation simply ends and Revolution takes over.
-- (Ruination and the overload are handled by the player manager via BUFFS in
-- both modes, not by the rotation.)
--
-- Derived from the `setupBoundary` flag rather than a label match, so
-- re-ordering the pre-fight can't silently move the boundary.
local SETUP_STEP_COUNT = #FIGHT_ROTATION
for i, step in ipairs(FIGHT_ROTATION) do
    if step.setupBoundary then
        SETUP_STEP_COUNT = i
        break
    end
end

local REVO_ROTATION = {}
for i = 1, SETUP_STEP_COUNT do REVO_ROTATION[i] = FIGHT_ROTATION[i] end

--- The rotation to load, per the Revolution setting.
--- @return table
local function activeRotation()
    if CONFIG.useRevolution then return REVO_ROTATION end
    return FIGHT_ROTATION
end

------------------------------------------
-- # PHASE 4 SPECIAL ACTION
------------------------------------------

--- The special action button that appears in phase 4.
---
--- FIRST ATTEMPT FAILED, and the reason shapes this design: it gated the click
--- solely on buff 45036, and the button was observed plainly on screen without a
--- single click going out. Player:getBuff reads the BUFF BAR only
--- (Buffbar_GetIDstatus), so if 45036 isn't a buff-bar entry — it may live on the
--- debuff bar, or not be a bar entry at all — that gate never opens.
---
--- So the button itself is now the trigger. Interface 743 is the shared
--- special-action container (Kerapac's "Warp time" button reads out of the same
--- place), and we scan it for button text. That's the precise signal: it goes
--- false the moment the button is consumed, which also answers the original
--- worry about the buff outliving the button.
---
--- The buff is kept only as a FALLBACK for the case where the scan can't see
--- Raksha's button either. Once the scan has proven itself even once we stop
--- consulting the buff at all, because the scan is strictly better.
---
--- Either way a click cap plus pacing applies, so no signal — stuck true, or
--- lingering after the button is gone — can turn into a click loop.
local SPECIAL_ACTION_BUFF = 12171
local SPECIAL_ACTION_MAX_CLICKS = 3 -- hard cap per buff window
local SPECIAL_ACTION_RETRY_TICKS = 2 -- pacing between retries

--- The components scanned for the button's label. Built once: a fresh table per
--- call would allocate on every check, and this runs inside the fight loop.
--- Component 6 is the one Raksha's button is clicked through; 0 and 1 are
--- included because that's where other bosses' buttons expose their label and
--- the container layout isn't guaranteed to be identical.
local SPECIAL_ACTION_COMPONENTS = {
    {743, 0, -1, 0}, {743, 1, -1, 0}, {743, 6, -1, 0}
}

--- Last tick the scan actually ran, and what it answered.
---
--- clickSpecialAction is called unconditionally from the fight handler, which is
--- `parallel` with `cooldown = 0` — so this runs 12-20 times per GAME TICK.
--- While the call underneath was a nil-pcall that cost nothing. A real native
--- scan of three components repeated that often is pure waste, since the button
--- cannot appear and vanish within one tick. Mechanics:siphonImminent throttles
--- its chat read exactly this way and for exactly this reason.
local lastSpecialScanTick = -1
local lastSpecialScanResult = false

--- True while the special action button is still drawn on screen.
--- @return boolean
local function specialActionVisible()
    local tick = API.Get_tick()
    if tick == lastSpecialScanTick then return lastSpecialScanResult end
    lastSpecialScanTick = tick
    lastSpecialScanResult = false

    -- API.ScanForInterfaceTest2Get IS GONE as of the interface API update, and
    -- calling it here is why this scan never once returned true. It was not in
    -- api.lua at all, so the pcall was catching "attempt to call a nil value"
    -- every single check — which reads exactly like "the button was never on
    -- screen", so specialActionScanWorks never latched and the click fell back
    -- to buff 12171 forever. That is the fallback the comment above already
    -- describes as unreliable.
    --
    -- ScanForInterfaceTest2GetAll is the replacement, and it is NOT a chain
    -- scan: it hands back one row PER COMPONENT rather than resolving the list
    -- down to a leaf. That suits this check unchanged — we only care whether
    -- any of the three is carrying text — but it is why the row order can no
    -- longer be assumed to match the order the ids are listed in.
    local ok, found = pcall(API.ScanForInterfaceTest2GetAll,
                            SPECIAL_ACTION_COMPONENTS, false)
    if not ok or type(found) ~= "table" then return false end

    for _, entry in ipairs(found) do
        -- BOTH fields, textids first. The inspector reports these separately and
        -- a cell can populate either: under the new API the label routinely
        -- arrives on textids with textitem left empty, which core/helper.lua
        -- (getLootWindowAmount, the instance-timer check) already reads for.
        -- Checking only textitem — as this did — is a second way to read
        -- nothing off a component that is perfectly correct.
        if entry then
            local ids = entry.textids
            local item = entry.textitem
            if (type(ids) == "string" and #ids > 0) or
                (type(item) == "string" and #item > 0) then
                lastSpecialScanResult = true
                return true
            end
        end
    end
    return false
end

------------------------------------------
-- # FIGHT
------------------------------------------

-- Extra game ticks to keep holding AFTER the phase 4 transition animation ends.
-- The animation stopping is not the same as being able to act: we stayed locked
-- a moment longer, so the rotation resumed slightly too early and the opening
-- abilities of PHASE4_ROTATION were swallowed.
local PHASE4_TRANSITION_GRACE_TICKS = 4

-- Consecutive GAME TICKS Raksha must look dead/absent before we register a kill
-- on the fallback path. The definitive signal is the subdued Raksha (27353)
-- appearing, which needs no confirmation at all; these only cover the moment
-- before he swaps id, or a kill where 27353 is somehow never detected.
--
-- "Ticks" is load-bearing here. The "Handle fight" task is `parallel` with
-- `cooldown = 0`, so it runs every main-loop iteration — 12-20 times per 600ms
-- game tick. deadStreak used to be incremented once per CALL, which made the old
-- 3-"tick" guard worth about 150ms and no real protection against a bad scan.
-- That is what teleported us out of a live phase 4 with Raksha still up.
--
-- Two windows, because a bad read and a real kill look identical for a moment:
-- when he was last seen nearly dead a short confirmation is trustworthy, but
-- when he still had real HP left "he vanished" is almost always a scan flicker,
-- so we wait far longer before believing it. The long window still exists so a
-- genuine kill can never strand us in the instance.
local KILL_CONFIRM_TICKS = 5 -- ~3s, when he was already nearly dead
local KILL_CONFIRM_TICKS_HIGH_HP = 50 -- ~30s, when he still had HP left

-- Last-known HP at or below which the short confirmation window applies.
local KILL_TRUST_HP = 20000

-- How long we'll keep trying to loot after a kill before teleporting out anyway.
-- The teleport waits for the ground pile to be EMPTY, so without a deadline
-- anything we can't actually pick up — a full inventory being the realistic case
-- — parks the script in the dead instance forever. 50 ticks is ~30 seconds,
-- which is far longer than a Loot All needs.
local LOOT_TIMEOUT_TICKS = 50

--- The loot window, and the component that takes everything in it.
---
--- MEASURED, supplied from the interface inspector. Both of the opaque natives
--- this used to rely on — API.LootWindowOpen_2 and API.DoAction_LootAll_Button
--- — stopped answering, and the failure mode was ugly: the window check read
--- false while the window was plainly on screen, so pickUpLoot fell through to
--- the ground-item branch and clicked the pile over and over (the
--- "DoAction_G_Item: 48076" spam — 48076 is Dinosaur bones (noted), a common
--- off the drop table).
---
--- Component 21 is the one the working action routes through. The inspector also
--- shows the button itself at 1622:15; the two are not necessarily the same
--- thing, and 21 is what the DoAction below was verified with.
local LOOT_INTERFACE = 1622
local LOOT_ALL_COMPONENT = 21

--- Components on 1622 known to carry text while the window is up.
---
--- The same four core/helper.lua reads the "Value:" line off in
--- getLootWindowAmount, so if any of them is holding text the window is open.
local LOOT_WINDOW_TEXT = {
    {LOOT_INTERFACE, 4, -1, 0}, {LOOT_INTERFACE, 6, -1, 0},
    {LOOT_INTERFACE, 2, -1, 0}, {LOOT_INTERFACE, 3, -1, 0}
}

--- True while the loot window is on screen.
---
--- Two signals, because neither is trustworthy alone. GetInterfaceOpenBySize is
--- the documented way to test a window with no varbit, but Arch-Glacor already
--- caught it reporting closed on a window that was visibly up
--- (Arch-Glacor/AG/config.lua, chestInterfaceOpen), so a text scan backs it up.
--- Answering "open" too eagerly is the safe direction here: the worst case is we
--- press Loot All at nothing, where the old failure clicked the ground pile a
--- dozen times a tick.
--- @return boolean
local function lootWindowOpen()
    if API.GetInterfaceOpenBySize(LOOT_INTERFACE) then return true end

    local ok, rows = pcall(API.ScanForInterfaceTest2GetAll, LOOT_WINDOW_TEXT,
                           false)
    if not ok or type(rows) ~= "table" then return false end

    for _, row in ipairs(rows) do
        if row then
            local ids = row.textids
            local item = row.textitem
            if (type(ids) == "string" and #ids > 0) or
                (type(item) == "string" and #item > 0) then
                return true
            end
        end
    end
    return false
end

local RakshaFight = {
    variables = {
        engaged = false, -- Rotation loaded and fight underway
        bossDead = false,
        looted = false,
        lootDeadline = 0, -- tick we give up looting and teleport out regardless
        lootTimeoutLogged = false,
        -- Tick the ground pile was last clicked, so opening the window is paced
        -- to once per game tick no matter how often the task runs.
        lastLootClickTick = -1,
        bossSeen = false, -- Latched once Raksha has been detected this trip
        sawBossAlive = false, -- Latched once Raksha is seen with health > 0
        deadStreak = 0, -- Consecutive GAME TICKS the boss has looked dead/absent
        lastDeadTick = nil, -- tick deadStreak last counted, so it counts once/tick
        lastKnownHealth = -1, -- HP the last time we actually saw him alive
        deadStreakWarned = false, -- one-shot log for a suspiciously long streak
        conjured = false, -- Latched once conjures are summoned this trip
        luckEquipped = false, -- Latched once the luck ring is swapped in
        -- Phase whose rotation is currently loaded. Starts at 1 because
        -- FIGHT_ROTATION (setup + phase 1) is what instance entry loads, so
        -- there's nothing to swap in until we reach phase 2.
        loadedPhase = 1,
        specialActionClicks = 0, -- Clicks spent on the current availability window
        lastSpecialActionTick = -99, -- Pacing for special action retries
        specialActionScanWorks = false, -- Latched once the 743 scan sees the button
        transitionHolding = false, -- True while sitting out the phase 4 transition
        transitionEndTick = nil, -- Tick the transition animation stopped
        transitionReattacked = false, -- Raksha re-targeted during the grace window
        -- Duo only: consecutive GAME TICKS with no partner visible, and the tick
        -- that streak last counted on. See RakshaFight:partnerMissingTicks.
        partnerMissingStreak = 0,
        lastPartnerCheckTick = nil
    }
}

--- In the boss room: in an instance and not at War's Retreat. True the moment
--- we enter — before Raksha is detected — so the pre-fight setup runs straight
--- away. The lobby (before the gate) is NOT instanced, so InInstancedArea alone
--- separates it from the boss room; no gate check is needed here, and adding one
--- was wrong — the gate is still within range right after you walk through it,
--- which was delaying the whole pre-fight.
--- @return boolean
function RakshaFight:atLocation()
    -- During death recovery we're heading to Death's Office / War's Retreat, not
    -- fighting — and Death's Office may itself read as instanced.
    if Common.isDead then return false end
    if warsRetreat:atLocation() then return false end
    return API.InInstancedArea()
end

--- Per-GAME-TICK memo for the boss read. See getBoss.
local fightBossCache, fightBossCacheTick = nil, -1

--- Raksha's entity info.
---
--- MEMOISED PER GAME TICK for the same reason Mechanics:getBoss is: handleFight
--- calls this at the top and is driven by the "Handle fight" task, which is
--- `parallel` with `cooldown = 0` — 12-20 native NPC scans per tick for a value
--- the game only updates on tick boundaries. buildGUIData calls it too, once per
--- RENDERED FRAME, which added the client's whole frame rate on top.
---
--- This is a SEPARATE cache from the mechanics one because the two return
--- different shapes (this one is Utils:getEntityInfo — health/animation/tile;
--- the other is life/anim/x/y/z/distance). Sharing one read would mean reshaping
--- at every call site, which is a bigger change than the delay warrants.
--- @return table
function RakshaFight:getBoss()
    local tick = API.Get_tick()
    if fightBossCache and tick == fightBossCacheTick then
        return fightBossCache
    end

    fightBossCacheTick = tick
    fightBossCache = Utils:getEntityInfo(Constants.BOSS.id, Constants.BOSS.type,
                                         60)
    return fightBossCache
end

--- Per-GAME-TICK memo for the subdued-Raksha read. See subduedPresent.
local subduedCache, subduedCacheTick = false, -1

--- True once the subdued Raksha (27353) is on the floor — he's dead and the drop
--- can be looted.
---
--- MEMOISED PER GAME TICK. This is read from the "Registering the kill" task
--- CONDITION, and Timer:run evaluates every task's condition on every cycle
--- (core/timer.lua:247) — not just the ones that could fire. The three gates
--- ahead of it (atLocation, engaged, not bossDead) are all true for the whole
--- fight, so this scan ran on every loop iteration from the pull to the kill.
--- @return boolean
function RakshaFight:subduedPresent()
    local tick = API.Get_tick()
    if tick == subduedCacheTick then return subduedCache end

    local sub = Constants.BOSS_SUBDUED
    subduedCacheTick = tick
    subduedCache = #Utils:findAll(sub.id, sub.type, 60) > 0
    return subduedCache
end

--- True while Raksha is playing the phase 4 transition.
---
--- Detected from his ANIMATION, not from a cutscene varbit. The previous version
--- keyed off varbit 16903 (quest.lua's "IsInCutscene(maybe)") and that turned out
--- to be quest-only — it never read true here, so nothing was ever held back and
--- the transition ran exactly as badly as before.
---
--- Animation 33707 does double duty, which is the whole subtlety:
---   * In phases 1-3 it is the tail sweep we answer with Freedom.
---   * At 200k HP or below it is the phase 4 transition.
---
--- HP alone cannot separate them. Phase 4 itself runs 400k down to 0 and he tail
--- sweeps the whole way through, so at 150k in phase 4 a 33707 is a real sweep
--- that MUST get its Freedom — treating that as a transition would freeze us
--- standing in it. The latch is what disambiguates: the transition happens
--- exactly once, before the phase 4 rotation is loaded, so once loadedPhase
--- reaches 4 this can only ever be a sweep.
---
--- Holding through it matters for two reasons. The obvious one is that abilities
--- sent during the transition are swallowed. The damaging one is that
--- PHASE4_ROTATION was being loaded the instant HP crossed 200k — mid-transition
--- — and the rotation manager walks each step's `wait` down on its own schedule
--- whether or not the ability landed, so the Adrenaline renewal / Living Death /
--- Death Skulls opener was spent against a locked player and we arrived in phase
--- 4 already parked on the Improvise tail.
--- The animation ending is NOT the end of the transition — we're still locked for
--- a moment afterwards, which is why the first few phase 4 abilities were being
--- thrown away. So the hold runs on for this many ticks after 33707 stops.
--- @param boss table
--- @return boolean
function RakshaFight:inPhase4Transition(boss)
    -- Already through it: from here 33707 is an ordinary tail sweep.
    if self.variables.loadedPhase >= 4 then return false end

    local animating = boss.found and boss.health > 0 and
                          boss.health <= Constants.PHASE_HP.P4 and
                          boss.animation == Constants.ANIM.TAIL_SWEEP_FREEDOM

    if animating then
        self.variables.transitionEndTick = nil -- restart the grace on release
        return true
    end

    -- Not animating. Only run the grace period if we were actually holding —
    -- otherwise this would delay every fight that never saw a transition.
    if not self.variables.transitionHolding then return false end

    local tick = API.Get_tick()
    self.variables.transitionEndTick = self.variables.transitionEndTick or tick
    return (tick - self.variables.transitionEndTick) <
               PHASE4_TRANSITION_GRACE_TICKS
end

--- Clicks the phase 4 special action button. See SPECIAL_ACTION_BUFF for the
--- signal design and why the buff alone was not enough.
--- @return boolean clicked True if we clicked this tick
function RakshaFight:clickSpecialAction()
    local v = self.variables

    local scanned = specialActionVisible()
    if scanned and not v.specialActionScanWorks then
        v.specialActionScanWorks = true
        Utils:log("Special action: interface 743 scan is working — " ..
                      "using it as the trigger", "debug")
    end

    -- Prefer the scan once it has proven it can see this button. It's precise
    -- and it clears the moment the button is consumed. Only fall back to the
    -- bars while the scan has never seen anything, since a scan that always
    -- reads false would otherwise mean never clicking at all — which is exactly
    -- the failure we're fixing.
    local available, why
    if v.specialActionScanWorks then
        available, why = scanned, "scan"
    else
        local onBuffBar = Player:getBuff(SPECIAL_ACTION_BUFF).found
        -- Checked as a DEBUFF too: getBuff only reads the buff bar, and the
        -- likeliest reason the first version never fired is that 45036 isn't
        -- there.
        local onDebuffBar = Player:getDebuff(SPECIAL_ACTION_BUFF).found
        available = onBuffBar or onDebuffBar
        why = onBuffBar and "buff bar" or "debuff bar"
    end

    if not available then
        v.specialActionClicks = 0 -- re-arm for the next appearance
        return false
    end

    -- The cap applies to BOTH paths, so neither a lingering buff nor a scan
    -- stuck reading true can become a click loop. It resets above as soon as the
    -- signal drops.
    if v.specialActionClicks >= SPECIAL_ACTION_MAX_CLICKS then return false end

    local tick = API.Get_tick()
    if (tick - v.lastSpecialActionTick) < SPECIAL_ACTION_RETRY_TICKS then
        return false
    end

    v.lastSpecialActionTick = tick
    v.specialActionClicks = v.specialActionClicks + 1

    -- The trailing pixel_x/pixel_y args are optional in practice; every other
    -- caller in this codebase passes seven, so the arity warning is spurious.
    ---@diagnostic disable-next-line: missing-parameter
    API.DoAction_Interface(0x2e, 0xffffffff, 1, 743, 6, -1,
                           API.OFF_ACT_GeneralInterface_route)
    Utils:log(string.format("Special action clicked %d/%d (via %s)",
                            v.specialActionClicks, SPECIAL_ACTION_MAX_CLICKS, why))
    return true
end

------------------------------------------
-- # LOBBY
------------------------------------------

-- Between the portal and the boss room is a short lobby with a Security gate,
-- identical in flow to Rasial's Citadel lobby and its Chamber doorway. We
-- conjure here (conjures carry into the instance) and then start the fight via
-- the gate — rejoining the existing instance when one is still live, and only
-- creating a fresh one when needed, so we don't reset its ~1 hour timer each
-- kill. Instance-creation handling is copied from Rasial verbatim; the 1188 /
-- 1591 interface ids are the shared RS3 instance dialogs, not boss-specific.

-- Seconds to wait for a new-instance attempt to take effect before retrying.
local INSTANCE_TIMEOUT = 30

--- The instance settings window, and the component on it that confirms and
--- creates the instance.
---
--- This window has NO varbit, which is the whole reason the old detection broke.
--- It used `API.VB_FindPSettinOrder(2874).state == 18`, and 2874 is the shared
--- "blocking interface" varbit that PACKS TWO BYTES (api.lua: "checks both set1
--- and set2 any match in those 2 bytes"). Comparing the raw state to a single
--- number only works when nothing else is flagged in the other byte, so it was
--- always fragile — any change to what else counts as blocking silently breaks
--- it, and nothing else in the codebase reads 2874 that way.
---
--- API.GetInterfaceOpenBySize is the right tool and says so in its own doc:
--- "used for determining if interfaces with no VB and floating popup windows are
--- open". FleshHatcher already detects this exact window that way.
local INSTANCE_INTERFACE = 1591
local INSTANCE_CONFIRM_COMPONENT = 56

--- "Max players" field on the same settings panel.
---
--- Component id taken from kerapac/KerapacPreparation.lua:HandleSetupInstance,
--- which drives interface 1591 in production — the same panel this script
--- confirms through component 56, so the ids belong to the same layout.
local INSTANCE_MAX_PLAYERS_COMPONENT = 68

--- Varbit holding when OUR instance expires, as an absolute count of minutes
--- since the epoch. Zero/absent means we have no instance.
---
--- Private to this script on purpose. This lived in core.helper for a while as a
--- shared static (Utils.INSTANCE_EXPIRY_VARBIT) because Raksha and Rasial read
--- the same number — but the instance belongs to the script that made it, so the
--- id and the read that consumes it stay local and each script carries its own
--- isInstanceValid.
local INSTANCE_EXPIRY_VARBIT = 9925

--- Minutes that must remain before we'll rejoin rather than make a fresh
--- instance.
---
--- 1 — rejoin whenever the instance has ANY time left on it.
---
--- There is no mid-fight risk in rejoining a nearly-expired instance. The timer
--- reaching 00:00 does NOT evict you: the instance keeps running and the kill
--- finishes normally. What 00:00 means is that it can no longer be rejoined, so
--- the next trip has to build a fresh one — which is exactly what a reading of 0
--- produces here.
---
--- This was 6, guarding against a mid-fight expiry that does not happen. All it
--- achieved was abandoning instances with several usable minutes left on them.
local INSTANCE_MIN_MINUTES = 1

--- Seconds to leave the instance flow alone after a successful creation.
---
--- This is a latch, and dropping it is what broke instance entry: the OLD code
--- set `instanceStartTime = os.clock()` on success, and that non-zero value was
--- doing double duty as both the age tracker AND the "we have an instance now"
--- flag that flipped the next call from create to rejoin. Replacing the age
--- tracking with varbit 9925 was right; losing the flag was not.
---
--- Without it, the moment the confirm click lands we come straight back round,
--- read the varbit before the game has populated it, see 0 minutes left, and
--- start creating another instance — clicking a gate we are already walking
--- through. That spins until the timeout watchdog gives up and teleports to
--- War's Retreat.
local INSTANCE_CREATE_GRACE = 12

local RakshaLobby = {
    variables = {
        -- Short post-creation latch (see INSTANCE_CREATE_GRACE), NOT an age
        -- tracker — varbit 9925 owns the age.
        instanceCreatedAt = 0,
        -- Duo leader only: whether the max-players field has been set on the
        -- settings panel currently open. Cleared on confirm, so each new
        -- instance sets its own size.
        instanceSizeSet = false,
        -- True from the moment the Start button is confirmed until we either
        -- get into the instance or a dialogue tells us the old one is still
        -- alive. It is what separates the dialogue that is part of the create
        -- flow from the one that means "you already have an instance".
        startConfirmed = false,
        -- Lobby pre-fight sequence latches: Conjure -> Life Transfer -> food.
        -- Cleared the moment we are no longer at the lobby (see the Handle
        -- instance condition) so each trip runs the sequence fresh.
        lifeTransferDone = false,
        foodEaten = false,
        rejoinAttempts = 0, -- consecutive rejoin tries this trip
        lastInstanceAttempt = 0, -- os.clock() of the pending new-instance attempt
        instanceAttemptCount = 0, -- consecutive new-instance timeouts
        lobbyEnteredTick = nil -- tick we arrived, for the conjure wait window
    }
}

--- Last minutes-left value logged, so the diagnostic prints on change rather
--- than on every pass of the lobby task.
local loggedMinutesLeft = nil

--- Minutes left on the current instance; 0 when there isn't one.
---
--- Read through VB_FindPSettinOrder, which hands the value back as a
--- settings-order entry with the number on `.state`. NOT API.GetVarbitValue —
--- that one is still in api.lua but reads the varbit namespace out of the cache
--- and returns a bare number (-1 when the cache is not loaded), so it is neither
--- a drop-in nor the same lookup.
---
--- pcall'd because the native read can throw rather than return, which would
--- take the whole script down from inside a task.
---
--- A 0 here is ambiguous: it means "no instance" AND "the game has not populated
--- the varbit yet", which is why the create path has INSTANCE_CREATE_GRACE.
--- @return number
local function instanceMinutesLeft()
    local ok, expiry = pcall(API.VB_FindPSettinOrder, INSTANCE_EXPIRY_VARBIT)
    if not ok or not expiry or type(expiry.state) ~= "number" or
        expiry.state <= 0 then
        return 0
    end

    -- The varbit is an absolute wall-clock minute, so this compares against the
    -- local clock rather than any elapsed time we tracked ourselves. The -1
    -- discards the partial minute we are currently inside.
    --
    -- Floored so the result is always an integer: it is logged with %d, and %d
    -- on a float without an exact integer representation raises "bad argument to
    -- 'format'" in Lua 5.3+.
    local left = math.floor(expiry.state - math.floor(os.time() / 60)) - 1
    if left < 0 then left = 0 end

    if loggedMinutesLeft ~= left then
        loggedMinutesLeft = left
        Utils:log(string.format(
                      "Instance timer: %d min left (varbit %d reads %d)", left,
                      INSTANCE_EXPIRY_VARBIT, expiry.state), "debug")
    end

    return left
end

--- True when we already own an instance worth rejoining, with the minutes left
--- alongside it for the log line at the call site.
---
--- Below INSTANCE_MIN_MINUTES this deliberately says no and we build fresh:
--- rejoining one that expires mid-kill is worse than the rebuild it avoids.
--- @return boolean, number
local function isInstanceValid()
    local minutesLeft = instanceMinutesLeft()
    return minutesLeft >= INSTANCE_MIN_MINUTES, minutesLeft
end

--- True while the instance settings window is on screen.
--- @return boolean
local function instanceInterfaceOpen()
    return API.GetInterfaceOpenBySize(INSTANCE_INTERFACE) and true or false
end

--- In the lobby: not at War's Retreat, NOT yet in the instance, and the Security
--- gate is nearby. Requiring "not instanced" keeps the lobby and the fight
--- mutually exclusive — the moment we pass through the gate we're instanced, so
--- the lobby switches off and the fight takes over.
--- @return boolean
function RakshaLobby:atLocation()
    -- While dead we route through War's Retreat to re-bank, not back into the
    -- instance, so report "not at lobby" during recovery.
    if Common.isDead then return false end
    if warsRetreat:atLocation() then return false end
    if API.InInstancedArea() then return false end
    local gate = Constants.OBJECTS.SECURITY_GATE
    return #Utils:findAll(gate.id, gate.type, 30) > 0
end

--- Creates a fresh instance through the gate.
---
--- Three stages, checked newest-first so we always answer the furthest point
--- we've reached rather than re-clicking an earlier one:
---   1. The settings window is up -> confirm it, and we're in.
---   2. A dialogue is up          -> pick the SECOND option. This is part of
---      the create flow, not an "you already have an instance" prompt — it has
---      to be answered or the settings window never appears.
---   3. Neither                   -> click the gate to start the flow.
---
--- Whether we should be creating an instance at all is decided upstream in
--- handleInstance, from the expiry varbit. By the time we're here that call has
--- already been made, so the dialogue is simply a step to get through.
--- @return boolean
function RakshaLobby:startNewInstance()
    local gate = Constants.OBJECTS.SECURITY_GATE

    -- Start the timeout clock on the first attempt
    if self.variables.lastInstanceAttempt == 0 then
        self.variables.lastInstanceAttempt = os.clock()
    end

    if instanceInterfaceOpen() then
        -- DUO LEADER: widen the instance before confirming it.
        --
        -- Has to happen on the CREATE. A solo instance has no second slot to
        -- give away later, so a partner trying to join one is simply refused —
        -- there is no recovering from this after the confirm click.
        --
        -- Latched, and returns false rather than falling through to the confirm:
        -- the size field needs a pass to take, and confirming in the same pass
        -- would bank whatever was in the box before we typed.
        if CONFIG.party.isLeader and not self.variables.instanceSizeSet then
            self.variables.instanceSizeSet = true
            Utils:log(string.format("Duo: setting instance size to %d players",
                                    CONFIG.party.size))

            ---@diagnostic disable-next-line:missing-parameter
            API.DoAction_Interface(0x24, 0xffffffff, 1, INSTANCE_INTERFACE,
                                   INSTANCE_MAX_PLAYERS_COMPONENT, -1,
                                   API.OFF_ACT_GeneralInterface_route)
            API.Sleep_tick(2)
            API.KeyboardPress(CONFIG.party.size, 60, 110)
            API.KeyboardPress2(0x0D, 60, 110) -- Enter
            API.Sleep_tick(2)
            return false
        end

        ---@diagnostic disable-next-line:missing-parameter
        if API.DoAction_Interface(0x24, 0xffffffff, 1, INSTANCE_INTERFACE,
                                  INSTANCE_CONFIRM_COMPONENT, -1,
                                  API.OFF_ACT_GeneralInterface_route) then
            Utils:log("Instance settings window confirmed — creating instance")
            self.variables.lastInstanceAttempt = 0
            self.variables.instanceAttemptCount = 0
            self.variables.rejoinAttempts = 0
            self.variables.instanceSizeSet = false
            self.variables.startConfirmed = true
            self.variables.instanceCreatedAt = os.clock()
            return true
        end
        return false
    end

    if API.Check_Dialog_Open() then
        -- A DIALOGUE AFTER START MEANS THE OLD INSTANCE IS STILL ALIVE.
        --
        -- Pressing Start on a clean slate drops us straight in. If the game
        -- stops to ask something instead, the thing it is asking about is the
        -- instance we already own — so the answer is not to push through the
        -- create flow, it is to go back to the gate and rejoin.
        --
        -- Only when we have actually clicked Start. A dialogue BEFORE that is
        -- part of the ordinary create flow and still takes the second option
        -- below; this branch is specifically about the one that appears after.
        if self.variables.startConfirmed then
            self.variables.startConfirmed = false

            Utils:log("Dialogue after Start — instance is still live, rejoining",
                      "warn")

            -- The dialogue is modal, so a right-click aimed at the gate behind
            -- it never reaches the object. Clear it first.
            API.KeyboardPress2(0x1B, 60, 110) -- ESC
            API.Sleep_tick(1)

            -- Not a fresh creation after all, so drop the grace latch — leaving
            -- it set would make handleInstance sit out the next several seconds
            -- waiting on an instance we never made.
            self.variables.instanceCreatedAt = 0

            return self:rejoiningInstance()
        end

        -- Second option on the dialogue (interface 1188, component 13).
        Utils:log("Instance dialogue open — choosing the second option", "debug")
        ---@diagnostic disable-next-line:missing-parameter
        return API.DoAction_Interface(0xffffffff, 0xffffffff, 0, 1188, 13, -1,
                                      API.OFF_ACT_GeneralInterface_Choose_option)
    end

    ---@diagnostic disable-next-line
    return Interact:Object(gate.name, gate.action)
end

--- Joins the party owner's instance instead of making one of our own.
---
--- Ported from kerapac/KerapacPreparation.lua, whose non-leader branch does the
--- same two steps against the Colosseum gateway: right-click the entrance with
--- the join offset, then type the owner's name into the prompt that opens.
---
--- THE OFFSET IS THE UNVERIFIED PART. 0x29 with OFF_ACT_GeneralObject_route1 is
--- Kerapac's join action on ITS gateway; Raksha's Security gate is a different
--- object and its options are only documented here for "Enter" and "Rejoin last
--- instance". If joining silently does nothing, this pair is what to correct —
--- the log line below fires either way so the attempt is visible.
--- @return boolean sent
function RakshaLobby:joinLeaderInstance()
    local gate = Constants.OBJECTS.SECURITY_GATE
    local leader = CONFIG.party.leaderName

    if leader == nil or leader == "" then
        Utils:log("Duo: no party owner name configured — cannot join", "error")
        return false
    end

    Utils:log(string.format("Duo: joining %s's instance", leader))

    local clicked = API.DoAction_Object1(0x29, API.OFF_ACT_GeneralObject_route1,
                                         {gate.id}, 50)
    if not clicked then
        Utils:log("Duo: join click did not go out — retrying", "warn")
        return false
    end

    -- TYPE STRAIGHT AFTER THE CLICK, without waiting for a dialogue.
    --
    -- The first version gated this on API.Check_Dialog_Open() and never typed a
    -- character, which is the bug: the name prompt is a text-entry interface,
    -- not the dialogue that check reports on, so the gate was never satisfied
    -- and we just re-clicked the gate forever.
    --
    -- Kerapac's HandleJoinPlayer does not check anything either — it clicks,
    -- sleeps a tick and types. That version works in production, so this one
    -- follows it rather than being clever.
    API.Sleep_tick(4) -- let the prompt appear before typing

    -- Uppercased, and sent as a "0x41" STRING rather than the number 65.
    -- Numerically identical, and the number is what KeyboardPress2 is annotated
    -- to take — but the string is the form Kerapac has been using successfully,
    -- and this is not the place to find out whether the native treats them the
    -- same. The annotation is silenced instead.
    --
    -- Virtual-key codes for A-Z and 0-9 equal their uppercase ASCII values,
    -- which is why the uppercase matters. It does not hold for every
    -- punctuation mark, so a name with a hyphen may not type cleanly.
    local upper = string.upper(leader)
    for i = 1, #upper do
        -- Bail the moment we are actually inside. Kerapac checks this between
        -- every keystroke, and the reason is worth keeping: if the join lands
        -- part way through the name, the remaining characters go somewhere else
        -- entirely — the chat box, most likely.
        if API.InInstancedArea() then
            Utils:log("Duo: joined mid-type, stopping", "debug")
            return true
        end

        local hex = string.format("%02X", string.byte(upper, i))
        ---@diagnostic disable-next-line: param-type-mismatch
        API.KeyboardPress2("0x" .. hex, 100, 180) -- types username char by char
    end

    if API.InInstancedArea() then return true end

    -- Enter, on the LONGER timings Kerapac uses for this key specifically
    -- (120/180 against 60/110 for the characters) and a 4 tick settle after. It
    -- submits the name and the join takes a moment to resolve, so this is the
    -- one keystroke worth giving room.
    API.KeyboardPress2(0x0D, 120, 180) -- Enter 
    API.Sleep_tick(6) -- settle after the join resolves
    return true
end

--- Ticks between "still waiting for the other player" log lines.
---
--- The wait itself is unbounded — starting a 1,600,000 life point boss alone is
--- worse than standing still — so it has to be visible, or a partner who never
--- loads in looks identical to the script having hung.
local PARTNER_WAIT_LOG_TICKS = 16

--- Players in the arena besides us.
---
--- Same scan Kerapac uses in WaitForPartyToBeComplete: object type 2 with id 1
--- is the player list, and each entry carries a Name.
---
--- Counted by "anyone who is not me" rather than matched against the owner's
--- name, and deliberately so. Only party members can be inside the instance, so
--- presence is already proof of identity — and the LEADER never learns the
--- partner's name anyway, since the settings only capture the owner's. A name
--- match would work for the joiner and be unimplementable for the leader.
--- @return number
local function otherPlayersHere()
    local players = API.GetAllObjArray1({1}, 30, {2})
    if not players then return 0 end

    local me = API.GetLocalPlayerName()
    local count = 0

    for _, player in ipairs(players) do
        local name = player and player.Name
        if type(name) == "string" and name ~= "" and name ~= me then
            count = count + 1
        end
    end

    return count
end

--- Ticks with no partner in sight before we accept they are gone and bail out.
---
--- Generous on purpose. A death removes them instantly, so a shorter window
--- would work for the case this exists for — but the phase 4 transition moves
--- both players into the antechamber, and a partner mid-transit can read as
--- absent for a stretch through no fault of theirs. Leaving a live fight because
--- of a scan gap costs a kill; taking fifteen seconds to notice a real death
--- costs almost nothing, because the fight is already lost at that point.
local PARTNER_GONE_TICKS = 25

--- Re-enters the live instance without resetting its timer.
--- @return boolean
function RakshaLobby:rejoiningInstance()
    local gate = Constants.OBJECTS.SECURITY_GATE
    self.variables.rejoinAttempts = self.variables.rejoinAttempts + 1
    ---@diagnostic disable-next-line
    return Interact:Object(gate.name, gate.rejoinAction)
end

--- Decides between rejoining the current instance and creating a new one, with
--- a timeout that teleports back to War's Retreat if creation keeps failing.
--- @return boolean
function RakshaLobby:handleInstance()
    -- Timeout watchdog for a stalled new-instance attempt
    if self.variables.lastInstanceAttempt > 0 then
        local elapsed = os.clock() - self.variables.lastInstanceAttempt
        if elapsed > INSTANCE_TIMEOUT then
            self.variables.instanceAttemptCount =
                self.variables.instanceAttemptCount + 1

            if self.variables.instanceAttemptCount >= 3 then
                Utils:log("Instance creation kept failing — returning to War's " ..
                              "Retreat", "warn")
                self.variables.lastInstanceAttempt = 0
                self.variables.instanceAttemptCount = 0
                return Utils:useAbility("War's Retreat Teleport")
            end
            self.variables.lastInstanceAttempt = 0
        end
    end

    -- DUO, AND WE ARE NOT THE OWNER: we never create anything.
    --
    -- Checked before every other branch, including the mid-flow one below. A
    -- joiner has no instance of its own to rejoin and no settings panel to
    -- confirm — the only thing it should ever do at the gate is join the owner,
    -- and letting it fall through to startNewInstance would build a SECOND
    -- instance next to the one it was supposed to enter.
    if CONFIG.party.inParty and not CONFIG.party.isLeader then
        return self:joinLeaderInstance()
    end

    -- ALREADY MID-FLOW: finish what we started.
    --
    -- Once the settings window or the dialogue is up we are committed to
    -- creating this instance, and re-running the rejoin-vs-create decision
    -- underneath it would abandon a half-finished creation every tick.
    if instanceInterfaceOpen() or API.Check_Dialog_Open() then
        return self:startNewInstance()
    end

    -- JUST CREATED ONE: leave it alone while the game catches up. See
    -- INSTANCE_CREATE_GRACE — varbit 9925 is not populated the instant the
    -- confirm click lands, so without this we read 0 minutes left and
    -- immediately start building another instance on top of the one we just
    -- made.
    if self.variables.instanceCreatedAt > 0 then
        local since = os.clock() - self.variables.instanceCreatedAt
        if since < INSTANCE_CREATE_GRACE then return false end
        self.variables.instanceCreatedAt = 0
    end

    -- Rejoin only when the game says there is genuinely enough time left on the
    -- instance; otherwise make a fresh one.
    --
    -- The expiry comes straight from our own expiry varbit read, so this
    -- survives a script restart and knows the real remaining time. The old check
    -- compared os.clock() against an instanceStartTime we set ourselves, which
    -- reset to 0 every launch and therefore made a brand new instance on the
    -- first trip of every session — throwing away whatever was still live.
    local valid, minutesLeft = isInstanceValid()

    if not valid or self.variables.rejoinAttempts > 3 then
        if minutesLeft > 0 then
            Utils:log(string.format(
                          "Instance has only %d min left — creating a fresh one",
                          minutesLeft))
        end
        return self:startNewInstance()
    end

    return self:rejoiningInstance()
end

--- Resets per-kill state when leaving for a new trip.
function RakshaFight:reset()
    self.variables.engaged = false
    self.variables.bossDead = false
    self.variables.looted = false
    self.variables.lootRecorded = false
    self.variables.lastLootClickTick = -1
    -- Dropped rather than carried. A staged kill still sitting here means its
    -- pile never materialised — loot timed out, or the detector fired on a bad
    -- scan — and carrying it would hand its duration to the NEXT kill.
    Common.pendingKill = nil
    self.variables.lootDeadline = 0
    self.variables.lootTimeoutLogged = false
    self.variables.bossSeen = false
    self.variables.sawBossAlive = false
    self.variables.deadStreak = 0
    self.variables.lastDeadTick = nil
    self.variables.lastKnownHealth = -1
    self.variables.deadStreakWarned = false
    self.variables.conjured = false
    -- The lobby sequence latches live on RakshaLobby, but a trip reset has to
    -- clear them too: reset() runs on the teleport home, where the Handle
    -- instance condition may not get another pass at the lobby branch first.
    RakshaLobby.variables.lifeTransferDone = false
    RakshaLobby.variables.foodEaten = false
    self.variables.luckEquipped = false
    self.variables.loadedPhase = 1
    self.variables.specialActionClicks = 0
    self.variables.lastSpecialActionTick = -99
    self.variables.transitionHolding = false
    self.variables.transitionEndTick = nil
    self.variables.transitionReattacked = false
    self.variables.sawPhase4Hp = false
    self.variables.partnerWaitLogged = nil
    self.variables.partnerMissingStreak = 0
    self.variables.lastPartnerCheckTick = nil
    -- specialActionScanWorks is deliberately NOT reset: it records that the
    -- interface scan can see this button on this client, which stays true
    -- between kills. Clearing it would drop us back to the buff fallback at the
    -- start of every fight and re-learn the same fact each time.
    Common.fightStartTick = nil
    rotationManager:reset()

    -- Clears the phase latch, the presence latches and the shadow cache. This
    -- used to be just clearHome(), which left mechanics.state.phase pinned at 4
    -- from the previous kill — so the next fight loaded PHASE4_ROTATION on its
    -- first iteration and phases 1-3 never ran again.
    mechanics:resetFight()

    -- Fresh rejoin/new-instance counters each trip. Nothing tracks the
    -- instance's age any more — varbit 9925 is the source of truth for that, so
    -- there is no local state to preserve across trips.
    RakshaLobby.variables.rejoinAttempts = 0
    RakshaLobby.variables.lastInstanceAttempt = 0
    RakshaLobby.variables.instanceAttemptCount = 0
    -- Cleared with them. A Start we clicked on the LAST trip must not make the
    -- first ordinary dialogue of the next one look like "you already have an
    -- instance" and send us to the rejoin.
    RakshaLobby.variables.startConfirmed = false
    RakshaLobby.variables.instanceSizeSet = false
end

--- Consecutive GAME TICKS with no party member visible in the arena.
---
--- Counted per TICK, not per call, for the same reason deadStreak is: this runs
--- a dozen or more times a tick, so counting calls would turn a fifteen second
--- confirmation window into about one.
--- @return number
function RakshaFight:partnerMissingTicks()
    local tick = API.Get_tick()
    if tick == self.variables.lastPartnerCheckTick then
        return self.variables.partnerMissingStreak
    end
    self.variables.lastPartnerCheckTick = tick

    if otherPlayersHere() > 0 then
        self.variables.partnerMissingStreak = 0
    else
        self.variables.partnerMissingStreak =
            self.variables.partnerMissingStreak + 1
    end

    return self.variables.partnerMissingStreak
end

--- True once we've spent LOOT_TIMEOUT_TICKS trying to clear the pile. Lets the
--- teleport fire even with loot still on the floor, so an item we can't pick up
--- can't strand us in a finished instance. Logged once, because silently
--- abandoning a drop is exactly the kind of thing worth seeing in the log.
--- @return boolean
function RakshaFight:lootTimedOut()
    if self.variables.lootDeadline == 0 then return false end
    if API.Get_tick() < self.variables.lootDeadline then return false end

    if not self.variables.lootTimeoutLogged then
        self.variables.lootTimeoutLogged = true
        Utils:log("Loot still on the floor after " ..
                      tostring(LOOT_TIMEOUT_TICKS) ..
                      " ticks (inventory full?) — leaving it and teleporting out",
                  "warn")
    end
    return true
end

--- @return table[]
function RakshaFight:getGroundLoot()
    if not lootConfigured() then return {} end
    return API.GetAllObjArray1(Utils:virtualTableConcat(LOOT.COMMONS,
                                                        LOOT.UNIQUES), 70, {3})
end

--- Collects loot from the floor, going through the loot window when one opens.
--- Mirrors rasial/main.lua:pickUpLoot.
--- @return boolean
function RakshaFight:pickUpLoot()
    local hasLoot = #self:getGroundLoot() > 0
    if not hasLoot then return false end

    if not lootWindowOpen() then
        -- ONE click per game tick, and report the attempt as an action taken.
        --
        -- Both halves matter. Timer:_execute only stamps a task's cooldown when
        -- the action returns TRUE (core/timer.lua:397), so the old
        -- `return API.DoAction_G_Items1(...)` re-ran this whole branch on every
        -- loop pass whenever the click reported false — 10-20 ground-item
        -- clicks per game tick at the pile. Returning true hands the task its 1
        -- tick cooldown; the explicit tick guard makes the pacing independent of
        -- that, since this path has already proven it can spam.
        --
        -- Opening the window is not the same as having looted, so `looted` is
        -- deliberately NOT set here — the Loot All press below owns that.
        local tick = API.Get_tick()
        if tick == self.variables.lastLootClickTick then return false end
        self.variables.lastLootClickTick = tick

        API.DoAction_G_Items1(0x45,
                              Utils:virtualTableConcat(LOOT.COMMONS,
                                                       LOOT.UNIQUES), 30)
        return true
    end

    -- Record BEFORE taking it. Both sources only exist right now: the window's
    -- value line is gone once the window closes, and the uniques are read off
    -- the floor, which Loot All is about to clear.
    --
    -- Recorded only once the button press actually lands, and only once per
    -- kill: this function is on a 1 tick cooldown and runs until the pile is
    -- gone, so recording on sight would count the same drop several times over.
    -- Uniques are read off the FLOOR, so they have to be scanned before Loot All
    -- clears it. The window's value line is read AFTER the press instead, which
    -- is the order rasial/main.lua uses and the reason its figure is reliable —
    -- the text is populated by then, where on the frame the window first opens
    -- it can still be empty and would bank a zero.
    local uniques = (not self.variables.lootRecorded) and
                        Utils:findAll(LOOT.UNIQUES, 3, 30) or nil

    -- Loot All by interface component rather than API.DoAction_LootAll_Button,
    -- which is an opaque native and was not landing.
    ---@diagnostic disable-next-line: missing-parameter
    if API.DoAction_Interface(0x24, 0xffffffff, 1, LOOT_INTERFACE,
                              LOOT_ALL_COMPONENT, -1,
                              API.OFF_ACT_GeneralInterface_route) then
        if not self.variables.lootRecorded then
            self.variables.lootRecorded = true
            -- First, so the pile and any rare are stamped with this kill's
            -- number rather than the previous one's.
            confirmKill()
            recordUniqueDrops(uniques)
            recordLootValue(Utils:getLootWindowAmount())
        end
        self.variables.looted = true
        return true
    end

    return false
end

--- Records kill time and increments counters.
function RakshaFight:logKill()
    if self.variables.bossDead then return true end
    self.variables.bossDead = true
    self.variables.lootDeadline = API.Get_tick() + LOOT_TIMEOUT_TICKS

    -- He's subdued: nothing left to pray against, so drop the overheads rather
    -- than draining prayer through the looting and the walk out.
    --
    -- Ruination and the pocket item (Scripture / grimoire) are NOT touched here.
    -- Setting bossDead stops handleFight requesting BUFFS, and the player manager
    -- toggles off anything it was tracking that is no longer requested — retrying
    -- until it lands, which a one-shot call here would not.
    --
    -- This used to Unequip the grimoire instead. That was wrong twice over: it
    -- stopped the charge drain by removing the item rather than deactivating it,
    -- and nothing ever put it back, so every kill after the first ran with the
    -- grimoire sat in the inventory doing nothing.
    prayerFlicker:deactivatePrayer()
    Utils:log("Kill registered — prayers off, fight buffs releasing")

    local durationMs = 0
    if Common.fightStartTick then
        durationMs = (API.Get_tick() - Common.fightStartTick) * 600
    end

    -- STAGED, not committed. Both the counter and the timing record are settled
    -- against the loot pile instead — see confirmKill. This detector is
    -- inferential (a run of ticks where Raksha reads as unfound counts as a
    -- kill), which is right for deciding to teleport out and wrong for counting,
    -- so nothing it produces is banked until a pile proves it.
    Common.pendingKill = {
        runtime = API.ScriptRuntimeString(),
        fightDuration = Utils:formatKillDuration(durationMs)
    }

    Utils:log(string.format("Boss down in %s — awaiting loot to confirm",
                            Utils:formatKillDuration(durationMs)))

    -- Fight review. The line that matters is any mechanic showing MISSED: that
    -- is an animation that fired without us beginning a response, which is where
    -- unexplained damage comes from. Everything else in the fight is guesswork
    -- until these numbers exist — see Mechanics:noteMechanicSeen.
    for _, line in ipairs(mechanics:fightReview()) do
        Utils:log("[REVIEW] " .. line)
    end

    return true
end

--- The per-tick fight driver.
--- @return boolean
function RakshaFight:handleFight()
    local tProf = os.clock()
    local boss = self:getBoss()
    tProf = profMark("fight:getBoss", tProf)

    if boss.found then self.variables.bossSeen = true end

    -- PHASE 4 LATCH, and it lives here — above the transition early-return —
    -- precisely so nothing below can lose it.
    --
    -- mechanics.state.phase is derived from HP, and phase 4 is the one phase HP
    -- cannot describe: entering it heals Raksha back to 400k, which getPhase
    -- reads as phase 3. The only window where HP says "4" is between him
    -- dropping under 200k and that heal — and both of the existing latches can
    -- miss it:
    --
    --   * setPhase(4) on transition release only runs if transitionHolding was
    --     ever set, which needs the 33707 animation to have been read.
    --   * the HP backstop further down sits BELOW the transition return, so it
    --     never runs on a holding iteration.
    --
    -- Between them that leaves a real hole: if Raksha reads as unfound while the
    -- arena changes — which is exactly when he would — neither fires, and after
    -- the heal HP never says 4 again. Phase stays 3 for the whole of phase 4,
    -- and every `phase >= 4` branch silently does the wrong thing:
    --
    --   * getHome() skips its phase 4 ring entirely and hands back the safespot
    --     recorded next to the DORMANT boss in the FIRST arena — a tile with no
    --     meaning in the antechamber, which is how we end up holding a spot
    --     nowhere near east of him.
    --   * animation 33707 resolves to the general tail sweep instead of the
    --     phase 4 one, and the general answer is a bare Surge. Surge follows our
    --     FACING, and our facing on arrival is arbitrary, so it throws us
    --     somewhere unrelated to where we meant to stand.
    --
    -- Latched off the strongest signal available and never cleared mid-fight:
    -- once either "we saw him under the phase 4 threshold" or "we started
    -- holding through the transition" is true, phase 4 has begun.
    if boss.found and boss.health > 0 and boss.health <= Constants.PHASE_HP.P4 then
        self.variables.sawPhase4Hp = true
    end
    if self.variables.sawPhase4Hp or self.variables.transitionHolding then
        mechanics:setPhase(4)
    end

    -- Phase 4 transition: sit the whole thing out until the animation ends.
    -- Nothing we send lands, so acting is pure noise — and acting through it is
    -- what was burning the phase 4 opener down.
    --
    -- Placed after the boss read because it IS a boss-animation check now, not a
    -- varbit. Placed before liveness tracking so deadStreak freezes: he can go
    -- briefly unreadable as the transition ends, and that must not read as a
    -- kill.
    if self:inPhase4Transition(boss) then
        -- Keep asking for the fight buffs regardless. The player manager toggles
        -- OFF any toggle buff not requested on a frame, so going quiet here
        -- would switch Ruination and the Scripture off during the transition and
        -- we'd arrive in phase 4 unbuffed.
        if not self.variables.bossDead then
            playerManager:requestBuffs(BUFFS)
        end

        if not self.variables.transitionHolding then
            self.variables.transitionHolding = true
            Utils:log("----- PHASE 4 TRANSITION: holding until it ends -----")
        end

        -- Re-acquire Raksha during the grace window, once the animation itself
        -- has stopped, so the phase 4 rotation opens with him already targeted.
        --
        -- This is deliberately an ACTION rather than the "are we targeting
        -- Raksha?" gate that would seem the obvious reading: while we're holding
        -- we aren't attacking, so we wouldn't be targeting him, so a check like
        -- that would never release and we'd hold forever. Re-targeting achieves
        -- what the check was meant to guarantee without the deadlock.
        if self.variables.transitionEndTick and
            not self.variables.transitionReattacked then
            self.variables.transitionReattacked = true
            mechanics:reattackBoss()
        end
        return true
    end

    if self.variables.transitionHolding then
        self.variables.transitionHolding = false

        -- Latch phase 4 from the TRANSITION, not from HP. This is what was
        -- broken: mechanics.getPhase derives the phase from HP, but entering
        -- phase 4 heals Raksha back to 400k, which reads as phase 3. The only
        -- moment HP says "4" is between him dropping under 200k and the heal —
        -- and that moment is precisely when we're holding through the transition
        -- and never calling mechanics:update(). So the latch stayed at 3 for the
        -- whole of phase 4, and every `phase >= 4` gate in the script silently
        -- did nothing.
        mechanics:setPhase(4)
        Utils:log("Phase 4 transition over — resuming")
    end

    -- Load the rotation the moment we're in the boss room, BEFORE Raksha is
    -- engaged, so the pre-fight setup (Invoke Death, Surge, Vengeance, conjure
    -- commands) runs first — like Rasial.
    if not self.variables.engaged then
        -- DUO: hold the opener until our partner is actually in here with us.
        --
        -- FIGHT_ROTATION opens with Vengeance, Darkness and two Surges — it
        -- commits us to the safespot and starts the fight. Running that while
        -- the second player is still at the gate means soloing the opening of a
        -- boss with double the life points, on a rotation written for two.
        --
        -- Returns out of the whole pass rather than just skipping the load.
        -- Safe here specifically because Raksha is DORMANT until something wakes
        -- him: nothing is attacking us while we wait, so there is no prayer,
        -- food or mechanic work being missed. The moment we engage, the normal
        -- pass resumes and all of it comes back.
        if CONFIG.party.inParty and otherPlayersHere() < 1 then
            local tick = API.Get_tick()
            if (tick - (self.variables.partnerWaitLogged or -99)) >=
                PARTNER_WAIT_LOG_TICKS then
                self.variables.partnerWaitLogged = tick
                Utils:log("Duo: waiting for the other player to enter the arena",
                          "warn")
            end
            return true
        end

        Utils:log("----- INSTANCE ENTERED: pre-fight setup -----")
        self.variables.engaged = true
        rotationManager:load(activeRotation())
    end

    -- Liveness tracking for kill detection. Raksha's Life field reads 0 until
    -- combat actually starts, so "health <= 0" on its own is NOT a kill — it is
    -- also the state before we engage. Only after we've seen the boss genuinely
    -- alive (health > 0) do we count ticks where it looks dead, and a kill needs
    -- a sustained streak to rule out a flicker. The kill timer starts at that
    -- first-alive moment so the pre-fight setup isn't counted.
    if boss.found and boss.health > 0 then
        if not self.variables.sawBossAlive then
            self.variables.sawBossAlive = true
            Common.fightStartTick = API.Get_tick()
        end
        self.variables.lastKnownHealth = boss.health
        self.variables.deadStreak = 0
        self.variables.lastDeadTick = nil

        -- Backstop for the phase 4 latch, covering the case where the transition
        -- animation is never detected and the release above therefore never
        -- fires. Runs here rather than inside mechanics:update() because that
        -- doesn't run on holding iterations, which is the whole reason the HP
        -- window gets missed. setPhase only ever moves forward, so seeing a low
        -- HP reading in phase 3 can't drag us backwards later.
        if boss.health <= Constants.PHASE_HP.P4 then mechanics:setPhase(4) end
    elseif self.variables.sawBossAlive then
        -- Once per GAME TICK, not once per call. This function runs 12-20 times
        -- a tick (parallel task, zero cooldown), so counting per call turned the
        -- confirmation window into ~150ms and let a momentary bad read register
        -- as a kill mid-fight.
        local tick = API.Get_tick()
        if tick ~= self.variables.lastDeadTick then
            self.variables.lastDeadTick = tick
            self.variables.deadStreak = self.variables.deadStreak + 1
        end
    end

    -- Swap in that phase's rotation on every transition, the way Rasial loads its
    -- finalRotation — but for each of 2, 3 and 4, because Raksha's phases want
    -- genuinely different lines (see PHASE_ROTATIONS). Phase 1 is already loaded
    -- as part of FIGHT_ROTATION on instance entry.
    --
    -- Skipped in Revolution mode, where the action bar owns damage and
    -- activeRotation() is setup-only.
    --
    -- Reaching here at all means we are NOT mid-transition — that case returned
    -- above. That ordering is what actually defers the phase 4 load: HP crosses
    -- 200k at the START of the transition, so without it the rotation dropped in
    -- while Raksha was still animating and the manager walked the opener's
    -- `wait` timers down against a locked player.
    --
    -- `boss.found and boss.health > 0` stays as a second line of defence for the
    -- other transitions, which have no animation cue wired up.
    --
    -- `sawBossAlive` keeps this from ever firing on the same iteration as the
    -- pre-fight load above: both live in this function, so without it a stray
    -- low-HP reading before we engage would swap the rotation out from under the
    -- setup steps (conjures, Split Soul, the walk to the safespot) and they'd
    -- simply never run.
    --
    -- Only ever moves FORWARD. Reloading a lower phase's rotation would restart
    -- its scripted opener mid-fight, and phase numbers never go backwards.
    if not CONFIG.useRevolution and boss.found and boss.health > 0 and
        self.variables.sawBossAlive then
        local phase = mechanics.state.phase
        if phase > self.variables.loadedPhase and PHASE_ROTATIONS[phase] then
            self.variables.loadedPhase = phase
            Utils:log(string.format("----- PHASE %d: loading rotation -----",
                                    phase))
            rotationManager:load(PHASE_ROTATIONS[phase])
        end
    end

    -- Swap in the luck ring before he dies, so the drop rolls with it. Latched,
    -- and equipping is not a global-cooldown action so it costs no DPS.
    if not self.variables.luckEquipped and boss.found and boss.health > 0 and
        boss.health <= Constants.LUCK_RING_HP and mechanics.state.phase >= 4 then
        self.variables.luckEquipped = true
        if Utils:equipLuckRing() then
            Utils:log(string.format("Boss at %d hp — equipped luck ring",
                                    boss.health))
        else
            Utils:log("No luck ring in inventory to equip", "warn")
        end
    end

    -- Run the fight until the boss is dead. The rotation (pre-fight buffs first)
    -- executes even before Raksha is found; prayer flicker and mechanics both
    -- self-guard on boss presence, so they're harmless pre-engage.
    if not self.variables.bossDead then
        -- Ask for the fight buffs every iteration. The manager re-applies what
        -- has lapsed (re-drinking the overload when it runs out) and keeps the
        -- toggles alive. Once bossDead flips we stop asking, which is what turns
        -- Ruination and the pocket item off — see BUFFS.
        --
        -- Requesting costs nothing and takes no global cooldown; it only records
        -- intent, and playerManager:update() acts on it later in the same loop.
        tProf = os.clock()
        playerManager:requestBuffs(BUFFS)
        tProf = profMark("requestBuffs", tProf)

        prayerFlicker:update()
        tProf = profMark("prayerFlicker", tProf)

        -- Phase 4 special action button, BEFORE the global-cooldown arbitration
        -- below and deliberately not part of it.
        --
        -- It used to sit in the `consumed` chain behind mechanics and
        -- defensives. In phase 4 those fire near-constantly — dodges, Escapes,
        -- prayer flicks — so the click was competing for a slot it kept losing.
        -- An interface button is not an ability and does not spend the ability
        -- global cooldown, so it has no business in that chain: it runs on its
        -- own pacing and lets the rotation carry on in the same tick.
        self:clickSpecialAction()
        tProf = profMark("specialAction", tProf)

        -- Mechanics get first claim on the tick. When one consumes the action
        -- (a counter ability, an Escape, a Freedom/Surge step) the rotation
        -- must not also fire, or the two contend for the same global cooldown.
        local consumed = mechanics:update()
        tProf = profMark("mechanics:update", tProf)

        -- Defensives come straight after the mechanic responses and ahead of
        -- everything else: staying alive beats both DPS and conjure upkeep.
        if not consumed and spendSurvivalAbilities() then consumed = true end
        tProf = profMark("survival", tProf)

        -- Re-summon conjures if they've been killed or expired mid-fight. Sits
        -- here rather than in its own task so it shares the same global-cooldown
        -- arbitration as the rotation instead of racing it.
        if not consumed and canSummonConjures() then
            if summonConjures() then
                Utils:log("Conjures gone — re-summoning")
                consumed = true
            end
        end

        -- HOLD the rotation while we're off the boss killing something else.
        --
        -- Anima pools, the Shadow manifestation and Shadow Energy all pull our
        -- target away, and the phase rotation is written against Raksha — so
        -- letting it run during a clear spends Death Skulls, Volley and the
        -- specs into a pool and then resumes phase 3 several steps further on
        -- than it should. mechanics owns those fights outright and uses its own
        -- ability lists (see Mechanics:rotationOnHold); we simply stop here and
        -- pick up at the same step once it hands the target back.
        --
        -- The rotation manager's step timer keeps running while we're held, so
        -- resuming is immediate rather than paying another full wait.
        if not consumed and mechanics:rotationOnHold() then consumed = true end

        if not consumed then
            local ok, err = pcall(function() rotationManager:execute() end)
            if not ok then
                Utils:log("Rotation error: " .. tostring(err), "error")
            end
        end
        profMark("rotation", tProf)
    else
        prayerFlicker:deactivatePrayer()
    end

    local tTail = os.clock()
    playerManager:manageHealth()
    playerManager:managePrayer()
    profMark("health/prayer", tTail)

    return true
end

------------------------------------------
-- # FIGHT TASKS
------------------------------------------

RakshaFight.tasks = {
    {
    -- DUO: our partner is gone, so we leave too and both reset together.
    --
    -- A death takes them out of the instance entirely — straight to Death's
    -- Office — so from in here "gone" and "dead" look the same, and both call
    -- for the same answer. Raksha in a duo has 1,600,000 life points on a
    -- rotation written for two; carrying on alone is not a fight we win, it is
    -- a second death and a second reclaim fee.
    --
    -- Their side is already handled: the death recovery task reclaims at Death's
    -- Office and teleports them to War's Retreat. This is the other half, so we
    -- both arrive there and the normal bank-and-return flow lines us back up.
    name = "Duo: partner gone — leaving the instance",
    priority = 96,
    cooldown = 5,
    useTicks = true,
    parallel = true,
    condition = function()
        if not CONFIG.party.inParty then return false end
        if not RakshaFight:atLocation() then return false end

        -- Only once the fight is actually underway. Before that the
        -- wait-for-partner gate in handleFight owns the situation, and it waits
        -- rather than bailing.
        if not RakshaFight.variables.engaged then return false end

        -- Boss already down: finish the trip properly. Loot is on the floor and
        -- the teleport task will take us out once it is cleared.
        if RakshaFight.variables.bossDead then return false end

        -- WE are the one who died. Death recovery owns movement from here and
        -- teleports us out itself; two teleport sources is how you end up
        -- stranded in Death's Office.
        if Common.isDead then return false end

        -- Mid phase 4 transition both players are moving between arenas, which
        -- is exactly when a partner reads as absent without being gone.
        if RakshaFight.variables.transitionHolding then return false end

        return RakshaFight:partnerMissingTicks() >= PARTNER_GONE_TICKS
    end,
    action = function()
        if not Utils:useAbility("War's Retreat Teleport") then
            Utils:log("Duo: partner gone, but the teleport did not fire — " ..
                          "retrying", "warn")
            return false
        end

        Utils:log(string.format(
                      "Duo: no partner for %d ticks — teleporting to War's Retreat to reset",
                      RakshaFight.variables.partnerMissingStreak), "warn")
        RakshaFight:reset()
        return true
    end
    }, {
        -- Safety net: being at War's Retreat means the trip is over, so the
        -- fight state must be clear. Nothing else guarantees that.
        --
        -- The teleport task calls reset() only when useAbility() reports
        -- success, so a teleport that fires while the call returns false leaves
        -- every fight variable stale — engaged, bossDead, the loaded rotation
        -- and its index all carry into the next trip. That is worth closing on
        -- its own account.
        --
        -- It also leaves rotationManager.index wherever the kill ended, which
        -- matters ONLY when the prebuild is enabled: _checkCrystalCondition
        -- skips the adrenaline crystal while `index ~= 1 and index <=
        -- #prebuildRotation`, reading a low index as "prebuild in progress".
        -- With prebuild off, prebuildSettings is nil and that branch is dead.
        name = "Resetting fight state at War's Retreat",
        priority = 95,
        cooldown = 3,
        useTicks = true,
        parallel = true,
        -- Keyed on the FIGHT flags only, never on rotationManager.index: the
        -- prebuild legitimately drives that index up while we stand here, so
        -- treating a non-1 index as "stale" would reset the prebuild mid-run —
        -- trading one bug for a worse one. reset() clears the index anyway, and
        -- these flags are only true when a trip really has ended.
        condition = function()
            return warsRetreat:atLocation() and
                       (RakshaFight.variables.engaged or
                           RakshaFight.variables.bossDead)
        end,
        action = function()
            -- Adrenaline is logged here because it decides the crystal. The only
            -- gate left in _checkCrystalCondition once prebuild is off is
            -- `getAdrenaline() < getMaxAdrenaline()` — arrive full and the
            -- crystal is skipped, correctly. Printing the arrival value is the
            -- difference between knowing that and guessing at it.
            -- %.0f, not %d. Player:getAdrenaline() is `varbit / 10`, and `/` is
            -- always float division in Lua 5.3+ — so 973 adrenaline comes back
            -- as 97.3, which has no integer representation and makes %d raise
            -- "bad argument to 'format'". It only blew up when adrenaline wasn't
            -- a multiple of 10, which is why it looked intermittent.
            Utils:log(string.format(
                          "Back at War's Retreat — clearing fight state (adrenaline %.0f/%.0f)",
                          Player:getAdrenaline() or -1,
                          Player:getMaxAdrenaline() or -1))
            RakshaFight:reset()
            return true
        end
    }, {
        -- Lobby step 1: conjure. Fires in the lobby (gate present, boss not yet
        -- engaged) so the conjures are up before we start the instance — they
        -- carry through the gate, mirroring how Rasial conjures in the lobby.
        -- Gated on the conjures actually being OUT (buffs), not on having
        -- clicked the ability, and it never re-casts over its own animation.
        name = "Summoning conjures",
        priority = 60,
        cooldown = 4,
        useTicks = true,
        parallel = true,
        condition = function()
            return RakshaLobby:atLocation() and canSummonConjures()
        end,
        action = function()
            if summonConjures() then
                RakshaFight.variables.conjured = true
                Utils:log("Conjuring Undead Army in the lobby")
                return true
            end
            return false
        end
    }, {
        -- Lobby step 2: Life Transfer into the conjures we just summoned.
        --
        -- Gated on hasActiveConjures rather than on having CLICKED the summon:
        -- transferring before they exist heals nothing and spends our health for
        -- it. `conjuring()` keeps us off the cast while the summon animation is
        -- still playing, the same guard the instance step uses.
        name = "Lobby: Life Transfer",
        priority = 59,
        cooldown = 3,
        useTicks = true,
        parallel = true,
        condition = function()
            if not RakshaLobby:atLocation() then return false end
            if RakshaLobby.variables.lifeTransferDone then return false end
            if conjuring() then return false end
            if not hasActiveConjures() then return false end
            return Utils:canUseAbility(LIFE_TRANSFER_ABILITY)
        end,
        action = function()
            if Utils:useAbility(LIFE_TRANSFER_ABILITY) then
                RakshaLobby.variables.lifeTransferDone = true
                Utils:log("Life Transfer cast into the conjures")
                return true
            end
            return false
        end
    }, {
        -- Lobby step 3: put back the health Life Transfer just spent.
        --
        -- Strictly AFTER the transfer, which is the entire point of the
        -- ordering: eating first tops up health we are about to give away.
        name = "Lobby: eating before entry",
        priority = 58,
        cooldown = 3,
        useTicks = true,
        parallel = true,
        condition = function()
            if not RakshaLobby:atLocation() then return false end
            if RakshaLobby.variables.foodEaten then return false end
            if conjuring() then return false end
            if not RakshaLobby.variables.lifeTransferDone then return false end
            return lobbyFoodItem() ~= nil
        end,
        action = function()
            if eatOneFood() then
                RakshaLobby.variables.foodEaten = true
                Utils:log("Ate one food after Life Transfer")
                return true
            end
            return false
        end
    }, {
        -- Lobby step 4: start the instance (rejoin or create), but only once the
        -- conjures are genuinely up. Entering on the click flag cut the summon
        -- animation short, so we never actually got conjures.
        name = "Handle instance",
        priority = 55,
        cooldown = 3,
        useTicks = true,
        condition = function()
            if not RakshaLobby:atLocation() then
                -- Reset the lobby timer as we leave, ready for the next trip.
                RakshaLobby.variables.lobbyEnteredTick = nil
                -- And the pre-fight latches with it, so the next trip conjures,
                -- transfers and eats again rather than walking straight in on
                -- last trip's flags.
                RakshaLobby.variables.lifeTransferDone = false
                RakshaLobby.variables.foodEaten = false
                return false
            end

            -- Stamp our arrival the first time we see the lobby (conditions run
            -- once per cycle, so this is a safe place to latch it).
            RakshaLobby.variables.lobbyEnteredTick =
                RakshaLobby.variables.lobbyEnteredTick or API.Get_tick()

            if conjuring() then return false end -- never interrupt the summon

            -- The full sequence: conjures OUT, Life Transfer spent, one food
            -- eaten. Only then do we go through the gate.
            if hasActiveConjures() and RakshaLobby.variables.lifeTransferDone and
                RakshaLobby.variables.foodEaten then
                return true
            end

            -- Escape hatch, and it now covers all three steps rather than just
            -- the summon. Any of them can legitimately never complete — the
            -- summon or Life Transfer on cooldown from the previous life, no food
            -- in the bag, an unbarred item — and none of those is worth parking
            -- the script in the lobby over. Go in with whatever we managed.
            return (API.Get_tick() - RakshaLobby.variables.lobbyEnteredTick) >
                       LOBBY_PREP_WAIT_TICKS
        end,
        action = function() return RakshaLobby:handleInstance() end,
        delay = 1,
        delayTicks = true
    }, {
        name = "Handle fight",
        priority = 99,
        cooldown = 0,
        parallel = true,
        condition = function() return RakshaFight:atLocation() end,
        action = function() return RakshaFight:handleFight() end
    }, {
        name = "Registering the kill",
        priority = 20,
        cooldown = 0,
        useTicks = true,
        condition = function()
            if not RakshaFight:atLocation() then return false end
            if not RakshaFight.variables.engaged then return false end
            if RakshaFight.variables.bossDead then return false end

            -- Definitive: once the subdued Raksha (27353) is on the floor he is
            -- dead, no inference needed.
            if RakshaFight:subduedPresent() then return true end

            -- Fallback for the tick or two before he swaps id: we must have seen
            -- him genuinely alive (so the pre-combat 0-HP read can't count) and
            -- he must have looked dead for several consecutive GAME ticks.
            local v = RakshaFight.variables
            if not v.sawBossAlive then return false end

            -- How long we insist on depends on how healthy he was when we last
            -- actually saw him. Nearly dead: believe it quickly. Still holding
            -- real HP: "he vanished" is almost certainly a bad scan, so make it
            -- prove itself for ~30s before we accept a kill and leave.
            local nearlyDead = v.lastKnownHealth > 0 and
                                   v.lastKnownHealth <= KILL_TRUST_HP
            local needed = nearlyDead and KILL_CONFIRM_TICKS or
                               KILL_CONFIRM_TICKS_HIGH_HP

            if v.deadStreak >= needed then return true end

            -- Visibility: a long stretch of "can't find the boss" while he still
            -- had HP is the exact signature of the bug that used to teleport us
            -- out of a live fight, so say so rather than failing silently.
            if not nearlyDead and v.deadStreak > KILL_CONFIRM_TICKS and
                not v.deadStreakWarned then
                v.deadStreakWarned = true
                Utils:log(string.format(
                              "Boss unreadable for %d ticks but was at %d hp — " ..
                                  "treating as a bad scan, not a kill",
                              v.deadStreak, v.lastKnownHealth), "warn")
            end
            return false
        end,
        action = function() return RakshaFight:logKill() end
    }, {
        name = "Looting",
        priority = 8,
        cooldown = 1,
        useTicks = true,
        condition = function()
            return RakshaFight:atLocation() and
                       RakshaFight.variables.bossDead and lootConfigured() and
                       not RakshaFight:lootTimedOut() and
                       #RakshaFight:getGroundLoot() > 0
        end,
        action = function() return RakshaFight:pickUpLoot() end
    }, {
        name = "Teleporting back to War's Retreat",
        priority = 1,
        cooldown = 10,
        useTicks = true,
        condition = function()
            return RakshaFight:atLocation() and
                       RakshaFight.variables.bossDead and
                       (not lootConfigured() or
                           #RakshaFight:getGroundLoot() == 0 or
                           RakshaFight:lootTimedOut())
        end,
        action = function()
            -- Reset only AFTER the teleport lands. reset() clears bossDead,
            -- which is what this task's own condition keys off — so resetting
            -- first meant a teleport that failed (cooldown, misclick) left us in
            -- a finished instance with no task able to fire again.
            if not Utils:useAbility("War's Retreat Teleport") then
                Utils:log("War's Retreat Teleport did not fire — retrying", "warn")
                return false
            end
            Utils:log("Teleporting to War's Retreat")
            RakshaFight:reset()
            return true
        end,
        delay = 2,
        delayTicks = true
    }
}

for _, task in pairs(RakshaFight.tasks) do timer:addTask(task) end

------------------------------------------
-- # FAMILIAR
------------------------------------------

--- Special move points currently in the pool, out of 60.
--- @return number
local function familiarPoints()
    local ok, points = pcall(function() return Familiars:GetSpellPoints() end)
    return (ok and tonumber(points)) or 0
end

--- @return boolean
local function familiarOut()
    local ok, has = pcall(function() return Familiars:HasFamiliar() end)
    return ok and has and true or false
end

--- Seconds the current familiar has left, or 0 when we cannot read it.
--- @return number
local function familiarTimeLeft()
    local ok, left = pcall(function() return Familiars:GetTimeRemaining() end)
    return (ok and tonumber(left)) or 0
end

-- Summon the Ripper Demon at War's Retreat.
--
-- Only here, never in the arena: summoning is a pouch click that costs the
-- summoning points we want spent on the familiar being OUT for the fight, and a
-- trip that starts without one should notice before it walks through the portal.
timer:addTask({
    name = "Summoning familiar",
    priority = 72,
    cooldown = 4,
    useTicks = true,
    parallel = true,
    condition = function()
        if not FAMILIAR.enabled then return false end
        if not warsRetreat:atLocation() then return false end
        if Common.isDead then return false end
        if familiarOut() then return false end
        return Inventory:Contains(FAMILIAR.pouch)
    end,
    action = function()
        Utils:log("Summoning Ripper Demon", "info")
        -- Summoned off the action bar. FAMILIAR.pouch is an id, which the bag
        -- check above still uses; the bar needs the name, so that comes from
        -- FAMILIAR.pouchName alongside it.
        return useBarItem(FAMILIAR.pouchName)
    end,
    executionData = {lastRun = 0, count = 0}
})

-- Renew it before it lapses, following rasial's pattern of doing familiar upkeep
-- at War's Retreat once the preset is in.
--
-- Renewing rather than re-summoning keeps the familiar's timer topped up without
-- dismissing it, so the DPS never stops. Button 7 on the follower panel is
-- "renew familiar" — see the DoAction_Button_FO table in api.lua.
timer:addTask({
    name = "Renewing familiar",
    priority = 71,
    cooldown = 4,
    useTicks = true,
    parallel = true,
    condition = function()
        if not FAMILIAR.enabled then return false end
        if not warsRetreat:atLocation() then return false end
        if Common.isDead then return false end
        if not familiarOut() then return false end

        -- CanRenew is the client's own "is there a pouch to do this with"
        -- check, so we never click a button that cannot work.
        local ok, canRenew = pcall(function() return Familiars:CanRenew() end)
        if not ok or not canRenew then return false end

        return familiarTimeLeft() < FAMILIAR.renewBelowSeconds
    end,
    action = function()
        Utils:log(string.format("Renewing familiar (%ds left)",
                                familiarTimeLeft()), "info")
        return API.DoAction_Button_FO(7)
    end,
    executionData = {lastRun = 0, count = 0}
})

-- Top the special move pool back up with a Spiritual prayer potion.
--
-- OPTIONAL, and inert unless FAMILIAR.usePotion is set. Without it the familiar
-- still summons, renews and specs — it just spends the starting 60 points (three
-- casts) and then waits on natural regeneration instead of topping up.
--
-- When it is on: runs in the fight as well as at War's Retreat, because the pool
-- is what turns the familiar from a passive damage source into a specced one. A
-- dose gives 15 points back plus prayer and summoning, none of it wasted here.
--
-- dontDrink pauses the player manager around it for the same reason the
-- adrenaline potion does: two drinks in one tick means one is thrown away, and
-- the one we lose is whichever went second.
timer:addTask({
    name = "Drinking spiritual prayer potion",
    priority = 69,
    cooldown = 5,
    useTicks = true,
    parallel = true,
    condition = function()
        if not FAMILIAR.enabled then return false end
        if not FAMILIAR.usePotion then return false end
        if Common.isDead then return false end
        if not familiarOut() then return false end
        if familiarPoints() >= FAMILIAR.drinkBelowPoints then return false end
        return Inventory:ContainsAny(FAMILIAR.potionIds)
    end,
    action = function()
        playerManager:dontDrink(ADREN_POTION_DONT_DRINK)
        Utils:log(string.format(
                      "Special move points at %d — drinking spiritual prayer potion",
                      familiarPoints()), "info")
        -- By id, like the other potions: the bar labels each dose separately, so
        -- a name lookup would never match. See useBarPotion.
        return useBarPotion(FAMILIAR.potionIds, FAMILIAR.potionName)
    end,
    executionData = {lastRun = 0, count = 0}
})

-- Fire Death From Above whenever the pool can pay for it.
--
-- A familiar special does NOT spend the player's global cooldown, which is why
-- this is its own parallel task rather than another branch in the rotation's
-- consumed chain — it costs the rotation nothing and should never lose a tick to
-- it. Same reasoning as the phase 4 special action button.
timer:addTask({
    name = "Familiar special attack",
    priority = 70,
    -- Roughly the special's own cadence. Faster just burns scroll clicks on a
    -- pool that cannot pay yet.
    cooldown = 8,
    useTicks = true,
    parallel = true,
    condition = function()
        if not FAMILIAR.enabled then return false end
        if not RakshaFight:atLocation() then return false end
        if not RakshaFight.variables.engaged then return false end
        if RakshaFight.variables.bossDead then return false end
        if not familiarOut() then return false end
        if familiarPoints() < FAMILIAR.specialCost then return false end
        return Inventory:Contains(FAMILIAR.scroll)
    end,
    action = function()
        local ok, fired = pcall(function()
            return Familiars:CastSpecialAttack()
        end)
        if ok and fired then
            Utils:log("Familiar special: Death From Above", "debug")
            return true
        end
        return false
    end,
    executionData = {lastRun = 0, count = 0}
})

------------------------------------------
-- # PRAYER TEARDOWN AT WAR'S RETREAT
------------------------------------------

-- Drop any overhead we are still holding once we are back at War's Retreat.
--
-- Nothing at War's Retreat wants an overhead up, and one left on quietly drains
-- the prayer we just walked to the altar to restore — so the trip refills a pool
-- that is emptying behind it.
--
-- A DEDICATED TASK RATHER THAN A LINE IN THE RESET, because the resets do not
-- all pass through the same place and two of them clear the fight flags BEFORE
-- we land:
--
--   * A normal kill turns prayers off in handleFight's bossDead branch, but only
--     while still in the arena.
--   * The duo partner-gone bail calls RakshaFight:reset() in the ARENA, so by
--     the time we arrive the "Resetting fight state at War's Retreat" task sees
--     engaged and bossDead already false and never runs.
--   * Death recovery resets on arrival for the same reason.
--
-- Keying off "am I at War's Retreat with a prayer on" instead covers every route
-- home, including the ones that have not been written yet.
timer:addTask({
    name = "Deactivating prayers at War's Retreat",
    priority = 90,
    cooldown = 2,
    useTicks = true,
    parallel = true,
    condition = function() return warsRetreat:atLocation() end,
    action = function()
        prayerFlicker:deactivatePrayer()

        -- TRUE regardless of what that returned. Timer:_execute only starts a
        -- task's cooldown on success, and deactivatePrayer reports false
        -- whenever there was nothing to turn off — which is almost every pass we
        -- spend here. Handing that straight back would re-run this every loop
        -- iteration, and each run reads the prayer buffs one by one.
        return true
    end,
    executionData = {lastRun = 0, count = 0}
})

------------------------------------------
-- # INVENTORY READ RECOVERY
------------------------------------------

--- How often the watchdog samples. Ticks, not loop iterations: the read itself
--- is a native call, and this codebase has already been bitten by running one of
--- those per frame.
local INVENTORY_CHECK_TICKS = 5

--- Consecutive bad samples before we accept the read is genuinely broken.
---
--- One is not enough. The array legitimately reads short for a moment while an
--- interface is opening or a preset is mid-load, and teleporting out of the
--- lobby over a single frame of that would be worse than the bug.
local INVENTORY_BROKEN_SAMPLES = 3

--- Consecutive bad inventory samples seen so far.
local invBrokenStreak = 0

--- Slots a healthy inventory read reports. Always 28.
local INVENTORY_SLOTS = 28

--- Whether the client's inventory array is currently unusable.
---
--- TWO signals, because one was not enough. Inventory:IsArrayNull() reads like
--- the whole answer — its own documentation says "null or unexpected size" — but
--- a watchdog built on it alone never fired once while the client was logging
--- "Unexpected inventory size" on every frame. Whatever that message is raised
--- from, IsArrayNull does not agree with it.
---
--- So the slot count is asked directly as well. A healthy read has 28 entries;
--- anything else IS the fault, by definition, and needs no interpretation.
---
--- ReadInvArrays33 is a native call, which is why this runs on the watchdog's
--- tick cadence and never per frame.
--- AMBIGUITY MEANS HEALTHY. Anything this cannot measure is reported as fine.
---
--- That rule is written in blood. The first version treated "could not measure
--- it" as a fault, via `type(slots) ~= "table"` — and ReadInvArrays33 does not
--- return a Lua table. Every caller in this repo iterates it with ipairs and
--- none of them ever calls type() or #, which is the signature of a userdata
--- binding: ipairs-able through metamethods, but `type()` says "userdata".
---
--- So that check was true on EVERY call, healthy or not. The watchdog fired
--- continuously at War's Retreat, forced a preset reload every fifteen ticks,
--- pinned the step machine on LOAD PRESET and stopped the script ever reaching
--- the portal. A watchdog that acts on "I don't know" is worse than no watchdog.
---
--- The count is therefore taken by ITERATING, which works on a table and on an
--- ipairs-able userdata alike, and a failure to count reports healthy.
--- @return boolean broken
--- @return string reason Human-readable, for the log
local function inventoryReadBroken()
    -- The client's own verdict. Trusted when it says yes, ignored otherwise.
    local okNull, isNull = pcall(function() return Inventory:IsArrayNull() end)
    if okNull and isNull then return true, "IsArrayNull reported true" end

    local okCount, count = pcall(function()
        local slots = API.ReadInvArrays33()
        if slots == nil then return nil end

        local n = 0
        for _ in ipairs(slots) do n = n + 1 end
        return n
    end)

    -- Unmeasurable. Not evidence of anything, so say nothing.
    if not okCount or type(count) ~= "number" then return false, "" end

    if count ~= INVENTORY_SLOTS then
        return true, string.format("%d slots, expected %d", count,
                                   INVENTORY_SLOTS)
    end

    return false, ""
end

-- Recovers from a broken inventory read by reloading the preset.
--
-- WHY THIS EXISTS. The client intermittently hands back an inventory array that
-- is null or the wrong length. Nothing downstream can tell: Inventory:InvItemcount
-- answers 0 for everything, so _inventoryMatchCheck reports a mismatch, the
-- War's Retreat step machine parks on LOAD PRESET, and the bank task retries
-- against a container that is never going to read correctly. That is the
-- "Unexpected inventory size" spam, and it ends in an idle logout because none
-- of it is real input.
--
-- Reloading the preset rebuilds the container, which is what actually clears it
-- — so the fix is to get to the bank and do exactly that.
--
-- NEVER DURING A FIGHT. A teleport mid-Raksha throws the kill away, and the
-- inventory being unreadable is survivable where a lost instance is not. The
-- fight has its own consumable handling and none of it routes through here.
timer:addTask({
    name = "Inventory read recovery",
    -- Below death recovery (600), above the fight and War's Retreat tasks. A
    -- death outranks this: it teleports us anyway and ends at the bank.
    priority = 550,
    cooldown = INVENTORY_CHECK_TICKS,
    useTicks = true,
    parallel = true,
    condition = function()
        -- Out of the Raksha fight only, as asked. RakshaFight:atLocation() is
        -- the arena; the lobby and War's Retreat both fall through to true.
        if RakshaFight:atLocation() then return false end

        -- Death recovery owns movement while it runs, and it finishes at War's
        -- Retreat with a bank stop of its own. Two teleport sources racing each
        -- other is how you get stranded in Death's Office.
        if Common.isDead then return false end

        return true
    end,
    action = function()
        local broken, reason = inventoryReadBroken()

        if not broken then
            if invBrokenStreak > 0 then
                Utils:log(string.format(
                              "Inventory read recovered after %d bad sample(s)",
                              invBrokenStreak), "warn")
                invBrokenStreak = 0
            end
            -- TRUE even though nothing happened. Timer:_execute only starts a
            -- task's cooldown when the action reports success, so returning
            -- false here would re-run this every loop iteration and reintroduce
            -- the per-frame native call this is meant to stop.
            return true
        end

        invBrokenStreak = invBrokenStreak + 1

        -- Logged on EVERY bad sample, not just once we act. Staying quiet until
        -- the third was indistinguishable from the watchdog not running at all,
        -- and that is exactly how the first version's detection was able to
        -- never fire without anyone noticing.
        Utils:log(string.format("Inventory read bad (%s) — sample %d/%d", reason,
                                invBrokenStreak, INVENTORY_BROKEN_SAMPLES),
                  "warn")

        if invBrokenStreak < INVENTORY_BROKEN_SAMPLES then return true end

        -- Acted on. Clear the streak so the recovery paces itself: it takes
        -- another full run of bad samples to come back round, which gives the
        -- teleport time to land and the preset time to load before we judge it
        -- again.
        invBrokenStreak = 0

        if not warsRetreat:atLocation() then
            Utils:log("Inventory read broken — teleporting to War's Retreat",
                      "warn")
            Utils:useAbility("War's Retreat Teleport")
            return true
        end

        -- At War's Retreat. Force the bank stop rather than trusting the
        -- ordinary inventory-match route to get us there: that route is decided
        -- by the very read we have just declared unusable. requirePresetLoad is
        -- idempotent and logs its own transition.
        Utils:log("Inventory read broken at War's Retreat — forcing a preset reload",
                  "warn")
        warsRetreat:requirePresetLoad()
        return true
    end,
    executionData = {lastRun = 0, count = 0}
})

------------------------------------------
-- # DEATH RECOVERY
------------------------------------------

-- Ported from rasial/main.lua. We're in Death's Office when Death (NPC 27299) is
-- standing next to us — a far more reliable signal than API.IsInDeathOffice(),
-- which doesn't detect the office here.
local function inDeathsOffice()
    return #Utils:findAll(27299, 1, 30) > 0
end

--- Reclaims items from Death's Office via the Death Coffer. The office is a
--- universal area, so the same NPC (27299) and interfaces (1626 / 1673) apply
--- here as at Rasial. Runs as a tick-paced state machine.
--- @return boolean done True once items have been reclaimed
local function reclaimAtDeathsOffice()
    local currentTick = API.Get_tick()

    if not Common.deathReclaimStep then
        Common.deathReclaimStep = 1
        Common.deathReclaimStepTick = currentTick
    end

    local step = Common.deathReclaimStep
    local ticksWaited = currentTick - Common.deathReclaimStepTick

    local function advance(nextStep)
        Utils:log(("Death reclaim: step %s -> %s"):format(
                      tostring(Common.deathReclaimStep), nextStep), "warn")
        Common.deathReclaimStep = nextStep
        Common.deathReclaimStepTick = currentTick
    end

    if step == 1 then
        -- Let the office settle, then talk to Death
        if ticksWaited >= 6 and
            API.DoAction_NPC(0x29, API.OFF_ACT_InteractNPC_route3, {27299}, 50) then
            advance(2)
        end
    elseif step == 2 then
        -- Wait for Death's reclaim interface to open.
        --
        -- Detected by SIZE, not by varbit 2874. Same fix as the instance window
        -- in the lobby: 2874 packs two bytes, so comparing its raw state to a
        -- single number is only right when nothing else is flagged, and it
        -- stopped matching. Asking whether interface 1626 is open is direct and
        -- can't drift — and 1626 is the interface we go on to click anyway.
        if API.GetInterfaceOpenBySize(1626) then advance(3) end
    elseif step == 3 then
        -- Choose "reclaim items"
        if API.DoAction_Interface(0xffffffff, 0xffffffff, 1, 1626, 47, -1,
                                  API.OFF_ACT_GeneralInterface_route) then
            advance(4)
        end
    elseif step == 4 then
        if ticksWaited >= 3 then advance(5) end
    elseif step == 5 then
        -- Select "pay from Death's Coffer"
        if API.DoAction_Interface(0xffffffff, 0xffffffff, 0, 1626, 72, -1,
                                  API.OFF_ACT_GeneralInterface_Choose_option) then
            advance(6)
        end
    elseif step == 6 then
        if ticksWaited >= 2 then advance(7) end
    elseif step == 7 then
        -- Confirm the coffer payment
        if API.DoAction_Interface(0x2e, 0xffffffff, 1, 1673, 14, -1,
                                  API.OFF_ACT_GeneralInterface_route) then
            Common.deathReclaimStep = nil
            Common.deathReclaimStepTick = nil
            Common.deathReclaimed = true
            Utils:log("- Items reclaimed from Death's Office", "warn")
            return true
        end
    end

    return false
end

-- Death recovery: detect the death, reclaim at Death's Office, return to War's
-- Retreat and reset so the normal bank-and-return flow takes over.
timer:addTask({
    name = "Death recovery handler",
    priority = 600, -- Above everything else
    cooldown = 2,
    useTicks = true,
    parallel = true,
    condition = function()
        -- Two death signals:
        --  * HP hit 0 while a fight was actually underway (`engaged` guards
        --    against a transient 0-HP read during instance loading)
        --  * Death (NPC 27299) is next to us — the definitive backstop
        local inOffice = inDeathsOffice()
        local diedInFight = Player:getHP() == 0 and RakshaFight.variables.engaged

        if (inOffice or diedInFight) and not Common.isDead then
            Common.isDead = true
            Common.reachedDeathOffice = false
            Common.deathReclaimed = false
            Common.deathTime = os.time()
            Common.deathCount = Common.deathCount + 1
            Utils:log(string.format("DEATH DETECTED! Death count: %d",
                                    Common.deathCount), "error")

            -- Sent from inside the `not Common.isDead` branch, which is the
            -- one-shot: this condition runs every 2 ticks for the whole recovery,
            -- so anywhere else would post an embed per tick until we got back.
            if discordEnabled() then
                ---@diagnostic disable-next-line: undefined-global
                local embed = DiscordEmbed.new()
                                  :SetTitle("Death Notification")
                                  :SetDescription(
                                      "Your character has died during the Raksha fight.")
                                  :SetColor(DISCORD_COLOR.death)
                                  :SetTimestamp(tostring(os.time()))
                                  :SetAuthor(discordAuthor())

                ---@diagnostic disable-next-line: undefined-global
                embed:AddField(EmbedField.new("Death Count",
                                              tostring(Common.deathCount), true))
                ---@diagnostic disable-next-line: undefined-global
                embed:AddField(EmbedField.new("Kill Count",
                                              tostring(Common.killCount), true))
                ---@diagnostic disable-next-line: undefined-global
                embed:AddField(EmbedField.new("Phase",
                                              tostring(mechanics.state.phase),
                                              true))
                ---@diagnostic disable-next-line: undefined-global
                embed:AddField(EmbedField.new("Runtime",
                                              API.ScriptRuntimeString(), true))
                embed:SetFooter(discordFooter("Recovery in progress..."))

                sendDiscord(embed, "death")
            end
        end

        return Common.isDead
    end,
    action = function()
        -- Phase 1: reclaim while inside Death's Office.
        if inDeathsOffice() and not Common.deathReclaimed then
            Common.reachedDeathOffice = true
            reclaimAtDeathsOffice()
            return true
        end

        -- Not in the office yet. Until we've actually been there, do NOT
        -- teleport — that could strand our reclaimable items at Death.
        if not Common.reachedDeathOffice then
            -- False positive: HP read 0 but we're alive in the instance.
            if Player:getHP() > 0 and API.InInstancedArea() then
                Utils:log("- Death flag cleared (false positive, still alive)",
                          "warn")
                Common.isDead = false
                return true
            end
            return true -- mid death-transition; wait to arrive
        end

        -- Phase 2: reclaimed — teleport out (this also leaves the office).
        if not warsRetreat:atLocation() then
            Utils:log("- Death recovery: teleporting to War's Retreat", "warn")
            Utils:useAbility("War's Retreat Teleport")
            API.RandomSleep2(3500, 3500, 3500)
            return true
        end

        -- Phase 3: back at War's Retreat — clear death state and reset so the
        -- normal banking/lobby flow restocks and re-enters.
        Utils:log("- Death recovery complete, resuming at War's Retreat", "warn")
        Common.isDead = false
        Common.reachedDeathOffice = false
        Common.deathReclaimed = false
        Common.deathReclaimStep = nil
        Common.deathReclaimStepTick = nil

        warsRetreat:reset()
        rotationManager:unload()
        RakshaFight:reset()

        return true
    end,
    executionData = {lastRun = 0, count = 0}
})

------------------------------------------
-- # TRACKING
------------------------------------------

--- Flattens the loot ledger into the shape the GUI renders.
---
--- Sorted by value rather than by name or by when it dropped, so the line that
--- actually pays for the trip sits at the top. Cheap enough to do per frame: the
--- table is one entry per DISTINCT item id, which for this drop table is a few
--- dozen at most, and the prices behind it are already cached.
--- @return table
local function buildLootSnapshot()
    local elapsed = os.time() - Common.scriptStartTime
    local perHour = elapsed > 0 and (Common.lootValue / (elapsed / 3600)) or 0
    local perKill = Common.killCount > 0 and
                        (Common.lootValue / Common.killCount) or 0

    -- COPIED, not handed over by reference. The draw callback runs on ImGui's
    -- thread (see the note in buildGUIData), so a table the fight loop can still
    -- table.insert into is one the renderer could be walking mid-write.
    local rares, history, best = {}, {}, 0
    for i, r in ipairs(Common.rareLog) do rares[i] = r end
    for i, k in ipairs(Common.lootPerKill) do
        history[i] = k
        if k.gp > best then best = k.gp end
    end

    return {
        totalValue = Common.lootValue,
        gpPerHour = perHour,
        gpPerKill = perKill,
        bestKill = best,
        history = history,
        rares = rares
    }
end

------------------------------------------
-- # LOOP HEALTH
------------------------------------------

--- How many main-loop iterations happened in the last tick, and the largest tick
--- JUMP seen between two consecutive iterations.
---
--- This exists to answer "are we behind the game?" with a number rather than a
--- feeling. The loop is meant to run 12-20 times per 600ms game tick, and every
--- per-tick memo in this script — and in core/rotation_manager — assumes it
--- runs at least once per tick.
---
--- `jump` is the reading that matters. Between two consecutive iterations the
--- tick counter should move by 0 (still the same tick) or 1 (we rolled into the
--- next). A jump of 2 or more means one pass of the loop took longer than a
--- whole game tick and we SKIPPED one: every mechanic that started and ended
--- inside that tick was never seen, and the rotation's `wait` counted down
--- against a tick we never observed. That is what being "ticks behind" is.
local loopHealth = {itersThisTick = 0, itersLastTick = 0, lastJump = 0,
                    worstJump = 0, skippedTicks = 0, lastTick = -1}

--- Records one pass of the main loop. Costs a single Get_tick.
local function noteLoopIteration()
    local tick = API.Get_tick()

    if loopHealth.lastTick < 0 then
        loopHealth.lastTick = tick
        loopHealth.itersThisTick = 1
        return
    end

    local jump = tick - loopHealth.lastTick
    if jump == 0 then
        loopHealth.itersThisTick = loopHealth.itersThisTick + 1
        return
    end

    -- Rolled into a new tick: publish the count for the tick that just ended.
    loopHealth.itersLastTick = loopHealth.itersThisTick
    loopHealth.itersThisTick = 1
    loopHealth.lastTick = tick
    loopHealth.lastJump = jump

    if jump > loopHealth.worstJump then loopHealth.worstJump = jump end

    -- A jump of 1 is normal. Beyond that is ticks we never looked at.
    if jump > 1 then
        loopHealth.skippedTicks = loopHealth.skippedTicks + (jump - 1)
    end
end

--- Cached mechanics debug rows, and the clock reading they were built at.
local trackingCache, trackingCacheAt = nil, -math.huge

--- How often the mechanics debug readout may be rebuilt, in seconds.
---
--- It is a HUMAN-READABLE DIAGNOSTIC — nobody can read a table that updates 60
--- times a second, so rebuilding it at the client's frame rate bought nothing
--- and cost a great deal. Four times a second is still faster than the eye
--- follows and is ~1/20th of the scanning.
local TRACKING_INTERVAL = 0.25

--- The mechanics debug rows, gated and throttled.
---
--- THIS WAS THE MAIN SOURCE OF THE DELAY. Mechanics:tracking() ends with a live
--- "Detected:" block that runs five object scans — findAnyType for 2789, 27355,
--- 27356 and 27354, plus getShadowTiles — and findAnyType asks for EIGHT object
--- types at once (mechanics.lua:270), three of them at range 60. buildGUIData
--- called it unconditionally on every RENDERED FRAME, on ImGui's thread. At 60
--- fps that is ~300 native object-array scans a second, all of them competing
--- with the fight loop for the same client, purely to fill a debug table.
---
--- Two gates now. The tab that displays these rows only exists when the
--- mechanics debug flag is on (raksha/gui.lua:1154), so with it off the rows
--- were being computed and then thrown away entirely — that path now does no
--- work at all. With it on, the rebuild is throttled to TRACKING_INTERVAL and
--- the last table is handed back in between.
---
--- CONFIG.debug.mechanics, NOT CONFIG.debugMechanics: getConfig() reshapes the
--- flat GUI table into a nested runtime one (raksha/gui.lua:475-483), so the
--- flat name the checkbox and the tab check use does not exist on CONFIG. Gating
--- on the wrong name here would read nil and silently disable the tab for
--- everyone.
---
--- os.clock rather than API.Get_tick deliberately: this is display pacing, not
--- game logic, and it should not speed up or slow down with the tick.
--- @return table|nil
local function trackingSnapshot()
    if not (CONFIG.debug and CONFIG.debug.mechanics) then return nil end

    local now = os.clock()
    if trackingCache and (now - trackingCacheAt) < TRACKING_INTERVAL then
        return trackingCache
    end

    trackingCacheAt = now
    trackingCache = mechanics:tracking()
    return trackingCache
end

--- Builds the live data the GUI renders each frame.
--- @return table
local function buildGUIData()
    local fastest, slowest, average = Utils:getKillStats(Common.killData)
    local boss = RakshaFight:getBoss()

    local location = "Unknown"
    if Common.isDead then
        location = "DEAD (recovering)"
    elseif RakshaFight:atLocation() then
        location = "Raksha Arena"
    elseif RakshaLobby:atLocation() then
        location = "Raksha Lobby"
    elseif warsRetreat:atLocation() then
        location = "War's Retreat"
    end

    return {
        status = timer:getStatus(),
        location = location,
        inFight = RakshaFight:atLocation(),
        killCount = Common.killCount,
        killsPerHour = Utils:valuePerHour(Common.killCount,
                                          Common.scriptStartTime),
        deathCount = Common.deathCount,
        fastestKill = fastest,
        slowestKill = slowest,
        averageKill = average,
        boss = {
            found = boss.found,
            health = boss.health,
            animation = boss.animation,
            mechanic = Constants.ANIM_NAMES[boss.animation] or "-"
        },

        -- Dashboard extras. Read here rather than inside the GUI so the draw
        -- callback stays a pure renderer — it runs on ImGui's thread and should
        -- not be reaching into game memory itself.
        phase = mechanics.state.phase,
        activeMechanic = mechanics.state.activeDef and
            mechanics.state.activeDef.name or nil,
        dodging = mechanics.state.instakillActive,
        player = {
            hp = Player:getHP(),
            maxHp = Player:getMaxHP(),
            prayer = Player:getPrayerPercent(),
            adrenaline = Player:getAdrenaline(),
            maxAdrenaline = Player:getMaxAdrenaline()
        },
        review = mechanics:reviewSnapshot(),

        mechanics = trackingSnapshot(),
        loot = buildLootSnapshot(),

        profile = profileSnapshot(),

        -- Cheap enough to send every frame: four numbers, no game reads.
        loopHealth = {
            itersLastTick = loopHealth.itersLastTick,
            lastJump = loopHealth.lastJump,
            worstJump = loopHealth.worstJump,
            skippedTicks = loopHealth.skippedTicks
        }
    }
end

------------------------------------------
-- # STARTUP CHECKS
------------------------------------------

if not Constants.OBJECTS.PORTAL.name then
    Utils:terminate("Portal name is not set in raksha/constants.lua")
end

if not lootConfigured() then
    Utils:log("No loot IDs configured — kills will not be looted.", "warn")
end

if #LOADOUT == 0 then
    Utils:log("LOADOUT is empty — banking is disabled (supplies won't refill). " ..
                  "Add your consumables to LOADOUT in main.lua.", "warn")
end

-- Log the resolved task order: if a step is missing here it will never run, no
-- matter what its toggle says (that's how PREBUILD got silently skipped).
Utils:log("War's Retreat task order: " ..
              table.concat(CONFIG.warsRetreat.taskOrder, " -> "))
if CONFIG.usePrebuild then
    local hasPrebuild = false
    for _, key in ipairs(CONFIG.warsRetreat.taskOrder) do
        if key == "PREBUILD" then hasPrebuild = true end
    end
    if not hasPrebuild then
        Utils:log("Pre-build is enabled but PREBUILD is missing from the task " ..
                      "order — the dummies will be skipped.", "warn")
    end
end

Utils:log(string.format("Starting Raksha v%s", CONFIG.scriptVersion))

------------------------------------------
-- # MAIN LOOP
------------------------------------------

-- Swap the settings window for the runtime window.
--
-- buildGUIData is pcall'd because it runs INSIDE the render callback, before
-- GUI.draw is entered — so it sits outside the safeDraw protection the GUI has
-- around its own tabs (raksha/gui.lua:1127). A bad read there would escape into
-- ImGui mid-frame, skip the endTab/endTabBar calls and leave the window broken
-- until restart, which is the exact failure safeDraw exists to prevent. A failed
-- build draws an empty frame and we try again next one.
DrawImGui(function()
    if not GUI.open then return end
    local ok, data = pcall(buildGUIData)
    GUI.draw(ok and data or {})
end)
GUI.selectInfoTab = true

-- Last value SetDrawLogs was given, so we only push it when it changes.
--
-- It was going to the client on every loop iteration — 12-20 times a game
-- tick — for a value that only changes when the user ticks a checkbox.
local lastDrawLogs = nil

while API.Read_LoopyLoop() do
    if GUI.isStopped() then
        API.printlua("Script stopped by user", 0, false)
        break
    end

    -- Pause halts the script logic but keeps the GUI responsive
    if not GUI.isPaused() then
        local t = os.clock()

        -- Timer tasks run before the player manager, matching Rasial's ordering
        timer:run()
        t = profMark("timer:run", t)

        playerManager:update()
        profMark("playerManager", t)

        if CONFIG.debug.main ~= lastDrawLogs then
            lastDrawLogs = CONFIG.debug.main
            API.SetDrawLogs(lastDrawLogs)
        end
    end

    noteLoopIteration()

    local tSleep = os.clock()
    API.RandomSleep2(30, 10, 10)
    profMark("RandomSleep2", tSleep)
end
