program kyzu_logger;

{$mode objfpc}{$H+}

// kyzu_logger - a standalone VDRX-supervised process with exactly one
// job: turn kyzu's live game.event.*/game.tick stream into a
// permanent, indexed, queryable history. It has no relationship to
// kyzu.lpr beyond being another bus subscriber (same principle the
// web dashboard's own comment makes about itself) - it could run on a
// different machine entirely, and kyzu never knows it exists.
//
// Two tables, two different jobs:
//   events            - every event, verbatim, forever. Full fidelity,
//                        indexed by topic/owner/tick, the source of
//                        truth for anything not covered below.
//   faction_snapshots - one row per faction every SNAPSHOT_EVERY_TICKS
//                        ticks, with population/unit/city/combat
//                        figures already computed. This is what makes
//                        "population over time" or "kills per hour" a
//                        cheap indexed range query instead of an
//                        aggregation over however many million raw
//                        rows have accumulated by then.
//
// The world model kept in memory here (Units/Cities/Stats) is the
// same shape of thing web/dashboard/kyzu_dashboard.html rebuilds in
// JS from the same event stream - this is the same logic, in Pascal,
// persisted instead of thrown away on tab close.
//
// Wire format in is identical to what kyzu.lpr itself emits (see
// KYZU_VDRX_API.md "The bus envelope"): one JSON object per line,
// {"topic":"...","payload":"...json-encoded string..."} - payload is
// a STRING containing escaped JSON, not a nested object, so every
// event needs a second parse pass. To subscribe, add this to
// kyzu.vdrx.conf's "processes" array:
//
//   {
//     "id": "kyzu_logger",
//     "command": "C:/dev/kyzu/kyzu_logger.exe",
//     "restart": "always",
//     "graceful_timeout_ms": 5000,
//     "subscribe": ["game.event.>", "game.tick"],
//     "publish": [],
//     "prefix": "", "host": "", "port": "",
//     "enabled": true
//   }
//
// DB path: ParamStr(1) if given, else kyzu_events.sqlite3 next to this
// executable.

uses
  SysUtils, Classes, DateUtils, Generics.Collections, fpjson, jsonparser, sqlite3dyn;

const
  // ~20 ticks/sec is kyzu's own cadence (see KYZU_VDRX_API.md) - these
  // are chosen relative to that, not to wall-clock time, so they track
  // correctly even if kyzu's tick rate is ever retuned.
  COMMIT_EVERY_TICKS = 20;    // ~1 SQLite commit/sec - batches writes so a busy multi-faction stream doesn't turn into one fsync per row
  SNAPSHOT_EVERY_TICKS = 100; // ~1 faction snapshot round every 5 sec

type
  TLoggerUnit = record
    Owner: string;
    UnitType: string;
    Level: Integer;
  end;

  TLoggerCity = record
    Owner: string;
    Population: Integer;
  end;

  // Running totals that, unlike population/unit-count, have no
  // "current value" derivable from Units/Cities alone - a kill or a
  // capture is an event that happened, not a state to inspect. Same
  // reasoning the JS dashboard's own `stats` map comment gives.
  TFactionStats = record
    Kills, Deaths: Integer;
    CitiesFounded, CitiesCaptured, CitiesLost: Integer;
    VeteranLevelUps: Integer;
    TechsResearched: Integer;
  end;

var
  DB: psqlite3;
  InsertEventStmt: psqlite3_stmt;
  InsertSnapshotStmt: psqlite3_stmt;
  CurrentTick: Int64;
  LastCommitTick: Int64;
  LastSnapshotTick: Int64;
  InTransaction: Boolean;
  EventCount: Int64;

  Units: specialize TDictionary<string, TLoggerUnit>;
  Cities: specialize TDictionary<string, TLoggerCity>;
  Stats: specialize TDictionary<string, TFactionStats>;
  // A kill needs correlating two events (the hit that reduced HP to 0,
  // and the despawn that follows it) - same two-step credit-tracking
  // the JS dashboard does, held here just long enough to bridge them.
  PendingKillCredit: specialize TDictionary<string, string>;

