-- peripheral identification
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
