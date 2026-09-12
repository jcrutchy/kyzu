unit kyzu_sim;

// The per-tick world passes that aren't triggered by a client command:
// unit movement (AdvanceUnits), city growth/upkeep, tech research
// progress, and development recomputation. Every one of these is called
// ONLY from kyzu.lpr's main tick loop - never from kyzu_commands or
// kyzu_ai - which is what keeps this a clean one-way dependency on
// kyzu_state alone.

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, fpjson,
  kyzu_types, kyzu_state, kyzu_pathfinding, kyzu_bakeconfig;

procedure GrowCities;
procedure PruneRoadsForCity(const ACityID: string);
procedure ProcessCityUpkeep;
procedure RecomputeDevelopment(ABroadcast: Boolean = True);
procedure ProcessResearch;
procedure AdvanceUnits;

implementation

procedure GrowCities;
var
  Keys: array of string;
  i: Integer;
  C: TCity;
  Pair: specialize TPair<string, TCity>;
  KeyIdx: Integer;
  CanAfford: Boolean;
begin
  CitiesLock.Enter;
  try
    SetLength(Keys, Cities.Count);
    KeyIdx := 0;
    for Pair in Cities do
    begin
      Keys[KeyIdx] := Pair.Key;
      Inc(KeyIdx);
    end;
  finally
    CitiesLock.Leave;
  end;

  for i := 0 to High(Keys) do
  begin
    CitiesLock.Enter;
    try
      if not Cities.TryGetValue(Keys[i], C) then Continue;
    finally
      CitiesLock.Leave;
    end;

    if (C.Population >= Balance.CityMaxPopulation) or (Tick - C.LastGrowthTick < Balance.CityGrowthTicks) then
      Continue;

    CanAfford := True;
    if C.Owner <> '' then
    begin
      CanAfford := CanAffordCost(C.Owner, Balance.CityGrowthCost);
      if CanAfford then DeductCost(C.Owner, Balance.CityGrowthCost);
    end;

    // Not affordable yet - LastGrowthTick is left untouched so this city
    // is simply re-checked next tick rather than waiting a full
    // Balance.CityGrowthTicks interval once resources finally show up.
    if not CanAfford then Continue;

    C.Population := C.Population + Balance.CityGrowthAmount;
    if C.Population > Balance.CityMaxPopulation then C.Population := Balance.CityMaxPopulation;
    C.LastGrowthTick := Tick;

    CitiesLock.Enter;
    try
      Cities.AddOrSetValue(Keys[i], C);
    finally
      CitiesLock.Leave;
    end;

    if (C.Owner <> '') and (Length(Balance.CityGrowthCost) > 0) then
    begin
      LogEvent('{"type":"city_growth_spent","city_id":' + JsonQuote(Keys[i]) +
        ',"owner":' + JsonQuote(C.Owner) + ',"costs":' + CostsToJSON(Balance.CityGrowthCost) + '}');
      SendLine(MakeEventLine('game.event.city_growth_spent', '{"city_id":' + JsonQuote(Keys[i]) +
        ',"owner":' + JsonQuote(C.Owner) + ',"costs":' + CostsToJSON(Balance.CityGrowthCost) + '}'));
    end;

    LogEvent('{"type":"city_grew","city_id":' + JsonQuote(Keys[i]) + ',"population":' + IntToStr(C.Population) + '}');
    SendLine(MakeEventLine('game.event.city_grew', '{"city_id":' + JsonQuote(Keys[i]) + ',"population":' + IntToStr(C.Population) + '}'));
  end;
end;

