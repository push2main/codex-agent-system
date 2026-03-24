const http = require("http");
const https = require("https");
const fs = require("fs");
const fsp = fs.promises;
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
  strategyLatest: envPath("DASHBOARD_STRATEGY_LATEST_FILE", path.join(ROOT, "codex-logs", "strategy-latest.json")),
  metrics: envPath("DASHBOARD_METRICS_FILE", path.join(ROOT, "codex-learning", "metrics.json")),
  externalSignals: envPath("DASHBOARD_EXTERNAL_SIGNALS_FILE", path.join(ROOT, "codex-learning", "external-signals.json")),
  priority: envPath("DASHBOARD_PRIORITY_FILE", path.join(ROOT, "codex-memory", "priority.json")),
  rules: envPath("DASHBOARD_RULES_FILE", path.join(ROOT, "codex-learning", "rules.md")),
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
const RETRY_CHURN_ATTEMPT_THRESHOLD = 2;
const STRATEGY_SATURATED_FAILURE_THRESHOLD = 2;
const TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD = 512000;
const LOW_COMPLETION_EXECUTABLE_BUFFER_THRESHOLD = 2;
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
let taskRegistryMutationQueue = Promise.resolve();
let taskRegistryReadCache = null;
let taskRegistrySummarySnapshotCache = null;
const projectConfigReadCache = new Map();

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
  ensureFile(
    PATHS.metrics,
    '{\n  "total_tasks": 0,\n  "success_rate": 0,\n  "timeout_failure_records": 0,\n  "timeout_failure_rate": 0,\n  "analysis_runs": 0,\n  "pending_approval_tasks": 0,\n  "approved_tasks": 0,\n  "task_registry_total": 0,\n  "task_registry_payload_bytes": 0,\n  "task_registry_pressure_detected": false,\n  "task_registry_pressure_primary_surface": "",\n  "last_task_score": 0,\n  "manual_recovery_records": 0,\n  "low_first_pass_success_detected": false,\n  "retry_churn_detected": false,\n  "queue_starvation_detected": false,\n  "pending_approval_blocked_detected": false,\n  "low_completion_drain_detected": false,\n  "first_pass_success_rate": 0,\n  "first_pass_success_count": 0,\n  "multi_attempt_resolved_count": 0,\n  "loop_effort_detected": false,\n  "loop_effort_task_count": 0,\n  "loop_effort_extra_step_attempts": 0\n}\n',
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

  let verificationCommand = sanitizeTaskText(input?.verificationCommand || input?.verification_command || "");
  if (!verificationCommand && (/\b(dashboard|ui|iphone|ipad|tablet|mobile|playwright|screenshot)\b/.test(combinedLower) || category === "ui")) {
    verificationCommand = "bash scripts/run-playwright-docker.sh bash tests/dashboard-screenshot-verification.sh";
  }

  const matchedManualReviewKeywords = projectPolicy.manual_review_required_keywords.filter((keyword) =>
    combinedLower.includes(String(keyword || "").trim().toLowerCase()),
  );
  if (matchedManualReviewKeywords.length > 0) {
    riskFlags.push(...matchedManualReviewKeywords);
  }
  const manualReviewRequired = projectPolicy.auto_approve_allowed === false || matchedManualReviewKeywords.length > 0;

  return {
    approval_ready: reasons.length === 0,
    requires_split: reasons.length > 0,
    reasons,
    manual_review_required: manualReviewRequired,
    risk_profile: String(projectPolicy.risk_profile || "standard").trim() || "standard",
    risk_flags: [...new Set(riskFlags)],
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

  if (replacedTitle) {
    return sanitizeTaskText(`Replace ${excerptText(replacedTitle, 88)} with a different bounded experiment`).slice(0, 140);
  }
  return sanitizeTaskText(`Replace saturated ${replacedCategory} experiment with a different bounded task`).slice(0, 140);
}

function deriveSaturationRecoveryContextHint(task, saturationRecovery, replacedTask) {
  const replacedTitle = sentenceCase(sanitizeTaskText(saturationRecovery?.replaces_title || ""));
  const replacedTemplate = sanitizeTaskText(
    replacedTask?.strategy_template || replacedTask?.strategyTemplate || saturationRecovery?.replaces_strategy_template || "",
  );
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
  const saturationRecoveryVerificationCommand = deriveSaturationRecoveryVerificationCommand(
    taskForRepair,
    saturationRecovery,
    replacedTask,
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
      ? deriveSaturationRecoveryFollowupTitle(taskForRepair, saturationRecovery, replacedTask)
      : compactApprovalTitle(currentTitle, taskForRepair);
  const repairedContextHint =
    saturationRecovery && sanitizeTaskText(saturationRecovery.kind || "") === "replace_saturated_experiment"
      ? deriveSaturationRecoveryContextHint(taskForRepair, saturationRecovery, replacedTask)
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
  const failureContext = task && typeof task.failure_context === "object" ? task.failure_context : null;
  const taskIntent = task && typeof task.task_intent === "object" ? task.task_intent : null;
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
    last_board_updates: Array.isArray(boardUpdates) ? boardUpdates.length : boardTasks.length,
    board_tasks: boardTasks,
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
  const successfulCompletedRecords = projectRegistryTasks
    .filter((task) => isPersistedCompletedSuccessfulTask(task))
    .map((task) => deriveResolvedAttemptRecord(task))
    .filter(Boolean);
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

function buildLoopEffortSignal(registryTasks) {
  const loopEffortRecords = (Array.isArray(registryTasks) ? registryTasks : [])
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
  const firstPassSignal = buildFirstPassSuccessSignal(projectKey, projectRegistryTasks);
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
    low_first_pass_success_detected: firstPassSignal.detected,
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
  const metrics = buildProjectHealthMetrics(projectKey, registryTasks, taskLogRecords);
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
  const lowFirstPassSuccessDetected = metrics?.low_first_pass_success_detected === true;
  const activeRetryChurnCount = Math.max(0, safeInteger(metrics?.active_retry_churn_count, 0));
  const recentRetryChurnCount = Math.max(0, safeInteger(metrics?.recent_retry_churn_count, 0));
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
  if (lowFirstPassSuccessDetected && executableWorkDrained && executableStrategyWorkBelowBuffer) {
    const bufferDeficit = LOW_COMPLETION_EXECUTABLE_BUFFER_THRESHOLD - executableStrategyWorkCount;
    signals.push(
      `first-pass completion remains low after executable work drained and executable strategy work fell below buffer (approved_running_strategy=${executableStrategyWorkCount}, buffer=${LOW_COMPLETION_EXECUTABLE_BUFFER_THRESHOLD}, deficit=${bufferDeficit}, queued=${queuedCount}, active=${activeCount}, approved=${approvedCount})`,
    );
  }
  const lowCompletionDrainDetected =
    lowFirstPassSuccessDetected && executableWorkDrained && executableStrategyWorkBelowBuffer;
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
    low_first_pass_success_detected: lowFirstPassSuccessDetected,
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
    low_completion_followup_task_id: String(preservedLowCompletionFollowup?.id || "").trim(),
    actionable_count: actionableCount,
    failed_count: failedCount,
    retrying_count: metrics.retrying,
  };
}

function selectLowCompletionQueueDrainFailure(projectTasks) {
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
    return null;
  }

  return (
    recentFailedTasks
      .map((task) => {
        const targetExecutionContext =
          task && typeof task.execution_context === "object" ? task.execution_context : {};
        const targetFailureContext = task && typeof task.failure_context === "object" ? task.failure_context : {};
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
      })[0] || null
  );
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
    !guard.low_first_pass_success_detected ||
    !guard.executable_work_drained ||
    !guard.executable_strategy_work_below_buffer
  ) {
    return { seeded: false, reason: "guard_inactive", guard };
  }

  const projectTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter(
    (t) => normalizeTaskProject(t) === projectKey,
  );
  const targetFailure = selectLowCompletionQueueDrainFailure(projectTasks);
  const targetFailedTask = targetFailure?.task || null;
  const failedTaskContext = targetFailedTask
    ? {
        title: targetFailedTask.title || targetFailedTask.task || "",
        score: targetFailedTask.score,
        failure_context: targetFailedTask.failure_context || null,
      }
    : null;
  if (!targetFailure?.nextExecutablePlanStep) {
    return { seeded: false, reason: "no_bounded_failure", guard };
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

  const snapshot = {
    tasks: registryTasks,
    queueTasks,
    status,
    taskLog,
    taskLogRecords: parseJsonLines(taskLog),
    taskRegistryPayloadBytes,
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

async function buildProjectSummaries() {
  const [projects, registryTasks, queueTasks, status, taskLog, context, decisions, learnings, knowledge] = await Promise.all([
    listProjects(),
    readTaskRegistry(),
    readQueueTasks(),
    readStatus(),
    readText(PATHS.taskLog),
    readText(PROJECT_MEMORY_FILES.context),
    readText(PROJECT_MEMORY_FILES.decisions),
    readText(PROJECT_MEMORY_FILES.learnings),
    readJsonFile(PROJECT_MEMORY_FILES.knowledge, { rules: [] }),
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

  return [...knownProjects]
    .filter(Boolean)
    .sort()
    .map((project) => ({
      project,
      health_metrics: buildProjectHealthMetrics(project, registryTasks, taskLogRecords),
      queue: compactQueueState(project, queueTasks, registryTasks, status),
      memory_summary: buildProjectMemorySummary(project, registryTasks, taskLogRecords, memoryFiles),
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
    }));
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
      const taskProject = sanitizeProjectName(task.project || "codex-agent-system") || "codex-agent-system";
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
            project: sanitizeProjectName(task.queue_handoff.project || taskProject) || "codex-agent-system",
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
  const saturationCounts = buildStrategyFailureSaturationCounts(normalizedTasks);
  return normalizedTasks.map((task, index) => {
    const dependencyState = buildTaskDependencyState(task, tasksById);
    const saturationKey = strategySaturationKey(task);
    const failedEquivalentCount = saturationKey ? saturationCounts.get(saturationKey) || 0 : 0;
    const saturated =
      String(task.status || "").trim().toLowerCase() === "failed" &&
      failedEquivalentCount >= STRATEGY_SATURATED_FAILURE_THRESHOLD;
    return {
      ...task,
      active_work: buildActiveWorkSummary(task),
      dependency_state: dependencyState,
      depends_on: dependencyState.depends_on,
      rank: index + 1,
      strategy_state: {
        source: strategyTaskSource(task),
        is_saturable: isSaturableStrategyTask(task),
        failed_equivalent_count: failedEquivalentCount,
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
    current_work_label: progress.current_work_label,
    progress_label: progress.label,
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
      tasks.push(...payload.tasks);
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

function buildTaskRegistryPressureSignal(tasks, options = {}) {
  const registryTasks = Array.isArray(tasks) ? tasks.filter((task) => task && typeof task === "object") : [];
  const overridePayloadBytes = safeInteger(options?.task_registry_payload_bytes, -1);
  const payloadBytes =
    overridePayloadBytes >= 0
      ? overridePayloadBytes
      : Buffer.byteLength(JSON.stringify(canonicalizeJsonValue({ tasks: registryTasks })), "utf8");
  const detected = payloadBytes >= TASK_REGISTRY_PRESSURE_BYTES_THRESHOLD;
  return {
    task_registry_payload_bytes: payloadBytes,
    task_registry_pressure_detected: detected,
    // The dashboard remains the highest-frequency registry reader under the current fixed poll topology.
    task_registry_pressure_primary_surface: detected ? "dashboard_read_path" : "",
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

function buildExternalResearchSummary(payload = {}) {
  const snapshot = payload && typeof payload === "object" ? payload : {};
  const signals = Array.isArray(snapshot.signals)
    ? snapshot.signals.filter((signal) => signal && typeof signal === "object")
    : [];
  const errors = Array.isArray(snapshot.errors) ? snapshot.errors.filter(Boolean) : [];
  const latestSignal =
    signals
      .slice()
      .sort((left, right) =>
        firstNonEmptyString(right.published_at, right.fetched_at).localeCompare(
          firstNonEmptyString(left.published_at, left.fetched_at),
        ),
      )[0] || null;
  const freshSignals = signals.filter((signal) => signal.fresh === true).length;
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
          fresh: latestSignal.fresh === true,
        }
      : null,
  };
}

function buildPersistedMetrics(tasks, records, externalSignals = null, options = {}) {
  const registryTasks = Array.isArray(tasks) ? tasks.filter((task) => task && typeof task === "object") : [];
  const firstPassSignal = buildFirstPassSuccessSignal("", registryTasks);
  const loopEffortSignal = buildLoopEffortSignal(registryTasks);
  const boardHealthSignals = buildPersistedBoardHealthSignals("", registryTasks, records);
  const saturationCounts = buildStrategyFailureSaturationCounts(registryTasks);
  const externalResearch = buildExternalResearchSummary(externalSignals);
  const taskRegistryPressureSignal = buildTaskRegistryPressureSignal(registryTasks, options);
  const totalRecords = records.length;
  const successRecords = records.filter((record) => String(record.result || "").trim() === "SUCCESS").length;
  const timeoutFailureRecords = countUnresolvedTimeoutRecords(records, registryTasks);
  const pendingApproval = registryTasks.filter(
    (task) => String(task.status || "").trim().toLowerCase() === "pending_approval",
  ).length;
  const approved = registryTasks.filter(
    (task) => String(task.status || "").trim().toLowerCase() === "approved",
  ).length;
  const lastTask = registryTasks[registryTasks.length - 1] || null;
  const manualRecoveryRecords = records.filter(
    (record) => String(record.source || "").trim() === "manual_recovery",
  ).length;
  const saturatedFailedTasks = registryTasks.filter((task) => {
    if (String(task.status || "").trim().toLowerCase() !== "failed") {
      return false;
    }
    const saturationKey = strategySaturationKey(task);
    return Boolean(saturationKey) && (saturationCounts.get(saturationKey) || 0) >= STRATEGY_SATURATED_FAILURE_THRESHOLD;
  }).length;

  return {
    total_tasks: totalRecords,
    success_rate: totalRecords ? Number((successRecords / totalRecords).toFixed(2)) : 0,
    timeout_failure_records: timeoutFailureRecords,
    timeout_failure_rate: totalRecords ? Number((timeoutFailureRecords / totalRecords).toFixed(2)) : 0,
    analysis_runs: registryTasks.length,
    pending_approval_tasks: pendingApproval,
    approved_tasks: approved,
    task_registry_total: registryTasks.length,
    task_registry_payload_bytes: taskRegistryPressureSignal.task_registry_payload_bytes,
    task_registry_pressure_detected: taskRegistryPressureSignal.task_registry_pressure_detected,
    task_registry_pressure_primary_surface: taskRegistryPressureSignal.task_registry_pressure_primary_surface,
    last_task_score: lastTask ? safeNumber(lastTask.score, 0) : 0,
    manual_recovery_records: manualRecoveryRecords,
    low_first_pass_success_detected: firstPassSignal.detected,
    strategy_saturation_detected: saturatedFailedTasks > 0,
    saturated_failed_tasks: saturatedFailedTasks,
    retry_churn_detected: boardHealthSignals.retry_churn_detected,
    queue_starvation_detected: boardHealthSignals.queue_starvation_detected,
    pending_approval_blocked_detected: boardHealthSignals.pending_approval_blocked_detected,
    first_pass_success_rate: firstPassSignal.first_pass_success_rate,
    first_pass_success_count: firstPassSignal.first_pass_success_count,
    multi_attempt_resolved_count: firstPassSignal.multi_attempt_resolved_count,
    loop_effort_detected: loopEffortSignal.detected,
    loop_effort_task_count: loopEffortSignal.loop_effort_task_count,
    loop_effort_extra_step_attempts: loopEffortSignal.loop_effort_extra_step_attempts,
    external_signal_status: externalResearch.status,
    external_signal_count: externalResearch.total_signals,
    fresh_external_signal_count: externalResearch.fresh_signals,
    external_signal_error_count: externalResearch.errors,
    external_signal_updated_at: externalResearch.updated_at,
    latest_external_signal_source: externalResearch.latest_signal?.source_label || "",
    latest_external_signal_title: externalResearch.latest_signal?.title || "",
    latest_external_signal_url: externalResearch.latest_signal?.url || "",
    latest_external_signal_published_at: externalResearch.latest_signal?.published_at || "",
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
  const [taskLog, registryPayload, externalSignals] = await Promise.all([
    readText(PATHS.taskLog),
    tasks === null ? readTaskRegistryPayload() : Promise.resolve({ tasks }),
    readJsonFile(PATHS.externalSignals, {}),
  ]);
  const records = parseJsonLines(taskLog);
  const metrics = buildPersistedMetrics(registryPayload.tasks, records, externalSignals, {
    task_registry_payload_bytes: registryPayload.payloadBytes,
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
  return sanitizeProjectName(task.project || task.target_project || "codex-agent-system") || "codex-agent-system";
}

function taskExecutionText(task) {
  return sanitizeTaskText(task.execution_task || task.title || "");
}

function buildApprovalExecutionBrief({ approvedAt, project, queueTask, provider, queueStatus, taskIntent }) {
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
  const located = await locateTaskRegistryTask(taskId, requestedProject);
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
      verificationCommand: sanitizeTaskText(preparedTask?.task_shape?.verification_command || ""),
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
  const providedAuthHealth = options.authHealth && typeof options.authHealth === "object" ? options.authHealth : null;
  const providedRuntimeDashboardStatus =
    options.runtimeDashboardStatus && typeof options.runtimeDashboardStatus === "object"
      ? options.runtimeDashboardStatus
      : null;
  const [{ taskLog, queueTasks, status, tasks: plannedTasks, taskLogRecords }, settings, externalSignals] = await Promise.all([
    summarySnapshot ? Promise.resolve(summarySnapshot) : readTaskRegistrySummarySnapshot(),
    providedSettings ? Promise.resolve(providedSettings) : readDashboardSettings(),
    providedExternalSignals ? Promise.resolve(providedExternalSignals) : readJsonFile(PATHS.externalSignals, {}),
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
  });
  const taskSummary = applyRuntimeReloadGateToTaskSummary(
    summarizeTaskRegistry(plannedTasks, authHealth, {
      taskRegistryPressureSignal,
    }),
    runtimeDashboardStatus,
  );
  const firstPassSignal = buildFirstPassSuccessSignal("", plannedTasks);
  const loopEffortSignal = buildLoopEffortSignal(plannedTasks);
  const boardHealthSignals = buildPersistedBoardHealthSignals("", plannedTasks, records);
  const externalResearch = buildExternalResearchSummary(externalSignals);
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
    strategySaturationDetected: taskSummary.strategy.saturated_failed_tasks > 0,
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
    queueStarvation: {
      detected: boardHealthSignals.queue_starvation_detected,
      actionable_backlog_count: boardHealthSignals.actionable_backlog_count,
      active_progress_count: boardHealthSignals.active_progress_count,
    },
    taskRegistryPressure: {
      detected: taskRegistryPressureSignal.task_registry_pressure_detected,
      payload_bytes: taskRegistryPressureSignal.task_registry_payload_bytes,
      primary_surface: taskRegistryPressureSignal.task_registry_pressure_primary_surface,
    },
    pendingApprovalBlocker: {
      detected: boardHealthSignals.pending_approval_blocked_detected,
      pending_approval_tasks: pendingApproval,
      approved_tasks: approved,
      active_progress_count: boardHealthSignals.active_progress_count,
    },
    externalResearch,
  };
}

async function readDashboardSnapshot() {
  const artifacts = await readDashboardArtifacts({ includeProjects: true, includeStrategyLatest: true });
  const {
    projects,
    summarySnapshot: taskRegistrySnapshot,
    settings,
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
  });
  const taskRegistrySummary = applyRuntimeReloadGateToTaskSummary(
    summarizeTaskRegistry(taskRegistrySnapshot.tasks, authHealth, {
      taskRegistryPressureSignal,
    }),
    runtimeDashboardStatus,
  );

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
    },
    metrics,
    queue: {
      tasks: Array.isArray(taskRegistrySnapshot.queueTasks) ? taskRegistrySnapshot.queueTasks : [],
    },
    taskRegistry: {
      tasks: taskRegistrySnapshot.tasks,
      summary: taskRegistrySummary,
      authHealth,
      ...runtimeDashboardStatus,
    },
  };
}

async function readDashboardArtifacts(options = {}) {
  const includeProjects = options.includeProjects === true;
  const includeStrategyLatest = options.includeStrategyLatest === true;
  const [summarySnapshot, settings, externalSignals, projects, strategyLatestPayload, strategyLatestStat] = await Promise.all([
    readTaskRegistrySummarySnapshot(),
    readDashboardSettings(),
    readJsonFile(PATHS.externalSignals, {}),
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
    externalSignals,
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

  if (request.method === "GET" && url.pathname === "/api/task-registry") {
    const artifacts = await readDashboardArtifacts();
    const { summarySnapshot, authHealth, runtimeDashboardStatus } = artifacts;
    const { tasks } = summarySnapshot;
    const taskRegistryPressureSignal = buildTaskRegistryPressureSignal(tasks, {
      task_registry_payload_bytes: summarySnapshot.taskRegistryPayloadBytes,
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

      if (fromParam) {
        const fromMs = new Date(fromParam).getTime();
        if (Number.isFinite(fromMs)) records = records.filter(r => new Date(r.timestamp).getTime() >= fromMs);
      }
      if (toParam) {
        const toMs = new Date(toParam).getTime();
        if (Number.isFinite(toMs)) records = records.filter(r => new Date(r.timestamp).getTime() <= toMs);
      }

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
