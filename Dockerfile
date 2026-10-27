FROM node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20 AS pi
WORKDIR /opt/pi
COPY priv/pi/package.json priv/pi/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY priv/pi/bridge.mjs ./
COPY --chmod=0755 priv/pi/bash-watchdog.mjs ./

FROM hexpm/elixir@sha256:73e79b5a183c6ba8c060a664a430b30f571a890907f899a66ed13b0bd4aa03c2 AS tooling
ENV ERL_FLAGS="+S 2:2"
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git docker.io docker-buildx util-linux build-essential && rm -rf /var/lib/apt/lists/*
ENV MIX_HOME=/opt/mix HEX_HOME=/opt/hex
RUN mix local.hex --force && mix local.rebar --force && mkdir -p /opt/hex && chmod -R a+rX /opt/mix /opt/hex
COPY --from=pi /usr/local/bin/node /opt/pi/node
COPY --from=pi /opt/pi /opt/pi
WORKDIR /app
ENV MIX_BUILD_ROOT=/app/.local/docker-build MIX_DEPS_PATH=/app/.local/docker-deps

FROM tooling AS build
ENV MIX_ENV=prod
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
RUN mix compile --warnings-as-errors && mix assets && mix release

FROM ubuntu:24.04 AS app
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client docker.io docker-buildx util-linux libstdc++6 libssl3t64 libncurses6 locales && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 EAB_ROOT=/app EAB_DATA_DIR=/data ERL_FLAGS="+S 2:2"
WORKDIR /app
COPY --from=build /app/.local/docker-build/prod/rel/eab ./
COPY cases cases
COPY config/benchmark.json config/benchmark.json
COPY lib lib
COPY mix.lock mix.lock
COPY priv/fixtures priv/fixtures
COPY priv/pi priv/pi
COPY priv/claude_code priv/claude_code
COPY priv/admitted_validation_runs.json priv/admitted_validation_runs.json
VOLUME /data
CMD ["bin/eab", "start"]
