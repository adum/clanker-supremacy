local builder_data = require("shared.builder_data")

local avatar = table.deepcopy(data.raw.character.character)

avatar.name = builder_data.avatar.prototype_name
avatar.icon = "__base__/graphics/icons/construction-robot.png"
avatar.localised_name = {"entity-name.enemy-builder-avatar"}
avatar.localised_description = {"entity-description.enemy-builder-avatar"}
avatar.max_health = 1000000
avatar.healing_per_tick = 100
avatar.alert_when_damaged = false
avatar.running_speed = 0.16
avatar.distance_per_frame = 0.14
avatar.damage_hit_tint = {0.0, 0.3, 0.45, 0.0}
avatar.light =
{
  {
    minimum_darkness = 0.2,
    intensity = 0.45,
    size = 25,
    color = {0.45, 0.85, 1.0}
  },
  {
    type = "oriented",
    minimum_darkness = 0.2,
    picture =
    {
      filename = "__core__/graphics/light-cone.png",
      priority = "extra-high",
      flags = {"light"},
      scale = 2,
      size = 200
    },
    shift = {0, -13},
    size = 2,
    intensity = 0.65,
    color = {0.45, 0.85, 1.0}
  }
}

data:extend({avatar})
