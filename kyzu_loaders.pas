unit kyzu_loaders;

// Startup-time loaders for every *.json config/seed file (game balance,
// unit types, tech tree, AI faction configs, seed cities, resource
// nodes). Each populates the corresponding global dictionary/var in
// kyzu_state. Only ever called once, from kyzu.lpr's main startup
// sequence - see its own comments for the required load order (cities.json
// before ReplayEventLog, in particular).

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, fpjson, jsonparser,
  kyzu_types, kyzu_state;

procedure LoadResourceNodes(const AFilename: string);
function DefaultGameBalance: TGameBalance;
function LoadGameBalance(const AFilename: string): TGameBalance;
procedure LoadUnitTypes(const AFilename: string);
procedure LoadTechDefs(const AFilename: string);
procedure LoadAiFactionConfigs(const AFilename: string; const ABalance: TGameBalance);
procedure LoadCities(const AFilename: string);

implementation

// Loads static resource nodes from resource_nodes.json - a flat array of
// {id, resource_type, lon, lat, amount}. Missing or malformed file is a
// non-fatal, zero-nodes startup (same tolerance as ReplayEventLog's
// missing events.jsonl) - resource nodes are optional gameplay content,
// not core simulation state the server can't run without.
procedure LoadResourceNodes(const AFilename: string);
var
  Data: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  Node: TResourceNode;
  i: Integer;
  F: TextFile;
  Line, JSONText: string;
begin
  if not FileExists(AFilename) then
  begin
    LogDiag('No resource_nodes.json at ' + AFilename + ' - starting with zero nodes.');
    Exit;
  end;

  JSONText := '';
  AssignFile(F, AFilename);
  Reset(F);
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      JSONText := JSONText + Line;
    end;
  finally
    CloseFile(F);
  end;

  try
    Data := GetJSON(JSONText);
  except
    LogDiag('resource_nodes.json is not valid JSON - starting with zero nodes.');
    Exit;
  end;

  try
    if Data.JSONType <> jtArray then Exit;
    Arr := TJSONArray(Data);
    for i := 0 to Arr.Count - 1 do
    begin
      Obj := TJSONObject(Arr.Items[i]);
      Node.ID := Obj.Get('id', '');
      if Node.ID = '' then Continue;
      Node.ResourceType := Obj.Get('resource_type', 'unknown');
      Node.Lon := Obj.Get('lon', 0.0);
      Node.Lat := Obj.Get('lat', 0.0);
      Node.GX := LonToGridX(Node.Lon) + 0.5;
      Node.GY := LatToGridY(Node.Lat) + 0.5;
      Node.Amount := Obj.Get('amount', 0);
      Nodes.AddOrSetValue(Node.ID, Node);
    end;
    LogDiag('Loaded ' + IntToStr(Nodes.Count) + ' resource nodes.');
  finally
    Data.Free;
  end;
end;

// Every value here is exactly what used to be a hardcoded const in
// this file - used both as the compiled-in fallback when
// game_balance.json is missing/malformed, and as the starting point
// LoadGameBalance overrides field-by-field, so a config file that only
// sets a handful of keys still gets sane values for everything else.
function DefaultGameBalance: TGameBalance;
begin
  Result.BaseSpeed := 0.15;
  Result.CollectRadiusCells := 1.5;
  Result.CollectAmountPerAction := 10;

  Result.CityInitialPopulation := 10;
  Result.CityGrowthAmount := 1;
  Result.CityGrowthTicks := 40;
  Result.CityMaxPopulation := 5000;
  SetLength(Result.CityGrowthCost, 2);
  Result.CityGrowthCost[0].ResourceType := 'wood';
  Result.CityGrowthCost[0].Amount := 5;
  Result.CityGrowthCost[1].ResourceType := 'stone';
  Result.CityGrowthCost[1].Amount := 2;

  Result.DevelopmentRadiusCells := 12;
  Result.DevelopmentMinRadiusCells := 3;
  Result.DevelopmentUpdateTicks := 20;
  Result.RoadDevelopmentRadiusCells := 2;
  Result.RoadDevelopmentPeak := 60.0;
  Result.DevelopmentBroadcastThreshold := 2;

  Result.AttackRangeCells := 1.5;
  Result.SiegeDamagePerAttack := 20;
  Result.CityCaptureResetPopulation := 10;

  Result.CityUpkeepTicks := 60;
  SetLength(Result.CityUpkeepCost, 1);
  Result.CityUpkeepCost[0].ResourceType := 'wood';
  Result.CityUpkeepCost[0].Amount := 1;
  Result.CityDecayAmount := 5;

  Result.AiFactionName := 'ai';
  Result.AiTickInterval := 40;
  Result.AiTargetSettlerCount := 1;
  Result.AiExpansionSearchRadiusCells := 25;
  Result.AiExpansionMinCityDistanceCells := 6;
  Result.AiTargetSoldierCount := 2;
  Result.AiAggressionRangeCells := 15;
  Result.AiResearchEnabled := False;
  Result.AiTargetWorkerCount := 2;

  Result.VeterancyXPPerHit := 10;
  Result.VeterancyXPPerLevel := 30;
  Result.VeterancyMaxLevel := 3;
  Result.VeterancyAttackBonusPerLevel := 5;
  Result.VeterancyHPBonusPerLevel := 10;
