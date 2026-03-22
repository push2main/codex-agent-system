const http = require("http");
const https = require("https");
const fs = require("fs");
const fsp = fs.promises;
const os = require("os");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const PORT = Number(process.env.DASHBOARD_PORT || 3000);
const HTTPS_ENABLED = String(process.env.DASHBOARD_HTTPS || "0") === "1";
const PROTOCOL = HTTPS_ENABLED ? "https" : "http";
const TLS_KEY_FILE =
  process.env.DASHBOARD_TLS_KEY_FILE || path.join(ROOT, "codex-logs", "dashboard-tls", "dashboard-key.pem");
const TLS_CERT_FILE =
  process.env.DASHBOARD_TLS_CERT_FILE || path.join(ROOT, "codex-logs", "dashboard-tls", "dashboard-cert.pem");
const QUEUE_LIMIT = Number(process.env.QUEUE_LIMIT || 20);
const PATHS = {
  dashboard: __dirname,
  projects: path.join(ROOT, "projects"),
  queues: path.join(ROOT, "queues"),
  authFailure: path.join(ROOT, "codex-logs", "codex-auth-failure.json"),
  logs: path.join(ROOT, "codex-logs", "system.log"),
  metrics: path.join(ROOT, "codex-learning", "metrics.json"),
  rules: path.join(ROOT, "codex-learning", "rules.md"),
  taskLog: path.join(ROOT, "codex-memory", "tasks.log"),
  taskRegistry: path.join(ROOT, "codex-memory", "tasks.json"),
  status: path.join(ROOT, "status.txt"),
};

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
    '{\n  "total_tasks": 0,\n  "success_rate": 0,\n  "analysis_runs": 0,\n  "pending_approval_tasks": 0,\n  "approved_tasks": 0,\n  "task_registry_total": 0,\n  "last_task_score": 0,\n  "manual_recovery_records": 0\n}\n',
  );
  ensureFile(PATHS.rules, "# Learned Rules\n\n");
  ensureFile(PATHS.taskLog, "");
  ensureFile(PATHS.taskRegistry, '{\n  "tasks": []\n}\n');
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

function safeNumber(value, fallback = 0) {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : fallback;
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

function taskSlug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
}

async function readText(filePath) {
  try {
    return await fsp.readFile(filePath, "utf8");
  } catch {
    return "";
  }
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
  const payload = await readJsonFile(PATHS.taskRegistry, { tasks: [] });
  const tasks = Array.isArray(payload.tasks) ? payload.tasks : [];
  return tasks
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
      const rawExecution = task.execution && typeof task.execution === "object" ? task.execution : null;
      const execution = rawExecution
        ? {
            ...rawExecution,
            attempt: Number(rawExecution.attempt || 0),
            max_retries: Number(rawExecution.max_retries || 0),
            result: typeof rawExecution.result === "string" ? rawExecution.result : "",
            state: typeof rawExecution.state === "string" ? rawExecution.state : "",
            updated_at: typeof rawExecution.updated_at === "string" ? rawExecution.updated_at : "",
            will_retry: Boolean(rawExecution.will_retry),
          }
        : null;
      const historyPreview = history.slice(-2).reverse();

      return {
        ...task,
        id: typeof task.id === "string" && task.id.trim() ? task.id.trim() : fallbackId,
        title,
        category: typeof task.category === "string" ? task.category : "code_quality",
        confidence: Number(task.confidence || 0),
        created_at: createdAt,
        execution,
        effort: Number(task.effort || 0),
        history,
        history_preview: historyPreview,
        impact: Number(task.impact || 0),
        last_history_entry: history.length ? history[history.length - 1] : null,
        project: sanitizeProjectName(task.project || "codex-agent-system") || "codex-agent-system",
        score: Number(task.score || 0),
        status: typeof task.status === "string" ? task.status : "pending_approval",
        updated_at: updatedAt,
      };
    })
    .sort((left, right) => Number(right.score || 0) - Number(left.score || 0))
    .map((task, index) => ({
      ...task,
      rank: index + 1,
    }));
}

