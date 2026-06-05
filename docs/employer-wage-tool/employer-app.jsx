// Employer wage tool — app shell.
// Two directions on a design canvas:
//   A · Job Family Overview — planned wage as a line across the family
//   B · Pay-Band Planner    — target percentile, recommended $ per role
// Tweaks panel drives both: industry, family, region, planned wage,
// target percentile. Industry only affects the Industry Summary band
// in direction B.

const { useState, useEffect } = React;

function App() {
  const [industry, setIndustry] = useState("62: Health Care & Social Assistance");
  const [family, setFamily]     = useState("43-3000 · Financial Clerks");
  const [region, setRegion]     = useState("Virginia");
  const [wage, setWage]         = useState(48000);
  const [target, setTarget]     = useState(60);

  // Wire the Tweaks DOM (kept outside React so it overlays the canvas).
  useEffect(() => {
    const panel = document.getElementById("tweaks");
    const onMsg = (e) => {
      const t = e.data && e.data.type;
      if (t === "__activate_edit_mode")   panel.classList.add("on");
      if (t === "__deactivate_edit_mode") panel.classList.remove("on");
    };
    window.addEventListener("message", onMsg);
    window.parent.postMessage({ type: "__edit_mode_available" }, "*");

    const indBtns = panel.querySelectorAll("button.ind");
    indBtns.forEach(b => b.onclick = () => {
      indBtns.forEach(x=>x.classList.remove("on")); b.classList.add("on");
      setIndustry(b.dataset.ind);
    });
    const famBtns = panel.querySelectorAll("button.fam");
    famBtns.forEach(b => b.onclick = () => {
      famBtns.forEach(x=>x.classList.remove("on")); b.classList.add("on");
      setFamily(b.dataset.fam);
    });
    const regBtns = panel.querySelectorAll("button.reg");
    regBtns.forEach(b => b.onclick = () => {
      regBtns.forEach(x=>x.classList.remove("on")); b.classList.add("on");
      setRegion(b.dataset.reg);
    });
    const wageEl = panel.querySelector("#wage");
    const wageOut = panel.querySelector("#wageOut");
    if (wageEl) wageEl.oninput = () => { setWage(+wageEl.value); wageOut.textContent = "$" + (+wageEl.value).toLocaleString(); };
    const tgtEl = panel.querySelector("#target");
    const tgtOut = panel.querySelector("#targetOut");
    if (tgtEl) tgtEl.oninput = () => { setTarget(+tgtEl.value); tgtOut.textContent = tgtEl.value + "th"; };

    return () => window.removeEventListener("message", onMsg);
  }, []);

  // Artboard heights track family size so the canvas stays snug.
  // Option A uses fixed row-h. Option B uses min-h with wrap → estimate.
  const nA = FAMILIES[family].length;
  const hA = 250 + 110 + nA*40 + 110;
  // Option B taller: + ~80 industry band + extra row for split controls + slightly taller rows for wrap
  const hB = 260 + 60 + 90 + 120 + nA*54 + 130;

  return (
    <DesignCanvas>
      <DCSection
        id="concepts"
        title="Employer wage tool · concepts"
        subtitle="Same visual system as the job-seeker tool · job-family research · ~760 px embed"
      >
        <DCArtboard id="a" label="A · Job Family Overview — one planned wage across the family" width={760} height={hA}>
          <FamilyOverview family={family} region={region} plannedWage={wage} />
        </DCArtboard>
        <DCArtboard id="b" label="B · Pay-Band Planner — refined per design brief (industry summary · KPI strip · red diamond · hourly)" width={760} height={hB}>
          <PayBandPlanner industry={industry} family={family} region={region} targetPct={target} />
        </DCArtboard>
      </DCSection>
    </DesignCanvas>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
