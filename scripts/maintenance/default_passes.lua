local collect_containers = require("scripts.maintenance.passes.collect_containers")
local collect_outputs = require("scripts.maintenance.passes.collect_outputs")
local refuel_machines = require("scripts.maintenance.passes.refuel_machines")
local supply_inputs = require("scripts.maintenance.passes.supply_inputs")

local default_passes = {}

function default_passes.build(context)
  return {
    {name = "collect-containers", run = function(builder_state, tick) return collect_containers.run(builder_state, tick, context) end},
    {name = "collect-machine-output", run = function(builder_state, tick) return collect_outputs.run(builder_state, tick, context) end},
    {name = "refuel-machines", run = function(builder_state, tick) return refuel_machines.run(builder_state, tick, context) end},
    {name = "supply-machine-inputs", run = function(builder_state, tick) return supply_inputs.run(builder_state, tick, context) end}
  }
end

return default_passes
