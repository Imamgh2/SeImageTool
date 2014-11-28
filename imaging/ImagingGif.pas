{
  $Id: ImagingGif.pas 132 2008-08-27 20:37:38Z galfar $
  Vampyre Imaging Library
  by Marek Mauder 
  http://imaginglib.sourceforge.net

  The contents of this file are used with permission, subject to the Mozilla
  Public License Version 1.1 (the "License"); you may not use this file except
  in compliance with the License. You may obtain a copy of the License at
  http://www.mozilla.org/MPL/MPL-1.1.html

  Software distributed under the License is distributed on an "AS IS" basis,
  WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License for
  the specific language governing rights and limitations under the License.

  Alternatively, the contents of this file may be used under the terms of the
  GNU Lesser General Public License (the  "LGPL License"), in which case the
  provisions of the LGPL License are applicable instead of those above.
  If you wish to allow use of your version of this file only under the terms
  of the LGPL License and not to allow others to use your version of this file
  under the MPL, indicate your decision by deleting  the provisions above and
  replace  them with the notice and other provisions required by the LGPL
  License.  If you do not delete the provisions above, a recipient may use
  your version of this file under either the MPL or the LGPL License.

  For more information about the LGPL: http://www.gnu.org/copyleft/lesser.html
}

{ This unit contains image format loader/saver for GIF images.}
unit ImagingGif;

{$I ImagingOptions.inc}

interface

uses
  SysUtils, Classes, Imaging, ImagingTypes, ImagingIO, ImagingUtility;

type
  { GIF (Graphics Interchange Format) loader/saver class. GIF was
    (and is still used) popular format for storing images supporting
    multiple images per file and single color transparency.
    Pixel format is 8 bit indexed where each image frame can have
    its own color palette. GIF uses lossless LZW compression
    (patent expired few years ago).
    Imaging can load and save all GIFs with all frames and supports
    transparency.}
  TGIFFileFormat = class(TImageFileFormat)
  private
    function InterlaceStep(Y, Height: Integer; var Pass: Integer): Integer;
    procedure LZWDecompress(Stream: TStream; Handle: TImagingHandle;
      Width, Height: Integer; Interlaced: Boolean; Data: Pointer);
    procedure LZWCompress(const IO: TIOFunctions; Handle: TImagingHandle;
      Width, Height, BitCount: Integer; Interlaced: Boolean; Data: Pointer);
  protected
    function LoadData(Handle: TImagingHandle; var Images: TDynImageDataArray;
      OnlyFirstLevel: Boolean): Boolean; override;
    function SaveData(Handle: TImagingHandle; const Images: TDynImageDataArray;
      Index: LongInt): Boolean; override;
    procedure ConvertToSupported(var Image: TImageData;
      const Info: TImageFormatInfo); override;
  public
    constructor Create; override;
    function TestFormat(Handle: TImagingHandle): Boolean; override;
  end;

implementation

const
  SGIFFormatName = 'Graphics Interchange Format';
  SGIFMasks      = '*.gif';
  GIFSupportedFormats: TImageFormats = [ifIndex8];

type
  TGIFVersion = (gv87, gv89);
  TDisposalMethod = (dmUndefined, dmLeave, dmRestoreBackground,
    dmRestorePrevious, dmReserved4, dmReserved5, dmReserved6, dmReserved7);

const
  GIFSignature: TChar3 = 'GIF';
  GIFVersions: array[TGIFVersion] of TChar3 = ('87a', '89a');

  // Masks for accessing fields in PackedFields of TGIFHeader
  GIFGlobalColorTable = $80;
  GIFColorResolution  = $70;
  GIFColorTableSorted = $08;
  GIFColorTableSize   = $07;

  // Masks for accessing fields in PackedFields of TImageDescriptor
  GIFLocalColorTable  = $80;
  GIFInterlaced       = $40;
  GIFLocalTableSorted = $20;

  // Block identifiers
  GIFPlainText: Byte               = $01;
  GIFGraphicControlExtension: Byte = $F9;
  GIFCommentExtension: Byte        = $FE;
  GIFApplicationExtension: Byte    = $FF;
  GIFImageDescriptor: Byte         = Ord(',');
  GIFExtensionIntroducer: Byte     = Ord('!');
  GIFTrailer: Byte                 = Ord(';');
  GIFBlockTerminator: Byte         = $00;

  // Masks for accessing fields in PackedFields of TGraphicControlExtension
  GIFTransparent    = $01;
  GIFUserInput      = $02;
  GIFDisposalMethod = $1C;

