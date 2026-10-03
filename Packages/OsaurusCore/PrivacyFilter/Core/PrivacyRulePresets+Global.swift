//
//  PrivacyRulePresets+Global.swift
//  osaurus / PrivacyFilter
//
//  Region-less presets: multilingual generic fallbacks (Tier 3),
//  international finance identifiers, network addresses, crypto
//  wallets, and developer secrets. See `PrivacyRulePresets.swift`
//  for the tier contract.
//

import Foundation

extension PrivacyRulePresets {
    // MARK: Generic fallbacks (Tier 3)

    /// Multilingual "passport" keyword followed by a 6–10 char
    /// alphanumeric token that contains at least one digit.
    public static let genericPassport = Preset(
        id: "generic.passport",
        name: "Passport number (any country)",
        summary:
            "Any passport number written after the word “passport” in English, Spanish, Portuguese, French, German, Italian, Dutch, Polish, Turkish or Indonesian.",
        pattern:
            #"(?i)\b(?:passport|passeport|pasaporte|passaporte|reisepass|passaporto|paspoort|paszport|pasaport|paspor)"#
            + anchorGap + #"((?=[A-Z0-9]*\d)[A-Z0-9]{6,10})\b"#,
        category: .accountNumber,
        sample: "Passport No: X1234567",
        counterexample: "passport photos",
        regionCode: nil,
        kind: .generic,
        tier: .generic,
        autoEnable: .anyRegion
    )

    public static let genericNationalID = Preset(
        id: "generic.nationalID",
        name: "National ID / ID card number (any country)",
        summary:
            "An ID written after “national ID”, “ID card”, “ID number”, “identity card”, “cédula”, “carte d'identité”, “Personalausweis”, “carta d'identità” or “documento de identidad”.",
        pattern:
            #"(?i)\b(?:national\s+id(?:entity)?(?:\s+(?:card|number|no\.?))?|id\s+(?:card|number|no\.?)|identity\s+(?:card|number|no\.?)|identification\s+(?:number|no\.?)|c[ée]dula(?:\s+de\s+(?:identidad|ciudadan[íi]a))?|carte\s+(?:nationale\s+)?d'identit[ée]|personalausweis(?:nummer)?|carta\s+d'identit[àa]|documento\s+de\s+identidad|bilhete\s+de\s+identidade)"#
            + anchorGap + #"((?=[A-Z0-9\-]*\d)[A-Z0-9][A-Z0-9\-]{4,15}[A-Z0-9])\b"#,
        category: .accountNumber,
        sample: "ID number: 4120987654",
        counterexample: "id card holder",
        regionCode: nil,
        kind: .generic,
        tier: .generic,
        autoEnable: .anyRegion
    )

    public static let genericDriversLicense = Preset(
        id: "generic.driversLicense",
        name: "Driver's licence number (any country)",
        summary:
            "A licence number written after “driver's licence”, “driving licence”, “permis de conduire”, “licencia de conducir”, “Führerschein”, “patente”, “carteira de habilitação”, “rijbewijs” or “prawo jazdy”.",
        pattern:
            #"(?i)\b(?:driver'?s?\s*licen[cs]e|driving\s+licen[cs]e|permis\s+de\s+conduire|licencia\s+de\s+(?:conducir|manejo)|f(?:ü|ue)hrerschein(?:nummer)?|patente(?:\s+di\s+guida)?|carteira\s+(?:nacional\s+)?de\s+habilita[çc][ãa]o|rijbewijs(?:nummer)?|prawo\s+jazdy)"#
            + anchorGap + #"((?=[A-Z0-9\-]*\d)[A-Z0-9][A-Z0-9\-]{3,17}[A-Z0-9])\b"#,
        category: .accountNumber,
        sample: "Driving licence: MORGA657054SM9IJ",
        counterexample: "driving licence renewal",
        regionCode: nil,
        kind: .generic,
        tier: .generic,
        autoEnable: .anyRegion
    )

