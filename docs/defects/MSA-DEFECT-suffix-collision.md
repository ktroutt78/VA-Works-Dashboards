# MSA membership defect — FIPS-suffix collision in `msa_members`

**Filed:** 2026-07-09 (internal — not a client ticket)
**Status:** OPEN — fix BLOCKED on `queries/community_profiles_mssql_validate_r4.sql` (P9–P11)
**Defective artifact:** `queries/community_profiles_mssql_RUN.sql` (`msa_members` CTE), shipped in commit `a1ea230`; wrong data installed in `apps/community-profiles/data/profiles.json` (commit `b2104dc`)
**Discovered by:** user report — Washington MSA map highlight scattered across Virginia (Eastern Shore, far southwest, mid-state), 2026-07-09

## Root cause

`msa_members` joins `county_dim cd ON cd.Area = sg.SubArea` with **no
constraint on the member's state**. `SUBGEOGRAPHIES` AreaType '31' rows list
every member county of a multi-state MSA, and out-of-state members carry
their **own state's** 3-digit FIPS suffix in `SubArea` (the WID standard has
a member-state column, presumed `SubStFips`, that the query never selected
or filtered). The unconstrained join therefore matched out-of-state member
codes onto Virginia localities sharing the same suffix — e.g. DC `11001` →
`'000001'` → **Accomack County (51001)**.

## The 12 intruder localities

| MSA | Intruder (VA locality) | Actual member it collided with |
|---|---|---|
| 047900 Washington | Accomack (51001) | District of Columbia 11001 |
| 047900 Washington | Bath (51017) | Charles County MD 24017 |
| 047900 Washington | Bland (51021) | Frederick County MD 24021 |
| 047900 Washington | Campbell (51031) | Montgomery County MD 24031 |
| 047900 Washington | Caroline (51033) | Prince George's County MD 24033 |
| 047900 Washington | Charlotte (51037) | Jefferson County WV 54037 |
| 047260 Virginia Beach | Buckingham (51029) | Camden County NC 37029 |
| 047260 Virginia Beach | Dinwiddie (51053) | Currituck County NC 37053 |
| 047260 Virginia Beach | Gloucester (51073, **duplicate**) | Gates County NC 37073 (collides onto the real member) |
| 028700 Kingsport-Bristol | Gloucester (51073) | Hawkins County TN 47073 |
| 028700 Kingsport-Bristol | Rockbridge (51163) | Sullivan County TN 47163 |
| 049020 Winchester | Buchanan (51027) | Hampshire County WV 54027 |

The 7 single-state MSAs are clean (every member genuinely VA). Note the
Virginia Beach duplicate: if that MSA's rollup path is ever taken, Gloucester
is **double-counted** in the sums. Also noted: Calvert MD (24009) produced no
collision row — P9b checks whether its membership row is absent at source.

## Blast radius (verified against installed profiles.json, 2026-07-09)

- **Map highlights:** wrong for the 4 multi-state MSAs; correct for the 7
  single-state MSAs, all 14 LWDAs (re-verified), GO Virginia, counties, state.
- **`industryEmployment`:** CORRECT everywhere — **firebreak**: MSA industry
  uses native AreaType '31' fact rows only; no rollup path exists for it, so
  the bad membership never touches it. All 11 MSAs resolved native rows.
- **`unempLatest`:** `COALESCE(native '31' row, polluted rollup)`. Correct
  wherever a native LAUS annual row exists. **Every MSA that fell through to
  the rollup is displaying a wrong rate with NO illustrative badge.** Per the
  documented LAUS home-state gotcha, Washington and Kingsport-Bristol have no
  LABORFORCE rows under StFips 51 and are the expected fall-throughs — P10
  enumerates the actual list; do not treat the expectation as confirmed.
- Secondary question raised (P11): even where native rows exist, native may
  be a whole-multi-state-MSA quantity while the fallback rollup is VA-part —
  the shipped COALESCE would then mix two grains in one emitted field.

## Process gap

Probe **P3a validated LWDA membership by name** — every locality resolved
against GEOGRAPHIES and eyeballed — which is exactly how it earned
"CONFIRMED". **MSA membership was never name-validated**: probe P8 only
*counted* SUBGEOGRAPHIES parents/rows per AreaType. A P3a-equivalent dump for
AreaType '31' would have shown "Accomack" inside the Washington MSA
immediately. Rule going forward: **membership crosswalks are validated at
name level, per parent, before any RUN.sql consumes them** — row counts are
not validation.

## The badge system cannot catch this class of defect

`realFields` asserts **PROVENANCE, not CORRECTNESS**. A field sourced from
SQL enters `realFields` and renders with no "Illustrative" badge **even when
the SQL is wrong** — which is precisely what happened to the polluted MSA
unemployment rates. The badge invariant ("fallback-to-mock is always
badged") held perfectly and still shipped wrong numbers as real. Nothing in
the badge design should be blamed or changed for this; the defense against
wrong-but-real is name-level validation of every crosswalk at probe time,
plus aggregate spot-checks against published figures (the smoke tests
checked counts and one county rate, not MSA member identity).

## Fix (blocked, not designed here)

Awaiting P9 (member-state column name), P10 (exact fall-through list), P11
(native grain semantics). The fix will at minimum constrain `msa_members` to
VA sub-areas and re-emit profiles.json; it must also resolve the
mixed-grain COALESCE question before re-shipping MSA unemployment.
