program kyzu;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, Math, SyncObjs, Generics.Collections, fpjson, jsonparser,
  kyzu_bakeconfig, kyzu_pathfinding;

const
  // Grid cells per tick at move_cost=1.0 - first-pass tuning value, same
  // spirit as the move_cost numbers themselves: adjust once actual
  // gameplay pacing is something to judge against, not before.
  BaseSpeed = 0.15;
  // How close (in grid cells) a unit must be to a node to collect from
  // it, and how much a single collect command takes - both first-pass
  // tuning values, same spirit as BaseSpeed above.
  CollectRadiusCells = 1.5;
  CollectAmountPerAction = 10;
  // City/development tuning - first-pass values, same spirit as BaseSpeed.
  CityInitialPopulation = 10;
  CityGrowthAmount = 1;         // population gained per growth step
  // First-pass growth recipe, hardcoded to the "wood"/"stone" resource
  // types resource_nodes.json actually seeds - if new resource types get
  // added that cities should consume instead of (or alongside) these,
  // this is the place to extend. An unowned city (Owner = '') has no
  // ledger to charge and keeps growing on the timer alone, same as
  // before this feature existed.
  CityGrowthWoodCost = 5;
  CityGrowthStoneCost = 2;
  CityGrowthTicks = 40;         // ticks between growth steps (~2s @ 20 ticks/sec)
  CityMaxPopulation = 5000;
  DevelopmentRadiusCells = 12;  // max distance a mature city's density reaches
  DevelopmentUpdateTicks = 20;  // recompute/broadcast interval (~1s)
  RoadDevelopmentRadiusCells = 2;
  DevelopmentBroadcastThreshold = 2; // ignore sub-threshold quantized changes
  // Combat tuning - first-pass values, same spirit as BaseSpeed. Reuses
  // CollectRadiusCells' distance idiom rather than inventing a separate
  // one, since "close enough to act on" means the same thing here as it
  // does for collecting.
  AttackRangeCells = 1.5;
  // A city's Population doubles as its defense pool - no separate HP
  // field needed. Deliberate: a captured city being freshly decimated
  // ties combat back into the same growth loop everything else already
  // feeds, rather than adding a third parallel numeric resource.
  SiegeDamagePerAttack = 20;
  CityCaptureResetPopulation = 10; // population the city starts at under its new owner
  // Upkeep runs on its OWN clock (LastUpkeepTick), deliberately separate
  // from LastGrowthTick - if it shared the growth clock, a city stalled
  // on an unaffordable growth cost would get re-charged upkeep every
  // single tick until growth became affordable, since growth's "stall
  // and retry immediately" behavior never advances that shared clock.
  // An unowned city has no ledger to charge and never decays, same
  // "nobody to charge" exemption growth already uses.
  CityUpkeepTicks = 60;  // ~3s at 20 ticks/sec - a bit slower than growth's cadence, decay shouldn't feel twitchy
  CityUpkeepCost = 1;    // wood per upkeep cycle - cheap; decay signals a genuinely empty stockpile, not routine friction
  // Waived entirely if the city has a road to another city under the
  // same owner - infrastructure sustains it instead of raw stockpile,
  // which is what actually gives roads a reason to exist beyond decor.
  CityDecayAmount = 5;   // population lost per unpaid upkeep cycle
  // A single autonomous AI faction, driven entirely from the tick loop
  // via internal calls into HandleSpawn/HandleMove/HandleCollect - it
  // plays by exactly the same rules a human faction does (ownership
  // checks, movement costs, node depletion), just issuing its own
  // commands instead of a client's. It needs an owned city to already
  // exist (seeded via cities.json) - it never bootstraps one for
  // itself, keeping its logic scoped to "run an economy", not "start
  // a civilization from nothing".
  AiFactionName = 'ai';
  AiTickInterval = 40; // ~2s at 20 ticks/sec - how often it considers spawning a new worker
  AiTargetWorkerCount = 2;

type
  TUnit = record
    ID: string;
    Owner: string;      // faction/player id, '' = unowned
    UnitType: string;   // key into UnitDefs - see TUnitDef below
    GX, GY: Double; // fractional grid position, for smooth interpolated reporting
    Path: TGridPath;
    PathIndex: Integer; // index of the path node the unit is currently departing from
    HP: Integer;    // current hit points, initialized from UnitDefs[UnitType].MaxHP at spawn
  end;

  // Static resource nodes - placed once from resource_nodes.json at
  // startup, never moved, only depleted. GX/GY are cached grid
  // coordinates computed once at load, so HandleCollect's distance
  // check against a moving unit doesn't repeat the lon/lat conversion
  // on every call.
  TResourceNode = record
    ID: string;
    ResourceType: string;
    Lon, Lat: Double;
    GX, GY: Double;
    Amount: Integer;
  end;

  // Cities are stationary, cell-snapped population centers seeded either
  // from cities.json at startup or founded live via game.cmd.found_city.
  // Population is the sole driver of a city's development footprint -
  // see RecomputeDevelopment.
  TCity = record
    ID: string;
    Owner: string;
    GX, GY: Integer;
    Population: Integer;
    LastGrowthTick: Int64;
    LastUpkeepTick: Int64; // separate clock from LastGrowthTick - see ProcessCityUpkeep
  end;

  // A built connection between two cities - path is computed once via
  // the same A* used for unit movement, then cached and reused as a
  // linear development source. Roads never move and are never removed
  // once built (no despawn/demolish command exists yet).
  TRoad = record
    ID: string;
    FromCityID, ToCityID: string;
    Owner: string;
    Path: TGridPath;
  end;

  // Quantized development intensity for one cell, carrying its own GX/GY
  // so callers never need to parse them back out of a "gx,gy" string key.
  TDensityCell = record
    GX, GY: Integer;
    Level: Byte; // 0..255
  end;

  // A unit type's gameplay-affecting stats, keyed by the free-form
  // UnitType string on TUnit. Loaded once from unit_types.json into a
  // static registry (UnitDefs) - not per-unit-instance data, since every
  // unit of a given type shares the same def. An unrecognized or absent
  // UnitType falls back to DefaultUnitDef (see GetUnitDef), which
  // preserves the pre-this-change behavior (any speed, can found, can
  // collect) so existing spawned units and old event logs keep working
  // unchanged.
  TUnitDef = record
    TypeID: string;
    DisplayName: string;
    SpeedMultiplier: Double;
    CanFoundCity: Boolean;
    CanCollect: Boolean;
    CollectMultiplier: Double;
    MaxHP: Integer;
    // 0 = this type cannot initiate an attack at all (the common case -
    // settlers/workers/scouts are non-combatants). Any unit, combat-
    // capable or not, can still be damaged/killed BY an attack; Attack
    // only gates who can throw the first punch.
    Attack: Integer;
  end;

// StdErr is buffered by default and only auto-flushes on a clean, natural
// exit - a forceful kill (VDRX's normal way of stopping this process)
// loses anything not explicitly flushed. Confirmed by direct test: an
// unflushed WriteLn(StdErr,...) followed by a kill produces literally
// zero output, even though the line executed. Route all startup/
// diagnostic messages through this instead of raw WriteLn(StdErr,...).
procedure LogDiag(const AMsg: string);
begin
  WriteLn(StdErr, AMsg);
  Flush(StdErr);
end;

var
  OutputLock: TCriticalSection;
  UnitsLock: TCriticalSection;
  NodesLock: TCriticalSection;
  LedgerLock: TCriticalSection;
  CitiesLock: TCriticalSection;
  RoadsLock: TCriticalSection;
  DensityLock: TCriticalSection;
  EventLogLock: TCriticalSection;
  EventLogFile: TextFile;
  Units: specialize TDictionary<string, TUnit>;
  Nodes: specialize TDictionary<string, TResourceNode>;
  Ledger: specialize TDictionary<string, Integer>; // key: "<owner>|<resource_type>" -> total collected
  Cities: specialize TDictionary<string, TCity>;
  Roads: specialize TDictionary<string, TRoad>;
  Density: specialize TDictionary<string, TDensityCell>; // key: "<gx>,<gy>" - sparse, untouched cells are simply absent
  UnitDefs: specialize TDictionary<string, TUnitDef>; // key: TypeID - static registry, loaded once at startup
  // unit_id -> node_id, the AI's memory of which node each of its
  // workers is currently headed for/working. Touched ONLY from RunAI,
  // which itself only ever runs on the single main tick-loop thread -
  // unlike every other shared dictionary in this file, it genuinely
  // never needs a lock.
  AiUnitTargets: specialize TDictionary<string, string>;
  Grid: TMovementGrid;
  Config: TBakeConfig;
  // Moved up from the final var block (originally declared right before
  // the main begin) - GrowCities/HandleFoundCity/RecomputeDevelopment all
  // need to read it, and those are defined well before that point.
  Tick: Int64;