type
  TGIFHeader = packed record
    // File header part
    Signature: TChar3;  // Header Signature (always "GIF")
    Version: TChar3;    // GIF format version("87a" or "89a")
    // Logical Screen Descriptor part
    ScreenWidth: Word;  // Width of Display Screen in Pixels
    ScreenHeight: Word; // Height of Display Screen in Pixels
    PackedFields: Byte; // Screen and color map information
    BackgroundColorIndex: Byte; // Background color index (in global color table)
    AspectRatio: Byte;  // Pixel aspect ratio, ratio = (AspectRatio + 15) / 64
  end;

  TImageDescriptor = packed record
    //Separator: Byte; // leave that out since we always read one bye ahead
    Left: Word;        // X position of image with respect to logical screen
    Top: Word;         // Y position
    Width: Word;
    Height: Word;
    PackedFields: Byte;
  end;

const
  // GIF extension labels
  GIFExtTypeGraphic     = $F9;
  GIFExtTypePlainText   = $01;
  GIFExtTypeApplication = $FF;
  GIFExtTypeComment     = $FE;

type
  TGraphicControlExtension = packed record
    BlockSize: Byte;
    PackedFields: Byte;
    DelayTime: Word;
    TransparentColorIndex: Byte;
    Terminator: Byte;
  end;

const
  CodeTableSize = 4096;
  HashTableSize = 17777;
  
type
  TReadContext = record
    Inx: Integer;
    Size: Integer;
    Buf: array [0..255 + 4] of Byte;
    CodeSize: Integer;
    ReadMask: Integer;
  end;
  PReadContext = ^TReadContext;

  TWriteContext = record
    Inx: Integer;
    CodeSize: Integer;
    Buf: array [0..255 + 4] of Byte;
  end;
  PWriteContext = ^TWriteContext;

  TOutputContext = record
    W: Integer;
    H: Integer;
    X: Integer;
    Y: Integer;
    BitsPerPixel: Integer;
    Pass: Integer;
    Interlace: Boolean;
    LineIdent: Integer;
    Data: Pointer;
    CurrLineData: Pointer;
  end;

  TImageDict = record
    Tail: Word;
    Index: Word;
    Col: Byte;
  end;
  PImageDict = ^TImageDict;

  PIntCodeTable = ^TIntCodeTable;
  TIntCodeTable = array [0..CodeTableSize - 1] of Word;

  TDictTable = array [0..CodeTableSize - 1] of TImageDict;
  PDictTable = ^TDictTable;

resourcestring
  SGIFDecodingError = 'Error when decoding GIF LZW data';

{
  TGIFFileFormat implementation
}

constructor TGIFFileFormat.Create;
begin
  inherited Create;
  FName := SGIFFormatName;
  FCanLoad := True;
  FCanSave := True;
  FIsMultiImageFormat := True;
  FSupportedFormats := GIFSupportedFormats;

  AddMasks(SGIFMasks);
end;

function TGIFFileFormat.InterlaceStep(Y, Height: Integer; var Pass: Integer): Integer;
begin
  Result := Y;
  case Pass of
    0, 1:
      Inc(Result, 8);
    2:
      Inc(Result, 4);
    3:
      Inc(Result, 2);
  end;
  if Result >= Height then
  begin
    if Pass = 0 then
    begin
      Pass := 1;
      Result := 4;
      if Result < Height then
        Exit;
    end;
    if Pass = 1 then
    begin
      Pass := 2;
      Result := 2;
      if Result < Height then
        Exit;
    end;
    if Pass = 2 then
    begin
      Pass := 3;
      Result := 1;
    end;
  end;
end;

{ GIF LZW decompresion code is from JVCL JvGIF.pas unit.}
procedure TGIFFileFormat.LZWDecompress(Stream: TStream; Handle: TImagingHandle; Width, Height: Integer;
  Interlaced: Boolean; Data: Pointer);
