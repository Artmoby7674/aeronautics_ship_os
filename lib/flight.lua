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
        move_right = 0,
        yaw_cmd = 0,
        speed = 0, -- cruise speed target (W/S ramps it)
    }

    self.cruise_rear_hold = nil -- rear thrust that holds target speed (nil = not yet known)
    self.estop = false        -- latched by X until reset (R / altitude / mode)

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
        pitch_rate = 0,
        roll_rate = 0,
        yaw_rate = 0,
    }

    -- signed tilt (translation/yaw) + per-prop thrust 0..15 (altitude + attitude)
    self.outputs = {
        speed = 0,
        FL_speed = 0, FR_speed = 0, RL_speed = 0, RR_speed = 0,
        FL_tilt = 0, FR_tilt = 0, RL_tilt = 0, RR_tilt = 0,
        rear_fw = 0, rear_bw = 0,
        -- legacy aliases used by HUD
        tilt_fwd = 0, tilt_bwd = 0,
    }

    self.landed = false
    self.gear_down = false
    self.gear_settle = 0
    self.auto_land = false
    self.land_state = Flight.LAND_IDLE
    self.proximity = 0
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
        self.targets.speed = self.state.speed
        self.cruise_rear_hold = nil -- seed from PID on first cruise tick
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
    self.state.angularVelocity = state.angularVelocity or { x = 0, y = 0, z = 0 }
    -- Create Avionics body rates: wx=pitch, wy=yaw, wz=roll
    self.state.pitch_rate = rateDps(self.state.angularVelocity.x)
    self.state.yaw_rate = rateDps(self.state.angularVelocity.y)
    self.state.roll_rate = rateDps(self.state.angularVelocity.z)
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
    local can_strafe = self:hasFeature("strafe")

    if self.mode == Flight.MODE_HOVER then
        local move_speed = limits.hover_speed

        if keys.W and keys.W > 0 then
            self.targets.move_forward = move_speed
        elseif keys.S and keys.S > 0 then
            self.targets.move_forward = -move_speed
        else
            self.targets.move_forward = 0
        end

        -- A/D only when the ship actually has lateral thrusters
        if can_strafe then
            if keys.A and keys.A > 0 then
                self.targets.move_right = -move_speed
            elseif keys.D and keys.D > 0 then
                self.targets.move_right = move_speed
            else
                self.targets.move_right = 0
            end
        else
            self.targets.move_right = 0
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

        -- W/S ramps horizontal speed target; release holds it
        local limits = self.config.limits or {}
        local ramp = (limits.cruise_ramp or 8) * self.tick_rate
        local smax = limits.max_speed or 80
        if keys.W and keys.W > 0 then
            self.targets.speed = clamp((self.targets.speed or 0) + ramp, 0, smax)
        elseif keys.S and keys.S > 0 then
            self.targets.speed = clamp((self.targets.speed or 0) - ramp, 0, smax)
        end

        self.targets.move_forward = 0
        self.targets.move_right = 0
    end
end

