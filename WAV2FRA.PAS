Program WAV2FRA;
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

Uses DOS
{$IFDEF MSWINDOWS}
 , Windows
{$ELSE}
 , BaseUnix, Unix
{$ENDIF}
;

Type
  { Fichier binaire tamponne, manipule uniquement par des procedures. }
 TBinary = record
 Handle: File;
 Name: string;
 Size, Position: Int64;
 Buffer: array[0..8191] of Byte;
 Used, Index: LongInt;
 Writing: Boolean;
End;
PBinary = ^TBinary;
TSamples = array of Single;
TOptions = record
Input, Output, Model, VADModel, Whisper, MFA, Dictionary, Acoustic: string;
PrepareOnly, TextOnly: Boolean;
End;

Const
 TargetRate = 16000;
 MaxInputBytes = 268435456;
 { limite explicite: 256 Mio }
 MaxSeconds = 1800;

Var
 OpenFiles: array[0..7] of PBinary;
 WorkDirectory: string;
 CommandArguments: array of string;
Procedure Fail(const S: string);Forward;
Procedure CleanupWork;Forward;
{$IFDEF MSWINDOWS}

 Type
  TWideArguments = array[0..65535] of PWideChar;
  PWideArguments = ^TWideArguments;

 Function DecodeCommandLine(Command: PWideChar; var Count: LongInt): PWideArguments;
 stdcall; external 'shell32.dll' name 'CommandLineToArgvW';
{$ENDIF}

Procedure InitializeArguments;
Var
 I, Count: LongInt;
 {$IFDEF MSWINDOWS}
  Values: PWideArguments;
  Size: LongInt;
 {$ENDIF}