var
  MinCodeSize: Byte;
  MaxCode, BitMask, InitCodeSize: Integer;
  ClearCode, EndingCode, FirstFreeCode, FreeCode: Word;
  I, OutCount, Code: Integer;
  CurCode, OldCode, InCode, FinalChar: Word;
  Prefix, Suffix, OutCode: PIntCodeTable;
  ReadCtxt: TReadContext;
  OutCtxt: TOutputContext;
  TableFull: Boolean;

  function ReadCode(var Context: TReadContext): Integer;
  var
    RawCode: Integer;
    ByteIndex: Integer;
    Bytes: Byte;
    BytesToLose: Integer;
  begin
    while (Context.Inx + Context.CodeSize > Context.Size) and
      (Stream.Position < Stream.Size) do
    begin
      // Not enough bits in buffer - refill it - Not very efficient, but infrequently called
      BytesToLose := Context.Inx shr 3;
      // Note biggest Code Size is 12 bits. And this can at worst span 3 Bytes
      Move(Context.Buf[Word(BytesToLose)], Context.Buf[0], 3);
      Context.Inx := Context.Inx and 7;
      Context.Size := Context.Size - (BytesToLose shl 3);
      Stream.Read(Bytes, 1);
      if Bytes > 0 then
        Stream.Read(Context.Buf[Word(Context.Size shr 3)], Bytes);
      Context.Size := Context.Size + (Bytes shl 3);
    end;
    ByteIndex := Context.Inx shr 3;
    RawCode := Context.Buf[Word(ByteIndex)] +
      (Word(Context.Buf[Word(ByteIndex + 1)]) shl 8);
    if Context.CodeSize > 8 then
      RawCode := RawCode + (LongInt(Context.Buf[ByteIndex + 2]) shl 16);
    RawCode := RawCode shr (Context.Inx and 7);
    Context.Inx := Context.Inx + Byte(Context.CodeSize);
    Result := RawCode and Context.ReadMask;
  end;

  procedure Output(Value: Byte; var Context: TOutputContext);
  var
    P: PByte;
  begin
    if Context.Y >= Context.H then
      Exit;

    // Only ifIndex8 supported
    P := @PByteArray(Context.CurrLineData)[Context.X];
    P^ := Value;

    {case Context.BitsPerPixel of
      1:
        begin
          P := @PByteArray(Context.CurrLineData)[Context.X shr 3];
          if (Context.X and $07) <> 0 then
            P^ := P^ or Word(Value shl (7 - (Word(Context.X and 7))))
          else
            P^ := Byte(Value shl 7);
        end;
      4:
        begin
          P := @PByteArray(Context.CurrLineData)[Context.X shr 1];
          if (Context.X and 1) <> 0 then
            P^ := P^ or Value
          else
            P^ := Byte(Value shl 4);
        end;
      8:
        begin
          P := @PByteArray(Context.CurrLineData)[Context.X];
          P^ := Value;
        end;
    end;}
    Inc(Context.X);

    if Context.X < Context.W then
      Exit;
    Context.X := 0;
    if Context.Interlace then
      Context.Y := InterlaceStep(Context.Y, Context.H, Context.Pass)
    else
      Inc(Context.Y);

    Context.CurrLineData := @PByteArray(Context.Data)[Context.Y * Context.LineIdent];
  end;

begin
  OutCount := 0;
  OldCode := 0;
  FinalChar := 0;
  TableFull := False;
  GetMem(Prefix, SizeOf(TIntCodeTable));
  GetMem(Suffix, SizeOf(TIntCodeTable));
  GetMem(OutCode, SizeOf(TIntCodeTable) + SizeOf(Word));
  try
    Stream.Read(MinCodeSize, 1);
    if (MinCodeSize < 2) or (MinCodeSize > 9) then
      RaiseImaging(SGIFDecodingError, []);
    // Initial read context
    ReadCtxt.Inx := 0;
    ReadCtxt.Size := 0;
    ReadCtxt.CodeSize := MinCodeSize + 1;
    ReadCtxt.ReadMask := (1 shl ReadCtxt.CodeSize) - 1;
    // Initialise pixel-output context
    OutCtxt.X := 0;
    OutCtxt.Y := 0;
    OutCtxt.Pass := 0;
    OutCtxt.W := Width;
    OutCtxt.H := Height;
    OutCtxt.BitsPerPixel := MinCodeSize;
    OutCtxt.Interlace := Interlaced;
    OutCtxt.LineIdent := Width;
    OutCtxt.Data := Data;
    OutCtxt.CurrLineData := Data;
    BitMask := (1 shl OutCtxt.BitsPerPixel) - 1;
    // 2 ^ MinCodeSize accounts for all colours in file
    ClearCode := 1 shl MinCodeSize;
    EndingCode := ClearCode + 1;
    FreeCode := ClearCode + 2;
    FirstFreeCode := FreeCode;
    // 2^ (MinCodeSize + 1) includes clear and eoi Code and space too
    InitCodeSize := ReadCtxt.CodeSize;
    MaxCode := 1 shl ReadCtxt.CodeSize;
    Code := ReadCode(ReadCtxt);
    while (Code <> EndingCode) and (Code <> $FFFF) and
      (OutCtxt.Y < OutCtxt.H) do
    begin
      if Code = ClearCode then
      begin
        ReadCtxt.CodeSize := InitCodeSize;
        MaxCode := 1 shl ReadCtxt.CodeSize;
        ReadCtxt.ReadMask := MaxCode - 1;
        FreeCode := FirstFreeCode;
        Code := ReadCode(ReadCtxt);
        CurCode := Code;
        OldCode := Code;
        if Code = $FFFF then
          Break;
        FinalChar := (CurCode and BitMask);
        Output(Byte(FinalChar), OutCtxt);
        TableFull := False;
      end
      else
      begin
        CurCode := Code;
        InCode := Code;
        if CurCode >= FreeCode then
        begin
          CurCode := OldCode;
          OutCode^[OutCount] := FinalChar;
          Inc(OutCount);
        end;
        while CurCode > BitMask do
        begin
          if OutCount > CodeTableSize then
            RaiseImaging(SGIFDecodingError, []);
          OutCode^[OutCount] := Suffix^[CurCode];
          Inc(OutCount);
          CurCode := Prefix^[CurCode];
        end;

        FinalChar := CurCode and BitMask;
        OutCode^[OutCount] := FinalChar;
        Inc(OutCount);
        for I := OutCount - 1 downto 0 do
          Output(Byte(OutCode^[I]), OutCtxt);
        OutCount := 0;
        // Update dictionary
        if not TableFull then
        begin
          Prefix^[FreeCode] := OldCode;
          Suffix^[FreeCode] := FinalChar;
          // Advance to next free slot
          Inc(FreeCode);
          if FreeCode >= MaxCode then
          begin
            if ReadCtxt.CodeSize < 12 then
            begin
              Inc(ReadCtxt.CodeSize);
              MaxCode := MaxCode shl 1;
              ReadCtxt.ReadMask := (1 shl ReadCtxt.CodeSize) - 1;
            end
            else
              TableFull := True;
          end;
        end;
        OldCode := InCode;
      end;
      Code := ReadCode(ReadCtxt);
    end;
    if Code = $FFFF then
      RaiseImaging(SGIFDecodingError, []);
  finally
    FreeMem(Prefix);
    FreeMem(OutCode);
    FreeMem(Suffix);
  end;
