# dockside gem: interface and implementation plan

## Context

Mugshotbot and shikigamiya both need sidecar containers in development and test (an html2img screenshot
server, a Redmine instance). Each app currently carries its own compose file, a bespoke start script
(`bin/start_html2img`, `bin/start_redmine`) and a spec hook that spins the container up. No existing gem covers
this: `testcontainers` is test-only, ephemeral and cannot build images; the `docker-compose` gem targets the dead
v1 binary. We extract the behaviour into a new gem, `dockside` (name free on RubyGems), living at
`~/RenuoWorkspace/dockside`. Once approved, this document is copied into that folder as `PLAN.md`
and a separate agent builds the gem from it.

Decisions taken with the user:

- The configuration **is a Docker Compose file** (`config/dockside.yml`). Compose already expresses
  image, build (including git contexts), ports, env and volumes. The gem adds only what compose lacks:
  environment selection, automatic idempotent start with readiness, post-start provisioning, reset, and the
  Rails hooks. Every command can be reproduced with plain `docker compose`.
- Per-environment differences live in an environment block inside the service's `x-dockside` key,
  so one file covers development and test.
- The gem manages containers only. It does **not** feed URLs or tokens into the app. The app keeps its own
  configuration (ENV, `.env.test`, credentials) and duplicates the port there.
- The app never calls the gem. Dependencies are up before the app serves in development (`rails server`, so
  also `bin/dev`) and before the first test runs in test. A test run that would not need them still starts
  them; that is accepted for the sake of simplicity.
- Development and test use separate containers (separate compose projects) on different host ports.
- v1 covers shikigamiya's provisioning needs: `after_start` steps, volumes, `reset`, `exec`.

## 1. What each app ends up with

### Mugshotbot

`Gemfile`, in `group :development, :test`:

```ruby
gem "dockside"
```

`config/dockside.yml`, the whole file:

```yaml
services:
  html2img:
    build: https://github.com/renuo/html2img-server.git
    environment:
      API_TOKEN: test-token
    ports: ["8080:8080"]
    x-dockside:
      test:
        ports: ["8081:8080"]
```

Everything above `x-dockside` is ordinary compose and applies to every environment. The `test:`
block holds what differs in the test environment: the test container publishes host port 8081 instead of 8080,
so the development and test containers can run at the same time. Anything a service accepts can go in such a
block (`environment`, `volumes`, `image`, ...), and lists inside it replace the shared value instead of
appending. Only the environments that differ need a block.

`.env.test` (app-side, port duplicated on purpose):

```
HETZNER_RENDER_URL=http://html2img.localhost:8081
HETZNER_RENDER_TOKEN=test-token
```

That is all. `rails server` starts html2img before serving, and the test suite starts it before the first
example. Readiness needs no config: the gem waits for the container to run and for its port to accept
connections.

Deleted: `compose.yml`, `bin/start_html2img`, the `:html2img` hook in `spec/support/vcr.rb` and the
`:html2img` tag on the renderer spec. Consequence for CI: Semaphore builds and starts html2img on every run
(the machine has Docker; the first build takes a few minutes, later runs can use a published image or a cached
layer store).

### Shikigamiya

`Gemfile`, in `group :development, :test`:

```ruby
gem "dockside"
```

`config/dockside.yml`, the whole file:

```yaml
services:
  redmine:
    image: ghcr.io/renuo/shikigamiya-redmine:latest
    build:
      context: .
      dockerfile: Dockerfile.redmine
    environment:
      REDMINE_SECRET_KEY_BASE: test_secret_key_base_for_development
      SECRET_KEY_BASE: test_secret_key_base_for_development
    ports: ["4000:3000"]
    volumes:
      - ./tmp/dockside/${RAILS_ENV}/redmine/files:/usr/src/redmine/files
      - ./tmp/dockside/${RAILS_ENV}/redmine/sqlite:/usr/src/redmine/sqlite
    x-dockside:
      after_start:
        - exec: bundle exec rake redmine:load_default_data
          environment: { REDMINE_LANG: en }
          allow_failure: true
        - exec: bundle exec rails runner -
          stdin: bin/setup_redmine.rb
      test:
        ports: ["4001:3000"]
```

