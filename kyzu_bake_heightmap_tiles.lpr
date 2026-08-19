program kyzu_bake_heightmap_tiles;
{$mode objfpc}{$H+}

uses
  SysUtils, FPImage, kyzu_geotiff, kyzu_bakeconfig, kyzu_shading, kyzu_baketiles;

var
  Config: TBakeConfig;
  Reader: TGeoTIFFReader;

procedure BakeTile(ALevel, ATileX, ATileY: Integer);
var
  LonMin, LonMax, LatMin, LatMax: Double;
  StepLon, StepLat: Double;
  Img: TFPMemoryImage;
  px, py: Integer;
  Lon, Lat: Double;
  Elev: Single;
  Shade, Mult: Double;
  R, G, B: Byte;
  Col: TFPColor;
begin
  TileBounds(ALevel, ATileX, ATileY, LonMin, LonMax, LatMin, LatMax);
  StepLon := (LonMax - LonMin) / Config.TileSize;
  StepLat := (LatMax - LatMin) / Config.TileSize;

  Img := TFPMemoryImage.Create(Config.TileSize, Config.TileSize);
  try
    for py := 0 to Config.TileSize - 1 do
      for px := 0 to Config.TileSize - 1 do
      begin
        Lon := LonMin + (px + 0.5) / Config.TileSize * (LonMax - LonMin);
        Lat := LatMax - (py + 0.5) / Config.TileSize * (LatMax - LatMin);

        Elev := SampleElevationAt(Reader, Lon, Lat);
        Shade := ComputeShade(Reader, Config.Shading, Lon, Lat, StepLon, StepLat);
        Mult := ShadeMultiplier(Config.Shading, Shade);

        HypsometricColorRGB(Config, Elev, R, G, B);
        Col.Red := ApplyShadeToByte(R, Mult) shl 8;
        Col.Green := ApplyShadeToByte(G, Mult) shl 8;
        Col.Blue := ApplyShadeToByte(B, Mult) shl 8;
        Col.Alpha := $FFFF;

        Img.Colors[px, py] := Col;
      end;
    SaveTilePNG(Img, Config.OutDirHeightmap, ALevel, ATileX, ATileY);
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
  WriteLn('  ', Length(Config.Hypsometric), ' hypsometric colour stops loaded.');

  WriteLn('Opening ', Config.ElevationPath, ' ...');
  Reader := TGeoTIFFReader.Create(Config.ElevationPath);
  try
    WriteLn('Source: ', Reader.Width, ' x ', Reader.Height);
    RunTilePyramidBake(MaxLevel, @BakeTile);
  finally
    Reader.Free;
  end;
end.
