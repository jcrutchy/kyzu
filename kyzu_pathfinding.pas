unit kyzu_pathfinding;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, kyzu_bakeconfig;

type
  TMovementGrid = record
    Width, Height: Integer;
    Cells: array of Byte; // row-major, one GlobCover class ID per cell
  end;

  TGridPoint = record
    X, Y: Integer;
  end;
  TGridPath = array of TGridPoint;

function LoadMovementGrid(const AFilename: string): TMovementGrid;
function CellClass(const AGrid: TMovementGrid; X, Y: Integer): Byte;
function CellMoveCost(const AGrid: TMovementGrid; const AConfig: TBakeConfig; X, Y: Integer): Double;

// Returns an empty path (Length=0) if no path exists or the search hits
// AMaxNodes without reaching the goal - the cap is a safety valve against
// a request that's technically searchable but pathologically expensive.
// Default is generous (2M nodes) based on measured worst case: opposite
// corners of a full 1300x650 grid needed ~260K+ nodes and ~260ms - the
// cap exists for genuinely pathological cases (e.g. a request across an
// entire ocean with no valid route at all), not normal long moves. See
// the "hierarchical pathfinding for macro movement" discussion for the
// real long-term answer to very-long-distance routing cost.
function FindPath(const AGrid: TMovementGrid; const AConfig: TBakeConfig;
  AStartX, AStartY, AGoalX, AGoalY: Integer; AMaxNodes: Integer = 2000000): TGridPath;

implementation

// ── binary min-heap of open-set nodes, keyed by F-score ──────────────
type
  TAStarNode = record
    X, Y: Integer;
    G, F: Double;
  end;

  TMinHeap = class
  private
    FItems: array of TAStarNode;
    FCount: Integer;
    procedure Swap(i, j: Integer);
    procedure SiftUp(i: Integer);
    procedure SiftDown(i: Integer);
  public
    constructor Create;
    procedure Push(const ANode: TAStarNode);
    function Pop: TAStarNode;
    function IsEmpty: Boolean;
  end;

constructor TMinHeap.Create;
begin
  inherited Create;
  SetLength(FItems, 1024);
  FCount := 0;
end;

procedure TMinHeap.Swap(i, j: Integer);
var
  t: TAStarNode;
begin
  t := FItems[i]; FItems[i] := FItems[j]; FItems[j] := t;
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
    l := 2 * i + 1; r := 2 * i + 2; smallest := i;
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

// ── grid loading / lookups ────────────────────────────────────────────

// Matches kyzu_bake_movement_grid.lpr's output format exactly:
//   4 bytes magic 'KYTR', 4 bytes width (Int32 LE), 4 bytes height
//   (Int32 LE), then width*height class-ID bytes, row-major.
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
  X := EnsureRange(X, 0, AGrid.Width - 1);
  Y := EnsureRange(Y, 0, AGrid.Height - 1);
  Result := AGrid.Cells[Y * AGrid.Width + X];
end;

function CellMoveCost(const AGrid: TMovementGrid; const AConfig: TBakeConfig; X, Y: Integer): Double;
begin
  Result := PaletteClassMoveCost(AConfig, CellClass(AGrid, X, Y));
end;

// ── A* ─────────────────────────────────────────────────────────────

function FindPath(const AGrid: TMovementGrid; const AConfig: TBakeConfig;
  AStartX, AStartY, AGoalX, AGoalY: Integer; AMaxNodes: Integer): TGridPath;
const
  Dirs: array[0..7] of TGridPoint = (
    (X: 1; Y: 0), (X: -1; Y: 0), (X: 0; Y: 1), (X: 0; Y: -1),
    (X: 1; Y: 1), (X: 1; Y: -1), (X: -1; Y: 1), (X: -1; Y: -1)
  );
var
  Heap: TMinHeap;
  GScore: array of Double;
  CameFrom: array of Integer;
  Closed: array of Boolean;
  NumCells: Integer;
  Current, Node: TAStarNode;
  CurIdx, NIdx: Integer;
  i, nx, ny: Integer;
  StepCost, TentativeG, MinCost: Double;
  NodesPopped, PathLen, Idx: Integer;

  // Octile distance (allows diagonal movement) scaled by the cheapest
  // passable move cost anywhere in the palette - keeps the heuristic
  // admissible (never overestimates true remaining cost) so A* stays
  // optimal rather than degrading into a greedy approximation.
  function Heuristic(HX, HY: Integer): Double;
  var
    dx, dy: Double;
  begin
    dx := Abs(HX - AGoalX);
    dy := Abs(HY - AGoalY);
    Result := (Max(dx, dy) + (Sqrt(2) - 1) * Min(dx, dy)) * MinCost;
  end;

