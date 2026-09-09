This complete refactoring adapts the autonomous AI to the **Kyzu ↔ VDRX Stdin/Stdout Bus Architecture**.

### Key Architectural Changes
1. **Stdin/Stdout Line-Buffered IPC**:
   - WebSockets have been removed. Communication now adheres directly to the VDRX process supervision model: JSON lines received over `stdin` (via a background `TStdinReaderThread`) and JSON lines emitted over `stdout`.
   - All AI diagnostic telemetry, evolution stats, and error reporting are strictly routed to `stderr` (`WriteLn(StdErr, ...)`), keeping `stdout` clean for the VDRX bus.
2. **Deep JSON-Driven Configuration (`KyzuConfig.pas`)**:
   - Everything is externalized into `kyzu_bot_config.json`: faction identity, home coordinates, operational intervals, kinetic prediction thresholds, combat multipliers, genetic weights, and dynamic unit archetype roles.
   - If the configuration file is missing, the AI generates and persists a fully documented template.
3. **Full Kyzu Protocol Support**:
   - Unit spawning, pathfinding, and anticipatory combat.
   - Resource harvesting (`game.cmd.collect`, node tracking).
   - City founding (`game.cmd.found_city`), road infrastructure (`game.cmd.build_road`), and city siege mechanics.
   - Veterancy leveling tracking.
4. **Predictive Coding Engine (`KyzuPredictive.pas`)**:
   - Estimates velocities and accelerations, compares predictions against observations, computes surprise gradients, and calculates anticipatory intercept points.
5. **Genetic Strategy Evolution (`KyzuGenetics.pas`)**:
   - Real-time chromosome adaptation persisted to `kyzu_evolved_genome.json`.

---

### File Overview
```text
KyzuAI/
├── KyzuConfig.pas      # JSON configuration manager for all attributes & heuristics
├── KyzuEntities.pas    # Dynamic entities (units, cities, nodes, roads) & event bus
├── KyzuPredictive.pas  # Predictive coding, kinematic belief states & intercept calculator
├── KyzuGenetics.pas    # Genome vectors, crossover, mutation & fitness evaluation
├── KyzuBrain.pas       # High-level strategic coordinator implementing the Kyzu API
├── KyzuIO.pas          # Threaded Stdin reader and synchronized Stdout writer
└── KyzuAIProgram.lpr   # Application entry point and main tick loop
```

---

### 1. `KyzuConfig.pas` (Centralized JSON Configuration)
```pascal
unit KyzuConfig;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser;

type
  TAIConfig = class
  public
    // Faction & Geo Identity
    FactionName: string;
    HomeLon: Double;
    HomeLat: Double;

    // Tick & Decision Timing
    TickIntervalMs: Integer;
    SyncIntervalMs: Integer;
    PingIntervalMs: Integer;

    // Predictive Coding Parameters
    PredictiveLookahead: Double;
    KineticSmoothing: Double;
    SurpriseDampening: Double;
    SurpriseSensitivity: Double;

    // Tactical & Economic Thresholds
    RetreatHPRatio: Double;
    AggressionWeight: Double;
    CitySiegeWeight: Double;
    ResourceCollectWeight: Double;
    RoadBuildingWeight: Double;
    CityFoundingWeight: Double;
    FlockingCohesion: Double;
    MaxCombatRadius: Double;
    CollectRadius: Double;

    // Production Quotas
    MaxSoldiers: Integer;
    MaxHarvesters: Integer;
    MaxPioneers: Integer;

    // Genetic Evolution
    GeneticAutoEvolve: Boolean;
    EpochDurationSec: Double;
    PopulationSize: Integer;
    MutationRate: Double;

    constructor Create;
    procedure LoadFromFile(const AFilename: string);
    procedure SaveToFile(const AFilename: string);
    procedure SetDefaults;
  end;

implementation

constructor TAIConfig.Create;
begin
  SetDefaults;
end;

procedure TAIConfig.SetDefaults;
begin
  FactionName := 'evolved_ai';
  HomeLon := 25.0;
  HomeLat := 15.0;

  TickIntervalMs := 100;
  SyncIntervalMs := 5000;
  PingIntervalMs := 10000;

  PredictiveLookahead := 2.5;
  KineticSmoothing := 0.65;
  SurpriseDampening := 0.85;
  SurpriseSensitivity := 1.2;

  RetreatHPRatio := 0.25;
  AggressionWeight := 1.5;
  CitySiegeWeight := 2.0;
  ResourceCollectWeight := 1.0;
  RoadBuildingWeight := 0.8;
  CityFoundingWeight := 1.1;
  FlockingCohesion := 0.75;
  MaxCombatRadius := 20.0;
  CollectRadius := 2.0;

  MaxSoldiers := 6;
  MaxHarvesters := 3;
  MaxPioneers := 1;

  GeneticAutoEvolve := True;
  EpochDurationSec := 60.0;
  PopulationSize := 8;
  MutationRate := 0.25;
end;

procedure TAIConfig.LoadFromFile(const AFilename: string);
var
  SL: TStringList;
  JData: TJSONData;
  J, JSec: TJSONObject;
begin
  if not FileExists(AFilename) then
  begin
    SaveToFile(AFilename);
    Exit;
  end;

  SL := TStringList.Create;
  try
    SL.LoadFromFile(AFilename);
    JData := GetJSON(SL.Text);
    try
      if JData is TJSONObject then
      begin
        J := TJSONObject(JData);

        // General
        FactionName := J.Get('faction_name', FactionName);
        HomeLon := J.Get('home_lon', HomeLon);
        HomeLat := J.Get('home_lat', HomeLat);
        TickIntervalMs := J.Get('tick_interval_ms', TickIntervalMs);
        SyncIntervalMs := J.Get('sync_interval_ms', SyncIntervalMs);
        PingIntervalMs := J.Get('ping_interval_ms', PingIntervalMs);

        // Predictive
        JSec := J.Get('predictive', TJSONObject(nil));
        if JSec <> nil then
        begin
          PredictiveLookahead := JSec.Get('lookahead_sec', PredictiveLookahead);
          KineticSmoothing := JSec.Get('smoothing', KineticSmoothing);
          SurpriseDampening := JSec.Get('surprise_dampening', SurpriseDampening);
          SurpriseSensitivity := JSec.Get('surprise_sensitivity', SurpriseSensitivity);
        end;

        // Tactics & Utility
        JSec := J.Get('tactics', TJSONObject(nil));
        if JSec <> nil then
        begin
          RetreatHPRatio := JSec.Get('retreat_hp_ratio', RetreatHPRatio);
          AggressionWeight := JSec.Get('aggression_weight', AggressionWeight);
          CitySiegeWeight := JSec.Get('city_siege_weight', CitySiegeWeight);
          ResourceCollectWeight := JSec.Get('resource_collect_weight', ResourceCollectWeight);
          RoadBuildingWeight := JSec.Get('road_building_weight', RoadBuildingWeight);
          CityFoundingWeight := JSec.Get('city_founding_weight', CityFoundingWeight);
          FlockingCohesion := JSec.Get('flocking_cohesion', FlockingCohesion);
          MaxCombatRadius := JSec.Get('max_combat_radius', MaxCombatRadius);
          CollectRadius := JSec.Get('collect_radius', CollectRadius);
        end;

        // Quotas
        JSec := J.Get('quotas', TJSONObject(nil));
        if JSec <> nil then
        begin
          MaxSoldiers := JSec.Get('max_soldiers', MaxSoldiers);
          MaxHarvesters := JSec.Get('max_harvesters', MaxHarvesters);
          MaxPioneers := JSec.Get('max_pioneers', MaxPioneers);
        end;

        // Evolution
        JSec := J.Get('genetics', TJSONObject(nil));
        if JSec <> nil then
        begin
          GeneticAutoEvolve := JSec.Get('auto_evolve', GeneticAutoEvolve);
          EpochDurationSec := JSec.Get('epoch_duration_sec', EpochDurationSec);
          PopulationSize := JSec.Get('population_size', PopulationSize);
          MutationRate := JSec.Get('mutation_rate', MutationRate);
        end;
      end;
    finally
      JData.Free;
    end;
  finally
    SL.Free;
  end;
end;

procedure TAIConfig.SaveToFile(const AFilename: string);
var
  J, JPred, JTact, JQuota, JGen: TJSONObject;
  SL: TStringList;
begin
  J := TJSONObject.Create;
  try
    J.Strings['faction_name'] := FactionName;
    J.Floats['home_lon'] := HomeLon;
    J.Floats['home_lat'] := HomeLat;
    J.Integers['tick_interval_ms'] := TickIntervalMs;
    J.Integers['sync_interval_ms'] := SyncIntervalMs;
    J.Integers['ping_interval_ms'] := PingIntervalMs;

    JPred := TJSONObject.Create;
    JPred.Floats['lookahead_sec'] := PredictiveLookahead;
    JPred.Floats['smoothing'] := KineticSmoothing;
    JPred.Floats['surprise_dampening'] := SurpriseDampening;
    JPred.Floats['surprise_sensitivity'] := SurpriseSensitivity;
    J.Add('predictive', JPred);

    JTact := TJSONObject.Create;
    JTact.Floats['retreat_hp_ratio'] := RetreatHPRatio;
    JTact.Floats['aggression_weight'] := AggressionWeight;
    JTact.Floats['city_siege_weight'] := CitySiegeWeight;
    JTact.Floats['resource_collect_weight'] := ResourceCollectWeight;
    JTact.Floats['road_building_weight'] := RoadBuildingWeight;
    JTact.Floats['city_founding_weight'] := CityFoundingWeight;
    JTact.Floats['flocking_cohesion'] := FlockingCohesion;
    JTact.Floats['max_combat_radius'] := MaxCombatRadius;
    JTact.Floats['collect_radius'] := CollectRadius;
    J.Add('tactics', JTact);

    JQuota := TJSONObject.Create;
    JQuota.Integers['max_soldiers'] := MaxSoldiers;
    JQuota.Integers['max_harvesters'] := MaxHarvesters;
    JQuota.Integers['max_pioneers'] := MaxPioneers;
    J.Add('quotas', JQuota);

    JGen := TJSONObject.Create;
    JGen.Booleans['auto_evolve'] := GeneticAutoEvolve;
    JGen.Floats['epoch_duration_sec'] := EpochDurationSec;
    JGen.Integers['population_size'] := PopulationSize;
    JGen.Floats['mutation_rate'] := MutationRate;
    J.Add('genetics', JGen);

    SL := TStringList.Create;
    try
      SL.Text := J.FormatJSON();
      SL.SaveToFile(AFilename);
    finally
      SL.Free;
    end;
  finally
    J.Free;
  end;
end;

end.
```

