# --ulimit 'nofile=1024:1048576'  # slow fakeroot
FROM --platform=${BUILDPLATFORM:-linux/amd64} docker.io/tonistiigi/xx AS xx
FROM --platform=${BUILDPLATFORM:-linux/amd64} docker.io/library/alpine:edge as rust-toolchain
ENV APORTS_BRANCH=master
#FROM --platform=${BUILDPLATFORM:-linux/amd64} docker.io/library/alpine:3.20 as rust-toolchain
#ENV APORTS_BRANCH=3.20-alpine
COPY --from=xx / /
COPY APKBUILD.rust /tmp/
ARG TARGETPLATFORM
ENV TARGETPLATFORM="${TARGETPLATFORM:-linux/amd64}"

## since the default Rust toolchain superimposes gcc's unwinder during linking
## (`-lgcc_s`) against musl libc, to bypass it with llvm's, we are rebuilding
## the entire toolchain
## ref: https://github.com/rust-lang/rust/blob/9b00956e56009bab2aa15d7bff10916599e3d6d6/library/unwind/src/lib.rs#L63  # pins to tag 1.78.0

RUN set -x; apk update && apk add --no-cache alpine-sdk bison flex texinfo zlib-dev llvm-libunwind-static clang lld rustup bash gcc gcompat \
 && export ANDROID_NDK="/opt/android-sdk/ndk/27.1.12297006" ANDROID_ABI=21 ANDROID_MARCH="$(xx-info march | grep -q ^armv7 && echo armv7a || xx-info march)" \
    ANDROID_TARGET="$(xx-info march | grep -q ^armv7 && echo armv7 || xx-info march)-$(xx-info os)-$(echo "${TARGETPLATFORM#*/}" | grep -q ^arm/ && echo androideabi || echo android)" \
 && export ANDROID_NDK_HOME="${ANDROID_NDK}" ANDROID_NDK_ROOT="${ANDROID_NDK}" ANDROID_NDK_LATEST_HOME="${ANDROID_NDK}" \
 && mkdir -p "${ANDROID_NDK%/*}" && wget https://dl.google.com/android/repository/android-ndk-r27b-linux.zip \
 && [ "$(sha1sum android-ndk-r27b-linux.zip | awk '{print $1}')" = "6fc476b2e57d7c01ac0c95817746b927035b9749" ] \
 && unzip -o android-ndk-r27b-linux.zip && rm android-ndk-r27b-linux.zip && mv android-ndk-r27b "${ANDROID_NDK}" \
 && xx-apk add --no-cache xx-cxx-essentials llvm-libunwind-static && xx-clang --setup-target-triple \
 && addgroup bin abuild && ln -s /usr/bin/rustup-init /usr/bin/rustup \
 && mkdir -p /var/cache/distfiles && chgrp abuild /var/cache/distfiles && chmod g+w /var/cache/distfiles \
 && cd /var/tmp && su -s /bin/sh bin -c 'git clone https://github.com/alpinelinux/aports -b ${APORTS_BRANCH} --depth 1 && HOME=/var/tmp abuild-keygen -a -n' \
 && cp /var/tmp/.abuild/*.pub /etc/apk/keys/ \
 && export MARCH="$(TARGETPLATFORM="${BUILDPLATFORM:-linux/amd64}" xx-info march)" \
 && su -s /bin/sh bin -c 'export HOME=/var/tmp MARCH="$(xx-info | awk -F- '\''{print $1}'\'')" \
  && git config --global user.name zer0def && git config --global user.email zer0def@zer0def.0 \
  && cd /var/tmp/aports/main/rust && cp /tmp/APKBUILD.rust APKBUILD && JOBS=$(nproc) abuild -mr  # BOOTSTRAP=1' \
 && apk add --no-cache \
  /var/tmp/packages/main/${MARCH}/cargo-*.apk \
  /var/tmp/packages/main/${MARCH}/rust-*.apk \
  /var/tmp/packages/main/${MARCH}/rustfmt-*.apk \
 && apk del rustup && rm /usr/bin/rustup

# install native dependencies first so we can cache them
FROM --platform="${BUILDPLATFORM:-linux/amd64}" rust-toolchain as builder
ARG TARGETOS
ENV TARGETOS=${TARGETOS:-linux}
RUN apk add --no-cache clang cmake gcc g++ make llvm18-dev clang18-static llvm18-static ncurses-static zlib-static zstd-static
WORKDIR /app
COPY . .

# yes, I could've mangled TARGETPLATFORM to achieve this result, but introducing a separate variable is cleaner, even if confusing
RUN set -x; \
    if test "${TARGETOS}" = "android"; then \
      TARGET="$(xx-info march | grep -q ^armv7 && echo armv7 || xx-info march)-$(xx-info os)-$(echo "${TARGETPLATFORM#*/}" | grep -q ^arm/ && echo androideabi || echo android)"; \
      ANDROID_MARCH="$(xx-info march | grep -q ^armv7 && echo armv7a || xx-info march)" ANDROID_ABI=21; \
      export ANDROID_NDK="/opt/android-sdk/ndk/27.1.12297006"; export ANDROID_NDK_HOME="${ANDROID_NDK}" ANDROID_NDK_ROOT="${ANDROID_NDK}" ANDROID_NDK_LATEST_HOME="${ANDROID_NDK}" \
      ANDROID_TARGET_CPU="$(xx-info march | grep -q ^armv7 && echo armv7-a || xx-info march)"; \
      ANDROID_TOOLCHAIN="${ANDROID_NDK}/toolchains/llvm/prebuilt/$(TARGETPLATFORM="${BUILDPLATFORM:-linux/amd64}" xx-info os)-$(TARGETPLATFORM="${BUILDPLATFORM:-linux/amd64}" xx-info march)"; \
      export CC="${ANDROID_TOOLCHAIN}/bin/${ANDROID_MARCH}-${TARGET#*-}${ANDROID_ABI}-clang" CXX="${ANDROID_TOOLCHAIN}/bin/${ANDROID_MARCH}-${TARGET#*-}${ANDROID_ABI}-clang++"; \
    else \
      TARGET="$(xx-info)"; \
      export RUSTFLAGS="${RUSTFLAGS} -C linker=/usr/bin/$(xx-info)-clang" \
      CC="xx-cc" CFLAGS="${CFLAGS} --config /usr/bin/$(xx-info).cfg" \
      CXX="xx-c++" CXXFLAGS="${CXXFLAGS} --config /usr/bin/$(xx-info).cfg"; \
    fi; \
  RUSTFLAGS="${RUSTFLAGS} -C target-feature=+crt-static -C link-arg=-s -C strip=symbols -C opt-level=3" cargo build -vv --color never --release --bin aero2solver --target="${TARGET}" \
 && XX_VERIFY_STATIC=1 xx-verify "./target/${TARGET}/release/aero2solver" \
 && cp "./target/${TARGET}/release/aero2solver" "./target/aero2solver"

FROM scratch AS runtime
WORKDIR /app
COPY ./model/ /app/model/
COPY --from=builder /app/target/aero2solver /app/aero2solver
ENTRYPOINT ["/app/aero2solver"]