end;

{ GIF LZW compresion code is from JVCL JvGIF.pas unit.}
procedure TGIFFileFormat.LZWCompress(const IO: TIOFunctions; Handle: TImagingHandle; Width, Height, BitCount: Integer;
    Interlaced: Boolean; Data: Pointer);
var
  LineIdent: Integer;
  MinCodeSize, Col: Byte;
  InitCodeSize, X, Y: Integer;
  Pass: Integer;
  MaxCode: Integer; { 1 shl CodeSize }
  ClearCode, EndingCode, LastCode, Tail: Integer;
  I, HashValue: Integer;
  LenString: Word;
  Dict: PDictTable;
  HashTable: TList;
  PData: PByte;
  WriteCtxt: TWriteContext;

  function InitHash(P: Integer): Integer;
  begin
    Result := (P + 3) * 301;
  end;

  procedure WriteCode(Code: Integer; var Context: TWriteContext);
  var
    BufIndex: Integer;
    Bytes: Byte;
  begin
    BufIndex := Context.Inx shr 3;
    Code := Code shl (Context.Inx and 7);
    Context.Buf[BufIndex] := Context.Buf[BufIndex] or Byte(Code);
    Context.Buf[BufIndex + 1] := Byte(Code shr 8);
    Context.Buf[BufIndex + 2] := Byte(Code shr 16);
    Context.Inx := Context.Inx + Context.CodeSize;
    if Context.Inx >= 255 * 8 then
    begin
      // Flush out full buffer
      Bytes := 255;
      IO.Write(Handle, @Bytes, 1);
      IO.Write(Handle, @Context.Buf, Bytes);
      Move(Context.Buf[255], Context.Buf[0], 2);
      FillChar(Context.Buf[2], 255, 0);
      Context.Inx := Context.Inx - (255 * 8);
    end;
  end;

  procedure FlushCode(var Context: TWriteContext);
  var
    Bytes: Byte;
  begin
    Bytes := (Context.Inx + 7) shr 3;
    if Bytes > 0 then
    begin
      IO.Write(Handle, @Bytes, 1);
      IO.Write(Handle, @Context.Buf, Bytes);
    end;
    // Data block terminator - a block of zero Size
    Bytes := 0;
    IO.Write(Handle, @Bytes, 1);
  end;

