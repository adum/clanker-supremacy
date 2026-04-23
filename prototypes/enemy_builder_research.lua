local constants = require("shared.config.constants")

data:extend({
  {
    type = "technology",
    name = constants.enemy_builder_physical_damage_1_technology_name,
    icons = util.technology_icon_constant_damage("__base__/graphics/technology/physical-projectile-damage-1.png"),
    hidden = true,
    enabled = true,
    effects = {
      {
        type = "ammo-damage",
        ammo_category = "bullet",
        modifier = 0.1
      },
      {
        type = "turret-attack",
        turret_id = "gun-turret",
        modifier = 0.1
      },
      {
        type = "ammo-damage",
        ammo_category = "shotgun-shell",
        modifier = 0.1
      }
    },
    unit = {
      count = 10,
      ingredients = {
        {"automation-science-pack", 1}
      },
      time = 30
    },
    upgrade = true,
    order = "z[enemy-builder]-a[red-science]"
  },
  {
    type = "technology",
    name = constants.enemy_builder_piercing_rounds_technology_name,
    icons = util.technology_icon_constant_damage("__base__/graphics/technology/physical-projectile-damage-2.png"),
    hidden = true,
    enabled = true,
    prerequisites = {constants.enemy_builder_physical_damage_1_technology_name},
    effects = {
      {
        type = "unlock-recipe",
        recipe = "piercing-rounds-magazine"
      }
    },
    unit = {
      count = 10,
      ingredients = {
        {"automation-science-pack", 1}
      },
      time = 30
    },
    upgrade = true,
    order = "z[enemy-builder]-b[piercing-rounds-magazine]"
  }
})