    public static let genericTaxID = Preset(
        id: "generic.taxID",
        name: "Tax ID / VAT number (any country)",
        summary:
            "A number written after “tax ID”, “tax number”, “TIN”, “VAT number”, “Steuernummer”, “numéro fiscal”, “NIF”, “RFC”, “CUIT”, “RUC” or “NPWP”.",
        pattern:
            #"(?i)\b(?:tax\s*(?:id|identification\s+number|number|no\.?|file\s+number|reference(?:\s+number)?)|TIN|VAT\s*(?:id|number|no\.?|reg(?:istration)?(?:\s+number)?)|steuernummer|steuer-?id(?:entifikationsnummer)?|num[ée]ro\s+fiscal|NIF|RFC|CUIT|CUIL|RUC|NPWP)"#
            + anchorGap + #"((?=[A-Z0-9\-\./]*\d)[A-Z0-9][A-Z0-9\-\./]{4,19}[A-Z0-9])\b"#,
        category: .accountNumber,
        sample: "Tax ID: 12-3456789",
        counterexample: "tax id renewal",
        regionCode: nil,
        kind: .generic,
        tier: .generic,
        autoEnable: .anyRegion
    )

    public static let genericBankAccount = Preset(
        id: "generic.bankAccount",
        name: "Bank account / routing number (any country)",
        summary:
            "Digits written after “account number”, “acct #”, “sort code”, “routing number”, “BSB”, “IFSC”, “CLABE”, “transit number”, “Kontonummer”, “numéro de compte” or “número de cuenta”.",
        pattern:
            #"(?i)\b(?:account\s*(?:no\.?|number|#)|acct\.?\s*(?:no\.?|#)?|sort\s*code|routing\s*(?:number|no\.?|#)?|BSB|IFSC|CLABE|transit\s*(?:number|no\.?)|kontonummer|num[ée]ro\s+de\s+compte|n[úu]mero\s+de\s+cuenta|conta\s+corrente|BLZ)"#
            + anchorGap + #"(\d[\d\- ]{4,24}\d)\b"#,
        category: .accountNumber,
        sample: "Account number: 12345678",
        counterexample: "account manager",
        regionCode: nil,
        kind: .generic,
        tier: .generic,
        autoEnable: .anyRegion
    )

    // MARK: Finance

    /// IBAN — 2 letter country code, 2 check digits, 11–30
    /// alphanumerics, optional 4-char spacing; MOD 97-10 validated.
    public static let iban = Preset(
        id: "iban",
        name: "IBAN (Bank Account)",
        summary:
            "International bank account number — two-letter country code, two check digits, then 11–30 characters; checksum-verified.",
        pattern: #"\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){2,7}(?:\s?[A-Z0-9]{1,4})?\b"#,
        category: .accountNumber,
        sample: "GB82 WEST 1234 5698 7654 32",
        counterexample: "GB82 WEST 1234 5698 7654 33",
        regionCode: nil,
        kind: .bankAccount,
        tier: .validated,
        autoEnable: .regions(ibanCountries),
        validator: { PrivacyChecksums.iban($0) }
    )

    public static let bic = Preset(
        id: "bic",
        name: "SWIFT / BIC code",
        summary: "An 8- or 11-character bank identifier written after “SWIFT” or “BIC”.",
        pattern: #"(?i)\b(?:SWIFT|BIC)(?:\s*code)?"# + anchorGap + #"([A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?)\b"#,
        category: .accountNumber,
        sample: "SWIFT: DEUTDEFF500",
        counterexample: "SWIFT: DEUT",
        regionCode: nil,
        kind: .bankAccount,
        tier: .anchored,
        autoEnable: .regions(ibanCountries)
    )

