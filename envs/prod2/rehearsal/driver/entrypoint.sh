#!/bin/sh
# The rehearsal driver task's command (inlined into the task definition: entryPoint ["/bin/sh", "-c"]). The image is
# the public node:22 Alpine; this installs Alpine's ffmpeg (libx264, lavfi, AAC, TLS for rtmps://), unpacks the driver
# (DRIVER_MJS_GZ_B64 = Terraform's base64gzip of driver/driver.mjs, checked against DRIVER_SHA256) and runs it.
# Exit: the driver's (0 PASS, 1 a region failed, 2 configuration, 3 engine/regions never up); 10 = setup failed here.
set -eu
echo "rehearsal-driver: setup ($(node --version), Alpine $(cat /etc/alpine-release))"
if ! apk add --no-cache ffmpeg > /tmp/apk.log 2>&1; then
  tail -n 20 /tmp/apk.log
  echo "REHEARSAL_SETUP_FAILED apk add ffmpeg"
  exit 10
fi
echo "rehearsal-driver: $(ffmpeg -hide_banner -version | head -n 1)"
umask 077
printenv DRIVER_MJS_GZ_B64 | base64 -d | gunzip > /tmp/driver.mjs
unset DRIVER_MJS_GZ_B64
if [ "$(sha256sum /tmp/driver.mjs | cut -d' ' -f1)" != "${DRIVER_SHA256:-}" ]; then
  echo "REHEARSAL_SETUP_FAILED the unpacked driver does not match DRIVER_SHA256"
  exit 10
fi
exec node /tmp/driver.mjs
