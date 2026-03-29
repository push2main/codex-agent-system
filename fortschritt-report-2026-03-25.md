# Fortschrittsbericht — Codex Agent System
**Datum:** 25. März 2026 (Update 3 — Abend)

---

## 1. Aktueller Stand (Kennzahlen)

| Metrik | Wert | Vorher (Update 2) | Trend |
|---|---|---|---|
| Gesamte Tasks | 522 | 522 | → |
| Globale Success Rate | 15% | 15% | → stagniert |
| Recent Success Rate (letzte 50) | 28% | 28% | → stabil |
| First-Pass Success Rate | 55% | 55% | → stabil |
| Timeout-Rate | 36% | 36% | → stabil |
| Registry Pressure | 1.17 MB | 1.18 MB | ↘ minimal besser |
| Retry Classification Coverage | 87% | 87% | → gut |
| Learned Rules | 13 | 5 | ↗ stark gewachsen |
| Rule Effectiveness (traced) | 47.8% | 47.8% | → |
| Queue Status | 0 running, 0 queued | — | idle |

## 2. Heutige Task-Ausführungen (detailliert)

### Erfolge heute (9 Tasks)
| Task | Provider | Attempts | Score | Dauer |
|---|---|---|---|---|
| Compose Multiplatform Desktop App | claude | 2 | 3 | 658s |
| Test-Infrastruktur Setup | claude | 1 | 5 | 680s |
| iOS Dashboard SwiftUI | claude | 1 | 5 | 404s |
| Push Notification Adapter Android | codex | 1 | 0 | 403s |
| DSGVO DSAR Generator | codex | 1 | 0 | 345s |
| Clipboard Monitoring Crypto | claude | 1 | 1 | 475s |
| Desktop System Tray Agent | claude | 2 | 4 | 686s |
| Public WiFi Security Checker | codex | 2 | 0 | 590s |
| Social Media Privacy Wizard | claude | 2 | 1 | 836s |

### Fehlschläge heute (25+ Tasks)
Davon **17 Timeouts mit 0 Step Attempts** — der Orchestrator verbringt das gesamte Timeout-Budget mit Planning/Setup und kommt nie zur Implementation. Betroffene Tasks u.a.: Web Onboarding, Incident Feed, Privacy Score Dashboard, Simplified Mode, Kubernetes Manifests, Dark Mode, Secure Family Chat, Network Scanner, Matter/Zigbee.

**Heutige Erfolgsquote: ~26% (9 von ~34)**

## 3. NEU ENTDECKT: Queue-Rehydration-Loop (KRITISCH)

Im `system.log` zeigt sich ein **Endlos-Loop**: Approved Tasks werden in die Queue geladen → sofort als "stale/without actionable registry record" entfernt → im nächsten Zyklus erneut geladen → wieder entfernt. Dieses Muster wiederholt sich alle ~10 Sekunden und betrifft:

- Self-improve Tasks (improve-first-pass, break-retry-churn) für superheld
- Feature-Tasks für codex-agent-system (family-admin, blocked-site flow)

**Ursache:** Queue-Code prüft nach Rehydration, ob der Task einen gültigen Registry-Eintrag hat. Falls nicht, wird er entfernt — aber beim nächsten Poll wird er erneut rehydriert. Es fehlt ein "blacklist after removal"-Mechanismus.

**Impact:** Massiver Error-Spam im Log, CPU-Verschwendung, keine produktive Arbeit auf den betroffenen Lanes.

## 4. Task-Umsetzbarkeit

### Was funktioniert (beibehalten):
- **Kleine, fokussierte Tasks** (1-3 Dateien, klarer Scope): DSAR Generator, Push Adapter, Clipboard Monitor → hohe Erfolgsrate
- **Testing-Kategorie** mit Claude: 80% Success Rate
- **Auth-Kategorie** mit Codex: 40% Success Rate
- **Tasks < 500s Dauer** mit First-Pass: 55% Success

### Was systematisch scheitert (ändern):
- **"Implement X across all platforms"** Tasks: Zu breit, immer Timeout
- **Tasks die npm/Gradle Setup brauchen**: Setup allein sprengt das Budget
- **Web-Dashboard Tasks** (React/Next.js): 0% Erfolgsrate heute
- **0-step-attempt Timeouts**: Planner erzeugt zu komplexe Pläne → nie Implementation

