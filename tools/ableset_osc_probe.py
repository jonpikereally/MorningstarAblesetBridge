import socket, struct, time
def pad(b): b+=b'\0'; return b+b'\0'*((4-len(b)%4)%4)
def msg(addr,*args):
    tags=','; data=b''
    for a in args:
        if isinstance(a,int): tags+='i'; data+=struct.pack('>i',a)
        else: tags+='s'; data+=pad(a.encode())
    return pad(addr.encode())+pad(tags.encode())+data
def parse(b):
    i=b.index(b'\0'); addr=b[:i].decode(); j=(i//4+1)*4
    k=b.index(b'\0',j); tags=b[j+1:k].decode(); j=(k//4+1)*4; out=[]
    for t in tags:
        if t in 'if': out.append(struct.unpack('>'+t,b[j:j+4])[0]); j+=4
        elif t=='s': k=b.index(b'\0',j); out.append(b[j:k].decode('utf8','replace')); j=(k//4+1)*4
        elif t in 'TF': out.append(t=='T')
    return addr,out
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('127.0.0.1',39071)); s.settimeout(0.5)
s.sendto(msg('/subscribe','127.0.0.1',39071,'probe'),('127.0.0.1',39051))
s.sendto(msg('/getValues'),('127.0.0.1',39051))
end=time.time()+4; seen={}
while time.time()<end:
    try: d,_=s.recvfrom(65536)
    except socket.timeout: continue
    if d.startswith(b'#bundle'): print('bundle'); continue
    a,v=parse(d); seen[a]=v
for a in sorted(seen):
    if a.startswith(('/global','/setlist','/heartbeat')): print(a, str(seen[a])[:100])
print(len(seen),'addresses')
s.sendto(msg('/unsubscribe'),('127.0.0.1',39051))