end;

// Loads game_balance.json at startup, starting from DefaultGameBalance
// and overriding only the keys actually present - same tolerant,
// non-fatal pattern as LoadResourceNodes/LoadCities/LoadUnitTypes. A
// missing, malformed, or partial file just means some or all values
// fall back to exactly what used to be hardcoded, so this can never
// make the server refuse to start.
function LoadGameBalance(const AFilename: string): TGameBalance;
var
  Data: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  F: TextFile;
  Line, JSONText: string;
begin
  Result := DefaultGameBalance;

  if not FileExists(AFilename) then
  begin
    LogDiag('No game_balance.json at ' + AFilename + ' - using built-in defaults for every value.');
    Exit;
  end;

  JSONText := '';
  AssignFile(F, AFilename);
  Reset(F);
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      JSONText := JSONText + Line;
    end;
  finally
    CloseFile(F);
  end;

  try
    Data := GetJSON(JSONText);
  except
    LogDiag('game_balance.json is not valid JSON - using built-in defaults for every value.');
    Exit;
  end;

  try
    if Data.JSONType <> jtObject then Exit;
    Obj := TJSONObject(Data);

    Result.BaseSpeed := Obj.Get('base_speed', Result.BaseSpeed);
    Result.CollectRadiusCells := Obj.Get('collect_radius_cells', Result.CollectRadiusCells);
    Result.CollectAmountPerAction := Obj.Get('collect_amount_per_action', Result.CollectAmountPerAction);

    Result.CityInitialPopulation := Obj.Get('city_initial_population', Result.CityInitialPopulation);
    Result.CityGrowthAmount := Obj.Get('city_growth_amount', Result.CityGrowthAmount);
    Result.CityGrowthTicks := Obj.Get('city_growth_ticks', Result.CityGrowthTicks);
    Result.CityMaxPopulation := Obj.Get('city_max_population', Result.CityMaxPopulation);
    Arr := TJSONArray(Obj.Find('city_growth_cost'));
    if Assigned(Arr) and (Arr.JSONType = jtArray) then
      Result.CityGrowthCost := ParseResourceCostList(Arr);

    Result.DevelopmentRadiusCells := Obj.Get('development_radius_cells', Result.DevelopmentRadiusCells);
    Result.DevelopmentMinRadiusCells := Obj.Get('development_min_radius_cells', Result.DevelopmentMinRadiusCells);
    Result.DevelopmentUpdateTicks := Obj.Get('development_update_ticks', Result.DevelopmentUpdateTicks);
    Result.RoadDevelopmentRadiusCells := Obj.Get('road_development_radius_cells', Result.RoadDevelopmentRadiusCells);
    Result.RoadDevelopmentPeak := Obj.Get('road_development_peak', Result.RoadDevelopmentPeak);
    Result.DevelopmentBroadcastThreshold := Obj.Get('development_broadcast_threshold', Result.DevelopmentBroadcastThreshold);

    Result.AttackRangeCells := Obj.Get('attack_range_cells', Result.AttackRangeCells);
    Result.SiegeDamagePerAttack := Obj.Get('siege_damage_per_attack', Result.SiegeDamagePerAttack);
    Result.CityCaptureResetPopulation := Obj.Get('city_capture_reset_population', Result.CityCaptureResetPopulation);

    Result.CityUpkeepTicks := Obj.Get('city_upkeep_ticks', Result.CityUpkeepTicks);
    Arr := TJSONArray(Obj.Find('city_upkeep_cost'));
    if Assigned(Arr) and (Arr.JSONType = jtArray) then
      Result.CityUpkeepCost := ParseResourceCostList(Arr);
    Result.CityDecayAmount := Obj.Get('city_decay_amount', Result.CityDecayAmount);

    Result.AiFactionName := Obj.Get('ai_faction_name', Result.AiFactionName);
    Result.AiTickInterval := Obj.Get('ai_tick_interval', Result.AiTickInterval);
    Result.AiTargetWorkerCount := Obj.Get('ai_target_worker_count', Result.AiTargetWorkerCount);
    Result.AiTargetSettlerCount := Obj.Get('ai_target_settler_count', Result.AiTargetSettlerCount);
    Result.AiExpansionSearchRadiusCells := Obj.Get('ai_expansion_search_radius_cells', Result.AiExpansionSearchRadiusCells);
    Result.AiExpansionMinCityDistanceCells := Obj.Get('ai_expansion_min_city_distance_cells', Result.AiExpansionMinCityDistanceCells);
    Result.AiTargetSoldierCount := Obj.Get('ai_target_soldier_count', Result.AiTargetSoldierCount);
    Result.AiAggressionRangeCells := Obj.Get('ai_aggression_range_cells', Result.AiAggressionRangeCells);
    Result.AiResearchEnabled := Obj.Get('ai_research_enabled', Result.AiResearchEnabled);

    Result.VeterancyXPPerHit := Obj.Get('veterancy_xp_per_hit', Result.VeterancyXPPerHit);
    Result.VeterancyXPPerLevel := Obj.Get('veterancy_xp_per_level', Result.VeterancyXPPerLevel);
    Result.VeterancyMaxLevel := Obj.Get('veterancy_max_level', Result.VeterancyMaxLevel);
    Result.VeterancyAttackBonusPerLevel := Obj.Get('veterancy_attack_bonus_per_level', Result.VeterancyAttackBonusPerLevel);
    Result.VeterancyHPBonusPerLevel := Obj.Get('veterancy_hp_bonus_per_level', Result.VeterancyHPBonusPerLevel);

    LogDiag('Loaded game_balance.json.');
  finally
    Data.Free;
  end;
