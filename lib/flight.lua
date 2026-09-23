local PID = require("lib.pid")

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

-- Ship angular velocity Y -> deg/s (Sable commonly reports rad/s)
local function yawRateDps(av)
    if not av or type(av.y) ~= "number" then return 0 end
    local v = av.y
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
    }

    self.targets = {
        altitude = 0,
        pitch = 0,
        roll = 0,
        yaw = 0,
        move_forward = 0,
        move_right = 0,
        yaw_cmd = 0,
    }

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
    }

    -- signed tilt commands before split to fwd/bwd channels (-tilt_max..+tilt_max)
    self.outputs = {
        speed = 0,
        FL_tilt = 0, FR_tilt = 0, RL_tilt = 0, RR_tilt = 0,
        rear_fw = 0, rear_bw = 0,
        -- legacy aliases used by HUD
        tilt_fwd = 0, tilt_bwd = 0,
    }

    self.landed = false
    self.gear_down = false
    self.auto_land = false
    self.land_state = Flight.LAND_IDLE
    self.proximity = 0
    self.shift_level = 0
    self.shift_armed = true -- allow next toggle after release

    self.last_update = os.clock()
    self.update_count = 0
    self.tick_rate = 0.05
    self.tune_requested = false
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

    for _, pid in pairs(self.pid) do
        pid:reset()
    end

    self.targets.altitude = self.state.altitude
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
    self.targets.altitude = self.targets.altitude + delta
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
        self.gear_down = true
        self.hw.setGear(true)
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
    self.yaw_rate_dps = yawRateDps(self.state.angularVelocity)
    if state.sable_error then
        self.last_sable_error = state.sable_error
    end
    return state
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

        if keys.A and keys.A > 0 then
            self.targets.move_right = -move_speed
        elseif keys.D and keys.D > 0 then
            self.targets.move_right = move_speed
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

    -- Hands-off heading hold
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
    yaw_tilt = clamp((out / pid.output_limit) * tilt_max, -tilt_max, tilt_max)
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
    local now = os.clock()
    local dt = now - self.last_update
    self.last_update = now
    self.update_count = self.update_count + 1
    if dt > 0.5 then dt = 0.05 end

    self:updateState()

    self.proximity = self.hw.getProximity() or 0
    local prox_cfg = self.config.proximity or {}
    local landed_thr = prox_cfg.landed_threshold or 15
    local gear_thr = prox_cfg.gear_deploy_threshold or 1

    -- Manual gear deploy when ground comes into range (not already deployed)
    if not self.gear_down and self.proximity >= gear_thr then
        self.gear_down = true
        self.hw.setGear(true)
    end

    -- Ground contact detection
    if self.proximity >= landed_thr then
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

    if self.mode == Flight.MODE_HOVER then
        self:updateHover(dt)
    elseif self.mode == Flight.MODE_CRUISE then
        self:updateCruise(dt)
    end

    self:updateAutoLand(dt)

    if self.landed and not self.auto_land then
        -- fully reduced props when parked (unless pilot already commanded climb)
        local climbing = self.targets.altitude > self.state.altitude + 0.5
        if not climbing then
            self:cutPropsSoft()
        end
    end

    self:applyOutputs()
    return self.outputs
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
        if self.proximity >= (self.config.proximity.landed_threshold or 15) then
            self.land_state = Flight.LAND_TOUCH
        else
            self.land_state = Flight.LAND_DESCEND
            -- start slightly above current and walk target down
            self.targets.altitude = self.state.altitude
        end
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
    self.outputs.FL_tilt = 0
    self.outputs.FR_tilt = 0
    self.outputs.RL_tilt = 0
    self.outputs.RR_tilt = 0
    self.outputs.rear_fw = 0
    self.outputs.rear_bw = 0
end

