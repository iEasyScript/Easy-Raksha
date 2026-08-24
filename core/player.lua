--- @module "Sonson's Player"
--- @version 1.0.0

------------------------------------------
--# IMPORTS
------------------------------------------

local API = require("api")

------------------------------------------
--# MODULE DEFINITION
------------------------------------------

local Player = {}

------------------------------------------
--# PLAYER CORE
------------------------------------------

--- Checks if the player is in the game.
--- @return boolean: True if the player is in the game, false otherwise.
function Player:isIngame()
    return API.PlayerLoggedIn() or false
end

--- Checks if the player is moving.
--- @return boolean: True if the player is moving, false otherwise.
function Player:isMoving()
    return API.ReadPlayerMovin2()
end

--- Checks if the player is animating.
--- @return boolean: True if the player is animating, false otherwise.
function Player:isAnimating()
    return API.CheckAnim(2) or false
end

--- Gets the current animation of the player.
--- @return number: The player's current animation.
function Player:getAnimation()
    return API.ReadPlayerAnim()
end

--- Gets the hover progress of the player.
--- @return number: The hover progress value.
function Player:getHoverProgress()
    return API.LocalPlayer_HoverProgress()
end

--- Checks if the player's run mode is enabled.
--- @return boolean: True if run mode is enabled, false otherwise.
function Player:isRunModeOn()
    return API.GetRun2() or false
end

--- Checks if the player is interacting with a specific entity.
--- @param idOrName number|string: The ID or name of the entity to check.
--- @return boolean: True if the player is interacting with the specified entity, false otherwise.
function Player:isInteractingWith(idOrName)
    local interacting = API.ReadLpInteracting()
    if interacting == nil then return false end
    if type(idOrName) == "number" then
        return interacting.Id == idOrName
    end
    if type(idOrName) == "string" then
        return interacting.Name == idOrName
    end

    return false
end

------------------------------------------
--# COMBAT
------------------------------------------

--- Checks if the player is in combat.
--- @return boolean: True if the player is in combat, false otherwise.
function Player:isInCombat()
    return API.GetInCombBit()
end

--- Checks if the player is targeting an entity.
--- @return boolean: True if the player is targeting an entity, false otherwise.
function Player:isTargeting()
    return API.IsTargeting() or false
end

--- Checks if the player is being attacked by a specific entity.
--- @param idOrName number|string: The ID or name of the entity to check.
--- @return boolean: True if the player is being attacked by the specified entity, false otherwise.
function Player:isBeingAttackedBy(idOrName)
    local attacking = API.OthersInteractingWithLpNPC(true, 0)
    if attacking == nil then return false end
    if type(idOrName) == "number" then
        return attacking.Id == idOrName
    end
    if type(idOrName) == "string" then
        return attacking.Name == idOrName
    end

    return false
end

------------------------------------------
--# LOCATION AND NAVIGATION
------------------------------------------

--- Gets the player's current coordinates.
--- @return WPOINT: The player's coordinates as a WPOINT.
function Player:getCoords()
    return API.PlayerCoord()
end

--- Gets the player's current region.
--- @return {regionX:number,regionY:number,regionId:number}: The player's region.
function Player:getRegion()
    return API.PlayerRegion()
end

--- Checks if the player is at a specific coordinate.
--- @param tile WPOINT: The tile coordinate to check.
--- @return boolean: True if the player is at the specified coordinate, false otherwise.
function Player:isAtCoord(tile)
    return API.Dist_FLPW(tile) < 1
end

--- Checks if the player is within a specified radius of a coordinate.
--- @param tile WPOINT: The tile coordinate to check.
--- @param radius number: The radius within which to check.
--- @return boolean: True if the player is within the specified radius, false otherwise.
function Player:isAtCoordWithRadius(tile, radius)
    return API.Dist_FLPW(tile) < radius
end

--- Gets the player's orientation in degrees.
--- @return number: The player's orientation in degrees (0-359).
function Player:getOrientation()
    return math.floor(API.calculatePlayerOrientation()) % 360
