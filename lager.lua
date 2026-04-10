local IO_NAME = nil
local MONITOR_NAME = nil
local MONITOR_SCALE = 0.5
local SORT_INTERVAL = 1
local SCAN_INTERVAL = 5
local PAGE_INTERVAL = 4
local TOPOLOGY_REFRESH_INTERVAL = 10
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
}

local SIDE_ORDER = { "top", "bottom", "left", "right", "front", "back" }

local function sortedNames()
  local names = peripheral.getNames()
  table.sort(names)
  return names
end

local function isInventory(name)
  return name and peripheral.isPresent(name) and peripheral.hasType(name, "inventory")
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
    "stripped_",
    "planks",
    "_stem",
    "_hyphae",
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

    local name = value.displayName or value.name or tostring(value)
    parts[#parts + 1] = tostring(name)
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

local function listSignature(list)
  return table.concat(list or {}, "\31")
end

local function buildTopologySignature(ioName, poolNames, storageNames)
  return table.concat({
    tostring(ioName or ""),
    listSignature(poolNames or {}),
    listSignature(storageNames or {}),
  }, "\30")
end

local function refreshTopology()
  state.ioName = chooseIOName()
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

  saveMap()

  local newSig = buildTopologySignature(state.ioName, state.poolNames, state.storageNames)
  if state.topologySig == "" or state.topologySig ~= newSig then
    state.dirty = true
  end
  state.topologySig = newSig
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
          local modName = namespaceOf(item.name)
          entry = {
            key = key,
            name = item.name,
            nbt = item.nbt,
            modName = modName,
            modLabel = prettyModName(modName),
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
  state.lastScan = os.epoch("utc")
  state.dirty = false
end

local function ensureTopologyFresh(force)
  local now = os.epoch("utc")

  if not force and (now - state.lastTopologyCheck) < (TOPOLOGY_REFRESH_INTERVAL * 1000) then
    return false
  end

  state.lastTopologyCheck = now
  local previousSig = state.topologySig
  local ok = pcall(refreshTopology)

  if not ok then
    return false
  end

  return state.topologySig ~= previousSig
end

local function ensureFresh(force)
  local topologyChanged = ensureTopologyFresh(force)

  if force or topologyChanged or state.dirty or (os.epoch("utc") - state.lastScan) >= (SCAN_INTERVAL * 1000) then
    scanStorage()
  end
end

local function sortInput()
  local movedAny = false

  for slot = 1, inputEnd() do
    while true do
      local item = state.io.getItemDetail(slot)
      if not item then
        break
      end

      local target = chooseTargetForItem(item)
      local moved = 0

      if target then
        local ok, sent = pcall(state.io.pushItems, target, slot)
        if ok and sent and sent > 0 then
          moved = sent
        end
      end

      if moved == 0 and SPECIAL_TARGETS.overflow and isInventory(SPECIAL_TARGETS.overflow) and target ~= SPECIAL_TARGETS.overflow then
        local ok, sent = pcall(state.io.pushItems, SPECIAL_TARGETS.overflow, slot)
        if ok and sent and sent > 0 then
          moved = sent
        end
      end

      if moved == 0 then
        break
      end

      movedAny = true
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

  local moved = 0
  for toSlot = outputStart(), state.io.size() do
    local remaining = amount - moved
    if remaining <= 0 then
      break
    end

    local ok, sent = pcall(inv.pushItems, state.ioName, fromSlot, remaining, toSlot)
    if ok and sent and sent > 0 then
      moved = moved + sent
    end
  end

  return moved
end

local function splitWords(text)
  local out = {}

  for part in tostring(text or ""):gmatch("%S+") do
    out[#out + 1] = part
  end

  return out
end

local function matchEntryScore(entry, query)
  local q = trim(query):lower()
  if q == "" then
    return nil
  end

  local display = entry.displayName:lower()
  local name = entry.name:lower()
  local desc = tostring(entry.desc or ""):lower()
  local modName = namespaceOf(entry.name):lower()
  local modLabel = prettyModName(modName):lower()

  if q:sub(1, 1) == "@" then
    local modQuery = trim(q:sub(2))
    if modQuery == "" then
      return nil
    end

    if modName == modQuery or modLabel == modQuery then
      return 1000
    end

    local score = 0
    if modName:find(modQuery, 1, true) == 1 or modLabel:find(modQuery, 1, true) == 1 then
      score = score + 700
    end
    if modName:find(modQuery, 1, true) or modLabel:find(modQuery, 1, true) then
      score = score + 300
    end

    return score > 0 and score or nil
  end

  if name == q or display == q or (desc ~= "" and desc == q) then
    return 1000
  end

  local score = 0
  if display:find(q, 1, true) == 1 then
    score = score + 700
  end
  if desc ~= "" and desc:find(q, 1, true) == 1 then
    score = score + 650
  end
  if name:find(q, 1, true) == 1 then
    score = score + 600
  end
  if display:find(q, 1, true) then
    score = score + 300
  end
  if desc ~= "" and desc:find(q, 1, true) then
    score = score + 260
  end
  if name:find(q, 1, true) then
    score = score + 220
  end

  local words = splitWords(q)
  local wordHits = 0

  for _, word in ipairs(words) do
    local hit = false

    if display:find(word, 1, true) then
      score = score + 90
      hit = true
    end
    if desc ~= "" and desc:find(word, 1, true) then
      score = score + 70
      hit = true
    end
    if name:find(word, 1, true) then
      score = score + 50
      hit = true
    end

    if hit then
      wordHits = wordHits + 1
    end
  end

  if #words > 1 and wordHits < #words then
    return nil
  end

  if score > 0 then
    score = score + math.min(100, wordHits * 15)
    return score
  end

  return nil
end

local function findMatches(query)
  ensureFresh(false)

  local scored = {}
  local q = trim(query)
  if q == "" then
    return {}
  end

  for _, entry in ipairs(state.order) do
    local score = matchEntryScore(entry, q)
    if score then
      scored[#scored + 1] = {
        entry = entry,
        score = score,
      }
    end
  end

  table.sort(scored, function(a, b)
    if a.score == b.score then
      local al = entryLabel(a.entry):lower()
      local bl = entryLabel(b.entry):lower()
      if al == bl then
        return a.entry.name < b.entry.name
      end
      return al < bl
    end
    return a.score > b.score
  end)

  local out = {}
  for i, row in ipairs(scored) do
    out[i] = row.entry
  end

  return out
end

local function clearShownEntries()
  state.lastShownKeys = {}
  state.lastShownQuery = ""
end

local function rememberShownEntries(entries, query)
  clearShownEntries()
  state.lastShownQuery = trim(query)

  for i, entry in ipairs(entries) do
    state.lastShownKeys[i] = entry.key
  end
end

local function printEntryLine(index, entry)
  local width = select(1, term.getSize()) or 51
  local prefix = ("%2d) "):format(index)
  local countText = " x" .. formatCount(entry.count)
  local free = math.max(10, width - #prefix - #countText)
  local text = clip(entryLabel(entry), free)
  local padding = math.max(1, width - #prefix - #text - #countText)

  print(prefix .. text .. string.rep(" ", padding) .. countText)
end

local function printPreviewEntries(entries, maxLines)
  local width = select(1, term.getSize()) or 51

  for i = 1, math.min(#entries, maxLines) do
    local entry = entries[i]
    local prefix = " - "
    local countText = " x" .. formatCount(entry.count)
    local free = math.max(10, width - #prefix - #countText)
    local text = clip(entryLabel(entry), free)
    local padding = math.max(1, width - #prefix - #text - #countText)

    print(prefix .. text .. string.rep(" ", padding) .. countText)
  end
end

local function collectModSummary(entries)
  local mods = {}

  for _, entry in ipairs(entries) do
    local ns = namespaceOf(entry.name)
    local row = mods[ns]
    if not row then
      row = {
        key = ns,
        label = prettyModName(ns),
        types = 0,
        items = 0,
      }
      mods[ns] = row
    end

    row.types = row.types + 1
    row.items = row.items + entry.count
  end

  local out = {}
  for _, row in pairs(mods) do
    out[#out + 1] = row
  end

  table.sort(out, function(a, b)
    if a.types == b.types then
      return a.label < b.label
    end
    return a.types > b.types
  end)

  return out
end

local function printOverview()
  local byCount = {}
  for i, entry in ipairs(state.order) do
    byCount[i] = entry
  end

  table.sort(byCount, function(a, b)
    if a.count == b.count then
      return entryLabel(a):lower() < entryLabel(b):lower()
    end
    return a.count > b.count
  end)

  local mods = collectModSummary(state.order)

  print(("Typen: %d | Items: %s | Lagerkisten: %d"):format(#state.order, formatCount(state.totalItems), #state.storageNames))
  print("Schnell finden mit:")
  print(" list <name>      sucht nach Name oder Beschreibung")
  print(" list @mod        zeigt nur Items aus einem Mod")
  print(" hole <name>      gibt direkt aus")
  print(" hole #<nr>       nimmt Nummer aus letzter Trefferliste")
  print("")
  print("Meiste Items:")
  printPreviewEntries(byCount, LIST_PREVIEW_COUNT)

  if #mods > 0 then
    print("")
    print("Mods im Lager:")
    for i = 1, math.min(#mods, LIST_MOD_COUNT) do
      local row = mods[i]
      print((" %d) %s - %d Typen, %s Items"):format(i, row.label, row.types, formatCount(row.items)))
    end

    if #mods > LIST_MOD_COUNT then
      print((" ... %d weitere Mods"):format(#mods - LIST_MOD_COUNT))
    end
  end
end

local function printEntries(entries, maxLines, startIndex)
  maxLines = maxLines or #entries
  startIndex = startIndex or 1

  local endIndex = math.min(#entries, startIndex + maxLines - 1)
  for i = startIndex, endIndex do
    printEntryLine(i, entries[i])
  end
end

local function showPagedEntries(entries, title)
  local height = select(2, term.getSize()) or 19
  local pageSize = math.max(5, height - 5)
  local pageCount = math.max(1, math.ceil(#entries / pageSize))
  local page = 1

  while true do
    local startIndex = (page - 1) * pageSize + 1
    local endIndex = math.min(#entries, startIndex + pageSize - 1)

    print(("%s | Seite %d/%d | %d-%d von %d"):format(title, page, pageCount, startIndex, endIndex, #entries))
    printEntries(entries, pageSize, startIndex)

    if pageCount == 1 then
      return
    end

    write("[Enter=weiter, Zahl=Seite, q=Ende] ")
    local answer = trim(read() or ""):lower()

    if answer == "" then
      page = page + 1
      if page > pageCount then
        return
      end
    elseif answer == "q" or answer == "x" or answer == "ende" then
      return
    else
      local wanted = tonumber(answer)
      if wanted and wanted >= 1 and wanted <= pageCount then
        page = wanted
      else
        print("Bitte Enter, q oder eine Seitennummer eingeben.")
      end
    end
  end
end

local function chooseMatch(matches)
  if #matches == 1 then
    return matches[1]
  end

  local height = select(2, term.getSize()) or 19
  local pageSize = math.max(5, height - 6)
  local pageCount = math.max(1, math.ceil(#matches / pageSize))
  local page = 1

  print("Mehrdeutig. Waehle die passende Nummer.")

  while true do
    local startIndex = (page - 1) * pageSize + 1
    local endIndex = math.min(#matches, startIndex + pageSize - 1)

    print(("Treffer %d-%d von %d | Seite %d/%d"):format(startIndex, endIndex, #matches, page, pageCount))
    printEntries(matches, pageSize, startIndex)
    write(("Auswahl 1-%d (n/p/q): "):format(#matches))

    local line = trim(read() or ""):lower()
    if line == "" or line == "q" or line == "x" or line == "abbrechen" then
      return nil
    elseif line == "n" or line == "weiter" then
      page = page + 1
      if page > pageCount then
        page = 1
      end
    elseif line == "p" or line == "zurueck" then
      page = page - 1
      if page < 1 then
        page = pageCount
      end
    else
      local idx = tonumber(line)
      if idx and matches[idx] then
        return matches[idx]
      end

      print("Bitte eine gueltige Nummer oder n/p/q eingeben.")
    end
  end
end

local function resolveListReference(query)
  local idx = tonumber(tostring(query or ""):match("^#(%d+)$"))
  if not idx then
    return nil, nil
  end

  local key = state.lastShownKeys[idx]
  if not key then
    return false, "Nummer nicht in letzter Trefferliste: #" .. tostring(idx)
  end

  local entry = state.index[key]
  if not entry then
    return false, "Der Eintrag #" .. tostring(idx) .. " ist nicht mehr im Lager vorhanden."
  end

  return entry, nil
end

local function withdraw(query, amount)
  ensureFresh(true)

  local entry, refError = resolveListReference(query)
  if entry == false then
    print(refError)
    return
  end

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
    print(("Nicht mehr vorhanden oder Output-Haelfte voll: %d"):format(remaining))
  end
end

local function listItems(filter)
  ensureFresh(false)

  local cleanFilter = trim(filter)
  if cleanFilter == "" then
    clearShownEntries()
    printOverview()
    return
  end

  local hits = findMatches(cleanFilter)
  if #hits == 0 then
    clearShownEntries()
    print("Keine Treffer fuer: " .. tostring(cleanFilter))
    return
  end

  rememberShownEntries(hits, cleanFilter)
  showPagedEntries(hits, ("Treffer fuer '%s': %d"):format(cleanFilter, #hits))
  print("Tipp: Mit 'hole #<nr>' kannst du direkt eine Nummer aus der Liste holen.")
end

local function listAssignments()
  ensureTopologyFresh(false)

  print("I/O: " .. tostring(state.ioName))
  print("Input-Slots: 1-" .. inputEnd())
  print("Output-Slots: " .. outputStart() .. "-" .. state.io.size())
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
  print("I/O-Kiste: " .. tostring(state.ioName))
  print("Lager-Inventare: " .. tostring(#state.storageNames))
  print("Mod-Pool: " .. tostring(#state.poolNames))
  print("Monitor: " .. (state.monitor and "ja" or "nein"))
  print("Auto-Kistencheck: alle " .. tostring(TOPOLOGY_REFRESH_INTERVAL) .. "s")
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
    local topologyChanged = ensureTopologyFresh(false)
    sortInput()

    if topologyChanged then
      scanStorage()
    end

    sleep(SORT_INTERVAL)
  end
end

local function fullScan()
  refreshTopology()
  state.lastTopologyCheck = os.epoch("utc")
  sortInput()
  scanStorage()
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
  print(" list")
  print(" list <filter>")
  print(" list @<mod>")
  print(" hole <name> [anzahl]")
  print(" hole #<nr> [anzahl]")
  print(" stop")
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

    for part in tostring(line or ""):gmatch("%S+") do
      args[#args + 1] = part
    end

    local cmd = (args[1] or ""):lower()

    if cmd == "" then
    elseif cmd == "hilfe" then
      printHelp()
    elseif cmd == "status" then
      ensureFresh(false)
      printStatus()
    elseif cmd == "zuordnung" then
      listAssignments()
    elseif cmd == "scan" then
      local ok, err = pcall(fullScan)
      if ok then
        print("Scan fertig. Neue Kisten und Items wurden uebernommen.")
      else
        print("Scan fehlgeschlagen: " .. tostring(err))
      end
    elseif cmd == "neu" then
      local ok, err = pcall(fullScan)
      if ok then
        print("Peripherie neu geladen.")
        printStatus()
      else
        print("Neu laden fehlgeschlagen: " .. tostring(err))
      end
    elseif cmd == "list" or cmd == "such" or cmd == "suche" or cmd == "find" then
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
state.lastTopologyCheck = os.epoch("utc")
ensureFresh(true)

parallel.waitForAny(
  commandLoop,
  function()
    parallel.waitForAll(sorterLoop, monitorLoop)
  end
)
