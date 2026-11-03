# The dependency advisories macaw_data accepts, read by ci/advisories.exs
# (dco-tek/macaw/macaw#214, macaw_data#162). Each entry is one advisory, by an id
# `mix hex.audit` prints for it, and why it does not apply or can't be acted on yet:
#
#   %{advisory: "EEF-CVE-2026-105659", reason: "..."}
#
# An entry the audit no longer reports fails the check. Prefer updating the lock.
[]
