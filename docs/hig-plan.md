# HIG-Umsetzungsplan: Podlight für macOS

> Arbeitsplan nach dem Skill `apple-hig` (LOGIN-TB/claude-skills, Stand 2026-11-16).
> Produktentscheidungen: Interview vom 2026-11-20. Quellen-IDs `[n]` verweisen auf
> `references/source-map.md` des Skills. Das ist kein Apple-Zertifikat. Die Abnahme erfolgt über
> `docs/hig-audit.json`.

## Scope
- **Produkt / Hauptaufgabe:** Ein eigenes LLM auf einer gemieteten RunPod-GPU starten, aus einem
  lokalen Coding-Agenten (z. B. OpenCode) über eine OpenAI-kompatible Adresse nutzen und dafür
  sorgen, dass der Pod nie unbemerkt Geld kostet.
- **Zielgruppe:** Entwickler mit eigenem RunPod-Konto, die nicht jeden Tag mit GPUs arbeiten.
  Sie müssen ohne Vorwissen über vLLM, VRAM oder Quantisierung zurechtkommen.
- **Kritische Journeys:**
  1. Erststart → RunPod-Key eingeben und prüfen → (HF-Token) → erstes Modell → OpenCode verbinden.
  2. Modell anlegen: suchen oder Link einfügen → Variante vorgeschlagen → GPU-Ziel → Kosten → speichern.
  3. Starten mit „Läuft bis“ → warten (Kaltstart bis ~5 min) → Antwort im Agenten → Ende/Leerlauf-Stopp.
  4. Beenden der App mit laufendem Pod → Dialog → stoppen.
  5. Kosten im Blick: Menüleiste, Übersicht, Limit erreicht → verständlicher Stopp.
  6. (M2) Server hinzufügen → koppeln → Server-Pods steuern.
- **Art:** native Apple-App (SwiftUI, wo nötig AppKit), nur macOS. Windows folgt als eigene native App
  mit gemeinsamer Logik-Spezifikation, aber eigenen Interaktionsmustern [4].
- **Plattform / Mindest-OS / SDK:** macOS 26+, Xcode 27.2 / macOS-27-SDK, Swift 6.
- **Eingaben / assistive Technik:** Maus/Trackpad, volle Tastaturbedienung, VoiceOver,
  Full Keyboard Access, Erhöhter Kontrast, Transparenz reduzieren, Bewegung reduzieren.
- **Vorhandene Vorgaben:** keine eigene Marke außer Name und Icon; Deutsch und Englisch.
- **Nichtziele:** kein iOS/iPadOS, kein Mac App Store, keine eigene App-Einstellung für Hell/Dunkel [26],
  keine Konten oder Anmeldung bei Podlight selbst, keine KI-Funktionen in der App, kein Chat-Fenster
  (Podlight ist Schnittstelle, nicht Client).
- **Quellen zuletzt geprüft:** Skill-Paraphrasen 2026-11-16. Vor der Implementierung von
  Menüleisten-Extra, Liquid Glass und Alert-Stil die Originalseiten [164][70][113] erneut lesen.

## Themenfamilien
- **Getting started / Plattformen:** macOS [32]: große Flächen, wenig Tiefe und Modalität, alle
  Befehle in der Menüleiste, Tastaturkürzel, frei skalierbare Fenster. Anwendbar.
- **Foundations:** Accessibility [8], Farbe [24], Dark Mode [26], Layout [60], Materialien [70],
  Typografie [104], SF Symbols [95], App-Icon [13], Texte [109], Bewegung [73], Datenschutz [87].
  Anwendbar. RTL: nicht unterstützte Sprachen, nur Layout-Robustheit prüfen.
- **Patterns:** Starten [59], Onboarding [79], Hilfe [78], Dateneingabe [38], Feedback [40],
  Laden [64], Modalität [72], Suchen [92], Einstellungen [94], Mitteilungen [68], Diagramme [22],
  Rückgängig [105]. Anwendbar. Nicht anwendbar: Medien, Spiele, Drucken, Dateiverwaltung, Workouts.
