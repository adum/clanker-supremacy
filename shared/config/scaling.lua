local build_tasks = require("shared.config.build_tasks")
local constants = require("shared.config.constants")
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

return {
  enabled = true,
  idle_retry_ticks = 2 * 60,
  pursue_milestones_proactively = false,
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
        iron_smelting = 5
      }
    },
    steel_plate_belt_export = {
      minimum_site_counts = {
        steel_smelting = 3
      }
    },
    copper_plate_belt_export = {
      minimum_site_counts = {
        copper_smelting = 5
      }
    },
    firearm_magazine_outpost = {
      required_completed_milestones = {"firearm-magazine-defense"}
    }
  },
  reserve_items = {
    {name = "coal", count = 20}
  },
  wait_patrol = {
    item_site_patterns = {
      ["coal"] = {"coal_outpost"},
      ["iron-plate"] = {"iron_smelting", "coal_outpost"},
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
      inventory_thresholds = {
        {name = "iron-plate", count = 200},
        {name = "copper-plate", count = 200}
      },
      required_items = {
        {name = "assembling-machine-1", count = 1}
      },
      task = firearm_magazine_assembler_task
    },
    {
      name = "firearm-magazine-defense",
      display_name = "Fortify firearm magazine assembler",
      pursue_proactively = true,
      repeat_when_eligible = true,
      required_items = deep_copy(constants.ammo_defense_required_items),
      task = {
        id = "scale-place-firearm-magazine-defense",
        type = "place-layout-near-machine",
        anchor_entity_names = {constants.firearm_magazine_assembler_name},
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
        seed_anchor_items = {
          {name = "iron-plate", count = 80}
        },
        layout_elements = deep_copy(constants.ammo_defense_layout_elements)
      }
    },
    {
      name = "solar-panel-factory-block",
      display_name = "Place solar panel factory block",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"firearm-magazine-defense"},
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
        {name = "transport-belt", count = 96}
      },
      task = solar_panel_factory_task
    },
    {
      name = "solar-panel-factory-iron-input",
      display_name = "Connect solar factory iron input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"solar-panel-factory-block"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "burner-inserter", count = 1}
      },
      task = solar_panel_factory_iron_input_task
    },
    {
      name = "solar-panel-factory-copper-cable-input",
      display_name = "Connect solar factory copper cable input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"solar-panel-factory-iron-input"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "burner-inserter", count = 1}
      },
      task = solar_panel_factory_copper_cable_input_task
    },
    {
      name = "solar-panel-factory-copper-solar-input",
      display_name = "Connect solar factory direct copper input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"solar-panel-factory-copper-cable-input"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
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
        {name = "burner-inserter", count = 1}
      },
      task = solar_panel_factory_steel_input_task
    }
  }
}
