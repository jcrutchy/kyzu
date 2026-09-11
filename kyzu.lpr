program kyzu;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, Math, SyncObjs, Generics.Collections, fpjson, jsonparser,
  kyzu_bakeconfig, kyzu_pathfinding,
  kyzu_types, kyzu_state, kyzu_loaders, kyzu_commands, kyzu_sim, kyzu_ai,
  kyzu_dispatch, kyzu_persist;

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

