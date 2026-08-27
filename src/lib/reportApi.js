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

export async function matchCsvRows(rows) {
  const { data, error } = await requiredClient().rpc("dashboard_csv_match", { p_rows: rows });
  if (error) throw new Error(error.message || "CSV matching failed.");
  return Array.isArray(data) ? data : data?.rows || [];
}

export async function loadCsvCallDetails(leadIds) {
  const { data, error } = await requiredClient().rpc("dashboard_csv_call_details", { p_lead_ids: leadIds });
  if (error) throw new Error(error.message || "Call-detail export failed.");
  return Array.isArray(data) ? data : [];
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
