#!/usr/bin/env bash
# Install a KernelSU variant into the kernel tree.
#
# Every variant ships a near-identical kernel/setup.sh that clones itself next
# to the kernel tree and symlinks drivers/kernelsu at it. They differ in three
# ways that matter, all of which are encoded in the registry below:
#
#   * the directory the clone lands in (KernelSU vs KernelSU-Next),
#   * what "no argument" means -- most check out the latest tag, ReSukiSU
#     checks out main,
#   * which ref carries non-GKI support and which carries SUSFS.
#
# The critical safety property: every variant's setup.sh ends its checkout with
#     git checkout "$1" ... || echo "[-] Checkout default branch"
# so an invalid ref does NOT fail the script -- it silently leaves the tree on
# the default branch. A build asking for SukiSU's SUSFS-capable 'builtin'
# branch and typing 'susfs-main' (which does not exist) would quietly produce a
# kernel with no SUSFS at all. So we validate the ref before calling setup.sh
# and verify the checkout afterwards.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

# ------------------------------------------------------------- registry -----
#
# Fields, '|'-separated:
#   1 repo URL
#   2 ref the setup.sh script itself is fetched from
#   3 directory setup.sh clones into, relative to the kernel tree
#   4 default ref for modern (>= 5.10) kernels; empty means "let setup.sh pick"
#   5 default ref for legacy (< 5.10) kernels
#   6 refs that already contain SUSFS support (space separated; '-' for none)
#   7 human-readable name
#
# Verified against each repo's live branch/tag list on 2026-07-27.

ksu_registry() {
	case "$1" in
	kernelsu)
		# Official upstream. Dropped non-GKI support at v1.0, so legacy kernels
		# are pinned to the last release that supports them.
		echo "https://github.com/tiann/KernelSU|main|KernelSU||v0.9.5|-|KernelSU" ;;
	kernelsu-next)
		# 'next' was renamed to 'legacy' and the default branch is now 'dev'.
		# Raw URLs containing /next/ only still work via GitHub's rename
		# redirect, so we address the real branches directly.
		echo "https://github.com/KernelSU-Next/KernelSU-Next|dev|KernelSU-Next|dev|legacy|-|KernelSU-Next" ;;
	sukisu-ultra)
		# Repo moved from the personal ShirkNeko account into its own org.
		# 'main' is the modular v4 tree (KPM, no SUSFS); 'builtin' is the
		# non-GKI/source-integrated tree and is the only one with SUSFS Kconfig.
		echo "https://github.com/SukiSU-Ultra/SukiSU-Ultra|main|KernelSU|main|builtin|builtin|SukiSU-Ultra" ;;
	resukisu)
		# Re-fork of SukiSU-Ultra aimed at legacy/non-GKI kernels.
		echo "https://github.com/Baka-SU/BakaSU|main|KernelSU|main|main|-|BakaSU" ;;
	rsuntk)
		echo "https://github.com/rsuntk/KernelSU|main|KernelSU|main|main|susfs-rksu-master|RKSU (rsuntk)" ;;
	backslashxx)
		echo "https://github.com/backslashxx/KernelSU|master|KernelSU|master|master|-|backslashxx KernelSU" ;;
	*)
		die "unknown KSU_VARIANT '$1'" ;;
	esac
}

ksu_field() { ksu_registry "$1" | cut -d'|' -f"$2"; }

# ReSukiSU's setup.sh checks out 'main' when given no argument, while every
# other variant checks out the latest tag. Call that out so an unpinned CI
# build is not silently tracking a moving branch.
ksu_default_is_branch() { [ "$1" = "resukisu" ]; }

# ---------------------------------------------------------------- install ---

