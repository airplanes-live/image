#!/bin/bash -e

if [ ! -d "${ROOTFS_DIR}" ]; then
	copy_previous
fi

# Decoder-stage selection: legacy in-chroot path (02-install-decoder,
# 03-install-tar1090, 04-install-graphs1090) vs runtime-overlay build-mode
# path (02-install-runtime-overlay). Drop SKIP files based on the channel
# config's AIRPLANES_USE_LEGACY_DECODER_STAGES setting. Actively clean
# stale SKIP files first so flipping the flag between local builds works
# without leftover state from a prior run.
for _skip in \
	"${BASE_DIR}/stage-airplanes/02-install-decoder/SKIP" \
	"${BASE_DIR}/stage-airplanes/03-install-tar1090/SKIP" \
	"${BASE_DIR}/stage-airplanes/04-install-graphs1090/SKIP" \
	"${BASE_DIR}/stage-airplanes/02-install-runtime-overlay/SKIP"; do
	rm -f -- "$_skip"
done

if [[ "${AIRPLANES_USE_LEGACY_DECODER_STAGES:-0}" == "1" ]]; then
	touch "${BASE_DIR}/stage-airplanes/02-install-runtime-overlay/SKIP"
else
	touch "${BASE_DIR}/stage-airplanes/02-install-decoder/SKIP"
	touch "${BASE_DIR}/stage-airplanes/03-install-tar1090/SKIP"
	touch "${BASE_DIR}/stage-airplanes/04-install-graphs1090/SKIP"
fi
