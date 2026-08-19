unit kyzu_baketiles;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DateUtils, FPImage, FPWritePNG;

type
  TBakeTileProc = procedure(ALevel, ATileX, ATileY: Integer);

procedure TileBounds(ALevel, ATileX, ATileY: Integer;
  out ALonMin, ALonMax, ALatMin, ALatMax: Double);
procedure SaveTilePNG(AImg: TFPMemoryImage; const AOutDir: string;
  ALevel, ATileX, ATileY: Integer);
procedure RunTilePyramidBake(AMaxLevel: Integer; ABakeTileProc: TBakeTileProc);

implementation

// Standard equirectangular quadtree convention: level L = 2^(L+1) x 2^L
// tiles, doubling each level, matching WMTS/NASA WorldWind non-Mercator
// pyramids. Every bake tool uses this identical layout, which is what
// lets all three tile pyramids line up exactly for viewer blending.
procedure TileBounds(ALevel, ATileX, ATileY: Integer;
  out ALonMin, ALonMax, ALatMin, ALatMax: Double);
var
  TilesAcross, TilesDown: Integer;
begin
  TilesAcross := 1 shl (ALevel + 1);
  TilesDown := 1 shl ALevel;
  ALonMin := -180.0 + ATileX * (360.0 / TilesAcross);
  ALonMax := ALonMin + (360.0 / TilesAcross);
  ALatMax := 90.0 - ATileY * (180.0 / TilesDown);
  ALatMin := ALatMax - (180.0 / TilesDown);
end;

procedure SaveTilePNG(AImg: TFPMemoryImage; const AOutDir: string;
  ALevel, ATileX, ATileY: Integer);
var
  Dir, FileName: string;
  Writer: TFPWriterPNG;
begin
  Dir := Format('%s/%d/%d', [AOutDir, ALevel, ATileX]);
  ForceDirectories(Dir);
  FileName := Format('%s/%d.png', [Dir, ATileY]);
  Writer := TFPWriterPNG.Create;
  try
    AImg.SaveToFile(FileName, Writer);
  finally
    Writer.Free;
  end;
end;

// ty outer, tx inner: all tiles in one ty row share the same latitude
// band, so per-tool source readers tend to reuse the same cached source
// strip(s) - matches the row-major cache-friendly pattern established
// back in kyzu_bake_terrain.
procedure RunTilePyramidBake(AMaxLevel: Integer; ABakeTileProc: TBakeTileProc);
var
  Level, tx, ty, TilesAcross, TilesDown: Integer;
  TotalTiles, DoneTiles: Int64;
  StartTime, LevelStartTime: TDateTime;
begin
  TotalTiles := 0;
  for Level := 0 to AMaxLevel do
    Inc(TotalTiles, Int64(1 shl (Level + 1)) * Int64(1 shl Level));
  WriteLn('Max level: ', AMaxLevel, '  Total tiles to bake: ', TotalTiles);

  StartTime := Now;
  DoneTiles := 0;
  for Level := 0 to AMaxLevel do
  begin
    TilesAcross := 1 shl (Level + 1);
    TilesDown := 1 shl Level;
    LevelStartTime := Now;
    WriteLn('Level ', Level, ': ', TilesAcross, ' x ', TilesDown, ' tiles');

    for ty := 0 to TilesDown - 1 do
      for tx := 0 to TilesAcross - 1 do
      begin
        ABakeTileProc(Level, tx, ty);
        Inc(DoneTiles);
      end;

    WriteLn('  level ', Level, ' done in ', MilliSecondsBetween(Now, LevelStartTime), ' ms  (',
      DoneTiles, '/', TotalTiles, ' total tiles so far)');
  end;
  WriteLn('All done. Total time: ', MilliSecondsBetween(Now, StartTime), ' ms');
end;

end.
