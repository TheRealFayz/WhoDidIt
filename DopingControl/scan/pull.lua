if WDI_DOPING_SKIP then return end -- DopingControl scan/pull.lua
-- Silent snapshot on a pull timer: BigWigs' Pulltimer plugin broadcasts a
-- CHAT_MSG_ADDON every time ANYONE in the raid/party starts (or rebroadcasts)
-- a pull timer -- one more moment where "who has their flask up" matters,
-- and one the addon currently misses entirely (only READY_CHECK triggers an
-- automatic snapshot -- scan/engine.lua's header -- and some raids' ready
-- checks route through a DIFFERENT addon's own protocol instead: prefix
-- "TW_RF", payload "<Name> Ready", never raising the native READY_CHECK
-- event at all (seen in a live capture). A whole Molten
-- Core night went unsnapshotted this way on 24 Sep 2026.
--
-- Wire format (source-confirmed against the installed BigWigs addon):
--   BigWigsComm:BigWigs_SendSync sends
--     SendAddonMessage("BigWigs", "<syncName> <rest>", "RAID")
--   (Plugins/Comm.lua:57-67) and receives the identical shape back on
--   CHAT_MSG_ADDON with prefix == "BigWigs" (Plugins/Comm.lua:43-54:
--     local _, _, sync, rest = string.find(message, "(%S+)%s*(.*)$")
--   -- the exact split used below). The pull-timer sync names
--   (Plugins/Pulltimer.lua:27-32):
--     "PulltimerSync"          -- a (possibly soft/relayed) timer start,
--                                  rest = duration in seconds
--     "PulltimerBroadcastSync" -- an explicit rebroadcast, same rest shape
--     "PulltimerStopSync"      -- pull aborted -- no duration, never a start
--     "PulltimerReqSync"       -- "is a timer running" -- no duration
--   DoPull only ever Syncs a POSITIVE duration (Plugins/Pulltimer.lua:203-
--   223: an explicit 0 either stops an existing bar or resolves to 6 before
--   sending), and BigWigs_Pulltimer itself discards anything `tonumber`
--   rejects (Plugins/Pulltimer.lua:256-260) -- so "sync name matches AND
--   rest is a positive number" is both necessary and sufficient for "a pull
--   just started".
--   No pfUI pull timer exists on this client (checked: no "pull" or
--   "Pulltimer" hit anywhere under Interface/AddOns/pfUI) -- BigWigs is the
--   only pull timer installed, so it is the only wire this file speaks.
--   Live confirmation the "BigWigs"/RAID channel is real traffic on this
--   server, not merely installed-but-idle code: captured chat addon
--   messages carry the same "<sync> <rest>" shape (a ward-fired notice).
--   No PulltimerSync sample was captured, so the exact in-game duration
--   argument is confirmed from source, not from a captured packet.
--
-- Self-pull: does the SENDER's own client receive its own CHAT_MSG_ADDON on
-- this fork? Unverified in-game either way -- but BigWigs' own code does not
-- trust it: BigWigs_SendSync calls SendAddonMessage AND ALSO invokes its own
-- CHAT_MSG_ADDON handler directly, passing the sender's own name, right
-- after (Plugins/Comm.lua:64-65). That is strong circumstantial evidence the
-- authors did not want a raid leader's own /pull to depend on the echo. This
-- file does the analogous thing: it hooks the global SendAddonMessage
-- (guarded, pcall-wrapped, every return value passed through unchanged) and
-- feeds prefix=="BigWigs" traffic through the SAME parser the CHAT_MSG_ADDON
-- handler uses. If the echo DOES fire on this client, the debounce below
-- absorbs the harmless double trigger; if it does not, the hook is the only
-- path a self-started pull has.
--
-- The scan itself rides the SAME entry point as the ready-check path
-- (DC_Scan.Start, scan/engine.lua) and is silent BY CONSTRUCTION: E.Start
-- never shows any UI frame -- the ready-check path's own auto-OPEN is a
-- SEPARATE decision made by core/init.lua's READY_CHECK handler
-- (db.readyCheckOpen -> DC_Matrix.Show()), which this file never touches or
-- even requires loaded. The resulting store gets a `trigger = "pull"` tag
-- (E.NewStore, scan/engine.lua) purely so dev/raiddump.lua's S line and the
-- store itself say which scans came from a pull timer; store.source stays
-- "scan" either way -- every real gate keeps reading THAT field.
--
-- Pure Lua 5.0, dofile-loadable offline: P.ParsePull/P.ShouldTrigger are
-- pure; the frame, the event and the SendAddonMessage hook sit behind
-- `if CreateFrame then`, the same convention as every other scan/*.lua file.

DopingControl = DopingControl or {}
local DC = DopingControl

DC_Pull = DC_Pull or {}
local P = DC_Pull

-- at most one pull-triggered scan every this many seconds
P.DEBOUNCE = 15

-- ==================================================================
-- Pure part
-- ==================================================================

-- ParsePull(prefix, msg) -> duration (number > 0) | nil
-- Recognizes a pull-timer START message on the BigWigs wire (see header).
-- Everything else (wrong prefix, a stop/req sync, a non-numeric or
-- non-positive rest) returns nil -- including a message from some OTHER
-- addon that happens to share the "BigWigs" prefix by accident, which would
-- simply fail the sync-name check.
function P.ParsePull(prefix, msg)
    if prefix ~= "BigWigs" or type(msg) ~= "string" then
        return nil
    end
    local _, _, sync, rest = string.find(msg, "(%S+)%s*(.*)$")
    if sync ~= "PulltimerSync" and sync ~= "PulltimerBroadcastSync" then
        return nil
    end
    local dur = tonumber(rest)
    if dur and dur > 0 then
        return dur
    end
    return nil
end

-- ShouldTrigger(now, lastAt, opts) -> bool
--   opts = { enabled, inGroup, simOwnsStore, scanRunning }
-- Every gate named in the brief, in one pure, orthogonal predicate: the
-- setting, group membership, the sim-store lock and the debounce window.
-- `scanRunning` is a SEPARATE gate from the debounce window -- a long scan
-- (a large raid, batched 5 units/frame in scan/engine.lua) can still be
-- running well past 15s, and a second pull during it must not restart it:
-- unlike a manual/ready-check Start(true), a pull-triggered Start is never
-- `force`, so DC_Scan.Start would already no-op on its own -- this gate just
-- avoids bumping `lastAt` (and thus the debounce window) for a call that was
-- never going to do anything.
function P.ShouldTrigger(now, lastAt, opts)
    opts = opts or {}
    if not opts.enabled then
        return false
    end
    if opts.simOwnsStore then
        return false
    end
    if not opts.inGroup then
        return false
    end
    if opts.scanRunning then
        return false
    end
    if lastAt and (now - lastAt) < P.DEBOUNCE then
        return false
    end
    return true
end

-- ==================================================================
-- WoW part
-- ==================================================================
if CreateFrame then

    local lastAt = nil

    -- Raid count first, party count only when it is 0 -- same convention as
    -- core/init.lua's (private) GroupSize(): both read the same two API
    -- calls and would drift identically if either ever changed shape.
    local function inGroup()
        local n = GetNumRaidMembers and GetNumRaidMembers() or 0
        if n and n > 0 then
            return true
        end
        n = GetNumPartyMembers and GetNumPartyMembers() or 0
        return (n or 0) > 0
    end

    local function pullEnabled(db)
        -- default ON, like every other auto-scan switch in this file family
        -- (db.readyCheckScan, core/config.lua) -- NEVER `db.pullTimerScan`
        -- alone (would misread a saved `false` as truthy-missing).
        return not (db and db.pullTimerScan == false)
    end

    -- Shared by the CHAT_MSG_ADDON handler and the SendAddonMessage hook
    -- below -- one decision path, fed from two entry points (see header).
    local function maybeTrigger(prefix, msg)
        local dur = P.ParsePull(prefix, msg)
        if not dur then
            return
        end
        local db = DopingControlDB
        local now = GetTime and GetTime() or 0
        local scanRunning = (DC_Scan and DC_Scan.IsRunning
            and DC_Scan.IsRunning()) or false
        local go = P.ShouldTrigger(now, lastAt, {
            enabled = pullEnabled(db),
            inGroup = inGroup(),
            simOwnsStore = DC.SimOwnsStore(db),
            scanRunning = scanRunning,
        })
        if not go then
            return
        end
        lastAt = now
        if DC_Scan and DC_Scan.Start then
            DC_Scan.Start(nil, "pull")
        end
    end

    local f = CreateFrame("Frame", "DopingControlPullFrame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:SetScript("OnEvent", function()
        -- 1.12: arg1 prefix, arg2 message, arg3 channel, arg4 sender -- the
        -- channel/sender are not needed here, unlike scan/talents.lua: ANY
        -- raid/party member's pull (including our own, see below) is a
        -- trigger, so there is nothing left to filter on.
        maybeTrigger(arg1, arg2)
    end)

    -- Self-pull backstop -- see the file header. Installed once; pcall-
    -- wrapped so a malformed call from ANY addon can never take the real
    -- SendAddonMessage down with it, and every return value is passed
    -- through unchanged so no other addon (BigWigs included) can tell it
    -- was wrapped.
    if SendAddonMessage and not P.hooked then
        P.hooked = true
        local orig = SendAddonMessage
        P.origSendAddonMessage = orig  -- exposed for tests
        SendAddonMessage = function(prefix, msg, chatType, target)
            -- our own logic is guarded so it can never break the caller's
            -- send; the original runs unguarded so its errors still reach
            -- the calling addon exactly as before the hook
            pcall(maybeTrigger, prefix, msg)
            return orig(prefix, msg, chatType, target)
        end
    end

end