procedure LogDiag(const AMsg: string);
begin
  WriteLn(StdErr, AMsg);
  Flush(StdErr);
end;

procedure ExecOrDie(const ASQL: string);
var
  ErrMsg: pansichar;
begin
  ErrMsg := nil;
  if sqlite3_exec(DB, pansichar(ASQL), nil, nil, @ErrMsg) <> SQLITE_OK then
  begin
    LogDiag('SQLite error executing "' + ASQL + '": ' + string(ErrMsg));
    sqlite3_free(pointer(ErrMsg));
    Halt(1);
  end;
end;

// Every text bind uses SQLITE_TRANSIENT - sqlite3 makes its own copy
// of the bytes immediately rather than holding a pointer into our
// (Pascal-managed, about-to-be-reused) string buffer. Costs a copy per
// bind; at this event rate that's noise next to the surrounding JSON
// parsing.
procedure BindText(Stmt: psqlite3_stmt; N: Integer; const V: string);
begin
  sqlite3_bind_text(Stmt, N, pansichar(V), Length(V), sqlite3_destructor_type(SQLITE_TRANSIENT));
end;

procedure OpenDatabase(const APath: string);
var
  Loaded: Boolean;
begin
  // The default (empty LibraryName -> platform default, "sqlite3.dll" on
  // Windows) is tried first; the fallbacks only matter on Linux
  // installs that have the runtime .so.0 but not the -dev package's
  // unversioned "libsqlite3.so" symlink InitializeSqlite's default
  // name expects.
  Loaded := TryInitializeSqlite() >= 0;
  if not Loaded then Loaded := TryInitializeSqlite('libsqlite3.so.0') >= 0;
  if not Loaded then Loaded := TryInitializeSqlite('libsqlite3.so') >= 0;
  if not Loaded then
  begin
    LogDiag('Could not load the SQLite3 library under any known name - is it installed?');
    Halt(1);
  end;

  if sqlite3_open(pansichar(APath), @DB) <> SQLITE_OK then
  begin
    LogDiag('Could not open ' + APath + ': ' + string(sqlite3_errmsg(DB)));
    Halt(1);
  end;

  // WAL + NORMAL synchronous: this process is the only writer, so the
  // durability WAL trades away (a very small window of loss on a hard
  // crash, not corruption) is an easy trade for the write throughput a
  // live multi-faction event stream needs. A dashboard/report process
  // reading the same file concurrently is exactly WAL's other benefit
  // - readers never block on this process's writes.
  ExecOrDie('PRAGMA journal_mode=WAL;');
  ExecOrDie('PRAGMA synchronous=NORMAL;');

  ExecOrDie(
    'CREATE TABLE IF NOT EXISTS events (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  ts INTEGER NOT NULL,' +      // unix epoch seconds when this logger received it
    '  tick INTEGER NOT NULL,' +    // most recent game.tick value known at receipt time
    '  topic TEXT NOT NULL,' +
    '  owner TEXT NOT NULL,' +
    '  payload TEXT NOT NULL' +
    ');'
  );
  ExecOrDie('CREATE INDEX IF NOT EXISTS idx_events_topic ON events(topic);');
  ExecOrDie('CREATE INDEX IF NOT EXISTS idx_events_owner ON events(owner);');
  ExecOrDie('CREATE INDEX IF NOT EXISTS idx_events_tick ON events(tick);');

  ExecOrDie(
    'CREATE TABLE IF NOT EXISTS faction_snapshots (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  ts INTEGER NOT NULL,' +
    '  tick INTEGER NOT NULL,' +
    '  faction TEXT NOT NULL,' +
    '  population INTEGER NOT NULL,' +
    '  city_count INTEGER NOT NULL,' +
    '  unit_count INTEGER NOT NULL,' +
    '  max_level INTEGER NOT NULL,' +
    '  kills INTEGER NOT NULL,' +
    '  deaths INTEGER NOT NULL,' +
    '  cities_founded INTEGER NOT NULL,' +
    '  cities_captured INTEGER NOT NULL,' +
    '  cities_lost INTEGER NOT NULL,' +
    '  veteran_level_ups INTEGER NOT NULL,' +
    '  techs_researched INTEGER NOT NULL' +
    ');'
  );
  ExecOrDie('CREATE INDEX IF NOT EXISTS idx_snapshots_faction_tick ON faction_snapshots(faction, tick);');
  ExecOrDie('CREATE INDEX IF NOT EXISTS idx_snapshots_tick ON faction_snapshots(tick);');

  LogDiag('Opened ' + APath + ' (SQLite ' + string(sqlite3_libversion()) + ').');
