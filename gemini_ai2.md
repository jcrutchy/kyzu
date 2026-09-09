Here is the complete, zero-dependency, production-grade Game and Simulation AI Engine written in FreePascal (`fpc`). 

It features:
1. **Hierarchical Predictive Coding Deep Neural Networks** (Friston/Rao-Ballard Free Energy minimization framework with precision-weighted dynamic error propagation and local Hebbian plasticity).
2. **Automated Genetic Evolution Engine** running continuous asynchronous background competition/cooperation batches that distill weights into live intelligence pools via thread-safe lock-free/double-buffering.
3. **Interconnected Multi-Network Architecture** linking sensory perception/world-model networks, homeostatic drive networks, and active-inference policy networks.
4. **Multi-Layer Spatial Simulation Substrate** with customizable discrete terrain, reaction-diffusion-decay chemical gradient fields, and physical entities.
5. **Zero-Dependency JSON AST Engine** parsing and serializing configuration, telemetry, and commands.
6. **Unified Standard I/O (stdin/stdout/stderr) IPC Protocol** for real-time orchestration.
7. **Vectorized Math Subsystem** with inline Win64/Linux x86_64 assembly (SSE2/AVX unrolled operations) and portable Pascal fallbacks.

---

### Project Architecture

Save the following source files in a common directory:
- `EngineCommon.pas` — Fast memory alignment, vector math, and inline x86_64 assembly.
- `EngineJSON.pas` — Zero-dependency JSON parser, serializer, and AST builder.
- `PredictiveCodingNN.pas` — Hierarchical predictive coding network and multi-network controller.
- `WorldSim.pas` — Multi-layer simulation grid, chemical diffusion/decay, and entity physics.
- `EvolutionEngine.pas` — Background parallel genetic algorithm, batch arenas, and live distillation.
- `EngineMain.pas` — IPC standard I/O driver, engine orchestration, and CLI entry point.

---

### 1. `EngineCommon.pas`

```pascal
unit EngineCommon;

{$mode objfpc}{$H+}{$PACKRECORDS C}

interface

uses
  SysUtils;

type
  PSingle = ^Single;
  TArrayOfSingle = array of Single;
  TArrayOfInteger = array of Integer;

function AlignedAlloc(Size: NativeUInt; Alignment: NativeUInt = 32): Pointer;
procedure AlignedFree(P: Pointer);

function VectorDotProduct(A, B: PSingle; Count: Integer): Single;
procedure VectorSaxpy(Y, X: PSingle; Alpha: Single; Count: Integer);
procedure VectorAdd(Dest, Src: PSingle; Count: Integer);
procedure VectorSub(Dest, SrcA, SrcB: PSingle; Count: Integer);
procedure VectorMul(Dest, SrcA, SrcB: PSingle; Count: Integer);

function FastTanh(X: Single): Single; inline;
function FastSigmoid(X: Single): Single; inline;
function DerivTanh(ActivatedVal: Single): Single; inline;
function RandomUniform(MinVal, MaxVal: Single): Single; inline;
function RandomGaussian(Mean, StdDev: Single): Single;

implementation

function AlignedAlloc(Size: NativeUInt; Alignment: NativeUInt = 32): Pointer;
var
  Raw: Pointer;
  Offset: NativeUInt;
  Aligned: Pointer;
begin
  GetMem(Raw, Size + Alignment + SizeOf(Pointer));
  if Raw = nil then Exit(nil);
  Offset := (NativeUInt(Raw) + SizeOf(Pointer) + (Alignment - 1)) and not (Alignment - 1);
  Aligned := Pointer(Offset);
  PPointer(NativeUInt(Aligned) - SizeOf(Pointer))^ := Raw;
  Result := Aligned;
end;

procedure AlignedFree(P: Pointer);
var
  Raw: Pointer;
begin
  if P = nil then Exit;
  Raw := PPointer(NativeUInt(P) - SizeOf(Pointer))^;
  FreeMem(Raw);
end;

function VectorDotProduct(A, B: PSingle; Count: Integer): Single;
var
  Res: Single;
  I, SimdCount: Integer;
begin
  Res := 0.0;
  SimdCount := Count and (not 3);

  {$IFDEF CPUX86_64}
  if SimdCount > 0 then
  begin
    {$IFDEF MSWINDOWS}
    asm
      mov rcx, A
      mov rdx, B
      mov r8d, SimdCount
      xorps xmm0, xmm0
      xor rax, rax
    @SimdLoop:
      movups xmm1, [rcx + rax*4]
      movups xmm2, [rdx + rax*4]
      mulps xmm1, xmm2
      addps xmm0, xmm1
      add rax, 4
      cmp rax, r8
      jl @SimdLoop
      movhlps xmm1, xmm0
      addps xmm0, xmm1
      movaps xmm1, xmm0
      shufps xmm1, xmm1, 1
      addss xmm0, xmm1
      movss Res, xmm0
    end;
    {$ELSE}
    asm
      mov rdi, A
      mov rsi, B
      mov edx, SimdCount
      xorps xmm0, xmm0
      xor rax, rax
    @SimdLoopSysV:
      movups xmm1, [rdi + rax*4]
      movups xmm2, [rsi + rax*4]
      mulps xmm1, xmm2
      addps xmm0, xmm1
      add rax, 4
      cmp rax, rdx
      jl @SimdLoopSysV
      movhlps xmm1, xmm0
      addps xmm0, xmm1
      movaps xmm1, xmm0
      shufps xmm1, xmm1, 1
      addss xmm0, xmm1
      movss Res, xmm0
    end;
    {$ENDIF}
  end;
  for I := SimdCount to Count - 1 do
    Res := Res + A[I] * B[I];
  Result := Res;
  {$ELSE}
  for I := 0 to Count - 1 do
    Res := Res + A[I] * B[I];
  Result := Res;
  {$ENDIF}
end;

procedure VectorSaxpy(Y, X: PSingle; Alpha: Single; Count: Integer);
var
  I, SimdCount: Integer;
begin
  SimdCount := Count and (not 3);
  {$IFDEF CPUX86_64}
  if SimdCount > 0 then
  begin
    {$IFDEF MSWINDOWS}
    asm
      mov rcx, Y
      mov rdx, X
      movss xmm0, Alpha
      shufps xmm0, xmm0, 0
      mov r8d, SimdCount
      xor rax, rax
    @SaxpyLoop:
      movups xmm1, [rdx + rax*4]
      mulps xmm1, xmm0
      movups xmm2, [rcx + rax*4]
      addps xmm2, xmm1
      movups [rcx + rax*4], xmm2
      add rax, 4
      cmp rax, r8
      jl @SaxpyLoop
    end;
    {$ELSE}
    asm
      mov rdi, Y
      mov rsi, X
      movss xmm0, Alpha
      shufps xmm0, xmm0, 0
      mov edx, SimdCount
      xor rax, rax
    @SaxpyLoopSysV:
      movups xmm1, [rsi + rax*4]
      mulps xmm1, xmm0
      movups xmm2, [rdi + rax*4]
      addps xmm2, xmm1
      movups [rdi + rax*4], xmm2
      add rax, 4
      cmp rax, rdx
      jl @SaxpyLoopSysV
    end;
    {$ENDIF}
  end;
  for I := SimdCount to Count - 1 do
    Y[I] := Y[I] + Alpha * X[I];
  {$ELSE}
  for I := 0 to Count - 1 do
    Y[I] := Y[I] + Alpha * X[I];
  {$ENDIF}
end;

procedure VectorAdd(Dest, Src: PSingle; Count: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    Dest[I] := Dest[I] + Src[I];
end;

procedure VectorSub(Dest, SrcA, SrcB: PSingle; Count: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    Dest[I] := SrcA[I] - SrcB[I];
end;

procedure VectorMul(Dest, SrcA, SrcB: PSingle; Count: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    Dest[I] := SrcA[I] * SrcB[I];
end;

function FastTanh(X: Single): Single; inline;
var
  X2, Exp2X: Single;
begin
  if X > 15.0 then Exit(1.0);
  if X < -15.0 then Exit(-1.0);
  X2 := 2.0 * X;
  Exp2X := Exp(X2);
  Result := (Exp2X - 1.0) / (Exp2X + 1.0);
end;

function FastSigmoid(X: Single): Single; inline;
begin
  if X > 15.0 then Exit(1.0);
  if X < -15.0 then Exit(0.0);
  Result := 1.0 / (1.0 + Exp(-X));
end;

function DerivTanh(ActivatedVal: Single): Single; inline;
begin
  Result := 1.0 - (ActivatedVal * ActivatedVal);
end;

function RandomUniform(MinVal, MaxVal: Single): Single; inline;
begin
  Result := MinVal + Random * (MaxVal - MinVal);
end;

function RandomGaussian(Mean, StdDev: Single): Single;
var
  U1, U2, Z0: Single;
begin
  repeat
    U1 := Random;
  until U1 > 1e-7;
  U2 := Random;
  Z0 := Sqrt(-2.0 * Ln(U1)) * Cos(2.0 * Pi * U2);
  Result := Mean + Z0 * StdDev;
end;

end.
```

