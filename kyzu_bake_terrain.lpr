program kyzu_bake_terrain;
{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, Math, FPImage, FPWritePNG, kyzu_geotiff;

var
  GridW, GridH: Integer; // set from ParamStr(1) below - was fixed at 360x180

const
  // GlobCover's actual coverage per its readme: full longitude (-180..180)
  // but only 90N down to 65S in latitude - Antarctica isn't included.
  // Anything south of 65S gets treated as permanent ice (class 220) below,
  // since that's a reasonable stand-in for what GlobCover simply doesn't map.
  SourceLatNorth = 90.0;
  SourceLatSouth = -65.0;

  SourceTIFFPath = 'C:\dev\kyzu_data\Globcover2009_V2.3_Global_\GLOBCOVER_L4_200901_200912_V2.3.tif';

type
  TGlobCoverClass = record
    ID: Byte;
    R, G, B: Byte;
    Name: string;
  end;

const
  GlobCoverClasses: array[0..22] of TGlobCoverClass = (
    (ID: 11;  R:170; G:240; B:240; Name: 'Irrigated cropland (or aquatic)'),
    (ID: 14;  R:255; G:255; B:100; Name: 'Rainfed cropland'),
    (ID: 20;  R:220; G:240; B:100; Name: 'Cropland/vegetation mosaic'),
    (ID: 30;  R:205; G:205; B:102; Name: 'Vegetation/cropland mosaic'),
    (ID: 40;  R:  0; G:100; B:  0; Name: 'Broadleaved evergreen forest'),
    (ID: 50;  R:  0; G:160; B:  0; Name: 'Broadleaved deciduous forest'),
    (ID: 60;  R:170; G:200; B:  0; Name: 'Open deciduous forest/woodland'),
    (ID: 70;  R:  0; G: 60; B:  0; Name: 'Needleleaved evergreen forest'),
    (ID: 90;  R: 40; G:100; B:  0; Name: 'Open needleleaved forest'),
    (ID:100;  R:120; G:130; B:  0; Name: 'Mixed forest'),
    (ID:110;  R:140; G:160; B:  0; Name: 'Forest/shrubland/grassland mosaic'),
    (ID:120;  R:190; G:150; B:  0; Name: 'Grassland/forest mosaic'),
    (ID:130;  R:150; G:100; B:  0; Name: 'Shrubland'),
    (ID:140;  R:255; G:180; B: 50; Name: 'Herbaceous/grassland/savanna'),
    (ID:150;  R:255; G:235; B:175; Name: 'Sparse vegetation'),
    (ID:160;  R:  0; G:120; B: 90; Name: 'Flooded broadleaved forest'),
    (ID:170;  R:  0; G:150; B:120; Name: 'Flooded forest/shrubland (saline)'),
    (ID:180;  R:  0; G:220; B:130; Name: 'Flooded grassland/wetland'),
    (ID:190;  R:195; G: 20; B:  0; Name: 'Urban/artificial surfaces'),
    (ID:200;  R:255; G:245; B:215; Name: 'Bare areas'),
    (ID:210;  R:  0; G: 70; B:200; Name: 'Water bodies'),
    (ID:220;  R:255; G:255; B:255; Name: 'Permanent snow/ice'),
    (ID:230;  R:  0; G:  0; B:  0; Name: 'No data')
  );

function ClassKnown(AID: Byte): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(GlobCoverClasses) do
    if GlobCoverClasses[i].ID = AID then
      Exit(True);
end;

function ClassColor(AID: Byte): TFPColor;
var
  i: Integer;
begin
  for i := 0 to High(GlobCoverClasses) do
    if GlobCoverClasses[i].ID = AID then
    begin
      Result.Red   := GlobCoverClasses[i].R shl 8;
      Result.Green := GlobCoverClasses[i].G shl 8;
      Result.Blue  := GlobCoverClasses[i].B shl 8;
      Result.Alpha := $FFFF;
      Exit;
    end;
  // Unrecognised ID - magenta so it's obvious in the output rather than
  // silently blending in as black, if the real file has a class value
  // this table doesn't account for.
  Result.Red := $FFFF; Result.Green := 0; Result.Blue := $FFFF; Result.Alpha := $FFFF;
end;

var
  Img: TFPMemoryImage;
  Writer: TFPWriterPNG;
  Reader: TGeoTIFFReader;
  x, y: Integer;
  Lon, Lat: Double;
  SrcX, SrcY: Integer;
  ClassID: Byte;
  UnknownCount: Integer;
  StartTime, OpenedTime, EndTime: TDateTime;
begin
  UnknownCount := 0;
  GridW := 5760;
  if ParamCount >= 1 then
    GridW := StrToIntDef(ParamStr(1), GridW);
  GridH := GridW div 2; // output always covers the full globe 2:1, regardless
                         // of GridW - only the source data's own coverage is
                         // partial (see SourceLatSouth handling below)

  StartTime := Now;
  WriteLn('Grid: ', GridW, ' x ', GridH);
  WriteLn('Opening ', SourceTIFFPath, ' ...');
  Reader := TGeoTIFFReader.Create(SourceTIFFPath);
  try
    OpenedTime := Now;
    WriteLn('Source: ', Reader.Width, ' x ', Reader.Height, '  (open took ',
      MilliSecondsBetween(OpenedTime, StartTime), ' ms)');

    Img := TFPMemoryImage.Create(GridW, GridH);
    try
      for y := 0 to GridH - 1 do
      begin
        for x := 0 to GridW - 1 do
        begin
          // Cell centre in lon/lat.
          Lon := -180.0 + (x + 0.5) * (360.0 / GridW);
          Lat := 90.0 - (y + 0.5) * (180.0 / GridH);

          if Lat < SourceLatSouth then
            ClassID := 220 // south of GlobCover's coverage - treat as ice
          else
          begin
            // Nearest-neighbour into source pixel space. GlobCover is
            // already Plate Carree/equirectangular, same as this grid,
            // so this is a direct linear mapping - no reprojection needed.
            SrcX := Round((Lon - (-180.0)) / 360.0 * Reader.Width);
            SrcY := Round((SourceLatNorth - Lat) / (SourceLatNorth - SourceLatSouth) * Reader.Height);
            if SrcX < 0 then SrcX := 0;
            if SrcX >= Reader.Width then SrcX := Reader.Width - 1;
            if SrcY < 0 then SrcY := 0;
            if SrcY >= Reader.Height then SrcY := Reader.Height - 1;

            ClassID := Reader.GetByteSample(SrcX, SrcY);

            if (not ClassKnown(ClassID)) and (UnknownCount < 20) then
            begin
              Inc(UnknownCount);
              WriteLn('  UNKNOWN class ', ClassID, ' at grid(', x, ',', y,
                ') lon=', Lon:0:2, ' lat=', Lat:0:2, ' src(', SrcX, ',', SrcY, ')');
            end;
          end;

          Img.Colors[x, y] := ClassColor(ClassID);
        end;
        if (y mod Max(1, GridH div 20)) = 0 then
          WriteLn('  row ', y, '/', GridH, '  (', MilliSecondsBetween(Now, OpenedTime), ' ms elapsed)');
      end;

      Writer := TFPWriterPNG.Create;
      try
        Img.SaveToFile('terrain.png', Writer);
      finally
        Writer.Free;
      end;
    finally
      Img.Free;
    end;
  finally
    Reader.Free;
  end;
  EndTime := Now;
  WriteLn('Wrote terrain.png (', GridW, 'x', GridH, ' from real GlobCover data)');
  WriteLn('Total time: ', MilliSecondsBetween(EndTime, StartTime), ' ms',
    '  (bake loop: ', MilliSecondsBetween(EndTime, OpenedTime), ' ms)');
end.
