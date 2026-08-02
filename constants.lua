--- @module 'raksha.constants'
--- @version 1.0.0
--- Confirmed Raksha (normal mode) identifiers and mechanic definitions.
---
--- Everything in CONFIRMED came from observed data. Everything in PENDING is
--- still unknown and is listed explicitly so nothing gets silently guessed —
--- if a value is not in this file, the code must not assume it.
---@diagnostic disable: undefined-global

local PrayerFlicker = require("core.prayer_flicker")

local Constants = {}

------------------------------------------
-- # BOSS
------------------------------------------

Constants.BOSS = {
    name = "Raksha, the Shadow Colossus",
    id = 27352,
    type = 1 -- NPC
}

--- Raksha once he's been killed: he becomes "Raksha, the Shadow Colossus
--- (subdued)" under a different id. His presence is a definitive kill signal —
--- far better than inferring death from HP, which reads 0 in several harmless
--- situations — and it's the cue that the drop can be looted.
Constants.BOSS_SUBDUED = {
    name = "Raksha, the Shadow Colossus (subdued)",
    id = 27353,
    type = 1
}

--- Dormant ("sleeping") Raksha, present in the arena before the fight starts.
--- The instance is generated fresh each time so fixed tiles shift between runs,
--- but this NPC is a stable anchor to position against. Attacking it wakes the
--- active boss (27352).
Constants.DORMANT_BOSS = {
    id = 27351,
    type = 1 -- NPC
}

------------------------------------------
-- # ANIMATIONS (confirmed)
------------------------------------------

Constants.ANIM = {
    -- Auto attacks; these drive prayer switching
    ATTACK_RANGED = 33705,
    ATTACK_MAGIC = 33703,
    ATTACK_MELEE = 33702,

    -- Tail sweep, two variants with different correct responses
    TAIL_SWEEP_ESCAPE = 33706, -- answer with Escape
    --
    -- 33707 IS DUAL-PURPOSE. Normally it's the tail sweep answered with Freedom
    -- then Surge — but at 200k HP or below, BEFORE phase 4 has started, it is the
    -- phase 4 transition and the correct response is to do nothing at all until
    -- it ends.
    --
    -- HP does not separate the two on its own: phase 4 runs 400k down to 0 and he
    -- keeps tail sweeping throughout, so a 33707 at 150k is a real sweep that
    -- needs its Freedom. RakshaFight:inPhase4Transition disambiguates with a
    -- latch — the transition can only happen before the phase 4 rotation loads.
    TAIL_SWEEP_FREEDOM = 33707,

    -- Bombs: keep moving around the arena, but keep attacking through it
    BOMBS = 33709,

    -- Shadow bomb / shadow bombardment
    SHADOW_BOMBARDMENT = 33720,

    -- Bind + insta-kill highlight: Freedom, then MOVE out of the 2789 zone
    -- (see Constants.INSTAKILL). This is a lethal mechanic.
    INSTAKILL_BIND = 33718,

    -- Phase 4 only: the shadow detonation dome. Burn it down fast — if the bar
    -- above him fills it is an instant kill.
    DOME = 33711
}

--- Reverse lookup so logs can name an animation instead of printing a number.
Constants.ANIM_NAMES = {}
for name, id in pairs(Constants.ANIM) do Constants.ANIM_NAMES[id] = name end

------------------------------------------
-- # INSTA-KILL HIGHLIGHT
------------------------------------------

--- Ground highlight (object 2789) that comes with animation 33718. Standing
--- within `lethalRange` tiles of one is INSTANT DEATH, so dodging it is the
--- single highest-priority thing the script does — checked before every other
--- mechanic. `triggerRange` gives a tile of reaction buffer, `safeRange` is how
--- far clear we move (past the kill radius).
Constants.INSTAKILL = {
    id = 2789,
    type = 4,
    lethalRange = 4, -- die within this many tiles
    triggerRange = 5, -- start dodging when a highlight is this close
    safeRange = 6 -- move to a tile at least this far from every highlight
}

