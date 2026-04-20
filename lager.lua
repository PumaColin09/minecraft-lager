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

local function collectNamesByType(t)
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == t then
      out[#out + 1] = name
    end
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

local function setScale(mon, scale)
  if not mon then return 0, 0 end
  pcall(mon.setTextScale, scale)
  return sizeOf(mon)
end

local function discoverMonitors()
  local mons = {}
  for _, name in ipairs(collectNamesByType("monitor")) do
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

  return {
    left = sides[1],
    center = center,
    right = sides[2],
  }
end

local display = pickDisplays()
if not display or not display.left or not display.center or not display.right then
  error("Ich brauche 3 Monitore. Start: chrono_show_triple_megafix <links> <mitte> <rechts>")
end
if not display.left.mon or not display.center.mon or not display.right.mon then
  error("Mindestens ein Monitorname ist ungueltig.")
end

local leftMon = display.left.mon
local centerMon = display.center.mon
local rightMon = display.right.mon
local leftName = display.left.name
local centerName = display.center.name
local rightName = display.right.name

local speakers = {}
for _, name in ipairs(collectNamesByType("speaker")) do
  local sp = safeWrap(name)
  if sp then speakers[#speakers + 1] = sp end
end

local function nowTable()
  local ok, t = pcall(function() return os.date("*t") end)
  if ok and type(t) == "table" then return t end
  local ingame = textutils.formatTime(os.time(), true) or "00:00"
  local hh, mm = ingame:match("^(%d+):(%d+)")
  return { hour = tonumber(hh) or 0, min = tonumber(mm) or 0, sec = 0 }
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
  mon.setBackgroundColor(bg)
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

local function frameBox(mon, outer, inner)
  local w, h = sizeOf(mon)
  if w < 2 or h < 2 then return end
  rect(mon, 1, 1, w, 1, outer)
  rect(mon, 1, h, w, h, outer)
  rect(mon, 1, 1, 1, h, outer)
  rect(mon, w, 1, w, h, outer)
  if w >= 4 and h >= 4 then
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
  if fill > 0 then
    rect(mon, 3, y, 2 + fill, y, onCol)
  end
end

local function stripeBackground(mon, frame, c1, c2, c3)
  local w, h = sizeOf(mon)
  rect(mon, 1, 1, w, h, colors.black)
  for y = 2, h - 1 do
    local mod = (y + frame) % 6
    local col = (mod == 0 or mod == 1) and c1 or ((mod == 2 or mod == 3) and c2 or c3)
    rect(mon, 2, y, w - 1, y, col)
  end
end

local function equalizer(mon, frame, baseY, height, palette)
  local w, _ = sizeOf(mon)
  local bars = math.max(6, math.floor((w - 4) / 3))
  local gap = math.max(0, math.floor((w - 4 - bars) / math.max(1, bars - 1)))
  local x = 3
  for i = 1, bars do
    local lvl = math.floor((math.sin((frame + i) * 0.55) + 1) * 0.5 * height)
    local col = palette[((i + frame) % #palette) + 1]
    if lvl > 0 then
      rect(mon, x, baseY - lvl + 1, x, baseY, col)
    end
    x = x + 1 + gap
    if x > w - 2 then break end
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

local function drawPair(mon, pair, onCol, offCol, title, foot, secRatio)
  setScale(mon, 0.5)
  clear(mon, colors.black)
  local w, h = sizeOf(mon)
  frameBox(mon, onCol, colors.gray)
  rect(mon, 3, 3, w - 2, h - 3, colors.black)
  frameBox(mon, onCol, colors.gray)
  centerText(mon, 2, title, colors.white, colors.black)
  local gap = 3
  local digitW = math.floor((w - 6 - gap) / 2)
  local digitH = h - 9
  local y = 4
  local x1 = 3
  local x2 = x1 + digitW + gap
  drawDigit(mon, x1, y, digitW, digitH, pair:sub(1, 1), onCol, offCol)
  drawDigit(mon, x2, y, digitW, digitH, pair:sub(2, 2), onCol, offCol)
  centerText(mon, h - 3, foot, colors.white, colors.black)
  progress(mon, h - 2, secRatio, onCol, colors.gray)
end

local partyWordsLeft = { "COLIN", "LASER", "HYPE", "BASS", "CYAN" }
local partyWordsRight = { "MARCEL", "DROP", "RAVE", "BOOM", "GOLD" }
local partyWordsCenter = { "PARTY", "LOUD", "DROP", "HYPE", "WOW" }
local legendWordsCenter = { "LEGEND", "MAX", "B2B", "ULTRA", "BOSS" }
local rainbow = { colors.red, colors.orange, colors.yellow, colors.lime, colors.green, colors.cyan, colors.lightBlue, colors.blue, colors.purple, colors.magenta, colors.pink }

local function drawPartyWord(mon, word, main, accent, frame)
  setScale(mon, 1.5)
  clear(mon, colors.black)
  local w, h = sizeOf(mon)
  rect(mon, 1, 1, w, h, colors.black)
  for y = 2, h - 1 do
    local col = ((y + frame) % 2 == 0) and main or accent
    rect(mon, 2, y, w - 1, y, col)
  end
  rect(mon, 3, 3, w - 2, h - 2, colors.black)
  frameBox(mon, accent, colors.white)
  local mid = math.floor(h / 2)
  centerText(mon, mid - 1, word, colors.white, colors.black)
  if h >= 6 then
    centerText(mon, h - 2, "PARTY!", accent, colors.black)
  end
end

local function renderNormalLeft(dt, frame)
  local foot = (frame % 20 < 10) and "COLIN" or "STUNDEN"
  drawPair(leftMon, string.format("%02d", dt.hour), colors.cyan, colors.gray, "COLIN", foot, dt.sec / 59)
  local w = sizeOf(leftMon)
  local tickX = 3 + ((frame * 2) % math.max(1, w - 6))
  rect(leftMon, tickX, 3, math.min(tickX + 1, w - 2), 3, colors.lightBlue)
end

local function renderNormalRight(dt, frame)
  local foot = (frame % 20 < 10) and "MARCEL" or "MINUTEN"
  drawPair(rightMon, string.format("%02d", dt.min), colors.orange, colors.gray, "MARCEL", foot, dt.sec / 59)
  local w = sizeOf(rightMon)
  local tickX = 3 + ((frame * 2 + 8) % math.max(1, w - 6))
  rect(rightMon, tickX, 3, math.min(tickX + 1, w - 2), 3, colors.yellow)
end

local function renderNormalCenter(dt, frame)
  setScale(centerMon, 1)
  clear(centerMon, colors.black)
  local w, h = sizeOf(centerMon)
  frameBox(centerMon, colors.white, colors.gray)
  local pulse = (dt.sec % 2 == 0) and colors.lime or colors.green
  rect(centerMon, 3, 3, w - 2, h - 2, colors.black)

  if h >= 7 then
    centerText(centerMon, 2, "ME SYSTEM", colors.white, colors.black)
    local dotsCol = (dt.sec % 2 == 0) and colors.cyan or colors.orange
    centerText(centerMon, math.floor(h / 2) - 1, ":", dotsCol, colors.black)
    centerText(centerMon, math.floor(h / 2), "Applied Energistics 2", colors.lightBlue, colors.black)
    centerText(centerMon, math.floor(h / 2) + 1, string.format("SEK %02d", dt.sec), pulse, colors.black)
    centerText(centerMon, math.floor(h / 2) + 2, "Touch oder P = Party", colors.yellow, colors.black)
    centerText(centerMon, h - 1, "L oder 3x Mitte = Legend", colors.lightGray, colors.black)
  else
    centerText(centerMon, 2, "ME SYSTEM", colors.white, colors.black)
    centerText(centerMon, math.max(3, math.floor(h / 2) - 1), "Applied Energistics", colors.lightBlue, colors.black)
    centerText(centerMon, math.max(4, math.floor(h / 2) + 1), string.format("SEK %02d", dt.sec), pulse, colors.black)
    centerText(centerMon, h, "P = Party", colors.yellow, colors.black)
  end

  equalizer(centerMon, frame, h - 2, math.max(2, math.floor(h / 3)), { colors.cyan, colors.lightBlue, colors.lime, colors.orange })
end

local function renderParty(frame, legend)
  local leftWord = partyWordsLeft[(math.floor(frame / 4) % #partyWordsLeft) + 1]
  local rightWord = partyWordsRight[(math.floor(frame / 4) % #partyWordsRight) + 1]
  local centerWord = (legend and legendWordsCenter or partyWordsCenter)[(math.floor(frame / 3) % #(legend and legendWordsCenter or partyWordsCenter)) + 1]

  drawPartyWord(leftMon, leftWord, colors.cyan, colors.lightBlue, frame)
  drawPartyWord(rightMon, rightWord, colors.orange, colors.yellow, frame)

  setScale(centerMon, 1)
  clear(centerMon, colors.black)
  local w, h = sizeOf(centerMon)
  local main = legend and colors.magenta or colors.lime
  local alt = legend and colors.purple or colors.cyan
  stripeBackground(centerMon, frame, main, alt, colors.black)
  rect(centerMon, 2, 2, w - 1, h - 1, colors.black)
  frameBox(centerMon, colors.white, main)
  centerText(centerMon, 2, "ME SYSTEM", colors.yellow, colors.black)
  centerText(centerMon, 4, "Applied Energistics 2", colors.lightBlue, colors.black)
  centerText(centerMon, math.max(5, math.floor(h / 2) + 1), centerWord, colors.white, colors.black)
  if h >= 7 then
    centerText(centerMon, h - 2, legend and "LEGEND MODE" or "PARTY MODE", main, colors.black)
    centerText(centerMon, h - 1, "Touch / P / L", colors.lightGray, colors.black)
  end
  equalizer(centerMon, frame * 2, h - 3, math.max(3, math.floor(h / 2)), rainbow)
end

local function playForGroup(group, instrument, volume, pitch)
  if #speakers == 0 then return end
  for i, sp in ipairs(speakers) do
    local okGroup = false
    if group == "all" then
      okGroup = true
    elseif group == "a" then
      okGroup = ((i - 1) % 3) == 0
    elseif group == "b" then
      okGroup = ((i - 1) % 3) == 1
    elseif group == "c" then
      okGroup = ((i - 1) % 3) == 2
    end
    if okGroup then
      pcall(function() sp.playNote(instrument, volume, clamp(pitch, 0, 24)) end)
    end
  end
end

local progParty = { 12, 10, 8, 7 }
local progLegend = { 12, 15, 10, 8 }
local melody = { 12, 15, 17, 15, 12, 10, 8, 10, 12, 15, 19, 15, 12, 10, 8, 7 }
local legendMelody = { 12, 17, 19, 17, 15, 19, 20, 19, 17, 22, 24, 22, 19, 17, 15, 12 }
local musicStep = 0

local function playBeat(legend)
  if #speakers == 0 then return end
  musicStep = musicStep + 1
  local step = ((musicStep - 1) % 16) + 1
  local bar = math.floor((musicStep - 1) / 16) % 4 + 1
  local root = (legend and progLegend or progParty)[bar]
  local lead = (legend and legendMelody or melody)[step]

  if step == 1 or step == 9 then
    playForGroup("all", "basedrum", 3, 0)
  end
  if step == 5 or step == 13 then
    playForGroup("all", "snare", 2, 0)
  end
  if step % 2 == 0 then
    playForGroup(step % 4 == 0 and "a" or "b", "hat", 1, 0)
  end
  if step == 3 or step == 7 or step == 11 or step == 15 then
    playForGroup("c", "bass", 2, root)
  end
  if step == 1 or step == 5 or step == 9 or step == 13 then
    playForGroup("a", legend and "bit" or "pling", 2, root)
    playForGroup("b", legend and "bit" or "pling", 2, root + 3)
    playForGroup("c", legend and "bit" or "pling", 2, root + 7)
  end
  if step == 4 or step == 8 or step == 12 or step == 16 then
    playForGroup("all", legend and "bell" or "chime", 2, lead)
  elseif step % 4 == 2 then
    playForGroup(step % 8 == 2 and "a" or "b", legend and "flute" or "guitar", 1, lead)
  end
end

local function playIntro(legend)
  local seq = legend and { 7, 10, 12, 15, 19, 22 } or { 5, 7, 10, 12, 14, 17 }
  for _, p in ipairs(seq) do
    playForGroup("all", legend and "bell" or "chime", legend and 3 or 2, p)
    sleep(0.04)
  end
end

local function minuteChime(dt)
  if #speakers == 0 then return end
  local p = ({ 12, 15, 19, 22 })[(dt.hour % 4) + 1]
  playForGroup("all", "bell", 2, p)
  sleep(0.05)
  playForGroup("all", "chime", 2, p + 3)
end

local function splash()
  for _, mon in ipairs({ leftMon, centerMon, rightMon }) do
    setScale(mon, 1)
    clear(mon, colors.black)
    frameBox(mon, colors.white, colors.lightBlue)
    local _, h = sizeOf(mon)
    centerText(mon, math.max(2, math.floor(h / 2) - 1), "ME SYSTEM", colors.cyan, colors.black)
    centerText(mon, math.max(3, math.floor(h / 2)), "Applied Energistics 2", colors.white, colors.black)
    centerText(mon, math.max(4, math.floor(h / 2) + 1), "bootet...", colors.lightGray, colors.black)
  end
  playForGroup("all", "pling", 2, 7)
  sleep(0.04)
  playForGroup("all", "chime", 2, 12)
  sleep(0.04)
  playForGroup("all", "bell", 2, 19)
end

splash()

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Triple Mega Clock laeuft")
print("Links : " .. leftName)
print("Mitte : " .. centerName)
print("Rechts: " .. rightName)
print("Speaker: " .. #speakers)
print("Touch auf einen Monitor oder P = Party")
print("L oder 3 schnelle Touches in der Mitte = Legend")
print("Beenden mit Ctrl+T")

local bootClock = os.clock()
local frame = 0
local partyUntil = 0
local legendUntil = 0
local lastMinuteKey = nil
local centerTouches = {}

local function pushCenterTouch(ts)
  centerTouches[#centerTouches + 1] = ts
  while #centerTouches > 5 do table.remove(centerTouches, 1) end
  while #centerTouches > 0 and ts - centerTouches[1] > 1.6 do table.remove(centerTouches, 1) end
end

local function isLegendTouchBurst()
  return #centerTouches >= 3
end

local function startParty(seconds, legend)
  local now = os.clock()
  if legend then
    legendUntil = math.max(legendUntil, now + seconds)
    partyUntil = math.max(partyUntil, legendUntil)
    playIntro(true)
  else
    partyUntil = math.max(partyUntil, now + seconds)
    playIntro(false)
  end
end

local function render()
  local dt = nowTable()
  local now = os.clock()
  local legend = legendUntil > now
  local party = partyUntil > now

  if legend or party then
    renderParty(frame, legend)
    playBeat(legend)
  else
    renderNormalLeft(dt, frame)
    renderNormalCenter(dt, frame)
    renderNormalRight(dt, frame)
  end

  local minuteKey = string.format("%02d:%02d", dt.hour, dt.min)
  if minuteKey ~= lastMinuteKey then
    minuteChime(dt)
    lastMinuteKey = minuteKey
  end

  if dt.hour == 13 and dt.min == 37 and dt.sec == 0 then
    startParty(45, true)
  end
end

local timer = os.startTimer(0.12)
while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "timer" and a == timer then
    frame = frame + 1
    render()
    timer = os.startTimer(0.12)
  elseif ev == "monitor_touch" then
    local monName = a
    local ts = os.clock()
    if monName == centerName then
      pushCenterTouch(ts)
      if isLegendTouchBurst() then
        centerTouches = {}
        startParty(75, true)
      else
        startParty(50, false)
      end
    elseif monName == leftName or monName == rightName then
      startParty(40, false)
    end
  elseif ev == "char" then
    local ch = tostring(a or ""):lower()
    if ch == "p" then
      startParty(50, false)
    elseif ch == "l" then
      startParty(75, true)
    end
  elseif ev == "terminate" then
    for _, mon in ipairs({ leftMon, centerMon, rightMon }) do
      setScale(mon, 1)
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
