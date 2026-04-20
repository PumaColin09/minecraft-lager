local args = { ... }

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function collectByType(t)
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == t then
      table.insert(out, name)
    end
  end
  table.sort(out)
  return out
end

local function safeWrap(name)
  if not name then return nil end
  local ok, obj = pcall(peripheral.wrap, name)
  if ok then return obj end
  return nil
end

local function sizeOf(mon)
  if not mon then return 0, 0 end
  local ok, w, h = pcall(mon.getSize)
  if not ok then return 0, 0 end
  return tonumber(w) or 0, tonumber(h) or 0
end

local function setScale(mon, scale)
  if not mon then return 0, 0 end
  pcall(mon.setTextScale, scale)
  return sizeOf(mon)
end

local function nowTable()
  local ok, t = pcall(function() return os.date("*t") end)
  if ok and type(t) == "table" then return t end
  local ingame = textutils.formatTime(os.time(), true) or "00:00"
  local hh, mm = ingame:match("^(%d+):(%d+)")
  return {
    hour = tonumber(hh) or 0,
    min = tonumber(mm) or 0,
    sec = 0,
    yday = os.day() or 0,
    day = os.day() or 0,
  }
end

local function discoverMonitors()
  local mons = {}
  for _, name in ipairs(collectByType("monitor")) do
    local mon = safeWrap(name)
    if mon then
      local w, h = setScale(mon, 0.5)
      mons[#mons + 1] = { name = name, mon = mon, w = w, h = h, area = w * h }
    end
  end
  table.sort(mons, function(a, b)
    if a.area == b.area then return a.name < b.name end
    return a.area > b.area
  end)
  return mons
end

local function pickDisplays()
  if #args >= 3 then
    return {
      left = { name = args[1], mon = safeWrap(args[1]) },
      center = { name = args[2], mon = safeWrap(args[2]) },
      right = { name = args[3], mon = safeWrap(args[3]) },
    }
  end

  local mons = discoverMonitors()
  if #mons < 3 then return nil end

  local chosen = { mons[1], mons[2], mons[3] }
  table.sort(chosen, function(a, b)
    if a.area == b.area then return a.name < b.name end
    return a.area < b.area
  end)

  local center = chosen[1]
  local sides = { chosen[2], chosen[3] }
  table.sort(sides, function(a, b) return a.name < b.name end)

  return {
    left = sides[1],
    center = center,
    right = sides[2],
  }
end

local setup = pickDisplays()
if not setup or not setup.left or not setup.center or not setup.right then
  error("Ich brauche 3 Monitore. Start: chrono_show_triple_party_plus <links> <mitte> <rechts>")
end
if not setup.left.mon or not setup.center.mon or not setup.right.mon then
  error("Mindestens ein Monitorname ist ungueltig.")
end

local leftMon = setup.left.mon
local centerMon = setup.center.mon
local rightMon = setup.right.mon
local leftName = setup.left.name
local centerName = setup.center.name
local rightName = setup.right.name

local speakers = {}
for _, name in ipairs(collectByType("speaker")) do
  local sp = safeWrap(name)
  if sp then
    speakers[#speakers + 1] = sp
  end
end

local function rect(mon, x1, y1, x2, y2, bg)
  local w, h = sizeOf(mon)
  if w < 1 or h < 1 then return end
  x1 = clamp(math.floor(x1), 1, w)
  y1 = clamp(math.floor(y1), 1, h)
  x2 = clamp(math.floor(x2), 1, w)
  y2 = clamp(math.floor(y2), 1, h)
  if x2 < x1 then x1, x2 = x2, x1 end
  if y2 < y1 then y1, y2 = y2, y1 end
  mon.setBackgroundColor(bg)
  local line = string.rep(" ", x2 - x1 + 1)
  for y = y1, y2 do
    mon.setCursorPos(x1, y)
    mon.write(line)
  end
end

local function clear(mon, bg)
  local w, h = sizeOf(mon)
  if w < 1 or h < 1 then return end
  mon.setBackgroundColor(bg)
  mon.setTextColor(colors.white)
  mon.clear()
  mon.setCursorPos(1, 1)
end

local function writeAt(mon, x, y, txt, fg, bg)
  local w, h = sizeOf(mon)
  if w < 1 or h < 1 or y < 1 or y > h then return end
  txt = tostring(txt or "")
  x = math.floor(x)
  if x > w then return end
  if x < 1 then
    txt = txt:sub(2 - x)
    x = 1
  end
  if txt == "" then return end
  if x + #txt - 1 > w then
    txt = txt:sub(1, w - x + 1)
  end
  if txt == "" then return end
  mon.setTextColor(fg or colors.white)
  mon.setBackgroundColor(bg or colors.black)
  mon.setCursorPos(x, y)
  mon.write(txt)
end

local function centerText(mon, y, txt, fg, bg)
  local w = sizeOf(mon)
  txt = tostring(txt or "")
  local x = math.floor((w - #txt) / 2) + 1
  writeAt(mon, x, y, txt, fg, bg)
end

local function marqueeText(txt, width, offset)
  local src = tostring(txt or "") .. "   *   "
  if #src < 1 then return string.rep(" ", width) end
  local pos = (offset % #src) + 1
  local out = src:sub(pos, pos + width - 1)
  while #out < width do out = out .. src end
  return out:sub(1, width)
end

local function drawBorder(mon, c1, c2)
  local w, h = sizeOf(mon)
  if w < 2 or h < 2 then return end
  rect(mon, 1, 1, w, 1, c1)
  rect(mon, 1, h, w, h, c1)
  rect(mon, 1, 1, 1, h, c1)
  rect(mon, w, 1, w, h, c1)
  if w >= 4 and h >= 4 then
    rect(mon, 2, 2, w - 1, 2, c2)
    rect(mon, 2, h - 1, w - 1, h - 1, c2)
    rect(mon, 2, 2, 2, h - 1, c2)
    rect(mon, w - 1, 2, w - 1, h - 1, c2)
  end
end

local function progressBar(mon, x, y, w, ratio, onCol, offCol)
  if w <= 0 then return end
  rect(mon, x, y, x + w - 1, y, offCol)
  local fill = math.floor(w * clamp(ratio, 0, 1))
  if fill > 0 then rect(mon, x, y, x + fill - 1, y, onCol) end
end

local SEG = {
  ["0"] = { a = true, b = true, c = true, d = true, e = true, f = true },
  ["1"] = { b = true, c = true },
  ["2"] = { a = true, b = true, g = true, e = true, d = true },
  ["3"] = { a = true, b = true, g = true, c = true, d = true },
  ["4"] = { f = true, g = true, b = true, c = true },
  ["5"] = { a = true, f = true, g = true, c = true, d = true },
  ["6"] = { a = true, f = true, g = true, e = true, c = true, d = true },
  ["7"] = { a = true, b = true, c = true },
  ["8"] = { a = true, b = true, c = true, d = true, e = true, f = true, g = true },
  ["9"] = { a = true, b = true, c = true, d = true, f = true, g = true },
}

local function drawDigit(mon, x, y, w, h, ch, onCol, offCol)
  if w < 5 or h < 7 then return end
  local t = math.max(1, math.floor(math.min(w, h) / 7))
  local midY = y + math.floor((h - t) / 2)
  local bottomY = y + h - t
  local rightX = x + w - t
  local segs = SEG[ch] or {}

  local function segment(name, sx1, sy1, sx2, sy2)
    local col = segs[name] and onCol or offCol
    rect(mon, sx1, sy1, sx2, sy2, col)
  end

  segment("a", x + t, y, x + w - t - 1, y + t - 1)
  segment("g", x + t, midY, x + w - t - 1, midY + t - 1)
  segment("d", x + t, bottomY, x + w - t - 1, y + h - 1)
  segment("f", x, y + t, x + t - 1, midY - 1)
  segment("b", rightX, y + t, x + w - 1, midY - 1)
  segment("e", x, midY + t, x + t - 1, bottomY - 1)
  segment("c", rightX, midY + t, x + w - 1, bottomY - 1)
end

local function drawTwoDigitsLarge(mon, value, onCol, offCol)
  local w, h = sizeOf(mon)
  if w < 12 or h < 10 then
    centerText(mon, math.floor(h / 2), value, onCol, colors.black)
    return
  end
  local marginX = 2
  local marginY = 3
  local gap = 2
  local digitW = math.floor((w - marginX * 2 - gap) / 2)
  local digitH = h - marginY * 2 - 5
  local y = marginY
  local x1 = marginX
  local x2 = x1 + digitW + gap
  drawDigit(mon, x1, y, digitW, digitH, value:sub(1, 1), onCol, offCol)
  drawDigit(mon, x2, y, digitW, digitH, value:sub(2, 2), onCol, offCol)
end

local function laserLines(mon, frame, cold)
  local w, h = sizeOf(mon)
  local base = cold and colors.blue or colors.purple
  rect(mon, 1, 1, w, h, colors.black)
  for i = 0, 7 do
    local y = ((frame * 2 + i * 3) % h) + 1
    local x1 = 2
    local x2 = w - 1
    local c = cold and ((i % 2 == 0) and colors.cyan or colors.lightBlue) or ((i % 2 == 0) and colors.magenta or colors.pink)
    rect(mon, x1, y, x2, y, c)
    if y + 1 <= h then rect(mon, x1 + 2, y + 1, x2 - 2, y + 1, base) end
  end
end

local rainbow = {
  colors.red, colors.orange, colors.yellow, colors.lime, colors.green,
  colors.cyan, colors.lightBlue, colors.blue, colors.purple, colors.magenta, colors.pink,
}

local function rainbowSweep(mon, frame)
  local w, h = sizeOf(mon)
  for y = 1, h do
    local c = rainbow[((frame + y) % #rainbow) + 1]
    rect(mon, 1, y, w, y, c)
  end
end

local function confetti(mon, frame)
  local w, h = sizeOf(mon)
  local count = math.max(8, math.floor((w * h) / 70))
  for i = 1, count do
    local x = ((frame * 7 + i * 11) % math.max(1, w - 2)) + 2
    local y = ((frame * 5 + i * 13) % math.max(1, h - 2)) + 2
    rect(mon, x, y, x, y, rainbow[((frame + i) % #rainbow) + 1])
  end
end

local function pulseBox(mon, y1, y2, c)
  local w = sizeOf(mon)
  rect(mon, 3, y1, w - 2, y2, c)
end

local function renderNormalLeft(mon, dt, frame)
  setScale(mon, 0.5)
  clear(mon, colors.black)
  laserLines(mon, frame, true)
  drawBorder(mon, colors.cyan, colors.lightBlue)
  local w, h = sizeOf(mon)
  rect(mon, 2, 2, w - 1, h - 1, colors.black)
  drawBorder(mon, colors.cyan, colors.gray)
  centerText(mon, 2, "COLIN // LASER", colors.white, colors.black)
  drawTwoDigitsLarge(mon, string.format("%02d", dt.hour), colors.lightBlue, colors.gray)
  centerText(mon, h - 4, "STUNDEN", colors.cyan, colors.black)
  centerText(mon, h - 3, textutils.formatTime(os.time(), true), colors.white, colors.black)
  progressBar(mon, 3, h - 2, math.max(1, w - 4), dt.sec / 59, colors.cyan, colors.gray)
end

local function renderNormalRight(mon, dt, frame)
  setScale(mon, 0.5)
  clear(mon, colors.black)
  rainbowSweep(mon, frame)
  drawBorder(mon, colors.magenta, colors.orange)
  local w, h = sizeOf(mon)
  rect(mon, 2, 2, w - 1, h - 1, colors.black)
  drawBorder(mon, colors.orange, colors.gray)
  centerText(mon, 2, "MARCEL // PARTY", colors.white, colors.black)
  drawTwoDigitsLarge(mon, string.format("%02d", dt.min), colors.orange, colors.gray)
  centerText(mon, h - 4, "MINUTEN", colors.orange, colors.black)
  centerText(mon, h - 3, string.format("SEK %02d", dt.sec), colors.white, colors.black)
  progressBar(mon, 3, h - 2, math.max(1, w - 4), dt.sec / 59, colors.orange, colors.gray)
end

local function renderNormalCenter(mon, dt, frame, uptimeSeconds)
  setScale(mon, 0.5)
  clear(mon, colors.black)
  drawBorder(mon, colors.white, colors.gray)
  local w, h = sizeOf(mon)

  local top = marqueeText("COLIN x MARCEL // TRIPLE CLOCK // TAP FOR PARTY", math.max(1, w - 2), frame)
  writeAt(mon, 2, 2, top, colors.yellow, colors.black)

  local secColor = (dt.sec % 2 == 0) and colors.lime or colors.green
  drawTwoDigitsLarge(mon, string.format("%02d", dt.sec), secColor, colors.gray)
  centerText(mon, math.max(4, h - 6), "SEKUNDEN", colors.lime, colors.black)

  local slogan
  if dt.hour == 13 and dt.min == 37 then
    slogan = "13:37 MODE AKTIV"
  elseif dt.sec % 10 < 5 then
    slogan = "COLIN LINKS // MARCEL RECHTS"
  else
    slogan = "7 TAPS MITTE = LEGEND MODE"
  end

  pulseBox(mon, h - 5, h - 4, (dt.sec % 2 == 0) and colors.blue or colors.purple)
  centerText(mon, h - 5, slogan, colors.white, (dt.sec % 2 == 0) and colors.blue or colors.purple)
  centerText(mon, h - 3, string.format("Uptime %s  |  Day %d", textutils.formatTime((uptimeSeconds / 50) % 24, true), os.day() or 0), colors.lightGray, colors.black)
  progressBar(mon, 3, h - 2, math.max(1, w - 4), dt.sec / 59, colors.magenta, colors.gray)
end

local function renderPartyLeft(mon, frame)
  setScale(mon, 0.5)
  clear(mon, colors.black)
  laserLines(mon, frame * 2, true)
  confetti(mon, frame)
  drawBorder(mon, colors.cyan, colors.white)
  local w, h = sizeOf(mon)
  local words = { "COLIN", "LASER", "BASS", "HYPE" }
  local word = words[((math.floor(frame / 4)) % #words) + 1]
  rect(mon, 4, math.floor(h / 2) - 2, w - 3, math.floor(h / 2) + 2, colors.cyan)
  centerText(mon, math.floor(h / 2), word, colors.white, colors.cyan)
  centerText(mon, 2, "LEFT DECK", colors.white, colors.black)
  centerText(mon, h - 1, "TOUCH = PARTY++", colors.white, colors.black)
end

local function renderPartyRight(mon, frame)
  setScale(mon, 0.5)
  clear(mon, colors.black)
  rainbowSweep(mon, frame * 2)
  confetti(mon, frame + 3)
  drawBorder(mon, colors.orange, colors.white)
  local w, h = sizeOf(mon)
  local words = { "MARCEL", "DISCO", "DROP", "BOOM" }
  local word = words[((math.floor(frame / 4)) % #words) + 1]
  rect(mon, 4, math.floor(h / 2) - 2, w - 3, math.floor(h / 2) + 2, colors.orange)
  centerText(mon, math.floor(h / 2), word, colors.white, colors.orange)
  centerText(mon, 2, "RIGHT DECK", colors.white, colors.black)
  centerText(mon, h - 1, "WIDE SOUND", colors.white, colors.black)
end

local function renderPartyCenter(mon, dt, frame, legend)
  setScale(mon, 0.5)
  clear(mon, colors.black)
  local w, h = sizeOf(mon)
  rainbowSweep(mon, frame)
  drawBorder(mon, colors.white, rainbow[((frame + 2) % #rainbow) + 1])

  local top = legend and "LEGEND MODE // COLIN x MARCEL // MAXIMUM" or "PARTY MODE // COLIN x MARCEL // TAP CENTER FAST"
  writeAt(mon, 2, 2, marqueeText(top, math.max(1, w - 2), frame * 2), colors.black, colors.yellow)

  local words = legend and { "LEGEND", "MAX", "B2B", "BOSS" } or { "PARTY", "LASER", "BEAT", "LOUD" }
  local word = words[((math.floor(frame / 3)) % #words) + 1]
  local boxCol = rainbow[((frame + 5) % #rainbow) + 1]
  rect(mon, 4, math.floor(h / 2) - 3, w - 3, math.floor(h / 2) + 3, boxCol)
  centerText(mon, math.floor(h / 2), word, colors.white, boxCol)

  centerText(mon, h - 5, string.format("%02d:%02d:%02d", dt.hour, dt.min, dt.sec), colors.white, colors.black)
  centerText(mon, h - 4, "COLIN LINKS // MARCEL RECHTS", colors.white, colors.black)
  centerText(mon, h - 3, legend and "14 SPEAKER RAVE" or "TRIPLE DISPLAY SHOW", colors.white, colors.black)
  progressBar(mon, 3, h - 2, math.max(1, w - 4), (frame % 32) / 31, colors.lime, colors.gray)
end

local function playGroup(inst, vol, pitch, offset)
  if #speakers == 0 then return end
  offset = offset or 0
  for i, sp in ipairs(speakers) do
    if ((i + offset) % 4) == 0 then
      pcall(function() sp.playNote(inst, vol, clamp(pitch, 0, 24)) end)
    end
  end
end

local function playEvery(inst, vol, pitch)
  for _, sp in ipairs(speakers) do
    pcall(function() sp.playNote(inst, vol, clamp(pitch, 0, 24)) end)
  end
end

local partyStep = 0
local partyPhase = {
  roots = { 12, 9, 5, 7 },
  bassline = { 0, 0, 7, 0, 0, 0, 7, 10, 0, 0, 7, 0, 0, 0, 7, 10 },
  melody = { 12, 14, 15, 14, 12, 10, 9, 10, 12, 14, 17, 14, 12, 10, 9, 7 },
}
local legendPhase = {
  roots = { 12, 12, 15, 17 },
  bassline = { 0, 0, 7, 10, 0, 0, 7, 10, 0, 0, 7, 12, 0, 0, 7, 12 },
  melody = { 17, 19, 20, 19, 17, 15, 14, 15, 17, 19, 22, 19, 17, 15, 14, 12 },
}

local function playPartyMusic(legend)
  if #speakers == 0 then return end
  partyStep = partyStep + 1
  local seq = legend and legendPhase or partyPhase
  local step = ((partyStep - 1) % 16) + 1
  local bar = math.floor((partyStep - 1) / 16) % 4 + 1
  local root = seq.roots[bar]
  local bass = root + seq.bassline[step] - 12
  local lead = seq.melody[step]
  local chord = { root, root + 4, root + 7 }

  if step == 1 or step == 9 then
    playEvery("basedrum", legend and 3 or 2, 0)
  end
  if step == 5 or step == 13 then
    playGroup("snare", legend and 3 or 2, 0, 1)
    playGroup("bass", 2, root - 12, 2)
  end
  if step % 2 == 0 then
    playGroup("hat", legend and 3 or 2, 0, 2)
  end
  if step == 3 or step == 7 or step == 11 or step == 15 then
    playGroup("bass", 2, bass, 0)
  end

  playGroup("pling", legend and 3 or 2, chord[((step - 1) % 3) + 1], 1)
  if step % 4 == 1 then
    playGroup(legend and "bell" or "chime", legend and 3 or 2, lead, 3)
  elseif step % 4 == 3 then
    playGroup(legend and "bit" or "flute", 2, lead - 12, 3)
  end
end

local function playIntro(legend)
  local rise = legend and { 7, 10, 12, 15, 19, 22 } or { 5, 7, 10, 12, 14, 17 }
  for i, p in ipairs(rise) do
    for s = 1, #speakers do
      local sp = speakers[s]
      local inst = (i < #rise) and ((s % 2 == 0) and "pling" or "chime") or "bell"
      pcall(function() sp.playNote(inst, legend and 3 or 2, p) end)
    end
    sleep(0.05)
  end
end

local function minuteChime(dt)
  if #speakers == 0 then return end
  local root = ({ 12, 14, 17, 19 })[(dt.hour % 4) + 1]
  playEvery("bell", 2, root)
  sleep(0.05)
  playEvery("chime", 2, root + 7)
  if dt.min == 0 then
    sleep(0.06)
    playEvery("bell", 3, root + 12)
  end
end

local function bootSplash()
  for _, mon in ipairs({ leftMon, centerMon, rightMon }) do
    setScale(mon, 0.5)
    clear(mon, colors.black)
    drawBorder(mon, colors.lightBlue, colors.white)
    local _, h = sizeOf(mon)
    centerText(mon, math.max(2, math.floor(h / 2) - 1), "COLIN x MARCEL", colors.cyan, colors.black)
    centerText(mon, math.max(3, math.floor(h / 2)), "TRIPLE PARTY CLOCK", colors.white, colors.black)
    centerText(mon, math.max(4, math.floor(h / 2) + 1), "BOOTING...", colors.lightGray, colors.black)
  end
  if #speakers > 0 then
    playEvery("pling", 2, 7)
    sleep(0.05)
    playEvery("chime", 2, 12)
    sleep(0.05)
    playEvery("bell", 2, 19)
  end
end

bootSplash()

term.setTextColor(colors.white)
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
print("Triple Party Clock laeuft")
print("Links : " .. tostring(leftName))
print("Mitte : " .. tostring(centerName))
print("Rechts: " .. tostring(rightName))
print("Speaker: " .. tostring(#speakers))
print("Touch = Party Mode")
print("7 schnelle Touches in der Mitte = Legend Mode")
print("Beenden mit Ctrl+T")

local partyUntil = 0
local legendUntil = 0
local frame = 0
local lastMinuteKey = nil
local last1337Key = nil
local touchTimes = {}
local bootClock = os.clock()

local function pushTouch(ts)
  touchTimes[#touchTimes + 1] = ts
  while #touchTimes > 10 do table.remove(touchTimes, 1) end
  while #touchTimes > 0 and ts - touchTimes[1] > 2.5 do table.remove(touchTimes, 1) end
end

local function render()
  local dt = nowTable()
  local now = os.clock()
  local uptimeSeconds = math.floor((now - bootClock) * 20)
  local mode = "normal"
  if legendUntil > now then
    mode = "legend"
  elseif partyUntil > now then
    mode = "party"
  end

  if mode == "normal" then
    renderNormalLeft(leftMon, dt, frame)
    renderNormalCenter(centerMon, dt, frame, uptimeSeconds)
    renderNormalRight(rightMon, dt, frame)
  else
    renderPartyLeft(leftMon, frame)
    renderPartyCenter(centerMon, dt, frame, mode == "legend")
    renderPartyRight(rightMon, frame + 2)
  end

  local minuteKey = string.format("%d-%d-%d", dt.yday or 0, dt.hour, dt.min)
  if minuteKey ~= lastMinuteKey then
    minuteChime(dt)
    lastMinuteKey = minuteKey
  end

  local key1337 = string.format("%d-%d", dt.yday or 0, dt.hour * 60 + dt.min)
  if dt.hour == 13 and dt.min == 37 and key1337 ~= last1337Key then
    partyUntil = math.max(partyUntil, now + 40)
    playIntro(true)
    last1337Key = key1337
  end
end

local timer = os.startTimer(0.10)
while true do
  local ev, a = os.pullEvent()
  if ev == "timer" and a == timer then
    frame = frame + 1
    render()
    local modeLegend = legendUntil > os.clock()
    local modeParty = partyUntil > os.clock()
    if modeLegend or modeParty then
      if frame % 2 == 0 then playPartyMusic(modeLegend) end
      timer = os.startTimer(0.10)
    else
      timer = os.startTimer(0.20)
    end
  elseif ev == "monitor_touch" then
    local name = a
    local ts = os.clock()
    if name == centerName then
      pushTouch(ts)
      if #touchTimes >= 7 then
        legendUntil = ts + 75
        partyUntil = legendUntil
        touchTimes = {}
        playIntro(true)
      else
        partyUntil = math.max(partyUntil, ts + 45)
        playIntro(false)
      end
    elseif name == leftName or name == rightName then
      partyUntil = math.max(partyUntil, ts + 35)
      playIntro(false)
    end
  elseif ev == "terminate" then
    for _, mon in ipairs({ leftMon, centerMon, rightMon }) do
      setScale(mon, 0.5)
      clear(mon, colors.black)
      drawBorder(mon, colors.gray, colors.lightGray)
      local _, h = sizeOf(mon)
      centerText(mon, math.max(2, math.floor(h / 2)), "SHOW BEENDET", colors.white, colors.black)
    end
    term.setCursorPos(1, 8)
    print("Show beendet.")
    return
  end
end
