#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2023 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

function maybe_make_clean_uboot() {
	if [[ $CLEAN_LEVEL == *make-uboot* ]]; then
		display_alert "${uboot_prefix}Cleaning u-boot tree - CLEAN_LEVEL contains 'make-uboot'" "${BOOTSOURCEDIR}" "info"
		(
			cd "${SRC}/cache/sources/${BOOTSOURCEDIR}" || exit_with_error "crazy about ${BOOTSOURCEDIR}"
			run_host_command_logged make clean
		)
	else
		display_alert "${uboot_prefix}Not cleaning u-boot tree, use CLEAN_LEVEL=make-uboot if needed" "CLEAN_LEVEL=${CLEAN_LEVEL}" "debug"
	fi
}

function patch_uboot_target() {
	local uboot_work_dir=""
	uboot_work_dir="$(pwd)"

	# outer scope variable: uboot_git_revision, validate that it is set
	if [[ -z "${uboot_git_revision}" ]]; then
		exit_with_error "uboot_git_revision is not set"
	fi

	display_alert "${uboot_prefix} Checking out to clean sources SHA1 ${uboot_git_revision}" "{$BOOTSOURCEDIR} for ${target_make}"
	git checkout -f -q "${uboot_git_revision}"

	# remove all git untracked files; echo their names to screen
	# this throws away the baby with the bathwater; rebuilds will be slow. but the risk of shipping wrong binaries is too high.
	display_alert "${uboot_prefix} Cleaning u-boot tree" "${BOOTSOURCEDIR} for '${target_make}'"
	regular_git clean -xfdq

	maybe_make_clean_uboot

	# Python patching for u-boot!
	do_with_hooks uboot_main_patching_python

	# create patch for manual source changes
	if [[ $CREATE_PATCHES == yes ]]; then
		userpatch_create "u-boot"
	fi
}

