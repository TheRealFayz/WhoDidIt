if WDI_DOPING_SKIP then return end -- DopingControl scan/addons.lua
-- Addons tab backend: finds out which raid addons the OTHER raiders run.
-- They do not run DopingControl, so detection rides only on what their own
-- addons send or answer:
--   BigWigs   prefix "BigWigs" (RAID): query "BWVQ BigWigs"; replies
--             "PEPO_BWVR <rev> <nick>", "BWVR <rev> <nick> <Fork>", the
--             old "MC:REV" style or a bare number. Any other BigWigs sync
--             proves presence without a version.
--   Threat    prefix "TWT": query "TWT_WHO"; replies "TWT_ME:<ver>";
--             passive "TWTVersion:<ver>" at login. (Server threat packets
--             use the prefix "TWT " with a trailing space - a different
--             prefix, ignored here.)
--   EPGP      shootyepgp, prefix "SEPGP_PREFIX" (GUILD): "VERSION;<ver>;<n>"
--             at the sender's login only; no query answer.
--   SuperWoW  prefix "SWOW_Q" (GUILD) is answered by shootyepgp on prefix
--             "SWOW_R" with "1" (SuperWoW present) or "0". A reply also
--             proves shootyepgp itself is installed.
--   Rinse     prefix "Rinse": query "REPORT_ADDON_VERSION", reply
--             "V_<ver>" (only the UpsiRinse fork answers).
-- Honest-unknown rule: silence is only "no reply" after a query window has
-- passed for a member who was in the group when the query went out;
-- before that the cell is unknown, and members who cannot answer (not in
-- the guild, a class that cannot dispel) are n/a.
-- The parsers, the evaluation and the query state machine are pure Lua 5.0
-- (dofile-loadable offline); the WoW wiring sits behind "if CreateFrame".

DopingControl = DopingControl or {}
local DC = DopingControl

DC_Addons = DC_Addons or {}
local A = DC_Addons

A.WINDOW        = 6    -- seconds a query waits for replies
A.AUTO_THROTTLE = 30   -- seconds between automatic queries
A.MAX_NAMES     = 400  -- passive-store cap (guild chatter from non-raiders)

-- slot ids (match DC.SLOTS_ADDONS)
A.SLOT_IDS = { "BIGWIGS", "TWT", "EPGP", "SUPERWOW", "RINSE" }

A.DISPELLERS = {
    DRUID = true, PRIEST = true, PALADIN = true, SHAMAN = true, MAGE = true,
}

-- prefix -> slot (hash lookup = the whole cost of an unrelated message)
local PREFIX_SLOT = {
    ["BigWigs"]      = "BIGWIGS",
    ["TWT"]          = "TWT",
    ["Rinse"]        = "RINSE",
    ["SEPGP_PREFIX"] = "EPGP",
    ["SWOW_R"]       = "SUPERWOW",
}
A.PREFIXES = PREFIX_SLOT

-- passive store: A.data[name][slot] = entry
A.data = {}
A.dataCount = 0

-- query state
A.query = { at = nil, sent = {}, roster = {} }
A.lastStatus = nil   -- last StartQuery verdict text (shown next to the button)

-- ------------------------------------------------------------------
-- text + version helpers
-- ------------------------------------------------------------------

