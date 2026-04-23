local builder_data = require("shared.builder_data")

local artillery_item_name = builder_data.prototypes.clanker_artillery_item_name
local artillery_entity_name = builder_data.prototypes.clanker_artillery_entity_name
local artillery_cannon_name = builder_data.prototypes.clanker_artillery_cannon_name
local artillery_shell_name = builder_data.prototypes.clanker_artillery_shell_item_name
local artillery_shell_starting_speed = builder_data.prototypes.clanker_artillery_shell_starting_speed
local artillery_range = builder_data.prototypes.clanker_artillery_range

local clanker_tint = {r = 0.36, g = 0.92, b = 1.0, a = 0.95}
local clanker_dark_tint = {r = 0.55, g = 0.85, b = 0.95, a = 1.0}

local function tint_sprite(sprite, tint)
  if not sprite then
    return
  end

  if sprite.layers then
    for _, layer in ipairs(sprite.layers) do
      tint_sprite(layer, tint)
    end
    return
  end

  if sprite.hr_version then
    tint_sprite(sprite.hr_version, tint)
  end

  if not sprite.draw_as_shadow then
    sprite.tint = tint
  end
end

local artillery_item = table.deepcopy(data.raw.item["artillery-turret"])
artillery_item.name = artillery_item_name
artillery_item.localised_name = {"item-name.clanker-artillery"}
artillery_item.localised_description = {"item-description.clanker-artillery"}
artillery_item.icon = nil
artillery_item.icons = {
  {
    icon = "__base__/graphics/icons/artillery-turret.png",
    tint = clanker_tint
  }
}
artillery_item.hidden = true
artillery_item.auto_recycle = false
artillery_item.place_result = artillery_entity_name
artillery_item.subgroup = "other"
artillery_item.order = "z[enemy-builder]-b[clanker-artillery]"

local artillery_cannon = table.deepcopy(data.raw.gun["artillery-wagon-cannon"])
artillery_cannon.name = artillery_cannon_name
artillery_cannon.localised_name = {"item-name.clanker-artillery-cannon"}
artillery_cannon.localised_description = {"item-description.clanker-artillery-cannon"}
artillery_cannon.hidden = true
artillery_cannon.auto_recycle = false
artillery_cannon.order = "z[enemy-builder]-b[clanker-artillery-cannon]"
artillery_cannon.attack_parameters.range = artillery_range
artillery_cannon.attack_parameters.min_range = 8
artillery_cannon.attack_parameters.ammo_category = artillery_shell_name

local artillery_ammo_category = table.deepcopy(data.raw["ammo-category"]["artillery-shell"])
artillery_ammo_category.name = artillery_shell_name
artillery_ammo_category.localised_name = {"item-name.clanker-artillery-shell"}

local artillery_shell = table.deepcopy(data.raw.ammo["artillery-shell"])
artillery_shell.name = artillery_shell_name
artillery_shell.localised_name = {"item-name.clanker-artillery-shell"}
artillery_shell.localised_description = {"item-description.clanker-artillery-shell"}
artillery_shell.icon = nil
artillery_shell.icons = {
  {
    icon = "__base__/graphics/icons/artillery-shell.png",
    tint = clanker_tint
  }
}
artillery_shell.hidden = true
artillery_shell.auto_recycle = false
artillery_shell.ammo_category = artillery_shell_name
artillery_shell.subgroup = "other"
artillery_shell.order = "z[enemy-builder]-b[clanker-artillery-shell]"
artillery_shell.ammo_type.action.action_delivery.starting_speed = artillery_shell_starting_speed

local artillery_entity = table.deepcopy(data.raw["artillery-turret"]["artillery-turret"])
artillery_entity.name = artillery_entity_name
artillery_entity.localised_name = {"entity-name.clanker-artillery"}
artillery_entity.localised_description = {"entity-description.clanker-artillery"}
artillery_entity.icon = nil
artillery_entity.icons = {
  {
    icon = "__base__/graphics/icons/artillery-turret.png",
    tint = clanker_tint
  }
}
artillery_entity.flags = {"placeable-player", "player-creation"}
artillery_entity.hidden = true
artillery_entity.minable = nil
artillery_entity.fast_replaceable_group = nil
artillery_entity.gun = artillery_cannon_name
artillery_entity.manual_range_modifier = 1
artillery_entity.map_color = {r = 0.18, g = 0.68, b = 0.9, a = 1}

tint_sprite(artillery_entity.base_picture, clanker_dark_tint)
tint_sprite(artillery_entity.cannon_barrel_pictures, clanker_tint)
tint_sprite(artillery_entity.cannon_base_pictures, clanker_tint)
tint_sprite(artillery_entity.water_reflection and artillery_entity.water_reflection.pictures, clanker_tint)

local artillery_recipe = table.deepcopy(data.raw.recipe["artillery-turret"])
artillery_recipe.name = artillery_item_name
artillery_recipe.localised_name = {"recipe-name.clanker-artillery"}
artillery_recipe.hidden = true
artillery_recipe.enabled = false
artillery_recipe.results = {
  {type = "item", name = artillery_item_name, amount = 1}
}

data:extend({
  artillery_ammo_category,
  artillery_item,
  artillery_cannon,
  artillery_shell,
  artillery_entity,
  artillery_recipe
})
