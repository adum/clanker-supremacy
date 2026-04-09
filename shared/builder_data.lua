local builder_data = {
  force_name = "enemy-builder",
  default_plan = "bootstrap",
  avatar = {
    prototype_name = "enemy-builder-avatar",
    spawn_offset = {x = 2, y = 0},
    spawn_search_radius = 8,
    spawn_precision = 0.5,
    tint = {r = 0.42, g = 0.9, b = 1, a = 0.85}
  },
  plans = {
    bootstrap = {
      tasks = {
        {
          id = "claim-nearest-coal",
          type = "place-miner-on-resource",
          resource_name = "coal",
          miner_name = "burner-mining-drill",
          search_radii = {64, 128, 256, 512},
          max_resource_candidates_per_radius = 48,
          search_retry_ticks = 5 * 60,
          placement_search_radius = 4,
          placement_step = 0.5,
          arrival_distance = 1.1,
          stuck_retry_ticks = 3 * 60,
          placement_directions = {"north", "east", "south", "west"},
          fuel = {
            name = "coal",
            count = 8
          }
        }
      }
    }
  }
}

return builder_data
