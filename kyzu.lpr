program kyzu;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, Math, SyncObjs, Generics.Collections, fpjson, jsonparser,
  kyzu_bakeconfig, kyzu_pathfinding;

// All former first-pass tuning constants (Balance.BaseSpeed, growth/upkeep
// costs, combat ranges, veterancy thresholds, etc.) now live in the
// Balance global (TGameBalance, loaded from game_balance.json) rather
// than as compile-time const values here - see the type's own comment
// for what stayed in code vs what moved to config.

type
  TUnit = record
    ID: string;
    Owner: string;      // faction/player id, '' = unowned
    UnitType: string;   // key into UnitDefs - see TUnitDef below
    GX, GY: Double; // fractional grid position, for smooth interpolated reporting
    Path: TGridPath;
    PathIndex: Integer; // index of the path node the unit is currently departing from
    HP: Integer;    // current hit points, initialized from UnitDefs[UnitType].MaxHP at spawn
    XP: Integer;     // combat experience - see Balance.VeterancyXPPerHit/Balance.VeterancyMaxLevel
    Level: Integer;  // 0 = green, up to Balance.VeterancyMaxLevel - boosts effective Attack/MaxHP
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
    // '' = spawnable by anyone regardless of research (matches every
    // pre-tech unit type exactly). Non-empty = the spawning faction must
    // have this TechID in ResearchedTech first - see HandleSpawn. Deliberately
    // NOT enforced for Owner = '' (unowned/free-for-all spawns): there is
    // no faction to have researched anything against, same free-for-all
    // carve-out HandleMove/HandleDespawn already give unowned units.
    RequiresTech: string;
  end;

  // One line of a resource cost - "5 wood", "2 stone". Growth and
  // upkeep costs are both just lists of these rather than fixed
  // wood/stone fields, so a NEW resource type (anything seeded in
  // resource_nodes.json) can be made part of either cost purely by
  // editing game_balance.json - no code change, no recompile.
  TResourceCost = record
    ResourceType: string;
    Amount: Integer;
  end;
  TResourceCostList = array of TResourceCost;

  // One entry in tech.json - a researchable upgrade, gated behind its own
  // prerequisite techs and a resource cost, that unlocks new unit types
  // once completed. Loaded once into TechDefs at startup, same tolerant
  // pattern as UnitDefs; TechOrder preserves load order separately since
  // TDictionary enumeration order isn't something to rely on for "walk
  // techs in a sensible order" (used by RunAI's research picker).
  TTechDef = record
    TechID: string;
    DisplayName: string;
    Prerequisites: array of string;
    Cost: TResourceCostList;
    ResearchTicks: Integer;
  end;

  // A faction's in-flight research - one at a time per faction (see
  // ResearchInProgress, keyed by owner). StartTick resets to 0 alongside
  // Tick on every restart - see ReplayEventLog's 'research_started'
  // branch for why that's the same precedent as city clocks.
  TResearchInProgress = record
    TechID: string;
    StartTick: Int64;
  end;

  // Every first-pass tuning number in the game, loaded once at startup
  // from game_balance.json (see LoadGameBalance) with defaults that
  // exactly match what used to be hardcoded const values - editing the
  // JSON and restarting the server is now how you rebalance the game,
  // not editing this source file. What's deliberately NOT in here: the
  // actual mechanics (why upkeep runs on its own clock, how damage is
  // computed, the density falloff shape) - those are relationships
  // between numbers, not the numbers themselves, and turning THOSE
  // into data would mean building a small rules/expression engine,
  // not a config file. This only externalizes the inputs to formulas
  // that stay in code.
  TGameBalance = record
    BaseSpeed: Double;
    CollectRadiusCells: Double;
    CollectAmountPerAction: Integer;

    CityInitialPopulation: Integer;
    CityGrowthAmount: Integer;
    CityGrowthTicks: Integer;
    CityMaxPopulation: Integer;
    CityGrowthCost: TResourceCostList;

    DevelopmentRadiusCells: Double;
    DevelopmentMinRadiusCells: Double;
    DevelopmentUpdateTicks: Integer;
    RoadDevelopmentRadiusCells: Integer; // used as a raw FOR-loop bound (see RecomputeDevelopment) - must stay a whole number of cells, unlike the other *Cells fields which are fractional distance thresholds
    RoadDevelopmentPeak: Double;
    DevelopmentBroadcastThreshold: Integer;

    AttackRangeCells: Double;
    SiegeDamagePerAttack: Integer;
    CityCaptureResetPopulation: Integer;

    CityUpkeepTicks: Integer;
    CityUpkeepCost: TResourceCostList;
    CityDecayAmount: Integer;

    AiFactionName: string;
    AiTickInterval: Integer;
    AiTargetWorkerCount: Integer;
    // Expansion: how many settlers the AI keeps in flight at once, and
    // where it's willing to found. AiExpansionSearchRadiusCells bounds
    // the search around each AI-owned city; AiExpansionMinCityDistanceCells
    // is the minimum distance a candidate site must keep from EVERY
    // existing city (any owner) so the AI doesn't found on top of
    // someone else's back yard.
    AiTargetSettlerCount: Integer;
    AiExpansionSearchRadiusCells: Double;
    AiExpansionMinCityDistanceCells: Double;
    // Military: how many soldiers the AI keeps up, and how far a soldier
    // will proactively range from its spawn city looking for a target
    // before giving up and heading home to garrison.
    AiTargetSoldierCount: Integer;
    AiAggressionRangeCells: Double;
    // Research: whether the AI ever starts research at all. Off by
    // default (False) in DefaultGameBalance so an existing deployment
    // with no ai_research_enabled key in game_balance.json sees no
    // behavior change until the operator opts in.
    AiResearchEnabled: Boolean;

    VeterancyXPPerHit: Integer;
    VeterancyXPPerLevel: Integer;
    VeterancyMaxLevel: Integer;
    VeterancyAttackBonusPerLevel: Integer;
    VeterancyHPBonusPerLevel: Integer;
  end;

  // One entry in ai_factions.json - a single AI-controlled faction's
  // identity plus its own copy of every knob RunAI reads. Letting each
  // faction carry its own numbers (rather than RunAI reaching for the
  // single shared Balance.Ai* fields directly) is what makes multiple
  // AI factions with different "personalities" possible - one entry
  // tuned aggressive (high soldier count, wide aggression range), one
  // tuned as a builder (more settlers/workers, research always on),
  // etc, all from JSON with no code change. See LoadAiFactionConfigs
  // for how a faction entry inherits from Balance.Ai* for any field it
  // doesn't specify.
  TAiFactionConfig = record
    FactionName: string;
    TickInterval: Integer;
    TargetWorkerCount: Integer;
    TargetSettlerCount: Integer;
    ExpansionSearchRadiusCells: Double;
    ExpansionMinCityDistanceCells: Double;
    TargetSoldierCount: Integer;
    AggressionRangeCells: Double;
    ResearchEnabled: Boolean;
    // This faction's position in AiFactionConfigs, used purely to
    // stagger which tick each faction's decision pass falls on
    // ((Tick + Offset) mod TickInterval = 0) so N AI factions sharing
    // the same TickInterval don't all recompute on the exact same
    // tick - see RunAllAI.
    Offset: Integer;
  end;

  // One AI-owned city's local "governor" state for the current RunAI
  // pass - computed fresh every call (never persisted, never locked -
  // same reasoning as AiUnitTargets: only ever touched from the single
  // main tick-loop thread). Exists so spawning/garrisoning can be
  // decided per-city rather than always favouring whichever city the
  // faction happened to found first - see RunAI's use of
  // ComputeAiRegions/NearestAiRegion.
  TAiRegion = record
    CityID: string;
    GX, GY: Integer;
    WorkerCount, SettlerCount, SoldierCount: Integer;
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
  Balance: TGameBalance; // every tunable number in the game - see LoadGameBalance
  // unit_id -> node_id, the AI's memory of which node each of its
  // workers is currently headed for/working. Touched ONLY from RunAI,
  // which itself only ever runs on the single main tick-loop thread -
  // unlike every other shared dictionary in this file, it genuinely
  // never needs a lock.
  AiUnitTargets: specialize TDictionary<string, string>;
  // Every AI-controlled faction currently running, loaded once at
  // startup from ai_factions.json (or synthesized as a single
  // Balance.AiFactionName entry if that file is absent - see
  // LoadAiFactionConfigs). RunAllAI iterates this once per tick.
  AiFactionConfigs: array of TAiFactionConfig;
  TechDefs: specialize TDictionary<string, TTechDef>; // key: TechID - static registry, loaded once at startup from tech.json
  TechOrder: TStringList; // TechIDs in tech.json's own array order - RunAI's research picker walks this rather than the dictionary's unspecified enumeration order
  ResearchedTech: specialize TDictionary<string, Boolean>; // key: "<owner>|<tech_id>" -> True once completed; absence = not researched
  ResearchInProgress: specialize TDictionary<string, TResearchInProgress>; // key: owner - one research at a time per faction
  TechLock: TCriticalSection;
  // Diplomatic status between two factions, keyed by DiplomacyKey (a
  // canonical, order-independent "<a>|<b>" - see its own comment).
  // Absence of a key means the default relationship: neutral. Only
  // 'war' and 'allied' are ever stored - there's no separate 'neutral'
  // value, so returning to neutral (accepted peace, broken alliance)
  // removes the key rather than writing 'neutral' into it.
  DiplomaticStatus: specialize TDictionary<string, string>;
  // In-memory only, deliberately never logged to events.jsonl or restored
  // on replay - an alliance/peace proposal that was sitting unanswered
  // when the server last stopped is just gone on restart, same as a
  // human negotiation that never got a reply. Key: "<proposer>|<target>|<kind>",
  // kind is 'alliance' or 'peace'.
  PendingProposals: specialize TDictionary<string, Boolean>;
  DiplomacyLock: TCriticalSection;
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

