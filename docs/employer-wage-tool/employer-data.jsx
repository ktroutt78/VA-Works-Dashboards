// Employer wage tool — shared data + chart primitives.
// Visual system intentionally mirrors the shipped job-seeker tool
// (navy header, paper controls bar, white chart card, percentile bar,
//  legend, footer) so this reads as the SAME product, not a re-theme.

const { useMemo } = React;

// Tokens — pulled to match the shipped widget ----------------------------
const T = {
  headerBg: "#1b2536",   // navy header band
  headerSub:"#aab3c4",
  paper:    "#f3f0e9",   // warm controls bg
  shell:    "#ffffff",
  cardLine: "#dfe2e8",
  fieldLine:"#d2d7df",
  ink:      "#1b2536",
  body:     "#27303f",
  muted:    "#6b7280",
  label:    "#727a89",   // uppercase field/stat labels
  faint:    "#edeae1",
  rangeLt:  "#aab9d6",   // 10–90 fill
  rangeDk:  "#34537d",   // 25–75 fill
  median:   "#11151c",   // median tick
  you:      "#b5392b",   // employer wage marker (red)
  youDot:   "#c0392b",
  spWage:   "#34537d",   // wage-trend sparkline
  spEmp:    "#3f7d5a",   // employment sparkline
  accent:   "#b5392b",   // brand red accent rule
  serif:    '"Source Serif Pro", Georgia, "Times New Roman", serif',
  sans:     '"Inter", system-ui, sans-serif',
};

// Regional wage multipliers (applied to all percentile points) -----------
const REGIONS = {
  "Virginia":               { mult: 1.00, short: "VA statewide",       label: "Virginia" },
  "Virginia Beach–Norfolk": { mult: 0.98, short: "Va. Beach–Norfolk",  label: "Virginia Beach–Norfolk" },
  "Northern Virginia":      { mult: 1.18, short: "Northern Virginia",  label: "Northern Virginia" },
};

// Industries (NAICS sectors) ---------------------------------------------
// Drives ONLY the Industry Summary band. Industry × occupation data is
// suppressed for privacy, so industry never affects the occupation bands.
// Numbers are QCEW means (intentionally blunt "head-cost" ballparks).
const INDUSTRIES = {
  "62: Health Care & Social Assistance": {
    naics: "62", short: "Health Care & Social Asst.",
    mean: { "Virginia": 58200, "Virginia Beach–Norfolk": 55400, "Northern Virginia": 67800 },
    emp:  { "Virginia": 412000,"Virginia Beach–Norfolk": 88600, "Northern Virginia": 132400 },
    est:  { "Virginia": 23800, "Virginia Beach–Norfolk": 4820,  "Northern Virginia": 7240 },
  },
  "54: Professional, Scientific & Technical": {
    naics: "54", short: "Prof, Sci & Technical",
    mean: { "Virginia": 102400,"Virginia Beach–Norfolk": 86500, "Northern Virginia": 124800 },
    emp:  { "Virginia": 538000,"Virginia Beach–Norfolk": 52600, "Northern Virginia": 312500 },
    est:  { "Virginia": 64200, "Virginia Beach–Norfolk": 6420,  "Northern Virginia": 32800 },
  },
  "52: Finance & Insurance": {
    naics: "52", short: "Finance & Insurance",
    mean: { "Virginia": 88600, "Virginia Beach–Norfolk": 74200, "Northern Virginia": 106400 },
    emp:  { "Virginia": 116200,"Virginia Beach–Norfolk": 14100, "Northern Virginia": 41800 },
    est:  { "Virginia": 9460,  "Virginia Beach–Norfolk": 1180,  "Northern Virginia": 3120 },
  },
  "31–33: Manufacturing": {
    naics: "31–33", short: "Manufacturing",
    mean: { "Virginia": 64800, "Virginia Beach–Norfolk": 58200, "Northern Virginia": 73400 },
    emp:  { "Virginia": 238400,"Virginia Beach–Norfolk": 28600, "Northern Virginia": 18900 },
    est:  { "Virginia": 5240,  "Virginia Beach–Norfolk": 720,   "Northern Virginia": 480 },
  },
  "92: Public Administration": {
    naics: "92", short: "Public Administration",
    mean: { "Virginia": 71400, "Virginia Beach–Norfolk": 65800, "Northern Virginia": 89200 },
    emp:  { "Virginia": 184600,"Virginia Beach–Norfolk": 19400, "Northern Virginia": 64800 },
    est:  { "Virginia": 2840,  "Virginia Beach–Norfolk": 320,   "Northern Virginia": 720 },
  },
};

