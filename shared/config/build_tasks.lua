local constants = require("shared.config.constants")
local assembly_targets = require("shared.config.assembly_targets")
local deep_copy = require("shared.config.util").deep_copy

local build_tasks = {}

local function make_fresh_output_belt_task(pattern_name, resource_name, output_item_name)
  return {
    type = "place-miner-on-resource",
    pattern_name = pattern_name,
    resource_name = resource_name,
    output_item_name = output_item_name,
    miner_name = "burner-mining-drill",
    site_search_mode = "resource-edge-only",
    defer_downstream_planning = true,
    defer_output_belt_planning = true,
    abandon_partial_site_on_failure = true,
    search_radii = {64, 128, 256, 512},
    max_resource_candidates_per_radius = 4,
    search_retry_ticks = 5 * 60,
    placement_search_radius = 4,
    placement_step = 0.5,
    arrival_distance = 1.1,
    stuck_retry_ticks = 3 * 60,
    placement_directions = {"north", "east", "south", "west"},
    site_selection = {
      prefer_middle = true,
      prefer_patch_margin = true,
      random_candidate_pool = 2
    },
    downstream_machine = {
      name = "stone-furnace",
      recipe = output_item_name,
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
    },
    patch_search_radius = 64,
    output_inserter = {
      entity_name = "burner-inserter",
      item_name = "burner-inserter",
      fuel = {
        name = "coal",
        count = 4
      }
    },
    belt_entity_name = "transport-belt",
    belt_item_name = "transport-belt",
    belt_hub_search = {
      heading_count = 8,
      heading_attempts = 4,
      ray_step = 1,
      max_distance = 48,
      extra_distance_min = 8,
      extra_distance_max = 12,
      local_search_radius = 3,
      local_search_step = 1
    },
    belt_terminal_search_radius = 3,
    belt_terminal_search_step = 1,
    forbid_resource_overlap = true
  }
end

