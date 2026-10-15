if WDI_DOPING_SKIP then return end -- DopingControl data/enchants.lua
-- Equipment tab: 15 enchant slots + 2 item-tile slots (both trinkets), in
-- paperdoll order, with 1.12 inventory slot IDs.
-- Enchant columns are checked present/missing only (enchant ID in the item
-- link ~= 0); an EMPTY enchant slot is always a gap (core/model.lua), so it
-- is never gated by the expectation checkbox -- only the "has an enchant"
-- question is. Item-tile slots (trinkets) show the equipped item and
-- ignore expectations entirely; only an EMPTY slot counts as a gap there.
--
-- Server note: neck, both rings AND the waist ARE enchantable on this
-- server (a server-custom feature beyond vanilla WoW, where none of them
-- take an enchant) -- NECK/R1/R2/WAIST are therefore kind="ench" like any
-- armor slot, not item tiles. The waist enchant is a "Belt Buckle" item
-- (Copper/Bronze/Thorium/Dreamsteel/Bloody Belt Buckle),
-- the same custom itemization line as the neck/ring gems. Their
-- expectation defaults to OFF (data/expectations.lua): unlike the ARMOR
-- enchant slots, a neck/ring/waist enchant is not assumed baseline raid
-- gear, so the columns only track it once a role/class opts in via the
-- options grid.
--
-- Bug history (2026-08-30): the waist (invSlot 6) was missing from this
-- table entirely -- not a deliberate exclusion, an oversight that predates
-- the Belt Buckle lookup above. Because scan/gear.lua's G.InvSlots()
-- derives the full GetInventoryItemLink read list from THIS table, the
-- omission silently dropped the waist from every equipment read: no raid
-- dump ever carried a ";6=" entry, and the HIT tab under-counted any
-- +hit/+resist on a belt (scan/hit.lua's H.SLOTS already listed 6 and
-- expected scan/gear.lua's rawLinks to cover it -- see that file's
-- ReadUnit comment). Adding WAIST here fixes both at the source.
-- Pure Lua 5.0, no WoW API -- dofile-loadable offline.

DopingControl = DopingControl or {}
local DC = DopingControl

-- ------------------------------------------------------------------
-- Slot definitions (array, order = column order). Same field shape as the
-- other tabs plus invSlot (GetInventoryItemLink slot number). Ids
-- HEAD/SHLD/... with tile labels HEA/SHO/...
-- ------------------------------------------------------------------
DC.SLOTS_EQUIPMENT = {
    { id = "HEAD", label = "HEA", sub = "slot 1",  full = "Head",       kind = "ench",    invSlot = 1 },
    { id = "NECK", label = "NCK", sub = "slot 2",  full = "Neck",       kind = "ench",    invSlot = 2 },  -- enchantable on this server (custom, unlike vanilla)
    { id = "SHLD", label = "SHO", sub = "slot 3",  full = "Shoulders",  kind = "ench",    invSlot = 3 },
    { id = "BACK", label = "BCK", sub = "slot 15", full = "Back",       kind = "ench",    invSlot = 15 },
    { id = "CHST", label = "CHE", sub = "slot 5",  full = "Chest",      kind = "ench",    invSlot = 5 },
    { id = "WAIST", label = "WAI", sub = "slot 6", full = "Waist",      kind = "ench",    invSlot = 6 },  -- enchantable on this server (custom Belt Buckle line, unlike vanilla)
    { id = "WRST", label = "WRI", sub = "slot 9",  full = "Wrist",      kind = "ench",    invSlot = 9 },
    { id = "HAND", label = "HND", sub = "slot 10", full = "Hands",      kind = "ench",    invSlot = 10 },
    { id = "LEGS", label = "LEG", sub = "slot 7",  full = "Legs",       kind = "ench",    invSlot = 7 },
    { id = "FEET", label = "FEE", sub = "slot 8",  full = "Feet",       kind = "ench",    invSlot = 8 },
    { id = "MAIN", label = "MH",  sub = "slot 16", full = "Main hand",  kind = "ench",    invSlot = 16 },
    { id = "OFFH", label = "OH",  sub = "slot 17", full = "Off hand",   kind = "ench",    invSlot = 17 },
    { id = "RNGD", label = "RNG", sub = "slot 18", full = "Ranged (scope)", kind = "ench", invSlot = 18 },  -- scope counts as the enchant
    { id = "R1",   label = "R1",  sub = "slot 11", full = "Ring 1",     kind = "ench",    invSlot = 11 },  -- enchantable on this server (custom, unlike vanilla)
    { id = "R2",   label = "R2",  sub = "slot 12", full = "Ring 2",     kind = "ench",    invSlot = 12 },  -- enchantable on this server (custom, unlike vanilla)
    { id = "T1",   label = "T1",  sub = "slot 13", full = "Trinket 1",  kind = "trinket", invSlot = 13 },
    { id = "T2",   label = "T2",  sub = "slot 14", full = "Trinket 2",  kind = "trinket", invSlot = 14 },
}

