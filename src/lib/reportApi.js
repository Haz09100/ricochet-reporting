import { config } from "../config.js";
import { currentAccessToken, supabase } from "./supabase.js";

const rpcNames = Object.freeze({
  overview: "dashboard_overview",
  team: "dashboard_team_activity",
  calls: "dashboard_calls",
  notes: "dashboard_notes",
  leads: "dashboard_leads",
  teacher: "dashboard_ai_review",
});
const reportCache = new Map();
const rpcCache = new Map();
let cacheGeneration = 0;
export function clearReportCaches() {
  cacheGeneration += 1;
  reportCache.clear();
  rpcCache.clear();
}
const CACHE_MS = 60_000;
const wait = (milliseconds) => new Promise((resolve) => window.setTimeout(resolve, milliseconds));
const transientReportError = (error) => !/statement timeout|canceling statement|57014|abort/i.test(error?.message || "") && /fetch failed|failed to fetch|network|connection reset|502|503|504/i.test(error?.message || "");
const compactText = (input) => String(input || "").replace(/\s+/g, " ").trim();
const comparable = (input) => compactText(input).toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

async function rpcWithRetry(name, params, maximumAttempts = 2, { signal } = {}) {
  let response;
  let thrown;
  const delays = [1000,2500,5000];
  for (let attempt = 0; attempt < maximumAttempts; attempt += 1) {
    try {
      signal?.throwIfAborted();
      const query = requiredClient().rpc(name, params);
      response = await (signal ? query.abortSignal(signal) : query);
      signal?.throwIfAborted();
      thrown = null;
      if (!response.error || !transientReportError(response.error) || attempt === maximumAttempts - 1) return response;
    } catch (error) {
      if (signal?.aborted) throw error;
      thrown = error;
      if (!transientReportError(error) || attempt === maximumAttempts - 1) throw error;
    }
    await wait(delays[Math.min(attempt,delays.length - 1)]);
  }
  if (thrown) throw thrown;
  return response;
}

async function readReportRpc(name, params, { signal, bypassCache = false } = {}) {
  signal?.throwIfAborted();
  const key = JSON.stringify([name, params]);
  const cached = rpcCache.get(key);
  if (!bypassCache && cached && Date.now() - cached.savedAt < CACHE_MS) return cached.response;
  const generation = cacheGeneration;
  const response = await rpcWithRetry(name, params, 2, { signal });
  if (!response.error && generation === cacheGeneration && !signal?.aborted) {
    if (rpcCache.size >= 24) rpcCache.delete(rpcCache.keys().next().value);
    rpcCache.set(key, { response, savedAt: Date.now() });
  }
  return response;
}

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
      creation_origin: filters.creationOrigin,
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

