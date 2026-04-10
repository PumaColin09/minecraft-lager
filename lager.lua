local IO_NAME = nil
local MONITOR_NAME = nil
local MONITOR_SCALE = 0.5
local SORT_INTERVAL = 1
local SCAN_INTERVAL = 5
local PAGE_INTERVAL = 4
local TOPOLOGY_REFRESH_INTERVAL = 10
local OUTPUT_HOLD_SECONDS = 120
local OUTPUT_FRACTION = 0.25
local MIN_OUTPUT_SLOTS = 9
local MAX_OUTPUT_SLOTS = 27
local REBALANCE_BATCH_MOVES = 32
local ROLE_MARKER_SLOT = 1
local MAP_FILE = "mod_map.txt"

local SPECIAL_TARGETS = {
  ores = nil,
  stone = nil,
  wood = nil,
  redstone = nil,
  food = nil,
  farming = nil,
  mobdrops = nil,
  tools = nil,
  misc = nil,
  overflow = nil,
}

local AUTO_MOD_POOL = true
local MOD_POOL_NAMES = {
  -- "create:item_vault_0",
  -- "create:item_vault_1",
  -- "minecraft:chest_3",
  -- "minecraft:chest_4",
}

local GROUP_LABELS = {
  ores = "Erze & Metalle",
  stone = "Stein & Erde",
  wood = "Holz",
  redstone = "Redstone",
  food = "Essen",
  farming = "Pflanzen",
  mobdrops = "Mobdrops",
  tools = "Werkzeuge",
  misc = "Verschiedenes",
}

local state = {
  ioName = nil,
  io = nil,
  monitor = nil,
  poolNames = {},
  storageNames = {},
  modMap = {},
  pinnedTargets = {},
  overflowName = nil,
  ignoredNames = {},
  markers = {},
  candidateInventories = {},
  freePool = {},
  index = {},
  order = {},
  totalItems = 0,
  totalStacks = 0,
  lastScan = 0,
  lastTopologyCheck = 0,
  topologySig = "",
  markerSig = "",
  lastShownKeys = {},
  lastShownQuery = "",
  dirty = true,
  rebalancePending = false,
  outputReservations = {},
}

local SIDE_ORDER = { "top", "bottom", "left", "right", "front", "back" }

local function nowMs()
  return os.epoch("utc")
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sortedNames()
  local names = peripheral.getNames()
  table.sort(names)
  return names
end

local function isInventory(name)
  return name and peripheral.isPresent(name) and peripheral.hasType(name, "inventory")
end

local function invSize(inv)
  if not inv or not inv.size then
    return 0
  end

  local ok, value = pcall(inv.size)
  if ok and value then
    return value
  end

  return 0
end

local function invList(inv)
  if not inv or not inv.list then
    return {}
  end

  local ok, value = pcall(inv.list)
  if ok and type(value) == "table" then
    return value
  end

  return {}
end

local function invDetail(inv, slot)
  if not inv or not inv.getItemDetail then
    return nil
  end

  local ok, value = pcall(inv.getItemDetail, slot)
  if ok then
    return value
  end

  return nil
end

