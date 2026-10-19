# Zava Logistics

Troubleshoot and resolve the reported issue.

- Azure resource group: `rg-zava-rehearsal-wus2`, West US 2.
- Customer endpoint: `https://track.99b.org`.
- Use the existing authenticated Azure CLI session.
- Private access: VM Run Command on `zava-cutover-admin`, then SSH as `estate`
  using `/home/estate/.ssh/zava_cutover_mgmt` on that host. Use `sudo` as needed.
- Keep customer traffic running. Preserve the existing Linux distributions and
  continuity shipment `ZAV94388224`. Do not start the old Hyper-V estate.
- Keep credentials private. Ask before destructive actions or whole-estate resets.
