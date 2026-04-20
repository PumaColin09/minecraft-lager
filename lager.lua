local args = { ... }

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function safeWrap(name)
  if not name then return nil end
  local ok, obj = pcall(peripheral.wrap, name)
  if ok then return obj end
  return nil
end

local function namesByType(t)
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == t then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

local function sizeOf(mon)
  if not mon then return 0, 0 end
  local ok, w, h = pcall(mon.getSize)
  if not ok then return 0, 0 end
  return tonumber(w) or 0, tonumber(h) or 0
end

local function setScale(mon, s)
  if not mon then return 0, 0 end
  pcall(mon.setTextScale, s)
  return sizeOf(mon)
end

local function discoverMonitors()
  local mons = {}
  for _, name in ipairs(namesByType("monitor")) do
    local mon = safeWrap(name)
    if mon then
      local w, h = setScale(mon, 0.5)
      mons[#mons + 1] = { name = name, mon = mon, area = w * h, w = w, h = h }
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
  return { left = sides[1], center = center, right = sides[2] }
end

local display = pickDisplays()
if not display or not display.left or not display.center or not display.right then
  error("Ich brauche 3 Monitore. Start: chrono_show_triple_party_fix2 <links> <mitte> <rechts>")
end
if not display.left.mon or not display.center.mon or not display.right.mon then
  error("Mindestens ein Monitorname ist ungueltig.")
end

local leftMon, centerMon, rightMon = display.left.mon, display.center.mon, display.right.mon
local leftName, centerName, rightName = display.left.name, display.center.name, display.right.name

local speakers = {}
for _, name in ipairs(namesByType("speaker")) do
  local sp = safeWrap(name)
  if sp then speakers[#speakers + 1] = sp end
end

local function nowTable()
  local ok, t = pcall(function() return os.date("*t") end)
  if ok and type(t) == "table" and t.hour ~= nil then return t end
  local ingame = textutils.formatTime(os.time(), true) or "00:00"
  local hh, mm = ingame:match("^(%d+):(%d+)")
  return { hour = tonumber(hh) or 0, min = tonumber(mm) or 0, sec = 0 }
end

local function rect(mon, x1, y1, x2, y2, bg)
  local w, h = sizeOf(mon)
  if w < 1 or h < 1 then return end
  x1 = clamp(math.floor(x1), 1, w)
  x2 = clamp(math.floor(x2), 1, w)
  y1 = clamp(math.floor(y1), 1, h)
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
  mon.setBackgroundColor(bg or colors.black)
  mon.setTextColor(colors.white)
  mon.clear()
  mon.setCursorPos(1, 1)
end

local function writeAt(mon, x, y, txt, fg, bg)
  local w, h = sizeOf(mon)
  if y < 1 or y > h then return end
  txt = tostring(txt or "")
  x = math.floor(x)
  if x < 1 then
    txt = txt:sub(2 - x)
    x = 1
  end
  if x > w or txt == "" then return end
  if x + #txt - 1 > w then txt = txt:sub(1, w - x + 1) end
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

local function frameBox(mon, outer, inner)
  local w, h = sizeOf(mon)
  if w < 2 or h < 2 then return end
  rect(mon, 1, 1, w, 1, outer)
  rect(mon, 1, h, w, h, outer)
  rect(mon, 1, 1, 1, h, outer)
  rect(mon, w, 1, w, h, outer)
  if inner and w >= 4 and h >= 4 then
    rect(mon, 2, 2, w - 1, 2, inner)
    rect(mon, 2, h - 1, w - 1, h - 1, inner)
    rect(mon, 2, 2, 2, h - 1, inner)
    rect(mon, w - 1, 2, w - 1, h - 1, inner)
  end
end

local function progress(mon, y, ratio, onCol, offCol)
  local w = sizeOf(mon)
  if w < 4 then return end
  rect(mon, 3, y, w - 2, y, offCol)
  local fill = math.floor((w - 4) * clamp(ratio, 0, 1))
  if fill > 0 then rect(mon, 3, y, 2 + fill, y, onCol) end
end

local function spectrum(mon, frame, baseY, height, palette)
  local w = sizeOf(mon)
  local bars = math.max(6, math.floor((w - 4) / 2))
  local x = 3
  for i = 1, bars do
    local lvl = math.floor((math.sin((frame + i) * 0.55) + math.sin((frame + i * 2) * 0.21) + 2) * 0.25 * height)
    local col = palette[((i + frame) % #palette) + 1]
    if lvl > 0 then rect(mon, x, baseY - lvl + 1, x, baseY, col) end
    x = x + 2
    if x > w - 2 then break end
  end
end

local function movingBorder(mon, frame, palette)
  local w, h = sizeOf(mon)
  for x = 1, w do
    local col = palette[((x + frame) % #palette) + 1]
    rect(mon, x, 1, x, 1, col)
    rect(mon, x, h, x, h, col)
  end
  for y = 1, h do
    local col = palette[((y + frame) % #palette) + 1]
    rect(mon, 1, y, 1, y, col)
    rect(mon, w, y, w, y, col)
  end
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
  local t = math.max(1, math.floor(math.min(w, h) / 6))
  local midY = y + math.floor((h - t) / 2)
  local bottomY = y + h - t
  local rightX = x + w - t
  local segs = SEG[ch] or {}

  local function segment(name, sx1, sy1, sx2, sy2)
    rect(mon, sx1, sy1, sx2, sy2, segs[name] and onCol or offCol)
  end

  segment("a", x + t, y, x + w - t - 1, y + t - 1)
  segment("g", x + t, midY, x + w - t - 1, midY + t - 1)
  segment("d", x + t, bottomY, x + w - t - 1, y + h - 1)
  segment("f", x, y + t, x + t - 1, midY - 1)
  segment("b", rightX, y + t, x + w - 1, midY - 1)
  segment("e", x, midY + t, x + t - 1, bottomY - 1)
  segment("c", rightX, midY + t, x + w - 1, bottomY - 1)
end

local function drawPair(mon, pair, onCol, offCol, title, footer, secRatio, frame, pulseCol)
  setScale(mon, 0.5)
  clear(mon, colors.black)
  local w, h = sizeOf(mon)
  frameBox(mon, onCol, colors.gray)
  movingBorder(mon, frame, { onCol, pulseCol or colors.white, colors.black, offCol })
  centerText(mon, 2, title, colors.white, colors.black)

  local gap = math.max(2, math.floor(w * 0.04))
  local digitW = math.floor((w - 6 - gap) / 2)
  local digitH = h - 10
  local y = 4
  local x1 = 3
  local x2 = x1 + digitW + gap
  drawDigit(mon, x1, y, digitW, digitH, pair:sub(1, 1), onCol, offCol)
  drawDigit(mon, x2, y, digitW, digitH, pair:sub(2, 2), onCol, offCol)
  centerText(mon, h - 3, footer, colors.white, colors.black)
  progress(mon, h - 2, secRatio, pulseCol or onCol, colors.gray)
end

local function drawNormalCenter(dt, frame)
  setScale(centerMon, 0.5)
  clear(centerMon, colors.black)
  local w, h = sizeOf(centerMon)
  frameBox(centerMon, colors.white, colors.gray)
  movingBorder(centerMon, frame, { colors.cyan, colors.lightBlue, colors.black, colors.gray })

  local pulse = (dt.sec % 2 == 0) and colors.lime or colors.green
  centerText(centerMon, 2, "ME SYSTEM", colors.white, colors.black)
  centerText(centerMon, 4, "Applied Energistics 2", colors.lightBlue, colors.black)
  centerText(centerMon, 6, string.format("%02d:%02d:%02d", dt.hour, dt.min, dt.sec), colors.yellow, colors.black)
  centerText(centerMon, 8, "COLIN x MARCEL", colors.cyan, colors.black)
  centerText(centerMon, h - 4, "Touch / P = Party", colors.orange, colors.black)
  centerText(centerMon, h - 3, "3x Mitte / L = Legend", colors.pink, colors.black)
  centerText(centerMon, h - 2, "ME Hall Display", pulse, colors.black)
  spectrum(centerMon, frame, h - 6, math.max(3, math.floor(h / 3)), { colors.cyan, colors.lightBlue, colors.lime, colors.orange, colors.magenta })
end

local function drawPartySide(mon, pair, title, footer, palette, frame, legend)
  local onCol = palette[((math.floor(frame / 2)) % #palette) + 1]
  local pulse = palette[((math.floor(frame / 2) + 2) % #palette) + 1]
  local offCol = legend and colors.gray or colors.lightGray
  drawPair(mon, pair, onCol, offCol, title, footer, (frame % 60) / 59, frame, pulse)
  local w, h = sizeOf(mon)
  local stripeCol = palette[((math.floor(frame / 3) + 4) % #palette) + 1]
  rect(mon, 3, 4, w - 2, 4, stripeCol)
  rect(mon, 3, h - 4, w - 2, h - 4, stripeCol)
  spectrum(mon, frame, h - 5, math.max(2, math.floor(h / 5)), palette)
end

local function drawPartyCenter(frame, legend)
  setScale(centerMon, 0.5)
  clear(centerMon, colors.black)
  local w, h = sizeOf(centerMon)
  local palette = legend
      and { colors.magenta, colors.purple, colors.red, colors.orange, colors.yellow }
      or { colors.lime, colors.cyan, colors.lightBlue, colors.pink, colors.orange }

  frameBox(centerMon, colors.white, palette[((math.floor(frame / 2)) % #palette) + 1])
  movingBorder(centerMon, frame, palette)

  rect(centerMon, 3, 3, w - 2, h - 2, colors.black)
  centerText(centerMon, 2, "ME SYSTEM", colors.white, colors.black)
  centerText(centerMon, 4, "Applied Energistics 2", colors.lightBlue, colors.black)
  centerText(centerMon, 7, legend and "LEGEND MODE" or "PARTY MODE", palette[((math.floor(frame / 2)) % #palette) + 1], colors.black)
  centerText(centerMon, 9, "COLIN x MARCEL", colors.yellow, colors.black)
  centerText(centerMon, h - 4, legend and "MAXIMUM RAVE" or "DISCO AKTIV", colors.white, colors.black)
  centerText(centerMon, h - 3, "P = Party   L = Legend", colors.lightGray, colors.black)
  centerText(centerMon, h - 2, "Touch = auch okay", colors.gray, colors.black)
  spectrum(centerMon, frame * 2, h - 6, math.max(4, math.floor(h / 2.8)), palette)
end

local function groupSpeakerIndexes(group)
  local idx = {}
  for i = 1, #speakers do
    local ok = false
    if group == "all" then ok = true
    elseif group == "a" then ok = ((i - 1) % 3) == 0
    elseif group == "b" then ok = ((i - 1) % 3) == 1
    elseif group == "c" then ok = ((i - 1) % 3) == 2 end
    if ok then idx[#idx + 1] = i end
  end
  return idx
end

local speakerGroups = {
  all = groupSpeakerIndexes("all"),
  a = groupSpeakerIndexes("a"),
  b = groupSpeakerIndexes("b"),
  c = groupSpeakerIndexes("c"),
}

local function playGroup(group, instrument, volume, pitch)
  local list = speakerGroups[group] or speakerGroups.all
  for _, i in ipairs(list) do
    local sp = speakers[i]
    pcall(function() sp.playNote(instrument, volume, clamp(pitch, 0, 24)) end)
  end
end

local noteQueue = {}
local function enqueue(delay, group, instrument, volume, pitch)
  noteQueue[#noteQueue + 1] = {
    t = os.clock() + (delay or 0),
    group = group,
    instrument = instrument,
    volume = volume,
    pitch = pitch,
  }
end

local function sortQueue()
  table.sort(noteQueue, function(a, b) return a.t < b.t end)
end

local function processNotes()
  local now = os.clock()
  local i = 1
  while i <= #noteQueue do
    local n = noteQueue[i]
    if n.t <= now then
      playGroup(n.group, n.instrument, n.volume, n.pitch)
      table.remove(noteQueue, i)
    else
      i = i + 1
    end
  end
end

local function queueIntro(legend)
  local seq = legend and { 8, 12, 15, 19, 22 } or { 7, 10, 14, 17, 19 }
  for i, p in ipairs(seq) do
    enqueue((i - 1) * 0.06, "all", legend and "bell" or "chime", legend and 3 or 2, p)
  end
  sortQueue()
end

local function queueMinuteChime(hour)
  local base = ({ 8, 12, 15, 19 })[(hour % 4) + 1]
  enqueue(0.00, "all", "bell", 2, base)
  enqueue(0.12, "all", "chime", 2, base + 4)
  enqueue(0.24, "all", "pling", 1, base + 7)
  sortQueue()
end

local partyProgression = { 8, 13, 10, 15 }
local legendProgression = { 8, 15, 17, 13 }
local partyLead = { 15, 17, 19, 17, 15, 12, 10, 12, 15, 17, 19, 22, 19, 17, 15, 12 }
local legendLead = { 15, 19, 22, 19, 17, 22, 24, 22, 19, 17, 15, 19, 22, 24, 22, 19 }
local beatStep = 0

local function beatTick(legend)
  if #speakers == 0 then return end
  beatStep = beatStep + 1
  local step = ((beatStep - 1) % 16) + 1
  local bar = math.floor((beatStep - 1) / 16) % 4 + 1
  local root = (legend and legendProgression or partyProgression)[bar]
  local lead = (legend and legendLead or partyLead)[step]

  if step == 1 or step == 5 or step == 9 or step == 13 then
    playGroup("all", "basedrum", legend and 3 or 2, 0)
  end
  if step == 5 or step == 13 then
    playGroup("all", "snare", 2, 0)
  end
  if step % 2 == 0 then
    playGroup(step % 4 == 0 and "b" or "a", "hat", 1, 0)
  end
  if step == 12 or step == 16 then
    playGroup("c", "hat", 2, 0)
  end

  if step == 1 or step == 3 or step == 7 or step == 9 or step == 11 or step == 15 then
    playGroup("c", "bass", 2, root)
  end

  if step == 1 or step == 5 or step == 9 or step == 13 then
    playGroup("a", legend and "bit" or "pling", 2, root + 12)
    playGroup("b", legend and "bit" or "flute", 2, root + 16)
    playGroup("c", legend and "bell" or "chime", 1, root + 19)
  end

  if step == 3 or step == 7 or step == 11 or step == 15 then
    playGroup(step == 7 or step == 15 and "all" or "b", legend and "bell" or "pling", legend and 2 or 1, lead)
  elseif step == 4 or step == 8 or step == 12 or step == 16 then
    playGroup(step % 8 == 0 and "a" or "b", legend and "flute" or "guitar", 1, lead - 12)
  end
end

local function splash()
  for _, mon in ipairs({ leftMon, centerMon, rightMon }) do
    setScale(mon, 0.5)
    clear(mon, colors.black)
    frameBox(mon, colors.white, colors.gray)
    local _, h = sizeOf(mon)
    centerText(mon, math.max(2, math.floor(h / 2) - 1), "ME SYSTEM", colors.cyan, colors.black)
    centerText(mon, math.max(3, math.floor(h / 2)), "Applied Energistics 2", colors.white, colors.black)
    centerText(mon, math.max(4, math.floor(h / 2) + 1), "startet...", colors.lightGray, colors.black)
  end
  enqueue(0.00, "all", "pling", 2, 8)
  enqueue(0.08, "all", "chime", 2, 12)
  enqueue(0.16, "all", "bell", 2, 17)
  sortQueue()
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Triple ME Clock laeuft")
print("Links : " .. leftName)
print("Mitte : " .. centerName)
print("Rechts: " .. rightName)
print("Speaker: " .. #speakers)
print("Touch / P = Party")
print("3x Mitte / L = Legend")
print("Beenden mit Ctrl+T")

splash()

local frame = 0
local partyUntil = 0
local legendUntil = 0
local lastMinuteKey = nil
local centerTouches = {}

local function pushCenterTouch(ts)
  centerTouches[#centerTouches + 1] = ts
  while #centerTouches > 5 do table.remove(centerTouches, 1) end
  while #centerTouches > 0 and ts - centerTouches[1] > 1.5 do table.remove(centerTouches, 1) end
end

local function isLegendTouchBurst()
  return #centerTouches >= 3
end

local function startParty(seconds, legend)
  local now = os.clock()
  if legend then
    legendUntil = math.max(legendUntil, now + seconds)
    partyUntil = math.max(partyUntil, now + seconds)
    queueIntro(true)
  else
    partyUntil = math.max(partyUntil, now + seconds)
    queueIntro(false)
  end
end

local function render()
  local dt = nowTable()
  local now = os.clock()
  local legend = legendUntil > now
  local party = partyUntil > now

  if party or legend then
    drawPartySide(leftMon, string.format("%02d", dt.hour), "COLIN", legend and "LEGEND" or "PARTY", { colors.cyan, colors.lightBlue, colors.white }, frame, legend)
    drawPartyCenter(frame, legend)
    drawPartySide(rightMon, string.format("%02d", dt.min), "MARCEL", legend and "RAVE" or "DROP", { colors.orange, colors.yellow, colors.white }, frame, legend)
  else
    drawPair(leftMon, string.format("%02d", dt.hour), colors.cyan, colors.gray, "COLIN", "STUNDEN", dt.sec / 59, frame, colors.lightBlue)
    drawNormalCenter(dt, frame)
    drawPair(rightMon, string.format("%02d", dt.min), colors.orange, colors.gray, "MARCEL", "MINUTEN", dt.sec / 59, frame, colors.yellow)
  end

  local minuteKey = string.format("%02d:%02d", dt.hour, dt.min)
  if dt.sec == 0 and minuteKey ~= lastMinuteKey then
    queueMinuteChime(dt.hour)
    lastMinuteKey = minuteKey
  elseif lastMinuteKey == nil then
    lastMinuteKey = minuteKey
  end

  if dt.hour == 13 and dt.min == 37 and dt.sec == 0 then
    startParty(45, true)
  end
end

local renderTimer = os.startTimer(0.10)
local beatTimer = os.startTimer(0.125)
local noteTimer = os.startTimer(0.05)

while true do
  local ev, a = os.pullEvent()
  if ev == "timer" then
    if a == renderTimer then
      frame = frame + 1
      processNotes()
      render()
      renderTimer = os.startTimer(0.10)
    elseif a == beatTimer then
      processNotes()
      local now = os.clock()
      if partyUntil > now or legendUntil > now then
        beatTick(legendUntil > now)
      end
      beatTimer = os.startTimer(0.125)
    elseif a == noteTimer then
      processNotes()
      noteTimer = os.startTimer(0.05)
    end
  elseif ev == "monitor_touch" then
    local monName = a
    local ts = os.clock()
    if monName == centerName then
      pushCenterTouch(ts)
      if isLegendTouchBurst() then
        centerTouches = {}
        startParty(75, true)
      else
        startParty(40, false)
      end
    elseif monName == leftName or monName == rightName then
      startParty(35, false)
    end
  elseif ev == "char" then
    local ch = tostring(a or ""):lower()
    if ch == "p" then
      startParty(40, false)
    elseif ch == "l" then
      startParty(75, true)
    end
  elseif ev == "terminate" then
    for _, mon in ipairs({ leftMon, centerMon, rightMon }) do
      setScale(mon, 0.5)
      clear(mon, colors.black)
      frameBox(mon, colors.gray, colors.lightGray)
      local _, h = sizeOf(mon)
      centerText(mon, math.max(2, math.floor(h / 2)), "Show beendet", colors.white, colors.black)
    end
    term.setCursorPos(1, 8)
    print("Show beendet.")
    break
  end
end
