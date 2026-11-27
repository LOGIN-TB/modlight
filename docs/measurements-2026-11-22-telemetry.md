# Messung 2026-11-22: Auslastung der Pods (0.5) auf echter RunPod-Hardware

> Entstanden unter dem früheren Namen Podlight. · Written under the former name Podlight.

Geprüft wurde, ob der Watchdog im Pod die Auslastung misst und mit jedem Heartbeat zurückgibt, und ob
Mac und Server sie als Verlauf halten. Mac-Seite: `LiveTelemetryTests` (`PODLIGHT_LIVE_TELEMETRY=vllm|llamacpp`,
12 Last-Anfragen nach dem Start). Server-Seite: Node-Server lokal mit festem `PAIRING_CODE`, gesteuert
über die Admin-API, drei Chat-Anfragen. Alle Test-Pods wurden danach gelöscht, RunPod meldete für jeden
404. Kosten aller Läufe zusammen etwa 0,10 $.

## Vorab: was RunPods API liefert
- GraphQL `pod { runtime { … } latestTelemetry { … } }` liefert CPU %, RAM %, Uptime und je GPU Last,
  Temperatur und Watt.
- Das GPU-Feld `memoryUtilization` ist nicht der belegte Grafikspeicher: Es stand bei 0 % auf einem
  vLLM-Pod mit rund 94 % belegtem VRAM.
- Belegter VRAM in Bytes und die Container-Festplatte fehlen ganz; Introspection ist gesperrt.
- Deshalb misst der Watchdog selbst (`nvidia-smi`, cgroup, `statvfs`, `/metrics` der Engine).

## Ergebnisse
| Prüfung | Ergebnis |
|---|---|
| `nvidia-smi` in den Images | vorhanden in `vllm/vllm-openai:v0.28.0` und `ghcr.io/ggml-org/llama.cpp:full-cuda12-b12602` |
| vLLM auf RTX A4000 | VRAM 15,7 von 17,2 GB, RAM-Grenze 31 GB, Festplatte; Engine unter Last 176 Token/s |
| llama.cpp mit `--metrics` (RTX 3080 Ti) | laufende Anfragen und Token/s (unter Last bis 600 Token/s); **kein KV-Cache-Wert** |
| Erste Messung nach dem Start | mit dem ersten Heartbeat, bei llama.cpp schon in der Phase „loading“ (ohne Engine-Teil) |
| GPU-Last, `nvidia-smi` einmal je Messung | **0 % unter Last** (RTX 2000 Ada: 297 Token/s, 49 von 70 W) — Befund, siehe unten |
| GPU-Last mit Sekunden-Mittel | Verlauf `[0, 74, 88, 89, 71, 0, …]` %: unter Last hoch, danach 0 |
| Server: `/admin/state` | `telemetry` je Lauf, ab dem ersten Heartbeat nach „ready“ |
| Server: `/admin/models/{id}/telemetry` | Verlauf mit allen Messungen; nach dem Löschen des Modells (204) ist der Pod weg (404) |

## Befund: GPU-Last 0 % unter Last
`utilization.gpu` von `nvidia-smi` ist der Anteil der Zeit im letzten Messfenster, in dem ein Kernel
lief. Ein einzelner Aufruf alle 5 s traf bei kurzen Anfragen oft eine Pause und meldete 0 %, obwohl die
Karte arbeitete. Der Watchdog startet jetzt ein dauerhaft laufendes
`nvidia-smi --query-gpu=… --loop-ms=1000` und meldet je Messung den Mittelwert der Sekundenwerte seit
der letzten Messung.

## Nicht geprüft
- Pods mit mehreren Karten (die Ringe erscheinen je Karte; live nicht gemessen).
- Ein fortgesetztes Volume unter `/workspace`.
- Ein Server hinter HTTPS; die App-Ansicht wurde als Screenshot geprüft, nicht an einem echten Pod
  durchgeklickt.
