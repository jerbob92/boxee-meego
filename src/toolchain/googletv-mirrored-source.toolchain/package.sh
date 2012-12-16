#!/bin/bash

case "$1" in
arm)
	# ARM toolchain
	TARGET=arm-unknown-linux-gnueabi
	;;
*)
	# Intel Atom toolchain
	TARGET=i686-unknown-linux
esac

echo "Packaging toolchain ${TARGET}..."

rm -rf gtv-toolchain-${TARGET}-*.tar.bz2

pushd ".install-$(uname -m)"
tar cjf "../gtv-toolchain-${TARGET}-$(uname -m).tar.bz2" bin libexec ${TARGET}
tar cjf "../gtv-toolchain-${TARGET}-common.tar.bz2" share target-${TARGET}
popd
