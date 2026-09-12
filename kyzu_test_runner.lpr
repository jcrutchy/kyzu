program kyzu_test_runner;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Generics.Collections, fpjson, jsonparser, Process;

type
  TEventStats = record
    Spawned: specialize TDictionary<string, Boolean>;
    Despawned: specialize TDictionary<string, Boolean>;
    EventCounts: specialize TDictionary<string, Integer>;
  end;

procedure Usage;
begin
  WriteLn('KYZU FPC test/diagnostic runner');
  WriteLn;
  WriteLn('  kyzu_test_runner --startup <kyzu> <workdir>');
  WriteLn('      Run KyzU startup self-tests using the exact live binary.');
  WriteLn;
  WriteLn('  kyzu_test_runner --analyse <events.jsonl>');
  WriteLn('      Analyse event history and report lifecycle anomalies.');
end;

function RunStartup(const ABinary, AWorkDir: string): Integer;
var
  P: TProcess;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := ExpandFileName(ABinary);
    P.CurrentDirectory := ExpandFileName(AWorkDir);
    P.Parameters.Add('--self-test');
    P.Options := [poWaitOnExit];
    WriteLn('KYZU REGRESSION');
    WriteLn('  Binary: ', P.Executable);
    WriteLn('  Workdir: ', P.CurrentDirectory);
    WriteLn('  Mode: startup self-test');
    P.Execute;
    Result := P.ExitStatus;
    if Result = 0 then
      WriteLn('PASS: startup regression suite')
    else
      WriteLn('FAIL: startup regression suite (exit code ', Result, ')');
  finally
    P.Free;
  end;
end;

procedure IncCount(var AStats: TEventStats; const AType: string);
var
  N: Integer;
begin
  N := 0;
  AStats.EventCounts.TryGetValue(AType, N);
  AStats.EventCounts.AddOrSetValue(AType, N + 1);
end;

procedure AnalyseLog(const AFilename: string);
var
  F: TextFile;
  Line, EventType, UnitID: string;
  Data: TJSONData;
  Obj: TJSONObject;
  Stats: TEventStats;
  Pair: specialize TPair<string, Integer>;
  EventTotal, Malformed: Integer;
  PathFound, Waypoint, Arrived, Position: Integer;
  SpawnedCount, DespawnedCount: Integer;
  AliveCount: Integer;
  PairBool: specialize TPair<string, Boolean>;
begin
  Stats.Spawned := specialize TDictionary<string, Boolean>.Create;
  Stats.Despawned := specialize TDictionary<string, Boolean>.Create;
  Stats.EventCounts := specialize TDictionary<string, Integer>.Create;
  EventTotal := 0;
  Malformed := 0;
  try
    if not FileExists(AFilename) then
      raise Exception.Create('event log not found: ' + AFilename);

    AssignFile(F, AFilename);
    Reset(F);
    try
      while not Eof(F) do
      begin
        ReadLn(F, Line);
        if Trim(Line) = '' then Continue;
        Inc(EventTotal);
        try
          Data := GetJSON(Line);
        except
          Inc(Malformed);
          Continue;
        end;
        try
          if Data.JSONType <> jtObject then
          begin
            Inc(Malformed);
            Continue;
          end;
          Obj := TJSONObject(Data);
          EventType := Obj.Get('type', '');
          IncCount(Stats, EventType);
          UnitID := Obj.Get('unit_id', '');
          if EventType = 'spawned' then
            Stats.Spawned.AddOrSetValue(UnitID, True)
          else if EventType = 'despawned' then
            Stats.Despawned.AddOrSetValue(UnitID, True);
        finally
          Data.Free;
        end;
      end;
    finally
      CloseFile(F);
    end;

    SpawnedCount := Stats.Spawned.Count;
    DespawnedCount := Stats.Despawned.Count;
    AliveCount := 0;
    for PairBool in Stats.Spawned do
      if not Stats.Despawned.ContainsKey(PairBool.Key) then
        Inc(AliveCount);

    PathFound := 0; Stats.EventCounts.TryGetValue('path_found', PathFound);
    Waypoint := 0; Stats.EventCounts.TryGetValue('waypoint', Waypoint);
    Arrived := 0; Stats.EventCounts.TryGetValue('arrived', Arrived);
    Position := 0; Stats.EventCounts.TryGetValue('position', Position);

    WriteLn('KYZU EVENT LOG DIAGNOSTIC');
    WriteLn('  Events: ', EventTotal);
    WriteLn('  Malformed lines: ', Malformed);
    WriteLn('  Spawned units: ', SpawnedCount);
    WriteLn('  Despawned units: ', DespawnedCount);
    WriteLn('  Currently alive by lifecycle: ', AliveCount);
    WriteLn('');
    WriteLn('Movement pipeline:');
    WriteLn('  path_found: ', PathFound);
    WriteLn('  waypoint:   ', Waypoint);
    WriteLn('  arrived:    ', Arrived);
    WriteLn('  position:   ', Position);
    if Position = 0 then
      WriteLn('  WARNING: no persisted position events were found. This is worth checking against the live VDRX stream.');
    if (Arrived > PathFound) then
      WriteLn('  WARNING: more arrived events than path_found events.');
    if (Malformed > 0) then
      WriteLn('  WARNING: malformed JSONL lines were skipped.');

    WriteLn('');
    WriteLn('Event counts:');
    for Pair in Stats.EventCounts do
      WriteLn('  ', Pair.Key, ': ', Pair.Value);
  finally
    Stats.Spawned.Free;
    Stats.Despawned.Free;
    Stats.EventCounts.Free;
  end;
end;

var
  Mode: string;
begin
  try
    if ParamCount < 1 then
    begin
      Usage;
      Halt(2);
    end;

    Mode := ParamStr(1);
    if SameText(Mode, '--startup') then
    begin
      if ParamCount < 3 then
      begin
        Usage;
        Halt(2);
      end;
      Halt(RunStartup(ParamStr(2), ParamStr(3)));
    end
    else if SameText(Mode, '--analyse') then
    begin
      if ParamCount < 2 then
      begin
        Usage;
        Halt(2);
      end;
      AnalyseLog(ParamStr(2));
      Halt(0);
    end
    else
    begin
      Usage;
      Halt(2);
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.