procedure SendLine(const ALine: string);
begin
  OutputLock.Enter;
  try
    WriteLn(ALine);
    Flush(Output);
  finally
    OutputLock.Leave;
  end;
end;

// Persistence: append-only JSONL event log, same convention as VDRX's own
// TVDRX_BucketExecutive. Logs resolved OUTCOMES (a spawn's actual
// location, a move's actual computed path), not raw commands - replay
// never needs to re-run pathfinding, and never risks silently producing
// a DIFFERENT path than what actually happened if bake_config.json's
// move_cost values get edited between the original run and a later
// replay. Flushed after every write - durability over throughput, this
// isn't a hot path.
procedure LogEvent(const AJSON: string);
begin
  EventLogLock.Enter;
  try
    WriteLn(EventLogFile, AJSON);
    Flush(EventLogFile);
  finally
    EventLogLock.Leave;
  end;
end;

function GridToLon(GX: Double): Double;
begin
  Result := -180.0 + GX * (360.0 / Grid.Width);
end;

function GridToLat(GY: Double): Double;
begin
  Result := 90.0 - GY * (180.0 / Grid.Height);
end;

function LonToGridX(Lon: Double): Integer;
begin
  Result := Trunc((Lon - (-180.0)) / 360.0 * Grid.Width);
end;

function LatToGridY(Lat: Double): Integer;
begin
  Result := Trunc((90.0 - Lat) / 180.0 * Grid.Height);
end;

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

function DensityKey(GX, GY: Integer): string;
begin
  Result := IntToStr(GX) + ',' + IntToStr(GY);
end;

// The fallback used for any UnitType not found in UnitDefs - including
// the historical 'generic' type from before unit stats existed, and any
// typo/unrecognized value a client sends. Matches the pre-stats behavior
// exactly (normal speed, can found, can collect) so nothing that already
// worked stops working just because unit_types.json is missing or a
// spawn omits/misspells unit_type.
function DefaultUnitDef: TUnitDef;
begin
  Result.TypeID := 'generic';
  Result.DisplayName := 'Generic';
  Result.SpeedMultiplier := 1.0;
  Result.CanFoundCity := True;
  Result.CanCollect := True;
  Result.CollectMultiplier := 1.0;
  Result.MaxHP := 20;
  Result.Attack := 0; // non-combatant by default - matches pre-combat behavior exactly
end;

function GetUnitDef(const AUnitType: string): TUnitDef;
begin
  if not UnitDefs.TryGetValue(AUnitType, Result) then
    Result := DefaultUnitDef;
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
      UnitDefs.AddOrSetValue(Def.TypeID, Def);
    end;
    LogDiag('Loaded ' + IntToStr(UnitDefs.Count) + ' unit type definitions.');
  finally
    Data.Free;
  end;
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
      C.Population := Obj.Get('population', CityInitialPopulation);
      C.LastGrowthTick := 0;
      C.LastUpkeepTick := 0;
      Cities.AddOrSetValue(C.ID, C);
    end;
    LogDiag('Loaded ' + IntToStr(Arr.Count) + ' seed cities from cities.json (' + IntToStr(Cities.Count) + ' total before replay).');
  finally
    Data.Free;
  end;
end;

// Emits the full current node state in one message rather than one
// event per node - a freshly-connected viewer needs this exactly once
// on load, and a single message is simpler for it to handle than
// reassembling a burst. Live depletion after this point comes through
// the per-collection game.event.collected messages instead.
procedure HandleListNodes;
var
  Node: TResourceNode;
  ListJSON: string;
  First: Boolean;
begin
  ListJSON := '[';
  First := True;
  NodesLock.Enter;
  try
    for Node in Nodes.Values do
    begin
      if not First then ListJSON := ListJSON + ',';
      First := False;
      ListJSON := ListJSON + Format('{"id":"%s","resource_type":"%s","lon":%.4f,"lat":%.4f,"amount":%d}',
        [Node.ID, Node.ResourceType, Node.Lon, Node.Lat, Node.Amount]);
    end;
  finally
    NodesLock.Leave;
  end;
  ListJSON := ListJSON + ']';

  // ListJSON has its own internal quotes (ids, resource_type strings) -
  // unlike BuildPathJSON's plain numeric arrays, this needs actual
  // escaping before it can be embedded in the outer payload string.
  SendLine('{"topic":"game.event.node_list","payload":"{\"nodes\":' +
    StringReplace(ListJSON, '"', '\"', [rfReplaceAll]) + '}"}');
end;

// Raw JSON array text, e.g. [[20.08,15.09],[20.15,15.02],...] - no quotes
// anywhere in this, so it can be embedded directly into the escaped
// payload string below without needing further escaping itself (only
// the surrounding quoted fields like unit_id need the \" treatment).
function BuildPathJSON(const APath: TGridPath): string;
var
  i: Integer;
begin
  Result := '[';
  for i := 0 to High(APath) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + Format('[%.4f,%.4f]', [GridToLon(APath[i].X + 0.5), GridToLat(APath[i].Y + 0.5)]);
  end;
  Result := Result + ']';
end;

procedure HandleSpawn(APayload: TJSONObject);
var
  UnitID: string;
  U: TUnit;
  Lon, Lat: Double;
  GX, GY: Integer;
begin
  UnitID := APayload.Get('unit_id', '');
  if UnitID = '' then Exit;

  Lon := APayload.Get('lon', 0.0);
  Lat := APayload.Get('lat', 0.0);
  GX := LonToGridX(Lon);
  GY := LatToGridY(Lat);

  if (GX < 0) or (GX >= Grid.Width) or (GY < 0) or (GY >= Grid.Height) then
  begin
    SendLine(Format('{"topic":"game.event.spawn_failed","payload":"{\"unit_id\":\"%s\",\"reason\":\"out of bounds\"}"}', [UnitID]));
    Exit;
  end;

  if CellMoveCost(Grid, Config, GX, GY) <= 0 then
  begin
    SendLine(Format('{"topic":"game.event.spawn_failed","payload":"{\"unit_id\":\"%s\",\"reason\":\"impassable terrain\"}"}', [UnitID]));
    Exit;
  end;

  U.ID := UnitID;
  U.Owner := APayload.Get('owner', '');
  U.UnitType := APayload.Get('unit_type', 'generic');
  U.GX := GX + 0.5;
  U.GY := GY + 0.5;
  SetLength(U.Path, 0);
  U.PathIndex := 0;
  U.HP := GetUnitDef(U.UnitType).MaxHP;

  UnitsLock.Enter;
  try
    Units.AddOrSetValue(UnitID, U);
  finally
    UnitsLock.Leave;
  end;

  LogEvent(Format('{"type":"spawned","unit_id":"%s","owner":"%s","unit_type":"%s","lon":%.4f,"lat":%.4f,"hp":%d}',
    [UnitID, U.Owner, U.UnitType, GridToLon(U.GX), GridToLat(U.GY), U.HP]));
  SendLine(Format('{"topic":"game.event.spawned","payload":"{\"unit_id\":\"%s\",\"owner\":\"%s\",\"unit_type\":\"%s\",\"lon\":%.4f,\"lat\":%.4f,\"hp\":%d}"}',
    [UnitID, U.Owner, U.UnitType, GridToLon(U.GX), GridToLat(U.GY), U.HP]));
end;

// Removes a unit outright - no "death" event distinct from a deliberate
// despawn yet (no combat exists to produce one), so a single despawned
// event covers both for now. An unowned unit (Owner = '') can be
// despawned by anyone, same free-for-all rule as HandleMove - it's the
// only way an old pre-ownership or terminal-spawned unit stays
// manageable at all.
procedure HandleDespawn(APayload: TJSONObject);
var
  UnitID, Actor: string;
  U: TUnit;
  Found, Owned: Boolean;