// Runs on its own clock (LastUpkeepTick), independent of growth - see
// the Balance.CityUpkeepTicks comment for why sharing the growth clock would
// misbehave. A road-connected city's upkeep is free (infrastructure
// sustains it); an isolated owned city must pay its Balance.CityUpkeepCost
// out of its owner's ledger or its population decays. Population
// hitting zero abandons the city entirely - it's removed from Cities,
// not just left at zero, since a city with zero population isn't
// meaningfully a city anymore and leaving it around would keep
// RecomputeDevelopment radiating development from a ghost.
// Removes every road touching ACityID - called when a city is
// abandoned, so a dead city doesn't leave roads that RecomputeDevelopment
// keeps stamping density from forever, and so the road list a fresh
// viewer requests doesn't dangle a reference to a city that no longer
// exists. Snapshots under RoadsLock, releases it, then removes and
// broadcasts per road - keeps each individual RoadsLock hold short
// rather than one long one spanning network/logging I/O.
procedure PruneRoadsForCity(const ACityID: string);
var
  ToRemove: array of string;
  Pair: specialize TPair<string, TRoad>;
  i, Idx: Integer;
begin
  RoadsLock.Enter;
  try
    SetLength(ToRemove, 0);
    for Pair in Roads do
      if (Pair.Value.FromCityID = ACityID) or (Pair.Value.ToCityID = ACityID) then
      begin
        SetLength(ToRemove, Length(ToRemove) + 1);
        ToRemove[High(ToRemove)] := Pair.Key;
      end;
  finally
    RoadsLock.Leave;
  end;

  for i := 0 to High(ToRemove) do
  begin
    RoadsLock.Enter;
    try
      Roads.Remove(ToRemove[i]);
    finally
      RoadsLock.Leave;
    end;
    LogEvent('{"type":"road_removed","road_id":' + JsonQuote(ToRemove[i]) + ',"reason":"city_abandoned"}');
    SendLine(MakeEventLine('game.event.road_removed', '{"road_id":' + JsonQuote(ToRemove[i]) + ',"reason":"city_abandoned"}'));
  end;
end;

procedure ProcessCityUpkeep;
var
  Keys: array of string;
  i: Integer;
  C: TCity;
  Pair: specialize TPair<string, TCity>;
  KeyIdx: Integer;
  Connected, Paid: Boolean;
  NewPop: Integer;
begin
  CitiesLock.Enter;
  try
    SetLength(Keys, Cities.Count);
    KeyIdx := 0;
    for Pair in Cities do
    begin
      Keys[KeyIdx] := Pair.Key;
      Inc(KeyIdx);
    end;
  finally
    CitiesLock.Leave;
  end;

  for i := 0 to High(Keys) do
  begin
    CitiesLock.Enter;
    try
      if not Cities.TryGetValue(Keys[i], C) then Continue;
    finally
      CitiesLock.Leave;
    end;

    // Unowned cities have no ledger to charge and never decay, same
    // exemption GrowCities gives them.
    if (C.Owner = '') or (Tick - C.LastUpkeepTick < Balance.CityUpkeepTicks) then
      Continue;

    Connected := IsCityRoadConnected(Keys[i], C.Owner);

    if Connected then
    begin
      // Free - nothing to deduct, just advance the clock.
      C.LastUpkeepTick := Tick;
      CitiesLock.Enter;
      try
        Cities.AddOrSetValue(Keys[i], C);
      finally
        CitiesLock.Leave;
      end;
      Continue;
    end;

    Paid := CanAffordCost(C.Owner, Balance.CityUpkeepCost);
    if Paid then DeductCost(C.Owner, Balance.CityUpkeepCost);

    C.LastUpkeepTick := Tick;

    if Paid then
    begin
      CitiesLock.Enter;
      try
        Cities.AddOrSetValue(Keys[i], C);
      finally
        CitiesLock.Leave;
      end;
      if Length(Balance.CityUpkeepCost) > 0 then
      begin
        LogEvent('{"type":"city_upkeep_spent","city_id":' + JsonQuote(Keys[i]) +
          ',"owner":' + JsonQuote(C.Owner) + ',"costs":' + CostsToJSON(Balance.CityUpkeepCost) + '}');
        SendLine(MakeEventLine('game.event.city_upkeep_spent', '{"city_id":' + JsonQuote(Keys[i]) +
          ',"owner":' + JsonQuote(C.Owner) + ',"costs":' + CostsToJSON(Balance.CityUpkeepCost) + '}'));
      end;
      Continue;
    end;

    // Couldn't pay - decay instead. An empty stockpile is the actual
    // signal here (upkeep costs are deliberately cheap by default), so
    // this should be rare for an actively-collecting player.
    NewPop := C.Population - Balance.CityDecayAmount;

    if NewPop <= 0 then
    begin
      CitiesLock.Enter;
      try
        Cities.Remove(Keys[i]);
      finally
        CitiesLock.Leave;
      end;
      LogEvent('{"type":"city_abandoned","city_id":' + JsonQuote(Keys[i]) + ',"previous_owner":' + JsonQuote(C.Owner) + '}');
      SendLine(MakeEventLine('game.event.city_abandoned', '{"city_id":' + JsonQuote(Keys[i]) + ',"previous_owner":' + JsonQuote(C.Owner) + '}'));
      PruneRoadsForCity(Keys[i]);
    end
    else
    begin
      C.Population := NewPop;
      CitiesLock.Enter;
      try
        Cities.AddOrSetValue(Keys[i], C);
      finally
        CitiesLock.Leave;
      end;
      LogEvent('{"type":"city_population_decayed","city_id":' + JsonQuote(Keys[i]) + ',"population":' + IntToStr(NewPop) + '}');
      SendLine(MakeEventLine('game.event.city_population_decayed', '{"city_id":' + JsonQuote(Keys[i]) + ',"population":' + IntToStr(NewPop) + '}'));
    end;
  end;
