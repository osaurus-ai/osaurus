import Foundation

struct BrowserFormField: Sendable {
    let element: CUElement
    let signature: String
    let generation: Int
}

extension BrowserSession {
    /// Only real, visible, editable text fields. S1 does not get authority to
    /// activate buttons, agree to terms, type credentials or pick arbitrary JS.
    private static let describeFormField = #"""
        function describeFormField(el) {
            if (!el || !el.isConnected || el.disabled || el.readOnly || el.matches(':disabled')) return null;
            const doc = el.ownerDocument, win = doc.defaultView;
            const tag = el.tagName.toLowerCase(), type = String(el.type || '').toLowerCase();
            if (tag !== 'textarea' && !(tag === 'input' && ['text','email','tel','url','search'].includes(type))) return null;
            if (el.getAttribute('aria-disabled') === 'true' || el.getAttribute('aria-readonly') === 'true') return null;
            const autocomplete = (el.autocomplete || '').toLowerCase();
            if (/(?:password|one-time-code|cc-)/.test(autocomplete)) return null;
            const rect = el.getBoundingClientRect(), style = win.getComputedStyle(el);
            if (!rect.width || !rect.height || style.visibility === 'hidden' || style.display === 'none' || style.opacity === '0') return null;
            const labelledBy = (el.getAttribute('aria-labelledby') || '').split(/\s+/)
                .map(id => doc.getElementById(id)?.innerText || '').join(' ').trim();
            const labels = Array.from(el.labels || []).map(label => label.innerText).join(' ').trim();
            const label = String(el.getAttribute('aria-label') || labelledBy || labels || el.placeholder || el.name || '').trim();
            if (!label) return null;
            const store = window.__osaurus_form_nodes || (window.__osaurus_form_nodes = {
                document: Array.from(crypto.getRandomValues(new Uint32Array(4))).join('-'), nodes: new WeakMap(), next: 0
            });
            const identity = node => {
                if (!store.nodes.has(node)) store.nodes.set(node, ++store.next);
                return store.nodes.get(node);
            };
            return {label, value: el.value, placeholder: el.placeholder || '',
                signature: JSON.stringify([store.document, identity(el), identity(doc), doc.URL, tag, type,
                    label, el.name, el.id, autocomplete, el.form ? identity(el.form) : null,
                    el.form?.action || '', el.form?.method || '', rect.x, rect.y, rect.width, rect.height])};
        }
        """#

    func captureFormFields() async throws -> (title: String, fields: [BrowserFormField]) {
        let snapshot = await takeSnapshot(options: SnapshotOptions(filter: "inputs", maxElements: 65), detail: .none)
        guard !snapshot.hasPrefix("Error:") else { throw CUAFormsError.invalid(snapshot) }
        let result = await evaluateJavaScript(
            """
            (() => { try {
                \(Self.describeFormField)
                if (!window.__osaurus_refs) throw new Error('No form snapshot.');
                const fields = [];
                for (const [ref, el] of window.__osaurus_refs) {
                    const field = describeFormField(el);
                    if (field) fields.push({ref, ...field});
                }
                if (window.__osaurus_refs.size >= 65) throw new Error('Form exceeds the 64-element limit.');
                return {title: document.title, generation: window.__osaurus_snapshot_gen, fields};
            } catch(e) { return {error: e.message || String(e)}; } })()
            """
        )
        if let error = result.error { throw CUAFormsError.invalid(error) }
        guard let row = result.result as? [String: Any], let generation = row["generation"] as? Int,
            let fields = row["fields"] as? [[String: Any]], !fields.isEmpty
        else {
            throw CUAFormsError.invalid(
                (result.result as? [String: Any])?["error"] as? String
                    ?? "No supported visible text fields. Passwords, dropdowns and buttons are not filled by S1."
            )
        }
        let decoded = try fields.map { field -> BrowserFormField in
            guard let ref = field["ref"] as? String, let label = field["label"] as? String,
                let value = field["value"] as? String, let signature = field["signature"] as? String
            else { throw CUAFormsError.invalid("Incomplete form field snapshot.") }
            return BrowserFormField(
                element: CUElement(
                    id: ref,
                    role: "Edit",
                    label: label,
                    value: value,
                    placeholder: field["placeholder"] as? String
                ),
                signature: signature,
                generation: generation
            )
        }
        return (row["title"] as? String ?? "", decoded)
    }

    func fillFormField(_ field: BrowserFormField, value: String) async throws {
        let valueJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let oldJSON = String(decoding: try JSONEncoder().encode(field.element.value ?? ""), as: UTF8.self)
        let validation = """
            \(Self.describeFormField)
            if (window.__osaurus_snapshot_gen !== \(field.generation)) throw new Error('Form snapshot changed.');
            const el = window.__osaurus_refs?.get('\(browserEscapeSelector(field.element.id))');
            const field = describeFormField(el);
            if (!field || field.signature !== '\(browserEscapeSelector(field.signature))') {
                throw new Error('Form target changed after scoring or approval.');
            }
            """
        let result = await evaluateJavaScript(
            """
            (() => { try {
                \(validation)
                if (field.value !== \(oldJSON)) throw new Error('Field value changed after scoring.');
                const win = el.ownerDocument.defaultView;
                const prototype = el.tagName === 'TEXTAREA' ? win.HTMLTextAreaElement.prototype : win.HTMLInputElement.prototype;
                Object.getOwnPropertyDescriptor(prototype, 'value').set.call(el, \(valueJSON));
                el.dispatchEvent(new win.Event('input', {bubbles: true}));
                el.dispatchEvent(new win.Event('change', {bubbles: true}));
                return {success: true};
            } catch(e) { return {error: e.message || String(e)}; } })()
            """
        )
        if let error = result.error { throw CUAFormsError.invalid(error) }
        guard (result.result as? [String: Any])?["success"] as? Bool == true else {
            throw CUAFormsError.invalid((result.result as? [String: Any])?["error"] as? String ?? "Form edit failed.")
        }
        await waitForDOMStable(timeout: 1)
        let verified = await evaluateJavaScript(
            """
            (() => { try { \(validation) return field.value === \(valueJSON); } catch(e) { return false; } })()
            """
        )
        guard verified.error == nil, verified.result as? Bool == true else {
            throw CUAFormsError.invalid("The page did not retain the expected field value. Inspect it before retrying.")
        }
    }
}
