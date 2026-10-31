/*
 * SPIN Model for Inferno Namespace Race Conditions
 *
 * Models the namespace operations that race when one emu host thread
 * reads a Prog's name space while that Prog's own thread changes it
 * (INFR-373).  Dis code runs one thread at a time, but a system call
 * releases the VM, so the Prog's own thread then runs beside every
 * other thread; and devprog (/prog/n/ns, fd, status) reads ANOTHER
 * Prog's groups, holding the VM.
 *
 * RACE 1: Sys_pctl FORKNS pgrp pointer swap (inferno.c, Sys_pctl)
 *   - Process A calls Sys_pctl(FORKNS) with the VM released, swaps
 *     o->pgrp and closes the old one
 *   - Thread B reads A's o->pgrp (devprog) concurrently
 *   - B could use the old pgrp after A's closepgrp freed it
 *
 * RACE 2: kchdir dot-writing race (sysfile.c, kchdir)
 *   - Process A calls kchdir: cclose(pg->dot); pg->dot = c;
 *   - Thread B reads pg->dot (namec, devprog)
 *   - B could read the freed channel between cclose and assignment
 *
 * RACE 3: reading slash/dot without the lock (chan.c namec, devprog)
 *   - pg->slash or pg->dot read without holding pg->ns
 *
 * By default the model is the code as fixed:
 *   - the pgrp swap holds the VM, as devprog's readers do, and the
 *     old pgrp is closed after it (pctlswap);
 *   - kchdir replaces dot holding pg->ns (wlock) and closes the old
 *     dot after unlocking;
 *   - readers take pg->ns (rlock) to read slash/dot and incref it.
 * Defining UNFIXED models the code before the fix, in which SPIN
 * finds all three use-after-frees:
 *
 *   spin -a namespace_races.pml                 # fixed: properties hold
 *   spin -DUNFIXED -a namespace_races.pml       # before: violations
 *   gcc -o pan pan.c -O2
 *   ./pan -a -N no_use_after_free_dot -m10000000
 */

/* Channel states */
#define CHAN_FREED    0
#define CHAN_VALID    1
#define CHAN_CLOSING  2

/* Pgrp states */
#define PGRP_FREED   0
#define PGRP_VALID   1
#define PGRP_CLOSING 2

/* Number of pgrps and channels */
#define NUM_PGRPS    3
#define NUM_CHANS    4

/* State */
byte pgrp_state[NUM_PGRPS];    /* FREED, VALID, CLOSING */
byte pgrp_refcount[NUM_PGRPS];
byte pgrp_dot[NUM_PGRPS];      /* Channel ID used as dot */
byte pgrp_slash[NUM_PGRPS];    /* Channel ID used as slash */
byte chan_state[NUM_CHANS];     /* FREED, VALID, CLOSING */
byte chan_refcount[NUM_CHANS];

/* Process's current pgrp pointer (o->pgrp) */
byte process_pgrp[2];  /* 2 processes sharing an Osenv */

/*
 * Locks.  The VM lock (acquire/release) and each pgrp's ns RWlock.
 * The ns lock is modelled as exclusive: that only removes reader
 * interleavings, and readers do not race with each other.
 */
bit vm = 0;
bit ns[NUM_PGRPS];

inline lockvm()   { atomic { vm == 0 -> vm = 1 } }
inline unlockvm() { vm = 0 }
inline lockns(p)  { atomic { ns[p] == 0 -> ns[p] = 1 } }
inline unlockns(p) { ns[p] = 0 }

/* Verification flags */
bool use_after_free_dot = false;
bool use_after_free_pgrp = false;
bool use_after_free_slash = false;

/* ========== RACE 1: Sys_pctl FORKNS ========== */

/*
 * Models Sys_pctl with FORKNS flag (inferno.c:869-876):
 *
 *   release();                    // Let other threads run
 *   np.np = newpgrp();
 *   pgrpcpy(np.np, o->pgrp);
 *   opg = o->pgrp;               // Read old pgrp
 *   o->pgrp = np.np;             // SWAP - no lock!
 *   np.np = nil;
 *   closepgrp(opg);              // Decref old pgrp
 *   acquire();
 *
 * The critical window: between o->pgrp = np.np and closepgrp(opg),
 * another thread reading o->pgrp might see np.np (new, valid) or
 * still be using opg (which is being freed).
 *
 * Actually, the real danger is: the Dis virtual machine calls release()
 * before the pctl operation (line 809), allowing other emu threads to
 * run. If another thread has already read up->env->pgrp and cached it,
 * then after the swap, that cached pointer is stale.
 *
 * Note: In Inferno's threading model, only one Dis thread runs at a time
 * per virtual machine (cooperative scheduling with release()/acquire()).
 * However, multiple emu threads (for I/O, timers, etc.) can access the
 * Osenv concurrently.
 */