end;

// Recomputes the whole density field from Cities+Roads every
// Balance.DevelopmentUpdateTicks ticks. A full recompute (not incremental
// deltas) is cheap at this map's scale and can never drift from what
// actually exists. Density itself is NEVER logged to events.jsonl -
// it's a deterministic function of city population + road paths at any
// given tick, so replay only needs city_founded/city_grew/road_built to
// reconstruct it, same principle as the ledger being rebuildable from
// collected events alone.
procedure RecomputeDevelopment(ABroadcast: Boolean);
var
  Contrib: specialize TDictionary<string, TDensityCell>;
  NewDensity: specialize TDictionary<string, TDensityCell>;
  C: TCity;
  R: TRoad;
  Cell, OldCell: TDensityCell;
  dx, dy, dist, falloff, val: Double;
  gx, gy, radius, i: Integer;
  key: string;
  Pair: specialize TPair<string, TDensityCell>;
  DeltaJSON: string;
  First: Boolean;
  RoadProgressJSON: string;
  FirstRoadProgress: Boolean;
begin
  Contrib := specialize TDictionary<string, TDensityCell>.Create;
  try
    CitiesLock.Enter;
    try
      for C in Cities.Values do
      begin
        // Both Min() args are Double now (Balance fields), so the
        // whole expression is computed in Double space and Round()ed
        // once at the end into the Integer `radius` this loop needs -
        // Min() has no mixed Double/Integer overload to fall back on.
        radius := Round(Min(Balance.DevelopmentRadiusCells,
          Balance.DevelopmentMinRadiusCells + Balance.DevelopmentRadiusCells * (C.Population / Balance.CityMaxPopulation)));
        for gy := C.GY - radius to C.GY + radius do
          for gx := C.GX - radius to C.GX + radius do
          begin
            if (gx < 0) or (gx >= Grid.Width) or (gy < 0) or (gy >= Grid.Height) then Continue;
            dx := gx - C.GX; dy := gy - C.GY;
            dist := Sqrt(dx * dx + dy * dy);
            if dist > radius then Continue;
            falloff := 1.0 - (dist / radius);
            // Squared falloff gives a denser core with a softer edge,
            // rather than a linear cone - reads more like an actual
            // urban footprint on the map.
            val := falloff * falloff * (C.Population / Balance.CityMaxPopulation) * 255.0;
            key := DensityKey(gx, gy);
            if Contrib.TryGetValue(key, Cell) then
            begin
              // Overlapping cities don't stack additively - the denser
              // of the two influences wins, so two adjacent cities
              // don't saturate the cell between them past what either
              // alone would produce.
              if val > Cell.Level then
              begin
                Cell.Level := Min(255, Round(val));
                Contrib.AddOrSetValue(key, Cell);
              end;
            end
            else
            begin
              Cell.GX := gx; Cell.GY := gy; Cell.Level := Min(255, Round(val));
              Contrib.Add(key, Cell);
            end;
          end;
      end;
    finally
      CitiesLock.Leave;
    end;

    // Only the BUILT portion of each road contributes development -
    // an in-progress road's still-unbuilt tail is just a pathfinding
    // result sitting in R.Path, not a real road yet, and shouldn't
    // stamp density (or, via IsCityRoadConnected, grant upkeep relief)
    // for ground the construction front hasn't reached.
    RoadsLock.Enter;
    try
      for R in Roads.Values do
        for i := 0 to RoadBuiltCells(R) - 1 do
          for gy := R.Path[i].Y - Balance.RoadDevelopmentRadiusCells to R.Path[i].Y + Balance.RoadDevelopmentRadiusCells do
            for gx := R.Path[i].X - Balance.RoadDevelopmentRadiusCells to R.Path[i].X + Balance.RoadDevelopmentRadiusCells do
            begin
              if (gx < 0) or (gx >= Grid.Width) or (gy < 0) or (gy >= Grid.Height) then Continue;
              dx := gx - R.Path[i].X; dy := gy - R.Path[i].Y;
              dist := Sqrt(dx * dx + dy * dy);
              if dist > Balance.RoadDevelopmentRadiusCells then Continue;
              falloff := 1.0 - (dist / Balance.RoadDevelopmentRadiusCells);
              val := falloff * Balance.RoadDevelopmentPeak;
              key := DensityKey(gx, gy);
              if Contrib.TryGetValue(key, Cell) then
              begin
                if val > Cell.Level then
                begin
                  Cell.Level := Min(255, Round(val));
                  Contrib.AddOrSetValue(key, Cell);
                end;
              end
              else
              begin
                Cell.GX := gx; Cell.GY := gy; Cell.Level := Min(255, Round(val));
                Contrib.Add(key, Cell);
              end;
            end;
    finally
      RoadsLock.Leave;
    end;

    DeltaJSON := '[';
    First := True;
    DensityLock.Enter;
    try
      NewDensity := specialize TDictionary<string, TDensityCell>.Create;
      for Pair in Contrib do
      begin
        Cell := Pair.Value;
        NewDensity.Add(Pair.Key, Cell);
        OldCell.Level := 0;
        Density.TryGetValue(Pair.Key, OldCell);
        if Abs(Integer(Cell.Level) - Integer(OldCell.Level)) >= Balance.DevelopmentBroadcastThreshold then
        begin
          if not First then DeltaJSON := DeltaJSON + ',';
          First := False;
          DeltaJSON := DeltaJSON + Format('{"gx":%d,"gy":%d,"d":%d}', [Cell.GX, Cell.GY, Cell.Level]);
        end;
      end;

      // A cell that was previously developed but has NO current
      // contribution at all - a city shrank away from it, was captured
      // down to nothing, was abandoned, or a road touching it was
      // removed - never appears in Contrib above, so the loop over
      // Contrib alone can never tell a connected viewer it faded. That
      // viewer would otherwise keep rendering the cell at its last
      // known peak density forever, since nothing ever says otherwise.
      for Pair in Density do
      begin
        if Contrib.ContainsKey(Pair.Key) then Continue;
        if Pair.Value.Level >= Balance.DevelopmentBroadcastThreshold then
        begin
          if not First then DeltaJSON := DeltaJSON + ',';
          First := False;
          DeltaJSON := DeltaJSON + Format('{"gx":%d,"gy":%d,"d":0}', [Pair.Value.GX, Pair.Value.GY]);
        end;
      end;

      Density.Free;
      Density := NewDensity;
    finally
      DensityLock.Leave;
    end;

    if ABroadcast and (DeltaJSON <> '[') then
    begin
      DeltaJSON := DeltaJSON + ']';
      SendLine(MakeEventLine('game.event.development_delta', '{"cells":' + DeltaJSON + '}'));
    end;

    // Piggybacks on this same DevelopmentUpdateTicks cadence rather than
    // a separate timer - roads already get walked above for density, so
    // this just reports what RoadBuiltCells already computed for each
    // one. Only still-under-construction roads are reported; once a
    // road completes, the client already has its full path from
    // road_built/road_list and needs no further updates - same
    // "broadcast only while something's actually changing" shape as
    // development_delta above.
    if ABroadcast then
    begin
      RoadProgressJSON := '[';
      FirstRoadProgress := True;
      RoadsLock.Enter;
      try
        for R in Roads.Values do
        begin
          if RoadIsComplete(R) then Continue;
          if not FirstRoadProgress then RoadProgressJSON := RoadProgressJSON + ',';
          FirstRoadProgress := False;
          RoadProgressJSON := RoadProgressJSON + Format('{"road_id":%s,"built_cells":%d,"total_cells":%d}',
            [JsonQuote(R.ID), RoadBuiltCells(R), Length(R.Path)]);
        end;
      finally
        RoadsLock.Leave;
      end;
      if not FirstRoadProgress then
      begin
        RoadProgressJSON := RoadProgressJSON + ']';
        SendLine(MakeEventLine('game.event.road_progress', '{"roads":' + RoadProgressJSON + '}'));
      end;
    end;
  finally
    Contrib.Free;
  end;