function summarizeTaskRegistry(tasks, authHealth = null) {
  const byStatus = {
    pending_approval: 0,
    approved: 0,
    completed: 0,
    other: 0,
  };
  const byCategory = {};

  for (const task of tasks) {
    const status = String(task.status || "").toLowerCase();
    if (status === "pending_approval" || status === "approved" || status === "completed") {
      byStatus[status] += 1;
    } else {
      byStatus.other += 1;
    }

    const category = String(task.category || "code_quality");
    byCategory[category] = (byCategory[category] || 0) + 1;
  }

  const topTask = tasks[0] || null;
  const topPendingTask = tasks.find((task) => task.status === "pending_approval") || null;
  const topApprovedTask = tasks.find((task) => task.status === "approved") || null;
  const oldestPendingTask = tasks
    .filter((task) => task.status === "pending_approval" && task.created_at)
    .sort((left, right) => String(left.created_at).localeCompare(String(right.created_at)))[0] || null;
  const topCategoryEntry = Object.entries(byCategory).sort(
    (left, right) => right[1] - left[1] || left[0].localeCompare(right[0]),
  )[0] || null;

  let nextAction = {
    state: "idle",
    message: "No tracked tasks yet.",
  };

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
    nextAction = {
      state: "approval",
      message: `Review pending task: ${topPendingTask.title}`,
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
    nextAction,
  };
}

async function readTaskRegistryPayload() {
  const payload = await readJsonFile(PATHS.taskRegistry, { tasks: [] });
  return {
    ...payload,
    tasks: Array.isArray(payload.tasks) ? payload.tasks : [],
  };
}

async function writeTaskRegistryPayload(payload) {
  await writeJsonFile(PATHS.taskRegistry, {
    ...payload,
    tasks: Array.isArray(payload.tasks) ? payload.tasks : [],
  });
}

function buildPersistedMetrics(tasks, records) {
  const registryTasks = Array.isArray(tasks) ? tasks.filter((task) => task && typeof task === "object") : [];
  const totalRecords = records.length;
  const successRecords = records.filter((record) => String(record.result || "").trim() === "SUCCESS").length;
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

  return {
    total_tasks: totalRecords,
    success_rate: totalRecords ? Number((successRecords / totalRecords).toFixed(2)) : 0,
    analysis_runs: registryTasks.length,
    pending_approval_tasks: pendingApproval,
    approved_tasks: approved,
    task_registry_total: registryTasks.length,
    last_task_score: lastTask ? safeNumber(lastTask.score, 0) : 0,
    manual_recovery_records: manualRecoveryRecords,
  };
}

async function refreshPersistedMetrics(tasks = null) {
  const [taskLog, registryPayload] = await Promise.all([
    readText(PATHS.taskLog),
    tasks === null ? readTaskRegistryPayload() : Promise.resolve({ tasks }),
  ]);
  const records = parseJsonLines(taskLog);
  const metrics = buildPersistedMetrics(registryPayload.tasks, records);
  await writeJsonFile(PATHS.metrics, metrics);
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
  return String(task.execution_task || task.title || "").trim();
}

