Here is an intelligent learning AI system for the Kyzu VDRX WebSocket engine, written in clean FreePascal without third-party dependencies (using standard FCL units: `fpjson`, `jsonparser`, `math`, `sysutils`, `classes`, and native Win64/Linux OS sockets).

### Key Architectural Enhancements
1. **Predictive Coding Engine (`KyzuPredictive.pas`)**:
   - Maintains kinetic state filters (position, velocity vectors, acceleration, trajectory history) for all entities.
   - Generates top-down forward predictions $\hat{S}_{t+\Delta t}$ and computes prediction error vectors ($\epsilon = Y - \hat{Y}$).
   - High prediction error triggers a cognitive **Surprise Signal** (detecting tactical feints, unexpected maneuvers, or ambushes) causing dynamic adaptation.
   - Provides **anticipatory intercept calculation** rather than chasing behind fleeing targets.
2. **Genetic Evolution Engine (`KyzuGenetics.pas`)**:
   - Represents behavioral and tactical hyperparameters as evolvable chromosomes (aggression, predictive horizon, flocking cohesion, retreat HP thresholds, city capture bias, surprise sensitivity).
   - Dynamic fitness tracking (kills, survivability, territory expansion, predictive accuracy).
   - Auto-saves and loads winning genomes from `kyzu_genome.json` so learned combat behaviors persist across runs.
3. **Abstracted Dynamic Attribute Architecture (`KyzuEntities.pas`)**:
   - Key-value attribute graphs that dynamically ingest new game attributes (`shield`, `energy`, `elevation`, `morale`) without schema rewrites.
   - Extensible topic event dispatcher.
4. **Zero-Dependency RFC-6455 WebSocket Client (`KyzuSockets.pas`)**:
   - Handles TCP handshake, frame masking/unmasking, fragmented buffers, and non-blocking I/O across Win64 (`WinSock2`) and Linux (`BaseUnix`/`Sockets`).

---

### Project File Structure
```text
KyzuAI/
├── KyzuSockets.pas      # Native cross-platform RFC-6455 WebSocket client
├── KyzuEntities.pas     # Dynamic world model, attribute maps, and event bus
├── KyzuPredictive.pas   # Predictive coding and kinematic trajectory tracking
├── KyzuGenetics.pas     # Chromosomes, mutations, fitness, and persistence
├── KyzuBrain.pas        # Tactical coordinator uniting prediction and genetics
└── KyzuAIProgram.lpr    # Main application entry point and event loop
```

---

