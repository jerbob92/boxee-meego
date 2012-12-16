#!/bin/bash

STATIC_HOST_TOOLS=1

TOOLCHAIN_ROOT="$(pwd)"

INSTALL_DIR="${TOOLCHAIN_ROOT}/.install-$(uname -m)"
mkdir -p ${INSTALL_DIR} || exit 1

BUILD_ROOT="${TOOLCHAIN_ROOT}/.build-$(uname -m)"
mkdir -p ${BUILD_ROOT} || exit 1

BOOTSTRAP_DIR="${TOOLCHAIN_ROOT}/.bootstrap-$(uname -m)"
mkdir -p ${BOOTSTRAP_DIR} || exit 1

CPU_NR=$(grep -c processor /proc/cpuinfo)
PARALLELMFLAGS="-j$((CPU_NR + 1))"

ORIG_PATH="${PATH}"

THUMB2LIB_DIR_NAME="thumb2"

build_bootstrap_lib()
{
	local src_dir="$1"
	shift 1

	PATH="${ORIG_PATH}"

	local build_dir="${BUILD_ROOT}/$(basename ${src_dir})-bootstrap"
	mkdir -p "${build_dir}" || exit 1
	pushd "${build_dir}" || exit 1

	"${src_dir}/configure" \
		--prefix="${BOOTSTRAP_DIR}" \
		--disable-shared \
		"$@" || exit 1

	make ${PARALLELMFLAGS} || exit 1
	make check || exit 1
	make install || exit 1

	popd
}

build_cross_pkg_config()
{
	local target="$1"
	local tool_prefix="$2"
	shift 2

	PATH="${ORIG_PATH}"

	local build_dir="${BUILD_ROOT}/pkg-config-${target}"
	mkdir -p "${build_dir}" || exit 1
	pushd "${build_dir}" || exit 1

	"${TOOLCHAIN_ROOT}/pkg-config/configure" \
		--prefix="${INSTALL_DIR}" \
		--program-prefix="${tool_prefix}" \
		--with-sysroot="../target-${target}" \
		--with-pc-path="/usr/lib/pkgconfig:/usr/share/pkgconfig" \
		--mandir="${INSTALL_DIR}/share/man" \
		--infodir="${INSTALL_DIR}/share/info" \
		"$@" || exit 1

	local static_opts
	if [[ "${STATIC_HOST_TOOLS}" == "1" ]]; then
		static_opts=(
			CCLD="gcc -all-static"
		)
	fi

	make ${PARALLELMFLAGS} "${static_opts[@]}" || exit 1
	make install || exit 1

	rm "${INSTALL_DIR}/share/aclocal/pkg.m4" || exit 1
	rmdir "${INSTALL_DIR}/share/aclocal"

	popd
}

build_cross_binutils()
{
	local target="$1"
	local tool_prefix="$2"
	shift 2

	PATH="${ORIG_PATH}"

	local sysroot="${INSTALL_DIR}/target-${target}"
	mkdir -p "${sysroot}" || exit 1

	local build_dir="${BUILD_ROOT}/binutils-${target}"
	mkdir -p "${build_dir}" || exit 1
	pushd "${build_dir}" || exit 1

	"${TOOLCHAIN_ROOT}/binutils/configure" \
		--prefix="${INSTALL_DIR}" \
		--target="${target}" \
		--with-build-sysroot="${sysroot}" \
		--with-sysroot="${sysroot}" \
		--program-prefix="${tool_prefix}" \
		--mandir="${INSTALL_DIR}/share/man" \
		--infodir="${INSTALL_DIR}/share/info" \
		--disable-nls \
		"$@" || exit 1

	local static_opts
	if [[ "${STATIC_HOST_TOOLS}" == "1" ]]; then
		static_opts=(
			CCLD="gcc -all-static"
		)
	fi

	touch "${TOOLCHAIN_ROOT}/binutils/binutils/"sys{info,lex}.c || exit 1

	make ${PARALLELMFLAGS} "${static_opts[@]}" || exit 1
	make install || exit 1

	for f in ar as ld ld.bfd nm objcopy objdump ranlib strip; do
		rm -f "${INSTALL_DIR}/${target}/bin/${f}" || exit 1
		ln -s "../../bin/${tool_prefix}${f}" "${INSTALL_DIR}/${target}/bin/${f}" || exit 1
	done

	# Move ldscripts to sysroot
	local cross_ldscripts_dir="${INSTALL_DIR}/${target}/lib/ldscripts"
	local target_ldscripts_dir="${sysroot}/usr/${target}/lib/ldscripts"
	mkdir -p "${target_ldscripts_dir}" || exit 1
	mv -fv "${cross_ldscripts_dir}" "$(dirname ${target_ldscripts_dir})" || exit 1
	rm -f "${cross_ldscripts_dir}" || exit 1
	ln -sfv "../../target-${target}/usr/${target}/lib/ldscripts" "${cross_ldscripts_dir}" || exit 1

	rm -f "${INSTALL_DIR}/lib/libiberty.a" || exit 1
	rmdir "${INSTALL_DIR}/lib"

	popd
}

