unit kyzu_state;

// Shared mutable world state (Units/Cities/Nodes/Ledger/Roads/Density/
// UnitDefs/Balance/Grid/Config/Tick/tech & diplomacy tables) plus the
// small stateless-ish helpers that operate directly on it: logging/
// output, lon-lat<->grid conversion, wrapped-distance math, unit-def
// lookup, diplomacy/tech/territory queries, resource-cost math, and the
// two JSON wire-format helpers (JsonQuote/MakeEventLine). Every lock is
// declared here alongside the dictionary it guards - see each lock's own
// original comment (carried over below) for why. This is the one shared
// substrate every other kyzu_* unit imports; it must never import any of
// them back.

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, SyncObjs, Generics.Collections, fpjson,
  kyzu_types, kyzu_bakeconfig, kyzu_pathfinding;


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

procedure LogDiag(const AMsg: string);
procedure SendLine(const ALine: string);
function JsonQuote(const S: string): string;
function MakeEventLine(const ATopic, APayloadJSON: string): string;
procedure LogEvent(const AJSON: string);
function GridToLon(GX: Double): Double;
function GridToLat(GY: Double): Double;
function LonToGridX(Lon: Double): Integer;
function LatToGridY(Lat: Double): Integer;
function TryLonToGridX(Lon: Double; out GX: Integer): Boolean;
function TryLatToGridY(Lat: Double; out GY: Integer): Boolean;
function WrappedDX(AX1, AX2: Double): Double;
function WrappedDistance(AX1, AY1, AX2, AY2: Double): Double;
function DensityKey(GX, GY: Integer): string;
function DefaultUnitDef: TUnitDef;
function GetUnitDef(const AUnitType: string): TUnitDef;
function ParseResourceCostList(AArr: TJSONArray): TResourceCostList;
function BuildPathJSON(const APath: TGridPath): string;
function DiplomacyKey(const A, B: string): string;
function GetDiplomaticStatus(const A, B: string): string;
procedure SetDiplomaticStatus(const A, B, AStatus: string);
function HasResearched(const AOwner, ATechID: string): Boolean;
function TechPrereqsMet(const AOwner: string; const ADef: TTechDef): Boolean;
function GetTerritoryOwner(GX, GY: Integer): string;
function CanAffordCost(const AOwner: string; const ACosts: TResourceCostList): Boolean;
procedure DeductCost(const AOwner: string; const ACosts: TResourceCostList);
function CostsToJSON(const ACosts: TResourceCostList): string;
function IsCityRoadConnected(const ACityID, AOwner: string): Boolean;
function RoadExistsBetween(const ACityID1, ACityID2: string): Boolean;

implementation

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

end.
