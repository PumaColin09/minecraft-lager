-- Marcel ChronoShow
-- Two-monitor clock show for CC:Tweaked
-- Auto-detects the two largest monitors and all speakers.
-- Optional: chrono_show_dual <monitorA> <monitorB>

local VERSION = "1.1"

local CONFIG = {
  textScale = 0.5,
  frameDelay = 0.12,
  partySeconds = 32,
  quoteDelay = 8,
  minuteChime = true,
  quarterChime = true,
  hourChime = true,
  touchPartyCount = 5,
  touchWindow = 5,
}

local args = { ... }
if #args >= 1 then CONFIG.monitorAName = args[1] end
if #args >= 2 then CONFIG.monitorBName = args[2] end

local QUOTES = {
  "ZEIT FLIESST. REDSTONE AUCH.",
  "MARCEL-O-MATIC ONLINE",
  "KAFFEE > SCHLAF > BUGFIX",
  "DIE GLOCKE WEISS ALLES",
  "HEUTE WIRD NICHT GESTRESST",
  "TICK. TOCK. BOOM.",
  "MONITOREN HABEN AUCH GEFUEHLE",
  "AE2 KANN WARTEN. UHR LAEUFT.",
  "ICH BIN NICHT SPAET. DIE SEKUNDEN SIND FRUEH.",
}

local COLOR_CYCLE = {
  colors.cyan,
  colors.lightBlue,
  colors.blue,
  colors.purple,
  colors.magenta,
  colors.pink,
  colors.red,
  colors.orange,
  colors.yellow,
  colors.lime,
  colors.green,
}

local FONT = {
  ["0"] = { "11111", "10001", "10001", "10001", "11111" },
  ["1"] = { "00100", "01100", "00100", "00100", "01110" },
  ["2"] = { "11111", "00001", "11111", "10000", "11111" },
  ["3"] = { "11111", "00001", "01111", "00001", "11111" },
  ["4"] = { "10001", "10001", "11111", "00001", "00001" },
  ["5"] = { "11111", "10000", "11111", "00001", "11111" },
  ["6"] = { "11111", "10000", "11111", "10001", "11111" },
  ["7"] = { "11111", "00010", "00100", "01000", "01000" },
  ["8"] = { "11111", "10001", "11111", "10001", "11111" },
  ["9"] = { "11111", "10001", "11111", "00001", "11111" },
  [":"] = { "0", "1", "0", "1", "0" },
  [" "] = { "0", "0", "0", "0", "0" },
}

local state = {
  startClock = os.clock(),
  quoteIndex = 1,
  nextQuoteAt = 0,
  partyUntil = 0,
  statusMessage = "ChronoShow online",
  statusUntil = 0,
  lastMinute = nil,
  lastSecond = nil,
  frame = 0,
  soundFlashUntil = 0,
  touchTimes = {},
}

local monitors = {}
local speakers = {}
local soundQueue = {}
local particles = {}

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function round(n)
  return math.floor(n + 0.5)
end