// Returns a JSON string literal, including surrounding double quotes.
// Non-ASCII UTF-8 is left intact (valid JSON permits UTF-8), while JSON
// metacharacters and control characters are escaped according to RFC 8259.
function JsonQuote(const S: string): string;
var
  i, C: Integer;
  Ch: Char;
begin
  Result := '"';
  for i := 1 to Length(S) do
  begin
    Ch := S[i];
    C := Ord(Ch);
    case Ch of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if C < 32 then
        Result := Result + '\u' + IntToHex(C, 4)
      else
        Result := Result + Ch;
    end;
  end;
  Result := Result + '"';
end;

// VDRX's current KYZU contract deliberately carries the inner event object
// as a JSON-encoded string in the outer payload field. Keep that wire format
// stable, but centralize the escaping so callers cannot accidentally emit
// invalid JSON when an id/name contains '"', '\\', or control characters.
function MakeEventLine(const ATopic, APayloadJSON: string): string;
begin
  Result := '{"topic":' + JsonQuote(ATopic) + ',"payload":' +
    JsonQuote(APayloadJSON) + '}';
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
  // Lon = 180.0 exactly (a legitimate value - the antimeridian itself)
  // computes to precisely Grid.Width, one past the last valid column.
  // Every caller already treats an out-of-range GX as a rejectable
  // "out of bounds" input, but clamping here means the boundary itself
  // resolves to the last real column instead of a value that's always
  // one-off from anything valid.
  if Result >= Grid.Width then Result := Grid.Width - 1;
  if Result < 0 then Result := 0;
end;

function LatToGridY(Lat: Double): Integer;
begin
  Result := Trunc((90.0 - Lat) / 180.0 * Grid.Height);
  // Same off-by-one at Lat = -90.0 exactly (the south pole).
  if Result >= Grid.Height then Result := Grid.Height - 1;
  if Result < 0 then Result := 0;
end;

function TryLonToGridX(Lon: Double; out GX: Integer): Boolean;
begin
  Result := (Lon >= -180.0) and (Lon <= 180.0) and
            (not IsNan(Lon)) and (not IsInfinite(Lon));
  if Result then
    GX := LonToGridX(Lon);
end;

function TryLatToGridY(Lat: Double; out GY: Integer): Boolean;
begin
  Result := (Lat >= -90.0) and (Lat <= 90.0) and
            (not IsNan(Lat)) and (not IsInfinite(Lat));
  if Result then
    GY := LatToGridY(Lat);
end;

// The grid is toroidal in X only - longitude wraps at the ±180° seam,
// matching kyzu_pathfinding.pas's own wrapping (see its "Toroidal
// wrapping along the X axis" and heuristic seam-wrap comments).
// Latitude never wraps; there are real poles up there, not a seam.
// Returns the SIGNED shorter-way-around delta from AX1 to AX2, so
// AdvanceUnits can use it as a step direction, not just a magnitude.
function WrappedDX(AX1, AX2: Double): Double;
begin
  Result := AX2 - AX1;
  if Result > Grid.Width / 2.0 then
    Result := Result - Grid.Width
  else if Result < -Grid.Width / 2.0 then
    Result := Result + Grid.Width;
end;

// Straight-line grid distance with the same antimeridian wrap applied
// to the X component. Every proximity/range check in this file
// (collect radius, attack range, AI node-seeking) should go through
// this rather than a raw Sqrt(Sqr(dx)+Sqr(dy)) - otherwise a unit and
// a node/unit/city sitting on opposite sides of the ±180° seam measure
// as roughly Grid.Width cells apart instead of however close they
// actually are, even though a unit can genuinely path across that seam
// (pathfinding already wraps it).
function WrappedDistance(AX1, AY1, AX2, AY2: Double): Double;
var
  dx, dy: Double;
begin
  dx := WrappedDX(AX1, AX2);
  dy := AY2 - AY1;
  Result := Sqrt(dx * dx + dy * dy);
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

// Parses a JSON array of {"resource_type":"...", "amount":N} objects -
// shared by both CityGrowthCost and CityUpkeepCost, since a growth
// recipe and an upkeep bill are the same shape of thing.
function ParseResourceCostList(AArr: TJSONArray): TResourceCostList;
var
  i: Integer;
  Obj: TJSONObject;
begin
  SetLength(Result, AArr.Count);
  for i := 0 to AArr.Count - 1 do
  begin
    Obj := TJSONObject(AArr.Items[i]);
    Result[i].ResourceType := Obj.Get('resource_type', '');
    Result[i].Amount := Obj.Get('amount', 0);
  end;
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
      ListJSON := ListJSON + '{"id":' + JsonQuote(Node.ID) +
        ',"resource_type":' + JsonQuote(Node.ResourceType) +
        ',"lon":' + Format('%.4f', [Node.Lon]) +
        ',"lat":' + Format('%.4f', [Node.Lat]) +
        ',"amount":' + IntToStr(Node.Amount) + '}';
    end;
  finally
    NodesLock.Leave;
  end;
  ListJSON := ListJSON + ']';

  SendLine(MakeEventLine('game.event.node_list', '{"nodes":' + ListJSON + '}'));
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

// Canonical, order-independent key for a faction pair - DiplomacyKey('a','b')
// and DiplomacyKey('b','a') always produce the same string, so a
// relationship only ever needs one dictionary entry regardless of which
// side is doing the asking. Plain string comparison is enough ordering
// for this - factions are free-form owner strings, not anything with a
// meaningful sort order beyond "consistent".
function DiplomacyKey(const A, B: string): string;
begin
  if A <= B then
    Result := A + '|' + B
  else
    Result := B + '|' + A;
end;

// 'war', 'allied', or '' (neutral - the default for any two factions
// that have never interacted). Same faction compared to itself is
// always '' too - nothing calling this ever needs a faction's
// relationship with itself distinguished from ordinary neutral.
function GetDiplomaticStatus(const A, B: string): string;
begin
  Result := '';
  if A = B then Exit;
  DiplomacyLock.Enter;
  try
    DiplomaticStatus.TryGetValue(DiplomacyKey(A, B), Result);
  finally
    DiplomacyLock.Leave;
  end;
end;

// Applies AStatus ('war', 'allied', or '' for neutral) between A and B,
// persists it, and broadcasts it - the single path every diplomacy
// handler and HandleAttack's auto-war-on-first-strike go through, so
// the log/broadcast shape never drifts between callers. '' removes the
// key entirely rather than storing an explicit 'neutral' value (see
// DiplomaticStatus's own comment).
procedure SetDiplomaticStatus(const A, B, AStatus: string);
var
  Key: string;
