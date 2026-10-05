#!/bin/sh
# Forced command for a stats_collector_ssh_keys entry (see terraform/variables.tf).
#
# Prints dnsdist's process-wide counters and nothing else. Whatever command the
# client sends is ignored, so a key pinned to this cannot open a shell on a
# resolver, forward a port, or read a file - it can only produce this output.
#
# What that output contains is bounded by the node, not by this script: query
# and response totals, cache hits and misses, latency buckets, per-rule hit
# counts. There is no client address and no query name in it. With
# dynblock_ring_entries = 0 the ring buffers are off, so grepq() and
# topQueries() have nothing to return and no per-client record exists on the
# node to leak. unbound statistics stay off, asserted by bin/privacy-audit.sh.
#
# This is the same aggregate surface privacy-audit.sh already reads for its own
# cache-hits/cache-misses line, which is why collecting it needs no change to
# dnsdist's configuration and leaves `make audit` reporting exactly what it did
# before.
#
# The console is controlSocket("127.0.0.1:5199"), loopback only, so this has to
# run on the node - which is why a key is involved at all.
set -eu

exec dnsdist -c -e 'dumpStats()'
