# Game Club server image: the authoritative Dart server plus the compiled
# Flutter web build, so ONE deployed service serves the game UI, the
# WebSocket transport, /stats, and the leaderboard API on the same origin.
#
# The pubspec is a Flutter project, so dependency resolution needs the
# Flutter SDK even though the server itself is pure Dart.
FROM ghcr.io/cirruslabs/flutter:3.35.0 AS build
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
RUN flutter build web --release
# The server is pure Dart — compile to a small self-contained binary.
RUN dart compile exe bin/server.dart -o /app/server

FROM debian:bookworm-slim
# libsqlite3 keeps the file-backed leaderboard fallback working when
# TURSO_DATABASE_URL is not set (e.g. local `docker run` without Turso).
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/server /app/server
COPY --from=build /app/build/web /app/build/web
ENV WEB_DIR=/app/build/web
EXPOSE 8080
CMD ["/app/server"]
