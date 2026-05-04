local args = { ... }
local target = args[1]

local function safeSerialize(value)
  if textutils and textutils.serialize then
    return textutils.serialize(value)
  end
  return tostring(value)
end

local function isSafeMethod(name)
  return name:match("^get")
      or name:match("^is")
      or name:match("^has")
      or name:match("^list")
end

local function printPeripheral(name)
  local pType = peripheral.getType(name)
  print("")
  print(name .. " [" .. tostring(pType) .. "]")

  local methods = peripheral.getMethods(name) or {}
  table.sort(methods)

  print("Methods:")
  for _, method in ipairs(methods) do
    print("  " .. method)
  end

  local wrapped = peripheral.wrap(name)
  if wrapped == nil then
    print("Could not wrap peripheral.")
    return
  end

  print("")
  print("Direct peripheral.call probes:")
  for _, method in ipairs(methods) do
    if isSafeMethod(method) then
      local ok, a, b, c, d = pcall(peripheral.call, name, method)
      if ok then
        print("  " .. method .. " -> " .. safeSerialize({ a, b, c, d }))
      else
        print("  " .. method .. " ERROR -> " .. tostring(a))
      end
    end
  end

  print("")
  print("Wrapped getter probes:")
  for _, method in ipairs(methods) do
    if isSafeMethod(method) and type(wrapped[method]) == "function" then
      local ok, a, b, c, d = pcall(wrapped[method])
      if ok then
        print("  " .. method .. " -> " .. safeSerialize({ a, b, c, d }))
      else
        print("  " .. method .. " ERROR -> " .. tostring(a))
      end
    end
  end
end

if target ~= nil then
  if peripheral.isPresent(target) == false then
    error("Peripheral not found: " .. target)
  end
  printPeripheral(target)
  return
end

print("Detected peripherals:")
for _, name in ipairs(peripheral.getNames()) do
  print(name .. " [" .. tostring(peripheral.getType(name)) .. "]")
end

print("")
print("Local side probes:")
for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
  if peripheral.isPresent(side) then
    print(side .. " [" .. tostring(peripheral.getType(side)) .. "]")
    local methods = peripheral.getMethods(side) or {}
    table.sort(methods)
    print("  methods: " .. table.concat(methods, ", "))
    if peripheral.hasType and peripheral.hasType(side, "draconic_reactor") then
      print("  hasType draconic_reactor: true")
    end
  end
end
print("")
print("Run with a name, for example:")
print("probe draconic_reactor_0")
