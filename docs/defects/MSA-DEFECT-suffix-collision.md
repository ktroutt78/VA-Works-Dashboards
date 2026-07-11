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

## Update 2026-07-09 — P9 results, reconciliation, and the S-prefix reframe

**P9 CONFIRMED (client run):** the member-state column is `SubStFips`
(char(2) NOT NULL, ordinal 5). Pinning `StFips='51' AND SubStFips='51'` on
Washington returns exactly the 17 genuine VA-part members, zero intruders —
the two-predicate fix is proven correct for MEMBERSHIP. Single vintage on
this install (2301/0000); no vintage anchor needed — this is NOT the
front-page multi-vintage mechanism.

**Virginia Beach reconciliation (corrects the table above):** the "18
members with 3 intruders" figure is the **defect's emitted count** — the
whole-MSA distinct-member list under StFips 51 is 18 (15 VA + Camden,
Currituck, Gates NC), and Gates NC (`'000073'`) collides **onto the real
member Gloucester**, producing a visible duplicate in the emitted fips array
rather than 18 distinct localities. **15 is the true VA-part member count.**
All-11 VA-part counts: Blacksburg 5, Charlottesville 5, Harrisonburg 2,
Kingsport-Bristol 3, Lynchburg 5, Richmond 17, Roanoke 6, Staunton 3,
Virginia Beach 15, Washington 17, Winchester 2 — 80 localities total.

**Storage model (proven by the 129-row identity):** whole-MSA parents
replicate the FULL member list under every asking state's StFips (Washington:
92 rows = 23 x 4); S-part parents (S47900 etc.) list each member ONCE under
the member's own StFips. P8's 129 member rows at StFips 51 decompose exactly
as 43 (7 single-state MSAs) + 49 (4 whole multi-state copies) + 37 (4
S-twins' VA members) — no other composition fits. The undocumented 92→23
collapse in RUN.sql is therefore the `sg.StFips='51'` predicate selecting
Virginia's whole-MSA copy; `county_dim` dropped nothing (23 in → 23 out) and
no DISTINCT exists downstream (the duplicate Gloucester proves it).

**S-prefix finding:** S-areas are the OMB state-part delineation
(GEOGRAPHIES names them, e.g. S47900 "Washington … VA Part" — wage tool P2,
client-confirmed 2026-07-07). Only the 4 multi-state MSAs have S-twins.
**The tranche-1 smoke test S6 ("no S-part MSAs = PASS") was inherited from
the wage tool's whole-MSA model and is WRONG for this VA-scoped app** — for
community profiles the S-areas may be the authoritative fact source: if
LABORFORCE/INDUSTRY carry S-area rows under StFips 51, MSA profiles read
**published VA-part aggregates natively** and the mixed-grain COALESCE
problem dissolves instead of needing a fallback rule.

## Update 2026-07-11 — P10–P12 results and the implemented fix

**P10 (S-aware sweep, client run 2026-07-09):** LAUS carries 9 wholes +
S28700/S47260/S49020; **S47900 does not exist in LABORFORCE at all** —
Washington has no published unemployment at any grain under StFips 51; its
only option is the correct-membership VA rollup. Industry carries all 11
wholes + all 4 S-parts, **but every S-part's row/industry-code counts are
IDENTICAL to its whole twin** (e.g. Kingsport 4832/1227 both grains) — the
S-part Industry rows may be duplicated whole-MSA values, not genuine VA
parts. Probe P13 (added) compares actual employment values; **industry must
not source from S-parts until P13 answers.**

**P11 (grain comparison):** Richmond control passed (whole 723,088 vs rollup
723,091). Virginia Beach: S-part 850,069 vs rollup 850,068 — **S LAUS rows
ARE the published VA part**; whole − S = 26,641 = the NC share. Washington
correct-membership rollup: LF 1,759,084, rate **3.1** — the shipped polluted
rate was 3.2, so the defect moved Washington by +0.1pt. Damage final:
Washington and Kingsport rates were wrong; Virginia Beach (3.5) and
Winchester (3.2) shipped from whole-grain native rows and were correct.

**P12:** Calvert MD absent from the loaded 2301 delineation under ALL asking
states — national load/delineation question, parked (punchlist candidate;
whole-MSA membership only).

**Fix implemented in RUN.sql (2026-07-11, grain policy "as-sourced,
whole-first" — client decision):**
1. `msa_members` pins `StFips='51' AND SubStFips='51'` (also added the
   explicit pin to `lwda_members` — correct today by accident of geography,
   now correct by contract).
2. `laus_native` gained a per-MSA priority chain: whole-grain published row
   (pri 1) → S-part published VA-part row (pri 2, `'S'+RIGHT(code,5)`) →
   fall through to the correct-membership rollup. Kingsport lands on its
   published S28700 rate; Washington on the 3.1 rollup.
3. `industryEmployment` unchanged (whole-grain native — was never wrong).
4. Smoke tests S7–S9 added: name-level membership regression, expected
   values from P11, S-part-industry-unused assertion.

**Not yet done:** re-run RUN.sql, name-level membership validation of the
emitted regions block (per the process rule above), install profiles.json,
headless re-verify. P13 outstanding (documentation under this grain policy;
blocking only if S-part industry is ever considered again).
