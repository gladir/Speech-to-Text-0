{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @version: 1.00
  @website(https://www.gladir.com/speech-to-text-0)
  @abstract(Target: Free Pascal 3.2
  @description: Aligneur procedural natif. }
Program MFA;

{$A-}

{$mode fpc}{$H+}

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


Const
 TargetRate = 16000;
 MaxInputBytes = 268435456;
 { limite explicite: 256 Mio }
 MaxSeconds = 1800;

Var
 OpenFiles: array[0..7] of PBinary;
 PartialOutput: string;
Procedure Fail(const S: string);Forward;
Procedure CleanupWork;Forward;
{ Services proceduraux locaux, sans Classes, SysUtils ni Process. }

Function IntToStr(Value: Int64): string;Begin
 Str(Value, IntToStr);
End;

Function Trim(const Text: string): string;
Var
 First, Last: Integer;
Begin
 First := 1; Last := Length(Text);
 While (First <= Last) and (Text[First] <= ' ') do Inc(First);
 While (Last >= First) and (Text[Last] <= ' ') do Dec(Last);
 Trim := Copy(Text, First, Last - First + 1);
End;

Function LowerCase(const Text: string): string;
Var
 I: Integer;
Begin
  { Seul le suffixe ASCII des noms de modeles est compare. }
 LowerCase := Text;
 For I := 1 to Length(LowerCase) do    if LowerCase[I] in ['A'..'Z'] Then LowerCase[I] := Chr(Ord(
 LowerCase[I]) + 32);
End;

Function IsPathDelimiter(C: Char): Boolean;Begin
 {$IFDEF MSWINDOWS}
  IsPathDelimiter := C in ['/', '\'];
 {$ELSE}
  IsPathDelimiter := C = '/';
 {$ENDIF}
End;

Function IncludeTrailingPathDelimiter(const Path: string): string;Begin
 IncludeTrailingPathDelimiter := Path;
 if (IncludeTrailingPathDelimiter = '') or not IsPathDelimiter(IncludeTrailingPathDelimiter[Length(IncludeTrailingPathDelimiter)]) Then    IncludeTrailingPathDelimiter :=
 IncludeTrailingPathDelimiter + DirectorySeparator;
End;

Function ExtractFileName(const Path: string): string;
Var
 I: Integer;
Begin
 I := Length(Path);
 While (I > 0) and not IsPathDelimiter(Path[I]) do Dec(I);
 ExtractFileName := Copy(Path, I + 1, Length(Path) - I);
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
 Then    ExtractFileDir := Copy(Path, 1, I)
 else if I > 0 Then ExtractFileDir := Copy(Path, 1, I - 1)
 else ExtractFileDir := '';
End;

Function ChangeFileExt(const Path, Extension: string): string;
Var
 I: Integer;
Begin
 I := Length(Path);
 While (I > 0) and not IsPathDelimiter(Path[I]) and (Path[I] <> '.') do Dec(I);
 if (I > 0) and (Path[I] = '.') Then ChangeFileExt := Copy(Path, 1, I - 1) + Extension
 else ChangeFileExt := Path + Extension;
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
 ExpandFileName := IncludeTrailingPathDelimiter(Current) + Path;
End;

Function PathAttributes(const Name: string; var Attributes: Word): Boolean;
Var
 F: File;
Begin
 Assign(F, Name);
 DOS.GetFAttr(F, Attributes);
 PathAttributes := DosError = 0;
End;

Function FileExists(const Name: string): Boolean;
Var
 Attributes: Word;
Begin
 FileExists := PathAttributes(Name, Attributes);
 if FileExists Then FileExists := (Attributes and Directory) = 0;
End;

Function DirectoryExists(const Name: string): Boolean;
Var
 Attributes: Word;
Begin
 DirectoryExists := PathAttributes(Name, Attributes);
 if DirectoryExists Then DirectoryExists := (Attributes and Directory) <> 0;
End;

Function CreateDir(const Name: string): Boolean;Begin
  {$I-}
 MkDir(Name);
 CreateDir := IOResult = 0;
  {$I+}
End;

Function RemoveDir(const Name: string): Boolean;Begin
  {$I-}
 RmDir(Name);
 RemoveDir := IOResult = 0;
  {$I+}
End;

Function DeleteFile(const Name: string): Boolean;
Var
 F: File;
Begin
 Assign(F, Name);
  {$I-}
 Erase(F);
 DeleteFile := IOResult = 0;
  {$I+}
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
 AudioDuration := IntToStr(SampleCount div TargetRate) + '.' + Fraction;
End;
{ Fonctions numeriques locales: aucune dependance directe a l'unite Math.
  Abs, Sin, Cos, Pi, Round et Trunc sont fournis par l'unite System. }

Function MinInt(A, B: Integer): Integer;Begin
 if A < B Then MinInt := A else MinInt := B;
End;

Function MinDouble(A, B: Double): Double;Begin
 if A < B Then MinDouble := A else MinDouble := B;
End;

Function Max(A, B: Integer): Integer;Begin
 if A > B Then Max := A else Max := B;
End;

Function EnsureRange(Value, LowerBound, UpperBound: Double): Double;Begin
 if Value < LowerBound Then EnsureRange := LowerBound
 else if Value > UpperBound Then EnsureRange := UpperBound
 else EnsureRange := Value;
End;
{ Les appels du reechantillonneur portent sur des valeurs finies dont
  les arrondis sont representables en Int64. Trunc arrondit vers zero. }

Function Floor(Value: Double): Int64;Begin
 Floor := Trunc(Value);
 if Value < Floor Then Dec(Floor);
End;

Function Ceil(Value: Double): Int64;Begin
 Ceil := Trunc(Value);
 if Value > Ceil Then Inc(Ceil);
End;
{ Inspection IEEE 754 binary32 sans operation flottante, y compris pour
  les NaN signalants. Ces fonctions servent aux echantillons WAV float32. }

Function IsNan(const Value: Single): Boolean;
Var
 Bits: LongWord;
Begin
 Move(Value, Bits, SizeOf(Bits));
 IsNan := ((Bits and $7F800000) = $7F800000) and
 ((Bits and $007FFFFF) <> 0);
End;

Function IsInfinite(const Value: Single): Boolean;
Var
 Bits: LongWord;
Begin
 Move(Value, Bits, SizeOf(Bits));
 IsInfinite := (Bits and $7FFFFFFF) = $7F800000;
End;

Procedure Fail(const S: string);
Var
 I, ErrorCode: Integer;
Begin
 WriteLn(StdErr, 'MFA: ', S);
  { Fermer les fichiers encore ouverts avant de supprimer les temporaires.
    Les pointeurs concernent des records toujours presents sur la pile. }
 For I := 0 to High(OpenFiles) do    if OpenFiles[I] <> nil Then Begin
      {$I-}
  Close(OpenFiles[I]^.Handle); ErrorCode := IOResult;
      {$I+}
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
  {$I-}
 if Writing Then Rewrite(S.Handle, 1) else Reset(S.Handle, 1);
 ErrorCode := IOResult;
  {$I+}
 FileMode := OldMode;
 if ErrorCode <> 0 Then Fail('Ouverture impossible: ' + Name + ' (code ' + IntToStr(
 ErrorCode) + ')');
 I := 0;
 While (I <= High(OpenFiles)) and (OpenFiles[I] <> nil) do Inc(I);
 if I > High(OpenFiles) Then Begin
    {$I-}Close(S.Handle); ErrorCode := IOResult;{$I+}
  Fail('Trop de fichiers ouverts.');
 End;
 OpenFiles[I] := @S;
  {$I-}
 S.Size := FileSize(S.Handle); ErrorCode := IOResult;
  {$I+}
 if ErrorCode <> 0 Then Fail('Taille inaccessible: ' + Name);
End;

Procedure FlushBinary(var S: TBinary);
Var
 Count, ErrorCode: LongInt;
Begin
 if not S.Writing or (S.Used = 0) Then Exit;
  {$I-}
 BlockWrite(S.Handle, S.Buffer, S.Used, Count); ErrorCode := IOResult;
  {$I+}
 if (ErrorCode <> 0) or (Count <> S.Used) Then Fail('Ecriture incomplete: ' + S.Name);
 S.Used := 0;
End;

Procedure CloseBinary(var S: TBinary);
Var
 I, ErrorCode: Integer;
Begin
 FlushBinary(S);
  {$I-}Close(S.Handle); ErrorCode := IOResult;{$I+}
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
      {$I-}
   BlockRead(S.Handle, S.Buffer, SizeOf(S.Buffer), S.Used); ErrorCode := IOResult;
      {$I+}
   if (ErrorCode <> 0) or (S.Used = 0) Then Fail('Lecture incomplete: ' + S.Name);
   S.Index := 0;
  End;
  N := MinInt(Count, S.Used - S.Index);
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
  N := MinInt(Count, SizeOf(S.Buffer) - S.Used);
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
  {$I-}Seek(S.Handle, Position); ErrorCode := IOResult;{$I+}
 if ErrorCode <> 0 Then Fail('Position inaccessible: ' + S.Name);
 S.Position := Position; S.Index := 0; S.Used := 0;
End;

Function LoadText(const Name: string): string;
Var
 S: TBinary;
Begin
 OpenBinary(S, Name, False);
 if S.Size > MaxInputBytes Then Fail('Fichier texte trop grand: ' + Name);
 SetLength(LoadText, S.Size);
 if S.Size > 0 Then ReadBytes(S, LoadText[1], S.Size);
 CloseBinary(S);
  { Le BOM UTF-8 eventuel n'est pas une partie du texte prononce. }
 if Copy(LoadText, 1, 3) = #$EF#$BB#$BF Then Delete(LoadText, 1, 3);
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
 U16 := Word(B[0]) or (Word(B[1]) shl 8);
End;

Function U32(var S: TBinary): LongWord;
Var
 B: array[0..3] of Byte;
Begin
 ReadBytes(S, B, 4);
 U32 := LongWord(B[0]) or (LongWord(B[1]) shl 8) or
 (LongWord(B[2]) shl 16) or (LongWord(B[3]) shl 24);
End;

Function FourCC(var S: TBinary): AnsiString;Begin
 SetLength(FourCC, 4);
 ReadBytes(S, FourCC[1], 4);
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

Procedure ReadWave(const Name: string; var Samples: TSamples; var Rate: LongWord);
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

Procedure Resample(const Source: TSamples; Rate: LongWord; var Dest: TSamples);
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
 Cutoff := 0.94 * MinDouble(1.0, TargetRate / Rate);
 Radius := Ceil(16 / Cutoff);
 For I := 0 to Count - 1 do Begin
  Position := I * (Double(Rate) / TargetRate);
  Center := Floor(Position); Total := 0; Norm := 0;
  For J := Max(0, Center - Radius) to MinInt(High(Source), Center + Radius) do Begin
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
 TReader = record Data, Name: RawByteString;
 Position: LongInt;
End;
THuffman = record Counts: array[0..15] of Integer;
Symbols: array[0..287] of Integer;
End;

Function ReadByte(var R: TReader): Byte;Begin
 if (R.Position < 1) or (R.Position > Length(R.Data)) Then Fail('Donnees tronquees: ' +
 R.Name);
 ReadByte := Ord(R.Data[R.Position]); Inc(R.Position);
End;

Function ReadLE(var R: TReader; Count: Integer): LongWord;
Var
 I: Integer;
Begin
 ReadLE := 0;
 For I := 0 to Count - 1 do ReadLE := ReadLE or (LongWord(ReadByte(R)) shl (8 * I));
End;

Function KToken(var R: TReader): string;
Var
 C: Byte;
Begin
 KToken := '';
 repeat C := ReadByte(R); until C > 32;
 repeat
 KToken := KToken + Chr(C);
 if Length(KToken) > 100 Then Fail('Token Kaldi invalide: ' + R.Name);
 C := ReadByte(R);
 until C <= 32;
End;

Procedure KExpect(var R: TReader; const Expected: string);
Var
 Actual: string;
Begin
 Actual := KToken(R);
 if Actual <> Expected Then Fail(R.Name + ': attendu ' + Expected + ', obtenu ' + Actual);
End;

Function KInt(var R: TReader): LongInt;
Var
 Marker: Byte;
Begin
 Marker := ReadByte(R);
 if (Marker <> 4) and (Marker <> 252) Then  Fail('Entier Kaldi non 32 bits: ' + R.Name +
 ', octet ' + IntToStr(R.Position - 1));
 KInt := LongInt(ReadLE(R, 4));
End;

Function Bounded(Value, LowBound, HighBound: LongInt; const What: string): LongInt;Begin
 if (Value < LowBound) or (Value > HighBound) Then Fail('Valeur invalide: ' + What);
 Bounded := Value;
End;

Function KFloat(var R: TReader; WithSize: Boolean): Single;
Var
 Bits: LongWord;
Begin
 if WithSize Then if ReadByte(R) <> 4 Then Fail('Reel Kaldi non float32: ' + R.Name);
 Bits := ReadLE(R, 4); Move(Bits, KFloat, 4);
 if IsNan(KFloat) or IsInfinite(KFloat) Then Fail('Reel Kaldi non fini: ' + R.Name);
End;

Procedure KHeader(var R: TReader; const Data, Name: string);Begin
 R.Data := Data; R.Name := Name; R.Position := 1;
 if (ReadByte(R) <> 0) or (ReadByte(R) <> Ord('B')) Then  Fail(
 'Modele Kaldi binaire requis: ' + Name);
End;

Procedure KInts(var R: TReader; var Values: TIntVector);
Var
 I, N: Integer;
Begin
 { Les vecteurs d'entiers ont une seule marque de taille, puis N brut. }
 if ReadByte(R) <> 4 Then Fail('Vecteur Kaldi invalide: ' + R.Name);
 N := Bounded(LongInt(ReadLE(R, 4)), 0, 1000000, 'taille vecteur');
 if Int64(N) * 4 > Length(R.Data) - R.Position + 1 Then Fail('Vecteur Kaldi tronque: ' +
 R.Name);
 SetLength(Values, N);
 For I := 0 to N - 1 do Values[I] := LongInt(ReadLE(R, 4));
End;

Procedure KReals(var R: TReader; var Values: TRealVector; var Rows, Cols: Integer;
Matrix: Boolean);
Var
 I: Integer;
Begin
 if Matrix Then KExpect(R, 'FM') else KExpect(R, 'FV');
 Rows := Bounded(KInt(R), 0, 1000000, 'dimension Kaldi'); Cols := 1;
 if Matrix Then Cols := Bounded(KInt(R), 1, 1000, 'colonnes Kaldi');
 if Int64(Rows) * Cols > 16000000 Then Fail('Matrice Kaldi trop grande.');
 if Int64(Rows) * Cols * 4 > Length(R.Data) - R.Position + 1 Then Fail(
 'Matrice Kaldi tronquee: ' + R.Name);
 SetLength(Values, Rows * Cols);
 For I := 0 to High(Values) do Values[I] := KFloat(R, False);
End;

Procedure MakeHuffman(const Lengths: array of Integer; var H: THuffman);
Var
 I, Left: Integer;
 Offsets: array[0..15] of Integer;
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
 LenBase: array[0..28] of Integer = (3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,
 67,83,99,115,131,163,195,227,258);
 LenExtra: array[0..28] of Integer = (0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,
 5,5,0);
 DistBase: array[0..29] of Integer = (1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,
 513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577);
 DistExtra: array[0..29] of Integer = (0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,
 11,11,12,12,13,13);
Var
 R: TReader;
 Bits: LongWord;
 BitCount, Used: Integer;
 Lit, Dist, Code: THuffman;
 L: array[0..287] of Integer;
 D: array[0..31] of Integer;
 C: array[0..18] of Integer;
 All: array[0..319] of Integer;
 FinalBlock, Kind, NL, ND, NC, I, J, Symbol, N, Distance, Previous, Inverse: Integer;

Function Take(N: Integer): Integer;Begin
 While BitCount < N do Begin
  Bits := Bits or (LongWord(ReadByte(R)) shl BitCount); Inc(BitCount, 8);
 End;
 Take := Bits and ((LongWord(1) shl N) - 1); Bits := Bits shr N; Dec(BitCount, N);
End;

Function Decode(const H: THuffman): Integer;
Var
 Width, Value, First, Offset: Integer;
Begin
 Value := 0; First := 0; Offset := 0;
 For Width := 1 to 15 do Begin
  Value := (Value shl 1) or Take(1);
  if (Value >= First) and (Value < First + H.Counts[Width]) Then    Exit(
  H.Symbols[Offset + Value - First]);
  Inc(Offset, H.Counts[Width]); First := (First + H.Counts[Width]) shl 1;
 End;
 Fail('Code deflate invalide.'); Decode := 0;
End;

Procedure Emit(Value: Char);Begin
 if Used >= ExpectedSize Then Fail('Taille ZIP decompressee depassee.');
 Inc(Used); InflateRaw[Used] := Value;
End;
Begin
 Bounded(ExpectedSize, 0, MaxInputBytes, 'taille ZIP'); SetLength(InflateRaw, ExpectedSize);
 R.Data := Compressed; R.Name := 'deflate ZIP'; R.Position := 1;
 Bits := 0; BitCount := 0; Used := 0;
 repeat
 FinalBlock := Take(1); Kind := Take(2);
 if Kind = 0 Then Begin
  Bits := 0; BitCount := 0;
  N := ReadLE(R, 2); Inverse := ReadLE(R, 2);
  if (N xor Inverse) <> 65535 Then Fail('Bloc ZIP stocke invalide.');
  For I := 1 to N do Emit(Chr(ReadByte(R)));
 End else
 Begin
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
    if Symbol <= 15 Then Begin
     All[I] := Symbol; Inc(I);
    End
    else
    Begin
     Previous := 0;
     case Symbol of
     16:
     Begin
      if I = 0 Then Fail('Repetition deflate sans precedent.'); Previous := All[I - 1];
      N := Take(2) + 3;
     End;
     17: N := Take(3) + 3;
     18: N := Take(7) + 11;
     else
     Begin
      Fail('Longueur deflate invalide.'); N := 0;
     End;
    End;
    if I + N > NL + ND Then Fail('Repetition deflate excessive.');
    For J := 1 to N do Begin
     All[I] := Previous; Inc(I);
    End;
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
  For I := 1 to N do Emit(InflateRaw[Used - Distance + 1]);
 End;
 until Symbol = 256;
End;
until FinalBlock = 1;
if Used <> ExpectedSize Then Fail('Taille ZIP decompressee incorrecte.');
End;

Function CRC32(const Data: string): LongWord;
Var
 I, J: Integer;
Begin
 CRC32 := $FFFFFFFF;
 For I := 1 to Length(Data) do Begin
  CRC32 := CRC32 xor Ord(Data[I]);
  For J := 1 to 8 do   if (CRC32 and 1) <> 0 Then CRC32 := (CRC32 shr 1) xor $EDB88320
  else CRC32 := CRC32 shr 1;
 End;
 CRC32 := not CRC32;
End;

Function ZipMember(const Archive, Member: string): string;
Var
 R, L: TReader;
 I, Entries, N, Extra, Comment, Method, Flags: Integer;
 Offset, PackedSize, UnpackedSize, Checksum: LongWord;
 Name, Payload: string;
 Found: Boolean;
Begin
 R.Data := Archive; R.Name := 'archive MFA'; Found := False;
 I := Length(Archive) - 21;
 While I >= Max(1, Length(Archive) - 65557) do Begin
  if Copy(Archive, I, 4) = 'PK' + #5#6 Then Begin
   Found := True; Break;
  End;
  Dec(I);
 End;
 if not Found Then Fail('Repertoire central ZIP absent.');
 R.Position := I + 4;
 if (ReadLE(R, 2) <> 0) or (ReadLE(R, 2) <> 0) Then Fail('ZIP multidisque non accepte.');
 Entries := ReadLE(R, 2);
 if ReadLE(R, 2) <> LongWord(Entries) Then Fail('ZIP multidisque non accepte.');
 ReadLE(R, 4); Offset := ReadLE(R, 4);
 R.Position := Bounded(Int64(Offset) + 1, 1, Length(Archive), 'offset ZIP');
 Found := False; ZipMember := '';
 For I := 1 to Entries do Begin
  if ReadLE(R, 4) <> $02014B50 Then Fail('Entree ZIP invalide.');
  ReadLE(R, 2); ReadLE(R, 2); Flags := ReadLE(R, 2); Method := ReadLE(R, 2);
  ReadLE(R, 4); Checksum := ReadLE(R, 4); PackedSize := ReadLE(R, 4);
  UnpackedSize := ReadLE(R, 4);
  N := ReadLE(R, 2); Extra := ReadLE(R, 2); Comment := ReadLE(R, 2);
  ReadLE(R, 2); ReadLE(R, 2); ReadLE(R, 4); Offset := ReadLE(R, 4);
  if Int64(R.Position) + N + Extra + Comment - 1 > Length(Archive) Then Fail(
  'Nom ZIP tronque.');
  Name := Copy(Archive, R.Position, N); Inc(R.Position, N + Extra + Comment);
  if (Name <> Member) and (Copy(Name, Length(Name) - Length(Member), Length(Member) + 1)
  <> '/' + Member) Then Continue;
  if Found Then Fail('Plusieurs fichiers ' + Member + ' dans l''archive.');
  Found := True;
  if (Flags and 1) <> 0 Then Fail('ZIP chiffre non accepte.');
  if (PackedSize > MaxInputBytes) or (UnpackedSize > MaxInputBytes) Then Fail(
  'Entree ZIP trop grande.');
  L.Data := Archive; L.Name := Name;
  L.Position := Bounded(Int64(Offset) + 1, 1, Length(Archive), 'offset ZIP local');
  if ReadLE(L, 4) <> $04034B50 Then Fail('Entete ZIP locale absente.');
  Inc(L.Position, 22); N := ReadLE(L, 2); Extra := ReadLE(L, 2);
  Inc(L.Position, N + Extra);
  if Int64(L.Position) + PackedSize - 1 > Length(Archive) Then Fail(
  'Entree ZIP tronquee.');
  Payload := Copy(Archive, L.Position, PackedSize);
  if Method = 0 Then ZipMember := Payload
  else if Method = 8 Then ZipMember := InflateRaw(Payload, UnpackedSize)
  else Fail('Compression ZIP non prise en charge (stockage/deflate requis).');
  if (Length(ZipMember) <> UnpackedSize) or (CRC32(ZipMember) <> Checksum) Then Fail(
  'CRC/taille ZIP incorrect: ' + Member);
 End;
End;

Function ModelMember(const Path, Archive, Member: string; Required: Boolean): string;
Var
 Name: string;
Begin
 if Archive <> '' Then ModelMember := ZipMember(Archive, Member)
 else
 Begin
  Name := IncludeTrailingPathDelimiter(Path) + Member;
  if FileExists(Name) Then ModelMember := LoadText(Name) else ModelMember := '';
 End;
 if Required and (ModelMember = '') Then Fail('Fichier du modele manquant: ' + Member);
End;

Type
 TTopoState = record PdfClass: Integer;
 Dest: TIntVector;
End;
TTopology = array of TTopoState;
TTransition = record Phone, State, Pdf, First: Integer;
End;
TGMM = record Constants, Means, InverseVars: TRealVector;
Count: Integer;
End;
TTreeNode = record Kind, Key, Answer, YesNode, NoNode: Integer;
Values: TIntVector;
End;
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
Var
 First: Integer;
Begin
 While (Position <= Length(Text)) and (Text[Position] <= ' ') do Inc(Position);
 First := Position;
 While (Position <= Length(Text)) and (Text[Position] > ' ') do Inc(Position);
 NextToken := Copy(Text, First, Position - First);
End;

Function JsonValue(const Text, Key: string): string;
Var
 I, Start: Integer;
Begin
 JsonValue := ''; I := Pos('"' + Key + '"', Text);
 if I = 0 Then Exit;
 Inc(I, Length(Key) + 2);
 While (I <= Length(Text)) and (Text[I] <= ' ') do Inc(I);
 if (I > Length(Text)) or (Text[I] <> ':') Then Fail('Meta JSON invalide: ' + Key);
 Inc(I);
 While (I <= Length(Text)) and (Text[I] <= ' ') do Inc(I);
 if (I <= Length(Text)) and (Text[I] = '"') Then Begin
  Inc(I); Start := I;
  While (I <= Length(Text)) and (Text[I] <> '"') do Inc(I);
 End else
 Begin
  Start := I;
  While (I <= Length(Text)) and not (Text[I] in [',','}',']',#9,#10,#13,' ']) do Inc(I);
 End;
 JsonValue := Copy(Text, Start, I - Start);
End;

Function Number(const Text, What: string): Double;
Var
 Code: Integer;
 Bits: QWord;
Begin
 Val(Text, Number, Code); Move(Number, Bits, SizeOf(Bits));
 if (Code <> 0) or ((Bits and QWord($7FF0000000000000)) = QWord($7FF0000000000000))
 Then  Fail('Nombre invalide: ' + What);
End;

Function ReadTreeNode(var R: TReader; var M: TKaldiModel; Depth: Integer): Integer;
Var
 Token: string;
 Node, I, Child, N: Integer;
 Values: TIntVector;
Begin
 if Depth > 256 Then Fail('Arbre Kaldi trop profond.');
 Token := KToken(R);
 if Token = 'NULL' Then Exit(-1);
 Node := Length(M.Tree); if Node >= 100000 Then Fail('Arbre Kaldi trop grand.');
 SetLength(M.Tree, Node + 1); ReadTreeNode := Node;
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

Function TreePdf(const M: TKaldiModel;
LeftPhone, Phone, RightPhone, PdfClass: Integer): Integer;
Var
 Node, Value, I: Integer;
 Found: Boolean;
Begin
 Node := M.TreeRoot;
 While Node >= 0 do Begin
  if M.Tree[Node].Kind = 0 Then Exit(Bounded(M.Tree[Node].Answer, 0, High(M.PDFs),
  'pdf arbre'));
  case M.Tree[Node].Key of
  -1: Value := PdfClass;
  0: if M.ContextWidth = 1 Then Value := Phone else Value := LeftPhone;
  1: Value := Phone;
  2: Value := RightPhone;
  else
  Begin
   Fail('Cle de contexte Kaldi non prise en charge.'); Value := 0;
  End;
 End;
 if M.Tree[Node].Kind = 1 Then Begin
  Found := False;
  For I := 0 to High(M.Tree[Node].Values) do    if M.Tree[Node].Values[I] =
  Value Then Begin
   Found := True; Break;
  End;
  if Found Then Node := M.Tree[Node].YesNode else Node := M.Tree[Node].NoNode;
 End else
 Begin
  if (Value < 0) or (Value >= Length(M.Tree[Node].Values)) Then Node := -1
  else Node := M.Tree[Node].Values[Value];
 End;
End;
Fail('Contexte absent de l''arbre Kaldi.'); TreePdf := -1;
End;

Procedure LoadKaldiModel(const Location: string; var M: TKaldiModel);
Var
 Path, Archive, Data, Token, ModelFile, Value: string;
 R: TReader;
 I, J, K, N, Rows, Cols, Phone, State, TransCount, Position, Code: Integer;
 UnusedInts: TIntVector;
 UnusedReals: TRealVector;
 HMM: Boolean;
 Probability: Single;
Begin
 Path := Location; Archive := ''; ModelFile := 'final.alimdl';
 if not DirectoryExists(Path) Then Begin
  if LowerCase(Copy(Path, Length(Path) - 3, 4)) = '.zip' Then Archive := LoadText(Path)
  else
  Begin
   ModelFile := ExtractFileName(Path); Path := ExtractFileDir(ExpandFileName(Path));
  End;
 End;
 M.Metadata := ModelMember(Path, Archive, 'meta.json', True);
 if JsonValue(M.Metadata, 'architecture') <> 'gmm-hmm' Then Fail(
 'Modele MFA GMM-HMM requis (pas de reseau neuronal).');
 if (JsonValue(M.Metadata, 'type') <> 'mfcc') or
 (Number(JsonValue(M.Metadata, 'sample_frequency'), 'sample_frequency') <> 16000) or
 (Number(JsonValue(M.Metadata, 'frame_shift'), 'frame_shift') <> 10) or
 (Number(JsonValue(M.Metadata, 'frame_length'), 'frame_length') <> 25) or
 (Number(JsonValue(M.Metadata, 'num_coefficients'), 'num_coefficients') <> 13) Then  Fail(
 'Configuration MFCC non prise en charge: 16 kHz, 25/10 ms, 13 coefficients requis.');
 if JsonValue(M.Metadata, 'snip_edges') <> 'false' Then Fail(
 'Modele MFA snip_edges=false requis.');
 if (JsonValue(M.Metadata, 'use_pitch') = 'true') or (JsonValue(M.Metadata, 'use_voicing')
 = 'true') or
 (JsonValue(M.Metadata, 'position_dependent_phones') = 'true') Then  Fail(
 'Modele avec pitch/voicing/phonemes positionnels non pris en charge.');
 if Number(JsonValue(M.Metadata, 'dither'), 'dither') <> 0 Then Fail(
 'Modele sans dither requis.');
 if Abs(Number(JsonValue(M.Metadata, 'preemphasis_coefficient'), 'preemphasis') - 0.97) >
 1E-6 Then  Fail('Preaccentuation Kaldi non prise en charge.');
 M.MelBins := Round(Number(JsonValue(M.Metadata, 'num_mel_bins'), 'num_mel_bins'));
 Bounded(M.MelBins, 13, 40, 'num_mel_bins');
 M.LowFrequency := Number(JsonValue(M.Metadata, 'low_frequency'), 'low_frequency');
 M.HighFrequency := Number(JsonValue(M.Metadata, 'high_frequency'), 'high_frequency');
 if M.HighFrequency <= 0 Then M.HighFrequency := 8000 + M.HighFrequency;
 if (M.LowFrequency < 0) or (M.HighFrequency > 8000) or (M.LowFrequency >=
 M.HighFrequency) Then  Fail('Bornes mel invalides.');
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
   if ((J < Rows - 1) and (State < 0)) or ((J = Rows - 1) and (State <> -1)) Then    Fail(
   'Topologie a etats non emetteurs intermediaires non prise en charge.');
   Cols := Bounded(KInt(R), 0, 32, 'transitions topologie');
   if (J = Rows - 1) and (Cols <> 0) Then Fail('Etat final avec transitions.');
   SetLength(M.Topologies[I][J].Dest, Cols);
   For K := 0 to Cols - 1 do Begin
    M.Topologies[I][J].Dest[K] := Bounded(KInt(R), 0, Rows - 1, 'destination topologie');
    Probability := KFloat(R, True);
    if (Probability <= 0) or (Probability > 1) Then Fail(
    'Probabilite de transition invalide.');
   End;
  End;
 End;
 KExpect(R, '</Topology>'); Token := KToken(R);
 if (Token <> '<Triples>') and (Token <> '<Tuples>') Then Fail(
 'Transitions Kaldi absentes.');
 N := Bounded(KInt(R), 1, 1000000, 'nombre transitions'); SetLength(M.Transitions, N);
 TransCount := 1;
 For I := 0 to N - 1 do Begin
  Phone := Bounded(KInt(R), 1, High(M.PhoneTopology), 'phone transition');
  J := Bounded(M.PhoneTopology[Phone], 0, High(M.Topologies), 'index topologie');
  State := Bounded(KInt(R), 0, Length(M.Topologies[J]) - 2, 'etat transition');
  M.Transitions[I].Phone := Phone; M.Transitions[I].State := State;
  M.Transitions[I].Pdf := KInt(R);
  if Token = '<Tuples>' Then if KInt(R) <> M.Transitions[I].Pdf Then Fail(
  'PDF self-loop distinct non pris en charge.');
  M.Transitions[I].First := TransCount;
  Inc(TransCount, Length(M.Topologies[J][State].Dest));
 End;
 if Token = '<Triples>' Then KExpect(R, '</Triples>') else KExpect(R, '</Tuples>');
 KExpect(R, '<LogProbs>'); KReals(R, M.LogProbs, Rows, Cols, False);
 if Rows <> TransCount Then Fail('Nombre de probabilites Kaldi incoherent.');
 KExpect(R, '</LogProbs>'); KExpect(R, '</TransitionModel>');
 KExpect(R, '<DIMENSION>'); M.Dimension := Bounded(KInt(R), 1, 100, 'dimension GMM');
 KExpect(R, '<NUMPDFS>'); N := Bounded(KInt(R), 1, 100000, 'nombre PDF');
 SetLength(M.PDFs, N);
 For I := 0 to N - 1 do Begin
  KExpect(R, '<DiagGMM>'); KExpect(R, '<GCONSTS>');
  KReals(R, M.PDFs[I].Constants, Rows, Cols, False);
  M.PDFs[I].Count := Bounded(Rows, 1, 4096, 'gaussiennes par PDF');
  KExpect(R, '<WEIGHTS>'); KReals(R, UnusedReals, Rows, Cols, False);
  if Rows <> M.PDFs[I].Count Then Fail('Poids GMM incoherents.');
  KExpect(R, '<MEANS_INVVARS>'); KReals(R, M.PDFs[I].Means, Rows, Cols, True);
  if (Rows <> M.PDFs[I].Count) or (Cols <> M.Dimension) Then Fail(
  'Moyennes GMM incoherentes.');
  KExpect(R, '<INV_VARS>'); KReals(R, M.PDFs[I].InverseVars, Rows, Cols, True);
  if (Rows <> M.PDFs[I].Count) or (Cols <> M.Dimension) Then Fail(
  'Variances GMM incoherentes.');
  For J := 0 to High(M.PDFs[I].InverseVars) do if M.PDFs[I].InverseVars[J] <= 0 Then Fail(
  'Variance GMM non positive.');
  KExpect(R, '</DiagGMM>');
 End;
 For I := 0 to High(M.Transitions) do Bounded(M.Transitions[I].Pdf, 0, High(M.PDFs),
 'pdf transition');
 Data := ModelMember(Path, Archive, 'tree', True); KHeader(R, Data, 'tree');
 KExpect(R, 'ContextDependency'); M.ContextWidth := KInt(R); M.CentralPosition := KInt(R);
 if not (((M.ContextWidth = 3) and (M.CentralPosition = 1)) or
 ((M.ContextWidth = 1) and (M.CentralPosition = 0))) Then Fail(
 'Contexte Kaldi non monophone/triphone.');
 KExpect(R, 'ToPdf'); M.TreeRoot := ReadTreeNode(R, M, 0);
 KExpect(R, 'EndContextDependency');
 Data := ModelMember(Path, Archive, 'lda.mat', False);
 if Data <> '' Then Begin
  KHeader(R, Data, 'lda.mat'); KReals(R, M.LDA, M.LdaRows, M.LdaCols, True);
  if (M.LdaRows <> M.Dimension) or not (M.LdaCols in [91,92]) Then Fail(
  'LDA attendue: D x 91 ou D x 92.');
  if (Number(JsonValue(M.Metadata, 'splice_left_context'), 'splice_left_context') <> 3) or
  (Number(JsonValue(M.Metadata, 'splice_right_context'), 'splice_right_context') <> 3)
  Then Fail('LDA: contexte +/-3 requis.');
 End else if not (M.Dimension in [13,39]) Then Fail(
 'Dimension GMM sans LDA non prise en charge.');
 WriteLn(StdErr, 'Modele Kaldi charge: ', Length(M.PDFs), ' PDF, ', M.Dimension,
 ' dimensions, ', Length(M.Transitions), ' transitions.');
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
Var
 I, J, K, Size, Half: Integer;
 A, B, C, S, Angle: Double;
Begin
 J := 0;
 For I := 1 to AlignFFT - 1 do Begin
  K := AlignFFT div 2;
  While (J and K) <> 0 do Begin
   J := J xor K; K := K div 2;
  End;
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

Procedure ExtractFeatures(const Audio: TSamples; const M: TKaldiModel;
var Features: TAcousticFeatures);
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
 For I := 0 to M.MelBins + 1 do Edges[I] := MelLow + (MelHigh - MelLow) * I / (M.MelBins +
 1);
 For I := 0 to AlignWindow - 1 do Begin
  X := 0.5 - 0.5 * Cos(2 * Pi * I / (AlignWindow - 1));
  if X <= 0 Then Window[I] := 0 else Window[I] := Exp(0.85 * Ln(X));
 End;
 For J := 0 to M.MelBins - 1 do Begin
  For K := 0 to AlignFFT div 2 do Begin
   Mel := 1127 * Ln(1 + K * (TargetRate / AlignFFT) / 700); X := 0;
   if (Mel > Edges[J]) and (Mel < Edges[J + 1]) Then    X := (Mel - Edges[J]) / (Edges[J +
   1] - Edges[J])
   else if (Mel >= Edges[J + 1]) and (Mel < Edges[J + 2]) Then    X := (Edges[J + 2] -
   Mel) / (Edges[J + 2] - Edges[J + 1]);
   Filters[J, K] := X;
  End;
  DCT[0, J] := Sqrt(1 / M.MelBins);
  For I := 1 to AlignDims - 1 do   DCT[I, J] := Sqrt(2 / M.MelBins) * Cos(Pi * I * (J +
  0.5) / M.MelBins);
 End;
 For Frame := 0 to High(Base) do Begin
  FillChar(Re, SizeOf(Re), 0); FillChar(Im, SizeOf(Im), 0); Mean := 0; Energy := 0;
  For I := 0 to AlignWindow - 1 do Begin
   Index := Frame * AlignHop + AlignHop div 2 - AlignWindow div 2 + I;
   While (Index < 0) or (Index >= Length(Audio)) do    if Index < 0 Then Index := -Index -
   1 else Index := 2 * Length(Audio) - 1 - Index;
   Re[I] := Audio[Index] * 32768; Mean := Mean + Re[I];
  End;
  Mean := Mean / AlignWindow;
  For I := 0 to AlignWindow - 1 do Begin
   Re[I] := Re[I] - Mean; Energy := Energy + Re[I] * Re[I];
  End;
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
  For Frame := 0 to High(Base) do
  For I := 0 to 12 do Begin
   X := 0;
   For J := -2 to 2 do X := X + J * Base[Max(0, MinInt(High(Base), Frame + J))][I];
   Delta[Frame][I] := X / 10;
  End;
 End;
 For Frame := 0 to High(Base) do Begin
  SetLength(Features[Frame], M.Dimension);
  if Length(M.LDA) > 0 Then Begin
   For I := 0 to M.Dimension - 1 do Begin
    X := 0; Offset := I * M.LdaCols;
    For J := -3 to 3 do
    For K := 0 to 12 do     X := X + M.LDA[Offset + (J + 3) * 13 + K] * Base[Max(0,
    MinInt(High(Base), Frame + J))][K];
    if M.LdaCols = 92 Then X := X + M.LDA[Offset + 91];
    Features[Frame][I] := X;
   End;
  End else
  For I := 0 to 12 do Begin
   Features[Frame][I] := Base[Frame][I];
   if M.Dimension = 39 Then Begin
    Features[Frame][I + 13] := Delta[Frame][I]; X := 0;
    For J := -2 to 2 do X := X + J * Delta[Max(0, MinInt(High(Base), Frame + J))][I];
    Features[Frame][I + 26] := X / 10;
   End;
  End;
 End;
End;

Type
 TLexEntry = record WordText: string;
 Phones: TIntVector;
 Probability: Double;
End;
TLexicon = array of TLexEntry;
TWordList = array of TLexEntry;
TPhoneNode = record Phone, Owner: Integer;
Optional: Boolean;
End;
TPhoneNodes = array of TPhoneNode;
TContextNode = record Node, LeftNode, RightNode, FirstState: Integer;
End;
TContexts = array of TContextNode;
TArc = record Source: Integer;
Score: Double;
End;
TAlignState = record
Pdf, PhoneNode: Integer;
Incoming: array of TArc;
Initial, FinalScore: Double;
End;
TAlignStates = array of TAlignState;

Const
 ImpossibleScore = -1E100;

Function NormalizeFrench(const Text: string): string;
Var
 I, Code, Next: Integer;
Begin
 NormalizeFrench := ''; I := 1;
 While I <= Length(Text) do Begin
  Code := Ord(Text[I]); Inc(I);
  if (Code >= $C2) and (Code <= $DF) and (I <= Length(Text)) Then Begin
   Next := Ord(Text[I]); Inc(I); Code := ((Code and 31) shl 6) or (Next and 63);
  End else if (Code >= $E0) and (Code <= $EF) and (I + 1 <= Length(Text)) Then Begin
   Code := ((Code and 15) shl 12) or ((Ord(Text[I]) and 63) shl 6) or (Ord(Text[I + 1])
   and 63); Inc(I, 2);
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
  if Code < 128 Then NormalizeFrench := NormalizeFrench + Chr(Code)
  else NormalizeFrench := NormalizeFrench + Chr($C0 or (Code shr 6)) + Chr($80 or (Code and 63));
 End;
 NormalizeFrench := Trim(NormalizeFrench);
End;

Function PhoneID(const M: TKaldiModel; const Name: string): Integer;
Var
 I: Integer;
Begin
 For I := 1 to High(M.PhoneNames) do if M.PhoneNames[I] = Name Then Exit(I);
 Fail('Phoneme du dictionnaire absent du modele: ' + Name); PhoneID := -1;
End;

Procedure SortLexicon(var Lex: TLexicon; Left, Right: Integer);
Var
 I, J: Integer;
 Pivot: string;
 Swap: TLexEntry;
Begin
 I := Left; J := Right; Pivot := Lex[(Left + Right) div 2].WordText;
 repeat
 While Lex[I].WordText < Pivot do Inc(I);
 While Lex[J].WordText > Pivot do Dec(J);
 if I <= J Then Begin
  Swap := Lex[I]; Lex[I] := Lex[J]; Lex[J] := Swap; Inc(I); Dec(J);
 End;
 until I > J;
 if Left < J Then SortLexicon(Lex, Left, J);
 if I < Right Then SortLexicon(Lex, I, Right);
End;

Procedure LoadLexicon(const Name: string; const M: TKaldiModel; var Lex: TLexicon);
Var
 Data, Line, WordText, Token: string;
 Start, Finish, P, N, I, Count, Code: Integer;
 Fields: TStringVector;
 Probability, NumericValue: Double;
Begin
 Data := LoadText(Name); Start := 1; Count := 0; SetLength(Lex, 1024);
 While Start <= Length(Data) do Begin
  Finish := Start;
  While (Finish <= Length(Data)) and (Data[Finish] <> #10) do Inc(Finish);
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
   if (NumericValue < 0) or (NumericValue > 1E6) Then Fail(
   'Valeur lexicale hors limites: ' + WordText);
   if I = 0 Then Probability := Number(Fields[I], 'probabilite lexicale');
   Inc(I);
  End;
  if not (I in [0,1,4]) or (I = N) or (Probability <= 0) or (Probability > 1) Then   Fail(
  'Format/probabilite du dictionnaire MFA invalide: ' + WordText);
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
Var
 L, R, Mid, Best: Integer;
Begin
 L := 0; R := Length(Lex);
 While L < R do Begin
  Mid := (L + R) div 2; if Lex[Mid].WordText < WordText Then L := Mid + 1 else R := Mid;
 End;
 if (L >= Length(Lex)) or (Lex[L].WordText <> WordText) Then Exit(-1);
 Best := L;
 While (L < Length(Lex)) and (Lex[L].WordText = WordText) do Begin
  if Lex[L].Probability > Lex[Best].Probability Then Best := L;
  Inc(L);
 End;
 LookupWord := Best;
End;

Procedure TranscriptWords(const Text: string; const Lex: TLexicon; var Words: TWordList);
Var
 Normalized, Token: string;
 P: Integer;

Procedure Append(const WordText: string; Depth: Integer);
Var
 Index, Split, N: Integer;
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
 N := Length(Words);
 if N >= 4096 Then Fail('Transcription trop longue pour l''alignement.');
 SetLength(Words, N + 1); Words[N] := Lex[Index];
End;
Begin
 SetLength(Words, 0); Normalized := NormalizeFrench(Text); P := 1;
 repeat Token := NextToken(Normalized, P); if Token = '' Then Break; Append(Token, 0);
 until False;
 if Length(Words) = 0 Then Fail('La transcription ne contient aucun mot alignable.');
End;

Function TransitionIndex(const M: TKaldiModel; Phone, State, Pdf: Integer): Integer;
Var
 L, R, Mid, Compare: Integer;
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
 Fail('Transition (phone, etat, pdf) absente du modele Kaldi.'); TransitionIndex := -1;
End;
Procedure BuildAlignmentGraph(const M: TKaldiModel; const Words: TWordList;

var Nodes: TPhoneNodes; var States: TAlignStates);
Var
 Contexts: TContexts;
 P, I, J, K, L, R, C, D, N, Phone, LeftPhone, RightPhone,
 Topo, State, PDF, Transition, Dest, First, Target, Sil: Integer;
 InitialSilence, SilenceProbability, Probability, SelfProb, Weight: Double;

Procedure AddPhone(ID, Owner: Integer; Optional: Boolean);
Var
 N: Integer;
Begin
 N := Length(Nodes); SetLength(Nodes, N + 1);
 Nodes[N].Phone := ID; Nodes[N].Owner := Owner; Nodes[N].Optional := Optional;
End;

Function Adjacent(A, B: Integer): Boolean;Begin
 Adjacent := B = A + 1;
 if (B = A + 2) and (A + 1 >= 0) and (A + 1 < Length(Nodes)) Then Adjacent := Nodes[A +
 1].Optional;
End;

Procedure AddArc(Source, Destination: Integer; Score: Double);
Var
 N: Integer;
Begin
 N := Length(States[Destination].Incoming);
 SetLength(States[Destination].Incoming, N + 1);
 States[Destination].Incoming[N].Source := Source;
 States[Destination].Incoming[N].Score := Score;
End;
Begin
 SetLength(Nodes, 0); SetLength(States, 0); SetLength(Contexts, 0);
 Sil := PhoneID(M, JsonValue(M.Metadata, 'optional_silence_phone'));
 InitialSilence := Number(JsonValue(M.Metadata, 'initial_silence_probability'),
 'initial_silence_probability');
 SilenceProbability := Number(JsonValue(M.Metadata, 'silence_probability'),
 'silence_probability');
 if (InitialSilence <= 0) or (InitialSilence >= 1) or (SilenceProbability <= 0) or (
 SilenceProbability >= 1) Then  Fail('Probabilites de silence hors ]0,1[.');
 AddPhone(Sil, -1, True);
 For I := 0 to High(Words) do Begin
  For J := 0 to High(Words[I].Phones) do AddPhone(Words[I].Phones[J], I, False);
  AddPhone(Sil, -1, True);
 End;
 if Length(Nodes) > 12000 Then Fail('Trop de phonemes pour l''alignement.');
 For P := 0 to High(Nodes) do
 For L := Max(-1, P - 2) to P - 1 do if Adjacent(L, P) Then
 For R := P + 1 to MinInt(Length(Nodes), P + 2) do if Adjacent(P, R) Then Begin
  C := Length(Contexts); SetLength(Contexts, C + 1);
  Contexts[C].Node := P; Contexts[C].LeftNode := L; Contexts[C].RightNode := R;
  Contexts[C].FirstState := Length(States);
  Phone := Nodes[P].Phone; Bounded(Phone, 1, High(M.PhoneTopology), 'phone graphe');
  Topo := Bounded(M.PhoneTopology[Phone], 0, High(M.Topologies), 'topologie graphe');
  N := Length(M.Topologies[Topo]) - 1; First := Length(States);
  SetLength(States, First + N);
  LeftPhone := 0; RightPhone := 0;
  if L >= 0 Then LeftPhone := Nodes[L].Phone;
  if R < Length(Nodes) Then RightPhone := Nodes[R].Phone;
  For J := 0 to N - 1 do Begin
   States[First + J].Pdf := TreePdf(M, LeftPhone, Phone, RightPhone,
   M.Topologies[Topo][J].PdfClass);
   States[First + J].PhoneNode := P;
   States[First + J].Initial := ImpossibleScore;
   States[First + J].FinalScore := ImpossibleScore;
  End;
  if L = -1 Then Begin
   if Nodes[P].Optional Then Probability := InitialSilence else Probability := 1 -
   InitialSilence;
   States[First].Initial := Ln(Probability);
  End;
 End;
 if Length(States) > 65534 Then Fail('Graphe d''alignement trop grand.');
 For C := 0 to High(Contexts) do Begin
  P := Contexts[C].Node; Phone := Nodes[P].Phone;
  Topo := M.PhoneTopology[Phone]; N := Length(M.Topologies[Topo]) - 1;
  First := Contexts[C].FirstState;
  For J := 0 to N - 1 do Begin
   State := First + J; PDF := States[State].Pdf;
   Transition := TransitionIndex(M, Phone, J, PDF); SelfProb := 0;
   For K := 0 to High(M.Topologies[Topo][J].Dest) do    if M.Topologies[Topo][J].Dest[K] =
   J Then SelfProb := Exp(M.LogProbs[M.Transitions[Transition].First + K]);
   if SelfProb >= 1 Then Fail('Self-loop de probabilite 1.');
   For K := 0 to High(M.Topologies[Topo][J].Dest) do Begin
    Dest := M.Topologies[Topo][J].Dest[K];
    Weight := M.LogProbs[M.Transitions[Transition].First + K];
    { Echelles standard d'alignement: transitions 1, self-loops 0.1. }
    if Dest = J Then Weight := 0.1 * Weight else Weight := Weight - 0.9 * Ln(1 - SelfProb)
    ;
    if Dest < N Then AddArc(State, First + Dest, Weight)
    else if Contexts[C].RightNode = Length(Nodes) Then Begin
     if not Nodes[P].Optional Then Weight := Weight + Ln(1 - SilenceProbability);
     States[State].FinalScore := Weight;
    End else
    Begin
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
Var
 I, J, Offset: Integer;
 Value, Best, Sum: Double;
 Scores: array of Double;
Begin
 SetLength(Scores, G.Count); Best := ImpossibleScore;
 For I := 0 to G.Count - 1 do Begin
  Value := G.Constants[I]; Offset := I * Length(Features);
  For J := 0 to High(Features) do Value := Value + G.Means[Offset + J] * Features[J] -
  0.5 * G.InverseVars[Offset + J] * Features[J] * Features[J];
  Scores[I] := Value; if Value > Best Then Best := Value;
 End;
 Sum := 0;
 For I := 0 to G.Count - 1 do if Scores[I] > Best - 40 Then Sum := Sum + Exp(Scores[I] -
 Best);
 GMMScore := Best + Ln(Sum);
End;
Procedure ViterbiAlign(const Features: TAcousticFeatures; const M: TKaldiModel;

const States: TAlignStates; var Path: TIntVector);
Var
 Previous, Current, Scores: array of Double;
 Marks: TIntVector;
 Back: array of Word;
 T, S, I, Source, PDF, BestState: Integer;
 Value, Best, Peak: Double;
Begin
 if Int64(Length(Features)) * Length(States) > 32000000 Then  Fail(
 'Alignement trop grand (32 millions de cellules); decouper le WAV et le texte.');
 SetLength(Back, Length(Features) * Length(States));
 SetLength(Previous, Length(States)); SetLength(Current, Length(States));
 SetLength(Scores, Length(M.PDFs)); SetLength(Marks, Length(M.PDFs));
 For I := 0 to High(Marks) do Marks[I] := -1;
 For T := 0 to High(Features) do Begin
  Peak := ImpossibleScore;
  For S := 0 to High(States) do Begin
   Best := ImpossibleScore; BestState := 0;
   if T = 0 Then Best := States[S].Initial
   else
   For I := 0 to High(States[S].Incoming) do Begin
    Source := States[S].Incoming[I].Source;
    Value := Previous[Source] + States[S].Incoming[I].Score;
    if Value > Best Then Begin
     Best := Value; BestState := Source;
    End;
   End;
   if Best > ImpossibleScore / 2 Then Begin
    PDF := States[S].Pdf;
    if Marks[PDF] <> T Then Begin
     Scores[PDF] := GMMScore(M.PDFs[PDF], Features[T]); Marks[PDF] := T;
    End;
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
  if Value > Best Then Begin
   Best := Value; BestState := S;
  End;
 End;
 if (BestState < 0) or (Best <= ImpossibleScore / 2) Then Fail(
 'Audio trop court ou texte impossible a aligner.');
 SetLength(Path, Length(Features)); S := BestState;
 For T := High(Path) downto 0 do Begin
  Path[T] := States[S].PhoneNode; S := Back[T * Length(States) + S];
 End;
End;

Function GridQuote(const Text: string): string;
Var
 I: Integer;
Begin
 GridQuote := '"';
 For I := 1 to Length(Text) do Begin
  GridQuote := GridQuote + Text[I]; if Text[I] = '"' Then GridQuote := GridQuote + '"';
 End;
 GridQuote := GridQuote + '"';
End;
Procedure WriteAlignmentGrid(const FileName: string; SampleCount: Integer;
const M: TKaldiModel;

const Words: TWordList; const Nodes: TPhoneNodes; const Path: TIntVector);
Var
 S: TBinary;
 Tier, T, First, Last, Owner, NextOwner, Count, Index: Integer;
 LabelText: string;

Procedure PutLine(const Text: string);
Var
 Value: string;
Begin
 Value := Text + LineEnding; WriteBytes(S, Value[1], Length(Value));
End;

Function LabelID(Frame: Integer): Integer;Begin
 LabelID := Path[Frame]; if Tier = 1 Then LabelID := Nodes[LabelID].Owner;
End;
Begin
 OpenBinary(S, FileName, True);
 PutLine('File type = "ooTextFile"'); PutLine('Object class = "TextGrid"'); PutLine('');
 PutLine('xmin = 0'); PutLine('xmax = ' + AudioDuration(SampleCount));
 PutLine('tiers? <exists>'); PutLine('size = 2'); PutLine('item []:');
 For Tier := 1 to 2 do Begin
  Count := 1;
  For T := 1 to High(Path) do if LabelID(T) <> LabelID(T - 1) Then Inc(Count);
  PutLine('    item [' + IntToStr(Tier) + ']:');
  PutLine('        class = "IntervalTier"');
  if Tier = 1 Then LabelText := 'words' else LabelText := 'phones';
  PutLine('        name = ' + GridQuote(LabelText)); PutLine('        xmin = 0');
  PutLine('        xmax = ' + AudioDuration(SampleCount));
  PutLine('        intervals: size = ' + IntToStr(Count));
  First := 0; Index := 0;
  While First < Length(Path) do Begin
   Last := First + 1; Owner := LabelID(First);
   While Last < Length(Path) do Begin
    NextOwner := LabelID(Last); if NextOwner <> Owner Then Break; Inc(Last);
   End;
   LabelText := '';
   if Tier = 1 Then Begin
    if Owner >= 0 Then LabelText := Words[Owner].WordText;
   End
   else LabelText := M.PhoneNames[Nodes[Owner].Phone];
   Inc(Index); PutLine('        intervals [' + IntToStr(Index) + ']:');
   PutLine('            xmin = ' + AudioDuration(MinInt(SampleCount, First * AlignHop)));
   if Last = Length(Path) Then T := SampleCount else T := MinInt(SampleCount, Last *
   AlignHop);
   PutLine('            xmax = ' + AudioDuration(T));
   PutLine('            text = ' + GridQuote(LabelText));
   First := Last;
  End;
 End;
 CloseBinary(S);
End;


Procedure CleanupWork;
Begin
 if PartialOutput <> '' Then
  if DeleteFile(PartialOutput) Then PartialOutput := '';
End;

Type
 TJob = record Audio, Transcript, Output: string; End;
 TJobs = array of TJob;
Var
 Jobs: TJobs;
 Model: TKaldiModel;
 Lexicon: TLexicon;
 Arguments: TStringVector;
 Command, DictionaryName, ModelName, OutputName: string;
 Quiet: Boolean;
 I, N: Integer;

Procedure Help;
Begin
 WriteLn('MFA Pascal 1.0 - alignement acoustique natif GMM-HMM');
 WriteLn('Usage: mfa align CORPUS DICTIONARY ACOUSTIC_MODEL OUTPUT');
 WriteLn('       mfa align_one SOUND_FILE TEXT_FILE DICTIONARY ACOUSTIC_MODEL OUTPUT');
 WriteLn('Options: -h, --help, /? ; --version ; -q, --quiet');
 WriteLn('Audio: WAV PCM/float. Transcriptions UTF-8 .lab ou .txt (.lab prioritaire).');
 WriteLn('Sortie: TextGrid long, pistes words et phones; aucun ecrasement.');
 WriteLn('align_one: OUTPUT est un fichier .TextGrid ou un dossier.');
 WriteLn('Modeles: dossier Kaldi ou archive MFA ZIP GMM-HMM compatible.');
 WriteLn('Alias locaux: models/dictionary/NOM.dict et models/acoustic/NOM.zip');
 WriteLn('Aucun telechargement automatique. Voir MFA.md pour les limites.');
End;

Procedure EnsureDirectory(const Name: string);
Var Parent: string;
Begin
 if (Name = '') or DirectoryExists(Name) Then Exit;
 Parent := ExtractFileDir(Name);
 if (Parent <> '') and (Parent <> Name) Then EnsureDirectory(Parent);
 if not CreateDir(Name) Then Fail('Creation du dossier impossible: ' + Name);
End;

Function ResolveData(const Name, Kind, Extension: string): string;
Var Candidate: string;
Begin
 if FileExists(Name) or DirectoryExists(Name) Then Begin ResolveData := Name; Exit; End;
 Candidate := Name + Extension;
 if FileExists(Candidate) Then Begin ResolveData := Candidate; Exit; End;
 Candidate := 'models/' + Kind + '/' + Name;
 if FileExists(Candidate) or DirectoryExists(Candidate) Then Begin ResolveData := Candidate; Exit; End;
 Candidate := Candidate + Extension;
 if FileExists(Candidate) Then Begin ResolveData := Candidate; Exit; End;
 Fail('Donnees locales introuvables: ' + Name + ' (models/' + Kind + ')');
 ResolveData := '';
End;

Procedure AddJob(const Audio, Transcript, Output: string);
Var J: Integer;
Begin
 if not FileExists(Transcript) Then Fail('Transcription manquante: ' + Transcript);
 if FileExists(Output) or DirectoryExists(Output) Then Fail('Sortie deja existante: ' + Output);
 For J := 0 to High(Jobs) do
  if LowerCase(ExpandFileName(Jobs[J].Output)) = LowerCase(ExpandFileName(Output)) Then
   Fail('Deux fichiers produisent la meme sortie: ' + Output);
 J := Length(Jobs); SetLength(Jobs, J + 1);
 Jobs[J].Audio := Audio; Jobs[J].Transcript := Transcript; Jobs[J].Output := Output;
End;

Procedure ScanCorpus(const Folder, Destination: string; Depth: Integer);
Var Search: SearchRec; Names: TStringVector; A, B, ErrorCode: Integer;
 Name, Temp, Source, Target, Transcript: string;
Begin
 SetLength(Names, 0);
 if Depth > 32 Then Fail('Corpus trop profond (32 niveaux maximum): ' + Folder);
 FindFirst(IncludeTrailingPathDelimiter(Folder) + '*', AnyFile, Search);
 While DosError = 0 do Begin
  Name := Search.Name;
  if (Name <> '.') and (Name <> '..') Then Begin
   A := Length(Names); SetLength(Names, A + 1); Names[A] := Name;
  End;
  FindNext(Search);
 End;
 ErrorCode := DosError;
 FindClose(Search);
 if (ErrorCode <> 18) and (ErrorCode <> 2) Then Fail('Lecture du corpus impossible: ' + Folder);
 For A := 1 to High(Names) do Begin
  Temp := Names[A]; B := A - 1;
  While (B >= 0) and (Names[B] > Temp) do Begin Names[B + 1] := Names[B]; Dec(B); End;
  Names[B + 1] := Temp;
 End;
 For A := 0 to High(Names) do Begin
  Source := IncludeTrailingPathDelimiter(Folder) + Names[A];
  Target := IncludeTrailingPathDelimiter(Destination) + Names[A];
  if DirectoryExists(Source) Then ScanCorpus(Source, Target, Depth + 1)
  else if LowerCase(Copy(Source, Length(Source) - 3, 4)) = '.wav' Then Begin
   Transcript := ChangeFileExt(Source, '.lab');
   if not FileExists(Transcript) Then Transcript := ChangeFileExt(Source, '.txt');
   AddJob(Source, Transcript, ChangeFileExt(Target, '.TextGrid'));
  End;
 End;
End;

Procedure AlignJob(const Job: TJob);
Var Audio, Mono: TSamples; Rate: LongWord; Text: string;
 Words: TWordList; Nodes: TPhoneNodes; States: TAlignStates;
 Features: TAcousticFeatures; Path: TIntVector;
Begin
 Text := LoadText(Job.Transcript);
 if Copy(Text, 1, 3) = #239#187#191 Then Delete(Text, 1, 3);
 TranscriptWords(Text, Lexicon, Words);
 ReadWave(Job.Audio, Audio, Rate);
 Resample(Audio, Rate, Mono); SetLength(Audio, 0);
 RemoveDC(Mono);
 ExtractFeatures(Mono, Model, Features);
 BuildAlignmentGraph(Model, Words, Nodes, States);
 ViterbiAlign(Features, Model, States, Path);
 EnsureDirectory(ExtractFileDir(Job.Output));
 if FileExists(Job.Output) or DirectoryExists(Job.Output) Then Fail('Sortie deja existante: ' + Job.Output);
 PartialOutput := Job.Output;
 WriteAlignmentGrid(Job.Output, Length(Mono), Model, Words, Nodes, Path);
 PartialOutput := '';
 if not Quiet Then WriteLn(Job.Audio, ' -> ', Job.Output);
End;

Begin
 SetLength(Arguments, 0);
 Quiet := False;
 For I := 1 to ParamCount do Begin
  Command := ParamStr(I);
  if (Command = '-h') or (Command = '--help') or (Command = '/?') Then Begin Help; Halt(0); End
  else if Command = '--version' Then Begin WriteLn('MFA Pascal 1.0 (moteur natif du projet)'); Halt(0); End
  else if (Command = '-q') or (Command = '--quiet') Then Quiet := True
  else Begin
   if (Length(Command) > 0) and (Command[1] = '-') Then Fail('Option inconnue: ' + Command);
   N := Length(Arguments); SetLength(Arguments, N + 1); Arguments[N] := Command;
  End;
 End;
 if Length(Arguments) = 0 Then Begin Help; Halt(1); End;
 Command := Arguments[0];
 if Command = 'align' Then Begin
  if Length(Arguments) <> 5 Then Fail('Usage: mfa align CORPUS DICTIONARY ACOUSTIC_MODEL OUTPUT');
  if not DirectoryExists(Arguments[1]) Then Fail('Corpus introuvable: ' + Arguments[1]);
  DictionaryName := Arguments[2]; ModelName := Arguments[3]; OutputName := Arguments[4];
  ScanCorpus(Arguments[1], OutputName, 0);
 End
 else if Command = 'align_one' Then Begin
  if Length(Arguments) <> 6 Then Fail('Usage: mfa align_one SOUND_FILE TEXT_FILE DICTIONARY ACOUSTIC_MODEL OUTPUT');
  DictionaryName := Arguments[3]; ModelName := Arguments[4]; OutputName := Arguments[5];
  if LowerCase(Copy(OutputName, Length(OutputName) - 8, 9)) <> '.textgrid' Then
   OutputName := IncludeTrailingPathDelimiter(OutputName) + ChangeFileExt(ExtractFileName(Arguments[1]), '.TextGrid');
  AddJob(Arguments[1], Arguments[2], OutputName);
 End
 else Fail('Commande inconnue: ' + Command);
 if Length(Jobs) = 0 Then Fail('Aucun fichier WAV dans le corpus.');
 DictionaryName := ResolveData(DictionaryName, 'dictionary', '.dict');
 ModelName := ResolveData(ModelName, 'acoustic', '.zip');
 if not Quiet Then WriteLn('Chargement du modele acoustique: ', ModelName);
 LoadKaldiModel(ModelName, Model); LoadLexicon(DictionaryName, Model, Lexicon);
 For I := 0 to High(Jobs) do AlignJob(Jobs[I]);
 if not Quiet Then WriteLn(Length(Jobs), ' fichier(s) aligne(s).');
End.
