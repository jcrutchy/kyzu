program kyzu;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpjson, jsonparser,
  kyzu_bakeconfig, kyzu_pathfinding;

const
  // Grid cells per tick at move_cost=1.0 - first-pass tuning value, same
  // spirit as the move_cost numbers themselves: adjust once actual
  // gameplay pacing is something to judge against, not before.
  BaseSpeed = 0.15;

type
  TUnit = record
    ID: string;
    Owner: string;      // faction/player id, '' = unowned
    UnitType: string;   // free-form for now (default 'generic') - no stats system yet
    GX, GY: Double; // fractional grid position, for smooth interpolated reporting
    Path: TGridPath;
    PathIndex: Integer; // index of the path node the unit is currently departing from
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
  EventLogLock: TCriticalSection;
  EventLogFile: TextFile;
  Units: specialize TDictionary<string, TUnit>;
  Grid: TMovementGrid;
  Config: TBakeConfig;

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

  UnitsLock.Enter;
  try
    Units.AddOrSetValue(UnitID, U);
  finally
    UnitsLock.Leave;
  end;

  LogEvent(Format('{"type":"spawned","unit_id":"%s","owner":"%s","unit_type":"%s","lon":%.4f,"lat":%.4f}',
    [UnitID, U.Owner, U.UnitType, GridToLon(U.GX), GridToLat(U.GY)]));
  SendLine(Format('{"topic":"game.event.spawned","payload":"{\"unit_id\":\"%s\",\"owner\":\"%s\",\"unit_type\":\"%s\",\"lon\":%.4f,\"lat\":%.4f}"}',
    [UnitID, U.Owner, U.UnitType, GridToLon(U.GX), GridToLat(U.GY)]));
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
    MoveAmount := BaseSpeed / StepCost;

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
  Line, EventType, UnitID: string;
  Data: TJSONData;
  Obj: TJSONObject;
  U: TUnit;
  Lon, Lat: Double;
  PathArr, PointArr: TJSONArray;
  GridPath: TGridPath;
  i, PathIdx, EventCount: Integer;
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
        UnitID := Obj.Get('unit_id', '');
        if UnitID = '' then Continue;

        if EventType = 'spawned' then
        begin
          Lon := Obj.Get('lon', 0.0);
          Lat := Obj.Get('lat', 0.0);
          U.ID := UnitID;
          U.Owner := Obj.Get('owner', '');
          U.UnitType := Obj.Get('unit_type', 'generic');
          U.GX := LonToGridX(Lon) + 0.5;
          U.GY := LatToGridY(Lat) + 0.5;
          SetLength(U.Path, 0);
          U.PathIndex := 0;
          Units.AddOrSetValue(UnitID, U);
        end
        else if EventType = 'path_found' then
        begin
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
          if Units.TryGetValue(UnitID, U) then
          begin
            SetLength(U.Path, 0);
            Units.AddOrSetValue(UnitID, U);
          end;
        end
        else if EventType = 'despawned' then
        begin
          Units.Remove(UnitID);
        end;

        Inc(EventCount);
      finally
        Data.Free;
      end;
    end;
  finally
    CloseFile(F);
  end;

  LogDiag('Replayed ' + IntToStr(EventCount) + ' events - ' + IntToStr(Units.Count) + ' units restored.');
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
  Tick: Int64;
  EventLogPath: string;
  EventLogExisted: Boolean;

begin
  Tick := 0;
  OutputLock := TCriticalSection.Create;
  UnitsLock := TCriticalSection.Create;
  EventLogLock := TCriticalSection.Create;
  Units := specialize TDictionary<string, TUnit>.Create;

  LogDiag('Loading bake_config.json ...');
  Config := LoadBakeConfig(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'bake_config.json');

  LogDiag('Loading ' + Config.MovementGridPath + ' ...');
  Grid := LoadMovementGrid(Config.MovementGridPath);
  LogDiag('Movement grid: ' + IntToStr(Grid.Width) + ' x ' + IntToStr(Grid.Height));

  EventLogPath := ExpandFileName(ExtractFilePath(ParamStr(0))) + 'events.jsonl';
  LogDiag('Event log: ' + EventLogPath);
  EventLogExisted := FileExists(EventLogPath);
  ReplayEventLog(EventLogPath);

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
    Sleep(50); // ~20 ticks/sec target loop pacing
  end;
end.