end

--- Gets the player's facing direction as a string.
--- @return string: The player's facing direction (e.g., "North", "East").
function Player:getFacingDirection()
    local deg = Player:getOrientation()
    local directions = {
        { min = 338, max = 22,  name = "North" },
        { min = 23,  max = 67,  name = "Northeast" },
        { min = 68,  max = 112, name = "East" },
        { min = 113, max = 157, name = "Southeast" },
        { min = 158, max = 202, name = "South" },
        { min = 203, max = 247, name = "Southwest" },
        { min = 248, max = 292, name = "West" },
        { min = 293, max = 337, name = "Northwest" }
    }

    -- Special case for North (wraps around 0°)
    if deg >= 338 or deg <= 22 then
        return "North"
    end

    for _, dir in ipairs(directions) do
        if deg >= dir.min and deg <= dir.max then
            return dir.name
        end
    end
    return "North" -- Fallback (should never reach here)
end

------------------------------------------
--# PLAYER STATE
------------------------------------------

--- Per-GAME-TICK memo for the vitals reads below.
---
--- THESE CALLS ARE EXPENSIVE. Profiling a Raksha fight measured them at roughly
--- 47ms EACH in this API build — so a boss loop that passes 12-20 times per
--- 600ms tick, reading HP and prayer on every pass, spends more than the whole
--- tick just asking how much health it has. The measured symptom was a main loop
--- managing ONE pass per game tick and skipping ~44% of ticks outright: boss
--- animations started and finished unseen, and rotation waits counted down
--- against ticks nobody observed.
---
--- Memoising is semantically neutral, which is the reason it is safe to do here
--- rather than at each call site. The client only updates these values when it
--- receives a tick from the server, so a second read within the same tick
--- returns the identical number — just 47ms later. Nothing can observe the
--- difference except the clock.
---
--- Deliberately NOT applied to anything that can change between ticks. Buffs and
--- debuffs (getBuff / getDebuff) are left uncached: they are read to decide
--- whether an ability landed, and that answer must be allowed to change.
local vitals = { tick = -1 }

--- Reads one vital at most once per game tick.
--- @param key string cache key
--- @param read fun():number
--- @return number
local function cachedVital(key, read)
    local tick = API.Get_tick()
    if vitals.tick ~= tick then vitals = { tick = tick } end

    local value = vitals[key]
    if value == nil then
        value = read()
        vitals[key] = value
    end
    return value
end

--- Gets the player's current health points.
--- @return number: The player's current health points.
function Player:getHP()
    return cachedVital("hp", function() return API.GetHP_() or 0 end)
end

--- Gets the player's maximum health points.
--- @return number: The player's maximum health points.
function Player:getMaxHP()
    return cachedVital("maxHp", function() return API.GetHPMax_() or 0 end)
end

--- Gets the player's current health percentage.
--- @return number: The player's health percentage (0-100).
function Player:getHpPercent()
    return cachedVital("hpPercent", function() return API.GetHPrecent() or 0 end)
end

--- Gets the player's current prayer points.
--- @return number: The player's current prayer points.
function Player:getPrayerPoints()
    return cachedVital("prayer", function() return API.GetPray_() or 0 end)
end

--- Gets the player's maximum prayer points.
--- @return number: The player's maximum prayer points.
function Player:getMaxPrayerPoints()
    return cachedVital("maxPrayer", function() return API.GetPrayMax_() or 0 end)
end

--- Gets the player's prayer percentage.
--- @return number: The player's prayer percentage (0-100).
function Player:getPrayerPercent()
    return cachedVital("prayerPercent",
                       function() return API.GetPrayPrecent() or 0 end)
end

--- Gets the player's current summoning points.
--- @return number: The player's current summoning points.
function Player:getSummoningPoints()
    return cachedVital("summoning",
                       function() return API.GetSummoningPoints_() or 0 end)
end