# this receives version  target uboot_name uboottempdir uboot_target_counter toolchain as variables.
# also receives uboot_prefix, target_make, target_patchdir, target_files as input
function compile_uboot_target() {
	: "${artifact_version:?artifact_version is not set}"

	if [[ "${SHOW_DEBUG}" == "yes" ]]; then
		display_alert "${uboot_prefix}Listing contents of u-boot directory" "'${version}' '${target_make}' before patching" "debug"
		run_host_command_logged "ls -laht"
	fi

	patch_uboot_target

	if [[ "${SHOW_DEBUG}" == "yes" ]]; then
		display_alert "${uboot_prefix}Listing contents of u-boot directory" "'${version}' '${target_make}' after patching" "debug"
		run_host_command_logged "ls -laht"
	fi

	if [[ $CREATE_PATCHES == yes ]]; then
		return 0
	fi

	# atftempdir comes from atf.sh's compile_atf()
	if [[ -n $ATFSOURCE && -d "${atftempdir}" ]]; then
		display_alert "Copying over bin/elf/itb's from atftempdir" "${atftempdir}" "debug"
		run_host_command_logged cp -pv "${atftempdir}"/*.bin "${atftempdir}"/*.elf "${atftempdir}"/*.itb ./ # only works due to nullglob
		# atftempdir is under WORKDIR, so no cleanup necessary.
	fi

	# crusttempdir comes from crust.sh's compile_crust()
	if [[ -n $CRUSTSOURCE && -d "${crusttempdir}" ]]; then
		display_alert "Copying over bin/elf's from crusttempdir" "${crusttempdir}" "debug"
		run_host_command_logged cp -pv "${crusttempdir}"/*.bin "${crusttempdir}"/*.elf ./ # only works due to nullglob
	fi

	# Hook time, for extra post-processing
	call_extension_method "pre_config_uboot_target" <<- 'PRE_CONFIG_UBOOT_TARGET'
		*allow extensions prepare before configuring and compiling an u-boot target*
		Some u-boot targets require extra configuration or pre-processing before compiling.
		For example, changing Python version can be done by replacing the `${BIN_WORK_DIR}/python` symlink.
	PRE_CONFIG_UBOOT_TARGET

	display_alert "${uboot_prefix}Preparing u-boot config '${BOOTCONFIG}'" "${version} ${target_make}" "info"
	declare -g if_error_detail_message="${uboot_prefix}Failed to configure u-boot ${version} $BOOTCONFIG ${target_make}"
	run_host_command_logged CCACHE_BASEDIR="$(pwd)" PATH="${toolchain}:${toolchain2}:${PATH}" \
		"KCFLAGS=-fdiagnostics-color=always" \
		pipetty make "${CTHREADS}" "${BOOTCONFIG}" "CROSS_COMPILE=\"${CCACHE} ${UBOOT_COMPILER}\""

	# armbian specifics u-boot settings
	[[ -f .config ]] && sed -i "s/CONFIG_LOCALVERSION=\"\"/CONFIG_LOCALVERSION=\"-armbian-${artifact_version}\"/g" .config
	[[ -f .config ]] && sed -i 's/CONFIG_LOCALVERSION_AUTO=.*/# CONFIG_LOCALVERSION_AUTO is not set/g' .config

	# for modern (? 2018-2019?) kernel and non spi targets @TODO: this does not belong here
	if [[ ${BOOTBRANCH} =~ ^tag:v201[8-9](.*) && ${target} != "spi" && -f .config ]]; then
		display_alert "Hacking ENV stuff in u-boot config 2018-2019" "for ${target}" "debug"
		sed -i 's/^.*CONFIG_ENV_IS_IN_FAT.*/# CONFIG_ENV_IS_IN_FAT is not set/g' .config
		sed -i 's/^.*CONFIG_ENV_IS_IN_EXT4.*/CONFIG_ENV_IS_IN_EXT4=y/g' .config
		sed -i 's/^.*CONFIG_ENV_IS_IN_MMC.*/# CONFIG_ENV_IS_IN_MMC is not set/g' .config
		sed -i 's/^.*CONFIG_ENV_IS_NOWHERE.*/# CONFIG_ENV_IS_NOWHERE is not set/g' .config
		echo "# CONFIG_ENV_IS_NOWHERE is not set" >> .config
		echo 'CONFIG_ENV_EXT4_INTERFACE="mmc"' >> .config
		echo 'CONFIG_ENV_EXT4_DEVICE_AND_PART="0:auto"' >> .config
		echo 'CONFIG_ENV_EXT4_FILE="/boot/boot.env"' >> .config
	fi

	# @TODO: this does not belong here
	[[ -f tools/logos/udoo.bmp ]] && run_host_command_logged cp -pv "${SRC}"/packages/blobs/splash/udoo.bmp tools/logos/udoo.bmp

	# @TODO: why?
	touch .scmversion

	# use `scripts/config` instead of sed if available. Cleaner results.
	if [[ ! -f scripts/config ]]; then
		display_alert "scripts/config not found" "u-boot ${version} $BOOTCONFIG ${target_make}" "debug"
		# Old, pre-2022.10 u-boot; does not have the scripts/config script. Do it the old way.
		# $BOOTDELAY can be set in board family config, ensure autoboot can be stopped even if set to 0
		[[ $BOOTDELAY == 0 ]] && echo -e "CONFIG_ZERO_BOOTDELAY_CHECK=y" >> .config
		[[ -n $BOOTDELAY ]] && sed -i "s/^CONFIG_BOOTDELAY=.*/CONFIG_BOOTDELAY=${BOOTDELAY}/" .config || [[ -f .config ]] && echo "CONFIG_BOOTDELAY=${BOOTDELAY}" >> .config
	else
		display_alert "scripts/config found" "u-boot ${version} $BOOTCONFIG ${target_make}" "debug"

		# $BOOTDELAY can be set in board family config, ensure autoboot can be stopped even if set to 0
		if [[ $BOOTDELAY == 0 ]]; then
			display_alert "Adding CONFIG_ZERO_BOOTDELAY_CHECK=y u-boot config" "BOOTDELAY==0 for ${target}" "info"
			run_host_command_logged scripts/config --enable CONFIG_ZERO_BOOTDELAY_CHECK
		fi

		# If BOOTDELAY is set, either change a preexisting CONFIG_BOOTDELAY or add it
		if [[ -n $BOOTDELAY ]]; then
			display_alert "Hacking autoboot delay in u-boot config" "BOOTDELAY=${BOOTDELAY} for ${target}" "info"
			run_host_command_logged scripts/config --set-val CONFIG_BOOTDELAY "${BOOTDELAY}"
		fi

		# Hack, up the log level to 6: "info" (default is 4: "warning")
		display_alert "Hacking log level in u-boot config" "LOGLEVEL=6 for ${target}" "info"
		run_host_command_logged scripts/config --set-val CONFIG_LOGLEVEL 6
	fi

	if [[ "${UBOOT_DEBUGGING}" == "yes" ]]; then
		display_alert "Enabling u-boot debugging" "UBOOT_DEBUGGING=yes" "debug"

		# Remove unsets...
		cp .config .config.pre.debug
		cat .config.pre.debug | grep -v -e "CONFIG_LOG is not set" -e "CONFIG_ERRNO_STR" > .config
		rm .config.pre.debug

		# 0 - emergency ; 1 - alert; 2 - critical; 3 - error; 4 - warning; 5 - note; 6 - info; 7 - debug; 8 - debug content; 9 - debug hardware I/O
		cat <<- EXTRA_UBOOT_DEBUG_CONFIGS >> .config
			CONFIG_LOG=y
			CONFIG_LOG_MAX_LEVEL=7
			CONFIG_LOG_DEFAULT_LEVEL=7
			CONFIG_LOG_CONSOLE=y
			CONFIG_SPL_LOG=y
			CONFIG_SPL_LOG_MAX_LEVEL=6
			CONFIG_SPL_LOG_CONSOLE=y
			CONFIG_TPL_LOG=y
			CONFIG_TPL_LOG_MAX_LEVEL=6
			CONFIG_TPL_LOG_CONSOLE=y
			# CONFIG_ERRNO_STR is not set
		EXTRA_UBOOT_DEBUG_CONFIGS

		run_host_command_logged CCACHE_BASEDIR="$(pwd)" PATH="${toolchain}:${toolchain2}:${PATH}" \
			"KCFLAGS=-fdiagnostics-color=always" \
			pipetty make "olddefconfig" "CROSS_COMPILE=\"$CCACHE $UBOOT_COMPILER\""

	fi

	# cflags will be passed both as CFLAGS, KCFLAGS, and both as make params and as env variables. (some vendor u-boot's are cuckoo)
	# boards/families/extensions can customize this via the hook below
	local -a uboot_cflags_array=(
		"-fdiagnostics-color=always" # color messages
		"-Wno-error=maybe-uninitialized"
		"-Wno-error=misleading-indentation"   # patches have mismatching indentation
		"-Wno-error=attributes"               # for very old-uboots
		"-Wno-error=address-of-packed-member" # for very old-uboots
	)
	if linux-version compare "${gcc_version_main}" ge "11.0"; then
		uboot_cflags_array+=(
			"-Wno-error=array-parameter" # very old uboots
		)
	fi

	# Hook time, for extra post-processing
	call_extension_method "post_config_uboot_target" <<- 'POST_CONFIG_UBOOT_TARGET'
		*allow extensions prepare after configuring but before compiling an u-boot target*
		Some u-boot targets require extra configuration or pre-processing before compiling.
		Last chance to change .config for u-boot before compiling.
		Also the only chance to change the (local) array `uboot_cflags_array`.
	POST_CONFIG_UBOOT_TARGET

	# make olddefconfig, so changes made in hook above are consolidated
	display_alert "${uboot_prefix}Updating u-boot config with olddefconfig" "${version} ${target_make}" "info"
	run_host_command_logged CCACHE_BASEDIR="$(pwd)" PATH="${toolchain}:${toolchain2}:${PATH}" \
		"KCFLAGS=-fdiagnostics-color=always" \
		pipetty make "${CTHREADS}" "olddefconfig" "CROSS_COMPILE=\"${CCACHE} ${UBOOT_COMPILER}\""

	if [[ "${UBOOT_CONFIGURE:-"no"}" == "yes" ]]; then
		display_alert "Configuring u-boot" "UBOOT_CONFIGURE=yes; experimental" "warn"
		run_host_command_dialog make menuconfig
		display_alert "Exporting saved config" "UBOOT_CONFIGURE=yes; experimental" "warn"
		run_host_command_logged make savedefconfig
		run_host_command_logged cp -v defconfig "${DEST}/defconfig-uboot-${BOARD}-${BRANCH}"

		# check if we can find configs/${BOOTCONFIG}, and if so, output a diff between that and the new saved defconfig
		if [[ -f "configs/${BOOTCONFIG}" ]]; then
			display_alert "Diffing ${BOOTCONFIG} and new defconfig" "UBOOT_CONFIGURE=yes; experimental" "warn"
			run_host_command_logged diff -u --color=always "configs/${BOOTCONFIG}" "${DEST}/defconfig-uboot-${BOARD}-${BRANCH}" "2>&1" "|| true" # no errors please, all to stdout
		fi

		display_alert "Exporting saved config (experimental)" "${DEST}/defconfig-uboot-${BOARD}-${BRANCH}" "warn"

		return 0 # exit after this
	fi

	##########################################
	# REAL COMPILATION SECTION STARTING HERE #
	##########################################

	local uboot_cflags="${uboot_cflags_array[*]}"
	local ts=${SECONDS}

	# Collect make environment variables, similar to 'kernel-make.sh'
	uboot_make_envs=(
		"CFLAGS='${uboot_cflags}'"
		"KCFLAGS='${uboot_cflags}'"
		"CCACHE_BASEDIR=$(pwd)"
		"PATH=${toolchain}:${toolchain2}:${PATH}"
		"PYTHONPATH=\"${PYTHON3_INFO[MODULES_PATH]}:${PYTHONPATH}\"" # Insert the pip modules downloaded by Armbian into PYTHONPATH (needed e.g. for pyelftools)
	)

	# workaround when two compilers are needed
	cross_compile="CROSS_COMPILE=\"$CCACHE $UBOOT_COMPILER\""
	[[ -n $UBOOT_TOOLCHAIN2 ]] && cross_compile="ARMBIAN=foe" # empty parameter is not allowed

	display_alert "${uboot_prefix}Compiling u-boot" "${version} ${target_make} with gcc '${gcc_version_main}'" "info"
	declare -g if_error_detail_message="${uboot_prefix}Failed to build u-boot ${version} ${target_make}"
	do_with_ccache_statistics run_host_command_logged_long_running \
		"env" "-i" "${uboot_make_envs[@]}" \
		pipetty make "$target_make" "$CTHREADS" "${cross_compile}"

	display_alert "${uboot_prefix}built u-boot target" "${version} in $((SECONDS - ts)) seconds" "info"

	# Save a defconfig, as that will be included as reference in the .deb package
	# Do not fail here; some very (very!) old u-boots like 2011 do not have 'savedefconfig'
	run_host_command_logged "env" "-i" "${uboot_make_envs[@]}" pipetty make savedefconfig "$CTHREADS" "${cross_compile}" ||
		display_alert "${uboot_prefix}Failed to save defconfig" "${version} ${target_make}" "warn"

	if [[ $(type -t uboot_custom_postprocess) == function ]]; then
		display_alert "${uboot_prefix}Postprocessing u-boot" "${version} ${target_make}"
		uboot_custom_postprocess
	fi

	# Hook time, for extra post-processing
	call_extension_method "post_uboot_custom_postprocess" <<- 'POST_UBOOT_CUSTOM_POSTPROCESS'
		*allow extensions to do extra u-boot postprocessing, after uboot_custom_postprocess*
		For hacking at the produced binaries after u-boot is compiled and post-processed.
	POST_UBOOT_CUSTOM_POSTPROCESS

	declare -a target_dst_files=()                           # to be filled by deploy_built_uboot_bins_for_one_target_to_packaging_area
	deploy_built_uboot_bins_for_one_target_to_packaging_area # copy according to the target_files

	# Include metadata about the build, for reference; use the target_counter as part of filename to avoid overwriting
	# .config and defconfig go to ${uboottempdir}/usr/lib/${uboot_name}/u-boot-config-target-${target_counter}
	# ${uboottempdir}/usr/lib/${uboot_name}/u-boot-metadata-target-${uboot_target_counter}.sh has general metadata about the target
	cat <<- UBOOT_TARGET_METADATA_SH > "${uboottempdir}/usr/lib/${uboot_name}/u-boot-metadata-target-${uboot_target_counter}.sh"
		declare -a UBOOT_TARGET_BINS=(${target_dst_files[@]@Q})
		declare UBOOT_TARGET_MAKE=${target_make@Q}
	UBOOT_TARGET_METADATA_SH

	if [[ -f .config ]]; then # Not all u-boots have .config; some very old did boards.cfg or whatever. Ignore in this case
		run_host_command_logged cp -v .config "${uboottempdir}/usr/lib/${uboot_name}/u-boot-config-target-${uboot_target_counter}"
		cat <<- UBOOT_TARGET_METADATA_SH >> "${uboottempdir}/usr/lib/${uboot_name}/u-boot-metadata-target-${uboot_target_counter}.sh"
			declare UBOOT_TARGET_CONFIG="u-boot-config-target-${uboot_target_counter}"
		UBOOT_TARGET_METADATA_SH
	fi

	if [[ -f defconfig ]]; then # Not all u-boots are capable of savedefconfig, and thus defconfig will not be available
		run_host_command_logged cp -v defconfig "${uboottempdir}/usr/lib/${uboot_name}/u-boot-defconfig-target-${uboot_target_counter}"
		cat <<- UBOOT_TARGET_METADATA_SH >> "${uboottempdir}/usr/lib/${uboot_name}/u-boot-metadata-target-${uboot_target_counter}.sh"
			declare UBOOT_TARGET_DEFCONFIG="u-boot-defconfig-target-${uboot_target_counter}"
		UBOOT_TARGET_METADATA_SH
	fi

	if [[ $DEBUG == yes ]]; then
		display_alert "${uboot_prefix}Showing u-boot metadata for target" "${version} ${target_make}" "debug"
		run_tool_batcat --file-name "/usr/lib/${uboot_name}/u-boot-metadata-target-${uboot_target_counter}.sh" "${uboottempdir}/usr/lib/${uboot_name}/u-boot-metadata-target-${uboot_target_counter}.sh"
	fi

	display_alert "${uboot_prefix}Done with u-boot target" "${version} ${target_make}"
	return 0
}

