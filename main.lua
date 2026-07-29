--- @module 'raksha.main'
--- @version 0.1.0
--- Raksha (normal mode) — fight loop.
---
--- Structure follows rasial/main.lua: a Timer holds prioritised tasks, one of
--- which drives the fight; War's Retreat handles everything between kills.
---
--- STATUS: end-to-end loop is in place and self-sustaining — War's Retreat ->
--- portal -> fight -> loot -> teleport back -> repeat. Settings are inline
--- constants; the GUI is a later step.
---@diagnostic disable: undefined-global

local API             = require("api")

local RotationManager = require("core.rotation_manager")
local PlayerManager   = require("core.player_manager")
local PrayerFlicker   = require("core.prayer_flicker")
local WarsRetreat     = require("core.wars_retreat")
local Player          = require("core.player")
local Utils           = require("core.helper")
local Timer           = require("core.timer")

local Constants       = require("raksha.constants")
local Mechanics       = require("raksha.mechanics")
local GUI             = require("raksha.gui")

------------------------------------------
-- # SETTINGS
------------------------------------------

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
        ids = {49079, 49081, 49083, 49085, 39220, 39222, 39224, 39226, 39228, 39230},
        --ids = {39220, 39222, 39224, 39226, 39228, 39230},
        amount = 1,
        name = "Adrenaline renewal"
        --name = "Enhanced replenishment potion"
    }
}

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

        -- Tertiary
        51102 -- Broken shackle (1/1,000)
    },

    -- The 1/50 unique table.
    UNIQUES = {
        51082, -- Fleeting boots
        51086, -- Shadow spike
        51094, -- Greater Ricochet ability codex
        51096, -- Greater Chain ability codex
        51098 -- Divert ability codex
    }
}

--- @return boolean
local function lootConfigured()
    return (#LOOT.COMMONS + #LOOT.UNIQUES) > 0
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
        canApply = function() return Inventory:Contains(ELDER_OVERLOAD_IDS) end,
        execute = function()
            return Inventory:DoAction("Elder overload potion", 1,
                                      API.OFF_ACT_GeneralInterface_route)
        end,
        refreshAt = math.random(10, 20)
    }
}

------------------------------------------
-- # SCRIPT INITIALIZATION
------------------------------------------

Interact:SetSleep(0, 0, 0)
API.Write_fake_mouse_do(false)
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

-- Push the tunable mechanic values from the GUI onto the constants the
-- mechanics module reads.
do
    local m = CONFIG.mechanics
    Constants.ADDS.ANIMA_POOL.ignore = m.ignoreAnimaPools
    Constants.ADDS.ANIMA_POOL.killThreshold = m.poolKillThreshold
    Constants.ADDS.ANIMA_POOL.diveDistance = m.poolDiveDistance
    Constants.SHADOW_FLOOR.triggerRange = m.shadowTriggerRange
    Constants.SHADOW_FLOOR.safeRange = m.shadowSafeRange
    Constants.INSTAKILL.triggerRange = m.instakillTriggerRange
    Constants.INSTAKILL.safeRange = m.instakillSafeRange
    local bombs = Constants.MECHANICS[Constants.ANIM.BOMBS]
    if bombs then bombs.escapeDistance = m.bombEscapeDistance end
end

ClearRender()

local Common = {
    scriptStartTime = os.time(),
    killCount = 0,
    deathCount = 0,
    killData = {},
    fightStartTick = nil,

    -- Death recovery (ported from rasial/main.lua)
    isDead = false, -- Latched while the recovery flow is running
    deathTime = nil, -- os.time() of the death, for logging
    deathReclaimStep = nil, -- Death's Office reclaim state-machine step
    deathReclaimStepTick = nil, -- Tick the current reclaim step started
    reachedDeathOffice = false, -- True once we've actually arrived at Death
    deathReclaimed = false -- True once items are back, so we stop and leave
}

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