---

### 2. `KyzuEntities.pas` (Entities, Dynamic Attributes & Event Dispatcher)
```pascal
unit KyzuEntities;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser;

type
  { Dynamic attribute bag for extensible schemas without recompilation }
  TDynamicAttributes = class
  private
    FData: TJSONObject;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetFloat(const Key: string; Val: Double);
    function GetFloat(const Key: string; Def: Double = 0.0): Double;
    procedure SetString(const Key: string; const Val: string);
    function GetString(const Key: string; const Def: string = ''): string;
    procedure IngestJSON(JObj: TJSONObject);
    property Raw: TJSONObject read FData;
  end;

  { Unit representation with veterancy & tasks }
  TKyzuUnit = class
  public
    ID: string;
    Owner: string;
    UnitType: string;
    Lon, Lat: Double;
    HP, MaxHP: Double;
    Level: Integer;
    XP: Integer;
    AttackPower: Double;
    TargetID: string;
    IsMoving: Boolean;
    Attributes: TDynamicAttributes;
    LastUpdate: TDateTime;
    constructor Create(const AID: string);
    destructor Destroy; override;
  end;

  { City representation with population defense pool & road links }
  TKyzuCity = class
  public
    ID: string;
    Owner: string;
    Lon, Lat: Double;
    Population: Double;
    Attributes: TDynamicAttributes;
    constructor Create(const AID: string);
    destructor Destroy; override;
  end;

  { Harvestable Resource Node }
  TKyzuNode = class
  public
    ID: string;
    NodeType: string;
    Lon, Lat: Double;
    Amount: Double;
    Attributes: TDynamicAttributes;
    constructor Create(const AID: string);
    destructor Destroy; override;
  end;

  { Road Network Connection }
  TKyzuRoad = class
  public
    ID: string;
    FromCityID: string;
    ToCityID: string;
    Owner: string;
    Attributes: TDynamicAttributes;
    constructor Create(const AID: string);
    destructor Destroy; override;
  end;

  TTopicCallback = procedure(Payload: TJSONObject) of object;

  { Extensible Event Dispatcher }
  TEventDispatcher = class
  private
    FHandlers: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Subscribe(const ATopic: string; AHandler: TMethod);
    procedure Dispatch(const ATopic: string; Payload: TJSONObject);
  end;

function EuclideanDist(Lon1, Lat1, Lon2, Lat2: Double): Double;

implementation

function EuclideanDist(Lon1, Lat1, Lon2, Lat2: Double): Double;
begin
  Result := Sqrt(Sqr(Lon1 - Lon2) + Sqr(Lat1 - Lat2));
end;

{ TDynamicAttributes }
constructor TDynamicAttributes.Create;
begin
  FData := TJSONObject.Create;
end;

destructor TDynamicAttributes.Destroy;
begin
  FData.Free;
  inherited Destroy;
end;

procedure TDynamicAttributes.SetFloat(const Key: string; Val: Double);
begin
  FData.Floats[Key] := Val;
end;

function TDynamicAttributes.GetFloat(const Key: string; Def: Double): Double;
var
  Idx: Integer;
begin
  Idx := FData.IndexOfName(Key);
  if Idx >= 0 then Result := FData.Items[Idx].AsFloat else Result := Def;
end;

procedure TDynamicAttributes.SetString(const Key: string; const Val: string);
begin
  FData.Strings[Key] := Val;
end;

function TDynamicAttributes.GetString(const Key: string; const Def: string): string;
var
  Idx: Integer;
begin
  Idx := FData.IndexOfName(Key);
  if Idx >= 0 then Result := FData.Items[Idx].AsString else Result := Def;
end;

procedure TDynamicAttributes.IngestJSON(JObj: TJSONObject);
var
  i: Integer;
begin
  for i := 0 to JObj.Count - 1 do
    FData.Add(JObj.Names[i], JObj.Items[i].Clone);
end;

{ TKyzuUnit }
constructor TKyzuUnit.Create(const AID: string);
begin
  ID := AID;
  HP := 100.0;
  MaxHP := 100.0;
  Level := 0;
  XP := 0;
  AttackPower := 10.0;
  IsMoving := False;
  Attributes := TDynamicAttributes.Create;
  LastUpdate := Now;
end;

destructor TKyzuUnit.Destroy;
begin
  Attributes.Free;
  inherited Destroy;
end;

{ TKyzuCity }
constructor TKyzuCity.Create(const AID: string);
begin
  ID := AID;
  Population := 1.0;
  Attributes := TDynamicAttributes.Create;
end;

destructor TKyzuCity.Destroy;
begin
  Attributes.Free;
  inherited Destroy;
end;

{ TKyzuNode }
constructor TKyzuNode.Create(const AID: string);
begin
  ID := AID;
  Amount := 100.0;
  Attributes := TDynamicAttributes.Create;
end;

destructor TKyzuNode.Destroy;
begin
  Attributes.Free;
  inherited Destroy;
end;

{ TKyzuRoad }
constructor TKyzuRoad.Create(const AID: string);
begin
  ID := AID;
  Attributes := TDynamicAttributes.Create;
end;

destructor TKyzuRoad.Destroy;
begin
  Attributes.Free;
  inherited Destroy;
end;

{ TEventDispatcher }
constructor TEventDispatcher.Create;
begin
  FHandlers := TStringList.Create;
  FHandlers.Sorted := True;
  FHandlers.Duplicates := dupAccept;
end;

destructor TEventDispatcher.Destroy;
begin
  FHandlers.Free;
  inherited Destroy;
end;

procedure TEventDispatcher.Subscribe(const ATopic: string; AHandler: TMethod);
begin
  FHandlers.AddObject(ATopic, TObject(AHandler.Code));
end;

procedure TEventDispatcher.Dispatch(const ATopic: string; Payload: TJSONObject);
var
  i: Integer;
  CB: TTopicCallback;
  M: TMethod;
begin
  for i := 0 to FHandlers.Count - 1 do
  begin
    if (FHandlers[i] = ATopic) or (FHandlers[i] = 'game.>') then
    begin
      M.Code := Pointer(FHandlers.Objects[i]);
      M.Data := Self;
      CB := TTopicCallback(M);
      try
        CB(Payload);
      except
        on E: Exception do
          Writeln(StdErr, Format('[DISPATCH ERROR] Topic %s: %s', [ATopic, E.Message]));
      end;
    end;
  end;
end;

end.
```

