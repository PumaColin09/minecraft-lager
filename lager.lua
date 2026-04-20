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
  return {
    left = sides[1],
    center = center,
    right = sides[2],
  }
end

local display = pickDisplays()
if not display or not display.left or not display.center or not display.right then
  error("Ich brauche 3 Monitore. Start: chrono_show_triple_modern_plus <links> <mitte> <rechts>")
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

local function frameBox(mon, border, inner)
  local w, h = sizeOf(mon)
  if w < 2 or h < 2 then return end
  rect(mon, 1, 1, w, 1, border)
  rect(mon, 1, h, w, h, border)
  rect(mon, 1, 1, 1, h, border)
  rect(mon, w, 1, w, h, border)
  if inner and w >= 4 and h >= 4 then
    rect(mon, 2, 2, w - 1, 2, inner)
    rect(mon, 2, h - 1, w - 1, h - 1, inner)
    rect(mon, 2, 2, 2, h - 1, inner)
    rect(mon, w - 1, 2, w - 1, h - 1, inner)
  end
end

local function progress(mon, y, ratio, onCol, offCol)
  local w = sizeOf(mon)
  if w < 6 then return end
  rect(mon, 3, y, w - 2, y, offCol)
  local fill = math.floor((w - 4) * clamp(ratio, 0, 1))
  if fill > 0 then rect(mon, 3, y, 2 + fill, y, onCol) end
end

local function drawGlowLine(mon, y, colA, colB, frame)
  local w = sizeOf(mon)
  if y < 1 then return end
  for x = 3, w - 2 do
    local use = ((x + frame) % 6 < 3) and colA or colB
    rect(mon, x, y, x, y, use)
  end
end

local DIGITS = {
  ["0"] = {"01110","10001","10011","10101","11001","10001","01110"},
  ["1"] = {"00100","01100","00100","00100","00100","00100","01110"},
  ["2"] = {"01110","10001","00001","00010","00100","01000","11111"},
  ["3"] = {"11110","00001","00001","01110","00001","00001","11110"},
  ["4"] = {"00010","00110","01010","10010","11111","00010","00010"},
  ["5"] = {"11111","10000","10000","11110","00001","00001","11110"},
  ["6"] = {"01110","10000","10000","11110","10001","10001","01110"},
  ["7"] = {"11111","00001","00010","00100","01000","01000","01000"},
  ["8"] = {"01110","10001","10001","01110","10001","10001","01110"},
  ["9"] = {"01110","10001","10001","01111","00001","00001","01110"},
}

local function drawPixelGlyph(mon, glyph, x, y, scale, onCol)
  if not glyph then return end
  for gy = 1, #glyph do
    local row = glyph[gy]
    for gx = 1, #row do
      if row:sub(gx, gx) == "1" then
        local px = x + (gx - 1) * scale
        local py = y + (gy - 1) * scale
        rect(mon, px, py, px + scale - 1, py + scale - 1, onCol)
      end
    end
  end
end

local function glyphWidth(ch)
  local g = DIGITS[ch]
  if not g then return 0 end
  return #g[1]
end

local function drawDigitalPair(mon, pair, theme, title, footer, secRatio, frame, partyMode, legendMode)
  setScale(mon, 0.5)
  clear(mon, colors.black)
  local w, h = sizeOf(mon)

  local border = partyMode and theme.alt or theme.main
  local inner = partyMode and theme.main or colors.gray
  frameBox(mon, border, inner)
  drawGlowLine(mon, 2, theme.main, theme.alt, frame)
  drawGlowLine(mon, h - 1, theme.alt, theme.main, frame)
  centerText(mon, 3, title, colors.white, colors.black)

  local marginX = 4
  local topY = 6
  local availW = w - marginX * 2
  local availH = h - 13
  local pairWidthUnits = glyphWidth(pair:sub(1,1)) + glyphWidth(pair:sub(2,2)) + 2
  local scale = math.max(1, math.floor(math.min(availW / pairWidthUnits, availH / 7)))
  local totalW = pairWidthUnits * scale
  local totalH = 7 * scale
  local startX = math.floor((w - totalW) / 2) + 1
  local startY = math.max(topY, math.floor((h - totalH) / 2) - 1)

  if partyMode then
    for i = 0, 3 do
      local c = (i % 2 == 0) and theme.glow or theme.alt
      rect(mon, startX - 2 - i, startY - 2 - i, startX + totalW + 1 + i, startY + totalH + 1 + i, c)
    end
    rect(mon, startX - 1, startY - 1, startX + totalW, startY + totalH, colors.black)
  end

  drawPixelGlyph(mon, DIGITS[pair:sub(1,1)], startX, startY, scale, theme.main)
  drawPixelGlyph(mon, DIGITS[pair:sub(2,2)], startX + (glyphWidth(pair:sub(1,1)) + 2) * scale, startY, scale, theme.main)

  centerText(mon, h - 4, footer, colors.lightGray, colors.black)
  progress(mon, h - 2, secRatio, legendMode and theme.glow or theme.alt, colors.gray)
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

