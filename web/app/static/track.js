/* Audience-facing tracking page: create a shipment, then follow it live. */

const createCard = document.getElementById("create-card");
const resultCard = document.getElementById("result-card");
const createForm = document.getElementById("create-form");
const createButton = document.getElementById("create-button");
const lookupForm = document.getElementById("lookup-form");
const itemPreset = document.getElementById("item-preset");
const customItem = document.getElementById("custom-item");
const customItemLabel = document.getElementById("custom-item-label");
const recentCard = document.getElementById("recent-card");
const recentShipments = document.getElementById("recent-shipments");
const voteLink = document.getElementById("audience-vote-link");
const voteStatus = document.getElementById("audience-vote-status");

let tracking = null;
let pollTimer = null;
let previousStatus = null;
const shipmentHistoryKey = "zava-created-shipments-v1";

async function refreshVotingLink() {
  try {
    const poll = await getJSON("/api/poll");
    voteLink.classList.toggle("hidden", poll.state !== "open");
    voteStatus.classList.add("hidden");
  } catch (err) {
    voteLink.classList.add("hidden");
    voteStatus.textContent = `Voting status unavailable - ${err.message}`;
    voteStatus.classList.remove("hidden");
  }
}

document.getElementById("clear-shipment-history").addEventListener("click", () => {
  try {
    localStorage.removeItem(shipmentHistoryKey);
    renderShipmentHistory();
  } catch (err) {
    showBanner(`Could not clear shipment history - ${err.message}`, "error");
  }
});

function loadShipmentHistory() {
  try {
    const value = JSON.parse(localStorage.getItem(shipmentHistoryKey) || "[]");
    return Array.isArray(value) ? value.slice(0, 12) : [];
  } catch {
    return [];
  }
}

function saveShipmentHistory(shipments) {
  try {
    localStorage.setItem(shipmentHistoryKey, JSON.stringify(shipments.slice(0, 12)));
  } catch {
    // Tracking still works when storage is unavailable or full.
  }
}

function renderShipmentHistory() {
  const shipments = loadShipmentHistory();
  recentShipments.replaceChildren();
  recentCard.classList.toggle("hidden", shipments.length === 0);

  for (const shipment of shipments) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    const number = document.createElement("span");
    const description = document.createElement("span");
    const route = document.createElement("span");

    button.type = "button";
    button.className = "recent-shipment";
    number.className = "mono recent-tracking";
    number.textContent = shipment.tracking_number;
    description.className = "recent-description";
    description.textContent = shipment.description;
    route.className = "recent-route";
    route.textContent = `${shipment.origin} → ${shipment.destination}`;
    button.append(number, description, route);
    button.addEventListener("click", () => {
      showResult(shipment.tracking_number);
      window.scrollTo({top: 0, behavior: "smooth"});
    });
    item.append(button);
    recentShipments.append(item);
  }
}

function rememberShipment(shipment) {
  const shipments = loadShipmentHistory().filter(
    (item) => item.tracking_number !== shipment.tracking_number,
  );
  shipments.unshift({
    tracking_number: shipment.tracking_number,
    description: shipment.description,
    origin: shipment.origin,
    destination: shipment.destination,
  });
  saveShipmentHistory(shipments);
  renderShipmentHistory();
}

function clientToken() {
  const key = "zava-audience-client";
  let token = localStorage.getItem(key);
  if (!token) {
    const bytes = new Uint8Array(24);
    crypto.getRandomValues(bytes);
    token = Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
    localStorage.setItem(key, token);
  }
  return token;
}

function updateCustomItem() {
  const custom = itemPreset.value === "__custom__";
  customItemLabel.classList.toggle("hidden", !custom);
  customItem.required = custom;
  if (custom) customItem.focus();
}

itemPreset.addEventListener("change", updateCustomItem);

