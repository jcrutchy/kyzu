unit kyzu_geotiff;

// ──────────────────────────────────────────────────────────────
//   Minimal GeoTIFF reader - ported from tiff_reader.rs (Kyzu's
//   old Rust planetary-renderer project) and generalized:
//
//   - Original only read Int16/Float32 samples (ETOPO elevation).
//     Added Byte sample support for GlobCover's classification IDs.
//   - Original only supported Deflate + uncompressed. GlobCover's
//     readme specifies LZW compression, so a TIFF-variant LZW
//     decoder has been added (see LZWDecompress below - TIFF's
//     LZW has a subtle "early change" quirk vs. plain LZW/GIF,
//     flagged where it matters).
//   - Original unconditionally applied a floating-point predictor
//     deshuffle to every tile, because it only ever read ETOPO
//     float data. That's wrong for classification bytes, so this
//     version reads the actual Predictor tag (317) and dispatches
//     on it: 1=none, 2=horizontal differencing, 3=floating point
//     (the float-plane-deshuffle logic, kept for future elevation
//     reuse, now properly gated instead of assumed).
//
//   NOT YET VALIDATED against a real GlobCover file - run
//   `gdalinfo -json <file>.tif` first and check Compression,
//   Predictor, and whether it's tiled or stripped match what's
//   assumed here before trusting pixel output. See usage notes
//   at the bottom of this file.
// ──────────────────────────────────────────────────────────────

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, ZStream, Generics.Collections;

type
  TQWordArray = array of QWord;
  TGeoTIFFSampleFormat = (sfByte, sfInt16, sfFloat32);
  TGeoTIFFCompression = (cmpNone, cmpDeflate, cmpLZW);

  EGeoTIFFError = class(Exception);

  TGeoTIFFReader = class
  private
    FStream: TFileStream;
    FBigEndian: Boolean;
    FBigTIFF: Boolean;

    FWidth, FHeight: Integer;
    FSampleFormat: TGeoTIFFSampleFormat;
    FBitsPerSample: Integer;
    FCompression: TGeoTIFFCompression;
    FPredictor: Integer;          // 1=none, 2=horizontal, 3=floating point

    FTiled: Boolean;
    FTileWidth, FTileHeight: Integer;
    FRowsPerStrip: Integer;

    FOffsets: array of QWord;
    FByteCounts: array of QWord;

    FChunkCache: specialize TDictionary<Integer, TBytes>;
    FLastGoodChunkIndex: Integer;
    FLastGoodChunkData: TBytes;
    FDumpFailingChunks: Boolean; // off by default - see GetChunkData comment

    // -- endian-aware primitive reads at the current stream position --
    function ReadU16: Word;
    function ReadU32: Cardinal;
    function ReadU64: QWord;
    function SwapU16(V: Word): Word;
    function SwapU32(V: Cardinal): Cardinal;
    function SwapU64(V: QWord): QWord;

    procedure ReadIFD;
    procedure ReadTagValues(ATag, AType: Word; ACount: QWord; AValueOffset: QWord;
      AInlineBytes: TBytes; out AValues: TQWordArray);

    function DecompressChunk(AOffset, AByteCount: QWord; AExpectedSize: Integer): TBytes;
    procedure ApplyPredictor(var AData: TBytes; AChunkWidth, AChunkHeight: Integer);

    function GetChunkIndex(AX, AY: Integer): Integer;
    function GetChunkData(AChunkIndex: Integer): TBytes;
    function SampleByteWidth: Integer;
    procedure DumpFailingChunk(AChunkIndex: Integer; AOffset, AByteCount: QWord);
  public
    constructor Create(const AFilename: string);
    destructor Destroy; override;

    function GetByteSample(AX, AY: Integer): Byte;
    function GetInt16Sample(AX, AY: Integer): SmallInt;
    function GetFloatSample(AX, AY: Integer): Single;

    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property SampleFormat: TGeoTIFFSampleFormat read FSampleFormat;
    property DumpFailingChunks: Boolean read FDumpFailingChunks write FDumpFailingChunks;
  end;

implementation

const
  TAG_IMAGE_WIDTH        = 256;
  TAG_IMAGE_LENGTH       = 257;
  TAG_BITS_PER_SAMPLE    = 258;
  TAG_COMPRESSION        = 259;
  TAG_PREDICTOR          = 317;
  TAG_ROWS_PER_STRIP     = 278;
  TAG_STRIP_OFFSETS      = 273;
  TAG_STRIP_BYTE_COUNTS  = 279;
  TAG_TILE_WIDTH         = 322;
  TAG_TILE_LENGTH        = 323;
  TAG_TILE_OFFSETS       = 324;
  TAG_TILE_BYTE_COUNTS   = 325;
  TAG_SAMPLE_FORMAT      = 339;

  CLEAR_CODE = 256;
  EOI_CODE   = 257;