function loop_over_uboot_targets_and_do() {
	# Try very hard, to fault even, to avoid using subshells while reading a newline-delimited string.
	# Sorry for the juggling with IFS.
	declare _old_ifs="${IFS}" _new_ifs=$'\n'
	IFS="${_new_ifs}" # split on newlines only
	display_alert "Looping over u-boot targets" "'${UBOOT_TARGET_MAP}'" "debug"
	declare -i uboot_target_counter=1

	# save the current state of nullglob into a variable; don't fail
	declare _old_nullglob
	_old_nullglob="$(shopt -p nullglob || true)"
	display_alert "previous state of nullglob" "'${_old_nullglob}'" "debug"

	# disable nullglob; dont fail if already disabled
	shopt -u nullglob || true

	# store new state; don't fail
	declare _new_nullglob
	_new_nullglob="$(shopt -p nullglob || true)"
	display_alert "new state of nullglob" "'${_new_nullglob}'" "debug"

	for target in ${UBOOT_TARGET_MAP}; do
		display_alert "Building u-boot target" "'${target}'" "debug"

		# reset nullglob to _old_nullglob
		eval "${_old_nullglob}"

		IFS="${_old_ifs}" # restore for the body of loop
		declare -g target uboot_name uboottempdir toolchain version
		declare -g uboot_prefix="{u-boot:${uboot_target_counter}} "
		declare -g target_make target_patchdir target_files
		target_make=$(cut -d';' -f1 <<< "${target}")
		target_patchdir=$(cut -d';' -f2 <<< "${target}")
		target_files=$(cut -d';' -f3 <<< "${target}")
		# Invoke our parameters directly
		"$@"
		# Increment the counter
		uboot_target_counter=$((uboot_target_counter + 1))
		IFS="${_new_ifs}" # split on newlines only for rest of loop
	done

	IFS="${_old_ifs}"
	# reset nullglob to _old_nullglob
	eval "${_old_nullglob}"

	uboot_target_counter=$((uboot_target_counter - 1))           # decrement, as we incremented after the last target
	declare -g -i uboot_target_counter="${uboot_target_counter}" # set global, for metadata ("how many targets?")

	return 0
}

