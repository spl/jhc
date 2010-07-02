#ifdef JHC_RTS_INCLUDE
#undef JHC_RTS_INCLUDE
#include "jhc_jgc.h"
#define JHC_RTS_INCLUDE
#else

#if _JHC_GC == _JHC_GC_JGC

#ifndef JGC_STATUS
#define JGC_STATUS 0
#endif


#ifdef JHC_JGC_STACK

struct frame {
        struct frame *prev;
        unsigned nptrs;
        void *ptrs[0];
};

typedef struct frame *gc_t;

#else

typedef void* *gc_t;

#endif

static gc_t saved_gc;

#ifndef JHC_JGC_STACK
static gc_t gc_stack_base;
#endif


#define GC_MINIMUM_SIZE 1
#define GC_BASE sizeof(void *)

#define TO_BLOCKS(x) ((x) <= GC_MINIMUM_SIZE*GC_BASE ? GC_MINIMUM_SIZE : (((x) - 1)/GC_BASE) + 1)

struct s_cache;
static void gc_perform_gc(gc_t gc);
static void *gc_alloc(gc_t gc,struct s_cache **sc, unsigned count, unsigned nptrs);


#if 0
#ifdef NDEBUG
#define JUDYERROR_NOTEST 1
#endif

#include <Judy.h>
#endif

#if JGC_STATUS > 1
#define debugf(...) fprintf(stderr,__VA_ARGS__)
#else
#define debugf(...) do { } while (0)
#endif

#endif
#endif
