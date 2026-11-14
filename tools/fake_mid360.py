# Fake Livox Mid-360 control port (UDP 56100) for testing the app's network settings screen.
# Answers 0x0101 (inquire), 0x0100 (configure) and 0x0200 (reboot) per the Mid-360 protocol, checking
# crc16 / crc32 of every request.  Usage: python3 tools/fake_mid360.py [bind_ip=127.0.0.1]
import socket, struct, zlib, sys
def crc16(b):
    c=0xFFFF
    for x in b:
        c^=x<<8
        for _ in range(8): c=((c<<1)^0x1021)&0xFFFF if c&0x8000 else (c<<1)&0xFFFF
    return c
cfg={4:bytes([192,168,1,123,255,255,255,0,192,168,1,1]),6:bytes([192,168,1,50])+struct.pack('<HH',56301,56300)}
log=[]
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind((sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1', 56100))
def ack(seq,cmd,data):
    h=struct.pack('<BBHIHBB6s',0xAA,0,24+len(data),seq,cmd,1,1,b'\0'*6)
    h+=struct.pack('<H',crc16(h))+struct.pack('<I',zlib.crc32(data) if data else 0)
    return h+data
while True:
    p,a=s.recvfrom(2000)
    sof,ver,ln,seq,cmd,ct,st=struct.unpack_from('<BBHIHBB',p)
    assert sof==0xAA and ln==len(p) and ct==0 and st==0, 'bad header'
    assert struct.unpack_from('<H',p,18)[0]==crc16(p[:18]), 'crc16'
    d=p[24:]
    assert struct.unpack_from('<I',p,20)[0]==(zlib.crc32(d) if d else 0), 'crc32'
    if cmd==0x0101:
        n=struct.unpack_from('<H',d)[0]; keys=struct.unpack_from('<%dH'%n,d,4)
        out=struct.pack('<BH',0,len(keys))+b''.join(struct.pack('<HH',k,len(cfg[k]))+cfg[k] for k in keys)
        s.sendto(ack(seq,cmd,out),a); print('GET',[hex(k) for k in keys],flush=True)
    elif cmd==0x0100:
        n=struct.unpack_from('<H',d)[0]; o=4
        for _ in range(n):
            k,l=struct.unpack_from('<HH',d,o); v=d[o+4:o+4+l]; o+=4+l
            if k==4: print('SET lidar_ipcfg', '.'.join(map(str,v[:4])),'/','.'.join(map(str,v[4:8])),'gw','.'.join(map(str,v[8:12])),flush=True)
            else: print('SET key',hex(k),'.'.join(map(str,v[:4])),'dst',struct.unpack('<H',v[4:6])[0],'src',struct.unpack('<H',v[6:8])[0],flush=True)
            cfg[k]=v
        assert o==len(d)
        s.sendto(ack(seq,cmd,struct.pack('<BH',0,0)),a)
    elif cmd==0x0200:
        print('REBOOT timeout',struct.unpack('<H',d)[0],'ms from port',a[1],flush=True); s.sendto(ack(seq,cmd,b'\0'),a)
