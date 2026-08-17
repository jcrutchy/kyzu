program kyzu_bake_heightmap_tiles;
{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, Math, FPImage, FPWritePNG, kyzu_geotiff;

const
  TileSize = 256;
  SourceTIFFPath = 'C:\dev\kyzu_data\ETOPO_2022_v1_60s_N90W180_surface.tif';
  TilesOutDir = 'tiles_heightmap';

  // Light direction for hillshading - from the upper-left at a moderately
  // high angle, the standard cartographic convention (matches how relief
  // maps have been shaded since well before computers did it).
  LightX = -0.5;
  LightY = 0.5;
  LightZ = 0.7;

  // Metres per degree - longitude gets a cos(lat) correction applied at
  // use time since it shrinks toward the poles; latitude spacing is
  // ~constant so a fixed approximation is fine here.
  MetresPerDegreeLat = 110540.0;
  MetresPerDegreeLonAtEquator = 111320.0;

type
  TColorStop = record
    Elevation: Double;
    R, G, B: Byte;
  end;

const
  // Hypsometric tint control points, elevation in metres. Linearly
  // interpolated between neighbouring stops.
  ColorStops: array[0..10] of TColorStop = (
    (Elevation: -8000; R: 10;  G: 10;  B: 40),
    (Elevation: -4000; R: 15;  G: 40;  B: 90),
    (Elevation: -2000; R: 25;  G: 80;  B: 140),
    (Elevation: -200;  R: 60;  G: 130; B: 190),
    (Elevation: 0;      R: 90;  G: 170; B: 210),
    (Elevation: 1;      R: 70;  G: 140; B: 70),
    (Elevation: 300;    R: 110; G: 160; B: 70),
    (Elevation: 1000;   R: 180; G: 180; B: 100),
    (Elevation: 2200;   R: 170; G: 130; B: 90),
    (Elevation: 3500;   R: 190; G: 180; B: 170),
    (Elevation: 5500;   R: 255; G: 255; B: 255)
  );

function HypsometricColor(AElev: Double): TFPColor;
var
  i: Integer;
  t: Double;
  r, g, b: Double;
begin
  if AElev <= ColorStops[0].Elevation then
  begin
    r := ColorStops[0].R; g := ColorStops[0].G; b := ColorStops[0].B;
  end
  else if AElev >= ColorStops[High(ColorStops)].Elevation then
  begin
    r := ColorStops[High(ColorStops)].R;
    g := ColorStops[High(ColorStops)].G;
    b := ColorStops[High(ColorStops)].B;
  end
  else
  begin
    i := 0;
    while (i < High(ColorStops)) and (ColorStops[i + 1].Elevation < AElev) do
      Inc(i);
    t := (AElev - ColorStops[i].Elevation) / (ColorStops[i + 1].Elevation - ColorStops[i].Elevation);
    r := ColorStops[i].R + t * (ColorStops[i + 1].R - ColorStops[i].R);
    g := ColorStops[i].G + t * (ColorStops[i + 1].G - ColorStops[i].G);
    b := ColorStops[i].B + t * (ColorStops[i + 1].B - ColorStops[i].B);
  end;

  Result.Red := Round(EnsureRange(r, 0, 255)) shl 8;
  Result.Green := Round(EnsureRange(g, 0, 255)) shl 8;
  Result.Blue := Round(EnsureRange(b, 0, 255)) shl 8;
  Result.Alpha := $FFFF;
end;

var
  Reader: TGeoTIFFReader;

function SampleElevationAt(Lon, Lat: Double): Single;
var
  SrcX, SrcY: Integer;
begin
  SrcX := Round((Lon - (-180.0)) / 360.0 * Reader.Width);
  SrcY := Round((90.0 - Lat) / 180.0 * Reader.Height);
  if SrcX < 0 then SrcX := 0;
  if SrcX >= Reader.Width then SrcX := Reader.Width - 1;
  if SrcY < 0 then SrcY := 0;
  if SrcY >= Reader.Height then SrcY := Reader.Height - 1;
  Result := Reader.GetFloatSample(SrcX, SrcY);
end;

// Shading multiplier via finite-difference slope estimate. StepLon/StepLat
// are in degrees and should match the CURRENT tile's per-pixel angular
// size, so shading detail naturally coarsens when zoomed out (matching
// the sampling density) rather than always probing single-source-pixel
// gaps, which would look noisy at low zoom and under-detailed at high zoom.
function ComputeShade(Lon, Lat, StepLon, StepLat: Double): Double;
var
  hL, hR, hD, hU: Single;
  dzdx, dzdy: Double;
  nx, ny, nz, len: Double;
  lx, ly, lz: Double;
  cosLat: Double;
begin
  hL := SampleElevationAt(Lon - StepLon, Lat);
  hR := SampleElevationAt(Lon + StepLon, Lat);
  hD := SampleElevationAt(Lon, Lat - StepLat);
  hU := SampleElevationAt(Lon, Lat + StepLat);

  cosLat := Cos(Lat * Pi / 180.0);
  if Abs(cosLat) < 0.01 then cosLat := 0.01; // avoid blowup right at the poles

  dzdx := (hR - hL) / (2 * StepLon * MetresPerDegreeLonAtEquator * cosLat);
  dzdy := (hU - hD) / (2 * StepLat * MetresPerDegreeLat);

  nx := -dzdx; ny := -dzdy; nz := 1.0;
  len := Sqrt(nx * nx + ny * ny + nz * nz);
  nx := nx / len; ny := ny / len; nz := nz / len;

  lx := LightX; ly := LightY; lz := LightZ;
  len := Sqrt(lx * lx + ly * ly + lz * lz);
  lx := lx / len; ly := ly / len; lz := lz / len;

  Result := nx * lx + ny * ly + nz * lz;
end;

procedure BakeTile(ALevel, ATileX, ATileY: Integer);
var
  TilesAcross, TilesDown: Integer;
  LonMin, LonMax, LatMin, LatMax: Double;
  StepLon, StepLat: Double;
  Img: TFPMemoryImage;
  Writer: TFPWriterPNG;
  px, py: Integer;
  Lon, Lat: Double;
  Elev: Single;
  Shade: Double;
  Col: TFPColor;
  Dir, FileName: string;
begin
  TilesAcross := 1 shl (ALevel + 1);
  TilesDown := 1 shl ALevel;

  LonMin := -180.0 + ATileX * (360.0 / TilesAcross);
  LonMax := LonMin + (360.0 / TilesAcross);
  LatMax := 90.0 - ATileY * (180.0 / TilesDown);
  LatMin := LatMax - (180.0 / TilesDown);

  StepLon := (LonMax - LonMin) / TileSize;
  StepLat := (LatMax - LatMin) / TileSize;

  Img := TFPMemoryImage.Create(TileSize, TileSize);
  try
    for py := 0 to TileSize - 1 do
      for px := 0 to TileSize - 1 do
      begin
        Lon := LonMin + (px + 0.5) / TileSize * (LonMax - LonMin);
        Lat := LatMax - (py + 0.5) / TileSize * (LatMax - LatMin);

        Elev := SampleElevationAt(Lon, Lat);
        Shade := ComputeShade(Lon, Lat, StepLon, StepLat);

        Col := HypsometricColor(Elev);
        // ambient + directional term, clamped so nothing goes fully black/blown-out
        Col.Red := Round(EnsureRange((Col.Red shr 8) * EnsureRange(0.55 + 0.55 * Shade, 0.35, 1.35), 0, 255)) shl 8;
        Col.Green := Round(EnsureRange((Col.Green shr 8) * EnsureRange(0.55 + 0.55 * Shade, 0.35, 1.35), 0, 255)) shl 8;
        Col.Blue := Round(EnsureRange((Col.Blue shr 8) * EnsureRange(0.55 + 0.55 * Shade, 0.35, 1.35), 0, 255)) shl 8;

        Img.Colors[px, py] := Col;
      end;

    Dir := Format('%s/%d/%d', [TilesOutDir, ALevel, ATileX]);
    ForceDirectories(Dir);
    FileName := Format('%s/%d.png', [Dir, ATileY]);

    Writer := TFPWriterPNG.Create;
    try
      Img.SaveToFile(FileName, Writer);
    finally
      Writer.Free;
    end;
  finally
    Img.Free;
  end;
end;

var
  MaxLevel, Level, tx, ty, TilesAcross, TilesDown: Integer;
  TotalTiles, DoneTiles: Int64;
  StartTime, LevelStartTime: TDateTime;
begin
  MaxLevel := 6;
  if ParamCount >= 1 then
    MaxLevel := StrToIntDef(ParamStr(1), 6);

  TotalTiles := 0;
  for Level := 0 to MaxLevel do
    Inc(TotalTiles, Int64(1 shl (Level + 1)) * Int64(1 shl Level));
  WriteLn('Max level: ', MaxLevel, '  Total tiles to bake: ', TotalTiles);

  StartTime := Now;
  WriteLn('Opening ', SourceTIFFPath, ' ...');
  Reader := TGeoTIFFReader.Create(SourceTIFFPath);
  try
    WriteLn('Source: ', Reader.Width, ' x ', Reader.Height);

    DoneTiles := 0;
    for Level := 0 to MaxLevel do
    begin
      TilesAcross := 1 shl (Level + 1);
      TilesDown := 1 shl Level;
      LevelStartTime := Now;
      WriteLn('Level ', Level, ': ', TilesAcross, ' x ', TilesDown, ' tiles');

      for ty := 0 to TilesDown - 1 do
        for tx := 0 to TilesAcross - 1 do
        begin
          BakeTile(Level, tx, ty);
          Inc(DoneTiles);
        end;

      WriteLn('  level ', Level, ' done in ', MilliSecondsBetween(Now, LevelStartTime), ' ms  (',
        DoneTiles, '/', TotalTiles, ' total tiles so far)');
    end;
  finally
    Reader.Free;
  end;
  WriteLn('All done. Total time: ', MilliSecondsBetween(Now, StartTime), ' ms');
end.

