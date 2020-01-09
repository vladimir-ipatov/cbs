#!/bin/bash
# this is the post-install script
# the newly-installed system is not yet booted, but chrooted at the moment of execution

set -x

VERSION=3.0

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# XXX needed for handling around reloc_domain

# Preset vlan for standard interface
# To change, set the value in postinst.conf
vlan_no=""

if [ -f postinst.conf ]; then
 . postinst.conf
fi

## mount proc and sys, mknod for loop
mount -t proc proc /proc
mount -t sysfs sys /sys
mknod /dev/loop0 b 7 0

## Set PermitRoolLogin=yes in ssd_config
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' $TARGET/etc/ssh/sshd_config

## Set /var/log/kern.log to unbuffered mode

./strreplace.sh $target/etc/rsyslog.conf "^kern\.\*[\t ]+-\/var\/log\/kern.log" 'kern.*\t\t\t\t/var/log/kern.log'

## Enable puppet to start

echo Setting up defaults
./strreplace.sh $target/etc/default/puppet "^START=" "START=yes"

## Enable smartd to start

./strreplace.sh $target/etc/default/smartmontools "^#start_smartd=yes" "start_smartd=yes"

## Tune temperature warning on smartd

./strreplace.sh $target/etc/smartd.conf "^DEVICESCAN" "DEVICESCAN -d removable -n standby -m root -R 194 -R 231 -I 9 -W 5,50,55 -M exec /usr/share/smartmontools/smartd-runner"

## Remove /media/usb0 mountpoint from fstab as we using usbmount helper

sed -i '/\/media\/usb0/d' $target/etc/fstab

## Set localized console and keyboard

cp files/default/* $target/etc/default/

if [ ! -f /proc/mounts ]; then
	echo Warning: /proc is not mounted. Trying to fix.
	mkdir -p /proc
	mount /proc
	proc_mounted=1
fi

# Mount /home if we detect unmounted xenvg/system-stuff
grep -q /home /proc/mounts || test -b $target/dev/cbs/home && test -d $target/home && grep -q /home $target/etc/fstab && mount $target/home

# Place commented-out template for /cbs if no one
grep -q /home $target/etc/fstab || echo "#/dev/cbs/home /home ext4 errors=remount-ro 0 0" >>$target/etc/fstab

## Set up CD-ROM repository: create /stuff/cdimages, /media/sci

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
cp files/apt/sci-dev.list $target/root
cp files/apt/apt.pub $target/etc/apt/sci-dev.pub
apt-key add $target/etc/apt/sci-dev.pub

## Remove systemd
apt-get install -y --allow-downgrades --allow-remove-essential --allow-change-held-packages sysvinit-core sysvinit-utils
cp "$TARGET/usr/share/sysvinit/inittab" "$TARGET/etc/inittab"
apt-get remove -y --allow-downgrades --allow-remove-essential --allow-change-held-packages --purge --auto-remove systemd
echo -e 'Package: systemd\nPin: release *\nPin-Priority: -1' > "$TARGET/etc/apt/preferences.d/systemd"
echo -e '\n\nPackage: *systemd*\nPin: release *\nPin-Priority: -1' >> "$TARGET/etc/apt/preferences.d/systemd"
echo -e '\nPackage: systemd:i386\nPin: release *\nPin-Priority: -1' >> "$TARGET/etc/apt/preferences.d/systemd"

## disable nut-client
update-rc.d nut-client remove

## Write motd
cat <<EOF >$target/etc/motd

Debian CBS, ver. $VERSION
For more information see http://www.c-mit.ru

EOF

## enable puppet
update-rc.d -f puppet remove
update-rc.d -f puppet defaults

## Set vim disable defaults for 8.0
sed -i 's/\" let g:skip_defaults_vim = 1/let g:skip_defaults_vim = 1/' $TARGET/etc/vim/vimrc

## Set vim syntax on
sed -i 's/\"syntax on/syntax on/' $TARGET/etc/vim/vimrc


## Set chrony reboot if there is no sources

echo 'PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin' >> $target/etc/cron.d/chrony
echo '*/10 * * * *	root	chronyc sourcestats|grep -q "^210 Number of sources = 0" && service chrony restart' >> $target/etc/cron.d/chrony

# Write installed version information
echo $VERSION >$target/etc/cbs.version