begin
  Key := DiplomacyKey(A, B);
  DiplomacyLock.Enter;
  try
    if AStatus = '' then
      DiplomaticStatus.Remove(Key)
    else
      DiplomaticStatus.AddOrSetValue(Key, AStatus);
  finally
    DiplomacyLock.Leave;
  end;

  LogEvent('{"type":"diplomacy_status_changed","faction_a":' + JsonQuote(A) +
    ',"faction_b":' + JsonQuote(B) + ',"status":' + JsonQuote(AStatus) + '}');
  SendLine(MakeEventLine('game.event.diplomacy_status_changed',
    '{"faction_a":' + JsonQuote(A) + ',"faction_b":' + JsonQuote(B) +
    ',"status":' + JsonQuote(AStatus) + '}'));
end;

// True if AOwner has already completed ATechID. An empty ATechID (the
// common case - most unit types have RequiresTech = '') is trivially
// always true, matching every pre-tech unit type's unconditional
// spawnability.
function HasResearched(const AOwner, ATechID: string): Boolean;
begin
  if ATechID = '' then Exit(True);
  TechLock.Enter;
  try
    Result := ResearchedTech.ContainsKey(AOwner + '|' + ATechID);
  finally
    TechLock.Leave;
  end;
end;

// True if every prerequisite listed on ATechID has already been
// researched by AOwner. A tech with no prerequisites is trivially
// always startable (subject to affording its own Cost separately -
// see HandleStartResearch/RunAI).
function TechPrereqsMet(const AOwner: string; const ADef: TTechDef): Boolean;
var
  i: Integer;
begin
  Result := True;
  for i := 0 to High(ADef.Prerequisites) do
    if not HasResearched(AOwner, ADef.Prerequisites[i]) then
    begin
      Result := False;
      Break;
    end;
end;

// Which faction "controls" cell (GX,GY), or '' if no city's influence
// reaches it. Mirrors RecomputeDevelopment's own radius/falloff formula
// (see its comment for why population scales the radius) so territory
// lines up with what a viewer already sees as development, rather than
// being a second, inconsistent notion of "whose land this is". Where
// two different owners' cities both reach a cell, the stronger
// falloff value wins - same tie-break RecomputeDevelopment's Contrib
// dictionary already uses between overlapping cities.
function GetTerritoryOwner(GX, GY: Integer): string;
var
  C: TCity;
  radius: Integer;
  dx, dy, dist, falloff, val, BestVal: Double;
begin
  Result := '';
  BestVal := 0.0;
  CitiesLock.Enter;
  try
    for C in Cities.Values do
    begin
      if C.Owner = '' then Continue; // unowned cities claim no territory
      radius := Round(Min(Balance.DevelopmentRadiusCells,
        Balance.DevelopmentMinRadiusCells + Balance.DevelopmentRadiusCells * (C.Population / Balance.CityMaxPopulation)));
      dx := GX - C.GX; dy := GY - C.GY;
      dist := Sqrt(dx * dx + dy * dy);
      if dist > radius then Continue;
      falloff := 1.0 - (dist / radius);
      val := falloff * falloff * (C.Population / Balance.CityMaxPopulation);
      if val > BestVal then
      begin
        BestVal := val;
        Result := C.Owner;
      end;
    end;
  finally
    CitiesLock.Leave;
  end;
end;

procedure HandleSpawn(APayload: TJSONObject);
var
  UnitID: string;
  U: TUnit;
  Lon, Lat: Double;
  GX, GY: Integer;
  AlreadyExists: Boolean;
begin
  UnitID := APayload.Get('unit_id', '');
  if UnitID = '' then Exit;

  // Without this, any client sending an ALREADY-TAKEN unit_id would
  // silently overwrite that unit in place via AddOrSetValue below -
  // hijacking its owner, resetting its HP/position, all for free,
  // bypassing combat entirely. IDs are broadcast openly in every
  // spawned/position event, so this isn't just a hypothetical
  // collision - anyone watching the event stream can read an
  // opponent's exact unit_id and reuse it deliberately. Now that
  // external, non-browser clients can genuinely connect and issue
  // commands (not just the map viewer), this stopped being a
  // theoretical concern.
  UnitsLock.Enter;
  try
    AlreadyExists := Units.ContainsKey(UnitID);
  finally
    UnitsLock.Leave;
  end;
  if AlreadyExists then
  begin
    SendLine(MakeEventLine('game.event.spawn_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"id already in use"}'));
    Exit;
  end;

  Lon := APayload.Get('lon', 0.0);
  Lat := APayload.Get('lat', 0.0);
  // Validate the geographic range before grid conversion. The conversion
  // helpers intentionally clamp exact valid endpoints (±180/±90), so
  // checking only the resulting cell cannot reject values like lon=999.
  if (not TryLonToGridX(Lon, GX)) or (not TryLatToGridY(Lat, GY)) then
  begin
    SendLine(MakeEventLine('game.event.spawn_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"out of bounds"}'));
    Exit;
  end;

  if CellMoveCost(Grid, Config, GX, GY) <= 0 then
  begin
    SendLine(MakeEventLine('game.event.spawn_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"impassable terrain"}'));
    Exit;
  end;

  U.Owner := APayload.Get('owner', '');
  U.UnitType := APayload.Get('unit_type', 'generic');

  // Unowned spawns (U.Owner = '') stay exempt - there's no faction to
  // check ResearchedTech against, same free-for-all carve-out
  // HandleMove/HandleDespawn already give unowned units.
  if (U.Owner <> '') and not HasResearched(U.Owner, GetUnitDef(U.UnitType).RequiresTech) then
  begin
    SendLine(MakeEventLine('game.event.spawn_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"tech not researched"}'));
    Exit;
  end;

  U.ID := UnitID;
  U.GX := GX + 0.5;
  U.GY := GY + 0.5;
  SetLength(U.Path, 0);
  U.PathIndex := 0;
  U.HP := GetUnitDef(U.UnitType).MaxHP;
  U.XP := 0;
  U.Level := 0;

  UnitsLock.Enter;
  try
    Units.AddOrSetValue(UnitID, U);
  finally
    UnitsLock.Leave;
  end;

  LogEvent('{"type":"spawned","unit_id":' + JsonQuote(UnitID) +
    ',"owner":' + JsonQuote(U.Owner) + ',"unit_type":' + JsonQuote(U.UnitType) +
    ',"lon":' + Format('%.4f', [GridToLon(U.GX)]) +
    ',"lat":' + Format('%.4f', [GridToLat(U.GY)]) +
    ',"hp":' + IntToStr(U.HP) + '}');
  SendLine(MakeEventLine('game.event.spawned', '{"unit_id":' + JsonQuote(UnitID) +
    ',"owner":' + JsonQuote(U.Owner) + ',"unit_type":' + JsonQuote(U.UnitType) +
    ',"lon":' + Format('%.4f', [GridToLon(U.GX)]) +
    ',"lat":' + Format('%.4f', [GridToLat(U.GY)]) +
    ',"hp":' + IntToStr(U.HP) + '}'));
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
    SendLine(MakeEventLine('game.event.despawn_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"unknown unit"}'));
    Exit;
  end;

  if not Owned then
  begin
    SendLine(MakeEventLine('game.event.despawn_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"not your unit"}'));
    Exit;
  end;

  LogEvent('{"type":"despawned","unit_id":' + JsonQuote(UnitID) + '}');
  SendLine(MakeEventLine('game.event.despawned', '{"unit_id":' + JsonQuote(UnitID) + '}'));
end;