proctype sys_pctl_forkns(byte proc_id) {
    byte old_pg, new_pg;

    /* release() - allow concurrent access */
    /* (modeled by allowing interleaving) */

    /* np.np = newpgrp() */
    atomic {
        byte i;
        for (i : 0 .. (NUM_PGRPS - 1)) {
            if
            :: (pgrp_state[i] == PGRP_FREED) ->
                new_pg = i;
                pgrp_state[i] = PGRP_VALID;
                pgrp_refcount[i] = 1;
                break;
            :: else -> skip;
            fi
        }
    }

    /* pgrpcpy(np.np, o->pgrp) - copy mounts (simplified), wlock(from->ns) */
    old_pg = process_pgrp[proc_id];
#ifndef UNFIXED
    lockns(old_pg);
#endif
    /* Copy dot/slash from old to new */
    pgrp_dot[new_pg] = pgrp_dot[old_pg];
    pgrp_slash[new_pg] = pgrp_slash[old_pg];
    /* Incref channels for the copy */
    if
    :: (pgrp_dot[old_pg] < NUM_CHANS && chan_state[pgrp_dot[old_pg]] == CHAN_VALID) ->
        chan_refcount[pgrp_dot[old_pg]] = chan_refcount[pgrp_dot[old_pg]] + 1;
    :: else -> skip
    fi
    if
    :: (pgrp_slash[old_pg] < NUM_CHANS && chan_state[pgrp_slash[old_pg]] == CHAN_VALID) ->
        chan_refcount[pgrp_slash[old_pg]] = chan_refcount[pgrp_slash[old_pg]] + 1;
    :: else -> skip
    fi
#ifndef UNFIXED
    unlockns(old_pg);
#endif

    /* opg = o->pgrp; o->pgrp = np.np; -- holding the VM (pctlswap) */
#ifndef UNFIXED
    lockvm();
#endif
    process_pgrp[proc_id] = new_pg;
#ifndef UNFIXED
    unlockvm();
#endif

    /* closepgrp(opg) - decrement old pgrp refcount; free under wlock(ns) */
    pgrp_refcount[old_pg] = pgrp_refcount[old_pg] - 1;
    if
    :: (pgrp_refcount[old_pg] == 0) ->
#ifndef UNFIXED
        lockns(old_pg);
#endif
        pgrp_state[old_pg] = PGRP_CLOSING;
        /* Free dot channel */
        if
        :: (pgrp_dot[old_pg] < NUM_CHANS) ->
            chan_refcount[pgrp_dot[old_pg]] = chan_refcount[pgrp_dot[old_pg]] - 1;
            if
            :: (chan_refcount[pgrp_dot[old_pg]] == 0) ->
                chan_state[pgrp_dot[old_pg]] = CHAN_FREED;
            :: else -> skip
            fi
        :: else -> skip
        fi
        /* Free slash channel */
        if
        :: (pgrp_slash[old_pg] < NUM_CHANS) ->
            chan_refcount[pgrp_slash[old_pg]] = chan_refcount[pgrp_slash[old_pg]] - 1;
            if
            :: (chan_refcount[pgrp_slash[old_pg]] == 0) ->
                chan_state[pgrp_slash[old_pg]] = CHAN_FREED;
            :: else -> skip
            fi
        :: else -> skip
        fi
        pgrp_state[old_pg] = PGRP_FREED;
#ifndef UNFIXED
        unlockns(old_pg);
#endif
    :: else -> skip
    fi
}

/* ========== RACE 2: kchdir dot-writing ========== */