export async function loadReportPage(page, filters, pagination = {}, { bypassCache = false, signal } = {}) {
  signal?.throwIfAborted();
  const generation = cacheGeneration;
  const read = (rpcName, rpcParams) => readReportRpc(rpcName, rpcParams, { signal, bypassCache }).catch((error) => ({ data: null, error }));
  const name = rpcNames[page] || rpcNames.overview;
  const withPagination = ["calls", "notes", "leads", "teacher"].includes(page);
  const params = reportParameters(filters, withPagination ? {
    page: pagination.page || 1,
    pageSize: pagination.pageSize || 50,
    ...(page === "leads" ? { filters: { call_min: pagination.callMin ?? "", call_max: pagination.callMax ?? "", call_sort: pagination.callSort || "fewest" } } : {}),
  } : {});
  const cacheKey = JSON.stringify([page, params]);
  const cached = reportCache.get(cacheKey);
  if (!bypassCache && cached && Date.now() - cached.savedAt < CACHE_MS) return cached.data;
  // Start independent sections together. All promises settle safely even if
  // the main request fails or the user changes filters.
  const core = read(name, params);
  const extraParams = reportParameters(filters);
  const extras = page === "overview"
    ? Promise.all([read("dashboard_first_response_metrics", extraParams),
      read("dashboard_live_bonus_count", extraParams).then((response) => {
        // Older databases remain compatible until migration 018 is installed.
        if (response.error && /PGRST202|42883|could not find the function/i.test(`${response.error.code || ''} ${response.error.message || ''}`)) {
          return read("dashboard_live_bonus", extraParams);
        }
        return response;
      })])
    : page === "team"
      ? Promise.all([
        read("dashboard_live_bonus", extraParams),
        read("dashboard_companion_bonus", extraParams),
        loadAuthoritativeCompanionBonus(filters, {}, { signal, bypassCache }).then((data) => ({ data, error: null })).catch((error) => ({ data: null, error })),
      ]) : null;
  const response = await core;
  signal?.throwIfAborted();
  const { data, error } = response;
  if (error) throw new Error(error.message || `Could not load ${page}.`);
  let result = data || {};
  if (page === "leads") {
    if (result.call_count_scope !== "all_synchronized_history") throw new Error("Install supabase/017_lead_call_coverage.sql in Supabase SQL Editor to enable lead call counts and sorting.");
    result = await decorateCompanionRows(result, "id", { signal, bypassCache });
  }
  if (page === "team") {
    const [liveBonus,companion,authoritative] = await extras;
    signal?.throwIfAborted();
    if (liveBonus.error) throw new Error(liveBonus.error.message || "Could not load the live-lead bonus ledger.");
    if (companion.error) throw new Error(companion.error.message || "Could not load companion lead bonuses.");
    const fallbackCompanion = companion.data || {};
    let companionBonus = authoritative.data
      ? { ...authoritative.data, can_manage_bonus: fallbackCompanion.can_manage_bonus === true }
      : {
        ...fallbackCompanion,
        source: "supabase-note-fallback",
        source_warning: `LeadFlow verification is unavailable: ${authoritative.error?.message || "Unknown connection error"}`,
      };
    result = { ...result, ...(liveBonus.data || {}), companion_bonus: companionBonus };
  }
  if (page === "overview") {
    const [firstResponse, teamResponse] = await extras;
    signal?.throwIfAborted();
    const auditedLiveTotal = teamResponse.error
      ? null
      : Number(teamResponse.data?.live_bonus_totals?.sent_live_leads);
    result = {
      ...result,
      totals: Number.isFinite(auditedLiveTotal)
        ? {
            ...(result.totals || {}),
            live_leads_sent: auditedLiveTotal,
            live_emails_sent: auditedLiveTotal,
          }
        : result.totals,
      first_response: firstResponse.error
        ? { available: false }
        : { ...(firstResponse.data || {}), available: true },
    };
  }
  signal?.throwIfAborted();
  if (generation === cacheGeneration) {
    if (reportCache.size >= 16) reportCache.delete(reportCache.keys().next().value);
    reportCache.set(cacheKey, { data: result, savedAt: Date.now() });
  }
  return result;
}

function formField(text, label) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const nextLabel = "(?:CURRENT(?:\\s+LIVING)?(?:\\s+STATUS)?(?:\\/LOCATION)?|VENDOR|LOCATION|PROPERTY|TARGET|REASON|FLEXIBLE|PRICE|FINANCING|PRIMARY|MOTIVATION|APPOINTMENT|AGENT|DISPOSITION|NOTES?)";
  const match = String(text || "").match(new RegExp(`(?:^|[\\r\\n]|\\s)${escaped}\\s*:\\s*(.+?)(?=(?:[\\r\\n]|\\s+)${nextLabel}(?:[^:\\r\\n]{0,45})?\\s*:|$)`, "i"));
  return compactText(match?.[1] || "").slice(0, 160);
}

