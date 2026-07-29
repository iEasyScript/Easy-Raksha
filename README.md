# Raksha, the Shadow Colossus — Necromancy Bosser

An automated Raksha (normal mode) script for MemoryError, written for **Necromancy**.

Runs the full loop: bank and prebuild at War's Retreat → enter the instance → fight all four phases with prayer flicking and mechanic responses → loot → teleport back → repeat.

---

## Requirements

### Account

| Requirement | Detail |
|---|---|
| **Combat style** | Necromancy only — there is no Melee/Range/Magic path |
| **Prayer book** | **Curses.** The prayer flicker uses Soul Split and Deflect Magic/Ranged/Melee. Standard prayers will not work |
| **Quest** | Raksha access (*Desperate Times*) |
| **Conjures** | Undead Army — Vengeful Ghost, Skeleton Warrior, Putrid Zombie |

### Installation

Place the folder so the module paths resolve:

```
Lua_Scripts/
├── api.lua
├── core/            ← shared modules (required)
└── raksha/
    ├── main.lua     ← run this
    ├── mechanics.lua
    ├── constants.lua
    ├── gui.lua
    └── config.json  ← created on first save
```

Run `raksha/main.lua`.

---

## Abilities required on your bar

The script activates these by name, so they must be **on an action bar** and unlocked. A missing ability is skipped rather than retried, so the rotation quietly degrades instead of erroring.

**Damage**
`Death Skulls` · `Living Death` · `Finger of Death` · `Touch of Death` · `Soul Sap` · `Volley of Souls` · `Bloat` · `Divert` · `Basic Attack`

**Setup / buffs**
`Ruination` · `Split Soul` · `Invoke Death` · `Invoke Lord of Bones` · `Darkness` · `Vengeance` · `Threads of Fate` · `Conjure Undead Army` · `Command Vengeful Ghost` · `Command Skeleton Warrior` · `Command Putrid Zombie`

**Utility / mechanics**
`Surge` · `Escape` · `Freedom` · `Anticipation` · `Dive` (or `Bladed Dive`) · `Ingenuity of the Humans` · `Weapon Special Attack` · `War's Retreat Teleport`

---

## Gear recommendations

### Weapon

**Omni guard** is what the rotation assumes — the `Weapon Special Attack` steps are built around its spec, gated on the debuff bar rather than the ability bar (the bar does not reflect spec cooldown).

### Pocket slot

Put **one** of these in your pocket slot. The script detects which one you're wearing and manages only that one — no configuration needed:

- **Scripture of Jas**
- **Scripture of Ful**
- **Erethdor's grimoire**

All three are treated as toggles: switched on for the fight and **off after the kill**, so they don't burn charges on the walk back.

### Other slots

| Slot | Recommendation | Notes |
|---|---|---|
| Ring | **Luck of the Dwarves** / Hazelmere's signet | Auto-equipped at **50,000 boss HP** so the drop rolls with it. Augmented `(i)` variants supported |
| Amulet | **Essence of Finality** | Optional. Used for its spec, preceded by Ingenuity of the Humans so it's free. Skipped cleanly if absent |
| Cape | Any Necromancy cape | |

---

## Inventory preset

Set up a **bank preset** at War's Retreat containing:

| Item | Amount | Notes |
|---|---|---|
| **Vulnerability bomb** | ~500 | Used on engage and in phase 4 |
| **Blue blubber jellyfish** | 10 | Emergency food |
| **Elder overload potion** | 1 | Any dose (1–6). Re-drunk automatically when the buff drops |
| **Adrenaline renewal** | 1 | Any dose. Funds Living Death in phases 2 and 4 |

Optional extras are pre-wired but commented out in `main.lua` — uncomment to enable:

- Lantadyme incense sticks
- Binding contract (blood reaver)
- Enhanced replenishment potion (alternative to Adrenaline renewal)

If you use the **Elder overload salve** instead of the potion, swap the ID list in `LOADOUT` (the salve IDs are in a comment directly above it) and the matching entry in `BUFFS`.

---

## Settings

Configured through the in-game GUI; saved to `raksha/config.json`.

### General

| Setting | Default | What it does |
|---|---|---|
| Bank PIN | *(empty)* | Leave blank if you have none |
| Wait for full HP | `true` | Don't leave War's Retreat below full health |
| Use Revolution | `false` | Hands damage to the action bar. The script still does setup, positioning, prayers, mechanics and food |

### Health / prayer thresholds

Health defaults are **deliberately high** (70/70/60% and 75% for Excalibur). Anima clouds ramp to ~2,000 per tick, pools are ~1,500 per tick, and even a countered shadow bomb lands ~6,000 — eating at 45% left no room to react.

### War's Retreat

| Setting | Default | Notes |
|---|---|---|
| Use prebuild | `true` | Build stacks on the dummies before entering |
| Use adrenaline crystal | `true` | |
| Summon conjures | `false` | Conjures are summoned in the lobby instead |
| Advanced movement | `false` | Surge/Dive shortcuts around War's Retreat. Saves a couple of seconds per trip; walking reaches every stop without it |
| Bank if inventory full | `false` | |

### Mechanics

| Setting | Default | Notes |
|---|---|---|
| Ignore anima pools | `false` | |
| Pool kill threshold | `10` | **Phase 3 only** — see below |
| Shadow trigger / safe range | `1` / `2` | Measured from the **edge** of the shadow's 4×4 box, not its centre. Keep small: large values create a huge exclusion zone and the script shuffles between tiles instead of attacking |
| Insta-kill trigger / safe range | `5` / `6` | For the 2789 ground highlight |
| Bomb escape distance | `5` | |

---

## How it fights

### Per-phase rotations

Each phase loads its own rotation, following the [PVME Necromancy guide](https://pvme.io/pvme-guides/rs3-full-boss-guides/raksha/necromancy/):

| Phase | HP | Opening line |
|---|---|---|
| 1 | 800k–600k | Bloat → Death Skulls → Volley → Soul Sap → Divert → Touch of Death → Soul Sap → Command Skeleton |
| 2 | 600k–400k | Living Death + Adrenaline renewal → Touch of Death → Death Skulls → Soul Sap → Finger ×2 |
| 3 | 400k–200k | Finger ×2 → Basic → Death Skulls → Bloat → Volley → Threads of Fate |
| 4 | 200k–0 | Adrenaline renewal → Living Death → Death Skulls → Finger ×2 → spec → Split Soul |

When a scripted rotation runs out it falls into an adaptive filler that fires the big cooldowns on recharge.

---

## Credits
- Easy
- Sonson for Core 