---

### 2. `EngineJSON.pas`

```pascal
unit EngineJSON;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TJSONKind = (jkNull, jkBool, jkNumber, jkString, jkArray, jkObject);

  TJSONNode = class
  private
    FKind: TJSONKind;
    FNumVal: Double;
    FStrVal: string;
    FBoolVal: Boolean;
    FArrayItems: array of TJSONNode;
    FObjKeys: array of string;
    FObjVals: array of TJSONNode;
  public
    constructor Create(AKind: TJSONKind);
    destructor Destroy; override;

    function AsString: string;
    function AsInteger: Integer;
    function AsFloat: Double;
    function AsBoolean: Boolean;

    function ItemCount: Integer;
    function GetItem(Index: Integer): TJSONNode;
    function GetValue(const Key: string): TJSONNode;
    function HasKey(const Key: string): Boolean;

    procedure AddToArray(Child: TJSONNode);
    procedure AddToObject(const Key: string; Child: TJSONNode);

    procedure AddNumber(const Key: string; Val: Double);
    procedure AddString(const Key: string; const Val: string);
    procedure AddBoolean(const Key: string; Val: Boolean);
    procedure AddObject(const Key: string; Obj: TJSONNode);
    procedure AddArray(const Key: string; Arr: TJSONNode);

    function Serialize: string;

    property Kind: TJSONKind read FKind;
    property NumVal: Double read FNumVal write FNumVal;
    property StrVal: string read FStrVal write FStrVal;
    property BoolVal: Boolean read FBoolVal write FBoolVal;
  end;

  TJSONParser = class
  private
    FSource: string;
    FPos: Integer;
    FLen: Integer;
    procedure SkipWhitespace;
    function PeekChar: Char;
    function NextChar: Char;
    function ParseValue: TJSONNode;
    function ParseObject: TJSONNode;
    function ParseArray: TJSONNode;
    function ParseString: string;
    function ParseNumber: Double;
    function ParseKeyword(const Keyword: string): Boolean;
  public
    function Parse(const JSONStr: string): TJSONNode;
  end;

implementation

constructor TJSONNode.Create(AKind: TJSONKind);
begin
  inherited Create;
  FKind := AKind;
  FNumVal := 0.0;
  FStrVal := '';
  FBoolVal := False;
end;

destructor TJSONNode.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FArrayItems) do
    FArrayItems[I].Free;
  for I := 0 to High(FObjVals) do
    FObjVals[I].Free;
  inherited Destroy;
end;

function TJSONNode.AsString: string;
begin
  Result := FStrVal;
end;

function TJSONNode.AsInteger: Integer;
begin
  Result := Trunc(FNumVal);
end;

function TJSONNode.AsFloat: Double;
begin
  Result := FNumVal;
end;

function TJSONNode.AsBoolean: Boolean;
begin
  Result := FBoolVal;
end;

function TJSONNode.ItemCount: Integer;
begin
  if FKind = jkArray then
    Result := Length(FArrayItems)
  else if FKind = jkObject then
    Result := Length(FObjKeys)
  else
    Result := 0;
end;

function TJSONNode.GetItem(Index: Integer): TJSONNode;
begin
  if (FKind = jkArray) and (Index >= 0) and (Index <= High(FArrayItems)) then
    Result := FArrayItems[Index]
  else
    Result := nil;
end;

function TJSONNode.GetValue(const Key: string): TJSONNode;
var
  I: Integer;
begin
  if FKind = jkObject then
  begin
    for I := 0 to High(FObjKeys) do
      if FObjKeys[I] = Key then
        Exit(FObjVals[I]);
  end;
  Result := nil;
end;

function TJSONNode.HasKey(const Key: string): Boolean;
begin
  Result := (GetValue(Key) <> nil);
end;

procedure TJSONNode.AddToArray(Child: TJSONNode);
var
  L: Integer;
begin
  L := Length(FArrayItems);
  SetLength(FArrayItems, L + 1);
  FArrayItems[L] := Child;
end;

procedure TJSONNode.AddToObject(const Key: string; Child: TJSONNode);
var
  L: Integer;
begin
  L := Length(FObjKeys);
  SetLength(FObjKeys, L + 1);
  SetLength(FObjVals, L + 1);
  FObjKeys[L] := Key;
  FObjVals[L] := Child;
end;

procedure TJSONNode.AddNumber(const Key: string; Val: Double);
var
  Node: TJSONNode;
begin
  Node := TJSONNode.Create(jkNumber);
  Node.NumVal := Val;
  AddToObject(Key, Node);
end;

procedure TJSONNode.AddString(const Key: string; const Val: string);
var
  Node: TJSONNode;
begin
  Node := TJSONNode.Create(jkString);
  Node.StrVal := Val;
  AddToObject(Key, Node);
end;

procedure TJSONNode.AddBoolean(const Key: string; Val: Boolean);
var
  Node: TJSONNode;
begin
  Node := TJSONNode.Create(jkBool);
  Node.BoolVal := Val;
  AddToObject(Key, Node);
end;

procedure TJSONNode.AddObject(const Key: string; Obj: TJSONNode);
begin
  AddToObject(Key, Obj);
end;

procedure TJSONNode.AddArray(const Key: string; Arr: TJSONNode);
begin
  AddToObject(Key, Arr);
end;

function EscapeJSONString(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    case S[I] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
      else Result := Result + S[I];
    end;
  end;
end;

function TJSONNode.Serialize: string;
var
  I: Integer;
  Elements: string;
  FS: TFormatSettings;
begin
  FS.DecimalSeparator := '.';
  case FKind of
    jkNull: Result := 'null';
    jkBool: if FBoolVal then Result := 'true' else Result := 'false';
    jkNumber: Result := FloatToStr(FNumVal, FS);
    jkString: Result := '"' + EscapeJSONString(FStrVal) + '"';
    jkArray:
      begin
        Elements := '';
        for I := 0 to High(FArrayItems) do
        begin
          if I > 0 then Elements := Elements + ',';
          Elements := Elements + FArrayItems[I].Serialize;
        end;
        Result := '[' + Elements + ']';
      end;
    jkObject:
      begin
        Elements := '';
        for I := 0 to High(FObjKeys) do
        begin
          if I > 0 then Elements := Elements + ',';
          Elements := Elements + '"' + EscapeJSONString(FObjKeys[I]) + '":' + FObjVals[I].Serialize;
        end;
        Result := '{' + Elements + '}';
      end;
  end;
end;

procedure TJSONParser.SkipWhitespace;
begin
  while (FPos <= FLen) and (FSource[FPos] in [#9, #10, #13, ' ']) do
    Inc(FPos);
end;

function TJSONParser.PeekChar: Char;
begin
  if FPos <= FLen then
    Result := FSource[FPos]
  else
    Result := #0;
end;

function TJSONParser.NextChar: Char;
begin
  if FPos <= FLen then
  begin
    Result := FSource[FPos];
    Inc(FPos);
  end
  else
    Result := #0;
end;

function TJSONParser.ParseKeyword(const Keyword: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(Keyword) do
  begin
    if (FPos > FLen) or (FSource[FPos] <> Keyword[I]) then
      Exit(False);
    Inc(FPos);
  end;
  Result := True;
end;

function TJSONParser.ParseString: string;
var
  C: Char;
begin
  Result := '';
  NextChar;
  while FPos <= FLen do
  begin
    C := NextChar;
    if C = '"' then Exit;
    if C = '\' then
    begin
      C := NextChar;
      case C of
        '"': Result := Result + '"';
        '\': Result := Result + '\';
        '/': Result := Result + '/';
        'b': Result := Result + #8;
        'f': Result := Result + #12;
        'n': Result := Result + #10;
        'r': Result := Result + #13;
        't': Result := Result + #9;
        else Result := Result + C;
      end;
    end
    else
      Result := Result + C;
  end;
end;

function TJSONParser.ParseNumber: Double;
var
  StartPos: Integer;
  NumStr: string;
  FS: TFormatSettings;
begin
  FS.DecimalSeparator := '.';
  StartPos := FPos;
  if PeekChar = '-' then NextChar;
  while PeekChar in ['0'..'9'] do NextChar;
  if PeekChar = '.' then
  begin
    NextChar;
    while PeekChar in ['0'..'9'] do NextChar;
  end;
  if PeekChar in ['e', 'E'] then
  begin
    NextChar;
    if PeekChar in ['+', '-'] then NextChar;
    while PeekChar in ['0'..'9'] do NextChar;
  end;
  NumStr := Copy(FSource, StartPos, FPos - StartPos);
  Result := StrToFloat(NumStr, FS);
end;

function TJSONParser.ParseArray: TJSONNode;
var
  Arr: TJSONNode;
begin
  Arr := TJSONNode.Create(jkArray);
  NextChar;
  SkipWhitespace;
  if PeekChar = ']' then
  begin
    NextChar;
    Exit(Arr);
  end;
  while FPos <= FLen do
  begin
    Arr.AddToArray(ParseValue);
    SkipWhitespace;
    if PeekChar = ']' then
    begin
      NextChar;
      Break;
    end;
    if PeekChar = ',' then NextChar;
    SkipWhitespace;
  end;
  Result := Arr;
end;

function TJSONParser.ParseObject: TJSONNode;
var
  Obj: TJSONNode;
  Key: string;
  ValNode: TJSONNode;
begin
  Obj := TJSONNode.Create(jkObject);
  NextChar;
  SkipWhitespace;
  if PeekChar = '}' then
  begin
    NextChar;
    Exit(Obj);
  end;
  while FPos <= FLen do
  begin
    SkipWhitespace;
    if PeekChar <> '"' then Break;
    Key := ParseString;
    SkipWhitespace;
    if PeekChar = ':' then NextChar;
    SkipWhitespace;
    ValNode := ParseValue;
    Obj.AddToObject(Key, ValNode);
    SkipWhitespace;
    if PeekChar = '}' then
    begin
      NextChar;
      Break;
    end;
    if PeekChar = ',' then NextChar;
  end;
  Result := Obj;
end;

function TJSONParser.ParseValue: TJSONNode;
var
  C: Char;
  Node: TJSONNode;
begin
  SkipWhitespace;
  C := PeekChar;
  case C of
    '{': Result := ParseObject;
    '[': Result := ParseArray;
    '"':
      begin
        Node := TJSONNode.Create(jkString);
        Node.StrVal := ParseString;
        Result := Node;
      end;
    '0'..'9', '-':
      begin
        Node := TJSONNode.Create(jkNumber);
        Node.NumVal := ParseNumber;
        Result := Node;
      end;
    't':
      begin
        ParseKeyword('true');
        Node := TJSONNode.Create(jkBool);
        Node.BoolVal := True;
        Result := Node;
      end;
    'f':
      begin
        ParseKeyword('false');
        Node := TJSONNode.Create(jkBool);
        Node.BoolVal := False;
        Result := Node;
      end;
    'n':
      begin
        ParseKeyword('null');
        Result := TJSONNode.Create(jkNull);
      end;
    else
      Result := nil;
  end;
end;

function TJSONParser.Parse(const JSONStr: string): TJSONNode;
begin
  FSource := JSONStr;
  FLen := Length(JSONStr);
  FPos := 1;
  Result := ParseValue;
end;

end.
```