### 1. `KyzuSockets.pas` (Native WebSocket Client)
```pascal
unit KyzuSockets;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils
  {$IFDEF WINDOWS}
  , WinSock2, Windows
  {$ELSE}
  , Sockets, BaseUnix, Unix
  {$ENDIF};

type
  TWSEventType = (wseOpen, wseMessage, wseClose, wseError);
  TWSMessageCallback = procedure(const AMessage: string) of object;
  TWSEventCallback = procedure(AEventType: TWSEventType; const AInfo: string) of object;

  TWebSocketClient = class
  private
    {$IFDEF WINDOWS}
    FSocket: TSocket;
    {$ELSE}
    FSocket: cint;
    {$ENDIF}
    FHost: string;
    FPort: Word;
    FConnected: Boolean;
    FHandshakeDone: Boolean;
    FOnMessage: TWSMessageCallback;
    FOnEvent: TWSEventCallback;
    FRxBuffer: string;

    function ConnectSocket(const AHost: string; APort: Word): Boolean;
    procedure CloseSocketInternal;
    function SendRaw(const AData: Pointer; ASize: Integer): Integer;
    function ReceiveRaw(ABuffer: Pointer; ASize: Integer): Integer;
    function PerformHandshake: Boolean;
    procedure ProcessRawFrame;
    function GenerateMaskKey: LongWord;
  public
    constructor Create;
    destructor Destroy; override;

    function Connect(const AHost: string; APort: Word): Boolean;
    procedure Disconnect;
    procedure Poll(TimeoutMs: Integer = 10);
    function SendText(const APayload: string): Boolean;

    property Connected: Boolean read FConnected;
    property HandshakeDone: Boolean read FHandshakeDone;
    property OnMessage: TWSMessageCallback read FOnMessage write FOnMessage;
    property OnEvent: TWSEventCallback read FOnEvent write FOnEvent;
  end;

implementation

{$IFDEF WINDOWS}
var
  WSAData: TWSAData;
  WSAInitialized: Boolean = False;
{$ENDIF}

constructor TWebSocketClient.Create;
begin
  inherited Create;
  {$IFDEF WINDOWS}
  if not WSAInitialized then
  begin
    WSAStartup($0202, WSAData);
    WSAInitialized := True;
  end;
  FSocket := INVALID_SOCKET;
  {$ELSE}
  FSocket := -1;
  {$ENDIF}
  FConnected := False;
  FHandshakeDone := False;
  FRxBuffer := '';
end;

destructor TWebSocketClient.Destroy;
begin
  Disconnect;
  inherited Destroy;
end;

function TWebSocketClient.ConnectSocket(const AHost: string; APort: Word): Boolean;
{$IFDEF WINDOWS}
var
  Addr: sockaddr_in;
  HostEnt: PHostEnt;
begin
  Result := False;
  FSocket := WinSock2.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if FSocket = INVALID_SOCKET then Exit;

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Addr.sin_addr.S_addr := inet_addr(PChar(AHost));

  if Addr.sin_addr.S_addr = INADDR_NONE then
  begin
    HostEnt := gethostbyname(PChar(AHost));
    if HostEnt = nil then Exit;
    Addr.sin_addr := PInAddr(HostEnt^.h_addr_list^)^;
  end;

  if WinSock2.connect(FSocket, @Addr, SizeOf(Addr)) = 0 then
    Result := True;
end;
{$ELSE}
var
  Addr: TInetSockAddr;
  HostEnt: THostEntry;
begin
  Result := False;
  FSocket := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FSocket < 0 then Exit;

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Addr.sin_addr.s_addr := StrToNetAddr(AHost).s_addr;

  if Addr.sin_addr.s_addr = 0 then
  begin
    if ResolveHostByName(AHost, HostEnt) then
      Addr.sin_addr := HostEnt.Addr;
  end;

  if fpConnect(FSocket, @Addr, SizeOf(Addr)) = 0 then
    Result := True;
end;
{$ENDIF}

procedure TWebSocketClient.CloseSocketInternal;
begin
  {$IFDEF WINDOWS}
  if FSocket <> INVALID_SOCKET then
  begin
    closesocket(FSocket);
    FSocket := INVALID_SOCKET;
  end;
  {$ELSE}
  if FSocket >= 0 then
  begin
    fpClose(FSocket);
    FSocket := -1;
  end;
  {$ENDIF}
  FConnected := False;
  FHandshakeDone := False;
end;

function TWebSocketClient.SendRaw(const AData: Pointer; ASize: Integer): Integer;
begin
  Result := 0;
  if not FConnected then Exit;
  {$IFDEF WINDOWS}
  Result := WinSock2.send(FSocket, AData^, ASize, 0);
  {$ELSE}
  Result := fpSend(FSocket, AData, ASize, 0);
  {$ENDIF}
end;

function TWebSocketClient.ReceiveRaw(ABuffer: Pointer; ASize: Integer): Integer;
begin
  Result := 0;
  if not FConnected then Exit;
  {$IFDEF WINDOWS}
  Result := WinSock2.recv(FSocket, ABuffer^, ASize, 0);
  {$ELSE}
  Result := fpRecv(FSocket, ABuffer, ASize, 0);
  {$ENDIF}
end;

function TWebSocketClient.PerformHandshake: Boolean;
var
  Req: string;
  Buffer: array[0..2047] of Char;
  BytesRead: Integer;
  Resp: string;
begin
  Result := False;
  Req := 'GET / HTTP/1.1'#13#10 +
         'Host: ' + FHost + ':' + IntToStr(FPort) + #13#10 +
         'Upgrade: websocket'#13#10 +
         'Connection: Upgrade'#13#10 +
         'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='#13#10 +
         'Sec-WebSocket-Version: 13'#13#10#13#10;

  if SendRaw(PChar(Req), Length(Req)) <= 0 then Exit;

  FillChar(Buffer, SizeOf(Buffer), 0);
  BytesRead := ReceiveRaw(@Buffer[0], SizeOf(Buffer) - 1);
  if BytesRead <= 0 then Exit;

  Resp := Buffer;
  if Pos('101 Switching Protocols', Resp) > 0 then
  begin
    FHandshakeDone := True;
    Result := True;
    if Assigned(FOnEvent) then FOnEvent(wseOpen, 'Connected and Handshake Complete');
  end;
end;

function TWebSocketClient.GenerateMaskKey: LongWord;
begin
  Result := Random($7FFFFFFF);
end;

function TWebSocketClient.SendText(const APayload: string): Boolean;
var
  Frame: array of Byte;
  Len: Int64;
  Mask: LongWord;
  MaskBytes: array[0..3] of Byte;
  HeaderSize, i: Integer;
begin
  Result := False;
  if not (FConnected and FHandshakeDone) then Exit;

  Len := Length(APayload);
  if Len <= 125 then
    HeaderSize := 6
  else if Len <= 65535 then
    HeaderSize := 8
  else
    HeaderSize := 14;

  SetLength(Frame, HeaderSize + Len);
  Frame[0] := $81; // FIN + Text Opcode

  Mask := GenerateMaskKey;
  Move(Mask, MaskBytes[0], 4);

  if Len <= 125 then
  begin
    Frame[1] := $80 or Byte(Len);
    Move(MaskBytes[0], Frame[2], 4);
  end
  else if Len <= 65535 then
  begin
    Frame[1] := $80 or 126;
    Frame[2] := (Len shr 8) and $FF;
    Frame[3] := Len and $FF;
    Move(MaskBytes[0], Frame[4], 4);
  end
  else
  begin
    Frame[1] := $80 or 127;
    for i := 0 to 7 do
      Frame[2 + i] := (Len shr ((7 - i) * 8)) and $FF;
    Move(MaskBytes[0], Frame[10], 4);
  end;

  for i := 0 to Len - 1 do
    Frame[HeaderSize + i] := Byte(APayload[i + 1]) xor MaskBytes[i mod 4];

  Result := SendRaw(@Frame[0], Length(Frame)) = Length(Frame);
end;

procedure TWebSocketClient.ProcessRawFrame;
var
  Opcode, MaskBit: Byte;
  PayloadLen: Int64;
  HeaderLen: Integer;
  PayloadStr: string;
  MaskKey: array[0..3] of Byte;
  i: Integer;
begin
  while Length(FRxBuffer) >= 2 do
  begin
    Opcode := Byte(FRxBuffer[1]) and $0F;
    MaskBit := (Byte(FRxBuffer[2]) and $80) shr 7;
    PayloadLen := Byte(FRxBuffer[2]) and $7F;
    HeaderLen := 2;

    if PayloadLen = 126 then
    begin
      if Length(FRxBuffer) < 4 then Exit;
      PayloadLen := (Byte(FRxBuffer[3]) shl 8) or Byte(FRxBuffer[4]);
      HeaderLen := 4;
    end
    else if PayloadLen = 127 then
    begin
      if Length(FRxBuffer) < 10 then Exit;
      PayloadLen := 0;
      for i := 0 to 7 do
        PayloadLen := (PayloadLen shl 8) or Byte(FRxBuffer[3 + i]);
      HeaderLen := 10;
    end;

    if MaskBit = 1 then
    begin
      if Length(FRxBuffer) < HeaderLen + 4 then Exit;
      Move(FRxBuffer[HeaderLen + 1], MaskKey[0], 4);
      Inc(HeaderLen, 4);
    end;

    if Length(FRxBuffer) < HeaderLen + PayloadLen then Exit;

    SetLength(PayloadStr, PayloadLen);
    if PayloadLen > 0 then
    begin
      Move(FRxBuffer[HeaderLen + 1], PayloadStr[1], PayloadLen);
      if MaskBit = 1 then
      begin
        for i := 1 to PayloadLen do
          PayloadStr[i] := Char(Byte(PayloadStr[i]) xor MaskKey[(i - 1) mod 4]);
      end;
    end;

    Delete(FRxBuffer, 1, HeaderLen + PayloadLen);

    if Opcode = $1 then // Text
    begin
      if Assigned(FOnMessage) then FOnMessage(PayloadStr);
    end
    else if Opcode = $8 then // Close
    begin
      Disconnect;
      Exit;
    end;
  end;
end;

procedure TWebSocketClient.Poll(TimeoutMs: Integer);
var
  {$IFDEF WINDOWS}
  ReadFds: TFDSet;
  Tv: TTimeVal;
  {$ELSE}
  ReadFds: TFDSet;
  Tv: TimeVal;
  {$ENDIF}
  Buffer: array[0..4095] of Char;
  BytesRead: Integer;
begin
  if not FConnected then Exit;

  {$IFDEF WINDOWS}
  FD_ZERO(ReadFds);
  FD_SET(FSocket, ReadFds);
  Tv.tv_sec := TimeoutMs div 1000;
  Tv.tv_usec := (TimeoutMs mod 1000) * 1000;
  if WinSock2.select(0, @ReadFds, nil, nil, @Tv) > 0 then
  {$ELSE}
  fpFD_ZERO(ReadFds);
  fpFD_SET(FSocket, ReadFds);
  Tv.tv_sec := TimeoutMs div 1000;
  Tv.tv_usec := (TimeoutMs mod 1000) * 1000;
  if fpSelect(FSocket + 1, @ReadFds, nil, nil, @Tv) > 0 then
  {$ENDIF}
  begin
    BytesRead := ReceiveRaw(@Buffer[0], SizeOf(Buffer));
    if BytesRead > 0 then
    begin
      FRxBuffer := FRxBuffer + Copy(Buffer, 1, BytesRead);
      ProcessRawFrame;
    end
    else if BytesRead <= 0 then
    begin
      Disconnect;
    end;
  end;
end;

function TWebSocketClient.Connect(const AHost: string; APort: Word): Boolean;
begin
  Disconnect;
  FHost := AHost;
  FPort := APort;
  Randomize;
  FConnected := ConnectSocket(AHost, APort);
  if FConnected then
    Result := PerformHandshake
  else
    Result := False;
end;

procedure TWebSocketClient.Disconnect;
begin
  if FConnected then
  begin
    CloseSocketInternal;
    if Assigned(FOnEvent) then FOnEvent(wseClose, 'Disconnected');
  end;
end;

end.
```