procedure HandleMove(APayload: TJSONObject);
var
  UnitID, Actor, TerritoryOwner, DiploStatus: string;
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
    SendLine(MakeEventLine('game.event.move_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"unknown unit"}'));
    Exit;
  end;

  // Unowned units (Owner = '') stay free-for-all - keeps the bus
  // terminal's own raw quick-command buttons (which never send "by")
  // working unmodified against any unit spawned without an owner.
  if (U.Owner <> '') and (U.Owner <> Actor) then
  begin
    SendLine(MakeEventLine('game.event.move_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"not your unit"}'));
    Exit;
  end;

  ToLon := APayload.Get('to_lon', 0.0);
  ToLat := APayload.Get('to_lat', 0.0);
  // Validate before conversion for the same reason as spawn: otherwise
  // an out-of-range request silently becomes an edge-cell destination.
  if (not TryLonToGridX(ToLon, ToX)) or (not TryLatToGridY(ToLat, ToY)) then
  begin
    SendLine(MakeEventLine('game.event.move_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"out of bounds"}'));
    Exit;
  end;
  StartX := Trunc(U.GX);
  StartY := Trunc(U.GY);

  // Territory rule: a destination inside another faction's territory
  // (see GetTerritoryOwner) is only open to a unit whose owner is at
  // 'war' with that faction (invasion - the whole point of a war) or
  // 'allied' with them (open borders). A plain neutral relationship
  // keeps the border closed - declare war (or ally up) first. Unowned
  // units (U.Owner = '') stay exempt, same free-for-all carve-out as
  // the ownership check above.
  if U.Owner <> '' then
  begin
    TerritoryOwner := GetTerritoryOwner(ToX, ToY);
    if (TerritoryOwner <> '') and (TerritoryOwner <> U.Owner) then
    begin
      DiploStatus := GetDiplomaticStatus(U.Owner, TerritoryOwner);
      if DiploStatus = '' then
      begin
        SendLine(MakeEventLine('game.event.move_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"neutral territory - declare war or ally to enter"}'));
        Exit;
      end;
    end;
  end;

  Path := FindPath(Grid, Config, StartX, StartY, ToX, ToY);
  if Length(Path) = 0 then
  begin
    SendLine(MakeEventLine('game.event.move_failed', '{"unit_id":' + JsonQuote(UnitID) + ',"reason":"no path"}'));
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

  LogEvent('{"type":"path_found","unit_id":' + JsonQuote(UnitID) + ',"path":' + BuildPathJSON(Path) + '}');
  SendLine(MakeEventLine('game.event.path_found', '{"unit_id":' + JsonQuote(UnitID) +
    ',"steps":' + IntToStr(Length(Path)) + ',"path":' + BuildPathJSON(Path) + '}'));
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
        Dist := WrappedDistance(U.GX, U.GY, Node.GX, Node.GY);
        if Dist > Balance.CollectRadiusCells then
          Reason := 'too far'
        else if Node.Amount <= 0 then
          Reason := 'depleted'
        else
        begin
          // A better-suited unit type (e.g. a dedicated worker) takes
          // more per action via CollectMultiplier - the gate above
          // (CanCollect) decides WHO can collect at all, this decides
          // how much a type that can collect actually gets.
          Taken := Round(Balance.CollectAmountPerAction * UnitDef.CollectMultiplier);
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
    SendLine(MakeEventLine('game.event.collect_failed', '{"unit_id":' + JsonQuote(UnitID) +
      ',"node_id":' + JsonQuote(NodeID) + ',"reason":' + JsonQuote(Reason) + '}'));
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

  LogEvent('{"type":"collected","unit_id":' + JsonQuote(UnitID) +
    ',"node_id":' + JsonQuote(NodeID) + ',"by":' + JsonQuote(Actor) +
    ',"amount":' + IntToStr(Taken) + '}');
  SendLine(MakeEventLine('game.event.collected', '{"unit_id":' + JsonQuote(UnitID) +
    ',"node_id":' + JsonQuote(NodeID) + ',"resource_type":' + JsonQuote(Node.ResourceType) +
    ',"by":' + JsonQuote(Actor) + ',"amount":' + IntToStr(Taken) +
    ',"remaining":' + IntToStr(Node.Amount) + '}'));
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
        TotalsJSON := TotalsJSON + JsonQuote(KeyResource) + ':' + IntToStr(Pair.Value);
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

  // Checked here, BEFORE the unit gets consumed below - a city_id
  // collision needs to fail before the founding unit is spent, not
  // after, or a rejected founding would still cost the player their
  // settler for nothing. Without this check at all, a colliding id
  // would silently overwrite an existing city via AddOrSetValue -
  // instantly "capturing" it for free, resetting its owner and
  // population, with none of the siege mechanic HandleAttack enforces.
  if Reason = '' then
  begin
    CitiesLock.Enter;
    try
      if Cities.ContainsKey(CityID) then
        Reason := 'city id already in use';
    finally
      CitiesLock.Leave;
    end;
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
    SendLine(MakeEventLine('game.event.city_failed', '{"city_id":' + JsonQuote(CityID) +
      ',"unit_id":' + JsonQuote(UnitID) + ',"reason":' + JsonQuote(Reason) + '}'));
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
  LogEvent('{"type":"despawned","unit_id":' + JsonQuote(UnitID) + '}');
  SendLine(MakeEventLine('game.event.despawned', '{"unit_id":' + JsonQuote(UnitID) + '}'));

  Owner := U.Owner;
  C.ID := CityID;
  C.Owner := Owner;
  C.GX := GX;
  C.GY := GY;
  C.Population := Balance.CityInitialPopulation;
  C.LastGrowthTick := Tick;
  C.LastUpkeepTick := Tick;

  CitiesLock.Enter;
  try
    Cities.AddOrSetValue(CityID, C);
  finally
    CitiesLock.Leave;
  end;

  LogEvent('{"type":"city_founded","city_id":' + JsonQuote(CityID) +
    ',"owner":' + JsonQuote(Owner) + ',"lon":' + Format('%.4f', [GridToLon(GX + 0.5)]) +
    ',"lat":' + Format('%.4f', [GridToLat(GY + 0.5)]) + ',"population":' + IntToStr(C.Population) + '}');
  SendLine(MakeEventLine('game.event.city_founded', '{"city_id":' + JsonQuote(CityID) +
    ',"owner":' + JsonQuote(Owner) + ',"lon":' + Format('%.4f', [GridToLon(GX + 0.5)]) +
    ',"lat":' + Format('%.4f', [GridToLat(GY + 0.5)]) + ',"population":' + IntToStr(C.Population) + '}'));
end;

// Grows every city's population by a fixed step once every
// Balance.CityGrowthTicks ticks - simple time-based growth for a first pass,
// same tuning-constant spirit as Balance.BaseSpeed. An OWNED city's growth now
// also costs Balance.CityGrowthCost out of its owner's
// ledger - ties resource collection back into this loop instead of
// population climbing for free forever. An unowned (neutral/seed) city
// has nobody to charge and keeps growing on the timer alone. Called
// once per tick from the main loop; the per-city interval check keeps
// it a no-op for idle cities rather than a busy poll.

// True if AOwner's ledger currently holds at least ACosts' amount of
// EVERY resource type it lists - checked as one atomic pass under
// LedgerLock so a concurrent collect/spend can't be observed mid-check
// (all-or-nothing, same guarantee the old fixed wood+stone check had).
// An empty cost list is trivially always affordable.
function CanAffordCost(const AOwner: string; const ACosts: TResourceCostList): Boolean;
var
  i, Total: Integer;
begin
  Result := True;
  if Length(ACosts) = 0 then Exit;
  LedgerLock.Enter;
  try
    for i := 0 to High(ACosts) do
    begin
      Total := 0;
      Ledger.TryGetValue(AOwner + '|' + ACosts[i].ResourceType, Total);
      if Total < ACosts[i].Amount then
      begin
        Result := False;
        Break;
      end;
    end;
  finally
    LedgerLock.Leave;
  end;
end;

// Deducts every line of ACosts from AOwner's ledger. Caller must have
// already confirmed CanAffordCost - this doesn't re-check. Clamped at
// 0 as defense-in-depth (should never actually trigger during live
// play since CanAffordCost already gated it, but replay reuses this
// same function and a defensive floor costs nothing here).
procedure DeductCost(const AOwner: string; const ACosts: TResourceCostList);
var
  i, Total: Integer;
  Key: string;
begin
  LedgerLock.Enter;
  try
    for i := 0 to High(ACosts) do
    begin
      Key := AOwner + '|' + ACosts[i].ResourceType;
      Total := 0;
      Ledger.TryGetValue(Key, Total);
      Total := Total - ACosts[i].Amount;
      if Total < 0 then Total := 0;
      Ledger.AddOrSetValue(Key, Total);
    end;
  finally
    LedgerLock.Leave;
  end;
end;

// Renders a cost list as a JSON array of {"resource_type":...,"amount":...}
// objects - the generic shape city_growth_spent/city_upkeep_spent both
// broadcast now, replacing the old fixed wood/stone fields. Returns
// PLAIN unescaped JSON (normal quote characters) - callers embedding
// this into a LogEvent line use it as-is (events.jsonl lines are flat,
// single-level JSON), while SendLine callers need to
// StringReplace(..., '"', '\"', ...) the result first, same as every
// other nested-array payload in this file (see HandleListCities et al).
function CostsToJSON(const ACosts: TResourceCostList): string;
var
  i: Integer;