begin
  UnitID := APayload.Get('unit_id', '');
  if UnitID = '' then Exit;
  Actor := APayload.Get('by', '');

  UnitsLock.Enter;
  try
    Found := Units.TryGetValue(UnitID, U);
    Owned := Found and ((U.Owner = '') or (U.Owner = Actor));
    if Owned then
      Units.Remove(UnitID);
  finally
    UnitsLock.Leave;
  end;

  if not Found then
  begin
    SendLine(Format('{"topic":"game.event.despawn_failed","payload":"{\"unit_id\":\"%s\",\"reason\":\"unknown unit\"}"}', [UnitID]));
    Exit;
  end;

  if not Owned then
  begin
    SendLine(Format('{"topic":"game.event.despawn_failed","payload":"{\"unit_id\":\"%s\",\"reason\":\"not your unit\"}"}', [UnitID]));
    Exit;
  end;

  LogEvent(Format('{"type":"despawned","unit_id":"%s"}', [UnitID]));
  SendLine(Format('{"topic":"game.event.despawned","payload":"{\"unit_id\":\"%s\"}"}', [UnitID]));
end;

procedure HandleMove(APayload: TJSONObject);
var
  UnitID, Actor: string;
  U: TUnit;
  ToLon, ToLat: Double;
  ToX, ToY, StartX, StartY: Integer;
  Path: TGridPath;
  Found: Boolean;
begin
  UnitID := APayload.Get('unit_id', '');
  Actor := APayload.Get('by', '');

  UnitsLock.Enter;
  try
    Found := Units.TryGetValue(UnitID, U);
  finally
    UnitsLock.Leave;
  end;

  if not Found then
  begin
    SendLine(Format('{"topic":"game.event.move_failed","payload":"{\"unit_id\":\"%s\",\"reason\":\"unknown unit\"}"}', [UnitID]));
    Exit;
  end;

  // Unowned units (Owner = '') stay free-for-all - keeps the bus
  // terminal's own raw quick-command buttons (which never send "by")
  // working unmodified against any unit spawned without an owner.
  if (U.Owner <> '') and (U.Owner <> Actor) then
  begin
    SendLine(Format('{"topic":"game.event.move_failed","payload":"{\"unit_id\":\"%s\",\"reason\":\"not your unit\"}"}', [UnitID]));
    Exit;
  end;

  ToLon := APayload.Get('to_lon', 0.0);
  ToLat := APayload.Get('to_lat', 0.0);
  ToX := LonToGridX(ToLon);
  ToY := LatToGridY(ToLat);
  StartX := Trunc(U.GX);
  StartY := Trunc(U.GY);

  Path := FindPath(Grid, Config, StartX, StartY, ToX, ToY);
  if Length(Path) = 0 then
  begin
    SendLine(Format('{"topic":"game.event.move_failed","payload":"{\"unit_id\":\"%s\",\"reason\":\"no path\"}"}', [UnitID]));
    Exit;
  end;

  U.Path := Path;
  U.PathIndex := 0;

  UnitsLock.Enter;
  try
    Units.AddOrSetValue(UnitID, U);
  finally
    UnitsLock.Leave;
  end;

  LogEvent('{"type":"path_found","unit_id":"' + UnitID + '","path":' + BuildPathJSON(Path) + '}');
  SendLine('{"topic":"game.event.path_found","payload":"{\"unit_id\":\"' + UnitID +
    '\",\"steps\":' + IntToStr(Length(Path)) + ',\"path\":' + BuildPathJSON(Path) + '}"}');
end;

// A flat, instant harvest - no travel time or animation on the resource
// side, the unit just needs to already be standing within range. Same
// ownership rule as HandleMove/HandleDespawn (unowned units free-for-
// all), applied to the COMMANDING unit, not the node - nodes have no
// owner of their own yet, they're a shared, contestable resource.
procedure HandleCollect(APayload: TJSONObject);
var
  UnitID, NodeID, Actor, Reason, LedgerKey: string;
  U: TUnit;
  Node: TResourceNode;
  UnitDef: TUnitDef;
  UnitFound, NodeFound: Boolean;
  Dist: Double;
  Taken, CurrentTotal: Integer;
begin
  UnitID := APayload.Get('unit_id', '');
  NodeID := APayload.Get('node_id', '');
  Actor := APayload.Get('by', '');
  Reason := '';
  Taken := 0;

  UnitsLock.Enter;
  try
    UnitFound := Units.TryGetValue(UnitID, U);
  finally
    UnitsLock.Leave;
  end;

  if not UnitFound then
    Reason := 'unknown unit'
  else if (U.Owner <> '') and (U.Owner <> Actor) then
    Reason := 'not your unit'
  else
  begin
    UnitDef := GetUnitDef(U.UnitType);
    if not UnitDef.CanCollect then
      Reason := 'unit type cannot collect';
  end;

  if Reason = '' then
  begin
    NodesLock.Enter;
    try
      NodeFound := Nodes.TryGetValue(NodeID, Node);
      if not NodeFound then
        Reason := 'unknown node'
      else
      begin
        Dist := Sqrt(Sqr(U.GX - Node.GX) + Sqr(U.GY - Node.GY));
        if Dist > CollectRadiusCells then
          Reason := 'too far'
        else if Node.Amount <= 0 then
          Reason := 'depleted'
        else
        begin
          // A better-suited unit type (e.g. a dedicated worker) takes
          // more per action via CollectMultiplier - the gate above
          // (CanCollect) decides WHO can collect at all, this decides
          // how much a type that can collect actually gets.
          Taken := Round(CollectAmountPerAction * UnitDef.CollectMultiplier);
          if Taken > Node.Amount then Taken := Node.Amount;
          Node.Amount := Node.Amount - Taken;
          Nodes.AddOrSetValue(NodeID, Node);
        end;
      end;
    finally
      NodesLock.Leave;
    end;
  end;

  if Reason <> '' then
  begin
    SendLine(Format('{"topic":"game.event.collect_failed","payload":"{\"unit_id\":\"%s\",\"node_id\":\"%s\",\"reason\":\"%s\"}"}',
      [UnitID, NodeID, Reason]));
    Exit;
  end;

  // Credited to the ACTOR who issued the command, not the collecting
  // unit's Owner - lets a shared/unowned unit's harvest still land in a
  // real faction's stash. An empty Actor (raw terminal testing, no
  // faction identity) still depletes the node normally but credits no
  // one - there's nobody to attribute it to.
  if Actor <> '' then
  begin
    LedgerLock.Enter;
    try
      LedgerKey := Actor + '|' + Node.ResourceType;
      CurrentTotal := 0;
      Ledger.TryGetValue(LedgerKey, CurrentTotal);
      Ledger.AddOrSetValue(LedgerKey, CurrentTotal + Taken);
    finally
      LedgerLock.Leave;
    end;
  end;

  LogEvent(Format('{"type":"collected","unit_id":"%s","node_id":"%s","by":"%s","amount":%d}', [UnitID, NodeID, Actor, Taken]));
  SendLine(Format('{"topic":"game.event.collected","payload":"{\"unit_id\":\"%s\",\"node_id\":\"%s\",\"resource_type\":\"%s\",\"by\":\"%s\",\"amount\":%d,\"remaining\":%d}"}',
    [UnitID, NodeID, Node.ResourceType, Actor, Taken, Node.Amount]));
end;

// Reports one faction's accumulated totals - deliberately scoped to the
// requester's own "by", not a scoreboard of everyone's stash. A shared
// leaderboard view is a reasonable future addition but a different
// trust question (broadcasting a query would need to enumerate every
// owner Ledger has ever seen) - not needed for a first pass.
procedure HandleGetLedger(APayload: TJSONObject);
var
  Actor, Prefix, KeyResource, TotalsJSON: string;
  First: Boolean;
  Pair: specialize TPair<string, Integer>;
begin
  Actor := APayload.Get('by', '');
  Prefix := Actor + '|';
  TotalsJSON := '{';
  First := True;

  LedgerLock.Enter;
  try
    for Pair in Ledger do
    begin
      if Copy(Pair.Key, 1, Length(Prefix)) = Prefix then
      begin
        KeyResource := Copy(Pair.Key, Length(Prefix) + 1, MaxInt);
        if not First then TotalsJSON := TotalsJSON + ',';
        First := False;
        TotalsJSON := TotalsJSON + Format('"%s":%d', [KeyResource, Pair.Value]);
      end;
    end;
  finally
    LedgerLock.Leave;
  end;
  TotalsJSON := TotalsJSON + '}';

  SendLine('{"topic":"game.event.ledger","payload":"{\"owner\":\"' + Actor + '\",\"totals\":' +
    StringReplace(TotalsJSON, '"', '\"', [rfReplaceAll]) + '}"}');