---

### 2. `KyzuEntities.pas` (Dynamic Entities & Attribute Model)
```pascal
unit KyzuEntities;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser;

type
  { Extensible dynamic attribute dictionary supporting arbitrary schema changes }
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
    property RawObject: TJSONObject read FData;
  end;

  { Game World Entity representation }
  TKyzuUnit = class
  public
    ID: string;
    Owner: string;
    UnitType: string;
    Lon: Double;
    Lat: Double;
    HP: Double;
    MaxHP: Double;
    Attributes: TDynamicAttributes;
    LastUpdate: TDateTime;
    constructor Create(const AID: string);
    destructor Destroy; override;
  end;

  TKyzuCity = class
  public
    ID: string;
    Owner: string;
    Lon: Double;
    Lat: Double;
    Population: Double;
    Attributes: TDynamicAttributes;
    constructor Create(const AID: string);
    destructor Destroy; override;
  end;

  { Dynamic Feature & Event Dispatcher }
  TEventPayloadCallback = procedure(Payload: TJSONObject) of object;

  TEventDispatcher = class
  private
    FHandlers: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure RegisterTopic(const ATopic: string; AHandler: TMethod);
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
  if Idx >= 0 then
    Result := FData.Items[Idx].AsFloat
  else
    Result := Def;
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
  if Idx >= 0 then
    Result := FData.Items[Idx].AsString
  else
    Result := Def;
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
  Attributes := TDynamicAttributes.Create;
  LastUpdate := Now;
  HP := 100.0;
  MaxHP := 100.0;
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
  Attributes := TDynamicAttributes.Create;
  Population := 1.0;
end;

destructor TKyzuCity.Destroy;
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

procedure TEventDispatcher.RegisterTopic(const ATopic: string; AHandler: TMethod);
begin
  FHandlers.AddObject(ATopic, TObject(AHandler.Code));
end;

procedure TEventDispatcher.Dispatch(const ATopic: string; Payload: TJSONObject);
var
  i: Integer;
  Handler: TEventPayloadCallback;
  M: TMethod;
begin
  for i := 0 to FHandlers.Count - 1 do
  begin
    if (FHandlers[i] = ATopic) or (FHandlers[i] = 'game.>') then
    begin
      M.Code := Pointer(FHandlers.Objects[i]);
      M.Data := Self;
      Handler := TEventPayloadCallback(M);
      try
        Handler(Payload);
      except
      end;
    end;
  end;
end;

end.
```

---

