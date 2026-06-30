# Source Material Preservation Log

This directory preserves the original project source material used to create the Hostwright repository foundation. These files are historical inputs. They are not public-facing product copy and must not be edited in place.

The original files also remain at the repository root for now because Phase 0 was approved as copy-only preservation. Do not delete or rename the root originals without a separate maintainer approval.

## Preservation Rules

- Preserve original filenames where possible.
- Record old path, preserved path, size, and SHA-256 before using the material.
- Treat old Orchard naming as source-material history only.
- Treat PNG assets as source material only. They are not final transparent/vector production brand assets.

## Preserved Documents

| Old path | Preserved path | Size | SHA-256 |
| --- | --- | ---: | --- |
| `./Orchard_Agent_Engineering_Manual (1).docx` | `docs/source-material/originals/Orchard_Agent_Engineering_Manual (1).docx` | 58804 bytes | `093c29cd640b2da62a5fe28a0d300b2abb7a1a473871b7071c0a052590452c88` |
| `./Orchard_Final_Production_Arsenal.pdf` | `docs/source-material/originals/Orchard_Final_Production_Arsenal.pdf` | 199734 bytes | `b80518866565d465f2df7f071bbb1928955a4ee4dccab1d90f3547bc61e8c392` |
| `./Orchard_Document_2_Security_and_Apple_Silicon_Acceleration.pdf` | `docs/source-material/originals/Orchard_Document_2_Security_and_Apple_Silicon_Acceleration.pdf` | 470963 bytes | `8cc2404440fd50f16f4e64977eedb93d13b0c7c57fe996ad1bde73ae3a6265d6` |
| `./Orchard_Document_3_Network_Tunnels_Protocols_Cloud_Security.pdf` | `docs/source-material/originals/Orchard_Document_3_Network_Tunnels_Protocols_Cloud_Security.pdf` | 475045 bytes | `78bd83b99e0fb8d2a55bda875d1cdf6200fb1eefd585559b9287e7058c779779` |
| `./Hostwright_Naming_Convention_Folder.zip` | `docs/source-material/originals/Hostwright_Naming_Convention_Folder.zip` | 9710 bytes | `b7ef9aaba17528a3d0730b20031b7ee2bc782da358b5c55ba50c7d400a87c673` |

## Preserved Brand Source Assets

| Old path | Preserved path | Size | SHA-256 |
| --- | --- | ---: | --- |
| `./ChatGPT Image Jun 29, 2026, 11_22_44 AM.png` | `assets/brand/originals/ChatGPT Image Jun 29, 2026, 11_22_44 AM.png` | 712612 bytes | `1ad0104a0d7b3f925080758ae63e548544c325edc2667573e1a8d68f5e8f3faf` |
| `./ChatGPT Image Jun 29, 2026, 11_35_08 AM.png` | `assets/brand/originals/ChatGPT Image Jun 29, 2026, 11_35_08 AM.png` | 1091401 bytes | `509e5b751341cce91ac39ea41da6c3717c6a600fd54677e0e89925f92a8059d2` |
| `./ChatGPT Image Jun 29, 2026, 11_37_17 AM.png` | `assets/brand/originals/ChatGPT Image Jun 29, 2026, 11_37_17 AM.png` | 772803 bytes | `3bee747822a5ec6b549570a778b93ecc027925b58812b29447fe603338deb628` |
| `./cc7fa227-8d41-4d45-8432-1b6959410d12.png` | `assets/brand/originals/cc7fa227-8d41-4d45-8432-1b6959410d12.png` | 795184 bytes | `4f75d7805fb298530b4c426e6152ce4d43a655da7579830979ade2ac70b331c5` |

## Verification Commands

```bash
find docs/source-material/originals -type f -print0 | sort -z | xargs -0 shasum -a 256
find assets/brand/originals -type f -print0 | sort -z | xargs -0 shasum -a 256
```

