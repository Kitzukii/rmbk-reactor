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

manual_control()
local rbmk = require("rbmk")
local reactor = rbmk.create()

-- Simple monitor printing
reactor:on("update", function(s)
  if math.floor(s.time) % 5 == 0 then
    local rep = reactor:report()
    print(string.format("t=%.0f s | T=%.1f C | rods=%.1f%% | water=%.1f | steam=%.1f | rpm=%.0f | V=%.1f",
      rep.time, rep.core_temp, rep.control_rods, rep.water, rep.steam, rep.turbine_rpm, rep.grid_voltage))
  end
  if s.meltdown then
    local ori = term.getTextColor()
    term.setTextColor(colors.red)
    print("!!! MELTDOWN in progress !!!")
    print("!!! SCRAM asap !!!")
    term.setTextColor(ori)
  end
end)

-- Example policy:
-- Maintain grid voltage near nominal by adjusting rods slowly and turbine/generator
local target_voltage = reactor._config.grid_nominal_voltage
local function control_step()
  local state = reactor:report()

  -- if voltage low -> increase generation: withdraw rods (lower percent)
  if state.grid_voltage < target_voltage * 0.98 then
    reactor:setControlRods(math.max(0, state.control_rods - 1))
    reactor:setGeneratorLoad(100)
  elseif state.grid_voltage > target_voltage * 1.02 then
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
while true do
  reactor:tick(1) -- advance 1 second
  control_step()
  sleep(0.1)
end
