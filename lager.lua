local IO_NAME = nil
local MONITOR_NAME = nil
local MONITOR_SCALE = 0.5
local SORT_INTERVAL = 1
local SCAN_INTERVAL = 5
local PAGE_INTERVAL = 4
local TOPOLOGY_REFRESH_INTERVAL = 10
local OUTPUT_HOLD_SECONDS = 120
local LIST_PREVIEW_COUNT = 10
local LIST_MOD_COUNT = 8
local MAP_FILE = "mod_map.txt"

local SPECIAL_TARGETS = {
  ores = nil,
  stone = nil,
  wood = nil,
  overflow = nil,
}

local AUTO_MOD_POOL = true
local MOD_POOL_NAMES = {
  -- "create:item_vault_0",
  -- "create:item_vault_1",
  -- "minecraft:chest_3",
  -- "minecraft:chest_4",
}

local state = {
  ioName = nil,
  io = nil,
  monitor = nil,
  poolNames = {},
  storageNames = {},
  modMap = {},
  freePool = {},
  index = {},
  order = {},
  totalItems = 0,
  totalStacks = 0,
  lastScan = 0,
  lastTopologyCheck = 0,
  topologySig = "",
  lastShownKeys = {},
  lastShownQuery = "",
  dirty = true,
  outputReservations = {},
}

local SIDE_ORDER = { "top", "bottom", "left", "right", "front", "back" }

local function nowMs()
  return os.epoch("utc")
end

local function sortedNames()
  local names = peripheral.getNames()
  table.sort(names)
  return names
end

local function isInventory(name)
  return name and peripheral.isPresent(name) and peripheral.hasType(name, "inventory")
end

local function inventorySignature()
  local out = {}

  for _, name in ipairs(sortedNames()) do
    if isInventory(name) then
      local inv = peripheral.wrap(name)
      local size = 0

      if inv and inv.size then
        local ok, value = pcall(inv.size)
        if ok and value then
          size = value
        end
      end

      out[#out + 1] = tostring(name) .. "=" .. tostring(size)
    end
  end

  return table.concat(out, "|")
end

local function uniqueList(list)
  local out = {}
  local seen = {}

  for _, value in ipairs(list) do
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

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function outputStart()
  return math.floor(state.io.size() / 2) + 1
end

local function inputEnd()
  return outputStart() - 1
end

local function entryKey(item)
  return tostring(item.name) .. "#" .. tostring(item.nbt or "")
end

local function namespaceOf(itemName)
  return tostring(itemName):match("^(.-):") or "unknown"
end

local function chooseIOName()
  if IO_NAME and isInventory(IO_NAME) then
    return IO_NAME
  end

  if state.ioName and isInventory(state.ioName) then
    return state.ioName
  end

  for _, name in ipairs(sortedNames()) do
    if isInventory(name) and tostring(name):match("^minecraft:chest") then
      return name
    end
  end

  for _, side in ipairs(SIDE_ORDER) do
    if isInventory(side) then
      return side
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
  if type(data) == "table" then
    state.modMap = data
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

local function classifyItemName(itemName)
  local base = tostring(itemName):match(":(.+)$") or tostring(itemName)

  if base == "ancient_debris"
    or base:find("_ore", 1, true)
    or base:find("ore_", 1, true)
    or base:find("raw_", 1, true)
    or base:find("_raw", 1, true)
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
  }

  for _, part in ipairs(stoneParts) do
    if base:find(part, 1, true) then
      return "stone"
    end
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

  for _, part in ipairs(woodParts) do
    if base:find(part, 1, true) then
      return "wood"
    end
  end

  return nil
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