--- Non-interactable 4x4 shadow dropped on the floor. Stepping in one is INSTANT
--- DEATH and several can be out at once, so it's avoided at the same top
--- priority as the 2789 highlight (handled together in handleInstakill so we
--- never dodge one into the other), AND fed into every movement decision (bomb
--- dodge etc.) so we never walk back into one. The exact id is uncertain, so we
--- scan BOTH candidates. triggerRange/safeRange are sized for the 4x4 footprint.
Constants.SHADOW_FLOOR = {
    ids = {7407}, --7391}, -- either id — scan both to be safe
    type = 4,

    -- 4x4 footprint, modelled as a box centred on the reported tile rather than
    -- as a point. Treating it as a point meant tiles we called "safe" could
    -- still be inside the shadow, so we kept walking back into it.
    size = 4,

    -- These are measured from the BOX EDGE, not the shadow's centre — the box
    -- already covers the 4x4 footprint, so they only need to be a tile or two.
    --
    -- They were 4 and 6, which made a ~15x15 exclusion zone around every shadow:
    -- in a small arena that meant we were nearly always "in danger" and shuffled
    -- between tiles non-stop, bleeding DPS. The danger is standing IN one, so we
    -- react when we're in/touching it and move just far enough to be clear.
    triggerRange = 1,
    safeRange = 2
}

------------------------------------------
-- # PHASES
------------------------------------------

--- SOLO HP thresholds (wiki). Phase drives how aggressively we clear pools:
---   P1 800k-600k  Raksha does NOT siphon pools yet — pure DPS, ignore them
---   P2 600k-400k  Energy waves start; he siphons, so pools must die
---   P3 400k-200k  8 pools per sweep and he siphons after EVERY special
---   P4 200k-0     Antechamber; shadow detonation dome
---
--- These are the BASE values. Constants.PHASE_HP is rebuilt from them by
--- setPartySize, so read PHASE_HP everywhere and never these directly.
Constants.PHASE_HP_SOLO = {P2 = 600000, P3 = 400000, P4 = 200000}

--- Live thresholds, scaled for the party we are actually in. Starts at solo.
Constants.PHASE_HP = {
    P2 = Constants.PHASE_HP_SOLO.P2,
    P3 = Constants.PHASE_HP_SOLO.P3,
    P4 = Constants.PHASE_HP_SOLO.P4
}

--- Players the thresholds are currently scaled for.
Constants.partySize = 1

--- Rescales the phase thresholds for a party of `size`.
---
--- Raksha's life points scale exactly with the party: 800,000 solo, 1,600,000
--- in a duo, and the wiki's strategy page confirms every transition doubles with
--- them — phases at 1.2M / 800k / 400k rather than 600k / 400k / 200k. The
--- enrage heal follows the same rule: he returns to phase 3's starting health,
--- which is 400k solo and 800k duo.
---
--- Getting this wrong is not a cosmetic reporting error. mechanics.getPhase
--- derives the phase from these numbers, and the phase decides which rotation is
--- loaded and which mechanic definitions apply — so a duo fight read against
--- solo thresholds sits in "phase 4" for most of the kill, loading the phase 4
--- rotation and its overrides against a boss still in phase 1.
---
--- Mutates the SAME table rather than replacing it, because constants.lua is
--- required once and other modules hold a reference to Constants.PHASE_HP.
--- @param size number Players in the instance (1 = solo, 2 = duo)
function Constants.setPartySize(size)
    size = math.max(math.floor(tonumber(size) or 1), 1)

    Constants.partySize = size
    Constants.PHASE_HP.P2 = Constants.PHASE_HP_SOLO.P2 * size
    Constants.PHASE_HP.P3 = Constants.PHASE_HP_SOLO.P3 * size
    Constants.PHASE_HP.P4 = Constants.PHASE_HP_SOLO.P4 * size

    -- Reassigned rather than mutated: this one is a number, and every reader
    -- looks it up through Constants at call time.
    Constants.LUCK_RING_HP = Constants.LUCK_RING_HP_SOLO * size
end