/*
 * Models kchdir() from sysfile.c.  Before the fix:
 *
 *   c = namec(path, Atodir, 0, 0);
 *   pg = up->env->pgrp;
 *   cclose(pg->dot);       // STEP A: free old dot
 *   pg->dot = c;           // STEP B: assign new dot
 *
 * with no lock between steps A and B.  Fixed:
 *
 *   c = namec(path, Atodir, 0, 0);
 *   pg = up->env->pgrp;
 *   wlock(&pg->ns);
 *   old = pg->dot;
 *   pg->dot = c;
 *   wunlock(&pg->ns);
 *   cclose(old);
 */

proctype kchdir(byte proc_id; byte new_chan) {
    byte pg, old_dot;

    pg = process_pgrp[proc_id];

    /* Check pgrp is valid */
    assert(pg < NUM_PGRPS);
    if
    :: (pgrp_state[pg] != PGRP_VALID) -> goto done;
    :: else -> skip
    fi

#ifdef UNFIXED
    old_dot = pgrp_dot[pg];

    /* STEP A: cclose(pg->dot) - decrement refcount */
    if
    :: (old_dot < NUM_CHANS && chan_state[old_dot] == CHAN_VALID) ->
        chan_refcount[old_dot] = chan_refcount[old_dot] - 1;
        if
        :: (chan_refcount[old_dot] == 0) ->
            chan_state[old_dot] = CHAN_FREED;
        :: else -> skip
        fi
    :: else -> skip
    fi

    /* CRITICAL WINDOW: pg->dot points to potentially freed channel */
    /* Another thread reading pg->dot RIGHT NOW sees stale value */

    /* STEP B: pg->dot = c */
    pgrp_dot[pg] = new_chan;
    if
    :: (new_chan < NUM_CHANS && chan_state[new_chan] == CHAN_VALID) ->
        chan_refcount[new_chan] = chan_refcount[new_chan] + 1;
    :: else -> skip
    fi
#else
    /* c = namec(...): the new dot arrives with a reference */
    if
    :: (new_chan < NUM_CHANS && chan_state[new_chan] == CHAN_VALID) ->
        chan_refcount[new_chan] = chan_refcount[new_chan] + 1;
    :: else -> skip
    fi

    lockns(pg);
    old_dot = pgrp_dot[pg];
    pgrp_dot[pg] = new_chan;
    unlockns(pg);

    /* cclose(old) */
    if
    :: (old_dot < NUM_CHANS && chan_state[old_dot] == CHAN_VALID) ->
        chan_refcount[old_dot] = chan_refcount[old_dot] - 1;
        if
        :: (chan_refcount[old_dot] == 0) ->
            chan_state[old_dot] = CHAN_FREED;
        :: else -> skip
        fi
    :: else -> skip
    fi
#endif

done:
    skip;
}

/* ========== RACE 3: namec reading slash/dot ========== */

/*
 * Models a reader of another thread's pg->slash or pg->dot: namec()
 * (chan.c) on its own pgrp, devprog on another Prog's.  Before the
 * fix the read of the pgrp pointer and of slash/dot held no lock:
 *
 *   c = up->env->pgrp->dot;     // NO LOCK
 *   incref(&c->r);
 *
 * Fixed, devprog holds the VM from reading o->pgrp until it is done
 * with it, and slash/dot are read and incref'd under rlock(&pg->ns):
 *
 *   acquire();
 *   pg = o->pgrp;
 *   rlock(&pg->ns); c = pg->dot; incref(&c->r); runlock(&pg->ns);
 *   ...
 *   release();
 */

