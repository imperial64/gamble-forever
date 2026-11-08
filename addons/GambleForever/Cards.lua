-- Playing cards. Pure: no WoW API (uses the `bit` library, which both the client and LuaJIT have).
--   card id 0..51: suit * 13 + (value - 2), value 2..14 (14 = ace)
--   shoe: several decks in a fixed order; a roll picks the n-th card still in it and removes it
--   deck shuffle from a seed (poker), with a fingerprint published before the hand
--   hand ranking: best five of up to seven cards
local _, ns = ...
local Cards = {}
ns.Cards = Cards

local SUITS = { "hearts", "diamonds", "clubs", "spades" }
local SUIT_LETTER = { "h", "d", "c", "s" }
Cards.SUITS = SUITS

function Cards.value(id) return id % 13 + 2 end
function Cards.suit(id) return math.floor(id / 13) + 1 end
function Cards.make(value, suit) return (suit - 1) * 13 + (value - 2) end

local RANK_TEXT = { [11] = "J", [12] = "Q", [13] = "K", [14] = "A" }
function Cards.rankText(v) return RANK_TEXT[v] or tostring(v) end
function Cards.text(id) return Cards.rankText(Cards.value(id)) .. SUIT_LETTER[Cards.suit(id)] end
-- plain words for chat: "5 of clubs", "queen of hearts"
local RANK_NAME = { [11] = "jack", [12] = "queen", [13] = "king", [14] = "ace" }
function Cards.name(id)
    local v = Cards.value(id)
    return (RANK_NAME[v] or tostring(v)) .. " of " .. SUITS[Cards.suit(id)]
end

-- Kenney file name: card_<suit>_<A|02..10|J|Q|K>.png
function Cards.file(id)
    local v = Cards.value(id)
    local r = RANK_TEXT[v] or (v < 10 and ("0" .. v) or tostring(v))
    return ("card_%s_%s"):format(SUITS[Cards.suit(id)], r)
end

-- two hex digits per card
function Cards.pack(list)
    local out = {}
    for i, c in ipairs(list or {}) do out[i] = ("%02x"):format(c) end
    return table.concat(out)
