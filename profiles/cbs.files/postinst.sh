#!/bin/bash
# this is the post-install script
# the newly-installed system is not yet booted, but chrooted at the moment of execution

set -x

VERSION=1.0

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# XXX needed for handling around reloc_domain

# Preset vlan for standard interface
# To change, set the value in postinst.conf
vlan_no=""

if [ -f postinst.conf ]; then
 . postinst.conf
fi

if [ "$1" = "real" ]; then
 target=""
else # prepare test environment
 if [ `id -u` -eq 0 ]; then
   echo "Please don't run test mode as root, because it can modify your system accidentally!"
   exit 1
 fi
 rm -rf target
 cp -a target-orig target
 target=target
 mkdir -p $target/etc/xen $target/usr/sbin $target/usr/share/ganeti $target/usr/lib/xen $target/usr/local/sbin
fi

cp -a real/* .

mkdir -p backup
for i in \
 /etc/network/interfaces \
 /etc/hosts \
 /etc/hostname \
 /etc/default/puppet \
 /etc/rsyslog.conf \
 /etc/dhcp/dhclient.conf
do
 cp $target/$i backup
done

## Set /var/log/kern.log to unbuffered mode

./strreplace.sh $target/etc/rsyslog.conf "^kern\.\*[\t ]+-\/var\/log\/kern.log" 'kern.*\t\t\t\t/var/log/kern.log'

## Assign supersede parameters for node's dhcp
dns=`grep nameserver $target/etc/resolv.conf|awk '{print $2; exit}'\;`
./strreplace.sh $target/etc/dhcp/dhclient.conf "^#supersede domain-name" "supersede domain-name $domain\;\nsupersede domain-name-servers $dns\;"

## Enable smartd to start

./strreplace.sh $target/etc/default/smartmontools "^#start_smartd=yes" "start_smartd=yes"

## Tune temperature warning on smartd

./strreplace.sh $target/etc/smartd.conf "^DEVICESCAN" "DEVICESCAN -d removable -n standby -m root -R 194 -R 231 -I 9 -W 5,50,55 -M exec /usr/share/smartmontools/smartd-runner"

## Remove /media/usb0 mountpoint from fstab as we using usbmount helper

sed -i '/\/media\/usb0/d' $target/etc/fstab

## Add flush option for USB-flash mounted with vfat

./strreplace.sh $target/etc/usbmount/usbmount.conf "^FS_MOUNTOPTIONS" 'FS_MOUNTOPTIONS="-fstype=vfat,flush"'

## Set localized console and keyboard

cp files/default/* $target/etc/default/

## Copy chrony config

cp files/chrony.conf $target/etc/chrony

## Copy sci-puppet modules

cp -r files/root/puppet/modules $target/etc/puppet/
cp -r files/root/puppet/manifests $target/etc/puppet/
cp -r files/root/*pp $target/etc/puppet/

## Allow plugins and facts syncing for puppet
echo Editing puppet.conf
sed -i '/\[main\]/ a\pluginsync = true' $target/etc/puppet/puppet.conf

## Add startup script rc.cbs to setup performance

# a bit ugly, but fast ;)
cat <<EOF >$target/etc/rc.local
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.

if [ -f /etc/rc.cbs ]; then
  . /etc/rc.cbs
fi

exit 0
EOF
chmod +x $target/etc/rc.local


## Tune storage scheduler for better disk latency
cat <<EOFF >$target/etc/rc.cbs
#!/bin/sh
# On-boot configuration for hardware for better cluster performance
# mostly http://code.google.com/p/ganeti/wiki/PerformanceTuning

modprobe sg
disks=\`sg_map -i|awk '{if(\$3=="ATA"){print substr(\$2, length(\$2))}}'\`
for i in \$disks; do
  # Set value if you want to use read-ahead
  ra="$read_ahead"
  if [ -n "\$ra" ]; then
    blockdev --setra \$ra /dev/sd\$i
  fi
  if grep -q sd\$i /etc/sysfs.conf; then
    echo sd\$i already configured in /etc/sysfs.conf
  else
 cat <<EOF >>/etc/sysfs.conf
block/sd\$i/queue/scheduler = deadline
block/sd\$i/queue/iosched/front_merges = 0
block/sd\$i/queue/iosched/read_expire = 150
block/sd\$i/queue/iosched/write_expire = 1500
EOF
  fi
done
/etc/init.d/sysfsutils restart
EOFF
chmod +x $target/etc/rc.cbs

## Add tcp buffers tuning for drbd
## Tune disk system to avoid (or reduce?) deadlocks
cat <<EOF >$target/etc/sysctl.d/cbs.conf
# Increase "minimum" (and default) 
# tcp buffer to increase the chance to make progress in IO via tcp, 
# even under memory pressure. 
# These numbers need to be confirmed - probably a bad example.
#net.ipv4.tcp_rmem = 131072 131072 10485760 
#net.ipv4.tcp_wmem = 131072 131072 10485760 

# add disk tuning options to avoid (or reduce?) deadlocks
# gives better latency on heavy load
vm.swappiness = 0
vm.overcommit_memory = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_expire_centisecs = 1000
EOF

# Mount /home if we detect unmounted cbs/home
grep -q /home /proc/mounts || test -b $target/dev/cbs/home && test -d $target/home && grep -q /home $target/etc/fstab && mount $target/home

# Place commented-out template for /cbs if no one
grep -q /home $target/etc/fstab || echo "#/dev/cbs/home /home ext4 errors=remount-ro 0 0" >>$target/etc/fstab

## Set up CD-ROM repository: create /media/cbs

echo Setting up local CD-ROM repository
mkdir -p $target/media/cbs

cat <<EOF >>$target/etc/apt/apt.conf.d/99-cbs
Acquire::cdrom::mount "/media/cbs";
APT::CDROM::NoMount;
EOF

## Copy-in cbs iso image to /home/cbs.iso, mount to /media/cbs, set up sources.list

# when installing from USB stick, two /cdrom mounts are shown
# XXX 'head -1' may be a wrong choice here, but will not differ them at present
dev=`grep '/cdrom' /proc/mounts|head -1|cut -d' ' -f1`

if [ -n "$dev" -a -e "$dev" ]; then
	echo ...Copying CD-ROM image
	dd if=$dev of=$target/home/cbs.iso

	echo "/home/cbs.iso /media/cbs iso9660 loop 0 1" >>$target/etc/fstab

	echo ...Adding repository data
	mount /media/cbs && (apt-cdrom -d=/media/cbs add; umount /media/cbs)
else
	echo Unable to find CD-ROM device
	echo "#/home/cbs.iso /media/cbs iso9660 loop 0 1" >>$target/etc/fstab
fi

## set cbs apt sources
cp files/apt/sci-dev.list $target/etc/apt/sources.list.d
cp files/apt/apt.pub $target/etc/apt
echo "deb http://mirror.yandex.ru/debian/ wheezy main" >> $target/etc/apt/sources.list
echo "deb http://mirror.yandex.ru/debian-security/ wheezy/updates main" >> $target/etc/apt/sources.list
echo "deb http://mirror.yandex.ru/debian/ wheezy-backports main" >> $target/etc/apt/sources.list
apt-key add /etc/apt/apt.pub

## Add cbs deploing scripts

cp files/sbin/* $target/usr/local/sbin/

# Write motd
cat <<EOF >$target/etc/motd

Debian-CBS, ver. $VERSION
For more information see http://github.com/vladimir-ipatov/cbs

EOF

## Filling cbs configuration template

mkdir $target/etc/sci
touch $target/etc/sci/sci.conf

mkdir $target/etc/cbs
cat <<EOF >$target/etc/cbs/cbs.conf
# This is the SCI-CD cluster setup parameters
# Fill the values and execute "sci-setup cluster"

# The hostname to represent the cluster (without a domain part).
# It MUST be different from any node's hostnames
CLUSTER_NAME=gnt

# The IP address corresponding to CLUSTER_NAME.
# It MUST be different from any node's IP.
# You should not up this IP address manualy - it will be automatically
# activated as an interface alias on the current master node
# We suggest to assign this address in the LAN (if LAN segment is present)
CLUSTER_IP=

# The first (master) node data
NODE1_NAME=$hostname
NODE1_IP=$ipaddr

# Optional separate IP for SAN (should be configured and up;
# ganeti node will be configured with -s option)
NODE1_SAN_IP=
# Optional separate IP for LAN (should be configured and up)
NODE1_LAN_IP=

# Optional additional IP for virtual service machine "sci" in the LAN segment.
# If NODE1_LAN_IP is set, then you probably wish to set this too.
# (you should not to pre-configure this IP on the node)
SCI_LAN_IP=
# Optional parameters if NODE1_LAN_IP not configured
# If not set, it will be omited in instance's interface config
SCI_LAN_NETMASK=
SCI_LAN_GATEWAY=

# The second node data
# If you skip it, then the cluster will be set up in non redundant mode
NODE2_NAME=
NODE2_IP=
NODE2_SAN_IP=
NODE2_LAN_IP=

# Network interface for CLUSTER_IP
# (if set, this interface will be passed to "gnt-cluser init --master-netdev")
# Autodetect if NODE1_LAN_IP is set and CLUSTER_IP matches LAN network
MASTER_NETDEV=
MASTER_NETMASK=

# Network interface to bind to virtual machies by default
# (if set, this interface will be passed to
# "gnt-cluster init --nic-parameters link=")
# Autodetect if NODE1_LAN_IP or MASTER_NETDEV are set
LAN_NETDEV=

# reserved volume names are ignored by Ganety and may be used for any needs
# (comma separated)
RESERVED_VOLS="xenvg/system-.*"

# sources for approx apt cache server on sci
# all two together must be non empty, or nonexistent
APT_DEBIAN="debian http://ftp.debian.org/debian/"
APT_SECURITY="security http://security.debian.org/"

# forwarders for DNS server on sci
# use syntax "1.2.3.4; 1.2.3.4;"
DNS_FORWARDERS=""

EOF

# Write installed version information
echo $VERSION >$target/etc/cbs/cbs.version
