program kyzu_server;
{$mode objfpc}{$H+}

uses
  SysUtils, Classes, SyncObjs, fpjson, jsonparser;

var
  OutputLock: TCriticalSection;

procedure SendLine(const ALine: string);
begin
  OutputLock.Enter;
  try
    WriteLn(ALine);
    Flush(Output);
  finally
    OutputLock.Leave;
  end;
end;

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
      SendLine('{"topic":"game.event.pong","payload":"{}"}');
    // add more topic handlers here as the command set grows
  finally
    Data.Free;
  end;
end;

type
  // Plain blocking ReadLn on its own thread - same idiom as VDRX's own
  // vdrx_stdin.pas. Deliberately not polling IsInputAvailable on the main
  // thread: that doesn't mix reliably with FPC's buffered Text I/O on the
  // same handle (PeekNamedPipe only sees the OS-level pipe buffer, not
  // bytes the runtime may already have pulled into its own internal
  // buffer), so input can silently go undetected.
  TStdinReaderThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TStdinReaderThread.Execute;
var
  Line: string;
begin
  WriteLn(StdErr, 'reader thread started, waiting for input...');
  while not Terminated do
  begin
    if Eof(Input) then Break; // stdin closed - bridge is gone, VDRX will restart us
    ReadLn(Line);
    WriteLn(StdErr, 'got line: ' + Line); // <-- new
    if Line <> '' then
      DispatchIncoming(Line);
  end;
  WriteLn(StdErr, 'reader thread exiting'); // <-- new
end;

var
  ReaderThread: TStdinReaderThread;
  Tick: Int64;
begin
  Tick := 0;
  OutputLock := TCriticalSection.Create;
  ReaderThread := TStdinReaderThread.Create(False); // starts immediately

  while True do
  begin
    Inc(Tick);
    SendLine(Format('{"topic":"game.tick","payload":"{\"tick\":%d}"}', [Tick]));
    Sleep(50); // ~20 ticks/sec target loop pacing
  end;
end.