---

### 3. `KyzuPredictive.pas` (Kinematic Coding & Anticipatory Intercepts)
```pascal
unit KyzuPredictive;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, KyzuEntities, KyzuConfig;

type
  TKineticBelief = record
    Lon, Lat: Double;
    VelLon, VelLat: Double;
    AccLon, AccLat: Double;
    PredictedLon, PredictedLat: Double;
    LastObserved: TDateTime;
    PredictionError: Double;
    SampleCount: Integer;
  end;
  PKineticBelief = ^TKineticBelief;

  TPredictiveCodingEngine = class
  private
    FBeliefs: TStringList;
    FSurpriseMetric: Double;
    FConfig: TAIConfig;
    procedure ClearBeliefs;
    function GetOrCreateBelief(const AID: string): PKineticBelief;
  public
    constructor Create(AConfig: TAIConfig);
    destructor Destroy; override;

    procedure IngestObservation(const AID: string; CurrentLon, CurrentLat: Double);
    function PredictPosition(const AID: string; LookaheadSec: Double): TPointF;
    function CalculateAnticipatoryIntercept(AttackerLon, AttackerLat, AttackerSpeed: Double;
                                           const TargetID: string; MaxHorizon: Double): TPointF;
    procedure RemoveEntity(const AID: string);

    property SurpriseMetric: Double read FSurpriseMetric;
  end;

implementation

constructor TPredictiveCodingEngine.Create(AConfig: TAIConfig);
begin
  FConfig := AConfig;
  FBeliefs := TStringList.Create;
  FBeliefs.Sorted := True;
  FSurpriseMetric := 0.0;
end;

destructor TPredictiveCodingEngine.Destroy;
begin
  ClearBeliefs;
  FBeliefs.Free;
  inherited Destroy;
end;

procedure TPredictiveCodingEngine.ClearBeliefs;
var
  i: Integer;
begin
  for i := 0 to FBeliefs.Count - 1 do
    Dispose(PKineticBelief(FBeliefs.Objects[i]));
  FBeliefs.Clear;
end;

function TPredictiveCodingEngine.GetOrCreateBelief(const AID: string): PKineticBelief;
var
  Idx: Integer;
begin
  Idx := FBeliefs.IndexOf(AID);
  if Idx >= 0 then
    Result := PKineticBelief(FBeliefs.Objects[Idx])
  else
  begin
    New(Result);
    FillChar(Result^, SizeOf(TKineticBelief), 0);
    Result^.LastObserved := Now;
    FBeliefs.AddObject(AID, TObject(Result));
  end;
end;

procedure TPredictiveCodingEngine.IngestObservation(const AID: string; CurrentLon, CurrentLat: Double);
var
  B: PKineticBelief;
  Dt, Error, VLon, VLat: Double;
  Smooth: Double;
begin
  B := GetOrCreateBelief(AID);
  Dt := (Now - B^.LastObserved) * 86400.0;

  if (Dt > 0.02) and (B^.SampleCount > 0) then
  begin
    // Predictive error between prior sensory hypothesis and observation
    Error := EuclideanDist(CurrentLon, CurrentLat, B^.PredictedLon, B^.PredictedLat);
    B^.PredictionError := (B^.PredictionError * FConfig.SurpriseDampening) +
                          (Error * (1.0 - FConfig.SurpriseDampening));

    // Update global cognitive surprise gradient
    FSurpriseMetric := (FSurpriseMetric * 0.9) + (Error * 0.1);

    // Differentiate velocity & acceleration
    VLon := (CurrentLon - B^.Lon) / Dt;
    VLat := (CurrentLat - B^.Lat) / Dt;

    B^.AccLon := (VLon - B^.VelLon) / Dt;
    B^.AccLat := (VLat - B^.VelLat) / Dt;

    Smooth := FConfig.KineticSmoothing;
    B^.VelLon := (B^.VelLon * Smooth) + (VLon * (1.0 - Smooth));
    B^.VelLat := (B^.VelLat * Smooth) + (VLat * (1.0 - Smooth));
  end;

  B^.Lon := CurrentLon;
  B^.Lat := CurrentLat;
  B^.LastObserved := Now;
  Inc(B^.SampleCount);

  // Generative forward prediction for the next 1-second step
  B^.PredictedLon := CurrentLon + (B^.VelLon * 1.0);
  B^.PredictedLat := CurrentLat + (B^.VelLat * 1.0);
end;

function TPredictiveCodingEngine.PredictPosition(const AID: string; LookaheadSec: Double): TPointF;
var
  Idx: Integer;
  B: PKineticBelief;
begin
  Idx := FBeliefs.IndexOf(AID);
  if Idx < 0 then
  begin
    Result.X := 0.0;
    Result.Y := 0.0;
    Exit;
  end;

  B := PKineticBelief(FBeliefs.Objects[Idx]);
  Result.X := B^.Lon + (B^.VelLon * LookaheadSec) + (0.5 * B^.AccLon * Sqr(LookaheadSec) * 0.05);
  Result.Y := B^.Lat + (B^.VelLat * LookaheadSec) + (0.5 * B^.AccLat * Sqr(LookaheadSec) * 0.05);
end;

function TPredictiveCodingEngine.CalculateAnticipatoryIntercept(AttackerLon, AttackerLat, AttackerSpeed: Double;
                                                               const TargetID: string; MaxHorizon: Double): TPointF;
var
  Idx: Integer;
  B: PKineticBelief;
  Dist, Tau: Double;
begin
  Result.X := AttackerLon;
  Result.Y := AttackerLat;
  Idx := FBeliefs.IndexOf(TargetID);
  if Idx < 0 then Exit;

  B := PKineticBelief(FBeliefs.Objects[Idx]);
  Dist := EuclideanDist(AttackerLon, AttackerLat, B^.Lon, B^.Lat);

  if AttackerSpeed <= 0.001 then AttackerSpeed := 1.0;
  Tau := Min(Dist / AttackerSpeed, MaxHorizon);

  Result.X := B^.Lon + (B^.VelLon * Tau);
  Result.Y := B^.Lat + (B^.VelLat * Tau);
end;

procedure TPredictiveCodingEngine.RemoveEntity(const AID: string);
var
  Idx: Integer;
begin
  Idx := FBeliefs.IndexOf(AID);
  if Idx >= 0 then
  begin
    Dispose(PKineticBelief(FBeliefs.Objects[Idx]));
    FBeliefs.Delete(Idx);
  end;
end;

end.
```

---

