local build_tasks = require("shared.config.build_tasks")
local constants = require("shared.config.constants")

local function combine_required_items(...)
  local merged = {}

  for _, item_list in ipairs({...}) do
    for _, item in ipairs(item_list or {}) do
      merged[#merged + 1] = {
        name = item.name,
        count = item.count
      }
    end
  end

  return merged
end

return {
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
    build_task = build_tasks.coal_outpost
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
    build_task = build_tasks.iron_smelting
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
    build_task = build_tasks.stone_outpost
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
    build_task = build_tasks.copper_smelting
  },
  steel_smelting = {
    display_name = "steel smelting line",
    collect = {
      source = "downstream-machine-output",
      item_names = {"steel-plate"}
    },
    required_items = {
      {name = "burner-inserter", count = 1},
      {name = "stone-furnace", count = 1}
    },
    build_task = build_tasks.steel_smelting
  },
  iron_plate_belt_export = {
    display_name = "iron plate belt export",
    required_items = {
      {name = "burner-mining-drill", count = 1},
      {name = "stone-furnace", count = 1},
      {name = "burner-inserter", count = 1},
      {name = "transport-belt", count = 48}
    },
    build_task = build_tasks.iron_plate_belt_export
  },
  copper_plate_belt_export = {
    display_name = "copper plate belt export",
    required_items = {
      {name = "burner-mining-drill", count = 1},
      {name = "stone-furnace", count = 1},
      {name = "burner-inserter", count = 1},
      {name = "transport-belt", count = 48}
    },
    build_task = build_tasks.copper_plate_belt_export
  },
  steel_plate_belt_export = {
    display_name = "steel plate belt export",
    required_items = {
      {name = "burner-inserter", count = 1},
      {name = "transport-belt", count = 48}
    },
    build_task = build_tasks.steel_plate_belt_export
  },
  firearm_magazine_outpost = {
    display_name = "firearm magazine outpost",
    required_items = combine_required_items(
      {
        {name = "assembling-machine-1", count = 1}
      },
      constants.ammo_defense_required_items
    ),
    build_task = build_tasks.firearm_magazine_outpost
  },
  solar_panel_factory = {
    display_name = "solar panel factory",
    tasks = {
      build_tasks.solar_panel_factory,
      build_tasks.solar_panel_factory_copper_cable_input,
      build_tasks.solar_panel_factory_iron_input,
      build_tasks.solar_panel_factory_copper_solar_input,
      build_tasks.solar_panel_factory_steel_input,
      build_tasks.solar_panel_factory_power
    },
    required_items = {
      {name = "assembling-machine-1", count = 3},
      {name = "burner-inserter", count = 7},
      {name = "small-electric-pole", count = 12},
      {name = "splitter", count = 4},
      {name = "transport-belt", count = 256},
      {name = "underground-belt", count = 32},
      {name = "wooden-chest", count = 1}
    },
    build_task = build_tasks.solar_panel_factory
  },
  gun_turret_factory = {
    display_name = "gun turret factory",
    tasks = {
      build_tasks.gun_turret_factory,
      build_tasks.gun_turret_factory_iron_gear_input,
      build_tasks.gun_turret_factory_iron_turret_input,
      build_tasks.gun_turret_factory_copper_input,
      build_tasks.gun_turret_factory_power
    },
    required_items = {
      {name = "assembling-machine-1", count = 2},
      {name = "burner-inserter", count = 5},
      {name = "small-electric-pole", count = 10},
      {name = "splitter", count = 3},
      {name = "transport-belt", count = 192},
      {name = "underground-belt", count = 24},
      {name = "wooden-chest", count = 1}
    },
    build_task = build_tasks.gun_turret_factory
  },
  automation_science_lab = {
    display_name = "automation science lab",
    tasks = {
      build_tasks.automation_science_lab,
      build_tasks.automation_science_lab_iron_gear_input,
      build_tasks.automation_science_lab_copper_input,
      build_tasks.automation_science_lab_power
    },
    required_items = {
      {name = "assembling-machine-1", count = 2},
      {name = "lab", count = 1},
      {name = "burner-inserter", count = 6},
      {name = "small-electric-pole", count = 10},
      {name = "splitter", count = 2},
      {name = "transport-belt", count = 192},
      {name = "underground-belt", count = 24}
    },
    build_task = build_tasks.automation_science_lab
  }
}