-- Rotation stabilizer:
--  - Pilot stick: rate command + gyro damp, integrates heading hold target
--  - Stick centered: hold capture heading with wrapped-error PID + rate damp
--  - Returns prop yaw tilt (-tilt_max..tilt_max) and rear assist (-1..1)
function Flight:rotationControl(dt, yaw_stick, tilt_max)
    local state = self.state
    local rate = self.yaw_rate_dps
    local rear = 0
    local yaw_tilt = 0

    if math.abs(yaw_stick) > 0.05 then
        -- Rate command while stick held (deg/s), damp toward that rate
        local rate_target = yaw_stick * 35
        local rate_err = rate_target - rate
        local damp = clamp(rate_err / 45, -1, 1) * tilt_max * 0.4
        local direct = yaw_stick * tilt_max * 0.6
        yaw_tilt = clamp(direct + damp, -tilt_max, tilt_max)
        rear = clamp(yaw_stick * 0.85 + clamp(rate_err / 80, -0.3, 0.3), -1, 1)

        -- Keep hold target tracking so release does not snap
        if not self.heading_valid then
            self:captureHeading()
        end
        self.targets.yaw = wrapDeg(self.targets.yaw + yaw_stick * 30 * dt)
        self.pid.yaw:reset()
        return yaw_tilt, rear
    end

    -- Hands-off: no prop-tilt stabilisation (tilt is piloting-only for now;
    -- heading autopilot via tilt may come later). Rear differential still
    -- tracks heading in cruise (hover forces rear off elsewhere).
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

    local out = clamp(p + i + d, -pid.output_limit, pid.output_limit)
    yaw_tilt = 0
    rear = clamp(out / pid.output_limit, -1, 1)

    -- Deadband: avoid micro-wiggle when nearly on heading and still
    if math.abs(err) < 0.35 and math.abs(rate) < 1.5 then
        yaw_tilt = 0
        rear = 0
        pid.integral = pid.integral * 0.9
    end

    return yaw_tilt, rear
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

    -- Ground contact (ignore brief proximity spike while gear is deploying)
    -- Gearless ships: no gear to settle, so ground contact is immediate
    local gear_ready = (not self:hasFeature("gear"))
        or (self.gear_down and (not self.gear_settle or self.gear_settle <= 0))
    if self.proximity >= landed_thr and gear_ready then
        if not self.landed then
            self.landed = true
            if self.land_state == Flight.LAND_DESCEND or self.land_state == Flight.LAND_ARMED then
                self.land_state = Flight.LAND_TOUCH
            elseif self.land_state == Flight.LAND_IDLE then
                self.land_state = Flight.LAND_DONE
            end
        end
    else
        if self.landed and self.proximity < (landed_thr - 1) and self.targets.altitude > self.state.altitude + 1 then
            -- climbing away
            self.landed = false
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

    if self.land_state == Flight.LAND_DESCEND then
        local rate = (self.config.limits and self.config.limits.land_descent_rate) or 0.8
        self.targets.altitude = self.targets.altitude - rate * dt
        if self.targets.altitude < 0 then
            self.targets.altitude = 0
        end
        if not self.heading_valid then
            self:captureHeading()
        end
    end

    if self.land_state == Flight.LAND_TOUCH then
        self.landed = true
        self.land_state = Flight.LAND_DONE
        self.targets.altitude = self.state.altitude
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
        return
    end

    -- Sticks as -1..1
    local fwd = 0
    if targets.move_forward > 0 then fwd = 1
    elseif targets.move_forward < 0 then fwd = -1 end

    local can_strafe = self:hasFeature("strafe")
    local lat = 0
    if can_strafe then
        if targets.move_right > 0 then lat = 1
        elseif targets.move_right < 0 then lat = -1 end
    else
        targets.move_right = 0
    end

    local yaw_stick = targets.yaw_cmd or 0

    -- Tilt is direct piloting only (W/S collective, Q/E yaw, A/D if strafe).
    -- Sign flipped: W (forward) was pushing the ship backward.
    local collective = -fwd * tilt_max
    local strafe_tilt = lat * tilt_max

    local yaw_tilt = self:rotationControl(dt, yaw_stick, tilt_max)

    local FL_tilt = clamp(collective + yaw_tilt + strafe_tilt, -tilt_max, tilt_max)
    local FR_tilt = clamp(collective - yaw_tilt - strafe_tilt, -tilt_max, tilt_max)
    local RL_tilt = clamp(collective + yaw_tilt - strafe_tilt, -tilt_max, tilt_max)
    local RR_tilt = clamp(collective - yaw_tilt + strafe_tilt, -tilt_max, tilt_max)

    -- Altitude only: uniform prop speed (no attitude speed control).
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
    self:setUniformSpeed(base_speed)
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
    local tilt_max = limits.tilt_max or 12
    local yaw_stick = targets.yaw_cmd or 0
    local hover = limits.hover_throttle or 6
    local hmin = limits.hover_min_speed or 0
    local hmax = limits.hover_max_speed or 15

    if self.landed and not self.auto_land
        and not (targets.altitude > state.altitude + 0.5) then
        return
    end

    if not self.heading_valid then
        self:captureHeading()
    end

    -- Rear differential gives yaw assist (prop tilt not used for heading hold)
    local _, rear_cmd = self:rotationControl(dt, yaw_stick, tilt_max)

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

    -- Horizontal speed PID toward targets.speed. Inside the deadband keep
    -- the last thrust that held the speed (nil = never computed yet →
    -- run the PID once to seed it; do not substitute a fixed base thrust,
    -- which caused a 0↔rear_base limit cycle).
    local sdb = limits.cruise_speed_deadband or 1.5
    local serr = (targets.speed or 0) - state.speed
    local rear_thrust
    if math.abs(serr) < sdb then
        rear_thrust = self.cruise_rear_hold
        if rear_thrust == nil then
            rear_thrust = clamp(self.pid.speed:update(targets.speed, state.speed, dt), 0, 15)
            self.cruise_rear_hold = rear_thrust
        end
    else
        rear_thrust = clamp(self.pid.speed:update(targets.speed, state.speed, dt), 0, 15)
        self.cruise_rear_hold = rear_thrust
    end

    -- rear_cmd -1..1 adds differential thrust on top of speed-hold thrust
    local fw = clamp(rear_thrust + rear_cmd * 6, 0, 15)
    local bw = clamp(rear_thrust - rear_cmd * 6, 0, 15)
    self.outputs.rear_fw = fw
    self.outputs.rear_bw = bw
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
        pid_gains = {
            altitude = self.pid.altitude:getGains(),
            pitch = self.pid.pitch:getGains(),
            roll = self.pid.roll:getGains(),
            yaw = self.pid.yaw:getGains(),
        },
    }
end

return Flight
