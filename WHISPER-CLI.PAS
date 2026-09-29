Program WHISPERCLI;
{$A-}
{$MODE FPC}{$H+}
{ Moteur Whisper procedural integre. Free Pascal 3.2+, memoire 32/64 bits.
  Pas de moteur externe, objets, SysUtils, Classes ou Math.
  L'inference neuronale et les tableaux dynamiques ne tiennent pas dans
  l'environnement 16 bits de Turbo Pascal DOS.
  Reference des architectures et licences: THIRD_PARTY_NOTICES.md. }

Uses DOS;

Type
 Integer = LongInt;
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
TStringVector = array of string;

Const
 TargetRate = 16000;
 MaxInputBytes = 268435456;
 MaxSeconds = 1800;
 NativeVersion = '1.0.0';

Var
 OpenFiles: array[0..7] of PBinary;
 ThreadCount: Integer;
Procedure Fail(const S: string);Forward;

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

Function Floor(Value: Double): Int64;Begin
 Floor := Trunc(Value);
 if Value < Floor Then Dec(Floor);
End;

Function Ceil(Value: Double): Int64;Begin
 Ceil := Trunc(Value);
 if Value > Ceil Then Inc(Ceil);
End;

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

Function Bounded(Value, LowBound, HighBound: LongInt; const What: string): LongInt;Begin
 if (Value < LowBound) or (Value > HighBound) Then Fail('Valeur invalide: ' + What);
 Bounded := Value;
End;

Procedure Fail(const S: string);
Var
 I, ErrorCode: Integer;
Begin
 WriteLn(StdErr, 'WHISPER-CLI: ', S);
  { Fermer les fichiers encore ouverts avant de supprimer les temporaires.
    Les pointeurs concernent des records toujours presents sur la pile. }
 For I := 0 to High(OpenFiles) do    if OpenFiles[I] <> nil Then Begin
      {$I-}
  Close(OpenFiles[I]^.Handle); ErrorCode := IOResult;
      {$I+}
  if ErrorCode <> 0 Then WriteLn(StdErr, 'Fermeture incomplete: ', OpenFiles[I]^.Name);
  OpenFiles[I] := nil;
 End;
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

Procedure SeekBinary(var S: TBinary; Position: Int64);
Var
 ErrorCode: Integer;
Begin
 FlushBinary(S);
  {$I-}Seek(S.Handle, Position); ErrorCode := IOResult;{$I+}
 if ErrorCode <> 0 Then Fail('Position inaccessible: ' + S.Name);
 S.Position := Position; S.Index := 0; S.Used := 0;
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

Type
 TTensor = record Name: string;
 Dims: array[0..3] of Integer;
 Rank: Integer;
 Data: TSamples;
End;
TTensors = array of TTensor;
TMatrix = record Rows, Cols: Integer;
Data: TSamples;
End;
TAttentionWeights = record Q, QB, K, V, VB, O, OB, LN, LNB: Integer;
End;
TWhisperLayer = record
Attention, Cross: TAttentionWeights;
MLP0, MLP0B, MLP2, MLP2B, MLPNorm, MLPNormB: Integer;
End;
TWhisperModel = record
Tensors: TTensors;
Vocab: TStringVector;
AudioContext, AudioWidth, AudioHeads, AudioLayers, TextContext, TextWidth, TextHeads,
TextLayers, MelCount, VocabCount: Integer;
Conv1, Conv1B, Conv2, Conv2B, AudioPosition, AudioNorm, AudioNormB, TextPosition,
TextNorm, TextNormB, Embedding: Integer;
Encoder, Decoder: array of TWhisperLayer;
Filters: TSamples;
EOT, SOT, French, Transcribe, NoSpeech, NoTimestamps: Integer;
End;
TDecoderCache = record SelfK, SelfV, CrossK, CrossV: TMatrix;
End;
TDecoderCaches = array of TDecoderCache;

Function HalfToSingle(Value: Word): Single;
Var
 Bits, Mantissa, Exponent: LongWord;
Begin
 Bits := LongWord(Value and $8000) shl 16;
 Mantissa := Value and $3FF; Exponent := (Value shr 10) and 31;
 if Exponent = 0 Then Begin
  if Mantissa <> 0 Then Begin
   Exponent := 113;
   While (Mantissa and $400) = 0 do Begin
    Mantissa := Mantissa shl 1; Dec(Exponent);
   End;
   Bits := Bits or (Exponent shl 23) or ((Mantissa and $3FF) shl 13);
  End;
 End else if Exponent = 31 Then Bits := Bits or $7F800000 or (Mantissa shl 13)
 else Bits := Bits or ((Exponent + 112) shl 23) or (Mantissa shl 13);
 Move(Bits, HalfToSingle, 4);
End;

Procedure ReadFloatArray(var S: TBinary; Count, Kind: Integer; var Values: TSamples);
Var
 I: Integer;
 Raw: array of Word;
Begin
 if not (Kind in [0,1]) Then Fail(
 'Tenseur GGML quantifie/non pris en charge; utiliser un modele FP16 ou FP32.');
 if (Count < 0) or (Int64(Count) * (4 - Kind * 2) > S.Size - S.Position) Then Fail(
 'Tenseur GGML tronque.');
 SetLength(Values, Count);
 if Kind = 0 Then Begin
  if Count > 0 Then ReadBytes(S, Values[0], Count * 4);
 End
 else
 Begin
  SetLength(Raw, Count); if Count > 0 Then ReadBytes(S, Raw[0], Count * 2);
  For I := 0 to Count - 1 do Values[I] := HalfToSingle(Raw[I]);
 End;
 For I := 0 to Count - 1 do if IsNan(Values[I]) or IsInfinite(Values[I]) Then Fail(
 'Poids GGML non fini.');
