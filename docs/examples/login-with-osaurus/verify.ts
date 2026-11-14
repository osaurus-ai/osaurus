// Reference relying-party implementation for "Log in with Osaurus" (osl-v1).
//
// Framework-agnostic: wire `OsaurusLoginRelyingParty.start`, `.callback`, and
// `.status` to three POST endpoints and issue your own session after
// `.callback` succeeds. Only dependency: viem (`npm install viem`).
//
// Spec: docs/LOGIN_WITH_OSAURUS.md

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { isAddress, verifyMessage } from "viem";

export const OSAURUS_LOGIN = {
  tokenPrefix: "osl-v1",
  messagePrefix: "osaurus-login-v1.",
  type: "osaurus-login",
  version: 1,
  maxLifetimeSeconds: 300,
  defaultClockSkewSeconds: 60,
} as const;

export interface OsaurusLoginClaims {
  typ: "osaurus-login";
  ver: 1;
  /** Lowercase master address. Use this as the account key. */
  iss: `0x${string}`;
  aud: string;
  redirect_uri: string;
  nonce: string;
  iat: number;
  exp: number;
  jti: string;
  /** Display hint only. Never authorize on it. */
  osaurus_id?: string;
  dev?: string;
}

export type OsaurusLoginErrorCode =
  | "malformed"
  | "bad_signature"
  | "wrong_type"
  | "audience_mismatch"
  | "redirect_uri_mismatch"
  | "nonce_mismatch"
  | "lifetime_too_long"
  | "issued_in_future"
  | "expired"
  | "unknown_state"
  | "browser_mismatch"
  | "already_used";

export class OsaurusLoginError extends Error {
  readonly code: OsaurusLoginErrorCode;

  constructor(code: OsaurusLoginErrorCode, message: string = code) {
    super(message);
    this.name = "OsaurusLoginError";
    this.code = code;
  }
}

export interface VerifyExpectations {
  /** Your origin, exactly as you send it as `client_id`. */
  audience: string;
  /** Your callback URL, exactly as you send it as `redirect_uri`. */
  redirectUri: string;
  /** The nonce you issued for this login. */
  nonce: string;
  /** Unix seconds. Defaults to now. */
  now?: number;
  clockSkewSeconds?: number;
}

/**
 * Verifies an `osl-v1` assertion: signature, then every claim. Does NOT
 * consume the nonce; do that atomically after this returns.
 */
export async function verifyOsaurusAssertion(
  assertion: string,
  expected: VerifyExpectations,
): Promise<OsaurusLoginClaims> {
  const parts = assertion.split(".");
  if (parts.length !== 3 || parts[0] !== OSAURUS_LOGIN.tokenPrefix) {
    throw new OsaurusLoginError("malformed");
  }
  const [, encodedPayload, signature] = parts;
  if (!/^[A-Za-z0-9_-]+$/.test(encodedPayload) || !/^0x[0-9a-fA-F]{130}$/.test(signature)) {
    throw new OsaurusLoginError("malformed");
  }

  let claims: OsaurusLoginClaims;
  try {
    claims = JSON.parse(Buffer.from(encodedPayload, "base64url").toString("utf8"));
  } catch {
    throw new OsaurusLoginError("malformed");
  }
  if (
    typeof claims !== "object" || claims === null ||
    typeof claims.iss !== "string" || !isAddress(claims.iss, { strict: false }) ||
    typeof claims.aud !== "string" || typeof claims.redirect_uri !== "string" ||
    typeof claims.nonce !== "string" || typeof claims.jti !== "string" ||
    !Number.isInteger(claims.iat) || !Number.isInteger(claims.exp)
  ) {
    throw new OsaurusLoginError("malformed");
  }

  // EIP-191 personal_sign over the literal prefix + the base64url payload,
  // exactly as received. Never re-encode the payload before checking.
  const valid = await verifyMessage({
    address: claims.iss,
    message: OSAURUS_LOGIN.messagePrefix + encodedPayload,
    signature: signature as `0x${string}`,
  }).catch(() => false);
  if (!valid) throw new OsaurusLoginError("bad_signature");

  if (claims.typ !== OSAURUS_LOGIN.type || claims.ver !== OSAURUS_LOGIN.version) {
    throw new OsaurusLoginError("wrong_type");
  }
  if (claims.aud !== expected.audience) throw new OsaurusLoginError("audience_mismatch");
  if (claims.redirect_uri !== expected.redirectUri) throw new OsaurusLoginError("redirect_uri_mismatch");
  if (!safeEqual(claims.nonce, expected.nonce)) throw new OsaurusLoginError("nonce_mismatch");

  const now = expected.now ?? Math.floor(Date.now() / 1000);
  const skew = expected.clockSkewSeconds ?? OSAURUS_LOGIN.defaultClockSkewSeconds;
  if (claims.exp - claims.iat > OSAURUS_LOGIN.maxLifetimeSeconds) throw new OsaurusLoginError("lifetime_too_long");
  if (claims.iat > now + skew) throw new OsaurusLoginError("issued_in_future");
  if (claims.exp <= now - skew) throw new OsaurusLoginError("expired");

  return { ...claims, iss: claims.iss.toLowerCase() as `0x${string}` };
}

// MARK: - Login transactions

