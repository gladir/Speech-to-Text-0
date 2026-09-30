{ @author: Sylvain Maltais (support@gladir.com)
 @created: 2026
 @version: 1.00
 @website(https://www.gladir.com/speech-to-text-0)
 @abstract(Target: Turbo Pascal 7/Free Pascal 3.2
 @description: Convertisseur Creative VOC PCM vers WAV PCM16, sans outil externe. }

Program VOC2WAV;

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
 WriteLn('VOC2WAV: ', MessageText); Cleanup; Halt(1);
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
 WriteLn('VOC2WAV - Cette commande permet de lancer le convertisseur Creative VOC PCM vers WAV PCM16');
 WriteLn;
 WriteLn('Syntaxe : VOC2WAV entree.voc [sortie.wav]');
 WriteLn;
 WriteLn('Creative VOC PCM 8/16 bits -> WAV PCM16, mono/stereo.');
 WriteLn('Continuations, silences et boucles internes finies pris en charge.');
 WriteLn('ADPCM, A-law, mu-law et changements de frequence/canaux refuses.');
 WriteLn('Sans sortie explicite: meme chemin avec extension .wav.');
 WriteLn('Fichiers < 2 Go; aucune sortie existante ecrasee. Aide: /? ou --help');
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
  Header.Rate := Rate; Header.Channels := Channels;
  HaveFormat := True;
 End;
End;

Procedure SubmitPCM(Count: Word);Begin
 If Written > 2147483600 - Count Then Fail('Sortie WAV depassant 2 Go.');
 WriteBytes(PCM,Count); Inc(Written,Count);
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
  SubmitPCM(Count * Header.Channels * 2); Dec(Frames, Count);
 End;
 HaveSound := True;
End;

Procedure Convert;
Const
 { Une constante chaine non typee ne peut pas etre indexee sous Turbo Pascal. }
 Signature: String[19] = 'Creative Voice File';
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
 CreateOutput;
 WriteLn('Conversion VOC vers WAV PCM16...');
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
{$I-}Seek(OutputFile,0); Code := IOResult;{$I+}
If Code <> 0 Then Fail('Positionnement entete WAV impossible.');
WriteWaveHeader(Written,16);
{$I-}Close(InputFile); Code := IOResult;{$I+} InputOpen := False;
If Code <> 0 Then Fail('Fermeture VOC impossible.');
{$I-}Close(OutputFile); Code := IOResult;{$I+} OutputOpen := False;
If Code <> 0 Then Fail('Fermeture WAV impossible.');
OutputCreated := False;
WriteLn('WAV cree: ',OutputName);
WriteLn(Header.Rate,' Hz, ',Header.Channels,' canal/canaux, PCM 16 bits, ',Written Div (
Header.Channels*2),' trames.');
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
