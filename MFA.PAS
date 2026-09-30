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
 TBinary = Record
  Handle: File;
  Name: String;
  Size, Position: Int64;
  Buffer: Array[0..8191] Of Byte;
  Used, Index: LongInt;
  Writing: Boolean;
 End;
 PBinary = ^TBinary;
 TSamples = Array Of Single;

Const
 TargetRate = 16000;
 MaxInputBytes = 268435456;
 { limite explicite: 256 Mio }
 MaxSeconds = 1800;

Var
 OpenFiles: Array[0..7] Of PBinary;
 PartialOutput: String;
Procedure Fail(Const S: String);Forward;
Procedure CleanupWork;Forward;
{ Services proceduraux locaux, sans Classes, SysUtils ni Process. }

Function IntToStr(Value: Int64): String;Begin
 Str(Value, IntToStr);
End;

Function Trim(Const Text: String): String;
Var
 First, Last: Integer;
Begin
 First := 1; Last := Length(Text);
 While (First <= Last) And (Text[First] <= ' ') Do Inc(First);
 While (Last >= First) And (Text[Last] <= ' ') Do Dec(Last);
 Trim := Copy(Text, First, Last - First + 1);
End;

Function LowerCase(Const Text: String): String;
Var
 I: Integer;
Begin
  { Seul le suffixe ASCII des noms de modeles est compare. }
 LowerCase := Text;
 For I := 1 To Length(LowerCase) Do    If LowerCase[I] In ['A'..'Z'] Then LowerCase[I] :=
 Chr(Ord(
 LowerCase[I]) + 32);
End;