// Job families — SOC-3 minor groups (BLS OEWS) ---------------------------
// Each detailed (SOC-6) occupation carries:
//   p  — annual percentile distribution (5-number summary, statewide base)
//   ph — NATIVE hourly percentile distribution (sourced separately by BLS;
//        not derived from annual ÷ 2080)
//   emp — statewide employment level
const FAMILIES = {
  "43-3000 · Financial Clerks": [
    { job:"Bill & Account Collectors",                p:{10:32000,25:36000,50:42000,75:50000,90:60000}, ph:{10:15.40,25:17.30,50:20.20,75:24.00,90:28.80}, emp:3800  },
    { job:"Billing & Posting Clerks",                 p:{10:32000,25:38000,50:44000,75:51000,90:58000}, ph:{10:15.40,25:18.30,50:21.10,75:24.50,90:27.90}, emp:12100 },
    { job:"Bookkeeping, Accounting & Auditing Clerks",p:{10:34000,25:40000,50:48000,75:57000,90:66000}, ph:{10:16.30,25:19.20,50:23.10,75:27.40,90:31.70}, emp:28600 },
    { job:"Payroll & Timekeeping Clerks",             p:{10:38000,25:44000,50:52000,75:60000,90:69000}, ph:{10:18.30,25:21.20,50:25.00,75:28.80,90:33.20}, emp:6400  },
    { job:"Procurement Clerks",                       p:{10:36000,25:42000,50:50000,75:59000,90:68000}, ph:{10:17.30,25:20.20,50:24.00,75:28.40,90:32.70}, emp:2900  },
    { job:"Tellers",                                  p:{10:28000,25:31000,50:36000,75:42000,90:49000}, ph:{10:13.50,25:14.90,50:17.30,75:20.20,90:23.60}, emp:8200  },
  ],
  "43-4000 · Information & Record Clerks": [
    { job:"Customer Service Representatives",         p:{10:30000,25:34000,50:40000,75:47000,90:55000}, ph:{10:14.40,25:16.30,50:19.20,75:22.60,90:26.40}, emp:64800 },
    { job:"Receptionists & Information Clerks",       p:{10:28000,25:32000,50:36000,75:41000,90:47000}, ph:{10:13.50,25:15.40,50:17.30,75:19.70,90:22.60}, emp:21300 },
    { job:"Human Resources Assistants, Except Payroll",p:{10:36000,25:42000,50:49000,75:57000,90:65000},ph:{10:17.30,25:20.20,50:23.60,75:27.40,90:31.30}, emp:5200  },
    { job:"New Accounts Clerks",                      p:{10:32000,25:38000,50:44000,75:51000,90:59000}, ph:{10:15.40,25:18.30,50:21.10,75:24.50,90:28.40}, emp:1100  },
    { job:"Eligibility Interviewers, Government Programs", p:{10:38000,25:44000,50:52000,75:61000,90:71000}, ph:{10:18.30,25:21.20,50:25.00,75:29.30,90:34.10}, emp:3400 },
    { job:"Loan Interviewers & Clerks",               p:{10:34000,25:40000,50:46000,75:54000,90:63000}, ph:{10:16.30,25:19.20,50:22.10,75:26.00,90:30.30}, emp:4800  },
  ],
  "15-1200 · Computer Occupations": [
    { job:"Computer User Support Specialists",        p:{10:45000,25:54000,50:63000,75:74000,90:86000},   ph:{10:21.60,25:26.00,50:30.30,75:35.60,90:41.30}, emp:22000 },
    { job:"Web Developers",                           p:{10:52000,25:63000,50:77000,75:93000,90:112000},  ph:{10:25.00,25:30.30,50:37.00,75:44.70,90:53.80}, emp:6800  },
    { job:"Software Quality Assurance Analysts & Testers", p:{10:58000,25:70000,50:82000,75:98000,90:118000}, ph:{10:27.90,25:33.70,50:39.40,75:47.10,90:56.70}, emp:12500 },
    { job:"Network & Computer Systems Administrators",p:{10:66000,25:78000,50:92000,75:108000,90:126000}, ph:{10:31.70,25:37.50,50:44.20,75:51.90,90:60.60}, emp:12000 },
    { job:"Software Developers",                      p:{10:70000,25:84000,50:98000,75:115000,90:138000}, ph:{10:33.70,25:40.40,50:47.10,75:55.30,90:66.30}, emp:41000 },
    { job:"Database Administrators",                  p:{10:78000,25:92000,50:108000,75:126000,90:146000},ph:{10:37.50,25:44.20,50:51.90,75:60.60,90:70.20}, emp:4900  },
    { job:"Information Security Analysts",            p:{10:84000,25:100000,50:118000,75:137000,90:158000},ph:{10:40.40,25:48.10,50:56.70,75:65.90,90:75.90}, emp:7200  },
  ],
  "21-1000 · Counselors & Social Workers": [
    { job:"Substance Abuse, Behavioral Disorder & Mental Health Counselors", p:{10:40000,25:46000,50:53000,75:62000,90:72000}, ph:{10:19.20,25:22.10,50:25.50,75:29.80,90:34.60}, emp:6100 },
    { job:"Educational, Guidance & Career Counselors", p:{10:44000,25:52000,50:60000,75:70000,90:82000}, ph:{10:21.20,25:25.00,50:28.80,75:33.70,90:39.40}, emp:8400 },
    { job:"Child, Family & School Social Workers",    p:{10:38000,25:44000,50:52000,75:62000,90:73000}, ph:{10:18.30,25:21.20,50:25.00,75:29.80,90:35.10}, emp:7200  },
    { job:"Healthcare Social Workers",                p:{10:50000,25:55000,50:64000,75:74000,90:79000}, ph:{10:24.00,25:26.40,50:30.80,75:35.60,90:38.00}, emp:4200  },
    { job:"Mental Health & Substance Abuse Social Workers", p:{10:38000,25:44000,50:51000,75:60000,90:70000}, ph:{10:18.30,25:21.20,50:24.50,75:28.80,90:33.70}, emp:3100 },
    { job:"Community Health Workers",                 p:{10:34000,25:39000,50:45000,75:52000,90:60000}, ph:{10:16.30,25:18.80,50:21.60,75:25.00,90:28.80}, emp:3300  },
  ],
};

