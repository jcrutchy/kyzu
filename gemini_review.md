Here is a comprehensive review, critique, and deep-dive debugging of the Kyzu codebase across concurrency, simulation logic, spatial mathematics, persistence, and data pipelines.

---

### 1. Critical Concurrency Hazards & Thread Safety

#### A. Stale State Overwrites and Unit Resurrection in `AdvanceUnits`
In `kyzu.lpr`, `AdvanceUnits` runs on the main game loop thread while commands arrive concurrently on `TStdinReaderThread`.

```pascal
UnitsLock.Enter;
try
  if not Units.TryGetValue(Keys[i], U) then Continue;
finally
  UnitsLock.Leave;
end;

// ... moves U in local record ...

UnitsLock.Enter;
try
  Units.AddOrSetValue(Keys[i], U);
finally
  UnitsLock.Leave;
end;
```
* **The Bug:** Between reading `U` and writing back `Units.AddOrSetValue(Keys[i], U)`, `UnitsLock` is released.
  1. If `HandleMove` runs concurrently on `TStdinReaderThread`, it assigns a new path to `U` under lock and completes. Immediately after, `AdvanceUnits` overwrites `Units[Keys[i]]` with its stale snapshot, **erasing the new path**.
  2. If `HandleAttack` or `HandleDespawn` kills or despawns the unit (`Units.Remove(unit_id)`), `AdvanceUnits` finishes its step and calls `Units.AddOrSetValue(Keys[i], U)`, **resurrecting the dead/despawned unit back into existence**.
* **Fix:** Hold `UnitsLock` across the single-unit step, or perform a conditional check before writing back: verify that `Units.TryGetValue(Keys[i], CurrentU)` still exists and that `CurrentU.Path` matches what was being stepped before replacing.

#### B. Thread Termination on Unhandled Exceptions
In `TStdinReaderThread.Execute`:
```pascal
procedure TStdinReaderThread.Execute;
var Line: string;
begin
  while not Terminated do
  begin
    if Eof(Input) then Break;
    ReadLn(Line);
    if Line <> '' then
      DispatchIncoming(Line);
  end;
end;
```
* **The Bug:** There is no `try...except` block protecting `DispatchIncoming`. If any payload triggers a runtime exception (e.g. `EInvalidOp` from `Trunc(NaN)`, an index out of bounds, or JSON casting mismatch), the reader thread silently terminates. The main tick loop continues running, but the server becomes permanently deaf to all incoming commands.
* **Fix:** Wrap the invocation in a `try...except` logging to `LogDiag`.

---

### 2. Geometry, Wrap-Around & Coordinate Math Bugs

#### A. The Antimeridian Seam Backtracking Bug
`kyzu_pathfinding.pas` correctly supports toroidal wrap-around across the $180^\circ$ meridian:
`nx := (Current.X + Dirs[i].X + AGrid.Width) mod AGrid.Width;`

However, look at how `AdvanceUnits` in `kyzu.lpr` moves the unit along that path:
```pascal
TargetX := U.Path[U.PathIndex + 1].X;
TargetY := U.Path[U.PathIndex + 1].Y;

DX := (TargetX + 0.5) - U.GX;
DY := (TargetY + 0.5) - U.GY;
Dist := Sqrt(DX * DX + DY * DY);
```
* **The Bug:** If `Grid.Width = 1300`, and a unit at `U.GX = 1299.5` steps east across the antimeridian to `TargetX = 0`:
  $$\text{DX} = (0 + 0.5) - 1299.5 = -1299.0$$
  Instead of taking a $1$-cell step eastward across the seam, $\text{DX}$ is $-1299.0$. The unit will spend hundreds of ticks **slowly walking in reverse across the entire planet**, straight through impassable terrain and oceans!
* **Fix:** Apply toroidal delta-wrapping to `DX`:
```pascal
DX := (TargetX + 0.5) - U.GX;
if DX > Grid.Width / 2.0 then
  DX := DX - Grid.Width
else if DX < -Grid.Width / 2.0 then
  DX := DX + Grid.Width;
```
And wrap `U.GX` after updating:
```pascal
U.GX := (U.GX + Grid.Width);
while U.GX >= Grid.Width do U.GX := U.GX - Grid.Width;
```

#### B. City Center Asymmetry in Combat (`HandleAttack`)
In `HandleAttack`:
```pascal
Dist := Sqrt(Sqr(Attacker.GX - TargetCity.GX) + Sqr(Attacker.GY - TargetCity.GY));
if Dist > AttackRangeCells then
  Reason := 'too far';
```
* **The Bug:** `Attacker.GX` and `Attacker.GY` are fractional coordinates centered on the cell (`X + 0.5`). But `TargetCity.GX` and `TargetCity.GY` are raw integer coordinates (`X`, `Y`).
  - An attacker standing at `(10.5, 10.5)` attacking a city at cell `(10, 10)` calculates:
    $\Delta X = 0.5, \Delta Y = 0.5 \implies \text{Dist} \approx 0.707$
  - An attacker directly east at `(12.5, 10.5)` calculates:
    $\Delta X = 2.5, \Delta Y = 0.5 \implies \text{Dist} \approx 2.55 > 1.5$ (Out of range!)
  - An attacker directly west at `(8.5, 10.5)` calculates:
    $\Delta X = -1.5, \Delta Y = 0.5 \implies \text{Dist} \approx 1.58 \approx \text{in range}$
