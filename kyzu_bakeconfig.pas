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
    Value: Double;
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
    OutDirMovecost: string;
    MovementGridPath: string;
    Shading: TShadingParams;
    Classes: TGlobCoverPalette;
    Hypsometric: THypsometricRamp;
    MovementCostRamp: THypsometricRamp;
    ImpassableColor: array[0..2] of Byte;
  end;

function LoadBakeConfig(const AFilename: string): TBakeConfig;
function PaletteClassRGB(const AConfig: TBakeConfig; AID: Byte; out R, G, B: Byte): Boolean;
function PaletteClassMoveCost(const AConfig: TBakeConfig; AID: Byte): Double;

// Generic piecewise-linear interpolation over any color ramp - shared by
// the elevation hypsometric tint and the movement-cost choropleth below,
// rather than duplicating the interpolation logic for each.
procedure RampColorRGB(const ARamp: THypsometricRamp; AValue: Double; out R, G, B: Byte);
procedure HypsometricColorRGB(const AConfig: TBakeConfig; AElev: Double; out R, G, B: Byte);
procedure MovementCostColorRGB(const AConfig: TBakeConfig; AMoveCost: Double; out R, G, B: Byte);

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
      Result.OutDirMovecost := JOutDirs.Get('movecost', 'tiles_movecost');

      Result.ImpassableColor[0] := JRoot.Get('impassable_color_r', 40);
      Result.ImpassableColor[1] := JRoot.Get('impassable_color_g', 40);
      Result.ImpassableColor[2] := JRoot.Get('impassable_color_b', 40);

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
        Result.Hypsometric[i].Value := JItem.Get('elevation', 0.0);
        Result.Hypsometric[i].R := JItem.Get('r', 0);
        Result.Hypsometric[i].G := JItem.Get('g', 0);
        Result.Hypsometric[i].B := JItem.Get('b', 0);
      end;

      JArr := TJSONArray(JRoot.Find('movement_cost_ramp'));
      if Assigned(JArr) then
      begin
        SetLength(Result.MovementCostRamp, JArr.Count);
        for i := 0 to JArr.Count - 1 do
        begin
          JItem := TJSONObject(JArr[i]);
          Result.MovementCostRamp[i].Value := JItem.Get('value', 0.0);
          Result.MovementCostRamp[i].R := JItem.Get('r', 0);
          Result.MovementCostRamp[i].G := JItem.Get('g', 0);
          Result.MovementCostRamp[i].B := JItem.Get('b', 0);
        end;
      end
      else
        SetLength(Result.MovementCostRamp, 0); // not baking the movecost layer - fine, optional
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

procedure RampColorRGB(const ARamp: THypsometricRamp; AValue: Double; out R, G, B: Byte);
var
  i: Integer;
  t, rf, gf, bf: Double;
begin
  if Length(ARamp) = 0 then
  begin
    R := 128; G := 128; B := 128;
    Exit;
  end;

  if AValue <= ARamp[0].Value then
  begin
    rf := ARamp[0].R; gf := ARamp[0].G; bf := ARamp[0].B;
  end
  else if AValue >= ARamp[High(ARamp)].Value then
  begin
    rf := ARamp[High(ARamp)].R; gf := ARamp[High(ARamp)].G; bf := ARamp[High(ARamp)].B;
  end
  else
  begin
    i := 0;
    while (i < High(ARamp)) and (ARamp[i + 1].Value < AValue) do
      Inc(i);
    t := (AValue - ARamp[i].Value) / (ARamp[i + 1].Value - ARamp[i].Value);
    rf := ARamp[i].R + t * (ARamp[i + 1].R - ARamp[i].R);
    gf := ARamp[i].G + t * (ARamp[i + 1].G - ARamp[i].G);
    bf := ARamp[i].B + t * (ARamp[i + 1].B - ARamp[i].B);
  end;

  R := Round(EnsureRange(rf, 0, 255));
  G := Round(EnsureRange(gf, 0, 255));
  B := Round(EnsureRange(bf, 0, 255));
end;

procedure HypsometricColorRGB(const AConfig: TBakeConfig; AElev: Double; out R, G, B: Byte);
begin
  RampColorRGB(AConfig.Hypsometric, AElev, R, G, B);
end;

// Caller is responsible for checking AMoveCost <= 0 (impassable) first and
// using AConfig.ImpassableColor instead - this function only makes sense
// for genuinely passable values, since "impassable" isn't a point on a
// continuous cost gradient, it's a categorically different case.
procedure MovementCostColorRGB(const AConfig: TBakeConfig; AMoveCost: Double; out R, G, B: Byte);
begin
  RampColorRGB(AConfig.MovementCostRamp, AMoveCost, R, G, B);
end;

end.
