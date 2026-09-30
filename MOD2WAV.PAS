{ @author: Sylvain Maltais (support@gladir.com)
 @created: 2026
 @version: 1.00
 @website(https://www.gladir.com/speech-to-text-0)
 @abstract(Target: Turbo Pascal 7/Free Pascal 3.2
 @description: Convertisseur MOD ProTracker vers WAV PCM16, sans outil externe. }

Program MOD2WAV;

{$IFDEF FPC}
 {$MODE TP}
{$ENDIF}
{$IFNDEF FPC}
 {$N+}{$E+}
{$ENDIF}

Uses DOS;

Type
 TAudioFormat = Record
  Channels: Integer;
  Rate: LongInt;
 End;

Var
 InputFile, OutputFile: File;
 InputName, OutputName: String;
 InputOpen, OutputOpen, OutputCreated: Boolean;
 InputSize, Written: LongInt;
 PCM: Array[0..4095] Of Byte;
 Header: TAudioFormat;
 SavedExit: Pointer;

Procedure Cleanup;
Var
 Code: Integer;
Begin
 If InputOpen Then Begin
  {$I-}Close(InputFile); Code := IOResult;{$I+} InputOpen := False;
 End;
 If OutputOpen Then Begin
  {$I-}Close(OutputFile); Code := IOResult;{$I+} OutputOpen := False;
 End;
 If OutputCreated Then Begin
  {$I-}Erase(OutputFile); Code := IOResult;{$I+}
  If Code <> 0 Then WriteLn('Fichier incomplet a supprimer: ', OutputName);
  OutputCreated := False;
 End;
End;
Procedure ExitCleanup;
{$IFNDEF FPC}
 Far;
{$ENDIF}
Begin
 ExitProc := SavedExit; Cleanup;
End;

Procedure Fail(MessageText: String);Begin
 WriteLn('MOD2WAV: ', MessageText); Cleanup; Halt(1);
End;

Function Exists(Name: String): Boolean;
Var
 F: File;
 Attributes: Word;
Begin
 Assign(F, Name); GetFAttr(F, Attributes); Exists := DosError = 0;
End;

Function DefaultOutput(Name: String): String;
Var
 I: Integer;
Begin
 I := Length(Name);
 While (I > 0) And Not (Name[I] In ['.', '/', '\', ':']) Do Dec(I);
 If (I > 0) And (Name[I] = '.') Then Name := Copy(Name, 1, I - 1);
 If Length(Name) > 251 Then Fail('Nom de sortie trop long.');
 DefaultOutput := Name + '.wav';
End;

Procedure Help;Begin
 WriteLn('MOD2WAV - Cette commande permet de lancer le convertisseur MOD ProTracker vers WAV PCM16');
 WriteLn;
 WriteLn('Syntaxe: MOD2WAV entree.mod [sortie.wav]');
 WriteLn;
 WriteLn('MOD 4 canaux/31 instruments: M.K., M!K!, 4CHN, FLT4.');
 WriteLn('Rendu integre WAV PCM16 stereo 22050 Hz. Voir MOD2WAV.md pour les effets.');
 WriteLn('Sans sortie explicite: meme chemin avec extension .wav.');
 WriteLn('Aucun outil externe. Sortie existante refusee. Aide: /? ou --help');
End;

Procedure ReadAt(Position: LongInt; Var Buffer; Count: Word);
Var
 Actual: Word;
 ErrorCode: Integer;
Begin
 If (Position < 0) Or (Position > InputSize) Then Fail('Position MOD incorrecte.');
 If Count > InputSize - Position Then Fail('Fichier MOD tronque.');
 {$I-}Seek(InputFile, Position); ErrorCode := IOResult;{$I+}
 If ErrorCode <> 0 Then Fail('Positionnement MOD impossible.');
 {$I-}BlockRead(InputFile, Buffer, Count, Actual); ErrorCode := IOResult;{$I+}
 If (ErrorCode <> 0) Or (Actual <> Count) Then Fail('Lecture MOD incomplete.');
End;

Procedure WriteBytes(Var Buffer; Count: Word);
Var
 Actual: Word;
 ErrorCode: Integer;
Begin
 {$I-}BlockWrite(OutputFile, Buffer, Count, Actual); ErrorCode := IOResult;{$I+}
 If (ErrorCode <> 0) Or (Actual <> Count) Then Fail('Ecriture WAV incomplete.')
 ;
End;

Procedure Put16(Value: Word);
Var
 B: Array[0..1] Of Byte;
Begin
 B[0] := Value And 255; B[1] := Value Shr 8; WriteBytes(B,2);
End;

Procedure Put32(Value: LongInt);
Var
 B: Array[0..3] Of Byte;
 J: Integer;
Begin
 For J := 0 To 3 Do Begin
  B[J] := Value And 255; Value := Value Shr 8;
 End;
 WriteBytes(B,4);
End;

Procedure WriteWaveHeader(DataSize: LongInt; Bits: Integer);
Var
 Tag: String[4];
 Align: Word;
 RiffSize: LongInt;
Begin
 Align := Header.Channels*(Bits Div 8);
 RiffSize := DataSize+36; If Odd(DataSize) Then Inc(RiffSize);
 Tag := 'RIFF'; WriteBytes(Tag[1],4); Put32(RiffSize);
 Tag := 'WAVE'; WriteBytes(Tag[1],4);
 Tag := 'fmt '; WriteBytes(Tag[1],4); Put32(16); Put16(1);
 Put16(Header.Channels); Put32(Header.Rate); Put32(Header.Rate*Align);
 Put16(Align); Put16(Bits);
 Tag := 'data'; WriteBytes(Tag[1],4); Put32(DataSize);
End;

Procedure CreateOutput;
Var
 Code: Integer;
Begin
 If Exists(OutputName) Then Fail('Le fichier de sortie existe deja: '+OutputName);
 Assign(OutputFile,OutputName);
 {$I-}Rewrite(OutputFile,1); Code := IOResult;{$I+}
 If Code <> 0 Then Fail('Creation WAV impossible: '+OutputName);
 OutputOpen := True; OutputCreated := True;
 FillChar(PCM,44,0); WriteBytes(PCM,44); Written := 0;
End;

Const
 MixRate = 22050;

Type
 TSample = Record
  Start, Length, LoopStart, LoopLength: LongInt;
  Volume, Fine: Integer;
 End;
 TVoice = Record
  Instrument, ActiveSample, Volume, MixVolume, Pan, Fine: Integer;
  Effect, Param, PortaSpeed, OffsetMemory, VibratoSpeed, VibratoDepth: Integer;
  TremoloSpeed, TremoloDepth, VibratoPhase, TremoloPhase: Integer;
  LoopRow, LoopCount, DelayPeriod: Integer;
  Period, Target, Position, Step: Double;
  Active: Boolean;
  CacheStart: LongInt;
  CacheCount: Integer;
  Cache: Array[0..1023] Of Byte;
 End;

Var
 Samples: Array[1..31] Of TSample;
 Voices: Array[0..3] Of TVoice;
 Orders: Array[0..127] Of Byte;
 Pattern: Array[0..1023] Of Byte;
 SongLength, PatternCount, LoadedPattern, Speed, BPM, Order, Row: Integer;
 PCMUsed: Integer;
 Rendered: LongInt;
 TickFraction: Double;

Function BE16(Const B; Index: Integer): LongInt;
Type
 TBytes = Array[0..1083] Of Byte;
Begin
 BE16 := LongInt(TBytes(B)[Index])*256 + TBytes(B)[Index+1];
End;

Function Clamp(Value, Low, High: Integer): Integer;Begin
 If Value < Low Then Value := Low;
 If Value > High Then Value := High;
 Clamp := Value;
End;

Procedure FlushMix;Begin
 If PCMUsed = 0 Then Exit;
 If Written > 2147483600 - PCMUsed Then Fail('Sortie WAV trop grande.');
 WriteBytes(PCM,PCMUsed); Inc(Written,PCMUsed); PCMUsed := 0;
End;

Procedure PutSample(Value: LongInt);Begin
 If Value < -32768 Then Value := -32768;
 If Value > 32767 Then Value := 32767;
 If Value < 0 Then Inc(Value, 65536);
 PCM[PCMUsed] := Value And 255; PCM[PCMUsed+1] := Value Shr 8;
 Inc(PCMUsed, 2);
 If PCMUsed = SizeOf(PCM) Then FlushMix;
End;

Procedure Trigger(Var V: TVoice; Note: Integer; Offset: LongInt);Begin
 If (V.Instrument < 1) Or (Note = 0) Then Exit;
 V.ActiveSample := V.Instrument;
 V.Period := Note * Exp(-V.Fine*Ln(2)/96);
 V.Position := Offset; V.CacheStart := -1; V.CacheCount := 0;
 V.Active := Offset < Samples[V.ActiveSample].Length;
 V.VibratoPhase := 0; V.TremoloPhase := 0;
End;

Procedure SlideVolume(Var V: TVoice; Param: Integer);Begin
 If (Param Shr 4) > 0 Then Inc(V.Volume, Param Shr 4)
                      Else Dec(V.Volume, Param And 15);
 V.Volume := Clamp(V.Volume,0,64);
End;

Procedure TonePorta(Var V: TVoice);Begin
 If (V.Target <= 0) Or (V.Period <= 0) Then Exit;
 If V.Period < V.Target Then Begin
  V.Period := V.Period + V.PortaSpeed;
  If V.Period > V.Target Then V.Period := V.Target;
 End Else
 Begin
  V.Period := V.Period - V.PortaSpeed;
  If V.Period < V.Target Then V.Period := V.Target;
 End;
End;

Procedure RowEvents(Var JumpOrder, BreakRow, LoopTo, DelayRows: Integer;
                    Var Stop: Boolean);
Var
 C, At, Inst, Note, Fx, CellParam, X, Y: Integer;
Begin
 For C := 0 To 3 Do Begin
  At := Row*16+C*4;
  Inst := (Pattern[At] And $F0) Or (Pattern[At+2] Shr 4);
  Note := (Word(Pattern[At] And 15) Shl 8) Or Pattern[At+1];
  Fx := Pattern[At+2] And 15; CellParam := Pattern[At+3]; X := CellParam Shr 4;
  Y := CellParam And 15;
  If Inst > 31 Then Fail('Instrument MOD invalide.');
  If (Note <> 0) And ((Note < 28) Or (Note > 3424)) Then Fail('Periode MOD invalide.');
  With Voices[C] Do Begin
   Effect := Fx; Voices[C].Param := CellParam; DelayPeriod := 0;
   If Inst > 0 Then Begin
    Instrument := Inst; Volume := Samples[Inst].Volume; Fine := Samples[Inst].Fine;
   End;
   If (Fx = 14) And (X = 5) Then Begin
    Fine := Y; If Fine > 7 Then Dec(Fine,16);
   End;
   If (Fx = 9) And (CellParam > 0) Then OffsetMemory := CellParam;
   If (Fx = 3) And (CellParam > 0) Then PortaSpeed := CellParam;
   If Fx = 4 Then Begin
    If X > 0 Then VibratoSpeed := X;
    If Y > 0 Then VibratoDepth := Y;
   End;
   If Fx = 7 Then Begin
    If X > 0 Then TremoloSpeed := X;
    If Y > 0 Then TremoloDepth := Y;
   End;
   If Note > 0 Then Begin
    If (Fx = 3) Or (Fx = 5) Then Target := Note*Exp(-Fine*Ln(2)/96) Else
    If (Fx = 14) And (X = 13) And (Y > 0) Then DelayPeriod := Note Else
    If Fx = 9 Then Trigger(Voices[C], Note, LongInt(OffsetMemory)*256)
              Else Trigger(Voices[C], Note, 0);
   End;
   Case Fx Of
   8: Pan := CellParam;
   11: JumpOrder := CellParam;
   12: Volume := Clamp(CellParam,0,64);
   13:
   Begin
    If (X > 6) Or (Y > 9) Or (X*10+Y > 63) Then Fail('Pattern break MOD invalide.');
    BreakRow := X*10+Y;
   End;
   14: Case X Of
   1: If Period > 0 Then Period := Clamp(Round(Period)-Y,113,856);
   2: If Period > 0 Then Period := Clamp(Round(Period)+Y,113,856);
   5:
   Begin
   End;
   6: If Y = 0 Then LoopRow := Row Else
   Begin
    If LoopCount = 0 Then LoopCount := Y Else Dec(LoopCount);
    If LoopCount > 0 Then LoopTo := LoopRow;
   End;
   8: Pan := Y*17;
   9:
   Begin
   End;
   10: Volume := Clamp(Volume+Y,0,64);
   11: Volume := Clamp(Volume-Y,0,64);
   12: If Y = 0 Then Volume := 0;
   13:
   Begin
   End;
   14: DelayRows := Y;
   Else Fail('Effet MOD E0/E3/E4/E7/EF non pris en charge.');
  End;
  15: If CellParam = 0 Then Stop := True Else
  If CellParam < 32 Then Speed := CellParam Else BPM := CellParam;
 End;
End;
End;
End;

Procedure TickEffects(Tick: Integer);
Var
 C, X, Y, Semitone: Integer;
 PlayPeriod: Double;
Begin
 For C := 0 To 3 Do With Voices[C] Do Begin
  X := Param Shr 4; Y := Param And 15;
  If Tick > 0 Then Begin
   Case Effect Of
   1: If Period > 0 Then Period := Clamp(Round(Period)-Param,113,856);
   2: If Period > 0 Then Period := Clamp(Round(Period)+Param,113,856);
   3: TonePorta(Voices[C]);
   5:
   Begin
    TonePorta(Voices[C]); SlideVolume(Voices[C], Param);
   End;
   6,10: SlideVolume(Voices[C], Param);
   14: Case X Of
   9: If Y > 0 Then If (Tick Mod Y) = 0 Then Begin
    Position := 0; Active := ActiveSample > 0;
   End;
   12: If Tick = Y Then Volume := 0;
   13: If (Tick = Y) And (DelayPeriod > 0) Then Trigger(Voices[C], DelayPeriod, 0);
  End;
 End;
End;
PlayPeriod := Period; MixVolume := Volume;
If (Effect = 0) And (Param <> 0) And (Period > 0) Then Begin
 Semitone := 0;
 Case Tick Mod 3 Of 1: Semitone := X; 2: Semitone := Y;
End;
PlayPeriod := Period*Exp(-Semitone*Ln(2)/12);
End;
If (Tick > 0) And ((Effect = 4) Or (Effect = 6)) Then Begin
 PlayPeriod := Period + Sin(VibratoPhase*2*Pi/64)*VibratoDepth*2;
 VibratoPhase := (VibratoPhase+VibratoSpeed) Mod 64;
End;
If (Tick > 0) And (Effect = 7) Then Begin
 MixVolume := Clamp(Volume+Round(Sin(TremoloPhase*2*Pi/64)*TremoloDepth*4),0,64);
 TremoloPhase := (TremoloPhase+TremoloSpeed) Mod 64;
End;
If PlayPeriod > 0 Then Step := 3546894.6 / (PlayPeriod*MixRate) Else Step := 0;
End;
End;

Function VoiceValue(Var V: TVoice): LongInt;
Var
 Index, EndPoint, RemainingBytes: LongInt;
 N, Value: Integer;
Begin
 VoiceValue := 0;
 If Not V.Active Or (V.ActiveSample < 1) Then Exit;
 With Samples[V.ActiveSample] Do Begin
  EndPoint := Length;
  If LoopLength > 2 Then EndPoint := LoopStart+LoopLength;
  If V.Position >= EndPoint Then Begin
   If LoopLength > 2 Then    V.Position := LoopStart + (V.Position-LoopStart) - Trunc((
   V.Position-LoopStart)/LoopLength)*LoopLength
    Else
   Begin
    V.Active := False; Exit;
   End;
  End;
  Index := Trunc(V.Position);
  If (Index < 0) Or (Index >= Length) Then Begin
   V.Active := False; Exit;
  End;
  If (V.CacheStart < 0) Or (Index < V.CacheStart) Or (Index >= V.CacheStart+V.CacheCount)
  Then Begin
   V.CacheStart := (Index Div 1024)*1024;
   RemainingBytes := Length-V.CacheStart;
   If RemainingBytes > 1024 Then N := 1024 Else N := RemainingBytes;
   ReadAt(Samples[V.ActiveSample].Start+V.CacheStart, V.Cache, N);
   V.CacheCount := N;
  End;
  Value := V.Cache[Index-V.CacheStart]; If Value >= 128 Then Dec(Value,256);
  VoiceValue := LongInt(Value)*V.MixVolume*2;
  V.Position := V.Position+V.Step;
 End;
End;

Procedure MixTick;
Var
 N, J, C: Integer;
 L, R, Value: LongInt;
Begin
 TickFraction := TickFraction + MixRate*2.5/BPM;
 N := Trunc(TickFraction); TickFraction := TickFraction-N;
 If Rendered > MixRate*1800-N Then Fail('Morceau MOD trop long (limite 30 minutes).');
 Inc(Rendered, N);
 For J := 1 To N Do Begin
  L := 0; R := 0;
  For C := 0 To 3 Do Begin
   Value := VoiceValue(Voices[C]);
   Inc(L, Value*(255-Voices[C].Pan) Div 255);
   Inc(R, Value*Voices[C].Pan Div 255);
  End;
  PutSample(L); PutSample(R);
 End;
End;

Procedure Convert;
Var
 B: Array[0..1083] Of Byte;
 Code, I, J, SampleFine, Tick, DelayRows, JumpOrder,
 BreakRow, LoopTo, NextOrder, NextRow: Integer;
 DataStart, LengthBytes, Steps: LongInt;
 OldMode: Byte;
 Signature: String[4];
 Stop: Boolean;
Begin
 Assign(InputFile, InputName); OldMode := FileMode; FileMode := 0;
 {$I-}Reset(InputFile,1); Code := IOResult;{$I+}
 FileMode := OldMode;
 If Code <> 0 Then Fail('Ouverture MOD impossible: '+InputName);
 InputOpen := True;
 {$I-}InputSize := FileSize(InputFile); Code := IOResult;{$I+}
 If (Code <> 0) Or (InputSize < 1084) Then Fail('Entete MOD tronquee.');
 ReadAt(0,B,1084);
 Signature := '';
 For I := 1080 To 1083 Do Signature := Signature+Chr(B[I]);
 If (Signature <> 'M.K.') And (Signature <> 'M!K!') And (Signature <> '4CHN') And (
 Signature <> 'FLT4') Then  Fail(
 'MOD 4 canaux/31 instruments requis: M.K., M!K!, 4CHN ou FLT4.');
 SongLength := B[950];
 If (SongLength < 1) Or (SongLength > 128) Then Fail('Longueur de chanson MOD invalide.');
 PatternCount := 0;
 For I := 0 To 127 Do Begin
  Orders[I] := B[952+I];
  If Orders[I] > 127 Then Fail('Numero de pattern MOD invalide.');
  If Orders[I]+1 > PatternCount Then PatternCount := Orders[I]+1;
 End;
 DataStart := 1084+LongInt(PatternCount)*1024;
 If DataStart > InputSize Then Fail('Patterns MOD tronques.');
 For I := 1 To 31 Do Begin
  J := 20+(I-1)*30;
  LengthBytes := BE16(B,J+22)*2; SampleFine := B[J+24];
  If (SampleFine > 15) Or (B[J+25] > 64) Then Fail('Finetune ou volume MOD invalide.');
  If SampleFine > 7 Then Dec(SampleFine,16);
  With Samples[I] Do Begin
   Start := DataStart; Length := LengthBytes; Volume := B[J+25];
   Samples[I].Fine := SampleFine;
   LoopStart := BE16(B,J+26)*2; LoopLength := BE16(B,J+28)*2;
   If (LoopLength > 2) And ((LoopStart > Length) Or (LoopLength > Length-LoopStart))
   Then Fail('Boucle echantillon MOD invalide.');
  End;
  If LengthBytes > InputSize-DataStart Then Fail('Echantillon MOD tronque.');
  Inc(DataStart, LengthBytes);
 End;
 FillChar(Voices,SizeOf(Voices),0);
 For I := 0 To 3 Do Begin
  Voices[I].CacheStart := -1;
  If I In [1,2] Then Voices[I].Pan := 255;
 End;
 Header.Rate := MixRate; Header.Channels := 2;
 PCMUsed := 0; Rendered := 0; TickFraction := 0; Speed := 6; BPM := 125;
 Order := 0; Row := 0; LoadedPattern := -1; Steps := 0; Stop := False;
 CreateOutput; WriteLn('Rendu MOD 4 canaux vers PCM stereo 22050 Hz...');
 While (Order < SongLength) And Not Stop Do Begin
  Inc(Steps); If Steps > 65536 Then Fail('Trop de lignes MOD executees.');
  If Orders[Order] <> LoadedPattern Then Begin
   ReadAt(1084+LongInt(Orders[Order])*1024,Pattern,1024); LoadedPattern := Orders[Order];
  End;
  JumpOrder := -1; BreakRow := -1; LoopTo := -1; DelayRows := 0;
  RowEvents(JumpOrder,BreakRow,LoopTo,DelayRows,Stop);
  If Stop Then Break;
  For Tick := 0 To Speed*(DelayRows+1)-1 Do Begin
   TickEffects(Tick Mod Speed); MixTick;
  End;
  NextOrder := Order; NextRow := Row+1;
  If NextRow = 64 Then Begin
   Inc(NextOrder); NextRow := 0;
  End;
  If LoopTo >= 0 Then Begin
   NextOrder := Order; NextRow := LoopTo;
  End;
  If (JumpOrder >= 0) Or (BreakRow >= 0) Then Begin
   If JumpOrder >= 0 Then NextOrder := JumpOrder Else NextOrder := Order+1;
   If BreakRow >= 0 Then NextRow := BreakRow Else NextRow := 0;
   { Un saut de chanson en arriere termine le rendu; les boucles E6 sont executees. }
   If (NextOrder < Order) Or ((NextOrder = Order) And (NextRow <= Row)) Then Stop := True;
  End;
  If NextOrder <> Order Then
  For I := 0 To 3 Do Begin
   Voices[I].LoopRow := 0; Voices[I].LoopCount := 0;
  End;
  Order := NextOrder; Row := NextRow;
 End;
 FlushMix;
 If Written = 0 Then Fail('Aucune duree audio MOD.');
 {$I-}Seek(OutputFile,0); Code := IOResult;{$I+}
 if Code <> 0 Then Fail('Positionnement entete WAV impossible.');
 WriteWaveHeader(Written,16);
 {$I-}Close(InputFile); Code := IOResult;{$I+} InputOpen := False;
 if Code <> 0 Then Fail('Fermeture MOD impossible.');
 {$I-}Close(OutputFile); Code := IOResult;{$I+} OutputOpen := False;
 if Code <> 0 Then Fail('Fermeture WAV impossible.');
 OutputCreated := False;
 WriteLn('WAV cree: ',OutputName);
 WriteLn('PCM16 stereo 22050 Hz, ',Rendered,' trames, ',Rendered/MixRate:0:3,' secondes.');
End;


Var
 I: Integer;
 Argument: String;

BEGIN
 InputOpen := False; OutputOpen := False; OutputCreated := False;
 SavedExit := ExitProc; ExitProc := @ExitCleanup;
 For I := 1 To ParamCount Do Begin
  Argument := ParamStr(I);
  If (Argument = '/?') Or (Argument = '--help') Or (Argument = '-h') Then Begin
   Help; Halt(0);
  End;
 End;
 If (ParamCount < 1) Or (ParamCount > 2) Then Begin
  Help; Halt(1);
 End;
 InputName := ParamStr(1);
 If ParamCount = 2 Then OutputName := ParamStr(2) Else OutputName := DefaultOutput(
 InputName);
 If (InputName = '') Or (OutputName = '') Then Fail('Nom de fichier vide.');
 If Exists(OutputName) Then Fail('Le fichier de sortie existe deja: '+OutputName);
 Convert;
END.