async function transitionTaskRegistryItem(taskId, action) {
  const payload = await readTaskRegistryPayload();
  const index = payload.tasks.findIndex((task) => String(task.id || "").trim() === taskId);
  if (index === -1) {
    return { ok: false, status: 404, error: "Task was not found." };
  }

  const existing = payload.tasks[index];
  const normalizedTask = (await readTaskRegistry()).find((task) => task.id === taskId);
  const fromStatus = String((normalizedTask || existing).status || "pending_approval");

  if (action === "approve") {
    if (fromStatus !== "pending_approval") {
      return { ok: false, status: 409, error: "Only pending approval tasks can be approved." };
    }

    const transitionAt = nowUtc();
    const project = normalizeTaskProject(existing);
    const queueTask = taskExecutionText(existing);
    if (!queueTask) {
      return { ok: false, status: 400, error: "Approved tasks need a non-empty title or execution task." };
    }

    const enqueueResult = await enqueueTask(project, queueTask);
    const duplicateQueue = enqueueResult.error === "Duplicate task rejected.";
    if (!enqueueResult.ok && !duplicateQueue) {
      return enqueueResult;
    }

    const nextTask = {
      ...existing,
      project,
      status: "approved",
      approved_at: transitionAt,
      updated_at: transitionAt,
      queue_handoff: {
        at: transitionAt,
        project,
        task: queueTask,
        status: duplicateQueue ? "already_queued" : "queued",
      },
    };
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "approve", fromStatus, "approved", {
        at: transitionAt,
        note: duplicateQueue ? "Task was already queued or running." : "Task was enqueued after approval.",
        project,
        queueTask,
      }),
    );
    payload.tasks[index] = nextTask;
    await writeTaskRegistryPayload(payload);
    await refreshPersistedMetrics(payload.tasks);
    await appendLog(`Approved task ${taskId} for ${project}: ${queueTask}`);
    return {
      ok: true,
      status: 200,
      task: nextTask,
      message: duplicateQueue ? "Task approved and recognized as already queued." : "Task approved and queued.",
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
    await writeTaskRegistryPayload(payload);
    await refreshPersistedMetrics(payload.tasks);
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

async function readMetrics() {
  const [taskLog, queueCount, status, plannedTasks] = await Promise.all([
    readText(PATHS.taskLog),
    queueTaskCount(),
    readStatus(),
    readTaskRegistry(),
  ]);
  const records = parseJsonLines(taskLog);
  const authHealth = await readCodexAuthHealth(status);
  const taskSummary = summarizeTaskRegistry(plannedTasks, authHealth);
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
  return {
    total,
    success,
    failure,
    successRate,
    queued: queueCount,
    pendingApproval,
    approved,
    taskRegistryTotal: taskSummary.total,
    averageDurationSeconds,
    averageScore,
    currentState: status.state || "idle",
    lastRun,
    lastFailed,
    authHealth,
    topPendingTask: taskSummary.topPendingTask,
    nextAction: taskSummary.nextAction,
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

  if (request.method === "GET" && url.pathname === "/api/status") {
    const [status, addresses] = await Promise.all([readStatus(), Promise.resolve(localAddresses())]);
    const authHealth = await readCodexAuthHealth(status);
    sendJson(response, 200, { ...status, authHealth, port: PORT, addresses, protocol: PROTOCOL });
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

  if (request.method === "GET" && url.pathname === "/api/metrics") {
    const metrics = await readMetrics();
    sendJson(response, 200, metrics);
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/task-registry") {
    const [tasks, status] = await Promise.all([readTaskRegistry(), readStatus()]);
    const authHealth = await readCodexAuthHealth(status);
    sendJson(response, 200, { tasks, summary: summarizeTaskRegistry(tasks, authHealth), authHealth });
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task-registry/action") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const taskId = String(body.id || "").trim();
      const action = String(body.action || "").trim().toLowerCase();
      if (!taskId || !action) {
        sendJson(response, 400, { error: "Task id and action are required." });
        return;
      }
      const result = await transitionTaskRegistryItem(taskId, action);
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
      const result = await enqueueTask(body.project || body.newProject, body.task);
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

  sendJson(response, 404, { error: "Not found" });
}

ensureStructure();

const requestHandler = async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);
  if (url.pathname.startsWith("/api/")) {
    await handleApi(request, response, url);
    return;
  }

  const filePath = url.pathname === "/" ? path.join(PATHS.dashboard, "index.html") : null;
  if (!filePath) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }

  const html = await readText(filePath);
  response.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(html);
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
