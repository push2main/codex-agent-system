# System-Verbesserung Report — 2026-03-24

## Diagnose: Warum hat das Agent-System eine niedrige Erfolgsquote?

**Gesamte Erfolgsquote: 12% (21 von 118 Tasks erfolgreich)**

### Hauptursache Nr. 1: Ungültiger Codex-CLI-Flag (KRITISCH)

Das System verwendete `codex -a auto` — aber `auto` ist kein gültiger Wert für `--ask-for-approval`. Die gültigen Werte sind: `untrusted`, `on-failure`, `on-request`, `never`.

**Auswirkung:** JEDER einzelne Codex-Aufruf schlug sofort fehl mit:
```
error: invalid value 'auto' for '--ask-for-approval <APPROVAL_POLICY>'
```

Das erklärt, warum 80 von 81 fehlgeschlagenen Tasks das Muster `no_steps` zeigen — der Provider-Aufruf scheiterte vor jeder Step-Ausführung. Die Fallback-Logik übernahm dann, konnte aber nur triviale Hello-World-Tasks lösen.

**Warum funktionieren Codex und Claude als Tools besser:** Wenn du direkt `codex` oder `claude` verwendest, nutzen diese Tools ihre eigenen korrekten CLI-Parameter. Das Agent-System hatte einen veralteten/falschen Flag.

### Hauptursache Nr. 2: Zu kurzes Timeout (180s)

Komplexe Tasks wie Dashboard-Änderungen oder mehrstufige Code-Refactorings brauchen oft 3-5 Minuten. Mit 180s Timeout wurden viele Tasks abgebrochen bevor sie fertig waren (65 Timeout-Failures in den Logs).

### Hauptursache Nr. 3: Zu wenige Retries (max 2)

Mit nur 2 Versuchen pro Step gab es kaum Spielraum für Feedback-getriebene Korrekturen. Der Coder bekommt Feedback vom Reviewer, aber bei nur 2 Versuchen reicht das nicht für einen vollen Korrekturzyklus.

### Hauptursache Nr. 4: Vage Planner-Prompts

Die Planner-Steps waren oft zu unspezifisch ("implement the requested change") — ohne konkrete Dateinamen und exakte Änderungsbeschreibungen scheitert der Coder-Agent systematisch.

### Hauptursache Nr. 5: Coder-Prompt ohne Lesehinweis

Der Coder-Prompt forderte nicht explizit, dass Quelldateien vor dem Editieren gelesen werden sollen oder dass Syntax-Validierung nach Änderungen nötig ist.

---

## Durchgeführte Verbesserungen

### 1. Codex-CLI-Flag korrigiert (KRITISCHSTER FIX)
- **Datei:** `scripts/lib.sh`
- **Änderung:** `codex -a auto` → `codex -a on-request`
- **Erwartete Auswirkung:** Alle Provider-Aufrufe sollten jetzt tatsächlich ausgeführt werden statt sofort zu scheitern.

### 2. Timeout erhöht
- **Datei:** `scripts/lib.sh`
- **Änderung:** Default-Timeout von 180s auf 300s erhöht
- **Erwartete Auswirkung:** Weniger Timeout-Abbrüche bei komplexen Tasks

### 3. Max Retries erhöht
- **Datei:** `scripts/lib.sh`
- **Änderung:** `MAX_AGENT_RETRIES` von 2 auf 3
- **Erwartete Auswirkung:** Ein zusätzlicher Versuch nach Feedback ermöglicht Korrekturen

### 4. Planner-Prompt verbessert
- **Datei:** `agents/planner.sh`
- **Änderungen:**
  - Jeder Step muss Dateinamen und exakte Änderung benennen
  - Verbot vager Worte ohne HOW-Spezifikation
  - Letzter Step muss konkreten Befehl enthalten
  - Weniger Steps mit präzisen Anweisungen > viele vage Steps

### 5. Coder-Prompt verbessert
- **Datei:** `agents/coder.sh`
- **Änderungen:**
  - Step-Anweisung prominent oben im Prompt
  - Instruktion: Quelldateien VOR Änderungen lesen
  - Instruktion: Syntax-Validierung nach Änderungen
  - Instruktion: Bei Verification-Steps tatsächlich Befehle ausführen
  - Feedback-Block deutlich als "fix the issues listed here" markiert

### 6. Fallback-Handling verbessert
- **Datei:** `agents/coder.sh`
- **Änderung:** Nicht-triviale Tasks erhalten actionable Guidance statt stumm zu scheitern

### 7. Lernregeln aktualisiert
- **Dateien:** `codex-learning/rules.md`, `codex-learning/prompt-rules.md`
- **Änderung:** Neue Regeln dokumentieren die gefundenen Ursachen und Lösungen

---

## Erwartete Ergebnisse

| Metrik | Vorher | Erwartet nach Fix |
|--------|--------|-------------------|
| Erfolgsquote | 12% | 50-70% |
| Timeout-Failures | 65 | <10 |
| Provider-CLI-Errors | 24+ (alle recent) | 0 |

**Die wichtigste Erkenntnis:** Der CLI-Flag-Fehler (`-a auto`) war die dominierende Ursache. Da dieser Fehler jeden einzelnen Codex-Aufruf sofort zum Scheitern brachte, war das System effektiv "blind" und konnte nur über seine Fallback-Logik arbeiten — die nur Hello-World-Tasks unterstützt. Nach der Korrektur sollte das System ähnlich gute Ergebnisse liefern wie die direkte Verwendung von `codex` oder `claude`.

---

## Geänderte Dateien

1. `scripts/lib.sh` — CLI-Flag, Timeout, Max-Retries
2. `agents/planner.sh` — Prompt-Verbesserungen
3. `agents/coder.sh` — Prompt-Verbesserungen, Fallback-Handling
4. `codex-learning/rules.md` — Neue Lernregeln
5. `codex-learning/prompt-rules.md` — Neue Prompt-Regeln
