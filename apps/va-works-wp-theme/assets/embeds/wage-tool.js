  (async function () {
    // Data base URL. In the standalone app this was the relative "data/" dir; when
    // embedded in the WordPress theme, PHP passes the theme-assets path via
    // window.vaWageTool.dataBase (see functions.php). Falls back to "data/" so the
    // file still runs standalone.
    var DATA_BASE = (window.vaWageTool && window.vaWageTool.dataBase) || 'data/';

    // ------- 0. Diagnostic helper -------
    function fatal(msg) {
      const el = document.getElementById('diag');
      el.textContent = msg;
      el.classList.add('show');
    }
    if (typeof echarts === 'undefined') {
      fatal('ECharts CDN failed to load. Check network/extensions blocking cdn.jsdelivr.net.');
      return;
    }

    // ------- 1. Load data (real first, then example fallback) -------
    async function loadData() {
      for (const path of [DATA_BASE + 'wages.json', DATA_BASE + 'wages.example.json']) {
        try {
          const r = await fetch(path, { cache: 'no-store' });
          if (r.ok) {
            const j = await r.json();
            return { data: j, path };
          }
        } catch (_) { /* try next */ }
      }
      return null;
    }
    async function loadEmployment() {
      try {
        const r = await fetch(DATA_BASE + 'employment_trend.json', { cache: 'no-store' });
        if (r.ok) return await r.json();
      } catch (_) { /* optional file */ }
      return null;
    }

    const [loaded, EMP] = await Promise.all([loadData(), loadEmployment()]);
    if (!loaded) {
      fatal(
        'Could not load wage data.\n\n' +
        'Looked for:\n' +
        '  data/wages.json (real WID SQL Server export)\n' +
        '  data/wages.example.json (fallback)\n\n' +
        'If you opened this file via file:// some browsers block fetch().\n' +
        'Run a tiny local server instead:\n' +
        '  cd "' + location.pathname.replace(/[^/]*$/, '') + '" && python3 -m http.server 8000\n' +
        'Then open http://localhost:8000/wage-tool.html'
      );
      return;
    }
    const DATA = loaded.data;
    const isReal = loaded.path === DATA_BASE + 'wages.json';
    // Show only the data freshness signal — hide the underlying database.schema
    // since end-users don't need to see internal warehouse table names.
    document.getElementById('source-note').textContent =
      isReal ? 'Live data · BLS OEWS' : 'Example data';

    // ------- 2. Clean + index data -------
    // 2a. Drop junk areas: anything with id "none", and dedupe by label (prefer the
    //     longer/more specific label — e.g. "Virginia Beach-Chesapeake-Norfolk, VA-NC"
    //     wins over "Virginia Beach-Norfolk-Newport News" since the former matches
    //     the OMB MSA name).
    (function cleanAreas() {
      const byLabel = new Map(); // canonical label -> chosen area
      DATA.areas.forEach(a => {
        if (!a || !a.id || a.id === 'none' || /^none$/i.test(a.label || '')) return;
        const key = (a.label || '').toLowerCase().replace(/[^a-z]/g, '').slice(0, 20);
        const existing = byLabel.get(key);
        if (!existing || a.label.length > existing.label.length) byLabel.set(key, a);
      });
      const keep = new Set([...byLabel.values()].map(a => a.id));
      DATA.areas = DATA.areas.filter(a => keep.has(a.id));
      DATA.jobs.forEach(j => {
        j.areas = Object.fromEntries(
          Object.entries(j.areas || {}).filter(([aid]) => keep.has(aid))
        );
      });
    })();

    // 2b. Sanitize non-monotonic percentiles. The BLS OEWS "#" top-code marker
    //     (annual wages ≥ ~$239,200) sometimes survives the Snowflake export as
    //     a literal 0, producing entries like p90=0 with p75=$234K. That breaks
    //     the band layout (negative width, off-screen) and pulls computeDomain
    //     onto just the salary value. Cascade-clamp each upper percentile to
    //     the next lower one so the band still renders — just without an upper
    //     tail when the data is bad. The fix is non-destructive when the data
    //     is already monotonic. Track the patch count for the source-note.
    let _patched = 0;
    (function sanitizePercentiles() {
      for (const j of DATA.jobs) {
        for (const aid in (j.areas || {})) {
          const e = j.areas[aid];
          if (!e) continue;
          const before = e.p10 + ',' + e.p25 + ',' + e.p50 + ',' + e.p75 + ',' + e.p90;
          if (e.p25 < e.p10) e.p25 = e.p10;
          if (e.p50 < e.p25) e.p50 = e.p25;
          if (e.p75 < e.p50) e.p75 = e.p50;
          if (e.p90 < e.p75) e.p90 = e.p75;
          const after = e.p10 + ',' + e.p25 + ',' + e.p50 + ',' + e.p75 + ',' + e.p90;
          if (before !== after) _patched++;
        }
      }
      if (_patched) {
        console.warn('[wage-tool] patched ' + _patched + ' non-monotonic percentile entries (likely BLS top-code suppression mishandled in export).');
      }
    })();

    const AREAS  = DATA.areas;
    const JOBS   = DATA.jobs;
    const AREA_BY_ID = Object.fromEntries(AREAS.map(a => [a.id, a]));
    const JOB_BY_ID  = Object.fromEntries(JOBS.map(j => [j.id, j]));
    const TREND_YEARS = (DATA.meta && DATA.meta.trend_years) || [2020,2021,2022,2023,2024];

    function getEntry(jobId, areaId) {
      const job = JOB_BY_ID[jobId];
      if (!job) return null;
      return job.areas[areaId] || null;
    }
    function defaultAreaFor(jobId) {
      const j = JOB_BY_ID[jobId];
      if (!j) return AREAS[0].id;
      const k = Object.keys(j.areas);
      return k.includes(AREAS[0].id) ? AREAS[0].id : k[0];
    }

    // ------- 3. State -------
    // Pick first two jobs that share at least one area, prefer a "your role" + comparison pair.
    function pickInitial() {
      // Default first job: Office Clerks, General. Comparison falls back to Registered Nurses,
      // then to whatever is first in the list if those aren't present.
      const prefer = ['43-9061', '29-1141'];
      const have = prefer.filter(id => JOB_BY_ID[id]);
      if (have.length === 2) return have;
      if (have.length === 1) return [have[0], JOBS.find(j => j.id !== have[0]).id];
      return JOBS.slice(0, 2).map(j => j.id);
    }
    const initialJobs = pickInitial();
    const initialArea = AREAS.find(a => a.areatype === '01')?.id || AREAS[0].id;

    // Tool starts with ONE job (the user's current job). The Add button reveals
    // the comparison job; the × on the comparison row removes it.
    const state = {
      // null until the user types a value. The tool launches in an empty state
      // with no pre-loaded job and no pre-filled salary — the empty card prompts
      // the user to pick a job; salary becomes meaningful once they enter one.
      userSalary: null,
      // null = auto-follow userSalary (default). A number = explicit override
      // so the user can model "what if I targeted $X in the comparison job?".
      // Persists across remove/re-add of the comparison row, same as cmpDraft.
      cmpSalaryOverride: null,
      rows: [
        // jobId stays null until the user picks (typed search or demo chip).
        // render() detects null and shows renderEmptyState() instead of a row card.
        { jobId: null, areaId: initialArea, isYou: true },
      ],
    };
    function effectiveCmpSalary() {
      return state.cmpSalaryOverride != null ? state.cmpSalaryOverride : state.userSalary;
    }
    // The comparison job's prior selection is held here while it's not shown,
    // so re-adding it restores what they had before.
    let cmpDraft = { jobId: initialJobs[1] || initialJobs[0], areaId: initialArea };

    const frameEl = document.querySelector('.frame');
    function syncCmpFlag() {
      frameEl.classList.toggle('has-cmp', state.rows.length >= 2);
    }

    // ------- 4. Tom Select comboboxes (searchable; grouped by SOC major group for jobs) -------
    // Pre-build job options grouped by major_group so the dropdown organizes hundreds of SOC codes.
    const jobOptgroups = Array.from(
      JOBS.reduce((m, j) => {
        const g = j.major_group || 'Other';
        if (!m.has(g)) m.set(g, []);
        m.get(g).push({ value: j.id, text: j.label, group: g });
        return m;
      }, new Map())
    ).map(([g, _items]) => ({ value: g, label: g }));

    const jobOptions  = JOBS.map(j => ({
      value: j.id,
      text:  j.label + ' · ' + j.soc_code,
      // Concatenated alias string — Tom Select searches across it.
      aliases: (j.aliases || []).join(' | '),
      group: j.major_group || 'Other',
    }));
    const areaOptions = AREAS.map(a => ({ value: a.id, text: a.label }));

    // Normalize a string for matching: lowercase, strip punctuation, collapse spaces.
    function normStr(s) {
      return String(s || '').toLowerCase()
        .replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
    }
    // Strip trailing 's' so "associates" -> "associate", "developers" -> "developer".
    // Rough but effective for occupation titles where plural is the only common variant.
    function depluralize(t) { return t.length > 3 ? t.replace(/s$/, '') : t; }

    // Pre-normalized + depluralized index for fast freeform matching.
    // We depluralize at index time too so the haystack and query compare on
    // equal footing — "Sales Associate" alias becomes "sale associate", which
    // matches a query "sales associates" (depluralized to "sale associate").
    function deplurStr(s) { return s.split(' ').map(depluralize).join(' '); }

    // Total employment across all areas for a job — used as a "this is a common job"
    // tiebreaker. Registered Nurses (large) beats Nurse Anesthetists (small) for "nurse".
    function totalEmployment(j) {
      let sum = 0;
      for (const a in (j.areas || {})) sum += (j.areas[a].employment || 0);
      return sum;
    }

    const JOB_INDEX = JOBS.map(j => ({
      job: j,
      labelDep: deplurStr(normStr(j.label)),
      aliasesNorm: (j.aliases || []).map(a => ({ raw: a, dep: deplurStr(normStr(a)) })),
      employment: totalEmployment(j),
    }));
    const MAX_EMP = Math.max(1, ...JOB_INDEX.map(ix => ix.employment));

    // Stop words pulled from common conversational queries — strip before scoring.
    const STOP = new Set(['i','im','a','an','the','to','my','is','at','for','of','as','work','works','working','job']);

    // Levenshtein edit distance with early exit when the distance exceeds `limit`.
    // Used to make the matcher typo-tolerant ("carpentr" → "carpenter", "machanic" → "mechanic").
    function editDist(a, b, limit) {
      if (a === b) return 0;
      const m = a.length, n = b.length;
      if (Math.abs(m - n) > limit) return limit + 1;
      if (m === 0) return n;
      if (n === 0) return m;
      let prev = new Array(n + 1);
      for (let j = 0; j <= n; j++) prev[j] = j;
      for (let i = 1; i <= m; i++) {
        const curr = new Array(n + 1);
        curr[0] = i;
        let rowMin = i;
        const ca = a.charCodeAt(i - 1);
        for (let j = 1; j <= n; j++) {
          const cost = ca === b.charCodeAt(j - 1) ? 0 : 1;
          curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
          if (curr[j] < rowMin) rowMin = curr[j];
        }
        if (rowMin > limit) return limit + 1;
        prev = curr;
      }
      return prev[n];
    }

    // Allowed edits as a function of query token length — be strict for short tokens.
    function maxEditsFor(t) { return t.length <= 3 ? 0 : t.length <= 5 ? 1 : 2; }

    // Return 1.0 if exact match, ~0.65 if within edit distance, 0 otherwise.
    function tokenMatchScore(qToken, hayTokens) {
      if (hayTokens.includes(qToken)) return 1.0;
      const limit = maxEditsFor(qToken);
      if (limit === 0) return 0;
      for (const h of hayTokens) {
        if (Math.abs(h.length - qToken.length) > limit) continue;
        if (editDist(qToken, h, limit) <= limit) return 0.65;
      }
      return 0;
    }

    // Score one alias (or the label) against the query. WORD-BOUNDARY ONLY —
    // raw-substring matches are NOT counted, which prevents "rn" from matching
    // "patte_rn_makers" and similar false positives. Includes typo-tolerant
    // per-token matching (Levenshtein ≤ 2) at the lower scoring tier.
    function scoreString(hayNorm, qPhrase, qTokens) {
      if (!hayNorm || !qPhrase) return 0;
      if (hayNorm === qPhrase) return 100;
      if (hayNorm.startsWith(qPhrase + ' ')
       || hayNorm.endsWith(' ' + qPhrase)
       || hayNorm.includes(' ' + qPhrase + ' ')) return 50;
      const hayTokens = hayNorm.split(' ');
      // Per-token score (1.0 exact, 0.65 fuzzy). All tokens must hit; sum scaled to 18.
      let sum = 0;
      for (const t of qTokens) {
        const m = tokenMatchScore(t, hayTokens);
        if (m === 0) return 0;
        sum += m;
      }
      return Math.round(18 * (sum / qTokens.length));
    }

    // Score every job against the query and return the top N candidates above
    // the match threshold. The single-best path (bestMatchJob) is a thin wrapper —
    // both flows share scoring so a "good enough to commit on Enter" match always
    // appears in the dropdown too.
    function topMatchJobs(query, n) {
      n = n || 5;
      const qPhraseRaw = normStr(query);
      if (!qPhraseRaw) return [];
      const qTokens = qPhraseRaw.split(' ').filter(t => t && !STOP.has(t)).map(depluralize);
      if (!qTokens.length) return [];
      const qPhrase = qTokens.join(' ');

      const candidates = [];
      for (const ix of JOB_INDEX) {
        const labelScore = scoreString(ix.labelDep, qPhrase, qTokens) * 2;
        let topAlias = null, topAliasScore = 0;
        for (const a of ix.aliasesNorm) {
          const s = scoreString(a.dep, qPhrase, qTokens);
          if (s > topAliasScore) { topAliasScore = s; topAlias = a; }
        }
        const allOtherPenalty   = /\ball other\b/.test(ix.labelDep) ? 40 : 0;
        const postsecPenalty    = /\bpostsecondary\b/.test(ix.labelDep) ? 25 : 0;
        const supervisorPenalty = /supervisor|first line/.test(ix.labelDep) ? 8 : 0;
        const empBonus = ix.employment > 0
          ? (Math.log10(ix.employment + 1) / Math.log10(MAX_EMP + 1)) * 25
          : 0;

        const matchOnly = labelScore + topAliasScore;
        if (matchOnly === 0) continue;

        const total = matchOnly + empBonus
                      - allOtherPenalty - postsecPenalty - supervisorPenalty;
        if (total < 18) continue;

        const matchedAlias = ix.labelDep.includes(qPhrase)
          ? null
          : (topAlias && topAlias.raw) || null;
        candidates.push({ job: ix.job, score: total, matchedAlias });
      }
      candidates.sort((a, b) => b.score - a.score);
      return candidates.slice(0, n);
    }

    function bestMatchJob(query) {
      return topMatchJobs(query, 1)[0] || null;
    }

    function mkAreaCombo(id, initialValue, onChange) {
      return new TomSelect('#' + id, {
        options: areaOptions, items: [initialValue], maxOptions: null,
        searchField: ['text'], onChange: (v) => onChange(v),
      });
    }

    // HTML-escape — guard against odd alias strings flowing into innerHTML.
    function escHtml(s) {
      return String(s).replace(/[&<>"']/g, c =>
        ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    }

    // Wire a freeform job text input with O*NET-style typeahead. The user types,
    // a ranked dropdown of candidates from topMatchJobs surfaces, Enter/Tab/click
    // commits the active row (or top match when none is highlighted). Single-match
    // case still renders the dropdown — confirmation beats silent auto-commit.
    function mkJobInput(id, getJobId, setJobId) {
      const el     = document.getElementById(id);
      const hint   = document.querySelector('.match-hint[data-for="' + id + '"]');
      const list   = document.querySelector('.job-suggest[data-for="' + id + '"]');
      const helper = document.querySelector('.job-helper[data-for="' + id + '"]');
      el.value = (JOB_BY_ID[getJobId()] || {}).label || '';

      let suggestions = [];
      let activeIdx = -1;

      // Helper and dropdown share the same absolute position, so they must be
      // mutually exclusive. Helper is the focus-state hint; dropdown is the
      // typing-state results. Both go away on blur.
      function showHelper() { if (helper) { helper.hidden = false; } }
      function hideHelper() { if (helper) { helper.hidden = true; } }

      function setHint(cls, msg) {
        hint.className = 'match-hint' + (cls ? ' ' + cls : '');
        hint.textContent = msg || '';
      }
      function setStatus(cls) {
        el.classList.remove('matched', 'unmatched');
        if (cls) el.classList.add(cls);
      }

      function hideList() {
        list.hidden = true;
        list.innerHTML = '';
        suggestions = [];
        activeIdx = -1;
      }

      function showList(raw) {
        suggestions = topMatchJobs(raw, 5);
        if (!suggestions.length) { hideList(); return; }
        hideHelper();
        activeIdx = 0;
        list.innerHTML = suggestions.map((m, i) => {
          const aliasHint = m.matchedAlias
            ? ' <span class="alias-hint">via &ldquo;' + escHtml(m.matchedAlias) + '&rdquo;</span>'
            : '';
          return '<li role="option" data-i="' + i + '"'
            + (i === activeIdx ? ' class="active" aria-selected="true"' : '')
            + '>' + escHtml(m.job.label) + aliasHint + '</li>';
        }).join('');
        list.hidden = false;
      }

      function setActive(newIdx) {
        if (!suggestions.length) return;
        activeIdx = (newIdx + suggestions.length) % suggestions.length;
        const items = list.children;
        for (let i = 0; i < items.length; i++) {
          const on = (i === activeIdx);
          items[i].classList.toggle('active', on);
          if (on) items[i].setAttribute('aria-selected', 'true');
          else    items[i].removeAttribute('aria-selected');
        }
        // Keep the active row visible inside the scroll area.
        const li = items[activeIdx];
        if (li && li.scrollIntoView) li.scrollIntoView({ block: 'nearest' });
      }

      function commit(m, raw) {
        setJobId(m.job.id);
        el.value = m.job.label;
        setStatus('matched');
        if (m.matchedAlias) {
          setHint('ok', 'Matched “' + raw + '” → ' + m.job.label + ' (' + m.job.soc_code + ') via a.k.a. “' + m.matchedAlias + '”');
        } else {
          setHint('ok', 'Matched → ' + m.job.label + ' (' + m.job.soc_code + ')');
        }
        hideList();
      }

      function resolve() {
        const raw = el.value.trim();
        const current = JOB_BY_ID[getJobId()];
        // Empty → revert to current selection silently.
        if (!raw) {
          el.value = current ? current.label : '';
          setStatus(''); setHint('', '');
          hideList();
          return;
        }
        // Exactly the current label → no-op.
        if (current && raw === current.label) {
          setStatus(''); setHint('', '');
          hideList();
          return;
        }
        // Prefer the highlighted suggestion; fall back to top match for the raw text.
        const chosen = (suggestions.length && activeIdx >= 0)
          ? suggestions[activeIdx]
          : bestMatchJob(raw);
        if (!chosen) {
          setStatus('unmatched');
          setHint('bad', 'No SOC match — try a more common job title.');
          hideList();
          return;
        }
        commit(chosen, raw);
      }

      el.addEventListener('focus', () => {
        el.select();
        setHint('', '');
        setStatus('');
        // Show the focus hint on entry. The first input event will hide it.
        showHelper();
      });
      el.addEventListener('input', () => {
        const raw = el.value.trim();
        const current = JOB_BY_ID[getJobId()];
        if (raw && (!current || raw !== current.label)) {
          showList(raw);
          hideHelper();
        } else {
          hideList();
          // Empty input while focused — bring the hint back, like O*NET does.
          if (document.activeElement === el) showHelper();
        }
      });
      el.addEventListener('keydown', (e) => {
        if (e.key === 'ArrowDown') {
          if (suggestions.length) { e.preventDefault(); setActive(activeIdx + 1); }
        } else if (e.key === 'ArrowUp') {
          if (suggestions.length) { e.preventDefault(); setActive(activeIdx - 1); }
        } else if (e.key === 'Enter' || e.key === 'Tab') {
          resolve();
          if (e.key === 'Enter') el.blur();
        } else if (e.key === 'Escape') {
          el.value = (JOB_BY_ID[getJobId()] || {}).label || '';
          setHint('', ''); setStatus('');
          hideList();
          hideHelper();
          el.blur();
        }
      });
      el.addEventListener('blur', () => { hideHelper(); resolve(); });

      // mousedown (not click) fires before the input's blur — by preventDefault
      // we keep focus on the input long enough to commit, then explicitly blur.
      list.addEventListener('mousedown', (e) => {
        const li = e.target.closest('li[data-i]');
        if (!li) return;
        e.preventDefault();
        const i = parseInt(li.getAttribute('data-i'), 10);
        if (!isNaN(i) && suggestions[i]) {
          commit(suggestions[i], el.value.trim());
          el.blur();
        }
      });

      return {
        refresh: () => { el.value = (JOB_BY_ID[getJobId()] || {}).label || ''; setStatus(''); setHint('',''); hideList(); hideHelper(); },
      };
    }

    // For the comparison job/area inputs we read/write through cmpDraft when the
    // comparison row is hidden, and through state.rows[1] when it's shown. This
    // lets the user pre-fill the comparison fields BEFORE clicking Add, and also
    // remembers what they had selected if they later remove and re-add the row.
    function getCmpJob()  { return state.rows[1] ? state.rows[1].jobId  : cmpDraft.jobId;  }
    function getCmpArea() { return state.rows[1] ? state.rows[1].areaId : cmpDraft.areaId; }
    function setCmpJob(v) {
      cmpDraft.jobId = v;
      if (state.rows[1]) state.rows[1].jobId = v;
      render();
    }
    function setCmpArea(v) {
      cmpDraft.areaId = v;
      if (state.rows[1]) state.rows[1].areaId = v;
      render();
    }

    const ts = {
      curJob:  mkJobInput ('cur-job',  () => state.rows[0].jobId,  v => { state.rows[0].jobId  = v; render(); }),
      curArea: mkAreaCombo('cur-area', state.rows[0].areaId,       v => { state.rows[0].areaId = v; render(); }),
      cmpJob:  mkJobInput ('cmp-job',  getCmpJob,                  setCmpJob),
      cmpArea: mkAreaCombo('cmp-area', cmpDraft.areaId,            setCmpArea),
    };

    // Rebuild the area dropdown to only include areas that have data for the given job.
    // Returns the resolved area id (may differ from input if the previous selection no
    // longer has data; caller should write back to state).
    function refreshAreaForJob(tomSelectInstance, jobId, currentAreaId) {
      const job = JOB_BY_ID[jobId];
      const validIds = new Set(job ? Object.keys(job.areas || {}) : AREAS.map(a => a.id));
      const valid = AREAS.filter(a => validIds.has(a.id));
      if (!valid.length) return currentAreaId; // defensive — shouldn't happen
      const fallback = valid.find(a => a.areatype === '01') || valid[0];
      const resolved = validIds.has(currentAreaId) ? currentAreaId : fallback.id;
      // Rebuild options
      tomSelectInstance.clear(true);
      tomSelectInstance.clearOptions();
      for (const a of valid) tomSelectInstance.addOption({ value: a.id, text: a.label });
      tomSelectInstance.refreshOptions(false);
      tomSelectInstance.addItem(resolved, true);
      return resolved;
    }

    // Track previous job ids so we only rebuild area options when the job actually
    // changes. Rebuilding on every render (e.g. when the user just picked a new area)
    // momentarily clears the .item display and shows a blank box.
    const lastJobIds = [null, null];

    function syncTopControls() {
      ts.curJob.refresh();
      if (state.rows[0].jobId !== lastJobIds[0]) {
        const r = refreshAreaForJob(ts.curArea, state.rows[0].jobId, state.rows[0].areaId);
        if (r !== state.rows[0].areaId) state.rows[0].areaId = r;
        lastJobIds[0] = state.rows[0].jobId;
      } else {
        ts.curArea.setValue(state.rows[0].areaId, true);
      }

      // Always keep the comparison job/area inputs in sync with cmpDraft/state[1]
      // so the user can prefill before clicking Add.
      ts.cmpJob.refresh();
      const cmpJobId  = getCmpJob();
      const cmpAreaId = getCmpArea();
      if (cmpJobId !== lastJobIds[1]) {
        const r = refreshAreaForJob(ts.cmpArea, cmpJobId, cmpAreaId);
        if (r !== cmpAreaId) {
          cmpDraft.areaId = r;
          if (state.rows[1]) state.rows[1].areaId = r;
        }
        lastJobIds[1] = cmpJobId;
      } else {
        ts.cmpArea.setValue(cmpAreaId, true);
      }

      const curSalEl = document.getElementById('cur-salary');
      curSalEl.value = state.userSalary != null ? '$' + state.userSalary.toLocaleString() : '';
      const cmpSal = effectiveCmpSalary();
      cmpSalaryEl.value = cmpSal != null ? '$' + cmpSal.toLocaleString() : '';
      cmpSalaryResetBtn.hidden = (state.cmpSalaryOverride == null);
      frameEl.classList.toggle('no-data', !(state.rows[0] && state.rows[0].jobId));
      syncCmpFlag();
    }

    document.getElementById('cur-salary').addEventListener('change', e => {
      const raw = e.target.value.trim();
      // Empty value clears the salary — the chart removes the red dot and the
      // percentile stat falls back to "—" with the "set salary above" sub.
      if (!raw) { state.userSalary = null; render(); return; }
      const n = parseInt(raw.replace(/[^0-9]/g, ''), 10);
      if (!isNaN(n) && n > 0) { state.userSalary = n; render(); }
      else e.target.value = state.userSalary != null ? '$' + state.userSalary.toLocaleString() : '';
    });

    const cmpSalaryEl       = document.getElementById('cmp-salary');
    const cmpSalaryResetBtn = document.getElementById('cmp-salary-reset');
    cmpSalaryEl.addEventListener('change', e => {
      const raw = e.target.value.trim();
      // Clearing the comparison box is equivalent to "reset to current" —
      // it drops the override and the field starts auto-following again.
      if (!raw) { state.cmpSalaryOverride = null; render(); return; }
      const n = parseInt(raw.replace(/[^0-9]/g, ''), 10);
      if (!isNaN(n) && n > 0) { state.cmpSalaryOverride = n; render(); }
      else {
        const cmpSal = effectiveCmpSalary();
        cmpSalaryEl.value = cmpSal != null ? '$' + cmpSal.toLocaleString() : '';
      }
    });
    cmpSalaryResetBtn.addEventListener('click', () => {
      state.cmpSalaryOverride = null;
      render();
    });

    document.getElementById('add-job').addEventListener('click', () => {
      if (state.rows.length >= 2) return;
      // Seed the comparison row with the current job's job + area. The user
      // will change it anyway, but starting from a valid combination guarantees
      // the comparison row renders real data immediately instead of a hidden
      // "no data" placeholder.
      cmpDraft.jobId  = state.rows[0].jobId;
      cmpDraft.areaId = state.rows[0].areaId;
      state.rows.push({ jobId: cmpDraft.jobId, areaId: cmpDraft.areaId, isYou: false });
      render();
    });

    // Help modal wiring — open on header button click, close on backdrop click,
    // × button, or Escape.
    (function () {
      const modal = document.getElementById('help-modal');
      const open  = () => { modal.classList.add('show'); modal.setAttribute('aria-hidden','false'); };
      const close = () => { modal.classList.remove('show'); modal.setAttribute('aria-hidden','true'); };
      document.getElementById('help-btn').addEventListener('click', open);
      modal.querySelector('.modal-close').addEventListener('click', close);
      modal.addEventListener('click', (e) => { if (e.target === modal) close(); });
      document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && modal.classList.contains('show')) close(); });
    })();

    // ------- 5. Domain computation -------
    function snap(n, step, dir) {
      return dir === 'down' ? Math.floor(n / step) * step : Math.ceil(n / step) * step;
    }
    function computeDomain() {
      const entries = state.rows.map(r => getEntry(r.jobId, r.areaId)).filter(Boolean);
      if (!entries.length) return { min: 30000, max: 100000, ticks: [30000, 50000, 70000, 90000] };
      // Include any explicit salaries so dots stay on-scale even when extreme.
      // Either may be null (no salary entered yet); filter those out before Math.min.
      const candidateSalaries = [state.userSalary];
      if (state.cmpSalaryOverride != null && state.rows.length >= 2) candidateSalaries.push(state.cmpSalaryOverride);
      const salaries = candidateSalaries.filter(s => s != null && !isNaN(s));
      const lo = Math.min(...entries.map(e => e.p10), ...salaries);
      const hi = Math.max(...entries.map(e => e.p90), ...salaries);
      const step = (hi - lo) > 80000 ? 20000 : 10000;
      const min = Math.max(0, snap(lo - step * 0.4, step, 'down'));
      const max = snap(hi + step * 0.3, step, 'up');
      const tickStep = (max - min) / 5;
      const ticks = [];
      for (let i = 0; i <= 5; i++) ticks.push(min + i * tickStep);
      return { min, max, ticks };
    }

    function approxPercentile(p, salary) {
      const pts = [[10,p.p10],[25,p.p25],[50,p.p50],[75,p.p75],[90,p.p90]];
      if (salary <= pts[0][1]) return '<10';
      if (salary >= pts[4][1]) return '>90';
      for (let i = 0; i < pts.length - 1; i++) {
        const [pa, va] = pts[i], [pb, vb] = pts[i+1];
        if (salary >= va && salary <= vb) {
          const t = (salary - va) / (vb - va);
          return Math.round(pa + t * (pb - pa));
        }
      }
      return '—';
    }

    // ------- 6. ECharts: custom percentile bar -------
    const charts = []; // track for disposal

    // Cache token colors once — reading them per renderItem call is expensive when ECharts repaints.
    const COL = (function () {
      // Read the design tokens from the tool's scoping container: when embedded in
      // the WordPress theme they live on .wage-embed, not :root/documentElement.
      const css = getComputedStyle(document.querySelector('.wage-embed') || document.documentElement);
      const g = (n) => css.getPropertyValue(n).trim();
      return {
        ink: g('--ink'), muted: g('--muted'), line: g('--line'),
        accent: g('--accent'), hi: g('--hi'),
        bandOuter: g('--band-outer'), bandInner: g('--band-inner'),
      };
    })();

    function renderPercentileItem(params, api) {
      const xPx = (v) => api.coord([v, 0])[0];
      const yPx = api.coord([api.value(0), 0])[1];
      const barH = 20;

      const p10 = api.value(1), p25 = api.value(2), p50 = api.value(3),
            p75 = api.value(4), p90 = api.value(5);
      const sal = api.value(6);

      // Plot-region bounds for the full-width baseline rail (drawn behind the band
      // so the band sits cleanly on top of it).
      const csys = params.coordSys;

      const showSal = sal != null && !isNaN(sal);
      const children = [
        // Light horizontal rail spanning the full domain — gives the band a baseline
        // and extends past it so values that fall outside the percentile range still
        // read as positioned on the same scale.
        { type: 'line',
          shape: { x1: csys.x, y1: yPx, x2: csys.x + csys.width, y2: yPx },
          style: { stroke: COL.line, lineWidth: 1 } },
        // 10–90 outer band — clear contrast vs white card
        { type: 'rect',
          shape: { x: xPx(p10), y: yPx - barH/2, width: xPx(p90) - xPx(p10), height: barH, r: 2 },
          style: { fill: COL.bandOuter } },
        // 25–75 inner band — distinct mid-navy so the median tick reads on top
        { type: 'rect',
          shape: { x: xPx(p25), y: yPx - barH/2 + 1.5, width: xPx(p75) - xPx(p25), height: barH - 3, r: 1.5 },
          style: { fill: COL.bandInner } },
        // Median tick — 3px wide, extends 4px past the bar on each side for emphasis
        { type: 'line',
          shape: { x1: xPx(p50), y1: yPx - barH/2 - 4, x2: xPx(p50), y2: yPx + barH/2 + 4 },
          style: { stroke: COL.ink, lineWidth: 3, lineCap: 'square' } },
      ];
      if (showSal) {
        const sx = xPx(sal);
        children.push(
          { type: 'circle',
            shape: { cx: sx, cy: yPx, r: 5.5 },
            style: { fill: COL.hi, stroke: '#fff', lineWidth: 2 } }
        );
      }
      return { type: 'group', children };
    }

    // Shared inset for the percentile-bar plot region so the bottom axis can render
    // its leftmost/rightmost tick labels without clipping ("$140K" needs ~18px).
    const PLOT_INSET_L = 4;
    const PLOT_INSET_R = 18;

    function mkPercentileBar(el, entry, domain, salary, salaryLabel) {
      salaryLabel = salaryLabel || 'Your salary';
      const c = echarts.init(el, 'vaWorks');
      charts.push(c);
      c.setOption({
        animation: false,
        grid: { top: 6, bottom: 6, left: PLOT_INSET_L, right: PLOT_INSET_R },
        xAxis: { type: 'value', min: domain.min, max: domain.max, show: false, splitLine: { show: false } },
        yAxis: { type: 'category', data: [''], show: false },
        tooltip: {
          appendToBody: true,
          trigger: 'item',
          formatter: () => {
            const fmt = (n) => '$' + Math.round(n).toLocaleString();
            const pct = salary != null ? approxPercentile(entry, salary) : null;
            return [
              '<b>Median</b> · ' + fmt(entry.p50),
              '<b>P25–75</b> · ' + fmt(entry.p25) + '–' + fmt(entry.p75),
              '<b>P10–90</b> · ' + fmt(entry.p10) + '–' + fmt(entry.p90),
              pct != null ? '<b>' + salaryLabel + '</b> · ' + fmt(salary) + ' (~' + pct + 'th pct)' : ''
            ].filter(Boolean).join('<br/>');
          },
        },
        series: [{
          type: 'custom',
          renderItem: renderPercentileItem,
          encode: { x: [1,2,3,4,5,6], y: 0, tooltip: [1,2,3,4,5,6] },
          data: [[0, entry.p10, entry.p25, entry.p50, entry.p75, entry.p90, salary != null ? salary : NaN]],
        }],
      });
      return c;
    }

    function mkSparkline(el, trend, opts) {
      opts = opts || {};
      const valid = trend.filter(v => v != null);
      if (valid.length < 1) {
        el.classList.add('empty');
        el.textContent = opts.emptyText || 'no data';
        return null;
      }
      const labels = opts.labels || TREND_YEARS.map(String);
      const fmt = opts.fmt || ((n) => '$' + Math.round(n).toLocaleString());
      const color = (opts.color || getComputedStyle(document.querySelector('.wage-embed') || document.documentElement).getPropertyValue('--accent')).trim();

      // Tight Y-axis scaling: pad by 10% of the actual data RANGE (not of absolute value).
      // Result: the line fills ~80% of vertical space regardless of how big the numbers
      // are, so a $72K→$89K rise looks just as expressive as a $25K→$33K rise.
      const minV = Math.min(...valid);
      const maxV = Math.max(...valid);
      const range = maxV - minV;
      const pad = range > 0 ? range * 0.10 : Math.max(1, maxV * 0.02);

      const c = echarts.init(el, 'vaWorks');
      charts.push(c);
      c.setOption({
        animation: false,
        grid: { top: 3, bottom: 3, left: 2, right: 6 },
        xAxis: { type: 'category', show: false, data: labels },
        yAxis: { type: 'value', show: false, min: minV - pad, max: maxV + pad },
        tooltip: {
          appendToBody: true,
          trigger: 'axis',
          formatter: (params) => {
            const p = params[0];
            return p.name + ' · ' + fmt(p.value);
          },
        },
        series: [{
          type: 'line', smooth: true, symbol: 'none',
          lineStyle: { width: 1.5, color, type: opts.dashed ? 'dashed' : 'solid' },
          data: trend,
          markPoint: {
            symbol: 'circle', symbolSize: 6,
            label: { show: false },
            itemStyle: { color },
            data: (() => {
              let lastIdx = -1;
              for (let i = trend.length - 1; i >= 0; i--) if (trend[i] != null) { lastIdx = i; break; }
              return lastIdx < 0 ? [] : [{ coord: [lastIdx, trend[lastIdx]] }];
            })(),
          },
        }],
      });
      return c;
    }

    // Employment data lookup. Returns { trend, scope } where scope is:
    //   'local'  → exact (job, area) match
    //   'state'  → Virginia statewide fallback when the MSA has no data
    //   null     → nothing for this job at all
    const EMP_MONTHS = (EMP && EMP.meta && EMP.meta.months) || [];
    // Statewide id comes from the data (areatype '01') — area ids are 6-digit
    // WID GEOGRAPHIES codes as of the SQL Server export. 'virginia' is the
    // legacy slug, kept only as a last-resort fallback for the example dataset.
    const STATE_AREA_ID = (AREAS.find(a => a.areatype === '01') || {}).id || 'virginia';
    function getEmploymentTrend(jobId, areaId) {
      if (!EMP || !EMP.trends) return { trend: null, scope: null };
      const local = EMP.trends[jobId + '__' + areaId];
      if (local) return { trend: local, scope: 'local' };
      if (areaId !== STATE_AREA_ID) {
        const statewide = EMP.trends[jobId + '__' + STATE_AREA_ID];
        if (statewide) return { trend: statewide, scope: 'state' };
      }
      return { trend: null, scope: null };
    }

    function mkAxis(el, domain) {
      const c = echarts.init(el, 'vaWorks');
      charts.push(c);
      c.setOption({
        animation: false,
        // Same inset as percentile bars so ticks align with the bars above AND
        // the leftmost/rightmost labels have room to render without being clipped.
        grid: { top: 0, bottom: 18, left: PLOT_INSET_L, right: PLOT_INSET_R },
        xAxis: {
          type: 'value', min: domain.min, max: domain.max,
          axisLine: { lineStyle: { color: COL.line } },
          axisTick: { lineStyle: { color: COL.muted }, length: 4 },
          axisLabel: {
            color: COL.ink,
            fontFamily: 'JetBrains Mono, ui-monospace, monospace',
            fontSize: 11,
            fontWeight: 500,
            formatter: (v) => '$' + Math.round(v / 1000) + 'K',
            hideOverlap: true,
            margin: 6,
          },
          splitLine: { show: false },
          interval: (domain.max - domain.min) / 5,
        },
        yAxis: { type: 'category', show: false, data: [''] },
        series: [],
      });
      return c;
    }

    // ------- 7. Row rendering -------
    // Format approxPercentile output as a display label: "58th", "<10th", ">90th".
    function fmtPctLabel(entry, salary) {
      const v = approxPercentile(entry, salary);
      if (v === '<10') return '<10th';
      if (v === '>90') return '>90th';
      if (v === '—' || v == null) return '—';
      return v + 'th';
    }

    function renderRow(row, domain) {
      const entry = getEntry(row.jobId, row.areaId);
      const job   = JOB_BY_ID[row.jobId];
      const area  = AREA_BY_ID[row.areaId];
      const wrap  = document.createElement('div');
      wrap.className = 'row-card ' + (row.isYou ? 'you' : 'cmp');

      const tag = row.isYou ? 'Your role' : 'Comparison';
      const occHtml =
        '<div class="row-occ">' +
          '<div class="role-tag">' + tag + '</div>' +
          '<div class="row-job">' + (job ? job.label : '—') + '</div>' +
          '<div class="row-area">' + (area ? area.label : '—') + '</div>' +
        '</div>';

      // No-data card: same tag/job/area block + message; × button still placed on the comparison row.
      if (!entry) {
        wrap.innerHTML =
          '<div class="row-top" style="grid-template-columns: minmax(160px, 1.5fr) 1fr 24px;">' +
            occHtml +
            '<div style="font-size:11px; color: var(--muted); padding-top: 8px;">No data for this occupation × area.</div>' +
            '<div class="row-actions" data-role="actions"></div>' +
          '</div>';
        if (!row.isYou) {
          const slot = wrap.querySelector('[data-role=actions]');
          const x = document.createElement('button');
          x.className = 'row-remove'; x.textContent = '×';
          x.title = 'Remove comparison job';
          x.setAttribute('aria-label', 'Remove comparison job');
          x.onclick = () => {
            const idx = state.rows.indexOf(row);
            if (idx > 0) { state.rows.splice(idx, 1); render(); }
          };
          slot.appendChild(x);
        }
        return wrap;
      }

      // Each row plots its own salary dot. The comparison row uses the override
      // when present so the user can model a target wage in the other occupation.
      // Either may be null when the user has yet to enter a salary; renderItem
      // suppresses the dot in that case and the percentile stat shows "—".
      const dotSalary = row.isYou ? state.userSalary : effectiveCmpSalary();
      const haveSalary = dotSalary != null;
      const cmpOverridden = !row.isYou
        && state.cmpSalaryOverride != null
        && state.cmpSalaryOverride !== state.userSalary;

      // Stat values
      const medianStr = '$' + Math.round(entry.p50 / 1000) + 'K';
      const pctStr   = haveSalary ? fmtPctLabel(entry, dotSalary) : '—';

      // Comparison row: Median sub = delta vs YOUR ROLE's median, color-coded green/red.
      let medianSub = 'annual';
      let medianSubCls = '';
      if (!row.isYou) {
        const youEntry = getEntry(state.rows[0].jobId, state.rows[0].areaId);
        if (youEntry) {
          const delta = entry.p50 - youEntry.p50;
          const k = Math.round(Math.abs(delta) / 1000);
          if (delta > 0)      { medianSub = '+$' + k + 'K vs you'; medianSubCls = 'pos'; }
          else if (delta < 0) { medianSub = '-$' + k + 'K vs you'; medianSubCls = 'neg'; }
          else                { medianSub = 'same as you'; }
        }
      }

      // Percentile-block label/sub. Four modes:
      //   • Salary not yet entered → generic label + nudge to fill it in.
      //   • You row → "Your percentile / within your role"
      //   • Comparison, no override (or override equals current) → "If you stayed at $X / within this role"
      //   • Comparison with override ≠ current → neutral "At $X / in [role]"
      //     so the framing matches what the dot now represents (a hypothetical target).
      let pctLabel, pctSub;
      if (!haveSalary) {
        pctLabel = row.isYou ? 'Your percentile' : 'Comparison';
        pctSub   = 'enter salary above';
      } else if (row.isYou) {
        pctLabel = 'Your percentile';
        pctSub = 'within your role';
      } else if (cmpOverridden) {
        pctLabel = 'At $' + Math.round(dotSalary / 1000) + 'K';
        pctSub   = 'in ' + (job ? job.label : 'this role');
      } else {
        pctLabel = 'If you stayed at $' + Math.round(state.userSalary / 1000) + 'K';
        pctSub   = 'within this role';
      }

      wrap.innerHTML =
        '<div class="row-top">' +
          occHtml +
          '<div class="stat-block stat-median">' +
            '<div class="stat-label">Median</div>' +
            '<div class="stat-value">' + medianStr + '</div>' +
            '<div class="stat-sub ' + medianSubCls + '">' + medianSub + '</div>' +
          '</div>' +
          '<div class="stat-block stat-pct">' +
            '<div class="stat-label">' + pctLabel + '</div>' +
            '<div class="stat-value">' + pctStr + '</div>' +
            '<div class="stat-sub">' + pctSub + '</div>' +
          '</div>' +
          '<div class="stat-block stat-spark stat-wage">' +
            '<div class="stat-label">Wage trend<span class="stat-label-sub">5-yr</span></div>' +
            '<div class="sparkline" data-role="wage-spark"></div>' +
          '</div>' +
          '<div class="stat-block stat-spark stat-emp">' +
            '<div class="stat-label">Employment<span class="stat-label-sub">24 mo.</span></div>' +
            '<div class="sparkline" data-role="emp-spark"></div>' +
          '</div>' +
          '<div class="row-actions" data-role="actions"></div>' +
        '</div>' +
        '<div class="pct-bar" data-role="pct-bar"></div>';

      if (!row.isYou) {
        const slot = wrap.querySelector('[data-role=actions]');
        const x = document.createElement('button');
        x.className = 'row-remove'; x.textContent = '×';
        x.title = 'Remove comparison job';
        x.setAttribute('aria-label', 'Remove comparison job');
        x.onclick = () => {
          const idx = state.rows.indexOf(row);
          if (idx > 0) { state.rows.splice(idx, 1); render(); }
        };
        slot.appendChild(x);
      }

      // Defer chart mounting until after row is in the DOM so ECharts can measure containers.
      wrap._mount = () => {
        mkPercentileBar(wrap.querySelector('[data-role=pct-bar]'),
                        entry, domain, dotSalary,
                        row.isYou ? 'Your salary' : 'Comparison salary');
        mkSparkline(wrap.querySelector('[data-role=wage-spark]'), entry.trend, {
          labels: TREND_YEARS.map(String),
          fmt: (n) => '$' + Math.round(n).toLocaleString(),
          emptyText: 'no trend',
        });
        // Employment trend: chosen area first, fall back to VA statewide (dashed line + prefixed tooltip).
        const emp = getEmploymentTrend(row.jobId, row.areaId);
        const prefix = emp.scope === 'state' ? 'VA statewide · ' : '';
        mkSparkline(wrap.querySelector('[data-role=emp-spark]'),
                    emp.trend || new Array(EMP_MONTHS.length || 0).fill(null), {
          labels: EMP_MONTHS,
          fmt: (n) => prefix + Math.round(n).toLocaleString() + ' jobs',
          color: '#1f7a4d',
          dashed: emp.scope === 'state',
          emptyText: EMP ? 'no data' : 'pending',
        });
      };
      return wrap;
    }

    // Render the empty-state card when no job has been picked yet.
    // Prompts the user toward the search above + offers one-click demo jobs
    // (Sales Associate / Registered Nurses by default; falls back to top
    //  two by employment if those SOCs aren't in the loaded data).
    function renderEmptyState() {
      const container = document.getElementById('rows-container');
      container.innerHTML = '';
      const axisEl = document.getElementById('axis-chart');
      axisEl.innerHTML = '';

      const card = document.createElement('div');
      card.className = 'row-card empty-card';
      card.innerHTML =
        '<div class="empty-arrow" aria-hidden="true">↑</div>' +
        '<div class="empty-heading">Type a job above to see wage data</div>' +
        '<div class="empty-sub">or try one of these</div>' +
        '<div class="empty-chips" data-role="chips"></div>';
      container.appendChild(card);

      // Pick demo jobs. Prefer Retail Salespersons + Registered Nurses (covers
      // low- and mid-wage spectrum). Fall back to top-2-by-employment if those
      // SOCs aren't present in the loaded dataset.
      const preferred = ['41-2031', '29-1141'];
      let demos = preferred.map(id => JOB_BY_ID[id]).filter(Boolean);
      if (demos.length < 2) {
        const byEmp = JOB_INDEX.slice()
          .sort((a, b) => b.employment - a.employment)
          .slice(0, 2)
          .map(ix => ix.job)
          .filter(j => !demos.includes(j));
        demos = demos.concat(byEmp).slice(0, 2);
      }

      const chipsEl = card.querySelector('[data-role=chips]');
      demos.forEach(j => {
        const btn = document.createElement('button');
        btn.className = 'demo-chip';
        btn.type = 'button';
        btn.textContent = j.label;
        btn.addEventListener('click', () => {
          state.rows[0].jobId = j.id;
          render();
        });
        chipsEl.appendChild(btn);
      });
    }

    // ------- 8. Top-level render -------
    function render() {
      // Dispose old charts
      charts.splice(0).forEach(c => { try { c.dispose(); } catch(_) {} });

      syncTopControls();

      // Empty state: no YOUR ROLE job picked yet. Skip the chart pipeline
      // entirely and render a prompt card; the axis-chart + legend-row are
      // hidden via .frame.no-data set in syncTopControls.
      if (!(state.rows[0] && state.rows[0].jobId)) {
        renderEmptyState();
        return;
      }

      const domain = computeDomain();
      const container = document.getElementById('rows-container');
      container.innerHTML = '';
      const built = state.rows.map(r => renderRow(r, domain));
      built.forEach(el => container.appendChild(el));
      // mount charts after layout
      requestAnimationFrame(() => {
        built.forEach(el => el._mount && el._mount());
        const axisEl = document.getElementById('axis-chart');
        axisEl.innerHTML = '';
        mkAxis(axisEl, domain);
      });
    }

    // Handle resize for ECharts instances
    window.addEventListener('resize', () => charts.forEach(c => { try { c.resize(); } catch(_) {} }));

    render();
    // Land the cursor in the search box so the focus-helper + dropdown are
    // immediately discoverable. Skipped if the user has already begun typing
    // somewhere else by the time this runs.
    if (document.activeElement === document.body) {
      document.getElementById('cur-job').focus();
    }
  })();