# Get version tag for the latest commit that could have affected toolchain
toolchain_version_tag()
{
	local paths="binutils eglibc gcc gmp kernel-headers libelf mpc mpfr build.sh"
	local hash=$(git rev-list --first-parent --max-count=1 HEAD -- ${paths} 2> /dev/null)

	if [[ -n "${hash}" ]]; then
		local ts=$(git show ${hash} --format="%ad" --date=short | head -n 1 | sed 's/-//g')
		echo "${ts}-${hash}" | cut -c -16
	else
		date +%Y%m%d
	fi
}

build_cross_gcc()
{
	local stage="$1"
	local target="$2"
	local tool_prefix="$3"
	shift 3

	PATH="${BOOTSTRAP_DIR}/bin:${INSTALL_DIR}/bin:${ORIG_PATH}"

	local sysroot="${INSTALL_DIR}/target-${target}"

	local prefix stage_opts
	case ${stage} in
	bootstrap)
		prefix="${BOOTSTRAP_DIR}"
		stage_opts=(
			--enable-languages=c
			--with-newlib
			--disable-libgcc
			--disable-shared
			--disable-threads
			--without-headers
		)
		;;
	c-only)
		prefix="${BOOTSTRAP_DIR}"
		stage_opts=(
			--enable-languages=c
			--with-sysroot="${sysroot}"
			--enable-threads=posix
			--enable-tls
		)
		;;
	final)
		prefix="${INSTALL_DIR}"
		stage_opts=(
			--with-sysroot="${sysroot}"
			--libdir="${sysroot}/usr/lib"
			--enable-languages="c,c++"
			--enable-linker-build-id
			--enable-lto
			--enable-tls
			--enable-threads=posix
			--enable-version-specific-runtime-libs
		)
		if [[ "${STATIC_HOST_TOOLS}" == "1" ]]; then
			stage_opts=(
				"${stage_opts[@]}"
				LDFLAGS="-static"
			)
		fi
		;;
	*)
		echo "Invalid GCC build stage - ${stage}" 1>&2
		exit 1
	esac

	if [[ "${prefix}" != "${INSTALL_DIR}" ]]; then
		stage_opts=(
			"${stage_opts[@]}"
			--with-as="${INSTALL_DIR}/bin/${tool_prefix}as"
			--with-ld="${INSTALL_DIR}/bin/${tool_prefix}ld"
		)
	fi

	local version_tag=$(toolchain_version_tag)

	local build_dir="${BUILD_ROOT}/gcc-${target}-${stage}"
	mkdir -p "${build_dir}" || exit 1
	pushd "${build_dir}" || exit 1

	"${TOOLCHAIN_ROOT}/gcc/configure" \
		--prefix="${prefix}" \
		--target="${target}" \
		--program-prefix="${tool_prefix}" \
		--mandir="${prefix}/share/man" \
		--infodir="${prefix}/share/info" \
		--with-gnu-as \
		--with-gnu-ld \
		--with-gmp="${BOOTSTRAP_DIR}" \
		--with-libelf="${BOOTSTRAP_DIR}" \
		--with-mpc="${BOOTSTRAP_DIR}" \
		--with-mpfr="${BOOTSTRAP_DIR}" \
		--enable-__cxa_atexit \
		--disable-libgomp \
		--disable-libmudflap \
		--disable-libssp \
		--disable-nls \
		--disable-plugin \
		--without-cloog \
		--without-ppl \
		--with-pkgversion="gtv ${version_tag}" \
		"${stage_opts[@]}" \
		"$@" || exit 1

	make ${PARALLELMFLAGS} || exit 1
	make install || exit 1

	if [[ "${stage}" == "final" ]]; then
		for f in c++ g++ gcc; do
			rm -f "${INSTALL_DIR}/${target}/bin/${f}" || exit 1
			ln -s "../../bin/${tool_prefix}${f}" "${INSTALL_DIR}/${target}/bin/${f}" || exit 1
		done

		local version=$(${INSTALL_DIR}/bin/${tool_prefix}gcc -dumpversion)
		rm -f "${INSTALL_DIR}/bin/${tool_prefix}gcc" || exit 1
		ln -s "${tool_prefix}gcc-${version}" "${INSTALL_DIR}/bin/${tool_prefix}gcc" || exit 1

		rm -f "${INSTALL_DIR}/bin/${tool_prefix}c++" || exit 1
		ln -s "${tool_prefix}g++" "${INSTALL_DIR}/bin/${tool_prefix}c++" || exit 1

		for d in . ${THUMB2LIB_DIR_NAME}; do
			local gcc_dir="${sysroot}/usr/lib/gcc/${target}/${version}/${d}"

                        # .so libraries with -mthumb (thumb2) will overwrite -marm (default) libraries.
			chmod a+x "${gcc_dir}/libgcc_s.so.1"
			mv -f "${gcc_dir}/lib"*.so* "${sysroot}/lib"

			rm -f "${sysroot}/usr/lib/${d}/libiberty.a" || exit 1
			rm -f "${INSTALL_DIR}/${target}/lib/${d}/libiberty.a" || exit 1

			rm -rf "${gcc_dir}/install-tools" || exit 1
			rm -rf "${gcc_dir}/"*.la || exit 1
		done

		rmdir "${INSTALL_DIR}/include"

		rm -rf "${INSTALL_DIR}/share/gcc-${version}/python" || exit 1
		rmdir "${INSTALL_DIR}/share/gcc-${version}"
		rm -f "${INSTALL_DIR}/target-${target}/lib/"*-gdb.py || exit 1
		rm -rf "${INSTALL_DIR}/libexec/gcc/${target}/${version}/install-tools" || exit 1
	fi

	popd
}