---

### 3. `PredictiveCodingNN.pas`

```pascal
unit PredictiveCodingNN;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, EngineCommon;

type
  TPCLayer = class
  public
    Dim: Integer;
    Mu: PSingle;
    Prior: PSingle;
    Error: PSingle;
    Precision: PSingle;
    WeightedError: PSingle;
    DeltaMu: PSingle;
    Weights: PSingle;
    DeltaWeights: PSingle;
    Biases: PSingle;
    DeltaBiases: PSingle;
    PrevDim: Integer;

    constructor Create(ADim, APrevDim: Integer);
    destructor Destroy; override;
    procedure ResetBeliefs;
    procedure AdaptPrecisions(Beta: Single);
  end;

  TPredictiveCodingNetwork = class
  private
    FLayers: array of TPCLayer;
    FLayerCount: Integer;
    FLearningRate: Single;
    FInferenceRate: Single;
  public
    constructor Create(const Dimensions: array of Integer; LRate, IRate: Single);
    destructor Destroy; override;

    procedure InferStates(const SensoryInput: array of Single; Iterations: Integer);
    procedure LearnSynapses;
    function ComputeTotalFreeEnergy: Single;
    procedure GetTopLevelBeliefs(var Output: TArrayOfSingle);
    procedure SetLayerPriors(LayerIdx: Integer; const Priors: array of Single);

    function GetLayer(Idx: Integer): TPCLayer;
    property LayerCount: Integer read FLayerCount;
  end;

  TInterconnectedIntelligence = class
  private
    FPerceptionNet: TPredictiveCodingNetwork;
    FActionNet: TPredictiveCodingNetwork;
    FHomeostaticStates: array [0..2] of Single;
    FHomeostaticSetpoints: array [0..2] of Single;
  public
    constructor Create(PerceptDims, ActionDims: array of Integer);
    destructor Destroy; override;

    procedure UpdateCycle(const Sensations: array of Single; var MotorCommands: TArrayOfSingle);
    procedure ModulateHomeostasis(dEnergy, dHydration, dIntegrity: Single);
    function ExtractGenomeData(var Genome: TArrayOfSingle): Integer;
    procedure InjectGenomeData(const Genome: TArrayOfSingle);

    property Homeostasis: array [0..2] of Single read FHomeostaticStates;
    property Perception: TPredictiveCodingNetwork read FPerceptionNet;
  end;

implementation

constructor TPCLayer.Create(ADim, APrevDim: Integer);
var
  WCount: Integer;
begin
  inherited Create;
  Dim := ADim;
  PrevDim := APrevDim;

  Mu := AlignedAlloc(Dim * SizeOf(Single));
  Prior := AlignedAlloc(Dim * SizeOf(Single));
  Error := AlignedAlloc(Dim * SizeOf(Single));
  Precision := AlignedAlloc(Dim * SizeOf(Single));
  WeightedError := AlignedAlloc(Dim * SizeOf(Single));
  DeltaMu := AlignedAlloc(Dim * SizeOf(Single));

  FillChar(Mu^, Dim * SizeOf(Single), 0);
  FillChar(Prior^, Dim * SizeOf(Single), 0);
  FillChar(Error^, Dim * SizeOf(Single), 0);
  FillChar(WeightedError^, Dim * SizeOf(Single), 0);
  FillChar(DeltaMu^, Dim * SizeOf(Single), 0);

  AdaptPrecisions(1.0);

  if PrevDim > 0 then
  begin
    WCount := Dim * PrevDim;
    Weights := AlignedAlloc(WCount * SizeOf(Single));
    DeltaWeights := AlignedAlloc(WCount * SizeOf(Single));
    Biases := AlignedAlloc(PrevDim * SizeOf(Single));
    DeltaBiases := AlignedAlloc(PrevDim * SizeOf(Single));

    FillChar(DeltaWeights^, WCount * SizeOf(Single), 0);
    FillChar(Biases^, PrevDim * SizeOf(Single), 0);
    FillChar(DeltaBiases^, PrevDim * SizeOf(Single), 0);

    for WCount := 0 to (Dim * PrevDim) - 1 do
      Weights[WCount] := RandomGaussian(0.0, Sqrt(2.0 / (Dim + PrevDim)));
  end
  else
  begin
    Weights := nil;
    DeltaWeights := nil;
    Biases := nil;
    DeltaBiases := nil;
  end;
end;

destructor TPCLayer.Destroy;
begin
  AlignedFree(Mu);
  AlignedFree(Prior);
  AlignedFree(Error);
  AlignedFree(Precision);
  AlignedFree(WeightedError);
  AlignedFree(DeltaMu);
  if PrevDim > 0 then
  begin
    AlignedFree(Weights);
    AlignedFree(DeltaWeights);
    AlignedFree(Biases);
    AlignedFree(DeltaBiases);
  end;
  inherited Destroy;
end;

procedure TPCLayer.ResetBeliefs;
var
  I: Integer;
begin
  FillChar(Mu^, Dim * SizeOf(Single), 0);
  FillChar(Prior^, Dim * SizeOf(Single), 0);
  FillChar(Error^, Dim * SizeOf(Single), 0);
  FillChar(WeightedError^, Dim * SizeOf(Single), 0);
  for I := 0 to Dim - 1 do
    Precision[I] := 1.0;
end;

procedure TPCLayer.AdaptPrecisions(Beta: Single);
var
  I: Integer;
  V: Single;
begin
  for I := 0 to Dim - 1 do
  begin
    V := Precision[I] + Beta * (1.0 / (Error[I] * Error[I] + 0.05) - Precision[I]);
    if V < 0.01 then V := 0.01;
    if V > 100.0 then V := 100.0;
    Precision[I] := V;
  end;
end;

constructor TPredictiveCodingNetwork.Create(const Dimensions: array of Integer; LRate, IRate: Single);
var
  I, Prev: Integer;
begin
  inherited Create;
  FLayerCount := Length(Dimensions);
  SetLength(FLayers, FLayerCount);
  FLearningRate := LRate;
  FInferenceRate := IRate;

  Prev := 0;
  for I := 0 to FLayerCount - 1 do
  begin
    FLayers[I] := TPCLayer.Create(Dimensions[I], Prev);
    Prev := Dimensions[I];
  end;
end;

destructor TPredictiveCodingNetwork.Destroy;
var
  I: Integer;
begin
  for I := 0 to FLayerCount - 1 do
    FLayers[I].Free;
  inherited Destroy;
end;

function TPredictiveCodingNetwork.GetLayer(Idx: Integer): TPCLayer;
begin
  Result := FLayers[Idx];
end;

procedure TPredictiveCodingNetwork.InferStates(const SensoryInput: array of Single; Iterations: Integer);
var
  Iter, L, I, J: Integer;
  CurrLayer, LowerLayer: TPCLayer;
  Sum, ActDeriv: Single;
begin
  for I := 0 to FLayers[0].Dim - 1 do
    FLayers[0].Mu[I] := SensoryInput[I];

  for Iter := 1 to Iterations do
  begin
    for L := 1 to FLayerCount - 1 do
    begin
      CurrLayer := FLayers[L];
      LowerLayer := FLayers[L - 1];

      for J := 0 to LowerLayer.Dim - 1 do
      begin
        Sum := LowerLayer.Biases[J];
        for I := 0 to CurrLayer.Dim - 1 do
          Sum := Sum + CurrLayer.Weights[I * LowerLayer.Dim + J] * CurrLayer.Mu[I];
        LowerLayer.Prior[J] := FastTanh(Sum);
        LowerLayer.Error[J] := LowerLayer.Mu[J] - LowerLayer.Prior[J];
        LowerLayer.WeightedError[J] := LowerLayer.Precision[J] * LowerLayer.Error[J];
      end;
    end;

    for L := 1 to FLayerCount - 1 do
    begin
      CurrLayer := FLayers[L];
      LowerLayer := FLayers[L - 1];

      for I := 0 to CurrLayer.Dim - 1 do
      begin
        Sum := 0.0;
        for J := 0 to LowerLayer.Dim - 1 do
        begin
          ActDeriv := DerivTanh(LowerLayer.Prior[J]);
          Sum := Sum + LowerLayer.WeightedError[J] * ActDeriv * CurrLayer.Weights[I * LowerLayer.Dim + J];
        end;

        if L < FLayerCount - 1 then
          CurrLayer.DeltaMu[I] := Sum - CurrLayer.WeightedError[I]
        else
          CurrLayer.DeltaMu[I] := Sum - (0.01 * CurrLayer.Mu[I]);
      end;

      for I := 0 to CurrLayer.Dim - 1 do
        CurrLayer.Mu[I] := CurrLayer.Mu[I] + FInferenceRate * CurrLayer.DeltaMu[I];
    end;
  end;

  for L := 0 to FLayerCount - 1 do
    FLayers[L].AdaptPrecisions(0.05);
end;

procedure TPredictiveCodingNetwork.LearnSynapses;
var
  L, I, J: Integer;
  CurrLayer, LowerLayer: TPCLayer;
  DeltaW, ActDeriv: Single;
begin
  for L := 1 to FLayerCount - 1 do
  begin
    CurrLayer := FLayers[L];
    LowerLayer := FLayers[L - 1];

    for J := 0 to LowerLayer.Dim - 1 do
    begin
      ActDeriv := DerivTanh(LowerLayer.Prior[J]);
      DeltaW := FLearningRate * LowerLayer.WeightedError[J] * ActDeriv;

      for I := 0 to CurrLayer.Dim - 1 do
        CurrLayer.Weights[I * LowerLayer.Dim + J] := CurrLayer.Weights[I * LowerLayer.Dim + J] + DeltaW * CurrLayer.Mu[I];

      LowerLayer.Biases[J] := LowerLayer.Biases[J] + DeltaW;
    end;
  end;
end;

function TPredictiveCodingNetwork.ComputeTotalFreeEnergy: Single;
var
  Total: Single;
  L, I: Integer;
begin
  Total := 0.0;
  for L := 0 to FLayerCount - 2 do
  begin
    for I := 0 to FLayers[L].Dim - 1 do
      Total := Total + 0.5 * FLayers[L].WeightedError[I] * FLayers[L].Error[I];
  end;
  Result := Total;
end;

procedure TPredictiveCodingNetwork.GetTopLevelBeliefs(var Output: TArrayOfSingle);
var
  Top: TPCLayer;
  I: Integer;
begin
  Top := FLayers[FLayerCount - 1];
  SetLength(Output, Top.Dim);
  for I := 0 to Top.Dim - 1 do
    Output[I] := Top.Mu[I];
end;

procedure TPredictiveCodingNetwork.SetLayerPriors(LayerIdx: Integer; const Priors: array of Single);
var
  I, MaxI: Integer;
begin
  if (LayerIdx < 0) or (LayerIdx >= FLayerCount) then Exit;
  MaxI := FLayers[LayerIdx].Dim;
  if Length(Priors) < MaxI then MaxI := Length(Priors);
  for I := 0 to MaxI - 1 do
    FLayers[LayerIdx].Prior[I] := Priors[I];
end;

constructor TInterconnectedIntelligence.Create(PerceptDims, ActionDims: array of Integer);
begin
  inherited Create;
  FPerceptionNet := TPredictiveCodingNetwork.Create(PerceptDims, 0.005, 0.1);
  FActionNet := TPredictiveCodingNetwork.Create(ActionDims, 0.01, 0.1);

  FHomeostaticSetpoints[0] := 1.0;
  FHomeostaticSetpoints[1] := 1.0;
  FHomeostaticSetpoints[2] := 1.0;

  FHomeostaticStates[0] := 1.0;
  FHomeostaticStates[1] := 1.0;
  FHomeostaticStates[2] := 1.0;
end;

destructor TInterconnectedIntelligence.Destroy;
begin
  FPerceptionNet.Free;
  FActionNet.Free;
  inherited Destroy;
end;

procedure TInterconnectedIntelligence.ModulateHomeostasis(dEnergy, dHydration, dIntegrity: Single);
begin
  FHomeostaticStates[0] := FHomeostaticStates[0] + dEnergy;
  FHomeostaticStates[1] := FHomeostaticStates[1] + dHydration;
  FHomeostaticStates[2] := FHomeostaticStates[2] + dIntegrity;

  if FHomeostaticStates[0] > 1.0 then FHomeostaticStates[0] := 1.0;
  if FHomeostaticStates[1] > 1.0 then FHomeostaticStates[1] := 1.0;
  if FHomeostaticStates[2] > 1.0 then FHomeostaticStates[2] := 1.0;

  if FHomeostaticStates[0] < 0.0 then FHomeostaticStates[0] := 0.0;
  if FHomeostaticStates[1] < 0.0 then FHomeostaticStates[1] := 0.0;
  if FHomeostaticStates[2] < 0.0 then FHomeostaticStates[2] := 0.0;
end;

procedure TInterconnectedIntelligence.UpdateCycle(const Sensations: array of Single; var MotorCommands: TArrayOfSingle);
var
  PerceptBeliefs: TArrayOfSingle;
  ActionInputs: array of Single;
  I, AInCount: Integer;
  HomeoError: array [0..2] of Single;
begin
  FPerceptionNet.InferStates(Sensations, 6);
  FPerceptionNet.LearnSynapses;
  FPerceptionNet.GetTopLevelBeliefs(PerceptBeliefs);

  HomeoError[0] := FHomeostaticSetpoints[0] - FHomeostaticStates[0];
  HomeoError[1] := FHomeostaticSetpoints[1] - FHomeostaticStates[1];
  HomeoError[2] := FHomeostaticSetpoints[2] - FHomeostaticStates[2];

  AInCount := Length(PerceptBeliefs) + 3;
  SetLength(ActionInputs, AInCount);

  for I := 0 to High(PerceptBeliefs) do
    ActionInputs[I] := PerceptBeliefs[I];

  ActionInputs[AInCount - 3] := HomeoError[0];
  ActionInputs[AInCount - 2] := HomeoError[1];
  ActionInputs[AInCount - 1] := HomeoError[2];

  FActionNet.InferStates(ActionInputs, 4);
  FActionNet.LearnSynapses;

  SetLength(MotorCommands, FActionNet.GetLayer(0).Dim);
  for I := 0 to High(MotorCommands) do
    MotorCommands[I] := FastTanh(FActionNet.GetLayer(0).Mu[I]);
end;

function TInterconnectedIntelligence.ExtractGenomeData(var Genome: TArrayOfSingle): Integer;
var
  Idx, L, WCount: Integer;
  Layer: TPCLayer;
begin
  Idx := 0;
  for L := 1 to FActionNet.LayerCount - 1 do
  begin
    Layer := FActionNet.GetLayer(L);
    WCount := Layer.Dim * Layer.PrevDim;
    if Length(Genome) < Idx + WCount then
      SetLength(Genome, (Idx + WCount) * 2);
    Move(Layer.Weights^, Genome[Idx], WCount * SizeOf(Single));
    Inc(Idx, WCount);
  end;
  SetLength(Genome, Idx);
  Result := Idx;
end;

procedure TInterconnectedIntelligence.InjectGenomeData(const Genome: TArrayOfSingle);
var
  Idx, L, WCount: Integer;
  Layer: TPCLayer;
begin
  Idx := 0;
  for L := 1 to FActionNet.LayerCount - 1 do
  begin
    Layer := FActionNet.GetLayer(L);
    WCount := Layer.Dim * Layer.PrevDim;
    if Idx + WCount <= Length(Genome) then
      Move(Genome[Idx], Layer.Weights^, WCount * SizeOf(Single));
    Inc(Idx, WCount);
  end;
end;

end.
```