begin
  LineIdent := Width;
  Tail := 0;
  HashValue := 0;
  Col := 0;
  HashTable := TList.Create;
  GetMem(Dict, SizeOf(TDictTable));
  try
    for I := 0 to HashTableSize - 1 do
      HashTable.Add(nil);

    // Initialise encoder variables
    InitCodeSize := BitCount + 1;
    if InitCodeSize = 2 then
      Inc(InitCodeSize);
    MinCodeSize := InitCodeSize - 1;
    IO.Write(Handle, @MinCodeSize, 1);
    ClearCode := 1 shl MinCodeSize;
    EndingCode := ClearCode + 1;
    LastCode := EndingCode;
    MaxCode := 1 shl InitCodeSize;
    LenString := 0;
    // Setup write context
    WriteCtxt.Inx := 0;
    WriteCtxt.CodeSize := InitCodeSize;
    FillChar(WriteCtxt.Buf, SizeOf(WriteCtxt.Buf), 0);
    WriteCode(ClearCode, WriteCtxt);
    Y := 0;
    Pass := 0;

    while Y < Height do
    begin
      PData := @PByteArray(Data)[Y * LineIdent];
      for X := 0 to Width - 1 do
      begin
        // Only ifIndex8 support
        case BitCount of
          8:
            begin
              Col := PData^;
              PData := @PByteArray(PData)[1];
            end;
          {4:
            begin
              if X and 1 <> 0 then
              begin
                Col := PData^ and $0F;
                PData := @PByteArray(PData)[1];
              end
              else
                Col := PData^ shr 4;
            end;
          1:
            begin
              if X and 7 = 7 then
              begin
                Col := PData^ and 1;
                PData := @PByteArray(PData)[1];
              end
              else
                Col := (PData^ shr (7 - (X and $07))) and $01;
            end;}
        end;
        Inc(LenString);
        if LenString = 1 then
        begin
          Tail := Col;
          HashValue := InitHash(Col);
        end
        else
        begin
          HashValue := HashValue * (Col + LenString + 4);
          I := HashValue mod HashTableSize;
          HashValue := HashValue mod HashTableSize;
          while (HashTable[I] <> nil) and
            ((PImageDict(HashTable[I])^.Tail <> Tail) or
            (PImageDict(HashTable[I])^.Col <> Col)) do
          begin
            Inc(I);
            if I >= HashTableSize then
              I := 0;
          end;
          if HashTable[I] <> nil then // Found in the strings table
            Tail := PImageDict(HashTable[I])^.Index
          else
          begin
            // Not found
            WriteCode(Tail, WriteCtxt);
            Inc(LastCode);
            HashTable[I] := @Dict^[LastCode];
            PImageDict(HashTable[I])^.Index := LastCode;
            PImageDict(HashTable[I])^.Tail := Tail;
            PImageDict(HashTable[I])^.Col := Col;
            Tail := Col;
            HashValue := InitHash(Col);
            LenString := 1;
            if LastCode >= MaxCode then
            begin
              // Next Code will be written longer
              MaxCode := MaxCode shl 1;
              Inc(WriteCtxt.CodeSize);
            end
            else
            if LastCode >= CodeTableSize - 2 then
            begin
              // Reset tables
              WriteCode(Tail, WriteCtxt);
              WriteCode(ClearCode, WriteCtxt);
              LenString := 0;
              LastCode := EndingCode;
              WriteCtxt.CodeSize := InitCodeSize;
              MaxCode := 1 shl InitCodeSize;
              for I := 0 to HashTableSize - 1 do
                HashTable[I] := nil;
            end;
          end;
        end;
      end;
      if Interlaced then
        Y := InterlaceStep(Y, Height, Pass)
      else
        Inc(Y);
    end;
    WriteCode(Tail, WriteCtxt);
    WriteCode(EndingCode, WriteCtxt);
    FlushCode(WriteCtxt);
  finally
    HashTable.Free;
    FreeMem(Dict);
  end;
end;

function TGIFFileFormat.LoadData(Handle: TImagingHandle;
  var Images: TDynImageDataArray; OnlyFirstLevel: Boolean): Boolean;