function sourceCompanionMatches(row, filters) {
  if (filters.creationOrigin === "original") return false;
  if (filters.creationOrigin && row.noteCreationDirection !== filters.creationOrigin) return false;
  if (filters.status && comparable(row.ricochetStatus) !== comparable(filters.status)) return false;
  if (filters.vendor && comparable(row.vendor) !== comparable(filters.vendor)) return false;
  if (filters.leadType && comparable(row.intent) !== comparable(filters.leadType)) return false;
  if (filters.state && comparable(row.state) !== comparable(filters.state)) return false;
  if (filters.city && comparable(row.city) !== comparable(filters.city)) return false;
  if (filters.countyFilterActive && !(filters.counties || []).some((county) => comparable(county) === comparable(row.county))) return false;
  const agent = formField(row.sentBackground, "ISA");
  if (filters.agent && !comparable(agent).includes(comparable(filters.agent)) && !comparable(filters.agent).includes(comparable(agent))) return false;
  if (filters.search) {
    const haystack = comparable([row.firstName,row.lastName,row.email,row.phone,row.city,row.state,row.zip,row.destinationFubPersonId,row.sourceLeadId].join(" "));
    if (!haystack.includes(comparable(filters.search))) return false;
  }
  return true;
}

function companionDate(input) {
  const parsed = new Date(input);
  if (Number.isNaN(parsed.getTime())) return input || "";
  return new Intl.DateTimeFormat(undefined, { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" }).format(parsed);
}

function buildAuthoritativeCompanionBonus(sourceRows, decisions, fallback) {
  const byId = new Map((decisions || []).map((item) => [String(item.source_lead_id), item]));
  const ledger = sourceRows.map((row) => {
    const manual = byId.get(String(row.sourceLeadId));
    const originatingAgent = formField(row.sentBackground, "ISA");
    const automaticState = originatingAgent ? "payable" : "needs_review";
    const bonusState = manual?.decision === "retracted" ? "retracted" : manual?.decision === "approved" ? "payable" : automaticState;
    return {
      id: `leadflow:${row.sourceLeadId}`,
      source_lead_id: row.sourceLeadId,
      destination_fub_person_id: row.destinationFubPersonId,
      lead_name: [row.firstName,row.lastName].filter(Boolean).join(" ") || `LeadFlow lead ${row.sourceLeadId}`,
      created_date_eastern: companionDate(row.receivedAt),
      created_at: row.receivedAt,
      lead_type: row.noteCreationDirection === "seller_to_buyer" ? "Buyer" : "Seller",
      creation_origin: row.noteCreationDirection,
      creation_label: row.noteCreationDirection === "seller_to_buyer" ? "Buyer created from Seller Form" : "Seller created from Buyer Form",
      originating_agent: originatingAgent,
      credited_agent_name: manual?.decision === "approved" ? manual.credited_agent_name : originatingAgent,
      bonus_state: bonusState,
      manual_decision: manual?.decision || "",
      decision_reason: manual?.reason || "",
      state: row.state,
      city: row.city,
      county: row.county,
      vendor: row.vendor,
      delivery_status: row.deliveryStatus,
      routing_status: row.routingStatus,
      allocation_id: row.allocationId,
      allocation_status: row.allocationStatus,
      delivery_attempts: row.attemptCount,
      delivery_error: row.lastError,
      fub_account_name: row.fubAccountName,
      agreement_name: row.agreementName,
      sent_source: row.sentSource,
      sent_stage: row.sentStage,
      sent_tags: row.sentTags || [],
      sent_message: row.sentMessage,
      generated_note: row.sentBackground,
      sent_property_search: row.sentPropertySearch,
      buyer_search_activity_status: row.buyerSearchActivityStatus,
      buyer_search_activity_response_code: row.buyerSearchActivityResponseCode,
      buyer_search_activity_error: row.buyerSearchActivityError,
      source_tracking_status: row.sourceTrackingStatus,
      source_tracking_attempts: row.sourceTrackingAttemptCount,
      source_tracking_lookup_method: row.sourceTrackingLookupMethod,
      source_tracking_person_id: row.sourceTrackingPersonId,
      source_tracking_tags: row.sourceTrackingTags || [],
      source_tracking_error: row.sourceTrackingError,
      source_tracking_at: row.sourceTrackingAt,
      split_group_id: row.splitGroupId,
      delivery_snapshot_recorded: row.deliverySnapshotRecorded === true,
      source_system: "leadflow-d1",
      source_snapshot: {
        source_lead_id: row.sourceLeadId,
        destination_fub_person_id: row.destinationFubPersonId,
        received_at: row.receivedAt,
        lead_name: [row.firstName,row.lastName].filter(Boolean).join(" "),
        creation_origin: row.noteCreationDirection,
        originating_agent: originatingAgent,
        delivery_status: row.deliveryStatus,
        fub_account_name: row.fubAccountName,
        agreement_name: row.agreementName,
        sent_tags: row.sentTags || [],
        state: row.state,
        city: row.city,
        vendor: row.vendor,
      },
    };
  });
  const payable = ledger.filter((row) => row.bonus_state === "payable");
  const agentMap = new Map();
  for (const row of payable) {
    const key = comparable(row.credited_agent_name);
    if (!key) continue;
    const current = agentMap.get(key) || { owner_key: key, agent: row.credited_agent_name, payable_companion_leads: 0, buyers_from_seller: 0, sellers_from_buyer: 0, manager_approved: 0 };
    current.payable_companion_leads += 1;
    current.buyers_from_seller += row.creation_origin === "seller_to_buyer" ? 1 : 0;
    current.sellers_from_buyer += row.creation_origin === "buyer_to_seller" ? 1 : 0;
    current.manager_approved += row.manual_decision === "approved" ? 1 : 0;
    agentMap.set(key,current);
  }
  return {
    source: "leadflow-d1",
    can_manage_bonus: fallback?.can_manage_bonus === true,
    totals: {
      created: ledger.length,
      buyers_from_seller: ledger.filter((row) => row.creation_origin === "seller_to_buyer").length,
      sellers_from_buyer: ledger.filter((row) => row.creation_origin === "buyer_to_seller").length,
      payable: payable.length,
      needs_review: ledger.filter((row) => row.bonus_state === "needs_review").length,
      retracted: ledger.filter((row) => row.bonus_state === "retracted").length,
    },
    agents: [...agentMap.values()].sort((a,b) => b.payable_companion_leads - a.payable_companion_leads || a.agent.localeCompare(b.agent)),
    ledger,
  };
}

async function loadAuthoritativeCompanionBonus(filters, fallback, options = {}) {
  const query = new URLSearchParams({ from: filters.from, to: filters.to });
  const response = await bridgeRequest(`/companion-leads?${query}`, { signal: options.signal });
  const payload = await response.json();
  const sourceRows = (Array.isArray(payload.rows) ? payload.rows : []).filter((row) => sourceCompanionMatches(row,filters));
  const sourceIds = sourceRows.map((row) => String(row.sourceLeadId || "")).filter(Boolean);
  const decisions = [];
  for (let index = 0; index < sourceIds.length; index += 500) {
    const { data, error } = await readReportRpc("dashboard_companion_source_decisions", { p_source_lead_ids: sourceIds.slice(index,index + 500) }, options);
    if (error) throw new Error(error.message || "Could not load companion bonus decisions.");
    decisions.push(...(Array.isArray(data) ? data : []));
  }
  return buildAuthoritativeCompanionBonus(sourceRows,decisions,fallback);
}

export async function loadFilterOptions(from, to, options = {}) {
  const { data, error } = await readReportRpc("dashboard_filter_options", { p_from: from, p_to: to }, options);
  if (error) throw new Error(error.message || "Could not load filter choices.");
  return data || {};
}

export async function loadGeoOptions(state) {
  if (!state) return { state: "", counties: [], metros: [], mapped_zip_codes: 0 };
  const { data, error } = await requiredClient().rpc("dashboard_geo_options", { p_state: state });
  if (error) throw new Error(error.message || "Could not load county and metro choices.");
  return data || { state, counties: [], metros: [], mapped_zip_codes: 0 };
}

export async function loadAllFilteredLeads(filters, selectedFields = [], onProgress, callOptions = {}) {
  const output = [];
  let page = 1;
  let total = Number.POSITIVE_INFINITY;
  while (output.length < total) {
    const params = { ...reportParameters(filters, { page, pageSize: 250, filters: { call_min: callOptions.callMin ?? "", call_max: callOptions.callMax ?? "", call_sort: callOptions.callSort || "fewest" } }), p_fields: selectedFields };
    const { data, error } = await rpcWithRetry("dashboard_lead_export",params);
    if (error) throw new Error(error.message || "Could not prepare the full lead export.");
    const rows = Array.isArray(data?.rows) ? data.rows : [];
    total = Number(data?.total || 0);
    const decorated = await decorateCompanionRows({ rows });
    output.push(...decorated.rows);
    onProgress?.(Math.min(output.length, total), total);
    if (!rows.length || output.length >= total) break;
    page += 1;
    if (page > 250) throw new Error("The export exceeded the safe page limit. Narrow the filters and try again.");
  }
  return output;
}

export async function matchCsvRows(rows) {
  const response = await rpcWithRetry("dashboard_csv_match",{ p_rows: rows });
  const { data, error } = response;
  if (error) throw new Error(error.message || "CSV matching failed.");
  const matched = Array.isArray(data) ? data : data?.rows || [];
  return (await decorateCompanionRows({ rows: matched }, "lead_id")).rows;
}

async function decorateCompanionRows(result, idField = "id", options = {}) {
  const rows = Array.isArray(result?.rows) ? result.rows : [];
  const ids = [...new Set(rows.filter((row) => !row.creation_origin).map((row) => Number(row?.[idField] || 0)).filter(Boolean))];
  if (!ids.length) return { ...(result || {}), rows };
  const { data, error } = await readReportRpc("dashboard_companion_origins",{ p_lead_ids: ids }, options);
  if (error) throw new Error(error.message || "Could not identify companion leads.");
  const byId = new Map((Array.isArray(data) ? data : []).map((item) => [Number(item.id), item]));
  return { ...(result || {}), rows: rows.map((row) => ({ ...row, ...(byId.get(Number(row?.[idField])) || {}) })) };
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
    const { data, error } = await rpcWithRetry("dashboard_calls",params);
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
  clearReportCaches();
  return data || {};
}

export async function setCompanionBonusDecision({ leadId, sourceLeadId = "", destinationFubPersonId = "", sourceSnapshot = {}, decision, agentName = "", reason }) {
  if (sourceLeadId) {
    const { data, error } = await requiredClient().rpc("dashboard_set_companion_source_bonus_decision", {
      p_source_lead_id: String(sourceLeadId),
      p_destination_fub_person_id: destinationFubPersonId || null,
      p_decision: decision,
      p_agent_name: agentName || null,
      p_reason: reason,
      p_source_snapshot: sourceSnapshot || {},
    });
    if (error) throw new Error(error.message || "Could not save the LeadFlow companion bonus decision.");
    clearReportCaches();
    return data || {};
  }
  const { data, error } = await requiredClient().rpc("dashboard_set_companion_bonus_decision", {
    p_lead_id: Number(leadId), p_decision: decision, p_agent_name: agentName || null, p_reason: reason,
  });
  if (error) throw new Error(error.message || "Could not save the companion bonus decision.");
  clearReportCaches();
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
  const method = String(options.method || "GET").toUpperCase();
  const attempts = method === "GET" ? 3 : 1;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    let response;
    try {
      response = await fetch(`${config.workerUrl}${path}`, { ...options, headers });
    } catch (error) {
      if (options.signal?.aborted) throw error;
      if (attempt < attempts) { await new Promise((resolve) => setTimeout(resolve, 350 * attempt)); continue; }
      throw new Error(`Could not reach the private report bridge at ${config.workerUrl}. Check the GitHub WORKER_BASE_URL and the bridge ALLOWED_ORIGINS setting.`);
    }
    if (response.ok) return response;
    const body = await response.json().catch(() => ({}));
    if (attempt < attempts && [429,502,503,504].includes(response.status)) {
      await new Promise((resolve) => setTimeout(resolve, 350 * attempt));
      continue;
    }
    throw new Error(body.error || `Private bridge returned HTTP ${response.status}.`);
  }
  throw new Error("The private report bridge did not respond.");
}

export async function runAiAction(path, payload) {
  const response = await bridgeRequest(path, { method: "POST", body: JSON.stringify(payload || {}) });
  const result = await response.json();
  clearReportCaches();
  return result;
}