install_kernel_headers()
{
	local target="$1"
	local arch="$2"

	PATH="${ORIG_PATH}"

	local src_dir="${TOOLCHAIN_ROOT}/kernel-headers"
	local sysroot_include="${INSTALL_DIR}/target-${target}/usr/include"

	for d in asm-generic drm linux mtd rdma scsi sound video; do
		mkdir -p "${sysroot_include}/${d}" || exit 1
		rsync -a "${src_dir}/${d}/" "${sysroot_include}/${d}" || exit 1
	done

	mkdir -p "${sysroot_include}/asm" || exit 1
	rsync -a "${src_dir}/asm-${arch}/" "${sysroot_include}/asm" || exit 1
}

build_target_glibc()
{
	local stage="$1"
	local target="$2"
	local tool_prefix="$3"
	local kernel_abi="$4"
	shift 4

	PATH="${BOOTSTRAP_DIR}/bin:${INSTALL_DIR}/bin:${ORIG_PATH}"

	local sysroot="${INSTALL_DIR}/target-${target}"
	
	local build_dir="${BUILD_ROOT}/eglibc-${target}-${stage}"
	mkdir -p "${build_dir}" || exit 1
	pushd "${build_dir}" || exit 1

	local build_cc=gcc
	local cross_cc="${BOOTSTRAP_DIR}/bin/${tool_prefix}gcc"
	local cross_cxx="${BOOTSTRAP_DIR}/bin/${tool_prefix}g++"
	local lib_dir="/usr/lib"

	if [[ "${stage}" == *"-thumb" ]]; then
		cross_cc="${cross_cc} -mthumb"
		cross_cxx="${cross_cxx} -mthumb"
		lib_dir="${lib_dir}/${THUMB2LIB_DIR_NAME}"
	fi

	echo "LINGUAS=" > configparms
	echo "BUILD_CC := ${build_cc}" >> configparms
	echo "CC := ${cross_cc}" >> configparms
	echo "CXX := ${cross_cxx}" >> configparms
	echo "AR := ${INSTALL_DIR}/bin/${tool_prefix}ar" >> configparms
	echo "LD := ${INSTALL_DIR}/bin/${tool_prefix}ld" >> configparms
	echo "NM := ${INSTALL_DIR}/bin/${tool_prefix}nm" >> configparms
	echo "OBJDUMP := ${INSTALL_DIR}/bin/${tool_prefix}objdump" >> configparms
	echo "RANLIB := ${INSTALL_DIR}/bin/${tool_prefix}ranlib" >>  configparms

	BUILD_CC="${build_cc}" \
	CC="${cross_cc}" \
	CXX="${cross_cxx}" \
	"${TOOLCHAIN_ROOT}/eglibc/configure" \
		--prefix=/usr \
		--libdir=${lib_dir} \
		--host="${target}" \
		--with-headers="${sysroot}/usr/include" \
		--with-__thread \
		--with-tls \
		--enable-add-ons=nptl \
		--enable-kernel="${kernel_abi}" \
		--enable-static-nss \
		--mandir=/usr/share/man \
		--infodir=/usr/share/info \
		--without-cvs \
		--without-gd \
		"$@" || exit 1

	case ${stage} in
	bootstrap)
		PARALLELMFLAGS=${PARALLELMFLAGS} \
		make \
			install-headers \
			install_root="${sysroot}" \
			install-bootstrap-headers="yes" || exit 1

		PARALLELMFLAGS=${PARALLELMFLAGS} make csu/subdir_lib || exit 1
		mkdir -p "${sysroot}${lib_dir}" || exit 1
		cp csu/crt{1,i,n}.o "${sysroot}${lib_dir}" || exit 1

		"${cross_cc}" -nostdlib -nostartfiles -shared \
			-x c /dev/null -o "${sysroot}${lib_dir}/libc.so" || exit 1
		;;
	final)
		touch "${TOOLCHAIN_ROOT}/eglibc/intl/plural.c" || exit 1
		PARALLELMFLAGS=${PARALLELMFLAGS} make user-defined-trusted-dirs="/system/lib" || exit 1
		make install_root="${sysroot}" install || exit 1
		
		# Remove stuff we don't need
		rm -f "${sysroot}/etc/localtime" || exit 1
		rm -f "${sysroot}/etc/rpc" || exit 1
		rmdir "${sysroot}/etc"

		for l in BrokenLocale SegFault anl memusage nss_nis \
			 nss_nisplus pcprofile; do
			rm -f "${sysroot}/lib/lib${l}"* || exit 1
			rm -f "${sysroot}${lib_dir}/lib${l}"* || exit 1
		done

		for f in catchsegv gencat getconf getent iconv lddlibc4 locale \
			localedef mtrace pcprofiledump rpcgen sprof tzselect xtrace; do
			rm -f "${sysroot}/usr/bin/${f}" || exit 1
		done

		rm -f "${sysroot}${lib_dir}/"*.map || exit 1
		rm -rf "${sysroot}${lib_dir}/gconv" || exit 1
		
		rm -rf "${sysroot}/usr/libexec/getconf" || exit 1
		rm -f "${sysroot}/usr/libexec/pt_chown" || exit 1
		rmdir "${sysroot}/usr/libexec/"
		rm -f "${sysroot}/usr/sbin/"{zdump,zic} || exit 1
		rm -rf "${sysroot}/usr/share/i18n" || exit 1
		rm -rf "${sysroot}/usr/share/zoneinfo" || exit 1
		;;
	final-thumb)
		sysroot="${sysroot}/${THUMB2LIB_DIR_NAME}"

		touch "${TOOLCHAIN_ROOT}/eglibc/intl/plural.c" || exit 1
		PARALLELMFLAGS=${PARALLELMFLAGS} make user-defined-trusted-dirs="/system/lib" || exit 1
		make install_root="${sysroot}" install || exit 1

		# Copy thumb libraries to proper locations
		rsync -a --existing --exclude="libm"* "${sysroot}/lib/"* "${sysroot}/../lib/"
		rsync -a --exclude="libm"* "${sysroot}${lib_dir}/"* "${sysroot}/..${lib_dir}"

		# Clean
		diff -rq "${sysroot}/..${lib_dir}" "${sysroot}/..${lib_dir}/.." \
			| grep -e '^Only in' | awk '{print $4}' \
			| xargs -I {} rm -rf "${sysroot}/..${lib_dir}/"{}
		rm -rf "${sysroot}"
                ;;
	*)
		echo "Invalid EGLIBC build stage - ${stage}" 1>&2
		exit 1
	esac

	popd
}

