program kyzu_bake_movement_grid;
{$mode objfpc}{$H+}

// Outputs a small self-describing binary file, not a PNG/tile pyramid:
//
//   Offset 0:  4 bytes  magic 'KYTR' ("Kyzu Terrain")
//   Offset 4:  4 bytes  width  (Int32 LE)
//   Offset 8:  4 bytes  height (Int32 LE)
//   Offset 12: width*height bytes, row-major, one GlobCover class ID per
//              cell (top-left = 90N/180W, matching every other bake
//              tool's convention in this project)
//
// Movement cost is NOT baked into this file - it stays a runtime lookup
// via kyzu_bakeconfig's PaletteClassMoveCost against the same
// bake_config.json, so tuning move_cost doesn't require re-baking the
// grid, just reloading the config.
//
// This is a single flat grid, not a tile pyramid - pathfinding needs one
// canonical resolution to operate on, not LOD. Resolution is configurable
// (ParamStr(1)) since it's genuinely still an open design question - see
// the "square grid, configurable resolution, hierarchical macro/tactical
// split for zoom-dependent movement" discussion this was born from.

uses
  SysUtils, Classes, Math, kyzu_geotiff, kyzu_bakeconfig, kyzu_landcover;

var
  Config: TBakeConfig;
  LandCoverReader, ElevationReader: TGeoTIFFReader;
  GridW, GridH: Integer;

procedure WriteGrid(const AFilename: string);
var
  Stream: TFileStream;
  Magic: array[0..3] of Byte;
  W32, H32: Int32;
  Row: array of Byte;
  x, y: Integer;
  Lon, Lat: Double;
begin
  Stream := TFileStream.Create(AFilename, fmCreate);
  try
    Magic[0] := Ord('K'); Magic[1] := Ord('Y'); Magic[2] := Ord('T'); Magic[3] := Ord('R');
    Stream.WriteBuffer(Magic, 4);
    W32 := GridW; H32 := GridH;
    Stream.WriteBuffer(W32, 4);
    Stream.WriteBuffer(H32, 4);

    SetLength(Row, GridW);
    for y := 0 to GridH - 1 do
    begin
      for x := 0 to GridW - 1 do
      begin
        Lon := -180.0 + (x + 0.5) * (360.0 / GridW);
        Lat := 90.0 - (y + 0.5) * (180.0 / GridH);
        Row[x] := SampleLandCoverClass(LandCoverReader, ElevationReader, Config, Lon, Lat);
      end;
      Stream.WriteBuffer(Row[0], GridW);
      if y mod Max(1, GridH div 20) = 0 then
        WriteLn('  row ', y, '/', GridH);
    end;
  finally
    Stream.Free;
  end;
end;

var
  i: Integer;
  Cost: Double;
begin
  GridW := 1300; // Civ5-ish default - override via ParamStr(1)
  if ParamCount >= 1 then
    GridW := StrToIntDef(ParamStr(1), 1300);
  GridH := GridW div 2;

  WriteLn('Grid: ', GridW, ' x ', GridH);
  WriteLn('Loading bake_config.json ...');
  Config := LoadBakeConfig('bake_config.json');

  WriteLn('Opening ', Config.GlobCoverPath, ' ...');
  LandCoverReader := TGeoTIFFReader.Create(Config.GlobCoverPath);
  WriteLn('Opening ', Config.ElevationPath, ' ...');
  ElevationReader := TGeoTIFFReader.Create(Config.ElevationPath);
  try
    WriteLn('Writing ', Config.MovementGridPath, ' ...');
    WriteGrid(Config.MovementGridPath);
  finally
    LandCoverReader.Free;
    ElevationReader.Free;
  end;

  WriteLn('Done. Move costs per class (from bake_config.json, for reference):');
  for i := 0 to High(Config.Classes) do
  begin
    Cost := PaletteClassMoveCost(Config, Config.Classes[i].ID);
    WriteLn('  ', Config.Classes[i].ID:4, '  cost=', Cost:0:2, '  ', Config.Classes[i].Name);
  end;
end.

