export const demoOverview = {
  totals: {
    leads_received: 10093,
    activity_cohort: 12086,
    worked_leads: 11684,
    live_leads_sent: 1190,
    live_emails_sent: 1190,
    calls_logged: 48143,
    unique_called_leads: 11920,
    contacted_leads: 2568,
    handled_calls: 37757,
    notes_added: 18226,
    leads_with_notes: 10045,
    ai_reviewed: 491,
    average_ai_score: 71.5,
    needs_attention: 362,
    contact_rate: 21.0,
  },
  status_breakdown: [
    { status: "1.0 CALLED - No Contact", count: 8534 },
    { status: "2.4 Live Call Back", count: 1205 },
    { status: "2.1 CONTACTED - Not Interested", count: 1011 },
    { status: "2.0 CONTACTED - Follow Up", count: 260 },
    { status: "XX - Do Not Call", count: 564 },
  ],
  daily_trend: [],
  generated_at: new Date().toISOString(),
};

export const demoTeam = {
  totals: { calls: 48143, agents: 23, unique_leads: 11920, duration_seconds: 722145 },
  agents: [
    { user_name: "Melissa Pujol", user_id: "20", score: 91, calls: 3842, unique_leads: 1541, handled_calls: 3024, average_duration_seconds: 188, first_call: "8:03 AM", last_call: "6:41 PM" },
    { user_name: "Vincent Menditto", user_id: "39", score: 87, calls: 3519, unique_leads: 1412, handled_calls: 2744, average_duration_seconds: 174, first_call: "8:12 AM", last_call: "6:28 PM" },
    { user_name: "Diego Nieto", user_id: "41", score: 83, calls: 3221, unique_leads: 1290, handled_calls: 2440, average_duration_seconds: 162, first_call: "8:29 AM", last_call: "6:18 PM" },
  ],
  note_authors: [
    { author: "Melissa Pujol", notes: 902, unique_leads: 641 },
    { author: "Vincent Menditto", notes: 811, unique_leads: 598 },
  ],
};

export const demoCalls = {
  total: 491,
  page: 1,
  page_size: 50,
  rows: [
    { id: 1001, first_name: "Miguel", last_name: "Cesar", phone: "8138022817", user_name: "Melissa Pujol", call_date_time: "Aug 25, 2026 4:18 PM", duration_seconds: 125, direction: "Outbound", call_status: "Completed", lead_status: "2.0 CONTACTED - Follow Up", recording_status: "available", call_uuid: "demo-call-0001", ai_analysis_status: "completed", ai_analysis_model: "gpt-5-mini", ai_agent_score: 88, ai_summary: "The agent reached the intended lead, discussed the follow-up, and established a clear next action.", ai_status_matches: true, ai_note_matches: true },
  ],
};

export const demoNotes = {
  total: 1,
  page: 1,
  page_size: 50,
  rows: [{
    id: 2001,
    first_name: "Miguel",
    last_name: "Cesar",
    phone: "8138022817",
    lead_status: "2.0 CONTACTED - Follow Up",
    note_text: "possible client speaks creole - client looking for $290k home - $2400 a month",
    note_user_name: "Melissa Pujol",
    note_created_at: "Aug 25, 2026 4:20 PM",
    recordings: [
      { id: 1001, call_uuid: "demo-call-0001", call_date_time: "Aug 25, 2026 4:18 PM", duration_seconds: 125, user_name: "Melissa Pujol", direction: "Outbound", exact_match: true },
      { id: 998, call_uuid: "demo-call-0000", call_date_time: "Aug 22, 2026 11:03 AM", duration_seconds: 73, user_name: "Melissa Pujol", direction: "Outbound", exact_match: false },
    ],
  }],
};

export const demoLeads = {
  total: 3,
  page: 1,
  page_size: 50,
  rows: [
    { id: 22514, first_name: "Miguel", last_name: "Cesar", phone: "8138022817", email: "miguel@example.com", lead_status: "2.0 CONTACTED - Follow Up", lead_type: "Buyer", vendor: "HomeValue.com", user_name: "Melissa Pujol", city: "Plant City", property_state: "FL", lead_date: "2026-08-25" },
    { id: 20465, first_name: "Rebekah", last_name: "Handlee", phone: "9046990674", email: "rebekah@example.com", lead_status: "1.0 CALLED - No Contact", lead_type: "Unknown", vendor: "Realty.com", user_name: "Diego Nieto", city: "Jacksonville", property_state: "FL", lead_date: "2026-08-25" },
  ],
};

export const demoTeacher = { total: 2, page: 1, page_size: 50, totals: { reviewed: 491, needs_review: 362, queued: 0, processing: 0 }, rows: [] };

export function demoForPage(page) {
  if (page === "team") return demoTeam;
  if (page === "calls") return demoCalls;
  if (page === "notes") return demoNotes;
  if (page === "leads") return demoLeads;
  if (page === "teacher") return demoTeacher;
  return demoOverview;
}