build_cross_gdb()
{
	local target="$1"
	local tool_prefix="$2"

	PATH="${INSTALL_DIR}/bin:${ORIG_PATH}"

	local sysroot="${INSTALL_DIR}/target-${target}"

	local build_dir="${BUILD_ROOT}/gdb-${target}-host"
	mkdir -p "${build_dir}" || exit 1
	pushd "${build_dir}" || exit 1

	"${TOOLCHAIN_ROOT}/gdb/configure" \
		--prefix="${INSTALL_DIR}" \
		--target="${target}" \
		--program-prefix="${tool_prefix}" \
		--with-sysroot="${sysroot}" \
		--mandir="${INSTALL_DIR}/share/man" \
		--infodir="${INSTALL_DIR}/share/info" \
		--with-gmp="${BOOTSTRAP_DIR}" \
		--with-mpfr="${BOOTSTRAP_DIR}" \
		--with-expat=yes \
		--with-python=no \
		--disable-nls || exit 1

	touch "${TOOLCHAIN_ROOT}/gdb/gdb/ada-lex.c" || exit 1

	local static_opts
	if [[ "${STATIC_HOST_TOOLS}" == "1" ]]; then
		static_opts=(
			CCLD="gcc -all-static"
			CC_LD="gcc -static"
		)
	fi

	make ${PARALLELMFLAGS} "${static_opts[@]}" || exit 1
	make install || exit 1

	rm -f "${INSTALL_DIR}/lib/libiberty.a" || exit 1
	rmdir "${INSTALL_DIR}/lib"

	popd
}

