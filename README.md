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

**Rear Thruster Relay**: Front=fw, Back=bw (inverted slow-down: 15 = stopped, 0 = full speed), **Top=rev** (reverse: 15 = reversed — used by the auto-land fore/aft hold)  

**Proximity / gear**: sensor is on the **bottom of the front landing gear**. Any active proximity forces gear **down** (G cannot retract while prox &gt; 0). Gear deploy briefly reads closer (~6 blocks) before settle. The sensor feeds the aux relay **back** face as **analog** — CC redstone relays read analog fine (`getAnalogInput`, 0–15); the flight-tab gear line shows the live value (`DN <n>`). A **latched landed** requires **4 consecutive ticks** at `landed_threshold` (spike filter).

## Controls

| Input | Function |
|-------|----------|
| W/S | Hover: tilt collective fw/bw · Cruise: step rear goal bar ±1 (hold repeats every 0.2 s) |
| Q/E | Yaw left/right (hover only — cruise rear is W/S speed level only) |
| Space / Ctrl | Altitude target +/− (any mode; in cruise the ship also pitches up to ±15° toward the goal) |
| Shift redstone | Hover ↔ Cruise (if ship has `cruise_mode`) |
| Engine relay front/back (UP/DOWN) | Switch monitor tab ↑/↓ (one step per key press; wired to the typewriter links on the engine relay) |

### ACTIONS tab

Actions are **monitor-only** (no keyboard shortcuts): **AUTO-LAND**, **GEAR**, **E-STOP**, **AUTO-TUNE**. Features the ship lacks are dimmed. The red **stop button** (top-left) powers off back to the boot splash and resets session state (HOVER mode, default tab) so the next boot matches a first-time start.

### Flight laws (drone-style)

- **Altitude**: `thrust = hover_throttle + PID` (default hover **6**/15), applied **uniformly** to all four props. Create Aeronautics gravity is **g = 11 m/s²** (`physics.gravity`); default gains are derived for that plant (ωn≈0.8, ζ≈0.8). The D term uses **climb rate** (no kick on Space/Ctrl steps) and I only integrates near the target (anti-windup). At the target altitude props keep spinning — they do not cut to 0.
- **Pitch / roll**: automatic **stability** via **prop speed reductions only** (never tilt, never accelerating a prop above the altitude-PID base): `corr = clamp(PID(0 − attitude) − 0.15 × rate, ±cap)`, with a **stepped cap by attitude error**: **0** below 2° (deadband — larger and the ship leans/strafes off-course, smaller and the wobble loop returns), **max 1** at 2–10°, **max 2** above 10°. Strength is quantized, so **precision comes from time**: the capped correction fires as **short pulses** on a 0.6 s window with a **duty cycle growing with the error** (0 → 0.3 → 1.0 across the 2–10° band), giving small errors brief small corrections instead of a continuous hold. Only the pair needing less lift slows down; the opposite pair stays at base, so corrections are gentle and the altitude PID absorbs the small mean-thrust loss. Full authority hands-off; duty fades to zero while the matching stick (W/S) is held so the pilot always wins. Gains come from `config/pid_<slot>.lua` (`pitch`, `roll`).
- **Auto-unflip**: if pitch **or** roll stays within 15° of 180° (**≥165°**) for **5 s** (airborne, not e-stopped), a recovery sequence runs: a black-on-red **AUTOMATIC UNFLIP SEQUENCE** banner (header content area + alarms row), the **left-of-computer redstone link** reverses all lift propellers, thrust goes **full**, and the pair on the **opposite side of the flip** is **cut** for a 1.5 s asymmetric kick; then **4 s of pure ascent** (uniform full reversed thrust, no cuts) to gain altitude while inverted; then a **violent righting drive** (P=6, D=1.5, no deadband, reduce-only from full speed, polarity inverted while reversed) runs until attitude ≤ 10°. The reverse link drops below 90° so reversed thrust can't press a levelled ship down; ≤ 10° ends the sequence (reverse off, PIDs reset, 5 s cooldown), and a **20 s hard timeout** aborts it (reverse off, normal law resumes). E-stop / landing / safety cut all kill the reverse link. Sign knobs at the top of `lib/flight.lua` (`UNFLIP_ROLL_CUT`, `UNFLIP_PITCH_CUT`, `UNFLIP_DRIVE_POL`) if a phase kicks the wrong way in-game.
- **Tilt** is **direct piloting only** (W/S collective, Q/E yaw stick). There is currently **no hands-off heading actuation** (the cruise rear differential / heading-hold drive was removed). The ship **cannot strafe** (props don't tilt left/right) — A/D controls are removed.
- **Rear thrusters**: **off in hover** (signal 15 = stopped); entering **cruise** puts them at **speed level 1** (signal 14) automatically. They respond **only** to the W/S goal bar — no yaw differential, no other controls. Both relay faces receive the same level.
- **Cruise speed**: a **15-segment goal bar** (levels 1–15) — each W press steps **+1**, holding repeats **every 0.2 s** (S = −1, floor **level 1**). Signal = **15 − level**: level 1 → 14 … level 15 → **0 (no redstone = reduction off)**; level 0 (hover/e-stop) → signal 15 = stopped. Wiring is **inverted slow-down** (same as the main props' speed face). Reverse = the REAR relay's **top** face (`output_map.REAR.rev`, `features.rear_reverse`).
- **Auto-landing** (L / ACTIONS): gear down → ARMED (sensor settle) → DESCEND: the altitude target walks down at `limits.land_descent_rate` (**12.0 m/s** default), freezing once the sensor reaches `landed_threshold` so the debounced ground-contact latch (4 ticks) can finish. **Runaway-goal safety**: if the goal ends up **more than 20 m below the ship while it isn't falling** (ground latch never fired, goal still walking), the goal freezes and the OS **shuts down** — clutch decoupled (props free of the engines) and the monitor back to the splash screen (climb-rate guard keeps a fast mid-air catch-up from tripping it). The heading **recorded the moment auto-land fires** is held for the whole sequence (pilot Q/E ignored; if the ship rotates, the yaw hold drives it back to the recorded heading). During ARMED/DESCEND the ship **holds fore/aft position with the rear thrusters** (gentle pulsed P-damp on longitudinal velocity — nose-axis projection from the orientation quaternion, gain **2**, 0.3 m/s deadband; corrections fire as **short bursts on a 0.6 s window** with duty growing with the excess speed but capped at **50%**, so the rear only nudges instead of shoving; drifting forward = **reverse link ON + normal thrust** pushes backward, backward drift = thrust alone — set `features.rear_reverse = false` if the reverse face isn't wired, then only backward drift is countered). Flip `LAND_FA_SIGN` in `lib/flight.lua` if the rear push amplifies drift.
- **Landed idle**: OS on + grounded → uniform prop speed **1** (slow-down wire **14**, blades creep, no lift). Full stop on shutdown / e-stop.
- **Auto-tune**: if `config/pid_<slot>.lua` is missing (first boot or deleted), altitude auto-tune arms and runs on the first airborne HOVER; gains are saved back to that file. Delete the file to re-tune.
- **Coordinates**: the ship's world position (logical pose) is sampled **every control tick** into `state.position` and exposed via `getStatus().position` — the **NAV tab** shows live **X / Y / Z** (was `N/A`). Touchdown records `getStatus().land_position` (world coords at landing) as the first reference point for the upcoming autopilot work.

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
