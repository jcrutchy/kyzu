unit kyzu_dispatch;

// Routes one parsed incoming bus line (a game.cmd.* topic) to the
// matching kyzu_commands Handle* procedure. The only thing kyzu.lpr's
// stdin reader thread calls directly.

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser,
  kyzu_state, kyzu_commands;

procedure DispatchIncoming(const ALine: string);

implementation

procedure DispatchIncoming(const ALine: string);
var
  Data: TJSONData;
  Obj: TJSONObject;
  Topic: string;
  PayloadData: TJSONData;
  ParsedPayload: TJSONData;
begin
  ParsedPayload := nil;
  try
    Data := GetJSON(ALine);
  except
    Exit; // not valid JSON - ignore rather than crash the loop
  end;

  try
    if Data.JSONType <> jtObject then Exit;
    Obj := TJSONObject(Data);
    Topic := Obj.Get('topic', '');
    PayloadData := Obj.Find('payload');

    // A payload sent as a JSON STRING (rather than a nested object) is
    // accepted too, not just silently dropped. This server's OWN
    // outgoing events use exactly that shape
    // ({"topic":"...","payload":"{\"...\":...}"}), so a client that
    // mirrors that convention when sending commands would otherwise
    // have every command go nowhere with nothing to explain why.
    if Assigned(PayloadData) and (PayloadData.JSONType = jtString) then
    begin
      try
        ParsedPayload := GetJSON(PayloadData.AsString);
        if ParsedPayload.JSONType = jtObject then
          PayloadData := ParsedPayload;
      except
        // Not parseable as JSON after all - leave PayloadData as the
        // original string; every Handle* below already requires
        // jtObject and will just no-op on it, same as today.
      end;
    end;

    if Topic = 'game.cmd.ping' then
      SendLine('{"topic":"game.event.pong","payload":"{}"}')
    else if Topic = 'game.cmd.spawn' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleSpawn(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.despawn' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleDespawn(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.move' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleMove(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.collect' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleCollect(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.list_nodes' then
      HandleListNodes
    else if Topic = 'game.cmd.get_ledger' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleGetLedger(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.found_city' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleFoundCity(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.build_road' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleBuildRoad(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.list_cities' then
      HandleListCities
    else if Topic = 'game.cmd.list_roads' then
      HandleListRoads
    else if Topic = 'game.cmd.get_development' then
      HandleGetDevelopment
    else if Topic = 'game.cmd.attack' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleAttack(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.list_tech_defs' then
      HandleListTechDefs
    else if Topic = 'game.cmd.get_tech' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleGetTech(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.start_research' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleStartResearch(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.get_diplomacy' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleGetDiplomacy(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.declare_war' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleDeclareWar(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.propose_alliance' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleProposeAlliance(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.accept_alliance' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleAcceptAlliance(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.break_alliance' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleBreakAlliance(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.propose_peace' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleProposePeace(TJSONObject(PayloadData));
    end
    else if Topic = 'game.cmd.accept_peace' then
    begin
      if Assigned(PayloadData) and (PayloadData.JSONType = jtObject) then
        HandleAcceptPeace(TJSONObject(PayloadData));
    end;
    // add more topic handlers here as the command set grows
  finally
    Data.Free;
    if Assigned(ParsedPayload) then ParsedPayload.Free;
  end;
end;

end.