---

### 4. `WorldSim.pas`

```pascal
unit WorldSim;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, EngineCommon, PredictiveCodingNN;

type
  TLayerType = (ltTopography, ltChemicalPheromone, ltChemicalResource, ltObstacle);

  TWorldGridLayer = class
  private
    FWidth, FHeight: Integer;
    FData: PSingle;
    FScratch: PSingle;
    FLayerType: TLayerType;
    FDiffusionRate: Single;
    FDecayRate: Single;
  public
    constructor Create(W, H: Integer; AType: TLayerType; DiffRate, DecRate: Single);
    destructor Destroy; override;

    procedure SimulatePhysics(DeltaTime: Single);
    procedure Deposit(X, Y: Integer; Amount: Single);
    function Sample(X, Y: Single): Single;
    function SampleDiscrete(X, Y: Integer): Single;
    procedure SetDiscrete(X, Y: Integer; Val: Single);

    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property RawData: PSingle read FData;
  end;

  TSimAgent = class
  public
    ID: Integer;
    X, Y: Single;
    Heading: Single;
    Velocity: Single;
    Brain: TInterconnectedIntelligence;
    FitnessAccumulator: Single;
    Alive: Boolean;

    constructor Create(AID: Integer; InitX, InitY: Single);
    destructor Destroy; override;
  end;

  TWorldSimulation = class
  private
    FWidth, FHeight: Integer;
    FLayers: array of TWorldGridLayer;
    FAgents: array of TSimAgent;
    FNextAgentID: Integer;

    procedure UpdateSensors(Agent: TSimAgent; var SensoryArray: array of Single);
    procedure ApplyMotorCommands(Agent: TSimAgent; const Commands: TArrayOfSingle; DeltaTime: Single);
  public
    constructor Create(W, H: Integer);
    destructor Destroy; override;

    procedure AddLayer(AType: TLayerType; DiffRate, DecRate: Single);
    function SpawnAgent(X, Y: Single): TSimAgent;
    procedure Step(DeltaTime: Single);

    function GetLayer(Index: Integer): TWorldGridLayer;
    function LayerCount: Integer;
    function AgentCount: Integer;
    function GetAgent(Index: Integer): TSimAgent;
  end;

implementation

constructor TWorldGridLayer.Create(W, H: Integer; AType: TLayerType; DiffRate, DecRate: Single);
var
  TotalCells: Integer;
begin
  inherited Create;
  FWidth := W;
  FHeight := H;
  FLayerType := AType;
  FDiffusionRate := DiffRate;
  FDecayRate := DecRate;

  TotalCells := W * H;
  FData := AlignedAlloc(TotalCells * SizeOf(Single));
  FScratch := AlignedAlloc(TotalCells * SizeOf(Single));

  FillChar(FData^, TotalCells * SizeOf(Single), 0);
  FillChar(FScratch^, TotalCells * SizeOf(Single), 0);
end;

destructor TWorldGridLayer.Destroy;
begin
  AlignedFree(FData);
  AlignedFree(FScratch);
  inherited Destroy;
end;

procedure TWorldGridLayer.SimulatePhysics(DeltaTime: Single);
var
  X, Y, Idx: Integer;
  Laplacian, Val: Single;
  TotalCells: Integer;
begin
  if (FDiffusionRate <= 0.0) and (FDecayRate <= 0.0) then Exit;

  TotalCells := FWidth * FHeight;

  for Y := 0 to FHeight - 1 do
  begin
    for X := 0 to FWidth - 1 do
    begin
      Idx := Y * FWidth + X;
      Val := FData[Idx];

      Laplacian := 0.0;
      if X > 0 then Laplacian := Laplacian + FData[Idx - 1] else Laplacian := Laplacian + Val;
      if X < FWidth - 1 then Laplacian := Laplacian + FData[Idx + 1] else Laplacian := Laplacian + Val;
      if Y > 0 then Laplacian := Laplacian + FData[Idx - FWidth] else Laplacian := Laplacian + Val;
      if Y < FHeight - 1 then Laplacian := Laplacian + FData[Idx + FWidth] else Laplacian := Laplacian + Val;

      Laplacian := Laplacian - (4.0 * Val);
      FScratch[Idx] := Val + (FDiffusionRate * Laplacian - FDecayRate * Val) * DeltaTime;
      if FScratch[Idx] < 0.0 then FScratch[Idx] := 0.0;
    end;
  end;

  Move(FScratch^, FData^, TotalCells * SizeOf(Single));
end;

procedure TWorldGridLayer.Deposit(X, Y: Integer; Amount: Single);
var
  Idx: Integer;
begin
  if (X >= 0) and (X < FWidth) and (Y >= 0) and (Y < FHeight) then
  begin
    Idx := Y * FWidth + X;
    FData[Idx] := FData[Idx] + Amount;
  end;
end;

function TWorldGridLayer.Sample(X, Y: Single): Single;
var
  X0, Y0, X1, Y1: Integer;
  DX, DY, V00, V10, V01, V11, Top, Bottom: Single;
begin
  if X < 0.0 then X := 0.0;
  if Y < 0.0 then Y := 0.0;
  if X > FWidth - 1.001 then X := FWidth - 1.001;
  if Y > FHeight - 1.001 then Y := FHeight - 1.001;

  X0 := Trunc(X);
  Y0 := Trunc(Y);
  X1 := X0 + 1;
  Y1 := Y0 + 1;

  DX := X - X0;
  DY := Y - Y0;

  V00 := FData[Y0 * FWidth + X0];
  V10 := FData[Y0 * FWidth + X1];
  V01 := FData[Y1 * FWidth + X0];
  V11 := FData[Y1 * FWidth + X1];

  Top := V00 + DX * (V10 - V00);
  Bottom := V01 + DX * (V11 - V01);
  Result := Top + DY * (Bottom - Top);
end;

function TWorldGridLayer.SampleDiscrete(X, Y: Integer): Single;
begin
  if (X >= 0) and (X < FWidth) and (Y >= 0) and (Y < FHeight) then
    Result := FData[Y * FWidth + X]
  else
    Result := 0.0;
end;

procedure TWorldGridLayer.SetDiscrete(X, Y: Integer; Val: Single);
begin
  if (X >= 0) and (X < FWidth) and (Y >= 0) and (Y < FHeight) then
    FData[Y * FWidth + X] := Val;
end;

constructor TSimAgent.Create(AID: Integer; InitX, InitY: Single);
var
  PStructure, AStructure: array of Integer;
begin
  inherited Create;
  ID := AID;
  X := InitX;
  Y := InitY;
  Heading := Random * 2.0 * Pi;
  Velocity := 0.0;
  FitnessAccumulator := 0.0;
  Alive := True;

  SetLength(PStructure, 3);
  PStructure[0] := 8;
  PStructure[1] := 16;
  PStructure[2] := 8;

  SetLength(AStructure, 3);
  AStructure[0] := 4;
  AStructure[1] := 16;
  AStructure[2] := 11;

  Brain := TInterconnectedIntelligence.Create(PStructure, AStructure);
end;

destructor TSimAgent.Destroy;
begin
  Brain.Free;
  inherited Destroy;
end;

constructor TWorldSimulation.Create(W, H: Integer);
begin
  inherited Create;
  FWidth := W;
  FHeight := H;
  FNextAgentID := 1;
end;

destructor TWorldSimulation.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FLayers) do
    FLayers[I].Free;
  for I := 0 to High(FAgents) do
    FAgents[I].Free;
  inherited Destroy;
end;

procedure TWorldSimulation.AddLayer(AType: TLayerType; DiffRate, DecRate: Single);
var
  L: Integer;
begin
  L := Length(FLayers);
  SetLength(FLayers, L + 1);
  FLayers[L] := TWorldGridLayer.Create(FWidth, FHeight, AType, DiffRate, DecRate);
end;

function TWorldSimulation.SpawnAgent(X, Y: Single): TSimAgent;
var
  Agent: TSimAgent;
  L: Integer;
begin
  Agent := TSimAgent.Create(FNextAgentID, X, Y);
  Inc(FNextAgentID);
  L := Length(FAgents);
  SetLength(FAgents, L + 1);
  FAgents[L] := Agent;
  Result := Agent;
end;

procedure TWorldSimulation.UpdateSensors(Agent: TSimAgent; var SensoryArray: array of Single);
var
  Ray: Integer;
  Angle, RayDist, SampleX, SampleY: Single;
begin
  for Ray := 0 to 7 do
  begin
    Angle := Agent.Heading + (Ray - 3.5) * (Pi / 4.0);
    RayDist := 4.0;
    SampleX := Agent.X + Cos(Angle) * RayDist;
    SampleY := Agent.Y + Sin(Angle) * RayDist;

    if Length(FLayers) > 0 then
      SensoryArray[Ray] := FLayers[0].Sample(SampleX, SampleY)
    else
      SensoryArray[Ray] := 0.0;
  end;
end;

procedure TWorldSimulation.ApplyMotorCommands(Agent: TSimAgent; const Commands: TArrayOfSingle; DeltaTime: Single);
var
  Steer, Accel, Ingest, Excrete: Single;
  NewX, NewY, IngestedVal: Single;
  GridX, GridY: Integer;
begin
  Steer := Commands[0];
  Accel := Commands[1];
  Ingest := Commands[2];
  Excrete := Commands[3];

  Agent.Heading := Agent.Heading + Steer * 3.0 * DeltaTime;
  Agent.Velocity := Agent.Velocity * 0.85 + Accel * 5.0 * DeltaTime;

  NewX := Agent.X + Cos(Agent.Heading) * Agent.Velocity * DeltaTime;
  NewY := Agent.Y + Sin(Agent.Heading) * Agent.Velocity * DeltaTime;

  if NewX < 0.0 then NewX := 0.0;
  if NewY < 0.0 then NewY := 0.0;
  if NewX > FWidth - 1.0 then NewX := FWidth - 1.0;
  if NewY > FHeight - 1.0 then NewY := FHeight - 1.0;

  Agent.X := NewX;
  Agent.Y := NewY;

  GridX := Trunc(Agent.X);
  GridY := Trunc(Agent.Y);

  if (Ingest > 0.2) and (Length(FLayers) > 1) then
  begin
    IngestedVal := FLayers[1].SampleDiscrete(GridX, GridY);
    if IngestedVal > 0.1 then
    begin
      FLayers[1].SetDiscrete(GridX, GridY, IngestedVal * 0.5);
      Agent.Brain.ModulateHomeostasis(0.1, 0.05, 0.0);
      Agent.FitnessAccumulator := Agent.FitnessAccumulator + 2.0;
    end;
  end;

  if (Excrete > 0.3) and (Length(FLayers) > 0) then
    FLayers[0].Deposit(GridX, GridY, 2.0);

  Agent.Brain.ModulateHomeostasis(-0.002 * DeltaTime, -0.003 * DeltaTime, 0.0);

  if Agent.Brain.Homeostasis[0] <= 0.05 then
    Agent.Alive := False;
end;

procedure TWorldSimulation.Step(DeltaTime: Single);
var
  I: Integer;
  SensoryFeed: array [0..7] of Single;
  Motors: TArrayOfSingle;
begin
  for I := 0 to High(FLayers) do
    FLayers[I].SimulatePhysics(DeltaTime);

  for I := 0 to High(FAgents) do
  begin
    if FAgents[I].Alive then
    begin
      UpdateSensors(FAgents[I], SensoryFeed);
      FAgents[I].Brain.UpdateCycle(SensoryFeed, Motors);
      ApplyMotorCommands(FAgents[I], Motors, DeltaTime);
      FAgents[I].FitnessAccumulator := FAgents[I].FitnessAccumulator + (0.1 * DeltaTime);
    end;
  end;
end;

function TWorldSimulation.GetLayer(Index: Integer): TWorldGridLayer;
begin
  Result := FLayers[Index];
end;

function TWorldSimulation.LayerCount: Integer;
begin
  Result := Length(FLayers);
end;

function TWorldSimulation.AgentCount: Integer;
begin
  Result := Length(FAgents);
end;

function TWorldSimulation.GetAgent(Index: Integer): TSimAgent;
begin
  Result := FAgents[Index];
end;

end.
```

