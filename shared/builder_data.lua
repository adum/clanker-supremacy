local base = require("shared.config.base")
local build_out = require("shared.config.build_out")
local crafting = require("shared.config.crafting")
local logistics = require("shared.config.logistics")
local plans = require("shared.config.plans")
local scaling = require("shared.config.scaling")
local site_patterns = require("shared.config.site_patterns")
local ui = require("shared.config.ui")
local validate = require("shared.config.validate")
local world_item_sources = require("shared.config.world_items")

local builder_data = {
  force_name = base.force_name,
  force = base.force,
  prototypes = base.prototypes,
  default_plan = base.default_plan,
  avatar = base.avatar,
  build = base.build,
  build_out = build_out,
  recovery = base.recovery,
  movement = base.movement,
  ui = ui,
  logistics = logistics,
  world_item_sources = world_item_sources,
  crafting = crafting,
  site_patterns = site_patterns,
  scaling = scaling,
  plans = plans
}

return validate(builder_data)