local function listPeripheralTypes(name)
  local raw = { peripheral.getType(name) }
  local out = {}
  local seen = {}

  for _, value in ipairs(raw) do
    if value and value ~= "" and not seen[value] then
      seen[value] = true
      out[#out + 1] = tostring(value)
    end
  end

  table.sort(out)
  return out
end

local function joinList(values, sep)
  local out = {}
  for _, value in ipairs(values or {}) do
    out[#out + 1] = tostring(value)
  end
  return table.concat(out, sep or ", ")
end

local function uniqueList(list)
  local out = {}
  local seen = {}

  for _, value in ipairs(list or {}) do
    if value and value ~= "" and not seen[value] then
      seen[value] = true
      out[#out + 1] = value
    end
  end

  return out
end

local function formatCount(n)
  local s = tostring(n or 0)
  local out = ""

  while #s > 3 do
    out = "." .. s:sub(-3) .. out
    s = s:sub(1, -4)
  end

  return s .. out
end

local function clip(text, maxLen)
  text = tostring(text or "")

  if maxLen <= 0 then
    return ""
  end

  if #text <= maxLen then
    return text
  end

  if maxLen == 1 then
    return text:sub(1, 1)
  end

  return text:sub(1, maxLen - 1) .. ">"
end

local function outputSlotCount()
  if not state.io then
    return 0
  end

  local size = invSize(state.io)
  if size <= 1 then
    return 1
  end

  local count = math.floor(size * OUTPUT_FRACTION + 0.5)
  count = math.max(MIN_OUTPUT_SLOTS, math.min(MAX_OUTPUT_SLOTS, count))

  if count >= size then
    count = math.max(1, math.floor(size / 2))
  end

  return count
end

local function outputStart()
  if not state.io then
    return 1
  end

  local size = invSize(state.io)
  return math.max(1, size - outputSlotCount() + 1)
end

local function inputEnd()
  return math.max(0, outputStart() - 1)
end

local function entryKey(item)
  return tostring(item.name) .. "#" .. tostring(item.nbt or "")
end

local function namespaceOf(itemName)
  return tostring(itemName):match("^(.-):") or "unknown"
end

local function baseNameOf(itemName)
  return tostring(itemName):match(":(.+)$") or tostring(itemName)
end

local function containsAny(text, parts)
  for _, part in ipairs(parts or {}) do
    if text:find(part, 1, true) then
      return true
    end
  end

  return false
end

local function prettyModName(ns)
  local map = {
    create = "Create",
    mekanism = "Mekanism",
    farmersdelight = "Farmer's Delight",
    supplementaries = "Supplementaries",
    computercraft = "CC",
    storagedrawers = "Storage Drawers",
    thermal = "Thermal",
    immersiveengineering = "Immersive Engineering",
    ae2 = "Applied Energistics 2",
  }

  if map[ns] then
    return map[ns]
  end

  ns = tostring(ns or ""):gsub("_", " ")
  return (ns:gsub("(%a)([%w ]*)", function(a, b)
    return a:upper() .. b:lower()
  end))
end

local function routeLabel(routeKey)
  routeKey = tostring(routeKey or "")

  if routeKey == "overflow" then
    return "Overflow"
  end

  local group = routeKey:match("^group:(.+)$")
  if group then
    return GROUP_LABELS[group] or ("Gruppe " .. group)
  end

  local mod = routeKey:match("^mod:(.+)$")
  if mod then
    return prettyModName(mod)
  end

  return routeKey
end

local function normalizeRouteKey(key)
  key = trim(tostring(key or "")):lower()
  if key == "" then
    return nil
  end

  key = key:gsub("^%[", ""):gsub("%]$", "")

  if key == "io" then
    return "io"
  end

  if key == "ignore" or key == "off" then
    return "ignore"
  end

  if key == "overflow" then
    return "overflow"
  end

  local group = key:match("^group:(.+)$") or key:match("^gruppe:(.+)$")
  if group then
    group = trim(group)
    if GROUP_LABELS[group] then
      return "group:" .. group
    end
    return nil
  end

  local mod = key:match("^mod:(.+)$")
  if mod then
    mod = trim(mod)
    if mod ~= "" then
      return "mod:" .. mod
    end
    return nil
  end

  if GROUP_LABELS[key] then
    return "group:" .. key
  end

  return "mod:" .. key
end

local function parseMarkerText(text)
  local raw = trim(text)
  if raw == "" then
    return nil
  end

  local normalized = raw:upper():gsub("%s+", "")
  normalized = normalized:gsub("^%[", ""):gsub("%]$", "")

  if not normalized:find("^LAGER:") then
    return nil
  end

  local body = normalized:sub(7)

  if body == "IO" then
    return { kind = "io", label = "IO" }
  end

  if body == "IGNORE" or body == "OFF" then
    return { kind = "ignore", label = "IGNORE" }
  end

  if body == "OVERFLOW" then
    return { kind = "overflow", label = "OVERFLOW", routeKey = "overflow" }
  end

  local group = body:match("^GROUP:(.+)$") or body:match("^GRUPPE:(.+)$")
  if group then
    group = group:lower()
    if GROUP_LABELS[group] then
      return {
        kind = "route",
        label = "GROUP:" .. group,
        routeKey = "group:" .. group,
      }
    end
    return nil
  end

  local mod = body:match("^MOD:(.+)$")
  if mod and mod ~= "" then
    mod = mod:lower()
    return {
      kind = "route",
      label = "MOD:" .. mod,
      routeKey = "mod:" .. mod,
    }
  end

  local plain = body:lower()
  if GROUP_LABELS[plain] then
    return {
      kind = "route",
      label = "GROUP:" .. plain,
      routeKey = "group:" .. plain,
    }
  end

  return nil
end

local function readInventoryMarker(name)
  if not isInventory(name) then
    return nil
  end

  local inv = peripheral.wrap(name)
  if not inv then
    return nil
  end

  local detail = invDetail(inv, ROLE_MARKER_SLOT)
  if not detail then
    return nil
  end

  local marker = parseMarkerText(detail.displayName or detail.name)
  if marker then
    marker.itemName = detail.name
    marker.displayName = detail.displayName or detail.name
  end

  return marker
end

local function inventorySignature()
  local out = {}

  for _, name in ipairs(sortedNames()) do
    if isInventory(name) then
      local inv = peripheral.wrap(name)
      out[#out + 1] = tostring(name) .. "=" .. tostring(invSize(inv))
    end
  end

  return table.concat(out, "|")
end

local function markerSignature()
  local out = {}

  for _, name in ipairs(sortedNames()) do
    if isInventory(name) then
      local marker = readInventoryMarker(name)
      if marker then
        out[#out + 1] = tostring(name) .. "=" .. tostring(marker.label or marker.routeKey or marker.kind)
      end
    end
  end

  return table.concat(out, "|")
end

local function chooseIOName(markedIO)
  if IO_NAME and isInventory(IO_NAME) then
    return IO_NAME
  end

  if markedIO and isInventory(markedIO) then
    return markedIO
  end

  if state.ioName and isInventory(state.ioName) then
    return state.ioName
  end

  for _, side in ipairs(SIDE_ORDER) do
    if isInventory(side) then
      return side
    end
  end

  for _, name in ipairs(sortedNames()) do
    if isInventory(name) and peripheral.hasType(name, "minecraft:chest") then
      return name
    end
  end

  for _, name in ipairs(sortedNames()) do
    if isInventory(name) then
      return name
    end
  end

  return nil
end

local function getMonitor()
  if MONITOR_NAME and MONITOR_NAME ~= "" then
    if peripheral.isPresent(MONITOR_NAME) and peripheral.hasType(MONITOR_NAME, "monitor") then
      return peripheral.wrap(MONITOR_NAME)
    end

    return nil
  end

  return peripheral.find("monitor")
end

local function loadMap()
  state.modMap = {}

  if not fs.exists(MAP_FILE) then
    return
  end

  local h = fs.open(MAP_FILE, "r")
  if not h then
    return
  end

  local raw = h.readAll()
  h.close()

  local data = textutils.unserialize(raw)
  if type(data) ~= "table" then
    return
  end

  for key, invName in pairs(data) do
    local routeKey = normalizeRouteKey(key)
    if routeKey and type(invName) == "string" and invName ~= "" then
      state.modMap[routeKey] = invName
    end
  end
end

local function saveMap()
  local h = fs.open(MAP_FILE, "w")
  if not h then
    return
  end

  h.write(textutils.serialize(state.modMap))
  h.close()
end

local function classifyCoreGroup(itemName)
  local base = baseNameOf(itemName)

  if base == "ancient_debris"
    or base:find("_ore", 1, true)
    or base:find("ore_", 1, true)
    or base:find("raw_", 1, true)
    or base:find("_raw", 1, true)
    or base:find("_ingot", 1, true)
    or base:find("_nugget", 1, true)
  then
    return "ores"
  end

  local stoneExact = {
    stone = true,
    cobblestone = true,
    deepslate = true,
    cobbled_deepslate = true,
    blackstone = true,
    basalt = true,
    andesite = true,
    diorite = true,
    granite = true,
    tuff = true,
    calcite = true,
    dripstone_block = true,
    netherrack = true,
    end_stone = true,
    sandstone = true,
    red_sandstone = true,
    gravel = true,
    flint = true,
    limestone = true,
    marble = true,
    scoria = true,
    slate = true,
    smooth_stone = true,
    dirt = true,
    coarse_dirt = true,
    rooted_dirt = true,
    podzol = true,
    mycelium = true,
    clay = true,
    sand = true,
    red_sand = true,
    soul_sand = true,
    soul_soil = true,
    terracotta = true,
  }

  if stoneExact[base] then
    return "stone"
  end

  local stoneParts = {
    "cobblestone",
    "deepslate",
    "blackstone",
    "basalt",
    "andesite",
    "diorite",
    "granite",
    "tuff",
    "calcite",
    "dripstone",
    "netherrack",
    "end_stone",
    "sandstone",
    "gravel",
    "limestone",
    "marble",
    "scoria",
    "slate",
    "terracotta",
    "concrete",
    "dirt",
    "sand",
    "clay",
  }

  if containsAny(base, stoneParts) then
    return "stone"
  end

  local woodParts = {
    "_log",
    "_wood",
    "_planks",
    "_stem",
    "_hyphae",
    "stripped_",
    "leaves",
    "sapling",
    "bamboo",
    "mangrove_roots",
    "_boat",
    "chest_boat",
    "_slab",
    "_stairs",
    "_door",
    "_trapdoor",
    "_fence",
    "_fence_gate",
    "_button",
    "_pressure_plate",
    "_sign",
    "_hanging_sign",
  }

  if containsAny(base, woodParts) then
    return "wood"
  end

  return nil
end

local function classifyVanillaGroup(itemName)
  local base = baseNameOf(itemName)

  if containsAny(base, {
    "redstone",
    "repeater",
    "comparator",
    "observer",
    "piston",
    "hopper",
    "dispenser",
    "dropper",
    "lever",
    "tripwire_hook",
    "daylight_detector",
    "target",
    "lightning_rod",
    "sculk_sensor",
    "calibrated_sculk_sensor",
    "note_block",
    "jukebox",
  }) then
    return "redstone"
  end

  if containsAny(base, {
    "_sword",
    "_pickaxe",
    "_axe",
    "_shovel",
    "_hoe",
    "_helmet",
    "_chestplate",
    "_leggings",
    "_boots",
    "shield",
    "bow",
    "crossbow",
    "trident",
    "fishing_rod",
    "shears",
    "flint_and_steel",
    "brush",
    "spyglass",
    "compass",
    "clock",
    "elytra",
  }) then
    return "tools"
  end

  if containsAny(base, {
    "apple",
    "bread",
    "stew",
    "soup",
    "pie",
    "cookie",
    "cake",
    "melon_slice",
    "dried_kelp",
    "carrot",
    "potato",
    "beetroot",
    "pumpkin_pie",
    "sweet_berries",
    "glow_berries",
    "chorus_fruit",
    "porkchop",
    "beef",
    "mutton",
    "chicken",
    "rabbit",
    "cod",
    "salmon",
    "tropical_fish",
    "pufferfish",
    "golden_apple",
    "golden_carrot",
    "honey_bottle",
  }) then
    return "food"
  end

  if containsAny(base, {
    "_seeds",
    "wheat",
    "carrot",
    "potato",
    "beetroot",
    "pumpkin",
    "melon",
    "sugar_cane",
    "bamboo",
    "cactus",
    "kelp",
    "sapling",
    "propagule",
    "leaves",
    "vine",
    "flower",
    "tulip",
    "dandelion",
    "poppy",
    "orchid",
    "allium",
    "azure_bluet",
    "oxeye_daisy",
    "cornflower",
    "lily_of_the_valley",
    "sunflower",
    "lilac",
    "rose_bush",
    "peony",
    "moss",
    "fern",
    "grass",
    "roots",
  }) then
    return "farming"
  end

  if containsAny(base, {
    "rotten_flesh",
    "bone",
    "bone_meal",
    "string",
    "spider_eye",
    "gunpowder",
    "slime_ball",
    "magma_cream",
    "ender_pearl",
    "blaze_rod",
    "blaze_powder",
    "ghast_tear",
    "phantom_membrane",
    "leather",
    "feather",
    "rabbit_hide",
    "ink_sac",
    "glow_ink_sac",
    "nautilus_shell",
    "prismarine_shard",
    "prismarine_crystals",
    "shulker_shell",
    "echo_shard",
  }) then
    return "mobdrops"
  end

  return "misc"
end

local function routeKeyForItemName(itemName)
  local group = classifyCoreGroup(itemName)
  if group then
    return "group:" .. group
  end

  local ns = namespaceOf(itemName)
  if ns == "minecraft" then
    return "group:" .. classifyVanillaGroup(itemName)
  end

  return "mod:" .. ns
end

local function formatDisplayEntry(value)
  if type(value) == "table" then
    local name = value.displayName or value.name or value.id or value.effect or value.key or tostring(value)

    if value.level then
      return tostring(name) .. " " .. tostring(value.level)
    end

    if value.amplifier then
      return tostring(name) .. " " .. tostring(value.amplifier)
    end

    return tostring(name)
  end

  return tostring(value)
end

local function joinDisplayList(entries, maxItems)
  if type(entries) ~= "table" or #entries == 0 then
    return ""
  end

  local parts = {}
  maxItems = maxItems or #entries

  for i, value in ipairs(entries) do
    if i > maxItems then
      parts[#parts + 1] = "+" .. tostring(#entries - maxItems)
      break
    end

    parts[#parts + 1] = formatDisplayEntry(value)
  end

  return table.concat(parts, ", ")
end

local function buildDescription(detail)
  if not detail then
    return ""
  end

  if detail.enchantments and #detail.enchantments > 0 then
    return joinDisplayList(detail.enchantments, 3)
  end

  if detail.potionEffects and #detail.potionEffects > 0 then
    return joinDisplayList(detail.potionEffects, 2)
  end

  if detail.lore and #detail.lore > 0 then
    return tostring(detail.lore[1])
  end

  local ns = namespaceOf(detail.name or "")
  if ns ~= "minecraft" then
    return "[" .. prettyModName(ns) .. "]"
  end

  return ""
end

local function entryLabel(entry)
  if entry.desc and entry.desc ~= "" then
    return entry.displayName .. " - " .. entry.desc
  end

  return entry.displayName
end

local function buildConfiguredTargets()
  local pinned = {}
  local overflowName = nil

  for key, invName in pairs(SPECIAL_TARGETS) do
    if invName and invName ~= "" and isInventory(invName) then
      if key == "overflow" then
        overflowName = invName
      elseif GROUP_LABELS[key] then
        pinned["group:" .. key] = invName
      end
    end
  end

  return pinned, overflowName
end

local function isMarkerSlot(invName, slot)
  return slot == ROLE_MARKER_SLOT and state.markers[invName] ~= nil
end

local function cleanupOutputReservations()
  if not state.io then
    state.outputReservations = {}
    return
  end

  local now = nowMs()

  for slot, expiresAt in pairs(state.outputReservations) do
    if expiresAt <= now or not invDetail(state.io, slot) then
      state.outputReservations[slot] = nil
    end
  end
end

local function reserveOutputSlot(slot)
  state.outputReservations[slot] = nowMs() + (OUTPUT_HOLD_SECONDS * 1000)
end

local function isReservedOutputSlot(slot)
  local expiresAt = state.outputReservations[slot]
  if not expiresAt then
    return false
  end

  if not state.io then
    state.outputReservations[slot] = nil
    return false
  end

  if expiresAt <= nowMs() or not invDetail(state.io, slot) then
    state.outputReservations[slot] = nil
    return false
  end

  return true
end

local function refreshTopology()
  local oldIOName = state.ioName
  local configuredPinned, configuredOverflow = buildConfiguredTargets()
  local markers = {}
  local ignored = {}
  local markedIO = nil
  local candidates = {}
  local markerRouteOwner = {}
  local overflowMarkerOwner = nil

  for _, name in ipairs(sortedNames()) do
    if isInventory(name) then
      local inv = peripheral.wrap(name)
      local info = {
        name = name,
        size = invSize(inv),
        types = listPeripheralTypes(name),
      }

      local marker = readInventoryMarker(name)
      if marker then
        markers[name] = marker
        info.marker = marker

        if marker.kind == "io" then
          if not markedIO then
            markedIO = name
          else
            info.note = "zweiter IO-Marker ignoriert"
          end
        elseif marker.kind == "ignore" then
          ignored[name] = true
        elseif marker.kind == "overflow" then
          if not overflowMarkerOwner then
            configuredOverflow = name
            overflowMarkerOwner = name
          else
            info.note = "zweiter Overflow-Marker ignoriert"
          end
        elseif marker.kind == "route" then
          if not markerRouteOwner[marker.routeKey] then
            configuredPinned[marker.routeKey] = name
            markerRouteOwner[marker.routeKey] = name
          else
            info.note = "zweiter Gruppen-/Mod-Marker ignoriert"
          end
        end
      end

      candidates[#candidates + 1] = info
    end
  end

  state.ioName = chooseIOName(markedIO)
  if not state.ioName then
    error("Keine I/O-Kiste gefunden.\nSetz IO_NAME oder nutze einen Marker in Slot 1: LAGER:IO", 0)
  end

  if not isInventory(state.ioName) then
    error("IO_NAME ist kein Inventar: " .. tostring(state.ioName), 0)
  end

  state.io = peripheral.wrap(state.ioName)
  state.monitor = getMonitor()
  if state.monitor then
    state.monitor.setTextScale(MONITOR_SCALE)
    state.monitor.setBackgroundColor(colors.black)
    state.monitor.setTextColor(colors.white)
  end

  state.markers = markers
  state.ignoredNames = ignored
  state.pinnedTargets = configuredPinned
  state.overflowName = configuredOverflow

  local reservedPool = {}
  reservedPool[state.ioName] = true
  if state.overflowName and isInventory(state.overflowName) then
    reservedPool[state.overflowName] = true
  end

  for _, invName in pairs(state.pinnedTargets) do
    if invName and isInventory(invName) then
      reservedPool[invName] = true
    end
  end

  for invName in pairs(state.ignoredNames) do
    reservedPool[invName] = true
  end

  local poolNames = {}
  if AUTO_MOD_POOL then
    for _, name in ipairs(sortedNames()) do
      if isInventory(name) and not reservedPool[name] then
        poolNames[#poolNames + 1] = name
      end
    end
  else
    for _, name in ipairs(MOD_POOL_NAMES) do
      if isInventory(name) and not reservedPool[name] then
        poolNames[#poolNames + 1] = name
      end
    end
  end
  table.sort(poolNames)
  state.poolNames = uniqueList(poolNames)

  local storageNames = {}
  for _, name in ipairs(sortedNames()) do
    if isInventory(name) and name ~= state.ioName and not state.ignoredNames[name] then
      storageNames[#storageNames + 1] = name
    end
  end
  table.sort(storageNames)
  state.storageNames = uniqueList(storageNames)

  if #state.storageNames == 0 then
    error("Keine Lager-Inventare gefunden.\nMarkiere Kisten mit LAGER:IGNORE, falls fremde Inventare stoeren.", 0)
  end

  local validPool = {}
  local validStorage = {}
  local used = {}
  for _, name in ipairs(state.poolNames) do
    validPool[name] = true
  end
  for _, name in ipairs(state.storageNames) do
    validStorage[name] = true
  end

  local cleanMap = {}
  for routeKey, invName in pairs(state.pinnedTargets) do
    if invName and validStorage[invName] then
      cleanMap[routeKey] = invName
      used[invName] = true
    end
  end

  if state.overflowName and validStorage[state.overflowName] then
    used[state.overflowName] = true
  else
    state.overflowName = nil
  end

  for key, invName in pairs(state.modMap) do
    local routeKey = normalizeRouteKey(key)
    if routeKey
      and routeKey ~= "overflow"
      and not cleanMap[routeKey]
      and validPool[invName]
      and not used[invName]
    then
      cleanMap[routeKey] = invName
      used[invName] = true
    end
  end

  state.modMap = cleanMap
  state.freePool = {}
  for _, name in ipairs(state.poolNames) do
    if not used[name] then
      state.freePool[#state.freePool + 1] = name
    end
  end

  local pinnedByInv = {}
  for routeKey, invName in pairs(state.pinnedTargets) do
    if invName then
      pinnedByInv[invName] = routeKey
    end
  end

  for _, info in ipairs(candidates) do
    if info.name == state.ioName then
      info.role = "I/O"
    elseif state.ignoredNames[info.name] then
      info.role = "Ignoriert"
    elseif state.overflowName and info.name == state.overflowName then
      info.role = "Overflow"
    elseif pinnedByInv[info.name] then
      info.role = routeLabel(pinnedByInv[info.name])
    elseif validPool[info.name] then
      info.role = "Auto-Pool"
    elseif validStorage[info.name] then
      info.role = "Lager"
    else
      info.role = "-"
    end
  end
  state.candidateInventories = candidates

  if oldIOName ~= state.ioName then
    state.outputReservations = {}
  end

  saveMap()
  state.topologySig = inventorySignature()
  state.markerSig = markerSignature()
  state.lastTopologyCheck = nowMs()
  state.rebalancePending = true
  state.dirty = true
end

local function ensureTopology(force)
  local now = nowMs()

  if not force and state.lastTopologyCheck > 0 and (now - state.lastTopologyCheck) < (TOPOLOGY_REFRESH_INTERVAL * 1000) then
    return false
  end

  state.lastTopologyCheck = now

  local sig = inventorySignature()
  local markerSig = markerSignature()
  if force or sig ~= state.topologySig or markerSig ~= state.markerSig then
    refreshTopology()
    return true
  end

  return false
end

local function ensureRouteTarget(routeKey)
  if routeKey == "overflow" then
    return state.overflowName
  end

  local current = state.modMap[routeKey]
  if current and isInventory(current) then
    return current
  end

  local nextFree = table.remove(state.freePool, 1)
  if nextFree then
    state.modMap[routeKey] = nextFree
    saveMap()
    return nextFree
  end

  if state.overflowName and isInventory(state.overflowName) then
    return state.overflowName
  end

  return nil
end

local function chooseTargetForItem(item)
  local routeKey = routeKeyForItemName(item.name)
  return ensureRouteTarget(routeKey), routeKey
end

local function scanStorage()
  local index = {}
  local order = {}
  local totalItems = 0
  local totalStacks = 0

  for _, invName in ipairs(state.storageNames) do
    local inv = peripheral.wrap(invName)
    if inv then
      for slot, item in pairs(invList(inv)) do
        if not isMarkerSlot(invName, slot) then
          totalStacks = totalStacks + 1
          totalItems = totalItems + item.count

          local key = entryKey(item)
          local entry = index[key]
          if not entry then
            local detail = invDetail(inv, slot)
            entry = {
              key = key,
              name = item.name,
              nbt = item.nbt,
              displayName = (detail and detail.displayName) or item.name,
              desc = buildDescription(detail),
              count = 0,
              locs = {},
            }
            index[key] = entry
            order[#order + 1] = entry
          end

          entry.count = entry.count + item.count
          entry.locs[#entry.locs + 1] = {
            inv = invName,
            slot = slot,
            count = item.count,
          }
        end
      end
    end
  end

  table.sort(order, function(a, b)
    local ad = a.displayName:lower()
    local bd = b.displayName:lower()

    if ad == bd then
      local aDesc = tostring(a.desc or ""):lower()
      local bDesc = tostring(b.desc or ""):lower()

      if aDesc == bDesc then
        return a.name < b.name
      end

      return aDesc < bDesc
    end

    return ad < bd
  end)

  state.index = index
  state.order = order
  state.totalItems = totalItems
  state.totalStacks = totalStacks
  state.lastScan = nowMs()
  state.dirty = false
end

local function ensureFresh(force)
  local topologyChanged = ensureTopology(force)

  if force or topologyChanged or state.dirty or (nowMs() - state.lastScan) >= (SCAN_INTERVAL * 1000) then
    scanStorage()
  end
end

local function pushItemsSafe(fromInv, targetName, fromSlot, amount, toSlot)
  if not fromInv or not targetName or not isInventory(targetName) then
    return 0
  end

  local ok, sent
  if toSlot then
    ok, sent = pcall(fromInv.pushItems, targetName, fromSlot, amount, toSlot)
  else
    ok, sent = pcall(fromInv.pushItems, targetName, fromSlot, amount)
  end

  if ok and sent and sent > 0 then
    return sent
  end

  return 0
end

local function pushFromIO(targetName, fromSlot, toSlot)
  if not targetName or targetName == state.ioName or not isInventory(targetName) then
    return 0
  end

  local current = invDetail(state.io, fromSlot)
  if not current then
    return 0
  end

  return pushItemsSafe(state.io, targetName, fromSlot, current.count, toSlot)
end

local function pushBetweenInventories(fromInvName, targetName, fromSlot, amount, toSlot)
  if not fromInvName or not targetName or fromInvName == targetName then
    return 0
  end

  if not isInventory(fromInvName) or not isInventory(targetName) then
    return 0
  end

  local fromInv = peripheral.wrap(fromInvName)
  if not fromInv then
    return 0
  end

  local detail = invDetail(fromInv, fromSlot)
  if not detail then
    return 0
  end

  return pushItemsSafe(fromInv, targetName, fromSlot, amount or detail.count, toSlot)
end

local function moveIntoKnownStacks(fromSlot, item)
  local entry = state.index[entryKey(item)]
  if not entry then
    return 0
  end

  local moved = 0

  for _, loc in ipairs(entry.locs) do
    if not invDetail(state.io, fromSlot) then
      break
    end

    if loc.inv ~= state.ioName and isInventory(loc.inv) then
      moved = moved + pushFromIO(loc.inv, fromSlot, loc.slot)
    end
  end

  return moved
end

local function moveIntoAnyStorage(fromSlot, attemptedInventories)
  local moved = 0

  for _, invName in ipairs(state.poolNames) do
    if invName ~= state.ioName and isInventory(invName) and not attemptedInventories[invName] then
      attemptedInventories[invName] = true
      moved = moved + pushFromIO(invName, fromSlot)

      if not invDetail(state.io, fromSlot) then
        break
      end
    end
  end

  return moved
end

local function sortInput()
  ensureFresh(false)
  cleanupOutputReservations()

  local movedAny = false
  local size = invSize(state.io)

  for slot = 1, size do
    if not isReservedOutputSlot(slot) and not isMarkerSlot(state.ioName, slot) then
      while true do
        local item = invDetail(state.io, slot)
        if not item then
          break
        end

        local moved = 0
        moved = moved + moveIntoKnownStacks(slot, item)

        local attemptedInventories = {}

        if invDetail(state.io, slot) then
          local target = chooseTargetForItem(item)
          if target and not attemptedInventories[target] then
            attemptedInventories[target] = true
            moved = moved + pushFromIO(target, slot)
          end
        end

        if invDetail(state.io, slot)
          and state.overflowName
          and isInventory(state.overflowName)
          and not attemptedInventories[state.overflowName]
        then
          attemptedInventories[state.overflowName] = true
          moved = moved + pushFromIO(state.overflowName, slot)
        end

        if invDetail(state.io, slot) then
          moved = moved + moveIntoAnyStorage(slot, attemptedInventories)
        end

        if moved == 0 then
          break
        end

        movedAny = true
        state.dirty = true
      end
    end
  end

  if movedAny then
    state.dirty = true
  end
end

local function rebalanceBatch(maxMoves)
  ensureFresh(false)

  local movedStacks = 0
  local movedItems = 0

  for _, invName in ipairs(state.storageNames) do
    if movedStacks >= maxMoves then
      break
    end

    local inv = peripheral.wrap(invName)
    if inv then
      for slot, item in pairs(invList(inv)) do
        if movedStacks >= maxMoves then
          break
        end

        if not isMarkerSlot(invName, slot) then
          local detail = invDetail(inv, slot)
          if detail then
            local targetName = chooseTargetForItem(detail)
            if targetName and targetName ~= invName then
              local sent = pushBetweenInventories(invName, targetName, slot, detail.count)

              if sent == 0
                and state.overflowName
                and state.overflowName ~= invName
                and targetName ~= state.overflowName
              then
                sent = pushBetweenInventories(invName, state.overflowName, slot, detail.count)
              end

              if sent > 0 then
                movedStacks = movedStacks + 1
                movedItems = movedItems + sent
                state.dirty = true
              end
            end
          end
        end
      end
    end
  end

  if movedStacks == 0 then
    state.rebalancePending = false
  end

  return movedStacks, movedItems
end

local function moveIntoOutput(fromInvName, fromSlot, amount)
  local inv = peripheral.wrap(fromInvName)
  if not inv then
    return 0
  end

  cleanupOutputReservations()

  local moved = 0
  local size = invSize(state.io)
  for toSlot = outputStart(), size do
    local remaining = amount - moved
    if remaining <= 0 then
      break
    end

    if not isReservedOutputSlot(toSlot) and not isMarkerSlot(state.ioName, toSlot) then
      local sent = pushItemsSafe(inv, state.ioName, fromSlot, remaining, toSlot)
      if sent > 0 then
        moved = moved + sent
        reserveOutputSlot(toSlot)
      end
    end
  end

  return moved
end

local function rememberShown(entries, query)
  state.lastShownKeys = {}
  state.lastShownQuery = tostring(query or "")

  for i, entry in ipairs(entries or {}) do
    state.lastShownKeys[i] = entry.key
  end
end

local function entryFromReference(ref)
  ref = trim(ref)
  if ref:sub(1, 1) ~= "#" then
    return nil
  end

  local idx = tonumber(ref:sub(2))
  if not idx then
    return nil
  end

  ensureFresh(false)
  local key = state.lastShownKeys[idx]
  if not key then
    return nil
  end

  return state.index[key]
end

local function findMatches(query)
  ensureFresh(false)

  local q = trim(query or ""):lower()
  local hits = {}

  if q == "" then
    return hits
  end

  if q:sub(1, 1) == "@" then
    local routeQuery = trim(q:sub(2))
    for _, entry in ipairs(state.order) do
      local routeKey = routeKeyForItemName(entry.name)
      local routeName = routeLabel(routeKey):lower()
      local ns = namespaceOf(entry.name):lower()

      if routeKey == routeQuery
        or routeKey == ("mod:" .. routeQuery)
        or routeKey == ("group:" .. routeQuery)
        or ns == routeQuery
        or routeName:find(routeQuery, 1, true)
        or routeKey:find(routeQuery, 1, true)
      then
        hits[#hits + 1] = entry
      end
    end

    return hits
  end

  local exact = {}
  local fuzzy = {}

  for _, entry in ipairs(state.order) do
    local name = entry.name:lower()
    local display = entry.displayName:lower()
    local desc = tostring(entry.desc or ""):lower()

    if name == q or display == q or (q ~= "" and desc == q) then
      exact[#exact + 1] = entry
    end
  end

  if #exact > 0 then
    return exact
  end

  for _, entry in ipairs(state.order) do
    local name = entry.name:lower()
    local display = entry.displayName:lower()
    local desc = tostring(entry.desc or ""):lower()

    if name:find(q, 1, true) or display:find(q, 1, true) or (q ~= "" and desc:find(q, 1, true)) then
      fuzzy[#fuzzy + 1] = entry
    end
  end

  return fuzzy
end

local function printEntries(entries, maxLines)
  maxLines = maxLines or #entries

  for i = 1, math.min(#entries, maxLines) do
    local e = entries[i]
    print(('%2d) %s x%s'):format(i, entryLabel(e), formatCount(e.count)))
  end

  if #entries > maxLines then
    print(('... %d weitere Treffer'):format(#entries - maxLines))
  end
end

local function chooseMatch(matches)
  if #matches == 1 then
    return matches[1]
  end

  if #matches > 30 then
    print("Zu viele Treffer. Bitte Suchbegriff verfeinern.")
    rememberShown(matches, "")
    printEntries(matches, 30)
    return nil
  end

  rememberShown(matches, "")
  print("Mehrdeutig.")
  print("Waehle die passende Nummer:")
  printEntries(matches, #matches)

  while true do
    write(("Auswahl 1-%d (leer = abbrechen): "):format(#matches))
    local line = read()

    if not line or line == "" then
      return nil
    end

    local idx = tonumber(line)
    if idx and matches[idx] then
      return matches[idx]
    end

    print("Bitte eine gueltige Nummer eingeben.")
  end
end

local function withdraw(query, amount)
  ensureFresh(true)

  local entry = entryFromReference(query)
  if not entry then
    local matches = findMatches(query)
    if #matches == 0 then
      print("Nichts gefunden: " .. tostring(query))
      return
    end

    entry = chooseMatch(matches)
    if not entry then
      print("Abgebrochen.")
      return
    end
  end

  local remaining = amount
  for _, loc in ipairs(entry.locs) do
    if remaining <= 0 then
      break
    end

    local moved = moveIntoOutput(loc.inv, loc.slot, remaining)
    remaining = remaining - moved
  end

  local movedTotal = amount - remaining
  if movedTotal > 0 then
    state.dirty = true
    ensureFresh(true)
  end

  print(("Ausgegeben: %d x %s"):format(movedTotal, entry.displayName))
  if entry.desc and entry.desc ~= "" then
    print("Variante: " .. entry.desc)
  end

  if remaining > 0 then
    print(("Nicht mehr vorhanden oder Ausgabebereich belegt: %d"):format(remaining))
  end
end

local function buildGroupOverview()
  local stats = {}

  for _, entry in ipairs(state.order) do
    local routeKey = routeKeyForItemName(entry.name)
    local row = stats[routeKey]
    if not row then
      row = {
        routeKey = routeKey,
        types = 0,
        items = 0,
      }
      stats[routeKey] = row
    end

    row.types = row.types + 1
    row.items = row.items + entry.count
  end

  local rows = {}
  for _, row in pairs(stats) do
    rows[#rows + 1] = row
  end

  table.sort(rows, function(a, b)
    if a.items == b.items then
      return routeLabel(a.routeKey) < routeLabel(b.routeKey)
    end

    return a.items > b.items
  end)

  return rows
end

local function printGroupOverview(limit)
  ensureFresh(false)

  local rows = buildGroupOverview()
  print(("Gruppen: %d | Typen: %d | Items: %s"):format(#rows, #state.order, formatCount(state.totalItems)))

  limit = limit or #rows
  for i = 1, math.min(#rows, limit) do
    local row = rows[i]
    print(("%2d) %s | %d Typen | %s Items"):format(i, routeLabel(row.routeKey), row.types, formatCount(row.items)))
  end

  if #rows > limit then
    print(("... %d weitere Gruppen"):format(#rows - limit))
  end
end

local function listItems(filter)
  ensureFresh(false)
  filter = trim(filter or "")

  if filter == "" then
    printGroupOverview(12)
    print("")
    print("Suche: list <suchwort>")
    print("Nach Mod/Gruppe: list @create oder list @stone")
    print("Danach: hole #<nummer> [anzahl]")
    return
  end

  local hits = findMatches(filter)
  if #hits == 0 then
    print("Keine Treffer fuer: " .. tostring(filter))
    return
  end

  rememberShown(hits, filter)
  print(("Treffer fuer '%s': %d"):format(filter, #hits))
  printEntries(hits, 20)
  print("Danach geht direkt: hole #<nummer> [anzahl]")
end

local function listAssignments()
  ensureFresh(false)

  print("I/O: " .. tostring(state.ioName))
  print("Marker-Slot: " .. ROLE_MARKER_SLOT .. " (z. B. LAGER:IO)")
  print("Input-Bereich: 1-" .. inputEnd())
  print("Output-Bereich: " .. outputStart() .. "-" .. invSize(state.io))
  print("Ausgabe-Schutz: " .. OUTPUT_HOLD_SECONDS .. "s")
  print("")
  print("Zuordnung:")

  local rows = {}
  for routeKey, invName in pairs(state.modMap) do
    rows[#rows + 1] = {
      routeKey = routeKey,
      inv = invName,
      pinned = state.pinnedTargets[routeKey] == invName,
    }
  end

  table.sort(rows, function(a, b)
    return routeLabel(a.routeKey) < routeLabel(b.routeKey)
  end)

  if #rows == 0 then
    print(" noch keine")
  else
    for _, row in ipairs(rows) do
      local prefix = row.pinned and " * " or "   "
      print(prefix .. routeLabel(row.routeKey) .. " -> " .. tostring(row.inv))
    end
  end

  if state.overflowName then
    print("")
    print("Overflow -> " .. tostring(state.overflowName))
  end

  print("")
  print("Freie Auto-Kisten: " .. #state.freePool)
end

local function listInventories()
  ensureTopology(true)

  print("Inventare:")
  for _, info in ipairs(state.candidateInventories) do
    print(("- %s | %d Slots | %s"):format(info.name, info.size or 0, info.role or "-"))

    if info.marker then
      print("  Marker: " .. tostring(info.marker.label or info.marker.routeKey or info.marker.kind))
    end

    if info.note then
      print("  Hinweis: " .. info.note)
    end

    local types = joinList(info.types, ", ")
    if types ~= "" then
      print("  Typen: " .. types)
    end
  end

  print("")
  print("Marker in Slot " .. ROLE_MARKER_SLOT .. ":")
  print(" LAGER:IO")
  print(" LAGER:GROUP:stone")
  print(" LAGER:MOD:create")
  print(" LAGER:OVERFLOW")
  print(" LAGER:IGNORE")
end

local function printStatus()
  ensureFresh(false)

  print("I/O-Kiste: " .. tostring(state.ioName))
  print("Lager-Inventare: " .. tostring(#state.storageNames))
  print("Auto-Pool: " .. tostring(#state.poolNames))
  print("Monitor: " .. (state.monitor and "ja" or "nein"))
  print("Output-Slots: " .. outputStart() .. "-" .. invSize(state.io))
  print("Umsortierung: " .. (state.rebalancePending and "aktiv" or "ruhig"))
  print("Typen: " .. tostring(#state.order) .. " | Items: " .. formatCount(state.totalItems))
end

local function redrawMonitor(page)
  local m = state.monitor
  if not m then
    return 1, 1
  end

  local w, h = m.getSize()
  local lines = math.max(1, h - 2)
  local pages = math.max(1, math.ceil(#state.order / lines))

  if page > pages then
    page = 1
  end

  m.setBackgroundColor(colors.black)
  m.clear()
  m.setTextColor(colors.yellow)
  m.setCursorPos(1, 1)
  m.write(clip(("Lager %d/%d %d Typen %s Items"):format(page, pages, #state.order, formatCount(state.totalItems)), w))

  local startIndex = (page - 1) * lines + 1
  for row = 1, lines do
    local entry = state.order[startIndex + row - 1]
    local y = row + 1

    if y > h then
      break
    end

    if entry then
      local countText = formatCount(entry.count)
      local countWidth = #countText
      local nameWidth = math.max(12, math.floor(w * 0.44))
      local descWidth = math.max(0, w - nameWidth - countWidth - 3)

      m.setTextColor(colors.white)
      m.setCursorPos(1, y)
      m.write(clip(entry.displayName, nameWidth))

      if descWidth > 0 then
        m.setTextColor(colors.lightGray)
        m.setCursorPos(nameWidth + 2, y)
        m.write(clip(entry.desc or "", descWidth))
      end

      m.setTextColor(colors.lime)
      m.setCursorPos(w - countWidth + 1, y)
      m.write(countText)
    end
  end

  return page, pages
end

local function monitorLoop()
  local page = 1

  while true do
    state.monitor = getMonitor()
    if state.monitor then
      state.monitor.setTextScale(MONITOR_SCALE)
      state.monitor.setBackgroundColor(colors.black)
      state.monitor.setTextColor(colors.white)
    end

    ensureFresh(false)

    if state.monitor then
      local currentPage, pageCount = redrawMonitor(page)
      page = currentPage + 1
      if page > pageCount then
        page = 1
      end
    end

    sleep(PAGE_INTERVAL)
  end
end

local function fullRebalance()
  ensureTopology(true)
  ensureFresh(true)

  local totalStacks = 0
  local totalItems = 0
  local loops = 0

  state.rebalancePending = true

  while true do
    local movedStacks, movedItems = rebalanceBatch(REBALANCE_BATCH_MOVES)
    totalStacks = totalStacks + movedStacks
    totalItems = totalItems + movedItems
    loops = loops + 1

    if movedStacks == 0 then
      break
    end

    ensureFresh(true)

    if loops > 5000 then
      break
    end

    sleep(0)
  end

  ensureFresh(true)
  return totalStacks, totalItems
end

local function sorterLoop()
  while true do
    sortInput()

    if state.rebalancePending then
      local movedStacks = select(1, rebalanceBatch(REBALANCE_BATCH_MOVES))
      if movedStacks > 0 then
        ensureFresh(true)
      end
    end

    sleep(SORT_INTERVAL)
  end
end

local function fullScan(doRebalance)
  ensureTopology(true)
  sortInput()

  local movedStacks = 0
  local movedItems = 0
  if doRebalance then
    movedStacks, movedItems = fullRebalance()
  end

  ensureFresh(true)
  return movedStacks, movedItems
end

local function parseQueryAndAmount(args, startIndex)
  if #args < startIndex then
    return "", 1
  end

  local last = #args
  local amount = tonumber(args[#args])
  if amount then
    last = #args - 1
  else
    amount = 1
  end

  if amount < 1 then
    amount = 1
  end

  return table.concat(args, " ", startIndex, last), amount
end

local function printHelp()
  print("Befehle:")
  print(" hilfe")
  print(" status")
  print(" zuordnung")
  print(" inventare")
  print(" gruppen")
  print(" list [filter]")
  print(" hole <name>|#<nummer> [anzahl]")
  print(" scan")
  print(" umsortieren")
  print(" neu")
  print(" stop")
  print("")
  print("Marker in Slot " .. ROLE_MARKER_SLOT .. ":")
  print(" LAGER:IO macht genau diese Kiste zur I/O-Kiste.")
  print(" LAGER:GROUP:stone oder LAGER:MOD:create pinnt eine Lagerkiste.")
  print(" LAGER:OVERFLOW ist die Notfall-Kiste.")
  print(" LAGER:IGNORE nimmt ein Inventar ganz aus dem System.")
end

local function commandLoop()
  term.clear()
  term.setCursorPos(1, 1)
  print("Lagersystem gestartet.")
  printStatus()
  print("")
  printHelp()
  print("")

  while true do
    write("lager> ")
    local line = read()
    local args = {}

    for part in line:gmatch("%S+") do
      args[#args + 1] = part
    end

    local cmd = (args[1] or ""):lower()

    if cmd == "" then
    elseif cmd == "hilfe" then
      printHelp()
    elseif cmd == "status" then
      printStatus()
    elseif cmd == "zuordnung" then
      listAssignments()
    elseif cmd == "inventare" or cmd == "kisten" then
      listInventories()
    elseif cmd == "gruppen" then
      printGroupOverview(50)
    elseif cmd == "scan" then
      local stacks, items = fullScan(true)
      print(("Scan fertig. Neue Kisten uebernommen. Umsortiert: %d Stacks / %s Items"):format(stacks, formatCount(items)))
    elseif cmd == "umsortieren" or cmd == "rebalance" then
      local stacks, items = fullRebalance()
      print(("Umsortiert: %d Stacks / %s Items"):format(stacks, formatCount(items)))
    elseif cmd == "neu" then
      local stacks, items = fullScan(true)
      print(("Peripherie neu geladen. Umsortiert: %d Stacks / %s Items"):format(stacks, formatCount(items)))
      printStatus()
    elseif cmd == "list" then
      listItems(table.concat(args, " ", 2))
    elseif cmd == "hole" then
      local query, amount = parseQueryAndAmount(args, 2)
      if query == "" then
        print("Benutzung: hole <name>|#<nummer> [anzahl]")
      else
        withdraw(query, amount)
      end
    elseif cmd == "stop" or cmd == "exit" then
      print("Programm beendet.")
      return
    else
      print("Unbekannter Befehl. 'hilfe' zeigt die Befehle.")
    end
  end
end

loadMap()
refreshTopology()
ensureFresh(true)

parallel.waitForAny(
  commandLoop,
  function()
    parallel.waitForAll(sorterLoop, monitorLoop)
  end
)