### 3. `KyzuPredictive.pas` (Predictive Coding & Intercept Trajectory)
```pascal
unit KyzuPredictive;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, KyzuEntities;

type
  { 2D Kinematic Belief State for an entity }
  TKineticBelief = record
    Lon, Lat: Double;
    VelLon, VelLat: Double;
    AccLon, AccLat: Double;
    PredictedLon, PredictedLat: Double;
    LastObservedTime: TDateTime;
    PredictionErrorAccumulator: Double;
    ObservationsCount: Integer;
  end;
  PKineticBelief = ^TKineticBelief;

  { Predictive Coding Engine implementing Free-Energy/Surprise minimisation }
  TPredictiveCodingEngine = class
  private
    FBeliefs: TStringList; // Key: UnitID, Value: PKineticBelief
    FGlobalSurprise: Double;
    procedure ClearBeliefs;
    function GetOrCreateBelief(const EntityID: string): PKineticBelief;
  public
    constructor Create;
    destructor Destroy; override;

    procedure IngestObservation(const EntityID: string; CurrentLon, CurrentLat: Double);
    procedure PredictEntity(const EntityID: string; LookaheadSeconds: Double; out OutLon, OutLat: Double);
    function CalculateAnticipatoryIntercept(AttackerLon, AttackerLat, AttackerSpeed: Double;
                                           const TargetID: string; MaxHorizon: Double): TPointF;
    procedure RemoveEntity(const EntityID: string);

    property GlobalSurprise: Double read FGlobalSurprise;
  end;

implementation

constructor TPredictiveCodingEngine.Create;
begin
  FBeliefs := TStringList.Create;
  FBeliefs.Sorted := True;
  FGlobalSurprise := 0.0;
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

function TPredictiveCodingEngine.GetOrCreateBelief(const EntityID: string): PKineticBelief;
var
  Idx: Integer;
begin
  Idx := FBeliefs.IndexOf(EntityID);
  if Idx >= 0 then
    Result := PKineticBelief(FBeliefs.Objects[Idx])
  else
  begin
    New(Result);
    FillChar(Result^, SizeOf(TKineticBelief), 0);
    Result^.LastObservedTime := Now;
    FBeliefs.AddObject(EntityID, TObject(Result));
  end;
end;

procedure TPredictiveCodingEngine.IngestObservation(const EntityID: string; CurrentLon, CurrentLat: Double);
var
  B: PKineticBelief;
  Dt, Error, InstantVelLon, InstantVelLat: Double;
begin
  B := GetOrCreateBelief(EntityID);
  Dt := (Now - B^.LastObservedTime) * 86400.0; // convert days to seconds

  if (Dt > 0.01) and (B^.ObservationsCount > 0) then
  begin
    // Calculate prediction error (Sensory Input - Prior Predictive Expectation)
    Error := EuclideanDist(CurrentLon, CurrentLat, B^.PredictedLon, B^.PredictedLat);
    B^.PredictionErrorAccumulator := (B^.PredictionErrorAccumulator * 0.8) + (Error * 0.2);
    
    // Free Energy / Surprise calculation (Leaky integration of prediction error)
    FGlobalSurprise := (FGlobalSurprise * 0.9) + (Error * 0.1);

    // Compute velocity and acceleration updates
    InstantVelLon := (CurrentLon - B^.Lon) / Dt;
    InstantVelLat := (CurrentLat - B^.Lat) / Dt;

    B^.AccLon := (InstantVelLon - B^.VelLon) / Dt;
    B^.AccLat := (InstantVelLat - B^.VelLat) / Dt;

    // Dampen noise with predictive exponential smoothing
    B^.VelLon := (B^.VelLon * 0.65) + (InstantVelLon * 0.35);
    B^.VelLat := (B^.VelLat * 0.65) + (InstantVelLat * 0.35);
  end;

  B^.Lon := CurrentLon;
  B^.Lat := CurrentLat;
  B^.LastObservedTime := Now;
  Inc(B^.ObservationsCount);

  // Top-down generative prediction for next 1 second step
  B^.PredictedLon := CurrentLon + (B^.VelLon * 1.0);
  B^.PredictedLat := CurrentLat + (B^.VelLat * 1.0);
end;

procedure TPredictiveCodingEngine.PredictEntity(const EntityID: string; LookaheadSeconds: Double; out OutLon, OutLat: Double);
var
  Idx: Integer;
  B: PKineticBelief;
begin
  Idx := FBeliefs.IndexOf(EntityID);
  if Idx < 0 then
  begin
    OutLon := 0.0;
    OutLat := 0.0;
    Exit;
  end;

  B := PKineticBelief(FBeliefs.Objects[Idx]);
  // 2nd-order Taylor expansion with kinematic dampening
  OutLon := B^.Lon + (B^.VelLon * LookaheadSeconds) + (0.5 * B^.AccLon * Sqr(LookaheadSeconds) * 0.1);
  OutLat := B^.Lat + (B^.VelLat * LookaheadSeconds) + (0.5 * B^.AccLat * Sqr(LookaheadSeconds) * 0.1);
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

  // Intercept point projected along velocity trajectory
  Result.X := B^.Lon + (B^.VelLon * Tau);
  Result.Y := B^.Lat + (B^.VelLat * Tau);
end;

procedure TPredictiveCodingEngine.RemoveEntity(const EntityID: string);
var
  Idx: Integer;
begin
  Idx := FBeliefs.IndexOf(EntityID);
  if Idx >= 0 then
  begin
    Dispose(PKineticBelief(FBeliefs.Objects[Idx]));
    FBeliefs.Delete(Idx);
  end;
end;

end.
```

---