Why it is this short: `docker compose exec` runs in the image's `WORKDIR` (`/usr/src/redmine`) with the image's
`RAILS_ENV=production`, so no `cd` and no env repetition; `SECRET_KEY_BASE` is set once on the service so exec'd
commands see it; `${RAILS_ENV}` is provided by the gem when it invokes compose, so one volume line serves both
environments; the setup script reads its external port from `DOCKSIDE_PORT`, which the gem injects
into every provisioning step.

Deleted: `docker-compose.yml`, `bin/start_redmine`, `app/services/redmine_docker.rb`, the `before(:suite)`
line in `spec/rails_helper.rb`. Redmine is up before the suite starts and before `rails server` serves. The two
places that ran Ruby inside the container (`db/seeds.rb` generating an API key,
`spec/support/redmine_webhook_helpers.rb` repointing webhooks) call
`Dockside.redmine.exec("bundle exec rails runner -", stdin: script)` directly.
The test-data cleanup helpers are plain Redmine HTTP calls and move to `spec/support/redmine_cleanup.rb`.
`bin/setup_redmine.rb` changes one line to read `DOCKSIDE_PORT`. CI prologue:
`RAILS_ENV=test bin/rails "dockside:reset[redmine]"`.

## 2. Configuration reference

`config/dockside.yml` is a standard Compose file. The gem reads one extension key per service,
`x-dockside`, which compose itself ignores:

| Key | Default | Meaning |
|---|---|---|
| `development:` / `test:` | – | Environment block. Any compose service key or `x-dockside` key inside it overrides the service for that environment. Lists such as `ports` replace rather than append. |
| `ready` | `auto` | `auto` = `compose up --wait` (healthy if the service has a healthcheck, else running) followed by a TCP connect on the first published port. Also `{http: "/path"}` (any HTTP response, optional `status:`), `{log: "regex"}`, `{command: [...]}`, `none`. |
| `timeout` | `300` | Seconds for `--wait-timeout` and the host-side probe. |
| `after_start` | `[]` | Provisioning steps, see section 4. |
| `autostart` | `true` | `false`: not started on server boot or suite start; only via rake tasks or `Dockside.ensure_running!`. |

Conventions the gem applies without configuration:

- Compose project `<app>-<env>` (`<app>` = Rails application name, underscored and dasherized), so each
  environment has its own containers, networks and named volumes. Compose names containers
  `<app>-<env>-<service>-1`; `container_name` in the file is rejected because it would collide.
- `--project-directory Rails.root`: relative build contexts and bind mounts resolve from the app root.
- `RAILS_ENV` and `DOCKSIDE_ENV` are set for `${...}` interpolation.
- A service with `build` and no `image` is tagged `<app>-<service>`, shared by both environments, so the image
  builds once.
- `extra_hosts: host.docker.internal:host-gateway` is added to every service (Linux parity with Docker Desktop).
- Host ports may be shared between environments. When a service maps the same host port in development and
  test, the registry logs a warning at load (the environments share data) and the service is marked
  `shared`; see the start sequence and section 8.
- `config/dockside.<env>.yml`, when present, is applied as a compose override file after the main
  file and before the environment block, for those who prefer separate files (compose append rules apply there).

## 3. Ruby API

Nothing in section 1 needs it; it exists for scripts, seeds and provisioning helpers.

```ruby
Dockside.registry                      # Dockside::Registry for Rails.env (#fetch, #[], #each, #names)
Dockside.redmine                       # Dependency; Dockside.fetch(:redmine) for dynamic names
Dockside.names                         # registry delegators; method_missing resolves service names
Dockside.ensure_running!(*names)       # no names = autostart dependencies; blocking, idempotent
Dockside.down                          # compose down for the current env, keeps volumes

Dependency#name #env #port (first published host port) #container_port #container_name #url #autostart?
Dependency#running? #ready?
Dependency#start(build: false, pull: false) #ensure_running! #stop #reset
Dependency#exec(cmd, environment: {}, stdin: nil, workdir: nil, user: nil, allow_failure: false) → stdout
Dependency#logs(tail: 100)
```

