{ @author: Sylvain Maltais (support@gladir.com)
 @created: 2026
 @version: 1.00
 @website(https://www.gladir.com/speech-to-text-0)
 @abstract(Target: Turbo Pascal 7/Free Pascal 3.2
 @description: Joueur de MOD }

Program PLAYMOD;

{$A-}
{$IFDEF FPC}
 {$MODE TP}
{$ENDIF}
{$IFNDEF FPC}
 {$N+}{$E+}
{$ENDIF}
{ Lecteur MOD ProTracker procedural. Voir PLAYMOD.md. }
{$IFDEF FPC}
 {$IFNDEF MSWINDOWS}
  {$IFNDEF CPU8086}
   {$FATAL DOS real-mode 8086 or Windows required}
  {$ENDIF}
 {$ENDIF}
{$ENDIF}

Uses DOS
{$IFNDEF MSWINDOWS}
 , Crt
{$ENDIF}
;

{$IFDEF MSWINDOWS}
{ Declarations Win32/Win64 locales. Les DLL sont celles du systeme Windows.
  DWORD reste sur 32 bits; handles et DWORD_PTR suivent la taille du pointeur.
  Ces deux structures ont la disposition binaire des en-tetes multimedia. }
 Type
  DWORD = LongWord;
  HWAVEOUT = PtrUInt;
  PHWAVEOUT = ^HWAVEOUT;
  TWaveFormatEx = Packed Record
   wFormatTag, nChannels: Word;
   nSamplesPerSec, nAvgBytesPerSec: DWORD;
   nBlockAlign, wBitsPerSample, cbSize: Word;
  End;
  PWaveFormatEx = ^TWaveFormatEx;
  PWaveHdr = ^TWaveHdr;
  TWaveHdr = Packed Record
   lpData: PChar;
   dwBufferLength, dwBytesRecorded: DWORD;
   dwUser: PtrUInt;
   dwFlags, dwLoops: DWORD;
   lpNext: PWaveHdr;
   reserved: PtrUInt;
  End;

 Const
  WAVE_FORMAT_PCM = 1;
  WAVE_MAPPER = DWORD($FFFFFFFF);
  CALLBACK_NULL = 0;
  MMSYSERR_NOERROR = 0;
  WHDR_DONE = 1;
  WHDR_PREPARED = 2;
  WHDR_INQUEUE = 16;

 Function waveOutOpen(Handle: PHWAVEOUT; Device: DWORD; Format: PWaveFormatEx;
                      Callback, Instance: PtrUInt; Flags: DWORD): DWORD;
 stdcall;
 external 'winmm.dll' name 'waveOutOpen';

 Function waveOutPrepareHeader(Handle: HWAVEOUT; Header: PWaveHdr; Size: DWORD): DWORD;
 stdcall; external 'winmm.dll' name 'waveOutPrepareHeader';

 Function waveOutUnprepareHeader(Handle: HWAVEOUT; Header: PWaveHdr; Size: DWORD): DWORD;
 stdcall; external 'winmm.dll' name 'waveOutUnprepareHeader';

 Function waveOutWrite(Handle: HWAVEOUT; Header: PWaveHdr; Size: DWORD): DWORD;
 stdcall; external 'winmm.dll' name 'waveOutWrite';

 Function waveOutReset(Handle: HWAVEOUT): DWORD;
 stdcall;
 external 'winmm.dll' name 'waveOutReset';

 Function waveOutClose(Handle: HWAVEOUT): DWORD;
 stdcall;
 external 'winmm.dll' name 'waveOutClose';

 Function GetTickCount: DWORD;
 stdcall; external 'kernel32.dll' name 'GetTickCount';

 Procedure Sleep(Milliseconds: DWORD);
 stdcall; external 'kernel32.dll' name 'Sleep';
{$ENDIF}

Const
 MaxWaveData = 2147483600;

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
 SavedExit: Pointer;
 Header, FirstHeader: TAudioFormat;
 PCM: Array[0..4095] Of Byte;
Procedure StopAudio;Forward;

Procedure Fail(MessageText: String);
Var
 ErrorCode: Integer;
Begin
 StopAudio;
 WriteLn('PLAYMOD: ', MessageText);
 If InputOpen Then Begin
  {$I-}Close(InputFile); ErrorCode := IOResult;{$I+}
  InputOpen := False;
 End;
 If OutputOpen Then Begin
  {$I-}Close(OutputFile); ErrorCode := IOResult;{$I+}
  OutputOpen := False;
 End;
 If OutputCreated Then Begin
  {$I-}Erase(OutputFile); ErrorCode := IOResult;{$I+}
  If ErrorCode <> 0 Then WriteLn('Fichier temporaire a supprimer: ', OutputName);
  OutputCreated := False;
 End;
 Halt(1);
End;

Function Exists(Name: String): Boolean;
Var
 F: File;
 Attributes: Word;
Begin
 Assign(F, Name); GetFAttr(F, Attributes); Exists := DosError = 0;
End;

Procedure Help;Begin
 WriteLn('PLAYMOD - Cette commande permet de lancer le lecteur de fichiers MOD.');
 WriteLn;
 WriteLn('Syntaxe: PLAYMOD fichier.mod [/VOLUME:0..100] [/LOOP:1..32767]');
 WriteLn;
 WriteLn('Volume logiciel: 100 par defaut. LOOP: nombre total de lectures, defaut 1.');
 WriteLn('MOD ProTracker 4 canaux, 31 instruments: M.K., M!K!, 4CHN, FLT4.');
 WriteLn('Effets usuels integres; effets non pris en charge refuses. Voir PLAYMOD.md.');
 WriteLn('Windows: API waveOut directes. DOS: SB 2.0+, BLASTER requis; Echap arrete.');
 WriteLn('Rendu du morceau dans un fichier PCM temporaire avant lecture.');
 WriteLn('Aide: /? ou --help');
End;

Procedure ReadAt(Position: LongInt; Var Buffer; Count: Word);
Var
 Actual: Word;
 ErrorCode: Integer;
Begin
 If (Position < 0) Or (Position > InputSize) Then Fail('Position WAV incorrecte.');
 If Count > InputSize - Position Then Fail('Fichier WAV tronque.');
 {$I-}Seek(InputFile, Position); ErrorCode := IOResult;{$I+}
 If ErrorCode <> 0 Then Fail('Positionnement WAV impossible.');
 {$I-}BlockRead(InputFile, Buffer, Count, Actual); ErrorCode := IOResult;{$I+}
 If (ErrorCode <> 0) Or (Actual <> Count) Then Fail('Lecture WAV incomplete.');
End;

Procedure WriteBytes(Var Buffer; Count: Word);
Var
 Actual: Word;
 ErrorCode: Integer;
Begin
 {$I-}BlockWrite(OutputFile, Buffer, Count, Actual); ErrorCode := IOResult;{$I+}
 If (ErrorCode <> 0) Or (Actual <> Count) Then Fail('Ecriture PCM temporaire incomplete.')
 ;
End;

Const
 AudioBlock = 4096;

Type
 TAudioBytes = Array[0..AudioBlock-1] Of Byte;
 {$IFDEF MSWINDOWS}
  TOutputSlot = Record
   Data: TAudioBytes;
   Head: TWaveHdr;
   Prepared: Boolean;
  End;
 {$ELSE}
  TDMAArea = Array[0..16383] Of Byte;
  PDMAArea = ^TDMAArea;
  TDMABytes = Array[0..8191] Of Byte;
  PDMABytes = ^TDMABytes;
 {$ENDIF}

Var
 Volume, Loops: Integer;
 AudioActive: Boolean;
 Phase: LongInt;
 {$IFDEF MSWINDOWS}
  WaveHandle: HWAVEOUT;
  Slots: Array[0..3] Of TOutputSlot;
 {$ELSE}
  SBBase, SBIRQ, SBDMA: Word;
  OldMask: Byte;
  OldVector: Pointer;
  IRQInstalled: Boolean;
  DMAArea: PDMAArea;
  DMABuffer: PDMABytes;
  Completed: Word;
 {$ENDIF}
Procedure StopAudio;
{$IFDEF MSWINDOWS}

 Var
  J: Integer;
 Begin
  If AudioActive Then Begin
   waveOutReset(WaveHandle);
   For J := 0 To 3 Do   If Slots[J].Prepared Then Begin
    waveOutUnprepareHeader(WaveHandle, @Slots[J].Head, SizeOf(TWaveHdr));
    Slots[J].Prepared := False;
   End;
   waveOutClose(WaveHandle); AudioActive := False;
  End;
 End;
{$ELSE}

 Var
  Dummy: Byte;
 Begin
  If AudioActive Then Begin
  { Reset stops the DSP and releases its DMA request before restoring IRQ. }
   Port[SBBase + 6] := 1; Delay(1); Port[SBBase + 6] := 0;
   Port[$0A] := 4 Or SBDMA;
   AudioActive := False;
  End;
  If IRQInstalled Then Begin
   Port[$21] := Port[$21] Or (1 Shl SBIRQ);
   Dummy := Port[SBBase + $0E];
   SetIntVec(8 + SBIRQ, OldVector);
   Port[$21] := OldMask;
   IRQInstalled := False;
  End;
  If DMAArea <> Nil Then Begin
   Dispose(DMAArea); DMAArea := Nil;
  End;
 End;
{$ENDIF}

Procedure EmitPCM(Count: Word);
Var
 J, C, OutCount: Integer;
 Sample, Value: LongInt;
 Bytes: TAudioBytes;
Begin
 {$IFDEF MSWINDOWS}
  J := 0;
  While J < Count Do Begin
   Sample := LongInt(PCM[J]) + LongInt(PCM[J+1]) * 256;
   If Sample >= 32768 Then Dec(Sample, 65536);
   Sample := Sample * Volume Div 100;
   If Sample < 0 Then Inc(Sample, 65536);
   PCM[J] := Sample And 255; PCM[J+1] := Sample Shr 8;
   Inc(J, 2);
  End;
  WriteBytes(PCM, Count); Inc(Written, Count);
 {$ELSE}
 { Rate 1000000/45 matches DSP time constant 211. Nearest-sample
   conversion; fractional phase persists across frames. }
  OutCount := 0; J := 0;
  While J < Count Do Begin
   Value := 0;
   For C := 0 To Header.Channels-1 Do Begin
    Sample := LongInt(PCM[J]) + LongInt(PCM[J+1]) * 256;
    If Sample >= 32768 Then Dec(Sample, 65536);
    Inc(Value, Sample); Inc(J, 2);
   End;
   Value := (Value Div Header.Channels) * Volume Div 100;
   Inc(Phase, 1000000);
   While Phase >= Header.Rate * 45 Do Begin
    Dec(Phase, Header.Rate * 45);
    Bytes[OutCount] := (Value + 32768) Div 256;
    Inc(OutCount);
    If OutCount = AudioBlock Then Begin
     WriteBytes(Bytes, OutCount); Inc(Written, OutCount); OutCount := 0;
    End;
   End;
  End;
  If OutCount > 0 Then Begin
   WriteBytes(Bytes, OutCount); Inc(Written, OutCount);
  End;
 {$ENDIF}
End;

Procedure MakeTemporary;
Var
 Attempt, ErrorCode: Integer;
 Digits: String;
Begin
 Randomize;
 For Attempt := 1 To 100 Do Begin
  Str(Random(30000), Digits); OutputName := 'PT' + Digits + '.TMP';
  If Not Exists(OutputName) Then Begin
   Assign(OutputFile, OutputName);
   {$I-}Rewrite(OutputFile, 1); ErrorCode := IOResult;{$I+}
   If ErrorCode <> 0 Then Fail('Creation temporaire impossible: ' + OutputName);
   OutputOpen := True; OutputCreated := True; Exit;
  End;
 End;
 Fail('Aucun nom temporaire disponible.');
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
 If Written > MaxWaveData - 16384 Then Fail('PCM temporaire trop grand.');
 EmitPCM(PCMUsed); PCMUsed := 0;
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

Procedure Prepare;
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
 Header.Rate := MixRate; Header.Channels := 2; FirstHeader := Header;
 PCMUsed := 0; Rendered := 0; TickFraction := 0; Speed := 6; BPM := 125;
 Order := 0; Row := 0; LoadedPattern := -1; Steps := 0; Stop := False;
 MakeTemporary; WriteLn('Rendu MOD 4 canaux vers PCM stereo 22050 Hz...');
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
   { Un saut de chanson en arriere termine un passage; /LOOP rejoue le rendu. }
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
 WriteLn('Duree rendue: ', Rendered/MixRate:0:3, ' secondes.');
 {$I-}Close(InputFile); Code := IOResult;{$I+} InputOpen := False;
 If Code <> 0 Then Fail('Fermeture MOD impossible.');
 {$I-}Close(OutputFile); Code := IOResult;{$I+} OutputOpen := False;
 If Code <> 0 Then Fail('Fermeture temporaire impossible.');
 {$I-}Reset(OutputFile,1); Code := IOResult;{$I+}
 If Code <> 0 Then Fail('Relecture temporaire impossible.');
 OutputOpen := True;
End;

Procedure ReadPCM(Var Buffer; Count: Word; Var Actual: Word);
Var
 ErrorCode: Integer;
Begin
 {$I-}BlockRead(OutputFile, Buffer, Count, Actual); ErrorCode := IOResult;{$I+}
 If ErrorCode <> 0 Then Fail('Lecture PCM temporaire impossible.');
End;

Procedure RewindPCM;
Var
 ErrorCode: Integer;
Begin
 {$I-}Seek(OutputFile, 0); ErrorCode := IOResult;{$I+}
 If ErrorCode <> 0 Then Fail('Positionnement PCM impossible.');
End;
{$IFDEF MSWINDOWS}

 Procedure Play;
 Var
  Format: TWaveFormatEx;
  J, Pass: Integer;
  Actual: Word;
  Started: DWORD;
 Begin
  FillChar(Format, SizeOf(Format), 0);
  Format.wFormatTag := WAVE_FORMAT_PCM;
  Format.nChannels := FirstHeader.Channels;
  Format.nSamplesPerSec := FirstHeader.Rate;
  Format.wBitsPerSample := 16;
  Format.nBlockAlign := Format.nChannels * 2;
  Format.nAvgBytesPerSec := Format.nSamplesPerSec * Format.nBlockAlign;
  If waveOutOpen(@WaveHandle, WAVE_MAPPER, @Format, 0, 0, CALLBACK_NULL) <>
  MMSYSERR_NOERROR Then  Fail(
  'Ouverture waveOut impossible (carte absente ou format refuse).');
  AudioActive := True;
  For J := 0 To 3 Do Begin
   FillChar(Slots[J].Head, SizeOf(TWaveHdr), 0);
   Slots[J].Head.lpData := @Slots[J].Data;
   Slots[J].Head.dwBufferLength := AudioBlock;
   If waveOutPrepareHeader(WaveHandle, @Slots[J].Head, SizeOf(TWaveHdr)) <>
   MMSYSERR_NOERROR Then Fail('waveOutPrepareHeader a echoue.');
   Slots[J].Prepared := True;
  End;
  J := 0;
  For Pass := 1 To Loops Do Begin
   RewindPCM;
   Repeat
   Started := GetTickCount;
   While ((Slots[J].Head.dwFlags And WHDR_INQUEUE) <> 0) Do Begin
    If DWORD(GetTickCount - Started) > 10000 Then Fail('Delai waveOut depasse.');
    Sleep(1);
   End;
   ReadPCM(Slots[J].Data, AudioBlock, Actual);
   If Actual > 0 Then Begin
    Slots[J].Head.dwBufferLength := Actual;
    If waveOutWrite(WaveHandle, @Slots[J].Head, SizeOf(TWaveHdr)) <>
    MMSYSERR_NOERROR Then Fail('waveOutWrite a echoue.');
    J := (J + 1) Mod 4;
   End;
   Until Actual = 0;
  End;
  For J := 0 To 3 Do Begin
   Started := GetTickCount;
   While (Slots[J].Head.dwFlags And WHDR_INQUEUE) <> 0 Do Begin
    If DWORD(GetTickCount - Started) > 10000 Then Fail('Fin waveOut bloquee.');
    Sleep(1);
   End;
  End;
  StopAudio;
 End;
{$ELSE}

 Function ClockMS: LongInt;
 Var
  H, M, S, HS: Word;
 Begin
  GetTime(H, M, S, HS);
  ClockMS := ((LongInt(H) * 60 + M) * 60 + S) * 1000 + HS * 10;
 End;

 Function TimedOut(Start: LongInt): Boolean;
 Var
  Delta: LongInt;
 Begin
  Delta := ClockMS - Start;
  If Delta < 0 Then Inc(Delta, 86400000);
  TimedOut := Delta > 3000;
 End;

 Procedure DSPWrite(Value: Byte);
 Var
  Start: LongInt;
 Begin
  Start := ClockMS;
  While (Port[SBBase + $0C] And $80) <> 0 Do  If TimedOut(Start) Then Fail(
  'DSP Sound Blaster bloque.');
  Port[SBBase + $0C] := Value;
 End;

 Function DSPRead: Byte;
 Var
  Start: LongInt;
 Begin
  Start := ClockMS;
  While (Port[SBBase + $0E] And $80) = 0 Do  If TimedOut(Start) Then Fail(
  'Sound Blaster absente ou BLASTER incorrect.');
  DSPRead := Port[SBBase + $0A];
 End;

 Procedure SoundIRQ;
 Interrupt;

 Var
  Dummy: Byte;
 Begin
  Dummy := Port[SBBase + $0E];
  Inc(Completed);
  Port[$20] := $20;
 End;

 Procedure ConfigureSB;
 Var
  Env, Token: String;
  I, J, Code, Number: Integer;
  Major, Minor: Byte;
  Physical: LongInt;
  Offset: Word;
 Begin
  Env := GetEnv('BLASTER'); I := 1;
  While I <= Length(Env) Do Begin
   While (I <= Length(Env)) And (Env[I] = ' ') Do Inc(I);
   J := I;
   While (I <= Length(Env)) And (Env[I] <> ' ') Do Inc(I);
   Token := Copy(Env, J, I-J);
   If Length(Token) > 1 Then Begin
    If UpCase(Token[1]) In ['A','I','D'] Then Begin
     If UpCase(Token[1]) = 'A' Then Val('$'+Copy(Token,2,255),Number,Code)
                               Else Val(Copy(Token,2,255),Number,Code);
     If Code <> 0 Then Fail('Variable BLASTER invalide.');
     Case UpCase(Token[1]) Of 'A': SBBase := Number; 'I': SBIRQ := Number;
     'D': SBDMA := Number;
    End;
   End;
  End;
 End;
 If (SBBase < $210) Or (SBBase > $280) Or ((SBBase And 15) <> 0) Or
 Not (SBIRQ In [3,5,7]) Or Not (SBDMA In [1,3]) Then  Fail(
 'BLASTER requis: base A210..A280, IRQ I3/I5/I7, DMA D1/D3.');
 Port[SBBase + 6] := 1; Delay(1); Port[SBBase + 6] := 0;
 If DSPRead <> $AA Then Fail('Reinitialisation DSP incorrecte.');
 DSPWrite($E1); Major := DSPRead; Minor := DSPRead;
 If Major < 2 Then Fail('Sound Blaster 2.0 ou superieure requise (DMA auto-init).');
 WriteLn('Sound Blaster DSP ', Major, '.', Minor, ' ; mono 8 bits, 22222 Hz.');
 New(DMAArea);
 Physical := LongInt(Seg(DMAArea^)) * 16 + Ofs(DMAArea^);
 Offset := 0;
 If (Physical And $FFFF) > $E000 Then Offset := $10000 - (Physical And $FFFF);
 Inc(Physical, Offset);
 DMABuffer := Ptr(Physical Div 16, Physical And 15);
 GetIntVec(8 + SBIRQ, OldVector); OldMask := Port[$21];
 Port[$21] := OldMask Or (1 Shl SBIRQ);
 SetIntVec(8 + SBIRQ, @SoundIRQ); IRQInstalled := True;
 End;

 Procedure FillHalf(Half: Integer);
 Var
  Actual: Word;
 Begin
  FillChar(DMABuffer^[Half * AudioBlock], AudioBlock, 128);
  ReadPCM(DMABuffer^[Half * AudioBlock], AudioBlock, Actual);
 End;

 Procedure Play;
 Const
  Pages: Array[0..3] Of Byte = ($87,$83,$81,$82);
 Var
  Physical, Start, Blocks, Done: LongInt;
  Seen, Current: Word;
  Pass: Integer;
  Dummy: Byte;
 Begin
  CheckBreak := False;
  ConfigureSB;
  Physical := LongInt(Seg(DMABuffer^)) * 16 + Ofs(DMABuffer^);
  For Pass := 1 To Loops Do Begin
   RewindPCM; FillHalf(0); FillHalf(1);
   Completed := 0; Seen := 0; Done := 0;
   Blocks := (Written + AudioBlock-1) Div AudioBlock;
   Port[$0A] := 4 Or SBDMA;
   Port[$0C] := 0;
   Port[$0B] := $58 Or SBDMA; { single transfer, auto-init, memory -> device }
   Port[SBDMA * 2] := Physical And 255;
   Port[SBDMA * 2] := (Physical Shr 8) And 255;
   Port[Pages[SBDMA]] := Physical Shr 16;
   Port[$0C] := 0;
   Port[SBDMA * 2 + 1] := $FF;
   Port[SBDMA * 2 + 1] := $1F; { 8192-byte ring }
   AudioActive := True;
   Port[$0A] := SBDMA;
   Port[$21] := OldMask And Not (1 Shl SBIRQ);
   DSPWrite($D1); DSPWrite($40); DSPWrite(211);
   DSPWrite($48); DSPWrite($FF); DSPWrite($0F); { interrupt every 4096 bytes }
   DSPWrite($1C);
   Start := ClockMS;
   While Done < Blocks Do Begin
    If KeyPressed Then If ReadKey = #27 Then Begin
     StopAudio; Exit;
    End;
    Current := Completed;
    If Current <> Seen Then Begin
     If Word(Current-Seen) <> 1 Then Fail('Sous-alimentation du tampon Sound Blaster.');
     Inc(Done); Seen := Current;
     If Done < Blocks Then FillHalf((Done-1) Mod 2);
     Start := ClockMS;
    End
    Else If TimedOut(Start) Then Fail(
    'Aucune interruption Sound Blaster: verifier BLASTER.');
   End;
   DSPWrite($D0); DSPWrite($DA); DSPWrite($D3);
   Port[$0A] := 4 Or SBDMA;
   Port[$21] := Port[$21] Or (1 Shl SBIRQ);
   Dummy := Port[SBBase + $0E];
  End;
  StopAudio;
 End;
{$ENDIF}

Function Upper(Text: String): String;
Var
 J: Integer;
Begin
 For J := 1 To Length(Text) Do Text[J] := UpCase(Text[J]);
 Upper := Text;
End;
Procedure ExitCleanup;
{$IFNDEF FPC}
 Far;
{$ENDIF}

Var
 ErrorCode: Integer;
Begin
 ExitProc := SavedExit;
 StopAudio;
 If InputOpen Then Begin
  {$I-}Close(InputFile); ErrorCode := IOResult;{$I+}
  InputOpen := False;
 End;
 If OutputOpen Then Begin
  {$I-}Close(OutputFile); ErrorCode := IOResult;{$I+}
  OutputOpen := False;
 End;
 If OutputCreated Then Begin
  {$I-}Erase(OutputFile); ErrorCode := IOResult;{$I+}
  OutputCreated := False;
 End;
End;

Var
 Argument, Option: String;
 I, Code, Value, ErrorCode: Integer;

BEGIN
 InputName := ''; OutputName := '';
 InputOpen := False; OutputOpen := False; OutputCreated := False;
 AudioActive := False;
 Written := 0; Phase := 0;
 {$IFDEF MSWINDOWS}
  FillChar(Slots, SizeOf(Slots), 0);
 {$ELSE}
  DMAArea := Nil; IRQInstalled := False; SBBase := 0; SBIRQ := 0; SBDMA := 0;
 {$ENDIF}
 SavedExit := ExitProc; ExitProc := @ExitCleanup;
 Volume := 100; Loops := 1;
 For I := 1 To ParamCount Do Begin
  Argument := ParamStr(I); Option := Upper(Argument);
  If (Option = '/?') Or (Option = '--HELP') Or (Option = '-H') Then Begin
   Help; Halt(0);
  End
   Else
  If (Copy(Option,1,8) = '/VOLUME:') Or (Copy(Option,1,6) = '/LOOP:') Then Begin
   If Copy(Option,1,8) = '/VOLUME:' Then Val(Copy(Option,9,255),Value,Code)
                                    Else Val(Copy(Option,7,255),Value,Code);
   If Code <> 0 Then Fail('Valeur numerique incorrecte: ' + Argument);
   If Copy(Option,1,8) = '/VOLUME:' Then Begin
    If (Value < 0) Or (Value > 100) Then Fail('Volume attendu: 0..100.');
    Volume := Value;
   End Else
   Begin
    If (Value < 1) Then Fail('Nombre de lectures attendu: 1..32767.');
    Loops := Value;
   End;
  End
  Else If (Copy(Option,1,1) = '/') Or (Copy(Option,1,1) = '-') Then Fail(
  'Option inconnue: ' + Argument)
  Else If InputName <> '' Then Fail('Un seul fichier MOD attendu.')
                          Else InputName := Argument;
 End;
 If InputName = '' Then Begin
  Help; Halt(1);
 End;
 Prepare;
 Begin
  Play;
  {$I-}Close(OutputFile); ErrorCode := IOResult;{$I+}
  OutputOpen := False;
  If ErrorCode <> 0 Then Fail('Fermeture temporaire impossible.');
  {$I-}Erase(OutputFile); ErrorCode := IOResult;{$I+}
  If ErrorCode <> 0 Then Fail('Suppression temporaire impossible: ' + OutputName);
  OutputCreated := False;
 End;
END.
