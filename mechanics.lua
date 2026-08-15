--- @module 'raksha.mechanics'
--- @version 1.0.0
--- Raksha mechanic detection and response.
---
--- Watches the boss's animation and fires the response defined in
--- raksha/constants.lua. Modelled on the Arch-Glacor approach (animation ->
--- mechanic -> behaviour) but kept as a standalone module so the fight loop can
--- call one `update()` and get a clear "did I take the game action this tick"
--- answer back.
---
--- Contract: `update()` returns true when it consumed the tick's action. The
--- caller must then skip its normal rotation for that tick, so a dodge and an
--- ability never contend for the same global cooldown.
---@diagnostic disable: undefined-global

local API       = require("api")
local Utils     = require("core.helper")
local Player    = require("core.player")
local Constants = require("raksha.constants")

local Mechanics = {}
Mechanics.__index = Mechanics

------------------------------------------
-- # CONSTRUCTION
------------------------------------------

--- @param options? table {debug: boolean}
--- @return table
function Mechanics.new(options)
    options = options or {}
    local self = setmetatable({}, Mechanics)

    self.debug = options.debug or false

    -- Revolution mode: the action bar handles damage, so we target things and
    -- handle mechanics but never cast damage abilities ourselves. Mechanic
    -- responses (Freedom / Escape / Anticipation / dodges) still fire — the bar
    -- won't do those.
    self.revolution = options.revolution or false

    self.state = {
        -- Currently active mechanic, if any
        activeAnim = nil,
        activeDef = nil,
        startTick = 0,

        -- Sequence progress
        stepIndex = 1,
        stepExecuted = false, -- has the current step fired yet
        stepTick = 0, -- tick the current step fired, for its `wait`
        stepTimeMs = 0, -- os.clock ms it fired, for real-time `waitMs`
        stepArrivedTick = nil, -- tick we reached the step, for any pre-delay

        -- Presence-based adds (Shadow Energy)
        addsActive = false,

        -- Top-priority insta-kill highlight (object 2789)
        instakillActive = false,
        lastLethalMoveTick = -99, -- pacing for the lethal-ground dodge
        lethalTarget = nil, -- committed escape tile, so we don't re-pick each tick

        -- True once we have got clear of the sweep currently animating. One
        -- escape per sweep — see ensureClearOfSweep.
        sweepEscaped = false,

        -- Floor shadows, cached by tile. Keyed "x:y" -> {x, y, seen}. Entries
        -- linger briefly after they stop being detected so a scan flicker can't
        -- make us dart back and forth, then are dropped once genuinely gone.
        shadowCache = {},

        -- Anima pools being cleared during the bombs phase
        poolsActive = false,
        lastPoolAbilityTick = -99, -- GCD pacing for pool DPS
        lastPoolTargetTick = -99, -- when we last clicked a pool
        lastPoolSurgeTick = -99, -- when we last surged toward one
        poolTargetId = nil, -- Unique_Id of the pool we're currently killing
        -- Set by the phase 3 rotation's "Threads of fate + target pools" step.
        -- Starts a clear regardless of how many are up, since that is the point
        -- in the guide's line where the pools are meant to be dealt with.
        poolClearRequested = false,

        -- Shadow manifestation (NPC 27355) being killed
        manifestationActive = false,
        lastManifestAbilityTick = -99, -- GCD pacing for manifestation DPS
        manifestTargetId = nil, -- Unique_Id of the one we're attacking
        lastManifestTargetTick = -99, -- when we last clicked it

        -- Expel pacing, in real milliseconds (sub-tick — see EXPEL_INTERVAL_MS)
        lastExpelTick = -99,
        lastExpelMs = 0,
        expelIndex = 0, -- round-robin cursor over the orbs currently up

        -- Sustained behaviour bookkeeping (dodgeBombs)
        lastMoveTick = -1,

        -- Last tick each mechanic fired, for retrigger suppression
        lastFired = {},

        -- The anchor for every movement decision: our home tile when we have
        -- one, otherwise the boss's tile as a fallback.
        arenaCenter = nil,

        -- Home tiles, recorded once per fight from the safespot. homeAlt is the
        -- fallback used when the primary is under a hazard.
        homeTile = nil,
        homeAlt = nil,
        lastHomeMoveTick = -99,

        -- Raksha's own tile, tracked separately from arenaCenter because phase 4
        -- positioning is relative to him rather than to a fixed spot.
        arenaCenterBoss = nil,

        -- Fight phase (1-4) from boss HP, and the pool-siphon chat cue.
        phase = 1,
        bossLife = -1,
        lastSiphonTick = -999,
        lastSiphonCheckTick = -1,

        -- Last boss animation we saw, for edge detection. A mechanic fires when
        -- the animation CHANGES, not while it is merely playing — otherwise a
        -- long animation re-triggers as soon as the suppression window expires,
        -- which is what made Escape and Surge go off twice per cast.
        lastSeenAnim = -1,

        -- Rolling history for the debug panel
        history = {},
        count = 0,

        -- Per-kill review. See noteMechanicSeen / fightReview.
        review = {
            seen = {}, -- [name] = times the animation started
            answered = {}, -- [name] = times we actually began a response
            damageTaken = 0, -- total HP lost across the fight
            biggestHit = 0, -- largest single drop, and what was playing
            biggestHitAnim = "none",
            lastHp = -1,
            lowestHp = -1,
            lastSampleTick = -1, -- so HP is sampled once per tick, not per call

            -- Highest boss HP seen this fight, as the denominator for the GUI's
            -- health bar. Self-calibrating on purpose: Raksha's true max is
            -- listed as unconfirmed in Constants.PENDING, and watching the
            -- actual reads is more honest than hardcoding a number from the
            -- wiki that might be wrong.
            bossMaxSeen = 0
        }
    }

    return self
end

--- @param message string
function Mechanics:log(message)
    if self.debug then Utils:log("[MECH] " .. message, "debug") end
end

------------------------------------------
-- # FIGHT REVIEW (telemetry)
------------------------------------------

--- Records that a mechanic's animation STARTED, whether or not we responded.
---
--- This is the honest version of "learn from our mistakes". A genuinely adaptive
--- system is the wrong tool for this fight: kills are short, the sample size per
--- session is tiny, and a wrong adaptation is fatal rather than merely slow —
--- you cannot A/B test a mechanic that one-shots you. What actually improves the
--- script is MEASUREMENT, because the numbers we're guessing at are knowable.
---
--- So we count two things per fight: how many times each mechanic's animation
--- fired, and how many times we actually began a response. The gap between them
--- is the miss rate, and it is the single most useful number here — a mechanic
--- showing seen=4 answered=2 is telling you exactly where the damage came from,
--- which is not something you can see by watching.
---
--- Constants.PRAYER_FLICKER already admits its delay/duration values are
--- "starting estimates, not measured values". This is how they stop being
--- guesses.
--- @param name string
function Mechanics:noteMechanicSeen(name)
    if not name then return end
    local seen = self.state.review.seen
    seen[name] = (seen[name] or 0) + 1
end

--- Samples player HP and attributes any drop to whatever Raksha was doing.
--- Called once per game tick from update(); the per-tick gate matters because
--- update() runs 12-20 times a tick and we'd otherwise count each drop repeatedly.
--- @param animName string
function Mechanics:sampleHealth(animName)
    local review = self.state.review
    local hp = Player:getHP()
    if hp <= 0 then return end -- dead or unreadable; don't attribute a "hit"

    if review.lastHp < 0 then
        review.lastHp = hp
        review.lowestHp = hp
        return
    end

    local drop = review.lastHp - hp
    if drop > 0 then
        review.damageTaken = review.damageTaken + drop
        if drop > review.biggestHit then
            review.biggestHit = drop
            review.biggestHitAnim = animName or "unknown"
        end
    end

    if hp < review.lowestHp then review.lowestHp = hp end
    review.lastHp = hp
end

--- Live snapshot of the review counters, for the GUI dashboard.
---
--- Separate from fightReview() because that formats strings for the kill log,
--- whereas the dashboard wants raw numbers it can colour and lay out itself.
--- @return table {damageTaken, biggestHit, biggestHitAnim, lowestHp, seen, answered, missed, bossMaxSeen}
function Mechanics:reviewSnapshot()
    local review = self.state.review

    local seen, answered = 0, 0
    for _, count in pairs(review.seen) do seen = seen + count end
    for _, count in pairs(review.answered) do answered = answered + count end

    return {
        damageTaken = review.damageTaken or 0,
        biggestHit = review.biggestHit or 0,
        biggestHitAnim = review.biggestHitAnim or "none",
        lowestHp = review.lowestHp or -1,
        seen = seen,
        answered = answered,
        missed = math.max(0, seen - answered),
        bossMaxSeen = review.bossMaxSeen or 0
    }
end

--- Human-readable summary of the fight just finished, for the kill log.
--- @return string[]
function Mechanics:fightReview()
    local review = self.state.review
    local lines = {
        string.format("damage taken %d (lowest hp %d, biggest hit %d during %s)",
                      review.damageTaken, review.lowestHp, review.biggestHit,
                      review.biggestHitAnim)
    }

    -- Sorted so the log is stable between kills and easy to eyeball.
    local names = {}
    for name in pairs(review.seen) do names[#names + 1] = name end
    table.sort(names)

    for _, name in ipairs(names) do
        local seen = review.seen[name] or 0
        local answered = review.answered[name] or 0
        local missed = seen - answered
        lines[#lines + 1] = string.format("%-32s seen %2d  answered %2d%s", name,
                                          seen, answered,
                                          missed > 0 and
                                              string.format("  MISSED %d", missed) or
                                              "")
    end
    return lines
end

-- Object types to sweep when we don't fully trust an entity's type. This client
-- does not always categorise "NPCs" as type 1 (the boss happens to be type 1,
-- but the adds may not be), so presence detection searches every common type
-- rather than guessing a single one. Includes 4 for ground-marker objects.
local FIND_TYPES = {0, 1, 2, 3, 4, 5, 8, 12}

-- Abilities to spend on the anima pools, best first, and the ONLY things cast
-- while we're on them — the phase rotation is held for the whole clear (see
-- Mechanics:rotationOnHold), so this list is the pool fight in its entirety.
--
-- Ordered by how much of the CLUSTER each one hits, not by single-target
-- damage. PVME's phase 3 line is "Threads of fate + target pools -> Soul sap",
-- so Threads of Fate leads: it hits the target and two more pools at once,
-- which is the difference between clearing a sweep of eight and killing eight
-- things one after another.
--
-- Volley of Souls is deliberately absent. It's the biggest thing 5 souls can
-- buy and the guide spends it on Raksha immediately after the pools ("target
-- Raksha + Volley of souls"), so dumping it into a pool costs more than it
-- clears.
local POOL_DPS_ABILITIES = {
    "Threads of Fate", -- hits the target plus two more of the cluster
    "Bloat", -- spreads across the cluster as they die
    "Blood Siphon", -- hits the cluster and heals per pool
    "Soul Sap", -- builds the souls the guide spends on Raksha next
    "Touch of Death", "Basic<nbsp>Attack"
}

-- How close two pools have to be to count as one cluster when choosing which to
-- attack. Threads of Fate splashes to nearby targets, so among pools that are
-- about equally close we lead on the one with the most neighbours inside this
-- radius — killing three at a time instead of one.
--
-- Density is now the TIEBREAK, not the primary sort. See pickPoolTarget.
local POOL_CLUSTER_RADIUS = 3

-- How much closer one pool has to be than another before distance decides on its
-- own. Inside this band the two count as equally close and the denser cluster
-- wins; outside it, the nearer pool always wins.
--
-- This is what stops us walking past pools at our feet to reach a knot across
-- the arena, which is exactly what the old density-first ordering did.
local POOL_DISTANCE_TIE = 1.0

-- Abilities to spend on the Shadow manifestation, best first, once it has been
-- stunned. Same contract as POOL_DPS_ABILITIES: while it's up the phase
-- rotation is held, so this list is all the damage it takes.
local MANIFESTATION_DPS_ABILITIES = {
    "Touch of Death", "Soul Sap", "Basic<nbsp>Attack"
}

-- update() runs every main-loop iteration (~30-50ms), which is 12-20 times per
-- 600ms game tick. Without pacing we fire abilities and interactions that many
-- times a tick — each click cancelling the last, which drops damage and makes
-- interactions look sluggish. These are the minimum GAME TICKS between actions.
local GCD_TICKS = 3 -- global cooldown between ability casts
local INTERACT_TICKS = 1 -- one clean interaction per tick

-- Watchdog only. We normally click a pool ONCE and let the attack run until it
-- dies, so this is not a retarget cadence — it exists purely so a click that
-- silently failed can't leave us standing next to a pool we think we're already
-- attacking. Long enough that the periodic re-assert almost never cancels a
-- real attack.
local POOL_RECLICK_TICKS = 5

-- The same watchdog for the Shadow manifestation. There is only ever one, so
-- this exists purely so a click that silently failed can't leave us standing
-- next to something we think we're already attacking.
local MANIFEST_RECLICK_TICKS = 5

-- Ticks to wait between clicking a pool and surging at it, so the character has
-- actually finished turning to face it first. Surge follows facing, not the
-- target, so surging on the same tick as the click sends us in whatever
-- direction we were already pointed.
local POOL_SURGE_FACE_TICKS = 2

-- Minimum ticks between two surges toward a pool. The ability bar's cooldown is
-- not enough on its own: it doesn't refresh within the tick, and this handler
-- runs a dozen-plus times per tick, so without this we'd fire the same Surge
-- repeatedly and end up across the arena.
local POOL_SURGE_REPEAT_TICKS = 5

-- Expel is the exception to the one-per-tick rule: Mind Flay orbs dispel on
-- click instead of resolving like an attack, so clicks don't cancel each other
-- and speed is everything (four orbs, ~600 damage each per tick, immobilised).
-- Now that we round-robin instead of hammering one orb, the interval sets how
-- fast we get all the way round rather than how fast one orb dies. At 90ms four
-- orbs each take a click inside ~360ms — comfortably under a single game tick.
local EXPEL_INTERVAL_MS = 90

--- Finds all instances of an id across every common object type — robust to the
--- exact `type` in constants being wrong, which is the usual reason a presence
--- mechanic "never fires".
--- @param id number
--- @param range number
--- @return AllObject[]
function Mechanics:findAnyType(id, range)
    return API.GetAllObjArray1({id}, range or 30, FIND_TYPES) or {}
end

--- Builds an axis-aligned hazard box centred on a tile.
--- @param x number
--- @param y number
--- @param half number Half the footprint width in tiles
--- @param clearance number Tiles of margin required outside the box
--- @return table
local function hazardBox(x, y, half, clearance)
    return {
        minX = x - half,
        maxX = x + half,
        minY = y - half,
        maxY = y + half,
        clearance = clearance
    }
end

--- Clearance an escape tile must have from a hazard.
---
--- Crucially this is never less than the hazard's TRIGGER radius: if we dodge at
--- 4 tiles but only require 2 tiles of clearance at the destination, we arrive
--- somewhere that still counts as dangerous, re-trigger immediately, pick a new
--- tile, and never settle or attack — an oscillation that just burns food.
--- @param safeRange number|nil
--- @param triggerRange number|nil
--- @return number
local function escapeClearance(safeRange, triggerRange)
    return math.max(safeRange or 2, (triggerRange or 4) + 1)
end

--- Distance from a tile to the EDGE of a hazard box (0 when inside it).
--- @param px number
--- @param py number
--- @param h table
--- @return number
local function distanceToHazard(px, py, h)
    local dx = math.max(h.minX - px, 0, px - h.maxX)
    local dy = math.max(h.minY - py, 0, py - h.maxY)
    return math.sqrt(dx * dx + dy * dy)
end

-- How long a shadow stays in the cache after we stop detecting it. Long enough
-- to ride out a scan flicker, short enough that a genuinely despawned shadow
-- frees the ground again quickly.
local SHADOW_LINGER_TICKS = 3

--- Floor shadows as 4x4 hazard BOXES, cached across ticks.
---
--- Modelling a 4x4 as a single point meant tiles we judged "safe" could still be
--- inside the shadow, so we walked back into it. Boxes fix the geometry; the
--- cache stops a detection flicker from making us dart back and forth. Entries
--- are dropped once they've gone unseen for SHADOW_LINGER_TICKS, which is what
--- lets us walk back over ground where a shadow has genuinely despawned.
--- @return table[]
function Mechanics:getShadowTiles()
    local sf = Constants.SHADOW_FLOOR
    local tick = API.Get_tick()
    local half = math.floor((sf.size or 4) / 2)

    -- Clamped: the box already covers the footprint, so these are small margins
    -- around it. A larger value (e.g. a saved config from before the box model)
    -- turns every shadow into a huge exclusion zone and we shuffle constantly
    -- instead of attacking.
    local clearance = math.min(escapeClearance(sf.safeRange, sf.triggerRange), 3)

    for _, s in ipairs(API.GetAllObjArray1(sf.ids, 30, {sf.type}) or {}) do
        local tile = s.Tile_XYZ
        if tile then
            local x, y = math.floor(tile.x), math.floor(tile.y)
            self.state.shadowCache[x .. ":" .. y] = {x = x, y = y, seen = tick}
        end
    end

    local out = {}
    for key, entry in pairs(self.state.shadowCache) do
        if (tick - entry.seen) > SHADOW_LINGER_TICKS then
            self.state.shadowCache[key] = nil -- despawned: ground is free again
        else
            out[#out + 1] = hazardBox(entry.x, entry.y, half, clearance)
        end
    end
    return out
end

--- The LETHAL ground only: floor shadows and the 2789 insta-kill highlights.
--- Standing in either is an instant death, so these are the hazards no movement
--- may ever ignore, however urgent it is.
---
--- Split out from getAllHazardTiles because "never land here or you die" and
--- "prefer not to stand here" were being treated as the same thing, and that
--- silently disabled the pool clear's Dive. The full list includes a box around
--- every anima pool, so validating a dive ONTO a pool against it asked whether
--- the pool's own tile was clear of the pool — distance 0 against a clearance of
--- 2, false every time. Every approach fell back to walking, and with
--- diveDistance at 8 that is most of a sweep spent crossing the arena on foot.
--- @return table[]
function Mechanics:getLethalHazardTiles()
    local hazards = self:getShadowTiles()

    local ik = Constants.INSTAKILL
    for _, mark in ipairs(self:findAnyType(ik.id, 25)) do
        local tile = mark.Tile_XYZ
        if tile then
            hazards[#hazards + 1] = hazardBox(tile.x, tile.y, 0,
                                          escapeClearance(ik.safeRange,
                                                          ik.triggerRange))
        end
    end

    return hazards
end

--- Every area we must never move into, as hazard boxes: the lethal ground above,
--- plus the anima pools, the ground bombs and (in phase 4) Raksha's own blocked
--- footprint. Used to validate a movement destination in the general case.
--- @return table[]
function Mechanics:getAllHazardTiles()
    local hazards = self:getLethalHazardTiles()

    -- Phase 4: Raksha is a blocked 5x5 that can't be walked through, so his
    -- footprint is a pathing hazard. Clearance is deliberately TINY — we want to
    -- stand right against him to force tail sweeps instead of shadow bombs, so
    -- this only stops us pathing into him, it doesn't push us away.
    if self.state.phase >= 4 and self.state.arenaCenterBoss then
        local p4 = Constants.PHASE4
        local c = self.state.arenaCenterBoss
        hazards[#hazards + 1] = hazardBox(c.x, c.y, p4.bossFootprint or 2,
                                          p4.bossClearance or 1)
    end

    -- Anima pools burn ~1500 per tick if we stand in one. We move toward them to
    -- kill them, so without this we walk straight into the damage.
    local pool = Constants.ADDS.ANIMA_POOL
    for _, p in ipairs(self:findAnyType(pool.id, 25)) do
        local tile = p.Tile_XYZ
        if tile then
            hazards[#hazards + 1] = hazardBox(tile.x, tile.y, 0,
                                              pool.avoidClearance or 2)
        end
    end

    -- Bombs are 2x2, so they get a footprint too rather than being points.
    local bomb = Constants.OBJECTS.BOMB_HAZARD
    local bombsDef = Constants.MECHANICS[Constants.ANIM.BOMBS]
    local bombClearance = (bombsDef and bombsDef.escapeDistance) or 5
    local bombHalf = math.floor((bomb.size or 2) / 2)
    for _, b in ipairs(Utils:findAll(bomb.id, bomb.type, 20)) do
        local tile = b.Tile_XYZ
        if tile then
            hazards[#hazards + 1] = hazardBox(tile.x, tile.y, bombHalf,
                                              bombClearance)
        end
    end

    return hazards
end

--- True if a tile clears every hazard box by that hazard's own clearance.
--- @param x number
--- @param y number
--- @param hazards table[]
--- @return boolean
local function tileIsClear(x, y, hazards)
    for _, h in ipairs(hazards) do
        if distanceToHazard(x, y, h) < h.clearance then return false end
    end
    return true
end

------------------------------------------
-- # PATH SAFETY
------------------------------------------

--- Margin used when judging a tile we merely CROSS, as opposed to one we intend
--- to stand on.
---
--- Standing wants each hazard's full clearance. Crossing only needs to keep us
--- out of the lethal footprint itself — insisting on full clearance for every
--- tile of a route would reject nearly every escape in an arena this tight.
local PATH_MARGIN = 1

--- True when a tile is at least `margin` from every hazard's footprint,
--- ignoring the hazards' own (larger) standing clearances.
--- @param x number
--- @param y number
--- @param hazards table[]
--- @param margin number
--- @return boolean
local function tileOutsideHazards(x, y, hazards, margin)
    for _, h in ipairs(hazards) do
        if distanceToHazard(x, y, h) < margin then return false end
    end
    return true
end

--- How many tiles along the straight line from (x0,y0) to (x1,y1) sit inside a
--- hazard. Zero means the route is genuinely safe to walk.
---
--- THIS IS THE FIX FOR THE WHOLE PROBLEM. Every movement decision used to check
--- only the DESTINATION, then hand the tile to API.DoAction_WalkerW and hope.
--- The client paths around BLOCKED tiles, but a shadow floor isn't blocked —
--- it's ordinary ground that happens to kill you — so a walk to a perfectly safe
--- tile on the far side of a shadow strolls straight through the middle of it.
--- That is why the dodging looked so bad, and why we kept "running back through
--- it" on the way home.
---
--- A COUNT rather than a boolean on purpose: when we're already standing in a
--- shadow every route starts off unsafe, so a yes/no test would reject them all.
--- Ranking by cost instead gives us "the way out that spends least time in the
--- fire", which is exactly the right behaviour in that case.
--- @param x0 number
--- @param y0 number
--- @param x1 number
--- @param y1 number
--- @param hazards table[]
--- @param margin? number Defaults to PATH_MARGIN
--- @return number cost Number of unsafe tiles crossed
local function pathHazardCost(x0, y0, x1, y1, hazards, margin)
    margin = margin or PATH_MARGIN
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy))
    if steps == 0 then return 0 end

    local cost = 0
    -- Starts at 1: the tile we're already standing on is not a choice, and
    -- counting it would penalise every option equally anyway.
    for i = 1, steps do
        local t = i / steps
        local px = math.floor(x0 + dx * t + 0.5)
        local py = math.floor(y0 + dy * t + 0.5)
        if not tileOutsideHazards(px, py, hazards, margin) then
            cost = cost + 1
        end
    end
    return cost
