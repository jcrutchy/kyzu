unit kyzu_bakeconfig;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, fpjson, jsonparser;

type
  TGlobCoverClass = record
    ID: Byte;
    R, G, B: Byte;
    MoveCost: Double; // <=0 = impassable to land units (water, no-data)
    Name: string;
  end;
  TGlobCoverPalette = array of TGlobCoverClass;

  TColorStop = record
    Elevation: Double;
    R, G, B: Byte;
  end;
  THypsometricRamp = array of TColorStop;

  TShadingParams = record
    LightX, LightY, LightZ: Double;
    GainBase, GainScale: Double;
    ClampMin, ClampMax: Double;
    MetresPerDegreeLat: Double;
    MetresPerDegreeLonEquator: Double;
  end;

  TBakeConfig = record
    GlobCoverPath: string;
    ElevationPath: string;
    TileSize: Integer;
    GlobCoverLatSouth: Double;
    OutDirLandcover: string;
    OutDirHeightmap: string;
    OutDirCombined: string;
    MovementGridPath: string;
    Shading: TShadingParams;
    Classes: TGlobCoverPalette;
    Hypsometric: THypsometricRamp;
  end;

function LoadBakeConfig(const AFilename: string): TBakeConfig;
function PaletteClassRGB(const AConfig: TBakeConfig; AID: Byte; out R, G, B: Byte): Boolean;
function PaletteClassMoveCost(const AConfig: TBakeConfig; AID: Byte): Double;
procedure HypsometricColorRGB(const AConfig: TBakeConfig; AElev: Double; out R, G, B: Byte);

implementation

function LoadBakeConfig(const AFilename: string): TBakeConfig;
var
  FileContent: TStringList;
  JData: TJSONData;
  JRoot, JPaths, JOutDirs, JShading, JItem: TJSONObject;
  JArr: TJSONArray;
  i: Integer;
begin
  FileContent := TStringList.Create;
  try
    FileContent.LoadFromFile(AFilename);
    JData := GetJSON(FileContent.Text);
    try
      JRoot := TJSONObject(JData);

      JPaths := TJSONObject(JRoot.Find('paths'));
      Result.GlobCoverPath := JPaths.Get('globcover_tif', 'GLOBCOVER_L4_200901_200912_V2.3.tif');
      Result.ElevationPath := JPaths.Get('elevation_tif', 'ETOPO_2022_v1_60s_N90W180_surface.tif');

      Result.TileSize := JRoot.Get('tile_size', 256);
      Result.GlobCoverLatSouth := JRoot.Get('globcover_lat_south', -65.0);
      Result.MovementGridPath := JRoot.Get('movement_grid_path', 'movement_grid.bin');

      JOutDirs := TJSONObject(JRoot.Find('output_dirs'));
      Result.OutDirLandcover := JOutDirs.Get('landcover', 'tiles');
      Result.OutDirHeightmap := JOutDirs.Get('heightmap', 'tiles_heightmap');
      Result.OutDirCombined := JOutDirs.Get('combined', 'tiles_combined');

      JShading := TJSONObject(JRoot.Find('shading'));
      Result.Shading.LightX := JShading.Get('light_x', -0.5);
      Result.Shading.LightY := JShading.Get('light_y', 0.5);
      Result.Shading.LightZ := JShading.Get('light_z', 0.7);
      Result.Shading.GainBase := JShading.Get('gain_base', 0.55);
      Result.Shading.GainScale := JShading.Get('gain_scale', 0.55);
      Result.Shading.ClampMin := JShading.Get('clamp_min', 0.35);
      Result.Shading.ClampMax := JShading.Get('clamp_max', 1.35);
      Result.Shading.MetresPerDegreeLat := JShading.Get('metres_per_degree_lat', 110540.0);
      Result.Shading.MetresPerDegreeLonEquator := JShading.Get('metres_per_degree_lon_equator', 111320.0);

      JArr := TJSONArray(JRoot.Find('classes'));
      if not Assigned(JArr) then
        raise Exception.Create('bake_config.json has no "classes" array');
      SetLength(Result.Classes, JArr.Count);
      for i := 0 to JArr.Count - 1 do
      begin
        JItem := TJSONObject(JArr[i]);
        Result.Classes[i].ID := JItem.Get('id', 0);
        Result.Classes[i].R := JItem.Get('r', 0);
        Result.Classes[i].G := JItem.Get('g', 0);
        Result.Classes[i].B := JItem.Get('b', 0);
        Result.Classes[i].MoveCost := JItem.Get('move_cost', 1.0);
        Result.Classes[i].Name := JItem.Get('name', '');
      end;

      JArr := TJSONArray(JRoot.Find('hypsometric'));
      if not Assigned(JArr) then
        raise Exception.Create('bake_config.json has no "hypsometric" array');
      SetLength(Result.Hypsometric, JArr.Count);
      for i := 0 to JArr.Count - 1 do
      begin
        JItem := TJSONObject(JArr[i]);
        Result.Hypsometric[i].Elevation := JItem.Get('elevation', 0.0);
        Result.Hypsometric[i].R := JItem.Get('r', 0);
        Result.Hypsometric[i].G := JItem.Get('g', 0);
        Result.Hypsometric[i].B := JItem.Get('b', 0);
      end;
    finally
      JData.Free;
    end;
  finally
    FileContent.Free;
  end;
end;

function PaletteClassRGB(const AConfig: TBakeConfig; AID: Byte; out R, G, B: Byte): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AConfig.Classes) do
    if AConfig.Classes[i].ID = AID then
    begin
      R := AConfig.Classes[i].R; G := AConfig.Classes[i].G; B := AConfig.Classes[i].B;
      Exit(True);
    end;
  R := 255; G := 0; B := 255; // unrecognised - obvious magenta rather than silently wrong
  Result := False;
end;

function PaletteClassMoveCost(const AConfig: TBakeConfig; AID: Byte): Double;
var
  i: Integer;
begin
  for i := 0 to High(AConfig.Classes) do
    if AConfig.Classes[i].ID = AID then
      Exit(AConfig.Classes[i].MoveCost);
  Result := -1; // unrecognised class - treat as impassable rather than silently walkable
end;

procedure HypsometricColorRGB(const AConfig: TBakeConfig; AElev: Double; out R, G, B: Byte);
var
  i: Integer;
  t, rf, gf, bf: Double;
  Stops: THypsometricRamp;
begin
  Stops := AConfig.Hypsometric;
  if Length(Stops) = 0 then
  begin
    R := 128; G := 128; B := 128;
    Exit;
  end;

  if AElev <= Stops[0].Elevation then
  begin
    rf := Stops[0].R; gf := Stops[0].G; bf := Stops[0].B;
  end
  else if AElev >= Stops[High(Stops)].Elevation then
  begin
    rf := Stops[High(Stops)].R; gf := Stops[High(Stops)].G; bf := Stops[High(Stops)].B;
  end
  else
  begin
    i := 0;
    while (i < High(Stops)) and (Stops[i + 1].Elevation < AElev) do
      Inc(i);
    t := (AElev - Stops[i].Elevation) / (Stops[i + 1].Elevation - Stops[i].Elevation);
    rf := Stops[i].R + t * (Stops[i + 1].R - Stops[i].R);
    gf := Stops[i].G + t * (Stops[i + 1].G - Stops[i].G);
    bf := Stops[i].B + t * (Stops[i + 1].B - Stops[i].B);
  end;

  R := Round(EnsureRange(rf, 0, 255));
  G := Round(EnsureRange(gf, 0, 255));
  B := Round(EnsureRange(bf, 0, 255));
end;

end.