// Regional fallback simulation -----------------------------------------
// In real OEWS, MSA × occupation cells can be suppressed when sparse;
// those rows fall back to statewide. Here, a static map decides which
// (region, occupation) cells are flagged as fallback.
const FALLBACK = {
  "Virginia": new Set(),  // statewide is always native
  "Virginia Beach–Norfolk": new Set([
    "Procurement Clerks",
    "New Accounts Clerks",
    "Eligibility Interviewers, Government Programs",
    "Information Security Analysts",
    "Mental Health & Substance Abuse Social Workers",
    "Database Administrators",
  ]),
  "Northern Virginia": new Set([
    "Tellers",
    "Bill & Account Collectors",
    "Community Health Workers",
  ]),
};
function isFallback(region, jobName) { return FALLBACK[region].has(jobName); }

// Helpers ----------------------------------------------------------------
const fmtK = (v) => "$" + Math.round(v/1000) + "K";
const fmtMoney = (v) => "$" + Math.round(v).toLocaleString();
const fmtEmp = (v) => v.toLocaleString();
const fmtHourly = (v) => "$" + v.toFixed(2) + "/hr";
// hourly range w/ 1-decimal precision (compact form for KPI strip)
const fmtHourlyShort = (v) => "$" + v.toFixed(0);

function scaleRegion(p, mult) {
  return { 10:p[10]*mult, 25:p[25]*mult, 50:p[50]*mult, 75:p[75]*mult, 90:p[90]*mult };
}

// Resolve an occupation row for a given region. If the cell is flagged
// as fallback, return the statewide distribution and mark the row.
function resolveRow(row, region) {
  const fb = isFallback(region, row.job);
  const mult = fb ? 1.0 : REGIONS[region].mult;
  return {
    ...row,
    p:  scaleRegion(row.p,  mult),
    ph: scaleRegion(row.ph, mult),
    fallback: fb,
  };
}

// wage → approximate percentile (linear between the 5 known points)
function approxPct(p, wage) {
  const pts = [[10,p[10]],[25,p[25]],[50,p[50]],[75,p[75]],[90,p[90]]];
  if (wage <= pts[0][1]) return 5;
  if (wage >= pts[4][1]) return 95;
  for (let i=0;i<pts.length-1;i++){
    const [pa,va]=pts[i],[pb,vb]=pts[i+1];
    if (wage>=va && wage<=vb) return Math.round(pa + (wage-va)/(vb-va)*(pb-pa));
  }
  return 50;
}
// percentile → wage (linear between the 5 known points)
function wageAtPct(p, t) {
  const pts = [[10,p[10]],[25,p[25]],[50,p[50]],[75,p[75]],[90,p[90]]];
  if (t<=10) return p[10];
  if (t>=90) return p[90];
  for (let i=0;i<pts.length-1;i++){
    const [pa,va]=pts[i],[pb,vb]=pts[i+1];
    if (t>=pa && t<=pb) return va + (t-pa)/(pb-pa)*(vb-va);
  }
  return p[50];
}

