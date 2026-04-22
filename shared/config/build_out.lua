local build_tasks = require("shared.config.build_tasks")
local deep_copy = require("shared.config.util").deep_copy

local function milestone_task(task, task_id, reopen_milestone_name)
  local task_copy = deep_copy(task)
  task_copy.id = task_id
  task_copy.reopen_completed_scaling_milestone_name = reopen_milestone_name
  return task_copy
end

local solar_panel_factory_task = milestone_task(
  build_tasks.solar_panel_factory,
  "build-out-place-solar-panel-factory"
)
local solar_panel_factory_copper_cable_input_task = milestone_task(
  build_tasks.solar_panel_factory_copper_cable_input,
  "build-out-connect-solar-panel-factory-copper-cable-input",
  "solar-panel-factory-block"
)
local solar_panel_factory_iron_input_task = milestone_task(
  build_tasks.solar_panel_factory_iron_input,
  "build-out-connect-solar-panel-factory-iron-input",
  "solar-panel-factory-block"
)
local solar_panel_factory_copper_solar_input_task = milestone_task(
  build_tasks.solar_panel_factory_copper_solar_input,
  "build-out-connect-solar-panel-factory-copper-solar-input",
  "solar-panel-factory-block"
)
local solar_panel_factory_steel_input_task = milestone_task(
  build_tasks.solar_panel_factory_steel_input,
  "build-out-connect-solar-panel-factory-steel-input",
  "solar-panel-factory-block"
)
local solar_panel_factory_power_task = milestone_task(
  build_tasks.solar_panel_factory_power,
  "build-out-connect-solar-panel-factory-power",
  "solar-panel-factory-block"
)

local gun_turret_factory_task = milestone_task(
  build_tasks.gun_turret_factory,
  "build-out-place-gun-turret-factory"
)
local gun_turret_factory_iron_gear_input_task = milestone_task(
  build_tasks.gun_turret_factory_iron_gear_input,
  "build-out-connect-gun-turret-factory-iron-gear-input",
  "gun-turret-factory-block"
)
local gun_turret_factory_iron_turret_input_task = milestone_task(
  build_tasks.gun_turret_factory_iron_turret_input,
  "build-out-connect-gun-turret-factory-iron-turret-input",
  "gun-turret-factory-block"
)
local gun_turret_factory_copper_input_task = milestone_task(
  build_tasks.gun_turret_factory_copper_input,
  "build-out-connect-gun-turret-factory-copper-input",
  "gun-turret-factory-block"
)
local gun_turret_factory_power_task = milestone_task(
  build_tasks.gun_turret_factory_power,
  "build-out-connect-gun-turret-factory-power",
  "gun-turret-factory-block"
)

local automation_science_lab_task = milestone_task(
  build_tasks.automation_science_lab,
  "build-out-place-automation-science-lab"
)
local automation_science_lab_iron_gear_input_task = milestone_task(
  build_tasks.automation_science_lab_iron_gear_input,
  "build-out-connect-automation-science-lab-iron-gear-input",
  "automation-science-lab-block"
)
local automation_science_lab_copper_input_task = milestone_task(
  build_tasks.automation_science_lab_copper_input,
  "build-out-connect-automation-science-lab-copper-input",
  "automation-science-lab-block"
)
local automation_science_lab_power_task = milestone_task(
  build_tasks.automation_science_lab_power,
  "build-out-connect-automation-science-lab-power",
  "automation-science-lab-block"
)

