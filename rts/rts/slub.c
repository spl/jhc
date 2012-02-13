#if _JHC_GC == _JHC_GC_JGC

#ifdef JHC_HEADER

struct s_arena;
struct s_cache;
static void *s_alloc(gc_t gc, struct s_cache *sc) A_UNUSED;
static struct s_cache *find_cache(struct s_cache **rsc, struct s_arena *arena,
                                  unsigned short size, unsigned short num_ptrs) A_UNUSED;
static bool s_set_used_bit(void *val) A_UNUSED;
static void clear_used_bits(struct s_arena *arena) A_UNUSED;

#define S_BLOCK(val) ((struct s_block *)((uintptr_t)(val) & ~ (BLOCK_SIZE - 1)))
#define BLOCK_SIZE     (1UL << 12)
#define MEGABLOCK_SIZE (1UL << 20)

#else

#include "sys/bitarray.h"
#include "sys/queue.h"

struct s_arena {
        struct s_megablock *current_megablock;
        SLIST_HEAD(,s_block) free_blocks;
        unsigned block_used;
        unsigned block_threshold;
        SLIST_HEAD(,s_cache) caches;
        SLIST_HEAD(,s_megablock) megablocks;
};

struct s_megablock {
        void *base;
        unsigned next_free;
        SLIST_ENTRY(s_megablock) next;
};

struct s_block_info {
        unsigned char color;
        unsigned char size;
        unsigned char num_ptrs;
        unsigned char flags;
};

struct s_block {
        SLIST_ENTRY(s_block) link;
        struct s_block_info pi;
        unsigned short num_free;
        unsigned short next_free;
        bitarray_t used[];
};

struct s_cache {
        SLIST_ENTRY(s_cache) next;
        SLIST_HEAD(,s_block) blocks;
        SLIST_HEAD(,s_block) full_blocks;
        struct s_block_info pi;
        unsigned short num_entries;
        struct s_arena *arena;
};

/* This finds a bit that isn't set, sets it, then returns its index.  It
 * assumes that a bit is available to be found, otherwise it goes into an
 * infinite loop. */

static unsigned
bitset_find_free(unsigned *next_free,int n,bitarray_t ba[static n]) {
        assert(*next_free < (unsigned)n);
        unsigned i = *next_free;
        do {
                int o = __builtin_ffsl(~ba[i]);
                if(__predict_true(o)) {
                        ba[i] |= (1UL << (o - 1));
                        *next_free = i;
                        return (i*BITS_PER_UNIT + (o - 1));
                }
                i = (i + 1) % n;
                assert(i != *next_free);
        } while (1);
}

struct s_megablock *
s_new_megablock(struct s_arena *arena)
{
        struct s_megablock *mb = malloc(sizeof(*mb));
#if defined(__WIN32__)
        mb->base = _aligned_malloc(MEGABLOCK_SIZE, BLOCK_SIZE);
        int ret = !mb->base;
#elif defined(__ARM_EABI__)
        mb->base = memalign(BLOCK_SIZE,MEGABLOCK_SIZE);
        int ret = !mb->base;
#elif (defined(__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__) && __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ <  1060)
        assert(sysconf(_SC_PAGESIZE) == BLOCK_SIZE);
        mb->base = valloc(MEGABLOCK_SIZE);
        int ret = !mb->base;
#else
        int ret = posix_memalign(&mb->base,BLOCK_SIZE,MEGABLOCK_SIZE);
#endif
        if(ret != 0) {
                fprintf(stderr,"Unable to allocate memory for megablock\n");
                abort();
        }
        VALGRIND_MAKE_MEM_NOACCESS(mb->base,MEGABLOCK_SIZE);
        //VALGRIND_FREELIKE_BLOCK(mb->base,0);
        mb->next_free = 0;
        return mb;
}

/* block allocator */

static struct s_block *
get_free_block(gc_t gc, struct s_arena *arena) {
        arena->block_used++;
        if(__predict_true(SLIST_FIRST(&arena->free_blocks))) {
                struct s_block *pg = SLIST_FIRST(&arena->free_blocks);
                SLIST_REMOVE_HEAD(&arena->free_blocks,link);
                return pg;
        } else {
                if((arena->block_used >= arena->block_threshold)) {
                        gc_perform_gc(gc);
                        // if we are still using 80% of the heap after a gc, raise the threshold.
                        if(__predict_false((unsigned)arena->block_used * 10 >= arena->block_threshold * 9)) {
                                arena->block_threshold *= 2;
                        }
                }
                if(__predict_false(!arena->current_megablock))
                        arena->current_megablock = s_new_megablock(arena);
                struct s_megablock *mb = arena->current_megablock;
                struct s_block *pg = mb->base + BLOCK_SIZE*mb->next_free;
                mb->next_free++;
                if(mb->next_free == MEGABLOCK_SIZE / BLOCK_SIZE) {
                        SLIST_INSERT_HEAD(&arena->megablocks,mb, next);
                        arena->current_megablock = NULL;
                }
                VALGRIND_MAKE_MEM_UNDEFINED(pg,sizeof(struct s_block));
                pg->num_free = 0;
                return pg;
        }
}