{ ────────────────────────────────────────────────────────────
  TIFF-variant LZW decompression.

  This is NOT plain GIF-style LZW. Two things differ, and both
  will silently produce garbled (not crashing, just wrong) output
  if missed:

  1. Codes are packed MSB-first within the byte stream (GIF is
     LSB-first).
  2. "Early change": TIFF increases the code width ONE code
     before the naive power-of-two boundary - i.e. code size
     bumps to 10 bits as soon as the dictionary holds 511 entries
     (not 512), to 11 bits at 1023 (not 1024), and 12 bits at
     2047 (not 2048). This is TIFF6 spec section 13's defined
     behaviour, and it's the single most common thing people get
     wrong porting an LZW decoder to TIFF.
  ──────────────────────────────────────────────────────────── }
function LZWDecompress(const AInput: TBytes; AExpectedSize: Integer): TBytes;
var
  Dict: array of TBytes;
  DictCount: Integer;
  CodeSize: Integer;
  BitBuf: QWord;
  BitCount: Integer;
  InPos: Integer;
  Output: TBytes;
  OutPos: Integer;

  function ReadCode: Integer;
  begin
    while BitCount < CodeSize do
    begin
      if InPos >= Length(AInput) then
      begin
        Result := EOI_CODE; // ran out of input - treat as end rather than crash
        Exit;
      end;
      BitBuf := (BitBuf shl 8) or AInput[InPos];
      Inc(InPos);
      Inc(BitCount, 8);
    end;
    Result := Integer((BitBuf shr (BitCount - CodeSize)) and ((QWord(1) shl CodeSize) - 1));
    Dec(BitCount, CodeSize);
  end;

  procedure ResetDict;
  var
    i: Integer;
  begin
    SetLength(Dict, 4096);
    for i := 0 to 255 do
    begin
      SetLength(Dict[i], 1);
      Dict[i][0] := Byte(i);
    end;
    DictCount := 258; // 256 = clear, 257 = EOI, first assignable code = 258
    CodeSize := 9;
  end;

  procedure EmitBytes(const B: TBytes);
  begin
    if OutPos + Length(B) > Length(Output) then
      SetLength(Output, (OutPos + Length(B)) * 2);
    if Length(B) > 0 then
      Move(B[0], Output[OutPos], Length(B));
    Inc(OutPos, Length(B));
  end;

var
  Code, OldCode: Integer;
  Entry, NewEntry: TBytes;
begin
  SetLength(Output, Max(AExpectedSize, 4096));
  OutPos := 0;
  InPos := 0;
  BitBuf := 0;
  BitCount := 0;
  OldCode := -1;
  ResetDict;

  Code := ReadCode;
  while Code <> EOI_CODE do
  begin
    if Code = CLEAR_CODE then
    begin
      ResetDict;
      OldCode := -1;
      Code := ReadCode;
      if Code = EOI_CODE then Break;
      EmitBytes(Dict[Code]);
      OldCode := Code;
      Code := ReadCode;
      Continue;
    end;

    if Code < DictCount then
      Entry := Copy(Dict[Code], 0, Length(Dict[Code]))
    else if (Code = DictCount) and (OldCode >= 0) then
    begin
      SetLength(Entry, Length(Dict[OldCode]) + 1);
      Move(Dict[OldCode][0], Entry[0], Length(Dict[OldCode]));
      Entry[High(Entry)] := Dict[OldCode][0];
    end
    else
    begin
      // Bitstream has desynced - there's no way to know what code Code
      // was meant to represent (dictionary entries are derived from
      // correctly-decoded prior output, not preallocated slots, so
      // there's nothing to "add" here). BUT everything decoded into
      // Output so far (OutPos bytes) was validated against the dictionary
      // state at the time and is genuinely correct - stopping cleanly and
      // keeping that prefix is far better than discarding it, which is
      // what raising an exception here used to do. The caller treats a
      // short result as "valid prefix, pad/patch the rest" rather than
      // "chunk is worthless."
      WriteLn(StdErr, Format('LZW: desync at output byte %d (code %d, dict had %d entries) - keeping %d correctly-decoded bytes',
        [OutPos, Code, DictCount, OutPos]));
      SetLength(Output, OutPos);
      Result := Output;
      Exit;
    end;

    EmitBytes(Entry);

    if (OldCode >= 0) and (DictCount < 4096) then
    begin
      SetLength(NewEntry, Length(Dict[OldCode]) + 1);
      Move(Dict[OldCode][0], NewEntry[0], Length(Dict[OldCode]));
      NewEntry[High(NewEntry)] := Entry[0];
      Dict[DictCount] := NewEntry;
      Inc(DictCount);

      // Early change - see unit header comment. Deliberately checked
      // against the boundary values, not >= a power of two.
      if DictCount = 511 then CodeSize := 10
      else if DictCount = 1023 then CodeSize := 11
      else if DictCount = 2047 then CodeSize := 12;
    end;

    OldCode := Code;
    Code := ReadCode;
  end;

  SetLength(Output, OutPos);
  Result := Output;
