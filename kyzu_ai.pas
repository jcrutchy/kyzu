unit kyzu_ai;

// Faction AI: the regional/tactical layer (ComputeAiRegions/
// NearestAiRegion/LeastStaffedAiRegion - see their own comments) sitting
// between each faction's strategic TAiFactionConfig and RunAI's
// per-unit logic, and RunAllAI, which drives every configured faction
// once per tick from kyzu.lpr's main loop. RunAI acts entirely through
// kyzu_commands' Handle* procedures - the same entry points a real
// client command goes through - so it depends on kyzu_commands as well
// as kyzu_state.

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, fpjson,
  kyzu_types, kyzu_state, kyzu_commands, kyzu_pathfinding, kyzu_bakeconfig;

function ComputeAiRegions(const AFactionName: string; const ACityKeys: array of string): specialize TArray<TAiRegion>;
function NearestAiRegion(const ARegions: array of TAiRegion; PX, PY: Double): Integer;
function LeastStaffedAiRegion(const ARegions: array of TAiRegion; const AUnitType: string): Integer;
procedure RunAI(const AConfig: TAiFactionConfig);
procedure RunAllAI;

implementation

// Builds one TAiRegion per city in ACityKeys (an AI faction's own
// cities - see RunAI's AiCityKeys) and tallies how many of the
// faction's own workers/settlers/soldiers currently belong to each,
// "belong to" meaning nearest-by-distance rather than any explicit
// assignment. This is what turns RunAI's spawning/garrisoning from
// "always city #1" into "whichever of our cities needs it most" -
// the regional/tactical layer sitting between the per-faction
// TAiFactionConfig (strategic) and the per-unit Drive-style logic
// further down RunAI (unit level).
function ComputeAiRegions(const AFactionName: string; const ACityKeys: array of string): specialize TArray<TAiRegion>;
var
  Regions: specialize TArray<TAiRegion>;
  City: TCity;
  UnitPair: specialize TPair<string, TUnit>;
  i, BestIdx: Integer;
  BestDist, Dist: Double;
begin
  SetLength(Regions, Length(ACityKeys));
  CitiesLock.Enter;
  try
    for i := 0 to High(ACityKeys) do
      if Cities.TryGetValue(ACityKeys[i], City) then
      begin
        Regions[i].CityID := City.ID;
        Regions[i].GX := City.GX;
        Regions[i].GY := City.GY;
      end;
  finally
    CitiesLock.Leave;
  end;

  if Length(Regions) = 0 then Exit(Regions);

  UnitsLock.Enter;
  try
    for UnitPair in Units do
    begin
      if UnitPair.Value.Owner <> AFactionName then Continue;

      BestIdx := 0;
      BestDist := WrappedDistance(UnitPair.Value.GX, UnitPair.Value.GY, Regions[0].GX + 0.5, Regions[0].GY + 0.5);
      for i := 1 to High(Regions) do
      begin
        Dist := WrappedDistance(UnitPair.Value.GX, UnitPair.Value.GY, Regions[i].GX + 0.5, Regions[i].GY + 0.5);
        if Dist < BestDist then
        begin
          BestDist := Dist;
          BestIdx := i;
        end;
      end;

      if UnitPair.Value.UnitType = 'worker' then Inc(Regions[BestIdx].WorkerCount)
      else if UnitPair.Value.UnitType = 'settler' then Inc(Regions[BestIdx].SettlerCount)
      else if UnitPair.Value.UnitType = 'soldier' then Inc(Regions[BestIdx].SoldierCount);
    end;
  finally
    UnitsLock.Leave;
  end;

  Result := Regions;
end;

// Index into ARegions whose city is nearest to (PX,PY) - used both to
// pick which understaffed region a new unit spawns into (fewest of
// that unit type first, nearest as a tiebreak - see RunAI) and to
// send an idle soldier home to whichever of the faction's OWN cities
// is closest to it right now, rather than always the first one founded.
function NearestAiRegion(const ARegions: array of TAiRegion; PX, PY: Double): Integer;
var
  i: Integer;
  BestDist, Dist: Double;