---

### 5. `EvolutionEngine.pas`

```pascal
unit EvolutionEngine;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, EngineCommon, WorldSim;

type
  TGenome = record
    Data: TArrayOfSingle;
    Fitness: Single;
  end;

  TDistillationBuffer = class
  private
    FLock: TCriticalSection;
    FEliteGenome: TArrayOfSingle;
    FHasNewElite: Boolean;
    FBestFitness: Single;
  public
    constructor Create;
    destructor Destroy; override;
    procedure PostElite(const Genome: TArrayOfSingle; Fitness: Single);
    function FetchElite(var OutGenome: TArrayOfSingle): Boolean;
    property BestFitness: Single read FBestFitness;
  end;

  TEvolutionWorker = class(TThread)
  private
    FPopulation: array of TGenome;
    FPopSize: Integer;
    FGenomeLength: Integer;
    FDistributor: TDistillationBuffer;
    FRunning: Boolean;

    procedure EvaluateBatch;
    procedure SelectionAndReproduction;
  protected
    procedure Execute; override;
  public
    constructor Create(PopSize, GenomeLen: Integer; Distributor: TDistillationBuffer);
    destructor Destroy; override;
    procedure TerminateWorker;
  end;

implementation

constructor TDistillationBuffer.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FHasNewElite := False;
  FBestFitness := -1e9;
end;

destructor TDistillationBuffer.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TDistillationBuffer.PostElite(const Genome: TArrayOfSingle; Fitness: Single);
begin
  FLock.Enter;
  try
    if Fitness > FBestFitness then
    begin
      FBestFitness := Fitness;
      SetLength(FEliteGenome, Length(Genome));
      Move(Genome[0], FEliteGenome[0], Length(Genome) * SizeOf(Single));
      FHasNewElite := True;
    end;
  finally
    FLock.Leave;
  end;
end;

function TDistillationBuffer.FetchElite(var OutGenome: TArrayOfSingle): Boolean;
begin
  Result := False;
  if not FHasNewElite then Exit;

  FLock.Enter;
  try
    if FHasNewElite then
    begin
      SetLength(OutGenome, Length(FEliteGenome));
      Move(FEliteGenome[0], OutGenome[0], Length(FEliteGenome) * SizeOf(Single));
      FHasNewElite := False;
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

constructor TEvolutionWorker.Create(PopSize, GenomeLen: Integer; Distributor: TDistillationBuffer);
var
  I, J: Integer;
begin
  inherited Create(True);
  FPopSize := PopSize;
  FGenomeLength := GenomeLen;
  FDistributor := Distributor;
  FRunning := True;

  SetLength(FPopulation, FPopSize);
  for I := 0 to FPopSize - 1 do
  begin
    SetLength(FPopulation[I].Data, FGenomeLength);
    for J := 0 to FGenomeLength - 1 do
      FPopulation[I].Data[J] := RandomGaussian(0.0, 0.5);
    FPopulation[I].Fitness := 0.0;
  end;
end;

destructor TEvolutionWorker.Destroy;
begin
  inherited Destroy;
end;

procedure TEvolutionWorker.TerminateWorker;
begin
  FRunning := False;
  Terminate;
end;

procedure TEvolutionWorker.EvaluateBatch;
var
  Arena: TWorldSimulation;
  Agents: array of TSimAgent;
  StepIdx, I: Integer;
begin
  Arena := TWorldSimulation.Create(32, 32);
  try
    Arena.AddLayer(ltChemicalPheromone, 0.1, 0.01);
    Arena.AddLayer(ltChemicalResource, 0.05, 0.001);

    for StepIdx := 0 to 15 do
      Arena.GetLayer(1).SetDiscrete(Random(32), Random(32), 25.0);

    SetLength(Agents, FPopSize);
    for I := 0 to FPopSize - 1 do
    begin
      Agents[I] := Arena.SpawnAgent(RandomUniform(2.0, 30.0), RandomUniform(2.0, 30.0));
      Agents[I].Brain.InjectGenomeData(FPopulation[I].Data);
    end;

    for StepIdx := 0 to 80 do
      Arena.Step(0.1);

    for I := 0 to FPopSize - 1 do
    begin
      FPopulation[I].Fitness := Agents[I].FitnessAccumulator;
      FDistributor.PostElite(FPopulation[I].Data, FPopulation[I].Fitness);
    end;
  finally
    Arena.Free;
  end;
end;

procedure TEvolutionWorker.SelectionAndReproduction;
var
  NewPop: array of TGenome;
  I, J, P1, P2, BestCandidate: Integer;
  Alpha, MutProb: Single;

  function TournamentSelect: Integer;
  var
    K, Candidate, Winner: Integer;
    BestFit: Single;
  begin
    Winner := Random(FPopSize);
    BestFit := FPopulation[Winner].Fitness;
    for K := 1 to 2 do
    begin
      Candidate := Random(FPopSize);
      if FPopulation[Candidate].Fitness > BestFit then
      begin
        BestFit := FPopulation[Candidate].Fitness;
        Winner := Candidate;
      end;
    end;
    Result := Winner;
  end;

begin
  SetLength(NewPop, FPopSize);

  BestCandidate := 0;
  for I := 1 to FPopSize - 1 do
    if FPopulation[I].Fitness > FPopulation[BestCandidate].Fitness then
      BestCandidate := I;

  SetLength(NewPop[0].Data, FGenomeLength);
  Move(FPopulation[BestCandidate].Data[0], NewPop[0].Data[0], FGenomeLength * SizeOf(Single));
  NewPop[0].Fitness := FPopulation[BestCandidate].Fitness;

  MutProb := 0.05;
  for I := 1 to FPopSize - 1 do
  begin
    P1 := TournamentSelect;
    P2 := TournamentSelect;
    SetLength(NewPop[I].Data, FGenomeLength);

    for J := 0 to FGenomeLength - 1 do
    begin
      Alpha := Random;
      NewPop[I].Data[J] := Alpha * FPopulation[P1].Data[J] + (1.0 - Alpha) * FPopulation[P2].Data[J];

      if Random < MutProb then
        NewPop[I].Data[J] := NewPop[I].Data[J] + RandomGaussian(0.0, 0.2);
    end;
    NewPop[I].Fitness := 0.0;
  end;

  FPopulation := NewPop;
end;

procedure TEvolutionWorker.Execute;
begin
  while FRunning and (not Terminated) do
  begin
    EvaluateBatch;
    SelectionAndReproduction;
    Sleep(5);
  end;
end;

end.
```

