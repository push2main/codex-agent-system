const http = require("http");
const https = require("https");
const fs = require("fs");
const fsp = fs.promises;

// Crash diagnostics — log uncaught errors to file before exit
const _crashLogPath = require("path").join(__dirname, "..", "codex-logs", "dashboard-crash.log");
process.on("uncaughtException", (err) => {
  const msg = `[${new Date().toISOString()}] UNCAUGHT EXCEPTION: ${err.stack || err}\n`;
  try { fs.appendFileSync(_crashLogPath, msg); } catch (_) { /* ignore */ }
  console.error(msg);
  process.exit(1);
});
process.on("unhandledRejection", (reason) => {
  const msg = `[${new Date().toISOString()}] UNHANDLED REJECTION: ${reason instanceof Error ? reason.stack : reason}\n`;
  try { fs.appendFileSync(_crashLogPath, msg); } catch (_) { /* ignore */ }
  console.error(msg);
  process.exit(1);
});
const net = require("net");
const os = require("os");
const path = require("path");
const crypto = require("crypto");

const ROOT = path.resolve(__dirname, "..");
const PORT = Number(process.env.DASHBOARD_PORT || 3000);
const HTTPS_ENABLED = String(process.env.DASHBOARD_HTTPS || "0") === "1";
const PROTOCOL = HTTPS_ENABLED ? "https" : "http";
const TLS_KEY_FILE =
  process.env.DASHBOARD_TLS_KEY_FILE || path.join(ROOT, "codex-logs", "dashboard-tls", "dashboard-key.pem");
const TLS_CERT_FILE =
  process.env.DASHBOARD_TLS_CERT_FILE || path.join(ROOT, "codex-logs", "dashboard-tls", "dashboard-cert.pem");
const QUEUE_LIMIT = Number(process.env.QUEUE_LIMIT || 20);
function envPath(name, fallback) {
  return process.env[name] || fallback;
}

const PATHS = {
  dashboard: __dirname,
  projects: envPath("DASHBOARD_PROJECTS_DIR", path.join(ROOT, "projects")),
  queues: envPath("DASHBOARD_QUEUES_DIR", path.join(ROOT, "queues")),
  agentctlRuntime: envPath("DASHBOARD_AGENTCTL_RUNTIME_FILE", path.join(ROOT, "codex-logs", "agentctl-runtime.env")),
  authFailure: envPath("DASHBOARD_AUTH_FAILURE_FILE", path.join(ROOT, "codex-logs", "codex-auth-failure.json")),
  logs: envPath("DASHBOARD_SYSTEM_LOG_FILE", path.join(ROOT, "codex-logs", "system.log")),
  taskActivity: envPath("DASHBOARD_TASK_ACTIVITY_DIR", path.join(ROOT, "codex-logs", "task-activity")),
  runtimeSessions: envPath("DASHBOARD_RUNTIME_SESSIONS_DIR", path.join(ROOT, "codex-logs", "runtime-sessions")),
  strategyLatest: envPath("DASHBOARD_STRATEGY_LATEST_FILE", path.join(ROOT, "codex-logs", "strategy-latest.json")),
  incidentLog: envPath("DASHBOARD_INCIDENT_LOG_FILE", path.join(ROOT, "codex-memory", "incidents.jsonl")),
  metrics: envPath("DASHBOARD_METRICS_FILE", path.join(ROOT, "codex-learning", "metrics.json")),
  selfImproveRun: envPath("DASHBOARD_SELF_IMPROVE_RUN_FILE", path.join(ROOT, "codex-learning", "self-improve-run.json")),
  alerts: envPath("DASHBOARD_ALERTS_FILE", path.join(ROOT, "codex-learning", "alerts.json")),
  externalSignals: envPath("DASHBOARD_EXTERNAL_SIGNALS_FILE", path.join(ROOT, "codex-learning", "external-signals.json")),
  priority: envPath("DASHBOARD_PRIORITY_FILE", path.join(ROOT, "codex-memory", "priority.json")),
  rules: envPath("DASHBOARD_RULES_FILE", path.join(ROOT, "codex-learning", "rules.md")),
  promptRules: envPath("DASHBOARD_PROMPT_RULES_FILE", path.join(ROOT, "codex-learning", "prompt-rules.md")),
  knowledge: envPath("DASHBOARD_KNOWLEDGE_FILE", path.join(ROOT, "codex-memory", "knowledge.json")),
  taskLog: envPath("DASHBOARD_TASK_LOG_FILE", path.join(ROOT, "codex-memory", "tasks.log")),
  taskRegistry: envPath("DASHBOARD_TASK_REGISTRY_FILE", path.join(ROOT, "codex-memory", "tasks.json")),
  dashboardSettings: envPath("DASHBOARD_SETTINGS_FILE", path.join(ROOT, "codex-memory", "dashboard-settings.json")),
  status: envPath("DASHBOARD_STATUS_FILE", path.join(ROOT, "status.txt")),
};
const DEFAULT_PRIORITY_CATEGORIES = {
  stability: { weight: 1.8, success_rate: 0.76 },
  ui: { weight: 1.35, success_rate: 0.81 },
  performance: { weight: 1.1, success_rate: 0.7 },
  code_quality: { weight: 1.05, success_rate: 0.79 },
};
const DASHBOARD_INCIDENT_LIMIT = 20;
const PRIORITY_LEARNING_LOOKBACK = 6;
const MAX_PRIORITY_LEARNED_ADJUSTMENT = 0.25;
const STRATEGY_PRIMARY_PROJECT = sanitizeProjectName(process.env.STRATEGY_PRIMARY_PROJECT || "codex-agent-system") || "codex-agent-system";
const STRATEGY_RECENT_FAILURE_WINDOW = Math.max(1, safeInteger(process.env.STRATEGY_RECENT_FAILURE_WINDOW, 30));
const STRATEGY_RECENT_FAILURE_COUNT_THRESHOLD = Math.max(
  1,
  safeInteger(process.env.STRATEGY_RECENT_FAILURE_COUNT_THRESHOLD, 10),
);
const STRATEGY_RECENT_FAILURE_RATE_THRESHOLD = clampNumber(
  safeNumber(process.env.STRATEGY_RECENT_FAILURE_RATE_THRESHOLD, 0.2),
  0,
  1,
);
const TRACKED_RUNTIME_HELPER_SCRIPTS = [
  "scripts/lib.sh",
  "scripts/multi-queue.sh",
  "scripts/queue-worker.sh",
  "scripts/strategy-loop.sh",
  "agents/strategy.sh",
  "codex-dashboard/server.js",
];
const PROJECT_MEMORY_FILES = {
  context: path.join(ROOT, "codex-memory", "context.md"),
  decisions: path.join(ROOT, "codex-memory", "decisions.md"),
  learnings: path.join(ROOT, "codex-memory", "learnings.md"),
  knowledge: path.join(ROOT, "codex-memory", "knowledge.json"),
};
const LOW_FIRST_PASS_SUCCESS_RATE_THRESHOLD = 0.5;
const FIRST_PASS_SUCCESS_MIN_SAMPLE_SIZE = 3;
const FIRST_PASS_SUCCESS_RECENT_LOG_WINDOW = 50;
const LOW_COMPLETION_THRESHOLD = LOW_FIRST_PASS_SUCCESS_RATE_THRESHOLD;
const LEGACY_FIRST_PASS_EXPERIMENT_TITLE = "Detect low first-pass success before repeated retries dominate the board";
const LOOP_EFFORT_BOUNDED_EXPERIMENT_ROOT_ID = "strategy::loop-effort";
const LOOP_EFFORT_BOUNDED_EXPERIMENT_TITLE = "Detect bounded loop effort before repeated child-step retries dominate the board";
const LOOP_EFFORT_BOUNDED_EXPERIMENT_METRIC_NAME = "loop_effort_extra_step_attempts";
const LOOP_EFFORT_BOUNDED_EXPERIMENT_EXTRA_STEP_THRESHOLD = 2;
const RETRY_CHURN_ATTEMPT_THRESHOLD = 2;
const STRATEGY_SATURATED_FAILURE_THRESHOLD = 2;
const TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD = 512000;
const SELF_IMPROVE_PAUSE_ESCALATION_SECONDS = Math.max(
  0,
  safeInteger(process.env.SELF_IMPROVE_PAUSE_ESCALATION_SECONDS, 6 * 60 * 60),
);
const LOW_COMPLETION_EXECUTABLE_BUFFER_THRESHOLD = 2;
const ROOT_FAILURE_DEMOTION_THRESHOLD = 3;
const LOW_COMPLETION_QUEUE_DRAIN_STRATEGY_TEMPLATE = "low_completion_queue_drain_followup";
const LOW_COMPLETION_QUEUE_DRAIN_ROOT_ID = "strategy::queue-drain-completion";
const LOW_COMPLETION_QUEUE_DRAIN_TASK_TITLE = "System-work buffer: improve lowest-scoring recent failure";
const PROJECT_SOURCE_LEVELS = new Set(["low", "medium", "high"]);
const PROJECT_SOURCES_MAX_ITEMS = 50;
const DEFAULT_PROJECT_SOURCE_ENTRY = Object.freeze({
  type: "reference",
  relevance: "medium",
  trust: "medium",
});
const QR_URL_DENYLIST_SCHEMES = new Set(["javascript:", "data:", "file:"]);
const QR_URL_ALLOWED_PROTOCOLS = new Set(["http:", "https:"]);
const QR_URL_LOCALHOST_HOSTNAMES = new Set(["localhost", "localhost.localdomain"]);
let taskRegistryMutationQueue = Promise.resolve();
let taskRegistryReadCache = null;
let taskRegistrySummarySnapshotCache = null;
const projectConfigReadCache = new Map();

function expandIpv6(ip) {
  const normalized = String(ip || "").trim().toLowerCase();
  if (!normalized.includes(":")) {
    return null;
  }
  let candidate = normalized;
  if (candidate.includes(".")) {
    const lastColonIndex = candidate.lastIndexOf(":");
    if (lastColonIndex < 0) {
      return null;
    }
    const embeddedIpv4 = candidate.slice(lastColonIndex + 1);
    const octets = embeddedIpv4.split(".").map((part) => Number.parseInt(part, 10));
    if (octets.length !== 4 || octets.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
      return null;
    }
    const high = ((octets[0] << 8) | octets[1]).toString(16);
    const low = ((octets[2] << 8) | octets[3]).toString(16);
    candidate = `${candidate.slice(0, lastColonIndex)}:${high}:${low}`;
  }
  const halves = candidate.split("::");
  if (halves.length > 2) {
    return null;
  }
  const left = halves[0] ? halves[0].split(":").filter(Boolean) : [];
  const right = halves[1] ? halves[1].split(":").filter(Boolean) : [];
  if (halves.length === 1) {
    if (left.length !== 8) {
      return null;
    }
    return left.map((part) => part.padStart(4, "0"));
  }
  const missing = 8 - (left.length + right.length);
  if (missing < 0) {
    return null;
  }
  return [
    ...left.map((part) => part.padStart(4, "0")),
    ...Array.from({ length: missing }, () => "0000"),
    ...right.map((part) => part.padStart(4, "0")),
  ];
}

function isPrivateIpv4Address(hostname) {
  const octets = String(hostname || "")
    .split(".")
    .map((part) => Number.parseInt(part, 10));
  if (octets.length !== 4 || octets.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return false;
  }
  if (octets[0] === 10 || octets[0] === 127) {
    return true;
  }
  if (octets[0] === 0) {
    return true;
  }
  if (octets[0] === 169 && octets[1] === 254) {
    return true;
  }
  if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) {
    return true;
  }
  if (octets[0] === 192 && octets[1] === 168) {
    return true;
  }
  if (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) {
    return true;
  }
  return false;
}

function isPrivateIpv6Address(hostname) {
  const segments = expandIpv6(hostname);
  if (!segments) {
    return false;
  }
  if (segments.join(":") === "0000:0000:0000:0000:0000:0000:0000:0001") {
    return true;
  }
  const first = Number.parseInt(segments[0], 16);
  if (!Number.isInteger(first)) {
    return false;
  }
  if ((first & 0xfe00) === 0xfc00) {
    return true;
  }
  if ((first & 0xffc0) === 0xfe80) {
    return true;
  }
  return false;
}

function isLocalOrPrivateHostname(hostname) {
  const normalizedHostname = String(hostname || "").trim().toLowerCase();
  if (!normalizedHostname) {
    return true;
  }
  if (
    QR_URL_LOCALHOST_HOSTNAMES.has(normalizedHostname)
    || normalizedHostname.endsWith(".localhost")
    || normalizedHostname.endsWith(".local")
  ) {
    return true;
  }
  const ipVersion = net.isIP(normalizedHostname);
  if (ipVersion === 4) {
    return isPrivateIpv4Address(normalizedHostname);
  }
  if (ipVersion === 6) {
    return isPrivateIpv6Address(normalizedHostname);
  }
  return false;
}

function scanQrUrl(rawUrl) {
  if (typeof rawUrl !== "string" || !rawUrl.trim()) {
    return { safe: false, reason: "empty_url", normalizedUrl: null };
  }

  const candidate = rawUrl.trim();
  const colonIndex = candidate.indexOf(":");
  const scheme = colonIndex >= 0 ? candidate.slice(0, colonIndex + 1).toLowerCase() : "";
  if (QR_URL_DENYLIST_SCHEMES.has(scheme)) {
    return { safe: false, reason: "blocked_scheme", normalizedUrl: null };
  }

  let parsed;
  try {
    parsed = new URL(candidate);
  } catch {
    return { safe: false, reason: "invalid_url", normalizedUrl: null };
  }

  if (!QR_URL_ALLOWED_PROTOCOLS.has(parsed.protocol)) {
    return { safe: false, reason: "unsupported_scheme", normalizedUrl: null };
  }

  if (isLocalOrPrivateHostname(parsed.hostname)) {
    return { safe: false, reason: "blocked_host", normalizedUrl: null };
  }

  return { safe: true, reason: "ok", normalizedUrl: parsed.toString() };
}

function runTaskRegistryMutation(work) {
  const run = taskRegistryMutationQueue.then(() => work(), () => work());
  taskRegistryMutationQueue = run.catch(() => {});
  return run;
}

function invalidateTaskRegistryReadCache() {
  taskRegistryReadCache = null;
  taskRegistrySummarySnapshotCache = null;
}

function syncFileSignature(filePath) {
  const resolvedPath = path.resolve(String(filePath || ""));
  try {
    const stat = fs.statSync(resolvedPath);
    return `${resolvedPath}:${stat.mtimeMs}:${stat.size}`;
  } catch {
    return `${resolvedPath}:missing`;
  }
}

function readCachedProjectConfigFile(filePath, fallback = {}) {
  const resolvedPath = path.resolve(String(filePath || ""));
  const signature = syncFileSignature(resolvedPath);
  const cached = projectConfigReadCache.get(resolvedPath);
  if (cached && cached.signature === signature) {
    return cached.value;
  }

  let nextValue = fallback;
  if (!signature.endsWith(":missing")) {
    try {
      const payload = JSON.parse(fs.readFileSync(resolvedPath, "utf8"));
      nextValue = payload && typeof payload === "object" ? payload : fallback;
    } catch {
      nextValue = fallback;
    }
  }

  projectConfigReadCache.set(resolvedPath, {
    signature,
    value: nextValue,
  });
  return nextValue;
}

function ensureFile(filePath, fallback = "") {
  if (!fs.existsSync(filePath)) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, fallback, "utf8");
  }
}

function ensureStructure() {
  fs.mkdirSync(PATHS.projects, { recursive: true });
  fs.mkdirSync(PATHS.queues, { recursive: true });
  ensureFile(PATHS.logs, "");
  ensureFile(PATHS.incidentLog, "");
  ensureFile(
    PATHS.metrics,
    '{\n  "total_tasks": 0,\n  "success_rate": 0,\n  "timeout_failure_records": 0,\n  "timeout_failure_rate": 0,\n  "analysis_runs": 0,\n  "pending_approval_tasks": 0,\n  "approved_tasks": 0,\n  "task_registry_total": 0,\n  "task_registry_payload_bytes": 0,\n  "task_registry_pressure_detected": false,\n  "task_registry_pressure_primary_surface": "",\n  "task_registry_pressure_sources": [],\n  "last_task_score": 0,\n  "manual_recovery_records": 0,\n  "strategy_saturation_detected": false,\n  "saturated_failed_tasks": 0,\n  "retry_churn_detected": false,\n  "queue_starvation_detected": false,\n  "pending_approval_blocked_detected": false,\n  "first_pass_success_rate": 0,\n  "first_pass_success_count": 0,\n  "multi_attempt_resolved_count": 0,\n  "loop_effort_detected": false,\n  "loop_effort_task_count": 0,\n  "loop_effort_extra_step_attempts": 0,\n  "loop_effort_bounded_experiment_detected": false,\n  "loop_effort_bounded_experiment_metric_name": "loop_effort_extra_step_attempts",\n  "loop_effort_bounded_experiment_extra_step_threshold": 2,\n  "loop_effort_bounded_experiment_message": "Bounded loop effort experiment inactive because loop_effort_extra_step_attempts is below 2.",\n  "external_signal_status": "missing",\n  "external_signal_count": 0,\n  "fresh_external_signal_count": 0,\n  "external_signal_error_count": 0,\n  "external_signal_updated_at": "",\n  "latest_external_signal_source": "",\n  "latest_external_signal_title": "",\n  "latest_external_signal_url": "",\n  "latest_external_signal_published_at": ""\n}\n',
  );
  ensureFile(
    PATHS.alerts,
    '{\n  "updated_at": "",\n  "project_id": "",\n  "alert_count": 0,\n  "active": false,\n  "alerts": []\n}\n',
  );
  ensureFile(
    PATHS.externalSignals,
    '{\n  "updated_at": "",\n  "source_count": 0,\n  "signal_count": 0,\n  "signals": [],\n  "errors": []\n}\n',
  );
  ensureFile(PATHS.priority, `${JSON.stringify({ categories: DEFAULT_PRIORITY_CATEGORIES }, null, 2)}\n`);
  ensureFile(PATHS.rules, "# Learned Rules\n\n");
  ensureFile(PATHS.taskLog, "");
  ensureFile(PATHS.taskRegistry, '{\n  "tasks": []\n}\n');
  ensureFile(PATHS.dashboardSettings, '{\n  "approval_mode": "manual",\n  "updated_at": ""\n}\n');
  ensureFile(
    PATHS.status,
    "state=idle\nproject=\ntask=\nlast_result=NONE\nnote=Dashboard initialized\nupdated_at=\n",
  );
}

function formatLogLine(agent, level, message) {
  return `[${new Date().toISOString()}] [${agent}] ${level}: ${message}\n`;
}

function isStructuredLogLine(line) {
  return /^\[\d{4}-\d{2}-\d{2}T.*Z\] \[[^\]]+\] (INFO|WARN|ERROR): /.test(String(line || ""));
}

function nowUtc() {
  return new Date().toISOString();
}

function defaultIndicatorTrafficLight() {
  return "yellow";
}

function normalizeIndicatorTrafficLight(rawValue, keyHint = "") {
  const normalizedHint = String(keyHint || "").trim().toLowerCase();
  const redHint = /(fail|error|critical|blocked|unsafe|saturat|starvation|churn|alert|risk|breach|deny|expired)/;
  const yellowHint = /(stale|warn|missing|pending|unknown|degrad|review|attention|drift|partial)/;

  if (rawValue == null) {
    return defaultIndicatorTrafficLight();
  }

  if (Array.isArray(rawValue)) {
    for (const entry of rawValue) {
      const normalized = normalizeIndicatorTrafficLight(entry, normalizedHint);
      if (normalized === "red") {
        return "red";
      }
      if (normalized === "yellow") {
        return "yellow";
      }
    }
    return rawValue.length ? "green" : defaultIndicatorTrafficLight();
  }

  if (typeof rawValue === "object") {
    const indicator = rawValue;
    const candidateEntries = [
      ["traffic_light", indicator.traffic_light],
      ["color", indicator.color],
      ["severity", indicator.severity],
      ["status", indicator.status],
      ["state", indicator.state],
      ["health", indicator.health],
      ["auth_status", indicator.auth_status],
      ["external_signal_status", indicator.external_signal_status],
      ["failure", indicator.failure],
      ["failed", indicator.failed],
      ["error", indicator.error],
      ["blocked", indicator.blocked],
      ["stale", indicator.stale],
      ["warning", indicator.warning],
      ["warn", indicator.warn],
      ["detected", indicator.detected],
      ["score", indicator.score],
      ["value", indicator.value],
    ];
    for (const [candidateHint, candidateValue] of candidateEntries) {
      if (candidateValue === undefined) {
        continue;
      }
      const normalized = normalizeIndicatorTrafficLight(candidateValue, candidateHint);
      if (normalized === "red") {
        return "red";
      }
      if (normalized === "yellow") {
        return "yellow";
      }
      if (normalized === "green") {
        return "green";
      }
    }
    return defaultIndicatorTrafficLight();
  }

  if (typeof rawValue === "boolean") {
    if (redHint.test(normalizedHint)) {
      return rawValue ? "red" : "green";
    }
    if (yellowHint.test(normalizedHint)) {
      return rawValue ? "yellow" : "green";
    }
    return rawValue ? "red" : "green";
  }

  if (typeof rawValue === "number") {
    if (!Number.isFinite(rawValue)) {
      return defaultIndicatorTrafficLight();
    }
    if (rawValue >= 0.75) {
      return "green";
    }
    if (rawValue >= 0.4) {
      return "yellow";
    }
    return "red";
  }

  if (typeof rawValue === "string") {
    const normalized = rawValue.trim().toLowerCase();
    if (!normalized) {
      return defaultIndicatorTrafficLight();
    }
    if (["green", "healthy", "ok", "pass", "passed", "success", "succeeded", "safe", "fresh"].includes(normalized)) {
      return "green";
    }
    if (
      [
        "yellow",
        "warning",
        "warn",
        "stale",
        "missing",
        "unknown",
        "pending",
        "degraded",
        "recovered",
        "needs_review",
        "needs_attention",
      ].includes(normalized)
    ) {
      return "yellow";
    }
    if (
      [
        "red",
        "critical",
        "error",
        "failed",
        "failure",
        "blocked",
        "unhealthy",
        "offline",
        "denied",
      ].includes(normalized)
    ) {
      return "red";
    }
    if (normalized === "true" || normalized === "false") {
      return normalizeIndicatorTrafficLight(normalized === "true", normalizedHint);
    }
    const numericValue = Number(normalized);
    if (!Number.isNaN(numericValue)) {
      return normalizeIndicatorTrafficLight(numericValue, normalizedHint);
    }
    if (redHint.test(normalized)) {
      return "red";
    }
    if (yellowHint.test(normalized)) {
      return "yellow";
    }
  }

  return defaultIndicatorTrafficLight();
}

function projectMetadataPath(project) {
  const projectKey = sanitizeProjectName(project || "") || "codex-agent-system";
  return path.join(PATHS.projects, projectKey, "project.json");
}

function readProjectMetadata(project) {
  return readCachedProjectConfigFile(projectMetadataPath(project), {});
}

function projectTaskRegistryPath(project) {
  const projectKey = sanitizeProjectName(project || "") || "codex-agent-system";
  const metadata = readProjectMetadata(projectKey);
  if (typeof metadata.task_registry_file === "string" && metadata.task_registry_file.trim()) {
    return metadata.task_registry_file.trim();
  }
  return PATHS.taskRegistry;
}

function projectUsesDedicatedTaskRegistry(project) {
  const metadata = readProjectMetadata(project);
  return typeof metadata.task_registry_file === "string" && metadata.task_registry_file.trim().length > 0;
}

function knownProjectKeys() {
  const projects = new Set(["codex-agent-system"]);
  try {
    for (const entry of fs.readdirSync(PATHS.projects, { withFileTypes: true })) {
      if (!entry.isDirectory()) {
        continue;
      }
      const normalized = sanitizeProjectName(entry.name);
      if (normalized) {
        projects.add(normalized);
      }
    }
  } catch {}
  return [...projects];
}

function resolveTaskProject(task, fallbackProject = "codex-agent-system") {
  const queueHandoff =
    task && typeof task === "object" && task.queue_handoff && typeof task.queue_handoff === "object"
      ? task.queue_handoff
      : {};
  const resolvedProject =
    task && typeof task === "object"
      ? task.project || task.target_project || queueHandoff.project || task._source_project
      : "";
  return sanitizeProjectName(resolvedProject || fallbackProject) || "codex-agent-system";
}

function taskRegistryTargets() {
  const seen = new Set();
  const targets = [];
  for (const projectKey of knownProjectKeys()) {
    const filePath = projectTaskRegistryPath(projectKey);
    const dedupeKey = path.resolve(filePath);
    if (seen.has(dedupeKey)) {
      continue;
    }
    seen.add(dedupeKey);
    targets.push({ project: projectKey, filePath });
  }
  return targets;
}

function projectPolicyPath(project) {
  const projectKey = sanitizeProjectName(project || "") || "codex-agent-system";
  const payload = readProjectMetadata(projectKey);
  if (payload && typeof payload.policy_file === "string" && payload.policy_file.trim()) {
    return payload.policy_file.trim();
  }
  return path.join(PATHS.projects, projectKey, "policy.json");
}

function projectSourcesPath(project) {
  const projectKey = sanitizeProjectName(project || "") || "codex-agent-system";
  const payload = readProjectMetadata(projectKey);
  if (payload && typeof payload.sources_file === "string" && payload.sources_file.trim()) {
    return payload.sources_file.trim();
  }
  return path.join(PATHS.projects, projectKey, "sources.json");
}

function projectCraCompliancePath(project) {
  const projectKey = sanitizeProjectName(project || "") || "codex-agent-system";
  const payload = readProjectMetadata(projectKey);
  if (payload && typeof payload.cra_compliance_file === "string" && payload.cra_compliance_file.trim()) {
    return payload.cra_compliance_file.trim();
  }
  if (payload && typeof payload.workspace === "string" && payload.workspace.trim()) {
    return path.join(payload.workspace.trim(), ".codex-agent", "cra-compliance.json");
  }
  return path.join(PATHS.projects, projectKey, ".codex-agent", "cra-compliance.json");
}

function readProjectPolicy(project) {
  const fallback = {
    project: sanitizeProjectName(project || "") || "codex-agent-system",
    risk_profile: "standard",
    auto_approve_allowed: true,
    manual_review_required_keywords: [],
  };
  const payload = readCachedProjectConfigFile(projectPolicyPath(project), fallback);
  return {
    ...fallback,
    ...(payload && typeof payload === "object" ? payload : {}),
    manual_review_required_keywords: Array.isArray(payload?.manual_review_required_keywords)
      ? payload.manual_review_required_keywords.map((value) => String(value || "").trim()).filter(Boolean)
      : [],
  };
}

function safeNumber(value, fallback = 0) {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : fallback;
}

function clampNumber(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function safeInteger(value, fallback = 0) {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? Math.trunc(numeric) : fallback;
}

function dashboardUrls(addresses) {
  const hosts = addresses.length ? addresses : ["localhost"];
  return hosts.map((host) => `${PROTOCOL}://${host}:${PORT}`);
}

function normalizeTask(task) {
  return String(task || "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

function sanitizeProjectName(name) {
  return String(name || "")
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .trim();
}

function sanitizeTaskText(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeProjectSourceLevel(value) {
  const normalized = sanitizeTaskText(value).toLowerCase();
  return PROJECT_SOURCE_LEVELS.has(normalized) ? normalized : "medium";
}

function normalizeProjectSourceDefaults(input) {
  return {
    type: sanitizeTaskText(input?.type || "") || DEFAULT_PROJECT_SOURCE_ENTRY.type,
    relevance: normalizeProjectSourceLevel(input?.relevance),
    trust: normalizeProjectSourceLevel(input?.trust),
  };
}

function normalizeProjectSourceEntry(input, defaults = DEFAULT_PROJECT_SOURCE_ENTRY) {
  const url = sanitizeTaskText(input?.url || "");
  const filePath = sanitizeTaskText(input?.path || "");
  if (!url && !filePath) {
    return null;
  }
  const normalizedDefaults = normalizeProjectSourceDefaults(defaults);
  return {
    url,
    path: filePath,
    type: sanitizeTaskText(input?.type || "") || normalizedDefaults.type,
    relevance:
      input && Object.prototype.hasOwnProperty.call(input, "relevance")
        ? normalizeProjectSourceLevel(input?.relevance)
        : normalizedDefaults.relevance,
    trust:
      input && Object.prototype.hasOwnProperty.call(input, "trust")
        ? normalizeProjectSourceLevel(input?.trust)
        : normalizedDefaults.trust,
  };
}

function normalizeProjectSourcesPayload(project, payload) {
  const projectKey = sanitizeProjectName(project || "") || "codex-agent-system";
  const items = Array.isArray(payload?.sources) ? payload.sources : [];
  const defaults = normalizeProjectSourceDefaults(payload?.defaults);
  const sources = [];
  for (const item of items) {
    const normalized = normalizeProjectSourceEntry(item, defaults);
    if (normalized) {
      sources.push(normalized);
    }
    if (sources.length >= PROJECT_SOURCES_MAX_ITEMS) {
      break;
    }
  }
  return {
    project: projectKey,
    updated_at: typeof payload?.updated_at === "string" ? payload.updated_at : "",
    defaults,
    sources,
  };
}

function normalizeProviderName(value) {
  const normalized = String(value || "")
    .toLowerCase()
    .trim();
  return normalized === "codex" || normalized === "claude" ? normalized : "";
}

function alternateProviderName(value) {
  const normalized = normalizeProviderName(value);
  if (!normalized) {
    return "";
  }
  return normalized === "codex" ? "claude" : "codex";
}

function normalizeApprovalMode(value) {
  const normalized = String(value || "")
    .toLowerCase()
    .trim();
  return normalized === "auto" ? "auto" : "manual";
}

function splitListInput(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeTaskText(entry)).filter(Boolean);
  }
  return String(value || "")
    .split(/\r?\n|,/)
    .map((entry) => sanitizeTaskText(entry))
    .filter(Boolean);
}

function sentenceCase(value) {
  const text = sanitizeTaskText(value);
  if (!text) {
    return "";
  }
  return text.charAt(0).toUpperCase() + text.slice(1);
}

function excerptText(value, limit = 220) {
  const text = sanitizeTaskText(value);
  if (!text || text.length <= limit) {
    return text;
  }
  return `${text.slice(0, Math.max(0, limit - 1)).trimEnd()}…`;
}

function inferTaskCategory(text, availableCategories = []) {
  const normalized = sanitizeTaskText(text).toLowerCase();
  const known = new Set(Array.isArray(availableCategories) ? availableCategories : []);
  const categoryChecks = [
    {
      category: "stability",
      pattern: /\b(stable|stability|retry|recover|recovery|queue|runtime|worker|restart|lease|lock|failure|error|bug|auth|secure|security|audit|governance)\b/,
    },
    {
      category: "ui",
      pattern: /\b(ui|dashboard|board|layout|mobile|iphone|ipad|tablet|card|badge|panel|sidebar|toolbar|view)\b/,
    },
    {
      category: "performance",
      pattern: /\b(performance|latency|fast|faster|cache|load|optimi[sz]e|throughput|render time)\b/,
    },
    {
      category: "code_quality",
      pattern: /\b(clean|cleanup|refactor|shape|consistency|prompt|task|learning|routing|context|metadata|maintain)\b/,
    },
  ];

  for (const entry of categoryChecks) {
    if (known.has(entry.category) && entry.pattern.test(normalized)) {
      return entry.category;
    }
  }
  if (known.has("code_quality")) {
    return "code_quality";
  }
  return availableCategories[0] || "code_quality";
}

function normalizePromptClause(value) {
  return sanitizeTaskText(
    String(value || "")
      .replace(/^[\s>*\-–—•]+/, "")
      .replace(/^\d+[\.\)]\s+/, "")
      .replace(/^(please|pls|need to|we need to|i need to|ich brauche(?: tasks?)?,? die|ich möchte|wir müssen|wir wollen)\s+/i, "")
      .replace(/[.;:,]+$/, ""),
  );
}

function splitPromptIntoTaskTitles(prompt) {
  const normalizedPrompt = String(prompt || "").replace(/\r/g, "\n");
  const rawLines = normalizedPrompt
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean);
  const candidateParts = [];

  for (const rawLine of rawLines) {
    const line = rawLine.replace(/^[\s>*\-–—•]+/, "").replace(/^\d+[\.\)]\s+/, "").trim();
    if (!line) {
      continue;
    }
    const semicolonParts = line.split(/\s*[;|]\s*/).filter(Boolean);
    for (const part of semicolonParts) {
      const sentenceParts = part.split(/(?<=[.!?])\s+(?=[A-Z0-9ÄÖÜ])/).filter(Boolean);
      if (sentenceParts.length > 1) {
        candidateParts.push(...sentenceParts);
      } else {
        candidateParts.push(part);
      }
    }
  }

  let normalizedParts = candidateParts.map(normalizePromptClause).filter((part) => part.length >= 18);

  if (normalizedParts.length <= 1) {
    const base = normalizePromptClause(normalizedPrompt);
    const connectiveParts = base
      .split(/\s+(?:and|und|sowie|plus)\s+/i)
      .map(normalizePromptClause)
      .filter((part) => part.length >= 18);
    if (connectiveParts.length > 1) {
      normalizedParts = connectiveParts;
    } else if (base) {
      normalizedParts = [base];
    }
  }

  if (normalizedParts.length <= 1 && normalizedParts[0] && normalizedParts[0].length >= 80) {
    const summary = excerptText(normalizedParts[0], 110);
    normalizedParts = [
      `Inspect the current implementation and isolate the smallest safe change surface for ${summary}`,
      `Implement the smallest safe improvement for ${summary}`,
      `Verify the result and capture approval-ready completion checks for ${summary}`,
    ];
  }

  const seen = new Set();
  const titles = [];
  for (const part of normalizedParts) {
    const title = sentenceCase(part);
    const key = normalizeTask(title);
    if (!title || seen.has(key)) {
      continue;
    }
    seen.add(key);
    titles.push(title);
    if (titles.length >= 5) {
      break;
    }
  }
  return titles;
}

function validatePromptDerivedTitle(title, prompt) {
  const normalizedTitle = sanitizeTaskText(title);
  const normalizedPrompt = String(prompt || "");
  const metaPrompt = /^(you are|role:|goal:|core principles|system behavior)\b/i.test(
    sanitizeTaskText(normalizedPrompt),
  );
  const metaTailWords = normalizedTitle
    .toLowerCase()
    .replace(/^(analyze|identify|generate|prioritize|review|inspect)\s+/i, "")
    .match(/[a-z0-9]+/g);
  const genericMetaTail =
    Array.isArray(metaTailWords) &&
    metaTailWords.length > 0 &&
    metaTailWords.every((word) =>
      [
        "and",
        "or",
        "the",
        "a",
        "an",
        "its",
        "itself",
        "system",
        "systems",
        "project",
        "projects",
        "connected",
        "weakness",
        "weaknesses",
        "opportunity",
        "opportunities",
        "improvement",
        "improvements",
        "task",
        "tasks",
        "priority",
        "priorities",
        "analysis",
        "work",
        "backlog",
      ].includes(word),
    );
  if (!normalizedTitle) {
    return { ok: false, reason: "Derived task text is empty." };
  }
  if (normalizedTitle.length > 180) {
    return { ok: false, reason: "Derived task is too long to be a safe actionable board item." };
  }
  if (/^(you are|role:|goal:|core principles|system behavior)\b/i.test(normalizedTitle)) {
    return { ok: false, reason: "Derived task still looks like prompt framing instead of an actionable task." };
  }
  if (/(---|#\s|(?:^|\s)\*\s|core principles|system behavior|operate under human supervision)/i.test(normalizedTitle)) {
    return { ok: false, reason: "Derived task still contains prompt-spec formatting or policy text." };
  }
  if (metaPrompt && /^(analyze|identify|generate|prioritize|review|inspect)\b/i.test(normalizedTitle) && genericMetaTail) {
    return {
      ok: false,
      reason: "Derived task is still a generic planning/meta step instead of project-specific executable work.",
    };
  }
  if (/\b\d+$/.test(normalizedTitle) && /\b1[\.\)]\s|\b2[\.\)]\s|\b3[\.\)]\s/.test(normalizedPrompt)) {
    return { ok: false, reason: "Derived task still contains numbered-list spillover from the source prompt." };
  }
  return { ok: true };
}

function splitBroadDerivedTitle(title) {
  const normalizedTitle = sanitizeTaskText(title);
  if (!normalizedTitle) {
    return [];
  }

  const splits = [];
  const normalized = normalizedTitle
    .replace(/\s*,\s*then\s+/gi, "\n")
    .replace(/\s+then\s+/gi, "\n")
    .replace(/\s+and verify\s+/gi, "\nVerify ")
    .replace(/\s+and confirm\s+/gi, "\nConfirm ")
    .replace(/\s+before proceeding:\s+/gi, "\nConfirm ")
    .replace(/\s+before proceeding\s+/gi, "\nConfirm ")
    .replace(/\s*;\s*/g, "\n");

  for (const part of normalized.split(/\n+/)) {
    const candidate = sentenceCase(normalizePromptClause(part));
    if (!candidate || candidate.length < 18) {
      continue;
    }
    splits.push(candidate);
  }

  return splits.length > 1 ? splits : [normalizedTitle];
}

function derivedTaskIntentSource(task) {
  const existingSource = strategyTaskSource(task);
  if (existingSource) {
    return existingSource;
  }
  const template = sanitizeTaskText(task?.strategy_template || task?.strategyTemplate || "");
  if (template === "bounded_failed_step_child") {
    return "strategy_followup";
  }
  if (template === "external_signal_review") {
    return "strategy_external_signal";
  }
  if (template) {
    return "strategy_seed";
  }
  return "dashboard_backlog";
}

function derivedTaskIntentContext(task) {
  const title = sanitizeTaskText(task?.title || "");
  const category = sanitizeTaskText(task?.category || "code_quality") || "code_quality";
  const normalizedIntent = normalizeTaskIntentRecord(task, title, normalizeTaskProject(task), category);
  if (normalizedIntent?.context_hint) {
    return normalizedIntent.context_hint;
  }
  if (/^review external signal:\s*/i.test(title)) {
    return sanitizeTaskText(title.replace(/^review external signal:\s*/i, ""));
  }
  const failureContext = task?.failure_context && typeof task.failure_context === "object" ? task.failure_context : {};
  const executionContext = task?.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const failedStep = sanitizeTaskText(failureContext.failed_step || executionContext.failed_step || "");
  if (failedStep) {
    return excerptText(failedStep, 140);
  }
  return excerptText(task?.reason || task?.experiment || task?.hypothesis || "", 140);
}

function stableTaskShape(shape) {
  if (!shape || typeof shape !== "object") {
    return {};
  }
  const { updated_at: _updatedAt, ...rest } = shape;
  return rest;
}

function taskShapeEquals(left, right) {
  return JSON.stringify(stableTaskShape(left)) === JSON.stringify(stableTaskShape(right));
}

function compactApprovalTitle(title, task = null) {
  const original = sanitizeTaskText(title);
  if (!original) {
    return "";
  }
  const experiment = sanitizeTaskText(task?.experiment || "");
  const combinedRepairSource = `${original} ${experiment}`.toLowerCase();
  const strategyTemplate = sanitizeTaskText(task?.strategy_template || task?.strategyTemplate || "");
  const saturationRecovery =
    task?.saturation_recovery && typeof task.saturation_recovery === "object" ? task.saturation_recovery : null;
  const saturationRecoveryKind = sanitizeTaskText(saturationRecovery?.kind || "");

  if (strategyTemplate === "strategy_saturation_rescue" && saturationRecoveryKind === "replace_saturated_experiment") {
    const replacedTitle = sentenceCase(sanitizeTaskText(saturationRecovery?.replaces_title || ""));
    const replacedCategory =
      sanitizeTaskText(saturationRecovery?.replaces_category || task?.category || "strategy") || "strategy";
    if (replacedTitle) {
      return sanitizeTaskText(
        `Replace ${excerptText(replacedTitle, 88)} with a different bounded experiment`,
      ).slice(0, 140);
    }
    return sanitizeTaskText(
      `Replace saturated ${replacedCategory} experiment with a different bounded task`,
    ).slice(0, 140);
  }

  if (strategyTemplate === "external_signal_review" || /^review external signal:\s*/i.test(original)) {
    const signalLabel =
      sentenceCase(
        derivedTaskIntentContext(task) ||
          original
            .replace(/^review external signal:\s*/i, "")
            .replace(/^check\s+/i, "")
            .replace(/\s+impact on codex-agent-system$/i, ""),
      ) || "external signal";
    return sanitizeTaskText(`Check ${signalLabel} impact on codex-agent-system`);
  }

  if (combinedRepairSource.includes("metric cards") && combinedRepairSource.includes("readiness domains")) {
    return "Add readiness metric cards to the task summary";
  }

  const strategySourceFamily = sanitizeTaskText(
    task?.original_failed_root_id || task?.originalFailedRootId || task?.root_source_task_id || task?.source_task_id || "",
  ).toLowerCase();
  const strategySourceTitle = sanitizeTaskText(task?.source_task_title || task?.sourceTaskTitle || "").toLowerCase();
  const combinedStrategySource = `${strategySourceFamily} ${strategySourceTitle}`.trim();

  if (
    combinedStrategySource.includes("strategy::retry-churn") ||
    strategySourceTitle.includes("retry churn and queue starvation")
  ) {
    return "Make board health detect retry churn and queue starvation";
  }

  if (
    combinedStrategySource.includes("strategy::first-pass-success") ||
    strategySourceTitle.includes("first-pass success")
  ) {
    return "Align persisted first-pass success metrics";
  }

  if (
    combinedStrategySource.includes(LOOP_EFFORT_BOUNDED_EXPERIMENT_ROOT_ID) ||
    strategySourceTitle.includes("bounded loop effort")
  ) {
    return "Align persisted loop effort metrics";
  }

  let compacted = original;
  if (/^execute only this bounded child step next:\s*/i.test(experiment)) {
    compacted = experiment.replace(/^execute only this bounded child step next:\s*/i, "");
  }

  const splitCandidates = splitBroadDerivedTitle(compacted);
  if (splitCandidates.length > 1) {
    compacted = splitCandidates[0];
  }

  compacted = compacted
    .replace(/^In [`][^`]+[`],\s*/i, "")
    .replace(/^In [^,]+,\s*/i, "")
    .replace(/^Verify deterministically that\s+/i, "Verify ")
    .replace(/[`]/g, "");

  if (/append metric cards for the three readiness domains/i.test(compacted)) {
    return "Add readiness metric cards to the task summary";
  }

  compacted = compacted
    .replace(/\busing the existing\b.*$/i, "")
    .replace(/\bsourced from\b.*$/i, "")
    .replace(/\bdo not implement\b.*$/i, "")
    .replace(/\bdo not modify\b.*$/i, "")
    .replace(/\bwithout adding\b.*$/i, "")
    .replace(/\bwithout removing\b.*$/i, "")
    .replace(/\bwith no\b.*$/i, "")
    .replace(/\bthen verify\b.*$/i, "")
    .replace(/\band verify\b.*$/i, "")
    .replace(/\band confirm\b.*$/i, "")
    .replace(/\bbefore retrying\b.*$/i, "")
    .replace(/\s+[—–-]\s+.*$/, "")
    .replace(/[;:,.\-–—]+$/, "");

  compacted = sentenceCase(compacted);
  if (/^Review\b/i.test(compacted)) {
    compacted = compacted.replace(/^Review\b/i, "Check");
  }
  if (/^Inspect\b/i.test(compacted)) {
    compacted = compacted.replace(/^Inspect\b/i, "Document");
  }

  if (compacted.length > 140) {
    const shortened = compacted.split(/(?:[:;,]|\s+\b(?:using|with|from|while|without|where|that)\b)/i)[0].trim();
    if (shortened.length >= 24) {
      compacted = shortened;
    }
  }

  return sanitizeTaskText(compacted).slice(0, 140);
}

function buildTaskShape(input) {
  const title = sanitizeTaskText(input?.title || input?.task || "");
  const category = sanitizeTaskText(input?.category || "code_quality") || "code_quality";
  const taskIntent = input?.task_intent && typeof input.task_intent === "object" ? input.task_intent : {};
  const inheritedTaskShape = input?.task_shape && typeof input.task_shape === "object" ? input.task_shape : {};
  const project = sanitizeProjectName(input?.project || taskIntent.project || "codex-agent-system") || "codex-agent-system";
  const projectPolicy = readProjectPolicy(project);
  const combined = [
    title,
    taskIntent.objective,
    taskIntent.context_hint,
    ...(Array.isArray(taskIntent.constraints) ? taskIntent.constraints : []),
    ...(Array.isArray(taskIntent.success_signals) ? taskIntent.success_signals : []),
  ]
    .map((value) => String(value || "").trim())
    .filter(Boolean)
    .join(" ");
  const combinedLower = combined.toLowerCase();
  const reasons = [];
  const riskFlags = [];

  if (title.length > 140) {
    reasons.push("Task title is too long for a safe queue unit.");
  }
  if (/[`]/.test(title)) {
    reasons.push("Task still embeds implementation detail formatting instead of a compact board title.");
  }
  if (
    /\bthen\b|\band verify\b|\band confirm\b|\bbefore proceeding\b|\bwhile\b|\bwithout adding\b|\bwithout removing\b/.test(
      combinedLower,
    )
  ) {
    reasons.push("Task still combines implementation and verification or multiple execution phases.");
  }
  if ((title.match(/,/g) || []).length >= 2 && title.length > 90) {
    reasons.push("Task title still contains multiple comma-delimited scopes.");
  }
  if (/^(analyze|identify|generate|prioritize|review|inspect)\b/i.test(title) && title.split(/\s+/).length <= 8) {
    reasons.push("Task is still phrased as a broad meta step instead of a bounded implementation unit.");
  }

  function defaultVerificationCommandForProject(projectName, taskCategory, combinedTextLower) {
    const isUiLike =
      /\b(dashboard|ui|iphone|ipad|tablet|mobile|playwright|screenshot)\b/.test(combinedTextLower) ||
      taskCategory === "ui";
    if (!isUiLike) {
      return "";
    }
    if (projectName !== "codex-agent-system") {
      const metadata = readProjectMetadata(projectName);
      const workspace = typeof metadata?.workspace === "string" ? metadata.workspace.trim() : "";
      if (workspace) {
        const localPlaywrightScript = path.join(workspace, "scripts", "run-playwright-docker.sh");
        const localScreenshotTest = path.join(workspace, "tests", "dashboard-screenshot-verification.sh");
        if (fs.existsSync(localPlaywrightScript) && fs.existsSync(localScreenshotTest)) {
          return "bash scripts/run-playwright-docker.sh bash tests/dashboard-screenshot-verification.sh";
        }
        const localBaselineVerify = path.join(workspace, "scripts", "verify-baseline.sh");
        if (fs.existsSync(localBaselineVerify)) {
          return "bash scripts/verify-baseline.sh";
        }
      }
      return "";
    }
    return "bash scripts/run-playwright-docker.sh bash tests/dashboard-screenshot-verification.sh";
  }

  let verificationCommand = sanitizeTaskText(input?.verificationCommand || input?.verification_command || "");
  if (!verificationCommand) {
    verificationCommand = defaultVerificationCommandForProject(project, category, combinedLower);
  }

  const matchedManualReviewKeywords = projectPolicy.manual_review_required_keywords.filter((keyword) =>
    combinedLower.includes(String(keyword || "").trim().toLowerCase()),
  );
  if (matchedManualReviewKeywords.length > 0) {
    riskFlags.push(...matchedManualReviewKeywords);
  }
  const manualReviewRequired = projectPolicy.auto_approve_allowed === false || matchedManualReviewKeywords.length > 0;
  const editableFiles = splitListInput(input?.editableFiles || input?.editable_files || taskIntent.affected_files);
  const frozenFiles = splitListInput(input?.frozenFiles || input?.frozen_files);
  const playbook = sanitizeTaskText(
    input?.playbook || input?.strategy_playbook || inheritedTaskShape.playbook || "",
  );
  const family = sanitizeTaskText(
    input?.family || input?.task_family || inheritedTaskShape.family || "",
  );

  return {
    approval_ready: reasons.length === 0,
    requires_split: reasons.length > 0,
    reasons,
    manual_review_required: manualReviewRequired,
    risk_profile: String(projectPolicy.risk_profile || "standard").trim() || "standard",
    risk_flags: [...new Set(riskFlags)],
    editable_files: editableFiles,
    frozen_files: frozenFiles,
    ...(family ? { family } : {}),
    ...(playbook ? { playbook } : {}),
    verification_command: verificationCommand,
    updated_at: nowUtc(),
  };
}

function normalizeTaskIntentInput(input, project, title, category) {
  return {
    source: sanitizeTaskText(input.taskIntentSource || input.task_intent_source || "dashboard_backlog") || "dashboard_backlog",
    objective: title,
    project,
    category,
    context_hint: sanitizeTaskText(input.contextHint || input.context_hint || ""),
    constraints: splitListInput(input.constraints),
    success_signals: splitListInput(input.successCriteria || input.success_criteria || input.successSignals || input.success_signals),
    affected_files: splitListInput(input.affectedFiles || input.affected_files),
  };
}

function normalizeTaskIntentRecord(task, title, project, category) {
  const queueHandoff = task.queue_handoff && typeof task.queue_handoff === "object" ? task.queue_handoff : null;
  const queueTaskIntent =
    queueHandoff && queueHandoff.task_intent && typeof queueHandoff.task_intent === "object"
      ? queueHandoff.task_intent
      : null;
  const taskTaskIntent = task.task_intent && typeof task.task_intent === "object" ? task.task_intent : null;
  const sourceTaskIntent =
    taskTaskIntent || queueTaskIntent || queueHandoff
      ? {
          ...(queueTaskIntent || {}),
          ...(taskTaskIntent || {}),
        }
      : null;
  if (!sourceTaskIntent && !queueHandoff) {
    return null;
  }
  const fallbackObjective = sanitizeTaskText(queueHandoff?.task || title);
  const fallbackProject = sanitizeProjectName(queueHandoff?.project || project) || "codex-agent-system";
  const fallbackCategory = sanitizeTaskText(category) || "code_quality";
  const normalizedObjective = sanitizeTaskText(sourceTaskIntent?.objective || fallbackObjective) || fallbackObjective;
  return {
    source: sanitizeTaskText(sourceTaskIntent?.source || "dashboard_backlog") || "dashboard_backlog",
    objective: normalizedObjective,
    project: sanitizeProjectName(sourceTaskIntent?.project || fallbackProject) || "codex-agent-system",
    category: sanitizeTaskText(sourceTaskIntent?.category || fallbackCategory) || fallbackCategory,
    context_hint: sanitizeTaskText(sourceTaskIntent?.context_hint || sourceTaskIntent?.contextHint || ""),
    constraints: splitListInput(sourceTaskIntent?.constraints),
    success_signals: splitListInput(sourceTaskIntent?.success_signals || sourceTaskIntent?.successSignals),
    affected_files: splitListInput(sourceTaskIntent?.affected_files || sourceTaskIntent?.affectedFiles),
  };
}

function derivePendingApprovalTaskIntent(task, title, project, category) {
  const derivedSource = derivedTaskIntentSource(task);
  const saturationRecovery =
    task?.saturation_recovery && typeof task.saturation_recovery === "object" ? task.saturation_recovery : null;
  const saturationRecoveryKind = sanitizeTaskText(saturationRecovery?.kind || "");
  const saturationRecoveryTitle = sanitizeTaskText(saturationRecovery?.replaces_title || "");
  const saturationRecoveryCategory =
    sanitizeTaskText(saturationRecovery?.replaces_category || category || "code_quality") || "code_quality";
  const saturationRecoveryCurrentTitle = sanitizeTaskText(title || taskExecutionText(task));
  const genericSaturationReplacement =
    /^replace\b/i.test(saturationRecoveryCurrentTitle) && /\bdifferent bounded experiment\b/i.test(saturationRecoveryCurrentTitle);
  const saturationRecoveryContextHint =
    derivedSource === "strategy_saturation" && saturationRecoveryKind === "replace_saturated_experiment"
      ? saturationRecoveryTitle
        ? genericSaturationReplacement
          ? `Replace saturated experiment: ${excerptText(saturationRecoveryTitle, 120)}`
          : `Derived from saturated experiment: ${excerptText(saturationRecoveryTitle, 120)}`
        : `Replace the saturated ${saturationRecoveryCategory} experiment with a different bounded follow-up.`
      : "";
  const normalizedIntent = normalizeTaskIntentRecord(task, title, project, category);
  if (normalizedIntent) {
    return saturationRecoveryContextHint ? { ...normalizedIntent, context_hint: saturationRecoveryContextHint } : normalizedIntent;
  }

  if (!derivedSource.startsWith("strategy_")) {
    return null;
  }

  const objective = sanitizeTaskText(title || taskExecutionText(task));
  if (!objective) {
    return null;
  }

  let contextHint = derivedTaskIntentContext(task);
  if (saturationRecoveryContextHint) {
    contextHint = saturationRecoveryContextHint;
  }

  return {
    source: derivedSource,
    objective,
    project: sanitizeProjectName(project) || "codex-agent-system",
    category: sanitizeTaskText(category) || "code_quality",
    context_hint: contextHint,
    constraints: [],
    success_signals: [],
    affected_files: [],
  };
}

function deriveTimeoutEnterpriseGuidance(tasks, project) {
  const statusRank = {
    completed: 4,
    failed: 3,
    running: 2,
    approved: 2,
    pending_approval: 1,
  };
  let selected = null;
  let selectedRank = null;

  for (const [index, task] of (Array.isArray(tasks) ? tasks : []).entries()) {
    if (!task || typeof task !== "object") {
      continue;
    }
    if (normalizeTaskProject(task) !== project) {
      continue;
    }
    if (sanitizeTaskText(task.strategy_template || task.strategyTemplate || "") !== "enterprise_timeout_stability") {
      continue;
    }

    const taskIntent = task.task_intent && typeof task.task_intent === "object" ? task.task_intent : {};
    const timeoutLearning =
      task.timeout_failure_learning && typeof task.timeout_failure_learning === "object" ? task.timeout_failure_learning : {};
    const contextHint = sanitizeTaskText(taskIntent.context_hint || taskIntent.contextHint || "");
    const constraints = splitListInput(taskIntent.constraints);
    const successSignals = splitListInput(taskIntent.success_signals || taskIntent.successSignals);
    const affectedFiles = splitListInput(taskIntent.affected_files || taskIntent.affectedFiles);
    if (
      !(
        (contextHint && normalizeTask(contextHint) !== normalizeTask("Observed queue timeout pressure")) ||
        constraints.length ||
        successSignals.length ||
        affectedFiles.length ||
        sanitizeTaskText(timeoutLearning.observed_example_project || "") ||
        sanitizeTaskText(timeoutLearning.observed_example_lane || "") ||
        sanitizeTaskText(timeoutLearning.observed_example_task || "")
      )
    ) {
      continue;
    }

    const rank = [
      statusRank[String(task.status || "").trim().toLowerCase()] || 0,
      String(task.updated_at || ""),
      String(task.created_at || ""),
      index,
    ];
    if (!selectedRank || rank.join("|") > selectedRank.join("|")) {
      selected = task;
      selectedRank = rank;
    }
  }

  const guidance = {
    context_hint: "Observed queue timeout pressure",
    constraints: [
      "Touch only one timeout-prone queue or orchestration path surfaced by the current timeout evidence.",
      "Do not change retry limits, queue worker counts, or broad strategy seeding behavior.",
    ],
    success_signals: [
      "The chosen timeout-prone path is narrowed or reconciled without introducing another generic timeout classification.",
      "A focused timeout-specific regression test proves the behavior deterministically.",
    ],
    affected_files: [],
    observed_example_project: "",
    observed_example_lane: "",
    observed_example_task: "",
  };
  if (!selected || typeof selected !== "object") {
    return guidance;
  }

  const taskIntent = selected.task_intent && typeof selected.task_intent === "object" ? selected.task_intent : {};
  const timeoutLearning =
    selected.timeout_failure_learning && typeof selected.timeout_failure_learning === "object"
      ? selected.timeout_failure_learning
      : {};
  let contextHint = sanitizeTaskText(taskIntent.context_hint || taskIntent.contextHint || "");
  const observedProject = sanitizeTaskText(timeoutLearning.observed_example_project || "");
  const observedLane = sanitizeTaskText(timeoutLearning.observed_example_lane || "");
  const observedTask = sanitizeTaskText(timeoutLearning.observed_example_task || "");
  if (!contextHint || normalizeTask(contextHint) === normalizeTask("Observed queue timeout pressure")) {
    const exampleParts = [];
    if (observedLane) {
      exampleParts.push(observedLane);
    }
    if (observedProject) {
      exampleParts.push(observedProject);
    }
    const exampleScope = exampleParts.join(" on ");
    if (exampleScope && observedTask) {
      contextHint = `Most recent unresolved timeout: ${exampleScope} task \`${observedTask}\`. Focus on one bounded timeout-reduction path from that example.`;
    } else if (observedProject && observedTask) {
      contextHint = `Most recent unresolved timeout in ${observedProject}: \`${observedTask}\`. Focus on one bounded timeout-reduction path from that example.`;
    } else if (observedTask) {
      contextHint = `Most recent unresolved timeout task: \`${observedTask}\`. Focus on one bounded timeout-reduction path from that example.`;
    }
  }

  if (contextHint) {
    guidance.context_hint = contextHint;
  }
  if (splitListInput(taskIntent.constraints).length > 0) {
    guidance.constraints = splitListInput(taskIntent.constraints);
  }
  if (splitListInput(taskIntent.success_signals || taskIntent.successSignals).length > 0) {
    guidance.success_signals = splitListInput(taskIntent.success_signals || taskIntent.successSignals);
  }
  if (splitListInput(taskIntent.affected_files || taskIntent.affectedFiles).length > 0) {
    guidance.affected_files = splitListInput(taskIntent.affected_files || taskIntent.affectedFiles);
  }
  guidance.observed_example_project = observedProject;
  guidance.observed_example_lane = observedLane;
  guidance.observed_example_task = observedTask;
  return guidance;
}

function taskTitleConflicts(tasks, taskId, project, title) {
  const titleKey = normalizeTask(title);
  if (!titleKey) {
    return false;
  }
  return (Array.isArray(tasks) ? tasks : []).some((task) => {
    if (!task || typeof task !== "object") {
      return false;
    }
    if (String(task.id || "").trim() === taskId) {
      return false;
    }
    const status = String(task.status || "").trim().toLowerCase();
    if (!["pending_approval", "approved", "running"].includes(status)) {
      return false;
    }
    if (normalizeTaskProject(task) !== project) {
      return false;
    }
    return normalizeTask(taskExecutionText(task)) === titleKey;
  });
}

function deriveSaturationRecoveryMetadata(task, tasks) {
  if (!task || typeof task !== "object") {
    return null;
  }
  const strategyTemplate = sanitizeTaskText(task.strategy_template || task.strategyTemplate || "");
  const sourceTaskId = sanitizeTaskText(task.source_task_id || task.sourceTaskId || "");
  if (strategyTemplate !== "strategy_saturation_rescue" && sourceTaskId !== "strategy::saturation-recovery") {
    return null;
  }

  const existing =
    task.saturation_recovery && typeof task.saturation_recovery === "object" ? task.saturation_recovery : null;
  if (existing) {
    const normalized = {
      kind: sanitizeTaskText(existing.kind || ""),
      replaces_task_id: sanitizeTaskText(existing.replaces_task_id || ""),
      replaces_title: sanitizeTaskText(existing.replaces_title || ""),
      replaces_strategy_template: sanitizeTaskText(existing.replaces_strategy_template || ""),
      replaces_category: sanitizeTaskText(existing.replaces_category || ""),
    };
    return normalized.kind ||
      normalized.replaces_task_id ||
      normalized.replaces_title ||
      normalized.replaces_strategy_template ||
      normalized.replaces_category
      ? normalized
      : null;
  }

  const reason = String(task.reason || "").trim();
  const quotedMatch = reason.match(/latest saturated failure is [`'"]([^`'"]+)[`'"]\s*\(([^)]+)\)/i);
  const unquotedMatch = quotedMatch ? null : reason.match(/latest saturated failure is ([^(]+?)\s*\(([^)]+)\)/i);
  const parsedTitle = sanitizeTaskText((quotedMatch && quotedMatch[1]) || (unquotedMatch && unquotedMatch[1]) || "");
  const parsedTemplate = sanitizeTaskText((quotedMatch && quotedMatch[2]) || (unquotedMatch && unquotedMatch[2]) || "");
  if (!parsedTitle && !parsedTemplate) {
    return null;
  }

  const project = normalizeTaskProject(task);
  let selectedCandidate = null;
  let selectedRank = "";
  for (const candidate of Array.isArray(tasks) ? tasks : []) {
    if (!candidate || typeof candidate !== "object") {
      continue;
    }
    if (String(candidate.id || "").trim() === String(task.id || "").trim()) {
      continue;
    }
    if (String(candidate.status || "").trim().toLowerCase() !== "failed") {
      continue;
    }
    if (normalizeTaskProject(candidate) !== project) {
      continue;
    }
    const candidateTitle = sanitizeTaskText(taskExecutionText(candidate));
    const candidateTemplate = sanitizeTaskText(candidate.strategy_template || candidate.strategyTemplate || "");
    let score = 0;
    if (parsedTitle && candidateTitle === parsedTitle) {
      score += 4;
    }
    if (parsedTemplate && candidateTemplate === parsedTemplate) {
      score += 2;
    }
    if (score <= 0) {
      continue;
    }
    const rank = `${String(score).padStart(2, "0")}|${String(candidate.updated_at || "")}|${String(candidate.created_at || "")}|${String(candidate.id || "")}`;
    if (!selectedCandidate || rank > selectedRank) {
      selectedCandidate = candidate;
      selectedRank = rank;
    }
  }

  return {
    kind: "replace_saturated_experiment",
    replaces_task_id: sanitizeTaskText(selectedCandidate?.id || ""),
    replaces_title: sanitizeTaskText(selectedCandidate ? taskExecutionText(selectedCandidate) : parsedTitle),
    replaces_strategy_template: sanitizeTaskText(
      selectedCandidate?.strategy_template || selectedCandidate?.strategyTemplate || parsedTemplate,
    ),
    replaces_category:
      sanitizeTaskText(selectedCandidate?.category || task.category || "code_quality") || "code_quality",
  };
}

function findSaturationRecoveryReplacedTask(saturationRecovery, tasks, project) {
  if (!saturationRecovery || typeof saturationRecovery !== "object") {
    return null;
  }

  const replacedTaskId = sanitizeTaskText(saturationRecovery.replaces_task_id || "");
  const replacedTitle = sanitizeTaskText(saturationRecovery.replaces_title || "");
  const replacedTemplate = sanitizeTaskText(saturationRecovery.replaces_strategy_template || "");
  let selectedCandidate = null;
  let selectedRank = "";

  for (const candidate of Array.isArray(tasks) ? tasks : []) {
    if (!candidate || typeof candidate !== "object") {
      continue;
    }
    if (normalizeTaskProject(candidate) !== project) {
      continue;
    }

    const candidateId = sanitizeTaskText(candidate.id || "");
    const candidateTitle = sanitizeTaskText(taskExecutionText(candidate));
    const candidateTemplate = sanitizeTaskText(candidate.strategy_template || candidate.strategyTemplate || "");
    let score = 0;

    if (replacedTaskId && candidateId === replacedTaskId) {
      score += 8;
    }
    if (replacedTitle && candidateTitle === replacedTitle) {
      score += 4;
    }
    if (replacedTemplate && candidateTemplate === replacedTemplate) {
      score += 2;
    }
    if (score <= 0) {
      continue;
    }

    const rank = `${String(score).padStart(2, "0")}|${String(candidate.updated_at || "")}|${String(candidate.created_at || "")}|${candidateId}`;
    if (!selectedCandidate || rank > selectedRank) {
      selectedCandidate = candidate;
      selectedRank = rank;
    }
  }

  return selectedCandidate;
}

function taskTimestamp(task) {
  return sanitizeTaskText(task?.failed_at || task?.updated_at || task?.created_at || "");
}

function taskStrategyDepth(task) {
  const parsed = Number.parseInt(task?.strategy_depth ?? task?.strategyDepth ?? 0, 10);
  return Number.isFinite(parsed) ? parsed : 0;
}

function taskOriginalFailedRootId(task) {
  const failureContext = task?.failure_context && typeof task.failure_context === "object" ? task.failure_context : {};
  const executionContext = task?.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  return sanitizeTaskText(
    task?.original_failed_root_id ||
      task?.originalFailedRootId ||
      failureContext.original_failed_root_id ||
      executionContext.original_failed_root_id ||
      task?.id ||
      "",
  );
}

function taskRootSourceTaskId(task) {
  return sanitizeTaskText(task?.root_source_task_id || task?.rootSourceTaskId || task?.source_task_id || task?.id || "");
}

function failedTaskContextRank(task) {
  const failedStep = saturationRecoveryFailedStep(task);
  if (!failedStep) {
    return 2;
  }
  for (const context of [task?.failure_context, task?.execution_context]) {
    if (!context || typeof context !== "object") {
      continue;
    }
    const source = sanitizeTaskText(context.failed_step_source || "").toLowerCase();
    if (source === "task_intent_backfill") {
      return 1;
    }
    if (source) {
      return 0;
    }
  }
  return 0;
}

function preferredSaturationRecoveryBasisTask(saturatedTask, tasks, project) {
  if (!saturatedTask || typeof saturatedTask !== "object") {
    return null;
  }

  const saturatedTaskId = sanitizeTaskText(saturatedTask.id || "");
  const familyRootId = taskOriginalFailedRootId(saturatedTask) || taskRootSourceTaskId(saturatedTask) || saturatedTaskId;
  if (!familyRootId) {
    return saturatedTask;
  }

  const saturatedDepth = taskStrategyDepth(saturatedTask);
  const saturatedTimestamp = parseTimestampMs(taskTimestamp(saturatedTask)) ?? 0;
  let selectedTask = saturatedTask;
  let selectedRank = [1, failedTaskContextRank(saturatedTask), -saturatedTimestamp, saturatedTaskId];

  for (const candidate of Array.isArray(tasks) ? tasks : []) {
    if (!candidate || typeof candidate !== "object") {
      continue;
    }
    if (normalizeTaskProject(candidate) !== project) {
      continue;
    }
    if (String(candidate.status || "").trim().toLowerCase() !== "failed") {
      continue;
    }
    if (deriveSaturationRecoveryMetadata(candidate, tasks)) {
      continue;
    }

    const candidateId = sanitizeTaskText(candidate.id || "");
    if (!candidateId || candidateId === saturatedTaskId) {
      continue;
    }

    const candidateRoots = new Set([
      taskOriginalFailedRootId(candidate),
      taskRootSourceTaskId(candidate),
      sanitizeTaskText(candidate.source_task_id || ""),
    ]);
    candidateRoots.delete("");
    if (!candidateRoots.has(familyRootId)) {
      continue;
    }

    const candidateDepth = taskStrategyDepth(candidate);
    const candidateTimestamp = parseTimestampMs(taskTimestamp(candidate)) ?? 0;
    const candidateRank = [
      candidateDepth > saturatedDepth ? 0 : 1,
      failedTaskContextRank(candidate),
      -candidateTimestamp,
      candidateId,
    ];
    if (
      candidateRank[0] < selectedRank[0] ||
      (candidateRank[0] === selectedRank[0] && candidateRank[1] < selectedRank[1]) ||
      (candidateRank[0] === selectedRank[0] &&
        candidateRank[1] === selectedRank[1] &&
        candidateRank[2] < selectedRank[2]) ||
      (candidateRank[0] === selectedRank[0] &&
        candidateRank[1] === selectedRank[1] &&
        candidateRank[2] === selectedRank[2] &&
        candidateRank[3] < selectedRank[3])
    ) {
      selectedTask = candidate;
      selectedRank = candidateRank;
    }
  }

  return selectedTask;
}

function saturationRecoveryBasisTask(saturationRecovery, tasks, project) {
  const directReplacedTask = findSaturationRecoveryReplacedTask(saturationRecovery, tasks, project);
  if (!directReplacedTask || typeof directReplacedTask !== "object") {
    return null;
  }
  return preferredSaturationRecoveryBasisTask(directReplacedTask, tasks, project) || directReplacedTask;
}

function saturationRecoveryFailedStep(task) {
  if (!task || typeof task !== "object") {
    return "";
  }
  const failureContext = task.failure_context && typeof task.failure_context === "object" ? task.failure_context : {};
  const executionContext = task.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const failedStep = sanitizeTaskText(failureContext.failed_step || executionContext.failed_step || "");
  if (failedStep) {
    return failedStep.replace(/\s+/g, " ").trim().replace(/[.]$/, "");
  }
  const experiment = String(task.experiment || "").trim();
  const match = experiment.match(
    /Execute only this bounded child step next:\s*(.+?)(?:\.\s*Do not implement later plan steps|$)/i,
  );
  if (!match) {
    return "";
  }
  return sanitizeTaskText(match[1] || "")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/[.]$/, "");
}

function deriveSaturationRecoveryFollowupTitle(task, saturationRecovery, replacedTask) {
  if (!saturationRecovery || typeof saturationRecovery !== "object") {
    return "Choose a different bounded experiment after strategy saturation stalls the board";
  }

  const replacedTitle = sentenceCase(sanitizeTaskText(saturationRecovery.replaces_title || ""));
  const replacementBasisTitle = sanitizeTaskText(taskExecutionText(replacedTask));
  const replacedCategory = sanitizeTaskText(saturationRecovery.replaces_category || task?.category || "strategy") || "strategy";
  const replacedTemplate = sanitizeTaskText(
    replacedTask?.strategy_template || replacedTask?.strategyTemplate || saturationRecovery.replaces_strategy_template || "",
  );
  const failedStep = saturationRecoveryFailedStep(replacedTask);

  if (replacedTemplate === "bounded_failed_step_child" && failedStep) {
    const narrowedMatch = failedStep.match(
      /limit (?:the )?follow-up (?:fix )?(?:strictly )?to (?:the )?(.+?)(?: surfaced by .*?| before .*?| while .*?| using .*?| after .*?|$|[.;])/i,
    );
    if (narrowedMatch && sanitizeTaskText(narrowedMatch[1] || "")) {
      return sanitizeTaskText(`Fix ${excerptText(narrowedMatch[1], 88)}`).slice(0, 140);
    }

    const verifyMatch = failedStep.match(/Run [`'"]?([^`'"]+)[`'"]? as the single deterministic verification command/i);
    if (verifyMatch && replacedTitle) {
      const command = sanitizeTaskText(verifyMatch[1] || "");
      if (command) {
        return sanitizeTaskText(`Verify ${excerptText(replacedTitle, 64)} with \`${excerptText(command, 48)}\``).slice(0, 140);
      }
      return sanitizeTaskText(`Verify ${excerptText(replacedTitle, 72)} with one deterministic command`).slice(0, 140);
    }

    let candidate = failedStep.split(/[.;]/, 1)[0].trim();
    candidate = candidate.replace(/^Execute only this bounded child step next:\s*/i, "");
    if (candidate) {
      if (/^Run\b/i.test(candidate)) {
        if (replacedTitle) {
          return sanitizeTaskText(`Verify ${excerptText(replacedTitle, 72)} with one deterministic command`).slice(0, 140);
        }
        candidate = candidate.replace(/^Run\b/i, "Verify");
      } else if (/^Inspect\b/i.test(candidate)) {
        candidate = candidate.replace(/^Inspect\b/i, "Document");
      } else if (/^Review\b/i.test(candidate)) {
        candidate = candidate.replace(/^Review\b/i, "Check");
      }
      candidate = sanitizeTaskText(candidate.replace(/`/g, ""));
      if (candidate) {
        return excerptText(candidate, 88);
      }
    }
  }

  if (replacementBasisTitle && normalizeTask(replacementBasisTitle) !== normalizeTask(replacedTitle)) {
    return sanitizeTaskText(`Replace ${excerptText(replacementBasisTitle, 88)} with a different bounded experiment`).slice(0, 140);
  }
  if (replacedTitle) {
    return sanitizeTaskText(`Replace ${excerptText(replacedTitle, 88)} with a different bounded experiment`).slice(0, 140);
  }
  return sanitizeTaskText(`Replace saturated ${replacedCategory} experiment with a different bounded task`).slice(0, 140);
}

function deriveSaturationRecoveryContextHint(task, saturationRecovery, replacedTask) {
  const replacedTitle = sentenceCase(sanitizeTaskText(saturationRecovery?.replaces_title || ""));
  const replacementBasisTitle = sanitizeTaskText(taskExecutionText(replacedTask));
  const replacedTemplate = sanitizeTaskText(
    replacedTask?.strategy_template || replacedTask?.strategyTemplate || saturationRecovery?.replaces_strategy_template || "",
  );
  if (replacementBasisTitle && normalizeTask(replacementBasisTitle) !== normalizeTask(replacedTitle)) {
    return `Replace saturated experiment: ${excerptText(replacementBasisTitle, 120)}`;
  }
  if (replacedTitle && replacedTemplate === "bounded_failed_step_child") {
    return `Derived from saturated experiment: ${excerptText(replacedTitle, 120)}`;
  }
  if (replacedTitle) {
    return `Replace saturated experiment: ${excerptText(replacedTitle, 120)}`;
  }
  const replacedCategory = sanitizeTaskText(saturationRecovery?.replaces_category || task?.category || "strategy") || "strategy";
  return `Replace the saturated ${replacedCategory} experiment with a different bounded follow-up.`;
}

function deriveSaturationRecoveryVerificationCommand(task, saturationRecovery, replacedTask) {
  if (!task || typeof task !== "object") {
    return "";
  }
  if (!saturationRecovery || typeof saturationRecovery !== "object") {
    return "";
  }
  if (sanitizeTaskText(saturationRecovery.kind || "") !== "replace_saturated_experiment") {
    return "";
  }

  const existingCommand = sanitizeTaskText(
    replacedTask?.task_shape?.verification_command || replacedTask?.taskShape?.verification_command || "",
  );
  if (existingCommand) {
    return existingCommand;
  }

  const failedStep = saturationRecoveryFailedStep(replacedTask);
  if (!failedStep) {
    return "";
  }
  const verifyMatch = failedStep.match(/Run [`'"]?([^`'"]+)[`'"]? as the single deterministic verification command/i);
  return sanitizeTaskText(verifyMatch?.[1] || "");
}

function preservedTaskVerificationCommand(task) {
  return sanitizeTaskText(task?.task_shape?.verification_command || task?.taskShape?.verification_command || "");
}

function taskExecutionProvider(task) {
  if (!task || typeof task !== "object") {
    return "";
  }
  const execution = task.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext = task.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const failureContext = task.failure_context && typeof task.failure_context === "object" ? task.failure_context : {};
  const providerSelection =
    task.provider_selection && typeof task.provider_selection === "object" ? task.provider_selection : {};
  return normalizeProviderName(
    execution.provider ||
      executionContext.provider ||
      failureContext.provider ||
      task.execution_provider ||
      providerSelection.selected,
  );
}

function deriveSaturationRecoveryProviderSelection(task, tasks) {
  if (!task || typeof task !== "object") {
    return null;
  }

  const saturationRecovery =
    task.saturation_recovery && typeof task.saturation_recovery === "object" ? task.saturation_recovery : null;
  if (sanitizeTaskText(saturationRecovery?.kind || "") !== "replace_saturated_experiment") {
    return null;
  }

  const existingProviderSelection =
    task.provider_selection && typeof task.provider_selection === "object" ? task.provider_selection : {};
  const existingSource = sanitizeTaskText(existingProviderSelection.source || "");
  if (existingSource === "input" || existingSource === "manual_assessment") {
    return null;
  }

  const project = normalizeTaskProject(task);
  const replacedTask = findSaturationRecoveryReplacedTask(saturationRecovery, tasks, project);
  const replacedProvider = taskExecutionProvider(replacedTask);
  const replacementProvider = alternateProviderName(replacedProvider);
  if (!replacementProvider) {
    return null;
  }

  return {
    execution_provider: replacementProvider,
    provider_selection: {
      selected: replacementProvider,
      source: "task_registry",
      reason: `Saturation recovery rerouted this replacement task from ${replacedProvider} to ${replacementProvider} because the replaced experiment already saturated on ${replacedProvider}.`,
    },
  };
}

function repairPendingApprovalTask(task, tasks) {
  if (!task || typeof task !== "object") {
    return { changed: false, task };
  }
  if (String(task.status || "").trim().toLowerCase() !== "pending_approval") {
    return { changed: false, task };
  }

  const saturationRecovery = deriveSaturationRecoveryMetadata(task, tasks);
  const taskForRepair =
    saturationRecovery && JSON.stringify(saturationRecovery) !== JSON.stringify(task.saturation_recovery || null)
      ? {
          ...task,
          saturation_recovery: saturationRecovery,
        }
      : task;
  const saturationRecoveryProvider = deriveSaturationRecoveryProviderSelection(taskForRepair, tasks);
  const project = normalizeTaskProject(taskForRepair);
  const replacedTask = saturationRecovery ? findSaturationRecoveryReplacedTask(saturationRecovery, tasks, project) : null;
  const basisTask = saturationRecovery ? saturationRecoveryBasisTask(saturationRecovery, tasks, project) || replacedTask : replacedTask;
  const saturationRecoveryVerificationCommand = deriveSaturationRecoveryVerificationCommand(
    taskForRepair,
    saturationRecovery,
    basisTask,
  );
  const preservedVerificationCommand = saturationRecoveryVerificationCommand || preservedTaskVerificationCommand(taskForRepair);
  const category = sanitizeTaskText(taskForRepair.category || "code_quality") || "code_quality";
  const currentTitle = taskExecutionText(taskForRepair);
  if (!currentTitle) {
    return { changed: taskForRepair !== task, task: taskForRepair };
  }
  const repairSource = `${currentTitle} ${sanitizeTaskText(taskForRepair.experiment || "")}`.toLowerCase();
  const readinessMetricsTitle = "Add readiness metric cards to the task summary";
  if (
    sanitizeTaskText(taskForRepair.strategy_template || taskForRepair.strategyTemplate || "") === "bounded_failed_step_child" &&
    repairSource.includes("metric cards") &&
    repairSource.includes("readiness domains") &&
    normalizeTask(currentTitle) !== normalizeTask(readinessMetricsTitle) &&
    !taskTitleConflicts(tasks, String(task.id || "").trim(), project, readinessMetricsTitle)
  ) {
    const transitionAt = nowUtc();
    const repairedTitle = readinessMetricsTitle;
    const repairedIntent = {
      source: "strategy_followup",
      objective: repairedTitle,
      project,
      category,
      context_hint: "Bounded follow-up from a broader failed strategy task.",
      constraints: [],
      success_signals: [],
      affected_files: [],
    };
    const nextTask = {
      ...taskForRepair,
      project,
      title: repairedTitle,
      execution_task: repairedTitle,
      ...(saturationRecoveryProvider
        ? {
            execution_provider: saturationRecoveryProvider.execution_provider,
            provider_selection: {
              ...saturationRecoveryProvider.provider_selection,
              updated_at: transitionAt,
            },
          }
        : {}),
      task_intent: repairedIntent,
      task_shape: buildTaskShape({
        title: repairedTitle,
        category,
        task_intent: repairedIntent,
      }),
      updated_at: transitionAt,
    };
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "auto_repair", "pending_approval", "pending_approval", {
        at: transitionAt,
        note: "Task was automatically reshaped into an approval-ready decision before queue handoff.",
        project,
        queueTask: repairedTitle,
      }),
    );
    return { changed: true, task: nextTask, repaired: true };
  }

  const normalizedIntent = derivePendingApprovalTaskIntent(taskForRepair, currentTitle, project, category);
  if (sanitizeTaskText(taskForRepair.strategy_template || taskForRepair.strategyTemplate || "") === "enterprise_timeout_stability") {
    const timeoutGuidance = deriveTimeoutEnterpriseGuidance(tasks, project);
    const repairedIntent = {
      source: sanitizeTaskText(normalizedIntent?.source || derivedTaskIntentSource(taskForRepair) || "strategy_seed") || "strategy_seed",
      objective: sanitizeTaskText(normalizedIntent?.objective || currentTitle) || currentTitle,
      project,
      category,
      context_hint:
        sanitizeTaskText(timeoutGuidance.context_hint || normalizedIntent?.context_hint || normalizedIntent?.contextHint || "") ||
        "Observed queue timeout pressure",
      constraints: Array.isArray(timeoutGuidance.constraints) ? timeoutGuidance.constraints : [],
      success_signals: Array.isArray(timeoutGuidance.success_signals) ? timeoutGuidance.success_signals : [],
      affected_files: Array.isArray(timeoutGuidance.affected_files) ? timeoutGuidance.affected_files : [],
    };
    const existingTimeoutLearning =
      taskForRepair.timeout_failure_learning && typeof taskForRepair.timeout_failure_learning === "object"
        ? taskForRepair.timeout_failure_learning
        : {};
    const repairedTimeoutLearning = {
      ...existingTimeoutLearning,
    };
    let timeoutChanged =
      JSON.stringify(taskForRepair.task_intent || {}) !== JSON.stringify(repairedIntent);
    for (const field of ["observed_example_project", "observed_example_lane", "observed_example_task"]) {
      const value = sanitizeTaskText(timeoutGuidance[field] || "");
      if (value && repairedTimeoutLearning[field] !== value) {
        repairedTimeoutLearning[field] = value;
        timeoutChanged = true;
      }
    }
    if (timeoutChanged) {
      const transitionAt = nowUtc();
      const nextTask = {
        ...taskForRepair,
        project,
        task_intent: repairedIntent,
        timeout_failure_learning: repairedTimeoutLearning,
        task_shape: buildTaskShape({
          title: currentTitle,
          category,
          task_intent: repairedIntent,
          verificationCommand: preservedVerificationCommand,
        }),
        updated_at: transitionAt,
      };
      nextTask.history = appendTaskHistory(
        nextTask,
        buildTaskHistoryEntry(nextTask, "auto_repair", "pending_approval", "pending_approval", {
          at: transitionAt,
          note: "Task was automatically reshaped from prior timeout guidance before queue handoff.",
          project,
          queueTask: currentTitle,
        }),
      );
      return { changed: true, task: nextTask, repaired: true };
    }
  }
  const currentShape = buildTaskShape({
    title: currentTitle,
    category,
    task_intent: normalizedIntent || undefined,
    verificationCommand: preservedVerificationCommand,
  });
  const persistedShape =
    taskForRepair.task_shape &&
    typeof taskForRepair.task_shape === "object" &&
    taskShapeEquals(taskForRepair.task_shape, currentShape)
      ? taskForRepair.task_shape
      : currentShape;

  const repairedTitle =
    saturationRecovery && sanitizeTaskText(saturationRecovery.kind || "") === "replace_saturated_experiment"
      ? deriveSaturationRecoveryFollowupTitle(taskForRepair, saturationRecovery, basisTask)
      : compactApprovalTitle(currentTitle, taskForRepair);
  const repairedContextHint =
    saturationRecovery && sanitizeTaskText(saturationRecovery.kind || "") === "replace_saturated_experiment"
      ? deriveSaturationRecoveryContextHint(taskForRepair, saturationRecovery, basisTask)
      : normalizedIntent?.source === "strategy_followup"
        ? sanitizeTaskText(taskForRepair?.source_task_title || taskForRepair?.sourceTaskTitle || "") ||
          "Bounded follow-up from a broader failed strategy task."
        : normalizedIntent?.context_hint || derivedTaskIntentContext(taskForRepair);
  const repairedIntent =
    repairedTitle && repairedTitle !== currentTitle
      ? {
          source: normalizedIntent?.source || derivedTaskIntentSource(taskForRepair),
          objective: repairedTitle,
          project,
          category,
          context_hint: repairedContextHint,
          constraints: Array.isArray(normalizedIntent?.constraints) ? normalizedIntent.constraints : [],
          success_signals: Array.isArray(normalizedIntent?.success_signals) ? normalizedIntent.success_signals : [],
          affected_files: Array.isArray(normalizedIntent?.affected_files) ? normalizedIntent.affected_files : [],
        }
      : normalizedIntent;
  const repairedShape = repairedTitle
    ? buildTaskShape({
        title: repairedTitle,
        category,
      task_intent: repairedIntent || undefined,
      verificationCommand: preservedVerificationCommand,
    })
    : currentShape;

  const canRepair =
    repairedTitle &&
    normalizeTask(repairedTitle) !== normalizeTask(currentTitle) &&
    repairedShape.approval_ready &&
    !taskTitleConflicts(tasks, String(task.id || "").trim(), project, repairedTitle);

  if (canRepair) {
    const transitionAt = nowUtc();
    const nextTask = {
      ...taskForRepair,
      project,
      title: repairedTitle,
      execution_task: repairedTitle,
      ...(saturationRecoveryProvider
        ? {
            execution_provider: saturationRecoveryProvider.execution_provider,
            provider_selection: {
              ...saturationRecoveryProvider.provider_selection,
              updated_at: transitionAt,
            },
          }
        : {}),
      task_intent: repairedIntent,
      task_shape: repairedShape,
      updated_at: transitionAt,
    };
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "auto_repair", "pending_approval", "pending_approval", {
        at: transitionAt,
        note: "Task was automatically reshaped into an approval-ready decision before queue handoff.",
        project,
        queueTask: repairedTitle,
      }),
    );
    return { changed: true, task: nextTask, repaired: true };
  }

  const hydratedTask = {
    ...taskForRepair,
    project,
    ...(saturationRecoveryProvider
      ? {
          execution_provider: saturationRecoveryProvider.execution_provider,
          provider_selection: {
            ...saturationRecoveryProvider.provider_selection,
            updated_at:
              typeof taskForRepair.provider_selection?.updated_at === "string" &&
              sanitizeTaskText(taskForRepair.provider_selection.updated_at)
                ? taskForRepair.provider_selection.updated_at
                : nowUtc(),
          },
        }
      : {}),
    ...(normalizedIntent ? { task_intent: normalizedIntent } : {}),
    task_shape: persistedShape,
  };
  const changed =
    !taskShapeEquals(hydratedTask.task_shape, task.task_shape) ||
    JSON.stringify(hydratedTask.saturation_recovery || null) !== JSON.stringify(task.saturation_recovery || null) ||
    taskExecutionProvider(hydratedTask) !== taskExecutionProvider(task) ||
    JSON.stringify(
      (hydratedTask.provider_selection && typeof hydratedTask.provider_selection === "object"
        ? {
            selected: sanitizeTaskText(hydratedTask.provider_selection.selected || ""),
            source: sanitizeTaskText(hydratedTask.provider_selection.source || ""),
            reason: sanitizeTaskText(hydratedTask.provider_selection.reason || ""),
          }
        : null),
    ) !==
      JSON.stringify(
        (task.provider_selection && typeof task.provider_selection === "object"
          ? {
              selected: sanitizeTaskText(task.provider_selection.selected || ""),
              source: sanitizeTaskText(task.provider_selection.source || ""),
              reason: sanitizeTaskText(task.provider_selection.reason || ""),
            }
          : null),
      ) ||
    (normalizedIntent && JSON.stringify(normalizedIntent) !== JSON.stringify(task.task_intent || {}));
  return { changed, task: hydratedTask, repaired: false };
}

function taskRequiresHumanApproval(task) {
  if (!task || typeof task !== "object") {
    return false;
  }
  const taskIntentSource = strategyTaskSource(task);
  if (["strategy_seed", "strategy_followup", "strategy_loop"].includes(taskIntentSource)) {
    return true;
  }
  return typeof task.strategy_template === "string" && task.strategy_template.trim().length > 0;
}

function strategyTaskSource(task) {
  if (!task || typeof task !== "object") {
    return "";
  }
  const taskIntent = task.task_intent && typeof task.task_intent === "object" ? task.task_intent : null;
  return String(taskIntent?.source || task.taskIntentSource || task.task_intent_source || "")
    .trim()
    .toLowerCase();
}

function taskBoardScope(task) {
  const status = String(task?.status || "").trim().toLowerCase();
  if (status === "pending_approval") {
    return "pending";
  }
  if (status === "approved") {
    return "approved";
  }
  const source = strategyTaskSource(task);
  if (status === "running" && ["strategy_seed", "strategy_anomaly", "strategy_followup", "strategy_loop"].includes(source)) {
    return "approved";
  }
  return "other";
}

function isSaturableStrategyTask(task) {
  const source = strategyTaskSource(task);
  if (source === "strategy_seed" || source === "strategy_anomaly") {
    return true;
  }
  const strategyTemplate = sanitizeTaskText(task?.strategy_template || task?.strategyTemplate || "");
  const rootSourceTaskId = sanitizeTaskText(task?.root_source_task_id || task?.rootSourceTaskId || task?.source_task_id || "");
  return Boolean(strategyTemplate) && rootSourceTaskId.startsWith("strategy::");
}

function strategySaturationKey(task) {
  if (!isSaturableStrategyTask(task)) {
    return "";
  }
  const project = sanitizeProjectName(task?.project || "codex-agent-system") || "codex-agent-system";
  const title = normalizeTask(taskExecutionText(task));
  const strategyTemplate = sanitizeTaskText(task?.strategy_template || task?.strategyTemplate || "");
  if (!strategyTemplate && !title) {
    return "";
  }
  return `${project}::${strategyTemplate}::${title}`;
}

function buildStrategyFailureSaturationCounts(tasks) {
  const counts = new Map();
  for (const task of Array.isArray(tasks) ? tasks : []) {
    if (!task || typeof task !== "object") {
      continue;
    }
    if (String(task.status || "").trim().toLowerCase() !== "failed") {
      continue;
    }
    const key = strategySaturationKey(task);
    if (!key) {
      continue;
    }
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return counts;
}

function normalizeRelatedSourceTaskIds(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  const normalized = [];
  for (const entry of value) {
    const sourceId = sanitizeTaskText(entry);
    if (sourceId && !normalized.includes(sourceId)) {
      normalized.push(sourceId);
    }
  }
  return normalized;
}

function normalizeDependencyTaskIds(value) {
  const entries = Array.isArray(value)
    ? value
    : typeof value === "string"
      ? value.split(/[\n,]/)
      : [];
  const normalized = [];
  for (const entry of entries) {
    const dependencyId = sanitizeTaskText(entry);
    if (dependencyId && !normalized.includes(dependencyId)) {
      normalized.push(dependencyId);
    }
  }
  return normalized;
}

function buildTaskDependencyState(task, tasksById) {
  const dependsOn = normalizeDependencyTaskIds(task?.depends_on || task?.dependsOn);
  if (!dependsOn.length) {
    return {
      depends_on: [],
      blocked: false,
      satisfied: [],
      unmet: [],
      reason: "",
    };
  }

  const satisfied = [];
  const unmet = [];
  const taskProject = normalizeTaskProject(task);
  for (const dependencyId of dependsOn) {
    const dependencyTask = lookupTaskById(tasksById, dependencyId, taskProject);
    const dependencyStatus = String(dependencyTask?.status || "").trim().toLowerCase();
    if (dependencyStatus === "completed") {
      satisfied.push({
        id: dependencyId,
        status: dependencyStatus,
        title: sanitizeTaskText(dependencyTask?.title || ""),
        project: normalizeTaskProject(dependencyTask),
      });
      continue;
    }
    unmet.push({
      id: dependencyId,
      status: dependencyStatus || "missing",
      title: sanitizeTaskText(dependencyTask?.title || ""),
      project: dependencyTask ? normalizeTaskProject(dependencyTask) : taskProject,
    });
  }

  const blocked = unmet.length > 0;
  let reason = "";
  if (blocked) {
    if (unmet.length === 1) {
      const dependency = unmet[0];
      reason = `Blocked by ${dependency.id} (${dependency.status}).`;
    } else {
      reason = `Blocked by ${unmet.length} unresolved dependencies.`;
    }
  }

  return {
    depends_on: dependsOn,
    blocked,
    satisfied,
    unmet,
    reason,
  };
}

function normalizeStrategyIdentity(task, fallbackTitle = "") {
  const failureContext = task && task.failure_context && typeof task.failure_context === "object" ? task.failure_context : null;
  const taskIntent = task && task.task_intent && typeof task.task_intent === "object" ? task.task_intent : null;
  const taskIntentSource = String(
    taskIntent?.source || task?.taskIntentSource || task?.task_intent_source || "",
  )
    .trim()
    .toLowerCase();
  return {
    is_strategy:
      ["strategy_seed", "strategy_followup", "strategy_loop"].includes(taskIntentSource) ||
      typeof task?.strategy_template === "string" ||
      typeof task?.original_failed_root_id === "string" ||
      typeof failureContext?.failed_step === "string",
    strategy_template: sanitizeTaskText(task?.strategy_template || task?.strategyTemplate || ""),
    original_failed_root_id: sanitizeTaskText(
      task?.original_failed_root_id || task?.originalFailedRootId || failureContext?.original_failed_root_id || "",
    ),
    failed_step: sanitizeTaskText(task?.failed_step || task?.failedStep || failureContext?.failed_step || ""),
    task_key: normalizeTask(fallbackTitle || taskExecutionText(task)),
  };
}

function hasMatchingStrategyIdentity(candidate, existingTask) {
  const existing = normalizeStrategyIdentity(existingTask);
  if (!candidate?.is_strategy || !existing.is_strategy) {
    return false;
  }
  if (
    candidate.strategy_template &&
    candidate.original_failed_root_id &&
    existing.strategy_template === candidate.strategy_template &&
    existing.original_failed_root_id === candidate.original_failed_root_id
  ) {
    return true;
  }
  if (
    candidate.original_failed_root_id &&
    candidate.failed_step &&
    existing.original_failed_root_id === candidate.original_failed_root_id &&
    existing.failed_step === candidate.failed_step
  ) {
    return true;
  }
  if (
    candidate.strategy_template &&
    candidate.failed_step &&
    existing.strategy_template === candidate.strategy_template &&
    existing.failed_step === candidate.failed_step
  ) {
    return true;
  }
  return false;
}

function selectTaskProvider(input, taskIntent) {
  const explicit = normalizeProviderName(input.executionProvider || input.execution_provider || input.provider);
  if (explicit) {
    return {
      selected: explicit,
      source: "input",
      reason: `Provider was selected explicitly from the task payload: ${explicit}.`,
    };
  }

  const corpus = [
    input.title,
    input.task,
    input.reason,
    taskIntent?.objective,
    taskIntent?.context_hint,
    taskIntent?.constraints?.join(" "),
  ]
    .map((value) => String(value || ""))
    .join(" ")
    .toLowerCase();

  if (/(^|\W)(claude|anthropic)(\W|$)/.test(corpus)) {
    return {
      selected: "claude",
      source: "keyword",
      reason: "Task text explicitly references Claude or Anthropic.",
    };
  }

  return {
    selected: "codex",
    source: "default",
    reason: "Default provider is Codex when no explicit Claude hint is present.",
  };
}

function taskSlug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
}

function buildPendingTaskRecord(projectTasks, categories, input) {
  const project = sanitizeProjectName(input.project || input.newProject || "");
  const title = sanitizeTaskText(input.title || input.task || "");
  const strategyIdentity = normalizeStrategyIdentity(input, title);
  const strategyTemplate = strategyIdentity.strategy_template;
  const originalFailedRootId = strategyIdentity.original_failed_root_id;
  const sourceTaskId = sanitizeTaskText(input.sourceTaskId || input.source_task_id || "");
  const rootSourceTaskId = sanitizeTaskText(input.rootSourceTaskId || input.root_source_task_id || "");
  const relatedSourceTaskIds = normalizeRelatedSourceTaskIds(input.relatedSourceTaskIds || input.related_source_task_ids);
  const dependencyTaskIds = normalizeDependencyTaskIds(input.dependsOn || input.depends_on);
  const strategyDepth =
    input.strategyDepth === undefined && input.strategy_depth === undefined
      ? null
      : Math.max(0, safeInteger(input.strategyDepth || input.strategy_depth, 0));
  const historyNote =
    sanitizeTaskText(input.historyNote || "Task was added from the dashboard backlog form.") ||
    "Task was added from the dashboard backlog form.";
  if (!project) {
    return { ok: false, status: 400, error: "Project is required." };
  }
  if (!title) {
    return { ok: false, status: 400, error: "Task is required." };
  }

  // Duplicate blocker note: compare the incoming record's normalized `project` plus normalized task text from
  // `input.title || input.task` against persisted entries resolved through `normalizeTaskProject(task)` and
  // `taskExecutionText(task)`, which currently read `task.project || task.target_project` and
  // `task.execution_task || task.title`. Existing `pending_approval`, `approved`, and `running` statuses are
  // treated as blockers because they are still actionable or not yet fully cleared from board-visible workflow.
  const taskKey = normalizeTask(title);
  const duplicate = (Array.isArray(projectTasks) ? projectTasks : []).find((task) => {
    const status = String(task?.status || "").trim().toLowerCase();
    if (!["pending_approval", "approved", "running"].includes(status)) {
      return false;
    }
    if (normalizeTaskProject(task) !== project) {
      return false;
    }
    if (normalizeTask(taskExecutionText(task)) === taskKey) {
      return true;
    }
    return hasMatchingStrategyIdentity(strategyIdentity, task);
  });
  if (duplicate) {
    return { ok: false, status: 409, error: "Task is already tracked and actionable for this project." };
  }

  // Root failure count demotion: block new strategy follow-ups for root goals
  // that have exceeded the failure threshold.
  if (rootSourceTaskId && ["strategy_followup", "strategy_seed", "strategy_loop"].includes(
    sanitizeTaskText(input.taskIntentSource || input.task_intent_source || "")
  )) {
    const demotion = shouldDemoteRoot(rootSourceTaskId, projectTasks);
    if (demotion.demoted) {
      return {
        ok: false,
        status: 429,
        error: `Root goal "${rootSourceTaskId}" shelved after ${demotion.count} failures (threshold=${demotion.threshold}). No further follow-ups allowed.`,
      };
    }
  }

  const categoryNames = Object.keys(categories || {});
  const requestedCategory = String(input.category || "").trim().toLowerCase();
  const category =
    categoryNames.includes(requestedCategory)
      ? requestedCategory
      : input.inferCategory === true
        ? inferTaskCategory([title, input.reason, input.contextHint, input.context_hint].join(" "), categoryNames)
        : "code_quality";
  const categoryConfig = categories[category] || DEFAULT_PRIORITY_CATEGORIES.code_quality;
  const impact = clampNumber(Math.round(safeNumber(input.impact, 5)), 1, 10);
  const effort = clampNumber(Math.round(safeNumber(input.effort, 3)), 1, 10);
  const confidence = Number(
    clampNumber(safeNumber(input.confidence, categoryConfig.success_rate), 0, 1).toFixed(2),
  );
  const transitionAt = input.transitionAt || nowUtc();
  const taskIntent = normalizeTaskIntentInput(input, project, title, category);
  const providerSelection = selectTaskProvider(input, taskIntent);
  const taskShape = buildTaskShape({
    title,
    category,
    task_intent: taskIntent,
  });
  const nextTask = {
    id: nextTaskRegistryId(projectTasks, project, title),
    title,
    impact,
    effort,
    confidence,
    category,
    project,
    reason: sanitizeTaskText(input.reason || "Added from the dashboard for approval before queue execution."),
    score: taskScore({
      impact,
      effort,
      confidence,
      categoryWeight: safeNumber(categoryConfig.weight, 1),
    }),
    execution_provider: providerSelection.selected,
    provider_selection: {
      ...providerSelection,
      updated_at: transitionAt,
    },
    status: "pending_approval",
    task_intent: taskIntent,
    task_shape: taskShape,
    created_at: transitionAt,
    updated_at: transitionAt,
  };

  if (input.prompt && input.promptMeta && typeof input.promptMeta === "object") {
    nextTask.prompt_intake = {
      source: "dashboard_prompt_intake",
      prompt_excerpt: excerptText(input.prompt, 240),
      index: safeInteger(input.promptMeta.index, 1),
      total: safeInteger(input.promptMeta.total, 1),
      updated_at: transitionAt,
    };
  }

  if (sourceTaskId) {
    nextTask.source_task_id = sourceTaskId;
  }
  if (rootSourceTaskId) {
    nextTask.root_source_task_id = rootSourceTaskId;
  }
  if (originalFailedRootId) {
    nextTask.original_failed_root_id = originalFailedRootId;
  }
  if (strategyTemplate) {
    nextTask.strategy_template = strategyTemplate;
  }
  if (relatedSourceTaskIds.length) {
    nextTask.related_source_task_ids = relatedSourceTaskIds;
  }
  if (dependencyTaskIds.length) {
    nextTask.depends_on = dependencyTaskIds;
  }
  if (strategyDepth !== null) {
    nextTask.strategy_depth = strategyDepth;
  }

  nextTask.history = appendTaskHistory(
    nextTask,
    buildTaskHistoryEntry(nextTask, "create", "", "pending_approval", {
      at: transitionAt,
      note: historyNote,
      project,
      queueTask: title,
    }),
  );

  return { ok: true, task: nextTask };
}

/**
 * Count how many tasks sharing the same root_source_task_id have failed.
 * Used to implement root failure count demotion: when a root goal has
 * accumulated >= ROOT_FAILURE_DEMOTION_THRESHOLD failed attempts, new
 * follow-ups for that root are blocked and the root is marked "shelved".
 */
function countRootFailures(rootSourceTaskId, registryTasks) {
  if (!rootSourceTaskId) return 0;
  const normalizedRoot = sanitizeTaskText(rootSourceTaskId).toLowerCase();
  if (!normalizedRoot) return 0;
  return (Array.isArray(registryTasks) ? registryTasks : []).filter((task) => {
    const status = String(task?.status || "").trim().toLowerCase();
    if (status !== "failed") return false;
    const taskRoot = sanitizeTaskText(
      task?.root_source_task_id || task?.rootSourceTaskId || task?.original_failed_root_id || task?.source_task_id || ""
    ).toLowerCase();
    return taskRoot === normalizedRoot;
  }).length;
}

/**
 * Check if a root goal should be demoted (shelved) because it has
 * exceeded the failure threshold. Returns { demoted, count, threshold }.
 */
function shouldDemoteRoot(rootSourceTaskId, registryTasks) {
  const count = countRootFailures(rootSourceTaskId, registryTasks);
  return {
    demoted: count >= ROOT_FAILURE_DEMOTION_THRESHOLD,
    count,
    threshold: ROOT_FAILURE_DEMOTION_THRESHOLD,
  };
}

async function readPriorityCategories() {
  const payload = await readJsonFile(PATHS.priority, { categories: DEFAULT_PRIORITY_CATEGORIES });
  const rawCategories = payload && typeof payload === "object" ? payload.categories : null;
  const categories = rawCategories && typeof rawCategories === "object" ? rawCategories : DEFAULT_PRIORITY_CATEGORIES;
  const normalized = {};

  for (const [name, config] of Object.entries(categories)) {
    if (!config || typeof config !== "object") {
      continue;
    }
    normalized[String(name)] = {
      weight: safeNumber(config.weight, 1),
      success_rate: clampNumber(safeNumber(config.success_rate, 0.8), 0, 1),
    };
  }

  return Object.keys(normalized).length ? normalized : DEFAULT_PRIORITY_CATEGORIES;
}

function priorityLearningTimestamp(task) {
  return (
    String(task?.updated_at || "").trim() ||
    String(task?.completed_at || "").trim() ||
    String(task?.failed_at || "").trim() ||
    String(task?.success_at || "").trim() ||
    String(task?.approved_at || "").trim() ||
    String(task?.created_at || "").trim()
  );
}

function listRecentCategoryOutcomeTasks(tasks, category, lookback = PRIORITY_LEARNING_LOOKBACK) {
  return (Array.isArray(tasks) ? tasks : [])
    .filter((task) => task && typeof task === "object")
    .filter((task) => String(task.category || "").trim() === String(category || "").trim())
    .filter((task) => {
      const status = String(task.status || "").trim().toLowerCase();
      return status === "completed" || status === "success" || status === "failed";
    })
    .sort((left, right) => priorityLearningTimestamp(right).localeCompare(priorityLearningTimestamp(left)))
    .slice(0, Math.max(1, safeInteger(lookback, PRIORITY_LEARNING_LOOKBACK)));
}

function computePriorityCategoryLearning(config, tasks, category, lookback = PRIORITY_LEARNING_LOOKBACK) {
  const recentTasks = listRecentCategoryOutcomeTasks(tasks, category, lookback);
  if (!recentTasks.length) {
    return null;
  }

  const observedSuccessRate = Number(
    (
      recentTasks.filter((task) => {
        const status = String(task.status || "").trim().toLowerCase();
        return status === "completed" || status === "success";
      }).length /
      recentTasks.length
    ).toFixed(2),
  );
  const predictedConfidence = Number(
    (
      recentTasks.reduce((total, task) => total + clampNumber(safeNumber(task.confidence, config.success_rate), 0, 1), 0) /
      recentTasks.length
    ).toFixed(2),
  );
  const confidenceDrift = Number((observedSuccessRate - predictedConfidence).toFixed(2));
  const learnedAdjustment = Number(
    clampNumber(
      Number(((predictedConfidence - observedSuccessRate) * 0.6).toFixed(2)),
      -MAX_PRIORITY_LEARNED_ADJUSTMENT,
      MAX_PRIORITY_LEARNED_ADJUSTMENT,
    ).toFixed(2),
  );

  return {
    observed_success_rate: observedSuccessRate,
    predicted_confidence: predictedConfidence,
    confidence_drift: confidenceDrift,
    learned_adjustment: learnedAdjustment,
    updated_at: priorityLearningTimestamp(recentTasks[0]),
  };
}

function applyPriorityLearningSnapshot(priorityPayload, tasks, lookback = PRIORITY_LEARNING_LOOKBACK) {
  const sourceCategories =
    priorityPayload && typeof priorityPayload.categories === "object" && priorityPayload.categories
      ? priorityPayload.categories
      : DEFAULT_PRIORITY_CATEGORIES;
  const learnedCategories = {};

  for (const [name, rawConfig] of Object.entries(sourceCategories)) {
    if (!rawConfig || typeof rawConfig !== "object") {
      continue;
    }
    const config = {
      ...rawConfig,
      weight: safeNumber(rawConfig.weight, 1),
      success_rate: clampNumber(safeNumber(rawConfig.success_rate, 0.8), 0, 1),
    };
    const learning = computePriorityCategoryLearning(config, tasks, name, lookback);
    learnedCategories[name] = learning ? { ...config, ...learning } : config;
  }

  return {
    ...priorityPayload,
    categories: learnedCategories,
  };
}

function taskScore({ impact, effort, confidence, categoryWeight }) {
  return Number(((impact * confidence * categoryWeight) / Math.max(effort, 1)).toFixed(2));
}

async function readText(filePath) {
  try {
    return await fsp.readFile(filePath, "utf8");
  } catch {
    return "";
  }
}

function dashboardAssetContentType(filePath) {
  const extension = path.extname(filePath).toLowerCase();
  if (extension === ".css") {
    return "text/css; charset=utf-8";
  }
  if (extension === ".js") {
    return "application/javascript; charset=utf-8";
  }
  if (extension === ".html") {
    return "text/html; charset=utf-8";
  }
  if (extension === ".json") {
    return "application/json; charset=utf-8";
  }
  if (extension === ".png") {
    return "image/png";
  }
  return "application/octet-stream";
}

async function readJsonFile(filePath, fallback) {
  try {
    const raw = await readText(filePath);
    if (!raw.trim()) {
      return fallback;
    }
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

async function readFileModifiedAt(filePath) {
  try {
    const stat = await fsp.stat(filePath);
    return stat?.mtime instanceof Date && Number.isFinite(stat.mtime.getTime())
      ? stat.mtime.toISOString()
      : "";
  } catch {
    return "";
  }
}

function defaultDashboardAlerts() {
  return {
    updated_at: "",
    project_id: "",
    alert_count: 0,
    active: false,
    alerts: [],
  };
}

function defaultCraCompliancePayload(project = "") {
  const projectKey = sanitizeProjectName(project || "");
  return {
    updated_at: "",
    project_id: projectKey || "",
    status: "incomplete",
    missing_artifacts: [],
    incident_summary: {
      severity: "unknown",
      failure_kind: "unknown",
      message: "No incident recorded.",
    },
    supply_chain_controls: {
      spec_present: false,
      policy_present: false,
      task_registry_present: false,
    },
    evidence: [],
  };
}

function normalizeCraCompliancePayload(project, payload) {
  const fallback = defaultCraCompliancePayload(project);
  const incidentSummary =
    payload?.incident_summary && typeof payload.incident_summary === "object" && !Array.isArray(payload.incident_summary)
      ? payload.incident_summary
      : {};
  const supplyChainControls =
    payload?.supply_chain_controls && typeof payload.supply_chain_controls === "object" && !Array.isArray(payload.supply_chain_controls)
      ? payload.supply_chain_controls
      : {};
  return {
    ...fallback,
    ...(payload && typeof payload === "object" ? payload : {}),
    updated_at: typeof payload?.updated_at === "string" ? payload.updated_at : fallback.updated_at,
    project_id: typeof payload?.project_id === "string" && sanitizeProjectName(payload.project_id)
      ? sanitizeProjectName(payload.project_id)
      : fallback.project_id,
    status: sanitizeTaskText(payload?.status || fallback.status) || fallback.status,
    missing_artifacts: Array.isArray(payload?.missing_artifacts)
      ? payload.missing_artifacts.map((entry) => sanitizeTaskText(entry)).filter(Boolean)
      : fallback.missing_artifacts,
    incident_summary: {
      ...fallback.incident_summary,
      severity: sanitizeTaskText(incidentSummary.severity || fallback.incident_summary.severity) || fallback.incident_summary.severity,
      failure_kind:
        sanitizeTaskText(incidentSummary.failure_kind || fallback.incident_summary.failure_kind)
        || fallback.incident_summary.failure_kind,
      message: sanitizeTaskText(incidentSummary.message || fallback.incident_summary.message) || fallback.incident_summary.message,
    },
    supply_chain_controls: {
      ...fallback.supply_chain_controls,
      spec_present: supplyChainControls.spec_present === true,
      policy_present: supplyChainControls.policy_present === true,
      task_registry_present: supplyChainControls.task_registry_present === true,
    },
    evidence: Array.isArray(payload?.evidence) ? payload.evidence : fallback.evidence,
  };
}

async function readProjectCraCompliance(project) {
  const payload = await readJsonFile(projectCraCompliancePath(project), defaultCraCompliancePayload(project));
  return normalizeCraCompliancePayload(project, payload);
}

function normalizeDashboardAlertEntry(entry) {
  if (!entry || typeof entry !== "object") {
    return null;
  }
  return {
    code: sanitizeTaskText(entry.code || ""),
    metric: sanitizeTaskText(entry.metric || ""),
    severity: sanitizeTaskText(entry.severity || ""),
    message: sanitizeTaskText(entry.message || ""),
    details: entry.details && typeof entry.details === "object" && !Array.isArray(entry.details) ? entry.details : {},
  };
}

async function readAlerts() {
  const fallback = defaultDashboardAlerts();
  const payload = await readJsonFile(PATHS.alerts, fallback);
  const alerts = Array.isArray(payload?.alerts)
    ? payload.alerts.map((entry) => normalizeDashboardAlertEntry(entry)).filter(Boolean)
    : [];
  return {
    updated_at: typeof payload?.updated_at === "string" ? payload.updated_at : "",
    project_id: typeof payload?.project_id === "string" ? payload.project_id : "",
    alert_count: Number.isInteger(payload?.alert_count) ? payload.alert_count : alerts.length,
    active: payload?.active === true || alerts.length > 0,
    alerts,
  };
}

async function writeJsonFile(filePath, payload) {
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  await fsp.writeFile(filePath, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
}

async function readDashboardSettings() {
  const payload = await readJsonFile(PATHS.dashboardSettings, {});
  return {
    approval_mode: normalizeApprovalMode(
      payload.approval_mode || payload.approvalMode || (payload.auto_approve ? "auto" : "manual"),
    ),
    updated_at: typeof payload.updated_at === "string" ? payload.updated_at : "",
  };
}

async function writeDashboardSettings(input) {
  const settings = {
    approval_mode: normalizeApprovalMode(input.approval_mode || input.approvalMode || input.mode),
    updated_at: input.updated_at || nowUtc(),
  };
  await writeJsonFile(PATHS.dashboardSettings, settings);
  return settings;
}

async function readProjectSources(project) {
  const payload = await readJsonFile(projectSourcesPath(project), {});
  return normalizeProjectSourcesPayload(project, payload);
}

async function writeProjectSources(project, payload) {
  const nextPayload = normalizeProjectSourcesPayload(project, payload);
  nextPayload.updated_at = nowUtc();
  await writeJsonFile(projectSourcesPath(project), nextPayload);
  return nextPayload;
}

async function readStatus() {
  const raw = await readText(PATHS.status);
  return raw
    .split(/\r?\n/)
    .filter(Boolean)
    .reduce((result, line) => {
      const index = line.indexOf("=");
      if (index === -1) {
        return result;
      }
      const key = line.slice(0, index);
      const value = line.slice(index + 1);
      result[key] = value;
      return result;
    }, {});
}

async function readEnvFile(filePath) {
  const raw = await readText(filePath);
  return raw
    .split(/\r?\n/)
    .filter(Boolean)
    .reduce((result, line) => {
      const index = line.indexOf("=");
      if (index === -1) {
        return result;
      }
      const key = line.slice(0, index).trim();
      if (!key) {
        return result;
      }
      result[key] = line.slice(index + 1).trim();
      return result;
    }, {});
}

function runtimeRestartStatePath(runtimeFile) {
  const normalized = String(runtimeFile || "").trim();
  if (!normalized) {
    return "";
  }
  if (normalized.endsWith(".restart-state.env") || normalized.endsWith(".restart-state")) {
    return normalized;
  }
  if (normalized.endsWith(".env")) {
    return `${normalized.slice(0, -4)}.restart-state.env`;
  }
  return `${normalized}.restart-state`;
}

async function readRuntimeEnvWithRestartState(runtimeFile) {
  const normalized = String(runtimeFile || "").trim();
  if (!normalized) {
    return {};
  }
  const restartStateFile = runtimeRestartStatePath(normalized);
  const [runtimeEnv, restartStateEnv] = await Promise.all([
    readEnvFile(normalized).catch(() => ({})),
    restartStateFile ? readEnvFile(restartStateFile).catch(() => ({})) : Promise.resolve({}),
  ]);
  return { ...runtimeEnv, ...restartStateEnv };
}

function matchesActiveDashboardRuntime(runtimeEnv) {
  const runtimePort = safeInteger(runtimeEnv.dashboard_port, 0);
  const runtimeScheme = String(runtimeEnv.dashboard_scheme || "").trim().toLowerCase();
  return runtimePort === PORT && runtimeScheme === PROTOCOL;
}

async function resolveAgentctlRuntimeFile() {
  const configuredPath = process.env.DASHBOARD_AGENTCTL_RUNTIME_FILE;
  if (configuredPath) {
    return configuredPath;
  }

  const runtimeDir = path.dirname(PATHS.agentctlRuntime);
  let entries = [];
  try {
    entries = await fsp.readdir(runtimeDir);
  } catch {
    const fallbackEnv = await readEnvFile(PATHS.agentctlRuntime).catch(() => null);
    return fallbackEnv && matchesActiveDashboardRuntime(fallbackEnv) ? PATHS.agentctlRuntime : "";
  }

  const candidateNames = entries
    .filter((entry) => /^agentctl-runtime(?:-[A-Za-z0-9._-]+)?\.env$/.test(entry))
    .sort();

  let selectedPath = "";
  let selectedUpdatedAt = "";

  for (const entry of candidateNames) {
    const candidatePath = path.join(runtimeDir, entry);
    const runtimeEnv = await readEnvFile(candidatePath);
    if (!matchesActiveDashboardRuntime(runtimeEnv)) {
      continue;
    }

    const updatedAt = String(runtimeEnv.updated_at || "").trim();
    if (!selectedUpdatedAt || updatedAt > selectedUpdatedAt) {
      selectedPath = candidatePath;
      selectedUpdatedAt = updatedAt;
    }
  }

  return selectedPath;
}

async function computeHelperScriptsFingerprint() {
  const digest = crypto.createHash("sha256");
  for (const relativePath of TRACKED_RUNTIME_HELPER_SCRIPTS) {
    digest.update(relativePath, "utf8");
    digest.update("\0", "utf8");
    try {
      const fileBuffer = await fsp.readFile(path.join(ROOT, relativePath));
      digest.update(fileBuffer);
    } catch {
      digest.update("missing", "utf8");
    }
    digest.update("\0", "utf8");
  }
  return digest.digest("hex");
}

function shortFingerprint(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return /^[a-f0-9]{12,}$/.test(normalized) ? normalized.slice(0, 12) : "";
}

function shellQuote(value) {
  return `'${String(value || "").replace(/'/g, `'\"'\"'`)}'`;
}

function buildRuntimeReloadAction(runtimeEnv = {}) {
  const sessionName = sanitizeTaskText(runtimeEnv.session_name || "codex-agent-system") || "codex-agent-system";
  const sessionPrefix =
    sessionName && sessionName !== "codex-agent-system" ? `AGENTCTL_SESSION_NAME=${shellQuote(sessionName)} ` : "";
  return {
    label: "Reload Runtime",
    summary: "Run the existing reload workflow before approving or deriving more work.",
    command: `cd ${shellQuote(ROOT)} && ${sessionPrefix}bash scripts/agentctl.sh reload`,
    cwd: ROOT,
    session_name: sessionName,
  };
}

async function readRuntimeDashboardStatus(statusInput = null) {
  const runtimeFile = await resolveAgentctlRuntimeFile();
  const [runtimeEnv, currentHelperFingerprint] = await Promise.all([
    readRuntimeEnvWithRestartState(runtimeFile),
    computeHelperScriptsFingerprint(),
  ]);
  const activeHelperFingerprint = String(runtimeEnv.queue_helper_fingerprint || "").trim().toLowerCase();
  const sessionName = sanitizeTaskText(runtimeEnv.session_name || "codex-agent-system") || "codex-agent-system";
  const runtimeVersionShort = shortFingerprint(activeHelperFingerprint) || "unknown";
  const runtimeVersionLabel = `${sessionName}@${runtimeVersionShort}`;
  const currentHelperFingerprintShort = shortFingerprint(currentHelperFingerprint) || "unknown";
  const driftDetected = Boolean(activeHelperFingerprint) && activeHelperFingerprint !== currentHelperFingerprint;
  const persistedRestartNeeded =
    String(runtimeEnv.restart_needed || statusInput?.restart_needed || "").trim().toLowerCase() === "true";
  const restartNeeded = driftDetected || persistedRestartNeeded;
  const driftStatus = !activeHelperFingerprint
    ? "unknown"
    : driftDetected
      ? restartNeeded
        ? "restart_needed"
        : "drifted"
      : "in_sync";
  const promptIntakeAllowed = Boolean(activeHelperFingerprint) && !driftDetected && !restartNeeded;

  let reloadDriftSummary = "Runtime helper fingerprint not recorded yet. Reload once to capture the active helper version.";
  if (activeHelperFingerprint && !driftDetected) {
    reloadDriftSummary = `In sync: runtime ${runtimeVersionShort} matches current helpers ${currentHelperFingerprintShort}.`;
  } else if (activeHelperFingerprint) {
    reloadDriftSummary = `Reload drift detected: runtime ${runtimeVersionShort} vs current helpers ${currentHelperFingerprintShort}${restartNeeded ? " (restart needed)." : "."}`;
  }

  return {
    runtime_version_label: runtimeVersionLabel,
    reload_drift_summary: reloadDriftSummary,
    runtime: {
      version: {
        label: runtimeVersionLabel,
        session_name: sessionName,
        helper_fingerprint: activeHelperFingerprint || "",
        helper_fingerprint_short: runtimeVersionShort,
      },
      reload_drift: {
        detected: driftDetected,
        restart_needed: restartNeeded,
        status: driftStatus,
        runtime_helper_fingerprint: activeHelperFingerprint || "",
        runtime_helper_fingerprint_short: runtimeVersionShort,
        current_helper_fingerprint: currentHelperFingerprint || "",
        current_helper_fingerprint_short: currentHelperFingerprintShort,
        summary: reloadDriftSummary,
      },
      reload_action: buildRuntimeReloadAction(runtimeEnv),
    },
    capabilities: {
      prompt_intake: promptIntakeAllowed,
    },
  };
}

async function writeStatus(nextStatus) {
  const status = {
    state: nextStatus.state || "idle",
    project: nextStatus.project || "",
    task: nextStatus.task || "",
    last_result: nextStatus.last_result || "NONE",
    note: nextStatus.note || "",
    updated_at: nextStatus.updated_at || nowUtc(),
  };
  const content = [
    `state=${status.state}`,
    `project=${status.project}`,
    `task=${status.task}`,
    `last_result=${status.last_result}`,
    `note=${status.note}`,
    `updated_at=${status.updated_at}`,
    "",
  ].join("\n");
  await fsp.writeFile(PATHS.status, content, "utf8");
}

async function readCodexAuthHealth(statusInput = null) {
  const payload = await readJsonFile(PATHS.authFailure, {});
  const reason = typeof payload.reason === "string" ? payload.reason.trim() : "";
  const detectedAt = typeof payload.detected_at === "string" ? payload.detected_at.trim() : "";
  const rawCooldown = Number(process.env.CODEX_AUTH_FAILURE_COOLDOWN_SECONDS || 900);
  const cooldownSeconds = Number.isFinite(rawCooldown) && rawCooldown > 0 ? Math.floor(rawCooldown) : 0;
  const stat = await fsp.stat(PATHS.authFailure).catch(() => null);
  const ageSeconds = stat ? Math.max(0, Math.floor((Date.now() - stat.mtimeMs) / 1000)) : null;
  const active = Boolean(reason) && cooldownSeconds > 0 && ageSeconds !== null && ageSeconds < cooldownSeconds;
  const remainingSeconds =
    active && ageSeconds !== null ? Math.max(cooldownSeconds - ageSeconds, 0) : 0;
  const queueState = String(statusInput?.state || "").toLowerCase();
  const queueNote = String(statusInput?.note || "");
  const blockedByStatus = queueState === "blocked" && queueNote.startsWith("waiting_for_codex_auth");

  let message = "No cached Codex auth failure.";
  if (active) {
    message = "Queue execution is paused until Codex authentication recovers.";
  } else if (reason) {
    message = "Last cached Codex auth failure has expired.";
  }

  return {
    active,
    age_seconds: ageSeconds,
    blocks_queue: active || blockedByStatus,
    cooldown_expires_at:
      stat && cooldownSeconds > 0 ? new Date(stat.mtimeMs + cooldownSeconds * 1000).toISOString() : "",
    cooldown_seconds: cooldownSeconds,
    detected_at: detectedAt,
    message,
    reason,
    remaining_seconds: remainingSeconds,
    status: active ? "blocked" : reason ? "recovered" : "healthy",
  };
}

async function readStrategyHealth(snapshot = null) {
  const summarySnapshot = snapshot && typeof snapshot === "object" ? snapshot : null;
  const providedStrategyPayload =
    summarySnapshot?.strategyLatestPayload && typeof summarySnapshot.strategyLatestPayload === "object"
      ? summarySnapshot.strategyLatestPayload
      : null;
  const providedStrategyStat =
    summarySnapshot?.strategyLatestStat && typeof summarySnapshot.strategyLatestStat === "object"
      ? summarySnapshot.strategyLatestStat
      : null;
  const [payload, stat, registryTasks, queueTasks, statusInput, taskLog] = await Promise.all([
    providedStrategyPayload ? Promise.resolve(providedStrategyPayload) : readJsonFile(PATHS.strategyLatest, {}),
    providedStrategyStat ? Promise.resolve(providedStrategyStat) : fsp.stat(PATHS.strategyLatest).catch(() => null),
    summarySnapshot ? Promise.resolve(summarySnapshot.tasks || []) : readTaskRegistry(),
    summarySnapshot ? Promise.resolve(summarySnapshot.queueTasks || []) : readQueueTasks(),
    summarySnapshot ? Promise.resolve(summarySnapshot.status || {}) : readStatus(),
    summarySnapshot ? Promise.resolve(summarySnapshot.taskLog || "") : readText(PATHS.taskLog),
  ]);
  const message = typeof payload.message === "string" ? payload.message.trim() : "";
  const boardUpdates = Array.isArray(payload?.data?.board_updates)
    ? payload.data.board_updates.filter((task) => task && typeof task === "object")
    : null;
  const boardTasks = Array.isArray(payload?.data?.board_tasks)
    ? payload.data.board_tasks.filter((task) => task && typeof task === "object")
    : [];
  const status = String(payload.status || "").trim().toLowerCase();
  const ageSeconds = stat ? Math.max(0, Math.floor((Date.now() - stat.mtimeMs) / 1000)) : null;
  const intervalSeconds = Math.max(15, safeInteger(process.env.STRATEGY_INTERVAL_SECONDS, 60));
  const staleThresholdSeconds = Math.max(intervalSeconds * 3, safeInteger(process.env.STRATEGY_STALE_SECONDS, 180));
  const active = Boolean(stat) && status === "success" && ageSeconds !== null && ageSeconds <= staleThresholdSeconds;
  let state = "unknown";
  let title = "Unknown";

  if (stat && status === "success" && active) {
    state = "running";
    title = "Active";
  } else if (stat && status === "success") {
    state = "stale";
    title = "Stale";
  } else if (stat && status) {
    state = "failed";
    title = "Failed";
  }

  const taskLogRecords = Array.isArray(summarySnapshot?.taskLogRecords)
    ? summarySnapshot.taskLogRecords
    : parseJsonLines(taskLog);
  const loopEffortBoundedExperiment = buildLoopEffortBoundedExperiment(
    buildLoopEffortSignal(STRATEGY_PRIMARY_PROJECT, registryTasks),
  );
  const normalizedBoardTasks = boardTasks
    .map((task) => replaceLegacyBoardAnalysisTask(task, loopEffortBoundedExperiment))
    .filter(Boolean);
  const guard = buildStrategyHealthGuard(
    STRATEGY_PRIMARY_PROJECT,
    registryTasks,
    queueTasks,
    statusInput,
    taskLogRecords,
  );
  let nextMessage = message || (stat ? "Strategy health is available." : "No strategy run has been recorded yet.");

  if (state === "running" && !guard.healthy) {
    state = "failed";
    title = guard.retry_churn_detected && guard.queue_starvation_detected ? "Blocked" : guard.retry_churn_detected ? "Churning" : guard.executable_work_drained ? "Drained" : "Starved";
    nextMessage = `Strategy run is fresh, but ${guard.summary.toLowerCase()} for ${guard.project}.`;
  }

  return {
    active,
    status: state,
    title,
    message: nextMessage,
    last_board_updates: Array.isArray(boardUpdates) ? boardUpdates.length : normalizedBoardTasks.length,
    board_tasks: normalizedBoardTasks,
    last_run_at: stat ? new Date(stat.mtimeMs).toISOString() : "",
    next_run_in_seconds: ageSeconds === null ? null : Math.max(intervalSeconds - ageSeconds, 0),
    guard,
  };
}

async function listProjects() {
  const [projectEntries, queueEntries] = await Promise.all([
    fsp.readdir(PATHS.projects, { withFileTypes: true }).catch(() => []),
    fsp.readdir(PATHS.queues, { withFileTypes: true }).catch(() => []),
  ]);
  const projectNames = new Set(
    projectEntries.filter((entry) => entry.isDirectory()).map((entry) => entry.name),
  );
  for (const entry of queueEntries) {
    if (entry.isFile() && entry.name.endsWith(".txt")) {
      projectNames.add(entry.name.replace(/\.txt$/, ""));
    }
  }
  return [...projectNames].sort();
}

async function readQueueTasks() {
  const entries = await fsp.readdir(PATHS.queues, { withFileTypes: true }).catch(() => []);
  const tasks = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".txt")) {
      continue;
    }
    const filePath = path.join(PATHS.queues, entry.name);
    const raw = await readText(filePath);
    for (const line of raw.split(/\r?\n/)) {
      const task = line.trim();
      if (task) {
        tasks.push({ project: entry.name.replace(/\.txt$/, ""), task });
      }
    }
  }
  return tasks;
}

async function buildQueueReadCacheSignature() {
  const baseSignature = syncFileSignature(PATHS.queues);
  const entries = await fsp.readdir(PATHS.queues, { withFileTypes: true }).catch(() => []);
  const fileSignatures = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".txt"))
    .map((entry) => syncFileSignature(path.join(PATHS.queues, entry.name)))
    .sort();
  return [baseSignature, ...fileSignatures].join("|");
}

async function queueTaskCount() {
  const tasks = await readQueueTasks();
  return tasks.length;
}

async function taskExistsAnywhere(project, task) {
  const normalized = normalizeTask(task);
  const [status, queueTasks] = await Promise.all([readStatus(), readQueueTasks()]);
  if (status.project === project && normalizeTask(status.task || "") === normalized) {
    return true;
  }
  return queueTasks.some(
    (entry) => entry.project === project && normalizeTask(entry.task) === normalized,
  );
}

function parseJsonLines(raw) {
  return raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .flatMap((line) => {
      try {
        return [JSON.parse(line)];
      } catch {
        return [];
      }
    });
}

function normalizeIncidentRecord(record) {
  if (!record || typeof record !== "object") {
    return null;
  }
  return {
    timestamp: typeof record.timestamp === "string" ? record.timestamp : "",
    project_id: typeof record.project_id === "string" ? record.project_id : "",
    result: sanitizeTaskText(record.result || ""),
    run_state: sanitizeTaskText(record.run_state || ""),
    failure_kind: sanitizeTaskText(record.failure_kind || "unknown") || "unknown",
    message: sanitizeTaskText(record.message || ""),
    metrics: record.metrics && typeof record.metrics === "object" && !Array.isArray(record.metrics) ? record.metrics : {},
  };
}

async function readRecentIncidents(limit = DASHBOARD_INCIDENT_LIMIT) {
  const raw = await readText(PATHS.incidentLog);
  const records = parseJsonLines(raw)
    .map((record) => normalizeIncidentRecord(record))
    .filter(Boolean);
  if (!records.length) {
    return [];
  }
  return records.slice(-Math.max(1, limit));
}

function escapeRegExp(value) {
  return String(value || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function normalizeRecordProject(record) {
  return sanitizeProjectName(record?.project || record?.target_project || "codex-agent-system") || "codex-agent-system";
}

function countProjectTextMentions(raw, project) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const normalized = String(raw || "").toLowerCase();
  if (!normalized) {
    return 0;
  }
  const matches = normalized.match(new RegExp(escapeRegExp(projectKey), "g"));
  return matches ? matches.length : 0;
}

function normalizePatternField(value, fallback = "unknown") {
  const normalized = String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 64);
  return normalized || fallback;
}

function createReusablePatternRecord(input) {
  const category = normalizePatternField(input?.category, "code_quality");
  const trigger = normalizePatternField(input?.trigger, "unknown");
  const action = normalizePatternField(input?.action, "record");
  const outcome = normalizePatternField(input?.outcome, "observed");
  const sourceFileType = normalizePatternField(input?.source_file_type, "json");
  const key = [category, trigger, action, outcome, sourceFileType].join(":");
  return {
    pattern_id: `pattern-${crypto.createHash("sha1").update(key).digest("hex").slice(0, 12)}`,
    category,
    trigger,
    action,
    outcome,
    source_file_type: sourceFileType,
  };
}

function collectReusablePatternRecords(project, registryTasks, taskLogRecords, memoryFiles) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const projectRegistryTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter(
    (task) => normalizeTaskProject(task) === projectKey,
  );
  const projectRecords = (Array.isArray(taskLogRecords) ? taskLogRecords : []).filter(
    (record) => normalizeRecordProject(record) === projectKey,
  );
  const knowledgePayload =
    memoryFiles?.knowledge && typeof memoryFiles.knowledge === "object" ? memoryFiles.knowledge : { rules: [] };
  const knowledgeRules = Array.isArray(knowledgePayload.rules) ? knowledgePayload.rules : [];
  const knowledgeMatches = knowledgeRules.filter((rule) =>
    JSON.stringify(rule || {})
      .toLowerCase()
      .includes(projectKey),
  );
  const patterns = [];
  const pushPattern = (input) => {
    patterns.push(createReusablePatternRecord(input));
  };

  for (const task of projectRegistryTasks) {
    const status = normalizePatternField(task?.status, "tracked");
    const source =
      task?.task_intent && typeof task.task_intent === "object"
        ? normalizePatternField(task.task_intent.source, "task_registry")
        : "task_registry";
    const executionResult = normalizePatternField(task?.execution?.result, status);
    pushPattern({
      category: task?.category || "code_quality",
      trigger: source,
      action: `status_${status}`,
      outcome: executionResult,
      source_file_type: "json",
    });
  }

  for (const record of projectRecords) {
    pushPattern({
      category: "code_quality",
      trigger: "task_log",
      action: "execute_task",
      outcome: normalizePatternField(record?.result, "unknown"),
      source_file_type: "log",
    });
  }

  for (const rule of knowledgeMatches) {
    pushPattern({
      category: rule?.category || "code_quality",
      trigger: "knowledge_rule",
      action: "record_rule",
      outcome: "available",
      source_file_type: "json",
    });
  }

  for (const [fileType, raw] of [
    ["context_md", memoryFiles?.context],
    ["decisions_md", memoryFiles?.decisions],
    ["learnings_md", memoryFiles?.learnings],
  ]) {
    if (countProjectTextMentions(raw, projectKey) > 0) {
      pushPattern({
        category: "code_quality",
        trigger: "project_memory",
        action: "capture_pattern",
        outcome: "available",
        source_file_type: fileType,
      });
    }
  }

  return patterns
    .sort((left, right) => left.pattern_id.localeCompare(right.pattern_id))
    .filter((pattern, index, items) => index === items.findIndex((entry) => entry.pattern_id === pattern.pattern_id));
}

function compactQueueState(project, queueTasks, registryTasks, status) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const queuedTasks = (Array.isArray(queueTasks) ? queueTasks : [])
    .filter((entry) => sanitizeProjectName(entry?.project || "") === projectKey)
    .map((entry) => sanitizeTaskText(entry?.task || ""))
    .filter(Boolean);
  const activeRegistryTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter((task) => {
    const executionState = String(task?.execution?.state || "").trim().toLowerCase();
    return normalizeTaskProject(task) === projectKey && (executionState === "running" || executionState === "retrying");
  });
  const currentStatusProject = sanitizeProjectName(status?.project || "") || "";
  const currentStatusTask = sanitizeTaskText(status?.task || "");
  const currentStatusState = sanitizeTaskText(status?.state || "").toLowerCase();
  const statusMatchesProject = currentStatusProject === projectKey;
  const activeTaskTitle =
    (statusMatchesProject && currentStatusTask) ||
    sanitizeTaskText(activeRegistryTasks[0]?.title || activeRegistryTasks[0]?.execution?.current_step || "") ||
    queuedTasks[0] ||
    "";
  const derivedState =
    (statusMatchesProject && currentStatusState) ||
    (activeRegistryTasks.length ? String(activeRegistryTasks[0]?.execution?.state || "").trim().toLowerCase() : "") ||
    (queuedTasks.length ? "queued" : "idle") ||
    "idle";
  return {
    queued_count: queuedTasks.length,
    active_count: activeRegistryTasks.length,
    state: derivedState || "idle",
    active_task: activeTaskTitle,
    note: statusMatchesProject ? sanitizeTaskText(status?.note || "") : "",
    queued_tasks_preview: queuedTasks.slice(0, 3),
  };
}

function deriveResolvedAttemptRecord(task) {
  if (!task || typeof task !== "object") {
    return null;
  }
  const execution = task.execution && typeof task.execution === "object" ? task.execution : {};
  const status = String(task.status || "").trim().toLowerCase();
  const resolvedResult = String(execution.result || "").trim().toUpperCase();
  if (status !== "completed" || resolvedResult !== "SUCCESS") {
    return null;
  }
  const attempt = safeInteger(execution.attempt, Number.NaN);

  return {
    result: resolvedResult,
    attempt: Number.isFinite(attempt) && attempt >= 0 ? attempt : Number.NaN,
  };
}

function isPersistedCompletedSuccessfulTask(task) {
  if (!task || typeof task !== "object") {
    return false;
  }
  const execution = task.execution && typeof task.execution === "object" ? task.execution : {};
  return (
    String(task.status || "").trim().toLowerCase() === "completed" &&
    String(execution.result || "").trim().toUpperCase() === "SUCCESS"
  );
}

function buildFirstPassSuccessSignal(project, registryTasks) {
  const projectKey = sanitizeProjectName(project || "");
  const projectRegistryTasks = projectKey
    ? (Array.isArray(registryTasks) ? registryTasks : []).filter((task) => normalizeTaskProject(task) === projectKey)
    : Array.isArray(registryTasks)
      ? registryTasks.filter((task) => task && typeof task === "object")
      : [];
  let successfulCompletedRecords = projectRegistryTasks
    .filter((task) => isPersistedCompletedSuccessfulTask(task))
    .map((task) => deriveResolvedAttemptRecord(task))
    .filter(Boolean);
  if (successfulCompletedRecords.length < FIRST_PASS_SUCCESS_MIN_SAMPLE_SIZE) {
    const taskLogRecords = Array.isArray(arguments[2]) ? arguments[2] : [];
    const projectTaskLogRecords = projectKey
      ? taskLogRecords.filter((record) => normalizeRecordProject(record) === projectKey)
      : taskLogRecords.filter((record) => record && typeof record === "object");
    const recentSuccessfulTaskLogRecords = projectTaskLogRecords
      .filter((record) => {
        const result = String(record?.result || "").trim().toUpperCase();
        return result === "SUCCESS" || result === "FAILURE";
      })
      .slice(-FIRST_PASS_SUCCESS_RECENT_LOG_WINDOW)
      .filter((record) => String(record?.result || "").trim().toUpperCase() === "SUCCESS")
      .map((record) => ({
        result: "SUCCESS",
        attempt: Math.max(0, safeInteger(record?.attempts ?? record?.attempt, 0)),
      }));
    if (recentSuccessfulTaskLogRecords.length >= FIRST_PASS_SUCCESS_MIN_SAMPLE_SIZE) {
      successfulCompletedRecords = recentSuccessfulTaskLogRecords;
    }
  }
  const successfulSampleSize = successfulCompletedRecords.length;
  const firstPassSuccessCount = successfulCompletedRecords.filter((record) => record.attempt <= 1).length;
  const multiAttemptResolvedCount = successfulCompletedRecords.filter((record) => record.attempt > 1).length;
  const firstPassSuccessRatio = successfulSampleSize ? firstPassSuccessCount / successfulSampleSize : 0;
  const firstPassSuccessRate = successfulSampleSize ? Number(firstPassSuccessRatio.toFixed(2)) : 0;
  const lowFirstPassSuccessDetected =
    successfulSampleSize > 0 && firstPassSuccessRatio < LOW_FIRST_PASS_SUCCESS_RATE_THRESHOLD;
  const summary = lowFirstPassSuccessDetected
    ? `low first-pass success (${firstPassSuccessCount}/${successfulSampleSize} first-pass successes, ${multiAttemptResolvedCount} multi-attempt resolved)`
    : successfulSampleSize
      ? `first-pass success stable (${firstPassSuccessCount}/${successfulSampleSize} resolved on first attempt)`
      : "No successful completed execution records are available yet.";

  return {
    detected: lowFirstPassSuccessDetected,
    summary,
    sample_size: successfulSampleSize,
    first_pass_success_count: firstPassSuccessCount,
    multi_attempt_resolved_count: multiAttemptResolvedCount,
    first_pass_success_rate: firstPassSuccessRate,
  };
}

function isExhaustedRetryFailedTask(task) {
  if (!task || typeof task !== "object") {
    return false;
  }
  if (String(task.status || "").trim().toLowerCase() !== "failed") {
    return false;
  }
  const execution = task.execution && typeof task.execution === "object" ? task.execution : {};
  const attempt = Math.max(0, safeInteger(execution.attempt, 0));
  const maxRetries = Math.max(0, safeInteger(execution.max_retries, 0));
  return maxRetries > 0 && attempt >= maxRetries;
}

function buildStrategySaturationSignal(project, registryTasks) {
  const projectKey = sanitizeProjectName(project || "");
  const projectRegistryTasks = projectKey
    ? (Array.isArray(registryTasks) ? registryTasks : []).filter((task) => normalizeTaskProject(task) === projectKey)
    : Array.isArray(registryTasks)
      ? registryTasks.filter((task) => task && typeof task === "object")
      : [];
  const saturationCounts = buildStrategyFailureSaturationCounts(projectRegistryTasks);
  const saturatedFailedTasks = projectRegistryTasks.filter((task) => {
    if (!task || typeof task !== "object") {
      return false;
    }
    if (String(task.status || "").trim().toLowerCase() !== "failed") {
      return false;
    }
    const key = strategySaturationKey(task);
    return Boolean(key) && (saturationCounts.get(key) || 0) >= STRATEGY_SATURATED_FAILURE_THRESHOLD;
  }).length;

  return {
    detected: saturatedFailedTasks > 0,
    saturated_failed_tasks: saturatedFailedTasks,
  };
}

function deriveLoopEffortRecord(task) {
  if (!task || typeof task !== "object") {
    return null;
  }
  const execution = task.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext =
    task.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const failureContext = task.failure_context && typeof task.failure_context === "object" ? task.failure_context : {};
  const attempt = Math.max(
    0,
    execution.attempt != null
      ? safeInteger(execution.attempt, 0)
      : executionContext.attempts != null
        ? safeInteger(executionContext.attempts, 0)
        : failureContext.attempts != null
          ? safeInteger(failureContext.attempts, 0)
          : 0,
  );
  const totalStepAttempts = Math.max(
    attempt,
    execution.total_step_attempts != null
      ? safeInteger(execution.total_step_attempts, attempt)
      : executionContext.total_step_attempts != null
        ? safeInteger(executionContext.total_step_attempts, attempt)
        : failureContext.total_step_attempts != null
          ? safeInteger(failureContext.total_step_attempts, attempt)
          : attempt,
  );
  if (totalStepAttempts <= attempt) {
    return null;
  }
  return {
    attempt,
    total_step_attempts: totalStepAttempts,
  };
}

function buildLoopEffortSignal(project, registryTasks) {
  const projectKey = sanitizeProjectName(project || "");
  const scopedRegistryTasks = projectKey
    ? (Array.isArray(registryTasks) ? registryTasks : []).filter((task) => normalizeTaskProject(task) === projectKey)
    : Array.isArray(registryTasks)
      ? registryTasks.filter((task) => task && typeof task === "object")
      : [];
  const loopEffortRecords = scopedRegistryTasks
    .map((task) => deriveLoopEffortRecord(task))
    .filter(Boolean);
  const loopEffortTaskCount = loopEffortRecords.length;
  const loopEffortExtraStepAttempts = loopEffortRecords.reduce(
    (sum, record) => sum + Math.max(0, safeInteger(record.total_step_attempts, 0) - safeInteger(record.attempt, 0)),
    0,
  );
  return {
    detected: loopEffortTaskCount > 0,
    loop_effort_task_count: loopEffortTaskCount,
    loop_effort_extra_step_attempts: loopEffortExtraStepAttempts,
  };
}

function buildLoopEffortBoundedExperiment(loopEffortSignal) {
  const signal = loopEffortSignal && typeof loopEffortSignal === "object" ? loopEffortSignal : {};
  const loopEffortTaskCount = Math.max(0, safeInteger(signal.loop_effort_task_count, 0));
  const loopEffortExtraStepAttempts = Math.max(0, safeInteger(signal.loop_effort_extra_step_attempts, 0));
  const detected = loopEffortExtraStepAttempts >= LOOP_EFFORT_BOUNDED_EXPERIMENT_EXTRA_STEP_THRESHOLD;
  return {
    detected,
    title: LOOP_EFFORT_BOUNDED_EXPERIMENT_TITLE,
    source_task_id: LOOP_EFFORT_BOUNDED_EXPERIMENT_ROOT_ID,
    root_source_task_id: LOOP_EFFORT_BOUNDED_EXPERIMENT_ROOT_ID,
    original_failed_root_id: LOOP_EFFORT_BOUNDED_EXPERIMENT_ROOT_ID,
    metric_name: LOOP_EFFORT_BOUNDED_EXPERIMENT_METRIC_NAME,
    extra_step_threshold: LOOP_EFFORT_BOUNDED_EXPERIMENT_EXTRA_STEP_THRESHOLD,
    message: detected
      ? `Bounded loop effort experiment active because ${LOOP_EFFORT_BOUNDED_EXPERIMENT_METRIC_NAME} reached ${loopEffortExtraStepAttempts} across ${loopEffortTaskCount} task(s).`
      : `Bounded loop effort experiment inactive because ${LOOP_EFFORT_BOUNDED_EXPERIMENT_METRIC_NAME} is below ${LOOP_EFFORT_BOUNDED_EXPERIMENT_EXTRA_STEP_THRESHOLD}.`,
  };
}

function isLegacyFirstPassExperimentTask(task) {
  if (!task || typeof task !== "object") {
    return false;
  }
  const title = sanitizeTaskText(task.title || task.task || "");
  const sourceTaskId = sanitizeTaskText(
    task.source_task_id || task.sourceTaskId || task.root_source_task_id || task.rootSourceTaskId || "",
  );
  return title === LEGACY_FIRST_PASS_EXPERIMENT_TITLE || sourceTaskId === "strategy::first-pass-success";
}

function replaceLegacyBoardAnalysisTask(task, boundedExperiment) {
  if (!isLegacyFirstPassExperimentTask(task)) {
    return task;
  }
  const experiment = boundedExperiment && typeof boundedExperiment === "object" ? boundedExperiment : {};
  if (experiment.detected !== true) {
    return null;
  }
  return {
    ...task,
    title: experiment.title,
    task: experiment.title,
    source_task_title: experiment.title,
    source_task_id: experiment.source_task_id,
    root_source_task_id: experiment.root_source_task_id,
    original_failed_root_id: experiment.original_failed_root_id,
    experiment_metric_name: experiment.metric_name,
    experiment_message: experiment.message,
  };
}

function derivePersistedExecutionState(task) {
  const execution = task?.execution && typeof task.execution === "object" ? task.execution : {};
  const status = String(task?.status || "unknown").trim().toLowerCase() || "unknown";
  const executionState = String(execution.state || "unknown").trim().toLowerCase() || "unknown";
  const attempt = Math.max(0, safeInteger(execution.attempt, 0));
  const maxRetries = Math.max(0, safeInteger(execution.max_retries, 0));
  const willRetry = execution.will_retry === true || executionState === "retrying";

  return {
    status,
    execution_state: executionState,
    attempt,
    max_retries: maxRetries,
    will_retry: willRetry,
  };
}

function persistedTaskOutcomeTimestamp(task) {
  return (
    String(task?.completed_at || "").trim() ||
    String(task?.failed_at || "").trim() ||
    String(task?.updated_at || "").trim() ||
    String(task?.approved_at || "").trim() ||
    String(task?.created_at || "").trim()
  );
}

function isPersistedActionableTask(execution) {
  return execution.status === "pending_approval" || execution.status === "approved" || execution.status === "running";
}

function isPersistedQueueStarvationBacklogTask(execution) {
  return execution.status === "approved" || execution.status === "running";
}

function isPersistedActiveProgressTask(execution) {
  return execution.execution_state === "running" || execution.execution_state === "retrying";
}

function isPersistedRetryChurnExecution(execution) {
  return (
    (isPersistedActionableTask(execution) || isPersistedActiveProgressTask(execution)) &&
    (
      execution.execution_state === "retrying" ||
      (
        execution.attempt >= RETRY_CHURN_ATTEMPT_THRESHOLD &&
        (execution.max_retries === 0 || execution.attempt <= execution.max_retries)
      )
    )
  );
}

function buildPersistedBoardHealthSignals(project, registryTasks, taskLogRecords = []) {
  const projectKey = sanitizeProjectName(project || "");
  const projectRegistryTasks = projectKey
    ? (Array.isArray(registryTasks) ? registryTasks : []).filter((task) => normalizeTaskProject(task) === projectKey)
    : Array.isArray(registryTasks)
      ? registryTasks.filter((task) => task && typeof task === "object")
      : [];
  let activeExecutionCount = 0;
  let actionableBacklogCount = 0;
  let activeRetryChurnCount = 0;
  let pendingApprovalCount = 0;
  const recentRetryChurnCount = projectRegistryTasks
    .filter((task) => task && typeof task === "object")
    .map((task, index) => ({
      task,
      index,
      execution: derivePersistedExecutionState(task),
      result: String(task?.execution?.result || "").trim().toUpperCase(),
      timestamp: persistedTaskOutcomeTimestamp(task),
    }))
    .filter(({ execution, result }) => {
      // Recent retry churn is derived from persisted failed task rows only.
      // Exclude non-failed rows so recovered multi-attempt work does not keep the board unhealthy.
      if (execution.status !== "failed") {
        return false;
      }
      if (result !== "FAILURE") {
        return false;
      }
      return execution.attempt >= RETRY_CHURN_ATTEMPT_THRESHOLD;
    })
    .sort((left, right) => {
      const timestampOrder = right.timestamp.localeCompare(left.timestamp);
      return timestampOrder !== 0 ? timestampOrder : right.index - left.index;
    })
    .slice(0, STRATEGY_RECENT_FAILURE_WINDOW)
    .length;

  for (const task of projectRegistryTasks) {
    const execution = derivePersistedExecutionState(task);
    if (execution.status === "pending_approval") {
      pendingApprovalCount += 1;
    }
    // Inclusion rules are explicit here because strategy health depends on persisted status/execution values only.
    // Queue starvation only uses persisted backlog rows that are waiting for approval or execution.
    // Retry churn continues to use the broader actionable set, including stalled running rows.
    if (isPersistedQueueStarvationBacklogTask(execution)) {
      actionableBacklogCount += 1;
    }
    if (isPersistedActiveProgressTask(execution)) {
      activeExecutionCount += 1;
    }
    // Retry churn excludes completed registry rows on purpose so historical recovered work cannot poison health forever.
    // Active churn comes only from actionable persisted tasks that still show retry evidence.
    if (isPersistedRetryChurnExecution(execution)) {
      activeRetryChurnCount += 1;
    }
  }

  return {
    retry_churn_detected: activeRetryChurnCount > 0 || recentRetryChurnCount > 0,
    queue_starvation_detected: actionableBacklogCount > 0 && activeExecutionCount === 0,
    pending_approval_blocked_detected: pendingApprovalCount > 0 && actionableBacklogCount === 0 && activeExecutionCount === 0,
    active_retry_churn_count: activeRetryChurnCount,
    recent_retry_churn_count: recentRetryChurnCount,
    actionable_backlog_count: actionableBacklogCount,
    active_progress_count: activeExecutionCount,
  };
}

function buildProjectHealthMetrics(project, registryTasks, taskLogRecords) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const projectRegistryTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter(
    (task) => normalizeTaskProject(task) === projectKey,
  );
  const projectRecords = (Array.isArray(taskLogRecords) ? taskLogRecords : []).filter(
    (record) => normalizeRecordProject(record) === projectKey,
  );
  const firstPassSignal = buildFirstPassSuccessSignal(projectKey, projectRegistryTasks, projectRecords);
  const strategySaturationSignal = buildStrategySaturationSignal(projectKey, projectRegistryTasks);
  const boardHealthSignals = buildPersistedBoardHealthSignals(projectKey, projectRegistryTasks, projectRecords);
  const registryCounts = {
    pending_approval: 0,
    approved: 0,
    running: 0,
    retrying: 0,
    completed: 0,
    failed: 0,
    other: 0,
  };

  for (const task of projectRegistryTasks) {
    const status = String(task?.status || "").trim().toLowerCase();
    const executionState = String(task?.execution?.state || "").trim().toLowerCase();
    if (status === "pending_approval") {
      registryCounts.pending_approval += 1;
    } else if (status === "approved") {
      registryCounts.approved += 1;
    } else if (status === "completed" || status === "success") {
      registryCounts.completed += 1;
    } else if (status === "failed") {
      registryCounts.failed += 1;
    } else {
      registryCounts.other += 1;
    }

    if (executionState === "running") {
      registryCounts.running += 1;
    }
    if (executionState === "retrying") {
      registryCounts.retrying += 1;
    }
  }

  const successCount = projectRecords.filter((record) => String(record?.result || "").trim().toUpperCase() === "SUCCESS").length;
  const failureCount = projectRecords.filter((record) => String(record?.result || "").trim().toUpperCase() === "FAILURE").length;
  const timeoutFailureCount = countUnresolvedTimeoutRecords(projectRecords, projectRegistryTasks);
  const lastRecord = projectRecords.at(-1) || null;

  return {
    task_log_total: projectRecords.length,
    task_log_success: successCount,
    task_log_failure: failureCount,
    timeout_failure_records: timeoutFailureCount,
    timeout_failure_rate:
      projectRecords.length > 0 ? Number((timeoutFailureCount / projectRecords.length).toFixed(2)) : 0,
    task_log_success_rate:
      projectRecords.length > 0 ? Number(((successCount / projectRecords.length) * 100).toFixed(1)) : 0,
    registry_total: projectRegistryTasks.length,
    pending_approval: registryCounts.pending_approval,
    approved: registryCounts.approved,
    running: registryCounts.running,
    retrying: registryCounts.retrying,
    completed: registryCounts.completed,
    failed: registryCounts.failed,
    other: registryCounts.other,
    strategy_saturation_detected: strategySaturationSignal.detected,
    saturated_failed_tasks: strategySaturationSignal.saturated_failed_tasks,
    retry_churn_detected: boardHealthSignals.retry_churn_detected,
    queue_starvation_detected: boardHealthSignals.queue_starvation_detected,
    pending_approval_blocked_detected: boardHealthSignals.pending_approval_blocked_detected,
    active_retry_churn_count: boardHealthSignals.active_retry_churn_count,
    recent_retry_churn_count: boardHealthSignals.recent_retry_churn_count,
    actionable_backlog_count: boardHealthSignals.actionable_backlog_count,
    active_progress_count: boardHealthSignals.active_progress_count,
    first_pass_success: firstPassSignal,
    last_result: typeof lastRecord?.result === "string" ? lastRecord.result : "",
    last_result_at:
      typeof lastRecord?.completed_at === "string"
        ? lastRecord.completed_at
        : typeof lastRecord?.timestamp === "string"
          ? lastRecord.timestamp
          : "",
  };
}

function buildStrategyHealthGuard(project, registryTasks, queueTasks, status, taskLogRecords) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const projectTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter(
    (task) => normalizeTaskProject(task) === projectKey,
  );
  const metrics = buildProjectHealthMetrics(projectKey, registryTasks, taskLogRecords);
  const completion = clampNumber(
    safeNumber(metrics?.first_pass_success?.first_pass_success_rate, metrics?.first_pass_success_rate, 0),
    0,
    1,
  );
  const queueState = compactQueueState(projectKey, queueTasks, registryTasks, status);
  const pendingApprovalCount = Math.max(0, safeInteger(metrics?.pending_approval, 0));
  const approvedCount = Math.max(0, safeInteger(metrics?.approved, 0));
  const failedCount = Math.max(0, safeInteger(metrics?.failed, 0));
  const activeCount = Math.max(0, safeInteger(metrics?.active_progress_count, 0));
  const actionableCount = Math.max(0, safeInteger(metrics?.actionable_backlog_count, 0)) + activeCount;
  const queuedCount = Math.max(0, safeInteger(queueState?.queued_count, 0));
  const retryChurnDetected = metrics?.retry_churn_detected === true;
  const queueStarvationDetected = metrics?.queue_starvation_detected === true;
  const pendingApprovalBlockedDetected =
    metrics?.pending_approval_blocked_detected === true && approvedCount === 0 && activeCount === 0 && queuedCount === 0;
  const strategySaturationDetected = metrics?.strategy_saturation_detected === true;
  const saturatedFailedTasks = Math.max(0, safeInteger(metrics?.saturated_failed_tasks, 0));
  const activeRetryChurnCount = Math.max(0, safeInteger(metrics?.active_retry_churn_count, 0));
  const recentRetryChurnCount = Math.max(0, safeInteger(metrics?.recent_retry_churn_count, 0));
  const executableWork = listLowCompletionQueueDrainExecutableWork(projectTasks);
  const lowCompletionBlockedDecision = buildLowCompletionQueueDrainBlockedDecision(completion, executableWork);
  const preservedLowCompletionFollowup = findLowCompletionQueueDrainFollowupTask(projectKey, registryTasks);
  const executableStrategyWorkCount =
    (Array.isArray(registryTasks) ? registryTasks : []).filter((task) => {
      if (normalizeTaskProject(task) !== projectKey) {
        return false;
      }
      const source = strategyTaskSource(task);
      if (!["strategy_seed", "strategy_anomaly", "strategy_followup", "strategy_loop"].includes(source)) {
        return false;
      }
      const taskStatus = String(task?.status || "").trim().toLowerCase();
      const executionState = String(task?.execution?.state || "").trim().toLowerCase();
      return taskStatus === "approved" || taskStatus === "running" || executionState === "running" || executionState === "retrying";
    }).length +
    (preservedLowCompletionFollowup &&
    String(preservedLowCompletionFollowup?.status || "").trim().toLowerCase() === "pending_approval"
      ? 1
      : 0);
  const executableWorkDrained = approvedCount === 0 && activeCount === 0 && queuedCount === 0;
  const executableStrategyWorkBelowBuffer =
    executableStrategyWorkCount < LOW_COMPLETION_EXECUTABLE_BUFFER_THRESHOLD;
  const signals = [];

  if (retryChurnDetected) {
    signals.push(
      `retry churn is active in persisted tasks (active=${activeRetryChurnCount}, recent_multi_attempt_outcomes=${recentRetryChurnCount})`,
    );
  }
  if (queueStarvationDetected) {
    signals.push(
      `queue starvation persists (active=${activeCount}, pending=${pendingApprovalCount}, approved=${approvedCount})`,
    );
  }
  if (strategySaturationDetected && executableWorkDrained && executableStrategyWorkBelowBuffer) {
    const bufferDeficit = LOW_COMPLETION_EXECUTABLE_BUFFER_THRESHOLD - executableStrategyWorkCount;
    signals.push(
      `strategy saturation persisted after executable work drained and executable strategy work fell below buffer (saturated_failed_tasks=${saturatedFailedTasks}, threshold=${STRATEGY_SATURATED_FAILURE_THRESHOLD}, approved_running_strategy=${executableStrategyWorkCount}, buffer=${LOW_COMPLETION_EXECUTABLE_BUFFER_THRESHOLD}, deficit=${bufferDeficit}, queued=${queuedCount}, active=${activeCount}, approved=${approvedCount})`,
    );
  }
  const lowCompletionDrainDetected =
    strategySaturationDetected && executableWorkDrained && executableStrategyWorkBelowBuffer;
  const forcedUnhealthy = retryChurnDetected || queueStarvationDetected || lowCompletionDrainDetected;
  const blockerSummary = pendingApprovalBlockedDetected
    ? `Waiting on ${pendingApprovalCount} pending approval task(s); no executable work is currently queued or running.`
    : "";

  return {
    project: projectKey,
    healthy: !forcedUnhealthy && signals.length === 0,
    summary:
      signals.length > 0
        ? signals.join("; ")
        : blockerSummary || "No persisted retry churn or queue starvation signals are active.",
    strategy_saturation_detected: strategySaturationDetected,
    saturated_failed_tasks: saturatedFailedTasks,
    retry_churn_detected: retryChurnDetected,
    queue_starvation_detected: queueStarvationDetected,
    pending_approval_blocked_detected: pendingApprovalBlockedDetected,
    executable_work_drained: executableWorkDrained,
    recent_failure_count: 0,
    recent_success_count: 0,
    recent_success_rate: 0,
    recent_window_size: 0,
    active_retry_churn_count: activeRetryChurnCount,
    retried_task_count: activeRetryChurnCount,
    queued_count: queuedCount,
    active_count: activeCount,
    executable_strategy_work_count: executableStrategyWorkCount,
    executable_strategy_work_below_buffer: executableStrategyWorkBelowBuffer,
    executable_buffer_threshold: LOW_COMPLETION_EXECUTABLE_BUFFER_THRESHOLD,
    executable_work_count: executableWork.length,
    low_completion_followup_task_id: String(preservedLowCompletionFollowup?.id || "").trim(),
    actionable_count: actionableCount,
    failed_count: failedCount,
    retrying_count: metrics.retrying,
    completion,
    completion_threshold: LOW_COMPLETION_THRESHOLD,
    ...(lowCompletionBlockedDecision || {}),
  };
}

function listLowCompletionQueueDrainExecutableWork(projectTasks) {
  const recentFailedTasks = (Array.isArray(projectTasks) ? projectTasks : [])
    .filter((task) => {
      if (String(task?.status || "").trim().toLowerCase() !== "failed") {
        return false;
      }
      const strategyIdentity = normalizeStrategyIdentity(task);
      if (!strategyIdentity.is_strategy) {
        return true;
      }
      // Allow failed strategy work to seed the bounded follow-up when it points at concrete executable
      // steps, but never recurse on the queue-drain follow-up template/root itself.
      return !(
        strategyIdentity.strategy_template === LOW_COMPLETION_QUEUE_DRAIN_STRATEGY_TEMPLATE ||
        strategyIdentity.original_failed_root_id === LOW_COMPLETION_QUEUE_DRAIN_ROOT_ID
      );
    })
    .sort((left, right) => priorityLearningTimestamp(right).localeCompare(priorityLearningTimestamp(left)))
    .slice(0, STRATEGY_RECENT_FAILURE_WINDOW);

  if (!recentFailedTasks.length) {
    return [];
  }

  return recentFailedTasks
    .map((task) => {
      const targetExecutionContext =
        task && task.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
      const targetFailureContext = task && task.failure_context && typeof task.failure_context === "object" ? task.failure_context : {};
      const planSteps = Array.isArray(targetExecutionContext.plan_steps) ? targetExecutionContext.plan_steps : [];
      const failedStepIndex = Math.max(
        0,
        safeInteger(
          targetExecutionContext.failed_step_index ?? targetFailureContext.failed_step_index,
          0,
        ),
      );
      const nextExecutablePlanStep = [
        planSteps[failedStepIndex],
        targetExecutionContext.failed_step,
        targetFailureContext.failed_step,
        ...planSteps.filter((step, index) => index !== failedStepIndex),
      ]
        .map((step) => sanitizeTaskText(String(step || "").replace(/[`]/g, "")))
        .find(
          (step) =>
            /^(patch|update|extend|implement|add|wire|seed|keep)\b/i.test(step) &&
            /\b[a-z0-9._-]+\/[a-z0-9._/-]+\b/i.test(step),
        );
      if (!nextExecutablePlanStep) {
        return null;
      }
      return {
        task,
        nextExecutablePlanStep,
        affectedFiles: [...new Set(nextExecutablePlanStep.match(/\b[a-z0-9._-]+\/[a-z0-9._/-]+\b/gi) || [])],
      };
    })
    .filter(Boolean)
    .sort((left, right) => {
      const scoreDelta = safeNumber(left?.task?.score, 0) - safeNumber(right?.task?.score, 0);
      if (scoreDelta !== 0) {
        return scoreDelta;
      }
      const timeDelta = priorityLearningTimestamp(right?.task).localeCompare(priorityLearningTimestamp(left?.task));
      if (timeDelta !== 0) {
        return timeDelta;
      }
      return String(left?.task?.title || left?.task?.task || "").localeCompare(String(right?.task?.title || right?.task?.task || ""));
    });
}

function buildLowCompletionQueueDrainBlockedDecision(completion, executableWork) {
  const normalizedCompletion = clampNumber(safeNumber(completion, 0), 0, 1);
  const workItems = Array.isArray(executableWork) ? executableWork : [];
  if (normalizedCompletion >= LOW_COMPLETION_THRESHOLD || workItems.length > 0) {
    return null;
  }
  return {
    status: "blocked_no_executable_work",
    code: "blocked_no_executable_work",
    reason: "First-pass completion stayed below threshold and no executable follow-up work could be derived.",
    completion: normalizedCompletion,
  };
}

function selectLowCompletionQueueDrainFailure(projectTasks) {
  return listLowCompletionQueueDrainExecutableWork(projectTasks)[0] || null;
}

function buildLowCompletionQueueDrainFollowupInput(project, failedTaskContext) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  let contextHint = "Low completion persisted after approved, queued, and active executable work drained.";
  let successCriteria =
    "Improve the lowest-scoring recent failure from persisted task records\nLeave exactly one bounded follow-up task ready for review";
  let reason =
    "First-pass completion is still below threshold and executable work drained, so strategy should queue one bounded system-work follow-up instead of idling.";
  if (failedTaskContext && failedTaskContext.title) {
    const scoreText =
      Number.isFinite(safeNumber(failedTaskContext.score, Number.NaN)) && failedTaskContext.score !== ""
        ? ` (score=${Number(safeNumber(failedTaskContext.score, 0)).toFixed(2)})`
        : "";
    contextHint += ` Lowest-scoring recent failure: ${failedTaskContext.title}${scoreText}`;
    successCriteria =
      `Improve the lowest-scoring recent failure: ${failedTaskContext.title}${scoreText}\nLeave exactly one bounded follow-up task ready for review`;
    reason = `Executable work drained while first-pass completion stayed low, so strategy should improve the lowest-scoring recent failure: ${failedTaskContext.title}${scoreText}.`;
  }
  return {
    project: projectKey,
    title: LOW_COMPLETION_QUEUE_DRAIN_TASK_TITLE,
    task: LOW_COMPLETION_QUEUE_DRAIN_TASK_TITLE,
    category: "stability",
    impact: 8,
    effort: 2,
    confidence: 0.78,
    reason,
    contextHint,
    successCriteria,
    constraints:
      "Stay within codex-agent-system\nKeep the change deterministic and approval-ready\nDo not seed duplicate follow-up work",
    taskIntentSource: "strategy_followup",
    executionProvider: "codex",
    rootSourceTaskId: LOW_COMPLETION_QUEUE_DRAIN_ROOT_ID,
    originalFailedRootId: LOW_COMPLETION_QUEUE_DRAIN_ROOT_ID,
    strategyTemplate: LOW_COMPLETION_QUEUE_DRAIN_STRATEGY_TEMPLATE,
    historyNote:
      "Strategy follow-up was seeded because first-pass completion stayed low after executable work drained.",
  };
}

function listLowCompletionQueueDrainFollowupTasks(project, registryTasks) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const strategyInput = buildLowCompletionQueueDrainFollowupInput(projectKey);
  const strategyIdentity = normalizeStrategyIdentity(strategyInput, strategyInput.title);
  return (Array.isArray(registryTasks) ? registryTasks : [])
    .filter((task) => normalizeTaskProject(task) === projectKey)
    .filter((task) => hasMatchingStrategyIdentity(strategyIdentity, task))
    .slice()
    .sort((left, right) => priorityLearningTimestamp(right).localeCompare(priorityLearningTimestamp(left)));
}

function findLowCompletionQueueDrainFollowupTask(project, registryTasks) {
  return (
    listLowCompletionQueueDrainFollowupTasks(project, registryTasks).find((task) => {
      const status = String(task?.status || "").trim().toLowerCase();
      const executionState = String(task?.execution?.state || "").trim().toLowerCase();
      if (!["pending_approval", "approved", "running"].includes(status) && !["running", "retrying"].includes(executionState)) {
        return false;
      }
      return true;
    }) || null
  );
}

async function ensureLowCompletionQueueDrainFollowup(project, registryTasks, queueTasks, status, taskLogRecords) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  if (projectKey !== STRATEGY_PRIMARY_PROJECT) {
    return { seeded: false, reason: "project_mismatch" };
  }

  const guard = buildStrategyHealthGuard(projectKey, registryTasks, queueTasks, status, taskLogRecords);
  if (
    !guard.strategy_saturation_detected ||
    !guard.executable_work_drained ||
    !guard.executable_strategy_work_below_buffer
  ) {
    return { seeded: false, reason: "guard_inactive", guard };
  }

  const projectTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter(
    (t) => normalizeTaskProject(t) === projectKey,
  );
  const executableWork = listLowCompletionQueueDrainExecutableWork(projectTasks);
  const targetFailure = executableWork[0] || null;
  const targetFailedTask = targetFailure?.task || null;
  const failedTaskContext = targetFailedTask
    ? {
        title: targetFailedTask.title || targetFailedTask.task || "",
        score: targetFailedTask.score,
        failure_context: targetFailedTask.failure_context || null,
      }
    : null;
  const blockedDecision = buildLowCompletionQueueDrainBlockedDecision(guard.completion, executableWork);
  if (blockedDecision) {
    return {
      seeded: false,
      ...blockedDecision,
      guard,
    };
  }
  if (!targetFailure?.nextExecutablePlanStep) {
    return { seeded: false, reason: "no_bounded_failure", guard };
  }

  // Root failure count demotion: if the target failure's root goal has already
  // failed >= ROOT_FAILURE_DEMOTION_THRESHOLD times, shelve the root goal
  // instead of seeding yet another follow-up attempt.
  const targetRootId = sanitizeTaskText(
    targetFailedTask?.root_source_task_id || targetFailedTask?.original_failed_root_id ||
    targetFailedTask?.source_task_id || ""
  );
  if (targetRootId) {
    const demotion = shouldDemoteRoot(targetRootId, projectTasks);
    if (demotion.demoted) {
      await appendLog(
        `Root failure demotion: shelved root "${targetRootId}" after ${demotion.count} failures (threshold=${demotion.threshold}). No further follow-ups will be seeded.`,
      );
      return { seeded: false, reason: "root_demoted", guard, rootId: targetRootId, failureCount: demotion.count };
    }
  }

  const nextExecutablePlanStep = targetFailure.nextExecutablePlanStep;
  const affectedFiles = targetFailure.affectedFiles;

  return runTaskRegistryMutation(async () => {
    const persistedTasks = await readTaskRegistry();
    const preservedTask = findLowCompletionQueueDrainFollowupTask(projectKey, persistedTasks);
    if (preservedTask) {
      return { seeded: false, reason: "preserved", guard, task: preservedTask };
    }
    const input = buildLowCompletionQueueDrainFollowupInput(projectKey, failedTaskContext);
    input.title = LOW_COMPLETION_QUEUE_DRAIN_TASK_TITLE;
    input.task = LOW_COMPLETION_QUEUE_DRAIN_TASK_TITLE;
    input.reason = nextExecutablePlanStep
      ? `${sanitizeTaskText(input.reason)} Target step: ${nextExecutablePlanStep}`
      : input.reason;
    input.contextHint = `${sanitizeTaskText(input.contextHint)} Next executable step: ${nextExecutablePlanStep}`;
    input.successCriteria =
      "Seed exactly one bounded system-work follow-up task\nPreserve current storage formats and routing behavior";
    if (affectedFiles.length) {
      input.affectedFiles = affectedFiles.join("\n");
    }
    const createResult = await createTaskRegistryItem(input);
    if (createResult.ok) {
      await appendLog(
        `Seeded 1 deterministic strategy follow-up for ${projectKey} after low completion and executable work drained.`,
      );
      return { seeded: true, count: 1, reason: "created", guard, tasks: [createResult.task] };
    }
    if (createResult.status !== 409) {
      await appendLog(
        `Failed to seed low-completion queue-drain follow-up for ${projectKey}: ${createResult.error || "unknown error"}`,
        "WARN",
      );
    }
    return { seeded: false, reason: "duplicate", guard };
  });
}

async function readTaskRegistrySummarySnapshot() {
  // Dashboard registry read flow: readTaskRegistry() loads and normalizes the shared tasks payload, then this
  // helper layers queue/status/task-log state into one snapshot that /api/dashboard, /api/status, /api/metrics,
  // and /api/task-registry can reuse. Under the current fixed-poll UI, that dashboard_read_path is the
  // highest-frequency reread surface, so this snapshot boundary is the smallest safe reuse point for either a
  // shared loaded registry snapshot or any derived summary that should stay consistent across those responses.
  const registryTargets = taskRegistryTargets();
  const [taskRegistrySignature, queueSignature] = await Promise.all([
    buildTaskRegistryReadCacheSignature(registryTargets),
    buildQueueReadCacheSignature(),
  ]);
  const summarySignature = [
    taskRegistrySignature,
    queueSignature,
    syncFileSignature(PATHS.status),
    syncFileSignature(PATHS.taskLog),
  ].join("|");
  if (taskRegistrySummarySnapshotCache && taskRegistrySummarySnapshotCache.signature === summarySignature) {
    return taskRegistrySummarySnapshotCache.snapshot;
  }

  const [registryTasks, queueTasks, status, taskLog] = await Promise.all([
    readTaskRegistry(),
    readQueueTasks(),
    readStatus(),
    readText(PATHS.taskLog),
  ]);
  const taskRegistryPayloadBytes = taskRegistryPayloadBytesForTargets(registryTargets);
  const taskRegistryPressureSources = buildTaskRegistryPressureSources(registryTargets);

  const snapshot = {
    tasks: registryTasks,
    queueTasks,
    status,
    taskLog,
    taskLogRecords: parseJsonLines(taskLog),
    taskRegistryPayloadBytes,
    taskRegistryPressureSources,
  };
  taskRegistrySummarySnapshotCache = {
    signature: summarySignature,
    snapshot,
  };
  return snapshot;
}

function buildProjectMemorySummary(project, registryTasks, taskLogRecords, memoryFiles) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const projectRegistryTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter(
    (task) => normalizeTaskProject(task) === projectKey,
  );
  const projectRecords = (Array.isArray(taskLogRecords) ? taskLogRecords : []).filter(
    (record) => normalizeRecordProject(record) === projectKey,
  );
  const contextRaw = typeof memoryFiles?.context === "string" ? memoryFiles.context : "";
  const decisionsRaw = typeof memoryFiles?.decisions === "string" ? memoryFiles.decisions : "";
  const learningsRaw = typeof memoryFiles?.learnings === "string" ? memoryFiles.learnings : "";
  const knowledgePayload =
    memoryFiles?.knowledge && typeof memoryFiles.knowledge === "object" ? memoryFiles.knowledge : { rules: [] };
  const knowledgeRules = Array.isArray(knowledgePayload.rules) ? knowledgePayload.rules : [];
  const knowledgeMatches = knowledgeRules.filter((rule) =>
    JSON.stringify(rule || {})
      .toLowerCase()
      .includes(projectKey),
  );
  const tasksWithHistory = projectRegistryTasks.filter((task) => Array.isArray(task?.history) && task.history.length > 0);
  const taskHistoryCount = tasksWithHistory.reduce(
    (total, task) => total + (Array.isArray(task?.history) ? task.history.length : 0),
    0,
  );

  return {
    registry_task_count: projectRegistryTasks.length,
    log_record_count: projectRecords.length,
    tasks_with_history_count: tasksWithHistory.length,
    task_history_count: taskHistoryCount,
    context_mentions: countProjectTextMentions(contextRaw, projectKey),
    decisions_mentions: countProjectTextMentions(decisionsRaw, projectKey),
    learnings_mentions: countProjectTextMentions(learningsRaw, projectKey),
    knowledge_rule_count: knowledgeMatches.length,
    reusable_patterns: collectReusablePatternRecords(projectKey, registryTasks, taskLogRecords, memoryFiles),
    memory_files_present: {
      context: Boolean(contextRaw.trim()),
      decisions: Boolean(decisionsRaw.trim()),
      learnings: Boolean(learningsRaw.trim()),
      knowledge: knowledgeRules.length > 0,
    },
  };
}

function formatTaskRegistryPressureBytes(value) {
  const total = Math.max(safeInteger(value, 0), 0);
  if (total <= 0) {
    return "0 B";
  }
  if (total >= 1024 * 1024) {
    return `${(total / (1024 * 1024)).toFixed(total >= 10 * 1024 * 1024 ? 0 : 1)} MiB`;
  }
  if (total >= 1024) {
    return `${(total / 1024).toFixed(total >= 10 * 1024 ? 0 : 1)} KiB`;
  }
  return `${Math.floor(total)} B`;
}

function formatTaskRegistryPressureSourceLabel(filePath) {
  const normalized = String(filePath || "").trim();
  if (!normalized) {
    return "";
  }
  const parts = path.normalize(normalized).split(path.sep).filter(Boolean);
  if (!parts.length) {
    return normalized;
  }
  if (parts.length === 1) {
    return parts[0];
  }
  return `${parts[parts.length - 2]}/${parts[parts.length - 1]}`;
}

function buildProjectTaskRegistryPressureSummary(project, taskRegistryPressureSignal) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const sources = Array.isArray(taskRegistryPressureSignal?.task_registry_pressure_sources)
    ? taskRegistryPressureSignal.task_registry_pressure_sources
    : [];
  const totalBytes = Math.max(safeInteger(taskRegistryPressureSignal?.task_registry_payload_bytes, 0), 0);
  const primarySource =
    taskRegistryPressureSignal?.task_registry_pressure_primary_source
    && typeof taskRegistryPressureSignal.task_registry_pressure_primary_source === "object"
      ? taskRegistryPressureSignal.task_registry_pressure_primary_source
      : null;
  const matchedSource = sources.find((entry) => {
    const primaryProject = sanitizeProjectName(entry?.project || "");
    const sharedProjects = Array.isArray(entry?.shared_projects)
      ? entry.shared_projects.map((sharedProject) => sanitizeProjectName(sharedProject || "")).filter(Boolean)
      : [];
    return primaryProject === projectKey || sharedProjects.includes(projectKey);
  }) || null;
  const dominant = Boolean(
    matchedSource
    && primarySource
    && path.resolve(String(primarySource.file || "")) === path.resolve(String(matchedSource.file || "")),
  );
  const payloadBytes = matchedSource ? Math.max(safeInteger(matchedSource.payload_bytes, 0), 0) : 0;
  const shareOfTotal = matchedSource && totalBytes > 0
    ? Number((matchedSource.payload_bytes / totalBytes).toFixed(3))
    : 0;
  const sharePercent = Math.max(0, Math.round(shareOfTotal * 100));
  const shareLabel = shareOfTotal > 0
    ? (sharePercent > 0 ? `${sharePercent}% of dashboard payload` : "<1% of dashboard payload")
    : "";
  const sharedProjects = matchedSource && Array.isArray(matchedSource.shared_projects)
    ? matchedSource.shared_projects
      .map((sharedProject) => sanitizeProjectName(sharedProject || ""))
      .filter(Boolean)
    : [];
  const peerProjects = sharedProjects.filter((sharedProject) => sharedProject !== projectKey);
  const summaryParts = [];
  if (payloadBytes > 0) {
    summaryParts.push(formatTaskRegistryPressureBytes(payloadBytes));
  }
  if (shareLabel) {
    summaryParts.push(shareLabel);
  }
  if (peerProjects.length) {
    summaryParts.push(`shared with ${peerProjects.join(", ")}`);
  }

  return {
    detected: Boolean(taskRegistryPressureSignal?.task_registry_pressure_detected) && Boolean(matchedSource),
    dominant,
    payload_bytes: payloadBytes,
    share_of_total: shareOfTotal,
    file: matchedSource ? String(matchedSource.file || "") : "",
    shared_projects: sharedProjects,
    headline: matchedSource ? (dominant ? "Dominant registry pressure" : "Registry pressure contributor") : "",
    summary: matchedSource ? summaryParts.join(" · ") : "",
    source_label: matchedSource ? formatTaskRegistryPressureSourceLabel(matchedSource.file || "") : "",
  };
}

function defaultProjectOverviewSignal() {
  return {
    active: false,
    source: "none",
    kind: "none",
    title: "",
    summary: "",
    detail: "",
    command: "",
  };
}

async function buildProjectSummaries() {
  const [
    projects,
    registryTasks,
    queueTasks,
    status,
    taskLog,
    context,
    decisions,
    learnings,
    knowledge,
    selfImproveRun,
    metricsUpdatedAt,
    selfImproveRunUpdatedAt,
  ] = await Promise.all([
    listProjects(),
    readTaskRegistry(),
    readQueueTasks(),
    readStatus(),
    readText(PATHS.taskLog),
    readText(PROJECT_MEMORY_FILES.context),
    readText(PROJECT_MEMORY_FILES.decisions),
    readText(PROJECT_MEMORY_FILES.learnings),
    readJsonFile(PROJECT_MEMORY_FILES.knowledge, { rules: [] }),
    readJsonFile(PATHS.selfImproveRun, {}),
    readFileModifiedAt(PATHS.metrics),
    readFileModifiedAt(PATHS.selfImproveRun),
  ]);
  const taskLogRecords = parseJsonLines(taskLog);
  const knownProjects = new Set(Array.isArray(projects) ? projects : []);

  for (const task of Array.isArray(registryTasks) ? registryTasks : []) {
    knownProjects.add(normalizeTaskProject(task));
  }
  for (const record of taskLogRecords) {
    knownProjects.add(normalizeRecordProject(record));
  }
  for (const entry of Array.isArray(queueTasks) ? queueTasks : []) {
    knownProjects.add(sanitizeProjectName(entry?.project || "") || "codex-agent-system");
  }
  if (sanitizeProjectName(status?.project || "")) {
    knownProjects.add(sanitizeProjectName(status.project));
  }
  if (!knownProjects.size) {
    knownProjects.add("codex-agent-system");
  }

  const memoryFiles = {
    context,
    decisions,
    learnings,
    knowledge,
  };
  const taskRegistryPressureSignal = buildTaskRegistryPressureSignal(registryTasks, {
    task_registry_payload_bytes: taskRegistryPayloadBytesForTargets(taskRegistryTargets()),
    task_registry_pressure_sources: buildTaskRegistryPressureSources(taskRegistryTargets()),
  });

  return [...knownProjects]
    .filter(Boolean)
    .sort()
    .map((project) => {
      const taskRegistryPressureSummary = buildProjectTaskRegistryPressureSummary(project, taskRegistryPressureSignal);
      const selfImproveSummary = buildProjectSelfImproveSummary(project, selfImproveRun, {
        metricsUpdatedAt,
        artifactUpdatedAt: selfImproveRunUpdatedAt,
      });

      return {
        project,
        health_metrics: buildProjectHealthMetrics(project, registryTasks, taskLogRecords),
        queue: compactQueueState(project, queueTasks, registryTasks, status),
        memory_summary: buildProjectMemorySummary(project, registryTasks, taskLogRecords, memoryFiles),
        task_registry_pressure: taskRegistryPressureSummary,
        self_improve_summary: selfImproveSummary,
        project_overview_signal: buildProjectOverviewSignal(taskRegistryPressureSummary, selfImproveSummary),
        status_summary: {
          current_status: sanitizeTaskText(
            (sanitizeProjectName(status?.project || "") || "") === project ? String(status?.state || "").toLowerCase() : "",
          ),
          current_task: sanitizeTaskText(
            (sanitizeProjectName(status?.project || "") || "") === project ? status?.task || "" : "",
          ),
          updated_at:
            (sanitizeProjectName(status?.project || "") || "") === project && typeof status?.updated_at === "string"
              ? status.updated_at
              : "",
        },
      };
    });
}

function readTlsCredentials() {
  try {
    return {
      key: fs.readFileSync(TLS_KEY_FILE, "utf8"),
      cert: fs.readFileSync(TLS_CERT_FILE, "utf8"),
    };
  } catch (error) {
    throw new Error(
      `HTTPS requested but TLS files could not be read: key=${TLS_KEY_FILE} cert=${TLS_CERT_FILE} (${error.message})`,
    );
  }
}

async function readTaskRegistry() {
  const targets = taskRegistryTargets();
  const cachedSignature = await buildTaskRegistryReadCacheSignature(targets);
  if (taskRegistryReadCache && taskRegistryReadCache.signature === cachedSignature) {
    return taskRegistryReadCache.tasks;
  }

  const payload = await readTaskRegistryPayload(targets);
  const tasks = Array.isArray(payload.tasks) ? payload.tasks : [];
  const normalizedTasks = tasks
    .filter((task) => task && typeof task === "object" && typeof task.title === "string")
    .map((task, index) => {
      const title = String(task.title || "").trim();
      const fallbackId = `task-${String(index + 1).padStart(3, "0")}-${taskSlug(title) || "untitled"}`;
      const createdAt =
        typeof task.created_at === "string" && task.created_at.trim() ? task.created_at.trim() : "";
      const updatedAt =
        typeof task.updated_at === "string" && task.updated_at.trim() ? task.updated_at.trim() : createdAt;
      const history = Array.isArray(task.history)
        ? task.history
            .filter((entry) => entry && typeof entry === "object")
            .map((entry) => ({
              ...entry,
              action: typeof entry.action === "string" ? entry.action : "",
              at: typeof entry.at === "string" ? entry.at : "",
              from_status: typeof entry.from_status === "string" ? entry.from_status : "",
              note: typeof entry.note === "string" ? entry.note : "",
              project: typeof entry.project === "string" ? entry.project : "",
              queue_task: typeof entry.queue_task === "string" ? entry.queue_task : "",
              to_status: typeof entry.to_status === "string" ? entry.to_status : "",
            }))
        : [];
      const executionContext =
        task.execution_context && typeof task.execution_context === "object" ? task.execution_context : null;
      const failureContext =
        task.failure_context && typeof task.failure_context === "object" ? task.failure_context : null;
      const rawExecution = task.execution && typeof task.execution === "object" ? task.execution : null;
      const rawProviderSelection =
        task.provider_selection && typeof task.provider_selection === "object" ? task.provider_selection : {};
      const executionProvider = taskExecutionProvider(task) || normalizeProviderName(rawExecution?.provider) || "codex";
      const totalStepAttempts = Math.max(
        0,
        rawExecution && rawExecution.total_step_attempts != null
          ? safeInteger(rawExecution.total_step_attempts, 0)
          : executionContext && executionContext.total_step_attempts != null
            ? safeInteger(executionContext.total_step_attempts, 0)
            : failureContext && failureContext.total_step_attempts != null
              ? safeInteger(failureContext.total_step_attempts, 0)
              : 0,
      );
      const providerSelection = {
        selected: executionProvider,
        source: typeof rawProviderSelection.source === "string" && rawProviderSelection.source.trim()
          ? rawProviderSelection.source.trim()
          : executionProvider === "codex"
            ? "default"
            : "task_registry",
        reason:
          typeof rawProviderSelection.reason === "string" && rawProviderSelection.reason.trim()
            ? rawProviderSelection.reason.trim()
            : executionProvider === "codex"
              ? "Default provider is Codex when no explicit Claude hint is present."
              : `Provider is pinned on the task: ${executionProvider}.`,
      };
      const taskProject = resolveTaskProject(task);
      const taskCategory = typeof task.category === "string" ? task.category : "code_quality";
      const taskIntent = normalizeTaskIntentRecord(task, title, taskProject, taskCategory);
      const executionBrief =
        task.execution_brief && typeof task.execution_brief === "object"
          ? buildApprovalExecutionBrief({
              approvedAt: task.execution_brief.approved_at,
              project: task.execution_brief.project,
              queueTask: task.execution_brief.queue_task,
              provider: task.execution_brief.provider,
              queueStatus: task.execution_brief.status,
              taskIntent: task.execution_brief.task_intent,
              taskShape: {
                editable_files: task.execution_brief.editable_files,
                frozen_files: task.execution_brief.frozen_files,
                frozen_verify_command: task.execution_brief.frozen_verify_command,
              },
            })
          : null;
      const approvalExecutionBrief =
        task.approval_execution_brief && typeof task.approval_execution_brief === "object"
          ? buildApprovalExecutionSnapshot({
              approvedAt: task.approval_execution_brief.approved_at,
              project: task.approval_execution_brief.project,
              queueTask: task.approval_execution_brief.queue_task,
              provider: task.approval_execution_brief.provider,
              queueStatus: task.approval_execution_brief.queue_status,
            })
          : null;
      const queueHandoff = task.queue_handoff && typeof task.queue_handoff === "object"
        ? {
            ...task.queue_handoff,
            at: typeof task.queue_handoff.at === "string" ? task.queue_handoff.at : "",
            project: resolveTaskProject({ queue_handoff: task.queue_handoff }, taskProject),
            task: sanitizeTaskText(task.queue_handoff.task || title),
            status: typeof task.queue_handoff.status === "string" ? task.queue_handoff.status : "",
            provider: normalizeProviderName(task.queue_handoff.provider || executionProvider) || executionProvider,
            ...(taskIntent ? { task_intent: taskIntent } : {}),
          }
        : null;
      const execution = rawExecution
        ? {
            ...rawExecution,
            attempt: safeInteger(rawExecution.attempt, 0),
            current_step: sanitizeTaskText(rawExecution.current_step || ""),
            current_step_index: safeInteger(rawExecution.current_step_index, 0),
            max_retries: safeInteger(rawExecution.max_retries, 0),
            total_step_attempts: totalStepAttempts,
            result: typeof rawExecution.result === "string" ? rawExecution.result : "",
            state: typeof rawExecution.state === "string" ? rawExecution.state : "",
            updated_at: typeof rawExecution.updated_at === "string" ? rawExecution.updated_at : "",
            will_retry: Boolean(rawExecution.will_retry),
            provider: executionProvider,
            lane: typeof rawExecution.lane === "string" ? rawExecution.lane : "",
            lease_state: typeof rawExecution.lease_state === "string" ? rawExecution.lease_state : "",
            lease_claimed_at: typeof rawExecution.lease_claimed_at === "string" ? rawExecution.lease_claimed_at : "",
            lease_released_at: typeof rawExecution.lease_released_at === "string" ? rawExecution.lease_released_at : "",
          }
        : null;
      const historyPreview = history.slice(-2).reverse();
      const taskShape =
        task.task_shape && typeof task.task_shape === "object"
          ? task.task_shape
          : buildTaskShape({
              title,
              category: typeof task.category === "string" ? task.category : "code_quality",
            });

      return {
        ...task,
        id: typeof task.id === "string" && task.id.trim() ? task.id.trim() : fallbackId,
        title,
        category: typeof task.category === "string" ? task.category : "code_quality",
        confidence: Number(task.confidence || 0),
        created_at: createdAt,
        execution,
        execution_brief: executionBrief,
        ...(approvalExecutionBrief ? { approval_execution_brief: approvalExecutionBrief } : {}),
        execution_context: executionContext,
        execution_provider: executionProvider,
        effort: Number(task.effort || 0),
        failure_context: failureContext,
        history,
        history_preview: historyPreview,
        impact: Number(task.impact || 0),
        last_history_entry: history.length ? history[history.length - 1] : null,
        provider_selection: providerSelection,
        project: taskProject,
        queue_handoff: queueHandoff,
        score: Number(task.score || 0),
        status: typeof task.status === "string" ? task.status : "pending_approval",
        task_shape: taskShape,
        task_intent: taskIntent,
        updated_at: updatedAt,
        depends_on: normalizeDependencyTaskIds(task.depends_on || task.dependsOn),
        board_scope: taskBoardScope({
          ...task,
          status: typeof task.status === "string" ? task.status : "pending_approval",
          task_intent: taskIntent,
        }),
      };
    })
    .sort((left, right) => Number(right.score || 0) - Number(left.score || 0));
  const finalSignature = await buildTaskRegistryReadCacheSignature(targets);
  taskRegistryReadCache = {
    signature: finalSignature,
    tasks: normalizedTasks,
  };
  const tasksById = buildTaskIndexById(normalizedTasks);
  return normalizedTasks.map((task, index) => {
    const dependencyState = buildTaskDependencyState(task, tasksById);
    const saturated = isExhaustedRetryFailedTask(task);
    const runtimeActivity = readLatestTaskActivity(task);
    const runtimeActivityHistory = readRecentTaskActivity(task, 3);
    const runtimeSession = readRuntimeSessionForTask(task);
    return {
      ...task,
      active_work: buildActiveWorkSummary(task),
      dependency_state: dependencyState,
      depends_on: dependencyState.depends_on,
      runtime_activity:
        runtimeActivity && typeof runtimeActivity === "object"
          ? {
              at: typeof runtimeActivity.at === "string" ? runtimeActivity.at : "",
              type: typeof runtimeActivity.type === "string" ? runtimeActivity.type : "",
              summary: sanitizeTaskText(runtimeActivity.summary || ""),
              detail: sanitizeTaskText(runtimeActivity.detail || ""),
            }
          : null,
      runtime_activity_history: Array.isArray(runtimeActivityHistory)
        ? runtimeActivityHistory.map((item) => ({
            at: typeof item?.at === "string" ? item.at : "",
            type: typeof item?.type === "string" ? item.type : "",
            summary: sanitizeTaskText(item?.summary || ""),
            detail: sanitizeTaskText(item?.detail || ""),
          }))
        : [],
      runtime_session: runtimeSession,
      rank: index + 1,
      strategy_state: {
        source: strategyTaskSource(task),
        is_saturable: isSaturableStrategyTask(task),
        failed_equivalent_count: saturated ? 1 : 0,
        saturated,
      },
    };
  });
}

function summarizeTaskRegistry(tasks, authHealth = null, options = {}) {
  const taskRegistryPressureSignal =
    options.taskRegistryPressureSignal && typeof options.taskRegistryPressureSignal === "object"
      ? options.taskRegistryPressureSignal
      : buildTaskRegistryPressureSignal(tasks, options);
  const byStatus = {
    pending_approval: 0,
    approved: 0,
    completed: 0,
    other: 0,
  };
  const byCategory = {};
  const providerCoverage = {
    codex: 0,
    claude: 0,
    unknown: 0,
  };
  let tasksWithHistory = 0;
  let totalHistoryEntries = 0;
  let queueHandoffs = 0;
  let rejectedTasks = 0;
  let splitTasks = 0;
  let tasksWithIntent = 0;
  let lastRecordedEventAt = "";
  let saturatedFailedTaskCount = 0;
  let topSaturatedFailedTask = null;

  for (const task of tasks) {
    const status = String(task.status || "").toLowerCase();
    if (status === "pending_approval" || status === "approved" || status === "completed") {
      byStatus[status] += 1;
    } else {
      byStatus.other += 1;
    }

    const category = String(task.category || "code_quality");
    byCategory[category] = (byCategory[category] || 0) + 1;

    const provider = normalizeProviderName(task.execution_provider || task.provider_selection?.selected);
    if (provider) {
      providerCoverage[provider] += 1;
    } else {
      providerCoverage.unknown += 1;
    }

    const history = Array.isArray(task.history) ? task.history : [];
    if (history.length) {
      tasksWithHistory += 1;
      totalHistoryEntries += history.length;
    }

    if (task.queue_handoff && typeof task.queue_handoff === "object") {
      queueHandoffs += 1;
      const handoffAt = typeof task.queue_handoff.at === "string" ? task.queue_handoff.at.trim() : "";
      if (handoffAt && (!lastRecordedEventAt || handoffAt > lastRecordedEventAt)) {
        lastRecordedEventAt = handoffAt;
      }
    }

    if (task.task_intent && typeof task.task_intent === "object") {
      tasksWithIntent += 1;
    }

    if (task.strategy_state?.saturated === true) {
      saturatedFailedTaskCount += 1;
      const candidateTimestamp = String(task.failed_at || task.updated_at || task.created_at || "").trim();
      const currentTimestamp = String(
        topSaturatedFailedTask?.failed_at || topSaturatedFailedTask?.updated_at || topSaturatedFailedTask?.created_at || "",
      ).trim();
      if (!topSaturatedFailedTask || candidateTimestamp > currentTimestamp) {
        topSaturatedFailedTask = task;
      }
    }

    if (status === "rejected") {
      rejectedTasks += 1;
    }
    if (status === "split") {
      splitTasks += 1;
    }

    for (const candidate of [
      task.updated_at,
      task.created_at,
      task.approved_at,
      task.completed_at,
      task.failed_at,
      task.rejected_at,
      task.split_at,
      ...history.map((entry) => entry?.at),
    ]) {
      const timestamp = typeof candidate === "string" ? candidate.trim() : "";
      if (timestamp && (!lastRecordedEventAt || timestamp > lastRecordedEventAt)) {
        lastRecordedEventAt = timestamp;
      }
    }
  }

  const topTask = tasks[0] || null;
  const topApprovedTask = tasks.find((task) => task.status === "approved") || null;
  const oldestPendingTask = tasks
    .filter((task) => task.status === "pending_approval" && task.created_at)
    .sort((left, right) => String(left.created_at).localeCompare(String(right.created_at)))[0] || null;
  const pendingApprovalTasks = tasks.filter((task) => task.status === "pending_approval");
  const pendingApprovalCandidates = pendingApprovalTasks.filter(
    (task) => !(task.dependency_state && typeof task.dependency_state === "object" && task.dependency_state.blocked === true),
  );
  const prioritizedPendingTasks = (pendingApprovalCandidates.length ? pendingApprovalCandidates : pendingApprovalTasks)
    .slice()
    .sort(
      (left, right) =>
        String(left.created_at || left.updated_at || "").localeCompare(String(right.created_at || right.updated_at || "")) ||
        String(left.updated_at || "").localeCompare(String(right.updated_at || "")) ||
        String(left.id || "").localeCompare(String(right.id || "")),
    );
  const topPendingTask = prioritizedPendingTasks[0] || null;
  const topPendingSaturationRecovery =
    topPendingTask && topPendingTask.saturation_recovery && typeof topPendingTask.saturation_recovery === "object"
      ? {
          kind: sanitizeTaskText(topPendingTask.saturation_recovery.kind || ""),
          replaces_task_id: sanitizeTaskText(topPendingTask.saturation_recovery.replaces_task_id || ""),
          replaces_title: sanitizeTaskText(topPendingTask.saturation_recovery.replaces_title || ""),
          replaces_strategy_template: sanitizeTaskText(topPendingTask.saturation_recovery.replaces_strategy_template || ""),
          replaces_category: sanitizeTaskText(topPendingTask.saturation_recovery.replaces_category || ""),
        }
      : null;
  const singlePendingSaturationRecovery = pendingApprovalTasks.length === 1 && topPendingSaturationRecovery;
  const topPendingRecoveryTitle = sanitizeTaskText(topPendingSaturationRecovery?.replaces_title || "");
  const topPendingRecoveryTemplate = sanitizeTaskText(topPendingSaturationRecovery?.replaces_strategy_template || "");
  const approvalRecommendation = topPendingTask
    ? {
        task_id: String(topPendingTask.id || ""),
        title: String(topPendingTask.title || ""),
        pending_approval_count: pendingApprovalTasks.length,
        blocked_pending_approval_count: Math.max(pendingApprovalTasks.length - pendingApprovalCandidates.length, 0),
        created_at: String(topPendingTask.created_at || ""),
        updated_at: String(topPendingTask.updated_at || ""),
        saturation_recovery: topPendingSaturationRecovery,
        reason:
          pendingApprovalTasks.length > 1
            ? "Review the oldest pending approval first so operator-held backlog clears deterministically."
            : singlePendingSaturationRecovery
              ? `Review the saturation-recovery task: ${topPendingTask.title}.`
              : "Review the only pending approval task.",
      }
    : null;
  const topCategoryEntry = Object.entries(byCategory).sort(
    (left, right) => right[1] - left[1] || left[0].localeCompare(right[0]),
  )[0] || null;

  let nextAction = {
    state: "idle",
    message: "No tracked tasks yet.",
  };
  const authBlocked = Boolean(authHealth?.blocks_queue);
  if (authHealth?.active && topApprovedTask) {
    nextAction = {
      state: "blocked",
      message: `Resolve Codex auth before executing: ${topApprovedTask.title}`,
    };
  } else if (authHealth?.active && topPendingTask) {
    nextAction = {
      state: "blocked",
      message: "Codex auth is blocked; avoid approving more work until it recovers.",
    };
  } else if (topApprovedTask) {
    nextAction = {
      state: "ready",
      message: `Execute approved task: ${topApprovedTask.title}`,
    };
  } else if (topPendingTask) {
    const pendingApprovalCount = Math.max(1, safeInteger(approvalRecommendation?.pending_approval_count, byStatus.pending_approval));
    nextAction = {
      state: "approval",
      message:
        pendingApprovalCount > 1
          ? `Review oldest pending task first: ${topPendingTask.title} (${pendingApprovalCount} pending approvals).`
          : singlePendingSaturationRecovery
            ? `Review saturation recovery: ${topPendingTask.title}`
            : `Review pending task: ${topPendingTask.title}`,
    };
  } else if (topSaturatedFailedTask) {
    nextAction = {
      state: "strategy",
      message: `Choose a different bounded experiment than: ${topSaturatedFailedTask.title}`,
    };
  } else if (topTask) {
    nextAction = {
      state: "tracking",
      message: `Review tracked task state: ${topTask.title}`,
    };
  }

  return {
    total: tasks.length,
    byStatus,
    byCategory,
    oldestPendingTask,
    topCategory: topCategoryEntry ? { name: topCategoryEntry[0], count: topCategoryEntry[1] } : null,
    topTask,
    topPendingTask,
    topApprovedTask,
    approvalRecommendation,
    nextAction,
    strategy: {
      strategy_saturation_detected: saturatedFailedTaskCount >= STRATEGY_SATURATED_FAILURE_THRESHOLD,
      saturated_failed_tasks: saturatedFailedTaskCount,
      topSaturatedFailedTask,
    },
    security: {
      auth_status: authBlocked ? "blocked" : authHealth?.reason ? "recovered" : "healthy",
      auth_blocked: authBlocked,
      auth_reason: String(authHealth?.reason || authHealth?.message || ""),
      blocked_approved_tasks: authBlocked ? byStatus.approved : 0,
      provider_coverage: providerCoverage,
    },
    audit: {
      tasks_with_history: tasksWithHistory,
      tasks_without_history: Math.max(tasks.length - tasksWithHistory, 0),
      total_history_entries: totalHistoryEntries,
      queue_handoffs: queueHandoffs,
      last_recorded_event_at: lastRecordedEventAt,
    },
    governance: {
      pending_approval_tasks: byStatus.pending_approval,
      approved_tasks: byStatus.approved,
      rejected_tasks: rejectedTasks,
      split_tasks: splitTasks,
      tasks_with_intent: tasksWithIntent,
    },
    taskRegistryPressure: {
      detected: taskRegistryPressureSignal.task_registry_pressure_detected,
      payload_bytes: taskRegistryPressureSignal.task_registry_payload_bytes,
      primary_surface: taskRegistryPressureSignal.task_registry_pressure_primary_surface,
      primary_source: taskRegistryPressureSignal.task_registry_pressure_primary_source,
      sources: taskRegistryPressureSignal.task_registry_pressure_sources,
    },
  };
}

function applyRuntimeReloadGateToTaskSummary(summary, runtimeDashboardStatus = null) {
  if (!summary || typeof summary !== "object") {
    return summary;
  }
  const restartRequired = runtimeDashboardStatus?.runtime?.reload_drift?.restart_needed === true;
  if (!restartRequired || !summary.topPendingTask) {
    return summary;
  }
  return {
    ...summary,
    nextAction: {
      state: "blocked",
      message: "Restart the dashboard/runtime before approving more work.",
    },
    security: {
      ...(summary.security && typeof summary.security === "object" ? summary.security : {}),
      runtime_reload_blocked: true,
    },
  };
}

function activeTaskSortKey(task) {
  const state = String(task?.execution?.state || task?.state || "").toLowerCase();
  const lane = sanitizeTaskText(task?.execution?.lane || task?.lane || "");
  const title = sanitizeTaskText(task?.title || "");
  const stateRank = state === "running" ? "0" : state === "retrying" ? "1" : "2";
  return `${stateRank}:${lane}:${title}`;
}

function activeTaskWorkLabel(task) {
  const execution = task?.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext =
    task?.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const currentStep = sanitizeTaskText(execution.current_step || executionContext.current_step || "");
  if (currentStep) {
    return currentStep;
  }

  const planSteps = Array.isArray(executionContext.plan_steps) ? executionContext.plan_steps : [];
  const completedSteps = Math.max(0, safeInteger(executionContext.completed_steps, 0));
  const nextPlannedStep = sanitizeTaskText(planSteps[completedSteps] || "");
  if (nextPlannedStep) {
    return nextPlannedStep;
  }

  if (String(execution.state || "").toLowerCase() === "retrying") {
    return "Retry queued";
  }
  return "In progress";
}

function activeTaskOwnership(task, provider) {
  const execution = task?.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext =
    task?.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const worker = sanitizeTaskText(execution.worker || executionContext.worker || execution.lane || "");
  const owner = sanitizeTaskText(task?.owner || execution.owner || executionContext.owner || worker || provider);
  return {
    worker,
    owner: owner || provider,
  };
}

function activeTaskProgress(task) {
  const execution = task?.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext =
    task?.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const planSteps = Array.isArray(executionContext.plan_steps) ? executionContext.plan_steps : [];
  const totalSteps = Math.max(0, safeInteger(executionContext.step_count, planSteps.length || 0));
  const completedSteps = clampNumber(safeInteger(executionContext.completed_steps, 0), 0, totalSteps || Number.MAX_SAFE_INTEGER);
  const currentStepLabel = activeTaskWorkLabel(task);
  let progressLabel = "Progress unavailable";
  if (totalSteps > 0) {
    progressLabel = `${completedSteps}/${totalSteps} steps`;
  } else if (String(execution.state || "").toLowerCase() === "retrying") {
    progressLabel = "Retry queued";
  } else if (currentStepLabel !== "In progress") {
    progressLabel = "Step in progress";
  }

  return {
    current_work_label: currentStepLabel,
    completed_steps: totalSteps > 0 ? completedSteps : 0,
    total_steps: totalSteps,
    label: progressLabel,
  };
}

function sanitizeActivityPathToken(value, fallback) {
  const normalized = String(value || "").trim().replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^[-._]+|[-._]+$/g, "");
  return normalized || fallback;
}

function readTaskActivityPath(task) {
  if (!task || typeof task !== "object") {
    return null;
  }
  const project = sanitizeProjectName(resolveTaskProject(task)) || "unknown-project";
  const taskId = sanitizeActivityPathToken(task.id, "");
  const lane = sanitizeActivityPathToken(task?.execution?.lane, "runtime");
  const activityKey = taskId || lane;
  if (!activityKey) {
    return null;
  }
  return path.join(PATHS.taskActivity, project, `${activityKey}.jsonl`);
}

function readLatestTaskActivity(task) {
  const filePath = readTaskActivityPath(task);
  if (!filePath) {
    return null;
  }
  let contents = "";
  try {
    contents = fs.readFileSync(filePath, "utf8");
  } catch {
    return null;
  }
  const lines = contents.trim().split("\n").filter(Boolean);
  if (!lines.length) {
    return null;
  }
  try {
    const payload = JSON.parse(lines[lines.length - 1]);
    return payload && typeof payload === "object" ? payload : null;
  } catch {
    return null;
  }
}

function readRecentTaskActivity(task, limit = 3) {
  const filePath = readTaskActivityPath(task);
  if (!filePath) {
    return [];
  }
  let contents = "";
  try {
    contents = fs.readFileSync(filePath, "utf8");
  } catch {
    return [];
  }
  const lines = contents.trim().split("\n").filter(Boolean).slice(-Math.max(1, limit));
  const items = [];
  for (const line of lines.reverse()) {
    try {
      const payload = JSON.parse(line);
      if (payload && typeof payload === "object") {
        items.push(payload);
      }
    } catch {
      continue;
    }
  }
  return items;
}

function normalizeRuntimeSessionRecord(payload) {
  if (!payload || typeof payload !== "object") {
    return null;
  }
  const blockers = Array.isArray(payload.blockers)
    ? payload.blockers.map((entry) => ({
        at: typeof entry?.at === "string" ? entry.at : "",
        code: sanitizeTaskText(entry?.code || ""),
        reason: sanitizeTaskText(entry?.reason || ""),
      })).filter((entry) => entry.code || entry.reason)
    : [];
  const permissionRequests = Array.isArray(payload.permission_requests)
    ? payload.permission_requests.map((entry) => ({
        at: typeof entry?.at === "string" ? entry.at : "",
        tool: sanitizeTaskText(entry?.tool || ""),
        target: sanitizeTaskText(entry?.target || ""),
      })).filter((entry) => entry.tool || entry.target)
    : [];
  const activityHistory = Array.isArray(payload.activity_history)
    ? payload.activity_history.map((entry) => ({
        at: typeof entry?.at === "string" ? entry.at : "",
        type: sanitizeTaskText(entry?.type || ""),
        summary: sanitizeTaskText(entry?.summary || ""),
        detail: sanitizeTaskText(entry?.detail || ""),
      })).filter((entry) => entry.type || entry.summary || entry.detail)
    : [];
  const latestActivity =
    payload.latest_activity && typeof payload.latest_activity === "object"
      ? {
          at: typeof payload.latest_activity.at === "string" ? payload.latest_activity.at : "",
          type: sanitizeTaskText(payload.latest_activity.type || ""),
          summary: sanitizeTaskText(payload.latest_activity.summary || ""),
          detail: sanitizeTaskText(payload.latest_activity.detail || ""),
        }
      : null;
  return {
    project: sanitizeProjectName(payload.project || "") || "",
    task: sanitizeTaskText(payload.task || ""),
    task_id: sanitizeTaskText(payload.task_id || ""),
    run_id: sanitizeTaskText(payload.run_id || ""),
    state: sanitizeTaskText(payload.state || ""),
    visibility: sanitizeTaskText(payload.visibility || "background") || "background",
    result: sanitizeTaskText(payload.result || ""),
    provider: sanitizeTaskText(payload.provider || ""),
    lane: sanitizeTaskText(payload.lane || ""),
    step_count: safeInteger(payload.step_count, 0),
    completed_steps: safeInteger(payload.completed_steps, 0),
    current_step: sanitizeTaskText(payload.current_step || ""),
    created_at: typeof payload.created_at === "string" ? payload.created_at : "",
    updated_at: typeof payload.updated_at === "string" ? payload.updated_at : "",
    retrieved_at: typeof payload.retrieved_at === "string" ? payload.retrieved_at : "",
    latest_activity: latestActivity,
    activity_history: activityHistory,
    blockers,
    permission_requests: permissionRequests,
  };
}

function readRuntimeSessionForTask(task) {
  const project = sanitizeProjectName(resolveTaskProject(task)) || "unknown-project";
  const taskId = sanitizeActivityPathToken(task?.id, "");
  const lane = sanitizeActivityPathToken(task?.execution?.lane, "");
  const candidates = [];
  if (taskId) {
    candidates.push(path.join(PATHS.runtimeSessions, project, `${taskId}.json`));
  }
  if (lane) {
    candidates.push(path.join(PATHS.runtimeSessions, project, `${lane}.json`));
  }
  for (const candidate of candidates) {
    try {
      const payload = JSON.parse(fs.readFileSync(candidate, "utf8"));
      const normalized = normalizeRuntimeSessionRecord(payload);
      if (normalized) {
        return normalized;
      }
    } catch {
      continue;
    }
  }
  return null;
}

function readRuntimeSessions() {
  let projects = [];
  try {
    projects = fs.readdirSync(PATHS.runtimeSessions, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name);
  } catch {
    return [];
  }
  const sessions = [];
  for (const project of projects) {
    let files = [];
    try {
      files = fs.readdirSync(path.join(PATHS.runtimeSessions, project), { withFileTypes: true })
        .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
        .map((entry) => entry.name);
    } catch {
      continue;
    }
    for (const fileName of files) {
      try {
        const payload = JSON.parse(fs.readFileSync(path.join(PATHS.runtimeSessions, project, fileName), "utf8"));
        const normalized = normalizeRuntimeSessionRecord(payload);
        if (normalized) {
          sessions.push(normalized);
        }
      } catch {
        continue;
      }
    }
  }
  return sessions.sort((left, right) => String(right.updated_at || "").localeCompare(String(left.updated_at || "")));
}

async function focusRuntimeSession(projectName, taskId) {
  const project = sanitizeProjectName(projectName || "");
  const normalizedTaskId = sanitizeTaskText(taskId || "");
  if (!project || !normalizedTaskId) {
    throw new Error("Project and task id are required.");
  }
  const targetPath = path.join(PATHS.runtimeSessions, project, `${sanitizeActivityPathToken(normalizedTaskId, normalizedTaskId)}.json`);
  const payload = await readJsonFile(targetPath, null);
  if (!payload || typeof payload !== "object") {
    throw new Error("Runtime session not found.");
  }
  const updatedAt = nowUtc();
  const nextPayload = {
    ...payload,
    visibility: "foreground",
    retrieved_at: updatedAt,
    updated_at: updatedAt,
  };
  await fsp.mkdir(path.dirname(targetPath), { recursive: true });
  await fsp.writeFile(targetPath, `${JSON.stringify(nextPayload, null, 2)}\n`, "utf8");
  return normalizeRuntimeSessionRecord(nextPayload);
}

function buildActiveWorkSummary(task) {
  const state = String(task?.execution?.state || "").trim().toLowerCase();
  if (!["running", "retrying"].includes(state)) {
    return null;
  }

  const provider =
    normalizeProviderName(task?.execution?.provider || task?.execution_provider || task?.provider_selection?.selected) ||
    "codex";
  const ownership = activeTaskOwnership(task, provider);
  const progress = activeTaskProgress(task);
  const activity = readLatestTaskActivity(task);
  const execution = task?.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext =
    task?.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const totalStepAttempts = Math.max(
    0,
    execution.total_step_attempts != null
      ? safeInteger(execution.total_step_attempts, 0)
      : executionContext.total_step_attempts != null
        ? safeInteger(executionContext.total_step_attempts, 0)
        : 0,
  );
  const attempt = Math.max(0, safeInteger(execution.attempt, 0));
  return {
    id: typeof task?.id === "string" ? task.id : "",
    title: sanitizeTaskText(task?.title || ""),
    state: state || "running",
    provider,
    lane: sanitizeTaskText(execution.lane || ""),
    attempt,
    max_retries: Math.max(0, safeInteger(execution.max_retries, 0)),
    total_step_attempts: totalStepAttempts,
    loop_effort_label: totalStepAttempts > attempt ? `${totalStepAttempts} step attempts` : "",
    worker: ownership.worker,
    worker_label: ownership.worker || "Unassigned",
    owner: ownership.owner,
    owner_label: ownership.owner || provider,
    current_work_label:
      sanitizeTaskText(progress.current_work_label || "") !== "In progress"
        ? progress.current_work_label
        : sanitizeTaskText(activity?.summary || "") || progress.current_work_label,
    progress_label: progress.label,
    activity_label: sanitizeTaskText(activity?.summary || ""),
    activity_at: typeof activity?.at === "string" ? activity.at : "",
    completed_steps: progress.completed_steps,
    step_count: progress.total_steps,
    total_steps: progress.total_steps,
  };
}

function buildActiveWorkItems(tasks) {
  return (Array.isArray(tasks) ? tasks : [])
    .map((task) => buildActiveWorkSummary(task))
    .filter(Boolean)
    .sort((left, right) => activeTaskSortKey(left).localeCompare(activeTaskSortKey(right)));
}

function buildLiveWorkPanel(tasks) {
  const items = buildActiveWorkItems(tasks);
  return {
    items,
  };
}

function compactDashboardExecutionContext(task) {
  if (!task || typeof task !== "object") {
    return null;
  }
  const executionContext =
    task.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const failureContext =
    task.failure_context && typeof task.failure_context === "object" ? task.failure_context : {};
  const activeWork = task.active_work && typeof task.active_work === "object" ? task.active_work : {};
  const execution = task.execution && typeof task.execution === "object" ? task.execution : {};
  const compact = {};
  const currentStep = sanitizeTaskText(
    execution.current_step || executionContext.current_step || activeWork.current_work_label || "",
  );
  const worker = sanitizeTaskText(executionContext.worker || activeWork.worker || "");
  const owner = sanitizeTaskText(executionContext.owner || activeWork.owner || "");
  const completedSteps = Math.max(
    0,
    safeInteger(
      executionContext.completed_steps,
      activeWork.completed_steps != null ? safeInteger(activeWork.completed_steps, 0) : 0,
    ),
  );
  const stepCount = Math.max(
    0,
    safeInteger(executionContext.step_count, activeWork.step_count != null ? safeInteger(activeWork.step_count, 0) : 0),
  );
  const totalStepAttempts = Math.max(
    0,
    execution.total_step_attempts != null
      ? safeInteger(execution.total_step_attempts, 0)
      : executionContext.total_step_attempts != null
        ? safeInteger(executionContext.total_step_attempts, 0)
        : failureContext.total_step_attempts != null
          ? safeInteger(failureContext.total_step_attempts, 0)
          : activeWork.total_step_attempts != null
            ? safeInteger(activeWork.total_step_attempts, 0)
            : 0,
  );

  if (currentStep && currentStep !== "In progress" && currentStep !== "Retry queued") {
    compact.current_step = currentStep;
  }
  if (worker) {
    compact.worker = worker;
  }
  if (owner) {
    compact.owner = owner;
  }
  if (completedSteps > 0) {
    compact.completed_steps = completedSteps;
  }
  if (stepCount > 0) {
    compact.step_count = stepCount;
  }
  if (totalStepAttempts > 0) {
    compact.total_step_attempts = totalStepAttempts;
  }

  return Object.keys(compact).length ? compact : null;
}

function compactDashboardQueueHandoff(task) {
  if (!task || typeof task !== "object") {
    return null;
  }
  const queueHandoff = task.queue_handoff && typeof task.queue_handoff === "object" ? task.queue_handoff : null;
  if (!queueHandoff) {
    return null;
  }

  const compact = {};
  const handoffAt = typeof queueHandoff.at === "string" ? queueHandoff.at : "";
  const handoffTask = sanitizeTaskText(queueHandoff.task || "");
  const handoffStatus = typeof queueHandoff.status === "string" ? queueHandoff.status : "";

  if (handoffAt) {
    compact.at = handoffAt;
  }
  if (handoffTask) {
    compact.task = handoffTask;
  }
  if (handoffStatus) {
    compact.status = handoffStatus;
  }

  return Object.keys(compact).length ? compact : null;
}

function compactDashboardTaskShape(task) {
  if (!task || typeof task !== "object") {
    return null;
  }
  const taskShape = task.task_shape && typeof task.task_shape === "object" ? task.task_shape : null;
  if (!taskShape || taskShape.approval_ready !== false) {
    return null;
  }

  const reasons = Array.isArray(taskShape.reasons)
    ? taskShape.reasons.map((reason) => sanitizeTaskText(reason)).filter(Boolean)
    : [];
  const compact = {
    approval_ready: false,
  };

  if (reasons.length) {
    compact.reasons = reasons;
  }

  return compact;
}

function compactDashboardTask(task) {
  if (!task || typeof task !== "object") {
    return task;
  }
  const history = Array.isArray(task.history) ? task.history : [];
  const {
    history: _history,
    execution_brief: _executionBrief,
    approval_execution_brief: _approvalExecutionBrief,
    task_intent: _taskIntent,
    execution_context: _executionContext,
    failure_context: _failureContext,
    runtime_session: _runtimeSession,
    queue_handoff: _queueHandoff,
    task_shape: _taskShape,
    ...rest
  } = task;
  const compactExecutionContext = compactDashboardExecutionContext(task);
  const compactQueueHandoff = compactDashboardQueueHandoff(task);
  const compactTaskShape = compactDashboardTaskShape(task);
  return {
    ...rest,
    ...(task.runtime_session && typeof task.runtime_session === "object" ? { runtime_session: task.runtime_session } : {}),
    ...(compactExecutionContext ? { execution_context: compactExecutionContext } : {}),
    ...(compactQueueHandoff ? { queue_handoff: compactQueueHandoff } : {}),
    ...(compactTaskShape ? { task_shape: compactTaskShape } : {}),
    history_length: history.length,
  };
}

async function readTaskRegistryPayloadAt(filePath) {
  const payload = await readJsonFile(filePath, { tasks: [] });
  const normalizedPayload = {
    ...payload,
    tasks: Array.isArray(payload.tasks) ? payload.tasks : [],
  };
  const repairedTasks = [];
  let changed = false;
  let repairedCount = 0;
  for (const task of normalizedPayload.tasks) {
    const repair = repairPendingApprovalTask(task, repairedTasks.concat(normalizedPayload.tasks));
    repairedTasks.push(repair.task);
    if (repair.changed) {
      changed = true;
    }
    if (repair.repaired) {
      repairedCount += 1;
    }
  }

  if (!changed) {
    return normalizedPayload;
  }

  const nextPayload = {
    ...normalizedPayload,
    tasks: repairedTasks,
  };
  await writeTaskRegistryPayloadAt(filePath, nextPayload);
  if (repairedCount > 0) {
    await appendLog(
      `Auto-repaired ${repairedCount} pending approval task${repairedCount === 1 ? "" : "s"} into approval-ready decisions.`,
    );
  }
  return nextPayload;
}

async function readProjectTaskRegistryPayload(project) {
  return readTaskRegistryPayloadAt(projectTaskRegistryPath(project));
}

async function buildTaskRegistryReadCacheSignature(targets) {
  const entries = await Promise.all(
    (Array.isArray(targets) ? targets : []).map(async (target) => {
      const filePath = path.resolve(String(target?.filePath || ""));
      const project = sanitizeProjectName(target?.project || "") || "codex-agent-system";
      const metadataPath = path.resolve(projectMetadataPath(project));
      const policyPath = path.resolve(projectPolicyPath(project));
      const [taskRegistryStat, metadataStat, policyStat] = await Promise.all([
        fsp.stat(filePath).catch(() => null),
        fsp.stat(metadataPath).catch(() => null),
        fsp.stat(policyPath).catch(() => null),
      ]);
      return [
        `${filePath}:${taskRegistryStat ? `${taskRegistryStat.mtimeMs}:${taskRegistryStat.size}` : "missing"}`,
        `${metadataPath}:${metadataStat ? `${metadataStat.mtimeMs}:${metadataStat.size}` : "missing"}`,
        `${policyPath}:${policyStat ? `${policyStat.mtimeMs}:${policyStat.size}` : "missing"}`,
      ];
    }),
  );
  return entries.flat().sort().join("|");
}

async function readTaskRegistryPayload(targets = null) {
  const resolvedTargets = Array.isArray(targets) ? targets : taskRegistryTargets();
  const tasks = [];
  let payloadBytes = 0;
  for (const target of resolvedTargets) {
    const payload = await readTaskRegistryPayloadAt(target.filePath);
    const stat = await fsp.stat(target.filePath).catch(() => null);
    if (stat) {
      payloadBytes += stat.size;
    }
    if (Array.isArray(payload.tasks)) {
      const sourceProject = sanitizeProjectName(target?.project || "") || "codex-agent-system";
      tasks.push(
        ...payload.tasks.map((task) =>
          task && typeof task === "object" && !Array.isArray(task)
            ? { ...task, _source_project: firstNonEmptyString(task._source_project, sourceProject) }
            : task,
        ),
      );
    }
  }
  return { tasks, payloadBytes };
}

async function writeTaskRegistryPayloadAt(filePath, payload) {
  const tasks = pruneApprovedTasksForPersistence(Array.isArray(payload.tasks) ? payload.tasks : []);
  invalidateTaskRegistryReadCache();
  await writeJsonFile(filePath, {
    ...payload,
    tasks,
  });
}

async function writeProjectTaskRegistryPayload(project, payload) {
  await writeTaskRegistryPayloadAt(projectTaskRegistryPath(project), payload);
}

function taskIdentityMatches(task, taskId, project = "") {
  const normalizedId = String(taskId || "").trim();
  if (!normalizedId || String(task?.id || "").trim() !== normalizedId) {
    return false;
  }
  const normalizedProject = sanitizeProjectName(project || "");
  if (!normalizedProject) {
    return true;
  }
  return normalizeTaskProject(task) === normalizedProject;
}

function taskIdentityKey(taskId, project = "") {
  const normalizedId = normalizeTask(taskId || "");
  if (!normalizedId) {
    return "";
  }
  const normalizedProject = sanitizeProjectName(project || "");
  return normalizedProject ? `${normalizedProject}::${normalizedId}` : normalizedId;
}

async function locateTaskRegistryTask(taskId, project = "") {
  const normalizedId = String(taskId || "").trim();
  const normalizedProject = sanitizeProjectName(project || "");
  const matches = [];
  for (const target of taskRegistryTargets()) {
    const payload = await readTaskRegistryPayloadAt(target.filePath);
    if (!Array.isArray(payload.tasks)) {
      continue;
    }
    for (let index = 0; index < payload.tasks.length; index += 1) {
      const task = payload.tasks[index];
      if (!taskIdentityMatches(task, normalizedId, normalizedProject)) {
        continue;
      }
      matches.push({
        project: target.project,
        filePath: target.filePath,
        payload,
        index,
        task,
      });
    }
  }
  if (matches.length === 1) {
    return matches[0];
  }
  return {
    conflict: matches.length > 1,
    project: normalizedProject,
    taskId: normalizedId,
    matches,
  };
}

function firstNonEmptyString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return "";
}

function canonicalizeJsonValue(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => canonicalizeJsonValue(entry));
  }
  if (value && typeof value === "object") {
    return Object.keys(value)
      .sort()
      .reduce((result, key) => {
        result[key] = canonicalizeJsonValue(value[key]);
        return result;
      }, {});
  }
  return value;
}

function normalizeTaskRegistryPressureSources(sources) {
  return (Array.isArray(sources) ? sources : [])
    .filter((entry) => entry && typeof entry === "object")
    .map((entry) => {
      const sharedProjects = Array.from(
        new Set(
          (Array.isArray(entry.shared_projects) ? entry.shared_projects : [])
            .map((project) => sanitizeProjectName(project || ""))
            .filter(Boolean),
        ),
      ).sort();
      const primaryProject =
        sanitizeProjectName(entry.project || "") || sharedProjects[0] || "codex-agent-system";
      const file = path.resolve(String(entry.file || entry.filePath || ""));
      return {
        project: primaryProject,
        file,
        payload_bytes: Math.max(safeInteger(entry.payload_bytes, 0), 0),
        shared_projects: sharedProjects.length ? sharedProjects : [primaryProject],
      };
    })
    .filter((entry) => entry.file)
    .sort((left, right) => {
      if (right.payload_bytes !== left.payload_bytes) {
        return right.payload_bytes - left.payload_bytes;
      }
      if (left.project !== right.project) {
        return left.project.localeCompare(right.project);
      }
      return left.file.localeCompare(right.file);
    });
}

function buildTaskRegistryPressureSources(targets) {
  const aggregated = new Map();
  for (const entry of Array.isArray(targets) ? targets : []) {
    const file = path.resolve(String(entry?.filePath || ""));
    if (!file) {
      continue;
    }
    const project = sanitizeProjectName(entry?.project || "") || "codex-agent-system";
    const existing = aggregated.get(file) || {
      file,
      payload_bytes: 0,
      shared_projects: new Set(),
    };
    if (existing.payload_bytes <= 0) {
      try {
        existing.payload_bytes = fs.statSync(file).size;
      } catch {
        existing.payload_bytes = 0;
      }
    }
    existing.shared_projects.add(project);
    aggregated.set(file, existing);
  }

  return normalizeTaskRegistryPressureSources(
    [...aggregated.values()].map((entry) => {
      const sharedProjects = [...entry.shared_projects].sort();
      return {
        project: sharedProjects[0] || "codex-agent-system",
        file: entry.file,
        payload_bytes: entry.payload_bytes,
        shared_projects: sharedProjects,
      };
    }),
  );
}

function buildTaskRegistryPressureSignal(tasks, options = {}) {
  const registryTasks = Array.isArray(tasks) ? tasks.filter((task) => task && typeof task === "object") : [];
  const overridePayloadBytes = safeInteger(options?.task_registry_payload_bytes, -1);
  const pressureSources = normalizeTaskRegistryPressureSources(options?.task_registry_pressure_sources);
  const payloadBytes =
    overridePayloadBytes >= 0
      ? overridePayloadBytes
      : Buffer.byteLength(JSON.stringify(canonicalizeJsonValue({ tasks: registryTasks })), "utf8");
  const detected = payloadBytes >= TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD;
  const primarySource = pressureSources[0] || null;
  return {
    task_registry_payload_bytes: payloadBytes,
    task_registry_pressure_detected: detected,
    // The dashboard remains the highest-frequency registry reader under the current fixed poll topology.
    task_registry_pressure_primary_surface: detected ? "dashboard_read_path" : "",
    task_registry_pressure_sources: pressureSources,
    task_registry_pressure_primary_source: primarySource,
  };
}

function taskRegistryPayloadBytesForTargets(targets) {
  const entries = Array.isArray(targets) ? targets : [];
  const seen = new Set();
  let total = 0;
  for (const entry of entries) {
    const filePath = path.resolve(String(entry?.filePath || ""));
    if (!filePath || seen.has(filePath)) {
      continue;
    }
    seen.add(filePath);
    try {
      total += fs.statSync(filePath).size;
    } catch {}
  }
  return total;
}

function parseTimestampMs(value) {
  const text = firstNonEmptyString(value);
  if (!text) {
    return null;
  }
  const timestamp = Date.parse(text);
  return Number.isFinite(timestamp) ? timestamp : null;
}

function taskHasPersistedSuccess(task) {
  if (!task || typeof task !== "object") {
    return false;
  }
  const status = String(task.status || "").trim().toLowerCase();
  const execution = task.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext = task.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  return (
    status === "completed" ||
    status === "success" ||
    String(execution.result || "").trim().toUpperCase() === "SUCCESS" ||
    String(executionContext.result || "").trim().toUpperCase() === "SUCCESS"
  );
}

function buildTaskIndexById(tasks) {
  const index = new Map();
  const uniqueById = new Map();
  const duplicateIds = new Set();
  for (const task of Array.isArray(tasks) ? tasks : []) {
    if (!task || typeof task !== "object") {
      continue;
    }
    const taskId = normalizeTask(task.id || "");
    if (!taskId) {
      continue;
    }
    index.set(taskIdentityKey(taskId, normalizeTaskProject(task)), task);
    if (uniqueById.has(taskId)) {
      duplicateIds.add(taskId);
      continue;
    }
    uniqueById.set(taskId, task);
  }
  for (const [taskId, task] of uniqueById.entries()) {
    if (!duplicateIds.has(taskId)) {
      index.set(taskId, task);
    }
  }
  return index;
}

function lookupTaskById(tasksById, taskId, project = "") {
  if (!(tasksById instanceof Map)) {
    return null;
  }
  const scopedKey = taskIdentityKey(taskId, project);
  if (scopedKey && tasksById.has(scopedKey)) {
    return tasksById.get(scopedKey) || null;
  }
  const normalizedId = normalizeTask(taskId || "");
  if (normalizedId && tasksById.has(normalizedId)) {
    return tasksById.get(normalizedId) || null;
  }
  return null;
}

function taskLogIdentityKey(record) {
  const project = normalizeRecordProject(record);
  const task = normalizeTask(record?.task || "");
  if (!project || !task) {
    return "";
  }
  return `${project}::${task}`;
}

function buildLatestSuccessTimestampByIdentity(records) {
  const latestByIdentity = new Map();
  for (const record of Array.isArray(records) ? records : []) {
    if (String(record?.result || "").trim().toUpperCase() !== "SUCCESS") {
      continue;
    }
    const identity = taskLogIdentityKey(record);
    const timestampMs = parseTimestampMs(record?.timestamp);
    if (!identity || timestampMs === null) {
      continue;
    }
    const existingTimestampMs = latestByIdentity.get(identity);
    if (existingTimestampMs === undefined || timestampMs > existingTimestampMs) {
      latestByIdentity.set(identity, timestampMs);
    }
  }
  return latestByIdentity;
}

function isUnresolvedTimeoutRecord(record, tasksById, latestSuccessByIdentity) {
  if (String(record?.result || "").trim().toUpperCase() !== "FAILURE") {
    return false;
  }
  if (String(record?.failure_kind || "").trim() !== "timeout") {
    return false;
  }

  const taskId = normalizeTask(record?.task_id || "");
  if (!taskId) {
    const identity = taskLogIdentityKey(record);
    const recordTimestampMs = parseTimestampMs(record?.timestamp);
    const latestSuccessTimestampMs = latestSuccessByIdentity.get(identity);
    if (
      identity &&
      recordTimestampMs !== null &&
      latestSuccessTimestampMs !== undefined &&
      latestSuccessTimestampMs > recordTimestampMs
    ) {
      return false;
    }
    return true;
  }

  const linkedTask = lookupTaskById(tasksById, taskId, normalizeRecordProject(record));
  if (!linkedTask || typeof linkedTask !== "object") {
    return true;
  }
  return !taskHasPersistedSuccess(linkedTask);
}

function countUnresolvedTimeoutRecords(records, registryTasks) {
  const normalizedRecords = Array.isArray(records) ? records : [];
  const tasksById = buildTaskIndexById(registryTasks);
  const latestSuccessByIdentity = buildLatestSuccessTimestampByIdentity(normalizedRecords);
  return normalizedRecords.filter((record) => isUnresolvedTimeoutRecord(record, tasksById, latestSuccessByIdentity)).length;
}

function latestHistoryTransitionAt(task, toStatus) {
  const entries = Array.isArray(task?.history) ? task.history : [];
  let latest = "";
  for (const entry of entries) {
    if (!entry || typeof entry !== "object") {
      continue;
    }
    if (String(entry.to_status || "").trim().toLowerCase() !== toStatus) {
      continue;
    }
    const at = typeof entry.at === "string" ? entry.at.trim() : "";
    if (at && (!latest || at > latest)) {
      latest = at;
    }
  }
  return latest;
}

function completionEvidenceForApprovedTask(task) {
  const execution = task?.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext = task?.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const completedAt = firstNonEmptyString(
    task?.completed_at,
    latestHistoryTransitionAt(task, "completed"),
    String(execution.state || "").trim().toLowerCase() === "completed" ? execution.updated_at : "",
    String(execution.result || "").trim().toUpperCase() === "SUCCESS" ? execution.updated_at : "",
    String(executionContext.result || "").trim().toUpperCase() === "SUCCESS" ? task?.updated_at : "",
  );
  if (!completedAt) {
    return null;
  }
  return {
    at: completedAt,
    note: "Approved task was pruned because completion evidence already exists on the task record.",
  };
}

function invalidEvidenceForApprovedTask(task) {
  const queueTask = taskExecutionText(task);
  if (!queueTask) {
    return {
      at: firstNonEmptyString(task?.updated_at, task?.created_at),
      note: "Approved task was pruned because it has no non-empty queue task text.",
    };
  }

  const promptSource = String(task?.prompt_intake?.source || task?.task_intent?.source || "")
    .trim()
    .toLowerCase();
  const title = sanitizeTaskText(task?.title || "");
  if (promptSource === "dashboard_prompt_intake") {
    if (title.length > 240 && (/^you are\b/i.test(title) || /---|[#*]/.test(title))) {
      return {
        at: firstNonEmptyString(task?.updated_at, task?.created_at),
        note: "Approved task was pruned because the prompt-intake title is still a raw instruction blob instead of a discrete task.",
      };
    }
    if (/https?:\/\//i.test(title)) {
      return {
        at: firstNonEmptyString(task?.updated_at, task?.created_at),
        note: "Approved task was pruned because the prompt-intake title still contains a raw URL instead of normalized task text.",
      };
    }
  }

  return null;
}

function supersedingEvidenceForApprovedTask(task, allTasks) {
  const project = normalizeTaskProject(task);
  const taskKey = normalizeTask(taskExecutionText(task));
  if (!project || !taskKey) {
    return null;
  }

  const supersedingCandidate = (Array.isArray(allTasks) ? allTasks : [])
    .filter((candidate) => {
      if (!candidate || typeof candidate !== "object" || candidate === task) {
        return false;
      }
      if (normalizeTaskProject(candidate) !== project) {
        return false;
      }
      if (normalizeTask(taskExecutionText(candidate)) !== taskKey) {
        return false;
      }
      const status = String(candidate.status || "").trim().toLowerCase();
      return status === "running" || status === "completed";
    })
    .sort((left, right) => {
      const leftStatus = String(left.status || "").trim().toLowerCase();
      const rightStatus = String(right.status || "").trim().toLowerCase();
      const leftRank = leftStatus === "completed" ? 0 : 1;
      const rightRank = rightStatus === "completed" ? 0 : 1;
      if (leftRank !== rightRank) {
        return leftRank - rightRank;
      }
      const leftUpdated = firstNonEmptyString(left.updated_at, left.created_at);
      const rightUpdated = firstNonEmptyString(right.updated_at, right.created_at);
      return rightUpdated.localeCompare(leftUpdated);
    })[0];

  if (!supersedingCandidate) {
    return null;
  }

  return {
    at: firstNonEmptyString(supersedingCandidate.updated_at, supersedingCandidate.created_at, task.updated_at, task.created_at),
    note: `Approved task was pruned because duplicate work already advanced to ${String(
      supersedingCandidate.status || "",
    ).trim().toLowerCase()}.`,
  };
}

function pruneApprovedTask(task, allTasks) {
  const status = String(task?.status || "").trim().toLowerCase();
  if (status !== "approved") {
    return task;
  }

  const completionEvidence = completionEvidenceForApprovedTask(task);
  if (completionEvidence) {
    const transitionAt = firstNonEmptyString(completionEvidence.at, task.updated_at, task.created_at);
    const nextTask = {
      ...task,
      status: "completed",
      completed_at: firstNonEmptyString(task.completed_at, transitionAt),
      updated_at: transitionAt,
    };
    if (task.queue_handoff && typeof task.queue_handoff === "object") {
      nextTask.queue_handoff = {
        ...task.queue_handoff,
        status: "completed",
      };
    }
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "prune", "approved", "completed", {
        at: transitionAt,
        note: completionEvidence.note,
        project: normalizeTaskProject(task),
        queueTask: taskExecutionText(task),
      }),
    );
    return nextTask;
  }

  const supersedingEvidence = supersedingEvidenceForApprovedTask(task, allTasks);
  if (supersedingEvidence) {
    const transitionAt = firstNonEmptyString(supersedingEvidence.at, task.updated_at, task.created_at);
    const nextTask = {
      ...task,
      status: "rejected",
      rejected_at: firstNonEmptyString(task.rejected_at, transitionAt),
      updated_at: transitionAt,
    };
    if (task.queue_handoff && typeof task.queue_handoff === "object") {
      nextTask.queue_handoff = {
        ...task.queue_handoff,
        status: "pruned",
      };
    }
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "prune", "approved", "rejected", {
        at: transitionAt,
        note: supersedingEvidence.note,
        project: normalizeTaskProject(task),
        queueTask: taskExecutionText(task),
      }),
    );
    return nextTask;
  }

  const invalidEvidence = invalidEvidenceForApprovedTask(task);
  if (invalidEvidence) {
    const transitionAt = firstNonEmptyString(invalidEvidence.at, task.updated_at, task.created_at);
    const nextTask = {
      ...task,
      status: "rejected",
      rejected_at: firstNonEmptyString(task.rejected_at, transitionAt),
      updated_at: transitionAt,
    };
    if (task.queue_handoff && typeof task.queue_handoff === "object") {
      nextTask.queue_handoff = {
        ...task.queue_handoff,
        status: "pruned",
      };
    }
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "prune", "approved", "rejected", {
        at: transitionAt,
        note: invalidEvidence.note,
        project: normalizeTaskProject(task),
        queueTask: taskExecutionText(task),
      }),
    );
    return nextTask;
  }

  return task;
}

function pruneApprovedTasksForPersistence(tasks) {
  const input = Array.isArray(tasks) ? tasks : [];
  return input.map((task) => pruneApprovedTask(task, input));
}

const DEFAULT_EXTERNAL_SIGNAL_FRESHNESS_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

function readExternalSignalNow() {
  const override = firstNonEmptyString(process.env.CODEX_EXTERNAL_SIGNAL_NOW);
  if (override) {
    const parsed = new Date(override);
    if (Number.isFinite(parsed.getTime())) {
      return parsed;
    }
  }
  return new Date();
}

function readExternalSignalFreshnessWindowMs(snapshot = {}, signal = {}) {
  const rawValue =
    signal && typeof signal === "object" && signal.freshness_window_seconds !== undefined
      ? signal.freshness_window_seconds
      : snapshot && typeof snapshot === "object"
        ? snapshot.freshness_window_seconds
        : undefined;
  const parsed = safeNumber(rawValue, DEFAULT_EXTERNAL_SIGNAL_FRESHNESS_WINDOW_MS / 1000);
  return Math.max(60000, parsed * 1000);
}

function isExternalSignalFresh(signal, snapshot = {}, now = readExternalSignalNow()) {
  if (!signal || typeof signal !== "object") {
    return false;
  }
  const reference = firstNonEmptyString(signal.published_at, signal.fetched_at);
  if (!reference) {
    return signal.fresh === true;
  }
  const parsed = new Date(reference);
  if (!Number.isFinite(parsed.getTime())) {
    return signal.fresh === true;
  }
  const ageMs = Math.max(now.getTime() - parsed.getTime(), 0);
  return ageMs <= readExternalSignalFreshnessWindowMs(snapshot, signal);
}

function buildExternalResearchSummary(payload = {}) {
  const snapshot = payload && typeof payload === "object" ? payload : {};
  const signals = Array.isArray(snapshot.signals)
    ? snapshot.signals.filter((signal) => signal && typeof signal === "object")
    : [];
  const errors = Array.isArray(snapshot.errors) ? snapshot.errors.filter(Boolean) : [];
  const now = readExternalSignalNow();
  const latestSignal =
    signals
      .slice()
      .sort((left, right) =>
        firstNonEmptyString(right.published_at, right.fetched_at).localeCompare(
          firstNonEmptyString(left.published_at, left.fetched_at),
        ),
      )[0] || null;
  const freshSignals = signals.filter((signal) => isExternalSignalFresh(signal, snapshot, now)).length;
  const updatedAt = firstNonEmptyString(snapshot.updated_at);
  const status = errors.length
    ? "error"
    : freshSignals > 0
      ? "fresh"
      : signals.length > 0
        ? "stale"
        : updatedAt
          ? "empty"
          : "unavailable";

  return {
    status,
    total_signals: signals.length,
    fresh_signals: freshSignals,
    errors: errors.length,
    updated_at: updatedAt,
    latest_signal: latestSignal
      ? {
          source_id: String(latestSignal.source_id || "").trim(),
          source_label: firstNonEmptyString(latestSignal.source_label, latestSignal.source_id),
          title: String(latestSignal.title || "").trim(),
          url: String(latestSignal.url || "").trim(),
          published_at: String(latestSignal.published_at || "").trim(),
          fresh: isExternalSignalFresh(latestSignal, snapshot, now),
        }
      : null,
  };
}

function defaultSelfImproveSummary() {
  return {
    status: "unavailable",
    project: "",
    generated_at: "",
    selected_improvement: "",
    selection: {
      selected_title: "",
      state: "none",
      submitted_titles: [],
      ranked_titles: [],
      next_title: "",
    },
    counts: {
      detected: 0,
      generated: 0,
      submitted: 0,
      skipped: 0,
      blocked_analysis: 0,
    },
    pause: {
      active: false,
      reason: "none",
      file: "",
      detected_at: "",
      age_seconds: 0,
      remediation: {
        active: false,
        kind: "none",
        title: "",
        summary: "",
        command: "",
      },
    },
    gating: {
      dominant_reason: "none",
      analysis_reason: "none",
      submission_reason: "none",
      active_self_improve_count: 0,
      resulting_active_self_improve_count: 0,
      active_self_improve_cap: 0,
      backlog_bypass_active: false,
      backlog_gate_active: false,
      overload: {
        active: false,
        preserved_title: "",
        preserved_reason: "inactive",
        candidate_count: 0,
        blocked_candidate_count: 0,
        candidates: [],
      },
    },
    operator_signal: {
      active: false,
      kind: "none",
      title: "",
      summary: "",
      remediation: {
        active: false,
        kind: "none",
        title: "",
        summary: "",
        command: "",
      },
    },
    automation_memory: {
      automation_id: "",
      exists: false,
      memory_file: "",
      source: "none",
      external_hydrated: false,
      external_sync_pending: true,
      readable: false,
      continuity_status: "missing",
    },
    metrics_input: {
      status: "unknown",
      refresh_performed: false,
      reason: "not_checked",
      missing_keys: [],
    },
    artifact_freshness: {
      status: "unknown",
      stale: false,
      reason: "not_checked",
      artifact_updated_at: "",
      compared_source: "",
      compared_updated_at: "",
    },
    metrics_snapshot: {},
  };
}

function describeSelfImproveMetricsInputReason(reason) {
  const normalizedReason = firstNonEmptyString(reason, "not_checked");
  if (normalizedReason === "metrics_file_missing") {
    return "metrics.json was missing";
  }
  if (normalizedReason === "invalid_json") {
    return "metrics.json was unreadable JSON";
  }
  if (normalizedReason === "invalid_payload") {
    return "metrics.json did not contain an object payload";
  }
  if (normalizedReason === "missing_required_keys") {
    return "required counters were missing from metrics.json";
  }
  if (normalizedReason === "missing_required_keys_after_refresh") {
    return "required counters were still missing after refresh";
  }
  if (normalizedReason === "registry_count_mismatch") {
    return "persisted metrics counters drifted from the task registry";
  }
  if (normalizedReason.startsWith("invalid_bounded_metric_")) {
    const metricName = normalizedReason.slice("invalid_bounded_metric_".length).replace(/_/g, " ");
    return `${metricName || "a bounded metric"} was outside the expected 0-1 range`;
  }
  if (normalizedReason.startsWith("invalid_registry_count_")) {
    const counterName = normalizedReason.slice("invalid_registry_count_".length).replace(/_/g, " ");
    return `${counterName || "a persisted counter"} did not match the task registry`;
  }
  if (normalizedReason.startsWith("stale_against_")) {
    const source = normalizedReason.slice("stale_against_".length);
    const labels = {
      tasks_json: "tasks.json was newer than metrics.json",
      tasks_log: "tasks.log was newer than metrics.json",
      external_signals: "external signals were newer than metrics.json",
    };
    return labels[source] || `${source} was newer than metrics.json`;
  }
  if (normalizedReason === "refresh_failed") {
    return "metrics refresh failed before ranking improvements";
  }
  if (normalizedReason === "python3_unavailable") {
    return "python3 was unavailable for metrics refresh";
  }
  if (normalizedReason === "sync_task_artifacts_missing") {
    return "sync-task-artifacts.py was unavailable for metrics refresh";
  }
  if (normalizedReason === "complete_snapshot") {
    return "metrics.json was already complete";
  }
  return normalizedReason.replace(/_/g, " ");
}

const SELF_IMPROVE_ARTIFACT_STALE_THRESHOLD_MS = 60 * 1000;
const SELF_IMPROVE_ZERO_STEP_TIMEOUT_OPERATOR_THRESHOLD = 0.75;
const SELF_IMPROVE_TIMEOUT_DIAGNOSTIC_COVERAGE_OPERATOR_THRESHOLD = 0.35;
const SELF_IMPROVE_TIMEOUT_DIAGNOSTIC_COVERAGE_MIN_FAILURES = 20;
const SELF_IMPROVE_TIMEOUT_DIAGNOSTIC_COVERAGE_TITLE = "Improve timeout diagnostic coverage";

function buildSelfImproveArtifactFreshness(generatedAt = "", options = {}) {
  const artifactTimestampCandidates = [generatedAt, options.artifactUpdatedAt]
    .map((value) => parseTimestampMs(value))
    .filter((value) => value !== null);
  const artifactTimestampMs =
    artifactTimestampCandidates.length > 0 ? Math.max(...artifactTimestampCandidates) : null;
  const artifactUpdatedAt =
    artifactTimestampMs === null ? "" : new Date(artifactTimestampMs).toISOString();
  const metricsUpdatedAt = firstNonEmptyString(options.metricsUpdatedAt);
  const metricsTimestampMs = parseTimestampMs(metricsUpdatedAt);

  if (artifactTimestampMs === null) {
    return {
      status: "unknown",
      stale: false,
      reason: "artifact_timestamp_missing",
      artifact_updated_at: "",
      compared_source: metricsUpdatedAt ? "metrics.json" : "",
      compared_updated_at: metricsUpdatedAt,
    };
  }

  if (
    metricsTimestampMs !== null
    && metricsTimestampMs > (artifactTimestampMs + SELF_IMPROVE_ARTIFACT_STALE_THRESHOLD_MS)
  ) {
    return {
      status: "stale",
      stale: true,
      reason: "metrics_newer",
      artifact_updated_at: artifactUpdatedAt,
      compared_source: "metrics.json",
      compared_updated_at: new Date(metricsTimestampMs).toISOString(),
    };
  }

  return {
    status: "current",
    stale: false,
    reason: "up_to_date",
    artifact_updated_at: artifactUpdatedAt,
    compared_source: metricsUpdatedAt ? "metrics.json" : "",
    compared_updated_at: metricsUpdatedAt,
  };
}

function defaultSelfImproveOperatorRemediation() {
  return {
    active: false,
    kind: "none",
    title: "",
    summary: "",
    command: "",
  };
}

function buildSelfImproveRerunRemediation(projectName = "", title = "Refresh self-improve artifact", summary = "") {
  const normalizedProjectName = firstNonEmptyString(projectName);
  const command = normalizedProjectName
    ? `bash scripts/self-improve.sh ${normalizedProjectName}`
    : "bash scripts/self-improve.sh";
  return {
    active: true,
    kind: "rerun_self_improve",
    title,
    summary: summary || `Run ${command} to regenerate ranking details from current metrics.`,
    command,
  };
}

function buildSelfImproveMetricsInputRemediation(projectName = "", metricsInputStatus = "unknown", metricsInputReason = "not_checked") {
  const normalizedProjectName = firstNonEmptyString(projectName);
  const normalizedStatus = firstNonEmptyString(metricsInputStatus, "unknown");
  const normalizedReason = firstNonEmptyString(metricsInputReason, "not_checked");
  const rerunCommand = normalizedProjectName
    ? `bash scripts/self-improve.sh ${normalizedProjectName}`
    : "bash scripts/self-improve.sh";
  const validateCommand = "bash scripts/validate-metrics.sh";
  const syncCommand = "python3 scripts/sync-task-artifacts.py codex-memory/tasks.json codex-memory/tasks.log codex-learning/metrics.json codex-learning/external-signals.json";

  if (normalizedReason === "python3_unavailable") {
    return {
      active: true,
      kind: "restore_python_runtime",
      title: "Restore Python runtime",
      summary: `Restore python3 in the runtime environment, then run ${rerunCommand} to regenerate ranking details.`,
      command: rerunCommand,
    };
  }

  if (normalizedReason === "sync_task_artifacts_missing") {
    return {
      active: true,
      kind: "restore_metrics_sync_helper",
      title: "Restore metrics sync helper",
      summary: `Restore scripts/sync-task-artifacts.py, then run ${rerunCommand} to regenerate ranking details.`,
      command: rerunCommand,
    };
  }

  if (
    normalizedReason === "missing_required_keys"
    || normalizedReason === "missing_required_keys_after_refresh"
    || normalizedReason === "registry_count_mismatch"
    || normalizedReason.startsWith("invalid_bounded_metric_")
    || normalizedReason.startsWith("invalid_registry_count_")
  ) {
    return {
      active: true,
      kind: "realign_persisted_metrics",
      title: "Realign persisted metrics",
      summary: `Run ${validateCommand} to repair persisted metrics, then run ${rerunCommand} to regenerate ranking details.`,
      command: validateCommand,
    };
  }

  if (
    normalizedStatus === "refresh_failed"
    || normalizedReason === "metrics_file_missing"
    || normalizedReason === "invalid_json"
    || normalizedReason === "invalid_payload"
  ) {
    return {
      active: true,
      kind: "rebuild_metrics_snapshot",
      title: "Rebuild metrics snapshot",
      summary: `Run ${syncCommand} to rebuild metrics from current artifacts, then run ${rerunCommand} to regenerate ranking details.`,
      command: syncCommand,
    };
  }

  return buildSelfImproveRerunRemediation(
    normalizedProjectName,
    "Retry self-improve metrics refresh",
    `Run ${rerunCommand} to retry metrics refresh and regenerate ranking details.`,
  );
}

function buildSelfImprovePauseRemediation(pause = {}, projectName = "") {
  const normalizedProjectName = firstNonEmptyString(projectName);
  const normalizedPause =
    pause && typeof pause === "object" && !Array.isArray(pause)
      ? pause
      : {};
  const remediation =
    normalizedPause.remediation && typeof normalizedPause.remediation === "object" && !Array.isArray(normalizedPause.remediation)
      ? normalizedPause.remediation
      : {};
  const pauseFile = firstNonEmptyString(normalizedPause.file);
  const rerunCommand = normalizedProjectName
    ? `bash scripts/self-improve.sh ${normalizedProjectName}`
    : "bash scripts/self-improve.sh";
  const defaultCommand = pauseFile ? `rm -f ${pauseFile} && ${rerunCommand}` : rerunCommand;

  return {
    active: remediation.active === true || Boolean(pauseFile),
    kind: firstNonEmptyString(remediation.kind, pauseFile ? "remove_pause_file" : "rerun_self_improve"),
    title: firstNonEmptyString(remediation.title, pauseFile ? "Remove self-improve pause gate" : "Resume self-improve"),
    summary: firstNonEmptyString(
      remediation.summary,
      pauseFile
        ? `Delete ${pauseFile} and rerun self-improve when autonomous improvement should resume.`
        : `Run ${rerunCommand} once the pause condition has been cleared.`,
    ),
    command: firstNonEmptyString(remediation.command, defaultCommand),
  };
}

function buildSelfImproveOperatorSignal(projectName = "", gating = {}, pause = {}, metricsSnapshot = {}, metricsInput = {}, artifactFreshness = {}) {
  const overload = gating && typeof gating === "object" && gating.overload && typeof gating.overload === "object"
    ? gating.overload
    : {};
  const analysisReason = firstNonEmptyString(gating.analysis_reason, "none");
  const submissionReason = firstNonEmptyString(gating.submission_reason, "none");
  const normalizedProjectName = firstNonEmptyString(projectName);
  const normalizedPause =
    pause && typeof pause === "object" && !Array.isArray(pause)
      ? pause
      : {};
  const pauseReason = firstNonEmptyString(normalizedPause.reason, "none");
  const pauseDetectedAt = firstNonEmptyString(normalizedPause.detected_at);
  const pauseAgeSeconds = Math.max(0, safeInteger(normalizedPause.age_seconds, 0));
  const normalizedPauseEscalation =
    normalizedPause.escalation && typeof normalizedPause.escalation === "object" && !Array.isArray(normalizedPause.escalation)
      ? normalizedPause.escalation
      : {};
  const pauseEscalationActive =
    normalizedPauseEscalation.active === true
    || (pauseAgeSeconds >= SELF_IMPROVE_PAUSE_ESCALATION_SECONDS && SELF_IMPROVE_PAUSE_ESCALATION_SECONDS > 0);
  const pauseEscalationThresholdSeconds = Math.max(
    0,
    safeInteger(normalizedPauseEscalation.threshold_seconds, SELF_IMPROVE_PAUSE_ESCALATION_SECONDS),
  );
  const pauseEscalationSummary = firstNonEmptyString(
    normalizedPauseEscalation.summary,
    pauseEscalationActive && pauseEscalationThresholdSeconds > 0
      ? `Self-improve has been paused for ${pauseAgeSeconds}s, exceeding the ${pauseEscalationThresholdSeconds}s review threshold.`
      : "",
  );
  const preservedTitle = firstNonEmptyString(overload.preserved_title);
  const blockedCandidateCount = Math.max(0, safeInteger(overload.blocked_candidate_count, 0));
  const activeSelfImproveCount = Math.max(
    0,
    safeInteger(
      gating.resulting_active_self_improve_count,
      safeInteger(gating.active_self_improve_count, 0),
    ),
  );
  const activeSelfImproveCap = Math.max(0, safeInteger(gating.active_self_improve_cap, 0));
  const retryTotalCount = Math.max(0, safeInteger(metricsSnapshot.retry_total_count, 0));
  const retryClassifiedCount = Math.max(0, safeInteger(metricsSnapshot.retry_classified_count, 0));
  const totalFailureRecords = Math.max(0, safeInteger(metricsSnapshot.total_failure_records, 0));
  const failuresWithDiagnostic = Math.max(0, safeInteger(metricsSnapshot.failures_with_diagnostic, 0));
  const rawRetryCoverage = safeNumber(metricsSnapshot.retry_classification_coverage, Number.NaN);
  const retryCoverage = Number.isFinite(rawRetryCoverage) ? clampNumber(rawRetryCoverage, 0, 1) : null;
  const rawZeroStepTimeoutRate = safeNumber(metricsSnapshot.zero_step_timeout_rate, Number.NaN);
  const zeroStepTimeoutRate = Number.isFinite(rawZeroStepTimeoutRate)
    ? clampNumber(rawZeroStepTimeoutRate, 0, 1)
    : null;
  const rawDiagnosticCoverage = safeNumber(metricsSnapshot.diagnostic_coverage, Number.NaN);
  const diagnosticCoverage = Number.isFinite(rawDiagnosticCoverage)
    ? clampNumber(rawDiagnosticCoverage, 0, 1)
    : null;
  const registryPressureScope = firstNonEmptyString(metricsSnapshot.registry_pressure_scope, "none");
  const localRegistryBytes = Math.max(0, safeInteger(metricsSnapshot.local_registry_bytes, 0));
  const dominantRegistrySource =
    metricsSnapshot.registry_pressure_dominant_source
    && typeof metricsSnapshot.registry_pressure_dominant_source === "object"
    && !Array.isArray(metricsSnapshot.registry_pressure_dominant_source)
      ? metricsSnapshot.registry_pressure_dominant_source
      : {};
  const dominantRegistryProject = firstNonEmptyString(dominantRegistrySource.project, "another project");
  const dominantRegistryFileLabel = formatTaskRegistryPressureSourceLabel(dominantRegistrySource.file || "");
  const dominantRegistryBytes = Math.max(0, safeInteger(dominantRegistrySource.payload_bytes, 0));

  if (artifactFreshness.stale === true) {
    return {
      active: true,
      kind: "self_improve_artifact_stale",
      title: "Self-improve artifact is stale",
      summary: "Dashboard self-improve details are older than metrics.json and may not reflect the latest ranking inputs.",
      remediation: buildSelfImproveRerunRemediation(normalizedProjectName),
    };
  }

  if (normalizedPause.active === true || analysisReason === "paused_by_file" || pauseReason === "paused_by_file") {
    if (pauseEscalationActive) {
      return {
        active: true,
        kind: "self_improve_pause_escalated",
        title: firstNonEmptyString(normalizedPauseEscalation.title, "Self-improve pause needs review"),
        summary: pauseEscalationSummary,
        remediation: buildSelfImprovePauseRemediation(normalizedPause, normalizedProjectName),
      };
    }
    const pauseDetail = pauseDetectedAt
      ? ` Pause file detected at ${pauseDetectedAt}.`
      : pauseAgeSeconds > 0
        ? ` Pause has been active for ${pauseAgeSeconds}s.`
        : "";
    return {
      active: true,
      kind: "self_improve_paused",
      title: "Self-improve is paused",
      summary: `Self-improve is intentionally paused by file; no new improvement tasks will be generated until the pause gate is removed.${pauseDetail}`,
      remediation: buildSelfImprovePauseRemediation(normalizedPause, normalizedProjectName),
    };
  }

  if (submissionReason === "active_self_improve_backlog" && activeSelfImproveCount > 0) {
    const capLabel = activeSelfImproveCap > 0 ? `${activeSelfImproveCount}/${activeSelfImproveCap}` : `${activeSelfImproveCount}`;
    return {
      active: true,
      kind: "active_self_improve_backlog",
      title: "Active self-improve backlog is full",
      summary: `${capLabel} active self-improve tasks are already pending, approved, queued, or running; new improvements stay blocked until the backlog drains.`,
      remediation: {
        active: true,
        kind: "drain_self_improve_backlog",
        title: "Drain active self-improve work",
        summary: "Complete, reject, or shelve one active self-improve task before generating another experiment.",
        command: "",
      },
    };
  }

  if (retryTotalCount >= 10 && retryCoverage !== null && retryCoverage < 0.5) {
    const coveragePct = `${Math.round(retryCoverage * 100)}%`;
    const prioritizedTitle = preservedTitle || "Improve retry failure classification coverage";
    return {
      active: true,
      kind: "retry_classification_coverage_low",
      title: "Low retry classification coverage",
      summary: `${coveragePct} classified (${retryClassifiedCount}/${retryTotalCount} retries); self-improve prioritized ${prioritizedTitle}.`,
      remediation: defaultSelfImproveOperatorRemediation(),
    };
  }

  if (
    zeroStepTimeoutRate !== null
    && zeroStepTimeoutRate >= SELF_IMPROVE_ZERO_STEP_TIMEOUT_OPERATOR_THRESHOLD
    && diagnosticCoverage !== null
    && diagnosticCoverage < SELF_IMPROVE_TIMEOUT_DIAGNOSTIC_COVERAGE_OPERATOR_THRESHOLD
    && totalFailureRecords >= SELF_IMPROVE_TIMEOUT_DIAGNOSTIC_COVERAGE_MIN_FAILURES
    && (!preservedTitle || preservedTitle === SELF_IMPROVE_TIMEOUT_DIAGNOSTIC_COVERAGE_TITLE)
  ) {
    const diagnosticCoveragePct = `${Math.round(diagnosticCoverage * 100)}%`;
    const zeroStepTimeoutPct = `${Math.round(zeroStepTimeoutRate * 100)}%`;
    return {
      active: true,
      kind: "timeout_diagnostic_coverage_low",
      title: "Low timeout diagnostic coverage",
      summary: `${diagnosticCoveragePct} diagnostic coverage (${failuresWithDiagnostic}/${totalFailureRecords} failures) while ${zeroStepTimeoutPct} of timeout failures ended before any step started; self-improve prioritized ${SELF_IMPROVE_TIMEOUT_DIAGNOSTIC_COVERAGE_TITLE}.`,
      remediation: {
        active: true,
        kind: "repair_timeout_diagnostics",
        title: "Repair timeout diagnostics first",
        summary: "Improve deterministic failed-step timeout evidence before retrying generic timeout-reduction work.",
        command: "",
      },
    };
  }

  if (overload.active === true && preservedTitle) {
    const blockedSummary =
      blockedCandidateCount > 0
        ? `${blockedCandidateCount} other candidate${blockedCandidateCount === 1 ? "" : "s"} blocked.`
        : "No other overload candidates are currently blocked.";
    return {
      active: true,
      kind: "overload_preserved_focus",
      title: "Preserved self-improve focus",
      summary: `${preservedTitle} remains the selected improvement. ${blockedSummary}`,
      remediation: defaultSelfImproveOperatorRemediation(),
    };
  }

  const metricsInputStatus = firstNonEmptyString(metricsInput.status, "unknown");
  const metricsInputReason = firstNonEmptyString(metricsInput.reason, "not_checked");
  if (metricsInputStatus === "incomplete" || metricsInputStatus === "refresh_failed") {
    return {
      active: true,
      kind: metricsInputStatus === "refresh_failed" ? "metrics_input_refresh_failed" : "metrics_input_incomplete",
      title: metricsInputStatus === "refresh_failed" ? "Self-improve metrics refresh failed" : "Self-improve metrics incomplete",
      summary: `Self-improve used degraded metrics input because ${describeSelfImproveMetricsInputReason(metricsInputReason)}.`,
      remediation: buildSelfImproveMetricsInputRemediation(
        normalizedProjectName,
        metricsInputStatus,
        metricsInputReason,
      ),
    };
  }

  if (analysisReason === "cross_project_registry_pressure" && registryPressureScope === "cross_project") {
    const dominantLabel = dominantRegistryBytes > 0
      ? formatTaskRegistryPressureBytes(dominantRegistryBytes)
      : "dominant external registry size unavailable";
    const localLabel = localRegistryBytes > 0
      ? formatTaskRegistryPressureBytes(localRegistryBytes)
      : "local registry size unavailable";
    const sourceDetail = dominantRegistryFileLabel
      ? `Dominant source: ${dominantRegistryProject} · ${dominantRegistryFileLabel}.`
      : `Dominant source: ${dominantRegistryProject}.`;
    return {
      active: true,
      kind: "cross_project_registry_pressure",
      title: "Shared registry pressure is external",
      summary: `Self-improve skipped local registry compaction because shared pressure is dominated by ${dominantRegistryProject} (${dominantLabel}) while ${normalizedProjectName || "this project"} is ${localLabel}.`,
      remediation: {
        active: true,
        kind: "inspect_external_registry_pressure",
        title: "Inspect dominant registry source",
        summary: `${sourceDetail} Compact or archive that registry before changing local pressure policies.`,
        command: "",
      },
    };
  }

  if (zeroStepTimeoutRate !== null && zeroStepTimeoutRate >= SELF_IMPROVE_ZERO_STEP_TIMEOUT_OPERATOR_THRESHOLD) {
    const zeroStepTimeoutPct = `${Math.round(zeroStepTimeoutRate * 100)}%`;
    return {
      active: true,
      kind: "zero_step_timeout_pressure_high",
      title: "Critical zero-step timeout pressure",
      summary: `${zeroStepTimeoutPct} of timeout failures ended before any step started; planning/setup is likely exhausting the worker budget.`,
      remediation: {
        active: true,
        kind: "inspect_timeout_budget",
        title: "Inspect planning budget before retrying",
        summary: "Prioritize planning-budget and setup fixes before retrying more timeout-prone tasks.",
        command: "",
      },
    };
  }

  if (metricsInputStatus === "refreshed") {
    const refreshedStale = metricsInputReason.startsWith("stale_against_");
    return {
      active: true,
      kind: refreshedStale ? "metrics_input_stale_refresh" : "metrics_input_repaired",
      title: refreshedStale ? "Refreshed stale self-improve metrics" : "Repaired self-improve metrics",
      summary: `Self-improve refreshed ${refreshedStale ? "stale" : "incomplete"} metrics before ranking improvements because ${describeSelfImproveMetricsInputReason(metricsInputReason)}.`,
      remediation: defaultSelfImproveOperatorRemediation(),
    };
  }

  return {
    active: false,
    kind: "none",
    title: "",
    summary: "",
    remediation: defaultSelfImproveOperatorRemediation(),
  };
}

function buildSelfImproveSummary(payload = {}, options = {}) {
  const fallback = defaultSelfImproveSummary();
  const snapshot = payload && typeof payload === "object" ? payload : {};
  const selection = snapshot.selection && typeof snapshot.selection === "object" ? snapshot.selection : {};
  const counts = snapshot.counts && typeof snapshot.counts === "object" ? snapshot.counts : {};
  const gating = snapshot.gating && typeof snapshot.gating === "object" ? snapshot.gating : {};
  const overload = gating.overload && typeof gating.overload === "object" ? gating.overload : {};
  const overloadCandidates = Array.isArray(overload.candidates) ? overload.candidates : [];
  const automationMemory =
    snapshot.automation_memory && typeof snapshot.automation_memory === "object" && !Array.isArray(snapshot.automation_memory)
      ? snapshot.automation_memory
      : {};
  const metricsInput =
    snapshot.metrics_input && typeof snapshot.metrics_input === "object" && !Array.isArray(snapshot.metrics_input)
      ? snapshot.metrics_input
      : {};
  const pause =
    snapshot.pause && typeof snapshot.pause === "object" && !Array.isArray(snapshot.pause)
      ? snapshot.pause
      : {};
  const pauseRemediation =
    pause.remediation && typeof pause.remediation === "object" && !Array.isArray(pause.remediation)
      ? pause.remediation
      : {};
  const pauseEscalation =
    pause.escalation && typeof pause.escalation === "object" && !Array.isArray(pause.escalation)
      ? pause.escalation
      : {};
  const metricsSnapshot =
    snapshot.metrics_snapshot && typeof snapshot.metrics_snapshot === "object" && !Array.isArray(snapshot.metrics_snapshot)
      ? snapshot.metrics_snapshot
      : {};
  const generatedAt = firstNonEmptyString(snapshot.generated_at);
  const rawStatus = firstNonEmptyString(snapshot.status);
  const artifactFreshness = buildSelfImproveArtifactFreshness(generatedAt, options);
  const operatorSignal = buildSelfImproveOperatorSignal(
    firstNonEmptyString(snapshot.project),
    gating,
    pause,
    metricsSnapshot,
    metricsInput,
    artifactFreshness,
  );
  const automationMemoryFile = firstNonEmptyString(automationMemory.memory_file);
  const automationMemoryExists = automationMemory.exists === true || Boolean(automationMemoryFile);
  const automationMemoryReadable = automationMemory.readable === true;
  const automationMemorySource = firstNonEmptyString(automationMemory.source, automationMemoryExists ? "external" : "none");
  let automationMemoryContinuity = firstNonEmptyString(automationMemory.continuity_status);
  if (!automationMemoryContinuity) {
    if (automationMemoryReadable) {
      if (automationMemorySource === "mirror" || automationMemory.external_sync_pending === true) {
        automationMemoryContinuity = "mirror_only";
      } else if (automationMemory.external_hydrated === true) {
        automationMemoryContinuity = "hydrated_external";
      } else {
        automationMemoryContinuity = "external";
      }
    } else {
      automationMemoryContinuity = "missing";
    }
  }

  return {
    status: rawStatus || (generatedAt ? "success" : fallback.status),
    project: firstNonEmptyString(snapshot.project),
    generated_at: generatedAt,
    selected_improvement: firstNonEmptyString(
      snapshot.selected_improvement,
      selection.selected_title,
    ),
    selection: {
      selected_title: firstNonEmptyString(
        selection.selected_title,
        snapshot.selected_improvement,
      ),
      state: firstNonEmptyString(selection.state, "none"),
      submitted_titles: Array.isArray(selection.submitted_titles)
        ? selection.submitted_titles
            .map((value) => firstNonEmptyString(value))
            .filter((value) => value)
            .slice(0, 8)
        : [],
      ranked_titles: Array.isArray(selection.ranked_titles)
        ? selection.ranked_titles
            .map((value) => firstNonEmptyString(value))
            .filter((value) => value)
            .slice(0, 8)
        : [],
      next_title: firstNonEmptyString(selection.next_title),
    },
    counts: {
      detected: Math.max(0, safeInteger(counts.detected, 0)),
      generated: Math.max(0, safeInteger(counts.generated, 0)),
      submitted: Math.max(0, safeInteger(counts.submitted, 0)),
      skipped: Math.max(0, safeInteger(counts.skipped, 0)),
      blocked_analysis: Math.max(0, safeInteger(counts.blocked_analysis, 0)),
    },
    pause: {
      active: pause.active === true,
      reason: firstNonEmptyString(pause.reason, "none"),
      file: firstNonEmptyString(pause.file),
      detected_at: firstNonEmptyString(pause.detected_at),
      age_seconds: Math.max(0, safeInteger(pause.age_seconds, 0)),
      escalation: {
        active: pauseEscalation.active === true,
        kind: firstNonEmptyString(pauseEscalation.kind, "none"),
        severity: firstNonEmptyString(pauseEscalation.severity, "none"),
        threshold_seconds: Math.max(0, safeInteger(pauseEscalation.threshold_seconds, 0)),
        title: firstNonEmptyString(pauseEscalation.title),
        summary: firstNonEmptyString(pauseEscalation.summary),
      },
      remediation: {
        active: pauseRemediation.active === true,
        kind: firstNonEmptyString(pauseRemediation.kind, "none"),
        title: firstNonEmptyString(pauseRemediation.title),
        summary: firstNonEmptyString(pauseRemediation.summary),
        command: firstNonEmptyString(pauseRemediation.command),
      },
    },
    gating: {
      dominant_reason: firstNonEmptyString(gating.dominant_reason, "none"),
      analysis_reason: firstNonEmptyString(gating.analysis_reason, "none"),
      submission_reason: firstNonEmptyString(gating.submission_reason, "none"),
      active_self_improve_count: Math.max(0, safeInteger(gating.active_self_improve_count, 0)),
      resulting_active_self_improve_count: Math.max(
        0,
        safeInteger(
          gating.resulting_active_self_improve_count,
          safeInteger(gating.active_self_improve_count, 0),
        ),
      ),
      active_self_improve_cap: Math.max(0, safeInteger(gating.active_self_improve_cap, 0)),
      backlog_bypass_active: gating.backlog_bypass_active === true,
      backlog_gate_active: gating.backlog_gate_active === true,
      overload: {
        active: overload.active === true,
        preserved_title: firstNonEmptyString(overload.preserved_title),
        preserved_reason: firstNonEmptyString(overload.preserved_reason, overload.active === true ? "unknown" : "inactive"),
        candidate_count: Math.max(0, safeInteger(overload.candidate_count, overloadCandidates.length)),
        blocked_candidate_count: Math.max(
          0,
          safeInteger(
            overload.blocked_candidate_count,
            overloadCandidates.filter((candidate) => candidate && candidate.blocked === true).length,
          ),
        ),
        candidates: overloadCandidates
          .filter((candidate) => candidate && typeof candidate === "object")
          .slice(0, 8)
          .map((candidate) => ({
            title: firstNonEmptyString(candidate.title),
            blocked: candidate.blocked === true,
            blocked_reason: firstNonEmptyString(candidate.blocked_reason, "none"),
            score: Math.max(0, safeInteger(candidate.score, 0)),
            static_priority: Math.max(0, safeInteger(candidate.static_priority, 0)),
            signal_priority: Math.max(0, safeInteger(candidate.signal_priority, 0)),
            recent_failures_since_latest_success: Math.max(
              0,
              safeInteger(candidate.recent_failures_since_latest_success, 0),
            ),
            recent_self_improve_failures: Math.max(0, safeInteger(candidate.recent_self_improve_failures, 0)),
          })),
      },
    },
    operator_signal: operatorSignal,
    automation_memory: {
      automation_id: firstNonEmptyString(automationMemory.automation_id),
      exists: automationMemoryExists,
      memory_file: automationMemoryFile,
      source: automationMemorySource,
      external_hydrated: automationMemory.external_hydrated === true,
      external_sync_pending: automationMemory.external_sync_pending === true,
      readable: automationMemoryReadable,
      continuity_status: automationMemoryContinuity,
    },
    metrics_input: {
      status: firstNonEmptyString(metricsInput.status, "unknown"),
      refresh_performed: metricsInput.refresh_performed === true,
      reason: firstNonEmptyString(metricsInput.reason, "not_checked"),
      missing_keys: Array.isArray(metricsInput.missing_keys)
        ? metricsInput.missing_keys
            .map((value) => firstNonEmptyString(value))
            .filter((value) => value)
            .slice(0, 8)
        : [],
    },
    artifact_freshness: artifactFreshness,
    metrics_snapshot: metricsSnapshot,
  };
}

function buildProjectSelfImproveSummary(project, payload = {}, options = {}) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const summary = buildSelfImproveSummary(payload, options);
  const artifactProject = sanitizeProjectName(summary.project || "");
  const matchesProject = artifactProject ? artifactProject === projectKey : projectKey === STRATEGY_PRIMARY_PROJECT;

  if (!matchesProject) {
    return {
      ...defaultSelfImproveSummary(),
      project: projectKey,
      scoped_to_project: false,
      source_project: artifactProject || "",
    };
  }

  return {
    ...summary,
    project: artifactProject || projectKey,
    scoped_to_project: true,
    source_project: artifactProject || projectKey,
  };
}

function buildProjectOverviewSignal(taskRegistryPressure = {}, selfImproveSummary = {}) {
  const operatorSignal =
    selfImproveSummary && typeof selfImproveSummary === "object"
    && selfImproveSummary.operator_signal && typeof selfImproveSummary.operator_signal === "object"
      ? selfImproveSummary.operator_signal
      : {};
  const operatorSummary = firstNonEmptyString(operatorSignal.summary);

  if (operatorSignal.active === true && operatorSummary) {
    const operatorRemediation =
      operatorSignal.remediation && typeof operatorSignal.remediation === "object"
        ? operatorSignal.remediation
        : {};
    const selfImproveGating =
      selfImproveSummary && typeof selfImproveSummary === "object"
      && selfImproveSummary.gating && typeof selfImproveSummary.gating === "object"
        ? selfImproveSummary.gating
        : {};
    const activeSelfImproveCount = Math.max(
      0,
      safeInteger(
        selfImproveGating.resulting_active_self_improve_count,
        safeInteger(selfImproveGating.active_self_improve_count, 0),
      ),
    );
    const activeSelfImproveCap = Math.max(0, safeInteger(selfImproveGating.active_self_improve_cap, 0));
    const activeSelfImproveDetail =
      activeSelfImproveCount > 0
        ? `Active self-improve backlog ${activeSelfImproveCap > 0 ? `${activeSelfImproveCount}/${activeSelfImproveCap}` : `${activeSelfImproveCount}`}.`
        : "";
    return {
      active: true,
      source: "self_improve",
      kind: firstNonEmptyString(operatorSignal.kind, "self_improve"),
      title: firstNonEmptyString(operatorSignal.title, "Self-improve focus"),
      summary: operatorSummary,
      detail: firstNonEmptyString(
        activeSelfImproveDetail,
        operatorRemediation.summary,
        selfImproveSummary?.selected_improvement,
        selfImproveSummary?.gating?.overload?.preserved_title,
      ),
      command: firstNonEmptyString(operatorRemediation.command),
    };
  }

  const pressureSummary = firstNonEmptyString(taskRegistryPressure.summary);
  if (taskRegistryPressure.detected === true && pressureSummary) {
    return {
      active: true,
      source: "task_registry_pressure",
      kind: taskRegistryPressure.dominant === true
        ? "task_registry_pressure_dominant"
        : "task_registry_pressure_contributor",
      title: firstNonEmptyString(taskRegistryPressure.headline, "Registry pressure"),
      summary: pressureSummary,
      detail: firstNonEmptyString(taskRegistryPressure.source_label),
    };
  }

  return defaultProjectOverviewSignal();
}

function readMarkdownBulletRules(filePath) {
  if (!filePath) {
    return [];
  }
  try {
    return fs
      .readFileSync(filePath, "utf8")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.startsWith("- "))
      .map((line) => line.slice(2).replace(/\s+/g, " ").trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

function buildLearningEfficiencySnapshot(records) {
  const uniqueRules = new Set([
    ...readMarkdownBulletRules(PATHS.rules),
    ...readMarkdownBulletRules(PATHS.promptRules),
  ]);

  let knowledgeCount = 0;
  try {
    const payload = JSON.parse(fs.readFileSync(PATHS.knowledge, "utf8"));
    const rules = Array.isArray(payload?.rules) ? payload.rules : [];
    knowledgeCount = rules.length;
  } catch {
    knowledgeCount = 0;
  }

  const totalRecords = Array.isArray(records) ? records.length : 0;
  const learningRate = totalRecords > 0
    ? Number((uniqueRules.size / (totalRecords / 100)).toFixed(2))
    : 0;

  return {
    learning_rules_count: uniqueRules.size,
    learning_knowledge_count: knowledgeCount,
    learning_rate_per_100_tasks: learningRate,
  };
}

function buildPersistedMetrics(tasks, records, externalSignals = null, options = {}) {
  const registryTasks = Array.isArray(tasks) ? tasks.filter((task) => task && typeof task === "object") : [];
  const firstPassSignal = buildFirstPassSuccessSignal("", registryTasks, records);
  const loopEffortSignal = buildLoopEffortSignal("", registryTasks);
  const loopEffortBoundedExperiment = buildLoopEffortBoundedExperiment(loopEffortSignal);
  const boardHealthSignals = buildPersistedBoardHealthSignals("", registryTasks, records);
  const strategySaturationSignal = buildStrategySaturationSignal("", registryTasks);
  const externalResearch = buildExternalResearchSummary(externalSignals);
  const selfImprove = buildSelfImproveSummary(options.selfImproveRun);
  const taskRegistryPressureSignal = buildTaskRegistryPressureSignal(registryTasks, options);
  const learningEfficiency = buildLearningEfficiencySnapshot(records);
  const totalRecords = records.length;
  const successRecords = records.filter((record) => String(record.result || "").trim() === "SUCCESS").length;
  const timeoutFailureRecords = countUnresolvedTimeoutRecords(records, registryTasks);
  const pendingApproval = registryTasks.filter(
    (task) => String(task.status || "").trim().toLowerCase() === "pending_approval",
  ).length;
  const approved = registryTasks.filter(
    (task) => String(task.status || "").trim().toLowerCase() === "approved",
  ).length;
  const queued = registryTasks.filter(
    (task) => String(task.status || "").trim().toLowerCase() === "queued",
  ).length;
  const running = registryTasks.filter(
    (task) => String(task.status || "").trim().toLowerCase() === "running",
  ).length;
  const lastTask = registryTasks[registryTasks.length - 1] || null;
  const manualRecoveryRecords = records.filter(
    (record) => String(record.source || "").trim() === "manual_recovery",
  ).length;

  return {
    total_tasks: totalRecords,
    success_rate: totalRecords ? Number((successRecords / totalRecords).toFixed(2)) : 0,
    timeout_failure_records: timeoutFailureRecords,
    timeout_failure_rate: totalRecords ? Number((timeoutFailureRecords / totalRecords).toFixed(2)) : 0,
    analysis_runs: registryTasks.length,
    pending_approval_tasks: pendingApproval,
    approved_tasks: approved,
    approved_backlog: approved,
    queued_tasks: queued,
    running_tasks: running,
    task_registry_total: registryTasks.length,
    task_registry_payload_bytes: taskRegistryPressureSignal.task_registry_payload_bytes,
    task_registry_pressure_bytes: taskRegistryPressureSignal.task_registry_payload_bytes,
    task_registry_pressure_detected: taskRegistryPressureSignal.task_registry_pressure_detected,
    task_registry_pressure_primary_surface: taskRegistryPressureSignal.task_registry_pressure_primary_surface,
    last_task_score: lastTask ? safeNumber(lastTask.score, 0) : 0,
    manual_recovery_records: manualRecoveryRecords,
    strategy_saturation_detected: strategySaturationSignal.detected,
    strategy_saturation: strategySaturationSignal.detected,
    saturated_failed_tasks: strategySaturationSignal.saturated_failed_tasks,
    retry_churn_detected: boardHealthSignals.retry_churn_detected,
    queue_starvation_detected: boardHealthSignals.queue_starvation_detected,
    pending_approval_blocked_detected: boardHealthSignals.pending_approval_blocked_detected,
    first_pass_success_rate: firstPassSignal.first_pass_success_rate,
    first_pass_success_count: firstPassSignal.first_pass_success_count,
    multi_attempt_resolved_count: firstPassSignal.multi_attempt_resolved_count,
    loop_effort_detected: loopEffortSignal.detected,
    loop_effort_task_count: loopEffortSignal.loop_effort_task_count,
    loop_effort_extra_step_attempts: loopEffortSignal.loop_effort_extra_step_attempts,
    loop_effort_bounded_experiment_detected: loopEffortBoundedExperiment.detected,
    loop_effort_bounded_experiment_metric_name: loopEffortBoundedExperiment.metric_name,
    loop_effort_bounded_experiment_extra_step_threshold: loopEffortBoundedExperiment.extra_step_threshold,
    loop_effort_bounded_experiment_message: loopEffortBoundedExperiment.message,
    external_signal_status: externalResearch.status,
    external_signal_count: externalResearch.total_signals,
    fresh_external_signal_count: externalResearch.fresh_signals,
    external_signal_error_count: externalResearch.errors,
    external_signal_updated_at: externalResearch.updated_at,
    latest_external_signal_source: externalResearch.latest_signal?.source_label || "",
    latest_external_signal_title: externalResearch.latest_signal?.title || "",
    latest_external_signal_url: externalResearch.latest_signal?.url || "",
    latest_external_signal_published_at: externalResearch.latest_signal?.published_at || "",
    learning_rules_count: learningEfficiency.learning_rules_count,
    learning_knowledge_count: learningEfficiency.learning_knowledge_count,
    learning_rate_per_100_tasks: learningEfficiency.learning_rate_per_100_tasks,
    self_improve_status: selfImprove.status,
    self_improve_generated_at: selfImprove.generated_at,
    self_improve_detected_count: selfImprove.counts.detected,
    self_improve_generated_count: selfImprove.counts.generated,
    self_improve_submitted_count: selfImprove.counts.submitted,
    self_improve_skipped_count: selfImprove.counts.skipped,
    self_improve_dominant_reason: selfImprove.gating.dominant_reason,
  };
}

async function refreshPersistedPriority(tasks = null) {
  const registryPayload = tasks === null ? await readTaskRegistryPayload() : { tasks };
  const priorityPayload = await readJsonFile(PATHS.priority, { categories: DEFAULT_PRIORITY_CATEGORIES });
  const learnedPriority = applyPriorityLearningSnapshot(priorityPayload, registryPayload.tasks);
  await writeJsonFile(PATHS.priority, learnedPriority);
  return learnedPriority;
}

async function refreshPersistedMetrics(tasks = null) {
  const [taskLog, registryPayload, externalSignals, selfImproveRun] = await Promise.all([
    readText(PATHS.taskLog),
    tasks === null ? readTaskRegistryPayload() : Promise.resolve({ tasks }),
    readJsonFile(PATHS.externalSignals, {}),
    readJsonFile(PATHS.selfImproveRun, {}),
  ]);
  const records = parseJsonLines(taskLog);
  const metrics = buildPersistedMetrics(registryPayload.tasks, records, externalSignals, {
    task_registry_payload_bytes: registryPayload.payloadBytes,
    selfImproveRun,
  });
  await Promise.all([writeJsonFile(PATHS.metrics, metrics), refreshPersistedPriority(registryPayload.tasks)]);
  return metrics;
}

function buildTaskHistoryEntry(task, action, fromStatus, toStatus, extra = {}) {
  return {
    at: extra.at || nowUtc(),
    action,
    from_status: fromStatus,
    to_status: toStatus,
    project: extra.project || task.project || "",
    queue_task: extra.queueTask || task.execution_task || task.title || "",
    note: extra.note || "",
  };
}

function appendTaskHistory(task, entry) {
  const history = Array.isArray(task.history) ? task.history.slice(-19) : [];
  return [...history, entry];
}

function normalizeTaskProject(task) {
  return resolveTaskProject(task);
}

function taskExecutionText(task) {
  return sanitizeTaskText(task.execution_task || task.title || "");
}

function buildApprovalExecutionBrief({ approvedAt, project, queueTask, provider, queueStatus, taskIntent, taskShape }) {
  const normalizedProject = sanitizeProjectName(project || "") || "codex-agent-system";
  const normalizedQueueTask = sanitizeTaskText(queueTask || "");
  const normalizedTaskIntent =
    taskIntent && typeof taskIntent === "object"
      ? normalizeTaskIntentRecord(
          {
            task_intent: taskIntent,
          },
          normalizedQueueTask,
          normalizedProject,
          sanitizeTaskText(taskIntent.category || "") || "code_quality",
        )
      : null;
  const normalizedTaskShape = taskShape && typeof taskShape === "object" ? taskShape : null;
  const shapeEditableFiles = splitListInput(normalizedTaskShape?.editable_files || normalizedTaskShape?.editableFiles);
  const editableFiles = shapeEditableFiles.length
    ? shapeEditableFiles
    : splitListInput(normalizedTaskIntent?.affected_files);
  const frozenFiles = splitListInput(normalizedTaskShape?.frozen_files || normalizedTaskShape?.frozenFiles);
  const frozenVerifyCommand = sanitizeTaskText(
    normalizedTaskShape?.verification_command ||
      normalizedTaskShape?.frozen_verify_command ||
      normalizedTaskShape?.frozenVerifyCommand ||
      "",
  );
  return {
    approved_at: typeof approvedAt === "string" ? approvedAt : "",
    project: normalizedProject,
    queue_task: normalizedQueueTask,
    provider: normalizeProviderName(provider) || "codex",
    queue_status: typeof queueStatus === "string" ? queueStatus : "",
    status: typeof queueStatus === "string" ? queueStatus : "",
    source: normalizedTaskIntent?.source || "",
    objective: normalizedTaskIntent?.objective || normalizedQueueTask,
    category: normalizedTaskIntent?.category || "",
    context_hint: normalizedTaskIntent?.context_hint || "",
    constraints: Array.isArray(normalizedTaskIntent?.constraints) ? normalizedTaskIntent.constraints : [],
    success_signals: Array.isArray(normalizedTaskIntent?.success_signals) ? normalizedTaskIntent.success_signals : [],
    editable_files: editableFiles,
    frozen_files: frozenFiles,
    frozen_verify_command: frozenVerifyCommand,
    affected_files: Array.isArray(normalizedTaskIntent?.affected_files) ? normalizedTaskIntent.affected_files : [],
    task_intent: normalizedTaskIntent,
  };
}

function buildApprovalExecutionSnapshot({ approvedAt, project, queueTask, provider, queueStatus }) {
  return {
    approved_at: typeof approvedAt === "string" ? approvedAt : "",
    project: sanitizeProjectName(project || "") || "codex-agent-system",
    queue_task: sanitizeTaskText(queueTask || ""),
    provider: normalizeProviderName(provider) || "codex",
    queue_status: typeof queueStatus === "string" ? queueStatus : "",
  };
}

function nextTaskRegistryId(tasks, project, title) {
  const projectKey = sanitizeProjectName(project || "") || "codex-agent-system";
  const useProjectScopedPrefix = projectKey !== "codex-agent-system" && projectUsesDedicatedTaskRegistry(projectKey);
  const idPrefix = useProjectScopedPrefix ? `${projectKey}-task-` : "task-";
  const idPattern = new RegExp(`^${idPrefix.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\$&")}(\\d+)-`);
  const maxIndex = (Array.isArray(tasks) ? tasks : []).reduce((highest, task) => {
    if (sanitizeProjectName(task?.project || "") !== projectKey) {
      return highest;
    }
    const match = idPattern.exec(String(task?.id || "").trim());
    if (!match) {
      return highest;
    }
    return Math.max(highest, Number(match[1]) || 0);
  }, 0);
  const prefix = String(maxIndex + 1).padStart(3, "0");
  return `${idPrefix}${prefix}-${taskSlug(title) || "untitled"}`;
}

async function createTaskRegistryItem(input) {
  const project = sanitizeProjectName(input.project || input.newProject || "") || "codex-agent-system";
  const payload = await readProjectTaskRegistryPayload(project);
  const successMessage =
    sanitizeTaskText(input.successMessage || "Task added to backlog.") || "Task added to backlog.";
  const successStatus = clampNumber(Math.round(safeNumber(input.successStatus, 201)), 200, 299);
  const projectTasks = Array.isArray(payload.tasks) ? payload.tasks : [];
  const categories = await readPriorityCategories();
  const result = buildPendingTaskRecord(projectTasks, categories, input);
  if (!result.ok) {
    return result;
  }
  const nextTask = result.task;

  payload.tasks = [...projectTasks, nextTask];
  await writeProjectTaskRegistryPayload(project, payload);
  await refreshPersistedMetrics(await readTaskRegistry());
  await appendLog(`Created pending task ${nextTask.id} for ${nextTask.project}: ${nextTask.title}`);

  if (input.autoApprove === true) {
    const taskShape = nextTask.task_shape && typeof nextTask.task_shape === "object" ? nextTask.task_shape : buildTaskShape(nextTask);
    const allowAutoApprove = taskShape.approval_ready && taskShape.manual_review_required !== true;
    if (!allowAutoApprove) {
      return {
        ok: true,
        status: successStatus,
        task: nextTask,
        message:
          taskShape.manual_review_required === true
            ? `${successMessage} Auto-approve was suppressed by project policy; task remains pending manual review.`
            : `${successMessage} Auto-approve left the task pending because it is not approval-ready.`,
      };
    }
    const autoApproval = await applyAutoApproveToTaskIds([{ id: nextTask.id, project: nextTask.project }]);
    const finalTask =
      autoApproval.tasksByIdentity[taskIdentityKey(nextTask.id, nextTask.project)] || autoApproval.tasksById[nextTask.id] || nextTask;
    return {
      ok: true,
      status: successStatus,
      task: finalTask,
      message: autoApproval.approved.length
        ? "Task auto-approved and queued."
        : `${successMessage} Auto-approve left the task pending: ${autoApproval.errors[0]?.error || "approval did not complete."}`,
      auto_approve: autoApproval,
    };
  }

  return {
    ok: true,
    status: successStatus,
    task: nextTask,
    message: successMessage,
  };
}

async function createTaskRegistryItemsFromPrompt(input) {
  const project = sanitizeProjectName(input.project || input.newProject || "");
  const prompt = sanitizeTaskText(input.prompt || input.taskPrompt || input.task_prompt || "");
  if (!project) {
    return { ok: false, status: 400, error: "Project is required." };
  }
  if (!prompt) {
    return { ok: false, status: 400, error: "Prompt is required." };
  }
  const payload = await readProjectTaskRegistryPayload(project);
  const projectTasks = Array.isArray(payload.tasks) ? payload.tasks : [];
  const categories = await readPriorityCategories();

  const derivedTitles = splitPromptIntoTaskTitles(prompt);
  const shapedTitles = [];
  const seenShapedTitles = new Set();
  for (const title of derivedTitles) {
    for (const shapedTitle of splitBroadDerivedTitle(title)) {
      const shapedKey = normalizeTask(shapedTitle);
      if (!shapedTitle || seenShapedTitles.has(shapedKey)) {
        continue;
      }
      seenShapedTitles.add(shapedKey);
      shapedTitles.push(shapedTitle);
    }
  }

  if (!shapedTitles.length) {
    return { ok: false, status: 400, error: "Prompt did not produce any actionable task candidates." };
  }

  const created = [];
  const skipped = [];
  const transitionAt = nowUtc();
  for (const [index, title] of shapedTitles.entries()) {
    const titleValidation = validatePromptDerivedTitle(title, prompt);
    if (!titleValidation.ok) {
      skipped.push({ title, reason: titleValidation.reason });
      continue;
    }
    const effort = title.length > 110 ? 4 : title.length > 70 ? 3 : 2;
    const category = inferTaskCategory(title, Object.keys(categories));
    const result = buildPendingTaskRecord(payload.tasks, categories, {
      project,
      title,
      task: title,
      category,
      impact: category === "ui" ? 7 : category === "stability" ? 8 : category === "performance" ? 7 : 6,
      effort,
      confidence: effort >= 4 ? 0.74 : 0.82,
      reason:
        sanitizeTaskText(
          input.reason ||
            `Derived from a dashboard prompt intake so the request can be reviewed as smaller approval-ready tasks.`,
        ) || `Derived from a dashboard prompt intake so the request can be reviewed as smaller approval-ready tasks.`,
      contextHint: `Derived from prompt: ${excerptText(prompt, 240)}`,
      successCriteria: `Task is reviewable on its own\nThe broader prompt is decomposed into smaller approval items`,
      constraints: `Keep the change small\nDo not bypass approval\nStay within the selected project`,
      historyNote: `Task was derived from dashboard prompt intake (${index + 1}/${shapedTitles.length}).`,
      taskIntentSource: "dashboard_prompt_intake",
      executionProvider: input.executionProvider || input.execution_provider,
      prompt,
      promptMeta: { index: index + 1, total: shapedTitles.length },
      transitionAt,
    });
    if (!result.ok) {
      if (result.status === 409) {
        skipped.push({ title, reason: result.error });
        continue;
      }
      return result;
    }
    payload.tasks = [...payload.tasks, result.task];
    created.push(result.task);
  }

  if (!created.length) {
    const duplicateOnly = skipped.length > 0 && skipped.every((entry) => entry.reason === "Task is already tracked and actionable for this project.");
    return {
      ok: false,
      status: duplicateOnly ? 409 : 400,
      error: duplicateOnly
        ? "Prompt only produced tasks that are already tracked for this project."
        : "Prompt only produced malformed or non-actionable task candidates.",
      skipped,
    };
  }

  await writeProjectTaskRegistryPayload(project, payload);
  await refreshPersistedMetrics(await readTaskRegistry());
  await appendLog(`Derived ${created.length} pending task(s) from prompt for ${project}.`);

  let responseTasks = created;
  let message = `Derived ${created.length} task${created.length === 1 ? "" : "s"} for ${project}.`;
  let autoApproval = null;
  if (input.autoApprove === true) {
    const eligibleTasks = created.filter((task) => {
      const taskShape = task.task_shape && typeof task.task_shape === "object" ? task.task_shape : buildTaskShape(task);
      return taskShape.approval_ready && taskShape.manual_review_required !== true;
    });
    if (eligibleTasks.length > 0) {
      autoApproval = await applyAutoApproveToTaskIds(
        eligibleTasks.map((task) => ({ id: task.id, project: task.project })),
      );
      responseTasks = created.map(
        (task) => autoApproval.tasksByIdentity[taskIdentityKey(task.id, task.project)] || autoApproval.tasksById[task.id] || task,
      );
      message = autoApproval.approved.length
        ? `Derived ${created.length} task${created.length === 1 ? "" : "s"} for ${project}; auto-approved ${autoApproval.approved.length}.`
        : `Derived ${created.length} task${created.length === 1 ? "" : "s"} for ${project}, but auto-approve left them pending.`;
    } else {
      message = `Derived ${created.length} task${created.length === 1 ? "" : "s"} for ${project}; auto-approve was suppressed by project policy.`;
    }
  }

  return {
    ok: true,
    status: 201,
    tasks: responseTasks,
    created_count: created.length,
    skipped,
    message,
    ...(autoApproval ? { auto_approve: autoApproval } : {}),
  };
}

async function updateTaskRegistryItem(taskId, updates) {
  const requestedProject = sanitizeProjectName(updates?.project || "");
  let located = await locateTaskRegistryTask(taskId, requestedProject);
  if ((!located || (!located.task && !located.conflict)) && requestedProject) {
    located = await locateTaskRegistryTask(taskId, "");
  }
  if (!located || (!located.task && !located.conflict)) {
    return { ok: false, status: 404, error: "Task was not found." };
  }
  if (located.conflict) {
    return {
      ok: false,
      status: 409,
      error: "Task id is ambiguous across projects. Retry with the task project.",
    };
  }

  const payload = located.payload;
  const index = located.index;
  const existing = payload.tasks[index];
  const normalizedTasks = await readTaskRegistry();
  const normalizedTask = normalizedTasks.find((task) => taskIdentityMatches(task, taskId, normalizeTaskProject(existing)));
  const fromStatus = String((normalizedTask || existing).status || "pending_approval");
  if (fromStatus !== "pending_approval") {
    return { ok: false, status: 409, error: "Only pending approval tasks can be edited." };
  }

  const currentTitle = sanitizeTaskText(existing.title || "");
  const currentProject = normalizeTaskProject(existing);
  const nextTitle = sanitizeTaskText(updates.title || currentTitle);
  const nextProject = sanitizeProjectName(updates.project || currentProject) || "codex-agent-system";
  const currentDependsOn = normalizeDependencyTaskIds(existing.depends_on || existing.dependsOn);
  const nextDependsOn = normalizeDependencyTaskIds(
    Object.prototype.hasOwnProperty.call(updates, "dependsOn") || Object.prototype.hasOwnProperty.call(updates, "depends_on")
      ? updates.dependsOn || updates.depends_on
      : currentDependsOn,
  );
  if (!nextTitle) {
    return { ok: false, status: 400, error: "Pending tasks need a non-empty task text." };
  }

  const changedFields = [];
  if (nextTitle !== currentTitle) {
    changedFields.push("title");
  }
  if (nextProject !== currentProject) {
    changedFields.push("project");
  }
  if (JSON.stringify(nextDependsOn) !== JSON.stringify(currentDependsOn)) {
    changedFields.push("depends_on");
  }
  if (!changedFields.length) {
    return {
      ok: true,
      status: 200,
      task: normalizedTask || existing,
      message: "Task already matches the requested text and project.",
    };
  }

  const transitionAt = nowUtc();
  const nextTask = {
    ...existing,
    title: nextTitle,
    project: nextProject,
    updated_at: transitionAt,
  };
  if (nextDependsOn.length) {
    nextTask.depends_on = nextDependsOn;
  } else {
    delete nextTask.depends_on;
  }
  if (existing.task_intent && typeof existing.task_intent === "object") {
    nextTask.task_intent = {
      ...existing.task_intent,
      objective: nextTitle,
      project: nextProject,
    };
  }
  nextTask.task_shape = buildTaskShape({
    title: nextTitle,
    category: nextTask.category,
    task_intent: nextTask.task_intent,
    task_shape: existing.task_shape,
    playbook: existing.task_shape?.playbook || existing.strategy_playbook || "",
    family: existing.task_shape?.family || existing.task_family || "",
    verificationCommand: preservedTaskVerificationCommand(existing),
  });
  if (Object.prototype.hasOwnProperty.call(existing, "execution_task") || nextTitle !== currentTitle) {
    nextTask.execution_task = nextTitle;
  }
  nextTask.history = appendTaskHistory(
    nextTask,
    buildTaskHistoryEntry(nextTask, "edit", fromStatus, fromStatus, {
      at: transitionAt,
      note: `Updated pending task ${changedFields.join(" and ")} from the dashboard.`,
      project: nextProject,
      queueTask: nextTitle,
      changes: {
        ...(nextTitle !== currentTitle ? { title: { from: currentTitle, to: nextTitle } } : {}),
        ...(nextProject !== currentProject ? { project: { from: currentProject, to: nextProject } } : {}),
        ...(JSON.stringify(nextDependsOn) !== JSON.stringify(currentDependsOn)
          ? { depends_on: { from: currentDependsOn, to: nextDependsOn } }
          : {}),
      },
    }),
  );
  const sourcePath = path.resolve(located.filePath);
  const targetPath = path.resolve(projectTaskRegistryPath(nextProject));
  if (sourcePath === targetPath) {
    payload.tasks[index] = nextTask;
    await writeTaskRegistryPayloadAt(located.filePath, payload);
  } else {
    const targetPayload = await readProjectTaskRegistryPayload(nextProject);
    nextTask.id = nextTaskRegistryId(Array.isArray(targetPayload.tasks) ? targetPayload.tasks : [], nextProject, nextTitle);
    payload.tasks.splice(index, 1);
    targetPayload.tasks = [...(Array.isArray(targetPayload.tasks) ? targetPayload.tasks : []), nextTask];
    await writeTaskRegistryPayloadAt(located.filePath, payload);
    await writeProjectTaskRegistryPayload(nextProject, targetPayload);
  }
  await refreshPersistedMetrics(await readTaskRegistry());
  await appendLog(
    `Updated pending task ${taskId}: ${currentProject}/${currentTitle} -> ${nextProject}/${nextTitle}`,
  );
  return {
    ok: true,
    status: 200,
    task: nextTask,
    message: "Pending task updated.",
  };
}

async function transitionTaskRegistryItem(taskId, action, project = "") {
  const located = await locateTaskRegistryTask(taskId, project);
  if (!located || (!located.task && !located.conflict)) {
    return { ok: false, status: 404, error: "Task was not found." };
  }
  if (located.conflict) {
    return {
      ok: false,
      status: 409,
      error: "Task id is ambiguous across projects. Retry with the task project.",
    };
  }

  const payload = located.payload;
  const index = located.index;
  const existing = payload.tasks[index];
  const normalizedTasks = await readTaskRegistry();
  const normalizedTask = normalizedTasks.find((task) => taskIdentityMatches(task, taskId, normalizeTaskProject(existing)));
  const fromStatus = String((normalizedTask || existing).status || "pending_approval");

  if (action === "approve") {
    if (fromStatus !== "pending_approval") {
      return { ok: false, status: 409, error: "Only pending approval tasks can be approved." };
    }
  } else if (action === "retry") {
    if (fromStatus !== "failed") {
      return { ok: false, status: 409, error: "Only failed tasks can be retried." };
    }
  } else if (action !== "reject") {
    return { ok: false, status: 400, error: "Unsupported task action." };
  }

  if (action === "approve" || action === "retry") {
    const actionLabel = action === "retry" ? "retry" : "approval";

    const status = await readStatus();
    const [authHealth, runtimeDashboardStatus] = await Promise.all([
      readCodexAuthHealth(status),
      readRuntimeDashboardStatus(status),
    ]);
    if (authHealth.blocks_queue) {
      const authReason = authHealth.reason ? ` ${authHealth.reason}` : "";
      const cooldownNote = authHealth.remaining_seconds ? ` Retry after ${authHealth.remaining_seconds}s.` : "";
      await appendLog(`Rejected ${actionLabel} for ${taskId} because Codex auth is blocked.`, "WARN");
      return {
        ok: false,
        status: 409,
        error: `Codex auth is blocked. Resolve authentication before sending more work to execution.${authReason}${cooldownNote}`,
      };
    }
    if (runtimeDashboardStatus.runtime?.reload_drift?.restart_needed === true) {
      await appendLog(`Rejected ${actionLabel} for ${taskId} because runtime reload is pending.`, "WARN");
      return {
        ok: false,
        status: 409,
        error: `Runtime reload is pending. Restart the dashboard/runtime before sending more work to execution. ${runtimeDashboardStatus.reload_drift_summary || ""}`.trim(),
      };
    }

    const transitionAt = nowUtc();
    const preparedTask =
      action === "approve"
        ? repairPendingApprovalTask(normalizedTask || existing, normalizedTasks).task
        : normalizedTask || existing;
    const project = normalizeTaskProject(preparedTask);
    const queueTask = taskExecutionText(preparedTask);
    const executionProvider =
      normalizeProviderName(preparedTask.execution_provider || preparedTask.provider_selection?.selected) || "codex";
    const preservedTaskIntent =
      preparedTask.task_intent && typeof preparedTask.task_intent === "object"
        ? preparedTask.task_intent
        : normalizedTask && normalizedTask.task_intent && typeof normalizedTask.task_intent === "object"
          ? normalizedTask.task_intent
          : existing.task_intent && typeof existing.task_intent === "object"
            ? existing.task_intent
          : null;
    const normalizedTaskIntent = preservedTaskIntent
      ? {
          source: sanitizeTaskText(preservedTaskIntent.source || "dashboard_backlog") || "dashboard_backlog",
          objective: sanitizeTaskText(preservedTaskIntent.objective || queueTask) || queueTask,
          project: sanitizeProjectName(preservedTaskIntent.project || project) || "codex-agent-system",
          category:
            sanitizeTaskText(preservedTaskIntent.category || preparedTask.category || existing.category || "code_quality") || "code_quality",
          context_hint: sanitizeTaskText(preservedTaskIntent.context_hint || preservedTaskIntent.contextHint || ""),
          constraints: splitListInput(preservedTaskIntent.constraints),
          success_signals: splitListInput(
            preservedTaskIntent.success_signals || preservedTaskIntent.successSignals,
          ),
          affected_files: splitListInput(
            preservedTaskIntent.affected_files || preservedTaskIntent.affectedFiles,
          ),
        }
      : normalizeTaskIntentRecord(
          preparedTask,
          queueTask,
          project,
          typeof preparedTask.category === "string" ? preparedTask.category : "code_quality",
        );
    const queueTaskIntent =
      normalizedTaskIntent ||
      (preparedTask.task_intent && typeof preparedTask.task_intent === "object" ? preparedTask.task_intent : null);
    const taskShape = buildTaskShape({
      title: queueTask,
      category: preparedTask.category,
      task_intent: queueTaskIntent,
      task_shape: preparedTask.task_shape,
      playbook:
        preparedTask?.task_shape?.playbook ||
        preparedTask?.strategy_playbook ||
        "",
      family:
        preparedTask?.task_shape?.family ||
        preparedTask?.task_family ||
        "",
      editableFiles:
        preparedTask?.task_shape?.editable_files ||
        preparedTask?.task_shape?.editableFiles ||
        preparedTask?.execution_brief?.editable_files ||
        preparedTask?.execution_brief?.editableFiles ||
        queueTaskIntent?.affected_files ||
        queueTaskIntent?.affectedFiles ||
        [],
      frozenFiles:
        preparedTask?.task_shape?.frozen_files ||
        preparedTask?.task_shape?.frozenFiles ||
        preparedTask?.execution_brief?.frozen_files ||
        preparedTask?.execution_brief?.frozenFiles ||
        [],
      verificationCommand: sanitizeTaskText(
        preparedTask?.task_shape?.verification_command ||
          preparedTask?.execution_brief?.frozen_verify_command ||
          "",
      ),
    });
    if (!queueTask) {
      return { ok: false, status: 400, error: "Approved tasks need a non-empty title or execution task." };
    }
    const dependencyState =
      preparedTask.dependency_state && typeof preparedTask.dependency_state === "object"
        ? preparedTask.dependency_state
        : buildTaskDependencyState(preparedTask, buildTaskIndexById(normalizedTasks));
    if (dependencyState.blocked) {
      return {
        ok: false,
        status: 409,
        error: dependencyState.reason || "Task is blocked by unresolved dependencies.",
      };
    }
    if (!taskShape.approval_ready) {
      return {
        ok: false,
        status: 409,
        error: `Task must be split into a smaller approval-ready unit before queue handoff. ${taskShape.reasons[0] || ""}`.trim(),
      };
    }

    const enqueueResult = await enqueueTask(project, queueTask);
    const duplicateQueue = enqueueResult.error === "Duplicate task rejected.";
    const queueStatus = duplicateQueue ? "already_queued" : "queued";
    if (!enqueueResult.ok && !duplicateQueue) {
      return enqueueResult;
    }

    const nextTask = {
      ...existing,
      ...preparedTask,
      project,
      status: "approved",
      approved_at: transitionAt,
      updated_at: transitionAt,
      execution_provider: executionProvider,
      approval_execution_brief: buildApprovalExecutionSnapshot({
        approvedAt: transitionAt,
        project,
        queueTask,
        provider: executionProvider,
        queueStatus,
      }),
      execution_brief: buildApprovalExecutionBrief({
        approvedAt: transitionAt,
        project,
        queueTask,
        provider: executionProvider,
        queueStatus,
        taskIntent: normalizedTaskIntent,
        taskShape,
      }),
      queue_handoff: {
        at: transitionAt,
        project,
        task: queueTask,
        status: queueStatus,
        provider: executionProvider,
        ...(queueTaskIntent ? { task_intent: queueTaskIntent } : {}),
      },
      ...(normalizedTaskIntent ? { task_intent: normalizedTaskIntent } : {}),
      task_shape: taskShape,
    };
    // Track cumulative attempts across re-approval cycles to prevent infinite retry churn.
    // The execution block is about to be deleted for the new approval, but we preserve
    // the total attempt count so the queue worker can enforce a global retry budget.
    const priorAttempts = Math.max(
      parseInt(existing.cumulative_attempts || 0, 10),
      parseInt((existing.execution || {}).attempt || 0, 10),
      parseInt(preparedTask.cumulative_attempts || 0, 10),
    );
    if (priorAttempts > 0) {
      nextTask.cumulative_attempts = priorAttempts;
    }
    delete nextTask.execution;
    delete nextTask.started_at;
    delete nextTask.last_started_at;
    delete nextTask.last_retry_at;
    delete nextTask.failed_at;
    delete nextTask.rejected_at;
    delete nextTask.completed_at;
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, action === "retry" ? "retry" : "approve", fromStatus, "approved", {
        at: transitionAt,
        note:
          action === "retry"
            ? duplicateQueue
              ? "Failed task was retried and recognized as already queued or running."
              : "Failed task was retried and requeued."
            : duplicateQueue
              ? "Task was already queued or running."
              : "Task was enqueued after approval.",
        project,
        queueTask,
      }),
    );
    payload.tasks[index] = nextTask;
    await writeTaskRegistryPayloadAt(located.filePath, payload);
    await refreshPersistedMetrics(await readTaskRegistry());
    await appendLog(
      action === "retry"
        ? `Retried failed task ${taskId} for ${project}: ${queueTask}`
        : `Approved task ${taskId} for ${project}: ${queueTask}`,
    );
    return {
      ok: true,
      status: 200,
      task: nextTask,
      message:
        action === "retry"
          ? duplicateQueue
            ? "Failed task retried and recognized as already queued."
            : "Failed task retried and queued."
          : duplicateQueue
            ? "Task approved and recognized as already queued."
            : "Task approved and queued.",
    };
  }

  if (action === "reject") {
    if (fromStatus !== "pending_approval") {
      return { ok: false, status: 409, error: "Only pending approval tasks can be rejected." };
    }

    const transitionAt = nowUtc();
    const nextTask = {
      ...existing,
      status: "rejected",
      rejected_at: transitionAt,
      updated_at: transitionAt,
    };
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "reject", fromStatus, "rejected", {
        at: transitionAt,
        note: "Task was rejected from the dashboard.",
      }),
    );
    payload.tasks[index] = nextTask;
    await writeTaskRegistryPayloadAt(located.filePath, payload);
    await refreshPersistedMetrics(await readTaskRegistry());
    await appendLog(`Rejected task ${taskId}: ${nextTask.title}`);
    return {
      ok: true,
      status: 200,
      task: nextTask,
      message: "Task rejected.",
    };
  }

  return { ok: false, status: 400, error: "Unsupported task action." };
}

async function applyAutoApproveToTaskIds(taskIds) {
  const approved = [];
  const errors = [];
  const uniqueTaskRefs = [];
  const seen = new Set();
  for (const entry of Array.isArray(taskIds) ? taskIds : []) {
    const taskId = normalizeTask(typeof entry === "string" ? entry : entry?.id || "");
    const project = sanitizeProjectName(typeof entry === "object" && entry !== null ? entry.project || "" : "");
    if (!taskId) {
      continue;
    }
    const identityKey = `${project}::${taskId}`;
    if (seen.has(identityKey)) {
      continue;
    }
    seen.add(identityKey);
    uniqueTaskRefs.push({ id: taskId, project });
  }

  for (const taskRef of uniqueTaskRefs) {
    const existing = (await readTaskRegistry()).find((task) => taskIdentityMatches(task, taskRef.id, taskRef.project));
    if (taskRequiresHumanApproval(existing)) {
      errors.push({
        id: taskRef.id,
        project: taskRef.project,
        error: "Strategy-seeded tasks require manual approval before queue handoff.",
      });
      continue;
    }
    const result = await transitionTaskRegistryItem(taskRef.id, "approve", taskRef.project);
    if (result.ok) {
      approved.push(taskRef);
    } else {
      errors.push({
        id: taskRef.id,
        project: taskRef.project,
        error: result.error || "Approval failed.",
      });
    }
  }

  const tasks = await readTaskRegistry();
  const matchedTasks = tasks.filter((task) =>
    uniqueTaskRefs.some((taskRef) => taskIdentityMatches(task, taskRef.id, taskRef.project)),
  );
  const tasksById = {};
  const duplicateIds = new Set();
  for (const task of matchedTasks) {
    const taskId = String(task?.id || "").trim();
    if (!taskId) {
      continue;
    }
    if (Object.prototype.hasOwnProperty.call(tasksById, taskId)) {
      duplicateIds.add(taskId);
      continue;
    }
    tasksById[taskId] = task;
  }
  for (const taskId of duplicateIds) {
    delete tasksById[taskId];
  }
  const tasksByIdentity = Object.fromEntries(
    matchedTasks.map((task) => [taskIdentityKey(task.id, normalizeTaskProject(task)), task]),
  );

  return {
    mode: "auto",
    attempted: uniqueTaskRefs.length,
    approved,
    errors,
    tasksById,
    tasksByIdentity,
  };
}

async function readMetrics(options = {}) {
  const summarySnapshot = options.snapshot && typeof options.snapshot === "object" ? options.snapshot : null;
  const providedSettings = options.settings && typeof options.settings === "object" ? options.settings : null;
  const providedExternalSignals =
    options.externalSignals && typeof options.externalSignals === "object" ? options.externalSignals : null;
  const providedSelfImproveRun =
    options.selfImproveRun && typeof options.selfImproveRun === "object" ? options.selfImproveRun : null;
  const providedMetricsUpdatedAt = firstNonEmptyString(options.metricsUpdatedAt);
  const providedSelfImproveRunUpdatedAt = firstNonEmptyString(options.selfImproveRunUpdatedAt);
  const providedAuthHealth = options.authHealth && typeof options.authHealth === "object" ? options.authHealth : null;
  const providedRuntimeDashboardStatus =
    options.runtimeDashboardStatus && typeof options.runtimeDashboardStatus === "object"
      ? options.runtimeDashboardStatus
      : null;
  const [
    { taskLog, queueTasks, status, tasks: plannedTasks, taskLogRecords },
    settings,
    externalSignals,
    selfImproveRun,
    metricsUpdatedAt,
    selfImproveRunUpdatedAt,
  ] = await Promise.all([
    summarySnapshot ? Promise.resolve(summarySnapshot) : readTaskRegistrySummarySnapshot(),
    providedSettings ? Promise.resolve(providedSettings) : readDashboardSettings(),
    providedExternalSignals ? Promise.resolve(providedExternalSignals) : readJsonFile(PATHS.externalSignals, {}),
    providedSelfImproveRun ? Promise.resolve(providedSelfImproveRun) : readJsonFile(PATHS.selfImproveRun, {}),
    providedMetricsUpdatedAt ? Promise.resolve(providedMetricsUpdatedAt) : readFileModifiedAt(PATHS.metrics),
    providedSelfImproveRunUpdatedAt ? Promise.resolve(providedSelfImproveRunUpdatedAt) : readFileModifiedAt(PATHS.selfImproveRun),
  ]);
  const records = Array.isArray(taskLogRecords) ? taskLogRecords : parseJsonLines(taskLog);
  const [authHealth, runtimeDashboardStatus] = await Promise.all([
    providedAuthHealth ? Promise.resolve(providedAuthHealth) : readCodexAuthHealth(status),
    providedRuntimeDashboardStatus
      ? Promise.resolve(providedRuntimeDashboardStatus)
      : readRuntimeDashboardStatus(status),
  ]);
  const taskRegistryPressureSignal = buildTaskRegistryPressureSignal(plannedTasks, {
    task_registry_payload_bytes: summarySnapshot?.taskRegistryPayloadBytes,
    task_registry_pressure_sources: summarySnapshot?.taskRegistryPressureSources,
  });
  const taskSummary = applyRuntimeReloadGateToTaskSummary(
    summarizeTaskRegistry(plannedTasks, authHealth, {
      taskRegistryPressureSignal,
    }),
    runtimeDashboardStatus,
  );
  const firstPassSignal = buildFirstPassSuccessSignal("", plannedTasks, records);
  const loopEffortSignal = buildLoopEffortSignal("", plannedTasks);
  const loopEffortBoundedExperiment = buildLoopEffortBoundedExperiment(loopEffortSignal);
  const boardHealthSignals = buildPersistedBoardHealthSignals("", plannedTasks, records);
  const externalResearch = buildExternalResearchSummary(externalSignals);
  const selfImprove = buildSelfImproveSummary(selfImproveRun, {
    metricsUpdatedAt,
    artifactUpdatedAt: selfImproveRunUpdatedAt,
  });
  const total = records.length;
  const success = records.filter((record) => record.result === "SUCCESS").length;
  const failure = records.filter((record) => record.result === "FAILURE").length;
  const pendingApproval = taskSummary.byStatus.pending_approval;
  const approved = taskSummary.byStatus.approved;
  const successRate =
    total > 0 ? Number(((success / total) * 100).toFixed(1)) : 0;
  const averageDurationSeconds =
    total > 0
      ? Number(
          (
            records.reduce((sum, record) => sum + Number(record.duration_seconds || 0), 0) /
            Math.max(total, 1)
          ).toFixed(2),
        )
      : 0;
  const averageScore =
    total > 0
      ? Number(
          (
            records.reduce((sum, record) => sum + Number(record.score || 0), 0) / Math.max(total, 1)
          ).toFixed(2),
        )
      : 0;
  const lastRun = records.at(-1) || null;
  const lastFailed = [...records].reverse().find((record) => record.result === "FAILURE") || null;
  const timeoutFailure = countUnresolvedTimeoutRecords(records, plannedTasks);
  const liveWorkPanel = buildLiveWorkPanel(plannedTasks);
  return {
    total,
    success,
    failure,
    timeoutFailure,
    timeoutFailureRate: total > 0 ? Number((timeoutFailure / total).toFixed(2)) : 0,
    successRate,
    queued: Array.isArray(queueTasks) ? queueTasks.length : 0,
    pendingApproval,
    approved,
    saturatedFailedTasks: taskSummary.strategy.saturated_failed_tasks,
    strategySaturationDetected: taskSummary.strategy.strategy_saturation_detected,
    taskRegistryTotal: taskSummary.total,
    taskRegistryPayloadBytes: taskRegistryPressureSignal.task_registry_payload_bytes,
    taskRegistryPressureDetected: taskRegistryPressureSignal.task_registry_pressure_detected,
    taskRegistryPressurePrimarySurface: taskRegistryPressureSignal.task_registry_pressure_primary_surface,
    task_registry_payload_bytes: taskRegistryPressureSignal.task_registry_payload_bytes,
    task_registry_pressure_detected: taskRegistryPressureSignal.task_registry_pressure_detected,
    task_registry_pressure_primary_surface: taskRegistryPressureSignal.task_registry_pressure_primary_surface,
    averageDurationSeconds,
    averageScore,
    currentState: status.state || "idle",
    lastRun,
    lastFailed,
    authHealth,
    settings,
    topPendingTask: taskSummary.topPendingTask,
    approvalRecommendation: taskSummary.approvalRecommendation,
    nextAction: taskSummary.nextAction,
    live_work_panel: liveWorkPanel,
    lowFirstPassSuccess: firstPassSignal,
    retry_churn_detected: boardHealthSignals.retry_churn_detected,
    queue_starvation_detected: boardHealthSignals.queue_starvation_detected,
    pending_approval_blocked_detected: boardHealthSignals.pending_approval_blocked_detected,
    active_retry_churn_count: boardHealthSignals.active_retry_churn_count,
    recent_retry_churn_count: boardHealthSignals.recent_retry_churn_count,
    actionable_backlog_count: boardHealthSignals.actionable_backlog_count,
    active_progress_count: boardHealthSignals.active_progress_count,
    loop_effort_detected: loopEffortSignal.detected,
    loop_effort_task_count: loopEffortSignal.loop_effort_task_count,
    loop_effort_extra_step_attempts: loopEffortSignal.loop_effort_extra_step_attempts,
    loop_effort_bounded_experiment_detected: loopEffortBoundedExperiment.detected,
    loop_effort_bounded_experiment_metric_name: loopEffortBoundedExperiment.metric_name,
    loop_effort_bounded_experiment_extra_step_threshold: loopEffortBoundedExperiment.extra_step_threshold,
    loop_effort_bounded_experiment_message: loopEffortBoundedExperiment.message,
    retryChurnDetected: boardHealthSignals.retry_churn_detected,
    queueStarvationDetected: boardHealthSignals.queue_starvation_detected,
    pendingApprovalBlockedDetected: boardHealthSignals.pending_approval_blocked_detected,
    retryChurn: {
      detected: boardHealthSignals.retry_churn_detected,
      active_retry_churn_count: boardHealthSignals.active_retry_churn_count,
      recent_retry_churn_count: boardHealthSignals.recent_retry_churn_count,
    },
    loopEffort: {
      detected: loopEffortSignal.detected,
      task_count: loopEffortSignal.loop_effort_task_count,
      extra_step_attempts: loopEffortSignal.loop_effort_extra_step_attempts,
    },
    loopEffortBoundedExperiment: {
      detected: loopEffortBoundedExperiment.detected,
      metric_name: loopEffortBoundedExperiment.metric_name,
      extra_step_threshold: loopEffortBoundedExperiment.extra_step_threshold,
      message: loopEffortBoundedExperiment.message,
    },
    queueStarvation: {
      detected: boardHealthSignals.queue_starvation_detected,
      actionable_backlog_count: boardHealthSignals.actionable_backlog_count,
      active_progress_count: boardHealthSignals.active_progress_count,
    },
    taskRegistryPressure: {
      detected: taskRegistryPressureSignal.task_registry_pressure_detected,
      payload_bytes: taskRegistryPressureSignal.task_registry_payload_bytes,
      primary_surface: taskRegistryPressureSignal.task_registry_pressure_primary_surface,
      primary_source: taskRegistryPressureSignal.task_registry_pressure_primary_source,
      sources: taskRegistryPressureSignal.task_registry_pressure_sources,
    },
    pendingApprovalBlocker: {
      detected: boardHealthSignals.pending_approval_blocked_detected,
      pending_approval_tasks: pendingApproval,
      approved_tasks: approved,
      active_progress_count: boardHealthSignals.active_progress_count,
    },
    externalResearch,
    selfImprove,
  };
}

async function readDashboardSnapshot() {
  const artifacts = await readDashboardArtifacts({ includeProjects: true, includeStrategyLatest: true });
  const {
    projects,
    summarySnapshot: taskRegistrySnapshot,
    settings,
    alerts,
    incidents,
    externalSignals,
    strategyLatestPayload,
    strategyLatestStat,
    status,
    authHealth,
    runtimeDashboardStatus,
  } = artifacts;
  const addresses = localAddresses();
  const [metrics, strategy] = await Promise.all([
    readMetrics({
      snapshot: taskRegistrySnapshot,
      settings,
      externalSignals,
      selfImproveRun: artifacts.selfImproveRun,
      authHealth,
      runtimeDashboardStatus,
    }),
    readStrategyHealth({
      ...taskRegistrySnapshot,
      strategyLatestPayload,
      strategyLatestStat,
    }),
  ]);
  const taskRegistryPressureSignal = buildTaskRegistryPressureSignal(taskRegistrySnapshot.tasks, {
    task_registry_payload_bytes: taskRegistrySnapshot.taskRegistryPayloadBytes,
    task_registry_pressure_sources: taskRegistrySnapshot.taskRegistryPressureSources,
  });
  const taskRegistrySummary = applyRuntimeReloadGateToTaskSummary(
    summarizeTaskRegistry(taskRegistrySnapshot.tasks, authHealth, {
      taskRegistryPressureSignal,
    }),
    runtimeDashboardStatus,
  );
  const dashboardTasks = taskRegistrySnapshot.tasks.map((task) => compactDashboardTask(task));

  return {
    projects,
    status: {
      ...status,
      ...runtimeDashboardStatus,
      authHealth,
      strategy,
      settings,
      port: PORT,
      addresses,
      protocol: PROTOCOL,
      taskRegistryPressure: taskRegistrySummary.taskRegistryPressure,
      task_registry_payload_bytes: taskRegistryPressureSignal.task_registry_payload_bytes,
      task_registry_pressure_detected: taskRegistryPressureSignal.task_registry_pressure_detected,
      task_registry_pressure_primary_surface: taskRegistryPressureSignal.task_registry_pressure_primary_surface,
      task_registry_pressure_primary_source: taskRegistryPressureSignal.task_registry_pressure_primary_source,
      task_registry_pressure_sources: taskRegistryPressureSignal.task_registry_pressure_sources,
    },
    metrics,
    alerts,
    incidents,
    queue: {
      tasks: Array.isArray(taskRegistrySnapshot.queueTasks) ? taskRegistrySnapshot.queueTasks : [],
    },
    taskRegistry: {
      tasks: dashboardTasks,
      summary: taskRegistrySummary,
      authHealth,
      ...runtimeDashboardStatus,
    },
  };
}

async function readDashboardArtifacts(options = {}) {
  const includeProjects = options.includeProjects === true;
  const includeStrategyLatest = options.includeStrategyLatest === true;
  const [summarySnapshot, settings, alerts, incidents, externalSignals, selfImproveRun, projects, strategyLatestPayload, strategyLatestStat] = await Promise.all([
    readTaskRegistrySummarySnapshot(),
    readDashboardSettings(),
    readAlerts(),
    readRecentIncidents(),
    readJsonFile(PATHS.externalSignals, {}),
    readJsonFile(PATHS.selfImproveRun, {}),
    includeProjects ? listProjects() : Promise.resolve([]),
    includeStrategyLatest ? readJsonFile(PATHS.strategyLatest, {}) : Promise.resolve(null),
    includeStrategyLatest ? fsp.stat(PATHS.strategyLatest).catch(() => null) : Promise.resolve(null),
  ]);
  const status = summarySnapshot.status || {};
  const [authHealth, runtimeDashboardStatus] = await Promise.all([
    readCodexAuthHealth(status),
    readRuntimeDashboardStatus(status),
  ]);

  return {
    summarySnapshot,
    settings,
    alerts,
    incidents,
    externalSignals,
    selfImproveRun,
    projects,
    strategyLatestPayload,
    strategyLatestStat,
    status,
    authHealth,
    runtimeDashboardStatus,
  };
}

async function findLastFailedTask() {
  const taskLog = await readText(PATHS.taskLog);
  const records = parseJsonLines(taskLog);
  for (let index = records.length - 1; index >= 0; index -= 1) {
    const record = records[index];
    if (record.result === "FAILURE" && record.project && record.task) {
      return { project: record.project, task: record.task };
    }
  }
  return null;
}

async function appendLog(message, level = "INFO") {
  await fsp.appendFile(PATHS.logs, formatLogLine("dashboard", level, message), "utf8");
}

function sendJson(response, statusCode, payload) {
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(JSON.stringify(payload));
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 1024 * 1024) {
        reject(new Error("Payload too large"));
      }
    });
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });
}

function localAddresses() {
  const networkInterfaces = os.networkInterfaces();
  const addresses = [];
  for (const entries of Object.values(networkInterfaces)) {
    for (const entry of entries || []) {
      if (entry.family === "IPv4" && !entry.internal) {
        addresses.push(entry.address);
      }
    }
  }
  return [...new Set(addresses)].sort();
}

async function enqueueTask(projectInput, taskInput) {
  const project = sanitizeProjectName(projectInput);
  const task = String(taskInput || "").trim();
  if (!project) {
    await appendLog("Rejected task submission with missing project.", "WARN");
    return { ok: false, status: 400, error: "Project is required." };
  }
  if (!task) {
    await appendLog(`Rejected empty task submission for ${project}.`, "WARN");
    return { ok: false, status: 400, error: "Task is required." };
  }

  const queued = await queueTaskCount();
  if (queued >= QUEUE_LIMIT) {
    await appendLog(`Rejected task for ${project} because queue limit ${QUEUE_LIMIT} was reached.`, "WARN");
    return { ok: false, status: 409, error: `Queue limit ${QUEUE_LIMIT} reached.` };
  }

  if (await taskExistsAnywhere(project, task)) {
    await appendLog(`Rejected duplicate task for ${project}: ${task}`, "WARN");
    return { ok: false, status: 409, error: "Duplicate task rejected." };
  }

  const projectDir = path.join(PATHS.projects, project);
  const queueFile = path.join(PATHS.queues, `${project}.txt`);
  const status = await readStatus();
  await fsp.mkdir(projectDir, { recursive: true });
  await fsp.appendFile(queueFile, `${task}\n`, "utf8");
  if (!["running", "retrying"].includes(String(status.state || "").toLowerCase())) {
    await writeStatus({
      ...status,
      state: "queued",
      project,
      task,
      note: `queued_at=${nowUtc()}`,
      updated_at: nowUtc(),
    });
  }
  await appendLog(`Queued task for ${project}: ${task}`);
  return { ok: true, status: 200, project, task };
}

async function handleApi(request, response, url) {
  if (request.method === "GET" && url.pathname === "/api/projects") {
    const projects = await listProjects();
    sendJson(response, 200, { projects });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/project-summaries") {
    const projects = await buildProjectSummaries();
    sendJson(response, 200, { projects });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/project-sources") {
    const project = sanitizeProjectName(url.searchParams.get("project") || "") || "codex-agent-system";
    const payload = await readProjectSources(project);
    sendJson(response, 200, payload);
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/project-cra-compliance") {
    const project = sanitizeProjectName(url.searchParams.get("project") || "") || "codex-agent-system";
    try {
      const payload = await readProjectCraCompliance(project);
      sendJson(response, 200, payload);
    } catch (error) {
      sendJson(response, 500, {
        error: error.message || "Failed to read CRA compliance document.",
        project,
        cra_compliance: defaultCraCompliancePayload(project),
      });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/project-sources") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const project = sanitizeProjectName(body.project || "") || "codex-agent-system";
      const current = await readProjectSources(project);
      const nextPayload =
        Array.isArray(body.sources) || Array.isArray(body.entries)
          ? {
              ...current,
              ...body,
              sources: Array.isArray(body.sources) ? body.sources : body.entries,
            }
          : {
              ...current,
              sources: [...current.sources, body.source || body],
            };
      const saved = await writeProjectSources(project, nextPayload);
      await appendLog(`Updated project sources for ${project}: ${saved.sources.length} item(s).`);
      sendJson(response, 200, { ok: true, project, sources: saved.sources, updated_at: saved.updated_at });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/status") {
    const [artifacts, addresses] = await Promise.all([
      readDashboardArtifacts({ includeStrategyLatest: true }),
      Promise.resolve(localAddresses()),
    ]);
    const { summarySnapshot, settings, status, authHealth, runtimeDashboardStatus, strategyLatestPayload, strategyLatestStat } =
      artifacts;
    const taskRegistryPressureSignal = buildTaskRegistryPressureSignal(summarySnapshot.tasks, {
      task_registry_payload_bytes: summarySnapshot.taskRegistryPayloadBytes,
      task_registry_pressure_sources: summarySnapshot.taskRegistryPressureSources,
    });
    const taskSummary = applyRuntimeReloadGateToTaskSummary(
      summarizeTaskRegistry(summarySnapshot.tasks, authHealth, {
        taskRegistryPressureSignal,
      }),
      runtimeDashboardStatus,
    );
    const strategy = await readStrategyHealth({
      ...summarySnapshot,
      strategyLatestPayload,
      strategyLatestStat,
    });
    sendJson(response, 200, {
      ...status,
      ...runtimeDashboardStatus,
      authHealth,
      strategy,
      settings,
      port: PORT,
      addresses,
      protocol: PROTOCOL,
      taskRegistryPressure: taskSummary.taskRegistryPressure,
      task_registry_payload_bytes: taskRegistryPressureSignal.task_registry_payload_bytes,
      task_registry_pressure_detected: taskRegistryPressureSignal.task_registry_pressure_detected,
      task_registry_pressure_primary_surface: taskRegistryPressureSignal.task_registry_pressure_primary_surface,
      task_registry_pressure_primary_source: taskRegistryPressureSignal.task_registry_pressure_primary_source,
      task_registry_pressure_sources: taskRegistryPressureSignal.task_registry_pressure_sources,
    });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/settings") {
    const settings = await readDashboardSettings();
    sendJson(response, 200, settings);
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/settings") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const settings = await writeDashboardSettings({
        approval_mode: body.approval_mode || body.approvalMode || body.mode,
      });
      await appendLog(`Updated dashboard settings: approval_mode=${settings.approval_mode}`);
      sendJson(response, 200, { ok: true, settings, message: `Approval mode set to ${settings.approval_mode}.` });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/logs") {
    const limit = Math.max(20, Math.min(Number(url.searchParams.get("limit") || 200), 500));
    const logs = await readText(PATHS.logs);
    const lines = logs.split(/\r?\n/).filter(isStructuredLogLine).slice(-limit);
    sendJson(response, 200, { logs: lines.join("\n") });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/rules") {
    const rules = await readText(PATHS.rules);
    sendJson(response, 200, { rules });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/dashboard") {
    const snapshot = await readDashboardSnapshot();
    sendJson(response, 200, snapshot);
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/metrics") {
    const artifacts = await readDashboardArtifacts();
    const metrics = await readMetrics({
      snapshot: artifacts.summarySnapshot,
      settings: artifacts.settings,
      externalSignals: artifacts.externalSignals,
      selfImproveRun: artifacts.selfImproveRun,
      authHealth: artifacts.authHealth,
      runtimeDashboardStatus: artifacts.runtimeDashboardStatus,
    });
    sendJson(response, 200, metrics);
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/active-tasks") {
    const tasks = await readTaskRegistry();
    const active = buildActiveWorkItems(tasks);
    sendJson(response, 200, { active });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/runtime-sessions") {
    const sessions = readRuntimeSessions();
    sendJson(response, 200, { sessions });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/task-registry") {
    const artifacts = await readDashboardArtifacts();
    const { summarySnapshot, authHealth, runtimeDashboardStatus } = artifacts;
    const { tasks } = summarySnapshot;
    const taskRegistryPressureSignal = buildTaskRegistryPressureSignal(tasks, {
      task_registry_payload_bytes: summarySnapshot.taskRegistryPayloadBytes,
      task_registry_pressure_sources: summarySnapshot.taskRegistryPressureSources,
    });
    sendJson(response, 200, {
      tasks,
      summary: applyRuntimeReloadGateToTaskSummary(
        summarizeTaskRegistry(tasks, authHealth, {
          taskRegistryPressureSignal,
        }),
        runtimeDashboardStatus,
      ),
      authHealth,
      ...runtimeDashboardStatus,
    });
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task-registry") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const result = await runTaskRegistryMutation(async () =>
        createTaskRegistryItem({
          project: body.project || body.newProject,
          task: body.task,
          title: body.title,
          category: body.category,
          confidence: body.confidence,
          effort: body.effort,
          impact: body.impact,
          reason: body.reason,
          contextHint: body.contextHint || body.context_hint,
          successCriteria: body.successCriteria || body.success_criteria,
          constraints: body.constraints,
          affectedFiles: body.affectedFiles || body.affected_files,
          taskIntentSource: body.taskIntentSource || body.task_intent_source,
          executionProvider: body.executionProvider || body.execution_provider,
          dependsOn: body.dependsOn || body.depends_on,
          sourceTaskId: body.sourceTaskId || body.source_task_id,
          rootSourceTaskId: body.rootSourceTaskId || body.root_source_task_id,
          relatedSourceTaskIds: body.relatedSourceTaskIds || body.related_source_task_ids,
          originalFailedRootId: body.originalFailedRootId || body.original_failed_root_id,
          strategyTemplate: body.strategyTemplate || body.strategy_template,
          strategyDepth: body.strategyDepth || body.strategy_depth,
          failureContext: body.failureContext || body.failure_context,
          autoApprove:
            typeof body.autoApprove === "boolean"
              ? body.autoApprove
              : (await readDashboardSettings()).approval_mode === "auto",
        }),
      );
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task-registry/intake") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const result = await runTaskRegistryMutation(async () =>
        createTaskRegistryItemsFromPrompt({
          project: body.project || body.newProject,
          prompt: body.prompt || body.taskPrompt || body.task_prompt,
          reason: body.reason,
          executionProvider: body.executionProvider || body.execution_provider,
          autoApprove:
            typeof body.autoApprove === "boolean"
              ? body.autoApprove
              : (await readDashboardSettings()).approval_mode === "auto",
        }),
      );
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task-registry/action") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const taskId = String(body.id || "").trim();
      const taskProject = sanitizeProjectName(body.project || "");
      const action = String(body.action || "").trim().toLowerCase();
      if (!taskId || !action) {
        sendJson(response, 400, { error: "Task id and action are required." });
        return;
      }
      const result = await runTaskRegistryMutation(() => transitionTaskRegistryItem(taskId, action, taskProject));
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/runtime-sessions/focus") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const session = await focusRuntimeSession(body.project || "", body.task_id || body.taskId || "");
      sendJson(response, 200, { ok: true, session });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task-registry/update") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const taskId = String(body.id || "").trim();
      if (!taskId) {
        sendJson(response, 400, { error: "Task id is required." });
        return;
      }
      const result = await runTaskRegistryMutation(() =>
        updateTaskRegistryItem(taskId, {
          project: body.project,
          title: body.title,
          dependsOn: body.dependsOn || body.depends_on,
        }),
      );
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/queue") {
    const tasks = await readQueueTasks();
    sendJson(response, 200, { tasks });
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const result = await runTaskRegistryMutation(async () =>
        createTaskRegistryItem({
          project: body.project || body.newProject,
          task: body.task,
          title: body.title,
          category: body.category,
          confidence: body.confidence,
          effort: body.effort,
          impact: body.impact,
          contextHint: body.contextHint || body.context_hint,
          successCriteria: body.successCriteria || body.success_criteria,
          constraints: body.constraints,
          affectedFiles: body.affectedFiles || body.affected_files,
          dependsOn: body.dependsOn || body.depends_on,
          taskIntentSource: body.taskIntentSource || body.task_intent_source,
          executionProvider: body.executionProvider || body.execution_provider,
          sourceTaskId: body.sourceTaskId || body.source_task_id,
          rootSourceTaskId: body.rootSourceTaskId || body.root_source_task_id,
          relatedSourceTaskIds: body.relatedSourceTaskIds || body.related_source_task_ids,
          originalFailedRootId: body.originalFailedRootId || body.original_failed_root_id,
          strategyTemplate: body.strategyTemplate || body.strategy_template,
          strategyDepth: body.strategyDepth || body.strategy_depth,
          failureContext: body.failureContext || body.failure_context,
          reason:
            body.reason ||
            "Legacy direct queue submissions are routed into pending approval so work cannot bypass human review.",
          historyNote:
            "Legacy direct queue request was captured in the approval backlog instead of entering the live queue.",
          successMessage: "Direct queue is disabled. Task added to backlog for approval.",
          successStatus: 202,
          autoApprove:
            typeof body.autoApprove === "boolean"
              ? body.autoApprove
              : (await readDashboardSettings()).approval_mode === "auto",
        }),
      );
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/retry-last-failed") {
    const candidate = await findLastFailedTask();
    if (!candidate) {
      sendJson(response, 404, { error: "No failed task is available to retry." });
      return;
    }

    const result = await enqueueTask(candidate.project, candidate.task);
    sendJson(response, result.status, result.ok ? result : { error: result.error });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/health") {
    sendJson(response, 200, { ok: true });
    return;
  }

  // ──── TIME-SERIES TASK LOG HISTORY ────
  // Returns task log records with optional time range and filters for charts/visualizations.
  // Query params: from (ISO), to (ISO), project, provider, result, category, limit
  if (request.method === "GET" && url.pathname === "/api/history") {
    try {
      const taskLog = await readText(PATHS.taskLog);
      let records = parseJsonLines(taskLog);
      const fromParam = url.searchParams.get("from");
      const toParam = url.searchParams.get("to");
      const projectParam = url.searchParams.get("project");
      const providerParam = url.searchParams.get("provider");
      const resultParam = url.searchParams.get("result");
      const limitParam = Math.max(1, Math.min(Number(url.searchParams.get("limit") || 5000), 5000));

      if (fromParam) {
        const fromMs = new Date(fromParam).getTime();
        if (Number.isFinite(fromMs)) records = records.filter(r => new Date(r.timestamp).getTime() >= fromMs);
      }
      if (toParam) {
        const toMs = new Date(toParam).getTime();
        if (Number.isFinite(toMs)) records = records.filter(r => new Date(r.timestamp).getTime() <= toMs);
      }
      if (projectParam) records = records.filter(r => r.project === projectParam);
      if (providerParam) records = records.filter(r => r.provider === providerParam);
      if (resultParam) records = records.filter(r => r.result === resultParam.toUpperCase());

      records = records.slice(-limitParam);
      sendJson(response, 200, { records, total: records.length });
    } catch (error) {
      sendJson(response, 500, { error: error.message || "Failed to read history." });
    }
    return;
  }

  // ──── AGGREGATED TIME-SERIES FOR CHARTS ────
  // Returns bucketed time-series data for throughput, success rate, duration over time.
  // Query params: from (ISO), to (ISO), bucket (hour|day|week), project, provider
  if (request.method === "GET" && url.pathname === "/api/history/timeseries") {
    try {
      const taskLog = await readText(PATHS.taskLog);
      let records = parseJsonLines(taskLog);
      const fromParam = url.searchParams.get("from");
      const toParam = url.searchParams.get("to");
      const bucketParam = url.searchParams.get("bucket") || "hour";
      const projectParam = url.searchParams.get("project");
      const providerParam = url.searchParams.get("provider");

      if (fromParam) {
        const fromMs = new Date(fromParam).getTime();
        if (Number.isFinite(fromMs)) records = records.filter(r => new Date(r.timestamp).getTime() >= fromMs);
      }
      if (toParam) {
        const toMs = new Date(toParam).getTime();
        if (Number.isFinite(toMs)) records = records.filter(r => new Date(r.timestamp).getTime() <= toMs);
      }
      if (projectParam) records = records.filter(r => r.project === projectParam);
      if (providerParam) records = records.filter(r => r.provider === providerParam);

      // Bucket records by time interval
      function bucketKey(timestamp) {
        const d = new Date(timestamp);
        if (bucketParam === "week") {
          const dayOfWeek = d.getUTCDay();
          const diff = d.getUTCDate() - dayOfWeek;
          const weekStart = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), diff));
          return weekStart.toISOString().slice(0, 10);
        }
        if (bucketParam === "day") return d.toISOString().slice(0, 10);
        return d.toISOString().slice(0, 13) + ":00:00Z"; // hour
      }

      const buckets = new Map();
      for (const record of records) {
        const key = bucketKey(record.timestamp);
        if (!buckets.has(key)) {
          buckets.set(key, { timestamp: key, total: 0, success: 0, failure: 0, timeout: 0, totalDuration: 0, totalScore: 0, totalAttempts: 0, totalStepAttempts: 0 });
        }
        const b = buckets.get(key);
        b.total++;
        if (record.result === "SUCCESS") b.success++;
        if (record.result === "FAILURE") b.failure++;
        if (record.failure_kind === "timeout") b.timeout++;
        b.totalDuration += Number(record.duration_seconds || 0);
        b.totalScore += Number(record.score || 0);
        b.totalAttempts += Number(record.attempts || 0);
        b.totalStepAttempts += Number(record.total_step_attempts || 0);
      }

      const series = Array.from(buckets.values())
        .sort((a, b) => a.timestamp.localeCompare(b.timestamp))
        .map(b => ({
          timestamp: b.timestamp,
          total: b.total,
          success: b.success,
          failure: b.failure,
          timeout: b.timeout,
          successRate: b.total > 0 ? Number(((b.success / b.total) * 100).toFixed(1)) : 0,
          avgDuration: b.total > 0 ? Number((b.totalDuration / b.total).toFixed(1)) : 0,
          avgScore: b.total > 0 ? Number((b.totalScore / b.total).toFixed(1)) : 0,
          avgAttempts: b.total > 0 ? Number((b.totalAttempts / b.total).toFixed(1)) : 0,
          avgStepAttempts: b.total > 0 ? Number((b.totalStepAttempts / b.total).toFixed(1)) : 0,
        }));

      sendJson(response, 200, { series, bucket: bucketParam, totalRecords: records.length });
    } catch (error) {
      sendJson(response, 500, { error: error.message || "Failed to build timeseries." });
    }
    return;
  }

  // ──── PROVIDER STATS (already in file, expose via API) ────
  if (request.method === "GET" && url.pathname === "/api/provider-stats") {
    try {
      const stats = await readJsonFile(path.join(ROOT, "codex-learning", "provider-stats.json"), {});
      const routing = await readJsonFile(path.join(ROOT, "codex-learning", "provider-routing.json"), {});
      sendJson(response, 200, { stats, routing });
    } catch (error) {
      sendJson(response, 500, { error: error.message || "Failed to read provider stats." });
    }
    return;
  }

  // ──── TASK BREAKDOWN BY STATUS / CATEGORY / PROJECT ────
  if (request.method === "GET" && url.pathname === "/api/history/breakdown") {
    try {
      const taskLog = await readText(PATHS.taskLog);
      let records = parseJsonLines(taskLog);
      const fromParam = url.searchParams.get("from");
      const toParam = url.searchParams.get("to");
      const groupByParam = url.searchParams.get("groupBy") || "project";
      const projectParam = url.searchParams.get("project");
      const providerParam = url.searchParams.get("provider");

      if (fromParam) {
        const fromMs = new Date(fromParam).getTime();
        if (Number.isFinite(fromMs)) records = records.filter(r => new Date(r.timestamp).getTime() >= fromMs);
      }
      if (toParam) {
        const toMs = new Date(toParam).getTime();
        if (Number.isFinite(toMs)) records = records.filter(r => new Date(r.timestamp).getTime() <= toMs);
      }
      if (projectParam) records = records.filter(r => r.project === projectParam);
      if (providerParam) records = records.filter(r => r.provider === providerParam);

      const groups = new Map();
      for (const record of records) {
        let key;
        if (groupByParam === "provider") key = record.provider || "unknown";
        else if (groupByParam === "result") key = record.result || "unknown";
        else key = record.project || "unknown";

        if (!groups.has(key)) {
          groups.set(key, { label: key, total: 0, success: 0, failure: 0, timeout: 0, totalDuration: 0, totalScore: 0 });
        }
        const g = groups.get(key);
        g.total++;
        if (record.result === "SUCCESS") g.success++;
        if (record.result === "FAILURE") g.failure++;
        if (record.failure_kind === "timeout") g.timeout++;
        g.totalDuration += Number(record.duration_seconds || 0);
        g.totalScore += Number(record.score || 0);
      }

      const breakdown = Array.from(groups.values())
        .sort((a, b) => b.total - a.total)
        .map(g => ({
          label: g.label,
          total: g.total,
          success: g.success,
          failure: g.failure,
          timeout: g.timeout,
          successRate: g.total > 0 ? Number(((g.success / g.total) * 100).toFixed(1)) : 0,
          avgDuration: g.total > 0 ? Number((g.totalDuration / g.total).toFixed(1)) : 0,
          avgScore: g.total > 0 ? Number((g.totalScore / g.total).toFixed(1)) : 0,
        }));

      sendJson(response, 200, { breakdown, groupBy: groupByParam, totalRecords: records.length });
    } catch (error) {
      sendJson(response, 500, { error: error.message || "Failed to build breakdown." });
    }
    return;
  }

  sendJson(response, 404, { error: "Not found" });
}

ensureStructure();

const requestHandler = async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);
  if (url.pathname.startsWith("/api/")) {
    await handleApi(request, response, url);
    return;
  }

  const filePath =
    url.pathname === "/"
      ? path.join(PATHS.dashboard, "index.html")
      : path.resolve(PATHS.dashboard, `.${url.pathname}`);
  const dashboardRoot = `${PATHS.dashboard}${path.sep}`;
  if (
    filePath !== path.join(PATHS.dashboard, "index.html") &&
    !filePath.startsWith(dashboardRoot)
  ) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }

  let asset;
  try {
    const stats = await fsp.stat(filePath);
    if (!stats.isFile()) {
      throw new Error("Not a file");
    }
    asset = await fsp.readFile(filePath);
  } catch {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }

  response.writeHead(200, {
    "Content-Type": dashboardAssetContentType(filePath),
    "Cache-Control": "no-store",
  });
  response.end(asset);
};

const server = HTTPS_ENABLED
  ? https.createServer(readTlsCredentials(), requestHandler)
  : http.createServer(requestHandler);

server.listen(PORT, "0.0.0.0", () => {
  const addresses = localAddresses();
  const addressText = dashboardUrls(addresses).join(", ");
  fs.appendFileSync(
    PATHS.logs,
    formatLogLine("dashboard", "INFO", `Dashboard listening on ${addressText}`),
    "utf8",
  );
  console.log(`Dashboard listening on ${addressText}`);
});