- **Components:** Sidebars [154], Split View, Listen/Tabellen [134], Toolbars [167], Menüleiste und
  Extras [164], Menüs [137], Buttons [116], Sheets [153], Alerts [113], Popovers [146],
  Textfelder [162], Suchfelder [151], Picker [144], Toggles [165], Disclosure [126],
  Fortschritt [147], Gauges [129], Labels [133], Charts [117], Fenster [173], Mitteilungen [138].
- **Inputs:** Tastaturen [58], Zeigegeräte [84]. Touch, Pencil, Crown usw. nicht anwendbar.
- **Technologies:** nur VoiceOver [106]. Sign in with Apple, iCloud, Siri und alle übrigen sind
  nicht anwendbar (keine Konten, keine Sync).

## Anforderungsliste
Herkunft: **HIG** = Apple-Empfehlung, **ENG** = Engineering-Ableitung, **PROD** = Produktentscheidung.

| ID | Anforderung | Herkunft | Quellen | Screen / Journey | Abnahmetest |
|---|---|---|---|---|---|
| PL-NAV-001 | Hauptfenster als NavigationSplitView: Seitenleiste mit „Dieser Mac“ (Modelle, Verbindungen, Kosten) und später „Server“, höchstens zwei Ebenen, standardmäßig sichtbar | HIG | 154, 32 | Hauptfenster | Seitenleiste ein- und ausblenden, Fenster auf Minimum: Auswahl und Rückweg bleiben |
| PL-NAV-002 | Jeder Befehl (Starten, Stoppen, Neues Modell, Verbindung kopieren, Hilfe) steht auch in der Menüleiste, mit Standard- und eigenen Kürzeln | HIG | 164, 58, 167 | alle | Toolbar ausblenden, alle Befehle per Menü und Tastatur ausführbar |
| PL-NAV-003 | Einstellungen über App-Menü / ⌘, mit stabilen Bereichen, zuletzt genutzter Bereich bleibt; aufgabenbezogene Optionen (Laufzeit, GPU-Ziel) im Kontext, nicht in den Einstellungen | HIG | 94 | Einstellungen | ⌘, öffnet zuletzt genutzten Bereich |
| PL-ONB-001 | Erststart: kein Splash; Einrichtung beginnt nach dem Start, besteht nur aus Pflichtschritten (RunPod-Key) plus optionalen (HF-Token), ist unterbrechbar und später fortsetzbar | HIG | 59, 79 | Journey 1 | Nach Schritt 1 beenden, neu starten: Fortsetzung an gleicher Stelle |
| PL-ONB-002 | Jedes Eingabefeld für Schlüssel hat 3–4 Schritte, einen Knopf, der die Key-Seite direkt öffnet, und „Prüfen“ mit Live-Ergebnis | PROD | 38, 109 | Journey 1 | Falscher, abgelaufener und richtiger Key: drei verschiedene, verständliche Ergebnisse |
| PL-ONB-003 | Schlüssel werden in sicheren Feldern eingegeben, im Schlüsselbund gespeichert, nie im Klartext angezeigt oder geloggt; Einfügen erlaubt | HIG | 38, 162, 87 | Journey 1 | Feld maskiert, Log und Defaults enthalten keinen Key |
| PL-ONB-004 | Abschluss zeigt die fertige OpenCode-Konfiguration (Adresse, Schlüssel, Modellname) mit „Kopieren“ und Prüfen der Erreichbarkeit | PROD | 40, 78 | Journey 1 | Kopierte Konfig in OpenCode funktioniert ohne weitere Änderung |
| PL-MOD-001 | Modellsuche liefert sofortige Treffer, Link-Einfügen erkennt HF-URLs; Ergebnisliste zeigt Größe, Format, Lizenz, Zugriffsbeschränkung | HIG | 151, 92, 134 | Journey 2 | Suche, Link, ungültiger Link, gated Modell ohne Token |
| PL-MOD-002 | Vorschlag einer Variante (z. B. INT4) und GPU nach Ziel Sparsam/Ausgewogen/Schnell; Alternativen mit $/h, tok/s-Schätzung, Laufzeitkosten; Schätzungen als solche gekennzeichnet | PROD | 109, 40 | Journey 2 | Zielwechsel ändert Vorschlag nachvollziehbar; „geschätzt“ ist für VoiceOver hörbar |
| PL-RUN-001 | Start als kurzes Sheet: „Läuft bis“ (Vorschläge + Uhrzeit), Kosten bis dahin, Standardknopf „Starten“, Abbrechen | HIG | 153, 72 | Journey 3 | Abbrechen startet nichts; Return startet; Esc bricht ab |
| PL-RUN-002 | Kaltstart zeigt ehrlichen Fortschritt nach Phasen (GPU suchen, Laden, Engine startet) mit Erwartungszeit; andere Bereiche bleiben bedienbar | HIG | 64, 147 | Journey 3 | Langsamer und abgebrochener Start: kein hängender Spinner, Stillstand erklärt |
| PL-RUN-003 | Status nie nur über Farbe: Symbol + Text („Läuft · noch 1:42 h · 0,74 $/h“) | HIG | 24, 8, 133 | Liste, Menüleiste | Graustufen und VoiceOver unterscheiden alle Zustände |
| PL-RUN-004 | Menüleisten-Extra mit Status, Restzeit, Kosten/h und Stopp; nicht einziger Zugang zu Funktionen | HIG | 164 | Menüleiste | Jede Menüleisten-Aktion auch im Hauptfenster/Menü vorhanden |
| PL-RUN-005 | Beenden mit laufenden lokalen Pods: Alert mit Anzahl, Kosten/h, Standard „Stoppen und beenden“, Alternativen „Weiterlaufen lassen“ (mit Hinweis auf Notbremse) und „Abbrechen“ | HIG | 113, 40 | Journey 4 | ⌘Q mit/ohne Pod; Abbrechen beendet nicht; Escape = Abbrechen |
| PL-RUN-006 | Fenster schließen beendet die App nicht; Gateway läuft weiter, Menüleisten-Symbol bleibt | PROD | 173 | Fenster | Fenster schließen, Agent fragt weiter an: Antwort kommt |
| PL-RUN-007 | Ereignisse außerhalb des Fensters (Pod bereit, Laufzeit endet in 10 min, Limit erreicht, Notbremse ausgelöst) als Mitteilung nach Einwilligung, ohne Dubletten | HIG | 138, 68 | Hintergrund | Berechtigung ablehnen: App funktioniert, Hinweis im Fenster stattdessen |
| PL-COST-001 | Kostenübersicht mit Diagramm (Tag/Monat, je Quelle) und Limit als Gauge; Diagramm hat Text-Alternative | HIG | 117, 22, 129 | Kosten | VoiceOver liest Werte und Limit; Diagramm ohne Farbe lesbar |
| PL-COST-002 | Limit erreicht: Pod stoppt, Erklärung am Ort mit Lösungsweg (Limit anheben / morgen) statt nur Fehlercode | HIG | 40, 109 | Journey 5 | Limit künstlich niedrig, Anfrage aus Agent: verständliche Meldung in App und Agent |
| PL-DEL-001 | Löschen eines Modells: Bestätigung nur, wenn Disk/Pod betroffen ist; Undo für Bearbeitungen im Modell-Editor | HIG | 113, 105 | Modell-Editor | ⌘Z nimmt letzte Änderung zurück; Löschen nennt Folgen |
| PL-HELP-001 | Kontextbezogene Hilfe: Tooltips beschreiben die Aktion; „?“-Knöpfe an komplexen Feldern (Kontext, Quantisierung, Leerlauf) öffnen kurze Popover; Hilfe-Menü öffnet die Anleitung | HIG | 78, 146 | alle | Jeder Hilfe-Knopf hat Inhalt; Help-Menü funktioniert |
| PL-UI-001 | Systemfarben/-materialien, keine eigenen Blur-Kopien; Liquid Glass nur über Systemkomponenten (Toolbar, Seitenleiste), nicht auf Inhaltskarten | HIG | 70, 24 | alle | Transparenz reduzieren / Kontrast erhöhen: alles lesbar |
| PL-UI-002 | Hell/Dunkel folgt dem System; Wechsel bei laufender App | HIG | 26 | alle | Umschalten im laufenden Betrieb |
| PL-UI-003 | Semantische Textstile, kein abgeschnittener Text bei langen deutschen Begriffen und schmalem Fenster | HIG | 104, 60 | alle | Minimalbreite, Deutsch, längste Strings |
| PL-UI-004 | Controls in macOS-Standardgröße (28×28 pt Standard, 20×20 Minimum) | HIG | 8 | alle | Accessibility Inspector |
| PL-UI-005 | App-Icon nach macOS-Vorgaben, ohne RunPod-Logo | HIG | 13 | Icon | Icon in Dock, Finder, hell/dunkel |
| PL-A11Y-001 | Alle Journeys mit VoiceOver ausführbar: Labels, Werte, Zustände, sinnvolle Reihenfolge | HIG | 8, 106 | alle | VoiceOver-Durchlauf Journeys 1–4, protokolliert |
| PL-A11Y-002 | Alle Journeys nur mit Tastatur (Full Keyboard Access) ausführbar | HIG | 58, 84 | alle | Ohne Maus Journeys 1–4 |
| PL-A11Y-003 | Bewegung reduzieren respektiert (Fortschritts- und Statusanimationen) | HIG | 73, 8 | alle | Einstellung an: keine dekorative Bewegung |
| PL-TXT-001 | Einheitliche Begriffe de/en („Modell“, „Verbindung“, „Läuft bis“, „Leerlauf-Stopp“); Fehlermeldungen ohne Schuld, mit nächstem Schritt; leere Zustände mit Aktion | HIG | 109 | alle | Glossar vorhanden; jeder Fehler hat Aktion |
| PL-STATE-001 | Zustandsmatrix (unten) für jeden datenabhängigen Screen umgesetzt | ENG | 64, 40 | alle | je Zustand ein UI-Test oder Screenshot |
| PL-PRIV-001 | Keine Telemetrie; Netzwerkziele nur RunPod, Hugging Face, Pods, eigene Server, Update-Feed; in der Hilfe benannt | PROD | 87 | Hilfe | Netzwerkmitschnitt eines Durchlaufs |