export interface LoginTransaction {
  /** Random id kept in an HttpOnly cookie in the browser that started the login. */
  id: string;
  state: string;
  nonce: string;
  /** base64url(SHA-256(code_verifier)), held by the tab that started the login. */
  codeChallenge: string;
  /** Unix seconds. */
  expiresAt: number;
  status: "pending" | "complete";
  address?: string;
}

/** Back this with Redis, a database row, or anything with an atomic update. */
export interface LoginTransactionStore {
  create(txn: LoginTransaction): Promise<void>;
  getByState(state: string): Promise<LoginTransaction | undefined>;
  /** Atomically flip pending -> complete. False when it was not pending. */
  complete(state: string, address: string): Promise<boolean>;
  delete(state: string): Promise<void>;
}

export class MemoryLoginTransactionStore implements LoginTransactionStore {
  private readonly byState = new Map<string, LoginTransaction>();
  async create(txn: LoginTransaction) {
    this.byState.set(txn.state, txn);
  }
  async getByState(state: string) {
    return this.byState.get(state);
  }
  async complete(state: string, address: string) {
    const txn = this.byState.get(state);
    if (!txn || txn.status !== "pending") return false;
    txn.status = "complete";
    txn.address = address;
    return true;
  }
  async delete(state: string) {
    this.byState.delete(state);
  }
}

export interface RelyingPartyOptions {
  /** e.g. "https://store.osaurus.ai" — must be on the Osaurus allowlist. */
  origin: string;
  /** e.g. "https://store.osaurus.ai/auth/osaurus/callback" */
  redirectUri: string;
  store: LoginTransactionStore;
  ttlSeconds?: number;
  responseMode?: "fragment" | "query";
  now?: () => number;
}

export class OsaurusLoginRelyingParty {
  private readonly options: RelyingPartyOptions;
  private readonly ttl: number;
  private readonly now: () => number;

  constructor(options: RelyingPartyOptions) {
    this.options = options;
    this.ttl = options.ttlSeconds ?? 300;
    this.now = options.now ?? (() => Math.floor(Date.now() / 1000));
  }

  /**
   * POST /auth/osaurus/start  { code_challenge }
   * Set `transactionId` as an HttpOnly, Secure, SameSite=Lax cookie that
   * lives `ttlSeconds`, and return `{ state, authorize_url }` to the page.
   */
  async start(input: { codeChallenge: string }) {
    if (!/^[A-Za-z0-9_-]{43}$/.test(input.codeChallenge)) throw new OsaurusLoginError("malformed");
    const txn: LoginTransaction = {
      id: randomToken(),
      state: randomToken(),
      nonce: randomToken(),
      codeChallenge: input.codeChallenge,
      expiresAt: this.now() + this.ttl,
      status: "pending",
    };
    await this.options.store.create(txn);
    const url = new URL("osaurus://auth/authorize");
    url.searchParams.set("client_id", this.options.origin);
    url.searchParams.set("redirect_uri", this.options.redirectUri);
    url.searchParams.set("state", txn.state);
    url.searchParams.set("nonce", txn.nonce);
    if (this.options.responseMode === "query") url.searchParams.set("response_mode", "query");
    return { transactionId: txn.id, state: txn.state, authorizeUrl: url.toString() };
  }

  /**
   * POST /auth/osaurus/callback  { assertion, state }  (+ the transaction cookie)
   * On success, issue your session for `claims.iss` and clear the
   * transaction cookie. A `browser_mismatch` leaves the login usable, so the
   * user can paste the callback link into the browser they started in.
   */
  async callback(input: { assertion: string; state: string; transactionId: string | undefined }) {
    const txn = await this.options.store.getByState(input.state);
    if (!txn || txn.expiresAt <= this.now()) throw new OsaurusLoginError("unknown_state");
    if (txn.status !== "pending") throw new OsaurusLoginError("already_used");
    if (!input.transactionId || !safeEqual(input.transactionId, txn.id)) {
      throw new OsaurusLoginError("browser_mismatch");
    }
    const claims = await verifyOsaurusAssertion(input.assertion, {
      audience: this.options.origin,
      redirectUri: this.options.redirectUri,
      nonce: txn.nonce,
      now: this.now(),
    });
    if (!(await this.options.store.complete(txn.state, claims.iss))) {
      throw new OsaurusLoginError("already_used");
    }
    return claims;
  }

  /**
   * POST /auth/osaurus/status  { state, code_verifier }  (+ the transaction cookie)
   * Polled by the tab that started the login. The session itself was set
   * by `callback` in the same browser; this only says when to reload.
   */
  async status(input: { state: string; codeVerifier: string; transactionId: string | undefined }) {
    const txn = await this.options.store.getByState(input.state);
    if (!txn || !input.transactionId || !safeEqual(input.transactionId, txn.id)) {
      throw new OsaurusLoginError("unknown_state");
    }
    if (!safeEqual(pkceChallenge(input.codeVerifier), txn.codeChallenge)) {
      throw new OsaurusLoginError("unknown_state");
    }
    if (txn.status === "complete") {
      await this.options.store.delete(txn.state);
      return { status: "complete" as const, address: txn.address! };
    }
    if (txn.expiresAt <= this.now()) {
      await this.options.store.delete(txn.state);
      return { status: "expired" as const };
    }
    return { status: "pending" as const };
  }
}

export function pkceChallenge(verifier: string): string {
  return createHash("sha256").update(verifier, "utf8").digest("base64url");
}

function randomToken(): string {
  return randomBytes(32).toString("base64url");
}

function safeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  return left.length === right.length && timingSafeEqual(left, right);
}
