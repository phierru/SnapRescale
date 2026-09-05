from solver import solve, solve2
SRC=(6000,4000)
cases=[("long edge 1600",[("long",1600)]),
 ("width 1500 + 16:9",[("width",1500),("aspect",16/9)]),
 ("width 1920 + 16:9",[("width",1920),("aspect",16/9)]),
 ("short edge 1080 + 21:9",[("short",1080),("aspect",21/9)]),
 ("aspect 16:9 + 2 MP",[("aspect",16/9),("megapixels",2.0)]),
 ("aspect 21:9 + 1 MP",[("aspect",21/9),("megapixels",1.0)]),
 ("aspect 1:1 + 0.5 MP",[("aspect",1.0),("megapixels",0.5)])]
for m in (8,16):
    print(f"\n=== multiple = {m} ===")
    print(f"{'case':26} {'ideal':>13} {'AR-priority':>18} {'pin-respecting':>19}")
    print("-"*80)
    for l,p in cases:
        a,b=solve(p,*SRC,multiple=m),solve2(p,*SRC,multiple=m)
        print(f"{l:26} {a.ideal_w:6.1f}x{a.ideal_h:<6.1f} {a.width:>6}x{a.height:<5}{a.aspect_error_pct:5.2f}% "
              f"{b.width:>7}x{b.height:<5}{b.aspect_error_pct:5.2f}%")