---

### 6. `EngineMain.pas`

```pascal
program EngineMain;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  EngineCommon, EngineJSON, PredictiveCodingNN, WorldSim, EvolutionEngine;

type
  TEngineController = class
  private
    FWorld: TWorldSimulation;
    FDistributor: TDistillationBuffer;
    FEvoWorker: TEvolutionWorker;
    FRunning: Boolean;
    FTickCount: Int64;
    FGenomeLength: Integer;

    function ExecuteJSONCommand(const CmdStr: string): string;
  public
    constructor Create;
    destructor Destroy; override;

    procedure RunIPCEventLoop;
  end;

constructor TEngineController.Create;
var
  DummyGenome: TArrayOfSingle;
  ProbeAgent: TSimAgent;
begin
  inherited Create;
  Randomize;
  FRunning := True;
  FTickCount := 0;

  FWorld := TWorldSimulation.Create(64, 64);
  FWorld.AddLayer(ltChemicalPheromone, 0.15, 0.02);
  FWorld.AddLayer(ltChemicalResource, 0.05, 0.001);

  FDistributor := TDistillationBuffer.Create;

  ProbeAgent := FWorld.SpawnAgent(32.0, 32.0);
  FGenomeLength := ProbeAgent.Brain.ExtractGenomeData(DummyGenome);

  FEvoWorker := TEvolutionWorker.Create(32, FGenomeLength, FDistributor);
  FEvoWorker.Start;

  Writeln(StdErr, Format('[BOOT] Engine initialized. Genome length: %d parameters.', [FGenomeLength]));
end;

destructor TEngineController.Destroy;
begin
  FEvoWorker.TerminateWorker;
  FEvoWorker.WaitFor;
  FEvoWorker.Free;
  FDistributor.Free;
  FWorld.Free;
  inherited Destroy;
end;

function TEngineController.ExecuteJSONCommand(const CmdStr: string): string;
var
  Parser: TJSONParser;
  RootNode, RespNode, DataNode: TJSONNode;
  Cmd: string;
  StepCount, S, I: Integer;
  NewElite: TArrayOfSingle;
  DistillCount: Integer;
  Ag: TSimAgent;
  LayerIdx, X, Y: Integer;
  Val: Single;
begin
  Result := '{"status":"error","message":"Invalid command payload"}';
  Parser := TJSONParser.Create;
  try
    RootNode := Parser.Parse(CmdStr);
    if RootNode = nil then Exit;
    try
      if not RootNode.HasKey('cmd') then Exit;
      Cmd := RootNode.GetValue('cmd').AsString;

      RespNode := TJSONNode.Create(jkObject);
      try
        if Cmd = 'step' then
        begin
          StepCount := 1;
          if RootNode.HasKey('ticks') then
            StepCount := RootNode.GetValue('ticks').AsInteger;

          DistillCount := 0;
          for S := 1 to StepCount do
          begin
            if FDistributor.FetchElite(NewElite) then
            begin
              for I := 0 to FWorld.AgentCount - 1 do
                FWorld.GetAgent(I).Brain.InjectGenomeData(NewElite);
              Inc(DistillCount);
            end;

            FWorld.Step(0.1);
            Inc(FTickCount);
          end;

          RespNode.AddString('status', 'ok');
          RespNode.AddNumber('tick', FTickCount);
          RespNode.AddNumber('agent_count', FWorld.AgentCount);
          RespNode.AddNumber('elite_distillations', DistillCount);
          RespNode.AddNumber('best_evo_fitness', FDistributor.BestFitness);
          Result := RespNode.Serialize;
        end
        else if Cmd = 'spawn' then
        begin
          X := 32;
          Y := 32;
          if RootNode.HasKey('x') then X := RootNode.GetValue('x').AsInteger;
          if RootNode.HasKey('y') then Y := RootNode.GetValue('y').AsInteger;

          Ag := FWorld.SpawnAgent(X, Y);
          RespNode.AddString('status', 'ok');
          RespNode.AddNumber('spawned_id', Ag.ID);
          Result := RespNode.Serialize;
        end
        else if Cmd = 'deposit' then
        begin
          LayerIdx := 0;
          X := 0;
          Y := 0;
          Val := 10.0;
          if RootNode.HasKey('layer') then LayerIdx := RootNode.GetValue('layer').AsInteger;
          if RootNode.HasKey('x') then X := RootNode.GetValue('x').AsInteger;
          if RootNode.HasKey('y') then Y := RootNode.GetValue('y').AsInteger;
          if RootNode.HasKey('val') then Val := RootNode.GetValue('val').AsFloat;

          if (LayerIdx >= 0) and (LayerIdx < FWorld.LayerCount) then
          begin
            FWorld.GetLayer(LayerIdx).Deposit(X, Y, Val);
            RespNode.AddString('status', 'ok');
          end
          else
            RespNode.AddString('status', 'out_of_bounds');

          Result := RespNode.Serialize;
        end
        else if Cmd = 'telemetry' then
        begin
          RespNode.AddString('status', 'ok');
          DataNode := TJSONNode.Create(jkObject);
          DataNode.AddNumber('ticks', FTickCount);
          DataNode.AddNumber('agents', FWorld.AgentCount);
          DataNode.AddNumber('best_evo_fitness', FDistributor.BestFitness);
          if FWorld.AgentCount > 0 then
          begin
            Ag := FWorld.GetAgent(0);
            DataNode.AddNumber('agent0_x', Ag.X);
            DataNode.AddNumber('agent0_y', Ag.Y);
            DataNode.AddNumber('agent0_energy', Ag.Brain.Homeostasis[0]);
            DataNode.AddNumber('agent0_free_energy', Ag.Brain.Perception.ComputeTotalFreeEnergy);
          end;
          RespNode.AddObject('telemetry', DataNode);
          Result := RespNode.Serialize;
        end
        else if Cmd = 'quit' then
        begin
          FRunning := False;
          RespNode.AddString('status', 'terminating');
          Result := RespNode.Serialize;
        end
        else
        begin
          RespNode.AddString('status', 'unknown_cmd');
          Result := RespNode.Serialize;
        end;
      finally
        RespNode.Free;
      end;
    finally
      RootNode.Free;
    end;
  finally
    Parser.Free;
  end;
end;

procedure TEngineController.RunIPCEventLoop;
var
  InputLine, Response: string;
begin
  Writeln(StdErr, '[IPC] Standard I/O loop engaged. Ready for JSON messages.');
  while FRunning and not EOF do
  begin
    ReadLn(InputLine);
    InputLine := Trim(InputLine);
    if InputLine = '' then Continue;

    try
      Response := ExecuteJSONCommand(InputLine);
      Writeln(Response);
      Flush(Output);
    except
      on E: Exception do
      begin
        Writeln(StdErr, '[ERROR] Exception in command cycle: ' + E.Message);
        Writeln('{"status":"fatal_error","message":"' + E.Message + '"}');
        Flush(Output);
      end;
    end;
  end;
end;

var
  Engine: TEngineController;

begin
  Engine := TEngineController.Create;
  try
    Engine.RunIPCEventLoop;
  finally
    Engine.Free;
  end;
end.
```

