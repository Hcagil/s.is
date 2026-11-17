# Headless Android emulator image for a test lane.
# Build context is the docker/ directory.
FROM ghcr.io/hcagil/base-ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

ARG LOCAL_UID=1000
ARG LOCAL_GID=1000
ARG SYSTEM_IMAGE='system-images;android-35;google_apis;x86_64'

ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_AVD_HOME=/home/ubuntu/.android/avd \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:${PATH}

# Install runtime dependencies for the emulator and headless display.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl unzip openjdk-17-jre-headless \
    libpulse0 libnss3 libxcomposite1 libxcursor1 libxi6 libxtst6 \
    libxdamage1 libxrandr2 libxkbfile1 libgl1 libegl1 libdrm2 libgbm1 \
    libasound2t64 libbsd0 libxkbcommon0 libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*

# Create the ubuntu user with the provided host IDs for volume mounting.
RUN groupmod -g "${LOCAL_GID}" ubuntu \
    && usermod -u "${LOCAL_UID}" -g "${LOCAL_GID}" ubuntu \
    && mkdir -p /opt/android-sdk/cmdline-tools /home/ubuntu/.android \
    && chown -R ubuntu:ubuntu /opt/android-sdk /home/ubuntu

USER ubuntu

# Download and verify the command-line tools.
RUN curl -fsSL --retry 5 --retry-all-errors "https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip" -o /tmp/android-tools.zip \
    && echo '4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583  /tmp/android-tools.zip' | sha256sum -c - \
    && unzip -q /tmp/android-tools.zip -d /opt/android-sdk/cmdline-tools \
    && mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest \
    && rm /tmp/android-tools.zip

# Receipts produced by the required interactive license review. Do not replace
# these with an automated `sdkmanager --licenses` acceptance step.
COPY --chown=ubuntu:ubuntu android-licenses/ /opt/android-sdk/licenses/

# Install the emulator, platform-tools, and the specified system image.
RUN sdkmanager 'emulator' 'platform-tools' "${SYSTEM_IMAGE}"

# Create the AVD at build time so it is ready for immediate use.
RUN echo no | avdmanager create avd -n sis -k "${SYSTEM_IMAGE}" -d pixel_6

WORKDIR /home/ubuntu
CMD ["bash"]
