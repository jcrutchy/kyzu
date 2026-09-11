unit kyzu_persist;

// Reconstructs Units/Cities/Roads/Ledger/tech/diplomacy state from the
// append-only events.jsonl log at startup - see ReplayEventLog's own
// comment for ordering requirements relative to kyzu_loaders' LoadCities.
// Applies logged OUTCOMES directly to kyzu_state's dictionaries rather
// than going through kyzu_commands, since replay must never re-run
// pathfinding or re-validate a command that already succeeded once.

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, fpjson, jsonparser,
  kyzu_types, kyzu_state, kyzu_pathfinding;

procedure ReplayEventLog(const AFilename: string);

implementation

// Reconstructs Units from the event log, in order, before anything else
// touches Units - called from the main block before the reader thread
// starts, so there's no window where a live command could race a
// still-in-progress replay. Malformed lines (e.g. a log truncated by a
// crash mid-write) are skipped rather than aborting startup entirely -
// losing the last partial line is an acceptable, bounded cost; refusing
// to start at all over it would not be.
procedure ReplayEventLog(const AFilename: string);
var
  F: TextFile;
  Line, EventType, UnitID, NodeID, ByActor, LedgerKey, CityID, RoadID, TargetUnitID, AttackerUnitID: string;
  TechID, StatusVal, FactionA, FactionB: string;
  Data: TJSONData;
  Obj: TJSONObject;
  U: TUnit;
  Node: TResourceNode;
  C: TCity;
  R: TRoad;
  InProgressRec: TResearchInProgress;
  Lon, Lat: Double;
  PathArr, PointArr, CostsArr: TJSONArray;
  GridPath: TGridPath;
  i, PathIdx, EventCount, CollectedAmount, CurrentTotal: Integer;
