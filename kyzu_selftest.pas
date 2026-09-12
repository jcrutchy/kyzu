unit kyzu_selftest;

// Fast, deterministic startup validation for the live KyzU server.
// These tests deliberately avoid mutating the persistent world or emitting
// gameplay events. They validate the already-loaded runtime state and a few
// core invariants before the tick loop or stdin reader starts.

{$mode objfpc}{$H+}

interface

function RunStartupSelfTests: Boolean;

implementation

uses
  SysUtils, Math, Generics.Collections, fpjson, jsonparser,
  kyzu_types, kyzu_state, kyzu_pathfinding;

type
  TSelfTestProc = procedure;

var
  TestsRun: Integer;
  TestsPassed: Integer;
  FirstFailure: string;

procedure Fail(const AMessage: string);
begin
  raise Exception.Create(AMessage);
end;

procedure AssertTrue(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    Fail(AMessage);
end;

procedure AssertNear(AActual, AExpected, ATolerance: Double; const AMessage: string);
begin
  if Abs(AActual - AExpected) > ATolerance then
    Fail(AMessage + ' (actual=' + FloatToStr(AActual) +
      ', expected=' + FloatToStr(AExpected) + ')');
end;

procedure RunOne(const AName: string; ATest: TSelfTestProc);
begin
  Inc(TestsRun);
  try
    ATest();
    Inc(TestsPassed);
    LogDiag('[TEST] ' + AName + ' ............... PASS');
  except
    on E: Exception do
    begin
      if FirstFailure = '' then
        FirstFailure := AName + ': ' + E.Message;
      LogDiag('[TEST] ' + AName + ' ............... FAIL');
      LogDiag('        ' + E.Message);
    end;
  end;
end;

procedure TestMovementGrid;
begin
  AssertTrue(Grid.Width > 0, 'movement grid width is zero');
  AssertTrue(Grid.Height > 0, 'movement grid height is zero');
  AssertTrue(Length(Grid.Cells) = Grid.Width * Grid.Height,
    'movement grid cell count does not match dimensions');
end;

procedure TestBakeConfig;
begin
  AssertTrue(Length(Config.Classes) > 0, 'no terrain classes loaded');
  AssertTrue(Config.TileSize > 0, 'tile size must be positive');
  AssertTrue(Config.MovementGridPath <> '', 'movement grid path is empty');
end;

procedure TestBalance;
begin
  AssertTrue(Balance.BaseSpeed > 0, 'base speed must be positive');
  AssertTrue(Balance.CollectRadiusCells >= 0, 'collect radius cannot be negative');
  AssertTrue(Balance.CityGrowthTicks > 0, 'city growth ticks must be positive');
  AssertTrue(Balance.CityMaxPopulation > 0, 'city max population must be positive');
  AssertTrue(Balance.DevelopmentUpdateTicks > 0, 'development update interval must be positive');
  AssertTrue(Balance.RoadDevelopmentRadiusCells >= 0, 'road development radius cannot be negative');
  AssertTrue(Balance.AttackRangeCells >= 0, 'attack range cannot be negative');
  AssertTrue(Balance.CityUpkeepTicks > 0, 'city upkeep ticks must be positive');
  AssertTrue(Balance.VeterancyMaxLevel >= 0, 'veterancy max level cannot be negative');
end;

procedure TestCoordinateConversions;
var
  X, Y: Integer;
begin
  AssertTrue(TryLonToGridX(-180.0, X), 'longitude -180 rejected');
  AssertTrue(TryLonToGridX(180.0, X), 'longitude 180 rejected');
  AssertTrue(TryLatToGridY(-90.0, Y), 'latitude -90 rejected');
  AssertTrue(TryLatToGridY(90.0, Y), 'latitude 90 rejected');
  AssertTrue(not TryLonToGridX(180.000001, X), 'longitude above 180 accepted');
  AssertTrue(not TryLonToGridX(-180.000001, X), 'longitude below -180 accepted');
  AssertTrue(not TryLatToGridY(90.000001, Y), 'latitude above 90 accepted');
  AssertTrue(not TryLatToGridY(-90.000001, Y), 'latitude below -90 accepted');
  AssertNear(WrappedDX(0.0, Grid.Width - 1.0), -1.0, 0.001,
    'wrapped X distance does not cross antimeridian correctly');
end;

procedure TestUnitDefinitions;
var
  Pair: specialize TPair<string, TUnitDef>;
  Def: TUnitDef;
begin
  AssertTrue(UnitDefs.Count > 0, 'no unit definitions loaded');
  for Pair in UnitDefs do
  begin
    Def := Pair.Value;
    AssertTrue(Def.TypeID <> '', 'unit definition has empty TypeID: ' + Pair.Key);
    AssertTrue(Def.SpeedMultiplier > 0, 'unit speed must be positive: ' + Pair.Key);
    AssertTrue(Def.MaxHP > 0, 'unit MaxHP must be positive: ' + Pair.Key);
    if Def.RequiresTech <> '' then
      AssertTrue(TechDefs.ContainsKey(Def.RequiresTech),
        'unit ' + Pair.Key + ' requires missing tech ' + Def.RequiresTech);
  end;
end;

procedure TestTechDefinitions;
var
  Pair: specialize TPair<string, TTechDef>;
  Def: TTechDef;
  i: Integer;
begin
  AssertTrue(TechDefs.Count = TechOrder.Count,
    'tech dictionary/order counts differ');
  for Pair in TechDefs do
  begin
    Def := Pair.Value;
    AssertTrue(Def.TechID <> '', 'tech definition has empty TechID');
    AssertTrue(Def.ResearchTicks > 0, 'tech research ticks must be positive: ' + Pair.Key);
    for i := 0 to High(Def.Prerequisites) do
      AssertTrue(TechDefs.ContainsKey(Def.Prerequisites[i]),
        'tech ' + Pair.Key + ' references missing prerequisite ' + Def.Prerequisites[i]);
  end;
end;

procedure TestFactionConfigs;
var
  i: Integer;
begin
  AssertTrue(Length(AiFactionConfigs) > 0, 'no AI faction configuration loaded');
  for i := 0 to High(AiFactionConfigs) do
  begin
    AssertTrue(AiFactionConfigs[i].FactionName <> '', 'AI faction has empty name');
    AssertTrue(AiFactionConfigs[i].TickInterval > 0,
      'AI tick interval must be positive for ' + AiFactionConfigs[i].FactionName);
    AssertTrue(AiFactionConfigs[i].TargetWorkerCount >= 0, 'negative worker target');
    AssertTrue(AiFactionConfigs[i].TargetSettlerCount >= 0, 'negative settler target');
    AssertTrue(AiFactionConfigs[i].TargetSoldierCount >= 0, 'negative soldier target');
  end;
end;

procedure TestSeedWorld;
var
  Pair: specialize TPair<string, TCity>;
  C: TCity;
  NodePair: specialize TPair<string, TResourceNode>;
  N: TResourceNode;
begin
  for Pair in Cities do
  begin
    C := Pair.Value;
    AssertTrue(C.ID = Pair.Key, 'city dictionary key/ID mismatch: ' + Pair.Key);
    AssertTrue((C.GX >= 0) and (C.GX < Grid.Width), 'city X outside grid: ' + Pair.Key);
    AssertTrue((C.GY >= 0) and (C.GY < Grid.Height), 'city Y outside grid: ' + Pair.Key);
    AssertTrue(C.Population >= 0, 'negative city population: ' + Pair.Key);
  end;

  for NodePair in Nodes do
  begin
    N := NodePair.Value;
    AssertTrue(N.ID = NodePair.Key, 'resource node key/ID mismatch: ' + NodePair.Key);
    AssertTrue(N.Amount >= 0, 'negative resource amount: ' + NodePair.Key);
    AssertTrue(N.ResourceType <> '', 'resource node has empty resource type: ' + NodePair.Key);
  end;
end;

procedure TestPathfinding;
var
  X, Y: Integer;
  GoalX, GoalY: Integer;
  Found: Boolean;
  Path: TGridPath;
  i: Integer;
begin
  Found := False;
  X := 0;
  Y := 0;
  for Y := 0 to Grid.Height - 1 do
  begin
    for X := 0 to Grid.Width - 1 do
    begin
      if CellMoveCost(Grid, Config, X, Y) > 0 then
      begin
        GoalX := (X + 1) mod Grid.Width;
        GoalY := Y;
        if CellMoveCost(Grid, Config, GoalX, GoalY) > 0 then
        begin
          Found := True;
          Break;
        end;
      end;
    end;
    if Found then Break;
  end;

  AssertTrue(Found, 'could not find two adjacent passable cells for pathfinding smoke test');
  Path := FindPath(Grid, Config, X, Y, GoalX, GoalY, 10000);
  try
    AssertTrue(Length(Path) >= 2, 'A* failed to connect adjacent passable cells');
    AssertTrue(Path[0].X = X, 'A* path starts at unexpected X');
    AssertTrue(Path[0].Y = Y, 'A* path starts at unexpected Y');
    AssertTrue(Path[High(Path)].X = GoalX, 'A* path ends at unexpected X');
    AssertTrue(Path[High(Path)].Y = GoalY, 'A* path ends at unexpected Y');
    for i := 0 to High(Path) do
      AssertTrue(CellMoveCost(Grid, Config, Path[i].X, Path[i].Y) > 0,
        'A* returned an impassable cell');
  finally
    SetLength(Path, 0);
  end;
end;

procedure TestWireFormat;
var
  Line: string;
  Data, Payload: TJSONData;
  Obj: TJSONObject;
  Escaped: string;
begin
  Escaped := 'qa"\\' + #10 + 'unit';
  Line := MakeEventLine('game.event.self_test', '{"unit_id":' + JsonQuote(Escaped) + '}');
  Data := GetJSON(Line);
  try
    AssertTrue(Data.JSONType = jtObject, 'event envelope is not an object');
    Obj := TJSONObject(Data);
    AssertTrue(Obj.Get('topic', '') = 'game.event.self_test', 'event topic mismatch');
    Payload := GetJSON(Obj.Get('payload', ''));
    try
      AssertTrue(Payload.JSONType = jtObject, 'event payload is not an object');
      AssertTrue(TJSONObject(Payload).Get('unit_id', '') = Escaped,
        'JSON escaping round-trip failed');
    finally
      Payload.Free;
    end;
  finally
    Data.Free;
  end;
end;

function RunStartupSelfTests: Boolean;
begin
  TestsRun := 0;
  TestsPassed := 0;
  FirstFailure := '';

  LogDiag('');
  LogDiag('==================================================');
  LogDiag('KYZU STARTUP REGRESSION TESTS');
  LogDiag('==================================================');

  RunOne('Movement grid', @TestMovementGrid);
  RunOne('Bake configuration', @TestBakeConfig);
  RunOne('Game balance', @TestBalance);
  RunOne('Coordinate conversions', @TestCoordinateConversions);
  RunOne('Unit definitions', @TestUnitDefinitions);
  RunOne('Technology definitions', @TestTechDefinitions);
  RunOne('AI faction configuration', @TestFactionConfigs);
  RunOne('Seed world integrity', @TestSeedWorld);
  RunOne('Pathfinding', @TestPathfinding);
  RunOne('JSON wire format', @TestWireFormat);

  Result := TestsPassed = TestsRun;
  LogDiag('');
  LogDiag(Format('KYZU STARTUP TESTS: %d passed, %d failed',
    [TestsPassed, TestsRun - TestsPassed]));

  if not Result then
  begin
    LogDiag('');
    LogDiag('==================================================');
    LogDiag('KYZU STARTUP FAILURE');
    LogDiag('==================================================');
    LogDiag('The server will NOT start.');
    if FirstFailure <> '' then
      LogDiag('First failure: ' + FirstFailure);
    LogDiag('==================================================');
  end
  else
    LogDiag('KYZU startup validation successful.');
end;

end.