## Informationsarchitektur
- **Hauptfenster (NavigationSplitView):**
  - Seitenleiste: Abschnitt **Dieser Mac** → *Modelle*, *Verbindungen*, *Kosten*; Abschnitt
    **Server** (M2) → je Server dieselben drei Einträge; unten nichts Kritisches [154].
  - *Modelle*: Liste (Name, GPU, Status, Restzeit, $/h); Detail mit Starten/Stoppen, Laufzeit,
    Zeitplan, Bearbeiten. Leerer Zustand: „Erstes Modell hinzufügen“.
  - *Verbindungen*: Adresse, Schlüssel (anlegen, beschränken, widerrufen), Rezepte (OpenCode zuerst,
    dann weitere Clients) mit Kopieren.
  - *Kosten*: heute/Monat, je Modell und Quelle, Limits, Speicherkosten angehaltener Pods.
- **Modalitäten:** Einrichtung (eigenes Fenster beim Erststart, später über Hilfe-Menü erneut),
  Start-Sheet, Neues Modell (Sheet mit Schritten Suche → Variante → GPU → Laufzeit/Zeitplan →
  Name), Beenden-Alert. Keine Sheet-Kaskaden [153].
- **Menüleiste:** Podlight · Ablage (Neues Modell ⌘N) · Bearbeiten (Undo) · Modell (Starten ⌘R,
  Stoppen ⌘., Verlängern) · Verbindung (OpenCode-Konfig kopieren ⇧⌘C) · Fenster · Hilfe
  (Podlight-Hilfe, Einrichtung erneut, RunPod-Konsole öffnen).
