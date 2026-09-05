from solver import solve2
LADDER=[512,768,1024,2048]
ARS=[("1:1",1/1),("4:3",4/3),("3:2",3/2),("16:9",16/9),("21:9",21/9),("9:16",9/16)]
SRC=(6000,4000)
print("chip pins LONG EDGE, multiple=16, source 6000x4000\n")
print(f"{'':6}" + "".join(f"{n:>13}" for n,_ in ARS))
for v in LADDER:
    row=f"{v:<6}"
    for _,ar in ARS:
        s=solve2([("long",v),("aspect",ar)],*SRC,multiple=16)
        row+=f"{s.width:>6}x{s.height:<6}"
    print(row)
print("\nlattice-safety of the ladder itself:")
for v in LADDER:
    print(f"  {v}: /8 = {v/8:g}{'  ok' if v%8==0 else '  NOT DIVISIBLE'}"
          f"   /16 = {v/16:g}{'  ok' if v%16==0 else '  NOT DIVISIBLE'}")
print("\nsame chip pinning SHORT edge instead (16:9):")
for v in LADDER:
    s=solve2([("short",v),("aspect",16/9)],*SRC,multiple=16)
    print(f"  {v} -> {s.width}x{s.height}")
