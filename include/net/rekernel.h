#ifndef __REKERNEL_H
#define __REKERNEL_H

#include <linux/types.h>
#include <linux/cgroup.h>
#include <linux/freezer.h>
#include <linux/sched.h>
#include <uapi/linux/android/binder.h>

/* Re-Kernel UAPI for 4.14 compat - avoids conflict with hans.h */
enum rek_report_type {
	REK_BINDER,
	REK_SIGNAL,
#ifdef CONFIG_REKERNEL_NETWORK
	REK_NETWORK,
#endif
};

enum rek_binder_type {
	REK_REPLY,
	REK_TRANSACTION,
	REK_OVERFLOW,
};

/* 4.14 compat: enum aliases for compatibility with existing code */
#define BINDER		REK_BINDER
#define SIGNAL		REK_SIGNAL
#define NETWORK		REK_NETWORK
#define REPLY		REK_REPLY
#define TRANSACTION	REK_TRANSACTION
#define OVERFLOW	REK_OVERFLOW

/* 4.14 compat: JOBCTL_TRAP_FREEZE not available */
#ifndef JOBCTL_TRAP_FREEZE
#define JOBCTL_TRAP_FREEZE 0
#endif

/* 4.14 compat: cgroup_task_frozen/freeze not available */
#ifndef CONFIG_ARCH_HAS_CGROUP_TASK_FREEZE
#define cgroup_task_frozen(task) frozen(task)
#define cgroup_task_freeze(task) freezing(task)
#endif

/* Function declarations for kernel hooks */
extern void rekernel_report(int reporttype, int type, pid_t src_pid, struct task_struct* src, pid_t dst_pid, struct task_struct* dst, bool oneway, struct binder_transaction_data* tr);
extern void rekernel_report_no_binder_rpc_code(int type, pid_t src_pid, struct task_struct* src, pid_t dst_pid, struct task_struct* dst, bool oneway, const char* rpc_name);
extern void binder_reply_handler(pid_t src_pid, struct task_struct* src, pid_t dst_pid, struct task_struct* dst, bool oneway, struct binder_transaction_data* tr);
extern void binder_trans_handler(pid_t src_pid, struct task_struct* src, pid_t dst_pid, struct task_struct* dst, bool oneway, struct binder_transaction_data* tr);
extern void binder_overflow_handler(pid_t src_pid, struct task_struct* src, pid_t dst_pid, struct task_struct* dst, bool oneway, struct binder_transaction_data* tr);

/* 4.14 compat: JOBCTL_TRAP_FREEZE not available */
#ifndef JOBCTL_TRAP_FREEZE
#define JOBCTL_TRAP_FREEZE 0
#endif

/* 4.14 compat: cgroup_task_frozen/freeze not available */
#ifndef CONFIG_ARCH_HAS_CGROUP_TASK_FREEZE
#define cgroup_task_frozen(task) frozen(task)
#define cgroup_task_freeze(task) freezing(task)
#endif

#endif /* __REKERNEL_H */
