import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export async function GET() {
  const file = fileURLToPath(new URL("../sitecodes.txt", import.meta.url));
  const sites = readFileSync(file, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"))
    .map((line) => line.split(/\s+/)[0])
    .filter((code) => /^[A-Za-z0-9_]+$/.test(code));
  return Response.json({ sites });
}
