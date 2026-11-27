# Messung 2026-11-21: Podlight-Server (0.4) auf echter RunPod-Hardware

> Entstanden unter dem früheren Namen Podlight. · Written under the former name Podlight.

Der Server lief als Container aus `server/Dockerfile` (lokal gebaut, `podlight-server:dev`) auf diesem
Mac unter Docker (colima). Gesteuert wurde er über die Admin-API, wie es die App tut: koppeln,
RunPod-Schlüssel setzen, Modell anlegen, Zugangsschlüssel anlegen. Die Agenten-Anfragen gingen mit
`curl` an `/v1` des Containers.

## Aufbau
- Kopplung mit festem `PAIRING_CODE`, Notbremse 5 Minuten, Tageslimit 3 $, Zeitzone Europe/Berlin.
- Modell `Qwen/Qwen2.5-0.5B-Instruct-GGUF`, Q4_K_M (0,49 GB), Kontext 8.192, Ziel „Sparsam“, ohne
  bevorzugte Karte und ohne behaltene Festplatte. KV 12.288 Byte pro Token (aus der 0.3-Messung).
- Werkzeug in der Chat-Anfrage: `get_weather(city)`, Frage „What is the weather in Berlin? Use the tool.“

## Ergebnisse
| Prüfung | Ergebnis |
|---|---|
| Schlüsselprüfung über den Server (`/admin/settings/verify-runpod`) | `valid` |
| Kartenwahl des Servers | RTX 4070 Ti Community, 0,19 $/h, als erste von sechs Karten; die billigeren (RTX 3070/3080, A4000/A5000) meldete der Katalog als nicht verfügbar |
| Aufwecken durch die erste Chat-Anfrage | Pod angelegt (`podlight-srv-tiny`), **bereit nach etwa 56 s** |
| Diese erste Anfrage | **404 ohne Inhalt**, obwohl `/v1/models` am Pod schon 200 meldete: RunPods Proxy leitete noch nicht weiter (Befund, siehe unten) |
| Folgeanfragen `/v1/chat/completions` | 200 in 0,15–0,66 s |
| Werkzeugaufruf (Chat) | `tool_calls: get_weather({"city": "Berlin"})` |
| `/v1/messages?beta=true`, Schlüssel als `x-api-key`, gestreamt, mit `role: "system"` mitten im Verlauf | 200, Ereignisse von `message_start` bis `message_stop` |
| `/v1/responses` | 200, `status: completed` |
| Unbekanntes Modell / falscher Schlüssel | 404 / 401 |
| Notbremse: Container um 17:00:13 UTC gestoppt, letzter Heartbeat 17:00:11 | Pod bei RunPod **EXITED um 17:05:18** (Abfrage alle 30 s; um 17:04:47 lief er noch), also nach gut 5 Minuten wie eingestellt |
| Server wieder gestartet (neues Image, gleiche Daten) | erkennt den Stopp: `phase: stopped`, `lastReason: stopped-outside` |
| Zweites Aufwecken per Anfrage | gestoppter Pod fortgesetzt, **erste Anfrage 200 nach 27,5 s** |
| Modell über die Admin-API gelöscht | 204; RunPod antwortet für den Pod mit 404, kein `podlight-srv-`-Pod mehr im Konto |
| Kosten laut Server, gesamter Test | 0,03 $ |

## Befund: 404 vom Proxy direkt nach dem Aufwecken
Der Server hielt die erste Anfrage fest, bis der Pod bereit war (`GET /v1/models` mit dem Pod-Schlüssel
ergab 200), und leitete sie dann weiter. RunPods Proxy antwortete darauf mit 404 ohne JSON. Eine
Sekunde später gingen alle Anfragen durch. Der Vorgänger RunPod Launcher kannte das Verhalten schon.
Seit 0.4 versuchen Server und Mac-Gateway es bei einem 404 ohne JSON bis zu 30 Sekunden lang erneut,
statt das 404 an den Agenten weiterzugeben. Beim zweiten Aufwecken mit dem neuen Image bekam die erste Anfrage 200. Ob dabei ein 404 abgefangen
wurde, protokolliert der Server nicht; belegt ist, dass der Agent keins mehr sah. Der Wiederholversuch
selbst ist in beiden Implementierungen getestet (Fake-Proxy im Server-Test, Erkennung im Swift-Test).

## Was diese Messung nicht belegt
- Coolify und ein Reverse Proxy mit Zertifikat: Der Container lief nur lokal, ohne https.
- Die Server-Bildschirme der Mac-App gegen diesen Server per Hand durchgeklickt: Geprüft sind der
  Swift-Client der App gegen den echten Node-Server (`ServerClientTests`) und die Bildschirme als
  gerenderte Snapshots.
- Ein echter `claude -p`-Lauf gegen den Server: Claude Codes Anweisungen passen nicht in 8.192 Token
  Kontext. Der Weg ist derselbe wie im Mac-Gateway, wo er mit 0.3.1 gegen ein 27B-Modell lief.
- Das Image für arm64 und amd64 aus CI; gemessen wurde das lokal gebaute arm64-Image.
- Ein Pod, den die Notbremse ohne behaltene Platte gestoppt hat, bleibt bei RunPod bis zum nächsten
  Start oder bis zum Löschen nach drei Tagen stehen (wie auf dem Mac). Nach RunPods Preisliste kostet ein
  gestoppter Pod ohne Volume-Platte nichts; gemessen wurde das hier nicht.
