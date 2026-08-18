program kyzu_bake_tiles;
{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, Math, FPImage, FPWritePNG, kyzu_geotiff, kyzu_palette;

const
  TileSize = 256;

  // Same coverage convention as kyzu_bake_terrain: GlobCover's readme
  // states 90N to 65S - south of that gets treated as ice.
  SourceLatNorth = 90.0;
  SourceLatSouth = -65.0;

  SourceTIFFPath = 'GLOBCOVER_L4_200901_200912_V2.3.tif';
  PalettePath = 'globcover_palette.json';
  TilesOutDir = 'tiles';

var
  Palette: TGlobCoverPalette;
  Reader: TGeoTIFFReader;

// Shared sampling logic - identical mapping to kyzu_bake_terrain, just
// called per-tile-pixel here instead of per-global-grid-pixel.
function SampleClassAt(Lon, Lat: Double): Byte;
var
  SrcX, SrcY: Integer;
begin
  if Lat < SourceLatSouth then
  begin
    Result := 220; // south of GlobCover's coverage - ice stand-in
    Exit;
  end;
  SrcX := Round((Lon - (-180.0)) / 360.0 * Reader.Width);
  SrcY := Round((SourceLatNorth - Lat) / (SourceLatNorth - SourceLatSouth) * Reader.Height);
  if SrcX < 0 then SrcX := 0;
  if SrcX >= Reader.Width then SrcX := Reader.Width - 1;
  if SrcY < 0 then SrcY := 0;
  if SrcY >= Reader.Height then SrcY := Reader.Height - 1;
  Result := Reader.GetByteSample(SrcX, SrcY);
end;

procedure BakeTile(ALevel, ATileX, ATileY: Integer);
var
  TilesAcross, TilesDown: Integer;
  LonMin, LonMax, LatMin, LatMax: Double;
  Img: TFPMemoryImage;
  Writer: TFPWriterPNG;
  px, py: Integer;
  Lon, Lat: Double;
  ClassID: Byte;
  Dir, FileName: string;
begin
  TilesAcross := 1 shl (ALevel + 1);
  TilesDown := 1 shl ALevel;

  LonMin := -180.0 + ATileX * (360.0 / TilesAcross);
  LonMax := LonMin + (360.0 / TilesAcross);
  LatMax := 90.0 - ATileY * (180.0 / TilesDown);
  LatMin := LatMax - (180.0 / TilesDown);

  Img := TFPMemoryImage.Create(TileSize, TileSize);
  try
    for py := 0 to TileSize - 1 do
      for px := 0 to TileSize - 1 do
      begin
        Lon := LonMin + (px + 0.5) / TileSize * (LonMax - LonMin);
        Lat := LatMax - (py + 0.5) / TileSize * (LatMax - LatMin);
        ClassID := SampleClassAt(Lon, Lat);
        Img.Colors[px, py] := PaletteClassColor(Palette, ClassID);
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

      // ty outer, tx inner: all tiles in one ty row share the same latitude
      // band, so they tend to reuse the same cached source strip(s) -
      // matches the row-major cache-friendly pattern from kyzu_bake_terrain.
      for ty := 0 to TilesDown - 1 do
      begin
        for tx := 0 to TilesAcross - 1 do
        begin
          BakeTile(Level, tx, ty);
          Inc(DoneTiles);
        end;
      end;
      WriteLn('  level ', Level, ' done in ', MilliSecondsBetween(Now, LevelStartTime), ' ms  (',
        DoneTiles, '/', TotalTiles, ' total tiles so far)');
    end;
  finally
    Reader.Free;
  end;
  WriteLn('All done. Total time: ', MilliSecondsBetween(Now, StartTime), ' ms');
end.
