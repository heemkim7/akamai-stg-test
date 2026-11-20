import https from "node:https";

const HOST = "www.samsung.com";
export const DEFAULT_STAGING_IP = "23.220.3.157";

export const PAGES = {
  mypage: "/mypage/",
  myproducts: "/mypage/myproducts/",
  myrepair: "/mypage/myrepair/",
  "track-repair": "/mypage/myrepair/track-repair/",
  getsupport: "/mypage/getsupport/",
  mysmartthings: "/mypage/mysmartthings/",
  rewards: "/mypage/rewards/",
};

export function validIpv4(ip) {
  if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(ip)) return false;
  return ip.split(".").every((part) => {
    const n = Number(part);
    return n >= 0 && n <= 255;
  });
}

function stagingLookup(ip) {
  return function lookup(hostname, options, callback) {
    if (typeof options === "function") {
      callback = options;
      options = {};
    }
    if (options && options.all) {
      callback(null, [{ address: ip, family: 4 }]);
      return;
    }
    callback(null, ip, 4);
  };
}

function absoluteLocation(requestUrl, location) {
  if (!location) return "";
  try {
    return new URL(location, requestUrl).href;
  } catch {
    return location;
  }
}

function locationOk(location, site) {
  const expect = `https://${HOST}/${site}/common/parking`.toLowerCase();
  const actual = String(location).replace(/\/+$/, "").toLowerCase();
  if (!actual.startsWith(expect)) return false;
  if (actual.length === expect.length) return true;
  const next = actual[expect.length];
  return next === "/" || next === "?" || next === "#";
}

export function normalizePath(value) {
  const path = String(value || "").trim();
  const withSlash = path.startsWith("/") ? path : `/${path}`;
  if (withSlash === "/" || withSlash.includes("..") || !/^\/[A-Za-z0-9._~/-]*$/.test(withSlash)) return "";
  return withSlash;
}

export function checkOne(site, page, stagingIp = DEFAULT_STAGING_IP, customPath = "") {
  const path = customPath ? normalizePath(customPath) : PAGES[page];
  const ip = validIpv4(stagingIp) ? stagingIp : DEFAULT_STAGING_IP;
  const requestUrl = `https://${HOST}/${site}${path}`;
  return new Promise((resolve) => {
    const req = https.request(
      {
        hostname: HOST,
        path: `/${site}${path}`,
        method: "GET",
        timeout: 20000,
        headers: {
          Accept: "text/html",
          "User-Agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        },
        lookup: stagingLookup(ip),
      },
      (res) => {
        res.resume();
        const location = absoluteLocation(requestUrl, res.headers.location || "");
        const staging = res.headers["x-akamai-staging"] || "";
        const reasons = [];
        const redirect = [301, 302, 303, 307, 308].includes(res.statusCode);
        if (!redirect) reasons.push(`상태코드 ${res.statusCode}`);
        if (!location) reasons.push("Location 없음");
        else if (!locationOk(location, site)) reasons.push("Location 불일치");
        if (!staging) reasons.push("스테이징 헤더 없음");
        resolve({
          result: reasons.length ? "FAIL" : "OK",
          sitecode: site,
          path,
          status: res.statusCode,
          location: location || "-",
          staging,
          reason: reasons.join("; "),
        });
      },
    );
    req.on("timeout", () => req.destroy(new Error("시간 초과")));
    req.on("error", (err) => {
      resolve({
        result: "FAIL",
        sitecode: site,
        path,
        status: "ERR",
        location: "-",
        staging: "",
        reason: err.message,
      });
    });
    req.end();
  });
}
