# Messung 2026-11-23: Modelle zwischen zwei Macs übernehmen (0.6)

> Entstanden unter dem früheren Namen Podlight. · Written under the former name Podlight.

## Vorab-Prüfung an eigenen Test-Pods (busybox, `sleep`, zusammen etwa 2 Cent)
- `PATCH /v2/pods/{id} {"name": …}` benennt einen Pod um, **ohne Neustart**. Im Betrieb blieb er
  RUNNING und `startedAt` unverändert, gestoppt blieb er EXITED.
- `@` ist im Namen erlaubt, beim Anlegen und beim Umbenennen, und erscheint so in der Liste.
- `tags` lassen sich weder beim Anlegen noch danach setzen (422 „additional properties 'tags' not
  allowed“).
- `startedAt` wird beim Fortsetzen neu gesetzt.
- `GET /v2/pods` liefert je Pod `env`, `disk` und `mounts.persistent.size`, dazu `pagination`.

Deshalb steht der verwaltende Mac im Pod-Namen: `podlight-<modell>@<mac-kennung>`.

## Ablauf mit zwei Engines (`LiveTakeOverTests`)
Zwei `PodManager` mit eigener State-Datei und eigenem Schlüsselbund-Dienst spielen Mac A und Mac B.
Modell: `Qwen/Qwen2.5-0.5B-Instruct-GGUF` Q4_K_M, behaltene Festplatte, RTX 2000 Ada, 0,24 $/h.

| Schritt | Ergebnis |
|---|---|
| A startet | bereit nach 126 s, Pod heißt `podlight-tiny-takeover@live-a-a33b` |
| B sucht | findet `tiny-takeover from live-a-a33b running` |
| B übernimmt im Betrieb | Pod heißt `…@live-b-08d0`, Status weiter RUNNING (kein Neustart) |
| B nach der Übernahme | bereit nach 11 s; die Engine antwortet mit dem übernommenen Schlüssel (200) |
| A beim nächsten Takt | `managedBy live-b-08d0`, Gateway lehnt ab |
| B stoppt | EXITED (Festplatte bleibt) |
| A holt zurück | Pod heißt wieder `…@live-a-a33b`, bleibt EXITED |
| B beim nächsten Takt | `managedBy live-a-a33b` |
| Aufräumen | Pod gelöscht, RunPod meldet 404 |

Kosten des Ablaufs: etwa 2 Cent.

## Nicht geprüft
- Die Oberfläche am echten Pod (geprüft als Snapshots de/en).
- Ein Pod aus einer Version vor 0.6, der gerade läuft. Der Code benennt ihn beim ersten Abgleich auf
  den eigenen Mac um; geprüft ist das mit dem gefälschten RunPod.

## Nachtrag 0.7: Modelle ohne Pod
Ein Modell ohne behaltene Festplatte hat zwischen zwei Läufen keinen Pod; der zweite Mac des
Anwenders fand deshalb nichts (im Konto lag kein Podlight-Pod mehr). Seit 0.7 legt jeder Mac seine
Modelle zusätzlich als private Pod-Vorlage ab: `podlight-model-<name>@<mac>`, im env die
Modelldefinition (JSON, base64), der Pod-Schlüssel und die aktuelle Pod-ID.

Vorab an eigenen Test-Vorlagen geprüft (kostenlos): `POST/PATCH/GET/DELETE /v2/templates` funktionieren,
`PATCH` ändert Name und env, neue Vorlagen sind privat (`public: false`), Namen müssen im Konto
eindeutig sein („Template name must be unique.“), 4 KB im env sind kein Problem.

`LiveRecordsTests` mit zwei Engines, ohne Pod: Eintrag `podlight-model-records-test-8520@live-a-c9dd`
angelegt, B sieht das Modell (`pod: false`) und übernimmt es mit demselben Schlüssel, A gibt beim
nächsten Abgleich ab, A holt zurück, B gibt ab, nach dem Löschen bleibt kein Eintrag. 4,5 s, 0 $.