begin
  EventCount := 0;

  if not FileExists(AFilename) then
  begin
    LogDiag('No existing event log at ' + AFilename + ' - starting fresh.');
    Exit;
  end;

  AssignFile(F, AFilename);
  Reset(F);
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      if Line = '' then Continue;

      try
        Data := GetJSON(Line);
      except
        Continue; // malformed line - skip rather than abort startup
      end;

      try
        if Data.JSONType <> jtObject then Continue;
        Obj := TJSONObject(Data);
        EventType := Obj.Get('type', '');
        // NOTE: unit_id is only present on unit-related event types.
        // City/road events carry city_id/road_id instead, so the
        // "no unit_id -> skip" guard that used to sit here up front has
        // been pushed down into each unit-specific branch below -
        // otherwise every city_founded/city_grew/road_built line would
        // get silently skipped.
        UnitID := Obj.Get('unit_id', '');

        if EventType = 'spawned' then
        begin
          if UnitID = '' then Continue;
          Lon := Obj.Get('lon', 0.0);
          Lat := Obj.Get('lat', 0.0);
          U.ID := UnitID;
          U.Owner := Obj.Get('owner', '');
          U.UnitType := Obj.Get('unit_type', 'generic');
          U.GX := LonToGridX(Lon) + 0.5;
          U.GY := LatToGridY(Lat) + 0.5;
          SetLength(U.Path, 0);
          U.PathIndex := 0;
          // Old log lines predating combat won't have "hp" - fall back
          // to the type's current MaxHP, same as a live spawn would.
          U.HP := Obj.Get('hp', GetUnitDef(U.UnitType).MaxHP);
          // Explicitly reset (not left to whatever the previous loop
          // iteration's reused U record happened to hold) - XP/Level
          // for a freshly spawned unit are always 0 regardless of what
          // some earlier unit in this same replay pass leveled up to.
          U.XP := 0;
          U.Level := 0;
          Units.AddOrSetValue(UnitID, U);
        end
        else if EventType = 'path_found' then
        begin
          if UnitID = '' then Continue;
          if Units.TryGetValue(UnitID, U) then
          begin
            PathArr := TJSONArray(Obj.Find('path'));
            if Assigned(PathArr) then
            begin
              SetLength(GridPath, PathArr.Count);
              for i := 0 to PathArr.Count - 1 do
              begin
                PointArr := TJSONArray(PathArr.Items[i]);
                GridPath[i].X := LonToGridX(PointArr.Floats[0]);
                GridPath[i].Y := LatToGridY(PointArr.Floats[1]);
              end;
              U.Path := GridPath;
              U.PathIndex := 0;
              Units.AddOrSetValue(UnitID, U);
            end;
          end;
        end
        else if EventType = 'waypoint' then
        begin
          if UnitID = '' then Continue;
          if Units.TryGetValue(UnitID, U) then
          begin
            PathIdx := Obj.Get('path_index', 0);
            if (PathIdx >= 0) and (PathIdx <= High(U.Path)) then
            begin
              U.PathIndex := PathIdx;
              U.GX := U.Path[PathIdx].X + 0.5;
              U.GY := U.Path[PathIdx].Y + 0.5;
              Units.AddOrSetValue(UnitID, U);
            end;
          end;
        end
        else if EventType = 'arrived' then
        begin
          if UnitID = '' then Continue;
          if Units.TryGetValue(UnitID, U) then
          begin
            SetLength(U.Path, 0);
            Units.AddOrSetValue(UnitID, U);
          end;
        end
        else if EventType = 'despawned' then
        begin
          if UnitID = '' then Continue;
          Units.Remove(UnitID);
        end
        else if EventType = 'collected' then
        begin
          if UnitID = '' then Continue;
          NodeID := Obj.Get('node_id', '');
          CollectedAmount := Obj.Get('amount', 0);
          ByActor := Obj.Get('by', '');
          if NodeID <> '' then
          begin
            NodesLock.Enter;
            try
              if Nodes.TryGetValue(NodeID, Node) then
              begin
                Node.Amount := Node.Amount - CollectedAmount;
                if Node.Amount < 0 then Node.Amount := 0;
                Nodes.AddOrSetValue(NodeID, Node);

                if ByActor <> '' then
                begin
                  LedgerLock.Enter;
                  try
                    LedgerKey := ByActor + '|' + Node.ResourceType;
                    CurrentTotal := 0;
                    Ledger.TryGetValue(LedgerKey, CurrentTotal);
                    Ledger.AddOrSetValue(LedgerKey, CurrentTotal + CollectedAmount);
                  finally
                    LedgerLock.Leave;
                  end;
                end;
              end;
            finally
              NodesLock.Leave;
            end;
          end;
        end
        else if EventType = 'city_founded' then
        begin
          CityID := Obj.Get('city_id', '');
          if CityID = '' then Continue;
          C.ID := CityID;
          C.Owner := Obj.Get('owner', '');
          C.GX := LonToGridX(Obj.Get('lon', 0.0));
          C.GY := LatToGridY(Obj.Get('lat', 0.0));
          C.Population := Obj.Get('population', Balance.CityInitialPopulation);
          // Tick itself resets to 0 on every restart already (see the
          // main block), so a city's growth clock resets alongside it -
          // same precedent as everything else tick-based here, rather
          // than trying to preserve an absolute tick that the rest of
          // the server doesn't preserve either.
          C.LastGrowthTick := 0;
          C.LastUpkeepTick := 0; // same reset-alongside-Tick precedent
          Cities.AddOrSetValue(CityID, C);
        end
        else if EventType = 'city_grew' then
        begin
          CityID := Obj.Get('city_id', '');
          if (CityID <> '') and Cities.TryGetValue(CityID, C) then
          begin
            C.Population := Obj.Get('population', C.Population);
            Cities.AddOrSetValue(CityID, C);
          end;
        end
        else if EventType = 'city_growth_spent' then
        begin
          // Mirrors 'collected' crediting the ledger, but in reverse -
          // an owned city's growth step spends resources (see
          // GrowCities), so replay has to apply the same deduction or a
          // continued events.jsonl would leave the ledger overstated
          // relative to a server that kept running live. Reuses the
          // exact same DeductCost live spending goes through, applied
          // to the "costs" array this event now carries (generic, not
          // fixed wood/stone fields).
          ByActor := Obj.Get('owner', '');
          CostsArr := TJSONArray(Obj.Find('costs'));
          if (ByActor <> '') and Assigned(CostsArr) then
            DeductCost(ByActor, ParseResourceCostList(CostsArr));
        end
        else if EventType = 'road_built' then
        begin
          RoadID := Obj.Get('road_id', '');
          if RoadID = '' then Continue;
          R.ID := RoadID;
          R.FromCityID := Obj.Get('from_city_id', '');
          R.ToCityID := Obj.Get('to_city_id', '');
          R.Owner := Obj.Get('owner', '');
          PathArr := TJSONArray(Obj.Find('path'));
          if Assigned(PathArr) then
          begin
            SetLength(GridPath, PathArr.Count);
            for i := 0 to PathArr.Count - 1 do
            begin
              PointArr := TJSONArray(PathArr.Items[i]);
              GridPath[i].X := LonToGridX(PointArr.Floats[0]);
              GridPath[i].Y := LatToGridY(PointArr.Floats[1]);
            end;
            R.Path := GridPath;
            Roads.AddOrSetValue(RoadID, R);
          end;
        end
        else if EventType = 'unit_attacked' then
        begin
          TargetUnitID := Obj.Get('target_unit_id', '');
          if (TargetUnitID <> '') and Units.TryGetValue(TargetUnitID, U) then
          begin
            U.HP := Obj.Get('remaining_hp', U.HP);
            Units.AddOrSetValue(TargetUnitID, U);
          end;
          // A unit that died from this attack has a corresponding
          // 'despawned' event immediately after it in the log (see
          // HandleAttack), which the existing 'despawned' branch above
          // already handles - no special-casing needed here.

          // The ATTACKER's XP/Level are carried in this same event
          // (see HandleAttack) rather than a separate one, so restore
          // them here too. Old log lines predating veterancy simply
          // won't have these fields - Obj.Get's defaults leave an
          // already-replayed attacker's XP/Level untouched in that case.
          AttackerUnitID := Obj.Get('attacker_unit_id', '');
          if (AttackerUnitID <> '') and Units.TryGetValue(AttackerUnitID, U) then
          begin
            U.XP := Obj.Get('attacker_xp', U.XP);
            U.Level := Obj.Get('attacker_level', U.Level);
            Units.AddOrSetValue(AttackerUnitID, U);
          end;
        end
        else if EventType = 'city_attacked' then
        begin
          CityID := Obj.Get('city_id', '');
          if (CityID <> '') and Cities.TryGetValue(CityID, C) then
          begin
            C.Population := Obj.Get('population_remaining', C.Population);
            Cities.AddOrSetValue(CityID, C);
          end;
        end
        else if EventType = 'city_captured' then
        begin
          CityID := Obj.Get('city_id', '');
          if (CityID <> '') and Cities.TryGetValue(CityID, C) then
          begin
            C.Owner := Obj.Get('new_owner', C.Owner);
            C.Population := Obj.Get('population', C.Population);
            C.LastGrowthTick := 0; // growth clock resets alongside Tick on every restart, same precedent as city_founded/city_grew
            C.LastUpkeepTick := 0;
            Cities.AddOrSetValue(CityID, C);
          end;
        end
        else if EventType = 'city_upkeep_spent' then
        begin
          // Mirrors city_growth_spent - decrements the ledger on
          // replay the same way a live upkeep payment does, so a
          // continued events.jsonl doesn't leave the ledger overstated.
          ByActor := Obj.Get('owner', '');
          CostsArr := TJSONArray(Obj.Find('costs'));
          if (ByActor <> '') and Assigned(CostsArr) then
            DeductCost(ByActor, ParseResourceCostList(CostsArr));
        end
        else if EventType = 'city_population_decayed' then
        begin
          CityID := Obj.Get('city_id', '');
          if (CityID <> '') and Cities.TryGetValue(CityID, C) then
          begin
            C.Population := Obj.Get('population', C.Population);
            Cities.AddOrSetValue(CityID, C);
          end;
        end
        else if EventType = 'city_abandoned' then
        begin
          CityID := Obj.Get('city_id', '');
          if CityID <> '' then
            Cities.Remove(CityID);
        end
        else if EventType = 'road_removed' then
        begin
          RoadID := Obj.Get('road_id', '');
          if RoadID <> '' then
            Roads.Remove(RoadID);
        end
        else if EventType = 'research_cost_spent' then
        begin
          // Mirrors city_growth_spent/city_upkeep_spent.
          ByActor := Obj.Get('owner', '');
          CostsArr := TJSONArray(Obj.Find('costs'));
          if (ByActor <> '') and Assigned(CostsArr) then
            DeductCost(ByActor, ParseResourceCostList(CostsArr));
        end
        else if EventType = 'research_started' then
        begin
          // StartTick resets to 0 alongside every other in-flight
          // clock this server tracks (see LastGrowthTick's own
          // precedent) - Tick itself starts back at 0 on every
          // restart, so a research that was N ticks into a
          // ResearchTicks-tick run before the last stop resumes as if
          // freshly started, the same "restart forgives partial
          // progress" behavior city growth/upkeep already have.
          ByActor := Obj.Get('owner', '');
          TechID := Obj.Get('tech_id', '');
          if (ByActor <> '') and (TechID <> '') then
          begin
            InProgressRec.TechID := TechID;
            InProgressRec.StartTick := 0;
            ResearchInProgress.AddOrSetValue(ByActor, InProgressRec);
          end;
        end
        else if EventType = 'research_completed' then
        begin
          ByActor := Obj.Get('owner', '');
          TechID := Obj.Get('tech_id', '');
          if (ByActor <> '') and (TechID <> '') then
          begin
            ResearchedTech.AddOrSetValue(ByActor + '|' + TechID, True);
            ResearchInProgress.Remove(ByActor);
          end;
        end
        else if EventType = 'diplomacy_status_changed' then
        begin
          FactionA := Obj.Get('faction_a', '');
          FactionB := Obj.Get('faction_b', '');
          StatusVal := Obj.Get('status', '');
          if (FactionA <> '') and (FactionB <> '') then
          begin
            if StatusVal = '' then
              DiplomaticStatus.Remove(DiplomacyKey(FactionA, FactionB))
            else
              DiplomaticStatus.AddOrSetValue(DiplomacyKey(FactionA, FactionB), StatusVal);
          end;
        end;

        Inc(EventCount);
      finally
        Data.Free;
      end;
    end;
  finally
    CloseFile(F);
  end;

  LogDiag('Replayed ' + IntToStr(EventCount) + ' events - ' + IntToStr(Units.Count) + ' units, ' +
    IntToStr(Cities.Count) + ' cities, ' + IntToStr(Roads.Count) + ' roads restored.');
end;

end.
