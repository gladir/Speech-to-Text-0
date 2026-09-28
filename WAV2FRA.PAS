program WAV2FRA;

{$mode fpc}{$H+}
{$modeswitch result+}{$modeswitch out+}

{ Free Pascal 3.2+. Compile: fpc -O2 WAV2FRA.PAS
  Pipeline local: RIFF -> mono/16 kHz -> Silero VAD -> Whisper francais
  -> alignement acoustique MFA mots/phonemes. Aucun appel reseau ici.
  Les poids entraines sont externes, pas simules par des regles Pascal.
  Whisper integre modelisation acoustique et linguistique, accents et
  ponctuation. MFA aligne le texte reconnu: une erreur de transcription
  peut donc aussi produire des frontieres phonetiques incorrectes.
  Turbo Pascal DOS ne fournit pas la memoire requise pour ce pipeline. }

uses DOS
  {$IFDEF MSWINDOWS}, Windows{$ELSE}, BaseUnix, Unix{$ENDIF};

type
  { Fichier binaire tamponne, manipule uniquement par des procedures. }
  TBinary = record
    Handle: File;
    Name: string;
    Size, Position: Int64;
    Buffer: array[0..8191] of Byte;
    Used, Index: LongInt;
    Writing: Boolean;
  end;
  PBinary = ^TBinary;
  TSamples = array of Single;
  TOptions = record
    Input, Output, Model, VADModel, Whisper, MFA, Dictionary, Acoustic: string;
    PrepareOnly, TextOnly: Boolean;
  end;

const
  TargetRate = 16000;
  MaxInputBytes = 268435456; { limite explicite: 256 Mio }
  MaxSeconds = 1800;
var
  OpenFiles: array[0..7] of PBinary;
  WorkDirectory: string;
  CommandArguments: array of string;

procedure Fail(const S: string); forward;
procedure CleanupWork; forward;

{$IFDEF MSWINDOWS}
type
  TWideArguments = array[0..65535] of PWideChar;
  PWideArguments = ^TWideArguments;
function DecodeCommandLine(Command: PWideChar; var Count: LongInt): PWideArguments;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';
{$ENDIF}

