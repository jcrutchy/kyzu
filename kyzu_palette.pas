unit kyzu_palette;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, FPImage;

type
  TGlobCoverClass = record
    ID: Byte;
    R, G, B: Byte;
    Name: string;
  end;
  TGlobCoverPalette = array of TGlobCoverClass;

function LoadPalette(const AFilename: string): TGlobCoverPalette;
function PaletteClassRGB(const APalette: TGlobCoverPalette; AID: Byte; out R, G, B: Byte): Boolean;
function PaletteClassColor(const APalette: TGlobCoverPalette; AID: Byte): TFPColor;

implementation

// Expects: { "classes": [ { "id":11, "r":110, "g":170, "b":150, "name":"..." }, ... ] }
function LoadPalette(const AFilename: string): TGlobCoverPalette;
var
  FileContent: TStringList;
  JData: TJSONData;
  JArr: TJSONArray;
  JItem: TJSONObject;
  i: Integer;
begin
  SetLength(Result, 0);
  FileContent := TStringList.Create;
  try
    FileContent.LoadFromFile(AFilename);
    JData := GetJSON(FileContent.Text);
    try
      JArr := TJSONArray(TJSONObject(JData).Find('classes'));
      if not Assigned(JArr) then
        raise Exception.Create('palette file has no "classes" array');

      SetLength(Result, JArr.Count);
      for i := 0 to JArr.Count - 1 do
      begin
        JItem := TJSONObject(JArr[i]);
        Result[i].ID := JItem.Get('id', 0);
        Result[i].R := JItem.Get('r', 0);
        Result[i].G := JItem.Get('g', 0);
        Result[i].B := JItem.Get('b', 0);
        Result[i].Name := JItem.Get('name', '');
      end;
    finally
      JData.Free;
    end;
  finally
    FileContent.Free;
  end;
end;

function PaletteClassRGB(const APalette: TGlobCoverPalette; AID: Byte; out R, G, B: Byte): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(APalette) do
    if APalette[i].ID = AID then
    begin
      R := APalette[i].R; G := APalette[i].G; B := APalette[i].B;
      Exit(True);
    end;
  // Unrecognised ID - obvious magenta rather than silently wrong, same
  // convention as before.
  R := 255; G := 0; B := 255;
  Result := False;
end;

function PaletteClassColor(const APalette: TGlobCoverPalette; AID: Byte): TFPColor;
var
  R, G, B: Byte;
begin
  PaletteClassRGB(APalette, AID, R, G, B);
  Result.Red := R shl 8;
  Result.Green := G shl 8;
  Result.Blue := B shl 8;
  Result.Alpha := $FFFF;
end;

end.
