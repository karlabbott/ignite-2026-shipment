/* Operations and presentation views for the live mixed-Linux estate. */

const TIER_ORDER = ["web", "api", "db", "worker"];
const TIER_LABEL = { web: "Web", api: "API", db: "Database", worker: "Worker" };
const TIER_LOGO = {
  web: "/static/logos/ubuntu.svg",
  api: "/static/logos/suse.svg",
  db: "/static/logos/redhat.svg",
  worker: "/static/logos/rockylinux.svg",
};

const lastPlatform = new Map();
const lastTopologyPlatform = new Map();
const lastStatus = new Map();
const queueHistory = [];
const throughputHistory = [];
let latestEstate = [];
let lastGoldenStatus = null;
let consecutiveBoardFailures = 0;
let returnProbeTimer = null;

function probeReturnUrl() {
  const target = (window.RETURN_URL || "").replace(/\/$/, "");
  if (!target || target === window.location.origin) return;
  const image = new Image();
  image.onload = () => window.location.replace(`${target}/?restored=1`);
  image.src = `${target}/static/ready.svg?cutover=${Date.now()}`;
}

function setUnavailable(unavailable) {
  document.getElementById("unavailable-page").classList.toggle("hidden", !unavailable);
  document.body.classList.toggle("estate-unavailable", unavailable);
  if (unavailable && !returnProbeTimer) {
    probeReturnUrl();
    returnProbeTimer = setInterval(probeReturnUrl, 3000);
  } else if (!unavailable && returnProbeTimer) {
    clearInterval(returnProbeTimer);
    returnProbeTimer = null;
  }
}

async function getDashboardJSON(url) {
  try {
    return await getJSON(url);
  } catch (err) {
    if (err.status) throw err;
    await new Promise((resolve) => setTimeout(resolve, 250));
    return getJSON(url);
  }
}

function logoFor(tile) {
  if ((tile.distro || "").toLowerCase().includes("azure linux")) {
    return "/static/logos/azurelinux.svg";
  }
  return TIER_LOGO[tile.tier] || "/static/logos/azurelinux.svg";
}

function orderedEstate(tiers) {
  const result = [];
  for (const tier of ["web", "api", "db"]) {
    result.push(tiers.find((tile) => tile.tier === tier) || { tier, missing: true });
  }
  const workers = tiers.filter((tile) => tile.tier === "worker");
  result.push(...(workers.length ? workers : [{ tier: "worker", missing: true }]));
  result.push(...tiers.filter((tile) => !TIER_ORDER.includes(tile.tier)));
  return result;
}

function renderEstate(payload) {
  const container = document.getElementById("estate");
  const tiers = (payload && payload.tiers) || [];
  latestEstate = tiers;

  container.innerHTML = orderedEstate(tiers).map((tile) => {
    const tier = tile.tier;
    if (tile.missing) {
      return `
        <div class="tile unhealthy" data-tier="${tier}">
          <div class="tile-heading">
            <span class="distro-mark unavailable">?</span>
            <div><div class="tier">${TIER_LABEL[tier] || tier}</div><div class="host">not reporting</div></div>
          </div>
          <div class="distro">No heartbeat received</div>
          <div class="meta"><span class="chip down">Offline</span></div>
        </div>`;
    }

    const platform = tile.platform || "unknown";
    const identityKey = `${tier}:${tile.hostname}`;
    const previous = lastPlatform.get(identityKey);
    const flipped = previous && previous !== platform;
    lastPlatform.set(identityKey, platform);
    const classes = [
      "tile",
      `platform-${platformClass(platform)}`,
      tile.healthy === false ? "unhealthy" : "",
      flipped ? "flipped" : "",
    ].filter(Boolean).join(" ");
    const size = tile.vm_size ? `<span class="chip">${escapeHTML(tile.vm_size)}</span>` : "";
    const seen = tile.healthy === false
      ? `<span class="chip down"${tile.last_seen ? ` title="Last heartbeat ${escapeHTML(relativeTime(tile.last_seen))}"` : ""}>Heartbeat stale</span>`
      : `<span class="chip live"${tile.last_seen ? ` title="Last heartbeat ${escapeHTML(relativeTime(tile.last_seen))}"` : ' title="This tier served the current request"'}><span class="live-dot"></span>Live</span>`;

    return `
      <div class="${classes}" data-tier="${tier}">
        <div class="tile-heading">
          <span class="distro-mark"><img src="${logoFor(tile)}" alt="" aria-hidden="true"></span>
          <div><div class="tier">${escapeHTML(TIER_LABEL[tier] || tier)}</div><div class="host">${escapeHTML(tile.hostname)}</div></div>
        </div>
        <div class="distro">${escapeHTML(tile.distro)}</div>
        <div class="meta">
          <span class="chip ${platformClass(platform)}">${escapeHTML(platform)}</span>
          <span class="chip">${escapeHTML(tile.location || "")}</span>
          ${size}${seen}
        </div>
      </div>`;
  }).join("");

  renderTopology(tiers);
  if (payload && payload.degraded) {
    showBanner(
      `Estate partially visible: ${describeDetail(payload.reason) || "API tier unreachable"}`,
      "warn",
    );
  }
}