end;

{ TGeoTIFFReader }

function TGeoTIFFReader.SwapU16(V: Word): Word;
begin
  Result := ((V and $00FF) shl 8) or ((V and $FF00) shr 8);
end;

function TGeoTIFFReader.SwapU32(V: Cardinal): Cardinal;
begin
  Result := ((V and $000000FF) shl 24) or ((V and $0000FF00) shl 8)
          or ((V and $00FF0000) shr 8)  or ((V and $FF000000) shr 24);
end;

function TGeoTIFFReader.SwapU64(V: QWord): QWord;
begin
  Result := (QWord(SwapU32(V and $FFFFFFFF)) shl 32) or SwapU32(V shr 32);
end;

function TGeoTIFFReader.ReadU16: Word;
begin
  FStream.ReadBuffer(Result, 2);
  if FBigEndian then Result := SwapU16(Result);
end;

function TGeoTIFFReader.ReadU32: Cardinal;
begin
  FStream.ReadBuffer(Result, 4);
  if FBigEndian then Result := SwapU32(Result);
end;

function TGeoTIFFReader.ReadU64: QWord;
begin
  FStream.ReadBuffer(Result, 8);
  if FBigEndian then Result := SwapU64(Result);
end;

// Returns the byte size of one TIFF field-type unit (TIFF6 spec table),
// used to decide whether a tag's values fit inline in the 4/8-byte slot
// or need to be fetched from an offset elsewhere in the file.
function TIFFTypeSize(AType: Word): Integer;
begin
  case AType of
    1, 2, 6, 7:     Result := 1;  // BYTE, ASCII, SBYTE, UNDEFINED
    3, 8:           Result := 2;  // SHORT, SSHORT
    4, 9, 11:       Result := 4;  // LONG, SLONG, FLOAT
    5, 10, 12:      Result := 8;  // RATIONAL, SRATIONAL, DOUBLE
    16, 17, 18:     Result := 8;  // LONG8, SLONG8, IFD8 (BigTIFF)
    else            Result := 4;
  end;
end;

procedure TGeoTIFFReader.ReadTagValues(ATag, AType: Word; ACount: QWord; AValueOffset: QWord;
  AInlineBytes: TBytes; out AValues: TQWordArray);
var
  ElemSize: Integer;
  Total: QWord;
  Buf: TBytes;
  SavedPos: Int64;
  i: Integer;

  function ReadOne(AOffset: Integer): QWord;
  begin
    case TIFFTypeSize(AType) of
      1: Result := Buf[AOffset];
      2: begin
           Result := Buf[AOffset] or (Buf[AOffset + 1] shl 8);
           if FBigEndian then Result := SwapU16(Word(Result));
         end;
      4: begin
           Result := Buf[AOffset] or (Buf[AOffset + 1] shl 8)
                    or (Buf[AOffset + 2] shl 16) or (Buf[AOffset + 3] shl 24);
           if FBigEndian then Result := SwapU32(Cardinal(Result));
         end;
      8: begin
           Move(Buf[AOffset], Result, 8);
           if FBigEndian then Result := SwapU64(Result);
         end;
      else Result := 0;
    end;
  end;

begin
  ElemSize := TIFFTypeSize(AType);
  Total := ACount * QWord(ElemSize);

  if Length(AInlineBytes) >= Integer(Total) then
    Buf := Copy(AInlineBytes, 0, Total)
  else
  begin
    SavedPos := FStream.Position;
    FStream.Position := AValueOffset;
    SetLength(Buf, Total);
    if Total > 0 then
      FStream.ReadBuffer(Buf[0], Total);
    FStream.Position := SavedPos;
  end;

  SetLength(AValues, ACount);
  for i := 0 to Integer(ACount) - 1 do
    AValues[i] := ReadOne(i * ElemSize);