end

------------------------------------------
-- # ORBIT (phase 4 movement)
------------------------------------------

-- Phase 4 movement is ORBITAL: we hold a ring of tiles around Raksha and only
-- ever travel along it, never across the middle. Two reasons:
--
--   1. It is the cheapest way to guarantee we don't path through a shadow.
--      Consecutive ring tiles are adjacent, so a short hop's straight-line path
--      IS the arc — there's nothing in between to cut through.
--   2. It keeps us at a constant distance from Raksha, which phase 4 needs
--      anyway: drift out and he swaps tail sweeps for shadow bombs.
--
-- 16 slots at radius 4-5 is roughly one tile of arc per slot: fine enough to
-- hug the ring, coarse enough that we aren't re-issuing a walk every tick.
local ORBIT_SLOTS = 16

-- Never issue a walk more than this many slots ahead. A short hop tracks the
-- arc; a long one cuts the chord straight across the middle, which is the exact
-- thing we're avoiding. Longer journeys still happen, just re-issued in arcs as
-- we travel.
local ORBIT_STEP_SLOTS = 2

-- Phase 4 walk-back tuning. See Mechanics:returnToPhase4Home.
--
-- Beyond HOME_HURRY_DISTANCE we are out of position badly enough to re-issue the
-- walk every tick instead of pacing it — which is what an Escape leaves us. At
-- or inside it we're close enough that the normal pacing avoids twitching
-- between adjacent tiles.
local HOME_HURRY_DISTANCE = 3

-- Past this, walking back is slow enough to be worth a Dive. Set below Dive's
-- ~10 tile reach so a dive that lands short still covers most of the gap, and
-- above HOME_HURRY_DISTANCE so short corrections never burn the cooldown.
local HOME_DIVE_DISTANCE = 6

-- Error range handed to API.DoAction_Surge_Tile when escaping a tail sweep: how
-- far off the requested tile the surge may land and still be worth taking. Surge
-- travels a fixed distance, so demanding an exact tile would reject nearly every
-- useful surge; two tiles of slack still lands us outside the 7x7.
local SWEEP_SURGE_ERROR = 2

--- Ring offsets in a fixed rotational order, cached per radius.
---
--- Built with cos/sin once at first use. Slots are matched to tiles by DISTANCE
--- rather than by angle, deliberately: the two-argument form of math.atan (and
--- whether math.atan2 exists at all) varies between Lua versions, and nothing
--- here needs an angle.
local ringCache = {}

--- @param radius number
--- @return table[]
local function orbitRing(radius)
    if ringCache[radius] then return ringCache[radius] end

    local ring = {}
    for i = 0, ORBIT_SLOTS - 1 do
        local angle = (i / ORBIT_SLOTS) * 2 * math.pi
        ring[i + 1] = {
            dx = math.floor(radius * math.cos(angle) + 0.5),
            dy = math.floor(radius * math.sin(angle) + 0.5)
        }
    end
    ringCache[radius] = ring
    return ring
end

--- Steps and direction from slot `a` to slot `b` the short way round.
--- @param a number
--- @param b number
--- @return number steps, number direction (+1 or -1)
local function ringDelta(a, b)
    local diff = (b - a) % ORBIT_SLOTS
    if diff <= ORBIT_SLOTS / 2 then return diff, 1 end
    return ORBIT_SLOTS - diff, -1
end

--- Dive is only usable when off cooldown — same check core/wars_retreat.lua uses.
--- @return boolean
function Mechanics:canDive()
    return Utils:canUseAbility("Dive") or Utils:canUseAbility("Bladed Dive")
end

--- Dives to a tile, preferring plain Dive over Bladed Dive.
--- @param tile WPOINT
--- @return boolean
function Mechanics:diveToTile(tile)
    if Utils:canUseAbility("Dive") then
        return API.DoAction_Dive_Tile(tile) and true or false
    end
    if Utils:canUseAbility("Bladed Dive") then
        return API.DoAction_BDive_Tile(tile) and true or false
    end
    return false
end

--- True while we are off Raksha killing something else, and the phase rotation
--- must therefore be held.
---
--- The phase rotations are written against the boss — Death Skulls, Volley of
--- Souls, the specs, the phase 4 switches. Firing them at an anima pool or a
--- manifestation both wastes them and walks the rotation index forward, so a
--- clear that takes eight seconds used to cost us three or four steps of the
--- phase as well as the damage. Everything we do to an add is cast from this
--- module's own lists instead (POOL_DPS_ABILITIES,
--- MANIFESTATION_DPS_ABILITIES), and the rotation resumes on the same step once
--- the target comes back.
--- @return boolean
function Mechanics:rotationOnHold()
    return self.state.poolsActive or self.state.manifestationActive or
               self.state.addsActive
end

--- True from the moment the phase 3 rotation casts "Threads of Fate + target
--- pools" until the last pool is dead. While this holds, the pool clear owns our
--- movement outright and the bomb dodge is suppressed (see runActive).
---
--- Deliberately checks the REQUEST as well as the latch, and that second half is
--- load-bearing. Mechanics:begin() resets poolsActive to false, and the BOMBS
--- definition re-arms every couple of ticks for the whole bomb phase (duration
--- 20, retriggerAfter 3) — so during exactly the window we care about, the latch
--- is being knocked down and rebuilt constantly. runActive runs BEFORE
--- handleAnimaPools in update(), so on any iteration where begin() had just
--- cleared the latch, a check on poolsActive alone would read false and let the
--- dodge run. poolClearRequested survives all of that: it is set once by the
--- rotation and cleared only when the pools are actually gone.
--- @return boolean
function Mechanics:poolClearInProgress()
    return self.state.poolsActive or self.state.poolClearRequested
end

--- True when Raksha is our current target. Escape teleports us away from what
--- we're attacking, so it only clears the sweep when we're on the boss.
---
--- Biased towards TRUE on purpose. The rotation keeps Raksha targeted, so "on
--- the boss" is the normal state — and the only times we're NOT are when this
--- module has deliberately pulled the target onto a pool/manifestation/add,
--- which we already track. An earlier version required a positive read from the
--- target API and fell through to false otherwise, so any unreadable or
--- differently-formatted target name meant Surge every single time.
--- @return boolean
function Mechanics:isTargetingBoss()
    -- Authoritative: our own handlers know when they've redirected the target.
    if self.state.poolsActive or self.state.manifestationActive or
        self.state.addsActive then
        return false
    end

    -- Positive confirmation from the game, when it's readable.
    if Player:isInteractingWith(Constants.BOSS.id) then return true end

    -- Note ReadTargetInfo99, not ReadTargetInfo — the latter isn't in this
    -- api.lua. Only a target explicitly named as something else counts against
    -- us; an empty/failed read must not flip us to Surge.
    local ok, target = pcall(API.ReadTargetInfo99, true)
    if ok and target and type(target.Target_Name) == "string" and
        target.Target_Name ~= "" then
        if target.Target_Name:find("Raksha", 1, true) then return true end
        self:log("target reads as '" .. target.Target_Name .. "'")
    end

    -- Unreadable or unrecognised: assume the boss and Escape.
    return true
end

------------------------------------------
-- # HOME TILES
------------------------------------------

--- How far we're willing to roam from the anchor, which differs by phase — the
--- phase 4 antechamber is its own arena.
--- @return number
function Mechanics:arenaRadius()
    if self.state.phase >= 4 then
        return Constants.PHASE4.arenaRadius or Constants.ARENA_RADIUS or 12
    end
    return Constants.ARENA_RADIUS or 12
end

--- Records the tile we set up on for this fight, plus its alternate. Called once
--- from the pre-fight safespot step; the arena is instanced so this has to be
--- captured live rather than hardcoded.
--- @param x number
--- @param y number
--- @param z number
function Mechanics:setHome(x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z or 0)
    self.state.homeTile = {x = x, y = y, z = z}
    self.state.homeAlt = {
        x = x + (Constants.HOME.alternateOffsetX or 8),
        y = y,
        z = z
    }
    self:log(string.format("home set (%d, %d), alternate (%d, %d)", x, y,
                           self.state.homeAlt.x, self.state.homeAlt.y))
end

--- Clears the home tiles between fights.
--- Clears everything that is specific to ONE kill, ready for the next trip.
---
--- The phase latch is the reason this exists. It only ever moves forward (see
--- setPhase), which is correct within a fight — but nothing was clearing it
--- between fights, so once a kill reached phase 4 the latch stayed at 4 for the
--- rest of the session. On every subsequent kill the loader saw phase 4 against a
--- freshly reset loadedPhase of 1 and loaded PHASE4_ROTATION immediately,
--- overwriting the pre-fight setup on the very first iteration. Phases 1-3 never
--- ran again after the first kill, and every `phase >= 4` gate — orbit movement,
--- the pool ignore, the luck ring — was active from the opening tick.
---
--- Presence latches and the shadow cache go too: they describe the arena we just
--- left, and the next instance is a fresh one.
function Mechanics:resetFight()
    self.state.phase = 1
    self.state.bossLife = -1

    self.state.activeAnim = nil
    self.state.activeDef = nil
    self.state.lastSeenAnim = -1
    self.state.lastFired = {}

    self.state.addsActive = false
    self.state.poolsActive = false
    self.state.poolTargetId = nil
    self.state.poolClearRequested = false
    self.state.lastPoolSurgeTick = -99
    self.state.manifestationActive = false
    self.state.manifestTargetId = nil
    self.state.instakillActive = false
    self.state.lethalTarget = nil
    self.state.sweepEscaped = false

    self.state.shadowCache = {}
    self.state.expelIndex = 0

    self.state.arenaCenter = nil
    self.state.arenaCenterBoss = nil
    self.state.lastHomeSlotLogged = nil

    self.state.lastSiphonTick = -999
    self.state.lastSiphonCheckTick = -1

    self.state.review = {
        seen = {},
        answered = {},
        damageTaken = 0,
        biggestHit = 0,
        biggestHitAnim = "none",
        lastHp = -1,
        lowestHp = -1,
        lastSampleTick = -1,
        bossMaxSeen = 0
    }

    self:clearHome()
    self:log("fight state reset")