`Dependency#url` is `http://localhost:<port>`, a convenience for scripts and `status`; the app does not read it.
`Dockside.runner=` injects a command runner (test seam). Errors under `Dockside::Error`:
`ConfigError`, `UnknownDependency`, `DockerMissing`, `DockerUnavailable`, `ComposeMissing`, `CommandFailed`
(exposes `stderr`), `ReadyTimeout`, `PortInUse`. Messages are actionable, for example
`html2img (test) did not become ready within 300s. Last 50 log lines: ...`.

## 4. Behaviour

**Resolution.** The gem writes `tmp/dockside/<env>/override.yml` from the environment block and
its conventions (project name, image tag, extra_hosts, `!override` on replaced lists), then runs
`docker compose ... config --format json` to obtain the resolved services. This reuses compose's own merge and
interpolation rules instead of reimplementing them. The registry is built lazily, on first use.

**Compose invocation.** Every call is
`docker compose -p <app>-<env> --project-directory <root> -f config/dockside.yml
[-f config/dockside.<env>.yml] -f tmp/dockside/<env>/override.yml <command>`, run through
`Open3` with argv arrays, never shell strings. `dockside:config` prints the resolved YAML so any
command can be reproduced by hand.

**Start sequence** (`Dependency#start`, under a `flock` on `tmp/dockside/<env>/.lock`):

1. Preflight once per process: `docker version`, `docker compose version` (v2 plugin; v1 only raises
   `ComposeMissing`).
2. Create host directories for bind mounts whose source lies under `Rails.root` (mode 777, so containers running
   as another uid can write).
3. Regenerate the override file and the resolved config; note whether the resolved config changed.
4. Fast path: unchanged, container running, readiness probe passes → log `html2img already running at
   http://localhost:8081` and return without calling compose.
   For a `shared` service, also look for a running container of this app in the other environment
   (`docker ps --filter label=com.docker.compose.project=<app>-<other-env>
   --filter label=com.docker.compose.service=<service>`). If found and the probe passes, log
   `html2img shared with development at http://localhost:8080` and return; `after_start` is skipped because
   the creating environment already ran it.
5. `compose up -d --wait --wait-timeout <timeout> [--build] [--pull always] <service>`, output streamed so build
   progress is visible. A non-zero exit dumps the last 50 log lines and raises (`PortInUse` when the daemon
   reports an allocated port).
6. Host-side probe from `ready` (TCP by default), polled every second until `timeout`.
7. Run `after_start` steps if due.
8. Log `html2img ready at http://localhost:8081`.

**after_start.** Runs once per container instance: a marker `tmp/dockside/<env>/<service>.provisioned`
stores the container ID and steps run when it is missing or differs. Recreation after a config change or `reset`
re-runs them; a plain restart does not. The marker is written only after all steps succeed. Step keys:
`exec` (String → `sh -c`, Array → argv, via `docker compose exec`), `run` (host command from `Rails.root`),
`environment`, `workdir`, `user`, `stdin` (host file piped through `exec -T`), `allow_failure` (default false),
`always` (default false). Every step's environment also receives `DOCKSIDE_NAME`, `_ENV`, `_PORT`,
`_URL` and `_CONTAINER`.

**reset.** `compose rm -sfv <service>`, remove the project's named volumes used by the service, `rm -rf` bind
mount sources that lie under `Rails.root/tmp` (never anything else), delete the marker. The rake task then starts
the dependency again, matching today's `bin/start_redmine --reset`.