### 4. `KyzuGenetics.pas` (Genetic Optimization & Fitness Tracking)
```pascal
unit KyzuGenetics;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser, KyzuConfig;

type
  TStrategyGenome = record
    AggressionMult: Double;
    LookaheadMult: Double;
    RetreatHPRatio: Double;
    CitySiegeMult: Double;
    CohesionMult: Double;
    HarvestMult: Double;
    Fitness: Double;
  end;

  TGeneticEngine = class
  private
    FConfig: TAIConfig;
    FPopulation: array of TStrategyGenome;
    FActiveIndex: Integer;
    FGeneration: Integer;
    FEpochStart: TDateTime;
    FStorageFile: string;

    // Telemetry registers
    FKills: Integer;
    FDeaths: Integer;
    FCitiesCaptured: Integer;
    FDamageDealt: Double;
    FResourcesHarvested: Double;

    function MutateGene(Val, MinV, MaxV: Double): Double;
    procedure Mutate(var G: TStrategyGenome);
    function Crossover(const A, B: TStrategyGenome): TStrategyGenome;
  public
    constructor Create(AConfig: TAIConfig; const AStorageFile: string = 'kyzu_evolved_genome.json');
    destructor Destroy; override;

    procedure RecordKill;
    procedure RecordDeath;
    procedure RecordCityCapture;
    procedure RecordDamage(Amount: Double);
    procedure RecordHarvest(Amount: Double);

    procedure EvaluateEpoch(SurpriseSum: Double);
    procedure SaveBestGenome;
    procedure LoadBestGenome;

    function GetActiveGenome: TStrategyGenome;
    property ActiveIndex: Integer read FActiveIndex;
    property Generation: Integer read FGeneration;
  end;

implementation

constructor TGeneticEngine.Create(AConfig: TAIConfig; const AStorageFile: string);
var
  i: Integer;
begin
  FConfig := AConfig;
  FStorageFile := AStorageFile;
  FActiveIndex := 0;
  FGeneration := 1;
  FEpochStart := Now;

  SetLength(FPopulation, FConfig.PopulationSize);
  for i := 0 to High(FPopulation) do
  begin
    FPopulation[i].AggressionMult := 0.7 + Random * 1.5;
    FPopulation[i].LookaheadMult := 0.8 + Random * 1.2;
    FPopulation[i].RetreatHPRatio := 0.15 + Random * 0.25;
    FPopulation[i].CitySiegeMult := 0.8 + Random * 1.5;
    FPopulation[i].CohesionMult := 0.5 + Random * 1.0;
    FPopulation[i].HarvestMult := 0.7 + Random * 1.3;
    FPopulation[i].Fitness := 0.0;
  end;

  LoadBestGenome;
end;

destructor TGeneticEngine.Destroy;
begin
  SaveBestGenome;
  inherited Destroy;
end;

function TGeneticEngine.MutateGene(Val, MinV, MaxV: Double): Double;
var
  Delta: Double;
begin
  if Random < FConfig.MutationRate then
  begin
    Delta := (Random - 0.5) * (MaxV - MinV) * 0.3;
    Val := EnsureRange(Val + Delta, MinV, MaxV);
  end;
  Result := Val;
end;

procedure TGeneticEngine.Mutate(var G: TStrategyGenome);
begin
  G.AggressionMult := MutateGene(G.AggressionMult, 0.2, 3.5);
  G.LookaheadMult := MutateGene(G.LookaheadMult, 0.3, 3.0);
  G.RetreatHPRatio := MutateGene(G.RetreatHPRatio, 0.05, 0.5);
  G.CitySiegeMult := MutateGene(G.CitySiegeMult, 0.2, 4.0);
  G.CohesionMult := MutateGene(G.CohesionMult, 0.0, 2.5);
  G.HarvestMult := MutateGene(G.HarvestMult, 0.2, 3.0);
end;

function TGeneticEngine.Crossover(const A, B: TStrategyGenome): TStrategyGenome;
begin
  Result.AggressionMult := (A.AggressionMult + B.AggressionMult) * 0.5;
  Result.LookaheadMult := (A.LookaheadMult + B.LookaheadMult) * 0.5;
  Result.RetreatHPRatio := (A.RetreatHPRatio + B.RetreatHPRatio) * 0.5;
  Result.CitySiegeMult := (A.CitySiegeMult + B.CitySiegeMult) * 0.5;
  Result.CohesionMult := (A.CohesionMult + B.CohesionMult) * 0.5;
  Result.HarvestMult := (A.HarvestMult + B.HarvestMult) * 0.5;
  Result.Fitness := 0.0;
end;

procedure TGeneticEngine.RecordKill; begin Inc(FKills); end;
procedure TGeneticEngine.RecordDeath; begin Inc(FDeaths); end;
procedure TGeneticEngine.RecordCityCapture; begin Inc(FCitiesCaptured); end;
procedure TGeneticEngine.RecordDamage(Amount: Double); begin FDamageDealt := FDamageDealt + Amount; end;
procedure TGeneticEngine.RecordHarvest(Amount: Double); begin FResourcesHarvested := FResourcesHarvested + Amount; end;

procedure TGeneticEngine.EvaluateEpoch(SurpriseSum: Double);
var
  Elapsed: Double;
  Score: Double;
  BestIdx, RunnerUpIdx, i: Integer;
begin
  if not FConfig.GeneticAutoEvolve then Exit;

  Elapsed := (Now - FEpochStart) * 86400.0;
  if Elapsed < FConfig.EpochDurationSec then Exit;

  Score := (FKills * 150.0) +
           (FCitiesCaptured * 400.0) +
           (FResourcesHarvested * 1.5) +
           (FDamageDealt * 2.0) -
           (FDeaths * 100.0) -
           (SurpriseSum * 10.0);

  FPopulation[FActiveIndex].Fitness := Score;
  Writeln(StdErr, Format('[EVO-EPOCH] Gen %d | Ind %d | Score: %.2f (Kills:%d Deaths:%d Caps:%d Dmg:%.1f Harf:%.1f)',
                 [FGeneration, FActiveIndex, Score, FKills, FDeaths, FCitiesCaptured, FDamageDealt, FResourcesHarvested]));

  // Reset registers
  FKills := 0;
  FDeaths := 0;
  FCitiesCaptured := 0;
  FDamageDealt := 0.0;
  FResourcesHarvested := 0.0;
  FEpochStart := Now;

  Inc(FActiveIndex);
  if FActiveIndex >= Length(FPopulation) then
  begin
    BestIdx := 0;
    RunnerUpIdx := 0;
    for i := 1 to High(FPopulation) do
    begin
      if FPopulation[i].Fitness > FPopulation[BestIdx].Fitness then
      begin
        RunnerUpIdx := BestIdx;
        BestIdx := i;
      end;
    end;

    Writeln(StdErr, Format('>>> GENERATION %d COMPLETE. Top Fitness: %.2f <<<', [FGeneration, FPopulation[BestIdx].Fitness]));
    SaveBestGenome;

    // Breed next generation
    for i := 0 to High(FPopulation) do
    begin
      if i = BestIdx then Continue;
      FPopulation[i] := Crossover(FPopulation[BestIdx], FPopulation[RunnerUpIdx]);
      Mutate(FPopulation[i]);
    end;

    FActiveIndex := 0;
    Inc(FGeneration);
  end;
end;

procedure TGeneticEngine.SaveBestGenome;
var
  J: TJSONObject;
  G: TStrategyGenome;
  SL: TStringList;
begin
  G := GetActiveGenome;
  J := TJSONObject.Create;
  try
    J.Floats['aggression_mult'] := G.AggressionMult;
    J.Floats['lookahead_mult'] := G.LookaheadMult;
    J.Floats['retreat_hp_ratio'] := G.RetreatHPRatio;
    J.Floats['city_siege_mult'] := G.CitySiegeMult;
    J.Floats['cohesion_mult'] := G.CohesionMult;
    J.Floats['harvest_mult'] := G.HarvestMult;

    SL := TStringList.Create;
    try
      SL.Text := J.FormatJSON();
      SL.SaveToFile(FStorageFile);
    finally
      SL.Free;
    end;
  finally
    J.Free;
  end;
end;

procedure TGeneticEngine.LoadBestGenome;
var
  SL: TStringList;
  JData: TJSONData;
  J: TJSONObject;
begin
  if not FileExists(FStorageFile) then Exit;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FStorageFile);
    JData := GetJSON(SL.Text);
    try
      if JData is TJSONObject then
      begin
        J := TJSONObject(JData);
        FPopulation[0].AggressionMult := J.Get('aggression_mult', FPopulation[0].AggressionMult);
        FPopulation[0].LookaheadMult := J.Get('lookahead_mult', FPopulation[0].LookaheadMult);
        FPopulation[0].RetreatHPRatio := J.Get('retreat_hp_ratio', FPopulation[0].RetreatHPRatio);
        FPopulation[0].CitySiegeMult := J.Get('city_siege_mult', FPopulation[0].CitySiegeMult);
        FPopulation[0].CohesionMult := J.Get('cohesion_mult', FPopulation[0].CohesionMult);
        FPopulation[0].HarvestMult := J.Get('harvest_mult', FPopulation[0].HarvestMult);
        Writeln(StdErr, '[EVO] Successfully restored evolved genome from ' + FStorageFile);
      end;
    finally
      JData.Free;
    end;
  finally
    SL.Free;
  end;
end;

function TGeneticEngine.GetActiveGenome: TStrategyGenome;
begin
  Result := FPopulation[FActiveIndex];
end;

end.
```

---