end;

// Founds a new city at the calling unit's current position, consuming
// that unit in the process - same "settler" idiom as classic 4X games,
// and the reason unit types matter now rather than being cosmetic
// labels: only a unit whose UnitDef has CanFoundCity=true can do this.
// lon/lat are no longer accepted from the caller - the location is
// always read from the unit's own position, so there's no way to found
// a city somewhere the founding unit isn't actually standing.
procedure HandleFoundCity(APayload: TJSONObject);
var
  CityID, UnitID, Owner, Actor, Reason: string;
  C: TCity;
  U: TUnit;
  UnitDef: TUnitDef;
  UnitFound: Boolean;
  GX, GY: Integer;
begin
  CityID := APayload.Get('city_id', '');
  UnitID := APayload.Get('unit_id', '');
  Actor := APayload.Get('by', '');
  if (CityID = '') or (UnitID = '') then Exit;

  UnitsLock.Enter;
  try
    UnitFound := Units.TryGetValue(UnitID, U);
  finally
    UnitsLock.Leave;
  end;

  Reason := '';
  if not UnitFound then
    Reason := 'unknown unit'
  else if (U.Owner <> '') and (U.Owner <> Actor) then
    Reason := 'not your unit'
  else if Length(U.Path) > 0 then
    Reason := 'unit is still moving'
  else
  begin
    UnitDef := GetUnitDef(U.UnitType);
    if not UnitDef.CanFoundCity then
      Reason := 'unit type cannot found cities';
  end;

  if Reason = '' then
  begin
    // U.GX/U.GY are cell-center coordinates (integer cell + 0.5, see
    // HandleSpawn/AdvanceUnits), so Trunc recovers the cell exactly for
    // an idle unit rather than rounding to a neighboring cell.
    GX := Trunc(U.GX);
    GY := Trunc(U.GY);
    if (GX < 0) or (GX >= Grid.Width) or (GY < 0) or (GY >= Grid.Height) then
      Reason := 'out of bounds'
    else if CellMoveCost(Grid, Config, GX, GY) <= 0 then
      Reason := 'impassable terrain';
  end;

  if Reason <> '' then
  begin
    SendLine(Format('{"topic":"game.event.city_failed","payload":"{\"city_id\":\"%s\",\"unit_id\":\"%s\",\"reason\":\"%s\"}"}',
      [CityID, UnitID, Reason]));
    Exit;
  end;

  // The founding unit is consumed - same despawn path (and the same
  // logged/broadcast event shape) HandleDespawn uses, so replay and any
  // connected viewer see one consistent "unit gone" event regardless of
  // which command caused it.
  UnitsLock.Enter;
  try
    Units.Remove(UnitID);
  finally
    UnitsLock.Leave;
  end;
  LogEvent(Format('{"type":"despawned","unit_id":"%s"}', [UnitID]));
  SendLine(Format('{"topic":"game.event.despawned","payload":"{\"unit_id\":\"%s\"}"}', [UnitID]));

  Owner := U.Owner;
  C.ID := CityID;
  C.Owner := Owner;
  C.GX := GX;
  C.GY := GY;
  C.Population := CityInitialPopulation;
  C.LastGrowthTick := Tick;
  C.LastUpkeepTick := Tick;

  CitiesLock.Enter;
  try
    Cities.AddOrSetValue(CityID, C);
  finally
    CitiesLock.Leave;
  end;

  LogEvent(Format('{"type":"city_founded","city_id":"%s","owner":"%s","lon":%.4f,"lat":%.4f,"population":%d}',
    [CityID, Owner, GridToLon(GX + 0.5), GridToLat(GY + 0.5), C.Population]));
  SendLine(Format('{"topic":"game.event.city_founded","payload":"{\"city_id\":\"%s\",\"owner\":\"%s\",\"lon\":%.4f,\"lat\":%.4f,\"population\":%d}"}',
    [CityID, Owner, GridToLon(GX + 0.5), GridToLat(GY + 0.5), C.Population]));
end;

// Grows every city's population by a fixed step once every
// CityGrowthTicks ticks - simple time-based growth for a first pass,
// same tuning-constant spirit as BaseSpeed. An OWNED city's growth now
// also costs CityGrowthWoodCost/CityGrowthStoneCost out of its owner's
// ledger - ties resource collection back into this loop instead of
// population climbing for free forever. An unowned (neutral/seed) city
// has nobody to charge and keeps growing on the timer alone. Called
// once per tick from the main loop; the per-city interval check keeps
// it a no-op for idle cities rather than a busy poll.
procedure GrowCities;
var
  Keys: array of string;
  i: Integer;
  C: TCity;
  Pair: specialize TPair<string, TCity>;
  KeyIdx: Integer;
  WoodKey, StoneKey: string;
  WoodTotal, StoneTotal: Integer;
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

    if (C.Population >= CityMaxPopulation) or (Tick - C.LastGrowthTick < CityGrowthTicks) then
      Continue;

    CanAfford := True;
    WoodTotal := 0;
    StoneTotal := 0;
    if C.Owner <> '' then
    begin
      WoodKey := C.Owner + '|wood';
      StoneKey := C.Owner + '|stone';
      LedgerLock.Enter;
      try
        Ledger.TryGetValue(WoodKey, WoodTotal);
        Ledger.TryGetValue(StoneKey, StoneTotal);
        CanAfford := (WoodTotal >= CityGrowthWoodCost) and (StoneTotal >= CityGrowthStoneCost);
        if CanAfford then
        begin
          Ledger.AddOrSetValue(WoodKey, WoodTotal - CityGrowthWoodCost);
          Ledger.AddOrSetValue(StoneKey, StoneTotal - CityGrowthStoneCost);
        end;
      finally
        LedgerLock.Leave;
      end;
    end;

    // Not affordable yet - LastGrowthTick is left untouched so this city
    // is simply re-checked next tick rather than waiting a full
    // CityGrowthTicks interval once resources finally show up.
    if not CanAfford then Continue;

    C.Population := C.Population + CityGrowthAmount;
    if C.Population > CityMaxPopulation then C.Population := CityMaxPopulation;
    C.LastGrowthTick := Tick;

    CitiesLock.Enter;
    try
      Cities.AddOrSetValue(Keys[i], C);
    finally
      CitiesLock.Leave;
    end;

    if C.Owner <> '' then
    begin
      LogEvent(Format('{"type":"city_growth_spent","city_id":"%s","owner":"%s","wood":%d,"stone":%d}',
        [Keys[i], C.Owner, CityGrowthWoodCost, CityGrowthStoneCost]));
      SendLine(Format('{"topic":"game.event.city_growth_spent","payload":"{\"city_id\":\"%s\",\"owner\":\"%s\",\"wood\":%d,\"stone\":%d}"}',
        [Keys[i], C.Owner, CityGrowthWoodCost, CityGrowthStoneCost]));
    end;

    LogEvent(Format('{"type":"city_grew","city_id":"%s","population":%d}', [Keys[i], C.Population]));
    SendLine(Format('{"topic":"game.event.city_grew","payload":"{\"city_id\":\"%s\",\"population\":%d}"}', [Keys[i], C.Population]));
  end;
end;

// True if ACityID has a road to any OTHER city owned by AOwner. Roads
// are snapshotted under RoadsLock and released before touching
// CitiesLock for each endpoint lookup, rather than holding both locks
// at once - HandleBuildRoad already acquires CitiesLock then RoadsLock
// (to validate both cities before adding the road), so locking them in
// the opposite order here would risk a deadlock between the two.
function IsCityRoadConnected(const ACityID, AOwner: string): Boolean;
var
  RoadSnapshot: array of TRoad;
  Pair: specialize TPair<string, TRoad>;
  i, Idx: Integer;
  OtherCityID: string;
  OtherCity: TCity;
