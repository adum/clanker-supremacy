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

local firearm_magazine_assembler_name = "enemy-builder-firearm-magazine-assembler"
local ammo_defense_required_items = {
  {name = "burner-inserter", count = 2},
  {name = "gun-turret", count = 2},
  {name = "small-electric-pole", count = 4},
  {name = "solar-panel", count = 4},
  {name = "iron-plate", count = 80}
}
local ammo_defense_layout_elements = {
  {
    id = "left-burner-inserter",
    site_role = "burner-inserter",
    entity_name = "burner-inserter",
    offset = {x = -2, y = 0},
    direction_name = "west",
    placement_search_radius = 0.5,
    placement_step = 0.5,
    fuel = {
      name = "coal",
      count = 4
    }
  },
  {
    id = "right-burner-inserter",
    site_role = "burner-inserter",
    entity_name = "burner-inserter",
    offset = {x = 2, y = 0},
    direction_name = "east",
    placement_search_radius = 0.5,
    placement_step = 0.5,
    fuel = {
      name = "coal",
      count = 4
    }
  },
  {
    id = "left-turret",
    site_role = "turret",
    entity_name = "gun-turret",
    offset = {x = -4, y = 0},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "right-turret",
    site_role = "turret",
    entity_name = "gun-turret",
    offset = {x = 4, y = 0},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "power-pole-1",
    site_role = "power-pole",
    entity_name = "small-electric-pole",
    offset = {x = 0, y = -2},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "power-pole-2",
    site_role = "power-pole",
    entity_name = "small-electric-pole",
    offset = {x = 0, y = -5},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "power-pole-3",
    site_role = "power-pole",
    entity_name = "small-electric-pole",
    offset = {x = 0, y = -8},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "power-pole-4",
    site_role = "power-pole",
    entity_name = "small-electric-pole",
    offset = {x = 0, y = -11},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "solar-panel-1",
    site_role = "solar-panel",
    entity_name = "solar-panel",
    offset = {x = -3, y = -5},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "solar-panel-2",
    site_role = "solar-panel",
    entity_name = "solar-panel",
    offset = {x = 3, y = -5},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "solar-panel-3",
    site_role = "solar-panel",
    entity_name = "solar-panel",
    offset = {x = -3, y = -8},
    placement_search_radius = 0.5,
    placement_step = 0.5
  },
  {
    id = "solar-panel-4",
    site_role = "solar-panel",
    entity_name = "solar-panel",
    offset = {x = 3, y = -8},
    placement_search_radius = 0.5,
    placement_step = 0.5
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

local stone_outpost_build_task = {
  type = "place-miner-on-resource",
  pattern_name = "stone_outpost",
  resource_name = "stone",
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

local copper_smelting_build_task = {
  type = "place-miner-on-resource",
  pattern_name = "copper_smelting",
  resource_name = "copper-ore",
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
    recipe = "copper-plate",
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

local firearm_magazine_outpost_build_task = {
  type = "place-machine-near-site",
  pattern_name = "firearm_magazine_outpost",
  entity_name = firearm_magazine_assembler_name,
  consume_item_name = "assembling-machine-1",
  recipe_name = "firearm-magazine",
  recipe_is_fixed = true,
  anchor_pattern_names = {"coal_outpost", "iron_smelting", "stone_outpost", "copper_smelting"},
  anchor_position_source = "miner",
  max_anchor_sites = 12,
  search_retry_ticks = 5 * 60,
  placement_search_radius = 10,
  placement_step = 1,
  arrival_distance = 1.6,
  stuck_retry_ticks = 3 * 60,
  forbid_resource_overlap = true,
  layout_reservation = {
    layout_orientations = {"north", "east", "south", "west"},
    forbid_resource_overlap = true,
    layout_elements = deep_copy(ammo_defense_layout_elements)
  },
  anchor_preference = {
    fewer_registered_sites = {
      site_type = "assembler-defense",
      entity_field = "assembler",
      radius = 24
    }
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
  force = {
    unlock_all_technologies = true
  },
  prototypes = {
    firearm_magazine_assembler_name = firearm_magazine_assembler_name
  },
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
  movement = {
    approach_randomness = 0.6
  },
  ui = {
    overlay = {
      enabled = true,
      update_interval_ticks = 15,
      top_margin = 12,
      left_margin = 20,
      right_margin = 20,
      inventory_top_offset = 40,
      inventory_width = 260,
      max_inventory_lines = 24
    },
    map_marker = {
      enabled = true,
      update_interval_ticks = 60,
      chart_radius = 16,
      text = "Builder",
      refresh_distance = 1
    }
  },
  logistics = {
    inventory_take_limits = {
      coal = 500,
      ["iron-plate"] = 500,
      stone = 500,
      ["copper-plate"] = 500
    },
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
    nearby_machine_input_supply = {
      interval_ticks = 4 * 60,
      radius = 24,
      entity_types = {"assembling-machine"},
      target_ingredient_item_count = 20,
      own_force_only = true,
      max_entities_per_scan = 12
    },
    nearby_machine_output_collection = {
      interval_ticks = 4 * 60,
      radius = 24,
      entity_types = {"furnace"},
      own_force_only = true,
      max_entities_per_scan = 12
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
      ["copper-cable"] = {
        craft_ticks = 15,
        result_count = 2,
        ingredients = {
          {name = "copper-plate", count = 1}
        }
      },
      ["electronic-circuit"] = {
        craft_ticks = 30,
        ingredients = {
          {name = "iron-plate", count = 1},
          {name = "copper-cable", count = 3}
        }
      },
      ["burner-mining-drill"] = {
        craft_ticks = 120,
        ingredients = {
          {name = "iron-gear-wheel", count = 3},
          {name = "iron-plate", count = 3},
          {name = "stone-furnace", count = 1}
        }
      },
      ["assembling-machine-1"] = {
        craft_ticks = 30,
        ingredients = {
          {name = "iron-plate", count = 9},
          {name = "iron-gear-wheel", count = 5},
          {name = "electronic-circuit", count = 3}
        }
      },
      ["burner-inserter"] = {
        craft_ticks = 30,
        ingredients = {
          {name = "iron-plate", count = 1},
          {name = "iron-gear-wheel", count = 1}
        }
      },
      ["small-electric-pole"] = {
        craft_ticks = 30,
        result_count = 2,
        ingredients = {
          {name = "wood", count = 1},
          {name = "copper-cable", count = 2}
        }
      },
      ["steel-plate"] = {
        craft_ticks = 960,
        ingredients = {
          {name = "iron-plate", count = 5}
        }
      },
      ["gun-turret"] = {
        craft_ticks = 480,
        ingredients = {
          {name = "iron-gear-wheel", count = 10},
          {name = "copper-plate", count = 10},
          {name = "iron-plate", count = 20}
        }
      },
      ["solar-panel"] = {
        craft_ticks = 600,
        ingredients = {
          {name = "steel-plate", count = 5},
          {name = "electronic-circuit", count = 15},
          {name = "copper-plate", count = 5}
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
    },
    stone_outpost = {
      display_name = "stone outpost",
      collect = {
        source = "output-container",
        item_names = {"stone"}
      },
      required_items = {
        {name = "burner-mining-drill", count = 1},
        {name = "wooden-chest", count = 1}
      },
      build_task = stone_outpost_build_task
    },
    copper_smelting = {
      display_name = "copper smelting line",
      collect = {
        source = "downstream-machine-output",
        item_names = {"copper-plate"}
      },
      required_items = {
        {name = "burner-mining-drill", count = 1},
        {name = "stone-furnace", count = 1}
      },
      build_task = copper_smelting_build_task
    },
    firearm_magazine_outpost = {
      display_name = "firearm magazine outpost",
      required_items = {
        {name = "assembling-machine-1", count = 1}
      },
      build_task = firearm_magazine_outpost_build_task
    }
  },
  scaling = {
    enabled = true,
    idle_retry_ticks = 2 * 60,
    pursue_milestones_proactively = false,
    cycle_pattern_names = {"coal_outpost", "iron_smelting", "stone_outpost", "copper_smelting", "firearm_magazine_outpost"},
    pattern_unlocks = {
      stone_outpost = {
        minimum_site_counts = {
          coal_outpost = 5,
          iron_smelting = 5
        }
      },
      copper_smelting = {
        minimum_site_counts = {
          coal_outpost = 5,
          iron_smelting = 5
        }
      },
      firearm_magazine_outpost = {
        required_completed_milestones = {"firearm-magazine-defense"}
      }
    },
    reserve_items = {
      {name = "coal", count = 20}
    },
    gather_source_set = "basic_materials",
    production_milestones = {
      {
        name = "firearm-magazine-assembler",
        display_name = "Establish firearm magazine assembler",
        inventory_thresholds = {
          {name = "iron-plate", count = 200},
          {name = "copper-plate", count = 200}
        },
        required_items = {
          {name = "assembling-machine-1", count = 1}
        },
        task = {
          id = "scale-place-firearm-magazine-assembler",
          type = "place-machine-near-site",
          entity_name = "enemy-builder-firearm-magazine-assembler",
          consume_item_name = "assembling-machine-1",
          recipe_name = "firearm-magazine",
          recipe_is_fixed = true,
          anchor_pattern_names = {"iron_smelting", "copper_smelting"},
          anchor_position_source = "miner",
          max_anchor_sites = 8,
          search_retry_ticks = 5 * 60,
          placement_search_radius = 8,
          placement_step = 1,
          arrival_distance = 1.1,
          stuck_retry_ticks = 3 * 60,
          forbid_resource_overlap = true
        }
      },
      {
        name = "firearm-magazine-defense",
        display_name = "Fortify firearm magazine assembler",
        pursue_proactively = true,
        repeat_when_eligible = true,
        required_items = deep_copy(ammo_defense_required_items),
        task = {
          id = "scale-place-firearm-magazine-defense",
          type = "place-layout-near-machine",
          anchor_entity_names = {firearm_magazine_assembler_name},
          max_anchor_entities = 8,
          search_retry_ticks = 5 * 60,
          arrival_distance = 1.6,
          stuck_retry_ticks = 3 * 60,
          layout_orientations = {"north", "east", "south", "west"},
          require_missing_registered_site = {
            site_type = "assembler-defense",
            entity_field = "assembler"
          },
          forbid_resource_overlap = true,
          transfer = {
            interval_ticks = 30,
            ammo_item_name = "firearm-magazine",
            turret_ammo_target_count = 20,
            per_turret_transfer_limit = 1
          },
          seed_anchor_items = {
            {name = "iron-plate", count = 80}
          },
          layout_elements = deep_copy(ammo_defense_layout_elements)
        }
      }
    }
  },
  plans = {
    bootstrap = {
      display_name = "Bootstrap base",
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
