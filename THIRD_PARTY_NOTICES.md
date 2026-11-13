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

## Referenced, no code included

- FAST-LIO (W. Xu, F. Zhang, RA-L 2021): the LiDAR-inertial odometry in `core/`
  follows the formulation of the paper. It is an independent implementation and
  contains no code from the FAST-LIO repository.
- Livox Mid-360: the UDP protocol handling is an independent implementation;
  no Livox SDK code is included.
