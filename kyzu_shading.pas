unit kyzu_shading;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, kyzu_geotiff, kyzu_bakeconfig;

function SampleElevationAt(AReader: TGeoTIFFReader; Lon, Lat: Double): Single;

// Slope estimated via finite differences, scaled to StepLon/StepLat (should
// match the CURRENT tile's per-pixel angular size, so shading detail
// coarsens naturally when zoomed out rather than always probing
// fixed-size source-pixel gaps). Applies identically above and below sea
// level, which is what makes undersea trenches show up the same way
// mountain ridges do - no special-casing needed for bathymetry.
function ComputeShade(AReader: TGeoTIFFReader; const AShading: TShadingParams;
  Lon, Lat, StepLon, StepLat: Double): Double;

function ShadeMultiplier(const AShading: TShadingParams; AShade: Double): Double;
function ApplyShadeToByte(AValue: Byte; AMult: Double): Byte;

implementation

function SampleElevationAt(AReader: TGeoTIFFReader; Lon, Lat: Double): Single;
var
  SrcX, SrcY: Integer;
begin
  SrcX := Round((Lon - (-180.0)) / 360.0 * AReader.Width);
  SrcY := Round((90.0 - Lat) / 180.0 * AReader.Height);
  if SrcX < 0 then SrcX := 0;
  if SrcX >= AReader.Width then SrcX := AReader.Width - 1;
  if SrcY < 0 then SrcY := 0;
  if SrcY >= AReader.Height then SrcY := AReader.Height - 1;
  Result := AReader.GetFloatSample(SrcX, SrcY);
end;

function ComputeShade(AReader: TGeoTIFFReader; const AShading: TShadingParams;
  Lon, Lat, StepLon, StepLat: Double): Double;
var
  hL, hR, hD, hU: Single;
  dzdx, dzdy: Double;
  nx, ny, nz, len: Double;
  lx, ly, lz: Double;
  cosLat: Double;
begin
  hL := SampleElevationAt(AReader, Lon - StepLon, Lat);
  hR := SampleElevationAt(AReader, Lon + StepLon, Lat);
  hD := SampleElevationAt(AReader, Lon, Lat - StepLat);
  hU := SampleElevationAt(AReader, Lon, Lat + StepLat);

  cosLat := Cos(Lat * Pi / 180.0);
  if Abs(cosLat) < 0.01 then cosLat := 0.01; // avoid blowup right at the poles

  dzdx := (hR - hL) / (2 * StepLon * AShading.MetresPerDegreeLonEquator * cosLat);
  dzdy := (hU - hD) / (2 * StepLat * AShading.MetresPerDegreeLat);

  nx := -dzdx; ny := -dzdy; nz := 1.0;
  len := Sqrt(nx * nx + ny * ny + nz * nz);
  nx := nx / len; ny := ny / len; nz := nz / len;

  lx := AShading.LightX; ly := AShading.LightY; lz := AShading.LightZ;
  len := Sqrt(lx * lx + ly * ly + lz * lz);
  lx := lx / len; ly := ly / len; lz := lz / len;

  Result := nx * lx + ny * ly + nz * lz;
end;

function ShadeMultiplier(const AShading: TShadingParams; AShade: Double): Double;
begin
  Result := EnsureRange(AShading.GainBase + AShading.GainScale * AShade,
    AShading.ClampMin, AShading.ClampMax);
end;

function ApplyShadeToByte(AValue: Byte; AMult: Double): Byte;
begin
  Result := Round(EnsureRange(AValue * AMult, 0, 255));
end;

end.