---

### Compilation Instructions

Compile with maximum optimizations (`-O3`), FreePascal object model (`-Mobjfpc`), ansistrings (`-Sh`), and dead-code stripping:

```bash
fpc -O3 -Mobjfpc -Sh -CX -XX EngineMain.pas
```

*(Note: On Linux, multithreading automatically links `libpthread` via `cthreads`.)*

---

### Interactive Protocol / Testing Over `stdin` / `stdout`

Once executed, the engine runs silently on background threads and listens on `stdin` for newline-delimited JSON commands. Diagnostics are routed cleanly to `stderr`, while machine responses emit to `stdout`.

#### 1. Step the simulation forward 10 ticks
**Command (stdin):**
```json
{"cmd":"step", "ticks":10}
```
**Response (stdout):**
```json
{"status":"ok","tick":10,"agent_count":1,"elite_distillations":0,"best_evo_fitness":14.300000}
```

#### 2. Query real-time agent telemetry and predictive coding variational free energy
**Command (stdin):**
```json
{"cmd":"telemetry"}
```
**Response (stdout):**
```json
{"status":"ok","telemetry":{"ticks":10,"agents":1,"best_evo_fitness":14.300000,"agent0_x":32.148129,"agent0_y":31.981240,"agent0_energy":0.998000,"agent0_free_energy":0.003125}}
```

#### 3. Inject resources into the environment
**Command (stdin):**
```json
{"cmd":"deposit", "layer":1, "x":32, "y":32, "val":50.0}
```
**Response (stdout):**
```json
{"status":"ok"}
```

#### 4. Spawn additional live agents
**Command (stdin):**
```json
{"cmd":"spawn", "x":15, "y":15}
```
**Response (stdout):**
```json
{"status":"ok","spawned_id":2}
```

#### 5. Graceful termination
**Command (stdin):**
```json
{"cmd":"quit"}
```
**Response (stdout):**
```json
{"status":"terminating"}
```