--- Phase 4 is a different, smaller arena and Raksha heals back to 400k on entry
--- — which reads as phase 3 on HP alone, so the phase is LATCHED and only ever
--- moves forward (see mechanics.getPhase).
---
--- Positioning there is relative to Raksha rather than a fixed tile: he can't be
--- walked through (a 7x7 block), the arena is tighter, and the whole phase is a
--- damage race against the detonation dome.
Constants.PHASE4 = {
    -- ONE TILE, HELD. The wiki is explicit: "it is highly recommended to stay
    -- close to Raksha whenever possible so that he will always use his tail
    -- swipe instead of launching shadow bombs". Stay adjacent and the bombs —
    -- which disable prayers and are frequently fatal alongside his autos —
    -- simply never come out, so the whole phase reduces to prayers, escaping the
    -- tail sweep, and DPS.
    --
    -- We enter from the EAST and hold a single tile `homeOffsetX` east of him,
    -- which is 2 tiles off the edge of his blocked 5x5. The previous four-spot
    -- clockwise ring meant we were constantly relocating between spots, and
    -- every relocation was a window for him to switch to bombs.
    homeOffsetX = 4,

    bossFootprint = 2, -- half-extent of the blocked 5x5
    bossClearance = 1, -- just enough not to path into him

    -- Tail sweep is a 7x7 centred on him, so Escape clears it and we walk
    -- straight back in.
    --
    -- There is no returnDistance here any more: phase 4 movement is orbital, so
    -- "are we home?" is answered by which RING SLOT we're standing on rather
    -- than by a distance tolerance. See ORBIT_SLOTS in mechanics.lua.
    arenaRadius = 10
}

--- Each pool Raksha siphons heals him 5,000 AND stacks Shadow Infused Power (up
--- to +100% damage) and Shadow Infused Hide (up to 25% damage reduction). Left
--- unchecked this is the single biggest reason a kill stalls out.
Constants.POOL_SIPHON_HEAL = 5000

--- Chat line that fires when Raksha starts pulling the pools in — the exact cue
--- to drop everything and clear them.
Constants.SIPHON_CHAT = "anchors you to the shadows"

--- HP at which we swap in the luck ring, so the drop rolls with it. Phase 4
--- only — he sits above this for most of the fight.
---
--- Scaled with the party by setPartySize, like the phase thresholds. Left at a
--- flat 50,000 it would be half the warning it is meant to be in a duo, where
--- phase 4 starts at 800,000 rather than 400,000 — the ring would go on with
--- proportionally half as much fight left to spare.
Constants.LUCK_RING_HP_SOLO = 50000
Constants.LUCK_RING_HP = Constants.LUCK_RING_HP_SOLO

------------------------------------------
-- # ARENA
------------------------------------------

--- How far from Raksha we are ever willing to move.
---
--- The arena is instanced so there are no fixed bounds to work from — the boss
--- itself is the anchor. Constraining every movement target to this radius keeps
--- us manoeuvring around the middle, where there is room to dodge the next
--- mechanic, and stops the safe-tile search from sending us to the edges.
---
--- Kept deliberately tight: the wiki calls for central positioning, and staying
--- close forces tail sweeps (dodgeable) instead of trampling charges and shadow
--- bombs. Drifting wide is what made the bot look lost.
Constants.ARENA_RADIUS = 8

--- Home tiles: the fixed spots we fight from and return to.
---
--- Anchoring movement to Raksha meant the anchor itself moved, so "stay within
--- N tiles" drifted with him and positioning was never repeatable. Instead we
--- record a home tile once per fight (the safespot, offset from the dormant
--- boss) and treat THAT as the centre — dodges move off it, and we walk back
--- once the danger clears. `alternateOffsetX` is the fallback spot to use when
--- the primary is sitting under a hazard.
Constants.HOME = {
    alternateOffsetX = 8, -- shift this far along x when home is unsafe
    returnDistance = 5, -- drift beyond this and walk back
    returnEveryTicks = 3 -- pacing for the walk-back
}

------------------------------------------
-- # OBJECTS
------------------------------------------

Constants.OBJECTS = {
    --- War's Retreat portal to Raksha. core/wars_retreat.lua hardcodes the
    --- portal's object type to 0, so only id and name are needed.
    PORTAL = {
        id = 118585,
        --- Entered with Interact:Object(name, "Enter"), so this string has to
        --- match the in-game object exactly — wars_retreat terminates the
        --- script if the lookup fails.
        name = "Portal (Raksha)"
    },

    --- Security gate in the lobby (past the portal). Interacting with it starts
    --- the boss instance, the way Rasial's "Chamber doorway" does. Its presence
    --- is also how we detect the lobby, since we have no fixed lobby coords.
    SECURITY_GATE = {
        id = 118556,
        type = 0,

        --- Confirmed: same as Rasial's doorway. "Enter" starts a fresh instance
        --- (and pops the create-instance dialog, handled in startNewInstance);
        --- "Rejoin last instance" re-enters the existing one without resetting
        --- its ~1 hour timer.
        name = "Security gate",
        action = "Enter",
        rejoinAction = "Rejoin last instance"
    },

    --- Ground bombs dropped during the 33709 bomb phase. Each covers a 2x2 area,
    --- so we dodge to a tile clear of every one of them.
    BOMB_HAZARD = {
        id = 4566,
        type = 4,
        size = 2 -- 2x2 footprint
    }
}

