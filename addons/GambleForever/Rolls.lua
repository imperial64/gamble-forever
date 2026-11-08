-- Reading /roll results. Pure: no WoW API, so tests load it directly.
local _, ns = ...
local Rolls = {}
ns.Rolls = Rolls

-- Build a Lua pattern from the client's RANDOM_ROLL_RESULT ("%s rolls %d (%d-%d)" in English),
-- so the wording in other locales does not matter.
function Rolls.pattern(fmt)
    local s = (fmt or "%s rolls %d (%d-%d)"):gsub("([%(%)%.%-%+%[%]%^%$%?%*])", "%%%1")
    s = s:gsub("%%s", "(.+)")
    s = s:gsub("%%d", "(%%d+)")
    return "^" .. s .. "$"
end

-- name, value, lo, hi; or nil when the line is not a roll.
function Rolls.parse(pattern, text)
    local name, v, lo, hi = text:match(pattern)
    if name then return name, tonumber(v), tonumber(lo), tonumber(hi) end
end

-- Forever names carry a surname: roll lines and addon senders say "Efe Imperial" while
-- UnitName says "Efe". Either side may be the short form.
-- ponytail: two players sharing a first name would collide; compare GUIDs if that ever matters.
function Rolls.same(a, b)
    if not a or not b then return false end
    a, b = a:match("^[^%-]+"), b:match("^[^%-]+")  -- drop any "-Realm"
    if a == b then return true end
    if #a > #b then a, b = b, a end
    return b:sub(1, #a + 1) == a .. " "
end
