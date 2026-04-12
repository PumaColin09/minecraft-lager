local CONFIG_FILE = "lager_stats_config.txt"
local ROLE_MARKER_SLOT = 1
local DEFAULT_MONITOR_SCALE = 0.5
local DEFAULT_SCAN_INTERVAL = 8
local DEFAULT_PAGE_INTERVAL = 6
local LARGE_MONITOR_MIN_W = 36
local LARGE_MONITOR_MIN_H = 18
local MAX_SMALL_LINES = 18

local state = {
  running = true,
  snapshot = nil,
  previous = nil,
  page = 1,
  tick = 0,
  easterUnlocked = false,
  lastScan = 0,
  lastPageSwitch = 0,
  config = {
    monitorName = nil,
    monitorDisabled = false,
    monitorScale = DEFAULT_MONITOR_SCALE,
    meBridgeName = nil,
    meBridgeDisabled = false,
    scanInterval = DEFAULT_SCAN_INTERVAL,
    pageInterval = DEFAULT_PAGE_INTERVAL,
  },
}

local function nowMs()
  return os.epoch("utc")
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function safeNumber(value)
  value = tonumber(value)
  if value then
    return value
  end
  return nil
end

local function sortedNames()
  local names = peripheral.getNames()
  table.sort(names)
  return names
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

local function formatCount(n)
  n = math.floor(tonumber(n) or 0)
  local s = tostring(n)
  local out = ""

  while #s > 3 do
    out = "." .. s:sub(-3) .. out
    s = s:sub(1, -4)
  end

  return s .. out
end

local function formatCompact(n)
  n = tonumber(n) or 0
  local abs = math.abs(n)
  local value = n
  local suffix = ""

  if abs >= 1000000000 then
    value = n / 1000000000
    suffix = "G"
  elseif abs >= 1000000 then
    value = n / 1000000
    suffix = "M"
  elseif abs >= 1000 then
    value = n / 1000
    suffix = "k"
  else
    return formatCount(n)
  end

  return (string.format("%.1f%s", value, suffix):gsub("%.0([kMG])$", "%1"))
end

local function formatMaybeCount(n)
  if n == nil then
    return "-"
  end
  return formatCount(n)
end

local function formatPercent(part, total)
  part = tonumber(part) or 0
  total = tonumber(total) or 0
  if total <= 0 then
    return "0.0%"
  end
  return string.format("%.1f%%", (part / total) * 100)
end

local function formatRate(n)
  if n == nil then
    return "-"
  end
  return formatCount(n) .. " FE/t"
end

local function formatEnergy(stored, capacity)
  if stored == nil and capacity == nil then
    return "-"
  end
  if capacity and capacity > 0 then
    return formatCount(stored or 0) .. "/" .. formatCount(capacity) .. " FE"
  end
  return formatCount(stored or 0) .. " FE"
end

local function formatSince(ms)
  if not ms or ms <= 0 then
    return "-"
  end

  local sec = math.floor((nowMs() - ms) / 1000)
  if sec < 60 then
    return tostring(sec) .. "s"
  end

  local min = math.floor(sec / 60)
  local rest = sec % 60
  return tostring(min) .. "m " .. tostring(rest) .. "s"
end

