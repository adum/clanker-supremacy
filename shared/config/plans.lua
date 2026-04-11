local build_tasks = require("shared.config.build_tasks")
local deep_copy = require("shared.config.util").deep_copy

local bootstrap_coal_task = deep_copy(build_tasks.coal_outpost)
bootstrap_coal_task.id = "claim-nearest-coal"

local bootstrap_iron_task = deep_copy(build_tasks.iron_smelting)
bootstrap_iron_task.id = "claim-nearest-iron-smelting"

return {
  bootstrap = {
    display_name = "Bootstrap base",
    tasks = {
      bootstrap_coal_task,
      deep_copy(build_tasks.bootstrap_gather),
      bootstrap_iron_task,
      {
        id = "return-to-coal-patch",
        type = "move-to-resource",
        resource_name = "coal",
        search_radii = {64, 128, 256, 512},
        search_retry_ticks = 5 * 60,
        arrival_distance = 1.1,
        stuck_retry_ticks = 3 * 60
      }
    }
  }
}