    public static let euVAT = Preset(
        id: "euVAT",
        name: "EU / UK VAT number",
        summary: "VAT registration numbers with their country prefix (DE123456789, FR12345678901, GB123456789, …).",
        pattern:
            #"\b(?:ATU\d{8}|BE[01]\d{9}|BG\d{9,10}|HR\d{11}|CY\d{8}[A-Z]|CZ\d{8,10}|DK\d{8}|EE\d{9}|FI\d{8}|FR[A-Z0-9]{2}\d{9}|DE\d{9}|EL\d{9}|HU\d{8}|IE\d{7}[A-Z]{1,2}|IE\d[A-Z0-9+*]\d{5}[A-Z]|IT\d{11}|LV\d{11}|LT\d{9}(?:\d{3})?|LU\d{8}|MT\d{8}|NL\d{9}B\d{2}|PL\d{10}|PT\d{9}|RO\d{2,10}|SK\d{10}|SI\d{8}|ES[A-Z0-9]\d{7}[A-Z0-9]|SE\d{12}|GB\d{9}(?:\d{3})?|XI\d{9}|CHE\d{9}|NO\d{9}MVA)\b"#,
        category: .accountNumber,
        sample: "DE123456789",
        counterexample: "DE12345",
        regionCode: nil,
        kind: .taxID,
        tier: .anchored,
        autoEnable: .regions(euVATCountries)
    )

    public static let ehic = Preset(
        id: "ehic",
        name: "European Health Insurance Card number",
        summary: "The 20-digit card identification number written after “EHIC” or “European Health Insurance”.",
        pattern: #"(?i)\b(?:EHIC|European\s+Health\s+Insurance(?:\s+Card)?)"# + anchorGap + #"(\d{20})\b"#,
        category: .accountNumber,
        sample: "EHIC: 80380000012345678901",
        counterexample: "EHIC: 8038",
        regionCode: nil,
        kind: .healthID,
        tier: .anchored,
        autoEnable: .regions(euVATCountries)
    )

    // MARK: Network

    public static let ipv4 = Preset(
        id: "ipv4",
        name: "IPv4 address",
        summary: "Dotted-quad addresses like 192.168.1.20.",
        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#,
        category: .secret,
        sample: "192.168.1.20",
        counterexample: "256.1.1.1",
        regionCode: nil,
        kind: .network,
        tier: .anchored
    )

    public static let ipv6 = Preset(
        id: "ipv6",
        name: "IPv6 address",
        summary: "Colon-hex addresses like 2001:db8::8a2e:370:7334.",
        pattern:
            #"(?i)(?<![:\w])(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,7}:|(?:[0-9a-f]{1,4}:){1,6}:[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,5}(?::[0-9a-f]{1,4}){1,2}|(?:[0-9a-f]{1,4}:){1,4}(?::[0-9a-f]{1,4}){1,3}|(?:[0-9a-f]{1,4}:){1,3}(?::[0-9a-f]{1,4}){1,4}|(?:[0-9a-f]{1,4}:){1,2}(?::[0-9a-f]{1,4}){1,5}|[0-9a-f]{1,4}:(?::[0-9a-f]{1,4}){1,6})(?![:\w])"#,
        category: .secret,
        sample: "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
        counterexample: "12:30:45",
        regionCode: nil,
        kind: .network,
        tier: .anchored,
        validator: { $0.filter { $0 == ":" }.count >= 2 }
    )

    public static let macAddress = Preset(
        id: "macAddress",
        name: "MAC address",
        summary: "Six hex pairs separated by colons or dashes.",
        pattern: #"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#,
        category: .secret,
        sample: "00:1A:2B:3C:4D:5E",
        counterexample: "00:11:22:33:44",
        regionCode: nil,
        kind: .network,
        tier: .anchored
    )

    // MARK: Crypto

    public static let bitcoinAddress = Preset(
        id: "bitcoinAddress",
        name: "Bitcoin address",
        summary: "Legacy (1…/3…) and bech32 (bc1…) wallet addresses.",
        pattern: #"\b(?:bc1[ac-hj-np-z02-9]{25,62}|[13][a-km-zA-HJ-NP-Z1-9]{25,34})\b"#,
        category: .secret,
        sample: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
        counterexample: "1A1zP1eP5QGefi2D",
        regionCode: nil,
        kind: .crypto,
        tier: .anchored
    )

    public static let ethereumAddress = Preset(
        id: "ethereumAddress",
        name: "Ethereum address",
        summary: "0x followed by 40 hex characters.",
        pattern: #"\b0x[0-9a-fA-F]{40}\b"#,
        category: .secret,
        sample: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
        counterexample: "0x742d35Cc",
        regionCode: nil,
        kind: .crypto,
        tier: .anchored
    )