**Development auto-start.** The Railtie runs `Dockside.ensure_running!` in `after_initialize` when
`Rails.env.development?`, the process booted through `rails server` (`Rails::Server` defined, which covers
`bin/dev` via foreman), and `ENV["DOCKSIDE_AUTOSTART"] != "0"`. Boot blocks until every `autostart:
true` dependency is ready; progress prints to the console. Console, runner, rake and generators never start
anything.

**Test auto-start.** In `Rails.env.test?` the Railtie, in `after_initialize`, registers
`RSpec.configure { |c| c.before(:suite) { Dockside.ensure_running! } }` when RSpec is loaded, or a
Minitest `Rails::TestUnit` `before_run` equivalent when Minitest is loaded. Same `DOCKSIDE_AUTOSTART=0`
opt-out. Nothing to require in `rails_helper.rb`.

**Rake tasks** (`dockside:` namespace, all depend on `:environment`, so `RAILS_ENV=test` selects the
test project): `up[names]` (`BUILD=1`, `PULL=1`), `down`, `stop[names]`, `status` (name, container, state,
health, url, autostart), `reset[names]`, `logs[name]` (`TAIL`, `FOLLOW=1`), `config` (resolved compose YAML).

**Generator.** `bin/rails g dockside:install` writes a commented `config/dockside.yml`.

## 5. Gem layout

```
dockside.gemspec   authors Alessandro Rodi, alessandro.rodi@renuo.ch, MIT,
                              homepage https://github.com/coorasse/dockside, required_ruby >= 3.2,
                              runtime dep railties >= 7.1; dev: rspec-rails, ammeter, standard, simplecov, webmock
Gemfile  Rakefile  .rspec  .standard.yml  .gitignore  README.md  CHANGELOG.md  LICENSE.txt
bin/check (rspec)  bin/fastcheck (standardrb)  bin/rails (spec/dummy)  bin/setup  bin/console
.github/workflows/ci.yml
lib/dockside.rb                 Zeitwerk loader, module API, requires railtie when Rails is present
lib/dockside/version.rb
lib/dockside/errors.rb
lib/dockside/project.rb         file discovery, project name, override generation, resolved config
lib/dockside/registry.rb        Registry behind Dockside.<service>, validation
lib/dockside/dependency.rb      start/stop/reset/exec orchestration, fast path, flock
lib/dockside/compose.rb         docker compose command wrappers (config, up, stop, rm, down, exec, logs)
lib/dockside/docker.rb          preflight, inspect, volume rm
lib/dockside/runner.rb          Open3 capture and streaming runs, error mapping
lib/dockside/readiness.rb       Tcp/Http/Log/Command/None probes and the waiter
lib/dockside/provisioner.rb     after_start steps and marker handling
lib/dockside/railtie.rb         config object, dev auto-start, test hook, rake_tasks, generators
lib/tasks/dockside.rake
lib/generators/dockside/install_generator.rb + templates/dockside.yml.tt
spec/spec_helper.rb  spec/rails_helper.rb  spec/dummy/ (minimal Rails app, no database)
spec/support/fake_runner.rb  spec/fixtures/ (compose files and resolved-config JSON)
spec/dockside/*_spec.rb  spec/railtie_spec.rb  spec/tasks_spec.rb  spec/generators/*_spec.rb
spec/integration/real_docker_spec.rb (tag :docker)
```

Patterns to copy: argv-based `Open3.capture3` with raise-on-failure and readiness polling from
`shikigamiya/app/services/actions/services/docker_postgres.rb`; ammeter generator specs from
`rails_api_logger/spec/generators/install_generator_spec.rb`; CI layout from `onlylogs/.github/workflows/ci.yml`.

## 6. Testing the gem

- `FakeRunner` records every argv and answers from ordered stubs (including canned `config --format json`
  output from `spec/fixtures`); unmatched commands raise. Injected via `Dockside.runner=`.
