program kyzu_bake_terrain;
{$mode objfpc}{$H+}

uses
  SysUtils, FPImage, FPWritePNG;

const
  GridW = 360;
  GridH = 180;

type
  TGlobCoverClass = record
    ID: Byte;
    R, G, B: Byte;
    Name: string;
  end;

const
  // Subset for the stub pattern - full 23-class table goes here once the
  // real GeoTIFF reader is wired in.
  GlobCoverClasses: array[0..3] of TGlobCoverClass = (
    (ID: 210; R:  0; G: 70; B:200; Name: 'Water bodies'),
    (ID: 140; R:255; G:180; B: 50; Name: 'Herbaceous/grassland/savanna'),
    (ID:  40; R:  0; G:100; B:  0; Name: 'Broadleaved evergreen forest'),
    (ID: 200; R:255; G:245; B:215; Name: 'Bare areas')
  );

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
  Result := colBlack; // unknown class - shouldn't happen once real data is wired in
end;

var
  Img: TFPMemoryImage;
  Writer: TFPWriterPNG;
  x, y: Integer;
  StubClassID: Byte;
begin
  Img := TFPMemoryImage.Create(GridW, GridH);
  try
    for y := 0 to GridH - 1 do
      for x := 0 to GridW - 1 do
      begin
        // Placeholder checkerboard until the real GeoTIFF reader replaces
        // this loop with actual pixel classification - proves the
        // bake -> PNG -> served -> viewable pipeline first.
        case (x div 30 + y div 30) mod 4 of
          0: StubClassID := 210;
          1: StubClassID := 140;
          2: StubClassID := 40;
          else StubClassID := 200;
        end;
        Img.Colors[x, y] := ClassColor(StubClassID);
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
  WriteLn('Wrote terrain.png (', GridW, 'x', GridH, ' placeholder grid)');
end.