build_tasks.coal_outpost = {
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

build_tasks.iron_smelting = {
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

build_tasks.stone_outpost = {
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

build_tasks.copper_smelting = {
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

build_tasks.steel_smelting = {
  type = "place-layout-near-machine",
  pattern_name = "steel_smelting",
  resource_name = "iron-ore",
  anchor_pattern_names = {"iron_smelting"},
  anchor_position_source = "downstream-machine",
  max_anchor_entities = 12,
  search_retry_ticks = 5 * 60,
  arrival_distance = 1.6,
  stuck_retry_ticks = 3 * 60,
  layout_orientations = {"north", "east", "south", "west"},
  require_missing_registered_site = {
    site_type = "steel-smelting-chain",
    entity_field = "anchor_machine"
  },
  layout_site_kind = "steel-smelting-chain",
  layout_elements = {
    {
      id = "steel-feed-inserter",
      site_role = "steel-feed-inserter",
      entity_name = "burner-inserter",
      offset = {x = 1, y = 0},
      direction_name = "west",
      placement_search_radius = 0.5,
      placement_step = 0.5,
      fuel = {
        name = "coal",
        count = 4
      }
    },
    {
      id = "steel-furnace",
      site_role = "steel-furnace",
      entity_name = "stone-furnace",
      offset = {x = 3, y = 0},
      placement_search_radius = 0.5,
      placement_step = 0.5,
      fuel = {
        name = "coal",
        count = 8
      }
    }
  }
}

build_tasks.firearm_magazine_outpost = {
  type = "place-machine-near-site",
  pattern_name = "firearm_magazine_outpost",
  entity_name = constants.firearm_magazine_assembler_name,
  consume_item_name = "assembling-machine-1",
  recipe_name = "firearm-magazine",
  recipe_is_fixed = true,
  anchor_pattern_names = {"coal_outpost", "iron_smelting", "stone_outpost", "copper_smelting"},
  anchor_position_source = "miner",
  max_anchor_sites = 12,
  search_retry_ticks = 5 * 60,
  placement_search_radius = 8,
  placement_step = 1,
  resource_clearance_search = {
    heading_count = 16,
    heading_attempts = 8,
    ray_step = 1,
    max_distance = 64,
    extra_distance_min = 10,
    extra_distance_max = 16
  },
  arrival_distance = 1.6,
  stuck_retry_ticks = 3 * 60,
  forbid_resource_overlap = true,
  layout_reservation = {
    layout_orientations = {"north", "east", "south", "west"},
    forbid_resource_overlap = true,
    layout_elements = deep_copy(constants.ammo_defense_layout_elements)
  },
  anchor_preference = {
    fewer_registered_sites = {
      site_type = "assembler-defense",
      entity_field = "assembler",
      radius = 24
    }
  }
}

build_tasks.solar_panel_factory = {
  id = "solar-panel-factory-block",
  type = "place-assembly-block",
  pattern_name = "solar_panel_factory",
  target_item_name = "solar-panel",
  entity_name = "assembling-machine-1",
  assembly_target_name = "solar_panel_factory",
  assembly_target = deep_copy(assembly_targets.solar_panel_factory),
  power_anchor_search_radius = 24,
  max_anchor_entities = 6,
  search_retry_ticks = 5 * 60,
  placement_search_radius = 10,
  placement_step = 1,
  layout_orientations = {"north"},
  belt_route_search_margin = 80,
  arrival_distance = 1.6,
  stuck_retry_ticks = 3 * 60,
  resource_clearance_search = {
    heading_count = 16,
    heading_attempts = 8,
    ray_step = 1,
    max_distance = 80,
    extra_distance_min = 20,
    extra_distance_max = 28,
    local_search_radius = 6,
    local_search_step = 1
  },
  require_missing_registered_site = {
    site_type = "assembly-block",
    entity_field = "anchor_entity"
  },
  belt_entity_name = "transport-belt",
  belt_item_name = "transport-belt",
  forbid_resource_overlap = true
}

local function make_assembly_input_route_task(route_id, item_name)
  return {
    id = "solar-panel-factory-" .. route_id,
    type = "place-assembly-input-route",
    pattern_name = "solar_panel_factory",
    target_item_name = "solar-panel",
    route_id = route_id,
    route_item_name = item_name,
    assembly_target_name = "solar_panel_factory",
    assembly_target = deep_copy(assembly_targets.solar_panel_factory),
    max_anchor_entities = 8,
    search_retry_ticks = 5 * 60,
    arrival_distance = 1.6,
    stuck_retry_ticks = 3 * 60,
    belt_route_search_margin = 80,
    belt_entity_name = "transport-belt",
    belt_item_name = "transport-belt",
    forbid_resource_overlap = true
  }
end

build_tasks.solar_panel_factory_iron_input = make_assembly_input_route_task("iron-plate-line", "iron-plate")
build_tasks.solar_panel_factory_copper_cable_input = make_assembly_input_route_task("copper-plate-to-cable-line", "copper-plate")
build_tasks.solar_panel_factory_copper_solar_input = make_assembly_input_route_task("copper-plate-to-solar-line", "copper-plate")
build_tasks.solar_panel_factory_steel_input = make_assembly_input_route_task("steel-plate-line", "steel-plate")

build_tasks.copper_plate_belt_export = make_fresh_output_belt_task(
  "copper_plate_belt_export",
  "copper-ore",
  "copper-plate"
)

build_tasks.iron_plate_belt_export = make_fresh_output_belt_task(
  "iron_plate_belt_export",
  "iron-ore",
  "iron-plate"
)

local function make_retrofit_output_belt_task(pattern_name, anchor_pattern_names, resource_name, output_item_name)
  return {
    type = "place-output-belt-line",
    pattern_name = pattern_name,
    resource_name = resource_name,
    output_item_name = output_item_name,
    anchor_pattern_names = anchor_pattern_names,
    anchor_position_source = "downstream-machine",
    max_anchor_entities = 12,
    search_retry_ticks = 5 * 60,
    arrival_distance = 1.6,
    stuck_retry_ticks = 3 * 60,
    patch_search_radius = 64,
    require_missing_registered_site = {
      site_type = "smelting-output-belt",
      entity_field = "output_machine"
    },
    output_inserter = {
      entity_name = "burner-inserter",
      item_name = "burner-inserter",
      fuel = {
        name = "coal",
        count = 4
      }
    },
    belt_entity_name = "transport-belt",
    belt_item_name = "transport-belt",
    belt_hub_search = {
      heading_count = 16,
      heading_attempts = 8,
      ray_step = 1,
      max_distance = 80,
      extra_distance_min = 18,
      extra_distance_max = 24,
      local_search_radius = 4,
      local_search_step = 1
    },
    belt_terminal_search_radius = 3,
    belt_terminal_search_step = 1,
    forbid_resource_overlap = true
  }
end

build_tasks.steel_plate_belt_export = make_retrofit_output_belt_task(
  "steel_plate_belt_export",
  {"steel_smelting"},
  "iron-ore",
  "steel-plate"
)

build_tasks.bootstrap_gather = {
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
  sources = constants.gather_sources
}

return build_tasks
