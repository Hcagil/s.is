FROM ubuntu:24.04

ARG FLUTTER_VERSION=3.47.2
ARG ANDROID_TOOLS_VERSION=15859902
ARG LOCAL_UID=1000
ARG LOCAL_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    PUB_CACHE=/home/ubuntu/.pub-cache \
    GRADLE_USER_HOME=/home/ubuntu/.gradle
ENV PATH=/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils zip openjdk-17-jdk-headless \
    libglu1-mesa clang cmake ninja-build pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN groupmod -g "${LOCAL_GID}" ubuntu \
    && usermod -u "${LOCAL_UID}" -g "${LOCAL_GID}" ubuntu \
    && mkdir -p /opt/flutter /opt/android-sdk/cmdline-tools \
        /home/ubuntu/.android /home/ubuntu/.pub-cache /home/ubuntu/.gradle \
    && chown -R ubuntu:ubuntu /opt/flutter /opt/android-sdk /home/ubuntu

USER ubuntu
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" \
    https://github.com/flutter/flutter.git /opt/flutter \
    && curl -fsSL --retry 5 --retry-all-errors "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_TOOLS_VERSION}_latest.zip" -o /tmp/android-tools.zip \
    && echo '4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583  /tmp/android-tools.zip' | sha256sum -c - \
    && unzip -q /tmp/android-tools.zip -d /opt/android-sdk/cmdline-tools \
    && mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest \
    && rm /tmp/android-tools.zip

# Receipts produced by the required interactive license review. Do not replace
# these with an automated `sdkmanager --licenses` acceptance step.
COPY --chown=ubuntu:ubuntu android-licenses/ /opt/android-sdk/licenses/
RUN sdkmanager \
    'build-tools;36.0.0' \
    'cmake;3.22.1' \
    'ndk;28.2.13676358' \
    'platform-tools' \
    'platforms;android-35' \
    'platforms;android-36'
RUN flutter config --no-analytics && flutter precache --android
WORKDIR /workspace
CMD ["flutter", "doctor", "-v"]
