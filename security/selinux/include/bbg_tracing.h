#ifndef BBG_CRED_STRUCT_DEFINED
#define BBG_CRED_STRUCT_DEFINED

struct bbg_cred_security_struct {
	unsigned is_untrusted_process:1;	/* execve from su */
};

#endif
