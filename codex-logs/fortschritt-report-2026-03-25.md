# Fortschrittsbericht — Codex Agent System
## 2026-03-25, Update 2 (automatisiert)

---

## 1. Gesamtstatus: VERBESSERUNG, aber Timeout-Krise bremst

| Metrik | Wert | Trend |
|---|---|---|
| Gesamt-Erfolgsrate | 15% (522 Runs) | — |
| Letzte 50 Tasks | 28% | ↑ verbessert |
| Letzte 20 Tasks | 15% | ↓ Rückfall |
| Heute (25.03.) | 24% (26/110) | ↔ stabil |
| First-Pass-Success | 55% (22/40) | ✓ gut |
| Timeout-Rate | 36% gesamt | ⚠ kritisch |
| Zero-Step-Timeouts | 94% aller Timeouts | ⚠ Hauptproblem |

**Kernbefund:** Die Success-Rate hat sich von 4-6% (Fenster 51-150) auf 22-28% (Fenster 401-522) verbessert — ein klarer positiver Trend. ABER: Die letzten 20 Tasks zeigen einen Rückfall auf 15%, verursacht durch eine massive Timeout-Welle (17 von 20 Failures sind Zero-Step-Timeouts).

---

## 2. Projekt-Aufschlüsselung

| Projekt | Runs | Success | Timeouts | Rate |
|---|---|---|---|---|
| superheld | 184 | 38 | 90 | 21% |
| codex-agent-system | 326 | 34 | 142 | 10% |
| test-app | 6 | 6 | 0 | 100% |

**Superheld** ist das aktive Projekt mit 110 Runs heute. Die Erfolgsrate liegt bei 21% — vor allem dokumentations- und konfigurationsnahe Tasks schaffen es (DSGVO, CI/CD, Push Notifications), während komplexe Feature-Tasks (Compose UI, WebSocket, Deep Linking) fast ausnahmslos an Timeouts scheitern.

---

## 3. Aktive Alerts (3)

1. **CRITICAL: Registry Pressure** — 1.16 MB (superheld: 1.08 MB). Das Dashboard leidet unter Leselatenz. Kompaktierung nötig.
2. **HIGH: Retry Churn** — 169 Analysis-Runs. Tasks werden erneut analysiert, ohne dass sich das Ergebnis ändert.
3. **WARNING: Loop Effort** — 72 Tasks mit 171 verschwendeten Extra-Step-Attempts.

---

## 4. Was funktioniert?

**Erfolgreiche Task-Typen (letzte 24h):**
- Dokumentation & Compliance: DSGVO DSAR Generator ✓, Security Architecture Doc ✓, EU Funding Package ✓
- Konfiguration & Setup: CI/CD Pipeline ✓, Test Infrastructure ✓, Desktop System Tray ✓
- Leichtgewichtige Features: Push Notifications (Android) ✓, Clipboard Monitor ✓, WiFi Security Checker ✓, Social Media Privacy Wizard ✓

**Gemeinsames Muster:** Tasks mit ≤3 Dateien, <100 Zeilen Änderung und klarem Scope schaffen den First-Pass.

**Provider-Stärken:**
- Claude: Testing (80%!), UI general (15%), Infra (17%)
- Codex: Auth (40%), Code Quality (13%), General (22%)

---

## 5. Was scheitert systematisch?

### 5.1 Zero-Step-Timeouts (Hauptproblem)
28 der letzten 50 Tasks sind Zero-Step-Timeouts — der Orchestrator/Planner verbraucht das gesamte Timeout-Budget (600-900s), bevor auch nur ein Step ausgeführt wird.

**Betroffene Task-Typen:**
- Komplexe UI-Tasks (Compose Migration, SwiftUI Screens, Web Dashboard)
- Multi-Plattform Features (Deep Linking, Dark Mode, Gamification)
- Infrastruktur-Setups (Kubernetes, Docker Compose, Docusaurus)

