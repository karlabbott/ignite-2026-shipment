/* Infrastructure commands run only on the private, outbound-polling runner. */

const presenterKey = document.getElementById("presenter-key");
const openVoting = document.getElementById("open-voting");
const closeVoting = document.getElementById("close-voting");
const injectFault = document.getElementById("inject-fault");
const injectionStatus = document.getElementById("injection-status");
let presenterPoll = null;
let presenterInjection = null;
let changingPoll = false;
let pollRequest = 0;
let pollReadFailed = false;

function updateVotingControls() {
  const hasKey = Boolean(presenterKey.value.trim());
  const state = presenterPoll && presenterPoll.state;
  const unresolved = presenterInjection &&
    ["queued", "running", "failed"].includes(presenterInjection.state) &&
    !["recovered", "closed"].includes(state);
  openVoting.disabled = changingPoll || !hasKey || !presenterPoll ||
    state === "open" || state === "injected" || unresolved;
  closeVoting.disabled = changingPoll || !hasKey || state !== "open";
  injectFault.disabled = changingPoll || !hasKey || state !== "locked" ||
    !presenterPoll.winner_code || !presenterInjection ||
    !presenterInjection.runner_online || Boolean(presenterInjection.state);
}

function renderInjectionStatus(injection) {
  presenterInjection = injection;
  injectionStatus.textContent = {
    queued: "Fault requested. Waiting for the private runner.",
    running: injection.runner_online
      ? "Private runner is injecting the winning fault."
      : "Injection was claimed, but the runner is offline. Inspect its log; do not retry blindly.",
    succeeded: "Winning fault injected. Use the reviewed private repair after troubleshooting.",
    failed: "Injection failed or expired. A partial fault may remain. Inspect the private runner log before continuing.",
  }[injection.state] || (injection.runner_online
    ? "Private runner online. Close voting to select a fault, then explicitly inject it."
    : "Private runner offline. Injection is unavailable.");
  updateVotingControls();
}

function renderPresenterPoll(poll) {
  presenterPoll = poll;
  document.getElementById("presenter-poll-state").textContent = {
    open: "Voting open",
    locked: "Voting closed",
    injected: "Fault active",
    recovered: "Service recovered",
    closed: "No open voting",
  }[poll.state] || poll.state;
  document.getElementById("presenter-poll-count").textContent = poll.poll_id
    ? `Poll ${poll.poll_id} - ${poll.total_votes} vote${poll.total_votes === 1 ? "" : "s"}`
    : "Ready to open a poll";
  const winner = poll.state !== "open" && poll.choices.find(
    (choice) => choice.code === poll.winner_code,
  );
  document.getElementById("presenter-poll-winner").textContent = winner
    ? `Selected: ${winner.label}` : "";
  updateVotingControls();
}

async function refreshPresenterPoll() {
  if (changingPoll) return;
  const request = ++pollRequest;
  try {
    const poll = await getJSON("/api/poll");
    if (request !== pollRequest) return;
    if (!presenterPoll || presenterPoll.poll_id !== poll.poll_id) presenterInjection = null;
    renderPresenterPoll(poll);
    if (pollReadFailed) clearBanner();
    pollReadFailed = false;
    const key = presenterKey.value.trim();
    if (!key) {
      injectionStatus.textContent = "Enter your presenter key to check the private runner.";
      return;
    }
    try {
      const injection = await getJSON(
        `/api/presenter/polls/${poll.poll_id || 0}/injection`,
        {headers: {"x-zava-presenter-key": key}},
      );
      if (request !== pollRequest || key !== presenterKey.value.trim()) return;
      renderInjectionStatus(injection);
    } catch (err) {
      if (request !== pollRequest || key !== presenterKey.value.trim()) return;
      presenterInjection = null;
      updateVotingControls();
      injectionStatus.textContent = `Could not check the private runner - ${err.message}`;
    }
  } catch (err) {
    if (request !== pollRequest) return;
    presenterPoll = null;
    pollReadFailed = true;
    updateVotingControls();
    showBanner(`Could not read voting status - ${err.message}`, "error");
  }
}

async function changeVoting(action) {
  if (changingPoll || !presenterKey.value.trim() || !presenterPoll) return;
  if (action === "lock" && presenterPoll.state !== "open") return;
  if (action === "open" && ["open", "injected"].includes(presenterPoll.state)) return;
  if (action === "inject" && injectFault.disabled) return;
  const path = action === "open"
    ? "/api/presenter/polls"
    : `/api/presenter/polls/${presenterPoll.poll_id}/${action}`;
  changingPoll = true;
  ++pollRequest;
  updateVotingControls();
  try {
    const poll = await getJSON(path, {
      method: "POST",
      headers: {"x-zava-presenter-key": presenterKey.value.trim()},
    });
    if (action === "inject") renderInjectionStatus(poll);
    else {
      presenterInjection = null;
      renderPresenterPoll(poll);
    }
    clearBanner();
  } catch (err) {
    const operation = {open: "open voting", lock: "close voting", inject: "request fault injection"}[action];
    showBanner(`Could not ${operation} - ${err.message}`, "error");
  } finally {
    changingPoll = false;
    updateVotingControls();
  }
}

presenterKey.addEventListener("input", () => {
  presenterInjection = null;
  ++pollRequest;
  updateVotingControls();
  refreshPresenterPoll();
});
openVoting.addEventListener("click", () => changeVoting("open"));
closeVoting.addEventListener("click", () => changeVoting("lock"));
injectFault.addEventListener("click", () => changeVoting("inject"));
refreshPresenterPoll();
setInterval(refreshPresenterPoll, window.REFRESH_MS || 3000);
