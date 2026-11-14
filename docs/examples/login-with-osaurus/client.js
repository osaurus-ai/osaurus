// Browser side of "Log in with Osaurus" (osl-v1). Two entry points:
//
//   startOsaurusLogin()      — on the "Log in with Osaurus" button
//   handleOsaurusCallback()  — on the redirect_uri page
//
// The endpoints match docs/examples/login-with-osaurus/verify.ts. No
// dependencies; works in every current browser.

const CHANNEL = "osaurus-login";
const POLL_MS = 2000;
const GIVE_UP_MS = 5 * 60 * 1000;

function base64url(bytes) {
  let binary = "";
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function postJSON(path, body) {
  const response = await fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw Object.assign(new Error(data.error || `HTTP ${response.status}`), { code: data.error });
  return data;
}

/**
 * Opens Osaurus and resolves once this browser is signed in.
 * `onNotInstalled` fires when nothing handled the osaurus:// link.
 */
export async function startOsaurusLogin({ onNotInstalled } = {}) {
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const challenge = base64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  const { state, authorize_url } = await postJSON("/auth/osaurus/start", { code_challenge: challenge });

  // If Osaurus opens, this page loses focus. If it never does, Osaurus is
  // probably not installed.
  let left = false;
  const markLeft = () => (left = true);
  window.addEventListener("blur", markLeft, { once: true });
  document.addEventListener("visibilitychange", markLeft, { once: true });
  setTimeout(() => {
    if (!left && onNotInstalled) onNotInstalled();
  }, 2500);

  window.location.href = authorize_url;
  return waitForCompletion(state, verifier);
}

function waitForCompletion(state, verifier) {
  return new Promise((resolve, reject) => {
    const channel = "BroadcastChannel" in window ? new BroadcastChannel(CHANNEL) : null;
    const startedAt = Date.now();
    let timer;

    const finish = (fn, value) => {
      clearTimeout(timer);
      channel?.close();
      fn(value);
    };

    // Fast path: the callback tab in this browser announces the result.
    if (channel) {
      channel.onmessage = ({ data }) => {
        if (data?.state !== state) return;
        if (data.error) finish(reject, Object.assign(new Error(data.error), { code: data.error }));
      };
    }

    // Authoritative path: ask the server, proving we started this login.
    const poll = async () => {
      try {
        const result = await postJSON("/auth/osaurus/status", { state, code_verifier: verifier });
        if (result.status === "complete") return finish(resolve, result);
        if (result.status === "expired") return finish(reject, Object.assign(new Error("expired"), { code: "expired" }));
      } catch (error) {
        return finish(reject, error);
      }
      if (Date.now() - startedAt > GIVE_UP_MS) {
        return finish(reject, Object.assign(new Error("timeout"), { code: "timeout" }));
      }
      timer = setTimeout(poll, POLL_MS);
    };
    timer = setTimeout(poll, POLL_MS);
  });
}

/**
 * Run on the redirect_uri page. Resolves with the server's answer, or
 * rejects with `code` = the OAuth error (`access_denied`, ...) or the
 * server error (`browser_mismatch`, `expired`, ...).
 */
export async function handleOsaurusCallback() {
  const raw = window.location.hash ? window.location.hash.slice(1) : window.location.search.slice(1);
  const params = new URLSearchParams(raw);
  // Keep the one-time assertion out of history and later Referer headers.
  window.history.replaceState(null, "", window.location.pathname);

  const state = params.get("state");
  const channel = "BroadcastChannel" in window ? new BroadcastChannel(CHANNEL) : null;
  const announce = (message) => {
    channel?.postMessage({ state, ...message });
    channel?.close();
  };

  const error = params.get("error");
  if (error) {
    announce({ error });
    throw Object.assign(new Error(params.get("error_description") || error), { code: error });
  }

  const assertion = params.get("assertion");
  if (!assertion || !state) throw Object.assign(new Error("missing assertion"), { code: "invalid_request" });

  try {
    const result = await postJSON("/auth/osaurus/callback", { assertion, state });
    announce({ ok: true });
    return result;
  } catch (failure) {
    // browser_mismatch: Osaurus opened the default browser, but the login
    // was started in another one. The link still works there until it expires.
    if (failure.code === "browser_mismatch") {
      failure.continueURL = `${window.location.origin}${window.location.pathname}#${raw}`;
    } else {
      announce({ error: failure.code || "server_error" });
    }
    throw failure;
  }
}
