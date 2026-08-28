# Kickstart - rocky-worker (RLC+ 10)
#
# Worker tier for NinetyNine Freight. This VM deliberately gets a serial
# console and keeps UUID-based mounts so at least one tier migrates cleanly.
#
# Delivery: ISO labelled OEMDRV containing this file as ks.cfg.

text
eula --agreed
firstboot --disable
reboot --eject

keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
timezone America/Los_Angeles --utc

network --bootproto=static --ip=192.168.90.14 --netmask=255.255.255.0 \
        --gateway=192.168.90.1 --nameserver=!!DNS_SERVERS!! \
        --device=eth0 --activate --hostname=rocky-worker.99b.local

rootpw --lock
user --name=estate --groups=wheel --gecos="Estate admin" --iscrypted \
     --password=!!PASSWORD_HASH!!
sshkey --username=estate "!!SSH_PUBKEY!!"

firewall --enabled --service=ssh
selinux --enforcing
services --enabled="sshd,chronyd,firewalld"

ignoredisk --only-use=sda
clearpart --all --initlabel --drives=sda
part /boot/efi --fstype=efi --size=600 --fsoptions="umask=0077,shortname=winnt"
part /boot     --fstype=ext4 --size=1024
part swap      --fstype=swap --size=2048
part /         --fstype=xfs --size=1 --grow

bootloader --location=mbr --timeout=5 --boot-drive=sda --append="console=tty0 console=ttyS0,115200n8 earlyprintk=ttyS0,115200"

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
policycoreutils-python-utils
efibootmgr
grub2-efi-x64
grub2-efi-x64-modules
grub2-tools
grub2-tools-efi
shim-x64
-cloud-init
-cockpit
%end

%post --log=/root/ks-post.log
set -x

echo 'estate ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/estate
chmod 0440 /etc/sudoers.d/estate

cat >> /etc/hosts <<'HOSTS'
192.168.90.11   rhel-db.99b.local       rhel-db
192.168.90.12   sles-api.99b.local      sles-api
192.168.90.13   ubuntu-web.99b.local    ubuntu-web
192.168.90.14   rocky-worker.99b.local  rocky-worker
HOSTS

cp /etc/fstab /root/fstab.as-built
grub2-mkconfig -o /boot/grub2/grub.cfg
systemctl enable serial-getty@ttyS0.service || true

{
    echo "built:    $(date -Is)"
    echo "distro:   $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "kernel:   $(uname -r)"
    echo "tier:     worker"
    echo "source:   RLC+ 10 installer ISO"
    echo "walinuxagent: absent (deliberate)"
    echo "cloud-init:   absent (deliberate)"
    echo "fstab:        UUID (clean - this VM should migrate without drama)"
    echo "serial console: enabled (deliberate contrast with rhel-db)"
} > /etc/estate-baseline

%end

# Preserve the CIQ customizations included by the vendor's own ISO Kickstart.
%include /usr/share/anaconda/post-scripts/50-ciq-install-depot.ks
%include /usr/share/anaconda/post-scripts/50-ciq-login-banner.ks