### 4. `KyzuGenetics.pas` (Genetic Evolution & Hyperparameter Tuning)
```pascal
unit KyzuGenetics;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser;

type
  { Evolvable strategy genome vector }
  TStrategyGenome = record
    AggressionFactor: Double;        // 0.2 .. 3.0
    PredictiveLookahead: Double;     // 0.5 .. 5.0 seconds
    RetreatHPRatio: Double;          // 0.0 .. 0.5
    CityCaptureBias: Double;         // 0.1 .. 4.0
    FlockingCohesion: Double;        // 0.0 .. 2.0
    SurpriseSensitivity: Double;     // 0.1 .. 2.5
    TargetDefenseRadius: Double;     // 2.0 .. 25.0
    SpawnQuota: Integer;             // 1 .. 8
    Fitness: Double;
  end;

  { Genetic Evolution Manager }
  TGeneticEngine = class
  private
    FPopulation: array of TStrategyGenome;
    FActiveIndex: Integer;
    FGeneration: Integer;
    FEpochDurationSeconds: Double;
    FEpochStartTime: TDateTime;
    FStorageFile: string;

    // Telemetry for active fitness
    FKills: Integer;
    FDeaths: Integer;
    FCitiesCaptured: Integer;
    FDamageDealt: Double;
    FAccumulatedSurprise: Double;

    function MutateGene(Val, MinVal, MaxVal, MutationRate: Double): Double;
    procedure MutateGenome(var G: TStrategyGenome);
    function Crossover(const P1, P2: TStrategyGenome): TStrategyGenome;
  public
    constructor Create(const AStorageFile: string = 'kyzu_genome.json');
    destructor Destroy; override;

    procedure InitializePopulation(Size: Integer = 6);
    procedure RecordKill;
    procedure RecordDeath;
    procedure RecordCityCapture;
    procedure RecordDamage(Amount: Double);
    procedure IngestSurprise(SurpriseVal: Double);

    procedure EvaluateEpoch(ForceNext: Boolean = False);
    procedure SaveBestGenome;
    procedure LoadBestGenome;

    function GetActiveGenome: TStrategyGenome;
    property ActiveIndex: Integer read FActiveIndex;
    property Generation: Integer read FGeneration;
  end;

implementation

constructor TGeneticEngine.Create(const AStorageFile: string);
begin
  FStorageFile := AStorageFile;
  FActiveIndex := 0;
  FGeneration := 1;
  FEpochDurationSeconds := 45.0; // 45 seconds per evaluation cycle
  FEpochStartTime := Now;
  InitializePopulation(6);
  LoadBestGenome;
end;

destructor TGeneticEngine.Destroy;
begin
  SaveBestGenome;
  inherited Destroy;
end;

procedure TGeneticEngine.InitializePopulation(Size: Integer);
var
  i: Integer;
begin
  SetLength(FPopulation, Size);
  for i := 0 to Size - 1 do
  begin
    FPopulation[i].AggressionFactor := 0.8 + Random * 1.5;
    FPopulation[i].PredictiveLookahead := 1.0 + Random * 3.0;
    FPopulation[i].RetreatHPRatio := 0.1 + Random * 0.3;
    FPopulation[i].CityCaptureBias := 0.5 + Random * 2.0;
    FPopulation[i].FlockingCohesion := 0.2 + Random * 1.2;
    FPopulation[i].SurpriseSensitivity := 0.5 + Random * 1.0;
    FPopulation[i].TargetDefenseRadius := 5.0 + Random * 15.0;
    FPopulation[i].SpawnQuota := 2 + Random(4);
    FPopulation[i].Fitness := 0.0;
  end;
end;

function TGeneticEngine.MutateGene(Val, MinVal, MaxVal, MutationRate: Double): Double;
var
  Delta: Double;
begin
  if Random < 0.35 then
  begin
    Delta := (Random - 0.5) * (MaxVal - MinVal) * MutationRate;
    Val := EnsureRange(Val + Delta, MinVal, MaxVal);
  end;
  Result := Val;
end;

procedure TGeneticEngine.MutateGenome(var G: TStrategyGenome);
begin
  G.AggressionFactor := MutateGene(G.AggressionFactor, 0.2, 3.0, 0.3);
  G.PredictiveLookahead := MutateGene(G.PredictiveLookahead, 0.5, 5.0, 0.25);
  G.RetreatHPRatio := MutateGene(G.RetreatHPRatio, 0.0, 0.5, 0.2);
  G.CityCaptureBias := MutateGene(G.CityCaptureBias, 0.1, 4.0, 0.3);
  G.FlockingCohesion := MutateGene(G.FlockingCohesion, 0.0, 2.0, 0.25);
  G.SurpriseSensitivity := MutateGene(G.SurpriseSensitivity, 0.1, 2.5, 0.25);
  G.TargetDefenseRadius := MutateGene(G.TargetDefenseRadius, 2.0, 25.0, 0.3);
  if Random < 0.25 then
    G.SpawnQuota := EnsureRange(G.SpawnQuota + Random(3) - 1, 1, 8);
end;

function TGeneticEngine.Crossover(const P1, P2: TStrategyGenome): TStrategyGenome;
begin
  Result.AggressionFactor := (P1.AggressionFactor + P2.AggressionFactor) * 0.5;
  Result.PredictiveLookahead := (P1.PredictiveLookahead + P2.PredictiveLookahead) * 0.5;
  Result.RetreatHPRatio := (P1.RetreatHPRatio + P2.RetreatHPRatio) * 0.5;
  Result.CityCaptureBias := (P1.CityCaptureBias + P2.CityCaptureBias) * 0.5;
  Result.FlockingCohesion := (P1.FlockingCohesion + P2.FlockingCohesion) * 0.5;
  Result.SurpriseSensitivity := (P1.SurpriseSensitivity + P2.SurpriseSensitivity) * 0.5;
  Result.TargetDefenseRadius := (P1.TargetDefenseRadius + P2.TargetDefenseRadius) * 0.5;
  Result.SpawnQuota := Round((P1.SpawnQuota + P2.SpawnQuota) * 0.5);
  Result.Fitness := 0.0;
end;

procedure TGeneticEngine.RecordKill; begin Inc(FKills); end;
procedure TGeneticEngine.RecordDeath; begin Inc(FDeaths); end;
procedure TGeneticEngine.RecordCityCapture; begin Inc(FCitiesCaptured); end;
procedure TGeneticEngine.RecordDamage(Amount: Double); begin FDamageDealt := FDamageDealt + Amount; end;
procedure TGeneticEngine.IngestSurprise(SurpriseVal: Double); begin FAccumulatedSurprise := FAccumulatedSurprise + SurpriseVal; end;

procedure TGeneticEngine.EvaluateEpoch(ForceNext: Boolean);
var
  Elapsed: Double;
  FitnessScore: Double;
  BestIdx, SecondIdx, i: Integer;
begin
  Elapsed := (Now - FEpochStartTime) * 86400.0;
  if (not ForceNext) and (Elapsed < FEpochDurationSeconds) then Exit;

  // Composite Fitness calculation
  FitnessScore := (FKills * 120.0) +
                  (FCitiesCaptured * 300.0) +
                  (FDamageDealt * 1.5) -
                  (FDeaths * 90.0) -
                  (FAccumulatedSurprise * 5.0);

  FPopulation[FActiveIndex].Fitness := FitnessScore;
  Writeln(Format('[EVOLUTION] Individual %d Fitness: %.2f (K:%d D:%d Caps:%d Dmg:%.1f)',
                 [FActiveIndex, FitnessScore, FKills, FDeaths, FCitiesCaptured, FDamageDealt]));

  // Reset telemetry
  FKills := 0;
  FDeaths := 0;
  FCitiesCaptured := 0;
  FDamageDealt := 0.0;
  FAccumulatedSurprise := 0.0;
  FEpochStartTime := Now;

  Inc(FActiveIndex);
  if FActiveIndex >= Length(FPopulation) then
  begin
    // Epoch Generation Complete: Evolve
    BestIdx := 0;
    SecondIdx := 0;
    for i := 1 to High(FPopulation) do
    begin
      if FPopulation[i].Fitness > FPopulation[BestIdx].Fitness then
      begin
        SecondIdx := BestIdx;
        BestIdx := i;
      end;
    end;

    Writeln(Format('=== GENERATION %d COMPLETE. Dominant Fitness: %.2f ===', [FGeneration, FPopulation[BestIdx].Fitness]));
    SaveBestGenome;

    // Produce offspring
    for i := 0 to High(FPopulation) do
    begin
      if i = BestIdx then Continue;
      FPopulation[i] := Crossover(FPopulation[BestIdx], FPopulation[SecondIdx]);
      MutateGenome(FPopulation[i]);
    end;

    FActiveIndex := 0;
    Inc(FGeneration);
  end;
end;

procedure TGeneticEngine.SaveBestGenome;
var
  J: TJSONObject;
  G: TStrategyGenome;
  F: TStringList;
begin
  G := GetActiveGenome;
  J := TJSONObject.Create;
  try
    J.Floats['aggression'] := G.AggressionFactor;
    J.Floats['lookahead'] := G.PredictiveLookahead;
    J.Floats['retreat_hp'] := G.RetreatHPRatio;
    J.Floats['city_bias'] := G.CityCaptureBias;
    J.Floats['cohesion'] := G.FlockingCohesion;
    J.Floats['surprise_sensitivity'] := G.SurpriseSensitivity;
    J.Floats['defense_radius'] := G.TargetDefenseRadius;
    J.Integers['spawn_quota'] := G.SpawnQuota;

    F := TStringList.Create;
    try
      F.Text := J.AsJSON;
      F.SaveToFile(FStorageFile);
    finally
      F.Free;
    end;
  finally
    J.Free;
  end;
end;

procedure TGeneticEngine.LoadBestGenome;
var
  F: TStringList;
  JData: TJSONData;
  J: TJSONObject;
begin
  if not FileExists(FStorageFile) then Exit;
  F := TStringList.Create;
  try
    F.LoadFromFile(FStorageFile);
    JData := GetJSON(F.Text);
    try
      if JData is TJSONObject then
      begin
        J := TJSONObject(JData);
        FPopulation[0].AggressionFactor := J.Get('aggression', FPopulation[0].AggressionFactor);
        FPopulation[0].PredictiveLookahead := J.Get('lookahead', FPopulation[0].PredictiveLookahead);
        FPopulation[0].RetreatHPRatio := J.Get('retreat_hp', FPopulation[0].RetreatHPRatio);
        FPopulation[0].CityCaptureBias := J.Get('city_bias', FPopulation[0].CityCaptureBias);
        FPopulation[0].FlockingCohesion := J.Get('cohesion', FPopulation[0].FlockingCohesion);
        FPopulation[0].SurpriseSensitivity := J.Get('surprise_sensitivity', FPopulation[0].SurpriseSensitivity);
        FPopulation[0].TargetDefenseRadius := J.Get('defense_radius', FPopulation[0].TargetDefenseRadius);
        FPopulation[0].SpawnQuota := J.Get('spawn_quota', FPopulation[0].SpawnQuota);
        Writeln('[EVOLUTION] Loaded saved genome into active pool.');
      end;
    finally
      JData.Free;
    end;
  finally
    F.Free;
  end;
end;

function TGeneticEngine.GetActiveGenome: TStrategyGenome;
begin
  Result := FPopulation[FActiveIndex];
end;

end.
```