function Flight:updateHover(dt)
    local state = self.state
    local targets = self.targets
    local limits = self.config.limits
    local tilt_max = limits.tilt_max or 12

    -- Sticks as -1..1
    local fwd = 0
    if targets.move_forward > 0 then fwd = 1
    elseif targets.move_forward < 0 then fwd = -1 end

    local lat = 0
    if targets.move_right > 0 then lat = 1
    elseif targets.move_right < 0 then lat = -1 end

    local yaw_stick = targets.yaw_cmd or 0

    -- Direct mixes (precision control from pilot sticks)
    -- W/S: all props tilt together (collective pitch of thrust)
    local collective = fwd * tilt_max

    -- A/D strafe: bank via roll mix
    local strafe_tilt = lat * tilt_max

    -- Pitch/roll: track small attitude targets while stick held; level when idle
    local pitch_t = (fwd ~= 0) and (fwd * 4) or 0
    local roll_t = (lat ~= 0) and (lat * 4) or 0

    local pitch_auth = 1 - math.min(1, math.abs(fwd))
    local roll_auth = 1 - math.min(1, math.abs(lat))

    local pitch_out = self.pid.pitch:update(pitch_t, state.pitch, dt)
    local roll_out = self.pid.roll:update(roll_t, state.roll, dt)

    -- Gyro damp on pitch/roll when pilot is not commanding that axis
    local av = state.angularVelocity or {}
    local pitch_rate = av.x or 0
    local roll_rate = av.y or 0
    if math.abs(pitch_rate) <= (2 * math.pi + 0.75) then pitch_rate = math.deg(pitch_rate) end
    if math.abs(roll_rate) <= (2 * math.pi + 0.75) then roll_rate = math.deg(roll_rate) end
    -- roll rate around forward axis is typically z for ship frame; use both y/z blend
    local roll_rate_use = av.z or roll_rate
    if math.abs(av.z or 0) <= (2 * math.pi + 0.75) and av.z then roll_rate_use = math.deg(av.z) end

    local pitch_corr = (pitch_out - 0.15 * pitch_rate) * pitch_auth
    local roll_corr = (roll_out - 0.15 * roll_rate_use) * roll_auth

    -- Rotation stability (wrapped heading hold + rate damp)
    local yaw_tilt, rear_cmd = self:rotationControl(dt, yaw_stick, tilt_max)

    -- Prop tilt mix (BL/BR = rear props RL/RR)
    -- Q (stick=-1): FL-,FR+,RL-,RR+   E (stick=+1): opposite
    -- D(right): FL+,FR-,RL-,RR+        A(left): opposite
    local FL = collective + yaw_tilt + strafe_tilt + pitch_corr + roll_corr
    local FR = collective - yaw_tilt - strafe_tilt + pitch_corr - roll_corr
    local RL = collective + yaw_tilt - strafe_tilt - pitch_corr + roll_corr
    local RR = collective - yaw_tilt + strafe_tilt - pitch_corr - roll_corr

    FL = clamp(FL, -tilt_max, tilt_max)
    FR = clamp(FR, -tilt_max, tilt_max)
    RL = clamp(RL, -tilt_max, tilt_max)
    RR = clamp(RR, -tilt_max, tilt_max)

    -- Altitude PID -> prop speed (0 when landed and not climbing)
    local alt_output = self.pid.altitude:update(targets.altitude, state.altitude, dt)
    local base_speed = 0
    if not self.landed then
        base_speed = clamp(alt_output, 0, 15)
        if base_speed < 2 and not self.auto_land then
            base_speed = 2
        end
    else
        if targets.altitude > state.altitude + 0.5 then
            base_speed = clamp(alt_output, 0, 15)
        else
            base_speed = 0
            FL, FR, RL, RR = 0, 0, 0, 0
            self.pid.altitude:reset()
        end
    end

    if self.auto_land and self.land_state == Flight.LAND_DESCEND then
        base_speed = clamp(3 + alt_output * 0.3, 0, 6)
    end

    self.outputs.speed = base_speed
    self.outputs.FL_tilt = FL
    self.outputs.FR_tilt = FR
    self.outputs.RL_tilt = RL
    self.outputs.RR_tilt = RR
    self.outputs.tilt_fwd = math.max(0, collective)
    self.outputs.tilt_bwd = math.max(0, -collective)

    -- Rear thrusters follow the same signed rotation command (no fight)
    if self.landed then
        self.outputs.rear_fw = 0
        self.outputs.rear_bw = 0
    elseif rear_cmd > 0.02 then
        self.outputs.rear_fw = clamp(rear_cmd * 8, 0, 8)
        self.outputs.rear_bw = 0
    elseif rear_cmd < -0.02 then
        self.outputs.rear_fw = 0
        self.outputs.rear_bw = clamp(-rear_cmd * 8, 0, 8)
    else
        self.outputs.rear_fw = 0
        self.outputs.rear_bw = 0
    end
end

function Flight:updateCruise(dt)
    local state = self.state
    local targets = self.targets
    local limits = self.config.limits
    local tilt_max = limits.tilt_max or 12
    local yaw_stick = targets.yaw_cmd or 0

    if not self.heading_valid then
        self:captureHeading()
    end

    -- Same rotation stabilizer as hover; rear thrusters provide cruise thrust + yaw assist
    local _, rear_cmd = self:rotationControl(dt, yaw_stick, tilt_max)

    local alt_output = self.pid.altitude:update(targets.altitude, state.altitude, dt)

    local base_speed = 0
    if not self.landed then
        base_speed = clamp(8 + alt_output, 0, 15)
    elseif targets.altitude > state.altitude + 0.5 then
        base_speed = clamp(alt_output, 0, 15)
    else
        base_speed = 0
        self.pid.altitude:reset()
    end

    self.outputs.speed = base_speed
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

    local rear_base = limits.cruise_rear or 12
    -- rear_cmd -1..1 adds differential thrust on top of cruise base
    local fw = clamp(rear_base + rear_cmd * 6, 0, 15)
    local bw = clamp(rear_base - rear_cmd * 6, 0, 15)
    self.outputs.rear_fw = fw
    self.outputs.rear_bw = bw
end

function Flight:applyOutputs()
    local hw = self.hw

    hw.setAllSpeed(self.outputs.speed)

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
    self.hw.cutAllOutputs()
    self.outputs = {
        speed = 0, tilt_fwd = 0, tilt_bwd = 0,
        FL_tilt = 0, FR_tilt = 0, RL_tilt = 0, RR_tilt = 0,
        rear_fw = 0, rear_bw = 0,
    }
    for _, pid in pairs(self.pid) do
        pid:reset()
    end
end

function Flight:requestAutoTune()
    self.tune_requested = true
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
        pid_gains = {
            altitude = self.pid.altitude:getGains(),
            pitch = self.pid.pitch:getGains(),
            roll = self.pid.roll:getGains(),
            yaw = self.pid.yaw:getGains(),
        },
    }
end

return Flight
