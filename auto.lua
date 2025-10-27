local rbmk = require("rbmk")
local reactor = rbmk.create()
local monitor = peripheral.wrap("monitor_0") -- Adjust the monitor name as needed

-- Function to print reactor status to the monitor
local function update_monitor()
    while true do
        local rep = reactor:report()
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.write(string.format("t=%.0f s | T=%.1f C | rods=%.1f%% | water=%.1f | steam=%.1f | rpm=%.0f | V=%.1f",
            rep.time, rep.core_temp, rep.control_rods, rep.water, rep.steam, rep.turbine_rpm, rep.grid_voltage))
        sleep(5) -- Update every 5 seconds
    end
end

-- Manual control function
local function manual_control()
    while true do
        print("Manual Control: Enter command (set rods, set load, set pitch, exit):")
        local command = io.read()

        if command == "exit" then
            break
        elseif command:match("set rods (%d+)") then
            local rods = tonumber(command:match("set rods (%d+)"))
            reactor:setControlRods(math.clamp(rods, 0, 100))
        elseif command:match("set load (%d+)") then
            local load = tonumber(command:match("set load (%d+)"))
            reactor:setGeneratorLoad(math.clamp(load, 0, 100))
        elseif command:match("set pitch (%d+)") then
            local pitch = tonumber(command:match("set pitch (%d+)"))
            reactor:setTurbinePitch(math.clamp(pitch, 0, 100))
        else
            print("Invalid command. Please try again.")
        end
    end
end

-- Start monitor updating in parallel

-- Control step function
local function control_step()
    local state = reactor:report()

    -- if voltage low -> increase generation: withdraw rods (lower percent)
    if state.grid_voltage < reactor._config.grid_nominal_voltage * 0.98 then
        reactor:setControlRods(math.max(0, state.control_rods - 1))
        reactor:setGeneratorLoad(100)
    elseif state.grid_voltage > reactor._config.grid_nominal_voltage * 1.02 then
        reactor:setControlRods(math.min(100, state.control_rods + 1))
        reactor:setGeneratorLoad(50)
    end

    -- if core temp too high reduce reactivity and increase pumps
    if state.core_temp > reactor._config.max_core_temp * 0.9 then
        reactor:setControlRods(math.min(100, state.control_rods + 5))
        reactor:setPumpPower(100)
    elseif state.core_temp < reactor._config.max_core_temp * 0.6 then
        reactor:setPumpPower(80)
    end

    -- Ramp turbine pitch with steam available
    if state.steam > reactor._config.steam_capacity * 0.3 then
        reactor:setTurbinePitch(100)
    else
        reactor:setTurbinePitch(30)
    end

    -- if pressure high or meltdown predicted, scram
    if state.pressure > reactor._config.pressure_safe * 0.95 or state.core_temp > reactor._config.meltdown_temp * 0.9 then
        reactor:scram()
    end
end

-- Main loop: run small ticks and control
parallel.waitForAny(update_monitor, manual_control)
while true do
    reactor:tick(1) -- advance 1 second
    control_step()
    sleep(0.1)
end