End;

Procedure ReadTensorTable(var S: TBinary; var Tensors: TTensors);
Var
 N, I, J, Count, NameLength, Kind: Integer;
 Total: Int64;
 Name: string;
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
   if I < Tensors[N].Rank Then Tensors[N].Dims[I] := Bounded(LongInt(U32(S)), 1, 100000,
   'dimension tenseur');
   if Int64(Count) * Tensors[N].Dims[I] > 300000000 Then Fail('Tenseur GGML trop grand.');
   Count := Count * Tensors[N].Dims[I];
  End;
  Total := Total + Int64(Count) * 4;
  if Total > 1400000000 Then Fail(
  'Modele trop grand pour cette implementation CPU (1,4 Go de poids FP32 maximum).');
  SetLength(Name, NameLength); ReadBytes(S, Name[1], NameLength);
  For J := 0 to N - 1 do if Tensors[J].Name = Name Then Fail('Tenseur GGML repete: ' +
  Name);
  Tensors[N].Name := Name; ReadFloatArray(S, Count, Kind, Tensors[N].Data);
 End;
End;
Function TensorID(const Tensors: TTensors; const Name: string;

const Shape: array of Integer): Integer;
Var
 I, J: Integer;
Begin
 For I := 0 to High(Tensors) do if Tensors[I].Name = Name Then Begin
  For J := 0 to High(Shape) do if Tensors[I].Dims[J] <> Shape[J] Then Fail(
  'Dimensions incorrectes: ' + Name);
  For J := Length(Shape) to 3 do if Tensors[I].Dims[J] <> 1 Then Fail(
  'Dimensions supplementaires: ' + Name);
  Begin
   TensorID := I; Exit;
  End;
 End;
 Fail('Tenseur manquant: ' + Name); TensorID := -1;
End;
Procedure BindAttention(const T: TTensors; const Prefix, Norm: string; Width: Integer;

var W: TAttentionWeights);Begin
 W.Q := TensorID(T, Prefix + '.query.weight', [Width,Width]);
 W.QB := TensorID(T, Prefix + '.query.bias', [Width]);
 W.K := TensorID(T, Prefix + '.key.weight', [Width,Width]);
 W.V := TensorID(T, Prefix + '.value.weight', [Width,Width]);
 W.VB := TensorID(T, Prefix + '.value.bias', [Width]);
 W.O := TensorID(T, Prefix + '.out.weight', [Width,Width]);
 W.OB := TensorID(T, Prefix + '.out.bias', [Width]);
 W.LN := TensorID(T, Norm + '.weight', [Width]);
 W.LNB := TensorID(T, Norm + '.bias', [Width]);
End;
Procedure BindWhisperLayer(const T: TTensors; const Prefix: string; Width: Integer;

Decoder: Boolean; var L: TWhisperLayer);Begin
 BindAttention(T, Prefix + '.attn', Prefix + '.attn_ln', Width, L.Attention);
 if Decoder Then BindAttention(T, Prefix + '.cross_attn', Prefix + '.cross_attn_ln',
 Width, L.Cross);
 L.MLP0 := TensorID(T, Prefix + '.mlp.0.weight', [Width,Width*4]);
 L.MLP0B := TensorID(T, Prefix + '.mlp.0.bias', [Width*4]);
 L.MLP2 := TensorID(T, Prefix + '.mlp.2.weight', [Width*4,Width]);
 L.MLP2B := TensorID(T, Prefix + '.mlp.2.bias', [Width]);
 L.MLPNorm := TensorID(T, Prefix + '.mlp_ln.weight', [Width]);
 L.MLPNormB := TensorID(T, Prefix + '.mlp_ln.bias', [Width]);
End;

Procedure LoadWhisper(const FileName: string; var M: TWhisperModel);
Var
 S: TBinary;
 I, Count, N, Kind: Integer;
Begin
 OpenBinary(S, FileName, False);
 if U32(S) <> $67676D6C Then Fail(
 'Modele Whisper GGML requis (GGUF/ONNX non pris en charge).');
 M.VocabCount := Bounded(LongInt(U32(S)), 51864, 51866, 'vocabulaire Whisper')
 ;
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
 (M.AudioWidth mod M.AudioHeads <> 0) or (M.TextWidth mod M.TextHeads <> 0) Then Fail(
 'Architecture Whisper non prise en charge.');
 if not (Kind in [0,1]) Then Fail('Modele Whisper FP16/FP32 non quantifie requis.');
 if (U32(S) <> LongWord(M.MelCount)) or (U32(S) <> 201) Then Fail(
 'Filtres mel Whisper invalides.');
 ReadFloatArray(S, M.MelCount * 201, 0, M.Filters);
 Count := Bounded(LongInt(U32(S)), 50256, M.VocabCount, 'tokens GGML');
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
 M.AudioPosition := TensorID(M.Tensors, 'encoder.positional_embedding', [M.AudioWidth,
 M.AudioContext]);
 M.AudioNorm := TensorID(M.Tensors, 'encoder.ln_post.weight', [M.AudioWidth]);
 M.AudioNormB := TensorID(M.Tensors, 'encoder.ln_post.bias', [M.AudioWidth]);
 M.Embedding := TensorID(M.Tensors, 'decoder.token_embedding.weight', [M.TextWidth,
 M.VocabCount]);
 M.TextPosition := TensorID(M.Tensors, 'decoder.positional_embedding', [M.TextWidth,
 M.TextContext]);
 M.TextNorm := TensorID(M.Tensors, 'decoder.ln.weight', [M.TextWidth]);
 M.TextNormB := TensorID(M.Tensors, 'decoder.ln.bias', [M.TextWidth]);
 SetLength(M.Encoder, M.AudioLayers); SetLength(M.Decoder, M.TextLayers);
 For I := 0 to M.AudioLayers - 1 do BindWhisperLayer(M.Tensors, 'encoder.blocks.' +
 IntToStr(I), M.AudioWidth, False, M.Encoder[I]);
 For I := 0 to M.TextLayers - 1 do BindWhisperLayer(M.Tensors, 'decoder.blocks.' +
 IntToStr(I), M.TextWidth, True, M.Decoder[I]);
 M.EOT := 50256; if M.VocabCount > 51864 Then Inc(M.EOT);
 M.SOT := M.EOT + 1; M.French := M.SOT + 7;
 M.Transcribe := 50359 + M.VocabCount - 51865;
 M.NoSpeech := 50362 + M.VocabCount - 51865;
 M.NoTimestamps := 50363 + M.VocabCount - 51865;
 WriteLn(StdErr, 'Whisper natif: ', M.AudioLayers, ' couches encodeur, ', M.TextLayers,
 ' couches decodeur, largeur ', M.AudioWidth, '.');
