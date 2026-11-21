### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=Helicopterr Kernel by Omar
do.devicecheck=0
do.modules=1
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=CPH1911
device.name2=OP4863
device.name3=CPH1969
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties



### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=/dev/block/by-name/boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=true;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# Disable AVB (Android Verified Boot) using Python script
disable_avb() {
    ui_print " ";
    ui_print "Disabling AVB (Android Verified Boot)...";

    # Use Python script to patch vbmeta flags to 3 (disabled)
    if [ -f "/tmp/disable_avb.py" ]; then
        python3 /tmp/disable_avb.py "$BOOTIMAGE"
    elif [ -f "$TOOLS/disable_avb.py" ]; then
        python3 "$TOOLS/disable_avb.py" "$BOOTIMAGE"
    else
        ui_print "Python script not found, using magiskboot fallback...";
        if [ -f "$MAGISKBOOT" ]; then
            "$MAGISKBOOT" --disable-verity --disable-verification "$BOOTIMAGE" 2>/dev/null || true
        fi
    fi

    # Also patch vbmeta partition if exists (for A/B devices)
    for part in vbmeta vbmeta_system vbmeta_vendor; do
        if [ -e "/dev/block/by-name/$part" ]; then
            ui_print "Patching $part partition...";
            dd if=/dev/zero of="/dev/block/by-name/$part" bs=4096 count=1 2>/dev/null || true
        fi
    done

    ui_print "AVB disabled.";
}

# boot install
dump_boot; # use split_boot to skip ramdisk unpack, e.g. for devices with init_boot ramdisk
ui_print " ";
ui_print "Mounting /vendor as read-write";
mount -o rw,remount /vendor;

if mount | grep -q '/vendor ' && mount | grep '/vendor ' | grep -qv 'ro,'; then
  : # mounted fine, fall through to no-op
else
  ui_print " ";
  ui_print "ERROR: Failed to mount /vendor as read-write!";
  ui_print "Vendor is read-only. Attempting to make it writable...";
  ui_print " ";
  ui_print "Unmounting /vendor...";
  umount /vendor;
  ui_print "Growing filesystem to max partition size...";
  resize2fs -f /dev/block/by-name/vendor;
  ui_print "Running e2fsck -E unshare_blocks...";
  e2fsck -fy -E unshare_blocks /dev/block/by-name/vendor;
  ui_print "Retrying mount after filesystem resize...";
  mount -o rw /vendor;
fi;

if mount | grep -q '/vendor ' && mount | grep '/vendor ' | grep -qv 'ro,'; then
  ui_print "/vendor mounted successfully as read-write";
else
  ui_print " ";
  ui_print "ERROR: Still failed to mount /vendor as read-write!";
  ui_print "Aborting installation...";
  abort "Vendor mount failure";
fi;

# Disable AVB
disable_avb;

write_boot; # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk
## end boot install