build_target_gdbserver()
{
	local target="$1"
	local tool_prefix="$2"

	PATH="${INSTALL_DIR}/bin:${ORIG_PATH}"

	local sysroot="${INSTALL_DIR}/target-${target}"
	local cross_cc="${INSTALL_DIR}/bin/${tool_prefix}gcc"

	local build_dir="${BUILD_ROOT}/gdbserver-${target}"
	mkdir -p "${build_dir}" || exit 1
	pushd "${build_dir}" || exit 1

	CC="${cross_cc}" \
	"${TOOLCHAIN_ROOT}/gdb/gdb/gdbserver/configure" \
		--prefix=/usr \
		--host="${target}" \
		--with-libthread-db="${sysroot}/lib/libthread_db.so.1" \
		--mandir=/usr/share/man || exit 1

	CC="${cross_cc}" \
	make ${PARALLELMFLAGS} || exit 1

	make \
		prefix="${sysroot}/usr" \
		mandir="${sysroot}/usr/share/man" \
		install || exit 1

	popd
}

build_target_binutils()
{
	local target="$1"
	local tool_prefix="$2"

	PATH="${INSTALL_DIR}/bin:${ORIG_PATH}"

	local sysroot="${INSTALL_DIR}/target-${target}"
	local cross_cc="${INSTALL_DIR}/bin/${tool_prefix}gcc"

	local build_dir="${BUILD_ROOT}/binutils-${target}-final"
	mkdir -p "${build_dir}" || exit 1
	pushd "${build_dir}" || exit 1

	# Only libbfd and libiberty are currently needed (for perf tool).
	for d in bfd libiberty; do
		mkdir -p "${d}" || exit 1
		pushd "${d}" || exit 1

		CC="${cross_cc}" \
		"${TOOLCHAIN_ROOT}/binutils/${d}/configure" \
			--prefix=/usr \
			--host="${target}" \
			--disable-nls || exit 1

		CC="${cross_cc}" \
		make ${PARALLELMFLAGS} || exit 1

		make \
			prefix="${sysroot}/usr" \
			mandir="${sysroot}/usr/share/man" \
			infodir="${sysroot}/usr/share/info" \
			install || exit 1

		popd
	done

	# We don't need the libtool library file.
	rm -f "${sysroot}/usr/lib/libbfd.la" || exit 1

	popd
}