begin
  Result := '[';
  for i := 0 to High(ACosts) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + '{"resource_type":' + JsonQuote(ACosts[i].ResourceType) +
      ',"amount":' + IntToStr(ACosts[i].Amount) + '}';
  end;
  Result := Result + ']';
end;

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
// or collecting automatically applies to the AI too. Settlers/soldiers
// added for expansion/combat follow the same principle - see RunAI's
// own body below for how each unit type is driven.

// Builds a road between two existing cities, reusing the same A*
// pathfinding as HandleMove with the cities' cells as start/end. The
// path is cached on the TRoad so RecomputeDevelopment doesn't need to
// re-run pathfinding on every density update. Moved ahead of RunAI
// (which used to be textually first) because RunAI's own road-building
// pass now calls this directly, and this file has no forward
// declarations - everything a procedure calls has to already be
// defined above it.
procedure HandleBuildRoad(APayload: TJSONObject);
var
  RoadID, FromCityID, ToCityID, Actor: string;
  FromCity, ToCity: TCity;
  Found1, Found2, RoadIDTaken: Boolean;
  Path: TGridPath;
  R: TRoad;
begin
  RoadID := APayload.Get('road_id', '');
  FromCityID := APayload.Get('from_city_id', '');
  ToCityID := APayload.Get('to_city_id', '');
  Actor := APayload.Get('by', '');
  if (RoadID = '') or (FromCityID = '') or (ToCityID = '') then Exit;

  // Same reasoning as the unit_id/city_id checks in HandleSpawn/
  // HandleFoundCity - without this, a colliding road_id would silently
  // overwrite an existing road's endpoints/path via AddOrSetValue.
  RoadsLock.Enter;
  try
    RoadIDTaken := Roads.ContainsKey(RoadID);
  finally
    RoadsLock.Leave;
  end;
  if RoadIDTaken then
  begin
    SendLine(MakeEventLine('game.event.road_failed', '{"road_id":' + JsonQuote(RoadID) + ',"reason":"id already in use"}'));
    Exit;
  end;

  CitiesLock.Enter;
  try
    Found1 := Cities.TryGetValue(FromCityID, FromCity);
    Found2 := Cities.TryGetValue(ToCityID, ToCity);
  finally
    CitiesLock.Leave;
  end;

  if (not Found1) or (not Found2) then
  begin
    SendLine(MakeEventLine('game.event.road_failed', '{"road_id":' + JsonQuote(RoadID) + ',"reason":"unknown city"}'));
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
    SendLine(MakeEventLine('game.event.road_failed', '{"road_id":' + JsonQuote(RoadID) + ',"reason":"not your city"}'));
    Exit;
  end;

  Path := FindPath(Grid, Config, FromCity.GX, FromCity.GY, ToCity.GX, ToCity.GY);
  if Length(Path) = 0 then
  begin
    SendLine(MakeEventLine('game.event.road_failed', '{"road_id":' + JsonQuote(RoadID) + ',"reason":"no path"}'));
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

  LogEvent('{"type":"road_built","road_id":' + JsonQuote(RoadID) +
    ',"from_city_id":' + JsonQuote(FromCityID) + ',"to_city_id":' + JsonQuote(ToCityID) +
    ',"owner":' + JsonQuote(Actor) + ',"path":' + BuildPathJSON(Path) + '}');
  SendLine(MakeEventLine('game.event.road_built', '{"road_id":' + JsonQuote(RoadID) +
    ',"from_city_id":' + JsonQuote(FromCityID) + ',"to_city_id":' + JsonQuote(ToCityID) +
    ',"steps":' + IntToStr(Length(Path)) + ',"path":' + BuildPathJSON(Path) + '}'));
end;

// True if a direct road already links two specific cities (either
// direction) - the AI road-builder's own narrower question compared to
// IsCityRoadConnected's "connected to ANY same-owner city" check, since
// the AI wants to know about THIS pair specifically before spending a
// road_id on a duplicate.
function RoadExistsBetween(const ACityID1, ACityID2: string): Boolean;
var
  R: TRoad;
begin
  Result := False;
  RoadsLock.Enter;
  try
    for R in Roads.Values do
      if ((R.FromCityID = ACityID1) and (R.ToCityID = ACityID2)) or
         ((R.FromCityID = ACityID2) and (R.ToCityID = ACityID1)) then
      begin
        Result := True;
        Break;
      end;
  finally
    RoadsLock.Leave;
  end;
end;

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

