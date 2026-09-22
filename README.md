# dockside

[![Build Status](https://coorasse.semaphoreci.com/badges/dockside/branches/main.svg)](https://coorasse.semaphoreci.com/projects/dockside)
[![Gem Version](https://badge.fury.io/rb/dockside.svg)](https://rubygems.org/gems/dockside)

Starts the Docker containers your Rails app needs, when your app starts.

## The problem

Your app uses services that are not part of your app. An S3 bucket for uploads. A search engine. A login server.
In production these are hosted somewhere. On your machine, you run them in Docker.

Docker Compose describes the containers. But it does not start them for you. Before you run the server or the
tests, you have to remember to run `docker compose up`. Then you wait until the service really answers.
And if the server and the tests share a container, the tests wipe the data you were looking at.

## dockside to the rescue

You describe the containers in a compose file. The gem does the rest:

- starts the containers when you run `rails server` or the test suite
- waits until they are ready
- sets them up the first time (creates the bucket, loads the data)
- keeps one set of containers for development and another for test
- does nothing when they are already running

```yaml
# config/dockside.yml
services:
  minio:
    image: minio/minio
    command: server /data
    ports: ["9000:9000"]
    x-dockside:
      test:
        ports: ["9010:9000"]
```

This is a normal compose file that follows the
[Compose Specification](https://docs.docker.com/reference/compose-file/). The gem only reads the `x-dockside`
part, which is an [extension field](https://docs.docker.com/reference/compose-file/extension/). Compose ignores
extension fields, so `docker compose` can read the same file. See
[Using plain docker compose](#using-plain-docker-compose).

## Installation

```ruby
# Gemfile
group :development, :test do
  gem "dockside"
end
```

```sh
bundle install
bin/rails generate dockside:install
```

You need Docker with `docker compose`.

## Example: an S3 bucket for Active Storage

[MinIO](https://min.io) is an S3 server that runs in one container. Here is the compose file. The two `exec` lines
create the bucket after the container starts:

```yaml
# config/dockside.yml
services:
  minio:
    image: minio/minio
    command: server /data
    environment:
      MINIO_ROOT_USER: minio
      MINIO_ROOT_PASSWORD: minio-secret
    ports: ["9000:9000"]
    x-dockside:
      after_start:
        - exec: mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
        - exec: mc mb --ignore-existing local/uploads
      test:
        ports: ["9010:9000"]
```

Tell Active Storage where to find it. The gem does not do this for you. Your app keeps its own settings:

```yaml
# config/storage.yml
minio:
  service: S3
  endpoint: http://localhost:9000
  access_key_id: minio
  secret_access_key: minio-secret
  region: us-east-1
  bucket: uploads
  force_path_style: true

minio_test:
  service: S3
  endpoint: http://localhost:9010
  access_key_id: minio
  secret_access_key: minio-secret
  region: us-east-1
  bucket: uploads
  force_path_style: true
```

```ruby
# config/environments/development.rb
config.active_storage.service = :minio

# config/environments/test.rb
config.active_storage.service = :minio_test
```

Now start the server:

```
$ bin/rails server
dockside: starting minio (development)
 ✔ Container my-app-development-minio-1  Started
dockside: minio ready at http://localhost:9000
=> Booting Puma
```

Or run the tests:

```
$ bundle exec rspec
dockside: starting minio (test)
 ✔ Container my-app-test-minio-1  Started
dockside: minio ready at http://localhost:9010
```

Next time, the container is already there:

```
dockside: minio already running at http://localhost:9000
```

## Development and test

The server and the tests often run at the same time. Usually you want each one to have its own container, so
the tests cannot touch the data you are looking at in the browser. Two containers cannot use the same port on
your machine. That is why the `test:` block gives the test container another port.

Everything outside `x-dockside` is normal compose and is the same in every environment. The `test:`
block (or a `development:` block) holds only what is different. You can put any
[service setting](https://docs.docker.com/reference/compose-file/services/) in it.

Here, development keeps the uploaded files on disk. Test starts with an empty store every time:

```yaml
services:
  minio:
    image: minio/minio
    command: server /data
    ports: ["9000:9000"]
    volumes:
      - ./tmp/dockside/minio:/data
    x-dockside:
      test:
        ports: ["9010:9000"]
        volumes: []
```

A list inside the block replaces the list outside. The test container only has port 9010, and no volumes.

### One container for both

You do not have to split them. Leave the `test:` block out and development and test share one container:

```yaml
services:
  mailpit:
    image: axllent/mailpit
    ports: ["8025:8025", "1025:1025"]
```

The gem prints a warning when it loads the file, because the two environments now see the same data. Whoever
starts first creates the container. The other environment finds the port answered by a container of the same
app and uses it instead of starting a second one. `after_start` runs once, on whoever created it. A reset from
either environment removes the container for both.

This is fine for services without state, such as a mail catcher or a renderer. For a database or an S3 store,
give test its own port.

## Building your own image

If the service needs your own Dockerfile, use [`build`](https://docs.docker.com/reference/compose-file/build/)
like in any compose file:

```yaml
services:
  keycloak:
    build:
      context: .
      dockerfile: Dockerfile.keycloak
    ports: ["8080:8080"]
    x-dockside:
      test:
        ports: ["8081:8080"]
```

You can also build from a git URL:

```yaml
services:
  renderer:
    build: https://github.com/my-org/renderer.git#main
```

The image is built the first time. Development and test share it. To build it again:

```sh
BUILD=1 bin/rails dockside:up[keycloak]
```

## Waiting until ready

The gem waits until the container runs and its first port accepts a connection that stays open. (Docker accepts
connections on a published port before the service inside listens, but closes them at once.) For most services
that is enough.

Some services open the port before they are ready to answer. Then tell the gem what to check:

```yaml
services:
  minio:
    image: minio/minio
    command: server /data
    ports: ["9000:9000"]
    x-dockside:
      ready: { http: "/minio/health/live" }
      timeout: 60
      test:
        ports: ["9010:9000"]
```

You can wait for:

- `{ http: "/path" }`: the URL answers. Add `status: 200` if the status matters.
- `{ log: "some text" }`: the container log contains the text (a regular expression).
- `{ command: ["sh", "-c", "..."] }`: the command succeeds inside the container.
- `none`: do not wait for anything beyond the container running.

`timeout` is in seconds and defaults to 300. When time runs out, the gem raises an error with the last lines of
the container log.

## Keeping data

[Volumes](https://docs.docker.com/reference/compose-file/services/#volumes) work like in compose. Use a folder
under `tmp/` so the data survives a restart but is not committed:

```yaml
services:
  minio:
    image: minio/minio
    command: server /data
    ports: ["9000:9000"]
    volumes:
      - ./tmp/dockside/${RAILS_ENV}/minio:/data
    x-dockside:
      test:
        ports: ["9010:9000"]
```

The gem sets `RAILS_ENV` for compose, so
[interpolation](https://docs.docker.com/reference/compose-file/interpolation/) gives development and test their
own folder from this one line. The gem also creates the folder before the container starts.

## Setting up the container

A new container is usually empty. The bucket is missing, the users are missing, the data is missing.
`after_start` lists the commands that fix that. The gem runs them once, after the container is ready:

```yaml
services:
  minio:
    image: minio/minio
    command: server /data
    environment:
      MINIO_ROOT_USER: minio
      MINIO_ROOT_PASSWORD: minio-secret
    ports: ["9000:9000"]
    x-dockside:
      after_start:
        - exec: mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
        - exec: mc mb --ignore-existing local/uploads
        - exec: mc admin policy create local uploads /dev/stdin
          stdin: config/minio/uploads_policy.json
          allow_failure: true
      test:
        ports: ["9010:9000"]
```

- `exec:` runs a command inside the container.
- `run:` runs a command on your machine, in the app folder. Use it for Ruby scripts, for example
  `run: bin/rails runner script/seed_minio.rb`.
- `stdin:` sends a file from your app into the command.
- `allow_failure: true` moves on when the command fails.
- `always: true` runs the command on every start, not only the first time.
- `environment:`, `workdir:` and `user:` do what they do in compose.

Commands inside the container see the environment variables of the service. That is why `$MINIO_ROOT_USER` works
above. Every command also gets `DOCKSIDE_PORT`, `DOCKSIDE_URL` and `DOCKSIDE_CONTAINER`,
so a script knows which container it is talking to.

"Once" means once per container. Restarting the same container does not run the commands again. A new container
(after a config change, a rebuild or a reset) does.

## Starting over

When the data in a container is a mess, reset it:

```sh
bin/rails dockside:reset[minio]
RAILS_ENV=test bin/rails dockside:reset[minio]
```

This removes the container, its volumes and everything in its data folders under `tmp/`, then starts it again.
The `after_start` commands run again on the empty container.

## Running a command in a container from Ruby

```ruby
minio = Dockside.minio
minio.exec("mc rm --recursive --force local/uploads")
```

`exec` returns the output. If the command fails, it raises an error. It takes the same options as `after_start`:
`environment:`, `stdin:` (a string here), `workdir:`, `user:`, `allow_failure:`.

## When containers start

- In development: when you run `rails server`. The console, `rails runner` and rake tasks do not start anything.
- In test: before the first test, with RSpec or Minitest. You do not need to add anything to your test setup.

The app waits until every container is ready. In test, the containers start even if no test needs them.

To keep a container out of this, set `autostart: false`. Then it only starts when you ask:

```yaml
services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    command: start-dev
    ports: ["8080:8080"]
    x-dockside:
      autostart: false
      test:
        ports: ["8081:8080"]
```

```sh
bin/rails dockside:up[keycloak]
```

```ruby
Dockside.ensure_running!(:keycloak)
```

To skip all of it for one run, for example because the service is already running somewhere else:

```sh
DOCKSIDE_AUTOSTART=0 bin/rails server
```

## Rake tasks

Use `RAILS_ENV=test` in front to work on the test containers.

| Task | What it does |
|---|---|
| `dockside:up[names]` | Start the containers. `BUILD=1` rebuilds, `PULL=1` pulls. |
| `dockside:stop[names]` | Stop the containers, keep the data. |
| `dockside:down` | Remove the containers, keep the data. |
| `dockside:reset[names]` | Remove the containers and the data, start again. |
| `dockside:status` | Show every container, its state and URL. |
| `dockside:logs[name]` | Show the container log. `TAIL=200`, `FOLLOW=1`. |
| `dockside:config` | Show the compose file the gem really uses. |

Separate names with commas: `dockside:up[minio,keycloak]`.

## Ruby API

You will rarely need it. It is there for seeds, scripts and test helpers.

```ruby
Dockside.names                         # => [:minio, :keycloak]
Dockside.minio                         # one dependency, for the current environment
Dockside.fetch(:minio)                 # the same, for a name you only have as a variable

Dockside.ensure_running!               # start everything with autostart: true
Dockside.ensure_running!(:minio)       # start one
Dockside.down                          # remove the containers of the current environment
```

```ruby
minio.port             # => 9010
minio.url              # => "http://localhost:9010"
minio.container_name   # => "my-app-test-minio-1"
minio.running?
minio.ready?
minio.start
minio.stop
minio.reset
minio.exec("mc ls local/uploads")
minio.logs(tail: 100)
```

All errors inherit from `Dockside::Error`. The message always says what went wrong and, when a
container is involved, includes its last log lines.

## Good to know

- Containers are named `<app>-<environment>-<service>-1`. Do not set `container_name` yourself.
- Paths in the compose file are relative to the app folder.
- `host.docker.internal` works inside every container, also on Linux.
- The gem writes its own files to `tmp/dockside/`.
- Two checkouts of the same app share the same containers and ports.
- Ports and passwords appear twice: in the compose file and in your app's config. That is on purpose. The gem
  never changes your app's config.
- `dockside:config` shows the exact compose file. You can always run `docker compose` yourself with it.

## Using plain docker compose

`config/dockside.yml` is a valid compose file. Nothing stops you from using it without the gem, for example
from a shell, in CI, or with a tool that is not Rails.

For development, point compose at the file and use the same project name as the gem. Then compose sees the
same containers the gem started, and the gem sees the ones compose started:

```sh
docker compose -p my-app-development -f config/dockside.yml up -d
docker compose -p my-app-development -f config/dockside.yml ps
docker compose -p my-app-development -f config/dockside.yml logs -f minio
docker compose -p my-app-development -f config/dockside.yml down
```

The project name is `<app>-<environment>`. That is where the container names `my-app-development-minio-1` come
from. If the file uses `${RAILS_ENV}`, set it before you run compose: `RAILS_ENV=development docker compose ...`.
Compose also interpolates `$VARIABLES` inside `x-dockside`, so an `after_start` command like
`mc alias set local http://localhost:9000 $MINIO_ROOT_USER ...` makes it print a warning. The warning is harmless;
the gem reads the commands itself, from the original file.

Compose does not apply the `test:` overrides. It only sees the `x-dockside` block as an extension field it
does not understand. To get the file for one environment with the overrides merged in, let the gem print it:

```sh
RAILS_ENV=test bin/rails dockside:config > tmp/dockside/compose.test.yml
docker compose -p my-app-test -f tmp/dockside/compose.test.yml up -d
```

The printed file has no `x-dockside` part left, so it can go into any compose command, a `docker-compose.yml`
in another repository, or a CI step that has no Ruby.

Three things stay with the gem and do not happen when you use compose alone:

- waiting until the service is ready (`ready:` and `timeout:`)
- the `after_start` commands
- creating the `tmp/` folders for volumes

With compose alone, run those steps yourself, for example with `docker compose exec minio mc mb local/uploads`.

## Development

```sh
bin/setup
bin/check                     # the specs; they need the docker CLI but no running daemon
DOCKER=1 bin/check            # also runs the specs against a real Docker
bin/fastcheck                 # standardrb
```

The specs talk to a fake Docker (`spec/support/fake_docker.rb`) that remembers which containers compose
would have started. Only `docker compose config` reaches the real compose CLI, because it just parses files.

## License

MIT