var
  Header: TGIFHeader;
  HasGlobalPal: Boolean;
  GlobalPalLength: Integer;
  GlobalPal: TPalette32Size256;
  I: Integer;
  BlockID: Byte;
  HasGraphicExt: Boolean;
  GraphicExt: TGraphicControlExtension;
  Disposals: array of TDisposalMethod;

  function ReadBlockID: Byte;
  begin
    Result := GIFTrailer;
    GetIO.Read(Handle, @Result, SizeOf(Result));
  end;

  procedure ReadExtensions;
  var
    BlockSize, ExtType: Byte;
  begin
    HasGraphicExt := False;

    // Read extensions until image descriptor is found. Only graphic extension
    // is stored now (for transparency), others are skipped.
    while BlockID = GIFExtensionIntroducer do
    with GetIO do
    begin
      Read(Handle, @ExtType, SizeOf(ExtType));

      if ExtType = GIFGraphicControlExtension then
      begin
        HasGraphicExt := True;
        Read(Handle, @GraphicExt, SizeOf(GraphicExt));
      end
      else if ExtType in [GIFCommentExtension, GIFApplicationExtension, GIFPlainText] then
      repeat
        // Read block sizes and skip them
        Read(Handle, @BlockSize, SizeOf(BlockSize));
        Seek(Handle, BlockSize, smFromCurrent);
      until BlockSize = 0;

      // Read ID of following block
      BlockID := ReadBlockID;
    end;
  end;

  procedure CopyFrameTransparent(const Image, Frame: TImageData; Left, Top,
    TransIndex: Integer; Disposal: TDisposalMethod);
  var
    X, Y: Integer;
    Src, Dst: PByte;
  begin
    Src := Frame.Bits;

    // Copy all pixels from frame to log screen but ignore the transparent ones
    for Y := 0 to Frame.Height - 1 do
    begin
      Dst := @PByteArray(Image.Bits)[(Top + Y) * Image.Width + Left];
      for X := 0 to Frame.Width - 1 do
      begin
        // If disposal methos is undefined copy all pixels regardless of
        // transparency (transparency of whole image will be determined by TranspIndex
        // in image palette) - same effect as filling the image with trasp color
        // instead of backround color beforehand.
        // For other methods don't copy transparent pixels from frame to image.
        if (Src^ <> TransIndex) or (Disposal = dmUndefined) then
          Dst^ := Src^;
        Inc(Src);
        Inc(Dst);
      end;
    end;
  end;

  procedure CopyLZWData(Dest: TStream);
  var
    CodeSize, BlockSize: Byte;
    InputSize: Integer;
    Buff: array[Byte] of Byte;
  begin
    InputSize := ImagingIO.GetInputSize(GetIO, Handle);
    // Copy codesize to stream
    GetIO.Read(Handle, @CodeSize, 1);
    Dest.Write(CodeSize, 1);
    repeat
      // Read and write data blocks, last is block term value of 0
      GetIO.Read(Handle, @BlockSize, 1);
      Dest.Write(BlockSize, 1);
      if BlockSize > 0 then
      begin
        GetIO.Read(Handle, @Buff[0], BlockSize);
        Dest.Write(Buff[0], BlockSize);
      end;
    until (BlockSize = 0) or (GetIO.Tell(Handle) >= InputSize);
  end;

  procedure ReadFrame;
  var
    ImageDesc: TImageDescriptor;
    HasLocalPal, Interlaced, HasTransparency: Boolean;
    I, Idx, LocalPalLength, TransIndex: Integer;
    LocalPal: TPalette32Size256;
    BlockTerm: Byte;
    Frame: TImageData;
    LZWStream: TMemoryStream;
  begin
    Idx := Length(Images);
    SetLength(Images, Idx + 1);
    FillChar(LocalPal, SizeOf(LocalPal), 0);
    with GetIO do
    begin
      // Read and parse image descriptor
      Read(Handle, @ImageDesc, SizeOf(ImageDesc));
      HasLocalPal := (ImageDesc.PackedFields and GIFLocalColorTable) = GIFLocalColorTable;
      Interlaced := (ImageDesc.PackedFields and GIFInterlaced) = GIFInterlaced;
      LocalPalLength := ImageDesc.PackedFields and GIFColorTableSize;
      LocalPalLength := 1 shl (LocalPalLength + 1);   // Total pal length is 2^(n+1)

      // Create new logical screen
      NewImage(Header.ScreenWidth, Header.ScreenHeight, ifIndex8, Images[Idx]);
      // Create new image for this frame which would be later pasted onto logical screen
      InitImage(Frame);
      NewImage(ImageDesc.Width, ImageDesc.Height, ifIndex8, Frame);

      // Load local palette if there is any
      if HasLocalPal then
        for I := 0 to LocalPalLength - 1 do
        begin
          LocalPal[I].A := 255;
          Read(Handle, @LocalPal[I].R, SizeOf(LocalPal[I].R));
          Read(Handle, @LocalPal[I].G, SizeOf(LocalPal[I].G));
          Read(Handle, @LocalPal[I].B, SizeOf(LocalPal[I].B));
        end;

      // Use local pal if present or global pal if present or create
      // default pal if neither of them is present
      if HasLocalPal then
        Move(LocalPal, Images[Idx].Palette^, SizeOf(LocalPal))
      else if HasGlobalPal then
        Move(GlobalPal, Images[Idx].Palette^, SizeOf(GlobalPal))
      else
        FillCustomPalette(Images[Idx].Palette, GlobalPalLength, 3, 3, 2);

      // Add default disposal method for this frame
      SetLength(Disposals, Length(Disposals) + 1);
      Disposals[High(Disposals)] := dmUndefined;

      // If Grahic Control Extension is present make use of it
      if HasGraphicExt then
      begin
        HasTransparency := (GraphicExt.PackedFields and GIFTransparent) = GIFTransparent;
        Disposals[High(Disposals)] := TDisposalMethod((GraphicExt.PackedFields and GIFDisposalMethod) shr 2);
        if HasTransparency then
          Images[Idx].Palette[GraphicExt.TransparentColorIndex].A := 0;
      end
      else
        HasTransparency := False;

      if Idx >= 1 then
      begin
        // If previous frame had some special disposal method we take it into
        // account now
        case Disposals[Idx - 1] of
          dmUndefined: ; // Do nothing
          dmLeave:
            begin
              // Leave previous frame on log screen
              CopyRect(Images[Idx - 1], 0, 0, Images[Idx].Width,
                Images[Idx].Height, Images[Idx], 0, 0);
            end;
          dmRestoreBackground:
            begin
              // Clear log screen with background color
              FillRect(Images[Idx], 0, 0, Images[Idx].Width, Images[Idx].Height,
                @Header.BackgroundColorIndex);
            end;
          dmRestorePrevious:
            if Idx >= 2 then
            begin
              // Set log screen to "previous of previous" frame
              CopyRect(Images[Idx - 2], 0, 0, Images[Idx].Width,
                Images[Idx].Height, Images[Idx], 0, 0);
            end;
        end;
      end
      else
      begin
        // First frame - just fill with background color
        FillRect(Images[Idx], 0, 0, Images[Idx].Width, Images[Idx].Height,
          @Header.BackgroundColorIndex);
      end;

      LZWStream := TMemoryStream.Create;
      try
        // Copy LZW data to temp stream, needed for correct decompression
        CopyLZWData(LZWStream);
        LZWStream.Position := 0;
        // Data decompression finally
        LZWDecompress(LZWStream, Handle, ImageDesc.Width, ImageDesc.Height, Interlaced, Frame.Bits);
        // Now copy frame to logical screen with skipping of transparent pixels (if enabled)
        TransIndex := Iff(HasTransparency, GraphicExt.TransparentColorIndex, MaxInt);
        CopyFrameTransparent(Images[Idx], Frame, ImageDesc.Left, ImageDesc.Top,
          TransIndex, Disposals[Idx]);
      finally
        FreeImage(Frame);
        LZWStream.Free;
      end;
    end;
  end;