begin
  Result := False;

  RoadsLock.Enter;
  try
    SetLength(RoadSnapshot, Roads.Count);
    Idx := 0;
    for Pair in Roads do
    begin
      RoadSnapshot[Idx] := Pair.Value;
      Inc(Idx);
    end;
  finally
    RoadsLock.Leave;
  end;

  for i := 0 to High(RoadSnapshot) do
  begin
    OtherCityID := '';
    if RoadSnapshot[i].FromCityID = ACityID then
      OtherCityID := RoadSnapshot[i].ToCityID
    else if RoadSnapshot[i].ToCityID = ACityID then
      OtherCityID := RoadSnapshot[i].FromCityID;
    if OtherCityID = '' then Continue;

    CitiesLock.Enter;
    try
      if Cities.TryGetValue(OtherCityID, OtherCity) and (OtherCity.Owner = AOwner) then
        Result := True;
    finally
      CitiesLock.Leave;
    end;

    if Result then Break;
  end;
end;

// Runs on its own clock (LastUpkeepTick), independent of growth - see
// the CityUpkeepTicks comment for why sharing the growth clock would
// misbehave. A road-connected city's upkeep is free (infrastructure
// sustains it); an isolated owned city must pay CityUpkeepCost wood
// out of its owner's ledger or its population decays. Population
// hitting zero abandons the city entirely - it's removed from Cities,
// not just left at zero, since a city with zero population isn't
// meaningfully a city anymore and leaving it around would keep
// RecomputeDevelopment radiating development from a ghost.
procedure ProcessCityUpkeep;
var
  Keys: array of string;
  i: Integer;
  C: TCity;
  Pair: specialize TPair<string, TCity>;
  KeyIdx: Integer;
  WoodKey: string;
  WoodTotal: Integer;
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
    if (C.Owner = '') or (Tick - C.LastUpkeepTick < CityUpkeepTicks) then
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

    WoodKey := C.Owner + '|wood';
    WoodTotal := 0;
    LedgerLock.Enter;
    try
      Ledger.TryGetValue(WoodKey, WoodTotal);
      Paid := WoodTotal >= CityUpkeepCost;
      if Paid then
        Ledger.AddOrSetValue(WoodKey, WoodTotal - CityUpkeepCost);
    finally
      LedgerLock.Leave;
    end;

    C.LastUpkeepTick := Tick;

    if Paid then
    begin
      CitiesLock.Enter;
      try
        Cities.AddOrSetValue(Keys[i], C);
      finally
        CitiesLock.Leave;
      end;
      LogEvent(Format('{"type":"city_upkeep_spent","city_id":"%s","owner":"%s","wood":%d}', [Keys[i], C.Owner, CityUpkeepCost]));
      SendLine(Format('{"topic":"game.event.city_upkeep_spent","payload":"{\"city_id\":\"%s\",\"owner\":\"%s\",\"wood\":%d}"}', [Keys[i], C.Owner, CityUpkeepCost]));
      Continue;
    end;

    // Couldn't pay - decay instead. An empty stockpile is the actual
    // signal here (CityUpkeepCost is deliberately cheap), so this
    // should be rare for an actively-collecting player.
    NewPop := C.Population - CityDecayAmount;

    if NewPop <= 0 then
    begin
      CitiesLock.Enter;
      try
        Cities.Remove(Keys[i]);
      finally
        CitiesLock.Leave;
      end;
      LogEvent(Format('{"type":"city_abandoned","city_id":"%s","previous_owner":"%s"}', [Keys[i], C.Owner]));
      SendLine(Format('{"topic":"game.event.city_abandoned","payload":"{\"city_id\":\"%s\",\"previous_owner\":\"%s\"}"}', [Keys[i], C.Owner]));
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
      LogEvent(Format('{"type":"city_population_decayed","city_id":"%s","population":%d}', [Keys[i], NewPop]));
      SendLine(Format('{"topic":"game.event.city_population_decayed","payload":"{\"city_id\":\"%s\",\"population\":%d}"}', [Keys[i], NewPop]));
    end;
  end;
end;

// Drives the AI faction's economy: keep it topped up on workers, keep
// those workers headed toward (and collecting from) whatever resource
// node is nearest, and reassign once a node runs dry. Growth and
// upkeep for the AI's city are NOT handled here - GrowCities and
// ProcessCityUpkeep already treat every owned city identically
// regardless of who owns it, so the AI's city grows/decays through
// exactly the same code path a human-owned one does, funded by
// whatever this procedure's workers bring in.
//
// Every action here is issued by constructing the same JSON payload a
// real client would send and calling the existing Handle* procedure
// with it - not a parallel "AI does this differently" code path. That
// means the AI is bound by the exact same ownership/range/terrain
// rules as anyone else, and any future rule change to spawning, moving,
// or collecting automatically applies to the AI too.
procedure RunAI;
var
  AiCity: TCity;
  HasAiCity: Boolean;
  CityPair: specialize TPair<string, TCity>;
  WorkerCount: Integer;
  UnitKeys: array of string;
  UnitPair: specialize TPair<string, TUnit>;
  i, KeyIdx: Integer;
  U: TUnit;
  AssignedNodeID, NewUnitID: string;
  Node: TResourceNode;
  NodeFound: Boolean;
  BestNodeID: string;
  BestDist, Dist: Double;
  NodePair: specialize TPair<string, TResourceNode>;
  PayloadStr: string;
  PayloadData: TJSONData;
  TargetLon, TargetLat: Double;
begin
  HasAiCity := False;
  CitiesLock.Enter;
  try
    for CityPair in Cities do
      if CityPair.Value.Owner = AiFactionName then
      begin
        AiCity := CityPair.Value;
        HasAiCity := True;
        Break;
      end;
  finally
    CitiesLock.Leave;
  end;
  if not HasAiCity then Exit; // no seeded AI city (see cities.json) - nothing to run yet

  WorkerCount := 0;
  UnitsLock.Enter;
  try
    SetLength(UnitKeys, Units.Count);
    KeyIdx := 0;
    for UnitPair in Units do
    begin
      if (UnitPair.Value.Owner = AiFactionName) and (UnitPair.Value.UnitType = 'worker') then
        Inc(WorkerCount);
      UnitKeys[KeyIdx] := UnitPair.Key;
      Inc(KeyIdx);
    end;
  finally
    UnitsLock.Leave;
  end;

  if (Tick mod AiTickInterval = 0) and (WorkerCount < AiTargetWorkerCount) then
  begin
    NewUnitID := 'ai_w_' + IntToStr(Tick) + '_' + IntToStr(WorkerCount);
    PayloadStr := Format('{"unit_id":"%s","lon":%.4f,"lat":%.4f,"owner":"%s","unit_type":"worker"}',
      [NewUnitID, GridToLon(AiCity.GX + 0.5), GridToLat(AiCity.GY + 0.5), AiFactionName]);
    PayloadData := GetJSON(PayloadStr);
    try
      HandleSpawn(TJSONObject(PayloadData));
    finally
      PayloadData.Free;
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

    if (U.Owner <> AiFactionName) or (U.UnitType <> 'worker') then Continue;

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
          Dist := Sqrt(Sqr(U.GX - NodePair.Value.GX) + Sqr(U.GY - NodePair.Value.GY));
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

    Dist := Sqrt(Sqr(U.GX - Node.GX) + Sqr(U.GY - Node.GY));

    if Dist <= CollectRadiusCells then
    begin
      PayloadStr := Format('{"unit_id":"%s","node_id":"%s","by":"%s"}', [UnitKeys[i], AssignedNodeID, AiFactionName]);
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
      PayloadStr := Format('{"unit_id":"%s","to_lon":%.4f,"to_lat":%.4f,"by":"%s"}',
        [UnitKeys[i], TargetLon, TargetLat, AiFactionName]);
      PayloadData := GetJSON(PayloadStr);
      try
        HandleMove(TJSONObject(PayloadData));
      finally
        PayloadData.Free;
      end;
    end;
  end;
end;

// Builds a road between two existing cities, reusing the same A*
// pathfinding as HandleMove with the cities' cells as start/end. The
// path is cached on the TRoad so RecomputeDevelopment doesn't need to
// re-run pathfinding on every density update.
procedure HandleBuildRoad(APayload: TJSONObject);
var
  RoadID, FromCityID, ToCityID, Actor: string;
  FromCity, ToCity: TCity;
  Found1, Found2: Boolean;
  Path: TGridPath;
  R: TRoad;
