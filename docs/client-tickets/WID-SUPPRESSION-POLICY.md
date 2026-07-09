# WID Suppression Policy — disclosure question for the client

**Filed:** 2026-07-09
**Source artifact:** `queries/community_profiles_mssql_validate.sql` Probe R3b
**Consuming query:** `queries/community_profiles_mssql_RUN.sql` (Community Profiles dashboard — industry employment by sector)
**Status:** OPEN — awaiting client decision. No code change has been made or
should be made until the client answers.

## This is a disclosure question, not a display preference

The `WID.dbo.Industry` table on this install **stores real employment values
in rows flagged `Suppress = '1'`** — the flag marks the cell as
non-publishable but does not mask the number (probe R3b: 5,259 flagged
county-grain NAICS-2 cells, ~23% of the total, carrying real values up to
29,625 with only 136 zeros).

`community_profiles_mssql_RUN.sql` does not read the `Suppress` flag. As a
result, **BLS-suppressed values currently render on a public-facing chart**
(the Community Profiles industry section and Overview top-industries card).

BLS suppresses QCEW cells to protect **employer identity** — in small
counties, a sector cell can be one identifiable business. Whether
republishing those values is permissible depends on the terms of the
client's data-sharing agreement with BLS. **We cannot assess that agreement;
only the client can.**

## The question for the client

> Should the Community Profiles dashboard respect the `Suppress` flag —
> i.e., withhold flagged cells from public display?

## Consequences of each answer

**If yes (respect suppression):**
- RUN.sql filters `Suppress = '1'` cells; those sector values become absent
  from `profiles.json`.
- Incomplete sector charts become more common. Already today, 61 of 168
  regions render fewer than 21 sectors because the underlying fact rows do
  not exist at all; suppression filtering adds to that count, concentrated
  in small counties.
- Region rollups that sum county cells (GO Virginia) would undercount unless
  they continue to sum the stored values internally while withholding only
  the *display* of flagged county cells — a design decision to make at
  implementation time, guided by how the client reads their agreement.
- Native-grain rows (state, LWDA, MSA) carry their own flags at their own
  grain and are less exposed; county-level charts are the main surface.

**If no (values may be shown):**
- No change; current behavior stands, on the client's authority.
- Recommend the client's answer be recorded here and in the (future)
  handover doc, since the dashboard is public-facing.

## Explicitly out of scope until answered

No suppression filter ships in `community_profiles_mssql_RUN.sql` or the
front end before the client answers. The handover doc for this dashboard is
also deferred pending this answer, so it can document the decided policy
rather than an open question.