---

### 5. `KyzuBrain.pas` (Predictive Multi-Agent Tactical Coordinator)
```pascal
unit KyzuBrain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser,
  KyzuSockets, KyzuEntities, KyzuPredictive, KyzuGenetics;

type
  TKyzuBrain = class
  private
    FWS: TWebSocketClient;
    FFaction: string;
    FHomeLon, FHomeLat: Double;
    FUnits: TStringList;  // UnitID -> TKyzuUnit
    FCities: TStringList; // CityID -> TKyzuCity
    FPredictor: TPredictiveCodingEngine;
    FGenetics: TGeneticEngine;
    FDispatcher: TEventDispatcher;
    FNextID: Int64;

    function GenerateID(const Prefix: string): string;
    procedure Publish(const Topic: string; Payload: TJSONObject);
    procedure HandleIncomingJSON(const RawJSON: string);
    procedure SetupEventHandlers;

    // Topic handlers
    procedure OnEventSpawned(P: TJSONObject);
    procedure OnEventPosition(P: TJSONObject);
    procedure OnEventDespawned(P: TJSONObject);
    procedure OnEventUnitAttacked(P: TJSONObject);
    procedure OnEventCityUpdated(P: TJSONObject);
    procedure OnEventCityAbandoned(P: TJSONObject);
  public
    constructor Create(AWS: TWebSocketClient; const AFaction: string;
                       AHomeLon, AHomeLat: Double);
    destructor Destroy; override;

    procedure ProcessMessage(const AMessage: string);
    procedure ThinkAndAct; // Decision loop

    property Faction: string read FFaction;
    property Genetics: TGeneticEngine read FGenetics;
    property Predictor: TPredictiveCodingEngine read FPredictor;
  end;

implementation

constructor TKyzuBrain.Create(AWS: TWebSocketClient; const AFaction: string;
                              AHomeLon, AHomeLat: Double);
begin
  FWS := AWS;
  FFaction := AFaction;
  FHomeLon := AHomeLon;
  FHomeLat := AHomeLat;
  FNextID := 0;

  FUnits := TStringList.Create;
  FUnits.Sorted := True;

  FCities := TStringList.Create;
  FCities.Sorted := True;

  FPredictor := TPredictiveCodingEngine.Create;
  FGenetics := TGeneticEngine.Create('kyzu_evolved_genome.json');
  FDispatcher := TEventDispatcher.Create;

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

  FPredictor.Free;
  FGenetics.Free;
  FDispatcher.Free;
  inherited Destroy;
end;

function TKyzuBrain.GenerateID(const Prefix: string): string;
begin
  Inc(FNextID);
  Result := Format('%s_%s_%d_%d', [Prefix, FFaction, DateTimeToTimeStamp(Now).Time, FNextID]);
end;

procedure TKyzuBrain.Publish(const Topic: string; Payload: TJSONObject);
var
  Root: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Strings['method'] := 'publish';
    Root.Strings['topic'] := Topic;
    Root.Add('payload', Payload);
    FWS.SendText(Root.AsJSON);
  finally
    Root.Free;
  end;
end;

procedure TKyzuBrain.SetupEventHandlers;
begin
  FDispatcher.RegisterTopic('game.event.spawned', TMethod(@Self.OnEventSpawned));
  FDispatcher.RegisterTopic('game.event.position', TMethod(@Self.OnEventPosition));
  FDispatcher.RegisterTopic('game.event.despawned', TMethod(@Self.OnEventDespawned));
  FDispatcher.RegisterTopic('game.event.unit_attacked', TMethod(@Self.OnEventUnitAttacked));
  FDispatcher.RegisterTopic('game.event.city_founded', TMethod(@Self.OnEventCityUpdated));
  FDispatcher.RegisterTopic('game.event.city_grew', TMethod(@Self.OnEventCityUpdated));
  FDispatcher.RegisterTopic('game.event.city_captured', TMethod(@Self.OnEventCityUpdated));
  FDispatcher.RegisterTopic('game.event.city_abandoned', TMethod(@Self.OnEventCityAbandoned));
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
    if TKyzuUnit(FUnits.Objects[Idx]).Owner = FFaction then
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
  TargetID: string;
  Idx: Integer;
  U: TKyzuUnit;
  RemainingHP, Loss: Double;
begin
  TargetID := P.Get('target_unit_id', '');
  RemainingHP := P.Get('remaining_hp', 0.0);
  Idx := FUnits.IndexOf(TargetID);
  if Idx >= 0 then
  begin
    U := TKyzuUnit(FUnits.Objects[Idx]);
    Loss := Max(0.0, U.HP - RemainingHP);
    U.HP := RemainingHP;
    if U.Owner <> FFaction then
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
  if (NewOwner = FFaction) and (C.Owner <> FFaction) and (C.Owner <> '') then
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

procedure TKyzuBrain.HandleIncomingJSON(const RawJSON: string);
var
  JData, PayloadData: TJSONData;
  Root, PayloadObj: TJSONObject;
  Topic: string;
begin
  JData := GetJSON(RawJSON);
  try
    if not (JData is TJSONObject) then Exit;
    Root := TJSONObject(JData);

    if Root.Get('event', '') = 'auth.ok' then
    begin
      Writeln(Format('[BRAIN] Authenticated as %s. Subscribing to game events...', [Root.Get('source', '')]));
      FWS.SendText('{"method":"subscribe","filter":"game.>"}');
      Exit;
    end;

    Topic := Root.Get('topic', '');
    if Topic = '' then Exit;

    PayloadData := Root.Find('payload');
    if PayloadData = nil then Exit;

    PayloadObj := nil;
    if PayloadData is TJSONObject then
      PayloadObj := TJSONObject(PayloadData)
    else if PayloadData.JSONType = jtString then
    begin
      PayloadData := GetJSON(PayloadData.AsString);
      if PayloadData is TJSONObject then PayloadObj := TJSONObject(PayloadData);
    end;

    if PayloadObj <> nil then
      FDispatcher.Dispatch(Topic, PayloadObj);

  finally
    JData.Free;
  end;
end;

procedure TKyzuBrain.ProcessMessage(const AMessage: string);
begin
  try
    HandleIncomingJSON(AMessage);
  except
    on E: Exception do
      Writeln('[BRAIN ERROR] Parse exception: ' + E.Message);
  end;
end;

procedure TKyzuBrain.ThinkAndAct;
var
  Genome: TStrategyGenome;
  MySoldierCount, i, j: Integer;
  U, TargetU: TKyzuUnit;
  C: TKyzuCity;
  SpawnPayload, ActionPayload: TJSONObject;
  BestUnitID, BestCityID: string;
  BestUnitScore, BestCityScore, Score, Dist: Double;
  TargetLon, TargetLat: Double;
  Intercept: TPointF;
  FlockCenterLon, FlockCenterLat: Double;
  SurpriseMod: Double;
begin
  Genome := FGenetics.GetActiveGenome;
  FGenetics.IngestSurprise(FPredictor.GlobalSurprise);
  FGenetics.EvaluateEpoch;

  // Surprise modulation
  SurpriseMod := 1.0 + (FPredictor.GlobalSurprise * Genome.SurpriseSensitivity);

  // 1. Spawning decision using genome parameters
  MySoldierCount := 0;
  FlockCenterLon := 0.0;
  FlockCenterLat := 0.0;

  for i := 0 to FUnits.Count - 1 do
  begin
    U := TKyzuUnit(FUnits.Objects[i]);
    if (U.Owner = FFaction) and (U.UnitType = 'soldier') then
    begin
      Inc(MySoldierCount);
      FlockCenterLon := FlockCenterLon + U.Lon;
      FlockCenterLat := FlockCenterLat + U.Lat;
    end;
  end;

  if MySoldierCount > 0 then
  begin
    FlockCenterLon := FlockCenterLon / MySoldierCount;
    FlockCenterLat := FlockCenterLat / MySoldierCount;
  end;

  if MySoldierCount < Genome.SpawnQuota then
  begin
    SpawnPayload := TJSONObject.Create;
    SpawnPayload.Strings['unit_id'] := GenerateID('u');
    SpawnPayload.Floats['lon'] := FHomeLon;
    SpawnPayload.Floats['lat'] := FHomeLat;
    SpawnPayload.Strings['owner'] := FFaction;
    SpawnPayload.Strings['unit_type'] := 'soldier';
    Publish('game.cmd.spawn', SpawnPayload);
  end;

  // 2. Tactical evaluation per active unit
  for i := 0 to FUnits.Count - 1 do
  begin
    U := TKyzuUnit(FUnits.Objects[i]);
    if (U.Owner <> FFaction) or (U.UnitType <> 'soldier') then Continue;

    // Tactical Retreat behavior based on genome threshold
    if (U.MaxHP > 0) and ((U.HP / U.MaxHP) < Genome.RetreatHPRatio) then
    begin
      ActionPayload := TJSONObject.Create;
      ActionPayload.Strings['unit_id'] := U.ID;
      ActionPayload.Floats['to_lon'] := FHomeLon;
      ActionPayload.Floats['to_lat'] := FHomeLat;
      ActionPayload.Strings['by'] := FFaction;
      Publish('game.cmd.move', ActionPayload);
      Continue;
    end;

    // Predictive Threat Assessment & Target Selection
    BestUnitID := '';
    BestUnitScore := -1e9;

    for j := 0 to FUnits.Count - 1 do
    begin
      TargetU := TKyzuUnit(FUnits.Objects[j]);
      if (TargetU.Owner = FFaction) or (TargetU.Owner = '') then Continue;

      Dist := EuclideanDist(U.Lon, U.Lat, TargetU.Lon, TargetU.Lat);
      // Utility score: inverse distance, low target HP bonus, aggression factor
      Score := (100.0 / Max(0.5, Dist)) + ((TargetU.MaxHP - TargetU.HP) * 0.5) * Genome.AggressionFactor;
      if Score > BestUnitScore then
      begin
        BestUnitScore := Score;
        BestUnitID := TargetU.ID;
      end;
    end;

    // City conquest evaluation
    BestCityID := '';
    BestCityScore := -1e9;

    for j := 0 to FCities.Count - 1 do
    begin
      C := TKyzuCity(FCities.Objects[j]);
      if C.Owner = FFaction then Continue;

      Dist := EuclideanDist(U.Lon, U.Lat, C.Lon, C.Lat);
      Score := ((120.0 / Max(0.5, Dist)) + (C.Population * 10.0)) * Genome.CityCaptureBias;
      if Score > BestCityScore then
      begin
        BestCityScore := Score;
        BestCityID := C.ID;
      end;
    end;

    // Determine target selection based on evolved weights
    if (BestUnitID <> '') and (BestUnitScore >= BestCityScore) then
    begin
      Idx := FUnits.IndexOf(BestUnitID);
      TargetU := TKyzuUnit(FUnits.Objects[Idx]);
      Dist := EuclideanDist(U.Lon, U.Lat, TargetU.Lon, TargetU.Lat);

      if Dist <= 1.5 then
      begin
        // Attack range: strike target
        ActionPayload := TJSONObject.Create;
        ActionPayload.Strings['attacker_unit_id'] := U.ID;
        ActionPayload.Strings['target_unit_id'] := BestUnitID;
        ActionPayload.Strings['by'] := FFaction;
        Publish('game.cmd.attack', ActionPayload);
      end
      else
      begin
        // Predictive Intercept: Compute anticipatory vector
        Intercept := FPredictor.CalculateAnticipatoryIntercept(U.Lon, U.Lat, 1.2, BestUnitID,
                                                               Genome.PredictiveLookahead * SurpriseMod);
        
        // Cohesion bias: Blend movement toward intercept with flocking center
        TargetLon := (Intercept.X * 0.8) + (FlockCenterLon * 0.2 * Genome.FlockingCohesion);
        TargetLat := (Intercept.Y * 0.8) + (FlockCenterLat * 0.2 * Genome.FlockingCohesion);

        ActionPayload := TJSONObject.Create;
        ActionPayload.Strings['unit_id'] := U.ID;
        ActionPayload.Floats['to_lon'] := TargetLon;
        ActionPayload.Floats['to_lat'] := TargetLat;
        ActionPayload.Strings['by'] := FFaction;
        Publish('game.cmd.move', ActionPayload);
      end;
    end
    else if BestCityID <> '' then
    begin
      Idx := FCities.IndexOf(BestCityID);
      C := TKyzuCity(FCities.Objects[Idx]);
      Dist := EuclideanDist(U.Lon, U.Lat, C.Lon, C.Lat);

      if Dist <= 1.5 then
      begin
        ActionPayload := TJSONObject.Create;
        ActionPayload.Strings['attacker_unit_id'] := U.ID;
        ActionPayload.Strings['target_city_id'] := BestCityID;
        ActionPayload.Strings['by'] := FFaction;
        Publish('game.cmd.attack', ActionPayload);
      end
      else
      begin
        ActionPayload := TJSONObject.Create;
        ActionPayload.Strings['unit_id'] := U.ID;
        ActionPayload.Floats['to_lon'] := C.Lon;
        ActionPayload.Floats['to_lat'] := C.Lat;
        ActionPayload.Strings['by'] := FFaction;
        Publish('game.cmd.move', ActionPayload);
      end;
    end;
  end;
end;

end.
```