proctype namec_reader(byte proc_id; bit use_slash) {
    byte pg, ch;

#ifndef UNFIXED
    lockvm();
#endif
    /* Read pgrp pointer (could be stale if concurrent FORKNS) */
    pg = process_pgrp[proc_id];

    /* Check pgrp validity */
    if
    :: (pg >= NUM_PGRPS || pgrp_state[pg] != PGRP_VALID) ->
        /* USE-AFTER-FREE: reading a freed pgrp */
        if
        :: (pg < NUM_PGRPS && pgrp_state[pg] == PGRP_FREED) ->
            use_after_free_pgrp = true;
        :: else -> skip
        fi
        goto done;
    :: else -> skip
    fi

#ifndef UNFIXED
    lockns(pg);
#endif
    /* Read slash or dot */
    if
    :: (use_slash) -> ch = pgrp_slash[pg];
    :: else -> ch = pgrp_dot[pg];
    fi

    /* Check channel validity before incref */
    if
    :: (ch >= NUM_CHANS) ->
#ifndef UNFIXED
        unlockns(pg);
#endif
        goto done;
    :: else -> skip
    fi

    /* Try to incref - but channel might be freed! */
    if
    :: (chan_state[ch] == CHAN_FREED) ->
        /* USE-AFTER-FREE: trying to incref a freed channel */
        if
        :: (use_slash) -> use_after_free_slash = true;
        :: else -> use_after_free_dot = true;
        fi
#ifndef UNFIXED
        unlockns(pg);
#endif
    :: (chan_state[ch] == CHAN_VALID) ->
        chan_refcount[ch] = chan_refcount[ch] + 1;
#ifndef UNFIXED
        unlockns(pg);
#endif
        /* Use the channel for name resolution */
        skip;
        /* Done, decref */
        chan_refcount[ch] = chan_refcount[ch] - 1;
    :: else ->
#ifndef UNFIXED
        unlockns(pg);
#endif
        skip
    fi

done:
#ifndef UNFIXED
    unlockvm();
#endif
    skip;
}

/* ========== Test Scenarios ========== */

/*
 * Scenario 1: FORKNS races with a reader of process 0's name space
 * (devprog, reading /prog/n/ns from another thread).  The reader
 * holds no reference to the pgrp, so FORKNS's closepgrp frees it.
 */
proctype test_forkns_race() {
    /* Initialize */
    atomic {
        pgrp_state[0] = PGRP_VALID;
        pgrp_refcount[0] = 1;  /* process 0's only; the reader has none */
        pgrp_dot[0] = 0;
        pgrp_slash[0] = 1;
        chan_state[0] = CHAN_VALID;
        chan_refcount[0] = 1;
        chan_state[1] = CHAN_VALID;
        chan_refcount[1] = 1;
        chan_state[2] = CHAN_VALID;
        chan_refcount[2] = 1;  /* New channel for new pgrp */
        chan_state[3] = CHAN_VALID;
        chan_refcount[3] = 1;
        process_pgrp[0] = 0;
        process_pgrp[1] = 0;
    }

    /* Run FORKNS and namec concurrently */
    run sys_pctl_forkns(0);
    run namec_reader(0, 0);     /* Read dot */
    run namec_reader(0, 1);     /* Read slash */
}

/*
 * Scenario 2: kchdir races with namec
 */
proctype test_kchdir_race() {
    atomic {
        pgrp_state[0] = PGRP_VALID;
        pgrp_refcount[0] = 1;
        pgrp_dot[0] = 0;
        pgrp_slash[0] = 1;
        chan_state[0] = CHAN_VALID;
        chan_refcount[0] = 1;
        chan_state[1] = CHAN_VALID;
        chan_refcount[1] = 1;
        chan_state[2] = CHAN_VALID;
        chan_refcount[2] = 1;
        process_pgrp[0] = 0;
        process_pgrp[1] = 0;
    }

    /* kchdir changes dot while namec reads it */
    run kchdir(0, 2);          /* Change dot to channel 2 */
    run namec_reader(0, 0);    /* Read dot */
}

init {
    byte i;
    /* Initialize all state */
    atomic {
        for (i : 0 .. (NUM_PGRPS - 1)) {
            pgrp_state[i] = PGRP_FREED;
            pgrp_refcount[i] = 0;
            pgrp_dot[i] = NUM_CHANS;  /* invalid */
            pgrp_slash[i] = NUM_CHANS;
        }
        for (i : 0 .. (NUM_CHANS - 1)) {
            chan_state[i] = CHAN_FREED;
            chan_refcount[i] = 0;
        }
        process_pgrp[0] = 0;
        process_pgrp[1] = 0;
    }

    /* Run test scenarios */
    if
    :: run test_forkns_race();
    :: run test_kchdir_race();
    fi
}

/*
 * LTL properties: no use-after-free of dot, slash or a pgrp.  They
 * hold for the fixed code and are violated with -DUNFIXED.
 */

/* Check if any use-after-free was detected */
ltl no_use_after_free_dot   { [] (!use_after_free_dot) }
ltl no_use_after_free_pgrp  { [] (!use_after_free_pgrp) }
ltl no_use_after_free_slash { [] (!use_after_free_slash) }
