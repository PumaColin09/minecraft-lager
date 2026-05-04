# Minecraft Lager

Improved ComputerCraft installer for an ATM 10 Draconic Reactor monitor.

## Import In Game

Run this on the ComputerCraft computer:

```text
wget https://raw.githubusercontent.com/PumaColin09/minecraft-lager/main/install.lua install
install
startup
```

The installer writes `lib/f` and `startup`. If those files already exist on the ComputerCraft computer, it creates `.bak` backups before replacing them.

Check the side settings at the top of `startup` after installing:

```lua
local reactorSide = "top"
local fluxgateSide = "right"
local inputfluxgateSide = "left"
local relaySide = "bottom"
```

## Reactor Setup Invalid

If the monitor says `Reactor Setup Invalid`, the script found a reactor peripheral but `getReactorInfo()` returned `nil`. That usually means the Draconic Reactor multiblock is not complete/valid yet, or the ComputerCraft computer is connected to the wrong block/peripheral.

The current installer auto-scans all detected reactor candidates and prints their result on the terminal. Look for a line like `name [draconic_reactor]: getReactorInfo() returned nil`; that tells you which connection is being rejected by Draconic Evolution.

Useful in-game check:

```lua
for _, name in ipairs(peripheral.getNames()) do print(name, peripheral.getType(name)) end
```

For a full stabilizer API probe:

```text
wget https://raw.githubusercontent.com/PumaColin09/minecraft-lager/main/probe.lua probe
probe draconic_reactor_0
```

`probe` checks direct `peripheral.call(...)`, wrapped calls, and old-style wired modem `callRemote(...)`. The controller tries the direct path and then wired modem remote paths.

If reactor info is still unavailable, the monitor enters manual fallback mode. In that mode `STOP` is always available, while `CHARGE` and `ACTIVATE` require pressing `ARM` first. Automatic regulation is disabled until `getReactorInfo()` returns real sensor data.