End;
{$IFDEF CPU386}
{$ASMMODE INTEL}

 Function NeuralDot(A, B: PSingle; N: LongInt): Single;
 register; assembler; nostackframe;
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
 End;
{$ELSE}

 Function NeuralDot(A, B: PSingle; N: LongInt): Single;
 Var
  I: Integer;
  Value: Double;
 Begin
  Value := 0;
  For I := 1 to N do Begin
   Value := Value + A^ * B^; Inc(A); Inc(B);
  End;
  NeuralDot := Value;
 End;
{$ENDIF}

Procedure MatrixSize(var M: TMatrix; Rows, Cols: Integer);Begin
 if (Rows < 0) or (Cols <= 0) or (Int64(Rows) * Cols > 100000000) Then Fail(
 'Matrice neuronale trop grande.');
 M.Rows := Rows; M.Cols := Cols; SetLength(M.Data, Rows * Cols);
End;

Type
 TFloatMemory = array[0..268435455] of Single;
 PFloatMemory = ^TFloatMemory;
 TDenseJob = record
 X, Weight, Bias, Y: PFloatMemory;
 First, Last, Inputs, Outputs: Integer;
End;
PDenseJob = ^TDenseJob;

Procedure JoinThread(Handle: TThreadID);
Var
 Code: LongWord;
Begin
 Code := WaitForThreadTerminate(Handle, -1);
 CloseThread(Handle);
 if Code <> 0 Then Fail('Echec d''un thread de calcul.');
End;

Function DenseWorker(Parameter: Pointer): PtrInt;
Var
 Job: PDenseJob;
 Index, Row, Col: Integer;
 Value: Single;
Begin
 Job := Parameter;
 For Index := Job^.First to Job^.Last - 1 do Begin
  Row := Index div Job^.Outputs; Col := Index mod Job^.Outputs;
  Value := NeuralDot(@Job^.X^[Row * Job^.Inputs], @Job^.Weight^[Col * Job^.Inputs],
  Job^.Inputs);
  if Job^.Bias <> nil Then Value := Value + Job^.Bias^[Col];
  Job^.Y^[Index] := Value;
 End;
 DenseWorker := 0;
End;

Procedure Dense(const X: TMatrix; const T: TTensors; Weight, Bias: Integer;
var Y: TMatrix);
Var
 Width, Count, Workers, I, J: Integer;
 Jobs: array[0..63] of TDenseJob;
 Handles: array[0..63] of TThreadID;
Begin
 Width := T[Weight].Dims[1];
 if X.Cols <> T[Weight].Dims[0] Then Fail('Dimension de projection neuronale invalide.');
 MatrixSize(Y, X.Rows, Width); Count := X.Rows * Width;
 if Count = 0 Then Exit;
 Workers := MinInt(ThreadCount, Count);
 if Int64(Count) * X.Cols < 65536 Then Workers := 1;
 For I := 0 to Workers - 1 do Begin
  Jobs[I].X := @X.Data[0]; Jobs[I].Weight := @T[Weight].Data[0]; Jobs[I].Y := @Y.Data[0];
  Jobs[I].Bias := nil; if Bias >= 0 Then Jobs[I].Bias := @T[Bias].Data[0];
  Jobs[I].Inputs := X.Cols; Jobs[I].Outputs := Width;
  Jobs[I].First := Int64(Count) * I div Workers;
  Jobs[I].Last := Int64(Count) * (I + 1) div Workers;
 End;
 For I := 1 to Workers - 1 do Begin
  Handles[I] := BeginThread(@DenseWorker, @Jobs[I]);
  if Handles[I] = 0 Then Begin
   For J := 1 to I - 1 do JoinThread(Handles[J]);
   Fail('Creation d''un thread impossible; reduire --threads.');
  End;
 End;
 DenseWorker(@Jobs[0]);
 For I := 1 to Workers - 1 do JoinThread(Handles[I]);
End;

Function StableTanh(Value: Double): Double;Begin
 if Value > 15 Then Begin
  StableTanh := 1; Exit;
 End; if Value < -15 Then Begin
  StableTanh := -1; Exit;
 End;
 StableTanh := 2 / (1 + Exp(-2 * Value)) - 1;
End;

Function Sigmoid(Value: Double): Double;Begin
 if Value >= 0 Then Sigmoid := 1 / (1 + Exp(-Value))
 else
 Begin
  Value := Exp(Value); Sigmoid := Value / (1 + Value);
 End;
End;

Procedure GELU(var X: TMatrix);
Var
 I: Integer;
 V: Double;
Begin
 For I := 0 to High(X.Data) do Begin
  V := X.Data[I];
  X.Data[I] := 0.5 * V * (1 + StableTanh(0.7978845608028654 * V * (1 + 0.044715 * V * V)))
  ;
 End;
