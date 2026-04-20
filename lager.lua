-- Colin + Marcel Dual Monitor Clock Wall
-- For two large CC:Tweaked monitors and multiple speakers.
-- Touch any monitor to start PARTY MODE. Touch repeatedly for louder legend mode.
-- Optional: chrono_show_dual_ultra <leftMonitor> <rightMonitor>

local VERSION = "2.0"
local args = { ... }

local CONFIG = {
  textScale = 0.5,
  frameDelay = 0.08,
  partySeconds = 90,
  legendSeconds = 150,
  tapWindow = 4,
  minuteChime = true,
  hourChime = true,
  beatDelayParty = 0.18,
  beatDelayLegend = 0.11,
}

local monitors = {}
local speakers = {}
local state = {
  startClock = os.clock(),
  lastMinute = -1,
  lastHour = -1,
  colonOn = true,
  partyUntil = 0,
  legendUntil = 0,
  taps = {},
  message = "COLIN + MARCEL ZEITWAND ONLINE",
  messageUntil = 0,
  beatAt = 0,
  beatIndex = 0,
  sparkle = {},
  flash = 0,
  marquee = 0,
}

local COLORS = {
  colors.cyan, colors.lightBlue, colors.blue, colors.purple,
  colors.magenta, colors.pink, colors.red, colors.orange,
  colors.yellow, colors.lime, colors.green,
}

local FONT5 = {
  [" "] = {"00000","00000","00000","00000","00000"},
  ["!"] = {"00100","00100","00100","00000","00100"},
  [":"] = {"00000","00100","00000","00100","00000"},
  ["+"] = {"00100","00100","11111","00100","00100"},
  ["0"] = {"01110","10001","10001","10001","01110"},
  ["1"] = {"00100","01100","00100","00100","01110"},
  ["2"] = {"11110","00001","01110","10000","11111"},
  ["3"] = {"11110","00001","01110","00001","11110"},
  ["4"] = {"10010","10010","11111","00010","00010"},
  ["5"] = {"11111","10000","11110","00001","11110"},
  ["6"] = {"01110","10000","11110","10001","01110"},
  ["7"] = {"11111","00010","00100","01000","01000"},
  ["8"] = {"01110","10001","01110","10001","01110"},
  ["9"] = {"01110","10001","01111","00001","01110"},
  ["A"] = {"01110","10001","11111","10001","10001"},
  ["B"] = {"11110","10001","11110","10001","11110"},
  ["C"] = {"01111","10000","10000","10000","01111"},
  ["D"] = {"11110","10001","10001","10001","11110"},
  ["E"] = {"11111","10000","11110","10000","11111"},
  ["I"] = {"11111","00100","00100","00100","11111"},
  ["L"] = {"10000","10000","10000","10000","11111"},
  ["M"] = {"10001","11011","10101","10001","10001"},
  ["N"] = {"10001","11001","10101","10011","10001"},
  ["O"] = {"01110","10001","10001","10001","01110"},
  ["P"] = {"11110","10001","11110","10000","10000"},
  ["R"] = {"11110","10001","11110","10100","10010"},
  ["S"] = {"01111","10000","01110","00001","11110"},
  ["T"] = {"11111","00100","00100","00100","00100"},
  ["Y"] = {"10001","01010","00100","00100","00100"},
}

local SEGMENTS = {
  ["0"] = {true, true, true, false, true, true, true},
  ["1"] = {false, false, true, false, false, true, false},
  ["2"] = {true, false, true, true, true, false, true},
  ["3"] = {true, false, true, true, false, true, true},
  ["4"] = {false, true, true, true, false, true, false},
  ["5"] = {true, true, false, true, false, true, true},
  ["6"] = {true, true, false, true, true, true, true},
  ["7"] = {true, false, true, false, false, true, false},
  ["8"] = {true, true, true, true, true, true, true},
  ["9"] = {true, true, true, true, false, true, true},
}

local function now()
  return os.epoch("local") / 1000
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function copy(tbl)
  local out = {}
  for i = 1, #tbl do out[i] = tbl[i] end
  return out