end;

procedure PrepareStatements;
begin
  if sqlite3_prepare_v2(DB,
    'INSERT INTO events (ts, tick, topic, owner, payload) VALUES (?, ?, ?, ?, ?);',
    -1, @InsertEventStmt, nil) <> SQLITE_OK then
  begin
    LogDiag('Failed to prepare the event insert statement: ' + string(sqlite3_errmsg(DB)));
    Halt(1);
  end;

  if sqlite3_prepare_v2(DB,
    'INSERT INTO faction_snapshots (ts, tick, faction, population, city_count, unit_count, ' +
    'max_level, kills, deaths, cities_founded, cities_captured, cities_lost, veteran_level_ups, techs_researched) ' +
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    -1, @InsertSnapshotStmt, nil) <> SQLITE_OK then
  begin
    LogDiag('Failed to prepare the snapshot insert statement: ' + string(sqlite3_errmsg(DB)));
    Halt(1);
  end;
end;

procedure BeginTxnIfNeeded;
begin
  if not InTransaction then
  begin
    ExecOrDie('BEGIN;');
    InTransaction := True;
  end;
end;

procedure CommitTxn;
begin
  if InTransaction then
  begin
    ExecOrDie('COMMIT;');
    InTransaction := False;
  end;
end;

procedure InsertEventRow(const ATopic, AOwner, APayloadJSON: string);
begin
  BeginTxnIfNeeded;
  sqlite3_reset(InsertEventStmt);
  sqlite3_bind_int64(InsertEventStmt, 1, DateTimeToUnix(Now));
  sqlite3_bind_int64(InsertEventStmt, 2, CurrentTick);
  BindText(InsertEventStmt, 3, ATopic);
  BindText(InsertEventStmt, 4, AOwner);
  BindText(InsertEventStmt, 5, APayloadJSON);
  if sqlite3_step(InsertEventStmt) <> SQLITE_DONE then
    LogDiag('Failed to insert event row for ' + ATopic + ': ' + string(sqlite3_errmsg(DB)));
  Inc(EventCount);
end;

function GetOrCreateStats(const AFaction: string): TFactionStats;
begin
  if not Stats.TryGetValue(AFaction, Result) then
  begin
    FillChar(Result, SizeOf(Result), 0);
    Stats.AddOrSetValue(AFaction, Result);
  end;
end;

procedure InsertSnapshotRow(const AFaction: string; APopulation, ACityCount, AUnitCount, AMaxLevel: Integer;
  const AStats: TFactionStats);
begin
  BeginTxnIfNeeded;
  sqlite3_reset(InsertSnapshotStmt);
  sqlite3_bind_int64(InsertSnapshotStmt, 1, DateTimeToUnix(Now));
  sqlite3_bind_int64(InsertSnapshotStmt, 2, CurrentTick);
  BindText(InsertSnapshotStmt, 3, AFaction);
  sqlite3_bind_int64(InsertSnapshotStmt, 4, APopulation);
  sqlite3_bind_int64(InsertSnapshotStmt, 5, ACityCount);
  sqlite3_bind_int64(InsertSnapshotStmt, 6, AUnitCount);
  sqlite3_bind_int64(InsertSnapshotStmt, 7, AMaxLevel);
  sqlite3_bind_int64(InsertSnapshotStmt, 8, AStats.Kills);
  sqlite3_bind_int64(InsertSnapshotStmt, 9, AStats.Deaths);
  sqlite3_bind_int64(InsertSnapshotStmt, 10, AStats.CitiesFounded);
  sqlite3_bind_int64(InsertSnapshotStmt, 11, AStats.CitiesCaptured);
  sqlite3_bind_int64(InsertSnapshotStmt, 12, AStats.CitiesLost);
  sqlite3_bind_int64(InsertSnapshotStmt, 13, AStats.VeteranLevelUps);
  sqlite3_bind_int64(InsertSnapshotStmt, 14, AStats.TechsResearched);
  if sqlite3_step(InsertSnapshotStmt) <> SQLITE_DONE then
    LogDiag('Failed to insert snapshot row for ' + AFaction + ': ' + string(sqlite3_errmsg(DB)));