End;
Procedure NeuralNorm(const X: TMatrix; const T: TTensors; Weight, Bias: Integer;

var Y: TMatrix);
Var
 I, J, Offset: Integer;
 Mean, Variance, V, Scale: Double;
Begin
 MatrixSize(Y, X.Rows, X.Cols);
 For I := 0 to X.Rows - 1 do Begin
  Offset := I * X.Cols; Mean := 0; Variance := 0;
  For J := 0 to X.Cols - 1 do Mean := Mean + X.Data[Offset + J];
  Mean := Mean / X.Cols;
  For J := 0 to X.Cols - 1 do Begin
   V := X.Data[Offset + J] - Mean; Variance := Variance + V * V;
  End;
  Scale := 1 / Sqrt(Variance / X.Cols + 1E-5);
  For J := 0 to X.Cols - 1 do Y.Data[Offset + J] := (X.Data[Offset + J] - Mean) * Scale *
  T[Weight].Data[J] + T[Bias].Data[J];
 End;
End;

Procedure Residual(var X: TMatrix; const Y: TMatrix);
Var
 I: Integer;
Begin
 if (X.Rows <> Y.Rows) or (X.Cols <> Y.Cols) Then Fail('Dimension residuelle invalide.');
 For I := 0 to High(X.Data) do X.Data[I] := X.Data[I] + Y.Data[I];
End;
Procedure Conv1D(const X: TMatrix; const T: TTensors;

Weight, Bias, Stride, Padding: Integer; var Y: TMatrix);
Var
 I, J, C, K, Source, Width, Kernel, Rows: Integer;
 Patch: TSamples;
 Value: Single;
Begin
 Kernel := T[Weight].Dims[0]; Width := T[Weight].Dims[2];
 if T[Weight].Dims[1] <> X.Cols Then Fail('Canaux de convolution invalides.');
 Rows := (X.Rows + 2 * Padding - Kernel) div Stride + 1; MatrixSize(Y, Rows, Width);
 SetLength(Patch, X.Cols * Kernel);
 For I := 0 to Rows - 1 do Begin
  For C := 0 to X.Cols - 1 do
  For K := 0 to Kernel - 1 do Begin
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
Procedure NeuralAttention(const Q, K, V: TMatrix; KeyCount, Heads: Integer;

var Y: TMatrix);
Var
 I, J, H, D, Width: Integer;
 Scores, Transposed: TSamples;
 Scale, Peak, Sum, Value: Double;
Begin
 if (Q.Cols <> K.Cols) or (K.Cols <> V.Cols) or (KeyCount <= 0) or (KeyCount > K.Rows) or
 (KeyCount > V.Rows) or (Q.Cols mod Heads <> 0) Then Fail(
 'Dimensions attention invalides.');
 Width := Q.Cols div Heads; Scale := 1 / Sqrt(Width);
 MatrixSize(Y, Q.Rows, Q.Cols); SetLength(Scores, KeyCount);
 SetLength(Transposed, KeyCount * V.Cols);
 For J := 0 to KeyCount - 1 do
 For D := 0 to V.Cols - 1 do Transposed[D * KeyCount + J] := V.Data[J * V.Cols + D];
 For I := 0 to Q.Rows - 1 do
 For H := 0 to Heads - 1 do Begin
  Peak := -1E30;
  For J := 0 to KeyCount - 1 do Begin
   Value := NeuralDot(@Q.Data[I * Q.Cols + H * Width], @K.Data[J * K.Cols + H * Width],
   Width) * Scale;
   Scores[J] := Value; if Value > Peak Then Peak := Value;
  End;
  Sum := 0;
  For J := 0 to KeyCount - 1 do Begin
   Scores[J] := Exp(Scores[J] - Peak); Sum := Sum + Scores[J];
  End;
  For J := 0 to KeyCount - 1 do Scores[J] := Scores[J] / Sum;
  For D := 0 to Width - 1 do Y.Data[I * Y.Cols + H * Width + D] :=
  NeuralDot(@Scores[0], @Transposed[(H * Width + D) * KeyCount], KeyCount);
 End;
End;

Procedure NeuralMLP(var X: TMatrix; const T: TTensors; const L: TWhisperLayer);
Var
 N, A, B: TMatrix;
Begin
 NeuralNorm(X, T, L.MLPNorm, L.MLPNormB, N);
 Dense(N, T, L.MLP0, L.MLP0B, A); GELU(A); Dense(A, T, L.MLP2, L.MLP2B, B);
 Residual(X, B);
End;

Procedure EncodeWhisper(const Mel: TMatrix; const M: TWhisperModel; var Encoded: TMatrix);
Var
 X, N, Q, K, V, A, B: TMatrix;
 I, J: Integer;
 W: TAttentionWeights;
Begin
 Conv1D(Mel, M.Tensors, M.Conv1, M.Conv1B, 1, 1, X); GELU(X);
 Conv1D(X, M.Tensors, M.Conv2, M.Conv2B, 2, 1, Encoded); GELU(Encoded);
 For J := 0 to High(Encoded.Data) do Encoded.Data[J] := Encoded.Data[J] +
 M.Tensors[M.AudioPosition].Data[J];
 For I := 0 to M.AudioLayers - 1 do Begin
  W := M.Encoder[I].Attention;
  NeuralNorm(Encoded, M.Tensors, W.LN, W.LNB, N);
  Dense(N, M.Tensors, W.Q, W.QB, Q); Dense(N, M.Tensors, W.K, -1, K);
  Dense(N, M.Tensors, W.V, W.VB, V);
  NeuralAttention(Q, K, V, K.Rows, M.AudioHeads, A); Dense(A, M.Tensors, W.O, W.OB, B);
  Residual(Encoded, B);
  NeuralMLP(Encoded, M.Tensors, M.Encoder[I]);
 End;
 NeuralNorm(Encoded, M.Tensors, M.AudioNorm, M.AudioNormB, N); Encoded := N;