end
function Cards.unpack(s)
    local out = {}
    for h in (s or ""):gmatch("%x%x") do out[#out + 1] = tonumber(h, 16) end
    return out
end

---------------------------------------------------------------- shoe

function Cards.newShoe(decks)
    return { decks = decks, removed = {}, left = decks * 52 }
end

-- The n-th card still in the shoe (1-based, in the shoe's fixed order) comes out.
function Cards.draw(shoe, n)
    if n < 1 or n > shoe.left then return nil end
    local seen = 0
    for i = 1, shoe.decks * 52 do
        if not shoe.removed[i] then
            seen = seen + 1
            if seen == n then
                shoe.removed[i] = true
                shoe.left = shoe.left - 1
                return (i - 1) % 52
            end
        end
    end
end

-- removed-card bitmap as hex, 4 cards per digit (78 digits for six decks)
function Cards.packShoe(shoe)
    local out = {}
    local total = shoe.decks * 52
    for i = 1, total, 4 do
        local v = 0
        for k = 0, 3 do if shoe.removed[i + k] then v = v + 2 ^ k end end
        out[#out + 1] = ("%x"):format(v)
    end
    return shoe.decks .. ":" .. table.concat(out)
end
function Cards.unpackShoe(s)
    local decks, hex = (s or ""):match("^(%d+):(%x*)$")
    decks = tonumber(decks)
    if not decks then return nil end
    local shoe = Cards.newShoe(decks)
    for d = 1, #hex do
        local v = tonumber(hex:sub(d, d), 16)
        for k = 0, 3 do
            if v % 2 == 1 then shoe.removed[(d - 1) * 4 + k + 1] = true; shoe.left = shoe.left - 1 end
            v = math.floor(v / 2)
        end
    end
    return shoe
end

---------------------------------------------------------------- seeded shuffle and fingerprint

local band, bxor, lshift, rshift = bit.band, bit.bxor, bit.lshift, bit.rshift
local function u32(x) return x < 0 and x + 4294967296 or x end

-- FNV-1a, 32 bit. Multiplication is split so doubles stay exact.
local function fnv(s)
    local h = 2166136261
    for i = 1, #s do
        h = u32(bxor(h, s:byte(i)))
        local lo, hi = h % 65536, math.floor(h / 65536)
        h = (lo * 16777619 + ((hi * 16777619) % 65536) * 65536) % 4294967296
    end
    return h
end
Cards.fnv = fnv

-- Fingerprint published before a hand. Two independent 32-bit hashes: finding a second seed
-- that matches both and also deals a better hand is far out of reach of a Lua client.
-- ponytail: not a cryptographic hash; swap in SHA-256 if strangers ever play for real stakes.
function Cards.commit(seed) return ("%08x%08x"):format(fnv(seed .. ":a"), fnv(seed .. ":b")) end

-- xorshift32 deck shuffle (Fisher-Yates); everyone can recompute it from the revealed seed.
function Cards.shuffle(seed)
    local x = fnv(seed)
    if x == 0 then x = 2463534242 end
    local function nextInt(n)
        x = bxor(x, lshift(x, 13)); x = bxor(x, rshift(x, 17)); x = bxor(x, lshift(x, 5))
        return u32(x) % n + 1
    end
    local deck = {}
    for i = 1, 52 do deck[i] = i - 1 end
    for i = 52, 2, -1 do
        local j = nextInt(i)
        deck[i], deck[j] = deck[j], deck[i]
    end
    return deck
end

---------------------------------------------------------------- hand ranking

Cards.HAND_NAMES = { "High card", "Pair", "Two pair", "Three of a kind", "Straight", "Flush",
    "Full house", "Four of a kind", "Straight flush" }

local function straightHigh(has)
    for hi = 14, 5, -1 do
        local ok = true
        for v = hi, hi - 4, -1 do
            if not has[v == 1 and 14 or v] then ok = false; break end
        end
        if ok then return hi end
    end
end

-- Score of the best five cards: { category 1..9, tiebreak values... }; compare with Cards.cmp.
function Cards.eval(cards)
    local counts, bySuit, has = {}, {}, {}
    for _, c in ipairs(cards) do
        local v, s = Cards.value(c), Cards.suit(c)
        counts[v] = (counts[v] or 0) + 1
        bySuit[s] = bySuit[s] or {}
        table.insert(bySuit[s], v)
        has[v] = true
    end
    local flush
    for _, vals in pairs(bySuit) do
        if #vals >= 5 then table.sort(vals, function(a, b) return a > b end); flush = vals end
    end
    if flush then
        local fh = {}
        for _, v in ipairs(flush) do fh[v] = true end
        local sf = straightHigh(fh)
        if sf then return { 9, sf } end
    end
    local groups = {}
    for v, n in pairs(counts) do groups[#groups + 1] = { n = n, v = v } end
    table.sort(groups, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.v > b.v end)
    local function kickers(skip, n)
        local out = {}
        local vals = {}
        for v in pairs(counts) do if not skip[v] then vals[#vals + 1] = v end end
        table.sort(vals, function(a, b) return a > b end)
        for i = 1, n do out[i] = vals[i] end
        return out
    end
    local g1, g2 = groups[1], groups[2]
    if g1.n == 4 then
        local k = kickers({ [g1.v] = true }, 1)
        return { 8, g1.v, k[1] }
    end
    if g1.n == 3 and g2 and g2.n >= 2 then return { 7, g1.v, g2.v } end
    if flush then return { 6, flush[1], flush[2], flush[3], flush[4], flush[5] } end
    local st = straightHigh(has)
    if st then return { 5, st } end
    if g1.n == 3 then
        local k = kickers({ [g1.v] = true }, 2)
        return { 4, g1.v, k[1], k[2] }
    end
    if g1.n == 2 and g2 and g2.n == 2 then
        local k = kickers({ [g1.v] = true, [g2.v] = true }, 1)
        return { 3, g1.v, g2.v, k[1] }
    end
    if g1.n == 2 then
        local k = kickers({ [g1.v] = true }, 3)
        return { 2, g1.v, k[1], k[2], k[3] }
    end
    local k = kickers({}, 5)
    return { 1, k[1], k[2], k[3], k[4], k[5] }
end

function Cards.cmp(a, b)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y and 1 or -1 end
    end
    return 0
end

function Cards.handName(score)
    if score[1] == 9 and score[2] == 14 then return "Royal flush" end
    return Cards.HAND_NAMES[score[1]]
end