begin
  Result := -1;
  if Length(ARegions) = 0 then Exit;
  Result := 0;
  BestDist := WrappedDistance(PX, PY, ARegions[0].GX + 0.5, ARegions[0].GY + 0.5);
  for i := 1 to High(ARegions) do
  begin
    Dist := WrappedDistance(PX, PY, ARegions[i].GX + 0.5, ARegions[i].GY + 0.5);
    if Dist < BestDist then
    begin
      BestDist := Dist;
      Result := i;
    end;
  end;
end;

// Index of the region with the fewest of AUnitType currently nearest
// to it (ties broken by array order, i.e. whichever city was founded
// first) - the "understaffed region" a new spawn of that type should
// go to.
function LeastStaffedAiRegion(const ARegions: array of TAiRegion; const AUnitType: string): Integer;
var
  i, Count, BestCount: Integer;
begin
  Result := 0;
  BestCount := MaxInt;
  for i := 0 to High(ARegions) do
  begin
    if AUnitType = 'worker' then Count := ARegions[i].WorkerCount
    else if AUnitType = 'settler' then Count := ARegions[i].SettlerCount
    else Count := ARegions[i].SoldierCount;
    if Count < BestCount then
    begin
      BestCount := Count;
      Result := i;
    end;
  end;
end;

procedure RunAI(const AConfig: TAiFactionConfig);
var
  HasAiCity: Boolean;
  CityPair: specialize TPair<string, TCity>;
  WorkerCount, SettlerCount, SoldierCount: Integer;
  UnitKeys: array of string;
  UnitPair: specialize TPair<string, TUnit>;
  i, j, KeyIdx, TryX, TryY, SiteGX, SiteGY: Integer;
  U, OtherU: TUnit;
  AssignedNodeID, NewUnitID, AssignedTarget, TargetTechID: string;
  Node: TResourceNode;
  NodeFound, SiteFound, AllFarEnough: Boolean;
  BestNodeID: string;
  BestDist, Dist: Double;
  NodePair: specialize TPair<string, TResourceNode>;
  PayloadStr: string;
  PayloadData: TJSONData;
  TargetLon, TargetLat: Double;
  AiCityKeys: array of string;
  AiCityIdx: Integer;
  CityA, CityB: TCity;
  TargetUnitID, TargetCityID: string;
  BestTargetDist: Double;
  OtherCity: TCity;
  Def: TTechDef;
  AlreadyResearching: Boolean;
  Dummy: TResearchInProgress;
  Regions: specialize TArray<TAiRegion>;
  RegionIdx: Integer;