begin
  RoadID := APayload.Get('road_id', '');
  FromCityID := APayload.Get('from_city_id', '');
  ToCityID := APayload.Get('to_city_id', '');
  Actor := APayload.Get('by', '');
  if (RoadID = '') or (FromCityID = '') or (ToCityID = '') then Exit;

  CitiesLock.Enter;
  try
    Found1 := Cities.TryGetValue(FromCityID, FromCity);
    Found2 := Cities.TryGetValue(ToCityID, ToCity);
  finally
    CitiesLock.Leave;
  end;

  if (not Found1) or (not Found2) then
  begin
    SendLine(Format('{"topic":"game.event.road_failed","payload":"{\"road_id\":\"%s\",\"reason\":\"unknown city\"}"}', [RoadID]));
    Exit;
  end;

  // Same free-for-all spirit as HandleMove, tuned for a two-endpoint
  // action: requiring ownership of BOTH cities would block the ordinary
  // case of linking your own city to a neutral (unowned) one, so this
  // only blocks connecting two cities that are EACH owned by someone
  // else.
  if ((FromCity.Owner <> '') and (FromCity.Owner <> Actor)) and
     ((ToCity.Owner <> '') and (ToCity.Owner <> Actor)) then
  begin
    SendLine(Format('{"topic":"game.event.road_failed","payload":"{\"road_id\":\"%s\",\"reason\":\"not your city\"}"}', [RoadID]));
    Exit;
  end;

  Path := FindPath(Grid, Config, FromCity.GX, FromCity.GY, ToCity.GX, ToCity.GY);
  if Length(Path) = 0 then
  begin
    SendLine(Format('{"topic":"game.event.road_failed","payload":"{\"road_id\":\"%s\",\"reason\":\"no path\"}"}', [RoadID]));
    Exit;
  end;

  R.ID := RoadID;
  R.FromCityID := FromCityID;
  R.ToCityID := ToCityID;
  R.Owner := Actor;
  R.Path := Path;

  RoadsLock.Enter;
  try
    Roads.AddOrSetValue(RoadID, R);
  finally
    RoadsLock.Leave;
  end;

  LogEvent('{"type":"road_built","road_id":"' + RoadID + '","from_city_id":"' + FromCityID +
    '","to_city_id":"' + ToCityID + '","owner":"' + Actor + '","path":' + BuildPathJSON(Path) + '}');
  SendLine('{"topic":"game.event.road_built","payload":"{\"road_id\":\"' + RoadID +
    '\",\"from_city_id\":\"' + FromCityID + '\",\"to_city_id\":\"' + ToCityID +
    '\",\"steps\":' + IntToStr(Length(Path)) + ',\"path\":' + BuildPathJSON(Path) + '}"}');
end;

// Same "one message, full current state" pattern as HandleListNodes.
procedure HandleListCities;
var
  C: TCity;
  ListJSON: string;
  First: Boolean;
begin
  ListJSON := '[';
  First := True;
  CitiesLock.Enter;
  try
    for C in Cities.Values do
    begin
      if not First then ListJSON := ListJSON + ',';
      First := False;
      ListJSON := ListJSON + Format('{"id":"%s","owner":"%s","lon":%.4f,"lat":%.4f,"population":%d}',
        [C.ID, C.Owner, GridToLon(C.GX + 0.5), GridToLat(C.GY + 0.5), C.Population]);
    end;
  finally
    CitiesLock.Leave;
  end;
  ListJSON := ListJSON + ']';
  SendLine('{"topic":"game.event.city_list","payload":"{\"cities\":' +
    StringReplace(ListJSON, '"', '\"', [rfReplaceAll]) + '}"}');
end;

procedure HandleListRoads;
var
  R: TRoad;
  ListJSON: string;
  First: Boolean;
begin
  ListJSON := '[';
  First := True;
  RoadsLock.Enter;
  try
    for R in Roads.Values do
    begin
      if not First then ListJSON := ListJSON + ',';
      First := False;
      ListJSON := ListJSON + Format('{"id":"%s","from_city_id":"%s","to_city_id":"%s","owner":"%s","path":%s}',
        [R.ID, R.FromCityID, R.ToCityID, R.Owner, BuildPathJSON(R.Path)]);
    end;
  finally
    RoadsLock.Leave;
  end;
  ListJSON := ListJSON + ']';
  SendLine('{"topic":"game.event.road_list","payload":"{\"roads\":' +
    StringReplace(ListJSON, '"', '\"', [rfReplaceAll]) + '}"}');
end;

// Recomputes the whole density field from Cities+Roads every
// DevelopmentUpdateTicks ticks. A full recompute (not incremental
// deltas) is cheap at this map's scale and can never drift from what
// actually exists. Density itself is NEVER logged to events.jsonl -
// it's a deterministic function of city population + road paths at any
// given tick, so replay only needs city_founded/city_grew/road_built to
// reconstruct it, same principle as the ledger being rebuildable from
// collected events alone.
procedure RecomputeDevelopment(ABroadcast: Boolean = True);
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
begin
  Contrib := specialize TDictionary<string, TDensityCell>.Create;
  try
    CitiesLock.Enter;
    try
      for C in Cities.Values do
      begin
        radius := Min(DevelopmentRadiusCells, Round(3 + DevelopmentRadiusCells * (C.Population / CityMaxPopulation)));
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
            val := falloff * falloff * (C.Population / CityMaxPopulation) * 255.0;
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

    RoadsLock.Enter;
    try
      for R in Roads.Values do
        for i := 0 to High(R.Path) do
          for gy := R.Path[i].Y - RoadDevelopmentRadiusCells to R.Path[i].Y + RoadDevelopmentRadiusCells do
            for gx := R.Path[i].X - RoadDevelopmentRadiusCells to R.Path[i].X + RoadDevelopmentRadiusCells do
            begin
              if (gx < 0) or (gx >= Grid.Width) or (gy < 0) or (gy >= Grid.Height) then Continue;
              dx := gx - R.Path[i].X; dy := gy - R.Path[i].Y;
              dist := Sqrt(dx * dx + dy * dy);
              if dist > RoadDevelopmentRadiusCells then Continue;
              falloff := 1.0 - (dist / RoadDevelopmentRadiusCells);
              val := falloff * 60.0; // a modest fixed contribution, well below a mature city's peak
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
        if Abs(Integer(Cell.Level) - Integer(OldCell.Level)) >= DevelopmentBroadcastThreshold then
        begin
          if not First then DeltaJSON := DeltaJSON + ',';
          First := False;
          DeltaJSON := DeltaJSON + Format('{"gx":%d,"gy":%d,"d":%d}', [Cell.GX, Cell.GY, Cell.Level]);
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
      SendLine('{"topic":"game.event.development_delta","payload":"{\"cells\":' +
        StringReplace(DeltaJSON, '"', '\"', [rfReplaceAll]) + '}"}');
    end;
  finally
    Contrib.Free;
  end;
end;

// Full snapshot for a freshly-connected viewer - same role as
// HandleListNodes relative to the per-collection events.
procedure HandleGetDevelopment;
var
  Pair: specialize TPair<string, TDensityCell>;
  ListJSON: string;
  First: Boolean;
begin
  ListJSON := '[';
  First := True;
  DensityLock.Enter;
  try
    for Pair in Density do
    begin
      if not First then ListJSON := ListJSON + ',';
      First := False;
      ListJSON := ListJSON + Format('{"gx":%d,"gy":%d,"d":%d}', [Pair.Value.GX, Pair.Value.GY, Pair.Value.Level]);
    end;
  finally
    DensityLock.Leave;
  end;
  ListJSON := ListJSON + ']';
  SendLine('{"topic":"game.event.development_snapshot","payload":"{\"cells\":' +
    StringReplace(ListJSON, '"', '\"', [rfReplaceAll]) + '}"}');
end;

// Handles both unit-vs-unit and unit-vs-city combat, distinguished by
// which of target_unit_id/target_city_id the payload sets. A city's
// Population doubles as its defense pool (see SiegeDamagePerAttack's
// comment) - hitting a city just decrements it the same way an
// attacker's damage decrements a unit's HP, and capture is simply what
// happens when that pool bottoms out, mirroring death for units.
procedure HandleAttack(APayload: TJSONObject);
var
  AttackerID, TargetUnitID, TargetCityID, Actor, Reason, PrevOwner: string;
  Attacker, TargetUnit: TUnit;
  AttackerDef: TUnitDef;
  AttackerFound, TargetUnitFound, TargetCityFound: Boolean;
  TargetCity: TCity;
  Dist: Double;
  Damage, NewHP, NewPop: Integer;