// Handles both unit-vs-unit and unit-vs-city combat, distinguished by
// which of target_unit_id/target_city_id the payload sets. A city's
// Population doubles as its defense pool (see Balance.SiegeDamagePerAttack's
// comment) - hitting a city just decrements it the same way an
// attacker's damage decrements a unit's HP, and capture is simply what
// happens when that pool bottoms out, mirroring death for units.
procedure HandleAttack(APayload: TJSONObject);
var
  AttackerID, TargetUnitID, TargetCityID, Actor, Reason, PrevOwner: string;
  Attacker, TargetUnit: TUnit;
  AttackerDef: TUnitDef;
  AttackerFound, TargetUnitFound, TargetCityFound, LeveledUp: Boolean;
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
    else if (TargetUnit.Owner <> '') and (GetDiplomaticStatus(Attacker.Owner, TargetUnit.Owner) = 'allied') then
      Reason := 'cannot attack an allied faction - break the alliance first'
    else
    begin
      Dist := WrappedDistance(Attacker.GX, Attacker.GY, TargetUnit.GX, TargetUnit.GY);
      if Dist > Balance.AttackRangeCells then
        Reason := 'too far';
    end;

    // A strike against a faction not already at war is itself a
    // declaration of war - same "attacking auto-opens hostilities"
    // convention plenty of strategy games use, so declare_war is
    // available for signaling intent up front but never a hard
    // prerequisite to actually fighting. Allied targets never reach
    // here (blocked above); an unowned target (TargetUnit.Owner = '')
    // has no faction to open a war against.
    if (Reason = '') and (TargetUnit.Owner <> '') and (GetDiplomaticStatus(Attacker.Owner, TargetUnit.Owner) <> 'war') then
      SetDiplomaticStatus(Attacker.Owner, TargetUnit.Owner, 'war');

    if Reason = '' then
    begin
      // Effective damage includes the attacker's veterancy bonus - a
      // Level 2 soldier hits harder than a fresh one of the same type.
      Damage := AttackerDef.Attack + Attacker.Level * Balance.VeterancyAttackBonusPerLevel;
      NewHP := TargetUnit.HP - Damage;
      if NewHP < 0 then NewHP := 0;

      // Veterancy: any landed hit grants XP, win or lose, dead or
      // alive on the target's side - the attacker did the fighting
      // regardless of outcome. Scoped to unit-vs-unit only (see
      // Balance.VeterancyXPPerHit's comment) so this branch is the only place
      // that ever touches XP/Level.
      Attacker.XP := Attacker.XP + Balance.VeterancyXPPerHit;
      LeveledUp := False;
      while (Attacker.Level < Balance.VeterancyMaxLevel) and
            (Attacker.XP >= (Attacker.Level + 1) * Balance.VeterancyXPPerLevel) do
      begin
        Attacker.XP := Attacker.XP - (Attacker.Level + 1) * Balance.VeterancyXPPerLevel;
        Inc(Attacker.Level);
        Inc(Attacker.HP, Balance.VeterancyHPBonusPerLevel); // heals on level-up, not just a higher ceiling a wounded unit wouldn't feel
        LeveledUp := True;
      end;
      UnitsLock.Enter;
      try
        Units.AddOrSetValue(AttackerID, Attacker);
      finally
        UnitsLock.Leave;
      end;

      LogEvent('{"type":"unit_attacked","attacker_unit_id":' + JsonQuote(AttackerID) +
        ',"target_unit_id":' + JsonQuote(TargetUnitID) + ',"by":' + JsonQuote(Actor) +
        ',"damage":' + IntToStr(Damage) + ',"remaining_hp":' + IntToStr(NewHP) +
        ',"attacker_xp":' + IntToStr(Attacker.XP) + ',"attacker_level":' + IntToStr(Attacker.Level) + '}');
      SendLine(MakeEventLine('game.event.unit_attacked', '{"attacker_unit_id":' + JsonQuote(AttackerID) +
        ',"target_unit_id":' + JsonQuote(TargetUnitID) + ',"by":' + JsonQuote(Actor) +
        ',"damage":' + IntToStr(Damage) + ',"remaining_hp":' + IntToStr(NewHP) +
        ',"attacker_xp":' + IntToStr(Attacker.XP) + ',"attacker_level":' + IntToStr(Attacker.Level) + '}'));

      if LeveledUp then
      begin
        // Notification-only - fully redundant with the attacker_xp/
        // attacker_level fields already in unit_attacked above, so
        // replay never needs to handle this one specially. It exists
        // purely so a dashboard or map viewer can flag the moment
        // distinctly rather than noticing it by comparing two numbers.
        SendLine(MakeEventLine('game.event.unit_leveled_up', '{"unit_id":' + JsonQuote(AttackerID) +
          ',"level":' + IntToStr(Attacker.Level) + ',"hp":' + IntToStr(Attacker.HP) + '}'));
      end;

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
        LogEvent('{"type":"despawned","unit_id":' + JsonQuote(TargetUnitID) + '}');
        SendLine(MakeEventLine('game.event.despawned', '{"unit_id":' + JsonQuote(TargetUnitID) + '}'));
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
    else if (TargetCity.Owner <> '') and (GetDiplomaticStatus(Attacker.Owner, TargetCity.Owner) = 'allied') then
      Reason := 'cannot siege an allied faction - break the alliance first'
    else
    begin
      // TargetCity.GX/GY are the raw cell (no +0.5) - unlike a unit's
      // GX/GY, which is always a cell CENTER. Comparing against the
      // raw cell made the effective range asymmetric depending on
      // which direction the attacker approached from (a city dead
      // east could be out of range while the same distance to the
      // west was in range) - +0.5 puts both sides of the comparison
      // on the same cell-center footing.
      Dist := WrappedDistance(Attacker.GX, Attacker.GY, TargetCity.GX + 0.5, TargetCity.GY + 0.5);
      if Dist > Balance.AttackRangeCells then
        Reason := 'too far';
    end;

    // Same auto-war convention as the unit-target branch above.
    if (Reason = '') and (TargetCity.Owner <> '') and (GetDiplomaticStatus(Attacker.Owner, TargetCity.Owner) <> 'war') then
      SetDiplomaticStatus(Attacker.Owner, TargetCity.Owner, 'war');

    if Reason = '' then
    begin
      NewPop := TargetCity.Population - Balance.SiegeDamagePerAttack;

      if NewPop <= 0 then
      begin
        PrevOwner := TargetCity.Owner;
        TargetCity.Owner := Attacker.Owner;
        TargetCity.Population := Balance.CityCaptureResetPopulation;
        TargetCity.LastGrowthTick := Tick;
        TargetCity.LastUpkeepTick := Tick; // fresh upkeep clock too - no back-charged upkeep from being conquered

        CitiesLock.Enter;
        try
          Cities.AddOrSetValue(TargetCityID, TargetCity);
        finally
          CitiesLock.Leave;
        end;

        LogEvent('{"type":"city_captured","city_id":' + JsonQuote(TargetCityID) +
          ',"previous_owner":' + JsonQuote(PrevOwner) + ',"new_owner":' + JsonQuote(TargetCity.Owner) +
          ',"population":' + IntToStr(TargetCity.Population) + '}');
        SendLine(MakeEventLine('game.event.city_captured', '{"city_id":' + JsonQuote(TargetCityID) +
          ',"previous_owner":' + JsonQuote(PrevOwner) + ',"new_owner":' + JsonQuote(TargetCity.Owner) +
          ',"population":' + IntToStr(TargetCity.Population) + '}'));
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

        LogEvent('{"type":"city_attacked","city_id":' + JsonQuote(TargetCityID) +
          ',"attacker_unit_id":' + JsonQuote(AttackerID) + ',"by":' + JsonQuote(Actor) +
          ',"damage":' + IntToStr(Balance.SiegeDamagePerAttack) + ',"population_remaining":' + IntToStr(NewPop) + '}');
        SendLine(MakeEventLine('game.event.city_attacked', '{"city_id":' + JsonQuote(TargetCityID) +
          ',"attacker_unit_id":' + JsonQuote(AttackerID) + ',"by":' + JsonQuote(Actor) +
          ',"damage":' + IntToStr(Balance.SiegeDamagePerAttack) + ',"population_remaining":' + IntToStr(NewPop) + '}'));
      end;
      Exit;
    end;
  end;

  if Reason <> '' then
    SendLine(MakeEventLine('game.event.attack_failed', '{"attacker_unit_id":' + JsonQuote(AttackerID) + ',"reason":' + JsonQuote(Reason) + '}'));
end;

// Starts research on ATechID for AOwner, deducting its Cost up front
// (same "pay now, wait ticks" shape as GrowCities' growth cost, except
// research has no free-if-unaffordable retry loop - a rejected start
// just fails outright and the caller can retry once they can afford
// it). One research at a time per faction - starting a new one while
// another is already running is rejected rather than queued or
// overwritten, so a faction's progress on its current pick is never
// silently lost to a second command.
procedure HandleStartResearch(APayload: TJSONObject);
var
  TechID, Actor, Reason: string;
  Def: TTechDef;
  DefFound, AlreadyInProgress: Boolean;
  Dummy: TResearchInProgress;
  InProgress: TResearchInProgress;
begin
  TechID := APayload.Get('tech_id', '');
  Actor := APayload.Get('by', '');
  if (TechID = '') or (Actor = '') then Exit;

  Reason := '';
  DefFound := TechDefs.TryGetValue(TechID, Def);

  if not DefFound then
    Reason := 'unknown tech'
  else if HasResearched(Actor, TechID) then
    Reason := 'already researched'
  else if not TechPrereqsMet(Actor, Def) then
    Reason := 'prerequisites not met'
  else
  begin
    TechLock.Enter;
    try
      AlreadyInProgress := ResearchInProgress.TryGetValue(Actor, Dummy);
    finally
      TechLock.Leave;
    end;
    if AlreadyInProgress then
      Reason := 'research already in progress'
    else if not CanAffordCost(Actor, Def.Cost) then
      Reason := 'cannot afford';
  end;

  if Reason <> '' then
  begin
    SendLine(MakeEventLine('game.event.research_failed', '{"tech_id":' + JsonQuote(TechID) + ',"by":' + JsonQuote(Actor) +
      ',"reason":' + JsonQuote(Reason) + '}'));
    Exit;
  end;

  DeductCost(Actor, Def.Cost);

  InProgress.TechID := TechID;
  InProgress.StartTick := Tick;
  TechLock.Enter;
  try
    ResearchInProgress.AddOrSetValue(Actor, InProgress);
  finally
    TechLock.Leave;
  end;

  if Length(Def.Cost) > 0 then
  begin
    LogEvent('{"type":"research_cost_spent","owner":' + JsonQuote(Actor) + ',"costs":' + CostsToJSON(Def.Cost) + '}');
    SendLine(MakeEventLine('game.event.research_cost_spent', '{"owner":' + JsonQuote(Actor) +
      ',"costs":' + CostsToJSON(Def.Cost) + '}'));
  end;

  LogEvent('{"type":"research_started","owner":' + JsonQuote(Actor) + ',"tech_id":' + JsonQuote(TechID) + '}');
  SendLine(MakeEventLine('game.event.research_started', '{"owner":' + JsonQuote(Actor) +
    ',"tech_id":' + JsonQuote(TechID) + ',"research_ticks":' + IntToStr(Def.ResearchTicks) + '}'));
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
      ListJSON := ListJSON + '{"id":' + JsonQuote(C.ID) +
        ',"owner":' + JsonQuote(C.Owner) +
        ',"lon":' + Format('%.4f', [GridToLon(C.GX + 0.5)]) +
        ',"lat":' + Format('%.4f', [GridToLat(C.GY + 0.5)]) +
        ',"population":' + IntToStr(C.Population) + '}';
    end;
  finally
    CitiesLock.Leave;
  end;
  ListJSON := ListJSON + ']';
  SendLine(MakeEventLine('game.event.city_list', '{"cities":' + ListJSON + '}'));
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
      ListJSON := ListJSON + '{"id":' + JsonQuote(R.ID) +
        ',"from_city_id":' + JsonQuote(R.FromCityID) +
        ',"to_city_id":' + JsonQuote(R.ToCityID) +
        ',"owner":' + JsonQuote(R.Owner) +
        ',"path":' + BuildPathJSON(R.Path) + '}';
    end;
  finally
    RoadsLock.Leave;
  end;
  ListJSON := ListJSON + ']';
  SendLine(MakeEventLine('game.event.road_list', '{"roads":' + ListJSON + '}'));