ksu_install() {
	local variant=$1 requested_ref=${2-}

	[ "$variant" = "none" ] && { info "KernelSU integration disabled"; return 0; }

	local repo setup_ref dir modern_ref legacy_ref susfs_refs name
	IFS='|' read -r repo setup_ref dir modern_ref legacy_ref susfs_refs name <<<"$(ksu_registry "$variant")"

	group "Installing ${name}"
	info "repository: ${repo}"

	# Decide which ref to check out.
	local kver ref=$requested_ref
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")
	if [ -z "$ref" ]; then
		if ver_ge "$kver" "5.10"; then
			ref=$modern_ref
		else
			ref=$legacy_ref
			[ -n "$ref" ] && info "kernel ${kver} is pre-GKI; defaulting to ref '${ref}'"
		fi
	fi

	# Validate before handing the ref to setup.sh, which would swallow a typo.
	if [ -n "$ref" ]; then
		info "validating ref '${ref}' exists in ${repo}"
		ref_exists "$repo" "$ref" \
			|| die "ref '${ref}' does not exist in ${repo}.
       setup.sh would silently fall back to the default branch and you would
       get a kernel without the feature you asked for.
       Available branches: $(git ls-remote --heads "$repo" 2>/dev/null | awk '{print $2}' | sed 's@refs/heads/@@' | grep -v dependabot | tr '\n' ' ')"
		ok "ref '${ref}' exists"
	else
		warn "no ref pinned; setup.sh will pick the latest tag. Set KSU_REF for reproducible builds."
	fi

	if [ -z "$requested_ref" ] && ksu_default_is_branch "$variant"; then
		warn "${name}'s setup.sh defaults to the moving 'main' branch rather than a tag."
		warn "Pin KSU_REF (e.g. a tag) if you need reproducible builds."
	fi

	# Run the variant's own installer.
	local setup_url="https://raw.githubusercontent.com/${repo#https://github.com/}/${setup_ref}/kernel/setup.sh"
	info "running ${setup_url}"
	(
		cd "$KERNEL_DIR"
		if [ -n "$ref" ]; then
			fetch_stdout "$setup_url" | bash -s "$ref"
		else
			fetch_stdout "$setup_url" | bash
		fi
	) || die "${name} setup.sh failed"


	# --- 修复：setup.sh 的浅克隆可能没 fetch tag，手动补 ---
	local ksu_clone="${KERNEL_DIR}/${dir}"
	(
		cd "$ksu_clone"
		git fetch --tags --unshallow 2>/dev/null || git fetch --tags 2>/dev/null || true
		if [ -n "$ref" ]; then
			git checkout "$ref" 2>/dev/null && info "manually checked out ${ref}" \
				|| warn "could not checkout ${ref}; staying on $(git rev-parse --short HEAD)"
		fi
	) || warn "post-setup git fixup failed"

	# --- 动态探测源码目录：包含 Kconfig 和 Makefile 的目录才是真正的源码根 ---
	local ksu_src=""
	for candidate in \
		"${ksu_clone}/kernel" \
		"${ksu_clone}" \
		"${ksu_clone}/KernelSU" \
		"${ksu_clone}/kernel/kernel"; do
		if [ -f "${candidate}/Kconfig" ] && [ -f "${candidate}/Makefile" ]; then
			ksu_src="$candidate"
			break
		fi
	done
	if [ -z "$ksu_src" ]; then
		warn "could not locate KernelSU source under ${ksu_clone}"
		warn "top-level: $(ls -1 "$ksu_clone" | head -20 | tr '\n' ' ')"
		die "KernelSU source layout not recognized in ${dir}"
	fi
	info "KernelSU source located at ${ksu_src#${KERNEL_DIR}/}"

	# --- 强制重建 drivers/kernelsu 链接指向真实源码目录 ---
	local driver_dir
	if [ -d "${KERNEL_DIR}/common/drivers" ]; then
		driver_dir="${KERNEL_DIR}/common/drivers"
	else
		driver_dir="${KERNEL_DIR}/drivers"
	fi
	[ -d "$driver_dir" ] || die "no drivers directory found"

	local link="${driver_dir}/kernelsu"
	rm -f "$link"
	ln -sfn "$(realpath --relative-to="$driver_dir" "$ksu_src")" "$link"
	info "rebuilt symlink: ${link} -> $(readlink "$link")"

	# --- 验证 Kconfig 真的能打开 ---
	[ -f "${link}/Kconfig" ] || die "rebuilt symlink but ${link}/Kconfig still missing"
	info "verified: ${link}/Kconfig exists"

	# --- verify the installer actually did what it claims ------------------
		# --- verify the installer actually did what it claims ------------------
	local ksu_dir="${KERNEL_DIR}/${dir}"
	[ -d "$ksu_dir" ] || die "${name} setup.sh finished but ${dir}/ is missing"

	# 确定 DRIVER_DIR：4.9 内核通常只有 drivers/，GKI 风格才有 common/drivers/
	local driver_dir
	if [ -d "${KERNEL_DIR}/common/drivers" ]; then
		driver_dir="${KERNEL_DIR}/common/drivers"
	else
		driver_dir="${KERNEL_DIR}/drivers"
	fi
	[ -d "$driver_dir" ] || die "no drivers directory found in ${KERNEL_DIR}"

	local link="${driver_dir}/kernelsu"
	local ksu_kernel_dir="${ksu_dir}/kernel"

	# 检测链接：既检查符号链接本身，也检查目标是否有效
	if [ ! -L "$link" ] && [ ! -e "$link" ]; then
		warn "kernelsu symlink missing at ${link}, creating manually"
		ln -sfn "$(realpath --relative-to="$driver_dir" "$ksu_kernel_dir" 2>/dev/null || echo "$ksu_kernel_dir")" "$link"
	fi

	# broken symlink：链接在，但目标不存在，重建
	if [ -L "$link" ] && [ ! -e "$link" ]; then
		warn "kernelsu symlink at ${link} is broken (target missing), recreating"
		rm -f "$link"
		ln -sfn "$(realpath --relative-to="$driver_dir" "$ksu_kernel_dir" 2>/dev/null || echo "$ksu_kernel_dir")" "$link"
	fi

	# 最终校验：符号链接必须存在（目标是否有效交给后续编译验证）
	if [ ! -L "$link" ] && [ ! -e "$link" ]; then
		die "kernelsu symlink could not be created at ${link}"
	fi
	info "kernelsu symlink verified: ${link} -> $(readlink "$link" 2>/dev/null || echo '?')"

	# 如果是 common/drivers 布局，补建根目录兼容链接
	if [ "$driver_dir" = "${KERNEL_DIR}/common/drivers" ] \
		&& [ -d "${KERNEL_DIR}/drivers" ] \
		&& [ ! -e "${KERNEL_DIR}/drivers/kernelsu" ] \
		&& [ ! -L "${KERNEL_DIR}/drivers/kernelsu" ]; then
		ln -sfn "../common/drivers/kernelsu" "${KERNEL_DIR}/drivers/kernelsu"
		info "created compatibility symlink drivers/kernelsu"
	fi

	# Makefile / Kconfig 校验跟随 driver_dir
	local driver_makefile="${driver_dir}/Makefile"
	if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
		if grep -qE '^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
			sed -i -E 's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' "$driver_makefile"
			warn "normalized stale ${driver_dir#${KERNEL_DIR}/}/Makefile KernelSU guard to CONFIG_KSU"
		else
			printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$driver_makefile"
			warn "added missing CONFIG_KSU rule to ${driver_dir#${KERNEL_DIR}/}/Makefile"
		fi
	fi

	grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile" \
		|| die "${driver_dir#${KERNEL_DIR}/}/Makefile was not wired to CONFIG_KSU for kernelsu"
	grep -q 'kernelsu/Kconfig' "${driver_dir}/Kconfig" \
		|| die "${driver_dir#${KERNEL_DIR}/}/Kconfig was not wired up for kernelsu"

	# Confirm we landed on the ref we asked for, catching the silent fallback.
	local head_desc head_sha
	head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)
	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")
	if [ -n "$ref" ]; then
		local want
		want=$(git -C "$ksu_dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)
		if [ -n "$want" ] && [ "$want" != "$(git -C "$ksu_dir" rev-parse HEAD)" ]; then
			die "${name} is checked out at ${head_desc}, not the requested ref '${ref}'"
		fi
	fi
	ok "${name} installed at ${head_desc} (${head_sha})"
  # --- diagnostic: verify symlink target really exists -------------------
	info "=== verify symlink target ==="
	ls -la "${driver_dir}/kernelsu" || warn "symlink listing failed"
	if [ -d "${ksu_dir}/kernel" ]; then
		ls "${ksu_dir}/kernel/" | head -5
	else
		warn "WARNING: ${ksu_dir}/kernel directory does not exist"
	fi


	# --- publish facts the later steps need --------------------------------
	local count version_label
	count=$(git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null || echo 0)
	if git -C "$ksu_dir" describe --exact-match --tags >/dev/null 2>&1; then
		version_label=$(git -C "$ksu_dir" describe --exact-match --tags)
	else
		version_label="${ref:-HEAD}-${head_sha}"
	fi

	export_env KSU_DIR "$dir"
	export_env KSU_NAME "$name"
	export_env KSU_REF_RESOLVED "${ref:-<latest-tag>}"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_COMMIT_COUNT "$count"
	export_env KSU_SUSFS_BUNDLED_REFS "$susfs_refs"
	export_env UPLOADNAME "-${name// /_}_${version_label}"

	ksu_resolve_hook_mode "${KSU_HOOK_MODE:-auto}" "$kver"

	summary "| KernelSU variant | \`${name}\` |"
	summary "| KernelSU ref | \`${ref:-latest tag}\` -> \`${version_label}\` |"

	endgroup
}

# ------------------------------------------------------------ hook config ---
#
# Which hook mechanism a variant should use is genuinely version- and
# fork-specific. 'auto' picks the option that the variant actually declares.

# Resolve 'auto' into a concrete mode and publish it.
#
# This has to happen once, early, and be reused by BOTH the source-patching
# step and the defconfig step. Resolving it independently in each place is how
# you end up setting CONFIG_KSU_MANUAL_HOOK on a tree whose syscall entry
# points were never actually patched -- which builds fine and then does
# nothing at runtime.
ksu_resolve_hook_mode() {
	local mode=${1:-auto} kver=$2
	if [ "$mode" = "auto" ]; then
		if ver_ge "$kver" "5.10"; then
			mode="kprobes"
		else
			# kprobes on pre-GKI kernels is the classic source of "KernelSU
			# installed but su does nothing" reports; manual hooks are patched
			# straight into the syscall entry points instead.
			mode="manual"
		fi
		info "hook mode 'auto' resolved to '${mode}' for kernel ${kver}"
	fi
	export_env KSU_HOOK_MODE_RESOLVED "$mode"
}

ksu_hook_configs() {
	local variant=$1 mode=$2 defconfig=$3 kver=$4

	if [ "$mode" = "auto" ]; then
		[ -n "${KSU_HOOK_MODE_RESOLVED:-}" ] || ksu_resolve_hook_mode "$mode" "$kver"
		mode=$KSU_HOOK_MODE_RESOLVED
	fi

	case "$mode" in
	none) return 0 ;;
	kprobes)
		kconf_enable "$defconfig" CONFIG_MODULES
		kconf_enable "$defconfig" CONFIG_KPROBES
		kconf_enable "$defconfig" CONFIG_HAVE_KPROBES
		kconf_enable "$defconfig" CONFIG_KPROBE_EVENTS
		kconf_enable "$defconfig" CONFIG_KRETPROBES
		[ "$variant" = "kernelsu-next" ] && kconf_enable "$defconfig" CONFIG_KSU_KPROBES_HOOK
		;;
	manual)
		case "$variant" in
			kernelsu-next)  kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK ;;
			sukisu-ultra)
				kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK ;;
			resukisu)
				# ReSukiSU's non-GKI static export check requires the complete
				# kallsyms table unless every internal SELinux symbol is exported
				# manually by the vendor tree.
				kconf_set_many "$defconfig" \
					CONFIG_KSU_MANUAL_HOOK=y CONFIG_DEBUG_KERNEL=y \
					CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y ;;
			*) : ;;  # tiann/KernelSU 0.9.x infers manual hooks from the source patch
		esac
		;;
	tracepoint)
		[ "$variant" = "resukisu" ] || [ "$variant" = "sukisu-ultra" ] \
			|| warn "hook mode 'tracepoint' is only declared by ReSukiSU/SukiSU-Ultra; ignoring for ${variant}"
		kconf_enable "$defconfig" CONFIG_KSU_TRACEPOINT_HOOK
		;;
	syscall)
		kconf_enable "$defconfig" CONFIG_KSU_SYSCALL_HOOK
		;;
	esac
}

# Only run the installer when sourced as a script entry point.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install "${KSU_VARIANT:-none}" "${KSU_REF:-}"
fi
