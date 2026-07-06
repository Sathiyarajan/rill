# Contributing to Rill

Thanks for looking at this project. Rill is a **local, single-GPU practice lab**
for GenAI-on-Kubernetes patterns (vLLM, TGI, KServe, monitoring) — the goal is
a runnable teaching/learning tool, not a production system. Keep that framing
in mind when proposing changes.

## Project status

**Incubating** — see [NOTICE](NOTICE). Expect breaking changes to manifests,
scripts, and defaults as the project matures. Not an ASF project.

## Before you start

1. Read [README.md](README.md) in full, especially:
   - "How GPU passthrough actually works here" — the layered GPU-passthrough
     design is the trickiest part of this repo; most contributions that touch
     `kind-config.yaml` or `setup/02-create-cluster.sh` interact with it.
   - The troubleshooting log (21 numbered issues at time of writing) —
     check it before reporting something as a new bug; it may already be a
     documented, dated limitation (e.g. TGI's GPU-arch issue, #18).
2. This repo assumes Windows 11 + WSL2 + Docker Desktop + a single NVIDIA GPU.
   If you're on native Linux or a different GPU vendor, some of the
   WSL2-specific workarounds (containerd RuntimeClass split, `LIBRARY_PATH`
   fix, memory-utilization tuning) won't apply as written — call that out
   explicitly in your PR description rather than silently removing them.

## What's easy to contribute

- **New troubleshooting log entries** — if you hit something not already
  documented, add it in the same format (numbered, root cause + fix +
  general lesson). This is the single most useful thing to contribute.
- **Additional Grafana panels** — `monitoring/grafana-dashboard-vllm.json`,
  documented in the README's panel table. Verify against a live vLLM
  `/metrics` endpoint before submitting (metric names are vLLM-version-specific,
  see the note at the end of the monitoring section).
- **Alternate model configs** — smaller/larger models, different quantization,
  as long as they're documented with the VRAM math that justifies the
  `--gpu-memory-utilization` / `--max-model-len` values chosen (see
  troubleshooting #13-15 for why this matters more than it looks).
- **Fixing the TGI limitation** (#18) — if HuggingFace ships a TGI image with
  `sm_120` (or your GPU's arch) kernel support, or you find a real workaround,
  this is the most valuable open problem in the repo.

## What needs more discussion first

- **Cloud deployment (AWS/EKS, Azure/AKS, GCP/GKE) via Terraform** — see the
  "Roadmap" section in README.md for the intended design direction. Open an
  issue describing your approach before submitting a large PR — this is a
  significant scope expansion from "local single-GPU lab" and needs agreement
  on module boundaries (networking, GPU node pools, IAM/RBAC, cost controls)
  before code.
- **Multi-GPU / tensor-parallel support** — every manifest today hard-codes
  `nvidia.com/gpu: 1` intentionally (see each manifest's "PRODUCTION
  DIFFERENCE" comments). Making this configurable is welcome but should keep
  the single-GPU path as the well-tested default, not a special case.

## Style conventions already in use (please match them)

- Every manifest documents, inline, what a production/multi-GPU setup would
  add that this lab intentionally skips ("PRODUCTION DIFFERENCE" comments).
  New manifests should do the same.
- Scripts under `setup/` and `scripts/` must be idempotent — safe to re-run
  without erroring if resources already exist. Check existing scripts for the
  pattern (`if kubectl get ... &>/dev/null; then log "already exists,
  skipping"; else ...; fi`).
- GPU resource requests are always exactly `nvidia.com/gpu: 1` — never higher,
  given the one-GPU constraint this whole repo is designed around.

## Submitting changes

1. Fork, branch, make your change.
2. If you touched a manifest or script, actually run it against a real kind
   cluster on your hardware — this repo has already been burned once by
   "looks right, never actually tested against a live cluster" (see
   troubleshooting log). Paste the actual command output in your PR
   description, not just a description of what should happen.
3. Update README.md's relevant section (setup flow, troubleshooting log,
   inference stack reference table) in the same PR as the code change —
   don't leave documentation for a follow-up.
4. Open the PR against `main` with a clear description of what hardware/GPU
   you tested on.

## Code of conduct

Be direct, be kind, assume good faith. Debugging GPU passthrough through
three nested virtualization layers is hard enough without also being
unpleasant to work with.
