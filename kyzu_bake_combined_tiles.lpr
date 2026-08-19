program kyzu_bake_combined_tiles;
{$mode objfpc}{$H+}

uses
  SysUtils, FPImage, kyzu_geotiff, kyzu_bakeconfig, kyzu_shading, kyzu_landcover, kyzu_baketiles;

var
  Config: TBakeConfig;
  LandCoverReader, ElevationReader: TGeoTIFFReader;

procedure BakeTile(ALevel, ATileX, ATileY: Integer);
var
  LonMin, LonMax, LatMin, LatMax: Double;
  StepLon, StepLat: Double;
  Img: TFPMemoryImage;
  px, py: Integer;
  Lon, Lat: Double;
  ClassID: Byte;
  R, G, B: Byte;
  Shade, Mult: Double;
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

        ClassID := SampleLandCoverClass(LandCoverReader, ElevationReader, Config, Lon, Lat);
        PaletteClassRGB(Config, ClassID, R, G, B);
        Shade := ComputeShade(ElevationReader, Config.Shading, Lon, Lat, StepLon, StepLat);
        Mult := ShadeMultiplier(Config.Shading, Shade);

        Col.Red := ApplyShadeToByte(R, Mult) shl 8;
        Col.Green := ApplyShadeToByte(G, Mult) shl 8;
        Col.Blue := ApplyShadeToByte(B, Mult) shl 8;
        Col.Alpha := $FFFF;

        Img.Colors[px, py] := Col;
      end;
    SaveTilePNG(Img, Config.OutDirCombined, ALevel, ATileX, ATileY);
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

  WriteLn('Opening ', Config.GlobCoverPath, ' ...');
  LandCoverReader := TGeoTIFFReader.Create(Config.GlobCoverPath);
  WriteLn('Opening ', Config.ElevationPath, ' ...');
  ElevationReader := TGeoTIFFReader.Create(Config.ElevationPath);
  try
    WriteLn('Land cover source: ', LandCoverReader.Width, ' x ', LandCoverReader.Height);
    WriteLn('Elevation source: ', ElevationReader.Width, ' x ', ElevationReader.Height);
    RunTilePyramidBake(MaxLevel, @BakeTile);
  finally
    LandCoverReader.Free;
    ElevationReader.Free;
  end;
end.