procedure InitializeArguments;
var I, Count: LongInt;
{$IFDEF MSWINDOWS}
    Values: PWideArguments; Size: LongInt;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  { Le ParamStr Win32 de FPC 3.2 ne decode pas les antislashs et guillemets
    comme les moteurs C/C++. Decoder aussi l'entree selon la convention OS. }
  Values := DecodeCommandLine(GetCommandLineW, Count);
  if Values = nil then Fail('Lecture de la ligne de commande impossible.');
  SetLength(CommandArguments, Count);
  for I := 0 to Count - 1 do
  begin
    Size := WideCharToMultiByte(CP_ACP, 0, Values^[I], -1, nil, 0, nil, nil);
    if Size = 0 then
    begin
      LocalFree(HLOCAL(Values)); Fail('Conversion d''argument impossible.');
    end;
    SetLength(CommandArguments[I], Size);
    WideCharToMultiByte(CP_ACP, 0, Values^[I], -1, PChar(CommandArguments[I]), Size, nil, nil);
    SetLength(CommandArguments[I], Size - 1);
  end;
  LocalFree(HLOCAL(Values));
  {$ELSE}
  Count := System.ParamCount + 1;
  SetLength(CommandArguments, Count);
  for I := 0 to Count - 1 do CommandArguments[I] := System.ParamStr(I);
  {$ENDIF}
end;

function ParamCount: Integer;
begin
  Result := Length(CommandArguments) - 1;
end;

function ParamStr(Index: Integer): string;
begin
  if (Index >= 0) and (Index < Length(CommandArguments)) then Result := CommandArguments[Index]
  else Result := '';
end;

{ Services proceduraux locaux, sans Classes, SysUtils ni Process. }
function IntToStr(Value: Int64): string;
begin
  Str(Value, Result);
end;

function Trim(const Text: string): string;
var First, Last: Integer;
begin
  First := 1; Last := Length(Text);
  while (First <= Last) and (Text[First] <= ' ') do Inc(First);
  while (Last >= First) and (Text[Last] <= ' ') do Dec(Last);
  Result := Copy(Text, First, Last - First + 1);
end;

function LowerCase(const Text: string): string;
var I: Integer;
begin
  { Seul le suffixe ASCII des noms de modeles est compare. }
  Result := Text;
  for I := 1 to Length(Result) do
    if Result[I] in ['A'..'Z'] then Result[I] := Chr(Ord(Result[I]) + 32);
end;

function IsPathDelimiter(C: Char): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := C in ['/', '\'];
  {$ELSE}
  Result := C = '/';
  {$ENDIF}
end;

function IncludeTrailingPathDelimiter(const Path: string): string;
begin
  Result := Path;
  if (Result = '') or not IsPathDelimiter(Result[Length(Result)]) then
    Result := Result + DirectorySeparator;
end;

function ExtractFileName(const Path: string): string;
var I: Integer;
begin
  I := Length(Path);
  while (I > 0) and not IsPathDelimiter(Path[I]) do Dec(I);
  Result := Copy(Path, I + 1, Length(Path) - I);
end;

function ExtractFileDir(const Path: string): string;
var I: Integer;
begin
  I := Length(Path);
  while (I > 0) and not IsPathDelimiter(Path[I]) do Dec(I);
  { Conserver le separateur des racines / et C:\. }
  if (I = 1) {$IFDEF MSWINDOWS}or ((I = 3) and (Path[2] = ':')){$ENDIF} then
    Result := Copy(Path, 1, I)
  else if I > 0 then Result := Copy(Path, 1, I - 1)
  else Result := '';
end;

function ChangeFileExt(const Path, Extension: string): string;
var I: Integer;
begin
  I := Length(Path);
  while (I > 0) and not IsPathDelimiter(Path[I]) and (Path[I] <> '.') do Dec(I);
  if (I > 0) and (Path[I] = '.') then Result := Copy(Path, 1, I - 1) + Extension
  else Result := Path + Extension;
end;

function ExpandFileName(const Path: string): string;
var Current: string;
begin
  { Construire un chemin absolu sans limite ShortString. Les composants
    . et .. restent resolves par le systeme de fichiers. }
  GetDir(0, Current);
  {$IFDEF MSWINDOWS}
  if (Length(Path) >= 2) and (Path[2] = ':') then
  begin
    if (Length(Path) >= 3) and IsPathDelimiter(Path[3]) then Exit(Path);
    if UpCase(Path[1]) in ['A'..'Z'] then
      GetDir(Ord(UpCase(Path[1])) - Ord('A') + 1, Current);
    Exit(IncludeTrailingPathDelimiter(Current) + Copy(Path, 3, Length(Path)));
  end;
  if (Length(Path) >= 2) and IsPathDelimiter(Path[1]) and IsPathDelimiter(Path[2]) then
    Exit(Path);
  if (Path <> '') and IsPathDelimiter(Path[1]) then Exit(Copy(Current, 1, 2) + Path);
  {$ELSE}
  if (Path <> '') and IsPathDelimiter(Path[1]) then Exit(Path);
  {$ENDIF}
  Result := IncludeTrailingPathDelimiter(Current) + Path;
end;

function PathAttributes(const Name: string; out Attributes: Word): Boolean;
var F: File;
begin
  Assign(F, Name);
  DOS.GetFAttr(F, Attributes);
  Result := DosError = 0;
end;

function FileExists(const Name: string): Boolean;
var Attributes: Word;
begin
  Result := PathAttributes(Name, Attributes);
  if Result then Result := (Attributes and Directory) = 0;
end;

function DirectoryExists(const Name: string): Boolean;
var Attributes: Word;
begin
  Result := PathAttributes(Name, Attributes);
  if Result then Result := (Attributes and Directory) <> 0;
end;

function CreateDir(const Name: string): Boolean;
begin
  {$PUSH}{$I-}
  MkDir(Name);
  Result := IOResult = 0;
  {$POP}
end;

function RemoveDir(const Name: string): Boolean;
begin
  {$PUSH}{$I-}
  RmDir(Name);
  Result := IOResult = 0;
  {$POP}
end;

function DeleteFile(const Name: string): Boolean;
var F: File;
begin
  Assign(F, Name);
  {$PUSH}{$I-}
  Erase(F);
  Result := IOResult = 0;
  {$POP}
end;

function CreateWorkDir: string;
var Root: string; Attempt: Integer;
begin
  {$IFDEF MSWINDOWS}
  Root := DOS.GetEnv('TEMP');
  if Root = '' then Root := DOS.GetEnv('TMP');
  if Root = '' then GetDir(0, Root);
  {$ELSE}
  Root := DOS.GetEnv('TMPDIR');
  if Root = '' then Root := '/tmp';
  {$ENDIF}
  Root := IncludeTrailingPathDelimiter(ExpandFileName(Root));
  Randomize;
  for Attempt := 1 to 100 do
  begin
    Result := Root + 'wav2fra-' + IntToStr(Random(High(LongInt))) + '-' +
      IntToStr(Random(High(LongInt)));
    { MkDir est atomique: ne jamais reutiliser un dossier deja existant. }
    if CreateDir(Result) then Exit;
    if not FileExists(Result) and not DirectoryExists(Result) then Break;
  end;
  Fail('Creation du dossier temporaire impossible: ' + Root);
end;

function AudioDuration(SampleCount: Integer): string;
var Fraction: string;
begin
  { 1/16000 = 0.0000625: representation exacte, independante de la locale. }
  Fraction := IntToStr((SampleCount mod TargetRate) * 625);
  while Length(Fraction) < 7 do Fraction := '0' + Fraction;
  while (Length(Fraction) > 1) and (Fraction[Length(Fraction)] = '0') do
    SetLength(Fraction, Length(Fraction) - 1);
  Result := IntToStr(SampleCount div TargetRate) + '.' + Fraction;
end;

{ Fonctions numeriques locales: aucune dependance directe a l'unite Math.
  Abs, Sin, Cos, Pi, Round et Trunc sont fournis par l'unite System. }
function Min(A, B: Integer): Integer; overload;
begin
  if A < B then Result := A else Result := B;
end;

function Min(A, B: Double): Double; overload;
begin
  if A < B then Result := A else Result := B;
end;

function Max(A, B: Integer): Integer;
begin
  if A > B then Result := A else Result := B;
end;

function EnsureRange(Value, LowerBound, UpperBound: Double): Double;
begin
  if Value < LowerBound then Result := LowerBound
  else if Value > UpperBound then Result := UpperBound
  else Result := Value;
end;

{ Les appels du reechantillonneur portent sur des valeurs finies dont
  les arrondis sont representables en Int64. Trunc arrondit vers zero. }
function Floor(Value: Double): Int64;
begin
  Result := Trunc(Value);
  if Value < Result then Dec(Result);
end;

function Ceil(Value: Double): Int64;
begin
  Result := Trunc(Value);
  if Value > Result then Inc(Result);
end;

{ Inspection IEEE 754 binary32 sans operation flottante, y compris pour
  les NaN signalants. Ces fonctions servent aux echantillons WAV float32. }
function IsNan(const Value: Single): Boolean;
var Bits: LongWord;
begin
  Move(Value, Bits, SizeOf(Bits));
  Result := ((Bits and $7F800000) = $7F800000) and
    ((Bits and $007FFFFF) <> 0);
end;

function IsInfinite(const Value: Single): Boolean;
var Bits: LongWord;
begin
  Move(Value, Bits, SizeOf(Bits));
  Result := (Bits and $7FFFFFFF) = $7F800000;
end;

procedure Fail(const S: string);
var I, ErrorCode: Integer;
begin
  WriteLn(StdErr, 'WAV2FRA: ', S);
  { Fermer les fichiers encore ouverts avant de supprimer les temporaires.
    Les pointeurs concernent des records toujours presents sur la pile. }
  for I := 0 to High(OpenFiles) do
    if OpenFiles[I] <> nil then
    begin
      {$PUSH}{$I-}
      Close(OpenFiles[I]^.Handle); ErrorCode := IOResult;
      {$POP}
      if ErrorCode <> 0 then WriteLn(StdErr, 'Fermeture incomplete: ', OpenFiles[I]^.Name);
      OpenFiles[I] := nil;
    end;
  CleanupWork;
  Halt(1);
end;

procedure OpenBinary(var S: TBinary; const Name: string; Writing: Boolean);
var I, ErrorCode: Integer; OldMode: Byte;
begin
  S.Name := Name; S.Position := 0; S.Used := 0; S.Index := 0;
  S.Writing := Writing; S.Size := 0;
  Assign(S.Handle, Name);
  OldMode := FileMode; FileMode := $20; { lecture, partage sans ecriture }
  {$PUSH}{$I-}
  if Writing then Rewrite(S.Handle, 1) else Reset(S.Handle, 1);
  ErrorCode := IOResult;
  {$POP}
  FileMode := OldMode;
  if ErrorCode <> 0 then Fail('Ouverture impossible: ' + Name + ' (code ' + IntToStr(ErrorCode) + ')');
  I := 0;
  while (I <= High(OpenFiles)) and (OpenFiles[I] <> nil) do Inc(I);
  if I > High(OpenFiles) then
  begin
    {$PUSH}{$I-}Close(S.Handle); ErrorCode := IOResult;{$POP}
    Fail('Trop de fichiers ouverts.');
  end;
  OpenFiles[I] := @S;
  {$PUSH}{$I-}
  S.Size := FileSize(S.Handle); ErrorCode := IOResult;
  {$POP}
  if ErrorCode <> 0 then Fail('Taille inaccessible: ' + Name);
end;

procedure FlushBinary(var S: TBinary);
var Count, ErrorCode: LongInt;
begin
  if not S.Writing or (S.Used = 0) then Exit;
  {$PUSH}{$I-}
  BlockWrite(S.Handle, S.Buffer, S.Used, Count); ErrorCode := IOResult;
  {$POP}
  if (ErrorCode <> 0) or (Count <> S.Used) then Fail('Ecriture incomplete: ' + S.Name);
  S.Used := 0;
end;

procedure CloseBinary(var S: TBinary);
var I, ErrorCode: Integer;
begin
  FlushBinary(S);
  {$PUSH}{$I-}Close(S.Handle); ErrorCode := IOResult;{$POP}
  for I := 0 to High(OpenFiles) do
    if OpenFiles[I] = @S then OpenFiles[I] := nil;
  if ErrorCode <> 0 then Fail('Fermeture impossible: ' + S.Name);
end;

procedure ReadBytes(var S: TBinary; var Dest; Count: LongInt);
var P: PByte; N, ErrorCode: LongInt;
begin
  P := @Dest;
  while Count > 0 do
  begin
    if S.Index = S.Used then
    begin
      {$PUSH}{$I-}
      BlockRead(S.Handle, S.Buffer, SizeOf(S.Buffer), S.Used); ErrorCode := IOResult;
      {$POP}
      if (ErrorCode <> 0) or (S.Used = 0) then Fail('Lecture incomplete: ' + S.Name);
      S.Index := 0;
    end;
    N := Min(Count, S.Used - S.Index);
    Move(S.Buffer[S.Index], P^, N);
    Inc(P, N); Inc(S.Index, N); Inc(S.Position, N); Dec(Count, N);
  end;
end;

procedure WriteBytes(var S: TBinary; const Source; Count: LongInt);
var P: PByte; N: LongInt;
begin
  P := @Source;
  while Count > 0 do
  begin
    N := Min(Count, SizeOf(S.Buffer) - S.Used);
    Move(P^, S.Buffer[S.Used], N);
    Inc(P, N); Inc(S.Used, N); Inc(S.Position, N); Dec(Count, N);
    if S.Used = SizeOf(S.Buffer) then FlushBinary(S);
  end;
end;

procedure SeekBinary(var S: TBinary; Position: Int64);
var ErrorCode: Integer;
begin
  FlushBinary(S);
  {$PUSH}{$I-}Seek(S.Handle, Position); ErrorCode := IOResult;{$POP}
  if ErrorCode <> 0 then Fail('Position inaccessible: ' + S.Name);
  S.Position := Position; S.Index := 0; S.Used := 0;
end;

function LoadText(const Name: string): string;
var S: TBinary;
begin
  OpenBinary(S, Name, False);
  if S.Size > MaxInputBytes then Fail('Fichier texte trop grand: ' + Name);
  SetLength(Result, S.Size);
  if S.Size > 0 then ReadBytes(S, Result[1], S.Size);
  CloseBinary(S);
  { Le BOM UTF-8 eventuel n'est pas une partie du texte prononce. }
  if Copy(Result, 1, 3) = #$EF#$BB#$BF then Delete(Result, 1, 3);
end;

procedure SaveText(const Name, Text: string);
var S: TBinary;
begin
  OpenBinary(S, Name, True);
  if Text <> '' then WriteBytes(S, Text[1], Length(Text));
  CloseBinary(S);
end;

function U16(var S: TBinary): Word;
var B: array[0..1] of Byte;
begin
  ReadBytes(S, B, 2);
  Result := Word(B[0]) or (Word(B[1]) shl 8);
end;

function U32(var S: TBinary): LongWord;
var B: array[0..3] of Byte;
begin
  ReadBytes(S, B, 4);
  Result := LongWord(B[0]) or (LongWord(B[1]) shl 8) or
    (LongWord(B[2]) shl 16) or (LongWord(B[3]) shl 24);
end;

function FourCC(var S: TBinary): AnsiString;
begin
  SetLength(Result, 4);
  ReadBytes(S, Result[1], 4);
end;

procedure Put16(var S: TBinary; V: Word);
var B: array[0..1] of Byte;
begin
  B[0] := V and 255; B[1] := V shr 8;
  WriteBytes(S, B, 2);
end;

procedure Put32(var S: TBinary; V: LongWord);
begin
  Put16(S, V and 65535); Put16(S, V shr 16);
end;

procedure Tag(var S: TBinary; const V: AnsiString);
begin
  WriteBytes(S, V[1], 4);
end;

procedure ReadWave(const Name: string; out Samples: TSamples; out Rate: LongWord);
var
  S: TBinary;
  ID: string;
  ChunkSize, RiffSize, ByteRate, V: LongWord;
  Limit, ChunkEnd, DataPos, DataSize, Frames: Int64;
  Fmt, Channels, Bits, BlockSize: Word;
  HaveFmt, HaveData: Boolean;
  C, I: Integer;
  ThirdByte: Byte;
  SignedValue: Int64;
  X, Sum: Double;
  F: Single;
begin
  OpenBinary(S, Name, False);
    if (S.Size < 12) or (S.Size > MaxInputBytes) then
      Fail('WAV vide, trop court ou superieur a 256 Mio.');
    if FourCC(S) <> 'RIFF' then Fail('Seul RIFF WAV little-endian est accepte.');
    RiffSize := U32(S);
    if FourCC(S) <> 'WAVE' then Fail('Signature WAVE absente.');
    Limit := Int64(RiffSize) + 8;
    if (Limit > S.Size) or (Limit < 12) then Fail('Taille RIFF invalide.');
    HaveFmt := False; HaveData := False;
    Fmt := 0; Channels := 0; Bits := 0; BlockSize := 0; Rate := 0;
    DataPos := 0; DataSize := 0;
    while S.Position < Limit do
    begin
      if Limit - S.Position < 8 then Fail('Entete de chunk tronquee.');
      ID := FourCC(S); ChunkSize := U32(S);
      ChunkEnd := S.Position + Int64(ChunkSize);
      if ChunkEnd + (ChunkSize and 1) > Limit then Fail('Chunk WAV tronque.');
      if ID = 'fmt ' then
      begin
        if HaveFmt or (ChunkSize < 16) then Fail('Chunk fmt invalide ou repete.');
        Fmt := U16(S); Channels := U16(S); Rate := U32(S);
        ByteRate := U32(S); BlockSize := U16(S); Bits := U16(S);
        if not (Fmt in [1, 3]) then
          Fail('Encodage non pris en charge: utiliser PCM ou float IEEE WAV.');
        if (Channels < 1) or (Channels > 8) or (Rate < 8000) or (Rate > 192000) then
          Fail('Canaux (1..8) ou frequence (8000..192000) invalides.');
        if ((Fmt = 1) and not (Bits in [8,16,24,32])) or
           ((Fmt = 3) and (Bits <> 32)) then Fail('Resolution WAV non prise en charge.');
        if (BlockSize <> Channels * (Bits div 8)) or
           (ByteRate <> Rate * LongWord(BlockSize)) then Fail('Alignement PCM invalide.');
        HaveFmt := True;
      end
      else if ID = 'data' then
      begin
        if HaveData then Fail('Plusieurs chunks data non pris en charge.');
        DataPos := S.Position; DataSize := ChunkSize; HaveData := True;
      end;
      SeekBinary(S, ChunkEnd + (ChunkSize and 1));
    end;
    if not HaveFmt or not HaveData then Fail('Chunks fmt/data manquants.');
    if (DataSize = 0) or (DataSize mod BlockSize <> 0) then Fail('Donnees PCM incompletes.');
    Frames := DataSize div BlockSize;
    if Frames > Int64(Rate) * MaxSeconds then Fail('Duree maximale: 30 minutes.');
    SetLength(Samples, Frames);
    SeekBinary(S, DataPos);
    for I := 0 to Frames - 1 do
    begin
      Sum := 0;
      for C := 1 to Channels do
      begin
        V := 0;
        case Bits of
          8: ReadBytes(S, V, 1);
          16: V := U16(S);
          24: begin V := U16(S); ReadBytes(S, ThirdByte, 1);
                V := V or (LongWord(ThirdByte) shl 16); end;
          32: V := U32(S);
        end;
        if Fmt = 3 then
        begin
          Move(V, F, 4);
          if IsNan(F) or IsInfinite(F) then Fail('Echantillon float non fini.');
          X := F;
        end
        else if Bits = 8 then X := (Integer(V) - 128) / 128.0
        else
        begin
          SignedValue := V;
          if (QWord(V) and (QWord(1) shl (Bits - 1))) <> 0 then
            SignedValue := SignedValue - (Int64(1) shl Bits);
          X := SignedValue / (Int64(1) shl (Bits - 1));
        end;
        Sum := Sum + EnsureRange(X, -1.0, 1.0);
      end;
      Samples[I] := Sum / Channels;
    end;
  CloseBinary(S);
end;

procedure Resample(const Source: TSamples; Rate: LongWord; out Dest: TSamples);
var
  I, J, Center, Radius, Count: Integer;
  Position, Distance, Cutoff, Weight, Total, Norm, Angle: Double;
begin
  if Rate = TargetRate then begin Dest := Copy(Source); Exit; end;
  Count := (Int64(Length(Source)) * TargetRate + Rate - 1) div Rate;
  SetLength(Dest, Count);
  { Sinc fenetree Hann, filtre anti-repliement avant sous-echantillonnage.
    Le support augmente avec le rapport des frequences. }
  Cutoff := 0.94 * Min(1.0, TargetRate / Rate);
  Radius := Ceil(16 / Cutoff);
  for I := 0 to Count - 1 do
  begin
    Position := I * (Double(Rate) / TargetRate);
    Center := Floor(Position); Total := 0; Norm := 0;
    for J := Max(0, Center - Radius) to Min(High(Source), Center + Radius) do
    begin
      Distance := Position - J;
      if Abs(Distance) >= Radius then Continue;
      Angle := Pi * Distance * Cutoff;
      if Abs(Angle) < 1E-12 then Weight := Cutoff
      else Weight := Cutoff * Sin(Angle) / Angle;
      Weight := Weight * (0.5 + 0.5 * Cos(Pi * Distance / Radius));
      Total := Total + Source[J] * Weight; Norm := Norm + Weight;
    end;
    if Abs(Norm) > 1E-12 then Dest[I] := Total / Norm else Dest[I] := 0;
  end;
end;

procedure RemoveDC(var Samples: TSamples);
var I: Integer; PrevIn, PrevOut, X: Double;
begin
  { Passe-haut doux ~40 Hz; pas de gate qui supprimerait les consonnes.
    Le bruit restant est gere par VAD et le modele acoustique entraine. }
  PrevIn := 0; PrevOut := 0;
  for I := 0 to High(Samples) do
  begin
    X := Samples[I] - PrevIn + 0.9844 * PrevOut;
    PrevIn := Samples[I]; PrevOut := X;
    Samples[I] := EnsureRange(X, -1.0, 1.0);
  end;
end;

procedure WriteWave(const Name: string; const Samples: TSamples);
var S: TBinary; I, N: Integer; V: SmallInt;
begin
  OpenBinary(S, Name, True);
    N := Length(Samples) * 2;
    Tag(S, 'RIFF'); Put32(S, N + 36); Tag(S, 'WAVE');
    Tag(S, 'fmt '); Put32(S, 16); Put16(S, 1); Put16(S, 1);
    Put32(S, TargetRate); Put32(S, TargetRate * 2);
    Put16(S, 2); Put16(S, 16); Tag(S, 'data'); Put32(S, N);
    for I := 0 to High(Samples) do
    begin
      V := Round(EnsureRange(Samples[I], -1.0, 1.0) * 32767);
      Put16(S, Word(V));
    end;
  CloseBinary(S);
end;

{$IFDEF MSWINDOWS}
function QuoteArgument(const S: string): string;
var I, J, Slashes: Integer;
begin
  { Convention argv Windows: doubler les antislashs precedant un guillemet
    ou le guillemet final. Aucun interpreteur de commandes n'est utilise. }
  Result := '"'; Slashes := 0;
  for I := 1 to Length(S) do
    if S[I] = '\' then Inc(Slashes)
    else
    begin
      if S[I] = '"' then
      begin
        for J := 1 to Slashes * 2 + 1 do Result := Result + '\';
      end
      else for J := 1 to Slashes do Result := Result + '\';
      Result := Result + S[I]; Slashes := 0;
    end;
  for J := 1 to Slashes * 2 do Result := Result + '\';
  Result := Result + '"';
end;

procedure RunTool(const Exe: string; const Args: array of string);
var
  SI: TStartupInfo; PI: TProcessInformation; SA: TSecurityAttributes;
  ReadPipe, WritePipe, NullInput: THandle;
  Command, Executable, Log: string;
  PathBuffer: array[0..32767] of Char;
  Buffer: array[0..4095] of Byte;
  Count, Status, ErrorCode: DWORD;
  I: Integer;

  procedure CloseHandles;
  begin
    if ReadPipe <> 0 then CloseHandle(ReadPipe);
    if WritePipe <> 0 then CloseHandle(WritePipe);
    if NullInput <> INVALID_HANDLE_VALUE then CloseHandle(NullInput);
    if PI.hThread <> 0 then CloseHandle(PI.hThread);
    if PI.hProcess <> 0 then CloseHandle(PI.hProcess);
  end;

  procedure LaunchError(const Detail: string; Code: DWORD);
  begin
    CloseHandles;
    Fail(Exe + ': ' + Detail + ' (code ' + IntToStr(Code) + ')');
  end;

begin
  FillChar(SI, SizeOf(SI), 0); FillChar(PI, SizeOf(PI), 0);
  ReadPipe := 0; WritePipe := 0; NullInput := INVALID_HANDLE_VALUE;
  Count := SearchPath(nil, PChar(Exe), '.exe', Length(PathBuffer), @PathBuffer[0], nil);
  if (Count = 0) or (Count >= DWORD(Length(PathBuffer))) then
    LaunchError('executable introuvable', GetLastError);
  Executable := PChar(@PathBuffer[0]);
  Command := QuoteArgument(Executable);
  for I := 0 to High(Args) do Command := Command + ' ' + QuoteArgument(Args[I]);
  if Length(Command) >= 32767 then LaunchError('ligne de commande trop longue', 87);
  FillChar(SA, SizeOf(SA), 0); SA.nLength := SizeOf(SA); SA.bInheritHandle := True;
  if not CreatePipe(ReadPipe, WritePipe, @SA, 0) then LaunchError('creation du pipe impossible', GetLastError);
  if not SetHandleInformation(ReadPipe, HANDLE_FLAG_INHERIT, 0) then
    LaunchError('configuration du pipe impossible', GetLastError);
  NullInput := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE,
    @SA, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if NullInput = INVALID_HANDLE_VALUE then LaunchError('ouverture NUL impossible', GetLastError);
  SI.cb := SizeOf(SI); SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput := NullInput; SI.hStdOutput := WritePipe; SI.hStdError := WritePipe;
  if not CreateProcess(PChar(Executable), PChar(Command), nil, nil, True,
    CREATE_NO_WINDOW, nil, nil, SI, PI) then LaunchError('lancement impossible', GetLastError);
  CloseHandle(WritePipe); WritePipe := 0;
  CloseHandle(NullInput); NullInput := INVALID_HANDLE_VALUE;
  repeat
    if not ReadFile(ReadPipe, Buffer, SizeOf(Buffer), Count, nil) then
    begin
      ErrorCode := GetLastError;
      if ErrorCode <> ERROR_BROKEN_PIPE then
      begin
        TerminateProcess(PI.hProcess, 1);
        WaitForSingleObject(PI.hProcess, INFINITE);
        LaunchError('lecture des diagnostics impossible', ErrorCode);
      end;
      Break;
    end;
    if Count = 0 then Break;
    SetString(Log, PChar(@Buffer[0]), Count); Write(StdErr, Log);
  until False;
  if WaitForSingleObject(PI.hProcess, INFINITE) = WAIT_FAILED then
    LaunchError('attente du moteur impossible', GetLastError);
  if not GetExitCodeProcess(PI.hProcess, Status) then LaunchError('code de retour inaccessible', GetLastError);
  CloseHandles;
  if Status <> 0 then Fail(Exe + ': echec, code ' + IntToStr(Status));
end;
{$ELSE}
function FindExecutable(const Name: string): string;
var Paths, Part: string; I: Integer;
begin
  if Pos('/', Name) > 0 then Exit(ExpandFileName(Name));
  Paths := DOS.GetEnv('PATH');
  repeat
    I := Pos(':', Paths);
    if I = 0 then Part := Paths else Part := Copy(Paths, 1, I - 1);
    if Part = '' then Part := '.';
    Result := IncludeTrailingPathDelimiter(Part) + Name;
    if FileExists(Result) and (fpAccess(PChar(Result), X_OK) = 0) then Exit;
    if I = 0 then Break;
    Delete(Paths, 1, I);
  until False;
  Fail('Executable introuvable: ' + Name);
end;

procedure RunTool(const Exe: string; const Args: array of string);
var
  Pipes: array[0..1] of cint;
  PID, WaitResult: TPid;
  NullInput, Status, I: cint;
  N: Int64;
  Buffer: array[0..4095] of Byte;
  Executable, Log: string;
  Arguments: array of PChar;
begin
  Executable := FindExecutable(Exe);
  SetLength(Arguments, Length(Args) + 2);
  Arguments[0] := PChar(Executable);
  for I := 0 to High(Args) do Arguments[I + 1] := PChar(Args[I]);
  Arguments[High(Arguments)] := nil;
  if fpPipe(Pipes) <> 0 then Fail('Creation du pipe impossible: ' + Exe);
  PID := fpFork;
  if PID < 0 then
  begin
    fpClose(Pipes[0]); fpClose(Pipes[1]); Fail('Creation du processus impossible: ' + Exe);
  end;
  if PID = 0 then
  begin
    fpClose(Pipes[0]);
    NullInput := fpOpen('/dev/null', O_RDONLY);
    if (NullInput < 0) or (fpDup2(NullInput, 0) < 0) or
       (fpDup2(Pipes[1], 1) < 0) or (fpDup2(Pipes[1], 2) < 0) then fpExit(126);
    if NullInput > 2 then fpClose(NullInput);
    if Pipes[1] > 2 then fpClose(Pipes[1]);
    fpExecV(PChar(Executable), @Arguments[0]);
    fpExit(127);
  end;
  fpClose(Pipes[1]);
  repeat
    N := fpRead(Pipes[0], Buffer, SizeOf(Buffer));
    if (N < 0) and (fpGetErrNo = ESysEINTR) then Continue;
    if N <= 0 then Break;
    SetString(Log, PChar(@Buffer[0]), N); Write(StdErr, Log);
  until False;
  fpClose(Pipes[0]);
  repeat
    WaitResult := fpWaitPid(PID, @Status, 0);
  until (WaitResult >= 0) or (fpGetErrNo <> ESysEINTR);
  if (N < 0) or (WaitResult < 0) then Fail('Lecture/attente du moteur impossible: ' + Exe);
  if Status <> 0 then Fail(Exe + ': echec, statut POSIX ' + IntToStr(Status));
end;
{$ENDIF}

procedure Help;
begin
  WriteLn('WAV2FRA - transcription francaise locale (Free Pascal)');
  WriteLn('WAV2FRA entree.wav --model modele.bin --vad-model silero.bin [options]');
  WriteLn('  --output PREFIXE     Sorties PREFIXE.txt/.json/.TextGrid');
  WriteLn('  --whisper EXE        whisper-cli (defaut)');
  WriteLn('  --mfa EXE            mfa (defaut), MFA 3.x avec align_one');
  WriteLn('  --dictionary NOM     french_mfa (defaut), ou chemin dictionnaire');
  WriteLn('  --acoustic NOM       french_mfa (defaut), ou modele MFA .zip');
  WriteLn('  --text-only          Sans alignement mots/phonemes, ni dependance MFA');
  WriteLn('  --prepare-only       Conversion seule vers PREFIXE.wav, sans modeles');
  WriteLn('  --help               Cette aide');
  WriteLn('Les modeles multilingues Whisper, Silero et MFA doivent etre installes.');
  WriteLn('Pas de lecture haut-parleur; le fichier est analyse. Sorties UTF-8.');
  WriteLn('PCM 8/16/24/32 bits, float32; 1..8 canaux; 8..192 kHz; 256 Mio/30 min max.');
end;

procedure Parse(out O: TOptions);
var I: Integer; K, V: string;
begin
  O.Input := ''; O.Output := ''; O.Model := ''; O.VADModel := '';
  O.Whisper := 'whisper-cli'; O.MFA := 'mfa';
  O.Dictionary := 'french_mfa'; O.Acoustic := 'french_mfa';
  O.PrepareOnly := False; O.TextOnly := False;
  I := 1;
  while I <= ParamCount do
  begin
    K := ParamStr(I);
    if K = '--prepare-only' then O.PrepareOnly := True
    else if K = '--text-only' then O.TextOnly := True
    else if Copy(K, 1, 2) = '--' then
    begin
      if not ((K = '--output') or (K = '--model') or (K = '--vad-model') or
        (K = '--whisper') or (K = '--mfa') or (K = '--dictionary') or
        (K = '--acoustic')) then Fail('Option inconnue: ' + K);
      Inc(I); if I > ParamCount then Fail('Valeur manquante: ' + K);
      V := ParamStr(I); if V = '' then Fail('Valeur vide: ' + K);
      if K = '--output' then O.Output := V
      else if K = '--model' then O.Model := V
      else if K = '--vad-model' then O.VADModel := V
      else if K = '--whisper' then O.Whisper := V
      else if K = '--mfa' then O.MFA := V
      else if K = '--dictionary' then O.Dictionary := V
      else if K = '--acoustic' then O.Acoustic := V;
    end
    else if O.Input = '' then O.Input := K
    else Fail('Argument inattendu: ' + K);
    Inc(I);
  end;
  if O.Input = '' then Fail('Fichier WAV requis; utiliser --help.');
  O.Input := ExpandFileName(O.Input);
  if O.Output = '' then O.Output := ChangeFileExt(O.Input, '') + '.fra';
  O.Output := ExpandFileName(O.Output);
  if not DirectoryExists(ExtractFileDir(O.Output)) then Fail('Dossier de sortie absent.');
  if not O.PrepareOnly then
  begin
    if not FileExists(O.Model) then Fail('--model: fichier Whisper multilingue requis.');
    if Pos('.en', LowerCase(ExtractFileName(O.Model))) > 0 then
      Fail('Un modele Whisper anglais .en ne reconnait pas le francais.');
    if not FileExists(O.VADModel) then Fail('--vad-model: fichier Silero requis.');
  end;
end;

procedure MustBeNew(const Name: string);
begin
  if FileExists(Name) or DirectoryExists(Name) then Fail('Sortie deja existante: ' + Name);
end;

procedure CopyNew(const Source, Dest: string);
var A, B: TBinary; Buffer: array[0..8191] of Byte; Count: Integer;
begin
  MustBeNew(Dest);
  OpenBinary(A, Source, False); OpenBinary(B, Dest, True);
  while A.Position < A.Size do
  begin
    Count := SizeOf(Buffer);
    if A.Size - A.Position < Count then Count := A.Size - A.Position;
    ReadBytes(A, Buffer, Count); WriteBytes(B, Buffer, Count);
  end;
  CloseBinary(B); CloseBinary(A);
end;

procedure CleanupWork;
var Prefix: string;
begin
  if WorkDirectory = '' then Exit;
  Prefix := WorkDirectory + DirectorySeparator;
  { Ne supprimer que les fichiers connus; les diagnostics MFA sont conserves. }
  DeleteFile(Prefix + 'audio.wav'); DeleteFile(Prefix + 'transcript.txt');
  DeleteFile(Prefix + 'transcript.json'); DeleteFile(Prefix + 'phones.TextGrid');
  if not RemoveDir(WorkDirectory) then WriteLn(StdErr, 'Diagnostics conserves: ', WorkDirectory);
  WorkDirectory := '';
end;

procedure Transcribe(const O: TOptions; const Audio: TSamples);
var Work, Wav, Prefix, Grid, Txt, GridText: string;
begin
  MustBeNew(O.Output + '.txt'); MustBeNew(O.Output + '.json');
  if not O.TextOnly then MustBeNew(O.Output + '.TextGrid');
  Work := CreateWorkDir;
  WorkDirectory := Work;
  Wav := Work + DirectorySeparator + 'audio.wav';
  Prefix := Work + DirectorySeparator + 'transcript';
  Grid := Work + DirectorySeparator + 'phones.TextGrid';
    WriteWave(Wav, Audio);
    WriteLn(StdErr, 'Detection Silero et reconnaissance Whisper en francais...');
    RunTool(O.Whisper, ['-m', ExpandFileName(O.Model), '-f', Wav, '-l', 'fr',
      '--vad', '-vm', ExpandFileName(O.VADModel), '-otxt', '-oj', '-of', Prefix]);
    if not FileExists(Prefix + '.txt') or not FileExists(Prefix + '.json') then
      Fail('Whisper n''a pas produit les fichiers TXT et JSON attendus.');
      Txt := Trim(LoadText(Prefix + '.txt'));
      if not O.TextOnly then
      begin
        if Txt <> '' then
        begin
          WriteLn(StdErr, 'Alignement acoustique des mots et phonemes (MFA)...');
          RunTool(O.MFA, ['align_one', Wav, Prefix + '.txt', O.Dictionary,
            O.Acoustic, Grid, '--temporary_directory', Work + DirectorySeparator + 'mfa']);
          if not FileExists(Grid) then Fail('MFA n''a pas produit de TextGrid.');
        end
        else
        begin
          { Aucune parole: grille valide sans intervalles, pas de texte invente. }
          GridText := 'File type = "ooTextFile"' + LineEnding +
            'Object class = "TextGrid"' + LineEnding + LineEnding +
            'xmin = 0' + LineEnding + 'xmax = ' + AudioDuration(Length(Audio)) + LineEnding +
            'tiers? <exists>' + LineEnding + 'size = 0' + LineEnding + 'item []:' + LineEnding;
          SaveText(Grid, GridText);
        end;
      end;
      CopyNew(Prefix + '.txt', O.Output + '.txt');
      CopyNew(Prefix + '.json', O.Output + '.json');
      if not O.TextOnly then CopyNew(Grid, O.Output + '.TextGrid');
      WriteLn(Txt);
      WriteLn(StdErr, 'Transcription UTF-8: ', O.Output + '.txt');
  CleanupWork;
end;

var O: TOptions; Source, Audio: TSamples; Rate: LongWord; I: Integer;
begin
    InitializeArguments;
    for I := 1 to ParamCount do
      if ParamStr(I) = '--help' then begin Help; Halt(0); end;
    if ParamCount = 0 then begin Help; Halt(1); end;
    Parse(O);
    ReadWave(O.Input, Source, Rate);
    WriteLn(StdErr, 'Lecture WAV: ', Length(Source), ' trames, ', Rate, ' Hz.');
    Resample(Source, Rate, Audio); SetLength(Source, 0);
    RemoveDC(Audio);
    if O.PrepareOnly then
    begin
      MustBeNew(O.Output + '.wav'); WriteWave(O.Output + '.wav', Audio);
      WriteLn('WAV mono PCM16 / 16000 Hz: ', O.Output + '.wav');
    end
    else Transcribe(O, Audio);
end.