* **Fix:** Compare against cell centers:
```pascal
Dist := Sqrt(Sqr(Attacker.GX - (TargetCity.GX + 0.5)) + Sqr(Attacker.GY - (TargetCity.GY + 0.5)));
```

#### C. Antimeridian Blindness in Range Checks (`Attack`, `Collect`, `AI`)
In `HandleCollect`, `HandleAttack`, and `RunAI`, distances between units and nodes/targets are computed as:
```pascal
Dist := Sqrt(Sqr(U.GX - Node.GX) + Sqr(U.GY - Node.GY));
```
* **The Bug:** If a unit is at $X = 0.5$ and a resource node is at $X = 1299.5$, the computed distance is $1299.0$ cells instead of $1.0$ cell. Units are completely unable to harvest nodes or attack targets across the international date line.
* **Fix:** Use wrapped $\Delta X$ distance for all proximity checks:
```pascal
dx := Abs(U.GX - Node.GX);
if dx > Grid.Width / 2.0 then dx := Grid.Width - dx;
dy := Abs(U.GY - Node.GY);
Dist := Sqrt(dx * dx + dy * dy);
```

#### D. Out-of-Bounds on Extremes ($180^\circ$ and $-90^\circ$)
In `LonToGridX` and `LatToGridY`:
```pascal
function LonToGridX(Lon: Double): Integer;
begin
  Result := Trunc((Lon - (-180.0)) / 360.0 * Grid.Width);
end;

function LatToGridY(Lat: Double): Integer;
begin
  Result := Trunc((90.0 - Lat) / 180.0 * Grid.Height);
end;
```
* If `Lon = 180.0`, `(180 - (-180)) / 360.0 * Grid.Width = Grid.Width`.
* If `Lat = -90.0`, `(90 - (-90)) / 180.0 * Grid.Height = Grid.Height`.
`Result` equals `Grid.Width` or `Grid.Height`, which is an out-of-bounds index ($0 \le \text{index} < \text{Size}$).
* **Fix:** Clamp `LonToGridX` and `LatToGridY` with `EnsureRange(Result, 0, Grid.Width - 1)` or modulo wrap for longitude.

---

### 3. Protocol & Persistence Inconsistencies

#### A. System Locale Breaking JSON (`DecimalSeparator`)
Throughout `kyzu.lpr`, floats are formatted via `Format('%.4f', ...)`:
```pascal
LogEvent(Format('{"type":"spawned","unit_id":"%s",...,"lon":%.4f,"lat":%.4f}', ...));
```
* **The Bug:** `Format` in Free Pascal is locale-sensitive. On any system configured with European/non-English regional settings, `DefaultFormatSettings.DecimalSeparator` is `,` (comma).
  - Output becomes: `{"lon": 21,0000, "lat": 13,5000}`.
  - This is **invalid JSON**.
  - `GetJSON` in `ReplayEventLog` will fail and skip lines on startup, corrupting game state replay.
* **Fix:** Force standard decimal format at initialization in `kyzu.lpr`:
```pascal
DefaultFormatSettings.DecimalSeparator := '.';
```

#### B. JSON Ingestion vs Output Shape Mismatch
Notice how Kyzu emits messages:
```pascal
SendLine(Format('{"topic":"game.event.spawned","payload":"{\"unit_id\":\"%s\",...}"}', [...]));
```
`payload` is emitted as an **escaped string** inside outer JSON quotes.
Yet `DispatchIncoming` expects:
```pascal
PayloadData := Obj.Find('payload');
if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
  Handle*(TJSONObject(PayloadData));
```
`payload` is required to be a **raw JSON Object**. If a client mirrors Kyzu's own output convention and sends `payload` as a stringified JSON string, `PayloadData.JSONType` is `jtString` and the command is silently dropped.
* **Fix:** If `PayloadData.JSONType = jtString`, parse it via `GetJSON(PayloadData.AsString)` before dispatching, or emit clean unescaped JSON objects using `TJSONObject`.

#### C. Unchecked State Hijacking / Overwriting
In `HandleSpawn`, `HandleFoundCity`, and `HandleBuildRoad`:
* `Units.AddOrSetValue(UnitID, U)`
* `Cities.AddOrSetValue(CityID, C)`
* `Roads.AddOrSetValue(RoadID, R)`
* **The Bug:** None of these verify whether the ID is already claimed. Any client can send `game.cmd.found_city` with `city_id: "city_ai_home"` and overwrite an opponent's capital, completely resetting its population and stealing its ownership.

---

### 4. Simulation Logic Flaws