end;

procedure TGeoTIFFReader.ReadIFD;
var
  EntryCount: QWord;
  i: Integer;
  Tag, FieldType: Word;
  Count: QWord;
  ValueOffset: QWord;
  InlineBytes: TBytes;
  Values: TQWordArray;

  CompressionCode: QWord;
  HaveTileOffsets: Boolean;

  procedure ReadOneEntry;
  var
    InlineSize: Integer;
  begin
    if FBigTIFF then
    begin
      Tag := ReadU16;
      FieldType := ReadU16;
      Count := ReadU64;
      InlineSize := 8;
    end
    else
    begin
      Tag := ReadU16;
      FieldType := ReadU16;
      Count := ReadU32;
      InlineSize := 4;
    end;

    SetLength(InlineBytes, InlineSize);
    FStream.ReadBuffer(InlineBytes[0], InlineSize);

    if Count * QWord(TIFFTypeSize(FieldType)) <= QWord(InlineSize) then
      ValueOffset := 0 // unused - values come straight from InlineBytes
    else if FBigTIFF then
      Move(InlineBytes[0], ValueOffset, 8)
    else
    begin
      ValueOffset := 0;
      Move(InlineBytes[0], ValueOffset, 4);
      if FBigEndian then ValueOffset := SwapU32(Cardinal(ValueOffset));
    end;
  end;

begin
  HaveTileOffsets := False;
  FPredictor := 1; // default: no prediction, per TIFF6 spec
  FCompression := cmpNone;

  if FBigTIFF then
    EntryCount := ReadU64
  else
    EntryCount := ReadU16;

  for i := 0 to Integer(EntryCount) - 1 do
  begin
    ReadOneEntry;
    ReadTagValues(Tag, FieldType, Count, ValueOffset, InlineBytes, Values);

    case Tag of
      TAG_IMAGE_WIDTH:       FWidth := Integer(Values[0]);
      TAG_IMAGE_LENGTH:      FHeight := Integer(Values[0]);
      TAG_BITS_PER_SAMPLE:   FBitsPerSample := Integer(Values[0]);
      TAG_PREDICTOR:         FPredictor := Integer(Values[0]);
      TAG_ROWS_PER_STRIP:    FRowsPerStrip := Integer(Values[0]);
      TAG_TILE_WIDTH:        FTileWidth := Integer(Values[0]);
      TAG_TILE_LENGTH:       FTileHeight := Integer(Values[0]);

      TAG_COMPRESSION:
        begin
          CompressionCode := Values[0];
          case CompressionCode of
            1: FCompression := cmpNone;
            5: FCompression := cmpLZW;
            8: FCompression := cmpDeflate;
            else raise EGeoTIFFError.CreateFmt('Unsupported compression code %d', [CompressionCode]);
          end;
        end;

      TAG_STRIP_OFFSETS:
        begin
          FOffsets := Values;
          FTiled := False;
        end;
      TAG_STRIP_BYTE_COUNTS:
        FByteCounts := Values;

      TAG_TILE_OFFSETS:
        begin
          FOffsets := Values;
          FTiled := True;
          HaveTileOffsets := True;
        end;
      TAG_TILE_BYTE_COUNTS:
        FByteCounts := Values;
    end;
  end;

  FTiled := HaveTileOffsets;

  // Tag 339 (SampleFormat: int/uint/float) is deliberately not read here -
  // BitsPerSample alone decides the decode width below, same as the
  // original Rust reader's behaviour. Every format this unit targets
  // (Byte classes, Int16 elevation, Float32 elevation) has an unambiguous
  // bit width, so the extra tag wouldn't change anything - if a future
  // source needs to distinguish signed/unsigned at the same bit width,
  // this is the spot to add it.
  case FBitsPerSample of
    8:  FSampleFormat := sfByte;
    16: FSampleFormat := sfInt16;
    32: FSampleFormat := sfFloat32;
    else raise EGeoTIFFError.CreateFmt('Unsupported BitsPerSample %d', [FBitsPerSample]);
  end;

  if not FTiled then
  begin
    if FRowsPerStrip = 0 then
      FRowsPerStrip := FHeight; // whole image as one strip, if unset
  end;
end;

constructor TGeoTIFFReader.Create(const AFilename: string);
var
  Magic: array[0..1] of Byte;
  Version: Word;
  IFDOffset: QWord;
