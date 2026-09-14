"""Generate original CC0 GLB fixtures. Python 3 stdlib; not a runtime dependency."""
import json
import math
import struct
import zlib
from pathlib import Path


def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + bytes([166 + (y % 4) * 9, 126 + (y % 4) * 7, 81]) * 16 for y in range(16))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', 16, 16, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


class Asset:
    def __init__(self):
        self.data = bytearray()
        self.doc = dict(asset=dict(version='2.0', generator='Region Lab original fixtures'), scene=0,
                        scenes=[dict(nodes=[])], nodes=[], meshes=[], accessors=[], bufferViews=[],
                        materials=[dict(pbrMetallicRoughness=dict(baseColorFactor=c, metallicFactor=0, roughnessFactor=.8))
                                   for c in ([.68,.61,.49,1], [.22,.29,.30,1], [.28,.42,.19,1], [.40,.27,.16,1])])
        image = self.view(png())
        self.doc.update(images=[dict(bufferView=image, mimeType='image/png')], textures=[dict(source=0)])
        self.doc['materials'][3]['pbrMetallicRoughness']['baseColorTexture'] = dict(index=0)

    def view(self, data):
        self.data.extend(b'\0' * (-len(self.data) % 4))
        index = len(self.doc['bufferViews'])
        self.doc['bufferViews'].append(dict(buffer=0, byteOffset=len(self.data), byteLength=len(data)))
        self.data.extend(data)
        return index

    def accessor(self, values, kind):
        index = len(self.doc['accessors'])
        self.doc['accessors'].append(dict(bufferView=self.view(struct.pack('<' + 'f' * sum(map(len, values)), *(x for v in values for x in v))), componentType=5126, count=len(values), type=kind))
        return index

    def mesh(self, name, faces, material):
        vertices, normals, uv = [], [], []
        for face in faces:
            a,b,c = face[:3]
            u = [b[i]-a[i] for i in range(3)]; v = [c[i]-a[i] for i in range(3)]
            n = [u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]]
            length = math.sqrt(sum(x*x for x in n)); n = [x/length for x in n]
            for tri in ((0,1,2),(0,2,3)) if len(face)==4 else ((0,1,2),):
                for i in tri:
                    vertices.append(face[i]); normals.append(n); uv.append(((0,0),(1,0),(1,1),(0,1))[i])
        attrs = dict(POSITION=self.accessor(vertices,'VEC3'), NORMAL=self.accessor(normals,'VEC3'), TEXCOORD_0=self.accessor(uv,'VEC2'))
        self.doc['nodes'].append(dict(name=name, mesh=len(self.doc['meshes'])))
        self.doc['scenes'][0]['nodes'].append(len(self.doc['nodes'])-1)
        self.doc['meshes'].append(dict(primitives=[dict(attributes=attrs, material=material)]))

    def box(self, name, p, size, material=0):
        x,y,z=p; a,b,c=[v/2 for v in size]
        v=[(x+i*a,y+j*b,z+k*c) for i,j,k in ((-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1))]
        self.mesh(name, [[v[i] for i in f] for f in ((3,2,1,0),(4,5,6,7),(0,4,7,3),(5,1,2,6),(7,6,2,3),(0,1,5,4))],material)

    def save(self,path):
        self.doc['buffers']=[dict(byteLength=len(self.data))]
        j=json.dumps(self.doc,separators=(',',':')).encode(); j+=b' '*(-len(j)%4)
        b=bytes(self.data); b+=b'\0'*(-len(b)%4)
        path.write_bytes(struct.pack('<5I',0x46546c67,2,28+len(j)+len(b),len(j),0x4e4f534a)+j+struct.pack('<2I',len(b),0x004e4942)+b)


def generate(destination):
    destination.mkdir(parents=True,exist_ok=True)
    building=Asset()
    parts=[('Floor',(0,.1,0),(10,.2,8),0),('West',(-4.85,1.8,0),(.3,3.4,8),0),
           ('East',(4.85,1.8,0),(.3,3.4,8),0),('Back',(0,1.8,-3.85),(10,3.4,.3),0),
           ('FrontLeft',(-3.1,1.8,3.85),(3.8,3.4,.3),0),('FrontRight',(3.1,1.8,3.85),(3.8,3.4,.3),0),
           ('Lintel',(0,3.1,3.85),(2.4,.8,.3),0),('Roof',(0,3.65,0),(10.6,.3,8.6),1)]
    for name,p,size,m in parts:
        building.box(name,p,size,m); building.box('COL_'+name,p,size,m)
    building.save(destination/'pavilion.glb')
    bench=Asset()
    for name,p,size,m in [('Seat',(0,.55,0),(2.4,.15,.65),3),('Back',(0,.95,-.27),(2.4,.65,.12),3),('LegL',(-.85,.25,0),(.12,.5,.55),1),('LegR',(.85,.25,0),(.12,.5,.55),1)]:
        bench.box(name,p,size,m)
    bench.save(destination/'bench.glb')
    tree=Asset(); tree.box('Trunk',(0,1.5,0),(.4,3,.4),3); tree.box('COL_Trunk',(0,1.5,0),(.4,3,.4),0)
    ring=[(2*math.cos(i*math.tau/10),3,2*math.sin(i*math.tau/10)) for i in range(10)]
    faces=[]
    for i in range(10):
        a,b=ring[i],ring[(i+1)%10]
        faces.extend([(a,(0,6,0),b),(b,(0,2,0),a)])
    tree.mesh('Crown',faces,2); tree.save(destination/'tree.glb')
    for path in sorted(destination.glob('*.glb')):
        print(f'{path.name}: {path.stat().st_size} bytes')


if __name__=='__main__':
    generate(Path(__file__).resolve().parents[1]/'fixtures'/'meshes')
