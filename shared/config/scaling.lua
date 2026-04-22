local build_tasks = require("shared.config.build_tasks")
local site_patterns = require("shared.config.site_patterns")
local deep_copy = require("shared.config.util").deep_copy

local firearm_magazine_assembler_task = deep_copy(build_tasks.firearm_magazine_outpost)
firearm_magazine_assembler_task.id = "scale-place-firearm-magazine-assembler"
firearm_magazine_assembler_task.anchor_pattern_names = {"iron_smelting", "copper_smelting"}
firearm_magazine_assembler_task.max_anchor_sites = 8
firearm_magazine_assembler_task.arrival_distance = 1.1

local solar_panel_factory_task = deep_copy(build_tasks.solar_panel_factory)
solar_panel_factory_task.id = "scale-place-solar-panel-factory"

local solar_panel_factory_iron_input_task = deep_copy(build_tasks.solar_panel_factory_iron_input)
solar_panel_factory_iron_input_task.id = "scale-connect-solar-panel-factory-iron-input"
solar_panel_factory_iron_input_task.reopen_completed_scaling_milestone_name = "solar-panel-factory-block"

local solar_panel_factory_copper_cable_input_task = deep_copy(build_tasks.solar_panel_factory_copper_cable_input)
solar_panel_factory_copper_cable_input_task.id = "scale-connect-solar-panel-factory-copper-cable-input"
solar_panel_factory_copper_cable_input_task.reopen_completed_scaling_milestone_name = "solar-panel-factory-block"

local solar_panel_factory_copper_solar_input_task = deep_copy(build_tasks.solar_panel_factory_copper_solar_input)
solar_panel_factory_copper_solar_input_task.id = "scale-connect-solar-panel-factory-copper-solar-input"
solar_panel_factory_copper_solar_input_task.reopen_completed_scaling_milestone_name = "solar-panel-factory-block"

local solar_panel_factory_steel_input_task = deep_copy(build_tasks.solar_panel_factory_steel_input)
solar_panel_factory_steel_input_task.id = "scale-connect-solar-panel-factory-steel-input"
solar_panel_factory_steel_input_task.reopen_completed_scaling_milestone_name = "solar-panel-factory-block"

local solar_panel_factory_power_task = deep_copy(build_tasks.solar_panel_factory_power)
solar_panel_factory_power_task.id = "scale-connect-solar-panel-factory-power"
solar_panel_factory_power_task.reopen_completed_scaling_milestone_name = "solar-panel-factory-block"