end;

// Every faction that currently owns at least one unit or city gets a
// row, even one with all-zero combat stats - a faction with a city but
// no recorded kills yet is still a real data point ("this faction
// existed with this population at this tick"), not something to skip.
procedure TakeSnapshot;
var
  FactionNames: specialize TDictionary<string, Boolean>; // used as a set - value is never read, only key presence
  U: TLoggerUnit;
  C: TLoggerCity;
  Faction: string;
  Population, CityCount, UnitCount, MaxLevel: Integer;
  S: TFactionStats;
begin
  FactionNames := specialize TDictionary<string, Boolean>.Create;
  try
    for U in Units.Values do
      if U.Owner <> '' then FactionNames.AddOrSetValue(U.Owner, True);
    for C in Cities.Values do
      if C.Owner <> '' then FactionNames.AddOrSetValue(C.Owner, True);
    for Faction in Stats.Keys do
      if Faction <> '' then FactionNames.AddOrSetValue(Faction, True);

    for Faction in FactionNames.Keys do
    begin
      Population := 0; CityCount := 0; UnitCount := 0; MaxLevel := 0;
      for C in Cities.Values do
        if C.Owner = Faction then
        begin
          Inc(Population, C.Population);
          Inc(CityCount);
        end;
      for U in Units.Values do
        if U.Owner = Faction then
        begin
          Inc(UnitCount);
          if U.Level > MaxLevel then MaxLevel := U.Level;
        end;

      S := GetOrCreateStats(Faction);
      InsertSnapshotRow(Faction, Population, CityCount, UnitCount, MaxLevel, S);
    end;
  finally
    FactionNames.Free;
  end;
end;

// Pulls whichever field actually identifies "who this event is about"
// for a given topic, so the events table's owner column stays useful
// for per-faction filtering without needing a topic-specific query
// every time. Falls back to '' for topics that don't carry one
// (despawned, road_built/removed) - HandleTopic below fills in
// despawned's owner from the Units map BEFORE this is called, since
// that lookup needs the unit to still be in Units.
function ExtractOwner(const APayload: TJSONObject): string;
begin
  Result := APayload.Get('owner', '');
  if Result = '' then Result := APayload.Get('new_owner', '');
  if Result = '' then Result := APayload.Get('by', '');
  if Result = '' then Result := APayload.Get('previous_owner', '');
end;

procedure HandleTopic(const ATopic: string; const APayload: TJSONObject);
var
  Owner, UnitID, TargetUnitID, CityID, Credit: string;
  U, TargetU: TLoggerUnit;
  C: TLoggerCity;
  S: TFactionStats;
  Found: Boolean;
