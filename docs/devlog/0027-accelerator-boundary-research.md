# Phase 27: Accelerator Boundary Research

## What Changed

- Added a research-only accelerator boundary decision record.
- Compared Apple `container`, Apple `containerization`, Metal, Core ML, ANE, PyTorch MPS, and MLX documentation against Hostwright's current container boundary.
- Recorded conservative decisions before implementation: reject current Apple-container accelerator claims, defer host-native accelerator helpers to plugin or later prototype work, and block accelerator scheduler dimensions until a proved access path and policy gate exist.
- Added a docs guard test so public docs keep GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, and accelerator scheduling listed as unsupported current behavior.

## Boundaries Preserved

- No GPU, ANE, Metal, Core ML, MLX, or PyTorch MPS implementation.
- No host accelerator device exposure.
- No host-native helper or service.
- No accelerator scheduler scoring or placement.
- No runtime mutation.
- No image pull.
- No dependencies.
- No release tag or GitHub Release.