------------------------------------------
-- # ADDS (presence-based mechanics)
------------------------------------------

--- Entities we respond to by their presence rather than a boss animation. The
--- handler checks for these every tick, clears them, then returns to the boss.
Constants.ADDS = {
        --- Shadow anima pool — an NPC (confirmed) that spawns during the 33709 bomb
    --- phase and must be killed. All of them need to die, AoE'd down with Threads
    --- of Fate, while we keep dodging the bombs. See mechanics.handleAnimaPools.
    ---
    --- The ability list itself lives in mechanics.lua (POOL_DPS_ABILITIES) with
    --- Threads of Fate at the head, so there is no separate `aoeAbility` here
    --- any more: having the AoE in one place and the rest of the damage in
    --- another meant that whenever Threads was on cooldown we silently dropped
    --- back to killing pools one at a time.
    ANIMA_POOL = {
        id = 27354,
        type = 1, -- NPC (confirmed)
        name = "Shadow anima pool",
        action = "Attack",
        range = 60,

        -- Standing in a pool is ~1500 damage PER TICK, and we deliberately move
        -- toward them to kill them — so they have to be a movement hazard too or
        -- we cook ourselves while clearing. Small clearance: enough to stay off
        -- them, still far inside Necromancy's attack range.
        avoidClearance = 2,

        -- Threshold to START clearing, per phase. PHASE 3 ONLY — see
        -- killThresholdByPhase below. Once started we always clear to ZERO.
        killThreshold = 10,

        -- Phase 3 endgame. Below this HP we're close enough to the phase 4
        -- transition (200k) that pushing damage straight into Raksha beats
        -- spending the time on pools — he'll phase before they matter.
        skipBelowHpInPhase3 = 325000,

        -- POOLS ARE CLEARED IN PHASE 3 ONLY.
        --
        -- math.huge means never for that phase, and it is a hard never: the
        -- siphon chat cue does NOT override it (see handleAnimaPools, which
        -- returns before the siphon check). That was the missing piece — a huge
        -- threshold alone still let a siphon announcement drag us off the boss.
        --
        -- Phase 3 is the only phase where they earn the detour: 8 spawn per
        -- sweep and he siphons after every special, so the heal and the stacking
        -- damage buff actually add up. In phases 1 and 2 the pools do little
        -- enough that walking to them costs more DPS than the siphon does, and
        -- in phase 4 leaving the tile beside Raksha is what flips him from the
        -- dodgeable tail sweep to prayer-disabling shadow bombs.
        --
        -- They remain a MOVEMENT hazard in every phase (avoidClearance above) —
        -- ignoring them means not hunting them, not standing in them.
        killThresholdByPhase = {
            [1] = math.huge,
            [2] = math.huge,
            [3] = 3,
            [4] = math.huge
        },

        -- Use Dive to close the gap when the nearest pool is further than this
        -- many tiles (and Dive/Bladed Dive is actually off cooldown). The
        -- destination is always hazard-checked first.
        diveDistance = 8,

        -- Surge is the backup when Dive is on cooldown — they share no cooldown,
        -- so between them we're rarely reduced to walking. Lower threshold than
        -- diveDistance because Surge follows our facing rather than a chosen
        -- tile, so it's the blunter of the two and worth using sooner.
        surgeDistance = 6
    },
    --- Shadow Energy: click each with the "Expel" action to remove it; once all
    --- are gone, reattack Raksha. Detected by id, actioned by name via
    --- Interact:NPC, so `name` must match the in-game NPC name exactly.
    SHADOW_ENERGY = {
        name = "Shadow energy",
        action = "Expel",
        id = 27356,
        type = 1, -- NPC; unconfirmed, verify against a recon entities.csv row
        range = 30,
        delay = 1,
        useTicks = false
    },

    --- Shadow manifestation: kill it fast. Stun it with Soul Strike (needs a
    --- residual soul; Soul Sap it first to generate one) then DPS it down. See
    --- mechanics.handleShadowManifestation.
    SHADOW_MANIFESTATION = {
        name = "Shadow manifestation",
        action = "Attack",
        id = 27355,
        type = 1, -- NPC
        range = 60
    }
}

------------------------------------------
-- # PRAYER FLICKER THREATS
------------------------------------------

