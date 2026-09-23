#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Loopback-only FTP protocol fixture. Never contacts a console; no credentials logged."""
import socket, socketserver, sys
from pathlib import Path
root=Path(sys.argv[1]).resolve()
class Handler(socketserver.StreamRequestHandler):
 def handle(self):
  self.cwd=root; self.data=None; self.rename=None
  def reply(s): self.wfile.write((s+'\r\n').encode());self.wfile.flush()
  def path(s):
   p=(root/s.lstrip('/') if s.startswith('/') else self.cwd/s).resolve()
   if p!=root and root not in p.parents: raise ValueError('outside fixture')
   return p
  reply('220 synthetic FTP test server')
  try:
   while raw:=self.rfile.readline(8192):
    if len(raw)>=8192:break
    command,_,arg=raw.decode().rstrip('\r\n').partition(' ');command=command.upper()
    mode=(root/'mode').read_text() if (root/'mode').exists() else ''
    if command=='USER':reply('331 Password required')
    elif command=='PASS':reply('230 Logged in')
    elif command=='SYST':reply('215 UNIX Type: L8')
    elif command=='PWD':reply('257 "/"')
    elif command=='TYPE':reply('200 Type set')
    elif command=='CWD':
     p=path(arg)
     if p.is_dir():self.cwd=p;reply('250 Directory changed')
     else:reply('550 Missing directory')
    elif command=='MKD':
     try:
      if mode=='deny':raise FileExistsError()
      path(arg).mkdir();reply('257 Directory created')
     except OSError:reply('550 Cannot create directory')
    elif command=='EPSV':
     self.data=socket.socket();self.data.bind(('127.0.0.1',0));self.data.listen(1);self.data.settimeout(10)
     reply('229 Entering Extended Passive Mode (|||%d|)'%self.data.getsockname()[1])
    elif command=='SIZE':
     p=path(arg)
     reply('213 %d'%p.stat().st_size if p.is_file() else '550 Missing file')
    elif command in ('STOR','RETR'):
     if command=='STOR' and mode=='storfail':
      connection,_=self.data.accept();self.data.close();self.data=None
      with connection:
       try:connection.recv(65536)
       except OSError:pass
      reply('426 Connection closed; transfer aborted')
      continue
     reply('150 Opening data connection');connection,_=self.data.accept();self.data.close();self.data=None
     with connection:
      if command=='STOR':
       with path(arg).open('xb') as f:
        while data:=connection.recv(65536):f.write(data)
      else:
       data=path(arg).read_bytes()
       if mode=='corrupt':data=bytes([data[0]^1])+data[1:]
       if mode=='truncate':data=data[:-1]
       if mode=='oversize':data+=b'extra'
       try:connection.sendall(data)
       except OSError:pass
     reply('226 Transfer complete')
    elif command=='RNFR':self.rename=path(arg);reply('350 Ready for destination')
    elif command=='RNTO':
     p=path(arg)
     if p.exists():reply('550 Exists')
     else:self.rename.rename(p);reply('250 Renamed')
    elif command=='QUIT':reply('221 Goodbye');break
    else:reply('502 Unsupported command')
  except (OSError,ValueError):pass
  finally:
   if self.data:self.data.close()
class Server(socketserver.ThreadingTCPServer):
 allow_reuse_address=True
 daemon_threads=True
with Server(('127.0.0.1',0),Handler) as server:
 print(server.server_address[1],flush=True);server.serve_forever()
