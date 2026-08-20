program kyzu_server;
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
    GX, GY: Double; // fractional grid position, for smooth interpolated reporting
    Path: TGridPath;
    PathIndex: Integer; // index of the path node the unit is currently departing from
  end;

var
  OutputLock: TCriticalSection;
  UnitsLock: TCriticalSection;
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

function GridToLon(GX: Double): Double;
begin
  Result := -180.0 + GX * (360.0 / Grid.Width);
end;

function GridToLat(GY: Double): Double;
begin
  Result := 90.0 - GY * (180.0 / Grid.Height);
end;

procedure HandleSpawn(APayload: TJSONObject);
var
  UnitID: string;
  U: TUnit;
  GX, GY: Integer;
begin
  UnitID := APayload.Get('unit_id', '');
  if UnitID = '' then Exit;
  GX := APayload.Get('x', -1);
  GY := APayload.Get('y', -1);

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

  SendLine(Format('{"topic":"game.event.spawned","payload":"{\"unit_id\":\"%s\",\"lon\":%.4f,\"lat\":%.4f}"}',
    [UnitID, GridToLon(U.GX), GridToLat(U.GY)]));
end;

procedure HandleMove(APayload: TJSONObject);
var
  UnitID: string;
  U: TUnit;
  ToX, ToY, StartX, StartY: Integer;
  Path: TGridPath;
  Found: Boolean;
begin
  UnitID := APayload.Get('unit_id', '');

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

  ToX := APayload.Get('to_x', -1);
  ToY := APayload.Get('to_y', -1);
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

  SendLine(Format('{"topic":"game.event.path_found","payload":"{\"unit_id\":\"%s\",\"steps\":%d}"}',
    [UnitID, Length(Path)]));
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
      if U.PathIndex >= High(U.Path) then
      begin
        SetLength(U.Path, 0); // arrived - unit goes idle, stops generating traffic
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
begin
  Tick := 0;
  OutputLock := TCriticalSection.Create;
  UnitsLock := TCriticalSection.Create;
  Units := specialize TDictionary<string, TUnit>.Create;

  WriteLn(StdErr, 'Loading bake_config.json ...');
  Config := LoadBakeConfig(ExpandFileName(ExtractFilePath(ParamStr(0))) + 'bake_config.json');
  WriteLn(StdErr, 'Loading ', Config.MovementGridPath, ' ...');
  Grid := LoadMovementGrid(Config.MovementGridPath);
  WriteLn(StdErr, 'Movement grid: ', Grid.Width, ' x ', Grid.Height);

  // Grid/Config are read-only from here on, so it's safe to start the
  // reader thread only now - no window where it could race a concurrent
  // load.
  ReaderThread := TStdinReaderThread.Create(False); // starts immediately

  while True do
  begin
    Inc(Tick);
    SendLine(Format('{"topic":"game.tick","payload":"{\"tick\":%d}"}', [Tick]));
    AdvanceUnits;
    Sleep(50); // ~20 ticks/sec target loop pacing
  end;
end.
