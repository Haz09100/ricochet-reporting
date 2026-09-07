import { createReadStream, createWriteStream } from "node:fs";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { basename, resolve } from "node:path";

const [, , inputArgument, outputArgument = "supabase/004_zip_geo_lookup_data.sql"] = process.argv;
if (!inputArgument) {
  throw new Error("Usage: node scripts/build-zip-geo-sql.mjs <zillow.csv> [output.sql]");
}

function parseCsvRow(line) {
  const values = [];
  let value = "";
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (character === '"' && quoted && line[index + 1] === '"') {
      value += '"';
      index += 1;
    } else if (character === '"') quoted = !quoted;
    else if (character === "," && !quoted) {
      values.push(value);
      value = "";
    } else value += character;
  }
  values.push(value);
  return values;
}

function sqlText(value) {
  if (value == null || String(value).trim() === "") return "null";
  return `'${String(value).trim().replaceAll("'", "''")}'`;
}

const inputPath = resolve(inputArgument);
const outputPath = resolve(outputArgument);
const lines = createInterface({ input: createReadStream(inputPath), crlfDelay: Infinity });
const records = new Map();
let indexes;

for await (const line of lines) {
  if (!indexes) {
    const headers = parseCsvRow(line.replace(/^\uFEFF/, ""));
    indexes = Object.fromEntries(["RegionName", "State", "CountyName", "Metro", "City"].map((name) => [name, headers.indexOf(name)]));
    const missing = Object.entries(indexes).filter(([, index]) => index < 0).map(([name]) => name);
    if (missing.length) throw new Error(`Missing required CSV columns: ${missing.join(", ")}`);
    continue;
  }
  if (!line.trim()) continue;
  const cells = parseCsvRow(line);
  const zipCode = String(cells[indexes.RegionName] || "").trim().padStart(5, "0");
  const state = String(cells[indexes.State] || "").trim().toUpperCase();
  const county = String(cells[indexes.CountyName] || "").trim();
  if (!/^\d{5}$/.test(zipCode) || !/^[A-Z]{2}$/.test(state) || !county) continue;
  records.set(zipCode, {
    zipCode,
    state,
    county,
    metro: String(cells[indexes.Metro] || "").trim(),
    city: String(cells[indexes.City] || "").trim(),
  });
}

const sorted = [...records.values()].sort((left, right) => left.zipCode.localeCompare(right.zipCode));
const output = createWriteStream(outputPath, { encoding: "utf8" });
output.write(`-- Generated from ${basename(inputPath)}.\n`);
output.write("-- Run supabase/003_county_metro_filters.sql before this file.\n\n");
output.write("begin;\n\n");
for (let offset = 0; offset < sorted.length; offset += 500) {
  const batch = sorted.slice(offset, offset + 500);
  output.write("insert into public.zip_geo_lookup (zip_code,state,county,metro,city,source) values\n");
  output.write(batch.map((record) => `  (${sqlText(record.zipCode)},${sqlText(record.state)},${sqlText(record.county)},${sqlText(record.metro)},${sqlText(record.city)},'Zillow ZHVI ZIP geography')`).join(",\n"));
  output.write("\non conflict (zip_code) do update set\n  state=excluded.state, county=excluded.county, metro=excluded.metro, city=excluded.city, source=excluded.source;\n\n");
}
output.end("commit;\n");
await once(output, "finish");

const florida = sorted.filter((record) => record.state === "FL");
const floridaCounties = new Set(florida.map((record) => record.county));
const floridaMetros = new Set(florida.map((record) => record.metro).filter(Boolean));
process.stdout.write(JSON.stringify({ output: outputPath, zipCodes: sorted.length, floridaZipCodes: florida.length, floridaCounties: floridaCounties.size, floridaMetros: floridaMetros.size }, null, 2));
