/* Operations board: health strip, counters, live shipment table. */

const TIER_ORDER = ["web", "api", "db", "worker"];
const TIER_LABEL = { web: "Web", api: "API", db: "Database", worker: "Worker" };
const TIER_LOGO = {
  web: "/static/logos/ubuntu.svg",
  api: "/static/logos/suse.svg",
  db: "/static/logos/redhat.svg",
  worker: "/static/logos/rockylinux.svg",
};

/* Remembering the previous platform per tier is what lets us flash a tile the
   moment it moves from Hyper-V to Azure. That single animation is the payoff of
   the whole migration segment, so it must not be missed. */
const lastPlatform = new Map();
const lastStatus = new Map();

function renderEstate(payload) {
  const container = document.getElementById("estate");
  const tiers = (payload && payload.tiers) || [];
  const byTier = new Map(tiers.map((tile) => [tile.tier, tile]));

  container.innerHTML = TIER_ORDER.map((tier) => {
    const tile = byTier.get(tier);
    if (!tile) {
      return `
        <div class="tile unhealthy" data-tier="${tier}">
          <div class="tile-heading">
            <span class="distro-mark unavailable">?</span>
            <div>
              <div class="tier">${TIER_LABEL[tier]}</div>
              <div class="host">not reporting</div>
            </div>
          </div>
          <div class="distro">No heartbeat received</div>
          <div class="meta"><span class="chip down">offline</span></div>
        </div>`;
    }

    const platform = tile.platform || "unknown";
    const previous = lastPlatform.get(tier);
    const flipped = previous && previous !== platform;
    lastPlatform.set(tier, platform);

    const classes = [
      "tile",
      `platform-${platformClass(platform)}`,
      tile.healthy === false ? "unhealthy" : "",
      flipped ? "flipped" : "",
    ].filter(Boolean).join(" ");

    const size = tile.vm_size ? `<span class="chip">${escapeHTML(tile.vm_size)}</span>` : "";
    const seen = tile.last_seen
      ? `<span class="chip">${escapeHTML(relativeTime(tile.last_seen))}</span>`
      : "";

    return `
      <div class="${classes}" data-tier="${tier}">
        <div class="tile-heading">
          <span class="distro-mark">
            <img src="${TIER_LOGO[tier]}" alt="" aria-hidden="true">
          </span>
          <div>
            <div class="tier">${TIER_LABEL[tier]}</div>
            <div class="host">${escapeHTML(tile.hostname)}</div>
          </div>
        </div>
        <div class="distro">${escapeHTML(tile.distro)}</div>
        <div class="meta">
          <span class="chip ${platformClass(platform)}">${escapeHTML(platform)}</span>
          <span class="chip">${escapeHTML(tile.location || "")}</span>
          ${size}${seen}
        </div>
      </div>`;
  }).join("");

  if (payload && payload.degraded) {
    showBanner(
      `Estate partially visible: ${describeDetail(payload.reason) || "API tier unreachable"}`,
      "warn",
    );
  }
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
        <td class="mono">${escapeHTML(row.tracking_number)}</td>
        <td>${escapeHTML(row.carrier_code)}</td>
        <td>${escapeHTML(row.origin)} &rarr; ${escapeHTML(row.destination)}</td>
        <td class="status status-${escapeHTML(row.status)}">${escapeHTML(row.status_narrative)}</td>
        <td>
          <div class="progress">
            <div class="bar${done}" style="width:${Number(row.progress_percent) || 0}%"></div>
          </div>
        </td>
        <td>${escapeHTML(row.last_location || "—")}</td>
        <td class="host-tag">${escapeHTML(row.last_scanned_by || "—")}</td>
        <td>${escapeHTML(row.created_by)}</td>
      </tr>`;
  }).join("");
}

async function refresh() {
  /* The estate strip is fetched separately and never fails: the web tier always
     answers with at least its own tile, so we can still show which box is up. */
  try {
    renderEstate(await getJSON("/api/estate"));
  } catch (err) {
    showBanner(`Cannot read estate health: ${err.message}`, "error");
  }

  try {
    const [stats, board] = await Promise.all([
      getJSON("/api/stats"),
      getJSON("/api/board"),
    ]);
    renderStats(stats);
    renderBoard(board);
    clearBanner();
  } catch (err) {
    if (err.status === 503) {
      showBanner(`Database tier unavailable — ${err.message}`, "error");
    } else if (err.status === 502 || err.status === 504) {
      showBanner(`API tier unavailable — ${err.message}`, "error");
    } else {
      showBanner(`Board unavailable — ${err.message}`, "error");
    }
  }
}

refresh();
setInterval(refresh, window.REFRESH_MS || 3000);
