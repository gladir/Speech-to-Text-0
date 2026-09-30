{ @author: Sylvain Maltais (support@gladir.com)
 @created: 2026
 @version: 1.00
 @website(https://www.gladir.com/speech-to-text-0)
 @abstract(Target: Turbo Pascal 7/Free Pascal 3.2
 @description: Convertisseur procedural AIFF/AIFF-C PCM vers WAV PCM. }

Program AIFF2WAV;

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
 InputSize: LongInt;
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
 WriteLn('AIFF2WAV: ', MessageText); Cleanup; Halt(1);
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
 WriteLn(
 'AIFF2WAV - Cette commande permet de lancer le convertisseur AIFF/AIFF-C PCM vers WAV PCM.');
 WriteLn;
 WriteLn('Syntaxe: AIFF2WAV entree.aiff [sortie.wav]');
 WriteLn;
 WriteLn('AIFF/AIFF-C NONE ou sowt -> WAV PCM, mono/stereo, 8/16/24/32 bits.');
 WriteLn('Sans sortie explicite: meme chemin avec extension .wav.');
 WriteLn('Resolution et canaux conserves; frequence arrondie au hertz.');
 WriteLn('4000..192000 Hz, fichiers < 2 Go. Sortie existante refusee.');
 WriteLn('Aide: /? ou --help');
End;

Procedure ReadAt(Position: LongInt; Var Buffer; Count: Word);
Var
 Actual: Word;
 ErrorCode: Integer;
Begin
 If (Position < 0) Or (Position > InputSize) Then Fail('Position AIFF incorrecte.');
 If Count > InputSize - Position Then Fail('Fichier AIFF tronque.');
 {$I-}Seek(InputFile, Position); ErrorCode := IOResult;{$I+}
 If ErrorCode <> 0 Then Fail('Positionnement AIFF impossible.');
 {$I-}BlockRead(InputFile, Buffer, Count, Actual); ErrorCode := IOResult;{$I+}
 If (ErrorCode <> 0) Or (Actual <> Count) Then Fail('Lecture AIFF incomplete.');
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

Type
 THeaderBytes = Array[0..63] Of Byte;

Function BE16(Const B: THeaderBytes; Offset: Integer): Word;Begin
 BE16 := Word(B[Offset])*256+B[Offset+1];
End;

Function BE32(Const B: THeaderBytes; Offset: Integer): LongInt;Begin
 If B[Offset] >= 128 Then Fail('Valeur AIFF depassant 2 Go.');
 BE32 := LongInt(B[Offset])*16777216+LongInt(B[Offset+1])*65536+
 LongInt(B[Offset+2])*256+B[Offset+3];
End;

Function TagIs(Const B: THeaderBytes; Offset: Integer; Const Tag: String): Boolean;
Var
 J: Integer;
 Equal: Boolean;
Begin
 Equal := True;
 For J := 1 To 4 Do If B[Offset+J-1] <> Ord(Tag[J]) Then Equal := False;
 TagIs := Equal;
End;

Function ReadRate(Const B: THeaderBytes): LongInt;
Var
 Exponent, J: Integer;
 Value: Double;
Begin
 { COMM[8..17]: reel IEEE 80 bits big-endian, mantisse explicite.
   Decoder les octets evite une dependance au format Extended du compilateur. }
 If (B[8] And $80) <> 0 Then Fail('Frequence AIFF negative.');
 Exponent := BE16(B,8);
 If (Exponent < 16383+11) Or (Exponent > 16383+17) Or ((B[10] And $80) = 0) Then  Fail(
 'Frequence AIFF invalide (4000..192000 Hz attendus).');
 Dec(Exponent,16383);
 Value := 0;
 For J := 17 Downto 10 Do Value := (Value+B[J])/256;
 Value := Value*2;
 For J := 1 To Exponent Do Value := Value*2;
 If (Value < 4000) Or (Value > 192000) Then Fail('Frequence AIFF hors limites.');
 ReadRate := Round(Value);
End;

Procedure Convert;
Var
 B: THeaderBytes;
 Raw: Array[0..4095] Of Byte;
 Position, FormEnd, ChunkSize, DataStart, DataSize, FrameCount, Offset,
 Remaining, CountFrames: LongInt;
 Bits, BlockAlign, BytesPerSample, Code, J, K, C, OutCount: Integer;
 Value: LongInt;
 OldMode: Byte;
 HasFormat, HasData, HasVersion, CompressedForm, LittleEndian: Boolean;
Begin
 Assign(InputFile, InputName); OldMode := FileMode; FileMode := 0;
 {$I-}Reset(InputFile,1); Code := IOResult;{$I+}
 FileMode := OldMode;
 If Code <> 0 Then Fail('Ouverture AIFF impossible: '+InputName);
 InputOpen := True;
 {$I-}InputSize := FileSize(InputFile); Code := IOResult;{$I+}
 If (Code <> 0) Or (InputSize < 12) Then Fail('AIFF vide, trop grand ou tronque.');
 ReadAt(0,B,12);
 If Not TagIs(B,0,'FORM') Then Fail('Signature FORM manquante.');
 CompressedForm := TagIs(B,8,'AIFC');
 If Not CompressedForm And Not TagIs(B,8,'AIFF') Then Fail('Format AIFF ou AIFC requis.');
 FormEnd := BE32(B,4);
 If (FormEnd < 4) Or (FormEnd > InputSize-8) Then Fail('Taille FORM incorrecte.');
 Inc(FormEnd,8); Position := 12;
 HasFormat := False; HasData := False; HasVersion := False; LittleEndian := False;
 DataStart := 0; DataSize := 0; FrameCount := 0; Bits := 0;
 While Position < FormEnd Do Begin
  If FormEnd-Position < 8 Then Fail('Entete de bloc AIFF tronquee.');
  ReadAt(Position,B,8); ChunkSize := BE32(B,4); Inc(Position,8);
  If ChunkSize > FormEnd-Position Then Fail('Bloc AIFF tronque.');
  If TagIs(B,0,'COMM') Then Begin
   If HasFormat Then Fail('Plusieurs blocs COMM non pris en charge.');
   If ChunkSize < 18 Then Fail('Bloc COMM trop court.');
   ReadAt(Position,B,18);
   Header.Channels := BE16(B,0); FrameCount := BE32(B,2); Bits := BE16(B,6);
   Header.Rate := ReadRate(B);
   If Not (Header.Channels In [1,2]) Then Fail('AIFF mono ou stereo requis.');
   If Not (Bits In [8,16,24,32]) Then Fail('PCM AIFF attendu: 8/16/24/32 bits.');
   If CompressedForm Then Begin
    If ChunkSize < 24 Then Fail('Bloc COMM AIFC trop court.');
    ReadAt(Position+18,B,5);
    LittleEndian := TagIs(B,0,'sowt');
    If Not LittleEndian And Not TagIs(B,0,'NONE') Then Fail(
    'Codec AIFC non pris en charge: NONE ou sowt requis.');
    If 23+Word(B[4])+((1+Word(B[4])) Mod 2) > ChunkSize Then Fail(
    'Nom de compression AIFC tronque.');
   End;
   HasFormat := True;
  End
  Else If TagIs(B,0,'SSND') Then Begin
   If HasData Then Fail('Plusieurs blocs SSND non pris en charge.');
   If ChunkSize < 8 Then Fail('Bloc SSND trop court.');
   ReadAt(Position,B,8); Offset := BE32(B,0);
   If Offset > ChunkSize-8 Then Fail('Offset SSND hors du bloc.');
   { blockSize indique l'alignement physique; les trames restent contigues. }
   DataStart := Position+8+Offset; DataSize := ChunkSize-8-Offset; HasData := True;
  End
  Else If TagIs(B,0,'FVER') And CompressedForm Then Begin
   If HasVersion Or (ChunkSize <> 4) Then Fail('Bloc FVER incorrect.');
   ReadAt(Position,B,4);
   If (B[0] <> $A2) Or (B[1] <> $80) Or (B[2] <> $51) Or (B[3] <> $40) Then Fail(
   'Version AIFC non prise en charge.');
   HasVersion := True;
  End;
  Inc(Position,ChunkSize);
  If Odd(ChunkSize) Then Begin
   If Position >= FormEnd Then Fail('Octet de bourrage AIFF manquant.');
   Inc(Position);
  End;
 End;
 If Not HasFormat Or Not HasData Then Fail('Bloc COMM ou SSND manquant.');
 If CompressedForm And Not HasVersion Then Fail('Bloc FVER AIFC manquant.');
 BytesPerSample := Bits Div 8; BlockAlign := Header.Channels*BytesPerSample;
 If (FrameCount = 0) Or (FrameCount > DataSize Div BlockAlign) Then Fail(
 'Trames AIFF vides ou tronquees.');
 Remaining := FrameCount*BlockAlign; Position := DataStart;
 If Remaining > 2147483600 Then Fail('Sortie WAV depassant 2 Go.');
 { Creer la sortie seulement apres validation de tous les blocs AIFF. }
 If Exists(OutputName) Then Fail('Le fichier de sortie existe deja: '+OutputName);
 Assign(OutputFile,OutputName);
 {$I-}Rewrite(OutputFile,1); Code := IOResult;{$I+}
 If Code <> 0 Then Fail('Creation WAV impossible: '+OutputName);
 OutputOpen := True; OutputCreated := True;
 WriteWaveHeader(Remaining,Bits);
 While Remaining > 0 Do Begin
  CountFrames := Remaining Div BlockAlign;
  If CountFrames > 512 Then CountFrames := 512;
  OutCount := CountFrames*BlockAlign;
  ReadAt(Position,Raw,OutCount);
  If Bits = 8 Then
  For J := 0 To OutCount-1 Do Raw[J] := Raw[J] Xor $80
  Else If Not LittleEndian Then Begin
   K := 0;
   While K < OutCount Do Begin
    For C := 0 To BytesPerSample Div 2-1 Do Begin
     Value := Raw[K+C];
     Raw[K+C] := Raw[K+BytesPerSample-1-C];
     Raw[K+BytesPerSample-1-C] := Value;
    End;
    Inc(K,BytesPerSample);
   End;
  End;
  WriteBytes(Raw,OutCount);
  Inc(Position,OutCount); Dec(Remaining,OutCount);
 End;
 If Odd(FrameCount*BlockAlign) Then Begin
  Raw[0] := 0; WriteBytes(Raw,1);
 End;
 {$I-}Close(InputFile); Code := IOResult;{$I+} InputOpen := False;
 If Code <> 0 Then Fail('Fermeture AIFF impossible.');
 {$I-}Close(OutputFile); Code := IOResult;{$I+} OutputOpen := False;
 If Code <> 0 Then Fail('Fermeture WAV impossible.');
 OutputCreated := False;
 WriteLn('WAV cree: ',OutputName);
 WriteLn(Header.Rate,' Hz, ',Header.Channels,' canal/canaux, PCM ',Bits,' bits, ',
 FrameCount,' trames.');
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