function computeDomain(rows) {
  const min = Math.min(...rows.map(r=>r.p[10]));
  const max = Math.max(...rows.map(r=>r.p[90]));
  const lo = Math.floor((min*0.9)/5000)*5000;
  const hi = Math.ceil((max*1.04)/5000)*5000;
  return [lo, hi];
}
function niceTicks([lo,hi]) {
  const span = hi - lo;
  const steps = [10000,20000,25000,40000,50000];
  let step = 10000;
  for (const s of steps) { if (span/s <= 6) { step = s; break; } }
  const start = Math.ceil(lo/step)*step;
  const out = [];
  for (let v=start; v<=hi+1; v+=step) out.push(v);
  return out;
}

// deterministic little trend generators
function wageTrend(p50) {
  return [0.88,0.91,0.94,0.97,1].map(f => Math.round(p50*f));
}
function empTrend(emp) {
  // 8 points, gentle drift with one wobble (deterministic)
  return [0,1,2,3,4,5,6,7].map(i => Math.round(emp*(1 + Math.sin(i*1.1)*0.015 + (i-3.5)*0.004)));
}

// ------------------------------------------------------------------------
// Sparkline — tiny line chart (wage trend / employment)
function Sparkline({ data, width=64, height=22, color }) {
  const min = Math.min(...data), max = Math.max(...data);
  const x = (i)=> (i/(data.length-1))*(width-3)+1.5;
  const y = (v)=> height-2 - ((v-min)/Math.max(1,max-min))*(height-4);
  const pts = data.map((v,i)=>`${x(i)},${y(v)}`).join(" ");
  return (
    <svg width={width} height={height} style={{display:"block"}}>
      <polyline points={pts} fill="none" stroke={color} strokeWidth="1.6" strokeLinejoin="round" strokeLinecap="round"/>
      <circle cx={x(data.length-1)} cy={y(data[data.length-1])} r="2.4" fill={color}/>
    </svg>
  );
}

// ------------------------------------------------------------------------
// Bar — single occupation percentile bar (10–90, 25–75, median tick),
// plus optional markers (dot / diamond) at given wage values.
function Bar({ width, height=26, domain, p, markers=[] }) {
  const [dMin,dMax]=domain;
  const x = (v)=> ((v-dMin)/(dMax-dMin))*width;
  const h = 15, y = (height-h)/2;
  return (
    <svg width={width} height={height} style={{display:"block", overflow:"visible"}}>
      <line x1="0" x2={width} y1={height/2} y2={height/2} stroke={T.cardLine} strokeWidth="1"/>
      <rect x={x(p[10])} y={y} width={Math.max(0,x(p[90])-x(p[10]))} height={h} fill={T.rangeLt} rx="2.5"/>
      <rect x={x(p[25])} y={y} width={Math.max(0,x(p[75])-x(p[25]))} height={h} fill={T.rangeDk} rx="2"/>
      <line x1={x(p[50])} x2={x(p[50])} y1={y-3} y2={y+h+3} stroke={T.median} strokeWidth="2"/>
      {markers.map((m,i)=>{
        if (m.type==="diamond") {
          const cx=x(m.value), cy=height/2, s=5.5;
          return <path key={i} d={`M ${cx} ${cy-s} L ${cx+s} ${cy} L ${cx} ${cy+s} L ${cx-s} ${cy} Z`}
                       fill={m.color} stroke="#fff" strokeWidth="1.3"/>;
        }
        return <circle key={i} cx={x(m.value)} cy={height/2} r="5" fill={m.color} stroke="#fff" strokeWidth="1.5"/>;
      })}
    </svg>
  );
}

// ------------------------------------------------------------------------
// Axis — standalone x-axis row aligned to a bar of `width`
function Axis({ width, domain, ticks }) {
  const [dMin,dMax]=domain;
  const x=(v)=>((v-dMin)/(dMax-dMin))*width;
  return (
    <svg width={width} height="22" style={{display:"block", overflow:"visible"}}>
      <line x1="0" x2={width} y1="1" y2="1" stroke={T.cardLine} strokeWidth="1"/>
      {ticks.map((t,i)=>(
        <g key={i} transform={`translate(${x(t)},0)`}>
          <line x1="0" x2="0" y1="1" y2="4" stroke={T.muted} strokeWidth="1"/>
          <text x="0" y="16" fontSize="11" textAnchor="middle" fontFamily={T.sans} fill={T.muted}>{fmtK(t)}</text>
        </g>
      ))}
    </svg>
  );
}