--- Gets the player's maximum summoning points.
--- @return number: The player's maximum summoning points.
function Player:getMaxSummoningPoints()
    return cachedVital("maxSummoning",
                       function() return API.GetSummoningMax_() or 0 end)
end

--- Gets the player's summoning points as a percentage.
--- @return number: The player's summoning points percentage (0-100).
function Player:getSummoningPointsPercent()
    return math.floor((Player:getSummoningPoints() / Player:getMaxSummoningPoints()) * 100) or 0
end

--- Gets the player's current adrenaline level.
--- @return number: The player's adrenaline level (0-100).
function Player:getAdrenaline()
    return cachedVital("adrenaline", function()
        local adrenData = API.VB_FindPSettinOrder(679) -- adrenaline vb
        return adrenData and adrenData.state / 10 or 0
    end)
end

--  TODO: Add Heightened Senses VB check
--- Gets the maximum adrenaline value for the player
--- @return number: Maximum adrenaline value (100 or 120)
function Player:getMaxAdrenaline()
    return cachedVital("maxAdrenaline", function()
        return 100 + (API.VB_FindPSett(9509).state == 262144 and 20 or 0)
    end)
end

------------------------------------------
--# BUFF MANAGEMENT
------------------------------------------

--- Gets a specific player buff.
--- @param buffId number: The ID of the buff to retrieve.
--- @return {found: boolean, remaining: number}: Whether or not the buff was found and the remaining duration in seconds
function Player:getBuff(buffId)
    local buff = API.Buffbar_GetIDstatus(buffId, false)
    return { found = buff.found, remaining = ((buff.found and API.Bbar_ConvToSeconds(buff)) or -1) }
end

--- Gets a specific player debuff.
--- @param debuffId number: The ID of the debuff to retrieve.
--- @return {found: boolean, remaining: number}: Whether or not the debuff was found and the remaining duration in seconds
function Player:getDebuff(debuffId)
    local debuff = API.DeBuffbar_GetIDstatus(debuffId, false)
    return { found = debuff.found, remaining = (debuff.found and API.Bbar_ConvToSeconds(debuff)) or -1 }
end

------------------------------------------
--# INVENTORY MANAGEMENT
------------------------------------------

function Player:getItemInInventoryCount(items)
    local itemsFound = 0
    for _, item in ipairs(items) do
        local itemData = Inventory:GetItem(item)
        itemsFound = itemsFound + (#itemData or 0)
    end
    return itemsFound
end

function Player:hasFood(minCount)
    local foodCount = minCount or 1
    local foodItems = { "Kebab", "Bread", "Doughnut", "Roll", "Square sandwich",
        "Crayfish", "Shrimps", "Sardine", "Herring", "Mackerel",
        "Anchovies", "Cooked chicken", "Cooked meat", "Trout", "Cod",
        "Pike", "Salmon", "Tuna", "Bass", "Lobster", "Swordfish",
        "Desert sole", "Catfish", "Monkfish", "Beltfish", "Ghostly sole",
        "Cooked eeligator", "Shark", "Sea turtle", "Great white shark", "Cavefish",
        "Manta ray", "Rocktail", "Tiger shark", "Sailfish", "Baron shark",
        "Potato with cheese", "Tuna potato", "Great maki", "Great gunkan",
        "Rocktail soup", "Sailfish soup", "Fury shark", "Primal feast" }
    return self:getItemInInventoryCount(foodItems) >= foodCount
end

function Player:hasJellyfish(minCount)
    local foodCount = minCount or 1
    local foodItems = {
        "Blue blubber jellyfish", "2/3 blue blubber jellyfish", "1/3 blue blubber jellyfish",
        "Green blubber jellyfish", "2/3 green blubber jellyfish", "1/3 green blubber jellyfish"
    }
    return self:getItemInInventoryCount(foodItems) >= foodCount
end

function Player:hasHealingPotion(minCount)
    local foodCount = minCount or 1
    local foodItems = {
        "Guthix rest", "Super Guthix brew", "Saradomin brew"
    }
    return self:getItemInInventoryCount(foodItems) >= foodCount
end

return Player
