#!/bin/sh
# Keep the libguestfs appliance kernel where no host mount can hide it.
#
# guestfish (Workspace live backups, the legacy converter) boots a small
# appliance with this image's own kernel. KVM hosts run the image with the
# host's /lib/modules bound over /lib/modules, which hid that kernel's
# modules: supermin found no usable kernel and every appliance died before it
# read a byte (dev atp7 2026-11-15). The agent points supermin at this copy
# (SUPERMIN_KERNEL / SUPERMIN_MODULES in go/guestfs_linux.go).
set -eu
arch=$(dpkg --print-architecture)
package=$(dpkg-query -W -f='${Depends}' "linux-image-$arch" | sed 's/[ ,(].*//')
version=${package#linux-image-}
dest=/usr/lib/devshot/guestfs
test -f "/boot/vmlinuz-$version"
test -d "/lib/modules/$version"
mkdir -p "$dest"
cp "/boot/vmlinuz-$version" "$dest/vmlinuz"
chmod 0644 "$dest/vmlinuz"
mv "/lib/modules/$version" "$dest/modules"