End;
Procedure InitDecoderCache(const Encoded: TMatrix; const M: TWhisperModel;

var Cache: TDecoderCaches);
Var
 I: Integer;
 W: TAttentionWeights;
Begin
 SetLength(Cache, M.TextLayers);
 For I := 0 to M.TextLayers - 1 do Begin
  W := M.Decoder[I].Cross;
  Dense(Encoded, M.Tensors, W.K, -1, Cache[I].CrossK);
  Dense(Encoded, M.Tensors, W.V, W.VB, Cache[I].CrossV);
  MatrixSize(Cache[I].SelfK, M.TextContext, M.TextWidth);
  MatrixSize(Cache[I].SelfV, M.TextContext, M.TextWidth);
 End;
End;
Procedure DecoderStep(Token, Position: Integer; const M: TWhisperModel;

var Cache: TDecoderCaches; var Logits: TMatrix);
Var
 X, N, Q, K, V, A, B: TMatrix;
 I, J: Integer;
 W: TAttentionWeights;
Begin
 Bounded(Token, 0, M.VocabCount - 1, 'token decodeur');
 Bounded(Position, 0, M.TextContext - 1, 'position decodeur');
 MatrixSize(X, 1, M.TextWidth);
 For J := 0 to M.TextWidth - 1 do X.Data[J] := M.Tensors[M.Embedding].Data[Token *
 M.TextWidth + J] +
 M.Tensors[M.TextPosition].Data[Position * M.TextWidth + J];
 For I := 0 to M.TextLayers - 1 do Begin
  W := M.Decoder[I].Attention; NeuralNorm(X, M.Tensors, W.LN, W.LNB, N);
  Dense(N, M.Tensors, W.Q, W.QB, Q); Dense(N, M.Tensors, W.K, -1, K);
  Dense(N, M.Tensors, W.V, W.VB, V);
  Move(K.Data[0], Cache[I].SelfK.Data[Position * M.TextWidth], M.TextWidth * 4);
  Move(V.Data[0], Cache[I].SelfV.Data[Position * M.TextWidth], M.TextWidth * 4);
  NeuralAttention(Q, Cache[I].SelfK, Cache[I].SelfV, Position + 1, M.TextHeads, A);
  Dense(A, M.Tensors, W.O, W.OB, B); Residual(X, B);
  W := M.Decoder[I].Cross; NeuralNorm(X, M.Tensors, W.LN, W.LNB, N);
  Dense(N, M.Tensors, W.Q, W.QB, Q);
  NeuralAttention(Q, Cache[I].CrossK, Cache[I].CrossV, Cache[I].CrossK.Rows, M.TextHeads,
  A);
  Dense(A, M.Tensors, W.O, W.OB, B); Residual(X, B);
  NeuralMLP(X, M.Tensors, M.Decoder[I]);
 End;
 NeuralNorm(X, M.Tensors, M.TextNorm, M.TextNormB, N);
 Dense(N, M.Tensors, M.Embedding, -1, Logits);
End;
{ Whisper: DFT 400 points, fenetre Hann periodique et filtres mel du modele.
  Les tables trigonomÃƒÂ©triques sont calculees une fois; aucun moteur FFT externe. }
Procedure WhisperMel(const Audio: TSamples; First, Last: Integer; const M: TWhisperModel;

var Mel: TMatrix);
Var
 C, S, Frame, Power: TSamples;
 I, J, K, P: Integer;
 A, B, V, Peak: Double;
Begin
 SetLength(C, 201 * 400); SetLength(S, 201 * 400); SetLength(Frame, 400);
 SetLength(Power, 201);
 For K := 0 to 200 do
 For J := 0 to 399 do Begin
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
    A := NeuralDot(@Frame[0], @C[K * 400], 400);
    B := NeuralDot(@Frame[0], @S[K * 400], 400);
    Power[K] := A * A + B * B;
   End;
   For K := 0 to M.MelCount - 1 do Begin
    V := NeuralDot(@Power[0], @M.Filters[K * 201], 201);
    if V < 1E-10 Then V := 1E-10;
    V := Ln(V) / Ln(10); Mel.Data[I * M.MelCount + K] := V;
    if V > Peak Then Peak := V;
   End;
  End else
  For K := 0 to M.MelCount - 1 do Mel.Data[I * M.MelCount + K] := -10;
 End;
 For I := 0 to High(Mel.Data) do Begin
  V := Mel.Data[I]; if V < Peak - 8 Then V := Peak - 8;
  Mel.Data[I] := (V + 4) / 4;
 End;
End;

Const
 LanguageCodes: array[0..99] of string[3] = (
 'en','zh','de','es','ru','ko','fr','ja','pt','tr','pl','ca','nl','ar','sv','it',
 'id','hi','fi','vi','he','uk','el','ms','cs','ro','da','hu','ta','no','th','ur',
 'hr','bg','lt','la','mi','ml','cy','sk','te','fa','lv','bn','sr','az','sl','kn',
 'et','mk','br','eu','is','hy','ne','mn','bs','kk','sq','sw','gl','mr','pa','si',
 'km','sn','yo','so','af','oc','ka','be','tg','sd','gu','am','yi','lo','uz','fo',
 'ht','ps','tk','nn','mt','sa','lb','my','bo','tl','mg','as','tt','haw','ln','ha',
 'ba','jw','su','yue');

Type
 TOptions = record
 Files: TStringVector;
 Model, Language: string;
 Threads, Processors: Integer;
 OffsetMS, DurationMS, OffsetIndex: Integer;
 ShowIndex: Boolean;