--- Threat table for core/prayer_flicker.lua.
---
--- TIMING CAVEAT: `delay` (ticks before the prayer is needed) and `duration`
--- (ticks it stays up) are starting estimates, not measured values. They are
--- the two numbers most likely to need tuning. The recon tool's `_boss.csv`
--- records player HP alongside each boss animation change, so the real gap
--- between animation and damage can be read straight off a logged kill.
---
--- Praying every auto attack means dropping Soul Split for those ticks. If the
--- healing loss outweighs the damage taken, drop the melee entry first — it is
--- typically the smallest hit of the three.
Constants.PRAYER_FLICKER = {
    defaultPrayer = PrayerFlicker.CURSES.SOUL_SPLIT,
    threats = {
        {
            name = "Raksha magic auto",
            type = "Animation",
            priority = 10,
            prayer = PrayerFlicker.CURSES.DEFLECT_MAGIC,
            npcId = Constants.BOSS.id,
            id = Constants.ANIM.ATTACK_MAGIC,
            delay = 0,
            duration = 2
        }, {
            name = "Raksha ranged auto",
            type = "Animation",
            priority = 10,
            prayer = PrayerFlicker.CURSES.DEFLECT_RANGED,
            npcId = Constants.BOSS.id,
            id = Constants.ANIM.ATTACK_RANGED,
            delay = 0,
            duration = 2
        }, 
        {
            name = "Raksha melee auto",
            type = "Animation",
            priority = 9,
            prayer = PrayerFlicker.CURSES.DEFLECT_MELEE,
            npcId = Constants.BOSS.id,
            id = Constants.ANIM.ATTACK_MELEE,
            delay = 0,
            duration = 2
        }, 
        {
            -- Deflect Magic reduces the bomb's initial magic hit. Higher
            -- priority than the autos so it wins if they overlap.
            name = "Shadow bomb impact",
            type = "Animation",
            priority = 20,
            prayer = PrayerFlicker.CURSES.DEFLECT_MAGIC,
            npcId = Constants.BOSS.id,
            id = Constants.ANIM.SHADOW_BOMBARDMENT,
            delay = 0,
            duration = 4
        }
    }
}

------------------------------------------
-- # MECHANIC DEFINITIONS
------------------------------------------