-- ------------------------------------------------------------------
-- Item-subtype exemptions: whether an enchant applies at all is a
-- property of the equipped ITEM, not of the role. If the equipped item's
-- itemSubType (GetItemInfo return 6 on TWoW 1.18.1)
-- is listed for the slot, the cell classifies as NOTEXP instead
-- of MISSING.
--
-- Shape: DC.ENCH_EXEMPT[slotId][itemSubType] = true
--
-- [ASSUMPTION] English-client subtype strings: wands = "Wands", off-hand
-- frills/holdables = "Miscellaneous", thrown = "Thrown" (thrown weapons
-- cannot take a scope -- same item-property principle as wands; "Thrown"
-- is a deliberate extension --
-- kept because dropping it would show thrown users a
-- false MISSING scope). All three strings are on the probe checklist:
-- the /dc probe battery dumps GetItemInfo subType (return 6) for every
-- equipped slot ("Q5b" lines, core/probe.lua) -- a mismatch means the
-- exemption silently never fires and must be corrected here.
-- ------------------------------------------------------------------
DC.ENCH_EXEMPT = {
    RNGD = { ["Wands"] = true, ["Thrown"] = true },  -- Wands: no scope; Thrown: no scope [ASSUMPTION]
    OFFH = { ["Miscellaneous"] = true },             -- held-in-off-hand frills: not enchantable
}

-- ------------------------------------------------------------------
-- Class-based enchant exemptions:
-- whole CLASSES for which an ench slot never applies,
-- regardless of what (if anything) is equipped. DC_Model.classify checks
-- this FIRST, before gearRead/EMPTY/expectation logic, and returns
-- NOTEXP (detail "no ranged enchant for this class").
--
-- Shape: DC.ENCH_CLASS_EXEMPT[slotId][classToken] = true
--        (classToken = english GetRaidRosterInfo return-6 token)
--
-- RNGD: shamans/druids/priests/mages/warlocks carry wands/totems/idols/
-- relics or nothing there -- no scope ever applies.
-- PALADIN added: vanilla paladins have a permanently EMPTY ranged
-- slot (no ranged/relic item exists for them on 1.12), so a scope can
-- never apply either.
-- ------------------------------------------------------------------
DC.ENCH_CLASS_EXEMPT = {
    RNGD = {
        SHAMAN  = true,
        DRUID   = true,
        PRIEST  = true,
        MAGE    = true,
        WARLOCK = true,
        PALADIN = true,  -- permanently empty ranged slot in vanilla
    },
}

