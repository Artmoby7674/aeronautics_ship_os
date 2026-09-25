# ArtCorpOS

A ComputerCraft flight stabilization and control system for Create:Aeronautics ships.

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

Also drop in the ship identity file for your hull (Atlas example ships with the repo as `ship.lua`):

```
ship.lua   -- return { id="Atlas", name="Atlas", profile="atlas" }
```

Then run:

```
startup
```

### First-time setup flow

1. Build the ship  
2. Install the OS + `ship.lua` (identifies the computer as that ship)  
3. `startup` — shows **which ship** you are on  
4. Save-slot menu: load a config, or create a new save in an empty slot  
5. Setup wizard: plug each relay **one at a time** (includes **engine relay**)  
6. Jump in the pilot seat → splash → **boot** button  

### Save-slot menu (setup phase only)

| Key | Action |
|-----|--------|
| W/S | Move cursor |
| Space | Load slot / create new save in empty slot |
| D | Delete (D again confirms, Space cancels) |

Config `version` is stamped into `config/assignments_*.lua`. If you bump the config version (or a required peripheral is missing), the **full re-wizard** runs again so you can redo wiring.

## Boot sequence (Atlas, when `engine_auto_start` + `clutch` features are on)

Loading bar = **5s** (config `engine.boot_seconds`):

| Time | Action |
|------|--------|
| 0–3s | Engine **starter** high (relay **left**) |
| 3–4s | Starter off, wait |
| 4s | **Clutch** couples (relay **right**), stays on while OS is on |
| 5s | Flight HUD ready |

**Shutdown** (circle, top-left): allowed landed or airborne — decouples clutch (right→0), cuts all outputs (e-stop), returns to splash. In the air the ship loses all thrust, so expect it to drop.

`fuel_level` feature + `fuel` config block are reserved for a future fuel-container readout (not wired yet).

## Manual Install

Copy all files from this repo into a CC:Tweaked computer's filesystem:

```
aeronautics_ship_os/
  startup
  ship.lua
  config/atlas.lua
  lib/pid.lua
  lib/hardware.lua
  lib/flight.lua
  lib/os_main.lua
  lib/hud.lua
  lib/gfx.lua
  lib/font.lua
  install.lua
  mkconfig.lua
```

## Physical Setup

### Peripherals

| Device | Count | Purpose |
|--------|-------|---------|
| Computer | 1 | Runs the OS |
| Wired Modem | 9+ | One on computer, one per relay/monitor |
| Networking Cable | - | Connects all modems in a chain |
| Redstone Relay | 8 | Bridges computer to redstone links |
| Monitor (optional) | 1 | HUD display |

### Relay placement (Atlas)

**Input Relay 1** (WASD): Front=W, Back=S, Left=A, Right=D  

**Input Relay 2** (yaw + altitude): Left=Q, Right=E, Front=Space, Back=Ctrl  
(Relays face east; front/back are the east/west-facing link sides on that body.)

**Aux relay**: Left=shift receiver, Front=gear emitter, Back=proximity receiver  

**Engine relay** (new):  
- **Left** → engine start link (pulsed 3s on boot)  
- **Right** → clutch link (held while OS on; off on shutdown)  

**Output Relays** (one per prop): Front=tilt fwd, Back=tilt bwd  
**Slow-down link** (inverted redstone): FL/RL → relay **Left** face, FR/RR → relay **Right** face  
- Engine runs ~256 RPM always; higher redstone = more braking  
- Landed / stopped = signal **15**; full thrust = signal **0**  

**Rear Thruster Relay**: Front=fw, Back=bw  

**Proximity / gear**: sensor is on the **bottom of the front landing gear**. Any active proximity forces gear **down** (G cannot retract while prox &gt; 0). Gear deploy briefly reads closer (~6 blocks) before settle.

## Controls

| Input | Function |
|-------|----------|
| W/S | Hover: tilt collective fw/bw · Cruise: ramp speed goal up/down (hold) |
| A/D | Strafe via bank tilt (**only if** `features.strafe`; Atlas = off) |
| Q/E | Yaw left/right (hover) / heading adjust (cruise) |
| Space / Ctrl | Altitude target +/− (any mode; in cruise the ship also pitches up to ±15° toward the goal) |
| Shift redstone | Hover ↔ Cruise (if ship has `cruise_mode`) |

### ACTIONS tab

Actions are **monitor-only** (no keyboard shortcuts): **MODE**, **AUTO-LAND**, **GEAR**, **E-STOP**, **RESET**, **AUTO-TUNE**, **NEXT TAB**. Features the ship lacks are dimmed.

### Flight laws (drone-style)

- **Altitude**: `thrust = hover_throttle + PID` (default hover **6**/15), applied **uniformly** to all four props. Create Aeronautics gravity is **g = 11 m/s²** (`physics.gravity`); default gains are derived for that plant (ωn≈0.8, ζ≈0.8). The D term uses **climb rate** (no kick on Space/Ctrl steps) and I only integrates near the target (anti-windup). At the target altitude props keep spinning — they do not cut to 0.
- **Pitch / roll**: **no automatic attitude speed control.** Prop speeds are never used to level the ship (that mixer was removed as unreliable).
- **Tilt** is **direct piloting only** (W/S collective, Q/E yaw stick, A/D if `features.strafe`). Hands-off / heading hold does **not** use prop tilt (heading autopilot may come later).
- **Rear thrusters**: **off in hover**, used only in **cruise** (speed hold + yaw differential).
- **Cruise speed**: W/S ramps `targets.speed`; a PID drives the rear thrusters toward it. Inside `cruise_speed_deadband` the last thrust is **held** (air resistance — no cut to 0).
- **Landed idle**: OS on + grounded → uniform prop speed **1** (slow-down wire **14**, blades creep, no lift). Full stop on shutdown / e-stop.
- **Auto-tune**: if `config/pid_<slot>.lua` is missing (first boot or deleted), altitude auto-tune arms and runs on the first airborne HOVER; gains are saved back to that file. Delete the file to re-tune.

Keys that need a missing feature reply with `No … on this ship`.

## Ship builders: config wizard

On the CC computer, run:

```
mkconfig
```

It asks for identity, features, relay names, and limits, then writes `config/<slot>.lua`. Point `ship.lua` `profile` at the slot name and run `startup` to wire the relays.

## Ship features (multi-ship ready)

Configs declare what the hull actually has under `features`:

```lua
features = {
    engine_auto_start = true,
    clutch = true,
    auto_land = true,
    cruise_mode = true,
    auto_tune = true,
    fuel_level = false, -- reserved
    strafe = false,     -- true only if the ship has lateral thrusters
}
```

Future flow: other players download the OS + a ship config pack + their own `ship.lua`, then run `mkconfig` / `startup` for their relays. Ships without engine auto-start just set those flags false and omit `engine_relay`.

## Configuration

Edit `config/atlas.lua` (or your ship’s config), or generate one with `mkconfig`:

- `ship` identity lives in root `ship.lua`
- `features`: which OS subsystems this hull enables
- `engine`: starter/clutch timing and sides
- `computer_offset`, `peripherals`, `limits`, `pid`, `fuel` (reserved)
- `config/pid_<slot>.lua` — auto-written tuned altitude/pitch/roll/yaw/speed gains; delete to re-run auto-tune

## License

MIT