--- Tiles from Raksha we have to reach to be clear of the tail sweep, used by
--- both `escapeSweepWhenNotTargeting` and `walkFromBossWhenNotTargeting` so the
--- two routes can never disagree about what "out of it" means.
---
--- The sweep is a 7x7 centred on Raksha, so +/-3 tiles — but every distance here
--- is measured against his REPORTED tile (Tile_XYZ), and for a 5x5 NPC it is not
--- certain whether that is his centre or a corner. The rest of this file assumes
--- centre (PHASE4.homeOffsetX of 4 is described as "2 tiles off the edge of his
--- blocked 5x5", which only works from the centre), and on that reading 5 would
--- do. This is 7 because the cost of being wrong is asymmetric: two extra tiles
--- costs nothing — Necromancy reaches ~10, so we stay in range of the add we
--- were killing — while being two tiles short means eating a sweep that also
--- disables prayers. Tune down if the logs show us clearing it comfortably.
Constants.TAIL_SWEEP_CLEARANCE = 7

--- Clearance for PHASE 4 escapes, two tiles further out than everywhere else.
---
--- Phase 4 is the one phase we take the sweep from melee range: we hold the home
--- tile four out and the escape is a short hop, so any shortfall in it leaves us
--- inside. Observed in play — a Dive to the seven tile ring still got clipped.
---
--- Two tiles is also exactly the error the note above worries about. If the
--- reported tile is a CORNER of his 5x5 rather than the centre, a tile seven
--- from it can be barely five from where the sweep is really centred, and five
--- is not enough. Nine absorbs that either way.
---
--- Still inside Necromancy's ~10 tile reach, so the rotation keeps hitting him
--- from out here and the extra distance costs no damage. Left at 7 for phases
--- 1-3, where we are usually already off him on an add and moving further only
--- risks dropping the add out of range.
Constants.TAIL_SWEEP_CLEARANCE_P4 = 9

--- Tiles to retreat when a sweep answer's movement ability is on cooldown.
---
--- Escape has a long cooldown next to how often Raksha sweeps at melee range, so
--- "Escape is down" is the common case, not the rare one. It used to mean we did
--- not move AT ALL: runStep logged the ability as unavailable and the sequence
--- marched on to the reattack, so we stood in the 7x7 and wore it.
---
--- Five tiles, measured from where we STAND rather than from Raksha. Phase 4
--- holds a tile PHASE4.homeOffsetX (4) east of him, so five more puts us nine
--- out — which is TAIL_SWEEP_CLEARANCE_P4 exactly, and that agreement is
--- load-bearing rather than tidy. clearOfSweepRadius latches the "we are clear,
--- stop moving" flag at the phase 4 clearance, so a retreat that stopped short
--- of it would never satisfy the latch and we would shuffle in and out for the
--- rest of the animation. Change one of these two and change the other.
---
--- Still inside the phase 4 arenaRadius of 10, and within Necromancy's ~10 tile
--- reach so the rotation keeps hitting him on the way back in.
Constants.TAIL_SWEEP_FALLBACK_WALK = 5

--- How the fight loop should respond to each mechanic animation.
---
--- kind:
---   "instant"   fire once on the animation, then done
---   "sequence"  fire a list of abilities on consecutive ticks
---   "sustained" stay in a behaviour for a while after the animation
---
--- `retriggerAfter` guards against re-firing while the same animation is still
--- playing: the same mechanic will not trigger again within that many ticks.
--- Tail sweep note: it is a 7x7 AoE centred on Raksha, used when you are in
--- melee range, so clearing it means getting at least four tiles out. Escape and
--- Surge both cover that. It is typeless and disables prayers unless
--- Anticipation or Freedom is active first — 33707 already answers with
--- Freedom; 33706 answers with Escape alone, per observed usage, so it trades
--- the prayer-disable for a shorter, cheaper response. Adding a counter there is
--- an option if the prayer drop proves costly.
Constants.MECHANICS = {
    -- `exclusive = true` means the mechanic owns the fight until it completes:
    -- while it's running, the add killers (anima pools, manifestation, Shadow
    -- Energy) are skipped so they can't steal the target or the movement
    -- mid-response. The pools can always be killed afterwards. NOT set on BOMBS,
    -- which only moves us — pools keep dying throughout that phase.
    [Constants.ANIM.TAIL_SWEEP_ESCAPE] = {
        name = "Tail Sweep",
        -- A sequence, not a one-shot: Escape teleports us out of the sweep AND
        -- drops our target, so without the reattack we just stood there doing
        -- nothing until the rotation happened to re-acquire.
        kind = "sequence",
        steps = {
            -- Escape only clears the sweep when we're actually on the boss —
            -- it moves away from whatever we're TARGETING. While we're on a
            -- manifestation, pool or add we walk clear of his 7x7 instead
            -- (`walkFromBossWhenNotTargeting`), after a 2 tick hold. Walking
            -- costs no global cooldown, so it doesn't interrupt the add.
            {
                ability = "Escape",
                walkFromBossWhenNotTargeting = Constants.TAIL_SWEEP_CLEARANCE,
                delayWhenNotTargeting = 2,
                wait = 2
            },
            {attackBoss = true}
        },
        priority = 50,
        exclusive = true,
        useTicks = true,

        -- Not on Raksha when this starts (killing the manifestation, clearing
        -- pools): get out of the 7x7 immediately, by Dive, then tile-targeted
        -- Surge, then walking. See Mechanics:escapeSweep.
        --
        -- Handled in Mechanics:runActive rather than as a step, and retried
        -- every tick, because the whole point is skipping the 2 tick pre-delay
        -- above: waiting it out and then WALKING loses the race with the
        -- animation, which is why we kept eating sweeps while on the add.
        escapeSweepWhenNotTargeting = Constants.TAIL_SWEEP_CLEARANCE,

        -- The step above that actually MOVES us. ensureClearOfSweep waits on the
        -- sequence only while this ability can genuinely fire; the moment it
        -- can't, walking takes over. See Mechanics:ensureClearOfSweep.
        sweepMover = "Escape"
        -- retriggerAfter = 0
    },

    [Constants.ANIM.TAIL_SWEEP_FREEDOM] = {
        -- The other tail sweep variant. Anticipation first (it prevents the
        -- stun/prayer-disable), then hold a full 2 SECONDS before Surging clear.
        -- `waitMs` is real time rather than ticks so that delay is exact.
        -- Surge drops our target, so we reattack afterwards or we'd just stand
        -- there once we land.
        name = "Tail Sweep (Anticipation + Surge)",
        kind = "sequence",
        steps = {
            {ability = "Anticipation", waitMs = 2000},
            -- Same reasoning as the other sweep: Surge follows our facing, so
            -- while we're on an add it won't clear a sweep centred on Raksha.
            {ability = "Surge", walkFromBossWhenNotTargeting = Constants.TAIL_SWEEP_CLEARANCE, wait = 2},
            {attackBoss = true}
        },
        priority = 50,
        exclusive = true,
        retriggerAfter = 5,

        -- See the note on the other sweep. It matters more here: this variant
        -- holds on Anticipation for a full 2000ms before it moves us at all, so
        -- while we were on the manifestation that was two seconds of standing in
        -- the 7x7 before we even started walking out. escapeSweep jumps straight
        -- past it.
        escapeSweepWhenNotTargeting = Constants.TAIL_SWEEP_CLEARANCE,

        -- Surge is this variant's mover — see the note on the other sweep.
        sweepMover = "Surge"
    },

    [Constants.ANIM.INSTAKILL_BIND] = {
        -- Freedom breaks the bind so we can run from the 2789 insta-kill zone.
        -- The actual MOVE is handled at top priority in mechanics.handleInstakill;
        -- this just guarantees the bind is broken the moment the anim plays, even
        -- if we're not yet inside the highlight.
        name = "Insta-kill Bind (Freedom)",
        kind = "instant",
        ability = "Freedom",
        priority = 90,
        exclusive = true,
        retriggerAfter = 3
    },

    [Constants.ANIM.BOMBS] = {
        name = "Bombs",
        kind = "sustained",
        -- Dodge the 2x2 ground bombs (object 4566): if we are standing within
        -- `escapeDistance` of any bomb, walk to the nearest tile that clears
        -- every bomb (and every floor shadow). Moving does not use the global
        -- cooldown, so we keep attacking through it. Anima pools that spawn this
        -- phase are killed separately by mechanics.handleAnimaPools, which is
        -- presence-based and runs regardless of this animation.
        behaviour = "dodgeBombs",
        hazard = "BOMB_HAZARD",
        escapeDistance = 5, -- tiles clear of a bomb's tile (covers the 2x2 + margin)
        moveEveryTicks = 1, -- re-evaluate every tick; bombs drop quickly
        priority = 70,
        duration = 20,
        retriggerAfter = 1
    },

    [Constants.ANIM.SHADOW_BOMBARDMENT] = {
        name = "Shadow Bomb / Bombardment",
        kind = "sequence",

        -- Owns the fight for the whole Freedom -> Surge -> reattack sequence,
        -- including the hold ticks between steps, so nothing re-targets a pool
        -- mid-escape.
        priority = 90,
        exclusive = true,

        -- Freedom breaks the stun + bind immediately, then hold 2 ticks before
        -- Surging clear of the shadow anima cloud that forms at our feet
        -- (centred on us, so any direction escapes the 5x5); reattack
        -- re-acquires Raksha, since Surge drops the target. `wait` is the ticks
        -- to hold after a step before the next one (default 1).
        steps = {
            {ability = "Freedom", wait = 4, useTicks = true},
            {ability = "Surge"},
            {attackBoss = true}
        },
        retriggerAfter = 10
    }
}

