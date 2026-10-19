#!/usr/bin/env python3
"""Development-only archive tooling. Inspection/extraction never runs executable code.
Not a publisher verifier; production installation remains disabled in the host.
"""
import argparse, json, os, shutil, stat, tempfile, zipfile
from pathlib import Path, PurePosixPath
MAX_FILES=256
MAX_BYTES=64*1024*1024

def safe_name(name):
    if not name or '\\' in name or '\x00' in name or name.startswith('/'):
        raise ValueError('unsafe archive path')
    parts=name.split('/')
    if any(x in ('','.', '..') for x in parts): raise ValueError('unsafe archive path')
    if ':' in name: raise ValueError('unsafe archive path')
    return name

def inspect(archive):
    with zipfile.ZipFile(archive) as z:
        infos=z.infolist()
        if not 1 <= len(infos) <= MAX_FILES: raise ValueError('file count limit')
        seen=set(); total=0
        for info in infos:
            name=safe_name(info.filename)
            if name.casefold() in seen: raise ValueError('duplicate/case-colliding path')
            seen.add(name.casefold())
            mode=info.external_attr >> 16
            if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG)): raise ValueError('non-regular archive entry')
            if info.flag_bits & 1: raise ValueError('encrypted archive forbidden')
            if info.compress_type not in (zipfile.ZIP_STORED,zipfile.ZIP_DEFLATED): raise ValueError('unsupported compression')
            total+=info.file_size
            if total>MAX_BYTES: raise ValueError('expanded size limit')
            if info.file_size > max(1,info.compress_size)*200: raise ValueError('compression ratio limit')
        if 'manifest.json' not in z.namelist(): raise ValueError('missing manifest')
        mi=z.getinfo('manifest.json')
        if mi.file_size>65536: raise ValueError('manifest size limit')
        manifest=json.loads(z.read(mi))
        declared=manifest.get('files')
        if not isinstance(declared,list) or not all(isinstance(x,str) for x in declared): raise ValueError('invalid file list')
        names=[safe_name(x) for x in declared]
        if len(set(x.casefold() for x in names))!=len(names): raise ValueError('duplicate manifest paths')
        if 'manifest.json' in names or set(names)|{'manifest.json'} != set(z.namelist()): raise ValueError('manifest file set mismatch')
        if manifest.get('entrypoint') not in names: raise ValueError('entrypoint not declared')
        return manifest, infos

def extract(archive,destination):
    destination=Path(destination)
    if destination.exists() or destination.is_symlink(): raise ValueError('destination must not exist')
    # Caller supplies a local trusted destination; no archive path chooses this parent.
    destination.parent.mkdir(parents=True,exist_ok=True)
    manifest,infos=inspect(archive)
    staging=Path(tempfile.mkdtemp(prefix='.notch-unpack-',dir=destination.parent))
    try:
        written=0
        with zipfile.ZipFile(archive) as z:
            for info in infos:
                target=staging.joinpath(*info.filename.split('/'));target.parent.mkdir(parents=True,exist_ok=True)
                with z.open(info) as source, target.open('xb') as out:
                    count=0
                    while True:
                        chunk=source.read(65536)
                        if not chunk: break
                        count+=len(chunk);written+=len(chunk)
                        if count>info.file_size or written>MAX_BYTES: raise ValueError('actual size limit')
                        out.write(chunk)
                    if count!=info.file_size: raise ValueError('size mismatch')
                target.chmod(0o700 if info.filename==manifest['entrypoint'] else 0o600)
        staging.rename(destination)
    except BaseException:
        shutil.rmtree(staging,ignore_errors=True);raise
    return manifest

def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('archive',type=Path);p.add_argument('--extract-to',type=Path);args=p.parse_args()
    manifest=extract(args.archive,args.extract_to) if args.extract_to else inspect(args.archive)[0]
    print(json.dumps({'status':'development-only','manifest':manifest},ensure_ascii=False))
if __name__=='__main__':main()