function deploy_built_uboot_bins_for_one_target_to_packaging_area() {
	display_alert "${uboot_prefix}Preparing u-boot targets packaging" "${version} ${target_make}"
	# copy files to build directory
	declare f
	for f in $target_files; do
		declare f_src f_dst
		f_src=$(cut -d':' -f1 <<< "${f}")
		if [[ $f == *:* ]]; then
			f_dst=$(cut -d':' -f2 <<< "${f}")
		else
			f_dst=$(basename "${f_src}")
		fi
		display_alert "${uboot_prefix}Deploying u-boot binary target" "${version} ${target_make} :: ${f_dst}"
		[[ ! -f $f_src ]] && exit_with_error "U-boot artifact not found" "$(basename "${f_src}")"
		run_host_command_logged cp -v "${f_src}" "${uboottempdir}/usr/lib/${uboot_name}/${f_dst}"
		#display_alert "Done with binary target" "${version} ${target_make} :: ${f_dst}"
		target_dst_files+=("${f_dst}") # for metadata
	done
	return 0
}

function compile_uboot() {
	: "${artifact_version:?artifact_version is not set}"

	display_alert "Compiling u-boot" "BOOTSOURCE: ${BOOTSOURCE}" "debug"
	if [[ -n $BOOTSOURCE ]] && [[ "${BOOTSOURCE}" != "none" ]]; then
		display_alert "Extensions: fetch custom uboot" "fetch_custom_uboot" "debug"
		call_extension_method "fetch_custom_uboot" <<- 'FETCH_CUSTOM_UBOOT'
			*allow extensions to fetch extra uboot sources*
			For downstream uboot et al.
			This is done after `fetch_from_repo`, but before actually compiling u-boot.
		FETCH_CUSTOM_UBOOT
	fi

	# not optimal, but extra cleaning before overlayfs_wrapper should keep sources directory clean
	maybe_make_clean_uboot

	if [[ $USE_OVERLAYFS == yes ]]; then
		local ubootdir
		ubootdir=$(overlayfs_wrapper "wrap" "$SRC/cache/sources/$BOOTSOURCEDIR" "u-boot_${LINUXFAMILY}_${BRANCH}")
	else
		local ubootdir="$SRC/cache/sources/$BOOTSOURCEDIR"
	fi
	cd "${ubootdir}" || exit

	# read uboot version
	local version hash
	version=$(grab_version "$ubootdir")
	hash=$(git --git-dir="$ubootdir"/.git rev-parse HEAD)

	display_alert "Compiling u-boot" "$version ${ubootdir}" "info"

	# build aarch64
	if [[ $(dpkg --print-architecture) == amd64 ]]; then
		local toolchain
		toolchain=$(find_toolchain "$UBOOT_COMPILER" "$UBOOT_USE_GCC")
		[[ -z $toolchain ]] && exit_with_error "Could not find required toolchain" "${UBOOT_COMPILER}gcc $UBOOT_USE_GCC"

		if [[ -n $UBOOT_TOOLCHAIN2 ]]; then
			local toolchain2_type toolchain2_ver toolchain2
			toolchain2_type=$(cut -d':' -f1 <<< "${UBOOT_TOOLCHAIN2}")
			toolchain2_ver=$(cut -d':' -f2 <<< "${UBOOT_TOOLCHAIN2}")
			toolchain2=$(find_toolchain "$toolchain2_type" "$toolchain2_ver")
			[[ -z $toolchain2 ]] && exit_with_error "Could not find required toolchain" "${toolchain2_type}gcc $toolchain2_ver"
		fi
		# build aarch64
	fi

	declare gcc_version_main
	gcc_version_main="$(eval env PATH="${toolchain}:${toolchain2}:${PATH}" "${UBOOT_COMPILER}gcc" -dumpfullversion -dumpversion)"
	display_alert "Compiler version" "${UBOOT_COMPILER}gcc '${gcc_version_main}'" "info"
	[[ -n $toolchain2 ]] && display_alert "Additional compiler version" "${toolchain2_type}gcc $(eval env PATH="${toolchain}:${toolchain2}:${PATH}" "${toolchain2_type}gcc" -dumpfullversion -dumpversion)" "info"

	local uboot_name="linux-u-boot-${BRANCH}-${BOARD}"

	# create directory structure for the .deb package
	declare cleanup_id="" uboottempdir=""
	prepare_temp_dir_in_workdir_and_schedule_cleanup "uboot" cleanup_id uboottempdir # namerefs

	mkdir -p "$uboottempdir/usr/lib/u-boot" "$uboottempdir/usr/lib/$uboot_name" "$uboottempdir/DEBIAN"

	# Allow extension-based u-boot bulding. We call the hook, and if EXTENSION_BUILT_UBOOT="yes" afterwards, we skip our own compilation.
	# This is to make it easy to build vendor/downstream uboot with their own quirks.

	display_alert "Extensions: build custom uboot" "build_custom_uboot" "debug"
	call_extension_method "build_custom_uboot" <<- 'BUILD_CUSTOM_UBOOT'
		*allow extensions to build their own uboot*
		For downstream uboot et al.
		Set \`EXTENSION_BUILT_UBOOT=yes\` to then skip the normal compilation.
	BUILD_CUSTOM_UBOOT

	if [[ "${EXTENSION_BUILT_UBOOT}" != "yes" ]]; then
		loop_over_uboot_targets_and_do compile_uboot_target
	else
		display_alert "Extensions: custom uboot built by extension" "not building regular uboot" "debug"
	fi

	if [[ "${ARTIFACT_WILL_NOT_BUILD:-"no"}" == "yes" ]]; then
		display_alert "Extensions: artifact will not build" "not building regular uboot" "debug"
		return 0
	fi

	display_alert "Preparing u-boot general packaging" "${version} ${target_make}"

	local -a postinst_functions=()
	local destination=$uboottempdir

	call_extension_method "pre_package_uboot_image" <<- 'PRE_PACKAGE_UBOOT_IMAGE'
		*allow making some last minute changes before u-boot is packaged*
		This should be implemented by the config to tweak the uboot package, after the board or family has had the chance to.
		You can write to `$destination` here and it will be packaged.
		You can also append to the `postinst_functions` array, and the _content_ of those functions will be added to the postinst script.
	PRE_PACKAGE_UBOOT_IMAGE

	artifact_package_hook_helper_board_side_functions "postinst" uboot_postinst_base "${postinst_functions[@]}"
	unset uboot_postinst_base postinst_functions destination

	# declare -f on non-defined function does not do anything (but exits with errors, so ignore them with "|| true")
	cat <<- EOF > "${uboottempdir}/usr/lib/u-boot/platform_install.sh"
		# Armbian u-boot install script for linux-u-boot-${BOARD}-${BRANCH} ${artifact_version}
		# This file provides functions for deploying u-boot to a block device.
		DIR=/usr/lib/$uboot_name
		$(declare -f write_uboot_platform || true)
		$(declare -f write_uboot_platform_mtd || true)
		$(declare -f setup_write_uboot_platform || true)
	EOF

	if [[ "${SHOW_DEBUG}" == "yes" ]]; then
		display_alert "Showing contents of" "usr/lib/u-boot/platform_install.sh" "info"
		run_tool_batcat --file-name "usr/lib/u-boot/platform_install.sh" "${uboottempdir}/usr/lib/u-boot/platform_install.sh"
	fi

	# Write general metadata. This is intended to be used board-side, and allows some better gui and reuse.
	# Ensure that all variables used here are hashed in the artifact-uboot.sh during version calculation.
	cat <<- UBOOT_GENERAL_METADATA_SH > "${uboottempdir}/usr/lib/${uboot_name}/u-boot-metadata.sh"
		declare -i UBOOT_NUM_TARGETS=${uboot_target_counter}
		declare UBOOT_BIN_DIR="/usr/lib/${uboot_name}"
		declare UBOOT_VERSION="${version}"
		declare UBOOT_ARTIFACT_VERSION="${artifact_version}"
		declare UBOOT_GIT_REVISION="${hash}"
		declare UBOOT_GIT_SOURCE="${BOOTSOURCE}"
		declare UBOOT_GIT_BRANCH="${BOOTBRANCH}"
		declare UBOOT_GIT_PATCHDIR="${BOOTPATCHDIR}"
		declare UBOOT_PARTITION_TYPE="${IMAGE_PARTITION_TABLE}"
		declare UBOOT_KERNEL_DTB="${BOOT_FDT_FILE}"
		declare UBOOT_KERNEL_SERIALCON="${SERIALCON}"
		declare UBOOT_EXTLINUX_PREFER="${SRC_EXTLINUX:-"no"}"
		declare UBOOT_EXTLINUX_CMDLINE="${SRC_CMDLINE}"
	UBOOT_GENERAL_METADATA_SH

	if [[ $DEBUG == yes ]]; then
		display_alert "${uboot_prefix}Showing u-boot metadata for target" "${version} ${target_make}" "debug"
		run_tool_batcat --file-name "/usr/lib/${uboot_name}/u-boot-metadata.sh" "${uboottempdir}/usr/lib/${uboot_name}/u-boot-metadata.sh"
	fi

	display_alert "Running shellcheck" "usr/lib/u-boot/platform_install.sh" "info"
	shellcheck_debian_control_scripts "${uboottempdir}/usr/lib/u-boot/platform_install.sh"

	display_alert "Das U-Boot .deb package version" "${artifact_version}" "info"

	# set up control file
	cat <<- EOF > "$uboottempdir/DEBIAN/control"
		Package: linux-u-boot-${BOARD}-${BRANCH}
		Version: ${artifact_version}
		Architecture: $ARCH
		Maintainer: $MAINTAINER <$MAINTAINERMAIL>
		Section: kernel
		Priority: optional
		Provides: armbian-u-boot
		Replaces: armbian-u-boot
		Conflicts: armbian-u-boot, u-boot-sunxi
		Description: Das U-Boot for ${BOARD}
		 ${artifact_version_reason:-"${version}"}
	EOF

	# copy license files, config, etc.
	[[ -f .config && -n $BOOTCONFIG ]] && run_host_command_logged cp .config "$uboottempdir/usr/lib/u-boot/${BOOTCONFIG}" # legacy and @TODO should be removed as it has only the last target; we now have per-target configs and defconfigs
	[[ -f COPYING ]] && run_host_command_logged cp COPYING "$uboottempdir/usr/lib/u-boot/LICENSE"
	[[ -f Licenses/README ]] && run_host_command_logged cp Licenses/README "$uboottempdir/usr/lib/u-boot/LICENSE"
	[[ -n $atftempdir && -f $atftempdir/license.md ]] && run_host_command_logged cp "${atftempdir}/license.md" "$uboottempdir/usr/lib/u-boot/LICENSE.atf"

	display_alert "Building u-boot deb" "(version: ${artifact_version})"
	dpkg_deb_build "$uboottempdir" "uboot"

	[[ -n $atftempdir ]] && rm -rf "${atftempdir:?}" # @TODO: intricate cleanup; u-boot's pkg uses ATF's tempdir...

	done_with_temp_dir "${cleanup_id}" # changes cwd to "${SRC}" and fires the cleanup function early

	display_alert "Built u-boot deb OK" "linux-u-boot-${BOARD}-${BRANCH} ${artifact_version}" "info"
	return 0 # success
}

function uboot_postinst_base() {
	# Source the armbian-release information file
	# shellcheck source=/dev/null
	[ -f /etc/armbian-release ] && . /etc/armbian-release
	# shellcheck source=/dev/null
	source /usr/lib/u-boot/platform_install.sh

	if [ "${FORCE_UBOOT_UPDATE:-no}" == "yes" ]; then
		#recognize_root
		root_uuid=$(sed -e 's/^.*root=//' -e 's/ .*$//' < /proc/cmdline)
		root_partition=$(blkid | tr -d '":' | grep "${root_uuid}" | awk '{print $1}')
		root_partition_name=$(echo $root_partition | sed 's/\/dev\///g')
		root_partition_device_name=$(lsblk -ndo pkname $root_partition)
		root_partition_device=/dev/$root_partition_device_name

		write_uboot_platform "$DIR" "${root_partition_device}"
		sync
	fi
}
