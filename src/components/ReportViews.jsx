import { Bot, CheckCircle2, Download, FileUp, Headphones, Search, Sparkles, TriangleAlert, Users } from "lucide-react";
import { useMemo, useState } from "react";
import { parseLeadCsv, downloadCsv } from "../lib/csv.js";
import { loadCsvCallDetails, matchCsvRows, runAiAction } from "../lib/reportApi.js";
import AudioPlayer from "./AudioPlayer.jsx";

const number = (value, digits = 0) => Number(value || 0).toLocaleString(undefined, { maximumFractionDigits: digits });
const duration = (seconds) => {
  const total = Math.max(0, Number(seconds || 0));
  const minutes = Math.floor(total / 60);
  return minutes ? `${minutes}m ${Math.floor(total % 60)}s` : `${Math.floor(total)}s`;
};
const longDuration = (seconds) => {
  const total = Math.max(0, Math.floor(Number(seconds || 0)));
  const hours = Math.floor(total / 3600); const minutes = Math.floor((total % 3600) / 60); const secs = total % 60;
  return hours ? `${hours}h ${minutes}m ${secs}s` : duration(total);
};
const value = (item, ...keys) => keys.map((key) => item?.[key]).find((candidate) => candidate !== undefined && candidate !== null && candidate !== "") ?? "—";
const fullName = (row) => [row.first_name, row.last_name].filter(Boolean).join(" ") || "Unknown lead";
const cleanNoteText = (text) => String(text || "").replace(/\r/g, "").trim();
const noteKey = (note) => String(note.ricochet_note_id || note.note_sequence || cleanNoteText(note.note_text).toLowerCase().slice(0, 100));
const formatNoteTime = (input) => {
  if (!input) return "Time unavailable";
  const parsed = new Date(input);
  return Number.isNaN(parsed.getTime()) ? String(input) : parsed.toLocaleString(undefined, { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
};

function parseHistoricalNotes(raw) {
  return cleanNoteText(raw).split(/\s*-{4,}\s*/).map((block, index) => {
    const lines = block.split("\n").map((line) => line.trim()).filter(Boolean);
    let sequence = index + 1; let ricochet_note_id = ""; let note_user_email = ""; let note_user_id = ""; const body = [];
    for (const line of lines) {
      const sequenceMatch = line.match(/^Note\s+(\d+)\s*$/i); if (sequenceMatch) { sequence = Number(sequenceMatch[1]); continue; }
      const userMatch = line.match(/^User:\s*(.+)$/i); if (userMatch) { note_user_email = userMatch[1].trim(); continue; }
      const userIdMatch = line.match(/^User\s*ID:\s*(.+)$/i); if (userIdMatch) { note_user_id = userIdMatch[1].trim(); continue; }
      const noteIdMatch = line.match(/^Note\s*ID:\s*(.+)$/i); if (noteIdMatch) { ricochet_note_id = noteIdMatch[1].trim(); continue; }
      body.push(line);
    }
    return { note_sequence: sequence, ricochet_note_id, note_user_email, note_user_id, note_user_name: note_user_email ? note_user_email.split("@")[0].replace(/[._]+/g, " ") : "", note_text: body.join("\n"), historical_fallback: true };
  }).filter((note) => cleanNoteText(note.note_text) || note.ricochet_note_id).sort((a, b) => Number(b.note_sequence || 0) - Number(a.note_sequence || 0));
}

function mergedNotes(row) {
  const structured = (row.note_items || []).map((note) => ({ ...note, note_text: cleanNoteText(note.note_text) }));
  const known = new Set(structured.map(noteKey));
  const fallback = parseHistoricalNotes(row.note_text).filter((note) => !known.has(noteKey(note)));
  const combined = [...structured, ...fallback].sort((a, b) => Number(b.note_sequence || 0) - Number(a.note_sequence || 0) || String(b.note_time || "").localeCompare(String(a.note_time || "")));
  const latestText = cleanNoteText(row.latest_note);
  if (latestText && !combined.some((note) => cleanNoteText(note.note_text) === latestText)) combined.unshift({ note_sequence: Number.MAX_SAFE_INTEGER, note_text: latestText, note_user_name: row.note_user_name, note_user_email: row.note_user_email, note_time: row.note_created_at, call_uuid: (row.recordings || []).find((call) => call.exact_match)?.call_uuid, call_date_time: (row.recordings || []).find((call) => call.exact_match)?.call_date_time });
  return combined;
}

function displayedLeadType(row, notes = []) {
  const text = cleanNoteText(row.latest_note || notes[0]?.note_text || row.note_text).toLowerCase();
  const sellerForm = /(^|\s)seller form(\s|$)/i.test(text) || text.includes("seller motivation and financials") || text.includes("why selling now:");
  const buyerForm = /(^|\s)buyer form(\s|$)/i.test(text) || text.includes("primary reason for buying now:") || text.includes("target move-in date");
  const buyerIntent = /(want|wants|wanted|need|needs|plan|plans|planning|looking|ready|hoping)\s+to\s+(buy|purchase)/i.test(text) || /(buying|purchasing)\s+(another|a|their|his|her)\s+(home|house|property)/i.test(text) || /home to sell first.{0,40}(yes|true)/i.test(text);
  const sellerIntent = /(want|wants|wanted|need|needs|plan|plans|planning|looking|ready|consider|considering)\s+to\s+sell/i.test(text) || sellerForm;
  if ((sellerForm && buyerIntent) || (buyerForm && sellerIntent) || (buyerIntent && sellerIntent)) return "Buyer and Seller";
  if (sellerForm || sellerIntent) return "Seller";
  if (buyerForm || buyerIntent) return "Buyer";
  return value(row, "lead_type");
}

function Empty({ message }) { return <div className="empty"><Search size={22} /><strong>No matching data</strong><span>{message}</span></div>; }
function ErrorBox({ message }) { return message ? <div className="error-box"><TriangleAlert size={17} />{message}</div> : null; }
function Pager({ data, page, setPage }) {
  const total = Number(data?.total || 0); const size = Number(data?.page_size || 50); const pages = Math.max(1, Math.ceil(total / size));
  return <div className="pager"><span>{number(total)} rows · Page {page} of {pages}</span><div><button className="button secondary" disabled={page <= 1} onClick={() => setPage(page - 1)}>Previous</button><button className="button secondary" disabled={page >= pages} onClick={() => setPage(page + 1)}>Next</button></div></div>;
}

export function OverviewView({ data }) {
  const totals = data?.totals || {};
  const cards = [
    ["Leads received", totals.leads_received, "Created inside the selected range", "blue"],
    ["Activity cohort", totals.activity_cohort, "Updated or active in range", "blue"],
    ["Worked leads", totals.worked_leads, "Qualifying call or new note", "green"],
    ["Untouched received", totals.untouched_received, "Received without qualifying work", "gold"],
    ["Handled calls", totals.handled_calls, "Identified calls of at least 6 seconds", "green"],
    ["Live leads sent", totals.live_leads_sent, "First live status + email sent", "green"],
    ["Live emails sent", totals.live_emails_sent, "Passed note check and sent", "mint"],
    ["Contact rate", `${number(totals.contact_rate, 1)}%`, `${number(totals.contacted_leads)} reached (2.x)`, "green"],
    ["Calls logged", totals.calls_logged, `${number(totals.handled_calls)} handled calls`, "slate"],
    ["Notes added", totals.notes_added, `${number(totals.leads_with_notes)} leads received notes`, "violet"],
    ["Phone appointments", totals.live_phone_appointments, "Live phone appointment type", "green"],
    ["In-person appointments", totals.live_in_person_appointments, "Live in-person appointment type", "green"],
    ["Other appointments", totals.other_live_appointments, "Virtual, unclear, or other", "slate"],
    ["AI reviewed", totals.ai_reviewed, "Reviewed calls in selected range", "gold"],
    ["Average AI score", totals.average_ai_score ? number(totals.average_ai_score, 1) : "—", "Reviewed calls only", "gold"],
    ["Needs attention", totals.needs_attention, "Status or note mismatch", "gold"],
  ];
  const statuses = data?.status_breakdown || [];
  const max = Math.max(1, ...statuses.map((row) => Number(row.count || 0)));
  return <>
    <div className="hero-row"><div><span className="eyebrow">Daily command center</span><h2>Your lead operation at a glance</h2><p>Live means the lead first received a live/appointment status in range and its email passed the note check and was sent.</p></div></div>
    <div className="metric-grid">{cards.map(([label, amount, note, tone]) => <article className={`metric-card ${tone}`} key={label}><span>{label}</span><strong>{typeof amount === "number" ? number(amount, 1) : amount ?? 0}</strong><small>{note}</small></article>)}</div>
    <article className="panel pipeline-panel"><div className="panel-heading"><div><span className="eyebrow">Status pipeline</span><h3>Where selected leads ended up</h3></div><span className="subtle">{number(statuses.reduce((sum, row) => sum + Number(row.count || 0), 0))} selected</span></div><div className="pipeline">{statuses.map((row) => <i key={row.status} title={`${row.status}: ${number(row.count)}`} style={{ flex: Math.max(0, Number(row.count || 0)) }} />)}</div><div className="pipeline-legend">{statuses.map((row) => <span key={row.status}>{row.status} <b>{number(row.count)}</b></span>)}</div></article>
    <div className="dashboard-grid"><article className="panel wide"><div className="panel-heading"><div><span className="eyebrow">Pipeline detail</span><h3>Selected, worked, and calls by status</h3></div></div>
      <div className="status-list">{statuses.slice(0, 14).map((row) => <div className="status-row detailed" key={row.status}><span>{row.status || "Unknown"}</span><div><i style={{ width: `${Math.max(2, Number(row.count || 0) / max * 100)}%` }} /></div><b>{number(row.count)} selected · {number(row.worked)} worked · {number(row.calls)} calls</b></div>)}</div>
    </article><article className="panel"><div className="panel-heading"><div><span className="eyebrow">Counting rules</span><h3>Trusted definitions</h3></div></div><ul className="definition-list"><li><CheckCircle2 />Received uses created date.</li><li><CheckCircle2 />Worked requires a qualifying call or new note.</li><li><CheckCircle2 />Live excludes old live leads merely called today.</li><li><CheckCircle2 />Inbound types 7 and 10 count only when a recording/transcript exists.</li></ul></article></div>
    <div className="metric-grid compact-metrics">{[["Converted",totals.converted,"3.x statuses"],["Follow ups",totals.follow_ups,"Status 2.0"],["Not interested",totals.not_interested,"Status 2.1"],["Bad contacts",totals.bad_contacts,"Status 1.4"],["Active callers",totals.active_callers,"Selected range"],["Total call time",longDuration(totals.total_call_seconds),"All matching calls"]].map(([label, amount, note]) => <article className="metric-card mint" key={label}><span>{label}</span><strong>{typeof amount === "number" ? number(amount) : amount}</strong><small>{note}</small></article>)}</div>
  </>;
}

export function TeamView({ data }) {
  const [mode, setMode] = useState("calls");
  const rows = mode === "calls" ? data?.agents || [] : data?.note_authors || [];
  const totals = data?.totals || {};
  const qualifiedLiveLeads = data?.live_ownership_totals?.live_leads || 0;
  const exportRows = () => downloadCsv(mode === "calls" ? "ricochet-agent-calls.csv" : "ricochet-note-authors.csv", rows);
  return <><div className="metric-grid teacher-metrics team-summary">{[["Calls made",totals.calls,"All matching calls"],["Unique leads",totals.unique_leads,"Called in range"],["Total talk time",longDuration(totals.duration_seconds),"All agents"],["Qualified live leads",qualifiedLiveLeads,"First event passed all gates"]].map(([label, amount, note]) => <article className="metric-card green" key={label}><span>{label}</span><strong>{typeof amount === "number" ? number(amount) : amount}</strong><small>{note}</small></article>)}</div><article className="panel report-panel"><div className="panel-heading"><div><span className="eyebrow">Agent performance</span><h3>Calls and talk time in the selected range</h3><p>Live ownership is reported separately below using the original gated live event.</p></div><div className="panel-actions"><div className="segmented"><button className={mode === "calls" ? "active" : ""} onClick={() => setMode("calls")}>By calls</button><button className={mode === "notes" ? "active" : ""} onClick={() => setMode("notes")}>By notes</button></div><button className="button secondary" disabled={!rows.length} onClick={exportRows}><Download size={15} />Export CSV</button></div></div>
    {!rows.length ? <Empty message="No agent activity matched these filters." /> : <div className="table-wrap"><table><thead><tr>{mode === "calls" ? <><th>Caller</th><th>Score</th><th>Calls made</th><th>Unique leads</th><th>Handled</th><th>Total talk time</th><th>Avg duration</th><th>First call</th><th>Last call</th></> : <><th>Note author</th><th>Notes</th><th>Unique leads</th><th>First note</th><th>Last note</th></>}</tr></thead><tbody>{rows.map((row, index) => mode === "calls" ? <tr key={row.user_id || row.user_name || index}><td><strong>{value(row, "user_name")}</strong><small>{value(row, "user_id")}</small></td><td><span className="score">{number(row.score)}</span></td><td>{number(row.calls)}</td><td>{number(row.unique_leads)}</td><td>{number(row.handled_calls)}</td><td>{longDuration(row.duration_seconds)}</td><td>{duration(row.average_duration_seconds)}</td><td>{value(row, "first_call")}</td><td>{value(row, "last_call")}</td></tr> : <tr key={row.author || index}><td><strong>{value(row, "author")}</strong></td><td>{number(row.notes)}</td><td>{number(row.unique_leads)}</td><td>{value(row, "first_note")}</td><td>{value(row, "last_note")}</td></tr>)}</tbody></table></div>}
  </article><LiveOwnershipReport data={data} /></>;
}

function LiveOwnershipReport({ data }) {
  const rows = data?.live_ownership || []; const totals = data?.live_ownership_totals || {};
  const cards = [["Qualified live leads",totals.live_leads,"First live date + formal note + sent email"],["Live transfers",totals.live_transfers,"Original 2.3 disposition"],["Live call backs",totals.live_call_backs,"Original 2.4 disposition"],["Live group texts",totals.live_texts,"Original 2.5 disposition"],["Ownership confirmed",totals.confirmed_ownership,"Original caller + note owner + ISA"],["Needs review",totals.needs_review,"Missing or conflicting owner"]];
  return <section className="live-ownership-section"><div className="section-heading"><div><span className="eyebrow">Live ownership verification</span><h2>First live outcomes by original note owner</h2><p>Each lead is counted once, in the range containing its first live date. A sent live email and a formal Buyer/Seller form with an original 2.3, 2.4, or 2.5 disposition are required. Later work and inbound calls never move ownership.</p></div></div><div className="metric-grid ownership-metrics">{cards.map(([label,amount,note],index) => <article className={`metric-card ${index === 5 ? "gold" : "green"}`} key={label}><span>{label}</span><strong>{number(amount)}</strong><small>{note}</small></article>)}</div><article className="panel report-panel"><div className="panel-heading"><div><span className="eyebrow">Original agent verification</span><h3>2.3 Live Transfer, 2.4 Live Call Back, and 2.5 Live Group Text</h3></div><button className="button secondary" disabled={!rows.length} onClick={() => downloadCsv("ricochet-live-ownership.csv", rows)}><Download size={15} />Export CSV</button></div>{!rows.length ? <Empty message="No qualified first-live events matched this range." /> : <div className="table-wrap"><table><thead><tr><th>Original formal-note owner</th><th>Qualified live leads</th><th>Live transfer</th><th>Live call back</th><th>Live group text</th><th>Original call matches</th><th>Form ISA matches</th><th>Fully confirmed</th><th>Needs review</th></tr></thead><tbody>{rows.map((row,index) => <tr key={row.owner_key || index}><td><strong>{value(row,"agent")}</strong><small>{row.agent_id ? `ID ${row.agent_id}` : value(row,"agent_email")}</small></td><td>{number(row.live_leads)}</td><td>{number(row.live_transfers)}</td><td>{number(row.live_call_backs)}</td><td>{number(row.live_texts)}</td><td>{number(row.original_call_matches)}</td><td>{number(row.isa_matches)}</td><td><span className="ownership-confirmed">{number(row.confirmed_ownership)}</span></td><td><span className={Number(row.needs_review || 0) ? "ownership-review" : "ownership-clear"}>{number(row.needs_review)}</span></td></tr>)}</tbody></table></div>}</article></section>;
}

export function CallsView({ data, page, setPage, setToast }) {
  const rows = data?.rows || [];
  const analyze = async (row) => {
    try { await runAiAction("/ai/analyze-call", { call_event_id: row.id }); setToast("AI review was queued."); }
    catch (error) { setToast(error.message, true); }
  };
  return <article className="panel report-panel"><div className="panel-heading"><div><span className="eyebrow">Calls and AI</span><h3>Recent call recordings</h3><p>Reporting rows come directly from Supabase. Playback and AI commands use the private Worker bridge.</p></div></div>
    {!rows.length ? <Empty message="No calls matched these filters." /> : <div className="table-wrap"><table><thead><tr><th>Lead</th><th>Agent</th><th>Date</th><th>Direction</th><th>Duration</th><th>Status</th><th>AI review</th><th>Recording</th></tr></thead><tbody>{rows.map((row) => <tr key={row.id}><td><strong>{fullName(row)}</strong><small>{row.phone || "No phone"}</small></td><td>{value(row, "user_name")}</td><td>{value(row, "call_date_time")}</td><td>{value(row, "direction")}</td><td>{duration(row.duration_seconds)}</td><td><span className="tag">{value(row, "lead_status", "call_status")}</span></td><td>{row.ai_analysis_status === "completed" ? <span className="reviewed">{number(row.ai_agent_score)} reviewed</span> : <button className="text-action" onClick={() => analyze(row)}><Bot size={14} />Analyze</button>}</td><td><AudioPlayer compact callUuid={row.call_uuid} /></td></tr>)}</tbody></table></div>}
    <Pager data={data} page={page} setPage={setPage} />
  </article>;
}

export function NotesView({ data, page, setPage }) {
  const rows = data?.rows || [];
  return <><div className="section-heading"><div><span className="eyebrow">Notes</span><h2>Complete notes on file with recording timeline</h2><p>Each card now uses the lead’s full synchronized note history, not only notes detected after the new report was installed.</p></div></div>
    {!rows.length ? <Empty message="No notes matched these filters." /> : <div className="notes-grid">{rows.map((row) => <NoteCard row={row} key={row.id} />)}</div>}
    <Pager data={data} page={page} setPage={setPage} />
  </>;
}

function NoteEntry({ note, latest, live }) {
  const [expanded, setExpanded] = useState(false);
  const body = cleanNoteText(note.note_text) || "No note text";
  const isLong = body.length > 240 || body.split("\n").length > 5;
  const owner = value(note, "note_user_name", "note_user_email");
  return <section className={`note-entry${latest ? " latest" : ""}${live ? " live" : ""}`}><div className="note-entry-heading"><div><strong>{latest ? "Latest note" : `Note ${number(note.note_sequence)}`}</strong>{live && <span className="live-note-label">Live-status note</span>}</div><time>{formatNoteTime(note.note_time)}</time></div><div className="note-owner"><span>{owner}</span>{note.note_user_id && <small>ID {note.note_user_id}</small>}{note.ricochet_note_id && <small>Note {note.ricochet_note_id}</small>}</div><p className={expanded ? "note-body expanded" : "note-body"}>{body}</p><div className="note-entry-actions">{isLong && <button className="text-action" onClick={() => setExpanded(!expanded)}>{expanded ? "Show less" : "Read more"}</button>}{note.call_uuid ? <AudioPlayer compact callUuid={note.call_uuid} /> : <span className="unmatched-recording">No exact recording match</span>}</div></section>;
}

function NoteCard({ row }) {
  const notes = mergedNotes(row); const latest = notes[0]; const older = notes.slice(1);
  const live = /live|appointment/i.test(String(row.lead_status || ""));
  return <article className={`note-card compact-note-card${live ? " live-lead-note" : ""}`}><div className="note-top"><div><h3>{fullName(row)}</h3><div className="tag-row"><span className={`tag${live ? " live-tag" : ""}`}>{value(row, "lead_status")}</span><span className="tag quiet">{displayedLeadType(row, notes)}</span></div></div><span className="note-count">{number(notes.length)} notes</span></div>{latest ? <NoteEntry note={latest} latest live={live} /> : <span className="muted">No readable note was synchronized.</span>}{older.length > 0 && <details className="older-notes"><summary>View {number(older.length)} older notes</summary><div className="older-note-list">{older.map((note, index) => <NoteEntry note={note} key={`${noteKey(note)}-${index}`} />)}</div></details>}<details className="timeline"><summary><Headphones size={14} />All related recordings · {row.recordings?.length || 0}</summary>{(row.recordings || []).length ? row.recordings.map((call) => <div className="timeline-row" key={call.id}><div><strong>{call.exact_match ? "Latest exact note match" : value(call, "call_date_time")}</strong><span>{value(call, "user_name")} · {duration(call.duration_seconds)} · {value(call, "direction")}</span></div><AudioPlayer compact callUuid={call.call_uuid} /></div>) : <span className="muted">No playable recordings are synchronized for this lead.</span>}</details></article>;
}

export function LeadsView({ data, page, setPage }) {
  const rows = data?.rows || [];
  return <article className="panel report-panel"><div className="panel-heading"><div><span className="eyebrow">Lead directory</span><h3>Leads in the selected cohort</h3></div><button className="button secondary" onClick={() => downloadCsv("ricochet-leads.csv", rows)}><Download size={15} />Export visible</button></div>{!rows.length ? <Empty message="No leads matched these filters." /> : <div className="table-wrap"><table><thead><tr><th>Lead</th><th>Status</th><th>Type</th><th>Vendor</th><th>Agent</th><th>Location</th><th>Activity date</th></tr></thead><tbody>{rows.map((row) => <tr key={row.id}><td><strong>{fullName(row)}</strong><small>{row.phone || ""}{row.email ? ` · ${row.email}` : ""}</small></td><td><span className="tag">{value(row, "lead_status")}</span></td><td>{value(row, "lead_type")}</td><td>{value(row, "vendor")}</td><td>{value(row, "user_name")}</td><td>{[row.city, row.property_state, row.property_zip].filter(Boolean).join(", ") || "—"}</td><td>{value(row, "lead_date")}</td></tr>)}</tbody></table></div>}<Pager data={data} page={page} setPage={setPage} /></article>;
}

export function CsvView({ setToast }) {
  const [rows, setRows] = useState([]); const [matches, setMatches] = useState([]); const [busy, setBusy] = useState(false); const [exporting, setExporting] = useState(false); const [error, setError] = useState("");
  const summary = useMemo(() => ({ matched: matches.filter((row) => row.match_status === "MATCHED").length, missing: matches.filter((row) => row.match_status !== "MATCHED").length }), [matches]);
  const choose = async (event) => { setError(""); setMatches([]); try { const file = event.target.files?.[0]; if (!file) return; setRows(parseLeadCsv(await file.text())); } catch (cause) { setError(cause.message); } };
  const run = async () => { setBusy(true); setError(""); try { const output = []; for (let index = 0; index < rows.length; index += 200) output.push(...await matchCsvRows(rows.slice(index, index + 200))); setMatches(output); setToast(`${number(output.length)} CSV rows checked.`); } catch (cause) { setError(cause.message); } finally { setBusy(false); } };
  const exportCalls = async () => { setExporting(true); setError(""); try { const ids = [...new Set(matches.map((row) => Number(row.lead_id || 0)).filter(Boolean))]; const output = []; for (let index = 0; index < ids.length; index += 100) output.push(...await loadCsvCallDetails(ids.slice(index, index + 100))); downloadCsv("ricochet-csv-call-details.csv", output); setToast(`${number(output.length)} call rows exported.`); } catch (cause) { setError(cause.message); } finally { setExporting(false); } };
  return <div className="csv-layout"><article className="panel upload-panel"><div className="upload-icon"><FileUp size={25} /></div><span className="eyebrow">CSV lead filter</span><h2>Match a lead list without another key</h2><p>Accepted headers include first_name, last_name, email, and phone_number. Phone is matched first, then email.</p><label className="file-button"><input type="file" accept=".csv,text/csv" onChange={choose} />Choose CSV</label>{rows.length > 0 && <div className="upload-ready"><CheckCircle2 size={16} />{number(rows.length)} valid lead rows ready</div>}<ErrorBox message={error} /><button className="button primary" disabled={!rows.length || busy} onClick={run}>{busy ? "Matching in secure batches…" : "Run Supabase match"}</button></article>
    <article className="panel csv-results"><div className="panel-heading"><div><span className="eyebrow">Results</span><h3>{matches.length ? `${number(summary.matched)} matched · ${number(summary.missing)} not found` : "Upload a CSV to begin"}</h3></div>{matches.length > 0 && <div className="panel-actions"><button className="button secondary" onClick={() => downloadCsv("ricochet-csv-lead-summary.csv", matches)}><Download size={15} />Lead summary</button><button className="button secondary" disabled={exporting} onClick={exportCalls}><Download size={15} />{exporting ? "Preparing calls…" : "Call details"}</button></div>}</div>{matches.length ? <div className="table-wrap"><table><thead><tr><th>CSV row</th><th>Name</th><th>Phone</th><th>Email</th><th>Match</th><th>Current status</th><th>Calls</th><th>Notes</th><th>Agent</th></tr></thead><tbody>{matches.map((row) => <tr key={row.row_number}><td>{row.row_number}</td><td>{[row.input_first_name, row.input_last_name].filter(Boolean).join(" ")}</td><td>{row.input_phone}</td><td>{row.input_email}</td><td><span className={row.match_status === "MATCHED" ? "match matched" : "match missing"}>{row.match_method || row.match_status}</span></td><td>{value(row, "lead_status")}</td><td>{number(row.call_count)}</td><td>{number(row.note_count)}</td><td>{value(row, "user_name")}</td></tr>)}</tbody></table></div> : <Empty message="Matching is done directly by an authorized Supabase function." />}</article></div>;
}

export function TeacherView({ data, page, setPage, setToast }) {
  const totals = data?.totals || {};
  const audit = async () => { try { await runAiAction("/ai/teacher/run", { maximum_calls: 25 }); setToast("AI teacher audit was queued."); } catch (error) { setToast(error.message, true); } };
  return <><div className="teacher-actions"><div><span className="eyebrow">AI teacher review</span><h2>Manager review queue</h2><p>Read-only review data comes from Supabase. Paid AI, recording, and D1 corrections remain behind the private Worker bridge.</p></div><button className="button primary" onClick={audit}><Sparkles size={16} />Run paid audit</button></div><div className="metric-grid teacher-metrics">{[["Reviewed",totals.reviewed,"green"],["Needs review",totals.needs_review,"gold"],["Queued",totals.queued,"blue"],["Processing",totals.processing,"violet"]].map(([label, amount, tone]) => <article className={`metric-card ${tone}`} key={label}><span>{label}</span><strong>{number(amount)}</strong><small>Selected range</small></article>)}</div><article className="panel report-panel"><div className="panel-heading"><div><span className="eyebrow">Review queue</span><h3>Calls needing manager attention</h3></div></div>{data?.rows?.length ? <div className="table-wrap"><table><thead><tr><th>Lead</th><th>Call</th><th>Agent</th><th>Trigger</th><th>Score</th><th>Recording</th></tr></thead><tbody>{data.rows.map((row) => <tr key={row.call_event_id}><td>{fullName(row)}</td><td>{row.call_date_time}</td><td>{row.user_name}</td><td>{row.trigger_reason}</td><td>{number(row.ai_agent_score)}</td><td><AudioPlayer compact callUuid={row.call_uuid} /></td></tr>)}</tbody></table></div> : <Empty message="No AI reviews match these filters." />}<Pager data={data} page={page} setPage={setPage} /></article></>;
}

export function ViewRouter({ page, data, pagination, setPagination, setToast }) {
  if (page === "team") return <TeamView data={data} />;
  if (page === "calls") return <CallsView data={data} page={pagination.page} setPage={(pageNumber) => setPagination({ ...pagination, page: pageNumber })} setToast={setToast} />;
  if (page === "notes") return <NotesView data={data} page={pagination.page} setPage={(pageNumber) => setPagination({ ...pagination, page: pageNumber })} />;
  if (page === "leads") return <LeadsView data={data} page={pagination.page} setPage={(pageNumber) => setPagination({ ...pagination, page: pageNumber })} />;
  if (page === "csv") return <CsvView setToast={setToast} />;
  if (page === "teacher") return <TeacherView data={data} page={pagination.page} setPage={(pageNumber) => setPagination({ ...pagination, page: pageNumber })} setToast={setToast} />;
  return <OverviewView data={data} />;
}
