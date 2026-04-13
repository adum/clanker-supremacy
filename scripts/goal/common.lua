local common = {}

function common.deep_copy(value)
  if type(value) ~= "table" then
    return value
  end

  local copy = {}
  for key, nested_value in pairs(value) do
    copy[common.deep_copy(key)] = common.deep_copy(nested_value)
  end

  return copy
end

function common.clone_position(position)
  if not position then
    return nil
  end

  return {
    x = position.x,
    y = position.y
  }
end

function common.snap_to_tile_center(position)
  if not position then
    return nil
  end

  return {
    x = math.floor(position.x) + 0.5,
    y = math.floor(position.y) + 0.5
  }
end

function common.humanize_identifier(identifier)
  if not identifier or identifier == "" then
    return "Unknown"
  end

  local words = {}
  for word in string.gmatch(identifier:gsub("[_-]+", " "), "%S+") do
    words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
  end

  return table.concat(words, " ")
end

function common.format_position(position)
  if not position then
    return "(?, ?)"
  end

  return string.format("(%.2f, %.2f)", position.x, position.y)
end

return common