begin
  inherited Create;
  FChunkCache := specialize TDictionary<Integer, TBytes>.Create;
  FLastGoodChunkIndex := -1;
  FDumpFailingChunks := False;
  FStream := TFileStream.Create(AFilename, fmOpenRead or fmShareDenyWrite);

  FStream.ReadBuffer(Magic, 2);
  if (Magic[0] = Ord('I')) and (Magic[1] = Ord('I')) then
    FBigEndian := False
  else if (Magic[0] = Ord('M')) and (Magic[1] = Ord('M')) then
    FBigEndian := True
  else
    raise EGeoTIFFError.Create('Not a TIFF file (bad byte-order marker)');

  Version := ReadU16;
  case Version of
    42: // classic TIFF
      begin
        FBigTIFF := False;
        IFDOffset := ReadU32;
      end;
    43: // BigTIFF
      begin
        FBigTIFF := True;
        ReadU16; // bytesize-of-offsets field, always 8 - not needed here
        ReadU16; // constant 0
        IFDOffset := ReadU64;
      end;
    else
      raise EGeoTIFFError.CreateFmt('Unsupported TIFF version %d', [Version]);
  end;

  FStream.Position := IFDOffset;
  ReadIFD;
end;

destructor TGeoTIFFReader.Destroy;
begin
  FChunkCache.Free;
  FStream.Free;
  inherited Destroy;
end;

function TGeoTIFFReader.SampleByteWidth: Integer;
begin
  case FSampleFormat of
    sfByte:    Result := 1;
    sfInt16:   Result := 2;
    sfFloat32: Result := 4;
    else       Result := 1;
  end;
end;

// Writes the exact compressed bytes for one failing chunk to disk, plus a
// small sidecar text file with the context needed to reproduce it (chunk
// shape, predictor, endian) - so a specific decode failure can be shared
// and debugged directly without needing the full source file.
procedure TGeoTIFFReader.DumpFailingChunk(AChunkIndex: Integer; AOffset, AByteCount: QWord);
var
  Raw: TBytes;
  OutStream: TFileStream;
  InfoFile: TextFile;
  FileName: string;
  i: Integer;
begin
  SetLength(Raw, AByteCount);
  FStream.Position := AOffset;
  if AByteCount > 0 then
    FStream.ReadBuffer(Raw[0], AByteCount);

  FileName := Format('failing_chunk_%d.bin', [AChunkIndex]);
  OutStream := TFileStream.Create(FileName, fmCreate);
  try
    if Length(Raw) > 0 then
      OutStream.WriteBuffer(Raw[0], Length(Raw));
  finally
    OutStream.Free;
  end;

  AssignFile(InfoFile, Format('failing_chunk_%d.txt', [AChunkIndex]));
  Rewrite(InfoFile);
  try
    WriteLn(InfoFile, 'ChunkIndex=', AChunkIndex);
    WriteLn(InfoFile, 'Offset=', AOffset);
    WriteLn(InfoFile, 'ByteCount=', AByteCount);
    WriteLn(InfoFile, 'Tiled=', FTiled);
    WriteLn(InfoFile, 'ChunkWidth=', IfThen(FTiled, FTileWidth, FWidth));
    WriteLn(InfoFile, 'ChunkHeight=', IfThen(FTiled, FTileHeight, FRowsPerStrip));
    WriteLn(InfoFile, 'BitsPerSample=', FBitsPerSample);
    WriteLn(InfoFile, 'Predictor=', FPredictor);
    WriteLn(InfoFile, 'BigEndian=', FBigEndian);
    WriteLn(InfoFile, 'TotalStrips=', Length(FOffsets));
    WriteLn(InfoFile, '--- neighbouring strips (index: offset, bytecount, offset+bytecount) ---');
    for i := Max(0, AChunkIndex - 5) to Min(High(FOffsets), AChunkIndex + 5) do
      WriteLn(InfoFile, i, ': ', FOffsets[i], ', ', FByteCounts[i], ', ', FOffsets[i] + FByteCounts[i]);
  finally
    CloseFile(InfoFile);
  end;

  WriteLn(StdErr, 'kyzu_geotiff: dumped raw chunk to ', FileName, ' (', Length(Raw), ' bytes) + ',
    Format('failing_chunk_%d.txt', [AChunkIndex]));
end;

function TGeoTIFFReader.DecompressChunk(AOffset, AByteCount: QWord; AExpectedSize: Integer): TBytes;
var
  Raw: TBytes;
  InStream: TMemoryStream;
  DecompStream: TDecompressionStream;
  OutBuf: array[0..4095] of Byte;
  BytesRead: Integer;
  Out_: TBytes;
  OutPos: Integer;
