// Copyright © 2026 osaurus.

import VMLXJinja
import Testing

@Suite("Jinja template compatibility")
struct JinjaTemplateCompatibilityTests {
    @Test("For-loop iterable accepts binary plus expression")
    func forLoopIterableAcceptsBinaryPlusExpression() throws {
        let source = """
            {%- set loop_messages = messages -%}
            {%- for message in loop_messages + [{'role': '__sentinel__'}] -%}
              {%- if message.role != '__sentinel__' -%}
                {{- '[INST]' -}}{{- message.content -}}{{- '[/INST]' -}}
              {%- endif -%}
            {%- endfor -%}
            """

        let template = try Template(source)
        let output = try template.render([
            "messages": [
                ["role": "user", "content": "Hi"]
            ]
        ])

        #expect(output == "[INST]Hi[/INST]")
    }
}
