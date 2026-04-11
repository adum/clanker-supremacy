local build_tasks = require("shared.config.build_tasks")
local constants = require("shared.config.constants")
local deep_copy = require("shared.config.util").deep_copy

return {
  enabled = true,
  idle_retry_ticks = 2 * 60,
  pursue_milestones_proactively = false,
  cycle_pattern_names = {"coal_outpost", "iron_smelting", "steel_smelting", "stone_outpost", "copper_smelting", "firearm_magazine_outpost"},
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
    firearm_magazine_outpost = {
      required_completed_milestones = {"firearm-magazine-defense"}
    }
  },
  reserve_items = {
    {name = "coal", count = 20}
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
      task = {
        id = "scale-place-firearm-magazine-assembler",
        type = "place-machine-near-site",
        entity_name = constants.firearm_magazine_assembler_name,
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
        transfer = {
          interval_ticks = 30,
          ammo_item_name = "firearm-magazine",
          turret_ammo_target_count = 20,
          per_turret_transfer_limit = 1
        },
        seed_anchor_items = {
          {name = "iron-plate", count = 80}
        },
        layout_elements = deep_copy(constants.ammo_defense_layout_elements)
      }
    }
  }
}