-- ------------------------------------------------------------------
-- Enchant ID -> display text (1.12 has no API for it). DC.ENCH_NAMES below
-- is generated from the client's own SpellItemEnchantment.dbc, restricted
-- to permanent item enchants (ENCHANT_ITEM spell effects).
-- DC.EnchantName(id) -> name | nil (unknown id, or no enchant: 0/nil).
-- DC.EnchantLabel(id) -> name | "enchant #<id>" | nil (only for no enchant):
-- an id missing from the table is still KNOWN to be enchanted, so it is
-- never reported as missing -- only its name is unknown.
-- ------------------------------------------------------------------
function DC.EnchantName(id)
    if type(id) ~= "number" or id <= 0 or not DC.ENCH_NAMES then
        return nil
    end
    return DC.ENCH_NAMES[id]
end

function DC.EnchantLabel(id)
    if type(id) ~= "number" or id <= 0 then
        return nil
    end
    return DC.EnchantName(id) or ("enchant #" .. id)
end

-- BEGIN GENERATED ENCH_NAMES (tools/gen-enchant-names.py; do not edit by hand)
DC.ENCH_NAMES = {
    [1] = "Rockbiter 3",
    [3] = "Flametongue 3",
    [15] = "Reinforced Armor +8/+1 Stamina",
    [16] = "Reinforced Armor +16/+2 Stamina",
    [17] = "Reinforced Armor +24/+3 Stamina",
    [18] = "Reinforced Armor +32/+4 Stamina",
    [24] = "Mana +5",
    [28] = "+4 All Resistances",
    [30] = "Scope (+1 Damage)",
    [32] = "Scope (+2 Damage)",
    [33] = "Scope (+3 Damage)",
    [34] = "Counterweight +3% Attack Speed",
    [36] = "Enchant: Fiery Blaze",
    [37] = "Weapon Chain - Immune Disarm",
    [41] = "Health +5",
    [43] = "Iron Spike (8-12)",
    [44] = "Absorption (10)",
    [63] = "Absorption (25)",
    [65] = "+1 All Resistances",
    [66] = "Stamina +1",
    [71] = "+1 Stamina",
    [72] = "+2 Stamina",
    [73] = "+3 Stamina",
    [76] = "+3 Agility",
    [80] = "+2 Intellect",
    [90] = "+4 Agility",
    [92] = "+6 Agility",
    [93] = "+7 Agility",
    [94] = "+4 Intellect",
    [96] = "+6 Intellect",
    [98] = "+4 Spirit",
    [104] = "+6 Stamina",
    [107] = "+5 Strength",
    [108] = "+6 Strength",
    [208] = "Healing +7",
    [225] = "Nature Damage +9",
    [241] = "Weapon Damage +2",
    [242] = "Health +15",
    [243] = "Spirit +1",
    [246] = "Mana +20",
    [247] = "Agility +1",
    [248] = "Strength +1",
    [249] = "Beastslaying +2",
    [250] = "Weapon Damage +1",
    [254] = "Health +25",
    [255] = "Spirit +3",
    [256] = "+5 Fire Resistance",
    [345] = "+40 Armor",
    [354] = "+9 Intellect",
    [357] = "+9 Strength",
    [362] = "+10 Strength",
    [370] = "+12 Spirit",
    [371] = "+12 Stamina",
    [426] = "Spell Damage +5",
    [432] = "Spell Damage +12",
    [440] = "Healing +12",
    [449] = "Rift Tear",
    [450] = "Scope (+2% Ranged Crit)",
    [463] = "Mithril Spike (16-20)",
    [464] = "Mithril Spurs",
    [663] = "Scope (+5 Damage)",
    [664] = "Scope (+7 Damage)",
    [684] = "+15 Strength",
    [723] = "Intellect +3",
    [724] = "Stamina +3",
    [744] = "Armor +20",
    [763] = "Block +1%",
    [783] = "Armor +10",
    [803] = "Fiery Weapon",
    [804] = "+10 Shadow Resistance",
    [805] = "Weapon Damage +4",
    [823] = "Strength +3",
    [843] = "Mana +30",
    [844] = "Mining +2",
    [845] = "Herbalism +2",
    [846] = "Fishing +2",
    [847] = "All Stats +1",
    [848] = "Armor +30",
    [849] = "Agility +3",
    [850] = "Health +35",
    [851] = "Spirit +5",
    [852] = "Stamina +5",
    [853] = "Beastslaying +6",
    [854] = "Elemental Slayer +6",
    [856] = "Strength +5",
    [857] = "Mana +50",
    [863] = "Blocking +2%",
    [865] = "Skinning +5",
    [866] = "All Stats +2",
    [883] = "+15 Agility",
    [884] = "Armor +50",
    [903] = "+3 All Resistances",
    [904] = "Agility +5",
    [905] = "Intellect +5",
    [906] = "Mining +5",
    [907] = "Spirit +7",
    [908] = "Health +50",
    [909] = "Herbalism +5",
    [910] = "Increased Stealth",
    [911] = "Minor Speed Increase",
    [912] = "Demonslaying",
    [913] = "Mana +65",
    [923] = "Defense +3",
    [924] = "Defense +1",
    [925] = "Defense +2",
    [926] = "+8 Frost Resistance",
    [927] = "Strength +7",
    [928] = "All Stats +3",
    [929] = "Stamina +7",
    [930] = "Minor Mount Speed Increase",
    [931] = "Attack Speed +1%",
    [943] = "Weapon Damage +3",
    [963] = "Weapon Damage +7",
    [1023] = "Feedback 1",
    [1068] = "+15 Stamina",
    [1125] = "+22 Intellect",
    [1149] = "+20 Spirit",
    [1250] = "+8 Arcane Resistance",
    [1252] = "+10 Arcane Resistance",
    [1257] = "+15 Arcane Resistance",
    [1267] = "+25 Arcane Resistance",
    [1341] = "+7 Fire Resistance",
    [1342] = "+8 Fire Resistance",
    [1344] = "+10 Fire Resistance",
    [1388] = "+8 Nature Resistance",
    [1434] = "+8 Shadow Resistance",
    [1436] = "+10 Shadow Resistance",
    [1441] = "+15 Shadow Resistance",
    [1446] = "+20 Shadow Resistance",
    [1483] = "Mana +150",
    [1503] = "HP +100",
    [1504] = "Armor +125",
    [1505] = "+20 Fire Resistance",
    [1506] = "Strength +8",
    [1507] = "Stamina +8",
    [1508] = "Agility +8",
    [1509] = "Intellect +8",
    [1510] = "Spirit +8",
    [1523] = "MANA/FR +85/14",
    [1524] = "HP/FR +75/14",
    [1525] = "AC/FR +110/14",
    [1526] = "STR/FR +10/14",
    [1527] = "STA/FR +10/14",
    [1528] = "AGI/FR +10/14",
    [1529] = "INT/FR +10/14",
    [1530] = "SPI/FR +10/14",
    [1532] = "STR/STA/AC/FR +10/10/110/15",
    [1543] = "INT/SPI/MANA/FR +10/10/100/15",
    [1704] = "Thorium Spike (20-30)",
    [1843] = "Reinforced Armor +40/+5 Stamina",
    [1883] = "Intellect +7",
    [1884] = "Spirit +9",
    [1885] = "Strength +9",
    [1886] = "Stamina +9",
    [1887] = "Agility +7",
    [1888] = "+5 All Resistances",
    [1889] = "Armor +70",
    [1890] = "Spirit +9",
    [1891] = "All Stats +4",
    [1892] = "Health +100",
    [1893] = "Mana +100",
    [1894] = "Icy Weapon",
    [1896] = "Weapon Damage +9",
    [1897] = "Weapon Damage +5",
    [1898] = "Lifestealing",
    [1899] = "Unholy Weapon",
    [1900] = "Crusader",
    [1903] = "Spirit +9",
    [1904] = "Intellect +9",
    [1944] = "+5 Defense",
    [2045] = "+14 Ranged Attack Power",
    [2082] = "+6 Arcane Spell Damage",
    [2084] = "+9 Arcane Spell Damage",
    [2144] = "+40 Shadow Spell Damage",
    [2158] = "+6 Fire Spell Damage",
    [2160] = "+9 Fire Spell Damage",
    [2236] = "+9 Frost Spell Damage",
    [2296] = "+40 Nature Spell Damage",
    [2366] = "+2 mana every 5 sec.",
    [2443] = "Frost Spell Damage +7",
    [2463] = "+7 Fire Resistance",
    [2483] = "+5 Fire Resistance",
    [2484] = "+5 Frost Resistance",
    [2485] = "+5 Arcane Resistance",
    [2486] = "+5 Nature Resistance",
    [2487] = "+5 Shadow Resistance",
    [2488] = "+5 All Resistances",
    [2503] = "Defense +5",
    [2504] = "Spell Damage +30",
    [2505] = "Healing Spells +55",
    [2523] = "Scope (+3% Ranged Hit)",
    [2544] = "Healing and Spell Damage +12",
    [2545] = "Dodge +1%",
    [2563] = "Strength +15",
    [2564] = "Agility +15",
    [2565] = "Mana Regen 4 per 5 sec.",
    [2566] = "Healing Spells +24",
    [2567] = "Spirit +20",
    [2568] = "Intellect +22",
    [2583] = "Defense +7/Stamina +10/Block Value +15",
    [2584] = "Defense +7/Stamina +10/Healing Spells +24",
    [2585] = "Attack Power +28/Dodge +1%",
    [2586] = "Ranged Attack Power +24/Stamina +10/Hit +1%",
    [2587] = "Healing and Spell Damage +13/Intellect +15",
    [2588] = "Healing and Spell Damage +18/Spell Hit +1%",
    [2589] = "Healing and Spell Damage +18/Stamina +10",
    [2590] = "Mana Regen +4/Stamina +10/Healing Spells +24",
    [2591] = "Intellect +10/Stamina +10/Healing Spells +24",
    [2603] = "Eternium Line",
    [2604] = "+33 Healing Spells",
    [2605] = "+18 Spell Damage and Healing",
    [2606] = "+30 Attack Power",
    [2613] = "Threat +2%",
    [2614] = "Shadow Damage +20",
    [2615] = "Frost Damage +20",
    [2616] = "Fire Damage +20",
    [2617] = "Healing Spells +30",
    [2619] = "+15 Fire Resistance",
    [2620] = "+15 Nature Resistance",
    [2621] = "Subtlety",
    [2622] = "Dodge +1%",
    [2646] = "Agility +25",
    [2681] = "+10 Nature Resistance",
    [2682] = "+10 Frost Resistance",
    [2683] = "+10 Shadow Resistance",
    [2715] = "Healing +31 and 5 mana per 5 sec.",
    [2716] = "Stamina +16 and Armor +100",
    [2717] = "Attack Power +26 and +1% Critical Strike",
    [2721] = "Spell Damage +15 and +1% Spell Critical Strike",
    [2722] = "Block Value +10",
    [3001] = "Arcane Damage +20",
    [3002] = "Nature Damage +20",
    [3003] = "Holy Damage +20",
    [3004] = "Wolfsheart",
    [3005] = "+14 Stamina",
    [3008] = "+6 Spell Penetration",
    [3011] = "+1% Vampirism",
    [3012] = "+2% Vampirism",
    [3016] = "+1% Haste",
    [3017] = "+2% Haste",
    [3021] = "+3 Spell Power",
    [3024] = "+5 Defense",
    [3025] = "+9 Damage and Healing Spells",
    [3026] = "Thorium Spurs",
    [3038] = "Armor Penetration +40",
    [3047] = "+25 Spell Penetration",
    [3049] = "+2% Dodge",
    [3051] = "+25 Armor Penetration",
    [3052] = "+10 Intellect",
    [3054] = "1% Resilience",
    [3057] = "Healing +8",
}
-- END GENERATED ENCH_NAMES
