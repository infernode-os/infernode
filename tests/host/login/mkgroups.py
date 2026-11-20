#!/usr/bin/env python3
"""
The primes of login(6)'s groups, from RFC 3526's own formulas, with no
table copied from anywhere:

    group 14:  p = 2^2048 - 2^1984 - 1 + 2^64 * ([2^1918 pi] + 124476)
    group 15:  p = 2^3072 - 2^3008 - 1 + 2^64 * ([2^2942 pi] + 1690314)
    group 16:  p = 2^4096 - 2^4032 - 1 + 2^64 * ([2^3966 pi] + 240904)

Each is checked to be a safe prime (p and (p-1)/2 prime, Miller-Rabin),
to be 7 mod 8 (so 2 is a square and generates the subgroup of order
(p-1)/2), and to have its top 64 bits set (so a string of len(p) bytes
is a number below p but for one in 2^64: login(6) hides a group element
under a keystream, and a wrong key must give what a right one could).

Prints the hexadecimal strings appl/lib/login.b and tests/login_test.b
hold; `mkgroups.py -c FILE...` checks that every `Pnn: con` of each
Limbo source is group nn's prime.
"""
import re, sys

def pi_scaled(bits):
    """floor(pi * 2^bits), by Machin: pi = 16 atan(1/5) - 4 atan(1/239)"""
    guard = 64
    one = 1 << (bits + guard)
    def atan_inv(x):
        total = term = one // x
        x2 = x * x
        n = 1
        sign = -1
        while term:
            term //= x2
            n += 2
            total += sign * (term // n)
            sign = -sign
        return total
    return (16 * atan_inv(5) - 4 * atan_inv(239)) >> guard

def is_prime(n, rounds=40):
    import random
    if n < 4:
        return n in (2, 3)
    if n % 2 == 0:
        return False
    d, s = n - 1, 0
    while d % 2 == 0:
        d //= 2
        s += 1
    rng = random.Random(3526)
    for _ in range(rounds):
        a = rng.randrange(2, n - 1)
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(s - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True

GROUPS = [(14, 2048, 124476), (15, 3072, 1690314), (16, 4096, 240904)]

def prime(bits, c):
    return (1 << bits) - (1 << (bits - 64)) - 1 + (1 << 64) * (pi_scaled(bits - 130) + c)

def main():
    primes = {}
    for gid, bits, c in GROUPS:
        p = prime(bits, c)
        q = (p - 1) // 2
        assert p.bit_length() == bits
        assert is_prime(p) and is_prime(q), "group %d is not a safe prime" % gid
        assert p % 8 == 7 and pow(2, q, p) == 1, "2 is not of order q in group %d" % gid
        assert p >> (bits - 64) == (1 << 64) - 1 and p & ((1 << 64) - 1) == (1 << 64) - 1
        primes[gid] = "%X" % p
    if len(sys.argv) > 2 and sys.argv[1] == "-c":
        # each `Pnn: con "..."+ "...";` of a Limbo source is group nn's prime
        bad = 0
        for f in sys.argv[2:]:
            text = open(f).read()
            found = re.findall(r'^P(\d+): con\s*((?:"[0-9A-F]+"\s*\+?\s*)+);', text, re.M)
            if not found:
                print("%s: no group's prime" % f)
                bad = 1
            for gid, body in found:
                h = "".join(re.findall(r'"([0-9A-F]+)"', body))
                if primes.get(int(gid)) != h:
                    print("%s: P%s is not RFC 3526's group %s" % (f, gid, gid))
                    bad = 1
                else:
                    print("%s: group %s" % (f, gid))
        sys.exit(bad)
    for gid, bits, c in GROUPS:
        print("group %d (%d bits):" % (gid, bits))
        print(primes[gid])

if __name__ == "__main__":
    main()
