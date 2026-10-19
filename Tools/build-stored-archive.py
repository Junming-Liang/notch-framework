#!/usr/bin/env python3
"""Build a v1 STORED archive from an explicitly trusted local developer fixture."""
import argparse,json,pathlib,stat,zipfile
p=argparse.ArgumentParser();p.add_argument('fixture',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);a=p.parse_args()
m=json.loads((a.fixture/'manifest.json').read_text());files=['manifest.json']+m['files']
with zipfile.ZipFile(a.output,'x',compression=zipfile.ZIP_STORED) as z:
    for name in files:
        parts=name.split('/')
        if any(x in ('','.','..') for x in parts) or '\\' in name or ':' in name:raise ValueError('unsafe path')
        path=a.fixture.joinpath(*parts)
        if path.is_symlink() or not path.is_file():raise ValueError('regular files only')
        info=zipfile.ZipInfo(name,date_time=(2026,1,1,0,0,0));info.create_system=3
        info.external_attr=(stat.S_IFREG | (0o755 if name==m['entrypoint'] else 0o644))<<16
        info.compress_type=zipfile.ZIP_STORED
        z.writestr(info,path.read_bytes())
