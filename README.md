# ArtCorpOS

A ComputerCraft flight stabilization and control system for my Create:Aeronautics ships.

## Requirements

- Minecraft with the Create:Aeronautics mod
- CC:Tweaked
- CC:Sable addon
- CC:Graphics (pixel HUD)

## Quick Install

In a ComputerCraft terminal:

```
wget run https://raw.githubusercontent.com/Artmoby7674/aeronautics_ship_os/master/install.lua
```

Then run:

```
startup
```

On boot you get a **save-slot menu** (setup phase only):

| Key | Action |
|-----|--------|
| W/S | Move cursor |
| Space | Load slot / create new save in empty slot |
| D | Delete (press D again to confirm, Space cancels) |

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
  lib/gfx.lua
  lib/font.lua
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

| Input | Function |
|-------|----------|
| W/S | All props tilt forward/back (hover) |
| A/D | Strafe left/right via bank (hover) |
| Q/E | Yaw left/right (hover) / heading adjust (cruise) |
| Space / Ctrl | Altitude target +/− (PID takeoff/land) |
| Shift redstone (aux left) | Hover ↔ Cruise (rising-edge toggle, hold-safe) |
| L | Toggle auto-landing |
| G | Toggle landing gear |
| M | Toggle Hover/Cruise (keyboard) |
| X | Emergency stop |
| T | Auto-tune PIDs |
| R | Reset targets |
| N | Next HUD tab |

### Aux relay (mode + landing)

| Face | Function |
|------|----------|
| Left | Shift receiver → mode toggle |
| Front | Emitter → landing gear deploy |
| Back | Proximity receiver under front gear (0–15, 15 = on ground) |

Auto-landing (`L`): deploys gear, descends on proximity until signal = 15, then props to 0.
Manual land: gear auto-deploys when proximity ≥ 1.

## Modes

### Hover Mode
- Starts on boot; props default speed 0
- W/S collective tilt, A/D bank strafe, Q/E yaw
- Space/Ctrl changes altitude target through PID
- Level/heading PIDs stabilize when sticks centered

### Cruise Mode
- Altitude hold and heading lock
- Rear thrusters for thrust; Q/E adjusts heading

## Configuration

Edit `config/atlas.lua` for your ship:

- `computer_offset`: Computer position relative to center of mass
- `peripherals`: Network names of each relay
- `limits`: Speed, altitude, and tilt limits
- `pid`: PID controller gains (auto-tuned at runtime)

## License

MIT