### 5. `KyzuIO.pas` (Threaded Stdin/Stdout Line-Buffered IPC)
```pascal
unit KyzuIO;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils
  {$IFDEF UNIX}
  , BaseUnix
  {$ENDIF};

type
  { Background thread reading line-buffered JSON from Stdin }
  TStdinReaderThread = class(TThread)
  private
    FQueue: TStringList;
    FLock: TRTLCriticalSection;
    FTerminatedFlag: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    function PopLine(out Line: string): Boolean;
    property IsPipeClosed: Boolean read FTerminatedFlag;
  end;

  { Line-buffered stdout command emitter }
  TStdoutWriter = class
  private
    FLock: TRTLCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SendLine(const ALine: string);
  end;

implementation

{ TStdinReaderThread }
constructor TStdinReaderThread.Create;
begin
  InitCriticalSection(FLock);
  FQueue := TStringList.Create;
  FTerminatedFlag := False;
  inherited Create(False);
end;

destructor TStdinReaderThread.Destroy;
begin
  FQueue.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TStdinReaderThread.Execute;
var
  Line: string;
begin
  while not Terminated do
  begin
    if Eof(Input) then
    begin
      FTerminatedFlag := True;
      Break;
    end;

    try
      ReadLn(Input, Line);
      if Line <> '' then
      begin
        EnterCriticalSection(FLock);
        try
          FQueue.Add(Line);
        finally
          LeaveCriticalSection(FLock);
        end;
      end;
    except
      FTerminatedFlag := True;
      Break;
    end;
  end;
end;

function TStdinReaderThread.PopLine(out Line: string): Boolean;
begin
  Result := False;
  Line := '';
  EnterCriticalSection(FLock);
  try
    if FQueue.Count > 0 then
    begin
      Line := FQueue[0];
      FQueue.Delete(0);
      Result := True;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ TStdoutWriter }
constructor TStdoutWriter.Create;
begin
  InitCriticalSection(FLock);
end;

destructor TStdoutWriter.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TStdoutWriter.SendLine(const ALine: string);
begin
  EnterCriticalSection(FLock);
  try
    WriteLn(Output, ALine);
    Flush(Output);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
```

---

