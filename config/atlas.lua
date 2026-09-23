return {
    name = "Atlas",
    version = "1.1",

    -- Offset of computer from center of mass (in blocks)
    -- Positive X = right, Positive Y = up, Positive Z = forward
    computer_offset = { x = 0, y = 6, z = 56 },

    -- Wired network device names
    peripherals = {
        -- Input relays (typewriter / redstone link receivers)
        input_1 = "relay_1",  -- WASD
        input_2 = "relay_2",  -- Q/E (yaw)
        aux_relay = "relay_aux", -- shift + gear + proximity (assign at boot)

        -- Output relays (propeller transmitter links)
        output_FL = "relay_3",
        output_FR = "relay_4",
        output_RL = "relay_5",
        output_RR = "relay_6",
        output_REAR = "relay_7",

        main_monitor = "main_monitor",
        -- speaker = "speaker_0",
    },

    -- Which side of each input relay has which key's link
    input_map = {
        input_1 = {
            W = "front",
            S = "back",
            A = "left",
            D = "right",
        },
        input_2 = {
            Q = "front", -- yaw left (FL/RL bwd, FR/RR fwd)
            E = "back",  -- yaw right
        },
        aux_relay = {
            SHIFT = "left",   -- mode toggle (rising edge)
            PROX = "back",    -- proximity sensor 0-15, 15 = on ground
        },
    },

    -- Same aux relay: front face drives landing gear deploy emitter
    gear_output = {
        relay = "aux_relay",
        side = "front",
        deploy = 15,
        retract = 0,
    },

    -- Proximity: signal strength (0-15), stronger = closer.
    -- 15 = touching ground, 14 = ~1 block above, 0 = far/no detection
    proximity = {
        input_key = "aux_relay",
        side = "back",
        landed_threshold = 15,
        gear_deploy_threshold = 1, -- deploy gear when ground in range (manual land)
        max_blocks = 15,
    },

    output_map = {
        FL   = { relay = "output_FL", tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        FR   = { relay = "output_FR", tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        RL   = { relay = "output_RL", tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        RR   = { relay = "output_RR", tilt_fwd = "front", tilt_bwd = "back", speed = "right" },
        REAR = { relay = "output_REAR", fw = "front", bw = "back" },
    },

    -- Propeller positions relative to center of mass (in blocks)
    -- BL/BR in controls = rear-left/rear-right (RL/RR)
    propellers = {
        FL = { x = -3, y = 0, z = 3 },
        FR = { x = 3,  y = 0, z = 3 },
        RL = { x = -3, y = 0, z = -3 },
        RR = { x = 3,  y = 0, z = -3 },
    },

    limits = {
        max_speed = 80,
        max_altitude = 320,
        min_altitude = 0,
        max_tilt = 15,
        max_climb_rate = 10,
        max_descent_rate = 5,
        hover_speed = 2,
        -- signed tilt command range (redstone scale applied later)
        tilt_max = 12,
        -- prop speed when airborne hover idle (0 = fully reduced when landed)
        hover_min_speed = 0,
        hover_max_speed = 15,
        -- auto-land descent rate blocks/s
        land_descent_rate = 0.8,
        -- altitude step for Space/Control (blocks)
        alt_step = 2,
        -- rear thruster cruise base
        cruise_rear = 12,
    },

    fuel = {
        type = "charcoal",
        smelt_time = 80,
        items_per_smelt = 8,
        tank_capacity = 12960,
    },

    pid = {
        altitude = { kp = 1.2, ki = 0.15, kd = 0.6, integral_limit = 10 },
        pitch    = { kp = 2.0, ki = 0.0, kd = 1.0, integral_limit = 5 },
        roll     = { kp = 2.0, ki = 0.0, kd = 1.0, integral_limit = 5 },
        -- yaw uses wrapped heading error + gyro rate damp (see flight:rotationControl)
        yaw      = { kp = 2.2, ki = 0.0, kd = 1.4, integral_limit = 5, output_limit = 15 },
    },

    signal = {
        max = 15,
        min = 0,
    },

    -- Optional peripherals assigned at boot if missing
    optional_peripherals = { "aux_relay" },
}