end;

// Loads unit type definitions from unit_types.json at startup - same
// tolerant, non-fatal loading pattern as LoadResourceNodes/LoadCities. A
// missing or malformed file just means every unit type falls back to
// DefaultUnitDef, which is deliberately identical to how units behaved
// before this registry existed.
procedure LoadUnitTypes(const AFilename: string);
var
  Data: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  Def: TUnitDef;
  i: Integer;
  F: TextFile;
  Line, JSONText: string;
begin
  if not FileExists(AFilename) then
  begin
    LogDiag('No unit_types.json at ' + AFilename + ' - all unit types will use default stats.');
    Exit;
  end;

  JSONText := '';
  AssignFile(F, AFilename);
  Reset(F);
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      JSONText := JSONText + Line;
    end;
  finally
    CloseFile(F);
  end;

  try
    Data := GetJSON(JSONText);
  except
    LogDiag('unit_types.json is not valid JSON - all unit types will use default stats.');
    Exit;
  end;

  try
    if Data.JSONType <> jtArray then Exit;
    Arr := TJSONArray(Data);
    for i := 0 to Arr.Count - 1 do
    begin
      Obj := TJSONObject(Arr.Items[i]);
      Def.TypeID := Obj.Get('type_id', '');
      if Def.TypeID = '' then Continue;
      Def.DisplayName := Obj.Get('display_name', Def.TypeID);
      Def.SpeedMultiplier := Obj.Get('speed_multiplier', 1.0);
      Def.CanFoundCity := Obj.Get('can_found_city', False);
      Def.CanCollect := Obj.Get('can_collect', False);
      Def.CollectMultiplier := Obj.Get('collect_multiplier', 1.0);
      Def.MaxHP := Obj.Get('hp', 20);
      Def.Attack := Obj.Get('attack', 0);
      Def.RequiresTech := Obj.Get('requires_tech', '');
      UnitDefs.AddOrSetValue(Def.TypeID, Def);
    end;
    LogDiag('Loaded ' + IntToStr(UnitDefs.Count) + ' unit type definitions.');
  finally
    Data.Free;
  end;
end;

