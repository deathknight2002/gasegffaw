#!/usr/bin/env python3
"""Generate Swiss Ephemeris (Moshier) reference vectors for RitualCore's ephemeris tests.

Run: python3 Tools/truth/gen_vectors.py > Packages/RitualCore/Tests/RitualCoreTests/Fixtures/ephemeris_vectors.json
Requires: pip install pyswisseph
"""
import json, random, swisseph as swe
swe.set_ephe_path(None)
FLAGS = swe.FLG_MOSEPH | swe.FLG_SPEED
random.seed(20020816)

def elong(j):
    s = swe.calc_ut(j, swe.SUN, FLAGS)[0][0]; m = swe.calc_ut(j, swe.MOON, FLAGS)[0][0]
    return (m - s) % 360

def prenatal_syzygy(jd):
    j, e, step = jd, elong(jd), 0.05
    while True:
        j2 = j - step; e2 = elong(j2)
        if (e < 20 and e2 > 340) or (e >= 180 and e2 < 180):
            target = 0 if e < 20 else 180
            lo, hi = j2, j
            for _ in range(60):
                mid = (lo + hi) / 2; em = elong(mid)
                if target == 0: lo, hi = (mid, hi) if em > 340 else (lo, mid)
                else:           lo, hi = (mid, hi) if em < 180 else (lo, mid)
            js = (lo + hi) / 2
            kind = "new" if target == 0 else "full"
            body = swe.SUN if kind == "new" else swe.MOON
            return {"kind": kind, "jd": js, "lon": swe.calc_ut(js, body, FLAGS)[0][0]}
        j, e = j2, e2

def vector(y, mo, d, ut, lat, lon, with_syzygy):
    jd = swe.julday(y, mo, d, ut, swe.GREG_CAL)
    sun = swe.calc_ut(jd, swe.SUN, FLAGS)[0]
    moon = swe.calc_ut(jd, swe.MOON, FLAGS)[0]
    cusps, ascmc = swe.houses_ex(jd, lat, lon, b'P', swe.FLG_MOSEPH)
    alt = swe.azalt(jd, swe.ECL2HOR, (lon, lat, 0), 0, 0, (sun[0], sun[1], sun[2]))
    nut = swe.calc_ut(jd, swe.ECL_NUT, FLAGS)[0]  # [true obliquity, mean obliquity, nut lon, nut obl]
    v = {"date": f"{y:04d}-{mo:02d}-{d:02d}", "ut_hours": ut, "jd_ut": jd, "lat": lat, "lon": lon,
         "sun_lon": sun[0], "sun_lat": sun[1], "sun_dist_au": sun[2], "moon_lon": moon[0], "moon_lat": moon[1],
         "asc": ascmc[0], "mc": ascmc[1], "armc": ascmc[2], "sun_alt_true": alt[1],
         "true_obliquity": nut[0], "mean_obliquity": nut[1], "nutation_lon": nut[2], "nutation_obl": nut[3]}
    if with_syzygy: v["prenatal_syzygy"] = prenatal_syzygy(jd)
    return v

vectors = [vector(2002, 8, 16, 13.0, 45.5152, -122.6784, True)]
places = [(45.5152, -122.6784), (51.5074, -0.1278), (-33.8688, 151.2093), (35.6762, 139.6503), (0.0, 0.0), (64.1466, -21.9426), (-54.8019, -68.3030)]
for i in range(40):
    y = random.randint(1950, 2050); mo = random.randint(1, 12); d = random.randint(1, 28)
    ut = round(random.uniform(0, 24), 4); lat, lon = random.choice(places)
    vectors.append(vector(y, mo, d, ut, lat, lon, i % 4 == 0))
print(json.dumps({"source": "pyswisseph 2.10.03 / Moshier", "tolerance_deg": 0.1, "vectors": vectors}, indent=1))