// ------------------------------------------------------------------------
// Header band — navy, serif title, GUIDE button (matches shipped widget)
function GuideHeader({ title, subtitle }) {
  return (
    <div style={{
      background:T.headerBg, padding:"15px 20px",
      display:"flex", justifyContent:"space-between", alignItems:"flex-start",
    }}>
      <div>
        <div style={{fontFamily:T.serif, fontWeight:600, fontSize:20, color:"#fff", letterSpacing:0.2}}>{title}</div>
        <div style={{fontSize:12, color:T.headerSub, marginTop:3}}>{subtitle}</div>
      </div>
      <div style={{
        display:"flex", alignItems:"center", gap:6,
        border:"1px solid rgba(255,255,255,0.32)", borderRadius:16,
        padding:"5px 12px", color:"#dfe4ec", fontSize:11, letterSpacing:1.2, textTransform:"uppercase",
      }}>
        <span style={{
          width:14, height:14, borderRadius:"50%", border:"1px solid rgba(255,255,255,0.5)",
          display:"inline-flex", alignItems:"center", justifyContent:"center", fontSize:9, fontStyle:"italic",
        }}>?</span>
        Guide
      </div>
    </div>
  );
}

// Field (display-only — driven by the Tweaks panel) ----------------------
function Field({ label, value, info, caret, mono }) {
  return (
    <div>
      <div style={{display:"flex", alignItems:"center", gap:4, marginBottom:5}}>
        <span style={{fontSize:10.5, color:T.label, textTransform:"uppercase", letterSpacing:1}}>{label}</span>
        {info && <span style={{
          width:13, height:13, borderRadius:"50%", border:`1px solid ${T.muted}`,
          fontSize:8, fontStyle:"italic", color:T.muted, display:"inline-flex",
          alignItems:"center", justifyContent:"center",
        }}>i</span>}
      </div>
      <div style={{
        background:"#fff", border:`1px solid ${T.fieldLine}`, borderRadius:6,
        padding:"9px 12px", fontSize:14, color:T.body,
        display:"flex", justifyContent:"space-between", alignItems:"center",
        fontFamily: mono ? T.sans : T.sans,
      }}>
        <span style={{overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap"}}>{value}</span>
        {caret && <span style={{color:T.muted, fontSize:10, marginLeft:8}}>▾</span>}
      </div>
    </div>
  );
}

// Stat cell for the summary row -----------------------------------------
function StatCell({ label, value, sub, accentValue, size=20 }) {
  return (
    <div style={{minWidth:0}}>
      <div style={{fontSize:10.5, color:T.label, textTransform:"uppercase", letterSpacing:1, marginBottom:4, whiteSpace:"nowrap"}}>{label}</div>
      <div style={{fontFamily:T.serif, fontWeight:600, fontSize:size, lineHeight:1.05, color: accentValue||T.ink, whiteSpace:"nowrap"}}>{value}</div>
      {sub && <div style={{fontSize:11, color:T.muted, marginTop:3}}>{sub}</div>}
    </div>
  );
}

// Legend chip ------------------------------------------------------------
function LegendChip({ kind, color, label }) {
  let sw;
  if (kind==="tick") sw = <span style={{width:3, height:13, background:color, display:"inline-block"}}/>;
  else if (kind==="dot") sw = <span style={{width:11, height:11, borderRadius:"50%", background:color, display:"inline-block"}}/>;
  else if (kind==="diamond") sw = <span style={{width:11, height:11, background:color, display:"inline-block", transform:"rotate(45deg)"}}/>;
  else sw = <span style={{width:18, height:11, background:color, borderRadius:2, display:"inline-block"}}/>;
  return (
    <span style={{display:"inline-flex", alignItems:"center", gap:6, fontSize:11.5, color:T.body}}>
      {sw}{label}
    </span>
  );
}

Object.assign(window, {
  T, REGIONS, INDUSTRIES, FAMILIES, FALLBACK, isFallback, resolveRow,
  fmtK, fmtMoney, fmtEmp, fmtHourly, fmtHourlyShort,
  scaleRegion, approxPct, wageAtPct,
  computeDomain, niceTicks, wageTrend, empTrend,
  Sparkline, Bar, Axis, GuideHeader, Field, StatCell, LegendChip,
});
