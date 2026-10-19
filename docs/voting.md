# Audience voting

- Presenter controls: `https://dash.99b.org/voting`.
- Audience voting: `https://track.99b.org/vote`.
- Projected voting screen: `https://dash.99b.org/?view=network`.

Enter the existing presenter key and click **Save key**. The page verifies it,
then stores it in localStorage under `zava-presenter-key` and restores it after
reload. **Forget key** removes it and locks the controls. Save only on a trusted
device: scripts running on this origin can read localStorage. Storage is
separate for `dash.99b.org` and `track.99b.org`. The key is never included in URLs
or deployed source. An invalid key is rejected rather than saved.

**Open voting** creates a poll. **Close voting** locks it and reveals the winner;
neither action injects a fault. Fault injection remains a separate private
operation: after closing, click **Inject winning fault**. It queues exactly one
request for that locked poll; it does not send commands or Azure/SSH credentials
to the web server. Opening another poll creates a fresh vote, not a continuation of the
previous tally. Open voting is disabled while a poll is open or a fault is active.

## Private fault runner

Apply `db\08-private-fault-runner.sql` after the existing database migrations.
On the private presenter workstation, with an authenticated Azure CLI session,
run:

```powershell
.\tools\faults\Start-ZavaFaultRunner.ps1
```

It reads `$HOME\.zava\presenter.key` without displaying it, polls outbound over
HTTPS, and invokes the existing allowlisted private controller. The management
SSH key stays on the administration VM. The page shows whether the runner is
online and whether injection is queued, running, successful, or failed.
Keep the runner and workstation running during the demo; Azure VM Run Command
can take time. No inbound workstation port or public management endpoint is used.

Requests require presenter authentication, the latest poll must be locked,
and an online runner is required. Duplicate clicks do not create another job.
Unclaimed requests expire after 30 seconds. Claimed jobs are never automatically
replayed, including after a runner crash. New voting is blocked while an
injection or unresolved failure is pending. A failed injector may have partially
changed the estate: inspect the private log and use the corresponding reviewed
repair, not a blind retry. If a repair completes after the injector failed before
recording the poll as injected, explicitly resolve the poll lifecycle only after
confirming recovery.

Normal rehearsal reset does not require snapshots. The reviewed repairs resume
the worker, remove the fault-specific packet-loss rules, or restore the original
claim procedure. Confirm sustained recovery, then open fresh voting. Snapshots
remain a separate full-estate recovery safeguard.

While voting is open, the projected screen shows a locally served QR code and
readable voting URL, and the tracking page shows a **Vote now** link. Vote counts
per choice remain hidden until voting locks.

The tracking page's **Clear history** button removes only this browser's saved
shipment list. It does not delete SQL shipments or reset the browser's voter token.

The voting UI must be deployed before refreshing the web baseline snapshot.
Snapshot capture is a separate operation, not part of a UI deployment.

Focused UI regressions: `python tools/test-voting-ui.py`. Test-only dependencies
are `playwright`, `zxing-cpp`, and `Pillow`, plus the existing Jinja2 dependency.
The tests use installed Edge on Windows; on Linux run
`python -m playwright install chromium` first. All API mutations are mocked.
