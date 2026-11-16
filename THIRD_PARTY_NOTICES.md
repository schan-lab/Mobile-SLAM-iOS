# Third-party notices

The code in this repository is MIT licensed (see `LICENSE`), except for the
third-party components below, which keep their own licenses.

## Bundled in this repository

### Eigen 3.4.0 (`third_party/eigen`)

- License: Mozilla Public License 2.0 (`third_party/eigen/COPYING.MPL2`).
  A few headers carry BSD-style notices (`COPYING.BSD`, `COPYING.README`).
- Source: https://gitlab.com/libeigen/eigen (tag 3.4.0), unmodified.
- Only the `Eigen/` headers are kept here. The app uses `Eigen/Core` and
  `Eigen/Dense` and is built with `-DEIGEN_MPL2_ONLY`, so no LGPL code is compiled in.

### Zstandard 1.5.7, decompressor only (`third_party/zstd`)

- License: BSD (`third_party/zstd/LICENSE`; zstd is dual BSD / GPLv2, used here under BSD).
- Source: https://github.com/facebook/zstd (release v1.5.7), `lib/common` and `lib/decompress`, unmodified.
  Compiled as one unit by `MobileSLAM/Bridge/ZstdDecoder.c` (same settings as upstream `zstddeclib-in.c`).

### LZ4 1.10.0 (`third_party/lz4`)

- License: BSD 2-Clause (`third_party/lz4/LICENSE`).
- Source: https://github.com/lz4/lz4 (tag v1.10.0), `lib/` files, unmodified.

## Swift packages (fetched by Xcode, not in this repository)

- Citadel 0.12.0 (MIT), https://github.com/orlandos-nl/Citadel. It includes bcrypt / Blowfish code from OpenBSD
  (ISC / BSD-4-Clause, "This product includes software developed by Niels Provos.").
- swift-nio-ssh (Apache 2.0), Citadel's fork at https://github.com/Joannis/swift-nio-ssh.
- swift-nio, swift-crypto (includes BoringSSL), swift-asn1, swift-log, swift-collections, swift-atomics,
  swift-system (Apache 2.0), https://github.com/apple.
- BigInt (MIT), https://github.com/attaswift/BigInt.

The license texts and NOTICE files of everything above are bundled in the app
(`MobileSLAM/ThirdPartyLicenses.txt`, shown in 設定 › このアプリについて).

## Referenced, no code included

- FAST-LIO (W. Xu, F. Zhang, RA-L 2021): the LiDAR-inertial odometry in `core/`
  follows the formulation of the paper. It is an independent implementation and
  contains no code from the FAST-LIO repository.
- Livox Mid-360: the UDP protocol handling is an independent implementation;
  no Livox SDK code is included.