function pushMetric(history, value) {
  history.push(Number(value) || 0);
  if (history.length > 48) history.shift();
}

function renderSparkline(id, history, tone) {
  const svg = document.getElementById(id);
  if (!svg) return;
  const values = history.length > 1 ? history : [0, ...(history || [0])];
  const max = Math.max(1, ...values);
  const points = values.map((value, index) => {
    const x = (index / Math.max(1, values.length - 1)) * 500;
    const y = 108 - (value / max) * 92;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
  const area = `0,120 ${points} 500,120`;
  svg.innerHTML = `
    <line x1="0" y1="108" x2="500" y2="108" class="chart-baseline"/>
    <polygon points="${area}" class="chart-area ${tone}"/>
    <polyline points="${points}" class="chart-line ${tone}"/>`;
}

function renderStats(stats) {
  const set = (id, value) => {
    document.getElementById(id).textContent = value == null ? "–" : value;
  };
  set("stat-total", stats.total);
  set("stat-inflight", stats.in_flight);
  set("stat-delivered", stats.delivered);
  set("stat-queue", stats.queue_depth);
  set("stat-scans", stats.scans_last_5m);
  set("queue-current", stats.queue_depth);
  set("throughput-current", stats.scans_last_5m);
  pushMetric(queueHistory, stats.queue_depth);
  pushMetric(throughputHistory, stats.scans_last_5m);
  renderSparkline("queue-chart", queueHistory, "queue");
  renderSparkline("throughput-chart", throughputHistory, "throughput");
}

function renderBoard(rows) {
  const body = document.getElementById("board");
  body.innerHTML = rows.map((row) => {
    const changed = lastStatus.get(row.tracking_number) !== undefined
      && lastStatus.get(row.tracking_number) !== row.status;
    lastStatus.set(row.tracking_number, row.status);
    const done = row.status === "DELIVERED" ? " done" : "";
    return `
      <tr class="${changed ? "changed" : ""}">
        <td><a class="tracking-link mono" href="/track?n=${encodeURIComponent(row.tracking_number)}">${escapeHTML(row.tracking_number)}</a></td>
        <td>${escapeHTML(row.carrier_code)}</td>
        <td>${escapeHTML(row.origin)} &rarr; ${escapeHTML(row.destination)}</td>
        <td class="status status-${escapeHTML(row.status)}">${escapeHTML(row.status_narrative)}</td>
        <td><div class="progress"><div class="bar${done}" style="width:${Number(row.progress_percent) || 0}%"></div></div></td>
        <td>${escapeHTML(row.last_location || "—")}</td>
        <td class="host-tag">${escapeHTML(row.last_scanned_by || "—")}</td>
        <td>${escapeHTML(row.created_by)}</td>
      </tr>`;
  }).join("");
}

function topologyPosition(tile, workerIndex) {
  const azure = platformClass(tile.platform) === "azure";
  const offset = azure ? 50 : 0;
  const positions = {
    web: { x: 9 + offset, y: 31 },
    api: { x: 25 + offset, y: 31 },
    db: { x: 41 + offset, y: 31 },
    worker: { x: 41 + offset - workerIndex * 10, y: 72 + workerIndex * 8 },
  };
  return positions[tile.tier] || { x: 25 + offset, y: 72 };
}

function renderTopology(tiers) {
  const nodes = document.getElementById("topology-nodes");
  const lines = document.getElementById("topology-lines");
  if (!nodes || !lines) return;
  const workers = tiers.filter((tile) => tile.tier === "worker");
  const positioned = tiers.map((tile) => {
    const workerIndex = tile.tier === "worker" ? workers.indexOf(tile) : 0;
    return { tile, position: topologyPosition(tile, workerIndex) };
  });
  const byTier = new Map(positioned.filter((item) => item.tile.tier !== "worker").map((item) => [item.tile.tier, item]));
  const links = [];
  const addLink = (from, to, kind) => {
    if (!from || !to) return;
    const x1 = from.position.x * 10;
    const y1 = from.position.y * 4.2;
    const x2 = to.position.x * 10;
    const y2 = to.position.y * 4.2;
    const bend = Math.max(32, Math.abs(x2 - x1) * 0.18);
    links.push(`<path class="topology-link ${kind}" d="M${x1},${y1} C${x1 + bend},${y1} ${x2 - bend},${y2} ${x2},${y2}"/>`);
  };
  addLink(byTier.get("web"), byTier.get("api"), "request");
  addLink(byTier.get("api"), byTier.get("db"), "request");
  for (const worker of positioned.filter((item) => item.tile.tier === "worker")) {
    addLink(worker, byTier.get("db"), "queue");
  }
  lines.innerHTML = links.join("");

  nodes.innerHTML = positioned.map(({ tile, position }) => {
    const key = `${tile.tier}:${tile.hostname}`;
    const previous = lastTopologyPlatform.get(key);
    const moved = previous && previous !== tile.platform;
    lastTopologyPlatform.set(key, tile.platform);
    return `
      <div class="topology-node ${moved ? "moved" : ""} ${tile.healthy === false ? "unhealthy" : ""}"
           style="--node-x:${position.x}%;--node-y:${position.y}%">
        <span class="topology-logo"><img src="${logoFor(tile)}" alt=""></span>
        <span><small>${escapeHTML(TIER_LABEL[tile.tier] || tile.tier)}</small><strong>${escapeHTML(tile.hostname)}</strong></span>
        <i class="${platformClass(tile.platform)}"></i>
      </div>`;
  }).join("");
}

function renderGolden(shipment) {
  const container = document.getElementById("golden-spotlight");
  if (!shipment) {
    container.classList.add("hidden");
    return;
  }
  container.classList.remove("hidden");
  container.classList.toggle("delivered", shipment.status === "DELIVERED");
  const deliveryKey = `zava-delivered:${shipment.tracking_number}`;
  const celebrate = shipment.status === "DELIVERED"
    && lastGoldenStatus
    && lastGoldenStatus !== "DELIVERED"
    && !sessionStorage.getItem(deliveryKey);
  if (celebrate) sessionStorage.setItem(deliveryKey, "1");
  lastGoldenStatus = shipment.status;
  const holdLabel = shipment.is_held
    ? "Ready for final delivery"
    : shipment.hold_status
      ? `Delivery hold armed at ${shipment.hold_status.replace(/_/g, " ").toLowerCase()}`
      : "";
  container.innerHTML = `
    <div class="golden-mark">Golden shipment</div>
    <div class="golden-main">
      <a href="/track?n=${encodeURIComponent(shipment.tracking_number)}" class="golden-number mono">${escapeHTML(shipment.tracking_number)}</a>
      <span class="golden-route">${escapeHTML(shipment.origin)} <b>&rarr;</b> ${escapeHTML(shipment.destination)}</span>
      ${holdLabel ? `<span class="golden-hold">${escapeHTML(holdLabel)}</span>` : ""}
    </div>
    <div class="golden-state">
      <strong class="status status-${escapeHTML(shipment.status)}">${escapeHTML(shipment.status_narrative)}</strong>
      <div class="progress"><div class="bar ${shipment.status === "DELIVERED" ? "done" : ""}" style="width:${Number(shipment.progress_percent) || 0}%"></div></div>
    </div>
    ${shipment.status === "DELIVERED" ? `<div class="golden-delivered${celebrate ? " celebrate" : ""}">Delivered</div>` : ""}`;
}

function renderPresentation(payload) {
  renderGolden(payload && payload.golden);
  const shipments = (payload && payload.shipments) || [];
  window.ZavaMap.renderGlobe(document.getElementById("audience-globe"), shipments);
  document.getElementById("globe-count").textContent =
    `${shipments.length} route${shipments.length === 1 ? "" : "s"}`;
}

function renderPoll(poll) {
  const card = document.getElementById("failure-poll-card");
  const tally = document.getElementById("poll-tally");
  const state = document.getElementById("poll-state");
  const displayToggle = document.getElementById("poll-display-toggle");
  const stageStatus = document.getElementById("poll-stage-status");
  const stageLabel = document.getElementById("poll-stage-label");
  const stageDetail = document.getElementById("poll-stage-detail");
  if (!card || !tally || !state || !displayToggle || !stageStatus || !stageLabel || !stageDetail) return;

  card.classList.remove("state-open", "state-locked", "state-injected", "state-recovered");
  card.classList.toggle("active", Boolean(poll && poll.poll_id));
  if (!poll || !poll.poll_id) {
    card.classList.remove("minimized");
    state.textContent = "Poll closed";
    displayToggle.classList.add("hidden");
    displayToggle.textContent = "Minimize";
    displayToggle.setAttribute("aria-expanded", "true");
    stageStatus.classList.add("hidden");
    tally.innerHTML = `<p class="poll-empty">Voting opens during the final live demonstration.</p>`;
    return;
  }

  const winner = poll.choices.find((choice) => choice.code === poll.winner_code);
  const lifecycle = {
    open: {
      label: "VOTING OPEN",
      detail: "Results stay hidden until voting closes",
    },
    locked: {
      label: "VOTING LOCKED",
      detail: winner ? `${winner.label} selected` : "Audience decision locked",
    },
    injected: {
      label: "FAULT INJECTED",
      detail: winner ? winner.label : "Audience-selected failure active",
    },
    recovered: {
      label: "SERVICE RECOVERED",
      detail: "Business SLO restored and verified",
    },
  }[poll.state];

  card.classList.add(`state-${poll.state}`);
  displayToggle.classList.remove("hidden");
  stageStatus.classList.remove("hidden");
  stageLabel.textContent = lifecycle ? lifecycle.label : poll.state.toUpperCase();
  stageDetail.textContent = lifecycle ? lifecycle.detail : "";
  state.textContent = `${lifecycle ? lifecycle.label : poll.state.toUpperCase()} · ${poll.total_votes} vote${poll.total_votes === 1 ? "" : "s"}`;
  if (poll.state === "open") {
    tally.innerHTML = poll.choices.map((choice) => `
      <div class="poll-result concealed">
        <strong>${escapeHTML(choice.label)}</strong>
        <span>Results hidden</span>
      </div>`).join("");
    return;
  }
  tally.innerHTML = poll.choices.map((choice) => {
    const percent = poll.total_votes ? Math.round((choice.votes / poll.total_votes) * 100) : 0;
    const winner = poll.winner_code === choice.code;
    return `
      <div class="poll-result${winner ? " winner" : ""}">
        <div><strong>${escapeHTML(choice.label)}</strong><span>${choice.votes}</span></div>
        <div class="poll-bar"><i style="width:${percent}%"></i></div>
      </div>`;
  }).join("");
}

function setView(view) {
  for (const button of document.querySelectorAll(".view-button")) {
    button.classList.toggle("active", button.dataset.view === view);
  }
  document.getElementById("operations-view").classList.toggle("hidden", view !== "operations");
  document.getElementById("network-view").classList.toggle("hidden", view !== "network");
  if (view === "network") renderTopology(latestEstate);
}

for (const button of document.querySelectorAll(".view-button")) {
  button.addEventListener("click", () => {
    const view = button.dataset.view;
    setView(view);
    history.replaceState(null, "", view === "network" ? "/?view=network" : "/");
  });
}

async function refresh() {
  try {
    renderEstate(await getDashboardJSON("/api/estate"));
  } catch (err) {
    showBanner(`Cannot read estate health: ${err.message}`, "error");
  }

  try {
    const [stats, board] = await Promise.all([
      getDashboardJSON("/api/stats"),
      getDashboardJSON("/api/board"),
    ]);
    renderStats(stats);
    renderBoard(board);
    consecutiveBoardFailures = 0;
    setUnavailable(false);
    clearBanner();
  } catch (err) {
    consecutiveBoardFailures += 1;
    if (consecutiveBoardFailures >= 2) setUnavailable(true);
    if (err.status === 503) {
      showBanner(`Database tier unavailable — ${err.message}`, "error");
    } else if (err.status === 502 || err.status === 504) {
      showBanner(`API tier unavailable — ${err.message}`, "error");
    } else {
      showBanner(`Board unavailable — ${err.message}`, "error");
    }
  }

  try {
    const [presentation, poll] = await Promise.all([
      getDashboardJSON("/api/presentation?limit=30"),
      getDashboardJSON("/api/poll"),
    ]);
    renderPresentation(presentation);
    renderPoll(poll);
  } catch (err) {
    console.warn("presentation feed unavailable", err);
  }
}

refresh();
setView(new URLSearchParams(window.location.search).get("view") === "network" ? "network" : "operations");
document.getElementById("poll-display-toggle").addEventListener("click", () => {
  const card = document.getElementById("failure-poll-card");
  const button = document.getElementById("poll-display-toggle");
  const minimized = card.classList.toggle("minimized");
  button.textContent = minimized ? "Show poll" : "Minimize";
  button.setAttribute("aria-expanded", String(!minimized));
});
setInterval(refresh, window.REFRESH_MS || 3000);