Begin
 {$IFDEF MSWINDOWS}
  { Le ParamStr Win32 de FPC 3.2 ne decode pas les antislashs et guillemets
    comme les moteurs C/C++. Decoder aussi l'entree selon la convention OS. }
  Values := DecodeCommandLine(GetCommandLineW, Count);
  if Values = nil Then Fail('Lecture de la ligne de commande impossible.');
  SetLength(CommandArguments, Count);
  For I := 0 to Count - 1 do Begin
   Size := WideCharToMultiByte(CP_ACP, 0, Values^[I], -1, nil, 0, nil, nil);
   if Size = 0 Then Begin
    LocalFree(HLOCAL(Values)); Fail('Conversion d''argument impossible.');
   End;
   SetLength(CommandArguments[I], Size);
   WideCharToMultiByte(CP_ACP, 0, Values^[I], -1, PChar(CommandArguments[I]), Size, nil,
   nil);
   SetLength(CommandArguments[I], Size - 1);
  End;
  LocalFree(HLOCAL(Values));
 {$ELSE}
  Count := System.ParamCount + 1;
  SetLength(CommandArguments, Count);
  For I := 0 to Count - 1 do CommandArguments[I] := System.ParamStr(I);
 {$ENDIF}
End;

Function ParamCount: Integer;Begin
 Result := Length(CommandArguments) - 1;
End;

Function ParamStr(Index: Integer): string;Begin
 if (Index >= 0) and (Index < Length(CommandArguments)) Then Result :=
 CommandArguments[Index]
 else Result := '';
End;
{ Services proceduraux locaux, sans Classes, SysUtils ni Process. }

Function IntToStr(Value: Int64): string;Begin
 Str(Value, Result);
End;

Function Trim(const Text: string): string;
Var
 First, Last: Integer;
Begin
 First := 1; Last := Length(Text);
 While (First <= Last) and (Text[First] <= ' ') do Inc(First);
 While (Last >= First) and (Text[Last] <= ' ') do Dec(Last);
 Result := Copy(Text, First, Last - First + 1);
End;

Function LowerCase(const Text: string): string;
Var
 I: Integer;
Begin
  { Seul le suffixe ASCII des noms de modeles est compare. }
 Result := Text;
 For I := 1 to Length(Result) do    if Result[I] in ['A'..'Z'] Then Result[I] := Chr(Ord(
 Result[I]) + 32);
End;

Function IsPathDelimiter(C: Char): Boolean;Begin
 {$IFDEF MSWINDOWS}
  Result := C in ['/', '\'];
 {$ELSE}
  Result := C = '/';
 {$ENDIF}
End;

Function IncludeTrailingPathDelimiter(const Path: string): string;Begin
 Result := Path;
 if (Result = '') or not IsPathDelimiter(Result[Length(Result)]) Then    Result :=
 Result + DirectorySeparator;
End;

Function ExtractFileName(const Path: string): string;
Var
 I: Integer;
Begin
 I := Length(Path);
 While (I > 0) and not IsPathDelimiter(Path[I]) do Dec(I);
 Result := Copy(Path, I + 1, Length(Path) - I);
End;

Function ExtractFileDir(const Path: string): string;
Var
 I: Integer;
Begin
 I := Length(Path);
 While (I > 0) and not IsPathDelimiter(Path[I]) do Dec(I);
  { Conserver le separateur des racines / et C:\. }
 if (I = 1)
 {$IFDEF MSWINDOWS}
  or ((I = 3) and (Path[2] = ':'))
 {$ENDIF}
 Then    Result := Copy(Path, 1, I)
 else if I > 0 Then Result := Copy(Path, 1, I - 1)
 else Result := '';
End;

Function ChangeFileExt(const Path, Extension: string): string;
Var
 I: Integer;
Begin
 I := Length(Path);
 While (I > 0) and not IsPathDelimiter(Path[I]) and (Path[I] <> '.') do Dec(I);
 if (I > 0) and (Path[I] = '.') Then Result := Copy(Path, 1, I - 1) + Extension
 else Result := Path + Extension;
End;

Function ExpandFileName(const Path: string): string;
Var
 Current: string;
Begin
  { Construire un chemin absolu sans limite ShortString. Les composants
    . et .. restent resolves par le systeme de fichiers. }
 GetDir(0, Current);
 {$IFDEF MSWINDOWS}
  if (Length(Path) >= 2) and (Path[2] = ':') Then Begin
   if (Length(Path) >= 3) and IsPathDelimiter(Path[3]) Then Exit(Path);
   if UpCase(Path[1]) in ['A'..'Z'] Then      GetDir(Ord(UpCase(Path[1])) - Ord('A') + 1,
   Current);
   Exit(IncludeTrailingPathDelimiter(Current) + Copy(Path, 3, Length(Path)));
  End;
  if (Length(Path) >= 2) and IsPathDelimiter(Path[1]) and IsPathDelimiter(Path[2])
  Then    Exit(Path);
  if (Path <> '') and IsPathDelimiter(Path[1]) Then Exit(Copy(Current, 1, 2) + Path);
 {$ELSE}
  if (Path <> '') and IsPathDelimiter(Path[1]) Then Exit(Path);
 {$ENDIF}
 Result := IncludeTrailingPathDelimiter(Current) + Path;
End;

Function PathAttributes(const Name: string; out Attributes: Word): Boolean;
Var
 F: File;
Begin
 Assign(F, Name);
 DOS.GetFAttr(F, Attributes);
 Result := DosError = 0;
End;

Function FileExists(const Name: string): Boolean;
Var
 Attributes: Word;
Begin
 Result := PathAttributes(Name, Attributes);
 if Result Then Result := (Attributes and Directory) = 0;
End;

Function DirectoryExists(const Name: string): Boolean;
Var
 Attributes: Word;
Begin
 Result := PathAttributes(Name, Attributes);
 if Result Then Result := (Attributes and Directory) <> 0;
End;

Function CreateDir(const Name: string): Boolean;Begin
  {$PUSH}{$I-}
 MkDir(Name);
 Result := IOResult = 0;
  {$POP}
End;

Function RemoveDir(const Name: string): Boolean;Begin
  {$PUSH}{$I-}
 RmDir(Name);
 Result := IOResult = 0;
  {$POP}
End;

Function DeleteFile(const Name: string): Boolean;
Var
 F: File;
Begin
 Assign(F, Name);
  {$PUSH}{$I-}
 Erase(F);
 Result := IOResult = 0;
  {$POP}
End;

Function CreateWorkDir: string;
Var
 Root: string;
 Attempt: Integer;
Begin
 {$IFDEF MSWINDOWS}
  Root := DOS.GetEnv('TEMP');
  if Root = '' Then Root := DOS.GetEnv('TMP');
  if Root = '' Then GetDir(0, Root);
 {$ELSE}
  Root := DOS.GetEnv('TMPDIR');
  if Root = '' Then Root := '/tmp';
 {$ENDIF}
 Root := IncludeTrailingPathDelimiter(ExpandFileName(Root));
 Randomize;
 For Attempt := 1 to 100 do Begin
  Result := Root + 'wav2fra-' + IntToStr(Random(High(LongInt))) + '-' +
  IntToStr(Random(High(LongInt)));
    { MkDir est atomique: ne jamais reutiliser un dossier deja existant. }
  if CreateDir(Result) Then Exit;
  if not FileExists(Result) and not DirectoryExists(Result) Then Break;
 End;
 Fail('Creation du dossier temporaire impossible: ' + Root);
End;

Function AudioDuration(SampleCount: Integer): string;
Var
 Fraction: string;
Begin
  { 1/16000 = 0.0000625: representation exacte, independante de la locale. }
 Fraction := IntToStr((SampleCount mod TargetRate) * 625);
 While Length(Fraction) < 7 do Fraction := '0' + Fraction;
 While (Length(Fraction) > 1) and (Fraction[Length(Fraction)] = '0') do    SetLength(
 Fraction, Length(Fraction) - 1);
 Result := IntToStr(SampleCount div TargetRate) + '.' + Fraction;
End;
{ Fonctions numeriques locales: aucune dependance directe a l'unite Math.
  Abs, Sin, Cos, Pi, Round et Trunc sont fournis par l'unite System. }

Function Min(A, B: Integer): Integer;
overload;
Begin
 if A < B Then Result := A else Result := B;
End;

Function Min(A, B: Double): Double;
overload;
Begin
 if A < B Then Result := A else Result := B;
End;

Function Max(A, B: Integer): Integer;Begin
 if A > B Then Result := A else Result := B;
End;

Function EnsureRange(Value, LowerBound, UpperBound: Double): Double;Begin
 if Value < LowerBound Then Result := LowerBound
 else if Value > UpperBound Then Result := UpperBound
 else Result := Value;
End;
{ Les appels du reechantillonneur portent sur des valeurs finies dont
  les arrondis sont representables en Int64. Trunc arrondit vers zero. }

Function Floor(Value: Double): Int64;Begin
 Result := Trunc(Value);
 if Value < Result Then Dec(Result);
End;

Function Ceil(Value: Double): Int64;Begin
 Result := Trunc(Value);
 if Value > Result Then Inc(Result);
End;
{ Inspection IEEE 754 binary32 sans operation flottante, y compris pour
  les NaN signalants. Ces fonctions servent aux echantillons WAV float32. }

Function IsNan(const Value: Single): Boolean;
Var
 Bits: LongWord;
Begin
 Move(Value, Bits, SizeOf(Bits));
 Result := ((Bits and $7F800000) = $7F800000) and
 ((Bits and $007FFFFF) <> 0);
End;

Function IsInfinite(const Value: Single): Boolean;
Var
 Bits: LongWord;
Begin
 Move(Value, Bits, SizeOf(Bits));
 Result := (Bits and $7FFFFFFF) = $7F800000;
End;

Procedure Fail(const S: string);
Var
 I, ErrorCode: Integer;
Begin
 WriteLn(StdErr, 'WAV2FRA: ', S);
  { Fermer les fichiers encore ouverts avant de supprimer les temporaires.
    Les pointeurs concernent des records toujours presents sur la pile. }
 For I := 0 to High(OpenFiles) do    if OpenFiles[I] <> nil Then Begin
      {$PUSH}{$I-}
  Close(OpenFiles[I]^.Handle); ErrorCode := IOResult;
      {$POP}
  if ErrorCode <> 0 Then WriteLn(StdErr, 'Fermeture incomplete: ', OpenFiles[I]^.Name);
  OpenFiles[I] := nil;
 End;
 CleanupWork;
 Halt(1);
End;

Procedure OpenBinary(var S: TBinary; const Name: string; Writing: Boolean);
Var
 I, ErrorCode: Integer;
 OldMode: Byte;
Begin
 S.Name := Name; S.Position := 0; S.Used := 0; S.Index := 0;
 S.Writing := Writing; S.Size := 0;
 Assign(S.Handle, Name);
 OldMode := FileMode; FileMode := $20; { lecture, partage sans ecriture }
  {$PUSH}{$I-}
 if Writing Then Rewrite(S.Handle, 1) else Reset(S.Handle, 1);
 ErrorCode := IOResult;
  {$POP}
 FileMode := OldMode;
 if ErrorCode <> 0 Then Fail('Ouverture impossible: ' + Name + ' (code ' + IntToStr(
 ErrorCode) + ')');
 I := 0;
 While (I <= High(OpenFiles)) and (OpenFiles[I] <> nil) do Inc(I);
 if I > High(OpenFiles) Then Begin
    {$PUSH}{$I-}Close(S.Handle); ErrorCode := IOResult;{$POP}
  Fail('Trop de fichiers ouverts.');
 End;
 OpenFiles[I] := @S;
  {$PUSH}{$I-}
 S.Size := FileSize(S.Handle); ErrorCode := IOResult;
  {$POP}
 if ErrorCode <> 0 Then Fail('Taille inaccessible: ' + Name);
End;

Procedure FlushBinary(var S: TBinary);
Var
 Count, ErrorCode: LongInt;
Begin
 if not S.Writing or (S.Used = 0) Then Exit;
  {$PUSH}{$I-}
 BlockWrite(S.Handle, S.Buffer, S.Used, Count); ErrorCode := IOResult;
  {$POP}
 if (ErrorCode <> 0) or (Count <> S.Used) Then Fail('Ecriture incomplete: ' + S.Name);
 S.Used := 0;
End;

Procedure CloseBinary(var S: TBinary);
Var
 I, ErrorCode: Integer;
Begin
 FlushBinary(S);
  {$PUSH}{$I-}Close(S.Handle); ErrorCode := IOResult;{$POP}
 For I := 0 to High(OpenFiles) do    if OpenFiles[I] = @S Then OpenFiles[I] := nil;
 if ErrorCode <> 0 Then Fail('Fermeture impossible: ' + S.Name);
End;

Procedure ReadBytes(var S: TBinary; var Dest; Count: LongInt);
Var
 P: PByte;
 N, ErrorCode: LongInt;
Begin
 P := @Dest;
 While Count > 0 do Begin
  if S.Index = S.Used Then Begin
      {$PUSH}{$I-}
   BlockRead(S.Handle, S.Buffer, SizeOf(S.Buffer), S.Used); ErrorCode := IOResult;
      {$POP}
   if (ErrorCode <> 0) or (S.Used = 0) Then Fail('Lecture incomplete: ' + S.Name);
   S.Index := 0;
  End;
  N := Min(Count, S.Used - S.Index);
  Move(S.Buffer[S.Index], P^, N);
  Inc(P, N); Inc(S.Index, N); Inc(S.Position, N); Dec(Count, N);
 End;
End;

Procedure WriteBytes(var S: TBinary; const Source; Count: LongInt);
Var
 P: PByte;
 N: LongInt;
Begin
 P := @Source;
 While Count > 0 do Begin
  N := Min(Count, SizeOf(S.Buffer) - S.Used);
  Move(P^, S.Buffer[S.Used], N);
  Inc(P, N); Inc(S.Used, N); Inc(S.Position, N); Dec(Count, N);
  if S.Used = SizeOf(S.Buffer) Then FlushBinary(S);
 End;
End;

Procedure SeekBinary(var S: TBinary; Position: Int64);
Var
 ErrorCode: Integer;
Begin
 FlushBinary(S);
  {$PUSH}{$I-}Seek(S.Handle, Position); ErrorCode := IOResult;{$POP}
 if ErrorCode <> 0 Then Fail('Position inaccessible: ' + S.Name);
 S.Position := Position; S.Index := 0; S.Used := 0;
End;

Function LoadText(const Name: string): string;
Var
 S: TBinary;
Begin
 OpenBinary(S, Name, False);
 if S.Size > MaxInputBytes Then Fail('Fichier texte trop grand: ' + Name);
 SetLength(Result, S.Size);
 if S.Size > 0 Then ReadBytes(S, Result[1], S.Size);
 CloseBinary(S);
  { Le BOM UTF-8 eventuel n'est pas une partie du texte prononce. }
 if Copy(Result, 1, 3) = #$EF#$BB#$BF Then Delete(Result, 1, 3);
End;

Procedure SaveText(const Name, Text: string);
Var
 S: TBinary;
Begin
 OpenBinary(S, Name, True);
 if Text <> '' Then WriteBytes(S, Text[1], Length(Text));
 CloseBinary(S);
End;

Function U16(var S: TBinary): Word;
Var
 B: array[0..1] of Byte;
Begin
 ReadBytes(S, B, 2);
 Result := Word(B[0]) or (Word(B[1]) shl 8);
End;

Function U32(var S: TBinary): LongWord;
Var
 B: array[0..3] of Byte;
Begin
 ReadBytes(S, B, 4);
 Result := LongWord(B[0]) or (LongWord(B[1]) shl 8) or
 (LongWord(B[2]) shl 16) or (LongWord(B[3]) shl 24);
End;

Function FourCC(var S: TBinary): AnsiString;Begin
 SetLength(Result, 4);
 ReadBytes(S, Result[1], 4);
End;

Procedure Put16(var S: TBinary; V: Word);
Var
 B: array[0..1] of Byte;
Begin
 B[0] := V and 255; B[1] := V shr 8;
 WriteBytes(S, B, 2);
End;

Procedure Put32(var S: TBinary; V: LongWord);Begin
 Put16(S, V and 65535); Put16(S, V shr 16);
End;

Procedure Tag(var S: TBinary; const V: AnsiString);Begin
 WriteBytes(S, V[1], 4);
End;

Procedure ReadWave(const Name: string; out Samples: TSamples; out Rate: LongWord);
Var
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
Begin
 OpenBinary(S, Name, False);
 if (S.Size < 12) or (S.Size > MaxInputBytes) Then      Fail(
 'WAV vide, trop court ou superieur a 256 Mio.');
 if FourCC(S) <> 'RIFF' Then Fail('Seul RIFF WAV little-endian est accepte.');
 RiffSize := U32(S);
 if FourCC(S) <> 'WAVE' Then Fail('Signature WAVE absente.');
 Limit := Int64(RiffSize) + 8;
 if (Limit > S.Size) or (Limit < 12) Then Fail('Taille RIFF invalide.');
 HaveFmt := False; HaveData := False;
 Fmt := 0; Channels := 0; Bits := 0; BlockSize := 0; Rate := 0;
 DataPos := 0; DataSize := 0;
 While S.Position < Limit do Begin
  if Limit - S.Position < 8 Then Fail('Entete de chunk tronquee.');
  ID := FourCC(S); ChunkSize := U32(S);
  ChunkEnd := S.Position + Int64(ChunkSize);
  if ChunkEnd + (ChunkSize and 1) > Limit Then Fail('Chunk WAV tronque.');
  if ID = 'fmt ' Then Begin
   if HaveFmt or (ChunkSize < 16) Then Fail('Chunk fmt invalide ou repete.');
   Fmt := U16(S); Channels := U16(S); Rate := U32(S);
   ByteRate := U32(S); BlockSize := U16(S); Bits := U16(S);
   if not (Fmt in [1, 3]) Then          Fail(
   'Encodage non pris en charge: utiliser PCM ou float IEEE WAV.');
   if (Channels < 1) or (Channels > 8) or (Rate < 8000) or (Rate > 192000)
   Then          Fail('Canaux (1..8) ou frequence (8000..192000) invalides.');
   if ((Fmt = 1) and not (Bits in [8,16,24,32])) or
   ((Fmt = 3) and (Bits <> 32)) Then Fail('Resolution WAV non prise en charge.');
   if (BlockSize <> Channels * (Bits div 8)) or
   (ByteRate <> Rate * LongWord(BlockSize)) Then Fail('Alignement PCM invalide.');
   HaveFmt := True;
  End
  else if ID = 'data' Then Begin
   if HaveData Then Fail('Plusieurs chunks data non pris en charge.');
   DataPos := S.Position; DataSize := ChunkSize; HaveData := True;
  End;
  SeekBinary(S, ChunkEnd + (ChunkSize and 1));
 End;
 if not HaveFmt or not HaveData Then Fail('Chunks fmt/data manquants.');
 if (DataSize = 0) or (DataSize mod BlockSize <> 0) Then Fail('Donnees PCM incompletes.');
 Frames := DataSize div BlockSize;
 if Frames > Int64(Rate) * MaxSeconds Then Fail('Duree maximale: 30 minutes.');
 SetLength(Samples, Frames);
 SeekBinary(S, DataPos);
 For I := 0 to Frames - 1 do Begin
  Sum := 0;
  For C := 1 to Channels do Begin
   V := 0;
   case Bits of
   8: ReadBytes(S, V, 1);
   16: V := U16(S);
   24:
   Begin
    V := U16(S); ReadBytes(S, ThirdByte, 1);
    V := V or (LongWord(ThirdByte) shl 16);
   End;
   32: V := U32(S);
  End;
  if Fmt = 3 Then Begin
   Move(V, F, 4);
   if IsNan(F) or IsInfinite(F) Then Fail('Echantillon float non fini.');
   X := F;
  End
  else if Bits = 8 Then X := (Integer(V) - 128) / 128.0
  else
  Begin
   SignedValue := V;
   if (QWord(V) and (QWord(1) shl (Bits - 1))) <> 0 Then            SignedValue :=
   SignedValue - (Int64(1) shl Bits);
   X := SignedValue / (Int64(1) shl (Bits - 1));
  End;
  Sum := Sum + EnsureRange(X, -1.0, 1.0);
 End;
 Samples[I] := Sum / Channels;
End;
CloseBinary(S);
End;

Procedure Resample(const Source: TSamples; Rate: LongWord; out Dest: TSamples);
Var
 I, J, Center, Radius, Count: Integer;
 Position, Distance, Cutoff, Weight, Total, Norm, Angle: Double;
Begin
 if Rate = TargetRate Then Begin
  Dest := Copy(Source); Exit;
 End;
 Count := (Int64(Length(Source)) * TargetRate + Rate - 1) div Rate;
 SetLength(Dest, Count);
  { Sinc fenetree Hann, filtre anti-repliement avant sous-echantillonnage.
    Le support augmente avec le rapport des frequences. }
 Cutoff := 0.94 * Min(1.0, TargetRate / Rate);
 Radius := Ceil(16 / Cutoff);
 For I := 0 to Count - 1 do Begin
  Position := I * (Double(Rate) / TargetRate);
  Center := Floor(Position); Total := 0; Norm := 0;
  For J := Max(0, Center - Radius) to Min(High(Source), Center + Radius) do Begin
   Distance := Position - J;
   if Abs(Distance) >= Radius Then Continue;
   Angle := Pi * Distance * Cutoff;
   if Abs(Angle) < 1E-12 Then Weight := Cutoff
   else Weight := Cutoff * Sin(Angle) / Angle;
   Weight := Weight * (0.5 + 0.5 * Cos(Pi * Distance / Radius));
   Total := Total + Source[J] * Weight; Norm := Norm + Weight;
  End;
  if Abs(Norm) > 1E-12 Then Dest[I] := Total / Norm else Dest[I] := 0;
 End;
End;

Procedure RemoveDC(var Samples: TSamples);
Var
 I: Integer;
 PrevIn, PrevOut, X: Double;
Begin
  { Passe-haut doux ~40 Hz; pas de gate qui supprimerait les consonnes.
    Le bruit restant est gere par VAD et le modele acoustique entraine. }
 PrevIn := 0; PrevOut := 0;
 For I := 0 to High(Samples) do Begin
  X := Samples[I] - PrevIn + 0.9844 * PrevOut;
  PrevIn := Samples[I]; PrevOut := X;
  Samples[I] := EnsureRange(X, -1.0, 1.0);
 End;
End;

Procedure WriteWave(const Name: string; const Samples: TSamples);
Var
 S: TBinary;
 I, N: Integer;
 V: SmallInt;
Begin
 OpenBinary(S, Name, True);
 N := Length(Samples) * 2;
 Tag(S, 'RIFF'); Put32(S, N + 36); Tag(S, 'WAVE');
 Tag(S, 'fmt '); Put32(S, 16); Put16(S, 1); Put16(S, 1);
 Put32(S, TargetRate); Put32(S, TargetRate * 2);
 Put16(S, 2); Put16(S, 16); Tag(S, 'data'); Put32(S, N);
 For I := 0 to High(Samples) do Begin
  V := Round(EnsureRange(Samples[I], -1.0, 1.0) * 32767);
  Put16(S, Word(V));
 End;
 CloseBinary(S);
End;
{$IFDEF MSWINDOWS}

 Function QuoteArgument(const S: string): string;
 Var
  I, J, Slashes: Integer;
 Begin
  { Convention argv Windows: doubler les antislashs precedant un guillemet
    ou le guillemet final. Aucun interpreteur de commandes n'est utilise. }
  Result := '"'; Slashes := 0;
  For I := 1 to Length(S) do    if S[I] = '\' Then Inc(Slashes)
  else
  Begin
   if S[I] = '"' Then Begin
    For J := 1 to Slashes * 2 + 1 do Result := Result + '\';
   End
   else
   For J := 1 to Slashes do Result := Result + '\';
   Result := Result + S[I]; Slashes := 0;
  End;
  For J := 1 to Slashes * 2 do Result := Result + '\';
  Result := Result + '"';
 End;

 Procedure RunTool(const Exe: string; const Args: array of string);
 Var
  SI: TStartupInfo;
  PI: TProcessInformation;
  SA: TSecurityAttributes;
  ReadPipe, WritePipe, NullInput: THandle;
  Command, Executable, Log: string;
  PathBuffer: array[0..32767] of Char;
  Buffer: array[0..4095] of Byte;
  Count, Status, ErrorCode: DWORD;
  I: Integer;

 Procedure CloseHandles;Begin
  if ReadPipe <> 0 Then CloseHandle(ReadPipe);
  if WritePipe <> 0 Then CloseHandle(WritePipe);
  if NullInput <> INVALID_HANDLE_VALUE Then CloseHandle(NullInput);
  if PI.hThread <> 0 Then CloseHandle(PI.hThread);
  if PI.hProcess <> 0 Then CloseHandle(PI.hProcess);
 End;

 Procedure LaunchError(const Detail: string; Code: DWORD);Begin
  CloseHandles;
  Fail(Exe + ': ' + Detail + ' (code ' + IntToStr(Code) + ')');
 End;
 Begin
  FillChar(SI, SizeOf(SI), 0); FillChar(PI, SizeOf(PI), 0);
  ReadPipe := 0; WritePipe := 0; NullInput := INVALID_HANDLE_VALUE;
  Count := SearchPath(nil, PChar(Exe), '.exe', Length(PathBuffer), @PathBuffer[0], nil);
  if (Count = 0) or (Count >= DWORD(Length(PathBuffer))) Then    LaunchError(
  'executable introuvable', GetLastError);
  Executable := PChar(@PathBuffer[0]);
  Command := QuoteArgument(Executable);
  For I := 0 to High(Args) do Command := Command + ' ' + QuoteArgument(Args[I]);
  if Length(Command) >= 32767 Then LaunchError('ligne de commande trop longue', 87);
  FillChar(SA, SizeOf(SA), 0); SA.nLength := SizeOf(SA); SA.bInheritHandle := True;
  if not CreatePipe(ReadPipe, WritePipe, @SA, 0) Then LaunchError(
  'creation du pipe impossible', GetLastError);
  if not SetHandleInformation(ReadPipe, HANDLE_FLAG_INHERIT, 0) Then    LaunchError(
  'configuration du pipe impossible', GetLastError);
  NullInput := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE,
  @SA, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if NullInput = INVALID_HANDLE_VALUE Then LaunchError('ouverture NUL impossible',
  GetLastError);
  SI.cb := SizeOf(SI); SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput := NullInput; SI.hStdOutput := WritePipe; SI.hStdError := WritePipe;
  if not CreateProcess(PChar(Executable), PChar(Command), nil, nil, True,
  CREATE_NO_WINDOW, nil, nil, SI, PI) Then LaunchError('lancement impossible',
  GetLastError);
  CloseHandle(WritePipe); WritePipe := 0;
  CloseHandle(NullInput); NullInput := INVALID_HANDLE_VALUE;
  repeat
  if not ReadFile(ReadPipe, Buffer, SizeOf(Buffer), Count, nil) Then Begin
   ErrorCode := GetLastError;
   if ErrorCode <> ERROR_BROKEN_PIPE Then Begin
    TerminateProcess(PI.hProcess, 1);
    WaitForSingleObject(PI.hProcess, INFINITE);
    LaunchError('lecture des diagnostics impossible', ErrorCode);
   End;
   Break;
  End;
  if Count = 0 Then Break;
  SetString(Log, PChar(@Buffer[0]), Count); Write(StdErr, Log);
  until False;
  if WaitForSingleObject(PI.hProcess, INFINITE) = WAIT_FAILED Then    LaunchError(
  'attente du moteur impossible', GetLastError);
  if not GetExitCodeProcess(PI.hProcess, Status) Then LaunchError(
  'code de retour inaccessible', GetLastError);
  CloseHandles;
  if Status <> 0 Then Fail(Exe + ': echec, code ' + IntToStr(Status));
 End;
{$ELSE}

 Function FindExecutable(const Name: string): string;
 Var
  Paths, Part: string;
  I: Integer;
 Begin
  if Pos('/', Name) > 0 Then Exit(ExpandFileName(Name));
  Paths := DOS.GetEnv('PATH');
  repeat
  I := Pos(':', Paths);
  if I = 0 Then Part := Paths else Part := Copy(Paths, 1, I - 1);
  if Part = '' Then Part := '.';
  Result := IncludeTrailingPathDelimiter(Part) + Name;
  if FileExists(Result) and (fpAccess(PChar(Result), X_OK) = 0) Then Exit;
  if I = 0 Then Break;
  Delete(Paths, 1, I);
  until False;
  Fail('Executable introuvable: ' + Name);
 End;

 Procedure RunTool(const Exe: string; const Args: array of string);
 Var
  Pipes: array[0..1] of cint;
  PID, WaitResult: TPid;
  NullInput, Status, I: cint;
  N: Int64;
  Buffer: array[0..4095] of Byte;
  Executable, Log: string;
  Arguments: array of PChar;
 Begin
  Executable := FindExecutable(Exe);
  SetLength(Arguments, Length(Args) + 2);
  Arguments[0] := PChar(Executable);
  For I := 0 to High(Args) do Arguments[I + 1] := PChar(Args[I]);
  Arguments[High(Arguments)] := nil;
  if fpPipe(Pipes) <> 0 Then Fail('Creation du pipe impossible: ' + Exe);
  PID := fpFork;
  if PID < 0 Then Begin
   fpClose(Pipes[0]); fpClose(Pipes[1]); Fail('Creation du processus impossible: ' + Exe);
  End;
  if PID = 0 Then Begin
   fpClose(Pipes[0]);
   NullInput := fpOpen('/dev/null', O_RDONLY);
   if (NullInput < 0) or (fpDup2(NullInput, 0) < 0) or
   (fpDup2(Pipes[1], 1) < 0) or (fpDup2(Pipes[1], 2) < 0) Then fpExit(126);
   if NullInput > 2 Then fpClose(NullInput);
   if Pipes[1] > 2 Then fpClose(Pipes[1]);
   fpExecV(PChar(Executable), @Arguments[0]);
   fpExit(127);
  End;
  fpClose(Pipes[1]);
  repeat
  N := fpRead(Pipes[0], Buffer, SizeOf(Buffer));
  if (N < 0) and (fpGetErrNo = ESysEINTR) Then Continue;
  if N <= 0 Then Break;
  SetString(Log, PChar(@Buffer[0]), N); Write(StdErr, Log);
  until False;
  fpClose(Pipes[0]);
  repeat
  WaitResult := fpWaitPid(PID, @Status, 0);
  until (WaitResult >= 0) or (fpGetErrNo <> ESysEINTR);
  if (N < 0) or (WaitResult < 0) Then Fail('Lecture/attente du moteur impossible: ' + Exe)
  ;
  if Status <> 0 Then Fail(Exe + ': echec, statut POSIX ' + IntToStr(Status));
 End;
{$ENDIF}

Procedure Help;Begin
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
End;

Procedure Parse(out O: TOptions);
Var
 I: Integer;
 K, V: string;
Begin
 O.Input := ''; O.Output := ''; O.Model := ''; O.VADModel := '';
 O.Whisper := 'whisper-cli'; O.MFA := 'mfa';
 O.Dictionary := 'french_mfa'; O.Acoustic := 'french_mfa';
 O.PrepareOnly := False; O.TextOnly := False;
 I := 1;
 While I <= ParamCount do Begin
  K := ParamStr(I);
  if K = '--prepare-only' Then O.PrepareOnly := True
  else if K = '--text-only' Then O.TextOnly := True
  else if Copy(K, 1, 2) = '--' Then Begin
   if not ((K = '--output') or (K = '--model') or (K = '--vad-model') or
   (K = '--whisper') or (K = '--mfa') or (K = '--dictionary') or
   (K = '--acoustic')) Then Fail('Option inconnue: ' + K);
   Inc(I); if I > ParamCount Then Fail('Valeur manquante: ' + K);
   V := ParamStr(I); if V = '' Then Fail('Valeur vide: ' + K);
   if K = '--output' Then O.Output := V
   else if K = '--model' Then O.Model := V
   else if K = '--vad-model' Then O.VADModel := V
   else if K = '--whisper' Then O.Whisper := V
   else if K = '--mfa' Then O.MFA := V
   else if K = '--dictionary' Then O.Dictionary := V
   else if K = '--acoustic' Then O.Acoustic := V;
  End
  else if O.Input = '' Then O.Input := K
  else Fail('Argument inattendu: ' + K);
  Inc(I);
 End;
 if O.Input = '' Then Fail('Fichier WAV requis; utiliser --help.');
 O.Input := ExpandFileName(O.Input);
 if O.Output = '' Then O.Output := ChangeFileExt(O.Input, '') + '.fra';
 O.Output := ExpandFileName(O.Output);
 if not DirectoryExists(ExtractFileDir(O.Output)) Then Fail('Dossier de sortie absent.');
 if not O.PrepareOnly Then Begin
  if not FileExists(O.Model) Then Fail('--model: fichier Whisper multilingue requis.');
  if Pos('.en', LowerCase(ExtractFileName(O.Model))) > 0 Then      Fail(
  'Un modele Whisper anglais .en ne reconnait pas le francais.');
  if not FileExists(O.VADModel) Then Fail('--vad-model: fichier Silero requis.');
 End;
End;

Procedure MustBeNew(const Name: string);Begin
 if FileExists(Name) or DirectoryExists(Name) Then Fail('Sortie deja existante: ' + Name);
End;

Procedure CopyNew(const Source, Dest: string);
Var
 A, B: TBinary;
 Buffer: array[0..8191] of Byte;
 Count: Integer;
Begin
 MustBeNew(Dest);
 OpenBinary(A, Source, False); OpenBinary(B, Dest, True);
 While A.Position < A.Size do Begin
  Count := SizeOf(Buffer);
  if A.Size - A.Position < Count Then Count := A.Size - A.Position;
  ReadBytes(A, Buffer, Count); WriteBytes(B, Buffer, Count);
 End;
 CloseBinary(B); CloseBinary(A);
End;

Procedure CleanupWork;
Var
 Prefix: string;
Begin
 if WorkDirectory = '' Then Exit;
 Prefix := WorkDirectory + DirectorySeparator;
  { Ne supprimer que les fichiers connus; les diagnostics MFA sont conserves. }
 DeleteFile(Prefix + 'audio.wav'); DeleteFile(Prefix + 'transcript.txt');
 DeleteFile(Prefix + 'transcript.json'); DeleteFile(Prefix + 'phones.TextGrid');
 if not RemoveDir(WorkDirectory) Then WriteLn(StdErr, 'Diagnostics conserves: ',
 WorkDirectory);
 WorkDirectory := '';
End;

Procedure Transcribe(const O: TOptions; const Audio: TSamples);
Var
 Work, Wav, Prefix, Grid, Txt, GridText: string;
Begin
 MustBeNew(O.Output + '.txt'); MustBeNew(O.Output + '.json');
 if not O.TextOnly Then MustBeNew(O.Output + '.TextGrid');
 Work := CreateWorkDir;
 WorkDirectory := Work;
 Wav := Work + DirectorySeparator + 'audio.wav';
 Prefix := Work + DirectorySeparator + 'transcript';
 Grid := Work + DirectorySeparator + 'phones.TextGrid';
 WriteWave(Wav, Audio);
 WriteLn(StdErr, 'Detection Silero et reconnaissance Whisper en francais...');
 RunTool(O.Whisper, ['-m', ExpandFileName(O.Model), '-f', Wav, '-l', 'fr',
 '--vad', '-vm', ExpandFileName(O.VADModel), '-otxt', '-oj', '-of', Prefix]);
 if not FileExists(Prefix + '.txt') or not FileExists(Prefix + '.json') Then      Fail(
 'Whisper n''a pas produit les fichiers TXT et JSON attendus.');
 Txt := Trim(LoadText(Prefix + '.txt'));
 if not O.TextOnly Then Begin
  if Txt <> '' Then Begin
   WriteLn(StdErr, 'Alignement acoustique des mots et phonemes (MFA)...');
   RunTool(O.MFA, ['align_one', Wav, Prefix + '.txt', O.Dictionary,
   O.Acoustic, Grid, '--temporary_directory', Work + DirectorySeparator + 'mfa']);
   if not FileExists(Grid) Then Fail('MFA n''a pas produit de TextGrid.');
  End
  else
  Begin
          { Aucune parole: grille valide sans intervalles, pas de texte invente. }
   GridText := 'File type = "ooTextFile"' + LineEnding +
   'Object class = "TextGrid"' + LineEnding + LineEnding +
   'xmin = 0' + LineEnding + 'xmax = ' + AudioDuration(Length(Audio)) + LineEnding +
   'tiers? <exists>' + LineEnding + 'size = 0' + LineEnding + 'item []:' + LineEnding;
   SaveText(Grid, GridText);
  End;
 End;
 CopyNew(Prefix + '.txt', O.Output + '.txt');
 CopyNew(Prefix + '.json', O.Output + '.json');
 if not O.TextOnly Then CopyNew(Grid, O.Output + '.TextGrid');
 WriteLn(Txt);
 WriteLn(StdErr, 'Transcription UTF-8: ', O.Output + '.txt');
 CleanupWork;
End;

Var
 O: TOptions;
 Source, Audio: TSamples;
 Rate: LongWord;
 I: Integer;

BEGIN
 InitializeArguments;
 For I := 1 to ParamCount do      if ParamStr(I) = '--help' Then Begin
  Help; Halt(0);
 End;
 if ParamCount = 0 Then Begin
  Help; Halt(1);
 End;
 Parse(O);
 ReadWave(O.Input, Source, Rate);
 WriteLn(StdErr, 'Lecture WAV: ', Length(Source), ' trames, ', Rate, ' Hz.');
 Resample(Source, Rate, Audio); SetLength(Source, 0);
 RemoveDC(Audio);
 if O.PrepareOnly Then Begin
  MustBeNew(O.Output + '.wav'); WriteWave(O.Output + '.wav', Audio);
  WriteLn('WAV mono PCM16 / 16000 Hz: ', O.Output + '.wav');
 End
 else Transcribe(O, Audio);
END.