End;
TSegment = record First, Last: Integer;
Text, Language: string;
End;
TSegments = array of TSegment;
PWhisperModel = ^TWhisperModel;
PSamples = ^TSamples;
TProcessorJob = record
Model: PWhisperModel;
Audio: PSamples;
First, Last, Language: Integer;
Segments: TSegments;
End;
PProcessorJob = ^TProcessorJob;

Procedure Version;Begin
 WriteLn('WHISPER-CLI.PAS ', NativeVersion, ' - moteur Whisper natif en Pascal');
 WriteLn('whisper.cpp: non lie; compatibilite partielle de la ligne de commande.');
End;

Procedure Help;Begin
 WriteLn('Usage: whisper-cli [options] fichier0.wav fichier1.wav ...');
 WriteLn('   ou: whisper-cli [options] -f fichier.wav');
 WriteLn;
 WriteLn('  -h, --help           Affiche cette aide (/? accepte aussi)');
 WriteLn('      --version        Version du port Pascal autonome');
 WriteLn(
 '  -t N, --threads N    Threads de calcul matriciel par processeur (1..64, defaut 1)');
 WriteLn('  -p N, --processors N Portions audio traitees en parallele (1..8, defaut 1)');
 WriteLn('  -m NOM, --model NOM  Modele GGML FP16/FP32 (defaut models/ggml-base.en.bin)');
 WriteLn(
 '  -f NOM, --file NOM   Fichier WAV; option repetable, cumulable avec les fichiers positionnels');
 WriteLn('  -ot N, --offset-t N  Debut en millisecondes (defaut 0)');
 WriteLn('  -on N, --offset-n N  Premier index affiche des segments (defaut 0)');
 WriteLn('  -d N, --duration N   Duree en millisecondes (0 = jusqu''a la fin)');
 WriteLn('  -l CODE, --language CODE  Langue Whisper, ou auto (defaut en; francais: fr)');
 WriteLn(
 '      --               Fin des options; les arguments suivants sont des fichiers');
 WriteLn;
 WriteLn('Decodeur CPU glouton integre, aucun outil externe. Texte UTF-8 sur stdout.');
 WriteLn('Temps affiches: bornes des portions audio, pas alignement mot par mot.');
 WriteLn('WAV PCM/float32, 256 Mio/30 min maximum. Pour MP3: convertir avec MP32WAV.');
 WriteLn('Modeles quantifies/GGUF, GPU et autres options whisper.cpp non pris en charge.')
 ;
 WriteLn('Les poids de modele restent des fichiers de donnees necessaires.');
 WriteLn('Free Pascal 3.2+ requis; Turbo Pascal DOS ne peut pas executer ce moteur.');
 WriteLn('Parallelisme avec System: disponible dans cette version sous Windows.');
End;

Function PositiveInteger(const Text, Option: string; Maximum: Integer): Integer;
Var
 I, V, Code: Integer;
Begin
 if Text = '' Then Fail('Valeur vide: ' + Option);
 For I := 1 to Length(Text) do if not (Text[I] in ['0'..'9']) Then Fail(
 'Entier positif requis: ' + Option);
 Val(Text, V, Code);
 if (Code <> 0) or (V < 1) or (V > Maximum) Then Fail(Option + ': valeur entre 1 et ' +
 IntToStr(Maximum) + ' requise.');
 PositiveInteger := V;
End;

Function NonNegativeInteger(const Text, Option: string): Integer;
Var
 I, V, Code: Integer;
Begin
 if Text = '' Then Fail('Valeur vide: ' + Option);
 For I := 1 to Length(Text) do if not (Text[I] in ['0'..'9']) Then
  Fail('Entier positif ou nul requis: ' + Option);
 Val(Text, V, Code);
 if (Code <> 0) or (V < 0) Then
  Fail(Option + ': valeur entre 0 et 2147483647 requise.');
 NonNegativeInteger := V;
End;

Function LanguageIndex(const Name: string): Integer;
Var
 I: Integer;
Begin
 LanguageIndex := -1; if Name = 'auto' Then Exit;
 For I := 0 to High(LanguageCodes) do if Name = LanguageCodes[I] Then Begin
  LanguageIndex := I; Exit;
 End;
 Fail('Code de langue inconnu: ' + Name);
End;

Procedure AddInput(var O: TOptions; const Name: string);
Var
 N: Integer;
Begin
 if Name = '' Then Fail('Nom de fichier audio vide.');
 N := Length(O.Files);
 if N >= 1024 Then Fail('Maximum 1024 fichiers par commande.');
 SetLength(O.Files, N + 1); O.Files[N] := Name;
End;

Procedure ParseOptions(var O: TOptions);
Var
 I, L: Integer;
 Arg, Value: string;
 Positional: Boolean;