Function IsPathDelimiter(C: Char): Boolean;Begin
 {$IFDEF MSWINDOWS}
  IsPathDelimiter := C In ['/', '\'];
 {$ELSE}
  IsPathDelimiter := C = '/';
 {$ENDIF}
End;

Function IncludeTrailingPathDelimiter(Const Path: String): String;Begin
 IncludeTrailingPathDelimiter := Path;
 If (IncludeTrailingPathDelimiter = '') Or Not IsPathDelimiter(
 IncludeTrailingPathDelimiter[Length(IncludeTrailingPathDelimiter)])
 Then    IncludeTrailingPathDelimiter :=
 IncludeTrailingPathDelimiter + DirectorySeparator;
End;

Function ExtractFileName(Const Path: String): String;
Var
 I: Integer;
Begin
 I := Length(Path);
 While (I > 0) And Not IsPathDelimiter(Path[I]) Do Dec(I);
 ExtractFileName := Copy(Path, I + 1, Length(Path) - I);
End;

Function ExtractFileDir(Const Path: String): String;
Var
 I: Integer;
Begin
 I := Length(Path);
 While (I > 0) And Not IsPathDelimiter(Path[I]) Do Dec(I);
  { Conserver le separateur des racines / et C:\. }
 If (I = 1)
 {$IFDEF MSWINDOWS}
  Or ((I = 3) And (Path[2] = ':'))
 {$ENDIF}
 Then    ExtractFileDir := Copy(Path, 1, I) Else
 If I > 0 Then ExtractFileDir := Copy(Path, 1, I - 1)
          Else ExtractFileDir := '';
End;

Function ChangeFileExt(Const Path, Extension: String): String;
Var
 I: Integer;
Begin
 I := Length(Path);
 While (I > 0) And Not IsPathDelimiter(Path[I]) And (Path[I] <> '.') Do Dec(I);
 If (I > 0) And (Path[I] = '.') Then ChangeFileExt := Copy(Path, 1, I - 1) + Extension
                                Else ChangeFileExt := Path + Extension;
End;

Function ExpandFileName(Const Path: String): String;
Var
 Current: String;
Begin
  { Construire un chemin absolu sans limite ShortString. Les composants
    . et .. restent resolves par le systeme de fichiers. }
 GetDir(0, Current);
 {$IFDEF MSWINDOWS}
  If (Length(Path) >= 2) And (Path[2] = ':') Then Begin
   If (Length(Path) >= 3) And IsPathDelimiter(Path[3]) Then Exit(Path);
   If UpCase(Path[1]) In ['A'..'Z'] Then      GetDir(Ord(UpCase(Path[1])) - Ord('A') + 1,
   Current);
   Exit(IncludeTrailingPathDelimiter(Current) + Copy(Path, 3, Length(Path)));
  End;
  If (Length(Path) >= 2) And IsPathDelimiter(Path[1]) And IsPathDelimiter(Path[2])
  Then    Exit(Path);
  If (Path <> '') And IsPathDelimiter(Path[1]) Then Exit(Copy(Current, 1, 2) + Path);
 {$ELSE}
  If (Path <> '') And IsPathDelimiter(Path[1]) Then Exit(Path);
 {$ENDIF}
 ExpandFileName := IncludeTrailingPathDelimiter(Current) + Path;
End;

Function PathAttributes(Const Name: String; Var Attributes: Word): Boolean;
Var
 F: File;
Begin
 Assign(F, Name);
 DOS.GetFAttr(F, Attributes);
 PathAttributes := DosError = 0;
End;

Function FileExists(Const Name: String): Boolean;
Var
 Attributes: Word;
Begin
 FileExists := PathAttributes(Name, Attributes);
 If FileExists Then FileExists := (Attributes And Directory) = 0;
End;

Function DirectoryExists(Const Name: String): Boolean;
Var
 Attributes: Word;
Begin
 DirectoryExists := PathAttributes(Name, Attributes);
 If DirectoryExists Then DirectoryExists := (Attributes And Directory) <> 0;
End;

Function CreateDir(Const Name: String): Boolean;Begin
  {$I-}
 MkDir(Name);
 CreateDir := IOResult = 0;
  {$I+}
End;

Function RemoveDir(Const Name: String): Boolean;Begin
  {$I-}
 RmDir(Name);
 RemoveDir := IOResult = 0;
  {$I+}
End;

Function DeleteFile(Const Name: String): Boolean;
Var
 F: File;
Begin
 Assign(F, Name);
  {$I-}
 Erase(F);
 DeleteFile := IOResult = 0;
  {$I+}
End;

Function AudioDuration(SampleCount: Integer): String;
Var
 Fraction: String;
Begin
  { 1/16000 = 0.0000625: representation exacte, independante de la locale. }
 Fraction := IntToStr((SampleCount Mod TargetRate) * 625);
 While Length(Fraction) < 7 Do Fraction := '0' + Fraction;
 While (Length(Fraction) > 1) And (Fraction[Length(Fraction)] = '0') Do    SetLength(
 Fraction, Length(Fraction) - 1);
 AudioDuration := IntToStr(SampleCount Div TargetRate) + '.' + Fraction;
End;
{ Fonctions numeriques locales: aucune dependance directe a l'unite Math.
  Abs, Sin, Cos, Pi, Round et Trunc sont fournis par l'unite System. }

Function MinInt(A, B: Integer): Integer;Begin
 If A < B Then MinInt := A Else MinInt := B;
End;

Function MinDouble(A, B: Double): Double;Begin
 If A < B Then MinDouble := A Else MinDouble := B;
End;

Function Max(A, B: Integer): Integer;Begin
 If A > B Then Max := A Else Max := B;
End;

Function EnsureRange(Value, LowerBound, UpperBound: Double): Double;Begin
 If Value < LowerBound Then EnsureRange := LowerBound Else
 If Value > UpperBound Then EnsureRange := UpperBound
                       Else EnsureRange := Value;
End;
{ Les appels du reechantillonneur portent sur des valeurs finies dont
  les arrondis sont representables en Int64. Trunc arrondit vers zero. }

Function Floor(Value: Double): Int64;Begin
 Floor := Trunc(Value);
 If Value < Floor Then Dec(Floor);
End;

Function Ceil(Value: Double): Int64;Begin
 Ceil := Trunc(Value);
 If Value > Ceil Then Inc(Ceil);
End;
{ Inspection IEEE 754 binary32 sans operation flottante, y compris pour
  les NaN signalants. Ces fonctions servent aux echantillons WAV float32. }

Function IsNan(Const Value: Single): Boolean;
Var
 Bits: LongWord;
Begin
 Move(Value, Bits, SizeOf(Bits));
 IsNan := ((Bits And $7F800000) = $7F800000) And
 ((Bits And $007FFFFF) <> 0);
End;

Function IsInfinite(Const Value: Single): Boolean;
Var
 Bits: LongWord;
Begin
 Move(Value, Bits, SizeOf(Bits));
 IsInfinite := (Bits And $7FFFFFFF) = $7F800000;
End;

Procedure Fail(Const S: String);
Var
 I, ErrorCode: Integer;
Begin
 WriteLn(StdErr, 'MFA: ', S);
  { Fermer les fichiers encore ouverts avant de supprimer les temporaires.
    Les pointeurs concernent des records toujours presents sur la pile. }
 For I := 0 To High(OpenFiles) Do    If OpenFiles[I] <> Nil Then Begin
      {$I-}
  Close(OpenFiles[I]^.Handle); ErrorCode := IOResult;
      {$I+}
  If ErrorCode <> 0 Then WriteLn(StdErr, 'Fermeture incomplete: ', OpenFiles[I]^.Name);
  OpenFiles[I] := Nil;
 End;
 CleanupWork;
 Halt(1);
End;

Procedure OpenBinary(Var S: TBinary; Const Name: String; Writing: Boolean);
Var
 I, ErrorCode: Integer;
 OldMode: Byte;
Begin
 S.Name := Name; S.Position := 0; S.Used := 0; S.Index := 0;
 S.Writing := Writing; S.Size := 0;
 Assign(S.Handle, Name);
 OldMode := FileMode; FileMode := $20; { lecture, partage sans ecriture }
  {$I-}
 If Writing Then Rewrite(S.Handle, 1) Else Reset(S.Handle, 1);
 ErrorCode := IOResult;
  {$I+}
 FileMode := OldMode;
 If ErrorCode <> 0 Then Fail('Ouverture impossible: ' + Name + ' (code ' + IntToStr(
 ErrorCode) + ')');
 I := 0;
 While (I <= High(OpenFiles)) And (OpenFiles[I] <> Nil) Do Inc(I);
 If I > High(OpenFiles) Then Begin
    {$I-}Close(S.Handle); ErrorCode := IOResult;{$I+}
  Fail('Trop de fichiers ouverts.');
 End;
 OpenFiles[I] := @S;
  {$I-}
 S.Size := FileSize(S.Handle); ErrorCode := IOResult;
  {$I+}
 If ErrorCode <> 0 Then Fail('Taille inaccessible: ' + Name);
End;

Procedure FlushBinary(Var S: TBinary);
Var
 Count, ErrorCode: LongInt;
Begin
 If Not S.Writing Or (S.Used = 0) Then Exit;
  {$I-}
 BlockWrite(S.Handle, S.Buffer, S.Used, Count); ErrorCode := IOResult;
  {$I+}
 If (ErrorCode <> 0) Or (Count <> S.Used) Then Fail('Ecriture incomplete: ' + S.Name);
 S.Used := 0;
End;

Procedure CloseBinary(Var S: TBinary);
Var
 I, ErrorCode: Integer;
Begin
 FlushBinary(S);
  {$I-}Close(S.Handle); ErrorCode := IOResult;{$I+}
 For I := 0 To High(OpenFiles) Do    If OpenFiles[I] = @S Then OpenFiles[I] := Nil;
 If ErrorCode <> 0 Then Fail('Fermeture impossible: ' + S.Name);
End;

Procedure ReadBytes(Var S: TBinary; Var Dest; Count: LongInt);
Var
 P: PByte;
 N, ErrorCode: LongInt;
Begin
 P := @Dest;
 While Count > 0 Do Begin
  If S.Index = S.Used Then Begin
      {$I-}
   BlockRead(S.Handle, S.Buffer, SizeOf(S.Buffer), S.Used); ErrorCode := IOResult;
      {$I+}
   If (ErrorCode <> 0) Or (S.Used = 0) Then Fail('Lecture incomplete: ' + S.Name);
   S.Index := 0;
  End;
  N := MinInt(Count, S.Used - S.Index);
  Move(S.Buffer[S.Index], P^, N);
  Inc(P, N); Inc(S.Index, N); Inc(S.Position, N); Dec(Count, N);
 End;
End;

Procedure WriteBytes(Var S: TBinary; Const Source; Count: LongInt);
Var
 P: PByte;
 N: LongInt;
Begin
 P := @Source;
 While Count > 0 Do Begin
  N := MinInt(Count, SizeOf(S.Buffer) - S.Used);
  Move(P^, S.Buffer[S.Used], N);
  Inc(P, N); Inc(S.Used, N); Inc(S.Position, N); Dec(Count, N);
  If S.Used = SizeOf(S.Buffer) Then FlushBinary(S);
 End;
End;

Procedure SeekBinary(Var S: TBinary; Position: Int64);
Var
 ErrorCode: Integer;
Begin
 FlushBinary(S);
  {$I-}Seek(S.Handle, Position); ErrorCode := IOResult;{$I+}
 If ErrorCode <> 0 Then Fail('Position inaccessible: ' + S.Name);
 S.Position := Position; S.Index := 0; S.Used := 0;
End;

Function LoadText(Const Name: String): String;
Var
 S: TBinary;
Begin
 OpenBinary(S, Name, False);
 If S.Size > MaxInputBytes Then Fail('Fichier texte trop grand: ' + Name);
 SetLength(LoadText, S.Size);
 If S.Size > 0 Then ReadBytes(S, LoadText[1], S.Size);
 CloseBinary(S);
  { Le BOM UTF-8 eventuel n'est pas une partie du texte prononce. }
 If Copy(LoadText, 1, 3) = #$EF#$BB#$BF Then Delete(LoadText, 1, 3);
End;

Procedure SaveText(Const Name, Text: String);
Var
 S: TBinary;
Begin
 OpenBinary(S, Name, True);
 If Text <> '' Then WriteBytes(S, Text[1], Length(Text));
 CloseBinary(S);
End;

Function U16(Var S: TBinary): Word;
Var
 B: Array[0..1] Of Byte;
Begin
 ReadBytes(S, B, 2);
 U16 := Word(B[0]) Or (Word(B[1]) Shl 8);
End;

Function U32(Var S: TBinary): LongWord;
Var
 B: Array[0..3] Of Byte;
Begin
 ReadBytes(S, B, 4);
 U32 := LongWord(B[0]) Or (LongWord(B[1]) Shl 8) Or
 (LongWord(B[2]) Shl 16) Or (LongWord(B[3]) Shl 24);
End;

Function FourCC(Var S: TBinary): AnsiString;Begin
 SetLength(FourCC, 4);
 ReadBytes(S, FourCC[1], 4);
End;

Procedure Put16(Var S: TBinary; V: Word);
Var
 B: Array[0..1] Of Byte;
Begin
 B[0] := V And 255; B[1] := V Shr 8;
 WriteBytes(S, B, 2);
End;

Procedure Put32(Var S: TBinary; V: LongWord);Begin
 Put16(S, V And 65535); Put16(S, V Shr 16);
End;

Procedure Tag(Var S: TBinary; Const V: AnsiString);Begin
 WriteBytes(S, V[1], 4);
End;

Procedure ReadWave(Const Name: String; Var Samples: TSamples; Var Rate: LongWord);
Var
 S: TBinary;
 ID: String;
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
 If (S.Size < 12) Or (S.Size > MaxInputBytes) Then      Fail(
 'WAV vide, trop court ou superieur a 256 Mio.');
 If FourCC(S) <> 'RIFF' Then Fail('Seul RIFF WAV little-endian est accepte.');
 RiffSize := U32(S);
 If FourCC(S) <> 'WAVE' Then Fail('Signature WAVE absente.');
 Limit := Int64(RiffSize) + 8;
 If (Limit > S.Size) Or (Limit < 12) Then Fail('Taille RIFF invalide.');
 HaveFmt := False; HaveData := False;
 Fmt := 0; Channels := 0; Bits := 0; BlockSize := 0; Rate := 0;
 DataPos := 0; DataSize := 0;
 While S.Position < Limit Do Begin
  If Limit - S.Position < 8 Then Fail('Entete de chunk tronquee.');
  ID := FourCC(S); ChunkSize := U32(S);
  ChunkEnd := S.Position + Int64(ChunkSize);
  If ChunkEnd + (ChunkSize And 1) > Limit Then Fail('Chunk WAV tronque.');
  If ID = 'fmt ' Then Begin
   If HaveFmt Or (ChunkSize < 16) Then Fail('Chunk fmt invalide ou repete.');
   Fmt := U16(S); Channels := U16(S); Rate := U32(S);
   ByteRate := U32(S); BlockSize := U16(S); Bits := U16(S);
   If Not (Fmt In [1, 3]) Then          Fail(
   'Encodage non pris en charge: utiliser PCM ou float IEEE WAV.');
   If (Channels < 1) Or (Channels > 8) Or (Rate < 8000) Or (Rate > 192000)
   Then          Fail('Canaux (1..8) ou frequence (8000..192000) invalides.');
   If ((Fmt = 1) And Not (Bits In [8,16,24,32])) Or
   ((Fmt = 3) And (Bits <> 32)) Then Fail('Resolution WAV non prise en charge.');
   If (BlockSize <> Channels * (Bits Div 8)) Or
   (ByteRate <> Rate * LongWord(BlockSize)) Then Fail('Alignement PCM invalide.');
   HaveFmt := True;
  End
  Else If ID = 'data' Then Begin
   If HaveData Then Fail('Plusieurs chunks data non pris en charge.');
   DataPos := S.Position; DataSize := ChunkSize; HaveData := True;
  End;
  SeekBinary(S, ChunkEnd + (ChunkSize And 1));
 End;
 If Not HaveFmt Or Not HaveData Then Fail('Chunks fmt/data manquants.');
 If (DataSize = 0) Or (DataSize Mod BlockSize <> 0) Then Fail('Donnees PCM incompletes.');
 Frames := DataSize Div BlockSize;
 If Frames > Int64(Rate) * MaxSeconds Then Fail('Duree maximale: 30 minutes.');
 SetLength(Samples, Frames);
 SeekBinary(S, DataPos);
 For I := 0 To Frames - 1 Do Begin
  Sum := 0;
  For C := 1 To Channels Do Begin
   V := 0;
   Case Bits Of
   8: ReadBytes(S, V, 1);
   16: V := U16(S);
   24:
   Begin
    V := U16(S); ReadBytes(S, ThirdByte, 1);
    V := V Or (LongWord(ThirdByte) Shl 16);
   End;
   32: V := U32(S);
  End;
  If Fmt = 3 Then Begin
   Move(V, F, 4);
   If IsNan(F) Or IsInfinite(F) Then Fail('Echantillon float non fini.');
   X := F;
  End
  Else If Bits = 8 Then X := (Integer(V) - 128) / 128.0
   Else
  Begin
   SignedValue := V;
   If (QWord(V) And (QWord(1) Shl (Bits - 1))) <> 0 Then            SignedValue :=
   SignedValue - (Int64(1) Shl Bits);
   X := SignedValue / (Int64(1) Shl (Bits - 1));
  End;
  Sum := Sum + EnsureRange(X, -1.0, 1.0);
 End;
 Samples[I] := Sum / Channels;
End;
CloseBinary(S);
End;

Procedure Resample(Const Source: TSamples; Rate: LongWord; Var Dest: TSamples);
Var
 I, J, Center, Radius, Count: Integer;
 Position, Distance, Cutoff, Weight, Total, Norm, Angle: Double;
Begin
 If Rate = TargetRate Then Begin
  Dest := Copy(Source); Exit;
 End;
 Count := (Int64(Length(Source)) * TargetRate + Rate - 1) Div Rate;
 SetLength(Dest, Count);
  { Sinc fenetree Hann, filtre anti-repliement avant sous-echantillonnage.
    Le support augmente avec le rapport des frequences. }
 Cutoff := 0.94 * MinDouble(1.0, TargetRate / Rate);
 Radius := Ceil(16 / Cutoff);
 For I := 0 To Count - 1 Do Begin
  Position := I * (Double(Rate) / TargetRate);
  Center := Floor(Position); Total := 0; Norm := 0;
  For J := Max(0, Center - Radius) To MinInt(High(Source), Center + Radius) Do Begin
   Distance := Position - J;
   If Abs(Distance) >= Radius Then Continue;
   Angle := Pi * Distance * Cutoff;
   If Abs(Angle) < 1E-12 Then Weight := Cutoff
                         Else Weight := Cutoff * Sin(Angle) / Angle;
   Weight := Weight * (0.5 + 0.5 * Cos(Pi * Distance / Radius));
   Total := Total + Source[J] * Weight; Norm := Norm + Weight;
  End;
  If Abs(Norm) > 1E-12 Then Dest[I] := Total / Norm Else Dest[I] := 0;
 End;
End;

Procedure RemoveDC(Var Samples: TSamples);
Var
 I: Integer;
 PrevIn, PrevOut, X: Double;
Begin
  { Passe-haut doux ~40 Hz; pas de gate qui supprimerait les consonnes.
    Le bruit restant est gere par VAD et le modele acoustique entraine. }
 PrevIn := 0; PrevOut := 0;
 For I := 0 To High(Samples) Do Begin
  X := Samples[I] - PrevIn + 0.9844 * PrevOut;
  PrevIn := Samples[I]; PrevOut := X;
  Samples[I] := EnsureRange(X, -1.0, 1.0);
 End;
End;

Procedure WriteWave(Const Name: String; Const Samples: TSamples);
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
 For I := 0 To High(Samples) Do Begin
  V := Round(EnsureRange(Samples[I], -1.0, 1.0) * 32767);
  Put16(S, Word(V));
 End;
 CloseBinary(S);
End;
{ Aligneur interne: lecture des donnees Kaldi, sans executable ni DLL MFA.
  Implementations procedurales des formats binaires et du decodeur GMM-HMM. }

Type
 TIntVector = Array Of LongInt;
 TRealVector = Array Of Single;
 TStringVector = Array Of String;
 TReader = Record
  Data, Name: RawByteString;
  Position: LongInt;
 End;
 THuffman = Record
  Counts: Array[0..15] Of Integer;
  Symbols: Array[0..287] Of Integer;
 End;

Function ReadByte(Var R: TReader): Byte;Begin
 If (R.Position < 1) Or (R.Position > Length(R.Data)) Then Fail('Donnees tronquees: ' +
 R.Name);
 ReadByte := Ord(R.Data[R.Position]); Inc(R.Position);
End;

Function ReadLE(Var R: TReader; Count: Integer): LongWord;
Var
 I: Integer;
Begin
 ReadLE := 0;
 For I := 0 To Count - 1 Do ReadLE := ReadLE Or (LongWord(ReadByte(R)) Shl (8 * I));
End;

Function KToken(Var R: TReader): String;
Var
 C: Byte;
Begin
 KToken := '';
 Repeat C := ReadByte(R); Until C > 32;
 Repeat
 KToken := KToken + Chr(C);
 If Length(KToken) > 100 Then Fail('Token Kaldi invalide: ' + R.Name);
 C := ReadByte(R);
 Until C <= 32;
End;

Procedure KExpect(Var R: TReader; Const Expected: String);
Var
 Actual: String;
Begin
 Actual := KToken(R);
 If Actual <> Expected Then Fail(R.Name + ': attendu ' + Expected + ', obtenu ' + Actual);
End;

Function KInt(Var R: TReader): LongInt;
Var
 Marker: Byte;
Begin
 Marker := ReadByte(R);
 If (Marker <> 4) And (Marker <> 252) Then  Fail('Entier Kaldi non 32 bits: ' + R.Name +
 ', octet ' + IntToStr(R.Position - 1));
 KInt := LongInt(ReadLE(R, 4));
End;

Function Bounded(Value, LowBound, HighBound: LongInt; Const What: String): LongInt;Begin
 If (Value < LowBound) Or (Value > HighBound) Then Fail('Valeur invalide: ' + What);
 Bounded := Value;
End;

Function KFloat(Var R: TReader; WithSize: Boolean): Single;
Var
 Bits: LongWord;
Begin
 If WithSize Then If ReadByte(R) <> 4 Then Fail('Reel Kaldi non float32: ' + R.Name);
 Bits := ReadLE(R, 4); Move(Bits, KFloat, 4);
 If IsNan(KFloat) Or IsInfinite(KFloat) Then Fail('Reel Kaldi non fini: ' + R.Name);
End;

Procedure KHeader(Var R: TReader; Const Data, Name: String);Begin
 R.Data := Data; R.Name := Name; R.Position := 1;
 If (ReadByte(R) <> 0) Or (ReadByte(R) <> Ord('B')) Then  Fail(
 'Modele Kaldi binaire requis: ' + Name);
End;

Procedure KInts(Var R: TReader; Var Values: TIntVector);
Var
 I, N: Integer;
Begin
 { Les vecteurs d'entiers ont une seule marque de taille, puis N brut. }
 If ReadByte(R) <> 4 Then Fail('Vecteur Kaldi invalide: ' + R.Name);
 N := Bounded(LongInt(ReadLE(R, 4)), 0, 1000000, 'taille vecteur');
 If Int64(N) * 4 > Length(R.Data) - R.Position + 1 Then Fail('Vecteur Kaldi tronque: ' +
 R.Name);
 SetLength(Values, N);
 For I := 0 To N - 1 Do Values[I] := LongInt(ReadLE(R, 4));
End;

Procedure KReals(Var R: TReader; Var Values: TRealVector; Var Rows, Cols: Integer;
                 Matrix: Boolean);
Var
 I: Integer;
Begin
 If Matrix Then KExpect(R, 'FM') Else KExpect(R, 'FV');
 Rows := Bounded(KInt(R), 0, 1000000, 'dimension Kaldi'); Cols := 1;
 If Matrix Then Cols := Bounded(KInt(R), 1, 1000, 'colonnes Kaldi');
 If Int64(Rows) * Cols > 16000000 Then Fail('Matrice Kaldi trop grande.');
 If Int64(Rows) * Cols * 4 > Length(R.Data) - R.Position + 1 Then Fail(
 'Matrice Kaldi tronquee: ' + R.Name);
 SetLength(Values, Rows * Cols);
 For I := 0 To High(Values) Do Values[I] := KFloat(R, False);
End;

Procedure MakeHuffman(Const Lengths: Array Of Integer; Var H: THuffman);
Var
 I, Left: Integer;
 Offsets: Array[0..15] Of Integer;
Begin
 FillChar(H, SizeOf(H), 0);
 For I := 0 To High(Lengths) Do Begin
  Bounded(Lengths[I], 0, 15, 'code deflate'); Inc(H.Counts[Lengths[I]]);
 End;
 Left := 1;
 For I := 1 To 15 Do Begin
  Left := Left * 2 - H.Counts[I];
  If Left < 0 Then Fail('Arbre Huffman sursouscrit.');
 End;
 Offsets[1] := 0;
 For I := 1 To 14 Do Offsets[I + 1] := Offsets[I] + H.Counts[I];
 For I := 0 To High(Lengths) Do If Lengths[I] <> 0 Then Begin
  H.Symbols[Offsets[Lengths[I]]] := I; Inc(Offsets[Lengths[I]]);
 End;
End;

Function InflateRaw(Const Compressed: String; ExpectedSize: Integer): String;
Const
 Order: Array[0..18] Of Integer = (16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15);
 LenBase: Array[0..28] Of Integer = (3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,
 67,83,99,115,131,163,195,227,258);
 LenExtra: Array[0..28] Of Integer = (0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,
 5,5,0);
 DistBase: Array[0..29] Of Integer = (1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,
 513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577);
 DistExtra: Array[0..29] Of Integer = (0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,
 11,11,12,12,13,13);
Var
 R: TReader;
 Bits: LongWord;
 BitCount, Used: Integer;
 Lit, Dist, Code: THuffman;
 L: Array[0..287] Of Integer;
 D: Array[0..31] Of Integer;
 C: Array[0..18] Of Integer;
 All: Array[0..319] Of Integer;
 FinalBlock, Kind, NL, ND, NC, I, J, Symbol, N, Distance, Previous, Inverse: Integer;

Function Take(N: Integer): Integer;Begin
 While BitCount < N Do Begin
  Bits := Bits Or (LongWord(ReadByte(R)) Shl BitCount); Inc(BitCount, 8);
 End;
 Take := Bits And ((LongWord(1) Shl N) - 1); Bits := Bits Shr N; Dec(BitCount, N);
End;

Function Decode(Const H: THuffman): Integer;
Var
 Width, Value, First, Offset: Integer;
Begin
 Value := 0; First := 0; Offset := 0;
 For Width := 1 To 15 Do Begin
  Value := (Value Shl 1) Or Take(1);
  If (Value >= First) And (Value < First + H.Counts[Width]) Then    Exit(
  H.Symbols[Offset + Value - First]);
  Inc(Offset, H.Counts[Width]); First := (First + H.Counts[Width]) Shl 1;
 End;
 Fail('Code deflate invalide.'); Decode := 0;
End;

Procedure Emit(Value: Char);Begin
 If Used >= ExpectedSize Then Fail('Taille ZIP decompressee depassee.');
 Inc(Used); InflateRaw[Used] := Value;
End;
Begin
 Bounded(ExpectedSize, 0, MaxInputBytes, 'taille ZIP');
 SetLength(InflateRaw, ExpectedSize);
 R.Data := Compressed; R.Name := 'deflate ZIP'; R.Position := 1;
 Bits := 0; BitCount := 0; Used := 0;
 Repeat
 FinalBlock := Take(1); Kind := Take(2);
 If Kind = 0 Then Begin
  Bits := 0; BitCount := 0;
  N := ReadLE(R, 2); Inverse := ReadLE(R, 2);
  If (N Xor Inverse) <> 65535 Then Fail('Bloc ZIP stocke invalide.');
  For I := 1 To N Do Emit(Chr(ReadByte(R)));
 End Else
 Begin
  FillChar(L, SizeOf(L), 0); FillChar(D, SizeOf(D), 0);
  If Kind = 1 Then Begin
   For I := 0 To 143 Do L[I] := 8;
   For I := 144 To 255 Do L[I] := 9;
   For I := 256 To 279 Do L[I] := 7;
   For I := 280 To 287 Do L[I] := 8;
   For I := 0 To 31 Do D[I] := 5;
  End Else If Kind = 2 Then Begin
   NL := Take(5) + 257; ND := Take(5) + 1; NC := Take(4) + 4;
   FillChar(C, SizeOf(C), 0);
   For I := 0 To NC - 1 Do C[Order[I]] := Take(3);
   MakeHuffman(C, Code); I := 0;
   While I < NL + ND Do Begin
    Symbol := Decode(Code);
    If Symbol <= 15 Then Begin
     All[I] := Symbol; Inc(I);
    End
     Else
    Begin
     Previous := 0;
     Case Symbol Of
     16:
     Begin
      If I = 0 Then Fail('Repetition deflate sans precedent.'); Previous := All[I - 1];
      N := Take(2) + 3;
     End;
     17: N := Take(3) + 3;
     18: N := Take(7) + 11;
      Else
     Begin
      Fail('Longueur deflate invalide.'); N := 0;
     End;
    End;
    If I + N > NL + ND Then Fail('Repetition deflate excessive.');
    For J := 1 To N Do Begin
     All[I] := Previous; Inc(I);
    End;
   End;
  End;
  For I := 0 To NL - 1 Do L[I] := All[I];
  For I := 0 To ND - 1 Do D[I] := All[NL + I];
 End Else Fail('Type de bloc deflate invalide.');
 If L[256] = 0 Then Fail('Fin de bloc deflate absente.');
 MakeHuffman(L, Lit); MakeHuffman(D, Dist);
 Repeat
 Symbol := Decode(Lit);
 If Symbol < 256 Then Emit(Chr(Symbol)) Else
 If Symbol > 256 Then Begin
  Bounded(Symbol, 257, 285, 'longueur deflate'); Dec(Symbol, 257);
  N := LenBase[Symbol] + Take(LenExtra[Symbol]);
  Symbol := Bounded(Decode(Dist), 0, 29, 'distance deflate');
  Distance := DistBase[Symbol] + Take(DistExtra[Symbol]);
  If Distance > Used Then Fail('Distance deflate hors tampon.');
  For I := 1 To N Do Emit(InflateRaw[Used - Distance + 1]);
 End;
 Until Symbol = 256;
End;
Until FinalBlock = 1;
If Used <> ExpectedSize Then Fail('Taille ZIP decompressee incorrecte.');
End;

Function CRC32(Const Data: String): LongWord;
Var
 I, J: Integer;
Begin
 CRC32 := $FFFFFFFF;
 For I := 1 To Length(Data) Do Begin
  CRC32 := CRC32 Xor Ord(Data[I]);
  For J := 1 To 8 Do   If (CRC32 And 1) <> 0 Then CRC32 := (CRC32 Shr 1) Xor $EDB88320
                                             Else CRC32 := CRC32 Shr 1;
 End;
 CRC32 := Not CRC32;
End;

Function ZipMember(Const Archive, Member: String): String;
Var
 R, L: TReader;
 I, Entries, N, Extra, Comment, Method, Flags: Integer;
 Offset, PackedSize, UnpackedSize, Checksum: LongWord;
 Name, Payload: String;
 Found: Boolean;
Begin
 R.Data := Archive; R.Name := 'archive MFA'; Found := False;
 I := Length(Archive) - 21;
 While I >= Max(1, Length(Archive) - 65557) Do Begin
  If Copy(Archive, I, 4) = 'PK' + #5#6 Then Begin
   Found := True; Break;
  End;
  Dec(I);
 End;
 If Not Found Then Fail('Repertoire central ZIP absent.');
 R.Position := I + 4;
 If (ReadLE(R, 2) <> 0) Or (ReadLE(R, 2) <> 0) Then Fail('ZIP multidisque non accepte.');
 Entries := ReadLE(R, 2);
 If ReadLE(R, 2) <> LongWord(Entries) Then Fail('ZIP multidisque non accepte.');
 ReadLE(R, 4); Offset := ReadLE(R, 4);
 R.Position := Bounded(Int64(Offset) + 1, 1, Length(Archive), 'offset ZIP');
 Found := False; ZipMember := '';
 For I := 1 To Entries Do Begin
  If ReadLE(R, 4) <> $02014B50 Then Fail('Entree ZIP invalide.');
  ReadLE(R, 2); ReadLE(R, 2); Flags := ReadLE(R, 2); Method := ReadLE(R, 2);
  ReadLE(R, 4); Checksum := ReadLE(R, 4); PackedSize := ReadLE(R, 4);
  UnpackedSize := ReadLE(R, 4);
  N := ReadLE(R, 2); Extra := ReadLE(R, 2); Comment := ReadLE(R, 2);
  ReadLE(R, 2); ReadLE(R, 2); ReadLE(R, 4); Offset := ReadLE(R, 4);
  If Int64(R.Position) + N + Extra + Comment - 1 > Length(Archive) Then Fail(
  'Nom ZIP tronque.');
  Name := Copy(Archive, R.Position, N); Inc(R.Position, N + Extra + Comment);
  If (Name <> Member) And (Copy(Name, Length(Name) - Length(Member), Length(Member) + 1)
  <> '/' + Member) Then Continue;
  If Found Then Fail('Plusieurs fichiers ' + Member + ' dans l''archive.');
  Found := True;
  If (Flags And 1) <> 0 Then Fail('ZIP chiffre non accepte.');
  If (PackedSize > MaxInputBytes) Or (UnpackedSize > MaxInputBytes) Then Fail(
  'Entree ZIP trop grande.');
  L.Data := Archive; L.Name := Name;
  L.Position := Bounded(Int64(Offset) + 1, 1, Length(Archive), 'offset ZIP local');
  If ReadLE(L, 4) <> $04034B50 Then Fail('Entete ZIP locale absente.');
  Inc(L.Position, 22); N := ReadLE(L, 2); Extra := ReadLE(L, 2);
  Inc(L.Position, N + Extra);
  If Int64(L.Position) + PackedSize - 1 > Length(Archive) Then Fail(
  'Entree ZIP tronquee.');
  Payload := Copy(Archive, L.Position, PackedSize);
  If Method = 0 Then ZipMember := Payload Else
  If Method = 8 Then ZipMember := InflateRaw(Payload, UnpackedSize)
                Else Fail('Compression ZIP non prise en charge (stockage/deflate requis).');
  If (Length(ZipMember) <> UnpackedSize) Or (CRC32(ZipMember) <> Checksum) Then Fail(
  'CRC/taille ZIP incorrect: ' + Member);
 End;
End;

Function ModelMember(Const Path, Archive, Member: String; Required: Boolean): String;
Var
 Name: String;
Begin
 If Archive <> '' Then ModelMember := ZipMember(Archive, Member)
  Else
 Begin
  Name := IncludeTrailingPathDelimiter(Path) + Member;
  If FileExists(Name) Then ModelMember := LoadText(Name) Else ModelMember := '';
 End;
 If Required And (ModelMember = '') Then Fail('Fichier du modele manquant: ' + Member);
End;

Type
 TTopoState = Record
  PdfClass: Integer;
  Dest: TIntVector;
 End;
 TTopology = Array Of TTopoState;
 TTransition = Record
  Phone, State, Pdf, First: Integer;
 End;
 TGMM = Record
  Constants, Means, InverseVars: TRealVector;
  Count: Integer;
 End;
 TTreeNode = Record
  Kind, Key, Answer, YesNode, NoNode: Integer;
  Values: TIntVector;
 End;
 TKaldiModel = Record
  PhoneNames: TStringVector;
  PhoneTopology: TIntVector;
  Topologies: Array Of TTopology;
  Transitions: Array Of TTransition;
  LogProbs: TRealVector;
  PDFs: Array Of TGMM;
  Tree: Array Of TTreeNode;
  TreeRoot, ContextWidth, CentralPosition, Dimension, LdaRows, LdaCols: Integer;
  LDA: TRealVector;
  Metadata: String;
  LowFrequency, HighFrequency, Lifter: Double;
  MelBins: Integer;
  UseEnergy: Boolean;
 End;

Function NextToken(Const Text: String; Var Position: Integer): String;
Var
 First: Integer;
Begin
 While (Position <= Length(Text)) And (Text[Position] <= ' ') Do Inc(Position);
 First := Position;
 While (Position <= Length(Text)) And (Text[Position] > ' ') Do Inc(Position);
 NextToken := Copy(Text, First, Position - First);
End;

Function JsonValue(Const Text, Key: String): String;
Var
 I, Start: Integer;
Begin
 JsonValue := ''; I := Pos('"' + Key + '"', Text);
 If I = 0 Then Exit;
 Inc(I, Length(Key) + 2);
 While (I <= Length(Text)) And (Text[I] <= ' ') Do Inc(I);
 If (I > Length(Text)) Or (Text[I] <> ':') Then Fail('Meta JSON invalide: ' + Key);
 Inc(I);
 While (I <= Length(Text)) And (Text[I] <= ' ') Do Inc(I);
 If (I <= Length(Text)) And (Text[I] = '"') Then Begin
  Inc(I); Start := I;
  While (I <= Length(Text)) And (Text[I] <> '"') Do Inc(I);
 End Else
 Begin
  Start := I;
  While (I <= Length(Text)) And Not (Text[I] In [',','}',']',#9,#10,#13,' ']) Do Inc(I);
 End;
 JsonValue := Copy(Text, Start, I - Start);
End;

Function Number(Const Text, What: String): Double;
Var
 Code: Integer;
 Bits: QWord;
Begin
 Val(Text, Number, Code); Move(Number, Bits, SizeOf(Bits));
 If (Code <> 0) Or ((Bits And QWord($7FF0000000000000)) = QWord($7FF0000000000000))
 Then  Fail('Nombre invalide: ' + What);
End;

Function ReadTreeNode(Var R: TReader; Var M: TKaldiModel; Depth: Integer): Integer;
Var
 Token: String;
 Node, I, Child, N: Integer;
 Values: TIntVector;
Begin
 If Depth > 256 Then Fail('Arbre Kaldi trop profond.');
 Token := KToken(R);
 If Token = 'NULL' Then Exit(-1);
 Node := Length(M.Tree); If Node >= 100000 Then Fail('Arbre Kaldi trop grand.');
 SetLength(M.Tree, Node + 1); ReadTreeNode := Node;
 If Token = 'CE' Then Begin
  M.Tree[Node].Kind := 0; M.Tree[Node].Answer := KInt(R);
 End Else If Token = 'SE' Then Begin
  M.Tree[Node].Kind := 1; M.Tree[Node].Key := KInt(R);
  KInts(R, Values); M.Tree[Node].Values := Values; KExpect(R, '{');
  Child := ReadTreeNode(R, M, Depth + 1); M.Tree[Node].YesNode := Child;
  Child := ReadTreeNode(R, M, Depth + 1); M.Tree[Node].NoNode := Child; KExpect(R, '}');
 End Else If Token = 'TE' Then Begin
  M.Tree[Node].Kind := 2; M.Tree[Node].Key := KInt(R);
  N := Bounded(KInt(R), 0, 100000, 'table arbre');
  SetLength(M.Tree[Node].Values, N); KExpect(R, '(');
  For I := 0 To N - 1 Do Begin
   Child := ReadTreeNode(R, M, Depth + 1); M.Tree[Node].Values[I] := Child;
  End;
  KExpect(R, ')');
 End Else Fail('Noeud Kaldi inconnu: ' + Token);
End;

Function TreePdf(Const M: TKaldiModel;
                 LeftPhone, Phone, RightPhone, PdfClass: Integer): Integer;
Var
 Node, Value, I: Integer;
 Found: Boolean;
Begin
 Node := M.TreeRoot;
 While Node >= 0 Do Begin
  If M.Tree[Node].Kind = 0 Then Exit(Bounded(M.Tree[Node].Answer, 0, High(M.PDFs),
  'pdf arbre'));
  Case M.Tree[Node].Key Of
  -1: Value := PdfClass;
  0: If M.ContextWidth = 1 Then Value := Phone Else Value := LeftPhone;
  1: Value := Phone;
  2: Value := RightPhone;
   Else
  Begin
   Fail('Cle de contexte Kaldi non prise en charge.'); Value := 0;
  End;
 End;
 If M.Tree[Node].Kind = 1 Then Begin
  Found := False;
  For I := 0 To High(M.Tree[Node].Values) Do    If M.Tree[Node].Values[I] =
  Value Then Begin
   Found := True; Break;
  End;
  If Found Then Node := M.Tree[Node].YesNode Else Node := M.Tree[Node].NoNode;
 End Else
 Begin
  If (Value < 0) Or (Value >= Length(M.Tree[Node].Values)) Then Node := -1
                                                           Else Node := M.Tree[Node].Values[Value];
 End;
End;
Fail('Contexte absent de l''arbre Kaldi.'); TreePdf := -1;
End;

Procedure LoadKaldiModel(Const Location: String; Var M: TKaldiModel);
Var
 Path, Archive, Data, Token, ModelFile, Value: String;
 R: TReader;
 I, J, K, N, Rows, Cols, Phone, State, TransCount, Position, Code: Integer;
 UnusedInts: TIntVector;
 UnusedReals: TRealVector;
 HMM: Boolean;
 Probability: Single;
Begin
 Path := Location; Archive := ''; ModelFile := 'final.alimdl';
 If Not DirectoryExists(Path) Then Begin
  If LowerCase(Copy(Path, Length(Path) - 3, 4)) = '.zip' Then Archive := LoadText(Path)
   Else
  Begin
   ModelFile := ExtractFileName(Path); Path := ExtractFileDir(ExpandFileName(Path));
  End;
 End;
 M.Metadata := ModelMember(Path, Archive, 'meta.json', True);
 If JsonValue(M.Metadata, 'architecture') <> 'gmm-hmm' Then Fail(
 'Modele MFA GMM-HMM requis (pas de reseau neuronal).');
 If (JsonValue(M.Metadata, 'type') <> 'mfcc') Or
 (Number(JsonValue(M.Metadata, 'sample_frequency'), 'sample_frequency') <> 16000) Or
 (Number(JsonValue(M.Metadata, 'frame_shift'), 'frame_shift') <> 10) Or
 (Number(JsonValue(M.Metadata, 'frame_length'), 'frame_length') <> 25) Or
 (Number(JsonValue(M.Metadata, 'num_coefficients'), 'num_coefficients') <> 13) Then  Fail(
 'Configuration MFCC non prise en charge: 16 kHz, 25/10 ms, 13 coefficients requis.');
 If JsonValue(M.Metadata, 'snip_edges') <> 'false' Then Fail(
 'Modele MFA snip_edges=false requis.');
 If (JsonValue(M.Metadata, 'use_pitch') = 'true') Or (JsonValue(M.Metadata, 'use_voicing')
 = 'true') Or
 (JsonValue(M.Metadata, 'position_dependent_phones') = 'true') Then  Fail(
 'Modele avec pitch/voicing/phonemes positionnels non pris en charge.');
 If Number(JsonValue(M.Metadata, 'dither'), 'dither') <> 0 Then Fail(
 'Modele sans dither requis.');
 If Abs(Number(JsonValue(M.Metadata, 'preemphasis_coefficient'), 'preemphasis') - 0.97) >
 1E-6 Then  Fail('Preaccentuation Kaldi non prise en charge.');
 M.MelBins := Round(Number(JsonValue(M.Metadata, 'num_mel_bins'), 'num_mel_bins'));
 Bounded(M.MelBins, 13, 40, 'num_mel_bins');
 M.LowFrequency := Number(JsonValue(M.Metadata, 'low_frequency'), 'low_frequency');
 M.HighFrequency := Number(JsonValue(M.Metadata, 'high_frequency'), 'high_frequency');
 If M.HighFrequency <= 0 Then M.HighFrequency := 8000 + M.HighFrequency;
 If (M.LowFrequency < 0) Or (M.HighFrequency > 8000) Or (M.LowFrequency >=
 M.HighFrequency) Then  Fail('Bornes mel invalides.');
 M.Lifter := Number(JsonValue(M.Metadata, 'cepstral_lifter'), 'cepstral_lifter');
 If (M.Lifter < 0) Or (M.Lifter > 1000) Then Fail('Lifter invalide.');
 M.UseEnergy := JsonValue(M.Metadata, 'use_energy') = 'true';
 Data := ModelMember(Path, Archive, 'phones.txt', True); Position := 1;
 While Position <= Length(Data) Do Begin
  Token := NextToken(Data, Position); If Token = '' Then Break;
  Value := NextToken(Data, Position); Val(Value, Phone, Code);
  If Code <> 0 Then Fail('Identifiant de phoneme invalide.');
  Bounded(Phone, 0, 10000, 'phone');
  If Phone >= Length(M.PhoneNames) Then SetLength(M.PhoneNames, Phone + 1);
  If M.PhoneNames[Phone] <> '' Then Fail('Identifiant de phoneme repete.');
  M.PhoneNames[Phone] := Token;
 End;
 Data := ModelMember(Path, Archive, ModelFile, True); KHeader(R, Data, ModelFile);
 KExpect(R, '<TransitionModel>'); KExpect(R, '<Topology>');
 KInts(R, UnusedInts); KInts(R, M.PhoneTopology);
 N := KInt(R); HMM := N <> -1;
 If Not HMM Then N := KInt(R);
 Bounded(N, 1, 1000, 'topologies'); SetLength(M.Topologies, N);
 For I := 0 To N - 1 Do Begin
  Rows := Bounded(KInt(R), 2, 32, 'etats topologie'); SetLength(M.Topologies[I], Rows);
  For J := 0 To Rows - 1 Do Begin
   State := KInt(R); M.Topologies[I][J].PdfClass := State;
   If Not HMM Then If KInt(R) <> State Then Fail('Topologie chain non prise en charge.');
   If ((J < Rows - 1) And (State < 0)) Or ((J = Rows - 1) And (State <> -1)) Then    Fail(
   'Topologie a etats non emetteurs intermediaires non prise en charge.');
   Cols := Bounded(KInt(R), 0, 32, 'transitions topologie');
   If (J = Rows - 1) And (Cols <> 0) Then Fail('Etat final avec transitions.');
   SetLength(M.Topologies[I][J].Dest, Cols);
   For K := 0 To Cols - 1 Do Begin
    M.Topologies[I][J].Dest[K] := Bounded(KInt(R), 0, Rows - 1, 'destination topologie');
    Probability := KFloat(R, True);
    If (Probability <= 0) Or (Probability > 1) Then Fail(
    'Probabilite de transition invalide.');
   End;
  End;
 End;
 KExpect(R, '</Topology>'); Token := KToken(R);
 If (Token <> '<Triples>') And (Token <> '<Tuples>') Then Fail(
 'Transitions Kaldi absentes.');
 N := Bounded(KInt(R), 1, 1000000, 'nombre transitions'); SetLength(M.Transitions, N);
 TransCount := 1;
 For I := 0 To N - 1 Do Begin
  Phone := Bounded(KInt(R), 1, High(M.PhoneTopology), 'phone transition');
  J := Bounded(M.PhoneTopology[Phone], 0, High(M.Topologies), 'index topologie');
  State := Bounded(KInt(R), 0, Length(M.Topologies[J]) - 2, 'etat transition');
  M.Transitions[I].Phone := Phone; M.Transitions[I].State := State;
  M.Transitions[I].Pdf := KInt(R);
  If Token = '<Tuples>' Then If KInt(R) <> M.Transitions[I].Pdf Then Fail(
  'PDF self-loop distinct non pris en charge.');
  M.Transitions[I].First := TransCount;
  Inc(TransCount, Length(M.Topologies[J][State].Dest));
 End;
 If Token = '<Triples>' Then KExpect(R, '</Triples>') Else KExpect(R, '</Tuples>');
 KExpect(R, '<LogProbs>'); KReals(R, M.LogProbs, Rows, Cols, False);
 If Rows <> TransCount Then Fail('Nombre de probabilites Kaldi incoherent.');
 KExpect(R, '</LogProbs>'); KExpect(R, '</TransitionModel>');
 KExpect(R, '<DIMENSION>'); M.Dimension := Bounded(KInt(R), 1, 100, 'dimension GMM');
 KExpect(R, '<NUMPDFS>'); N := Bounded(KInt(R), 1, 100000, 'nombre PDF');
 SetLength(M.PDFs, N);
 For I := 0 To N - 1 Do Begin
  KExpect(R, '<DiagGMM>'); KExpect(R, '<GCONSTS>');
  KReals(R, M.PDFs[I].Constants, Rows, Cols, False);
  M.PDFs[I].Count := Bounded(Rows, 1, 4096, 'gaussiennes par PDF');
  KExpect(R, '<WEIGHTS>'); KReals(R, UnusedReals, Rows, Cols, False);
  If Rows <> M.PDFs[I].Count Then Fail('Poids GMM incoherents.');
  KExpect(R, '<MEANS_INVVARS>'); KReals(R, M.PDFs[I].Means, Rows, Cols, True);
  If (Rows <> M.PDFs[I].Count) Or (Cols <> M.Dimension) Then Fail(
  'Moyennes GMM incoherentes.');
  KExpect(R, '<INV_VARS>'); KReals(R, M.PDFs[I].InverseVars, Rows, Cols, True);
  If (Rows <> M.PDFs[I].Count) Or (Cols <> M.Dimension) Then Fail(
  'Variances GMM incoherentes.');
  For J := 0 To High(M.PDFs[I].InverseVars) Do If M.PDFs[I].InverseVars[J] <= 0 Then Fail(
  'Variance GMM non positive.');
  KExpect(R, '</DiagGMM>');
 End;
 For I := 0 To High(M.Transitions) Do Bounded(M.Transitions[I].Pdf, 0, High(M.PDFs),
 'pdf transition');
 Data := ModelMember(Path, Archive, 'tree', True); KHeader(R, Data, 'tree');
 KExpect(R, 'ContextDependency'); M.ContextWidth := KInt(R); M.CentralPosition := KInt(R);
 If Not (((M.ContextWidth = 3) And (M.CentralPosition = 1)) Or
 ((M.ContextWidth = 1) And (M.CentralPosition = 0))) Then Fail(
 'Contexte Kaldi non monophone/triphone.');
 KExpect(R, 'ToPdf'); M.TreeRoot := ReadTreeNode(R, M, 0);
 KExpect(R, 'EndContextDependency');
 Data := ModelMember(Path, Archive, 'lda.mat', False);
 If Data <> '' Then Begin
  KHeader(R, Data, 'lda.mat'); KReals(R, M.LDA, M.LdaRows, M.LdaCols, True);
  If (M.LdaRows <> M.Dimension) Or Not (M.LdaCols In [91,92]) Then Fail(
  'LDA attendue: D x 91 ou D x 92.');
  If (Number(JsonValue(M.Metadata, 'splice_left_context'), 'splice_left_context') <> 3) Or
  (Number(JsonValue(M.Metadata, 'splice_right_context'), 'splice_right_context') <> 3)
  Then Fail('LDA: contexte +/-3 requis.');
 End Else If Not (M.Dimension In [13,39]) Then Fail(
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
 TFeature = Array[0..AlignDims - 1] Of Double;
 TFeatures = Array Of TFeature;
 TAcousticFeatures = Array Of TRealVector;
 TSpectrum = Array[0..AlignFFT - 1] Of Double;

Procedure AcousticFFT(Var Re, Im: TSpectrum);
Var
 I, J, K, Size, Half: Integer;
 A, B, C, S, Angle: Double;
Begin
 J := 0;
 For I := 1 To AlignFFT - 1 Do Begin
  K := AlignFFT Div 2;
  While (J And K) <> 0 Do Begin
   J := J Xor K; K := K Div 2;
  End;
  J := J Xor K;
  If I < J Then Begin
   A := Re[I]; Re[I] := Re[J]; Re[J] := A;
   A := Im[I]; Im[I] := Im[J]; Im[J] := A;
  End;
 End;
 Size := 2;
 While Size <= AlignFFT Do Begin
  Half := Size Div 2;
  For K := 0 To Half - 1 Do Begin
   Angle := -2 * Pi * K / Size; C := Cos(Angle); S := Sin(Angle);
   I := K;
   While I < AlignFFT Do Begin
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

Procedure ExtractFeatures(Const Audio: TSamples; Const M: TKaldiModel;
                          Var Features: TAcousticFeatures);
Var
 Re, Im: TSpectrum;
 Filters: Array[0..AlignBands - 1, 0..AlignFFT Div 2] Of Double;
 DCT: Array[0..AlignDims - 1, 0..AlignBands - 1] Of Double;
 Window: Array[0..AlignWindow - 1] Of Double;
 Edges: Array[0..AlignBands + 1] Of Double;
 Bands: Array[0..AlignBands - 1] Of Double;
 Base, Delta: TFeatures;
 Frame, I, J, K, Index, Offset: Integer;
 MelLow, MelHigh, Mel, Energy, X, Power, Mean, Lift: Double;
Begin
 SetLength(Base, (Length(Audio) + AlignHop Div 2) Div AlignHop);
 If Length(Base) = 0 Then Fail('Audio trop court pour les MFCC Kaldi.');
 MelLow := 1127 * Ln(1 + M.LowFrequency / 700);
 MelHigh := 1127 * Ln(1 + M.HighFrequency / 700);
 For I := 0 To M.MelBins + 1 Do Edges[I] := MelLow + (MelHigh - MelLow) * I / (M.MelBins +
 1);
 For I := 0 To AlignWindow - 1 Do Begin
  X := 0.5 - 0.5 * Cos(2 * Pi * I / (AlignWindow - 1));
  If X <= 0 Then Window[I] := 0 Else Window[I] := Exp(0.85 * Ln(X));
 End;
 For J := 0 To M.MelBins - 1 Do Begin
  For K := 0 To AlignFFT Div 2 Do Begin
   Mel := 1127 * Ln(1 + K * (TargetRate / AlignFFT) / 700); X := 0;
   If (Mel > Edges[J]) And (Mel < Edges[J + 1]) Then    X := (Mel - Edges[J]) / (Edges[J +
   1] - Edges[J])
   Else If (Mel >= Edges[J + 1]) And (Mel < Edges[J + 2]) Then    X := (Edges[J + 2] -
   Mel) / (Edges[J + 2] - Edges[J + 1]);
   Filters[J, K] := X;
  End;
  DCT[0, J] := Sqrt(1 / M.MelBins);
  For I := 1 To AlignDims - 1 Do   DCT[I, J] := Sqrt(2 / M.MelBins) * Cos(Pi * I * (J +
  0.5) / M.MelBins);
 End;
 For Frame := 0 To High(Base) Do Begin
  FillChar(Re, SizeOf(Re), 0); FillChar(Im, SizeOf(Im), 0); Mean := 0; Energy := 0;
  For I := 0 To AlignWindow - 1 Do Begin
   Index := Frame * AlignHop + AlignHop Div 2 - AlignWindow Div 2 + I;
   While (Index < 0) Or (Index >= Length(Audio)) Do    If Index < 0 Then Index := -Index -
   1 Else Index := 2 * Length(Audio) - 1 - Index;
   Re[I] := Audio[Index] * 32768; Mean := Mean + Re[I];
  End;
  Mean := Mean / AlignWindow;
  For I := 0 To AlignWindow - 1 Do Begin
   Re[I] := Re[I] - Mean; Energy := Energy + Re[I] * Re[I];
  End;
  For I := AlignWindow - 1 Downto 1 Do Re[I] := Re[I] - 0.97 * Re[I - 1];
  Re[0] := Re[0] * 0.03;
  For I := 0 To AlignWindow - 1 Do Re[I] := Re[I] * Window[I];
  AcousticFFT(Re, Im);
  For J := 0 To M.MelBins - 1 Do Bands[J] := 0;
  For K := 0 To AlignFFT Div 2 Do Begin
   Power := Re[K] * Re[K] + Im[K] * Im[K];
   For J := 0 To M.MelBins - 1 Do Bands[J] := Bands[J] + Filters[J, K] * Power;
  End;
  For J := 0 To M.MelBins - 1 Do Begin
   If Bands[J] < 1.1920928955078125E-7 Then Bands[J] := 1.1920928955078125E-7;
   Bands[J] := Ln(Bands[J]);
  End;
  For I := 0 To AlignDims - 1 Do Begin
   X := 0;
   For J := 0 To M.MelBins - 1 Do X := X + DCT[I, J] * Bands[J];
   Lift := 1; If M.Lifter > 0 Then Lift := 1 + M.Lifter / 2 * Sin(Pi * I / M.Lifter);
   Base[Frame][I] := X * Lift;
  End;
  If M.UseEnergy Then Begin
   If Energy < 1.1920928955078125E-7 Then Energy := 1.1920928955078125E-7;
   Base[Frame][0] := Ln(Energy);
  End;
 End;
 If JsonValue(M.Metadata, 'uses_cmvn') = 'true' Then
 For I := 0 To AlignDims - 1 Do Begin
  Mean := 0;
  For Frame := 0 To High(Base) Do Mean := Mean + Base[Frame][I];
  Mean := Mean / Length(Base);
  For Frame := 0 To High(Base) Do Base[Frame][I] := Base[Frame][I] - Mean;
 End;
 SetLength(Features, Length(Base));
 If (Length(M.LDA) = 0) And (M.Dimension = 39) Then Begin
  SetLength(Delta, Length(Base));
  For Frame := 0 To High(Base) Do
  For I := 0 To 12 Do Begin
   X := 0;
   For J := -2 To 2 Do X := X + J * Base[Max(0, MinInt(High(Base), Frame + J))][I];
   Delta[Frame][I] := X / 10;
  End;
 End;
 For Frame := 0 To High(Base) Do Begin
  SetLength(Features[Frame], M.Dimension);
  If Length(M.LDA) > 0 Then Begin
   For I := 0 To M.Dimension - 1 Do Begin
    X := 0; Offset := I * M.LdaCols;
    For J := -3 To 3 Do
    For K := 0 To 12 Do     X := X + M.LDA[Offset + (J + 3) * 13 + K] * Base[Max(0,
    MinInt(High(Base), Frame + J))][K];
    If M.LdaCols = 92 Then X := X + M.LDA[Offset + 91];
    Features[Frame][I] := X;
   End;
  End Else
  For I := 0 To 12 Do Begin
   Features[Frame][I] := Base[Frame][I];
   If M.Dimension = 39 Then Begin
    Features[Frame][I + 13] := Delta[Frame][I]; X := 0;
    For J := -2 To 2 Do X := X + J * Delta[Max(0, MinInt(High(Base), Frame + J))][I];
    Features[Frame][I + 26] := X / 10;
   End;
  End;
 End;
End;

Type
 TLexEntry = Record
  WordText: String;
  Phones: TIntVector;
  Probability: Double;
 End;
 TLexicon = Array Of TLexEntry;
 TWordList = Array Of TLexEntry;
 TPhoneNode = Record
  Phone, Owner: Integer;
  Optional: Boolean;
 End;
 TPhoneNodes = Array Of TPhoneNode;
 TContextNode = Record
  Node, LeftNode, RightNode, FirstState: Integer;
 End;
 TContexts = Array Of TContextNode;
 TArc = Record
  Source: Integer;
  Score: Double;
 End;
 TAlignState = Record
  Pdf, PhoneNode: Integer;
  Incoming: Array Of TArc;
  Initial, FinalScore: Double;
 End;
 TAlignStates = Array Of TAlignState;

Const
 ImpossibleScore = -1E100;

Function NormalizeFrench(Const Text: String): String;
Var
 I, Code, Next: Integer;
Begin
 NormalizeFrench := ''; I := 1;
 While I <= Length(Text) Do Begin
  Code := Ord(Text[I]); Inc(I);
  If (Code >= $C2) And (Code <= $DF) And (I <= Length(Text)) Then Begin
   Next := Ord(Text[I]); Inc(I); Code := ((Code And 31) Shl 6) Or (Next And 63);
  End Else If (Code >= $E0) And (Code <= $EF) And (I + 1 <= Length(Text)) Then Begin
   Code := ((Code And 15) Shl 12) Or ((Ord(Text[I]) And 63) Shl 6) Or (Ord(Text[I + 1])
   And 63); Inc(I, 2);
  End Else If Code >= 128 Then Begin
   While (I <= Length(Text)) And ((Ord(Text[I]) And $C0) = $80) Do Inc(I);
   Code := 32;
  End;
  If (Code >= 65) And (Code <= 90) Then Inc(Code, 32);
  If (Code >= $C0) And (Code <= $DE) And (Code <> $D7) Then Inc(Code, 32);
  If Code = $152 Then Code := $153;
  If Code = $2019 Then Code := 39;
  If Not (((Code >= 97) And (Code <= 122)) Or ((Code >= 48) And (Code <= 57)) Or
  ((Code >= $C0) And (Code <= $36F)) Or (Code = 39)) Then Code := 32;
  If Code < 128 Then NormalizeFrench := NormalizeFrench + Chr(Code)
                Else NormalizeFrench := NormalizeFrench + Chr($C0 Or (Code Shr 6)) + Chr($80 Or (
  Code And 63));
 End;
 NormalizeFrench := Trim(NormalizeFrench);
End;

Function PhoneID(Const M: TKaldiModel; Const Name: String): Integer;
Var
 I: Integer;
Begin
 For I := 1 To High(M.PhoneNames) Do If M.PhoneNames[I] = Name Then Exit(I);
 Fail('Phoneme du dictionnaire absent du modele: ' + Name); PhoneID := -1;
End;

Procedure SortLexicon(Var Lex: TLexicon; Left, Right: Integer);
Var
 I, J: Integer;
 Pivot: String;
 Swap: TLexEntry;
Begin
 I := Left; J := Right; Pivot := Lex[(Left + Right) Div 2].WordText;
 Repeat
 While Lex[I].WordText < Pivot Do Inc(I);
 While Lex[J].WordText > Pivot Do Dec(J);
 If I <= J Then Begin
  Swap := Lex[I]; Lex[I] := Lex[J]; Lex[J] := Swap; Inc(I); Dec(J);
 End;
 Until I > J;
 If Left < J Then SortLexicon(Lex, Left, J);
 If I < Right Then SortLexicon(Lex, I, Right);
End;

Procedure LoadLexicon(Const Name: String; Const M: TKaldiModel; Var Lex: TLexicon);
Var
 Data, Line, WordText, Token: String;
 Start, Finish, P, N, I, Count, Code: Integer;
 Fields: TStringVector;
 Probability, NumericValue: Double;
Begin
 Data := LoadText(Name); Start := 1; Count := 0; SetLength(Lex, 1024);
 While Start <= Length(Data) Do Begin
  Finish := Start;
  While (Finish <= Length(Data)) And (Data[Finish] <> #10) Do Inc(Finish);
  Line := Trim(Copy(Data, Start, Finish - Start)); Start := Finish + 1;
  If (Line = '') Or (Line[1] = '#') Then Continue;
  P := 1; WordText := NextToken(Line, P);
  If (WordText = '<eps>') Or (WordText = '<unk>') Or (WordText[1] = '[') Then Continue;
  N := 0; SetLength(Fields, 0);
  Repeat
  Token := NextToken(Line, P); If Token = '' Then Break;
  SetLength(Fields, N + 1); Fields[N] := Token; Inc(N);
  Until False;
  If N = 0 Then Fail('Prononciation absente: ' + WordText);
  { Lexique MFA: mot [p_pron [p_sil corr_sil corr_non_sil]] phonemes. }
  I := 0; Probability := 1;
  While I < N Do Begin
   Val(Fields[I], NumericValue, Code); If Code <> 0 Then Break;
   If (NumericValue < 0) Or (NumericValue > 1E6) Then Fail(
   'Valeur lexicale hors limites: ' + WordText);
   If I = 0 Then Probability := Number(Fields[I], 'probabilite lexicale');
   Inc(I);
  End;
  If Not (I In [0,1,4]) Or (I = N) Or (Probability <= 0) Or (Probability > 1) Then   Fail(
  'Format/probabilite du dictionnaire MFA invalide: ' + WordText);
  If Count >= 1000000 Then Fail('Dictionnaire trop grand.');
  If Count = Length(Lex) Then SetLength(Lex, Count * 2);
  Lex[Count].WordText := NormalizeFrench(WordText); Lex[Count].Probability := Probability;
  SetLength(Lex[Count].Phones, N - I);
  For P := I To N - 1 Do Lex[Count].Phones[P - I] := PhoneID(M, Fields[P]);
  Inc(Count);
 End;
 SetLength(Lex, Count); If Count = 0 Then Fail('Dictionnaire vide.');
 SortLexicon(Lex, 0, Count - 1);
End;

Function LookupWord(Const Lex: TLexicon; Const WordText: String): Integer;
Var
 L, R, Mid, Best: Integer;
Begin
 L := 0; R := Length(Lex);
 While L < R Do Begin
  Mid := (L + R) Div 2; If Lex[Mid].WordText < WordText Then L := Mid + 1 Else R := Mid;
 End;
 If (L >= Length(Lex)) Or (Lex[L].WordText <> WordText) Then Exit(-1);
 Best := L;
 While (L < Length(Lex)) And (Lex[L].WordText = WordText) Do Begin
  If Lex[L].Probability > Lex[Best].Probability Then Best := L;
  Inc(L);
 End;
 LookupWord := Best;
End;

Procedure TranscriptWords(Const Text: String; Const Lex: TLexicon; Var Words: TWordList);
Var
 Normalized, Token: String;
 P: Integer;

Procedure Append(Const WordText: String; Depth: Integer);
Var
 Index, Split, N: Integer;
Begin
 If (WordText = '') Or (WordText = '''') Then Exit;
 If Depth > 16 Then Fail('Trop d''elisions imbriquees.');
 Index := LookupWord(Lex, WordText);
 If Index < 0 Then Begin
  Split := Pos('''', WordText);
  If (Split > 1) And (Split < Length(WordText)) Then Begin
   Append(Copy(WordText, 1, Split), Depth + 1);
   Append(Copy(WordText, Split + 1, Length(WordText)), Depth + 1); Exit;
  End;
  Fail('Mot absent du dictionnaire MFA: ' + WordText);
 End;
 N := Length(Words);
 If N >= 4096 Then Fail('Transcription trop longue pour l''alignement.');
 SetLength(Words, N + 1); Words[N] := Lex[Index];
End;
Begin
 SetLength(Words, 0); Normalized := NormalizeFrench(Text); P := 1;
 Repeat Token := NextToken(Normalized, P); If Token = '' Then Break; Append(Token, 0);
 Until False;
 If Length(Words) = 0 Then Fail('La transcription ne contient aucun mot alignable.');
End;

Function TransitionIndex(Const M: TKaldiModel; Phone, State, Pdf: Integer): Integer;
Var
 L, R, Mid, Compare: Integer;
Begin
 L := 0; R := High(M.Transitions);
 While L <= R Do Begin
  Mid := (L + R) Div 2;
  Compare := M.Transitions[Mid].Phone - Phone;
  If Compare = 0 Then Compare := M.Transitions[Mid].State - State;
  If Compare = 0 Then Compare := M.Transitions[Mid].Pdf - Pdf;
  If Compare = 0 Then Exit(Mid);
  If Compare < 0 Then L := Mid + 1 Else R := Mid - 1;
 End;
 Fail('Transition (phone, etat, pdf) absente du modele Kaldi.'); TransitionIndex := -1;
End;

Procedure BuildAlignmentGraph(Const M: TKaldiModel; Const Words: TWordList;
                              Var Nodes: TPhoneNodes; Var States: TAlignStates);
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
 If (B = A + 2) And (A + 1 >= 0) And (A + 1 < Length(Nodes)) Then Adjacent := Nodes[A +
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
 If (InitialSilence <= 0) Or (InitialSilence >= 1) Or (SilenceProbability <= 0) Or (
 SilenceProbability >= 1) Then  Fail('Probabilites de silence hors ]0,1[.');
 AddPhone(Sil, -1, True);
 For I := 0 To High(Words) Do Begin
  For J := 0 To High(Words[I].Phones) Do AddPhone(Words[I].Phones[J], I, False);
  AddPhone(Sil, -1, True);
 End;
 If Length(Nodes) > 12000 Then Fail('Trop de phonemes pour l''alignement.');
 For P := 0 To High(Nodes) Do
 For L := Max(-1, P - 2) To P - 1 Do If Adjacent(L, P) Then
 For R := P + 1 To MinInt(Length(Nodes), P + 2) Do If Adjacent(P, R) Then Begin
  C := Length(Contexts); SetLength(Contexts, C + 1);
  Contexts[C].Node := P; Contexts[C].LeftNode := L; Contexts[C].RightNode := R;
  Contexts[C].FirstState := Length(States);
  Phone := Nodes[P].Phone; Bounded(Phone, 1, High(M.PhoneTopology), 'phone graphe');
  Topo := Bounded(M.PhoneTopology[Phone], 0, High(M.Topologies), 'topologie graphe');
  N := Length(M.Topologies[Topo]) - 1; First := Length(States);
  SetLength(States, First + N);
  LeftPhone := 0; RightPhone := 0;
  If L >= 0 Then LeftPhone := Nodes[L].Phone;
  If R < Length(Nodes) Then RightPhone := Nodes[R].Phone;
  For J := 0 To N - 1 Do Begin
   States[First + J].Pdf := TreePdf(M, LeftPhone, Phone, RightPhone,
   M.Topologies[Topo][J].PdfClass);
   States[First + J].PhoneNode := P;
   States[First + J].Initial := ImpossibleScore;
   States[First + J].FinalScore := ImpossibleScore;
  End;
  If L = -1 Then Begin
   If Nodes[P].Optional Then Probability := InitialSilence Else Probability := 1 -
   InitialSilence;
   States[First].Initial := Ln(Probability);
  End;
 End;
 If Length(States) > 65534 Then Fail('Graphe d''alignement trop grand.');
 For C := 0 To High(Contexts) Do Begin
  P := Contexts[C].Node; Phone := Nodes[P].Phone;
  Topo := M.PhoneTopology[Phone]; N := Length(M.Topologies[Topo]) - 1;
  First := Contexts[C].FirstState;
  For J := 0 To N - 1 Do Begin
   State := First + J; PDF := States[State].Pdf;
   Transition := TransitionIndex(M, Phone, J, PDF); SelfProb := 0;
   For K := 0 To High(M.Topologies[Topo][J].Dest) Do    If M.Topologies[Topo][J].Dest[K] =
   J Then SelfProb := Exp(M.LogProbs[M.Transitions[Transition].First + K]);
   If SelfProb >= 1 Then Fail('Self-loop de probabilite 1.');
   For K := 0 To High(M.Topologies[Topo][J].Dest) Do Begin
    Dest := M.Topologies[Topo][J].Dest[K];
    Weight := M.LogProbs[M.Transitions[Transition].First + K];
    { Echelles standard d'alignement: transitions 1, self-loops 0.1. }
    If Dest = J Then Weight := 0.1 * Weight Else Weight := Weight - 0.9 * Ln(1 - SelfProb)
    ;
    If Dest < N Then AddArc(State, First + Dest, Weight) Else
    If Contexts[C].RightNode = Length(Nodes) Then Begin
     If Not Nodes[P].Optional Then Weight := Weight + Ln(1 - SilenceProbability);
     States[State].FinalScore := Weight;
    End Else
    Begin
     R := Contexts[C].RightNode;
     If Nodes[R].Optional Then Weight := Weight + Ln(SilenceProbability) Else
     If R = P + 2 Then Weight := Weight + Ln(1 - SilenceProbability);
     For D := C + 1 To High(Contexts) Do Begin
      If Contexts[D].Node > R Then Break;
      If (Contexts[D].Node = R) And (Contexts[D].LeftNode = P) Then Begin
       Target := Contexts[D].FirstState; AddArc(State, Target, Weight);
      End;
     End;
    End;
   End;
  End;
 End;
End;

Function GMMScore(Const G: TGMM; Const Features: TRealVector): Double;
Var
 I, J, Offset: Integer;
 Value, Best, Sum: Double;
 Scores: Array Of Double;
Begin
 SetLength(Scores, G.Count); Best := ImpossibleScore;
 For I := 0 To G.Count - 1 Do Begin
  Value := G.Constants[I]; Offset := I * Length(Features);
  For J := 0 To High(Features) Do Value := Value + G.Means[Offset + J] * Features[J] -
  0.5 * G.InverseVars[Offset + J] * Features[J] * Features[J];
  Scores[I] := Value; If Value > Best Then Best := Value;
 End;
 Sum := 0;
 For I := 0 To G.Count - 1 Do If Scores[I] > Best - 40 Then Sum := Sum + Exp(Scores[I] -
 Best);
 GMMScore := Best + Ln(Sum);
End;

Procedure ViterbiAlign(Const Features: TAcousticFeatures; Const M: TKaldiModel;
                       Const States: TAlignStates; Var Path: TIntVector);
Var
 Previous, Current, Scores: Array Of Double;
 Marks: TIntVector;
 Back: Array Of Word;
 T, S, I, Source, PDF, BestState: Integer;
 Value, Best, Peak: Double;
Begin
 If Int64(Length(Features)) * Length(States) > 32000000 Then  Fail(
 'Alignement trop grand (32 millions de cellules); decouper le WAV et le texte.');
 SetLength(Back, Length(Features) * Length(States));
 SetLength(Previous, Length(States)); SetLength(Current, Length(States));
 SetLength(Scores, Length(M.PDFs)); SetLength(Marks, Length(M.PDFs));
 For I := 0 To High(Marks) Do Marks[I] := -1;
 For T := 0 To High(Features) Do Begin
  Peak := ImpossibleScore;
  For S := 0 To High(States) Do Begin
   Best := ImpossibleScore; BestState := 0;
   If T = 0 Then Best := States[S].Initial
    Else
   For I := 0 To High(States[S].Incoming) Do Begin
    Source := States[S].Incoming[I].Source;
    Value := Previous[Source] + States[S].Incoming[I].Score;
    If Value > Best Then Begin
     Best := Value; BestState := Source;
    End;
   End;
   If Best > ImpossibleScore / 2 Then Begin
    PDF := States[S].Pdf;
    If Marks[PDF] <> T Then Begin
     Scores[PDF] := GMMScore(M.PDFs[PDF], Features[T]); Marks[PDF] := T;
    End;
    Best := Best + 0.1 * Scores[PDF];
   End;
   Current[S] := Best; Back[T * Length(States) + S] := BestState;
   If Best > Peak Then Peak := Best;
  End;
  If Peak <= ImpossibleScore / 2 Then Fail('Aucun chemin acoustique possible.');
  For S := 0 To High(States) Do Previous[S] := Current[S] - Peak;
 End;
 Best := ImpossibleScore; BestState := -1;
 For S := 0 To High(States) Do Begin
  Value := Previous[S] + States[S].FinalScore;
  If Value > Best Then Begin
   Best := Value; BestState := S;
  End;
 End;
 If (BestState < 0) Or (Best <= ImpossibleScore / 2) Then Fail(
 'Audio trop court ou texte impossible a aligner.');
 SetLength(Path, Length(Features)); S := BestState;
 For T := High(Path) Downto 0 Do Begin
  Path[T] := States[S].PhoneNode; S := Back[T * Length(States) + S];
 End;
End;

Function GridQuote(Const Text: String): String;
Var
 I: Integer;
Begin
 GridQuote := '"';
 For I := 1 To Length(Text) Do Begin
  GridQuote := GridQuote + Text[I]; If Text[I] = '"' Then GridQuote := GridQuote + '"';
 End;
 GridQuote := GridQuote + '"';
End;

Procedure WriteAlignmentGrid(Const FileName: String; SampleCount: Integer;
                             Const M: TKaldiModel;Const Words: TWordList;
                             Const Nodes: TPhoneNodes; Const Path: TIntVector);
Var
 S: TBinary;
 Tier, T, First, Last, Owner, NextOwner, Count, Index: Integer;
 LabelText: String;

Procedure PutLine(Const Text: String);
Var
 Value: String;
Begin
 Value := Text + LineEnding; WriteBytes(S, Value[1], Length(Value));
End;

Function LabelID(Frame: Integer): Integer;Begin
 LabelID := Path[Frame]; If Tier = 1 Then LabelID := Nodes[LabelID].Owner;
End;
Begin
 OpenBinary(S, FileName, True);
 PutLine('File type = "ooTextFile"'); PutLine('Object class = "TextGrid"'); PutLine('');
 PutLine('xmin = 0'); PutLine('xmax = ' + AudioDuration(SampleCount));
 PutLine('tiers? <exists>'); PutLine('size = 2'); PutLine('item []:');
 For Tier := 1 To 2 Do Begin
  Count := 1;
  For T := 1 To High(Path) Do If LabelID(T) <> LabelID(T - 1) Then Inc(Count);
  PutLine('    item [' + IntToStr(Tier) + ']:');
  PutLine('        class = "IntervalTier"');
  If Tier = 1 Then LabelText := 'words' Else LabelText := 'phones';
  PutLine('        name = ' + GridQuote(LabelText)); PutLine('        xmin = 0');
  PutLine('        xmax = ' + AudioDuration(SampleCount));
  PutLine('        intervals: size = ' + IntToStr(Count));
  First := 0; Index := 0;
  While First < Length(Path) Do Begin
   Last := First + 1; Owner := LabelID(First);
   While Last < Length(Path) Do Begin
    NextOwner := LabelID(Last); If NextOwner <> Owner Then Break; Inc(Last);
   End;
   LabelText := '';
   If Tier = 1 Then Begin
    If Owner >= 0 Then LabelText := Words[Owner].WordText;
   End
   Else LabelText := M.PhoneNames[Nodes[Owner].Phone];
   Inc(Index); PutLine('        intervals [' + IntToStr(Index) + ']:');
   PutLine('            xmin = ' + AudioDuration(MinInt(SampleCount, First * AlignHop)));
   If Last = Length(Path) Then T := SampleCount Else T := MinInt(SampleCount, Last *
   AlignHop);
   PutLine('            xmax = ' + AudioDuration(T));
   PutLine('            text = ' + GridQuote(LabelText));
   First := Last;
  End;
 End;
 CloseBinary(S);
End;

Procedure CleanupWork;Begin
 If PartialOutput <> '' Then  If DeleteFile(PartialOutput) Then PartialOutput := '';
End;

Type
 TJob = Record
  Audio, Transcript, Output: String;
 End;
 TJobs = Array Of TJob;

Var
 Jobs: TJobs;
 Model: TKaldiModel;
 Lexicon: TLexicon;
 Arguments: TStringVector;
 Command, DictionaryName, ModelName, OutputName: String;
 Quiet: Boolean;
 I, N: Integer;

Procedure Help;Begin
 WriteLn('MFA 1.0 - Cette commande permet d''effectuer l''alignement acoustique natif GMM-HMM.');
 WriteLn;
 WriteLn('Syntaxe: mfa align CORPUS DICTIONARY ACOUSTIC_MODEL OUTPUT');
 WriteLn('         mfa align_one SOUND_FILE TEXT_FILE DICTIONARY ACOUSTIC_MODEL OUTPUT');
 WriteLn;
 WriteLn('Options: -h, --help, /? ; --version ; -q, --quiet');
 WriteLn('Audio: WAV PCM/float. Transcriptions UTF-8 .lab ou .txt (.lab prioritaire).');
 WriteLn('Sortie: TextGrid long, pistes words et phones; aucun ecrasement.');
 WriteLn('align_one: OUTPUT est un fichier .TextGrid ou un dossier.');
 WriteLn('Modeles: dossier Kaldi ou archive MFA ZIP GMM-HMM compatible.');
 WriteLn('Alias locaux: models/dictionary/NOM.dict et models/acoustic/NOM.zip');
 WriteLn('Aucun telechargement automatique. Voir MFA.md pour les limites.');
End;

Procedure EnsureDirectory(Const Name: String);
Var
 Parent: String;
Begin
 If (Name = '') Or DirectoryExists(Name) Then Exit;
 Parent := ExtractFileDir(Name);
 If (Parent <> '') And (Parent <> Name) Then EnsureDirectory(Parent);
 If Not CreateDir(Name) Then Fail('Creation du dossier impossible: ' + Name);
End;

Function ResolveData(Const Name, Kind, Extension: String): String;
Var
 Candidate: String;
Begin
 If FileExists(Name) Or DirectoryExists(Name) Then Begin
  ResolveData := Name; Exit;
 End;
 Candidate := Name + Extension;
 If FileExists(Candidate) Then Begin
  ResolveData := Candidate; Exit;
 End;
 Candidate := 'models/' + Kind + '/' + Name;
 If FileExists(Candidate) Or DirectoryExists(Candidate) Then Begin
  ResolveData := Candidate; Exit;
 End;
 Candidate := Candidate + Extension;
 If FileExists(Candidate) Then Begin
  ResolveData := Candidate; Exit;
 End;
 Fail('Donnees locales introuvables: ' + Name + ' (models/' + Kind + ')');
 ResolveData := '';
End;

Procedure AddJob(Const Audio, Transcript, Output: String);
Var
 J: Integer;
Begin
 If Not FileExists(Transcript) Then Fail('Transcription manquante: ' + Transcript);
 If FileExists(Output) Or DirectoryExists(Output) Then Fail('Sortie deja existante: ' +
 Output);
 For J := 0 To High(Jobs) Do  If LowerCase(ExpandFileName(Jobs[J].Output)) = LowerCase(
 ExpandFileName(Output)) Then   Fail('Deux fichiers produisent la meme sortie: ' + Output)
 ;
 J := Length(Jobs); SetLength(Jobs, J + 1);
 Jobs[J].Audio := Audio; Jobs[J].Transcript := Transcript; Jobs[J].Output := Output;
End;

Procedure ScanCorpus(Const Folder, Destination: String; Depth: Integer);
Var
 Search: SearchRec;
 Names: TStringVector;
 A, B, ErrorCode: Integer;
 Name, Temp, Source, Target, Transcript: String;
Begin
 SetLength(Names, 0);
 If Depth > 32 Then Fail('Corpus trop profond (32 niveaux maximum): ' + Folder);
 FindFirst(IncludeTrailingPathDelimiter(Folder) + '*', AnyFile, Search);
 While DosError = 0 Do Begin
  Name := Search.Name;
  If (Name <> '.') And (Name <> '..') Then Begin
   A := Length(Names); SetLength(Names, A + 1); Names[A] := Name;
  End;
  FindNext(Search);
 End;
 ErrorCode := DosError;
 FindClose(Search);
 If (ErrorCode <> 18) And (ErrorCode <> 2) Then Fail('Lecture du corpus impossible: ' +
 Folder);
 For A := 1 To High(Names) Do Begin
  Temp := Names[A]; B := A - 1;
  While (B >= 0) And (Names[B] > Temp) Do Begin
   Names[B + 1] := Names[B]; Dec(B);
  End;
  Names[B + 1] := Temp;
 End;
 For A := 0 To High(Names) Do Begin
  Source := IncludeTrailingPathDelimiter(Folder) + Names[A];
  Target := IncludeTrailingPathDelimiter(Destination) + Names[A];
  If DirectoryExists(Source) Then ScanCorpus(Source, Target, Depth + 1) Else
  If LowerCase(Copy(Source, Length(Source) - 3, 4)) = '.wav' Then Begin
   Transcript := ChangeFileExt(Source, '.lab');
   If Not FileExists(Transcript) Then Transcript := ChangeFileExt(Source, '.txt');
   AddJob(Source, Transcript, ChangeFileExt(Target, '.TextGrid'));
  End;
 End;
End;

Procedure AlignJob(Const Job: TJob);
Var
 Audio, Mono: TSamples;
 Rate: LongWord;
 Text: String;
 Words: TWordList;
 Nodes: TPhoneNodes;
 States: TAlignStates;
 Features: TAcousticFeatures;
 Path: TIntVector;
Begin
 Text := LoadText(Job.Transcript);
 If Copy(Text, 1, 3) = #239#187#191 Then Delete(Text, 1, 3);
 TranscriptWords(Text, Lexicon, Words);
 ReadWave(Job.Audio, Audio, Rate);
 Resample(Audio, Rate, Mono); SetLength(Audio, 0);
 RemoveDC(Mono);
 ExtractFeatures(Mono, Model, Features);
 BuildAlignmentGraph(Model, Words, Nodes, States);
 ViterbiAlign(Features, Model, States, Path);
 EnsureDirectory(ExtractFileDir(Job.Output));
 If FileExists(Job.Output) Or DirectoryExists(Job.Output) Then Fail(
 'Sortie deja existante: ' + Job.Output);
 PartialOutput := Job.Output;
 WriteAlignmentGrid(Job.Output, Length(Mono), Model, Words, Nodes, Path);
 PartialOutput := '';
 If Not Quiet Then WriteLn(Job.Audio, ' -> ', Job.Output);
End;

BEGIN
 SetLength(Arguments, 0);
 Quiet := False;
 For I := 1 To ParamCount Do Begin
  Command := ParamStr(I);
  If (Command = '-h') Or (Command = '--help') Or (Command = '/?') Then Begin
   Help; Halt(0);
  End
  Else If Command = '--version' Then Begin
   WriteLn('MFA Pascal 1.0 (moteur natif du projet)'); Halt(0);
  End
  Else If (Command = '-q') Or (Command = '--quiet') Then Quiet := True
   Else
  Begin
   If (Length(Command) > 0) And (Command[1] = '-') Then Fail('Option inconnue: ' +
   Command);
   N := Length(Arguments); SetLength(Arguments, N + 1); Arguments[N] := Command;
  End;
 End;
 If Length(Arguments) = 0 Then Begin
  Help; Halt(1);
 End;
 Command := Arguments[0];
 If Command = 'align' Then Begin
  If Length(Arguments) <> 5 Then Fail(
  'Usage: mfa align CORPUS DICTIONARY ACOUSTIC_MODEL OUTPUT');
  If Not DirectoryExists(Arguments[1]) Then Fail('Corpus introuvable: ' + Arguments[1]);
  DictionaryName := Arguments[2]; ModelName := Arguments[3]; OutputName := Arguments[4];
  ScanCorpus(Arguments[1], OutputName, 0);
 End
 Else If Command = 'align_one' Then Begin
  If Length(Arguments) <> 6 Then Fail(
  'Usage: mfa align_one SOUND_FILE TEXT_FILE DICTIONARY ACOUSTIC_MODEL OUTPUT');
  DictionaryName := Arguments[3]; ModelName := Arguments[4]; OutputName := Arguments[5];
  If LowerCase(Copy(OutputName, Length(OutputName) - 8, 9)) <>
  '.textgrid' Then   OutputName := IncludeTrailingPathDelimiter(OutputName) +
  ChangeFileExt(ExtractFileName(Arguments[1]), '.TextGrid');
  AddJob(Arguments[1], Arguments[2], OutputName);
 End
 Else Fail('Commande inconnue: ' + Command);
 If Length(Jobs) = 0 Then Fail('Aucun fichier WAV dans le corpus.');
 DictionaryName := ResolveData(DictionaryName, 'dictionary', '.dict');
 ModelName := ResolveData(ModelName, 'acoustic', '.zip');
 If Not Quiet Then WriteLn('Chargement du modele acoustique: ', ModelName);
 LoadKaldiModel(ModelName, Model); LoadLexicon(DictionaryName, Model, Lexicon);
 For I := 0 To High(Jobs) Do AlignJob(Jobs[I]);
 If Not Quiet Then WriteLn(Length(Jobs), ' fichier(s) aligne(s).');
END.
