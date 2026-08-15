program kyzu_server;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, fpjson, jsonparser
  {$IFDEF WINDOWS} , Windows {$ELSE} , BaseUnix, Termio {$ENDIF};

// Helper function to check if bytes are waiting on standard input without blocking
function IsInputAvailable: Boolean;
{$IFDEF WINDOWS}
var
  H: THandle;
  Events: DWORD;
  NumRead: DWORD;
  InputRecord: TInputRecord;
  FileType: DWORD;
begin
  Result := False;
  H := GetStdHandle(STD_INPUT_HANDLE);
  FileType := GetFileType(H);

  if FileType = FILE_TYPE_PIPE then
  begin
    PeekNamedPipe(H, nil, 0, nil, @Events, nil);
    Result := (Events > 0);
  end
  else if FileType = FILE_TYPE_CHAR then
  begin
    GetNumberOfConsoleInputEvents(H, Events);
    if Events > 0 then
    begin
      // Explicitly cast to PInputRecord to satisfy strict type-checking on arg no. 2
      PeekConsoleInput(H, PInputRecord(@InputRecord)^, 1, NumRead);
      Result := (NumRead > 0) and (InputRecord.EventType = KEY_EVENT) and (InputRecord.Event.KeyEvent.bKeyDown);
    end;
  end;
end;
{$ELSE}
var
  fds:ofd_set;
  timeout:timeval;
  res: cint;
begin
  // Standard input file descriptor is 0
  fpFD_ZERO(fds);
  fpFD_SET(0, fds);

  timeout.tv_sec := 0;
  timeout.tv_usec := 0; // Return immediately (polling mode)

  res := fpSelect(1, @fds, nil, nil, @timeout);
  Result := (res > 0) and fpFD_ISSET(0, fds);
end;
{$ENDIF}

procedure DispatchIncoming(const ALine: string);
var
  Data: TJSONData;
  Obj: TJSONObject;
  Topic: string;
begin
  try
    Data := GetJSON(ALine);
  except
    Exit; // not valid JSON - ignore rather than crash the loop
  end;
  try
    if Data.JSONType <> jtObject then Exit;
    Obj := TJSONObject(Data);
    Topic := Obj.Get('topic', '');

    if Topic = 'game.cmd.ping' then
    begin
      WriteLn('{"topic":"game.event.pong","payload":"{}"}');
      Flush(Output);
    end;
    // add more topic handlers here as the command set grows
  finally
    Data.Free;
  end;
end;

var
  Line: string;
  Tick: Int64;
begin
  Tick := 0;

  // Optional: Disable input buffering if dealing with line-oriented pipes
  {$IFNDEF WINDOWS}
  // Ensures raw character streaming if necessary
  {$ENDIF}

  while True do
  begin
    if IsInputAvailable then
    begin
      if Eof(Input) then Break;
      ReadLn(Line);
      if Line <> '' then
        DispatchIncoming(Line);
    end;

    Inc(Tick);
    WriteLn(Format('{"topic":"game.tick","payload":"{\"tick\":%d}"}', [Tick]));
    Flush(Output); // Critical - prevents pipe stalling on the bridge side

    Sleep(50);     // ~20 ticks/sec target loop pacing
  end;
end.
