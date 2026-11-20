# Messung 2026-11-20: Podlight 0.1 auf echter RunPod-Hardware

Der ganze lokale Ablauf, ausgeführt mit `LiveFlowTests` (`apps/mac/PodlightEngine/Tests`) über die
echte RunPod-API und einen echten Pod. Die Uhrzeiten stammen aus dem Testprotokoll, der Pod-Status aus
RunPods eigener API.

## Aufbau
- Modell: `Qwen/Qwen2.5-0.5B-Instruct` (Safetensors, 1,0 GB, Kontext 32.768), von Podlight auf
  Hugging Face gelesen: Werkzeugaufrufe ja, Parser `hermes` aus der Chat-Vorlage.
- Ziel „Sparsam“, Karten bis 0,60 $/h. Vorschlag in dieser Reihenfolge: RTX 3080 Ti Community 0,18 $,
  RTX 2000 Ada Secure 0,24 $, RTX 4090 Community 0,34 $, RTX 5080 Community 0,39 $, RTX PRO 4000
  Secure 0,57 $. Nur Karten mit freiem CUDA-13-Host und Rechenleistung ab 7.5.
- Image `vllm/vllm-openai:v0.28.0` mit Podlights Startskript, Kontext 8.192, „Läuft bis“ +25 min.

## Ergebnisse
| Schritt | Ergebnis |
|---|---|
| Anlegen | Pod auf RTX 3080 Ti, 0,18 $/h, erste Wahl verfügbar (kein Ausweichen nötig) |
| Bis bereit (neuer Pod) | **1.318 s (22 min)**. Das 1-GB-Modell ist dabei Nebensache; der Großteil ist das Laden des etwa 9 GB großen Images auf einen Host, der es noch nicht hatte. |
| Herzschlag an die Notbremse | beantwortet (`lastHeartbeatAt` gesetzt) |
| Streaming über den Gateway | HTTP 200, 12 SSE-Ereignisse, `[DONE]` |
| Anfrage mit Werkzeug | HTTP 200, `tool_calls: get_weather({"city": "Berlin"})` – der Parser aus der Vorlage stimmt |
| Stopp | RunPod meldet `EXITED` |
| Fortsetzen (derselbe Pod) | **64 s** bis bereit |
| Kostenbuch | 0,069 $ für den Lauf |
| Löschen | RunPod antwortet für den Pod mit 404 |

## Folgen
- Texte in App und Hilfe nennen jetzt 10–25 Minuten für einen neuen Pod und etwa eine Minute für das
  Fortsetzen, statt der vorher geschätzten 3–10 Minuten.
- Die Wartezeit des Gateways beim Aufwecken ist auf 10 Minuten erhöht (passend zu OpenCodes
  `headerTimeout`). Für einen ganz neuen Pod reicht auch das nicht; die Hilfe rät, ein neues Modell beim
  ersten Mal in Podlight zu starten.
- Offen: ob ein Host, der das Image schon im Cache hat, deutlich schneller ist. Das hängt davon ab,
  wo RunPod den Pod platziert, und lässt sich von Podlight aus nicht steuern.