begin
  Owner := ExtractOwner(APayload);

  // --- world-model maintenance, mirroring web/dashboard/kyzu_dashboard.html's own switch ---
  if ATopic = 'game.event.spawned' then
  begin
    U.Owner := APayload.Get('owner', '');
    U.UnitType := APayload.Get('unit_type', 'generic');
    U.Level := 0;
    Units.AddOrSetValue(APayload.Get('unit_id', ''), U);
  end
  else if ATopic = 'game.event.despawned' then
  begin
    UnitID := APayload.Get('unit_id', '');
    Found := Units.TryGetValue(UnitID, U);
    if Found then Owner := U.Owner; // despawned carries no owner of its own - recover it before it's gone
    if PendingKillCredit.TryGetValue(UnitID, Credit) then
    begin
      S := GetOrCreateStats(Credit);
      Inc(S.Kills);
      Stats.AddOrSetValue(Credit, S);
      if Found then
      begin
        S := GetOrCreateStats(U.Owner);
        Inc(S.Deaths);
        Stats.AddOrSetValue(U.Owner, S);
      end;
      PendingKillCredit.Remove(UnitID);
    end;
    Units.Remove(UnitID);
  end
  else if ATopic = 'game.event.unit_attacked' then
  begin
    if APayload.Get('remaining_hp', -1) = 0 then
      PendingKillCredit.AddOrSetValue(APayload.Get('target_unit_id', ''), APayload.Get('by', ''));
    TargetUnitID := APayload.Get('attacker_unit_id', '');
    if Units.TryGetValue(TargetUnitID, TargetU) and APayload.Find('attacker_level').IsNull = False then
    begin
      TargetU.Level := APayload.Get('attacker_level', TargetU.Level);
      Units.AddOrSetValue(TargetUnitID, TargetU);
    end;
  end
  else if ATopic = 'game.event.unit_leveled_up' then
  begin
    UnitID := APayload.Get('unit_id', '');
    if Units.TryGetValue(UnitID, U) then
    begin
      U.Level := APayload.Get('level', U.Level);
      Units.AddOrSetValue(UnitID, U);
      S := GetOrCreateStats(U.Owner);
      Inc(S.VeteranLevelUps);
      Stats.AddOrSetValue(U.Owner, S);
    end;
  end
  else if ATopic = 'game.event.city_founded' then
  begin
    C.Owner := APayload.Get('owner', '');
    C.Population := APayload.Get('population', 0);
    Cities.AddOrSetValue(APayload.Get('city_id', ''), C);
    S := GetOrCreateStats(C.Owner);
    Inc(S.CitiesFounded);
    Stats.AddOrSetValue(C.Owner, S);
  end
  else if ATopic = 'game.event.city_grew' then
  begin
    CityID := APayload.Get('city_id', '');
    if Cities.TryGetValue(CityID, C) then
    begin
      C.Population := APayload.Get('population', C.Population);
      Cities.AddOrSetValue(CityID, C);
      Owner := C.Owner;
    end;
  end
  else if ATopic = 'game.event.city_population_decayed' then
  begin
    CityID := APayload.Get('city_id', '');
    if Cities.TryGetValue(CityID, C) then
    begin
      C.Population := APayload.Get('population', C.Population);
      Cities.AddOrSetValue(CityID, C);
      Owner := C.Owner;
    end;
  end
  else if ATopic = 'game.event.city_captured' then
  begin
    CityID := APayload.Get('city_id', '');
    Cities.TryGetValue(CityID, C); // fine if this is the first we've heard of it (missed city_founded before this logger started)
    C.Owner := APayload.Get('new_owner', '');
    C.Population := APayload.Get('population', 0);
    Cities.AddOrSetValue(CityID, C);
    S := GetOrCreateStats(APayload.Get('new_owner', ''));
    Inc(S.CitiesCaptured);
    Stats.AddOrSetValue(APayload.Get('new_owner', ''), S);
    S := GetOrCreateStats(APayload.Get('previous_owner', ''));
    Inc(S.CitiesLost);
    Stats.AddOrSetValue(APayload.Get('previous_owner', ''), S);
  end
  else if ATopic = 'game.event.city_abandoned' then
  begin
    CityID := APayload.Get('city_id', '');
    if Cities.TryGetValue(CityID, C) then
    begin
      S := GetOrCreateStats(C.Owner);
      Inc(S.CitiesLost);
      Stats.AddOrSetValue(C.Owner, S);
      Owner := C.Owner;
    end;
    Cities.Remove(CityID);
  end
  else if ATopic = 'game.event.research_completed' then
  begin
    S := GetOrCreateStats(Owner);
    Inc(S.TechsResearched);
    Stats.AddOrSetValue(Owner, S);
  end;
  // collected/city_attacked/road_built/road_removed/diplomacy_*/
  // research_started/research_failed/research_cost_spent carry
  // nothing the snapshot table needs beyond what ExtractOwner already
  // pulled - they're still fully captured in the raw events row below,
  // just without a world-model update here.

  InsertEventRow(ATopic, Owner, APayload.AsJSON);
