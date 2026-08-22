program kyzu_bake_movecost_tiles;
{$mode objfpc}{$H+}

// Colors terrain directly by movement cost (choropleth), not contour
// lines - contours are conventionally read as elevation relief by anyone
// who's seen a topographic map, and using that visual language for a
// non-elevation quantity (a swamp can be flat AND expensive to cross)
// would misleadingly suggest hills where there aren't any. A direct
// color gradient has no such ambiguity.

uses
  SysUtils, FPImage, kyzu_geotiff, kyzu_bakeconfig, kyzu_landcover, kyzu_baketiles;

var
  Config: TBakeConfig;
  LandCoverReader, ElevationReader: TGeoTIFFReader;

procedure BakeTile(ALevel, ATileX, ATileY: Integer);
var
  LonMin, LonMax, LatMin, LatMax: Double;
  Img: TFPMemoryImage;
  px, py: Integer;
  Lon, Lat: Double;
  ClassID: Byte;
  Cost: Double;
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

        ClassID := SampleLandCoverClass(LandCoverReader, ElevationReader, Config, Lon, Lat);
        Cost := PaletteClassMoveCost(Config, ClassID);

        if Cost <= 0 then
        begin
          // Impassable is a categorically different case, not a point on
          // the cost gradient - a fixed, visually distinct color rather
          // than an extrapolated ramp value.
          R := Config.ImpassableColor[0];
          G := Config.ImpassableColor[1];
          B := Config.ImpassableColor[2];
        end
        else
          MovementCostColorRGB(Config, Cost, R, G, B);

        Col.Red := R shl 8; Col.Green := G shl 8; Col.Blue := B shl 8; Col.Alpha := $FFFF;
        Img.Colors[px, py] := Col;
      end;
    SaveTilePNG(Img, Config.OutDirMovecost, ALevel, ATileX, ATileY);
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
  if Length(Config.MovementCostRamp) = 0 then
  begin
    WriteLn('bake_config.json has no "movement_cost_ramp" array - add one before running this tool.');
    Halt(1);
  end;
  WriteLn('  ', Length(Config.MovementCostRamp), ' cost ramp stops loaded.');

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