begin
  HasAiCity := False;
  SetLength(AiCityKeys, 0);
  AiCityIdx := 0;
  CitiesLock.Enter;
  try
    SetLength(AiCityKeys, Cities.Count);
    for CityPair in Cities do
      if CityPair.Value.Owner = AConfig.FactionName then
      begin
        HasAiCity := True;
        AiCityKeys[AiCityIdx] := CityPair.Key;
        Inc(AiCityIdx);
      end;
  finally
    CitiesLock.Leave;
  end;
  SetLength(AiCityKeys, AiCityIdx);
  if not HasAiCity then Exit; // no seeded AI city (see cities.json) - nothing to run yet

  WorkerCount := 0;
  SettlerCount := 0;
  SoldierCount := 0;
  UnitsLock.Enter;
  try
    SetLength(UnitKeys, Units.Count);
    KeyIdx := 0;
    for UnitPair in Units do
    begin
      if UnitPair.Value.Owner = AConfig.FactionName then
      begin
        if UnitPair.Value.UnitType = 'worker' then Inc(WorkerCount)
        else if UnitPair.Value.UnitType = 'settler' then Inc(SettlerCount)
        else if UnitPair.Value.UnitType = 'soldier' then Inc(SoldierCount);
      end;
      UnitKeys[KeyIdx] := UnitPair.Key;
      Inc(KeyIdx);
    end;
  finally
    UnitsLock.Leave;
  end;

  // Regional/tactical layer: which of our own cities is currently
  // understaffed of each unit type, and which is nearest a given
  // point - see ComputeAiRegions/LeastStaffedAiRegion/NearestAiRegion.
  Regions := ComputeAiRegions(AConfig.FactionName, AiCityKeys);

  if (Tick + AConfig.Offset) mod AConfig.TickInterval = 0 then
  begin
    if WorkerCount < AConfig.TargetWorkerCount then
    begin
      RegionIdx := LeastStaffedAiRegion(Regions, 'worker');
      NewUnitID := 'ai_w_' + AConfig.FactionName + '_' + IntToStr(Tick) + '_' + IntToStr(WorkerCount);
      PayloadStr := '{"unit_id":' + JsonQuote(NewUnitID) + ',"lon":' +
        Format('%.4f', [GridToLon(Regions[RegionIdx].GX + 0.5)]) + ',"lat":' +
        Format('%.4f', [GridToLat(Regions[RegionIdx].GY + 0.5)]) + ',"owner":' +
        JsonQuote(AConfig.FactionName) + ',"unit_type":"worker"}';
      PayloadData := GetJSON(PayloadStr);
      try
        HandleSpawn(TJSONObject(PayloadData));
      finally
        PayloadData.Free;
      end;
    end;

    if SettlerCount < AConfig.TargetSettlerCount then
    begin
      RegionIdx := LeastStaffedAiRegion(Regions, 'settler');
      NewUnitID := 'ai_s_' + AConfig.FactionName + '_' + IntToStr(Tick) + '_' + IntToStr(SettlerCount);
      PayloadStr := '{"unit_id":' + JsonQuote(NewUnitID) + ',"lon":' +
        Format('%.4f', [GridToLon(Regions[RegionIdx].GX + 0.5)]) + ',"lat":' +
        Format('%.4f', [GridToLat(Regions[RegionIdx].GY + 0.5)]) + ',"owner":' +
        JsonQuote(AConfig.FactionName) + ',"unit_type":"settler"}';
      PayloadData := GetJSON(PayloadStr);
      try
        HandleSpawn(TJSONObject(PayloadData));
      finally
        PayloadData.Free;
      end;
    end;

    if SoldierCount < AConfig.TargetSoldierCount then
    begin
      RegionIdx := LeastStaffedAiRegion(Regions, 'soldier');
      NewUnitID := 'ai_m_' + AConfig.FactionName + '_' + IntToStr(Tick) + '_' + IntToStr(SoldierCount);
      PayloadStr := '{"unit_id":' + JsonQuote(NewUnitID) + ',"lon":' +
        Format('%.4f', [GridToLon(Regions[RegionIdx].GX + 0.5)]) + ',"lat":' +
        Format('%.4f', [GridToLat(Regions[RegionIdx].GY + 0.5)]) + ',"owner":' +
        JsonQuote(AConfig.FactionName) + ',"unit_type":"soldier"}';
      PayloadData := GetJSON(PayloadStr);
      try
        HandleSpawn(TJSONObject(PayloadData));
      finally
        PayloadData.Free;
      end;
    end;

    // Road building: link every pair of AI-owned cities that isn't
    // already directly connected. O(n^2) over AI's own city count,
    // which stays tiny for the foreseeable lifetime of this project
    // (same "fine at this scale" reasoning the worker-node search
    // above already leans on).
    for i := 0 to High(AiCityKeys) do
      for j := i + 1 to High(AiCityKeys) do
        if not RoadExistsBetween(AiCityKeys[i], AiCityKeys[j]) then
        begin
          CitiesLock.Enter;
          try
            if not (Cities.TryGetValue(AiCityKeys[i], CityA) and Cities.TryGetValue(AiCityKeys[j], CityB)) then
              Continue;
          finally
            CitiesLock.Leave;
          end;
          PayloadStr := '{"road_id":' + JsonQuote('ai_road_' + AiCityKeys[i] + '_' + AiCityKeys[j]) +
            ',"from_city_id":' + JsonQuote(AiCityKeys[i]) + ',"to_city_id":' +
            JsonQuote(AiCityKeys[j]) + ',"by":' + JsonQuote(AConfig.FactionName) + '}';
          PayloadData := GetJSON(PayloadStr);
          try
            HandleBuildRoad(TJSONObject(PayloadData));
          finally
            PayloadData.Free;
          end;
        end;

    // Research: at most one tech in flight at a time (HandleStartResearch
    // enforces this too - the check here just avoids the noise of a
    // rejected research_failed event every AiTickInterval ticks while
    // one is already running). Walks TechOrder (tech.json's own array
    // order) and starts the first tech whose prerequisites are met and
    // whose cost the AI can currently afford, so cheaper/earlier techs
    // in the file tend to get picked up before pricier later ones.
    if AConfig.ResearchEnabled then
    begin
      TechLock.Enter;
      try
        AlreadyResearching := ResearchInProgress.TryGetValue(AConfig.FactionName, Dummy);
      finally
        TechLock.Leave;
      end;

      if not AlreadyResearching then
      begin
        TargetTechID := '';
        for i := 0 to TechOrder.Count - 1 do
        begin
          if not TechDefs.TryGetValue(TechOrder[i], Def) then Continue;
          if HasResearched(AConfig.FactionName, Def.TechID) then Continue;
          if not TechPrereqsMet(AConfig.FactionName, Def) then Continue;
          if not CanAffordCost(AConfig.FactionName, Def.Cost) then Continue;
          TargetTechID := Def.TechID;
          Break;
        end;

        if TargetTechID <> '' then
        begin
          PayloadStr := '{"tech_id":' + JsonQuote(TargetTechID) + ',"by":' +
            JsonQuote(AConfig.FactionName) + '}';
          PayloadData := GetJSON(PayloadStr);
          try
            HandleStartResearch(TJSONObject(PayloadData));
          finally
            PayloadData.Free;
          end;
        end;
      end;
    end;
  end;

  for i := 0 to High(UnitKeys) do
  begin
    UnitsLock.Enter;
    try
      if not Units.TryGetValue(UnitKeys[i], U) then Continue;
    finally
      UnitsLock.Leave;
    end;

    if U.Owner <> AConfig.FactionName then Continue;

    // --- Workers: collect from the nearest node with anything left ---
    if U.UnitType = 'worker' then
    begin
      if not AiUnitTargets.TryGetValue(UnitKeys[i], AssignedNodeID) then
        AssignedNodeID := '';

      NodesLock.Enter;
      try
        // Depleted or never assigned - (re)pick whatever's nearest with
        // anything left. A full scan of Nodes is fine at this map's
        // scale (a handful of seeded nodes), same reasoning as
        // RecomputeDevelopment's full-recompute-over-incremental choice.
        if (AssignedNodeID <> '') and Nodes.TryGetValue(AssignedNodeID, Node) and (Node.Amount <= 0) then
          AssignedNodeID := '';

        if AssignedNodeID = '' then
        begin
          BestNodeID := '';
          BestDist := MaxDouble;
          for NodePair in Nodes do
          begin
            if NodePair.Value.Amount <= 0 then Continue;
            Dist := WrappedDistance(U.GX, U.GY, NodePair.Value.GX, NodePair.Value.GY);
            if Dist < BestDist then
            begin
              BestDist := Dist;
              BestNodeID := NodePair.Key;
            end;
          end;
          AssignedNodeID := BestNodeID;
        end;

        NodeFound := (AssignedNodeID <> '') and Nodes.TryGetValue(AssignedNodeID, Node);
      finally
        NodesLock.Leave;
      end;

      if not NodeFound then Continue; // nothing left anywhere - this worker idles

      AiUnitTargets.AddOrSetValue(UnitKeys[i], AssignedNodeID);

      Dist := WrappedDistance(U.GX, U.GY, Node.GX, Node.GY);

      if Dist <= Balance.CollectRadiusCells then
      begin
        PayloadStr := '{"unit_id":' + JsonQuote(UnitKeys[i]) + ',"node_id":' +
          JsonQuote(AssignedNodeID) + ',"by":' + JsonQuote(AConfig.FactionName) + '}';
        PayloadData := GetJSON(PayloadStr);
        try
          HandleCollect(TJSONObject(PayloadData));
        finally
          PayloadData.Free;
        end;
      end
      else if Length(U.Path) = 0 then
      begin
        // Idle and out of range - (re)issue a move. Once en route,
        // AdvanceUnits carries it there on its own; this only fires again
        // if it arrives, gets interrupted, or its target got reassigned.
        TargetLon := GridToLon(Node.GX);
        TargetLat := GridToLat(Node.GY);
        PayloadStr := '{"unit_id":' + JsonQuote(UnitKeys[i]) + ',"to_lon":' +
          Format('%.4f', [TargetLon]) + ',"to_lat":' + Format('%.4f', [TargetLat]) +
          ',"by":' + JsonQuote(AConfig.FactionName) + '}';
        PayloadData := GetJSON(PayloadStr);
        try
          HandleMove(TJSONObject(PayloadData));
        finally
          PayloadData.Free;
        end;
      end;
      Continue;
    end;

    // --- Settlers: pick an unclaimed site, walk to it, found a city ---
    if U.UnitType = 'settler' then
    begin
      AssignedTarget := '';
      AiUnitTargets.TryGetValue(UnitKeys[i], AssignedTarget);

      // A settler target is stored as "GX,GY" (always contains a comma);
      // a worker's node target is a bare node_id (never does) - sharing
      // AiUnitTargets between the two is safe since each unit ID is only
      // ever used for one unit, so there's no risk of one unit's entry
      // being misread as the other's format.
      SiteFound := False;
      if (AssignedTarget <> '') and (Pos(',', AssignedTarget) > 0) then
      begin
        SiteGX := StrToIntDef(Copy(AssignedTarget, 1, Pos(',', AssignedTarget) - 1), -1);
        SiteGY := StrToIntDef(Copy(AssignedTarget, Pos(',', AssignedTarget) + 1, MaxInt), -1);
        SiteFound := SiteGX >= 0;
      end;

      if SiteFound and (Length(U.Path) = 0) and (Trunc(U.GX) = SiteGX) and (Trunc(U.GY) = SiteGY) then
      begin
        // Arrived - found the city and clear the target so a
        // replacement settler (if this one somehow survives, e.g. the
        // founding fails on a race with something else claiming the
        // site first) picks a fresh site next pass rather than
        // re-trying a now-stale one forever.
        PayloadStr := '{"city_id":' + JsonQuote('ai_city_' + AConfig.FactionName + '_' +
          IntToStr(SiteGX) + '_' + IntToStr(SiteGY)) + ',"unit_id":' +
          JsonQuote(UnitKeys[i]) + ',"by":' + JsonQuote(AConfig.FactionName) + '}';
        PayloadData := GetJSON(PayloadStr);
        try
          HandleFoundCity(TJSONObject(PayloadData));
        finally
          PayloadData.Free;
        end;
        AiUnitTargets.Remove(UnitKeys[i]);
        Continue;
      end;

      if not SiteFound then
      begin
        // Bounded random search around the settler's OWN nearest owned
        // city (its home region - see NearestAiRegion) for a passable
        // cell far enough from EVERY existing city (any owner). A
        // handful of random tries is enough at this map's scale rather
        // than an exhaustive spiral scan, same "good enough, not
        // optimal" spirit as the worker's nearest-node pick. Centering
        // on the settler's own region rather than always the first
        // city founded is what lets a faction's expansion spread out
        // from each of its cities in turn instead of every settler
        // radiating from the same origin point forever.
        RegionIdx := NearestAiRegion(Regions, U.GX, U.GY);
        for j := 1 to 40 do
        begin
          TryX := Trunc(Regions[RegionIdx].GX) + Random(Round(AConfig.ExpansionSearchRadiusCells * 2) + 1) - Round(AConfig.ExpansionSearchRadiusCells);
          TryY := Trunc(Regions[RegionIdx].GY) + Random(Round(AConfig.ExpansionSearchRadiusCells * 2) + 1) - Round(AConfig.ExpansionSearchRadiusCells);
          if (TryX < 0) or (TryX >= Grid.Width) or (TryY < 0) or (TryY >= Grid.Height) then Continue;
          if CellMoveCost(Grid, Config, TryX, TryY) <= 0 then Continue;

          AllFarEnough := True;
          CitiesLock.Enter;
          try
            for OtherCity in Cities.Values do
            begin
              Dist := WrappedDistance(TryX + 0.5, TryY + 0.5, OtherCity.GX + 0.5, OtherCity.GY + 0.5);
              if Dist < AConfig.ExpansionMinCityDistanceCells then
              begin
                AllFarEnough := False;
                Break;
              end;
            end;
          finally
            CitiesLock.Leave;
          end;

          if AllFarEnough then
          begin
            SiteGX := TryX;
            SiteGY := TryY;
            SiteFound := True;
            Break;
          end;
        end;

        if not SiteFound then Continue; // no acceptable site found this pass - try again next tick

        AiUnitTargets.AddOrSetValue(UnitKeys[i], Format('%d,%d', [SiteGX, SiteGY]));
      end;

      if Length(U.Path) = 0 then
      begin
        PayloadStr := '{"unit_id":' + JsonQuote(UnitKeys[i]) + ',"to_lon":' +
          Format('%.4f', [GridToLon(SiteGX + 0.5)]) + ',"to_lat":' +
          Format('%.4f', [GridToLat(SiteGY + 0.5)]) + ',"by":' + JsonQuote(AConfig.FactionName) + '}';
        PayloadData := GetJSON(PayloadStr);
        try
          HandleMove(TJSONObject(PayloadData));
        finally
          PayloadData.Free;
        end;
      end;
      Continue;
    end;

    // --- Soldiers: hunt anyone the AI is at war with, else garrison ---
    if U.UnitType = 'soldier' then
    begin
      TargetUnitID := '';
      BestTargetDist := AConfig.AggressionRangeCells;
      UnitsLock.Enter;
      try
        for UnitPair in Units do
        begin
          OtherU := UnitPair.Value;
          if (OtherU.Owner = '') or (OtherU.Owner = AConfig.FactionName) then Continue;
          if GetDiplomaticStatus(AConfig.FactionName, OtherU.Owner) <> 'war' then Continue;
          Dist := WrappedDistance(U.GX, U.GY, OtherU.GX, OtherU.GY);
          if Dist < BestTargetDist then
          begin
            BestTargetDist := Dist;
            TargetUnitID := UnitPair.Key;
          end;
        end;
      finally
        UnitsLock.Leave;
      end;

      if TargetUnitID <> '' then
      begin
        UnitsLock.Enter;
        try
          Units.TryGetValue(TargetUnitID, OtherU);
        finally
          UnitsLock.Leave;
        end;

        if BestTargetDist <= Balance.AttackRangeCells then
        begin
          PayloadStr := '{"attacker_unit_id":' + JsonQuote(UnitKeys[i]) +
            ',"target_unit_id":' + JsonQuote(TargetUnitID) + ',"by":' +
            JsonQuote(AConfig.FactionName) + '}';
          PayloadData := GetJSON(PayloadStr);
          try
            HandleAttack(TJSONObject(PayloadData));
          finally
            PayloadData.Free;
          end;
        end
        else if Length(U.Path) = 0 then
        begin
          PayloadStr := '{"unit_id":' + JsonQuote(UnitKeys[i]) + ',"to_lon":' +
            Format('%.4f', [GridToLon(OtherU.GX)]) + ',"to_lat":' +
            Format('%.4f', [GridToLat(OtherU.GY)]) + ',"by":' +
            JsonQuote(AConfig.FactionName) + '}';
          PayloadData := GetJSON(PayloadStr);
          try
            HandleMove(TJSONObject(PayloadData));
          finally
            PayloadData.Free;
          end;
        end;
        Continue;
      end;

      // No unit target in range - try an enemy CITY at war with the AI
      // instead, same range/attack-or-approach shape as above.
      TargetCityID := '';
      BestTargetDist := AConfig.AggressionRangeCells;
      CitiesLock.Enter;
      try
        for CityPair in Cities do
        begin
          OtherCity := CityPair.Value;
          if (OtherCity.Owner = '') or (OtherCity.Owner = AConfig.FactionName) then Continue;
          if GetDiplomaticStatus(AConfig.FactionName, OtherCity.Owner) <> 'war' then Continue;
          Dist := WrappedDistance(U.GX, U.GY, OtherCity.GX + 0.5, OtherCity.GY + 0.5);
          if Dist < BestTargetDist then
          begin
            BestTargetDist := Dist;
            TargetCityID := CityPair.Key;
          end;
        end;
      finally
        CitiesLock.Leave;
      end;

      if TargetCityID <> '' then
      begin
        CitiesLock.Enter;
        try
          Cities.TryGetValue(TargetCityID, OtherCity);
        finally
          CitiesLock.Leave;
        end;

        if BestTargetDist <= Balance.AttackRangeCells then
        begin
          PayloadStr := '{"attacker_unit_id":' + JsonQuote(UnitKeys[i]) +
            ',"target_city_id":' + JsonQuote(TargetCityID) + ',"by":' +
            JsonQuote(AConfig.FactionName) + '}';
          PayloadData := GetJSON(PayloadStr);
          try
            HandleAttack(TJSONObject(PayloadData));
          finally
            PayloadData.Free;
          end;
        end
        else if Length(U.Path) = 0 then
        begin
          PayloadStr := '{"unit_id":' + JsonQuote(UnitKeys[i]) + ',"to_lon":' +
            Format('%.4f', [GridToLon(OtherCity.GX + 0.5)]) + ',"to_lat":' +
            Format('%.4f', [GridToLat(OtherCity.GY + 0.5)]) + ',"by":' + JsonQuote(AConfig.FactionName) + '}';
          PayloadData := GetJSON(PayloadStr);
          try
            HandleMove(TJSONObject(PayloadData));
          finally
            PayloadData.Free;
          end;
        end;
        Continue;
      end;

      // Nobody to fight - garrison at the NEAREST of our own cities
      // rather than always the first one founded, so a faction with
      // more than one city ends up with soldiers actually distributed
      // across them instead of every idle soldier converging on city #1.
      RegionIdx := NearestAiRegion(Regions, U.GX, U.GY);
      if (Length(U.Path) = 0) and (WrappedDistance(U.GX, U.GY, Regions[RegionIdx].GX + 0.5, Regions[RegionIdx].GY + 0.5) > Balance.AttackRangeCells * 2) then
      begin
        PayloadStr := '{"unit_id":' + JsonQuote(UnitKeys[i]) + ',"to_lon":' +
          Format('%.4f', [GridToLon(Regions[RegionIdx].GX + 0.5)]) + ',"to_lat":' +
          Format('%.4f', [GridToLat(Regions[RegionIdx].GY + 0.5)]) + ',"by":' + JsonQuote(AConfig.FactionName) + '}';
        PayloadData := GetJSON(PayloadStr);
        try
          HandleMove(TJSONObject(PayloadData));
        finally
          PayloadData.Free;
        end;
      end;
    end;
  end;
end;

// Drives every AI faction in AiFactionConfigs once per tick. RunAI
// itself is always called - its per-unit movement/collection/combat
// pass needs to run every tick for smooth behavior. Only RunAI's OWN
// internal spawn/road/research section is throttled, by that
// faction's TickInterval+Offset (see TAiFactionConfig's comment) -
// staggering which tick each faction's heavier decision pass falls on
// so N factions sharing the same interval don't all recompute on the
// identical tick.
procedure RunAllAI;
var
  i: Integer;
begin
  for i := 0 to High(AiFactionConfigs) do
    RunAI(AiFactionConfigs[i]);
end;

end.