function showResult(number) {
  tracking = number;
  document.getElementById("result-tracking").textContent = number;
  createCard.classList.add("hidden");
  resultCard.classList.remove("hidden");
  history.replaceState(null, "", `/track?n=${encodeURIComponent(number)}`);
  poll();
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(poll, window.REFRESH_MS || 3000);
}

function renderShipment(data) {
  const bar = document.getElementById("result-bar");
  bar.style.width = `${Number(data.progress_percent) || 0}%`;
  bar.classList.toggle("done", data.status === "DELIVERED");

  const statusLine = document.getElementById("result-status");
  statusLine.textContent = data.status_narrative;
  statusLine.className = `status-line status status-${data.status}`;

  document.getElementById("result-route").textContent =
    `${data.origin} → ${data.destination}`;
  document.getElementById("result-carrier").textContent =
    `${data.carrier_name} (${data.carrier_code})`;
  window.ZavaMap.renderRoute(
    document.getElementById("route-map"),
    data.route_points || [],
    data.progress_percent,
  );

  const scans = data.scans || [];
  if (scans.length) {
    document.getElementById("result-location").textContent = scans[0].location;
  }

  document.getElementById("result-scans").innerHTML = scans.length
    ? scans.map((scan) => `
        <li>
          <span class="scan-type">${escapeHTML(scan.scan_type.replace(/_/g, " "))}</span>
          — ${escapeHTML(scan.location)}
          <span class="scan-meta">
            ${escapeHTML(relativeTime(scan.occurred_at))} ·
            scanned by ${escapeHTML(scan.worker_host)} (${escapeHTML(scan.worker_site)})
          </span>
        </li>`).join("")
    : `<li class="hint">No scans yet — the worker tier picks this up within a few seconds.</li>`;

  const deliveryMoment = document.getElementById("delivery-moment");
  const delivered = data.status === "DELIVERED";
  deliveryMoment.classList.toggle("visible", delivered);
  if (delivered && previousStatus && previousStatus !== "DELIVERED") {
    deliveryMoment.classList.remove("celebrate");
    void deliveryMoment.offsetWidth;
    deliveryMoment.classList.add("celebrate");
  }
  previousStatus = data.status;
}

async function poll() {
  if (!tracking) return;
  try {
    renderShipment(await getJSON(`/api/shipments/${encodeURIComponent(tracking)}`));
    clearBanner();
  } catch (err) {
    if (err.status === 404) {
      showBanner(`No shipment found with number ${tracking}.`, "warn");
    } else {
      showBanner(`Cannot reach the tracking service right now — ${err.message}`, "error");
    }
  }
}

createForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  createButton.disabled = true;
  clearBanner();

  const form = new FormData(createForm);
  const description = form.get("item_preset") === "__custom__"
    ? form.get("custom_item")
    : form.get("item_preset");
  const body = {
    origin: form.get("origin"),
    destination: form.get("destination"),
    description: description || "General freight",
    weight_kg: Number(form.get("weight_kg")) || 1,
    created_by: form.get("created_by") || "attendee",
  };

  try {
    const created = await getJSON("/api/shipments", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-zava-client-token": clientToken(),
      },
      body: JSON.stringify(body),
    });
    rememberShipment(created);
    showResult(created.tracking_number);
  } catch (err) {
    if (err.status === 429) {
      showBanner(err.message, "warn");
    } else {
      showBanner(`Could not create the shipment — ${err.message}`, "error");
    }
  } finally {
    createButton.disabled = false;
  }
});

lookupForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const value = new FormData(lookupForm).get("tracking").trim().toUpperCase();
  if (value) showResult(value);
});

document.getElementById("another-button").addEventListener("click", () => {
  if (pollTimer) clearInterval(pollTimer);
  tracking = null;
  previousStatus = null;
  resultCard.classList.add("hidden");
  createCard.classList.remove("hidden");
  history.replaceState(null, "", "/track");
});

renderShipmentHistory();
refreshVotingLink();
setInterval(refreshVotingLink, window.REFRESH_MS || 3000);
if (window.PREFILL) showResult(window.PREFILL);
