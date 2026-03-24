# System-Verbesserungsreport: Warum die Erfolgsquote niedrig ist

**Datum:** 2026-03-24
**Gesamte Erfolgsquote:** 12% (20 von 117 Tasks erfolgreich, 81 fehlgeschlagen)
**First-Pass Success Rate:** 58% (nur 14 von 24 beendeten Tasks beim ersten Versuch)

---

## Kernprobleme (Root Causes)

### 1. AGENT_EXEC_TIMEOUT zu niedrig (90 Sekunden)

**Das größte Problem.** Der `codex` CLI bekommt nur 90 Sekunden (`AGENT_EXEC_TIMEOUT_SECONDS=90`), um eine Aufgabe zu planen, Code zu schreiben, und JSON zurückzugeben. Bei komplexeren Tasks (Dashboard-Änderungen, Multi-File-Edits) reicht das oft nicht. Im Vergleich: Wenn du Codex oder Claude direkt im Terminal nutzt, gibt es kein 90-Sekunden-Limit — die Tools laufen so lange wie nötig.

**Beleg:** Logs zeigen häufig `codex exec timed out after 90s; using fallback logic`. Das Fallback schreibt dann ein `hello.sh` oder gibt eine Fehlermeldung aus — das hat nichts mit der eigentlichen Aufgabe zu tun.

**Fix:** `AGENT_EXEC_TIMEOUT_SECONDS` auf mindestens **180–300 Sekunden** erhöhen.

### 2. Fallback-Logik erzeugt irrelevante Ergebnisse

Wenn Codex/Claude fehlschlägt oder timeout, springt das System auf eine "Fallback"-Logik:
- **implement_fallback** erstellt ein `hello.sh` mit `echo "Hello, World!"` — egal was die eigentliche Aufgabe war
- **inspect_fallback** listet einfach Dateien auf und meldet "success"
- **verify_fallback** prüft ob `hello.py` "Hello, World!" ausgibt

Das heißt: Das System meldet manchmal "success" für Tasks, die gar nicht bearbeitet wurden. Und bei den meisten komplexen Tasks kommt ein "fail" raus, weil das Fallback nichts Nützliches tun kann.

**Fix:** Fallback-Logik komplett überarbeiten:
- Bei Timeout: Task zurück in die Queue mit erhöhtem Timeout statt Fallback
- Fallback nur für triviale "hello world"-Tasks verwenden
- Für alle anderen Tasks: ehrlich "fail" melden und requeuen

### 3. Prompts sind zu lang und unstrukturiert

Die Prompts an Codex/Claude enthalten:
- Task-Text
- Plan-JSON
- Memory-Kontext (letzte 20 Zeilen von decisions.md — das sind ~148KB)
- Source-Kontext
- Similar-Task-Kontext
- Verification-Guidance
- Feedback von vorherigen Versuchen
- Dateiliste

Das kann leicht **mehrere tausend Tokens** sein. Codex CLI im `exec`-Modus mit `-a never` (kein Approval) hat aber einen begrenzten Kontext. Wenn der Prompt zu lang ist, wird der relevante Teil (die eigentliche Aufgabe) vom Noise überschwemmt.

**Im Vergleich:** Wenn du Codex direkt nutzt, gibst du einen klaren, fokussierten Prompt ein. Kein Noise von Memory, Similar Tasks, etc.

**Fix:**
- Memory-Kontext auf max. 500 Zeichen kürzen (nur die 3–5 relevantesten Entscheidungen)
- Similar-Task-Kontext auf max. 1 Task beschränken
- Source-Kontext nur inkludieren wenn direkt relevant
- Prompt-Template straffen

### 4. Retry-Churn: Gleiche Tasks werden immer wieder versucht

Das System hat einen Teufelskreis:
1. Task schlägt fehl → Strategy erzeugt Follow-up-Task
2. Follow-up-Task ist im Kern die gleiche Aufgabe
3. Follow-up schlägt auch fehl → wieder ein Follow-up
4. **48 Tasks** haben "loop effort" mit **77 extra Versuchen**

Metrics zeigen: `retry_churn_detected: true`, `strategy_saturation_detected: true`, `saturated_failed_tasks: 29`.

**Fix:**
- Max. 2 Retries pro Task, dann permanent als "blocked" markieren
- Strategy soll keine Follow-ups für saturierte Tasks erzeugen
- "Saturated" Tasks in einen separaten Backlog verschieben