end;

// Recomputes the whole density field from Cities+Roads every
// Balance.DevelopmentUpdateTicks ticks. A full recompute (not incremental
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

    RoadsLock.Enter;
    try
      for R in Roads.Values do
        for i := 0 to High(R.Path) do
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


// Full tech.json registry, same "one message, full current state"
// pattern as HandleListNodes/HandleListCities - a client needs this
// once to know what's researchable at all and what each tech costs/
// unlocks, then follows individual research_started/research_completed
// events for what's actually happened.
procedure HandleListTechDefs;
var
  TechID: string;
  Def: TTechDef;
  ListJSON, PrereqJSON: string;
  First, FirstPrereq: Boolean;
  i: Integer;
begin
  ListJSON := '[';
  First := True;
  for TechID in TechOrder do
  begin
    if not TechDefs.TryGetValue(TechID, Def) then Continue;
    if not First then ListJSON := ListJSON + ',';
    First := False;

    PrereqJSON := '[';
    FirstPrereq := True;
    for i := 0 to High(Def.Prerequisites) do
    begin
      if not FirstPrereq then PrereqJSON := PrereqJSON + ',';
      FirstPrereq := False;
      PrereqJSON := PrereqJSON + JsonQuote(Def.Prerequisites[i]);
    end;
    PrereqJSON := PrereqJSON + ']';

    ListJSON := ListJSON + '{"tech_id":' + JsonQuote(Def.TechID) +
      ',"display_name":' + JsonQuote(Def.DisplayName) +
      ',"research_ticks":' + IntToStr(Def.ResearchTicks) +
      ',"prerequisites":' + PrereqJSON +
      ',"cost":' + CostsToJSON(Def.Cost) + '}';
  end;
  ListJSON := ListJSON + ']';
  SendLine(MakeEventLine('game.event.tech_list', '{"tech_defs":' + ListJSON + '}'));
end;

// One faction's researched tech + current in-progress research (if
// any) - scoped to the requester's own "by", same privacy stance
// HandleGetLedger already takes with resource totals.
procedure HandleGetTech(APayload: TJSONObject);
var
  Actor, Prefix, TechID, ResearchedJSON: string;
  First: Boolean;
  Pair: specialize TPair<string, Boolean>;
  InProgress: TResearchInProgress;
  HasInProgress: Boolean;
begin
  Actor := APayload.Get('by', '');
  Prefix := Actor + '|';
  ResearchedJSON := '[';
  First := True;

  TechLock.Enter;
  try
    for Pair in ResearchedTech do
      if Copy(Pair.Key, 1, Length(Prefix)) = Prefix then
      begin
        TechID := Copy(Pair.Key, Length(Prefix) + 1, MaxInt);
        if not First then ResearchedJSON := ResearchedJSON + ',';
        First := False;
        ResearchedJSON := ResearchedJSON + '"' + TechID + '"';
      end;
    HasInProgress := ResearchInProgress.TryGetValue(Actor, InProgress);
  finally
    TechLock.Leave;
  end;
  ResearchedJSON := ResearchedJSON + ']';

  if HasInProgress then
    SendLine(MakeEventLine('game.event.tech_status', '{"owner":' + JsonQuote(Actor) + ',"researched":' + ResearchedJSON +
      ',"in_progress":' + JsonQuote(InProgress.TechID) + ',"started_tick":' + IntToStr(InProgress.StartTick) + '}'))
  else
    SendLine(MakeEventLine('game.event.tech_status', '{"owner":' + JsonQuote(Actor) + ',"researched":' + ResearchedJSON + ',"in_progress":""}'));
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

// One faction's current relationships with every other faction it has
// a non-neutral status with. Scans the whole DiplomaticStatus
// dictionary (cheap at the scale of "a handful of factions", same
// reasoning RunAI's node search already leans on) rather than
// maintaining a second per-faction index just for this query.
procedure HandleGetDiplomacy(APayload: TJSONObject);
var
  Actor, Other, ListJSON: string;
  First: Boolean;
  Pair: specialize TPair<string, string>;
  Parts: TStringArray;
begin
  Actor := APayload.Get('by', '');
  ListJSON := '[';
  First := True;

  DiplomacyLock.Enter;
  try
    for Pair in DiplomaticStatus do
    begin
      Parts := Pair.Key.Split('|');
      if Length(Parts) <> 2 then Continue;
      Other := '';
      if Parts[0] = Actor then Other := Parts[1]
      else if Parts[1] = Actor then Other := Parts[0];
      if Other = '' then Continue;

      if not First then ListJSON := ListJSON + ',';
      First := False;
      ListJSON := ListJSON + '{"faction":' + JsonQuote(Other) +
        ',"status":' + JsonQuote(Pair.Value) + '}';
    end;
  finally
    DiplomacyLock.Leave;
  end;
  ListJSON := ListJSON + ']';

  SendLine(MakeEventLine('game.event.diplomacy_status', '{"owner":' + JsonQuote(Actor) +
    ',"relations":' + ListJSON + '}'));
end;

// Unilateral - no acceptance needed, matching how HandleAttack's own
// auto-war-on-first-strike already treats war as something one side
// alone can start. Clears any standing alliance between the two
// (fighting an ally makes no sense without breaking that first) and
// any proposals either side had pending toward the other, since a
// declared war supersedes an unanswered alliance/peace offer.
procedure HandleDeclareWar(APayload: TJSONObject);
var
  Actor, Target: string;
begin
  Actor := APayload.Get('by', '');
  Target := APayload.Get('target', '');
  if (Actor = '') or (Target = '') or (Actor = Target) then Exit;

  DiplomacyLock.Enter;
  try
    PendingProposals.Remove(Actor + '|' + Target + '|alliance');
    PendingProposals.Remove(Target + '|' + Actor + '|alliance');
    PendingProposals.Remove(Actor + '|' + Target + '|peace');
    PendingProposals.Remove(Target + '|' + Actor + '|peace');
  finally
    DiplomacyLock.Leave;
  end;

  SetDiplomaticStatus(Actor, Target, 'war');
end;

// Proposes an alliance - takes effect only once Target calls
// HandleAcceptAlliance (see PendingProposals' own comment on why this
// half is never persisted/replayed). Rejected outright if the two are
// already at war - break peace first, alliance second, not both at
// once via a single accept.
procedure HandleProposeAlliance(APayload: TJSONObject);
var
  Actor, Target: string;
begin
  Actor := APayload.Get('by', '');
  Target := APayload.Get('target', '');
  if (Actor = '') or (Target = '') or (Actor = Target) then Exit;

  if GetDiplomaticStatus(Actor, Target) = 'war' then
  begin
    SendLine(MakeEventLine('game.event.alliance_proposal_failed', '{"by":' + JsonQuote(Actor) + ',"target":' + JsonQuote(Target) + ',"reason":"at war - make peace first"}'));
    Exit;
  end;

  DiplomacyLock.Enter;
  try
    PendingProposals.AddOrSetValue(Actor + '|' + Target + '|alliance', True);
  finally
    DiplomacyLock.Leave;
  end;

  SendLine(MakeEventLine('game.event.alliance_proposed', '{"by":' + JsonQuote(Actor) + ',"target":' + JsonQuote(Target) + '}'));
end;

// Actor accepts an alliance TARGET previously proposed TO them -
// note the reversed roles from HandleProposeAlliance: here Actor is
// the one who received the offer, Target is who sent it.
procedure HandleAcceptAlliance(APayload: TJSONObject);
var
  Actor, Target, Key: string;
  Pending: Boolean;
