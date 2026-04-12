local MONITOR_NAME = nil
local MONITOR_SCALE = 0.5
local PAGE_INTERVAL = 4
local SCAN_INTERVAL = 5
local TOPOLOGY_REFRESH_INTERVAL = 10
local ROLE_MARKER_SLOT = 1
local MAP_FILE = "mod_map.txt"
local FINAL_LOCK_FILE = "lager_final_done.txt"

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

local SOURCE_CHEST_TYPES = {
  ["minecraft:chest"] = true,
  ["minecraft:trapped_chest"] = true,
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
  monitor = nil,
  poolNames = {},
  storageNames = {},
  sourceNames = {},
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
  pendingSourceItems = 0,
  pendingSourceStacks = 0,
  lastScan = 0,
  lastTopologyCheck = 0,
  topologySig = "",
  markerSig = "",
  dirty = true,
  migrationLocked = false,
}

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

local function hasAnyType(name, typeSet)
  for typeName in pairs(typeSet or {}) do
    if peripheral.hasType(name, typeName) then
      return true
    end
  end

  return false
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
  if body == "IGNORE" or body == "OFF" then
    return { kind = "ignore", label = "IGNORE" }
  end

  if body == "OVERFLOW" then
    return { kind = "overflow", label = "OVERFLOW", routeKey = "overflow" }
  end

  if body == "IO" then
    return { kind = "io", label = "IO" }
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

local function entryKey(item)
  return tostring(item.name) .. "#" .. tostring(item.nbt or "")
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

local function chooseSourceRole(name, marker)
  if not hasAnyType(name, SOURCE_CHEST_TYPES) then
    return false
  end

  if marker and (marker.kind == "route" or marker.kind == "overflow") then
    return false
  end

  return true
end

