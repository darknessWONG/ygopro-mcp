import sqlite3, sys
codes = sys.argv[1].split(',')
con = sqlite3.connect(r'D:\dsh_workspaces\MC_bot_dsh\mycard-bot\game\cards.cdb')
cur = con.cursor()
for c in codes:
    if not c: continue
    cur.execute("select type,level,atk,def from datas where id=?", (int(c),))
    r = cur.fetchone()
    name = '(no name)'
    try:
        cur.execute("select name from texts where id=?", (int(c),))
        n = cur.fetchone()
        if n and n[0]: name = n[0]
    except Exception:
        pass
    if r:
        t = r[0]
        tags = []
        if t & 0x1000: tags.append('TUNER')
        if t & 0x2000: tags.append('SYNCHRO')
        if t & 0x800000: tags.append('XYZ')
        if t & 0x4000000: tags.append('LINK')
        if t & 0x40: tags.append('FUSION')
        print(c, name, 'type=0x%x' % t, 'lv=%d' % r[1], 'atk=%d' % r[2], 'def=%d' % r[3], ' '.join(tags))
    else:
        print(c, 'NOT FOUND')
