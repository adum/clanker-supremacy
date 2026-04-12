local build_tasks = require("shared.config.build_tasks")

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
    required_items = {
      {name = "assembling-machine-1", count = 1}
    },
    build_task = build_tasks.firearm_magazine_outpost
  }
}