begin
  Actor := APayload.Get('by', '');
  Target := APayload.Get('target', '');
  if (Actor = '') or (Target = '') or (Actor = Target) then Exit;

  Key := Target + '|' + Actor + '|alliance'; // Target proposed, Actor is accepting
  DiplomacyLock.Enter;
  try
    Pending := PendingProposals.ContainsKey(Key);
    if Pending then PendingProposals.Remove(Key);
  finally
    DiplomacyLock.Leave;
  end;

  if not Pending then
  begin
    SendLine(MakeEventLine('game.event.alliance_accept_failed', '{"by":' + JsonQuote(Actor) + ',"target":' + JsonQuote(Target) + ',"reason":"no pending proposal"}'));
    Exit;
  end;

  SetDiplomaticStatus(Actor, Target, 'allied');
end;

// Unilateral, same as declaring war - either side can walk away from
// an alliance at any time, no acceptance from the other side required.
procedure HandleBreakAlliance(APayload: TJSONObject);
var
  Actor, Target: string;
begin
  Actor := APayload.Get('by', '');
  Target := APayload.Get('target', '');
  if (Actor = '') or (Target = '') or (Actor = Target) then Exit;
  if GetDiplomaticStatus(Actor, Target) <> 'allied' then Exit;

  SetDiplomaticStatus(Actor, Target, '');
end;

// Proposes ending a war - like alliance, takes effect only once the
// other side accepts (HandleAcceptPeace). Rejected if the two aren't
// actually at war, since "peace" is only meaningful relative to an
// active war.
procedure HandleProposePeace(APayload: TJSONObject);
var
  Actor, Target: string;
begin
  Actor := APayload.Get('by', '');
  Target := APayload.Get('target', '');
  if (Actor = '') or (Target = '') or (Actor = Target) then Exit;

  if GetDiplomaticStatus(Actor, Target) <> 'war' then
  begin
    SendLine(MakeEventLine('game.event.peace_proposal_failed', '{"by":' + JsonQuote(Actor) + ',"target":' + JsonQuote(Target) + ',"reason":"not at war"}'));
    Exit;
  end;

  DiplomacyLock.Enter;
  try
    PendingProposals.AddOrSetValue(Actor + '|' + Target + '|peace', True);
  finally
    DiplomacyLock.Leave;
  end;

  SendLine(MakeEventLine('game.event.peace_proposed', '{"by":' + JsonQuote(Actor) + ',"target":' + JsonQuote(Target) + '}'));
end;

// Mirrors HandleAcceptAlliance's reversed-roles convention: Target
// proposed peace, Actor is accepting it here.
procedure HandleAcceptPeace(APayload: TJSONObject);
var
  Actor, Target, Key: string;
  Pending: Boolean;
begin
  Actor := APayload.Get('by', '');
  Target := APayload.Get('target', '');
  if (Actor = '') or (Target = '') or (Actor = Target) then Exit;

  Key := Target + '|' + Actor + '|peace';
  DiplomacyLock.Enter;
  try
    Pending := PendingProposals.ContainsKey(Key);
    if Pending then PendingProposals.Remove(Key);
  finally
    DiplomacyLock.Leave;
  end;

  if not Pending then
  begin
    SendLine(MakeEventLine('game.event.peace_accept_failed', '{"by":' + JsonQuote(Actor) + ',"target":' + JsonQuote(Target) + ',"reason":"no pending proposal"}'));
    Exit;
  end;

  SetDiplomaticStatus(Actor, Target, '');
end;

procedure DispatchIncoming(const ALine: string);
var
  Data: TJSONData;
  Obj: TJSONObject;
  Topic: string;
  PayloadData: TJSONData;
  ParsedPayload: TJSONData;
begin
  ParsedPayload := nil;
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

    // A payload sent as a JSON STRING (rather than a nested object) is
    // accepted too, not just silently dropped. This server's OWN
    // outgoing events use exactly that shape
    // ({"topic":"...","payload":"{\"...\":...}"}), so a client that
    // mirrors that convention when sending commands would otherwise
    // have every command go nowhere with nothing to explain why.
    if Assigned(PayloadData) and (PayloadData.JSONType = jtString) then
    begin
      try
        ParsedPayload := GetJSON(PayloadData.AsString);
        if ParsedPayload.JSONType = jtObject then
          PayloadData := ParsedPayload;
      except
        // Not parseable as JSON after all - leave PayloadData as the
        // original string; every Handle* below already requires
        // jtObject and will just no-op on it, same as today.
      end;
    end;

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
    end
    else if Topic = 'game.cmd.list_tech_defs' then
      HandleListTechDefs
    else if Topic = 'game.cmd.get_tech' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleGetTech(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.start_research' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleStartResearch(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.get_diplomacy' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleGetDiplomacy(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.declare_war' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleDeclareWar(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.propose_alliance' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleProposeAlliance(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.accept_alliance' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleAcceptAlliance(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.break_alliance' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleBreakAlliance(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.propose_peace' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleProposePeace(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.accept_peace' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleAcceptPeace(TJSONObject(PayloadData));
    end;
    // add more topic handlers here as the command set grows
  finally
    Data.Free;
    if Assigned(ParsedPayload) then ParsedPayload.Free;
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

      SendLine(MakeEventLine('game.event.position', '{"unit_id":' + JsonQuote(Keys[i]) +
        ',"lon":' + Format('%.4f', [GridToLon(U.GX)]) + ',"lat":' + Format('%.4f', [GridToLat(U.GY)]) + '}'));
    finally
      UnitsLock.Leave;
    end;
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
    begin
      // DispatchIncoming's own try/except only covers the initial JSON
      // parse - a Handle* procedure raising anything else (a bad cast,
      // an unexpected nil, a range-check error) would previously
      // propagate all the way out of Execute uncaught. TThread swallows
      // an unhandled exception silently and just stops calling Execute
      // ever again - the tick loop keeps running and broadcasting state
      // as if nothing happened, but the server is now permanently deaf
      // to every future command with no crash, no log line, and no
      // visible symptom until someone notices commands stopped working.
      try
        DispatchIncoming(Line);
      except
        on E: Exception do
          LogDiag('DispatchIncoming raised ' + E.ClassName + ': ' + E.Message + ' - line ignored, reader continues');
      end;
    end;
  end;
end;

var
  ReaderThread: TStdinReaderThread;
  EventLogPath: string;
  EventLogExisted: Boolean;

begin
  // Format('%.4f', ...) and similar formatting throughout this file are
  // locale-sensitive in Free Pascal - on any machine whose regional
  // settings use a comma decimal separator (most of continental Europe,
  // among others), every "lon":%.4f would render as "lon":21,0000,
  // producing invalid JSON on every single event this server emits, and
  // GetJSON would fail to parse it back on the next replay. Every
  // number in this protocol is meant to be plain JSON regardless of
  // what machine it runs on, so the separator is pinned here before
  // anything else runs.
  DefaultFormatSettings.DecimalSeparator := '.';
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
  TechLock := TCriticalSection.Create;
  DiplomacyLock := TCriticalSection.Create;
  TechDefs := specialize TDictionary<string, TTechDef>.Create;
  TechOrder := TStringList.Create;
  ResearchedTech := specialize TDictionary<string, Boolean>.Create;
  ResearchInProgress := specialize TDictionary<string, TResearchInProgress>.Create;
  DiplomaticStatus := specialize TDictionary<string, string>.Create;
  PendingProposals := specialize TDictionary<string, Boolean>.Create;

  LogDiag('Loading bake_config.json ...');
  Config := LoadBakeConfig(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'bake_config.json');

  LogDiag('Loading game_balance.json ...');
  Balance := LoadGameBalance(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'game_balance.json');

  LogDiag('Loading ' + Config.MovementGridPath + ' ...');
  Grid := LoadMovementGrid(Config.MovementGridPath);
  LogDiag('Movement grid: ' + IntToStr(Grid.Width) + ' x ' + IntToStr(Grid.Height));

  LogDiag('Loading unit_types.json ...');
  LoadUnitTypes(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'unit_types.json');

  LogDiag('Loading tech.json ...');
  LoadTechDefs(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'tech.json');

  LogDiag('Loading ai_factions.json ...');
  LoadAiFactionConfigs(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'ai_factions.json', Balance);

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
    ProcessResearch;
    RunAllAI;
    if Tick mod Balance.DevelopmentUpdateTicks = 0 then
      RecomputeDevelopment;
    Sleep(50); // ~20 ticks/sec target loop pacing
  end;
end.