// Loads tech definitions from tech.json at startup - a flat array of
// {tech_id, display_name, prerequisites: [tech_id,...], cost: [{resource_type,amount},...],
// research_ticks}. Same tolerant, non-fatal pattern as LoadUnitTypes: a
// missing or malformed file just means TechDefs stays empty, which in
// turn means HandleStartResearch always fails with "unknown tech" and
// no unit type's RequiresTech can ever be satisfied - a safe, inert
// fallback rather than a startup failure.
procedure LoadTechDefs(const AFilename: string);
var
  Data: TJSONData;
  Arr, PrereqArr, CostArr: TJSONArray;
  Obj: TJSONObject;
  Def: TTechDef;
  i, j: Integer;
  F: TextFile;
  Line, JSONText: string;
begin
  if not FileExists(AFilename) then
  begin
    LogDiag('No tech.json at ' + AFilename + ' - starting with zero tech definitions.');
    Exit;
  end;

  JSONText := '';
  AssignFile(F, AFilename);
  Reset(F);
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      JSONText := JSONText + Line;
    end;
  finally
    CloseFile(F);
  end;

  try
    Data := GetJSON(JSONText);
  except
    LogDiag('tech.json is not valid JSON - starting with zero tech definitions.');
    Exit;
  end;

  try
    if Data.JSONType <> jtArray then Exit;
    Arr := TJSONArray(Data);
    for i := 0 to Arr.Count - 1 do
    begin
      Obj := TJSONObject(Arr.Items[i]);
      Def.TechID := Obj.Get('tech_id', '');
      if Def.TechID = '' then Continue;
      Def.DisplayName := Obj.Get('display_name', Def.TechID);
      Def.ResearchTicks := Obj.Get('research_ticks', 100);

      SetLength(Def.Prerequisites, 0);
      PrereqArr := TJSONArray(Obj.Find('prerequisites'));
      if Assigned(PrereqArr) and (PrereqArr.JSONType = jtArray) then
      begin
        SetLength(Def.Prerequisites, PrereqArr.Count);
        for j := 0 to PrereqArr.Count - 1 do
          Def.Prerequisites[j] := PrereqArr.Strings[j];
      end;

      SetLength(Def.Cost, 0);
      CostArr := TJSONArray(Obj.Find('cost'));
      if Assigned(CostArr) and (CostArr.JSONType = jtArray) then
        Def.Cost := ParseResourceCostList(CostArr);

      TechDefs.AddOrSetValue(Def.TechID, Def);
      TechOrder.Add(Def.TechID);
    end;
    LogDiag('Loaded ' + IntToStr(TechDefs.Count) + ' tech definitions.');
  finally
    Data.Free;
  end;
end;

// Loads ai_factions.json at startup - a flat array of per-faction
// overrides, each falling back to the matching Balance.Ai* field for
// anything it doesn't specify (so a faction entry can be as small as
// {"faction_name":"ai_west"} and just inherit every default, or
// override only the couple of fields that make it distinctive). If the
// file is missing, malformed, or an empty array, synthesizes a SINGLE
// faction entry named Balance.AiFactionName using Balance.Ai* directly
// - this is what keeps a deployment with no ai_factions.json at all
// running exactly one AI faction, same as before this file existed.
procedure LoadAiFactionConfigs(const AFilename: string; const ABalance: TGameBalance);
var
  Data: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  Cfg: TAiFactionConfig;
  i: Integer;
  F: TextFile;
  Line, JSONText: string;