end;

// Advances every faction's in-progress research once per tick - same
// "snapshot keys, then process" shape as GrowCities/ProcessCityUpkeep,
// which matters here too: completing a research can theoretically
// (via a future scripted reaction) trigger a new HandleStartResearch,
// and iterating a live dictionary while it's being mutated elsewhere
// is exactly what that snapshot avoids.
procedure ProcessResearch;
var
  Keys: array of string;
  i, KeyIdx: Integer;
  Pair: specialize TPair<string, TResearchInProgress>;
  InProgress: TResearchInProgress;
  Def: TTechDef;
begin
  TechLock.Enter;
  try
    SetLength(Keys, ResearchInProgress.Count);
    KeyIdx := 0;
    for Pair in ResearchInProgress do
    begin
      Keys[KeyIdx] := Pair.Key;
      Inc(KeyIdx);
    end;
  finally
    TechLock.Leave;
  end;

  for i := 0 to High(Keys) do
  begin
    TechLock.Enter;
    try
      if not ResearchInProgress.TryGetValue(Keys[i], InProgress) then Continue;
    finally
      TechLock.Leave;
    end;

    if not TechDefs.TryGetValue(InProgress.TechID, Def) then Continue; // tech.json changed out from under a running research - just stalls rather than crashing
    if Tick - InProgress.StartTick < Def.ResearchTicks then Continue;

    TechLock.Enter;
    try
      ResearchedTech.AddOrSetValue(Keys[i] + '|' + InProgress.TechID, True);
      ResearchInProgress.Remove(Keys[i]);
    finally
      TechLock.Leave;
    end;

    LogEvent('{"type":"research_completed","owner":' + JsonQuote(Keys[i]) + ',"tech_id":' + JsonQuote(InProgress.TechID) + '}');
    SendLine(MakeEventLine('game.event.research_completed', '{"owner":' + JsonQuote(Keys[i]) +
      ',"tech_id":' + JsonQuote(InProgress.TechID) + '}'));
  end;
