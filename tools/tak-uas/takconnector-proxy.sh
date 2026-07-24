#!/bin/bash
# host proxy for the deliberately-internal takconnector: host:7089 -> container:7089
# (mantod georef + mav_cot_bridge on minipc need it; container IP re-resolved each start)
while true; do
  IP=$(docker inspect takconnector --format "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}" 2>/dev/null | awk "{print \$1}")
  if [ -n "$IP" ]; then
    if command -v socat >/dev/null; then
      socat TCP-LISTEN:7089,bind=0.0.0.0,fork,reuseaddr TCP:$IP:7089
    else
      python3 -c "
import socket,threading
def pipe(a,b):
    try:
        while True:
            d=a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError: pass
    finally:
        try: a.close(); b.close()
        except OSError: pass
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind((\"0.0.0.0\",7089)); s.listen(16)
while True:
    c,_=s.accept()
    try: u=socket.create_connection((\"$IP\",7089),5)
    except OSError: c.close(); continue
    threading.Thread(target=pipe,args=(c,u),daemon=True).start()
    threading.Thread(target=pipe,args=(u,c),daemon=True).start()
"
    fi
  fi
  sleep 3
done
