# Game Club server image: the authoritative Dart server plus the compiled
# Flutter web build, so ONE deployed service serves the game UI, the
# WebSocket transport, /stats, and the leaderboard API on the same origin.
#
# The pubspec requires Dart ^3.13.2, which ships with Flutter 3.47.2 —
# pulled from the official release tarball (the cirruslabs/flutter images
# froze at 3.44.0/Dart 3.12 and cannot resolve this project).
FROM debian:bookworm-slim AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils \
    && rm -rf /var/lib/apt/lists/*
ARG FLUTTER_VERSION=3.47.2
RUN curl -fsSL \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
      | tar xJ --no-same-owner -C /opt
ENV PATH="/opt/flutter/bin:${PATH}"
# Prime the SDK cache and pin analytics off; the web build pulls its
# engine artifacts on demand below.
RUN flutter config --no-analytics && flutter --version
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
RUN flutter build web --release
# The server is pure Dart, but sqlite3 ships a build hook (prebuilt
# libsqlite3.so) that Dart 3.13's `dart compile exe` refuses; `dart build
# cli` is the supported replacement and emits a bundle with the executable
# plus its native libraries.
RUN dart build cli -t bin/server.dart -o /app/server-build

FROM debian:bookworm-slim
# libsqlite3 keeps the file-backed leaderboard fallback working when
# TURSO_DATABASE_URL is not set (e.g. local `docker run` without Turso).
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/server-build/bundle /app/server
COPY --from=build /app/build/web /app/build/web
ENV WEB_DIR=/app/build/web
EXPOSE 8080
CMD ["/app/server/bin/server"]