- Unit specs: project (environment block to override with `!override`, image defaulting, host-gateway,
  `container_name` rejected, host port uniqueness, optional env file discovery), registry, dependency (fast path
  issues no `up`, changed config triggers `up`, `build:`/`pull:` flags, flock), readiness (Tcp against a local
  `TCPServer`, Http via WebMock, Log/Command via FakeRunner, timeout raises with logs), provisioner (marker
  semantics, `always`, `allow_failure`, `stdin`, injected `DOCKSIDE_*` env), runner (error mapping).
- Rails specs with `spec/dummy`: registry on `Rails.configuration`, auto-start fires only with `Rails::Server` in
  development, `before(:suite)` registered only in test, opt-out env var, rake tasks against FakeRunner,
  generator.
- Integration `spec/integration/real_docker_spec.rb`, tag `:docker`, excluded unless `DOCKER=1`: `nginx:alpine`
  with `ready: {http: /}` and `hashicorp/http-echo` with default readiness on high ports. Covers start, fast
  path, `after_start` once, `exec` with stdin, bind mount created under tmp and wiped by `reset`, `stop`, `down`.
- CI: `lint` (standardrb), `test` matrix over Rails 7.1 to 8.1 gemfiles via Appraisal, `integration` job with
  `DOCKER=1` on ubuntu-latest.

## 7. Consumer migrations (after the gem exists)

Mugshotbot: apply section 1; re-record
`spec/support/fixtures/vcr_cassettes/HetznerImageRenderer/_render/renders_the_image.yml` (port moves to 8081);
point the README html2img section and the CLAUDE.md renderer line at the gem's rake tasks; confirm the
Semaphore test job can build the image within its time limit, otherwise publish `html2img-server` to ghcr and
switch the service to `image:`.

Shikigamiya: apply section 1; data moves from `redmine_data/<env>` to `tmp/dockside/<env>/redmine`
(copy the old sqlite file across or let provisioning reseed); update `bin/setup`, `bin/reset`, `.gitignore`,
README, `.semaphore/semaphore.yml`; `spec/rails_helper.rb` derives the WebMock allow list port from
`Dockside.redmine.port`.

## 8. Edge cases to handle

- A service with the same host port in both environments is `shared`: a warning at registry load, the first
  environment to start creates the container, the other reuses it (fast path above). `reset` and `down` remove
  the container regardless of which environment created it. `status` shows `shared with <env>`.
- A foreign process on the port raises `PortInUse` with a `docker ps` hint. A container of the same app in
  another environment is not foreign; it either counts as shared (above) or, when the ports differ and it still
  holds the port, is reported in the hint.
- Dev server and test suite run side by side: separate projects, containers, ports, data directories; the built
  image is shared; the flock is per environment.
- Linux lacks `host.docker.internal`; always injected through the generated override.
- Readiness always probes `127.0.0.1`; custom hostnames such as `html2img.localhost` are the app's concern.
- Two checkouts of the same app share project names; documented limitation.
- Missing Docker fails fast at boot or suite start with a clear message and the `DOCKSIDE_AUTOSTART=0`
  escape hatch.
- Environment blocks replace lists (`ports`, `volumes`); separate `.<env>.yml` files follow compose's append
  rule, documented in the README.

## 9. Implementation steps for this plan

1. Create `~/RenuoWorkspace/dockside/` and write this document there as `PLAN.md`.
2. Hand off to the building agent with the instruction to follow `PLAN.md`, then migrate mugshotbot and
   shikigamiya as described in sections 1 and 7.

## Verification

- Gem: `bin/fastcheck` and `bin/check` pass; `DOCKER=1 bin/check` passes the integration spec locally.
- Mugshotbot: delete the html2img cassette, run `bundle exec rspec spec/models/hetzner_image_renderer_spec.rb`,
  observe the container start on port 8081 before the example and the cassette record; run again, the fast path
  reports it already running and the cassette replays; `bin/dev` boots the container automatically;
  `bin/check_linters` passes.
- Shikigamiya: `RAILS_ENV=test bin/rails "dockside:reset[redmine]"` reseeds Redmine on 4001;
  `bin/check` passes with Redmine started at suite start; `bin/dev` brings up Redmine on 4000.
