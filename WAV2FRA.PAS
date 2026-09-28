Program WAV2FRA;
{$mode fpc}{$H+}
{$modeswitch result+}{$modeswitch out+}
{ Free Pascal 3.2+. Compile: fpc -O2 WAV2FRA.PAS
  Pipeline local: RIFF -> mono/16 kHz -> Silero VAD -> Whisper francais
  -> alignement acoustique interne, donnees MFA/Kaldi. Aucun appel reseau ici.
  Les poids entraines sont externes, pas simules par des regles Pascal.
  Whisper integre modelisation acoustique et linguistique, accents et
  ponctuation. L'aligneur utilise le texte reconnu: une erreur de transcription
  peut donc aussi produire des frontieres phonetiques incorrectes.
  Turbo Pascal DOS ne fournit pas la memoire requise pour ce pipeline. }

Uses DOS;

Type
 { Le mode FPC classique definit Integer sur 16 bits: indices audio en 32 bits. }
 Integer = LongInt;
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
Input, Output, Model, VADModel, Dictionary, Acoustic, AlignText: string;
PrepareOnly, TextOnly, CheckAcoustic, CheckWhisper, CheckVAD: Boolean;
End;

Const
 TargetRate = 16000;
 MaxInputBytes = 268435456;
 { limite explicite: 256 Mio }
 MaxSeconds = 1800;

Var
 OpenFiles: array[0..7] of PBinary;
 WorkDirectory: string;
Procedure Fail(const S: string);Forward;
Procedure CleanupWork;Forward;
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
{ Aligneur interne: lecture des donnees Kaldi, sans executable ni DLL MFA.
  Implementations procedurales des formats binaires et du decodeur GMM-HMM. }
Type
 TIntVector = array of LongInt;
 TRealVector = array of Single;
 TStringVector = array of string;
 TReader = record Data, Name: RawByteString; Position: LongInt; End;
 THuffman = record Counts: array[0..15] of Integer; Symbols: array[0..287] of Integer; End;

Function ReadByte(var R: TReader): Byte;
Begin
 if (R.Position < 1) or (R.Position > Length(R.Data)) Then Fail('Donnees tronquees: ' + R.Name);
 Result := Ord(R.Data[R.Position]); Inc(R.Position);
End;

Function ReadLE(var R: TReader; Count: Integer): LongWord;
Var I: Integer;
Begin
 Result := 0;
 For I := 0 to Count - 1 do Result := Result or (LongWord(ReadByte(R)) shl (8 * I));
End;

Function KToken(var R: TReader): string;
Var C: Byte;
Begin
 Result := '';
 repeat C := ReadByte(R); until C > 32;
 repeat
  Result := Result + Chr(C);
  if Length(Result) > 100 Then Fail('Token Kaldi invalide: ' + R.Name);
  C := ReadByte(R);
 until C <= 32;
End;

Procedure KExpect(var R: TReader; const Expected: string);
Var Actual: string;
Begin
 Actual := KToken(R);
 if Actual <> Expected Then Fail(R.Name + ': attendu ' + Expected + ', obtenu ' + Actual);
End;

Function KInt(var R: TReader): LongInt;
Var Marker: Byte;
Begin
 Marker := ReadByte(R);
 if (Marker <> 4) and (Marker <> 252) Then
  Fail('Entier Kaldi non 32 bits: ' + R.Name + ', octet ' + IntToStr(R.Position - 1));
 Result := LongInt(ReadLE(R, 4));
End;

Function Bounded(Value, LowBound, HighBound: LongInt; const What: string): LongInt;
Begin
 if (Value < LowBound) or (Value > HighBound) Then Fail('Valeur invalide: ' + What);
 Result := Value;
End;

Function KFloat(var R: TReader; WithSize: Boolean): Single;
Var Bits: LongWord;
Begin
 if WithSize Then if ReadByte(R) <> 4 Then Fail('Reel Kaldi non float32: ' + R.Name);
 Bits := ReadLE(R, 4); Move(Bits, Result, 4);
 if IsNan(Result) or IsInfinite(Result) Then Fail('Reel Kaldi non fini: ' + R.Name);
End;

Procedure KHeader(var R: TReader; const Data, Name: string);
Begin
 R.Data := Data; R.Name := Name; R.Position := 1;
 if (ReadByte(R) <> 0) or (ReadByte(R) <> Ord('B')) Then
  Fail('Modele Kaldi binaire requis: ' + Name);
End;