-- Reply text from other people goes into UI strings: drop colour escapes,
-- trailing "<...>" decorations, control characters, and cap the length.
function A.Clean(s)
    if type(s) ~= "string" then
        return nil
    end
    s = string.gsub(s, "|", "")
    s = string.gsub(s, "[%c]", "")
    s = string.gsub(s, "%s*<.*>%s*$", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    if string.len(s) > 24 then
        s = string.sub(s, 1, 24)
    end
    if s == "" then
        return nil
    end
    return s
end

-- "r4521" / "v1.2.3" / "1.10.0" -> { 4521 } / { 1, 2, 3 } / { 1, 10, 0 };
-- anything else -> nil (shown raw, never compared).
function A.Segments(text)
    if type(text) ~= "string" then
        return nil
    end
    local s = string.gsub(text, "^[rRvV]", "")
    if not string.find(s, "^%d+$") and not string.find(s, "^%d+%.[%d%.]*%d$") then
        return nil
    end
    if string.find(s, "%.%.") then
        return nil
    end
    local out = {}
    for d in string.gfind(s, "(%d+)") do
        table.insert(out, tonumber(d))
    end
    return out
end

-- numeric segment compare, missing segments count as 0: -1 / 0 / 1
function A.Compare(a, b)
    local na, nb = table.getn(a), table.getn(b)
    local n = na
    if nb > n then
        n = nb
    end
    for i = 1, n do
        local x, y = a[i] or 0, b[i] or 0
        if x < y then
            return -1
        elseif x > y then
            return 1
        end
    end
    return 0
end

local function entry(text, variant, raw, channel)
    return {
        text = text,
        ver = A.Segments(text),
        variant = variant,
        raw = raw,
    }
end

-- ------------------------------------------------------------------
-- reply parsers. Each returns an entry table or nil (not a reply);
-- a second return value "query" marks the query messages themselves.
-- ------------------------------------------------------------------

function A.ParseBigWigs(msg)
    if type(msg) ~= "string" then
        return nil
    end
    local _, _, sync, rest = string.find(msg, "^(%S+)%s*(.*)$")
    if not sync then
        return nil
    end
    if sync == "BWVQ" then
        return nil, "query"
    end
    if not string.find(sync, "BWVR") then
        -- some other BigWigs sync (boss engaged, ...): presence, no version
        local e = entry("yes", nil, msg)
        e.presenceOnly = true
        return e
    end
    local rev, fork
    if string.find(rest, ":") then
        -- old style "MC:1234 BWL:1234": the highest number is the revision
        for d in string.gfind(rest, "(%d+)") do
            local n = tonumber(d)
            if rev == nil or n > rev then
                rev = n
            end
        end
        fork = "Legacy"
    elseif tonumber(rest) then
        rev = tonumber(rest)
        fork = "Legacy"
    else
        local f1, f2, f3
        local _, _, a, b, c = string.find(rest, "^(%S*)%s*(%S*)%s*(%S*)")
        f1, f2, f3 = a, b, c
        rev = tonumber(f1)
        if f3 and f3 ~= "" then
            fork = A.Clean(f3)
        elseif sync == "PEPO_BWVR" then
            fork = "Pepo"
        else
            fork = "unknown"
        end
    end
    if rev == nil or rev < 0 then
        -- reply without a usable revision (zone unknown): BigWigs is there
        local e = entry("yes", fork, msg)
        e.presenceOnly = true
        return e
    end
    return entry("r" .. rev, fork, msg)
end

function A.ParseTWT(msg)
    if type(msg) ~= "string" then
        return nil
    end
    if string.find(msg, "^TWT_WHO") then
        return nil, "query"
    end
    local _, _, v = string.find(msg, "^TWT_ME:(.+)$")
    if not v then
        _, _, v = string.find(msg, "^TWTVersion:(.+)$")
    end
    v = A.Clean(v)
    if not v then
        return nil
    end
    return entry(v, nil, msg)
end

function A.ParseRinse(msg)
    if type(msg) ~= "string" then
        return nil
    end
    if msg == "REPORT_ADDON_VERSION" then
        return nil, "query"
    end
    local _, _, v = string.find(msg, "^V_(.+)$")
    v = A.Clean(v)
    if not v then
        return nil
    end
    return entry(v, nil, msg)
end

function A.ParseEPGP(msg)
    if type(msg) ~= "string" then
        return nil
    end
    local _, _, v = string.find(msg, "^VERSION;([^;]+)")
    v = A.Clean(v)
    if v then
        return entry(v, nil, msg)
    end
    if string.find(msg, ";") then
        -- any other shootyepgp traffic (EP awards, ...) proves it runs
        local e = entry("yes", nil, msg)
        e.presenceOnly = true
        return e
    end
    return nil
end

-- "1" -> present, "0" -> absent; anything else is not an answer
function A.ParseSwow(msg)
    if msg == "1" then
        local e = entry("yes", nil, msg)
        e.flag = true
        return e
    elseif msg == "0" then
        local e = entry("no", nil, msg)
        e.flag = false
        return e
    end
    return nil
end

local PARSER = {
    BIGWIGS  = A.ParseBigWigs,
    TWT      = A.ParseTWT,
    RINSE    = A.ParseRinse,
    EPGP     = A.ParseEPGP,
    SUPERWOW = A.ParseSwow,
}

-- ------------------------------------------------------------------
-- passive store
-- ------------------------------------------------------------------
local function put(name, slot, e, now)
    local byName = A.data[name]
    if not byName then
        if A.dataCount >= A.MAX_NAMES then
            A.data = {}
            A.dataCount = 0
        end
        byName = {}
        A.data[name] = byName
        A.dataCount = A.dataCount + 1
    end
    local old = byName[slot]
    -- a presence-only hint never replaces a real version
    if e.presenceOnly and old and not old.presenceOnly then
        return false
    end
    e.at = now
    byName[slot] = e
    return true
end

-- OnAddonMessage(prefix, msg, channel, sender, now) -> changed (bool)
-- Early return on an unrelated prefix: one table lookup, no allocation.
function A.OnAddonMessage(prefix, msg, channel, sender, now)
    local slot = PREFIX_SLOT[prefix]
    if not slot or type(sender) ~= "string" or sender == A.own then
        return false
    end
    -- BigWigs itself only honours its syncs on RAID
    if slot == "BIGWIGS" and channel ~= "RAID" then
        return false
    end
    local e = PARSER[slot](msg)
    if not e then
        return false
    end
    e.channel = channel
    local changed = put(sender, slot, e, now)
    if slot == "SUPERWOW" then
        -- the responder lives inside shootyepgp: an answer proves it
        local p = entry("yes", nil, msg)
        p.presenceOnly = true
        p.channel = channel
        if put(sender, "EPGP", p, now) then
            changed = true
        end
    end
    return changed
end

-- drop everybody not in the given name set (members who left)
function A.Prune(nameSet)
    for name in pairs(A.data) do
        if not nameSet[name] then
            A.data[name] = nil
            A.dataCount = A.dataCount - 1
        end
    end
end

function A.Reset()
    A.data = {}
    A.dataCount = 0
    A.query = { at = nil, sent = {}, roster = {} }
    A.lastStatus = nil
end

-- ------------------------------------------------------------------
-- query
-- env = { now, inCombat, raid, party, guild, send(prefix, msg, channel),
--         roster = array of names }
-- StartQuery(env, auto) -> started (bool), reason (string|nil)
-- ------------------------------------------------------------------
function A.StartQuery(env, auto)
    local q = A.query
    if env.inCombat then
        A.lastStatus = "not in combat"
        return false, "in combat"
    end
    if q.at and env.now - q.at < A.WINDOW then
        return false, "query running"
    end
    if auto and q.at and env.now - q.at < A.AUTO_THROTTLE then
        return false, "throttled"
    end
    if not env.raid and not env.party then
        A.lastStatus = "not in a group"
        return false, "no group"
    end
    local send = env.send
    local chan = env.raid and "RAID" or "PARTY"
    local sent = {}
    if env.raid then
        pcall(send, "BigWigs", "BWVQ BigWigs", "RAID")
        sent.BIGWIGS = true
    end
    pcall(send, "TWT", "TWT_WHO", chan)
    sent.TWT = true
    pcall(send, "Rinse", "REPORT_ADDON_VERSION", chan)
    sent.RINSE = true
    if env.guild then
        pcall(send, "SWOW_Q", "1", "GUILD")
        sent.SUPERWOW = true
        sent.EPGP = true
    end
    local roster = {}
    local names = env.roster or {}
    for i = 1, table.getn(names) do
        roster[names[i]] = true
    end
    A.query = { at = env.now, sent = sent, roster = roster }
    A.lastStatus = nil
    return true
end

-- AutoCheck: the throttled variant used when the tab is opened
function A.AutoCheck(env)
    return A.StartQuery(env, true)
end

function A.IsSilent(name, slot, now)
    local q = A.query
    if not q.at or not q.sent[slot] or not q.roster[name] then
        return false
    end
    return now >= q.at + A.WINDOW
end

-- ------------------------------------------------------------------
-- own row: local knowledge instead of replies (several addons never
-- answer their own sender).
-- g = { loaded = function(name) -> bool, meta = function(addon, field),
--       bigwigsRev = number|nil, twtVer = string|nil, superwow = any }
-- returns slot -> entry | false (known not installed)
-- ------------------------------------------------------------------
function A.LocalEntries(g)
    local out = {}
    local function mk(text, variant)
        local e = entry(A.Clean(text) or "yes", variant, "local")
        e.islocal = true
        return e
    end
    -- BigWigs
    if g.loaded("BigWigs") then
        local rev = g.bigwigsRev or tonumber(g.meta("BigWigs", "X-Revision"))
        local fork = A.Clean(g.meta("BigWigs", "X-Fork"))
        if rev and rev > 0 then
            out.BIGWIGS = mk("r" .. rev, fork or "unknown")
        else
            out.BIGWIGS = mk("yes", fork or "unknown")
            out.BIGWIGS.presenceOnly = true
        end
    else
        out.BIGWIGS = false
    end
    -- threat meter
    if g.twtVer then
        out.TWT = mk(g.twtVer)
    elseif g.loaded("TWThreat") then
        out.TWT = mk(g.meta("TWThreat", "Version") or "yes")
    else
        out.TWT = false
    end
    -- shootyepgp
    if g.loaded("shootyepgp") then
        out.EPGP = mk(g.meta("shootyepgp", "Version") or "yes")
    else
        out.EPGP = false
    end
    -- SuperWoW: a global the DLL sets, no version needed
    if g.superwow then
        local e = mk("yes")
        e.flag = true
        out.SUPERWOW = e
    else
        local e = mk("no")
        e.flag = false
        out.SUPERWOW = e
    end
    -- Rinse (the fork first: it is the one that answers queries)
    if g.loaded("UpsiRinse") then
        out.RINSE = mk(g.meta("UpsiRinse", "Version") or "yes")
    elseif g.loaded("Rinse") then
        out.RINSE = mk(g.meta("Rinse", "Version") or "yes")
    else
        out.RINSE = false
    end
    return out
end

-- ------------------------------------------------------------------
-- evaluation
-- ------------------------------------------------------------------

local function variantKey(e)
    return e.variant or ""
end

-- Group the present entries of one slot by fork/variant and find the
-- reference variant (most members, ties broken by name) plus the newest
-- parseable version inside each variant.
local function buildGroups(list)
    local byVar, vars = {}, {}
    for i = 1, table.getn(list) do
        local e = list[i]
        local k = variantKey(e)
        local g = byVar[k]
        if not g then
            g = { key = k, count = 0, parseable = 0, uniform = true,
                  first = e.text, best = nil }
            byVar[k] = g
            table.insert(vars, g)
        end
        g.count = g.count + 1
        if e.text ~= g.first then
            g.uniform = false
        end
        if e.ver then
            g.parseable = g.parseable + 1
            if not g.best or A.Compare(e.ver, g.best.ver) > 0 then
                g.best = e
            end
        end
    end
    local ref
    for i = 1, table.getn(vars) do
        local g = vars[i]
        if not ref or g.count > ref.count
           or (g.count == ref.count and g.key < ref.key) then
            ref = g
        end
    end
    return byVar, ref
end

-- Decide check / bang for one present entry. Returns mark, note.
local function markFor(e, byVar, ref)
    if e.flag ~= nil then
        return "check", nil   -- SuperWoW has no version
    end
    local g = byVar[variantKey(e)]
    if g ~= ref then
        local who = (e.variant and e.variant ~= "") and e.variant or "other"
        local refName = (ref.key ~= "") and ref.key or "main"
        return "bang", "fork " .. who .. " (the raid mostly runs "
            .. refName .. ", newest " .. (ref.best and ref.best.text or ref.first) .. ")"
    end
    if e.ver then
        if g.best and A.Compare(e.ver, g.best.ver) < 0 then
            return "bang", "newest in raid: " .. g.best.text
        end
        return "check", nil
    end
    -- unparseable text: fine only when nothing different is around
    if g.parseable == 0 and g.uniform then
        return "check", nil
    end
    return "bang", "version cannot be compared"
        .. (g.best and (" (newest in raid: " .. g.best.text .. ")") or "")
end

local NA_CLASS  = "this class cannot dispel, so Rinse is not expected"
local NA_GUILD  = "not in your guild - shootyepgp only talks on guild chat"
local NA_NOGLD  = "you are not in a guild - this check needs guild chat"

-- Annotate(players, ctx): sets p.addons[slot] and p.addonsAnswered on every
-- player table. ctx:
--   now          clock
--   own          own character name (nil in test mode)
--   ownEntries   LocalEntries result (or nil)
--   myGuild      bool, I am in a guild
--   inGuild(p)   bool, this player is in my guild
--   lookup(p, slot) -> entry | nil
--   silent(p, slot) -> bool (queried, window over, no reply)
--   queryAt      query time (nil = nothing asked yet)
function A.Annotate(players, ctx)
    local n = table.getn(players)
    local resolved = {}     -- resolved[i][slot] = entry | false | "na" ... see below
    local lists = {}        -- present entries per slot (for the groups)
    for s = 1, table.getn(A.SLOT_IDS) do
        lists[A.SLOT_IDS[s]] = {}
    end
    local info = {}         -- info[i][slot] = { kind=..., e=..., why=... }

    for i = 1, n do
        local p = players[i]
        local row = {}
        info[i] = row
        local isOwn = ctx.own ~= nil and p.name == ctx.own and ctx.ownEntries
        for s = 1, table.getn(A.SLOT_IDS) do
            local slot = A.SLOT_IDS[s]
            local r
            if p.online == false then
                r = { kind = "unknown", why = "offline" }
            elseif slot == "RINSE" and not A.DISPELLERS[p.class or ""] then
                r = { kind = "na", why = NA_CLASS }
            elseif isOwn then
                local e = ctx.ownEntries[slot]
                if e then
                    r = { kind = "present", e = e }
                    if not e.presenceOnly then
                        table.insert(lists[slot], e)
                    end
                else
                    r = { kind = "missing",
                          why = "not installed on your own character" }
                end
            elseif (slot == "EPGP" or slot == "SUPERWOW")
                   and not ctx.inGuild(p) then
                r = { kind = "na", why = ctx.myGuild and NA_GUILD or NA_NOGLD }
            else
                local e = ctx.lookup(p, slot)
                if e then
                    r = { kind = "present", e = e }
                    if not e.presenceOnly then
                        table.insert(lists[slot], e)
                    end
                elseif ctx.silent(p, slot) then
                    r = { kind = "missing" }
                else
                    local why
                    if ctx.queryAt then
                        why = "waiting for a reply, or this addon was not"
                            .. " queried in this kind of group"
                    else
                        why = "not asked yet - use Check addons"
                    end
                    r = { kind = "unknown", why = why }
                end
            end
            row[slot] = r
        end
    end

    -- newest per slot and variant
    local groups, refs = {}, {}
    for s = 1, table.getn(A.SLOT_IDS) do
        local slot = A.SLOT_IDS[s]
        if table.getn(lists[slot]) > 0 then
            groups[slot], refs[slot] = buildGroups(lists[slot])
        end
    end

    for i = 1, n do
        local p = players[i]
        local out = {}
        local answered = false
        for s = 1, table.getn(A.SLOT_IDS) do
            local slot = A.SLOT_IDS[s]
            local r = info[i][slot]
            local res
            if r.kind == "present" then
                local e = r.e
                if e.flag == false then
                    res = { status = "missing", text = e.text, raw = e.raw,
                            at = e.at, islocal = e.islocal,
                            why = e.islocal and "SuperWoW is not loaded"
                                or "shootyepgp reports: no SuperWoW" }
                    answered = true
                else
                    local mark, note, newest
                    if e.presenceOnly then
                        -- present, version unknown: fine unless somebody
                        -- else reported one to compare against
                        if refs[slot] and refs[slot].best then
                            mark = "bang"
                            newest = refs[slot].best.text
                            note = "version unknown (newest in raid: "
                                .. newest .. ")"
                        else
                            mark = "check"
                        end
                    else
                        mark, note = markFor(e, groups[slot], refs[slot])
                        local g = groups[slot][variantKey(e)]
                        newest = g.best and g.best.text or nil
                    end
                    res = { status = (mark == "check") and "ok" or "old",
                            mark = mark, text = e.text, raw = e.raw,
                            at = e.at, variant = e.variant,
                            islocal = e.islocal, note = note,
                            presenceOnly = e.presenceOnly,
                            newest = newest }
                    answered = true
                end
            elseif r.kind == "missing" then
                res = { status = "missing", why = r.why
                    or "no reply - addon missing, or an old version / fork"
                       .. " that does not answer" }
            elseif r.kind == "na" then
                res = { status = "na", why = r.why }
            else
                res = { status = "unknown", why = r.why }
            end
            out[slot] = res
        end
        p.addons = out
        p.addonsAnswered = answered
    end
end

-- ------------------------------------------------------------------
-- WoW wiring
-- ------------------------------------------------------------------

-- the real-game ctx: passive store + query state + guild lookup
function A.RealCtx(env)
    local now = env.now
    return {
        now = now,
        own = env.own,
        ownEntries = env.ownEntries,
        myGuild = env.myGuild,
        inGuild = env.inGuild,
        queryAt = A.query.at,
        lookup = function(p, slot)
            local byName = A.data[p.name]
            return byName and byName[slot] or nil
        end,
        silent = function(p, slot)
            return A.IsSilent(p.name, slot, now)
        end,
    }
end

-- the simulated raid: players carry p.addonSim = { guild = bool,
-- <slot> = entry (replied) | false (queried, silent) | nil (unknown) }
function A.SimCtx(now)
    return {
        now = now,
        myGuild = true,
        queryAt = now,
        inGuild = function(p)
            return p.addonSim ~= nil and p.addonSim.guild == true
        end,
        lookup = function(p, slot)
            local v = p.addonSim and p.addonSim[slot]
            if type(v) ~= "table" then
                return nil
            end
            local e = entry(v.text, v.variant, "sim: " .. v.text)
            e.flag = v.flag
            e.presenceOnly = v.presenceOnly
            e.at = now
            return e
        end,
        silent = function(p, slot)
            return p.addonSim ~= nil and p.addonSim[slot] == false
        end,
    }
end

-- Annotate a store's players for display (called before the model builds).
function A.AnnotateStore(store, env)
    if not store or not store.players then
        return
    end
    if store.source == "sim" then
        A.Annotate(store.players, A.SimCtx(env and env.now or 0))
        return
    end
    A.Annotate(store.players, A.RealCtx(env))
    -- evict against the live roster (not the store: before the first scan
    -- finishes the store is empty and would wipe everything)
    if env and env.roster and table.getn(env.roster) > 0 then
        local set = {}
        for i = 1, table.getn(env.roster) do
            set[env.roster[i]] = true
        end
        A.Prune(set)
    end
end

-- tooltip/age helper (pure): seconds -> "5s ago" / "2m ago" / "1h ago"
function A.AgeText(sec)
    if type(sec) ~= "number" or sec < 0 then
        return "just now"
    end
    if sec < 60 then
        return math.floor(sec) .. "s ago"
    elseif sec < 3600 then
        return math.floor(sec / 60) .. "m ago"
    end
    return math.floor(sec / 3600) .. "h ago"
end

if CreateFrame then

local function names()
    local list = {}
    local own = UnitName("player")
    if own then
        table.insert(list, own)
    end
    local nr = GetNumRaidMembers and GetNumRaidMembers() or 0
    if nr > 0 then
        list = {}
        for i = 1, nr do
            local nm = GetRaidRosterInfo(i)
            if nm then
                table.insert(list, nm)
            end
        end
    else
        local np = GetNumPartyMembers and GetNumPartyMembers() or 0
        for i = 1, np do
            local nm = UnitName("party" .. i)
            if nm then
                table.insert(list, nm)
            end
        end
    end
    return list
end

local function guildName(unit)
    if GetGuildInfo then
        return (GetGuildInfo(unit))
    end
    return nil
end

-- name -> true for raid/party members in MY guild, rebuilt per call (the
-- display refresh is event driven, not per frame)
local function guildSet()
    local set = {}
    local mine = guildName("player")
    if not mine then
        return set, false
    end
    local nr = GetNumRaidMembers and GetNumRaidMembers() or 0
    for i = 1, nr do
        local unit = "raid" .. i
        if guildName(unit) == mine then
            set[UnitName(unit)] = true
        end
    end
    local np = GetNumPartyMembers and GetNumPartyMembers() or 0
    for i = 1, np do
        local unit = "party" .. i
        if guildName(unit) == mine then
            set[UnitName(unit)] = true
        end
    end
    local own = UnitName("player")
    if own then
        set[own] = true
    end
    return set, true
end

function A.GameEnv()
    local now = GetTime()
    local nr = GetNumRaidMembers and GetNumRaidMembers() or 0
    local np = GetNumPartyMembers and GetNumPartyMembers() or 0
    local gs, inGuild = guildSet()
    local g = {
        loaded = function(name)
            return IsAddOnLoaded and IsAddOnLoaded(name) and true or false
        end,
        meta = function(addon, field)
            return GetAddOnMetadata and GetAddOnMetadata(addon, field) or nil
        end,
        bigwigsRev = (type(BigWigs) == "table") and tonumber(BigWigs.revision) or nil,
        twtVer = (type(TWT) == "table") and TWT.addonVer or nil,
        superwow = SUPERWOW_VERSION,
    }
    local own = UnitName("player")
    A.own = own
    return {
        now = now,
        raid = nr > 0,
        party = nr == 0 and np > 0,
        guild = inGuild,
        myGuild = inGuild,
        inCombat = UnitAffectingCombat and UnitAffectingCombat("player") and true or false,
        send = SendAddonMessage,
        roster = names(),
        own = own,
        ownEntries = A.LocalEntries(g),
        inGuild = function(p)
            return gs[p.name] == true
        end,
    }
end

-- Check addons button / tab open. Returns started, reason.
function A.Check(auto)
    local ok, env = pcall(A.GameEnv)
    if not ok then
        return false, "error"
    end
    local started, reason = A.StartQuery(env, auto)
    if started then
        A.finishAt = GetTime() + A.WINDOW + 0.3
        A.Wake()
    end
    return started, reason
end

-- one frame: passive listener + a throttled updater that repaints the tab
-- when replies came in and again when the query window ends
local listener = CreateFrame("Frame", "DopingControlAddonsEventFrame", UIParent)
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:SetScript("OnEvent", function()
    if A.OnAddonMessage(arg1, arg2, arg3, arg4, GetTime()) then
        A.dirty = true
        A.Wake()
    end
end)

local updater = CreateFrame("Frame", "DopingControlAddonsUpdateFrame", UIParent)
updater.dcT = 0
updater:Hide()
updater:SetScript("OnUpdate", function()
    this.dcT = this.dcT + arg1
    if this.dcT < 0.5 then
        return
    end
    this.dcT = 0
    local now = GetTime()
    local repaint = false
    if A.dirty then
        A.dirty = false
        repaint = true
    end
    if A.finishAt and now >= A.finishAt then
        A.finishAt = nil
        repaint = true
    end
    if repaint and DC_Matrix and DC_Matrix.RefreshAddons then
        DC_Matrix.RefreshAddons()
    end
    if not A.dirty and not A.finishAt then
        this:Hide()
    end
end)

function A.Wake()
    updater:Show()
end

end -- if CreateFrame