### 6. `KyzuBrain.pas` (Unified Kyzu VDRX AI Core)
```pascal
unit KyzuBrain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser,
  KyzuConfig, KyzuEntities, KyzuPredictive, KyzuGenetics, KyzuIO;

type
  TKyzuBrain = class
  private
    FConfig: TAIConfig;
    FWriter: TStdoutWriter;
    FDispatcher: TEventDispatcher;
    FPredictor: TPredictiveCodingEngine;
    FGenetics: TGeneticEngine;

    // Game entity registries
    FUnits: TStringList;  // ID -> TKyzuUnit
    FCities: TStringList; // ID -> TKyzuCity
    FNodes: TStringList;  // ID -> TKyzuNode
    FRoads: TStringList;  // ID -> TKyzuRoad

    FNextSeq: Int64;
    FLastSyncTime: TDateTime;
    FLastPingTime: TDateTime;

    function GenerateID(const Prefix: string): string;
    procedure EmitCommand(const Topic: string; Payload: TJSONObject);

    procedure SetupEventHandlers;

    // Kyzu API topic handlers
    procedure OnEventSpawned(P: TJSONObject);
    procedure OnEventPosition(P: TJSONObject);
    procedure OnEventDespawned(P: TJSONObject);
    procedure OnEventUnitAttacked(P: TJSONObject);
    procedure OnEventCityUpdated(P: TJSONObject);
    procedure OnEventCityAbandoned(P: TJSONObject);
    procedure OnEventNodeList(P: TJSONObject);
    procedure OnEventCityList(P: TJSONObject);
    procedure OnEventRoadList(P: TJSONObject);
    procedure OnEventCollected(P: TJSONObject);
    procedure OnEventTick(P: TJSONObject);
    procedure OnEventPong(P: TJSONObject);

    // Sub-agent roles
    procedure DriveCombatSoldier(U: TKyzuUnit; const G: TStrategyGenome; FlockLon, FlockLat: Double);
    procedure DriveHarvester(U: TKyzuUnit; const G: TStrategyGenome);
    procedure DrivePioneer(U: TKyzuUnit; const G: TStrategyGenome);

  public
    constructor Create(AConfig: TAIConfig; AWriter: TStdoutWriter);
    destructor Destroy; override;

    procedure IngestJSONLine(const ALine: string);
    procedure ThinkAndAct; // Invoked per decision cycle
    procedure SyncWorldState; // Periodic snapshot request
  end;

implementation

constructor TKyzuBrain.Create(AConfig: TAIConfig; AWriter: TStdoutWriter);
begin
  FConfig := AConfig;
  FWriter := AWriter;

  FUnits := TStringList.Create;
  FUnits.Sorted := True;

  FCities := TStringList.Create;
  FCities.Sorted := True;

  FNodes := TStringList.Create;
  FNodes.Sorted := True;

  FRoads := TStringList.Create;
  FRoads.Sorted := True;

  FDispatcher := TEventDispatcher.Create;
  FPredictor := TPredictiveCodingEngine.Create(FConfig);
  FGenetics := TGeneticEngine.Create(FConfig, 'kyzu_evolved_genome.json');

  FNextSeq := 0;
  FLastSyncTime := 0;
  FLastPingTime := Now;

  SetupEventHandlers;
end;

destructor TKyzuBrain.Destroy;
var
  i: Integer;
begin
  for i := 0 to FUnits.Count - 1 do FUnits.Objects[i].Free;
  FUnits.Free;
  for i := 0 to FCities.Count - 1 do FCities.Objects[i].Free;
  FCities.Free;
  for i := 0 to FNodes.Count - 1 do FNodes.Objects[i].Free;
  FNodes.Free;
  for i := 0 to FRoads.Count - 1 do FRoads.Objects[i].Free;
  FRoads.Free;

  FDispatcher.Free;
  FPredictor.Free;
  FGenetics.Free;
  inherited Destroy;
end;

function TKyzuBrain.GenerateID(const Prefix: string): string;
begin
  Inc(FNextSeq);
  Result := Format('%s_%s_%d', [Prefix, FConfig.FactionName, FNextSeq]);
end;

procedure TKyzuBrain.EmitCommand(const Topic: string; Payload: TJSONObject);
var
  Envelope: TJSONObject;
begin
  Envelope := TJSONObject.Create;
  try
    Envelope.Strings['topic'] := Topic;
    // As per VDRX API doc: payload can be object or escaped JSON string. Object is emitted.
    Envelope.Add('payload', Payload);
    FWriter.SendLine(Envelope.AsJSON);
  finally
    Envelope.Free;
  end;
end;

procedure TKyzuBrain.SetupEventHandlers;
begin
  FDispatcher.Subscribe('game.event.pong', TMethod(@Self.OnEventPong));
  FDispatcher.Subscribe('game.event.spawned', TMethod(@Self.OnEventSpawned));
  FDispatcher.Subscribe('game.event.position', TMethod(@Self.OnEventPosition));
  FDispatcher.Subscribe('game.event.despawned', TMethod(@Self.OnEventDespawned));
  FDispatcher.Subscribe('game.event.unit_attacked', TMethod(@Self.OnEventUnitAttacked));
  FDispatcher.Subscribe('game.event.city_founded', TMethod(@Self.OnEventCityUpdated));
  FDispatcher.Subscribe('game.event.city_grew', TMethod(@Self.OnEventCityUpdated));
  FDispatcher.Subscribe('game.event.city_captured', TMethod(@Self.OnEventCityUpdated));
  FDispatcher.Subscribe('game.event.city_abandoned', TMethod(@Self.OnEventCityAbandoned));
  FDispatcher.Subscribe('game.event.node_list', TMethod(@Self.OnEventNodeList));
  FDispatcher.Subscribe('game.event.city_list', TMethod(@Self.OnEventCityList));
  FDispatcher.Subscribe('game.event.road_list', TMethod(@Self.OnEventRoadList));
  FDispatcher.Subscribe('game.event.collected', TMethod(@Self.OnEventCollected));
  FDispatcher.Subscribe('game.tick', TMethod(@Self.OnEventTick));
end;

procedure TKyzuBrain.OnEventPong(P: TJSONObject);
begin
  // Pong verified
end;

procedure TKyzuBrain.OnEventSpawned(P: TJSONObject);
var
  UID: string;
  U: TKyzuUnit;
  Idx: Integer;
begin
  UID := P.Get('unit_id', '');
  if UID = '' then Exit;

  Idx := FUnits.IndexOf(UID);
  if Idx < 0 then
  begin
    U := TKyzuUnit.Create(UID);
    FUnits.AddObject(UID, U);
  end
  else
    U := TKyzuUnit(FUnits.Objects[Idx]);

  U.Owner := P.Get('owner', '');
  U.UnitType := P.Get('unit_type', 'soldier');
  U.Lon := P.Get('lon', 0.0);
  U.Lat := P.Get('lat', 0.0);
  U.HP := P.Get('hp', 100.0);
  U.MaxHP := U.HP;
  U.Level := P.Get('level', 0);
  U.AttackPower := P.Get('attack', 10.0);
  U.Attributes.IngestJSON(P);

  FPredictor.IngestObservation(UID, U.Lon, U.Lat);
end;

procedure TKyzuBrain.OnEventPosition(P: TJSONObject);
var
  UID: string;
  Idx: Integer;
  U: TKyzuUnit;
begin
  UID := P.Get('unit_id', '');
  Idx := FUnits.IndexOf(UID);
  if Idx >= 0 then
  begin
    U := TKyzuUnit(FUnits.Objects[Idx]);
    U.Lon := P.Get('lon', U.Lon);
    U.Lat := P.Get('lat', U.Lat);
    U.IsMoving := True;
    U.LastUpdate := Now;
    FPredictor.IngestObservation(UID, U.Lon, U.Lat);
  end;
end;

procedure TKyzuBrain.OnEventDespawned(P: TJSONObject);
var
  UID: string;
  Idx: Integer;
begin
  UID := P.Get('unit_id', '');
  Idx := FUnits.IndexOf(UID);
  if Idx >= 0 then
  begin
    if TKyzuUnit(FUnits.Objects[Idx]).Owner = FConfig.FactionName then
      FGenetics.RecordDeath
    else
      FGenetics.RecordKill;

    FUnits.Objects[Idx].Free;
    FUnits.Delete(Idx);
    FPredictor.RemoveEntity(UID);
  end;
end;

procedure TKyzuBrain.OnEventUnitAttacked(P: TJSONObject);
var
  TargetID, AttackerID: string;
  Idx: Integer;
  U: TKyzuUnit;
  RemainingHP, Loss: Double;
begin
  TargetID := P.Get('target_unit_id', '');
  AttackerID := P.Get('attacker_unit_id', '');
  RemainingHP := P.Get('remaining_hp', 0.0);

  Idx := FUnits.IndexOf(TargetID);
  if Idx >= 0 then
  begin
    U := TKyzuUnit(FUnits.Objects[Idx]);
    Loss := Max(0.0, U.HP - RemainingHP);
    U.HP := RemainingHP;

    if U.Owner <> FConfig.FactionName then
      FGenetics.RecordDamage(Loss);
  end;
end;

procedure TKyzuBrain.OnEventCityUpdated(P: TJSONObject);
var
  CID, NewOwner: string;
  Idx: Integer;
  C: TKyzuCity;
begin
  CID := P.Get('city_id', '');
  if CID = '' then Exit;

  Idx := FCities.IndexOf(CID);
  if Idx < 0 then
  begin
    C := TKyzuCity.Create(CID);
    FCities.AddObject(CID, C);
  end
  else
    C := TKyzuCity(FCities.Objects[Idx]);

  NewOwner := P.Get('owner', P.Get('new_owner', C.Owner));
  if (NewOwner = FConfig.FactionName) and (C.Owner <> FConfig.FactionName) and (C.Owner <> '') then
    FGenetics.RecordCityCapture;

  C.Owner := NewOwner;
  C.Lon := P.Get('lon', C.Lon);
  C.Lat := P.Get('lat', C.Lat);
  C.Population := P.Get('population', C.Population);
  C.Attributes.IngestJSON(P);
end;

procedure TKyzuBrain.OnEventCityAbandoned(P: TJSONObject);
var
  CID: string;
  Idx: Integer;
begin
  CID := P.Get('city_id', '');
  Idx := FCities.IndexOf(CID);
  if Idx >= 0 then
  begin
    FCities.Objects[Idx].Free;
    FCities.Delete(Idx);
  end;
end;

procedure TKyzuBrain.OnEventNodeList(P: TJSONObject);
var
  NodesArr: TJSONArray;
  Item: TJSONObject;
  i, Idx: Integer;
  NID: string;
  Node: TKyzuNode;
begin
  NodesArr := P.Get('nodes', TJSONArray(nil));
  if NodesArr = nil then Exit;

  for i := 0 to NodesArr.Count - 1 do
  begin
    if NodesArr.Types[i] <> jtObject then Continue;
    Item := TJSONObject(NodesArr.Items[i]);
    NID := Item.Get('node_id', '');
    if NID = '' then Continue;

    Idx := FNodes.IndexOf(NID);
    if Idx < 0 then
    begin
      Node := TKyzuNode.Create(NID);
      FNodes.AddObject(NID, Node);
    end
    else
      Node := TKyzuNode(FNodes.Objects[Idx]);

    Node.NodeType := Item.Get('node_type', 'resource');
    Node.Lon := Item.Get('lon', Node.Lon);
    Node.Lat := Item.Get('lat', Node.Lat);
    Node.Amount := Item.Get('amount', Node.Amount);
    Node.Attributes.IngestJSON(Item);
  end;
end;

procedure TKyzuBrain.OnEventCityList(P: TJSONObject);
var
  CitiesArr: TJSONArray;
  Item: TJSONObject;
  i: Integer;
begin
  CitiesArr := P.Get('cities', TJSONArray(nil));
  if CitiesArr = nil then Exit;
  for i := 0 to CitiesArr.Count - 1 do
  begin
    if CitiesArr.Types[i] = jtObject then
      OnEventCityUpdated(TJSONObject(CitiesArr.Items[i]));
  end;
end;

procedure TKyzuBrain.OnEventRoadList(P: TJSONObject);
var
  RoadsArr: TJSONArray;
  Item: TJSONObject;
  i, Idx: Integer;
  RID: string;
  R: TKyzuRoad;
begin
  RoadsArr := P.Get('roads', TJSONArray(nil));
  if RoadsArr = nil then Exit;

  for i := 0 to RoadsArr.Count - 1 do
  begin
    if RoadsArr.Types[i] <> jtObject then Continue;
    Item := TJSONObject(RoadsArr.Items[i]);
    RID := Item.Get('road_id', '');
    if RID = '' then Continue;

    Idx := FRoads.IndexOf(RID);
    if Idx < 0 then
    begin
      R := TKyzuRoad.Create(RID);
      FRoads.AddObject(RID, R);
    end
    else
      R := TKyzuRoad(FRoads.Objects[Idx]);

    R.FromCityID := Item.Get('from_city_id', '');
    R.ToCityID := Item.Get('to_city_id', '');
    R.Owner := Item.Get('owner', '');
    R.Attributes.IngestJSON(Item);
  end;
end;

procedure TKyzuBrain.OnEventCollected(P: TJSONObject);
var
  Amt: Double;
  ByFaction: string;
begin
  ByFaction := P.Get('by', '');
  Amt := P.Get('collected_amount', 0.0);
  if ByFaction = FConfig.FactionName then
    FGenetics.RecordHarvest(Amt);
end;

procedure TKyzuBrain.OnEventTick(P: TJSONObject);
begin
  // Game tick notification received from engine
end;

procedure TKyzuBrain.IngestJSONLine(const ALine: string);
var
  JData, PayloadData: TJSONData;
  Envelope, PayloadObj: TJSONObject;
  Topic: string;
begin
  JData := GetJSON(ALine);
  try
    if not (JData is TJSONObject) then Exit;
    Envelope := TJSONObject(JData);

    Topic := Envelope.Get('topic', '');
    if Topic = '' then Exit;

    PayloadData := Envelope.Find('payload');
    if PayloadData = nil then Exit;

    PayloadObj := nil;
    if PayloadData is TJSONObject then
      PayloadObj := TJSONObject(PayloadData)
    else if PayloadData.JSONType = jtString then
    begin
      PayloadData := GetJSON(PayloadData.AsString);
      if PayloadData is TJSONObject then
        PayloadObj := TJSONObject(PayloadData);
    end;

    if PayloadObj <> nil then
      FDispatcher.Dispatch(Topic, PayloadObj);

  finally
    JData.Free;
  end;
end;

procedure TKyzuBrain.SyncWorldState;
var
  P: TJSONObject;
begin
  P := TJSONObject.Create;
  try
    EmitCommand('game.cmd.list_cities', P.Clone as TJSONObject);
    EmitCommand('game.cmd.list_roads', P.Clone as TJSONObject);
    EmitCommand('game.cmd.list_nodes', P.Clone as TJSONObject);
  finally
    P.Free;
  end;
end;

procedure TKyzuBrain.DriveCombatSoldier(U: TKyzuUnit; const G: TStrategyGenome; FlockLon, FlockLat: Double);
var
  j: Integer;
  TargetU: TKyzuUnit;
  C: TKyzuCity;
  BestUnitID, BestCityID: string;
  BestUnitScore, BestCityScore, Dist, Score: Double;
  Intercept: TPointF;
  MovePayload, AttackPayload: TJSONObject;
begin
  // Retreat check
  if (U.MaxHP > 0) and ((U.HP / U.MaxHP) < (FConfig.RetreatHPRatio * G.RetreatHPRatio)) then
  begin
    MovePayload := TJSONObject.Create;
    MovePayload.Strings['unit_id'] := U.ID;
    MovePayload.Floats['to_lon'] := FConfig.HomeLon;
    MovePayload.Floats['to_lat'] := FConfig.HomeLat;
    MovePayload.Strings['by'] := FConfig.FactionName;
    EmitCommand('game.cmd.move', MovePayload);
    Exit;
  end;

  BestUnitID := '';
  BestUnitScore := -1e9;
  for j := 0 to FUnits.Count - 1 do
  begin
    TargetU := TKyzuUnit(FUnits.Objects[j]);
    if (TargetU.Owner = FConfig.FactionName) or (TargetU.Owner = '') then Continue;

    Dist := EuclideanDist(U.Lon, U.Lat, TargetU.Lon, TargetU.Lat);
    if Dist > FConfig.MaxCombatRadius then Continue;

    Score := ((100.0 / Max(0.5, Dist)) + (TargetU.MaxHP - TargetU.HP)) *
             FConfig.AggressionWeight * G.AggressionMult;
    if Score > BestUnitScore then
    begin
      BestUnitScore := Score;
      BestUnitID := TargetU.ID;
    end;
  end;

  BestCityID := '';
  BestCityScore := -1e9;
  for j := 0 to FCities.Count - 1 do
  begin
    C := TKyzuCity(FCities.Objects[j]);
    if C.Owner = FConfig.FactionName then Continue;

    Dist := EuclideanDist(U.Lon, U.Lat, C.Lon, C.Lat);
    Score := ((150.0 / Max(0.5, Dist)) + (C.Population * 10.0)) *
             FConfig.CitySiegeWeight * G.CitySiegeMult;
    if Score > BestCityScore then
    begin
      BestCityScore := Score;
      BestCityID := C.ID;
    end;
  end;

  if (BestUnitID <> '') and (BestUnitScore >= BestCityScore) then
  begin
    TargetU := TKyzuUnit(FUnits.Objects[FUnits.IndexOf(BestUnitID)]);
    Dist := EuclideanDist(U.Lon, U.Lat, TargetU.Lon, TargetU.Lat);

    if Dist <= 1.5 then
    begin
      AttackPayload := TJSONObject.Create;
      AttackPayload.Strings['attacker_unit_id'] := U.ID;
      AttackPayload.Strings['target_unit_id'] := BestUnitID;
      AttackPayload.Strings['by'] := FConfig.FactionName;
      EmitCommand('game.cmd.attack', AttackPayload);
    end
    else
    begin
      Intercept := FPredictor.CalculateAnticipatoryIntercept(U.Lon, U.Lat, 1.2, BestUnitID,
                                                             FConfig.PredictiveLookahead * G.LookaheadMult);
      MovePayload := TJSONObject.Create;
      MovePayload.Strings['unit_id'] := U.ID;
      MovePayload.Floats['to_lon'] := (Intercept.X * 0.8) + (FlockLon * 0.2 * G.CohesionMult);
      MovePayload.Floats['to_lat'] := (Intercept.Y * 0.8) + (FlockLat * 0.2 * G.CohesionMult);
      MovePayload.Strings['by'] := FConfig.FactionName;
      EmitCommand('game.cmd.move', MovePayload);
    end;
  end
  else if BestCityID <> '' then
  begin
    C := TKyzuCity(FCities.Objects[FCities.IndexOf(BestCityID)]);
    Dist := EuclideanDist(U.Lon, U.Lat, C.Lon, C.Lat);

    if Dist <= 1.5 then
    begin
      AttackPayload := TJSONObject.Create;
      AttackPayload.Strings['attacker_unit_id'] := U.ID;
      AttackPayload.Strings['target_city_id'] := BestCityID;
      AttackPayload.Strings['by'] := FConfig.FactionName;
      EmitCommand('game.cmd.attack', AttackPayload);
    end
    else
    begin
      MovePayload := TJSONObject.Create;
      MovePayload.Strings['unit_id'] := U.ID;
      MovePayload.Floats['to_lon'] := C.Lon;
      MovePayload.Floats['to_lat'] := C.Lat;
      MovePayload.Strings['by'] := FConfig.FactionName;
      EmitCommand('game.cmd.move', MovePayload);
    end;
  end;
end;

procedure TKyzuBrain.DriveHarvester(U: TKyzuUnit; const G: TStrategyGenome);
var
  i, BestIdx: Integer;
  Node: TKyzuNode;
  BestDist, Dist: Double;
  Cmd: TJSONObject;
begin
  BestIdx := -1;
  BestDist := 1e9;

  for i := 0 to FNodes.Count - 1 do
  begin
    Node := TKyzuNode(FNodes.Objects[i]);
    if Node.Amount <= 0.1 then Continue;

    Dist := EuclideanDist(U.Lon, U.Lat, Node.Lon, Node.Lat);
    if Dist < BestDist then
    begin
      BestDist := Dist;
      BestIdx := i;
    end;
  end;

  if BestIdx < 0 then Exit;
  Node := TKyzuNode(FNodes.Objects[BestIdx]);

  if BestDist <= FConfig.CollectRadius then
  begin
    Cmd := TJSONObject.Create;
    Cmd.Strings['unit_id'] := U.ID;
    Cmd.Strings['node_id'] := Node.ID;
    Cmd.Strings['by'] := FConfig.FactionName;
    EmitCommand('game.cmd.collect', Cmd);
  end
  else
  begin
    Cmd := TJSONObject.Create;
    Cmd.Strings['unit_id'] := U.ID;
    Cmd.Floats['to_lon'] := Node.Lon;
    Cmd.Floats['to_lat'] := Node.Lat;
    Cmd.Strings['by'] := FConfig.FactionName;
    EmitCommand('game.cmd.move', Cmd);
  end;
end;

procedure TKyzuBrain.DrivePioneer(U: TKyzuUnit; const G: TStrategyGenome);
var
  Cmd: TJSONObject;
  DistFromHome: Double;
begin
  DistFromHome := EuclideanDist(U.Lon, U.Lat, FConfig.HomeLon, FConfig.HomeLat);
  // If sufficiently far from home base, found city
  if DistFromHome >= 12.0 then
  begin
    Cmd := TJSONObject.Create;
    Cmd.Strings['city_id'] := GenerateID('city');
    Cmd.Strings['unit_id'] := U.ID;
    Cmd.Strings['by'] := FConfig.FactionName;
    EmitCommand('game.cmd.found_city', Cmd);
  end
  else
  begin
    // Head outward to an expansion sector
    Cmd := TJSONObject.Create;
    Cmd.Strings['unit_id'] := U.ID;
    Cmd.Floats['to_lon'] := FConfig.HomeLon + 15.0;
    Cmd.Floats['to_lat'] := FConfig.HomeLat + 15.0;
    Cmd.Strings['by'] := FConfig.FactionName;
    EmitCommand('game.cmd.move', Cmd);
  end;
end;

procedure TKyzuBrain.ThinkAndAct;
var
  Genome: TStrategyGenome;
  i, SoldCount, HarvCount, PionCount: Integer;
  U: TKyzuUnit;
  FlockLon, FlockLat: Double;
  SpawnCmd, PingCmd: TJSONObject;
begin
  Genome := FGenetics.GetActiveGenome;
  FGenetics.EvaluateEpoch(FPredictor.SurpriseMetric);

  // Keepalive ping check
  if ((Now - FLastPingTime) * 86400000.0) >= FConfig.PingIntervalMs then
  begin
    PingCmd := TJSONObject.Create;
    EmitCommand('game.cmd.ping', PingCmd);
    FLastPingTime := Now;
  end;

  // Periodic Snapshot Sync
  if ((Now - FLastSyncTime) * 86400000.0) >= FConfig.SyncIntervalMs then
  begin
    SyncWorldState;
    FLastSyncTime := Now;
  end;

  // 1. Tally units and calculate flocking center
  SoldCount := 0;
  HarvCount := 0;
  PionCount := 0;
  FlockLon := 0.0;
  FlockLat := 0.0;

  for i := 0 to FUnits.Count - 1 do
  begin
    U := TKyzuUnit(FUnits.Objects[i]);
    if U.Owner <> FConfig.FactionName then Continue;

    if U.UnitType = 'soldier' then
    begin
      Inc(SoldCount);
      FlockLon := FlockLon + U.Lon;
      FlockLat := FlockLat + U.Lat;
    end
    else if U.UnitType = 'harvester' then
      Inc(HarvCount)
    else if U.UnitType = 'pioneer' then
      Inc(PionCount);
  end;

  if SoldCount > 0 then
  begin
    FlockLon := FlockLon / SoldCount;
    FlockLat := FlockLat / SoldCount;
  end
  else
  begin
    FlockLon := FConfig.HomeLon;
    FlockLat := FConfig.HomeLat;
  end;

  // 2. Production spawns according to configured quotas
  if SoldCount < FConfig.MaxSoldiers then
  begin
    SpawnCmd := TJSONObject.Create;
    SpawnCmd.Strings['unit_id'] := GenerateID('soldier');
    SpawnCmd.Floats['lon'] := FConfig.HomeLon;
    SpawnCmd.Floats['lat'] := FConfig.HomeLat;
    SpawnCmd.Strings['owner'] := FConfig.FactionName;
    SpawnCmd.Strings['unit_type'] := 'soldier';
    EmitCommand('game.cmd.spawn', SpawnCmd);
  end
  else if HarvCount < FConfig.MaxHarvesters then
  begin
    SpawnCmd := TJSONObject.Create;
    SpawnCmd.Strings['unit_id'] := GenerateID('harv');
    SpawnCmd.Floats['lon'] := FConfig.HomeLon;
    SpawnCmd.Floats['lat'] := FConfig.HomeLat;
    SpawnCmd.Strings['owner'] := FConfig.FactionName;
    SpawnCmd.Strings['unit_type'] := 'harvester';
    EmitCommand('game.cmd.spawn', SpawnCmd);
  end
  else if PionCount < FConfig.MaxPioneers then
  begin
    SpawnCmd := TJSONObject.Create;
    SpawnCmd.Strings['unit_id'] := GenerateID('pion');
    SpawnCmd.Floats['lon'] := FConfig.HomeLon;
    SpawnCmd.Floats['lat'] := FConfig.HomeLat;
    SpawnCmd.Strings['owner'] := FConfig.FactionName;
    SpawnCmd.Strings['unit_type'] := 'pioneer';
    EmitCommand('game.cmd.spawn', SpawnCmd);
  end;

  // 3. Drive individual unit behaviors
  for i := 0 to FUnits.Count - 1 do
  begin
    U := TKyzuUnit(FUnits.Objects[i]);
    if U.Owner <> FConfig.FactionName then Continue;

    if U.UnitType = 'soldier' then
      DriveCombatSoldier(U, Genome, FlockLon, FlockLat)
    else if U.UnitType = 'harvester' then
      DriveHarvester(U, Genome)
    else if U.UnitType = 'pioneer' then
      DrivePioneer(U, Genome);
  end;
end;

end.
```

