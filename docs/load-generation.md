# Stage traffic generation

The sustained rehearsal generator runs on **`sles-api` (`192.168.90.12`)** as
`zava-loadgen-24.service`. It does not run on `zava-cutover-admin`; that VM is
only the private SSH control hop.

Run the control commands from the authenticated Windows operator shell. The
private management key remains on `zava-cutover-admin`.

## Start the 24 shipments/minute stream

From `zava-cutover-admin`, SSH to `sles-api` and create the transient unit:

```bash
sudo -u estate ssh \
  -i /home/estate/.ssh/zava_cutover_mgmt \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  estate@192.168.90.12 \
  "sudo systemd-run \
    --unit=zava-loadgen-24 \
    --collect \
    --property=Type=exec \
    --property=WorkingDirectory=/opt/shipment \
    --uid=shipment \
    --gid=shipment \
    /bin/bash -c \
    'set -a; . /etc/shipment/shipment.env; set +a; exec /opt/shipment/venv/bin/python -u /opt/shipment/tools/loadgen.py --web http://127.0.0.1:8080 --rate 24 --advance 0'"
```

The environment must be sourced inside the service command so the generator
sends `x-zava-loadgen-key`. Without it, audience rate limiting makes the load
test invalid.

Verify on `sles-api`:

```bash
systemctl show zava-loadgen-24.service --property ActiveState,SubState
journalctl -u zava-loadgen-24.service --since -2min --no-pager
pgrep -af '[l]oadgen.py'
```

## Stop the stream

Run on `sles-api`:

```bash
sudo systemctl stop zava-loadgen-24.service
test "$(systemctl is-active zava-loadgen-24.service || true)" = inactive
! pgrep -af '[l]oadgen.py'
```

Stopping the generator prevents new synthetic shipments. Workers continue
processing work already present in `scan_queue`.

## Local foreground tool

`tools/Start-ZavaTraffic.ps1` is a separate foreground operator tool. It runs
where PowerShell is invoked and is useful for short tests; it is not the
rehearsal service described above.
