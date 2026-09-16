"""Optional reproducible static CJK font build; FontTools 4.60.1, OFL source."""
import argparse, hashlib, json
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools import subset

p=argparse.ArgumentParser()
p.add_argument('--source', required=True)
p.add_argument('--license', required=True)
p.add_argument('--output', required=True)
a=p.parse_args()
source=Path(a.source); output=Path(a.output); output.mkdir(parents=True,exist_ok=True)
font=instantiateVariableFont(TTFont(source), {'wght':400}, inplace=True)
unicodes=set(range(0x20,0x250))|set(range(0x2000,0x2070))|set(range(0x2190,0x2200))|set(range(0x3000,0x3100))|set(range(0x4e00,0xa000))|set(range(0xff00,0xfff0))
options=subset.Options(); options.name_IDs=['*']; options.name_legacy=True; options.name_languages=['*']
builder=subset.Subsetter(options=options); builder.populate(unicodes=unicodes); builder.subset(font)
for record in font['name'].names:
    if record.nameID in [1,3,4,6,16]:
        text='RegionLabSansSC-Regular' if record.nameID==6 else 'Region Lab Sans SC'
        record.string=text.encode(record.getEncoding(),errors='replace')
target=output/'RegionLabSansSC-Regular.ttf'; font.save(target)
(output/'OFL.txt').write_bytes(Path(a.license).read_bytes())
manifest={'source':'https://github.com/google/fonts/tree/main/ofl/notosanssc','source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'license':'OFL-1.1','fonttools':'4.60.1','weight':400,'ranges':['0020-024F','2000-206F','2190-21FF','3000-30FF','4E00-9FFF','FF00-FFEF'],'output_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'bytes':target.stat().st_size,'glyphs':len(font.getGlyphOrder())}
(output/'provenance.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
print(json.dumps(manifest))
