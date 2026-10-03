//
//  PrivacyChecksums.swift
//  osaurus / PrivacyFilter
//
//  Check-digit algorithms behind the Tier-1 ("validated") preset
//  rules. A regex alone can only describe the *shape* of a national
//  ID; the public checksum is what lets the detector flag a bare
//  11-digit run as, say, a Polish PESEL without also flagging every
//  phone number and order id of the same length. Every function here
//  is pure, `Sendable`, and operates on the captured token only — the
//  keyword anchor (when a preset has one) is already stripped by the
//  capture group before the validator runs.
//
//  Reference vectors for each algorithm live in
//  `Tests/PrivacyFilter/PrivacyChecksumsTests.swift`; the sample on
//  every preset is also run through its validator by
//  `PrivacyPresetCatalogTests`, so a wrong weight table fails CI
//  rather than silently turning a preset into a never-matches rule.
//

import Foundation

public enum PrivacyChecksums {
    // MARK: - Token helpers

    /// ASCII digits of `s` in order, everything else dropped.
    public static func digits(_ s: String) -> [Int] {
        s.unicodeScalars.compactMap { scalar in
            guard scalar.value >= 48, scalar.value <= 57 else { return nil }
            return Int(scalar.value - 48)
        }
    }

    /// Uppercased ASCII letters + digits of `s`, separators dropped.
    public static func alphanumerics(_ s: String) -> String {
        String(
            s.uppercased().unicodeScalars.filter {
                ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
            }
        )
    }

    /// Dot product of two equal-length integer sequences (shorter wins).
    @inlinable
    public static func weightedSum(_ values: [Int], _ weights: [Int]) -> Int {
        var total = 0
        for (v, w) in zip(values, weights) { total += v * w }
        return total
    }

