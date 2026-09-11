unit kyzu_commands;

// One Handle* procedure per game.cmd.* topic (spawn/move/despawn/collect/
// found_city/build_road/attack/research/diplomacy/list_*), plus the
// small list-formatting helpers (HandleListNodes etc). This is what
// DispatchIncoming (kyzu_dispatch) routes a parsed command to, and what
// RunAI (kyzu_ai) calls directly to act on behalf of an AI faction -
// exactly the same entry points a real client command goes through,
// so AI factions can never do anything a client couldn't.

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, fpjson,
  kyzu_types, kyzu_state, kyzu_pathfinding, kyzu_bakeconfig;

procedure HandleListNodes;
procedure HandleSpawn(APayload: TJSONObject);
procedure HandleDespawn(APayload: TJSONObject);
procedure HandleMove(APayload: TJSONObject);
procedure HandleCollect(APayload: TJSONObject);
procedure HandleGetLedger(APayload: TJSONObject);
procedure HandleFoundCity(APayload: TJSONObject);
procedure HandleBuildRoad(APayload: TJSONObject);
procedure HandleAttack(APayload: TJSONObject);
procedure HandleStartResearch(APayload: TJSONObject);
procedure HandleListCities;
procedure HandleListRoads;
procedure HandleGetDevelopment;
procedure HandleListTechDefs;
procedure HandleGetTech(APayload: TJSONObject);
procedure HandleGetDiplomacy(APayload: TJSONObject);
procedure HandleDeclareWar(APayload: TJSONObject);
procedure HandleProposeAlliance(APayload: TJSONObject);
procedure HandleAcceptAlliance(APayload: TJSONObject);
procedure HandleBreakAlliance(APayload: TJSONObject);
procedure HandleProposePeace(APayload: TJSONObject);
procedure HandleAcceptPeace(APayload: TJSONObject);

implementation

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

  SendLine(MakeEventLine('game.event.ledger', '{"owner":' + JsonQuote(Actor) + ',"totals":' + TotalsJSON + '}'));
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
  SendLine(MakeEventLine('game.event.development_snapshot', '{"cells":' + ListJSON + '}'));
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

end.
