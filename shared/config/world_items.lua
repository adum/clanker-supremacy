local constants = require("shared.config.constants")

return {
  basic_materials = {
    search_retry_ticks = 5 * 60,
    arrival_distance = 1.1,
    stuck_retry_ticks = 3 * 60,
    mining_duration_ticks = 45,
    sources = constants.gather_sources
  }
}
