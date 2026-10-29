"""Bounded MessagePack subset used by the plugin protocol; no external Python packages."""
import struct

def pack(value):
    if value is None: return b'\xc0'
    if value is True: return b'\xc3'
    if value is False: return b'\xc2'
    if isinstance(value, int): return b'\xd3' + struct.pack('>q', value)
    if isinstance(value, float): return b'\xcb' + struct.pack('>d', value)
    if isinstance(value, str):
        text = value.encode('utf8'); return b'\xdb' + struct.pack('>I', len(text)) + text
    if isinstance(value, (list, tuple)): return b'\xdd' + struct.pack('>I', len(value)) + b''.join(map(pack, value))
    if isinstance(value, dict): return b'\xdf' + struct.pack('>I', len(value)) + b''.join(pack(k)+pack(v) for k,v in value.items())
    raise TypeError(type(value))

def unpack(data):
    offset = 0
    def take(n):
        nonlocal offset
        if offset+n>len(data): raise ValueError('truncated packet')
        v=data[offset:offset+n];offset+=n;return v
    def number(fmt):return struct.unpack(fmt,take(struct.calcsize(fmt)))[0]
    def read(depth=0):
        if depth>24:raise ValueError('depth exceeded')
        t=take(1)[0]
        if t<=0x7f:return t
        if t>=0xe0:return t-256
        if t==0xc0:return None
        if t==0xc2:return False
        if t==0xc3:return True
        if t in (0xca,0xcb):return number('>f' if t==0xca else '>d')
        ints={0xcc:'>B',0xcd:'>H',0xce:'>I',0xcf:'>Q',0xd0:'>b',0xd1:'>h',0xd2:'>i',0xd3:'>q'}
        if t in ints:return number(ints[t])
        if 0xa0<=t<=0xbf:return take(t&31).decode('utf8')
        if t in (0xd9,0xda,0xdb):return take(number({0xd9:'>B',0xda:'>H',0xdb:'>I'}[t])).decode('utf8')
        if 0x90<=t<=0x9f:n=t&15;return [read(depth+1) for _ in range(n)]
        if t in (0xdc,0xdd):return [read(depth+1) for _ in range(number('>H' if t==0xdc else '>I'))]
        if 0x80<=t<=0x8f:return {read(depth+1):read(depth+1) for _ in range(t&15)}
        if t in (0xde,0xdf):return {read(depth+1):read(depth+1) for _ in range(number('>H' if t==0xde else '>I'))}
        raise ValueError(f'unsupported MessagePack {t:x}')
    value=read()
    if offset!=len(data):raise ValueError('trailing bytes')
    return value

def receive(stream):
    h=stream.read(4)
    if len(h)!=4:raise EOFError('worker exited')
    n=struct.unpack('<I',h)[0]
    if n>2*1024*1024:raise ValueError('packet limit')
    return unpack(stream.read(n))

def send(stream,value):
    data=pack(value);stream.write(struct.pack('<I',len(data))+data);stream.flush()
