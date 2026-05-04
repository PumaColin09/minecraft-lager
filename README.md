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
