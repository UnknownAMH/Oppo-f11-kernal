### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## customized for Oppo F11 / CPH1911 (MT6771, oppo6771)
## - replaces kernel in boot (ramdisk untouched)
## - disables AVB in the flashed boot image (PATCH_VBMETA_FLAG)
## - pushes vendor modules to /vendor/lib/modules

### AnyKernel setup
# global properties
properties() { '
kernel.string=4.14.186+ stock-tree kernel, module verification disabled
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=oppo6771
device.name2=CPH1911
supported.versions=
supported.patchlevels=
'; } # end properties

## boot shell variables
BLOCK=auto;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

### push vendor modules to /vendor/lib/modules
push_vendor_modules() {
  ui_print "- Pushing vendor modules...";
  local vpart;
  for p in /dev/block/by-name/vendor /dev/block/bootdevice/by-name/vendor /dev/block/platform/*/by-name/vendor /dev/block/platform/*/*/by-name/vendor; do
    if [ -e "$p" ]; then vpart=$p; break; fi;
  done;
  if [ ! "$vpart" ]; then
    ui_print "  - vendor partition not found, skipping";
    return 1;
  fi;
  mkdir -p /mnt/ak3_vendor;
  if ! mount -t ext4 -o rw $vpart /mnt/ak3_vendor 2>/dev/null; then
    if ! mount -o rw $vpart /mnt/ak3_vendor 2>/dev/null; then
      ui_print "  - failed to mount vendor rw, skipping";
      rmdir /mnt/ak3_vendor 2>/dev/null;
      return 1;
    fi;
  fi;
  local vdir=/mnt/ak3_vendor/lib/modules;
  mkdir -p $vdir;
  [ -f $vdir/modules.dep.bak ] || cp -f $vdir/modules.dep $vdir/modules.dep.bak 2>/dev/null;
  cp -f $AKHOME/modules/*.ko $vdir/;
  for f in modules.dep modules.alias modules.softdep modules.load; do
    [ -f $AKHOME/modules/$f ] && cp -f $AKHOME/modules/$f $vdir/;
  done;
  chmod 0644 $vdir/*.ko $vdir/modules.* 2>/dev/null;
  chown -R 0:0 $vdir 2>/dev/null;
  chcon -R u:object_r:vendor_configs_file:s0 $vdir 2>/dev/null;
  umount /mnt/ak3_vendor;
  rmdir /mnt/ak3_vendor 2>/dev/null;
  ui_print "  - vendor modules installed";
  return 0;
}

### install
split_boot;
write_boot;
push_vendor_modules;
ui_print "- Done.";
exit 0