end;

// Advances every unit with an in-progress path by one tick's worth of
// movement, and broadcasts its position - only for units actually
// moving, so idle units generate zero bus traffic on their own. Position
// is reported as fractional lon/lat (not snapped to grid cells) so the
// viewer's own between-frame interpolation has genuinely smooth input to
// work with, not just a staircase of cell-to-cell jumps.
procedure AdvanceUnits;
var
  Keys: array of string;
  i: Integer;
  U: TUnit;
  TargetX, TargetY: Integer;
  StepCost, MoveAmount, DX, DY, Dist: Double;
  Pair: specialize TPair<string, TUnit>;
  KeyIdx: Integer;
  PositionLine: string;
begin
  UnitsLock.Enter;
  try
    SetLength(Keys, Units.Count);
    KeyIdx := 0;
    for Pair in Units do
    begin
      Keys[KeyIdx] := Pair.Key;
      Inc(KeyIdx);
    end;
  finally
    UnitsLock.Leave;
  end;

  for i := 0 to High(Keys) do
  begin
    // The read (TryGetValue), the movement computation, and the write
    // back (AddOrSetValue) are ALL held under one UnitsLock acquisition
    // now, rather than three separate ones with the actual computation
    // happening lock-free in between. That gap used to let a command
    // arriving on TStdinReaderThread for this exact unit - a move
    // (new path assigned, then silently overwritten back to the stale
    // one this loop iteration already had in hand), a despawn, or a
    // death from HandleAttack (Units.Remove, then this iteration's
    // finishing AddOrSetValue would resurrect it right back into
    // existence) - slip in between this loop's read and its write and
    // get silently clobbered or undone. Holding the lock for the whole
    // step closes that window entirely rather than trying to detect it
    // after the fact.
    UnitsLock.Enter;
    try
      if not Units.TryGetValue(Keys[i], U) then Continue;

      if (Length(U.Path) = 0) or (U.PathIndex >= High(U.Path)) then
        Continue; // idle - nothing to advance, nothing to broadcast

      TargetX := U.Path[U.PathIndex + 1].X;
      TargetY := U.Path[U.PathIndex + 1].Y;
      StepCost := CellMoveCost(Grid, Config, TargetX, TargetY);
      if StepCost <= 0 then StepCost := 1; // shouldn't happen, path was validated - stay safe rather than divide by zero
      MoveAmount := (Balance.BaseSpeed * GetUnitDef(U.UnitType).SpeedMultiplier) / StepCost;

      // WrappedDX (not a plain subtraction) - a path can legitimately
      // cross the ±180° antimeridian seam (kyzu_pathfinding.pas
      // supports it), and a raw (TargetX + 0.5) - U.GX would compute a
      // delta of roughly -Grid.Width instead of the true short step of
      // ~1 cell, sending the unit on a hundreds-of-ticks trip in
      // reverse around the entire planet instead of one step forward.
      DX := WrappedDX(U.GX, TargetX + 0.5);
      DY := (TargetY + 0.5) - U.GY;
      Dist := Sqrt(DX * DX + DY * DY);

      if Dist <= MoveAmount then
      begin
        U.GX := TargetX + 0.5;
        U.GY := TargetY + 0.5;
        Inc(U.PathIndex);
        LogEvent('{"type":"waypoint","unit_id":' + JsonQuote(Keys[i]) + ',"path_index":' + IntToStr(U.PathIndex) + '}');

        if U.PathIndex >= High(U.Path) then
        begin
          SetLength(U.Path, 0); // arrived - unit goes idle, stops generating traffic
          LogEvent('{"type":"arrived","unit_id":' + JsonQuote(Keys[i]) + '}');
          SendLine(MakeEventLine('game.event.arrived', '{"unit_id":' + JsonQuote(Keys[i]) + '}'));
        end;
      end
      else
      begin
        U.GX := U.GX + (DX / Dist) * MoveAmount;
        U.GY := U.GY + (DY / Dist) * MoveAmount;
        // A step whose wrapped delta pointed across the seam can walk
        // U.GX slightly outside [0, Grid.Width) - wrap it back in.
        if U.GX < 0 then U.GX := U.GX + Grid.Width
        else if U.GX >= Grid.Width then U.GX := U.GX - Grid.Width;
      end;

      Units.AddOrSetValue(Keys[i], U);

      // Build the event while the unit state is protected, but do not hold
      // UnitsLock across stdout I/O. A slow downstream consumer (VDRX, a
      // WebSocket client, or even a full OS pipe) must not stall commands,
      // combat, spawning, or other simulation work behind this lock.
      PositionLine := MakeEventLine('game.event.position', '{"unit_id":' + JsonQuote(Keys[i]) +
        ',"lon":' + Format('%.4f', [GridToLon(U.GX)]) + ',"lat":' + Format('%.4f', [GridToLat(U.GY)]) + '}');
    finally
      UnitsLock.Leave;
    end;

    SendLine(PositionLine);
  end;
end;

end.