begin
  AttackerID := APayload.Get('attacker_unit_id', '');
  TargetUnitID := APayload.Get('target_unit_id', '');
  TargetCityID := APayload.Get('target_city_id', '');
  Actor := APayload.Get('by', '');
  Reason := '';

  if (AttackerID = '') or ((TargetUnitID = '') and (TargetCityID = '')) then Exit;

  UnitsLock.Enter;
  try
    AttackerFound := Units.TryGetValue(AttackerID, Attacker);
  finally
    UnitsLock.Leave;
  end;

  if not AttackerFound then
    Reason := 'unknown attacker'
  else if (Attacker.Owner <> '') and (Attacker.Owner <> Actor) then
    Reason := 'not your unit'
  else if Attacker.Owner = '' then
    Reason := 'unowned units cannot attack' // nobody to credit the conquest to
  else
  begin
    AttackerDef := GetUnitDef(Attacker.UnitType);
    if AttackerDef.Attack <= 0 then
      Reason := 'unit type cannot fight';
  end;

  if (Reason = '') and (TargetUnitID <> '') then
  begin
    UnitsLock.Enter;
    try
      TargetUnitFound := Units.TryGetValue(TargetUnitID, TargetUnit);
    finally
      UnitsLock.Leave;
    end;

    if not TargetUnitFound then
      Reason := 'unknown target'
    else if TargetUnit.Owner = Attacker.Owner then
      Reason := 'cannot attack your own faction'
    else
    begin
      Dist := Sqrt(Sqr(Attacker.GX - TargetUnit.GX) + Sqr(Attacker.GY - TargetUnit.GY));
      if Dist > AttackRangeCells then
        Reason := 'too far';
    end;

    if Reason = '' then
    begin
      Damage := AttackerDef.Attack;
      NewHP := TargetUnit.HP - Damage;
      if NewHP < 0 then NewHP := 0;

      LogEvent(Format('{"type":"unit_attacked","attacker_unit_id":"%s","target_unit_id":"%s","by":"%s","damage":%d,"remaining_hp":%d}',
        [AttackerID, TargetUnitID, Actor, Damage, NewHP]));
      SendLine(Format('{"topic":"game.event.unit_attacked","payload":"{\"attacker_unit_id\":\"%s\",\"target_unit_id\":\"%s\",\"by\":\"%s\",\"damage\":%d,\"remaining_hp\":%d}"}',
        [AttackerID, TargetUnitID, Actor, Damage, NewHP]));

      if NewHP <= 0 then
      begin
        UnitsLock.Enter;
        try
          Units.Remove(TargetUnitID);
        finally
          UnitsLock.Leave;
        end;
        // Same event shape a normal despawn produces - the client and
        // replay both already know how to remove a unit this way, so
        // death-by-combat doesn't need its own removal handling.
        LogEvent(Format('{"type":"despawned","unit_id":"%s"}', [TargetUnitID]));
        SendLine(Format('{"topic":"game.event.despawned","payload":"{\"unit_id\":\"%s\"}"}', [TargetUnitID]));
      end
      else
      begin
        TargetUnit.HP := NewHP;
        UnitsLock.Enter;
        try
          Units.AddOrSetValue(TargetUnitID, TargetUnit);
        finally
          UnitsLock.Leave;
        end;
      end;
      Exit;
    end;
  end
  else if (Reason = '') and (TargetCityID <> '') then
  begin
    CitiesLock.Enter;
    try
      TargetCityFound := Cities.TryGetValue(TargetCityID, TargetCity);
    finally
      CitiesLock.Leave;
    end;

    if not TargetCityFound then
      Reason := 'unknown city'
    else if TargetCity.Owner = Attacker.Owner then
      Reason := 'already yours'
    else
    begin
      Dist := Sqrt(Sqr(Attacker.GX - TargetCity.GX) + Sqr(Attacker.GY - TargetCity.GY));
      if Dist > AttackRangeCells then
        Reason := 'too far';
    end;

    if Reason = '' then
    begin
      NewPop := TargetCity.Population - SiegeDamagePerAttack;

      if NewPop <= 0 then
      begin
        PrevOwner := TargetCity.Owner;
        TargetCity.Owner := Attacker.Owner;
        TargetCity.Population := CityCaptureResetPopulation;
        TargetCity.LastGrowthTick := Tick;
        TargetCity.LastUpkeepTick := Tick; // fresh upkeep clock too - no back-charged upkeep from being conquered

        CitiesLock.Enter;
        try
          Cities.AddOrSetValue(TargetCityID, TargetCity);
        finally
          CitiesLock.Leave;
        end;

        LogEvent(Format('{"type":"city_captured","city_id":"%s","previous_owner":"%s","new_owner":"%s","population":%d}',
          [TargetCityID, PrevOwner, TargetCity.Owner, TargetCity.Population]));
        SendLine(Format('{"topic":"game.event.city_captured","payload":"{\"city_id\":\"%s\",\"previous_owner\":\"%s\",\"new_owner\":\"%s\",\"population\":%d}"}',
          [TargetCityID, PrevOwner, TargetCity.Owner, TargetCity.Population]));
      end
      else
      begin
        TargetCity.Population := NewPop;
        CitiesLock.Enter;
        try
          Cities.AddOrSetValue(TargetCityID, TargetCity);
        finally
          CitiesLock.Leave;
        end;

        LogEvent(Format('{"type":"city_attacked","city_id":"%s","attacker_unit_id":"%s","by":"%s","damage":%d,"population_remaining":%d}',
          [TargetCityID, AttackerID, Actor, SiegeDamagePerAttack, NewPop]));
        SendLine(Format('{"topic":"game.event.city_attacked","payload":"{\"city_id\":\"%s\",\"attacker_unit_id\":\"%s\",\"by\":\"%s\",\"damage\":%d,\"population_remaining\":%d}"}',
          [TargetCityID, AttackerID, Actor, SiegeDamagePerAttack, NewPop]));
      end;
      Exit;
    end;
  end;

  if Reason <> '' then
    SendLine(Format('{"topic":"game.event.attack_failed","payload":"{\"attacker_unit_id\":\"%s\",\"reason\":\"%s\"}"}', [AttackerID, Reason]));
end;

procedure DispatchIncoming(const ALine: string);
var
  Data: TJSONData;
  Obj: TJSONObject;
  Topic: string;
  PayloadData: TJSONData;