------------------------------------------
-- # PHASE 4 MECHANIC OVERRIDES
------------------------------------------

--- Mechanics that behave differently in the final phase. Looked up first, with
--- Constants.MECHANICS as the fallback, so only the entries that actually differ
--- need repeating here.
---
--- Phase 4 is deliberately the simplest phase in the file: hold the east tile,
--- flick prayers against his autos, Escape both tail sweep variants, walk back,
--- and keep hitting him. Everything that used to relocate us around the arena
--- has been removed — the relocations themselves were what let him switch to
--- shadow bombs, so the fix for the bombs is to never leave the tile.
---
--- Both sweep variants therefore answer the same way: Escape out, reattack, and
--- let returnHome walk us back onto the spot. Bombs and bombardment need no
--- phase 4 entry at all — staying adjacent means they don't happen, and if one
--- does the general definitions still handle it.
Constants.MECHANICS_BY_PHASE = {
    [4] = {
        [Constants.ANIM.TAIL_SWEEP_FREEDOM] = {
            name = "Tail Sweep (P4) — Escape",
            kind = "sequence",
            steps = {
                {
                    ability = "Escape",
                    walkFromBossWhenNotTargeting = Constants.TAIL_SWEEP_CLEARANCE_P4,
                    retreatWhenUnavailable = Constants.TAIL_SWEEP_FALLBACK_WALK,
                    wait = 4
                },
                {attackBoss = true}
            },
            priority = 60,
            exclusive = true,
            retriggerAfter = 5,
            escapeSweepWhenNotTargeting = Constants.TAIL_SWEEP_CLEARANCE_P4,
            sweepMover = "Escape"
        },

        -- The detonation dome. If the bar above Raksha fills it is an instant
        -- kill, so this is a pure damage race: hold the target on him and let
        -- the rotation and the cooldown filler hammer it. Marked exclusive so
        -- pools and adds can't pull us off mid-burn.
        [Constants.ANIM.DOME] = {
            name = "Shadow Detonation Dome — BURN",
            kind = "sustained",
            behaviour = "burnDome",
            priority = 95,
            exclusive = true,
            duration = 30,
            retriggerAfter = 5
        },

        -- Shadow bomb, answered WITHOUT a Surge.
        --
        -- The general definition Surges out of the anima cloud, and in phase 4
        -- that is the wrong tool: Surge travels along our FACING, which nothing
        -- in the script controls, so it lands us on whichever side of Raksha we
        -- happened to be pointing at. The whole phase is built on holding ONE
        -- tile east of him — every other side gives up the adjacency that keeps
        -- him tail sweeping instead of bombing — so a movement that picks its
        -- own direction cannot be used here.
        --
        -- Stepping back instead keeps us on the line we are already on, which in
        -- phase 4 is due east. It clears the 5x5 cloud centred on us just as
        -- well, costs no global cooldown, and returnHome walks us back onto the
        -- tile the moment the sequence ends.
        --
        -- Worth saying plainly: this should be rare. Bombs only come out while
        -- we are off melee distance, so seeing this fire regularly means we are
        -- not holding the tile in the first place.
        [Constants.ANIM.SHADOW_BOMBARDMENT] = {
            name = "Shadow Bomb (P4) — Freedom + step east",
            kind = "sequence",
            steps = {
                {ability = "Freedom", wait = 4, useTicks = true},
                {retreat = Constants.TAIL_SWEEP_FALLBACK_WALK, wait = 2},
                {attackBoss = true}
            },
            priority = 90,
            exclusive = true,
            retriggerAfter = 10
        }
    }
}

