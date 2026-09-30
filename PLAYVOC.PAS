{ @author: Sylvain Maltais (support@gladir.com)
 @created: 2026
 @version: 1.00
 @website(https://www.gladir.com/speech-to-text-0)
 @abstract(Target: Turbo Pascal 7/Free Pascal 3.2
 @description: Joueur de VOC }

Program PLAYVOC;

{$A-}
{$IFDEF FPC}
 {$MODE TP}
{$ENDIF}
{$IFNDEF FPC}
 {$N+}{$E+}
{$ENDIF}
{ Lecture Creative Voice PCM native. Voir PLAYVOC.md. }
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
 WriteLn('PLAYVOC: ', MessageText);
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
 WriteLn(
 'PLAYVOC - Cette commande permet de lancer le lecteur audio pour les fichiers VOC.');
 WriteLn;
 WriteLn('Syntaxe: PLAYVOC fichier.voc [/VOLUME:0..100] [/LOOP:1..32767]');
 WriteLn;
 WriteLn('Volume logiciel: 100 par defaut. LOOP: nombre total de lectures, defaut 1.');
 WriteLn(
 'Creative VOC PCM 8/16 bits, mono/stereo; blocs 1..9, silences et boucles finies.');
 WriteLn(
 'ADPCM, A-law, mu-law, boucles infinies et changements de frequence/canaux refuses.');
 WriteLn('Windows: API waveOut directes. DOS: SB 2.0+, BLASTER requis; Echap arrete.');
 WriteLn('Preparation dans un fichier PCM temporaire du dossier courant avant lecture.');
 WriteLn('Aide: /? ou --help');
End;

Procedure ReadAt(Position: LongInt; Var Buffer; Count: Word);
Var
 Actual: Word;
 ErrorCode: Integer;
Begin
 If (Position < 0) Or (Position > InputSize) Then Fail('Position VOC incorrecte.');
 If Count > InputSize - Position Then Fail('Fichier VOC tronque.');
 {$I-}Seek(InputFile, Position); ErrorCode := IOResult;{$I+}
 If ErrorCode <> 0 Then Fail('Positionnement VOC impossible.');
 {$I-}BlockRead(InputFile, Buffer, Count, Actual); ErrorCode := IOResult;{$I+}
 If (ErrorCode <> 0) Or (Actual <> Count) Then Fail('Lecture VOC incomplete.');
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
  Str(Random(30000), Digits); OutputName := 'PV' + Digits + '.TMP';
  If Not Exists(OutputName) Then Begin
   Assign(OutputFile, OutputName);
   {$I-}Rewrite(OutputFile, 1); ErrorCode := IOResult;{$I+}
   If ErrorCode <> 0 Then Fail('Creation temporaire impossible: ' + OutputName);
   OutputOpen := True; OutputCreated := True; Exit;
  End;
 End;
 Fail('Aucun nom temporaire disponible.');
End;

Function LE16(Const B; Offset: Integer): Word;
Type
 TSmallBytes = Array[0..63] Of Byte;
Begin
 LE16 := Word(TSmallBytes(B)[Offset]) Or (Word(TSmallBytes(B)[Offset+1]) Shl 8);
End;

Function LE32(Const B; Offset: Integer): LongInt;
Type
 TSmallBytes = Array[0..63] Of Byte;
Begin
 If TSmallBytes(B)[Offset+3] >= 128 Then Fail('Valeur VOC depassant 2 Go.');
 LE32 := LongInt(TSmallBytes(B)[Offset]) + LongInt(TSmallBytes(B)[Offset+1])*256 +
 LongInt(TSmallBytes(B)[Offset+2])*65536 + LongInt(TSmallBytes(B)[Offset+3])*16777216;
End;

Var
 HaveFormat, HaveSound: Boolean;

Procedure SetFormat(Rate: LongInt; Channels: Integer);Begin
 If (Rate < 4000) Or (Rate > 192000) Or Not (Channels In [1,2]) Then  Fail(
 'Format VOC attendu: 4000..192000 Hz, mono/stereo.');
 If HaveFormat Then Begin
  If (Header.Rate <> Rate) Or (Header.Channels <> Channels) Then   Fail(
  'Changement de frequence ou de canaux non pris en charge.');
 End Else
 Begin
  Header.Rate := Rate; Header.Channels := Channels; FirstHeader := Header;
  HaveFormat := True;
 End;
End;

Procedure SubmitPCM(Count: Word);Begin
 If Written > MaxWaveData - 16384 Then Fail('PCM temporaire depassant 2 Go.');
 EmitPCM(Count);
End;

Procedure ConvertData(Position, Count: LongInt; Bits: Integer);
Var
 Raw: Array[0..2047] Of Byte;
 N, J, OutCount, Align: Integer;
 Value: LongInt;
Begin
 Align := Header.Channels * (Bits Div 8);
 If (Count Mod Align) <> 0 Then Fail('Echantillon VOC incomplet.');
 If Count > 0 Then HaveSound := True;
 While Count > 0 Do Begin
  If Count > SizeOf(Raw) Then N := SizeOf(Raw) Else N := Count;
  ReadAt(Position, Raw, N); OutCount := 0;
  If Bits = 8 Then Begin
   For J := 0 To N-1 Do Begin
    Value := (LongInt(Raw[J])-128)*256;
    If Value < 0 Then Inc(Value, 65536);
    PCM[OutCount] := Value And 255; PCM[OutCount+1] := Value Shr 8;
    Inc(OutCount, 2);
   End;
  End Else
  Begin
   Move(Raw, PCM, N); OutCount := N;
  End;
  SubmitPCM(OutCount); Inc(Position, N); Dec(Count, N);
 End;
End;

Procedure WriteSilence(Cycles: LongInt; TimeConstant: Byte);
Var
 Frames, Count: LongInt;
Begin
 If Not HaveFormat Then SetFormat(1000000 Div (256-Word(TimeConstant)), 1);
 { Convertir la duree en nombre d'echantillons du format courant. }
 Frames := Round(Cycles * (256.0-TimeConstant) * Header.Rate / 1000000.0);
 FillChar(PCM, SizeOf(PCM), 0);
 While Frames > 0 Do Begin
  Count := Frames;
  If Count > 1024 Then Count := 1024;
  { EmitPCM peut modifier PCM sous Windows, mais les zeros restent nuls. }
  SubmitPCM(Count * Header.Channels * 2); Dec(Frames, Count);
 End;
 HaveSound := True;
End;

Procedure Prepare;
Const
 Signature = 'Creative Voice File';
Type
 TRepeatState = Record
  Position: LongInt;
  Left: Word;
  Bits: Integer;
 End;
Var
 B: Array[0..63] Of Byte;
 Stack: Array[1..8] Of TRepeatState;
 Position, Size, Next, Rate, ExtendedRate, Steps: LongInt;
 Bits, Channels, ExtendedChannels, Depth, J, Code, Kind, Codec: Integer;
 Version, Check: Word;
 OldMode: Byte;
 Extended, Terminated: Boolean;
Begin
 HaveFormat := False; HaveSound := False;
 Extended := False; Terminated := False; Depth := 0; Bits := 0; Steps := 0;
 ExtendedRate := 0; ExtendedChannels := 0;
 Assign(InputFile, InputName); OldMode := FileMode; FileMode := 0;
 {$I-}Reset(InputFile, 1); Code := IOResult;{$I+}
 FileMode := OldMode;
 If Code <> 0 Then Fail('Ouverture VOC impossible: ' + InputName);
 InputOpen := True;
 {$I-}InputSize := FileSize(InputFile); Code := IOResult;{$I+}
 If (Code <> 0) Or (InputSize < 26) Then Fail('VOC vide, trop grand ou tronque.');
 ReadAt(0, B, 26);
 For J := 1 To 19 Do  If B[J-1] <> Ord(Signature[J]) Then Fail(
 'Signature Creative Voice File manquante.');
 If B[19] <> $1A Then Fail('Signature VOC incorrecte.');
 Version := LE16(B,22); Check := LE16(B,24);
 If Check <> Word((LongInt(Version Xor $FFFF)+$1234) And $FFFF) Then Fail(
 'Controle de version VOC incorrect.');
 If (Version < $0100) Or (Version > $0114) Then Fail(
 'Version VOC non prise en charge (1.00..1.20).');
 Position := LE16(B,20);
 If (Position < 26) Or (Position >= InputSize) Then Fail(
 'Position initiale VOC incorrecte.');
 MakeTemporary;
 WriteLn('Preparation VOC avant lecture...');
 While Position < InputSize Do Begin
  Inc(Steps);
  If Steps > 1000000 Then Fail('Trop de blocs VOC developpes (limite 1000000).');
  ReadAt(Position, B, 1); Kind := B[0]; Inc(Position);
  If Extended And (Kind <> 1) Then Fail(
  'Le bloc VOC 8 doit preceder immediatement le bloc 1.');
  If Kind = 0 Then Begin
   Terminated := True; Break;
  End;
  ReadAt(Position, B, 3); Inc(Position, 3);
  Size := LongInt(B[0])+LongInt(B[1])*256+LongInt(B[2])*65536;
  If Size > InputSize-Position Then Fail('Bloc VOC tronque.');
  Next := Position + Size;
  Case Kind Of
  1:
  Begin
   If Size < 2 Then Fail('Bloc VOC 1 trop court.');
   ReadAt(Position, B, 2);
   If Extended Then Begin
    Rate := ExtendedRate; Channels := ExtendedChannels; Extended := False;
   End Else
   Begin
    If B[1] <> 0 Then Fail('Compression VOC non prise en charge: PCM requis.');
    Rate := 1000000 Div (256-Word(B[0])); Channels := 1;
   End;
   SetFormat(Rate, Channels); Bits := 8;
   ConvertData(Position+2, Size-2, Bits);
  End;
  2:
  Begin
   If Not HaveFormat Or (Bits = 0) Then Fail('Continuation VOC sans bloc audio initial.');
   ConvertData(Position, Size, Bits);
  End;
  3:
  Begin
   If Size <> 3 Then Fail('Taille de silence VOC incorrecte.');
   ReadAt(Position, B, 3);
   WriteSilence(LongInt(LE16(B,0))+1, B[2]);
  End;
  4: If Size <> 2 Then Fail('Taille de marqueur VOC incorrecte.');
  5:
  Begin
 { Texte descriptif ignore. } 
  End;
  6:
  Begin
   If Size <> 2 Then Fail('Taille de boucle VOC incorrecte.');
   If Depth = 8 Then Fail('Plus de 8 boucles VOC imbriquees.');
   ReadAt(Position, B, 2); Check := LE16(B,0);
   If Check = $FFFF Then Fail('Boucle VOC infinie non prise en charge.');
   Inc(Depth); Stack[Depth].Position := Next; Stack[Depth].Left := Check;
   Stack[Depth].Bits := Bits;
  End;
  7:
  Begin
   If (Size <> 0) Or (Depth = 0) Then Fail('Fin de boucle VOC incorrecte.');
   If Stack[Depth].Left > 0 Then Begin
    Dec(Stack[Depth].Left); Next := Stack[Depth].Position;
    Bits := Stack[Depth].Bits;
   End Else Dec(Depth);
  End;
  8:
  Begin
   If Size <> 4 Then Fail('Taille du bloc VOC 8 incorrecte.');
   ReadAt(Position, B, 4);
   If (B[2] <> 0) Or (B[3] > 1) Then Fail('Bloc VOC 8: PCM mono/stereo requis.');
   ExtendedChannels := B[3]+1;
   ExtendedRate := 256000000 Div ((65536-LongInt(LE16(B,0)))*ExtendedChannels);
   Extended := True;
  End;
  9:
  Begin
   If Size < 12 Then Fail('Bloc VOC 9 trop court.');
   ReadAt(Position, B, 12);
   Rate := LE32(B,0); Bits := B[4]; Channels := B[5]; Codec := LE16(B,6);
   If Not (((Bits = 8) And (Codec = 0)) Or ((Bits = 16) And (Codec = 4))) Then     Fail(
   'Bloc VOC 9: PCM 8 bits (codec 0) ou 16 bits (codec 4) requis.');
   SetFormat(Rate, Channels); ConvertData(Position+12, Size-12, Bits);
  End;
  Else Fail('Type de bloc VOC inconnu.');
 End;
 Position := Next;
End;
If Not Terminated Then Fail('Terminateur VOC manquant.');
If Depth <> 0 Then Fail('Boucle VOC non fermee.');
If Not HaveSound Or (Written = 0) Then Fail('Aucun son VOC.');
WriteLn(Header.Rate, ' Hz, ', Header.Channels, ' canal/canaux, sortie PCM.');
 {$I-}Close(InputFile); Code := IOResult;{$I+}
InputOpen := False;
If Code <> 0 Then Fail('Fermeture VOC impossible.');
 {$I-}Close(OutputFile); Code := IOResult;{$I+}
OutputOpen := False;
If Code <> 0 Then Fail('Fermeture temporaire impossible.');
 {$I-}Reset(OutputFile, 1); Code := IOResult;{$I+}
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
  Else If InputName <> '' Then Fail('Un seul fichier VOC attendu.')
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
