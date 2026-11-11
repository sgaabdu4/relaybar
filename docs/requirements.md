# Requirements

## REQ-POOL-RECOVERY

A combined-accounts flow that can stop part way, such as moving the helper, Stop combining or signing in, saves in the state file each user choice it must apply again later, keyed by account kind and email, and keeps entries for accounts that are not signed in yet. Recovery never starts again what Stop already removed, and leaves no state file when nothing stays combined.

Proof: guidance
