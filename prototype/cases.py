from solver import solve

SRC = (6000, 4000)   # 3:2, 24 MP

cases = [
 ("aspect 16:9 + 2.0 MP",            [("aspect",16/9),("megapixels",2.0)], 1),
 ("  ...then width := 1600",         [("width",1600),("aspect",16/9)],     1),
 ("  ...then height := 900",         [("height",900),("aspect",16/9)],     1),
 ("aspect 16:9 + 2.0 MP, mult 8",    [("aspect",16/9),("megapixels",2.0)], 8),
 ("aspect 16:9 + 2.0 MP, mult 64",   [("aspect",16/9),("megapixels",2.0)], 64),
 ("aspect 16:9 + 2.0 MP, mult 128",  [("aspect",16/9),("megapixels",2.0)],128),
 ("aspect 21:9 + 1.0 MP, mult 64",   [("aspect",21/9),("megapixels",1.0)], 64),
 ("long edge 1600 (AR from source)", [("long",1600)],                      1),
 ("long edge 1600, mult 64",         [("long",1600)],                      64),
 ("width 1600 + height 1000",        [("width",1600),("height",1000)],     1),
 ("scale 50%",                       [("scale",0.5)],                      1),
 ("aspect 1:1 only (MP from source)",[("aspect",1.0)],                     1),
 ("2.0 MP only (AR from source)",    [("megapixels",2.0)],                 1),
]

print(f"source {SRC[0]}x{SRC[1]}  ({SRC[0]/SRC[1]:.4f}, {SRC[0]*SRC[1]/1e6:.1f} MP)\n")
print(f"{'case':36} {'mult':>4}  {'ideal':>13}  {'result':>11}  {'AR err':>7} {'px err':>7}")
print("-"*90)
for label, pins, m in cases:
    s = solve(pins, *SRC, multiple=m)
    print(f"{label:36} {m:>4}  {s.ideal_w:6.1f}x{s.ideal_h:6.1f}  "
          f"{s.width:5}x{s.height:<5}  {s.aspect_error_pct:6.3f}% {s.pixel_error_pct:6.2f}%")