local effects = {}
local function queueEffect(events)
  effects[#effects + 1] = { step = 0, events = events }
end

local function processEffects()
  if #effects == 0 then return end
  local nextEffects = {}
  for _, fx in ipairs(effects) do
    local alive = false
    for _, ev in ipairs(fx.events) do
      if ev[1] == fx.step then
        playGroup(ev[2], ev[3], ev[4], ev[5])
      end
      if ev[1] >= fx.step then alive = true end
    end
    fx.step = fx.step + 1
    if alive then nextEffects[#nextEffects + 1] = fx end
  end
  effects = nextEffects
end

local function queueIntro(legend)
  if legend then
    queueEffect({
      {0, "all", "bell", 2, 12},
      {1, "all", "bell", 2, 15},
      {2, "all", "chime", 2, 19},
      {3, "all", "pling", 2, 22},
      {4, "all", "bell", 2, 24},
    })
  else
    queueEffect({
      {0, "all", "chime", 2, 10},
      {1, "all", "chime", 2, 14},
      {2, "all", "pling", 2, 17},
      {3, "all", "bell", 2, 19},
    })
  end
end

local function queueMinuteChime(hour)
  local base = ({ 8, 10, 12, 15 })[(hour % 4) + 1]
  queueEffect({
    {0, "all", "bell", 2, base},
    {1, "all", "chime", 2, base + 4},
    {2, "all", "pling", 2, base + 7},
  })
end

local partyRoots = { 8, 8, 13, 13, 10, 10, 15, 15 }
local legendRoots = { 8, 8, 15, 15, 17, 17, 13, 13 }
local partyLead = { 15, 17, 19, 17, 15, 12, 10, 12, 15, 17, 19, 22, 19, 17, 15, 12 }
local legendLead = { 15, 19, 22, 19, 17, 22, 24, 22, 19, 17, 15, 19, 22, 24, 22, 19 }
local beatStep = 0

local function beatTick(legend)
  if #speakers == 0 then return end
  beatStep = beatStep + 1
  local step = ((beatStep - 1) % 16) + 1
  local rootIndex = (math.floor((beatStep - 1) / 8) % 8) + 1
  local root = (legend and legendRoots or partyRoots)[rootIndex]
  local lead = (legend and legendLead or partyLead)[step]

  if step == 1 or step == 5 or step == 9 or step == 13 then
    playGroup("all", "basedrum", 2, 0)
  end
  if step == 5 or step == 13 then
    playGroup("all", "snare", 2, 0)
  end
  if step % 2 == 0 then
    playGroup(step % 4 == 0 and "b" or "a", "hat", 1, 0)
  end

  if step == 1 or step == 4 or step == 7 or step == 9 or step == 12 or step == 15 then
    playGroup("c", "bass", 2, root)
  end

  if step == 1 or step == 9 then
    playGroup("a", legend and "bit" or "guitar", 1, root + 12)
    playGroup("b", legend and "bell" or "chime", 1, root + 16)
  end

  if step == 3 or step == 7 or step == 11 or step == 15 then
    playGroup("all", legend and "bell" or "pling", 1, lead)
  elseif step == 4 or step == 8 or step == 12 or step == 16 then
    playGroup(step % 8 == 0 and "a" or "b", legend and "bit" or "flute", 1, lead - 12)
  end
end

local function splash()
  for _, mon in ipairs({ leftMon, centerMon, rightMon }) do
    setScale(mon, 0.5)
    clear(mon, colors.black)
    frameBox(mon, colors.cyan, colors.gray)
    local _, h = sizeOf(mon)
    centerText(mon, math.max(2, math.floor(h / 2) - 1), "ME SYSTEM", colors.white, colors.black)
    centerText(mon, math.max(3, math.floor(h / 2)), "Applied Energistics 2", colors.lightBlue, colors.black)
    centerText(mon, math.max(4, math.floor(h / 2) + 1), "Clock startet...", colors.lightGray, colors.black)
  end
  queueEffect({
    {0, "all", "pling", 2, 8},
    {1, "all", "chime", 2, 12},
    {2, "all", "bell", 2, 17},
  })
end

local eqPhase = 0
local function drawCenter(dt, frame, partyMode, legendMode)
  setScale(centerMon, 1)
  clear(centerMon, colors.black)
  local w, h = sizeOf(centerMon)

  local border = legendMode and colors.magenta or (partyMode and colors.lime or colors.cyan)
  local inner = legendMode and colors.orange or (partyMode and colors.yellow or colors.lightBlue)
  frameBox(centerMon, border, inner)
  drawGlowLine(centerMon, 2, border, inner, frame)

  centerText(centerMon, 2, "ME SYSTEM", colors.white, colors.black)
  if w >= 23 then
    centerText(centerMon, 3, "Applied Energistics 2", colors.lightBlue, colors.black)
  else
    centerText(centerMon, 3, "Applied", colors.lightBlue, colors.black)
    centerText(centerMon, 4, "Energistics 2", colors.lightBlue, colors.black)
  end

  local barBase = h - 3
  local topY = (w >= 23) and 5 or 6
  local maxBar = math.max(2, barBase - topY)
  local bands = math.max(8, math.min(16, w - 6))
  local left = math.floor((w - bands) / 2) + 1
  eqPhase = eqPhase + (partyMode and 0.55 or 0.30) + (legendMode and 0.15 or 0)

  for i = 1, bands do
    local wave = math.sin(eqPhase + i * 0.65)
    local wave2 = math.sin(eqPhase * 0.55 + i * 1.12)
    local v = (wave + wave2 + 2) / 4
    if partyMode then v = math.min(1, v * 1.20) end
    if legendMode then v = math.min(1, v * 1.35) end
    local barH = math.max(1, math.floor(v * maxBar))
    local col
    if legendMode then
      local palette = { colors.magenta, colors.red, colors.orange, colors.yellow }
      col = palette[((i + frame) % #palette) + 1]
    elseif partyMode then
      local palette = { colors.cyan, colors.lime, colors.pink, colors.yellow }
      col = palette[((i + frame) % #palette) + 1]
    else
      col = (i % 2 == 0) and colors.cyan or colors.lightBlue
    end
    rect(centerMon, left + i - 1, barBase - barH + 1, left + i - 1, barBase, col)
  end

  if legendMode then
    centerText(centerMon, h - 2, "LEGEND MODE", colors.yellow, colors.black)
  elseif partyMode then
    centerText(centerMon, h - 2, "PARTY MODE", colors.lime, colors.black)
  else
    centerText(centerMon, h - 2, string.format("%02d:%02d:%02d", dt.hour, dt.min, dt.sec), colors.white, colors.black)
  end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Triple Modern Plus laeuft")
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

  local leftTheme = party
      and { main = colors.cyan, alt = legend and colors.magenta or colors.lightBlue, glow = colors.white }
      or { main = colors.cyan, alt = colors.lightBlue, glow = colors.white }
  local rightTheme = party
      and { main = colors.orange, alt = legend and colors.red or colors.yellow, glow = colors.white }
      or { main = colors.orange, alt = colors.yellow, glow = colors.white }

  drawDigitalPair(leftMon, string.format("%02d", dt.hour), leftTheme, "STUNDEN", "COLIN", dt.sec / 59, frame, party, legend)
  drawCenter(dt, frame, party, legend)
  drawDigitalPair(rightMon, string.format("%02d", dt.min), rightTheme, "MINUTEN", "MARCEL", dt.sec / 59, frame, party, legend)

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

local RENDER_STEP = 0.10
local MUSIC_STEP = 0.14
local renderTimer = os.startTimer(RENDER_STEP)
local musicTimer = os.startTimer(MUSIC_STEP)

while true do
  local ev, a = os.pullEvent()
  if ev == "timer" then
    if a == renderTimer then
      frame = frame + 1
      render()
      renderTimer = os.startTimer(RENDER_STEP)
    elseif a == musicTimer then
      processEffects()
      local now = os.clock()
      if partyUntil > now or legendUntil > now then
        beatTick(legendUntil > now)
      end
      musicTimer = os.startTimer(MUSIC_STEP)
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
