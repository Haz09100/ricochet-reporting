import { config } from "../config.js";
import { currentAccessToken, supabase } from "./supabase.js";

const rpcNames = Object.freeze({
  overview: "dashboard_overview",
  team: "dashboard_team",
  calls: "dashboard_calls",
  notes: "dashboard_notes",
  leads: "dashboard_leads",
  teacher: "dashboard_ai_review",
});
const reportCache = new Map();
const CACHE_MS = 60_000;
const wait = (milliseconds) => new Promise((resolve) => window.setTimeout(resolve, milliseconds));

function requiredClient() {
  if (!supabase) throw new Error("Supabase is not configured for this build.");
  return supabase;
}

export function reportParameters(filters, extra = {}) {
  return {
    p_from: filters.from,
    p_to: filters.to,
    p_filters: {
      date_basis: filters.dateBasis,
      status: filters.status,
      agent: filters.agent,
      vendor: filters.vendor,
      lead_type: filters.leadType,
      state: filters.state,
      city: filters.city,
      ...(filters.countyFilterActive ? { counties: filters.counties || [] } : {}),
      ...(filters.metroFilterActive ? { metros: filters.metros || [] } : {}),
      appointment_type: filters.appointmentType,
      source_description: filters.sourceDescription,
      address_quality: filters.addressQuality,
      email_status: filters.emailStatus,
      ai_review: filters.aiReview,
      recording: filters.recording,
      search: filters.search,
      ...extra.filters,
    },
    ...(extra.page ? { p_page: extra.page } : {}),
    ...(extra.pageSize ? { p_page_size: extra.pageSize } : {}),
  };
}

export async function loadReportPage(page, filters, pagination = {}, { bypassCache = false } = {}) {
  const name = rpcNames[page] || rpcNames.overview;
  const withPagination = ["calls", "notes", "leads", "teacher"].includes(page);
  const params = reportParameters(filters, withPagination ? {
    page: pagination.page || 1,
    pageSize: pagination.pageSize || 50,
  } : {});
  const cacheKey = JSON.stringify([page, params]);
  const cached = reportCache.get(cacheKey);
  if (!bypassCache && cached && Date.now() - cached.savedAt < CACHE_MS) return cached.data;
  let response = await requiredClient().rpc(name, params);
  if (response.error && /statement timeout|canceling statement/i.test(response.error.message || "")) {
    await wait(1200);
    response = await requiredClient().rpc(name, params);
  }
  const { data, error } = response;
  if (error) throw new Error(error.message || `Could not load ${page}.`);
  const result = data || {};
  reportCache.set(cacheKey, { data: result, savedAt: Date.now() });
  return result;
}

export async function loadFilterOptions(from, to) {
  const { data, error } = await requiredClient().rpc("dashboard_filter_options", { p_from: from, p_to: to });
  if (error) throw new Error(error.message || "Could not load filter choices.");
  return data || {};
}

export async function loadGeoOptions(state) {
  if (!state) return { state: "", counties: [], metros: [], mapped_zip_codes: 0 };
  const { data, error } = await requiredClient().rpc("dashboard_geo_options", { p_state: state });
  if (error) throw new Error(error.message || "Could not load county and metro choices.");
  return data || { state, counties: [], metros: [], mapped_zip_codes: 0 };
}

export async function loadAllFilteredLeads(filters, selectedFields = [], onProgress) {
  const output = [];
  let page = 1;
  let total = Number.POSITIVE_INFINITY;
  while (output.length < total) {
    const params = { ...reportParameters(filters, { page, pageSize: 250 }), p_fields: selectedFields };
    const { data, error } = await requiredClient().rpc("dashboard_lead_export", params);
    if (error) throw new Error(error.message || "Could not prepare the full lead export.");
    const rows = Array.isArray(data?.rows) ? data.rows : [];
    total = Number(data?.total || 0);
    output.push(...rows);
    onProgress?.(Math.min(output.length, total), total);
    if (!rows.length || output.length >= total) break;
    page += 1;
    if (page > 250) throw new Error("The export exceeded the safe page limit. Narrow the filters and try again.");
  }
  return output;
}

export async function matchCsvRows(rows) {
  let response = await requiredClient().rpc("dashboard_csv_match", { p_rows: rows });
  if (response.error && /statement timeout|canceling statement/i.test(response.error.message || "")) {
    await wait(600);
    response = await requiredClient().rpc("dashboard_csv_match", { p_rows: rows });
  }
  const { data, error } = response;
  if (error) throw new Error(error.message || "CSV matching failed.");
  return Array.isArray(data) ? data : data?.rows || [];
}

export async function loadCsvCallDetails(leadIds) {
  const { data, error } = await requiredClient().rpc("dashboard_csv_call_details", { p_lead_ids: leadIds });
  if (error) throw new Error(error.message || "Call-detail export failed.");
  return Array.isArray(data) ? data : [];
}

export async function loadCallAiReview(callEventId) {
  const { data, error } = await requiredClient().rpc("dashboard_call_ai_review", { p_call_event_id: Number(callEventId) });
  if (error) throw new Error(error.message || "Could not load the call AI review.");
  return data || {};
}

export async function loadAllFilteredCalls(filters, onProgress) {
  const output = [];
  let page = 1;
  let total = Number.POSITIVE_INFINITY;
  while (output.length < total) {
    const params = reportParameters(filters, { page, pageSize: 200 });
    const { data, error } = await requiredClient().rpc("dashboard_calls", params);
    if (error) throw new Error(error.message || "Could not load all matching calls.");
    const rows = Array.isArray(data?.rows) ? data.rows : [];
    total = Number(data?.total || 0);
    output.push(...rows);
    onProgress?.(Math.min(output.length, total), total);
    if (!rows.length || output.length >= total) break;
    page += 1;
    if (page > 500) throw new Error("The call selection exceeded the safe page limit. Narrow the filters and try again.");
  }
  return output;
}

export async function setLiveBonusDecision({ leadId, decision, agentId = "", agentName = "", agentEmail = "", reason }) {
  const { data, error } = await requiredClient().rpc("dashboard_set_live_bonus_decision", {
    p_lead_id: Number(leadId),
    p_decision: decision,
    p_agent_id: agentId || null,
    p_agent_name: agentName || null,
    p_agent_email: agentEmail || null,
    p_reason: reason,
  });
  if (error) throw new Error(error.message || "Could not save the bonus decision.");
  reportCache.clear();
  return data || {};
}

export async function loadLiveBonusReview(leadId) {
  const { data, error } = await requiredClient().rpc("dashboard_live_bonus_review", { p_lead_id: Number(leadId) });
  if (error) throw new Error(error.message || "Could not load the live-lead review.");
  return data || {};
}

export async function bridgeRequest(path, options = {}) {
  if (!config.workerUrl) throw new Error("The private recording/AI bridge URL is not configured.");
  const token = await currentAccessToken();
  if (!token) throw new Error("Your login expired. Sign in again.");
  const headers = new Headers(options.headers || {});
  headers.set("authorization", `Bearer ${token}`);
  headers.set("accept", options.accept || "application/json");
  if (options.body && !headers.has("content-type")) headers.set("content-type", "application/json");
  const response = await fetch(`${config.workerUrl}${path}`, { ...options, headers });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.error || `Private bridge returned HTTP ${response.status}.`);
  }
  return response;
}

export async function runAiAction(path, payload) {
  const response = await bridgeRequest(path, { method: "POST", body: JSON.stringify(payload || {}) });
  return response.json();
}
