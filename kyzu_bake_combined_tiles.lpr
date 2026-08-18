program kyzu_bake_combined_tiles;
{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, Math, FPImage, FPWritePNG, kyzu_geotiff, kyzu_palette;

const
  TileSize = 256;
  GlobCoverPath = 'C:\dev\kyzu_data\Globcover2009_V2.3_Global_\GLOBCOVER_L4_200901_200912_V2.3.tif';
  ElevationPath = 'C:\dev\kyzu_data\ETOPO_2022_v1_60s_N90W180_surface.tif';
  PalettePath = 'globcover_palette.json';
  TilesOutDir = 'C:\dev\kyzu_data\public\tiles_combined';

  // GlobCover's own coverage limit - south of this, fall back to
  // ETOPO-derived land/ocean instead of guessing.
  GlobCoverLatSouth = -65.0;

  LightX = -0.5;
  LightY = 0.5;
  LightZ = 0.7;
  MetresPerDegreeLat = 110540.0;
  MetresPerDegreeLonAtEquator = 111320.0;

var
  Palette: TGlobCoverPalette;
  LandCoverReader, ElevationReader: TGeoTIFFReader;

function SampleElevationAt(Lon, Lat: Double): Single;
var
  SrcX, SrcY: Integer;
begin
  SrcX := Round((Lon - (-180.0)) / 360.0 * ElevationReader.Width);
  SrcY := Round((90.0 - Lat) / 180.0 * ElevationReader.Height);
  if SrcX < 0 then SrcX := 0;
  if SrcX >= ElevationReader.Width then SrcX := ElevationReader.Width - 1;
  if SrcY < 0 then SrcY := 0;
  if SrcY >= ElevationReader.Height then SrcY := ElevationReader.Height - 1;
  Result := ElevationReader.GetFloatSample(SrcX, SrcY);
end;

// Returns the GlobCover class ID for this lon/lat - sampled directly where
// GlobCover has coverage, or derived from ETOPO's land/ocean sign where it
// doesn't (south of GlobCoverLatSouth). This replaces the old blanket
// "everything south of 65S is ice" approach with ETOPO's actual coastline:
// land (elevation > 0) becomes ice, ocean stays water - so the Southern
// Ocean renders correctly instead of being iced over along with Antarctica.
function SampleClassAt(Lon, Lat: Double): Byte;
var
  SrcX, SrcY: Integer;
begin
  if Lat < GlobCoverLatSouth then
  begin
    if SampleElevationAt(Lon, Lat) > 0 then
      Result := 220  // land, per ETOPO - Antarctic ice sheet
    else
      Result := 210; // ocean, per ETOPO - Southern Ocean, not ice
    Exit;
  end;

  SrcX := Round((Lon - (-180.0)) / 360.0 * LandCoverReader.Width);
  SrcY := Round((90.0 - Lat) / (90.0 - GlobCoverLatSouth) * LandCoverReader.Height);
  if SrcX < 0 then SrcX := 0;
  if SrcX >= LandCoverReader.Width then SrcX := LandCoverReader.Width - 1;
  if SrcY < 0 then SrcY := 0;
  if SrcY >= LandCoverReader.Height then SrcY := LandCoverReader.Height - 1;
  Result := LandCoverReader.GetByteSample(SrcX, SrcY);
end;

// Identical technique to kyzu_bake_heightmap_tiles's hillshade - slope
// estimated via finite differences scaled to the current tile's angular
// resolution, so shading detail matches sampling density at every zoom.
// Applies uniformly above and below sea level, which is what makes
// undersea trenches show up the same way mountain ridges do - no special
// casing needed for bathymetry vs. topography.
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
  if Abs(cosLat) < 0.01 then cosLat := 0.01;

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
  ClassID: Byte;
  R, G, B: Byte;
  Shade, Mult: Double;
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

        ClassID := SampleClassAt(Lon, Lat);
        PaletteClassRGB(Palette, ClassID, R, G, B);
        Shade := ComputeShade(Lon, Lat, StepLon, StepLat);
        Mult := EnsureRange(0.55 + 0.55 * Shade, 0.35, 1.35);

        Col.Red := Round(EnsureRange(R * Mult, 0, 255)) shl 8;
        Col.Green := Round(EnsureRange(G * Mult, 0, 255)) shl 8;
        Col.Blue := Round(EnsureRange(B * Mult, 0, 255)) shl 8;
        Col.Alpha := $FFFF;

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

  WriteLn('Loading palette from ', PalettePath, ' ...');
  Palette := LoadPalette(PalettePath);
  WriteLn('  ', Length(Palette), ' classes loaded.');

  StartTime := Now;
  WriteLn('Opening ', GlobCoverPath, ' ...');
  LandCoverReader := TGeoTIFFReader.Create(GlobCoverPath);
  WriteLn('Opening ', ElevationPath, ' ...');
  ElevationReader := TGeoTIFFReader.Create(ElevationPath);
  try
    WriteLn('Land cover source: ', LandCoverReader.Width, ' x ', LandCoverReader.Height);
    WriteLn('Elevation source: ', ElevationReader.Width, ' x ', ElevationReader.Height);

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
    LandCoverReader.Free;
    ElevationReader.Free;
  end;
  WriteLn('All done. Total time: ', MilliSecondsBetween(Now, StartTime), ' ms');
end.

