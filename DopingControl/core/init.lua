if WDI_DOPING_SKIP then return end -- DopingControl core/init.lua
-- Bootstrap: ADDON_LOADED wiring (SavedVariables defaults), event
-- registration (roster changes, READY_CHECK), test-mode switch, slash
-- commands /dc + /doping. Loads LAST in the TOC -- every module global
-- (DC_Scan, DC_Matrix, DC_Options, DC_Report, DC_Sim, DC_Probe) exists by
-- the time any function here runs.
--
-- Pure-Lua 5.0 dofile-loadable: all WoW wiring behind "if CreateFrame then".
-- The pure parts (DC.HandleSlash, DC.SetTestMode, DC.DumpUnknown) are
-- offline-tested with stubbed modules.

DopingControl = DopingControl or {}
local DC = DopingControl

-- Store (the shared data shape every consumer reads). Empty until the
-- first scan finishes or test mode injects the simulated store.
DC.store = DC.store or { players = {}, source = "scan" }

-- Unknown-aura tally, filled by scan/aura.lua (DC.unknownSeen[name] = count);
-- read here by /dc unknown (unknown buff names are never silently discarded).
DC.unknownSeen = DC.unknownSeen or {}

local CHAT_PREFIX = "|cff3fae5cDopingControl|r: "

function DC.Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. tostring(msg))
    else
        print(CHAT_PREFIX .. tostring(msg))  -- offline Lua 5.0
    end
end

-- Called by scan/engine.lua whenever the store changed (scan finished).
function DC.OnStoreUpdated()
    DC_Matrix.Refresh()
end

-- Matrix visibility, used to decide whether a roster change should trigger
-- an immediate rescan. DC_Matrix.IsShown is not pinned in the plan -- if
-- ui/matrix.lua does not provide it, we conservatively treat the window as
-- hidden (next manual scan / ready check rescans anyway).
local function MatrixIsShown()
    if DC_Matrix and DC_Matrix.IsShown then
        return DC_Matrix.IsShown()
    end
    return nil
end

-- ------------------------------------------------------------------
-- Test mode: the simulator fully replaces the data source.
-- ------------------------------------------------------------------
function DC.SetTestMode(v)
    local db = DC.db or DopingControlDB
    db.testMode = v
    if v then
        -- buildStore() itself resets and refills DC.simRoles with the
        -- built-in confirmations (DC_Sim.ROLES, core/sim.lua) -- do NOT wipe
        -- DC.simRoles afterwards, that would erase them and turn every row
        -- into a suggestion badge (the sim roster deliberately contains
        -- exactly two suggestion-badge cases).
        DC.store = DC_Sim.buildStore()
    elseif DC.demoMode then
        -- Demo mode owns the simulated store on its own account
        -- (DC.SimOwnsStore) -- the mirror image of core/demo.lua's
        -- "leaving demo mode must not kick test mode out of the sim
        -- store". Without this the showcase would be emptied here and the
        -- rescan below would be dropped by the scan gate anyway, leaving a
        -- blank window. /dc demo is what ends demo mode.
        DC.store = DC_Sim.buildStore()
    else
        DC.store = { players = {}, source = "scan" }
        DC_Scan.Start(true)  -- leaving test mode: immediate real rescan
    end
    DC_Matrix.Refresh()
end

-- ------------------------------------------------------------------
-- The pre-raid check, automated.
--
-- db.testMode is persisted (core/config.lua DEFAULTS), so it survives a
-- reload and a relog: a session that ends with the simulated raid on
-- screen starts the next one showing it again, and from then on the
-- matrix grades a roster that does not exist. On screen the only marker
-- is the source banner, and a "MISSING" wall reads the same either way --
-- so the failure mode is not a visible error, it is a plausible wrong
-- answer, which is the worst kind for a raid buff checker.
--
-- Remembering to check before every raid is not a routine anyone keeps.
-- The addon does it instead, at the two moments it matters: once per
-- login/reload, and again when a group forms.
--
-- DC.SimModeReminder(db, demoMode) -> string|nil
--   The line to print, or nil when neither simulated mode owns the
--   store. Pure -- the caller prints it, so it stays offline-testable.
--   Test mode is named first because it is the persisted one: the mode
--   that comes back on its own is the one this exists for. Demo mode is
--   transient (core/demo.lua) and cannot survive a reload, but it can
--   still be on when the raid forms, so it gets the same reminder with
--   its own switch named -- naming the wrong switch would send the user
--   to a toggle that changes nothing.
--   db/demoMode are optional; the fallback matches DC.SimOwnsStore.
-- ------------------------------------------------------------------
function DC.SimModeReminder(db, demoMode)
    db = db or DC.db or DopingControlDB
    if db and db.testMode then
        return "test mode is ON - the matrix shows the simulated raid, not your group (/dc test to leave)"
    end
    if demoMode == nil then
        demoMode = DC.demoMode
    end
    if demoMode then
        return "demo mode is ON - the matrix shows the simulated raid, not your group (/dc demo to leave)"
    end
    return nil
