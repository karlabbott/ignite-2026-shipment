# Kickstart — rhel-db (Red Hat Enterprise Linux 10)
#
# Database tier for NinetyNine Freight. Hosts SQL Server 2025 on Linux.
#
# READ THIS BEFORE "FIXING" ANYTHING BELOW.
# This machine is deliberately built the way a long-lived on-premises VM
# actually looks, which means it is wrong for Azure in several specific ways.
# Those divergences are the demo. Each one is marked DIVERGENCE.
#
# Delivery: build an ISO labelled OEMDRV containing this file as ks.cfg and
# attach it as a second DVD drive. Anaconda finds it with no boot arguments.
# See estate/build-answer-isos.sh.

text
eula --agreed
firstboot --disable
reboot --eject

keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
timezone America/Los_Angeles --utc

# DIVERGENCE 1: static addressing, no cloud-init, no DHCP.
# A migrated VM keeps this config and comes up on Azure unreachable, because
# 192.168.90.11 does not exist in the target VNet.
network --bootproto=static --ip=192.168.90.11 --netmask=255.255.255.0 --gateway=192.168.90.1 --nameserver=!!DNS_SERVERS!! --device=eth0 --activate --hostname=rhel-db.99b.local

# Root is locked; all access is by key as the estate admin.
rootpw --lock
user --name=estate --groups=wheel --gecos="Estate admin" --iscrypted \
     --password=!!PASSWORD_HASH!!
sshkey --username=estate "!!SSH_PUBKEY!!"

# The RHEL boot ISO deliberately has no package payload. Register before
# package selection so Anaconda uses Red Hat CDN through the lab NAT. These
# values are injected only into the generated OEMDRV ISO at build time.
rhsm --organization="!!RHSM_ORGANIZATION!!" --activation-key="!!RHSM_ACTIVATION_KEY!!"

# DIVERGENCE 2: firewalld active with a hand-carved rule set that assumes the
# 192.168.90.0/24 lab subnet. Post-migration this blocks the real API tier.
firewall --enabled --service=ssh
selinux --enforcing
services --enabled="sshd,chronyd,firewalld"

# ---------------------------------------------------------------- storage ---
# DIVERGENCE 3: an LVM layout with a separate /var/opt/mssql volume, sized by
# hand years ago. Azure Migrate carries it faithfully; generalization and
# resize behaviour get interesting.
ignoredisk --only-use=sda
clearpart --all --initlabel --drives=sda
part /boot/efi --fstype=efi --size=600 --fsoptions="umask=0077,shortname=winnt"
part /boot     --fstype=xfs --size=1024
part pv.01     --fstype=lvmpv --size=1 --grow
volgroup vg_db pv.01
logvol /              --vgname=vg_db --name=lv_root  --fstype=xfs --size=12288
logvol swap           --vgname=vg_db --name=lv_swap  --fstype=swap --size=4096
logvol /var           --vgname=vg_db --name=lv_var   --fstype=xfs --size=8192
logvol /var/opt/mssql --vgname=vg_db --name=lv_mssql --fstype=xfs --size=1 --grow

# DIVERGENCE 4: BIOS-style bootloader timeout and, deliberately, NO serial
# console. When this VM fails to boot in Azure there is no console output to
# read, which is exactly the wall you hit in the real migration.
bootloader --location=mbr --timeout=5 --boot-drive=sda

%packages --ignoremissing
@^minimal-environment
openssh-server
chrony
curl
tar
policycoreutils-python-utils
python3
# Note: cloud-init and WALinuxAgent are NOT installed. See DIVERGENCE 5.
-cloud-init
-cockpit
%end

%post --log=/root/ks-post.log
set -x

# ---------------------------------------------------------------------------
# DIVERGENCE 5: no WALinuxAgent, no cloud-init.
# This is the single most important divergence in the whole lab. Without the
# agent the migrated VM has no boot diagnostics, no serial console, no VM
# extensions, no password reset and no Run Command. Copilot has to fix it from
# a rescue VM with the OS disk attached.
# ---------------------------------------------------------------------------

# DIVERGENCE 6: rewrite fstab to device names instead of UUIDs.
# On Hyper-V, sda is always sda. In Azure the disk controller and enumeration
# order change, so device-name mounts send the boot into an emergency shell.
# Everything except the LVM volumes is repointed at a raw device path.
python3 - <<'PY'
import re

with open("/etc/fstab") as handle:
    lines = handle.readlines()

resolved = []
for line in lines:
    match = re.match(r"^UUID=(\S+)\s+(\S+)\s+(.*)$", line)
    if not match:
        resolved.append(line)
        continue
    uuid, mount, rest = match.groups()
    # Map the UUID back to whatever /dev/sdXN it happens to be today.
    import subprocess
    try:
        device = subprocess.check_output(
            ["blkid", "-U", uuid], text=True).strip()
    except subprocess.CalledProcessError:
        resolved.append(line)
        continue
    resolved.append(f"{device}\t{mount}\t{rest}\n")

with open("/etc/fstab", "w") as handle:
    handle.writelines(resolved)
PY

cp /etc/fstab /root/fstab.as-built

# DIVERGENCE 7: strip the serial console from the kernel command line if the
# installer added one, and disable the serial getty. No console on stage.
if [ -f /etc/default/grub ]; then
    sed -i 's/console=ttyS0[^ "]*//g' /etc/default/grub
    sed -i 's/  */ /g' /etc/default/grub
    grub2-mkconfig -o /boot/grub2/grub.cfg || true
    if [ -d /boot/efi/EFI/redhat ]; then
        grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg || true
    fi
fi
systemctl mask serial-getty@ttyS0.service || true

# Passwordless sudo for the estate account so Copilot can drive remediation.
echo 'estate ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/estate
chmod 0440 /etc/sudoers.d/estate

# Hosts file pinned to the lab subnet -- another thing that is silently wrong
# the moment these machines land in Azure with new addresses.
cat >> /etc/hosts <<'HOSTS'
192.168.90.11   rhel-db.99b.local       rhel-db
192.168.90.12   sles-api.99b.local      sles-api
192.168.90.13   ubuntu-web.99b.local    ubuntu-web
192.168.90.14   rocky-worker.99b.local  rocky-worker
HOSTS

# Record the as-built state so the baseline is provable later.
{
    echo "built:    $(date -Is)"
    echo "distro:   $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "kernel:   $(uname -r)"
    echo "tier:     db"
    echo "walinuxagent: absent (deliberate)"
    echo "cloud-init:   absent (deliberate)"
    echo "fstab:        device names (deliberate)"
    echo "serial console: disabled (deliberate)"
} > /etc/estate-baseline

%end
