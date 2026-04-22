local constants = require("shared.config.constants")

return {
  force_name = "enemy-builder",
  force = {
    unlock_all_technologies = false,
    enabled_recipes = {
      "steel-plate",
      "copper-cable",
      "electronic-circuit",
      "solar-panel",
      "gun-turret",
      "automation-science-pack",
      "lab"
    },
    research = {
      current_technology_name = constants.enemy_builder_research_technology_name,
      technology_line = {
        {
          name = constants.enemy_builder_physical_damage_1_technology_name,
          display_name = "Physical projectile damage 1"
        }
      }
    }
  },
  prototypes = {
    firearm_magazine_assembler_name = constants.firearm_magazine_assembler_name
  },
  default_plan = "bootstrap",
  avatar = {
    prototype_name = "enemy-builder-avatar",
    armor_prototype_name = "enemy-builder-inventory-armor",
    armor_inventory_bonus = 100,
    spawn_offset = {x = 2, y = 0},
    spawn_search_radius = 8,
    spawn_precision = 0.5,
    tint = {r = 0.42, g = 0.9, b = 1, a = 0.85}
  },
  build = {
    post_place_pause_ticks = 90,
    belt_post_place_pause_ticks = 23
  },
  recovery = {
    max_task_retries = 6,
    blocked_goal_cooldown_ticks = 15 * 60
  },
  movement = {
    approach_randomness = 0.6,
    build_standoff_distance = 0.85,
    build_approach_tolerance = 0.3,
    build_reach_distance = 6
  }
}
