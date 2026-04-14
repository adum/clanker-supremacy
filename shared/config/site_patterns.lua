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
      build_tasks.solar_panel_factory_iron_input,
      build_tasks.solar_panel_factory_copper_cable_input,
      build_tasks.solar_panel_factory_copper_solar_input,
      build_tasks.solar_panel_factory_steel_input
    },
    required_items = {
      {name = "assembling-machine-1", count = 3},
      {name = "burner-inserter", count = 10},
      {name = "small-electric-pole", count = 8},
      {name = "transport-belt", count = 256}
    },
    build_task = build_tasks.solar_panel_factory
  }
}
