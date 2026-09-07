import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { resolve, sep } from "node:path";

const [, , inputArgument = "supabase/004_zip_geo_lookup_data.sql", outputArgument = "supabase/zip_geo_chunks"] = process.argv;
const inputPath = resolve(inputArgument);
const outputDirectory = resolve(outputArgument);
const supabaseDirectory = resolve("supabase");
if (!outputDirectory.startsWith(`${supabaseDirectory}${sep}`)) {
  throw new Error("The chunk output directory must be a child of this project's supabase directory.");
}
const source = await readFile(inputPath, "utf8");
const statements = source
  .split(/(?=insert into public\.zip_geo_lookup \(zip_code,state,county,metro,city,source\) values\r?\n)/)
  .filter((part) => part.startsWith("insert into public.zip_geo_lookup"))
  .map((part) => part.replace(/\r?\ncommit;\s*$/i, "").trim());

if (!statements.length) throw new Error("No ZIP lookup insert statements were found.");

const statementsPerFile = 8;
const fileCount = Math.ceil(statements.length / statementsPerFile);
await rm(outputDirectory, { recursive: true, force: true });
await mkdir(outputDirectory, { recursive: true });

const results = [];
for (let index = 0; index < fileCount; index += 1) {
  const number = String(index + 1).padStart(2, "0");
  const filename = `004_${number}_zip_geo_lookup_data.sql`;
  const batch = statements.slice(index * statementsPerFile, (index + 1) * statementsPerFile);
  const contents = [
    `-- ZIP geography browser-safe part ${index + 1} of ${fileCount}.`,
    "-- Run 003_county_metro_filters.sql first, then run every 004 part in numeric order.",
    "",
    "begin;",
    "",
    batch.join("\n\n"),
    "",
    "commit;",
    "",
  ].join("\n");
  const path = resolve(outputDirectory, filename);
  await writeFile(path, contents, "utf8");
  results.push({ filename, bytes: Buffer.byteLength(contents), insertStatements: batch.length });
}

process.stdout.write(JSON.stringify({ input: inputPath, outputDirectory, files: results }, null, 2));
