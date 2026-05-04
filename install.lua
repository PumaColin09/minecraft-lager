-- ATM 10 Draconic Reactor Monitor safe installer
-- Installs lib/f and startup, with backups for existing files.

local version = "0.27-diagnostics"

local files = {
  { path = "lib/f", content = [=[-- peripheral identification
--
function periphSearch(type)
  local names = peripheral.getNames()
  local i, name
  for i, name in pairs(names) do
    if peripheral.getType(name) == type then
      return peripheral.wrap(name), name
    end
  end
  return nil, nil
end

-- formatting

function format_int(number)

	if number == nil then number = 0 end
  number = tonumber(number) or 0

  local i, j, minus, int, fraction = tostring(number):find('([-]?)(%d+)([.]?%d*)')
  if int == nil then
    return tostring(number)
  end
  -- reverse the int-string and append a comma to all blocks of 3 digits
  int = int:reverse():gsub("(%d%d%d)", "%1,")

  -- reverse the int-string back remove an optional comma and put the
  -- optional minus and fractional part back
  return minus .. int:reverse():gsub("^,", "") .. fraction
end

-- monitor related

local function fit_text(text, maxLen)
  text = tostring(text or "")
  maxLen = tonumber(maxLen) or string.len(text)
  if maxLen < 1 then
    return ""
  end
  if string.len(text) > maxLen then
    return string.sub(text, 1, maxLen)
  end
  return text
end

--display text text on monitor, "mon" peripheral
function draw_text(mon, x, y, text, text_color, bg_color)
  if mon == nil or mon.monitor == nil then return end
  if x < 1 or y < 1 then return end
  if mon.Y ~= nil and y > mon.Y then return end
  if mon.X ~= nil and x > mon.X then return end
  text = fit_text(text, mon.X and (mon.X - x + 1) or nil)
  mon.monitor.setBackgroundColor(bg_color)
  mon.monitor.setTextColor(text_color)
  mon.monitor.setCursorPos(x,y)
  mon.monitor.write(text)
end

function draw_text_right(mon, offset, y, text, text_color, bg_color)
  if mon == nil or mon.monitor == nil then return end
  if mon.X == nil then return end
  if y < 1 then return end
  if mon.Y ~= nil and y > mon.Y then return end
  text = fit_text(text, mon.X - offset)
  local x = mon.X-string.len(tostring(text))-offset
  if x < 1 then x = 1 end
  mon.monitor.setBackgroundColor(bg_color)
  mon.monitor.setTextColor(text_color)
  mon.monitor.setCursorPos(x,y)
  mon.monitor.write(text)
end

function draw_text_lr(mon, x, y, offset, text1, text2, text1_color, text2_color, bg_color)
	draw_text(mon, x, y, text1, text1_color, bg_color)
	draw_text_right(mon, offset, y, text2, text2_color, bg_color)
end

--draw line on computer terminal
function draw_line(mon, x, y, length, color)
    if mon == nil or mon.monitor == nil then return end
    if x < 1 or y < 1 then return end
    if mon.Y ~= nil and y > mon.Y then return end
    if mon.X ~= nil and x > mon.X then return end
    length = math.floor(tonumber(length) or 0)
    if length < 0 then length = 0 end
    if mon.X ~= nil and x + length - 1 > mon.X then
      length = mon.X - x + 1
    end
    mon.monitor.setBackgroundColor(color)
    mon.monitor.setCursorPos(x,y)
    mon.monitor.write(string.rep(" ", length))
end

--create progress bar
--draws two overlapping lines
--background line of bg_color
--main line of bar_color as a percentage of minVal/maxVal
function progress_bar(mon, x, y, length, minVal, maxVal, bar_color, bg_color)
  minVal = tonumber(minVal) or 0
  maxVal = tonumber(maxVal) or 0
  length = math.floor(tonumber(length) or 0)
  if length < 0 then length = 0 end

  draw_line(mon, x, y, length, bg_color) --backgoround bar
  if maxVal <= 0 then
    return
  end

  local percent = minVal / maxVal
  if percent < 0 then percent = 0 end
  if percent > 1 then percent = 1 end

  local barSize = math.floor(percent * length)
  draw_line(mon, x, y, barSize, bar_color) --progress so far
end


function clear(mon)
  term.clear()
  term.setCursorPos(1,1)
  mon.monitor.setBackgroundColor(colors.black)
  mon.monitor.clear()
  mon.monitor.setCursorPos(1,1)
end
]=] },
  { path = "startup", content = [=[-- modifiable variables
local reactorSide = "top"
local fluxgateSide = "right"
local inputfluxgateSide = "left"
local relaySide = "bottom"

local targetStrength = 30 -- lower = more efficient, but less safe
local maxTemperature = 8000
local targetTemperature = 7995
local safeTemperature = 3000
local targetSatPercent = 10 -- 10 at minimum
local lowestFieldPercent = 10 -- recommended 10 at minimum

local activateOnCharged = 1
local initialInputFlow = 222000
local chargeInputFlow = 900000
local startupOutputFlow = 3000000

-- please leave things untouched from here on
os.loadAPI("lib/f")

local version = "0.27-diagnostics"

-- toggleable via the monitor, use our algorithm to achieve our target field strength or let the user tweak it
local autoInputGate  = 1
local curInputGate   = initialInputFlow

-- auto output gate control
local autoOutputGate = 1       -- 1 = auto, 0 = manual
local prevTemp = nil
local fuelPercent

-- auto output gate tuning
local tempIntegral = 0
local boost = 0
local maxIntegral = 100000
local maxBoost = 500
--targetTemperature = targetTemperature + 1 --[[ Band-aid solution as the reactor tends to settle
    --around 1 degree less than targetTemperature due to internal delays]]

-- monitor 
local mon, monitor, monX, monY

-- peripherals
local reactor
local fluxgate
local inputfluxgate
local relay

-- reactor information
local ri

-- last performed action
local action = "None since reboot"
local emergencyCharge = false
local emergencyTemp   = false
local newReactorChecked = false

local function numberOr(value, fallback)
  local parsed = tonumber(value)
  if parsed == nil then
    return fallback
  end
  return parsed
end

local function clamp(value, minValue, maxValue)
  value = numberOr(value, minValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function clampFlow(value)
  value = math.floor(numberOr(value, 0) + 0.5)
  if value < 0 then return 0 end
  return value
end

local function readGateFlow(gate)
  if gate == nil or gate.getSignalLowFlow == nil then
    return 0
  end
  return clampFlow(gate.getSignalLowFlow())
end

local function setGateFlow(gate, value)
  local flow = clampFlow(value)
  gate.setSignalLowFlow(flow)
  return flow
end

local function percent(value, maxValue)
  value = numberOr(value, 0)
  maxValue = numberOr(maxValue, 0)
  if maxValue <= 0 then
    return 0
  end
  return clamp(math.ceil(value / maxValue * 10000) * 0.01, 0, 100)
end

local function isFluxGate(gate)
  return gate ~= nil and gate.getSignalLowFlow ~= nil and gate.setSignalLowFlow ~= nil
end

monitor      = f.periphSearch("monitor")
reactor      = peripheral.wrap(reactorSide)
if reactor == nil or reactor.getReactorInfo == nil then
  reactor = f.periphSearch("draconic_reactor")
end
inputfluxgate = peripheral.wrap(inputfluxgateSide)
fluxgate     = peripheral.wrap(fluxgateSide)
relay        = peripheral.wrap(relaySide)
if relay == nil or relay.setOutput == nil then
  relay = f.periphSearch("redstone_relay")
end

if monitor == nil then
  error("No valid monitor was found")
end

if isFluxGate(fluxgate) == false then
  error("No valid output fluxgate was found on side '" .. fluxgateSide .. "'")
end

if reactor == nil then
  error("No valid reactor was found")
end

if isFluxGate(inputfluxgate) == false then
  error("No valid input fluxgate was found on side '" .. inputfluxgateSide .. "'")
end

if targetStrength >= 95 then
  targetStrength = 95
elseif targetStrength < 1 then
  targetStrength = 1
end

monX, monY = monitor.getSize()
if monX < 29 or monY < 19 then
  error("Monitor is too small. Use at least 29x19 characters.")
end
mon = {}
mon.monitor, mon.X, mon.Y = monitor, monX, monY

-- Set up monitor and disable cursor blink
monitor.setCursorBlink(false)
monitor.setBackgroundColor(colors.black)
monitor.clear()

-- Create a hidden buffer (same size as monitor)
local win = window.create(monitor, 1, 1, monX, monY)
win.setVisible(false)

-- Redirect all drawing to the buffer instead of directly to the monitor
mon.monitor = win

--write settings to config file
function save_config()
  local sw = fs.open("config.txt", "w")
  if sw == nil then
    action = "Could not save config"
    return false
  end
  sw.writeLine(version)
  sw.writeLine(autoInputGate)
  sw.writeLine(curInputGate)
  sw.writeLine(autoOutputGate)
  sw.close()
  return true
end

--read settings from file
function load_config()
  local sr = fs.open("config.txt", "r")
  if sr == nil then
    save_config()
    return false
  end
  sr.readLine()
  autoInputGate = tonumber(sr.readLine())
  curInputGate  = clampFlow(sr.readLine())
  autoOutputGate = tonumber(sr.readLine()) or autoOutputGate
  sr.close()

  if autoInputGate ~= 0 then autoInputGate = 1 end
  if autoOutputGate ~= 0 then autoOutputGate = 1 end
  if curInputGate <= 0 then curInputGate = initialInputFlow end

  save_config()
  return true
end

-- 1st time? save our settings, if not, load our settings
if fs.exists("config.txt") == false then
  save_config()
else
  load_config()
end

function buttons()
  
  while true do
    -- button handler
    local event, side, xPos, yPos = os.pullEvent("monitor_touch")

    ----------------------------------------------------------------
    -- OUTPUT GATE: manual controls + AU/MA toggle on row 8
    ----------------------------------------------------------------
    -- 2-4 = -1000, 6-9 = -10000, 10-12 = -100000
    -- 17-19 = +100000, 21-23 = +10000, 25-27 = +1000
    -- 14-15 = AU/MA toggle
    if yPos == 8 then
      -- toggle auto / manual for OUTPUT gate
      if xPos == 14 or xPos == 15 then
        if autoOutputGate == 1 then
          autoOutputGate = 0
        else
          autoOutputGate = 1
        end
        save_config()

      -- manual adjustments only when in MA mode
      elseif autoOutputGate == 0 then
        local cFlow = readGateFlow(fluxgate)
        if xPos >= 2 and xPos <= 4 then
          cFlow = cFlow - 1000
        elseif xPos >= 6 and xPos <= 9 then
          cFlow = cFlow - 10000
        elseif xPos >= 10 and xPos <= 12 then
          cFlow = cFlow - 100000
        elseif xPos >= 17 and xPos <= 19 then
          cFlow = cFlow + 100000
        elseif xPos >= 21 and xPos <= 23 then
          cFlow = cFlow + 10000
        elseif xPos >= 25 and xPos <= 27 then
          cFlow = cFlow + 1000
        end
        setGateFlow(fluxgate, cFlow)
      end
    end

    ----------------------------------------------------------------
    -- INPUT GATE: existing manual controls + AU/MA toggle
    ----------------------------------------------------------------
    -- 2-4 = -1000, 6-9 = -10000, 10-12 = -100000
    -- 17-19 = +100000, 21-23 = +10000, 25-27 = +1000
    if yPos == 10 and autoInputGate == 0 and xPos ~= 14 and xPos ~= 15 then
      if xPos >= 2 and xPos <= 4 then
        curInputGate = curInputGate - 1000
      elseif xPos >= 6 and xPos <= 9 then
        curInputGate = curInputGate - 10000
      elseif xPos >= 10 and xPos <= 12 then
        curInputGate = curInputGate - 100000
      elseif xPos >= 17 and xPos <= 19 then
        curInputGate = curInputGate + 100000
      elseif xPos >= 21 and xPos <= 23 then
        curInputGate = curInputGate + 10000
      elseif xPos >= 25 and xPos <= 27 then
        curInputGate = curInputGate + 1000
      end
      curInputGate = setGateFlow(inputfluxgate, curInputGate)
      save_config()
    end

    -- input gate toggle
    if yPos == 10 and (xPos == 14 or xPos == 15) then
      if autoInputGate == 1 then
        autoInputGate = 0
      else
        autoInputGate = 1
      end
      save_config()
    end

  end
end

function drawButtons(y)
  -- 2-4 = -1000, 6-9 = -10000, 10-12 = -100000
  -- 17-19 = +100000, 21-23 = +10000, 25-27 = +1000

  f.draw_text(mon, 2,  y, " < ",  colors.white, colors.gray)
  f.draw_text(mon, 6,  y, " <<",  colors.white, colors.gray)
  f.draw_text(mon, 10, y, "<<<",  colors.white, colors.gray)

  f.draw_text(mon, 17, y, ">>>",  colors.white, colors.gray)
  f.draw_text(mon, 21, y, ">> ",  colors.white, colors.gray)
  f.draw_text(mon, 25, y, " > ",  colors.white, colors.gray)
end

function update()
  while true do 

    f.clear(mon)

    ri = reactor.getReactorInfo()

    -- print out all the infos from .getReactorInfo() to term

    if ri == nil then
      action = "Invalid reactor setup"

      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.white)
      term.clear()
      term.setCursorPos(1,1)
      print("Reactor setup invalid.")
      print("getReactorInfo() returned nil.")
      print("Check that the Draconic Reactor multiblock is complete and valid.")
      print("Check that the computer can reach the real reactor peripheral.")
      print("")
      print("Detected peripherals:")
      for i, name in ipairs(peripheral.getNames()) do
        print(name .. ": " .. tostring(peripheral.getType(name)))
      end

      f.draw_text(mon, 2, 2, "Reactor Setup Invalid", colors.red, colors.black)
      f.draw_text(mon, 2, 4, "getReactorInfo() is nil", colors.white, colors.black)
      f.draw_text(mon, 2, 6, "Check multiblock", colors.orange, colors.black)
      f.draw_text(mon, 2, 7, "Check reactor peripheral", colors.orange, colors.black)
      f.draw_text(mon, 2, 9, "Computer will retry", colors.gray, colors.black)
      win.setVisible(true)
      win.redraw()
      win.setVisible(false)
      sleep(5)
    end

    if ri ~= nil then
    local status = tostring(ri.status or "unknown")
    local temperature = numberOr(ri.temperature, 0)

    for k, v in pairs(ri) do
      print(k .. ": " .. tostring(v))
    end
    print("Output Gate: ", readGateFlow(fluxgate))
    print("Input Gate: ", readGateFlow(inputfluxgate))

    -- monitor output

    local statusColor = colors.red

    if status == "running" or status == "charged" then
      statusColor = colors.green
    elseif status == "cold" then
      statusColor = colors.gray
    elseif status == "charging" or status == "warming_up" then
      statusColor = colors.orange
    end

    f.draw_text_lr(mon, 2, 2, 1, "Reactor Status",
                   string.upper(status),
                   colors.white, statusColor, colors.black)

    f.draw_text_lr(mon, 2, 4, 1, "Generation",
                   f.format_int(ri.generationRate) .. " fe/t",
                   colors.white, colors.lime, colors.black)

    local tempColor = colors.red
    if temperature <= 5000 then tempColor = colors.green end
    if temperature >= 5000 and temperature <= 6500 then tempColor = colors.orange end
    f.draw_text_lr(mon, 2, 6, 1, "Temperature",
                   f.format_int(temperature) .. "C",
                   colors.white, tempColor, colors.black)

    f.draw_text_lr(mon, 2, 7, 1, "Output Gate",
                   f.format_int(readGateFlow(fluxgate)) .. " rf/t",
                   colors.white, colors.blue, colors.black)

    -- OUTPUT GATE AU/MA indicator + buttons
    if autoOutputGate == 1 then
      f.draw_text(mon, 14, 8, "AU", colors.white, colors.gray)
      -- no manual buttons in auto mode
    else
      f.draw_text(mon, 14, 8, "MA", colors.white, colors.gray)
      drawButtons(8)
    end

    f.draw_text_lr(mon, 2, 9, 1, "Input Gate",
                   f.format_int(readGateFlow(inputfluxgate)) .. " rf/t",
                   colors.white, colors.blue, colors.black)

    if autoInputGate == 1 then
      f.draw_text(mon, 14, 10, "AU", colors.white, colors.gray)
    else
      f.draw_text(mon, 14, 10, "MA", colors.white, colors.gray)
      drawButtons(10)
    end

    local satPercent
    satPercent = percent(ri.energySaturation, ri.maxEnergySaturation)

    f.draw_text_lr(mon, 2, 11, 1, "Energy Saturation",
                   satPercent .. "%", colors.white, colors.white, colors.black)
    f.progress_bar(mon, 2, 12, mon.X - 2, satPercent, 100, colors.blue, colors.gray)

    local fieldPercent, fieldColor
    fieldPercent = percent(ri.fieldStrength, ri.maxFieldStrength)

    fieldColor = colors.red
    if fieldPercent >= 50 then fieldColor = colors.green end
    if fieldPercent < 50 and fieldPercent > 30 then fieldColor = colors.orange end

    if autoInputGate == 1 then 
      f.draw_text_lr(mon, 2, 14, 1, "Field Strength T:" .. targetStrength,
                     fieldPercent .. "%", colors.white, fieldColor, colors.black)
    else
      f.draw_text_lr(mon, 2, 14, 1, "Field Strength",
                     fieldPercent .. "%", colors.white, fieldColor, colors.black)
    end
    f.progress_bar(mon, 2, 15, mon.X - 2, fieldPercent, 100, fieldColor, colors.gray)

    local fuelColor
    fuelPercent = 100 - percent(ri.fuelConversion, ri.maxFuelConversion)

    fuelColor = colors.red
    if fuelPercent >= 70 then fuelColor = colors.green end
    if fuelPercent < 70 and fuelPercent > 30 then fuelColor = colors.orange end

    f.draw_text_lr(mon, 2, 17, 1, "Fuel ",
                   fuelPercent .. "%", colors.white, fuelColor, colors.black)
    f.progress_bar(mon, 2, 18, mon.X - 2, fuelPercent, 100, fuelColor, colors.gray)

    f.draw_text_lr(mon, 2, 19, 1, "Action ",
                   action, colors.gray, colors.gray, colors.black)

    ----------------------------------------------------------------
    -- actual reactor interaction
    ----------------------------------------------------------------
    if emergencyCharge == true then
      reactor.chargeReactor()
    end
    
    -- are we charging? open the floodgates
    if status == "charging" or status == "warming_up" then
      setGateFlow(inputfluxgate, chargeInputFlow)
      emergencyCharge = false
    end

    -- are we stopping from a shutdown and our temp is better? activate
    if emergencyTemp == true and (status == "stopping" or status == "cold") and temperature < safeTemperature then
      reactor.activateReactor()
      emergencyTemp = false
    end

    -- are we charged? lets activate
    if (status == "charged" or (status == "warming_up" and temperature >= 2000)) and activateOnCharged == 1 then
      reactor.activateReactor()
    end

    -- are we on? regulate the input fludgate to our target field strength
    -- or set it to our saved setting since we are on manual
    if status == "running" then
      if autoInputGate == 1 then 
        curInputGate = clampFlow(numberOr(ri.fieldDrainRate, 0) / (1 - (targetStrength / 100)))
        print("Target Gate: " .. curInputGate)
        setGateFlow(inputfluxgate, curInputGate)
      else
        curInputGate = setGateFlow(inputfluxgate, curInputGate)
      end
    end

  ----------------------------------------------------------------
  -- AUTO OUTPUT GATE LOGIC
  ----------------------------------------------------------------
  if autoOutputGate == 1 and status == "running" then
      --math.exp(-math.abs(targetTemperature - ri.temperature)/targetTemperature)
    prevTemp = prevTemp or temperature -- one time on startup, make prevTemp = temperature
    local tempError = targetTemperature - temperature
    local tempDeriv = temperature - prevTemp
     --maybe make boost its own integral; increasing by 0.1 when tempderiv < 0 and decreasing or resetting otherwise
    if tempDeriv <= 0.01 and temperature < targetTemperature - 0.01 then -- if rate of change is less than +0.01, and we're done oscillating, boost
      boost = boost + 0.01
    elseif temperature > targetTemperature + 0.05 then
      boost = boost - 0.005
    else boost = boost - 0.001
    end
    boost = clamp(boost, -maxBoost, maxBoost)
    if tempDeriv < 5 then
      tempIntegral = tempIntegral + tempError + boost
      tempIntegral = clamp(tempIntegral, -maxIntegral, maxIntegral)
    end
    local Kp = 4200 * math.max(math.exp(-math.abs(targetTemperature - temperature) / math.max(targetTemperature, 1)), 0.1)^2 --2.7k
    local Ki = 80
    local Kd = 1000

    ----------------------------------------------------------------
    -- Keep temperature near targetTemperature while staying above targetSatPercent
    ----------------------------------------------------------------
    if satPercent > targetSatPercent then
      local currentFlow = tempError * Kp + tempIntegral * Ki - tempDeriv * Kd
      setGateFlow(fluxgate, currentFlow)
    end
    prevTemp = temperature
  else
    tempIntegral = 0
    boost = 0
    prevTemp = nil
  end

    ----------------------------------------------------------------
    -- safeguards
    ----------------------------------------------------------------
    -- out of fuel, kill it
    if fuelPercent <= 20 then
      reactor.stopReactor()
      action = "Fuel below 20%, refuel"
    end

    -- field strength is too dangerous, kill and try and charge it before it blows
    if fieldPercent <= lowestFieldPercent and status == "running" then
      action = "Field Str < " .. lowestFieldPercent .. "%"
      reactor.stopReactor()
      reactor.chargeReactor()
      emergencyCharge = true
    end

    -- temperature too high, kill it and activate it when its cool
    if temperature > maxTemperature then
      reactor.stopReactor()
      action = "Temp > " .. maxTemperature
      emergencyTemp = true
    end
    
    -- blow up? Place a cardboard box
    if relay ~= nil and relay.setOutput ~= nil then
      if status == "beyond_hope" then
        relay.setOutput(relaySide, false)
        sleep(1)
        relay.setOutput(relaySide, true)
      else
        relay.setOutput(relaySide, true)
      end
    elseif status == "beyond_hope" then
      action = "Beyond hope; no relay"
    end

    -- flip buffer
    win.setVisible(true)
    win.redraw()
    win.setVisible(false)
    
    
    ----------------------------------------------------------------
    -- NEW REACTOR CHECK (run once per boot)
    ----------------------------------------------------------------
    if (not newReactorChecked) then
      -- brand-new core: 100% fuel remaining
      if fuelPercent >= 99.9 then
        setGateFlow(fluxgate, startupOutputFlow)
        setGateFlow(inputfluxgate, initialInputFlow)
        curInputGate = initialInputFlow        -- also reset manual input setting
        autoInputGate = 1
        autoOutputGate = 1
        save_config()
      end
      newReactorChecked = true
    end
    if status ~= "running" and status ~= "cold" then
      local cFlow = startupOutputFlow
      setGateFlow(fluxgate, cFlow)
      newReactorChecked = false
      tempIntegral = 0
    end
    if status == "cold" then
      setGateFlow(inputfluxgate, 0)
    end

    sleep(0.1)
    end
  end
end

parallel.waitForAny(buttons, update)
]=] },
}

local function parentDir(path)
  return string.match(path, "^(.+)/[^/]+$")
end

local function ensureParent(path)
  local dir = parentDir(path)
  if dir ~= nil and fs.exists(dir) == false then
    fs.makeDir(dir)
  end
end

local function backup(path)
  if fs.exists(path) == false then
    return nil
  end

  local backupPath = path .. ".bak"
  local i = 1
  while fs.exists(backupPath) do
    backupPath = path .. ".bak" .. i
    i = i + 1
  end

  fs.copy(path, backupPath)
  return backupPath
end

local function writeFile(path, content)
  ensureParent(path)

  if fs.isReadOnly(path) then
    error(path .. " is read-only")
  end

  local backupPath = backup(path)
  if backupPath ~= nil then
    print("Backup: " .. path .. " -> " .. backupPath)
  end

  local handle = fs.open(path, "w")
  if handle == nil then
    error("Could not open " .. path .. " for writing")
  end

  handle.write(content)
  handle.close()
  print("Installed: " .. path)
end

print("Installing drmon " .. version)
for i, file in ipairs(files) do
  writeFile(file.path, file.content)
end

print("Done. Check the side settings at the top of startup if needed.")
print("Run: startup")