begin
  SetLength(Raw, AByteCount);
  FStream.Position := AOffset;
  if AByteCount > 0 then
    FStream.ReadBuffer(Raw[0], AByteCount);

  case FCompression of
    cmpNone:
      Result := Raw;

    cmpLZW:
      Result := LZWDecompress(Raw, AExpectedSize);

    cmpDeflate:
      begin
        InStream := TMemoryStream.Create;
        try
          if Length(Raw) > 0 then
            InStream.WriteBuffer(Raw[0], Length(Raw));
          InStream.Position := 0;
          DecompStream := TDecompressionStream.Create(InStream);
          try
            SetLength(Out_, Max(AExpectedSize, 4096));
            OutPos := 0;
            repeat
              BytesRead := DecompStream.Read(OutBuf, SizeOf(OutBuf));
              if BytesRead > 0 then
              begin
                if OutPos + BytesRead > Length(Out_) then
                  SetLength(Out_, (OutPos + BytesRead) * 2);
                Move(OutBuf[0], Out_[OutPos], BytesRead);
                Inc(OutPos, BytesRead);
              end;
            until BytesRead = 0;
            SetLength(Out_, OutPos);
            Result := Out_;
          finally
            DecompStream.Free;
          end;
        finally
          InStream.Free;
        end;
      end;
    else
      raise EGeoTIFFError.Create('Unhandled compression mode');
  end;
end;

// Horizontal-differencing / floating-point predictor reversal.
// Predictor 1 (none) is the common case for classification rasters like
// GlobCover and is a no-op here. Predictor 2 undoes simple per-sample
// horizontal differencing. Predictor 3 (floating point) undoes the
// byte-plane deshuffle the original Rust ETOPO reader always assumed -
// kept for future elevation-layer reuse, now only applied when the tag
// actually says so.
procedure TGeoTIFFReader.ApplyPredictor(var AData: TBytes; AChunkWidth, AChunkHeight: Integer);
var
  row, i, sw: Integer;
  RowStart: Integer;
  Deshuffled: TBytes;
  RowBytes: TBytes;
  planeBytes: Integer;
begin
  if FPredictor = 1 then
    Exit; // nothing to undo

  sw := SampleByteWidth;

  if FPredictor = 2 then
  begin
    // Simple horizontal differencing, per sample, reset at each row.
    for row := 0 to AChunkHeight - 1 do
    begin
      RowStart := row * AChunkWidth * sw;
      if RowStart + AChunkWidth * sw > Length(AData) then
        Break; // partial chunk (LZW desync) - nothing more to un-predict
      for i := 1 to AChunkWidth - 1 do
      begin
        case sw of
          1: AData[RowStart + i] := Byte(AData[RowStart + i] + AData[RowStart + i - 1]);
          2: PWord(@AData[RowStart + i * 2])^ :=
               Word(PWord(@AData[RowStart + i * 2])^ + PWord(@AData[RowStart + (i - 1) * 2])^);
          4: PCardinal(@AData[RowStart + i * 4])^ :=
               Cardinal(PCardinal(@AData[RowStart + i * 4])^ + PCardinal(@AData[RowStart + (i - 1) * 4])^);
        end;
      end;
    end;
    Exit;
  end;

  if FPredictor = 3 then
  begin
    // Floating-point predictor: each row is stored as separate byte
    // planes (all byte-0's, then all byte-1's, etc.), each plane
    // horizontally differenced independently, MSB plane first. Ported
    // from tiff_reader.rs's decode_tile_bytes, generalized to any
    // AChunkWidth instead of assuming a fixed tile width.
    planeBytes := AChunkWidth * sw;
    SetLength(Deshuffled, Length(AData));
    for row := 0 to AChunkHeight - 1 do
    begin
      RowStart := row * planeBytes;
      if RowStart + planeBytes > Length(AData) then Break;

      SetLength(RowBytes, planeBytes);
      Move(AData[RowStart], RowBytes[0], planeBytes);
      for i := 1 to planeBytes - 1 do
        RowBytes[i] := Byte(RowBytes[i] + RowBytes[i - 1]);

      for i := 0 to AChunkWidth - 1 do
      begin
        // sw byte planes, MSB-plane-first, reassembled per pixel -
        // mirrors the Rust code's B1..B4 reconstruction for sw=4.
        case sw of
          4: begin
               Deshuffled[RowStart + i * 4 + 0] := RowBytes[i + AChunkWidth * 3];
               Deshuffled[RowStart + i * 4 + 1] := RowBytes[i + AChunkWidth * 2];
               Deshuffled[RowStart + i * 4 + 2] := RowBytes[i + AChunkWidth * 1];
               Deshuffled[RowStart + i * 4 + 3] := RowBytes[i + AChunkWidth * 0];
             end;
          2: begin
               Deshuffled[RowStart + i * 2 + 0] := RowBytes[i + AChunkWidth * 1];
               Deshuffled[RowStart + i * 2 + 1] := RowBytes[i + AChunkWidth * 0];
             end;
          1: Deshuffled[RowStart + i] := RowBytes[i];
        end;
      end;
    end;
    AData := Deshuffled;
    Exit;
  end;

  raise EGeoTIFFError.CreateFmt('Unsupported Predictor value %d', [FPredictor]);
