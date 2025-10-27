-- rbmk.lua
-- RBMK-like reactor simulation for CC:Tweaked (game simulation only)
-- Place in /rom/apis/rbmk.lua so `require("rbmk")` can find it.

local rbmk = {}
rbmk._VERSION = "0.9.0"

-- Utility: shallow copy
local function copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k,v in pairs(t) do r[k] = v end
  return r
end

-- Default parameters (tweakable)
local DEFAULTS = {
  dt = 1, -- seconds per tick for the simulation (user tick step)
  core_mass = 1e6,         -- thermal inertia (arbitrary units)
  heat_capacity = 1.0,     -- heat capacity coefficient
  max_core_temp = 1000,    -- degrees C (fictional limit)
  ambient_temp = 20,
  decay_power = 0.002,     -- background decay when scrammed
  base_reactivity = 1.0,   -- base multiplier for reactor at 0% rods
  rod_effectiveness = 1.0, -- how much control rods reduce reactivity
  water_capacity = 1e5,    -- mass units of primary coolant
  steam_capacity = 5e4,    -- mass units for steam tank
  pump_max_flow = 2000,    -- units/sec when pumpPower == 100
  evaporation_const = 0.0005, -- heat->steam conversion factor
  turbine_max_rpm = 3600,
  turbine_efficiency = 0.35,  -- steam->mechanical->electric
  generator_max_output = 1e6, -- max grid power (watts) at 100% generator
  grid_nominal_voltage = 400, -- arbitrary units
  pressure_safe = 1200,     -- arbitrary units for safety trip
  meltdown_temp = 1200,     -- if core temp exceeds this, meltdown event
}