### codex-agent-system Registry (13 Tasks):
- 3 completed, 4 failed, 3 shelved, 2 approved, 1 pending
- Approved: "Improve first-pass success rate" + "Break retry churn" — beide nicht ausgeführt (Queue-Loop)
- Pending: "Improve retry classification coverage" — sollte approved werden

## 5. Bisherige Fortschritte (was gewirkt hat)

1. **Timeout-Retries abgeschafft** → 168 verschwendete Worker-Slots eliminiert
2. **Retry-Klassifikation** von 24% → 87% Coverage verbessert
3. **Learned Rules** von 5 → 13 gewachsen (Learner akkumuliert jetzt korrekt)
4. **Provider-Routing** datenbasiert (claude für testing/UI, codex für general/auth)
5. **Planungsregeln** (max 3 impl steps + 1 verification) implementiert
6. **Recent Success Rate** steigt: 15% → 24% → 28%

## 6. Notwendige Modifikationen

### A. System / Konfiguration

| Prio | Maßnahme | Erwarteter Effekt |
|---|---|---|
| **KRITISCH** | Queue-Rehydration-Loop fixen: nach Removal nicht erneut rehydrieren | Queue stabilisieren, Error-Spam stoppen |
| **HOCH** | 0-step-attempt Timeouts als `plan_too_complex` klassifizieren | Learner bekommt Signal, kein Retry |
| **HOCH** | Registry-Compaction für superheld (1.08 MB → <200 KB) | Dashboard-Performance |
| **MITTEL** | Planner-Prompt: "Wenn >3 Dateien nötig, Task splitten" | Weniger Timeouts |
| **MITTEL** | Learning-Provider von codex (7%) auf claude wechseln | Bessere Learning-Outcomes |
| **NIEDRIG** | Score-Tracking fixen (mehrere SUCCESS mit score: 0) | Qualitätsmessung |

### B. Task-Design

| Prio | Maßnahme | Erwarteter Effekt |
|---|---|---|
| **KRITISCH** | Große Tasks aufbrechen in 2-3 fokussierte Sub-Tasks | +15% Success Rate |
| **HOCH** | Setup-Schritte als eigene Vorgänger-Tasks modellieren | Vermeidet Setup-Timeouts |
| **HOCH** | Keine Tasks für fehlende Plattformen (iOS ohne Xcode) | Eliminiert guaranteed failures |
| **MITTEL** | Web-Dashboard Tasks pausieren oder Timeout auf 1200s erhöhen | Aktuell 0% Erfolg |

## 7. Konkrete nächste Schritte

1. **SOFORT:** Queue-Rehydration-Bug in `multi-queue.sh` fixen
2. **SOFORT:** `compact-registry.sh` für superheld ausführen
3. **SOFORT:** Pending Task "Improve retry failure classification" approven
4. **KURZFRISTIG:** 0-step-timeout Tasks als `plan_too_complex` auto-klassifizieren
5. **KURZFRISTIG:** Superheld-Tasks reviewen, zu breite Tasks splitten
6. **KURZFRISTIG:** Learning-Provider auf claude umstellen
7. **MITTELFRISTIG:** Dynamisches Timeout-Budget (einfach: 420s, komplex: 900s)

## 8. Prognose

| Szenario | Erwartete Recent Success Rate | Zeitrahmen |
|---|---|---|
| Ohne Änderungen | 28-30% (Stagnation) | — |
| Queue-Fix + Compaction (1-2) | 30-33% | sofort |
| + Task-Splitting + Classification (3-5) | 38-42% | 1 Woche |
| + alle 7 Schritte | 45-50% | 2 Wochen |

**Größter Hebel:** Queue-Rehydration-Loop fixen (verhindert aktuell jede Arbeit an den approved Tasks) + Task-Splitting (adressiert die 40%+ Timeout-Rate direkt).

---

*Automatisch generiert von scheduled task "fortschritt-tasks-und-system". Nächster Check empfohlen nach Queue-Fix.*
