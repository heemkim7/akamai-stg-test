import { createServer } from "node:http";
import { createReadStream, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { GET as check } from "./api/check.js";
import { GET as sites } from "./api/sites.js";

const root = path.dirname(fileURLToPath(import.meta.url));
const publicDir = path.join(root, "public");
const handlers = { "/api/check": check, "/api/sites": sites };

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  const handler = handlers[url.pathname];
  if (handler) {
    const response = await handler(new Request(url));
    res.statusCode = response.status;
    response.headers.forEach((value, key) => res.setHeader(key, value));
    res.end(Buffer.from(await response.arrayBuffer()));
    return;
  }
  const rel = url.pathname === "/" ? "index.html" : url.pathname.replace(/^\/+/, "");
  const file = path.join(publicDir, rel);
  if (!file.startsWith(publicDir) || !existsSync(file)) {
    res.statusCode = 404;
    res.end("not found");
    return;
  }
  res.setHeader("content-type", "text/html; charset=utf-8");
  createReadStream(file).pipe(res);
});

const port = Number(process.env.PORT) || 3000;
server.listen(port, "127.0.0.1", () => {
  console.log(`http://127.0.0.1:${port}`);
});