build_target_elfutils()
{
	local target="$1"
	local tool_prefix="$2"

	PATH="${INSTALL_DIR}/bin:${ORIG_PATH}"

	local sysroot="${INSTALL_DIR}/target-${target}"
	local cross_cc="${INSTALL_DIR}/bin/${tool_prefix}gcc"

	local build_dir="${BUILD_ROOT}/elfutils-${target}"
	mkdir -p "${build_dir}" || exit 1
	pushd "${build_dir}" || exit 1

	CC="${cross_cc}" \
	"${TOOLCHAIN_ROOT}/elfutils/configure" \
		--prefix=/usr \
		--host="${target}" \
		--disable-nls || exit 1

	# Build libelf, libdw and their dependencies. Note that libebl and
	# libdwfl need to be built before libdw.
	for d in libelf libebl libdwfl libdw; do
		pushd "${d}" || exit 1
		CC="${cross_cc}" \
		make ${PARALLELMFLAGS} || exit 1
		popd
	done

	# Only libelf and libdw are currently needed (for perf tool).
	for d in libelf libdw; do
		pushd "${d}" || exit 1
		make \
			prefix="${sysroot}/usr" \
			mandir="${sysroot}/usr/share/man" \
			infodir="${sysroot}/usr/share/info" \
			install || exit 1
		popd
	done

	# We don't need to install the whole elfutils package, but do need
	# version.h to be installed in the include directory (for the perf
	# tool). Just manually install it.
	install -c -m 644 version.h ${sysroot}/usr/include/elfutils || exit 1

	# Only need the archive libraries (for now).
	rm -f "${sysroot}/usr/lib/libdw"*.so* || exit 1
	rm -f "${sysroot}/usr/lib/libelf"*.so* || exit 1

	popd
}

strip_host_binaries()
{
	PATH="${ORIG_PATH}"

	for f in $(find ${INSTALL_DIR}/{bin,libexec} ! -name *.o ! -name *.a -type f); do
		if [[ -n $(file ${f} | grep "not stripped") ]]; then
			if [[ -n $(file ${f} | grep "executable") ]]; then
				echo "Stripping executable ${f} ..."
				strip --strip-all ${f} || exit 1
			else
				echo "Stripping ${f} ..."
				strip --strip-unneeded ${f} || exit 1
			fi
		fi
	done
}

remove_junk()
{
	rm -f "${INSTALL_DIR}/share/info/"{configure,cppinternals,gccinstall,gccint,gdbint,standards}.info || exit 1
	rm -f "${INSTALL_DIR}/share/info/dir" || exit 1
	rm -f "${INSTALL_DIR}/share/man/man1/"*-{nlmconv,windmc,windres}.1 || exit 1
	rm -rf "${INSTALL_DIR}/share/man/man7" || exit 1
}