local function splitWords(str)
  local out = {}
  for word in tostring(str):gmatch("%S+") do
    out[#out + 1] = word
  end
  return out
end

local function wrapText(text, width)
  local words = splitWords(text)
  local lines = {}
  local line = ""
  for i = 1, #words do
    local word = words[i]
    local candidate = line == "" and word or (line .. " " .. word)
    if #candidate <= width then
      line = candidate
    else
      if line ~= "" then lines[#lines + 1] = line end
      line = word
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  if #lines == 0 then lines[1] = "" end
  return lines
end

local function phaseName(gameTime)
  local h = math.floor(gameTime) % 24
  if h >= 6 and h < 11 then return "Morgen" end
  if h >= 11 and h < 18 then return "Tag" end
  if h >= 18 and h < 21 then return "Abend" end
  return "Nacht"
end

local function getClockSnapshot()
  local localTime = os.time("local") or 0
  local hour = math.floor(localTime) % 24
  local minute = math.floor(((localTime - math.floor(localTime)) * 60) + 1e-6)
  local second = math.floor((os.epoch("local") / 1000) % 60)
  local gameTime = os.time() or 0
  local uptime = math.floor(os.clock() - state.startClock)
  local secondsToNextMinute = 59 - second
  return {
    hour = hour,
    minute = minute,
    second = second,
    hm = string.format("%02d:%02d", hour, minute),
    hms = string.format("%02d:%02d:%02d", hour, minute, second),
    localFmt = textutils.formatTime(localTime, true),
    gameFmt = textutils.formatTime(gameTime, true),
    phase = phaseName(gameTime),
    uptime = uptime,
    minuteProgress = second / 59,
    epoch = os.epoch("local"),
    secondPulse = math.sin((second / 60) * math.pi * 2),
    nextMinute = secondsToNextMinute,
  }
end

local function detectSpeakers()
  local found = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "speaker" then
      found[#found + 1] = { name = name, obj = peripheral.wrap(name) }
    end
  end
  table.sort(found, function(a, b) return a.name < b.name end)
  speakers = found
end

local function detectMonitors()
  local found = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local mon = peripheral.wrap(name)
      pcall(mon.setTextScale, CONFIG.textScale)
      local ok, w, h = pcall(function()
        return mon.getSize()
      end)
      w = tonumber(w)
      h = tonumber(h)
      if ok and w and h and w > 0 and h > 0 then
        found[#found + 1] = { name = name, obj = mon, w = w, h = h, area = w * h }
      end
    end
  end

  table.sort(found, function(a, b)
    if a.area == b.area then return a.name < b.name end
    return a.area > b.area
  end)

  local selected = {}
  if CONFIG.monitorAName then
    for i = 1, #found do
      if found[i].name == CONFIG.monitorAName then
        selected[#selected + 1] = found[i]
        break
      end
    end
  end
  if CONFIG.monitorBName then
    for i = 1, #found do
      if found[i].name == CONFIG.monitorBName then
        local dupe = false
        for j = 1, #selected do
          if selected[j].name == found[i].name then dupe = true end
        end
        if not dupe then selected[#selected + 1] = found[i] end
        break
      end
    end
  end

  for i = 1, #found do
    if #selected >= 2 then break end
    local dupe = false
    for j = 1, #selected do
      if selected[j].name == found[i].name then dupe = true end
    end
    if not dupe then selected[#selected + 1] = found[i] end
  end

  monitors = selected
  for i = 1, #monitors do
    pcall(monitors[i].obj.setTextScale, CONFIG.textScale)
  end
end

local function refreshMonitorGeometry(monData)
  if not monData or not monData.obj then return 0, 0 end

  local ok, w, h = pcall(function()
    return monData.obj.getSize()
  end)

  w = tonumber(w) or tonumber(monData.w) or 0
  h = tonumber(h) or tonumber(monData.h) or 0

  if ok and w > 0 and h > 0 then
    monData.w = w
    monData.h = h
    monData.area = w * h
  end

  return monData.w or 0, monData.h or 0
end

local function makeParticles(termWidth, termHeight, count)
  local list = {}
  for i = 1, count do
    list[#list + 1] = {
      x = math.random() * termWidth,
      y = math.random() * termHeight,
      vx = 0.12 + math.random() * 0.32,
      vy = -0.05 + math.random() * 0.10,
      color = COLOR_CYCLE[(i % #COLOR_CYCLE) + 1],
      glyph = (i % 5 == 0) and "+" or ((i % 2 == 0) and "." or "*")
    }
  end
  return list
end

local function refreshParticlePools()
  particles = {}
  for i = 1, #monitors do
    local mon = monitors[i]
    local w, h = refreshMonitorGeometry(mon)
    if w > 0 and h > 0 then
      particles[i] = makeParticles(w, h, clamp(math.floor((mon.area or (w * h)) / 80), 12, 48))
    else
      particles[i] = {}
    end
  end
end

local function rescanPeripherals()
  detectMonitors()
  detectSpeakers()
  refreshParticlePools()
  state.statusMessage = ("%d Monitor(e), %d Speaker online"):format(#monitors, #speakers)
  state.statusUntil = os.clock() + 4
end

local function playNoteAll(instrument, volume, pitch)
  for i = 1, #speakers do
    pcall(speakers[i].obj.playNote, instrument, volume, pitch)
  end
  state.soundFlashUntil = os.clock() + 0.25
end

local function playSoundAll(name, volume, pitch)
  for i = 1, #speakers do
    pcall(speakers[i].obj.playSound, name, volume, pitch)
  end
  state.soundFlashUntil = os.clock() + 0.30
end

local function enqueue(event)
  soundQueue[#soundQueue + 1] = event
end

local function queueMinuteChime()
  enqueue({ kind = "note", inst = "chime", vol = 1.1, pitch = 12, delay = 0.00 })
  enqueue({ kind = "note", inst = "bell", vol = 1.6, pitch = 16, delay = 0.16 })
end

local function queueQuarterChime(quarter)
  for i = 1, quarter do
    enqueue({ kind = "note", inst = "bell", vol = 2.2, pitch = 9, delay = (i == 1) and 0 or 0.45 })
  end
  enqueue({ kind = "note", inst = "chime", vol = 1.5, pitch = 17, delay = 0.20 })
end

local function queueHourChime(hour)
  for i = 1, 4 do
    enqueue({ kind = "note", inst = "bell", vol = 2.6, pitch = 8, delay = (i == 1) and 0 or 0.50 })
  end
  enqueue({ kind = "note", inst = "chime", vol = 1.6, pitch = 12, delay = 0.22 })
  enqueue({ kind = "note", inst = "chime", vol = 1.8, pitch = 19, delay = 0.15 })
  enqueue({ kind = "sound", name = "minecraft:block.amethyst_block.chime", vol = 0.9, pitch = 1.0, delay = 0.22 })
  state.statusMessage = ("Es ist %02d Uhr!"):format(hour)
  state.statusUntil = os.clock() + 7
end

local function queueTouchPling()
  enqueue({ kind = "note", inst = "pling", vol = 0.9, pitch = 18, delay = 0 })
end

local function queuePartyFanfare()
  local seq = {
    { "bit", 1.0, 10 }, { "bit", 1.0, 14 }, { "bit", 1.0, 17 },
    { "pling", 1.2, 19 }, { "xylophone", 1.0, 14 }, { "bell", 1.8, 18 },
  }
  local first = true
  for i = 1, #seq do
    local s = seq[i]
    enqueue({ kind = "note", inst = s[1], vol = s[2], pitch = s[3], delay = first and 0 or 0.10 })
    first = false
  end
end

local function startParty(reason)
  state.partyUntil = os.clock() + CONFIG.partySeconds
  state.statusMessage = reason or "Party mode!"
  state.statusUntil = state.partyUntil
  queuePartyFanfare()
end

local function activeQuote(now)
  if state.statusUntil > now then
    return state.statusMessage
  end
  if now >= state.nextQuoteAt then
    state.quoteIndex = (state.quoteIndex % #QUOTES) + 1
    state.nextQuoteAt = now + CONFIG.quoteDelay
  end
  return QUOTES[state.quoteIndex]
end

local function setColors(target, fg, bg)
  target.setTextColor(fg)
  target.setBackgroundColor(bg)
end

local function clear(target, bg)
  target.setBackgroundColor(bg)
  target.clear()
end

local function writeAt(target, x, y, text, fg, bg)
  local w, h = target.getSize()
  if y < 1 or y > h then return end
  if x > w or x + #text - 1 < 1 then return end
  if x < 1 then
    text = text:sub(2 - x)
    x = 1
  end
  if x + #text - 1 > w then
    text = text:sub(1, w - x + 1)
  end
  setColors(target, fg or colors.white, bg or colors.black)
  target.setCursorPos(x, y)
  target.write(text)
end

local function centerWrite(target, y, text, fg, bg)
  local w = select(1, target.getSize())
  local x = math.floor((w - #text) / 2) + 1
  writeAt(target, x, y, text, fg, bg)
end

local function fillRect(target, x1, y1, x2, y2, bg, ch, fg)
  local w, h = target.getSize()
  if x2 < 1 or y2 < 1 or x1 > w or y1 > h then return end
  x1 = clamp(x1, 1, w)
  x2 = clamp(x2, 1, w)
  y1 = clamp(y1, 1, h)
  y2 = clamp(y2, 1, h)
  local text = string.rep(ch or " ", x2 - x1 + 1)
  for y = y1, y2 do
    writeAt(target, x1, y, text, fg or colors.white, bg)
  end
end

local function drawBox(target, x1, y1, x2, y2, border, fill, title)
  fillRect(target, x1, y1, x2, y2, fill or colors.black, " ")
  writeAt(target, x1, y1, "+" .. string.rep("-", math.max(0, x2 - x1 - 1)) .. "+", border, fill)
  for y = y1 + 1, y2 - 1 do
    writeAt(target, x1, y, "|", border, fill)
    writeAt(target, x2, y, "|", border, fill)
  end
  if y2 > y1 then
    writeAt(target, x1, y2, "+" .. string.rep("-", math.max(0, x2 - x1 - 1)) .. "+", border, fill)
  end
  if title and #title > 0 and x2 - x1 > 4 then
    local t = " " .. title .. " "
    local tx = math.floor((x1 + x2 - #t) / 2)
    writeAt(target, tx, y1, t, border, fill)
  end
end

local function drawBar(target, x, y, width, ratio, fillColor, backColor, label)
  ratio = clamp(ratio or 0, 0, 1)
  local inner = math.max(0, width - 2)
  local filled = clamp(round(inner * ratio), 0, inner)
  writeAt(target, x, y, "[", colors.lightGray, backColor)
  if inner > 0 then
    local left = string.rep("=", filled)
    local right = string.rep("-", inner - filled)
    writeAt(target, x + 1, y, left, fillColor, backColor)
    writeAt(target, x + 1 + filled, y, right, colors.gray, backColor)
  end
  writeAt(target, x + width - 1, y, "]", colors.lightGray, backColor)
  if label then
    writeAt(target, x + 2, y, label, colors.white, backColor)
  end
end

local function drawParticles(mon, index)
  local list = particles[index]
  if not list then return end
  local w, h = mon.getSize()
  for i = 1, #list do
    local p = list[i]
    p.x = p.x + p.vx
    p.y = p.y + p.vy
    if p.x > w + 1 then
      p.x = 1
      p.y = math.random(2, h - 1)
    end
    if p.y < 2 then p.y = h - 1 end
    if p.y > h - 1 then p.y = 2 end
    if math.random() < 0.02 then
      p.color = COLOR_CYCLE[math.random(1, #COLOR_CYCLE)]
    end
    writeAt(mon, math.floor(p.x), math.floor(p.y), p.glyph, p.color, colors.black)
  end
end

local function drawBigGlyph(target, x, y, ch, scale, onColor, offColor)
  local pattern = FONT[ch] or FONT[" "]
  local width = #pattern[1] * scale
  for row = 1, #pattern do
    for sy = 0, scale - 1 do
      for col = 1, #pattern[row] do
        local bit = pattern[row]:sub(col, col)
        local bg = (bit == "1") and onColor or offColor
        writeAt(target, x + (col - 1) * scale, y + (row - 1) * scale + sy, string.rep(" ", scale), onColor, bg)
      end
    end
  end
  return width
end

local function drawBigTime(target, x, y, timeText, scale, onColor, offColor, colonVisible)
  local cursor = x
  for i = 1, #timeText do
    local ch = timeText:sub(i, i)
    if ch == ":" and not colonVisible then ch = " " end
    local width = drawBigGlyph(target, cursor, y, ch, scale, onColor, offColor)
    cursor = cursor + width + scale
  end
end

local function bigTimeWidth(text, scale)
  local total = 0
  for i = 1, #text do
    local ch = text:sub(i, i)
    local pattern = FONT[ch] or FONT[" "]
    total = total + (#pattern[1] * scale) + scale
  end
  return total - scale
end

local function drawFace(target, x, y, w, h, pulseColor, speaking)
  local cx = x + math.floor(w / 2)
  local eyeY = y + 2
  local mouthY = y + h - 3
  local blink = (state.frame % 26 == 0) or (state.frame % 27 == 0)

  for yy = y, y + h do
    local pad = math.abs((yy - (y + math.floor(h / 2))))
    local inner = w - math.floor(pad / 2)
    local startX = cx - math.floor(inner / 2)
    local finishX = cx + math.floor(inner / 2)
    fillRect(target, startX, yy, finishX, yy, colors.gray, " ")
  end

  writeAt(target, cx - 7, y + 1, " .------------. ", colors.lightGray, colors.black)
  writeAt(target, cx - 7, y + h, " '------------' ", colors.lightGray, colors.black)

  local eye = blink and "-" or "o"
  writeAt(target, cx - 5, eyeY, eye, pulseColor, colors.gray)
  writeAt(target, cx + 5, eyeY, eye, pulseColor, colors.gray)
  writeAt(target, cx - 2, eyeY + 2, "<>", colors.white, colors.gray)

  local mouth = speaking and "\\____/" or ((state.frame % 12 < 6) and "\\----/" or "\\____/")
  writeAt(target, cx - 3, mouthY, mouth, colors.black, colors.gray)
  writeAt(target, cx - 6, mouthY + 2, "MARCEL-O-MATIC", colors.white, colors.black)
end

local function renderLeft(monData, snap)
  local mon = monData.obj
  local w, h = refreshMonitorGeometry(monData)
  if w < 1 or h < 1 then return end
  clear(mon, colors.black)

  for y = 1, h do
    local stripe = ((y + state.frame) % 6 < 3) and colors.black or colors.gray
    fillRect(mon, 1, y, w, y, stripe, " ")
  end

  drawParticles(mon, 1)
  drawBox(mon, 1, 1, w, h, colors.cyan, colors.black, " CHRONO CORE ")

  local scale = (w >= 72 and h >= 25) and 3 or 2
  local timeText = snap.hm
  local timeWidth = bigTimeWidth(timeText, scale)
  local tx = math.floor((w - timeWidth) / 2) + 1
  local ty = math.max(4, math.floor(h * 0.18))
  local timeColor = (state.partyUntil > os.clock()) and COLOR_CYCLE[(state.frame % #COLOR_CYCLE) + 1] or colors.cyan
  local offColor = colors.black

  drawBigTime(mon, tx, ty, timeText, scale, timeColor, offColor, snap.second % 2 == 0)

  centerWrite(mon, ty + 5 * scale + 2, snap.hms, colors.white, colors.black)
  centerWrite(mon, ty + 5 * scale + 4, ("MC %s  |  %s  |  %d Speaker"):format(snap.gameFmt, snap.phase, #speakers), colors.lightBlue, colors.black)

  local barWidth = math.min(w - 6, 50)
  local bx = math.floor((w - barWidth) / 2) + 1
  drawBar(mon, bx, h - 5, barWidth, snap.minuteProgress, colors.lime, colors.black, ("Minute %02d / 59"):format(snap.second))
  centerWrite(mon, h - 3, "Touch 5x schnell fuer Party Mode", colors.gray, colors.black)
  centerWrite(mon, h - 2, "CTRL+T beendet | ChronoShow " .. VERSION, colors.gray, colors.black)
end

local function renderRight(monData, snap)
  local mon = monData.obj
  local w, h = refreshMonitorGeometry(monData)
  if w < 1 or h < 1 then return end
  clear(mon, colors.black)

  for y = 1, h do
    local c = (y % 2 == 0) and colors.black or colors.gray
    fillRect(mon, 1, y, w, y, c, " ")
  end

  drawParticles(mon, 2)
  drawBox(mon, 1, 1, w, h, colors.orange, colors.black, " MARCEL TIME DECK ")

  local quote = activeQuote(os.clock())
  local quoteLines = wrapText(quote, w - 6)
  for i = 1, math.min(2, #quoteLines) do
    centerWrite(mon, 2 + i, quoteLines[i], COLOR_CYCLE[((state.frame + i) % #COLOR_CYCLE) + 1], colors.black)
  end

  drawBox(mon, 3, 5, w - 2, math.min(h - 11, 22), colors.lightBlue, colors.black, " STATUS FACE ")
  local speaking = state.soundFlashUntil > os.clock()
  local faceColor = (state.partyUntil > os.clock()) and COLOR_CYCLE[(state.frame % #COLOR_CYCLE) + 1] or colors.orange
  drawFace(mon, 6, 8, w - 12, math.min(12, h - 18), faceColor, speaking)

  local eqBaseY = math.min(h - 10, 23)
  local eqHeight = math.max(4, math.min(10, h - eqBaseY - 6))
  local eqLeft = 5
  local eqRight = w - 5
  for i = 0, 9 do
    local x = eqLeft + i * math.floor((eqRight - eqLeft) / 10)
    local wave = math.abs(math.sin((state.frame / 5) + (i * 0.7) + (snap.second / 10)))
    if speaking then wave = clamp(wave + 0.35, 0, 1) end
    if state.partyUntil > os.clock() then wave = clamp(wave + 0.20, 0, 1) end
    local level = math.floor(wave * eqHeight)
    for y = 0, eqHeight - 1 do
      local color = (y < level) and COLOR_CYCLE[((i + y + state.frame) % #COLOR_CYCLE) + 1] or colors.gray
      writeAt(mon, x, eqBaseY + eqHeight - y, " ", colors.white, color)
    end
  end

  local panelTop = h - 8
  drawBox(mon, 3, panelTop, w - 2, h - 1, colors.yellow, colors.black, " CLOCK DATA ")
  writeAt(mon, 5, panelTop + 1, "Real : " .. snap.hms, colors.white, colors.black)
  writeAt(mon, 5, panelTop + 2, "MC   : " .. snap.gameFmt .. "  (" .. snap.phase .. ")", colors.lightBlue, colors.black)
  writeAt(mon, 5, panelTop + 3, ("Next bell in %02ds"):format(snap.nextMinute + 1), colors.lime, colors.black)
  writeAt(mon, 5, panelTop + 4, ("Uptime %ds | Party %s"):format(snap.uptime, state.partyUntil > os.clock() and "AN" or "AUS"), colors.orange, colors.black)
  writeAt(mon, 5, panelTop + 5, ("Monitor %s | %dx%d"):format(monData.name, w, h), colors.gray, colors.black)
end

local function renderSingle(monData, snap)
  local mon = monData.obj
  local w, h = refreshMonitorGeometry(monData)
  if w < 1 or h < 1 then return end
  clear(mon, colors.black)
  drawParticles(mon, 1)
  drawBox(mon, 1, 1, w, h, colors.cyan, colors.black, " CHRONOSHOW SINGLE ")

  local scale = (w >= 72 and h >= 25) and 3 or 2
  local timeText = snap.hm
  local timeWidth = bigTimeWidth(timeText, scale)
  local tx = math.floor((w - timeWidth) / 2) + 1
  local ty = math.max(4, math.floor(h * 0.14))
  local timeColor = (state.partyUntil > os.clock()) and COLOR_CYCLE[(state.frame % #COLOR_CYCLE) + 1] or colors.cyan

  drawBigTime(mon, tx, ty, timeText, scale, timeColor, colors.black, snap.second % 2 == 0)
  centerWrite(mon, ty + 5 * scale + 2, activeQuote(os.clock()), colors.orange, colors.black)
  centerWrite(mon, ty + 5 * scale + 4, ("Real %s | MC %s | %s"):format(snap.hms, snap.gameFmt, snap.phase), colors.white, colors.black)
  drawBar(mon, 4, h - 4, w - 6, snap.minuteProgress, colors.lime, colors.black, ("Minute %02d / 59"):format(snap.second))
  centerWrite(mon, h - 2, "5x Touch = Party | " .. #speakers .. " Speaker", colors.gray, colors.black)
end

local function bootSequence()
  for i = 1, #monitors do
    local monData = monitors[i]
    local mon = monData.obj
    local w, h = refreshMonitorGeometry(monData)
    if w > 0 and h > 0 then
      clear(mon, colors.black)
      drawBox(mon, 1, 1, w, h, colors.cyan, colors.black, " MARCEL CHRONOSHOW BOOT ")
      centerWrite(mon, math.floor(h / 2) - 2, "Synchronisiere Monitore", colors.white, colors.black)
      drawBar(mon, 5, math.floor(h / 2), w - 8, 0, colors.lime, colors.black, "0%")
    end
  end

  local steps = {
    "Pruefe Monitore",
    "Wecke Lautsprecher",
    "Kalibriere Glocke",
    "Starte Zeitmaschine",
    "Fast fertig",
  }

  for i = 1, #steps do
    local ratio = i / #steps
    for m = 1, #monitors do
      local monData = monitors[m]
      local mon = monData.obj
      local w, h = refreshMonitorGeometry(monData)
      if w > 0 and h > 0 then
        centerWrite(mon, math.floor(h / 2) - 1, steps[i], COLOR_CYCLE[((i + m) % #COLOR_CYCLE) + 1], colors.black)
        drawBar(mon, 5, math.floor(h / 2), w - 8, ratio, colors.lime, colors.black, ("%d%%"):format(math.floor(ratio * 100)))
      end
    end
    if i == 2 and #speakers > 0 then queueTouchPling() end
    sleep(0.28)
  end

  if #speakers > 0 then
    queuePartyFanfare()
  end
end

local function tickScheduler(snap)
  if state.lastMinute == nil then
    state.lastMinute = snap.minute
    state.lastSecond = snap.second
    return
  end

  if snap.second ~= state.lastSecond then
    if state.partyUntil > os.clock() and snap.second % 4 == 0 then
      enqueue({ kind = "note", inst = "bit", vol = 0.8, pitch = 10 + (snap.second % 12), delay = 0 })
    end
    state.lastSecond = snap.second
  end

  if snap.minute ~= state.lastMinute then
    if snap.hour == 13 and snap.minute == 37 then
      startParty("MARCEL MODE 13:37")
    end

    if snap.minute == 0 and CONFIG.hourChime then
      queueHourChime(snap.hour)
    elseif snap.minute % 15 == 0 and CONFIG.quarterChime then
      local quarter = math.floor(snap.minute / 15)
      queueQuarterChime(quarter)
    elseif CONFIG.minuteChime then
      queueMinuteChime()
    end

    state.lastMinute = snap.minute
  end
end

local function renderLoop()
  while true do
    state.frame = state.frame + 1
    local snap = getClockSnapshot()
    tickScheduler(snap)

    if #monitors == 0 then
      term.setBackgroundColor(colors.black)
      term.clear()
      term.setCursorPos(1, 1)
      term.setTextColor(colors.red)
      print("Keine Monitore gefunden.")
      print("Bitte 2 Monitore und Speaker ans Modem-Netz haengen.")
      sleep(2)
    elseif #monitors == 1 then
      renderSingle(monitors[1], snap)
      sleep(CONFIG.frameDelay)
    else
      renderLeft(monitors[1], snap)
      renderRight(monitors[2], snap)
      sleep(CONFIG.frameDelay)
    end
  end
end

local function soundLoop()
  while true do
    if #soundQueue == 0 then
      sleep(0.05)
    else
      local event = table.remove(soundQueue, 1)
      if event.delay and event.delay > 0 then sleep(event.delay) end
      if event.kind == "note" then
        playNoteAll(event.inst, event.vol, event.pitch)
      elseif event.kind == "sound" then
        playSoundAll(event.name, event.vol, event.pitch)
      end
      sleep(0.02)
    end
  end
end

local function cleanup()
  for i = 1, #speakers do
    pcall(speakers[i].obj.stop)
  end
  for i = 1, #monitors do
    local monData = monitors[i]
    local mon = monData.obj
    local _, h = refreshMonitorGeometry(monData)
    clear(mon, colors.black)
    centerWrite(mon, math.floor(h / 2), "ChronoShow beendet", colors.white, colors.black)
  end
end

local function touchLoop()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "monitor_touch" then
      queueTouchPling()
      local now = os.clock()
      state.statusMessage = "Touch auf " .. tostring(a)
      state.statusUntil = now + 3
      state.touchTimes[#state.touchTimes + 1] = now
      while #state.touchTimes > 0 and now - state.touchTimes[1] > CONFIG.touchWindow do
        table.remove(state.touchTimes, 1)
      end
      if #state.touchTimes >= CONFIG.touchPartyCount then
        state.touchTimes = {}
        startParty("PARTY MODE AKTIV")
      end
    elseif ev == "monitor_resize" or ev == "peripheral" or ev == "peripheral_detach" then
      rescanPeripherals()
    elseif ev == "terminate" then
      cleanup()
      error("Terminated", 0)
    end
  end
end

math.randomseed(os.epoch("utc") or os.time())
rescanPeripherals()
bootSequence()
parallel.waitForAny(renderLoop, soundLoop, touchLoop)
