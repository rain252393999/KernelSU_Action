#!/usr/bin/env bash
# Fetch the compiler toolchain and export the make flags that use it.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKSPACE=${WORKSPACE:?WORKSPACE must be set}

# CLANG_DIR="${WORKSPACE}/clang"
GCC64_DIR="${WORKSPACE}/gcc-64"
GCC32_DIR="${WORKSPACE}/gcc-32"

# AOSP_CLANG_BASE="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"

# Known-good AOSP clang branch/version pairs, verified 2026-07-27.
#
# This table exists because the AOSP prebuilt repo is a minefield: every
# kernel-build branch lists *every* clang version directory in its tree, but
# only the one or two it was actually cut for contain a real toolchain. The
# rest are either absent or contain nothing but a `.keep` placeholder, and the
# generated tarball for those downloads happily with HTTP 200 -- it is just a
# valid, ~165-byte, empty archive. So a typo'd version does not 404; it
# produces an empty clang/ directory and a baffling "clang: not found" later.
#
#   branch                    version     approx clang
#   main-kernel               r596125     newest
#   main-kernel-2026          r584948c
#   main-kernel-2025          r547379     <- default
#   main-kernel-2025          r536225
#   main-kernel-build-2024    r510928
#   master-kernel-build-2022  r450784e    last of the master-* era
#
# Note the branch naming changed twice: master-kernel-build-YYYY became
# main-kernel-build-YYYY in 2023, then main-kernel-YYYY from 2025 on.
clang_known_good() {
	case "$1/$2" in
		main-kernel/r596125 | \
		main-kernel/r547379 | \
		main-kernel-2026/r584948c | \
		main-kernel-2025/r547379 | \
		main-kernel-2025/r536225 | \
		main-kernel-build-2024/r510928 | \
		main-kernel-build-2023/r498229b | \
		master-kernel-build-2022/r450784e | \
		master-kernel-build-2021/r416183b) return 0 ;;
		*) return 1 ;;
	esac
}

setup_clang() {
	info "Skipping Clang download, using GCC 4.9 toolchain."
	export_env CLANG_PATH ""

	
}

# AOSP's GCC 4.9 prebuilts are still the binutils of choice for pre-5.x trees
# that cannot yet use LLVM's integrated assembler.
setup_gcc() {
	local gcc_tag="pie-release"

	if is_true "${USE_CUSTOM_GCC_64:-false}"; then
		group "Downloading custom GCC (arm64)"
		fetch_toolchain_generic "${CUSTOM_GCC_64_SOURCE}" "${CUSTOM_GCC_64_BRANCH:-}" "$GCC64_DIR"
		export_env GCC_64 "CROSS_COMPILE=${GCC64_DIR}/bin/${CUSTOM_GCC_64_BIN:-aarch64-linux-android-}"
		endgroup
	elif is_true "${ENABLE_GCC_ARM64:-false}"; then
		group "Downloading AOSP GCC (arm64)"
		mkdir -p "$GCC64_DIR"
		fetch "https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/heads/${gcc_tag}.tar.gz" \
			"${WORKSPACE}/gcc-aarch64.tar.gz"
		extract_archive "${WORKSPACE}/gcc-aarch64.tar.gz" "$GCC64_DIR"
		export_env GCC_64 "CROSS_COMPILE=${GCC64_DIR}/bin/aarch64-linux-android-"
		endgroup
	fi

	if is_true "${USE_CUSTOM_GCC_32:-false}"; then
		group "Downloading custom GCC (arm32)"
		fetch_toolchain_generic "${CUSTOM_GCC_32_SOURCE}" "${CUSTOM_GCC_32_BRANCH:-}" "$GCC32_DIR"
		export_env GCC_32 "CROSS_COMPILE_ARM32=${GCC32_DIR}/bin/${CUSTOM_GCC_32_BIN:-arm-linux-androideabi-}"
		endgroup
	elif is_true "${ENABLE_GCC_ARM32:-false}"; then
		group "Downloading AOSP GCC (arm32)"
		mkdir -p "$GCC32_DIR"
		fetch "https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/refs/heads/${gcc_tag}.tar.gz" \
			"${WORKSPACE}/gcc-arm.tar.gz"
		extract_archive "${WORKSPACE}/gcc-arm.tar.gz" "$GCC32_DIR"
		export_env GCC_32 "CROSS_COMPILE_ARM32=${GCC32_DIR}/bin/arm-linux-androideabi-"
		endgroup
	fi
}

fetch_toolchain_generic() {
	local src=$1 branch=$2 dest=$3
	rm -rf "$dest"; mkdir -p "$dest"
	case "$src" in
		*.tar.gz | *.tgz | *.tar.xz | *.tar.zst)
			local ext="${src##*/}"; ext="${ext#*.}"
			fetch "$src" "${WORKSPACE}/tc.${ext}"
			extract_archive "${WORKSPACE}/tc.${ext}" "$dest" ;;
		*.zip)
			fetch "$src" "${WORKSPACE}/tc.zip"
			extract_archive "${WORKSPACE}/tc.zip" "$dest" ;;
		*git*)
			retry 3 git clone -q --depth=1 ${branch:+-b "$branch"} "$src" "$dest" \
				|| die "failed to clone ${src}" ;;
		*)
			fetch "$src" "${WORKSPACE}/tc.zip"
			extract_archive "${WORKSPACE}/tc.zip" "$dest" ;;
	esac
}

# mkbootimg is only needed when repacking a boot image.
setup_mkbootimg() {
	is_true "${BUILD_BOOT_IMG:-false}" || return 0
	group "Downloading mkbootimg tools"
	local dir="${WORKSPACE}/tools"
	rm -rf "$dir"
	retry 3 git clone -q --depth=1 -b main-kernel \
		https://android.googlesource.com/platform/system/tools/mkbootimg "$dir" \
		|| die "failed to clone mkbootimg"
	ok "mkbootimg ready"
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	setup_clang
	setup_gcc
	setup_mkbootimg
fi