------------------------------------------
-- # PHASE STRUCTURE
------------------------------------------

--- Reference only; no thresholds are known yet, so nothing keys off this.
--- Bomb behaviour differs by phase:
---   Phase 1    single bomb, once per cycle
---   Phase 2-3  bombardment of 3-7 bombs, count scaling with anima absorbed
---   Phase 4    single bomb again, and only while outside melee distance
--- The dodge is the same either way, so the handler does not branch on phase.
--- What may need per-phase tuning is `duration`, since a bombardment of seven
--- bombs keeps the arena dangerous for longer than a single one.
Constants.PHASE_NOTES = {
    [1] = "Single bomb per cycle",
    [2] = "Bombardment, 3-7 bombs by anima absorbed",
    [3] = "Bombardment, 3-7 bombs by anima absorbed",
    [4] = "Single bomb, only when outside melee distance"
}

------------------------------------------
-- # STILL NEEDED
------------------------------------------

--- Explicitly unknown. Nothing in the codebase may assume these until filled in.
Constants.PENDING = {
    "BLOCKING: exact War's Retreat portal NAME string (id 118585 is known)",
    "Confirm ANIMA_POOL object type (assumed 1)",
    "Lobby/entry coordinates and how the arena instance is detected",
    "Marked-tile object ID for the incoming bomb (the green arrow marker), so " ..
        "the dodge can pre-empt the bomb rather than react to the pool",
    "Ground hazard object IDs for the 33709 bomb phase",
    "Boss max HP and phase-transition thresholds",
    "Item id for Raksha's head — the wiki has no id for it, so it is absent " ..
        "from LOOT in main.lua. Not blocking: Loot All takes the whole pile " ..
        "once the window is open, and it can never drop alone.",
    "Measured delay/duration for each prayer threat"
}

--- Arena bounds are deliberately absent. Nothing needs them: the mechanic
--- handlers anchor their positioning to Raksha's own tile, which is always
--- inside the arena. Recon derives observed bounds anyway, so they are
--- available as a sanity check if a handler ever does need them.

return Constants
