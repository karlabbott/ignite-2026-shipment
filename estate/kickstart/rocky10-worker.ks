# Kickstart — rocky-worker (Rocky Linux 10)
#
# Worker tier for NinetyNine Freight. Consumes the scan queue and advances
# shipments through the pipeline.
#
# Unlike rhel-db, this VM DOES get a serial console. That is deliberate: the
# demo needs at least one machine you can actually see boot in Azure, so the
# audience learns the difference between "broken and diagnosable" and "broken
# and silent". Divergences are marked DIVERGENCE.
#
# Delivery: ISO labelled OEMDRV containing this file as ks.cfg.

text
eula --agreed
firstboot --disable
reboot --eject

keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
timezone America/Los_Angeles --utc

# DIVERGENCE 1: static addressing on the lab subnet.
network --bootproto=static --ip=192.168.90.14 --netmask=255.255.255.0 \
        --gateway=192.168.90.1 --nameserver=1.1.1.1,8.8.8.8 \
        --device=eth0 --activate --hostname=rocky-worker.99b.local

rootpw --lock
user --name=estate --groups=wheel --gecos="Estate admin" --iscrypted \
     --password=!!PASSWORD_HASH!!
sshkey --username=estate "!!SSH_PUBKEY!!"

firewall --enabled --service=ssh
selinux --enforcing
services --enabled="sshd,chronyd,firewalld"

# ---------------------------------------------------------------- storage ---
# Plain layout, no LVM. This machine migrates cleanly, which matters: if all
# four VMs break, the audience concludes migration never works. One clean
# machine makes the three failures credible.
ignoredisk --only-use=sda
clearpart --all --initlabel --drives=sda
part /boot/efi --fstype=efi --size=600 --fsoptions="umask=0077,shortname=winnt"
part /boot     --fstype=xfs --size=1024
part swap      --fstype=swap --size=2048
part /         --fstype=xfs --size=1 --grow

# Serial console IS configured here -- see the note at the top of this file.
bootloader --location=mbr --timeout=5 --boot-drive=sda \
           --append="console=tty0 console=ttyS0,115200n8 earlyprintk=ttyS0,115200"

%packages --ignoremissing
@^minimal-environment
openssh-server
chrony
curl
tar
python3
python3-pip
gcc
python3-devel
-cockpit
%end

%post --log=/root/ks-post.log
set -x

# DIVERGENCE 2: no WALinuxAgent. Even though this VM boots fine in Azure, it
# arrives with no extensions, no Run Command and no boot diagnostics until the
# agent is installed. "It booted" is not the same as "it is manageable".
# cloud-init is intentionally absent as well.

# fstab is left UUID-based here on purpose. Compare with rhel-db.
cp /etc/fstab /root/fstab.as-built

systemctl enable serial-getty@ttyS0.service || true

echo 'estate ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/estate
chmod 0440 /etc/sudoers.d/estate

cat >> /etc/hosts <<'HOSTS'
192.168.90.11   rhel-db.99b.local       rhel-db
192.168.90.12   sles-api.99b.local      sles-api
192.168.90.13   ubuntu-web.99b.local    ubuntu-web
192.168.90.14   rocky-worker.99b.local  rocky-worker
HOSTS

{
    echo "built:    $(date -Is)"
    echo "distro:   $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "kernel:   $(uname -r)"
    echo "tier:     worker"
    echo "walinuxagent: absent (deliberate)"
    echo "cloud-init:   absent (deliberate)"
    echo "fstab:        UUID (clean - this VM should migrate without drama)"
    echo "serial console: enabled (deliberate contrast with rhel-db)"
} > /etc/estate-baseline

%end
