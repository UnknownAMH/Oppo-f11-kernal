#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/mm.h>
#include <linux/page-flags.h>
#include <linux/oom.h>
#include <linux/gfp.h>
#include <linux/fs.h>
#include <linux/writeback.h>
#include <linux/swap.h>
#include <linux/swapops.h>
#include <linux/mm_inline.h>
#include <linux/memcontrol.h>
#include <linux/pagevec.h>
#include <linux/percpu_counter.h>
#include <linux/psi.h>
#include "nandswap.h"

struct task_struct *nswapoutd = NULL;

static int nswapoutd_thread(void *data)
{
	set_freezable();
	while (!kthread_should_stop()) {
		if (try_to_freeze())
			continue;
		schedule_timeout_interruptible(HZ);
	}
	return 0;
}

int __init nandswap_init(void)
{
	nswapoutd = kthread_run(nswapoutd_thread, NULL, "nswapoutd");
	if (IS_ERR(nswapoutd)) {
		pr_err("Failed to create nswapoutd thread\n");
		return PTR_ERR(nswapoutd);
	}
	return 0;
}

void __exit nandswap_exit(void)
{
	if (nswapoutd) {
		kthread_stop(nswapoutd);
		nswapoutd = NULL;
	}
}

module_init(nandswap_init);
module_exit(nandswap_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("MediaTek");
MODULE_DESCRIPTION("NAND Swap Driver");
