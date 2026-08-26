import {
  Activity,
  BarChart3,
  BellRing,
  FileSearch,
  Filter,
  Headphones,
  LayoutDashboard,
  LogOut,
  Menu,
  Moon,
  NotebookTabs,
  RefreshCw,
  Search,
  Settings,
  Sparkles,
  Sun,
  Users,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import LoginPage from "./components/LoginPage.jsx";
import { ViewRouter } from "./components/ReportViews.jsx";
import { config, supabaseConfigured } from "./config.js";
import { demoForPage } from "./demo.js";
import { useAutoRefresh } from "./hooks/useAutoRefresh.js";
import { loadFilterOptions, loadReportPage } from "./lib/reportApi.js";
import { supabase } from "./lib/supabase.js";

const navigation = [
  ["overview", "Overview", LayoutDashboard],
  ["team", "Team", Users],
  ["calls", "Calls & AI", Headphones],
  ["notes", "Notes", NotebookTabs],
  ["leads", "Leads", Activity],
  ["csv", "CSV lead filter", FileSearch],
  ["teacher", "AI teacher review", Sparkles],
  ["settings", "Connections", Settings],
];

function easternDateKey(value = new Date()) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(value);
  const byType = Object.fromEntries(parts.map(({ type, value: part }) => [type, part]));
  return `${byType.year}-${byType.month}-${byType.day}`;
}

const today = easternDateKey();
const initialFilters = {
  from: `${today.slice(0, 8)}01`,
  to: today,
  dateBasis: "activity",
  status: "",
  agent: "",
  vendor: "",
  leadType: "",
  state: "",
  city: "",
  appointmentType: "",
  sourceDescription: "",
  addressQuality: "",
  emailStatus: "",
  aiReview: "",
  recording: "",
  search: "",
};

const defaultOptions = { statuses: [], agents: [], vendors: [], lead_types: [], states: [], cities: [], source_descriptions: [] };

function FilterPanel({ draft, setDraft, apply, options, open, setOpen }) {
  const select = (label, field, choices, allLabel) => <label>{label}<select value={draft[field]} onChange={(event) => setDraft({ ...draft, [field]: event.target.value })}><option value="">{allLabel}</option>{(choices || []).map((choice) => {
    const id = typeof choice === "object" ? choice.value ?? choice.id ?? choice.name : choice;
    const text = typeof choice === "object" ? choice.label ?? choice.name ?? choice.value : choice;
    return <option key={id} value={id}>{text}</option>;
  })}</select></label>;
  const setRange = (days, month = false) => {
    const end = easternDateKey();
    const startDate = new Date(`${end}T12:00:00`);
    if (month) startDate.setDate(1); else startDate.setDate(startDate.getDate() - days);
    setDraft({ ...draft, from: easternDateKey(startDate), to: end });
  };
  return <section className="filter-card">
    <div className="filter-heading"><div><Filter size={16} /><strong>Filters</strong><span>Organized once and shared across every report page</span></div><button className="button ghost" onClick={() => setOpen(!open)}>{open ? "Hide filters" : "Show filters"}</button></div>
    {open && <><div className="quick-filters"><button onClick={() => setRange(0)}>Today</button><button onClick={() => setRange(1)}>Yesterday + today</button><button onClick={() => setRange(6)}>Last 7 days</button><button onClick={() => setRange(0, true)}>This month</button><button onClick={() => setDraft({ ...initialFilters })}>Reset filters</button></div><div className="filter-grid expanded">
      <label>From<input type="date" value={draft.from} onChange={(event) => setDraft({ ...draft, from: event.target.value })} /></label>
      <label>To<input type="date" value={draft.to} onChange={(event) => setDraft({ ...draft, to: event.target.value })} /></label>
      <label>Date basis<select value={draft.dateBasis} onChange={(event) => setDraft({ ...draft, dateBasis: event.target.value })}><option value="activity">Activity / updated date</option><option value="created">Created date</option></select></label>
      {select("Status", "status", options.statuses, "All statuses")}
      {select("Agent", "agent", options.agents, "All agents")}
      {select("Vendor", "vendor", options.vendors, "All vendors")}
      {select("Lead type", "leadType", options.lead_types, "All lead types")}
      {select("State", "state", options.states, "All states")}
      {select("City", "city", options.cities, "All cities")}
      {select("Appointment type from note", "appointmentType", ["In person", "Phone call", "Virtual", "Other / unclear", "Not provided"], "All appointment types")}
      {select("Original lead description", "sourceDescription", options.source_descriptions, "All descriptions")}
      {select("Live lead address", "addressQuality", [{ value: "complete", label: "Complete city and ZIP" }, { value: "missing_city_or_zip", label: "Missing city or ZIP" }, { value: "missing_city", label: "Missing city" }, { value: "missing_zip", label: "Missing ZIP" }], "All live/address records")}
      {select("Live email", "emailStatus", [{ value: "sent", label: "Email sent" }, { value: "not_sent", label: "Email not sent" }], "All email statuses")}
      {select("AI call review", "aiReview", [{ value: "completed", label: "AI reviewed" }, { value: "needs_review", label: "Needs manager review" }, { value: "not_reviewed", label: "Not reviewed" }], "All AI statuses")}
      {select("Recording", "recording", [{ value: "available", label: "Recording available" }, { value: "missing", label: "Recording missing" }], "All recorded calls")}
      <label className="search-field">Search<div><Search size={15} /><input value={draft.search} onChange={(event) => setDraft({ ...draft, search: event.target.value })} placeholder="Name, phone, email, lead ID" onKeyDown={(event) => { if (event.key === "Enter") apply(); }} /></div></label>
    </div><div className="filter-footer"><span>Filters change only when you click Apply, so typing does not repeatedly query Supabase.</span><button className="button primary" onClick={apply}>Apply filters</button></div></>}
  </section>;
}