begin
  SetLength(Result, 0);
  if (AStartX < 0) or (AStartX >= AGrid.Width) or (AStartY < 0) or (AStartY >= AGrid.Height) then Exit;
  if (AGoalX < 0) or (AGoalX >= AGrid.Width) or (AGoalY < 0) or (AGoalY >= AGrid.Height) then Exit;
  if CellMoveCost(AGrid, AConfig, AGoalX, AGoalY) <= 0 then Exit; // goal is impassable
  if CellMoveCost(AGrid, AConfig, AStartX, AStartY) <= 0 then Exit; // start is impassable

  MinCost := Infinity;
  for i := 0 to High(AConfig.Classes) do
    if (AConfig.Classes[i].MoveCost > 0) and (AConfig.Classes[i].MoveCost < MinCost) then
      MinCost := AConfig.Classes[i].MoveCost;
  if IsInfinite(MinCost) then MinCost := 0.5; // no passable classes found - fallback, shouldn't happen with a real palette

  NumCells := AGrid.Width * AGrid.Height;
  SetLength(GScore, NumCells);
  SetLength(CameFrom, NumCells);
  SetLength(Closed, NumCells);
  for i := 0 to NumCells - 1 do
  begin
    GScore[i] := Infinity;
    CameFrom[i] := -1;
    Closed[i] := False;
  end;

  Heap := TMinHeap.Create;
  try
    CurIdx := AStartY * AGrid.Width + AStartX;
    GScore[CurIdx] := 0;
    Node.X := AStartX; Node.Y := AStartY; Node.G := 0; Node.F := Heuristic(AStartX, AStartY);
    Heap.Push(Node);

    NodesPopped := 0;
    while not Heap.IsEmpty do
    begin
      Current := Heap.Pop;
      CurIdx := Current.Y * AGrid.Width + Current.X;
      if Closed[CurIdx] then Continue; // stale entry - a cheaper path to this cell was already processed
      Closed[CurIdx] := True;
      Inc(NodesPopped);
      if NodesPopped > AMaxNodes then Break; // safety valve - see function header comment

      if (Current.X = AGoalX) and (Current.Y = AGoalY) then
      begin
        PathLen := 0;
        Idx := CurIdx;
        while Idx >= 0 do begin Inc(PathLen); Idx := CameFrom[Idx]; end;
        SetLength(Result, PathLen);
        Idx := CurIdx;
        i := PathLen - 1;
        while Idx >= 0 do
        begin
          Result[i].X := Idx mod AGrid.Width;
          Result[i].Y := Idx div AGrid.Width;
          Idx := CameFrom[Idx];
          Dec(i);
        end;
        Exit;
      end;

      for i := 0 to 7 do
      begin
        nx := Current.X + Dirs[i].X;
        ny := Current.Y + Dirs[i].Y;
        if (nx < 0) or (nx >= AGrid.Width) or (ny < 0) or (ny >= AGrid.Height) then Continue;
        NIdx := ny * AGrid.Width + nx;
        if Closed[NIdx] then Continue;

        StepCost := CellMoveCost(AGrid, AConfig, nx, ny);
        if StepCost <= 0 then Continue; // impassable

        if (Dirs[i].X <> 0) and (Dirs[i].Y <> 0) then
          StepCost := StepCost * Sqrt(2); // diagonal step covers more ground

        TentativeG := Current.G + StepCost;
        if TentativeG < GScore[NIdx] then
        begin
          GScore[NIdx] := TentativeG;
          CameFrom[NIdx] := CurIdx;
          Node.X := nx; Node.Y := ny; Node.G := TentativeG; Node.F := TentativeG + Heuristic(nx, ny);
          Heap.Push(Node);
        end;
      end;
    end;
    // heap exhausted, or node budget hit, without reaching the goal - Result stays empty
  finally
    Heap.Free;
  end;
end;

end.