-- A straight transcription of the PVME Necromancy Raksha rotation:
--   https://pvme.io/pvme-guides/rs3-full-boss-guides/raksha/necromancy/
--
-- Every phase has its own line and gets it in full — a phase transition swaps
-- the entire rotation out (see PHASE_ROTATIONS), so what runs in phase 2 is
-- phase 2's line and nothing else. The guide, verbatim, for reading against:
--
--   Inside instance
--     Conjure army -> Life transfer -> Command ghost
--   Phase 1
--     Surge + Invoke death -> Command skeleton -> Split soul + Vuln bomb under
--     Raksha -> tc + Bloat -> Death skulls -> Volley of souls -> Soul sap ->
--     Divert -> Touch of death -> Soul sap -> Command skeleton
--   Phase 2
--     Living death + Adrenaline renewal -> Touch of death -> Death skulls ->
--     Soul sap -> Finger of death -> Finger of death -> Soul sap -> Basic ->
--     Basic -> Death skulls -> Basic -> Touch of death -> Basic ->
--     improvise basics if not phased
--   Phase 3
--     Finger of death -> Finger of death -> Basic -> Death skulls -> Bloat ->
--     Volley of souls -> Threads of fate + target pools -> Soul sap ->
--     target Raksha + Volley of souls
--   Phase 4
--     Anti -> Soul sap -> Touch of death -> Basic -> equip Excalibur -> equip
--     Soulbound lantern + Conjure army -> Soul sap -> Command skeleton ->
--     Command ghost -> Death skulls -> Ingenuity + Roar of awakening / Ode to
--     deceit spec (0 tick) -> Divert -> Soul sap -> Split soul -> Bloat ->
--     Omniguard spec -> Basic -> Soul sap -> Command skeleton -> Volley of
--     souls -> Touch of death -> Finger of death -> Deathguard90 EOF spec ->
--     improvise if not dead
--
-- Each line ends on improviseTail(), which is Improvise with `spend = false` —
-- the guide's "improvise basics if not phased" / "improvise if not dead". The
-- rotation manager never advances past an Improvise step, so we sit on it until
-- the phase changes and the next line is loaded.
--
-- IMPORTANT: each of these MUST be a flat array of steps. RotationManager:load
-- iterates with ipairs, so a {name=, rotation={}} wrapper reads as empty and
-- silently fails to load. Buff ids: 30101 = Necrosis, 30123 = Residual Souls.
--
-- Steps whose ability the account hasn't unlocked (e.g. Split Soul) simply fail
-- and advance — useAbility returns false, the rotation moves on after its wait.