Begin
 O.Threads := 1; O.Processors := 1; O.Model := 'models/ggml-base.en.bin';
 O.Language := 'en';
 O.OffsetMS := 0; O.DurationMS := 0; O.OffsetIndex := 0; O.ShowIndex := False;
 SetLength(O.Files, 0); Positional := False; I := 1;
 if ParamCount = 0 Then Begin
  Help; Halt(1);
 End;
 While I <= ParamCount do Begin
  Arg := ParamStr(I);
  if Positional Then AddInput(O, Arg)
  else if Arg = '--' Then Positional := True
  else if (Arg = '-h') or (Arg = '--help') or (Arg = '/?') Then Begin
   Help; Halt(0);
  End
  else if Arg = '--version' Then Begin
   Version; Halt(0);
  End
  else if (Arg = '-t') or (Arg = '--threads') or (Arg = '-p') or (Arg = '--processors') or
  (Arg = '-m') or (Arg = '--model') or (Arg = '-f') or (Arg = '--file') or
  (Arg = '-ot') or (Arg = '--offset-t') or
  (Arg = '-on') or (Arg = '--offset-n') or
  (Arg = '-d') or (Arg = '--duration') or
  (Arg = '-l') or (Arg = '--language') Then Begin
   Inc(I); if I > ParamCount Then Fail('Valeur manquante: ' + Arg);
   Value := ParamStr(I); if Value = '' Then Fail('Valeur vide: ' + Arg);
   if (Arg = '-t') or (Arg = '--threads') Then O.Threads := PositiveInteger(Value, Arg,
   64)
   else if (Arg = '-p') or (Arg = '--processors') Then O.Processors := PositiveInteger(
   Value, Arg, 8)
   else if (Arg = '-m') or (Arg = '--model') Then O.Model := Value
   else if (Arg = '-l') or (Arg = '--language') Then O.Language := Value
   else if (Arg = '-ot') or (Arg = '--offset-t') Then
    O.OffsetMS := NonNegativeInteger(Value, Arg)
   else if (Arg = '-d') or (Arg = '--duration') Then
    O.DurationMS := NonNegativeInteger(Value, Arg)
   else if (Arg = '-on') or (Arg = '--offset-n') Then Begin
    O.OffsetIndex := NonNegativeInteger(Value, Arg); O.ShowIndex := True;
   End
   else AddInput(O, Value);
  End
  else if (Arg <> '') and (Arg[1] = '-') Then Fail('Option non prise en charge: ' + Arg)
  else AddInput(O, Arg);
  Inc(I);
 End;
 if Length(O.Files) = 0 Then Fail('Au moins un fichier WAV est requis.');
 if O.Threads * O.Processors > 64 Then Fail(
 'Le produit threads * processors ne doit pas depasser 64.');
 {$IFNDEF MSWINDOWS}
  if (O.Threads > 1) or (O.Processors > 1) Then  Fail(
  'Cette compilation sans gestionnaire POSIX exige -t 1 -p 1; parallelisme disponible sous Windows.');
 {$ENDIF}
 L := LanguageIndex(O.Language);
 if not FileExists(O.Model) Then Fail('Modele introuvable: ' + O.Model +
 '; utiliser -m chemin_du_modele.bin');
 For I := 0 to High(O.Files) do if not FileExists(O.Files[I]) Then Fail(
 'Fichier audio introuvable: ' + O.Files[I]);
End;
Function DecodeChunk(const Audio: TSamples; First, Last: Integer;

const M: TWhisperModel; RequestedLanguage: Integer;
var DetectedLanguage: Integer): string;
Var
 Mel, Encoded, Logits: TMatrix;
 Cache: TDecoderCaches;
 Position, InitialPosition, Token, I, Best, LanguageCount, WordCount: Integer;
 Peak, Sum, NoSpeechProbability, LogProbability, Energy: Double;
Begin
 DecodeChunk := ''; DetectedLanguage := RequestedLanguage;
 Energy := 0;
 For I := First to Last - 1 do Energy := Energy + Sqr(Audio[I]);
 if (Last <= First) or (Energy / (Last - First) < 1E-12) Then Exit;
 WhisperMel(Audio, First, Last, M, Mel); EncodeWhisper(Mel, M, Encoded);
 Mel.Data := nil; InitDecoderCache(Encoded, M, Cache); Encoded.Data := nil;
 DecoderStep(M.SOT, 0, M, Cache, Logits);
 Peak := -1E30;
 For I := 0 to High(Logits.Data) do if Logits.Data[I] > Peak Then Peak := Logits.Data[I];
 Sum := 0;
 For I := 0 to High(Logits.Data) do Sum := Sum + Exp(Logits.Data[I] - Peak);
 NoSpeechProbability := Exp(Logits.Data[M.NoSpeech] - Peak) / Sum;
 Position := 1;
 if M.VocabCount > 51864 Then Begin
  LanguageCount := 99 + M.VocabCount - 51865;
  if DetectedLanguage < 0 Then Begin
   DetectedLanguage := 0;
   For I := 1 to LanguageCount - 1 do    if Logits.Data[M.SOT + 1 + I] >
   Logits.Data[M.SOT + 1 + DetectedLanguage] Then DetectedLanguage := I;
  End;
  if DetectedLanguage >= LanguageCount Then Fail('Langue absente de ce modele Whisper.');
  DecoderStep(M.SOT + 1 + DetectedLanguage, Position, M, Cache, Logits); Inc(Position);
  DecoderStep(M.Transcribe, Position, M, Cache, Logits); Inc(Position);
 End else DetectedLanguage := 0;
 DecoderStep(M.NoTimestamps, Position, M, Cache, Logits); Inc(Position);
 InitialPosition := Position; LogProbability := 0; WordCount := 0;
 Repeat
 Best := M.EOT; Peak := -1E30;
 For I := 0 to M.EOT do Begin
  if (I < M.EOT) and (M.Vocab[I] = '') Then Continue;
  if (Position = InitialPosition) and ((I = M.EOT) or (M.Vocab[I] = ' ')) Then Continue;
  if Logits.Data[I] > Peak Then Begin
   Peak := Logits.Data[I]; Best := I;
  End;
 End;
 Token := Best; if Token = M.EOT Then Break;
 Sum := 0;
 For I := 0 to M.EOT do Sum := Sum + Exp(Logits.Data[I] - Peak);
 LogProbability := LogProbability - Ln(Sum); Inc(WordCount);
 DecodeChunk := DecodeChunk + M.Vocab[Token];
 if Position >= M.TextContext Then Begin
  if (NoSpeechProbability > 0.6) and (LogProbability / WordCount < -1) Then Begin
   DecodeChunk := ''; Exit;
  End;
  Fail('Limite du contexte Whisper atteinte sans fin de texte.');
 End;
 DecoderStep(Token, Position, M, Cache, Logits); Inc(Position);
 Until False;
 if (NoSpeechProbability > 0.6) and (WordCount > 0) Then  if LogProbability / WordCount <
 -1 Then DecodeChunk := '';
 DecodeChunk := Trim(DecodeChunk);