begin
  SetLength(Images, 0);
  FillChar(GlobalPal, SizeOf(GlobalPal), 0);
  with GetIO do
  begin
    // Read GIF header
    Read(Handle, @Header, SizeOf(Header));
    HasGlobalPal := Header.PackedFields and GIFGlobalColorTable = GIFGlobalColorTable; // Bit 7
    GlobalPalLength := Header.PackedFields and GIFColorTableSize; // Bits 0-2
    GlobalPalLength := 1 shl (GlobalPalLength + 1);   // Total pal length is 2^(n+1)

    // Read global palette from file if present
    if HasGlobalPal then
    begin
      for I := 0 to GlobalPalLength - 1 do
      begin
        GlobalPal[I].A := 255;
        Read(Handle, @GlobalPal[I].R, SizeOf(GlobalPal[I].R));
        Read(Handle, @GlobalPal[I].G, SizeOf(GlobalPal[I].G));
        Read(Handle, @GlobalPal[I].B, SizeOf(GlobalPal[I].B));
      end;
    end;

    // Read ID of the first block
    BlockID := ReadBlockID;

    // Now read all data blocks in the file until file trailer is reached
    while BlockID <> GIFTrailer do
    begin
      // Read supported and skip unsupported extensions
      ReadExtensions;
      // If image frame is found read it
      if BlockID = GIFImageDescriptor then
        ReadFrame;
      // Read next block's ID
      BlockID := ReadBlockID;
      // If block ID is unknown set it to end-of-GIF marker
      if not (BlockID in [GIFExtensionIntroducer, GIFTrailer, GIFImageDescriptor]) then
        BlockID := GIFTrailer;
    end;

    Result := True;
  end;
end;

function TGIFFileFormat.SaveData(Handle: TImagingHandle;
  const Images: TDynImageDataArray; Index: Integer): Boolean;