end

-- ------------------------------------------------------------------
-- DC.NoteGroupSize(n) -> bool
--
-- Edge detector for "a group just formed": true only on the 0 -> >0
-- transition. The roster events fire once per member, so a 40-man raid
-- filling up would otherwise print the reminder 39 times. Pure apart
-- from its own last-seen counter, which starts at 0 (solo).
-- ------------------------------------------------------------------
local lastGroupSize = 0

function DC.NoteGroupSize(n)
    n = n or 0
    local joined = (lastGroupSize == 0 and n > 0)
    lastGroupSize = n
    return joined
end

-- Raid count first, party count only when it is 0: the two calls do not
-- agree on what "in a party" means once a raid exists, and the raid
-- answer is the unambiguous one. Returns 0 offline (no WoW API).
local function GroupSize()
    local n = GetNumRaidMembers and GetNumRaidMembers() or 0
    if n and n > 0 then
        return n
    end
    n = GetNumPartyMembers and GetNumPartyMembers() or 0
    return n or 0
end

-- ------------------------------------------------------------------
-- /dc unknown -- dump DC.unknownSeen via SuperWoW ExportFile.
-- ------------------------------------------------------------------
function DC.DumpUnknown()
    local names = {}
    local distinct = 0
    for name in pairs(DC.unknownSeen) do
        table.insert(names, name)
        distinct = distinct + 1
    end
    if distinct == 0 then
        DC.Print("no unknown buffs recorded")
        return
    end
    table.sort(names, function(a, b)
        local ca, cb = DC.unknownSeen[a], DC.unknownSeen[b]
        if ca ~= cb then return ca > cb end
        return a < b
    end)
    local lines = { "DopingControl unknown buffs (" .. distinct .. " names)" }
    for i = 1, table.getn(names) do
        table.insert(lines, string.format("%dx %s", DC.unknownSeen[names[i]], names[i]))
    end
    local text = table.concat(lines, "\n")
    if ExportFile then
        -- SuperWoW appends ".txt" itself -- pass the name WITHOUT extension.
        -- pcall: optional-DLL call -- an I/O error must not
        -- escape into the slash handler.
        local okE = pcall(ExportFile, "dc_unknown", text)
        if okE then
            DC.Print(distinct .. " unknown buff names dumped to dc_unknown.txt (WoW Imports folder)")
        else
            DC.Print("ExportFile failed - no dump written")
        end
    else
        DC.Print("ExportFile unavailable (SuperWoW required) - no dump written")
    end
end

-- ------------------------------------------------------------------
-- Slash commands: /dc, /doping
-- ------------------------------------------------------------------
local HELP_TEXT = "commands: /dc (window) | scan | options | report | test | demo | probe [range <name>] | unknown | talents [on|off|clear]"

function DC.HandleSlash(msg)
    msg = msg or ""
    local _, _, word, rest = string.find(msg, "^%s*(%S*)%s*(.-)%s*$")
    local cmd = string.lower(word or "")
    local db = DC.db or DopingControlDB

    if cmd == "" then
        DC_Matrix.Toggle()
    elseif cmd == "scan" then
        -- Real data never beats the simulation while EITHER simulated mode
        -- owns the store (DC.SimOwnsStore, core/config.lua). Test mode is
        -- named first because it is the persisted one -- but the refusal
        -- must name the mode that is actually on, or the user toggles the
        -- wrong switch and the scan keeps refusing.
        if db and db.testMode then
            DC.Print("test mode is on - /dc test to switch back before scanning")
        elseif DC.SimOwnsStore(db) then
            DC.Print("demo mode is on - /dc demo to switch back before scanning")
        else
            DC_Scan.Start()
        end
    elseif cmd == "options" then
        DC_Options.Toggle()
    elseif cmd == "report" then
        DC_Report.Open()
    elseif cmd == "test" then
        DC.SetTestMode(not (db and db.testMode))
        if db and db.testMode then
            DC.Print("test mode ON - simulated raid, chat output disabled")
        elseif DC.demoMode then
            -- SetTestMode kept the sim store for demo mode and started no
            -- rescan; a "rescanning" message here would be false.
            DC.Print("test mode OFF - demo mode still on, still showing the simulated raid (/dc demo to leave)")
        else
            DC.Print("test mode OFF - rescanning the real group")
        end
    elseif cmd == "demo" then
        -- Showcase view: the simulated raid plus a TRANSIENT expectation
        -- layer that shows all six school protection columns at once
        -- (core/demo.lua). Nothing about it is saved -- unlike /dc test,
        -- which persists db.testMode.
        if not DC.SetDemoMode then
            DC.Print("demo module not loaded")
        else
            DC.SetDemoMode(not DC.demoMode)
            if DC.demoMode then
                DC.Print("demo mode ON - simulated raid, all six protection columns shown")
            else
                DC.Print("demo mode OFF - back to the normal view")
            end
        end
    elseif cmd == "probe" then
        -- core/probe.lua owns the probe subcommand grammar:
        -- DC_Probe.HandleSlash(rest) handles "" (battery),
        -- "range <name>" (1 Hz run) and the range-run stop toggle.
        DC_Probe.HandleSlash(rest)
    elseif cmd == "unknown" then
        DC.DumpUnknown()
    elseif cmd == "talents" then
        -- foreign talents come in over this server's inspect protocol
        -- (scan/talents.lua). "on"/"off" is a real switch, not cosmetic:
        -- asking makes OTHER players' clients send their tree back, so it
        -- must be possible to stop doing that.
        if not DC_Talents then
            DC.Print("talent module not loaded")
        elseif rest == "on" or rest == "off" then
            DopingControlDB.readTalents = (rest == "on")
            DC.Print("talent reading " .. rest)
            if rest == "off" and DC_Talents.Clear then
                DC_Talents.Clear()
            end
        elseif rest == "clear" then
            DC_Talents.Clear()
            DC.Print("talent cache cleared - they will be asked again")
        else
            local s = DC_Talents.Stats()
            DC.Print("talents: " .. s.known .. " known, " .. s.pending
                .. " mid-reply, " .. s.queued .. " queued, "
                .. (s.enabled and "ON" or "OFF")
                .. "  (/dc talents on|off|clear)")
        end
    else
        DC.Print(HELP_TEXT)
    end