function ConnectionsView({ session, preview }) {
  const items = [
    ["Supabase Auth", preview || Boolean(session), "One login for the entire website"],
    ["Supabase report API", supabaseConfigured, "RLS-protected database functions"],
    ["Private Worker bridge", Boolean(config.workerUrl), "Recording playback and AI commands only"],
    ["D1 synchronization", true, "Continues in the existing background Worker"],
  ];
  return <div className="connections-grid">{items.map(([label, ok, note]) => <article className="panel connection-card" key={label}><span className={ok ? "connection-state ok-state" : "connection-state warning-state"}>{ok ? "Connected" : "Needs setup"}</span><h3>{label}</h3><p>{note}</p></article>)}</div>;
}

export default function App() {
  const preview = config.demoMode || (!supabaseConfigured && import.meta.env.DEV);
  const initialPage = window.location.hash.replace(/^#\/?/, "") || "overview";
  const [page, setPageState] = useState(navigation.some(([key]) => key === initialPage) ? initialPage : "overview");
  const [session, setSession] = useState(null);
  const [authReady, setAuthReady] = useState(preview);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [filtersOpen, setFiltersOpen] = useState(true);
  const [dark, setDark] = useState(() => localStorage.getItem("ricochet-theme") === "dark");
  const [autoRefresh, setAutoRefresh] = useState(() => localStorage.getItem("ricochet-auto-refresh") !== "false");
  const [draftFilters, setDraftFilters] = useState(initialFilters);
  const [filters, setFilters] = useState(initialFilters);
  const [options, setOptions] = useState(defaultOptions);
  const [pagination, setPagination] = useState({ page: 1, pageSize: 50 });
  const [data, setData] = useState(() => preview ? demoForPage("overview") : null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [lastUpdated, setLastUpdated] = useState(null);
  const [toast, setToastState] = useState(null);

  const setPage = (next) => {
    setPageState(next); setSidebarOpen(false); setPagination({ page: 1, pageSize: 50 }); setData(null); setError("");
    window.history.pushState(null, "", `${window.location.pathname}${window.location.search}#/${next}`);
  };
  const title = useMemo(() => navigation.find(([key]) => key === page)?.[1] ?? "Overview", [page]);
  const setToast = useCallback((message, isError = false) => {
    setToastState({ message, isError });
    window.setTimeout(() => setToastState(null), 4500);
  }, []);

  useEffect(() => {
    if (!supabase) return undefined;
    supabase.auth.getSession().then(({ data: auth }) => { setSession(auth.session); setAuthReady(true); });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, nextSession) => { setSession(nextSession); setAuthReady(true); });
    return () => listener.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    const syncRoute = () => {
      const next = window.location.hash.replace(/^#\/?/, "") || "overview";
      if (navigation.some(([key]) => key === next)) { setPageState(next); setPagination({ page: 1, pageSize: 50 }); setData(null); setError(""); }
    };
    window.addEventListener("hashchange", syncRoute);
    window.addEventListener("popstate", syncRoute);
    return () => { window.removeEventListener("hashchange", syncRoute); window.removeEventListener("popstate", syncRoute); };
  }, []);

  useEffect(() => { localStorage.setItem("ricochet-theme", dark ? "dark" : "light"); }, [dark]);
  useEffect(() => { localStorage.setItem("ricochet-auto-refresh", String(autoRefresh)); }, [autoRefresh]);

  const load = useCallback(async ({ background = false, force = false } = {}) => {
    if (["csv", "settings"].includes(page)) return;
    if (!background) { setLoading(true); setData(null); }
    setError("");
    try {
      const next = preview ? demoForPage(page) : await loadReportPage(page, filters, pagination, { bypassCache: background || force });
      setData(next); setLastUpdated(new Date());
    } catch (cause) { setError(cause.message); if (background) setToast(cause.message, true); }
    finally { if (!background) setLoading(false); }
  }, [filters, page, pagination, preview, setToast]);

  useEffect(() => { if (preview || session) load(); }, [load, preview, session]);
  useEffect(() => {
    if (preview || !session) return;
    loadFilterOptions(filters.from, filters.to).then((next) => setOptions({ ...defaultOptions, ...next })).catch(() => {});
  }, [filters.from, filters.to, preview, session]);

  const remaining = useAutoRefresh({ enabled: autoRefresh && Boolean(preview || session) && !["csv", "settings"].includes(page), seconds: config.autoRefreshSeconds, onRefresh: load });
  const applyFilters = () => {
    if (!draftFilters.from || !draftFilters.to) { setToast("Choose both dates.", true); return; }
    if (draftFilters.from > draftFilters.to) { setToast("The From date must be before the To date.", true); return; }
    setPagination({ page: 1, pageSize: 50 }); setFilters({ ...draftFilters });
  };
  const signOut = async () => { if (supabase) await supabase.auth.signOut(); };

  if (!authReady) return <div className="app-loading"><RefreshCw className="spin" />Loading secure session…</div>;
  if (!preview && !session) return <LoginPage setupMissing={!supabaseConfigured} />;

  return <div className={dark ? "app theme-dark" : "app"}>
    <aside className={sidebarOpen ? "sidebar sidebar-open" : "sidebar"}>
      <div className="brand"><div className="brand-mark"><BarChart3 size={18} /></div><div><strong>Ricochet</strong><span>Reporting workspace</span></div></div>
      <div className="nav-label">Workspace</div><nav>{navigation.map(([key, label, Icon]) => <button key={key} className={page === key ? "nav-item active" : "nav-item"} onClick={() => setPage(key)}><Icon size={17} /><span>{label}</span></button>)}</nav>
      <div className="sidebar-footer"><div className="connection-dot"><span /> {preview ? "Preview data" : "Supabase connected"}</div>{!preview && <button className="nav-item" onClick={signOut}><LogOut size={17} /><span>Sign out</span></button>}</div>
    </aside>

    <main className="main-shell">
      <header className="topbar"><button className="icon-button mobile-menu" onClick={() => setSidebarOpen(!sidebarOpen)} aria-label="Open navigation"><Menu size={19} /></button><div className="page-heading"><h1>{title}</h1><p>Supabase reporting with private AI and recording actions.</p></div><div className="top-actions"><button className={autoRefresh ? "auto-status on" : "auto-status"} onClick={() => setAutoRefresh(!autoRefresh)} title="Toggle automatic refresh"><BellRing size={14} /><span>{autoRefresh ? `Refresh in ${remaining}s` : "Auto refresh off"}</span></button><button className="button secondary" disabled={loading || ["csv", "settings"].includes(page)} onClick={() => load({ force: true })}><RefreshCw className={loading ? "spin" : ""} size={15} />Refresh</button><button className="icon-button" onClick={() => setDark(!dark)} aria-label="Toggle dark mode">{dark ? <Sun size={17} /> : <Moon size={17} />}</button><div className="avatar">{preview ? "DE" : String(session?.user?.email || "U").slice(0, 2).toUpperCase()}</div></div></header>
      <section className="content">
        {!['csv','settings'].includes(page) && <FilterPanel draft={draftFilters} setDraft={setDraftFilters} apply={applyFilters} options={options} open={filtersOpen} setOpen={setFiltersOpen} />}
        {preview && <div className="preview-banner">Visual preview data is active. Add the GitHub repository variables and run the Supabase SQL before publishing.</div>}
        {error && <div className="error-box page-error"><X size={17} /><span>{error}</span><button onClick={() => load()}>Try again</button></div>}
        {loading ? <div className="loading-panel"><RefreshCw className="spin" /><strong>Loading {title.toLowerCase()}…</strong><span>Directly from secured Supabase report functions</span></div> : page === "settings" ? <ConnectionsView session={session} preview={preview} /> : <ViewRouter page={page} data={data || {}} pagination={pagination} setPagination={setPagination} setToast={setToast} />}
        <footer className="report-footer"><span>Data: Supabase · Sync source: D1</span><span>{lastUpdated ? `Updated ${lastUpdated.toLocaleTimeString()}` : "Waiting for first refresh"}</span></footer>
      </section>
    </main>
    {sidebarOpen && <button className="sidebar-scrim" onClick={() => setSidebarOpen(false)} aria-label="Close navigation" />}
    {toast && <div className={toast.isError ? "toast toast-error" : "toast"}>{toast.message}</div>}
  </div>;
}
