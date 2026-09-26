local function loadLib(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    local path = (name:gsub("%.", "/")) .. ".lua"
    local fn = loadfile(path)
    if fn then
        local ok2, res = pcall(fn)
        if ok2 then return res end
        error(res, 0)
    end
    error(mod, 0)
end

local PID = loadLib("lib.pid")

local Flight = {}
Flight.__index = Flight

Flight.MODE_HOVER = "HOVER"
Flight.MODE_CRUISE = "CRUISE"

Flight.LAND_IDLE = "IDLE"
Flight.LAND_ARMED = "ARMED"       -- gear deploying / starting descent
Flight.LAND_DESCEND = "DESCEND"   -- auto-landing descent
Flight.LAND_TOUCH = "TOUCH"       -- ground contact
Flight.LAND_DONE = "LANDED"

-- Normalize degrees to (-180, 180]
local function wrapDeg(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

Flight.wrapDeg = wrapDeg

-- Shortest signed rotation from current to target (degrees)
local function angleError(target, current)
    return wrapDeg(target - current)
end

Flight.angleError = angleError

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Body rates (Sable usually rad/s; Create Avionics may report deg/s)
local function rateDps(v)
    if type(v) ~= "number" then return 0 end
    if math.abs(v) <= (2 * math.pi + 0.75) then
        return math.deg(v)
    end
    return v
end

-- ============================================================
-- Stability duty cycle (time-domain precision)
-- ============================================================
-- Correction strength is quantized (integer prop-speed units), so precision
-- comes from duration instead: corrections fire as short pulses on a fixed
-- window, with duty (on-time fraction) growing with attitude error.
local STAB_PERIOD = 0.6 -- s per pulse window

-- ============================================================
-- Auto-unflip: near-or-at inverted for > INV_HOLD seconds
-- ============================================================
local INV_ATT = 165        -- deg: "near or at 180"
local INV_HOLD = 5         -- s spent inverted before the sequence starts
local INV_KICK = 1.5       -- s of reversed/full/opposite-cut kick
local INV_RISE = 4         -- s of pure ascent (uniform full) before the drive
local INV_REVERSE_OFF = 90 -- deg: drop the reverse link below this attitude
local INV_DONE = 10        -- deg: sequence complete
local INV_TIMEOUT = 20     -- s hard abort (reverse off, normal law resumes)
local INV_COOLDOWN = 5     -- s before detection re-arms after a run

-- Kick: cut the pair on the OPPOSITE side of the flip. Flip a sign here if
-- the ship kicks the wrong way in-game.
local UNFLIP_ROLL_CUT = 1  -- roll >= 0 (rolled right) -> cut LEFT, else RIGHT
local UNFLIP_PITCH_CUT = 1 -- pitch >= 0 (went over forward) -> cut REAR, else FRONT

-- Drive: violent righting law (no deadband, no gentle cap). Torque polarity
-- inverts while the lift props run reversed, hence the sign switch.
local UNFLIP_KP = 6
local UNFLIP_KD = 1.5
local UNFLIP_DRIVE_POL = -1 -- -1 = reversed-thrust regime (flip if wrong way)

local function pickUnflipCut(pitch, roll)
    if math.abs(roll) >= math.abs(pitch) then
        if roll * UNFLIP_ROLL_CUT >= 0 then return "left" end
        return "right"
    end
    if pitch * UNFLIP_PITCH_CUT >= 0 then return "rear" end
    return "front"
end

-- ============================================================
-- Auto-landing assists
-- ============================================================
local LAND_GROUND_TICKS = 4 -- consecutive ticks at landed_thr before latch
local LAND_FA_KP = 2        -- fore-aft rear hold thrust gain (gentle)
local LAND_FA_DEAD = 0.3    -- m/s deadband (rear chatter)
local LAND_FA_PERIOD = 0.6  -- s pulse window for fore/aft corrections
local LAND_FA_DUTY = 0.5    -- max on-time fraction: corrections stay brief
local LAND_FA_FULL = 2.5    -- m/s excess velocity to reach max duty
local LAND_FA_SIGN = 1      -- flip if the rear push amplifies drift
local LAND_ALT_ERR_SHUTDOWN = 20 -- m goal-below-ship error: stop + OS shutdown

function Flight.new(config, hardware)
    local self = setmetatable({}, Flight)
    self.config = config
    self.hw = hardware

    self.mode = Flight.MODE_HOVER

    self.pid = {
        altitude = PID.new(config.pid.altitude),
        pitch    = PID.new(config.pid.pitch),
        roll     = PID.new(config.pid.roll),
        yaw      = PID.new(config.pid.yaw),
        speed    = PID.new(config.pid.speed or
            { kp = 0.15, ki = 0.04, kd = 0.0, integral_limit = 40, output_limit = 15 }),
    }

    self.targets = {
        altitude = 0,
        pitch = 0,
        roll = 0,
        yaw = 0,
        move_forward = 0,
        yaw_cmd = 0,
        speed = 0, -- rear speed level: 0 = off, cruise 1..15 (W/S steps it)
    }

    self.estop = false        -- latched by X until reset (R / altitude / mode)

    -- Stability pulse train + auto-unflip state
    self.stab_phase = 0   -- 0..1 duty window for time-domain stability pulses
    self.inv_time = 0     -- seconds spent near-or-at 180 (auto-unflip trigger)
    self.inv_cooldown = 0 -- seconds left before auto-unflip detection re-arms
    self.unflip = nil     -- active auto-unflip sequence table, if any

    -- Cruise W/S step state: +1 on press, +1 every 0.2 s held
    self.cruise_w_held = false
    self.cruise_s_held = false
    self.cruise_w_ticks = 0
    self.cruise_s_ticks = 0

    -- Explicit heading-hold state (0 is a valid heading — do not use as sentinel)
    self.heading_valid = false
    self.yaw_rate_dps = 0

    self.state = {
        altitude = 0,
        pitch = 0,
        roll = 0,
        yaw = 0,
        speed = 0,
        climb_rate = 0,
        angularVelocity = { x = 0, y = 0, z = 0 },
        velocity = { x = 0, y = 0, z = 0 },
        forward = { x = 0, y = 0, z = 0 },
        position = { x = 0, y = 0, z = 0 },
        pitch_rate = 0,
        roll_rate = 0,
        yaw_rate = 0,
    }

    -- signed tilt (translation/yaw) + per-prop thrust 0..15 (altitude + attitude)
    self.outputs = {
        speed = 0,
        FL_speed = 0, FR_speed = 0, RL_speed = 0, RR_speed = 0,
        FL_tilt = 0, FR_tilt = 0, RL_tilt = 0, RR_tilt = 0,
        rear_fw = 0, rear_bw = 0, rear_rev = 0,
        -- legacy aliases used by HUD
        tilt_fwd = 0, tilt_bwd = 0,
    }

    self.landed = false
    self.gear_down = false
    self.gear_settle = 0
    self.auto_land = false
    self.land_state = Flight.LAND_IDLE
    self.land_heading = nil -- heading recorded when auto-land fires
    self.fa_phase = 0       -- fore/aft correction pulse window (0..1)
    self.shutdown_request = nil -- set by safeguards; os_main acts on it
    self.proximity = 0
    self._ground_ticks = 0 -- consecutive landed_thr hits (debounced latch)
    self.shift_level = 0
    self.shift_armed = true -- allow next toggle after release

    self.last_update = os.clock()
    self.update_count = 0
    self.tick_rate = 0.05
    self.tune_requested = false
    self.tune_pending = false -- wait for airborne HOVER (e.g. boot while landed)
    self.tuning = false
    self.tune_speed = 0
    self.tune_status = nil
    self.onTuneComplete = nil -- function(ok) called when a tune finishes
    self.last_sable_error = nil

    return self
end

function Flight:captureHeading()
    self.targets.yaw = self.state.yaw
    self.heading_valid = true
    self.pid.yaw:reset()
end

function Flight:setMode(mode)
    if mode == self.mode then return false end

    local old_mode = self.mode
    self.mode = mode
    self.estop = false

    for _, pid in pairs(self.pid) do
        pid:reset()
    end

    self.targets.altitude = self.state.altitude
    if mode == Flight.MODE_CRUISE then
        -- Rear props come up at speed level 1 (cruise minimum, signal 14);
        -- W/S steps the goal bar. Hover puts them back to level 0 (signal 15).
        self.targets.speed = 1
        self.cruise_w_held = false
        self.cruise_s_held = false
        self.cruise_w_ticks = 0
        self.cruise_s_ticks = 0
    elseif mode == Flight.MODE_HOVER then
        self.targets.speed = 0
    end
    self:captureHeading()

    return true, old_mode, mode
end

function Flight:toggleMode()
    if self.mode == Flight.MODE_HOVER then
        return self:setMode(Flight.MODE_CRUISE)
    else
        return self:setMode(Flight.MODE_HOVER)
    end
end

-- Rising-edge mode toggle for held redstone (shift key).
-- Returns true when a toggle actually fired.
function Flight:pollShift(shift_value)
    local level = (shift_value or 0) > 0 and 1 or 0
    local toggled = false
    if level == 1 and self.shift_armed and self.shift_level == 0 then
        self:toggleMode()
        toggled = true
        self.shift_armed = false
    elseif level == 0 then
        self.shift_armed = true
    end
    self.shift_level = level
    return toggled
end

function Flight:adjustAltitude(delta)
    if self.auto_land and self.land_state ~= Flight.LAND_IDLE then
        return false
    end
    if self.tuning then
        return false -- do not move the setpoint mid-tune
    end
    self.estop = false -- pilot input cancels e-stop latch
    local limits = self.config.limits or {}
    local lo = limits.min_altitude or 0
    local hi = limits.max_altitude or 320
    self.targets.altitude = clamp(self.targets.altitude + delta, lo, hi)
    if self.landed and delta > 0 then
        -- command climb off ground
        self.landed = false
        if self.land_state == Flight.LAND_DONE or self.land_state == Flight.LAND_TOUCH then
            self.land_state = Flight.LAND_IDLE
            self.auto_land = false
        end
    end
    return true
end

function Flight:setAutoLand(on)
    on = not not on
    if on and self.landed then
        self.auto_land = false
        self.land_state = Flight.LAND_DONE
        return false, "ALREADY LANDED"
    end
    self.auto_land = on
    if on then
        self.land_state = Flight.LAND_ARMED
        -- Record the heading the moment auto-landing fires: the whole
        -- sequence holds this heading even if the ship rotates later.
        self.land_heading = self.state.yaw
        self.heading_valid = true
        self.targets.yaw = self.state.yaw
        self.pid.yaw:reset()
        if not self.gear_down then
            self.gear_down = true
            self.hw.setGear(true)
            self.gear_settle = (self.config.proximity and self.config.proximity.gear_settle_ticks) or 20
        end
        return true, "AUTO-LAND ARMED"
    else
        if self.land_state ~= Flight.LAND_DONE then
            self.land_state = Flight.LAND_IDLE
        end
        return true, "AUTO-LAND OFF"
    end
end

function Flight:toggleAutoLand()
    return self:setAutoLand(not self.auto_land)
end

function Flight:updateState()
    local state = self.hw.getShipState()
    self.state.altitude = state.altitude
    self.state.pitch = state.pitch
    self.state.roll = state.roll
    self.state.yaw = state.yaw
    self.state.speed = state.speed
    self.state.climb_rate = state.climb_rate
    self.state.velocity = state.velocity or { x = 0, y = 0, z = 0 }
    self.state.forward = state.forward or { x = 0, y = 0, z = 0 }
    self.state.position = state.position or { x = 0, y = 0, z = 0 }
    self.state.angularVelocity = state.angularVelocity or { x = 0, y = 0, z = 0 }
    -- Ship local X = LONGITUDINAL axis: av.x = roll rate, av.z = pitch rate.
    -- pitch+ = nose down = negative Z rotation, so d(pitch)/dt = -av.z.
    -- yaw+ = turning left = +Y rotation.
    self.state.pitch_rate = -rateDps(self.state.angularVelocity.z)
    self.state.yaw_rate = rateDps(self.state.angularVelocity.y)
    self.state.roll_rate = rateDps(self.state.angularVelocity.x)
    self.yaw_rate_dps = self.state.yaw_rate
    if state.sable_error then
        self.last_sable_error = state.sable_error
    end
    return state
end

-- Sample attitude + outputs to stab_log.txt (0.5 s) while banked or pitched.
function Flight:debugAttitude(dt)
    self._dbg_t = (self._dbg_t or 0) + dt
    if self._dbg_t < 0.5 then return end
    self._dbg_t = 0
    local st = self.state
    if math.abs(st.roll or 0) < 1 and math.abs(st.pitch or 0) < 1 then return end
    pcall(function()
        local f = fs.open("stab_log.txt", "a")
        if not f then return end
        local o = self.outputs or {}
        f.writeLine(string.format(
            "t=%.1f pitch=%.1f roll=%.1f base=%s FL=%s FR=%s RL=%s RR=%s rear=%s/%s",
            os.clock(), st.pitch or 0, st.roll or 0,
            tostring(o.speed),
            tostring(o.FL_speed), tostring(o.FR_speed),
            tostring(o.RL_speed), tostring(o.RR_speed),
            tostring(o.rear_fw), tostring(o.rear_bw)))
        f.close()
    end)
end

function Flight:hasFeature(name)
    local f = self.config and self.config.features
    if f and f[name] ~= nil then
        return not not f[name]
    end
    if self.hw and self.hw.hasFeature then
        return self.hw.hasFeature(name)
    end
    return true
end

function Flight:processInputs(keys)
    local limits = self.config.limits

    if self.mode == Flight.MODE_HOVER then
        local move_speed = limits.hover_speed

        if keys.W and keys.W > 0 then
            self.targets.move_forward = move_speed
        elseif keys.S and keys.S > 0 then
            self.targets.move_forward = -move_speed
        else
            self.targets.move_forward = 0
        end

        -- Q/E yaw stick (-1..1): Q left, E right
        local yaw = 0
        if keys.Q and keys.Q > 0 then yaw = -1
        elseif keys.E and keys.E > 0 then yaw = 1 end
        self.targets.yaw_cmd = yaw

    elseif self.mode == Flight.MODE_CRUISE then
        -- Heading stick integrates a wrapped hold target (dt applied in update)
        local yaw = 0
        if keys.Q and keys.Q > 0 then yaw = -1
        elseif keys.E and keys.E > 0 then yaw = 1 end
        self.targets.yaw_cmd = yaw

        -- W/S step the 0..15 rear goal bar: +1 on press, +1 every 0.2 s
        -- while held (4 ticks at 20 Hz). Release holds the goal.
        local repeat_ticks = math.max(1, math.floor(0.2 / (self.tick_rate or 0.05)))
        local step = 0
        if keys.W and keys.W > 0 then
            if not self.cruise_w_held then
                self.cruise_w_held = true
                self.cruise_w_ticks = 0
                step = step + 1
            else
                self.cruise_w_ticks = self.cruise_w_ticks + 1
                if self.cruise_w_ticks >= repeat_ticks then
                    self.cruise_w_ticks = 0
                    step = step + 1
                end
            end
        else
            self.cruise_w_held = false
        end
        if keys.S and keys.S > 0 then
            if not self.cruise_s_held then
                self.cruise_s_held = true
                self.cruise_s_ticks = 0
                step = step - 1
            else
                self.cruise_s_ticks = self.cruise_s_ticks + 1
                if self.cruise_s_ticks >= repeat_ticks then
                    self.cruise_s_ticks = 0
                    step = step - 1
                end
            end
        else
            self.cruise_s_held = false
        end
        if step ~= 0 then
            -- Cruise floor is speed level 1 (can't go lower); estop/mode
            -- changes can still put the goal at 0 (props stopped).
            self.targets.speed = clamp((self.targets.speed or 0) + step, 1, 15)
        end

        self.targets.move_forward = 0
    end
end

-- Rotation stabilizer:
--  - Pilot stick: rate command + gyro damp, integrates heading hold target
--  - Stick centered: hold capture heading with wrapped-error PID + rate damp
--  - Returns prop yaw tilt (-tilt_max..tilt_max); rear thrusters are not
--    steered anymore (single W/S speed level only)
function Flight:rotationControl(dt, yaw_stick, tilt_max)
    local state = self.state
    local rate = self.yaw_rate_dps
    local yaw_tilt = 0

    if math.abs(yaw_stick) > 0.05 then
        -- Rate command while stick held (deg/s), damp toward that rate
        local rate_target = yaw_stick * 35
        local rate_err = rate_target - rate
        local damp = clamp(rate_err / 45, -1, 1) * tilt_max * 0.4
        local direct = yaw_stick * tilt_max * 0.6
        yaw_tilt = clamp(direct + damp, -tilt_max, tilt_max)

        -- Keep hold target tracking so release does not snap
        if not self.heading_valid then
            self:captureHeading()
        end
        self.targets.yaw = wrapDeg(self.targets.yaw + yaw_stick * 30 * dt)
        self.pid.yaw:reset()
        return yaw_tilt
    end

    -- Hands-off: no prop-tilt stabilisation (tilt is piloting-only for now;
    -- heading autopilot via tilt may come later).
    if not self.heading_valid then
        self:captureHeading()
    end

    local err = angleError(self.targets.yaw, state.yaw)
    local pid = self.pid.yaw

    local p = pid.kp * err
    pid.integral = clamp(pid.integral + err * dt, -pid.integral_limit, pid.integral_limit)
    local i = pid.ki * pid.integral
    -- Damp absolute rotation (positive yaw rate = turning left/increasing yaw)
    local d = -pid.kd * rate

    yaw_tilt = 0
    local out = clamp(p + i + d, -pid.output_limit, pid.output_limit)

    -- Deadband: avoid micro-wiggle when nearly on heading and still
    if math.abs(err) < 0.35 and math.abs(rate) < 1.5 then
        yaw_tilt = 0
        pid.integral = pid.integral * 0.9
    end

    return yaw_tilt
end

function Flight:update()
    -- Fixed 20 Hz control period (timer is started at 0.05s)
    local dt = self.tick_rate
    if dt <= 0 then dt = 0.05 end
    self.last_update = os.clock()
    self.update_count = self.update_count + 1

    self:updateState()
    self:debugAttitude(dt)

    self.proximity = self.hw.getProximity() or 0
    local prox_cfg = self.config.proximity or {}
    local landed_thr = prox_cfg.landed_threshold or 15
    local deploy_thr = prox_cfg.gear_deploy_threshold or 1

    -- Laser under/near the gear: any detection at or above the deploy
    -- threshold forces gear down. Re-assert every tick (not just on the
    -- rising edge) so a missed setGear / state desync cannot stick.
    if self:hasFeature("gear") and self.proximity >= deploy_thr then
        if not self.gear_down then
            self.gear_settle = prox_cfg.gear_settle_ticks or 20
            self._prox_deployed = true
            if self.onGearAutoDeploy then
                pcall(self.onGearAutoDeploy, self.proximity)
            end
        end
        self.gear_down = true
        self.hw.setGear(true)
    end
    if self.gear_down then
        if self.gear_settle and self.gear_settle > 0 then
            self.gear_settle = self.gear_settle - 1
        end
    else
        self.gear_settle = 0
        self._prox_deployed = false
    end

    -- Ground contact: latch only after LAND_GROUND_TICKS consecutive ticks
    -- at/above the landed threshold (filters single-sensor spikes).
    -- Gearless ships: no gear to settle, so ground contact is immediate
    local gear_ready = (not self:hasFeature("gear"))
        or (self.gear_down and (not self.gear_settle or self.gear_settle <= 0))
    if self.proximity >= landed_thr and gear_ready then
        self._ground_ticks = (self._ground_ticks or 0) + 1
        if not self.landed and self._ground_ticks >= LAND_GROUND_TICKS then
            self.landed = true
            if self.land_state == Flight.LAND_DESCEND or self.land_state == Flight.LAND_ARMED then
                self.land_state = Flight.LAND_TOUCH
            elseif self.land_state == Flight.LAND_IDLE then
                self.land_state = Flight.LAND_DONE
            end
        end
    else
        self._ground_ticks = 0
        if self.landed and self.proximity < (landed_thr - 1) and self.targets.altitude > self.state.altitude + 1 then
            -- climbing away
    self.landed = false
    self.land_position = nil -- world coords recorded at touchdown
            if self.land_state == Flight.LAND_DONE or self.land_state == Flight.LAND_TOUCH then
                self.land_state = Flight.LAND_IDLE
                self.auto_land = false
            end
        end
    end

    -- E-stop latch first: no tune may start or run while latched.
    -- (emergencyStop finishes any active tune, so tuning is already false here.)
    if self.estop then
        self:cutPropsSoft()
        self:applyOutputs()
        return self.outputs
    end

    -- Altitude PID auto-tune: bang-bang while airborne in HOVER
    if self.tuning then
        if self.landed or self.mode ~= Flight.MODE_HOVER then
            self:finishAutoTune(false, "aborted")
        else
            local done, tune_ok = self.pid.altitude:updateAutoTune(dt)
            self:cutPropsSoft()
            self:setUniformSpeed(self.tune_speed or 0)
            self:applyOutputs()
            if done then
                local g = self.pid.altitude:getGains()
                self:finishAutoTune(tune_ok, tune_ok
                    and string.format("K%.1f I%.2f D%.1f", g.kp, g.ki, g.kd)
                    or "no oscillation")
            end
            return self.outputs
        end
    end

    -- Promote a pending tune once we are actually flying in HOVER
    if self.tune_pending and not self.landed and self.mode == Flight.MODE_HOVER then
        self.tune_pending = false
        self.tune_requested = true
        self.tune_status = "queued"
    end

    if self.tune_requested then
        if self.landed or self.mode ~= Flight.MODE_HOVER then
            -- conditions changed since the request (e.g. landed at boot)
            self.tune_requested = false
            self.tune_pending = true
            self.tune_status = "waiting for air"
        else
            self:beginAutoTune()
            self:cutPropsSoft()
            self:setUniformSpeed(self.tune_speed or 0)
            self:applyOutputs()
            return self.outputs
        end
    end

    if self.mode == Flight.MODE_HOVER then
        self:updateHover(dt)
    elseif self.mode == Flight.MODE_CRUISE then
        self:updateCruise(dt)
    end

    self:updateAutoLand(dt)

    if self.landed and not self.auto_land then
        -- idle on ground: creep + anti-drift (unless pilot already commanded climb)
        local climbing = self.targets.altitude > self.state.altitude + 0.5
        if not climbing then
            self:updateLandedIdle(dt)
        end
    end

    self:runUnflip(dt)

    self:applyOutputs()
    return self.outputs
end

-- Parked: uniform creep speed (slow-down wire 14). No tilt, no leveling.
function Flight:updateLandedIdle(dt)
    local limits = self.config.limits or {}
    local creep = limits.landed_creep or 1

    self.pid.altitude:reset()
    self:setUniformSpeed(creep)
    self.outputs.FL_tilt = 0
    self.outputs.FR_tilt = 0
    self.outputs.RL_tilt = 0
    self.outputs.RR_tilt = 0
    self.outputs.tilt_fwd = 0
    self.outputs.tilt_bwd = 0
    self.outputs.rear_fw = 0
    self.outputs.rear_bw = 0
    self.outputs.rear_rev = 0
end

-- Auto-landing: fore-aft drift hold with the rear thrusters. Damps
-- longitudinal velocity (drifting forward -> reverse link ON + normal
-- thrust pushes backward; backward drift -> thrust alone). The fore/aft
-- axis is the ship's NOSE direction from the orientation quaternion, so
-- the projection cannot pick up yaw-convention sign errors. Reverse needs
-- mapping.rev (REAR relay top face) wired.
function Flight:landingAssist(dt)
    if self.estop then return end
    local state = self.state
    local vel = state.velocity or { x = 0, y = 0, z = 0 }
    local fwd = state.forward or { x = 0, y = 0, z = 0 }
    local fwd_vel = (vel.x * fwd.x + vel.y * fwd.y + vel.z * fwd.z)
        * LAND_FA_SIGN
    -- Gentle pulsed corrections: strength is a coarse number, so trim with
    -- time instead — short bursts on a fixed window whose duty grows with
    -- the excess velocity but never exceeds LAND_FA_DUTY (split-second
    -- corrections, not a continuous shove).
    self.fa_phase = ((self.fa_phase or 0)
        + (dt or 0.05) / LAND_FA_PERIOD) % 1
    local level, rev = 0, false
    local a = math.abs(fwd_vel)
    if a > LAND_FA_DEAD then
        rev = fwd_vel > 0 -- moving forward -> reverse + thrust = push back
        local rev_ok = (not rev) or self:hasFeature("rear_reverse")
        local duty = math.min((a - LAND_FA_DEAD) / LAND_FA_FULL, 1)
            * LAND_FA_DUTY
        if rev_ok and self.fa_phase < duty then
            level = clamp(a * LAND_FA_KP, 0, 15)
        end
        if not rev_ok then rev = false end
    end
    self.outputs.rear_fw = level
    self.outputs.rear_bw = level
    self.outputs.rear_rev = rev and 1 or 0
end

function Flight:updateAutoLand(dt)
    if not self.auto_land then
        if self.land_state == Flight.LAND_TOUCH or self.land_state == Flight.LAND_DESCEND then
            -- finished or aborted mid-way handled elsewhere
        end
        return
    end

    if self.land_state == Flight.LAND_ARMED then
        self.gear_down = true
        self.hw.setGear(true)
        self:landingAssist(dt)
        local armed_ready = (not self:hasFeature("gear"))
            or (not self.gear_settle or self.gear_settle <= 0)
        local armed_land_thr = (self.config.proximity or {}).landed_threshold or 15
        if armed_ready and self.proximity >= armed_land_thr then
            self.land_state = Flight.LAND_TOUCH
        elseif armed_ready then
            self.land_state = Flight.LAND_DESCEND
            -- start slightly above current and walk target down
            self.targets.altitude = self.state.altitude
        end
        -- else: gear still settling, stay ARMED until it finishes
    end

    -- Hold the fire-time heading for the whole sequence: if the ship
    -- rotates, the hands-off yaw law drives it back to the recorded value.
    if self.land_heading then
        self.targets.yaw = self.land_heading
        self.heading_valid = true
    end

    if self.land_state == Flight.LAND_DESCEND then
        -- Runaway-goal safety: the goal kept walking down after the ship
        -- stopped (ground latch never fired). Freeze the goal and ask
        -- os_main for a full shutdown (clutch decouple + splash). The
        -- climb-rate guard keeps a mid-air catch-up (fast fall, big error)
        -- from tripping it.
        local alt_err = self.state.altitude - self.targets.altitude
        if alt_err > LAND_ALT_ERR_SHUTDOWN
            and (self.state.climb_rate or 0) > -3 then
            self.targets.altitude = self.state.altitude
            if not self.shutdown_request then
                self.shutdown_request =
                    string.format("land alt error %.0f m", alt_err)
            end
        end

        local rate = (self.config.limits and self.config.limits.land_descent_rate) or 12.0
        local land_thr = (self.config.proximity or {}).landed_threshold or 15
        -- Freeze the walking target once the sensor says touchdown range:
        -- the debounced ground-contact latch below finishes the landing.
        if self.proximity < land_thr and not self.shutdown_request then
            self.targets.altitude = self.targets.altitude - rate * dt
            if self.targets.altitude < 0 then
                self.targets.altitude = 0
            end
        end
        self:landingAssist(dt)
        if not self.heading_valid then
            self:captureHeading()
        end
    end

    if self.land_state == Flight.LAND_TOUCH then
        self.landed = true
        self.land_state = Flight.LAND_DONE
        self.targets.altitude = self.state.altitude
        -- touchdown coordinates: reference point for future autopilot work
        local p = self.state.position
        self.land_position = { x = p.x, y = p.y, z = p.z }
        -- keep gear down
        self.gear_down = true
        self.hw.setGear(true)
    end

    if self.land_state == Flight.LAND_DONE then
        self.auto_land = false
    end
end

function Flight:cutPropsSoft()
    self.outputs.speed = 0
    self.outputs.FL_speed = 0
    self.outputs.FR_speed = 0
    self.outputs.RL_speed = 0
    self.outputs.RR_speed = 0
    self.outputs.FL_tilt = 0
    self.outputs.FR_tilt = 0
    self.outputs.RL_tilt = 0
    self.outputs.RR_tilt = 0
    self.outputs.rear_fw = 0
    self.outputs.rear_bw = 0
    self.outputs.rear_rev = 0
end

function Flight:setUniformSpeed(v)
    v = clamp(v or 0, 0, 15)
    self.outputs.speed = v
    self.outputs.FL_speed = v
    self.outputs.FR_speed = v
    self.outputs.RL_speed = v
    self.outputs.RR_speed = v
end

function Flight:updateHover(dt)
    local state = self.state
    local targets = self.targets
    local limits = self.config.limits
    local tilt_max = limits.tilt_max or 12
    local hover = limits.hover_throttle or 6
    local hmin = limits.hover_min_speed or 0
    local hmax = limits.hover_max_speed or 15

    -- Parked: update() applies creep via updateLandedIdle
    if self.landed and not self.auto_land
        and not (targets.altitude > state.altitude + 0.5) then
        self.pid.pitch:reset()
        self.pid.roll:reset()
        return
    end

    -- Sticks as -1..1
    local fwd = 0
    if targets.move_forward > 0 then fwd = 1
    elseif targets.move_forward < 0 then fwd = -1 end

    local yaw_stick = targets.yaw_cmd or 0

    -- Auto-landing owns the heading: pilot Q/E forced to center so the same
    -- hands-off law (rotationControl with stick 0) holds the current heading.
    if self.auto_land and (self.land_state == Flight.LAND_ARMED
        or self.land_state == Flight.LAND_DESCEND) then
        yaw_stick = 0
    end

    -- Tilt: pilot stick only (W/S collective, Q/E yaw).
    -- Sign flipped: W (forward) was pushing the ship backward.
    local collective = -fwd * tilt_max

    local yaw_tilt = self:rotationControl(dt, yaw_stick, tilt_max)

    -- Stability via prop speed REDUCTION only (never tilt, never speeding a
    -- prop above the altitude-PID base): PID leveling + gyro damp toward 0
    -- deg attitude, with a stepped cap by attitude error so corrections stay
    -- gentle — 0 below 2 deg (deadband; larger = the ship leans and strafes
    -- off-course, smaller = wobble/overshoot returns), at most 1 unit at
    -- 2-10 deg, at most 2 above 10 deg. Full authority hands-off; fades while
    -- the W/S pitch stick is held so the pilot always wins. PIDs update
    -- every tick so the derivative state stays fresh under pilot override.
    local pitch_out = self.pid.pitch:update(0, state.pitch, dt)
    local roll_out = self.pid.roll:update(0, state.roll, dt)
    local pitch_auth = 1 - math.min(1, math.abs(fwd))
    local function stabCap(att)
        local a = math.abs(att)
        if a < 2 then return 0 end
        if a > 10 then return 2 end
        return 1
    end
    local pitch_cap = stabCap(state.pitch) * pitch_auth
    local roll_cap = stabCap(state.roll)
    local pitch_corr = clamp(pitch_out - 0.15 * (state.pitch_rate or 0), -pitch_cap, pitch_cap)
    local roll_corr = clamp(roll_out - 0.15 * (state.roll_rate or 0), -roll_cap, roll_cap)

    -- Time-domain precision: strength is quantized (1-2 units), so trim with
    -- duration instead — a pulse train (STAB_PERIOD window) whose duty grows
    -- 0 -> 0.3 -> 1.0 across the 2 deg deadband and the 2-10 deg band. Small
    -- errors get short bursts, larger errors more on-time; above 10 deg the
    -- capped correction holds continuously. Zero duty (deadband or stick
    -- override via pitch_auth) gates the axis off entirely.
    self.stab_phase = (self.stab_phase + dt / STAB_PERIOD) % 1
    local function stabDuty(att)
        local a = math.abs(att)
        if a < 2 then return 0 end
        if a > 10 then return 1 end
        return 0.3 + 0.7 * (a - 2) / 8
    end
    local pitch_duty = stabDuty(state.pitch) * pitch_auth
    local roll_duty = stabDuty(state.roll)
    if self.stab_phase >= pitch_duty then pitch_corr = 0 end
    if self.stab_phase >= roll_duty then roll_corr = 0 end

    local FL_tilt = clamp(collective + yaw_tilt, -tilt_max, tilt_max)
    local FR_tilt = clamp(collective - yaw_tilt, -tilt_max, tilt_max)
    local RL_tilt = clamp(collective + yaw_tilt, -tilt_max, tilt_max)
    local RR_tilt = clamp(collective - yaw_tilt, -tilt_max, tilt_max)

    -- Altitude: mean prop speed (attitude uses per-prop speed differentials).
    -- D uses climb rate (measurement) so altitude steps do not kick.
    local alt_output = self.pid.altitude:update(targets.altitude, state.altitude, dt, state.climb_rate)
    local base_speed = 0
    local flying = false

    if not self.landed then
        base_speed = clamp(hover + alt_output, hmin, hmax)
        flying = true
    elseif targets.altitude > state.altitude + 0.5 then
        base_speed = clamp(hover + alt_output, hmin, hmax)
        flying = true
    else
        base_speed = 0
        FL_tilt, FR_tilt, RL_tilt, RR_tilt = 0, 0, 0, 0
        self.pid.altitude:reset()
    end

    if not flying then
        base_speed = 0
    end

    -- LAND_DESCEND uses the same hover+PID law as normal flight: the walking
    -- altitude target alone produces the descent command. (A reduced
    -- feedforward here made the ship free-fall below the path.)
    if flying then
        -- Only-reduce: no prop ever goes above base_speed. The pair on the
        -- side needing less lift slows down (nose down -> rear slows, right
        -- down -> left slows); the opposite pair stays at base, so the
        -- altitude PID absorbs the small mean-thrust loss.
        self.outputs.speed = base_speed
        local p_front = math.max(pitch_corr, 0)
        local p_rear = math.max(-pitch_corr, 0)
        local r_left = math.max(-roll_corr, 0)
        local r_right = math.max(roll_corr, 0)
        self.outputs.FL_speed = clamp(base_speed - p_front - r_left, 0, 15)
        self.outputs.FR_speed = clamp(base_speed - p_front - r_right, 0, 15)
        self.outputs.RL_speed = clamp(base_speed - p_rear - r_left, 0, 15)
        self.outputs.RR_speed = clamp(base_speed - p_rear - r_right, 0, 15)
    else
        self:setUniformSpeed(0)
    end
    self.outputs.FL_tilt = FL_tilt
    self.outputs.FR_tilt = FR_tilt
    self.outputs.RL_tilt = RL_tilt
    self.outputs.RR_tilt = RR_tilt
    self.outputs.tilt_fwd = math.max(0, collective)
    self.outputs.tilt_bwd = math.max(0, -collective)

    -- Hover: rear thrusters always off (cruise only)
    self.outputs.rear_fw = 0
    self.outputs.rear_bw = 0
end

function Flight:updateCruise(dt)
    local state = self.state
    local targets = self.targets
    local limits = self.config.limits or {}
    local hover = limits.hover_throttle or 6
    local hmin = limits.hover_min_speed or 0
    local hmax = limits.hover_max_speed or 15

    if self.landed and not self.auto_land
        and not (targets.altitude > state.altitude + 0.5) then
        return
    end

    local alt_output = self.pid.altitude:update(targets.altitude, state.altitude, dt, state.climb_rate)

    local base_speed = 0
    local flying = false
    if not self.landed then
        base_speed = clamp(hover + alt_output, hmin, hmax)
        flying = true
    elseif targets.altitude > state.altitude + 0.5 then
        base_speed = clamp(hover + alt_output, hmin, hmax)
        flying = true
    else
        base_speed = 0
        self.pid.altitude:reset()
    end

    if not flying then
        base_speed = 0
    end

    self:setUniformSpeed(base_speed)

    self.outputs.FL_tilt = 0
    self.outputs.FR_tilt = 0
    self.outputs.RL_tilt = 0
    self.outputs.RR_tilt = 0
    self.outputs.tilt_fwd = 0
    self.outputs.tilt_bwd = 0

    if self.landed then
        self.outputs.rear_fw = 0
        self.outputs.rear_bw = 0
        return
    end

    -- Back thrusters: ONE speed level (0 = off, cruise 1..15), controlled
    -- only by the W/S goal bar. Both relay faces get the same level; the
    -- hardware layer sends signal = 15 - level (level 15 = signal 0 =
    -- reduction off; level 0 = signal 15 = stopped). No differential or
    -- any other rear control. Reverse (future autopilot) = redstone on
    -- the relay top.
    local level = clamp(targets.speed or 0, 0, 15)
    self.outputs.rear_fw = level
    self.outputs.rear_bw = level
end

function Flight:applyOutputs()
    local hw = self.hw

    hw.setPropellerOutput("FL", "speed", self.outputs.FL_speed or self.outputs.speed or 0)
    hw.setPropellerOutput("FR", "speed", self.outputs.FR_speed or self.outputs.speed or 0)
    hw.setPropellerOutput("RL", "speed", self.outputs.RL_speed or self.outputs.speed or 0)
    hw.setPropellerOutput("RR", "speed", self.outputs.RR_speed or self.outputs.speed or 0)

    hw.setPropellerOutput("FL", "tilt_fwd", math.max(0, self.outputs.FL_tilt))
    hw.setPropellerOutput("FL", "tilt_bwd", math.max(0, -self.outputs.FL_tilt))

    hw.setPropellerOutput("FR", "tilt_fwd", math.max(0, self.outputs.FR_tilt))
    hw.setPropellerOutput("FR", "tilt_bwd", math.max(0, -self.outputs.FR_tilt))

    hw.setPropellerOutput("RL", "tilt_fwd", math.max(0, self.outputs.RL_tilt))
    hw.setPropellerOutput("RL", "tilt_bwd", math.max(0, -self.outputs.RL_tilt))

    hw.setPropellerOutput("RR", "tilt_fwd", math.max(0, self.outputs.RR_tilt))
    hw.setPropellerOutput("RR", "tilt_bwd", math.max(0, -self.outputs.RR_tilt))

    hw.setRearOutput("fw", self.outputs.rear_fw)
    hw.setRearOutput("bw", self.outputs.rear_bw)
    hw.setRearReverse((self.outputs.rear_rev or 0) > 0)
end

-- ============================================================
-- Auto-unflip: lift props reversed (redstone link on the computer's back)
-- + opposite-side cut kick, then a violent righting drive back to 0 deg.
-- ============================================================
function Flight:runUnflip(dt)
    local state = self.state
    self.inv_cooldown = math.max(0, self.inv_cooldown - dt)

    if self.unflip then
        local u = self.unflip
        if self.landed or self.estop then
            self:finishUnflip()
            return
        end
        u.t = u.t + dt
        local att = math.max(math.abs(state.pitch), math.abs(state.roll))
        -- kick -> rise (pure ascent, uniform full thrust) -> drive. The rise
        -- phase keeps reversed full thrust on longer so the ship gains
        -- altitude while inverted; skipped if already past halfway.
        if u.phase == "kick" and u.t >= INV_KICK then
            u.phase = att >= INV_REVERSE_OFF and "rise" or "drive"
        elseif u.phase == "rise"
            and (u.t >= INV_KICK + INV_RISE or att < INV_REVERSE_OFF) then
            u.phase = "drive"
        end
        if att <= INV_DONE or u.t >= INV_TIMEOUT then
            self:finishUnflip() -- done, or hard abort after INV_TIMEOUT
            return
        end

        -- Reverse stays on while inverted; drops past halfway so reversed
        -- thrust can never press a levelled ship down.
        local reverse = att >= INV_REVERSE_OFF
        self.hw.setLiftReverse(reverse)

        -- Full thrust either way; no tilt, no rear during the sequence.
        self:setUniformSpeed(15)
        self.outputs.FL_tilt = 0
        self.outputs.FR_tilt = 0
        self.outputs.RL_tilt = 0
        self.outputs.RR_tilt = 0
        self.outputs.tilt_fwd = 0
        self.outputs.tilt_bwd = 0
        self.outputs.rear_fw = 0
        self.outputs.rear_bw = 0

        if u.phase == "kick" then
            -- Opposite pair cut: raw asymmetric reversed-thrust kick.
            if u.cut == "left" then
                self.outputs.FL_speed = 0
                self.outputs.RL_speed = 0
            elseif u.cut == "right" then
                self.outputs.FR_speed = 0
                self.outputs.RR_speed = 0
            elseif u.cut == "front" then
                self.outputs.FL_speed = 0
                self.outputs.FR_speed = 0
            elseif u.cut == "rear" then
                self.outputs.RL_speed = 0
                self.outputs.RR_speed = 0
            end
        elseif u.phase == "drive" then
            -- Drive: violent reduce-only righting from full speed. While the
            -- props run reversed the torque polarity flips, hence `pol`.
            local pol = 1
            if reverse then pol = UNFLIP_DRIVE_POL end
            local v_pitch = pol * clamp(-(UNFLIP_KP * state.pitch
                + UNFLIP_KD * (state.pitch_rate or 0)), -15, 15)
            local v_roll = pol * clamp(-(UNFLIP_KP * state.roll
                + UNFLIP_KD * (state.roll_rate or 0)), -15, 15)
            local p_front = math.max(v_pitch, 0)
            local p_rear = math.max(-v_pitch, 0)
            local r_left = math.max(-v_roll, 0)
            local r_right = math.max(v_roll, 0)
            self.outputs.FL_speed = clamp(15 - p_front - r_left, 0, 15)
            self.outputs.FR_speed = clamp(15 - p_front - r_right, 0, 15)
            self.outputs.RL_speed = clamp(15 - p_rear - r_left, 0, 15)
            self.outputs.RR_speed = clamp(15 - p_rear - r_right, 0, 15)
        end
        return
    end

    -- Detection: near-or-at 180 for INV_HOLD seconds (airborne, no e-stop,
    -- not mid-auto-tune, cooldown elapsed).
    local inverted = math.abs(state.pitch) >= INV_ATT
        or math.abs(state.roll) >= INV_ATT
    if inverted and not self.landed and not self.estop
        and not self.tuning and self.inv_cooldown <= 0 then
        self.inv_time = self.inv_time + dt
        if self.inv_time >= INV_HOLD then
            self.inv_time = 0
            self.unflip = {
                t = 0,
                phase = "kick",
                cut = pickUnflipCut(state.pitch, state.roll),
            }
        end
    else
        self.inv_time = 0
    end
end

function Flight:finishUnflip()
    self.unflip = nil
    self.inv_time = 0
    self.inv_cooldown = INV_COOLDOWN
    self.hw.setLiftReverse(false)
    self.pid.pitch:reset()
    self.pid.roll:reset()
    self.pid.yaw:reset()
end

function Flight:emergencyStop()
    self.auto_land = false
    self.land_state = Flight.LAND_IDLE
    self.heading_valid = false
    self.targets.yaw_cmd = 0
    self.targets.speed = 0 -- do not retain a cruise speed target across e-stop
    self.estop = true
    self.tune_pending = false
    self.tune_requested = false
    self.unflip = nil       -- cutAllOutputs below also drops the reverse link
    self.inv_time = 0
    self.inv_cooldown = 0
    self.shutdown_request = nil
    if self.tuning then
        self:finishAutoTune(false, "e-stop")
    end
    self.hw.cutAllOutputs()
    self:cutPropsSoft()
    for _, pid in pairs(self.pid) do
        pid:reset()
    end
end

function Flight:requestAutoTune()
    if self.estop then
        self.tune_status = "e-stop active"
        return false, self.tune_status
    end
    if self.unflip then
        self.tune_status = "unflip active"
        return false, self.tune_status
    end
    if self.tuning then
        self.tune_status = "already tuning"
        return false, self.tune_status
    end
    if self.landed or self.mode ~= Flight.MODE_HOVER then
        -- wait until airborne HOVER (boot while grounded / wrong mode)
        self.tune_pending = true
        self.tune_requested = false
        self.tune_status = "waiting for air"
        return true, self.tune_status
    end
    self.tune_pending = false
    self.tune_requested = true
    self.tune_status = "queued"
    return true, "queued"
end

function Flight:beginAutoTune()
    local pid = self.pid.altitude
    pid:startAutoTune(
        function()
            -- live target: reads targets.altitude each tick (adjustAltitude
            -- is blocked while tuning, but auto-land also walks the target)
            return self.targets.altitude - self.state.altitude
        end,
        function(out)
            -- bang-bang altitude drive: map ±output_limit to 0..15 speed
            self.tune_speed = math.max(0, math.min(15, 7.5 + (out / pid.output_limit) * 7.5))
        end
    )
    self.tuning = true
    self.tune_requested = false
    self.tune_pending = false
    self.tune_status = "running"
end

function Flight:finishAutoTune(ok, msg)
    self.tuning = false
    self.tune_requested = false
    self.tune_pending = false
    self.tune_speed = 0
    self.tune_status = msg or (ok and "done" or "failed")
    self.pid.altitude:reset()
    self.pid.pitch:reset()
    self.pid.roll:reset()
    if self.onTuneComplete then
        pcall(self.onTuneComplete, ok)
    end
    return ok, self.tune_status
end

function Flight:getStatus()
    return {
        mode = self.mode,
        altitude = self.state.altitude,
        target_altitude = self.targets.altitude,
        pitch = self.state.pitch,
        roll = self.state.roll,
        yaw = self.state.yaw,
        heading_target = self.targets.yaw,
        heading_valid = self.heading_valid,
        yaw_rate = self.yaw_rate_dps,
        speed = self.state.speed,
        target_speed = self.targets.speed,
        climb_rate = self.state.climb_rate,
        outputs = self.outputs,
        landed = self.landed,
        gear_down = self.gear_down,
        auto_land = self.auto_land,
        land_state = self.land_state,
        proximity = self.proximity,
        sable_error = self.last_sable_error,
        tuning = self.tuning,
        tune_status = self.tune_status,
        estop = self.estop,
        unflip = self.unflip ~= nil,
        position = self.state.position,
        land_position = self.land_position,
        pid_gains = {
            altitude = self.pid.altitude:getGains(),
            pitch = self.pid.pitch:getGains(),
            roll = self.pid.roll:getGains(),
            yaw = self.pid.yaw:getGains(),
        },
    }
end

return Flight
