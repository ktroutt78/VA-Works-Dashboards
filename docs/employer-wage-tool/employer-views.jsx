// Employer wage tool — the two layout directions.
//   Direction A · FamilyOverview  — every occupation in a family, with one
//     planned-wage line crossing all rows (where a single offer lands).
//   Direction B · PayBandPlanner   — set a target percentile, see the
//     recommended dollar figure per occupation + the gap to current pay.

// Shared geometry for a 760px-wide artboard ------------------------------
const CARD_PAD = 16;          // inner padding of the white chart card
const CARD_MARGIN = 16;       // chart card inset from the outer shell
const CONTENT_W = 760 - CARD_MARGIN*2 - CARD_PAD*2;  // 696

// ========================================================================
// Direction A — JOB FAMILY OVERVIEW
// ========================================================================
function FamilyOverview({ family, region, plannedWage }) {
  const mult = REGIONS[region].mult;
  const rows = FAMILIES[family].map(r => ({ ...r, p: scaleRegion(r.p, mult) }));
  const domain = computeDomain(rows);
  const ticks = niceTicks(domain);

  const LABEL_W = 196;
  const BAR_W = CONTENT_W - LABEL_W;     // 500
  const ROW_H = 40;

  const x = (v)=> ((v-domain[0])/(domain[1]-domain[0]))*BAR_W;
  const lineLeft = LABEL_W + x(plannedWage);

  // summary metrics
  const medians = rows.map(r=>r.p[50]);
  const totalEmp = rows.reduce((s,r)=>s+r.emp,0);
  const avgPct = Math.round(rows.reduce((s,r)=>s+approxPct(r.p, plannedWage),0)/rows.length);
  const empTotalsTrend = empTrend(totalEmp);

  return (
    <div style={{width:760, border:`1px solid ${T.cardLine}`, borderRadius:10, background:T.paper, overflow:"hidden", fontFamily:T.sans}}>
      <GuideHeader title="Wage Comparison Tool" subtitle="Plan pay across a job family · Bureau of Labor Statistics OEWS" />

      {/* Controls */}
      <div style={{padding:"14px 20px", display:"grid", gridTemplateColumns:"1.3fr 1fr 1fr", gap:14}}>
        <Field label="Job family"     value={family} info caret />
        <Field label="Region"         value={region} caret />
        <Field label="Your planned wage" value={fmtMoney(plannedWage)} />
      </div>

      {/* Chart card */}
      <div style={{
        background:T.shell, border:`1px solid ${T.cardLine}`, borderRadius:8,
        margin:`0 ${CARD_MARGIN}px ${CARD_MARGIN}px`, padding:CARD_PAD,
        borderLeft:`4px solid ${T.accent}`,
      }}>
        {/* summary stat row */}
        <div style={{display:"grid", gridTemplateColumns:"2fr 1fr 1.1fr 0.9fr", gap:14, alignItems:"flex-start", paddingBottom:14, borderBottom:`1px solid ${T.faint}`, marginBottom:14}}>
          <div>
            <div style={{fontSize:10.5, color:T.accent, textTransform:"uppercase", letterSpacing:1.2, fontWeight:600}}>Job family</div>
            <div style={{fontFamily:T.serif, fontWeight:600, fontSize:15, lineHeight:1.15, marginTop:3}}>{family}</div>
            <div style={{fontSize:11.5, color:T.muted, marginTop:4}}>{REGIONS[region].short} · {rows.length} occupations</div>
          </div>
          <StatCell label="Family median" value={`${fmtK(Math.min(...medians))}–${fmtK(Math.max(...medians))}`} sub="range of medians" />
          <div>
            <div style={{fontSize:10.5, color:T.label, textTransform:"uppercase", letterSpacing:1, marginBottom:4, whiteSpace:"nowrap"}}>Total employment</div>
            <div style={{display:"flex", alignItems:"center", gap:8}}>
              <div style={{fontFamily:T.serif, fontWeight:600, fontSize:20, lineHeight:1, color:T.ink}}>{fmtEmp(totalEmp)}</div>
              <Sparkline data={empTotalsTrend} color={T.spEmp} width={50} height={20}/>
            </div>
            <div style={{fontSize:11, color:T.muted, marginTop:3}}>24-mo. trend</div>
          </div>
          <StatCell label="Your position" value={`${avgPct}th`} sub="avg. across family" accentValue={T.you} />
        </div>

        {/* multi-row chart with shared planned-wage line */}
        <div style={{position:"relative", paddingTop:18}}>
          {/* planned-wage tag */}
          <div style={{position:"absolute", left:lineLeft, top:0, transform:"translateX(-50%)", zIndex:3}}>
            <span style={{
              background:T.you, color:"#fff", fontSize:10, padding:"2px 7px", borderRadius:3,
              whiteSpace:"nowrap", fontWeight:500,
            }}>YOUR WAGE · {fmtK(plannedWage)}</span>
          </div>
          {/* vertical planned-wage line spanning all rows */}
          <div style={{position:"absolute", left:lineLeft, top:18, height:rows.length*ROW_H, width:0, borderLeft:`2px dashed ${T.you}`, zIndex:2}}/>

          {rows.map((r,i)=>{
            const pct = approxPct(r.p, plannedWage);
            return (
              <div key={i} style={{display:"grid", gridTemplateColumns:`${LABEL_W}px ${BAR_W}px`, height:ROW_H, alignItems:"center"}}>
                <div style={{paddingRight:12, minWidth:0}}>
                  <div style={{fontSize:12.5, fontWeight:600, color:T.body, lineHeight:1.15, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap"}}>{r.job}</div>
                  <div style={{fontSize:10.5, color:T.muted}}>{fmtEmp(r.emp)} jobs · med {fmtK(r.p[50])}</div>
                </div>
                <div style={{position:"relative"}}>
                  <Bar width={BAR_W} domain={domain} p={r.p} height={ROW_H-14}
                       markers={[{type:"dot", value: Math.max(domain[0], Math.min(domain[1], plannedWage)), color:T.youDot}]}/>
                </div>
              </div>
            );
          })}

          {/* axis */}
          <div style={{display:"grid", gridTemplateColumns:`${LABEL_W}px ${BAR_W}px`}}>
            <span/>
            <Axis width={BAR_W} domain={domain} ticks={ticks}/>
          </div>
        </div>

        {/* legend + footer */}
        <div style={{display:"flex", justifyContent:"space-between", alignItems:"center", marginTop:14}}>
          <div style={{display:"flex", gap:16, flexWrap:"wrap"}}>
            <LegendChip kind="bar"  color={T.rangeLt} label="10th–90th percentile"/>
            <LegendChip kind="bar"  color={T.rangeDk} label="25th–75th percentile"/>
            <LegendChip kind="tick" color={T.median}  label="Median"/>
            <LegendChip kind="dot"  color={T.youDot}  label="Your planned wage"/>
          </div>
        </div>
        <div style={{display:"flex", justifyContent:"space-between", alignItems:"center", marginTop:12}}>
          <div style={{fontSize:11, color:T.muted}}>Live data · BLS OEWS</div>
          <button style={{
            fontSize:12.5, padding:"7px 14px", borderRadius:6, border:`1px solid ${T.rangeDk}`,
            color:T.rangeDk, background:"#fff", cursor:"pointer", fontFamily:T.sans, fontWeight:500,
          }}>Export this family ↓</button>
        </div>
      </div>
    </div>
  );
}

// ========================================================================
// Direction B — PAY-BAND PLANNER  (revised per design brief, June 2026)
//
// Top zone (NEW): Industry × Region summary — QCEW mean for the whole
// industry. Visually distinct from the occupation card so the two
// employment figures (industry headcount vs occupation hiring pool) are
// never confused.
//
// Pay-band card: family-header eyebrow (borrowed from Option A), KPI
// strip (budget at Nth · family median range · position vs market median
// · hiring pool), occupation rows with RED diamond markers at the target
// percentile (no more "YOU PAY" reference line), and a right-side $/yr +
// $/hr value pulled from native OEWS hourly data.
// ========================================================================
function PayBandPlanner({ industry, family, region, targetPct }) {
  const ind = INDUSTRIES[industry];
  const fam = FAMILIES[family];

  // resolveRow surfaces a `fallback` flag when the region × occupation
  // cell would be suppressed — that row falls back to statewide data.
  const rows   = fam.map(r => resolveRow(r, region));
  const domain = computeDomain(rows);
  const ticks  = niceTicks(domain);

  // Geometry — wider label column to accommodate full SOC-6 names with
  // wrap (no more "Receptionists & Informati…").
  const LABEL_W = 232;
  const FIG_W   = 100;
  const BAR_W   = CONTENT_W - LABEL_W - FIG_W;
  const ROW_MINH = 50;

  // Derived metrics ------------------------------------------------------
  const recsA  = rows.map(r => wageAtPct(r.p,  targetPct));   // annual $
  const recsH  = rows.map(r => wageAtPct(r.ph, targetPct));   // hourly $
  const budgetLo  = Math.min(...recsA), budgetHi  = Math.max(...recsA);
  const budgetLoH = Math.min(...recsH), budgetHiH = Math.max(...recsH);

  const medians  = rows.map(r => r.p[50]);
  const medLo    = Math.min(...medians), medHi = Math.max(...medians);
  // "Market median" = average of the family's occupation medians.
  // Compared against the midpoint of the dynamic budget range — gives a
  // clean dollar delta as the percentile slider moves.
  const marketMid    = medians.reduce((s, m) => s + m, 0) / medians.length;
  const bandMid      = (budgetLo + budgetHi) / 2;
  const positionDlt  = bandMid - marketMid;

  const totalEmp = rows.reduce((s, r) => s + r.emp, 0);

  // SOC-3 family header parsing  ("43-3000 · Financial Clerks")
  const [socCode, familyName] = family.split(" · ");

  return (
    <div style={{width:760, border:`1px solid ${T.cardLine}`, borderRadius:10, background:T.paper, overflow:"hidden", fontFamily:T.sans}}>
      <GuideHeader title="Wage Comparison Tool" subtitle="Build a competitive pay band · BLS OEWS + QCEW" />

      {/* Industry controls — drive only the summary band immediately below */}
      <div style={{padding:"14px 20px 12px", display:"grid", gridTemplateColumns:"1.7fr 1fr", gap:14}}>
        <Field label="Industry · NAICS"   value={industry} info caret />
        <Field label="Region"             value={region} caret />
      </div>

      {/* INDUSTRY × REGION SUMMARY — cooler tint to read as a separate
          statistic (mean, not percentile). Driven by Industry + Region. */}
      <div style={{
        margin:"0 20px 14px",
        background:"#eceff5",
        border:`1px solid #d8dde8`,
        borderRadius:6,
        padding:"10px 14px",
        display:"grid",
        gridTemplateColumns:"auto 1.3fr 1fr 1fr",
        gap:18,
        alignItems:"center",
      }}>
        <div style={{display:"flex", flexDirection:"column", gap:2}}>
          <span style={{fontSize:9.5, color:"#5b6577", textTransform:"uppercase", letterSpacing:1.2, fontWeight:600}}>NAICS {ind.naics}</span>
          <span style={{fontSize:12, color:T.body, fontWeight:600, lineHeight:1.15, maxWidth:148}}>{ind.short}</span>
        </div>
        <div>
          <div style={{fontSize:10, color:"#5b6577", textTransform:"uppercase", letterSpacing:1, whiteSpace:"nowrap"}}>
            Industry avg wage · all roles <span style={{opacity:0.65}}>(QCEW mean)</span>
          </div>
          <div style={{fontFamily:T.serif, fontWeight:600, fontSize:18, color:T.ink, lineHeight:1.05, marginTop:2}}>
            {fmtMoney(ind.mean[region])}
          </div>
          {/* QCEW does not publish a native hourly figure at this grain;
              derived as annual ÷ 2080 (standard convention). */}
          <div style={{fontSize:11, color:T.muted, marginTop:2}}>
            {fmtHourly(ind.mean[region] / 2080)}
          </div>
        </div>
        <div>
          <div style={{fontSize:10, color:"#5b6577", textTransform:"uppercase", letterSpacing:1}}>Industry employment</div>
          <div style={{fontFamily:T.serif, fontWeight:600, fontSize:18, color:T.ink, lineHeight:1.05, marginTop:2}}>
            {fmtEmp(ind.emp[region])}
          </div>
        </div>
        <div>
          <div style={{fontSize:10, color:"#5b6577", textTransform:"uppercase", letterSpacing:1}}>Establishments</div>
          <div style={{fontFamily:T.serif, fontWeight:600, fontSize:18, color:T.ink, lineHeight:1.05, marginTop:2}}>
            {fmtEmp(ind.est[region])}
          </div>
        </div>
      </div>

      {/* Pay-band controls — drive the chart card immediately below.
          Sit between the industry summary and the detailed pay bands so
          the control → output relationship reads in plain reading order. */}
      <div style={{padding:"0 20px 12px", display:"grid", gridTemplateColumns:"1.7fr 1fr", gap:14}}>
        <Field label="Job family · SOC-3" value={family} info caret />
        <div>
          <div style={{fontSize:10.5, color:T.label, textTransform:"uppercase", letterSpacing:1, marginBottom:5}}>Target percentile</div>
          <div style={{
            background:"#fff", border:`1px solid ${T.fieldLine}`, borderRadius:6, padding:"7px 12px",
            display:"flex", alignItems:"center", gap:10,
          }}>
            <span style={{fontFamily:T.serif, fontWeight:600, fontSize:16, color:T.you, minWidth:38}}>{targetPct}th</span>
            <div style={{flex:1, height:5, background:T.faint, borderRadius:3, position:"relative"}}>
              <div style={{position:"absolute", left:0, top:0, bottom:0, width:`${(targetPct-10)/80*100}%`, background:T.you, borderRadius:3}}/>
              <div style={{position:"absolute", left:`${(targetPct-10)/80*100}%`, top:"50%", transform:"translate(-50%,-50%)", width:12, height:12, borderRadius:"50%", background:"#fff", border:`2px solid ${T.you}`}}/>
            </div>
          </div>
        </div>
      </div>

      {/* Pay-band chart card (warm tone, red left accent) */}
      <div style={{
        background:T.shell, border:`1px solid ${T.cardLine}`, borderRadius:8,
        margin:`0 ${CARD_MARGIN}px ${CARD_MARGIN}px`, padding:CARD_PAD,
        borderLeft:`4px solid ${T.accent}`,
      }}>
        {/* Family header — eyebrow + bold serif title + sub-line (from A) */}
        <div style={{paddingBottom:12, borderBottom:`1px solid ${T.faint}`, marginBottom:14}}>
          <div style={{fontSize:10.5, color:T.accent, textTransform:"uppercase", letterSpacing:1.2, fontWeight:600}}>
            Job family · SOC {socCode}
          </div>
          <div style={{fontFamily:T.serif, fontWeight:600, fontSize:19, lineHeight:1.15, marginTop:3}}>
            {familyName}
          </div>
          <div style={{fontSize:11.5, color:T.muted, marginTop:4}}>
            {REGIONS[region].short} · {rows.length} occupations · pay band at the{" "}
            <span style={{color:T.you, fontWeight:600}}>{targetPct}th percentile</span>
          </div>
        </div>

        {/* KPI strip — 4 cells: budget (dynamic) · family medians (static)
            · position vs market (neutral) · hiring pool */}
        <div style={{display:"grid", gridTemplateColumns:"1.35fr 1fr 1.05fr 0.9fr", gap:14, paddingBottom:14, borderBottom:`1px solid ${T.faint}`, marginBottom:8}}>
          <div>
            <div style={{fontSize:10.5, color:T.label, textTransform:"uppercase", letterSpacing:1, marginBottom:4}}>
              Budget at the {targetPct}th
            </div>
            <div style={{fontFamily:T.serif, fontWeight:600, fontSize:18, lineHeight:1.05, color:T.you, whiteSpace:"nowrap"}}>
              {fmtK(budgetLo)}–{fmtK(budgetHi)}
            </div>
            <div style={{fontSize:11, color:T.muted, marginTop:3}}>
              {budgetLoH.toFixed(2)}–{budgetHiH.toFixed(2)}/hr · per role
            </div>
          </div>
          <div>
            <div style={{fontSize:10.5, color:T.label, textTransform:"uppercase", letterSpacing:1, marginBottom:4}}>
              Family median range
            </div>
            <div style={{fontFamily:T.serif, fontWeight:600, fontSize:18, lineHeight:1.05, color:T.ink, whiteSpace:"nowrap"}}>
              {fmtK(medLo)}–{fmtK(medHi)}
            </div>
            <div style={{fontSize:11, color:T.muted, marginTop:3}}>across {rows.length} occupations</div>
          </div>
          <div>
            <div style={{fontSize:10.5, color:T.label, textTransform:"uppercase", letterSpacing:1, marginBottom:4}}>
              Position vs. market median
            </div>
            <div style={{fontFamily:T.serif, fontWeight:600, fontSize:18, lineHeight:1.05, color:T.ink, whiteSpace:"nowrap"}}>
              {positionDlt >= 0 ? "+" : "−"}{fmtK(Math.abs(positionDlt))}
            </div>
            <div style={{fontSize:11, color:T.muted, marginTop:3}}>
              vs. family-avg median ({fmtK(marketMid)})
            </div>
          </div>
          <div>
            <div style={{fontSize:10.5, color:T.label, textTransform:"uppercase", letterSpacing:1, marginBottom:4}}>
              Hiring pool
            </div>
            <div style={{fontFamily:T.serif, fontWeight:600, fontSize:18, lineHeight:1.05, color:T.ink, whiteSpace:"nowrap"}}>
              {fmtEmp(totalEmp)}
            </div>
            <div style={{fontSize:11, color:T.muted, marginTop:3}}>sum across {rows.length} occs</div>
          </div>
        </div>

        {/* Chart rows — no YOU PAY reference line; red diamond per row */}
        <div style={{paddingTop:6}}>
          {rows.map((r,i)=>{
            const recA = recsA[i];
            const recH = recsH[i];
            const recAClamped = Math.max(domain[0], Math.min(domain[1], recA));
            return (
              <div key={i} style={{
                display:"grid", gridTemplateColumns:`${LABEL_W}px ${BAR_W}px ${FIG_W}px`,
                minHeight:ROW_MINH, alignItems:"center", padding:"3px 0",
                borderBottom: i === rows.length-1 ? "none" : `1px solid ${T.faint}`,
              }}>
                <div style={{paddingRight:10, minWidth:0}}>
                  <div style={{fontSize:11.5, fontWeight:600, color:T.body, lineHeight:1.25}}>
                    {r.job}
                    {r.fallback && (
                      <span title="State-level data — regional cell suppressed" style={{color:T.muted, marginLeft:4, fontWeight:400}}>*</span>
                    )}
                  </div>
                  <div style={{fontSize:10, color:T.muted, marginTop:2}}>
                    {fmtEmp(r.emp)} jobs · {r.fallback
                      ? <span style={{fontStyle:"italic"}}>VA statewide</span>
                      : REGIONS[region].short}
                  </div>
                </div>
                <div style={{position:"relative"}}>
                  <Bar width={BAR_W} domain={domain} p={r.p} height={26}
                       markers={[{type:"diamond", value: recAClamped, color: T.you}]}/>
                </div>
                <div style={{textAlign:"right", paddingLeft:8}}>
                  <div style={{fontFamily:T.serif, fontWeight:600, fontSize:14.5, color:T.you, lineHeight:1}}>
                    {fmtMoney(Math.round(recA/500)*500)}
                  </div>
                  <div style={{fontSize:11, color:T.muted, marginTop:2}}>
                    {fmtHourly(recH)}
                  </div>
                </div>
              </div>
            );
          })}

          <div style={{display:"grid", gridTemplateColumns:`${LABEL_W}px ${BAR_W}px ${FIG_W}px`, marginTop:4}}>
            <span/>
            <Axis width={BAR_W} domain={domain} ticks={ticks}/>
            <span/>
          </div>
        </div>

        {/* Legend — red diamond now = recommended pay; no "what you pay now" */}
        <div style={{display:"flex", gap:16, flexWrap:"wrap", marginTop:14, alignItems:"center"}}>
          <LegendChip kind="bar"     color={T.rangeLt} label="10th–90th percentile"/>
          <LegendChip kind="bar"     color={T.rangeDk} label="25th–75th percentile"/>
          <LegendChip kind="tick"    color={T.median}  label="Median"/>
          <LegendChip kind="diamond" color={T.you}     label={`Pay at ${targetPct}th (recommended)`}/>
          <span style={{display:"inline-flex", alignItems:"center", gap:5, fontSize:11.5, color:T.muted}}>
            <span style={{color:T.muted, fontWeight:600}}>*</span>
            Statewide fallback (regional cell suppressed)
          </span>
        </div>

        <div style={{display:"flex", justifyContent:"space-between", alignItems:"center", marginTop:12}}>
          <div style={{fontSize:11, color:T.muted}}>
            Industry summary: BLS QCEW (mean) · Pay band: BLS OEWS (percentiles)
          </div>
          <button style={{
            fontSize:12.5, padding:"7px 14px", borderRadius:6, border:`1px solid ${T.rangeDk}`,
            color:T.rangeDk, background:"#fff", cursor:"pointer", fontFamily:T.sans, fontWeight:500,
          }}>Save this pay band ↓</button>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { FamilyOverview, PayBandPlanner, CONTENT_W });