case "$1" in
--help|-help|-h)
	echo "Usage: build.sh [option]"
	echo "Options:"
	echo "    --help, -help, -h     This help"
	echo "    clean                 Clean build"
	echo "    arm                   Arm toolchain (arm-unknown-linux-gnueabi)"
	echo "    [default]             Intel atom toolchain (i686-unknown-linux)"
	exit 0
	;;
clean)
	# Clean Build
	rm -rf .bootstrap*
	rm -rf .build*
	rm -rf .install*
	exit 0
	;;
arm)
	# ARM toolchain
	TARGET=arm-unknown-linux-gnueabi
	TARGET_KERNEL_ARCH=arm
	TARGET_GCC_OPTS_PARAS=(
		--with-arch=armv7-a
		--with-float=softfp
		--with-fpu=neon
		CFLAGS_FOR_TARGET="-O2 -g -fPIC"
		CXXFLAGS_FOR_TARGET="-O2 -g -fPIC"
	)
	TARGET_GLIBC_OPTS_PARAS=(
		--enable-add-ons
	)
	;;
*)
	# Intel Atom toolchain
	TARGET=i686-unknown-linux
	TARGET_KERNEL_ARCH=i386
	TARGET_GCC_OPTS_PARAS=(
		--disable-multilib
		--with-arch=atom
		--with-tune=atom
	)
esac

TARGET_TOOL_PREFIX="${TARGET}-"
TARGET_GCC_OPTS=(
	"${TARGET}"
	"${TARGET_TOOL_PREFIX}"
	"${TARGET_GCC_OPTS_PARAS[@]}"
)

TARGET_GLIBC_OPTS=(
	"${TARGET}"
	"${TARGET_TOOL_PREFIX}"
	"2.6.35"
	"${TARGET_GLIBC_OPTS_PARAS[@]}"
)

echo "Building toolchain ${TARGET}..."

build_bootstrap_lib "${TOOLCHAIN_ROOT}/libelf"

build_bootstrap_lib "${TOOLCHAIN_ROOT}/gmp"

build_bootstrap_lib "${TOOLCHAIN_ROOT}/mpfr" \
	--with-gmp="${BOOTSTRAP_DIR}"

build_bootstrap_lib "${TOOLCHAIN_ROOT}/mpc" \
	--with-gmp="${BOOTSTRAP_DIR}" \
	--with-mpfr="${BOOTSTRAP_DIR}"

build_cross_binutils \
	"${TARGET}" \
	"${TARGET_TOOL_PREFIX}"

build_cross_gcc \
	"bootstrap" \
	"${TARGET_GCC_OPTS[@]}"

install_kernel_headers \
	"${TARGET}" \
	"${TARGET_KERNEL_ARCH}"

build_target_glibc \
	"bootstrap" \
	"${TARGET_GLIBC_OPTS[@]}"

build_cross_gcc \
	"c-only" \
	"${TARGET_GCC_OPTS[@]}"

build_target_glibc \
	"final" \
	"${TARGET_GLIBC_OPTS[@]}"

if [[ "$1" == "arm" ]]; then
	build_target_glibc \
		"final-thumb" \
		"${TARGET_GLIBC_OPTS[@]}"
fi

build_cross_gcc \
	"final" \
	"${TARGET_GCC_OPTS[@]}"

build_cross_gdb \
	"${TARGET}" \
	"${TARGET_TOOL_PREFIX}"

build_target_gdbserver \
	"${TARGET}" \
	"${TARGET_TOOL_PREFIX}"

build_target_binutils \
	"${TARGET}" \
	"${TARGET_TOOL_PREFIX}"

build_target_elfutils \
	"${TARGET}" \
	"${TARGET_TOOL_PREFIX}"

build_cross_pkg_config \
	"${TARGET}" \
	"${TARGET_TOOL_PREFIX}"

remove_junk
strip_host_binaries

exit 0
