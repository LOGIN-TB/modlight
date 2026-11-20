# Messung 2026-11-20: Kann ein Pod sich selbst stoppen?

Frage aus dem Redesign (Entscheidung 4, 20, 21): Ein lokal gestarteter Pod soll sich selbst
stoppen, wenn Podlight sich 15 Minuten nicht meldet (Mac schläft, App abgestürzt, Netz weg).
Dafür braucht der Pod eine Möglichkeit, sich selbst anzuhalten. Vorher war nur ein
Forenbeitrag bekannt, dessen Verfasser es selbst nicht getestet hatte.

## Aufbau
- Pod `c5a97jvle6gxin`, Tesla V100-SXM2-16GB, Community Cloud, 0,23 $/h, Image `python:3.12-slim`.
  (RTX 2000 Ada Secure und RTX 3090 Community waren beim Anlegen vergriffen.)
- Prüfskript: [`spikes/2026-11-20-dead-man-probe.py`](spikes/2026-11-20-dead-man-probe.py). Es gibt
  nur Variablennamen, Längen und HTTP-Statuscodes aus, nie Werte. Bericht:
  [`spikes/2026-11-20-dead-man-report.json`](spikes/2026-11-20-dead-man-report.json).
- Erstellt 18:39:25 UTC mit einem eigens angelegten Test-Key, danach gelöscht. Kosten ca. 0,03 $.

## Ergebnisse (gemessen, Quelle: RunPod-API und Pod-Logs)
1. **RunPod legt einen eigenen Key in jeden Pod:** `RUNPOD_API_KEY` (50 Zeichen), dazu
   `RUNPOD_POD_ID` und `runpodctl` unter `/usr/bin/runpodctl`, selbst in einem fremden Image
   (`python:3.12-slim`), das beides nicht mitbringt.
2. **Dieser Key ist eingeschränkt:**
   - `GET /v2/pods` (alle Pods des Kontos) → **403**
   - `GET /v2/catalog/gpus` → **403**
   - `GET /v2/pods/{eigene ID}` → **200**
3. **Der Pod kann sich damit selbst stoppen:** Haltezeit-Ende 18:45:27, danach
   `POST /v2/pods/{eigene ID}/action {"action":"stop"}`. RunPod-Log: `stop container` um
   **18:45:29**, Status danach `EXITED`, mögliche Aktionen `start, terminate`. Das ist der
   API-Stopp, nicht das Ende des Hauptprozesses: Das hätte das Skript erst 120 s später ausgelöst.
4. `rest.runpod.io/v1` war aus dem Pod heraus nicht erreichbar (Netzwerkfehler). `api.runpod.io/v2`
   funktioniert.

## Folgen für Podlight
- **Entscheidung 20 erledigt sich besser als geplant:** Es braucht **keinen Zweitschlüssel** im Pod.
  Die Notbremse nutzt den Key, den RunPod selbst einsetzt. Kein Key des Nutzers verlässt den Mac.
- Die Notbremse läuft als Watchdog im Pod-Image (`pod/`): Sie erwartet regelmäßig einen Heartbeat
  vom Launcher (über den Gateway-Port mit dem Launcher-API-Key) und ruft nach 15 min ohne
  Heartbeat `POST https://api.runpod.io/v2/pods/$RUNPOD_POD_ID/action {"action":"stop"}` auf.
  Ergänzend gilt eine harte Obergrenze (`maxRuntime`/„Läuft bis“ + Puffer), ebenfalls im Pod.
- `api.runpod.io/v2` verwenden, nicht `rest.runpod.io/v1`.

## Nachtest: Sieht der Pod-Key fremde Pods? (2026-11-20, 18:52 UTC)
- Pod `rui1hhvta9mxfz`, RTX A2000, Community, 0,12 $/h, sofort danach gelöscht. Skript und Bericht:
  [`spikes/2026-11-20-foreign-pod-probe.py`](spikes/2026-11-20-foreign-pod-probe.py),
  [`spikes/2026-11-20-foreign-pod-report.json`](spikes/2026-11-20-foreign-pod-report.json).
- Mit dem injizierten Key, nur lesend:
  - eigener Pod → **200**
  - ein anderer, angehaltener Pod desselben Kontos → **404 „pod not found“**, Logs desselben Pods ebenfalls 404
  - Network Volumes → 404
- Gegenprobe mit dem Konto-Key: Derselbe fremde Pod existiert (200).
- **Ergebnis:** Der Pod-Key ist auf den eigenen Pod begrenzt, andere Pods sind für ihn unsichtbar.
  Stoppen oder Löschen fremder Pods wurde bewusst nicht versucht. Aus „nicht sichtbar“ folgt es
  sehr wahrscheinlich, ist aber nicht gemessen.
- Nebenbefund: V100, RTX 3090 und RTX 2000 Ada waren nicht zu bekommen, obwohl der Katalog
  Sekunden vorher „LOW“ meldete. Verfügbarkeit im Katalog ist kein Versprechen. Der GPU-Vorschlag
  braucht immer Ausweichkarten.

## Nicht geprüft (offen)
- Ob der Pod-Key auch `terminate` darf (für „nach 3 Tagen löschen“ braucht es ihn nicht; das macht
  die App).
- Was RunPod tut, wenn der Hauptprozess endet (Neustart oder `EXITED`). Für die Notbremse nicht
  mehr nötig, für die Fehlerbehandlung der Engine aber interessant.
- Verhalten in der Secure Cloud und bei anderen Images (vLLM). Gemessen wurde nur Community + python-slim.
