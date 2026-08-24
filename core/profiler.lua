--- @module "Pass Profiler"
--- @version 1.0.0
--- Wall-clock cost of named sections of one main-loop pass.
---
--- Built while chasing a Raksha fight that was managing ONE main-loop pass per
--- 600ms game tick and skipping ~44% of ticks outright. Reading the source had
--- already produced two wrong answers; measuring produced the right one in a
--- single trip (PlayerManager:_checkThreshold, reading four player stats per
--- call at ~47ms each).
---
--- Kept as a module rather than a local so a section can be timed inside any
--- file that takes part in the pass, not just the one that owns the loop.
---
--- Overhead is one os.clock() per mark. That is a userspace clock read, orders
--- of magnitude below the native game calls this exists to find.

local Profiler = {}

--- name -> {last, worst}
local entries = {}

--- Insertion order, so a section that has never been slow still gets listed.
local order = {}

--- Records the time since `startedAt` against `name`.
---
--- Returns a fresh clock reading so marks can be chained straight down a
--- function body:
---
---     local t = os.clock()
---     doThing()      ; t = Profiler.mark("thing", t)
---     doOtherThing() ; t = Profiler.mark("other", t)
---
--- @param name string
--- @param startedAt number os.clock() reading from before the section
--- @return number now os.clock() reading taken after the section
function Profiler.mark(name, startedAt)
    local now = os.clock()
    local ms = (now - startedAt) * 1000

    local entry = entries[name]
    if not entry then
        entry = {last = 0, worst = 0}
        entries[name] = entry
        order[#order + 1] = name
    end

    entry.last = ms
    if ms > entry.worst then entry.worst = ms end
    return now
end

--- All recorded sections, worst-first.
---
--- `worst` leads the sort because the shape of a starvation bug is a section
--- that is usually instant and occasionally blocks for most of a tick. An
--- average hides exactly that.
--- @return table[] rows {name, last, worst}
function Profiler.snapshot()
    local rows = {}
    for _, name in ipairs(order) do
        local entry = entries[name]
        rows[#rows + 1] = {name = name, last = entry.last, worst = entry.worst}
    end
    table.sort(rows, function(a, b) return a.worst > b.worst end)
    return rows
end

--- Clears every recorded section. Not called by the fight loop; here so a
--- caller can start a fresh measurement window (e.g. per kill).
function Profiler.reset()
    entries = {}
    order = {}
end

return Profiler
