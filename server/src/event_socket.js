import { WebSocketServer, WebSocket } from 'ws';

export class EventSocket {
  constructor(server, authenticate) {
    this.wss = new WebSocketServer({ noServer: true, maxPayload: 1024 });
    server.on('upgrade', (request, socket, head) => {
      try {
        if (new URL(request.url, 'http://localhost').pathname !== '/events') throw new Error('path');
        const owner = authenticate(request);
        if ([...this.wss.clients].filter(c => c.owner === owner).length >= 4) throw new Error('limit');
        this.wss.handleUpgrade(request, socket, head, ws => {
          ws.owner = owner; ws.alive = true;
          ws.on('error', () => {});
          ws.on('pong', () => { ws.alive = true; });
          ws.send(JSON.stringify({ type: 'events.ready' }));
        });
      } catch { socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); }
    });
    this.timer = setInterval(() => {
      for (const ws of this.wss.clients) {
        if (!ws.alive) ws.terminate();
        else { ws.alive = false; ws.ping(); }
      }
    }, 15000);
    this.timer.unref();
  }
  publish(owner, event) {
    const text = JSON.stringify(event);
    for (const ws of this.wss.clients) {
      if (ws.owner !== owner || ws.readyState !== WebSocket.OPEN) continue;
      if (ws.bufferedAmount > 256000) ws.terminate(); else ws.send(text);
    }
  }
  close() { clearInterval(this.timer); for (const ws of this.wss.clients) ws.terminate(); this.wss.close(); }
}
