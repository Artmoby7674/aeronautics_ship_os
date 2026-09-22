# ArtCorpOS

A ComputerCraft flight stabilization and control system for Create:Aeronautics ships.

## Requirements

- Minecraft with Create:Aeronautics mod
- ComputerCraft (CC:Tweaked)
- CC:Sable addon (for ship physics data)
- Wired modems + networking cable

## Quick Install

In a ComputerCraft terminal:

```
wget run https://raw.githubusercontent.com/Artmoby7674/aeronautics_ship_os/master/install.lua
```

Then run:

```
startup
```

## Manual Install

Copy all files from this repo into a CC:Tweaked computer's filesystem:

```
atlas_os/
  startup
  config/atlas.lua
  lib/pid.lua
  lib/hardware.lua
  lib/flight.lua
  lib/os_main.lua
  lib/hud.lua
```

## Physical Setup

### Peripherals

| Device | Count | Purpose |
|--------|-------|---------|
| Computer | 1 | Runs the OS |
| Wired Modem | 8+ | One on computer, one per relay/monitor/speaker |
| Networking Cable | - | Connects all modems in a chain |
| Redstone Relay | 7 | Bridges computer to redstone links |
| Redstone Link (receiver) | 8 | Receives typewriter signals |
| Redstone Link (transmitter) | 15 | Sends control signals to propellers |
| Monitor (optional) | 1 | HUD display |

### Relay Placement

Each Redstone Relay has 6 faces. Place Redstone Links on the faces:

**Input Relay 1** (WASD):
- Front: Typewriter W key link
- Back: Typewriter S key link
- Left: Typewriter A key link
- Right: Typewriter D key link

**Input Relay 2** (Q/E):
- Front: Typewriter Q key link
- Back: Typewriter E key link

**Output Relays** (one per propeller):
- Front: Tilt forward link
- Back: Tilt backward link
- Right: Speed control link

**Rear Thruster Relay**:
- Front: Forward thrust link
- Back: Backward thrust link

## Controls

| Key | Function |
|-----|----------|
| W/S | Forward/Backward movement (hover) |
| A/D | Left/Right strafe (hover) or Bank turn (cruise) |
| Q/E | Altitude up/down (hover mode) |
| M | Toggle Hover/Cruise mode |
| X | Emergency stop |
| T | Auto-tune PIDs |
| R | Reset targets to current state |

## Modes

### Hover Mode
- Full PID stabilization on all axes
- WASD controls movement by tilting propellers
- Q/E adjusts altitude target

### Cruise Mode
- Altitude hold and heading lock
- A/D banks the ship for turning
- Rear thrusters at full speed

## Configuration

Edit `config/atlas.lua` for your ship:

- `computer_offset`: Computer position relative to center of mass
- `peripherals`: Network names of each relay
- `limits`: Speed, altitude, and tilt limits
- `pid`: PID controller gains (auto-tuned at runtime)

## License

MIT
