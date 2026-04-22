local constants = require("shared.config.constants")

data:extend({
  {
    type = "technology",
    name = constants.enemy_builder_research_technology_name,
    icon = "__base__/graphics/icons/automation-science-pack.png",
    icon_size = 64,
    hidden = true,
    enabled = true,
    effects = {},
    unit = {
      count = 1000000,
      ingredients = {
        {"automation-science-pack", 1}
      },
      time = 10
    },
    order = "z[enemy-builder]-a[red-science]"
  }
})