- **Menüleisten-Extra:** Status je laufendem Pod, Restzeit, $/h, Stopp, „Podlight öffnen“.
- **Wiederherstellung:** letzte Auswahl und Fenstergröße.

## Zustandsmatrix
| Screen | Initial | Loading | Content | Empty | Error | Offline | Denied | Disabled | Partial |
|---|---|---|---|---|---|---|---|---|---|
| Einrichtung | Schritt 1 | Key wird geprüft | geprüft ✓ | – | Key ungültig/abgelaufen, mit Erklärung | kein Internet → Hinweis, Eingabe bleibt | Key ohne Schreibrecht | „Weiter“ bis gültig | HF-Token fehlt (optional) |
| Modelle | aus Store | RunPod-Status lädt (Liste sofort aus Cache) | Liste | „Erstes Modell“ | RunPod-API-Fehler | Cache mit Zeitstempel „Stand von …“ | – | Starten aus, wenn Limit erreicht (mit Grund) | Pod-Status unbekannt |
| Modellsuche | leer + Hinweis | Suche läuft | Treffer | keine Treffer + Tipp | HF nicht erreichbar | Hinweis | gated ohne Token → Token-Schritt | – | Metadaten unvollständig |
| Start | Sheet | GPU suchen / Laden / Engine | läuft | – | keine Karte frei → Alternativen | Abbruch erklärt | Limit | – | Fallback-Karte genutzt |
| Verbindungen | Adresse + Schlüssel | – | Rezepte | kein Schlüssel → anlegen | Port belegt → Lösung | – | – | – | – |
| Kosten | heute | lädt | Diagramm | „Noch keine Kosten“ | – | Stand von … | – | – | Server nicht erreichbar (M2) |

