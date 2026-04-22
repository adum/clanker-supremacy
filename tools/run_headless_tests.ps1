param(
  [string]$FactorioBin = $env:FACTORIO_BIN,
  [string]$ModDir = $env:FACTORIO_MOD_DIR,
  [int]$TimeoutSecs = $(if ($env:FACTORIO_TEST_TIMEOUT_SECS) { [int]$env:FACTORIO_TEST_TIMEOUT_SECS } else { 120 }),
  [string[]]$CaseName = @(),
  [string]$SavePassingCase = $env:FACTORIO_TEST_SAVE_CASE,
  [string]$SaveOutputDir = $env:FACTORIO_TEST_SAVE_OUTPUT_DIR,
  [int]$SaveTimeoutSecs = $(if ($env:FACTORIO_TEST_SAVE_TIMEOUT_SECS) { [int]$env:FACTORIO_TEST_SAVE_TIMEOUT_SECS } else { 30 }),
  [switch]$ListCases,
  [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$modDirDefault = Split-Path -Parent $repoRoot

function Resolve-FactorioBinary {
  param(
    [string]$ConfiguredPath
  )

  $candidates = @()

  if ($ConfiguredPath) {
    $candidates += $ConfiguredPath
  }

  $fromPath = Get-Command factorio.exe -ErrorAction SilentlyContinue
  if ($fromPath) {
    $candidates += $fromPath.Source
  }

  $candidates += @(
    "C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe",
    "C:\Program Files\Steam\steamapps\common\Factorio\bin\x64\factorio.exe",
    "C:\Program Files\Factorio\bin\x64\factorio.exe"
  )

  foreach ($candidate in $candidates | Where-Object { $_ } | Select-Object -Unique) {
    if (Test-Path -LiteralPath $candidate) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  throw "Factorio binary not found. Set FACTORIO_BIN or pass -FactorioBin."
}

function Write-ConfigFile {
  param(
    [string]$Path,
    [string]$WriteDataDir
  )

  $content = @(
    "[path]",
    "read-data=__PATH__system-read-data__",
    "write-data=$WriteDataDir",
    ""
  ) -join "`r`n"

  [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.ASCIIEncoding))
}

function Write-ServerSettingsFile {
  param(
    [string]$Path
  )

  $content = @'
{
  "name": "Enemy Builder Test",
  "description": "Headless Enemy Builder integration test",
  "tags": ["test"],
  "max_players": 0,
  "visibility": {
    "public": false,
    "lan": false
  },
  "require_user_verification": false,
  "allow_commands": "true",
  "autosave_interval": 0,
  "autosave_slots": 1,
  "afk_autokick_interval": 0,
  "auto_pause": false,
  "auto_pause_when_players_connect": false,
  "only_admins_can_pause_the_game": false,
  "autosave_only_on_server": true,
  "non_blocking_saving": false
}
'@

  [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Factorio {
  param(
    [string[]]$Arguments
  )

  $argumentList = @("--config", $script:ConfigPath, "--mod-directory", $script:ModDir) + $Arguments
  $process = Start-Process -FilePath $script:FactorioBin -ArgumentList $argumentList -Wait -NoNewWindow -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Factorio exited with code $($process.ExitCode) while running: $($Arguments -join ' ')"
  }
}

function Escape-LuaString {
  param(
    [string]$Value
  )

  return $Value.Replace("\", "\\").Replace('"', '\"')
}

function New-RemoteSetupCommand {
  param(
    [pscustomobject]$Case
  )

  $setupName = Escape-LuaString $Case.Name
  if ($null -ne $Case.RemoteSetupArg) {
    $setupArg = Escape-LuaString ([string]$Case.RemoteSetupArg)
    return "/silent-command remote.call(""enemy-builder-test"", ""$setupName"", ""$setupArg"")"
  }

  return "/silent-command remote.call(""enemy-builder-test"", ""$setupName"")"
}

function New-ServerSaveCommand {
  param(
    [string]$SaveName
  )

  return "/server-save $SaveName"
}

function New-ServerLauncherFile {
  param(
    [string]$Path,
    [string]$CaseConfigPath,
    [string]$FreshSavePath,
    [string]$ServerSettingsPath,
    [int]$Port,
    [int]$RconPort,
    [string]$RconPassword,
    [string]$OutputPath
  )

  $lines = @(
    "@echo off",
    "`"$script:FactorioBin`" --config `"$CaseConfigPath`" --mod-directory `"$script:ModDir`" --start-server `"$FreshSavePath`" --server-settings `"$ServerSettingsPath`" --port $Port --rcon-port $RconPort --rcon-password `"$RconPassword`" 1>>`"$OutputPath`" 2>>&1"
  )

  [System.IO.File]::WriteAllText($Path, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.ASCIIEncoding))
}

function Get-ChildProcessIds {
  param(
    [int]$ParentId
  )

  return @(
    Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentId" -ErrorAction SilentlyContinue |
      ForEach-Object { [int]$_.ProcessId }
  )
}

function Get-DescendantProcessIds {
  param(
    [int]$ParentId
  )

  $pending = New-Object System.Collections.Generic.Queue[int]
  $seen = New-Object System.Collections.Generic.HashSet[int]
  $results = New-Object System.Collections.Generic.List[int]

  foreach ($childId in Get-ChildProcessIds -ParentId $ParentId) {
    $pending.Enqueue($childId)
  }

  while ($pending.Count -gt 0) {
    $currentId = $pending.Dequeue()
    if ($seen.Add($currentId)) {
      $results.Add($currentId) | Out-Null
      foreach ($childId in Get-ChildProcessIds -ParentId $currentId) {
        $pending.Enqueue($childId)
      }
    }
  }

  return $results.ToArray()
}

function Start-FactorioServer {
  param(
    [string]$CaseConfigPath,
    [string]$FreshSavePath,
    [string]$ServerSettingsPath,
    [int]$Port,
    [int]$RconPort,
    [string]$RconPassword,
    [string]$OutputPath,
    [string]$LauncherPath
  )

  New-ServerLauncherFile -Path $LauncherPath -CaseConfigPath $CaseConfigPath -FreshSavePath $FreshSavePath -ServerSettingsPath $ServerSettingsPath -Port $Port -RconPort $RconPort -RconPassword $RconPassword -OutputPath $OutputPath

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $env:SystemRoot "System32\cmd.exe"
  $psi.Arguments = "/d /c call `"$LauncherPath`""
  $psi.WorkingDirectory = $repoRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $process = [System.Diagnostics.Process]::Start($psi)
  if (-not $process) {
    throw "Failed to start dedicated server launcher."
  }

  return [pscustomobject]@{
    WrapperProcess = $process
    LauncherPath = $LauncherPath
    OutputPath = $OutputPath
  }
}

function Stop-FactorioServer {
  param(
    [pscustomobject]$Server
  )

  if (-not $Server) {
    return
  }

  $wrapper = $Server.WrapperProcess
  if ($wrapper) {
    $descendantIds = @()
    if (-not $wrapper.HasExited) {
      $descendantIds = Get-DescendantProcessIds -ParentId $wrapper.Id
    }

    foreach ($processId in $descendantIds) {
      try {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
      } catch {
      }
    }

    if (-not $wrapper.HasExited) {
      try {
        Stop-Process -Id $wrapper.Id -Force -ErrorAction SilentlyContinue
      } catch {
      }
    }

    try {
      $wrapper.WaitForExit()
    } catch {
    }

    $wrapper.Dispose()
  }
}

function Read-ExactBytes {
  param(
    [System.IO.Stream]$Stream,
    [int]$Length
  )

  $buffer = New-Object byte[] $Length
  $offset = 0

  while ($offset -lt $Length) {
    $readCount = $Stream.Read($buffer, $offset, $Length - $offset)
    if ($readCount -le 0) {
      throw "Unexpected EOF while reading RCON response."
    }
    $offset += $readCount
  }

  return $buffer
}

function Write-RconPacket {
  param(
    [System.IO.Stream]$Stream,
    [int]$RequestId,
    [int]$Type,
    [string]$Body
  )

  $bodyBytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
  $length = 4 + 4 + $bodyBytes.Length + 2
  $payload = New-Object byte[] ($length + 4)

  [System.BitConverter]::GetBytes([int]$length).CopyTo($payload, 0)
  [System.BitConverter]::GetBytes([int]$RequestId).CopyTo($payload, 4)
  [System.BitConverter]::GetBytes([int]$Type).CopyTo($payload, 8)
  [System.Array]::Copy($bodyBytes, 0, $payload, 12, $bodyBytes.Length)
  $payload[$payload.Length - 2] = 0
  $payload[$payload.Length - 1] = 0

  $Stream.Write($payload, 0, $payload.Length)
  $Stream.Flush()
}

function Read-RconPacket {
  param(
    [System.IO.Stream]$Stream
  )

  $lengthBytes = Read-ExactBytes -Stream $Stream -Length 4
  $length = [System.BitConverter]::ToInt32($lengthBytes, 0)
  $payload = Read-ExactBytes -Stream $Stream -Length $length
  $requestId = [System.BitConverter]::ToInt32($payload, 0)
  $type = [System.BitConverter]::ToInt32($payload, 4)
  $bodyLength = [Math]::Max(0, $length - 10)
  $body = [System.Text.Encoding]::ASCII.GetString($payload, 8, $bodyLength)

  return [pscustomobject]@{
    RequestId = $requestId
    Type = $type
    Body = $body
  }
}

function Invoke-RconCommand {
  param(
    [int]$Port,
    [string]$Password,
    [string]$Command,
    [switch]$IgnoreResponseEof
  )

  $client = New-Object System.Net.Sockets.TcpClient
  $client.ReceiveTimeout = 5000
  $client.SendTimeout = 5000
  $client.Connect("127.0.0.1", $Port)

  try {
    $stream = $client.GetStream()

    $authRequestId = 1
    Write-RconPacket -Stream $stream -RequestId $authRequestId -Type 3 -Body $Password

    $authSucceeded = $false
    for ($index = 0; $index -lt 2; $index++) {
      $response = Read-RconPacket -Stream $stream
      if ($response.RequestId -eq $authRequestId) {
        $authSucceeded = $true
        break
      }

      if ($response.RequestId -eq -1) {
        throw "RCON authentication failed."
      }
    }

    if (-not $authSucceeded) {
      throw "RCON authentication did not return a matching response."
    }

    $commandRequestId = 2
    Write-RconPacket -Stream $stream -RequestId $commandRequestId -Type 2 -Body $Command
    try {
      $null = Read-RconPacket -Stream $stream
    } catch {
      if (-not $IgnoreResponseEof -or -not $_.Exception.Message.Contains("Unexpected EOF while reading RCON response.")) {
        throw
      }
    }
  } finally {
    $client.Close()
    $client.Dispose()
  }
}

function Wait-ForLogPattern {
  param(
    [string]$Path,
    [string]$Pattern,
    [int]$TimeoutSeconds
  )

  for ($elapsed = 0; $elapsed -lt $TimeoutSeconds; $elapsed++) {
    if (Test-Path -LiteralPath $Path) {
      $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
      if ($content -like "*$Pattern*") {
        return $true
      }
    }

    Start-Sleep -Seconds 1
  }

  return $false
}

function Wait-ForPath {
  param(
    [string]$Path,
    [int]$TimeoutSeconds
  )

  for ($elapsed = 0; $elapsed -lt $TimeoutSeconds; $elapsed++) {
    if (Test-Path -LiteralPath $Path) {
      return $true
    }

    Start-Sleep -Seconds 1
  }

  return $false
}

function Show-FileIfPresent {
  param(
    [string]$Path
  )

  if (Test-Path -LiteralPath $Path) {
    Get-Content -LiteralPath $Path
  }
}

$allCases = @(
  [pscustomobject]@{ Name = "firearm_outpost_physical_feed"; RemoteSetupName = "setup_firearm_outpost_test_case"; ServerPort = 34197; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "pause_mode_manual_goal"; RemoteSetupName = "setup_pause_mode_manual_goal_test_case"; ServerPort = 34214; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "firearm_outpost_anchor_clearance"; RemoteSetupName = "setup_firearm_outpost_anchored_test_case"; ServerPort = 34198; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "tree_blocked_machine_placement"; RemoteSetupName = "setup_tree_blocked_assembler_test_case"; ServerPort = 34199; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "iron_plate_belt_export_physical_feed"; RemoteSetupName = "setup_iron_plate_belt_export_test_case"; ServerPort = 34200; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "iron_plate_belt_export_ignores_ground_items"; RemoteSetupName = "setup_iron_plate_belt_export_ground_items_test_case"; ServerPort = 34217; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "copper_plate_belt_export_ignores_ground_items"; RemoteSetupName = "setup_copper_plate_belt_export_ground_items_test_case"; ServerPort = 34218; RemoteSetupArg = $null },
    [pscustomobject]@{ Name = "output_belt_prefers_less_ore_direction"; RemoteSetupName = "setup_output_belt_prefers_less_ore_direction_test_case"; ServerPort = 34223; RemoteSetupArg = $null },
    [pscustomobject]@{ Name = "output_belt_layout_places_inserter_then_straight_belts"; RemoteSetupName = "setup_output_belt_layout_places_inserter_then_straight_belts_test_case"; ServerPort = 34226; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "output_belt_sidestep_before_building"; RemoteSetupName = "setup_output_belt_sidestep_before_building_test_case"; ServerPort = 34229; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "steel_output_belt_layout_places_inserter_then_straight_belts"; RemoteSetupName = "setup_steel_output_belt_layout_places_inserter_then_straight_belts_test_case"; ServerPort = 34227; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "steel_output_belt_counts_as_export_site"; RemoteSetupName = "setup_steel_output_belt_counts_as_export_site_test_case"; ServerPort = 34237; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "output_belt_abort_preserves_transport_belts"; RemoteSetupName = "setup_output_belt_abort_preserves_transport_belts_test_case"; ServerPort = 34228; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "solar_panel_factory_physical_feed"; RemoteSetupName = "setup_solar_panel_factory_test_case"; ServerPort = 34206; RemoteSetupArg = $null; TimeoutSecs = 600 },
  [pscustomobject]@{ Name = "gun_turret_factory_physical_feed"; RemoteSetupName = "setup_gun_turret_factory_test_case"; ServerPort = 34253; RemoteSetupArg = $null; TimeoutSecs = 600 },
  [pscustomobject]@{ Name = "build_out_gun_turret_factory_finds_nearby_open_space"; RemoteSetupName = "setup_build_out_gun_turret_factory_finds_nearby_open_space_test_case"; ServerPort = 34254; RemoteSetupArg = $null; TimeoutSecs = 240 },
  [pscustomobject]@{ Name = "solar_panel_factory_east_orientation_physical_feed"; RemoteSetupName = "setup_solar_panel_factory_test_case_east"; ServerPort = 34240; RemoteSetupArg = $null; TimeoutSecs = 600 },
  [pscustomobject]@{ Name = "solar_panel_factory_south_orientation_physical_feed"; RemoteSetupName = "setup_solar_panel_factory_test_case_south"; ServerPort = 34245; RemoteSetupArg = $null; TimeoutSecs = 600 },
  [pscustomobject]@{ Name = "solar_panel_factory_west_orientation_physical_feed"; RemoteSetupName = "setup_solar_panel_factory_test_case_west"; ServerPort = 34246; RemoteSetupArg = $null; TimeoutSecs = 600 },
  [pscustomobject]@{ Name = "solar_panel_factory_opposed_sources_physical_feed"; RemoteSetupName = "setup_solar_panel_factory_opposed_sources_test_case"; ServerPort = 34243; RemoteSetupArg = $null; TimeoutSecs = 600 },
  [pscustomobject]@{ Name = "solar_panel_factory_cross_pressure_physical_feed"; RemoteSetupName = "setup_solar_panel_factory_cross_pressure_test_case"; ServerPort = 34244; RemoteSetupArg = $null; TimeoutSecs = 600 },
  [pscustomobject]@{ Name = "solar_panel_factory_cross_pressure_walled_underground_physical_feed"; RemoteSetupName = "setup_solar_panel_factory_cross_pressure_walled_underground_test_case"; ServerPort = 34250; RemoteSetupArg = $null; TimeoutSecs = 600 },
  [pscustomobject]@{ Name = "solar_panel_factory_jungle_route_physical_feed"; RemoteSetupName = "setup_solar_panel_factory_jungle_route_test_case"; ServerPort = 34251; RemoteSetupArg = $null; TimeoutSecs = 600 },
  [pscustomobject]@{ Name = "solar_panel_factory_missing_sources_reports_blocker"; RemoteSetupName = "setup_solar_panel_factory_missing_sources_reports_blocker_test_case"; ServerPort = 34215; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "solar_panel_factory_block_marks_scaling_milestone"; RemoteSetupName = "setup_solar_panel_factory_block_marks_scaling_milestone_test_case"; ServerPort = 34238; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "solar_panel_factory_iron_input_marks_scaling_milestone"; RemoteSetupName = "setup_solar_panel_factory_iron_input_marks_scaling_milestone_test_case"; ServerPort = 34239; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "solar_panel_factory_power_marks_scaling_milestone"; RemoteSetupName = "setup_solar_panel_factory_power_marks_scaling_milestone_test_case"; ServerPort = 34247; RemoteSetupArg = $null; TimeoutSecs = 600 },
  [pscustomobject]@{ Name = "scaling_collect_switches_site"; RemoteSetupName = "setup_scaling_collect_switches_site_test_case"; ServerPort = 34205; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "scaling_stays_in_starter_core_until_solar_block"; RemoteSetupName = "setup_scaling_stays_in_starter_core_until_solar_block_test_case"; ServerPort = 34236; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "assembler_output_collection_limits"; RemoteSetupName = "setup_assembler_output_collection_limits_test_case"; ServerPort = 34209; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "wait_patrol_avoids_close_reposition"; RemoteSetupName = "setup_wait_patrol_avoids_close_reposition_test_case"; ServerPort = 34210; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "wait_patrol_stops_when_inventory_cap_reached"; RemoteSetupName = "setup_wait_patrol_stops_when_inventory_cap_reached_test_case"; ServerPort = 34224; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "wait_patrol_recovers_coal_when_producers_are_out_of_fuel"; RemoteSetupName = "setup_wait_patrol_recovers_coal_when_producers_are_out_of_fuel_test_case"; ServerPort = 34219; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "machine_refuel_respects_minimum_batch"; RemoteSetupName = "setup_machine_refuel_respects_minimum_batch_test_case"; ServerPort = 34212; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "nearby_tree_harvest_tops_up_wood"; RemoteSetupName = "setup_nearby_tree_harvest_tops_up_wood_test_case"; ServerPort = 34252; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "cleanup_nearby_exhausted_miners"; RemoteSetupName = "setup_cleanup_nearby_exhausted_miners_test_case"; ServerPort = 34232; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "cleanup_exhausted_miner_removes_orphan_furnace"; RemoteSetupName = "setup_cleanup_exhausted_miner_removes_orphan_furnace_test_case"; ServerPort = 34234; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "cleanup_exhausted_miner_removes_orphan_steel_chain"; RemoteSetupName = "setup_cleanup_exhausted_miner_removes_orphan_steel_chain_test_case"; ServerPort = 34235; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "steel_output_retries_blocked_anchors"; RemoteSetupName = "setup_steel_output_retries_blocked_anchors_test_case"; ServerPort = 34213; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "steel_smelting_missing_inserter_does_not_place_free_inserter"; RemoteSetupName = "setup_steel_smelting_missing_inserter_does_not_place_free_inserter_test_case"; ServerPort = 34230; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "copper_smelting_large_patch_open_half"; RemoteSetupName = "setup_copper_smelting_large_patch_open_half_test_case"; ServerPort = 34211; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "iron_plate_belt_export_large_patch_sparse_near_edge"; RemoteSetupName = "setup_iron_plate_belt_export_large_patch_sparse_near_edge_test_case"; ServerPort = 34231; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "iron_plate_belt_export_large_patch_blocked_near_edge"; RemoteSetupName = "setup_iron_plate_belt_export_large_patch_blocked_near_edge_test_case"; ServerPort = 34233; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "scaling_early_expansion_over_coal_reserve"; RemoteSetupName = "setup_scaling_early_expansion_over_coal_reserve_test_case"; ServerPort = 34207; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "scaling_builds_before_coal_reserve"; RemoteSetupName = "setup_scaling_builds_before_coal_reserve_test_case"; ServerPort = 34208; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "scaling_repeats_material_patterns"; RemoteSetupName = "setup_scaling_repeats_material_patterns_test_case"; ServerPort = 34221; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "scaling_firearm_outpost_respects_cap"; RemoteSetupName = "setup_scaling_firearm_outpost_respects_cap_test_case"; ServerPort = 34222; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "scaling_material_expansion_before_firearm_outpost"; RemoteSetupName = "setup_scaling_material_expansion_before_firearm_outpost_test_case"; ServerPort = 34220; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "steel_export_requires_iron_export"; RemoteSetupName = "setup_steel_export_requires_iron_export_test_case"; ServerPort = 34229; RemoteSetupArg = $null },
  [pscustomobject]@{ Name = "steel_smelting_physical_feed_north"; RemoteSetupName = "setup_steel_smelting_test_case"; ServerPort = 34201; RemoteSetupArg = "north" },
  [pscustomobject]@{ Name = "steel_smelting_physical_feed_east"; RemoteSetupName = "setup_steel_smelting_test_case"; ServerPort = 34202; RemoteSetupArg = "east" },
  [pscustomobject]@{ Name = "steel_smelting_physical_feed_south"; RemoteSetupName = "setup_steel_smelting_test_case"; ServerPort = 34203; RemoteSetupArg = "south" },
  [pscustomobject]@{ Name = "steel_smelting_physical_feed_west"; RemoteSetupName = "setup_steel_smelting_test_case"; ServerPort = 34204; RemoteSetupArg = "west" }
)

if ($ListCases) {
  $allCases | ForEach-Object { $_.Name }
  exit 0
}

$selectedCases = @()
if ($CaseName.Count -gt 0) {
  $requested = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $CaseName) {
    [void]$requested.Add($name)
  }

  foreach ($case in $allCases) {
    if ($requested.Contains($case.Name)) {
      $selectedCases += $case
    }
  }

  if ($selectedCases.Count -ne $requested.Count) {
    $availableNames = $allCases | ForEach-Object { $_.Name }
    foreach ($name in $CaseName) {
      if ($availableNames -notcontains $name) {
        throw "Unknown case '$name'. Available cases: $($availableNames -join ', ')"
      }
    }
  }
} else {
  $selectedCases = $allCases
}

$saveCaseName = $null
if ($SavePassingCase) {
  $saveCase = $allCases | Where-Object { $_.Name -ieq $SavePassingCase } | Select-Object -First 1
  if (-not $saveCase) {
    $availableNames = $allCases | ForEach-Object { $_.Name }
    throw "Unknown save case '$SavePassingCase'. Available cases: $($availableNames -join ', ')"
  }

  if (-not $SaveOutputDir) {
    throw "SaveOutputDir is required when SavePassingCase is set."
  }

  $saveCaseName = $saveCase.Name
}

$script:FactorioBin = Resolve-FactorioBinary -ConfiguredPath $FactorioBin
$script:ModDir = if ($ModDir) { (Resolve-Path -LiteralPath $ModDir).Path } else { $modDirDefault }

if (-not (Test-Path -LiteralPath $script:ModDir -PathType Container)) {
  throw "Mod directory not found: $script:ModDir"
}

$resolvedSaveOutputDir = $null
if ($SaveOutputDir) {
  $resolvedSaveOutputDir = [System.IO.Path]::GetFullPath($SaveOutputDir)
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("enemy-builder-tests." + [Guid]::NewGuid().ToString("N"))
$writeDataDir = Join-Path $tempRoot "write-data"
$script:ConfigPath = Join-Path $tempRoot "config.ini"
$serverSettingsPath = Join-Path $tempRoot "server-settings.json"
$freshSavePath = Join-Path $tempRoot "enemy-builder-test.zip"

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $writeDataDir | Out-Null

  Write-ConfigFile -Path $script:ConfigPath -WriteDataDir $writeDataDir
  Write-ServerSettingsFile -Path $serverSettingsPath

  Write-Host "== Enemy Builder headless tests =="
  Write-Host "factorio_bin: $script:FactorioBin"
  Write-Host "timeout_secs: $TimeoutSecs"
  Write-Host "write_data_dir: $writeDataDir"
  if ($CaseName.Count -gt 0) {
    Write-Host "selected_cases: $($selectedCases.Name -join ', ')"
  }
  if ($saveCaseName) {
    New-Item -ItemType Directory -Force -Path $resolvedSaveOutputDir | Out-Null
    Write-Host "save_passing_case: $saveCaseName"
    Write-Host "save_output_dir: $resolvedSaveOutputDir"
  }
  Write-Host

  Write-Host "-- create fresh save"
  Invoke-Factorio -Arguments @("--create", $freshSavePath)

  foreach ($case in $selectedCases) {
    $caseTimeoutSecs = if ($case.PSObject.Properties.Name -contains "TimeoutSecs" -and $case.TimeoutSecs) { [int]$case.TimeoutSecs } else { $TimeoutSecs }
    $caseWriteDataDir = Join-Path $tempRoot ("write-data-" + $case.Name)
    $caseConfigPath = Join-Path $tempRoot ("config-" + $case.Name + ".ini")
    $statusFilePath = Join-Path $caseWriteDataDir ("script-output\" + $case.Name + ".status")
    $statusDirPath = Split-Path -Parent $statusFilePath
    $outputPath = Join-Path $tempRoot ($case.Name + ".log")
    $launcherPath = Join-Path $tempRoot ("start-" + $case.Name + ".cmd")
    $currentLogPath = Join-Path $caseWriteDataDir "factorio-current.log"
    $rconPort = $case.ServerPort + 1000
    $rconPassword = "codex-test-password"

    New-Item -ItemType Directory -Force -Path $caseWriteDataDir | Out-Null
    New-Item -ItemType Directory -Force -Path $statusDirPath | Out-Null
    Write-ConfigFile -Path $caseConfigPath -WriteDataDir $caseWriteDataDir

    Remove-Item -LiteralPath $statusFilePath, $outputPath, $launcherPath -Force -ErrorAction SilentlyContinue

    Write-Host
    Write-Host "-- start dedicated server for $($case.Name)"
    $server = Start-FactorioServer -CaseConfigPath $caseConfigPath -FreshSavePath $freshSavePath -ServerSettingsPath $serverSettingsPath -Port $case.ServerPort -RconPort $rconPort -RconPassword $rconPassword -OutputPath $outputPath -LauncherPath $launcherPath

    try {
      if (-not (Wait-ForLogPattern -Path $outputPath -Pattern "changing state from(CreatingGame) to(InGame)" -TimeoutSeconds 15)) {
        if ($server.WrapperProcess.HasExited) {
          Show-FileIfPresent -Path $outputPath
          throw "Dedicated server exited before it became ready for $($case.Name)."
        }

        Show-FileIfPresent -Path $outputPath
        throw "Dedicated server never reached InGame state for $($case.Name)."
      }

      Write-Host
      Write-Host "-- inject $($case.Name) test case"
      New-Item -ItemType Directory -Force -Path $statusDirPath | Out-Null
      $remoteCommand = New-RemoteSetupCommand -Case $case
      Invoke-RconCommand -Port $rconPort -Password $rconPassword -Command $remoteCommand
      Start-Sleep -Seconds 1
      Invoke-RconCommand -Port $rconPort -Password $rconPassword -Command $remoteCommand

      $statusFound = $false
      for ($elapsed = 0; $elapsed -lt $caseTimeoutSecs; $elapsed++) {
        if (Test-Path -LiteralPath $statusFilePath) {
          $statusFound = $true
          break
        }

        if ($server.WrapperProcess.HasExited) {
          Show-FileIfPresent -Path $outputPath
          throw "Dedicated server exited before producing a status file for $($case.Name)."
        }

        Start-Sleep -Seconds 1
      }

      $statusPassed = $false
      if ($statusFound -and (Select-String -LiteralPath $statusFilePath -Pattern ("PASS " + $case.Name) -SimpleMatch -Quiet)) {
        $statusPassed = $true
      }

      if ($statusPassed -and $saveCaseName -and $case.Name -ieq $saveCaseName) {
        $serverSaveName = "headless-test-$($case.Name).zip"
        $serverSaveDir = Join-Path $caseWriteDataDir "saves"
        $serverSavePath = Join-Path $serverSaveDir $serverSaveName
        $destinationPath = Join-Path $resolvedSaveOutputDir $serverSaveName

        New-Item -ItemType Directory -Force -Path $serverSaveDir | Out-Null
        Write-Host "-- save $($case.Name) result"
        Invoke-RconCommand -Port $rconPort -Password $rconPassword -Command (New-ServerSaveCommand -SaveName $serverSaveName) -IgnoreResponseEof

        if (-not (Wait-ForPath -Path $serverSavePath -TimeoutSeconds $SaveTimeoutSecs)) {
          Show-FileIfPresent -Path $outputPath
          throw "Timed out waiting for saved game '$serverSaveName' for $($case.Name)."
        }

        Copy-Item -LiteralPath $serverSavePath -Destination $destinationPath -Force
        Write-Host "-- copied save to $destinationPath"
      }
    } finally {
      Stop-FactorioServer -Server $server
    }

    Show-FileIfPresent -Path $outputPath

    if (-not (Test-Path -LiteralPath $statusFilePath)) {
      Write-Host
      Write-Host "Headless test timed out before producing a status file for $($case.Name)." -ForegroundColor Red
      Write-Host
      Write-Host "-- factorio-current.log --" -ForegroundColor Red
      Show-FileIfPresent -Path $currentLogPath
      throw "Headless test timed out for $($case.Name)."
    }

    if (-not (Select-String -LiteralPath $statusFilePath -Pattern ("PASS " + $case.Name) -SimpleMatch -Quiet)) {
      Write-Host
      Write-Host "Headless test status did not report PASS for $($case.Name)." -ForegroundColor Red
      Write-Host
      Write-Host "-- status file --" -ForegroundColor Red
      Show-FileIfPresent -Path $statusFilePath
      throw "Headless test failed for $($case.Name)."
    }
  }

  Write-Host
  Write-Host "All requested headless tests passed."
} finally {
  if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