var
  Header: TGIFHeader;
  ImageDesc: TImageDescriptor;
  ImageToSave: TImageData;
  MustBeFreed: Boolean;
  I, J: Integer;
  GraphicExt: TGraphicControlExtension;

  procedure FindMaxDimensions(var MaxWidth, MaxHeight: Word);
  var
    I: Integer;
  begin
    MaxWidth := Images[FFirstIdx].Width;
    MaxHeight := Images[FFirstIdx].Height;

    for I := FFirstIdx + 1 to FLastIdx do
    begin
      MaxWidth := Iff(Images[I].Width > MaxWidth, Images[I].Width, MaxWidth);
      MaxHeight := Iff(Images[I].Height > MaxWidth, Images[I].Height, MaxHeight);
    end;
  end;

begin
  // Fill header with data, select size of largest image in array as
  // logical screen size
  FillChar(Header, Sizeof(Header), 0);
  Header.Signature := GIFSignature;
  Header.Version := GIFVersions[gv89];
  FindMaxDimensions(Header.ScreenWidth, Header.ScreenHeight);
  Header.PackedFields := GIFColorResolution; // Color resolution is 256
  GetIO.Write(Handle, @Header, SizeOf(Header));

  // Prepare default GC extension with delay
  FillChar(GraphicExt, Sizeof(GraphicExt), 0);
  GraphicExt.DelayTime := 65;
  GraphicExt.BlockSize := 4;

  for I := FFirstIdx to FLastIdx do
  begin
    if MakeCompatible(Images[I], ImageToSave, MustBeFreed) then
    with GetIO, ImageToSave do
    try
      // Write Graphic Control Extension with default delay
      Write(Handle, @GIFExtensionIntroducer, SizeOf(GIFExtensionIntroducer));
      Write(Handle, @GIFGraphicControlExtension, SizeOf(GIFGraphicControlExtension));
      Write(Handle, @GraphicExt, SizeOf(GraphicExt));
      // Write frame marker and fill and write image descriptor for this frame
      Write(Handle, @GIFImageDescriptor, SizeOf(GIFImageDescriptor));
      FillChar(ImageDesc, Sizeof(ImageDesc), 0);
      ImageDesc.Width := Width;
      ImageDesc.Height := Height;
      ImageDesc.PackedFields := GIFLocalColorTable or GIFColorTableSize; // Use lccal color table with 256 entries
      Write(Handle, @ImageDesc, SizeOf(ImageDesc));

      // Write local color table for each frame
      for J := 0 to 255 do
      begin
        Write(Handle, @Palette[J].R, SizeOf(Palette[J].R));
        Write(Handle, @Palette[J].G, SizeOf(Palette[J].G));
        Write(Handle, @Palette[J].B, SizeOf(Palette[J].B));
      end;

      // Fonally compress image data 
      LZWCompress(GetIO, Handle, Width, Height, 8, False, Bits);

    finally
      if MustBeFreed then
        FreeImage(ImageToSave);
    end;
  end;

  GetIO.Write(Handle, @GIFTrailer, SizeOf(GIFTrailer));
  Result := True;
end;

procedure TGIFFileFormat.ConvertToSupported(var Image: TImageData;
  const Info: TImageFormatInfo);
begin
  ConvertImage(Image, ifIndex8);
end;

function TGIFFileFormat.TestFormat(Handle: TImagingHandle): Boolean;
var
  Header: TGIFHeader;
  ReadCount: LongInt;
begin
  Result := False;
  if Handle <> nil then
  begin
    ReadCount := GetIO.Read(Handle, @Header, SizeOf(Header));
    GetIO.Seek(Handle, -ReadCount, smFromCurrent);
    Result := (ReadCount >= SizeOf(Header)) and
      (Header.Signature = GIFSignature) and
      ((Header.Version = GIFVersions[gv87]) or (Header.Version = GIFVersions[gv89]));
  end;
end;

initialization
  RegisterImageFileFormat(TGIFFileFormat);

{
  File Notes:

 -- TODOS ----------------------------------------------------
    - nothing now

  -- 0.25.0 Changes/Bug Fixes ---------------------------------
    - Fixed loading of some rare GIFs, problems with LZW
      decompression.

  -- 0.24.3 Changes/Bug Fixes ---------------------------------
    - Better solution to transparency for some GIFs. Background not
      transparent by default.

  -- 0.24.1 Changes/Bug Fixes ---------------------------------
    - Made backround color transparent by default (alpha = 0).

  -- 0.23 Changes/Bug Fixes -----------------------------------
    - Fixed other loading bugs (local pal size, transparency).
    - Added GIF saving.
    - Fixed bug when loading multiframe GIFs and implemented few animation
      features (disposal methods, ...). 
    - Loading of GIFs working.
    - Unit created with initial stuff!
}

end.