local function joinList(list, sep)
  local out = {}
  for _, value in ipairs(list or {}) do
    out[#out + 1] = tostring(value)
  end
  return table.concat(out, sep or ", ")
end

local function namespaceOf(itemName)
  return tostring(itemName or ""):match("^(.-):") or "unknown"
end

local function baseNameOf(itemName)
  return tostring(itemName or ""):match(":(.+)$") or tostring(itemName or "")
end

local function prettyModName(ns)
  local map = {
    minecraft = "Minecraft",
    ae2 = "Applied Energistics 2",
    advancedperipherals = "Advanced Peripherals",
    computercraft = "CC: Tweaked",
    create = "Create",
    mekanism = "Mekanism",
    storagedrawers = "Storage Drawers",
    refinedstorage = "Refined Storage",
    farmersdelight = "Farmer's Delight",
  }

  if map[ns] then
    return map[ns]
  end

  ns = tostring(ns or ""):gsub("_", " ")
  return (ns:gsub("(%a)([%w ]*)", function(a, b)
    return a:upper() .. b:lower()
  end))
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

local function hasType(name, typeName)
  if not name or not peripheral.isPresent(name) then
    return false
  end

  if peripheral.hasType then
    local ok, value = pcall(peripheral.hasType, name, typeName)
    if ok then
      return value and true or false
    end
  end

  for _, value in ipairs(listPeripheralTypes(name)) do
    if value == typeName then
      return true
    end
  end

  return false
end

local function safeWrap(name)
  if not name or not peripheral.isPresent(name) then
    return nil
  end

  local ok, value = pcall(peripheral.wrap, name)
  if ok then
    return value
  end
  return nil
end

local function hasMethod(object, methodName)
  return object and type(object[methodName]) == "function"
end

local function safeCall(object, methodName, ...)
  if not hasMethod(object, methodName) then
    return nil
  end

  local ok, a, b, c, d = pcall(object[methodName], ...)
  if ok then
    return a, b, c, d
  end
  return nil
end

local function firstNumericCall(object, methods)
  for _, methodName in ipairs(methods or {}) do
    local value = safeNumber(safeCall(object, methodName))
    if value ~= nil then
      return value, methodName
    end
  end
  return nil, nil
end

local function readFile(path)
  if not fs.exists(path) then
    return nil
  end

  local h = fs.open(path, "r")
  if not h then
    return nil
  end

  local raw = h.readAll()
  h.close()
  return raw
end

local function writeFile(path, text)
  local h = fs.open(path, "w")
  if not h then
    return false
  end

  h.write(text or "")
  h.close()
  return true
end

local function loadConfig()
  local raw = readFile(CONFIG_FILE)
  if not raw or raw == "" then
    return
  end

  local data = textutils.unserialize(raw)
  if type(data) ~= "table" then
    return
  end

  if type(data.monitorName) == "string" then
    state.config.monitorName = data.monitorName
  end
  if type(data.monitorDisabled) == "boolean" then
    state.config.monitorDisabled = data.monitorDisabled
  end
  if tonumber(data.monitorScale) then
    state.config.monitorScale = tonumber(data.monitorScale)
  end
  if type(data.meBridgeName) == "string" then
    state.config.meBridgeName = data.meBridgeName
  end
  if type(data.meBridgeDisabled) == "boolean" then
    state.config.meBridgeDisabled = data.meBridgeDisabled
  end
  if tonumber(data.scanInterval) then
    state.config.scanInterval = math.max(2, math.floor(tonumber(data.scanInterval)))
  end
  if tonumber(data.pageInterval) then
    state.config.pageInterval = math.max(2, math.floor(tonumber(data.pageInterval)))
  end
end

local function saveConfig()
  writeFile(CONFIG_FILE, textutils.serialize(state.config))
end

local function monitorArea(name)
  if not name or not peripheral.isPresent(name) or not hasType(name, "monitor") then
    return 0, 0, 0
  end

  local monitor = safeWrap(name)
  if not monitor then
    return 0, 0, 0
  end

  local width, height = safeCall(monitor, "getSize")
  width = math.floor(tonumber(width) or 0)
  height = math.floor(tonumber(height) or 0)
  return width * height, width, height
end

local function resolveMonitorName()
  if state.config.monitorDisabled then
    return nil
  end

  if state.config.monitorName and state.config.monitorName ~= "" and peripheral.isPresent(state.config.monitorName) and hasType(state.config.monitorName, "monitor") then
    return state.config.monitorName
  end

  local bestName = nil
  local bestArea = -1
  local bestWidth = -1
  local bestHeight = -1

  for _, name in ipairs(sortedNames()) do
    if hasType(name, "monitor") then
      local area, width, height = monitorArea(name)
      if area > bestArea
        or (area == bestArea and width > bestWidth)
        or (area == bestArea and width == bestWidth and height > bestHeight)
        or (area == bestArea and width == bestWidth and height == bestHeight and (not bestName or tostring(name) < tostring(bestName))) then
        bestName = name
        bestArea = area
        bestWidth = width
        bestHeight = height
      end
    end
  end

  return bestName
end

local function resolveMeBridgeName()
  if state.config.meBridgeDisabled then
    return nil
  end

  if state.config.meBridgeName and state.config.meBridgeName ~= "" and peripheral.isPresent(state.config.meBridgeName) and hasType(state.config.meBridgeName, "meBridge") then
    return state.config.meBridgeName
  end

  for _, name in ipairs(sortedNames()) do
    if hasType(name, "me_bridge") then
      return name
    end
  end

  return nil
end

local function resolveSpeakerName()
  for _, name in ipairs(sortedNames()) do
    if hasType(name, "speaker") then
      return name
    end
  end
  return nil
end

local function playSecretJingle()
  local name = resolveSpeakerName()
  if not name then
    return false
  end

  local speaker = safeWrap(name)
  if not speaker then
    return false
  end

  if hasMethod(speaker, "playNote") then
    local sequence = {
      { "bell", 3, 12 },
      { "bell", 3, 16 },
      { "chime", 3, 19 },
      { "bell", 3, 24 },
    }

    for _, note in ipairs(sequence) do
      pcall(speaker.playNote, note[1], note[2], note[3])
      sleep(0.12)
    end
    return true
  end

  if hasMethod(speaker, "playSound") then
    pcall(speaker.playSound, "block.note_block.bell", 1, 1)
    return true
  end

  return false
end

local function parseMarker(detail)
  if type(detail) ~= "table" then
    return nil
  end

  local raw = trim(detail.displayName or detail.name)
  if raw == "" then
    return nil
  end

  local normalized = raw:upper():gsub("%s+", "")
  normalized = normalized:gsub("^%[", ""):gsub("%]$", "")

  if not normalized:find("^LAGER:") then
    return nil
  end

  return normalized:sub(7)
end

local function inventoryMarker(inv)
  if not inv then
    return nil
  end

  local detail = safeCall(inv, "getItemDetail", ROLE_MARKER_SLOT)
  if not detail then
    return nil
  end

  return parseMarker(detail)
end

local function isIgnoredInventory(inv)
  local marker = inventoryMarker(inv)
  return marker == "IGNORE" or marker == "OFF"
end

local function buildItemKey(item)
  local nbt = item.nbt or item.fingerprint or item.itemFingerprint or ""
  return tostring(item.name or "unknown") .. "#" .. tostring(nbt)
end

local function mergeItem(map, detail, source, amount)
  if not detail or not detail.name then
    return
  end

  amount = tonumber(amount) or 0
  if amount == 0 then
    return
  end

  local key = buildItemKey(detail)
  local entry = map[key]

  if not entry then
    entry = {
      key = key,
      name = detail.name,
      displayName = detail.displayName or baseNameOf(detail.name),
      mod = namespaceOf(detail.name),
      localCount = 0,
      meCount = 0,
      totalCount = 0,
    }
    map[key] = entry
  end

  if source == "local" then
    entry.localCount = entry.localCount + amount
  elseif source == "me" then
    entry.meCount = entry.meCount + amount
  end

  entry.totalCount = entry.localCount + entry.meCount
end

local function sortItemMap(map)
  local out = {}
  for _, entry in pairs(map or {}) do
    out[#out + 1] = entry
  end

  table.sort(out, function(a, b)
    if a.totalCount ~= b.totalCount then
      return a.totalCount > b.totalCount
    end
    return tostring(a.displayName) < tostring(b.displayName)
  end)

  return out
end

local function sortModMap(map)
  local out = {}
  for mod, count in pairs(map or {}) do
    out[#out + 1] = {
      mod = mod,
      label = prettyModName(mod),
      count = count,
    }
  end

  table.sort(out, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return tostring(a.label) < tostring(b.label)
  end)

  return out
end

local function buildLocalStats()
  local stats = {
    inventoryCount = 0,
    totalSlots = 0,
    usedSlots = 0,
    freeSlots = 0,
    totalItems = 0,
    inventories = {},
    byKey = {},
    modCounts = {},
  }

  for _, name in ipairs(sortedNames()) do
    if hasType(name, "inventory") then
      local inv = safeWrap(name)
      if inv and not isIgnoredInventory(inv) then
        local size = tonumber(safeCall(inv, "size")) or 0
        local list = safeCall(inv, "list") or {}
        local used = 0
        local items = 0

        for slot, item in pairs(list) do
          if item and item.name and item.count then
            local detail = safeCall(inv, "getItemDetail", slot) or item
            if not (slot == ROLE_MARKER_SLOT and parseMarker(detail)) then
              local count = tonumber(item.count) or 0
              used = used + 1
              items = items + count
              stats.totalItems = stats.totalItems + count

              mergeItem(stats.byKey, detail, "local", count)
              local ns = namespaceOf(detail.name)
              stats.modCounts[ns] = (stats.modCounts[ns] or 0) + count
            end
          end
        end

        stats.inventoryCount = stats.inventoryCount + 1
        stats.totalSlots = stats.totalSlots + size
        stats.usedSlots = stats.usedSlots + used
        stats.freeSlots = stats.freeSlots + math.max(0, size - used)

        stats.inventories[#stats.inventories + 1] = {
          name = name,
          types = joinList(listPeripheralTypes(name), "/"),
          size = size,
          usedSlots = used,
          freeSlots = math.max(0, size - used),
          totalItems = items,
        }
      end
    end
  end

  table.sort(stats.inventories, function(a, b)
    if a.totalItems ~= b.totalItems then
      return a.totalItems > b.totalItems
    end
    if a.usedSlots ~= b.usedSlots then
      return a.usedSlots > b.usedSlots
    end
    return tostring(a.name) < tostring(b.name)
  end)

  stats.order = sortItemMap(stats.byKey)
  stats.uniqueItems = #stats.order
  stats.modOrder = sortModMap(stats.modCounts)
  return stats
end

local function buildMeStats()
  local name = resolveMeBridgeName()
  if not name then
    return {
      available = false,
      name = nil,
      byKey = {},
      order = {},
      craftables = {},
      fluids = {},
      modCounts = {},
      craftableCount = 0,
      fluidCount = 0,
      totalItems = 0,
      uniqueItems = 0,
      cellCount = 0,
      cpuCount = 0,
    }
  end

  local bridge = safeWrap(name)
  if not bridge then
    return {
      available = false,
      name = name,
      error = "ME Bridge konnte nicht geoeffnet werden",
      byKey = {},
      order = {},
      craftables = {},
      fluids = {},
      modCounts = {},
      craftableCount = 0,
      fluidCount = 0,
      totalItems = 0,
      uniqueItems = 0,
      cellCount = 0,
      cpuCount = 0,
    }
  end

  local stats = {
    available = true,
    name = name,
    byKey = {},
    modCounts = {},
    craftables = {},
    fluids = {},
    cells = {},
    cpus = {},
    totalItems = 0,
    uniqueItems = 0,
    craftableCount = 0,
    fluidCount = 0,
    fluidTotal = 0,
    cellCount = 0,
    cpuCount = 0,
    totalItemStorage = safeNumber(safeCall(bridge, "getTotalItemStorage")),
    usedItemStorage = safeNumber(safeCall(bridge, "getUsedItemStorage")),
    availableItemStorage = safeNumber(safeCall(bridge, "getAvailableItemStorage")),
    totalFluidStorage = safeNumber(safeCall(bridge, "getTotalFluidStorage")),
    usedFluidStorage = safeNumber(safeCall(bridge, "getUsedFluidStorage")),
    availableFluidStorage = safeNumber(safeCall(bridge, "getAvailableFluidStorage")),
    energyStorage = safeNumber(safeCall(bridge, "getEnergyStorage")),
    maxEnergyStorage = safeNumber(safeCall(bridge, "getMaxEnergyStorage")),
    energyUsage = safeNumber(safeCall(bridge, "getEnergyUsage")),
  }

  local items = safeCall(bridge, "listItems") or {}
  for _, item in pairs(items) do
    if item and item.name then
      local count = tonumber(item.amount or item.count or 0) or 0
      stats.totalItems = stats.totalItems + count
      mergeItem(stats.byKey, item, "me", count)
      local ns = namespaceOf(item.name)
      stats.modCounts[ns] = (stats.modCounts[ns] or 0) + count
    end
  end

  local craftables = safeCall(bridge, "listCraftableItems") or {}
  for _, item in pairs(craftables) do
    if item and item.name then
      stats.craftables[#stats.craftables + 1] = {
        name = item.name,
        displayName = item.displayName or baseNameOf(item.name),
      }
    end
  end

  table.sort(stats.craftables, function(a, b)
    return tostring(a.displayName) < tostring(b.displayName)
  end)

  local fluids = safeCall(bridge, "listFluid") or safeCall(bridge, "listFluids") or {}
  for _, fluid in pairs(fluids) do
    if fluid and fluid.name then
      local amount = tonumber(fluid.amount or fluid.count or 0) or 0
      stats.fluidTotal = stats.fluidTotal + amount
      stats.fluids[#stats.fluids + 1] = {
        name = fluid.name,
        displayName = fluid.displayName or baseNameOf(fluid.name),
        amount = amount,
      }
    end
  end

  table.sort(stats.fluids, function(a, b)
    if a.amount ~= b.amount then
      return a.amount > b.amount
    end
    return tostring(a.displayName) < tostring(b.displayName)
  end)

  stats.cells = safeCall(bridge, "listCells") or {}
  stats.cpus = safeCall(bridge, "getCraftingCPUs") or {}

  stats.order = sortItemMap(stats.byKey)
  stats.uniqueItems = #stats.order
  stats.modOrder = sortModMap(stats.modCounts)
  stats.craftableCount = #stats.craftables
  stats.fluidCount = #stats.fluids

  for _ in pairs(stats.cells) do
    stats.cellCount = stats.cellCount + 1
  end
  for _ in pairs(stats.cpus) do
    stats.cpuCount = stats.cpuCount + 1
  end

  return stats
end

local function buildCombinedStats(localStats, meStats)
  local combined = {
    byKey = {},
    modCounts = {},
    totalItems = 0,
    uniqueItems = 0,
  }

  local function mergeExistingEntry(sourceEntry)
    if not sourceEntry or not sourceEntry.key then
      return
    end

    local entry = combined.byKey[sourceEntry.key]
    if not entry then
      entry = {
        key = sourceEntry.key,
        name = sourceEntry.name,
        displayName = sourceEntry.displayName,
        mod = sourceEntry.mod,
        localCount = 0,
        meCount = 0,
        totalCount = 0,
      }
      combined.byKey[sourceEntry.key] = entry
    end

    entry.localCount = entry.localCount + (sourceEntry.localCount or 0)
    entry.meCount = entry.meCount + (sourceEntry.meCount or 0)
    entry.totalCount = entry.localCount + entry.meCount
  end

  for _, entry in ipairs(localStats.order or {}) do
    mergeExistingEntry(entry)
  end
  for _, entry in ipairs(meStats.order or {}) do
    mergeExistingEntry(entry)
  end

  for mod, count in pairs(localStats.modCounts or {}) do
    combined.modCounts[mod] = (combined.modCounts[mod] or 0) + count
  end
  for mod, count in pairs(meStats.modCounts or {}) do
    combined.modCounts[mod] = (combined.modCounts[mod] or 0) + count
  end

  combined.order = sortItemMap(combined.byKey)
  combined.uniqueItems = #combined.order
  combined.totalItems = (localStats.totalItems or 0) + (meStats.totalItems or 0)
  combined.modOrder = sortModMap(combined.modCounts)
  return combined
end

local function buildEnergyStats(meStats)
  local stats = {
    sources = {},
    totalStored = 0,
    totalCapacity = 0,
    totalRate = 0,
    totalUsage = 0,
  }

  for _, name in ipairs(sortedNames()) do
    if not meStats.name or name ~= meStats.name then
      local obj = safeWrap(name)
      if obj then
        local stored = firstNumericCall(obj, { "getEnergyStorage", "getEnergyStored", "getEnergy" })
        local capacity = firstNumericCall(obj, { "getMaxEnergyStorage", "getMaxEnergyStored", "getEnergyCapacity" })
        local rate = firstNumericCall(obj, { "getTransferRate", "getEnergyTransferRate", "getFlow", "getEnergyIn" })
        local usage = firstNumericCall(obj, { "getEnergyUsage", "getConsumption", "getPowerUsage" })

        if stored ~= nil or capacity ~= nil or rate ~= nil or usage ~= nil then
          stats.sources[#stats.sources + 1] = {
            name = name,
            types = joinList(listPeripheralTypes(name), "/"),
            stored = stored,
            capacity = capacity,
            rate = rate,
            usage = usage,
          }
          stats.totalStored = stats.totalStored + (stored or 0)
          stats.totalCapacity = stats.totalCapacity + (capacity or 0)
          stats.totalRate = stats.totalRate + (rate or 0)
          stats.totalUsage = stats.totalUsage + (usage or 0)
        end
      end
    end
  end

  if meStats.available and (meStats.energyStorage ~= nil or meStats.maxEnergyStorage ~= nil or meStats.energyUsage ~= nil) then
    stats.sources[#stats.sources + 1] = {
      name = meStats.name .. " (ME)",
      types = "meBridge",
      stored = meStats.energyStorage,
      capacity = meStats.maxEnergyStorage,
      rate = nil,
      usage = meStats.energyUsage,
    }
    stats.totalStored = stats.totalStored + (meStats.energyStorage or 0)
    stats.totalCapacity = stats.totalCapacity + (meStats.maxEnergyStorage or 0)
    stats.totalUsage = stats.totalUsage + (meStats.energyUsage or 0)
  end

  table.sort(stats.sources, function(a, b)
    local aKey = math.abs(a.rate or a.usage or a.stored or 0)
    local bKey = math.abs(b.rate or b.usage or b.stored or 0)
    if aKey ~= bKey then
      return aKey > bKey
    end
    return tostring(a.name) < tostring(b.name)
  end)

  return stats
end

local function buildPeripheralSummary()
  local summary = {
    total = 0,
    inventory = 0,
    monitor = 0,
    meBridge = 0,
    modem = 0,
    speaker = 0,
    energy = 0,
    list = {},
  }

  for _, name in ipairs(sortedNames()) do
    local types = listPeripheralTypes(name)
    local joined = joinList(types, "/")
    summary.total = summary.total + 1
    if hasType(name, "inventory") then
      summary.inventory = summary.inventory + 1
    end
    if hasType(name, "monitor") then
      summary.monitor = summary.monitor + 1
    end
    if hasType(name, "meBridge") then
      summary.meBridge = summary.meBridge + 1
    end
    if hasType(name, "modem") then
      summary.modem = summary.modem + 1
    end
    if hasType(name, "speaker") then
      summary.speaker = summary.speaker + 1
    end

    local obj = safeWrap(name)
    if obj and firstNumericCall(obj, { "getTransferRate", "getEnergyStorage", "getEnergyStored", "getEnergy", "getEnergyUsage" }) ~= nil then
      summary.energy = summary.energy + 1
    end

    summary.list[#summary.list + 1] = {
      name = name,
      types = joined,
    }
  end

  return summary
end

local function buildChanges(previous, current)
  local prevMap = previous and previous.combined and previous.combined.byKey or {}
  local currMap = current and current.combined and current.combined.byKey or {}
  local keys = {}
  local changes = {}

  for key in pairs(prevMap or {}) do
    keys[key] = true
  end
  for key in pairs(currMap or {}) do
    keys[key] = true
  end

  for key in pairs(keys) do
    local before = prevMap[key] and prevMap[key].totalCount or 0
    local after = currMap[key] and currMap[key].totalCount or 0
    if before ~= after then
      local ref = currMap[key] or prevMap[key]
      changes[#changes + 1] = {
        key = key,
        name = ref.name,
        displayName = ref.displayName,
        delta = after - before,
        before = before,
        after = after,
      }
    end
  end

  table.sort(changes, function(a, b)
    local ad = math.abs(a.delta)
    local bd = math.abs(b.delta)
    if ad ~= bd then
      return ad > bd
    end
    return tostring(a.displayName) < tostring(b.displayName)
  end)

  return changes
end

local function countMatchingItems(snapshot, patterns)
  if not snapshot or not snapshot.combined then
    return 0
  end

  local total = 0
  for _, entry in ipairs(snapshot.combined.order or {}) do
    local hay = (tostring(entry.displayName or "") .. " " .. tostring(entry.name or "")):lower()
    for _, pattern in ipairs(patterns or {}) do
      if hay:find(pattern, 1, true) then
        total = total + (entry.totalCount or 0)
        break
      end
    end
  end

  return total
end

local function scanAll(silent)
  local previous = state.snapshot
  local snapshot = {
    time = nowMs(),
    monitorName = resolveMonitorName(),
    meBridgeName = resolveMeBridgeName(),
  }

  snapshot.localStats = buildLocalStats()
  snapshot.me = buildMeStats()
  snapshot.combined = buildCombinedStats(snapshot.localStats, snapshot.me)
  snapshot.energy = buildEnergyStats(snapshot.me)
  snapshot.peripherals = buildPeripheralSummary()
  snapshot.changes = buildChanges(previous, snapshot)

  state.previous = previous
  state.snapshot = snapshot
  state.lastScan = snapshot.time

  if not silent then
    print("Scan fertig: " .. formatCount(snapshot.combined.totalItems) .. " Items gesamt, " .. formatCount(snapshot.combined.uniqueItems) .. " verschiedene Typen.")
  end
end

local function currentMonitor()
  local name = state.snapshot and state.snapshot.monitorName or resolveMonitorName()
  if not name then
    return nil, nil
  end

  return safeWrap(name), name
end

local function addPage(pages, title, lines, kind)
  pages[#pages + 1] = {
    title = title,
    lines = lines,
    kind = kind or title,
  }
end

local function buildMonitorPages(snapshot)
  local pages = {}
  if not snapshot then
    addPage(pages, "Warten", {
      "Noch kein Scan vorhanden.",
      "Bitte 'scan' ausfuehren.",
    }, "waiting")
    return pages
  end

  local localStats = snapshot.localStats
  local meStats = snapshot.me
  local combined = snapshot.combined
  local energy = snapshot.energy

  addPage(pages, "Cockpit", {
    "Lokale Inventare: " .. formatCount(localStats.inventoryCount),
    "Lokale Slots: " .. formatCount(localStats.usedSlots) .. "/" .. formatCount(localStats.totalSlots) .. " (" .. formatPercent(localStats.usedSlots, localStats.totalSlots) .. ")",
    "Lokale Items: " .. formatCount(localStats.totalItems),
    "Lokale Typen: " .. formatCount(localStats.uniqueItems),
    "ME Bridge: " .. (meStats.available and meStats.name or "nicht gefunden"),
    "ME Items: " .. formatCount(meStats.totalItems),
    "Kombi Items: " .. formatCount(combined.totalItems),
    "Kombi Typen: " .. formatCount(combined.uniqueItems),
    "Stromquellen: " .. formatCount(#energy.sources),
    "Letzter Scan: " .. formatSince(snapshot.time),
  }, "dashboard")

  local topItemLines = {}
  if #combined.order == 0 then
    topItemLines[#topItemLines + 1] = "Keine Items gefunden."
  else
    for i = 1, math.min(MAX_SMALL_LINES, #combined.order) do
      local entry = combined.order[i]
      local top = tostring(i) .. ". " .. entry.displayName .. " " .. formatCount(entry.totalCount)
      topItemLines[#topItemLines + 1] = top
    end
  end
  addPage(pages, "Top Items", topItemLines, "items")

  local storageLines = {}
  if #localStats.inventories == 0 then
    storageLines[#storageLines + 1] = "Keine lokalen Inventare."
  else
    for i = 1, math.min(MAX_SMALL_LINES, #localStats.inventories) do
      local inv = localStats.inventories[i]
      storageLines[#storageLines + 1] = tostring(i) .. ". " .. inv.name
      storageLines[#storageLines + 1] = "   " .. formatCount(inv.totalItems) .. " Items | " .. formatCount(inv.usedSlots) .. "/" .. formatCount(inv.size) .. " Slots"
    end
  end
  addPage(pages, "Lager", storageLines, "storage")

  local meLines = {}
  if not meStats.available then
    meLines[#meLines + 1] = "Keine ME Bridge gefunden."
  else
    meLines[#meLines + 1] = "Bridge: " .. meStats.name
    meLines[#meLines + 1] = "Item-Speicher: " .. formatMaybeCount(meStats.usedItemStorage) .. "/" .. formatMaybeCount(meStats.totalItemStorage)
    meLines[#meLines + 1] = "Fluid-Speicher: " .. formatMaybeCount(meStats.usedFluidStorage) .. "/" .. formatMaybeCount(meStats.totalFluidStorage)
    meLines[#meLines + 1] = "ME Energie: " .. formatEnergy(meStats.energyStorage, meStats.maxEnergyStorage)
    meLines[#meLines + 1] = "ME Verbrauch: " .. formatRate(meStats.energyUsage)
    meLines[#meLines + 1] = "Craftbar: " .. formatCount(meStats.craftableCount)
    meLines[#meLines + 1] = "Fluids: " .. formatCount(meStats.fluidCount) .. " Typen"
  end
  addPage(pages, "ME System", meLines, "me")

  local energyLines = {}
  if #energy.sources == 0 then
    energyLines[#energyLines + 1] = "Keine Stromdaten gefunden."
    energyLines[#energyLines + 1] = "Tipp: Energy Detector oder"
    energyLines[#energyLines + 1] = "ME Bridge anschliessen."
  else
    energyLines[#energyLines + 1] = "Gespeichert: " .. formatEnergy(energy.totalStored, energy.totalCapacity)
    energyLines[#energyLines + 1] = "Transfer: " .. formatRate(energy.totalRate)
    energyLines[#energyLines + 1] = "Verbrauch: " .. formatRate(energy.totalUsage)
    for i = 1, math.min(MAX_SMALL_LINES - 3, #energy.sources) do
      local src = energy.sources[i]
      local line = src.name .. " "
      if src.rate ~= nil then
        line = line .. formatRate(src.rate)
      elseif src.usage ~= nil then
        line = line .. "Use " .. formatRate(src.usage)
      else
        line = line .. formatEnergy(src.stored, src.capacity)
      end
      energyLines[#energyLines + 1] = line
    end
  end
  addPage(pages, "Strom", energyLines, "energy")

  local changeLines = {}
  if #snapshot.changes == 0 then
    changeLines[#changeLines + 1] = "Seit dem letzten Scan keine"
    changeLines[#changeLines + 1] = "Aenderungen erkannt."
  else
    for i = 1, math.min(MAX_SMALL_LINES, #snapshot.changes) do
      local entry = snapshot.changes[i]
      local prefix = entry.delta > 0 and "+" or ""
      changeLines[#changeLines + 1] = tostring(i) .. ". " .. entry.displayName .. " " .. prefix .. formatCount(entry.delta)
    end
  end
  addPage(pages, "Aenderungen", changeLines, "changes")

  if state.easterUnlocked then
    addPage(pages, "Marcel", {
      "Marcel-Modus aktiv.",
      "Kekse im Netz: " .. formatCount(countMatchingItems(snapshot, { "cookie", "keks" })),
      "Kuchen im Netz: " .. formatCount(countMatchingItems(snapshot, { "cake", "kuchen" })),
      "Tipp: 'marcel' schaltet wieder aus.",
    }, "easter")
  end

  return pages
end

local function padRight(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if #text >= width then
    return text:sub(1, width)
  end
  return text .. string.rep(" ", width - #text)
end

local function monitorSize(monitor)
  local width, height = safeCall(monitor, "getSize")
  return math.floor(tonumber(width) or 0), math.floor(tonumber(height) or 0)
end

local function isLargeMonitor(width, height)
  return width >= LARGE_MONITOR_MIN_W and height >= LARGE_MONITOR_MIN_H
end

local function writeAt(monitor, x, y, text, fg, bg, maxWidth)
  local width, height = monitorSize(monitor)
  if width <= 0 or height <= 0 or y < 1 or y > height or x > width then
    return
  end

  text = tostring(text or "")
  if x < 1 then
    local skip = 1 - x
    if skip >= #text then
      return
    end
    text = text:sub(skip + 1)
    x = 1
  end

  local available = width - x + 1
  if maxWidth then
    available = math.min(available, maxWidth)
  end
  if available <= 0 then
    return
  end

  text = clip(text, available)
  if bg then
    pcall(monitor.setBackgroundColor, bg)
  end
  if fg then
    pcall(monitor.setTextColor, fg)
  end
  pcall(monitor.setCursorPos, x, y)
  pcall(monitor.write, text)
end

local function fillRect(monitor, x, y, width, height, bg, char, fg)
  if width <= 0 or height <= 0 then
    return
  end

  local line = string.rep(char or " ", width)
  for row = 0, height - 1 do
    writeAt(monitor, x, y + row, line, fg or colors.white, bg, width)
  end
end

local function drawPanel(monitor, x, y, width, height, title, titleBg, bodyBg, titleFg)
  if width < 4 or height < 3 then
    return
  end

  titleBg = titleBg or colors.blue
  bodyBg = bodyBg or colors.black
  titleFg = titleFg or colors.white

  fillRect(monitor, x, y, width, height, bodyBg, " ")
  fillRect(monitor, x, y, width, 1, titleBg, " ")
  writeAt(monitor, x + 1, y, " " .. clip(title or "", math.max(1, width - 2)), titleFg, titleBg, math.max(1, width - 2))
end

local function drawCard(monitor, x, y, width, height, title, value, subtitle, accent)
  if width < 8 or height < 4 then
    return
  end

  drawPanel(monitor, x, y, width, height, title, accent or colors.blue, colors.black, colors.white)
  writeAt(monitor, x + 2, y + 2, clip(value or "-", math.max(1, width - 4)), colors.white, colors.black, math.max(1, width - 4))
  if subtitle then
    writeAt(monitor, x + 2, y + 3, clip(subtitle, math.max(1, width - 4)), colors.lightGray, colors.black, math.max(1, width - 4))
  end
end

local function drawBar(monitor, x, y, width, value, maximum, label, fillColor, emptyColor, textColor)
  if width <= 0 then
    return
  end

  fillRect(monitor, x, y, width, 1, emptyColor or colors.gray, " ")
  value = tonumber(value) or 0
  maximum = tonumber(maximum) or 0
  local fill = 0
  if maximum > 0 and value > 0 then
    fill = math.floor((value / maximum) * width + 0.5)
    if fill < 1 then
      fill = 1
    end
    if fill > width then
      fill = width
    end
  end
  if fill > 0 then
    fillRect(monitor, x, y, fill, 1, fillColor or colors.green, " ")
  end

  writeAt(monitor, x + 1, y, clip(label or "", math.max(1, width - 2)), textColor or colors.white, nil, math.max(1, width - 2))
end

local function drawRows(monitor, x, y, width, height, rows, fg, bg)
  for i = 1, math.min(height, #(rows or {})) do
    writeAt(monitor, x, y + i - 1, padRight(clip(rows[i], width), width), fg or colors.white, bg, width)
  end
end

local function worldClock()
  local ok, value = pcall(textutils.formatTime, os.time(), true)
  if ok and value then
    return value
  end
  return "-"
end

local function spinner()
  local frames = { "|", "/", "-", "\\" }
  return frames[(state.tick % #frames) + 1]
end

local function drawHeader(monitor, width, pageIndex, pageCount, title, snapshot, name)
  fillRect(monitor, 1, 1, width, 3, colors.black, " ")
  fillRect(monitor, 1, 1, width, 1, colors.blue, " ")

  local right = "Seite " .. tostring(pageIndex) .. "/" .. tostring(pageCount) .. " | " .. worldClock()
  local left = "LAGERNETZ // " .. tostring(title or "Monitor")
  writeAt(monitor, 2, 1, left, colors.white, colors.blue, math.max(1, width - #right - 3))
  writeAt(monitor, math.max(2, width - #right + 1), 1, right, colors.white, colors.blue, #right)

  local line2 = "Monitor: " .. tostring(name or "-") .. " | Letzter Scan: " .. formatSince(snapshot and snapshot.time or 0) .. " | Auto: groesster Monitor"
  local line3 = "Lokal " .. formatCompact(snapshot.localStats.totalItems) .. " | ME " .. formatCompact(snapshot.me.totalItems) .. " | Typen " .. formatCompact(snapshot.combined.uniqueItems) .. " | Strom " .. formatCompact(snapshot.energy.totalStored) .. " FE"
  writeAt(monitor, 2, 2, clip(line2, width - 2), colors.lightGray, colors.black, width - 2)
  writeAt(monitor, 2, 3, clip(line3, width - 2), colors.cyan, colors.black, width - 2)
end

local function drawFooter(monitor, width, height, pages, pageIndex)
  fillRect(monitor, 1, height, width, 1, colors.black, " ")

  local x = 1
  for i, page in ipairs(pages or {}) do
    local label = " " .. tostring(i) .. ":" .. clip(page.title, 10) .. " "
    local bg = (i == pageIndex) and colors.orange or colors.gray
    local fg = (i == pageIndex) and colors.black or colors.white
    if x <= width then
      local part = clip(label, width - x + 1)
      fillRect(monitor, x, height, #part, 1, bg, " ")
      writeAt(monitor, x, height, part, fg, bg, #part)
      x = x + #part
    end
    if x > width then
      break
    end
  end

  local status = " " .. spinner() .. " stats> 'seite <n>' | geheim: 'marcel' "
  local startX = math.max(1, width - #status + 1)
  fillRect(monitor, startX, height, math.min(width, #status), 1, colors.blue, " ")
  writeAt(monitor, startX, height, clip(status, width - startX + 1), colors.white, colors.blue, width - startX + 1)
end

local function renderDashboardPage(monitor, width, height, snapshot)
  local cardY = 4
  local cardH = 4
  local gap = 1
  local cardCount = 4
  local cardWidth = math.max(10, math.floor((width - ((cardCount - 1) * gap)) / cardCount))

  local cards = {
    {
      title = "Items gesamt",
      value = formatCompact(snapshot.combined.totalItems),
      subtitle = "Lokal " .. formatCompact(snapshot.localStats.totalItems) .. " | ME " .. formatCompact(snapshot.me.totalItems),
      accent = colors.green,
    },
    {
      title = "Typen",
      value = formatCompact(snapshot.combined.uniqueItems),
      subtitle = "Mods " .. formatCompact(#snapshot.combined.modOrder),
      accent = colors.cyan,
    },
    {
      title = "ME Speicher",
      value = snapshot.me.available and formatPercent(snapshot.me.usedItemStorage, snapshot.me.totalItemStorage) or "offline",
      subtitle = snapshot.me.available and (formatMaybeCount(snapshot.me.usedItemStorage) .. "/" .. formatMaybeCount(snapshot.me.totalItemStorage)) or "Keine Bridge",
      accent = colors.purple,
    },
    {
      title = "Strom",
      value = formatCompact(snapshot.energy.totalStored) .. " FE",
      subtitle = "Use " .. formatRate(snapshot.energy.totalUsage),
      accent = colors.red,
    },
  }

  for i, card in ipairs(cards) do
    local x = 1 + (i - 1) * (cardWidth + gap)
    local w = cardWidth
    if i == #cards then
      w = width - x + 1
    end
    drawCard(monitor, x, cardY, w, cardH, card.title, card.value, card.subtitle, card.accent)
  end

  local bodyY = cardY + cardH + 1
  local bodyH = math.max(6, height - bodyY - 1)
  local leftW = math.max(18, math.floor(width * 0.60))
  local rightW = width - leftW - 1
  local rightTopH = math.max(6, math.floor(bodyH * 0.55))
  local rightBottomH = bodyH - rightTopH - 1

  drawPanel(monitor, 1, bodyY, leftW, bodyH, "Top Items", colors.green, colors.black, colors.white)
  local maxValue = (#snapshot.combined.order > 0 and snapshot.combined.order[1].totalCount) or 0
  local maxRows = math.max(1, bodyH - 2)
  for i = 1, math.min(maxRows, #snapshot.combined.order) do
    local entry = snapshot.combined.order[i]
    local label = tostring(i) .. ". " .. clip(entry.displayName, math.max(6, leftW - 18)) .. " " .. formatCompact(entry.totalCount)
    drawBar(monitor, 2, bodyY + i, leftW - 2, entry.totalCount, maxValue, label, colors.green, colors.gray, colors.white)
  end
  if #snapshot.combined.order == 0 then
    writeAt(monitor, 3, bodyY + 2, "Keine Items erkannt.", colors.lightGray, colors.black, leftW - 4)
  end

  drawPanel(monitor, leftW + 2, bodyY, rightW, rightTopH, "Netzwerk", colors.cyan, colors.black, colors.white)
  local networkRows = {
    "Inventare: " .. formatCount(snapshot.localStats.inventoryCount),
    "Lokale Slots: " .. formatCount(snapshot.localStats.usedSlots) .. "/" .. formatCount(snapshot.localStats.totalSlots),
    "ME Bridge: " .. (snapshot.me.available and "online" or "offline"),
    "Craftbar: " .. formatCount(snapshot.me.craftableCount),
    "Fluids: " .. formatCount(snapshot.me.fluidCount),
    "Peripherals: " .. formatCount(snapshot.peripherals.total),
    "Monitorseiten: " .. tostring(#buildMonitorPages(snapshot)),
  }
  drawRows(monitor, leftW + 3, bodyY + 2, rightW - 2, rightTopH - 2, networkRows, colors.white, colors.black)

  if rightBottomH >= 3 then
    drawPanel(monitor, leftW + 2, bodyY + rightTopH + 1, rightW, rightBottomH, "Aenderungen", colors.orange, colors.black, colors.white)
    if #snapshot.changes == 0 then
      writeAt(monitor, leftW + 3, bodyY + rightTopH + 3, "Keine Aenderungen seit dem letzten Scan.", colors.lightGray, colors.black, rightW - 2)
    else
      for i = 1, math.min(rightBottomH - 2, #snapshot.changes) do
        local entry = snapshot.changes[i]
        local prefix = entry.delta > 0 and "+" or ""
        local row = tostring(i) .. ". " .. clip(entry.displayName, math.max(6, rightW - 16)) .. " " .. prefix .. formatCompact(entry.delta)
        local fg = entry.delta >= 0 and colors.lime or colors.red
        writeAt(monitor, leftW + 3, bodyY + rightTopH + 1 + i, row, fg, colors.black, rightW - 2)
      end
    end
  end
end

local function renderItemsPage(monitor, width, height, snapshot)
  local topY = 4
  local topH = math.max(6, height - topY - 1)
  local leftW = math.max(20, math.floor(width * 0.63))
  local rightW = width - leftW - 1

  drawPanel(monitor, 1, topY, leftW, topH, "Top Items im ganzen Netzwerk", colors.green, colors.black, colors.white)
  if #snapshot.combined.order == 0 then
    writeAt(monitor, 3, topY + 2, "Keine Items gefunden.", colors.lightGray, colors.black, leftW - 4)
  else
    local maxValue = snapshot.combined.order[1].totalCount or 0
    for i = 1, math.min(topH - 2, #snapshot.combined.order) do
      local entry = snapshot.combined.order[i]
      local tag = ""
      if entry.localCount > 0 and entry.meCount > 0 then
        tag = " L/ME"
      elseif entry.meCount > 0 then
        tag = " ME"
      else
        tag = " L"
      end
      local label = tostring(i) .. ". " .. clip(entry.displayName, math.max(8, leftW - 20)) .. " " .. formatCompact(entry.totalCount) .. tag
      drawBar(monitor, 2, topY + i, leftW - 2, entry.totalCount, maxValue, label, colors.green, colors.gray, colors.white)
    end
  end

  local upperH = math.max(7, math.floor(topH * 0.52))
  drawPanel(monitor, leftW + 2, topY, rightW, upperH, "Top Mods", colors.purple, colors.black, colors.white)
  if #snapshot.combined.modOrder == 0 then
    writeAt(monitor, leftW + 3, topY + 2, "Keine Mod-Daten.", colors.lightGray, colors.black, rightW - 2)
  else
    local modMax = snapshot.combined.modOrder[1].count or 0
    for i = 1, math.min(upperH - 2, #snapshot.combined.modOrder) do
      local entry = snapshot.combined.modOrder[i]
      local label = tostring(i) .. ". " .. clip(entry.label, math.max(8, rightW - 16)) .. " " .. formatCompact(entry.count)
      drawBar(monitor, leftW + 3, topY + i, rightW - 2, entry.count, modMax, label, colors.purple, colors.gray, colors.white)
    end
  end

  local bottomY = topY + upperH + 1
  local bottomH = topH - upperH - 1
  if bottomH >= 3 then
    drawPanel(monitor, leftW + 2, bottomY, rightW, bottomH, "Schnelle Fakten", colors.cyan, colors.black, colors.white)
    local facts = {
      "Lokale Items: " .. formatCount(snapshot.localStats.totalItems),
      "ME Items: " .. formatCount(snapshot.me.totalItems),
      "Freie Slots: " .. formatCount(snapshot.localStats.freeSlots),
      "ME Craftbar: " .. formatCount(snapshot.me.craftableCount),
      "Fluids: " .. formatCount(snapshot.me.fluidCount),
      "Stromquellen: " .. formatCount(#snapshot.energy.sources),
    }
    drawRows(monitor, leftW + 3, bottomY + 2, rightW - 2, bottomH - 2, facts, colors.white, colors.black)
  end
end

local function renderStoragePage(monitor, width, height, snapshot)
  local cardY = 4
  local cardH = 4
  local gap = 1
  local cardCount = 3
  local cardWidth = math.max(12, math.floor((width - ((cardCount - 1) * gap)) / cardCount))
  local topInv = snapshot.localStats.inventories[1]

  local cards = {
    {
      title = "Inventare",
      value = formatCount(snapshot.localStats.inventoryCount),
      subtitle = "lokal verbunden",
      accent = colors.cyan,
    },
    {
      title = "Slots",
      value = formatPercent(snapshot.localStats.usedSlots, snapshot.localStats.totalSlots),
      subtitle = formatCount(snapshot.localStats.usedSlots) .. "/" .. formatCount(snapshot.localStats.totalSlots),
      accent = colors.orange,
    },
    {
      title = "Groesstes Lager",
      value = topInv and formatCompact(topInv.totalItems) or "-",
      subtitle = topInv and clip(topInv.name, math.max(8, cardWidth - 4)) or "kein Inventar",
      accent = colors.green,
    },
  }

  for i, card in ipairs(cards) do
    local x = 1 + (i - 1) * (cardWidth + gap)
    local w = cardWidth
    if i == #cards then
      w = width - x + 1
    end
    drawCard(monitor, x, cardY, w, cardH, card.title, card.value, card.subtitle, card.accent)
  end

  local bodyY = cardY + cardH + 1
  local bodyH = math.max(6, height - bodyY - 1)
  local leftW = math.max(20, math.floor(width * 0.58))
  local rightW = width - leftW - 1

  drawPanel(monitor, 1, bodyY, leftW, bodyH, "Inventar-Auslastung", colors.cyan, colors.black, colors.white)
  if #snapshot.localStats.inventories == 0 then
    writeAt(monitor, 3, bodyY + 2, "Keine lokalen Inventare erkannt.", colors.lightGray, colors.black, leftW - 4)
  else
    local maxItems = snapshot.localStats.inventories[1].totalItems or 0
    for i = 1, math.min(bodyH - 2, #snapshot.localStats.inventories) do
      local inv = snapshot.localStats.inventories[i]
      local label = tostring(i) .. ". " .. clip(inv.name, math.max(8, leftW - 24)) .. " " .. formatCompact(inv.totalItems) .. " / " .. formatPercent(inv.usedSlots, inv.size)
      drawBar(monitor, 2, bodyY + i, leftW - 2, inv.totalItems, maxItems, label, colors.cyan, colors.gray, colors.white)
    end
  end

  local upperH = math.max(6, math.floor(bodyH * 0.52))
  drawPanel(monitor, leftW + 2, bodyY, rightW, upperH, "Mod-Verteilung", colors.purple, colors.black, colors.white)
  if #snapshot.combined.modOrder == 0 then
    writeAt(monitor, leftW + 3, bodyY + 2, "Keine Mods erkannt.", colors.lightGray, colors.black, rightW - 2)
  else
    local modMax = snapshot.combined.modOrder[1].count or 0
    for i = 1, math.min(upperH - 2, #snapshot.combined.modOrder) do
      local entry = snapshot.combined.modOrder[i]
      local label = tostring(i) .. ". " .. clip(entry.label, math.max(8, rightW - 16)) .. " " .. formatCompact(entry.count)
      drawBar(monitor, leftW + 3, bodyY + i, rightW - 2, entry.count, modMax, label, colors.purple, colors.gray, colors.white)
    end
  end

  local bottomY = bodyY + upperH + 1
  local bottomH = bodyH - upperH - 1
  if bottomH >= 3 then
    drawPanel(monitor, leftW + 2, bottomY, rightW, bottomH, "Peripherals", colors.orange, colors.black, colors.white)
    local rows = {
      "Gesamt: " .. formatCount(snapshot.peripherals.total),
      "Inventare: " .. formatCount(snapshot.peripherals.inventory),
      "Monitore: " .. formatCount(snapshot.peripherals.monitor),
      "ME Bridges: " .. formatCount(snapshot.peripherals.meBridge),
      "Speaker: " .. formatCount(snapshot.peripherals.speaker),
      "Stromdaten: " .. formatCount(snapshot.peripherals.energy),
    }
    drawRows(monitor, leftW + 3, bottomY + 2, rightW - 2, bottomH - 2, rows, colors.white, colors.black)
  end
end

local function renderMePage(monitor, width, height, snapshot)
  local me = snapshot.me
  if not me.available then
    drawPanel(monitor, 1, 4, width, height - 4, "ME System", colors.purple, colors.black, colors.white)
    writeAt(monitor, 4, 7, "Keine ME Bridge gefunden.", colors.white, colors.black, width - 6)
    writeAt(monitor, 4, 9, "Befehle: mebridge auto  |  mebridge <name>", colors.lightGray, colors.black, width - 6)
    writeAt(monitor, 4, 11, "Sobald eine Bridge gefunden wird, erscheinen hier", colors.lightGray, colors.black, width - 6)
    writeAt(monitor, 4, 12, "Items, Fluids, Speicher, Craftables und Energie.", colors.lightGray, colors.black, width - 6)
    return
  end

  local cardY = 4
  local cardH = 4
  local gap = 1
  local cardCount = 4
  local cardWidth = math.max(10, math.floor((width - ((cardCount - 1) * gap)) / cardCount))
  local cards = {
    {
      title = "ME Items",
      value = formatCompact(me.totalItems),
      subtitle = formatCount(me.uniqueItems) .. " Typen",
      accent = colors.purple,
    },
    {
      title = "Craftbar",
      value = formatCompact(me.craftableCount),
      subtitle = "Rezepte / Ziele",
      accent = colors.cyan,
    },
    {
      title = "Fluids",
      value = formatCompact(me.fluidCount),
      subtitle = formatCompact(me.fluidTotal) .. " Menge",
      accent = colors.blue,
    },
    {
      title = "ME Energie",
      value = formatCompact(me.energyStorage) .. " FE",
      subtitle = "Use " .. formatRate(me.energyUsage),
      accent = colors.red,
    },
  }

  for i, card in ipairs(cards) do
    local x = 1 + (i - 1) * (cardWidth + gap)
    local w = cardWidth
    if i == #cards then
      w = width - x + 1
    end
    drawCard(monitor, x, cardY, w, cardH, card.title, card.value, card.subtitle, card.accent)
  end

  local bodyY = cardY + cardH + 1
  local bodyH = math.max(6, height - bodyY - 1)
  local leftW = math.max(20, math.floor(width * 0.58))
  local rightW = width - leftW - 1

  drawPanel(monitor, 1, bodyY, leftW, bodyH, "ME Top Items", colors.purple, colors.black, colors.white)
  if #me.order == 0 then
    writeAt(monitor, 3, bodyY + 2, "Keine Items im ME System.", colors.lightGray, colors.black, leftW - 4)
  else
    local maxValue = me.order[1].meCount or me.order[1].totalCount or 0
    for i = 1, math.min(bodyH - 2, #me.order) do
      local entry = me.order[i]
      local amount = entry.meCount or entry.totalCount or 0
      local label = tostring(i) .. ". " .. clip(entry.displayName, math.max(8, leftW - 18)) .. " " .. formatCompact(amount)
      drawBar(monitor, 2, bodyY + i, leftW - 2, amount, maxValue, label, colors.purple, colors.gray, colors.white)
    end
  end

  local rightTopH = math.max(6, math.floor(bodyH * 0.52))
  drawPanel(monitor, leftW + 2, bodyY, rightW, rightTopH, "Fluids", colors.blue, colors.black, colors.white)
  if #me.fluids == 0 then
    writeAt(monitor, leftW + 3, bodyY + 2, "Keine Fluids erkannt.", colors.lightGray, colors.black, rightW - 2)
  else
    local maxFluid = me.fluids[1].amount or 0
    for i = 1, math.min(rightTopH - 2, #me.fluids) do
      local fluid = me.fluids[i]
      local label = tostring(i) .. ". " .. clip(fluid.displayName, math.max(8, rightW - 16)) .. " " .. formatCompact(fluid.amount)
      drawBar(monitor, leftW + 3, bodyY + i, rightW - 2, fluid.amount, maxFluid, label, colors.blue, colors.gray, colors.white)
    end
  end

  local bottomY = bodyY + rightTopH + 1
  local bottomH = bodyH - rightTopH - 1
  if bottomH >= 3 then
    drawPanel(monitor, leftW + 2, bottomY, rightW, bottomH, "ME Status", colors.red, colors.black, colors.white)
    local rows = {
      "Bridge: " .. me.name,
      "Item-Speicher: " .. formatMaybeCount(me.usedItemStorage) .. "/" .. formatMaybeCount(me.totalItemStorage),
      "Fluid-Speicher: " .. formatMaybeCount(me.usedFluidStorage) .. "/" .. formatMaybeCount(me.totalFluidStorage),
      "Zellen: " .. formatCount(me.cellCount),
      "CPUs: " .. formatCount(me.cpuCount),
      "Craftbar: " .. formatCount(me.craftableCount),
    }
    drawRows(monitor, leftW + 3, bottomY + 2, rightW - 2, bottomH - 2, rows, colors.white, colors.black)
  end
end

local function renderEnergyPage(monitor, width, height, snapshot)
  local cardY = 4
  local cardH = 4
  local gap = 1
  local cardCount = 4
  local cardWidth = math.max(10, math.floor((width - ((cardCount - 1) * gap)) / cardCount))
  local cards = {
    {
      title = "Gespeichert",
      value = formatCompact(snapshot.energy.totalStored) .. " FE",
      subtitle = formatCompact(snapshot.energy.totalCapacity) .. " FE max",
      accent = colors.red,
    },
    {
      title = "Transfer",
      value = formatCompact(snapshot.energy.totalRate) .. " FE/t",
      subtitle = "gemessen",
      accent = colors.orange,
    },
    {
      title = "Verbrauch",
      value = formatCompact(snapshot.energy.totalUsage) .. " FE/t",
      subtitle = "gesamt",
      accent = colors.purple,
    },
    {
      title = "Quellen",
      value = formatCount(#snapshot.energy.sources),
      subtitle = "mit Stromdaten",
      accent = colors.cyan,
    },
  }

  for i, card in ipairs(cards) do
    local x = 1 + (i - 1) * (cardWidth + gap)
    local w = cardWidth
    if i == #cards then
      w = width - x + 1
    end
    drawCard(monitor, x, cardY, w, cardH, card.title, card.value, card.subtitle, card.accent)
  end

  local bodyY = cardY + cardH + 1
  local bodyH = math.max(6, height - bodyY - 1)
  local leftW = math.max(22, math.floor(width * 0.66))
  local rightW = width - leftW - 1

  drawPanel(monitor, 1, bodyY, leftW, bodyH, "Energiequellen", colors.red, colors.black, colors.white)
  if #snapshot.energy.sources == 0 then
    writeAt(monitor, 3, bodyY + 2, "Keine Stromdaten gefunden.", colors.lightGray, colors.black, leftW - 4)
    writeAt(monitor, 3, bodyY + 4, "Tipp: Energy Detector oder ME Bridge anschliessen.", colors.lightGray, colors.black, leftW - 4)
  else
    local maxRate = 1
    for _, src in ipairs(snapshot.energy.sources) do
      local candidate = math.abs(src.rate or src.usage or src.stored or 0)
      if candidate > maxRate then
        maxRate = candidate
      end
    end

    for i = 1, math.min(bodyH - 2, #snapshot.energy.sources) do
      local src = snapshot.energy.sources[i]
      local metric = math.abs(src.rate or src.usage or src.stored or 0)
      local info = src.rate and formatRate(src.rate) or (src.usage and ("Use " .. formatRate(src.usage)) or formatEnergy(src.stored, src.capacity))
      local label = tostring(i) .. ". " .. clip(src.name, math.max(8, leftW - 22)) .. " " .. info
      drawBar(monitor, 2, bodyY + i, leftW - 2, metric, maxRate, label, colors.red, colors.gray, colors.white)
    end
  end

  local upperH = math.max(6, math.floor(bodyH * 0.50))
  drawPanel(monitor, leftW + 2, bodyY, rightW, upperH, "Delta", colors.orange, colors.black, colors.white)
  if #snapshot.changes == 0 then
    writeAt(monitor, leftW + 3, bodyY + 2, "Keine Aenderungen.", colors.lightGray, colors.black, rightW - 2)
  else
    for i = 1, math.min(upperH - 2, #snapshot.changes) do
      local entry = snapshot.changes[i]
      local prefix = entry.delta > 0 and "+" or ""
      local fg = entry.delta >= 0 and colors.lime or colors.red
      local row = tostring(i) .. ". " .. clip(entry.displayName, math.max(8, rightW - 16)) .. " " .. prefix .. formatCompact(entry.delta)
      writeAt(monitor, leftW + 3, bodyY + 1 + i, row, fg, colors.black, rightW - 2)
    end
  end

  local bottomY = bodyY + upperH + 1
  local bottomH = bodyH - upperH - 1
  if bottomH >= 3 then
    drawPanel(monitor, leftW + 2, bottomY, rightW, bottomH, "Live Hinweise", colors.cyan, colors.black, colors.white)
    local rows = {
      "Scan-Intervall: " .. tostring(state.config.scanInterval) .. "s",
      "Seitenwechsel: " .. tostring(state.config.pageInterval) .. "s",
      "Speaker: " .. (resolveSpeakerName() or "nicht gefunden"),
      "ME Bridge: " .. (snapshot.me.available and "online" or "offline"),
      "Monitor: " .. tostring(snapshot.monitorName or "-"),
    }
    drawRows(monitor, leftW + 3, bottomY + 2, rightW - 2, bottomH - 2, rows, colors.white, colors.black)
  end
end

local function renderChangesPage(monitor, width, height, snapshot)
  local topY = 4
  local boxH = math.max(6, height - topY - 1)
  local leftW = math.max(22, math.floor(width * 0.60))
  local rightW = width - leftW - 1

  drawPanel(monitor, 1, topY, leftW, boxH, "Aenderungen seit letztem Scan", colors.orange, colors.black, colors.white)
  if #snapshot.changes == 0 then
    writeAt(monitor, 3, topY + 2, "Keine Aenderungen erkannt.", colors.lightGray, colors.black, leftW - 4)
  else
    local maxDelta = 1
    for _, entry in ipairs(snapshot.changes) do
      local value = math.abs(entry.delta or 0)
      if value > maxDelta then
        maxDelta = value
      end
    end

    for i = 1, math.min(boxH - 2, #snapshot.changes) do
      local entry = snapshot.changes[i]
      local label = tostring(i) .. ". " .. clip(entry.displayName, math.max(8, leftW - 20)) .. " " .. (entry.delta > 0 and "+" or "") .. formatCompact(entry.delta)
      local color = entry.delta >= 0 and colors.lime or colors.red
      drawBar(monitor, 2, topY + i, leftW - 2, math.abs(entry.delta), maxDelta, label, color, colors.gray, colors.white)
    end
  end

  drawPanel(monitor, leftW + 2, topY, rightW, boxH, "Kurzstatus", colors.cyan, colors.black, colors.white)
  local topMod = snapshot.combined.modOrder[1]
  local topItem = snapshot.combined.order[1]
  local rows = {
    "Gesamtitems: " .. formatCount(snapshot.combined.totalItems),
    "Typen: " .. formatCount(snapshot.combined.uniqueItems),
    "Top Mod: " .. (topMod and topMod.label or "-"),
    "Top Item: " .. (topItem and topItem.displayName or "-"),
    "ME online: " .. (snapshot.me.available and "ja" or "nein"),
    "Energiequellen: " .. formatCount(#snapshot.energy.sources),
    "Kekse im Netz: " .. formatCount(countMatchingItems(snapshot, { "cookie", "keks" })),
    "Kuchen im Netz: " .. formatCount(countMatchingItems(snapshot, { "cake", "kuchen" })),
  }
  drawRows(monitor, leftW + 3, topY + 2, rightW - 2, boxH - 2, rows, colors.white, colors.black)
end

local function renderEasterPage(monitor, width, height, snapshot)
  fillRect(monitor, 1, 4, width, height - 4, colors.black, " ")
  local panelY = 5
  local panelH = math.max(8, height - panelY - 1)
  drawPanel(monitor, 2, panelY, width - 2, panelH, "Marcel-Modus", colors.magenta, colors.black, colors.white)

  local cookieCount = countMatchingItems(snapshot, { "cookie", "keks" })
  local cakeCount = countMatchingItems(snapshot, { "cake", "kuchen" })
  local topMod = snapshot.combined.modOrder[1] and snapshot.combined.modOrder[1].label or "-"
  local bridgeStatus = snapshot.me.available and "ME online" or "ME offline"

  local art = {
    "   __  __                       _ ",
    "  / /_/ /  ATL10 Lagerkern    (_)",
    " / __/ _ \\  Alles im Blick    / / ",
    "/_/ /_//_/  Marcel-Modus     /_/  ",
    "",
    "Kekse im Netz : " .. formatCount(cookieCount),
    "Kuchen im Netz: " .. formatCount(cakeCount),
    "Lieblings-Mod : " .. topMod,
    "Bridge-Status : " .. bridgeStatus,
    "Top Item      : " .. ((snapshot.combined.order[1] and snapshot.combined.order[1].displayName) or "-"),
    "",
    "Tipp: 'marcel' schaltet dieses Easteregg wieder aus.",
  }

  local startY = panelY + 2
  for i, line in ipairs(art) do
    if startY + i - 1 >= height then
      break
    end
    local fg = (i <= 4) and colors.magenta or colors.white
    if line == "" then
      fg = colors.black
    end
    writeAt(monitor, 5, startY + i - 1, clip(line, width - 8), fg, colors.black, width - 8)
  end
end

local function renderLargeMonitor(monitor, name, width, height, pages, page)
  drawHeader(monitor, width, state.page, #pages, page.title, state.snapshot, name)

  if page.kind == "dashboard" then
    renderDashboardPage(monitor, width, height, state.snapshot)
  elseif page.kind == "items" then
    renderItemsPage(monitor, width, height, state.snapshot)
  elseif page.kind == "storage" then
    renderStoragePage(monitor, width, height, state.snapshot)
  elseif page.kind == "me" then
    renderMePage(monitor, width, height, state.snapshot)
  elseif page.kind == "energy" then
    renderEnergyPage(monitor, width, height, state.snapshot)
  elseif page.kind == "changes" then
    renderChangesPage(monitor, width, height, state.snapshot)
  elseif page.kind == "easter" then
    renderEasterPage(monitor, width, height, state.snapshot)
  else
    drawPanel(monitor, 1, 4, width, height - 4, page.title, colors.blue, colors.black, colors.white)
    drawRows(monitor, 3, 6, width - 4, height - 8, page.lines or {}, colors.white, colors.black)
  end

  drawFooter(monitor, width, height, pages, state.page)
end

local function renderSmallMonitor(monitor, name, width, height, pages, page)
  local y = 1

  local function monLine(text, color)
    if y > height then
      return
    end
    writeAt(monitor, 1, y, padRight(clip(text, width), width), color or colors.white, colors.black, width)
    y = y + 1
  end

  monLine("Lager Statistik - " .. page.title, colors.cyan)
  monLine("Monitor: " .. name .. " | Seite " .. tostring(state.page) .. "/" .. tostring(#pages), colors.lightGray)

  for _, line in ipairs(page.lines or {}) do
    if y > height then
      break
    end
    monLine(line, colors.white)
  end
end

local function renderMonitor()
  local monitor, name = currentMonitor()
  if not monitor then
    return
  end

  local scale = tonumber(state.config.monitorScale) or DEFAULT_MONITOR_SCALE
  pcall(monitor.setTextScale, scale)
  pcall(monitor.setBackgroundColor, colors.black)
  pcall(monitor.setTextColor, colors.white)
  pcall(monitor.clear)
  pcall(monitor.setCursorPos, 1, 1)

  local width, height = monitorSize(monitor)
  local pages = buildMonitorPages(state.snapshot)
  if #pages == 0 then
    return
  end

  if state.page < 1 then
    state.page = 1
  end
  if state.page > #pages then
    state.page = 1
  end

  local page = pages[state.page]

  if isLargeMonitor(width, height) and state.snapshot then
    renderLargeMonitor(monitor, name, width, height, pages, page)
  else
    renderSmallMonitor(monitor, name, width, height, pages, page)
  end
end

local function printSection(title)
  print("")
  print("=== " .. title .. " ===")
end

local function showStatus()
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  printSection("Uebersicht")
  print("Lokale Inventare: " .. formatCount(snapshot.localStats.inventoryCount))
  print("Lokale Slots:     " .. formatCount(snapshot.localStats.usedSlots) .. "/" .. formatCount(snapshot.localStats.totalSlots) .. " (" .. formatPercent(snapshot.localStats.usedSlots, snapshot.localStats.totalSlots) .. ")")
  print("Lokale Items:     " .. formatCount(snapshot.localStats.totalItems))
  print("Lokale Typen:     " .. formatCount(snapshot.localStats.uniqueItems))
  print("ME Bridge:        " .. (snapshot.me.available and snapshot.me.name or "nicht gefunden"))
  print("ME Items:         " .. formatCount(snapshot.me.totalItems))
  print("ME Typen:         " .. formatCount(snapshot.me.uniqueItems))
  print("ME craftbar:      " .. formatCount(snapshot.me.craftableCount))
  print("Kombi Items:      " .. formatCount(snapshot.combined.totalItems))
  print("Kombi Typen:      " .. formatCount(snapshot.combined.uniqueItems))
  print("Energie-Quellen:  " .. formatCount(#snapshot.energy.sources))
  print("Letzter Scan:     " .. formatSince(snapshot.time))
end

local function showTop(limit)
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  limit = math.max(1, math.floor(tonumber(limit) or 15))
  printSection("Top Items")

  if #snapshot.combined.order == 0 then
    print("Keine Items gefunden.")
    return
  end

  for i = 1, math.min(limit, #snapshot.combined.order) do
    local entry = snapshot.combined.order[i]
    local line = string.format("%2d) %s = %s", i, entry.displayName, formatCount(entry.totalCount))
    if entry.localCount > 0 or entry.meCount > 0 then
      line = line .. " | Lokal " .. formatCount(entry.localCount) .. " | ME " .. formatCount(entry.meCount)
    end
    print(line)
  end
end

local function showMods(limit)
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  limit = math.max(1, math.floor(tonumber(limit) or 15))
  printSection("Mod Statistik")

  if #snapshot.combined.modOrder == 0 then
    print("Keine Mod-Daten gefunden.")
    return
  end

  for i = 1, math.min(limit, #snapshot.combined.modOrder) do
    local entry = snapshot.combined.modOrder[i]
    print(string.format("%2d) %s = %s", i, entry.label, formatCount(entry.count)))
  end
end

local function showInventories(limit)
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  limit = math.max(1, math.floor(tonumber(limit) or 15))
  printSection("Lokale Inventare")

  if #snapshot.localStats.inventories == 0 then
    print("Keine lokalen Inventare gefunden.")
    return
  end

  for i = 1, math.min(limit, #snapshot.localStats.inventories) do
    local inv = snapshot.localStats.inventories[i]
    print(string.format("%2d) %s", i, inv.name))
    print("    Typen:  " .. inv.types)
    print("    Items:  " .. formatCount(inv.totalItems))
    print("    Slots:  " .. formatCount(inv.usedSlots) .. "/" .. formatCount(inv.size) .. " (frei " .. formatCount(inv.freeSlots) .. ")")
  end
end

local function showMe()
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  printSection("ME System")
  if not snapshot.me.available then
    print("Keine ME Bridge gefunden.")
    return
  end

  local me = snapshot.me
  print("Bridge:           " .. me.name)
  print("Items gesamt:     " .. formatCount(me.totalItems))
  print("Item-Typen:       " .. formatCount(me.uniqueItems))
  print("Craftbar:         " .. formatCount(me.craftableCount))
  print("Fluids:           " .. formatCount(me.fluidCount) .. " Typen / " .. formatCount(me.fluidTotal) .. " Menge")
  print("Item-Speicher:    " .. formatMaybeCount(me.usedItemStorage) .. "/" .. formatMaybeCount(me.totalItemStorage))
  print("Fluid-Speicher:   " .. formatMaybeCount(me.usedFluidStorage) .. "/" .. formatMaybeCount(me.totalFluidStorage))
  print("Energie:          " .. formatEnergy(me.energyStorage, me.maxEnergyStorage))
  print("Verbrauch:        " .. formatRate(me.energyUsage))
  print("Zellen:           " .. formatCount(me.cellCount))
  print("CPUs:             " .. formatCount(me.cpuCount))
end

local function showFluids(limit)
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  limit = math.max(1, math.floor(tonumber(limit) or 15))
  printSection("ME Fluids")

  if not snapshot.me.available then
    print("Keine ME Bridge gefunden.")
    return
  end

  if #snapshot.me.fluids == 0 then
    print("Keine Fluids gefunden.")
    return
  end

  for i = 1, math.min(limit, #snapshot.me.fluids) do
    local fluid = snapshot.me.fluids[i]
    print(string.format("%2d) %s = %s", i, fluid.displayName, formatCount(fluid.amount)))
  end
end

local function showCraftables(limit)
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  limit = math.max(1, math.floor(tonumber(limit) or 20))
  printSection("ME Craftables")

  if not snapshot.me.available then
    print("Keine ME Bridge gefunden.")
    return
  end

  if #snapshot.me.craftables == 0 then
    print("Keine craftbaren Items gefunden.")
    return
  end

  for i = 1, math.min(limit, #snapshot.me.craftables) do
    local item = snapshot.me.craftables[i]
    print(string.format("%2d) %s", i, item.displayName))
  end
end

local function showEnergy()
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  printSection("Strom")
  if #snapshot.energy.sources == 0 then
    print("Keine Stromquellen erkannt.")
    print("Tipp: Energy Detector oder ME Bridge nutzen.")
    return
  end

  print("Gespeichert: " .. formatEnergy(snapshot.energy.totalStored, snapshot.energy.totalCapacity))
  print("Transfer:    " .. formatRate(snapshot.energy.totalRate))
  print("Verbrauch:   " .. formatRate(snapshot.energy.totalUsage))
  print("")

  for i, src in ipairs(snapshot.energy.sources) do
    print(string.format("%2d) %s", i, src.name))
    print("    Typen:      " .. src.types)
    print("    Gespeichert:" .. " " .. formatEnergy(src.stored, src.capacity))
    print("    Transfer:   " .. formatRate(src.rate))
    print("    Verbrauch:  " .. formatRate(src.usage))
  end
end

local function showPeripherals()
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  printSection("Peripherals")
  print("Gesamt:     " .. formatCount(snapshot.peripherals.total))
  print("Inventare:  " .. formatCount(snapshot.peripherals.inventory))
  print("Monitore:   " .. formatCount(snapshot.peripherals.monitor))
  print("ME Bridge:  " .. formatCount(snapshot.peripherals.meBridge))
  print("Modems:     " .. formatCount(snapshot.peripherals.modem))
  print("Speaker:    " .. formatCount(snapshot.peripherals.speaker))
  print("Stromdaten: " .. formatCount(snapshot.peripherals.energy))
  print("")

  for i, entry in ipairs(snapshot.peripherals.list) do
    print(string.format("%2d) %s [%s]", i, entry.name, entry.types))
  end
end

local function showChanges(limit)
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  limit = math.max(1, math.floor(tonumber(limit) or 15))
  printSection("Aenderungen seit letztem Scan")

  if #snapshot.changes == 0 then
    print("Keine Aenderungen erkannt.")
    return
  end

  for i = 1, math.min(limit, #snapshot.changes) do
    local entry = snapshot.changes[i]
    local prefix = entry.delta > 0 and "+" or ""
    print(string.format("%2d) %s: %s%s (vorher %s, jetzt %s)", i, entry.displayName, prefix, formatCount(entry.delta), formatCount(entry.before), formatCount(entry.after)))
  end
end

local function showFind(term)
  local snapshot = state.snapshot
  if not snapshot then
    print("Noch kein Scan vorhanden.")
    return
  end

  term = trim(term):lower()
  if term == "" then
    print("Bitte Suchbegriff angeben.")
    return
  end

  printSection("Suche: " .. term)
  local found = 0

  for _, entry in ipairs(snapshot.combined.order) do
    local hay = (entry.displayName .. " " .. entry.name):lower()
    if hay:find(term, 1, true) then
      found = found + 1
      print(string.format("%2d) %s = %s | Lokal %s | ME %s", found, entry.displayName, formatCount(entry.totalCount), formatCount(entry.localCount), formatCount(entry.meCount)))
      if found >= 20 then
        break
      end
    end
  end

  if found == 0 then
    print("Keine Treffer.")
  end
end

local function showMonitorStatus()
  local name = resolveMonitorName()
  local area, width, height = monitorArea(name)
  printSection("Monitor")
  print("Monitor:       " .. (name or "aus / keiner gefunden"))
  if name then
    print("Groesse:       " .. tostring(width) .. "x" .. tostring(height) .. " Zeichen (" .. formatCount(area) .. ")")
    print("Auto-Auswahl:  waehlt den groessten gefundenen Monitor")
  end
  print("Skalierung:    " .. tostring(state.config.monitorScale))
  print("Scan Intervall:" .. " " .. tostring(state.config.scanInterval) .. "s")
  print("Seitenwechsel: " .. tostring(state.config.pageInterval) .. "s")
end

local function showHelp()
  printSection("Statistik-Modus")
  print("Dieses Script bewegt keine Items.")
  print("Es liest nur Lager-, ME- und Stromdaten aus.")
  print("")
  print("Befehle:")
  print("  help / hilfe             - Hilfe anzeigen")
  print("  scan                     - sofort neu scannen")
  print("  status                   - Uebersicht")
  print("  top [n]                  - groesste Itemstapel")
  print("  mods [n]                 - Mod-Statistik")
  print("  inv [n]                  - lokale Inventare")
  print("  me                       - ME-Details")
  print("  fluids [n]               - ME-Fluids")
  print("  craft [n]                - craftbare ME-Items")
  print("  energy / strom           - Stromdaten")
  print("  find <text>              - Itemsuche lokal + ME")
  print("  changes [n]              - Veraenderungen")
  print("  periph                   - erkannte Peripherals")
  print("  monitor                  - Monitorstatus")
  print("  monitor off              - Monitor deaktivieren")
  print("  monitor auto             - groessten Monitor automatisch finden")
  print("  monitor <name>           - festen Monitor setzen")
  print("  monitor scale <wert>     - z.B. 0.5")
  print("  mebridge off             - ME Bridge deaktivieren")
  print("  mebridge auto            - ME Bridge automatisch finden")
  print("  mebridge <name>          - feste ME Bridge setzen")
  print("  intervall <scan> [page]  - Zeiten in Sekunden")
  print("  seite <n|next|prev>      - Monitorseite manuell")
  print("  marcel                   - kleines Easteregg auf dem Monitor")
  print("  exit                     - Script beenden")
end

local function handleMonitorCommand(args)
  if not args[2] then
    showMonitorStatus()
    return
  end

  local sub = tostring(args[2]):lower()

  if sub == "off" then
    state.config.monitorDisabled = true
    state.config.monitorName = nil
    saveConfig()
    scanAll(true)
    print("Monitor deaktiviert.")
    return
  end

  if sub == "auto" then
    state.config.monitorDisabled = false
    state.config.monitorName = nil
    saveConfig()
    scanAll(true)
    renderMonitor()
    print("Monitor wird jetzt automatisch gesucht.")
    return
  end

  if sub == "scale" then
    local value = tonumber(args[3] or "")
    if not value then
      print("Bitte gueltigen Zahlenwert angeben, z.B. 0.5")
      return
    end

    state.config.monitorScale = value
    saveConfig()
    renderMonitor()
    print("Monitor-Skalierung gesetzt auf " .. tostring(value))
    return
  end

  local name = args[2]
  if peripheral.isPresent(name) and hasType(name, "monitor") then
    state.config.monitorDisabled = false
    state.config.monitorName = name
    saveConfig()
    scanAll(true)
    renderMonitor()
    print("Monitor gesetzt auf " .. name)
  else
    print("Monitor '" .. tostring(name) .. "' nicht gefunden.")
  end
end

local function handleMeBridgeCommand(args)
  if not args[2] then
    printSection("ME Bridge")
    print("ME Bridge: " .. (resolveMeBridgeName() or "aus / keine gefunden"))
    return
  end

  local sub = tostring(args[2]):lower()

  if sub == "off" then
    state.config.meBridgeDisabled = true
    state.config.meBridgeName = nil
    saveConfig()
    scanAll(true)
    renderMonitor()
    print("ME Bridge deaktiviert.")
    return
  end

  if sub == "auto" then
    state.config.meBridgeDisabled = false
    state.config.meBridgeName = nil
    saveConfig()
    scanAll(true)
    renderMonitor()
    print("ME Bridge wird jetzt automatisch gesucht.")
    return
  end

  local name = args[2]
  if peripheral.isPresent(name) and hasType(name, "meBridge") then
    state.config.meBridgeDisabled = false
    state.config.meBridgeName = name
    saveConfig()
    scanAll(true)
    renderMonitor()
    print("ME Bridge gesetzt auf " .. name)
  else
    print("ME Bridge '" .. tostring(name) .. "' nicht gefunden.")
  end
end

local function handleIntervalCommand(args)
  local scanValue = tonumber(args[2] or "")
  local pageValue = tonumber(args[3] or "")

  if not scanValue then
    print("Bitte mindestens das Scan-Intervall angeben.")
    return
  end

  state.config.scanInterval = math.max(2, math.floor(scanValue))
  if pageValue then
    state.config.pageInterval = math.max(2, math.floor(pageValue))
  end

  saveConfig()
  print("Intervalle gesetzt: Scan " .. tostring(state.config.scanInterval) .. "s | Seitenwechsel " .. tostring(state.config.pageInterval) .. "s")
end

local function handlePageCommand(args)
  local pages = buildMonitorPages(state.snapshot)
  if #pages == 0 then
    print("Keine Monitorseiten vorhanden.")
    return
  end

  if not args[2] then
    print("Aktuelle Seite: " .. tostring(state.page) .. "/" .. tostring(#pages) .. " - " .. pages[state.page].title)
    return
  end

  local sub = tostring(args[2]):lower()
  if sub == "next" then
    state.page = state.page + 1
    if state.page > #pages then
      state.page = 1
    end
  elseif sub == "prev" then
    state.page = state.page - 1
    if state.page < 1 then
      state.page = #pages
    end
  else
    local pageNumber = tonumber(sub)
    if not pageNumber then
      print("Bitte Seitenzahl, 'next' oder 'prev' angeben.")
      return
    end
    state.page = math.max(1, math.min(#pages, math.floor(pageNumber)))
  end

  state.lastPageSwitch = nowMs()
  renderMonitor()
  print("Seite: " .. tostring(state.page) .. "/" .. tostring(#pages) .. " - " .. pages[state.page].title)
end

local function handleCommand(line)
  line = trim(line)
  if line == "" then
    return true
  end

  local args = {}
  for token in line:gmatch("%S+") do
    args[#args + 1] = token
  end

  local cmd = tostring(args[1] or ""):lower()

  if cmd == "help" or cmd == "hilfe" then
    showHelp()
  elseif cmd == "scan" or cmd == "refresh" then
    scanAll(false)
    renderMonitor()
  elseif cmd == "status" then
    showStatus()
  elseif cmd == "top" then
    showTop(args[2])
  elseif cmd == "mods" then
    showMods(args[2])
  elseif cmd == "inv" or cmd == "inventare" or cmd == "lager" then
    showInventories(args[2])
  elseif cmd == "me" then
    showMe()
  elseif cmd == "fluids" then
    showFluids(args[2])
  elseif cmd == "craft" or cmd == "craftables" then
    showCraftables(args[2])
  elseif cmd == "energy" or cmd == "strom" then
    showEnergy()
  elseif cmd == "find" or cmd == "suche" then
    local term = trim(line:sub(#args[1] + 1))
    showFind(term)
  elseif cmd == "changes" or cmd == "aenderungen" or cmd == "anderungen" then
    showChanges(args[2])
  elseif cmd == "periph" or cmd == "peripherals" then
    showPeripherals()
  elseif cmd == "monitor" then
    handleMonitorCommand(args)
  elseif cmd == "mebridge" then
    handleMeBridgeCommand(args)
  elseif cmd == "intervall" or cmd == "interval" then
    handleIntervalCommand(args)
  elseif cmd == "seite" or cmd == "page" then
    handlePageCommand(args)
  elseif cmd == "marcel" or cmd == "easteregg" or cmd == "party" then
    state.easterUnlocked = not state.easterUnlocked
    if state.easterUnlocked then
      playSecretJingle()
      local pages = buildMonitorPages(state.snapshot)
      state.page = #pages
      print("Marcel-Modus aktiviert. Schau auf den Monitor.")
    else
      state.page = 1
      print("Marcel-Modus deaktiviert.")
    end
    renderMonitor()
  elseif cmd == "exit" or cmd == "quit" or cmd == "ende" then
    state.running = false
    return false
  else
    print("Unbekannter Befehl: " .. cmd)
    print("Mit 'help' bekommst du alle Befehle.")
  end

  return true
end

local function backgroundLoop()
  while state.running do
    local now = nowMs()
    state.tick = state.tick + 1

    if (not state.snapshot) or (now - state.lastScan >= (state.config.scanInterval * 1000)) then
      scanAll(true)
    end

    if state.snapshot then
      local pages = buildMonitorPages(state.snapshot)
      if #pages > 1 and (now - state.lastPageSwitch >= (state.config.pageInterval * 1000)) then
        state.page = state.page + 1
        if state.page > #pages then
          state.page = 1
        end
        state.lastPageSwitch = now
      end
    end

    renderMonitor()
    sleep(1)
  end
end

local function commandLoop()
  print("Lager Statistik gestartet.")
  print("Nur noch Lesen / Statistiken - keine Item-Bewegung mehr.")
  print("ME Bridge und Stromdaten werden automatisch erkannt, wenn vorhanden.")
  print("Monitor auto waehlt jetzt den groessten gefundenen Monitor.")
  print("Mit 'help' bekommst du alle Befehle.")
  print("")

  scanAll(true)
  renderMonitor()
  showStatus()

  while state.running do
    write("stats> ")
    local line = read()
    if line == nil then
      break
    end
    if not handleCommand(line) then
      break
    end
  end
end

loadConfig()
state.lastPageSwitch = nowMs()
parallel.waitForAny(commandLoop, backgroundLoop)