    /// `A` → 10 … `Z` → 35, digits map to themselves. `nil` for
    /// anything else. The ICAO 9303 / ISO 7064 letter convention.
    public static func base36Value(_ ch: Character) -> Int? {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return nil }
        switch scalar.value {
        case 48 ... 57: return Int(scalar.value - 48)
        case 65 ... 90: return Int(scalar.value - 55)
        case 97 ... 122: return Int(scalar.value - 87)
        default: return nil
        }
    }

    /// `A` → 1 … `Z` → 26. `nil` for non-letters.
    public static func alphabetIndex(_ ch: Character) -> Int? {
        guard let scalar = ch.uppercased().unicodeScalars.first,
            scalar.value >= 65, scalar.value <= 90
        else { return nil }
        return Int(scalar.value - 64)
    }

    // MARK: - Generic algorithms

    /// Luhn (ISO/IEC 7812-1). Payment cards, Canadian SIN, Swedish
    /// personnummer, Israeli ID, South African ID, Emirates ID, …
    public static func luhn(_ s: String) -> Bool {
        let d = digits(s)
        guard !d.isEmpty else { return false }
        var sum = 0
        var alternate = false
        for x in d.reversed() {
            var v = x
            if alternate {
                v *= 2
                if v > 9 { v -= 9 }
            }
            sum += v
            alternate.toggle()
        }
        return sum % 10 == 0
    }

    /// Verhoeff (Dihedral group D5). Indian Aadhaar, Luxembourg ID.
    public static func verhoeff(_ s: String) -> Bool {
        let d = digits(s)
        guard !d.isEmpty else { return false }
        let dTable: [[Int]] = [
            [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5],
            [2, 3, 4, 0, 1, 7, 8, 9, 5, 6], [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
            [4, 0, 1, 2, 3, 9, 5, 6, 7, 8], [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
            [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
            [8, 7, 6, 5, 9, 3, 2, 1, 0, 4], [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
        ]
        let pTable: [[Int]] = [
            [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4],
            [5, 8, 0, 3, 7, 9, 6, 1, 4, 2], [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
            [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
            [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
        ]
        var c = 0
        for (i, x) in d.reversed().enumerated() {
            c = dTable[c][pTable[i % 8][x]]
        }
        return c == 0
    }

    /// ISO 7064 MOD 11,10 (hybrid). German Steuer-ID, Croatian OIB.
    public static func iso7064Mod11_10(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count >= 2 else { return false }
        var a = 10
        for x in d.dropLast() {
            a = (a + x) % 10
            if a == 0 { a = 10 }
            a = (a * 2) % 11
        }
        return (11 - a) % 10 == d[d.count - 1]
    }

    /// ISO 7064 MOD 11-2 as used by the Chinese resident identity
    /// card: 17 digits weighted by 2^(n-i) mod 11; check char from
    /// `10X98765432`.
    public static func chineseResidentId(_ s: String) -> Bool {
        let t = alphanumerics(s)
        guard t.count == 18 else { return false }
        let chars = Array(t)
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        var sum = 0
        for i in 0 ..< 17 {
            guard let v = chars[i].wholeNumberValue else { return false }
            sum += v * weights[i]
        }
        let table = Array("10X98765432")
        return table[sum % 11] == chars[17]
    }

    /// EAN-13 / GTIN check digit. Swiss AHV number.
    public static func ean13(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 13 else { return false }
        var sum = 0
        for i in 0 ..< 12 { sum += d[i] * (i % 2 == 0 ? 1 : 3) }
        return (10 - sum % 10) % 10 == d[12]
    }

    /// IBAN MOD 97-10 (ISO 13616). Spaces tolerated; letters map
    /// A=10…Z=35; rearranged number ≡ 1 (mod 97).
    public static func iban(_ s: String) -> Bool {
        let t = alphanumerics(s)
        guard t.count >= 15, t.count <= 34 else { return false }
        let rearranged = String(t.dropFirst(4)) + String(t.prefix(4))
        var remainder = 0
        for ch in rearranged {
            guard let v = base36Value(ch) else { return false }
            if v >= 10 {
                remainder = (remainder * 100 + v) % 97
            } else {
                remainder = (remainder * 10 + v) % 97
            }
        }
        return remainder == 1
    }

    /// ICAO 9303 document check digit: weights 7,3,1 cycling over the
    /// payload; letters A=10…; check = sum mod 10. German
    /// Personalausweis / passport MRZ fields.
    public static func icao9303(_ s: String) -> Bool {
        let t = alphanumerics(s)
        guard t.count >= 2 else { return false }
        let chars = Array(t)
        let weights = [7, 3, 1]
        var sum = 0
        for i in 0 ..< (chars.count - 1) {
            guard let v = base36Value(chars[i]) else { return false }
            sum += v * weights[i % 3]
        }
        return sum % 10 == chars[chars.count - 1].wholeNumberValue
    }

    /// Modulo-36 character checksum (Indian GSTIN).
    public static func mod36(_ s: String) -> Bool {
        let t = alphanumerics(s)
        guard t.count >= 2 else { return false }
        let chars = Array(t)
        var sum = 0
        for i in 0 ..< (chars.count - 1) {
            guard let v = base36Value(chars[i]) else { return false }
            let p = v * (i % 2 == 0 ? 1 : 2)
            sum += p / 36 + p % 36
        }
        let table = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return table[(36 - sum % 36) % 36] == chars[chars.count - 1]
    }

    // MARK: - Americas

    public static func usABARouting(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 9 else { return false }
        let sum = 3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])
        return sum % 10 == 0
    }

    public static func canadianSIN(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 9, d[0] != 0, d[0] != 8 else { return false }
        return luhn(s)
    }

    public static func mexicanCURP(_ s: String) -> Bool {
        let t = Array(s.uppercased())
        guard t.count == 18 else { return false }
        let alphabet = Array("0123456789ABCDEFGHIJKLMNÑOPQRSTUVWXYZ")
        var sum = 0
        for i in 0 ..< 17 {
            guard let idx = alphabet.firstIndex(of: t[i]) else { return false }
            sum += idx * (18 - i)
        }
        return (10 - sum % 10) % 10 == t[17].wholeNumberValue
    }

    public static func mexicanCLABE(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 18 else { return false }
        let weights = [3, 7, 1]
        var sum = 0
        for i in 0 ..< 17 { sum += (d[i] * weights[i % 3]) % 10 }
        return (10 - sum % 10) % 10 == d[17]
    }

    public static func brazilianCPF(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11, Set(d).count > 1 else { return false }
        for n in [9, 10] {
            var sum = 0
            for i in 0 ..< n { sum += d[i] * (n + 1 - i) }
            var check = (sum * 10) % 11
            if check == 10 { check = 0 }
            if check != d[n] { return false }
        }
        return true
    }

    public static func brazilianCNPJ(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 14, Set(d).count > 1 else { return false }
        let w1 = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
        let w2 = [6] + w1
        for (n, w) in [(12, w1), (13, w2)] {
            var check = 11 - weightedSum(Array(d[0 ..< n]), w) % 11
            if check >= 10 { check = 0 }
            if check != d[n] { return false }
        }
        return true
    }

    public static func brazilianPIS(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        var check = 11 - weightedSum(Array(d[0 ..< 10]), [3, 2, 9, 8, 7, 6, 5, 4, 3, 2]) % 11
        if check >= 10 { check = 0 }
        return check == d[10]
    }

    public static func argentineCUIT(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        var check = 11 - weightedSum(Array(d[0 ..< 10]), [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) % 11
        if check == 11 { check = 0 }
        if check == 10 { check = 9 }
        return check == d[10]
    }

    public static func chileanRUT(_ s: String) -> Bool {
        let t = alphanumerics(s)
        guard t.count >= 2 else { return false }
        let body = t.dropLast()
        let dv = t.last!
        var sum = 0
        var m = 2
        for ch in body.reversed() {
            guard let v = ch.wholeNumberValue else { return false }
            sum += v * m
            m = m == 7 ? 2 : m + 1
        }
        let r = 11 - sum % 11
        let expected: Character = r == 11 ? "0" : (r == 10 ? "K" : Character(String(r)))
        return expected == dv
    }

    public static func colombianNIT(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count >= 2 else { return false }
        let weights = [3, 7, 13, 17, 19, 23, 29, 37, 41, 43, 47, 53, 59, 67, 71]
        let body = Array(d.dropLast().reversed())
        let sum = weightedSum(body, weights)
        let r = sum % 11
        let expected = r <= 1 ? r : 11 - r
        return expected == d[d.count - 1]
    }

    public static func peruvianRUC(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        var check = 11 - weightedSum(Array(d[0 ..< 10]), [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) % 11
        if check == 10 { check = 0 }
        if check == 11 { check = 1 }
        return check == d[10]
    }

    public static func ecuadorianCedula(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10 else { return false }
        var sum = 0
        for i in 0 ..< 9 {
            var x = d[i] * (i % 2 == 0 ? 2 : 1)
            if x > 9 { x -= 9 }
            sum += x
        }
        return (10 - sum % 10) % 10 == d[9]
    }

    public static func uruguayanCI(_ s: String) -> Bool {
        var d = digits(s)
        guard d.count >= 7, d.count <= 8 else { return false }
        while d.count < 8 { d.insert(0, at: 0) }
        let sum = weightedSum(Array(d[0 ..< 7]), [2, 9, 8, 7, 6, 3, 4])
        return (10 - sum % 10) % 10 == d[7]
    }

    public static func guatemalanCUI(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 13 else { return false }
        var sum = 0
        for i in 0 ..< 8 { sum += d[i] * (i + 2) }
        return sum % 11 == d[8]
    }

    // MARK: - Europe

    public static func ukNHS(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10 else { return false }
        var check = 11 - weightedSum(Array(d[0 ..< 9]), [10, 9, 8, 7, 6, 5, 4, 3, 2]) % 11
        if check == 11 { check = 0 }
        if check == 10 { return false }
        return check == d[9]
    }

    public static func ukUTR(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10 else { return false }
        let sum = weightedSum(Array(d[1 ..< 10]), [6, 7, 8, 9, 10, 5, 4, 3, 2])
        let table = Array("21987654321")
        return table[sum % 11].wholeNumberValue == d[0]
    }

    public static func irishPPS(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 8 || t.count == 9 else { return false }
        var sum = 0
        let weights = [8, 7, 6, 5, 4, 3, 2]
        for i in 0 ..< 7 {
            guard let v = t[i].wholeNumberValue else { return false }
            sum += v * weights[i]
        }
        if t.count == 9, t[8] != "W" {
            guard let v = alphabetIndex(t[8]) else { return false }
            sum += 9 * v
        }
        let table = Array("WABCDEFGHIJKLMNOPQRSTUV")
        return table[sum % 23] == t[7]
    }

    public static func frenchNIR(_ s: String) -> Bool {
        var t = alphanumerics(s)
        guard t.count == 15 else { return false }
        let key = Int(t.suffix(2))
        t = String(t.prefix(13))
        // Corsica: 2A → 19, 2B → 18 before the mod-97.
        t = t.replacingOccurrences(of: "2A", with: "19").replacingOccurrences(of: "2B", with: "18")
        guard let key, let body = Int(t) else { return false }
        return 97 - body % 97 == key
    }

    public static func germanSteuerId(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11, d[0] != 0 else { return false }
        var counts: [Int: Int] = [:]
        for x in d[0 ..< 10] { counts[x, default: 0] += 1 }
        let repeated = counts.filter { $0.value > 1 }
        guard repeated.count == 1, let c = repeated.first?.value, c == 2 || c == 3 else { return false }
        return iso7064Mod11_10(s)
    }

    public static func germanSozialversicherungsnummer(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 12, let letter = alphabetIndex(t[8]) else { return false }
        var d: [Int] = []
        for i in 0 ..< 8 { guard let v = t[i].wholeNumberValue else { return false }; d.append(v) }
        d.append(letter / 10)
        d.append(letter % 10)
        for i in 9 ..< 12 { guard let v = t[i].wholeNumberValue else { return false }; d.append(v) }
        let weights = [2, 1, 2, 5, 7, 1, 2, 1, 2, 1, 2, 1]
        var sum = 0
        for i in 0 ..< 12 {
            var p = d[i] * weights[i]
            while p > 0 { sum += p % 10; p /= 10 }
        }
        return sum % 10 == d[12]
    }

    public static func germanKrankenversichertennummer(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 10, let letter = alphabetIndex(t[0]) else { return false }
        var d: [Int] = [letter / 10, letter % 10]
        for i in 1 ..< 10 { guard let v = t[i].wholeNumberValue else { return false }; d.append(v) }
        var sum = 0
        for i in 0 ..< 10 {
            var p = d[i] * (i % 2 == 0 ? 1 : 2)
            while p > 0 { sum += p % 10; p /= 10 }
        }
        return sum % 10 == d[10]
    }

    public static func dutchBSN(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 9 else { return false }
        var sum = 0
        for i in 0 ..< 8 { sum += d[i] * (9 - i) }
        sum -= d[8]
        return sum % 11 == 0
    }

    public static func belgianNationalRegister(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        let bodyStr = d[0 ..< 9].map(String.init).joined()
        let check = d[9] * 10 + d[10]
        guard let body = Int(bodyStr), let body2000 = Int("2" + bodyStr) else { return false }
        return 97 - body % 97 == check || 97 - body2000 % 97 == check
    }

    public static func luxembourgNationalId(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 13 else { return false }
        let str = d.map(String.init).joined()
        return luhn(String(str.prefix(12))) && verhoeff(str)
    }

    public static func austrianSVNR(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10 else { return false }
        let sum = weightedSum(d, [3, 7, 9, 0, 5, 8, 4, 2, 1, 6])
        return sum % 11 == d[3]
    }

    private static let spanishDNILetters = Array("TRWAGMYFPDXBNJZSQVHLCKE")

    public static func spanishDNI(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 9, let letter = t.last else { return false }
        guard let n = Int(String(t[0 ..< 8])) else { return false }
        return spanishDNILetters[n % 23] == letter
    }

    public static func spanishNIE(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 9, let letter = t.last else { return false }
        let prefix: String
        switch t[0] {
        case "X": prefix = "0"
        case "Y": prefix = "1"
        case "Z": prefix = "2"
        default: return false
        }
        guard let n = Int(prefix + String(t[1 ..< 8])) else { return false }
        return spanishDNILetters[n % 23] == letter
    }

    public static func spanishNSS(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 12 else { return false }
        guard let body = Int(d[0 ..< 10].map(String.init).joined()) else { return false }
        return body % 97 == d[10] * 10 + d[11]
    }

    public static func portugueseNIF(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 9 else { return false }
        var check = 11 - weightedSum(Array(d[0 ..< 8]), [9, 8, 7, 6, 5, 4, 3, 2]) % 11
        if check >= 10 { check = 0 }
        return check == d[8]
    }

    public static func portugueseNISS(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        let sum = weightedSum(Array(d[0 ..< 10]), [29, 23, 19, 17, 13, 11, 7, 5, 3, 2])
        return 9 - sum % 10 == d[10]
    }

    private static let codiceFiscaleOdd: [Character: Int] = [
        "0": 1, "1": 0, "2": 5, "3": 7, "4": 9, "5": 13, "6": 15, "7": 17, "8": 19, "9": 21,
        "A": 1, "B": 0, "C": 5, "D": 7, "E": 9, "F": 13, "G": 15, "H": 17, "I": 19, "J": 21,
        "K": 2, "L": 4, "M": 18, "N": 20, "O": 11, "P": 3, "Q": 6, "R": 8, "S": 12, "T": 14,
        "U": 16, "V": 10, "W": 22, "X": 25, "Y": 24, "Z": 23,
    ]

    public static func italianCodiceFiscale(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 16 else { return false }
        var sum = 0
        for i in 0 ..< 15 {
            let ch = t[i]
            if i % 2 == 0 {
                guard let v = codiceFiscaleOdd[ch] else { return false }
                sum += v
            } else if let v = ch.wholeNumberValue {
                sum += v
            } else if let v = alphabetIndex(ch) {
                sum += v - 1
            } else {
                return false
            }
        }
        guard let scalar = UnicodeScalar(65 + sum % 26) else { return false }
        return Character(scalar) == t[15]
    }

    public static func greekAFM(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 9 else { return false }
        var sum = 0
        for i in 0 ..< 8 { sum += d[i] << (8 - i) }
        return (sum % 11) % 10 == d[8]
    }

    /// Swedish personnummer / samordningsnummer: Luhn over the
    /// 10-digit YYMMDDXXXX form (a 12-digit century-prefixed input
    /// drops its first two digits first).
    public static func swedishPersonnummer(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10 || d.count == 12 else { return false }
        let ten = d.suffix(10).map(String.init).joined()
        return luhn(ten)
    }

    public static func norwegianFodselsnummer(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        var k1 = 11 - weightedSum(Array(d[0 ..< 9]), [3, 7, 6, 1, 8, 9, 4, 5, 2]) % 11
        if k1 == 11 { k1 = 0 }
        if k1 == 10 { return false }
        var k2 = 11 - weightedSum(Array(d[0 ..< 10]), [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) % 11
        if k2 == 11 { k2 = 0 }
        if k2 == 10 { return false }
        return k1 == d[9] && k2 == d[10]
    }

    public static func finnishHETU(_ s: String) -> Bool {
        let t = Array(s.uppercased())
        guard t.count == 11 else { return false }
        let numeric = String(t[0 ..< 6]) + String(t[7 ..< 10])
        guard let n = Int(numeric) else { return false }
        let table = Array("0123456789ABCDEFHJKLMNPRSTUVWXY")
        return table[n % 31] == t[10]
    }

    public static func icelandicKennitala(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10 else { return false }
        var check = 11 - weightedSum(Array(d[0 ..< 8]), [3, 2, 7, 6, 5, 4, 3, 2]) % 11
        if check == 11 { check = 0 }
        if check == 10 { return false }
        return check == d[8]
    }

    /// Estonian isikukood and Lithuanian asmens kodas share this
    /// two-stage weighted check.
    public static func balticPersonalCode(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        var r = weightedSum(Array(d[0 ..< 10]), [1, 2, 3, 4, 5, 6, 7, 8, 9, 1]) % 11
        if r == 10 {
            r = weightedSum(Array(d[0 ..< 10]), [3, 4, 5, 6, 7, 8, 9, 1, 2, 3]) % 11
            if r == 10 { r = 0 }
        }
        return r == d[10]
    }

    /// Latvian personas kods (legacy DDMMYY-XNNNC format). New-format
    /// codes starting `32` carry no check digit and pass through.
    public static func latvianPersonasKods(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        if d[0] == 3, d[1] == 2 { return true }
        let sum = weightedSum(Array(d[0 ..< 10]), [1, 6, 3, 7, 9, 10, 5, 8, 4, 2])
        return ((1101 - sum) % 11 + 11) % 11 % 10 == d[10]
    }

    public static func polishPESEL(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        let sum = weightedSum(Array(d[0 ..< 10]), [1, 3, 7, 9, 1, 3, 7, 9, 1, 3])
        return (10 - sum % 10) % 10 == d[10]
    }

    public static func polishNIP(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10 else { return false }
        let r = weightedSum(Array(d[0 ..< 9]), [6, 5, 7, 2, 3, 4, 5, 6, 7]) % 11
        return r != 10 && r == d[9]
    }

    public static func polishDowodOsobisty(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 9 else { return false }
        let weights = [7, 3, 1, 0, 7, 3, 1, 7, 3]
        var sum = 0
        for i in 0 ..< 9 {
            guard let v = base36Value(t[i]) else { return false }
            sum += v * weights[i]
        }
        return sum % 10 == t[3].wholeNumberValue
    }

    /// Czech and Slovak rodné číslo: the 10-digit form is divisible by 11.
    public static func czechSlovakRodneCislo(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10, let n = Int(d.map(String.init).joined()) else { return false }
        return n % 11 == 0
    }

    public static func hungarianTAJ(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 9 else { return false }
        var sum = 0
        for i in 0 ..< 8 { sum += d[i] * (i % 2 == 0 ? 3 : 7) }
        return sum % 10 == d[8]
    }

    public static func hungarianSzemelyiSzam(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        var sum = 0
        for i in 0 ..< 10 { sum += d[i] * (i + 1) }
        let r = sum % 11
        return r != 10 && r == d[10]
    }

    public static func hungarianAdoazonosito(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10, d[0] == 8 else { return false }
        var sum = 0
        for i in 0 ..< 9 { sum += d[i] * (i + 1) }
        let r = sum % 11
        return r != 10 && r == d[9]
    }

    /// Yugoslav-derived JMBG / EMŠO (SI, HR legacy, RS, BA, ME, MK).
    public static func jmbg(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 13 else { return false }
        var check = 11 - weightedSum(Array(d[0 ..< 12]), [7, 6, 5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) % 11
        if check == 11 { check = 0 }
        if check == 10 { return false }
        return check == d[12]
    }

    public static func bulgarianEGN(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10 else { return false }
        let sum = weightedSum(Array(d[0 ..< 9]), [2, 4, 8, 5, 10, 9, 7, 3, 6])
        return (sum % 11) % 10 == d[9]
    }

    public static func romanianCNP(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 13 else { return false }
        var r = weightedSum(Array(d[0 ..< 12]), [2, 7, 9, 1, 4, 6, 3, 5, 8, 2, 7, 9]) % 11
        if r == 10 { r = 1 }
        return r == d[12]
    }

    public static func moldovanIDNP(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 13 else { return false }
        let weights = [7, 3, 1]
        var sum = 0
        for i in 0 ..< 12 { sum += d[i] * weights[i % 3] }
        return sum % 10 == d[12]
    }

    public static func ukrainianRNTRC(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10 else { return false }
        let sum = weightedSum(Array(d[0 ..< 9]), [-1, 5, 7, 9, 4, 6, 10, 5, 7])
        return ((sum % 11) + 11) % 11 % 10 == d[9]
    }

    public static func russianSNILS(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        let sum = weightedSum(Array(d[0 ..< 9]), [9, 8, 7, 6, 5, 4, 3, 2, 1])
        let check = d[9] * 10 + d[10]
        let expected: Int
        if sum < 100 {
            expected = sum
        } else if sum == 100 || sum == 101 {
            expected = 0
        } else {
            let r = sum % 101
            expected = r == 100 ? 0 : r
        }
        return expected == check
    }

    public static func russianINN(_ s: String) -> Bool {
        let d = digits(s)
        switch d.count {
        case 10:
            return (weightedSum(Array(d[0 ..< 9]), [2, 4, 10, 3, 5, 9, 4, 6, 8]) % 11) % 10 == d[9]
        case 12:
            let c1 = (weightedSum(Array(d[0 ..< 10]), [7, 2, 4, 10, 3, 5, 9, 4, 6, 8]) % 11) % 10
            let c2 = (weightedSum(Array(d[0 ..< 11]), [3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8]) % 11) % 10
            return c1 == d[10] && c2 == d[11]
        default:
            return false
        }
    }

    public static func turkishTCKimlik(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 11, d[0] != 0 else { return false }
        let odd = d[0] + d[2] + d[4] + d[6] + d[8]
        let even = d[1] + d[3] + d[5] + d[7]
        guard ((odd * 7 - even) % 10 + 10) % 10 == d[9] else { return false }
        return d[0 ..< 10].reduce(0, +) % 10 == d[10]
    }

    // MARK: - Asia-Pacific

    public static func hongKongHKID(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 8 || t.count == 9 else { return false }
        let letterCount = t.count - 7
        var sum = 0
        if letterCount == 1 {
            guard let v = base36Value(t[0]) else { return false }
            sum += 36 * 9 + v * 8
        } else {
            guard let a = base36Value(t[0]), let b = base36Value(t[1]) else { return false }
            sum += a * 9 + b * 8
        }
        for i in 0 ..< 6 {
            guard let v = t[letterCount + i].wholeNumberValue else { return false }
            sum += v * (7 - i)
        }
        let r = 11 - sum % 11
        let expected: Character = r == 11 ? "0" : (r == 10 ? "A" : Character(String(r)))
        return expected == t[t.count - 1]
    }

    private static let taiwanLetterValues: [Character: Int] = [
        "A": 10, "B": 11, "C": 12, "D": 13, "E": 14, "F": 15, "G": 16, "H": 17, "I": 34, "J": 18,
        "K": 19, "L": 20, "M": 21, "N": 22, "O": 35, "P": 23, "Q": 24, "R": 25, "S": 26, "T": 27,
        "U": 28, "V": 29, "W": 32, "X": 30, "Y": 31, "Z": 33,
    ]

    public static func taiwanNationalId(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 10, let n = taiwanLetterValues[t[0]] else { return false }
        var sum = (n / 10) * 1 + (n % 10) * 9
        for i in 0 ..< 8 {
            guard let v = t[1 + i].wholeNumberValue else { return false }
            sum += v * (8 - i)
        }
        guard let last = t[9].wholeNumberValue else { return false }
        sum += last
        return sum % 10 == 0
    }

    public static func japaneseMyNumber(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 12 else { return false }
        var sum = 0
        for n in 1 ... 11 {
            let p = d[11 - n]
            let q = n <= 6 ? n + 1 : n - 5
            sum += p * q
        }
        let r = sum % 11
        let check = r <= 1 ? 0 : 11 - r
        return check == d[11]
    }

    public static func koreanRRN(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 13 else { return false }
        let sum = weightedSum(Array(d[0 ..< 12]), [2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5])
        return (11 - sum % 11) % 10 == d[12]
    }

    public static func singaporeNRIC(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 9 else { return false }
        let weights = [2, 7, 6, 5, 4, 3, 2]
        var sum = 0
        for i in 0 ..< 7 {
            guard let v = t[1 + i].wholeNumberValue else { return false }
            sum += v * weights[i]
        }
        let table: [Character]
        switch t[0] {
        case "S": table = Array("JZIHGFEDCBA")
        case "T": sum += 4; table = Array("JZIHGFEDCBA")
        case "F": table = Array("XWUTRQPNMLK")
        case "G": sum += 4; table = Array("XWUTRQPNMLK")
        case "M": sum += 3; table = Array("KLJNPQRTUWX")
        default: return false
        }
        return table[sum % 11] == t[8]
    }

    public static func thaiNationalId(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 13 else { return false }
        var sum = 0
        for i in 0 ..< 12 { sum += d[i] * (13 - i) }
        return (11 - sum % 11) % 10 == d[12]
    }

    public static func australianTFN(_ s: String) -> Bool {
        let d = digits(s)
        switch d.count {
        case 9: return weightedSum(d, [1, 4, 3, 7, 5, 8, 6, 9, 10]) % 11 == 0
        case 8: return weightedSum(d, [10, 7, 8, 4, 6, 3, 5, 1]) % 11 == 0
        default: return false
        }
    }

    public static func australianMedicare(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count >= 9, d.count <= 11, (2 ... 6).contains(d[0]) else { return false }
        let sum = weightedSum(Array(d[0 ..< 8]), [1, 3, 7, 9, 1, 3, 7, 9])
        return sum % 10 == d[8]
    }

    public static func australianABN(_ s: String) -> Bool {
        var d = digits(s)
        guard d.count == 11 else { return false }
        d[0] -= 1
        return weightedSum(d, [10, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19]) % 89 == 0
    }

    public static func newZealandIRD(_ s: String) -> Bool {
        var d = digits(s)
        guard d.count == 8 || d.count == 9, let n = Int(d.map(String.init).joined()) else { return false }
        guard (10_000_000 ... 150_000_000).contains(n) else { return false }
        while d.count < 9 { d.insert(0, at: 0) }
        func check(_ weights: [Int]) -> Int {
            let r = weightedSum(Array(d[0 ..< 8]), weights) % 11
            return r == 0 ? 0 : 11 - r
        }
        var c = check([3, 2, 7, 6, 5, 4, 3, 2])
        if c == 10 {
            c = check([7, 4, 3, 2, 5, 2, 7, 6])
            if c == 10 { return false }
        }
        return c == d[8]
    }

    public static func newZealandNHI(_ s: String) -> Bool {
        let t = Array(alphanumerics(s))
        guard t.count == 7 else { return false }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        var sum = 0
        for i in 0 ..< 6 {
            let ch = t[i]
            let v: Int
            if let n = ch.wholeNumberValue {
                v = n
            } else if let idx = alphabet.firstIndex(of: ch) {
                v = idx + 1
            } else {
                return false
            }
            sum += v * (7 - i)
        }
        let r = sum % 11
        guard r != 0 else { return false }
        var check = 11 - r
        if check == 10 { check = 0 }
        return check == t[6].wholeNumberValue
    }

    public static func kazakhIIN(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 12 else { return false }
        var r = weightedSum(Array(d[0 ..< 11]), Array(1 ... 11)) % 11
        if r == 10 {
            r = weightedSum(Array(d[0 ..< 11]), [3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2]) % 11
            if r == 10 { return false }
        }
        return r == d[11]
    }

    /// Sri Lankan NIC: day-of-year field must be 1–366 (male) or
    /// 501–866 (female) in both the legacy 9+V/X and new 12-digit form.
    public static func sriLankanNIC(_ s: String) -> Bool {
        let t = alphanumerics(s)
        let dayField: Substring
        switch t.count {
        case 10: dayField = t.dropFirst(2).prefix(3)
        case 12: dayField = t.dropFirst(4).prefix(3)
        default: return false
        }
        guard let day = Int(dayField) else { return false }
        return (1 ... 366).contains(day) || (501 ... 866).contains(day)
    }

    // MARK: - Middle East / Africa

    public static func kuwaitiCivilId(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 12 else { return false }
        let check = 11 - weightedSum(Array(d[0 ..< 11]), [2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]) % 11
        return check == d[11]
    }

    public static func iranianMelliCode(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 10, Set(d).count > 1 else { return false }
        let sum = weightedSum(Array(d[0 ..< 9]), [10, 9, 8, 7, 6, 5, 4, 3, 2])
        let r = sum % 11
        let expected = r < 2 ? r : 11 - r
        return expected == d[9]
    }
}