**Root Cause:** Der 60s-Planner-Cap und der 80%-Elapsed-Guard sind zwar implementiert, greifen aber nicht ausreichend. Die Zero-Step-Rate ist bei 94% geblieben — die Fixes vom 25.03. haben noch keinen messbaren Impact.

### 5.2 Step Failures
8 der letzten 50 Tasks scheitern an konkreten Steps. Hier liegt das Problem meist bei:
- Gradle/Build-Verifikation (fehlende SDK/Tooling)
- Komplexer Kotlin/Android Code der nicht kompiliert
- Steps mit zu großem Scope (>100 Zeilen, >3 Dateien)

### 5.3 Zombie Tasks
17 Tasks mit 5+ Failures, 151 verschwendete Worker-Slots. Die Blocklist existiert, scheint aber nicht vollständig durchgesetzt zu werden.

---

## 6. Sind die bisherigen Tasks umsetzbar?

### Umsetzbar (Approved im codex-agent-system):
- **"Improve first-pass success rate"** — JA, umsetzbar. First-Pass liegt bei 55%, es gibt klare Hebel (Task-Scope begrenzen, Planner-Prompts verbessern).
- **"Break retry churn"** — JA, umsetzbar. Erfordert striktere Non-Retryable Guards und Cooldown-Enforcement.

### Nicht umsetzbar ohne Modifikation:
- **Pending: "Improve retry failure classification coverage"** — Nur bedingt umsetzbar. Coverage liegt bei 87%, die restlichen 13% sind Edge Cases die manuelles Debugging brauchen.

### Superheld-Tasks — Kategorisierung:
- ~30% der Tasks sind umsetzbar (Docs, Config, leichtgewichtige Features)
- ~20% könnten mit reduziertem Scope umsetzbar werden
- ~50% scheitern systematisch an Timeouts und sollten umstrukturiert oder pausiert werden

---

## 7. Empfohlene Modifikationen

### 7.1 System-Konfiguration (Priorität: HOCH)

**A) Timeout-Budget erhöhen oder Task-Scope reduzieren**
- Der 60s Planner-Cap und 80% Elapsed-Guard sind nicht ausreichend
- Option 1: Timeout-Budget von 600/900s auf 1200s erhöhen für komplexe Tasks
- Option 2 (besser): Tasks vorab in Micro-Tasks splitten (1 Datei, 1 Funktion pro Task)

**B) Registry kompaktieren**
- Superheld-Registry (1.08 MB) sofort archivieren/kompaktieren
- Threshold bei 512 KB, aktuell bei 1.16 MB — Dashboard-Performance leidet

**C) Non-Retryable Guard härten**
- Zero-Step-Timeouts werden immer noch re-queued (Evidenz: 28 in letzten 50)
- Der Guard muss VOR dem Re-Queue greifen, nicht erst beim nächsten Worker-Start

### 7.2 Task-Modifikation (Priorität: HOCH)

**A) Superheld-Tasks: Scope-Reduktion**
- Alle Tasks mit >3 Dateien oder Multi-Plattform-Scope in 2-3 kleinere Tasks splitten
- Beispiel: "Implement comprehensive Android and iOS deep linking for all app screens" → Split in: 1) Android deep linking for main screens, 2) iOS deep linking for main screens, 3) Deep link routing tests

**B) Task-Pausierung für nicht-umsetzbare Tasks**
- Tasks die Gradle/Android SDK benötigen: Shelven bis Docker-Delegate funktioniert
- Alle reinen iOS/SwiftUI Tasks: Shelven (kein Xcode/Swift-Tooling verfügbar)
- Web-Dashboard Tasks (React/Next.js): Nur wenn kein Node-Timeout auftritt

**C) Task-Priorisierung ändern**
- Priorisiere Tasks mit nachgewiesener Erfolgswahrscheinlichkeit: Docs, Config, Backend-Kotlin, Shared-Module ohne Build-Verifikation
- De-priorisiere UI-heavy und Multi-Plattform Tasks

### 7.3 Strategy-Anpassung (Priorität: MITTEL)

