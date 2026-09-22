local PID = require("lib.pid")

local Flight = {}
Flight.__index = Flight

Flight.MODE_HOVER = "HOVER"
Flight.MODE_CRUISE = "CRUISE"

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
    }

    self.state = {
        altitude = 0,
        pitch = 0,
        roll = 0,
        yaw = 0,
        speed = 0,
        climb_rate = 0,
    }

    self.outputs = {
        speed = 0,
        tilt_fwd = 0,
        tilt_bwd = 0,
        rear_fw = 0,
        rear_bw = 0,
    }

    self.last_update = os.clock()
    self.update_count = 0
    self.tick_rate = 0.05

    self.tune_requested = false

    return self
end

function Flight:setMode(mode)
    if mode == self.mode then return end

    local old_mode = self.mode
    self.mode = mode

    for _, pid in pairs(self.pid) do
        pid:reset()
    end

    if mode == Flight.MODE_HOVER then
        self.targets.altitude = self.state.altitude
        self.targets.yaw = self.state.yaw
    end

    return true, old_mode, mode
end

function Flight:toggleMode()
    if self.mode == Flight.MODE_HOVER then
        return self:setMode(Flight.MODE_CRUISE)
    else
        return self:setMode(Flight.MODE_HOVER)
    end
end

function Flight:updateState()
    local state = self.hw.getShipState()
    self.state.altitude = state.altitude
    self.state.pitch = state.pitch
    self.state.roll = state.roll
    self.state.yaw = state.yaw
    self.state.speed = state.speed
    self.state.climb_rate = state.climb_rate
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

    elseif self.mode == Flight.MODE_CRUISE then
        local turn_rate = 2.0
        if keys.A and keys.A > 0 then
            self.targets.yaw = self.targets.yaw - turn_rate
        elseif keys.D and keys.D > 0 then
            self.targets.yaw = self.targets.yaw + turn_rate
        end

        while self.targets.yaw > 180 do self.targets.yaw = self.targets.yaw - 360 end
        while self.targets.yaw < -180 do self.targets.yaw = self.targets.yaw + 360 end
    end
end

function Flight:update()
    local now = os.clock()
    local dt = now - self.last_update
    self.last_update = now
    self.update_count = self.update_count + 1

    self:updateState()

    if self.mode == Flight.MODE_HOVER then
        self:updateHover(dt)
    elseif self.mode == Flight.MODE_CRUISE then
        self:updateCruise(dt)
    end

    self:applyOutputs()

    return self.outputs
end

function Flight:updateHover(dt)
    local state = self.state
    local targets = self.targets

    local alt_output = self.pid.altitude:update(targets.altitude, state.altitude, dt)

    local pitch_target = targets.move_forward * 3
    local pitch_output = self.pid.pitch:update(pitch_target, state.pitch, dt)

    local roll_target = targets.move_right * 3
    local roll_output = self.pid.roll:update(roll_target, state.roll, dt)

    local yaw_output = self.pid.yaw:update(targets.yaw, state.yaw, dt)

    local base_speed = math.max(0, math.min(15, 8 + alt_output))

    local pitch_tilt = math.max(-10, math.min(10, pitch_output))
    local roll_tilt = math.max(-10, math.min(10, roll_output))

    self.outputs.speed = base_speed

    self.outputs.FL_tilt = pitch_tilt + roll_tilt
    self.outputs.FR_tilt = pitch_tilt - roll_tilt
    self.outputs.RL_tilt = -pitch_tilt + roll_tilt
    self.outputs.RR_tilt = -pitch_tilt - roll_tilt

    self.outputs.rear_fw = math.max(0, math.min(8, 4 + yaw_output))
    self.outputs.rear_bw = math.max(0, math.min(8, 4 - yaw_output))
end

function Flight:updateCruise(dt)
    local state = self.state
    local targets = self.targets

    local alt_output = self.pid.altitude:update(targets.altitude, state.altitude, dt)
    local base_speed = math.max(0, math.min(15, 8 + alt_output))

    local yaw_output = self.pid.yaw:update(targets.yaw, state.yaw, dt)

    self.outputs.speed = base_speed
    self.outputs.FL_tilt = 0
    self.outputs.FR_tilt = 0
    self.outputs.RL_tilt = 0
    self.outputs.RR_tilt = 0

    self.outputs.rear_fw = math.max(0, math.min(15, 12 + yaw_output))
    self.outputs.rear_bw = math.max(0, math.min(15, 12 - yaw_output))
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
    self.hw.cutAllOutputs()
    self.outputs = {
        speed = 0, tilt_fwd = 0, tilt_bwd = 0,
        FL_tilt = 0, FR_tilt = 0, RL_tilt = 0, RR_tilt = 0,
        rear_fw = 0, rear_bw = 0,
    }
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
        speed = self.state.speed,
        climb_rate = self.state.climb_rate,
        outputs = self.outputs,
        pid_gains = {
            altitude = self.pid.altitude:getGains(),
            pitch = self.pid.pitch:getGains(),
            roll = self.pid.roll:getGains(),
            yaw = self.pid.yaw:getGains(),
        },
    }
end

return Flight