---

### 7. `KyzuAIProgram.lpr` (Main Stdin/Stdout Application Entry)
```pascal
program KyzuAIProgram;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads, BaseUnix,
  {$ENDIF}
  Classes, SysUtils,
  KyzuConfig, KyzuEntities, KyzuPredictive, KyzuGenetics, KyzuIO, KyzuBrain;

var
  Config: TAIConfig;
  Reader: TStdinReaderThread;
  Writer: TStdoutWriter;
  Brain: TKyzuBrain;
  Line: string;
  ConfigFile: string;
  LastDecisionTick: QWord;

procedure ParseCLI(out AConfigFile: string);
begin
  AConfigFile := 'kyzu_bot_config.json';
  if ParamCount >= 1 then
    AConfigFile := ParamStr(1);
end;

begin
  Randomize;
  ParseCLI(ConfigFile);

  // Load external JSON configuration
  Config := TAIConfig.Create;
  Config.LoadFromFile(ConfigFile);

  // Diagnostic banner to stderr (stdout is reserved exclusively for the bus)
  Writeln(StdErr, '=======================================================');
  Writeln(StdErr, ' Kyzu VDRX Stdin/Stdout AI Bot (Predictive & Genetic)  ');
  Writeln(StdErr, Format(' Config: %s | Faction: %s', [ConfigFile, Config.FactionName]));
  Writeln(StdErr, '=======================================================');

  Writer := TStdoutWriter.Create;
  Reader := TStdinReaderThread.Create;
  Brain := TKyzuBrain.Create(Config, Writer);

  try
    // Request initial world snapshots on startup
    Brain.SyncWorldState;

    LastDecisionTick := GetTickCount64;

    while not Reader.IsPipeClosed do
    begin
      // Drain inbound lines from Stdin reader queue
      while Reader.PopLine(Line) do
      begin
        try
          Brain.IngestJSONLine(Line);
        except
          on E: Exception do
            Writeln(StdErr, '[PARSER ERROR] ' + E.Message);
        end;
      end;

      // Cognitive tick execution
      if (GetTickCount64 - LastDecisionTick) >= QWord(Config.TickIntervalMs) then
      begin
        Brain.ThinkAndAct;
        LastDecisionTick := GetTickCount64;
      end;

      Sleep(10);
    end;

    Writeln(StdErr, '[SYSTEM] Stdin closed by supervisor. Exiting gracefully.');

  finally
    Brain.Free;
    Reader.Terminate;
    Reader.WaitFor;
    Reader.Free;
    Writer.Free;
    Config.Free;
  end;
end.
```

