# Draft: systemd upstream issue (not filed; for @snugmo to file)

**Target:** https://github.com/systemd/systemd/issues
**Component:** `systemd-repart`
**Confirmed on:** v259, v262 and `main` (2026-10)

---

## Title

`systemd-repart`: a UUID-only difference is not a change — "No changes." when a partition's UUID should be (re)assigned

## Body

### Description

`systemd-repart` silently does nothing when the only difference between the current
GPT state and the desired (definition-derived) state is a partition **UUID**: it
reports "No changes." and exits, even though `Partition.new_uuid !=
Partition.current_uuid` and the GPT entry on disk does not match the UUID the
definition (or the `--seed=` derivation) would assign.

`context_changed()` (`src/repart/repart.c`, v262 line 4768) decides whether any
change happened at all, and it looks only at allocation and size:

```c
static bool context_changed(const Context *context) {
        assert(context);

        LIST_FOREACH(partitions, p, context->partitions) {
                if (p->dropped)
                        continue;

                if (p->allocated_to_area)
                        return true;

                if (p->new_size != p->current_size)
                        return true;
        }

        return false;
}
```

and the commit path is gated on it (`v262` line 8681):

```c
        if (!context->from_scratch && !context_changed(context)) {
                log_notice("No changes.");
                return 0;
        }
```

A UUID-only difference therefore never reaches the GPT update.

### Reproduction

```sh
$ # 1. a GPT with one data partition, UUID intentionally left null
$ systemd-repart --definitions=defs1 --empty=create --dry-run=no disk.img
$   # defs1/10-part.conf:
$   #   [Partition]
$   #   Type=linux
$   #   Format=ext4
$   #   UUID=null

$ # 2. now assign it a UUID (an explicit one, or a different --seed)
$   # defs2/10-part.conf is the same file plus:
$   #   UUID=12345678-1234-5678-1234-567812345678
$ systemd-repart --definitions=defs2 --dry-run=no disk.img
No changes.

$ sgdisk -i disk.img | grep -A1 "Partition GUID"   # UUID still null
```

The same happens when the desired UUID comes from the seed
(`--seed=…`, i.e. `partition_acquire_uuid()`, the documented
`HMAC-SHA256(seed, TYPE_UUID[||COUNTER])` derivation): a partition created
without that seed (or with `UUID=null`) keeps its current UUID on re-runs with
the seed, because the size and location are unchanged.

### Two related observations

1. **`UUID=` is silently dropped for existing partitions with a non-null UUID.**
   In `context_acquire_partition_uuids_and_labels()` (v262 line ~7887):

   ```c
                   if (!sd_id128_is_null(p->current_uuid))
                           p->new_uuid = uuid = p->current_uuid; /* Never change initialized UUIDs */
                   else if (p->new_uuid_is_set)
                           uuid = p->new_uuid;
   ```

   That safety is reasonable (an in-use UUID is not something to rotate out
   from under a mounted/encrypted filesystem), but when the definition carries
   an *explicit* `UUID=` that differs from the existing one, the explicit
   setting is discarded without any log line. A `log_notice()` when an
   explicitly configured UUID does not match the existing one would make the
   behaviour discoverable.

2. **Derived identifiers are frozen at format time, independent of the GPT
   UUID.** The LUKS2 header UUID (`HMAC-SHA256(partition UUID, "luks-uuid")`)
   and the filesystem UUID (`… "file-system-uuid"`) are computed from the
   partition UUID, but formatting and encryption are skipped for existing
   partitions (`PARTITION_EXISTS(p)`, "Never format existing partitions",
   `context_mkfs()`/`context_encrypt()`). So even if a run *did* update the
   GPT UUID of an already-formatted encrypted partition (e.g. the null →
   assigned case above, if `context_changed()` noticed it), the LUKS2 header
   would keep the UUID derived from the *old* partition UUID, and
   `luks-uuid`/`file-system-uuid` would no longer be a function of the on-disk
   partition UUID as the man page describes.

### Impact

The documented seed derivation (`systemd.repart(5)`: the partition UUID is
`HMAC-SHA256` of the partition type, keyed on the seed, generally the machine
ID) is only applied at *creation*. A tool that wants to bring a pre-existing
disk under a seed (e.g. an installer that generates the machine ID *before*
wiping, so that every UUID on the target is a deterministic function of one
value, and then re-runs repart against the wiped disk) cannot do this: the
re-run sees equal sizes, says "No changes.", and the disk keeps whatever UUIDs
it had. There is no supported two-phase path either (create with `UUID=null`,
then assign), for the reasons above.

### Proposed fix

- include `!sd_id128_equal(p->new_uuid, p->current_uuid)` among the change
  conditions in `context_changed()`;
- when the GPT UUID of an existing partition is updated as a result, either
  re-derive (and re-write) the LUKS2 header / filesystem UUID to keep them a
  function of the partition UUID, or document that the GPT UUID of an
  already-formatted partition is immutable and make `UUID=` on such a
  partition an error (or at least a loud warning) when it conflicts.

### Environment

Observed with systemd 259.9 and 262 on Fedora 45, x86-64; the relevant code is
unchanged on `main`.

---

*Context: inglenook's installer generates the machine id before partitioning
and passes it as `--seed=`, so all UUIDs (partition, LUKS2, filesystem) are
deterministic at creation time and no post-hoc UUID re-assignment is needed —
the workaround is "seed before you create", which this issue does not
preclude, but the two behaviours above are worth reporting regardless.*