local function discoverPoolNames()
  local out = {}
  local reserved = {}

  reserved[state.ioName] = true
  for _, name in pairs(SPECIAL_TARGETS) do
    if name then
      reserved[name] = true
    end
  end

  if AUTO_MOD_POOL then
    for _, name in ipairs(sortedNames()) do
      if isInventory(name) and not reserved[name] then
        out[#out + 1] = name
      end
    end
  else
    for _, name in ipairs(MOD_POOL_NAMES) do
      if isInventory(name) and not reserved[name] then
        out[#out + 1] = name
      end
    end
  end

  table.sort(out)
  return uniqueList(out)
end

local function cleanupOutputReservations()
  if not state.io then
    state.outputReservations = {}
    return
  end

  local now = nowMs()

  for slot, expiresAt in pairs(state.outputReservations) do
    if expiresAt <= now or not state.io.getItemDetail(slot) then
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

  if expiresAt <= nowMs() or not state.io.getItemDetail(slot) then
    state.outputReservations[slot] = nil
    return false
  end

  return true
end

local function refreshTopology()
  local oldIOName = state.ioName
  local chosenIO = chooseIOName()

  state.ioName = chosenIO
  if not state.ioName then
    error("Keine I/O-Kiste gefunden.\nSetz IO_NAME auf deine normale Minecraft-Kiste.", 0)
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

  state.poolNames = discoverPoolNames()

  local allStorage = {}
  for _, name in pairs(SPECIAL_TARGETS) do
    if name and isInventory(name) and name ~= state.ioName then
      allStorage[#allStorage + 1] = name
    end
  end

  for _, name in ipairs(state.poolNames) do
    allStorage[#allStorage + 1] = name
  end

  state.storageNames = uniqueList(allStorage)

  if #state.storageNames == 0 then
    error("Keine Lager-Inventare gefunden.\nTrag SPECIAL_TARGETS oder MOD_POOL_NAMES ein.", 0)
  end

  local validPool = {}
  for _, name in ipairs(state.poolNames) do
    validPool[name] = true
  end

  local cleanMap = {}
  local used = {}
  for modName, invName in pairs(state.modMap) do
    if validPool[invName] and not used[invName] then
      cleanMap[modName] = invName
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

  if oldIOName ~= state.ioName then
    state.outputReservations = {}
  end

  saveMap()
  state.topologySig = inventorySignature()
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
  if force or sig ~= state.topologySig then
    refreshTopology()
    return true
  end

  return false
end

local function ensureModTarget(modName)
  local current = state.modMap[modName]
  if current and isInventory(current) then
    return current
  end

  local nextFree = table.remove(state.freePool, 1)
  if nextFree then
    state.modMap[modName] = nextFree
    saveMap()
    return nextFree
  end

  if SPECIAL_TARGETS.overflow and isInventory(SPECIAL_TARGETS.overflow) then
    return SPECIAL_TARGETS.overflow
  end

  return nil
end

local function chooseTargetForItem(item)
  local special = classifyItemName(item.name)
  if special and SPECIAL_TARGETS[special] and isInventory(SPECIAL_TARGETS[special]) then
    return SPECIAL_TARGETS[special], special
  end

  local modName = namespaceOf(item.name)
  return ensureModTarget(modName), modName
end

local function scanStorage()
  local index = {}
  local order = {}
  local totalItems = 0
  local totalStacks = 0

  for _, invName in ipairs(state.storageNames) do
    local inv = peripheral.wrap(invName)
    if inv then
      for slot, item in pairs(inv.list()) do
        totalStacks = totalStacks + 1
        totalItems = totalItems + item.count

        local key = entryKey(item)
        local entry = index[key]
        if not entry then
          local detail = inv.getItemDetail(slot)
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

local function pushFromIO(targetName, fromSlot, toSlot)
  if not targetName or targetName == state.ioName or not isInventory(targetName) then
    return 0
  end

  local current = state.io.getItemDetail(fromSlot)
  if not current then
    return 0
  end

  local ok, sent
  if toSlot then
    ok, sent = pcall(state.io.pushItems, targetName, fromSlot, current.count, toSlot)
  else
    ok, sent = pcall(state.io.pushItems, targetName, fromSlot, current.count)
  end

  if ok and sent and sent > 0 then
    return sent
  end

  return 0
end

local function moveIntoKnownStacks(fromSlot, item)
  local entry = state.index[entryKey(item)]
  if not entry then
    return 0
  end

  local moved = 0

  for _, loc in ipairs(entry.locs) do
    if not state.io.getItemDetail(fromSlot) then
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

      if not state.io.getItemDetail(fromSlot) then
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

  for slot = 1, state.io.size() do
    if not isReservedOutputSlot(slot) then
      while true do
        local item = state.io.getItemDetail(slot)
        if not item then
          break
        end

        local moved = 0

        moved = moved + moveIntoKnownStacks(slot, item)

        local attemptedInventories = {}

        if state.io.getItemDetail(slot) then
          local target = chooseTargetForItem(item)
          if target and not attemptedInventories[target] then
            attemptedInventories[target] = true
            moved = moved + pushFromIO(target, slot)
          end
        end

        if state.io.getItemDetail(slot)
          and SPECIAL_TARGETS.overflow
          and isInventory(SPECIAL_TARGETS.overflow)
          and not attemptedInventories[SPECIAL_TARGETS.overflow]
        then
          attemptedInventories[SPECIAL_TARGETS.overflow] = true
          moved = moved + pushFromIO(SPECIAL_TARGETS.overflow, slot)
        end

        if state.io.getItemDetail(slot) then
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

local function moveIntoOutput(fromInvName, fromSlot, amount)
  local inv = peripheral.wrap(fromInvName)
  if not inv then
    return 0
  end

  cleanupOutputReservations()

  local moved = 0
  for toSlot = outputStart(), state.io.size() do
    local remaining = amount - moved
    if remaining <= 0 then
      break
    end

    if not isReservedOutputSlot(toSlot) then
      local ok, sent = pcall(inv.pushItems, state.ioName, fromSlot, remaining, toSlot)
      if ok and sent and sent > 0 then
        moved = moved + sent
        reserveOutputSlot(toSlot)
      end
    end
  end

  return moved
end

local function findMatches(query)
  ensureFresh(false)

  local q = tostring(query or ""):lower()
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

local function chooseMatch(matches)
  if #matches == 1 then
    return matches[1]
  end

  if #matches > 30 then
    print("Zu viele Treffer. Bitte Suchbegriff verfeinern.")
    printEntries(matches, 30)
    return nil
  end

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

  local matches = findMatches(query)
  if #matches == 0 then
    print("Nichts gefunden: " .. tostring(query))
    return
  end

  local entry = chooseMatch(matches)
  if not entry then
    print("Abgebrochen.")
    return
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
    print(("Nicht mehr vorhanden oder Ausgabe-Bereich belegt: %d"):format(remaining))
  end
end

local function listItems(filter)
  ensureFresh(false)

  if not filter or filter == "" then
    print(("Typen: %d | Items: %s"):format(#state.order, formatCount(state.totalItems)))
    printEntries(state.order, 20)
    return
  end

  local hits = findMatches(filter)
  if #hits == 0 then
    print("Keine Treffer fuer: " .. tostring(filter))
    return
  end

  print(("Treffer fuer '%s': %d"):format(filter, #hits))
  printEntries(hits, 20)
end

local function listAssignments()
  ensureFresh(false)

  print("I/O: " .. tostring(state.ioName))
  print("Auto-Einsortieren: alle Slots")
  print("Ausgabe-Schutz: Slots " .. outputStart() .. "-" .. state.io.size() .. " fuer " .. OUTPUT_HOLD_SECONDS .. "s nach 'hole'")
  print("")
  print("Spezialkisten:")
  print(" ores -> " .. tostring(SPECIAL_TARGETS.ores or "-"))
  print(" stone -> " .. tostring(SPECIAL_TARGETS.stone or "-"))
  print(" wood -> " .. tostring(SPECIAL_TARGETS.wood or "-"))
  print(" overflow -> " .. tostring(SPECIAL_TARGETS.overflow or "-"))
  print("")
  print("Mod-Zuordnung:")

  local pairsList = {}
  for modName, invName in pairs(state.modMap) do
    pairsList[#pairsList + 1] = { mod = modName, inv = invName }
  end

  table.sort(pairsList, function(a, b)
    return a.mod < b.mod
  end)

  if #pairsList == 0 then
    print(" noch keine")
  else
    for _, row in ipairs(pairsList) do
      print(" " .. row.mod .. " -> " .. row.inv)
    end
  end

  print("")
  print("Freie Mod-Kisten: " .. #state.freePool)
end

local function printStatus()
  ensureFresh(false)

  print("I/O-Kiste: " .. tostring(state.ioName))
  print("Lager-Inventare: " .. tostring(#state.storageNames))
  print("Mod-Pool: " .. tostring(#state.poolNames))
  print("Monitor: " .. (state.monitor and "ja" or "nein"))
  print("Auto-Einsortieren: alle Slots")
  print("Ausgabe-Schutz unten: " .. OUTPUT_HOLD_SECONDS .. "s")
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

local function sorterLoop()
  while true do
    sortInput()
    sleep(SORT_INTERVAL)
  end
end

local function fullScan()
  ensureTopology(true)
  sortInput()
  ensureFresh(true)
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
  print(" scan")
  print(" neu")
  print(" list [filter]")
  print(" hole <name> [anzahl]")
  print(" stop")
  print("")
  print("Hinweis:")
  print(" Alle Slots der I/O-Kiste werden automatisch einsortiert.")
  print(" Der untere Bereich bleibt nach 'hole' " .. OUTPUT_HOLD_SECONDS .. "s als Ausgabe geschuetzt.")
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
    elseif cmd == "scan" then
      fullScan()
      print("Scan fertig. Neue Kisten wurden uebernommen und das Lager neu sortiert.")
    elseif cmd == "neu" then
      fullScan()
      print("Peripherie neu geladen.")
      printStatus()
    elseif cmd == "list" then
      listItems(table.concat(args, " ", 2))
    elseif cmd == "hole" then
      local query, amount = parseQueryAndAmount(args, 2)
      if query == "" then
        print("Benutzung: hole <name> [anzahl]")
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
