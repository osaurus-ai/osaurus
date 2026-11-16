// Conformance check for a relying-party implementation against vector.json.
//
//   npm install
//   npm run check-vector

import { readFileSync } from "node:fs";
import { privateKeyToAccount } from "viem/accounts";
import { OSAURUS_LOGIN, OsaurusLoginError, verifyOsaurusAssertion } from "./verify.ts";

const vector = JSON.parse(readFileSync(new URL("./vector.json", import.meta.url), "utf8"));
const expected = {
  audience: vector.request.client_id,
  redirectUri: vector.request.redirect_uri,
  nonce: vector.request.nonce,
  now: vector.verify_at,
};

let failures = 0;
function check(name: string, ok: boolean) {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (!ok) failures++;
}

async function rejects(name: string, code: string, run: () => Promise<unknown>) {
  try {
    await run();
    check(`${name} (accepted, expected ${code})`, false);
  } catch (error) {
    check(`${name} -> ${(error as OsaurusLoginError).code}`, (error as OsaurusLoginError).code === code);
  }
}

function forge(payload: object, privateKey: `0x${string}`) {
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return privateKeyToAccount(privateKey)
    .signMessage({ message: OSAURUS_LOGIN.messagePrefix + encoded })
    .then((signature) => `${OSAURUS_LOGIN.tokenPrefix}.${encoded}.${signature}`);
}

const claims = await verifyOsaurusAssertion(vector.assertion, expected);
check("vector verifies", claims.iss === vector.address);
check("vector payload matches", JSON.stringify(claims) === JSON.stringify(vector.payload));

const [, encoded, signature] = vector.assertion.split(".");
const resigned = await privateKeyToAccount(vector.private_key).signMessage({
  message: OSAURUS_LOGIN.messagePrefix + encoded,
});
check("viem reproduces the Swift signature byte for byte", resigned === signature);

await rejects("other audience", "audience_mismatch", () =>
  verifyOsaurusAssertion(vector.assertion, { ...expected, audience: "https://osaurus.ai" }));
await rejects("other redirect", "redirect_uri_mismatch", () =>
  verifyOsaurusAssertion(vector.assertion, { ...expected, redirectUri: "https://store.osaurus.ai/x" }));
await rejects("other nonce", "nonce_mismatch", () =>
  verifyOsaurusAssertion(vector.assertion, { ...expected, nonce: "another-nonce-0123456789" }));
await rejects("expired", "expired", () =>
  verifyOsaurusAssertion(vector.assertion, { ...expected, now: vector.payload.exp + 61 }));
await rejects("from the future", "issued_in_future", () =>
  verifyOsaurusAssertion(vector.assertion, { ...expected, now: vector.payload.iat - 61 }));

const bob = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
await rejects("another key claiming the vector address", "bad_signature", async () =>
  verifyOsaurusAssertion(await forge(vector.payload, bob), expected));

const tampered = vector.assertion.slice(0, -4) + (vector.assertion.endsWith("1c") ? "001b" : "001c");
await rejects("tampered signature", "bad_signature", () => verifyOsaurusAssertion(tampered, expected));

await rejects("long lifetime", "lifetime_too_long", async () =>
  verifyOsaurusAssertion(
    await forge({ ...vector.payload, exp: vector.payload.iat + 3600 }, vector.private_key),
    expected,
  ));

await rejects("wrong prefix", "malformed", () =>
  verifyOsaurusAssertion(vector.assertion.replace("osl-v1", "osl-v2"), expected));

console.log(failures === 0 ? "\nall checks passed" : `\n${failures} check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
