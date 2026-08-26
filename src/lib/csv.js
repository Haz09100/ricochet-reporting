const aliases = Object.freeze({
  first_name: ["first_name", "firstname", "first name"],
  last_name: ["last_name", "lastname", "last name"],
  name: ["name", "full_name", "full name"],
  email: ["email", "email_address", "email address"],
  phone: ["phone", "phone_number", "phone number", "mobile"],
});

function parseLine(line) {
  const values = [];
  let value = "";
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === '"' && quoted && line[i + 1] === '"') { value += '"'; i += 1; }
    else if (char === '"') quoted = !quoted;
    else if (char === "," && !quoted) { values.push(value); value = ""; }
    else value += char;
  }
  values.push(value);
  return values.map((item) => item.trim());
}

function headerIndex(headers, field) {
  return headers.findIndex((header) => aliases[field].includes(header));
}

export function parseLeadCsv(text) {
  if (new Blob([text]).size > 5 * 1024 * 1024) throw new Error("CSV must be 5 MB or smaller.");
  const lines = text.replace(/^\uFEFF/, "").split(/\r?\n/).filter((line) => line.trim());
  if (lines.length < 2) throw new Error("CSV needs a header and at least one lead row.");
  if (lines.length - 1 > 5000) throw new Error("CSV can contain up to 5,000 lead rows.");
  const headers = parseLine(lines[0]).map((value) => value.trim().toLowerCase());
  const indexes = Object.fromEntries(Object.keys(aliases).map((field) => [field, headerIndex(headers, field)]));
  if (indexes.phone < 0 && indexes.email < 0) throw new Error("CSV needs a phone_number/phone or email column.");
  return lines.slice(1).map((line, index) => {
    const cells = parseLine(line);
    const get = (field) => indexes[field] >= 0 ? String(cells[indexes[field]] || "").trim() : "";
    const fullName = get("name");
    const firstName = get("first_name") || fullName.split(/\s+/)[0] || "";
    const lastName = get("last_name") || fullName.split(/\s+/).slice(1).join(" ");
    return {
      row_number: index + 2,
      first_name: firstName,
      last_name: lastName,
      email: get("email").toLowerCase(),
      phone: get("phone").replace(/^p:\s*/i, ""),
    };
  }).filter((row) => row.phone || row.email || row.first_name || row.last_name);
}

export function downloadCsv(filename, rows) {
  if (!rows.length) return;
  const columns = [...new Set(rows.flatMap((row) => Object.keys(row)))];
  const cell = (value) => {
    const raw = value == null ? "" : typeof value === "object" ? JSON.stringify(value) : String(value);
    const safe = /^\s*[=+\-@]/.test(raw) ? `'${raw}` : raw;
    return /[",\r\n]/.test(safe) ? `"${safe.replaceAll('"', '""')}"` : safe;
  };
  const csv = [columns.map(cell).join(","), ...rows.map((row) => columns.map((column) => cell(row[column])).join(","))].join("\r\n");
  const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  URL.revokeObjectURL(url);
}
