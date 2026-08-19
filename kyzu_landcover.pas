unit kyzu_landcover;

{$mode objfpc}{$H+}

interface

uses
  kyzu_geotiff, kyzu_bakeconfig, kyzu_shading;

// Returns the GlobCover class ID for a lon/lat - sampled directly where
// GlobCover has coverage, or derived from ETOPO's land/ocean sign south
// of AConfig.GlobCoverLatSouth (land becomes ice - the Antarctic ice
// sheet, ocean stays water - the Southern Ocean). See the
// kyzu_bake_combined_tiles design notes for why this is better than a
// blanket "everything south of 65S is ice" fallback.
function SampleLandCoverClass(ALandCoverReader, AElevationReader: TGeoTIFFReader;
  const AConfig: TBakeConfig; Lon, Lat: Double): Byte;

implementation

function SampleLandCoverClass(ALandCoverReader, AElevationReader: TGeoTIFFReader;
  const AConfig: TBakeConfig; Lon, Lat: Double): Byte;
var
  SrcX, SrcY: Integer;
begin
  if Lat < AConfig.GlobCoverLatSouth then
  begin
    if SampleElevationAt(AElevationReader, Lon, Lat) > 0 then
      Result := 220  // land, per ETOPO - Antarctic ice sheet
    else
      Result := 210; // ocean, per ETOPO - Southern Ocean, not ice
    Exit;
  end;

  SrcX := Round((Lon - (-180.0)) / 360.0 * ALandCoverReader.Width);
  SrcY := Round((90.0 - Lat) / (90.0 - AConfig.GlobCoverLatSouth) * ALandCoverReader.Height);
  if SrcX < 0 then SrcX := 0;
  if SrcX >= ALandCoverReader.Width then SrcX := ALandCoverReader.Width - 1;
  if SrcY < 0 then SrcY := 0;
  if SrcY >= ALandCoverReader.Height then SrcY := ALandCoverReader.Height - 1;
  Result := ALandCoverReader.GetByteSample(SrcX, SrcY);
end;

end.
