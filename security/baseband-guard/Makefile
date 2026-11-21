bbg-objs += baseband_guard.o
bbg-objs += tracing/tracing.o
bbg-objs += blkdev_helper.o

ccflags-y += -I$(srctree)/security/selinux -I$(srctree)/security/selinux/include -I$(srctree)/block
ccflags-y += -I$(objtree)/security/selinux

obj-$(CONFIG_BBG) += bbg.o

# file_ioctl_compat hook only exists on newer kernels
ifeq ($(shell grep -q "file_ioctl_compat" $(srctree)/include/linux/lsm_hook_defs.h $(srctree)/include/linux/lsm_hooks.h 2>/dev/null && echo true),true)
    ccflags-y += -DBB_HAS_IOCTL_COMPAT
endif

ifeq ($(shell grep -q "selinux_state" $(srctree)/security/selinux/include/security.h 2>/dev/null && echo true),true)
    ccflags-y += -DBB_HAS_SELINUX_STATE
endif

ifeq ($(shell grep -q "task_security_struct\s\+\*selinux_cred" $(srctree)/security/selinux/include/objsec.h; echo $$?),0)
    ccflags-y += -DBBG_COMPAT_SELINUX_CRED
endif

# Pre-5.11 block layer has no bd_meta_info / blkdev_get_no_open
ifneq ($(shell grep -q "disk_get_part" $(srctree)/include/linux/genhd.h 2>/dev/null && echo true),true)
    ccflags-y += -DBBG_COMPAT_HAS_BLOCK_DEVICE_API
endif

ccflags-y += -DBBG_VERSION=\"vendored-028ff7f\"
ccflags-y += -DBBG_REPO=\"https://github.com/vc-teahouse/Baseband-guard\"