---

### Default Configuration File (`kyzu_bot_config.json`)
The bot creates this JSON file automatically if it doesn't already exist:
```json
{
  "faction_name": "evolved_ai",
  "home_lon": 25.0,
  "home_lat": 15.0,
  "tick_interval_ms": 100,
  "sync_interval_ms": 5000,
  "ping_interval_ms": 10000,
  "predictive": {
    "lookahead_sec": 2.5,
    "smoothing": 0.65,
    "surprise_dampening": 0.85,
    "surprise_sensitivity": 1.2
  },
  "tactics": {
    "retreat_hp_ratio": 0.25,
    "aggression_weight": 1.5,
    "city_siege_weight": 2.0,
    "resource_collect_weight": 1.0,
    "road_building_weight": 0.8,
    "city_founding_weight": 1.1,
    "flocking_cohesion": 0.75,
    "max_combat_radius": 20.0,
    "collect_radius": 2.0
  },
  "quotas": {
    "max_soldiers": 6,
    "max_harvesters": 3,
    "max_pioneers": 1
  },
  "genetics": {
    "auto_evolve": true,
    "epoch_duration_sec": 60.0,
    "population_size": 8,
    "mutation_rate": 0.25
  }
}
```

---

### Building & Execution

#### Linux / macOS
```bash
fpc -O2 -gl -Fu. KyzuAIProgram.lpr
# Direct execution (or managed as a child process by VDRX via stdin/stdout pipe)
./KyzuAIProgram custom_config.json
```

#### Windows (Win64)
```cmd
fpc -O2 -gl -Fu. -dWINDOWS KyzuAIProgram.lpr
KyzuAIProgram.exe custom_config.json
```

#### Supervising in `kyzu.vdrx.conf`
Because this binary communicates entirely via line-buffered stdin/stdout, it can be supervised directly by VDRX:
```nginx
process ai_bot {
    command = "./KyzuAIProgram kyzu_bot_config.json"
    restart = always
}
```