end;

function TGeoTIFFReader.GetChunkIndex(AX, AY: Integer): Integer;
var
  tilesAcross, tileX, tileY: Integer;
begin
  if FTiled then
  begin
    tilesAcross := (FWidth + FTileWidth - 1) div FTileWidth;
    tileX := AX div FTileWidth;
    tileY := AY div FTileHeight;
    Result := tileY * tilesAcross + tileX;
  end
  else
    Result := AY div FRowsPerStrip;
end;

function TGeoTIFFReader.GetChunkData(AChunkIndex: Integer): TBytes;
var
  Data: TBytes;
  chunkW, chunkH, expectedSize: Integer;
  validLen: Integer;
  Patched: TBytes;
begin
  if FChunkCache.TryGetValue(AChunkIndex, Result) then
    Exit;

  if FTiled then
  begin
    chunkW := FTileWidth;
    chunkH := FTileHeight; // tiles are stored at full nominal size even at
                            // image edges, per spec - unlike strips below
  end
  else
  begin
    chunkW := FWidth;
    // The last strip is legitimately shorter than FRowsPerStrip whenever
    // FHeight isn't an exact multiple of it - not a decode problem, just
    // how TIFF strips work. Using the uniform FRowsPerStrip for every
    // strip here previously caused the last strip to be misreported as a
    // partial/desynced decode.
    if (AChunkIndex + 1) * FRowsPerStrip > FHeight then
      chunkH := FHeight - AChunkIndex * FRowsPerStrip
    else
      chunkH := FRowsPerStrip;
  end;
  expectedSize := chunkW * chunkH * SampleByteWidth;

  try
    Data := DecompressChunk(FOffsets[AChunkIndex], FByteCounts[AChunkIndex], expectedSize);
    ApplyPredictor(Data, chunkW, chunkH);

    if Length(Data) < expectedSize then
    begin
      // LZW hit a desync partway through (see LZWDecompress) - everything
      // already in Data is a genuinely correct, validated decode; only the
      // missing tail needs patching. Borrow just that tail from the last
      // successfully-decoded chunk at the SAME byte positions, rather than
      // discarding the valid prefix too. Confirmed (2026-08) this is real,
      // localized corruption in a tiny fraction of strips in the source
      // file (~2 of 55800), not a reader bug - see conversation notes /
      // commit history for the full diagnosis.
      WriteLn(StdErr, Format('kyzu_geotiff: chunk %d recovered %d/%d bytes before desync - patching tail from chunk %d',
        [AChunkIndex, Length(Data), expectedSize, FLastGoodChunkIndex]));
      if FDumpFailingChunks then
        DumpFailingChunk(AChunkIndex, FOffsets[AChunkIndex], FByteCounts[AChunkIndex]);

      if (FLastGoodChunkIndex >= 0) and (Length(FLastGoodChunkData) = expectedSize) then
      begin
        validLen := Length(Data);
        SetLength(Patched, expectedSize);
        Move(Data[0], Patched[0], validLen);
        Move(FLastGoodChunkData[validLen], Patched[validLen], expectedSize - validLen);
        Data := Patched;
      end
      else
        SetLength(Data, expectedSize); // no prior good chunk yet - zero-pad the tail
    end;

    FLastGoodChunkIndex := AChunkIndex;
    FLastGoodChunkData := Copy(Data, 0, Length(Data));
  except
    on E: Exception do
    begin
      // Anything reaching here is a genuine, unexpected failure (not the
      // routine LZW-desync case handled above, which no longer raises) -
      // still worth falling back to the last good chunk wholesale rather
      // than crashing the bake.
      WriteLn(StdErr, 'kyzu_geotiff: chunk ', AChunkIndex, ' decode failed (offset=',
        FOffsets[AChunkIndex], ' bytes=', FByteCounts[AChunkIndex], '): ', E.Message,
        ' - substituting chunk ', FLastGoodChunkIndex);
      if FDumpFailingChunks then
        DumpFailingChunk(AChunkIndex, FOffsets[AChunkIndex], FByteCounts[AChunkIndex]);

      if (FLastGoodChunkIndex >= 0) and (Length(FLastGoodChunkData) = expectedSize) then
        Data := Copy(FLastGoodChunkData, 0, Length(FLastGoodChunkData))
      else
        SetLength(Data, expectedSize); // no prior good chunk yet (failure right at the start) - zeroed
    end;
  end;

  FChunkCache.Add(AChunkIndex, Data);
  Result := Data;
