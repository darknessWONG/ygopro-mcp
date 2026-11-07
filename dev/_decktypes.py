import sqlite3, sys, os
cdb = r'D:\dsh_workspaces\MC_bot_dsh\mycard-bot\game\cards.cdb'
con = sqlite3.connect(cdb); cur = con.cursor()
def extra_codes(path):
    sec=None; main=[]; extra=[]
    for line in open(path, encoding='utf-8', errors='ignore'):
        line=line.strip()
        if not line: continue
        if line.startswith('#main'): sec='main'; continue
        if line.startswith('#extra'): sec='extra'; continue
        if line.startswith('!'): sec=None; continue
        if line.startswith('#'): continue
        if not line.isdigit(): continue
        (main if sec=='main' else extra if sec=='extra' else []).append(int(line))
    return main, extra
deckdir = r'D:\dsh_workspaces\MC_bot_dsh\mycard-bot\game\deck'
for fn in sorted(os.listdir(deckdir)):
    if not fn.endswith('.ydk'): continue
    m, e = extra_codes(os.path.join(deckdir, fn))
    syn=xz=0
    for c in e:
        r=cur.execute("select type from datas where id=?", (c,)).fetchone()
        if not r: continue
        if r[0] & 0x2000: syn+=1
        if r[0] & 0x800000: xz+=1
    print(f"{fn:20s} main={len(m):2d} extra={len(e):2d} synchro={syn:2d} xyz={xz:2d}")
