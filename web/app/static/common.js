/* Shared front-end helpers for the dashboard and tracking pages. */

const banner = document.getElementById("banner");

/** Show a persistent banner. Level is "error" or "warn". */
function showBanner(message, level) {
  if (!banner) return;
  banner.textContent = message;
  banner.classList.remove("hidden");
  banner.classList.toggle("warn", level === "warn");
}

function clearBanner() {
  if (!banner) return;
  banner.classList.add("hidden");
}

/**
 * Fetch JSON and turn every failure into a thrown Error carrying the server's
 * own explanation. The demo depends on being able to say out loud *why* a tier
 * is unreachable, so upstream detail is never swallowed.
 */
async function getJSON(url, options) {
  const response = await fetch(url, options);
  let payload = null;
  try {
    payload = await response.json();
  } catch (err) {
    payload = null;
  }
  if (!response.ok) {
    const detail = payload && (payload.detail || payload.message || payload.error);
    const error = new Error(describeDetail(detail) || `HTTP ${response.status}`);
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

function describeDetail(detail) {
  if (!detail) return "";
  if (typeof detail === "string") return detail;
  if (detail.message) {
    return detail.target ? `${detail.message} (${detail.target})` : detail.message;
  }
  return JSON.stringify(detail);
}

function escapeHTML(value) {
  return String(value == null ? "" : value).replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[ch]));
}

function relativeTime(iso) {
  if (!iso) return "never";
  const seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (seconds < 60) return `${Math.round(seconds)}s ago`;
  if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`;
  return `${Math.round(seconds / 3600)}h ago`;
}

function platformClass(platform) {
  return String(platform || "unknown").toLowerCase().replace(/[^a-z0-9]+/g, "-");
}
