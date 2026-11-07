import sqlite3
cdb = r'D:\dsh_workspaces\MC_bot_dsh\mycard-bot\game\cards.cdb'
con=sqlite3.connect(cdb); cur=con.cursor()
def sections(path):
    sec=None; m=[]; e=[]
    for line in open(path, encoding='utf-8', errors='ignore'):
        s=line.strip()
        if s.startswith('#main'): sec='m'; continue
        if s.startswith('#extra'): sec='e'; continue
        if s.startswith('!'): sec=None; continue
        if not s or s[0]=='#' or not s.isdigit(): continue
        (m if sec=='m' else e if sec=='e' else []).append(int(s))
    return m,e
for fn in ['Speedroid-Windwitch.ydk','Shiranui.ydk','Blue Eyes.ydk']:
    m,e=sections(r'D:\dsh_workspaces\MC_bot_dsh\mycard-bot\game\deck\\'+fn)
    mon=0; tun=0
    for c in m:
        r=cur.execute("select type from datas where id=?",(c,)).fetchone()
        if not r: continue
        t=r[0]
        if t & 0x1: mon+=1
        if t & 0x1000: tun+=1
    print(f"{fn}: main={len(m)} monsters={mon} tuners={tun} extra={len(e)}")
