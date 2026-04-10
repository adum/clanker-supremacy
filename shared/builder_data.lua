local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end

  local copy = {}
  for key, nested_value in pairs(value) do
    copy[deep_copy(key)] = deep_copy(nested_value)
  end

  return copy
end

local gather_sources = {
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

local coal_outpost_build_task = {
  type = "place-miner-on-resource",
  pattern_name = "coal_outpost",
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
  site_selection = {
    prefer_middle = true,
    random_candidate_pool = 12
  },
  output_container = {
    name = "wooden-chest"
  },
  fuel = {
    name = "coal",
    count = 8
  }
}

local iron_smelting_build_task = {
  type = "place-miner-on-resource",
  pattern_name = "iron_smelting",
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
  site_selection = {
    prefer_middle = true,
    random_candidate_pool = 12
  },
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
}

local bootstrap_gather_task = {
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
  sources = gather_sources
}

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
    nearby_machine_refuel = {
      interval_ticks = 3 * 60,
      radius = 24,
      fuel_name = "coal",
      target_fuel_item_count = 20,
      own_force_only = true,
      max_entities_per_scan = 24
    },
    production_transfer = {
      interval_ticks = 30
    }
  },
  world_item_sources = {
    basic_materials = {
      search_retry_ticks = 5 * 60,
      arrival_distance = 1.1,
      stuck_retry_ticks = 3 * 60,
      mining_duration_ticks = 45,
      sources = gather_sources
    }
  },
  crafting = {
    recipes = {
      ["wooden-chest"] = {
        craft_ticks = 30,
        ingredients = {
          {name = "wood", count = 4}
        }
      },
      ["stone-furnace"] = {
        craft_ticks = 210,
        ingredients = {
          {name = "stone", count = 5}
        }
      },
      ["iron-gear-wheel"] = {
        craft_ticks = 30,
        ingredients = {
          {name = "iron-plate", count = 2}
        }
      },
      ["burner-mining-drill"] = {
        craft_ticks = 120,
        ingredients = {
          {name = "iron-gear-wheel", count = 3},
          {name = "iron-plate", count = 3},
          {name = "stone-furnace", count = 1}
        }
      }
    }
  },
  site_patterns = {
    coal_outpost = {
      display_name = "coal outpost",
      collect = {
        source = "output-container",
        item_names = {"coal"}
      },
      required_items = {
        {name = "burner-mining-drill", count = 1},
        {name = "wooden-chest", count = 1}
      },
      build_task = coal_outpost_build_task
    },
    iron_smelting = {
      display_name = "iron smelting line",
      collect = {
        source = "downstream-machine-output",
        item_names = {"iron-plate"}
      },
      required_items = {
        {name = "burner-mining-drill", count = 1},
        {name = "stone-furnace", count = 1}
      },
      build_task = iron_smelting_build_task
    }
  },
  scaling = {
    enabled = true,
    idle_retry_ticks = 2 * 60,
    cycle_pattern_names = {"coal_outpost", "iron_smelting"},
    reserve_items = {
      {name = "coal", count = 20}
    },
    gather_source_set = "basic_materials"
  },
  plans = {
    bootstrap = {
      tasks = {
        deep_copy(coal_outpost_build_task),
        bootstrap_gather_task,
        deep_copy(iron_smelting_build_task),
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

builder_data.plans.bootstrap.tasks[1].id = "claim-nearest-coal"
builder_data.plans.bootstrap.tasks[3].id = "claim-nearest-iron-smelting"

return builder_data
