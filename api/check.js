import { checkOne, PAGES, validIpv4, DEFAULT_STAGING_IP, normalizePath } from "../lib/check.js";

export async function GET(request) {
  const url = new URL(request.url);
  const site = url.searchParams.get("site") || "";
  const page = url.searchParams.get("page") || "";
  const customPath = url.searchParams.get("path") || "";
  const ip = url.searchParams.get("ip") || DEFAULT_STAGING_IP;
  const path = customPath ? normalizePath(customPath) : PAGES[page];
  if (!/^[A-Za-z0-9_]+$/.test(site) || !path) {
    return Response.json({ error: "국가와 페이지 경로를 확인하세요." }, { status: 400 });
  }
  if (!validIpv4(ip)) {
    return Response.json({ error: "스테이징 IP 형식을 확인하세요." }, { status: 400 });
  }
  return Response.json(await checkOne(site, page, ip, path));
}
