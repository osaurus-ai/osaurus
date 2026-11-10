// Minimal runnable property for "Log in with Osaurus", using only node:http
// and verify.ts. For local development:
//
//   npm install
//   ORIGIN=http://localhost:8787 npm start
//
// http://localhost origins are accepted only by DEBUG builds of Osaurus with
// the developer override set (see docs/LOGIN_WITH_OSAURUS.md, "Local
// development"). In production ORIGIN is your https origin.

import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { randomBytes } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { MemoryLoginTransactionStore, OsaurusLoginError, OsaurusLoginRelyingParty } from "./verify.ts";
const ORIGIN = process.env.ORIGIN ?? "http://localhost:8787";
const PORT = Number(new URL(ORIGIN).port || process.env.PORT || 8787);
const SECURE = ORIGIN.startsWith("https://");
// `__Host-` cookies require Secure, so plain-http development drops the prefix.
const TXN_COOKIE = SECURE ? "__Host-osl_txn" : "osl_txn";
const SESSION_COOKIE = SECURE ? "__Host-session" : "session";
const here = dirname(fileURLToPath(import.meta.url));

const rp = new OsaurusLoginRelyingParty({
  origin: ORIGIN,
  redirectUri: `${ORIGIN}/auth/osaurus/callback`,
  store: new MemoryLoginTransactionStore(),
});

/** Your real app keeps sessions in its own store. */
const sessions = new Map<string, { address: string; osaurusId?: string }>();

function cookies(req: IncomingMessage): Record<string, string> {
  return Object.fromEntries(
    (req.headers.cookie ?? "").split(";").map((pair) => {
      const index = pair.indexOf("=");
      return [pair.slice(0, index).trim(), decodeURIComponent(pair.slice(index + 1).trim())];
    }),
  );
}

function cookie(name: string, value: string, maxAge: number): string {
  return `${name}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${SECURE ? "; Secure" : ""}`;
}

async function body(req: IncomingMessage): Promise<Record<string, string>> {
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 16_384) throw new Error("body too large");
  }
  return raw ? JSON.parse(raw) : {};
}

function send(res: ServerResponse, status: number, payload: unknown, headers: Record<string, string | string[]> = {}) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store", ...headers });
  res.end(JSON.stringify(payload));
}

function page(res: ServerResponse, html: string) {
  res.writeHead(200, {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
    "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline'",
  });
  res.end(html);
}

const homePage = (who: string | null) => `<!doctype html>
<meta charset="utf-8"><title>Log in with Osaurus</title>
<h1>${who ? `Signed in as ${who}` : "Not signed in"}</h1>
${who ? `<form method="post" action="/logout"><button>Sign out</button></form>` : `<button id="login">Log in with Osaurus</button>`}
<p id="status"></p>
<script type="module">
  import { startOsaurusLogin } from "/client.js";
  const status = document.getElementById("status");
  document.getElementById("login")?.addEventListener("click", async () => {
    status.textContent = "Continue in Osaurus…";
    try {
      await startOsaurusLogin({ onNotInstalled: () => (status.textContent = "Osaurus didn't open. Is it installed?") });
      location.reload();
    } catch (error) {
      status.textContent = "Sign-in failed: " + (error.code || error.message);
    }
  });
</script>`;

const callbackPage = `<!doctype html>
<meta charset="utf-8"><title>Signing in…</title>
<p id="status">Signing in…</p>
<script type="module">
  import { handleOsaurusCallback } from "/client.js";
  const status = document.getElementById("status");
  try {
    await handleOsaurusCallback();
    location.replace("/");
  } catch (error) {
    if (error.code === "browser_mismatch") {
      status.textContent = "This login was started in another browser on this Mac. Paste this link there to finish, and never send it to anyone: " + error.continueURL;
    } else {
      status.textContent = "Sign-in failed: " + (error.code || error.message);
    }
  }
</script>`;

createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", ORIGIN);
  const jar = cookies(req);
  try {
    if (req.method === "GET" && url.pathname === "/") {
      const session = sessions.get(jar[SESSION_COOKIE] ?? "");
      const who = session ? (session.osaurusId ? `@${session.osaurusId} (${session.address})` : session.address) : null;
      return page(res, homePage(who));
    }
    if (req.method === "GET" && url.pathname === "/client.js") {
      res.writeHead(200, { "content-type": "text/javascript", "cache-control": "no-store" });
      return res.end(readFileSync(join(here, "client.js")));
    }
    if (req.method === "GET" && url.pathname === "/auth/osaurus/callback") {
      return page(res, callbackPage);
    }
    if (req.method !== "POST") return send(res, 404, { error: "not_found" });

    // All state-changing endpoints are same-origin only.
    if (req.headers.origin !== ORIGIN) return send(res, 403, { error: "bad_origin" });

    if (url.pathname === "/auth/osaurus/start") {
      const { code_challenge } = await body(req);
      const started = await rp.start({ codeChallenge: code_challenge });
      return send(res, 200, { state: started.state, authorize_url: started.authorizeUrl }, {
        "set-cookie": cookie(TXN_COOKIE, started.transactionId, 300),
      });
    }
    if (url.pathname === "/auth/osaurus/callback") {
      const { assertion, state } = await body(req);
      const claims = await rp.callback({ assertion, state, transactionId: jar[TXN_COOKIE] });
      const sessionId = randomBytes(32).toString("base64url");
      sessions.set(sessionId, { address: claims.iss, osaurusId: claims.osaurus_id });
      console.log(`signed in ${claims.iss} (jti ${claims.jti}, dev ${claims.dev ?? "-"})`);
      return send(res, 200, { address: claims.iss }, {
        "set-cookie": [cookie(SESSION_COOKIE, sessionId, 60 * 60 * 24 * 30), cookie(TXN_COOKIE, "", 0)],
      });
    }
    if (url.pathname === "/auth/osaurus/status") {
      const { state, code_verifier } = await body(req);
      return send(res, 200, await rp.status({ state, codeVerifier: code_verifier, transactionId: jar[TXN_COOKIE] }));
    }
    if (url.pathname === "/logout") {
      sessions.delete(jar[SESSION_COOKIE] ?? "");
      res.writeHead(303, { location: "/", "set-cookie": cookie(SESSION_COOKIE, "", 0) });
      return res.end();
    }
    return send(res, 404, { error: "not_found" });
  } catch (error) {
    if (error instanceof OsaurusLoginError) {
      console.log(`rejected: ${error.code}`);
      return send(res, error.code === "browser_mismatch" ? 409 : 400, { error: error.code });
    }
    console.error(error);
    return send(res, 500, { error: "server_error" });
  }
}).listen(PORT, () => console.log(`Log in with Osaurus example on ${ORIGIN}`));