return {
  enabled = true,
  idle_retry_ticks = 2 * 60,
  pursue_milestones_proactively = true,
  gather_source_set = "basic_materials",
  collect_ingredient_producers = {
    ["steel-plate"] = {
      pattern_name = "steel_smelting",
      minimum_site_count = 1
    }
  },
  wait_patrol = {
    arrival_distance = 2.5,
    fuel_recovery_unfueled_machine_threshold = 3,
    item_site_patterns = {
      ["coal"] = {"coal_outpost"},
      ["iron-plate"] = {"iron_smelting", "iron_plate_belt_export"},
      ["copper-plate"] = {"copper_smelting", "copper_plate_belt_export", "coal_outpost"},
      ["steel-plate"] = {"steel_smelting", "steel_plate_belt_export", "iron_smelting", "coal_outpost"}
    },
    fallback_site_patterns = {
      "coal_outpost",
      "iron_smelting",
      "steel_smelting",
      "copper_smelting",
      "stone_outpost",
      "iron_plate_belt_export",
      "copper_plate_belt_export",
      "steel_plate_belt_export"
    }
  },
  maintenance_patrol = {
    interval_ticks = 20 * 60,
    arrival_distance = 2.5,
    ore_patch_arrival_distance = 0.75,
    ore_patch_search_radius = 18,
    linger_ticks = 2 * 60,
    random_candidate_pool = 5,
    site_patterns = {
      "coal_outpost",
      "iron_smelting",
      "steel_smelting",
      "copper_smelting",
      "stone_outpost",
      "iron_plate_belt_export",
      "copper_plate_belt_export",
      "steel_plate_belt_export"
    }
  },
  production_milestones = {
    {
      name = "solar-panel-factory-block",
      display_name = "Place solar panel factory block",
      pursue_proactively = true,
      unlocks_remote_resource_expansion = true,
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
    },
    {
      name = "gun-turret-factory-block",
      display_name = "Place gun turret factory block",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"solar-panel-factory-power"}
      },
      required_items = {
        {name = "assembling-machine-1", count = 2},
        {name = "burner-inserter", count = 3},
        {name = "small-electric-pole", count = 6},
        {name = "transport-belt", count = 64},
        {name = "wooden-chest", count = 1}
      },
      task = gun_turret_factory_task
    },
    {
      name = "gun-turret-factory-iron-gear-input",
      display_name = "Connect gun turret factory gear iron input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"gun-turret-factory-block"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "underground-belt", count = 16},
        {name = "splitter", count = 1},
        {name = "burner-inserter", count = 1}
      },
      task = gun_turret_factory_iron_gear_input_task
    },
    {
      name = "gun-turret-factory-iron-turret-input",
      display_name = "Connect gun turret factory direct iron input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"gun-turret-factory-iron-gear-input"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "underground-belt", count = 16},
        {name = "splitter", count = 1},
        {name = "burner-inserter", count = 1}
      },
      task = gun_turret_factory_iron_turret_input_task
    },
    {
      name = "gun-turret-factory-copper-input",
      display_name = "Connect gun turret factory copper input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"gun-turret-factory-iron-turret-input"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "underground-belt", count = 16},
        {name = "splitter", count = 1},
        {name = "burner-inserter", count = 1}
      },
      task = gun_turret_factory_copper_input_task
    },
    {
      name = "gun-turret-factory-power",
      display_name = "Connect gun turret factory power",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {
          "gun-turret-factory-copper-input"
        }
      },
      required_items = {
        {name = "small-electric-pole", count = 32}
      },
      task = gun_turret_factory_power_task
    },
    {
      name = "automation-science-lab-block",
      display_name = "Place automation science lab block",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"gun-turret-factory-power"}
      },
      required_items = {
        {name = "assembling-machine-1", count = 2},
        {name = "lab", count = 1},
        {name = "burner-inserter", count = 4},
        {name = "small-electric-pole", count = 6},
        {name = "transport-belt", count = 64}
      },
      task = automation_science_lab_task
    },
    {
      name = "automation-science-lab-iron-gear-input",
      display_name = "Connect automation science lab gear iron input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"automation-science-lab-block"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "underground-belt", count = 16},
        {name = "splitter", count = 1},
        {name = "burner-inserter", count = 1}
      },
      task = automation_science_lab_iron_gear_input_task
    },
    {
      name = "automation-science-lab-copper-input",
      display_name = "Connect automation science lab copper input",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {"automation-science-lab-iron-gear-input"}
      },
      required_items = {
        {name = "transport-belt", count = 96},
        {name = "underground-belt", count = 16},
        {name = "splitter", count = 1},
        {name = "burner-inserter", count = 1}
      },
      task = automation_science_lab_copper_input_task
    },
    {
      name = "automation-science-lab-power",
      display_name = "Connect automation science lab power",
      pursue_proactively = true,
      unlock = {
        required_completed_milestones = {
          "automation-science-lab-copper-input"
        }
      },
      required_items = {
        {name = "small-electric-pole", count = 32}
      },
      task = automation_science_lab_power_task
    }
  }
}