Procedure KInts(var R: TReader; out Values: TIntVector);
Var I, N: Integer;
Begin
 { Les vecteurs d'entiers ont une seule marque de taille, puis N brut. }
 if ReadByte(R) <> 4 Then Fail('Vecteur Kaldi invalide: ' + R.Name);
 N := Bounded(LongInt(ReadLE(R, 4)), 0, 1000000, 'taille vecteur');
 if Int64(N) * 4 > Length(R.Data) - R.Position + 1 Then Fail('Vecteur Kaldi tronque: ' + R.Name);
 SetLength(Values, N);
 For I := 0 to N - 1 do Values[I] := LongInt(ReadLE(R, 4));
End;

Procedure KReals(var R: TReader; out Values: TRealVector; out Rows, Cols: Integer; Matrix: Boolean);
Var I: Integer;
Begin
 if Matrix Then KExpect(R, 'FM') else KExpect(R, 'FV');
 Rows := Bounded(KInt(R), 0, 1000000, 'dimension Kaldi'); Cols := 1;
 if Matrix Then Cols := Bounded(KInt(R), 1, 1000, 'colonnes Kaldi');
 if Int64(Rows) * Cols > 16000000 Then Fail('Matrice Kaldi trop grande.');
 if Int64(Rows) * Cols * 4 > Length(R.Data) - R.Position + 1 Then Fail('Matrice Kaldi tronquee: ' + R.Name);
 SetLength(Values, Rows * Cols);
 For I := 0 to High(Values) do Values[I] := KFloat(R, False);
End;

Procedure MakeHuffman(const Lengths: array of Integer; var H: THuffman);
Var I, Left: Integer; Offsets: array[0..15] of Integer;
Begin
 FillChar(H, SizeOf(H), 0);
 For I := 0 to High(Lengths) do Begin
  Bounded(Lengths[I], 0, 15, 'code deflate'); Inc(H.Counts[Lengths[I]]);
 End;
 Left := 1;
 For I := 1 to 15 do Begin
  Left := Left * 2 - H.Counts[I];
  if Left < 0 Then Fail('Arbre Huffman sursouscrit.');
 End;
 Offsets[1] := 0;
 For I := 1 to 14 do Offsets[I + 1] := Offsets[I] + H.Counts[I];
 For I := 0 to High(Lengths) do if Lengths[I] <> 0 Then Begin
  H.Symbols[Offsets[Lengths[I]]] := I; Inc(Offsets[Lengths[I]]);
 End;
End;

Function InflateRaw(const Compressed: string; ExpectedSize: Integer): string;
Const
 Order: array[0..18] of Integer = (16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15);
 LenBase: array[0..28] of Integer = (3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258);
 LenExtra: array[0..28] of Integer = (0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0);
 DistBase: array[0..29] of Integer = (1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577);
 DistExtra: array[0..29] of Integer = (0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13);
Var
 R: TReader; Bits: LongWord; BitCount, Used: Integer;
 Lit, Dist, Code: THuffman;
 L: array[0..287] of Integer; D: array[0..31] of Integer;
 C: array[0..18] of Integer; All: array[0..319] of Integer;
 FinalBlock, Kind, NL, ND, NC, I, J, Symbol, N, Distance, Previous, Inverse: Integer;

 Function Take(N: Integer): Integer;
 Begin
  While BitCount < N do Begin Bits := Bits or (LongWord(ReadByte(R)) shl BitCount); Inc(BitCount, 8); End;
  Result := Bits and ((LongWord(1) shl N) - 1); Bits := Bits shr N; Dec(BitCount, N);
 End;

 Function Decode(const H: THuffman): Integer;
 Var Width, Value, First, Offset: Integer;
 Begin
  Value := 0; First := 0; Offset := 0;
  For Width := 1 to 15 do Begin
   Value := (Value shl 1) or Take(1);
   if (Value >= First) and (Value < First + H.Counts[Width]) Then
    Exit(H.Symbols[Offset + Value - First]);
   Inc(Offset, H.Counts[Width]); First := (First + H.Counts[Width]) shl 1;
  End;
  Fail('Code deflate invalide.'); Result := 0;
 End;

 Procedure Emit(Value: Char);
 Begin
  if Used >= ExpectedSize Then Fail('Taille ZIP decompressee depassee.');
  Inc(Used); Result[Used] := Value;
 End;

Begin
 Bounded(ExpectedSize, 0, MaxInputBytes, 'taille ZIP'); SetLength(Result, ExpectedSize);
 R.Data := Compressed; R.Name := 'deflate ZIP'; R.Position := 1;
 Bits := 0; BitCount := 0; Used := 0;
 repeat
  FinalBlock := Take(1); Kind := Take(2);
  if Kind = 0 Then Begin
   Bits := 0; BitCount := 0;
   N := ReadLE(R, 2); Inverse := ReadLE(R, 2);
   if (N xor Inverse) <> 65535 Then Fail('Bloc ZIP stocke invalide.');
   For I := 1 to N do Emit(Chr(ReadByte(R)));
  End else Begin
   FillChar(L, SizeOf(L), 0); FillChar(D, SizeOf(D), 0);
   if Kind = 1 Then Begin
    For I := 0 to 143 do L[I] := 8;
    For I := 144 to 255 do L[I] := 9;
    For I := 256 to 279 do L[I] := 7;
    For I := 280 to 287 do L[I] := 8;
    For I := 0 to 31 do D[I] := 5;
   End else if Kind = 2 Then Begin
    NL := Take(5) + 257; ND := Take(5) + 1; NC := Take(4) + 4;
    FillChar(C, SizeOf(C), 0);
    For I := 0 to NC - 1 do C[Order[I]] := Take(3);
    MakeHuffman(C, Code); I := 0;
    While I < NL + ND do Begin
     Symbol := Decode(Code);
     if Symbol <= 15 Then Begin All[I] := Symbol; Inc(I); End
     else Begin
      Previous := 0;
      case Symbol of
       16: Begin if I = 0 Then Fail('Repetition deflate sans precedent.'); Previous := All[I - 1]; N := Take(2) + 3; End;
       17: N := Take(3) + 3;
       18: N := Take(7) + 11;
       else Begin Fail('Longueur deflate invalide.'); N := 0; End;
      End;
      if I + N > NL + ND Then Fail('Repetition deflate excessive.');
      For J := 1 to N do Begin All[I] := Previous; Inc(I); End;
     End;
    End;
    For I := 0 to NL - 1 do L[I] := All[I];
    For I := 0 to ND - 1 do D[I] := All[NL + I];
   End else Fail('Type de bloc deflate invalide.');
   if L[256] = 0 Then Fail('Fin de bloc deflate absente.');
   MakeHuffman(L, Lit); MakeHuffman(D, Dist);
   repeat
    Symbol := Decode(Lit);
    if Symbol < 256 Then Emit(Chr(Symbol))
    else if Symbol > 256 Then Begin
     Bounded(Symbol, 257, 285, 'longueur deflate'); Dec(Symbol, 257);
     N := LenBase[Symbol] + Take(LenExtra[Symbol]);
     Symbol := Bounded(Decode(Dist), 0, 29, 'distance deflate');
     Distance := DistBase[Symbol] + Take(DistExtra[Symbol]);
     if Distance > Used Then Fail('Distance deflate hors tampon.');
     For I := 1 to N do Emit(Result[Used - Distance + 1]);
    End;
   until Symbol = 256;
  End;
 until FinalBlock = 1;
 if Used <> ExpectedSize Then Fail('Taille ZIP decompressee incorrecte.');
End;

Function CRC32(const Data: string): LongWord;
Var I, J: Integer;
Begin
 Result := $FFFFFFFF;
 For I := 1 to Length(Data) do Begin
  Result := Result xor Ord(Data[I]);
  For J := 1 to 8 do
   if (Result and 1) <> 0 Then Result := (Result shr 1) xor $EDB88320
   else Result := Result shr 1;
 End;
 Result := not Result;
End;

Function ZipMember(const Archive, Member: string): string;
Var R, L: TReader; I, Entries, N, Extra, Comment, Method, Flags: Integer;
 Offset, PackedSize, UnpackedSize, Checksum: LongWord; Name, Payload: string; Found: Boolean;
Begin
 R.Data := Archive; R.Name := 'archive MFA'; Found := False;
 I := Length(Archive) - 21;
 While I >= Max(1, Length(Archive) - 65557) do Begin
  if Copy(Archive, I, 4) = 'PK' + #5#6 Then Begin Found := True; Break; End;
  Dec(I);
 End;
 if not Found Then Fail('Repertoire central ZIP absent.');
 R.Position := I + 4;
 if (ReadLE(R, 2) <> 0) or (ReadLE(R, 2) <> 0) Then Fail('ZIP multidisque non accepte.');
 Entries := ReadLE(R, 2);
 if ReadLE(R, 2) <> LongWord(Entries) Then Fail('ZIP multidisque non accepte.');
 ReadLE(R, 4); Offset := ReadLE(R, 4);
 R.Position := Bounded(Int64(Offset) + 1, 1, Length(Archive), 'offset ZIP');
 Found := False; Result := '';
 For I := 1 to Entries do Begin
  if ReadLE(R, 4) <> $02014B50 Then Fail('Entree ZIP invalide.');
  ReadLE(R, 2); ReadLE(R, 2); Flags := ReadLE(R, 2); Method := ReadLE(R, 2);
  ReadLE(R, 4); Checksum := ReadLE(R, 4); PackedSize := ReadLE(R, 4); UnpackedSize := ReadLE(R, 4);
  N := ReadLE(R, 2); Extra := ReadLE(R, 2); Comment := ReadLE(R, 2);
  ReadLE(R, 2); ReadLE(R, 2); ReadLE(R, 4); Offset := ReadLE(R, 4);
  if Int64(R.Position) + N + Extra + Comment - 1 > Length(Archive) Then Fail('Nom ZIP tronque.');
  Name := Copy(Archive, R.Position, N); Inc(R.Position, N + Extra + Comment);
  if (Name <> Member) and (Copy(Name, Length(Name) - Length(Member), Length(Member) + 1) <> '/' + Member) Then Continue;
  if Found Then Fail('Plusieurs fichiers ' + Member + ' dans l''archive.');
  Found := True;
  if (Flags and 1) <> 0 Then Fail('ZIP chiffre non accepte.');
  if (PackedSize > MaxInputBytes) or (UnpackedSize > MaxInputBytes) Then Fail('Entree ZIP trop grande.');
  L.Data := Archive; L.Name := Name;
  L.Position := Bounded(Int64(Offset) + 1, 1, Length(Archive), 'offset ZIP local');
  if ReadLE(L, 4) <> $04034B50 Then Fail('Entete ZIP locale absente.');
  Inc(L.Position, 22); N := ReadLE(L, 2); Extra := ReadLE(L, 2); Inc(L.Position, N + Extra);
  if Int64(L.Position) + PackedSize - 1 > Length(Archive) Then Fail('Entree ZIP tronquee.');
  Payload := Copy(Archive, L.Position, PackedSize);
  if Method = 0 Then Result := Payload
  else if Method = 8 Then Result := InflateRaw(Payload, UnpackedSize)
  else Fail('Compression ZIP non prise en charge (stockage/deflate requis).');
  if (Length(Result) <> UnpackedSize) or (CRC32(Result) <> Checksum) Then Fail('CRC/taille ZIP incorrect: ' + Member);
 End;
End;

Function ModelMember(const Path, Archive, Member: string; Required: Boolean): string;
Var Name: string;
Begin
 if Archive <> '' Then Result := ZipMember(Archive, Member)
 else Begin
  Name := IncludeTrailingPathDelimiter(Path) + Member;
  if FileExists(Name) Then Result := LoadText(Name) else Result := '';
 End;
 if Required and (Result = '') Then Fail('Fichier du modele manquant: ' + Member);
End;

Type
 TTopoState = record PdfClass: Integer; Dest: TIntVector; End;
 TTopology = array of TTopoState;
 TTransition = record Phone, State, Pdf, First: Integer; End;
 TGMM = record Constants, Means, InverseVars: TRealVector; Count: Integer; End;
 TTreeNode = record Kind, Key, Answer, YesNode, NoNode: Integer; Values: TIntVector; End;
 TKaldiModel = record
  PhoneNames: TStringVector;
  PhoneTopology: TIntVector;
  Topologies: array of TTopology;
  Transitions: array of TTransition;
  LogProbs: TRealVector;
  PDFs: array of TGMM;
  Tree: array of TTreeNode;
  TreeRoot, ContextWidth, CentralPosition, Dimension, LdaRows, LdaCols: Integer;
  LDA: TRealVector;
  Metadata: string;
  LowFrequency, HighFrequency, Lifter: Double;
  MelBins: Integer;
  UseEnergy: Boolean;
 End;

Function NextToken(const Text: string; var Position: Integer): string;
Var First: Integer;
Begin
 While (Position <= Length(Text)) and (Text[Position] <= ' ') do Inc(Position);
 First := Position;
 While (Position <= Length(Text)) and (Text[Position] > ' ') do Inc(Position);
 Result := Copy(Text, First, Position - First);
End;

Function JsonValue(const Text, Key: string): string;
Var I, Start: Integer;
Begin
 Result := ''; I := Pos('"' + Key + '"', Text);
 if I = 0 Then Exit;
 Inc(I, Length(Key) + 2);
 While (I <= Length(Text)) and (Text[I] <= ' ') do Inc(I);
 if (I > Length(Text)) or (Text[I] <> ':') Then Fail('Meta JSON invalide: ' + Key);
 Inc(I); While (I <= Length(Text)) and (Text[I] <= ' ') do Inc(I);
 if (I <= Length(Text)) and (Text[I] = '"') Then Begin
  Inc(I); Start := I;
  While (I <= Length(Text)) and (Text[I] <> '"') do Inc(I);
 End else Begin
  Start := I;
  While (I <= Length(Text)) and not (Text[I] in [',','}',']',#9,#10,#13,' ']) do Inc(I);
 End;
 Result := Copy(Text, Start, I - Start);
End;

Function Number(const Text, What: string): Double;
Var Code: Integer; Bits: QWord;
Begin
 Val(Text, Result, Code); Move(Result, Bits, SizeOf(Bits));
 if (Code <> 0) or ((Bits and QWord($7FF0000000000000)) = QWord($7FF0000000000000)) Then
  Fail('Nombre invalide: ' + What);
End;

Function ReadTreeNode(var R: TReader; var M: TKaldiModel; Depth: Integer): Integer;
Var Token: string; Node, I, Child, N: Integer; Values: TIntVector;
Begin
 if Depth > 256 Then Fail('Arbre Kaldi trop profond.');
 Token := KToken(R);
 if Token = 'NULL' Then Exit(-1);
 Node := Length(M.Tree); if Node >= 100000 Then Fail('Arbre Kaldi trop grand.');
 SetLength(M.Tree, Node + 1); Result := Node;
 if Token = 'CE' Then Begin
  M.Tree[Node].Kind := 0; M.Tree[Node].Answer := KInt(R);
 End else if Token = 'SE' Then Begin
  M.Tree[Node].Kind := 1; M.Tree[Node].Key := KInt(R);
  KInts(R, Values); M.Tree[Node].Values := Values; KExpect(R, '{');
  Child := ReadTreeNode(R, M, Depth + 1); M.Tree[Node].YesNode := Child;
  Child := ReadTreeNode(R, M, Depth + 1); M.Tree[Node].NoNode := Child; KExpect(R, '}');
 End else if Token = 'TE' Then Begin
  M.Tree[Node].Kind := 2; M.Tree[Node].Key := KInt(R);
  N := Bounded(KInt(R), 0, 100000, 'table arbre');
  SetLength(M.Tree[Node].Values, N); KExpect(R, '(');
  For I := 0 to N - 1 do Begin
   Child := ReadTreeNode(R, M, Depth + 1); M.Tree[Node].Values[I] := Child;
  End;
  KExpect(R, ')');
 End else Fail('Noeud Kaldi inconnu: ' + Token);
End;

Function TreePdf(const M: TKaldiModel; LeftPhone, Phone, RightPhone, PdfClass: Integer): Integer;
Var Node, Value, I: Integer; Found: Boolean;
Begin
 Node := M.TreeRoot;
 While Node >= 0 do Begin
  if M.Tree[Node].Kind = 0 Then Exit(Bounded(M.Tree[Node].Answer, 0, High(M.PDFs), 'pdf arbre'));
  case M.Tree[Node].Key of
   -1: Value := PdfClass;
   0: if M.ContextWidth = 1 Then Value := Phone else Value := LeftPhone;
   1: Value := Phone;
   2: Value := RightPhone;
   else Begin Fail('Cle de contexte Kaldi non prise en charge.'); Value := 0; End;
  End;
  if M.Tree[Node].Kind = 1 Then Begin
   Found := False;
   For I := 0 to High(M.Tree[Node].Values) do
    if M.Tree[Node].Values[I] = Value Then Begin Found := True; Break; End;
   if Found Then Node := M.Tree[Node].YesNode else Node := M.Tree[Node].NoNode;
  End else Begin
   if (Value < 0) or (Value >= Length(M.Tree[Node].Values)) Then Node := -1
   else Node := M.Tree[Node].Values[Value];
  End;
 End;
 Fail('Contexte absent de l''arbre Kaldi.'); Result := -1;
End;

Procedure LoadKaldiModel(const Location: string; out M: TKaldiModel);
Var
 Path, Archive, Data, Token, ModelFile, Value: string;
 R: TReader; I, J, K, N, Rows, Cols, Phone, State, TransCount, Position, Code: Integer;
 UnusedInts: TIntVector; UnusedReals: TRealVector; HMM: Boolean; Probability: Single;
Begin
 Path := Location; Archive := ''; ModelFile := 'final.alimdl';
 if not DirectoryExists(Path) Then Begin
  if LowerCase(Copy(Path, Length(Path) - 3, 4)) = '.zip' Then Archive := LoadText(Path)
  else Begin ModelFile := ExtractFileName(Path); Path := ExtractFileDir(ExpandFileName(Path)); End;
 End;
 M.Metadata := ModelMember(Path, Archive, 'meta.json', True);
 if JsonValue(M.Metadata, 'architecture') <> 'gmm-hmm' Then Fail('Modele MFA GMM-HMM requis (pas de reseau neuronal).');
 if (JsonValue(M.Metadata, 'type') <> 'mfcc') or
    (Number(JsonValue(M.Metadata, 'sample_frequency'), 'sample_frequency') <> 16000) or
    (Number(JsonValue(M.Metadata, 'frame_shift'), 'frame_shift') <> 10) or
    (Number(JsonValue(M.Metadata, 'frame_length'), 'frame_length') <> 25) or
    (Number(JsonValue(M.Metadata, 'num_coefficients'), 'num_coefficients') <> 13) Then
  Fail('Configuration MFCC non prise en charge: 16 kHz, 25/10 ms, 13 coefficients requis.');
 if JsonValue(M.Metadata, 'snip_edges') <> 'false' Then Fail('Modele MFA snip_edges=false requis.');
 if (JsonValue(M.Metadata, 'use_pitch') = 'true') or (JsonValue(M.Metadata, 'use_voicing') = 'true') or
    (JsonValue(M.Metadata, 'position_dependent_phones') = 'true') Then
  Fail('Modele avec pitch/voicing/phonemes positionnels non pris en charge.');
 if Number(JsonValue(M.Metadata, 'dither'), 'dither') <> 0 Then Fail('Modele sans dither requis.');
 if Abs(Number(JsonValue(M.Metadata, 'preemphasis_coefficient'), 'preemphasis') - 0.97) > 1E-6 Then
  Fail('Preaccentuation Kaldi non prise en charge.');
 M.MelBins := Round(Number(JsonValue(M.Metadata, 'num_mel_bins'), 'num_mel_bins'));
 Bounded(M.MelBins, 13, 40, 'num_mel_bins');
 M.LowFrequency := Number(JsonValue(M.Metadata, 'low_frequency'), 'low_frequency');
 M.HighFrequency := Number(JsonValue(M.Metadata, 'high_frequency'), 'high_frequency');
 if M.HighFrequency <= 0 Then M.HighFrequency := 8000 + M.HighFrequency;
 if (M.LowFrequency < 0) or (M.HighFrequency > 8000) or (M.LowFrequency >= M.HighFrequency) Then
  Fail('Bornes mel invalides.');
 M.Lifter := Number(JsonValue(M.Metadata, 'cepstral_lifter'), 'cepstral_lifter');
 if (M.Lifter < 0) or (M.Lifter > 1000) Then Fail('Lifter invalide.');
 M.UseEnergy := JsonValue(M.Metadata, 'use_energy') = 'true';
 Data := ModelMember(Path, Archive, 'phones.txt', True); Position := 1;
 While Position <= Length(Data) do Begin
  Token := NextToken(Data, Position); if Token = '' Then Break;
  Value := NextToken(Data, Position); Val(Value, Phone, Code);
  if Code <> 0 Then Fail('Identifiant de phoneme invalide.');
  Bounded(Phone, 0, 10000, 'phone');
  if Phone >= Length(M.PhoneNames) Then SetLength(M.PhoneNames, Phone + 1);
  if M.PhoneNames[Phone] <> '' Then Fail('Identifiant de phoneme repete.');
  M.PhoneNames[Phone] := Token;
 End;
 Data := ModelMember(Path, Archive, ModelFile, True); KHeader(R, Data, ModelFile);
 KExpect(R, '<TransitionModel>'); KExpect(R, '<Topology>');
 KInts(R, UnusedInts); KInts(R, M.PhoneTopology);
 N := KInt(R); HMM := N <> -1;
 if not HMM Then N := KInt(R);
 Bounded(N, 1, 1000, 'topologies'); SetLength(M.Topologies, N);
 For I := 0 to N - 1 do Begin
  Rows := Bounded(KInt(R), 2, 32, 'etats topologie'); SetLength(M.Topologies[I], Rows);
  For J := 0 to Rows - 1 do Begin
   State := KInt(R); M.Topologies[I][J].PdfClass := State;
   if not HMM Then if KInt(R) <> State Then Fail('Topologie chain non prise en charge.');
   if ((J < Rows - 1) and (State < 0)) or ((J = Rows - 1) and (State <> -1)) Then
    Fail('Topologie a etats non emetteurs intermediaires non prise en charge.');
   Cols := Bounded(KInt(R), 0, 32, 'transitions topologie');
   if (J = Rows - 1) and (Cols <> 0) Then Fail('Etat final avec transitions.');
   SetLength(M.Topologies[I][J].Dest, Cols);
   For K := 0 to Cols - 1 do Begin
    M.Topologies[I][J].Dest[K] := Bounded(KInt(R), 0, Rows - 1, 'destination topologie');
    Probability := KFloat(R, True);
    if (Probability <= 0) or (Probability > 1) Then Fail('Probabilite de transition invalide.');
   End;
  End;
 End;
 KExpect(R, '</Topology>'); Token := KToken(R);
 if (Token <> '<Triples>') and (Token <> '<Tuples>') Then Fail('Transitions Kaldi absentes.');
 N := Bounded(KInt(R), 1, 1000000, 'nombre transitions'); SetLength(M.Transitions, N); TransCount := 1;
 For I := 0 to N - 1 do Begin
  Phone := Bounded(KInt(R), 1, High(M.PhoneTopology), 'phone transition');
  J := Bounded(M.PhoneTopology[Phone], 0, High(M.Topologies), 'index topologie');
  State := Bounded(KInt(R), 0, Length(M.Topologies[J]) - 2, 'etat transition');
  M.Transitions[I].Phone := Phone; M.Transitions[I].State := State;
  M.Transitions[I].Pdf := KInt(R);
  if Token = '<Tuples>' Then if KInt(R) <> M.Transitions[I].Pdf Then Fail('PDF self-loop distinct non pris en charge.');
  M.Transitions[I].First := TransCount; Inc(TransCount, Length(M.Topologies[J][State].Dest));
 End;
 if Token = '<Triples>' Then KExpect(R, '</Triples>') else KExpect(R, '</Tuples>');
 KExpect(R, '<LogProbs>'); KReals(R, M.LogProbs, Rows, Cols, False);
 if Rows <> TransCount Then Fail('Nombre de probabilites Kaldi incoherent.');
 KExpect(R, '</LogProbs>'); KExpect(R, '</TransitionModel>');
 KExpect(R, '<DIMENSION>'); M.Dimension := Bounded(KInt(R), 1, 100, 'dimension GMM');
 KExpect(R, '<NUMPDFS>'); N := Bounded(KInt(R), 1, 100000, 'nombre PDF'); SetLength(M.PDFs, N);
 For I := 0 to N - 1 do Begin
  KExpect(R, '<DiagGMM>'); KExpect(R, '<GCONSTS>'); KReals(R, M.PDFs[I].Constants, Rows, Cols, False);
  M.PDFs[I].Count := Bounded(Rows, 1, 4096, 'gaussiennes par PDF');
  KExpect(R, '<WEIGHTS>'); KReals(R, UnusedReals, Rows, Cols, False);
  if Rows <> M.PDFs[I].Count Then Fail('Poids GMM incoherents.');
  KExpect(R, '<MEANS_INVVARS>'); KReals(R, M.PDFs[I].Means, Rows, Cols, True);
  if (Rows <> M.PDFs[I].Count) or (Cols <> M.Dimension) Then Fail('Moyennes GMM incoherentes.');
  KExpect(R, '<INV_VARS>'); KReals(R, M.PDFs[I].InverseVars, Rows, Cols, True);
  if (Rows <> M.PDFs[I].Count) or (Cols <> M.Dimension) Then Fail('Variances GMM incoherentes.');
  For J := 0 to High(M.PDFs[I].InverseVars) do if M.PDFs[I].InverseVars[J] <= 0 Then Fail('Variance GMM non positive.');
  KExpect(R, '</DiagGMM>');
 End;
 For I := 0 to High(M.Transitions) do Bounded(M.Transitions[I].Pdf, 0, High(M.PDFs), 'pdf transition');
 Data := ModelMember(Path, Archive, 'tree', True); KHeader(R, Data, 'tree');
 KExpect(R, 'ContextDependency'); M.ContextWidth := KInt(R); M.CentralPosition := KInt(R);
 if not (((M.ContextWidth = 3) and (M.CentralPosition = 1)) or
  ((M.ContextWidth = 1) and (M.CentralPosition = 0))) Then Fail('Contexte Kaldi non monophone/triphone.');
 KExpect(R, 'ToPdf'); M.TreeRoot := ReadTreeNode(R, M, 0); KExpect(R, 'EndContextDependency');
 Data := ModelMember(Path, Archive, 'lda.mat', False);
 if Data <> '' Then Begin
  KHeader(R, Data, 'lda.mat'); KReals(R, M.LDA, M.LdaRows, M.LdaCols, True);
  if (M.LdaRows <> M.Dimension) or not (M.LdaCols in [91,92]) Then Fail('LDA attendue: D x 91 ou D x 92.');
  if (Number(JsonValue(M.Metadata, 'splice_left_context'), 'splice_left_context') <> 3) or
     (Number(JsonValue(M.Metadata, 'splice_right_context'), 'splice_right_context') <> 3) Then Fail('LDA: contexte +/-3 requis.');
 End else if not (M.Dimension in [13,39]) Then Fail('Dimension GMM sans LDA non prise en charge.');
 WriteLn(StdErr, 'Modele Kaldi charge: ', Length(M.PDFs), ' PDF, ', M.Dimension, ' dimensions, ', Length(M.Transitions), ' transitions.');
End;

Const
 AlignWindow = 400;
 AlignHop = 160;
 AlignFFT = 512;
 AlignBands = 40;
 AlignDims = 13;
Type
 TFeature = array[0..AlignDims - 1] of Double;
 TFeatures = array of TFeature;
 TAcousticFeatures = array of TRealVector;
 TSpectrum = array[0..AlignFFT - 1] of Double;

Procedure AcousticFFT(var Re, Im: TSpectrum);
Var I, J, K, Size, Half: Integer; A, B, C, S, Angle: Double;
Begin
 J := 0;
 For I := 1 to AlignFFT - 1 do Begin
  K := AlignFFT div 2;
  While (J and K) <> 0 do Begin J := J xor K; K := K div 2; End;
  J := J xor K;
  if I < J Then Begin
   A := Re[I]; Re[I] := Re[J]; Re[J] := A;
   A := Im[I]; Im[I] := Im[J]; Im[J] := A;
  End;
 End;
 Size := 2;
 While Size <= AlignFFT do Begin
  Half := Size div 2;
  For K := 0 to Half - 1 do Begin
   Angle := -2 * Pi * K / Size; C := Cos(Angle); S := Sin(Angle);
   I := K;
   While I < AlignFFT do Begin
    J := I + Half;
    A := C * Re[J] - S * Im[J]; B := S * Re[J] + C * Im[J];
    Re[J] := Re[I] - A; Im[J] := Im[I] - B;
    Re[I] := Re[I] + A; Im[I] := Im[I] + B;
    Inc(I, Size);
   End;
  End;
  Size := Size * 2;
 End;
End;

Procedure ExtractFeatures(const Audio: TSamples; const M: TKaldiModel; out Features: TAcousticFeatures);
Var
 Re, Im: TSpectrum;
 Filters: array[0..AlignBands - 1, 0..AlignFFT div 2] of Double;
 DCT: array[0..AlignDims - 1, 0..AlignBands - 1] of Double;
 Window: array[0..AlignWindow - 1] of Double;
 Edges: array[0..AlignBands + 1] of Double;
 Bands: array[0..AlignBands - 1] of Double;
 Base, Delta: TFeatures;
 Frame, I, J, K, Index, Offset: Integer;
 MelLow, MelHigh, Mel, Energy, X, Power, Mean, Lift: Double;
Begin
 SetLength(Base, (Length(Audio) + AlignHop div 2) div AlignHop);
 if Length(Base) = 0 Then Fail('Audio trop court pour les MFCC Kaldi.');
 MelLow := 1127 * Ln(1 + M.LowFrequency / 700);
 MelHigh := 1127 * Ln(1 + M.HighFrequency / 700);
 For I := 0 to M.MelBins + 1 do Edges[I] := MelLow + (MelHigh - MelLow) * I / (M.MelBins + 1);
 For I := 0 to AlignWindow - 1 do Begin
  X := 0.5 - 0.5 * Cos(2 * Pi * I / (AlignWindow - 1));
  if X <= 0 Then Window[I] := 0 else Window[I] := Exp(0.85 * Ln(X));
 End;
 For J := 0 to M.MelBins - 1 do Begin
  For K := 0 to AlignFFT div 2 do Begin
   Mel := 1127 * Ln(1 + K * (TargetRate / AlignFFT) / 700); X := 0;
   if (Mel > Edges[J]) and (Mel < Edges[J + 1]) Then
    X := (Mel - Edges[J]) / (Edges[J + 1] - Edges[J])
   else if (Mel >= Edges[J + 1]) and (Mel < Edges[J + 2]) Then
    X := (Edges[J + 2] - Mel) / (Edges[J + 2] - Edges[J + 1]);
   Filters[J, K] := X;
  End;
  DCT[0, J] := Sqrt(1 / M.MelBins);
  For I := 1 to AlignDims - 1 do
   DCT[I, J] := Sqrt(2 / M.MelBins) * Cos(Pi * I * (J + 0.5) / M.MelBins);
 End;
 For Frame := 0 to High(Base) do Begin
  FillChar(Re, SizeOf(Re), 0); FillChar(Im, SizeOf(Im), 0); Mean := 0; Energy := 0;
  For I := 0 to AlignWindow - 1 do Begin
   Index := Frame * AlignHop + AlignHop div 2 - AlignWindow div 2 + I;
   While (Index < 0) or (Index >= Length(Audio)) do
    if Index < 0 Then Index := -Index - 1 else Index := 2 * Length(Audio) - 1 - Index;
   Re[I] := Audio[Index] * 32768; Mean := Mean + Re[I];
  End;
  Mean := Mean / AlignWindow;
  For I := 0 to AlignWindow - 1 do Begin Re[I] := Re[I] - Mean; Energy := Energy + Re[I] * Re[I]; End;
  For I := AlignWindow - 1 downto 1 do Re[I] := Re[I] - 0.97 * Re[I - 1];
  Re[0] := Re[0] * 0.03;
  For I := 0 to AlignWindow - 1 do Re[I] := Re[I] * Window[I];
  AcousticFFT(Re, Im);
  For J := 0 to M.MelBins - 1 do Bands[J] := 0;
  For K := 0 to AlignFFT div 2 do Begin
   Power := Re[K] * Re[K] + Im[K] * Im[K];
   For J := 0 to M.MelBins - 1 do Bands[J] := Bands[J] + Filters[J, K] * Power;
  End;
  For J := 0 to M.MelBins - 1 do Begin
   if Bands[J] < 1.1920928955078125E-7 Then Bands[J] := 1.1920928955078125E-7;
   Bands[J] := Ln(Bands[J]);
  End;
  For I := 0 to AlignDims - 1 do Begin
   X := 0;
   For J := 0 to M.MelBins - 1 do X := X + DCT[I, J] * Bands[J];
   Lift := 1; if M.Lifter > 0 Then Lift := 1 + M.Lifter / 2 * Sin(Pi * I / M.Lifter);
   Base[Frame][I] := X * Lift;
  End;
  if M.UseEnergy Then Begin
   if Energy < 1.1920928955078125E-7 Then Energy := 1.1920928955078125E-7;
   Base[Frame][0] := Ln(Energy);
  End;
 End;
 if JsonValue(M.Metadata, 'uses_cmvn') = 'true' Then
  For I := 0 to AlignDims - 1 do Begin
   Mean := 0;
   For Frame := 0 to High(Base) do Mean := Mean + Base[Frame][I];
   Mean := Mean / Length(Base);
   For Frame := 0 to High(Base) do Base[Frame][I] := Base[Frame][I] - Mean;
  End;
 SetLength(Features, Length(Base));
 if (Length(M.LDA) = 0) and (M.Dimension = 39) Then Begin
  SetLength(Delta, Length(Base));
  For Frame := 0 to High(Base) do For I := 0 to 12 do Begin
   X := 0;
   For J := -2 to 2 do X := X + J * Base[Max(0, Min(High(Base), Frame + J))][I];
   Delta[Frame][I] := X / 10;
  End;
 End;
 For Frame := 0 to High(Base) do Begin
  SetLength(Features[Frame], M.Dimension);
  if Length(M.LDA) > 0 Then Begin
   For I := 0 to M.Dimension - 1 do Begin
    X := 0; Offset := I * M.LdaCols;
    For J := -3 to 3 do For K := 0 to 12 do
     X := X + M.LDA[Offset + (J + 3) * 13 + K] * Base[Max(0, Min(High(Base), Frame + J))][K];
    if M.LdaCols = 92 Then X := X + M.LDA[Offset + 91];
    Features[Frame][I] := X;
   End;
  End else For I := 0 to 12 do Begin
   Features[Frame][I] := Base[Frame][I];
   if M.Dimension = 39 Then Begin
    Features[Frame][I + 13] := Delta[Frame][I]; X := 0;
    For J := -2 to 2 do X := X + J * Delta[Max(0, Min(High(Base), Frame + J))][I];
    Features[Frame][I + 26] := X / 10;
   End;
  End;
 End;
End;

Type
 TLexEntry = record WordText: string; Phones: TIntVector; Probability: Double; End;
 TLexicon = array of TLexEntry;
 TWordList = array of TLexEntry;
 TPhoneNode = record Phone, Owner: Integer; Optional: Boolean; End;
 TPhoneNodes = array of TPhoneNode;
 TContextNode = record Node, LeftNode, RightNode, FirstState: Integer; End;
 TContexts = array of TContextNode;
 TArc = record Source: Integer; Score: Double; End;
 TAlignState = record
  Pdf, PhoneNode: Integer;
  Incoming: array of TArc;
  Initial, FinalScore: Double;
 End;
 TAlignStates = array of TAlignState;
Const ImpossibleScore = -1E100;

Function NormalizeFrench(const Text: string): string;
Var I, Code, Next: Integer;
Begin
 Result := ''; I := 1;
 While I <= Length(Text) do Begin
  Code := Ord(Text[I]); Inc(I);
  if (Code >= $C2) and (Code <= $DF) and (I <= Length(Text)) Then Begin
   Next := Ord(Text[I]); Inc(I); Code := ((Code and 31) shl 6) or (Next and 63);
  End else if (Code >= $E0) and (Code <= $EF) and (I + 1 <= Length(Text)) Then Begin
   Code := ((Code and 15) shl 12) or ((Ord(Text[I]) and 63) shl 6) or (Ord(Text[I + 1]) and 63); Inc(I, 2);
  End else if Code >= 128 Then Begin
   While (I <= Length(Text)) and ((Ord(Text[I]) and $C0) = $80) do Inc(I);
   Code := 32;
  End;
  if (Code >= 65) and (Code <= 90) Then Inc(Code, 32);
  if (Code >= $C0) and (Code <= $DE) and (Code <> $D7) Then Inc(Code, 32);
  if Code = $152 Then Code := $153;
  if Code = $2019 Then Code := 39;
  if not (((Code >= 97) and (Code <= 122)) or ((Code >= 48) and (Code <= 57)) or
    ((Code >= $C0) and (Code <= $36F)) or (Code = 39)) Then Code := 32;
  if Code < 128 Then Result := Result + Chr(Code)
  else Result := Result + Chr($C0 or (Code shr 6)) + Chr($80 or (Code and 63));
 End;
 Result := Trim(Result);
End;

Function PhoneID(const M: TKaldiModel; const Name: string): Integer;
Var I: Integer;
Begin
 For I := 1 to High(M.PhoneNames) do if M.PhoneNames[I] = Name Then Exit(I);
 Fail('Phoneme du dictionnaire absent du modele: ' + Name); Result := -1;
End;

Procedure SortLexicon(var Lex: TLexicon; Left, Right: Integer);
Var I, J: Integer; Pivot: string; Swap: TLexEntry;
Begin
 I := Left; J := Right; Pivot := Lex[(Left + Right) div 2].WordText;
 repeat
  While Lex[I].WordText < Pivot do Inc(I);
  While Lex[J].WordText > Pivot do Dec(J);
  if I <= J Then Begin Swap := Lex[I]; Lex[I] := Lex[J]; Lex[J] := Swap; Inc(I); Dec(J); End;
 until I > J;
 if Left < J Then SortLexicon(Lex, Left, J);
 if I < Right Then SortLexicon(Lex, I, Right);
End;

Procedure LoadLexicon(const Name: string; const M: TKaldiModel; out Lex: TLexicon);
Var Data, Line, WordText, Token: string; Start, Finish, P, N, I, Count, Code: Integer;
 Fields: TStringVector; Probability, NumericValue: Double;
Begin
 Data := LoadText(Name); Start := 1; Count := 0; SetLength(Lex, 1024);
 While Start <= Length(Data) do Begin
  Finish := Start; While (Finish <= Length(Data)) and (Data[Finish] <> #10) do Inc(Finish);
  Line := Trim(Copy(Data, Start, Finish - Start)); Start := Finish + 1;
  if (Line = '') or (Line[1] = '#') Then Continue;
  P := 1; WordText := NextToken(Line, P);
  if (WordText = '<eps>') or (WordText = '<unk>') or (WordText[1] = '[') Then Continue;
  N := 0; SetLength(Fields, 0);
  repeat
   Token := NextToken(Line, P); if Token = '' Then Break;
   SetLength(Fields, N + 1); Fields[N] := Token; Inc(N);
  until False;
  if N = 0 Then Fail('Prononciation absente: ' + WordText);
  { Lexique MFA: mot [p_pron [p_sil corr_sil corr_non_sil]] phonemes. }
  I := 0; Probability := 1;
  While I < N do Begin
   Val(Fields[I], NumericValue, Code); if Code <> 0 Then Break;
   if (NumericValue < 0) or (NumericValue > 1E6) Then Fail('Valeur lexicale hors limites: ' + WordText);
   if I = 0 Then Probability := Number(Fields[I], 'probabilite lexicale');
   Inc(I);
  End;
  if not (I in [0,1,4]) or (I = N) or (Probability <= 0) or (Probability > 1) Then
   Fail('Format/probabilite du dictionnaire MFA invalide: ' + WordText);
  if Count >= 1000000 Then Fail('Dictionnaire trop grand.');
  if Count = Length(Lex) Then SetLength(Lex, Count * 2);
  Lex[Count].WordText := NormalizeFrench(WordText); Lex[Count].Probability := Probability;
  SetLength(Lex[Count].Phones, N - I);
  For P := I to N - 1 do Lex[Count].Phones[P - I] := PhoneID(M, Fields[P]);
  Inc(Count);
 End;
 SetLength(Lex, Count); if Count = 0 Then Fail('Dictionnaire vide.');
 SortLexicon(Lex, 0, Count - 1);
End;

Function LookupWord(const Lex: TLexicon; const WordText: string): Integer;
Var L, R, Mid, Best: Integer;
Begin
 L := 0; R := Length(Lex);
 While L < R do Begin Mid := (L + R) div 2; if Lex[Mid].WordText < WordText Then L := Mid + 1 else R := Mid; End;
 if (L >= Length(Lex)) or (Lex[L].WordText <> WordText) Then Exit(-1);
 Best := L;
 While (L < Length(Lex)) and (Lex[L].WordText = WordText) do Begin
  if Lex[L].Probability > Lex[Best].Probability Then Best := L;
  Inc(L);
 End;
 Result := Best;
End;

Procedure TranscriptWords(const Text: string; const Lex: TLexicon; out Words: TWordList);
Var Normalized, Token: string; P: Integer;

 Procedure Append(const WordText: string; Depth: Integer);
 Var Index, Split, N: Integer;
 Begin
  if (WordText = '') or (WordText = '''') Then Exit;
  if Depth > 16 Then Fail('Trop d''elisions imbriquees.');
  Index := LookupWord(Lex, WordText);
  if Index < 0 Then Begin
   Split := Pos('''', WordText);
   if (Split > 1) and (Split < Length(WordText)) Then Begin
    Append(Copy(WordText, 1, Split), Depth + 1);
    Append(Copy(WordText, Split + 1, Length(WordText)), Depth + 1); Exit;
   End;
   Fail('Mot absent du dictionnaire MFA: ' + WordText);
  End;
  N := Length(Words); if N >= 4096 Then Fail('Transcription trop longue pour l''alignement.');
  SetLength(Words, N + 1); Words[N] := Lex[Index];
 End;

Begin
 SetLength(Words, 0); Normalized := NormalizeFrench(Text); P := 1;
 repeat Token := NextToken(Normalized, P); if Token = '' Then Break; Append(Token, 0); until False;
 if Length(Words) = 0 Then Fail('La transcription ne contient aucun mot alignable.');
End;

Function TransitionIndex(const M: TKaldiModel; Phone, State, Pdf: Integer): Integer;
Var L, R, Mid, Compare: Integer;
Begin
 L := 0; R := High(M.Transitions);
 While L <= R do Begin
  Mid := (L + R) div 2;
  Compare := M.Transitions[Mid].Phone - Phone;
  if Compare = 0 Then Compare := M.Transitions[Mid].State - State;
  if Compare = 0 Then Compare := M.Transitions[Mid].Pdf - Pdf;
  if Compare = 0 Then Exit(Mid);
  if Compare < 0 Then L := Mid + 1 else R := Mid - 1;
 End;
 Fail('Transition (phone, etat, pdf) absente du modele Kaldi.'); Result := -1;
End;

Procedure BuildAlignmentGraph(const M: TKaldiModel; const Words: TWordList;
 out Nodes: TPhoneNodes; out States: TAlignStates);
Var Contexts: TContexts; P, I, J, K, L, R, C, D, N, Phone, LeftPhone, RightPhone,
 Topo, State, PDF, Transition, Dest, First, Target, Sil: Integer;
 InitialSilence, SilenceProbability, Probability, SelfProb, Weight: Double;

 Procedure AddPhone(ID, Owner: Integer; Optional: Boolean);
 Var N: Integer;
 Begin
  N := Length(Nodes); SetLength(Nodes, N + 1);
  Nodes[N].Phone := ID; Nodes[N].Owner := Owner; Nodes[N].Optional := Optional;
 End;

 Function Adjacent(A, B: Integer): Boolean;
 Begin
  Result := B = A + 1;
  if (B = A + 2) and (A + 1 >= 0) and (A + 1 < Length(Nodes)) Then Result := Nodes[A + 1].Optional;
 End;

 Procedure AddArc(Source, Destination: Integer; Score: Double);
 Var N: Integer;
 Begin
  N := Length(States[Destination].Incoming); SetLength(States[Destination].Incoming, N + 1);
  States[Destination].Incoming[N].Source := Source; States[Destination].Incoming[N].Score := Score;
 End;

Begin
 SetLength(Nodes, 0); SetLength(States, 0); SetLength(Contexts, 0);
 Sil := PhoneID(M, JsonValue(M.Metadata, 'optional_silence_phone'));
 InitialSilence := Number(JsonValue(M.Metadata, 'initial_silence_probability'), 'initial_silence_probability');
 SilenceProbability := Number(JsonValue(M.Metadata, 'silence_probability'), 'silence_probability');
 if (InitialSilence <= 0) or (InitialSilence >= 1) or (SilenceProbability <= 0) or (SilenceProbability >= 1) Then
  Fail('Probabilites de silence hors ]0,1[.');
 AddPhone(Sil, -1, True);
 For I := 0 to High(Words) do Begin
  For J := 0 to High(Words[I].Phones) do AddPhone(Words[I].Phones[J], I, False);
  AddPhone(Sil, -1, True);
 End;
 if Length(Nodes) > 12000 Then Fail('Trop de phonemes pour l''alignement.');
 For P := 0 to High(Nodes) do
  For L := Max(-1, P - 2) to P - 1 do if Adjacent(L, P) Then
   For R := P + 1 to Min(Length(Nodes), P + 2) do if Adjacent(P, R) Then Begin
    C := Length(Contexts); SetLength(Contexts, C + 1);
    Contexts[C].Node := P; Contexts[C].LeftNode := L; Contexts[C].RightNode := R;
    Contexts[C].FirstState := Length(States);
    Phone := Nodes[P].Phone; Bounded(Phone, 1, High(M.PhoneTopology), 'phone graphe');
    Topo := Bounded(M.PhoneTopology[Phone], 0, High(M.Topologies), 'topologie graphe');
    N := Length(M.Topologies[Topo]) - 1; First := Length(States); SetLength(States, First + N);
    LeftPhone := 0; RightPhone := 0;
    if L >= 0 Then LeftPhone := Nodes[L].Phone;
    if R < Length(Nodes) Then RightPhone := Nodes[R].Phone;
    For J := 0 to N - 1 do Begin
     States[First + J].Pdf := TreePdf(M, LeftPhone, Phone, RightPhone, M.Topologies[Topo][J].PdfClass);
     States[First + J].PhoneNode := P;
     States[First + J].Initial := ImpossibleScore; States[First + J].FinalScore := ImpossibleScore;
    End;
    if L = -1 Then Begin
     if Nodes[P].Optional Then Probability := InitialSilence else Probability := 1 - InitialSilence;
     States[First].Initial := Ln(Probability);
    End;
   End;
 if Length(States) > 65534 Then Fail('Graphe d''alignement trop grand.');
 For C := 0 to High(Contexts) do Begin
  P := Contexts[C].Node; Phone := Nodes[P].Phone;
  Topo := M.PhoneTopology[Phone]; N := Length(M.Topologies[Topo]) - 1; First := Contexts[C].FirstState;
  For J := 0 to N - 1 do Begin
   State := First + J; PDF := States[State].Pdf;
   Transition := TransitionIndex(M, Phone, J, PDF); SelfProb := 0;
   For K := 0 to High(M.Topologies[Topo][J].Dest) do
    if M.Topologies[Topo][J].Dest[K] = J Then SelfProb := Exp(M.LogProbs[M.Transitions[Transition].First + K]);
   if SelfProb >= 1 Then Fail('Self-loop de probabilite 1.');
   For K := 0 to High(M.Topologies[Topo][J].Dest) do Begin
    Dest := M.Topologies[Topo][J].Dest[K]; Weight := M.LogProbs[M.Transitions[Transition].First + K];
    { Echelles standard d'alignement: transitions 1, self-loops 0.1. }
    if Dest = J Then Weight := 0.1 * Weight else Weight := Weight - 0.9 * Ln(1 - SelfProb);
    if Dest < N Then AddArc(State, First + Dest, Weight)
    else if Contexts[C].RightNode = Length(Nodes) Then Begin
     if not Nodes[P].Optional Then Weight := Weight + Ln(1 - SilenceProbability);
     States[State].FinalScore := Weight;
    End else Begin
     R := Contexts[C].RightNode;
     if Nodes[R].Optional Then Weight := Weight + Ln(SilenceProbability)
     else if R = P + 2 Then Weight := Weight + Ln(1 - SilenceProbability);
     For D := C + 1 to High(Contexts) do Begin
      if Contexts[D].Node > R Then Break;
      if (Contexts[D].Node = R) and (Contexts[D].LeftNode = P) Then Begin
       Target := Contexts[D].FirstState; AddArc(State, Target, Weight);
      End;
     End;
    End;
   End;
  End;
 End;
End;

Function GMMScore(const G: TGMM; const Features: TRealVector): Double;
Var I, J, Offset: Integer; Value, Best, Sum: Double; Scores: array of Double;
Begin
 SetLength(Scores, G.Count); Best := ImpossibleScore;
 For I := 0 to G.Count - 1 do Begin
  Value := G.Constants[I]; Offset := I * Length(Features);
  For J := 0 to High(Features) do Value := Value + G.Means[Offset + J] * Features[J] -
   0.5 * G.InverseVars[Offset + J] * Features[J] * Features[J];
  Scores[I] := Value; if Value > Best Then Best := Value;
 End;
 Sum := 0;
 For I := 0 to G.Count - 1 do if Scores[I] > Best - 40 Then Sum := Sum + Exp(Scores[I] - Best);
 Result := Best + Ln(Sum);
End;

Procedure ViterbiAlign(const Features: TAcousticFeatures; const M: TKaldiModel;
 const States: TAlignStates; out Path: TIntVector);
Var Previous, Current, Scores: array of Double; Marks: TIntVector;
 Back: array of Word; T, S, I, Source, PDF, BestState: Integer; Value, Best, Peak: Double;
Begin
 if Int64(Length(Features)) * Length(States) > 32000000 Then
  Fail('Alignement trop grand (32 millions de cellules); decouper le WAV et le texte.');
 SetLength(Back, Length(Features) * Length(States));
 SetLength(Previous, Length(States)); SetLength(Current, Length(States));
 SetLength(Scores, Length(M.PDFs)); SetLength(Marks, Length(M.PDFs));
 For I := 0 to High(Marks) do Marks[I] := -1;
 For T := 0 to High(Features) do Begin
  Peak := ImpossibleScore;
  For S := 0 to High(States) do Begin
   Best := ImpossibleScore; BestState := 0;
   if T = 0 Then Best := States[S].Initial
   else For I := 0 to High(States[S].Incoming) do Begin
    Source := States[S].Incoming[I].Source;
    Value := Previous[Source] + States[S].Incoming[I].Score;
    if Value > Best Then Begin Best := Value; BestState := Source; End;
   End;
   if Best > ImpossibleScore / 2 Then Begin
    PDF := States[S].Pdf;
    if Marks[PDF] <> T Then Begin Scores[PDF] := GMMScore(M.PDFs[PDF], Features[T]); Marks[PDF] := T; End;
    Best := Best + 0.1 * Scores[PDF];
   End;
   Current[S] := Best; Back[T * Length(States) + S] := BestState;
   if Best > Peak Then Peak := Best;
  End;
  if Peak <= ImpossibleScore / 2 Then Fail('Aucun chemin acoustique possible.');
  For S := 0 to High(States) do Previous[S] := Current[S] - Peak;
 End;
 Best := ImpossibleScore; BestState := -1;
 For S := 0 to High(States) do Begin
  Value := Previous[S] + States[S].FinalScore;
  if Value > Best Then Begin Best := Value; BestState := S; End;
 End;
 if (BestState < 0) or (Best <= ImpossibleScore / 2) Then Fail('Audio trop court ou texte impossible a aligner.');
 SetLength(Path, Length(Features)); S := BestState;
 For T := High(Path) downto 0 do Begin
  Path[T] := States[S].PhoneNode; S := Back[T * Length(States) + S];
 End;
End;

Function GridQuote(const Text: string): string;
Var I: Integer;
Begin
 Result := '"';
 For I := 1 to Length(Text) do Begin Result := Result + Text[I]; if Text[I] = '"' Then Result := Result + '"'; End;
 Result := Result + '"';
End;

Procedure WriteAlignmentGrid(const FileName: string; SampleCount: Integer; const M: TKaldiModel;
 const Words: TWordList; const Nodes: TPhoneNodes; const Path: TIntVector);
Var S: TBinary; Tier, T, First, Last, Owner, NextOwner, Count, Index: Integer; LabelText: string;

 Procedure PutLine(const Text: string);
 Var Value: string;
 Begin Value := Text + LineEnding; WriteBytes(S, Value[1], Length(Value)); End;

 Function LabelID(Frame: Integer): Integer;
 Begin
  Result := Path[Frame]; if Tier = 1 Then Result := Nodes[Result].Owner;
 End;

Begin
 OpenBinary(S, FileName, True);
 PutLine('File type = "ooTextFile"'); PutLine('Object class = "TextGrid"'); PutLine('');
 PutLine('xmin = 0'); PutLine('xmax = ' + AudioDuration(SampleCount));
 PutLine('tiers? <exists>'); PutLine('size = 2'); PutLine('item []:');
 For Tier := 1 to 2 do Begin
  Count := 1;
  For T := 1 to High(Path) do if LabelID(T) <> LabelID(T - 1) Then Inc(Count);
  PutLine('    item [' + IntToStr(Tier) + ']:'); PutLine('        class = "IntervalTier"');
  if Tier = 1 Then LabelText := 'words' else LabelText := 'phones';
  PutLine('        name = ' + GridQuote(LabelText)); PutLine('        xmin = 0');
  PutLine('        xmax = ' + AudioDuration(SampleCount)); PutLine('        intervals: size = ' + IntToStr(Count));
  First := 0; Index := 0;
  While First < Length(Path) do Begin
   Last := First + 1; Owner := LabelID(First);
   While Last < Length(Path) do Begin NextOwner := LabelID(Last); if NextOwner <> Owner Then Break; Inc(Last); End;
   LabelText := '';
   if Tier = 1 Then Begin if Owner >= 0 Then LabelText := Words[Owner].WordText; End
   else LabelText := M.PhoneNames[Nodes[Owner].Phone];
   Inc(Index); PutLine('        intervals [' + IntToStr(Index) + ']:');
   PutLine('            xmin = ' + AudioDuration(Min(SampleCount, First * AlignHop)));
   if Last = Length(Path) Then T := SampleCount else T := Min(SampleCount, Last * AlignHop);
   PutLine('            xmax = ' + AudioDuration(T)); PutLine('            text = ' + GridQuote(LabelText));
   First := Last;
  End;
 End;
 CloseBinary(S);
End;

Procedure InternalAlign(const Audio: TSamples; const Text, Dictionary, Acoustic, Grid: string);
Var M: TKaldiModel; Lex: TLexicon; Words: TWordList; Nodes: TPhoneNodes;
 States: TAlignStates; Features: TAcousticFeatures; Path: TIntVector;
Begin
 WriteLn(StdErr, 'Alignement interne Pascal avec donnees MFA/Kaldi...');
 LoadKaldiModel(Acoustic, M); LoadLexicon(Dictionary, M, Lex); TranscriptWords(Text, Lex, Words);
 SetLength(Lex, 0);
 ExtractFeatures(Audio, M, Features); BuildAlignmentGraph(M, Words, Nodes, States);
 ViterbiAlign(Features, M, States, Path);
 WriteAlignmentGrid(Grid, Length(Audio), M, Words, Nodes, Path);
End;

{ Inference Whisper/Silero en Pascal procedural. Les conventions de tenseurs
  suivent les formats publics GGML et les architectures de leurs auteurs.
  Voir THIRD_PARTY_NOTICES.md pour les licences et references. }
Type
 TTensor = record Name: string; Dims: array[0..3] of Integer; Rank: Integer; Data: TSamples; End;
 TTensors = array of TTensor;
 TMatrix = record Rows, Cols: Integer; Data: TSamples; End;
 TAttentionWeights = record Q, QB, K, V, VB, O, OB, LN, LNB: Integer; End;
 TWhisperLayer = record
  Attention, Cross: TAttentionWeights;
  MLP0, MLP0B, MLP2, MLP2B, MLPNorm, MLPNormB: Integer;
 End;
 TWhisperModel = record
  Tensors: TTensors;
  Vocab: TStringVector;
  AudioContext, AudioWidth, AudioHeads, AudioLayers, TextContext, TextWidth, TextHeads, TextLayers, MelCount, VocabCount: Integer;
  Conv1, Conv1B, Conv2, Conv2B, AudioPosition, AudioNorm, AudioNormB, TextPosition, TextNorm, TextNormB, Embedding: Integer;
  Encoder, Decoder: array of TWhisperLayer;
  Filters: TSamples;
  EOT, SOT, French, Transcribe, NoSpeech, NoTimestamps: Integer;
 End;
 TDecoderCache = record SelfK, SelfV, CrossK, CrossV: TMatrix; End;
 TDecoderCaches = array of TDecoderCache;
 TSpeechRange = record First, Last: Integer; End;
 TSpeechRanges = array of TSpeechRange;
 TSileroModel = record
  Tensors: TTensors;
  Basis, IH, IHB, HH, HHB, FinalWeight, FinalBias: Integer;
  Conv, Bias: array[0..3] of Integer;
 End;

Function HalfToSingle(Value: Word): Single;
Var Bits, Mantissa, Exponent: LongWord;
Begin
 Bits := LongWord(Value and $8000) shl 16;
 Mantissa := Value and $3FF; Exponent := (Value shr 10) and 31;
 if Exponent = 0 Then Begin
  if Mantissa <> 0 Then Begin
   Exponent := 113;
   While (Mantissa and $400) = 0 do Begin Mantissa := Mantissa shl 1; Dec(Exponent); End;
   Bits := Bits or (Exponent shl 23) or ((Mantissa and $3FF) shl 13);
  End;
 End else if Exponent = 31 Then Bits := Bits or $7F800000 or (Mantissa shl 13)
 else Bits := Bits or ((Exponent + 112) shl 23) or (Mantissa shl 13);
 Move(Bits, Result, 4);
End;

Procedure ReadFloatArray(var S: TBinary; Count, Kind: Integer; out Values: TSamples);
Var I: Integer; Raw: array of Word;
Begin
 if not (Kind in [0,1]) Then Fail('Tenseur GGML quantifie/non pris en charge; utiliser un modele FP16 ou FP32.');
 if (Count < 0) or (Int64(Count) * (4 - Kind * 2) > S.Size - S.Position) Then Fail('Tenseur GGML tronque.');
 SetLength(Values, Count);
 if Kind = 0 Then Begin if Count > 0 Then ReadBytes(S, Values[0], Count * 4); End
 else Begin
  SetLength(Raw, Count); if Count > 0 Then ReadBytes(S, Raw[0], Count * 2);
  For I := 0 to Count - 1 do Values[I] := HalfToSingle(Raw[I]);
 End;
 For I := 0 to Count - 1 do if IsNan(Values[I]) or IsInfinite(Values[I]) Then Fail('Poids GGML non fini.');
End;

Procedure ReadTensorTable(var S: TBinary; out Tensors: TTensors);
Var N, I, J, Count, NameLength, Kind: Integer; Total: Int64; Name: string;
Begin
 SetLength(Tensors, 0); Total := 0;
 While S.Position < S.Size do Begin
  N := Length(Tensors); if N >= 2000 Then Fail('Trop de tenseurs GGML.');
  SetLength(Tensors, N + 1);
  Tensors[N].Rank := Bounded(LongInt(U32(S)), 0, 4, 'rang GGML');
  NameLength := Bounded(LongInt(U32(S)), 1, 256, 'nom tenseur'); Kind := LongInt(U32(S));
  Count := 1;
  For I := 0 to 3 do Begin
   Tensors[N].Dims[I] := 1;
   if I < Tensors[N].Rank Then Tensors[N].Dims[I] := Bounded(LongInt(U32(S)), 1, 100000, 'dimension tenseur');
   if Int64(Count) * Tensors[N].Dims[I] > 300000000 Then Fail('Tenseur GGML trop grand.');
   Count := Count * Tensors[N].Dims[I];
  End;
  Total := Total + Int64(Count) * 4;
  if Total > 1400000000 Then Fail('Modele trop grand pour cette implementation CPU (1,4 Go de poids FP32 maximum).');
  SetLength(Name, NameLength); ReadBytes(S, Name[1], NameLength);
  For J := 0 to N - 1 do if Tensors[J].Name = Name Then Fail('Tenseur GGML repete: ' + Name);
  Tensors[N].Name := Name; ReadFloatArray(S, Count, Kind, Tensors[N].Data);
 End;
End;

Function TensorID(const Tensors: TTensors; const Name: string; const Shape: array of Integer): Integer;
Var I, J: Integer;
Begin
 For I := 0 to High(Tensors) do if Tensors[I].Name = Name Then Begin
  For J := 0 to High(Shape) do if Tensors[I].Dims[J] <> Shape[J] Then Fail('Dimensions incorrectes: ' + Name);
  For J := Length(Shape) to 3 do if Tensors[I].Dims[J] <> 1 Then Fail('Dimensions supplementaires: ' + Name);
  Exit(I);
 End;
 Fail('Tenseur manquant: ' + Name); Result := -1;
End;

Procedure BindAttention(const T: TTensors; const Prefix, Norm: string; Width: Integer; out W: TAttentionWeights);
Begin
 W.Q := TensorID(T, Prefix + '.query.weight', [Width,Width]);
 W.QB := TensorID(T, Prefix + '.query.bias', [Width]);
 W.K := TensorID(T, Prefix + '.key.weight', [Width,Width]);
 W.V := TensorID(T, Prefix + '.value.weight', [Width,Width]);
 W.VB := TensorID(T, Prefix + '.value.bias', [Width]);
 W.O := TensorID(T, Prefix + '.out.weight', [Width,Width]);
 W.OB := TensorID(T, Prefix + '.out.bias', [Width]);
 W.LN := TensorID(T, Norm + '.weight', [Width]); W.LNB := TensorID(T, Norm + '.bias', [Width]);
End;

Procedure BindWhisperLayer(const T: TTensors; const Prefix: string; Width: Integer; Decoder: Boolean; out L: TWhisperLayer);
Begin
 BindAttention(T, Prefix + '.attn', Prefix + '.attn_ln', Width, L.Attention);
 if Decoder Then BindAttention(T, Prefix + '.cross_attn', Prefix + '.cross_attn_ln', Width, L.Cross);
 L.MLP0 := TensorID(T, Prefix + '.mlp.0.weight', [Width,Width*4]);
 L.MLP0B := TensorID(T, Prefix + '.mlp.0.bias', [Width*4]);
 L.MLP2 := TensorID(T, Prefix + '.mlp.2.weight', [Width*4,Width]);
 L.MLP2B := TensorID(T, Prefix + '.mlp.2.bias', [Width]);
 L.MLPNorm := TensorID(T, Prefix + '.mlp_ln.weight', [Width]);
 L.MLPNormB := TensorID(T, Prefix + '.mlp_ln.bias', [Width]);
End;

Procedure LoadWhisper(const FileName: string; out M: TWhisperModel);
Var S: TBinary; I, Count, N, Kind: Integer;
Begin
 OpenBinary(S, FileName, False);
 if U32(S) <> $67676D6C Then Fail('Modele Whisper GGML requis (GGUF/ONNX non pris en charge).');
 M.VocabCount := Bounded(LongInt(U32(S)), 51865, 51866, 'vocabulaire Whisper multilingue');
 M.AudioContext := Bounded(LongInt(U32(S)), 1500, 1500, 'contexte audio Whisper');
 M.AudioWidth := Bounded(LongInt(U32(S)), 4, 1536, 'largeur encodeur');
 M.AudioHeads := Bounded(LongInt(U32(S)), 1, 32, 'tetes encodeur');
 M.AudioLayers := Bounded(LongInt(U32(S)), 1, 32, 'couches encodeur');
 M.TextContext := Bounded(LongInt(U32(S)), 8, 448, 'contexte texte');
 M.TextWidth := Bounded(LongInt(U32(S)), 4, 1536, 'largeur decodeur');
 M.TextHeads := Bounded(LongInt(U32(S)), 1, 32, 'tetes decodeur');
 M.TextLayers := Bounded(LongInt(U32(S)), 1, 32, 'couches decodeur');
 M.MelCount := LongInt(U32(S)); Kind := LongInt(U32(S));
 if not (M.MelCount in [80,128]) or (M.AudioWidth <> M.TextWidth) or
  (M.AudioWidth mod M.AudioHeads <> 0) or (M.TextWidth mod M.TextHeads <> 0) Then Fail('Architecture Whisper non prise en charge.');
 if not (Kind in [0,1]) Then Fail('Modele Whisper FP16/FP32 non quantifie requis.');
 if (U32(S) <> LongWord(M.MelCount)) or (U32(S) <> 201) Then Fail('Filtres mel Whisper invalides.');
 ReadFloatArray(S, M.MelCount * 201, 0, M.Filters);
 Count := Bounded(LongInt(U32(S)), 50257, M.VocabCount, 'tokens GGML');
 SetLength(M.Vocab, M.VocabCount);
 For I := 0 to Count - 1 do Begin
  N := Bounded(LongInt(U32(S)), 0, 4096, 'longueur token'); SetLength(M.Vocab[I], N);
  if N > 0 Then ReadBytes(S, M.Vocab[I][1], N);
 End;
 ReadTensorTable(S, M.Tensors); CloseBinary(S);
 M.Conv1 := TensorID(M.Tensors, 'encoder.conv1.weight', [3,M.MelCount,M.AudioWidth]);
 M.Conv1B := TensorID(M.Tensors, 'encoder.conv1.bias', [1,M.AudioWidth]);
 M.Conv2 := TensorID(M.Tensors, 'encoder.conv2.weight', [3,M.AudioWidth,M.AudioWidth]);
 M.Conv2B := TensorID(M.Tensors, 'encoder.conv2.bias', [1,M.AudioWidth]);
 M.AudioPosition := TensorID(M.Tensors, 'encoder.positional_embedding', [M.AudioWidth,M.AudioContext]);
 M.AudioNorm := TensorID(M.Tensors, 'encoder.ln_post.weight', [M.AudioWidth]);
 M.AudioNormB := TensorID(M.Tensors, 'encoder.ln_post.bias', [M.AudioWidth]);
 M.Embedding := TensorID(M.Tensors, 'decoder.token_embedding.weight', [M.TextWidth,M.VocabCount]);
 M.TextPosition := TensorID(M.Tensors, 'decoder.positional_embedding', [M.TextWidth,M.TextContext]);
 M.TextNorm := TensorID(M.Tensors, 'decoder.ln.weight', [M.TextWidth]);
 M.TextNormB := TensorID(M.Tensors, 'decoder.ln.bias', [M.TextWidth]);
 SetLength(M.Encoder, M.AudioLayers); SetLength(M.Decoder, M.TextLayers);
 For I := 0 to M.AudioLayers - 1 do BindWhisperLayer(M.Tensors, 'encoder.blocks.' + IntToStr(I), M.AudioWidth, False, M.Encoder[I]);
 For I := 0 to M.TextLayers - 1 do BindWhisperLayer(M.Tensors, 'decoder.blocks.' + IntToStr(I), M.TextWidth, True, M.Decoder[I]);
 M.EOT := 50257; M.SOT := 50258; M.French := 50265;
 M.Transcribe := 50359 + M.VocabCount - 51865;
 M.NoSpeech := 50362 + M.VocabCount - 51865; M.NoTimestamps := 50363 + M.VocabCount - 51865;
 WriteLn(StdErr, 'Whisper natif: ', M.AudioLayers, ' couches encodeur, ', M.TextLayers, ' couches decodeur, largeur ', M.AudioWidth, '.');
End;

{$IFDEF CPU386}
{$ASMMODE INTEL}
Function NeuralDot(A, B: PSingle; N: LongInt): Single; register; assembler; nostackframe;
asm
 push esi
 push edi
 mov esi,eax
 mov edi,edx
 xorps xmm0,xmm0
@@vector:
 cmp ecx,4
 jl @@tail
 movups xmm1,[esi]
 movups xmm2,[edi]
 mulps xmm1,xmm2
 addps xmm0,xmm1
 add esi,16
 add edi,16
 sub ecx,4
 jmp @@vector
@@tail:
 test ecx,ecx
 jz @@sum
 movss xmm1,[esi]
 mulss xmm1,[edi]
 addss xmm0,xmm1
 add esi,4
 add edi,4
 dec ecx
 jmp @@tail
@@sum:
 movaps xmm1,xmm0
 movhlps xmm1,xmm0
 addps xmm0,xmm1
 movaps xmm1,xmm0
 shufps xmm1,xmm1,$55
 addss xmm0,xmm1
 sub esp,4
 movss [esp],xmm0
 fld dword ptr [esp]
 add esp,4
 pop edi
 pop esi
end;
{$ELSE}
Function NeuralDot(A, B: PSingle; N: LongInt): Single;
Var I: Integer; Value: Double;
Begin
 Value := 0;
 For I := 1 to N do Begin Value := Value + A^ * B^; Inc(A); Inc(B); End;
 Result := Value;
End;
{$ENDIF}

Procedure MatrixSize(var M: TMatrix; Rows, Cols: Integer);
Begin
 if (Rows < 0) or (Cols <= 0) or (Int64(Rows) * Cols > 100000000) Then Fail('Matrice neuronale trop grande.');
 M.Rows := Rows; M.Cols := Cols; SetLength(M.Data, Rows * Cols);
End;

Procedure Dense(const X: TMatrix; const T: TTensors; Weight, Bias: Integer; out Y: TMatrix);
Var I, J, Width: Integer; Value: Single;
Begin
 Width := T[Weight].Dims[1];
 if X.Cols <> T[Weight].Dims[0] Then Fail('Dimension de projection neuronale invalide.');
 MatrixSize(Y, X.Rows, Width);
 For I := 0 to X.Rows - 1 do For J := 0 to Width - 1 do Begin
  Value := NeuralDot(@X.Data[I * X.Cols], @T[Weight].Data[J * X.Cols], X.Cols);
  if Bias >= 0 Then Value := Value + T[Bias].Data[J];
  Y.Data[I * Width + J] := Value;
 End;
End;

Function StableTanh(Value: Double): Double;
Begin
 if Value > 15 Then Exit(1); if Value < -15 Then Exit(-1);
 Result := 2 / (1 + Exp(-2 * Value)) - 1;
End;

Function Sigmoid(Value: Double): Double;
Begin
 if Value >= 0 Then Result := 1 / (1 + Exp(-Value))
 else Begin Value := Exp(Value); Result := Value / (1 + Value); End;
End;

Procedure GELU(var X: TMatrix);
Var I: Integer; V: Double;
Begin
 For I := 0 to High(X.Data) do Begin
  V := X.Data[I]; X.Data[I] := 0.5 * V * (1 + StableTanh(0.7978845608028654 * V * (1 + 0.044715 * V * V)));
 End;
End;

Procedure NeuralNorm(const X: TMatrix; const T: TTensors; Weight, Bias: Integer; out Y: TMatrix);
Var I, J, Offset: Integer; Mean, Variance, V, Scale: Double;
Begin
 MatrixSize(Y, X.Rows, X.Cols);
 For I := 0 to X.Rows - 1 do Begin
  Offset := I * X.Cols; Mean := 0; Variance := 0;
  For J := 0 to X.Cols - 1 do Mean := Mean + X.Data[Offset + J];
  Mean := Mean / X.Cols;
  For J := 0 to X.Cols - 1 do Begin V := X.Data[Offset + J] - Mean; Variance := Variance + V * V; End;
  Scale := 1 / Sqrt(Variance / X.Cols + 1E-5);
  For J := 0 to X.Cols - 1 do Y.Data[Offset + J] := (X.Data[Offset + J] - Mean) * Scale * T[Weight].Data[J] + T[Bias].Data[J];
 End;
End;

Procedure Residual(var X: TMatrix; const Y: TMatrix);
Var I: Integer;
Begin
 if (X.Rows <> Y.Rows) or (X.Cols <> Y.Cols) Then Fail('Dimension residuelle invalide.');
 For I := 0 to High(X.Data) do X.Data[I] := X.Data[I] + Y.Data[I];
End;

Procedure Conv1D(const X: TMatrix; const T: TTensors; Weight, Bias, Stride, Padding: Integer; out Y: TMatrix);
Var I, J, C, K, Source, Width, Kernel, Rows: Integer; Patch: TSamples; Value: Single;
Begin
 Kernel := T[Weight].Dims[0]; Width := T[Weight].Dims[2];
 if T[Weight].Dims[1] <> X.Cols Then Fail('Canaux de convolution invalides.');
 Rows := (X.Rows + 2 * Padding - Kernel) div Stride + 1; MatrixSize(Y, Rows, Width);
 SetLength(Patch, X.Cols * Kernel);
 For I := 0 to Rows - 1 do Begin
  For C := 0 to X.Cols - 1 do For K := 0 to Kernel - 1 do Begin
   Source := I * Stride - Padding + K;
   if (Source < 0) or (Source >= X.Rows) Then Patch[C * Kernel + K] := 0
   else Patch[C * Kernel + K] := X.Data[Source * X.Cols + C];
  End;
  For J := 0 to Width - 1 do Begin
   Value := NeuralDot(@Patch[0], @T[Weight].Data[J * Length(Patch)], Length(Patch));
   if Bias >= 0 Then Value := Value + T[Bias].Data[J]; Y.Data[I * Width + J] := Value;
  End;
 End;
End;

Procedure NeuralAttention(const Q, K, V: TMatrix; KeyCount, Heads: Integer; out Y: TMatrix);
Var I, J, H, D, Width: Integer; Scores, Transposed: TSamples; Scale, Peak, Sum, Value: Double;
Begin
 if (Q.Cols <> K.Cols) or (K.Cols <> V.Cols) or (KeyCount <= 0) or (KeyCount > K.Rows) or
  (KeyCount > V.Rows) or (Q.Cols mod Heads <> 0) Then Fail('Dimensions attention invalides.');
 Width := Q.Cols div Heads; Scale := 1 / Sqrt(Width);
 MatrixSize(Y, Q.Rows, Q.Cols); SetLength(Scores, KeyCount); SetLength(Transposed, KeyCount * V.Cols);
 For J := 0 to KeyCount - 1 do For D := 0 to V.Cols - 1 do Transposed[D * KeyCount + J] := V.Data[J * V.Cols + D];
 For I := 0 to Q.Rows - 1 do For H := 0 to Heads - 1 do Begin
  Peak := -1E30;
  For J := 0 to KeyCount - 1 do Begin
   Value := NeuralDot(@Q.Data[I * Q.Cols + H * Width], @K.Data[J * K.Cols + H * Width], Width) * Scale;
   Scores[J] := Value; if Value > Peak Then Peak := Value;
  End;
  Sum := 0;
  For J := 0 to KeyCount - 1 do Begin Scores[J] := Exp(Scores[J] - Peak); Sum := Sum + Scores[J]; End;
  For J := 0 to KeyCount - 1 do Scores[J] := Scores[J] / Sum;
  For D := 0 to Width - 1 do Y.Data[I * Y.Cols + H * Width + D] :=
   NeuralDot(@Scores[0], @Transposed[(H * Width + D) * KeyCount], KeyCount);
 End;
End;

Procedure NeuralMLP(var X: TMatrix; const T: TTensors; const L: TWhisperLayer);
Var N, A, B: TMatrix;
Begin
 NeuralNorm(X, T, L.MLPNorm, L.MLPNormB, N);
 Dense(N, T, L.MLP0, L.MLP0B, A); GELU(A); Dense(A, T, L.MLP2, L.MLP2B, B); Residual(X, B);
End;

Procedure EncodeWhisper(const Mel: TMatrix; const M: TWhisperModel; out Encoded: TMatrix);
Var X, N, Q, K, V, A, B: TMatrix; I, J: Integer; W: TAttentionWeights;
Begin
 Conv1D(Mel, M.Tensors, M.Conv1, M.Conv1B, 1, 1, X); GELU(X);
 Conv1D(X, M.Tensors, M.Conv2, M.Conv2B, 2, 1, Encoded); GELU(Encoded);
 For J := 0 to High(Encoded.Data) do Encoded.Data[J] := Encoded.Data[J] + M.Tensors[M.AudioPosition].Data[J];
 For I := 0 to M.AudioLayers - 1 do Begin
  WriteLn(StdErr, 'Whisper: encodeur ', I + 1, '/', M.AudioLayers);
  W := M.Encoder[I].Attention;
  NeuralNorm(Encoded, M.Tensors, W.LN, W.LNB, N);
  Dense(N, M.Tensors, W.Q, W.QB, Q); Dense(N, M.Tensors, W.K, -1, K); Dense(N, M.Tensors, W.V, W.VB, V);
  NeuralAttention(Q, K, V, K.Rows, M.AudioHeads, A); Dense(A, M.Tensors, W.O, W.OB, B); Residual(Encoded, B);
  NeuralMLP(Encoded, M.Tensors, M.Encoder[I]);
 End;
 NeuralNorm(Encoded, M.Tensors, M.AudioNorm, M.AudioNormB, N); Encoded := N;
End;

Procedure InitDecoderCache(const Encoded: TMatrix; const M: TWhisperModel; out Cache: TDecoderCaches);
Var I: Integer; W: TAttentionWeights;
Begin
 SetLength(Cache, M.TextLayers);
 For I := 0 to M.TextLayers - 1 do Begin
  W := M.Decoder[I].Cross;
  Dense(Encoded, M.Tensors, W.K, -1, Cache[I].CrossK); Dense(Encoded, M.Tensors, W.V, W.VB, Cache[I].CrossV);
  MatrixSize(Cache[I].SelfK, M.TextContext, M.TextWidth); MatrixSize(Cache[I].SelfV, M.TextContext, M.TextWidth);
 End;
End;

Procedure DecoderStep(Token, Position: Integer; const M: TWhisperModel; var Cache: TDecoderCaches; out Logits: TMatrix);
Var X, N, Q, K, V, A, B: TMatrix; I, J: Integer; W: TAttentionWeights;
Begin
 Bounded(Token, 0, M.VocabCount - 1, 'token decodeur'); Bounded(Position, 0, M.TextContext - 1, 'position decodeur');
 MatrixSize(X, 1, M.TextWidth);
 For J := 0 to M.TextWidth - 1 do X.Data[J] := M.Tensors[M.Embedding].Data[Token * M.TextWidth + J] +
  M.Tensors[M.TextPosition].Data[Position * M.TextWidth + J];
 For I := 0 to M.TextLayers - 1 do Begin
  W := M.Decoder[I].Attention; NeuralNorm(X, M.Tensors, W.LN, W.LNB, N);
  Dense(N, M.Tensors, W.Q, W.QB, Q); Dense(N, M.Tensors, W.K, -1, K); Dense(N, M.Tensors, W.V, W.VB, V);
  Move(K.Data[0], Cache[I].SelfK.Data[Position * M.TextWidth], M.TextWidth * 4);
  Move(V.Data[0], Cache[I].SelfV.Data[Position * M.TextWidth], M.TextWidth * 4);
  NeuralAttention(Q, Cache[I].SelfK, Cache[I].SelfV, Position + 1, M.TextHeads, A);
  Dense(A, M.Tensors, W.O, W.OB, B); Residual(X, B);
  W := M.Decoder[I].Cross; NeuralNorm(X, M.Tensors, W.LN, W.LNB, N); Dense(N, M.Tensors, W.Q, W.QB, Q);
  NeuralAttention(Q, Cache[I].CrossK, Cache[I].CrossV, Cache[I].CrossK.Rows, M.TextHeads, A);
  Dense(A, M.Tensors, W.O, W.OB, B); Residual(X, B);
  NeuralMLP(X, M.Tensors, M.Decoder[I]);
 End;
 NeuralNorm(X, M.Tensors, M.TextNorm, M.TextNormB, N); Dense(N, M.Tensors, M.Embedding, -1, Logits);
End;

{ Whisper: DFT 400 points, fenetre Hann periodique et filtres mel du modele.
  Les tables trigonométriques sont calculees une fois; aucun moteur FFT externe. }
Procedure WhisperMel(const Audio: TSamples; First, Last: Integer; const M: TWhisperModel; out Mel: TMatrix);
Var C, S, Frame, Power: TSamples; I, J, K, P: Integer; A, B, V, Peak: Double;
Begin
 SetLength(C, 201 * 400); SetLength(S, 201 * 400); SetLength(Frame, 400); SetLength(Power, 201);
 For K := 0 to 200 do For J := 0 to 399 do Begin
  A := 2 * Pi * K * J / 400; B := 0.5 - 0.5 * Cos(2 * Pi * J / 400);
  C[K * 400 + J] := B * Cos(A); S[K * 400 + J] := B * Sin(A);
 End;
 MatrixSize(Mel, 3000, M.MelCount); Peak := -10;
 For I := 0 to 2999 do Begin
  if I * 160 - 200 < Last - First Then Begin
   For J := 0 to 399 do Begin
    P := I * 160 + J - 200; if P < 0 Then P := -P;
    if P < Last - First Then Frame[J] := Audio[First + P] else Frame[J] := 0;
   End;
   For K := 0 to 200 do Begin
    A := NeuralDot(@Frame[0], @C[K * 400], 400); B := NeuralDot(@Frame[0], @S[K * 400], 400);
    Power[K] := A * A + B * B;
   End;
   For K := 0 to M.MelCount - 1 do Begin
    V := NeuralDot(@Power[0], @M.Filters[K * 201], 201);
    if V < 1E-10 Then V := 1E-10;
    V := Ln(V) / Ln(10); Mel.Data[I * M.MelCount + K] := V;
    if V > Peak Then Peak := V;
   End;
  End else For K := 0 to M.MelCount - 1 do Mel.Data[I * M.MelCount + K] := -10;
 End;
 For I := 0 to High(Mel.Data) do Begin
  V := Mel.Data[I]; if V < Peak - 8 Then V := Peak - 8;
  Mel.Data[I] := (V + 4) / 4;
 End;
End;

Procedure LoadSilero(const Name: string; out M: TSileroModel);
Const Ins: array[0..3] of Integer = (129,128,64,64);
 Outs: array[0..3] of Integer = (128,64,64,128);
Var S: TBinary; I, N, Major, Minor: Integer; ModelType, Prefix: string;
Begin
 OpenBinary(S, Name, False);
 if U32(S) <> $67676D6C Then Fail('Signature GGML Silero incorrecte.');
 N := Bounded(LongInt(U32(S)), 1, 64, 'type Silero'); SetLength(ModelType, N); ReadBytes(S, ModelType[1], N);
 Major := U32(S); Minor := U32(S); N := U32(S);
 if (ModelType <> 'silero-16k') or not ((Major = 5) or ((Major = 6) and (Minor <= 2))) Then
  Fail('Modele Silero non pris en charge (16 kHz, v5 ou v6.0..6.2 requis).');
 if U32(S) <> 512 Then Fail('Fenetre Silero non prise en charge.');
 if U32(S) <> 64 Then Fail('Contexte Silero non pris en charge.');
 if U32(S) <> 4 Then Fail('Architecture Silero non prise en charge.');
 For I := 0 to 3 do Begin
  if U32(S) <> LongWord(Ins[I]) Then Fail('Entree convolution Silero incorrecte.');
  if U32(S) <> LongWord(Outs[I]) Then Fail('Sortie convolution Silero incorrecte.');
  if U32(S) <> 3 Then Fail('Noyau Silero incorrect.');
 End;
 For I := 1 to 3 do if U32(S) <> 128 Then Fail('Dimension LSTM Silero incorrecte.');
 if U32(S) <> 1 Then Fail('Sortie Silero incorrecte.');
 ReadTensorTable(S, M.Tensors); CloseBinary(S);
 M.Basis := TensorID(M.Tensors, '_model.stft.forward_basis_buffer', [256,1,258]);
 For I := 0 to 3 do Begin
  Prefix := '_model.encoder.' + IntToStr(I) + '.reparam_conv';
  M.Conv[I] := TensorID(M.Tensors, Prefix + '.weight', [3,Ins[I],Outs[I]]);
  M.Bias[I] := TensorID(M.Tensors, Prefix + '.bias', [Outs[I]]);
 End;
 M.IH := TensorID(M.Tensors, '_model.decoder.rnn.weight_ih', [128,512]);
 M.HH := TensorID(M.Tensors, '_model.decoder.rnn.weight_hh', [128,512]);
 M.IHB := TensorID(M.Tensors, '_model.decoder.rnn.bias_ih', [512]);
 M.HHB := TensorID(M.Tensors, '_model.decoder.rnn.bias_hh', [512]);
 M.FinalWeight := TensorID(M.Tensors, '_model.decoder.decoder.2.weight', [128]);
 M.FinalBias := TensorID(M.Tensors, '_model.decoder.decoder.2.bias', [1]);
End;

Procedure NeuralReLU(var X: TMatrix);
Var I: Integer;
Begin For I := 0 to High(X.Data) do if X.Data[I] < 0 Then X.Data[I] := 0; End;

Function SileroStep(const Audio: TSamples; Offset: Integer; const M: TSileroModel; var H, Cell: TMatrix): Double;
Var X, Y, Spectrum, A, B: TMatrix; I, J, P, Stride: Integer; V: Double;
Begin
 { Meme fenetre 512 et padding reflectif que le lecteur GGML whisper.cpp. }
 MatrixSize(X, 640, 1);
 For I := 0 to 639 do Begin
  P := I - 64; if P < 0 Then P := -P; if P >= 512 Then P := 1022 - P;
  if Offset + P < Length(Audio) Then X.Data[I] := Audio[Offset + P] else X.Data[I] := 0;
 End;
 Conv1D(X, M.Tensors, M.Basis, -1, 128, 0, Y); MatrixSize(Spectrum, 4, 129);
 For I := 0 to 3 do For J := 0 to 128 do
  Spectrum.Data[I * 129 + J] := Sqrt(Sqr(Y.Data[I * 258 + J]) + Sqr(Y.Data[I * 258 + J + 129]));
 X := Spectrum;
 For I := 0 to 3 do Begin
  if (I = 1) or (I = 2) Then Stride := 2 else Stride := 1;
  Conv1D(X, M.Tensors, M.Conv[I], M.Bias[I], Stride, 1, Y); NeuralReLU(Y); X := Y;
  Y.Data := nil;
 End;
 Dense(X, M.Tensors, M.IH, M.IHB, A); Dense(H, M.Tensors, M.HH, M.HHB, B);
 For I := 0 to 511 do A.Data[I] := A.Data[I] + B.Data[I];
 For I := 0 to 127 do Begin
  Cell.Data[I] := Sigmoid(A.Data[128 + I]) * Cell.Data[I] + Sigmoid(A.Data[I]) * StableTanh(A.Data[256 + I]);
  H.Data[I] := Sigmoid(A.Data[384 + I]) * StableTanh(Cell.Data[I]);
 End;
 V := M.Tensors[M.FinalBias].Data[0];
 For I := 0 to 127 do if H.Data[I] > 0 Then V := V + H.Data[I] * M.Tensors[M.FinalWeight].Data[I];
 Result := Sigmoid(V);
End;

Procedure DetectSpeech(const Audio: TSamples; const M: TSileroModel; out Ranges: TSpeechRanges);
Var H, Cell: TMatrix; Offset, Start, Quiet, N: Integer; P: Double;
Procedure AddRange(First, Last: Integer);
Begin
 if Last - First < 4000 Then Exit;
 First := Max(0, First - 480); Last := Min(Length(Audio), Last + 480);
 N := Length(Ranges);
 if (N > 0) and (First - Ranges[N - 1].Last <= 16000) and
  (Last - Ranges[N - 1].First <= 480000) Then Ranges[N - 1].Last := Last
 else Begin
  if (N > 0) and (First < Ranges[N - 1].Last) Then First := Ranges[N - 1].Last;
  While First < Last do Begin
   N := Length(Ranges); SetLength(Ranges, N + 1);
   Ranges[N].First := First; Ranges[N].Last := Min(Last, First + 480000); First := Ranges[N].Last;
  End;
 End;
End;
Begin
 SetLength(Ranges, 0); MatrixSize(H, 1, 128); MatrixSize(Cell, 1, 128);
 Offset := 0; Start := -1; Quiet := -1;
 While Offset < Length(Audio) do Begin
  P := SileroStep(Audio, Offset, M, H, Cell);
  if P >= 0.5 Then Begin if Start < 0 Then Start := Offset; Quiet := -1; End
  else if (P < 0.35) and (Start >= 0) Then Begin
   if Quiet < 0 Then Quiet := Offset;
   if Offset - Quiet >= 3200 Then Begin AddRange(Start, Quiet); Start := -1; Quiet := -1; End;
  End;
  Inc(Offset, 512);
 End;
 if Start >= 0 Then AddRange(Start, Length(Audio));
 { Les plages sont des bornes VAD, pas des horodatages de mots Whisper. }
End;

Function DecodeFrench(const Audio: TSamples; First, Last: Integer; const M: TWhisperModel): string;
Var Mel, Encoded, Logits: TMatrix; Cache: TDecoderCaches; Position, Token, I, Best: Integer; Peak: Single;
Begin
 WhisperMel(Audio, First, Last, M, Mel); EncodeWhisper(Mel, M, Encoded);
 Mel.Data := nil; InitDecoderCache(Encoded, M, Cache); Encoded.Data := nil;
 DecoderStep(M.SOT, 0, M, Cache, Logits); DecoderStep(M.French, 1, M, Cache, Logits);
 DecoderStep(M.Transcribe, 2, M, Cache, Logits); DecoderStep(M.NoTimestamps, 3, M, Cache, Logits);
 Result := ''; Position := 4;
 repeat
  Best := M.EOT; Peak := -1E30;
  For I := 0 to M.EOT do Begin
   if (I < M.EOT) and (M.Vocab[I] = '') Then Continue;
   if (Position = 4) and ((I = M.EOT) or (M.Vocab[I] = ' ')) Then Continue;
   if Logits.Data[I] > Peak Then Begin Peak := Logits.Data[I]; Best := I; End;
  End;
  Token := Best; if Token = M.EOT Then Break;
  Result := Result + M.Vocab[Token];
  if Position >= M.TextContext Then Fail('Limite du contexte Whisper atteinte sans fin de texte; aucune sortie partielle publiee.');
  DecoderStep(Token, Position, M, Cache, Logits); Inc(Position);
 until False;
 Result := Trim(Result);
End;

Function JSONString(const S: string): string;
Const Hex: string = '0123456789abcdef';
Var I, B: Integer;
Begin
 Result := '"';
 For I := 1 to Length(S) do Begin
  B := Ord(S[I]);
  if (S[I] = '"') or (S[I] = '\') Then Result := Result + '\' + S[I]
  else if B < 32 Then Result := Result + '\u00' + Hex[B div 16 + 1] + Hex[B mod 16 + 1]
  else Result := Result + S[I];
 End;
 Result := Result + '"';
End;

Procedure Help;Begin
 WriteLn('WAV2FRA - Cette commande permet d''effectuer la transcription francaise locale.');
 WriteLn;
 WriteLn('WAV2FRA entree.wav --model modele.bin --vad-model silero.bin [options]');
 WriteLn;
 WriteLn('  --output PREFIXE     Sorties PREFIXE.txt/.json/.TextGrid');
 WriteLn('  --check-whisper      Verifier le modele GGML --model, sans WAV');
 WriteLn('  --check-vad          Verifier le modele GGML --vad-model, sans WAV');
 WriteLn('  --dictionary FICHIER Dictionnaire MFA UTF-8 (.dict), obligatoire pour aligner');
 WriteLn('  --acoustic CHEMIN    Archive MFA .zip, dossier ou .alimdl/.mdl avec fichiers associes');
 WriteLn('  --align-text FICHIER Aligner un texte UTF-8 connu, sans appeler Whisper');
 WriteLn('  --check-acoustic     Verifier les donnees --acoustic, sans WAV ni moteur');
 WriteLn('  --text-only          Transcrire sans alignement mots/phonemes');
 WriteLn('  --prepare-only       Conversion seule vers PREFIXE.wav, sans modeles');
 WriteLn('  --help, /?           Cette aide');
 WriteLn;
 WriteLn('Whisper et Silero CPU internes: poids GGML FP16/FP32, sans executable externe.');
 WriteLn('Decodeur glouton francais; modeles quantifies et GPU non pris en charge.');
 WriteLn('Alignement GMM-HMM natif: aucun executable MFA/Kaldi necessaire.');
 WriteLn('Donnees MFA requises: meta.json, phones.txt, tree, final.alimdl et lda.mat si utilise.');
 WriteLn('Pas de lecture haut-parleur; le fichier est analyse. Sorties UTF-8.');
 WriteLn('PCM 8/16/24/32 bits, float32; 1..8 canaux; 8..192 kHz; 256 Mio/30 min max.');
End;

Procedure Parse(out O: TOptions);
Var
 I: Integer;
 K, V: string;
Begin
 O.Input := ''; O.Output := ''; O.Model := ''; O.VADModel := '';
 O.AlignText := ''; O.CheckWhisper := False; O.CheckVAD := False;
 O.Dictionary := ''; O.Acoustic := '';
 O.PrepareOnly := False; O.TextOnly := False; O.CheckAcoustic := False;
 I := 1;
 While I <= ParamCount do Begin
  K := ParamStr(I);
  if K = '--prepare-only' Then O.PrepareOnly := True
  else if K = '--text-only' Then O.TextOnly := True
  else if K = '--check-acoustic' Then O.CheckAcoustic := True
  else if K = '--check-whisper' Then O.CheckWhisper := True
  else if K = '--check-vad' Then O.CheckVAD := True
  else if K = '--whisper' Then Fail('--whisper supprime: la reconnaissance est maintenant interne.')
  else if K = '--mfa' Then Fail('--mfa supprime: l''alignement est maintenant interne.')
  else if Copy(K, 1, 2) = '--' Then Begin
   if not ((K = '--output') or (K = '--model') or (K = '--vad-model') or
   (K = '--align-text') or (K = '--dictionary') or
   (K = '--acoustic')) Then Fail('Option inconnue: ' + K);
   Inc(I); if I > ParamCount Then Fail('Valeur manquante: ' + K);
   V := ParamStr(I); if V = '' Then Fail('Valeur vide: ' + K);
   if K = '--output' Then O.Output := V
   else if K = '--model' Then O.Model := V
   else if K = '--vad-model' Then O.VADModel := V
   else if K = '--align-text' Then O.AlignText := V
   else if K = '--dictionary' Then O.Dictionary := V
   else if K = '--acoustic' Then O.Acoustic := V;
  End
  else if O.Input = '' Then O.Input := K
  else Fail('Argument inattendu: ' + K);
  Inc(I);
 End;
 if O.CheckWhisper or O.CheckVAD Then Begin
  if O.CheckAcoustic or O.PrepareOnly or O.TextOnly or (O.AlignText <> '') or
   (O.CheckWhisper and O.CheckVAD) Then Fail('Modes de verification incompatibles.');
  if O.CheckWhisper and not FileExists(O.Model) Then Fail('--model requis.');
  if O.CheckVAD and not FileExists(O.VADModel) Then Fail('--vad-model requis.');
  Exit;
 End;
 if (O.CheckAcoustic and (O.PrepareOnly or O.TextOnly or (O.AlignText <> ''))) or
    (O.PrepareOnly and (O.TextOnly or (O.AlignText <> ''))) or
    (O.TextOnly and (O.AlignText <> '')) Then Fail('Modes de traitement incompatibles.');
 if O.CheckAcoustic Then Begin
  if not FileExists(O.Acoustic) and not DirectoryExists(O.Acoustic) Then Fail('--acoustic: chemin requis.');
  Exit;
 End;
 if O.Input = '' Then Fail('Fichier WAV requis; utiliser --help.');
 O.Input := ExpandFileName(O.Input);
 if O.Output = '' Then O.Output := ChangeFileExt(O.Input, '') + '.fra';
 O.Output := ExpandFileName(O.Output);
 if not DirectoryExists(ExtractFileDir(O.Output)) Then Fail('Dossier de sortie absent.');
 if not O.PrepareOnly and (O.AlignText = '') Then Begin
  if not FileExists(O.Model) Then Fail('--model: fichier Whisper multilingue requis.');
  if Pos('.en', LowerCase(ExtractFileName(O.Model))) > 0 Then      Fail(
  'Un modele Whisper anglais .en ne reconnait pas le francais.');
  if not FileExists(O.VADModel) Then Fail('--vad-model: fichier Silero requis.');
 End;
 if not O.PrepareOnly and not O.TextOnly Then Begin
  if not FileExists(O.Dictionary) Then Fail('--dictionary: fichier MFA .dict requis.');
  if not FileExists(O.Acoustic) and not DirectoryExists(O.Acoustic) Then Fail('--acoustic: donnees MFA/Kaldi requises.');
  if (O.AlignText <> '') and not FileExists(O.AlignText) Then Fail('Fichier --align-text introuvable.');
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
  { Ne supprimer que les fichiers temporaires connus. }
 DeleteFile(Prefix + 'audio.wav'); DeleteFile(Prefix + 'transcript.txt');
 DeleteFile(Prefix + 'transcript.json'); DeleteFile(Prefix + 'phones.TextGrid');
 if not RemoveDir(WorkDirectory) Then WriteLn(StdErr, 'Diagnostics conserves: ',
 WorkDirectory);
 WorkDirectory := '';
End;

Procedure Transcribe(const O: TOptions; const Audio: TSamples);
Var
 Work, Prefix, Grid, Txt, GridText, Segment, JSON: string;
 M: TWhisperModel; VAD: TSileroModel; Ranges: TSpeechRanges; I: Integer;
Begin
 MustBeNew(O.Output + '.txt'); MustBeNew(O.Output + '.json');
 if not O.TextOnly Then MustBeNew(O.Output + '.TextGrid');
 Work := CreateWorkDir;
 WorkDirectory := Work;
 Prefix := Work + DirectorySeparator + 'transcript';
 Grid := Work + DirectorySeparator + 'phones.TextGrid';
 WriteLn(StdErr, 'Chargement des modeles Whisper et Silero internes...');
 LoadWhisper(O.Model, M); LoadSilero(O.VADModel, VAD);
 DetectSpeech(Audio, VAD, Ranges); SetLength(VAD.Tensors, 0);
 WriteLn(StdErr, 'Plages de parole: ', Length(Ranges));
 Txt := ''; JSON := '{"language":"fr","timing":"vad_segments","segments":[';
 For I := 0 to High(Ranges) do Begin
  WriteLn(StdErr, 'Transcription de la plage ', I + 1, '/', Length(Ranges));
  Segment := DecodeFrench(Audio, Ranges[I].First, Ranges[I].Last, M);
  if (Txt <> '') and (Segment <> '') Then Txt := Txt + ' ';
  Txt := Txt + Segment;
  if I > 0 Then JSON := JSON + ',';
  JSON := JSON + '{"start":' + AudioDuration(Ranges[I].First) + ',"end":' +
   AudioDuration(Ranges[I].Last) + ',"text":' + JSONString(Segment) + '}';
 End;
 JSON := JSON + '],"text":' + JSONString(Txt) + '}' + LineEnding;
 SetLength(M.Tensors, 0);
 SaveText(Prefix + '.txt', Txt + LineEnding); SaveText(Prefix + '.json', JSON);
 if not O.TextOnly Then Begin
  if Txt <> '' Then Begin
   InternalAlign(Audio, Txt, O.Dictionary, O.Acoustic, Grid);
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
 AcousticModel: TKaldiModel;
 WhisperModel: TWhisperModel; VADModel: TSileroModel;

BEGIN
 For I := 1 to ParamCount do
  if (ParamStr(I) = '--help') or (ParamStr(I) = '/?') Then Begin
  Help; Halt(0);
 End;
 if ParamCount = 0 Then Begin
  Help; Halt(1);
 End;
 Parse(O);
 if O.CheckWhisper Then Begin LoadWhisper(O.Model, WhisperModel); WriteLn('Modele Whisper lisible.'); Halt(0); End;
 if O.CheckVAD Then Begin LoadSilero(O.VADModel, VADModel); WriteLn('Modele Silero lisible.'); Halt(0); End;
 if O.CheckAcoustic Then Begin
  LoadKaldiModel(O.Acoustic, AcousticModel); WriteLn('Modele MFA/Kaldi lisible par l''aligneur interne.'); Halt(0);
 End;
 ReadWave(O.Input, Source, Rate);
 WriteLn(StdErr, 'Lecture WAV: ', Length(Source), ' trames, ', Rate, ' Hz.');
 Resample(Source, Rate, Audio); SetLength(Source, 0);
 RemoveDC(Audio);
 if O.PrepareOnly Then Begin
  MustBeNew(O.Output + '.wav'); WriteWave(O.Output + '.wav', Audio);
  WriteLn('WAV mono PCM16 / 16000 Hz: ', O.Output + '.wav');
 End
 else if O.AlignText <> '' Then Begin
  MustBeNew(O.Output + '.TextGrid');
  InternalAlign(Audio, Trim(LoadText(O.AlignText)), O.Dictionary, O.Acoustic, O.Output + '.TextGrid');
  WriteLn('Alignement: ', O.Output + '.TextGrid');
 End
 else Transcribe(O, Audio);
END.