begin
  try
    Data := GetJSON(ALine);
  except
    Exit; // not valid JSON - ignore rather than crash the loop
  end;

  try
    if Data.JSONType <> jtObject then Exit;
    Obj := TJSONObject(Data);
    Topic := Obj.Get('topic', '');
    PayloadData := Obj.Find('payload');

    if Topic = 'game.cmd.ping' then
      SendLine('{"topic":"game.event.pong","payload":"{}"}')
    else if Topic = 'game.cmd.spawn' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleSpawn(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.despawn' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleDespawn(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.move' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleMove(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.collect' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleCollect(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.list_nodes' then
      HandleListNodes
    else if Topic = 'game.cmd.get_ledger' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleGetLedger(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.found_city' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleFoundCity(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.build_road' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleBuildRoad(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.list_cities' then
      HandleListCities
    else if Topic = 'game.cmd.list_roads' then
      HandleListRoads
    else if Topic = 'game.cmd.get_development' then
      HandleGetDevelopment
    else if Topic = 'game.cmd.attack' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleAttack(TJSONObject(PayloadData));
    end;
    // add more topic handlers here as the command set grows
  finally
    Data.Free;
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
    UnitsLock.Enter;
    try
      if not Units.TryGetValue(Keys[i], U) then Continue;
    finally
      UnitsLock.Leave;
    end;

    if (Length(U.Path) = 0) or (U.PathIndex >= High(U.Path)) then
      Continue; // idle - nothing to advance, nothing to broadcast

    TargetX := U.Path[U.PathIndex + 1].X;
    TargetY := U.Path[U.PathIndex + 1].Y;
    StepCost := CellMoveCost(Grid, Config, TargetX, TargetY);
    if StepCost <= 0 then StepCost := 1; // shouldn't happen, path was validated - stay safe rather than divide by zero
    MoveAmount := (BaseSpeed * GetUnitDef(U.UnitType).SpeedMultiplier) / StepCost;

    DX := (TargetX + 0.5) - U.GX;
    DY := (TargetY + 0.5) - U.GY;
    Dist := Sqrt(DX * DX + DY * DY);

    if Dist <= MoveAmount then
    begin
      U.GX := TargetX + 0.5;
      U.GY := TargetY + 0.5;
      Inc(U.PathIndex);
      LogEvent(Format('{"type":"waypoint","unit_id":"%s","path_index":%d}', [Keys[i], U.PathIndex]));

      if U.PathIndex >= High(U.Path) then
      begin
        SetLength(U.Path, 0); // arrived - unit goes idle, stops generating traffic
        LogEvent(Format('{"type":"arrived","unit_id":"%s"}', [Keys[i]]));
        SendLine(Format('{"topic":"game.event.arrived","payload":"{\"unit_id\":\"%s\"}"}', [Keys[i]]));
      end;
    end
    else
    begin
      U.GX := U.GX + (DX / Dist) * MoveAmount;
      U.GY := U.GY + (DY / Dist) * MoveAmount;
    end;

    UnitsLock.Enter;
    try
      Units.AddOrSetValue(Keys[i], U);
    finally
      UnitsLock.Leave;
    end;

    SendLine(Format('{"topic":"game.event.position","payload":"{\"unit_id\":\"%s\",\"lon\":%.4f,\"lat\":%.4f}"}',
      [Keys[i], GridToLon(U.GX), GridToLat(U.GY)]));
  end;
end;

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
  Line, EventType, UnitID, NodeID, ByActor, LedgerKey, CityID, RoadID, TargetUnitID: string;
  Data: TJSONData;
  Obj: TJSONObject;
  U: TUnit;
  Node: TResourceNode;
  C: TCity;
  R: TRoad;
  Lon, Lat: Double;
  PathArr, PointArr: TJSONArray;
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
          C.Population := Obj.Get('population', CityInitialPopulation);
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
          // relative to a server that kept running live.
          ByActor := Obj.Get('owner', '');
          if ByActor <> '' then
          begin
            LedgerLock.Enter;
            try
              LedgerKey := ByActor + '|wood';
              CurrentTotal := 0;
              Ledger.TryGetValue(LedgerKey, CurrentTotal);
              CurrentTotal := CurrentTotal - Obj.Get('wood', 0);
              if CurrentTotal < 0 then CurrentTotal := 0;
              Ledger.AddOrSetValue(LedgerKey, CurrentTotal);

              LedgerKey := ByActor + '|stone';
              CurrentTotal := 0;
              Ledger.TryGetValue(LedgerKey, CurrentTotal);
              CurrentTotal := CurrentTotal - Obj.Get('stone', 0);
              if CurrentTotal < 0 then CurrentTotal := 0;
              Ledger.AddOrSetValue(LedgerKey, CurrentTotal);
            finally
              LedgerLock.Leave;
            end;
          end;
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
          if ByActor <> '' then
          begin
            LedgerLock.Enter;
            try
              LedgerKey := ByActor + '|wood';
              CurrentTotal := 0;
              Ledger.TryGetValue(LedgerKey, CurrentTotal);
              CurrentTotal := CurrentTotal - Obj.Get('wood', 0);
              if CurrentTotal < 0 then CurrentTotal := 0;
              Ledger.AddOrSetValue(LedgerKey, CurrentTotal);
            finally
              LedgerLock.Leave;
            end;
          end;
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

type
  // Plain blocking ReadLn on its own thread - same idiom as VDRX's own
  // vdrx_stdin.pas. Deliberately not polling IsInputAvailable on the main
  // thread: that doesn't mix reliably with FPC's buffered Text I/O on the
  // same handle (PeekNamedPipe only sees the OS-level pipe buffer, not
  // bytes the runtime may already have pulled into its own internal
  // buffer), so input can silently go undetected.
  TStdinReaderThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TStdinReaderThread.Execute;
var
  Line: string;
begin
  while not Terminated do
  begin
    if Eof(Input) then Break; // stdin closed - bridge is gone, VDRX will restart us
    ReadLn(Line);
    if Line <> '' then
      DispatchIncoming(Line);
  end;
end;

var
  ReaderThread: TStdinReaderThread;
  EventLogPath: string;
  EventLogExisted: Boolean;

begin
  Tick := 0;
  OutputLock := TCriticalSection.Create;
  UnitsLock := TCriticalSection.Create;
  NodesLock := TCriticalSection.Create;
  LedgerLock := TCriticalSection.Create;
  CitiesLock := TCriticalSection.Create;
  RoadsLock := TCriticalSection.Create;
  DensityLock := TCriticalSection.Create;
  EventLogLock := TCriticalSection.Create;
  Units := specialize TDictionary<string, TUnit>.Create;
  Nodes := specialize TDictionary<string, TResourceNode>.Create;
  Ledger := specialize TDictionary<string, Integer>.Create;
  Cities := specialize TDictionary<string, TCity>.Create;
  Roads := specialize TDictionary<string, TRoad>.Create;
  Density := specialize TDictionary<string, TDensityCell>.Create;
  UnitDefs := specialize TDictionary<string, TUnitDef>.Create;
  AiUnitTargets := specialize TDictionary<string, string>.Create;

  LogDiag('Loading bake_config.json ...');
  Config := LoadBakeConfig(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'bake_config.json');

  LogDiag('Loading ' + Config.MovementGridPath + ' ...');
  Grid := LoadMovementGrid(Config.MovementGridPath);
  LogDiag('Movement grid: ' + IntToStr(Grid.Width) + ' x ' + IntToStr(Grid.Height));

  LogDiag('Loading unit_types.json ...');
  LoadUnitTypes(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'unit_types.json');

  LogDiag('Loading resource_nodes.json ...');
  LoadResourceNodes(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'resource_nodes.json');

  // cities.json MUST load before ReplayEventLog, not after. Every
  // per-city event (city_grew, city_growth_spent, city_attacked,
  // city_captured, city_upkeep_spent, city_population_decayed,
  // city_abandoned) looks its target up with Cities.TryGetValue and
  // silently no-ops if it isn't found yet - correct for a city that
  // was itself created by a city_founded event earlier in the same
  // log, but for a city that only ever originated from cities.json,
  // "found on replay" never happens at all. Loading the seed file
  // first (same order LoadResourceNodes already uses relative to
  // replay) means a seed city exists by the time replay reaches any
  // event that updates it, and the accumulated history correctly
  // lands on top of the seed values instead of being silently dropped
  // and then overwritten back to the original seed on next restart.
  LogDiag('Loading cities.json ...');
  LoadCities(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'cities.json');

  EventLogPath := ExpandFileName(ExtractFilePath(ParamStr(0))) + 'events.jsonl';
  LogDiag('Event log: ' + EventLogPath);
  EventLogExisted := FileExists(EventLogPath);
  ReplayEventLog(EventLogPath);

  // Build the initial density field now, before anyone can connect, so
  // the first viewer's game.cmd.get_development gets real data instead
  // of an empty snapshot while waiting for the first tick-loop
  // recompute. Not broadcast - nothing is subscribed yet.
  RecomputeDevelopment(False);

  // Open for appending only after the full replay read pass above - if
  // this were opened first and appended to while also being read, we'd
  // risk replaying partially-written data from this same run.
  AssignFile(EventLogFile, EventLogPath);
  if EventLogExisted then
    Append(EventLogFile)
  else
    Rewrite(EventLogFile);

  // Grid/Config/EventLogFile are all read-only or append-only from here
  // on, so it's safe to start the reader thread only now - no window
  // where it could race a concurrent load or an in-progress replay.
  ReaderThread := TStdinReaderThread.Create(False); // starts immediately

  while True do
  begin
    Inc(Tick);
    SendLine(Format('{"topic":"game.tick","payload":"{\"tick\":%d}"}', [Tick]));
    AdvanceUnits;
    GrowCities;
    ProcessCityUpkeep;
    RunAI;
    if Tick mod DevelopmentUpdateTicks = 0 then
      RecomputeDevelopment;
    Sleep(50); // ~20 ticks/sec target loop pacing
  end;
end.
