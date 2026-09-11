// vdrx.js — shared VDRX message-bus WebSocket client for kyzu's web UIs.
//
// Handles the bus mechanics every client needs (connect, sys.auth handshake,
// subscribe, publish, JSON payload parsing, reconnect-with-backoff) so each
// page only has to deal with its own game-domain rendering. Deliberately
// stays out of game-domain concerns (units/cities/etc) - each client keeps
// rebuilding its own view from the event stream, same as before.
//
// Usage:
//   const bus = new VdrxBus({
//     onStatus:  (state, detail) => { ... },       // 'connecting'|'up'|'error'|'disconnected'
//     onAuthed:  (msg) => { ... },                  // fires once per connection, after subscribe is sent
//     onMessage: (topic, payload, source, raw) => { ... }
//   });
//   bus.connect();
//   bus.publish('game.cmd.ping', {});

(function (global) {
  function VdrxBus(opts) {
    opts = opts || {};
    this.url = opts.url || ('ws://' + location.hostname + ':8082');
    this.token = opts.token || 'dev';
    this.filter = opts.filter || 'game.>';
    this.autoSubscribe = opts.autoSubscribe !== false;
    this.autoReconnect = opts.autoReconnect !== false;
    this.reconnectDelayMs = opts.reconnectDelayMs || 2000;

    this.onStatus = opts.onStatus || function () {};
    this.onAuthed = opts.onAuthed || function () {};
    this.onMessage = opts.onMessage || function () {};

    this.ws = null;
    this.authed = false;
    this._closedByUser = false;
  }

  VdrxBus.prototype.connect = function () {
    this._closedByUser = false;
    this.authed = false;
    this.onStatus('connecting');

    const ws = new WebSocket(this.url);
    this.ws = ws;

    ws.onopen = () => {
      ws.send(JSON.stringify({ method: 'sys.auth', token: this.token }));
    };

    ws.onmessage = (evt) => {
      let msg;
      try { msg = JSON.parse(evt.data); }
      catch (e) { return; }

      if (!this.authed) {
        // Only an explicit auth.ok counts as authed - don't assume the
        // first frame in is necessarily the ack.
        if (msg.event === 'auth.ok') {
          this.authed = true;
          this.onStatus('up', msg.source);
          if (this.autoSubscribe) this.subscribe(this.filter);
          this.onAuthed(msg);
        }
        return;
      }

      if (msg.topic !== undefined) {
        this.onMessage(msg.topic, VdrxBus.payloadOf(msg), msg.source, msg);
      }
    };

    ws.onerror = () => { this.onStatus('error'); };

    ws.onclose = () => {
      this.authed = false;
      this.onStatus('disconnected');
      if (this.autoReconnect && !this._closedByUser) {
        setTimeout(() => this.connect(), this.reconnectDelayMs);
      }
    };
  };

  VdrxBus.prototype.publish = function (topic, payload) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    this.ws.send(JSON.stringify({ method: 'publish', topic: topic, payload: payload }));
    return true;
  };

  VdrxBus.prototype.subscribe = function (filter) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    this.ws.send(JSON.stringify({ method: 'subscribe', filter: filter }));
    return true;
  };

  // Closes the socket and, unlike a network drop, does not auto-reconnect -
  // call connect() again (e.g. via a "reconnect" button) to resume.
  VdrxBus.prototype.close = function () {
    this._closedByUser = true;
    if (this.ws) { try { this.ws.close(); } catch (e) {} }
  };

  // Forces a fresh connection (e.g. a manual "reconnect" button); onclose
  // handles the actual reconnect since autoReconnect stays in effect.
  VdrxBus.prototype.reconnect = function () {
    if (this.ws) { try { this.ws.close(); } catch (e) {} }
    else { this.connect(); }
  };

  // Parses a bus message's payload, which may already be an object or may
  // be a JSON-encoded string. Returns null on unparseable payloads.
  VdrxBus.payloadOf = function (msg) {
    let p = msg.payload;
    if (typeof p === 'string') {
      try { p = JSON.parse(p); } catch (e) { return null; }
    }
    return p;
  };

  global.VdrxBus = VdrxBus;
})(window);