end

local function rainbow(i)
  return COLORS[((i - 1) % #COLORS) + 1]
end

local function monSize(monData)
  if not monData or not monData.obj then return 0, 0 end
  local ok, w, h = pcall(monData.obj.getSize)
  if ok and tonumber(w) and tonumber(h) then
    monData.w = tonumber(w)
    monData.h = tonumber(h)
  end
  return monData.w or 0, monData.h or 0
end

local function fillRect(termObj, x, y, w, h, bg, textColor)
  if not termObj or w <= 0 or h <= 0 then return end
  termObj.setBackgroundColor(bg or colors.black)
  termObj.setTextColor(textColor or colors.white)
  local line = string.rep(" ", w)
  for yy = y, y + h - 1 do
    termObj.setCursorPos(x, yy)
    termObj.write(line)
  end
end

local function writeAt(termObj, x, y, text, fg, bg)
  if not termObj or not text then return end
  if bg then termObj.setBackgroundColor(bg) end
  if fg then termObj.setTextColor(fg) end
  termObj.setCursorPos(x, y)
  termObj.write(text)
end

local function centerWrite(termObj, y, text, fg, bg)
  local w = select(1, termObj.getSize())
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  writeAt(termObj, x, y, text, fg, bg)
end

local function clearMonitor(monData, bg)
  local mon = monData.obj
  local w, h = monSize(monData)
  mon.setBackgroundColor(bg or colors.black)
  mon.setTextColor(colors.white)
  mon.clear()
  mon.setCursorPos(1, 1)
  return w, h
end

local function detectMonitors()
  local found = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local obj = peripheral.wrap(name)
      pcall(obj.setTextScale, CONFIG.textScale)
      local ok, w, h = pcall(obj.getSize)
      if ok and tonumber(w) and tonumber(h) then
        found[#found + 1] = {
          name = name,
          obj = obj,
          w = tonumber(w),
          h = tonumber(h),
          area = tonumber(w) * tonumber(h),
        }
      end
    end
  end

  table.sort(found, function(a, b)
    if a.area == b.area then return a.name < b.name end
    return a.area > b.area
  end)

  local chosen = {}
  if args[1] then
    for _, mon in ipairs(found) do if mon.name == args[1] then chosen[#chosen + 1] = mon end end
  end
  if args[2] then
    for _, mon in ipairs(found) do
      if mon.name == args[2] and (#chosen == 0 or chosen[1].name ~= mon.name) then
        chosen[#chosen + 1] = mon
      end
    end
  end
  for _, mon in ipairs(found) do
    if #chosen >= 2 then break end
    local exists = false
    for _, picked in ipairs(chosen) do if picked.name == mon.name then exists = true end end
    if not exists then chosen[#chosen + 1] = mon end
  end

  monitors = chosen
  for _, mon in ipairs(monitors) do pcall(mon.obj.setTextScale, CONFIG.textScale) end
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

local function bootError(msg)
  term.setTextColor(colors.red)
  print(msg)
  error(msg, 0)
end

local function snapshot()
  local lt = os.time("local") or 0
  local h = math.floor(lt) % 24
  local m = math.floor(((lt - math.floor(lt)) * 60) + 1e-6)
  local s = math.floor((os.epoch("local") / 1000) % 60)
  local gt = os.time() or 0
  return {
    hour = h,
    minute = m,
    second = s,
    localHM = string.format("%02d:%02d", h, m),
    localHMS = string.format("%02d:%02d:%02d", h, m, s),
    game = textutils.formatTime(gt, true),
    uptime = math.floor(os.clock() - state.startClock),
  }
end

local function wideWidth()
  local w1 = select(1, monSize(monitors[1]))
  local w2 = select(1, monSize(monitors[2]))
  return w1 + w2
end

local function wideHeight()
  local _, h1 = monSize(monitors[1])
  local _, h2 = monSize(monitors[2])
  return math.min(h1, h2)
end

local function drawWideLine(y, text, fg, bg, scrollOffset)
  local left = monitors[1].obj
  local right = monitors[2].obj
  local w1 = select(1, monSize(monitors[1]))
  local total = wideWidth()
  local s = text
  if #s < total then
    local pad = math.max(0, total - #s)
    local lpad = math.floor(pad / 2)
    s = string.rep(" ", lpad) .. s .. string.rep(" ", total - #s - lpad)
  elseif scrollOffset then
    local pad = string.rep(" ", total)
    local loop = pad .. s .. "   " .. s .. pad
    local start = (scrollOffset % (#s + total + 3)) + 1
    s = loop:sub(start, start + total - 1)
    if #s < total then s = s .. loop:sub(1, total - #s) end
  else
    s = s:sub(1, total)
  end
  local leftText = s:sub(1, w1)
  local rightText = s:sub(w1 + 1)
  writeAt(left, 1, y, leftText, fg, bg)
  writeAt(right, 1, y, rightText, fg, bg)
end

local function drawBorder(monData, color, pulse)
  local mon = monData.obj
  local w, h = monSize(monData)
  local c = pulse or color
  fillRect(mon, 1, 1, w, 1, c)
  fillRect(mon, 1, h, w, 1, c)
  fillRect(mon, 1, 1, 1, h, c)
  fillRect(mon, w, 1, 1, h, c)
end

local function drawSegmentDigit(mon, digit, x, y, w, h, onColor, offColor)
  local seg = SEGMENTS[digit] or SEGMENTS["0"]
  local t = math.max(1, math.floor(math.min(w, h) / 7))
  local midY = y + math.floor(h / 2) - math.floor(t / 2)
  local topY = y
  local botY = y + h - t
  local leftX = x
  local rightX = x + w - t
  local topX = x + t
  local topW = w - 2 * t
  local upperH = math.max(1, math.floor(h / 2) - t)
  local lowerY = midY + t
  local lowerH = math.max(1, botY - lowerY)

  local function segRect(idx, sx, sy, sw, sh)
    fillRect(mon, sx, sy, sw, sh, seg[idx] and onColor or offColor)
  end

  segRect(1, topX, topY, topW, t)
  segRect(2, leftX, y + t, t, upperH)
  segRect(3, rightX, y + t, t, upperH)
  segRect(4, topX, midY, topW, t)
  segRect(5, leftX, lowerY, t, lowerH)
  segRect(6, rightX, lowerY, t, lowerH)
  segRect(7, topX, botY, topW, t)
end

local function drawColon(monData, color, bg)
  local mon = monData.obj
  local w, h = monSize(monData)
  local t = math.max(2, math.floor(h / 8))
  local x = w - t - 1
  local y1 = math.floor(h * 0.35)
  local y2 = math.floor(h * 0.63)
  fillRect(mon, x, y1, t, t, color)
  fillRect(mon, x, y2, t, t, color)
  if bg then
    fillRect(mon, x - 1, y1 - 1, 1, t + 2, bg)
    fillRect(mon, x - 1, y2 - 1, 1, t + 2, bg)
  end
end

local function drawHugePair(monData, pair, accent, footerText)
  local mon = monData.obj
  local w, h = clearMonitor(monData, colors.black)
  local footerH = 3
  local topPad = 2
  local colonReserve = monData == monitors[1] and 6 or 0
  local usableW = w - 4 - colonReserve
  local usableH = h - footerH - topPad - 1
  local gap = math.max(2, math.floor(usableW / 18))
  local digitW = math.max(6, math.floor((usableW - gap) / 2))
  local digitH = math.max(8, usableH)
  local x1 = 2
  local x2 = x1 + digitW + gap
  local y = topPad
  local offColor = colors.gray

  drawSegmentDigit(mon, pair:sub(1, 1), x1, y, digitW, digitH, accent, offColor)
  drawSegmentDigit(mon, pair:sub(2, 2), x2, y, digitW, digitH, accent, offColor)
  if monData == monitors[1] and state.colonOn then
    drawColon(monData, colors.white, colors.black)
  end

  local borderColor = state.flash > now() and colors.white or rainbow(math.floor(now() * 8) + (monData == monitors[1] and 1 or 4))
  drawBorder(monData, borderColor)

  fillRect(mon, 2, h - 2, w - 2, 1, colors.black)
  centerWrite(mon, h - 2, footerText, colors.white, colors.black)
end

local function textPatternWidth(text)
  local width = 0
  text = text:upper()
  for i = 1, #text do
    local pat = FONT5[text:sub(i, i)] or FONT5[" "]
    width = width + #pat[1]
    if i < #text then width = width + 1 end
  end
  return width
end

local function drawPatternText(monData, text, y, maxHeight, color)
  local mon = monData.obj
  local w = select(1, monSize(monData))
  text = text:upper()
  local rawW = textPatternWidth(text)
  local scale = math.max(1, math.floor(math.min((w - 4) / rawW, maxHeight / 5)))
  local drawW = rawW * scale
  local x = math.max(2, math.floor((w - drawW) / 2) + 1)
  local cursorX = x

  for i = 1, #text do
    local pat = FONT5[text:sub(i, i)] or FONT5[" "]
    for py = 1, #pat do
      local row = pat[py]
      for px = 1, #row do
        if row:sub(px, px) == "1" then
          fillRect(mon, cursorX + (px - 1) * scale, y + (py - 1) * scale, scale, scale, color)
        end
      end
    end
    cursorX = cursorX + (#pat[1] + 1) * scale
  end
end

local function addSparkles()
  local total = wideWidth()
  local h = wideHeight()
  state.sparkle = {}
  for i = 1, 80 do
    state.sparkle[i] = {
      x = math.random(1, total),
      y = math.random(2, h - 2),
      c = rainbow(math.random(1, #COLORS)),
      life = math.random() * 1.5,
    }
  end
end

local function setCombinedCell(x, y, bg, fg, ch)
  local w1 = select(1, monSize(monitors[1]))
  local target, tx
  if x <= w1 then
    target = monitors[1].obj
    tx = x
  else
    target = monitors[2].obj
    tx = x - w1
  end
  if bg then target.setBackgroundColor(bg) end
  if fg then target.setTextColor(fg) end
  target.setCursorPos(tx, y)
  target.write(ch or " ")
end

local function drawWideBars(baseY, maxH, phase)
  local totalW = wideWidth()
  for x = 1, totalW do
    local wave = math.sin((x / 3) + phase) + math.sin((x / 8) - phase * 1.7)
    local height = math.floor(((wave + 2) / 4) * maxH)
    for dy = 0, maxH - 1 do
      local on = dy < height
      local y = baseY + maxH - dy
      setCombinedCell(x, y, on and rainbow(x + math.floor(phase * 10)) or colors.black, nil, " ")
    end
  end
end

local function drawSparkles()
  local totalW = wideWidth()
  local h = wideHeight()
  for i = 1, #state.sparkle do
    local s = state.sparkle[i]
    if s.life > 0 then
      setCombinedCell(clamp(math.floor(s.x), 1, totalW), clamp(math.floor(s.y), 2, h - 1), s.c, nil, " ")
      s.y = s.y + (math.random() - 0.45) * 0.7
      s.x = s.x + (math.random() - 0.5) * 1.4
      s.life = s.life - CONFIG.frameDelay
      if s.x < 1 then s.x = totalW end
      if s.x > totalW then s.x = 1 end
      if s.y < 2 then s.y = h - 2 end
      if s.y > h - 2 then s.y = 2 end
    else
      s.x = math.random(1, totalW)
      s.y = math.random(2, h - 2)
      s.c = rainbow(math.random(1, #COLORS))
      s.life = math.random() * 1.4
    end
  end
end

local function renderClock(ss)
  drawHugePair(monitors[1], string.format("%02d", ss.hour), colors.cyan, "COLIN")
  drawHugePair(monitors[2], string.format("%02d", ss.minute), colors.lightBlue, "MARCEL")
  local totalH = wideHeight()
  local line1 = string.format("COLIN + MARCEL   %s   MC %s", ss.localHMS, ss.game)
  local line2 = "TIPPE AUF EINEN MONITOR FUER PARTY MODE"
  drawWideLine(totalH - 1, line1, colors.white, colors.black)
  drawWideLine(totalH, line2, colors.lightGray, colors.black, state.marquee)
end

local function renderParty(ss, legend)
  local phase = math.floor(now() * 4) % 4
  local left = monitors[1].obj
  local right = monitors[2].obj
  local _, h = clearMonitor(monitors[1], colors.black)
  clearMonitor(monitors[2], colors.black)
  drawBorder(monitors[1], legend and colors.red or colors.magenta, state.flash > now() and colors.white or nil)
  drawBorder(monitors[2], legend and colors.orange or colors.cyan, state.flash > now() and colors.white or nil)

  local title = legend and "LEGEND MODE" or "PARTY MODE"
  drawWideLine(1, "*** " .. title .. " ***  COLIN + MARCEL  *** TOUCH = MEHR CHAOS ***", colors.white, colors.black, state.marquee * 2)

  if phase == 0 then
    drawPatternText(monitors[1], "COLIN", 4, h - 11, colors.cyan)
    drawPatternText(monitors[2], "MARCEL", 4, h - 11, colors.orange)
  elseif phase == 1 then
    drawPatternText(monitors[1], "PARTY", 4, h - 11, colors.magenta)
    drawPatternText(monitors[2], "MODE!", 4, h - 11, colors.yellow)
  elseif phase == 2 then
    drawHugePair(monitors[1], string.format("%02d", ss.hour), rainbow(math.floor(now() * 10)), "COLIN")
    drawHugePair(monitors[2], string.format("%02d", ss.minute), rainbow(math.floor(now() * 10) + 4), "MARCEL")
  else
    drawPatternText(monitors[1], "BASS", 4, h - 11, colors.lime)
    drawPatternText(monitors[2], "BOOM!", 4, h - 11, colors.red)
  end

  drawWideBars(h - 8, 6, now() * (legend and 6 or 4))
  drawSparkles()

  local footer = legend and "COLIN x MARCEL - MAXIMALES GETOSE" or "COLIN x MARCEL - TANZENDER ZEITWARP"
  drawWideLine(h - 1, footer, colors.white, colors.black, state.marquee)
  drawWideLine(h, string.format("ZEIT %s   MC %s   UPTIME %ds", ss.localHMS, ss.game, ss.uptime), colors.lightGray, colors.black, state.marquee)
end

local function announce(msg, seconds)
  state.message = msg
  state.messageUntil = now() + (seconds or 3)
  state.flash = now() + 0.6
end

local function playOnSpeaker(sp, instrument, volume, pitch)
  if not sp or not sp.obj then return end
  pcall(function()
    sp.obj.playNote(instrument, volume, pitch)
  end)
end

local function playAll(instrument, volume, pitch)
  for i = 1, #speakers do
    playOnSpeaker(speakers[i], instrument, volume, pitch + ((i - 1) % 3))
  end
end

local function minuteChime(ss)
  if not CONFIG.minuteChime then return end
  if ss.minute ~= state.lastMinute then
    state.lastMinute = ss.minute
    state.colonOn = true
    playAll("pling", 2, 12)
    if ss.minute == 0 and CONFIG.hourChime then
      playAll("bell", 3, 16)
      playAll("chime", 3, 12)
      announce("VOLLE STUNDE!", 4)
    else
      announce("NEUE MINUTE: " .. ss.localHM, 2)
    end
  end
end

local function playPartyBeat(legend)
  if #speakers == 0 then return end
  state.beatIndex = state.beatIndex + 1
  local b = state.beatIndex
  local volume = legend and 3 or 2

  for i = 1, #speakers do
    local pitchBase = legend and 10 or 7
    local p = pitchBase + ((b + i * 2) % 12)
    if b % 4 == 1 then
      playOnSpeaker(speakers[i], i % 2 == 0 and "bass" or "basedrum", volume, p)
    elseif b % 4 == 2 then
      playOnSpeaker(speakers[i], i % 2 == 0 and "bit" or "pling", volume, p)
    elseif b % 4 == 3 then
      playOnSpeaker(speakers[i], i % 2 == 0 and "xylophone" or "guitar", volume, p)
    else
      playOnSpeaker(speakers[i], i % 2 == 0 and "bell" or "chime", volume, p)
    end
  end

  if legend and b % 8 == 0 then
    for i = 1, #speakers do
      playOnSpeaker(speakers[i], "snare", 3, 12 + (i % 5))
    end
  end
end

local function isParty()
  return now() < state.partyUntil
end

local function isLegend()
  return now() < state.legendUntil
end

local function registerTap()
  local t = now()
  local kept = {}
  for i = 1, #state.taps do
    if t - state.taps[i] <= CONFIG.tapWindow then kept[#kept + 1] = state.taps[i] end
  end
  kept[#kept + 1] = t
  state.taps = kept

  if #state.taps >= 5 then
    state.legendUntil = t + CONFIG.legendSeconds
    state.partyUntil = t + CONFIG.legendSeconds
    state.taps = {}
    addSparkles()
    announce("LEGEND MODE AKTIVIERT!", 4)
    playAll("bell", 3, 18)
    playAll("bit", 3, 14)
  else
    state.partyUntil = math.max(state.partyUntil, t + CONFIG.partySeconds)
    addSparkles()
    announce("PARTY MODE! TIPP FUER MEHR!", 3)
    playAll("pling", 3, 12)
  end
end

local function renderMessage()
  if now() < state.messageUntil then
    local y = 2
    drawWideLine(y, string.rep(" ", wideWidth()), colors.white, colors.black)
    drawWideLine(y, state.message, colors.white, colors.black, state.marquee)
  end
end

local function update(ss)
  state.marquee = state.marquee + 1
  state.colonOn = ss.second % 2 == 0
  minuteChime(ss)

  local beatDelay = isLegend() and CONFIG.beatDelayLegend or CONFIG.beatDelayParty
  if isParty() and now() >= state.beatAt then
    state.beatAt = now() + beatDelay
    playPartyBeat(isLegend())
    state.flash = now() + 0.2
  end
end

local function render()
  local ss = snapshot()
  update(ss)
  if isParty() then
    renderParty(ss, isLegend())
  else
    renderClock(ss)
  end
  renderMessage()
end

local function cleanup()
  for _, monData in ipairs(monitors) do
    if monData and monData.obj then
      monData.obj.setBackgroundColor(colors.black)
      monData.obj.setTextColor(colors.white)
      monData.obj.clear()
      monData.obj.setCursorPos(1, 1)
      monData.obj.write("COLIN + MARCEL")
      local _, h = monData.obj.getSize()
      monData.obj.setCursorPos(1, h)
      monData.obj.write("ChronoWall beendet")
    end
  end
end

math.randomseed(os.epoch("utc"))
detectMonitors()
detectSpeakers()
if #monitors < 2 then
  bootError("Bitte zwei Monitore anschliessen oder Namen uebergeben.")
end
addSparkles()
announce("COLIN + MARCEL ZEITWAND BEREIT", 2)

for _, mon in ipairs(monitors) do
  pcall(mon.obj.setTextScale, CONFIG.textScale)
end

render()
local timer = os.startTimer(CONFIG.frameDelay)

while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then
    render()
    timer = os.startTimer(CONFIG.frameDelay)
  elseif ev[1] == "monitor_touch" then
    registerTap()
    render()
  elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
    detectMonitors()
    detectSpeakers()
    if #monitors < 2 then
      cleanup()
      bootError("Zu wenige Monitore nach Aenderung erkannt.")
    end
    addSparkles()
    announce("MONITOR/SPEAKER NETZ AKTUALISIERT", 2)
    render()
  elseif ev[1] == "terminate" then
    cleanup()
    break
  end
end