--- Item names for phase 4's weapon switches, in one place because the exact
--- in-game strings vary with upgrade tier. Every switch step is conditional on
--- actually carrying the item, so a name that doesn't match costs nothing but
--- that switch — the rotation flows straight past it.
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
--- @param name string
--- @param wait? number
--- @return table
local function equipIfCarried(name, wait)
    return {
        label = "Equip " .. name,
        type = "Custom",
        condition = function() return #Inventory:GetItem(name) > 0 end,
        action = function()
            Inventory:Equip(name)
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
            for _, name in ipairs({SWITCHES.genesisMain, SWITCHES.deathguard}) do
                if #Inventory:GetItem(name) > 0 then
                    Inventory:Equip(name)
                    break
                end
            end
            for _, name in ipairs({SWITCHES.genesisOff, SWITCHES.lantern}) do
                if #Inventory:GetItem(name) > 0 then
                    Inventory:Equip(name)
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

--- Volley of Souls needs 5 Residual Souls; Soul Sap is the builder to fall back
--- on when we're short.
--- @param wait? number
--- @return table
local function volleyOfSouls(wait)
    return {
        label = "Volley of Souls",
        condition = function() return Player:getBuff(30123).remaining >= 5 end,
        replacementLabel = "Soul Sap",
        wait = wait or 3,
        useTicks = true
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
        wait = wait or 4,
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
    {label = "Surge", wait = 3, useTicks = true},
    {label = "Surge", wait = 2, useTicks = true},

    -- --- PVME "Inside instance" ---------------------------------------------
    -- Conjure army -> Life transfer -> Command ghost.
    --
    -- The lobby normally summons the army before we walk through the gate, in
    -- which case conjureArmy() skips straight through — but it stays here so a
    -- summon that failed in the lobby is still made before the fight starts.
    conjureArmy(4),
    {label = "Life Transfer", wait = 2, useTicks = true},
    {label = "Command Vengeful Ghost", wait = 2, useTicks = true},
    {
        -- Walk to the safespot, once, and record it as HOME for the fight.
        --
        -- The arena is instanced so fixed tiles shift between runs; we anchor to
        -- the sleeping Raksha (27351) instead. Registering this as home makes it
        -- the centre for every movement decision — dodges move off it and we
        -- walk back once the danger clears, so positioning is repeatable rather
        -- than drifting with the boss.
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
            return API.DoAction_WalkerW(WPOINT.new(hx, hy, hz))
        end,
        wait = 2,
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
    {label = "Invoke Death", wait = 2, useTicks = true},
    {label = "Command Skeleton Warrior", wait = 2, useTicks = true},

    -- "Split soul + Vuln bomb under Raksha" — the bomb is thrown at whatever
    -- we're targeting, so acquiring him first is what puts it under him.
    targetRaksha(1),
    {label = "Split Soul", wait = 2, useTicks = true},
    {
        label = "Vulnerability bomb",
        type = "Inventory",
        wait = 1,
        useTicks = true,

        -- ==== END OF SETUP ================================================
        -- Everything up to and including this step is buffs, conjures,
        -- positioning and engaging — none of which Revolution will do for us,
        -- so it runs in both modes. Everything BELOW is the damage rotation,
        -- which Revolution replaces. Flagged on the step itself rather than
        -- matched by label, so re-ordering the pre-fight can't silently move
        -- the boundary. See SETUP_STEP_COUNT.
        -- ==================================================================
        setupBoundary = true
    },

    -- "tc + Bloat": re-acquire Raksha, then open the damage.
    targetRaksha(1),
    {label = "Bloat", wait = 3, useTicks = true},
    {label = "Death Skulls", wait = 4, useTicks = true},
    volleyOfSouls(3),
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Divert", wait = 3, useTicks = true},
    {label = "Touch of Death", wait = 3, useTicks = true},
    {label = "Soul Sap", wait = 3, useTicks = true},
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
    -- "Living death + Adrenaline renewal": drunk in the same beat as the
    -- ultimate rather than saved, and it's what funds the Finger pair below.
    -- The drink goes first because it's an inventory action, so the adrenaline
    -- is already there when Living Death checks for it.
    {
        label = "Adrenaline renewal",
        type = "Inventory",
        condition = function() return API.GetAdrenalineFromInterface() < 100 end,
        wait = 1,
        useTicks = true
    },
    -- Living Death needs 5 ticks to land, not the GCD — at 2 it cut straight
    -- into the following ability.
    {label = "Living Death", wait = 5, useTicks = true},
    {label = "Touch of Death", wait = 3, useTicks = true},
    -- Death Skulls runs long; Rasial gives it 4 inside the Living Death window.
    {label = "Death Skulls", wait = 4, useTicks = true},
    {label = "Soul Sap", wait = 1, useTicks = true}, -- weaves off Death Skulls
    fingerOfDeath(4),
    fingerOfDeath(3),
    {label = "Soul Sap", wait = 3, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Death Skulls", wait = 4, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Touch of Death", wait = 3, useTicks = true},
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},

    -- "improvise basics if not phased"
    improviseTail()
}

------------------------------------------
-- # PHASE 3 ROTATION
------------------------------------------

--- PVME phase 3, in full:
---   Finger of death -> Finger of death -> Basic -> Death skulls -> Bloat ->
---   Volley of souls -> Threads of fate + target pools -> Soul sap ->
---   target Raksha + Volley of souls
---
--- "Threads of fate + target pools" is the one step that hands control away.
--- It casts the AoE and then ARMS the pool clear; from the next tick
--- mechanics:handleAnimaPools owns the target and the abilities, and this
--- rotation is held (see Mechanics:rotationOnHold) until the last pool is dead.
--- We resume at the Soul Sap below with Raksha re-acquired. Chasing the pools
--- from here as well is what had two layers fighting over the target.
local PHASE3_ROTATION = {
    fingerOfDeath(3),
    fingerOfDeath(3),
    {label = "Basic<nbsp>Attack", wait = 3, useTicks = true},
    {label = "Death Skulls", wait = 4, useTicks = true},
    {label = "Bloat", wait = 3, useTicks = true},
    volleyOfSouls(3),
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
    {label = "Soul Sap", wait = 3, useTicks = true},

    -- "target Raksha + Volley of souls" — the pool clear leaves us on the
    -- cluster, and the Volley that follows has to land on the boss.
    targetRaksha(1),
    volleyOfSouls(3),

    improviseTail()
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
    improviseTail()
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
local SPECIAL_ACTION_BUFF = 45036
local SPECIAL_ACTION_MAX_CLICKS = 3 -- hard cap per buff window
local SPECIAL_ACTION_RETRY_TICKS = 2 -- pacing between retries

--- True while the special action button is still drawn on screen.
--- Component 6 is the one Raksha's button is clicked through; 0 and 1 are
--- included because that's where other bosses' buttons expose their label and
--- the container layout isn't guaranteed to be identical.
--- @return boolean
local function specialActionVisible()
    -- Nested-table form: ScanForInterfaceTest2Get builds the InterfaceComp5
    -- objects itself when handed plain tables, which is how every other caller
    -- in this codebase uses it — so the missing-fields warning is spurious.
    ---@diagnostic disable-next-line: missing-fields
    local ok, found = pcall(API.ScanForInterfaceTest2Get, false,
                            {{743, 0, -1, 0}, {743, 1, -1, 0}, {743, 6, -1, 0}})
    if not ok or type(found) ~= "table" then return false end

    for _, entry in ipairs(found) do
        if entry and type(entry.textitem) == "string" and entry.textitem ~= "" then
            return true
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

local RakshaFight = {
    variables = {
        engaged = false, -- Rotation loaded and fight underway
        bossDead = false,
        looted = false,
        lootDeadline = 0, -- tick we give up looting and teleport out regardless
        lootTimeoutLogged = false,
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
        transitionReattacked = false -- Raksha re-targeted during the grace window
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

--- @return table
function RakshaFight:getBoss()
    return Utils:getEntityInfo(Constants.BOSS.id, Constants.BOSS.type, 60)
end

--- True once the subdued Raksha (27353) is on the floor — he's dead and the drop
--- can be looted.
--- @return boolean
function RakshaFight:subduedPresent()
    local sub = Constants.BOSS_SUBDUED
    return #Utils:findAll(sub.id, sub.type, 60) > 0
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

-- Seconds to wait for a new-instance attempt to take effect before retrying,
-- and how long an instance is kept before forcing a fresh one.
local INSTANCE_TIMEOUT = 30
local INSTANCE_MAX_AGE = 58 * 60

local RakshaLobby = {
    variables = {
        instanceStartTime = 0, -- os.clock() when the current instance was made
        rejoinAttempts = 0, -- consecutive rejoin tries this trip
        lastInstanceAttempt = 0, -- os.clock() of the pending new-instance attempt
        instanceAttemptCount = 0, -- consecutive new-instance timeouts
        lobbyEnteredTick = nil -- tick we arrived, for the conjure wait window
    }
}

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

--- Creates a fresh instance through the gate, clicking through the
--- create-instance dialog when it appears. Copied from Rasial's startNewInstance.
--- @return boolean
function RakshaLobby:startNewInstance()
    local gate = Constants.OBJECTS.SECURITY_GATE

    -- Start the timeout clock on the first attempt
    if self.variables.lastInstanceAttempt == 0 then
        self.variables.lastInstanceAttempt = os.clock()
    end

    if API.Check_Dialog_Open() then
        -- Confirm "create new instance" on the dialog
        ---@diagnostic disable-next-line:missing-parameter
        return API.DoAction_Interface(0xffffffff, 0xffffffff, 0, 1188, 13, -1,
                                      API.OFF_ACT_GeneralInterface_Choose_option)
    elseif API.VB_FindPSettinOrder(2874).state == 18 then
        -- Enter-instance interface is up: click it
        ---@diagnostic disable-next-line:missing-parameter
        if API.DoAction_Interface(0x24, 0xffffffff, 1, 1591, 56, -1,
                                  API.OFF_ACT_GeneralInterface_route) then
            self.variables.instanceStartTime = os.clock()
            self.variables.lastInstanceAttempt = 0
            self.variables.instanceAttemptCount = 0
            return true
        end
    else
        ---@diagnostic disable-next-line
        return Interact:Object(gate.name, gate.action)
    end
    return false
end

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

    -- New instance when we have none, the current one is near expiry, or rejoin
    -- has failed too many times; otherwise rejoin the live instance.
    if self.variables.instanceStartTime == 0 or
        ((os.clock() - self.variables.instanceStartTime) > INSTANCE_MAX_AGE) or
        self.variables.rejoinAttempts > 3 then
        return self:startNewInstance()
    end
    return self:rejoiningInstance()
end

--- Resets per-kill state when leaving for a new trip.
function RakshaFight:reset()
    self.variables.engaged = false
    self.variables.bossDead = false
    self.variables.looted = false
    self.variables.lootDeadline = 0
    self.variables.lootTimeoutLogged = false
    self.variables.bossSeen = false
    self.variables.sawBossAlive = false
    self.variables.deadStreak = 0
    self.variables.lastDeadTick = nil
    self.variables.lastKnownHealth = -1
    self.variables.deadStreakWarned = false
    self.variables.conjured = false
    self.variables.luckEquipped = false
    self.variables.loadedPhase = 1
    self.variables.specialActionClicks = 0
    self.variables.lastSpecialActionTick = -99
    self.variables.transitionHolding = false
    self.variables.transitionEndTick = nil
    self.variables.transitionReattacked = false
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

    -- Fresh rejoin/new-instance counters each trip, but keep instanceStartTime
    -- so we know how old the live instance is and when to remake it.
    RakshaLobby.variables.rejoinAttempts = 0
    RakshaLobby.variables.lastInstanceAttempt = 0
    RakshaLobby.variables.instanceAttemptCount = 0
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

    if not API.LootWindowOpen_2() then
        return API.DoAction_G_Items1(0x45,
                                     Utils:virtualTableConcat(LOOT.COMMONS,
                                                              LOOT.UNIQUES), 30)
    end

    if API.DoAction_LootAll_Button() then
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
    Common.killCount = Common.killCount + 1

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

    table.insert(Common.killData, {
        runtime = API.ScriptRuntimeString(),
        fightDuration = Utils:formatKillDuration(durationMs)
    })

    Utils:log(string.format("----- KILL %d in %s -----", Common.killCount,
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
    local boss = self:getBoss()

    if boss.found then self.variables.bossSeen = true end

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
        playerManager:requestBuffs(BUFFS)

        prayerFlicker:update()

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

        -- Mechanics get first claim on the tick. When one consumes the action
        -- (a counter ability, an Escape, a Freedom/Surge step) the rotation
        -- must not also fire, or the two contend for the same global cooldown.
        local consumed = mechanics:update()

        -- Defensives come straight after the mechanic responses and ahead of
        -- everything else: staying alive beats both DPS and conjure upkeep.
        if not consumed and spendSurvivalAbilities() then consumed = true end

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
    else
        prayerFlicker:deactivatePrayer()
    end

    playerManager:manageHealth()
    playerManager:managePrayer()

    return true
end

------------------------------------------
-- # FIGHT TASKS
------------------------------------------

RakshaFight.tasks = {
    {
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
            Utils:log(string.format(
                          "Back at War's Retreat — clearing fight state (adrenaline %d/%d)",
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
        -- Lobby step 2: start the instance (rejoin or create), but only once the
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
                return false
            end

            -- Stamp our arrival the first time we see the lobby (conditions run
            -- once per cycle, so this is a safe place to latch it).
            RakshaLobby.variables.lobbyEnteredTick =
                RakshaLobby.variables.lobbyEnteredTick or API.Get_tick()

            if conjuring() then return false end -- never interrupt the summon
            if hasActiveConjures() then return true end

            -- No conjures yet: give the summon a fair window to land, then go
            -- anyway rather than stalling in the lobby forever.
            return (API.Get_tick() - RakshaLobby.variables.lobbyEnteredTick) >
                       CONJURE_WAIT_TICKS
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
        -- Wait for the reclaim interface to open
        if API.VB_FindPSettinOrder(2874).state == 18 then advance(3) end
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

        mechanics = mechanics:tracking()
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

-- Swap the settings window for the runtime window
DrawImGui(function() if GUI.open then GUI.draw(buildGUIData()) end end)
GUI.selectInfoTab = true

while API.Read_LoopyLoop() do
    if GUI.isStopped() then
        API.printlua("Script stopped by user", 0, false)
        break
    end

    -- Pause halts the script logic but keeps the GUI responsive
    if not GUI.isPaused() then
        -- Timer tasks run before the player manager, matching Rasial's ordering
        timer:run()
        playerManager:update()
        API.SetDrawLogs(CONFIG.debug.main)
    end

    API.RandomSleep2(30, 10, 10)
end