local function refreshTopology()
  local configuredPinned, configuredOverflow = buildConfiguredTargets()
  local markers = {}
  local ignored = {}
  local candidates = {}
  local sourceNames = {}
  local storageNames = {}
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

        if marker.kind == "ignore" then
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
        elseif marker.kind == "io" then
          info.note = "IO-Marker hat in diesem Skript keine Funktion"
        end
      end

      candidates[#candidates + 1] = info
    end
  end

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

  for _, info in ipairs(candidates) do
    local name = info.name
    local marker = state.markers[name]

    if state.ignoredNames[name] then
      info.role = "Ignoriert"
    elseif chooseSourceRole(name, marker) then
      sourceNames[#sourceNames + 1] = name
      info.role = "Quelle (Minecraft-Kiste)"
    else
      storageNames[#storageNames + 1] = name
      info.role = "Lager"
    end
  end

  table.sort(sourceNames)
  table.sort(storageNames)
  state.sourceNames = uniqueList(sourceNames)
  state.storageNames = uniqueList(storageNames)

  if #state.storageNames == 0 then
    error("Keine Ziel-Inventare gefunden.\nMarkiere fremde Inventare mit LAGER:IGNORE oder haenge modded Lagerkisten an.", 0)
  end

  local validStorage = {}
  local used = {}
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
      and validStorage[invName]
      and not used[invName]
    then
      cleanMap[routeKey] = invName
      used[invName] = true
    end
  end

  state.modMap = cleanMap
  state.freePool = {}
  state.poolNames = {}

  for _, name in ipairs(state.storageNames) do
    if not used[name] then
      state.freePool[#state.freePool + 1] = name
      state.poolNames[#state.poolNames + 1] = name
    end
  end

  local pinnedByInv = {}
  for routeKey, invName in pairs(state.pinnedTargets) do
    if invName then
      pinnedByInv[invName] = routeKey
    end
  end

  for _, info in ipairs(candidates) do
    if info.role ~= "Quelle (Minecraft-Kiste)" and info.role ~= "Ignoriert" then
      if state.overflowName and info.name == state.overflowName then
        info.role = "Overflow"
      elseif pinnedByInv[info.name] then
        info.role = routeLabel(pinnedByInv[info.name])
      elseif validStorage[info.name] then
        info.role = "Lager"
      else
        info.role = "-"
      end
    end
  end

  state.candidateInventories = candidates
  saveMap()
  state.topologySig = inventorySignature()
  state.markerSig = markerSignature()
  state.lastTopologyCheck = nowMs()
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
end

local function scanSources()
  local pendingItems = 0
  local pendingStacks = 0

  for _, invName in ipairs(state.sourceNames) do
    local inv = peripheral.wrap(invName)
    if inv then
      for slot, item in pairs(invList(inv)) do
        if not isMarkerSlot(invName, slot) then
          pendingStacks = pendingStacks + 1
          pendingItems = pendingItems + item.count
        end
      end
    end
  end

  state.pendingSourceItems = pendingItems
  state.pendingSourceStacks = pendingStacks
end

local function ensureFresh(force)
  local topologyChanged = ensureTopology(force)

  if force or topologyChanged or state.dirty or (nowMs() - state.lastScan) >= (SCAN_INTERVAL * 1000) then
    scanStorage()
    scanSources()
    state.lastScan = nowMs()
    state.dirty = false
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

local function moveIntoAnyStorage(fromInvName, fromSlot, attemptedInventories)
  local moved = 0

  for _, invName in ipairs(state.storageNames) do
    if invName ~= fromInvName and isInventory(invName) and not attemptedInventories[invName] then
      attemptedInventories[invName] = true
      moved = moved + pushBetweenInventories(fromInvName, invName, fromSlot)

      if not invDetail(peripheral.wrap(fromInvName), fromSlot) then
        break
      end
    end
  end

  return moved
end

local function moveSlotFromSource(fromInvName, fromSlot)
  local fromInv = peripheral.wrap(fromInvName)
  if not fromInv then
    return 0
  end

  local detail = invDetail(fromInv, fromSlot)
  if not detail or isMarkerSlot(fromInvName, fromSlot) then
    return 0
  end

  local moved = 0
  local attemptedInventories = {}

  local targetName = select(1, chooseTargetForItem(detail))
  if targetName and targetName ~= fromInvName then
    attemptedInventories[targetName] = true
    moved = moved + pushBetweenInventories(fromInvName, targetName, fromSlot, detail.count)
  end

  if invDetail(fromInv, fromSlot) then
    moved = moved + moveIntoAnyStorage(fromInvName, fromSlot, attemptedInventories)
  end

  if invDetail(fromInv, fromSlot)
    and state.overflowName
    and state.overflowName ~= fromInvName
    and not attemptedInventories[state.overflowName]
  then
    attemptedInventories[state.overflowName] = true
    moved = moved + pushBetweenInventories(fromInvName, state.overflowName, fromSlot)
  end

  if moved > 0 then
    state.dirty = true
  end

  return moved
end

local function lockMigration()
  local h = fs.open(FINAL_LOCK_FILE, "w")
  if h then
    h.writeLine("Migration abgeschlossen")
    h.writeLine(textutils.formatTime(os.time(), true))
    h.close()
  end
  state.migrationLocked = true
end

local function loadMigrationLock()
  state.migrationLocked = fs.exists(FINAL_LOCK_FILE)
end

local function finalMigrate()
  ensureFresh(true)

  if state.migrationLocked then
    print("Migration ist bereits abgeschlossen und gesperrt.")
    print("Nur Statistik-Modus aktiv.")
    return
  end

  if #state.sourceNames == 0 then
    print("Keine Standard-Minecraft-Kisten als Quelle gefunden.")
    return
  end

  local movedStacks = 0
  local movedItems = 0

  print("Letzte Umlagerung startet...")

  for _, invName in ipairs(state.sourceNames) do
    local inv = peripheral.wrap(invName)
    if inv then
      for slot = 1, invSize(inv) do
        if not isMarkerSlot(invName, slot) then
          while true do
            local before = invDetail(inv, slot)
            if not before then
              break
            end

            local sent = moveSlotFromSource(invName, slot)
            if sent <= 0 then
              break
            end

            movedStacks = movedStacks + 1
            movedItems = movedItems + sent
            sleep(0)
          end
        end
      end
    end
  end

  ensureFresh(true)

  print(("Umlagerung fertig: %d Bewegungen / %s Items"):format(movedStacks, formatCount(movedItems)))

  if state.pendingSourceItems == 0 then
    lockMigration()
    print("Alle Standard-Minecraft-Kisten sind leer.")
    print("Ab jetzt ist nur noch Statistik-Modus aktiv.")
  else
    print(("Noch offen in Quellkisten: %s Items in %d Stacks"):format(formatCount(state.pendingSourceItems), state.pendingSourceStacks))
    print("Es fehlt wahrscheinlich Platz im Ziel-Lager oder ein Inventar sollte mit LAGER:IGNORE markiert werden.")
  end
end

local function rememberShown(entries, query)
  state.lastShownKeys = {}
  state.lastShownQuery = tostring(query or "")

  for i, entry in ipairs(entries or {}) do
    state.lastShownKeys[i] = entry.key
  end
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
    print(("%2d) %s x%s"):format(i, entryLabel(e), formatCount(e.count)))
  end

  if #entries > maxLines then
    print(("... %d weitere Treffer"):format(#entries - maxLines))
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
end

local function listAssignments()
  ensureFresh(false)

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
  print("Freie Auto-Ziele: " .. #state.poolNames)
end

local function listInventories()
  ensureTopology(true)
  ensureFresh(false)

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
  print(" LAGER:GROUP:stone")
  print(" LAGER:MOD:create")
  print(" LAGER:OVERFLOW")
  print(" LAGER:IGNORE")
end

local function printStatus()
  ensureFresh(false)

  print("Modus: Statistik + letzte Umlagerung")
  print("Monitor: " .. (state.monitor and "ja" or "nein"))
  print("Ziel-Inventare: " .. tostring(#state.storageNames))
  print("Quell-Minecraft-Kisten: " .. tostring(#state.sourceNames))
  print("Ziel-Typen: " .. tostring(#state.order) .. " | Ziel-Items: " .. formatCount(state.totalItems))
  print("Offen in Quellkisten: " .. formatCount(state.pendingSourceItems) .. " Items in " .. tostring(state.pendingSourceStacks) .. " Stacks")
  print("Migration gesperrt: " .. (state.migrationLocked and "ja" or "nein"))
end

local function redrawMonitor(page)
  local m = state.monitor
  if not m then
    return 1, 1
  end

  local w, h = m.getSize()
  local headerLines = math.min(2, h)
  local lines = math.max(1, h - headerLines)
  local pages = math.max(1, math.ceil(#state.order / lines))

  if page > pages then
    page = 1
  end

  m.setBackgroundColor(colors.black)
  m.clear()
  m.setTextColor(colors.yellow)
  m.setCursorPos(1, 1)
  m.write(clip(("Lager %d/%d | %d Typen | %s Items"):format(page, pages, #state.order, formatCount(state.totalItems)), w))

  if h >= 2 then
    m.setCursorPos(1, 2)
    if state.pendingSourceItems > 0 then
      m.setTextColor(colors.orange)
      m.write(clip(("Quellkisten offen: %s"):format(formatCount(state.pendingSourceItems)), w))
    else
      m.setTextColor(colors.lime)
      local text = state.migrationLocked and "Migration abgeschlossen" or "Quellkisten leer"
      m.write(clip(text, w))
    end
  end

  local startIndex = (page - 1) * lines + 1
  for row = 1, lines do
    local entry = state.order[startIndex + row - 1]
    local y = row + headerLines

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

local function printHelp()
  print("Befehle:")
  print(" hilfe")
  print(" status")
  print(" inventare")
  print(" zuordnung")
  print(" gruppen")
  print(" list [filter]")
  print(" scan")
  print(" umlagern")
  print(" stop")
  print("")
  print("Dieses Skript zieht Standard-Minecraft-Kisten nur noch einmal leer.")
  print("Danach bleibt nur Statistik/Monitor aktiv.")
end

local function commandLoop()
  term.clear()
  term.setCursorPos(1, 1)
  print("Lager-Abschlussmodus gestartet.")
  print("Standard-Minecraft-Kisten werden nur noch auf Wunsch geleert.")
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
    elseif cmd == "inventare" or cmd == "kisten" then
      listInventories()
    elseif cmd == "zuordnung" then
      listAssignments()
    elseif cmd == "gruppen" then
      printGroupOverview(50)
    elseif cmd == "list" then
      listItems(table.concat(args, " ", 2))
    elseif cmd == "scan" or cmd == "neu" then
      ensureFresh(true)
      print("Scan fertig.")
      printStatus()
    elseif cmd == "umlagern" or cmd == "migrieren" then
      finalMigrate()
    elseif cmd == "stop" or cmd == "exit" then
      print("Programm beendet.")
      return
    else
      print("Unbekannter Befehl. 'hilfe' zeigt die Befehle.")
    end
  end
end

loadMap()
loadMigrationLock()
refreshTopology()
ensureFresh(true)

parallel.waitForAny(
  commandLoop,
  monitorLoop
)