---

### 6. `KyzuAIProgram.lpr` (Main Program Entry Point)
```pascal
program KyzuAIProgram;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads, BaseUnix,
  {$ENDIF}
  Classes, SysUtils,
  KyzuSockets, KyzuEntities, KyzuPredictive, KyzuGenetics, KyzuBrain;

var
  WSClient: TWebSocketClient;
  Brain: TKyzuBrain;
  HostStr: string;
  PortNum: Word;
  FactionName: string;
  HomeLon, HomeLat: Double;
  LastDecisionTick: QWord;

procedure OnWSMessage(const AMessage: string);
begin
  Brain.ProcessMessage(AMessage);
end;

procedure OnWSEvent(AEventType: TWSEventType; const AInfo: string);
begin
  case AEventType of
    wseOpen:
    begin
      Writeln('[WS] Connected. Sending authentication token...');
      WSClient.SendText('{"method":"sys.auth","token":"bot"}');
    end;
    wseClose: Writeln('[WS] Disconnected: ' + AInfo);
    wseError: Writeln('[WS] Network Error: ' + AInfo);
  end;
end;

procedure ParseCommandLine(out Host: string; out Port: Word; out Faction: string);
var
  RawURL: string;
  ColPos: Integer;
begin
  RawURL := '127.0.0.1:8181';
  Faction := 'evolved_predator';

  if ParamCount >= 1 then RawURL := ParamStr(1);
  if ParamCount >= 2 then Faction := ParamStr(2);

  // Strip ws:// if present
  if Pos('ws://', RawURL) = 1 then
    Delete(RawURL, 1, 5);

  ColPos := Pos(':', RawURL);
  if ColPos > 0 then
  begin
    Host := Copy(RawURL, 1, ColPos - 1);
    Port := StrToIntDef(Copy(RawURL, ColPos + 1, Length(RawURL)), 8181);
  end
  else
  begin
    Host := RawURL;
    Port := 8181;
  end;
end;

begin
  Randomize;
  ParseCommandLine(HostStr, PortNum, FactionName);
  HomeLon := 22.0;
  HomeLat := 14.0;

  Writeln('====================================================');
  Writeln(' Kyzu Autonomous AI - Predictive Coding & Genetic Evo');
  Writeln(Format(' Target: ws://%s:%d | Faction: %s', [HostStr, PortNum, FactionName]));
  Writeln('====================================================');

  WSClient := TWebSocketClient.Create;
  Brain := TKyzuBrain.Create(WSClient, FactionName, HomeLon, HomeLat);
  try
    WSClient.OnMessage := @OnWSMessage;
    WSClient.OnEvent := @OnWSEvent;

    LastDecisionTick := GetTickCount64;

    while True do
    begin
      if not WSClient.Connected then
      begin
        Writeln(Format('[SYSTEM] Connecting to %s:%d ...', [HostStr, PortNum]));
        if not WSClient.Connect(HostStr, PortNum) then
          Sleep(2500);
      end;

      if WSClient.Connected then
      begin
        // Process network I/O
        WSClient.Poll(50);

        // Run cognitive cycle every 1000ms
        if (GetTickCount64 - LastDecisionTick) >= 1000 then
        begin
          if WSClient.HandshakeDone then
            Brain.ThinkAndAct;
          LastDecisionTick := GetTickCount64;
        end;
      end
      else
        Sleep(500);
    end;

  finally
    Brain.Free;
    WSClient.Free;
  end;
end.
```

---

### Compilation & Running Instructions

This implementation relies **strictly** on standard FreePascal units (`fcl-json`, `fcl-net`, and core RTL sockets). It requires no external libraries.

#### On Linux (x86_64 / aarch64)
```bash
fpc -O2 -gl -Fu. KyzuAIProgram.lpr
./KyzuAIProgram ws://127.0.0.1:8181 predator_bot
```

#### On Windows (Win64)
```cmd
fpc -O2 -gl -Fu. -dWINDOWS KyzuAIProgram.lpr
KyzuAIProgram.exe ws://127.0.0.1:8181 predator_bot
```
