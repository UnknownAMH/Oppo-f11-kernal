#ifndef _NAND_SWAP_H
#define _NAND_SWAP_H

#include <linux/types.h>
#include <linux/list.h>
#include <linux/sched.h>

enum nswap_type {
	NS_TYPE_NONE,
	NS_TYPE_RATIO,
	NS_TYPE_END
};

extern struct task_struct *nswapoutd;
static inline bool current_is_nswapoutd(void)
{
	return current == nswapoutd;
}
#endif /* _NAND_SWAP_H */