end;

procedure HandleLine(const ALine: string);
var
  Data: TJSONData;
  Obj: TJSONObject;
  Topic: string;
  PayloadRaw: TJSONData;
  PayloadObj: TJSONObject;
begin
  if Trim(ALine) = '' then Exit;

  try
    Data := GetJSON(ALine);
  except
    Exit; // a stray non-JSON line on stdin is ignored, not fatal
  end;

  try
    if Data.JSONType <> jtObject then Exit;
    Obj := TJSONObject(Data);
    Topic := Obj.Get('topic', '');
    if Topic = '' then Exit;

    if Topic = 'game.tick' then
    begin
      // payload here is ALSO a JSON-encoded string, same envelope as
      // everything else - never itself written to the events table
      // (it would dwarf every other topic combined at ~20/sec forever),
      // just used to keep CurrentTick current for whatever's inserted
      // next, and to drive the commit/snapshot cadence below.
      try
        PayloadRaw := GetJSON(Obj.Get('payload', '{}'));
        try
          if PayloadRaw.JSONType = jtObject then
            CurrentTick := TJSONObject(PayloadRaw).Get('tick', CurrentTick);
        finally
          PayloadRaw.Free;
        end;
      except
        // malformed tick payload - keep the last known CurrentTick rather than fail the process over it
      end;

      if CurrentTick - LastCommitTick >= COMMIT_EVERY_TICKS then
      begin
        CommitTxn;
        LastCommitTick := CurrentTick;
      end;
      if CurrentTick - LastSnapshotTick >= SNAPSHOT_EVERY_TICKS then
      begin
        BeginTxnIfNeeded;
        TakeSnapshot;
        LastSnapshotTick := CurrentTick;
      end;
      Exit;
    end;

    if Pos('game.event.', Topic) <> 1 then Exit; // not something we track

    try
      PayloadRaw := GetJSON(Obj.Get('payload', '{}'));
    except
      Exit; // malformed inner payload - drop just this one event, not the process
    end;
    try
      if PayloadRaw.JSONType <> jtObject then Exit;
      PayloadObj := TJSONObject(PayloadRaw);
      HandleTopic(Topic, PayloadObj);
    finally
      PayloadRaw.Free;
    end;
  finally
    Data.Free;
  end;
end;

var
  DBPath, Line: string;

begin
  if ParamCount >= 1 then
    DBPath := ParamStr(1)
  else
    DBPath := ExpandFileName(ExtractFilePath(ParamStr(0))) + 'kyzu_events.sqlite3';

  Units := specialize TDictionary<string, TLoggerUnit>.Create;
  Cities := specialize TDictionary<string, TLoggerCity>.Create;
  Stats := specialize TDictionary<string, TFactionStats>.Create;
  PendingKillCredit := specialize TDictionary<string, string>.Create;

  CurrentTick := 0;
  LastCommitTick := 0;
  LastSnapshotTick := 0;
  InTransaction := False;
  EventCount := 0;

  OpenDatabase(DBPath);
  PrepareStatements;
  LogDiag('kyzu_logger ready, writing to ' + DBPath);

  while not Eof(Input) do
  begin
    ReadLn(Input, Line);
    try
      HandleLine(Line);
    except
      on E: Exception do
        LogDiag('Error handling line (' + E.ClassName + ': ' + E.Message + '): ' + Copy(Line, 1, 200));
    end;
  end;

  // stdin closed - VDRX is stopping us (same shutdown signal kyzu.lpr's
  // own TStdinReaderThread relies on). Flush whatever's still pending
  // rather than losing the last partial batch.
  CommitTxn;
  sqlite3_finalize(InsertEventStmt);
  sqlite3_finalize(InsertSnapshotStmt);
  sqlite3_close(DB);
  ReleaseSqlite;
  LogDiag('kyzu_logger shutting down after ' + IntToStr(EventCount) + ' events.');
end.