begin
  SetLength(AiFactionConfigs, 0);

  if FileExists(AFilename) then
  begin
    JSONText := '';
    AssignFile(F, AFilename);
    Reset(F);
    try
      while not Eof(F) do
      begin
        ReadLn(F, Line);
        JSONText := JSONText + Line;
      end;
    finally
      CloseFile(F);
    end;

    try
      Data := GetJSON(JSONText);
    except
      Data := nil;
      LogDiag('ai_factions.json is not valid JSON - falling back to a single default AI faction.');
    end;

    if Assigned(Data) then
    begin
      try
        if Data.JSONType = jtArray then
        begin
          Arr := TJSONArray(Data);
          SetLength(AiFactionConfigs, Arr.Count);
          for i := 0 to Arr.Count - 1 do
          begin
            Obj := TJSONObject(Arr.Items[i]);
            Cfg.FactionName := Obj.Get('faction_name', '');
            Cfg.TickInterval := Obj.Get('tick_interval', ABalance.AiTickInterval);
            Cfg.TargetWorkerCount := Obj.Get('target_worker_count', ABalance.AiTargetWorkerCount);
            Cfg.TargetSettlerCount := Obj.Get('target_settler_count', ABalance.AiTargetSettlerCount);
            Cfg.ExpansionSearchRadiusCells := Obj.Get('expansion_search_radius_cells', ABalance.AiExpansionSearchRadiusCells);
            Cfg.ExpansionMinCityDistanceCells := Obj.Get('expansion_min_city_distance_cells', ABalance.AiExpansionMinCityDistanceCells);
            Cfg.TargetSoldierCount := Obj.Get('target_soldier_count', ABalance.AiTargetSoldierCount);
            Cfg.AggressionRangeCells := Obj.Get('aggression_range_cells', ABalance.AiAggressionRangeCells);
            Cfg.ResearchEnabled := Obj.Get('research_enabled', ABalance.AiResearchEnabled);
            Cfg.Offset := i;
            AiFactionConfigs[i] := Cfg;
          end;
        end;
      finally
        Data.Free;
      end;
    end;
  end;

  if Length(AiFactionConfigs) = 0 then
  begin
    Cfg.FactionName := ABalance.AiFactionName;
    Cfg.TickInterval := ABalance.AiTickInterval;
    Cfg.TargetWorkerCount := ABalance.AiTargetWorkerCount;
    Cfg.TargetSettlerCount := ABalance.AiTargetSettlerCount;
    Cfg.ExpansionSearchRadiusCells := ABalance.AiExpansionSearchRadiusCells;
    Cfg.ExpansionMinCityDistanceCells := ABalance.AiExpansionMinCityDistanceCells;
    Cfg.TargetSoldierCount := ABalance.AiTargetSoldierCount;
    Cfg.AggressionRangeCells := ABalance.AiAggressionRangeCells;
    Cfg.ResearchEnabled := ABalance.AiResearchEnabled;
    Cfg.Offset := 0;
    SetLength(AiFactionConfigs, 1);
    AiFactionConfigs[0] := Cfg;
  end;

  LogDiag('Running ' + IntToStr(Length(AiFactionConfigs)) + ' AI faction(s).');
end;

// Loads seed cities from cities.json at startup - a flat array of
// {id, owner, lon, lat, population}. Same non-fatal tolerance as
// LoadResourceNodes: a missing or malformed file just means starting
// with zero seed cities, not a startup failure. Cities founded live via
// game.cmd.found_city afterward work the same either way, since both
// paths write into the same Cities dictionary.
procedure LoadCities(const AFilename: string);
var
  Data: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  C: TCity;
  i: Integer;
  F: TextFile;
  Line, JSONText: string;
begin
  if not FileExists(AFilename) then
  begin
    LogDiag('No cities.json at ' + AFilename + ' - starting with zero seed cities.');
    Exit;
  end;

  JSONText := '';
  AssignFile(F, AFilename);
  Reset(F);
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      JSONText := JSONText + Line;
    end;
  finally
    CloseFile(F);
  end;

  try
    Data := GetJSON(JSONText);
  except
    LogDiag('cities.json is not valid JSON - starting with zero seed cities.');
    Exit;
  end;

  try
    if Data.JSONType <> jtArray then Exit;
    Arr := TJSONArray(Data);
    for i := 0 to Arr.Count - 1 do
    begin
      Obj := TJSONObject(Arr.Items[i]);
      C.ID := Obj.Get('id', '');
      if C.ID = '' then Continue;
      // LoadCities now runs BEFORE ReplayEventLog (see the main block),
      // so at this point Cities only contains whatever LoadCities itself
      // has already added earlier in this same loop - this guards
      // against a duplicate id within cities.json, not against replay
      // (replay hasn't run yet). Actual replayed history is applied
      // afterward, on top of whatever this function seeds.
      if Cities.ContainsKey(C.ID) then Continue;
      C.Owner := Obj.Get('owner', '');
      C.GX := LonToGridX(Obj.Get('lon', 0.0));
      C.GY := LatToGridY(Obj.Get('lat', 0.0));
      C.Population := Obj.Get('population', Balance.CityInitialPopulation);
      C.LastGrowthTick := 0;
      C.LastUpkeepTick := 0;
      Cities.AddOrSetValue(C.ID, C);
    end;
    LogDiag('Loaded ' + IntToStr(Arr.Count) + ' seed cities from cities.json (' + IntToStr(Cities.Count) + ' total before replay).');
  finally
    Data.Free;
  end;
end;

end.
