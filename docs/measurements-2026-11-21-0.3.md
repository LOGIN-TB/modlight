# Messung 2026-11-21: Podlight 0.3 auf echter RunPod-Hardware

> Entstanden unter dem früheren Namen Podlight. · Written under the former name Podlight.

Ausgeführt mit `Live03Tests` (`apps/mac/PodlightEngine/Tests/PodlightEngineTests/LiveFlowTests.swift`)
über die echte RunPod-API, je einmal pro Engine. Der Ablauf geht durch `PodManager` und das lokale
Gateway wie in der App: Modell bei Hugging Face lesen, billigste passende Karte, starten, warten, die
drei Schnittstellen über das Gateway ansprechen, Pod löschen und bei RunPod nachfragen.

## Aufbau
- Werkzeug in allen Anfragen: `get_weather(city)`, Frage „What is the weather in Berlin? Use the tool.“
- Kontext 8.192 Token, keine behaltene Festplatte, Hosting „Überall“.

## Ergebnisse
| | llama.cpp | vLLM |
|---|---|---|
| Modell | `Qwen/Qwen2.5-0.5B-Instruct-GGUF`, Quantisierung Q4_K_M (0,49 GB), von Podlight vorgeschlagen | `Qwen/Qwen2.5-0.5B-Instruct` (0,99 GB, safetensors) |
| KV pro Token | 12.288 Byte, aus dem GGUF-Kopf gelesen | 12.288 Byte, aus `config.json` |
| Image | `ghcr.io/ggml-org/llama.cpp:full-cuda12-b12602` | `vllm/vllm-openai:v0.28.0` |
| Karte | RTX 3070 Community, 0,13 $/h | RTX 3070 Community, 0,13 $/h |
| Bis bereit | **85 s** | **308 s** |
| `/v1/chat/completions` mit Werkzeug | 200, `tool_calls: get_weather({"city": "Berlin"})` | 200, `tool_calls` mit `get_weather` |
| `/v1/messages` (Anthropic) mit Werkzeug, Schlüssel als `x-api-key`, `?beta=true` | 200, `content: tool_use get_weather {"city":"Berlin"}`, `stop_reason: tool_use` | 200, gleiches Ergebnis |
| `/v1/messages` gestreamt | 200, 14 Ereignisse bis `message_stop` | 200, 14 Ereignisse bis `message_stop` |
| `/v1/messages/count_tokens` | 200, `input_tokens: 31` | 200, `input_tokens: 31` |
| `/v1/responses` mit Werkzeug | 200, `function_call get_weather {"city": "Berlin"}` | 200, `function_call get_weather` |
| Pod gelöscht | RunPod antwortet mit 404 | RunPod antwortet mit 404 |

## Weitere Prüfungen
- **GGUF-Kopf an einem großen Repository** (`unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF`, nur
  Range-Requests): 27 Quantisierungen erkannt, Vorschlag Q4_K_M mit 18,6 GB, Kontext 262.144,
  KV 98.304 Byte pro Token (48 Schichten × 4 KV-Heads × (128 + 128) × 2 Byte), Werkzeugformat
  `qwen3_xml` aus der Vorlage.
- **Was Claude Code wirklich schickt:** Der echte `claude`-Befehl (lokal installiert) wurde mit
  Podlights Umgebungsvariablen auf einen lokalen Testserver gerichtet, der nur die Kopfzeilen
  protokolliert. Ergebnis: `POST /v1/messages?beta=true`, Schlüssel als `Authorization: Bearer`,
  kein `x-api-key` (bei leerem `ANTHROPIC_API_KEY`), `anthropic-version: 2023-06-01`, dazu
  `anthropic-beta`. Genau das reicht das Gateway durch.

## Was diese Messung nicht belegt
- Eine echte Arbeitssitzung von Claude Code oder Codex gegen ein großes Modell. Das 0,5B-Testmodell
  mit 8k Kontext ist dafür zu klein; geprüft sind die Schnittstellen, über die beide Agenten sprechen.
- Codex selbst: Es war auf diesem Mac nicht installiert. Die Konfiguration folgt der offiziellen
  Referenz (`wire_api = "responses"`, Provider per `-c model_provider=…`).
- llama.cpp auf mehreren Karten (`-sm layer`) und mehrere Karten mit vLLM (aus 0.2 weiter offen).

## Nachtrag 0.3.1: Claude Code gegen ein 27B-GGUF-Modell
- Modell `huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF`, Q4_K_M, llama.cpp auf einer A40 (Secure Cloud),
  Kontext 262.144, gestartet über Podlight 0.3.0.
- Der echte `claude`-Befehl mit Podlights Umgebungsvariablen bekam 500: „Jinja Exception: System message
  must be at the beginning.“ Ursache: Claude Code schickt in `messages` nach der ersten Nutzernachricht
  einen Eintrag mit `role: "system"` (Umgebung, Arbeitsordner). llama.cpp macht daraus eine zweite
  Systemnachricht, die Qwens Vorlage ablehnt.
- Derselbe Request mit diesem Eintrag als Nutzertext in `<system-reminder>`: 200, normale Antwort.
- Ein Testproxy vor dem Gateway, der genau diese Umformung macht: `claude -p` mit der Aufgabe, eine
  Datei zu lesen, rief `Read` auf, bekam das `tool_result` und antwortete richtig. 0.3.1 macht die
  Umformung im Gateway (`LocalGateway.systemMessagesAsReminders`); geprüft mit `swift test` gegen das
  Fake-vLLM, nicht erneut live mit der fertigen App.
