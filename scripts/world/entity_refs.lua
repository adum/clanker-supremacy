local entity_refs = {}

function entity_refs.entity_overlaps_resources(entity)
  if not (entity and entity.valid) then
    return false
  end

  return #entity.surface.find_entities_filtered{
    area = entity.selection_box,
    type = "resource",
    limit = 1
  } > 0
end

function entity_refs.find_entity_covering_position(surface, force, entity_name, position, radius, ctx)
  local entities = surface.find_entities_filtered{
    position = position,
    radius = radius or 3,
    name = entity_name,
    force = force
  }

  for _, entity in ipairs(entities) do
    if entity.valid and ctx.point_in_area(position, entity.selection_box) then
      return entity
    end
  end

  return nil
end

function entity_refs.find_entity_at_position(surface, force, entity_name, position, radius)
  return surface.find_entities_filtered{
    position = position,
    radius = radius or 0.1,
    name = entity_name,
    force = force
  }[1]
end

function entity_refs.destroy_entities(entities)
  for _, entity in ipairs(entities or {}) do
    if entity and entity.valid then
      entity.destroy()
    end
  end
end

return entity_refs