-- Reactor factory
function rbmk.create(opts)
  opts = opts or {}
  local p = copy(DEFAULTS)
  for k,v in pairs(opts) do p[k] = v end

  local self = {}

  -- Dynamic state variables
  self.core_temp = p.ambient_temp            -- degrees C
  self.reactor_power = 0                     -- instantaneous thermal power (arbitrary units)
  self.control_rods = 100                    -- percent inserted (100 = fully inserted, reactor OFF)
  self.pump_power = 100                      -- percent
  self.water = p.water_capacity * 0.9        -- current water mass
  self.steam = p.steam_capacity * 0.1        -- current steam mass
  self.turbine_rpm = 0
  self.turbine_pitch = 100                   -- pitch / inlet guide vanes percent
  self.generator_load = 0                    -- percent of generator setpoint (0-100)
  self.grid_load_kw = 0                      -- external load requested (game units)
  self.grid_voltage = p.grid_nominal_voltage
  self.scrammed = false
  self.meltdown = false
  self.pressure = 100                        -- arbitrary units
  self.time = 0

  -- Callbacks (monitoring)
  local callbacks = {
    update = {},   -- args: self
    alarm = {},    -- args: self, message
    trip = {},     -- args: self, reason
  }

  -- Helper: call callbacks
  local function fire(evt, ...)
    for _,cb in ipairs(callbacks[evt] or {}) do
      -- pcall to prevent user callback from crashing sim
      local ok, err = pcall(cb, ...)
      if not ok then
        -- ignore errors from callbacks
      end
    end
  end

  -- Public API: attach callbacks
  function self:on(event, fn)
    if not callbacks[event] then error("Unknown event: "..tostring(event)) end
    table.insert(callbacks[event], fn)
  end

  -- Public getters
  function self:getState()
    return {
      core_temp = self.core_temp,
      reactor_power = self.reactor_power,
      control_rods = self.control_rods,
      pump_power = self.pump_power,
      water = self.water,
      steam = self.steam,
      turbine_rpm = self.turbine_rpm,
      turbine_pitch = self.turbine_pitch,
      generator_load = self.generator_load,
      grid_load_kw = self.grid_load_kw,
      grid_voltage = self.grid_voltage,
      scrammed = self.scrammed,
      meltdown = self.meltdown,
      pressure = self.pressure,
      time = self.time,
    }
  end

  -- Controls (fully controllable by user)
  function self:setControlRods(percent) -- 0..100 (0 = fully withdrawn -> most reactive)
    self.control_rods = math.max(0, math.min(100, percent))
  end
  function self:setPumpPower(percent) -- 0..100
    self.pump_power = math.max(0, math.min(100, percent))
  end
  function self:setTurbinePitch(percent) -- 0..100 (guide vanes)
    self.turbine_pitch = math.max(0, math.min(100, percent))
  end
  function self:setGeneratorLoad(percent) -- 0..100 desired share of generator
    self.generator_load = math.max(0, math.min(100, percent))
  end
  function self:setGridLoad(kw) -- set external grid demand (game units)
    self.grid_load_kw = math.max(0, kw)
  end

  function self:scram()
    self.scrammed = true
    self:setControlRods(100) -- full insert
    fire("trip", self, "SCRAM")
  end
  function self:resetTrip()
    self.scrammed = false
    fire("alarm", self, "Trip reset")
  end

  -- persistence helpers
  function self:serialize()
    return textutils.serialize(self:getState())
  end
  function self:deserialize(s)
    local ok, t = pcall(textutils.unserialize, s)
    if ok and type(t) == "table" then
      for k,v in pairs(t) do
        if self[k] ~= nil then self[k] = v end
      end
      return true
    end
    return false
  end

  -- Internal physics tick
  function self:tick(dt)
    dt = dt or p.dt
    if self.meltdown then
      -- completely broken
      self.core_temp = self.core_temp + 10 * dt
      fire("update", self)
      self.time = self.time + dt
      return
    end

    -- 1) Reactivity & Thermal Power
    local rod_factor = 1 - (self.control_rods / 100) * p.rod_effectiveness -- 0..1
    local scram_factor = self.scrammed and 0 or 1
    local reactivity = p.base_reactivity * rod_factor * scram_factor
    -- reactor power (thermal) scales with reactivity and water moderation (more water -> better moderation)
    local water_density = math.max(0.01, self.water / p.water_capacity) -- 0..1
    self.reactor_power = reactivity * water_density * 1e5 -- arbitrary units of thermal power

    -- 2) Core temperature change from power in, heat removed by evaporation & pumps
    local heat_in = self.reactor_power * dt
    local pump_flow = (self.pump_power / 100) * p.pump_max_flow -- units/sec
    local water_flow = math.min(self.water, pump_flow * dt)

    -- Cooling caused by water flow (simplified)
    local cooling = water_flow * 0.5 -- coefficient
    -- Evaporation: convert heat to steam mass if core temp is high enough
    local evaporation = math.max(0, heat_in * p.evaporation_const)
    evaporation = math.min(evaporation, self.water) -- cannot evaporate more water than available

    -- Temperature update
    local dtemp = (heat_in - cooling) / (p.core_mass * p.heat_capacity)
    self.core_temp = self.core_temp + dtemp
    -- ambient heat loss
    self.core_temp = self.core_temp - (self.core_temp - p.ambient_temp) * 0.01 * dt

    -- 3) Transfer water->steam
    self.water = self.water - evaporation
    self.steam = math.min(p.steam_capacity, self.steam + evaporation)

    -- 4) Turbine: convert steam to mechanical/electricity
    -- Steam flow to turbine depends on turbine pitch and steam available
    local potential_steam_flow = (self.turbine_pitch / 100) * 1000 * dt -- units/sec simplified
    local steam_to_turbine = math.min(self.steam, potential_steam_flow)
    self.steam = self.steam - steam_to_turbine

    -- Turbine RPM responds to steam and load
    local rpm_increase = steam_to_turbine * 0.5
    local rpm_decay = 10 * dt
    self.turbine_rpm = math.max(0, math.min(p.turbine_max_rpm, self.turbine_rpm + rpm_increase - rpm_decay))

    -- Electric generation
    local mechanical_power = self.turbine_rpm / p.turbine_max_rpm * p.generator_max_output * p.turbine_efficiency
    -- generator obeys setpoint generator_load (cap)
    local allowed_output = mechanical_power * (self.generator_load / 100)
    -- grid has external load; actual delivered is min(allowed_output, grid_load)
    local delivered = math.min(allowed_output, self.grid_load_kw)
    -- dissipate remainder as waste heat
    local wasted = allowed_output - delivered
    -- convert wasted mechanical to heat
    self.core_temp = self.core_temp + (wasted * 1e-6) -- small effect

    -- 5) Pressure model (steam increases pressure; pumps reduce)
    self.pressure = math.max(0, 100 + (self.steam / p.steam_capacity) * 200 - (self.pump_power / 100) * 50)

    -- 6) Grid voltage behaviour (simple)
    if delivered < self.grid_load_kw * 0.9 then
      -- undervoltage when supply < demand
      self.grid_voltage = p.grid_nominal_voltage * (delivered / math.max(1, self.grid_load_kw))
    else
      -- stable if supply >= demand
      self.grid_voltage = p.grid_nominal_voltage
    end

    -- 7) Decay heat when scrammed (residual)
    if self.scrammed then
      self.core_temp = self.core_temp + p.decay_power * dt * 1000
    end

    -- Safety checks
    if self.core_temp >= p.meltdown_temp then
      self.meltdown = true
      fire("trip", self, "Meltdown")
    end
    if self.pressure >= p.pressure_safe then
      self:scram()
      fire("alarm", self, "High pressure - SCRAM engaged")
    end

    -- minimal refill/autoregulation: pumps can pull some steam back into water if below certain temp
    if self.turbine_rpm < 100 and self.steam > p.steam_capacity * 0.1 then
      -- condense a bit
      local condense = math.min(self.steam, 100 * dt)
      self.steam = self.steam - condense
      self.water = math.min(p.water_capacity, self.water + condense)
    end

    -- update time and fire update
    self.time = self.time + dt
    fire("update", self)
  end

  -- Single-step run for many ticks
  function self:runFor(seconds, interval)
    interval = interval or p.dt
    local steps = math.floor(seconds / interval)
    for i=1,steps do
      self:tick(interval)
    end
  end

  -- Report function to return numbers in user-friendly units
  function self:report()
    return {
      time = self.time,
      core_temp = self.core_temp,
      reactor_power = self.reactor_power,
      control_rods = self.control_rods,
      pump_power = self.pump_power,
      water = self.water,
      steam = self.steam,
      turbine_rpm = self.turbine_rpm,
      turbine_pitch = self.turbine_pitch,
      generator_load = self.generator_load,
      grid_load_kw = self.grid_load_kw,
      grid_voltage = self.grid_voltage,
      scrammed = self.scrammed,
      meltdown = self.meltdown,
      pressure = self.pressure,
    }
  end

  -- Expose config defaults for reference
  self._config = p

  return self
end

return rbmk