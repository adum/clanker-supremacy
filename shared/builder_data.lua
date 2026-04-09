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
  build = {
    post_place_pause_ticks = 90
  },
  logistics = {
    nearby_container_collection = {
      interval_ticks = 5 * 60,
      radius = 24,
      entity_types = {"container", "logistic-container"},
      own_force_only = true,
      max_containers_per_scan = 16
    },
    production_transfer = {
      interval_ticks = 30
    }
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
          output_container = {
            name = "wooden-chest"
          },
          fuel = {
            name = "coal",
            count = 8
          }
        },
        {
          id = "gather-bootstrap-materials",
          type = "gather-world-items",
          search_retry_ticks = 5 * 60,
          arrival_distance = 1.1,
          stuck_retry_ticks = 3 * 60,
          mining_duration_ticks = 45,
          inventory_targets = {
            {name = "wood", count = 20},
            {name = "stone", count = 20}
          },
          sources = {
            {
              id = "trees",
              entity_type = "tree",
              search_radii = {32, 64, 128},
              yields = {
                {name = "wood", count = 4}
              }
            },
            {
              id = "rocks",
              decorative_names = {
                "huge-rock",
                "big-rock",
                "big-sand-rock",
                "medium-rock",
                "small-rock",
                "tiny-rock",
                "medium-sand-rock",
                "small-sand-rock"
              },
              search_radii = {64, 128, 256},
              yields = {
                {name = "stone", count = 8}
              }
            }
          }
        },
        {
          id = "claim-nearest-iron-smelting",
          type = "place-miner-on-resource",
          resource_name = "iron-ore",
          miner_name = "burner-mining-drill",
          search_radii = {64, 128, 256, 512},
          max_resource_candidates_per_radius = 48,
          search_retry_ticks = 5 * 60,
          placement_search_radius = 4,
          placement_step = 0.5,
          arrival_distance = 1.1,
          stuck_retry_ticks = 3 * 60,
          placement_directions = {"north", "east", "south", "west"},
          downstream_machine = {
            name = "stone-furnace",
            recipe = "iron-plate",
            placement_search_radius = 2,
            placement_step = 0.5,
            cover_drop_position = true,
            fuel = {
              name = "coal",
              count = 8
            }
          },
          fuel = {
            name = "coal",
            count = 8
          },
          transfer = {
            interval_ticks = 30
          }
        },
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
}

return builder_data
