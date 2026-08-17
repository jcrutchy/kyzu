program kyzu_bake_tiles;
{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, Math, FPImage, FPWritePNG, kyzu_geotiff;

const
  TileSize = 256;

  // Same coverage convention as kyzu_bake_terrain: GlobCover's readme
  // states 90N to 65S - south of that gets treated as ice.
  SourceLatNorth = 90.0;
  SourceLatSouth = -65.0;

  SourceTIFFPath = 'C:\dev\kyzu_data\Globcover2009_V2.3_Global_\GLOBCOVER_L4_200901_200912_V2.3.tif';
  TilesOutDir = 'tiles';

type
  TGlobCoverClass = record
    ID: Byte;
    R, G, B: Byte;
    Name: string;
  end;

const
  GlobCoverClasses: array[0..22] of TGlobCoverClass = (
    (ID: 11;  R:170; G:240; B:240; Name: 'Irrigated cropland (or aquatic)'),
    (ID: 14;  R:255; G:255; B:100; Name: 'Rainfed cropland'),
    (ID: 20;  R:220; G:240; B:100; Name: 'Cropland/vegetation mosaic'),
    (ID: 30;  R:205; G:205; B:102; Name: 'Vegetation/cropland mosaic'),
    (ID: 40;  R:  0; G:100; B:  0; Name: 'Broadleaved evergreen forest'),
    (ID: 50;  R:  0; G:160; B:  0; Name: 'Broadleaved deciduous forest'),
    (ID: 60;  R:170; G:200; B:  0; Name: 'Open deciduous forest/woodland'),
    (ID: 70;  R:  0; G: 60; B:  0; Name: 'Needleleaved evergreen forest'),
    (ID: 90;  R: 40; G:100; B:  0; Name: 'Open needleleaved forest'),
    (ID:100;  R:120; G:130; B:  0; Name: 'Mixed forest'),
    (ID:110;  R:140; G:160; B:  0; Name: 'Forest/shrubland/grassland mosaic'),
    (ID:120;  R:190; G:150; B:  0; Name: 'Grassland/forest mosaic'),
    (ID:130;  R:150; G:100; B:  0; Name: 'Shrubland'),
    (ID:140;  R:255; G:180; B: 50; Name: 'Herbaceous/grassland/savanna'),
    (ID:150;  R:255; G:235; B:175; Name: 'Sparse vegetation'),
    (ID:160;  R:  0; G:120; B: 90; Name: 'Flooded broadleaved forest'),
    (ID:170;  R:  0; G:150; B:120; Name: 'Flooded forest/shrubland (saline)'),
    (ID:180;  R:  0; G:220; B:130; Name: 'Flooded grassland/wetland'),
    (ID:190;  R:195; G: 20; B:  0; Name: 'Urban/artificial surfaces'),
    (ID:200;  R:255; G:245; B:215; Name: 'Bare areas'),
    (ID:210;  R:  0; G: 70; B:200; Name: 'Water bodies'),
    (ID:220;  R:255; G:255; B:255; Name: 'Permanent snow/ice'),
    (ID:230;  R:  0; G:  0; B:  0; Name: 'No data')
  );

function ClassColor(AID: Byte): TFPColor;
var
  i: Integer;
begin
  for i := 0 to High(GlobCoverClasses) do
    if GlobCoverClasses[i].ID = AID then
    begin
      Result.Red   := GlobCoverClasses[i].R shl 8;
      Result.Green := GlobCoverClasses[i].G shl 8;
      Result.Blue  := GlobCoverClasses[i].B shl 8;
      Result.Alpha := $FFFF;
      Exit;
    end;
  Result.Red := $FFFF; Result.Green := 0; Result.Blue := $FFFF; Result.Alpha := $FFFF;
end;

var
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
        Img.Colors[px, py] := ClassColor(ClassID);
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