return {
  enabled = true,
  idle_retry_ticks = 2 * 60,
  pursue_milestones_proactively = false,
  starter_resource_core = {
    resource_names = {"coal", "iron-ore", "copper-ore", "stone"},
    discovery_radius = 128,
    edge_padding = 24,
    minimum_half_extent = 64,
    fallback_half_extent = 96
  },
  cycle_pattern_names = {
    "coal_outpost",
    "iron_smelting",
    "steel_smelting",
    "stone_outpost",
    "copper_smelting",
    "iron_plate_belt_export",
    "steel_plate_belt_export",
    "copper_plate_belt_export",
    "firearm_magazine_outpost"
  },
  pattern_cycle_weights = {
    coal_outpost = 2,
    iron_smelting = 3,
    steel_smelting = 2,
    stone_outpost = 2,
    copper_smelting = 2
  },
  pattern_unlocks = {
    steel_smelting = {
      minimum_site_counts = {
        iron_smelting = 5
      }
    },
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
    iron_plate_belt_export = {
      minimum_site_counts = {
        iron_smelting = 10
      }
    },
    steel_plate_belt_export = {
      minimum_site_counts = {
        steel_smelting = 6
      },
      required_completed_milestones = {"iron-plate-belt-export-established"}
    },
    copper_plate_belt_export = {
      minimum_site_counts = {
        copper_smelting = 10
      }
    },
    firearm_magazine_outpost = {
      minimum_site_counts = {
        coal_outpost = 3,
        iron_smelting = 8,
        copper_smelting = 3
      },
      maximum_site_counts = {
        firearm_magazine_outpost = 5
      },
      required_completed_milestones = {"firearm-magazine-assembler"}
    }
  },
  reserve_items = {
    {
      name = "coal",
      count = 20,
      unlock = {
        minimum_site_counts = {
          coal_outpost = 2,
          iron_smelting = 2
        }
      }
    }
  },
  wait_patrol = {
    arrival_distance = 2.5,
    fuel_recovery_unfueled_machine_threshold = 3,
    item_site_patterns = {
      ["coal"] = {"coal_outpost"},
      ["iron-plate"] = {"iron_smelting"},
      ["copper-plate"] = {"copper_smelting", "coal_outpost"},
      ["steel-plate"] = {"steel_smelting", "iron_smelting", "coal_outpost"}
    },
    fallback_site_patterns = {"coal_outpost", "iron_smelting", "steel_smelting", "copper_smelting", "stone_outpost"}
  },
  collect_ingredient_producers = {
    ["steel-plate"] = {
      pattern_name = "steel_smelting",
      minimum_site_count = 1
    }
  },
  gather_source_set = "basic_materials",
  production_milestones = {
    {
      name = "firearm-magazine-assembler",
      display_name = "Establish firearm magazine assembler",
      unlock = {
        minimum_site_counts = {
          coal_outpost = 3,
          iron_smelting = 8,
          copper_smelting = 3
        }
      },
      inventory_thresholds = {
        {name = "iron-plate", count = 200},
        {name = "copper-plate", count = 200}
      },
      required_items = deep_copy(site_patterns.firearm_magazine_outpost.required_items),
      task = firearm_magazine_assembler_task
    },
    {
      name = "solar-panel-factory-block",
      display_name = "Place solar panel factory block",
      pursue_proactively = true,
      unlocks_remote_resource_expansion = true,
      unlock = {
        required_completed_milestones = {"firearm-magazine-assembler"},
        minimum_site_counts = {
          iron_plate_belt_export = 2,
          copper_plate_belt_export = 2,
          steel_plate_belt_export = 1
        }
      },
      required_items = {
        {name = "assembling-machine-1", count = 3},
        {name = "burner-inserter", count = 6},
        {name = "small-electric-pole", count = 8},
        {name = "transport-belt", count = 96},
        {name = "wooden-chest", count = 1}
      },
      task = solar_panel_factory_task
    },
    {
      name = "solar-panel-factory-copper-cable-input",
      display_name = "Connect solar factory copper cable input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"solar-panel-factory-block"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "underground-belt", count = 16},
        {name = "splitter", count = 1},
        {name = "burner-inserter", count = 1}
      },
      task = solar_panel_factory_copper_cable_input_task
    },
    {
      name = "solar-panel-factory-iron-input",
      display_name = "Connect solar factory iron input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"solar-panel-factory-copper-cable-input"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "underground-belt", count = 16},
        {name = "splitter", count = 1},
        {name = "burner-inserter", count = 1}
      },
      task = solar_panel_factory_iron_input_task
    },
    {
      name = "solar-panel-factory-copper-solar-input",
      display_name = "Connect solar factory direct copper input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"solar-panel-factory-iron-input"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "underground-belt", count = 16},
        {name = "splitter", count = 1},
        {name = "burner-inserter", count = 1}
      },
      task = solar_panel_factory_copper_solar_input_task
    },
    {
      name = "solar-panel-factory-steel-input",
      display_name = "Connect solar factory steel input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"solar-panel-factory-copper-solar-input"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "underground-belt", count = 16},
        {name = "splitter", count = 1},
        {name = "burner-inserter", count = 1}
      },
      task = solar_panel_factory_steel_input_task
    },
    {
      name = "solar-panel-factory-power",
      display_name = "Connect solar factory power",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {
          "solar-panel-factory-copper-solar-input",
          "solar-panel-factory-steel-input"
        }
      },
      required_items = {
        {name = "small-electric-pole", count = 32}
      },
      task = solar_panel_factory_power_task
    }
  }
}
