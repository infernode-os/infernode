import sys, time, os
sys.path.insert(0, '/mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance')
from board import Board
S = os.path.dirname(os.path.abspath(__file__))
lastdump = 0
while True:
    try:
        b = Board('192.168.1.104')
        m = b.sh('cat /dev/memory', wait=0.5)
        main = [l for l in m.splitlines() if l.strip().endswith('main')]
        f = main[0].split() if main else ['?']
        used = int(f[0]) if f[0].isdigit() else 0
        print(time.strftime('%H:%M:%S'), 'main used', f[0], 'of', f[1] if len(f) > 1 else '?', flush=True)
        # the pool is climbing: ask who, at most every 30 s, and keep every answer
        if used > 20*1024*1024 and time.time() - lastdump > 30:
            lastdump = time.time()
            t = b.sh('cat /dev/memtags', wait=2.0)
            fn = os.path.join(S, 'memtags-%s.txt' % time.strftime('%H%M%S'))
            open(fn, 'w').write(t)
            print(time.strftime('%H:%M:%S'), 'memtags dumped to', fn, flush=True)
    except Exception as e:
        print(time.strftime('%H:%M:%S'), 'unreachable', e, flush=True)
    time.sleep(2)