end

function Mechanics:clearHome()
    self.state.homeTile = nil
    self.state.homeAlt = nil
end

--- The home tile we should currently be using: the primary unless something
--- lethal is sitting on it, in which case the alternate.
--- @return table|nil {x, y, z}
--- Logs the phase 4 home tile whenever the chosen ring slot changes.
---
--- Diagnostic, and specifically for the question this file cannot answer on its
--- own: whether Raksha's REPORTED tile (Tile_XYZ) is the centre of his blocked
--- 5x5 or a corner of it. Everything here assumes centre — homeOffsetX of 4 is
--- documented as "2 tiles off the edge" of a footprint spanning +/-2, which only
--- holds from the centre — but constants.lua flags the assumption as unverified,
--- and if it is actually a corner then the east slot lands off his south-east
--- corner instead, which is what "we are south of the boss" would look like.
---
--- Prints the boss tile, the home tile and the delta between them, so the answer
--- can be read off a real kill instead of inferred. Slot 1 is due east; the ring
--- runs anticlockwise in 22.5 degree steps, so 5 is north, 9 west, 13 south.
--- @param tile table The chosen home tile
--- @param cx number Boss reported x
--- @param cy number Boss reported y
--- @param eastSlot number The slot due east, for comparison
--- @private
function Mechanics:logHomeSlot(tile, cx, cy, eastSlot)
    if self.state.lastHomeSlotLogged == tile.slot then return end
    self.state.lastHomeSlotLogged = tile.slot

    self:log(string.format(
                 "phase 4 home: slot %d (east is %d) at (%d, %d); boss reports (%d, %d); delta (%+d, %+d)",
                 tile.slot, eastSlot, tile.x, tile.y, cx, cy, tile.x - cx,
                 tile.y - cy))
end

function Mechanics:getHome()
    -- Phase 4 is a different, smaller arena, so the tile we recorded pre-fight is
    -- meaningless there. We orbit Raksha instead, and home is the EAST slot on
    -- the ring — always, with no search for somewhere better.
    --
    -- It used to walk outward from east to the nearest hazard-free slot, up to
    -- half the ring away, which is how we ended up holding a spot south of him.
    -- That relocation was solving a problem twice over and losing the phase in
    -- the process:
    --
    --   * handleInstakill already runs at top priority and moves us off lethal
    --     ground wherever we are standing, so nothing needs home to dodge.
    --   * returnToPhase4Home already refuses to walk a fouled route: it checks
    --     tileIsClear on home and falls through to planOrbitMove, which routes
    --     around hazards on its own.
    --
    -- So the only thing redefining home achieved was moving the spot we hold —
    -- and phase 4 depends entirely on holding ONE tile east of him. Drift off it
    -- and he swaps the dodgeable tail sweep for shadow bombs, which is precisely
    -- the trade PHASE4 exists to avoid.
    --
    -- Expressed in ring slots on purpose, so this agrees exactly with the tiles
    -- returnHome and the lethal dodge actually steer for. When it was a separate
    -- list of hand-picked offsets the two could disagree, and we'd shuffle
    -- between a "home" that wasn't on the ring and a ring the dodge preferred.
    if self.state.phase >= 4 then
        local center = self.state.arenaCenterBoss
        if center then
            local d = Constants.PHASE4.homeOffsetX or 4
            local cx, cy = math.floor(center.x), math.floor(center.y)
            local eastSlot = self:orbitNearestSlot(cx + d, cy)

            local tile = self:orbitTileAt(eastSlot)
            if tile then
                tile.name = "orbit " .. tile.slot
                self:logHomeSlot(tile, cx, cy, eastSlot)
                return tile
            end
        end
    end

    local primary = self.state.homeTile
    if not primary then return nil end

    local hazards = self:getAllHazardTiles()
    if tileIsClear(primary.x, primary.y, hazards) then return primary end

    local alt = self.state.homeAlt
    if alt and tileIsClear(alt.x, alt.y, hazards) then return alt end

    -- Both compromised: hand back the primary and let the dodge handlers move us
    -- somewhere safe instead.
    return primary
end

--- Centre and radius of the phase 4 orbit: Raksha himself, at the home offset.
--- @return table|nil center, number radius
function Mechanics:orbitParams()
    local center = self.state.arenaCenterBoss
    if not center then return nil, 0 end
    return center, Constants.PHASE4.homeOffsetX or 4
end

--- World tile for a ring slot. Slot numbers wrap, so callers can freely pass
--- `current + 5` or `current - 3` without doing the modulo themselves.
--- @param slot number
--- @return table|nil {x, y, z, slot}
function Mechanics:orbitTileAt(slot)
    local center, radius = self:orbitParams()
    if not center then return nil end

    local ring = orbitRing(radius)
    local index = ((math.floor(slot) - 1) % ORBIT_SLOTS) + 1
    local offset = ring[index]
    return {
        x = math.floor(center.x) + offset.dx,
        y = math.floor(center.y) + offset.dy,
        z = math.floor(center.z or 0),
        slot = index
    }
end

--- The ring slot whose tile is closest to (x, y).
--- @param x number
--- @param y number
--- @return number slot
function Mechanics:orbitNearestSlot(x, y)
    local center, radius = self:orbitParams()
    if not center then return 1 end

    local ring = orbitRing(radius)
    local best, bestDistance = 1, math.huge
    for index, offset in ipairs(ring) do
        local dx = (math.floor(center.x) + offset.dx) - x
        local dy = (math.floor(center.y) + offset.dy) - y
        local distance = dx * dx + dy * dy -- squared: we only compare
        if distance < bestDistance then best, bestDistance = index, distance end
    end
    return best
end

--- Total hazard cost of travelling `steps` slots from `from` in `direction`.
--- @param from number
--- @param direction number +1 or -1
--- @param steps number
--- @param hazards table[]
--- @return number cost
function Mechanics:arcCost(from, direction, steps, hazards)
    local cost = 0
    for k = 1, steps do
        local tile = self:orbitTileAt(from + direction * k)
        if not tile then return math.huge end
        if not tileOutsideHazards(tile.x, tile.y, hazards, PATH_MARGIN) then
            cost = cost + 1
        end
    end
    return cost
end

--- Plans the next hop of an orbital move.
---
--- Two decisions, in order:
---   1. WHERE to end up — the slot nearest `preferredSlot` that we can actually
---      stand on (full clearance).
---   2. WHICH WAY ROUND to get there — the arc with the lower hazard cost,
---      shorter arc winning ties. This is what makes us walk the long way round
---      a shadow instead of straight through it, which is the entire point.
---
--- Returns only the NEXT hop, capped at ORBIT_STEP_SLOTS, not the destination:
--- re-issuing short hops keeps us on the arc, where one long walk would cut the
--- chord across the middle.
--- @param hazards table[]
--- @param preferredSlot number Slot we would rather end up on
--- @return table|nil hop Next tile to walk to, nil if we're already settled
--- @return table|nil target The eventual destination, for logging
function Mechanics:planOrbitMove(hazards, preferredSlot)
    local player = Player:getCoords()
    if not player or not self.state.arenaCenterBoss then return nil, nil end

    -- 1. Destination: search outward from the preferred slot, both ways.
    local target
    for offset = 0, math.floor(ORBIT_SLOTS / 2) do
        for _, direction in ipairs({1, -1}) do
            local tile = self:orbitTileAt(preferredSlot + direction * offset)
            if tile and tileIsClear(tile.x, tile.y, hazards) then
                target = tile
                break
            end
        end
        if target then break end
    end
    if not target then return nil, nil end -- every slot fouled

    local current = self:orbitNearestSlot(player.x, player.y)
    if target.slot == current then
        -- On the right slot already. Only nudge if we've drifted off the exact
        -- tile, and only when the short hop there is safe.
        local dx, dy = target.x - player.x, target.y - player.y
        if (dx * dx + dy * dy) <= 1 then return nil, target end
        if pathHazardCost(player.x, player.y, target.x, target.y, hazards) > 0 then
            return nil, target
        end
        return target, target
    end

    -- 2. Which way round.
    local steps, direction = ringDelta(current, target.slot)
    local cost = self:arcCost(current, direction, steps, hazards)

    local otherSteps = ORBIT_SLOTS - steps
    local otherCost = self:arcCost(current, -direction, otherSteps, hazards)
    if otherCost < cost then
        steps, direction, cost = otherSteps, -direction, otherCost
    end

    -- 3. One short hop along the chosen arc.
    local hop = self:orbitTileAt(current + direction * math.min(steps,
                                                                ORBIT_STEP_SLOTS))
    return hop, target
end

--- Walks to (x, y) without crossing a hazard.
---
--- Used everywhere outside the phase 4 orbit. If the direct line is clean we
--- take it; if it isn't, we walk to the best intermediate tile that IS reachable
--- cleanly and gets us closer, and repeat on later ticks. That's a greedy
--- waypoint rather than a real pathfinder, but it's enough to stop us strolling
--- through a shadow to reach a tile that happens to be safe on arrival.
---
--- `urgent` decides what happens when there is no clean route at all, and the
--- two callers genuinely want opposite things:
---   * Escaping (urgent): walk the dirty route anyway. We're standing in
---     something lethal, and no clean stepping stone exists precisely because
---     we're deep inside a 4x4 — crossing a tile of it beats staying put.
---   * Going home (not urgent): don't move. Nothing is hurting us, so waiting a
---     few ticks for the shadow to expire is strictly better than walking
---     through it, which is the whole behaviour we set out to remove.
--- @param x number
--- @param y number
--- @param hazards table[]
--- @param urgent? boolean Move even if every route is compromised
--- @return boolean walked
function Mechanics:walkAvoiding(x, y, hazards, urgent)
    local player = Player:getCoords()
    if not player then return false end
    local pz = math.floor(player.z or 0)

    if pathHazardCost(player.x, player.y, x, y, hazards) == 0 then
        ---@diagnostic disable-next-line: undefined-global
        API.DoAction_WalkerW(WPOINT.new(math.floor(x), math.floor(y), pz))
        return true
    end

    -- Direct route is fouled: find a stepping stone. Rank by how much closer to
    -- the destination it gets us, and only consider tiles we can reach cleanly
    -- and stand on safely.
    local best, bestScore = nil, math.huge
    local currentGap = math.sqrt((x - player.x) ^ 2 + (y - player.y) ^ 2)

    for dx = -8, 8 do
        for dy = -8, 8 do
            local tx, ty = math.floor(player.x + dx), math.floor(player.y + dy)
            local gap = math.sqrt((x - tx) ^ 2 + (y - ty) ^ 2)
            if gap < currentGap and gap < bestScore and
                tileIsClear(tx, ty, hazards) and
                pathHazardCost(player.x, player.y, tx, ty, hazards) == 0 then
                best, bestScore = {x = tx, y = ty}, gap
            end
        end
    end

    if not best then
        if not urgent then
            self:log("no clean route — holding rather than walking through")
            return false
        end
        self:log("no clean route, but standing here is lethal — going direct")
        ---@diagnostic disable-next-line: undefined-global
        API.DoAction_WalkerW(WPOINT.new(math.floor(x), math.floor(y), pz))
        return true
    end

    self:log(string.format("routing around hazard via (%d, %d)", best.x, best.y))
    ---@diagnostic disable-next-line: undefined-global
    API.DoAction_WalkerW(WPOINT.new(best.x, best.y, pz))
    return true
end

--- The live Shadow manifestation, if one is up. Used to bias the sweep escape
--- toward a tile that keeps us on the add.
--- @return table|nil
function Mechanics:liveManifestation()
    local sm = Constants.ADDS.SHADOW_MANIFESTATION
    for _, m in ipairs(self:findAnyType(sm.id, sm.range)) do
        if (m.Life or 0) > 0 and m.Tile_XYZ then return m end
    end
    return nil
end

--- Best tile to escape a tail sweep to: outside the 7x7, safe to stand on,
--- reachable without crossing something lethal, and — as a tie-break only — as
--- close to the Shadow manifestation as we can get so we keep DPSing it.
---
--- Getting out comes first and the add comes second, deliberately. The previous
--- version had it the other way round: it aimed at the manifestation and gave up
--- entirely if the add happened to be inside the sweep radius, which is exactly
--- when we most needed to move.
--- @param clearance number Tiles from Raksha the tile must be
--- @param hazards table[] Ground hazards, with the sweep already added
--- @return table|nil {x, y}
function Mechanics:pickSweepEscapeTile(clearance, hazards)
    local center = self.state.arenaCenterBoss
    local player = Player:getCoords()
    if not center or not player then return nil end

    local cx, cy = math.floor(center.x), math.floor(center.y)
    local arenaCenter = self.state.arenaCenter
    local arenaRadius = self:arenaRadius()

    -- Bias target: the add if there is one, otherwise our own tile, which makes
    -- the tie-break "move as little as possible".
    local add = self:liveManifestation()
    local bx = add and math.floor(add.Tile_XYZ.x) or math.floor(player.x)
    local by = add and math.floor(add.Tile_XYZ.y) or math.floor(player.y)

    local searchRadius = 12
    local best, bestCost, bestBias = nil, math.huge, math.huge

    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local tx = math.floor(player.x + dx)
            local ty = math.floor(player.y + dy)

            -- Must actually be out of the sweep.
            local ox, oy = tx - cx, ty - cy
            if math.sqrt(ox * ox + oy * oy) >= clearance then
                local inArena = true
                if arenaCenter then
                    local ax = tx - arenaCenter.x
                    local ay = ty - arenaCenter.y
                    inArena = math.sqrt(ax * ax + ay * ay) <= arenaRadius
                end

                if inArena and tileIsClear(tx, ty, hazards) then
                    local cost = pathHazardCost(player.x, player.y, tx, ty,
                                                hazards)
                    local ex, ey = tx - bx, ty - by
                    local bias = math.sqrt(ex * ex + ey * ey)

                    if cost < bestCost or
                        (cost == bestCost and bias < bestBias) then
                        best, bestCost, bestBias = {x = tx, y = ty}, cost, bias
                    end
                end
            end
        end
    end

    return best
end

