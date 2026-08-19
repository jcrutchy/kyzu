program kyzu_bake_tiles;
{$mode objfpc}{$H+}

uses
  SysUtils, FPImage, kyzu_geotiff, kyzu_bakeconfig, kyzu_baketiles;

var
  Config: TBakeConfig;
  Reader: TGeoTIFFReader;

// South of GlobCover's own coverage this falls back to a blanket ice
// class, since this tool doesn't open the elevation file at all - it's
// meant to run standalone without needing ETOPO. See
// kyzu_bake_combined_tiles for the ETOPO-informed version that traces
// Antarctica's actual coastline instead.
function SampleClassAt(Lon, Lat: Double): Byte;
var
  SrcX, SrcY: Integer;
begin
  if Lat < Config.GlobCoverLatSouth then
  begin
    Result := 220;
    Exit;
  end;
  SrcX := Round((Lon - (-180.0)) / 360.0 * Reader.Width);
  SrcY := Round((90.0 - Lat) / (90.0 - Config.GlobCoverLatSouth) * Reader.Height);
  if SrcX < 0 then SrcX := 0;
  if SrcX >= Reader.Width then SrcX := Reader.Width - 1;
  if SrcY < 0 then SrcY := 0;
  if SrcY >= Reader.Height then SrcY := Reader.Height - 1;
  Result := Reader.GetByteSample(SrcX, SrcY);
end;

procedure BakeTile(ALevel, ATileX, ATileY: Integer);
var
  LonMin, LonMax, LatMin, LatMax: Double;
  Img: TFPMemoryImage;
  px, py: Integer;
  Lon, Lat: Double;
  ClassID: Byte;
  R, G, B: Byte;
  Col: TFPColor;
begin
  TileBounds(ALevel, ATileX, ATileY, LonMin, LonMax, LatMin, LatMax);

  Img := TFPMemoryImage.Create(Config.TileSize, Config.TileSize);
  try
    for py := 0 to Config.TileSize - 1 do
      for px := 0 to Config.TileSize - 1 do
      begin
        Lon := LonMin + (px + 0.5) / Config.TileSize * (LonMax - LonMin);
        Lat := LatMax - (py + 0.5) / Config.TileSize * (LatMax - LatMin);

        ClassID := SampleClassAt(Lon, Lat);
        PaletteClassRGB(Config, ClassID, R, G, B);

        Col.Red := R shl 8; Col.Green := G shl 8; Col.Blue := B shl 8; Col.Alpha := $FFFF;
        Img.Colors[px, py] := Col;
      end;
    SaveTilePNG(Img, Config.OutDirLandcover, ALevel, ATileX, ATileY);
  finally
    Img.Free;
  end;
end;

var
  MaxLevel: Integer;
begin
  MaxLevel := 6;
  if ParamCount >= 1 then
    MaxLevel := StrToIntDef(ParamStr(1), 6);

  WriteLn('Loading bake_config.json ...');
  Config := LoadBakeConfig('bake_config.json');
  WriteLn('  ', Length(Config.Classes), ' land-cover classes loaded.');

  WriteLn('Opening ', Config.GlobCoverPath, ' ...');
  Reader := TGeoTIFFReader.Create(Config.GlobCoverPath);
  try
    WriteLn('Source: ', Reader.Width, ' x ', Reader.Height);
    RunTilePyramidBake(MaxLevel, @BakeTile);
  finally
    Reader.Free;
  end;
end.