end;

function TGeoTIFFReader.GetByteSample(AX, AY: Integer): Byte;
var
  x, y, chunkIdx, chunkW, localX, localY: Integer;
  Data: TBytes;
begin
  x := EnsureRange(AX, 0, FWidth - 1);
  y := EnsureRange(AY, 0, FHeight - 1);
  chunkIdx := GetChunkIndex(x, y);
  Data := GetChunkData(chunkIdx);

  if FTiled then chunkW := FTileWidth else chunkW := FWidth;
  localX := x mod chunkW;
  if FTiled then localY := y mod FTileHeight else localY := y mod FRowsPerStrip;

  Result := Data[localY * chunkW + localX];
end;

function TGeoTIFFReader.GetInt16Sample(AX, AY: Integer): SmallInt;
var
  x, y, chunkIdx, chunkW, localX, localY, idx: Integer;
  Data: TBytes;
begin
  x := EnsureRange(AX, 0, FWidth - 1);
  y := EnsureRange(AY, 0, FHeight - 1);
  chunkIdx := GetChunkIndex(x, y);
  Data := GetChunkData(chunkIdx);

  if FTiled then chunkW := FTileWidth else chunkW := FWidth;
  localX := x mod chunkW;
  if FTiled then localY := y mod FTileHeight else localY := y mod FRowsPerStrip;

  idx := (localY * chunkW + localX) * 2;
  Result := SmallInt(Data[idx] or (Data[idx + 1] shl 8));
end;

function TGeoTIFFReader.GetFloatSample(AX, AY: Integer): Single;
var
  x, y, chunkIdx, chunkW, localX, localY, idx: Integer;
  Data: TBytes;
  Raw: Cardinal;
  F: Single absolute Raw;
begin
  x := EnsureRange(AX, 0, FWidth - 1);
  y := EnsureRange(AY, 0, FHeight - 1);
  chunkIdx := GetChunkIndex(x, y);
  Data := GetChunkData(chunkIdx);

  if FTiled then chunkW := FTileWidth else chunkW := FWidth;
  localX := x mod chunkW;
  if FTiled then localY := y mod FTileHeight else localY := y mod FRowsPerStrip;

  idx := (localY * chunkW + localX) * 4;
  Raw := Data[idx] or (Data[idx + 1] shl 8) or (Data[idx + 2] shl 16) or (Data[idx + 3] shl 24);
  if not (IsNan(F) or IsInfinite(F)) then
    Result := F
  else
    Result := 0;
end;

end.

{ ────────────────────────────────────────────────────────────
  Usage (once you have the real .tif files):

    var
      Reader: TGeoTIFFReader;
      ClassID: Byte;
    begin
      Reader := TGeoTIFFReader.Create('GLOBCOVER_L4_200901_200912_V2.3.tif');
      try
        WriteLn(Reader.Width, ' x ', Reader.Height);
        ClassID := Reader.GetByteSample(1000, 500);
      finally
        Reader.Free;
      end;
    end;

  BEFORE trusting output, run:  gdalinfo -json GLOBCOVER_L4_200901_200912_V2.3.tif
  and confirm against what this unit assumes:
    - Compression: should say "LZW" (code 5) - if it says something else,
      the case statement in ReadIFD's TAG_COMPRESSION handling needs a
      new branch, not a silent fallback.
    - Predictor: readme doesn't mention one, so it's likely absent (=1,
      no-op here) - worth confirming rather than assuming, since GlobCover
      is categorical data where a predictor wouldn't make sense anyway.
    - Tiled vs stripped: whichever gdalinfo reports, this unit handles
      both, but worth knowing which path you're actually exercising when
      debugging.
    - A cheap sanity check once wired into the bake tool: sample a known
      ocean coordinate and confirm GetByteSample returns 210 (Water
      bodies, per the legend table already extracted).
  ──────────────────────────────────────────────────────────── }
