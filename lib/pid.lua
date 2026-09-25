local PID = {}
PID.__index = PID

function PID.new(cfg)
    local self = setmetatable({}, PID)
    self.kp = cfg.kp or 1.0
    self.ki = cfg.ki or 0.0
    self.kd = cfg.kd or 0.0
    self.integral_limit = cfg.integral_limit or 10
    self.output_limit = cfg.output_limit or 15
    -- Derivative on measurement (e.g. climb rate) avoids setpoint-step kicks
    self.d_on_measurement = not not cfg.d_on_measurement
    -- Only integrate while |error| is within this band (anti-windup); nil = always
    self.integral_separation = cfg.integral_separation

    self.integral = 0
    self.prev_error = 0
    self.prev_time = nil

    self.tuning = false
    self.tune_phase = 0
    self.tune_output = 0
    self.tune_time = 0
    self.tune_duration = 5
    self.tune_crossings = 0
    self.tune_cross_times = {}
    self.tune_periods = {}
    self.tune_amplitudes = {}
    self.tune_max_error = 0

    self.gains_history = {}
    self.error_history = {}
    self.max_history = 100

    return self
end

function PID:update(setpoint, current, dt, meas_rate)
    if dt <= 0 then return 0 end

    local error = setpoint - current

    table.insert(self.error_history, { time = os.clock(), error = error })
    if #self.error_history > self.max_history then
        table.remove(self.error_history, 1)
    end

    local p = self.kp * error

    local sep = self.integral_separation
    if not sep or math.abs(error) <= sep then
        self.integral = self.integral + error * dt
        self.integral = math.max(-self.integral_limit, math.min(self.integral_limit, self.integral))
    end
    local i = self.ki * self.integral

    local d
    if self.d_on_measurement and meas_rate then
        -- d(error)/dt = -d(current)/dt when setpoint is held
        d = -self.kd * meas_rate
    else
        local derivative = 0
        if self.prev_time then
            derivative = (error - self.prev_error) / dt
        end
        d = self.kd * derivative
    end

    self.prev_error = error
    self.prev_time = os.clock()

    local output = p + i + d
    output = math.max(-self.output_limit, math.min(self.output_limit, output))

    return output, { p = p, i = i, d = d, error = error }
end

function PID:reset()
    self.integral = 0
    self.prev_error = 0
    self.prev_time = nil
end

function PID:setGains(kp, ki, kd)
    self.kp = kp
    self.ki = ki
    self.kd = kd
    table.insert(self.gains_history, { kp = kp, ki = ki, kd = kd })
end

function PID:getGains()
    return { kp = self.kp, ki = self.ki, kd = self.kd }
end

function PID:startAutoTune(get_error, set_output)
    self.tuning = true
    self.tune_phase = 1
    self.tune_time = 0
    self.tune_crossings = 0
    self.tune_cross_times = {}
    self.tune_periods = {}
    self.tune_amplitudes = {}
    self.tune_max_error = 0
    self.tune_get_error = get_error
    self.tune_set_output = set_output
    self.tune_prev_error = get_error()

    -- Start driving toward the target: error > 0 means below target, need thrust
    self.tune_output = (self.tune_prev_error > 0)
        and self.output_limit or -self.output_limit
    set_output(self.tune_output)
end

function PID:updateAutoTune(dt)
    if not self.tuning then return true, false end

    local error = self.tune_get_error()
    self.tune_time = self.tune_time + dt

    if self.tune_phase == 1 then
        if math.abs(error) > self.tune_max_error then
            self.tune_max_error = math.abs(error)
        end

        local prev_error = self.tune_prev_error
        if prev_error and (prev_error > 0) ~= (error > 0) and math.abs(error) > 0.1 then
            self.tune_crossings = self.tune_crossings + 1
            table.insert(self.tune_cross_times, self.tune_time)

            -- Zero crossings alternate direction: a full period spans
            -- crossing N to crossing N+2 (same direction).
            local n = #self.tune_cross_times
            if n >= 3 and n % 2 == 1 then
                local period = self.tune_cross_times[n] - self.tune_cross_times[n - 2]
                if period > 0.05 then
                    table.insert(self.tune_periods, period)
                end
            end

            self.tune_output = (error > 0)
                and self.output_limit or -self.output_limit
            self.tune_set_output(self.tune_output)
        end
        self.tune_prev_error = error

        if #self.tune_periods >= 2 or self.tune_time >= self.tune_duration then
            self.tune_phase = 2
        end
    end

    if self.tune_phase == 2 then
        local success = false
        if #self.tune_periods > 0 and self.tune_max_error > 0.1 then
            local avg_period = 0
            for _, p in ipairs(self.tune_periods) do
                avg_period = avg_period + p
            end
            avg_period = avg_period / #self.tune_periods

            local Ku = (4 * self.output_limit) / (math.pi * self.tune_max_error)
            local Tu = avg_period

            self:setGains(
                0.6 * Ku,
                2 * 0.6 * Ku / Tu,
                0.6 * Ku * Tu / 8
            )

            print("[PID] Auto-tune complete:")
            print("  Ku=" .. string.format("%.3f", Ku) .. " Tu=" .. string.format("%.3f", Tu))
            print("  Kp=" .. string.format("%.3f", self.kp) ..
                  " Ki=" .. string.format("%.3f", self.ki) ..
                  " Kd=" .. string.format("%.3f", self.kd))
            success = true
        else
            print("[PID] Auto-tune failed: not enough oscillations detected")
        end

        self.tuning = false
        self.tune_set_output(0)
        return true, success
    end

    return false
end

function PID:isTuning()
    return self.tuning
end

function PID:adaptGains(dt)
    if self.tuning then return end
    if #self.error_history < 20 then return end

    local sign_changes = 0
    for i = 2, #self.error_history do
        local prev = self.error_history[i-1].error
        local curr = self.error_history[i].error
        if (prev > 0) ~= (curr > 0) then
            sign_changes = sign_changes + 1
        end
    end

    local oscillation_ratio = sign_changes / #self.error_history

    if oscillation_ratio > 0.6 then
        self.kp = self.kp * 0.98
    elseif oscillation_ratio < 0.1 then
        local avg_error = 0
        for _, e in ipairs(self.error_history) do
            avg_error = avg_error + math.abs(e.error)
        end
        avg_error = avg_error / #self.error_history
        if avg_error > 0.5 then
            self.ki = self.ki * 1.02
        end
    end
end

function PID:serialize()
    return {
        kp = self.kp,
        ki = self.ki,
        kd = self.kd,
    }
end

return PID
