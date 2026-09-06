unit kyzu_pathfinding;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, SyncObjs, kyzu_bakeconfig;

type
  TMovementGrid = record
    Width, Height: Integer;
    Cells: array of Byte; // row-major, one GlobCover class ID per cell
  end;

  TGridPoint = record
    X, Y: Integer;
  end;
  TGridPath = array of TGridPoint;

  TAStarNode = record
    X, Y: Integer;
    G, F: Double;
  end;

  // Binary min-heap for open-set nodes, keyed by F-score. Reuses its
  // internal array across searches to avoid heap allocations.
  TMinHeap = class
  private
    FItems: array of TAStarNode;
    FCount: Integer;
    procedure Swap(i, j: Integer); inline;
    procedure SiftUp(i: Integer);
    procedure SiftDown(i: Integer);
  public
    constructor Create;
    procedure Clear; inline;
    procedure Push(const ANode: TAStarNode);
    function Pop: TAStarNode;
    function IsEmpty: Boolean; inline;
    property Count: Integer read FCount;
  end;

  // Reusable scratch workspace for A* searches. Instead of allocating
  // and zeroing GScore, CameFrom, and Closed arrays over the entire grid
  // on every single path query (e.g. 845K cells for 1300x650), this
  // maintains persistent buffers and stamps them with a monotonically
  // increasing RunID. A cell is visited or closed if its stamp matches
  // the current run, turning search setup into an O(1) counter increment.
  TPathfinderWorkspace = class
  private
    FCapacity: Integer;
    FGScore: array of Double;
    FCameFrom: array of Integer;
    FRunID: array of Cardinal;
    FClosedRun: array of Cardinal;
    FCurrentRun: Cardinal;
    FHeap: TMinHeap;
    procedure EnsureCapacity(ACount: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Prepare(ACount: Integer);
  end;

function LoadMovementGrid(const AFilename: string): TMovementGrid;
function CellClass(const AGrid: TMovementGrid; X, Y: Integer): Byte;
function CellMoveCost(const AGrid: TMovementGrid; const AConfig: TBakeConfig; X, Y: Integer): Double;

// Overloaded A* search:
// 1. Thread-safe default overload using the internal global workspace.
// 2. Custom workspace overload for callers running independent background workers.
function FindPath(const AGrid: TMovementGrid; const AConfig: TBakeConfig;
  AStartX, AStartY, AGoalX, AGoalY: Integer; AMaxNodes: Integer = 2000000): TGridPath; overload;

function FindPath(const AGrid: TMovementGrid; const AConfig: TBakeConfig;
  AStartX, AStartY, AGoalX, AGoalY: Integer; AWorkspace: TPathfinderWorkspace;
  AMaxNodes: Integer = 2000000): TGridPath; overload;

implementation

var
  GlobalWorkspace: TPathfinderWorkspace = nil;
  WorkspaceLock: TCriticalSection = nil;

// ── TMinHeap ─────────────────────────────────────────────────────────────────

constructor TMinHeap.Create;
begin
  inherited Create;
  SetLength(FItems, 1024);
  FCount := 0;
end;

procedure TMinHeap.Clear;
begin
  FCount := 0;
end;

procedure TMinHeap.Swap(i, j: Integer);
var
  t: TAStarNode;
begin
  t := FItems[i];
  FItems[i] := FItems[j];
  FItems[j] := t;
end;

procedure TMinHeap.SiftUp(i: Integer);
var
  p: Integer;
begin
  while i > 0 do
  begin
    p := (i - 1) div 2;
    if FItems[p].F <= FItems[i].F then Break;
    Swap(p, i);
    i := p;
  end;
end;

procedure TMinHeap.SiftDown(i: Integer);
var
  l, r, smallest: Integer;
begin
  while True do
  begin
    l := 2 * i + 1;
    r := 2 * i + 2;
    smallest := i;
    if (l < FCount) and (FItems[l].F < FItems[smallest].F) then smallest := l;
    if (r < FCount) and (FItems[r].F < FItems[smallest].F) then smallest := r;
    if smallest = i then Break;
    Swap(i, smallest);
    i := smallest;
  end;
end;

procedure TMinHeap.Push(const ANode: TAStarNode);
begin
  if FCount >= Length(FItems) then
    SetLength(FItems, Length(FItems) * 2);
  FItems[FCount] := ANode;
  Inc(FCount);
  SiftUp(FCount - 1);
end;

function TMinHeap.Pop: TAStarNode;
begin
  Result := FItems[0];
  Dec(FCount);
  FItems[0] := FItems[FCount];
  if FCount > 0 then
    SiftDown(0);
end;

function TMinHeap.IsEmpty: Boolean;
begin
  Result := FCount = 0;
end;

// ── TPathfinderWorkspace ─────────────────────────────────────────────────────

constructor TPathfinderWorkspace.Create;
begin
  inherited Create;
  FCapacity := 0;
  FCurrentRun := 0;
  FHeap := TMinHeap.Create;
end;

destructor TPathfinderWorkspace.Destroy;
begin
  FHeap.Free;
  inherited Destroy;
end;

procedure TPathfinderWorkspace.EnsureCapacity(ACount: Integer);
begin
  if ACount > FCapacity then
  begin
    FCapacity := ACount;
    SetLength(FGScore, FCapacity);
    SetLength(FCameFrom, FCapacity);
    SetLength(FRunID, FCapacity);
    SetLength(FClosedRun, FCapacity);
    // Reset stamps to 0 whenever buffers are newly sized
    FillChar(FRunID[0], Length(FRunID) * SizeOf(Cardinal), 0);
    FillChar(FClosedRun[0], Length(FClosedRun) * SizeOf(Cardinal), 0);
    FCurrentRun := 1;
  end;
end;

procedure TPathfinderWorkspace.Prepare(ACount: Integer);
begin
  EnsureCapacity(ACount);
  FHeap.Clear;
  Inc(FCurrentRun);
  // Stamp overflow safeguard (occurs after 4.2 billion searches)
  if FCurrentRun = 0 then
  begin
    FillChar(FRunID[0], Length(FRunID) * SizeOf(Cardinal), 0);
    FillChar(FClosedRun[0], Length(FClosedRun) * SizeOf(Cardinal), 0);
    FCurrentRun := 1;
  end;
end;

// ── Grid Loading / Lookups ───────────────────────────────────────────────────

function LoadMovementGrid(const AFilename: string): TMovementGrid;
var
  Stream: TFileStream;
  Magic: array[0..3] of Byte;
  W32, H32: Int32;
begin
  Stream := TFileStream.Create(AFilename, fmOpenRead);
  try
    Stream.ReadBuffer(Magic, 4);
    if (Magic[0] <> Ord('K')) or (Magic[1] <> Ord('Y')) or
       (Magic[2] <> Ord('T')) or (Magic[3] <> Ord('R')) then
      raise Exception.Create('movement grid: bad magic (expected KYTR)');
    Stream.ReadBuffer(W32, 4);
    Stream.ReadBuffer(H32, 4);
    Result.Width := W32;
    Result.Height := H32;
    SetLength(Result.Cells, Result.Width * Result.Height);
    Stream.ReadBuffer(Result.Cells[0], Result.Width * Result.Height);
  finally
    Stream.Free;
  end;
end;

function CellClass(const AGrid: TMovementGrid; X, Y: Integer): Byte;
begin
  if (AGrid.Width <= 0) or (AGrid.Height <= 0) then Exit(0);
  // Toroidal wrapping along the X axis (-180° to 180° meridian)
  X := (X mod AGrid.Width + AGrid.Width) mod AGrid.Width;
  Y := EnsureRange(Y, 0, AGrid.Height - 1);
  Result := AGrid.Cells[Y * AGrid.Width + X];
end;

function CellMoveCost(const AGrid: TMovementGrid; const AConfig: TBakeConfig; X, Y: Integer): Double;
begin
  Result := PaletteClassMoveCost(AConfig, CellClass(AGrid, X, Y));
end;

// ── A* Pathfinding Core ──────────────────────────────────────────────────────

function FindPath(const AGrid: TMovementGrid; const AConfig: TBakeConfig;
  AStartX, AStartY, AGoalX, AGoalY: Integer; AWorkspace: TPathfinderWorkspace;
  AMaxNodes: Integer): TGridPath;
const
  Dirs: array[0..7] of TGridPoint = (
    (X: 1; Y: 0), (X: -1; Y: 0), (X: 0; Y: 1), (X: 0; Y: -1),
    (X: 1; Y: 1), (X: 1; Y: -1), (X: -1; Y: 1), (X: -1; Y: -1)
  );
var
  NumCells: Integer;
  Current, Node: TAStarNode;
  CurIdx, NIdx: Integer;
  i, nx, ny: Integer;
  StepCost, TentativeG, MinCost: Double;
  NodesPopped, PathLen, Idx: Integer;
  HalfWidth: Double;

  // Octile distance admissible heuristic with toroidal X wrapping across the antimeridian.
  function Heuristic(HX, HY: Integer): Double;
  var
    dx, dy: Double;
  begin
    dx := Abs(HX - AGoalX);
    if dx > HalfWidth then
      dx := AGrid.Width - dx; // wrap distance across the seam
    dy := Abs(HY - AGoalY);
    Result := (Max(dx, dy) + (Sqrt(2) - 1.0) * Min(dx, dy)) * MinCost;
  end;

begin
  SetLength(Result, 0);

  if (AGrid.Width <= 0) or (AGrid.Height <= 0) then Exit;
  if (AStartY < 0) or (AStartY >= AGrid.Height) then Exit;
  if (AGoalY < 0) or (AGoalY >= AGrid.Height) then Exit;

  // Wrap input coordinates to standard [0..Width-1] range
  AStartX := (AStartX mod AGrid.Width + AGrid.Width) mod AGrid.Width;
  AGoalX := (AGoalX mod AGrid.Width + AGrid.Width) mod AGrid.Width;

  if CellMoveCost(AGrid, AConfig, AGoalX, AGoalY) <= 0 then Exit; // goal is impassable
  if CellMoveCost(AGrid, AConfig, AStartX, AStartY) <= 0 then Exit; // start is impassable

  // Handle immediate start == goal case
  if (AStartX = AGoalX) and (AStartY = AGoalY) then
  begin
    SetLength(Result, 1);
    Result[0].X := AStartX;
    Result[0].Y := AStartY;
    Exit;
  end;

  MinCost := Infinity;
  for i := 0 to High(AConfig.Classes) do
    if (AConfig.Classes[i].MoveCost > 0) and (AConfig.Classes[i].MoveCost < MinCost) then
      MinCost := AConfig.Classes[i].MoveCost;
  if IsInfinite(MinCost) then MinCost := 0.5;

  HalfWidth := AGrid.Width / 2.0;
  NumCells := AGrid.Width * AGrid.Height;
  AWorkspace.Prepare(NumCells);

  CurIdx := AStartY * AGrid.Width + AStartX;
  AWorkspace.FGScore[CurIdx] := 0;
  AWorkspace.FCameFrom[CurIdx] := -1;
  AWorkspace.FRunID[CurIdx] := AWorkspace.FCurrentRun;

  Node.X := AStartX;
  Node.Y := AStartY;
  Node.G := 0;
  Node.F := Heuristic(AStartX, AStartY);
  AWorkspace.FHeap.Push(Node);

  NodesPopped := 0;
  while not AWorkspace.FHeap.IsEmpty do
  begin
    Current := AWorkspace.FHeap.Pop;
    CurIdx := Current.Y * AGrid.Width + Current.X;

    // Stale entry check: if cell is already closed in this run, skip it
    if AWorkspace.FClosedRun[CurIdx] = AWorkspace.FCurrentRun then
      Continue;

    AWorkspace.FClosedRun[CurIdx] := AWorkspace.FCurrentRun;
    Inc(NodesPopped);
    if NodesPopped > AMaxNodes then Break; // safety limit exceeded

    // Goal reached: reconstruct path
    if (Current.X = AGoalX) and (Current.Y = AGoalY) then
    begin
      PathLen := 0;
      Idx := CurIdx;
      while Idx >= 0 do
      begin
        Inc(PathLen);
        Idx := AWorkspace.FCameFrom[Idx];
      end;

      SetLength(Result, PathLen);
      Idx := CurIdx;
      i := PathLen - 1;
      while Idx >= 0 do
      begin
        Result[i].X := Idx mod AGrid.Width;
        Result[i].Y := Idx div AGrid.Width;
        Idx := AWorkspace.FCameFrom[Idx];
        Dec(i);
      end;
      Exit;
    end;

    for i := 0 to 7 do
    begin
      ny := Current.Y + Dirs[i].Y;
      if (ny < 0) or (ny >= AGrid.Height) then
        Continue; // Latitude does not wrap (polar boundaries)

      // Longitude wrapping (toroidal equirectangular projection)
      nx := (Current.X + Dirs[i].X + AGrid.Width) mod AGrid.Width;
      NIdx := ny * AGrid.Width + nx;

      if AWorkspace.FClosedRun[NIdx] = AWorkspace.FCurrentRun then
        Continue;

      // Diagonal Corner-Cutting Prevention:
      // When moving diagonally, both orthogonal adjacent cells must be passable.
      // This prevents units from grazing or crossing water corners diagonally.
      if (Dirs[i].X <> 0) and (Dirs[i].Y <> 0) then
      begin
        if (CellMoveCost(AGrid, AConfig, Current.X, ny) <= 0) or
           (CellMoveCost(AGrid, AConfig, nx, Current.Y) <= 0) then
          Continue;
      end;

      StepCost := CellMoveCost(AGrid, AConfig, nx, ny);
      if StepCost <= 0 then
        Continue; // Target cell impassable

      if (Dirs[i].X <> 0) and (Dirs[i].Y <> 0) then
        StepCost := StepCost * Sqrt(2.0); // Diagonal step factor

      TentativeG := Current.G + StepCost;

      // Check if this node has not yet been discovered in this run,
      // or if we found a cheaper route to it.
      if (AWorkspace.FRunID[NIdx] <> AWorkspace.FCurrentRun) or
         (TentativeG < AWorkspace.FGScore[NIdx]) then
      begin
        AWorkspace.FGScore[NIdx] := TentativeG;
        AWorkspace.FCameFrom[NIdx] := CurIdx;
        AWorkspace.FRunID[NIdx] := AWorkspace.FCurrentRun;

        Node.X := nx;
        Node.Y := ny;
        Node.G := TentativeG;
        Node.F := TentativeG + Heuristic(nx, ny);
        AWorkspace.FHeap.Push(Node);
      end;
    end;
  end;
end;

function FindPath(const AGrid: TMovementGrid; const AConfig: TBakeConfig;
  AStartX, AStartY, AGoalX, AGoalY: Integer; AMaxNodes: Integer): TGridPath;
begin
  WorkspaceLock.Enter;
  try
    Result := FindPath(AGrid, AConfig, AStartX, AStartY, AGoalX, AGoalY, GlobalWorkspace, AMaxNodes);
  finally
    WorkspaceLock.Leave;
  end;
end;

initialization
  WorkspaceLock := TCriticalSection.Create;
  GlobalWorkspace := TPathfinderWorkspace.Create;

finalization
  GlobalWorkspace.Free;
  WorkspaceLock.Free;

end.