### 5. Codex CLI wird mit `-a never` aufgerufen (kein File-Approval)

Der Befehl ist: `codex -a never exec --skip-git-repo-check --ephemeral --color never -C <dir> --add-dir <root> -s workspace-write -o <output> <prompt>`

`-a never` bedeutet: Codex darf keine Dateien erstellen/ändern ohne Approval — aber da niemand da ist, der approven kann, muss es im Non-Interactive-Modus die Änderungen direkt machen. Das `-s workspace-write` erlaubt Schreiben, aber die Kombination kann bei bestimmten Operationen zu Konflikten führen.

**Fix:** `-a auto` verwenden statt `-a never`, damit Codex automatisch alle Änderungen genehmigt. Oder `-a full-auto` wenn verfügbar.

### 6. Task-Beschreibungen sind zu abstrakt

Viele fehlgeschlagene Tasks haben sehr abstrakte Beschreibungen wie:
- "Replace Detect retry churn and queue starvation before strategy declares the board healthy with a different bounded experiment"
- "Inventory current state for Keep an executable system-work buffer..."

Das sind keine klaren, ausführbaren Anweisungen. Codex/Claude brauchen konkrete Schritte: welche Datei, welche Funktion, was genau ändern.

**Im Vergleich:** Wenn du Codex direkt nutzt, sagst du z.B. "In server.js, ändere die Funktion X so dass Y" — das ist viel konkreter.

**Fix:** Strategy-Agent soll konkretere Tasks generieren mit:
- Explizite Dateinamen
- Explizite Funktionsnamen
- Klare Vorher/Nachher-Beschreibung

### 7. Claude-Provider hat 0% Erfolgsrate in 6 von 8 Kategorien

Die `provider-stats.json` zeigt: Claude hat bei auth, code_quality, general, learning, project, testing jeweils 0% Erfolgsrate. Nur bei `infra` (13%) und `ui` (14%) etwas Erfolg. Trotzdem werden Tasks an Claude geroutet.

**Fix:** Claude-Routing nur für UI-Tasks beibehalten, alle anderen an Codex. Oder die Claude-Integration debuggen — wahrscheinlich ist die JSON-Schema-Validierung oder der Prompt das Problem.

---

## Zusammenfassung: Warum Codex/Claude direkt besser funktionieren

| Faktor | Dein Agent-System | Codex/Claude direkt |
|--------|-------------------|---------------------|
| **Timeout** | 90 Sekunden | Kein Limit |
| **Prompt-Klarheit** | Überladen mit Memory, Context, Feedback | Klarer, fokussierter Prompt |
| **Fehlerbehandlung** | Hello-World-Fallback | Natürliche Fehlerkorrektur |
| **Task-Beschreibung** | Abstrakt, generiert | Von dir formuliert, konkret |
| **Interaktivität** | Keine (ephemeral, non-interactive) | Interaktiv, kann nachfragen |
| **Kontext** | Artificielle JSON-Pipeline | Voller Codebase-Zugriff |

---

## Priorisierte Änderungen

### Sofort (High Impact, Low Effort)

1. **`AGENT_EXEC_TIMEOUT_SECONDS` auf 180 erhöhen** — in `scripts/lib.sh` Zeile 4819
2. **`-a never` → `-a auto`** — in `scripts/lib.sh` Zeile 4878
3. **Max Retries auf 2 begrenzen** und saturierte Tasks nicht weiter verfolgen

### Kurzfristig (High Impact, Medium Effort)

4. **Prompts kürzen**: Memory auf 500 Zeichen, Similar Tasks auf 1
5. **Fallback-Logik überarbeiten**: Kein Hello-World für nicht-triviale Tasks
6. **Claude-Routing fixen**: Nur für UI-Tasks verwenden oder Debug der JSON-Schema-Probleme

### Mittelfristig (Architektur)

7. **Strategy-Agent Tasks konkreter machen**: Dateinamen, Funktionsnamen, klare Ziele
8. **Evaluator-Fallback verbessern**: Nicht automatisch "score 8" bei approved, sondern tatsächlich prüfen
9. **Task-Registry-Druck reduzieren**: 1.5MB tasks.json ist zu groß, alte Tasks archivieren