static void
s_cleanup_blocks(struct s_arena *arena) {
        struct s_cache *sc = SLIST_FIRST(&arena->caches);
        for(;sc;sc = SLIST_NEXT(sc,next)) {

                // 'best' keeps track of the block with the fewest free spots
                // and percolates it to the front, effectively a single pass
                // of a bubblesort to help combat fragmentation. It does
                // not increase the complexity of the cleanup algorithm as
                // we had to scan every block anyway, but over many passes
                // of the GC it will eventually result in a more sorted list
                // than would occur by chance.

                struct s_block *best = NULL;
                int free_best = 4096;
                struct s_block *pg = SLIST_FIRST(&sc->blocks);
                struct s_block *fpg = SLIST_FIRST(&sc->full_blocks);
                SLIST_INIT(&sc->blocks);
                SLIST_INIT(&sc->full_blocks);
                if(!pg) {
                        pg = fpg;
                        fpg = NULL;
                }
                while(pg) {
                        struct s_block *npg = SLIST_NEXT(pg,link);
                        if(__predict_false(pg->num_free == 0)) {
                                SLIST_INSERT_HEAD(&sc->full_blocks,pg,link);
                        } else if(__predict_true(pg->num_free == sc->num_entries)) {
                                arena->block_used--;
                                VALGRIND_MAKE_MEM_NOACCESS((char *)pg + sizeof(struct s_block), BLOCK_SIZE - sizeof(struct s_block));
                                SLIST_INSERT_HEAD(&arena->free_blocks,pg,link);
                        } else {
                                if(!best) {
                                        free_best = pg->num_free;
                                        best = pg;
                                } else {
                                        if(pg->num_free < free_best) {
                                                struct s_block *tmp = best;
                                                best = pg; pg = tmp;
                                                free_best = pg->num_free;
                                        }
                                        SLIST_INSERT_HEAD(&sc->blocks,pg,link);
                                }
                        }
                        if(!npg && fpg) {
                                pg = fpg;
                                fpg = NULL;
                        } else
                                pg = npg;
                }
                if(best)
                        SLIST_INSERT_HEAD(&sc->blocks,best,link);
        }
}

inline static void
clear_block_used_bits(unsigned num_entries, struct s_block *pg)
{
        pg->num_free = num_entries;
        memset(pg->used,0,BITARRAY_SIZE_IN_BYTES(num_entries) - sizeof(pg->used[0]));
        int excess = num_entries % BITS_PER_UNIT;
        pg->used[BITARRAY_SIZE(num_entries) - 1] = ~((1UL << excess) - 1);
#if JHC_VALGRIND
                unsigned header =  sizeof(struct s_block) + BITARRAY_SIZE_IN_BYTES(num_entries);
                VALGRIND_MAKE_MEM_NOACCESS((char *)pg + header, BLOCK_SIZE - header);
#endif
}

static void *
s_alloc(gc_t gc, struct s_cache *sc)
{
        struct s_block *pg = SLIST_FIRST(&sc->blocks);
        if(__predict_false(!pg)) {
                pg = get_free_block(gc, sc->arena);
                VALGRIND_MAKE_MEM_NOACCESS(pg, BLOCK_SIZE);
                VALGRIND_MAKE_MEM_DEFINED(pg, sizeof(struct s_block));
                if(sc->num_entries != pg->num_free)
                        VALGRIND_MAKE_MEM_UNDEFINED((char *)pg->used,BITARRAY_SIZE_IN_BYTES(sc->num_entries));
                else
                        VALGRIND_MAKE_MEM_DEFINED((char *)pg->used,BITARRAY_SIZE_IN_BYTES(sc->num_entries));
                assert(pg);
                pg->pi = sc->pi;
                pg->next_free = 0;
                SLIST_INSERT_HEAD(&sc->blocks,pg,link);
                if(sc->num_entries != pg->num_free)
                        clear_block_used_bits(sc->num_entries, pg);
                pg->used[0] = 1; //set the first bit
                pg->num_free = sc->num_entries - 1;
                return (uintptr_t *)pg + pg->pi.color;
        } else {
                __builtin_prefetch(pg->used,1);
                pg->num_free--;
                unsigned next_free = pg->next_free;
                unsigned found = bitset_find_free(&next_free,BITARRAY_SIZE(sc->num_entries),pg->used);
                pg->next_free = next_free;
                void *val = (uintptr_t *)pg + pg->pi.color + found*pg->pi.size;
                if(__predict_false(0 == pg->num_free)) {
                        assert(pg == SLIST_FIRST(&sc->blocks));
                        SLIST_REMOVE_HEAD(&sc->blocks,link);
                        SLIST_INSERT_HEAD(&sc->full_blocks,pg,link);
                }
                assert(S_BLOCK(val) == pg);
                //printf("s_alloc: val: %p s_block: %p size: %i color: %i found: %i num_free: %i\n", val, pg, pg->pi.size, pg->pi.color, found, pg->num_free);
                return val;
        }
}

