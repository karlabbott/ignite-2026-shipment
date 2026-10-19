/* Presenter controls only open/lock SQL-backed polls; they never inject faults. */

const presenterKey = document.getElementById("presenter-key");
const openVoting = document.getElementById("open-voting");
const closeVoting = document.getElementById("close-voting");
let presenterPoll = null;
let changingPoll = false;
let pollRequest = 0;
let pollReadFailed = false;

function updateVotingControls() {
  const hasKey = Boolean(presenterKey.value.trim());
  const state = presenterPoll && presenterPoll.state;
  openVoting.disabled = changingPoll || !hasKey || !presenterPoll ||
    state === "open" || state === "injected";
  closeVoting.disabled = changingPoll || !hasKey || state !== "open";
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
    renderPresenterPoll(poll);
    if (pollReadFailed) clearBanner();
    pollReadFailed = false;
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
  const path = action === "open"
    ? "/api/presenter/polls"
    : `/api/presenter/polls/${presenterPoll.poll_id}/lock`;
  changingPoll = true;
  ++pollRequest;
  updateVotingControls();
  try {
    const poll = await getJSON(path, {
      method: "POST",
      headers: {"x-zava-presenter-key": presenterKey.value.trim()},
    });
    renderPresenterPoll(poll);
    clearBanner();
  } catch (err) {
    showBanner(`Could not ${action === "open" ? "open" : "close"} voting - ${err.message}`, "error");
  } finally {
    changingPoll = false;
    updateVotingControls();
  }
}

presenterKey.addEventListener("input", updateVotingControls);
openVoting.addEventListener("click", () => changeVoting("open"));
closeVoting.addEventListener("click", () => changeVoting("lock"));
refreshPresenterPoll();
setInterval(refreshPresenterPoll, window.REFRESH_MS || 3000);
