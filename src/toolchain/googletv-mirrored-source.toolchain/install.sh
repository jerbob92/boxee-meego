#!/bin/bash

ANDROID_ROOT="$1"

if [[ -z "${ANDROID_ROOT}" ]]; then
	echo "Usage $0 <Android tree root> [arm]"
	exit 1
fi

if [[ ! -d "${ANDROID_ROOT}" ]]; then
	echo "${ANDROID_ROOT} is not directory"
	exit 1
fi

case "$2" in
arm)
	# ARM toolchain
	target="arm-unknown-linux-gnueabi"
	;;
*)
	# Intel Atom toolchain
	target="i686-unknown-linux"
esac

echo "Installing toolchain ${target}..."

atarget="${target}-4.5.3-glibc"

f="gtv-toolchain-${target}-common.tar.bz2"
if [[ -f "${f}" ]]; then
	d="${ANDROID_ROOT}/prebuilt/common/toolchain/${atarget}"
	echo "Installing ${f} into ${d} ..."
	rm -rf "${d}" || exit 1
	mkdir -p "${d}" || exit 1
	tar xjf "${f}" -C "${d}" || exit 1
fi

hosts=(i686 x86_64)
ahosts=(x86 x86_64)

for (( i = 0; i < ${#hosts[@]}; ++i )); do
	f="gtv-toolchain-${target}-${hosts[i]}.tar.bz2"
	if [[ -f "${f}" ]]; then
		d="${ANDROID_ROOT}/prebuilt/linux-${ahosts[i]}/toolchain/${atarget}"
		echo "Installing ${f} into ${d} ..."
		rm -rf "$d" || exit 1
		mkdir -p "${d}" || exit 1
		tar xjf "${f}" -C "${d}" || exit 1
		ln -s "../../../common/toolchain/${atarget}/share" "${d}/share" || exit 1
		ln -s "../../../common/toolchain/${atarget}/target-${target}" "${d}/target-${target}" || exit 1
	fi
done

exit 0
