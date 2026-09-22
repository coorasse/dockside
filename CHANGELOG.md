# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-22

### Added

- Compose-file based configuration of the containers a Rails app needs.
- Automatic start of the containers in development and test.
- Readiness probes that wait until the containers are ready.
- `after_start` hooks to provision containers the first time they start.
- Reset of the containers and their data.
- Rake tasks to start, stop and reset the containers.
- Install generator.

[Unreleased]: https://github.com/coorasse/dockside/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/coorasse/dockside/releases/tag/v0.1.0