End;

Function ProcessorWorker(Parameter: Pointer): PtrInt;
Var
 Job: PProcessorJob;
 First, Last, N, Detected: Integer;
 Text: string;
Begin
 Job := Parameter; First := Job^.First;
 While First < Job^.Last do Begin
  Last := MinInt(First + 480000, Job^.Last);
  Text := DecodeChunk(Job^.Audio^, First, Last, Job^.Model^, Job^.Language, Detected);
  N := Length(Job^.Segments); SetLength(Job^.Segments, N + 1);
  Job^.Segments[N].First := First; Job^.Segments[N].Last := Last;
  Job^.Segments[N].Text := Text;
  Job^.Segments[N].Language := '';
  if Detected >= 0 Then Job^.Segments[N].Language := LanguageCodes[Detected];
  First := Last;
 End;
 ProcessorWorker := 0;
End;

Function PadNumber(Value, Digits: Integer): string;Begin
 PadNumber := IntToStr(Value);
 While Length(PadNumber) < Digits do PadNumber := '0' + PadNumber;
End;

Function TimeStamp(Samples: Integer): string;
Var
 MS: Integer;
Begin
 MS := Int64(Samples) * 1000 div TargetRate;
 TimeStamp := PadNumber(MS div 3600000, 2) + ':' + PadNumber((MS div 60000) mod 60, 2) +
 ':' +
 PadNumber((MS div 1000) mod 60, 2) + '.' + PadNumber(MS mod 1000, 3);
End;

Procedure TranscribeFile(const Name: string; const O: TOptions; var M: TWhisperModel);
Var
 Source, Audio: TSamples;
 Rate: LongWord;
 Workers, I, J, Language, FirstSample, LastSample, Selected: Integer;
 Boundary, SegmentIndex: Int64;
 Jobs: array[0..7] of TProcessorJob;
 Handles: array[0..7] of TThreadID;
 UTF8Text: UTF8String;
Begin
 ReadWave(Name, Source, Rate); Resample(Source, Rate, Audio); Source := nil;
 RemoveDC(Audio);
 Language := LanguageIndex(O.Language);
 if (M.VocabCount = 51864) and (Language > 0) Then Fail(
 'Le modele .en ne prend en charge que l''anglais.');
 if Language >= 99 + M.VocabCount - 51865 Then Fail(
 'Langue absente de ce modele Whisper.');
 { Calcul en 64 bits avant de borner aux echantillons disponibles. }
 Boundary := Int64(O.OffsetMS) * TargetRate div 1000;
 if Boundary >= Length(Audio) Then Begin
  WriteLn(StdErr, 'Fichier: ', Name, ' | aucune portion audio apres le decalage.');
  Exit;
 End;
 FirstSample := Boundary; LastSample := Length(Audio);
 if O.DurationMS > 0 Then Begin
  Boundary := Int64(FirstSample) + Int64(O.DurationMS) * TargetRate div 1000;
  if Boundary < LastSample Then LastSample := Boundary;
 End;
 Selected := LastSample - FirstSample;
 if Selected <= 0 Then Exit;
 Workers := MinInt(O.Processors, Selected);
 WriteLn(StdErr, 'Fichier: ', Name, ' | ', O.Threads, ' thread(s) x ', Workers,
 ' processeur(s), langue=', O.Language, ', debut=', TimeStamp(FirstSample), ', duree=', TimeStamp(Selected));
 For I := 0 to Workers - 1 do Begin
  Jobs[I].Model := @M; Jobs[I].Audio := @Audio; Jobs[I].Language := Language;
  Jobs[I].First := FirstSample + Int64(Selected) * I div Workers;
  Jobs[I].Last := FirstSample + Int64(Selected) * (I + 1) div Workers;
 End;
 For I := 1 to Workers - 1 do Begin
  Handles[I] := BeginThread(@ProcessorWorker, @Jobs[I]);
  if Handles[I] = 0 Then Begin
   For J := 1 to I - 1 do JoinThread(Handles[J]);
   Fail('Creation d''un processeur impossible; reduire --processors.');
  End;
 End;
 ProcessorWorker(@Jobs[0]);
 For I := 1 to Workers - 1 do JoinThread(Handles[I]);
 SegmentIndex := O.OffsetIndex;
 For I := 0 to Workers - 1 do
 For J := 0 to High(Jobs[I].Segments) do  if Jobs[I].Segments[J].Text <> '' Then Begin
   { Les tokens GGML contiennent des octets UTF-8, parfois des caracteres
     coupes entre tokens. Ne declarer l'encodage qu'apres leur assemblage. }
  SetString(UTF8Text, PChar(Jobs[I].Segments[J].Text), Length(Jobs[I].Segments[J].Text));
  if O.ShowIndex Then Write('[', SegmentIndex, '] ');
  Inc(SegmentIndex);
  WriteLn('[', TimeStamp(Jobs[I].Segments[J].First), ' --> ',
  TimeStamp(Jobs[I].Segments[J].Last), '] ', UTF8Text);
 End;
End;

Var
 Options: TOptions;
 Model: TWhisperModel;
 FileIndex: Integer;

BEGIN
 SetTextCodePage(Output, 65001);
 ParseOptions(Options); ThreadCount := Options.Threads;
 LoadWhisper(Options.Model, Model);
 For FileIndex := 0 to High(Options.Files) do TranscribeFile(Options.Files[FileIndex],
 Options, Model);
END.