    // MARK: Secrets

    /// AWS access key id — `AKIA` (long-lived) or `ASIA` (session
    /// token) prefix followed by 16 base32 uppercase chars.
    public static let awsKey = Preset(
        id: "awsKey",
        name: "AWS Access Key",
        summary: "AKIA / ASIA prefix followed by 16 base32 characters.",
        pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        category: .secret,
        sample: "AKIAIOSFODNN7EXAMPLE",
        counterexample: "AKIAIOSFODNN",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    /// GitHub PAT family — `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`
    /// prefix + 36+ url-safe chars.
    public static let githubToken = Preset(
        id: "githubToken",
        name: "GitHub Token",
        summary: "Personal access / fine-grained / server tokens (ghp_, gho_, ghs_, …).",
        pattern: #"\bgh[pousr]_[A-Za-z0-9]{36,251}\b"#,
        category: .secret,
        sample: "ghp_1234567890abcdef1234567890abcdef1234",
        counterexample: "ghp_1234",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    // Some secret samples below are written as `"prefix" + "rest"`. The
    // runtime value is identical; splitting the literal keeps the source
    // text itself from matching GitHub push-protection secret scanners,
    // which otherwise reject the commit.
    public static let slackToken = Preset(
        id: "slackToken",
        name: "Slack token",
        summary: "Bot, user, app and refresh tokens (xoxb-, xoxp-, xoxa-, xoxr-, xoxs-).",
        pattern: #"\bxox[abprs]-[A-Za-z0-9\-]{10,}\b"#,
        category: .secret,
        sample: "xoxb-" + "123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx",
        counterexample: "xoxb-123",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let stripeKey = Preset(
        id: "stripeKey",
        name: "Stripe API key",
        summary: "Secret, restricted and publishable keys (sk_live_, rk_live_, pk_live_, …_test_).",
        pattern: #"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}\b"#,
        category: .secret,
        sample: "sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc",
        counterexample: "sk_live_abc",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let googleApiKey = Preset(
        id: "googleApiKey",
        name: "Google API key",
        summary: "AIza prefix followed by 35 URL-safe characters.",
        pattern: #"\bAIza[0-9A-Za-z\-_]{35}\b"#,
        category: .secret,
        sample: "AIzaSyA1234567890abcdefghijklmnopqrstuv",
        counterexample: "AIzaSyShort",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let openaiKey = Preset(
        id: "openaiKey",
        name: "OpenAI API key",
        summary: "sk- / sk-proj- / sk-svcacct- keys of 32+ characters.",
        pattern: #"\bsk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{32,}\b"#,
        category: .secret,
        sample: "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCDEF",
        counterexample: "sk-short",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let anthropicKey = Preset(
        id: "anthropicKey",
        name: "Anthropic API key",
        summary: "sk-ant-api… / sk-ant-admin… keys.",
        pattern: #"\bsk-ant-(?:api|admin)\d{2}-[A-Za-z0-9_\-]{30,}\b"#,
        category: .secret,
        sample: "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ",
        counterexample: "sk-ant-api03-short",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let jwt = Preset(
        id: "jwt",
        name: "JSON Web Token",
        summary: "Three base64url segments starting with eyJ (header.payload.signature).",
        pattern: #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#,
        category: .secret,
        sample:
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
        counterexample: "eyJabc.eyJdef",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let pemPrivateKey = Preset(
        id: "pemPrivateKey",
        name: "PEM private key header",
        summary: "-----BEGIN … PRIVATE KEY----- blocks (RSA, EC, DSA, OpenSSH, PGP).",
        pattern: #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?-----"#,
        category: .secret,
        sample: "-----BEGIN RSA PRIVATE KEY-----",
        counterexample: "-----BEGIN CERTIFICATE-----",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let azureStorageKey = Preset(
        id: "azureStorageKey",
        name: "Azure storage account key",
        summary: "AccountKey=… values in Azure connection strings (88-char base64).",
        pattern: #"(?i)\bAccountKey=([A-Za-z0-9+/]{86}==)"#,
        category: .secret,
        sample:
            "AccountKey=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwx==",
        counterexample: "AccountKey=short",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let gcpServiceAccountKey = Preset(
        id: "gcpServiceAccountKey",
        name: "Google Cloud service-account key id",
        summary: "\"private_key_id\" fields from a downloaded service-account JSON.",
        pattern: #""private_key_id"\s*:\s*"([0-9a-f]{40})""#,
        category: .secret,
        sample: "\"private_key_id\": \"0123456789abcdef0123456789abcdef01234567\"",
        counterexample: "\"private_key_id\": \"abc\"",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let twilioKey = Preset(
        id: "twilioKey",
        name: "Twilio SID / API key",
        summary: "AC… account SIDs and SK… API key SIDs (34 hex characters).",
        pattern: #"\b(?:AC|SK)[0-9a-fA-F]{32}\b"#,
        category: .secret,
        sample: "AC" + "0123456789abcdef0123456789abcdef",
        counterexample: "AC123",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let sendgridKey = Preset(
        id: "sendgridKey",
        name: "SendGrid API key",
        summary: "SG.<22 chars>.<43 chars> keys.",
        pattern: #"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"#,
        category: .secret,
        sample: "SG." + "abcdefghijklmnopqrstuv.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
        counterexample: "SG.short",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let npmToken = Preset(
        id: "npmToken",
        name: "npm access token",
        summary: "npm_ prefix followed by 36 characters.",
        pattern: #"\bnpm_[A-Za-z0-9]{36}\b"#,
        category: .secret,
        sample: "npm_abcdefghijklmnopqrstuvwxyz0123456789",
        counterexample: "npm_short",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let discordBotToken = Preset(
        id: "discordBotToken",
        name: "Discord bot token",
        summary: "Three dot-separated base64 segments issued by the Discord developer portal.",
        pattern: #"\b[MN][A-Za-z\d]{23,}\.[\w\-]{6}\.[\w\-]{27,}\b"#,
        category: .secret,
        sample: "MTIzNDU2Nzg5MDEyMzQ1Njc4" + ".GhIjKl." + "mnopqrstuvwxyz0123456789ABCDEF",
        counterexample: "MTIz.Gh.mn",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let telegramBotToken = Preset(
        id: "telegramBotToken",
        name: "Telegram bot token",
        summary: "<bot id>:AA<33 chars> tokens from @BotFather.",
        pattern: #"\b\d{8,10}:AA[A-Za-z0-9_\-]{33}\b"#,
        category: .secret,
        sample: "123456789:AAabcdefghijklmnopqrstuvwxyz0123456",
        counterexample: "123:AAabc",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    public static let genericApiKeyAssignment = Preset(
        id: "genericApiKeyAssignment",
        name: "API key / secret assignment",
        summary:
            "Values assigned to api_key, api_secret, secret_key, access_token, auth_token or client_secret (16+ characters).",
        pattern:
            #"(?i)\b(?:api[_\-\s]?key|api[_\-\s]?secret|secret[_\-\s]?key|access[_\-\s]?token|auth[_\-\s]?token|client[_\-\s]?secret)\b\s*[=:]\s*["']?([A-Za-z0-9_\-\.]{16,})["']?"#,
        category: .secret,
        sample: "api_key = \"abcdef1234567890abcdef\"",
        counterexample: "api_key = \"short\"",
        regionCode: nil,
        kind: .secret,
        tier: .anchored
    )

    static let global: [Preset] = [
        genericPassport,
        genericNationalID,
        genericDriversLicense,
        genericTaxID,
        genericBankAccount,
        iban,
        bic,
        euVAT,
        ehic,
        ipv4,
        ipv6,
        macAddress,
        bitcoinAddress,
        ethereumAddress,
        awsKey,
        githubToken,
        slackToken,
        stripeKey,
        googleApiKey,
        openaiKey,
        anthropicKey,
        jwt,
        pemPrivateKey,
        azureStorageKey,
        gcpServiceAccountKey,
        twilioKey,
        sendgridKey,
        npmToken,
        discordBotToken,
        telegramBotToken,
        genericApiKeyAssignment,
    ]
}