/*
static void
s_free(void *val)
{
        assert(val);
        struct s_block *pg = s_block(val);
        unsigned int offset = ((uintptr_t *)val - (uintptr_t *)pg) - pg->pi.color;
//        printf("s_free:  val: %p s_block: %p size: %i color: %i num_free: %i offset: %i bit: %i\n", val, pg, pg->pi.size, pg->pi.color, pg->num_free, offset, offset/pg->pi.size);
        assert(BIT_VALUE(pg->used,offset/(pg->pi.size)));
        BIT_UNSET(pg->used,offset/(pg->pi.size));
        pg->num_free++;
}
*/

static struct s_cache *
new_cache(struct s_arena *arena, unsigned short size, unsigned short num_ptrs)
{
        struct s_cache *sc = malloc(sizeof(*sc));
        sc->arena = arena;
        sc->pi.size = size;
        sc->pi.num_ptrs = num_ptrs;
        sc->pi.flags = 0;
        size_t excess = BLOCK_SIZE - sizeof(struct s_block);
        sc->num_entries = (8*excess) / (8*sizeof(uintptr_t)*size + 1) - 1;
        //sc->num_entries = (8*excess) / (8*size*sizeof(uintptr_t) + 1);
        sc->pi.color = (sizeof(struct s_block) + BITARRAY_SIZE_IN_BYTES(sc->num_entries) + sizeof(uintptr_t) - 1) / sizeof(uintptr_t);
        SLIST_INIT(&sc->blocks);
        SLIST_INIT(&sc->full_blocks);
        SLIST_INSERT_HEAD(&arena->caches,sc,next);
        //print_cache(sc);
        return sc;
}

// clear all used bits, must be followed by a marking phase.
static void
clear_used_bits(struct s_arena *arena)
{
        struct s_cache *sc = SLIST_FIRST(&arena->caches);
        for(;sc;sc = SLIST_NEXT(sc,next)) {
                struct s_block *pg = SLIST_FIRST(&sc->blocks);
                struct s_block *fpg = SLIST_FIRST(&sc->full_blocks);
                do {
                        for(;pg;pg = SLIST_NEXT(pg,link))
                                clear_block_used_bits(sc->num_entries,pg);
                        pg = fpg;
                        fpg = NULL;
                }  while(pg);
        }
}

// set a used bit. returns true if the
// tagged node should be scanned by the GC.
// this happens when the used bit was not previously set
// and the node contains internal pointers.

static bool
s_set_used_bit(void *val)
{
        assert(val);
        struct s_block *pg = S_BLOCK(val);
        unsigned int offset = ((uintptr_t *)val - (uintptr_t *)pg) - pg->pi.color;
        if(__predict_true(BIT_IS_UNSET(pg->used,offset/pg->pi.size))) {
                BIT_SET(pg->used,offset/pg->pi.size);
                pg->num_free--;
                return (bool)pg->pi.num_ptrs;
        }
        return false;
}

static struct s_cache *
find_cache(struct s_cache **rsc, struct s_arena *arena, unsigned short size, unsigned short num_ptrs)
{
        if(__predict_true(rsc && *rsc))
                return *rsc;
        struct s_cache *sc = SLIST_FIRST(&arena->caches);
        for(;sc;sc = SLIST_NEXT(sc,next)) {
                if(sc->pi.size == size && sc->pi.num_ptrs == num_ptrs)
                        goto found;
        }
        sc = new_cache(arena,size,num_ptrs);
found:
        if(rsc)
                *rsc = sc;
        return sc;
}

struct s_arena *
new_arena(void) {
        struct s_arena *arena = malloc(sizeof(struct s_arena));
        SLIST_INIT(&arena->caches);
        SLIST_INIT(&arena->free_blocks);
        SLIST_INIT(&arena->megablocks);
        arena->block_used = 0;
        arena->block_threshold = 8;
        arena->current_megablock = NULL;
        return arena;
}

void
print_cache(struct s_cache *sc) {
        fprintf(stderr, "num_entries: %i\n",(int)sc->num_entries);
//        printf("  entries: %i words\n",(int)(sc->num_entries*sc->pi.size));
        fprintf(stderr, "  header: %lu bytes\n", sizeof(struct s_block) + BITARRAY_SIZE_IN_BYTES(sc->num_entries));
        fprintf(stderr, "  size: %i words\n",(int)sc->pi.size);
//        printf("  color: %i words\n",(int)sc->pi.color);
        fprintf(stderr, "  nptrs: %i words\n",(int)sc->pi.num_ptrs);
//        printf("  end: %i bytes\n",(int)(sc->pi.color+ sc->num_entries*sc->pi.size)*sizeof(uintptr_t));
        fprintf(stderr, "%20s %9s %9s %s\n", "block", "num_free", "next_free", "status");
        struct s_block *pg;
        SLIST_FOREACH(pg,&sc->blocks,link) {
            fprintf(stderr, "%20p %9i %9i %c\n", pg, pg->num_free, pg->next_free, 'P');
        }
        fprintf(stderr, "  full_blocks:\n");
        SLIST_FOREACH(pg,&sc->full_blocks,link) {
            fprintf(stderr, "%20p %9i %9i %c\n", pg, pg->num_free, pg->next_free, 'F');
        }
}

#endif
#endif