end

-- ------------------------------------------------------------------
-- WoW wiring
-- ------------------------------------------------------------------
if CreateFrame then
    SLASH_DOPINGCONTROL1 = "/dc"
    SLASH_DOPINGCONTROL2 = "/doping"
    SlashCmdList["DOPINGCONTROL"] = DC.HandleSlash

    -- Matrix toolbar hooks (ui/matrix.lua fires MX.hooks.*): the Options
    -- and Report buttons fall back to DC_Options/DC_Report directly, but
    -- the Scan button ONLY fires MX.hooks.scan -- wire it here through the
    -- slash path so it gets the same test-mode gate as "/dc scan".
    if DC_Matrix and DC_Matrix.hooks then
        DC_Matrix.hooks.scan = function()
            DC.HandleSlash("scan")
        end
    end

    local ev = CreateFrame("Frame", "DopingControlInitEventFrame", UIParent)
    ev:RegisterEvent("ADDON_LOADED")
    ev:SetScript("OnEvent", function()
        if event == "ADDON_LOADED" then
            if arg1 ~= "WhoDidIt" then return end
            ev:UnregisterEvent("ADDON_LOADED")

            -- SavedVariables are in place now.
            DopingControlDB = DopingControlDB or {}
            DC.EnsureDefaults(DopingControlDB)  -- also deep-copies
            -- DC.DEFAULT_EXPECT into db.expectations on first load
            -- (core/config.lua handles that inside EnsureDefaults).
            DC.db = DopingControlDB

            -- Roster changes invalidate the store; rescan only when the
            -- window is up (otherwise the next scan re-reads the roster
            -- anyway -- scan/engine.lua re-walks it on every Start()).
            ev:RegisterEvent("RAID_ROSTER_UPDATE")
            ev:RegisterEvent("PARTY_MEMBERS_CHANGED")

            -- READY_CHECK: registered defensively -- it is unverified
            -- whether this event fires natively on 1.12/TurtleWoW, so a
            -- rejecting client must not break the bootstrap.
            pcall(ev.RegisterEvent, ev, "READY_CHECK")

            -- Persisted test mode survives reloads: restore the simulated
            -- store so window content and db.testMode stay consistent.
            if DC.db.testMode then
                DC.store = DC_Sim.buildStore()
            end

            -- ...and say so. Not here though: chat output before
            -- PLAYER_ENTERING_WORLD is silently dropped (verified), so
            -- the reminder waits for that event.
            ev:RegisterEvent("PLAYER_ENTERING_WORLD")

        elseif event == "PLAYER_ENTERING_WORLD" then
            -- Fires on every loading screen, not just login -- once is
            -- the point, so this unregisters itself. The group-join
            -- reminder below covers the rest of the session.
            ev:UnregisterEvent("PLAYER_ENTERING_WORLD")
            local warn = DC.SimModeReminder(DC.db)
            if warn then
                DC.Print(warn)
            end

        elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
            local db = DC.db
            -- A group just formed: the last moment before a raid where
            -- a forgotten simulated mode is still cheap to notice.
            if DC.NoteGroupSize(GroupSize()) then
                local warn = DC.SimModeReminder(db)
                if warn then
                    DC.Print(warn)
                end
            end
            if db and not DC.SimOwnsStore(db) and MatrixIsShown() then
                DC_Scan.Start()
            end

        elseif event == "READY_CHECK" then
            -- The auto-SCAN on ready check is owned by scan/engine.lua
            -- (single owner) -- registering the Start
            -- here too fired a duplicate full scan per ready check. This
            -- handler only does the auto-OPEN half.
            local db = DC.db
            if db and db.readyCheckOpen then
                DC_Matrix.Show()
            end
        end
    end)
end
