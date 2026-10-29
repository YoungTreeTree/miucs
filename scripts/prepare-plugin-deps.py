#!/usr/bin/env python3
"""Fetch pinned Lua, JSON and matching Skia headers/static libraries; verify before extraction."""
import argparse, hashlib, pathlib, platform, tarfile, urllib.request, tempfile, shutil
ROOT=pathlib.Path(__file__).resolve().parents[1]
DEST=ROOT/'build/plugin-deps'
SKIA='0746a1afaf750159e1a6aef29992980f4e293585'
BASE='https://github.com/rust-skia/skia-binaries/releases/download/0.156.0/skia-binaries-ce6727ef251518df37bc-'
BINARIES={
 'mac-arm64':('aarch64-apple-darwin-ganesh-jpegd-jpege-metal-pdf-textlayout','34ffe920f5a5cd4838e7ffe4cf6af48529c87bc0d74462de3e49a5715b35591a'),
 'win-x64':('x86_64-pc-windows-msvc-d3d-ganesh-jpegd-jpege-pdf-textlayout','6fd83e1a78729c5bb3eb9d331e999d3ba88ad13e99bf8370362ea29b81aef495'),
 'win-arm64':('aarch64-pc-windows-msvc-d3d-ganesh-jpegd-jpege-pdf-textlayout','b11178ef3f64140a3774b055385f07202597cfe2ffcdfe578fec603b2fb94086')}
def fetch(name,url,digest,folder=None):
    file=DEST/name
    if not file.exists() or hashlib.sha256(file.read_bytes()).hexdigest()!=digest:
        print('Downloading',name,flush=True)
        temp=file.with_suffix('.download')
        urllib.request.urlretrieve(url,temp)
        if hashlib.sha256(temp.read_bytes()).hexdigest()!=digest:temp.unlink();raise RuntimeError('SHA-256 mismatch: '+name)
        temp.replace(file)
    marker=DEST/(folder+'.verified' if folder else name+'.verified')
    if folder and (not (DEST/folder).exists() or not marker.exists() or marker.read_text()!=digest):
        with tarfile.open(file) as archive:
            members=[item for item in archive.getmembers() if not item.issym() and not item.islnk()]
            for item in members:
                path=pathlib.PurePosixPath(item.name)
                if path.is_absolute() or '..' in path.parts or item.issym() or item.islnk() or not (item.isfile() or item.isdir()):raise RuntimeError('Unsafe archive member')
            # Extract into a fresh directory: no archive links or pre-existing symlink
            # ancestors are permitted. This also supports Python 3.10 without tar filters.
            with tempfile.TemporaryDirectory(dir=DEST) as staging:
                for item in members:
                    if pathlib.PurePosixPath(item.name).parts[0]!=folder:raise RuntimeError('Unexpected archive root')
                archive.extractall(staging,members=members)
                target=DEST/folder
                if target.exists():shutil.rmtree(target)
                shutil.move(str(pathlib.Path(staging)/folder),target)
        marker.write_text(digest)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--target',choices=BINARIES,default='mac-arm64' if platform.system()=='Darwin' else 'win-x64');parser.add_argument('--core-only',action='store_true');args=parser.parse_args();DEST.mkdir(parents=True,exist_ok=True)
    fetch('lua.tar.gz','https://www.lua.org/ftp/lua-5.4.8.tar.gz','4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae','lua-5.4.8')
    fetch('json.hpp','https://raw.githubusercontent.com/nlohmann/json/v3.12.0/single_include/nlohmann/json.hpp','aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63')
    if not args.core_only:
        fetch('skia-source.tar.gz','https://codeload.github.com/rust-skia/skia/tar.gz/'+SKIA,'ae113534811d620f76e03a2ed0941dbd994ae48df24195a416e5c0a0a5e68669','skia-'+SKIA)
        name,digest=BINARIES[args.target];fetch('skia-'+args.target+'.tar.gz',BASE+name+'.tar.gz',digest,'skia-binaries')