- Strategy generiert zu viele ambitionierte Tasks die systematisch scheitern
- Neue Regel: Strategy darf keine Tasks generieren die >3 Dateien oder >100 LOC erfordern
- Strategy soll aus erfolgreichen Tasks lernen, nicht nur aus Failures

---

## 8. Zusammenfassung

| Bereich | Status | Aktion nötig? |
|---|---|---|
| Gesamttrend | ↑ Verbesserung (4% → 28%) | Weiter beobachten |
| Letzte 20 Tasks | ↓ Rückfall auf 15% | JA — Timeout-Welle |
| Learned Rules | 22 Rules, gut codifiziert | Code-Enforcement prüfen |
| Registry Pressure | CRITICAL (1.16 MB) | JA — sofort kompaktieren |
| Retry Churn | HIGH | JA — Guards härten |
| Task-Qualität | 50% nicht umsetzbar | JA — Scope reduzieren |
| Zero-Step-Timeouts | 94% aller Timeouts | JA — Hauptproblem |

**Bottom Line:** Das System verbessert sich langfristig, aber die aktuelle Timeout-Welle (85% Failure-Rate in den letzten 20 Tasks) zeigt, dass die am 25.03. implementierten Fixes noch nicht greifen. Die wichtigsten nächsten Schritte sind: 1) Registry kompaktieren, 2) Non-Retryable Guard für Zero-Step-Timeouts härten, 3) Superheld-Tasks radikal im Scope reduzieren.

---

## Update 2 — Detailanalyse (nachmittags)

### Retry-Failure-Klassifikation (62 analysierte Retries)

| Klassifikation | Anzahl | Anteil |
|---|---|---|
| timeout | 26 | 42% |
| missing_environment | 12 | 19% |
| step_not_completed | 10 | 16% |
| unknown (unklassifiziert) | 8 | 13% |
| review_rejection | 1 | 2% |
| test_failure | 1 | 2% |
| sandbox_restriction | 1 | 2% |
| missing_dependency | 1 | 2% |
| reviewer_indeterminate | 1 | 2% |
| empty_output | 1 | 2% |

**Erkenntnis:** 61% der Retry-Failures sind non-retryable (timeout + missing_environment). Diese hätten nie re-queued werden dürfen. Der Guard ist implementiert, aber die Daten zeigen, dass er historisch nicht durchgängig gegriffen hat. Die 8 verbleibenden "unknown" Klassifikationen (13%) sind das nächste Optimierungsziel.

### Bewertung der aktuellen Fixes

| Fix | Implementiert | Wirkung messbar? |
|---|---|---|
| Planner-Cap 60s | Ja | Nein — Zero-Step-Rate bleibt bei 94% |
| Elapsed-Time-Guard 80% | Ja | Nein — letzte 20 Tasks: 100% Timeouts |
| Zombie-Blocklist | Ja | Teilweise — 17 Zombies blockiert, aber task-127 (5 Attempts) fehlt noch |
| Diagnostic Text Extraction | Ja | Ja — Coverage stieg von ~0% auf 21% (recent: 30%) |
| Non-Retryable Filter in Strategy | Ja | Nicht validierbar — keine neuen Strategy-Runs seit Fix |

### Konkrete nächste Schritte (priorisiert)

1. **task-127 auf Zombie-Liste setzen** — 5 Attempts, persistent failure, verschwendet Slots
2. **Planner-Context-Größe messen** — Wenn der Planner >4000 Token Context bekommt, ist 60s zu knapp. Logging einbauen.
3. **superheld-Tasks ohne Docker pausieren** — CODEX_DOCKER_DELEGATE ist nicht gesetzt, Android/Gradle Tasks scheitern zu 100%
4. **Registry sofort kompaktieren** — superheld-Archiv (1.08 MB) in tasks-archive.json verschieben
5. **Strategy auf "kleine Tasks" umschalten** — Max 3 Dateien, max 100 LOC, max 3 Impl-Steps pro Task
