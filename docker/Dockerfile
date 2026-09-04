# The bench-contract runner image: Flutter SDK (pinned), Android SDK with a
# pre-loaded system image and a precreated AVD (built once, not per run).
# The consumer repo is mounted at /workspace; the entrypoint boots the AVD
# headless and drives the contract CLI — resolved from pub.dev through the
# consumer's own pubspec, so the package is never baked into the image.
#
# The image tag is the Flutter major.minor (3.47) — consumers select the
# runner by the Flutter version their goldens were recorded on. Pin by
# digest for reproducibility (docker/README.md).
ARG FLUTTER_VERSION=3.47.0
ARG ANDROID_API=36

FROM ubuntu:22.04

# System: the emulator's runtime library set + tooling. KVM is not baked
# in — the host passes /dev/kvm at run time (no KVM = no accel).
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      unzip \
      xz-utils \
      zip \
      openjdk-17-jdk-headless \
      libgl1 \
      libglib2.0-0 \
      libpulse0 \
      libx11-6 \
      libxcb1 \
      libxext6 \
      libxi6 \
      libxrender1 \
      libxcomposite1 \
      libxdamage1 \
      libxfixes3 \
      libxrandr2 \
      libdrm2 \
      libgbm1 \
      libnss3 \
      libnspr4 \
      libcups2 \
      libasound2 \
      libdbus-1-3 \
      libfontconfig1 \
      fonts-liberation \
      && rm -rf /var/lib/apt/lists/*

# sdkmanager and Gradle builds resolve java via JAVA_HOME.
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# -- Flutter SDK (pinned stable tarball).
ARG FLUTTER_VERSION
RUN curl -fsSL -o /tmp/flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && tar -xf /tmp/flutter.tar.xz -C /opt \
    && rm /tmp/flutter.tar.xz \
    && git config --global --add safe.directory /opt/flutter

ENV PATH="/opt/flutter/bin:${PATH}"
# Pre-cache engine artifacts (android for the device runs, web so an
# explicit `--legs web` also builds offline) — the first consumer build
# needs no network at run time.
RUN flutter --version >/dev/null && flutter precache --android --web

# -- Android SDK: cmdline-tools pinned, platform + build-tools + emulator +
# the system image. SDK licenses accepted at build time.
ARG ANDROID_API
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${PATH}"
RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" \
    && curl -fsSL -o /tmp/cmdtools.zip \
      "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
    && unzip -q /tmp/cmdtools.zip -d "${ANDROID_HOME}/cmdline-tools" \
    && mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest" \
    && rm /tmp/cmdtools.zip
RUN yes | sdkmanager --licenses >/dev/null 2>&1 || true
RUN sdkmanager \
      "platform-tools" \
      "platforms;android-${ANDROID_API}" \
      "build-tools;${ANDROID_API}.0.0" \
      "emulator" \
      "system-images;android-${ANDROID_API};google_apis;x86_64"

# Precreated AVD — built once, so every run starts from the same disk image
# state; medium_phone approximates the reference hardware goldens use.
RUN echo "no" | avdmanager create avd \
      -n contract \
      -k "system-images;android-${ANDROID_API};google_apis;x86_64" \
      --device medium_phone \
      --force

# Entrypoint: `bench-contract <check|record> [--ref ...]`.
COPY entrypoint.sh /usr/local/bin/bench-contract
RUN chmod +x /usr/local/bin/bench-contract
ENTRYPOINT ["bench-contract"]