## Designsystem
- **Farben:** nur Systemfarben semantisch (Akzent für primäre Aktion; Grün/Orange/Rot nur zusammen
  mit Symbol und Text für Läuft/Startet/Fehler). Keine eigenen Hex-Werte außer im App-Icon.
- **Text:** System-Textstile; Zahlen (Kosten, Zeiten) mit `monospacedDigit`, Formatierung
  über `FormatStyle` (Währung USD, Region des Nutzers).
- **Layout:** Mindestfenster so wählen, dass die längste deutsche Zeile nicht abgeschnitten wird;
  Formulare als `Form` (`.grouped`).
- **Controls / Icons:** Standard-SwiftUI-Controls; SF Symbols (`bolt.circle`, `moon.zzz`,
  `stop.circle`, `clock`, `dollarsign.circle` o. ä., final nach Verfügbarkeit im SDK prüfen).
- **Materialien:** Systemverhalten von Toolbar und Seitenleiste; kein `glassEffect` auf Inhalten.
- **Fokus / Motion:** Standardfokus; Animationen nur funktional und mit Reduce Motion abgeschaltet.

## Testmatrix und Belege
- **Umgebung:** macOS 27.2.1 (dieser Mac); macOS 26 in einer VM, sobald vorhanden. Bis dahin ist
  macOS 26 **blockiert**, nicht bestanden.
- **Befehle:** `swift test` (Engine gegen `spec/cases`), `xcodebuild test` (UI-Tests),
  Screenshots aus UI-Tests nach `docs/screenshots/<sprache>/`.
- **Visuell:** hell/dunkel, Kontrast erhöht, Transparenz reduziert, Minimal- und Maximalfenster, de/en.
- **Assistiv:** VoiceOver- und Tastaturdurchlauf der Journeys 1–4, Protokoll in `docs/evidence/`.
- **Fehler-/Abbruchpfade:** falscher Key, keine Karte frei, Limit erreicht, Netz weg, Port belegt,
  Beenden während Start.
- **Nicht ausführbar / Blocker:** echter Pod nötig für Journeys 3–5 (Kosten). Jeder Lauf braucht
  die Freigabe des Kontoinhabers.

## Abweichungen und Freigabe
- Noch keine. Abweichungen werden hier mit Kriterium, Begründung, Nutzerwirkung und Alternative eingetragen.
- Abnahmestatus: offen. Alle Kriterien stehen in `docs/hig-audit.json` auf `not_tested`.