#### A. Ghost Roads and Dangling Infrastructure
In `ProcessCityUpkeep`, when a city's population drops to zero:
```pascal
CitiesLock.Enter;
try
  Cities.Remove(Keys[i]);
finally
  CitiesLock.Leave;
end;
LogEvent(Format('{"type":"city_abandoned",...}'));
```
* **The Bug:** Roads connected to that city (`FromCityID` or `ToCityID`) are **never deleted**.
  1. `RecomputeDevelopment` iterates through all roads in `Roads.Values` and continues stamping road density into the map around an abandoned/deleted city.
  2. The dead roads remain stored and will be reloaded on every replay.
* **Fix:** When a city is abandoned, prune any roads referencing that city from `Roads` and emit/log a `road_removed` event.

#### B. `RecomputeDevelopment` Does Not Emit Zero Deltas
In `RecomputeDevelopment`:
```pascal
for Pair in Contrib do
begin
  Cell := Pair.Value;
  NewDensity.Add(Pair.Key, Cell);
  OldCell.Level := 0;
  Density.TryGetValue(Pair.Key, OldCell);
  if Abs(Integer(Cell.Level) - Integer(OldCell.Level)) >= DevelopmentBroadcastThreshold then
  begin
    // emits delta
  end;
end;
Density.Free;
Density := NewDensity;
```
* **The Bug:** It only iterates over cells that exist in `Contrib` (active influence).
  If a city shrinks, is captured, or is abandoned, cells that were previously developed now have an intensity of `0` and are completely absent from `Contrib`.
  `RecomputeDevelopment` never inspects entries in `Density` that are absent in `Contrib`. Consequently, **it never sends `d: 0` to connected clients**.
  On the client-side viewer, decaying urban areas will remain rendered at their peak density forever.
* **Fix:** Scan existing `Density` keys: if a key is not found in `Contrib`, emit `{"gx": OldCell.GX, "gy": OldCell.GY, "d": 0}` if `OldCell.Level >= DevelopmentBroadcastThreshold`.

---

### 5. GeoTIFF LZW Decompressor & Memory Leak

#### A. Off-by-One in TIFF LZW Early Change
In `kyzu_geotiff.pas`, the commentary notes that two strips in GlobCover cause "LZW bitstream desync" and attributes it to corrupted source data. Looking closely at `LZWDecompress`:
```pascal
Dict[DictCount] := NewEntry;
Inc(DictCount);

// Early change - see unit header comment. Deliberately checked
// against the boundary values, not >= a power of two.
if DictCount = 511 then CodeSize := 10
else if DictCount = 1023 then CodeSize := 11
else if DictCount = 2047 then CodeSize := 12;
```
* **The Bug:** `DictCount` begins at `258`.
  When `DictCount = 510`, `Dict[510] := NewEntry` is written, followed by `Inc(DictCount)`.
  Now `DictCount` becomes `511`.
  The check `if DictCount = 511 then CodeSize := 10` evaluates to **True**!
  The code size is increased to 10 bits when the table only contains 511 entries (indices 0..510). Entry 511 ($2^9 - 1 = 511$, which fits in 9 bits) has **not** even been added yet.
  In the TIFF 6.0 specification, code size bumps to 10 bits when code 511 is entered into the table (meaning the *next* code will be 512, requiring 10 bits).
  Because `Inc(DictCount)` happened on the preceding line, checking `DictCount = 511` switches bit widths **one code too early**.
* **Fix:**
```pascal
if DictCount = 512 then CodeSize := 10
else if DictCount = 1024 then CodeSize := 11
else if DictCount = 2048 then CodeSize := 12;
```

#### B. Unbounded GeoTIFF Chunk Cache
In `TGeoTIFFReader.GetChunkData`:
```pascal
FChunkCache.Add(AChunkIndex, Data);
Result := Data;
```
* **The Bug:** `FChunkCache` is a simple `TDictionary<Integer, TBytes>`. It never evicts elements.
  When baking high-zoom tile pyramids over GlobCover ($129{,}600 \times 40{,}000$ pixels), hundreds of uncompressed chunks are held in RAM simultaneously, quickly consuming gigabytes of memory and triggering `EOutOfMemory`.
* **Fix:** Implement a bounded ring-buffer or LRU cache holding only the most recent $N$ chunks (e.g. 16 or 32 strips).

---

### 6. Performance: JSON Churn in 20Hz Tick Loop
In `RunAI`:
```pascal
PayloadStr := Format('{"unit_id":"%s","node_id":"%s","by":"%s"}', ...);
PayloadData := GetJSON(PayloadStr);
try
  HandleCollect(TJSONObject(PayloadData));
finally
  PayloadData.Free;
end;
```
* Every tick (50ms), for every AI unit, `RunAI` formats text strings and runs `GetJSON` to build a `TJSONObject` just to pass it into `HandleCollect`, `HandleMove`, or `HandleSpawn`.
* While reusing `Handle*` keeps rules unified, formatting strings to parse them back into JSON objects 20 times a second creates high GC/heap allocation pressure.
* **Fix:** Either construct the `TJSONObject` directly via object methods (`TJSONObject.Create(['unit_id', UnitID, ...])`) or extract the internal domain logic (`DoMove(...)`, `DoCollect(...)`) so both client JSON handlers and internal AI call the same core methods without JSON marshaling overhead.