--- Gets us out of Raksha's 7x7 tail sweep when we are NOT targeting him.
---
--- This is the whole answer to "we keep eating the sweep while killing the add",
--- and it replaces a dive-to-the-manifestation attempt that had six separate
--- ways to silently give up and fall back to walking. Now there is one job —
--- reach a safe tile outside the 7x7 — and three ways to do it, tried in order
--- of how fast they are:
---
---   1. Dive to the tile. Instant, and it lands where we aimed.
---   2. Surge to the tile, via DoAction_Surge_Tile. Also instant, separate
---      cooldown from Dive, and being TILE-TARGETED is what makes it usable
---      here — a bare Surge follows our facing, which while we're turned toward
---      an add is as likely to carry us across the sweep as out of it.
---   3. Walk, urgently. Slow, but it goes the right way.
---
--- Escape is deliberately absent: it moves away from our TARGET, and our target
--- is the add rather than Raksha, so it can just as easily throw us deeper in.
---
--- Every bail-out logs its reason. The previous version failed silently, which
--- is why "it still isn't dodging" was impossible to tell apart from "it tried
--- and the dive was on cooldown".
--- @param clearance number Tiles from Raksha we need to be
--- @return boolean consumed True if we spent the tick's action
function Mechanics:escapeSweep(clearance)
    local center = self.state.arenaCenterBoss
    local player = Player:getCoords()
    if not center or not player then return false end

    -- Already clear of it.
    local dx, dy = player.x - center.x, player.y - center.y
    if math.sqrt(dx * dx + dy * dy) >= clearance then return false end

    -- The sweep radius goes in as a hazard on top of the real ground hazards,
    -- so neither the tile search nor the walk can hand back somewhere still
    -- inside it — or route us out through a floor shadow.
    local hazards = self:getAllHazardTiles()
    hazards[#hazards + 1] = hazardBox(center.x, center.y, 0, clearance)

    local target = self:pickSweepEscapeTile(clearance, hazards)
    if not target then
        self:log("tail sweep: no safe tile outside the 7x7 — walking clear")
        self:walkClearOfBoss(clearance)
        return false -- walking costs no global cooldown
    end

    local z = math.floor(player.z or 0)

    -- 1. Dive.
    if self:canDive() then
        ---@diagnostic disable-next-line: undefined-global
        if self:diveToTile(WPOINT.new(target.x, target.y, z)) then
            self:log(string.format("tail sweep: DIVED clear to (%d, %d)",
                                   target.x, target.y))
            return true
        end
        self:log(string.format("tail sweep: dive to (%d, %d) was rejected",
                               target.x, target.y))
    end

    -- 2. Tile-targeted Surge.
    if Utils:canUseAbility("Surge") then
        ---@diagnostic disable-next-line: undefined-global
        local dest = WPOINT.new(target.x, target.y, z)
        if API.DoAction_Surge_Tile(dest, SWEEP_SURGE_ERROR) then
            self:log(string.format("tail sweep: SURGED clear to (%d, %d)",
                                   target.x, target.y))
            return true
        end
        self:log("tail sweep: surge to tile was rejected")
    end

    -- 3. Walk. Urgent, so a compromised route still beats standing in the 7x7.
    self:log(string.format(
                 "tail sweep: no Dive or Surge available — walking to (%d, %d)",
                 target.x, target.y))
    self:walkAvoiding(target.x, target.y, hazards, true)
    return false
end

--- The two animations that mean "a 7x7 is about to land on Raksha's tile".
local SWEEP_ANIMS = {
    [Constants.ANIM.TAIL_SWEEP_ESCAPE] = true,
    [Constants.ANIM.TAIL_SWEEP_FREEDOM] = true
}

--- Tiles of clearance a sweep escape aims for, which differs by phase.
---
--- Phase 4 goes two further: we take the sweep from melee range there, so the
--- hop is short and a shortfall leaves us inside it. See
--- Constants.TAIL_SWEEP_CLEARANCE_P4.
---
--- Every phase 4 escape route has to agree on this number — the dive/surge
--- target, the walking retreat and the "we are clear now, stop moving" latch
--- alike. If the latch wanted more distance than the retreat delivers we would
--- never satisfy it and would shuffle in and out for the whole animation.
--- @return number
function Mechanics:sweepClearance()
    if self.state.phase >= 4 then
        return Constants.TAIL_SWEEP_CLEARANCE_P4 or
                   Constants.TAIL_SWEEP_CLEARANCE
    end
    return Constants.TAIL_SWEEP_CLEARANCE
end

--- Whether we are outside Raksha's tail sweep radius.
--- @return boolean
function Mechanics:clearOfSweepRadius()
    local center = self.state.arenaCenterBoss
    local player = Player:getCoords()
    if not center or not player then return false end

    local dx, dy = player.x - center.x, player.y - center.y
    return math.sqrt(dx * dx + dy * dy) >= self:sweepClearance()
end

--- Last line of defence for the tail sweep: a sweep is playing, we are still
--- inside the 7x7, and no sweep response is running. Get out anyway.
---
--- This deliberately sits OUTSIDE the mechanic-registration contest, and that is
--- the whole point of it. Registration is priority-ranked and a live mechanic
--- refuses anything that does not outrank it:
---
---     local outranks = (active == nil) or
---                          ((definition.priority or 0) >= (active.priority or 0))
---
--- In phase 4 the detonation dome is priority 95 against the sweep's 60, and it
--- is `sustained` for a FIXED 30 ticks — it finishes on `elapsed >= duration`,
--- not when the dome animation stops. So for eighteen seconds at a stretch every
--- tail sweep was refused registration outright: begin() was never called, no
--- sequence existed, and neither the Escape step nor its retreat fallback ever
--- got the chance to run.
---
--- That is why this reads as a phase 4 dodging problem when the detection is
--- fine. burnDome returns false, so the rotation kept firing throughout — we
--- were attacking normally and simply never moving.
---
--- Phases 1-3 never hit it because they have no dome. Their top-priority
--- responses are the bombardment and bind sequences, which finish in a few ticks
--- and hand the slot straight back.
--- @param boss table
--- @return boolean consumed True if we spent the tick's action getting clear
function Mechanics:ensureClearOfSweep(boss)
    if not boss.found or not SWEEP_ANIMS[boss.anim] then
        -- Sweep over. Re-arm for the next one.
        self.state.sweepEscaped = false
        return false
    end

    -- ONE escape per sweep, then hold position.
    --
    -- The animation plays on for several ticks after the hit has resolved, and
    -- this function runs every loop iteration — so without the latch we spent
    -- all of those ticks fighting returnHome. It walked us onto the home tile at
    -- four tiles out, we read four as "inside the 7x7" and shoved us back to
    -- seven, returnHome walked us in again, and round it went. That is the
    -- back-and-forth shuffle.
    --
    -- Once we have got clear the sweep cannot touch us, so from here we stop
    -- moving and let returnHome put us on the tile and LEAVE us there.
    if self.state.sweepEscaped then return false end

    -- Outside the radius already — nothing to do but remember that we are.
    if self:clearOfSweepRadius() then
        self.state.sweepEscaped = true
        return false
    end

    -- Defer to a registered sweep response ONLY while its mover can genuinely
    -- fire. Escape teleports us out in one action and leaves us at melee range,
    -- so it is worth a tick's wait — but only if it is actually coming.
    --
    -- THE GLOBAL COOLDOWN IS WHY THIS MATTERS. Every rotation ability puts one
    -- on us for around three ticks, and canUseAbility reads `enabled`, which the
    -- cooldown clears for the whole bar at once — Escape, Surge and Dive alike.
    -- So the sequence would reach its movement step mid-cooldown, log "not
    -- available", mark the step done and walk on to the reattack. We stood in
    -- the 7x7 waiting on an ability that was never going to come, and the more
    -- the rotation was firing the more reliably it happened.
    --
    -- WALKING is not on the global cooldown. That is the whole point: whatever
    -- the ability bar is doing, we can always walk out, and escapeSweep's last
    -- tier is a plain hazard-avoiding walk.
    local active = self.state.activeDef
    if active and SWEEP_ANIMS[self.state.activeAnim] then
        local mover = active.sweepMover
        if mover and self:isTargetingBoss() and Utils:canUseAbility(mover) then
            return false
        end
    end

    -- escapeSweep returns immediately when we are already outside the radius, so
    -- running this on every tick of every sweep costs nothing.
    return self:escapeSweep(self:sweepClearance())
end

--- Backs straight away from Raksha by `tiles`, for when a sweep answer's
--- movement ability is on cooldown.
---
--- Deliberately dumber than escapeSweep(): no tile search, no hazard routing,
--- no ability. Just step back along the line we're already standing on. That is
--- what makes it usable as a fallback — it cannot fail to find a tile, and it
--- cannot spend a global cooldown we may need for the rotation.
---
--- Direction comes from where we stand relative to him rather than a hardcoded
--- compass point. In phase 4 that resolves to due EAST, because the phase holds
--- a tile east of him and we are backing further out the same way. Deriving it
--- means a retreat from anywhere else still goes away from him rather than
--- through him, which a fixed east would not.
--- @param tiles number Tiles to retreat
--- @return boolean consumed Always false — walking costs no global cooldown
function Mechanics:retreatFromBoss(tiles)
    local player = Player:getCoords()
    if not player then return false end

    local px, py = math.floor(player.x), math.floor(player.y)

    -- Default east, the side phase 4 holds, for the degenerate case where we
    -- have no boss reading or are somehow standing on his exact tile.
    local dx, dy = 1, 0

    local center = self.state.arenaCenterBoss
    if center then
        local ox, oy = px - center.x, py - center.y
        local length = math.sqrt(ox * ox + oy * oy)
        if length > 0.5 then dx, dy = ox / length, oy / length end
    end

    local tx = math.floor(px + dx * tiles + 0.5)
    local ty = math.floor(py + dy * tiles + 0.5)
    tx, ty = self:clampToArena(tx, ty)

    self:log(string.format("tail sweep: backing off %d tiles to (%d, %d)", tiles,
                           tx, ty))
    ---@diagnostic disable-next-line: undefined-global
    API.DoAction_WalkerW(WPOINT.new(tx, ty, math.floor(player.z or 0)))
    return false
end

--- Walks to the nearest hazard-clear tile at least `distance` tiles from Raksha.
---
--- This exists because Escape moves away from our TARGET and Surge follows our
--- facing — so when we're on an add or a pool rather than the boss, neither
--- reliably clears a 7x7 centred on Raksha. Walking is slower but it actually
--- goes the right way.
--- @param distance number Tiles of clearance needed from the boss
--- @return boolean moved
function Mechanics:walkClearOfBoss(distance)
    local center = self.state.arenaCenterBoss
    local player = Player:getCoords()
    if not center or not player then return false end

    -- Already clear
    local dx, dy = player.x - center.x, player.y - center.y
    if math.sqrt(dx * dx + dy * dy) >= distance then return false end

    -- Treat the sweep radius as a hazard for this search, on top of the real
    -- ground hazards, so we never dodge the sweep into something worse.
    local hazards = self:getAllHazardTiles()
    hazards[#hazards + 1] = hazardBox(center.x, center.y, 0, distance)

    local target = self:findLethalSafeTile(hazards)
    if not target then return false end

    -- Urgent: a tail sweep is landing, so a compromised route still beats
    -- standing in the 7x7.
    return self:walkAvoiding(target.x, target.y, hazards, true)
end

--- Phase 4 walk-back, and the one movement in the fight that has to be fast.
---
--- Escape throws us the better part of ten tiles off the spot we hold beside
--- Raksha, and every tick spent out there is a tick he can spend on shadow bombs
--- instead of the tail sweep we can actually dodge. Getting back was slow for
--- three compounding reasons, none of them the Escape itself: the walk was paced
--- at returnEveryTicks (3), each re-issue only hopped ORBIT_STEP_SLOTS (2) round
--- the ring, and it took the arc even when nothing was in the way. Closing an
--- eight tile gap therefore cost a dozen-odd ticks on a clear floor.
---
--- Three routes, best first:
---   1. Dive straight onto the tile when it's off cooldown and the tile is
---      clear. Instant, and the same trick the pool chase already uses.
---   2. Walk the straight line when nothing lethal sits on it. The arc exists to
---      route around floor shadows; with none in the way, going round is pure
---      delay.
---   3. Fall back to the orbit arc, which is still the only thing that reliably
---      gets us round a shadow rather than through it.
---
--- Pacing is by distance: re-issue every tick while we're genuinely out of
--- position, and only fall back to returnEveryTicks for the final settle, so we
--- aren't spamming one-tile nudges once we're basically home.
--- @param player table
--- @param tick number
--- @param hazards table[]
function Mechanics:returnToPhase4Home(player, tick, hazards)
    local home = self:getHome()
    if not home then return end

    local dx, dy = home.x - player.x, home.y - player.y
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance <= 1 then return end -- on it, near enough

    local pace = (distance > HOME_HURRY_DISTANCE) and 1 or
                     (Constants.HOME.returnEveryTicks or 3)
    if (tick - self.state.lastHomeMoveTick) < pace then return end

    local homeClear = tileIsClear(home.x, home.y, hazards)

    -- 1. Dive the long gap.
    if homeClear and distance > HOME_DIVE_DISTANCE and self:canDive() then
        self.state.lastHomeMoveTick = tick
        ---@diagnostic disable-next-line: undefined-global
        local dest = WPOINT.new(home.x, home.y, math.floor(player.z or 0))
        if self:diveToTile(dest) then
            self:log(string.format("phase 4: dived home, %.1f tiles out",
                                   distance))
            return
        end
    end

    -- 2. Straight line, when it's clean.
    if homeClear and
        pathHazardCost(player.x, player.y, home.x, home.y, hazards) == 0 then
        self.state.lastHomeMoveTick = tick
        ---@diagnostic disable-next-line: undefined-global
        --- Could add a delay here possibly
        API.DoAction_WalkerW(WPOINT.new(home.x, home.y, home.z))
        return
    end

    -- 3. Round the ring, avoiding whatever is in the way.
    local homeSlot = self:orbitNearestSlot(
                         math.floor(self.state.arenaCenterBoss.x) +
                             (Constants.PHASE4.homeOffsetX or 4),
                         math.floor(self.state.arenaCenterBoss.y))

    local hop = self:planOrbitMove(hazards, homeSlot)
    if hop then
        self.state.lastHomeMoveTick = tick
        ---@diagnostic disable-next-line: undefined-global
        API.DoAction_WalkerW(WPOINT.new(hop.x, hop.y, hop.z))
    end
end

--- Walks back toward home once we've drifted off it and nothing is threatening.
--- Movement costs no global cooldown, so the rotation keeps attacking through
--- it. This is what makes positioning repeatable between mechanics.
function Mechanics:returnHome()
    local player = Player:getCoords()
    if not player then return end

    local tick = API.Get_tick()
    local hazards = self:getAllHazardTiles()

    -- Phase 4 does its own pacing, because "how fast do we need to be back?"
    -- has a very different answer there — see returnToPhase4Home.
    if self.state.phase >= 4 and self.state.arenaCenterBoss then
        return self:returnToPhase4Home(player, tick, hazards)
    end

    if (tick - self.state.lastHomeMoveTick) <
        (Constants.HOME.returnEveryTicks or 3) then
        return
    end

    local home = self:getHome()
    if not home then return end

    local dx, dy = home.x - player.x, home.y - player.y
    if math.sqrt(dx * dx + dy * dy) <= (Constants.HOME.returnDistance or 5) then
        return -- close enough
    end

    -- Never walk back into something lethal, and never walk THROUGH something
    -- lethal to get there — walkAvoiding handles the second half, which the
    -- plain destination check here used to miss entirely.
    if not tileIsClear(home.x, home.y, hazards) then return end

    self.state.lastHomeMoveTick = tick
    self:walkAvoiding(home.x, home.y, hazards)
end

------------------------------------------
-- # PHASE TRACKING
------------------------------------------

--- Which of the four phases we're in, from Raksha's HP. Phase decides how hard
--- we chase pools: he doesn't siphon them at all in phase 1, but from phase 2 on
--- every pool he absorbs heals him 5,000 and stacks a damage buff, so they stop
--- being optional.
--- @param life number Boss HP, or -1 when unknown
--- @return number 1-4
function Mechanics:getPhase(life)
    if not life or life <= 0 then return self.state.phase or 1 end
    local hp = Constants.PHASE_HP
    if life > hp.P2 then return 1 end
    if life > hp.P3 then return 2 end
    if life > hp.P4 then return 3 end
    return 4
end

--- Forces the phase latch forward, for phases that cannot be inferred from HP.
---
--- Phase 4 is the case that needs this and it is not a nicety. getPhase reads HP,
--- but entering phase 4 HEALS Raksha back to 400k — which reads as phase 3 — so
--- the only window in which HP says "4" is the brief moment between him dropping
--- under 200k and the heal landing. Miss that window and the latch never reaches
--- 4 for the entire phase, because it only ever moves forward.
---
--- We do miss it, reliably: that window is exactly when the phase 4 transition
--- animation is playing, and handleFight holds through the transition without
--- calling update() at all. So HP alone can never latch phase 4 — the transition
--- completing has to do it.
--- @param phase number
function Mechanics:setPhase(phase)
    if phase > self.state.phase then
        self:log(string.format("PHASE %d (latched by event, boss %d hp)", phase,
                               self.state.bossLife or -1))
        self.state.phase = phase
    end
end

--- True shortly after Raksha announces he's pulling the pools in. That message
--- is the exact cue to drop everything and clear them, regardless of how many
--- are up.
---
--- Reads the chat through API.GatherEvents_chat_check, which returns an array of
--- recent events with a `text` field. It used to call API.ChatFind, and that has
--- been REMOVED from api.lua as of 1.077 — the call was wrapped in pcall, so
--- instead of erroring it just failed every single time and this function
--- silently returned false for the whole fight. The siphon cue was therefore
--- dead: pools only ever got cleared by the count threshold or by phase 3's
--- rotation step, never by Raksha announcing the siphon.
--- @return boolean
function Mechanics:siphonImminent()
    local tick = API.Get_tick()

    -- Only re-scan the chat once a tick; this runs 12-20 times per tick.
    if tick ~= self.state.lastSiphonCheckTick then
        self.state.lastSiphonCheckTick = tick

        local ok, events = pcall(API.GatherEvents_chat_check)
        if ok and type(events) == "table" then
            for _, event in ipairs(events) do
                -- Entries are {text = "..."} in every other caller in this
                -- codebase, but tolerate a bare string too.
                local text = (type(event) == "table" and event.text) or event
                if type(text) == "string" and
                    text:find(Constants.SIPHON_CHAT, 1, true) then
                    self:log("siphon announced: " .. text)
                    self.state.lastSiphonTick = tick
                    break
                end
            end
        end
    end

    return (tick - (self.state.lastSiphonTick or -999)) < 30
end

------------------------------------------
-- # BOSS READING
------------------------------------------

--- Current boss state. Returns found=false when Raksha is not loaded.
--- @return table
function Mechanics:getBoss()
    local found = Utils:findAll(Constants.BOSS.id, Constants.BOSS.type, 50)
    if #found == 0 then
        return {found = false, anim = -1, life = -1, x = 0, y = 0, distance = -1}
    end

    local boss = found[1]
    local tile = boss.Tile_XYZ
    return {
        found = true,
        anim = boss.Anim or -1,
        life = boss.Life or -1,
        x = tile and tile.x or 0,
        y = tile and tile.y or 0,
        z = tile and tile.z or 0,
        distance = boss.Distance or -1
    }
end

------------------------------------------
-- # BEHAVIOURS
------------------------------------------

--- Bomb-phase dodge: read the 2x2 ground bombs (object 4566) and, if we are
--- standing within clearance of any of them, walk to the nearest tile that
--- clears them all. When we are already safe we hold position and let the
--- rotation keep attacking.
---
--- Movement does not use the global cooldown, so this always reports false —
--- the fight loop keeps DPSing whether or not we moved this tick.
---
--- @param definition table
--- @param boss table
--- @return boolean moved
function Mechanics:dodgeBombs(definition, boss)
    local hazardDef = definition.hazard and Constants.OBJECTS[definition.hazard]
    if not hazardDef then return false end

    -- Combined hazard list: the 2x2 bombs AND the floor shadows, each with its
    -- own clearance. Avoiding bombs must never move us into a shadow, so both
    -- constrain the target tile together.
    local clearance = definition.escapeDistance or 3
    local bombHalf = math.floor((hazardDef.size or 2) / 2)
    local hazards = {}
    for _, bomb in ipairs(Utils:findAll(hazardDef.id, hazardDef.type, 20)) do
        local tile = bomb.Tile_XYZ
        if tile then
            hazards[#hazards + 1] = hazardBox(tile.x, tile.y, bombHalf,
                                              clearance)
        end
    end
    for _, shadow in ipairs(self:getShadowTiles()) do
        hazards[#hazards + 1] = shadow
    end

    -- Anima pools too — this movement runs while we're clearing them, so it is
    -- exactly when we're most likely to end up standing in one.
    local pool = Constants.ADDS.ANIMA_POOL
    for _, p in ipairs(self:findAnyType(pool.id, 25)) do
        local tile = p.Tile_XYZ
        if tile then
            hazards[#hazards + 1] = hazardBox(tile.x, tile.y, 0,
                                              pool.avoidClearance or 2)
        end
    end

    if #hazards == 0 then return false end -- nothing to avoid; keep attacking

    local player = Player:getCoords()
    if not player then return false end

    -- Safe where we stand: outside every hazard box by its clearance
    if tileIsClear(player.x, player.y, hazards) then return false end

    -- Rate-limit re-issuing the walk so we actually travel to the tile
    local tick = API.Get_tick()
    if (tick - self.state.lastMoveTick) < (definition.moveEveryTicks or 1) then
        return false
    end
    self.state.lastMoveTick = tick

    local target = self:findLethalSafeTile(hazards)
    if not target then
        self:log("no safe tile from bombs/shadows")
        return false
    end

    self:log(string.format("bomb/shadow dodge -> (%d, %d), avoiding %d hazard(s)",
                           target.x, target.y, #hazards))

    -- Urgent: we're standing on a bomb, so move even if the route isn't clean.
    self:walkAvoiding(target.x, target.y, hazards, true)
    return false
end

--- Attacks an NPC by id. Uses DoAction_NPC, which is id-based — Interact:NPC
--- expects a NAME string and throws a sol type error when handed a number, so
--- it must NOT be used with ids. This is the proven Arch-Glacor attack call.
--- @param id number
--- @param distance? number
--- @return boolean
function Mechanics:attackNpc(id, distance)
    return API.DoAction_NPC(0x2a, API.OFF_ACT_AttackNPC_route, {id},
                            distance or 60) and true or false
end

--- Re-acquires Raksha as the attack target. Surge drops the current target, so
--- after moving clear of a mechanic we click the boss again to resume DPS.
--- @return boolean attacked
function Mechanics:reattackBoss()
    local attacked = self:attackNpc(Constants.BOSS.id)
    self:log("reattack Raksha" .. (attacked and "" or " (failed)"))
    return attacked and true or false
end

--- Runs one sequence step. A step is either an ability (`{ability = "..."}`) or
--- a reattack (`{attackBoss = true}`).
--- @param step table
--- @param index number
--- @param total number
--- @return boolean used
function Mechanics:runStep(step, index, total)
    if step.attackBoss then
        return self:reattackBoss()
    end

    -- A step that MOVES us without spending an ability. This is how phase 4
    -- answers anything that would otherwise Surge: Surge follows our facing, and
    -- our facing is not something the script controls, so it throws us to
    -- whichever side of Raksha we happen to be pointing at. Backing off along
    -- the line between us and him keeps us on the side we are already holding —
    -- east, in phase 4 — and costs no global cooldown.
    if step.retreat then
        self:log(string.format("step %d/%d: stepping back %d tiles", index,
                               total, step.retreat))
        return self:retreatFromBoss(step.retreat)
    end

    if not step.ability then
        self:log(string.format("step %d/%d: nothing to do", index, total))
        return false
    end

    local onBoss = self:isTargetingBoss()

    -- When we're on an add or a pool, WALK clear instead of using a movement
    -- ability: Escape moves away from whatever we're targeting and Surge follows
    -- our facing, so on a non-boss target neither one reliably gets us out of a
    -- sweep centred on Raksha. Walking costs no global cooldown, so this doesn't
    -- interrupt the add we're killing.
    if not onBoss and step.walkFromBossWhenNotTargeting then
        -- runActive is what normally handles this, every tick, from the moment
        -- the animation starts. By the time the sequence reaches this step we
        -- are usually already clear and escapeSweep returns straight away; it
        -- stays here so the escape is still attempted if the definition has no
        -- escapeSweepWhenNotTargeting set.
        self:escapeSweep(step.walkFromBossWhenNotTargeting)
        self:log(string.format("step %d/%d: not on boss — escaping the sweep",
                               index, total))
        return false
    end

    -- Escape only clears the sweep when we're actually on the boss; Surge is the
    -- substitute when we're on an add or a pool.
    local ability = step.ability
    if step.abilityWhenNotTargeting and not onBoss then
        ability = step.abilityWhenNotTargeting
        self:log("not on boss — using " .. ability .. " instead of " ..
                     step.ability)
    end

    if not Utils:canUseAbility(ability) then
        -- "Skipping step" used to be the whole story here, and on a tail sweep
        -- that meant standing in the 7x7 until it landed: the step is marked
        -- executed either way (see runActive), so the sequence just walked on to
        -- the reattack having never moved us. A step that declares a retreat
        -- gets to fall back on it instead.
        if step.retreatWhenUnavailable then
            self:log(ability .. " not available — retreating on foot instead")
            return self:retreatFromBoss(step.retreatWhenUnavailable)
        end

        self:log(ability .. " not available, skipping step")
        return false
    end

    local used = Utils:useAbility(ability)
    self:log(string.format("step %d/%d: %s%s", index, total, ability,
                           used and "" or " (failed)"))
    return used
end

------------------------------------------
-- # MECHANIC LIFECYCLE
------------------------------------------

--- @param anim number
--- @param definition table
function Mechanics:begin(anim, definition)
    local tick = API.Get_tick()

    self.state.activeAnim = anim
    self.state.activeDef = definition
    self.state.startTick = tick
    self.state.stepIndex = 1
    self.state.stepExecuted = false
    self.state.stepTick = 0
    self.state.stepTimeMs = 0
    self.state.stepArrivedTick = nil
    self.state.lastMoveTick = -1
    self.state.poolsActive = false
    self.state.lastFired[anim] = tick
    self.state.count = self.state.count + 1

    -- Counterpart to noteMechanicSeen: this is the "answered" half of the miss
    -- rate in fightReview.
    local answered = self.state.review.answered
    answered[definition.name] = (answered[definition.name] or 0) + 1

    table.insert(self.state.history, 1, {
        name = definition.name,
        anim = anim,
        tick = tick
    })
    while #self.state.history > 8 do table.remove(self.state.history) end

    self:log("mechanic started: " .. definition.name)
end

function Mechanics:finish()
    if self.state.activeDef then
        self:log("mechanic ended: " .. self.state.activeDef.name)
    end
    self.state.activeAnim = nil
    self.state.activeDef = nil
end

--- True when this animation is on retrigger cooldown.
--- @param anim number
--- @param definition table
--- @return boolean
function Mechanics:suppressed(anim, definition)
    local last = self.state.lastFired[anim]
    if not last then return false end
    local window = definition.retriggerAfter or 5
    return (API.Get_tick() - last) < window
end

------------------------------------------
-- # ACTIVE MECHANIC PROCESSING
------------------------------------------

--- Runs the currently active mechanic. Returns true if it used the tick.
--- @param boss table
--- @return boolean consumed
function Mechanics:runActive(boss)
    local definition = self.state.activeDef
    if not definition then return false end

    local tick = API.Get_tick()
    local elapsed = tick - self.state.startTick

    -- A tail sweep has started and we are NOT on Raksha: get out of the 7x7
    -- NOW, before any of the sequence below runs.
    --
    -- This deliberately jumps the queue. The sweep sequences open with a hold —
    -- 33707 sits on Anticipation for a full 2000ms, 33706 has a 2 tick pre-delay
    -- — and only then reach the step that moves us. That pacing is right when
    -- we're on the boss, where Escape teleports us out in one action, but while
    -- we're on an add it meant standing in the sweep for the whole wind-up and
    -- only then starting to WALK. That is why we were still being hit.
    --
    -- Retried EVERY tick the sweep is live, not once: escapeSweep returns
    -- immediately once we're outside the radius, so the cost of re-checking is
    -- nothing, and a Dive or Surge that was a tick off cooldown when the
    -- animation started now still gets used.
    if definition.escapeSweepWhenNotTargeting and not self:isTargetingBoss() then
        if self:escapeSweep(definition.escapeSweepWhenNotTargeting) then
            return true
        end
    end

    ----------------------------------------
    -- Instant: one ability, then done
    ----------------------------------------
    if definition.kind == "instant" then
        -- Some responses depend on whether we're on the boss: Escape only works
        -- when we're targeting it, so fall back to Surge when we're not (e.g.
        -- while we're on an add or a pool).
        local ability = definition.ability
        if definition.abilityWhenNotTargeting and not self:isTargetingBoss() then
            ability = definition.abilityWhenNotTargeting
            self:log("not on boss — using " .. ability .. " instead of " ..
                         definition.ability)
        end

        local used = false
        if Utils:canUseAbility(ability) then
            used = Utils:useAbility(ability)
            self:log(ability .. (used and " used" or " failed"))
        else
            self:log(ability .. " not available")
        end
        self:finish()
        return used
    end

    ----------------------------------------
    -- Hold: do nothing at all until the animation ends
    ----------------------------------------
    if definition.kind == "hold" then
        -- Returning true consumes the tick, so the rotation, the cooldown filler
        -- and the add handlers all stay quiet. The lethal-ground dodge and Expel
        -- still run — they're checked earlier in update() — so holding can't get
        -- us killed by something avoidable.
        if boss.anim ~= self.state.activeAnim then
            self:log(definition.name .. ": animation ended, resuming")
            self:finish()
            return false
        end

        -- Safety cap, so a missed animation change can't freeze us forever.
        if elapsed >= (definition.maxHold or 20) then
            self:log(definition.name .. ": hold cap reached, resuming")
            self:finish()
            return false
        end

        return true
    end

    ----------------------------------------
    -- Sequence: run each step once, then hold for its `wait` before advancing
    ----------------------------------------
    if definition.kind == "sequence" then
        local step = definition.steps[self.state.stepIndex]
        if not step then
            self:finish()
            return false
        end

        -- Stamp when we arrived at this step, for any pre-delay below.
        if not self.state.stepArrivedTick then
            self.state.stepArrivedTick = tick
        end

        -- Optional PRE-delay, applied before the step fires (`wait` is the delay
        -- *after* it). Currently used so the Surge substitute on a tail sweep
        -- holds a moment rather than going out the instant the animation starts.
        local preDelay = 0
        if step.delayWhenNotTargeting and not self:isTargetingBoss() then
            preDelay = step.delayWhenNotTargeting
        end

        -- Fire the step on arrival; on the hold ticks we report false so the
        -- rotation keeps DPSing through the gap.
        local used = false
        if not self.state.stepExecuted and
            (tick - self.state.stepArrivedTick) >= preDelay then
            used = self:runStep(step, self.state.stepIndex, #definition.steps)
            self.state.stepExecuted = true
            self.state.stepTick = tick
            self.state.stepTimeMs = os.clock() * 1000
        end

        -- Advance once this step's wait has elapsed. `waitMs` is real time in
        -- milliseconds, for delays specified in seconds; `wait` is game ticks
        -- (default 1). Only ever advance from a step that has actually fired —
        -- otherwise a pending pre-delay would be skipped straight over.
        local ready = false
        if self.state.stepExecuted then
            if step.waitMs then
                ready = (os.clock() * 1000 - self.state.stepTimeMs) >=
                            step.waitMs
            else
                ready = (tick - self.state.stepTick) >= (step.wait or 1)
            end
        end

        if ready then
            self.state.stepIndex = self.state.stepIndex + 1
            self.state.stepExecuted = false
            self.state.stepArrivedTick = nil -- restamp on the next step
            if self.state.stepIndex > #definition.steps then self:finish() end
        end

        return used
    end

    ----------------------------------------
    -- Sustained: hold a behaviour for a while
    ----------------------------------------
    if definition.kind == "sustained" then
        if elapsed >= (definition.duration or 20) then
            self:finish()
            return false
        end

        if definition.behaviour == "dodgeBombs" then
            -- NOT WHILE WE ARE CLEARING POOLS.
            --
            -- This is the other half of the "no bomb dodging during a clear"
            -- rule in handleAnimaPools, and for a long time only that half
            -- existed: the call was removed from inside the pool handler, but
            -- this one kept running and the two walked us in opposite
            -- directions on the same iteration. dodgeBombs returns false, so it
            -- never consumed the tick — handleAnimaPools ran straight after it
            -- (step 5-6 of update(), BELOW this) and clicked the pool we had
            -- just been walked away from. Every tick, for the whole sweep.
            --
            -- It is worse than a wash, because dodgeBombs counts the anima
            -- pools THEMSELVES as hazards to stand clear of. The tile we have
            -- to be on to attack a pool is by definition inside that pool's
            -- hazard box, so the dodge was specifically pushing us off the
            -- destination the clear was walking to.
            --
            -- The clear is a race against the siphon — 5,000 healed per pool
            -- plus a stacking damage buff — so bomb DAMAGE is the cheaper side
            -- of this trade. What we do NOT give up is the lethal ground: the
            -- floor shadows and the 2789 highlight are instant death and
            -- handleInstakill answers them at the top of update(), above all of
            -- this, so they still move us.
            if not self:poolClearInProgress() then
                self:dodgeBombs(definition, boss)
            end
            return false

        elseif definition.behaviour == "burnDome" then
            -- Phase 4 detonation dome: a pure damage race, since a filled bar is
            -- an instant kill. Hold the target on Raksha and report false so the
            -- rotation and cooldown filler keep hitting — being `exclusive` is
            -- what stops pools and adds pulling us off mid-burn.
            local tick = API.Get_tick()
            if (tick - self.state.lastPoolTargetTick) >= INTERACT_TICKS then
                self.state.lastPoolTargetTick = tick
                self:reattackBoss()
            end

            -- Walk back onto the home tile BETWEEN sweeps, which update() cannot
            -- do for us here: returnHome is gated on there being no active
            -- mechanic, and the dome holds that slot for its whole 30 tick
            -- duration. Without this, one sweep escape during a dome parks us at
            -- seven tiles for the rest of it — and range is exactly what makes
            -- him swap the dodgeable tail sweep for shadow bombs.
            --
            -- Skipped while a sweep is actually playing, so this can never walk
            -- us back into the 7x7 we just left. returnHome paces itself and
            -- routes around hazards, and walking costs no global cooldown, so
            -- the burn carries on regardless.
            if not SWEEP_ANIMS[boss.anim] then self:returnHome() end

            return false
        end

        -- No behaviour defined for this mechanic yet (see constants.PENDING).
        return false
    end

    self:finish()
    return false
end

------------------------------------------
-- # ANIMA POOLS (kill fast, presence-based)
------------------------------------------

--- Picks the NEAREST pool, using cluster density only to break near-ties.
---
--- This used to be the other way round — densest cluster first, distance as the
--- tiebreak — on the reasoning that Threads of Fate splashes, so a knot of four
--- five tiles away beats an isolated pool two tiles away. That was right when
--- the rule was "clear to zero": every pool was going to die, so the only
--- question was what order killed them fastest.
---
--- It is wrong now. We clear down to the threshold and go back to Raksha, so we
--- kill a handful and leave — and the cost of a pool is dominated by the walk to
--- it, not the casts. Leading on a distant cluster meant crossing the arena
--- while the near pools we could have shaved off in seconds stayed up.
---
--- POOL_DISTANCE_TIE keeps the splash benefit where it is nearly free: pools
--- within a tile of each other in distance count as equally close, and the
--- denser of those wins.
---
--- O(n^2) in the pool count, so callers must only use it when they actually
--- need a new target — not on every pass.
--- @param pools table[] Live pools, nearest-first ordering not required
--- @return table|nil
function Mechanics:pickPoolTarget(pools)
    local best, bestScore, bestDistance = nil, -1, math.huge

    for _, p in ipairs(pools) do
        local tile = p.Tile_XYZ
        local d = p.Distance or 999
        local score = 0

        if tile then
            for _, other in ipairs(pools) do
                local ot = other.Tile_XYZ
                if ot and other ~= p then
                    local dx, dy = ot.x - tile.x, ot.y - tile.y
                    if math.sqrt(dx * dx + dy * dy) <= POOL_CLUSTER_RADIUS then
                        score = score + 1
                    end
                end
            end
        end

        -- Distance first, cluster only among the near-equally-close.
        local closer = d < (bestDistance - POOL_DISTANCE_TIE)
        local sameish = math.abs(d - bestDistance) <= POOL_DISTANCE_TIE

        if best == nil or closer or (sameish and score > bestScore) then
            best, bestScore, bestDistance = p, score, d
        end
    end

    if best then
        self:log(string.format("next pool: %.1f away, %d others within %d tiles",
                               bestDistance, bestScore, POOL_CLUSTER_RADIUS))
    end
    return best
end

--- Shadow anima pools (NPC 27354) heal the boss and there can be ~16 at once, so
--- they must die fast. This is PRESENCE-based (runs whenever any pool exists) —
--- not tied to the 33709 animation, which was why they weren't being killed: the
--- pools linger while the boss isn't mid-animation, so the old animation-gated
--- handler never ran.
---
--- It attacks the chosen pool OBJECT DIRECTLY (DoAction_NPC__Direct), which
--- bypasses every id/name/type ambiguity by acting on the exact thing we found,
--- and leads with Threads of Fate so each cast takes three pools rather than
--- one. Movement (bomb/shadow dodge) runs first so we stay safe.
---
--- The phase rotation is HELD for the whole clear (see rotationOnHold), so
--- POOL_DPS_ABILITIES is the entirety of what we cast while we're down here.
---
--- START conditions, any one of which is enough:
---   * the swarm reaches `killThreshold` for the current phase,
---   * Raksha announces the siphon (siphonImminent), or
---   * the phase 3 rotation reaches its "target pools" step
---     (requestPoolClear).
--- Once started we keep going until the count is back at or under the
--- threshold, then return to Raksha — the setting is a ceiling on how many pools
--- we tolerate, not an instruction to kill every one.
---
--- The exception is a siphon: once announced, every remaining pool heals him
--- 5,000 and stacks his damage buff, so that case clears to ZERO regardless of
--- the count.
--- @return boolean consumed
function Mechanics:handleAnimaPools()
    local pool = Constants.ADDS.ANIMA_POOL

    -- Disabled in settings: never break off to clear pools, just keep DPSing the
    -- boss. Clears the latch too, in case we were mid-clear.
    if pool.ignore then
        self.state.poolsActive = false
        self.state.poolClearRequested = false
        return false
    end

    -- A threshold of math.huge means NEVER for this phase, and never really does
    -- mean never — the siphon cue below does NOT override it.
    --
    -- That distinction is the point of this block. Phases 1, 2 and 4 are all set
    -- to math.huge, but the siphon check further down deliberately ignores the
    -- threshold, so without this we'd still break off and clear the moment
    -- Raksha announced a siphon. Pools are only worth chasing in phase 3, where
    -- he spawns 8 a sweep and siphons after every special; elsewhere the DPS lost
    -- walking to them costs more than the heal they give him.
    --
    -- Checked before the scan so the common case is cheap, and it drops an
    -- in-progress clear too: a latch started in phase 3 must not drag us around
    -- the phase 4 arena, where leaving the tile beside Raksha is what flips him
    -- to shadow bombs.
    local byPhase = pool.killThresholdByPhase or {}
    local phaseThreshold = byPhase[self.state.phase] or pool.killThreshold or 10
    if phaseThreshold == math.huge then
        if self.state.poolsActive then
            self.state.poolsActive = false
            self:log(string.format(
                         "phase %d ignores anima pools — dropping clear, back to Raksha",
                         self.state.phase))
            self:reattackBoss()
        end
        -- A rotation request can't override a math.huge phase either, so drop it
        -- rather than leaving it armed for the next phase to pick up.
        self.state.poolClearRequested = false
        return false
    end

    -- Phase 3 endgame: close enough to the phase 4 transition that damage into
    -- Raksha is worth more than clearing pools he won't live to siphon.
    local skipBelow = pool.skipBelowHpInPhase3
    if skipBelow and self.state.phase == 3 and self.state.bossLife > 0 and
        self.state.bossLife < skipBelow then
        if self.state.poolsActive then
            self.state.poolsActive = false
            self:log(string.format(
                         "boss at %d hp (< %d) — dropping pools, pushing to phase 4",
                         self.state.bossLife, skipBelow))
            self:reattackBoss()
        end
        self.state.poolClearRequested = false
        return false
    end

    -- LIVE pools only. This filter is the single biggest source of the pause
    -- after each kill: a pool that has just died keeps appearing in the scan for
    -- a tick or two with Life at 0, so `current` stayed matched to a corpse and
    -- we stood there "attacking" it until the POOL_RECLICK_TICKS watchdog
    -- finally fired. Dropping the dead ones means the very next iteration picks
    -- the next live pool and clicks it.
    local pools = {}
    for _, p in ipairs(self:findAnyType(pool.id, pool.range or 60)) do
        if (p.Life or 0) > 0 then pools[#pools + 1] = p end
    end

    if #pools == 0 then
        if self.state.poolsActive then
            self.state.poolsActive = false
            self.state.poolTargetId = nil
            self:log("anima pools cleared (0 left) — back to Raksha")
            self:reattackBoss()
        end
        self.state.poolClearRequested = false
        return false
    end

    -- ALREADY CLEARING, and back at or under the configured count: stop and
    -- return to Raksha. We do not need to kill every pool — the setting is a
    -- ceiling on how many we tolerate, not a target of zero.
    --
    -- This used to clear to ZERO once started, on the reasoning that stragglers
    -- heal him on the next siphon. That still holds WHEN A SIPHON IS COMING, and
    -- that case is excluded below — every pool he pulls in is 5,000 health and a
    -- damage-buff stack, so an announced siphon still means all of them go. What
    -- it does not justify is walking the arena killing the last few pools while
    -- he stands there untouched and no siphon is pending; that trades real DPS
    -- for a heal that is not going to happen.
    if self.state.poolsActive and #pools <= phaseThreshold and
        not self:siphonImminent() then
        self.state.poolsActive = false
        self.state.poolClearRequested = false
        self.state.poolTargetId = nil
        self:log(string.format(
                     "anima pools: %d left (threshold %d) — back to Raksha",
                     #pools, phaseThreshold))
        self:reattackBoss()
        return false
    end

    -- Below the threshold and not already clearing: ignore them and keep DPSing
    -- the boss. Only crossing the threshold — or the phase 3 rotation reaching
    -- its "target pools" step, or Raksha announcing the siphon — starts a clear.
    if not self.state.poolsActive then
        -- TOP OF THE WINDOW. Phase 3 opens on Raksha, not on a detour: he enters
        -- at full phase health and we stay on him until he is 10,000 down.
        --
        -- Checked before the siphon and the rotation request, and overriding
        -- both, because it is the same kind of rule as the math.huge phases —
        -- "not here, whatever the cue says". The window's other end
        -- (skipBelowHpInPhase3) is enforced further up.
        --
        -- poolClearRequested is deliberately LEFT ARMED. The rotation reaches
        -- its "Threads of Fate + target pools" step at a fixed point in the
        -- line, which can land while he is still above the gate; dropping the
        -- request there would lose the clear entirely, so instead it waits and
        -- fires the moment his health crosses. Only a genuinely finished or
        -- cancelled clear clears that flag.
        local startBelow = pool.startBelowHpInPhase3
        if startBelow and self.state.phase == 3 and self.state.bossLife > 0 and
            self.state.bossLife > startBelow then
            return false
        end

        -- The siphon message overrides the THRESHOLD: every pool he pulls in
        -- heals him 5,000 and stacks his damage buff, so once it's announced
        -- they all have to go regardless of how few are up. It does not override
        -- a math.huge phase — that case already returned above.
        local siphoning = self:siphonImminent()
        local requested = self.state.poolClearRequested

        -- `<=`, not `<`: the threshold is the number we TOLERATE, so a count
        -- equal to it is acceptable and only a count above it starts a clear.
        -- With `<` the start and stop tests were both "== threshold", so hitting
        -- the number started a clear that the stop check above cancelled on the
        -- same tick.
        if not requested and not siphoning and #pools <= phaseThreshold then
            return false
        end
        self:log(string.format(
                     "anima pools: %d up (phase %d, threshold %d%s%s) — clearing to zero",
                     #pools, self.state.phase, phaseThreshold,
                     siphoning and ", SIPHONING" or "",
                     requested and ", ROTATION" or ""))
    end

    -- Latch: from here we keep clearing every tick until none are left.
    --
    -- BOTH flags, whichever trigger got us here. poolsActive alone is not a
    -- durable latch — Mechanics:begin() resets it, and the bomb phase registers
    -- mechanics continuously, so a clear that started on the count threshold or
    -- the siphon cue was being dropped part-way through. Once the count had
    -- fallen below the threshold (3) the re-entry test then refused to restart
    -- it, and the last two or three pools were simply left standing for Raksha
    -- to siphon — the exact failure the "clear to ZERO" rule exists to prevent.
    --
    -- poolClearRequested survives begin(), and every exit path below already
    -- clears it (pools gone, phase says never, endgame HP skip, setting
    -- disabled), so nothing can leave it armed.
    self.state.poolsActive = true
    self.state.poolClearRequested = true

    -- NO BOMB DODGING WHILE WE CLEAR. The clear is a race against the siphon —
    -- every pool he pulls in heals him 5,000 and stacks his damage buff — so
    -- time spent walking away from falling rocks is time the pools are still
    -- standing.
    --
    -- Worse, dodgeBombs treats the ANIMA POOLS THEMSELVES as hazards to walk
    -- away from, so it pushes us off the exact tile we need to stand on to
    -- attack one: the pool killer walks us toward a pool while the dodge walks
    -- us off it, on the same tick.
    --
    -- BOTH halves of that are now enforced. It isn't called from here, and
    -- runActive skips its own call while poolClearInProgress() holds — which is
    -- the one that was actually doing the damage, because dodgeBombs returns
    -- false and so never stopped this handler running immediately afterwards.
    --
    -- WHAT THIS DOES NOT GIVE UP. The lethal ground — floor shadows and the 2789
    -- highlight — is instant death and is not handled here at all: handleInstakill
    -- runs at the top of update(), above everything including this, so it still
    -- moves us off anything that kills outright. The dive below checks
    -- getLethalHazardTiles() before committing, so we cannot land in one either.
    --
    -- What we accept is bomb DAMAGE during a clear, which is survivable, in
    -- exchange for the pools dying before he siphons them.

    -- The pool we're already killing, and the nearest one as a fallback.
    local nearest, nd = nil, math.huge
    local current = nil
    for _, p in ipairs(pools) do
        local d = p.Distance or 999
        if d < nd then nd, nearest = d, p end
        if self.state.poolTargetId and p.Unique_Id == self.state.poolTargetId then
            current = p
        end
    end

    local tick = API.Get_tick()

    -- Stick with the pool we're already on until it's actually dead, then move
    -- to the next on the SAME iteration — no pacing window, no confirmation
    -- step. Confirming a kill before moving on bought us nothing (a dead pool
    -- simply stops passing the Life filter above) and cost a tick per pool,
    -- which across a sweep of eight is most of the clear.
    --
    -- Equally, we do NOT re-click a pool we're already attacking. Repeated
    -- clicks on the same target cancel the in-flight attack, which looks busy
    -- and deals almost no damage. The staleClick watchdog is the one exception,
    -- so a click that silently failed can't strand us on a pool forever.
    local staleClick = (tick - self.state.lastPoolTargetTick) >= POOL_RECLICK_TICKS
    local needTarget = (current == nil) or staleClick

    -- Only score the cluster when we actually need a new target. It's O(n^2) in
    -- the pool count and this runs a dozen-plus times per game tick, so doing it
    -- unconditionally would burn most of a sweep's CPU re-deciding something we
    -- aren't allowed to change anyway.
    local target = current
    if needTarget then
        target = self:pickPoolTarget(pools) or nearest
    end

    if target and needTarget then
        API.DoAction_NPC__Direct(0x2a, API.OFF_ACT_AttackNPC_route, target)
        self.state.poolTargetId = target.Unique_Id
        self.state.lastPoolTargetTick = tick
    end

    -- Approach is measured against the pool we're actually going to hit, not
    -- the nearest one — the cluster we picked above is the one that has to be in
    -- range.
    local approach = target or nearest
    local ad = (approach and approach.Distance) or math.huge

    -- Close a long gap with Dive, but ONLY onto a tile that clears the LETHAL
    -- ground — a blind dive into a floor shadow is instant death. Skipped
    -- entirely when Dive/Bladed Dive is on cooldown.
    --
    -- Lethal-only, deliberately, and this is what makes the dive fire at all.
    -- Checked against getAllHazardTiles it could never succeed: that list puts a
    -- box around every anima pool with a clearance of 2, and the destination
    -- here IS a pool's tile — zero tiles from its own box, so "clear" was false
    -- on every single approach and we walked the whole way instead. Bombs are
    -- excluded for the same reason they aren't dodged during a clear: landing in
    -- one costs damage, not the kill.
    if approach and ad > (pool.diveDistance or 8) and self:canDive() then
        local tile = approach.Tile_XYZ
        local player = Player:getCoords()
        if tile and player then
            local tx, ty = math.floor(tile.x), math.floor(tile.y)
            if tileIsClear(tx, ty, self:getLethalHazardTiles()) then
                ---@diagnostic disable-next-line: undefined-global
                local dest = WPOINT.new(tx, ty, math.floor(player.z or 0))
                if self:diveToTile(dest) then
                    self:log(string.format("dived to pool at (%d, %d), %.1f away",
                                           tx, ty, ad))
                    return true
                end
            else
                self:log("skipped dive — destination is inside a hazard")
            end
        end
    end

    -- Dive on cooldown but the pool is still a way off: Surge covers ground too
    -- and shares no cooldown with Dive, so between them we're rarely reduced to
    -- walking.
    --
    -- Surge fires along our CURRENT FACING, and clicking a target does not turn
    -- us instantly — the turn plays out over the next tick or two. So we click
    -- first (above) and only surge once POOL_SURGE_FACE_TICKS have passed and
    -- we're genuinely pointed at it; surging on the same iteration as the click
    -- is what used to launch us across the arena in whatever direction we
    -- happened to already be facing.
    --
    -- The target is KEPT afterwards. Clearing it forced a re-click on the next
    -- pass, and that re-click cancelled the attack we'd just started — a wasted
    -- tick at the end of every approach. Walking on after a surge resumes the
    -- same attack by itself.
    --
    -- lastPoolSurgeTick is what now stops a double-surge. Clearing the target
    -- used to do that as a side effect; the ability bar's cooldown alone isn't
    -- enough, because it doesn't update within the same tick and this runs a
    -- dozen-plus times per tick.
    if approach and ad > (pool.surgeDistance or 6) and self.state.poolTargetId and
        (tick - self.state.lastPoolTargetTick) >= POOL_SURGE_FACE_TICKS and
        (tick - self.state.lastPoolSurgeTick) >= POOL_SURGE_REPEAT_TICKS and
        Utils:canUseAbility("Surge") then
        self.state.lastPoolSurgeTick = tick
        if Utils:useAbility("Surge") then
            self:log(string.format(
                         "surged toward pool %.1f away (faced it for %d ticks)",
                         ad, tick - self.state.lastPoolTargetTick))
            return true
        end
    end

    -- Revolution owns damage: we've targeted the pool, so the bar will hit it.
    -- Returning true keeps us focused on the pools rather than the boss.
    if self.revolution then return true end

    -- Abilities are paced to the global cooldown. Firing every loop iteration
    -- just cancels the previous cast, which is why pool damage was so poor.
    if (tick - self.state.lastPoolAbilityTick) < GCD_TICKS then
        return true -- still own the tick; wait out the GCD
    end

    -- One ordered list, Threads of Fate first. The old version tried the AoE
    -- through a separate `aoeAbility` branch and then fell into a second list
    -- that led with single-target damage, so whenever Threads was on cooldown we
    -- went back to killing pools one at a time.
    for _, ability in ipairs(POOL_DPS_ABILITIES) do
        if Utils:canUseAbility(ability) then
            self:log("pool DPS: " .. ability)
            Utils:useAbility(ability)
            self.state.lastPoolAbilityTick = tick
            return true
        end
    end

    return true
end

--- Starts a pool clear from the rotation, regardless of how many are up.
---
--- PVME's phase 3 line reaches "Threads of fate + target pools" at a specific
--- point and expects the pools to be dealt with there, which is a different
--- trigger from the count threshold and the siphon cue. Cleared automatically
--- once the last pool dies.
function Mechanics:requestPoolClear()
    self.state.poolClearRequested = true
end

------------------------------------------
-- # SHADOW MANIFESTATION (kill fast)
------------------------------------------

--- Shadow manifestation (NPC 27355) spawns and must be killed fast. We target
--- it, stun it with Soul Strike, and DPS it down with
--- MANIFESTATION_DPS_ABILITIES. Soul Strike needs a residual soul (buff 30123);
--- if we have none we Soul Sap it first, which generates one.
---
--- This ALWAYS owns the tick while the manifestation is up. It used to return
--- false once the stun was handled so the phase rotation could add its damage,
--- and that was the wrong trade: the rotation is written against Raksha, so
--- letting it run here fed Death Skulls, Volley and the specs into an add and
--- then resumed the phase several steps further on than it should have. The
--- rotation is held instead (see Mechanics:rotationOnHold) and picks up exactly
--- where it left off once the manifestation is dead.
--- @return boolean consumed
function Mechanics:handleShadowManifestation()
    local sm = Constants.ADDS.SHADOW_MANIFESTATION

    -- ENDGAME SKIP: close enough to phase 4 that phasing him beats killing an
    -- add the transition is about to remove anyway.
    --
    -- Checked before the scan so the common case is cheap, and it drops an
    -- in-progress kill too — the manifestation owns every tick while it lives,
    -- so a latch that survived into this window would hold the fight right where
    -- we most want damage going into Raksha.
    --
    -- Mirrors the pools' skipBelowHpInPhase3; both are party-scaled.
    if sm.skipBelowHp and self.state.bossLife > 0 and self.state.bossLife <
        sm.skipBelowHp then
        if self.state.manifestationActive then
            self.state.manifestationActive = false
            self.state.manifestTargetId = nil
            self:log(string.format(
                         "boss at %d hp (< %d) — ignoring manifestation, pushing to phase 4",
                         self.state.bossLife, sm.skipBelowHp))
            self:reattackBoss()
        end
        return false
    end

    -- LIVE manifestations only — the same filter the pools needed, and the same
    -- reason we were slow coming off it. A manifestation that has just died
    -- keeps appearing in the scan for a tick or two with Life at 0, so
    -- `#present > 0` stayed true, the latch stayed on, the rotation stayed held
    -- and we carried on clicking a corpse. Dropping the dead ones hands the
    -- target back to Raksha on the very next iteration.
    local present = {}
    for _, m in ipairs(self:findAnyType(sm.id, sm.range)) do
        if (m.Life or 0) > 0 then present[#present + 1] = m end
    end

    if #present == 0 then
        -- Gone: hand the target back to Raksha once.
        if self.state.manifestationActive then
            self.state.manifestationActive = false
            self.state.manifestTargetId = nil
            self:log("Shadow manifestation dead — back to Raksha")
            self:reattackBoss()
        end
        return false
    end

    if not self.state.manifestationActive then
        self.state.manifestationActive = true
        self:log("Shadow manifestation up — killing fast")
    end

    local tick = API.Get_tick()
    local target = present[1]

    -- Acquire it ONCE, ahead of the global-cooldown gate.
    --
    -- Two fixes in one. The click used to sit behind the GCD gate, so a
    -- manifestation that spawned mid-cast wasn't even targeted until the
    -- previous ability finished — three ticks of standing still before the kill
    -- started. And it fired on every pass through, which re-clicks an attack we
    -- are already running; repeated attack clicks cancel each other, so we were
    -- restarting the attack every three ticks and landing very little of it.
    -- Now it's click once and hold, with MANIFEST_RECLICK_TICKS as a watchdog so
    -- a click that silently failed can't strand us. Same shape as the pools.
    local stale = (tick - self.state.lastManifestTargetTick) >=
                      MANIFEST_RECLICK_TICKS
    if self.state.manifestTargetId ~= target.Unique_Id or stale then
        API.DoAction_NPC__Direct(0x2a, API.OFF_ACT_AttackNPC_route, target)
        self.state.manifestTargetId = target.Unique_Id
        self.state.lastManifestTargetTick = tick
    end

    -- Revolution owns damage — it's targeted, so the bar will kill it. We skip
    -- the manual Soul Strike stun rather than fighting the bar for the GCD.
    if self.revolution then return true end

    -- Abilities are paced to the global cooldown; firing every loop iteration
    -- just cancels the previous cast.
    if (tick - self.state.lastManifestAbilityTick) < GCD_TICKS then
        return true -- own the tick while the GCD runs down
    end

    -- Soul Strike stuns but needs a residual soul (buff 30123). If we have one,
    -- stun; otherwise Soul Sap it first to generate a soul. Either uses the GCD,
    -- so we consume the tick when we cast.
    local souls = Player:getBuff(30123)
    local haveSoul = souls.found and souls.remaining >= 1

    if haveSoul and Utils:canUseAbility("Soul Strike") then
        self:log("Soul Strike (stun) on manifestation")
        Utils:useAbility("Soul Strike")
        self.state.lastManifestAbilityTick = tick
        return true
    elseif not haveSoul and Utils:canUseAbility("Soul Sap") then
        self:log("Soul Sap to build a soul for Soul Strike")
        Utils:useAbility("Soul Sap")
        self.state.lastManifestAbilityTick = tick
        return true
    end

    -- Stunned (or Soul Strike is on cooldown): keep hitting it ourselves rather
    -- than handing the tick to a rotation aimed at Raksha.
    for _, ability in ipairs(MANIFESTATION_DPS_ABILITIES) do
        if Utils:canUseAbility(ability) then
            self:log("manifestation DPS: " .. ability)
            Utils:useAbility(ability)
            self.state.lastManifestAbilityTick = tick
            return true
        end
    end

    return true
end

------------------------------------------
-- # LETHAL GROUND DODGE (top priority)
------------------------------------------

--- Best tile to escape to: safe to stand on, and reachable without walking
--- through anything lethal on the way.
---
--- Ranked by (path cost, then distance) rather than distance alone. That
--- ordering is the important bit — the nearest safe tile is very often on the
--- far side of the shadow we're trying to escape, and taking it meant strolling
--- straight through the shadow to reach safety. A tile two steps further away on
--- our own side of it is strictly better.
---
--- Cost is used rather than a hard filter so that standing INSIDE a shadow still
--- yields an answer: every route out is "unsafe" at that point, and we want the
--- one that spends the fewest tiles in it.
--- @param hazards table[]
--- @return table|nil {x, y}
function Mechanics:findLethalSafeTile(hazards)
    local player = Player:getCoords()
    if not player then return nil end

    -- Candidates must also stay inside the arena. Without this the search
    -- happily picked tiles out at the edges (or off the map), where there's no
    -- room to dodge whatever comes next.
    local center = self.state.arenaCenter
    local arenaRadius = self:arenaRadius()

    local searchRadius = 10
    local best, bestCost, bestMove = nil, math.huge, math.huge
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local moveDistance = math.sqrt(dx * dx + dy * dy)
            if moveDistance <= searchRadius then
                local tileX = math.floor(player.x + dx)
                local tileY = math.floor(player.y + dy)

                local inArena = true
                if center then
                    local ax, ay = tileX - center.x, tileY - center.y
                    inArena = math.sqrt(ax * ax + ay * ay) <= arenaRadius
                end

                if inArena and tileIsClear(tileX, tileY, hazards) then
                    local cost = pathHazardCost(player.x, player.y, tileX,
                                                tileY, hazards)
                    if cost < bestCost or
                        (cost == bestCost and moveDistance < bestMove) then
                        best, bestCost, bestMove = {x = tileX, y = tileY}, cost,
                                                   moveDistance
                    end
                end
            end
        end
    end
    return best
end

--- Pulls a destination back inside the arena. Used for the fallback escape,
--- which runs directly away from a hazard and would otherwise happily run us
--- off the edge of the map.
--- @param x number
--- @param y number
--- @return number, number
function Mechanics:clampToArena(x, y)
    local center = self.state.arenaCenter
    if not center then return x, y end

    local radius = self:arenaRadius()
    local dx, dy = x - center.x, y - center.y
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance <= radius then return x, y end

    local scale = radius / distance
    return math.floor(center.x + dx * scale), math.floor(center.y + dy * scale)
end

--- Highest-priority handler: avoid all instant-death ground hazards at once —
--- the 2789 highlight AND the type-13 floor shadows (4x4). Both kill on contact,
--- and dodging one must not walk us into the other, so they're handled together:
--- we gather every hazard tile with its own clearance and move to the nearest
--- tile clear of all of them. Breaks the bind (Freedom) only when a 2789
--- highlight is the threat (that's the one that comes with the 33718 bind).
---
--- RETURN VALUE MEANS "I SPENT THE TICK'S ACTION", not "I am busy". It used to
--- return true for the whole dodge, which stopped the fight loop running the
--- rotation — so every shadow dodge was also a total DPS outage, and shadows are
--- out for large stretches of the fight. Walking costs no global cooldown, so
--- there is no reason to give up the ability that tick.
---
--- What still needs protecting is our POSITION, not the action: the pools,
--- manifestation and returnHome handlers all move us, and letting them run
--- mid-dodge would fight this one for where we stand. `state.instakillActive` is
--- that lock, checked by update() — so we keep exclusive control of movement
--- while handing the ability back to the rotation.
--- @return boolean consumed True only when an ability was cast
function Mechanics:handleInstakill()
    local player = Player:getCoords()
    if not player then return false end

    local hazards = {}
    local nearestDanger = math.huge
    local instakillNear = false

    -- 2789 insta-kill highlights (these carry the 33718 bind). Found via
    -- findAnyType because 2789 is a specific id.
    local ik = Constants.INSTAKILL
    for _, mark in ipairs(self:findAnyType(ik.id, 25)) do
        local tile = mark.Tile_XYZ
        if tile then
            local box = hazardBox(tile.x, tile.y, 0,
                                          escapeClearance(ik.safeRange,
                                                          ik.triggerRange))
            hazards[#hazards + 1] = box
            local d = distanceToHazard(player.x, player.y, box)
            if d <= ik.triggerRange then
                instakillNear = true
                if d < nearestDanger then nearestDanger = d end
            end
        end
    end

    -- Floor shadows, as cached 4x4 boxes. Distance is to the box EDGE, so a
    -- trigger of 1-2 means "standing in it or right on top of it" — which is the
    -- only time it's actually worth giving up DPS to move. Clamped for the same
    -- reason as the clearance in getShadowTiles.
    local sf = Constants.SHADOW_FLOOR
    local shadowTrigger = math.min(sf.triggerRange or 1, 2)
    for _, shadow in ipairs(self:getShadowTiles()) do
        hazards[#hazards + 1] = shadow
        local d = distanceToHazard(player.x, player.y, shadow)
        if d <= shadowTrigger and d < nearestDanger then
            nearestDanger = d
        end
    end

    -- Not within the trigger radius of any lethal hazard
    if nearestDanger == math.huge then
        self.state.instakillActive = false
        self.state.lethalTarget = nil
        return false
    end

    if not self.state.instakillActive then
        self.state.instakillActive = true
        self:log(string.format("LETHAL GROUND %.1f tiles away — MOVING",
                               nearestDanger))
    end

    -- Break the bind only when a 2789 highlight is the threat. This is the one
    -- part of the dodge that spends an action, so it's the one case where we
    -- report back that the tick is used.
    local castFreedom = false
    if instakillNear and Utils:canUseAbility("Freedom") then
        castFreedom = Utils:useAbility("Freedom") and true or false
    end

    local tick = API.Get_tick()

    -- Phase 4: escape along the ring. The nearest clear slot to the one we're on
    -- is found by stepping outward around the orbit, and the arc we take is the
    -- one that doesn't cross the shadow — so we go AROUND Raksha rather than
    -- darting across the arena and back. It also lands us on a known attack
    -- tile, so there's no separate walk home afterwards.
    if self.state.phase >= 4 and self.state.arenaCenterBoss then
        local current = self:orbitNearestSlot(player.x, player.y)
        local hop, target = self:planOrbitMove(hazards, current)

        if hop then
            if (tick - self.state.lastLethalMoveTick) >= INTERACT_TICKS then
                self.state.lastLethalMoveTick = tick
                self.state.lethalTarget = target
                self:log(string.format(
                             "LETHAL GROUND — orbiting to slot %d via (%d, %d)",
                             target and target.slot or -1, hop.x, hop.y))
                ---@diagnostic disable-next-line: undefined-global
                API.DoAction_WalkerW(WPOINT.new(hop.x, hop.y, hop.z))
            end
            -- Movement only: the lock (instakillActive) keeps other handlers
            -- off our position, but the rotation still gets this tick.
            return castFreedom
        end
        -- No usable arc (every slot fouled): fall through to the free-form
        -- search below rather than standing in the fire.
    end

    -- COMMIT to an escape tile rather than recomputing one every call. update()
    -- runs 12-20 times a game tick, so re-picking (and re-clicking) each time
    -- was what made the bot look like it was clicking all over the arena. We
    -- keep the chosen tile until we arrive or it stops being safe.
    local committed = self.state.lethalTarget
    if committed and tileIsClear(committed.x, committed.y, hazards) then
        local dx, dy = committed.x - player.x, committed.y - player.y
        if math.sqrt(dx * dx + dy * dy) <= 1 then
            committed = nil -- arrived; re-evaluate below
        end
    else
        committed = nil -- no target yet, or it is no longer safe
    end

    if not committed then
        committed = self:findLethalSafeTile(hazards)

        -- Fallback: run directly away from the nearest hazard box.
        if not committed then
            local closest, cd = hazards[1], math.huge
            for _, h in ipairs(hazards) do
                local d = distanceToHazard(player.x, player.y, h)
                if d < cd then cd, closest = d, h end
            end
            local cx = (closest.minX + closest.maxX) / 2
            local cy = (closest.minY + closest.maxY) / 2
            local dx, dy = player.x - cx, player.y - cy
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 0.01 then dx, dy, len = 1, 0, 1 end
            local fx = math.floor(player.x + (dx / len) * (closest.clearance + 2))
            local fy = math.floor(player.y + (dy / len) * (closest.clearance + 2))
            fx, fy = self:clampToArena(fx, fy) -- never flee off the map
            committed = {x = fx, y = fy}
        end

        self.state.lethalTarget = committed
        self:log(string.format("LETHAL GROUND dodge -> (%d, %d)", committed.x,
                               committed.y))
    end

    -- One walk per tick at most, for the same reason. Routed via walkAvoiding so
    -- the committed tile is reached AROUND the hazards rather than through them
    -- — the destination was always checked, the journey never was.
    if (tick - self.state.lastLethalMoveTick) >= INTERACT_TICKS then
        self.state.lastLethalMoveTick = tick
        self:walkAvoiding(committed.x, committed.y, hazards, true)
    end

    -- Movement only — see the header. The rotation keeps DPSing through the
    -- dodge; `instakillActive` is what stops anything else moving us.
    return castFreedom
end

------------------------------------------
-- # PRESENCE MECHANICS (adds)
------------------------------------------

--- Shadow Energy adds (NPC 27356) are keyed on presence, not a boss animation:
--- while any are up we attack them down, and once they are gone we reattack
--- Raksha. Returns true whenever it owns the tick, so the boss rotation yields
--- and we stay focused on the adds.
--- @return boolean consumed
function Mechanics:handleAdds()
    local add = Constants.ADDS.SHADOW_ENERGY
    local present = self:findAnyType(add.id, add.range)

    if #present > 0 then
        if not self.state.addsActive then
            self.state.addsActive = true
            self:log(string.format("%s up (%d) — expelling", add.name, #present))
        end

        -- ROUND-ROBIN, one click per orb, never waiting to see if it worked.
        --
        -- This used to call Interact:NPC(name, action) with no tile, which lets
        -- the client pick the match for us — and it always picks the same one
        -- (the nearest). So we hammered a single orb until it popped, then moved
        -- to the next: four orbs took four times as long as it needed to, with
        -- every extra click on an already-dispelled orb wasted.
        --
        -- Interact:NPC takes an optional TILE to search around, so we can aim at
        -- one specific orb. We step through the list, clicking each in turn, and
        -- simply start again from the top when we reach the end — a still-present
        -- orb gets re-clicked on the next pass. Confirming a dispel is exactly
        -- the "check" that was costing us the time, and it's unnecessary: a
        -- redundant click on a dead orb is free, a missed click is not.
        --
        -- Expel is also the one interaction worth firing FASTER than once a game
        -- tick. These are Mind Flay orbs: up to four at once, each ticking ~600
        -- damage while we're immobilised, and they dispel on click rather than
        -- needing an attack to resolve, so clicks don't cancel each other the way
        -- attack interactions do.
        local nowMs = os.clock() * 1000
        if (nowMs - self.state.lastExpelMs) >= EXPEL_INTERVAL_MS then
            self.state.lastExpelMs = nowMs

            -- Wrap the index into the CURRENT list length: orbs disappear as we
            -- go, so the list shrinks under us and a stale index would either
            -- error or skip one.
            self.state.expelIndex = (self.state.expelIndex % #present) + 1
            local orb = present[self.state.expelIndex]
            local tile = orb and orb.Tile_XYZ

            if tile then
                -- Tile_XYZ is an FFPOINT (float world position); Interact:NPC
                -- wants a WPOINT. Handing the raw field over throws a sol type
                -- error, the same trap as passing an id where a name is expected.
                ---@diagnostic disable-next-line: undefined-global, missing-parameter
                local at = WPOINT.new(math.floor(tile.x), math.floor(tile.y),
                                      math.floor(tile.z or 0))
                ---@diagnostic disable-next-line: missing-parameter
                Interact:NPC(add.name, add.action, at)
            else
                -- Unreadable tile: fall back to letting the client choose.
                ---@diagnostic disable-next-line: missing-parameter
                Interact:NPC(add.name, add.action)
            end
        end
        return true
    end

    -- Just cleared: reattack Raksha once, then hand back to the rotation
    if self.state.addsActive then
        self.state.addsActive = false
        self:log(add.name .. " cleared — reattacking Raksha")
        self:reattackBoss()
        return true
    end

    return false
end

------------------------------------------
-- # UPDATE
------------------------------------------

--- Called once per tick from the fight loop.
--- @return boolean consumed True if a mechanic used this tick's ability action
--- Priority order (highest first):
---   0. Dodge the shadow floor / insta-kill ground — ALWAYS, non-negotiable
---   1. Expel Shadow Energy
---   2. Freedom (bind + shadow bombardment)
---   3. Dodge bombs
---   4. Tail sweep (Escape when on the boss, else Surge)
---   5. Shadow manifestation
---   6. Shadow anima pools
---   7. The boss (rotation — we return false and the fight loop DPSes)
--- 5 and 6 own the fight outright while they're running: they cast from their
--- own ability lists and the fight loop holds the phase rotation for the whole
--- clear (see rotationOnHold), so nothing aimed at Raksha is spent on an add.
--- Phase 4 collapses most of this: we hold one tile east of Raksha so bombs and
--- bombardment never come out, pools are left alone (see killThresholdByPhase),
--- and the only thing that moves us is escaping the tail sweep — after which
--- returnHome puts us straight back on the tile.
--- Steps 2-4 are boss animations, so only one can be live at a time; their
--- relative `priority` decides which wins if a new animation starts while
--- another response is still running.
function Mechanics:update()
    -- Read the boss once up front and refresh the arena anchor BEFORE anything
    -- moves us. Every movement decision is constrained to a radius around this,
    -- which is what keeps the fight near the middle of the arena.
    local boss = self:getBoss()

    -- Track Raksha's tile first: phase 4 home is derived from it.
    if boss.found then
        self.state.arenaCenterBoss = {x = boss.x, y = boss.y, z = boss.z or 0}
    end

    -- Anchor everything to our home tile when we have one; the boss is only a
    -- fallback for before it's been recorded. A fixed anchor is what makes the
    -- dodge radius and the walk-back repeatable.
    local home = self:getHome()
    if home then
        self.state.arenaCenter = home
    elseif boss.found then
        self.state.arenaCenter = {x = boss.x, y = boss.y}
    end

    if boss.found then
        self.state.bossLife = boss.life

        -- Track the highest reading for the GUI health bar's denominator.
        if boss.life > (self.state.review.bossMaxSeen or 0) then
            self.state.review.bossMaxSeen = boss.life
        end

        -- Phases only ever move FORWARD. Entering phase 4 heals Raksha back to
        -- 400k, which on HP alone reads as phase 3 again — latching stops us
        -- dropping back and losing all the phase 4 handling.
        local phase = self:getPhase(boss.life)
        if phase > self.state.phase then
            self:log(string.format("PHASE %d (boss %d hp)", phase, boss.life))
            self.state.phase = phase
        end
    end

    -- Sample HP once per GAME TICK, not once per call — update() runs 12-20
    -- times a tick and we'd otherwise count the same drop over and over.
    local sampleTick = API.Get_tick()
    if sampleTick ~= self.state.review.lastSampleTick then
        self.state.review.lastSampleTick = sampleTick
        self:sampleHealth(Constants.ANIM_NAMES[boss.anim] or
                              (boss.found and "auto/idle" or "boss unreadable"))
    end

    -- REGISTER a new boss mechanic FIRST, before any handler can return early.
    --
    -- This ordering is load-bearing and used to be wrong. Registration relies on
    -- edge detection — we react when the animation CHANGES — and lastSeenAnim was
    -- only updated further down, after handleInstakill and handleAdds had their
    -- chance to `return true`. So any mechanic that started while we were dodging
    -- lethal ground or expelling orbs was never registered: by the time those
    -- handlers finished, the animation had already come and gone, animChanged was
    -- false against a stale lastSeenAnim, and we simply ate the attack.
    --
    -- That is the worst kind of bug here, because it fires exactly when we're
    -- already under pressure — a tail sweep landing during a shadow dodge is
    -- precisely when missing it hurts. Registering first costs nothing: begin()
    -- only records the mechanic, and runActive below still runs after the
    -- higher-priority handlers, so the response order is unchanged.
    if boss.found then
        -- Only react when the animation actually changes. update() is called
        -- many times per game tick and boss animations play for several ticks,
        -- so reacting to "animation is present" fired the response repeatedly
        -- (the double Escape / double Surge).
        local animChanged = (boss.anim ~= self.state.lastSeenAnim)
        self.state.lastSeenAnim = boss.anim

        -- Phase-specific definition wins when there is one (phase 4 changes the
        -- bombardment response and adds the dome), otherwise the general table.
        local byPhase = Constants.MECHANICS_BY_PHASE[self.state.phase]
        local definition = (byPhase and byPhase[boss.anim]) or
                               Constants.MECHANICS[boss.anim]

        if animChanged and definition then
            self:noteMechanicSeen(definition.name)
        end

        if definition and animChanged and
            not self:suppressed(boss.anim, definition) then
            -- Don't let a lower-priority animation displace a response that's
            -- still running (e.g. a tail sweep must not cut off a bombardment
            -- escape mid-sequence).
            local active = self.state.activeDef
            local outranks = (active == nil) or
                                 ((definition.priority or 0) >=
                                     (active.priority or 0))
            if outranks then self:begin(boss.anim, definition) end
        end
    elseif self.state.activeDef then
        self:finish()
    end

    -- 0. ALWAYS dodge the lethal ground (floor shadows + 2789 highlight). This
    --    is instant death, so it outranks everything including Expel.
    --
    --    It reports whether it spent the tick's ACTION, not whether it moved.
    --    Walking costs no global cooldown, so a dodge that only walks lets the
    --    rotation keep firing — see the movement lock in handleInstakill.
    if self:handleInstakill() then return true end

    -- 0b. Tail sweep safety net. Below the lethal ground, which is instant
    --     death, but above everything else — a sweep that nothing registered a
    --     response for still has to be walked out of. See ensureClearOfSweep for
    --     why phase 4's dome made that a routine occurrence.
    if self:ensureClearOfSweep(boss) then return true end

    -- 1. Expel Shadow Energy — top of the actioned priorities.
    if self:handleAdds() then return true end

    -- 2-4. Boss animation responses: Freedom (bind/bombardment), bomb dodge,
    --      tail sweep. These beat the manifestation and the pools, so a boss
    --      attack mid-clear is always answered first.
    local exclusive = false

    if boss.found and self.state.activeDef then
        local consumed = self:runActive(boss)

        -- A mechanic marked `exclusive` owns the fight until it finishes —
        -- INCLUDING the hold ticks of a sequence, where runActive returns
        -- false so the rotation can keep DPSing. Without this the killers
        -- below would run on those ticks and re-target a pool mid-escape.
        -- runActive may have just finished the mechanic, so re-read state.
        exclusive = (self.state.activeDef ~= nil) and
                        (self.state.activeDef.exclusive == true)

        if consumed then return true end
    end

    -- 5-6. Anima pools, THEN the manifestation — unless an exclusive response is
    --      still mid-flight, or the lethal-ground dodge owns our movement.
    --      Presence-based, so they run whether or not Raksha is targetable.
    --
    --      POOLS GO FIRST. Both handlers own the tick when they act, so whichever
    --      is tested first starves the other for as long as it is running. With
    --      the manifestation first, a manifestation that spawned during a pool
    --      sweep held the tick for its whole life while the pools kept stacking
    --      up behind it — and pools are the ones that heal Raksha 5,000 apiece on
    --      the next siphon. The manifestation does not heal him; it just has to
    --      die reasonably soon.
    --
    --      This is bounded now in a way it would not have been before: the pool
    --      clear stops at the configured count rather than running to zero, so
    --      the manifestation waits for a handful of kills, not for the arena to
    --      be swept clean.
    --
    --      The instakillActive check is the movement lock: these handlers Dive,
    --      Surge and walk, so letting them run mid-dodge would fight the dodge
    --      for control of where we stand — which is how you die to the thing you
    --      were already running from.
    if not exclusive and not self.state.instakillActive then
        if self:handleAnimaPools() then return true end
        if self:handleShadowManifestation() then return true end
    end

    -- 7. Nothing threatening: drift back to our home tile so the next mechanic
    --    starts from a known, safe position. Movement costs no global cooldown,
    --    so the rotation still fires this tick.
    --
    --    NOT while a mechanic is still running, and NOT mid-dodge: this used to
    --    walk us straight back into the tail sweep we had just escaped, which is
    --    a large part of why phase 4 looked so frantic.
    if not exclusive and not self.state.activeDef and
        not self.state.instakillActive then self:returnHome() end
    return false
end

------------------------------------------
-- # DEBUG
------------------------------------------

--- Rows for the debug panel.
--- @return table
function Mechanics:tracking()
    local rows = {
        {"Mechanics:", ""},
        {"- Phase", tostring(self.state.phase)},
        {
            "- Home",
            (function()
                local h = self:getHome()
                if not h then return "not set" end
                if h.name then
                    return string.format("(%d, %d) [%s]", h.x, h.y, h.name)
                end
                local primary = self.state.homeTile
                local usingAlt = primary and
                                     (h.x ~= primary.x or h.y ~= primary.y)
                return string.format("(%d, %d)%s", h.x, h.y,
                                     usingAlt and " [alt]" or "")
            end)()
        },
        {
            -- Which ring slot we're on and whether the ground under us is safe.
            -- The whole phase 4 movement story reads off these two, so they're
            -- the first thing to look at if the dodging misbehaves again.
            "- Orbit",
            (function()
                if self.state.phase < 4 or not self.state.arenaCenterBoss then
                    return "n/a (phase < 4)"
                end
                local player = Player:getCoords()
                if not player then return "no player" end
                local slot = self:orbitNearestSlot(player.x, player.y)
                local safe = tileIsClear(player.x, player.y,
                                         self:getAllHazardTiles())
                return string.format("slot %d/%d, standing %s", slot,
                                     ORBIT_SLOTS, safe and "clear" or "IN HAZARD")
            end)()
        },
        {"- Siphoning", self:siphonImminent() and "YES (announced)" or "no"},
        {"- Active", self.state.activeDef and self.state.activeDef.name or "none"},
        {"- Lethal ground", self.state.instakillActive and "DODGING" or "clear"},
        {
            -- Shows the threshold for the CURRENT phase, not the generic
            -- fallback — pools are cleared in phase 3 only, so a flat number
            -- here read as though we were about to chase them in every phase.
            "- Anima pools",
            (function()
                local pool = Constants.ADDS.ANIMA_POOL
                if pool.ignore then return "ignored (setting)" end

                local byPhase = pool.killThresholdByPhase or {}
                local threshold = byPhase[self.state.phase] or pool.killThreshold or
                                      10
                if threshold == math.huge then
                    return string.format("ignored (phase %d)", self.state.phase)
                end
                if self.state.poolsActive then return "KILLING (to zero)" end

                -- Which END of the phase 3 window we're outside, when we are.
                -- "idle" alone was ambiguous the moment the window existed:
                -- above the top gate and below the bottom one look identical
                -- from the outside, and they mean opposite things.
                local life = self.state.bossLife or 0
                if self.state.phase == 3 and life > 0 then
                    local startBelow = pool.startBelowHpInPhase3
                    if startBelow and life > startBelow then
                        return string.format("holding on boss (>%d hp)%s",
                                             startBelow,
                                             self.state.poolClearRequested and
                                                 ", ROTATION ARMED" or "")
                    end
                    local skipBelow = pool.skipBelowHpInPhase3
                    if skipBelow and life < skipBelow then
                        return string.format("done (<%d hp, pushing to P4)",
                                             skipBelow)
                    end
                end

                return string.format("idle (<%d)", threshold)
            end)()
        },
        {"- Manifestation", self.state.manifestationActive and "killing" or "none"},
        {"- Adds", self.state.addsActive and "clearing" or "none"},
        {"- Total fired", tostring(self.state.count)}
    }

    -- Live detection counts across all object types, so we can SEE whether each
    -- entity is actually being found in the arena (a 0 while it's visibly on
    -- screen means the id or scan is wrong, not the handler).
    -- Targeting readout: drives Escape-vs-Surge on the tail sweep.
    local interacting = "nil"
    local okI, lp = pcall(API.ReadLpInteracting)
    if okI and lp then
        interacting = tostring(lp.Id) .. " " .. tostring(lp.Name)
    end
    local targetName = "nil"
    local okT, tinfo = pcall(API.ReadTargetInfo99, true)
    if okT and tinfo then targetName = tostring(tinfo.Target_Name) end

    table.insert(rows, {"Targeting:", ""})
    table.insert(rows, {"- On boss?", tostring(self:isTargetingBoss())})
    table.insert(rows, {"- Interacting", interacting})
    table.insert(rows, {"- Target name", targetName})

    table.insert(rows, {"Detected:", ""})
    table.insert(rows, {"- 2789 insta-kill", tostring(#self:findAnyType(2789, 25))})
    table.insert(rows, {"- shadow floor", tostring(#self:getShadowTiles())})
    table.insert(rows, {"- 27355 manifest", tostring(#self:findAnyType(27355, 60))})
    table.insert(rows, {"- 27356 shadow energy", tostring(#self:findAnyType(27356, 60))})
    table.insert(rows, {"- 27354 anima pool", tostring(#self:findAnyType(27354, 60))})

    if self.state.activeDef then
        local elapsed = API.Get_tick() - self.state.startTick
        table.insert(rows, {"- Ticks active", tostring(elapsed)})
        if self.state.activeDef.kind == "sequence" then
            table.insert(rows, {
                "- Step",
                string.format("%d/%d", self.state.stepIndex,
                              #self.state.activeDef.steps)
            })
        end
    end

    for index, entry in ipairs(self.state.history) do
        table.insert(rows, {
            string.format("- [%d] %s", index, entry.name), tostring(entry.anim)
        })
    end

    return rows
end

return Mechanics
